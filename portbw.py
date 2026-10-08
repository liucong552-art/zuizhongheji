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
                           capture_output=True, timeout=timeout)
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
def cfg():return read_json(CONF/'config.json')

def records():
    rows={}
    for p in sorted((STATE/'ports').glob('*.json')):
        try:port=port_num(p.stem)
        except Error:raise Error(f'非法配置文件名：{p}')
        rec=read_json(p)
        if rec.get('port')!=port or not all(isinstance(rec.get(x),int) and rec[x]>=0 for x in ('up','down')):
            raise Error(f'端口配置损坏：{p}')
        rows[port]=rec
    return rows

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
        proc=subprocess.run(args,text=True,capture_output=True,timeout=25)
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

def apply_nft(port,rec):
    items=ensure_base()
    rows,objs=owned(items,port)
    script=[f'delete rule inet {TABLE} {chain} handle {h}' for chain,h in sorted(rows,key=lambda e:e[1],reverse=True)]
    script += [f'delete {kind} inet {TABLE} {name}' for kind,name in objs]
    for d in CHAIN:
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

def ensure_tc_prefs(port,rec,iface):
    """Allocate FOUR globally distinct flower priorities; persist before installing."""
    rows={d:tc_filters(iface,d) for d in ('ingress','egress')}
    used=set()
    for other,r in records().items():
        if other==port:continue
        prefs=r.get('tc_prefs')
        if not isinstance(prefs,dict) or set(prefs)!={tc_slot_key(f,t) for f in FAMILIES for t in TRANSPORTS}:
            raise Error(f'{other}: 检测到旧版/损坏的 tc pref，测试版要求恢复未安装 portbw 的快照')
        for value in prefs.values():
            if type(value) is not int or not 1<=value<=65535 or value in used:
                raise Error(f'{other}: tc pref 重复/损坏')
            used.add(value)
    slots=[(f,t) for f in FAMILIES for t in TRANSPORTS]
    existing=rec.get('tc_prefs')
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

def tc_rate_is_ok(entry,b,iface,direction,port,family,transport,rec,text=None):
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
        if abs(actual-desired)>max(Decimal(1000),desired*Decimal('0.0005')):return False
        bm=re.search(r'\bburst\s+([0-9]+(?:\.[0-9]+)?)([kKmMgG]?)b\b',line)
        if not bm:return False
        actual_burst=_quantity_bytes(bm.group(1),bm.group(2))
        desired_burst=Decimal(tc_burst_kb(b)*1024)
        if abs(actual_burst-desired_burst)>max(Decimal(256),desired_burst*Decimal('0.05')):return False
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
        if not existing and tc_action_exists(index):
            raise Error(f'{port}: tc police index {index} 已被占用，拒绝覆盖')
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

def apply(port,rec,config):
    if rec['down']>0 and not config.get('tc_enabled'):
        raise Error('UDP/TCP 下载限速必须使用 tc egress；不可采用 nft-only，以免本地发送程序收到 EPERM')
    if not nft_ok(port,rec):apply_nft(port,rec)
    if config.get('tc_enabled'):
        ensure_tc_prefs(port,rec,config['iface'])
        if not tc_ok(port,rec,config['iface']):
            apply_tc(port,rec,config['iface'])
            if not tc_ok(port,rec,config['iface']):
                raise Error(f'{port} 双层限速尚未通过完整审计，保留 pending 状态供修复')


def commit(port,up,down,config,deleting=False):
    old=read_json(port_file(port),default={})
    rec={'port':port,'up':up,'down':down,'updated':int(time.time()),
         'pending':True,'deleting':deleting}
    if 'tc_prefs' in old:rec['tc_prefs']=old['tc_prefs']
    write_json(port_file(port),rec)
    apply(port,rec,config)  # on failure the pending record is deliberately kept
    if deleting:port_file(port).unlink(missing_ok=True)
    else:
        rec['pending']=False;write_json(port_file(port),rec)

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
            and not rec.get('pending') else 'STALE',nft,tc)

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

[Service]
Type=oneshot
ExecStart={exe} watch
TimeoutStartSec=120
UMask=0077
''',
    'portbw-watch.timer':'''[Unit]
Description=Check port bandwidth policies every 30 seconds

[Timer]
OnBootSec=20s
OnUnitInactiveSec=30s
AccuracySec=5s
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
        before=read_json(CONF/'config.json',default={})
        iface=args.iface or before.get('iface')
        if not iface or not IF_RE.fullmatch(iface) or iface in ('.','..'):
            raise Error('请指定合法 --iface，例如 eth0')
        run(['ip','link','show','dev',iface])
        enabled=not args.nft_only
        if args.iface is None and args.nft_only is False and before:
            enabled=before.get('tc_enabled',True)
        config={'iface':iface,'tc_enabled':enabled,'version':1}
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
            run(['systemctl','enable','portbw-restore.service','portbw-watch.timer'])
            if enabled:tc_prepare(iface)
            for port,rec in records().items():
                apply(port,rec,config)
                if rec.get('deleting'):port_file(port).unlink(missing_ok=True)
                elif rec.get('pending'):
                    rec['pending']=False;write_json(port_file(port),rec)
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

def operate(args):
    action=args.action
    if action=='install':return install(args)
    with lock(try_only=action=='watch') as got:
        if not got:return
        config=cfg()
        if action in ('set','up','down','del'):
            port=port_num(args.port)
            current=read_json(port_file(port),default={'port':port,'up':0,'down':0})
            if action=='set':up,down=rate_bytes(args.up_mbit),rate_bytes(args.down_mbit)
            elif action=='up':up,down=rate_bytes(args.up_mbit),current['down']
            elif action=='down':up,down=current['up'],rate_bytes(args.down_mbit)
            else:up=down=0
            if action!='del' and up==down==0:
                raise Error('两方向都是 0，请执行 portbw del <port> 删除规则')
            commit(port,up,down,config,deleting=action=='del')
            print(f'{port}: {"已手动取消" if action=="del" else f"上传 {rate_mbps(up)}Mbps / 下载 {rate_mbps(down)}Mbps"}')
            return
        if action in ('watch','repair'):
            failures=[];snap=ensure_base();tc_on=config.get('tc_enabled')
            tc_items=tc_snapshot(config['iface']) if tc_on else None
            for port,rec in records().items():
                try:
                    if not rec.get('deleting') and not rec.get('pending') and nft_ok(port,rec,snap) \
                            and (not tc_on or tc_ok(port,rec,config['iface'],tc_items)):continue
                    apply(port,rec,config)
                    if rec.get('deleting'):port_file(port).unlink(missing_ok=True)
                    elif rec.get('pending'):
                        rec['pending']=False;write_json(port_file(port),rec)
                except Exception as e:failures.append(f'{port}: {e}')
            if failures:raise Error('修复失败：'+'；'.join(failures))
            if action=='repair':print('所有已保存端口策略已校验/修复')
            return
        if action in ('list','audit','show'):
            failures=[]
            if action=='show':rows={port_num(args.port):read_json(port_file(args.port))}
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
    for name in ('list','audit','repair','watch','status'):subs.add_parser(name)
    try:
        if os.geteuid():raise Error('请使用 root')
        operate(p.parse_args())
    except (Error,OSError,ValueError,KeyError,TypeError) as e:
        print('错误：',e,file=sys.stderr);sys.exit(1)

if __name__=='__main__':main()
