#!/usr/bin/env python3
"""Standalone TCP+UDP shared port bandwidth policies. Owns only inet pbw_policy and tc filter slots.

No dependency on VLESS, SOCKS5, WireGuard, or any external node lifecycle.
Never changes a device root qdisc, BBR, iptables, or other nft tables.
"""
from __future__ import annotations
import argparse
from contextlib import contextmanager
from decimal import Decimal, InvalidOperation
import fcntl
import json
import math
import copy
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

STATE=Path(os.getenv('PORTBW_STATE','/var/lib/portbw'))
CONF=Path(os.getenv('PORTBW_CONF','/etc/portbw'))
LOCK=Path(os.getenv('PORTBW_LOCK','/run/portbw/manager.lock'))
UNITS=Path(os.getenv('PORTBW_UNITS','/etc/systemd/system'))
VOLATILE=Path(os.getenv('PORTBW_RUN','/run/portbw'))/'auto'
TABLE='pbw_policy'
CHAIN={'up':'inbound','down':'outbound'}
PORT_RE=re.compile(r'^[0-9]{1,5}$')
IF_RE=re.compile(r'^[a-zA-Z0-9_.-]{1,15}$')
# High handle namespace; legacy handle=port must NEVER be auto-adopted/deleted.
TC_HANDLE_PREFIX=0x0b700000
TC_POLICE_PREFIX=0x6d000000
FAMILIES=(4,6)
TRANSPORTS=('tcp','udp')
OWNED_RULE_RE=re.compile(r'^pbw-([1-9][0-9]{0,4})-(up|down)-(drop|count)$')

class Error(Exception):pass

def run(argv, *, input=None, check=True, timeout=25):
    try:
        res=subprocess.run([str(x) for x in argv], input=input, text=True,
                           capture_output=True, timeout=timeout,env=dict(os.environ,LC_ALL='C'))
    except (OSError,subprocess.TimeoutExpired) as e:
        if not check:return None
        raise Error(f'{argv[0]} 执行失败：{e}') from e
    if res.returncode:
        if not check:return None
        raise Error(f'{" ".join(map(str,argv))}：{res.stderr.strip()[:600]}')
    return res.stdout

def write_atomic(path, data, mode=0o600):
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    fd,temporary=tempfile.mkstemp(prefix='.'+path.name+'.',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as f:
            f.write(data);f.flush();os.fchmod(f.fileno(),mode);os.fsync(f.fileno())
        os.replace(temporary,path)
        fd=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(fd)
        finally:os.close(fd)
    finally:
        if os.path.lexists(temporary):os.unlink(temporary)

def write_json(p,obj):
    write_atomic(p,(json.dumps(obj,indent=2,ensure_ascii=False,sort_keys=True)+'\n').encode())

def read_json(p,default=None):
    if not p.exists():
        if default is not None:return default
        raise Error(f'缺少配置：{p}')
    if p.is_symlink():raise Error(f'拒绝符号链接：{p}')
    try:return json.loads(p.read_text(encoding='utf8'))
    except (ValueError,OSError) as e:raise Error(f'状态不能解析：{p} ({e})') from e

def port_num(x):
    if not PORT_RE.fullmatch(str(x)) or not 1<=int(x)<=65535:raise Error('端口必须在 1~65535')
    return int(x)

def rate_bytes(value):
    """User units decimal Mbps; exact integer bytes/s; zero means no limit."""
    try:amount=Decimal(str(value))
    except InvalidOperation as e:raise Error('Mbps 必须为数字') from e
    if not amount.is_finite() or not (Decimal(0)<=amount<=Decimal(100000)):
        raise Error('Mbps 必须在 0~100000 之间')
    b=amount*Decimal(125000)
    if b!=int(b) or (amount>0 and b<1500):
        raise Error('Mbps 换算为整数 bytes/s 后必须 >= 1500；建议至少 0.012 Mbps')
    return int(b)

def rate_mbps(x):
    result=Decimal(x)/Decimal(125000)
    return format(result.normalize(),'f')

def burst_bytes(b):
    # 16KiB minimum for MTU, with bounded additional burst tolerance.
    return max(16384,min(int(b//8),131072))

def port_file(port):return STATE/'ports'/f'{port_num(port)}.json'
def cfg():
    value=read_json(CONF/'config.json')
    if (not isinstance(value,dict) or not isinstance(value.get('iface'),str)
        or not IF_RE.fullmatch(value['iface']) or value['iface'] in ('.','..')
        or type(value.get('tc_enabled')) is not bool):
        raise Error('全局配置损坏；保留内核规则，拒绝猜测接口/模式')
    return value

def records():
    rows={}
    for p in sorted((STATE/'ports').glob('*.json')):
        try:port=port_num(p.stem)
        except Error:raise Error(f'非法配置文件名：{p}')
        rec=read_json(p)
        validate_record(port,rec)
        rows[port]=rec
    return rows

def records_for_watch():
    """Read valid ports independently; report damaged records without erasing them.

    Destructive operations and tc slot allocation still use strict records()
    to avoid adopting a slot if a damaged file could conceal its ownership.
    """
    good={};issues=[]
    for p in sorted((STATE/'ports').glob('*.json')):
        try:
            port=port_num(p.stem)
            rec=read_json(p)
            validate_record(port,rec)
            good[port]=rec
        except (Error,OSError,ValueError,KeyError,TypeError) as exc:
            issues.append(f'{p.name}: {exc}')
    return good,issues


@contextmanager
def lock(wait=60,try_only=False):
    LOCK.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    with LOCK.open('a+') as f:
        stop=time.monotonic()+wait
        while True:
            try:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB);break
            except BlockingIOError:
                if try_only:yield False;return
                if time.monotonic()>stop:raise Error('portbw 管理锁繁忙')
                time.sleep(.1)
        try:yield True
        finally:fcntl.flock(f,fcntl.LOCK_UN)

def nft_snapshot(required=True):
    # Missing table and failed nft query must not be conflated.
    args=['nft','-j','-a','list','table','inet',TABLE]
    try:
        proc=subprocess.run(args,text=True,capture_output=True,timeout=25,env=dict(os.environ,LC_ALL='C'))
    except (OSError,subprocess.TimeoutExpired) as e:
        raise Error(f'nft 快照查询失败：{e}') from e
    if proc.returncode:
        err=proc.stderr.lower()
        if not required and ('no such file' in err or 'does not exist' in err):
            return None
        raise Error(f'nft 快照查询异常（非空表）：{proc.stderr[:500]}')
    try:return json.loads(proc.stdout)['nftables']
    except (ValueError,KeyError,TypeError) as e:raise Error('nftables 规则 JSON 无法解析') from e

def _check_owned_table(items,allow_missing=False):
    if items is None:raise Error('nft 限速表缺失')
    chains={}
    for entry in items:
        if 'metainfo' in entry:continue
        if 'table' in entry:
            obj=entry['table']
            if obj.get('family')!='inet' or obj.get('name')!=TABLE:
                raise Error('nft 表身份异常')
        elif 'chain' in entry:
            c=entry['chain'];name=c.get('name')
            if name not in CHAIN.values() or name in chains:
                raise Error('nft 模块表出现额外/重复链，拒绝覆盖')
            expect='input' if name=='inbound' else 'output'
            if c.get('family','inet')!='inet' or c.get('table',TABLE)!=TABLE \
                or c.get('type')!='filter' or c.get('hook')!=expect \
                or c.get('policy')!='accept' or c.get('prio')!=-5:
                raise Error(f'{TABLE}/{name} 基链属性被修改，拒绝覆盖')
            chains[name]=c
        elif 'rule' in entry:
            r=entry['rule']
            match=OWNED_RULE_RE.fullmatch(str(r.get('comment','')))
            if r.get('chain') not in CHAIN.values() or not match:
                raise Error('nft 模块链出现非本模块管理的规则，拒绝覆盖')
            if type(r.get('handle')) is not int:raise Error('nft 规则缺少可用句柄')
            # A forged comment on ANOTHER port must not mask an early ACCEPT or
            # an incorrect port match that can bypass this customer's limiter.
            if not _rule_exact(r,int(match.group(1)),match.group(2),match.group(3)):
                raise Error('nft 存在标记为本模块但表达式不符的规则，拒绝覆盖')
        elif 'limit' in entry or 'counter' in entry:
            kind='limit' if 'limit' in entry else 'counter'
            name=entry[kind].get('name','')
            if not re.fullmatch(r'pbw_[ud]_([1-9][0-9]{0,4})' if kind=='limit'
                                   else r'pbw_c[ud]_([1-9][0-9]{0,4})',str(name)):
                raise Error('nft 模块表出现未登记命名对象，拒绝覆盖')
        else:
            raise Error('nft 模块表包含未知内核对象，拒绝覆盖')
    if not allow_missing and set(chains)!=set(CHAIN.values()):
        raise Error(f'nft 基链缺失：{set(CHAIN.values())-set(chains)}')
    return chains

def validate_base(items):
    _check_owned_table(items)

def ensure_base():
    items=nft_snapshot(False)
    if items is None:
        script=f'''add table inet {TABLE}
add chain inet {TABLE} inbound {{ type filter hook input priority -5; policy accept; }}
add chain inet {TABLE} outbound {{ type filter hook output priority -5; policy accept; }}
'''
        run(['nft','-f','-'],input=script)
    else:
        chains=_check_owned_table(items,allow_missing=True)
        missing=set(CHAIN.values())-set(chains)
        if missing:
            # Repair only genuinely missing owned chains. Never flush or replace others.
            script=''.join(f'add chain inet {TABLE} {name} {{ type filter hook '
                           f'{"input" if name=="inbound" else "output"} priority -5; policy accept; }}\n'
                           for name in sorted(missing))
            run(['nft','-f','-'],input=script)
    items=nft_snapshot()
    validate_base(items)
    return items

def limitname(direction,port):return f'pbw_{"u" if direction=="up" else "d"}_{port}'
def countname(direction,port):return f'pbw_c{"u" if direction=="up" else "d"}_{port}'
def comment(direction,port,suffix):return f'pbw-{port}-{direction}-{suffix}'

def owned(items,port):
    rules=[];objects=[]
    expected={limitname(d,port) for d in CHAIN}|{countname(d,port) for d in CHAIN}
    for row in items:
        rule=row.get('rule')
        if rule and str(rule.get('comment','')).startswith(f'pbw-{port}-'):
            if rule.get('chain') not in CHAIN.values() or type(rule.get('handle')) is not int:
                raise Error('nft 管理规则句柄异常')
            rules.append((rule['chain'],rule['handle']))
        for kind in ('limit','counter'):
            obj=row.get(kind)
            if obj and obj.get('name') in expected:objects.append((kind,obj['name']))
    return rules,objects

def expected_comments(port,rec):
    return {comment(direction,port,suffix)
            for direction in CHAIN if rec[direction]>0
            for suffix in (('drop','count') if direction=='up' else ('count',))}

def _named_ref(expr,kind):
    val=expr.get(kind,'__missing__') if isinstance(expr,dict) else '__missing__'
    if isinstance(val,dict):val=val.get('name')
    return val

# nftables version-dependent JSON representations of byte-based limits:
#   Legacy: {"rate": 1250000, "unit": "bytes", "burst": 131072}
#   Debian 12 nft 1.0.6: {"rate": 1250000, "rate_unit": "bytes",
#                       "burst": 128, "burst_unit": "kbytes"}
# Normalize both to bytes; reject unknown units and malformed quantities.
_NFT_BYTE_UNITS = {'bytes': 1, 'kbytes': 1024, 'mbytes': 1024 ** 2,
                   'gbytes': 1024 ** 3}

def _nft_bytes(value, name, unit_field, *, burst=False):
    qty=value.get(name)
    if type(qty) is not int or qty < 0:
        return None
    if unit_field in value:
        unit=value[unit_field]
    elif 'unit' in value:  # Legacy named limit JSON format
        unit=value['unit']
    elif burst and 'rate_unit' in value:
        # nft JSON defaults an omitted burst_unit to bytes.
        unit='bytes'
    else:
        return None
    multiplier=_NFT_BYTE_UNITS.get(unit)
    return qty * multiplier if multiplier is not None else None

def _limit_rate(value):
    return _nft_bytes(value,'rate','rate_unit')

def _limit_burst(value):
    return _nft_bytes(value,'burst','burst_unit',burst=True)

def _rule_exact(rule,port,d,kind):
    if rule.get('chain')!=CHAIN[d] or rule.get('family','inet')!='inet' \
       or rule.get('table',TABLE)!=TABLE:return False
    field='dport' if d=='up' else 'sport'
    # One rule and one named limiter for both TCP/UDP and IPv4/IPv6.
    # nftables JSON represents set membership as == or in, depending on version.
    expr=rule.get('expr')
    if not isinstance(expr,list) or len(expr)!=(4 if kind=='drop' else 3):return False
    proto=expr[0].get('match') if isinstance(expr[0],dict) else None
    if not isinstance(proto,dict) or proto.get('op') not in ('==','in') \
       or proto.get('left')!={'meta':{'key':'l4proto'}}:return False
    values=proto.get('right',{}).get('set') if isinstance(proto.get('right'),dict) else None
    if not isinstance(values,list) or len(values)!=2 \
       or {str(x).lower() for x in values} not in ({'tcp','udp'},{'6','17'}):return False
    if expr[1]!={'match':{'op':'==','left':{'payload':{'protocol':'th','field':field}},'right':port}}:
        return False
    if kind=='drop':
        return d=='up' and _named_ref(expr[2],'limit')==limitname(d,port) and expr[3]=={'drop':None}
    return _named_ref(expr[2],'counter')==countname(d,port)

def nft_ok(port,rec,items=None):
    try:
        if items is None:items=nft_snapshot()
        validate_base(items)  # Includes isolation: no foreign rule in our chains.
        rules,objects=owned(items,port)
        desired=expected_comments(port,rec)
        rows=[x['rule'] for x in items if 'rule' in x and str(x['rule'].get('comment','')).startswith(f'pbw-{port}-')]
        if {x['comment'] for x in rows}!=desired or len(rows)!=len(desired):return False
        # Inbound: nft and tc can both police. Outbound: nft OUTPUT drops
        # return EPERM to local UDP sendmsg(), aborting apps such as iperf3.
        # Only shared tc egress enforces outbound; nft keeps an exact counter.
        expected_obj={(kind,fun(d,port)) for d in CHAIN if rec[d]>0
                      for kind,fun in ((('limit',limitname),('counter',countname)) if d=='up'
                                       else (('counter',countname),))}
        if set(objects)!=expected_obj or len(objects)!=len(expected_obj):return False
        for d in CHAIN:
            if not rec[d]:continue
            if d=='up':
                lims=[x['limit'] for x in items if 'limit' in x and x['limit'].get('name')==limitname(d,port)]
                if len(lims)!=1:return False
                lim=lims[0]
                if _limit_rate(lim)!=rec[d] or lim.get('per','second')!='second' \
                    or lim.get('inv') is not True \
                    or _limit_burst(lim)!=burst_bytes(rec[d]):return False
            for kind in (('drop','count') if d=='up' else ('count',)):
                selected=[r for r in rows if r['comment']==comment(d,port,kind)]
                if len(selected)!=1 or not _rule_exact(selected[0],port,d,kind):return False
            # DROP must precede named counter, and no earlier accept/bypass exists.
            order={r['comment']:i for i,x in enumerate(items) if (r:=x.get('rule'))}
            if d=='up' and order[comment(d,port,'drop')]>=order[comment(d,port,'count')]:return False
        return True
    except (Error,ValueError,TypeError,KeyError,StopIteration):return False

def nft_direction_ok(port,rec,items,direction):
    other='down' if direction=='up' else 'up'
    excluded={limitname(other,port),countname(other,port)}
    subset=[x for x in items
            if not (x.get('rule',{}).get('comment','').startswith(f'pbw-{port}-{other}-')
                    or any(x.get(k,{}).get('name') in excluded for k in ('limit','counter')))]
    test=dict(rec);test[other]=0
    return nft_ok(port,test,subset)

def apply_nft(port,rec):
    items=ensure_base()
    dirty={d for d in CHAIN if not nft_direction_ok(port,rec,items,d)}
    rows,objs=owned(items,port)
    rows=[(c,h) for c,h in rows if c in {CHAIN[d] for d in dirty}]
    names={fn(d,port) for d in dirty for fn in (limitname,countname)}
    objs=[(k,n) for k,n in objs if n in names]
    script=[f'delete rule inet {TABLE} {chain} handle {h}' for chain,h in sorted(rows,key=lambda e:e[1],reverse=True)]
    script += [f'delete {kind} inet {TABLE} {name}' for kind,name in objs]
    for d in CHAIN:
        if d not in dirty:continue
        b=rec[d]
        if not b:continue
        l=limitname(d,port);c=countname(d,port);f='dport' if d=='up' else 'sport'
        if d=='up':
            script.extend([
                f'add limit inet {TABLE} {l} {{ rate over {b} bytes/second burst {burst_bytes(b)} bytes; }}',
                f'add counter inet {TABLE} {c}',
                f'add rule inet {TABLE} {CHAIN[d]} meta l4proto {{ tcp, udp }} th {f} {port} limit name "{l}" drop comment "{comment(d,port,"drop")}"',
                f'add rule inet {TABLE} {CHAIN[d]} meta l4proto {{ tcp, udp }} th {f} {port} counter name "{c}" comment "{comment(d,port,"count")}"'])
        else:
            # No OUTPUT nft DROP: exceedance would raise EPERM to UDP apps.
            # The single tc egress policer is the enforceable aggregate cap.
            script.extend([
                f'add counter inet {TABLE} {c}',
                f'add rule inet {TABLE} {CHAIN[d]} meta l4proto {{ tcp, udp }} th {f} {port} counter name "{c}" comment "{comment(d,port,"count")}"'])
    if script:run(['nft','-f','-'],input='\n'.join(script)+'\n')
    if not nft_ok(port,rec):raise Error(f'端口 {port}: nft 限速未能通过生效校验')

def tc_qdiscs(iface):
    raw=run(['tc','-j','qdisc','show','dev',iface])
    try:return json.loads(raw)
    except ValueError as e:raise Error('tc qdisc JSON 无法解析') from e

def tc_prepare(iface):
    kinds={e.get('kind') for e in tc_qdiscs(iface)}
    if 'clsact' in kinds:return
    if 'ingress' in kinds:raise Error(f'{iface} 已有 ingress qdisc，不能安全附加 clsact；使用 --nft-only 或检查原规则')
    # Never change the root queuing discipline / fq / BBR settings.
    run(['tc','qdisc','add','dev',iface,'clsact'])

def tc_filters(iface,dir):
    raw=run(['tc','-j','filter','show','dev',iface,dir])
    try:
        val=json.loads(raw)
        if not isinstance(val,list):raise ValueError('expected list')
        return val
    except (ValueError,TypeError) as e:raise Error('tc filter JSON 无法解析') from e

def tc_protocol(family):return 'ip' if family==4 else 'ipv6'

def tc_handle(port):
    return TC_HANDLE_PREFIX | port_num(port)

def tc_slot_key(family,transport):
    return f'{family}_{transport}'

def tc_pref(port,family,transport,rec=None):
    key=tc_slot_key(family,transport)
    value=(rec or {}).get('tc_prefs',{}).get(key)
    if type(value) is not int or not 1<=value<=65535:
        raise Error(f'{port}: IPv{family} {transport} tc pref 无效')
    return value

def tc_police_index(port,direction):
    # Deterministic, per-port, per-direction shared policer index, all L3/L4
    # filters point to this SINGLE tc action. No mixing between up and down.
    return TC_POLICE_PREFIX + port_num(port)*2 + (1 if direction=='down' else 0)

def _tc_slot_owned(row,port,direction,family,transport):
    opts=row.get('options')
    if row.get('protocol')!=tc_protocol(family) or row.get('kind')!='flower' or not isinstance(opts,dict):
        return False
    handle=opts.get('handle',row.get('handle',''))
    try:handle=handle if isinstance(handle,int) else int(str(handle),16)
    except (ValueError,TypeError):return False
    keys=opts.get('keys')
    field='dst_port' if direction=='up' else 'src_port'
    return (handle==tc_handle(port) and row.get('chain',0) in (0,'0')
            and isinstance(keys,dict)
            and set(keys) in ({'ip_proto',field},{'ip_proto',field,'eth_type'})
            and str(keys['ip_proto']).lower() in (transport, '6' if transport=='tcp' else '17')
            and str(keys[field])==str(port)
            and ('eth_type' not in keys or keys['eth_type']==('ipv4' if family==4 else 'ipv6')))

def _legacy_slot_owned(row,port,direction):
    opts=row.get('options')
    if not isinstance(opts,dict) or row.get('kind')!='flower' or row.get('chain',0) not in (0,'0'):
        return False
    family={'ip':4,'ipv6':6}.get(row.get('protocol'))
    if family is None:return False
    h=opts.get('handle',row.get('handle',''))
    try:h=h if isinstance(h,int) else int(str(h),16)
    except (ValueError,TypeError):return False
    field='dst_port' if direction=='up' else 'src_port'
    keys=opts.get('keys')
    return (h==port and int(row.get('pref',-1))==port and isinstance(keys,dict)
            and set(keys) in ({'ip_proto',field},{'ip_proto',field,'eth_type'})
            and str(keys['ip_proto']).lower() in ('tcp','6') and str(keys[field])==str(port)
            and ('eth_type' not in keys or keys['eth_type']==('ipv4' if family==4 else 'ipv6')))

def _used_tc_prefs(all_rows,port,direction,family,transport):
    """Return preferences used by any rule other than the exact owned slot."""
    groups={}
    for row in all_rows:
        try:pref=int(row['pref'])
        except (ValueError,TypeError,KeyError):continue
        if 1<=pref<=65535:groups.setdefault(pref,[]).append(row)
    busy=set()
    for pref,rows in groups.items():
        details=[r for r in rows if isinstance(r.get('options'),dict)]
        if not details or not all(_tc_slot_owned(r,port,direction,family,transport) for r in details):
            busy.add(pref)
    return busy

def ensure_tc_prefs(port,rec,iface,*,watch_rows=None,damaged_siblings=False):
    """Verify allocated slots; allocate NEW slots only with a complete inventory.

    The watchdog may repair an already allocated, valid port even when a
    different port record is damaged.  It must not allocate any new prefs in
    that situation: the damaged record may conceal previously reserved prefs.
    CLI operations still require the strict complete records() inventory.
    Every existing pref is independently checked against both live tc directions
    before making changes, whether the inventory is partial or complete.
    """
    if watch_rows is None and damaged_siblings:
        raise Error('不允许在没有已验证端口清单时使用损坏配置隔离模式')
    rows={d:tc_filters(iface,d) for d in ('ingress','egress')}
    existing=rec.get('tc_prefs')
    if damaged_siblings and existing is None:
        raise Error(f'{port}: 其他端口配置损坏，拒绝分配新的 tc pref；修复配置后重试')
    used=set()
    inventory=records() if watch_rows is None else watch_rows
    if watch_rows is not None and (port not in watch_rows or watch_rows[port] is not rec):
        raise Error(f'{port}: watchdog 已验证记录不一致，拒绝更改 tc')
    for other,r in inventory.items():
        if other==port:continue
        prefs=r.get('tc_prefs')
        if not isinstance(prefs,dict) or set(prefs)!={tc_slot_key(f,t) for f in FAMILIES for t in TRANSPORTS}:
            raise Error(f'{other}: 检测到旧版/损坏的 tc pref，测试版要求恢复未安装 portbw 的快照')
        for value in prefs.values():
            if type(value) is not int or not 1<=value<=65535 or value in used:
                raise Error(f'{other}: tc pref 重复/损坏')
            used.add(value)
    slots=[(f,t) for f in FAMILIES for t in TRANSPORTS]
    if existing is not None:
        if not isinstance(existing,dict) or set(existing)!={tc_slot_key(f,t) for f,t in slots}:
            raise Error(f'{port}: 检测到旧版 tc 状态，请恢复干净快照后再测试')
        selected={key:tc_pref(port,int(key[0]),key[2:],rec) for key in existing}
        if len(set(selected.values()))!=len(slots) or any(v in used for v in selected.values()):
            raise Error('tc pref 与其他端口冲突')
    else:
        selected={}
        def occupied(pref,family,transport):
            if pref in used:return True
            for direction,tcdir in (('up','ingress'),('down','egress')):
                if pref in _used_tc_prefs(rows[tcdir],port,direction,family,transport):return True
            return False
        for family,transport in slots:
            # Reserve port priority for v4 TCP, otherwise search downwards.
            pref=port if (family,transport)==(4,'tcp') and not occupied(port,family,transport) else None
            if pref is None:
                for candidate in range(65535,0,-1):
                    if not occupied(candidate,family,transport):pref=candidate;break
            if pref is None:raise Error('tc 优先级不足，无法为 TCP/UDP 双栈分配四个槽位')
            selected[tc_slot_key(family,transport)]=pref
            used.add(pref)
    for direction,tcdir in (('up','ingress'),('down','egress')):
        for family,transport in slots:
            pref=selected[tc_slot_key(family,transport)]
            if pref in _used_tc_prefs(rows[tcdir],port,direction,family,transport):
                raise Error(f'{port} {tcdir}: pref={pref} 存在非本模块 tc 规则')
    if existing is None:
        rec['tc_prefs']=selected
        rec['pending']=True
        write_json(port_file(port),rec)
    return selected

def tc_target(port,direction,family,transport,rec):
    return {'pref':tc_pref(port,family,transport,rec),'protocol':tc_protocol(family),
            'handle':f'0x{tc_handle(port):x}',
            'field':'dst_port' if direction=='up' else 'src_port'}

def tc_find(iface,port,direction,family,transport,rec,rows=None,strict=True):
    expected=tc_target(port,direction,family,transport,rec)
    if rows is None:rows=tc_filters(iface,'ingress' if direction=='up' else 'egress')
    candidates=[]
    for entry in rows:
        try:epref=int(entry.get('pref',-1))
        except (TypeError,ValueError):continue
        if epref!=expected['pref']:continue
        opts=entry.get('options')
        if not isinstance(opts,dict):continue
        if not _tc_slot_owned(entry,port,direction,family,transport):
            if strict:raise Error(f'{iface} {direction} IPv{family}/{transport}: pref={expected["pref"]} 被外部过滤器占用')
            continue
        candidates.append(entry)
    if len(candidates)>1:raise Error('tc 检测到重复过滤器')
    return candidates[0] if candidates else None

def _quantity_bytes(number,unit):
    factor={'':1,'k':1000,'m':1000000,'g':1000000000,
            'ki':1024,'mi':1024**2,'gi':1024**3}
    return Decimal(number)*factor[unit.lower()]

def tc_burst_kb(rate):
    return max(64,min(1024,(rate//10+1023)//1024))

def _tc_filter_body(text,port,direction,family,transport,pref):
    protocol=tc_protocol(family)
    head=re.compile(r'^filter protocol '+re.escape(protocol)+r' pref '+str(pref)+
                    r' flower chain 0 handle (?:0x)?'+format(tc_handle(port),'x')+r'\b',re.M)
    m=head.search(text)
    if not m:return None
    next_filter=re.search(r'^filter protocol ',text[m.end():],re.M)
    return text[m.end():m.end()+next_filter.start() if next_filter else len(text)]

def tc_rate_is_ok(entry,b,iface,direction,port,family,transport,rec,text=None,check_rate=True):
    if not entry:return False
    try:
        if text is None:text=run(['tc','-s','filter','show','dev',iface,'ingress' if direction=='up' else 'egress'])
        pref=tc_pref(port,family,transport,rec)
        fragment=_tc_filter_body(text,port,direction,family,transport,pref)
        if not fragment:return False
        field='dst_port' if direction=='up' else 'src_port'
        expected_type='ipv4' if family==4 else 'ipv6'
        lines=[l.strip() for l in fragment.splitlines() if l.strip()]
        index=next((i for i,l in enumerate(lines) if l.startswith('action order ')),None)
        if index is None:return False
        before=lines[:index]
        expected=[f'eth_type {expected_type}',f'ip_proto {transport}',f'{field} {port}','skip_hw']
        if before not in (expected,expected+['not_in_hw']):return False
        actions=[l for l in lines if l.startswith('action order ')]
        if len(actions)!=1:return False
        line=actions[0]
        # Crucial: all FOUR flowers per direction must reference the exact SAME action index.
        police=re.search(r'^action order 1:\s+police\s+0x([0-9a-fA-F]+)\s+',line)
        if not police or int(police.group(1),16)!=tc_police_index(port,direction):return False
        rm=re.search(r'\brate\s+([0-9]+(?:\.[0-9]+)?)\s*([kKmMgGtT]?)bit\b',line)
        if not rm:return False
        mult={'':1,'k':1000,'m':1000000,'g':1000000000,'t':1000000000000}[rm.group(2).lower()]
        actual=Decimal(rm.group(1))*mult
        desired=Decimal(b*8)
        if check_rate and abs(actual-desired)>max(Decimal(1000),desired*Decimal('0.0005')):return False
        bm=re.search(r'\bburst\s+([0-9]+(?:\.[0-9]+)?)([kKmMgG]?)b\b',line)
        if not bm:return False
        actual_burst=_quantity_bytes(bm.group(1),bm.group(2))
        desired_burst=Decimal(tc_burst_kb(b)*1024)
        if check_rate and abs(actual_burst-desired_burst)>max(Decimal(256),desired_burst*Decimal('0.05')):return False
        if not re.search(r'\baction drop(?:/ok)?(?:\s|$)',line):return False
        return True
    except (Error,ValueError,InvalidOperation,TypeError):return False

def tc_index_attached(text,port,direction,family,transport,pref):
    fragment=_tc_filter_body(text,port,direction,family,transport,pref)
    if not fragment:return False
    m=re.search(r'^\s*action order 1:\s+police\s+0x([0-9a-fA-F]+)\b',fragment,re.M)
    return bool(m and int(m.group(1),16)==tc_police_index(port,direction))


def apply_tc(port,rec,iface):
    tc_prepare(iface)
    rows={d:tc_filters(iface,d) for d in ('ingress','egress')}
    plan=[]
    for direction in CHAIN:
        tcdir='ingress' if direction=='up' else 'egress'
        for family in FAMILIES:
            for transport in TRANSPORTS:
                pref=tc_pref(port,family,transport,rec)
                if pref in _used_tc_prefs(rows[tcdir],port,direction,family,transport):
                    raise Error(f'{port}: {tcdir} pref={pref} 包含外部规则，拒绝修改')
                old=tc_find(iface,port,direction,family,transport,rec,rows[tcdir])
                plan.append((direction,tcdir,family,transport,pref,old))
    # Create the shared policer on the first flower; the other three share it.
    # On Debian 12, its last reference can survive all flower deletions as
    # ref=1 bind=0. Only GC this exact previously verified index once unbound.
    for direction in CHAIN:
        tcdir='ingress' if direction=='up' else 'egress'
        theirs=[p for p in plan if p[0]==direction]
        existing=[p for p in theirs if p[5] is not None]
        text=run(['tc','-s','filter','show','dev',iface,tcdir]) if existing else ''
        if rec[direction]>0 and len(existing)==len(theirs):
            if all(tc_rate_is_ok(old,rec[direction],iface,direction,port,f,t,rec,text)
                   for _,_,f,t,_,old in theirs):continue
        index=tc_police_index(port,direction)
        # Check every old slot before deletion; never adopt foreign bindings.
        for _,_,family,transport,pref,old in existing:
            if not tc_index_attached(text,port,direction,family,transport,pref):
                raise Error(f'{port}: {tcdir} {transport}/IPv{family} police index 不属于本模块，拒绝删除')
        if rec[direction]>0 and len(existing)==len(theirs):
            # Live rate changes must not detach the four sharing filters.
            # Count all global bindings: a foreign fifth binding forbids replacement.
            block=tc_action_block(index)
            counts=re.search(r'\bref\s+([0-9]+)\s+bind\s+([0-9]+)\b',block or '')
            if (not counts or int(counts[2])!=4 or int(counts[1]) not in (4,5)
                or not all(tc_rate_is_ok(old,rec[direction],iface,direction,port,f,t,
                                        rec,text,check_rate=False)
                           for _,_,f,t,_,old in theirs)):
                raise Error(f'{port}: {direction} action 归属/绑定异常，拒绝原位改速')
            run(['tc','actions','replace','action','police','rate',f'{rec[direction]*8}bit',
                 'burst',f'{tc_burst_kb(rec[direction])}k','conform-exceed','drop/ok',
                 'index',str(index),'skip_hw'])
            continue
        if not existing and tc_action_exists(index):
            raise Error(f'{port}: tc police index {index} 已被占用，拒绝覆盖')
        if existing:
            block=tc_action_block(index)
            counts=re.search(r'\bref\s+([0-9]+)\s+bind\s+([0-9]+)\b',block or '')
            if (not counts or int(counts[2])!=len(existing)
                or int(counts[1]) not in (len(existing),len(existing)+1)):
                raise Error(f'{port}: police index 存在未知引用；保留过滤器，拒绝删除')
        for _,_,family,transport,pref,old in existing:
            run(['tc','filter','del','dev',iface,tcdir,'protocol',tc_protocol(family),
                 'pref',str(pref),'handle',f'0x{tc_handle(port):x}','flower'])
        # The policer can legitimately outlive all four flower filters.
        # Never delete an index belonging to somebody else: all former slots
        # were verified as ours, and only ref=1/bind=0 may be collected.
        if existing:
            tc_gc_unbound_police(port,index)
        if rec[direction]==0:continue
        kb=tc_burst_kb(rec[direction])
        for n,(_,_,family,transport,pref,_) in enumerate(theirs):
            field='dst_port' if direction=='up' else 'src_port'
            cmd=['tc','filter','add','dev',iface,tcdir,'protocol',tc_protocol(family),
                 'pref',str(pref),'handle',f'0x{tc_handle(port):x}',
                 'flower','skip_hw','ip_proto',transport,field,str(port),
                 'action','police']
            if n==0:
                # Kernel atomically creates the policer and attaches filter 1.
                # skip_hw applies to both flower and action to avoid mismatch.
                cmd.extend(['rate',f'{rec[direction]*8}bit','burst',f'{kb}k',
                            'conform-exceed','drop/ok','index',str(index),'skip_hw'])
            else:cmd.extend(['index',str(index)])
            run(cmd)


def tc_action_block(index):
    """Return the exact global tc police entry for an action index, if any."""
    output=run(['tc','-s','actions','ls','action','police'])
    heads=list(re.finditer(r'^\s*action order [0-9]+:\s+police\s+0x([0-9a-f]+)\b',
                           output,re.I|re.M))
    matches=[i for i,m in enumerate(heads) if int(m.group(1),16)==index]
    if len(matches)>1:raise Error(f'tc police index {index} 存在重复输出，拒绝修改')
    if not matches:return None
    m=heads[matches[0]]
    following=heads[matches[0]+1].start() if matches[0]+1<len(heads) else len(output)
    return output[m.start():following]


def tc_action_exists(index):
    return tc_action_block(index) is not None


def tc_gc_unbound_police(port,index):
    """Wait for tc's deferred flower-action releases; GC only a truly unbound owned index.

    Linux may briefly report ref=1/bind=1 after the fourth flower is deleted.
    Do not mistake that transient state for a permanent foreign binding.  A
    STILL-bound action is never force-deleted, even if the timeout expires.
    """
    deadline=time.monotonic()+12
    removed=False
    while True:
        block=tc_action_block(index)
        if block is None:return
        counts=re.search(r'\bref\s+([0-9]+)\s+bind\s+([0-9]+)\b',block)
        if not counts:raise Error(f'{port}: police index {index} 缺少 ref/bind，拒绝删除')
        refs,binds=map(int,counts.groups())
        if (not re.search(r'\baction\s+drop\b',block) or
                not re.search(r'^\s*skip_hw\s*$',block,re.M)):
            raise Error(f'{port}: police index {index} 属性异常，拒绝删除')
        if not removed and refs==1 and binds==0:
            # Only this verified, now-unbound index may be deleted; no global flush.
            run(['tc','actions','delete','action','police','index',str(index)])
            removed=True
            continue
        if time.monotonic()>=deadline:
            raise Error(f'{port}: police index {index} 等待解绑/回收超时(ref={refs},bind={binds})；'
                        '未强制删除，请检查 tc 引用')
        time.sleep(0.25)


def tc_snapshot(iface):
    # One coherent read pass per audit/watch invocation, not per customer port.
    return {
        'qdiscs':tc_qdiscs(iface),
        'rows':{d:tc_filters(iface,d) for d in ('ingress','egress')},
        'text':{d:run(['tc','-s','filter','show','dev',iface,d]) for d in ('ingress','egress')},
    }

def tc_ok(port,rec,iface,snap=None):
    try:
        if 'clsact' not in {e.get('kind') for e in (snap['qdiscs'] if snap else tc_qdiscs(iface))}:return False
        for direction in CHAIN:
            tcdir='ingress' if direction=='up' else 'egress'
            rows=snap['rows'][tcdir] if snap else tc_filters(iface,tcdir)
            targets=[]
            for family in FAMILIES:
                for transport in TRANSPORTS:
                    pref=tc_pref(port,family,transport,rec)
                    if pref in _used_tc_prefs(rows,port,direction,family,transport):return False
                    entry=tc_find(iface,port,direction,family,transport,rec,rows,strict=rec[direction]>0)
                    targets.append((family,transport,entry))
            if rec[direction]==0:
                if any(entry for _,_,entry in targets) or tc_action_exists(tc_police_index(port,direction)):
                    return False
                continue
            if not all(entry for _,_,entry in targets):return False
            text=snap['text'][tcdir] if snap else run(['tc','-s','filter','show','dev',iface,tcdir])
            if not all(tc_rate_is_ok(entry,rec[direction],iface,direction,port,family,transport,rec,text)
                       for family,transport,entry in targets):return False
        return True
    except Error:return False

def apply(port,rec,config,*,watch_rows=None,damaged_siblings=False):
    # Fail BEFORE any nft/tc mutation if a damaged sibling makes slot ownership
    # unknowable. Existing valid slots are handled by ensure_tc_prefs below.
    if damaged_siblings and (watch_rows is None or watch_rows.get(port) is not rec):
        raise Error(f'{port}: 缺少可信的 watchdog 端口快照，拒绝修改限速规则')
    if damaged_siblings and config.get('tc_enabled') and 'tc_prefs' not in rec:
        raise Error(f'{port}: 其他端口配置损坏，拒绝分配新的 tc pref；修复配置后重试')
    if rec['down']>0 and not config.get('tc_enabled'):
        raise Error('UDP/TCP 下载限速必须使用 tc egress；不可采用 nft-only，以免本地发送程序收到 EPERM')
    if not nft_ok(port,rec):apply_nft(port,rec)
    if config.get('tc_enabled'):
        ensure_tc_prefs(port,rec,config['iface'],watch_rows=watch_rows,
                        damaged_siblings=damaged_siblings)
        if not tc_ok(port,rec,config['iface']):
            apply_tc(port,rec,config['iface'])
            if not tc_ok(port,rec,config['iface']):
                raise Error(f'{port} 双层限速尚未通过完整审计，保留 pending 状态供修复')


def commit(port,up,down,config,deleting=False,auto=None):
    old=read_json(port_file(port),default={})
    rec={'port':port,'up':up,'down':down,'updated':int(time.time()),
         'pending':True,'deleting':deleting}
    if 'tc_prefs' in old:rec['tc_prefs']=old['tc_prefs']
    if auto is not None:
        rec['auto']=auto
        reset_auto_boot(rec,boot_id())
    validate_record(port,rec)
    if down>0 and not config.get('tc_enabled'):
        raise Error('下载/自动限速需要 tc；未修改已保存配置')
    volatile_clear(port)
    write_json(port_file(port),rec)
    finish_apply(port,rec,config)


# Durable config, active target and phase/deadline live in the port record.
# Sampler observations are cached under /run/portbw/auto to avoid disk churn.
# During hold the deadline rolls forward only under sustained saturation / drops.
# Checkpoints to durable storage are batched, with a final checkpoint at idle.
# Older static records need no migration; corrupt state is not guessed.
AUTO_VERSION=1
# Do not trust sub-half-second measurements or long averaged windows.
MIN_SAMPLE=0.5
MAX_SAMPLE_GAP=75.0
FAST_MAX_SAMPLE_GAP=8.0
# TCP adapts to tc police; the old 60% base-rate threshold is unreachable
# after a 100 -> 20 Mbps transition. Use saturation and drop pressure instead.
ROLLING_NEAR_LIMIT_BP=8500  # 85% of the *limited* rate, conservative lower bound
ROLLING_DROP_FLOOR_BP=2000  # 20% of limited rate for meaningful drop pressure
ROLLING_DROP_PPS=3          # sustained overlimits/drops per second
ROLLING_CONFIRM_SECONDS=2.0



def max_sample_gap(options):
    # Preserve original tolerance for legacy >=60s policies. For short
    # thresholds a long averaged interval is not evidence of uninterrupted
    # second-level load; reject it and build a new sampling baseline.
    after=options['after']
    return MAX_SAMPLE_GAP if after>=60 else max(FAST_MAX_SAMPLE_GAP, min(MAX_SAMPLE_GAP, after*1.5))
MAX_QUERY_TIME=2.0
MAX_DURATION=30*86400


def boottime():
    return time.clock_gettime(time.CLOCK_BOOTTIME)


def boot_id():
    value=Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    if not re.fullmatch(r'[0-9a-f-]{36}',value):raise Error('无法取得可信 boot_id')
    return value


def finite_number(value):
    return type(value) in (int,float) and math.isfinite(value) and value>=0


def duration(value,minimum=1):
    m=re.fullmatch(r'([0-9]+)(s|m|h|d)',str(value))
    if not m:raise Error('时间必须是整数加 s/m/h/d，例如 60s、10m、2h')
    seconds=int(m[1])*{'s':1,'m':60,'h':3600,'d':86400}[m[2]]
    if not minimum<=seconds<=MAX_DURATION:
        raise Error(f'时间必须在 {minimum}~{MAX_DURATION} 秒之间')
    return seconds


def auto_options(args):
    base={d:rate_bytes(getattr(args,d)) for d in CHAIN}
    limited={d:rate_bytes(getattr(args,'auto_'+d)) for d in CHAIN}
    try:trigger=Decimal(str(args.trigger))
    except InvalidOperation as e:raise Error('trigger 必须为数字') from e
    if not trigger.is_finite() or not 0<trigger<=100:raise Error('trigger 必须大于 0 且 <=100')
    # Fixed precision keeps config validation and threshold arithmetic exact.
    if trigger*100!=int(trigger*100):raise Error('trigger 最多两位小数')
    for d in CHAIN:
        if not 0<limited[d]<base[d]:raise Error('自动模式两方向必须满足 0 < 降速值 < 基础速度')
    return {'version':AUTO_VERSION,'base':base,'limited':limited,'trigger_bp':int(trigger*100),
            'after':duration(args.after,1),'hold':duration(args.hold),
            'cooldown':duration(args.cooldown,0)}


def empty_direction():
    return {'phase':'monitor','until':None,'high_since':None,'progress':0.0,
            'last':None,'mbps':None,'lower_mbps':None,'reason':'等待两个有效采样',
            'busy_since':None,'last_busy_at':None}


def reset_auto_boot(rec,identity):
    rec.update(rec['auto']['base'])
    rec['runtime']={'boot_id':identity,'checked_at':None,
                    'dirs':{d:empty_direction() for d in CHAIN}}
    rec['pending']=True


def validate_record(port,rec):
    def bad():raise Error(f'{port}: 端口配置/自动状态损坏，拒绝猜测或放宽限速')
    if not isinstance(rec,dict) or type(rec.get('port')) is not int or rec['port']!=port:bad()
    for d in CHAIN:
        b=rec.get(d)
        if type(b) is not int or not (b==0 or 1500<=b<=12500000000):bad()
    for key in ('pending','deleting'):
        if key in rec and type(rec[key]) is not bool:bad()
    if 'tc_prefs' in rec:
        prefs=rec['tc_prefs']
        if (not isinstance(prefs,dict) or set(prefs)!={tc_slot_key(f,t) for f in FAMILIES for t in TRANSPORTS}
            or any(type(v) is not int or not 1<=v<=65535 for v in prefs.values())
            or len(set(prefs.values()))!=4):bad()
    if rec.get('deleting') and (rec['up'] or rec['down'] or 'auto' in rec):bad()
    if 'auto' not in rec:
        if 'runtime' in rec:bad()
        return
    a=rec['auto'];rt=rec.get('runtime')
    if (not isinstance(a,dict) or type(a.get('version')) is not int or a['version']!=AUTO_VERSION
        or type(a.get('trigger_bp')) is not int or not 1<=a['trigger_bp']<=10000):bad()
    for k,minimum in (('after',1),('hold',1),('cooldown',0)):
        if type(a.get(k)) is not int or not minimum<=a[k]<=MAX_DURATION:bad()
    for k in ('base','limited'):
        if not isinstance(a.get(k),dict) or set(a[k])!=set(CHAIN):bad()
        if any(type(v) is not int or not 1500<=v<=12500000000 for v in a[k].values()):bad()
    if any(a['limited'][d]>=a['base'][d] for d in CHAIN):bad()
    if (not isinstance(rt,dict) or not isinstance(rt.get('boot_id'),str)
        or not re.fullmatch(r'[0-9a-f-]{36}',rt['boot_id'])
        or not isinstance(rt.get('dirs'),dict) or set(rt['dirs'])!=set(CHAIN)):bad()
    if 'checked_at' not in rt or (rt['checked_at'] is not None and not finite_number(rt['checked_at'])):bad()
    for d,s in rt['dirs'].items():
        if not isinstance(s,dict) or s.get('phase') not in ('monitor','entering','hold','restoring','cooldown'):bad()
        for key in ('until','high_since','progress','mbps','lower_mbps'):
            if key not in s or (s[key] is not None and not finite_number(s[key])):bad()
        if s['progress'] is None or not isinstance(s.get('reason'),str) or 'last' not in s:bad()
        if s['progress']>a['after'] or (s['phase']!='monitor' and s['high_since'] is not None):bad()
        # Optional fields preserve existing 5.2.1 per-port records during an upgrade.
        for k in ('busy_since','last_busy_at'):
            if k in s and s[k] is not None and not finite_number(s[k]):bad()
        if s['phase']!='hold' and (s.get('busy_since') is not None or s.get('last_busy_at') is not None):bad()
        if s['phase'] in ('hold','cooldown') and s['until'] is None:bad()
        if s['phase'] not in ('hold','cooldown') and s['until'] is not None:bad()
        if s['phase'] in ('entering','restoring') and not rec.get('pending'):bad()
        target=a['limited'][d] if s['phase'] in ('entering','hold') else a['base'][d]
        if rec[d]!=target:bad()
        last=s.get('last')
        if last is not None:
            if not isinstance(last,dict):bad()
            if any(not finite_number(last.get(k)) for k in ('start','end','birth_lo','birth_hi')):bad()
            if last['end']<last['start'] or last['birth_hi']<last['birth_lo']:bad()
            if type(last.get('bytes')) is not int or not 0<=last['bytes']<2**64:bad()
            # Legacy v5.2.1 snapshots had only the byte counter; rebase safely.
            for k in ('drops','overlimits'):
                if k in last and (type(last[k]) is not int or not 0<=last[k]<2**64):bad()
            if (not isinstance(last.get('generation'),list)
                or any(type(h) is not int or h<0 for h in last['generation'])):bad()
        if s['high_since'] is not None and (last is None or s['high_since']>last['end']):bad()


def volatile_path(port):
    return VOLATILE/f'{port_num(port)}.json'


def volatile_clear(port):
    # A fresh manual/auto configuration must never reuse an old measurement.
    volatile_path(port).unlink(missing_ok=True)


def volatile_checkpoint(rec):
    # Only these transitions have a persistent meaning.  A stale /run file
    # must not override a newer intent (including entering/restoring/pending).
    return {'updated':rec.get('updated'),
            'auto':rec['auto'],
            'dirs':{d:{'phase':rec['runtime']['dirs'][d]['phase'],
                       'until':rec['runtime']['dirs'][d]['until'],
                       'target':rec[d]} for d in CHAIN}}


def volatile_save(port,rec):
    if 'auto' not in rec:return
    write_json(volatile_path(port),{'boot_id':rec['runtime']['boot_id'],
                                   'checkpoint':volatile_checkpoint(rec),
                                   'runtime':rec['runtime']})


def volatile_load(port,rec):
    """Only resume sampling when volatile state matches durable policy.

    A missing/corrupt tmpfs file breaks monitoring continuity, but it cannot
    release a durable hold or override a pending kernel transition.
    """
    if 'auto' not in rec or rec.get('pending'):return False
    try:
        data=read_json(volatile_path(port))
        if not isinstance(data,dict) or data.get('boot_id')!=rec['runtime']['boot_id']:
            raise Error('临时运行状态过期')
        if data.get('checkpoint')!=volatile_checkpoint(rec):
            raise Error('临时运行状态与已保存限速意图不符')
        copy_rec=dict(rec,runtime=data['runtime'])
        validate_record(port,copy_rec)
        # Never use volatile state for persistent phases: it is only a sampler.
        for d in CHAIN:
            st=copy_rec['runtime']['dirs'][d]
            durable=rec['runtime']['dirs'][d]
            if (st['phase'],st['until'])!=(durable['phase'],durable['until']):
                raise Error('临时状态阶段不一致')
        rec['runtime']=data['runtime']
        return True
    except (Error,KeyError,TypeError,ValueError,OSError):
        for state in rec['runtime']['dirs'].values():
            break_continuity(state,'采样缓存不可用，重建基线')
        return False


def break_continuity(s,reason):
    s.update(last=None,high_since=None,progress=0.0,mbps=None,lower_mbps=None,
             busy_since=None,reason=reason)


def finalize_hold_activity(s,hold):
    # When pressure ends, pin recovery to the most recent *confirmed* busy
    # sample. No per-second fsync: one durable deadline update at this edge.
    last_busy=s.get('last_busy_at')
    if last_busy is not None:
        s['until']=max(s['until'],last_busy+hold)
    s['last_busy_at']=None
    s['busy_since']=None


def police_blocks(output):
    heads=list(re.finditer(r'^\s*action order [0-9]+:\s+police\s+0x([0-9a-f]+)\b',output,re.I|re.M))
    blocks={}
    for i,m in enumerate(heads):
        index=int(m[1],16)
        if index in blocks:raise Error('tc action 快照包含重复 index')
        blocks[index]=output[m.start():heads[i+1].start() if i+1<len(heads) else len(output)]
    return blocks


def traffic_snapshot():
    # One global policer dump for ALL ports. The four flowers share these stats;
    # summing the copies printed by tc filter show would count every byte 4x.
    start=boottime()
    output=run(['tc','-s','actions','ls','action','police'])
    end=boottime()
    if not 0<=end-start<=MAX_QUERY_TIME:raise Error('tc 统计读取过慢/时钟异常，丢弃采样')
    return {'start':start,'end':end,'blocks':police_blocks(output)}


def traffic_sample(port,d,rec,snapshot,nft_items):
    if snapshot is None:raise Error('tc 统计快照不可用')
    block=snapshot['blocks'].get(tc_police_index(port,d),'')
    sent=re.findall(r'\bSent\s+([0-9]+)\s+bytes\s+([0-9]+)\s+pkt\s+' 
                    r'\(dropped\s+([0-9]+),\s+overlimits\s+([0-9]+)',block)
    installed=re.findall(r'\binstalled\s+([0-9]+)\s+sec\b',block)
    counts=re.search(r'\bref\s+([0-9]+)\s+bind\s+([0-9]+)\b',block)
    if (len(sent)!=1 or len(installed)!=1 or not counts or int(counts[2])!=4
        or int(counts[1]) not in (4,5) or not re.search(r'^\s*skip_hw\s*$',block,re.M)):
        raise Error('tc 字节/创建时间/共享绑定统计缺失或不兼容')
    count,packets,drops,overlimits=map(int,sent[0]);age=int(installed[0]);start=snapshot['start'];end=snapshot['end']
    if (max(count,packets,drops,overlimits)>=2**64 or drops>packets
        or overlimits>packets or age>end+2):
        raise Error('tc 计数/创建时间异常')
    # Quantized installed age defines an interval, not a fabricated exact birth.
    # Intersect it over successive samples to detect action recreation even if
    # the new counter has already overtaken the previous counter.
    handles=sorted(r['rule']['handle'] for r in nft_items if 'rule' in r
                   and r['rule'].get('comment','').startswith(f'pbw-{port}-{d}-'))
    return {'bytes':count,'drops':drops,'overlimits':overlimits,
            'start':start,'end':end,
            'birth_lo':max(0.0,start-age-1.1),'birth_hi':end-age+0.1,
            'generation':handles}


def observe(s,sample,base,options,limited=None):
    previous=s['last'];s['last']=sample
    s['mbps']=s['lower_mbps']=None
    if previous is None:
        s['reason']='建立统计基线';return False
    low=sample['start']-previous['end'];high=sample['end']-previous['start']
    birth_lo=max(sample['birth_lo'],previous['birth_lo'])
    birth_hi=min(sample['birth_hi'],previous['birth_hi'])
    reason=None
    max_gap=max_sample_gap(options)
    if not MIN_SAMPLE<=low or high>max_gap:reason='采样间隔异常/延迟，重新累计'
    elif sample['generation']!=previous['generation'] or birth_lo>birth_hi:reason='内核规则重建，重新累计'
    elif sample['bytes']<previous['bytes']:reason='计数器清零/回绕，重新累计'
    elif s['phase']=='hold' and (limited is None or
          any(k not in sample or k not in previous for k in ('drops','overlimits'))):
        reason='缺少可靠丢包计数，重新建立滚动保护采样基线'
    elif s['phase']=='hold' and (sample['drops']<previous['drops'] or
                                 sample['overlimits']<previous['overlimits']):
        reason='丢包计数器清零/回绕，重新建立基线'
    if reason:
        break_continuity(s,reason);s['last']=sample;return False
    sample.update(birth_lo=birth_lo,birth_hi=birth_hi)
    delta=sample['bytes']-previous['bytes']
    midpoint=(low+high)/2
    s['mbps']=delta*8/midpoint/1000000
    s['lower_mbps']=delta*8/high/1000000
    if s['phase']=='hold':
        # tc's 'Sent' counts attempted/action-seen bytes (possibly dropped),
        # NOT acknowledged client throughput. Here it is pressure evidence.
        # Require either near-capacity attempted traffic, or repeated drops
        # accompanied by meaningful traffic. An isolated drop is insufficient.
        near=Decimal(delta)*10000 >= Decimal(str(high))*limited*ROLLING_NEAR_LIMIT_BP
        drop_delta=max(sample['drops']-previous['drops'],
                       sample['overlimits']-previous['overlimits'])
        congested=(Decimal(delta)*10000 >= Decimal(str(high))*limited*ROLLING_DROP_FLOOR_BP
                   and Decimal(drop_delta)>=Decimal(str(high))*ROLLING_DROP_PPS)
        if near or congested:
            if s.get('busy_since') is None:s['busy_since']=previous['end']
            confirmed=sample['start']-s['busy_since']>=min(ROLLING_CONFIRM_SECONDS,
                                                            options['hold'])
            if confirmed:
                s['last_busy_at']=sample['start']
                # Checkpoint at most once per ~half hold while constantly busy.
                # On falling edge finalize_hold_activity pins the exact deadline.
                if s['until']-sample['start']<=options['hold']/2:
                    s['until']=max(s['until'],sample['start']+options['hold'])
                s['reason']='滚动保护续期：'+('持续接近降速上限' if near else '持续超限丢包')
            else:
                s['reason']='检测到拥塞，等待连续采样确认'
        else:
            finalize_hold_activity(s,options['hold'])
            s['reason']='负载下降，等待滚动保护期结束'
        s.update(high_since=None,progress=0.0)
        return True
    if s['phase']!='monitor':
        s.update(high_since=None,progress=0.0,reason='冷却期间只展示采样');return True
    # Use the longest possible interval for threshold testing (conservative).
    above=Decimal(delta)*10000 >= Decimal(str(high))*base*options['trigger_bp']
    if not above:
        s.update(high_since=None,progress=0.0,reason='低于阈值，连续时间清零');return True
    if s['high_since'] is None:s['high_since']=previous['end']
    s['progress']=max(0.0,sample['start']-s['high_since'])
    s['reason']='连续窗口达到阈值'
    if s['progress']>=options['after']:
        s.update(phase='entering',until=None,high_since=None,progress=0.0,
                 last=None,busy_since=None,last_busy_at=None,reason='等待降速生效')
    return True


def advance_auto(rec,now,samples,errors):
    a=rec['auto'];rt=rec['runtime']
    checked=rt['checked_at']
    if checked is not None and now<checked:
        for s in rt['dirs'].values():break_continuity(s,'启动内时钟倒退；保持当前限速并等待修复')
        raise Error('CLOCK_BOOTTIME 倒退，拒绝提前恢复')
    rt['checked_at']=now
    for d,s in rt['dirs'].items():
        phase=s['phase']
        if phase=='cooldown' and now>=s['until']:
            break_continuity(s,'冷却结束，重新建立采样基线')
            s.update(phase='monitor',until=None)
        if s['phase'] in ('entering','restoring'):continue
        if samples.get(d) is None:
            if phase=='hold':finalize_hold_activity(s,a['hold'])
            break_continuity(s,errors.get(d,'采样失败'))
        else:
            valid=observe(s,samples[d],a['base'][d],a,
                          a['limited'][d] if phase=='hold' else None)
            if phase=='hold' and not valid:finalize_hold_activity(s,a['hold'])
        # Expiration MUST be evaluated after this tick's pressure evidence:
        # rolling protection cannot be released on a sustained busy tick.
        if s['phase']=='hold' and now>=s['until']:
            finalize_hold_activity(s,a['hold'])
            if now>=s['until']:
                break_continuity(s,'滚动保护到期，等待基础速度生效')
                s.update(phase='restoring',until=None,last_busy_at=None)
                rec[d]=a['base'][d];rec['pending']=True
        if s['phase']=='entering':rec[d]=a['limited'][d];rec['pending']=True


def finish_apply(port,rec,config,*,watch_rows=None,damaged_siblings=False):
    # Caller persists intent BEFORE any kernel mutation. On crash, replay is safe.
    if watch_rows is None and not damaged_siblings:
        apply(port,rec,config)
    else:
        apply(port,rec,config,watch_rows=watch_rows,damaged_siblings=damaged_siblings)
    if rec.get('deleting'):
        port_file(port).unlink(missing_ok=True)
        directory=os.open(port_file(port).parent,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(directory)
        finally:os.close(directory)
        volatile_clear(port)
        return
    if 'auto' in rec:
        now=boottime();a=rec['auto']
        for d,s in rec['runtime']['dirs'].items():
            if s['phase']=='entering':
                s.update(phase='hold',until=now+a['hold'],busy_since=None,last_busy_at=None,
                         reason='降速已通过审计，滚动保护开始')
                print(f'{port} {d}: 自动降速 {rate_mbps(rec[d])} Mbps，滚动保护 {a["hold"]} 秒')
            elif s['phase']=='restoring':
                s.update(phase='cooldown' if a['cooldown'] else 'monitor',
                         until=now+a['cooldown'] if a['cooldown'] else None,
                         busy_since=None,last_busy_at=None,
                         reason='基础速度已恢复')
                print(f'{port} {d}: 恢复基础速度 {rate_mbps(rec[d])} Mbps')
    rec['pending']=False
    write_json(port_file(port),rec)
    if 'auto' in rec:volatile_save(port,rec)


def reconcile(config,monitor=False):
    rows,failures=records_for_watch();identity=boot_id()
    # Preserve the original discovery result while failures are appended later.
    damaged_siblings=bool(failures)
    def finish_repair(port,rec):
        if damaged_siblings:
            finish_apply(port,rec,config,watch_rows=rows,damaged_siblings=True)
        else:
            finish_apply(port,rec,config)
    if any('auto' in r for r in rows.values()) and not config.get('tc_enabled'):
        raise Error('自动模式必须启用 tc；拒绝 nft-only 静默降级')
    for port,rec in rows.items():
        if 'auto' in rec and rec['runtime']['boot_id']!=identity:
            volatile_clear(port)
            reset_auto_boot(rec,identity);write_json(port_file(port),rec)
        elif 'auto' in rec:
            volatile_load(port,rec)
    try:
        nft_items=ensure_base()
        tc_items=tc_snapshot(config['iface']) if config.get('tc_enabled') else None
    except Exception:
        for port,rec in rows.items():
            if 'auto' in rec:
                for s in rec['runtime']['dirs'].values():break_continuity(s,'规则快照失败，连续时间清零')
                volatile_clear(port)
                write_json(port_file(port),rec)
        raise
    traffic=None;traffic_error='本轮没有有效统计'
    if monitor and any('auto' in r for r in rows.values()):
        try:traffic=traffic_snapshot()
        except Error as e:traffic_error=str(e);failures.append(traffic_error)
    for port,rec in rows.items():
        try:
            healthy=(not rec.get('pending') and nft_ok(port,rec,nft_items)
                     and (not config.get('tc_enabled') or tc_ok(port,rec,config['iface'],tc_items)))
            if 'auto' in rec:
                if not healthy:
                    for s in rec['runtime']['dirs'].values():break_continuity(s,'规则待修复，连续时间清零')
                    rec['pending']=True;write_json(port_file(port),rec)
                    finish_repair(port,rec)
                    # Do not use a snapshot taken before repair; next watch rebases.
                    continue
                if monitor:
                    samples={};errors={}
                    for d in CHAIN:
                        try:
                            if traffic is None:raise Error(traffic_error)
                            samples[d]=traffic_sample(port,d,rec,traffic,nft_items)
                        except Error as e:
                            samples[d]=None;errors[d]=str(e)
                            if traffic is not None:failures.append(f'{port}/{d}: {e}')
                    durable_before=volatile_checkpoint(rec)
                    advance_auto(rec,boottime(),samples,errors)
                    if rec.get('pending') or volatile_checkpoint(rec)!=durable_before:
                        # Persist decisions before any kernel change; not raw samples.
                        write_json(port_file(port),rec)
                        if rec.get('pending'):
                            finish_repair(port,rec)
                        else:volatile_save(port,rec)
                    else:
                        # One atomic tmpfs write per tick; avoids fsyncing flash/disk
                        # once every 30 seconds for every monitored port.
                        volatile_save(port,rec)
            elif not healthy or rec.get('deleting'):
                rec['pending']=True;write_json(port_file(port),rec)
                finish_repair(port,rec)
        except Exception as e:
            # Save continuity failure without inventing a new bandwidth target.
            if 'auto' in rec:
                for s in rec['runtime']['dirs'].values():break_continuity(s,'本轮操作失败，等待修复')
                volatile_clear(port)
                write_json(port_file(port),rec)
            failures.append(f'{port}: {e}')
    if failures:raise Error('自检/采样失败：'+'；'.join(failures))


def auto_operate(args,config):
    port=port_num(args.port)
    if args.auto_action=='set':
        if not config.get('tc_enabled'):raise Error('auto set 必须使用 tc，不能 nft-only')
        options=auto_options(args)
        current=read_json(port_file(port),default={'port':port,'up':0,'down':0})
        validate_record(port,current)
        commit(port,options['base']['up'],options['base']['down'],config,auto=options)
        print(f'{port}: 自动模式已保存，上下行独立监测；after={options["after"]}s / 滚动hold={options["hold"]}s')
        return
    rec=read_json(port_file(port));validate_record(port,rec)
    if args.auto_action=='status' and 'auto' in rec:volatile_load(port,rec)
    if args.auto_action=='off':
        if 'auto' not in rec:
            print(f'{port}: 已为静态模式');return
        base=rec['auto']['base']
        commit(port,base['up'],base['down'],config)
        print(f'{port}: 自动模式已关闭并恢复基础带宽');return
    if 'auto' not in rec:
        print(f'{port}: 静态模式，上传 {rate_mbps(rec["up"])} / 下载 {rate_mbps(rec["down"])} Mbps');return
    nft_items=nft_snapshot(False)
    tc_items=tc_snapshot(config['iface']) if config.get('tc_enabled') else None
    state,_,_=audit_one(port,rec,config,nft_items,tc_items)
    now=boottime();a=rec['auto'];rt=rec['runtime']
    same_boot=rt['boot_id']==boot_id()
    print(f'端口 {port}: 内核审计={state} pending={rec.get("pending",False)}；'
          '当前速度为目标配置，审计 OK 才表示内核已匹配')
    print(f'阈值={a["trigger_bp"]/100:g}% 连续={a["after"]}s 滚动保护={a["hold"]}s 冷却={a["cooldown"]}s')
    for d,s in rt['dirs'].items():
        age=max(0,now-s['last']['end']) if same_boot and s['last'] else None
        fresh=age is not None and age<=max_sample_gap(a) and state=='OK'
        measured=f'{s["mbps"]:.4f}' if fresh and s['mbps'] is not None else '不可用/过期'
        lower=f'{s["lower_mbps"]:.4f}' if fresh and s['lower_mbps'] is not None else '不可用'
        remain=max(0,s['until']-now) if same_boot and s['until'] is not None else None
        progress=s['progress'] if fresh else 0
        print(f'{d}: 基础={rate_mbps(a["base"][d])} 当前目标={rate_mbps(rec[d])} '
              f'采样={measured} Mbps 判定下界={lower} Mbps 样本年龄={age}秒 '
              f'阶段={s["phase"]} 连续进度={progress:.1f}/{a["after"]}秒 '
              f'保护/冷却剩余={remain}秒；{s["reason"]}')
    print('采样值为最近一次 watch 的窗口平均值；status 只读，不改变触发计时。')
    if not same_boot:print('检测到重启：等待 repair/watch 恢复基础带宽并重建监测。')


def listen_ports():
    out=run(['ss','-H','-ltnu'],check=False) or ''
    found=set()
    for row in out.splitlines():
        m=re.search(r':(\d+)\s',row+' ')
        if m:found.add(int(m.group(1)))
    return found

def audit_one(port,rec,config,nft_items=None,tc_items=None):
    nft=nft_ok(port,rec,nft_items)
    tc=tc_ok(port,rec,config['iface'],tc_items) if config.get('tc_enabled') else None
    return ('OK' if nft and (tc is None or tc) and not (rec['down']>0 and tc is None)
            and not rec.get('pending')
            and ('auto' not in rec or rec['runtime']['boot_id']==boot_id()) else 'STALE',nft,tc)

def units():
    exe='/usr/local/sbin/portbw'
    return {
    'portbw-restore.service':f'''[Unit]
Description=Restore persistent independent port bandwidth policies
After=local-fs.target nftables.service systemd-udev-settle.service
Before=multi-user.target

[Service]
Type=oneshot
ExecStart={exe} repair
TimeoutStartSec=120
UMask=0077

[Install]
WantedBy=multi-user.target
''',
    'portbw-watch.service':f'''[Unit]
Description=Check and repair independent port bandwidth rules
After=local-fs.target
# At 1-second cadence, systemd's default 5 starts / 10 seconds causes
# start-limit-hit (confirmed on Debian 12).  This applies ONLY to portbw.
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart={exe} watch
TimeoutStartSec=120
UMask=0077
''',
    'portbw-watch.timer':'''[Unit]
Description=Check port bandwidth policies every 1 second (best-effort)

[Timer]
OnBootSec=20s
OnUnitInactiveSec=1s
AccuracySec=100ms
Unit=portbw-watch.service

[Install]
WantedBy=timers.target
''',
    }

def install(args):
    for program in ('nft','tc','ip','ss','systemctl'):
        if not shutil.which(program):raise Error(f'缺少命令：{program}')
    if not Path('/run/systemd/system').exists():raise Error('需要 PID1=systemd')
    with lock():
        before=cfg() if (CONF/'config.json').exists() else {}
        iface=args.iface or before.get('iface')
        if not iface or not IF_RE.fullmatch(iface) or iface in ('.','..'):
            raise Error('请指定合法 --iface，例如 eth0')
        run(['ip','link','show','dev',iface])
        enabled=not args.nft_only
        if args.iface is None and args.nft_only is False and before:
            enabled=before.get('tc_enabled',True)
        config={'iface':iface,'tc_enabled':enabled,'version':2}
        # A mode change with existing policies can leave old tc limits silently
        # enforced while the CLI reports tc=off.  Refuse rather than misreport.
        if before and before.get('tc_enabled',True)!=enabled and records():
            raise Error('已有端口策略时不允许直接切换 tc/nft-only 模式；先手动核对并迁移现有 tc 规则')
        # Validate before publishing. An ingress qdisc collision is not removed.
        if enabled:
            kinds={e.get('kind') for e in tc_qdiscs(iface)}
            if 'ingress' in kinds and 'clsact' not in kinds:
                raise Error('已有 ingress qdisc，不覆盖；请用 --nft-only 明确选择单层')
        # Test nft named limit support at parsing level without creating a live probe table.
        run(['nft','-c','-f','-'],input=(
            'add table inet pbw_capability_probe\n'
            'add chain inet pbw_capability_probe test { type filter hook input priority -5; policy accept; }\n'
            'add limit inet pbw_capability_probe lim { rate over 125000 bytes/second burst 16384 bytes; }\n'
            'add rule inet pbw_capability_probe test meta l4proto { tcp, udp } th dport 54321 limit name "lim" drop\n'))
        # Never replace settings while active policies would silently migrate to a different iface.
        if before and before.get('iface')!=iface and records():
            raise Error('已有端口规则，禁止静默修改绑定网卡；先在原网卡解除 tc 后迁移')
        ensure_base()
        cfg_path=CONF/'config.json'
        old_cfg=cfg_path.read_bytes() if cfg_path.exists() else None
        unit_paths={n:UNITS/n for n in units()}
        old_units={n:(p.read_bytes() if p.exists() else None) for n,p in unit_paths.items()}
        old_enabled={n:run(['systemctl','is-enabled',n],check=False) for n in unit_paths}
        old_active={n:run(['systemctl','is-active',n],check=False) for n in unit_paths}
        try:
            write_json(cfg_path,config)
            for name,body in units().items():
                write_atomic(unit_paths[name],body.encode(),0o644)
            run(['systemctl','daemon-reload'])
            # Check the EFFECTIVE property, not just the text: a drop-in override
            # or unrecognized directive must not silently break 1s sampling.
            limit=run(['systemctl','show','portbw-watch.service',
                       '-p','StartLimitIntervalUSec'])
            if limit is None or limit.strip()!='StartLimitIntervalUSec=0':
                raise Error('portbw-watch.service 启动频率限制未关闭；'
                            f'实际={limit!r}；请检查 systemd drop-in 覆盖配置')
            # Fresh installs can have a never-started service that is not loaded.
            # Do not call reset-failed unless systemd reports an actual failure.
            # run(..., check=False) returns None for a nonzero exit status, but
            # returns '' when is-failed --quiet reports success (exit status 0).
            if run(['systemctl','is-failed','--quiet','portbw-watch.service'], check=False) is not None:
                run(['systemctl','reset-failed','portbw-watch.service'])
            run(['systemctl','enable','portbw-restore.service','portbw-watch.timer'])
            if enabled:tc_prepare(iface)
            for port,rec in records().items():
                if 'auto' in rec and rec['runtime']['boot_id']!=boot_id():
                    reset_auto_boot(rec,boot_id());write_json(port_file(port),rec)
                finish_apply(port,rec,config)
            run(['systemctl','start','portbw-watch.timer'])
        except BaseException:
            # Roll back only config/units written here; saved port policies stay (pending) for repair.
            try:
                if old_cfg is None:cfg_path.unlink(missing_ok=True)
                else:write_atomic(cfg_path,old_cfg)
                for name,old in old_units.items():
                    if old is None:
                        run(['systemctl','disable',name],check=False);unit_paths[name].unlink(missing_ok=True)
                    else:write_atomic(unit_paths[name],old,0o644)
                run(['systemctl','daemon-reload'],check=False)
                for name,old in old_enabled.items():
                    if (old or '').strip() in ('enabled','enabled-runtime','linked','linked-runtime'):
                        run(['systemctl','enable',name],check=False)
                    else:
                        run(['systemctl','disable',name],check=False)
                for name,old in old_active.items():
                    if (old or '').strip()=='active':run(['systemctl','start',name],check=False)
                    else:run(['systemctl','stop',name],check=False)
            except Exception as e:print(f'回滚配置时出错：{e}',file=sys.stderr)
            raise
        print(f'portbw 安装/更新完成；接口={iface}；双层 tc={enabled}；不会修改 root qdisc。')

def _report_char_width(char):
    # Match the independent vless_audit.sh table renderer: CJK is 2 cells.
    from unicodedata import combining, east_asian_width
    if char in ('\n','\r') or combining(char):return 0
    return 2 if east_asian_width(char) in ('W','F') else 1


def _report_width(value):
    return sum(_report_char_width(char) for char in str(value))


def _report_pad(value,width,align='left'):
    value=str(value)
    gap=' '*max(0,width-_report_width(value))
    return gap+value if align=='right' else value+gap


def _report_wrap(value,width):
    value=str(value or '-')
    parts=[]
    for line in value.replace('\r','').split('\n'):
        line=line.strip()
        if not line:
            parts.append('');continue
        while _report_width(line)>width:
            cut=0;used=0
            for i,char in enumerate(line):
                w=_report_char_width(char)
                if used+w>width:break
                cut=i+1;used+=w
            if not cut:cut=1
            # Break at a natural slash or separator when possible, like VLESS.
            breaking=max((i+1 for i,char in enumerate(line[:cut]) if char in '/_:- '),default=0)
            if breaking and breaking>=cut//2:cut=breaking
            parts.append(line[:cut].rstrip())
            line=line[cut:].lstrip()
        parts.append(line)
    return parts or ['-']


def _report_table(schema,rows):
    """Same heavy box borders, row separators and CJK alignment as vless_audit.sh.

    Standalone on purpose: SOCKS5 hosts may not have VLESS's renderer installed.
    schema: (heading,min_width,ideal_width,max_width,align,weight).
    """
    headings=[item[0] for item in schema]
    minimum=[item[1] for item in schema]
    ideal=[item[2] for item in schema]
    maximum=[item[3] for item in schema]
    aligned=[item[4] for item in schema]
    weights=[item[5] for item in schema]
    columns_env=os.environ.get('COLUMNS','').strip()
    term=int(columns_env) if columns_env.isdecimal() and int(columns_env)>0 else shutil.get_terminal_size(fallback=(120,24)).columns
    available=max(sum(minimum),term-len(schema)-1)
    widths=ideal[:]
    if sum(widths)>available:
        order=sorted(range(len(schema)),key=lambda i:(weights[i],ideal[i]-minimum[i]),reverse=True)
        remaining=sum(widths)-available
        while remaining:
            changed=False
            for i in order:
                if widths[i]>minimum[i]:
                    widths[i]-=1;remaining-=1;changed=True
                    if not remaining:break
            if not changed:break
    elif sum(widths)<available:
        order=sorted(range(len(schema)),key=lambda i:(weights[i],maximum[i]-ideal[i]),reverse=True)
        remaining=available-sum(widths)
        while remaining:
            changed=False
            for i in order:
                if widths[i]<maximum[i]:
                    widths[i]+=1;remaining-=1;changed=True
                    if not remaining:break
            if not changed:break
    def edge(left,mid,right):return left+mid.join('━'*w for w in widths)+right
    print(edge('┏','┳','┓'))
    print('┃'+'│'.join(_report_pad(h,w) for h,w in zip(headings,widths))+'┃')
    print(edge('┣','╋','┫'))
    for i,row in enumerate(rows):
        wrapped=[_report_wrap(item,w) for item,w in zip(row,widths)]
        for line_index in range(max(map(len,wrapped))):
            cells=[_report_pad(parts[line_index] if line_index<len(parts) else '',widths[j],aligned[j])
                   for j,parts in enumerate(wrapped)]
            print('┃'+'│'.join(cells)+'┃')
        if i+1<len(rows):print(edge('┣','╋','┫'))
    print(edge('┗','┻','┛'))


def _report_one_table(items):
    """全中文单表格：每个端口一行；窄终端优先保留限速核心信息。"""
    columns=[
        ('端口','right'),('模式','left'),('当前上/下','right'),
        ('正常上/下','right'),('降速上/下','right'),('运行阶段','left'),
        ('阈值','right'),('持续','right'),('保护','right'),('冷却','right'),
        ('监听','left'),('防火墙','left'),('流控','left'),('状态','left'),
    ]
    widths=[max(_report_width(head),*(_report_width(row[i]) for row in items))
            for i,(head,_) in enumerate(columns)]
    columns_env=os.environ.get('COLUMNS','').strip()
    term=(int(columns_env) if columns_env.isdecimal() and int(columns_env)>0
          else shutil.get_terminal_size(fallback=(120,24)).columns)
    show=list(range(len(columns)))
    # 诊断类信息在窄终端下最后显示；限速值和触发条件永不省略。
    # 运行阶段也尽量保留；如终端极窄，仍保持一端口一行而不拆成多张表。
    for i in (10,11,12,5):
        if sum(widths[j] for j in show)+len(show)+1<=term:break
        show.remove(i)
    frame_width=sum(widths[j] for j in show)+len(show)+1
    if frame_width>term:
        print(f'注意：当前终端宽度为 {term} 列，完整限速参数需要 {frame_width} 列；'
              '请加宽终端，表格不会截断数值。')
    schema=[(columns[i][0],widths[i],widths[i],widths[i],columns[i][1],1)
            for i in show]
    _report_table(schema,[tuple(str(row[i]) for i in show) for row in items])
    hidden=[columns[i][0] for i in range(len(columns)) if i not in show]
    if hidden:
        print('因终端较窄暂不显示：'+'、'.join(hidden)+'；加宽窗口可查看全部列。')


def report_all(config):
    """只读查询全部限速：静态、自动混排，使用现有内核审计快照。"""
    rows=records()
    if not rows:
        print('当前没有已保存的端口限速规则。')
        return
    listening=listen_ports()
    nft_items=nft_snapshot(False)
    tc_items=tc_snapshot(config['iface']) if config.get('tc_enabled') else None
    phases={'monitor':'监控','entering':'应用中','hold':'保护中',
            'restoring':'恢复中','cooldown':'冷却'}
    auto_count=0;unhealthy=[];items=[]
    for port,rec in sorted(rows.items()):
        state,nft,tc=audit_one(port,rec,config,nft_items,tc_items)
        a=rec.get('auto')
        now=f'{rate_mbps(rec["up"])}/{rate_mbps(rec["down"])}'
        if a:
            auto_count+=1
            base=f'{rate_mbps(a["base"]["up"])}/{rate_mbps(a["base"]["down"])}'
            limited=f'{rate_mbps(a["limited"]["up"])}/{rate_mbps(a["limited"]["down"])}'
            phases_now=rec['runtime']['dirs']
            phase=f'{phases[phases_now["up"]["phase"]]}/{phases[phases_now["down"]["phase"]]}'
            trigger=f'{a["trigger_bp"]/100:g}%'
            after=f'{a["after"]}s'
            hold=f'{a["hold"]}s'
            cool=f'{a["cooldown"]}s'
        else:
            base=now;limited=phase=trigger=after=hold=cool='-'
        items.append((port,'自动' if a else '静态',now,base,limited,phase,
                      trigger,after,hold,cool,
                      '是' if port in listening else '否','正常' if nft else '异常',
                      '停用' if tc is None else '正常' if tc else '异常',
                      '正常' if state=='OK' else '异常'))
        if state!='OK':unhealthy.append(port)
    print(f'端口限速总览：共 {len(rows)} 个端口；速度单位 Mbps（上/下=上传/下载）')
    _report_one_table(items)
    print('说明：当前=正在生效的限速；正常=基础速度；降速=触发后的速度；'
          '运行阶段=上传/下载分别对应的状态。')
    print('阈值=触发百分比；持续=触发前连续秒数；保护=滚动保护秒数；'
          '冷却=恢复后等待秒数；“-”表示静态模式不适用。')
    print(f'合计 {len(rows)} 个端口：自动 {auto_count}，静态 {len(rows)-auto_count}；内核异常 {len(unhealthy)}。')
    if unhealthy:
        print('注意：端口 '+', '.join(map(str,unhealthy))+' 的规则状态异常，请运行 portbw audit 检查。')
    print('提示：本命令只读，不会修复规则、改变限速或重置滚动保护计时。')


def operate(args):
    action=args.action
    if action=='install':return install(args)
    with lock(try_only=action=='watch') as got:
        if not got:return
        config=cfg()
        if action in ('set','up','down','del'):
            port=port_num(args.port)
            current=read_json(port_file(port),default={'port':port,'up':0,'down':0})
            validate_record(port,current)
            if 'auto' in current:
                current=dict(current,**current['auto']['base'])
                print('手动操作将关闭该端口自动模式；未指定方向使用基础带宽')
            if action=='set':up,down=rate_bytes(args.up_mbit),rate_bytes(args.down_mbit)
            elif action=='up':up,down=rate_bytes(args.up_mbit),current['down']
            elif action=='down':up,down=current['up'],rate_bytes(args.down_mbit)
            else:up=down=0
            if action!='del' and up==down==0:
                raise Error('两方向都是 0，请执行 portbw del <port> 删除规则')
            commit(port,up,down,config,deleting=action=='del')
            print(f'{port}: {"已手动取消" if action=="del" else f"上传 {rate_mbps(up)}Mbps / 下载 {rate_mbps(down)}Mbps"}')
            return
        if action=='report':return report_all(config)
        if action=='auto':return auto_operate(args,config)
        if action in ('watch','repair'):
            reconcile(config,monitor=action=='watch')
            if action=='repair':print('所有已保存端口策略已校验/修复')
            return
        if action in ('list','audit','show'):
            failures=[]
            if action=='show':
                port=port_num(args.port);rec=read_json(port_file(port));validate_record(port,rec);rows={port:rec}
            else:rows=records()
            listening=listen_ports()  # audit also reports actual LISTEN state
            nft_items=nft_snapshot(False)
            tc_items=tc_snapshot(config['iface']) if config.get('tc_enabled') else None
            print(f'{"PORT":>5} {"UP Mbps":>10} {"DOWN Mbps":>10} {"LISTEN":>8} {"NFT":>6} {"TC":>7}  STATE')
            for port,rec in rows.items():
                state,nft,tc=audit_one(port,rec,config,nft_items,tc_items)
                print(f'{port:>5} {rate_mbps(rec["up"]):>10} {rate_mbps(rec["down"]):>10} '
                      f'{("yes" if port in listening else "no"):>8} {("ok" if nft else "MISSING"):>6} '
                      f'{("off" if tc is None else "ok" if tc else "MISSING"):>7}  {state}')
                if state!='OK':failures.append(port)
            if failures and action=='audit':raise Error('有异常限速端口：'+','.join(map(str,failures)))
            return
        if action=='status':
            print(json.dumps({'config':config,'policies':len(records()),'kernel_table':nft_snapshot(False) is not None},indent=2,ensure_ascii=False))
            return
        raise Error('未知命令')

def main():
    os.umask(0o077)
    p=argparse.ArgumentParser(description='独立端口聚合限速（永久保存端口规则，与节点无关）')
    subs=p.add_subparsers(dest='action',required=True)
    x=subs.add_parser('install');x.add_argument('--iface');x.add_argument('--nft-only',action='store_true',help='仅使用 nft，禁用 tc 次级保护')
    x=subs.add_parser('set');x.add_argument('port');x.add_argument('up_mbit');x.add_argument('down_mbit')
    x=subs.add_parser('up');x.add_argument('port');x.add_argument('up_mbit')
    x=subs.add_parser('down');x.add_argument('port');x.add_argument('down_mbit')
    x=subs.add_parser('del');x.add_argument('port')
    x=subs.add_parser('show');x.add_argument('port')
    x=subs.add_parser('auto');auto_sub=x.add_subparsers(dest='auto_action',required=True)
    y=auto_sub.add_parser('set');y.add_argument('port')
    for flag in ('up','down','trigger','after','auto-up','auto-down','hold'):
        y.add_argument('--'+flag,required=True)
    y.add_argument('--cooldown',default='60s',help='恢复后冷却时间，默认 60s，可设 0s')
    for name in ('status','off'):
        y=auto_sub.add_parser(name);y.add_argument('port')
    for name in ('list','report','audit','repair','watch','status'):subs.add_parser(name)
    try:
        if os.geteuid():raise Error('请使用 root')
        operate(p.parse_args())
    except (Error,OSError,ValueError,KeyError,TypeError) as e:
        print('错误：',e,file=sys.stderr);sys.exit(1)

if __name__=='__main__':main()
