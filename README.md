# VLESS Reality + 临时节点 + WG-NAT 使用说明

仓库地址：

```text
https://github.com/liucong552-art/zuizhongheji
```

本说明面向直接使用脚本的用户，只介绍安装顺序、命令、参数和常见问题，不展开脚本内部实现。

仓库包含 4 个入口脚本：

| 脚本 | 运行位置 | 用途 |
|---|---|---|
| `vless.sh` | VLESS VPS | 安装 VLESS Reality 主节点和临时节点管理功能 |
| `vpswg.sh` | VLESS VPS | 让该 VPS 可以使用 NAT 出口机 |
| `nat.sh` | NAT 出口机 | 初始化 NAT 出口并管理接入的 VPS |
| `natjichang.sh` | VLESS VPS | 增加通过 NAT 机出站的临时节点功能 |

> `natjichang.sh` 应运行在 **VLESS VPS**，不是 NAT 出口机。

本说明对应的 `vless.sh` SHA256：

```text
2f6fb064f9ea57d4820cd597b9871d388289893803b3f22a116e9cf1043a7efa
```

下载后可以校验：

```bash
sha256sum /root/vless.sh
```

---

## 一、系统要求

支持：

- Debian 11 或更高版本
- Ubuntu 20.04 或更高版本
- `root` 用户
- systemd
- Bash 4.0+
- `x86_64 / amd64` 或 `aarch64 / arm64`

云服务器安全组或防火墙需要按用途放行：

- 主节点 TCP 端口，默认 `443`
- 临时节点 TCP 端口，默认范围 `40000-50050`
- 使用 WG-NAT 时，VLESS VPS 的 UDP `51820`

建议先确认：

```bash
id
ps -p 1 -o comm=
uname -m
```

---

## 二、安装 VLESS 主系统

以下命令都在 **VLESS VPS** 执行。

### 1. 下载并运行 `vless.sh`

```bash
apt-get update
apt-get install -y curl ca-certificates

curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vless.sh' -o /root/vless.sh

chmod 700 /root/vless.sh
sha256sum /root/vless.sh
bash /root/vless.sh
```

也可以直接运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vless.sh)
```

执行完成后即可配置主节点和创建临时节点。

### 2. 编辑主节点配置

```bash
nano /etc/default/vless-reality
```

示例：

```bash
PUBLIC_DOMAIN=proxy.example.com
PUBLIC_IPV6_DOMAIN=

CAMOUFLAGE_DOMAIN=www.apple.com
REALITY_DEST=www.apple.com:443
REALITY_SNI=www.apple.com

PORT=443
NODE_NAME=MY-VLESS
```

说明：

- `PUBLIC_DOMAIN` 必填。
- 该域名的 A 记录必须指向当前 VPS 的公网 IPv4。
- 主节点使用 IPv4。
- `PUBLIC_IPV6_DOMAIN` 仅在创建 IPv6 临时节点时需要。
- 使用 IPv6 临时节点时，该域名的 AAAA 记录必须指向当前 VPS 的公网 IPv6。

### 3. 创建或更新主节点

```bash
bash /root/onekey_reality_ipv4.sh
```

查看主节点链接：

```bash
cat /root/vless_reality_vision_url.txt
```

查看主节点 Base64 订阅：

```bash
cat /root/v2ray_subscription_base64.txt
```

### 4. 固定 Xray 版本

```bash
env XRAY_VERSION=vX.Y.Z bash /root/onekey_reality_ipv4.sh
```

示例：

```bash
env XRAY_VERSION=v26.1.23 bash /root/onekey_reality_ipv4.sh
```

不指定时使用脚本选择的版本。

### 5. 重新生成主节点凭据

正常重复运行会尽量保留原来的客户端凭据。

只有明确需要更换 UUID 和 Reality 密钥时才运行：

```bash
env ROTATE_CREDENTIALS=1 bash /root/onekey_reality_ipv4.sh
```

执行后旧客户端链接会失效。

---

## 三、创建普通临时节点

普通临时节点直接使用当前 VPS 的公网出口。

基本命令：

```bash
vless_mktemp.sh
```

常用参数：

| 参数 | 含义 | 默认值 |
|---|---|---|
| `id` | 节点名称 | 自动生成 |
| `D` | 有效期，单位秒，必填 | 无 |
| `IP_VERSION` | 入站类型，`4` 或 `6` | `4` |
| `PORT_START` | 端口范围起点 | `40000` |
| `PORT_END` | 端口范围终点 | `50050` |
| `IP_LIMIT` | 允许的活跃来源 IP 数量，`0` 表示不限制数量 | `0` |
| `IP_STICKY_SECONDS` | 来源 IP 槽位保持时间 | `120` |
| `PQ_GIB` | 双向总流量配额，单位 GiB | 不启用 |

不固定端口时，可以省略 `PORT_START` 和 `PORT_END`。

固定端口时，把二者设为同一个值。

下面的示例均为**单行命令**，请整行复制执行；`D` 直接填写秒数，避免换行和算术表达式造成粘贴错误。

### IPv4 临时节点

1 小时、最多 3 个来源 IP、总流量 1 GiB：

```bash
env id=tmp1h IP_VERSION=4 IP_LIMIT=3 PQ_GIB=1 D=3600 vless_mktemp.sh
```

固定使用端口 `40000`：

```bash
env id=tmp40000 IP_VERSION=4 PORT_START=40000 PORT_END=40000 IP_LIMIT=3 PQ_GIB=1 D=3600 vless_mktemp.sh
```

有效期 1 天、总流量 50 GiB：

```bash
env id=tmp1d IP_VERSION=4 IP_LIMIT=3 PQ_GIB=50 D=86400 vless_mktemp.sh
```

### IPv6 临时节点

先编辑：

```bash
nano /etc/default/vless-reality
```

填写：

```bash
PUBLIC_IPV6_DOMAIN=proxy6.example.com
```

确认 AAAA 记录指向 VPS 公网 IPv6，然后创建：

```bash
env id=tmp6 IP_VERSION=6 IP_LIMIT=3 PQ_GIB=1 D=3600 vless_mktemp.sh
```

同一个尚未到期的 `id` 不应重复创建。

---

## 四、按端口查看和管理节点

日常使用时，建议把**端口号**作为主要管理入口，不需要先查节点 TAG。

下面的命令都只需要修改开头的 `PORT=端口号`，然后整行复制执行。

### 查看全部节点

```bash
vless_audit.sh
```

### 按端口查询节点链接

同时支持主节点 `443` 和临时节点端口。把 `40001` 改成需要查询的端口：

```bash
PORT=40001; if [ "$PORT" = 443 ]; then cat /root/vless_reality_vision_url.txt; else file=$(grep -l "^PORT=${PORT}$" /var/lib/vless-reality/temp/*.env 2>/dev/null | head -n1); [ -n "$file" ] || { echo "未找到端口 ${PORT} 的节点" >&2; exit 1; }; url="${file%.env}.url"; [ -s "$url" ] || { echo "节点存在，但链接文件不存在：${url}" >&2; exit 1; }; cat "$url"; fi
```

例如查询端口 `40000`：

```bash
PORT=40000; if [ "$PORT" = 443 ]; then cat /root/vless_reality_vision_url.txt; else file=$(grep -l "^PORT=${PORT}$" /var/lib/vless-reality/temp/*.env 2>/dev/null | head -n1); [ -n "$file" ] || { echo "未找到端口 ${PORT} 的节点" >&2; exit 1; }; url="${file%.env}.url"; [ -s "$url" ] || { echo "节点存在，但链接文件不存在：${url}" >&2; exit 1; }; cat "$url"; fi
```

查询主节点链接：

```bash
PORT=443; if [ "$PORT" = 443 ]; then cat /root/vless_reality_vision_url.txt; else file=$(grep -l "^PORT=${PORT}$" /var/lib/vless-reality/temp/*.env 2>/dev/null | head -n1); [ -n "$file" ] || { echo "未找到端口 ${PORT} 的节点" >&2; exit 1; }; url="${file%.env}.url"; [ -s "$url" ] || { echo "节点存在，但链接文件不存在：${url}" >&2; exit 1; }; cat "$url"; fi
```

### 按端口查看指定临时节点

把 `40000` 改成需要查看的临时节点端口：

```bash
PORT=40000; file=$(grep -l "^PORT=${PORT}$" /var/lib/vless-reality/temp/*.env 2>/dev/null | head -n1); [ -n "$file" ] || { echo "没找到端口 ${PORT} 对应的临时节点" >&2; exit 1; }; TAG=${file##*/}; TAG=${TAG%.env}; echo "查看临时节点：PORT=${PORT}, TAG=${TAG}"; vless_audit.sh --tag "$TAG"
```

### 强制按端口删除临时节点

把 `40000` 改成需要删除的临时节点端口。该命令会先显示找到的端口和 TAG，再立即删除：

```bash
PORT=40000; file=$(grep -l "^PORT=${PORT}$" /var/lib/vless-reality/temp/*.env 2>/dev/null | head -n1); [ -n "$file" ] || { echo "没找到端口 ${PORT} 对应的临时节点" >&2; exit 1; }; TAG=${file##*/}; TAG=${TAG%.env}; echo "删除临时节点：PORT=${PORT}, TAG=${TAG}"; FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG"
```

该命令只查找 `/var/lib/vless-reality/temp/` 中的临时节点，不会删除主节点 `443`。

### 已知 TAG 时删除

只有已经明确知道 TAG 时，才需要使用下面的方式：

```bash
env FORCE=1 vless_cleanup_one.sh vless-temp-tmp1h
```

### 查看临时节点聚合订阅

RAW：

```bash
cat /root/vless_temp_subscription.txt
```

Base64：

```bash
cat /root/vless_temp_subscription_base64.txt
```

手动刷新聚合订阅：

```bash
vless_temp_sub.sh
```

### 清空全部临时节点

```bash
vless_clear_all.sh
```

该命令不会删除主节点。

---

## 五、流量配额

临时节点创建时可以直接使用：

```bash
PQ_GIB=50
```

也可以按端口设置或修改：

```bash
pq_add.sh 40000 50
```

表示端口 `40000` 的双向总流量配额为 `50 GiB`。

查看配额：

```bash
pq_audit.sh
```

删除配额：

```bash
pq_del.sh 40000
```

说明：

- 对临时节点端口执行 `pq_add.sh`，新配额会同步到该临时节点。
- 临时节点到期或被删除时，对应配额会一起清理。
- 手工执行 `pq_add.sh` 不会启用 30 天自动重置。
- `pq_del.sh` 只删除配额，不删除节点。

### 30 天自动重置

只有在创建临时节点时同时满足以下条件才会启用：

- 设置了 `PQ_GIB`
- `D` 严格大于 30 天

示例：

```bash
env id=tmp31d IP_LIMIT=1 PQ_GIB=100 D=2678400 vless_mktemp.sh
```

恰好 30 天不会启用自动重置：

```bash
D=2592000
```

---

## 六、来源 IP 数量限制

创建临时节点时可以直接设置：

```bash
IP_LIMIT=3
IP_STICKY_SECONDS=120
```

也可以按端口修改。

最多允许 1 个活跃来源 IP：

```bash
ip_set.sh 40005 1
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

- 对临时节点端口执行 `ip_set.sh`，新限制会同步到该临时节点。
- `ip_del.sh` 只删除来源 IP 数量限制，不删除节点。
- IPv4 临时节点仍只接受 IPv4，IPv6 临时节点仍只接受 IPv6。

---

## 七、自动维护

安装完成后，临时节点到期清理、配额保存、重启恢复和异常修复均由系统自动处理，正常使用时不需要手动管理相关服务或定时器。

遇到异常时可以运行：

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

WG-NAT 用于让 VLESS VPS 上创建的指定临时节点，通过另一台 NAT 机器的公网 IPv4 出口访问互联网。

需要两台机器：

- **VLESS VPS**：运行 VLESS 节点
- **NAT 出口机**：提供公网 IPv4 出口

请严格按照下面顺序操作。

### 第 1 步：初始化 NAT 出口机

以下命令在 **NAT 出口机** 执行：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/nat.sh' -o /root/nat.sh

chmod 700 /root/nat.sh
bash /root/nat.sh init
```

初始化成功后查看 NAT 机公钥：

```bash
cat /etc/wireguard/wg-exit.pub
```

如果脚本无法识别公网网卡，可以指定：

```bash
env WAN_IF=eth0 bash /root/nat.sh init
```

### 第 2 步：在 VLESS VPS 运行 `vpswg.sh`

以下命令在 **VLESS VPS** 执行：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vpswg.sh' -o /root/vpswg.sh

chmod 700 /root/vpswg.sh
bash /root/vpswg.sh
```

查看 VPS 公钥：

```bash
cat /etc/wireguard/wg-nat.pub
```

### 第 3 步：在 NAT 机添加 VPS

假设：

- 名称：`hy2`
- VPS 域名：`hy2.example.com`
- 已取得 VPS 公钥

在 **NAT 出口机** 执行：

```bash
bash /root/nat.sh add hy2 hy2.example.com '这里替换成VPS公钥'
```

执行成功后，NAT 机会打印一条需要在 VPS 上执行的完整命令。

### 第 4 步：回到 VPS 执行回填命令

把 NAT 机打印的命令原样复制到 **VLESS VPS** 执行，例如：

```bash
/usr/local/sbin/wg_nat_set_peer.sh '这里是NAT公钥' '10.66.66.1/24'
```

然后运行：

```bash
/usr/local/sbin/wg_nat_healthcheck.sh
```

正常结果末尾类似：

```text
OK EXIT_IP=x.x.x.x
```

如果没有出现 `OK EXIT_IP=`，先不要继续创建 NAT 临时节点。

### 第 5 步：安装 NAT 临时节点功能

以下命令在 **VLESS VPS** 执行：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/natjichang.sh' -o /root/natjichang.sh

chmod 700 /root/natjichang.sh
bash /root/natjichang.sh
```

完成后即可使用：

```bash
vless_mktemp_nat.sh
```

---

## 九、创建 WG-NAT 临时节点

WG-NAT 临时节点的客户端仍连接 VLESS VPS，但访问互联网时使用 NAT 机的公网 IPv4。

### IPv4 入站

1 小时、最多 3 个来源 IP、总流量 1 GiB：

```bash
env id=nat1h IP_VERSION=4 IP_LIMIT=3 PQ_GIB=1 D=3600 vless_mktemp_nat.sh
```

固定端口 `40000`：

```bash
env id=nat40000 IP_VERSION=4 PORT_START=40000 PORT_END=40000 IP_LIMIT=3 PQ_GIB=1 D=3600 vless_mktemp_nat.sh
```

### IPv6 入站、NAT IPv4 出口

先确认 `/etc/default/vless-reality` 中已经设置：

```bash
PUBLIC_IPV6_DOMAIN=proxy6.example.com
```

然后创建：

```bash
env id=nat6 IP_VERSION=6 IP_LIMIT=3 PQ_GIB=1 D=3600 vless_mktemp_nat.sh
```

常用参数与普通临时节点基本相同：

| 参数 | 含义 | 默认值 |
|---|---|---|
| `id` | 节点名称 | 自动生成 |
| `D` | 有效期，单位秒，必填 | 无 |
| `IP_VERSION` | 入站类型，`4` 或 `6` | `4` |
| `PORT_START` | 端口范围起点 | `40000` |
| `PORT_END` | 端口范围终点 | `50050` |
| `IP_LIMIT` | 活跃来源 IP 数量 | `0` |
| `IP_STICKY_SECONDS` | IP 槽位保持时间 | `120` |
| `PQ_GIB` | 双向总流量配额 | 不启用 |

---

## 十、WG-NAT 日常管理

### 在 NAT 出口机操作

查看已添加的 VPS：

```bash
bash /root/nat.sh list
```

查看状态：

```bash
bash /root/nat.sh status
```

删除某台 VPS：

```bash
bash /root/nat.sh del hy2
```

更新 VPS 域名、IP 或公钥：

```bash
bash /root/nat.sh add hy2 hy2.example.com '当前VPS公钥'
```

同一个名称重新执行 `add`，会更新现有记录。

### 在 VLESS VPS 操作

检查 NAT 出口是否正常：

```bash
/usr/local/sbin/wg_nat_healthcheck.sh
```

查看所有 VLESS 节点：

```bash
vless_audit.sh
```

删除 NAT 临时节点时也建议直接按端口操作。把 `40000` 改成实际端口：

```bash
PORT=40000; file=$(grep -l "^PORT=${PORT}$" /var/lib/vless-reality/temp/*.env 2>/dev/null | head -n1); [ -n "$file" ] || { echo "没找到端口 ${PORT} 对应的临时节点" >&2; exit 1; }; TAG=${file##*/}; TAG=${TAG%.env}; echo "删除临时节点：PORT=${PORT}, TAG=${TAG}"; FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG"
```

---

## 十一、增加更多 VLESS VPS

每台新 VPS 都按以下步骤操作：

1. 在新 VPS 运行 `vless.sh` 并创建主节点。
2. 在新 VPS 运行 `vpswg.sh`。
3. 复制新 VPS 的 WireGuard 公钥。
4. 在 NAT 机执行一次新的 `nat.sh add`。
5. 把 NAT 机打印的命令复制回新 VPS 执行。
6. 在新 VPS 运行健康检查。
7. 需要 NAT 临时节点时，再运行 `natjichang.sh`。

示例：

```bash
bash /root/nat.sh add vless2 vless2.example.com '第2台VPS公钥'
```

---

## 十二、更新脚本

### 更新 VLESS VPS

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vless.sh' -o /root/vless.sh

curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vpswg.sh' -o /root/vpswg.sh

curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/natjichang.sh' -o /root/natjichang.sh

chmod 700 /root/vless.sh /root/vpswg.sh /root/natjichang.sh

bash /root/vless.sh
bash /root/vpswg.sh
bash /root/natjichang.sh
```

需要更新主节点程序时再运行：

```bash
bash /root/onekey_reality_ipv4.sh
```

### 更新 NAT 出口机

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/nat.sh' -o /root/nat.sh

chmod 700 /root/nat.sh
bash /root/nat.sh init
```

更新前建议备份 `/etc/wireguard`。

---

## 十三、常见问题

### 1. 主节点提示域名未指向本机

```bash
getent ahostsv4 proxy.example.com
curl -4 https://api.ipify.org
```

两处显示的公网 IPv4 应匹配。

### 2. IPv6 临时节点创建失败

```bash
getent ahostsv6 proxy6.example.com
ip -6 addr show scope global
```

确认：

- 已填写 `PUBLIC_IPV6_DOMAIN`
- AAAA 记录正确
- VPS 有公网 IPv6
- 已放行临时节点 TCP 端口

### 3. WG-NAT 健康检查失败

先运行：

```bash
/usr/local/sbin/wg_nat_healthcheck.sh
```

然后确认：

- VPS 的 UDP `51820` 已放行
- NAT 机添加 VPS 时填写的域名或 IP 正确
- 两边复制的公钥正确
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

### 4. 临时节点异常

```bash
vless_audit.sh
systemctl status vless-temp-节点ID.service
journalctl -u vless-temp-节点ID.service -n 100 --no-pager
```

### 5. 主节点异常

```bash
systemctl status xray.service
journalctl -u xray.service -n 120 --no-pager
```

### 6. 配额或 IP 限制状态异常

```bash
vless_restore_all.sh
vless_audit.sh
pq_audit.sh
```

---

## 十四、最短操作流程

### 只使用普通 VLESS

在 VPS 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vless.sh)

nano /etc/default/vless-reality

bash /root/onekey_reality_ipv4.sh
```

创建 1 小时临时节点：

```bash
env id=tmp1h IP_LIMIT=3 PQ_GIB=1 D=3600 vless_mktemp.sh
```

查看全部节点：

```bash
vless_audit.sh
```

按端口查询链接，例如端口 `40000`：

```bash
PORT=40000; if [ "$PORT" = 443 ]; then cat /root/vless_reality_vision_url.txt; else file=$(grep -l "^PORT=${PORT}$" /var/lib/vless-reality/temp/*.env 2>/dev/null | head -n1); [ -n "$file" ] || { echo "未找到端口 ${PORT} 的节点" >&2; exit 1; }; url="${file%.env}.url"; [ -s "$url" ] || { echo "节点存在，但链接文件不存在：${url}" >&2; exit 1; }; cat "$url"; fi
```

按端口强制删除，例如端口 `40000`：

```bash
PORT=40000; file=$(grep -l "^PORT=${PORT}$" /var/lib/vless-reality/temp/*.env 2>/dev/null | head -n1); [ -n "$file" ] || { echo "没找到端口 ${PORT} 对应的临时节点" >&2; exit 1; }; TAG=${file##*/}; TAG=${TAG%.env}; echo "删除临时节点：PORT=${PORT}, TAG=${TAG}"; FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG"
```

### 使用 WG-NAT

在 NAT 机执行：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/nat.sh' -o /root/nat.sh
chmod 700 /root/nat.sh
bash /root/nat.sh init
```

在 VLESS VPS 执行：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/vpswg.sh' -o /root/vpswg.sh
chmod 700 /root/vpswg.sh
bash /root/vpswg.sh
```

回到 NAT 机：

```bash
bash /root/nat.sh add hy2 hy2.example.com 'VPS公钥'
```

回到 VLESS VPS：

```bash
# 原样执行 NAT 机打印的回填命令
/usr/local/sbin/wg_nat_healthcheck.sh
```

安装 NAT 临时节点功能：

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/natjichang.sh' -o /root/natjichang.sh
chmod 700 /root/natjichang.sh
bash /root/natjichang.sh
```

创建 1 小时 NAT 临时节点：

```bash
env id=nat1h IP_LIMIT=3 PQ_GIB=1 D=3600 vless_mktemp_nat.sh
```

查看：

```bash
vless_audit.sh
/usr/local/sbin/wg_nat_healthcheck.sh
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

请仅在自己拥有或获得授权的服务器和网络环境中使用，并遵守所在地法律、服务商条款及网络使用规定。
