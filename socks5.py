#!/usr/bin/env python3
"""Standalone, fail-closed SOCKS5 node manager for a WG-NAT exit host.
No imports, lock files, nft tables, service names or state from vless-reality.
"""
from __future__ import annotations
import argparse
import contextlib
import datetime as dt
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.request
import urllib.error
from urllib.parse import quote
from decimal import Decimal, InvalidOperation

STATE = Path(os.getenv('S5_STATE', '/var/lib/socks5-manager'))
CONF = Path(os.getenv('S5_CONF', '/etc/socks5-manager'))
RUN = Path(os.getenv('S5_RUN', '/run/socks5-manager'))
UNITDIR = Path(os.getenv('S5_UNITS', '/etc/systemd/system'))
BIN = os.getenv('S5_3PROXY', shutil.which('3proxy') or '/usr/bin/3proxy')
TABLE_IP, TABLE_Q = 's5m_ip', 's5m_quota'
IP_CHAIN, Q_IN, Q_OUT = 'inbound', 'inbound', 'outbound'
ID_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,47}\Z')
PORT_MIN, PORT_MAX = 40000, 50050
D30 = 2592000
# These networks must not be reachable via an authenticated proxy. SOCKS ACL
# remains a defense in depth; deployment must test DNS re-resolution behavior.
BLOCKED = ('0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
           '169.254.0.0/16', '172.16.0.0/12', '192.0.0.0/24',
           '192.0.2.0/24', '192.168.0.0/16', '198.18.0.0/15',
           '198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/4',
           '240.0.0.0/4')

class Fail(Exception):
    pass

def cmd(args, *, input=None, timeout=40, required=True):
    try:
        p = subprocess.run(list(map(str, args)), input=input, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as e:
        if required: raise Fail(f'执行 {args[0]} 失败: {e}') from e
        return None
    if p.returncode != 0:
        if required: raise Fail(f'命令失败 {args}: {p.stderr.strip()[:800]}')
        return None
    return p.stdout

def atomic_json(path, value):
    atomic_write(path, (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode())

def atomic_write(path, value, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name + '.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(value); f.flush(); os.fchmod(f.fileno(), mode); os.fsync(f.fileno())
        os.replace(tmp, path)
        fd2 = os.open(str(path.parent), os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(fd2)
        finally: os.close(fd2)
    finally:
        if os.path.lexists(tmp): os.unlink(tmp)

def load(path, default=None):
    if not path.exists():
        if default is None: raise Fail(f'缺少状态文件：{path}')
        return default
    if path.is_symlink(): raise Fail(f'拒绝读取符号链接：{path}')
    try: return json.loads(path.read_text(encoding='utf8'))
    except (ValueError, OSError) as e: raise Fail(f'状态损坏，拒绝继续：{path}: {e}') from e

def must_id(s):
    if not ID_RE.fullmatch(s): raise Fail('ID 需以字母或数字开头，可含点、下划线和连字符（1-48 位）')
    return s

def nodefile(tag): return STATE / 'nodes' / (must_id(tag) + '.json')
def proxycfg(tag): return CONF / 'nodes' / (must_id(tag) + '.cfg')
def settings(): return load(CONF / 'settings.json')
def node(tag):
    d=load(nodefile(tag))
    if d.get('id')!=tag or not isinstance(d.get('instance'),str): raise Fail(f'节点 {tag} 元数据身份不匹配')
    return d

def nodes():
    result=[]
    for p in sorted((STATE/'nodes').glob('*.json')):
        result.append(node(p.stem))
    ports=[n['port'] for n in result]
    if len(set(ports))!=len(ports): raise Fail('节点使用相同监听端口，拒绝管理')
    return result

def resolve_node(reference):
    """Public CLI accepts a managed local port or the legacy node ID.

    Systemd/restore paths keep using immutable IDs. Never guess if a decimal
    reference could name both a port and a different explicit account ID.
    """
    reference=str(reference)
    if reference.isascii() and reference.isdecimal():
        port=num(reference,'端口',1,65535)
        matches=[n for n in nodes() if n['port']==port]
        if nodefile(reference).exists() and (not matches or matches[0]['id']!=reference):
            raise Fail(f'{reference} 同时可能是账号 ID 与端口；请使用非数字的账号 ID')
        if not matches:raise Fail(f'未找到本机 SOCKS5 监听端口 {port} 对应的账号；运行 socks5 list 查看端口')
        return matches[0]
    return node(reference)


@contextlib.contextmanager
def locked(wait=90, nonblocking=False):
    RUN.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (RUN/'manager.lock').open('a+') as f:
        end=time.monotonic()+wait
        while True:
            try:
                fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB); break
            except BlockingIOError:
                if nonblocking: yield False; return
                if time.monotonic()>end: raise Fail('管理锁繁忙，稍后重试')
                time.sleep(.1)
        try: yield True
        finally: fcntl.flock(f, fcntl.LOCK_UN)

def num(value, label, lower, upper):
    try: val=int(str(value))
    except ValueError: raise Fail(f'{label} 需要整数')
    if str(val)!=str(value) or not lower<=val<=upper: raise Fail(f'{label} 范围 {lower}..{upper}')
    return val

def gib_bytes(value):
    if value is None: return None
    try: n=Decimal(str(value)); b=n*Decimal(1024**3)
    except InvalidOperation: raise Fail('PQ_GIB 必须为正数')
    if not n.is_finite() or b<1 or b>Decimal('9000000000000000000') or b!=int(b):
        raise Fail('PQ_GIB 必须是正数，换算后为整数字节，且不能溢出')
    return int(b)

def connection_link(n):
    """Create a portable URI for clients that support socks5:// imports."""
    # Quote credentials so the URI stays valid even if account generation changes.
    user = quote(n['username'], safe='')
    password = quote(n['password'], safe='')
    return f'socks5://{user}:{password}@{n["public_host"]}:{n["public_port"]}'

def public_host(s):
    if not s or not re.fullmatch(r'[A-Za-z0-9._-]{1,253}',s): raise Fail('公网地址/域名格式错误')
    return s

def validate_iface(iface):
    if not re.fullmatch(r'[A-Za-z0-9_.-]{1,15}',iface) or iface in ('.','..'):
        raise Fail('非法 WAN_IF')
    cmd(['ip', 'link', 'show', 'dev', iface])
    if iface.startswith(('wg','tun','tailscale')): raise Fail('WAN_IF 不允许选择隧道接口')
    return iface

def local_route(iface):
    out=cmd(['ip','-4','route','get','1.1.1.1','oif',iface],required=False) or ''
    if not re.search(r'\bdev\s+'+re.escape(iface)+r'\b',out):
        raise Fail(f'无法验证经 {iface} 的 IPv4 路由')
    return out.strip()

def prepare_dirs():
    for d in (STATE,STATE/'nodes',CONF,CONF/'nodes',RUN):
        d.mkdir(parents=True,exist_ok=True,mode=0o700)
        os.chmod(d,0o700)

def ensure_tables():
    defs = [(TABLE_IP,f'add table inet {TABLE_IP}\nadd chain inet {TABLE_IP} {IP_CHAIN} {{ type filter hook input priority -10; policy accept; }}\n'),
            (TABLE_Q,f'add table inet {TABLE_Q}\nadd chain inet {TABLE_Q} {Q_IN} {{ type filter hook input priority 0; policy accept; }}\nadd chain inet {TABLE_Q} {Q_OUT} {{ type filter hook output priority 0; policy accept; }}\n')]
    for table,body in defs:
        if cmd(['nft','-j','list','table','inet',table],required=False) is None:
            cmd(['nft','-f','-'],input=body)

def nft_table(table):
    out=cmd(['nft','-j','list','table','inet',table],required=False)
    if out is None: raise Fail(f'缺少 nft 表 {table}')
    try: return json.loads(out)['nftables']
    except (ValueError,KeyError,TypeError) as e: raise Fail(f'nft JSON 不能解析: {table}') from e

def owned_objects(table, port, prefix, snap=None):
    if snap is None:snap=nft_table(table)
    matches=[]
    objnames={}
    for item in snap:
        for kind in ('rule','counter','quota','set'):
            x=item.get(kind)
            if not isinstance(x,dict): continue
            name=x.get('name')
            if kind=='rule':
                comment=x.get('comment','')
                if isinstance(comment,str) and comment.startswith(prefix+str(port)+'-'):
                    chain=x.get('chain'); handle=x.get('handle')
                    if not isinstance(handle,int) or not isinstance(chain,str): raise Fail('nft rule handle 数据异常')
                    matches.append((chain,handle))
            elif isinstance(name,str) and name in (
                 f's5m_ci_{port}',f's5m_co_{port}',f's5m_q_{port}',f's5m_i4_{port}'):
                objnames[name]=kind
    return matches,objnames

def delete_block(table, port, prefix):
    rules,objs=owned_objects(table,port,prefix)
    lines=[f'delete rule inet {table} {chain} handle {handle}' for chain,handle in sorted(rules,key=lambda x:x[1],reverse=True)]
    for name,kind in objs.items(): lines.append(f'delete {kind} inet {table} {name}')
    return lines

def execute_batch(lines):
    if lines: cmd(['nft','-f','-'],input='\n'.join(lines)+'\n')

def quota_names(port): return f's5m_ci_{port}',f's5m_co_{port}',f's5m_q_{port}'
def ip_name(port): return f's5m_i4_{port}'

def apply_ip(n):
    port=n['port']; limit=n['ip_limit']; sticky=n['sticky']
    lines=delete_block(TABLE_IP,port,'s5m-ip-')
    # Local authenticated health checks must not occupy a customer's IP slot.
    # Restrict exception to IPv4 loopback; IPv6 is still rejected.
    if limit:
        lines.append(f'add rule inet {TABLE_IP} {IP_CHAIN} meta nfproto ipv4 iifname "lo" tcp dport {port} accept comment "s5m-ip-{port}-local"')
    lines.append(f'add rule inet {TABLE_IP} {IP_CHAIN} meta nfproto ipv6 tcp dport {port} drop comment "s5m-ip-{port}-family"')
    if limit:
        setname=ip_name(port)
        lines.extend([
            f'add set inet {TABLE_IP} {setname} {{ type ipv4_addr; size {limit}; flags timeout,dynamic; timeout {sticky}s; }}',
            f'add rule inet {TABLE_IP} {IP_CHAIN} meta nfproto ipv4 tcp dport {port} ip saddr @{setname} update @{setname} {{ ip saddr timeout {sticky}s }} accept comment "s5m-ip-{port}-refresh"',
            f'add rule inet {TABLE_IP} {IP_CHAIN} meta nfproto ipv4 tcp dport {port} add @{setname} {{ ip saddr timeout {sticky}s }} accept comment "s5m-ip-{port}-claim"',
            f'add rule inet {TABLE_IP} {IP_CHAIN} meta nfproto ipv4 tcp dport {port} drop comment "s5m-ip-{port}-drop"'])
    execute_batch(lines)

def quota_remaining(n):
    q=n['quota']; return None if q is None else max(0,q['original']-q['saved'])

def apply_quota(n):
    p=n['port']; q=n['quota']; ci,co,qn=quota_names(p)
    lines=delete_block(TABLE_Q,p,'s5m-q-')
    if q is not None:
        remain=quota_remaining(n)
        if remain>0:
            lines.extend([
                f'add counter inet {TABLE_Q} {ci}', f'add counter inet {TABLE_Q} {co}',
                f'add quota inet {TABLE_Q} {qn} {{ over {remain} bytes used 0 bytes }}',
                f'add rule inet {TABLE_Q} {Q_IN} tcp dport {p} quota name "{qn}" drop comment "s5m-q-{p}-dropin"',
                f'add rule inet {TABLE_Q} {Q_IN} tcp dport {p} counter name "{ci}" comment "s5m-q-{p}-countin"',
                f'add rule inet {TABLE_Q} {Q_OUT} tcp sport {p} quota name "{qn}" drop comment "s5m-q-{p}-dropout"',
                f'add rule inet {TABLE_Q} {Q_OUT} tcp sport {p} counter name "{co}" comment "s5m-q-{p}-countout"'])
        else:
            lines.extend([
                f'add rule inet {TABLE_Q} {Q_IN} tcp dport {p} drop comment "s5m-q-{p}-dropin"',
                f'add rule inet {TABLE_Q} {Q_OUT} tcp sport {p} drop comment "s5m-q-{p}-dropout"'])
    execute_batch(lines)

def ensure_block(n):
    """Emergency fail-closed block in BOTH directions, then stop proxy."""
    p=n['port']
    try:
        lines=delete_block(TABLE_IP,p,'s5m-ip-')
        lines+=delete_block(TABLE_Q,p,'s5m-q-')
        lines.extend([
            f'add rule inet {TABLE_IP} {IP_CHAIN} tcp dport {p} drop comment "s5m-ip-{p}-failsafe"',
            f'add rule inet {TABLE_Q} {Q_OUT} tcp sport {p} drop comment "s5m-q-{p}-failsafe"'])
        execute_batch(lines)
    finally:
        # If nft is unavailable we still stop the process. If process stop
        # fails, stale/owner metadata remain and no cleanup frees the port.
        cmd(['systemctl','stop',service(n)],required=False,timeout=20)


def snapshot_pair():
    return {TABLE_IP:nft_table(TABLE_IP),TABLE_Q:nft_table(TABLE_Q)}

def named_object(snapshot,kind,name):
    for item in snapshot:
        value=item.get(kind)
        if isinstance(value,dict) and value.get('name')==name:return value
    return None

def _nft_match(expr, left, right, *, ops=('==',)):
    """Match one whole nft JSON comparison; never trust rule comments alone."""
    if not isinstance(expr,dict) or set(expr)!={'match'}:return False
    item=expr['match']
    return (isinstance(item,dict) and item.get('op') in ops
            and item.get('left')==left and item.get('right')==right)


def _nft_ref(value, name):
    if isinstance(value,str):return value.lstrip('@')==name
    if isinstance(value,dict) and set(value)=={'set'}:
        return _nft_ref(value['set'],name)
    return False


def _nft_tcp_port(expr, field, port):
    return _nft_match(expr,{'payload':{'protocol':'tcp','field':field}},port)


def _nft_family(expr, family):
    return _nft_match(expr,{'meta':{'key':'nfproto'}},family)


def _nft_action(expr, action):
    return isinstance(expr,dict) and expr=={action:None}


def _nft_named(expr, kind, name):
    return isinstance(expr,dict) and set(expr)=={kind} and _nft_ref(expr[kind],name)


def _nft_dynset(expr, mode, name, sticky):
    if not isinstance(expr,dict) or set(expr)!={'set'}:return False
    obj=expr['set']
    if not isinstance(obj,dict) or obj.get('op')!=mode or not _nft_ref(obj.get('set'),name):return False
    if set(obj)-{'op','set','elem'}:return False
    elem=obj.get('elem')
    if not isinstance(elem,dict):return False
    # libnftables on Debian 12 can serialize a dynamic-set element as
    # {"elem":{"elem":{"val":ip_saddr,"timeout":N}}} rather than a flat elem.
    # Unwrap exactly one recognized layer; still verify source, set and timeout.
    if set(elem)=={'elem'} and isinstance(elem['elem'],dict):
        elem=elem['elem']
    source={'payload':{'protocol':'ip','field':'saddr'}}
    if elem==source:return True
    # nft JSON encodes per-element timeout as seconds or milliseconds depending
    # on libnftables version; do not accept a different source expression.
    if set(elem)-{'val','timeout','expires','comment'}:return False
    if elem.get('val')!=source:return False
    timeout=elem.get('timeout')
    if timeout is not None and timeout not in (sticky,sticky*1000,str(sticky)+'s',str(sticky*1000)):
        return False
    return True


def _nft_set_member(expr, name):
    if not isinstance(expr,dict) or set(expr)!={'match'}:return False
    m=expr['match']
    return (isinstance(m,dict) and m.get('op') in ('==','in')
            and m.get('left')=={'payload':{'protocol':'ip','field':'saddr'}}
            and _nft_ref(m.get('right'),name))


def _nft_rule_valid(rule, n, kind):
    port=n['port']; s=ip_name(port); ci,co,qn=quota_names(port)
    expr=rule.get('expr')
    if not isinstance(expr,list):return False
    if rule.get('family','inet')!='inet':return False
    if kind in ('local','family','refresh','claim','drop'):
        if rule.get('table',TABLE_IP)!=TABLE_IP or rule.get('chain')!=IP_CHAIN:return False
        if kind=='family':
            return (len(expr)==3 and _nft_family(expr[0],'ipv6') and
                    _nft_tcp_port(expr[1],'dport',port) and _nft_action(expr[2],'drop'))
        if kind=='local':
            return (len(expr)==4 and _nft_family(expr[0],'ipv4')
                    and _nft_match(expr[1],{'meta':{'key':'iifname'}},'lo')
                    and _nft_tcp_port(expr[2],'dport',port) and _nft_action(expr[3],'accept'))
        if kind in ('refresh','claim'):
            # `ip saddr` and the ipv4_addr dynamic set imply IPv4. Some nft
            # versions omit the redundant `meta nfproto ipv4` in JSON dumps.
            # Accept only these two exact canonicalizations, never a wildcard
            # rule or a changed action, set, source address, port, or timeout.
            tail=expr[1:] if expr and _nft_family(expr[0],'ipv4') else expr
            if kind=='claim':
                return (len(tail)==3 and _nft_tcp_port(tail[0],'dport',port)
                        and _nft_dynset(tail[1],'add',s,n['sticky'])
                        and _nft_action(tail[2],'accept'))
            return (len(tail)==4 and _nft_tcp_port(tail[0],'dport',port)
                    and _nft_set_member(tail[1],s)
                    and _nft_dynset(tail[2],'update',s,n['sticky'])
                    and _nft_action(tail[3],'accept'))
        # Unlike a dynamic IPv4 set reference, the standalone drop must
        # retain its explicit IPv4 family guard or it could block IPv6.
        return (kind=='drop' and len(expr)==3
                and _nft_family(expr[0],'ipv4')
                and _nft_tcp_port(expr[1],'dport',port)
                and _nft_action(expr[2],'drop'))
    chain=Q_IN if kind.endswith('in') else Q_OUT
    field='dport' if chain==Q_IN else 'sport'
    if rule.get('table',TABLE_Q)!=TABLE_Q or rule.get('chain')!=chain:return False
    if not expr or not _nft_tcp_port(expr[0],field,port):return False
    if kind in ('dropin','dropout'):
        if n['quota'] is None:return False
        if quota_remaining(n)==0:
            return len(expr)==2 and _nft_action(expr[1],'drop')
        return (len(expr)==3 and _nft_named(expr[1],'quota',qn)
                and _nft_action(expr[2],'drop'))
    if kind in ('countin','countout'):
        if n['quota'] is None or quota_remaining(n)==0:return False
        return len(expr)==2 and _nft_named(expr[1],'counter',ci if kind=='countin' else co)
    return False


def _nft_base_ok(snap, table):
    chain_specs=({IP_CHAIN:('input',-10)} if table==TABLE_IP
                 else {Q_IN:('input',0),Q_OUT:('output',0)})
    tables=[v['table'] for v in snap if 'table' in v]
    if len(tables)!=1 or tables[0].get('family')!='inet' or tables[0].get('name')!=table:
        return False
    chains=[v['chain'] for v in snap if 'chain' in v]
    if len(chains)!=len(chain_specs):return False
    for name,(hook,priority) in chain_specs.items():
        candidates=[c for c in chains if c.get('name')==name]
        if len(candidates)!=1:return False
        c=candidates[0]
        if (c.get('family','inet')!='inet' or c.get('table',table)!=table
            or c.get('type')!='filter' or c.get('hook')!=hook
            or c.get('prio')!=priority or c.get('policy')!='accept'):
            return False
    return True


def _nft_rules_ok(snap, table, n, expected):
    """Validate exact expressions and order; reject foreign/wildcard shortcuts."""
    prefix='s5m-ip-' if table==TABLE_IP else 's5m-q-'
    port=n['port']
    selected=[]
    for index,entry in enumerate(snap):
        if 'rule' not in entry:continue
        r=entry['rule']
        if r.get('family','inet')!='inet' or r.get('table',table)!=table:return False
        comment=r.get('comment')
        # These tables are manager-owned: an unrecognized rule could bypass
        # an earlier/later restriction. Never accept external rules in them.
        if not isinstance(comment,str) or not re.fullmatch(prefix+r'[0-9]{1,5}-[a-z]+',comment):
            return False
        if r.get('chain') not in ({IP_CHAIN} if table==TABLE_IP else {Q_IN,Q_OUT}):return False
        ruleport=int(comment[len(prefix):].split('-',1)[0])
        if not 1<=ruleport<=65535:return False
        if ruleport==port:
            if type(r.get('handle')) is not int:return False
            kind=comment.rsplit('-',1)[1]
            if kind not in expected or not _nft_rule_valid(r,n,kind):return False
            selected.append((index,kind))
        else:
            # A rule claiming another port must actually match that port,
            # never a wildcard or our port (which could grant early accept).
            expr=r.get('expr')
            if not isinstance(expr,list):return False
            if table==TABLE_IP:
                if not any(_nft_tcp_port(x,'dport',ruleport) for x in expr):return False
            elif not any(_nft_tcp_port(x,'dport' if r['chain']==Q_IN else 'sport',ruleport) for x in expr):
                return False
    return [kind for _,kind in selected]==list(expected)


def _nft_ip_ok(n, snap):
    if not _nft_base_ok(snap,TABLE_IP):return False
    expected=(('local','family','refresh','claim','drop') if n['ip_limit'] else ('family',))
    if not _nft_rules_ok(snap,TABLE_IP,n,expected):return False
    matching=[v['set'] for v in snap if 'set' in v and v['set'].get('name')==ip_name(n['port'])]
    if not n['ip_limit']:return not matching
    if len(matching)!=1:return False
    s=matching[0]
    if s.get('type')!='ipv4_addr' or s.get('size')!=n['ip_limit']:return False
    flags=s.get('flags',[])
    if isinstance(flags,str):flags=[flags]
    # Older libnftables versions omit the dynamic flag in JSON dumps.
    if 'timeout' not in flags or 'constant' in flags:return False
    timeout=s.get('timeout')
    if timeout is not None and timeout not in (n['sticky'],n['sticky']*1000,str(n['sticky'])+'s',str(n['sticky']*1000)):
        return False
    return True


def _nft_quota_ok(n, snap):
    if not _nft_base_ok(snap,TABLE_Q):return False
    remain=quota_remaining(n)
    expected=(('dropin','countin','dropout','countout') if remain is not None and remain>0
              else ('dropin','dropout') if remain==0 else ())
    # Rule evaluation order is per chain, not across the two base chains.
    # _nft_rules_ok uses full nft dump order, generally preserving per-chain order.
    if not _nft_rules_ok(snap,TABLE_Q,n,expected):return False
    ci,co,qn=quota_names(n['port'])
    found={}
    for objkind in ('counter','quota'):
        for v in snap:
            x=v.get(objkind)
            if isinstance(x,dict) and x.get('name') in (ci,co,qn):
                if x['name'] in found:return False
                found[x['name']]=(objkind,x)
    if remain is None or remain==0:return not found
    if set(found)!={ci,co,qn}:return False
    if found[ci][0]!='counter' or found[co][0]!='counter' or found[qn][0]!='quota':return False
    q=found[qn][1]
    if q.get('bytes')!=remain or q.get('inv') is not True:return False
    if type(q.get('used',0)) is not int or q.get('used',0)<0:return False
    return all(type(found[name][1].get('bytes')) is int and found[name][1]['bytes']>=0
               for name in (ci,co))


def ready(n,snaps=None):
    if n.get('pending') or n.get('pending_ip') or n.get('phase') not in ('active','creating'):
        return False
    try:
        if snaps is None:snaps=snapshot_pair()
        return _nft_ip_ok(n,snaps[TABLE_IP]) and _nft_quota_ok(n,snaps[TABLE_Q])
    except (Fail,ValueError,TypeError,KeyError,IndexError,AttributeError):return False


def read_nft_named(kind,name):
    out=cmd(['nft','-j','list',kind,'inet',TABLE_Q,name],required=False)
    if out is None:return None
    try:
        data=json.loads(out)['nftables']
        for row in data:
            x=row.get(kind)
            if isinstance(x,dict) and x.get('name')==name:
                if kind=='counter' and type(x.get('bytes')) is int:return x['bytes']
                if kind=='quota':
                    v=x.get('used',0)
                    if type(v) is int and v>=0:return v
    except (ValueError,KeyError,TypeError):pass
    return None

def live_bytes(n,snaps=None):
    if n['quota'] is None:return 0
    if n['pending']:raise Fail('配额存在未完成事务，拒绝从 nft 重新计量')
    p=n['port']; ci,co,qn=quota_names(p)
    if snaps is None:
        used=read_nft_named('quota',qn)
        a=read_nft_named('counter',ci); b=read_nft_named('counter',co)
    else:
        snap=snaps[TABLE_Q]
        qo=named_object(snap,'quota',qn)
        one=named_object(snap,'counter',ci);two=named_object(snap,'counter',co)
        used=qo.get('used',0) if qo is not None else None
        a=one.get('bytes') if one is not None else None
        b=two.get('bytes') if two is not None else None
        if any(type(v) is not int or v<0 for v in (used,a,b) if v is not None):
            raise Fail('nft 配额计数器包含非法字节值')
    if used is not None and a is not None and b is not None:return max(used,a+b)
    if used is not None:return used
    if a is not None and b is not None:return a+b
    if quota_remaining(n)==0 and ready(n,snaps):return 0
    raise Fail(f'端口 {p} 无法读取配额/计数器，不能按零流量重建')

def save_quota(n):
    if n['quota'] is None:return
    if n['pending']:
        try:apply_quota(n)
        except Fail:ensure_block(n);raise
        n['pending']=False; atomic_json(nodefile(n['id']),n);return
    d=live_bytes(n); q=n['quota']; q['saved']=min(q['original'],q['saved']+d)
    n['pending']=True; atomic_json(nodefile(n['id']),n)
    try: apply_quota(n)
    except Fail:
        ensure_block(n); raise
    n['pending']=False; atomic_json(nodefile(n['id']),n)

def quota_reset(n,now=None):
    now=int(time.time()) if now is None else now
    q=n['quota']
    if not q or not q.get('reset_at') or n['expires']<=now or q['reset_at']>now:return False
    # Keep reset aligned to the original 30-day epoch, not to timer runtime.
    while q['reset_at']<=now:q['reset_at']+=D30
    q['saved']=0; n['pending']=True; atomic_json(nodefile(n['id']),n)
    try: apply_quota(n)
    except Fail:ensure_block(n);raise
    n['pending']=False;atomic_json(nodefile(n['id']),n);return True

def proxy_config(n,s):
    u=n['username'];pwd=n['password'];p=n['port'];wan=s['wan_if']
    # chars are deliberately restricted: passwords contain no $, whitespace, \n or ':'
    lines=['# Generated by socks5-manager. Do not edit manually.',
           'nscache 65536', 'maxconn '+str(n['maxconn']),
           f'users {u}:CL:{pwd}', 'auth strong',
           f'connlim {n["connections"]} 0 {u}',
           'connlim 120 60 '+u]
    # Restrict both requested private addresses and hostnames that resolve to private IPs.
    lines.append(f'deny {u} * {",".join(BLOCKED)} * CONNECT')
    # SMTP abuse mitigation.
    lines.append(f'deny {u} * * 25,465,587 CONNECT')
    lines.extend([f'deny {u} * * * UDPASSOC,BIND', f'allow {u} * * * CONNECT', 'deny *',
                  f'socks -4 -p{p} -i0.0.0.0 -De{wan}', ''])
    return '\n'.join(lines)

def make_user(n,s):
    atomic_write(proxycfg(n['id']),proxy_config(n,s).encode())

def service(n):return f'socks5-@{n["id"]}.service'

def systemctl(*args,required=True,timeout=35):
    return cmd(['systemctl',*args],required=required,timeout=timeout)

def verify_proxycfg(n):
    # In addition to text validation, service startup and SOCKS authentication
    # checks will verify 3proxy config at runtime.
    path=proxycfg(n['id'])
    if not path.is_file() or path.is_symlink():raise Fail('代理配置文件不存在或类型不安全')
    text=path.read_text(encoding='utf8')
    if text!=proxy_config(n,settings()):raise Fail('代理配置与节点状态不一致')
    if not Path(BIN).is_file():raise Fail(f'3proxy 可执行文件不存在: {BIN}')

def nstate(n,expose=False,snaps=None):
    x={k:v for k,v in n.items() if k not in ('password','up_mbit','down_mbit')}
    q=x.get('quota')
    if q:
        x['quota']={**q,'live_used':None,'realtime_available':False,'remaining_estimate':max(0,q['original']-q['saved'])}
        try:
            if not n['pending']:
                used=live_bytes(n,snaps);x['quota']['live_used']=used
                x['quota']['realtime_available']=True
                x['quota']['remaining_estimate']=max(0,q['original']-q['saved']-used)
        except Fail:pass
    x['protection_ready']=ready(n,snaps)
    x['unit_active']=systemctl('is-active','--quiet',service(n),required=False) is not None
    if expose:x['password']=n['password']
    return x

def human_bytes(value):
    """IEC units for user display; quota enforcement always stays in bytes."""
    if value is None:return '未知'
    value=max(0,int(value))
    if value<1024:return f'{value} B'
    units=('KiB','MiB','GiB','TiB','PiB','EiB')
    scale=1024
    for unit in units:
        if value < scale*1024 or unit==units[-1]:
            return f'{Decimal(value)/Decimal(scale):.2f} {unit}'
        scale*=1024


def time_left(expires,now=None):
    seconds=max(0,int(expires)-(int(time.time()) if now is None else now))
    if seconds==0:return '已到期'
    days,remainder=divmod(seconds,86400)
    hours,remainder=divmod(remainder,3600)
    minutes,_=divmod(remainder,60)
    if days:return f'{days}天{hours}时'
    if hours:return f'{hours}时{minutes}分'
    if minutes:return f'{minutes}分'
    return f'{seconds}秒'


def pct_text(used,total):
    if used is None or not total:return '-'
    ratio=Decimal(used)*100/Decimal(total)
    if 0<ratio<Decimal('0.01'):return f'{ratio:.4f}%'
    return f'{ratio:.2f}%'


def _display_width(value):
    return sum(0 if unicodedata.combining(c) else (2 if unicodedata.east_asian_width(c) in 'WF' else 1)
               for c in str(value))


def render_table(headers,rows,right=()):
    """Box-drawn fixed cells like vless_audit, without importing any VLESS files."""
    rows=[[str(v) for v in row] for row in rows]
    widths=[max(_display_width(header),*( _display_width(row[i]) for row in rows))
            for i,header in enumerate(headers)]
    def pad(value,index):
        space=' '*max(0,widths[index]-_display_width(value))
        return (space+value) if index in right else (value+space)
    def border(left,mid,right_end):
        return left+mid.join('━'*w for w in widths)+right_end
    print(border('┏','┳','┓'))
    print('┃'+'│'.join(v+' '*max(0,widths[i]-_display_width(v)) for i,v in enumerate(headers))+'┃')
    print(border('┣','╋','┫'))
    for j,row in enumerate(rows):
        print('┃'+'│'.join(pad(v,i) for i,v in enumerate(row))+'┃')
        if j!=len(rows)-1:print(border('┣','╋','┫'))
    print(border('┗','┻','┛'))


def quota_values(n,state):
    """Return exact quota accounting only if its live nft counters were read."""
    q=state['quota']
    if q is None:return (None,None,None,None)
    total=q['original']
    if not q.get('realtime_available'):return (total,None,None,None)
    used=min(total,q['saved']+q['live_used'])
    return (total,used,max(0,total-used),pct_text(used,total))


def show_quota(n,snaps=None):
    state=nstate(n,snaps=snaps)
    total,used,left,pct=quota_values(n,state)
    print(f'本机端口：{n["port"]}  账号 ID：{n["id"]}')
    if total is None:
        print('总流量配额：不限流量（未设置配额）')
        return
    def val(v):return f'{human_bytes(v)} ({v:,} B)' if v is not None else '未知'
    print(f'总配额：  {val(total)}')
    print(f'已用流量：{val(used)}')
    print(f'剩余流量：{val(left)}')
    print(f'使用比例：{pct or "未知"}')
    print(f'其中已持久化用量：{val(state["quota"]["saved"])}')
    if used is None:
        print('警告：未能读取实时 nftables 配额计数，剩余额度不可确认；请运行 socks5 status 排查防护。')
    else:
        print('计量方式：已保存配额用量 + 当前 nftables 实时计数（总配额，上传下载合计）')


def list_accounts(selected=None,*,audit=False):
    all_nodes=nodes()
    if selected is not None:
        chosen=resolve_node(selected)
        all_nodes=[chosen]
    if not all_nodes:
        print('当前没有 SOCKS5 账号')
        return
    try:snaps=snapshot_pair()
    except Fail:snaps=None
    wide=shutil.get_terminal_size(fallback=(120,24)).columns>=105
    if wide:
        headers=['PORT','STATE','LIMIT','USED','LEFT','USE%','TTL','EXPIRE(BJ)','IP/STICKY','GUARD']
        right={0,2,3,4,5,6,8}
    else:
        headers=['PORT','STATE','LIMIT','USED','LEFT','TTL','IP/STICKY','GUARD']
        right={0,2,3,4,5,6}
    data=[];issues=[]
    now=int(time.time())
    for n in sorted(all_nodes,key=lambda item:item['port']):
        state=nstate(n,snaps=snaps)
        total,used,left,pct=quota_values(n,state)
        ok=state['protection_ready'] and state['unit_active'] and n['expires']>now
        if not ok or (state['quota'] is not None and not state['quota'].get('realtime_available')):issues.append(n['port'])
        status='正常' if ok else ('已到期' if n['expires']<=now else '异常')
        guard='正常' if state['protection_ready'] else '异常'
        t='不限' if total is None else human_bytes(total)
        u='-' if total is None else human_bytes(used)
        l='不限' if total is None else human_bytes(left)
        ip=f'{n["ip_limit"]}/{n["sticky"]}s' if n['ip_limit'] else '不限'
        ttl=time_left(n['expires'],now)
        if wide:
            expire=dt.datetime.fromtimestamp(n['expires'],dt.timezone(dt.timedelta(hours=8))).strftime('%Y-%m-%d %H:%M')
            data.append([n['port'],status,t,u,l,pct or '-',ttl,expire,ip,guard])
        else:
            data.append([n['port'],status,t,u,l,ttl,ip,guard])
    render_table(headers,data,right)
    print('说明：LIMIT=总配额  USED=已用  LEFT=剩余  TTL=剩余有效期  IP/STICKY=来源IP上限/占位秒数')
    print('精确剩余字节数：socks5 quota 端口；完整连接链接：socks5 link 端口')
    if audit and issues:
        raise Fail('端口 '+', '.join(map(str,issues))+' 的运行状态、防护或有效期需要检查')


def make_units():
    exe='/usr/local/sbin/socks5'
    template=f'''[Unit]
Description=Managed residential SOCKS5 instance %i
After=network-online.target socks5-restore.service
Wants=network-online.target
ConditionPathExists={CONF}/nodes/%i.cfg
ConditionPathExists={STATE}/nodes/%i.json

[Service]
Type=simple
User=root
Group=root
ExecStart={exe} run %i
ExecStopPost=-{exe} stop-post %i
Restart=on-failure
RestartSec=5s
SuccessExitStatus=0 124 143
TimeoutStopSec=30
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectClock=true
ProtectHostname=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
SystemCallArchitectures=native
UMask=0077

[Install]
WantedBy=multi-user.target
'''
    oneshot=lambda name,task: f'''[Unit]
Description=SOCKS5 {name}
After=local-fs.target nftables.service

[Service]
Type=oneshot
ExecStart={exe} {task}
TimeoutStartSec=120
UMask=0077
'''
    timer=lambda name,interval,boot: f'''[Unit]
Description=SOCKS5 {name} timer

[Timer]
OnBootSec={boot}
OnUnitActiveSec={interval}
Persistent=true

[Install]
WantedBy=timers.target
'''
    outputs={
        'socks5-@.service':template,
        'socks5-restore.service':f'''[Unit]
Description=Restore SOCKS5 managed nftables protections
After=local-fs.target nftables.service
Before=multi-user.target

[Service]
Type=oneshot
ExecStart={exe} restore
TimeoutStartSec=120
RemainAfterExit=yes
UMask=0077

[Install]
WantedBy=multi-user.target
''',
        'socks5-ddns.service':oneshot('optional DDNS A record synchronization','ddns-check'),
        'socks5-ddns.timer':timer('optional DDNS A record synchronization','1min','30s'),
        'socks5-save.service':oneshot('quota snapshot','save'),
        'socks5-save.timer':timer('quota snapshot','5min','5min'),
        'socks5-gc.service':oneshot('expiration cleanup','gc'),
        'socks5-gc.timer':timer('expiration cleanup','1min','2min'),
        'socks5-reset.service':oneshot('quota reset','reset'),
        'socks5-reset.timer':timer('quota reset','1h','15min'),
        'socks5-watch.service':oneshot('watchdog','watch'),
        'socks5-watch.timer':timer('watchdog','1min','90s'),
        'socks5-shutdown.service':f'''[Unit]
Description=Save SOCKS5 quotas before shutdown
Before=shutdown.target reboot.target halt.target poweroff.target
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop={exe} save
TimeoutStopSec=120
UMask=0077

[Install]
WantedBy=multi-user.target
'''
    }
    return outputs

def preflight():
    if os.geteuid()!=0:raise Fail('需要 root')
    if not Path('/run/systemd/system').exists():raise Fail('systemd 必须是 PID 1')
    for binary in ('nft','ip','ss','timeout','systemctl','flock'):
        if not shutil.which(binary):raise Fail(f'缺少命令 {binary}')
    if not Path(BIN).is_file():raise Fail('缺少 3proxy，请先安装官方签名包')
    probe=f'''add table inet s5m_probe
add chain inet s5m_probe in {{ type filter hook input priority 0; policy accept; }}
add chain inet s5m_probe out {{ type filter hook output priority 0; policy accept; }}
add quota inet s5m_probe q {{ over 1048576 bytes used 0 bytes }}
add counter inet s5m_probe cin
add counter inet s5m_probe cout
add set inet s5m_probe v4 {{ type ipv4_addr; size 2; flags timeout,dynamic; timeout 120s; }}
add rule inet s5m_probe in tcp dport 65001 ip saddr @v4 update @v4 {{ ip saddr timeout 120s }} accept
add rule inet s5m_probe in tcp dport 65001 ip saddr @v4 add @v4 {{ ip saddr timeout 120s }} accept
add rule inet s5m_probe in tcp dport 65001 quota name "q" drop
add rule inet s5m_probe out tcp sport 65001 counter name "cout"
'''
    cmd(['nft','-c','-f','-'],input=probe)


def do_install(args):
    preflight()
    with locked():
        prepare_dirs()
        saved=load(CONF/'settings.json',default={})
        wan=args.wan_if or saved.get('wan_if')
        if not wan:
            r=cmd(['ip','-4','route','get','1.1.1.1'])
            m=re.search(r'\bdev\s+(\S+)',r)
            if not m:raise Fail('无法识别出口网卡，请指定 --wan-if')
            wan=m.group(1)
        validate_iface(wan);local_route(wan)
        host=args.host or saved.get('host') or 'AUTO'
        if host!='AUTO':public_host(host)
        s={**saved,'wan_if':wan,'host':host,'port_start':PORT_MIN,'port_end':PORT_MAX}
        settings_path=CONF/'settings.json'
        old_settings=settings_path.read_bytes() if settings_path.exists() else None
        targets={UNITDIR/name:body.encode() for name,body in make_units().items()}
        prior={path:(path.read_bytes() if path.exists() else None) for path in targets}
        units=('socks5-save.timer','socks5-gc.timer','socks5-reset.timer',
               'socks5-watch.timer','socks5-shutdown.service','socks5-restore.service')
        previous={u:((systemctl('is-enabled',u,required=False) or '').strip(),
                     systemctl('is-active','--quiet',u,required=False) is not None) for u in units}
        # Complete preflight of ALL legacy accounts before changing anything.
        existing=nodes()
        if existing and saved.get('wan_if') and saved['wan_if']!=wan:
            raise Fail('已有 SOCKS5 节点时禁止直接更换 WAN_IF；旧 3proxy 配置仍绑定原接口')
        for n in existing:
            existing_cfg=proxycfg(n['id'])
            if existing_cfg.is_file() and any(k in existing_cfg.read_text() for k in ('bandlimin ', 'bandlimout ')):
                raise Fail(f'检测到非本正式版的旧 SOCKS5 内置限速配置：{n["id"]}；拒绝直接升级，以避免意外放宽限速')
        try:
            atomic_json(settings_path,s)
            for path,body in targets.items(): atomic_write(path,body,0o644)
            systemctl('daemon-reload')
            for name in units:
                systemctl('enable',name)
            ensure_tables()
            # On upgrades never reset a healthy IP timeout set. Repair only
            # stale guards, and stop its service BEFORE touching stale rules.
            for n in existing:
                if n['phase']=='creating':
                    systemctl('stop',service(n),required=False)
                    continue
                repair_node(n,manual_restore=True)
            # The restore unit calls `socks5 restore`, which acquires the
            # same manager lock held by do_install(). Do NOT start it while
            # holding that lock: blocking restore would deadlock the install.
            # Unit is enabled here; start it synchronously after lock release.
            for name in ('socks5-save.timer','socks5-gc.timer','socks5-reset.timer','socks5-watch.timer','socks5-shutdown.service'):
                systemctl('start',name)
            if (CONF/'ddns.json').exists():systemctl('start','socks5-ddns.timer')
            for n in existing:
                if n['phase']=='active' and n['expires']>int(time.time()) and ready(n) and systemctl('is-active','--quiet',service(n),required=False) is None:
                    systemctl('start',service(n),required=False)
        except Exception:
            if old_settings is None:settings_path.unlink(missing_ok=True)
            else:atomic_write(settings_path,old_settings)
            for path,old in prior.items():
                if old is None:path.unlink(missing_ok=True)
                else:atomic_write(path,old,0o644)
            systemctl('daemon-reload',required=False)
            for unit,(state,was_active) in previous.items():
                if state in ('enabled','enabled-runtime','linked','linked-runtime'):
                    systemctl('enable',unit,required=False)
                elif state in ('disabled','static','indirect','masked','masked-runtime',''):
                    systemctl('disable',unit,required=False)
                if was_active:
                    systemctl('start',unit,required=False)
                else:
                    systemctl('stop',unit,required=False)
            raise
    # Release manager.lock before starting the restore oneshot. Its ExecStart
    # obtains the manager lock too, so this is a required lock-order boundary.
    systemctl('start','socks5-restore.service')
    print(f'安装成功。WAN_IF={wan}，公网地址={host}；不会更改 WG 配置或规则。')

def free_port(start,end,excluded=None,existing=None):
    occupied={n['port'] for n in (nodes() if existing is None else existing)} | set(excluded or ())
    output=cmd(['ss','-ltnH'],required=False) or ''
    for item in output.splitlines():
        mat=re.search(r':(\d+)\s',item+' ')
        if mat:occupied.add(int(mat.group(1)))
    for p in range(start,end+1):
        if p not in occupied:return p
    raise Fail('没有空闲端口')

def make_node(args,excluded=None):
    s=settings();validate_iface(s['wan_if']);local_route(s['wan_if'])
    existing=nodes()
    tag=must_id(args.id or ('s5-'+time.strftime('%Y%m%d%H%M%S')+'-'+secrets.token_hex(2)))
    if nodefile(tag).exists():raise Fail('ID 已存在')
    sec=num(args.seconds,'D',1,2147483647)
    start=num(args.port_start,'PORT_START',1024,65535)
    end=num(args.port_end,'PORT_END',start,65535)
    port=num(args.port,'PORT',1024,65535) if args.port is not None else free_port(start,end,excluded,existing)
    for n in existing:
        if n['port']==port:raise Fail('端口已被 SOCKS5 账号占用')
    # Verify physical port availability (includes listeners outside module).
    test=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
    try:
        test.bind(('0.0.0.0',port))
    except OSError as e:raise Fail(f'端口 {port} 无法绑定：{e}')
    finally:test.close()
    epoch=int(time.time());limit=gib_bytes(args.quota_gib)
    if args.public_port is not None:
        pub=num(args.public_port,'PUBLIC_PORT',1,65535)
    else:pub=port
    passwd=secrets.token_urlsafe(24).replace('-','A').replace('_','B')
    q=({'original':limit,'saved':0,'reset_at':epoch+D30 if sec>D30 else 0} if limit else None)
    n={'id':tag,'instance':secrets.token_hex(16),'port':port,'public_port':pub,
       'public_host':args.host or s['host'],'username':'u'+secrets.token_hex(8),
       'password':passwd,'created':epoch,'expires':epoch+sec,'seconds':sec,
       'ip_limit':num(args.ip_limit,'IP_LIMIT',0,65535),
       'sticky':num(args.sticky,'IP_STICKY_SECONDS',1,2147483647),
       'connections':num(args.connections,'连接数',1,2048),'maxconn':num(args.maxconn,'maxconn',1,4096),
       'quota':q,'pending':False,'pending_ip':False,'phase':'creating'}
    if n['public_host']=='AUTO':
        r=cmd(['ip','-4','addr','show','dev',s['wan_if']])
        found=re.search(r'inet\s+(\d+\.\d+\.\d+\.\d+)/',r)
        if not found:raise Fail('未找到 WAN_IF IPv4；请配置公网地址/域名')
        n['public_host']=found.group(1)
    public_host(n['public_host'])
    if any(x['public_host']==n['public_host'] and x['public_port']==n['public_port'] for x in existing):
        raise Fail('公网地址 + 公网端口 已被另一个 SOCKS5 账号占用')
    if args.host is None and s['host']=='AUTO':
        try:
            if not ipaddress.ip_address(n['public_host']).is_global:
                raise Fail('网卡 IPv4 为私网/NAT 地址，请明确提供 --host 公网入口和 --public-port')
        except ValueError:pass
    return n

def rollback_new(n):
    # The process must die before removing any nftables protection.
    systemctl('stop',service(n),required=False)
    systemctl('disable',service(n),required=False)
    if systemctl('is-active','--quiet',service(n),required=False) is not None:
        raise Fail('创建失败且进程仍运行，保留防护和状态，拒绝清理')
    sockets=cmd(['ss','-ltnH'],required=False) or ''
    if any(re.search(r':'+str(n['port'])+r'\s',line+' ') for line in sockets.splitlines()):
        raise Fail('创建失败但端口仍在监听，保留防护与元数据')
    try:
        execute_batch(delete_block(TABLE_Q,n['port'],'s5m-q-'))
        execute_batch(delete_block(TABLE_IP,n['port'],'s5m-ip-'))
    except Fail:raise Fail('创建失败且 nft 清理失败，保留状态以便 repair')
    proxycfg(n['id']).unlink(missing_ok=True)
    nodefile(n['id']).unlink(missing_ok=True)

def do_add(args):
    with locked():
        prepare_dirs();ensure_tables()
        failed=set();retries=num(args.max_start_retries,'MAX_START_RETRIES',1,100)
        for attempt in range(retries):
            n=make_node(args,failed)
            atomic_json(nodefile(n['id']),n)
            try:
                make_user(n,settings());verify_proxycfg(n)
                apply_ip(n);apply_quota(n)
                if not ready(n):raise Fail('代理启动前防护状态不完整')
                systemctl('enable',service(n))
                systemctl('start',service(n))
                # Require multiple consecutive samples, like original VLESS.
                ok=0
                for _ in range(12):
                    active=systemctl('is-active','--quiet',service(n),required=False) is not None
                    listening=cmd(['ss','-ltnH'],required=False) or ''
                    open_port=any(re.search(r':'+str(n['port'])+r'\s',line+' ') for line in listening.splitlines())
                    if active and open_port:ok+=1
                    else:ok=0
                    if ok>=3:break
                    time.sleep(1)
                if ok<3:raise Fail('SOCKS5 没有稳定启动/监听')
                socks_handshake(n)
                n['phase']='active';atomic_json(nodefile(n['id']),n)
                print(f'创建成功：ID={n["id"]}  {n["public_host"]}:{n["public_port"]}  本地端口={n["port"]}')
                print(f'用户名={n["username"]}\n密码={n["password"]}')
                print(f'到期(北京时间)={dt.datetime.fromtimestamp(n["expires"],dt.timezone(dt.timedelta(hours=8))).isoformat()}')
                print(f'IP_LIMIT={n["ip_limit"]}  STICKY={n["sticky"]}s')
                print(f'日常直接使用端口 {n["port"]} 管理：socks5 quota {n["port"]}（查余额） / socks5 link {n["port"]}（取链接）')
                print(f'需要限速请在独立 portbw 中执行：portbw set {n["port"]} <上传Mbps> <下载Mbps>')
                print(f'SOCKS5连接链接：{connection_link(n)}')
                return
            except Exception as problem:
                try:rollback_new(n)
                except Exception as failure:
                    raise Fail(f'创建失败且回滚不完整：{failure}') from problem
                failed.add(n['port'])
                if args.port is not None or attempt+1>=retries:
                    raise Fail(f'创建 SOCKS5 失败：{problem}') from problem
                print(f'端口 {n["port"]} 创建失败，已回滚，尝试下一个端口：{problem}',file=sys.stderr)
        raise Fail('创建失败：端口尝试次数耗尽')

def socks_handshake(n):
    """Fail creation if SOCKS5 authentication or critical ACLs are ineffective."""
    phase = '正确密码认证'
    def recv_exact(c,count):
        out=b''
        while len(out)<count:
            data=c.recv(count-len(out))
            if not data:raise Fail(f'SOCKS5 握手提前断开，阶段：{phase}')
            out+=data
        return out
    def login(password):
        c=socket.create_connection(('127.0.0.1',n['port']),timeout=4)
        try:
            c.settimeout(4)
            c.sendall(b'\x05\x01\x02')
            if recv_exact(c,2)!=b'\x05\x02':
                raise Fail('SOCKS5 没有要求用户名密码认证')
            user=n['username'].encode();pwd=password.encode()
            if len(user)>255 or len(pwd)>255:raise Fail('认证字段过长')
            c.sendall(b'\x01'+bytes([len(user)])+user+bytes([len(pwd)])+pwd)
            reply=recv_exact(c,2)
            if password==n['password'] and reply!=b'\x01\x00':
                raise Fail('SOCKS5 正确密码认证失败')
            return c,reply
        except BaseException:
            c.close();raise
    phase = 'UDP ASSOCIATE 拒绝检查'
    with contextlib.closing(login(n['password'])[0]) as c:
        # A wrong credential test guarantees the port isn't an open proxy.
        c.sendall(b'\x05\x03\x00\x01'+b'\x00'*4+b'\x00'*2)
        try:
            reply=recv_exact(c,2)
        except Fail as exc:
            if 'SOCKS5 握手提前断开' not in str(exc):raise
        except ConnectionResetError:
            pass
        else:
            if reply[0]!=5 or reply[1]==0:
                raise Fail('不允许 UDP ASSOCIATE，但实际代理未拒绝')
    phase = '127.0.0.1 访问拒绝检查'
    with contextlib.closing(login(n['password'])[0]) as c:
        c.sendall(b'\x05\x01\x00\x01'+bytes([127,0,0,1])+bytes([0,80]))
        try:
            reply=recv_exact(c,2)
        except Fail as exc:
            if 'SOCKS5 握手提前断开' not in str(exc):raise
        except ConnectionResetError:
            pass
        else:
            if reply[0]!=5 or reply[1]==0:
                raise Fail('目标 127.0.0.1 未被代理访问控制拒绝')
    # 3proxy 先回复 RFC1929 01 00，随后在 CONNECT 阶段校验密码。
    # 必须实际请求公网目标，才能验证错误密码无法使用代理。
    phase = '公网 CONNECT 认证检查'

    def can_connect(password):
        try:
            c, auth_reply = login(password)
        except (ConnectionResetError, BrokenPipeError) as exc:
            if password == n['password']:
                raise Fail(f'正确密码握手连接异常：{type(exc).__name__}: {exc}') from exc
            return False
        except Fail as exc:
            if password != n['password'] and '握手提前断开' in str(exc):
                return False
            raise

        with contextlib.closing(c):
            if auth_reply != bytes([1, 0]):
                if len(auth_reply) != 2 or auth_reply[0] != 1:
                    raise Fail('SOCKS5 认证响应格式异常')
                return False

            request = (
                bytes([5, 1, 0, 1])
                + socket.inet_aton('1.1.1.1')
                + (443).to_bytes(2, 'big')
            )
            try:
                c.sendall(request)
                reply = recv_exact(c, 2)
            except (Fail, OSError) as exc:
                if password == n['password']:
                    raise Fail(f'正确密码 CONNECT 阶段异常：{type(exc).__name__}: {exc}') from exc
                return False

            if reply[0] != 5:
                raise Fail(f'SOCKS5 CONNECT 回复格式异常：{reply.hex()}')
            if password == n['password'] and reply[1] != 0:
                raise Fail(f'正确密码 CONNECT 收到拒绝码：REP=0x{reply[1]:02x}')
            return reply[1] == 0

    if not can_connect(n['password']):
        raise Fail('正确密码无法 CONNECT 1.1.1.1:443，检查出口网络或 3proxy ACL')

    if can_connect(n['password'] + '!invalid'):
        raise Fail('安全错误：错误密码可以 CONNECT 公网，拒绝创建账号')


def do_del(n, *, stop_post=False):
    # Must run with manager lock, EXCEPT stop-post which can no-op if busy.
    if not stop_post:
        systemctl('stop',service(n),required=False,timeout=25)
    if systemctl('is-active','--quiet',service(n),required=False) is not None:
        raise Fail('进程仍在运行，拒绝撤销 nft 防护')
    openports=cmd(['ss','-ltnH'],required=False) or ''
    if any(re.search(r':'+str(n['port'])+r'\s',line+' ') for line in openports.splitlines()):
        raise Fail('监听端口仍在使用，拒绝撤销 nft 防护')
    # Remove quota and IP rules before deleting owner metadata so orphan
    # resources can still be found after partial failure.
    execute_batch(delete_block(TABLE_Q,n['port'],'s5m-q-'))
    execute_batch(delete_block(TABLE_IP,n['port'],'s5m-ip-'))
    systemctl('disable',service(n),required=False)
    proxycfg(n['id']).unlink(missing_ok=True)
    nodefile(n['id']).unlink(missing_ok=True)
    print('已删除',n['id'])

def do_mutate(n,fields, *, rebuild_ip=False, rebuild_q=False, rebuild_cfg=False):
    if n.get('pending') or n.get('pending_ip'):
        raise Fail('存在未完成配额/IP 事务，先运行 socks5 watch 修复，拒绝覆盖待恢复状态')
    old=json.loads(json.dumps(n))
    if rebuild_q and old['quota'] is not None and not old['pending']:
        # The previous generation must be persisted before any rebuild.
        save_quota(old)
        n['quota']=old['quota']
    n.update(fields)
    if rebuild_ip:n['pending_ip']=True
    if rebuild_q:n['pending']=True
    atomic_json(nodefile(n['id']),n)  # durable intent before any nft changes
    try:
        if rebuild_ip: apply_ip(n)
        if rebuild_q: apply_quota(n)
        if rebuild_cfg:
            make_user(n,settings());verify_proxycfg(n)
            systemctl('restart',service(n),required=True)
            socks_handshake(n)
        if rebuild_ip:n['pending_ip']=False
        if rebuild_q:n['pending']=False
        atomic_json(nodefile(n['id']),n)
        if not ready(n):raise Fail('修改后的保护状态不完整')
    except Exception:
        try:
            if rebuild_ip: apply_ip(old)
            if rebuild_q:apply_quota(old)
            if rebuild_cfg:
                make_user(old,settings());systemctl('restart',service(old),required=False)
        except Exception:
            try:ensure_block(old)
            finally:
                # Do not publish a clean state if kernel recovery failed.
                n['pending']=n.get('pending') or rebuild_q
                n['pending_ip']=n.get('pending_ip') or rebuild_ip
                atomic_json(nodefile(n['id']),n)
            raise
        atomic_json(nodefile(n['id']),old)
        raise

def repair_node(n, *, manual_restore=False, snaps=None):
    """Recover interrupted writes without resetting healthy IP slots/counters.

    A missing quota snapshot after a reboot can only be reconstructed from the
    durable saved baseline; stop the proxy before that conservative fallback.
    """
    if ready(n,snaps):
        if manual_restore and n['quota'] is not None:save_quota(n)
        return
    # During boot, an inactive instance may have a queued start job.
    # Do not cancel that job while restoring nft protection.
    # Stop an already-running proxy before changing its guards.
    if systemctl('is-active','--quiet',service(n),required=False) is not None:
        systemctl('stop',service(n),required=False)
    if n.get('pending'):
        try:apply_quota(n)
        except Fail:ensure_block(n);raise
        n['pending']=False;atomic_json(nodefile(n['id']),n)
    elif n['quota'] is not None:
        try:
            save_quota(n)
        except Fail as error:
            print(f'警告: {n["id"]} 未能读取实时配额；仅从最后保存的额度恢复：{error}',file=sys.stderr)
            apply_quota(n)
    else:
        apply_quota(n)
    # Do not needlessly reset valid sticky slots during unrelated quota work.
    if n.get('pending_ip') or not ip_ready(n):apply_ip(n)
    if n.get('pending_ip'):
        n['pending_ip']=False;atomic_json(nodefile(n['id']),n)
    if not ready(n):raise Fail(f'{n["id"]} 防护恢复后校验仍未通过')

def ip_ready(n,snaps=None):
    """Inspect the real IP guard expressions, verdicts, order and set schema."""
    try:
        snap=nft_table(TABLE_IP) if snaps is None else snaps[TABLE_IP]
        return _nft_ip_ok(n,snap)
    except (Fail,TypeError,KeyError,ValueError,IndexError,AttributeError):return False


def operate(args):
    action=args.action
    if action=='install':return do_install(args)
    if action=='add':return do_add(args)
    if action=='run':
        n=node(args.id)
        if n['expires']<=int(time.time()):return
        if not ready(n):raise Fail('防护不完整，拒绝启动 SOCKS5')
        s=settings();validate_iface(s['wan_if']);local_route(s['wan_if'])
        verify_proxycfg(n)  # Never start 3proxy with a modified/unaudited ACL.
        seconds=max(0,n['expires']-int(time.time()))
        if not seconds:return
        # timeout enforces exact epoch while GC performs final cleanup.
        os.execv('/usr/bin/timeout',['timeout','--foreground',str(seconds),BIN,str(proxycfg(args.id))])
    if action=='stop-post':
        with locked(nonblocking=True) as ok:
            if not ok:return
            if not nodefile(args.id).exists():return
            n=node(args.id)
            if n['expires']<=int(time.time()):do_del(n,stop_post=True)
        return
    if action in ('save','gc','reset','watch','restore'):
        # save/restore block as before. Watchdog must not silently skip a
        # whole minute when GC or a short management operation owns the lock.
        # Keep gc/reset nonblocking to avoid overlapping expensive jobs.
        lock_started=time.monotonic()
        with locked(wait=20 if action=='watch' else 90,
                    nonblocking=action in ('gc','reset')) as ok:
            if not ok:
                if action in ('gc','reset'):
                    print(f'{action}: skipped: management lock busy', flush=True)
                return
            if action=='watch':
                print(f'watchdog: lock acquired, waited {time.monotonic()-lock_started:.2f}s', flush=True)
            ensure_tables()
            failures=[]
            try:snaps=snapshot_pair()
            except Fail:snaps=None
            for n in nodes():
                try:
                    if action=='gc':
                        if n['expires']<=int(time.time()):do_del(n)
                    elif action=='save':save_quota(n)
                    elif action=='reset':quota_reset(n)
                    elif action in ('restore','watch'):
                        if n['expires']<=int(time.time()):do_del(n);continue
                        if n['phase']=='creating':
                            # Crash during creation: never turn a credential that
                            # the owner never received into a live proxy account.
                            systemctl('stop',service(n),required=False)
                            if int(time.time())-n['created']>=600:
                                rollback_new(n)
                            continue
                        repair_node(n,manual_restore=(action=='restore'),snaps=snaps)
                        if action=='watch' and ready(n) and systemctl('is-active','--quiet',service(n),required=False) is None:
                            print(f'watchdog: restarting {n["id"]} port={n["port"]}', flush=True)
                            systemctl('reset-failed',service(n),required=False)
                            systemctl('start',service(n))
                            if systemctl('is-active','--quiet',service(n),required=False) is None:
                                raise Fail(f'watchdog: {n["id"]} restart returned but unit not active')
                            print(f'watchdog: recovered {n["id"]} port={n["port"]}', flush=True)
                        if action=='restore':snaps=None  # subsequent nodes may need fresh state
                except Exception as e:
                    failures.append(f'{n["id"]}: {e}')
                    try:ensure_block(n)
                    except Exception:pass
            if failures:raise Fail('；'.join(failures))
        return
    if action=='clear':
        if not args.confirm:raise Fail('删除所有账号必须加 --confirm')
        with locked():
            errors=[]
            for n in nodes():
                try:do_del(n)
                except Exception as e:errors.append(f'{n["id"]}: {e}')
            if errors:raise Fail('部分删除失败：'+'; '.join(errors))
        return
    if action in ('list','audit','show','link','quota','pq-show'):
        with locked():
            if action in ('list','audit'):
                list_accounts(getattr(args,'id',None),audit=action=='audit');return
            n=resolve_node(args.id)
            if action=='show':
                print(json.dumps(nstate(n,expose=args.credentials),indent=2,ensure_ascii=False));return
            if action=='link':
                print(connection_link(n));return
            return show_quota(n)
    if action=='ddns-check':return ddns_check()
    if action=='ddns-set':return ddns_set(args)
    if action=='ddns-status':
        d=load(CONF/'ddns.json',default={})
        d.pop('token_file',None);print(json.dumps(d,ensure_ascii=False,indent=2));return
    if action=='status':
        s=settings();print('WAN_IF:',s['wan_if'],'ROUTE:',local_route(s['wan_if']))
        for n in nodes():print(n['id'],'guard=',ready(n),'unit=',systemctl('is-active',service(n),required=False) or 'inactive')
        return
    with locked():
        ensure_tables()
        n=resolve_node(args.id)
        if action=='del':return do_del(n)
        if action=='ip-set':
            limit=num(args.ip_limit,'IP_LIMIT',1,65535)
            seconds=num(args.sticky if args.sticky is not None else n['sticky'],'STICKY',1,2147483647)
            do_mutate(n,{'ip_limit':limit,'sticky':seconds},rebuild_ip=True)
            print(f'IP 数量设为 {limit}，槽位时间 {seconds}s；原活跃槽位已重置');return
        if action=='ip-del':
            do_mutate(n,{'ip_limit':0},rebuild_ip=True);print('已取消来源 IP 数量限制');return
        if action=='ip-show':
            if not n['ip_limit']:
                print('未启用 IP 限制');return
            print(cmd(['nft','list','set','inet',TABLE_IP,ip_name(n['port'])]));return
        if action=='pq-set':
            if not args.confirm_reset:raise Fail('pq-set 会重置已用量及 30 天重置周期；必须加 --confirm-reset')
            limit=gib_bytes(args.quota_gib)
            if limit is None:raise Fail('请提供 --quota-gib')
            do_mutate(n,{'quota':{'original':limit,'saved':0,'reset_at':0}},rebuild_q=True)
            print('总配额已重新设置（从零开始计量，不启用自动 30 天重置）');return
        if action=='pq-del':
            do_mutate(n,{'quota':None},rebuild_q=True)
            print('已取消流量配额');return
        raise Fail('未知命令')



def ddns_set(args):
    if not re.fullmatch(r'[0-9a-fA-F]{32}',args.zone_id):raise Fail('Cloudflare zone ID 无效')
    if not re.fullmatch(r'[0-9a-fA-F]{32}',args.record_id):raise Fail('Cloudflare DNS 记录 ID 无效')
    name=public_host(args.name)
    tokenpath=Path(args.token_file)
    cloudflare_token(tokenpath)
    with locked():
        atomic_json(CONF/'ddns.json',{'provider':'cloudflare','zone_id':args.zone_id,'record_id':args.record_id,
                                     'name':name,'token_file':str(tokenpath),'last_ip':''})
        s=settings();s['host']=name;atomic_json(CONF/'settings.json',s)
        systemctl('enable','socks5-ddns.timer');systemctl('start','socks5-ddns.timer')
    print('已启用 Cloudflare DDNS；请运行 socks5 ddns-check 立即验证。原数字 IP 交付的客户不会自动修改。')


def cloudflare_token(tokenpath):
    if not tokenpath.is_absolute():raise Fail('token-file 必须使用绝对路径')
    try:
        fd=os.open(str(tokenpath),os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
        with os.fdopen(fd,'r',encoding='utf8') as src:
            mode=os.fstat(src.fileno())
            if not stat.S_ISREG(mode.st_mode) or mode.st_uid!=0 or (mode.st_mode & 0o077):
                raise Fail('token-file 必须为 root 私有普通文件，权限 600 或更严格')
            token=src.read(301).strip()
    except OSError as e:raise Fail(f'无法安全读取 DDNS token-file: {e}') from e
    if not 20<=len(token)<=300 or any(c.isspace() for c in token):raise Fail('Cloudflare token 格式无效')
    return token

def ddns_check():
    # One dedicated writer lock serializes DDNS updates, while network I/O
    # never holds the global customer-management lock.
    RUN.mkdir(parents=True,exist_ok=True,mode=0o700)
    with (RUN/'ddns.lock').open('a+') as ddns_fd:
        try:fcntl.flock(ddns_fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:return
        with locked(nonblocking=True) as ok:
            if not ok:return
            d=load(CONF/'ddns.json',default={})
            if not d:return
            wan=settings()['wan_if']
        validate_iface(wan);local_route(wan)
        iptxt=cmd(['curl','-4','-fsS','--interface',wan,'--connect-timeout','5',
                   '--max-time','20','https://api.ipify.org'],required=True).strip()
        try:
            ip=ipaddress.IPv4Address(iptxt)
            if not ip.is_global:raise Fail('获取的公网地址不是真公网 IPv4')
        except ipaddress.AddressValueError as e:raise Fail('无法解析公网 IPv4') from e
        if str(ip)==d.get('last_ip'):return
        token=cloudflare_token(Path(d['token_file']))
        url='https://api.cloudflare.com/client/v4/zones/'+d['zone_id']+'/dns_records/'+d['record_id']
        payload=json.dumps({'type':'A','name':d['name'],'content':str(ip),'ttl':60,'proxied':False}).encode()
        req=urllib.request.Request(url,payload,headers={'Authorization':'Bearer '+token,
                           'Content-Type':'application/json'},method='PATCH')
        try:
            with urllib.request.urlopen(req,timeout=20) as resp:ans=json.load(resp)
        except (urllib.error.URLError,TimeoutError,ValueError) as e:
            raise Fail(f'Cloudflare DDNS API 失败: {type(e).__name__}') from e
        if not ans.get('success'):raise Fail('Cloudflare DNS API 未返回 success')
        with locked():
            current=load(CONF/'ddns.json',default={})
            if current!=d:
                raise Fail('DDNS 设置在网络调用期间已变化；拒绝把旧的地址写进新状态')
            d['last_ip']=str(ip);atomic_json(CONF/'ddns.json',d)
        print('公网 IPv4 已同步到 DNS:',ip)


def parser():
    ap=argparse.ArgumentParser(description='Independent SOCKS5 manager for dual-ISP residential IPv4 egress')
    sub=ap.add_subparsers(dest='action',required=True)
    p=sub.add_parser('install');p.add_argument('--wan-if');p.add_argument('--host')
    p=sub.add_parser('add')
    p.add_argument('--id',default=os.getenv('id'))
    p.add_argument('--seconds',default=os.getenv('D'),required=not bool(os.getenv('D')))
    p.add_argument('--quota-gib',default=os.getenv('PQ_GIB'))
    p.add_argument('--ip-limit',default=os.getenv('IP_LIMIT','0'))
    p.add_argument('--sticky',default=os.getenv('IP_STICKY_SECONDS','120'))
    p.add_argument('--port',type=int,default=os.getenv('PORT'))
    p.add_argument('--port-start',default=os.getenv('PORT_START',str(PORT_MIN)))
    p.add_argument('--port-end',default=os.getenv('PORT_END',str(PORT_MAX)))
    p.add_argument('--public-port',type=int);p.add_argument('--host')
    p.add_argument('--connections',default='64');p.add_argument('--maxconn',default='128')
    p.add_argument('--max-start-retries',default=os.getenv('MAX_START_RETRIES','12'))
    for name in ('status','save','gc','reset','watch','restore','ddns-check','ddns-status'):sub.add_parser(name)
    sub.add_parser('list')
    p=sub.add_parser('audit');p.add_argument('id',nargs='?',help='可选：本机监听端口或账号 ID')
    p=sub.add_parser('clear');p.add_argument('--confirm',action='store_true')
    p=sub.add_parser('ddns-set')
    p.add_argument('--zone-id',required=True);p.add_argument('--record-id',required=True)
    p.add_argument('--name',required=True);p.add_argument('--token-file',required=True)
    for name in ('show','link','quota','pq-show','del','run','stop-post','ip-del','ip-show','pq-del'):
        p=sub.add_parser(name);p.add_argument('id')
        if name=='show':p.add_argument('--credentials',action='store_true')
    p=sub.add_parser('ip-set');p.add_argument('id');p.add_argument('ip_limit');p.add_argument('sticky',nargs='?')
    p=sub.add_parser('pq-set');p.add_argument('id');p.add_argument('quota_gib');p.add_argument('--confirm-reset',action='store_true')
    return ap

def main():
    os.umask(0o077)
    if os.geteuid()!=0:raise Fail('请使用 root 运行')
    args=parser().parse_args()
    operate(args)

if __name__=='__main__':
    try:main()
    except (Fail,OSError,ValueError,KeyError) as e:
        print('错误:',e,file=sys.stderr);sys.exit(1)
