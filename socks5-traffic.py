#!/usr/bin/env python3
"""Optional, passive daily traffic history for managed SOCKS5 nodes.
Like the original VLESS traffic.py, its nft counters never enforce quotas.
"""
from __future__ import annotations
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import uuid
from socks5 import STATE, UNITDIR, atomic_json, atomic_write, load, nodes, locked, cmd, Fail, render_table

TABLE='s5m_daily'
TZ=dt.timezone(dt.timedelta(hours=8),'Asia/Shanghai')
RE=re.compile(r't_([0-9a-f]{32})_([0-9a-f]{16})_([ud])\Z')


def active_nodes(now):
    result={}
    for n in nodes():
        if n['expires']<=now:continue
        identity=f"{n['instance']}|{n['port']}|{n['username']}|{n['created']}"
        key=hashlib.sha256(identity.encode()).hexdigest()[:32]
        result[n['id']]={'id':n['id'],'port':n['port'],'key':key}
    return result


def nft_snapshot():
    tables=cmd(['nft','-j','list','tables'])
    try:
        names=json.loads(tables)['nftables']
    except (ValueError,KeyError,TypeError) as e:raise Fail('无法读取 nft 表清单') from e
    if not any(i.get('table',{}).get('name')==TABLE and i['table'].get('family')=='inet' for i in names):
        return []
    try:return json.loads(cmd(['nft','-j','list','table','inet',TABLE]))['nftables']
    except (ValueError,TypeError,KeyError) as e:raise Fail('读取日流量表失败') from e


def counters(snapshot):
    result={}
    for row in snapshot:
        c=row.get('counter',{})
        if RE.fullmatch(c.get('name','')):
            v=c.get('bytes')
            if type(v) is not int or v<0:raise Fail('日流量计数器损坏')
            result[c['name']]=v
    return result


def matching(rule,chain,port,name):
    field='dport' if chain=='input' else 'sport'
    expected=[{'match':{'op':'==','left':{'payload':{'protocol':'tcp','field':field}},'right':port}},{'counter':name}]
    return rule.get('chain')==chain and rule.get('comment')==name and rule.get('expr')==expected


def reconcile(current,selected,snapshot,counts):
    commands=[]
    exists=any('table' in x and x['table'].get('name')==TABLE for x in snapshot)
    if not exists:commands.append('add table inet '+TABLE)
    chains={x['chain']['name']:x['chain'] for x in snapshot if 'chain' in x}
    for name in ('input','output'):
        if name not in chains:
            commands.append(f'add chain inet {TABLE} {name} {{ type filter hook {name} priority 10; policy accept; }}')
        elif any(chains[name].get(k)!=v for k,v in [('type','filter'),('hook',name),('prio',10),('policy','accept')]):
            raise Fail(f'日流量链 {name} 被外部修改')
    desired=[]
    for tag,n in sorted(current.items()):
        for direction,chain in [('u','input'),('d','output')]:
            key=(tag,direction); counter=selected[key]
            if counter is None:
                counter=f't_{n["key"]}_{uuid.uuid4().hex[:16]}_{direction}'
                commands.append(f'add counter inet {TABLE} {counter}')
            desired.append((chain,n['port'],counter))
    rules=[v['rule'] for v in snapshot if 'rule' in v]
    if len(rules)!=len(desired) or not all(sum(matching(r,*want) for r in rules)==1 for want in desired):
        for chain in ('input','output'):
            commands.append(f'flush chain inet {TABLE} {chain}')
        for chain,port,name in desired:
            field='dport' if chain=='input' else 'sport'
            commands.append(f'add rule inet {TABLE} {chain} tcp {field} {port} counter name {name} comment "{name}"')
    retained={name for _,_,name in desired}
    for name in counts:
        if name not in retained:commands.append(f'delete counter inet {TABLE} {name}')
    return commands


def collect():
    now=dt.datetime.now(TZ);today=now.date();current=active_nodes(int(now.timestamp()))
    path=STATE/'traffic'/'daily.json'
    history=load(path,default={'version':1,'users':{}})
    if history.get('version')!=1 or not isinstance(history.get('users'),dict):raise Fail('不支持的日流量记录版本')
    old=json.dumps(history,sort_keys=True)
    earliest=(today-dt.timedelta(days=29)).isoformat()
    for tag in list(history['users']):
        record=history['users'][tag]
        if tag not in current or record.get('key')!=current[tag]['key']:
            del history['users'][tag];continue
        record['days']={day:v for day,v in record.get('days',{}).items() if earliest<=day<=today.isoformat()}
    if old!=json.dumps(history,sort_keys=True):atomic_json(path,history)
    snapshot=nft_snapshot();counts=counters(snapshot)
    selected={}
    for tag,n in current.items():
        for direction in ('u','d'):
            names=sorted(name for name in counts if RE.fullmatch(name).group(1)==n['key'] and name[-1]==direction)
            previous=history['users'].get(tag,{}).get('last',{}).get(direction,{}).get('name')
            selected[tag,direction]=previous if previous in names else (names[0] if names else None)
    for tag,n in current.items():
        record=history['users'].setdefault(tag,{**n,'days':{},'last':{}})
        day=record['days'].setdefault(today.isoformat(),{'upload':0,'download':0})
        for direction,key in (('u','upload'),('d','download')):
            name=selected[tag,direction]
            if name is None:continue
            value=counts[name];prev=record['last'].get(direction,{})
            delta=value-prev['bytes'] if prev.get('name')==name and value>=prev['bytes'] else value
            day[key]+=delta
            record['last'][direction]={'name':name,'bytes':value}
        record['sampled_at']=now.isoformat(timespec='seconds')
    # Daily values and baselines commit together BEFORE changing nft generations.
    atomic_json(path,history)
    commands=reconcile(current,selected,snapshot,counts)
    if commands:cmd(['nft','-f','-'],input='\n'.join(commands)+'\n')
    return history


def pretty(num):
    val=float(num)
    for unit in ('B','KiB','MiB','GiB','TiB','PiB'):
        if val<1024 or unit=='PiB':return f'{val:.2f}{unit}'
        val/=1024


def display(state,selector=None,as_json=False):
    vals=[x for x in state['users'].values() if selector is None or selector in (x['id'],str(x['port']))]
    if selector is not None and not vals:raise Fail('未找到有效账号')
    if as_json:
        print(json.dumps({'timezone':'Asia/Shanghai','users':[
            {k:v[k] for k in ('id','port','days','sampled_at') if k in v} for v in vals]},indent=2,ensure_ascii=False));return
    today=dt.datetime.now(TZ).date().isoformat()
    print('每日流量统计 | 北京时间 | '+('今日 '+today if selector is None else '最近 30 天'))
    if not vals:print('当前无有效客户');return
    rows=[]
    for v in sorted(vals,key=lambda item:item['port']):
        for day,record in sorted(v.get('days',{}).items(),reverse=True):
            if selector is None and day!=today:continue
            up=record['upload'];down=record['download']
            rows.append([v['port'],day,pretty(up),pretty(down),pretty(up+down)])
    if rows:render_table(['PORT','DATE(BJ)','UPLOAD','DOWNLOAD','TOTAL'],rows,right={0,2,3,4})
    else:print('暂无采集数据（启用后每分钟采集一次）')
    print('说明：本表是每日流量历史；总配额/实时剩余请使用 socks5 quota 端口')


def install():
    exe='/usr/local/sbin/socks5-traffic'
    service=f'''[Unit]
Description=Sample standalone SOCKS5 daily traffic
After=local-fs.target nftables.service socks5-restore.service

[Service]
Type=oneshot
ExecStart={exe} --collect
TimeoutStartSec=120
UMask=0077
'''
    timer=f'''[Unit]
Description=Collect SOCKS5 daily traffic every minute

[Timer]
OnBootSec=30s
OnCalendar=*-*-* *:*:00
AccuracySec=1s
Persistent=true

[Install]
WantedBy=timers.target
'''
    shutdown=f'''[Unit]
Description=Save SOCKS5 daily traffic before shutdown
After=local-fs.target nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop={exe} --collect
TimeoutStopSec=120
UMask=0077

[Install]
WantedBy=multi-user.target
'''
    files={UNITDIR/'socks5-traffic.service':service.encode(),UNITDIR/'socks5-traffic.timer':timer.encode(),
           UNITDIR/'socks5-traffic-shutdown.service':shutdown.encode()}
    with locked():
        backups={path:(path.read_bytes() if path.exists() else None) for path in files}
        try:
            for path,body in files.items():atomic_write(path,body,0o644)
            cmd(['systemctl','daemon-reload'])
            collect()
            for unit in ('socks5-traffic.timer','socks5-traffic-shutdown.service'):
                cmd(['systemctl','enable',unit]);cmd(['systemctl','start',unit])
        except Exception:
            for path,old in backups.items():
                if old is None:path.unlink(missing_ok=True)
                else:atomic_write(path,old,0o644)
            cmd(['systemctl','daemon-reload'],required=False)
            raise
    print('每日流量统计模块安装完成')


def main():
    ap=argparse.ArgumentParser();ap.add_argument('id',nargs='?');ap.add_argument('--collect',action='store_true')
    ap.add_argument('--json',action='store_true');ap.add_argument('--install',action='store_true')
    a=ap.parse_args();os.umask(0o077)
    if os.geteuid()!=0:raise Fail('需要 root')
    if a.install:return install()
    with locked():state=collect()
    if not a.collect:display(state,a.id,a.json)

if __name__=='__main__':
    try:main()
    except (Fail,OSError,KeyError,ValueError) as e:
        print('流量统计失败:',e,file=sys.stderr);sys.exit(1)
