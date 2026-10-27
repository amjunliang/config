import copy
import base64
import types
import json
import os
import pathlib
import pty
import signal
import subprocess
import tempfile
import termios
import threading
import time
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).with_name('xray-install.sh')
source = SCRIPT.read_text().split("<<'XRAY_MANAGER_PY'\n", 1)[1].rsplit('\nXRAY_MANAGER_PY', 1)[0]
m = types.ModuleType('manager')
m.__file__ = str(SCRIPT)
exec(compile(source, str(SCRIPT), 'exec'), m.__dict__)
REAL_CORE = pathlib.Path(os.environ['XRAY_TEST_CORE']).resolve() if os.environ.get('XRAY_TEST_CORE') else None
if REAL_CORE is not None and not REAL_CORE.is_file():
    raise RuntimeError('XRAY_TEST_CORE must point to a trusted local Xray binary')
signal.signal(signal.SIGHUP, signal.SIG_IGN)


class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='xray-test-')
        self.base = pathlib.Path(self.temporary.name)
        self.originals = {}
        for key, suffix in [('ROOT', 'var'), ('CONF', 'etc'), ('LIB', 'lib'), ('UNITS', 'units'), ('MANAGER', 'bin/xray-manager'), ('CACHE', 'cache')]:
            self.originals[key] = getattr(m, key)
            setattr(m, key, self.base / suffix)
        for directory in (m.ROOT, m.LIB / 'versions', m.UNITS, m.MANAGER.parent):
            directory.mkdir(parents=True, exist_ok=True)
        binary = m.LIB / 'versions/v26.10.21/xray'
        binary.parent.mkdir()
        binary.write_bytes(REAL_CORE.read_bytes() if REAL_CORE else b'unit-test-core-placeholder')
        binary.chmod(0o755)
        private, public = m.new_keys(binary) if REAL_CORE else (base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip('='), base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip('='))
        self.state = {'schema': 1, 'core_version': 'v26.10.21', 'core_binary': str(binary), 'core_binary_sha256': m.sha(binary),
                      'address': '8.8.8.8', 'listen': '0.0.0.0', 'target': 'www.microsoft.com',
                      'private_key': private, 'public_key': public, 'short_id': '0123456789abcdef',
                      'path': '/0123456789abcdef0123456789abcdef/', 'profiles': {'direct': {'port': 443}},
                      'users': [{'name': 'test', 'id': 'e780a1d1-d3db-4d67-81c5-139c51c41d1f', 'profiles': ['direct']}]}
        self.services = {unit: False for unit in m.OWN_UNITS}

    def tearDown(self):
        for key, value in self.originals.items():
            setattr(m, key, value)
        self.temporary.cleanup()

    def expanded(self):
        state = copy.deepcopy(self.state)
        state['profiles']['vision'] = {'port': 2443}
        state['profiles']['cdn'] = {'port': 443, 'domain': 'proxy.example.com', 'certificate': str(m.ROOT / 'acme/config/live/xray-manager-proxy.example.com'),
                                    'reality_internal': 1443, 'tls_internal': 1444, 'xhttp_internal': 10080,
                                    'path': '/abcdef0123456789abcdef0123456789/'}
        state['users'][0]['profiles'] = ['direct', 'vision', 'cdn']
        return state

    def seed_live(self):
        m.render(self.state, self.base / 'render')
        m.CONF.mkdir()
        for path in (self.base / 'render').iterdir():
            target = m.UNITS / path.name if path.name.endswith(('.service', '.timer')) else m.CONF / path.name
            if path.is_dir():
                m.shutil.copytree(path, target)
            else:
                m.shutil.copy2(path, target)
        m.current_link(self.state['core_binary'])
        self.state['manifest'] = {str(p): m.sha(p) for directory in (m.CONF, m.UNITS) for p in directory.iterdir() if p.is_file()}
        m.write(m.ROOT / 'state.json', self.state)
        self.services[m.CORE_UNIT] = True

    def fake_systemctl(self, action, unit, check=True):
        if action in ('stop', 'disable'):
            self.services[unit] = False
        if action in ('start', 'restart'):
            self.services[unit] = True
        if action in ('is-active', 'is-enabled'):
            return subprocess.CompletedProcess([], 0 if self.services.get(unit, False) else 3, '')
        return subprocess.CompletedProcess([], 0, '')

    def patches(self):
        from contextlib import ExitStack
        stack = ExitStack()
        stack.enter_context(patch.object(m, 'systemctl', side_effect=self.fake_systemctl))
        stack.enter_context(patch.object(m.shutil, 'chown'))
        stack.enter_context(patch.object(m, 'run', return_value=subprocess.CompletedProcess([], 0, '')))
        stack.enter_context(patch.object(m, 'check_candidate'))
        stack.enter_context(patch.object(m, 'ensure_account'))
        stack.enter_context(patch.object(m, 'firewall'))
        stack.enter_context(patch.object(m, 'remove_added_rules'))
        stack.enter_context(patch.object(m, 'save_manager'))
        stack.enter_context(patch.object(m.time, 'sleep'))
        return stack

    @unittest.skipUnless(REAL_CORE, 'Set XRAY_TEST_CORE for real-core validation')
    def test_real_core_accepts_direct_and_vision_configs(self):
        state = self.expanded()
        del state['profiles']['cdn']
        state['users'][0]['profiles'].remove('cdn')
        directory = self.base / 'candidate'
        m.render(state, directory)
        m.check_candidate(state, directory)

    @unittest.skipUnless(REAL_CORE, 'Set XRAY_TEST_CORE for real-core validation')
    def test_real_core_accepts_cdn_loopback_and_clients(self):
        state = self.expanded()
        directory = self.base / 'candidate'
        m.render(state, directory)
        for path in [directory / 'xray.json', *(directory / 'exports').glob('*.json')]:
            m.run([state['core_binary'], 'run', '-test', '-config', path])

    def test_flow_and_private_listener_boundaries(self):
        state = self.expanded()
        server = m.server_config(state)
        inbounds = {x['tag']: x for x in server['inbounds']}
        self.assertNotIn('flow', inbounds['managed-direct']['settings']['clients'][0])
        self.assertEqual(inbounds['managed-vision']['settings']['clients'][0]['flow'], 'xtls-rprx-vision')
        self.assertEqual(inbounds['managed-direct']['listen'], '127.0.0.1')
        self.assertEqual(inbounds['managed-direct']['port'], 1443)
        self.assertEqual(inbounds['managed-cdn']['listen'], '127.0.0.1')
        self.assertEqual(inbounds['managed-cdn']['streamSettings']['security'], 'none')
        self.assertEqual(state['profiles']['direct']['port'], 443)
        self.assertEqual(m.client_config(state, 'direct', state['users'][0])['outbounds'][0]['settings']['vnext'][0]['port'], 443)
        front = m.nginx_config(state)
        self.assertIn('proxy.example.com 127.0.0.1:1444', front)
        self.assertIn('default 127.0.0.1:1443', front)
        self.assertNotIn('private_key', front)

    def test_share_links_match_exported_client(self):
        from urllib.parse import urlsplit, parse_qs
        state = self.expanded()
        state['address'] = '2606:4700:4700::1111'
        for name in state['profiles']:
            user = state['users'][0]
            parts = urlsplit(m.share_link(state, name, user))
            config = m.client_config(state, name, user)['outbounds'][0]
            query = parse_qs(parts.query)
            self.assertEqual(parts.hostname, config['settings']['vnext'][0]['address'])
            self.assertEqual(parts.port, config['settings']['vnext'][0]['port'])
            self.assertEqual(parts.username, user['id'])
            self.assertEqual(query['security'][0], config['streamSettings']['security'])
            if name == 'vision':
                self.assertEqual(query['flow'], ['xtls-rprx-vision'])
            else:
                self.assertNotIn('flow', query)
                self.assertEqual(query['path'][0], config['streamSettings']['xhttpSettings']['path'])

    def test_rejects_unknown_schema_empty_users_and_conflicting_ports(self):
        for mutate in [lambda s: s.update(schema=2), lambda s: s.update(users=[]),
                       lambda s: s['profiles'].update(vision={'port': 443})]:
            state = copy.deepcopy(self.state)
            mutate(state)
            with self.assertRaises(m.Problem):
                m.validate_state(state)

    def test_domain_and_cert_path_injection_rejected(self):
        for domain in ['example.com; return 200', 'example.com\n}', '*.example.com', 'https://example.com']:
            with self.assertRaises(m.Problem):
                m.hostname(domain)
        state = self.expanded()
        state['profiles']['cdn']['certificate'] += ';\ninvalid'
        with self.assertRaises(m.Problem):
            m.validate_state(state)

    def test_last_authorized_user_cannot_be_removed(self):
        state = self.expanded()
        state['users'][0]['profiles'].remove('vision')
        with self.assertRaises(m.Problem):
            m.validate_state(state)

    def test_manual_config_edits_are_never_overwritten(self):
        self.seed_live()
        path = m.CONF / 'xray.json'
        path.write_text('manual edit')
        with self.assertRaises(m.Problem):
            m.apply(self.state, 'should not apply')
        self.assertEqual(path.read_text(), 'manual edit')
        self.assertFalse((m.ROOT / 'backups').exists())

    def test_core_digest_or_link_drift_rejected(self):
        self.seed_live()
        (m.LIB / 'current').unlink()
        with self.assertRaises(m.Problem):
            m.drift_check(self.state)

    def test_failed_update_restores_live_files_state_and_services(self):
        self.seed_live()
        before = (m.CONF / 'xray.json').read_bytes()
        candidate = copy.deepcopy(self.state)
        candidate['address'] = '1.1.1.1'
        with self.patches(), patch.object(m, 'health', side_effect=m.Problem('simulated connection failure')):
            with self.assertRaises(m.Problem):
                m.apply(candidate, 'failure test')
        self.assertEqual((m.CONF / 'xray.json').read_bytes(), before)
        self.assertEqual(m.read_json(m.ROOT / 'state.json')['address'], '8.8.8.8')
        self.assertTrue(self.services[m.CORE_UNIT])
        self.assertFalse((m.ROOT / 'transaction.json').exists())

    def test_failed_first_install_leaves_no_managed_live_state(self):
        with self.patches(), patch.object(m, 'health', side_effect=m.Problem('simulated failure')):
            with self.assertRaises(m.Problem):
                m.apply(self.state, 'first install failure')
        self.assertFalse((m.ROOT / 'state.json').exists())
        self.assertFalse(m.CONF.exists())
        self.assertFalse((m.UNITS / m.CORE_UNIT).exists())
        self.assertFalse((m.LIB / 'current').exists())

    def test_successful_change_preserves_identity(self):
        self.seed_live()
        candidate = copy.deepcopy(self.state)
        candidate['profiles']['vision'] = {'port': 2443}
        candidate['users'][0]['profiles'].append('vision')
        with self.patches(), patch.object(m, 'health'):
            m.apply(candidate, 'add vision')
        after = m.read_json(m.ROOT / 'state.json')
        for key in ('private_key', 'public_key', 'short_id', 'path'):
            self.assertEqual(after[key], self.state[key])
        self.assertEqual(after['users'][0]['id'], self.state['users'][0]['id'])
        self.assertEqual(after['profiles']['direct']['port'], 443)
        self.assertEqual((m.ROOT / 'state.json').stat().st_mode & 0o777, 0o600)
        for path in (m.CONF / 'exports').iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_interrupted_transaction_is_restored_before_menu(self):
        self.seed_live()
        with self.patches():
            snapshot = m.backup('before crash')
            (m.CONF / 'xray.json').write_text('partial write')
            m.write(m.ROOT / 'transaction.json', {'backup': str(snapshot), 'label': 'crash', 'ufw_tag': 'xray-manager-test'})
            with patch.object(m, 'confirm', return_value=True):
                m.recovery()
        self.assertNotEqual((m.CONF / 'xray.json').read_text(), 'partial write')
        self.assertFalse((m.ROOT / 'transaction.json').exists())
        self.assertTrue(self.services[m.CORE_UNIT])

    def test_missing_backup_binary_does_not_stop_services(self):
        self.seed_live()
        with self.patches():
            snapshot = m.backup('missing binary')
            pathlib.Path(self.state['core_binary']).unlink()
            with patch.object(m, 'systemctl') as ctl:
                with self.assertRaises(m.Problem):
                    m.restore(snapshot)
                ctl.assert_not_called()

    def test_ufw_rollback_removes_only_its_exact_tag(self):
        numbered = '[ 1] 22/tcp ALLOW IN Anywhere\n[ 2] 443/tcp ALLOW IN Anywhere # xray-manager-test\n[ 3] 2443/tcp ALLOW IN Anywhere # other\n[ 4] 443/tcp (v6) ALLOW IN Anywhere (v6) # xray-manager-test\n'
        with patch.object(m.shutil, 'which', return_value='/usr/sbin/ufw'), patch.object(m, 'run', return_value=subprocess.CompletedProcess([], 0, numbered)) as command:
            m.remove_added_rules('xray-manager-test')
        self.assertEqual(command.call_args_list[1].args[0], ['ufw', '--force', 'delete', '4'])
        self.assertEqual(command.call_args_list[2].args[0], ['ufw', '--force', 'delete', '2'])
        self.assertEqual(len(command.call_args_list), 3)

    def test_download_refuses_missing_official_digest(self):
        info = {'tag_name': 'v26.10.21', 'assets': [{'name': 'Xray-linux-arm64-v8a.zip'}]}
        with patch.object(m.platform, 'machine', return_value='aarch64'), patch.object(m, 'run') as command:
            with self.assertRaises(m.Problem):
                m.download_core(info)
            command.assert_not_called()

    def test_download_bad_digest_cannot_replace_core(self):
        self.seed_live()
        info = {'tag_name': 'v26.10.21', 'assets': [{'name': 'Xray-linux-arm64-v8a.zip', 'digest': 'sha256:' + '0' * 64}]}
        def fake_curl(args, **kwargs):
            pathlib.Path(args[-1]).write_bytes(b'corrupted archive')
            return subprocess.CompletedProcess([], 0, '')
        with patch.object(m.platform, 'machine', return_value='aarch64'), patch.object(m, 'run', side_effect=fake_curl):
            with self.assertRaises(m.Problem):
                m.download_core(info)
        self.assertEqual((m.LIB / 'current').resolve(), pathlib.Path(self.state['core_binary']).parent.resolve())

    def test_terminal_prompt_accepts_input_without_seekable_stream(self):
        master, slave = pty.openpty()
        terminal = m.Terminal(os.ttyname(slave))
        try:
            os.write(master, b'0\n')
            with patch.object(m, 'TTY', terminal):
                self.assertEqual(m.ask('selection', '1'), '0')
        finally:
            terminal.close()
            os.close(master)
            os.close(slave)

    def test_upgrade_switch_failure_restores_original_binary_link(self):
        self.seed_live()
        candidate = copy.deepcopy(self.state)
        new_binary = m.LIB / 'versions/v26.10.22/xray'
        new_binary.parent.mkdir()
        new_binary.write_bytes(REAL_CORE.read_bytes() if REAL_CORE else b'unit-test-core-placeholder')
        candidate.update(core_version='v26.10.22', core_binary=str(new_binary), core_binary_sha256=m.sha(new_binary))
        with self.patches(), patch.object(m, 'restart_deployment', side_effect=m.Problem('simulated service start failure')):
            with self.assertRaises(m.Problem):
                m.apply(candidate, 'upgrade restart failure')
        self.assertEqual(m.read_json(m.ROOT / 'state.json')['core_version'], 'v26.10.21')
        self.assertEqual((m.LIB / 'current').resolve(), pathlib.Path(self.state['core_binary']).parent.resolve())
        self.assertTrue(self.services[m.CORE_UNIT])

    def test_default_restart_does_not_download_or_rotate_credentials(self):
        self.seed_live()
        before = (m.ROOT / 'state.json').read_bytes()
        with patch.object(m, 'confirm', return_value=True), patch.object(m, 'systemctl', side_effect=self.fake_systemctl), patch.object(m, 'health') as health, patch.object(m, 'run'), patch.object(m, 'download_core') as download:
            m.installation()
        download.assert_not_called()
        health.assert_called_once()
        self.assertEqual((m.ROOT / 'state.json').read_bytes(), before)

    def test_secret_terminal_input_restores_echo_without_exposing_token(self):
        master, slave = pty.openpty()
        terminal = m.Terminal(os.ttyname(slave))
        original = termios.tcgetattr(slave)
        def type_secret():
            os.read(master, 4096)  # drain prompt so TCSADRAIN can complete on a virtual TTY
            for _ in range(100):
                if not termios.tcgetattr(slave)[3] & termios.ECHO:
                    os.write(master, b'sensitive-token\n')
                    return
                time.sleep(0.01)
        worker = threading.Thread(target=type_secret, daemon=True)
        worker.start()
        old_handler = signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError('virtual tty input timeout')))
        signal.alarm(5)
        try:
            with patch.object(m, 'TTY', terminal):
                self.assertEqual(m.ask('Token', secret=True), 'sensitive-token')
            worker.join(timeout=2)
            self.assertEqual(termios.tcgetattr(slave), original)
            os.set_blocking(master, False)
            output = os.read(master, 4096)
            self.assertNotIn(b'sensitive-token', output)
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, old_handler)
            terminal.close()
            os.close(master)
            os.close(slave)

    def test_config_directory_is_group_traversable_under_production_umask(self):
        previous = os.umask(0o077)
        try:
            with self.patches(), patch.object(m, 'health'):
                m.apply(self.state, 'production umask regression')
            self.assertEqual(m.CONF.stat().st_mode & 0o777, 0o750)
            self.assertEqual((m.CONF / 'xray.json').stat().st_mode & 0o777, 0o640)
            with self.patches():
                snapshot = m.backup('permissions snapshot')
                m.restore(snapshot)
            self.assertEqual(m.CONF.stat().st_mode & 0o777, 0o750)
        finally:
            os.umask(previous)

    def test_journal_survives_manager_install_and_restore_failures(self):
        self.seed_live()
        with self.patches(), patch.object(m, 'health'), patch.object(m, 'save_manager', side_effect=m.Problem('manager write failed')), patch.object(m, 'restore', side_effect=m.Problem('restore failed')):
            with self.assertRaises(m.Problem):
                m.apply(copy.deepcopy(self.state), 'journal regression')
        journal = m.read_json(m.ROOT / 'transaction.json')
        self.assertTrue((pathlib.Path(journal['backup']) / 'metadata.json').exists())

    def test_firewall_cleanup_failure_keeps_recovery_record(self):
        self.seed_live()
        with self.patches(), patch.object(m, 'health', side_effect=m.Problem('probe failed')), patch.object(m, 'remove_added_rules', side_effect=m.Problem('ufw failed')):
            with self.assertRaises(m.Problem):
                m.apply(copy.deepcopy(self.state), 'ufw cleanup regression')
        self.assertTrue((m.ROOT / 'transaction.json').exists())

    def test_failed_service_stop_cannot_remove_configuration(self):
        self.seed_live()
        before = (m.CONF / 'xray.json').read_bytes()
        with self.patches(), patch.object(m, 'stop_managed', side_effect=m.Problem('stop denied')):
            with self.assertRaises(m.Problem):
                m.apply(copy.deepcopy(self.state), 'stop failure regression')
        self.assertEqual((m.CONF / 'xray.json').read_bytes(), before)
        self.assertTrue((m.ROOT / 'transaction.json').exists())

    def test_unmanaged_account_is_not_granted_proxy_credentials(self):
        def lookup(args, **kwargs):
            record = 'xray-manager:x:1234:\n' if args[1] == 'group' else 'xray-manager:x:1234:1234::/home/person:/bin/bash\n'
            return subprocess.CompletedProcess(args, 0, record)
        with patch.object(m, 'run', side_effect=lookup) as command:
            with self.assertRaises(m.Problem):
                m.ensure_account()
        self.assertTrue(all(c.args[0][0] == 'getent' for c in command.call_args_list))
        self.assertFalse((m.ROOT / 'account-owned').exists())

    def test_root_or_shared_dedicated_group_is_rejected(self):
        m.write(m.ROOT / 'account-owned', 'manager-owned')
        for group in ('xray-manager:x:0:\n', 'xray-manager:x:999:another-user\n'):
            with self.subTest(group=group):
                with patch.object(m, 'run', side_effect=[subprocess.CompletedProcess([], 0, group), subprocess.CompletedProcess([], 1, '')]):
                    with self.assertRaises(m.Problem):
                        m.ensure_account()

    def test_new_account_gets_explicit_dedicated_primary_group(self):
        def lookup(args, **kwargs):
            return subprocess.CompletedProcess(args, 2 if args[0] == 'getent' else 0, '')
        with patch.object(m, 'run', side_effect=lookup) as command:
            m.ensure_account()
        useradd = next(c.args[0] for c in command.call_args_list if c.args[0][0] == 'useradd')
        self.assertEqual(useradd[useradd.index('--gid') + 1], 'xray-manager')
        self.assertEqual(useradd[useradd.index('--shell') + 1], '/usr/sbin/nologin')

    def test_private_directory_rejects_symlink_before_chmod(self):
        target = self.base / 'unrelated'
        target.mkdir(mode=0o755)
        target.chmod(0o755)
        link = self.base / 'misdirected'
        link.symlink_to(target, target_is_directory=True)
        with self.assertRaises(m.Problem):
            m.owned_directory(link, 0o700)
        self.assertEqual(target.stat().st_mode & 0o777, 0o755)

    def test_state_rejects_malformed_data_before_rendering(self):
        mutations = [lambda s: s.update(users='not a list'), lambda s: s.update(listen='127.0.0.1'),
                     lambda s: s['profiles']['direct'].update(port='443'),
                     lambda s: s.update(core_binary=str(m.LIB / 'versions/../../other/xray')),
                     lambda s: s.update(core_binary_sha256='not a digest')]
        for mutate in mutations:
            state = copy.deepcopy(self.state)
            mutate(state)
            with self.assertRaises(m.Problem):
                m.validate_state(state)
        state = self.expanded()
        state['profiles']['cdn']['port'] = 8443
        with self.assertRaises(m.Problem):
            m.validate_state(state)

    def test_cdn_port_conflict_stops_before_dependency_or_certificate_operations(self):
        answers = ['proxy.example.com', 'done', 'user@example.com', 'A' * 40, '1443', '1443', '10080']
        with patch.object(m, 'load_state', return_value=copy.deepcopy(self.state)), patch.object(m, 'ask', side_effect=answers), patch.object(m, 'cf_dns_check'), patch.object(m, 'ensure_free'), patch.object(m, 'cdn_dependencies') as install, patch.object(m, 'run') as command:
            with self.assertRaises(m.Problem):
                m.cdn_wizard()
        install.assert_not_called()
        command.assert_not_called()

    def test_self_update_reads_moved_script_from_pinned_commit(self):
        content = b'#!/bin/bash\n# XRAY_MANAGER_VERSION: 999.0.0\nexit 0\n'
        metadata = {'type': 'file', 'encoding': 'base64', 'content': base64.b64encode(content).decode(),
                    'sha': m.hashlib.sha1(b'blob ' + str(len(content)).encode() + b'\0' + content).hexdigest()}
        commit = 'a' * 40
        with patch.object(m, 'http', side_effect=[{'sha': commit}, metadata]) as fetch, patch.object(m, 'confirm', return_value=False):
            m.update_manager()
        self.assertEqual(fetch.call_args_list[1].args[0], m.API + m.REPO + '/contents/script/xray-install.sh?ref=' + commit)

    def test_renewal_unit_uses_manager_lock_and_retry_timer(self):
        units = m.unit_files(cdn=True)
        self.assertIn(f'{m.ROOT}/deployment.lock /usr/bin/certbot renew', units[m.RENEW_UNIT])
        self.assertIn('SuccessExitStatus=75', units[m.RENEW_UNIT])
        self.assertIn('OnUnitInactiveSec=6h', units[m.RENEW_TIMER])

    def test_deployment_lock_is_reentrant_and_excludes_another_process(self):
        code = "import fcntl,sys; f=open(sys.argv[1],'a+'); fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)"
        command = [os.sys.executable, '-c', code, str(m.ROOT / 'deployment.lock')]
        with m.deployment_lock():
            with m.deployment_lock():
                result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                self.assertNotEqual(result.returncode, 0)
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_idle_menu_lock_does_not_block_certificate_deployment_lock(self):
        try:
            m.lock()
            code = "import fcntl,sys; f=open(sys.argv[1],'a+'); fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)"
            result = subprocess.run([os.sys.executable, '-c', code, str(m.ROOT / 'deployment.lock')], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stderr)
        finally:
            if m.LOCK is not None:
                m.LOCK.close()
                m.LOCK = None

    def test_target_page_extracts_only_hostname(self):
        for value in ('www.example.com', 'https://WWW.EXAMPLE.COM/docs?a=1#section', 'www.example.com:443/docs'):
            self.assertEqual(m.target_hostname(value), 'www.example.com')

    def test_target_page_rejects_empty_insecure_or_unsupported_inputs(self):
        for value in ('', '  ', 'http://www.example.com', 'https://www.example.com:8443/',
                      'https://user:password@www.example.com/', 'https://1.1.1.1/',
                      'https://[2606:4700:4700::1111]/', 'https://www.example.com:invalid/'):
            with self.subTest(value=value), self.assertRaises(m.Problem):
                m.target_hostname(value)

    def test_required_target_retries_blank_and_failed_checks_without_a_default(self):
        with patch.object(m, 'ask', side_effect=['', 'https://bad.example.com/page', 'https://good.example.com/page']) as ask, patch.object(m, 'target_check', side_effect=[m.Problem('TLS check failed'), None]) as check:
            self.assertEqual(m.prompt_target(), 'good.example.com')
        self.assertTrue(all(c.args[1] is None for c in ask.call_args_list))
        self.assertEqual([c.args[0] for c in check.call_args_list], ['bad.example.com', 'good.example.com'])

    def test_target_prompt_cancellation_is_not_swallowed(self):
        with patch.object(m, 'ask', side_effect=m.Problem('cancelled')), patch.object(m, 'target_check') as check:
            with self.assertRaises(m.Problem):
                m.prompt_target()
        check.assert_not_called()

    def test_initial_install_uses_required_target_before_download(self):
        with patch.object(m, 'load_state', return_value=None), patch.object(m, 'foreign_install'), patch.object(m, 'detect_addresses', return_value={'IPv4': '8.8.8.8'}), patch.object(m, 'ask', side_effect=['8.8.8.8', '443']), patch.object(m, 'ensure_free'), patch.object(m, 'prompt_target', return_value='chosen.example.com') as target, patch.object(m, 'release', return_value={'tag_name': 'v26.10.21'}), patch.object(m, 'confirm', return_value=False), patch.object(m, 'download_core') as download:
            m.installation()
        target.assert_called_once_with()
        download.assert_not_called()


if __name__ == '__main__':
    unittest.main(verbosity=2)
