#!/usr/bin/env python3
"""Optional, passive daily traffic accounting for the VLESS node manager."""

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid

STATE = Path('/var/lib/vless-reality')
LOCKS = Path('/run/vless-reality')
PROGRAM = Path('/usr/local/sbin/vless_traffic')
UNIT_DIR = Path('/etc/systemd/system')
SYSTEMD_RUNTIME = Path('/run/systemd/system')
COMMON = Path('/usr/local/lib/vless-reality/common.sh')
TABLE = 'vr_daily_traffic'
TZ = dt.timezone(dt.timedelta(hours=8), 'Asia/Shanghai')
TAG_RE = re.compile(r'vless-temp-[A-Za-z0-9._-]{1,96}')
COUNTER_RE = re.compile(r't_([0-9a-f]{32})_([0-9a-f]{16})_([ud])')


def run(args, text=None):
    result = subprocess.run(args, input=text, text=True, capture_output=True,
                            timeout=30, check=False)
    if result.returncode:
        raise RuntimeError('{}: {}'.format(' '.join(args), result.stderr.strip()))
    return result.stdout


@contextlib.contextmanager
def locked(path, seconds=20):
    path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    with path.open('a') as stream:
        deadline = time.monotonic() + seconds
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise RuntimeError('锁繁忙：{}'.format(path))
                time.sleep(0.1)
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def atomic_write(path, content, mode=0o600):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(content)
            stream.flush()
            os.fchmod(stream.fileno(), mode)
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(str(path.parent), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def metadata(path):
    # Never source metadata as shell code; only read the fields we need.
    result = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        if '=' in line and not line.startswith('#'):
            key, value = line.split('=', 1)
            result.setdefault(key, value)
    return result


def discover(root, now):
    nodes = {}
    files = sorted((root / 'temp').glob('*.env'))
    main = root / 'main/main.env'
    if main.is_file():
        files.append(main)
    for path in files:
        meta = metadata(path)
        tag = 'main' if path == main else path.stem
        if tag != 'main':
            if not TAG_RE.fullmatch(tag) or meta.get('TAG') != tag:
                raise ValueError('非法节点 TAG：{}'.format(path))
            if int(meta['EXPIRE_EPOCH']) <= int(now.timestamp()):
                continue
        port = int(meta['PORT'])
        if not 1 <= port <= 65535:
            raise ValueError('非法端口：{}'.format(path))
        credential = str(uuid.UUID(meta['UUID']))
        # Reusing an ID/port must never inherit a previous user's history.
        identity = '{}|{}|{}|{}'.format(
            tag, port, credential, meta.get('CREATE_EPOCH', '') if tag != 'main' else '')
        nodes[tag] = {'tag': tag, 'port': port,
                      'key': hashlib.sha256(identity.encode()).hexdigest()[:32]}
    if len({node['port'] for node in nodes.values()}) != len(nodes):
        raise ValueError('多个节点占用同一端口，停止采集以避免记错用户')
    return nodes


class Nft:
    def snapshot(self):
        # A read/permission/JSON error is an error, never an empty snapshot.
        tables = json.loads(run(['nft', '-j', 'list', 'tables']))['nftables']
        exists = any(item.get('table', {}).get('name') == TABLE
                     and item['table'].get('family') == 'inet' for item in tables)
        if not exists:
            return []
        return json.loads(run(['nft', '-j', 'list', 'table', 'inet', TABLE]))['nftables']

    def apply(self, commands):
        if commands:
            # One atomic batch, restricted to our own passive table.
            run(['nft', '-f', '-'], '\n'.join(commands) + '\n')


def counters_in(snapshot):
    counters = {}
    for item in snapshot:
        counter = item.get('counter', {})
        name = counter.get('name', '')
        if COUNTER_RE.fullmatch(name):
            value = counter['bytes']
            if type(value) is not int or value < 0:
                raise ValueError('无法解析 nft counter：{}'.format(name))
            counters[name] = value
    return counters


def select_counters(nodes, users, counters):
    selected = {}
    for tag, node in nodes.items():
        for direction in ('u', 'd'):
            names = sorted(name for name in counters
                           if COUNTER_RE.fullmatch(name).groups()[::2]
                           == (node['key'], direction))
            previous = users.get(tag, {}).get('last', {}).get(direction, {}).get('name')
            selected[(tag, direction)] = previous if previous in names else (names[0] if names else None)
    return selected


def rule_matches(rule, chain, port, name):
    field = 'dport' if chain == 'input' else 'sport'
    expected = [
        {'match': {'op': '==', 'left': {'payload': {'protocol': 'tcp', 'field': field}},
                   'right': port}},
        {'counter': name},
    ]
    return (rule.get('chain') == chain and rule.get('comment') == name
            and rule.get('expr') == expected)


def reconcile(nodes, selected, snapshot, counters):
    commands = []
    exists = any(item.get('table', {}).get('name') == TABLE for item in snapshot)
    if not exists:
        commands.append('add table inet ' + TABLE)
    chains = {item['chain']['name']: item['chain'] for item in snapshot if 'chain' in item}
    for chain in ('input', 'output'):
        if chain not in chains:
            commands.append('add chain inet {} {} {{ type filter hook {} priority 10; policy accept; }}'
                            .format(TABLE, chain, chain))
        elif any(chains[chain].get(key) != value for key, value in
                 [('type', 'filter'), ('hook', chain), ('prio', 10), ('policy', 'accept')]):
            raise ValueError('统计链属性已被外部修改：{}'.format(chain))
    desired = []
    for tag, node in sorted(nodes.items()):
        for direction, chain in [('u', 'input'), ('d', 'output')]:
            name = selected[(tag, direction)]
            if name is None:
                # New generation names distinguish restored counters after a reboot
                # or deleted table, even if the new value already exceeds the old one.
                name = 't_{}_{}_{}'.format(node['key'], uuid.uuid4().hex[:16], direction)
                commands.append('add counter inet {} {}'.format(TABLE, name))
            desired.append((chain, node['port'], name))
    rules = [item['rule'] for item in snapshot if 'rule' in item]
    correct = (len(rules) == len(desired) and all(
        sum(rule_matches(rule, *wanted) for rule in rules) == 1 for wanted in desired))
    if not correct or not exists:
        commands += ['flush chain inet {} {}'.format(TABLE, chain) for chain in ('input', 'output')]
        for chain, port, name in desired:
            field = 'dport' if chain == 'input' else 'sport'
            commands.append('add rule inet {} {} tcp {} {} counter name {} comment "{}"'
                            .format(TABLE, chain, field, port, name, name))
    keep = {name for _, _, name in desired}
    commands += ['delete counter inet {} {}'.format(TABLE, name)
                 for name in counters if name not in keep]
    return commands


def load_state(path):
    if not path.exists():
        return {'version': 1, 'users': {}}
    result = json.loads(path.read_text(encoding='utf-8'))
    if result.get('version') != 1 or not isinstance(result.get('users'), dict):
        raise ValueError('不支持的统计文件格式：{}'.format(path))
    return result


def save_state(path, state):
    atomic_write(path, (json.dumps(state, ensure_ascii=False, sort_keys=True) + '\n').encode())


def prune(state, nodes, today):
    cutoff = (today - dt.timedelta(days=29)).isoformat()
    for tag in list(state['users']):
        record = state['users'][tag]
        if tag not in nodes or record['key'] != nodes[tag]['key']:
            del state['users'][tag]
            continue
        record['days'] = {day: value for day, value in record['days'].items()
                          if cutoff <= day <= today.isoformat()}


def collect(root=STATE, backend=None, now=None):
    backend = backend or Nft()
    now = now or dt.datetime.now(TZ)
    today = now.astimezone(TZ).date()
    path = root / 'traffic/daily.json'
    nodes = discover(root, now)
    state = load_state(path)
    before = json.dumps(state, sort_keys=True)
    prune(state, nodes, today)
    # Expired/deleted users and old days are removed even when nft reads fail.
    if json.dumps(state, sort_keys=True) != before:
        save_state(path, state)
    snapshot = backend.snapshot()
    counters = counters_in(snapshot)
    selected = select_counters(nodes, state['users'], counters)
    for tag, node in nodes.items():
        record = state['users'].setdefault(tag, dict(node, days={}, last={}))
        day = record['days'].setdefault(today.isoformat(), {'upload': 0, 'download': 0})
        for direction, column in [('u', 'upload'), ('d', 'download')]:
            name = selected[(tag, direction)]
            if name is None:
                continue
            value = counters[name]
            previous = record['last'].get(direction, {})
            delta = value
            if previous.get('name') == name and value >= previous['bytes']:
                delta -= previous['bytes']
            day[column] += delta
            record['last'][direction] = {'name': name, 'bytes': value}
        record['sampled_at'] = now.astimezone(TZ).isoformat(timespec='seconds')
    # Daily values AND baselines share one atomic commit. A failed write never
    # resets live counters, and retrying after a crash cannot double-count.
    save_state(path, state)
    backend.apply(reconcile(nodes, selected, snapshot, counters))
    return state


def show(state, selector=None, as_json=False):
    records = [record for tag, record in sorted(state['users'].items())
               if selector is None or selector in (tag, tag[len('vless-temp-'):] if
                   tag.startswith('vless-temp-') else tag, str(record['port']))]
    if selector is not None and not records:
        raise ValueError('未找到有效节点：{}'.format(selector))
    if as_json:
        # Raw byte counts for export; do not expose credentials or internal baselines.
        print(json.dumps({'timezone': 'Asia/Shanghai', 'users': [
            {key: record[key] for key in ('tag', 'port', 'days', 'sampled_at')}
            for record in records]}, ensure_ascii=False, indent=2))
        return
    print('北京时间 | 最近 30 个自然日 | 上传/下载均从用户视角计算')
    print('{:<28} {:>5}  {:10} {:>13} {:>13} {:>13}'.format(
        'TAG', 'PORT', 'DATE', 'UP(MiB)', 'DOWN(MiB)', 'TOTAL(MiB)'))
    for record in records:
        for day, value in sorted(record['days'].items(), reverse=True):
            up, down = value['upload'], value['download']
            print('{:<28} {:>5}  {} {:>13.3f} {:>13.3f} {:>13.3f}'.format(
                record['tag'], record['port'], day, up / 2**20, down / 2**20, (up + down) / 2**20))
    if not records:
        print('当前没有有效节点。')


def install():
    if not (STATE / 'temp').is_dir() or not COMMON.is_file():
        raise RuntimeError('请先安装本项目的 vless.sh 管理工具')
    run(['nft', '-j', 'list', 'tables'])
    if not SYSTEMD_RUNTIME.is_dir():
        raise RuntimeError('需要 systemd 环境')
    units = {
        'vless-traffic.service': '''[Unit]
Description=Collect daily VLESS traffic
After=local-fs.target nftables.service vless-managed-restore.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vless_traffic --collect
TimeoutStartSec=120
UMask=0077
''',
        'vless-traffic.timer': '''[Unit]
Description=Collect and prune daily VLESS traffic every minute

[Timer]
OnBootSec=30s
OnCalendar=*-*-* *:*:00
AccuracySec=1s
Persistent=true

[Install]
WantedBy=timers.target
''',
        'vless-traffic-shutdown.service': '''[Unit]
Description=Save daily VLESS traffic before shutdown
After=local-fs.target nftables.service vless-managed-restore.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/usr/local/sbin/vless_traffic --collect
TimeoutStopSec=120
UMask=0077

[Install]
WantedBy=multi-user.target
''',
    }
    timer = 'vless-traffic.timer'
    shutdown = 'vless-traffic-shutdown.service'
    with locked(LOCKS / 'traffic-install.lock'):
        targets = {PROGRAM: (Path(__file__).read_bytes(), 0o755)}
        targets.update({UNIT_DIR / name: (body.encode(), 0o644)
                        for name, body in units.items()})
        if any(path.is_symlink() for path in targets):
            raise RuntimeError('统计组件目标包含符号链接或 masked 单元，请先检查后再更新')
        old = {path: (path.read_bytes(), path.stat().st_mode & 0o777) if path.exists() else None
               for path in targets}
        enabled = {unit: subprocess.run(['systemctl', 'is-enabled', '--quiet', unit],
                                        capture_output=True).returncode == 0
                   for unit in (timer, shutdown)}
        active = {unit: subprocess.run(['systemctl', 'is-active', '--quiet', unit],
                                      capture_output=True).returncode == 0
                  for unit in (timer, shutdown)}
        try:
            # Stop only this optional module; Xray and existing quota/IP units
            # keep running. Shared temp.lock also serializes with node changes.
            existing_units = [unit for unit in (timer, 'vless-traffic.service', shutdown)
                              if old[UNIT_DIR / unit] is not None]
            if existing_units:
                run(['systemctl', 'stop'] + existing_units)
            with locked(LOCKS / 'temp.lock'), locked(LOCKS / 'traffic.lock'):
                for path, (content, mode) in targets.items():
                    atomic_write(path, content, mode)
                collect()
            run(['systemctl', 'daemon-reload'])
            run(['systemctl', 'enable', timer, shutdown])
            run(['systemctl', 'start', shutdown, timer])
            for unit in (shutdown, timer):
                run(['systemctl', 'is-active', '--quiet', unit])
        except Exception:
            subprocess.run(['systemctl', 'stop', timer, 'vless-traffic.service', shutdown],
                           capture_output=True, timeout=30)
            for unit in (timer, shutdown):
                subprocess.run(['systemctl', 'disable', unit], capture_output=True, timeout=30)
            for path, saved in old.items():
                if saved is None:
                    if path.exists():
                        path.unlink()
                else:
                    atomic_write(path, *saved)
            run(['systemctl', 'daemon-reload'])
            for unit, was_enabled in enabled.items():
                if was_enabled:
                    run(['systemctl', 'enable', unit])
            for unit, was_active in active.items():
                if was_active:
                    run(['systemctl', 'start', unit])
            raise
    print('每日流量记录已安装。查看全部：vless_traffic；按端口：vless_traffic 40000')


def main():
    parser = argparse.ArgumentParser(description='VLESS 每日流量记录（北京时间，保留 30 天）')
    parser.add_argument('selector', nargs='?', help='端口、节点 ID、完整 TAG 或 main')
    parser.add_argument('--json', action='store_true', help='输出每日字节数 JSON')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--collect', action='store_true', help='采集、轮换及清理，不显示列表')
    mode.add_argument('--install', action='store_true', help='安装或更新独立采集模块')
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('请以 root 身份运行')
    os.umask(0o077)
    if args.install:
        install()
        return
    with locked(LOCKS / 'temp.lock'), locked(LOCKS / 'traffic.lock'):
        state = collect()
    if not args.collect:
        show(state, args.selector, args.json)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print('流量记录失败：{}'.format(error), file=sys.stderr)
        sys.exit(1)
