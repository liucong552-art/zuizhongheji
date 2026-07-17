#!/usr/bin/env bash
# Final four-file edition: WireGuard NAT exit-host manager.
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
umask 077

# NAT 机（出网机）侧：作为 WG 出口，接收来自 VPS 的流量并 MASQUERADE 出网
#
# 目标：支持多台 VPS 共用一台 NAT 机
# 仍然保持：
#   - 开启 IPv4 转发
#   - 配置 iptables FORWARD
#   - 配置 iptables MASQUERADE
#   - 使用 wg-quick@wg-exit
#
# 用法：
#   bash nat.sh init
#   bash nat.sh add <name> <VPS_IP或域名> '<VPS_WG_PUBLIC_KEY>'
#   # VPS_WG_ADDR 由 NAT 机自动分配；旧四参数写法仍兼容
#   bash nat.sh del <name>
#   bash nat.sh list
#   bash nat.sh status
#
# 可覆盖参数（环境变量）：
DEFAULT_WG_IF="wg-exit"
DEFAULT_WG_PORT="51820"
DEFAULT_WG_ADDR="10.66.66.2/24"
DEFAULT_PERSISTENT_KEEPALIVE="25"

WG_PORT_EXPLICIT="${WG_PORT+x}"
WG_ADDR_EXPLICIT="${WG_ADDR+x}"
PERSISTENT_KEEPALIVE_EXPLICIT="${PERSISTENT_KEEPALIVE+x}"
WAN_IF_EXPLICIT="${WAN_IF+x}"
WG_IF="${WG_IF:-$DEFAULT_WG_IF}"
WG_PORT="${WG_PORT:-$DEFAULT_WG_PORT}"
WG_ADDR="${WG_ADDR:-$DEFAULT_WG_ADDR}"
PERSISTENT_KEEPALIVE="${PERSISTENT_KEEPALIVE:-$DEFAULT_PERSISTENT_KEEPALIVE}"
WAN_IF="${WAN_IF:-}"

# 平台兼容策略：只设置最低版本，不限制最高版本，后续 Debian/Ubuntu
# 发布新版本时无需因 codename 变化而修改脚本。
MIN_DEBIAN_MAJOR="${MIN_DEBIAN_MAJOR:-11}"
MIN_UBUNTU_VERSION="${MIN_UBUNTU_VERSION:-20.04}"
ALLOW_UNSUPPORTED_OS="${ALLOW_UNSUPPORTED_OS:-0}"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
OS_ID=""
OS_ID_LIKE=""
OS_VERSION_ID=""
OS_PRETTY_NAME=""

WG_DIR="/etc/wireguard"
CONF_FILE="${WG_DIR}/${WG_IF}.conf"
KEY_FILE="${WG_DIR}/${WG_IF}.key"
PUB_FILE="${WG_DIR}/${WG_IF}.pub"
STATE_FILE="${WG_DIR}/${WG_IF}.env"
PEER_DIR="${WG_DIR}/${WG_IF}-peers.d"
FIREWALL_SCRIPT="/usr/local/sbin/wg_exit_firewall.sh"
FIREWALL_SERVICE="/etc/systemd/system/wg-exit-firewall@.service"
FIREWALL_TIMER="/etc/systemd/system/wg-exit-firewall@.timer"
SYSCTL_FILE="/etc/sysctl.d/99-wg-exit.conf"

TX_ACTIVE=0
TX_DIR=""
TX_OLD_WG_ACTIVE=0
TX_OLD_WG_ENABLED=""
TX_OLD_TIMER_ACTIVE=0
TX_OLD_TIMER_ENABLED=""
TX_TEMPS=()

fail(){ echo "❌ $*" >&2; exit 1; }
warn(){ echo "⚠️  $*" >&2; }
need_root(){ [[ ${EUID:-0} -eq 0 ]] || fail "请用 root 运行"; }

load_os_release(){
  local release_file="$OS_RELEASE_FILE"
  local ID="" ID_LIKE="" VERSION_ID="" PRETTY_NAME=""

  if [[ ! -r "$release_file" && "$release_file" == "/etc/os-release" && -r /usr/lib/os-release ]]; then
    release_file="/usr/lib/os-release"
  fi
  [[ -r "$release_file" ]] || fail "无法读取 os-release：${release_file}"

  # shellcheck disable=SC1090
  . "$release_file"
  OS_ID="${ID,,}"
  OS_ID_LIKE="${ID_LIKE,,}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_PRETTY_NAME="${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-}}"
}

version_ge(){
  dpkg --compare-versions "$1" ge "$2"
}

require_supported_platform(){
  local major

  need_root
  (( BASH_VERSINFO[0] >= 4 )) || fail "需要 Bash 4.0 或更高版本"
  command -v dpkg >/dev/null 2>&1 || fail "缺少 dpkg；本脚本仅支持 Debian/Ubuntu 系列"
  load_os_release

  case "$OS_ID" in
    debian)
      major="${OS_VERSION_ID%%.*}"
      [[ "$major" =~ ^[0-9]+$ ]] || fail "无法识别 Debian 版本：${OS_PRETTY_NAME}"
      (( major >= MIN_DEBIAN_MAJOR )) \
        || fail "需要 Debian ${MIN_DEBIAN_MAJOR} 或更高版本；当前：${OS_PRETTY_NAME}"
      ;;
    ubuntu)
      [[ -n "$OS_VERSION_ID" ]] || fail "无法识别 Ubuntu 版本：${OS_PRETTY_NAME}"
      version_ge "$OS_VERSION_ID" "$MIN_UBUNTU_VERSION" \
        || fail "需要 Ubuntu ${MIN_UBUNTU_VERSION} 或更高版本；当前：${OS_PRETTY_NAME}"
      ;;
    *)
      if [[ "$ALLOW_UNSUPPORTED_OS" == "1" && " ${OS_ID_LIKE} " == *" debian "* ]]; then
        warn "以兼容模式运行未经验证的 Debian 衍生系统：${OS_PRETTY_NAME}"
      else
        fail "仅支持 Debian ${MIN_DEBIAN_MAJOR}+ 与 Ubuntu ${MIN_UBUNTU_VERSION}+；当前：${OS_PRETTY_NAME}。Debian 衍生系统可显式设置 ALLOW_UNSUPPORTED_OS=1 尝试运行"
      fi
      ;;
  esac

  command -v apt-get >/dev/null 2>&1 || fail "缺少 apt-get"
  command -v systemctl >/dev/null 2>&1 || fail "缺少 systemctl"
  [[ -d /run/systemd/system ]] \
    || fail "当前环境不是由 systemd 启动；wg-quick 服务无法管理（容器内请在宿主机运行）"

  echo "==> 系统兼容检查通过：${OS_PRETTY_NAME}"
}

ts(){ date +%F_%H%M%S; }
trim(){
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

usage(){
  cat <<EOF_USAGE
用法：
  bash $0 init
  bash $0 add <name> <VPS_IP或域名> '<VPS_WG_PUBLIC_KEY>'
  bash $0 del <name>
  bash $0 list
  bash $0 status

说明：
  - add 时不再需要填写 10.66.66.X/32。
  - NAT 机会自动选择当前网段内最小可用地址。
  - 默认顺序为：10.66.66.1、10.66.66.3、10.66.66.4……
    （10.66.66.2 是 NAT 机自身地址，会自动跳过。）
  - 对同一个 name 再次执行 add，会保留原来的 WG 地址，仅更新 Endpoint/公钥。
  - 旧写法仍兼容：
    bash $0 add <name> <VPS_IP或域名> <VPS_WG_ADDR> '<VPS_WG_PUBLIC_KEY>'

示例：
  bash $0 init
  bash $0 add vps-1 1.2.3.4 'PUBLIC_KEY'
  bash $0 add vps-2 hk.example.com 'PUBLIC_KEY'
  bash $0 del vps-1
  bash $0 list
  bash $0 status
EOF_USAGE
}

install_dirs(){
  install -d -m 700 "$WG_DIR"
  install -d -m 700 "$PEER_DIR"
}

apt_install_with_universe_retry(){
  local -a packages=("$@")
  if apt-get install -y --no-install-recommends "${packages[@]}" >/dev/null; then
    return 0
  fi

  if [[ "$OS_ID" == "ubuntu" ]]; then
    warn "首次依赖安装失败，尝试启用 Ubuntu Universe 后重试..."
    apt-get install -y --no-install-recommends software-properties-common >/dev/null 2>&1 || true
    if command -v add-apt-repository >/dev/null 2>&1; then
      add-apt-repository -y universe >/dev/null 2>&1 || true
      apt-get update -o Acquire::Retries=3 >/dev/null \
        || fail "启用 Universe 后 apt-get update 仍失败"
      apt-get install -y --no-install-recommends "${packages[@]}" >/dev/null && return 0
    fi
  fi

  fail "依赖安装失败；请检查软件源、网络以及 Ubuntu Universe 是否已启用"
}

need_packages(){
  local wg_package="wireguard-tools"
  export DEBIAN_FRONTEND=noninteractive
  echo "==> 安装依赖（${wg_package} / iproute2 / iptables / curl / procps）..."
  apt-get update -o Acquire::Retries=3 >/dev/null \
    || fail "apt-get update 失败；请检查 ${OS_PRETTY_NAME} 的软件源"
  apt_install_with_universe_retry \
    "$wg_package" iproute2 iptables curl ca-certificates procps kmod findutils util-linux coreutils

  local cmd
  for cmd in wg wg-quick ip iptables curl sysctl modprobe find flock timeout sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || fail "依赖安装后仍缺少命令：${cmd}"
  done
}

require_wireguard_kernel(){
  if modprobe wireguard >/dev/null 2>&1 || [[ -d /sys/module/wireguard ]]; then
    return 0
  fi
  fail "当前内核没有可用的 WireGuard 模块；请安装发行版支持的内核/WireGuard DKMS 后重试"
}

validate_name(){
  local name="$1"
  [[ -n "$name" ]] || fail "name 不能为空"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "name 非法：仅允许字母、数字、点、下划线、连字符"
}

validate_ifname(){
  local value="$1" label="${2:-接口名}"
  [[ -n "$value" ]] || fail "${label} 不能为空"
  (( ${#value} <= 15 )) || fail "${label} 过长（Linux 接口名最多 15 字符）：${value}"
  [[ "$value" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "${label} 非法：${value}"
  [[ "$value" != "." && "$value" != ".." ]] || fail "${label} 非法：${value}"
}

validate_uint_range(){
  local value="$1" min="$2" max="$3" label="$4"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "${label} 必须是整数：${value}"
  (( value >= min && value <= max )) || fail "${label} 必须在 ${min}-${max}：${value}"
}

validate_ipv4(){
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.
  local a b c d
  read -r a b c d <<<"$ip"
  for n in "$a" "$b" "$c" "$d"; do
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    (( n >= 0 && n <= 255 )) || return 1
  done
  return 0
}

validate_runtime_parameters(){
  local ip mask
  validate_ifname "$WG_IF" "WG_IF"
  validate_uint_range "$WG_PORT" 1 65535 "WG_PORT"
  validate_uint_range "$PERSISTENT_KEEPALIVE" 0 65535 "PERSISTENT_KEEPALIVE"

  [[ "$WG_ADDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] \
    || fail "WG_ADDR 格式不正确：${WG_ADDR}"
  ip="${WG_ADDR%/*}"
  mask="${WG_ADDR#*/}"
  validate_ipv4 "$ip" || fail "WG_ADDR 中的 IPv4 不合法：${WG_ADDR}"
  [[ "$mask" == "24" ]] || fail "当前自动地址分配要求 WG_ADDR 使用 /24：${WG_ADDR}"
  if [[ -n "$WAN_IF" ]]; then
    validate_ifname "$WAN_IF" "WAN_IF"
  fi
}

validate_wan_interface_runtime(){
  validate_ifname "$WAN_IF" "WAN_IF"
  ip link show dev "$WAN_IF" >/dev/null 2>&1 || fail "WAN_IF 不存在：${WAN_IF}"
}

tx_key(){
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

tx_restore_enabled(){
  local unit="$1" state="$2"
  systemctl disable "$unit" >/dev/null 2>&1 || true
  systemctl unmask "$unit" >/dev/null 2>&1 || true
  case "$state" in
    enabled) systemctl enable "$unit" >/dev/null 2>&1 || true ;;
    enabled-runtime) systemctl enable --runtime "$unit" >/dev/null 2>&1 || true ;;
    masked) systemctl mask "$unit" >/dev/null 2>&1 || true ;;
    masked-runtime) systemctl mask --runtime "$unit" >/dev/null 2>&1 || true ;;
  esac
}

tx_register_temp(){
  TX_TEMPS+=("$1")
}

stop_current_wg_for_rollback(){
  timeout 30 systemctl stop "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  if ip link show dev "$WG_IF" >/dev/null 2>&1; then
    timeout 20 wg-quick down "$WG_IF" >/dev/null 2>&1 || true
  fi
  if ip link show dev "$WG_IF" >/dev/null 2>&1; then
    ip link delete dev "$WG_IF" >/dev/null 2>&1 || true
  fi
}

cleanup_owned_firewall(){
  local suffix nat_chain fwd_chain owner
  suffix="${WG_IF//[^A-Za-z0-9]/_}"
  suffix="${suffix^^}"
  nat_chain="VRN_${suffix}"
  fwd_chain="VRF_${suffix}"
  owner="vr-wg:${WG_IF}"
  while iptables -w 5 -t nat -D POSTROUTING -m comment --comment "$owner" -j "$nat_chain" >/dev/null 2>&1; do :; done
  while iptables -w 5 -D FORWARD -m comment --comment "$owner" -j "$fwd_chain" >/dev/null 2>&1; do :; done
  iptables -w 5 -t nat -F "$nat_chain" >/dev/null 2>&1 || true
  iptables -w 5 -t nat -X "$nat_chain" >/dev/null 2>&1 || true
  iptables -w 5 -F "$fwd_chain" >/dev/null 2>&1 || true
  iptables -w 5 -X "$fwd_chain" >/dev/null 2>&1 || true
}

tx_begin(){
  local path key
  TX_DIR="$(mktemp -d /var/tmp/vr-nat-transaction.XXXXXX)"
  TX_TARGETS=(
    "$CONF_FILE" "$KEY_FILE" "$PUB_FILE" "$STATE_FILE" "$FIREWALL_SCRIPT"
    "$FIREWALL_SERVICE" "$FIREWALL_TIMER" "$SYSCTL_FILE"
  )
  for path in "${TX_TARGETS[@]}"; do
    key="$(tx_key "$path")"
    if [[ -e "$path" || -L "$path" ]]; then
      cp -a -- "$path" "${TX_DIR}/${key}"
      : >"${TX_DIR}/${key}.present"
    fi
  done
  if [[ -d "$PEER_DIR" ]]; then
    cp -a -- "$PEER_DIR" "${TX_DIR}/peer-dir"
    : >"${TX_DIR}/peer-dir.present"
  fi
  TX_OLD_WG_ENABLED="$(systemctl is-enabled "wg-quick@${WG_IF}" 2>/dev/null || true)"
  systemctl is-active --quiet "wg-quick@${WG_IF}" 2>/dev/null && TX_OLD_WG_ACTIVE=1 || true
  TX_OLD_TIMER_ENABLED="$(systemctl is-enabled "wg-exit-firewall@${WG_IF}.timer" 2>/dev/null || true)"
  systemctl is-active --quiet "wg-exit-firewall@${WG_IF}.timer" 2>/dev/null && TX_OLD_TIMER_ACTIVE=1 || true
  TX_OLD_IP_FORWARD="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)"
  TX_OLD_RP_ALL="$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || true)"
  TX_OLD_RP_DEFAULT="$(sysctl -n net.ipv4.conf.default.rp_filter 2>/dev/null || true)"
  TX_ACTIVE=1
}

tx_rollback(){
  (( TX_ACTIVE == 1 )) || return 0
  TX_ACTIVE=0
  set +e
  trap '' INT TERM HUP
  echo "↩ 正在回滚 NAT WireGuard 事务..." >&2
  local path key temp old_firewall_ok=0
  for temp in "${TX_TEMPS[@]}"; do
    [[ -n "$temp" ]] && rm -f -- "$temp"
  done
  timeout 20 systemctl stop "wg-exit-firewall@${WG_IF}.timer" >/dev/null 2>&1 || true
  stop_current_wg_for_rollback
  cleanup_owned_firewall

  for path in "${TX_TARGETS[@]}"; do
    key="$(tx_key "$path")"
    rm -f -- "$path"
    if [[ -f "${TX_DIR}/${key}.present" ]]; then
      install -d -m 755 "$(dirname "$path")"
      cp -a -- "${TX_DIR}/${key}" "$path"
    fi
  done
  rm -rf -- "$PEER_DIR"
  if [[ -f "${TX_DIR}/peer-dir.present" ]]; then
    cp -a -- "${TX_DIR}/peer-dir" "$PEER_DIR"
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
  tx_restore_enabled "wg-quick@${WG_IF}" "$TX_OLD_WG_ENABLED"
  tx_restore_enabled "wg-exit-firewall@${WG_IF}.timer" "$TX_OLD_TIMER_ENABLED"
  if [[ -x "$FIREWALL_SCRIPT" && -f "$STATE_FILE" ]] \
    && "$FIREWALL_SCRIPT" --manager "$WG_IF" >/dev/null 2>&1
  then
    old_firewall_ok=1
  fi
  if (( TX_OLD_WG_ACTIVE == 1 )) && [[ -f "$CONF_FILE" ]]; then
    systemctl start "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  else
    systemctl stop "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  fi
  if (( TX_OLD_TIMER_ACTIVE == 1 )); then
    systemctl start "wg-exit-firewall@${WG_IF}.timer" >/dev/null 2>&1 || true
  else
    systemctl stop "wg-exit-firewall@${WG_IF}.timer" >/dev/null 2>&1 || true
  fi
  if (( old_firewall_ok == 0 )) && [[ ! -f "$STATE_FILE" ]]; then
    [[ -n "$TX_OLD_IP_FORWARD" ]] && sysctl -w "net.ipv4.ip_forward=${TX_OLD_IP_FORWARD}" >/dev/null 2>&1 || true
    [[ -n "$TX_OLD_RP_ALL" ]] && sysctl -w "net.ipv4.conf.all.rp_filter=${TX_OLD_RP_ALL}" >/dev/null 2>&1 || true
    [[ -n "$TX_OLD_RP_DEFAULT" ]] && sysctl -w "net.ipv4.conf.default.rp_filter=${TX_OLD_RP_DEFAULT}" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$TX_DIR"
  TX_DIR=""
  set -e
}

tx_commit(){
  TX_ACTIVE=0
  rm -rf -- "$TX_DIR"
  TX_DIR=""
  TX_TEMPS=()
}

tx_on_exit(){
  local rc=$?
  trap - EXIT ERR
  tx_rollback || true
  exit "$rc"
}

validate_domain_name(){
  local host="$1"
  [[ -n "$host" ]] || return 1
  (( ${#host} <= 253 )) || return 1
  [[ "$host" != .* && "$host" != *..* && "$host" != *. ]] || return 1
  [[ "$host" == *.* ]] || return 1
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  local IFS=. label
  read -r -a labels <<<"$host"
  for label in "${labels[@]}"; do
    [[ -n "$label" ]] || return 1
    (( ${#label} <= 63 )) || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
  return 0
}

resolve_endpoint_ipv4(){
  local endpoint="$1" ip
  if validate_ipv4 "$endpoint"; then
    printf '%s\n' "$endpoint"
    return 0
  fi
  while IFS= read -r ip; do
    validate_ipv4 "$ip" || continue
    printf '%s\n' "$ip"
    return 0
  done < <(getent ahostsv4 "$endpoint" 2>/dev/null | awk '{print $1}' | awk '!seen[$0]++')
  return 1
}

validate_vps_endpoint(){
  local endpoint="$1"
  if validate_ipv4 "$endpoint"; then
    return 0
  fi
  validate_domain_name "$endpoint" || fail "第二个参数必须是合法 IPv4 或域名：$endpoint"
  resolve_endpoint_ipv4 "$endpoint" >/dev/null || fail "域名当前无法解析到 IPv4：$endpoint"
}

validate_vps_wg_addr(){
  local addr="$1"
  [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] || fail "VPS_WG_ADDR 格式不正确：$addr（示例：10.66.66.1/32）"
  local ip="${addr%/*}"
  local mask="${addr#*/}"
  validate_ipv4 "$ip" || fail "VPS_WG_ADDR 里的 IP 不合法：$addr"
  [[ "$mask" =~ ^[0-9]+$ ]] || fail "VPS_WG_ADDR 掩码不合法：$addr"
  (( mask >= 0 && mask <= 32 )) || fail "VPS_WG_ADDR 掩码不合法：$addr"
  (( mask == 32 )) || fail "为避免多 Peer 路由冲突，VPS_WG_ADDR 必须使用 /32：$addr"
}

wg_prefix24(){
  local ip mask a b c d
  ip="${WG_ADDR%/*}"
  mask="${WG_ADDR#*/}"

  [[ "$mask" == "24" ]] || fail "自动分配地址目前要求 NAT 的 WG_ADDR 使用 /24；当前：${WG_ADDR}"
  validate_ipv4 "$ip" || fail "NAT 的 WG_ADDR 不合法：${WG_ADDR}"

  IFS=. read -r a b c d <<<"$ip"
  printf '%s.%s.%s\n' "$a" "$b" "$c"
}

auto_allocate_vps_wg_addr(){
  local name="$1"
  local file existing prefix nat_ip nat_host host candidate used used_file used_addr

  file="$(peer_file "$name")"

  # 更新现有 name 时保留原地址，避免 Endpoint/IP 变化导致 VPS 侧地址也变化。
  if [[ -f "$file" ]]; then
    existing="$(peer_meta_value "$file" vps_wg_addr)"
    if [[ -n "$existing" ]]; then
      validate_vps_wg_addr "$existing"
      printf '%s\n' "$existing"
      return 0
    fi
  fi

  prefix="$(wg_prefix24)"
  nat_ip="${WG_ADDR%/*}"
  nat_host="${nat_ip##*.}"

  for ((host=1; host<=254; host++)); do
    (( host == nat_host )) && continue
    candidate="${prefix}.${host}/32"
    used=0

    while IFS= read -r used_file; do
      used_addr="$(peer_meta_value "$used_file" vps_wg_addr)"
      if [[ "$used_addr" == "$candidate" ]]; then
        used=1
        break
      fi
    done < <(find "$PEER_DIR" -maxdepth 1 -type f -name '*.peer' | LC_ALL=C sort)

    if (( used == 0 )); then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  fail "WG 地址池已满：${prefix}.1-${prefix}.254"
}

vps_interface_addr_from_peer_addr(){
  local peer_addr="$1"
  validate_vps_wg_addr "$peer_addr"
  printf '%s/24\n' "${peer_addr%/*}"
}

clean_pubkey(){
  local key="$1"
  key="${key//[[:space:]]/}"
  key="${key//\"/}"
  key="${key#<}"
  key="${key%>}"
  printf '%s' "$key"
}

validate_pubkey(){
  local key="$1"
  [[ -n "$key" ]] || fail "VPS_WG_PUBLIC_KEY 不能为空"
  [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    || fail "VPS_WG_PUBLIC_KEY 不是合法的 WireGuard 公钥：${key}"
}

peer_file(){
  local name="$1"
  printf '%s/%s.peer\n' "$PEER_DIR" "$name"
}

peer_meta_value(){
  local file="$1" key="$2"
  sed -n "s/^# ${key}: //p" "$file" | head -n1
}

peer_field_value(){
  local file="$1" key="$2"
  awk -F '=' -v k="$key" '
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      sub(/^[^=]*=/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$file"
}

render_wg_conf(){
  local out="$1"
  local nat_priv peer

  [[ -f "$KEY_FILE" ]] || fail "缺少 ${KEY_FILE}，请先执行：bash $0 init"
  nat_priv="$(cat "$KEY_FILE")"

  cat >"$out" <<CFG
[Interface]
Address = ${WG_ADDR}
PrivateKey = ${nat_priv}

# 规则由幂等 helper 和 watchdog 维护；manager 模式复用当前管理锁，避免 PostUp 自锁。
PostUp = /usr/local/sbin/wg_exit_firewall.sh --manager %i
CFG

  if [[ -d "$PEER_DIR" ]]; then
    while IFS= read -r peer; do
      printf '\n' >>"$out"
      cat "$peer" >>"$out"
    done < <(find "$PEER_DIR" -maxdepth 1 -type f -name '*.peer' | LC_ALL=C sort)
  fi

  chmod 600 "$out"
}

cleanup_legacy_firewall_rules_if_needed(){
  local backup tries
  [[ -f "$CONF_FILE" ]] || return 0
  grep -Eq "PostUp = iptables( -w [0-9]+)? -t nat -C POSTROUTING -o ${WAN_IF} -j MASQUERADE" "$CONF_FILE" \
    || return 0

  warn "检测到旧版无归属的宽泛 iptables 规则，迁移为专属 chain"
  if command -v iptables-save >/dev/null 2>&1; then
    backup="/root/iptables-before-${WG_IF}-migration-$(ts).rules"
    iptables-save >"$backup" 2>/dev/null || true
    [[ -s "$backup" ]] && echo "✅ 迁移前 iptables 快照：${backup}"
  fi

  tries=0
  while (( tries < 32 )) && iptables -w 5 -D FORWARD -i "$WG_IF" -o "$WAN_IF" -j ACCEPT >/dev/null 2>&1; do
    tries=$((tries + 1))
  done
  tries=0
  while (( tries < 32 )) && iptables -w 5 -D FORWARD -i "$WAN_IF" -o "$WG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1; do
    tries=$((tries + 1))
  done
  tries=0
  while (( tries < 32 )) && iptables -w 5 -t nat -D POSTROUTING -o "$WAN_IF" -j MASQUERADE >/dev/null 2>&1; do
    tries=$((tries + 1))
  done
}

save_state(){
  local tmp
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
  tx_register_temp "$tmp"
  cat >"$tmp" <<EOF_STATE
WG_PORT=${WG_PORT}
WG_ADDR=${WG_ADDR}
PERSISTENT_KEEPALIVE=${PERSISTENT_KEEPALIVE}
WAN_IF=${WAN_IF}
EOF_STATE
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

load_state(){
  local key value mode
  [[ -f "$STATE_FILE" ]] || return 1
  [[ "$(stat -c %u "$STATE_FILE" 2>/dev/null || echo -1)" == "0" ]] \
    || fail "状态文件不是 root 所有：${STATE_FILE}"
  mode="$(stat -c %a "$STATE_FILE" 2>/dev/null || echo 777)"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || fail "无法识别状态文件权限：${STATE_FILE}"
  (( ((8#$mode) & 8#022) == 0 )) \
    || fail "状态文件不能被 group/other 写入：${STATE_FILE}"

  while IFS='=' read -r key value; do
    case "$key" in
      WG_PORT) WG_PORT="$value" ;;
      WG_ADDR) WG_ADDR="$value" ;;
      PERSISTENT_KEEPALIVE) PERSISTENT_KEEPALIVE="$value" ;;
      WAN_IF) WAN_IF="$value" ;;
    esac
  done <"$STATE_FILE"
  validate_runtime_parameters
  return 0
}

merge_saved_state_if_exists(){
  local saved_wg_port="" saved_wg_addr="" saved_keepalive="" saved_wan_if=""

  [[ -f "$STATE_FILE" ]] || return 0

  saved_wg_port="$(sed -n 's/^WG_PORT=//p' "$STATE_FILE" | head -n1)"
  saved_wg_addr="$(sed -n 's/^WG_ADDR=//p' "$STATE_FILE" | head -n1)"
  saved_keepalive="$(sed -n 's/^PERSISTENT_KEEPALIVE=//p' "$STATE_FILE" | head -n1)"
  saved_wan_if="$(sed -n 's/^WAN_IF=//p' "$STATE_FILE" | head -n1)"

  saved_wg_port="$(trim "$saved_wg_port")"
  saved_wg_addr="$(trim "$saved_wg_addr")"
  saved_keepalive="$(trim "$saved_keepalive")"
  saved_wan_if="$(trim "$saved_wan_if")"

  if [[ -z "$WG_PORT_EXPLICIT" && -n "$saved_wg_port" ]]; then
    WG_PORT="$saved_wg_port"
  fi
  if [[ -z "$WG_ADDR_EXPLICIT" && -n "$saved_wg_addr" ]]; then
    WG_ADDR="$saved_wg_addr"
  fi
  if [[ -z "$PERSISTENT_KEEPALIVE_EXPLICIT" && -n "$saved_keepalive" ]]; then
    PERSISTENT_KEEPALIVE="$saved_keepalive"
  fi
  if [[ -z "$WAN_IF_EXPLICIT" && -n "$saved_wan_if" ]]; then
    WAN_IF="$saved_wan_if"
  fi
}

detect_wan_if(){
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev"){print $(i+1); exit}}' || true
}

ensure_nat_keys(){
  local nat_priv
  umask 077

  if [[ -f "$KEY_FILE" && -f "$PUB_FILE" ]]; then
    return 0
  fi

  if [[ ! -f "$KEY_FILE" && -f "$CONF_FILE" ]]; then
    nat_priv="$(sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' "$CONF_FILE" | head -n1)"
    nat_priv="$(trim "$nat_priv")"
    if [[ -n "$nat_priv" ]]; then
      printf '%s\n' "$nat_priv" >"$KEY_FILE"
      chmod 600 "$KEY_FILE"
    fi
  fi

  if [[ -f "$KEY_FILE" && ! -f "$PUB_FILE" ]]; then
    wg pubkey <"$KEY_FILE" >"$PUB_FILE"
    chmod 600 "$PUB_FILE"
    return 0
  fi

  if [[ ! -f "$KEY_FILE" ]]; then
    echo "==> 生成 NAT 机 WireGuard 密钥（${WG_IF}）..."
    wg genkey | tee "$KEY_FILE" | wg pubkey >"$PUB_FILE"
    chmod 600 "$KEY_FILE" "$PUB_FILE"
  fi
}

import_state_from_existing_conf(){
  local conf_addr conf_wan conf_port conf_keep

  [[ -f "$CONF_FILE" ]] || return 0

  conf_addr="$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$CONF_FILE" | head -n1)"
  conf_addr="$(trim "$conf_addr")"

  conf_wan="$(sed -n 's#^[[:space:]]*PostUp[[:space:]]*=[[:space:]]*iptables \(-w [0-9][0-9]* \)\?-C FORWARD -i %i -o \([^[:space:]]*\) -j ACCEPT.*$#\2#p' "$CONF_FILE" | head -n1)"
  conf_wan="$(trim "$conf_wan")"

  conf_port="$(sed -n 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*.*:\([0-9][0-9]*\)$/\1/p' "$CONF_FILE" | head -n1)"
  conf_port="$(trim "$conf_port")"

  conf_keep="$(sed -n 's/^[[:space:]]*PersistentKeepalive[[:space:]]*=[[:space:]]*//p' "$CONF_FILE" | head -n1)"
  conf_keep="$(trim "$conf_keep")"

  if [[ "$WG_ADDR" == "$DEFAULT_WG_ADDR" && -n "$conf_addr" ]]; then
    WG_ADDR="$conf_addr"
  fi
  if [[ "$WG_PORT" == "$DEFAULT_WG_PORT" && -n "$conf_port" ]]; then
    WG_PORT="$conf_port"
  fi
  if [[ "$PERSISTENT_KEEPALIVE" == "$DEFAULT_PERSISTENT_KEEPALIVE" && -n "$conf_keep" ]]; then
    PERSISTENT_KEEPALIVE="$conf_keep"
  fi
  if [[ -z "$WAN_IF" && -n "$conf_wan" ]]; then
    WAN_IF="$conf_wan"
  fi
}

import_existing_peers_if_needed(){
  local peer_count idx endpoint vps_ip vps_addr vps_pub keep

  [[ -f "$CONF_FILE" ]] || return 0
  peer_count="$(find "$PEER_DIR" -maxdepth 1 -type f -name '*.peer' | wc -l | tr -d ' ')"
  [[ "$peer_count" == "0" ]] || return 0
  grep -q '^[[:space:]]*\[Peer\][[:space:]]*$' "$CONF_FILE" || return 0

  idx=0
  while IFS=$'\t' read -r endpoint vps_addr vps_pub keep; do
    [[ -n "$vps_pub" ]] || continue
    idx=$((idx + 1))
    vps_ip="${endpoint%:*}"
    [[ -n "$vps_ip" ]] || continue
    [[ -n "$keep" ]] || keep="$PERSISTENT_KEEPALIVE"
    write_peer_file "legacy-${idx}" "$vps_ip" "$vps_addr" "$vps_pub" "$keep"
  done < <(
    awk '
      function trim(s){ gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
      function emit(){ if (in_peer && pub != "") print endpoint "\t" addr "\t" pub "\t" keep }
      /^\[Peer\][[:space:]]*$/ {
        emit()
        in_peer=1
        endpoint=""
        addr=""
        pub=""
        keep=""
        next
      }
      /^\[/ && $0 != "[Peer]" {
        emit()
        in_peer=0
        next
      }
      in_peer && /^[[:space:]]*PublicKey[[:space:]]*=/ {
        line=$0; sub(/^[^=]*=/, "", line); pub=trim(line); next
      }
      in_peer && /^[[:space:]]*Endpoint[[:space:]]*=/ {
        line=$0; sub(/^[^=]*=/, "", line); endpoint=trim(line); next
      }
      in_peer && /^[[:space:]]*AllowedIPs[[:space:]]*=/ {
        line=$0; sub(/^[^=]*=/, "", line); addr=trim(line); next
      }
      in_peer && /^[[:space:]]*PersistentKeepalive[[:space:]]*=/ {
        line=$0; sub(/^[^=]*=/, "", line); keep=trim(line); next
      }
      END { emit() }
    ' "$CONF_FILE"
  )

  if (( idx > 0 )); then
    echo "==> 已把旧的 wg 配置里的 Peer 导入到 ${PEER_DIR}/legacy-*.peer"
  fi
}

bootstrap_from_existing_conf_if_needed(){
  install_dirs
  if ! load_state && [[ -f "$CONF_FILE" ]]; then
    import_state_from_existing_conf
    if [[ -z "$WAN_IF" ]]; then
      WAN_IF="$(detect_wan_if)"
    fi
    [[ -n "$WAN_IF" ]] || fail "无法探测外网网卡 WAN_IF；请手动指定：WAN_IF=eth0 bash $0 init"
    save_state
  fi
  load_state || true
  import_existing_peers_if_needed
}

write_peer_file(){
  local name="$1" vps_ip="$2" vps_addr="$3" vps_pub="$4" keepalive="$5"
  local file tmp endpoint_ipv4

  endpoint_ipv4="$(resolve_endpoint_ipv4 "$vps_ip" || true)"
  file="$(peer_file "$name")"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  tx_register_temp "$tmp"
  cat >"$tmp" <<EOF_PEER
# name: ${name}
# vps_endpoint: ${vps_ip}
# endpoint_ipv4: ${endpoint_ipv4}
# vps_wg_addr: ${vps_addr}
[Peer]
PublicKey = ${vps_pub}
Endpoint = ${vps_ip}:${WG_PORT}
AllowedIPs = ${vps_addr}
PersistentKeepalive = ${keepalive}
EOF_PEER
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

check_peer_conflicts(){
  local name="$1" vps_ip="$2" vps_addr="$3" vps_pub="$4"
  local file other_name other_ip other_addr other_pub other_endpoint other_resolved this_resolved

  this_resolved="$(resolve_endpoint_ipv4 "$vps_ip" || true)"

  while IFS= read -r file; do
    other_name="$(basename "$file" .peer)"
    [[ "$other_name" == "$name" ]] && continue

    other_endpoint="$(peer_meta_value "$file" vps_endpoint)"
    [[ -n "$other_endpoint" ]] || other_endpoint="$(peer_meta_value "$file" vps_ip)"
    other_ip="$(peer_meta_value "$file" endpoint_ipv4)"
    [[ -n "$other_ip" ]] || other_ip="$(peer_meta_value "$file" vps_ip)"
    other_addr="$(peer_meta_value "$file" vps_wg_addr)"
    other_pub="$(peer_field_value "$file" PublicKey)"
    other_resolved="$other_ip"

    if [[ -n "$other_addr" && "$other_addr" == "$vps_addr" ]]; then
      fail "VPS_WG_ADDR 冲突：${vps_addr} 已被 ${other_name} 使用"
    fi
    if [[ -n "$other_pub" && "$other_pub" == "$vps_pub" ]]; then
      fail "WireGuard 公钥冲突：该公钥已被 ${other_name} 使用"
    fi
    if [[ -n "$other_endpoint" && "$other_endpoint" == "$vps_ip" ]]; then
      fail "Endpoint 冲突：${vps_ip} 已被 ${other_name} 使用"
    fi
    if [[ -n "$this_resolved" && -n "$other_resolved" && "$other_resolved" == "$this_resolved" ]]; then
      fail "Endpoint 解析结果冲突：${vps_ip} 当前解析到 ${this_resolved}，已被 ${other_name} 使用"
    fi
  done < <(find "$PEER_DIR" -maxdepth 1 -type f -name '*.peer' | LC_ALL=C sort)
}

restart_wg(){
  systemctl daemon-reload
  systemctl enable "wg-quick@${WG_IF}" >/dev/null
  if ! systemctl restart "wg-quick@${WG_IF}"; then
    echo "❌ wg-quick@${WG_IF} restart 返回失败，日志如下：" >&2
    systemctl --no-pager --full status "wg-quick@${WG_IF}" >&2 || true
    journalctl -u "wg-quick@${WG_IF}" --no-pager -n 200 >&2 || true
    return 1
  fi

  if ! systemctl is-active --quiet "wg-quick@${WG_IF}"; then
    echo "❌ wg-quick@${WG_IF} 启动失败，日志如下：" >&2
    systemctl --no-pager --full status "wg-quick@${WG_IF}" >&2 || true
    journalctl -u "wg-quick@${WG_IF}" --no-pager -n 200 >&2 || true
    return 1
  fi
  wg show "$WG_IF" >/dev/null 2>&1 || return 1
  "$FIREWALL_SCRIPT" --manager "$WG_IF" || return 1
  return 0
}

ensure_runtime_ready(){
  install_dirs
  bootstrap_from_existing_conf_if_needed
  load_state || fail "未找到 ${STATE_FILE}，请先执行：bash $0 init"
  [[ -n "$WAN_IF" ]] || WAN_IF="$(detect_wan_if)"
  [[ -n "$WAN_IF" ]] || fail "无法探测外网网卡 WAN_IF；请手动指定后重新 init"
  validate_runtime_parameters
  validate_wan_interface_runtime
  command -v wg >/dev/null 2>&1 || fail "wg 命令不存在：请先执行 bash $0 init"
  ensure_nat_keys
  [[ -x "$FIREWALL_SCRIPT" ]] || fail "缺少 ${FIREWALL_SCRIPT}，请重新执行 bash $0 init"
  systemctl is-enabled --quiet "wg-exit-firewall@${WG_IF}.timer" \
    || fail "防火墙 watchdog timer 未启用，请重新执行 bash $0 init"
}

show_nat_pub(){
  [[ -f "$PUB_FILE" ]] || return 0
  echo "==================== NAT 机 WG 公钥 ===================="
  cat "$PUB_FILE"
  echo "========================================================="
}

install_firewall_components(){
  local helper_tmp service_tmp timer_tmp
  install -d -m 755 /usr/local/sbin /etc/systemd/system

  helper_tmp="$(mktemp /usr/local/sbin/.wg_exit_firewall.XXXXXX)"
  tx_register_temp "$helper_tmp"
  cat >"$helper_tmp" <<'WG_EXIT_FIREWALL'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

fail(){ echo "❌ $*" >&2; exit 1; }
MODE="normal"
case "${1:-}" in
  --watchdog|--manager) MODE="${1#--}"; shift ;;
esac
WG_IF="${1:-}"
[[ -n "$WG_IF" && ${#WG_IF} -le 15 && "$WG_IF" =~ ^[A-Za-z0-9_.-]+$ && "$WG_IF" != "." && "$WG_IF" != ".." ]] \
  || fail "WG_IF 非法"

install -d -m 755 /run/lock
if [[ "$MODE" == "watchdog" ]]; then
  exec 9>"/run/lock/vr-wg-exit-${WG_IF}.lock"
  # 管理脚本正在重启接口时，本轮 watchdog 直接跳过，避免与 PostUp/PostDown 交错。
  flock -n 9 || exit 0
elif [[ "$MODE" == "normal" ]]; then
  exec 9>"/run/lock/vr-wg-exit-${WG_IF}.lock"
  flock -w 120 9 || fail "${WG_IF} 管理锁繁忙"
fi
exec 8>"/run/lock/vr-wg-exit-firewall-${WG_IF}.lock"
flock -w 30 8 || fail "${WG_IF} 防火墙锁繁忙"

STATE_FILE="/etc/wireguard/${WG_IF}.env"
[[ -f "$STATE_FILE" ]] || fail "缺少 ${STATE_FILE}"
[[ "$(stat -c %u "$STATE_FILE" 2>/dev/null || echo -1)" == "0" ]] || fail "状态文件必须属于 root"
mode="$(stat -c %a "$STATE_FILE" 2>/dev/null || echo 777)"
[[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( ((8#$mode) & 8#022) == 0 )) || fail "状态文件不能被 group/other 写入"

WG_ADDR=""
WAN_IF=""
while IFS='=' read -r key value; do
  case "$key" in
    WG_ADDR) WG_ADDR="$value" ;;
    WAN_IF) WAN_IF="$value" ;;
  esac
done <"$STATE_FILE"

[[ "$WG_ADDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/24$ ]] || fail "WG_ADDR 非法"
[[ -n "$WAN_IF" && ${#WAN_IF} -le 15 && "$WAN_IF" =~ ^[A-Za-z0-9_.-]+$ && "$WAN_IF" != "." && "$WAN_IF" != ".." ]] \
  || fail "WAN_IF 非法"
ip link show dev "$WAN_IF" >/dev/null 2>&1 || fail "WAN_IF 不存在：${WAN_IF}"

ip="${WG_ADDR%/*}"
IFS=. read -r a b c d <<<"$ip"
for n in "$a" "$b" "$c" "$d"; do
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 0 && n <= 255 )) || fail "WG_ADDR 非法"
done
WG_SOURCE_CIDR="${a}.${b}.${c}.0/24"
suffix="${WG_IF//[^A-Za-z0-9]/_}"
suffix="${suffix^^}"
WG_NAT_CHAIN="VRN_${suffix}"
WG_FWD_CHAIN="VRF_${suffix}"
OWNER="vr-wg:${WG_IF}"

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null

if iptables -w 5 -C "$WG_FWD_CHAIN" -i "$WG_IF" -o "$WAN_IF" -s "$WG_SOURCE_CIDR" -j ACCEPT >/dev/null 2>&1 \
  && iptables -w 5 -C "$WG_FWD_CHAIN" -i "$WAN_IF" -o "$WG_IF" -d "$WG_SOURCE_CIDR" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1 \
  && iptables -w 5 -C FORWARD -m comment --comment "$OWNER" -j "$WG_FWD_CHAIN" >/dev/null 2>&1 \
  && iptables -w 5 -t nat -C "$WG_NAT_CHAIN" -s "$WG_SOURCE_CIDR" -o "$WAN_IF" -j MASQUERADE >/dev/null 2>&1 \
  && iptables -w 5 -t nat -C POSTROUTING -m comment --comment "$OWNER" -j "$WG_NAT_CHAIN" >/dev/null 2>&1
then
  exit 0
fi

iptables -w 5 -N "$WG_FWD_CHAIN" 2>/dev/null || true
iptables -w 5 -F "$WG_FWD_CHAIN"
iptables -w 5 -A "$WG_FWD_CHAIN" -i "$WG_IF" -o "$WAN_IF" -s "$WG_SOURCE_CIDR" -j ACCEPT
iptables -w 5 -A "$WG_FWD_CHAIN" -i "$WAN_IF" -o "$WG_IF" -d "$WG_SOURCE_CIDR" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
while iptables -w 5 -D FORWARD -m comment --comment "$OWNER" -j "$WG_FWD_CHAIN" >/dev/null 2>&1; do :; done
iptables -w 5 -I FORWARD -m comment --comment "$OWNER" -j "$WG_FWD_CHAIN"

iptables -w 5 -t nat -N "$WG_NAT_CHAIN" 2>/dev/null || true
iptables -w 5 -t nat -F "$WG_NAT_CHAIN"
iptables -w 5 -t nat -A "$WG_NAT_CHAIN" -s "$WG_SOURCE_CIDR" -o "$WAN_IF" -j MASQUERADE
while iptables -w 5 -t nat -D POSTROUTING -m comment --comment "$OWNER" -j "$WG_NAT_CHAIN" >/dev/null 2>&1; do :; done
iptables -w 5 -t nat -I POSTROUTING -m comment --comment "$OWNER" -j "$WG_NAT_CHAIN"

iptables -w 5 -C FORWARD -m comment --comment "$OWNER" -j "$WG_FWD_CHAIN" >/dev/null
iptables -w 5 -t nat -C POSTROUTING -m comment --comment "$OWNER" -j "$WG_NAT_CHAIN" >/dev/null
[[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] || fail "ip_forward 未生效"
WG_EXIT_FIREWALL
  chmod 755 "$helper_tmp"
  bash -n "$helper_tmp"
  mv -f -- "$helper_tmp" "$FIREWALL_SCRIPT"

  service_tmp="$(mktemp /etc/systemd/system/.wg-exit-firewall-service.XXXXXX)"
  tx_register_temp "$service_tmp"
  cat >"$service_tmp" <<'WG_EXIT_SERVICE'
[Unit]
Description=Repair owned WireGuard exit firewall for %i
After=local-fs.target network-pre.target
ConditionPathExists=/etc/wireguard/%i.env

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wg_exit_firewall.sh --watchdog %i
WG_EXIT_SERVICE
  chmod 644 "$service_tmp"
  mv -f -- "$service_tmp" "$FIREWALL_SERVICE"

  timer_tmp="$(mktemp /etc/systemd/system/.wg-exit-firewall-timer.XXXXXX)"
  tx_register_temp "$timer_tmp"
  cat >"$timer_tmp" <<'WG_EXIT_TIMER'
[Unit]
Description=Watch owned WireGuard exit firewall for %i

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=5s
RandomizedDelaySec=5s
Unit=wg-exit-firewall@%i.service

[Install]
WantedBy=timers.target
WG_EXIT_TIMER
  chmod 644 "$timer_tmp"
  mv -f -- "$timer_tmp" "$FIREWALL_TIMER"

  systemctl daemon-reload
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "$FIREWALL_SERVICE" "$FIREWALL_TIMER" >/dev/null
  fi
  systemctl enable "wg-exit-firewall@${WG_IF}.timer" >/dev/null
}

cmd_init(){
  local tmp_conf sysctl_tmp

  need_packages
  require_wireguard_kernel
  tx_begin
  install_dirs

  merge_saved_state_if_exists

  # 如果是从旧单 Peer 版本升级，尽量自动继承已有配置。
  if [[ -f "$CONF_FILE" && ! -f "$STATE_FILE" ]]; then
    import_state_from_existing_conf
  fi

  if [[ -z "$WAN_IF" ]]; then
    WAN_IF="$(detect_wan_if)"
  fi
  [[ -n "$WAN_IF" ]] || fail "无法探测外网网卡 WAN_IF；请手动指定：WAN_IF=eth0 bash $0 init"
  validate_runtime_parameters
  validate_wan_interface_runtime

  echo "==> 开启 IPv4 转发（并持久化）..."
  sysctl_tmp="$(mktemp /etc/sysctl.d/.99-wg-exit.XXXXXX)"
  tx_register_temp "$sysctl_tmp"
  cat >"$sysctl_tmp" <<EOF_SYSCTL
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF_SYSCTL
  chmod 644 "$sysctl_tmp"
  mv -f -- "$sysctl_tmp" "$SYSCTL_FILE"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
  sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null

  command -v wg >/dev/null 2>&1 || fail "wg 命令不存在：请确认 wireguard-tools 安装成功"

  ensure_nat_keys
  save_state
  import_existing_peers_if_needed
  install_firewall_components

  echo "==> 写入 wg-quick 配置（${WG_IF}）..."
  tmp_conf="$(mktemp "${CONF_FILE}.tmp.XXXXXX")"
  tx_register_temp "$tmp_conf"
  render_wg_conf "$tmp_conf"
  cleanup_legacy_firewall_rules_if_needed
  mv -f -- "$tmp_conf" "$CONF_FILE"

  if ! restart_wg; then
    fail "初始化失败，已尽量回滚到旧配置"
  fi
  systemctl start "wg-exit-firewall@${WG_IF}.timer"
  systemctl is-enabled --quiet "wg-exit-firewall@${WG_IF}.timer" || fail "防火墙 watchdog timer 未启用"
  systemctl is-active --quiet "wg-exit-firewall@${WG_IF}.timer" || fail "防火墙 watchdog timer 未运行"
  tx_commit

  echo
  echo "✅ NAT 机 WG-EXIT 初始化完成。"
  echo "外网网卡: ${WAN_IF}"
  echo "接口名: ${WG_IF}"
  echo "Peer 目录: ${PEER_DIR}"
  show_nat_pub
  echo
  echo "下一步：为每台 VPS 执行 add（WG 地址自动分配），例如："
  echo "bash $0 add vps-1 1.2.3.4 'VPS_WG_PUBLIC_KEY'"
  echo "bash $0 add vps-2 hk.example.com 'VPS_WG_PUBLIC_KEY'"
}

cmd_add(){
  local name="$1" vps_ip="$2" vps_pub_raw="$3" requested_addr="${4:-}"
  local vps_pub vps_addr vps_local_addr nat_pub
  local tmp_conf

  validate_name "$name"
  validate_vps_endpoint "$vps_ip"
  tx_begin
  ensure_runtime_ready

  if [[ -n "$requested_addr" ]]; then
    # 旧命令兼容模式：显式地址仍然接受，但新用户不需要填写。
    vps_addr="$requested_addr"
    validate_vps_wg_addr "$vps_addr"
  else
    vps_addr="$(auto_allocate_vps_wg_addr "$name")"
  fi

  vps_pub="$(clean_pubkey "$vps_pub_raw")"
  validate_pubkey "$vps_pub"
  check_peer_conflicts "$name" "$vps_ip" "$vps_addr" "$vps_pub"

  write_peer_file "$name" "$vps_ip" "$vps_addr" "$vps_pub" "$PERSISTENT_KEEPALIVE"

  tmp_conf="$(mktemp "${CONF_FILE}.tmp.XXXXXX")"
  tx_register_temp "$tmp_conf"
  render_wg_conf "$tmp_conf"
  cleanup_legacy_firewall_rules_if_needed
  mv -f -- "$tmp_conf" "$CONF_FILE"

  if ! restart_wg; then
    fail "新增/更新 Peer 失败，已回滚"
  fi
  systemctl start "wg-exit-firewall@${WG_IF}.timer"
  systemctl is-active --quiet "wg-exit-firewall@${WG_IF}.timer" || fail "防火墙 watchdog timer 未运行"
  tx_commit

  vps_local_addr="$(vps_interface_addr_from_peer_addr "$vps_addr")"
  nat_pub="$(cat "$PUB_FILE")"

  echo "✅ 已新增/更新 Peer：${name}"
  echo "VPS_ENDPOINT: ${vps_ip}"
  echo "NAT AllowedIPs: ${vps_addr}"
  echo "VPS Interface Address: ${vps_local_addr}"
  echo
  echo "================ 在 VPS 原样执行下面这一条 ================"
  printf "/usr/local/sbin/wg_nat_set_peer.sh '%s' '%s'\n" "$nat_pub" "$vps_local_addr"
  echo "==========================================================="
  echo "提示：地址已经自动分配，不需要你手填 10.66.66.X/32。"
}

cmd_del(){
  local name="$1" file tmp_conf

  validate_name "$name"
  tx_begin
  ensure_runtime_ready
  file="$(peer_file "$name")"
  [[ -f "$file" ]] || fail "Peer 不存在：${name}"

  rm -f "$file"

  tmp_conf="$(mktemp "${CONF_FILE}.tmp.XXXXXX")"
  tx_register_temp "$tmp_conf"
  render_wg_conf "$tmp_conf"
  cleanup_legacy_firewall_rules_if_needed
  mv -f -- "$tmp_conf" "$CONF_FILE"

  if ! restart_wg; then
    fail "删除 Peer 失败，已回滚"
  fi
  systemctl start "wg-exit-firewall@${WG_IF}.timer"
  systemctl is-active --quiet "wg-exit-firewall@${WG_IF}.timer" || fail "防火墙 watchdog timer 未运行"
  tx_commit

  echo "✅ 已删除 Peer：${name}"
}

cmd_list(){
  local file count name vps_ip vps_addr vps_pub endpoint

  install_dirs
  bootstrap_from_existing_conf_if_needed

  mapfile -t PEER_FILES < <(find "$PEER_DIR" -maxdepth 1 -type f -name '*.peer' | LC_ALL=C sort)
  count="${#PEER_FILES[@]}"

  echo "当前 Peer 目录：${PEER_DIR}"
  echo "当前 Peer 数量：${count}"

  if (( count == 0 )); then
    echo "（空）"
    return 0
  fi

  printf '%-20s %-28s %-18s %s\n' "NAME" "ENDPOINT(IP或域名)" "VPS_WG_ADDR" "PUBLIC_KEY"
  printf '%-20s %-28s %-18s %s\n' "--------------------" "----------------------------" "------------------" "--------------------------------------------"

  for file in "${PEER_FILES[@]}"; do
    name="$(basename "$file" .peer)"
    vps_ip="$(peer_meta_value "$file" vps_endpoint)"
    [[ -n "$vps_ip" ]] || vps_ip="$(peer_meta_value "$file" vps_ip)"
    vps_addr="$(peer_meta_value "$file" vps_wg_addr)"
    vps_pub="$(peer_field_value "$file" PublicKey)"
    printf '%-20s %-28s %-18s %s\n' "$name" "$vps_ip" "$vps_addr" "$vps_pub"
  done
}

cmd_status(){
  install_dirs
  bootstrap_from_existing_conf_if_needed
  load_state || true

  echo "接口名: ${WG_IF}"
  [[ -f "$STATE_FILE" ]] && echo "状态文件: ${STATE_FILE}"
  [[ -d "$PEER_DIR" ]] && echo "Peer 目录: ${PEER_DIR}"
  echo

  cmd_list || true
  echo
  echo "==== systemctl status wg-quick@${WG_IF} ===="
  systemctl --no-pager --full status "wg-quick@${WG_IF}" || true
  echo
  echo "==== wg show ${WG_IF} ===="
  if command -v wg >/dev/null 2>&1; then
    wg show "${WG_IF}" || true
  else
    echo "wg 命令不存在"
  fi
}

main(){
  local cmd="${1:-}"
  validate_runtime_parameters
  require_supported_platform
  command -v flock >/dev/null 2>&1 || fail "缺少 flock（util-linux）"
  install -d -m 755 /run/lock
  exec 9>"/run/lock/vr-wg-exit-${WG_IF}.lock"
  flock -w 120 9 || fail "另一个 ${WG_IF} 管理任务仍在运行"
  trap 'tx_on_exit' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  case "$cmd" in
    init)
      [[ $# -eq 1 ]] || fail "用法: bash $0 init"
      cmd_init
      ;;
    add)
      case "$#" in
        4)
          cmd_add "$2" "$3" "$4"
          ;;
        5)
          warn "检测到旧版 add 写法；仍兼容，但以后可省略 VPS_WG_ADDR。"
          cmd_add "$2" "$3" "$5" "$4"
          ;;
        *)
          fail "用法: bash $0 add <name> <VPS_IP或域名> '<VPS_WG_PUBLIC_KEY>'"
          ;;
      esac
      ;;
    del)
      [[ $# -eq 2 ]] || fail "用法: bash $0 del <name>"
      cmd_del "$2"
      ;;
    list)
      [[ $# -eq 1 ]] || fail "用法: bash $0 list"
      cmd_list
      ;;
    status)
      [[ $# -eq 1 ]] || fail "用法: bash $0 status"
      cmd_status
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      fail "未知命令：${cmd}"
      ;;
  esac
}

main "$@"
