# VLESS Reality 临时节点与 WG-NAT

面向使用者的安装与日常管理说明。项目包含主 VLESS Reality 节点、普通临时节点、流量/IP 限制，以及可选的 WG-NAT 出口。

| 脚本 | 运行位置 | 用途 |
|---|---|---|
| `vless.sh` | VLESS VPS | 安装主节点与普通临时节点管理工具 |
| `vpswg.sh` | VLESS VPS | 配置 WG-NAT 的 VPS 端 |
| `nat.sh` | NAT 出口机 | 配置并管理 NAT 出口 |
| `natjichang.sh` | VLESS VPS | 安装 WG-NAT 临时节点工具 |

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

临时节点删除或到期时，绑定的配额和 IP 限制会一起清理。

创建时设置了 `PQ_GIB` 且有效期严格大于 30 天，配额会每 30 天自动重置。

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
