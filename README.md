# VLESS Reality 临时节点与 WG-NAT

面向使用者的安装与日常管理说明。项目包含主 VLESS Reality 节点、普通临时节点、流量/IP 限制，以及可选的 WG-NAT 出口。

| 脚本 | 运行位置 | 用途 |
|---|---|---|
| `vless.sh` | VLESS VPS | 安装主节点与普通临时节点管理工具 |
| `vpswg.sh` | VLESS VPS | 配置 WG-NAT 的 VPS 端 |
| `nat.sh` | NAT 出口机 | 配置并管理 NAT 出口 |
| `natjichang.sh` | VLESS VPS | 安装 WG-NAT 临时节点工具 |
| `traffic.py` | VLESS VPS | 可选：记录每日流量，保留最近 30 个自然日 |
| `portbw-install.sh`、`portbw.py` | VLESS VPS | 可选：按端口独立设置 TCP+UDP 共用上传/下载限速 |

> `natjichang.sh` 运行在 VLESS VPS，不是在 NAT 出口机。

## 使用前准备

- Debian 11+ 或 Ubuntu 20.04+
- `root` 用户、systemd 环境
- 一个 A 记录指向 VLESS VPS 公网 IPv4 的域名
- 创建 IPv6 临时节点时，再准备一个 AAAA 记录指向该 VPS 的域名
- 放行主节点 TCP 端口（默认 `443`）、临时节点 TCP 端口（默认 `40000-50050`）
- 使用 WG-NAT 时，放行 VLESS VPS 的 UDP `51820`

## 一、安装 VLESS 主节点

### 1. 安装

在 **VLESS VPS** 执行：

```bash
apt-get update && apt-get install -y curl ca-certificates && bash <(curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vless.sh')
```

### 2. 修改配置

```bash
nano /etc/default/vless-reality
```

参考配置：

```bash
PUBLIC_DOMAIN=proxy.example.com
PUBLIC_IPV6_DOMAIN=
CAMOUFLAGE_DOMAIN=www.apple.com
REALITY_DEST=www.apple.com:443
REALITY_SNI=www.apple.com
PORT=443
NODE_NAME=VLESS-REALITY-IPv4
```

通常只需要修改：

- `PUBLIC_DOMAIN`：A 记录必须指向当前 VPS
- `PUBLIC_IPV6_DOMAIN`：仅创建 IPv6 临时节点时填写
- `PORT`、`NODE_NAME`：按需修改

脚本默认伪装目标是 `www.apple.com`。需要更换时，请同时修改 `CAMOUFLAGE_DOMAIN`、`REALITY_DEST` 和 `REALITY_SNI`。

### 3. 创建或更新主节点

```bash
bash /root/onekey_reality_ipv4.sh
```

主节点链接：

```bash
cat /root/vless_reality_vision_url.txt
```

修改配置后重新执行主节点脚本即可。默认会保留原 UUID 和 Reality 密钥。

可选操作：

```bash
# 固定 Xray 版本
XRAY_VERSION=vX.Y.Z bash /root/onekey_reality_ipv4.sh

# 重新生成 UUID 和 Reality 密钥（旧链接会失效）
ROTATE_CREDENTIALS=1 bash /root/onekey_reality_ipv4.sh
```

## 二、创建临时节点

普通临时节点使用 VLESS VPS 自身出口；WG-NAT 临时节点使用 NAT 出口机的公网 IPv4。两者参数完全相同，只是创建命令不同：

| 节点类型 | 创建命令 |
|---|---|
| 普通临时节点 | `vless_mktemp.sh` |
| WG-NAT 临时节点 | `vless_mktemp_nat.sh` |

> WG-NAT 创建命令需要先完成本文“部署 WG-NAT”部分。
>
> `id` 是可选参数，省略后脚本会自动生成节点名称。手动填写时只支持英文字母、数字、点、下划线和连字符，不支持中文。下面示例均省略 `id`。

命令开头的数字控制有效期，`IP_LIMIT` 是活跃来源 IP 数量，`PQ_GIB` 是双向总流量配额。如果要加id在时间后面加上id="xx"即可。

### 按分钟

普通临时节点：

```bash
MINUTES=30; IP_VERSION=4 IP_LIMIT=3 PQ_GIB=1 D=$((MINUTES*60)) vless_mktemp.sh
```

WG-NAT 临时节点：

```bash
MINUTES=30; IP_VERSION=4 IP_LIMIT=3 PQ_GIB=1 D=$((MINUTES*60)) vless_mktemp_nat.sh
```

### 按小时

普通临时节点：

```bash
HOURS=2; IP_VERSION=4 IP_LIMIT=3 PQ_GIB=1 D=$((HOURS*60*60)) vless_mktemp.sh
```

WG-NAT 临时节点：

```bash
HOURS=2; IP_VERSION=4 IP_LIMIT=3 PQ_GIB=1 D=$((HOURS*60*60)) vless_mktemp_nat.sh
```

### 按天

普通临时节点：

```bash
DAYS=7; IP_VERSION=4 IP_LIMIT=3 PQ_GIB=50 D=$((DAYS*24*60*60)) vless_mktemp.sh
```

WG-NAT 临时节点：

```bash
DAYS=7; IP_VERSION=4 IP_LIMIT=3 PQ_GIB=50 D=$((DAYS*24*60*60)) vless_mktemp_nat.sh
```

### 固定端口

下面示例固定使用端口 `40000`，有效期为 1 小时。

普通临时节点：

```bash
HOURS=1; IP_VERSION=4 PORT_START=40000 PORT_END=40000 IP_LIMIT=3 PQ_GIB=1 D=$((HOURS*60*60)) vless_mktemp.sh
```

WG-NAT 临时节点：

```bash
HOURS=1; IP_VERSION=4 PORT_START=40000 PORT_END=40000 IP_LIMIT=3 PQ_GIB=1 D=$((HOURS*60*60)) vless_mktemp_nat.sh
```

固定端口时，`PORT_START` 和 `PORT_END` 必须设置为同一个端口。

### 创建 IPv6 入站节点

IPv6 只需改一个参数，按下面两步操作：

1. 在 `/etc/default/vless-reality` 中填写 `PUBLIC_IPV6_DOMAIN`，并确保该域名的 AAAA 记录指向当前 VLESS VPS。
2. 将上面任意创建命令中的 `IP_VERSION=4` 改成 `IP_VERSION=6`，其他参数不用改。

例如，将：

```bash
HOURS=2; IP_VERSION=4 IP_LIMIT=3 PQ_GIB=1 D=$((HOURS*60*60)) vless_mktemp.sh
```

改为：

```bash
HOURS=2; IP_VERSION=6 IP_LIMIT=3 PQ_GIB=1 D=$((HOURS*60*60)) vless_mktemp.sh
```

WG-NAT 同样只需把 `IP_VERSION=4` 改成 `IP_VERSION=6`；客户端通过 IPv6 连接 VLESS VPS，出站仍是 NAT 机的公网 IPv4。

常用调整：

- 不限制来源 IP：改为 `IP_LIMIT=0`
- 不限制流量：删除 `PQ_GIB=...`
- 修改固定端口：同时修改 `PORT_START` 和 `PORT_END`

创建成功后会直接输出端口、到期时间和节点链接。

## 三、查看与删除节点

### 查看全部节点

```bash
vless_audit.sh
```

### 按端口查询节点链接

修改最前面的端口：

```bash
PORT=40001; MAIN_PORT=$(awk -F= '$1=="PORT"{print $2; exit}' /var/lib/vless-reality/main/main.env /etc/default/vless-reality 2>/dev/null); if [ -n "$MAIN_PORT" ] && [ "$PORT" = "$MAIN_PORT" ]; then [ -s /root/vless_reality_vision_url.txt ] && cat /root/vless_reality_vision_url.txt || { echo "主节点链接文件不存在" >&2; exit 1; }; else mapfile -t files < <(grep -l "^PORT=${PORT}$" /var/lib/vless-reality/temp/*.env 2>/dev/null); [ "${#files[@]}" -eq 1 ] || { [ "${#files[@]}" -eq 0 ] && echo "未找到端口 ${PORT} 的节点" >&2 || echo "端口 ${PORT} 匹配到多个临时节点，请先运行 vless_audit.sh 检查" >&2; exit 1; }; url="${files[0]%.env}.url"; [ -s "$url" ] && cat "$url" || { echo "节点存在，但链接文件不存在：$url" >&2; exit 1; }; fi
```

### 按端口强制删除临时节点

修改最前面的端口：

```bash
PORT=40000; mapfile -t files < <(grep -l "^PORT=${PORT}$" /var/lib/vless-reality/temp/*.env 2>/dev/null); [ "${#files[@]}" -eq 1 ] || { [ "${#files[@]}" -eq 0 ] && echo "没找到端口 ${PORT} 对应的临时节点" >&2 || echo "端口 ${PORT} 匹配到多个临时节点，请先运行 vless_audit.sh 检查" >&2; exit 1; }; TAG=${files[0]##*/}; TAG=${TAG%.env}; FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG"
```

该命令只删除临时节点，不会删除主节点；普通临时节点和 WG-NAT 临时节点均适用。

### 清空全部临时节点

```bash
vless_clear_all.sh
```

## 四、流量与来源 IP 限制

创建节点时可以直接设置 `PQ_GIB`、`IP_LIMIT` 和 `IP_STICKY_SECONDS`，也可以按端口修改：

```bash
# 设置端口总流量为 50 GiB
pq_add.sh 40000 50

# 查看全部配额
pq_audit.sh

# 删除端口配额
pq_del.sh 40000

# 最多允许 2 个活跃来源 IP，槽位保持 300 秒
ip_set.sh 40000 2 300

# 删除来源 IP 数量限制
ip_del.sh 40000
```

### 按端口查看当前活跃来源 IP

修改最前面的端口，例如查询 `40000`：

```bash
PORT=40000; source /usr/local/lib/vless-reality/iplimit-lib.sh; vr_il_active_ips "$PORT" | tr ' ' '\n'
```

输出示例：

```text
1.2.3.4
5.6.7.8
```

这里显示的是该端口当前占用 `IP_LIMIT` 槽位的来源 IP。项目使用 nftables 动态集合记录这些 IP；只要该 IP 持续访问这个端口，对应槽位的超时时间就会刷新。

`IP_STICKY_SECONDS` 控制槽位保留时间，创建节点时默认是 `120` 秒。因此这里的“活跃 IP”表示最近一段时间仍占用槽位的 IP，不一定代表查询这一瞬间 TCP 连接仍处于 `ESTABLISHED` 状态。

如果端口设置为 `IP_LIMIT=0`，不会建立用于 IP_LIMIT 的动态集合，此时上面的命令不会列出来源 IP。

如果需要查看**此刻仍处于 TCP ESTABLISHED 状态**的连接，可以使用：

```bash
PORT=40000; ss -Htn state established "( sport = :$PORT )"
```

临时节点删除或到期时，绑定的配额和 IP 限制会一起清理。

创建时设置了 `PQ_GIB` 且有效期严格大于 30 天，配额会每 30 天自动重置。

### 可选：每日流量记录（保留 30 天）

在已经安装 VLESS 的 **VLESS VPS** 上，以 `root` 执行。此功能独立安装，支持主节点、普通临时节点和 WG-NAT 临时节点，包括未设置流量配额的节点；无需重新运行主脚本或重启 Xray。

#### 安装

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/traffic.py' -o /root/vless_traffic.py && python3 /root/vless_traffic.py --install
```

#### 使用方法

```bash
# 查看所有有效用户今天的流量
vless_traffic

# 按端口查看某个用户最近 30 个自然日的每日明细
vless_traffic 40002

# 查看主节点的每日明细（不受主节点端口设置影响）
vless_traffic main

# 主节点使用 443 端口时，也可以这样查询
vless_traffic 443

# 按创建时指定的节点 ID 或完整 TAG 查询
vless_traffic tmp001
vless_traffic vless-temp-tmp001

# 导出某个用户保留的历史记录，流量单位为字节
vless_traffic 40002 --json
```

将示例端口、节点 ID 或 TAG 替换为实际值；可以先运行 `vless_audit.sh` 查看节点。

**默认只显示今天**，每个用户一条记录。到了第二天，昨天的数据仍会保留，但不会挤在默认列表中；指定端口、节点 ID、TAG 或 `main` 才会展开该用户的历史明细。没有历史记录的日期不会补造数据。`--json` 导出完整保留历史，不受默认表格“只显示今天”的限制。

表格自动换算 B、KiB、MiB、GiB 等单位，字段含义如下：

| 字段 | 含义 |
|---|---|
| NAME | 节点名称 |
| PORT | 节点端口 |
| DATE | 北京时间日期 |
| UP | 用户当天上传流量 |
| DOWN | 用户当天下载流量 |
| TOTAL | 当天上传与下载合计，不是节点累计用量或剩余配额 |

#### 保留与清理规则

- 按**北京时间（UTC+8）**分日，保留今天和前 29 个自然日，采集时自动删除超出范围的日期。
- 正常每分钟采集一次，运行查询命令时也会采集。
- 用户到期、主动删除或清空临时节点后，下一次成功采集清理时自动删除对应的全部流量历史，正常情况下约 1 分钟内完成。
- 同名重建节点或复用端口时，新用户不会继承旧用户的记录。
- 记录独立于流量配额；调整、删除或重置配额不会重置每日流量记录。
- 数据保存在 `/var/lib/vless-reality/traffic/daily.json`，更新统计脚本和重启服务器会保留已保存的记录，仍按上述规则自动清理。

从安装启用后开始记录，无法补回安装前的用量。统计按节点/端口归属，多人共用一个节点链接时会合并计算。流量包含 TCP 网络协议开销；每分钟采样的增量计入采样当天，因此跨午夜可能存在采样间隔内的日期归属误差。断电或外部清空统计计数器可能丢失尚未保存的增量。

### 可选：TCP+UDP 同端口共享限速（portbw）

此组件与 VLESS 节点管理、流量统计、WG-NAT 相互独立：**按本机监听端口限速，不绑定节点配置**。TCP 和 UDP 使用同一个端口时，二者在**上传方向合计使用一个额度**，在**下载方向合计使用另一个额度**；IPv4 和 IPv6 也共用各自方向的同一额度，不是每种协议分别限速。实际速度可能因协议开销、丢包和瞬时突发略有波动。

#### 一键安装 / 更新

在 **VLESS VPS** 以 root 执行（不会修改 Xray、WireGuard、已有 nft 表及 root `fq` qdisc）：

```bash
apt-get update && apt-get install -y curl ca-certificates && bash <(curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/portbw-install.sh')
```

安装器从**本正式仓库**下载 `portbw.py`、校验 SHA256 与 Python 语法，自动识别物理出口网卡，安装开机自动恢复服务和每 30 秒自检定时器。也可以将 `portbw-install.sh` 与 `portbw.py` 放在同一目录，通过 `bash portbw-install.sh` 本地安装。

#### 设置、查询、取消

```bash
portbw set 40001 10 20  # 40001：TCP+UDP 合计上传 10 Mbps / 合计下载 20 Mbps
portbw up 40001 15      # 上传上限改为 15 Mbps
portbw down 40001 30    # 下载上限改为 30 Mbps
portbw down 40001 0     # 仅关闭下载限速；上传额度不变
portbw show 40001       # 查看端口配置及 nft/tc 状态
portbw list             # 查看所有已保存的端口限速
portbw audit            # 检查所有限速策略的生效状态
portbw del 40001        # 仅取消端口限速，不删除 VLESS 节点
```

`0` 表示对应方向**不限速**；两个方向都无需限速时用 `portbw del <端口>`。限速覆盖本机进入/离开的 TCP、UDP 流量，不覆盖任意 WireGuard/NAT `FORWARD` 转发流量；上传由 nftables + tc 执行限速，下载使用 tc egress 的单个共享 policer，nftables 负责计数（避免 OUTPUT 超限导致 UDP 程序 `Operation not permitted`）。`--nft-only` 不支持下载限速，请使用默认的 nft+tc 模式以获得完整双向限速。

**旧版升级注意：** 本次升级改变了 tc flower 的协议槽位（从 TCP 专用改为 TCP+UDP 双协议）和保存的 `tc_prefs` 格式。**已使用旧版 `portbw` 创建策略的 VPS 不能保证直接无中断升级**。先执行 `portbw list` 并备份端口及速率；如需迁移，请在维护时段用**旧版** `portbw del <端口>` 逐个取消旧策略，确认旧 tc/nft 规则已清除后再运行上述新安装器，最后按记录重新执行 `portbw set`。取消到重建之间，该端口暂不受 portbw 限制。**不要手动 `nft flush ruleset` 或删除网卡 root qdisc**；发现旧规则残留应先检查，不要强制清理其他业务的规则。未安装过 portbw 的全新 VPS 可直接安装。

**验收范围：** Debian 12 / `eth0` 上，IPv4 单协议、TCP+UDP 双向混合共享速率、反复修改/删除/重建、重启恢复，以及原始快照全新安装均已实测通过；该实测 VPS 未配置公网 IPv6，因此 IPv6 规则虽通过配置审计，但**没有 IPv6 实际测速结论**。不同发行版和网卡环境仍应进行自己的验收。

## 五、部署 WG-NAT

WG-NAT 让 VLESS VPS 上的指定临时节点通过另一台机器的公网 IPv4 出口访问互联网。

### 1. 初始化 NAT 出口机

在 **NAT 出口机** 执行：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/nat.sh' -o /root/nat.sh && chmod 700 /root/nat.sh && bash /root/nat.sh init
```

无法识别公网网卡时：

```bash
WAN_IF=eth0 bash /root/nat.sh init
```

### 2. 配置 VLESS VPS

在 **VLESS VPS** 执行：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vpswg.sh' -o /root/vpswg.sh && chmod 700 /root/vpswg.sh && bash /root/vpswg.sh
```

脚本会输出 VPS WireGuard 公钥。以后忘记时，在 **VLESS VPS** 查询：

```bash
cat /etc/wireguard/wg-nat.pub
```

### 3. 在 NAT 机添加 VPS

在 **NAT 出口机** 执行：

```bash
bash /root/nat.sh add hy2 hy2.example.com '这里替换成VPS公钥'
```

这条命令中的三个参数分别是：

- `hy2`：这台 VLESS VPS 在 NAT 机上的名称，可自行改成 `vps1`、`hk1` 等；以后查看、更新和删除都使用这个名称。
- `hy2.example.com`：VLESS VPS 的公网 IPv4 域名，也可以直接填写公网 IPv4。
- `'这里替换成VPS公钥'`：在 VLESS VPS 执行 `cat /etc/wireguard/wg-nat.pub` 得到的公钥。

NAT 机会自动分配 WG 地址，并打印一条完整的 VPS 回填命令。

### 4. 回到 VPS 执行回填命令

原样执行 NAT 机输出的命令。输出丢失时，可以重新执行上一步同名的 `nat.sh add`，NAT 机会再次打印回填命令。

忘记 NAT 出口机公钥时，在 **NAT 出口机** 查询：

```bash
cat /etc/wireguard/wg-exit.pub
```

回填完成后检查出口：

```bash
/usr/local/sbin/wg_nat_healthcheck.sh
```

出现以下结果后再继续：

```text
OK EXIT_IP=x.x.x.x
```

### 5. 安装 WG-NAT 临时节点工具

在 **VLESS VPS** 执行：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/natjichang.sh' -o /root/natjichang.sh && chmod 700 /root/natjichang.sh && bash /root/natjichang.sh
```

### NAT 出口机管理

以下命令都在 **NAT 出口机** 执行。

#### 查看已经添加的 VPS

```bash
bash /root/nat.sh list
```

先用这条命令查看每台 VPS 的名称。后面的 `hy2` 必须替换成这里显示的实际名称。

#### 查看完整运行状态

```bash
bash /root/nat.sh status
```

用于查看 WireGuard 接口、所有 VPS Peer、Endpoint 和握手状态。连接异常时先执行这条命令。

#### 删除某台 VPS 的 NAT 接入记录

例如删除名称为 `hy2` 的 VPS：

```bash
bash /root/nat.sh del hy2
```

`hy2` 只是示例。删除前先执行 `bash /root/nat.sh list`，复制需要删除的实际名称。

#### 更新 VPS 的域名、IP 或公钥

使用与原来相同的名称再次执行 `add`：

```bash
bash /root/nat.sh add hy2 hy2.example.com '当前VPS公钥'
```

同名 `add` 会更新该 VPS 的连接信息，并保留原来分配的 WG 地址。VPS 公钥可在 VLESS VPS 执行以下命令重新查询：

```bash
cat /etc/wireguard/wg-nat.pub
```

#### 忘记公钥时

```bash
# 在 VLESS VPS 查询 VPS 公钥
cat /etc/wireguard/wg-nat.pub

# 在 NAT 出口机查询 NAT 公钥
cat /etc/wireguard/wg-exit.pub
```

## 六、更新脚本

### VLESS 管理工具

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vless.sh' -o /root/vless.sh && chmod 700 /root/vless.sh && bash /root/vless.sh
```

需要更新 Xray 主程序或重新应用主配置时：

```bash
bash /root/onekey_reality_ipv4.sh
```

### 每日流量统计

已安装统计组件时，在 **VLESS VPS** 重新执行以下命令即可更新：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/traffic.py' -o /root/vless_traffic.py && python3 /root/vless_traffic.py --install
```

无需删除历史数据，也无需重新安装主脚本。更新后运行 `vless_traffic`，标题应显示“今日”；运行 `vless_traffic main` 可查看主节点保留的每日明细。

### VLESS VPS 的 WG-NAT 工具

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vpswg.sh' -o /root/vpswg.sh && chmod 700 /root/vpswg.sh && bash /root/vpswg.sh
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/natjichang.sh' -o /root/natjichang.sh && chmod 700 /root/natjichang.sh && bash /root/natjichang.sh
```

### NAT 出口机

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/nat.sh' -o /root/nat.sh && chmod 700 /root/nat.sh && bash /root/nat.sh init
```

## 七、常见排查

### 主节点

```bash
systemctl status xray.service
journalctl -u xray.service -n 120 --no-pager
```

### 临时节点、配额或规则异常

```bash
vless_restore_all.sh
vless_audit.sh
pq_audit.sh
```

### 按端口查看临时节点日志

```bash
PORT=40000; mapfile -t files < <(grep -l "^PORT=${PORT}$" /var/lib/vless-reality/temp/*.env 2>/dev/null); [ "${#files[@]}" -eq 1 ] || { echo "无法唯一找到端口 ${PORT} 对应的临时节点" >&2; exit 1; }; TAG=${files[0]##*/}; TAG=${TAG%.env}; journalctl -u "${TAG}.service" -n 100 --no-pager
```

### 每日流量统计

```bash
systemctl status vless-traffic.timer vless-traffic-shutdown.service
journalctl -u vless-traffic.service -n 50 --no-pager
```

定时器负责每分钟触发采集，采集服务执行完成后退出属于正常行为。若默认查询仍显示多天数据，请先按“更新脚本”中的每日流量统计命令更新。

### 域名解析

```bash
getent ahostsv4 proxy.example.com
curl -4 https://api.ipify.org

getent ahostsv6 proxy6.example.com
ip -6 addr show scope global
```

### WG-NAT

```bash
/usr/local/sbin/wg_nat_healthcheck.sh
```

仍有问题时，在 NAT 出口机执行：

```bash
bash /root/nat.sh status
```

---

请仅在自己拥有或获得授权的服务器和网络环境中使用，并遵守所在地法律、服务商条款和网络使用规定。


## 八、可选：独立 SOCKS5 代理（3proxy）

在**单独的家宽主机**上用 `root` 安装，与 VLESS VPS 分开。Debian 12 已完成真机验收；Debian 13 和 Ubuntu 22.04/24.04 LTS 在代码依赖上可能兼容，但尚未完成真机验收。

### 1. 安装 / 更新

在家宽主机执行（安装新版不会主动清空已有账号；更新时可能短暂影响连接）：

```bash
apt-get update && apt-get install -y curl ca-certificates
AUTO_DEPS=1 bash <(curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/socks5-install.sh') install
```

主机位于路由器 NAT 后面时，可以在 `install` 后加 `--host proxy.example.com`（换成自己的公网域名/IP）。必要时加 `--wan-if eth0` 指定物理出口网卡。

### 2. 创建临时账号（最后一行直接输出 SOCKS5 连接链接）

命令直接修改数字：`IP_LIMIT`=最多来源 IP 数量；`IP_STICKY_SECONDS`=来源 IP 闲置占位时长（秒）；`PQ_GIB`=上传+下载合计总配额（GiB）。持续活动的 IP 会刷新占位时间，超时后释放名额，不是强制断开已建立连接。

#### 按分钟

创建有效期 **30 分钟**、最多 **1 个来源 IP**、**IP 占位 60 秒（1 分钟）**、总配额 **1 GiB** 的账号：

```bash
MINUTES=30; IP_LIMIT=1 IP_STICKY_SECONDS=60 PQ_GIB=1 D=$((MINUTES*60)) socks5 add
```

#### 按小时

创建有效期 **2 小时**、最多 **2 个来源 IP**、**IP 占位 300 秒（5 分钟）**、总配额 **5 GiB** 的账号：

```bash
HOURS=2; IP_LIMIT=2 IP_STICKY_SECONDS=300 PQ_GIB=5 D=$((HOURS*3600)) socks5 add
```

#### 按天

创建有效期 **7 天**、最多 **3 个来源 IP**、**IP 占位 600 秒（10 分钟）**、总配额 **50 GiB** 的账号：

```bash
DAYS=7; IP_LIMIT=3 IP_STICKY_SECONDS=600 PQ_GIB=50 D=$((DAYS*86400)) socks5 add
```

#### 指定固定端口

创建有效期 **1 小时**、最多 **1 个来源 IP**、**IP 占位 60 秒**、总配额 **1 GiB**、监听端口 `41004` 的账号：

```bash
HOURS=1; IP_LIMIT=1 IP_STICKY_SECONDS=60 PQ_GIB=1 PORT=41004 D=$((HOURS*3600)) socks5 add
```

省略 `PORT` 自动选择本机空闲端口；`IP_LIMIT=0` 不限制来源 IP；删除 `PQ_GIB=...` 表示不限总配额。创建时可选 `id=myproxy` 自定义内部 ID，但**日常命令直接使用端口即可，不用记 ID**。

家宽主机在路由器后面时，需要把公网 **TCP** 端口映射到本机 SOCKS5 监听端口。若外部端口与本地端口不同，例如外部 `51004` 映射到本机 `41004`：

```bash
HOURS=1; IP_LIMIT=1 IP_STICKY_SECONDS=60 PORT=41004 D=$((HOURS*3600)) socks5 add --host proxy.example.com --public-port 51004
```

**重要：下面管理命令使用的是本机监听端口 `41004`，不是路由器映射的外部端口 `51004`。**

### 3. 按端口查看账号、剩余流量和连接链接

```bash
socks5 list                         # 对齐表格：端口、剩余流量、IP当前占用/上限、占位时间、防护
socks5 audit                        # 与 list 一样显示表格；发现异常时返回错误
socks5 audit 41004                  # 只检查端口 41004
socks5 quota 41004                  # 最重要：查看 41004 总配额、已用、剩余（包括精确字节数）
socks5 link 41004                   # 输出完整 socks5:// 连接链接
socks5 show 41004 --credentials     # 详细 JSON、用户名和密码
socks5 status                       # 运行状态与出口网卡
```

表格说明：`LIMIT`=总配额，`USED`=已用，**`LEFT`=实时剩余额度**，`USE%`=使用比例，`TTL`=剩余有效期，`EXPIRE(BJ)`=北京时间到期日期，`IP占用`=当前有效占位 IP 数/允许上限（例如 **2/3** 表示最多允许 3 个来源 IP，目前占用了 2 个名额），`STICKY`=IP 停止活动后的占位释放秒数。若实时 nftables 计数无法读取，`LEFT` 会显示 **未知**，不会把缓存值误当实时余额。**IP占用统计的是仍在占位期内的不同来源 IP，不是实时建立的 TCP 连接数；读取失败显示 ?/上限，而不是错误显示为零。** 窄终端会隐藏部分列，精确字节数请用 `socks5 quota 41004`。

`socks5-traffic` 每日统计**不等于**总流量配额；剩余可用配额以 `socks5 quota` 查询为准。

### 4. 按端口修改、删除账号

```bash
socks5 ip-show 41004                # 查看当前占位数量、具体来源 IP 和剩余占位时间
socks5 ip-set 41004 2 60            # 最多 2 个来源 IP，闲置占位 60 秒（重置已有占位记录）
socks5 ip-del 41004                 # 取消来源 IP 数量限制
socks5 pq-set 41004 5 --confirm-reset  # 重新设置 5 GiB 总配额，已用量从零开始
socks5 pq-del 41004                 # 取消总配额（不限流量）
socks5 del 41004                    # 删除本机端口 41004 对应的 SOCKS5 账号
```

为兼容旧版，也可以继续输入创建时返回的账号 ID；新建、到期或删除账号**不会改动独立 `portbw` 策略**。

### 5. 可选：每日流量历史（最近 30 天）

```bash
socks5-traffic --install            # 首次开启或更新每日流量采集
socks5-traffic                      # 按端口显示今天上传/下载流量
socks5-traffic 41004                # 查看端口 41004 最近 30 天的每日流量
socks5-traffic 41004 --json         # JSON 格式
socks5 watch                        # 手动检查和恢复防护
```

每日统计按约每分钟采样的增量记录；不能把每日流量直接当作实时剩余配额。

### 6. 可选：按端口限速（独立 portbw）

需要限速时，在**实际运行 SOCKS5 的家宽主机**安装原有 `portbw`，再按本机监听端口手动设置：

```bash
bash <(curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/portbw-install.sh')
portbw set 41004 10 20              # 上传 10 Mbps，下载 20 Mbps
portbw show 41004
portbw list
portbw audit
portbw del 41004                    # 只删除限速，不删除 SOCKS5 账号
```

SOCKS5 仅支持 TCP CONNECT，不支持 UDP ASSOCIATE；`portbw` 独立按原有方式管理 TCP+UDP。SOCKS5 的创建、修改、到期和删除都不会增删修改 `portbw` 规则。
