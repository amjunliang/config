"""Opt-in real proxy tests. Uses loopback high ports and temporary files only.

Requires explicitly supplied trusted XRAY_TEST_CORE, NGINX_TEST_BINARY and
NGINX_TEST_MODULE. Does not install binaries or change system services.
The HTTPS egress probe requires outbound network access.
"""
import copy
import os
import pathlib
import pwd
import re
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
import uuid

from test_xray_manager import m


@unittest.skipUnless(all(os.environ.get(k) for k in ('XRAY_TEST_CORE', 'NGINX_TEST_BINARY', 'NGINX_TEST_MODULE')),
                     'Set trusted Xray/Nginx/module paths to enable live proxy tests')
class ProxyIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {key: getattr(m, key) for key in ('ROOT', 'LIB', 'CACHE')}
        cls.temporary = tempfile.TemporaryDirectory(prefix='xray-proxy-integration-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.addClassCleanup(lambda: [setattr(m, key, value) for key, value in cls.original.items()])
        cls.base = pathlib.Path(cls.temporary.name)
        m.ROOT, m.LIB, m.CACHE = cls.base / 'data', cls.base / 'lib', cls.base / 'cache'
        for directory in (m.ROOT, m.LIB / 'versions/local', m.CACHE / 'client', m.CACHE / 'proxy', cls.base / 'prefix/logs'):
            directory.mkdir(parents=True, exist_ok=True)
        cls.core = m.LIB / 'versions/local/xray'
        shutil.copy2(pathlib.Path(os.environ['XRAY_TEST_CORE']).resolve(), cls.core)
        cls.core.chmod(0o755)
        cls.nginx = pathlib.Path(os.environ['NGINX_TEST_BINARY']).resolve()
        cls.module = pathlib.Path(os.environ['NGINX_TEST_MODULE']).resolve()
        private, public = m.new_keys(cls.core)
        version = re.search(r'^Xray (\d+\.\d+\.\d+(?:-\d+)?) ', m.run([cls.core, 'version']).stdout).group(1)
        cls.used_ports = set()

        def free_port():
            for _ in range(100):
                with socket.socket() as sock:
                    sock.bind(('127.0.0.1', 0))
                    value = sock.getsockname()[1]
                if value not in cls.used_ports:
                    cls.used_ports.add(value)
                    return value
            raise RuntimeError('Could not allocate unique test ports')

        cls.free_port = staticmethod(free_port)
        cls.public_port = free_port()
        certificate = m.ROOT / 'acme/config/live/xray-manager-proxy.example.com'
        certificate.mkdir(parents=True)
        m.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
               '-subj', '/CN=proxy.example.com', '-addext', 'subjectAltName=DNS:proxy.example.com',
               '-addext', 'basicConstraints=critical,CA:TRUE',
               '-keyout', certificate / 'privkey.pem', '-out', certificate / 'fullchain.pem'])
        cls.state = {'schema': 1, 'core_version': 'v' + version, 'core_binary': str(cls.core), 'core_binary_sha256': m.sha(cls.core),
                     'address': '8.8.8.8', 'listen': '0.0.0.0', 'target': 'www.microsoft.com',
                     'private_key': private, 'public_key': public, 'short_id': '0123456789abcdef', 'path': '/' + uuid.uuid4().hex + '/',
                     'users': [{'name': 'integration', 'id': str(uuid.uuid4()), 'profiles': ['direct', 'vision', 'cdn']}],
                     'profiles': {'direct': {'port': 443}, 'vision': {'port': free_port()},
                                  'cdn': {'port': 443, 'domain': 'proxy.example.com', 'certificate': str(certificate),
                                          'path': '/' + uuid.uuid4().hex + '/', 'reality_internal': free_port(),
                                          'tls_internal': free_port(), 'xhttp_internal': free_port()}}}
        m.validate_state(cls.state)
        server = m.server_config(cls.state)
        for inbound in server['inbounds']:
            inbound['listen'] = '127.0.0.1'  # No public listeners in integration tests.
        m.write(cls.base / 'server.json', server)
        config = m.nginx_config(cls.state)
        config = config.replace('/usr/lib/nginx/modules/ngx_stream_module.so', str(cls.module))
        config = config.replace('user www-data;', 'user ' + pwd.getpwuid(os.geteuid()).pw_name + ';')
        config = config.replace('worker_processes auto;', 'worker_processes 1;')
        config = config.replace('/run/xray-manager-nginx.pid', str(cls.base / 'nginx.pid'))
        config = config.replace('listen 0.0.0.0:443;', f'listen 127.0.0.1:{cls.public_port};')
        m.write(cls.base / 'nginx.conf', config)
        m.run([cls.nginx, '-p', str(cls.base / 'prefix') + '/', '-t', '-c', cls.base / 'nginx.conf'])
        for name, command in [('server', [cls.core, 'run', '-config', cls.base / 'server.json']),
                              ('nginx', [cls.nginx, '-p', str(cls.base / 'prefix') + '/', '-c', cls.base / 'nginx.conf', '-g', 'daemon off;'])]:
            log = (cls.base / (name + '.log')).open('w')
            process = subprocess.Popen([str(x) for x in command], stdout=log, stderr=subprocess.STDOUT)
            cls.addClassCleanup(log.close)
            cls.addClassCleanup(cls.stop, process)
            time.sleep(0.5)
            if process.poll() is not None:
                raise RuntimeError(f'{name} failed: ' + (cls.base / (name + '.log')).read_text())

    @staticmethod
    def stop(process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

    def probe(self, name, *, wrong_user=False, trust_certificate=True):
        user = copy.deepcopy(self.state['users'][0])
        if wrong_user:
            user['id'] = str(uuid.uuid4())
        socks = self.free_port()
        client = m.client_config(self.state, name, user, '127.0.0.1', socks)
        if name != 'vision':
            client['outbounds'][0]['settings']['vnext'][0]['port'] = self.public_port
        if name == 'cdn' and trust_certificate:
            tls = client['outbounds'][0]['streamSettings']['tlsSettings']
            tls['disableSystemRoot'] = True
            tls['certificates'] = [{'usage': 'verify', 'certificateFile': self.state['profiles']['cdn']['certificate'] + '/fullchain.pem'}]
        config = self.base / ('client-' + uuid.uuid4().hex + '.json')
        m.write(config, client)
        with (self.base / 'client.log').open('w') as log:
            process = subprocess.Popen([str(self.core), 'run', '-config', str(config)], stdout=log, stderr=subprocess.STDOUT)
            try:
                for _ in range(50):
                    if process.poll() is not None:
                        self.fail('Client failed before probe')
                    try:
                        with socket.create_connection(('127.0.0.1', socks), timeout=0.2):
                            break
                    except OSError:
                        time.sleep(0.1)
                result = m.run(['curl', '--fail', '--silent', '--show-error', '--noproxy', '',
                                '--proxy', f'socks5h://127.0.0.1:{socks}', '--max-time', '15', '-o', '/dev/null', m.TEST_URL], check=False, timeout=20)
                self.assertIsNone(process.poll(), 'Client died during probe')
                return result
            finally:
                self.stop(process)

    def test_existing_reality_works_through_sni_front(self):
        result = self.probe('direct')
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_private_authenticated_health_probe_works(self):
        state = copy.deepcopy(self.state)
        state['profiles']['direct']['port'] = self.public_port
        m.proxy_probe(state, 'direct')

    def test_vision_backup_remains_independent(self):
        result = self.probe('vision')
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_xhttp_tls_with_verified_certificate_works_through_front(self):
        result = self.probe('cdn')
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_wrong_uuid_is_rejected(self):
        result = self.probe('direct', wrong_user=True)
        self.assertNotEqual(result.returncode, 0)

    def test_untrusted_tls_certificate_is_rejected(self):
        result = self.probe('cdn', trust_certificate=False)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
