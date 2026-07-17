# VLESS Reality、临时节点与 WG-NAT 使用说明

项目地址：

```text
https://github.com/liucong552-art/zuizhongheji
```

这份说明只面向实际使用，不展开 WireGuard、策略路由、nftables、systemd timer 等内部原理。

仓库中的脚本：

| 脚本 | 在哪里运行 | 用途 |
|---|---|---|
| `vless.sh` | VLESS VPS | 安装主节点脚本和临时节点管理功能 |
| `vpswg.sh` | VLESS VPS | 接入 WG-NAT 出口机 |
| `nat.sh` | NAT 出口机 | 初始化 NAT 出口并管理 VPS |
| `natjichang.sh` | VLESS VPS | 安装 WG-NAT 临时节点功能 |

> `natjichang.sh` 运行在 VLESS VPS，不是在 NAT 出口机。

---

## 一、开始前准备

需要：

- Debian 11+ 或 Ubuntu 20.04+
- `root` 用户
- 正常使用 systemd 的 VPS
- 一个指向 VLESS VPS 公网 IPv4 的域名
- 创建 IPv6 临时节点时，还需要一个指向该 VPS 公网 IPv6 的域名

云服务器安全组或防火墙至少放行：

- 主节点 TCP 端口，默认 `443`
- 临时节点 TCP 端口，默认范围 `40000-50050`
- 使用 WG-NAT 时，VLESS VPS 的 UDP `51820`

正常安装时不需要先运行 `id`、`ps`、`uname`。脚本会自行检查系统环境；只有安装报错时，再看本文“常见问题”。

---

## 二、安装 VLESS 主系统

以下命令都在 **VLESS VPS** 执行。

### 1. 运行总脚本

推荐直接执行：

```bash
apt-get update && apt-get install -y curl ca-certificates && bash <(curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vless.sh')
```

这一步会安装主节点安装脚本和临时节点管理命令，但不会替你填写域名。

### 2. 编辑主配置

```bash
nano /etc/default/vless-reality
```

最少按自己的实际情况修改：

```bash
PUBLIC_DOMAIN=proxy.example.com
PUBLIC_IPV6_DOMAIN=
CAMOUFLAGE_DOMAIN=www.cloudflare.com
REALITY_DEST=www.cloudflare.com:443
REALITY_SNI=www.cloudflare.com
PORT=443
NODE_NAME=MY-VLESS
```

说明：

- `PUBLIC_DOMAIN` 的 A 记录必须指向当前 VLESS VPS。
- `PUBLIC_IPV6_DOMAIN` 只在需要 IPv6 临时节点时填写。
- `PORT` 是主节点端口，可以不是 `443`。
- `NODE_NAME` 是客户端里显示的节点名称。

### 3. 创建或更新主节点

```bash
bash /root/onekey_reality_ipv4.sh
```

成功后会直接显示主节点链接。

主节点原始链接保存在：

```bash
cat /root/vless_reality_vision_url.txt
```

主节点 Base64 订阅保存在：

```bash
cat /root/v2ray_subscription_base64.txt
```

### 4. 以后修改主配置

修改 `/etc/default/vless-reality` 后，再执行：

```bash
bash /root/onekey_reality_ipv4.sh
```

脚本正常情况下会保留原来的 UUID 和 Reality 密钥。

<details>
<summary>可选：固定 Xray 版本</summary>

“固定 Xray 版本”只用于执行主节点安装或更新这一步，不是创建临时节点时使用。

普通用户不需要填写版本，直接运行：

```bash
bash /root/onekey_reality_ipv4.sh
```

只有需要回退、锁定版本或让多台机器保持相同版本时，才使用：

```bash
XRAY_VERSION=vX.Y.Z bash /root/onekey_reality_ipv4.sh
```

例如：

```bash
XRAY_VERSION=v26.1.23 bash /root/onekey_reality_ipv4.sh
```

请把版本号替换为真实存在的 Xray 版本。

</details>

<details>
<summary>可选：重新生成主节点凭据</summary>

只有明确需要更换 UUID 和 Reality 密钥时才执行：

```bash
ROTATE_CREDENTIALS=1 bash /root/onekey_reality_ipv4.sh
```

执行后旧客户端链接会失效。

</details>

---

## 三、创建普通临时节点

普通临时节点使用当前 VLESS VPS 自己的公网出口。

常用参数：

| 参数 | 含义 | 默认值 |
|---|---|---|
| `id` | 临时节点名称 | 自动生成 |
| `D` | 有效期，单位秒，必填 | 无 |
| `IP_VERSION` | 入站类型，`4` 或 `6` | `4` |
| `PORT_START` | 可用端口范围起点 | `40000` |
| `PORT_END` | 可用端口范围终点 | `50050` |
| `IP_LIMIT` | 允许的活跃来源 IP 数量，`0` 表示不限制 | `0` |
| `IP_STICKY_SECONDS` | 来源 IP 槽位保持时间 | `120` |
| `PQ_GIB` | 双向总流量配额，单位 GiB | 不启用 |

常用时间：

| 时长 | `D` |
|---|---:|
| 1 分钟 | `60` |
| 1 小时 | `3600` |
| 1 天 | `86400` |
| 31 天 | `2678400` |

> 命令开头的 `id=tmp1h` 是给脚本传递节点名称，不是让你单独执行 Linux 的 `id` 命令。

### 1. 自动选择空闲端口

1 小时、最多 3 个来源 IP、总流量 1 GiB：

```bash
id=tmp1h IP_VERSION=4 IP_LIMIT=3 PQ_GIB=1 D=3600 vless_mktemp.sh
```

创建成功后，脚本会直接显示实际端口和节点链接。

### 2. 固定使用某个端口

固定端口 `40000`：

```bash
id=tmp40000 IP_VERSION=4 PORT_START=40000 PORT_END=40000 IP_LIMIT=3 PQ_GIB=1 D=3600 vless_mktemp.sh
```

固定端口时，`PORT_START` 和 `PORT_END` 必须填写成同一个端口。

### 3. 创建 1 天节点

```bash
id=tmp1d IP_VERSION=4 IP_LIMIT=3 PQ_GIB=50 D=86400 vless_mktemp.sh
```

### 4. 创建 IPv6 临时节点

先在主配置中填写：

```bash
PUBLIC_IPV6_DOMAIN=proxy6.example.com
```

并确认该域名的 AAAA 记录指向当前 VPS，然后执行：

```bash
id=tmp6 IP_VERSION=6 IP_LIMIT=3 PQ_GIB=1 D=3600 vless_mktemp.sh
```

注意：

- IPv4 临时节点只接受 IPv4 入站。
- IPv6 临时节点只接受 IPv6 入站。
- 同一个尚未到期的 `id` 不要重复创建。

---

## 四、日常查看和管理

日常管理建议以 **端口号** 为入口，不需要先记住 TAG。

### 1. 查看主节点和全部临时节点

```bash
vless_audit.sh
```

这条命令已经会显示节点端口、运行状态、到期时间、配额和 IP 限制等信息。

### 2. 按端口查询节点链接

下面一条命令同时支持：

- 主节点
- 普通临时节点
- WG-NAT 临时节点
- 主节点端口不是 `443` 的情况

只修改最前面的 `PORT=40001`：

```bash
PORT=40001; MAIN_PORT=$(awk -F= '$1=="PORT"{print $2; exit}' /var/lib/vless-reality/main/main.env /etc/default/vless-reality 2>/dev/null); if [ -n "$MAIN_PORT" ] && [ "$PORT" = "$MAIN_PORT" ]; then [ -s /root/vless_reality_vision_url.txt ] && cat /root/vless_reality_vision_url.txt || { echo "主节点链接文件不存在" >&2; exit 1; }; else mapfile -t files < <(grep -l "^PORT=${PORT}$" /var/lib/vless-reality/temp/*.env 2>/dev/null); [ "${#files[@]}" -eq 1 ] || { [ "${#files[@]}" -eq 0 ] && echo "未找到端口 ${PORT} 的节点" >&2 || echo "端口 ${PORT} 匹配到多个临时节点，请先运行 vless_audit.sh 检查" >&2; exit 1; }; url="${files[0]%.env}.url"; [ -s "$url" ] && cat "$url" || { echo "节点存在，但链接文件不存在：$url" >&2; exit 1; }; fi
```

例如：

- 查主节点：把 `PORT=` 改成主节点实际端口。
- 查临时节点：把 `PORT=` 改成该临时节点端口。

不再需要单独准备一条“查主节点链接”的命令。

### 3. 查看某端口当前占用的实时来源 IP

只有已经启用 `IP_LIMIT` 的端口才会有来源 IP 集合。

只修改最前面的 `PORT=40003`：

```bash
PORT=40003; META="/var/lib/vless-reality/iplimit/${PORT}.env"; [ -f "$META" ] || { echo "端口 ${PORT} 未启用 IP_LIMIT，当前没有来源 IP 集合" >&2; exit 1; }; IP_VERSION=$(awk -F= '$1=="IP_VERSION"{print $2; exit}' "$META"); { [ "$IP_VERSION" = 4 ] || [ "$IP_VERSION" = 6 ]; } || { echo "无法识别端口 ${PORT} 的 IP_VERSION" >&2; exit 1; }; SET="vr_il${IP_VERSION}_${PORT}"; echo "端口 ${PORT} 当前来源 IP（IPv${IP_VERSION}）"; nft list set inet vr_iplimit "$SET"
```

当前脚本使用的集合名称是：

- IPv4：`vr_il4_端口`
- IPv6：`vr_il6_端口`

旧教程里的 `vr_il_端口` 已不适用于当前脚本。

### 4. 强制按端口删除临时节点

只修改最前面的 `PORT=40000`：

```bash
PORT=40000; mapfile -t files < <(grep -l "^PORT=${PORT}$" /var/lib/vless-reality/temp/*.env 2>/dev/null); [ "${#files[@]}" -eq 1 ] || { [ "${#files[@]}" -eq 0 ] && echo "没找到端口 ${PORT} 对应的临时节点" >&2 || echo "端口 ${PORT} 匹配到多个临时节点，请先运行 vless_audit.sh 检查" >&2; exit 1; }; TAG=${files[0]##*/}; TAG=${TAG%.env}; echo "强制删除临时节点：PORT=${PORT}, TAG=${TAG}"; FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG"
```

说明：

- 该命令只查找临时节点，不会删除主节点。
- `FORCE=1` 表示即使节点尚未到期也立即清理。
- 普通临时节点和 WG-NAT 临时节点都使用同一条删除命令。
- 命令会检查是否有多个记录占用同一端口，不会用 `head -n1` 静默选中其中一个。

### 5. 已知 TAG 时删除

只有已经明确知道 TAG 时才需要：

```bash
FORCE=1 vless_cleanup_one.sh vless-temp-tmp1h
```

### 6. 查看临时节点聚合订阅

RAW：

```bash
cat /root/vless_temp_subscription.txt
```

Base64：

```bash
cat /root/vless_temp_subscription_base64.txt
```

手动刷新：

```bash
vless_temp_sub.sh
```

### 7. 清空全部临时节点

```bash
vless_clear_all.sh
```

这会清理普通临时节点和 WG-NAT 临时节点，但不会删除主节点。

---

## 五、流量配额

创建临时节点时可以直接填写：

```bash
PQ_GIB=50
```

也可以以后按端口增加或修改。

给端口 `40000` 设置总流量 `50 GiB`：

```bash
pq_add.sh 40000 50
```

查看全部端口配额：

```bash
pq_audit.sh
```

删除端口配额：

```bash
pq_del.sh 40000
```

说明：

- 对临时节点端口执行 `pq_add.sh`，新配额会绑定并同步到该临时节点。
- 临时节点删除或到期时，对应配额会一起清理。
- 对非临时端口执行 `pq_add.sh`，按普通手工配额管理。
- 手工执行 `pq_add.sh` 不会启用 30 天自动重置。
- `pq_del.sh` 只删除配额，不删除节点。

### 30 天自动重置

只有创建临时节点时同时满足以下条件才会启用：

- 设置了 `PQ_GIB`
- `D` 严格大于 `2592000` 秒，也就是严格大于 30 天

示例：

```bash
id=tmp31d IP_LIMIT=1 PQ_GIB=100 D=2678400 vless_mktemp.sh
```

恰好 `D=2592000` 不会启用自动重置。

---

## 六、来源 IP 数量限制

创建临时节点时可以直接填写：

```bash
IP_LIMIT=3 IP_STICKY_SECONDS=120
```

也可以以后按端口修改。

最多允许 1 个活跃来源 IP：

```bash
ip_set.sh 40005 1
```

最多允许 2 个活跃来源 IP：

```bash
ip_set.sh 40005 2
```

最多允许 2 个，槽位保持 300 秒：

```bash
ip_set.sh 40005 2 300
```

删除来源 IP 数量限制：

```bash
ip_del.sh 40005
```

说明：

- 不填写 `sticky_seconds` 时，已有规则会沿用旧值；没有旧值时默认 `120` 秒。
- 对临时节点端口执行 `ip_set.sh`，限制会绑定并同步到该临时节点。
- 对非临时端口执行时，按普通手工限制管理。
- `ip_del.sh` 只删除来源 IP 数量限制，不删除节点。
- 对临时节点删除数量限制后，IPv4/IPv6 入站类型仍保持不变。

查看实时来源 IP，请使用上一节的“查看某端口当前占用的实时来源 IP”。

---

## 七、自动维护

临时节点到期后会自动清理；配额保存、重启恢复和异常修复也由系统自动处理。

正常使用不需要手动管理服务或定时器。

遇到异常时先执行：

```bash
vless_audit.sh
pq_audit.sh
```

需要手动恢复管理状态时：

```bash
vless_restore_all.sh
```

---

## 八、部署 WG-NAT

WG-NAT 用于让 VLESS VPS 上的指定临时节点，通过另一台机器的公网 IPv4 出口访问互联网。

需要两台机器：

- **VLESS VPS**：运行 VLESS 节点
- **NAT 出口机**：提供公网 IPv4 出口

请严格按顺序操作。

### 第 1 步：初始化 NAT 出口机

在 **NAT 出口机** 执行：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/nat.sh' -o /root/nat.sh && chmod 700 /root/nat.sh && bash /root/nat.sh init
```

初始化完成后会显示 NAT 公钥。

也可以随时查看：

```bash
cat /etc/wireguard/wg-exit.pub
```

如果脚本无法识别公网网卡，可以指定：

```bash
WAN_IF=eth0 bash /root/nat.sh init
```

### 第 2 步：在 VLESS VPS 运行 `vpswg.sh`

在 **VLESS VPS** 执行：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vpswg.sh' -o /root/vpswg.sh && chmod 700 /root/vpswg.sh && bash /root/vpswg.sh
```

脚本最后会显示 VPS WireGuard 公钥，并给出下一步 NAT 机命令格式。

也可以查看 VPS 公钥：

```bash
cat /etc/wireguard/wg-nat.pub
```

### 第 3 步：在 NAT 机添加这台 VPS

假设：

- 名称：`hy2`
- VPS 域名：`hy2.example.com`
- 已复制 VPS 公钥

在 **NAT 出口机** 执行：

```bash
bash /root/nat.sh add hy2 hy2.example.com '这里替换成VPS公钥'
```

不需要手工填写 `10.66.66.X/32`，NAT 机会自动分配地址。

同一个名称重新执行 `add` 时，会保留原来的 WG 地址，并更新域名、IP 或公钥。

成功后，NAT 机会打印一条完整的 VPS 回填命令。

### 第 4 步：回到 VPS 执行回填命令

把 NAT 机打印的完整命令原样复制到 **VLESS VPS** 执行，例如：

```bash
/usr/local/sbin/wg_nat_set_peer.sh '这里是NAT公钥' '10.66.66.1/24'
```

然后检查：

```bash
/usr/local/sbin/wg_nat_healthcheck.sh
```

正常结果末尾类似：

```text
OK EXIT_IP=x.x.x.x
```

没有出现 `OK EXIT_IP=` 时，不要继续创建 WG-NAT 临时节点。

### 第 5 步：安装 WG-NAT 临时节点功能

确认健康检查成功后，在 **VLESS VPS** 执行：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/natjichang.sh' -o /root/natjichang.sh && chmod 700 /root/natjichang.sh && bash /root/natjichang.sh
```

安装完成后可以使用：

```bash
vless_mktemp_nat.sh
```

---

## 九、创建 WG-NAT 临时节点

WG-NAT 临时节点的客户端仍连接 VLESS VPS，但出站公网 IP 是 NAT 机的公网 IPv4。

### 1. 自动选择端口

```bash
id=nat1h IP_VERSION=4 IP_LIMIT=3 PQ_GIB=1 D=3600 vless_mktemp_nat.sh
```

### 2. 固定端口 `40000`

```bash
id=nat40000 IP_VERSION=4 PORT_START=40000 PORT_END=40000 IP_LIMIT=3 PQ_GIB=1 D=3600 vless_mktemp_nat.sh
```

### 3. IPv6 入站、NAT IPv4 出口

先确认主配置中已经填写：

```bash
PUBLIC_IPV6_DOMAIN=proxy6.example.com
```

然后执行：

```bash
id=nat6 IP_VERSION=6 IP_LIMIT=3 PQ_GIB=1 D=3600 vless_mktemp_nat.sh
```

普通使用不需要手工填写 `MARK=2333`。当前脚本会读取已经保存的 WG-NAT 配置。

WG-NAT 临时节点的查询链接、查看实时 IP、配额修改、IP 限制和删除方式，与普通临时节点完全相同。

---

## 十、WG-NAT 日常管理

### 在 NAT 出口机操作

查看已经添加的 VPS：

```bash
bash /root/nat.sh list
```

查看完整状态：

```bash
bash /root/nat.sh status
```

删除某台 VPS：

```bash
bash /root/nat.sh del hy2
```

更新某台 VPS 的域名、IP 或公钥：

```bash
bash /root/nat.sh add hy2 hy2.example.com '当前VPS公钥'
```

### 在 VLESS VPS 操作

检查 NAT 出口：

```bash
/usr/local/sbin/wg_nat_healthcheck.sh
```

查看所有 VLESS 节点：

```bash
vless_audit.sh
```

删除某个 WG-NAT 临时节点时，使用本文统一的“强制按端口删除临时节点”命令，不需要另一套删除方法。

### VPS 公网 IP 变化

修改 DNS A 记录后，在 NAT 机重新执行：

```bash
bash /root/nat.sh add hy2 hy2.example.com '原来的VPS公钥'
```

然后根据 NAT 机输出，必要时把新的回填命令复制到 VPS 执行。

### 增加第 2 台、第 3 台 VPS

每台新 VPS 都重复以下步骤：

1. 在新 VPS 运行 `vpswg.sh`。
2. 复制新 VPS 公钥。
3. 在 NAT 机执行新的 `nat.sh add`。
4. 把 NAT 机打印的命令复制回新 VPS执行。
5. 运行健康检查。
6. 需要 NAT 临时节点时，再运行 `natjichang.sh`。

示例：

```bash
bash /root/nat.sh add vless2 vless2.example.com '第2台VPS公钥'
```

NAT 机会自动分配下一可用 WG 地址，不需要自己记 `.3`、`.4`。

---

## 十一、更新脚本

### 1. 更新 VLESS 管理脚本

在 VLESS VPS 执行：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vless.sh' -o /root/vless.sh && chmod 700 /root/vless.sh && bash /root/vless.sh
```

这会刷新临时节点、配额和 IP 限制等管理命令。

需要同时更新 Xray 主程序或重新应用主配置时，再执行：

```bash
bash /root/onekey_reality_ipv4.sh
```

### 2. 更新 VLESS VPS 的 WG-NAT 脚本

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vpswg.sh' -o /root/vpswg.sh && chmod 700 /root/vpswg.sh && bash /root/vpswg.sh
```

当前脚本重复运行时会尽量保留已经使用的 WG 地址和 Peer 配置。

更新 NAT 临时节点模块：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/natjichang.sh' -o /root/natjichang.sh && chmod 700 /root/natjichang.sh && bash /root/natjichang.sh
```

### 3. 更新 NAT 出口机

更新前先备份：

```bash
TS=$(date +%F-%H%M%S); mkdir -p "/root/nat-backup-$TS"; cp -a /etc/wireguard "/root/nat-backup-$TS/" 2>/dev/null || true; cp -a /root/nat.sh "/root/nat-backup-$TS/" 2>/dev/null || true; echo "备份目录：/root/nat-backup-$TS"
```

然后更新：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/nat.sh' -o /root/nat.sh && chmod 700 /root/nat.sh && bash /root/nat.sh init
```

新版会继续使用已有 Peer 信息。以后新增 VPS 时使用三参数 `add` 写法即可。

> README 不再固定写死某个 SHA256。主分支更新后哈希会变化，固定写在教程里很容易变成过期信息。需要校验时，请以发布者当次提供的哈希为准。

---

## 十二、常见问题

### 1. 安装脚本提示不是 root、不是 systemd 或架构不支持

执行：

```bash
printf '当前用户：'; id -un; printf 'PID 1：'; ps -p 1 -o comm=; printf 'CPU 架构：'; uname -m
```

正常常见结果：

```text
当前用户：root
PID 1：systemd
CPU 架构：x86_64
```

`aarch64` 也属于常见支持架构。

### 2. 主节点提示域名未指向本机

```bash
getent ahostsv4 proxy.example.com
curl -4 https://api.ipify.org
```

两处公网 IPv4 应一致。

### 3. IPv6 临时节点创建失败

```bash
getent ahostsv6 proxy6.example.com
ip -6 addr show scope global
```

确认：

- 已填写 `PUBLIC_IPV6_DOMAIN`
- AAAA 记录正确
- VPS 有公网 IPv6
- 已放行临时节点 TCP 端口

### 4. 按端口查看临时节点日志

只修改最前面的 `PORT=40000`：

```bash
PORT=40000; mapfile -t files < <(grep -l "^PORT=${PORT}$" /var/lib/vless-reality/temp/*.env 2>/dev/null); [ "${#files[@]}" -eq 1 ] || { echo "无法唯一找到端口 ${PORT} 对应的临时节点" >&2; exit 1; }; TAG=${files[0]##*/}; TAG=${TAG%.env}; journalctl -u "${TAG}.service" -n 100 --no-pager
```

### 5. 按端口重启临时节点

只修改最前面的 `PORT=40000`：

```bash
PORT=40000; mapfile -t files < <(grep -l "^PORT=${PORT}$" /var/lib/vless-reality/temp/*.env 2>/dev/null); [ "${#files[@]}" -eq 1 ] || { echo "无法唯一找到端口 ${PORT} 对应的临时节点" >&2; exit 1; }; TAG=${files[0]##*/}; TAG=${TAG%.env}; systemctl restart "${TAG}.service" && vless_audit.sh --tag "$TAG"
```

### 6. 主节点异常

```bash
systemctl status xray.service
journalctl -u xray.service -n 120 --no-pager
```

### 7. WG-NAT 健康检查失败

先执行：

```bash
/usr/local/sbin/wg_nat_healthcheck.sh
```

然后确认：

- VLESS VPS 的 UDP `51820` 已放行
- NAT 机添加 VPS 时填写的域名或 IP 正确
- 两边公钥没有复制错误
- NAT 机可以访问 VPS

在 NAT 机查看：

```bash
bash /root/nat.sh status
```

必要时重新执行：

```bash
bash /root/nat.sh add hy2 hy2.example.com '当前VPS公钥'
```

再把新打印的回填命令复制到 VPS 执行。

### 8. 配额或 IP 限制状态异常

```bash
vless_restore_all.sh
vless_audit.sh
pq_audit.sh
```

---

## 十三、最短操作流程

### 只使用普通 VLESS

在 VLESS VPS 执行：

```bash
apt-get update && apt-get install -y curl ca-certificates && bash <(curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vless.sh')
nano /etc/default/vless-reality
bash /root/onekey_reality_ipv4.sh
```

创建 1 小时临时节点：

```bash
id=tmp1h IP_LIMIT=3 PQ_GIB=1 D=3600 vless_mktemp.sh
```

查看全部节点：

```bash
vless_audit.sh
```

查某端口链接、实时来源 IP 或删除节点，使用本文第四节的统一按端口命令。

### 使用 WG-NAT

NAT 出口机：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/nat.sh' -o /root/nat.sh && chmod 700 /root/nat.sh && bash /root/nat.sh init
```

VLESS VPS：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vpswg.sh' -o /root/vpswg.sh && chmod 700 /root/vpswg.sh && bash /root/vpswg.sh
```

NAT 出口机：

```bash
bash /root/nat.sh add hy2 hy2.example.com 'VPS公钥'
```

VLESS VPS：

```bash
# 原样执行 NAT 机打印的回填命令
/usr/local/sbin/wg_nat_healthcheck.sh
```

健康检查成功后安装 NAT 临时节点功能：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/natjichang.sh' -o /root/natjichang.sh && chmod 700 /root/natjichang.sh && bash /root/natjichang.sh
```

创建 1 小时 WG-NAT 临时节点：

```bash
id=nat1h IP_LIMIT=3 PQ_GIB=1 D=3600 vless_mktemp_nat.sh
```

---

## 项目链接

GitHub：

```text
https://github.com/liucong552-art/zuizhongheji
```

脚本直链：

```text
https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vless.sh
https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vpswg.sh
https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/nat.sh
https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/natjichang.sh
```

请仅在自己拥有或获得授权的服务器和网络环境中使用，并遵守所在地法律、服务商条款和网络使用规定。
