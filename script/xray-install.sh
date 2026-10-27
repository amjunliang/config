#!/usr/bin/env bash
# XRAY_MANAGER_VERSION: 0.1.2
# Public source contains no deployment credentials. Requires an interactive terminal.
set -euo pipefail
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  printf '%s\n' 'Xray Manager 0.1.2 — 中文交互式 VPS 管理' \
    '用法：sudo bash xray-install.sh  或  sudo xray-manager' \
    '参数：--status（只读状态）、--check-state（更新兼容检查）、--help' \
    '安装、升级、扩展和回退均须在菜单中确认。'
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  if [[ $(uname -s) != Linux || $EUID != 0 ]] || ! command -v apt-get >/dev/null; then
    printf '%s\n' '请在 Debian/Ubuntu VPS 上使用 root/sudo 运行；需要 python3。' >&2
    exit 1
  fi
  if [[ $# -gt 0 ]]; then
    printf '%s\n' '只读操作不安装依赖。请先安装 python3。' >&2
    exit 1
  fi
  printf '%s' '需要先安装 Python 3 才能打开菜单。安装 python3？[y/N] ' >/dev/tty
  read -r answer </dev/tty
  [[ $answer == y || $answer == Y ]] || exit 0
  apt-get update
  apt-get install -y --no-install-recommends python3 ca-certificates
fi
export XRAY_MANAGER_SOURCE
XRAY_MANAGER_SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
exec python3 - "$@" <<'XRAY_MANAGER_PY'
import base64
import fcntl
import functools
import hashlib
import ipaddress
import json
import os
import platform
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

VERSION = "0.1.2"
SCHEMA = 1
ROOT = Path('/var/lib/xray-manager')
CONF = Path('/etc/xray-manager')
LIB = Path('/usr/local/lib/xray-manager')
UNITS = Path('/etc/systemd/system')
MANAGER = Path('/usr/local/sbin/xray-manager')
CACHE = Path('/var/cache/xray-manager')
CORE_UNIT = 'xray-manager.service'
FRONT_UNIT = 'xray-manager-front.service'
RENEW_UNIT = 'xray-manager-renew.service'
RENEW_TIMER = 'xray-manager-renew.timer'
OWN_UNITS = (CORE_UNIT, FRONT_UNIT, RENEW_UNIT, RENEW_TIMER)
REPO = 'amjunliang/config'
SCRIPT_PATH = 'script/xray-install.sh'
API = 'https://api.github.com/repos/'
TEST_URL = 'https://www.gstatic.com/generate_204'
TTY = None
LOCK = None
DEPLOY_LOCK = None


class Problem(Exception):
    pass


class Terminal:
    """Separate streams: BufferedRandom/r+ requires seek, which a TTY cannot provide."""
    def __init__(self, path='/dev/tty'):
        self.reader = open(path, 'r', encoding='utf-8')
        try:
            self.writer = open(path, 'w', encoding='utf-8', buffering=1)
        except BaseException:
            self.reader.close()
            raise

    def write(self, text):
        return self.writer.write(text)

    def flush(self):
        self.writer.flush()

    def readline(self):
        return self.reader.readline()

    def fileno(self):
        return self.reader.fileno()

    def close(self):
        self.reader.close()
        self.writer.close()


def say(message=''):
    print(message, flush=True)


def ask(label, default=None, secret=False):
    if TTY is None:
        raise Problem('需要交互终端。请下载脚本后在 SSH 终端执行，不要使用 curl | bash。')
    suffix = f' [{default}]' if default is not None else ''
    TTY.write(label + suffix + ': ')
    TTY.flush()
    if secret:
        import termios
        previous = termios.tcgetattr(TTY.fileno())
        changed = previous[:]
        changed[3] &= ~termios.ECHO
        termios.tcsetattr(TTY.fileno(), termios.TCSADRAIN, changed)
        try:
            value = TTY.readline()
        finally:
            termios.tcsetattr(TTY.fileno(), termios.TCSADRAIN, previous)
            TTY.write('\n')
            TTY.flush()
    else:
        value = TTY.readline()
    if value == '':
        raise EOFError
    value = value.strip()
    if value.lower() == 'q':
        raise Problem('已返回菜单，未执行尚未确认的变更。')
    return value or (str(default) if default is not None else '')


def confirm(summary):
    say('\n' + summary)
    return ask('确认执行？输入 yes；其他输入取消', 'no').lower() == 'yes'


def run(args, check=True, timeout=120, capture=True, **kwargs):
    try:
        environment = {**kwargs.pop('env', os.environ), 'LC_ALL': 'C'}
        result = subprocess.run([str(x) for x in args], text=True,
                                stdout=subprocess.PIPE if capture else None,
                                stderr=subprocess.STDOUT if capture else None,
                                timeout=timeout, env=environment, **kwargs)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Problem(f'命令无法完成：{args[0]}（{type(exc).__name__}）') from None
    if check and result.returncode:
        # Commands never include token values; callers avoid logging sensitive responses.
        output = (result.stdout or '')[-3500:]
        raise Problem(f'命令失败：{args[0]}\n{output}')
    return result


def systemctl(action, unit, check=True):
    return run(['systemctl', action, *([unit] if unit else [])], check=check, timeout=45)


def active(unit):
    return systemctl('is-active', unit, check=False).returncode == 0


def sha(path):
    with open(path, 'rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(file.read()).hexdigest()


def write(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(data, ensure_ascii=False, indent=2) + '\n' if not isinstance(data, str) else data
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w') as file:
            file.write(payload)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
        # Persist the rename too, so the recovery journal survives a power failure.
        if platform.system() == 'Linux':
            directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        raise Problem(f'无法读取 JSON：{path}；不会自动覆盖，请从备份恢复。') from None


def load_state(required=True):
    path = ROOT / 'state.json'
    if not path.exists():
        if required:
            raise Problem('尚未安装，请先选择菜单 1。')
        return None
    state = read_json(path)
    validate_state(state)
    return state


def hostname(value):
    try:
        value = value.rstrip('.').encode('idna').decode('ascii').lower()
    except UnicodeError:
        raise Problem('域名格式不正确。') from None
    labels = value.split('.')
    if len(value) > 253 or len(labels) < 2 or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', x) for x in labels):
        raise Problem('请输入完整域名，不包含协议、端口、路径或通配符。')
    return value


def target_hostname(value):
    value = value.strip()
    if not value:
        raise Problem('目标网站必填，请输入域名或 HTTPS 页面地址。')
    try:
        page = urllib.parse.urlsplit(value if '://' in value else 'https://' + value)
        if page.scheme != 'https' or not page.hostname or page.port not in (None, 443) or page.username is not None or page.password is not None:
            raise Problem('目标必须是使用 443 端口、不带登录信息的 HTTPS 网站。')
        host = page.hostname
    except ValueError:
        raise Problem('目标页面地址或端口格式不正确。') from None
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return hostname(host)
    raise Problem('请输入网站域名；REALITY 目标不能直接填写 IP 地址。')


def prompt_target(current=None):
    say('填写 REALITY 目标网站：支持域名或 HTTPS 页面地址，页面路径仅用于输入，不写入配置。')
    say('将检查证书有效性、域名匹配、TLS 1.3 和 HTTP/2；输入 q 返回菜单。')
    while True:
        value = ask('REALITY 目标网站（必填）' if current is None else 'REALITY 目标网站（回车保留）', current)
        try:
            target = target_hostname(value)
            target_check(target)
        except Problem as exc:
            say('目标未通过：' + str(exc) + '\n请重新填写，或输入 q 返回。')
            continue
        say('检测通过，将使用目标：' + target + ':443；客户端 SNI：' + target)
        return target


def server_address(value):
    value = value.strip().strip('[]')
    try:
        address = ipaddress.ip_address(value)
        if not address.is_global:
            raise Problem('请输入可被客户端访问的公网 IP。')
        return str(address)
    except ValueError:
        return hostname(value)


def port_number(value):
    try:
        port = int(value)
    except (ValueError, TypeError):
        raise Problem('端口必须是 1–65535 的整数。') from None
    if not 1 <= port <= 65535:
        raise Problem('端口必须在 1–65535 之间。')
    return port


def validate_state(state):
    if not isinstance(state, dict):
        raise Problem('状态文件必须是 JSON 对象。')
    if state.get('schema') != SCHEMA:
        raise Problem('状态数据版本不兼容；本版只接受 schema=1，不会自动重置数据。')
    for key in ('core_version', 'core_binary', 'core_binary_sha256', 'address', 'target', 'listen', 'private_key', 'public_key', 'short_id', 'path'):
        if not isinstance(state.get(key), str):
            raise Problem('状态数据缺少有效字段：' + key)
    if state['listen'] not in ('0.0.0.0', '::'):
        raise Problem('公网监听地址必须是 0.0.0.0 或 ::。')
    if not re.fullmatch(r'[a-f0-9]{64}', state['core_binary_sha256']):
        raise Problem('核心摘要格式无效。')
    if not re.fullmatch(r'v\d+(?:\.\d+){2}(?:-\d+)?', state.get('core_version', '')):
        raise Problem('核心版本数据无效。')
    if not isinstance(state.get('users'), list) or not state['users'] or not isinstance(state.get('profiles'), dict) or 'direct' not in state['profiles']:
        raise Problem('状态数据缺少主入口或用户。')
    server_address(state['address'])
    hostname(state['target'])
    labels, ids, ports = set(), set(), []
    for user in state['users']:
        if not isinstance(user, dict) or not isinstance(user.get('name'), str) or not isinstance(user.get('id'), str) or not isinstance(user.get('profiles'), list) or any(not isinstance(p, str) for p in user['profiles']):
            raise Problem('用户记录格式无效。')
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,32}', user['name']) or user['name'] in labels:
            raise Problem('用户名无效或重复。')
        labels.add(user['name'])
        uuid.UUID(user['id'])
        if user['id'] in ids or not user['profiles'] or set(user['profiles']) - set(state['profiles']):
            raise Problem('用户授权或 UUID 无效。')
        ids.add(user['id'])
    for name, profile in state['profiles'].items():
        if not isinstance(profile, dict) or type(profile.get('port')) is not int:
            raise Problem('入口端口必须保存为整数。')
        if name not in ('direct', 'vision', 'cdn'):
            raise Problem('发现本版不认识的入口，停止修改。')
        if not any(name in x['profiles'] for x in state['users']):
            raise Problem(f'{name} 至少需要一名授权用户。')
        ports.append(port_number(profile['port']))
    if len(ports) != len(set(ports)):
        # CDN and direct intentionally share 443 through an SNI router.
        if not ('cdn' in state['profiles'] and state['profiles']['direct']['port'] == 443 and ports.count(443) == 2 and len(set(ports)) == len(ports) - 1):
            raise Problem('公网入口端口冲突。')
    for key in ('private_key', 'public_key'):
        if not re.fullmatch(r'[A-Za-z0-9_-]{43}', state.get(key, '')):
            raise Problem('REALITY 密钥数据无效。')
    if not re.fullmatch(r'[a-f0-9]{16}', state.get('short_id', '')):
        raise Problem('Short ID 数据无效。')
    if not re.fullmatch(r'/[a-f0-9]{32}/', state.get('path', '')):
        raise Problem('XHTTP 路径数据无效。')
    cdn = state['profiles'].get('cdn')
    if cdn:
        if cdn['port'] != 443:
            raise Problem('CDN 公网入口固定使用 443。')
        if any(not isinstance(cdn.get(key), str) for key in ('domain', 'certificate', 'path')):
            raise Problem('CDN 域名、证书或路径字段无效。')
        hostname(cdn['domain'])
        if cdn['domain'] == state['target']:
            raise Problem('CDN 域名与 REALITY 目标不能相同。')
        if any(type(cdn.get(key)) is not int for key in ('reality_internal', 'tls_internal', 'xhttp_internal')):
            raise Problem('CDN 内部端口必须保存为整数。')
        internals = [port_number(cdn[x]) for x in ('reality_internal', 'tls_internal', 'xhttp_internal')]
        if len(set(internals)) != 3 or set(internals) & set(ports):
            raise Problem('CDN 内部端口冲突。')
        if not re.fullmatch(r'/[a-f0-9]{32}/', cdn['path']):
            raise Problem('CDN 路径数据无效。')
        if Path(cdn['certificate']) != ROOT / 'acme/config/live' / ('xray-manager-' + cdn['domain']):
            raise Problem('证书必须由本脚本的独立 ACME 目录管理。')
    core_path = Path(state['core_binary'])
    if not core_path.is_absolute() or '..' in core_path.parts or not str(core_path).startswith(str(LIB / 'versions') + '/') or core_path.name != 'xray':
        raise Problem('核心路径不在本脚本版本目录中。')


def http(url, headers=None, raw=False, timeout=20):
    request = urllib.request.Request(url, headers={'User-Agent': f'xray-manager/{VERSION}', **(headers or {})})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            content = response.read(8 * 1024 * 1024 + 1)
        if len(content) > 8 * 1024 * 1024:
            raise Problem('远端元数据过大。')
        return content if raw else json.loads(content)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        code = getattr(exc, 'code', None)
        raise Problem(f'网络请求失败：{urllib.parse.urlsplit(url).hostname}' + (f'，HTTP {code}' if code else '') + '。可返回菜单重试。') from None


def target_check(target):
    context = ssl.create_default_context()
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.set_alpn_protocols(['h2'])
    try:
        with socket.create_connection((target, 443), timeout=8) as sock:
            with context.wrap_socket(sock, server_hostname=target) as secure:
                if secure.selected_alpn_protocol() != 'h2':
                    raise Problem('目标站点没有协商 HTTP/2，请更换 REALITY 目标域名。')
    except (OSError, ssl.SSLError):
        raise Problem('REALITY 目标的 TLS 1.3/证书检测失败，请更换目标或检查 VPS 出站网络。') from None


def listeners():
    return run(['ss', '-H', '-ltnp'], check=False).stdout or ''


def ensure_free(port):
    lines = [line for line in listeners().splitlines() if re.search(rf':{port}\s', line)]
    if lines:
        raise Problem(f'端口 {port} 已被占用：\n' + '\n'.join(lines))


def ensure_platform():
    if sys.version_info < (3, 9):
        raise Problem('需要 Python 3.9+；建议 Debian 12+ 或 Ubuntu 22.04+。')
    if platform.system() != 'Linux' or os.geteuid() != 0:
        raise Problem('请在 Debian/Ubuntu VPS 上使用 sudo/root 运行。--help 可以在本机查看。')
    os_release = Path('/etc/os-release').read_text()
    found = re.search(r'^ID=(.*)$', os_release, re.M)
    if not found or found.group(1).strip('"') not in ('debian', 'ubuntu'):
        raise Problem('首版只支持 Debian/Ubuntu。')
    if platform.machine() not in ('x86_64', 'aarch64', 'arm64'):
        raise Problem('首版只支持 x86_64 / ARM64。')
    if not Path('/run/systemd/system').exists():
        raise Problem('需要正在运行 systemd 的 VPS，不支持普通 Docker 容器。')


def owned_directory(path, mode):
    path = Path(path)
    if path.is_symlink() or path.exists() and (not path.is_dir() or path.stat().st_uid != os.geteuid()):
        raise Problem(f'目录不是当前管理员拥有的普通目录：{path}，停止操作。')
    path.mkdir(parents=True, exist_ok=True, mode=mode)
    path.chmod(mode)  # mkdir mode is filtered by umask; chmod restores intended group access.


def lock():
    global LOCK
    owned_directory(ROOT, 0o700)
    for path in (CONF, LIB):
        if path.is_symlink() or path.exists() and (not path.is_dir() or path.stat().st_uid != os.geteuid()):
            raise Problem(f'受管理路径归属异常：{path}，停止操作。')
    LOCK = open(ROOT / 'manager.lock', 'a+')
    try:
        fcntl.flock(LOCK, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise Problem('另一个管理进程正在运行，请稍后重试。') from None


@contextmanager
def deployment_lock():
    global DEPLOY_LOCK
    if DEPLOY_LOCK is not None:
        yield  # backup/restore are also used inside an already locked transaction.
        return
    file = open(ROOT / 'deployment.lock', 'a+')
    try:
        try:
            fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Problem('证书续期或部署变更正在进行，请稍后重试。') from None
        DEPLOY_LOCK = file
        yield
    finally:
        DEPLOY_LOCK = None
        file.close()


def deployment_locked(function):
    @functools.wraps(function)
    def wrapped(*args, **kwargs):
        with deployment_lock():
            return function(*args, **kwargs)
    return wrapped


def apt_install(packages):
    say('安装依赖：' + ', '.join(packages))
    run(['apt-get', 'update'], capture=False, timeout=600)
    run(['apt-get', 'install', '-y', '--no-install-recommends', *packages], capture=False,
        timeout=900, env={**os.environ, 'DEBIAN_FRONTEND': 'noninteractive'})


def base_dependencies():
    packages = {'curl': 'curl', 'openssl': 'openssl', 'ss': 'iproute2', 'flock': 'util-linux'}
    missing = sorted({package for command, package in packages.items() if not shutil.which(command)})
    if not Path('/etc/ssl/certs/ca-certificates.crt').exists():
        missing.append('ca-certificates')
    if missing:
        if not confirm('菜单需要安装以下基础依赖：' + ', '.join(missing)):
            raise Problem('缺少依赖，已退出。')
        apt_install(missing)


def detect_addresses():
    result = {}
    for family, url in (('IPv4', 'https://api4.ipify.org'), ('IPv6', 'https://api6.ipify.org')):
        output = run(['curl', '-4' if family == 'IPv4' else '-6', '-fsS', '--connect-timeout', '3', '--max-time', '5', url], check=False).stdout or ''
        try:
            address = ipaddress.ip_address(output.strip())
            if address.is_global:
                result[family] = str(address)
        except ValueError:
            pass
    return result


def release(tag=None):
    suffix = 'latest' if not tag else 'tags/' + urllib.parse.quote(tag, safe='')
    data = http(API + 'XTLS/Xray-core/releases/' + suffix)
    if data.get('draft') or data.get('prerelease') and tag is None:
        raise Problem('Latest 不是正式发布版本，请手动选择明确版本。')
    if not re.fullmatch(r'v\d+(?:\.\d+){2}(?:-\d+)?', data.get('tag_name', '')):
        raise Problem('官方版本号格式无法识别。')
    return data


def download_core(info):
    arch = '64' if platform.machine() == 'x86_64' else 'arm64-v8a'
    asset_name = f'Xray-linux-{arch}.zip'
    tag = info['tag_name']
    asset = next((x for x in info['assets'] if x['name'] == asset_name), None)
    if asset is None:
        raise Problem('该版本没有对应架构的 Linux 下载包。')
    digest = asset.get('digest') or ''
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', digest):
        raise Problem('官方发布缺少 SHA-256 摘要，本脚本拒绝跳过校验。')
    owned_directory(LIB, 0o755)
    versions = LIB / 'versions'
    versions.mkdir(exist_ok=True)
    versions.chmod(0o755)
    destination = versions / f'{tag}-{arch}-{digest[7:19]}'
    # Never trust an already existing version directory without re-verification.
    with tempfile.TemporaryDirectory(prefix='download-', dir=ROOT) as directory:
        archive = Path(directory) / 'core.zip'
        url = f'https://github.com/XTLS/Xray-core/releases/download/{tag}/{asset_name}'
        run(['curl', '-fL', '--retry', '2', '--connect-timeout', '15', '--max-time', '300', url, '-o', archive], capture=False, timeout=330)
        if sha(archive) != digest[7:]:
            raise Problem('下载包 SHA-256 不匹配；当前部署未改变。')
        with zipfile.ZipFile(archive) as zipped:
            binary = zipped.read('xray')
        binary_hash = hashlib.sha256(binary).hexdigest()
        # New unique directory avoids overwriting an active core on repeated downloads.
        destination = Path(str(destination) + '-' + secrets.token_hex(3))
        destination.mkdir(mode=0o755)
        destination.chmod(0o755)
        path = destination / 'xray'
        path.write_bytes(binary)
        path.chmod(0o755)
        output = run([path, 'version']).stdout
        if not output.startswith('Xray ' + tag[1:] + ' '):
            raise Problem('下载核心报告的版本与发布标签不一致。')
    return str(path), binary_hash


def new_keys(binary):
    output = run([binary, 'x25519']).stdout
    private = re.search(r'^Private\s*Key:\s*(\S+)', output, re.M | re.I)
    public = re.search(r'^(?:Password\s*\(PublicKey\)|Public\s*Key):\s*(\S+)', output, re.M | re.I)
    if not private or not public:
        raise Problem('无法识别 xray x25519 输出；请检查核心版本。')
    return private.group(1), public.group(1)


def permitted(state, profile):
    return [x for x in state['users'] if profile in x['profiles']]


def server_config(state):
    cdn = state['profiles'].get('cdn')
    inbounds = []
    for name, item in state['profiles'].items():
        if name == 'cdn':
            inbound = {'tag': 'managed-cdn', 'listen': '127.0.0.1', 'port': item['xhttp_internal'],
                       'protocol': 'vless', 'settings': {'decryption': 'none', 'clients': [{'id': x['id']} for x in permitted(state, name)]},
                       'streamSettings': {'network': 'xhttp', 'security': 'none', 'xhttpSettings': {'path': item['path'], 'mode': 'auto'}}}
        else:
            fronted = name == 'direct' and cdn and item['port'] == 443
            inbound = {'tag': 'managed-' + name, 'listen': '127.0.0.1' if fronted else state['listen'],
                       'port': cdn['reality_internal'] if fronted else item['port'], 'protocol': 'vless',
                       'settings': {'decryption': 'none', 'clients': []},
                       'streamSettings': {'network': 'raw' if name == 'vision' else 'xhttp', 'security': 'reality',
                                          'realitySettings': {'show': False, 'target': state['target'] + ':443', 'serverNames': [state['target']],
                                                              'privateKey': state['private_key'], 'shortIds': [state['short_id']],
                                                              'limitFallbackUpload': {'afterBytes': 1048576, 'bytesPerSec': 65536, 'burstBytesPerSec': 131072},
                                                              'limitFallbackDownload': {'afterBytes': 1048576, 'bytesPerSec': 65536, 'burstBytesPerSec': 131072}}}}
            for user in permitted(state, name):
                client = {'id': user['id'], 'email': user['name'] + '@local.invalid'}
                if name == 'vision':
                    client['flow'] = 'xtls-rprx-vision'
                inbound['settings']['clients'].append(client)
            if name == 'direct':
                inbound['streamSettings']['xhttpSettings'] = {'path': state['path'], 'mode': 'auto'}
        inbounds.append(inbound)
    return {'log': {'loglevel': 'warning'}, 'inbounds': inbounds, 'outbounds': [{'tag': 'direct', 'protocol': 'freedom'}]}


def client_config(state, name, user, address=None, socks_port=10808):
    item = state['profiles'][name]
    stream = {'network': 'raw' if name == 'vision' else 'xhttp', 'security': 'tls' if name == 'cdn' else 'reality'}
    if name == 'cdn':
        stream.update({'tlsSettings': {'serverName': item['domain'], 'alpn': ['h2'], 'fingerprint': 'chrome'},
                       'xhttpSettings': {'path': item['path'], 'mode': 'stream-up'}})
    else:
        stream['realitySettings'] = {'serverName': state['target'], 'fingerprint': 'chrome', 'publicKey': state['public_key'], 'shortId': state['short_id']}
        if name == 'direct':
            stream['xhttpSettings'] = {'path': state['path'], 'mode': 'auto'}
    account = {'id': user['id'], 'encryption': 'none'}
    if name == 'vision':
        account['flow'] = 'xtls-rprx-vision'
    outbound = {'tag': 'proxy', 'protocol': 'vless', 'settings': {'vnext': [{'address': address or (item['domain'] if name == 'cdn' else state['address']),
                                                                        'port': item['port'], 'users': [account]}]}, 'streamSettings': stream}
    return {'log': {'loglevel': 'warning'}, 'inbounds': [{'listen': '127.0.0.1', 'port': socks_port, 'protocol': 'socks', 'settings': {'auth': 'noauth', 'udp': True}}], 'outbounds': [outbound]}


def share_link(state, name, user):
    item = state['profiles'][name]
    address = item['domain'] if name == 'cdn' else state['address']
    host = '[' + address + ']' if ':' in address else address
    query = {'encryption': 'none', 'security': 'tls' if name == 'cdn' else 'reality',
             'type': 'tcp' if name == 'vision' else 'xhttp', 'sni': item['domain'] if name == 'cdn' else state['target'], 'fp': 'chrome'}
    if name == 'cdn':
        query.update({'alpn': 'h2', 'path': item['path'], 'mode': 'stream-up'})
    else:
        query.update({'pbk': state['public_key'], 'sid': state['short_id']})
        if name == 'vision':
            query['flow'] = 'xtls-rprx-vision'
        else:
            query.update({'path': state['path'], 'mode': 'auto'})
    return f"vless://{user['id']}@{host}:{item['port']}?{urllib.parse.urlencode(query)}#{urllib.parse.quote(user['name'] + '-' + name)}"


def nginx_config(state):
    cdn = state['profiles']['cdn']
    # Values are validated domains, integer ports and manager-owned paths, not shell fragments.
    default_backend = '127.0.0.1:' + str(cdn['reality_internal']) if state['profiles']['direct']['port'] == 443 else '""'
    ipv6 = 'listen [::]:443 ipv6only=on;' if state['listen'] == '::' else ''
    cert = cdn['certificate']
    return f'''load_module /usr/lib/nginx/modules/ngx_stream_module.so;
user www-data;
worker_processes auto;
pid /run/xray-manager-nginx.pid;
error_log stderr warn;
events {{ worker_connections 2048; }}
stream {{
    map $ssl_preread_server_name $backend {{
        {cdn['domain']} 127.0.0.1:{cdn['tls_internal']};
        default {default_backend};
    }}
    server {{
        listen 0.0.0.0:443;
        {ipv6}
        ssl_preread on;
        proxy_pass $backend;
        proxy_connect_timeout 10s;
        proxy_timeout 1h;
    }}
}}
http {{
    access_log off;
    client_body_temp_path {CACHE}/client;
    proxy_temp_path {CACHE}/proxy;
    server {{
        listen 127.0.0.1:{cdn['tls_internal']} ssl http2;
        server_name {cdn['domain']};
        ssl_certificate {cert}/fullchain.pem;
        ssl_certificate_key {cert}/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        client_max_body_size 0;
        location ^~ {cdn['path']} {{
            grpc_pass grpc://127.0.0.1:{cdn['xhttp_internal']};
            grpc_set_header Host $host;
            grpc_read_timeout 1h;
            grpc_send_timeout 1h;
        }}
        location / {{ return 404; }}
    }}
}}
'''


def unit_files(cdn=False):
    files = {CORE_UNIT: f'''[Unit]
Description=Xray Manager Core
After=network-online.target
Wants=network-online.target
[Service]
User=xray-manager
Group=xray-manager
ExecStart={LIB}/current/xray run -config {CONF}/xray.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
[Install]
WantedBy=multi-user.target
'''}
    if cdn:
        files[FRONT_UNIT] = f'''[Unit]
Description=Xray Manager SNI and TLS Front
After=network-online.target {CORE_UNIT}
Wants=network-online.target {CORE_UNIT}
[Service]
ExecStartPre=/usr/sbin/nginx -t -c {CONF}/nginx.conf
ExecStart=/usr/sbin/nginx -c {CONF}/nginx.conf -g "daemon off;"
ExecReload=/usr/sbin/nginx -c {CONF}/nginx.conf -s reload
Restart=on-failure
RestartSec=3
PrivateTmp=true
ProtectHome=true
[Install]
WantedBy=multi-user.target
'''
        acme = ROOT / 'acme'
        files[RENEW_UNIT] = f'''[Unit]
Description=Renew Xray Manager Certificates
[Service]
Type=oneshot
ExecStart=/usr/bin/flock --nonblock --conflict-exit-code 75 {ROOT}/deployment.lock /usr/bin/certbot renew --quiet --config-dir {acme}/config --work-dir {acme}/work --logs-dir {acme}/logs --deploy-hook {CONF}/reload-front.sh
SuccessExitStatus=75
'''
        files[RENEW_TIMER] = f'''[Unit]
Description=Daily Xray Manager Certificate Check
[Timer]
OnCalendar=daily
OnUnitInactiveSec=6h
RandomizedDelaySec=6h
Persistent=true
[Install]
WantedBy=timers.target
'''
    return files


def render(state, destination):
    validate_state(state)
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    write(destination / 'xray.json', server_config(state), 0o640)
    for name, content in unit_files('cdn' in state['profiles']).items():
        write(destination / name, content, 0o644)
    if 'cdn' in state['profiles']:
        write(destination / 'nginx.conf', nginx_config(state), 0o640)
        write(destination / 'reload-front.sh', f'#!/bin/sh\nset -eu\nif systemctl is-active --quiet {FRONT_UNIT}; then\n  /usr/sbin/nginx -t -c {CONF}/nginx.conf\n  systemctl reload {FRONT_UNIT}\nfi\n', 0o700)
    exports = destination / 'exports'
    exports.mkdir(mode=0o700)
    for user in state['users']:
        for name in user['profiles']:
            write(exports / f"{user['name']}-{name}.json", client_config(state, name, user))
            write(exports / f"{user['name']}-{name}.txt", share_link(state, name, user) + '\n')


def check_candidate(state, directory):
    binary = Path(state['core_binary'])
    if not binary.is_file() or sha(binary) != state['core_binary_sha256']:
        raise Problem('核心文件缺失或摘要改变，停止应用。')
    run([binary, 'run', '-test', '-config', Path(directory) / 'xray.json'])
    for path in (Path(directory) / 'exports').glob('*.json'):
        run([binary, 'run', '-test', '-config', path])
    if 'cdn' in state['profiles']:
        run(['/usr/sbin/nginx', '-t', '-c', Path(directory) / 'nginx.conf'])


@deployment_locked
def backup(label):
    directory = ROOT / 'backups' / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + secrets.token_hex(3))
    directory.mkdir(parents=True, mode=0o700)
    state = load_state(required=False)
    if state:
        shutil.copy2(ROOT / 'state.json', directory / 'state.json')
    if CONF.exists():
        shutil.copytree(CONF, directory / 'conf')
    units = directory / 'units'
    units.mkdir()
    for name in OWN_UNITS:
        if (UNITS / name).exists():
            shutil.copy2(UNITS / name, units / name)
    services = {name: {'active': active(name), 'enabled': systemctl('is-enabled', name, check=False).returncode == 0} for name in OWN_UNITS}
    write(directory / 'metadata.json', {'label': label, 'version': state['core_version'] if state else None, 'services': services})
    return directory


def current_link(binary):
    LIB.mkdir(parents=True, exist_ok=True)
    temporary = LIB / ('.current-' + secrets.token_hex(4))
    temporary.symlink_to(Path(binary).parent)
    os.replace(temporary, LIB / 'current')


def restart_deployment(state):
    systemctl('daemon-reload', '')
    systemctl('enable', CORE_UNIT)
    systemctl('restart', CORE_UNIT)
    if 'cdn' in state['profiles']:
        systemctl('enable', FRONT_UNIT)
        systemctl('restart', FRONT_UNIT)
        systemctl('enable', RENEW_TIMER)
        systemctl('start', RENEW_TIMER)
    time.sleep(2)
    for name in (CORE_UNIT, FRONT_UNIT) if 'cdn' in state['profiles'] else (CORE_UNIT,):
        if not active(name):
            raise Problem(f'{name} 启动失败，请查看日志。')


def stop_managed():
    # Stop renewal first; its deploy hook must not reload a half-replaced frontend.
    for name in (RENEW_TIMER, RENEW_UNIT, FRONT_UNIT, CORE_UNIT):
        if (UNITS / name).exists() or active(name):
            systemctl('stop', name)


def ensure_account():
    group = run(['getent', 'group', 'xray-manager'], check=False)
    account = run(['getent', 'passwd', 'xray-manager'], check=False)
    owned = (ROOT / 'account-owned').exists() or (ROOT / 'state.json').exists()
    if not owned and (group.returncode == 0 or account.returncode == 0):
        raise Problem('发现已有同名用户或组，不自动授权其读取代理密钥。')
    if group.returncode == 0:
        fields = (group.stdout or '').strip().split(':')
        if len(fields) != 4 or fields[2] == '0' or fields[3]:
            raise Problem('专用组无效、具有 root GID 或包含其他成员。')
    if account.returncode == 0:
        fields = (account.stdout or '').strip().split(':')
        if len(fields) != 7 or fields[2] == '0' or fields[6] not in ('/usr/sbin/nologin', '/sbin/nologin', '/bin/false'):
            raise Problem('专用账户权限或登录 shell 异常。')
        if group.returncode != 0 or fields[3] != group.stdout.strip().split(':')[2]:
            raise Problem('专用账户与专用组不匹配。')
    write(ROOT / 'account-owned', 'Dedicated non-login account managed by xray-manager.\n')
    if group.returncode:
        run(['groupadd', '--system', 'xray-manager'])
    if account.returncode:
        run(['useradd', '--system', '--gid', 'xray-manager', '--no-create-home', '--home-dir', '/nonexistent', '--shell', '/usr/sbin/nologin', 'xray-manager'])


@deployment_locked
def restore(directory):
    directory = Path(directory)
    metadata = read_json(directory / 'metadata.json')
    if (directory / 'state.json').exists():
        restored_state = read_json(directory / 'state.json')
        validate_state(restored_state)
        if not Path(restored_state['core_binary']).exists() or sha(restored_state['core_binary']) != restored_state['core_binary_sha256']:
            raise Problem('备份引用的核心文件缺失或已改变；尚未停止当前服务。')
    stop_managed()
    for name in OWN_UNITS:
        if (UNITS / name).exists():
            systemctl('disable', name)
    if CONF.exists():
        shutil.rmtree(CONF)
    if (directory / 'conf').exists():
        shutil.copytree(directory / 'conf', CONF)
        CONF.chmod(0o750)
        # copytree preserves modes but not ownership; the unprivileged core needs its group.
        shutil.chown(CONF, group='xray-manager')
        for name in ('xray.json', 'nginx.conf'):
            if (CONF / name).exists():
                shutil.chown(CONF / name, group='xray-manager')
    for name in OWN_UNITS:
        path = UNITS / name
        path.unlink(missing_ok=True)
        if (directory / 'units' / name).exists():
            shutil.copy2(directory / 'units' / name, path)
    if (directory / 'state.json').exists():
        state = read_json(directory / 'state.json')
        if not Path(state['core_binary']).exists() or sha(state['core_binary']) != state['core_binary_sha256']:
            raise Problem('备份引用的核心文件缺失或已改变，需要人工恢复。')
        current_link(state['core_binary'])
        shutil.copy2(directory / 'state.json', ROOT / 'state.json')
    else:
        (ROOT / 'state.json').unlink(missing_ok=True)
        (LIB / 'current').unlink(missing_ok=True)
    systemctl('daemon-reload', '')
    for name in OWN_UNITS:
        previous = metadata['services'][name]
        if previous['enabled']:
            systemctl('enable', name)
        if previous['active']:
            systemctl('start', name)


def proxy_probe(state, name, external=False):
    user = permitted(state, name)[0]
    with socket.socket() as port_socket:
        port_socket.bind(('127.0.0.1', 0))
        port = port_socket.getsockname()[1]
    with tempfile.TemporaryDirectory(prefix='probe-', dir=ROOT) as directory:
        config = Path(directory) / 'client.json'
        client = client_config(state, name, user, None if external else '127.0.0.1', port)
        probe_user, probe_password = secrets.token_hex(16), secrets.token_hex(24)
        client['inbounds'][0]['settings'].update(auth='password', accounts=[{'user': probe_user, 'pass': probe_password}])
        write(config, client)
        log = Path(directory) / 'client.log'
        with log.open('w') as output:
            process = subprocess.Popen([state['core_binary'], 'run', '-config', str(config)], stdout=output, stderr=subprocess.STDOUT)
            try:
                ready = False
                for _ in range(30):
                    if process.poll() is not None:
                        break
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=0.2):
                            ready = True
                        break
                    except OSError:
                        time.sleep(0.1)
                if not ready:
                    raise Problem('临时测试客户端无法启动。')
                # Private stdin config keeps temporary SOCKS credentials out of process arguments.
                run(['curl', '--config', '-', '--fail', '--silent', '--show-error', '--noproxy', '', '--proxy', f'socks5h://127.0.0.1:{port}',
                     '--connect-timeout', '10', '--max-time', '25', '-o', '/dev/null', TEST_URL], timeout=30,
                    input=f'proxy-user = "{probe_user}:{probe_password}"\n')
                if process.poll() is not None:
                    raise Problem('临时客户端已退出，连接测试结果无效。')
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def health(state):
    for name in state['profiles']:
        say(f'验证 {name} 本机完整代理连接……')
        proxy_probe(state, name)
    if 'cdn' in state['profiles']:
        say('验证经过 Cloudflare 的完整代理连接……')
        proxy_probe(state, 'cdn', external=True)


def drift_check(state):
    if not Path(state['core_binary']).is_file() or sha(state['core_binary']) != state['core_binary_sha256']:
        raise Problem('核心文件缺失或摘要改变，请从备份恢复。')
    if not (LIB / 'current').is_symlink() or (LIB / 'current').resolve() != Path(state['core_binary']).parent.resolve():
        raise Problem('核心版本符号链接发生外部修改，请先核查。')
    for path, expected in state.get('manifest', {}).items():
        if not Path(path).is_file() or sha(path) != expected:
            raise Problem(f'检测到脚本外修改：{path}。请先备份并恢复受管理文件，避免覆盖你的修改。')


def firewall(state, tag):
    # Rules are additive; never enable/reset UFW or modify SSH rules.
    if not shutil.which('ufw'):
        return
    output = run(['ufw', 'status']).stdout or ''
    if 'Status: active' not in output:
        return
    for port in sorted({x['port'] for x in state['profiles'].values()}):
        # Leave any existing global rule (including an explicit deny) untouched.
        existing = re.search(rf'(?m)^{port}/tcp(?:\s+\(v6\))?\s+([^\n]+)', output)
        if existing:
            if not re.search(r'\bALLOW(?: IN)?\s+Anywhere(?:\s|$)', existing.group(1)):
                raise Problem(f'UFW 已有 TCP {port} 的拒绝或受限来源规则，请先人工核查。')
            continue
        run(['ufw', 'allow', f'{port}/tcp', 'comment', tag])


def remove_added_rules(tag):
    if not shutil.which('ufw'):
        return
    # Unique transaction comments identify exactly the rules added by this operation.
    output = run(['ufw', 'status', 'numbered']).stdout or ''
    numbers = []
    for line in output.splitlines():
        match = re.match(r'^\[\s*(\d+)\]', line)
        if match and line.rstrip().endswith('# ' + tag):
            numbers.append(int(match.group(1)))
    for number in sorted(numbers, reverse=True):
        run(['ufw', '--force', 'delete', str(number)])


@deployment_locked
def apply(state, label):
    previous = load_state(required=False)
    if previous:
        drift_check(previous)
    with tempfile.TemporaryDirectory(prefix='candidate-', dir=ROOT) as directory:
        render(state, directory)
        check_candidate(state, directory)
        snapshot = backup(label)
        journal = ROOT / 'transaction.json'
        ufw_tag = 'xray-manager-' + secrets.token_hex(8)
        write(journal, {'backup': str(snapshot), 'label': label, 'ufw_tag': ufw_tag})
        try:
            ensure_account()
            stop_managed()
            if CONF.exists():
                shutil.rmtree(CONF)
            owned_directory(CONF, 0o750)
            shutil.chown(CONF, group='xray-manager')
            managed = {}
            for path in Path(directory).iterdir():
                if path.name.endswith(('.service', '.timer')):
                    target = UNITS / path.name
                else:
                    target = CONF / path.name
                if path.is_dir():
                    shutil.copytree(path, target)
                    for exported in target.rglob('*'):
                        if exported.is_file():
                            managed[str(exported)] = sha(exported)
                else:
                    shutil.copy2(path, target)
                    if target.parent == CONF and target.suffix in ('.json', '.conf'):
                        shutil.chown(target, group='xray-manager')
                    managed[str(target)] = sha(target)
            for name in OWN_UNITS:
                if name not in unit_files('cdn' in state['profiles']):
                    systemctl('disable', name, check=False)
                    (UNITS / name).unlink(missing_ok=True)
            current_link(state['core_binary'])
            restart_deployment(state)
            firewall(state, ufw_tag)
            health(state)
            state['manifest'] = managed
            state['manager_version'] = VERSION
            write(ROOT / 'state.json', state)
            save_manager()
            journal.unlink()  # Last commit step: earlier failures still leave a durable recovery record.
            say(f'操作成功；备份：{snapshot.name}')
            say('云平台安全组仍需允许 TCP：' + ', '.join(str(x) for x in sorted({p['port'] for p in state['profiles'].values()})))
            say('本机自测已通过；你所在网络到 VPS 的连通性仍需客户端实测。')
        except BaseException:
            say('变更失败或被中断，正在恢复原部署……')
            try:
                restore(snapshot)
                remove_added_rules(ufw_tag)
                journal.unlink(missing_ok=True)
                say('已恢复原配置及服务状态；新装依赖、已签发证书和 Cloudflare 后台设置不自动撤销。')
            except BaseException as exc:
                say(f'自动恢复未完成：{exc}\n恢复记录：{journal}。下次启动会要求先恢复。')
            raise


def save_manager():
    source = Path(os.environ.get('XRAY_MANAGER_SOURCE', ''))
    if source.is_file() and not MANAGER.exists() and source.resolve() != MANAGER.resolve():
        write(MANAGER, source.read_text(), 0o755)


def foreign_install():
    if load_state(required=False):
        return
    suspects = [p for p in ('/usr/local/etc/xray/config.json', '/etc/xray/config.json', '/usr/local/x-ui/bin/xray-linux-amd64', '/etc/sing-box/config.json') if Path(p).exists()]
    if shutil.which('xray') or active('xray.service') or active('x-ui.service') or active('sing-box.service'):
        suspects.append('已有代理核心或服务')
    if CONF.exists() or any((UNITS / x).exists() for x in OWN_UNITS):
        suspects.append('本脚本配置残留但缺少状态数据')
    if suspects:
        raise Problem('发现已有部署，首版不自动接管：' + ', '.join(suspects))


def installation():
    state = load_state(required=False)
    if state:
        drift_check(state)
        say('已安装：保留所有身份和配置，不下载新核心。')
        if confirm('检查当前配置、启动未运行的服务并执行连通测试？'):
            run([state['core_binary'], 'run', '-test', '-config', CONF / 'xray.json'])
            for unit in (CORE_UNIT, FRONT_UNIT, RENEW_TIMER) if 'cdn' in state['profiles'] else (CORE_UNIT,):
                systemctl('enable', unit)
                if not active(unit):
                    systemctl('start', unit)
            health(state)
        return
    foreign_install()
    addresses = detect_addresses()
    address = server_address(ask('客户端连接地址（自动检测结果可修改）', addresses.get('IPv4') or addresses.get('IPv6')))
    port = port_number(ask('XHTTP + REALITY 公网端口', 443))
    ensure_free(port)
    target = prompt_target()
    info = release()
    if not confirm(f"首次安装 XHTTP + REALITY\n地址：{address}:{port}\n目标：{target}:443\n核心：{info['tag_name']}\n将创建专用服务、系统用户和受限配置；生成全新 UUID/密钥。"):
        return
    binary, digest = download_core(info)
    private, public = new_keys(binary)
    state = {'schema': SCHEMA, 'core_version': info['tag_name'], 'core_binary': binary, 'core_binary_sha256': digest,
             'address': address, 'listen': '::' if Path('/proc/net/if_inet6').exists() and Path('/proc/net/if_inet6').read_text().strip() else '0.0.0.0',
             'target': target, 'private_key': private, 'public_key': public, 'short_id': secrets.token_hex(8), 'path': '/' + secrets.token_hex(16) + '/',
             'profiles': {'direct': {'port': port}}, 'users': [{'name': 'default', 'id': str(uuid.uuid4()), 'profiles': ['direct']}]}
    apply(state, '首次安装')
    export_menu()


def upgrade_core():
    state = load_state()
    info = release()
    say(f"当前：{state['core_version']}；官方 Latest：{info['tag_name']}")
    say('发布说明：https://github.com/XTLS/Xray-core/releases/tag/' + info['tag_name'])
    tag = ask('输入版本号；回车使用 Latest', info['tag_name'])
    if not re.fullmatch(r'v\d+(?:\.\d+){2}(?:-\d+)?', tag):
        raise Problem('版本格式示例：v26.10.21。')
    if tag == state['core_version']:
        say('已经是此版本，无需升级。')
        return
    if tag != info['tag_name']:
        info = release(tag)
    if not confirm(f"将核心 {state['core_version']} → {tag}；短暂重连；保留入口、用户、UUID 和密钥。\n将校验所有客户端配置并逐个测试入口，失败回退。\n指定旧版本可能与新客户端不兼容，请先查看该版本发布说明。"):
        return
    binary, digest = download_core(info)
    state.update(core_version=tag, core_binary=binary, core_binary_sha256=digest)
    apply(state, '核心升级')


def authorize(state, name):
    names = ','.join(x['name'] for x in state['users'])
    selected = ask('为哪些用户开放新入口？逗号分隔', names).split(',')
    selected = {x.strip() for x in selected}
    if not selected or selected - {x['name'] for x in state['users']}:
        raise Problem('包含不存在的用户名。')
    for user in state['users']:
        if user['name'] in selected:
            user['profiles'].append(name)


def vision_wizard():
    state = load_state()
    if 'vision' in state['profiles']:
        say('Vision 入口已存在；请从配置菜单修改，从导出菜单获取连接。')
        return
    port = port_number(ask('Vision 公网端口', 2443))
    ensure_free(port)
    state['profiles']['vision'] = {'port': port}
    authorize(state, 'vision')
    if confirm(f'新增 RAW + REALITY + Vision，TCP {port}，flow=xtls-rprx-vision。\n原 XHTTP 地址、端口和凭据保持不变；服务会短暂重连。'):
        apply(state, '新增 Vision')


def draft_save(draft, step):
    draft['step'] = step
    write(ROOT / 'cdn-draft.json', draft)


def cdn_dependencies():
    nginx_present = shutil.which('nginx') is not None
    owned = (ROOT / 'nginx-owned').exists()
    if active('nginx.service'):
        raise Problem('系统 nginx.service 正在运行；不接管或停止其他网站服务。')
    if nginx_present and not owned:
        raise Problem('已有非本脚本管理的 Nginx。首版不自动改动，请使用干净环境或先人工解决冲突。')
    if Path('/etc/nginx/nginx.conf').exists() and not owned:
        raise Problem('发现已有 Nginx 配置，不自动安装或改动其服务。')
    packages = ['nginx-core', 'libnginx-mod-stream', 'certbot', 'python3-certbot-dns-cloudflare']
    runtime_mask = Path('/run/systemd/system/nginx.service')
    if runtime_mask.exists() or runtime_mask.is_symlink():
        raise Problem('发现已有 Nginx runtime unit/mask；请先检查 systemctl status nginx，确认后再处理，脚本不自动移除它。')
    # Mask only a not-yet-installed distro service to avoid the package claiming port 80.
    if not nginx_present:
        if (UNITS / 'nginx.service').exists() or active('nginx.service'):
            raise Problem('存在 Nginx 系统服务，停止自动安装。')
        write(ROOT / 'nginx-owned', 'Installation initiated by xray-manager; distro service must stay disabled.\n')
    masked = False
    try:
        # Mask also on retries: a previous apt failure may have installed the executable already.
        run(['systemctl', 'mask', '--runtime', 'nginx.service'])
        masked = True
        apt_install(packages)
        write(ROOT / 'nginx-owned', 'Installed by xray-manager; distro service is disabled.\n')
    finally:
        if masked:
            run(['systemctl', 'unmask', '--runtime', 'nginx.service'])
            # The distro unit is disabled after removing our mask; other masks are never touched.
            systemctl('disable', 'nginx.service', check=False)
    systemctl('disable', 'nginx.service')
    if not Path('/usr/lib/nginx/modules/ngx_stream_module.so').exists():
        raise Problem('Nginx stream 模块缺失。')
    # Keep nginx workers away from ROOT, whose 0700 mode protects all credentials.
    CACHE.mkdir(parents=True, exist_ok=True)
    CACHE.chmod(0o750)
    shutil.chown(CACHE, user='www-data', group='www-data')
    for name in ('client', 'proxy'):
        (CACHE / name).mkdir(exist_ok=True)
        shutil.chown(CACHE / name, user='www-data', group='www-data')


def acme_args():
    return ['--config-dir', ROOT / 'acme/config', '--work-dir', ROOT / 'acme/work', '--logs-dir', ROOT / 'acme/logs']


def cf_dns_check(domain):
    try:
        addresses = {x[4][0] for x in socket.getaddrinfo(domain, 443, type=socket.SOCK_STREAM)}
        ranges = []
        for family in ('v4', 'v6'):
            ranges.extend(ipaddress.ip_network(x) for x in http('https://www.cloudflare.com/ips-' + family, raw=True).decode().split())
    except (OSError, ValueError):
        raise Problem('域名或 Cloudflare IP 范围检测失败，请检查 DNS/网络后重试。') from None
    if not addresses or any(not any(ipaddress.ip_address(x) in network for network in ranges) for x in addresses):
        raise Problem('域名尚未解析到 Cloudflare 代理地址；检查橙云及 DNS 生效情况。')


def cdn_wizard():
    state = load_state()
    if 'cdn' in state['profiles']:
        say('CDN 入口已存在，可在诊断菜单检查、证书菜单测试续期；更换域名需先移除 CDN 入口后重新引导。')
        return
    draft_path = ROOT / 'cdn-draft.json'
    draft = read_json(draft_path) if draft_path.exists() else {}
    say('Cloudflare 向导：所有输入可用 q 返回；草稿会保存，下次继续。')
    if draft:
        say('已有草稿，进度：' + draft.get('step', '未知'))
    domain = hostname(ask('用于 CDN 的完整子域名', draft.get('domain')))
    if domain == state['target']:
        raise Problem('CDN 域名不能等于 REALITY 目标。')
    if draft.get('domain') and draft['domain'] != domain:
        draft.pop('credentials', None)
        draft.pop('path', None)
    draft['domain'] = domain
    if len(domain) > 240:
        raise Problem('CDN 域名过长，无法安全创建证书目录。')
    draft_save(draft, '域名已填写')
    say(f'步骤 1：在 Cloudflare 为 {domain} 设置 A/AAAA → VPS 的对应公网 IP，并开启橙云。')
    say('只填写 VPS 实际拥有的地址；没有 IPv6 时不要添加 AAAA。请使用专用子域名，避免影响网站。')
    say('步骤 2：SSL/TLS → Full (strict)；Network → gRPC 开启；为此子域名启用 HTTP/2，避免 Access/交互式挑战拦截代理路径。')
    if ask('后台已完成后输入 done 继续检测；q 保存返回', 'q').lower() != 'done':
        return
    cf_dns_check(domain)
    draft_save(draft, 'DNS 代理已检测，待证书')
    email = ask('证书通知邮箱', draft.get('email'))
    if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', email):
        raise Problem('邮箱格式不正确。')
    draft['email'] = email
    draft_save(draft, '邮箱已填写，待 Token')
    say('步骤 3：Cloudflare → My Profile → API Tokens → Edit zone DNS；仅授权当前域名区域的 DNS 编辑。')
    say('Token 仅用于 Certbot 的 DNS 验证和自动续期；在 VPS 本地隐藏输入，不要发到聊天中。')
    credential = Path(draft['credentials']) if draft.get('credentials') else None
    if credential and credential.is_file() and ask('复用草稿中保存的 Token？输入 no 可重新输入', 'yes').lower() == 'no':
        credential = None
    token = None
    if not credential or not credential.is_file():
        token = ask('Cloudflare API Token', secret=True)
        if not re.fullmatch(r'[A-Za-z0-9_-]{20,256}', token):
            raise Problem('Token 格式不正确。')
    port_map = {'reality_internal': 1443, 'tls_internal': 1444, 'xhttp_internal': 10080}
    if state['profiles']['direct']['port'] != 443:
        ensure_free(443)
    for key, default in port_map.items():
        value = port_number(ask('本机内部端口 ' + key, draft.get(key, default)))
        ensure_free(value)
        draft[key] = value
        draft_save(draft, '内部端口已填写：' + key)
    if len({draft[key] for key in port_map}) != 3 or {draft[key] for key in port_map} & {p['port'] for p in state['profiles'].values()} or 443 in {draft[key] for key in port_map}:
        raise Problem('内部端口相互冲突或与公网端口冲突，请返回重新选择；尚未安装依赖或申请证书。')
    draft_save(draft, '待确认安装证书和前端')
    if not confirm(f'新增 {domain}:443 的 XHTTP + TLS + Cloudflare 入口。\n将安装 Nginx/stream、Certbot/DNS 插件；向 CA 提交邮箱、同意其服务条款，并使用 Token 创建/清理 DNS 验证 TXT。\nNginx 按 SNI 分流 443；原 REALITY 公网地址和端口保持不变。内部监听仅限 127.0.0.1。\n会测试证书续期，并建立每日自动续期任务；服务切换时可能短暂重连。\nCloudflare 后台设置、已签发证书及新依赖不会随本地回退自动撤销。'):
        return
    if token:
        # Stable per-domain path also updates Certbot's saved renewal credential reference.
        credential = ROOT / 'credentials' / (hashlib.sha256(domain.encode()).hexdigest()[:24] + '.ini')
        credential.parent.mkdir(mode=0o700, exist_ok=True)
        write(credential, 'dns_cloudflare_api_token = ' + token + '\n')
        token = None
        draft['credentials'] = str(credential)
        draft_save(draft, 'Token 已保存，待证书')
    cdn_dependencies()
    cert_name = 'xray-manager-' + domain
    cert_dir = ROOT / 'acme/config/live' / cert_name
    say('申请/复用证书（DNS 传播可能需要等待）……')
    run(['certbot', 'certonly', *acme_args(), '--dns-cloudflare', '--dns-cloudflare-credentials', credential,
         '--dns-cloudflare-propagation-seconds', '60', '--cert-name', cert_name, '-d', domain, '--email', email,
         '--agree-tos', '--non-interactive', '--keep-until-expiring'], timeout=600, capture=False)
    draft_save(draft, '证书已签发，待续期测试和部署')
    run(['certbot', 'renew', *acme_args(), '--cert-name', cert_name, '--dry-run', '--non-interactive'], timeout=600, capture=False)
    state['profiles']['cdn'] = {'port': 443, 'domain': domain, 'certificate': str(cert_dir), 'credentials': str(credential),
                                'email': email, 'path': draft.get('path') or '/' + secrets.token_hex(16) + '/',
                                **{key: draft[key] for key in port_map}}
    draft['path'] = state['profiles']['cdn']['path']
    draft_save(draft, '证书和续期通过，待应用')
    authorize(state, 'cdn')
    if not confirm('证书和续期测试通过。现在应用分流配置并测试原节点、新 CDN 节点？'):
        return
    apply(state, '新增 Cloudflare CDN')
    draft_path.unlink(missing_ok=True)


def expansion_menu():
    choice = ask('扩展：1 Vision 备用入口；2 Cloudflare 完整向导；0 返回', '0')
    if choice == '1':
        vision_wizard()
    elif choice == '2':
        cdn_wizard()


def choose_user(state):
    say('用户：' + ', '.join(x['name'] for x in state['users']))
    name = ask('用户名', state['users'][0]['name'])
    user = next((x for x in state['users'] if x['name'] == name), None)
    if not user:
        raise Problem('用户不存在。')
    return user


def export_menu():
    state = load_state()
    user = choose_user(state)
    for name in user['profiles']:
        say('\n' + name + ':\n' + share_link(state, name, user))
        say('客户端 JSON：' + str(CONF / 'exports' / f"{user['name']}-{name}.json"))
    say('链接和客户端 JSON 都包含访问凭据，请自行保管。')


def users_menu():
    state = load_state()
    say('\n' + '\n'.join(x['name'] + ' → ' + ', '.join(x['profiles']) for x in state['users']))
    choice = ask('1 新增用户；2 删除用户；3 导出连接；0 返回', '0')
    if choice == '3':
        export_menu()
        return
    if choice == '1':
        name = ask('用户名（字母、数字、下划线、短横线，最多 32 字）')
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,32}', name) or any(x['name'] == name for x in state['users']):
            raise Problem('用户名格式无效或已存在。')
        profiles = [x.strip() for x in ask('允许的入口（逗号分隔）', ','.join(state['profiles'])).split(',')]
        state['users'].append({'name': name, 'id': str(uuid.uuid4()), 'profiles': list(dict.fromkeys(profiles))})
        validate_state(state)
        if confirm(f'新增用户 {name}，授权：{profiles}；现有用户凭据不变，服务短暂重连。'):
            apply(state, '新增用户')
    elif choice == '2':
        user = choose_user(state)
        state['users'].remove(user)
        validate_state(state)
        if confirm(f"删除用户 {user['name']}；其 {', '.join(user['profiles'])} 连接将失效，服务短暂重连。"):
            apply(state, '删除用户')


def configure():
    state = load_state()
    choice = ask('1 公网地址；2 REALITY 目标；3 入口端口；4 移除可选入口；0 返回', '0')
    if choice == '1':
        state['address'] = server_address(ask('新的公网地址', state['address']))
        impact = '直连和 Vision 的导入链接变化；客户端需要重新导入。'
    elif choice == '2':
        state['target'] = prompt_target(state['target'])
        impact = '所有 REALITY 客户端需要重新导入；UUID 和密钥保留。'
    elif choice == '3':
        name = ask('入口名称 direct 或 vision', 'direct')
        if name not in state['profiles'] or name == 'cdn':
            raise Problem('CDN 固定使用 443；请输入已存在的 direct/vision。')
        if name == 'direct' and 'cdn' in state['profiles']:
            raise Problem('启用 CDN 后暂不支持修改主入口端口；先移除 CDN，避免更改分流拓扑。')
        value = port_number(ask('新的公网端口', state['profiles'][name]['port']))
        if value == state['profiles'][name]['port']:
            say('端口未改变。')
            return
        ensure_free(value)
        state['profiles'][name]['port'] = value
        impact = f'{name} 客户端需要重新导入；请先放行云安全组 TCP {value}。'
    elif choice == '4':
        name = ask('移除 vision 或 cdn（不允许移除主入口）')
        if name not in ('vision', 'cdn') or name not in state['profiles']:
            raise Problem('入口不存在或不能移除。')
        del state['profiles'][name]
        for user in state['users']:
            user['profiles'] = [x for x in user['profiles'] if x != name]
        if any(not x['profiles'] for x in state['users']):
            raise Problem('有用户只授权了该入口；先处理这些用户后再移除。')
        impact = f'{name} 链接将失效。移除 CDN 时原 REALITY 恢复直接监听；证书、Token 文件保留，不撤销外部 DNS 设置。'
    else:
        return
    validate_state(state)
    if confirm(impact + '\n生效时服务会短暂重连；未由本脚本新增的防火墙规则不会删除。'):
        apply(state, '修改部署配置')


def backups_menu():
    choices = sorted((ROOT / 'backups').glob('*'), reverse=True) if (ROOT / 'backups').exists() else []
    if not choices:
        say('暂无备份。')
        return
    for index, directory in enumerate(choices[:30], 1):
        meta = read_json(directory / 'metadata.json')
        say(f"{index}. {directory.name}  {meta['label']}  {meta['version'] or '安装前空状态'}")
    value = ask('输入编号回退；b 新建手动备份；0 返回', '0')
    if value == 'b':
        if confirm('创建本地完整配置快照？快照包含私钥，保存于 root 专用目录。'):
            say('备份：' + str(backup('手动备份')))
        return
    if value == '0':
        return
    if not value.isdigit() or not 1 <= int(value) <= min(len(choices), 30):
        raise Problem('备份编号无效。')
    selected = choices[int(value) - 1]
    if not (selected / 'state.json').exists():
        raise Problem('此快照为安装前空状态。首版不提供菜单卸载，请选择有部署状态的快照。')
    target = read_json(selected / 'state.json')
    validate_state(target)
    if not Path(target['core_binary']).exists() or sha(target['core_binary']) != target['core_binary_sha256']:
        raise Problem('备份引用的核心文件缺失或被修改。')
    if not confirm(f'回退到 {selected.name}，核心 {target["core_version"]}；之后新增的用户/入口可能消失，旧链接可能恢复有效。\n回退前将另存当前快照；外部 DNS、证书签发和依赖包不撤销。'):
        return
    current = backup('回退前保护快照')
    journal = ROOT / 'transaction.json'
    ufw_tag = 'xray-manager-' + secrets.token_hex(8)
    write(journal, {'backup': str(current), 'label': '手动回退', 'ufw_tag': ufw_tag})
    try:
        restore(selected)
        if read_json(selected / 'metadata.json')['services'][CORE_UNIT]['active']:
            firewall(target, ufw_tag)
            health(target)
        else:
            say('该快照保存的是停服状态，已原样恢复；可从菜单 1 启动和检查。')
        journal.unlink()
        say('回退完成；已验证各入口。')
    except BaseException:
        say('目标快照验证失败，恢复回退前状态……')
        restore(current)
        remove_added_rules(ufw_tag)
        journal.unlink(missing_ok=True)
        raise


def update_manager():
    commit = http(API + REPO + '/commits/main')['sha']
    if not re.fullmatch(r'[a-f0-9]{40}', commit):
        raise Problem('仓库提交号格式无效。')
    metadata = http(API + REPO + '/contents/' + SCRIPT_PATH + '?ref=' + commit)
    if metadata.get('type') != 'file' or metadata.get('encoding') != 'base64':
        raise Problem('仓库尚未发布可识别的管理脚本。')
    content = base64.b64decode(metadata['content'])
    if hashlib.sha1(b'blob ' + str(len(content)).encode() + b'\0' + content).hexdigest() != metadata['sha']:
        raise Problem('脚本 Git blob 摘要不匹配。')
    text = content.decode('utf-8')
    version = re.search(r'^# XRAY_MANAGER_VERSION: ([0-9.]+)$', text, re.M)
    if not version:
        raise Problem('脚本缺少版本标记。')
    if version.group(1) == VERSION:
        say('管理脚本已是该版本。')
        return
    say(f"管理脚本：{VERSION} → {version.group(1)}\n来源：https://github.com/{REPO}/blob/{commit}/{SCRIPT_PATH}")
    if not confirm('仅更新本地管理脚本；不会自动更新核心。安装前保存当前脚本，替换后退出，下次启动生效。'):
        return
    with tempfile.TemporaryDirectory(prefix='script-', dir=ROOT) as directory:
        candidate = Path(directory) / 'xray-install.sh'
        write(candidate, text, 0o700)
        run(['bash', '-n', candidate])
        # New code runs only after explicit confirmation of its exact source commit.
        run(['bash', candidate, '--check-state'])
        if MANAGER.exists():
            saved = ROOT / 'script-backups' / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + secrets.token_hex(3) + '.sh')
            write(saved, MANAGER.read_text(), 0o700)
            say('上一版脚本：' + str(saved))
        write(MANAGER, text, 0o755)
    say('更新完成。下次运行 sudo xray-manager。')
    raise SystemExit(0)


def manager_menu():
    choice = ask('1 检查并更新管理脚本；2 回退管理脚本；0 返回', '0')
    if choice == '1':
        update_manager()
    elif choice == '2':
        files = sorted((ROOT / 'script-backups').glob('*.sh'), reverse=True) if (ROOT / 'script-backups').exists() else []
        if not files:
            say('暂无管理脚本备份。')
            return
        for index, path in enumerate(files[:30], 1):
            say(f'{index}. {path.name}')
        selection = ask('回退编号；0 返回', '0')
        if selection == '0':
            return
        if not selection.isdigit() or not 1 <= int(selection) <= min(30, len(files)):
            raise Problem('编号无效。')
        path = files[int(selection) - 1]
        if not confirm(f'将管理脚本回退到 {path.name}；先检查旧脚本能否读取当前状态。不会回退 Xray 核心。'):
            return
        run(['bash', '-n', path])
        run(['bash', path, '--check-state'])
        if MANAGER.exists():
            write(ROOT / 'script-backups' / ('before-rollback-' + secrets.token_hex(6) + '.sh'), MANAGER.read_text(), 0o700)
        write(MANAGER, path.read_text(), 0o755)
        say('管理脚本已回退，下次运行生效。')
        raise SystemExit(0)


def status(network=False):
    state = load_state(required=False)
    say(f'\nXray Manager {VERSION} | {platform.system()} {platform.release()} | {platform.machine()}')
    say('系统：' + next((x.split('=', 1)[1].strip('"') for x in Path('/etc/os-release').read_text().splitlines() if x.startswith('PRETTY_NAME=')), '未知'))
    if network:
        say('公网地址检测：' + str(detect_addresses()))
        try:
            latest = http(API + 'XTLS/Xray-core/releases/latest', timeout=5)['tag_name']
            say('官方 Latest：' + latest + ('（与当前版本不同；是否升级由菜单确认）' if state and state['core_version'] != latest else ''))
        except (Problem, KeyError):
            say('更新检查暂不可用，不影响本地管理。')
    if not state:
        say('部署：尚未安装。')
    else:
        say(f"核心：{state['core_version']} | 服务：{'运行中' if active(CORE_UNIT) else '未运行'} | 用户：{len(state['users'])}")
        for name, item in state['profiles'].items():
            say(f"  {name}: {(item.get('domain') or state['address'])}:{item['port']}")
        if 'cdn' in state['profiles']:
            say('前端：' + ('运行中' if active(FRONT_UNIT) else '未运行') + '；续期计时器：' + ('运行中' if active(RENEW_TIMER) else '未运行'))
    if shutil.which('ss'):
        say('监听端口：\n' + listeners())
    if (ROOT / 'cdn-draft.json').exists():
        say('存在未完成的 CDN 向导，可从菜单 3 继续。')
    if (ROOT / 'transaction.json').exists():
        say('存在中断事务，管理菜单将要求先恢复。')


def diagnostics():
    choice = ask('1 状态与公网信息；2 服务日志；3 配置/完整连接诊断；4 测试证书续期；0 返回', '0')
    if choice == '1':
        status(network=True)
    elif choice == '2':
        for name in (CORE_UNIT, FRONT_UNIT, RENEW_UNIT):
            say('\n' + name)
            say(run(['journalctl', '-u', name, '-n', '40', '--no-pager'], check=False).stdout)
    elif choice == '3':
        state = load_state()
        drift_check(state)
        run([state['core_binary'], 'run', '-test', '-config', CONF / 'xray.json'])
        target_check(state['target'])
        if 'cdn' in state['profiles']:
            cf_dns_check(state['profiles']['cdn']['domain'])
            run(['/usr/sbin/nginx', '-t', '-c', CONF / 'nginx.conf'])
        health(state)
        say('本机和已启用的 CDN 自测通过；请继续用自己的客户端测试实际网络。')
    elif choice == '4':
        state = load_state()
        if 'cdn' not in state['profiles']:
            raise Problem('尚未启用 CDN。')
        if confirm('向 ACME 测试环境执行证书续期演练？会临时创建并清理 DNS TXT 记录。'):
            run(['certbot', 'renew', *acme_args(), '--dry-run', '--non-interactive'], capture=False, timeout=600)


def recovery():
    path = ROOT / 'transaction.json'
    if not path.exists():
        return
    journal = read_json(path)
    snapshot = Path(journal['backup'])
    if snapshot.parent != ROOT / 'backups' or not (snapshot / 'metadata.json').exists():
        raise Problem('中断恢复记录无效，需要人工处理。')
    if not confirm(f"发现中断操作：{journal['label']}。必须先恢复到 {snapshot.name} 才能继续管理。"):
        raise Problem('尚未恢复中断操作，已退出。')
    restore(snapshot)
    if journal.get('ufw_tag'):
        remove_added_rules(journal['ufw_tag'])
    path.unlink()
    say('已恢复中断前的本地部署。外部 DNS、依赖包和签发证书请按实际情况检查。')


def main():
    global TTY
    os.umask(0o077)
    os.environ['PATH'] = os.environ.get('PATH', '/usr/bin:/bin') + ':/usr/local/sbin:/usr/sbin:/sbin'
    if len(sys.argv) > 2 or len(sys.argv) > 1 and sys.argv[1] not in ('--status', '--check-state'):
        raise Problem('未知参数；使用 --help 查看用法。')
    ensure_platform()
    if len(sys.argv) > 1:
        if sys.argv[1] == '--check-state':
            load_state(required=False)
            say('状态版本兼容。')
        else:
            status()
        return
    try:
        TTY = Terminal()
    except OSError:
        raise Problem('请在交互式 SSH 终端下载后执行脚本；不支持 curl | bash。') from None
    lock()
    recovery()
    base_dependencies()
    actions = {'1': installation, '2': upgrade_core, '3': expansion_menu, '4': users_menu, '5': configure,
               '6': backups_menu, '7': diagnostics, '8': manager_menu}
    status(network=True)
    while True:
        say('\n1 安装/检查现有部署  2 升级 Xray 核心  3 扩展接入方式  4 用户/导出连接')
        say('5 修改配置  6 备份/回退  7 日志/诊断/证书  8 更新管理脚本  0 退出（向导中 q 返回）')
        try:
            choice = ask('选择', '0')
            if choice == '0':
                break
            action = actions.get(choice)
            if action:
                action()
            else:
                say('无效菜单项。')
        except (Problem, ValueError, KeyError, OSError, zipfile.BadZipFile) as exc:
            say('\n操作未完成：' + str(exc))
        except KeyboardInterrupt:
            say('\n已中断当前操作。')
        # Do not allow further mutations after an unsuccessful automatic restore.
        if (ROOT / 'transaction.json').exists():
            raise Problem('仍有未完成恢复记录。请重新运行脚本先恢复；不能继续修改部署。')


if __name__ == '__main__':
    try:
        main()
    except (Problem, ValueError, KeyError, OSError, zipfile.BadZipFile) as exc:
        say('错误：' + str(exc))
        sys.exit(1)
    except (EOFError, KeyboardInterrupt):
        say('\n已退出；下次运行可继续菜单或恢复中断操作。')
        sys.exit(130)
XRAY_MANAGER_PY
