#!/usr/bin/env bash
# Final four-file edition: VPS-side WireGuard policy-routing setup.
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
umask 077

# WG-NAT（VPS 侧）：为打 mark 的流量提供 WireGuard NAT 出口。
#
# 新流程：
#   1) VPS 执行本脚本，只需拿到 VPS WG 公钥。
#   2) NAT 机执行：
#        bash /root/nat.sh add <name> <VPS域名或IP> '<VPS_WG_PUB>'
#      NAT 会自动分配 10.66.66.X/32，并打印完整的 VPS 回填命令。
#   3) 回到 VPS，原样执行 NAT 打印的命令。
#
# 旧机器重复执行本脚本时，会尽量保留现有 WG 地址和已配置 Peer。

WG_PORT_EXPLICIT="${WG_PORT+x}"
MARK_EXPLICIT="${MARK+x}"
TABLE_ID_EXPLICIT="${TABLE_ID+x}"
RULE_PRIORITY_EXPLICIT="${RULE_PRIORITY+x}"
FAILCLOSE_METRIC_EXPLICIT="${FAILCLOSE_METRIC+x}"
WG_ROUTE_METRIC_EXPLICIT="${WG_ROUTE_METRIC+x}"

WG_IF="${WG_IF:-wg-nat}"
WG_PORT="${WG_PORT:-51820}"
DEFAULT_WG_ADDR="10.66.66.1/24"
MARK_RAW="${MARK:-2333}"
TABLE_ID="${TABLE_ID:-100}"
RULE_PRIORITY="${RULE_PRIORITY:-31000}"
FAILCLOSE_METRIC="${FAILCLOSE_METRIC:-42760}"
WG_ROUTE_METRIC="${WG_ROUTE_METRIC:-10}"

# 平台兼容策略：最低版本受控、最高版本开放，避免新发行版仅因代号变化被拒绝。
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
GUARD_SCRIPT="/usr/local/sbin/wg_nat_guard.sh"
SET_PEER_SCRIPT="/usr/local/sbin/wg_nat_set_peer.sh"
HEALTH_SCRIPT="/usr/local/sbin/wg_nat_healthcheck.sh"
GUARD_SERVICE="/etc/systemd/system/wg-nat-guard@.service"
GUARD_TIMER="/etc/systemd/system/wg-nat-guard@.timer"
WG_DROPIN_DIR="/etc/systemd/system/wg-quick@${WG_IF}.service.d"
WG_DROPIN="${WG_DROPIN_DIR}/10-vr-nat-guard.conf"
SYSCTL_FILE="/etc/sysctl.d/99-vr-wg-nat.conf"

MAIN_TX_ACTIVE=0
MAIN_TX_DIR=""
MAIN_OLD_SERVICE_ACTIVE=0
MAIN_OLD_SERVICE_ENABLED=""
MAIN_OLD_TIMER_ACTIVE=0
MAIN_OLD_TIMER_ENABLED=""
OLD_MARK_DEC=""
OLD_TABLE_ID=""
OLD_RULE_PRIORITY=""
OLD_FAILCLOSE_METRIC="42760"
OLD_WG_ROUTE_METRIC="10"

need_root(){ [[ ${EUID:-0} -eq 0 ]] || { echo "❌ 请用 root 运行"; exit 1; }; }
fail(){ echo "❌ $*" >&2; exit 1; }
warn(){ echo "⚠️  $*" >&2; }

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

install_packages(){
  local wg_package="wireguard-tools"
  export DEBIAN_FRONTEND=noninteractive
  echo "==> 安装依赖（${wg_package} / iproute2 / iptables / curl / python3 / openssl / procps）..."
  apt-get update -o Acquire::Retries=3 >/dev/null \
    || fail "apt-get update 失败；请检查 ${OS_PRETTY_NAME} 的软件源"
  apt_install_with_universe_retry \
    "$wg_package" iproute2 iptables curl python3 openssl ca-certificates procps kmod util-linux coreutils

  local cmd
  for cmd in wg wg-quick ip iptables curl python3 openssl sysctl modprobe; do
    command -v "$cmd" >/dev/null 2>&1 || fail "依赖安装后仍缺少命令：${cmd}"
  done
}

require_wireguard_kernel(){
  if modprobe wireguard >/dev/null 2>&1 || [[ -d /sys/module/wireguard ]]; then
    return 0
  fi
  fail "当前内核没有可用的 WireGuard 模块；请安装发行版支持的内核/WireGuard DKMS 后重试"
}

ts(){ date +%F_%H%M%S; }

backup_if_exists(){
  local f="$1" dst
  if [[ -e "$f" ]]; then
    dst="${f}.bak.$(ts)"
    cp -a "$f" "$dst"
    echo "✅ 备份：$f -> $dst"
  fi
}

trim(){
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

norm_mark(){
  local raw="${1,,}"
  raw="${raw//[[:space:]]/}"
  if [[ "$raw" =~ ^0x[0-9a-f]+$ ]]; then
    raw="${raw#0x}"
    (( ${#raw} <= 8 )) || fail "MARK 超出 32 位范围：$1"
    echo "$((16#$raw))"
  elif [[ "$raw" =~ ^[0-9]+$ ]]; then
    (( ${#raw} <= 10 )) || fail "MARK 超出 32 位范围：$1"
    echo "$raw"
  else
    fail "MARK 格式不合法：$1（应为 2333 或 0x91d）"
  fi
}

validate_ifname(){
  local value="$1" label="${2:-接口名}"
  [[ -n "$value" ]] || fail "${label} 不能为空"
  (( ${#value} <= 15 )) || fail "${label} 过长（最多 15 字符）：${value}"
  [[ "$value" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "${label} 非法：${value}"
  [[ "$value" != "." && "$value" != ".." ]] || fail "${label} 非法：${value}"
}

validate_uint_range(){
  local value="$1" min="$2" max="$3" label="$4"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "${label} 必须是整数：${value}"
  (( value >= min && value <= max )) || fail "${label} 必须在 ${min}-${max}：${value}"
}

validate_runtime_parameters(){
  validate_ifname "$WG_IF" "WG_IF"
  validate_uint_range "$WG_PORT" 1 65535 "WG_PORT"
  validate_uint_range "$TABLE_ID" 1 2147483647 "TABLE_ID"
  validate_uint_range "$RULE_PRIORITY" 1 32765 "RULE_PRIORITY"
  validate_uint_range "$MARK_DEC" 1 4294967295 "MARK"
  validate_uint_range "$FAILCLOSE_METRIC" 1 4294967295 "FAILCLOSE_METRIC"
  validate_uint_range "$WG_ROUTE_METRIC" 0 4294967295 "WG_ROUTE_METRIC"
  (( WG_ROUTE_METRIC < FAILCLOSE_METRIC )) || fail "WG_ROUTE_METRIC 必须小于 FAILCLOSE_METRIC"
  (( TABLE_ID < 253 || TABLE_ID > 255 )) || fail "TABLE_ID 不能使用 253-255 保留表"
}

validate_ipv4(){
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.
  local a b c d n
  read -r a b c d <<<"$ip"
  for n in "$a" "$b" "$c" "$d"; do
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    (( n >= 0 && n <= 255 )) || return 1
  done
}

normalize_vps_wg_addr(){
  local addr="$1" ip mask
  addr="$(trim "$addr")"
  [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/(24|32)$ ]] \
    || fail "WG 地址必须类似 10.66.66.3/24（也兼容传入 /32）：$addr"
  ip="${addr%/*}"
  mask="${addr#*/}"
  validate_ipv4 "$ip" || fail "WG 地址里的 IPv4 不合法：$addr"
  if [[ "$mask" == "32" ]]; then
    echo "${ip}/24"
  else
    echo "${ip}/24"
  fi
}

state_value(){
  local key="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  sed -n "s/^${key}=//p" "$STATE_FILE" | head -n1
}

merge_saved_runtime_parameters(){
  local saved
  [[ -f "$STATE_FILE" ]] || return 0
  if [[ -z "$WG_PORT_EXPLICIT" ]]; then
    saved="$(state_value WG_PORT || true)"; [[ -n "$saved" ]] && WG_PORT="$saved"
  fi
  if [[ -z "$MARK_EXPLICIT" ]]; then
    saved="$(state_value MARK || true)"; [[ -n "$saved" ]] && MARK_RAW="$saved"
  fi
  if [[ -z "$TABLE_ID_EXPLICIT" ]]; then
    saved="$(state_value TABLE_ID || true)"; [[ -n "$saved" ]] && TABLE_ID="$saved"
  fi
  if [[ -z "$RULE_PRIORITY_EXPLICIT" ]]; then
    saved="$(state_value RULE_PRIORITY || true)"; [[ -n "$saved" ]] && RULE_PRIORITY="$saved"
  fi
  if [[ -z "$FAILCLOSE_METRIC_EXPLICIT" ]]; then
    saved="$(state_value FAILCLOSE_METRIC || true)"; [[ -n "$saved" ]] && FAILCLOSE_METRIC="$saved"
  fi
  if [[ -z "$WG_ROUTE_METRIC_EXPLICIT" ]]; then
    saved="$(state_value WG_ROUTE_METRIC || true)"; [[ -n "$saved" ]] && WG_ROUTE_METRIC="$saved"
  fi
}

conf_address(){
  [[ -f "$CONF_FILE" ]] || return 0
  sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$CONF_FILE" | head -n1
}

save_state(){
  local addr="$1" tmp
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
  cat >"$tmp" <<EOF_STATE
WG_ADDR=${addr}
WG_PORT=${WG_PORT}
MARK=${MARK_DEC}
TABLE_ID=${TABLE_ID}
RULE_PRIORITY=${RULE_PRIORITY}
FAILCLOSE_METRIC=${FAILCLOSE_METRIC}
WG_ROUTE_METRIC=${WG_ROUTE_METRIC}
EOF_STATE
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

resolve_current_addr(){
  local explicit="${WG_ADDR:-}" saved existing has_peer=0
  if [[ -n "$explicit" ]]; then
    normalize_vps_wg_addr "$explicit"
    return
  fi

  existing="$(conf_address || true)"
  if [[ -f "$CONF_FILE" ]] && grep -q '^[[:space:]]*\[Peer\][[:space:]]*$' "$CONF_FILE"; then
    has_peer=1
  fi

  # 已经在工作的配置优先，避免旧 state 意外覆盖真实 Address。
  if (( has_peer == 1 )) && [[ -n "$existing" ]]; then
    normalize_vps_wg_addr "$existing"
    return
  fi

  saved="$(state_value WG_ADDR || true)"
  if [[ -n "$saved" ]]; then
    normalize_vps_wg_addr "$saved"
    return
  fi

  if [[ -n "$existing" ]]; then
    normalize_vps_wg_addr "$existing"
    return
  fi

  echo "$DEFAULT_WG_ADDR"
}

write_base_conf(){
  local addr="$1" priv="$2" out="${3:-$CONF_FILE}"
  cat >"$out" <<CFG
[Interface]
Address = ${addr}
ListenPort = ${WG_PORT}
PrivateKey = ${priv}
Table = off

# 放宽 rp_filter：避免策略路由/回程被丢
PostUp = sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
PostUp = sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1 || true

# 只有打了 fwmark 的流量才走 table ${TABLE_ID} -> ${WG_IF}。
# prohibit 路由和 OUTPUT guard 在 WireGuard 停止时继续保留，防止回落主路由。
PostUp = ip -4 rule del priority ${RULE_PRIORITY} fwmark ${MARK_DEC} lookup ${TABLE_ID} 2>/dev/null || true
PostUp = ip -4 rule add priority ${RULE_PRIORITY} fwmark ${MARK_DEC} lookup ${TABLE_ID}
PostUp = ip -4 route show table ${TABLE_ID} | grep -qE "^prohibit default.*metric ${FAILCLOSE_METRIC}([[:space:]]|$)" || ip -4 route add prohibit default metric ${FAILCLOSE_METRIC} table ${TABLE_ID}
PostUp = ip -4 route del default dev %i metric ${WG_ROUTE_METRIC} table ${TABLE_ID} 2>/dev/null || true
PostUp = ip -4 route add default dev %i metric ${WG_ROUTE_METRIC} table ${TABLE_ID}

PostDown = ip -4 route del default dev %i metric ${WG_ROUTE_METRIC} table ${TABLE_ID} 2>/dev/null || true
PostDown = ip -4 route show table ${TABLE_ID} | grep -qE "^prohibit default.*metric ${FAILCLOSE_METRIC}([[:space:]]|$)" || ip -4 route add prohibit default metric ${FAILCLOSE_METRIC} table ${TABLE_ID}
CFG
  chmod 600 "$out"
}

conf_uses_legacy_policy_rule(){
  local file="${1:-$CONF_FILE}"
  [[ -f "$file" ]] || return 1

  # 旧版没有固定 priority；只有明确检测到旧配置时才执行宽范围迁移清理。
  grep -Eq '^[[:space:]]*PostUp[[:space:]]*=[[:space:]]*ip([[:space:]]+-4)?[[:space:]]+rule[[:space:]]+add[[:space:]]+fwmark[[:space:]]+' "$file"
}

remove_owned_policy_rule(){
  local tries=0
  while (( tries < 8 )) \
    && ip -4 rule del priority "$RULE_PRIORITY" fwmark "$MARK_DEC" lookup "$TABLE_ID" >/dev/null 2>&1
  do
    tries=$((tries + 1))
  done
}

remove_legacy_policy_rules(){
  local tries=0
  while (( tries < 32 )) \
    && ip -4 rule del fwmark "$MARK_DEC" lookup "$TABLE_ID" >/dev/null 2>&1
  do
    tries=$((tries + 1))
  done
}

remove_policy_tuple(){
  local priority="$1" mark="$2" table="$3" wg_metric="$4" fail_metric="$5" tries=0
  [[ "$priority" =~ ^[0-9]+$ && "$mark" =~ ^[0-9]+$ && "$table" =~ ^[0-9]+$ ]] || return 0
  while (( tries < 16 )) && ip -4 rule del priority "$priority" fwmark "$mark" lookup "$table" >/dev/null 2>&1; do
    tries=$((tries + 1))
  done
  ip -4 route del default dev "$WG_IF" metric "$wg_metric" table "$table" >/dev/null 2>&1 || true
  ip -4 route del prohibit default metric "$fail_metric" table "$table" >/dev/null 2>&1 || true
}

prepare_policy_rule_migration(){
  # 正常重跑只处理本脚本固定优先级规则。
  remove_owned_policy_rule
  if [[ -n "$OLD_MARK_DEC" ]] \
    && [[ "$OLD_MARK_DEC" != "$MARK_DEC" || "$OLD_TABLE_ID" != "$TABLE_ID" || "$OLD_RULE_PRIORITY" != "$RULE_PRIORITY" \
          || "$OLD_WG_ROUTE_METRIC" != "$WG_ROUTE_METRIC" || "$OLD_FAILCLOSE_METRIC" != "$FAILCLOSE_METRIC" ]]
  then
    remove_policy_tuple "$OLD_RULE_PRIORITY" "$OLD_MARK_DEC" "$OLD_TABLE_ID" "$OLD_WG_ROUTE_METRIC" "$OLD_FAILCLOSE_METRIC"
  fi
  if (( LEGACY_POLICY_MIGRATION_NEEDED == 1 )); then
    warn "检测到旧版无固定优先级策略规则，执行一次迁移清理（fwmark=${MARK_DEC}, table=${TABLE_ID}）"
    remove_legacy_policy_rules
  fi
}

main_target_key(){
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

restore_enabled_state(){
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

stop_current_wg_for_rollback(){
  timeout 30 systemctl stop "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  if ip link show dev "$WG_IF" >/dev/null 2>&1; then
    timeout 20 wg-quick down "$WG_IF" >/dev/null 2>&1 || true
  fi
  if ip link show dev "$WG_IF" >/dev/null 2>&1; then
    ip link delete dev "$WG_IF" >/dev/null 2>&1 || true
  fi
}

direct_failsafe(){
  local action="$1" mark="$2" comment
  [[ "$mark" =~ ^[0-9]+$ ]] || return 0
  comment="vpswg:${WG_IF}:failsafe:${mark}"
  if [[ "$action" == "add" ]]; then
    iptables -w 5 -C OUTPUT -m mark --mark "${mark}/0xffffffff" '!' -o "$WG_IF" \
      -m comment --comment "$comment" -j REJECT --reject-with icmp-net-unreachable >/dev/null 2>&1 \
      || iptables -w 5 -I OUTPUT -m mark --mark "${mark}/0xffffffff" '!' -o "$WG_IF" \
        -m comment --comment "$comment" -j REJECT --reject-with icmp-net-unreachable
  else
    while iptables -w 5 -D OUTPUT -m mark --mark "${mark}/0xffffffff" '!' -o "$WG_IF" \
      -m comment --comment "$comment" -j REJECT --reject-with icmp-net-unreachable >/dev/null 2>&1
    do :; done
  fi
}

cleanup_guard_tuple(){
  local mark="$1" table="$2" priority="$3" wg_metric="$4" fail_metric="$5" suffix input_chain output_chain
  [[ "$mark" =~ ^[0-9]+$ && "$table" =~ ^[0-9]+$ && "$priority" =~ ^[0-9]+$ ]] || return 0
  while ip -4 rule del priority "$priority" fwmark "$mark" lookup "$table" >/dev/null 2>&1; do :; done
  ip -4 route del default dev "$WG_IF" metric "$wg_metric" table "$table" >/dev/null 2>&1 || true
  ip -4 route del prohibit default metric "$fail_metric" table "$table" >/dev/null 2>&1 || true
  suffix="${WG_IF//[^A-Za-z0-9]/_}"
  suffix="${suffix^^}"
  input_chain="VRWI_${suffix}"
  output_chain="VRWO_${suffix}"
  while iptables -w 5 -D INPUT -m comment --comment "vpswg:${WG_IF}:input" -j "$input_chain" >/dev/null 2>&1; do :; done
  while iptables -w 5 -D OUTPUT -m comment --comment "vpswg:${WG_IF}:output" -j "$output_chain" >/dev/null 2>&1; do :; done
  iptables -w 5 -F "$input_chain" >/dev/null 2>&1 || true
  iptables -w 5 -X "$input_chain" >/dev/null 2>&1 || true
  iptables -w 5 -F "$output_chain" >/dev/null 2>&1 || true
  iptables -w 5 -X "$output_chain" >/dev/null 2>&1 || true
}

main_begin_transaction(){
  local path key old_mark_raw
  MAIN_TX_DIR="$(mktemp -d /var/tmp/vr-vpswg-transaction.XXXXXX)"
  MAIN_TARGETS=(
    "$CONF_FILE" "$STATE_FILE" "$KEY_FILE" "$PUB_FILE" "$GUARD_SCRIPT"
    "$SET_PEER_SCRIPT" "$HEALTH_SCRIPT" "$GUARD_SERVICE" "$GUARD_TIMER"
    "$WG_DROPIN" "$SYSCTL_FILE"
  )
  for path in "${MAIN_TARGETS[@]}"; do
    key="$(main_target_key "$path")"
    if [[ -e "$path" || -L "$path" ]]; then
      cp -a -- "$path" "${MAIN_TX_DIR}/${key}"
      : >"${MAIN_TX_DIR}/${key}.present"
    fi
  done
  MAIN_TX_ACTIVE=1
  MAIN_OLD_SERVICE_ENABLED="$(systemctl is-enabled "wg-quick@${WG_IF}" 2>/dev/null || true)"
  systemctl is-active --quiet "wg-quick@${WG_IF}" 2>/dev/null && MAIN_OLD_SERVICE_ACTIVE=1 || true
  MAIN_OLD_TIMER_ENABLED="$(systemctl is-enabled "wg-nat-guard@${WG_IF}.timer" 2>/dev/null || true)"
  systemctl is-active --quiet "wg-nat-guard@${WG_IF}.timer" 2>/dev/null && MAIN_OLD_TIMER_ACTIVE=1 || true
  OLD_RP_ALL="$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || true)"
  OLD_RP_DEFAULT="$(sysctl -n net.ipv4.conf.default.rp_filter 2>/dev/null || true)"
  if [[ -f "$STATE_FILE" ]]; then
    old_mark_raw="$(state_value MARK || true)"
    OLD_TABLE_ID="$(state_value TABLE_ID || true)"
    OLD_RULE_PRIORITY="$(state_value RULE_PRIORITY || true)"
    OLD_FAILCLOSE_METRIC="$(state_value FAILCLOSE_METRIC || true)"
    OLD_WG_ROUTE_METRIC="$(state_value WG_ROUTE_METRIC || true)"
    OLD_FAILCLOSE_METRIC="${OLD_FAILCLOSE_METRIC:-42760}"
    OLD_WG_ROUTE_METRIC="${OLD_WG_ROUTE_METRIC:-10}"
    [[ -n "$old_mark_raw" ]] && OLD_MARK_DEC="$(norm_mark "$old_mark_raw")"
  fi
}

restore_main_previous_state(){
  (( MAIN_TX_ACTIVE == 1 )) || return 0
  MAIN_TX_ACTIVE=0
  set +e
  trap '' INT TERM HUP
  echo "↩ 正在回滚 VPS WireGuard 安装..." >&2
  local temp_path
  for temp_path in "${GUARD_TMP:-}" "${SERVICE_TMP:-}" "${TIMER_TMP:-}" "${DROPIN_TMP:-}" \
    "${SYSCTL_TMP:-}" "${SET_PEER_TMP:-}" "${HEALTH_TMP:-}" "${tmp_conf:-}"
  do
    [[ -n "$temp_path" ]] && rm -f -- "$temp_path"
  done
  direct_failsafe add "${MARK_DEC:-}"
  direct_failsafe add "$OLD_MARK_DEC"
  timeout 20 systemctl stop "wg-nat-guard@${WG_IF}.timer" >/dev/null 2>&1 || true
  stop_current_wg_for_rollback
  cleanup_guard_tuple "${MARK_DEC:-}" "${TABLE_ID:-}" "${RULE_PRIORITY:-}" "${WG_ROUTE_METRIC:-10}" "${FAILCLOSE_METRIC:-42760}"

  local path key guard_restored
  for path in "${MAIN_TARGETS[@]}"; do
    key="$(main_target_key "$path")"
    rm -f -- "$path"
    if [[ -f "${MAIN_TX_DIR}/${key}.present" ]]; then
      install -d -m 755 "$(dirname "$path")"
      cp -a -- "${MAIN_TX_DIR}/${key}" "$path"
    fi
  done
  systemctl daemon-reload >/dev/null 2>&1 || true
  restore_enabled_state "wg-quick@${WG_IF}" "$MAIN_OLD_SERVICE_ENABLED"
  restore_enabled_state "wg-nat-guard@${WG_IF}.timer" "$MAIN_OLD_TIMER_ENABLED"

  guard_restored=0
  if [[ -x "$GUARD_SCRIPT" && -f "$STATE_FILE" ]] \
    && "$GUARD_SCRIPT" --manager "$WG_IF" >/dev/null 2>&1
  then
    guard_restored=1
  fi
  if (( MAIN_OLD_SERVICE_ACTIVE == 1 )) && [[ -f "$CONF_FILE" ]]; then
    systemctl start "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  else
    systemctl stop "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  fi
  if (( MAIN_OLD_TIMER_ACTIVE == 1 )); then
    systemctl start "wg-nat-guard@${WG_IF}.timer" >/dev/null 2>&1 || true
  else
    systemctl stop "wg-nat-guard@${WG_IF}.timer" >/dev/null 2>&1 || true
  fi

  if (( guard_restored == 1 )); then
    direct_failsafe remove "${MARK_DEC:-}"
    direct_failsafe remove "$OLD_MARK_DEC"
  elif [[ -z "$OLD_MARK_DEC" ]]; then
    direct_failsafe remove "${MARK_DEC:-}"
    [[ -n "$OLD_RP_ALL" ]] && sysctl -w "net.ipv4.conf.all.rp_filter=${OLD_RP_ALL}" >/dev/null 2>&1 || true
    [[ -n "$OLD_RP_DEFAULT" ]] && sysctl -w "net.ipv4.conf.default.rp_filter=${OLD_RP_DEFAULT}" >/dev/null 2>&1 || true
  else
    echo "⚠️ 旧 guard 未能恢复；保留 failsafe OUTPUT 拒绝规则" >&2
  fi
  rm -rf -- "$MAIN_TX_DIR"
  MAIN_TX_DIR=""
  set -e
}

main_on_exit(){
  local rc=$?
  trap - EXIT ERR
  restore_main_previous_state || true
  exit "$rc"
}

restart_wg(){
  systemctl daemon-reload
  systemctl enable "wg-quick@${WG_IF}" >/dev/null
  if ! systemctl restart "wg-quick@${WG_IF}"; then
    echo "❌ wg-quick@${WG_IF} restart 返回失败，日志如下：" >&2
    systemctl --no-pager --full status "wg-quick@${WG_IF}" >&2 || true
    journalctl -u "wg-quick@${WG_IF}" --no-pager -n 120 >&2 || true
    return 1
  fi

  if ! systemctl is-active --quiet "wg-quick@${WG_IF}"; then
    echo "❌ wg-quick@${WG_IF} 启动失败，日志如下：" >&2
    systemctl --no-pager --full status "wg-quick@${WG_IF}" >&2 || true
    journalctl -u "wg-quick@${WG_IF}" --no-pager -n 120 >&2 || true
    return 1
  fi
  wg show "$WG_IF" >/dev/null 2>&1 || return 1
}

validate_policy_priority_available(){
  local line mark_hex old_hex allowed
  mark_hex="0x$(printf '%x' "$MARK_DEC")"
  old_hex=""
  [[ -n "$OLD_MARK_DEC" ]] && old_hex="0x$(printf '%x' "$OLD_MARK_DEC")"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    allowed=0
    if [[ "$line" =~ fwmark[[:space:]]+(${mark_hex}|${MARK_DEC})(/0xffffffff)? ]] \
      && [[ "$line" =~ lookup[[:space:]]+${TABLE_ID}([[:space:]]|$) ]]; then
      allowed=1
    elif [[ -n "$OLD_MARK_DEC" && "$OLD_TABLE_ID" =~ ^[0-9]+$ ]] \
      && [[ "$line" =~ fwmark[[:space:]]+(${old_hex}|${OLD_MARK_DEC})(/0xffffffff)? ]] \
      && [[ "$line" =~ lookup[[:space:]]+${OLD_TABLE_ID}([[:space:]]|$) ]]; then
      allowed=1
    fi
    (( allowed == 1 )) || fail "RULE_PRIORITY=${RULE_PRIORITY} 被其他规则占用：${line}"
  done < <(ip -4 rule show | awk -v p="${RULE_PRIORITY}:" '$1 == p {print}')
}

validate_active_nat_tuple(){
  local meta landing meta_if expire meta_mark meta_table meta_priority now
  now="$(date +%s)"
  for meta in /var/lib/vless-reality/temp/*.env; do
    [[ -f "$meta" ]] || continue
    landing="$(sed -n 's/^LANDING=//p' "$meta" | head -n1)"
    meta_if="$(sed -n 's/^WG_IF=//p' "$meta" | head -n1)"
    [[ "$landing" == "nat" && "$meta_if" == "$WG_IF" ]] || continue
    expire="$(sed -n 's/^EXPIRE_EPOCH=//p' "$meta" | head -n1)"
    [[ "$expire" =~ ^[0-9]+$ ]] && (( expire <= now )) && continue
    meta_mark="$(sed -n 's/^MARK=//p' "$meta" | head -n1)"
    meta_table="$(sed -n 's/^TABLE_ID=//p' "$meta" | head -n1)"
    meta_priority="$(sed -n 's/^RULE_PRIORITY=//p' "$meta" | head -n1)"
    [[ "$meta_mark" == "$MARK_DEC" && "$meta_table" == "$TABLE_ID" && "$meta_priority" == "$RULE_PRIORITY" ]] \
      || fail "存在使用其他策略 tuple 的活动 NAT 临时节点：$(basename "$meta" .env)"
  done
}

require_supported_platform
validate_ifname "$WG_IF" "WG_IF"
install_packages
require_wireguard_kernel

install -d -m 700 "$WG_DIR"
install -d -m 755 /usr/local/sbin
install -d -m 755 /run/lock /run/vless-reality

# 全局锁顺序固定为 temp -> vps，和临时节点及回填脚本一致。
exec 8>/run/vless-reality/temp.lock
flock -w 120 8 || fail "临时节点创建/清理任务仍在运行"
export VR_TEMP_LOCK_HELD=1
exec 9>"/run/lock/vr-vpswg-${WG_IF}.lock"
flock -w 120 9 || fail "另一个 ${WG_IF} 管理任务仍在运行"

if [[ -f "$STATE_FILE" ]]; then
  [[ "$(stat -c %u "$STATE_FILE" 2>/dev/null || echo -1)" == "0" ]] || fail "状态文件必须属于 root"
  state_mode="$(stat -c %a "$STATE_FILE" 2>/dev/null || echo 777)"
  [[ "$state_mode" =~ ^[0-7]{3,4}$ ]] && (( ((8#$state_mode) & 8#022) == 0 )) || fail "状态文件权限不安全"
fi
merge_saved_runtime_parameters
MARK_DEC="$(norm_mark "$MARK_RAW")"
validate_runtime_parameters

trap 'main_on_exit' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
main_begin_transaction
validate_policy_priority_available
validate_active_nat_tuple

echo "==> 准备 VPS WireGuard 密钥（${WG_IF}）..."
umask 077
if [[ ! -f "$KEY_FILE" ]]; then
  wg genkey | tee "$KEY_FILE" | wg pubkey >"$PUB_FILE"
elif [[ ! -f "$PUB_FILE" ]]; then
  wg pubkey <"$KEY_FILE" >"$PUB_FILE"
fi
chmod 600 "$KEY_FILE" "$PUB_FILE"

VPS_PRIV="$(cat "$KEY_FILE")"
VPS_PUB="$(cat "$PUB_FILE")"
CURRENT_WG_ADDR="$(resolve_current_addr)"

LEGACY_POLICY_MIGRATION_NEEDED=0
if conf_uses_legacy_policy_rule "$CONF_FILE"; then
  LEGACY_POLICY_MIGRATION_NEEDED=1
fi

install -d -m 755 /usr/local/sbin /etc/systemd/system /etc/sysctl.d
GUARD_TMP="$(mktemp /usr/local/sbin/.wg_nat_guard.XXXXXX)"
cat >"$GUARD_TMP" <<'WG_NAT_GUARD'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

fail(){ echo "❌ $*" >&2; exit 1; }
MODE="normal"
case "${1:-}" in
  --watchdog|--manager|--wg-pre) MODE="${1#--}"; shift ;;
esac
WG_IF="${1:-}"
[[ -n "$WG_IF" && ${#WG_IF} -le 15 && "$WG_IF" =~ ^[A-Za-z0-9_.-]+$ && "$WG_IF" != "." && "$WG_IF" != ".." ]] || fail "WG_IF 非法"

install -d -m 755 /run/lock
if [[ "$MODE" == "watchdog" ]]; then
  exec 9>"/run/lock/vr-vpswg-${WG_IF}.lock"
  # WireGuard 管理事务持锁时跳过本轮，避免与 PostUp/PostDown 交错。
  flock -n 9 || exit 0
elif [[ "$MODE" == "normal" ]]; then
  exec 9>"/run/lock/vr-vpswg-${WG_IF}.lock"
  flock -w 120 9 || fail "${WG_IF} 管理锁繁忙"
fi
exec 7>"/run/lock/vr-vpswg-guard-${WG_IF}.lock"
flock -w 30 7 || fail "${WG_IF} guard 锁繁忙"

STATE_FILE="/etc/wireguard/${WG_IF}.env"
[[ -f "$STATE_FILE" ]] || fail "缺少 ${STATE_FILE}"
[[ "$(stat -c %u "$STATE_FILE" 2>/dev/null || echo -1)" == "0" ]] || fail "状态文件必须属于 root"
mode="$(stat -c %a "$STATE_FILE" 2>/dev/null || echo 777)"
[[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( ((8#$mode) & 8#022) == 0 )) || fail "状态文件不能被 group/other 写入"

WG_PORT=""
MARK=""
TABLE_ID=""
RULE_PRIORITY=""
FAILCLOSE_METRIC="42760"
WG_ROUTE_METRIC="10"
while IFS='=' read -r key value; do
  case "$key" in
    WG_PORT) WG_PORT="$value" ;;
    MARK) MARK="$value" ;;
    TABLE_ID) TABLE_ID="$value" ;;
    RULE_PRIORITY) RULE_PRIORITY="$value" ;;
    FAILCLOSE_METRIC) FAILCLOSE_METRIC="$value" ;;
    WG_ROUTE_METRIC) WG_ROUTE_METRIC="$value" ;;
  esac
done <"$STATE_FILE"

for item in "$WG_PORT" "$MARK" "$TABLE_ID" "$RULE_PRIORITY" "$FAILCLOSE_METRIC" "$WG_ROUTE_METRIC"; do
  [[ "$item" =~ ^[0-9]+$ ]] || fail "状态文件含非法数字"
done
(( WG_PORT >= 1 && WG_PORT <= 65535 )) || fail "WG_PORT 非法"
(( MARK >= 1 && MARK <= 4294967295 )) || fail "MARK 非法"
(( TABLE_ID >= 1 && TABLE_ID <= 2147483647 && (TABLE_ID < 253 || TABLE_ID > 255) )) || fail "TABLE_ID 非法或为保留表"
(( RULE_PRIORITY >= 1 && RULE_PRIORITY <= 32765 )) || fail "RULE_PRIORITY 非法"
(( WG_ROUTE_METRIC < FAILCLOSE_METRIC )) || fail "路由 metric 顺序非法"

if [[ "$MODE" != "normal" ]]; then
  sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
  sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
fi
[[ "$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || true)" == "2" ]] || fail "all.rp_filter 未处于 loose 模式"
[[ "$(sysctl -n net.ipv4.conf.default.rp_filter 2>/dev/null || true)" == "2" ]] || fail "default.rp_filter 未处于 loose 模式"

suffix="${WG_IF//[^A-Za-z0-9]/_}"
suffix="${suffix^^}"
INPUT_CHAIN="VRWI_${suffix}"
OUTPUT_CHAIN="VRWO_${suffix}"
(( ${#INPUT_CHAIN} <= 28 && ${#OUTPUT_CHAIN} <= 28 )) || fail "iptables chain 名过长"
INPUT_OWNER="vpswg:${WG_IF}:input"
OUTPUT_OWNER="vpswg:${WG_IF}:output"

declare -A seen=()
MARKS=("$MARK")
seen["$MARK"]=1
now="$(date +%s)"
for meta in /var/lib/vless-reality/temp/*.env; do
  [[ -f "$meta" ]] || continue
  landing="$(sed -n 's/^LANDING=//p' "$meta" | head -n1)"
  meta_if="$(sed -n 's/^WG_IF=//p' "$meta" | head -n1)"
  expire="$(sed -n 's/^EXPIRE_EPOCH=//p' "$meta" | head -n1)"
  meta_mark="$(sed -n 's/^MARK=//p' "$meta" | head -n1)"
  [[ "$landing" == "nat" && "$meta_if" == "$WG_IF" && "$meta_mark" =~ ^[0-9]+$ ]] || continue
  [[ "$expire" =~ ^[0-9]+$ ]] && (( expire <= now )) && continue
  (( meta_mark >= 1 && meta_mark <= 4294967295 )) || continue
  if [[ -z "${seen[$meta_mark]+x}" ]]; then
    MARKS+=("$meta_mark")
    seen["$meta_mark"]=1
  fi
done

# 重建自有 chain 前先装临时直连拒绝规则，避免任何瞬时 fail-open。
for m in "${MARKS[@]}"; do
  comment="vpswg:${WG_IF}:failsafe:${m}"
  iptables -w 5 -C OUTPUT -m mark --mark "${m}/0xffffffff" '!' -o "$WG_IF" -m comment --comment "$comment" -j REJECT --reject-with icmp-net-unreachable >/dev/null 2>&1 \
    || iptables -w 5 -I OUTPUT -m mark --mark "${m}/0xffffffff" '!' -o "$WG_IF" -m comment --comment "$comment" -j REJECT --reject-with icmp-net-unreachable
done

iptables -w 5 -N "$INPUT_CHAIN" 2>/dev/null || true
iptables -w 5 -F "$INPUT_CHAIN"
iptables -w 5 -A "$INPUT_CHAIN" -p udp --dport "$WG_PORT" -j ACCEPT
while iptables -w 5 -D INPUT -m comment --comment "$INPUT_OWNER" -j "$INPUT_CHAIN" >/dev/null 2>&1; do :; done
iptables -w 5 -I INPUT -m comment --comment "$INPUT_OWNER" -j "$INPUT_CHAIN"

iptables -w 5 -N "$OUTPUT_CHAIN" 2>/dev/null || true
iptables -w 5 -F "$OUTPUT_CHAIN"
for m in "${MARKS[@]}"; do
  iptables -w 5 -A "$OUTPUT_CHAIN" -m mark --mark "${m}/0xffffffff" '!' -o "$WG_IF" -j REJECT --reject-with icmp-net-unreachable
done
while iptables -w 5 -D OUTPUT -m comment --comment "$OUTPUT_OWNER" -j "$OUTPUT_CHAIN" >/dev/null 2>&1; do :; done
iptables -w 5 -I OUTPUT -m comment --comment "$OUTPUT_OWNER" -j "$OUTPUT_CHAIN"

if ! ip -4 route show table "$TABLE_ID" \
  | grep -qE "^prohibit default.*metric ${FAILCLOSE_METRIC}([[:space:]]|$)"; then
  ip -4 route add prohibit default metric "$FAILCLOSE_METRIC" table "$TABLE_ID"
fi
while ip -4 rule del priority "$RULE_PRIORITY" fwmark "$MARK" lookup "$TABLE_ID" >/dev/null 2>&1; do :; done
ip -4 rule add priority "$RULE_PRIORITY" fwmark "$MARK" lookup "$TABLE_ID"
if ip link show dev "$WG_IF" >/dev/null 2>&1; then
  while ip -4 route del default dev "$WG_IF" metric "$WG_ROUTE_METRIC" table "$TABLE_ID" >/dev/null 2>&1; do :; done
  ip -4 route add default dev "$WG_IF" metric "$WG_ROUTE_METRIC" table "$TABLE_ID"
fi

for m in "${MARKS[@]}"; do
  comment="vpswg:${WG_IF}:failsafe:${m}"
  while iptables -w 5 -D OUTPUT -m mark --mark "${m}/0xffffffff" '!' -o "$WG_IF" -m comment --comment "$comment" -j REJECT --reject-with icmp-net-unreachable >/dev/null 2>&1; do :; done
  iptables -w 5 -C "$OUTPUT_CHAIN" -m mark --mark "${m}/0xffffffff" '!' -o "$WG_IF" -j REJECT --reject-with icmp-net-unreachable >/dev/null
done
iptables -w 5 -C INPUT -m comment --comment "$INPUT_OWNER" -j "$INPUT_CHAIN" >/dev/null
iptables -w 5 -C OUTPUT -m comment --comment "$OUTPUT_OWNER" -j "$OUTPUT_CHAIN" >/dev/null
ip -4 rule show | grep -qE "^${RULE_PRIORITY}:.*fwmark (0x$(printf '%x' "$MARK")|${MARK})(/0xffffffff)?([[:space:]]|$)"
ip -4 route show table "$TABLE_ID" | grep -qE "^prohibit default.*metric ${FAILCLOSE_METRIC}([[:space:]]|$)"
if ip link show dev "$WG_IF" >/dev/null 2>&1; then
  ip -4 route show table "$TABLE_ID" | grep -qE "^default dev ${WG_IF}.*metric ${WG_ROUTE_METRIC}([[:space:]]|$)"
  ip -4 route get 1.1.1.1 mark "$MARK" 2>/dev/null | grep -qE "\bdev ${WG_IF}\b"
fi
WG_NAT_GUARD
chmod 755 "$GUARD_TMP"
bash -n "$GUARD_TMP"
mv -f -- "$GUARD_TMP" "$GUARD_SCRIPT"

SERVICE_TMP="$(mktemp /etc/systemd/system/.wg-nat-guard-service.XXXXXX)"
cat >"$SERVICE_TMP" <<'WG_GUARD_SERVICE'
[Unit]
Description=Fail-closed guard for marked WireGuard NAT traffic on %i
After=local-fs.target network-pre.target
Before=wg-quick@%i.service
ConditionPathExists=/etc/wireguard/%i.env

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wg_nat_guard.sh --watchdog %i
WG_GUARD_SERVICE
chmod 644 "$SERVICE_TMP"
mv -f -- "$SERVICE_TMP" "$GUARD_SERVICE"

TIMER_TMP="$(mktemp /etc/systemd/system/.wg-nat-guard-timer.XXXXXX)"
cat >"$TIMER_TMP" <<'WG_GUARD_TIMER'
[Unit]
Description=Watch fail-closed WireGuard NAT guard on %i

[Timer]
OnBootSec=15s
OnUnitActiveSec=30s
AccuracySec=5s
RandomizedDelaySec=5s
Unit=wg-nat-guard@%i.service

[Install]
WantedBy=timers.target
WG_GUARD_TIMER
chmod 644 "$TIMER_TMP"
mv -f -- "$TIMER_TMP" "$GUARD_TIMER"

install -d -m 755 "$WG_DROPIN_DIR"
DROPIN_TMP="$(mktemp "${WG_DROPIN_DIR}/.guard-dropin.XXXXXX")"
cat >"$DROPIN_TMP" <<WG_GUARD_DROPIN
[Service]
ExecStartPre=/usr/local/sbin/wg_nat_guard.sh --wg-pre %i
WG_GUARD_DROPIN
chmod 644 "$DROPIN_TMP"
mv -f -- "$DROPIN_TMP" "$WG_DROPIN"

SYSCTL_TMP="$(mktemp /etc/sysctl.d/.99-vr-wg-nat.XXXXXX)"
cat >"$SYSCTL_TMP" <<'SYSCTL'
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
SYSCTL
chmod 644 "$SYSCTL_TMP"
mv -f -- "$SYSCTL_TMP" "$SYSCTL_FILE"
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null

# tuple 变更期间先封住旧 mark；只有新路径完整生效后才删除。
if [[ -n "$OLD_MARK_DEC" ]] \
  && [[ "$OLD_MARK_DEC" != "$MARK_DEC" || "$OLD_TABLE_ID" != "$TABLE_ID" || "$OLD_RULE_PRIORITY" != "$RULE_PRIORITY" ]]
then
  direct_failsafe add "$OLD_MARK_DEC"
fi
save_state "$CURRENT_WG_ADDR"
systemctl daemon-reload
systemctl enable "wg-nat-guard@${WG_IF}.timer" >/dev/null
"$GUARD_SCRIPT" --manager "$WG_IF"

# 第一次部署才写无 Peer 占位配置。
# 如果已经有 Peer，则保留现有配置，避免重复运行脚本把 Peer 擦掉。
tmp_conf="$(mktemp "${CONF_FILE}.tmp.XXXXXX")"
write_base_conf "$CURRENT_WG_ADDR" "$VPS_PRIV" "$tmp_conf"
if [[ -f "$CONF_FILE" ]] && grep -q '^[[:space:]]*\[Peer\][[:space:]]*$' "$CONF_FILE"; then
  echo "==> 检测到现有 Peer：保留 Peer，并刷新 Interface/策略路由参数。"
  awk 'BEGIN{copy=0} /^[[:space:]]*\[Peer\][[:space:]]*$/{copy=1} copy{print}' "$CONF_FILE" >>"$tmp_conf"
else
  echo "==> 写入无 Peer 占位配置；NAT 分配地址后会由回填脚本更新。"
fi
chmod 600 "$tmp_conf"
mv -f -- "$tmp_conf" "$CONF_FILE"

prepare_policy_rule_migration

if ! restart_wg; then
  fail "VPS 端 WireGuard 启动失败，已尽量恢复旧配置和状态"
fi

"$GUARD_SCRIPT" --manager "$WG_IF"
systemctl start "wg-nat-guard@${WG_IF}.timer"
systemctl is-enabled --quiet "wg-nat-guard@${WG_IF}.timer" || fail "wg-nat-guard watchdog timer 未启用"
systemctl is-active --quiet "wg-nat-guard@${WG_IF}.timer" || fail "wg-nat-guard watchdog timer 未运行"
while iptables -w 5 -D INPUT -p udp --dport "$WG_PORT" -m comment --comment "vpswg:${WG_IF}" -j ACCEPT >/dev/null 2>&1; do :; done

SET_PEER_TMP="$(mktemp /usr/local/sbin/.wg_nat_set_peer.XXXXXX)"
cat >"$SET_PEER_TMP" <<'SH_SET_PEER'
#!/usr/bin/env bash
set -Eeuo pipefail

WG_PORT_EXPLICIT="${WG_PORT+x}"
MARK_EXPLICIT="${MARK+x}"
TABLE_ID_EXPLICIT="${TABLE_ID+x}"
RULE_PRIORITY_EXPLICIT="${RULE_PRIORITY+x}"
FAILCLOSE_METRIC_EXPLICIT="${FAILCLOSE_METRIC+x}"
WG_ROUTE_METRIC_EXPLICIT="${WG_ROUTE_METRIC+x}"

WG_IF="${WG_IF:-wg-nat}"
WG_PORT="${WG_PORT:-51820}"
MARK_RAW="${MARK:-2333}"
TABLE_ID="${TABLE_ID:-100}"
RULE_PRIORITY="${RULE_PRIORITY:-31000}"
FAILCLOSE_METRIC="${FAILCLOSE_METRIC:-42760}"
WG_ROUTE_METRIC="${WG_ROUTE_METRIC:-10}"
DEFAULT_WG_ADDR="10.66.66.1/24"

WG_DIR="/etc/wireguard"
CONF_FILE="${WG_DIR}/${WG_IF}.conf"
KEY_FILE="${WG_DIR}/${WG_IF}.key"
STATE_FILE="${WG_DIR}/${WG_IF}.env"

TX_ACTIVE=0
TX_DIR=""
OLD_MARK_DEC=""
OLD_TABLE_ID=""
OLD_RULE_PRIORITY=""
OLD_WG_PORT=""
OLD_FAILCLOSE_METRIC="42760"
OLD_WG_ROUTE_METRIC="10"

on_error(){
  local rc=$?
  echo "❌ ${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}:${BASH_LINENO[0]:-?}: ${BASH_COMMAND}" >&2
  return "$rc"
}
on_exit(){
  local rc=$?
  trap - EXIT ERR
  trap '' INT TERM HUP
  if (( TX_ACTIVE == 1 )) && declare -F restore_previous_peer_state >/dev/null 2>&1; then
    restore_previous_peer_state || true
  fi
  exit "$rc"
}
trap 'on_error' ERR
trap 'on_exit' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

fail(){ echo "❌ $*" >&2; exit 1; }
need_root(){ [[ ${EUID:-0} -eq 0 ]] || fail "请用 root 运行"; }

stop_current_wg_for_rollback(){
  timeout 30 systemctl stop "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  if ip link show dev "$WG_IF" >/dev/null 2>&1; then
    timeout 20 wg-quick down "$WG_IF" >/dev/null 2>&1 || true
  fi
  if ip link show dev "$WG_IF" >/dev/null 2>&1; then
    ip link delete dev "$WG_IF" >/dev/null 2>&1 || true
  fi
}

trim(){
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

norm_mark(){
  local raw="${1,,}"
  raw="${raw//[[:space:]]/}"
  if [[ "$raw" =~ ^0x[0-9a-f]+$ ]]; then
    raw="${raw#0x}"
    (( ${#raw} <= 8 )) || fail "MARK 超出 32 位范围：$1"
    echo "$((16#$raw))"
  elif [[ "$raw" =~ ^[0-9]+$ ]]; then
    (( ${#raw} <= 10 )) || fail "MARK 超出 32 位范围：$1"
    echo "$((10#$raw))"
  else
    fail "MARK 格式不合法：$1"
  fi
}

validate_ifname(){
  local value="$1"
  [[ -n "$value" && ${#value} -le 15 && "$value" =~ ^[A-Za-z0-9_.-]+$ && "$value" != "." && "$value" != ".." ]] \
    || fail "WG_IF 非法：${value}"
}

validate_uint_range(){
  local value="$1" min="$2" max="$3" label="$4"
  [[ "$value" =~ ^[0-9]+$ ]] && (( value >= min && value <= max )) \
    || fail "${label} 必须在 ${min}-${max}：${value}"
}

validate_ipv4(){
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.
  local a b c d n
  read -r a b c d <<<"$ip"
  for n in "$a" "$b" "$c" "$d"; do
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    (( n >= 0 && n <= 255 )) || return 1
  done
}

normalize_addr(){
  local addr="$1" ip
  addr="$(trim "$addr")"
  [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/(24|32)$ ]] \
    || fail "VPS WG 地址必须类似 10.66.66.3/24：$addr"
  ip="${addr%/*}"
  validate_ipv4 "$ip" || fail "VPS WG 地址里的 IPv4 不合法：$addr"
  echo "${ip}/24"
}

state_value(){
  local key="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  sed -n "s/^${key}=//p" "$STATE_FILE" | head -n1
}

merge_saved_runtime_parameters(){
  local saved
  [[ -f "$STATE_FILE" ]] || return 0
  if [[ -z "$WG_PORT_EXPLICIT" ]]; then saved="$(state_value WG_PORT || true)"; [[ -n "$saved" ]] && WG_PORT="$saved"; fi
  if [[ -z "$MARK_EXPLICIT" ]]; then saved="$(state_value MARK || true)"; [[ -n "$saved" ]] && MARK_RAW="$saved"; fi
  if [[ -z "$TABLE_ID_EXPLICIT" ]]; then saved="$(state_value TABLE_ID || true)"; [[ -n "$saved" ]] && TABLE_ID="$saved"; fi
  if [[ -z "$RULE_PRIORITY_EXPLICIT" ]]; then saved="$(state_value RULE_PRIORITY || true)"; [[ -n "$saved" ]] && RULE_PRIORITY="$saved"; fi
  if [[ -z "$FAILCLOSE_METRIC_EXPLICIT" ]]; then saved="$(state_value FAILCLOSE_METRIC || true)"; [[ -n "$saved" ]] && FAILCLOSE_METRIC="$saved"; fi
  if [[ -z "$WG_ROUTE_METRIC_EXPLICIT" ]]; then saved="$(state_value WG_ROUTE_METRIC || true)"; [[ -n "$saved" ]] && WG_ROUTE_METRIC="$saved"; fi
}

conf_address(){
  [[ -f "$CONF_FILE" ]] || return 0
  sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$CONF_FILE" | head -n1
}

save_state(){
  local addr="$1" mark_dec="$2" tmp
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
  cat >"$tmp" <<EOF_STATE
WG_ADDR=${addr}
WG_PORT=${WG_PORT}
MARK=${mark_dec}
TABLE_ID=${TABLE_ID}
RULE_PRIORITY=${RULE_PRIORITY}
FAILCLOSE_METRIC=${FAILCLOSE_METRIC}
WG_ROUTE_METRIC=${WG_ROUTE_METRIC}
EOF_STATE
  mv "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

conf_uses_legacy_policy_rule(){
  local file="${1:-$CONF_FILE}"
  [[ -f "$file" ]] || return 1
  grep -Eq '^[[:space:]]*PostUp[[:space:]]*=[[:space:]]*ip([[:space:]]+-4)?[[:space:]]+rule[[:space:]]+add[[:space:]]+fwmark[[:space:]]+' "$file"
}

remove_owned_policy_rule(){
  local tries=0
  while (( tries < 8 )) \
    && ip -4 rule del priority "$RULE_PRIORITY" fwmark "$MARK_DEC" lookup "$TABLE_ID" >/dev/null 2>&1
  do
    tries=$((tries + 1))
  done
}

remove_legacy_policy_rules(){
  local tries=0
  while (( tries < 32 )) \
    && ip -4 rule del fwmark "$MARK_DEC" lookup "$TABLE_ID" >/dev/null 2>&1
  do
    tries=$((tries + 1))
  done
}

remove_policy_tuple(){
  local priority="$1" mark="$2" table="$3" wg_metric="$4" fail_metric="$5" tries=0
  [[ "$priority" =~ ^[0-9]+$ && "$mark" =~ ^[0-9]+$ && "$table" =~ ^[0-9]+$ ]] || return 0
  while (( tries < 16 )) && ip -4 rule del priority "$priority" fwmark "$mark" lookup "$table" >/dev/null 2>&1; do
    tries=$((tries + 1))
  done
  ip -4 route del default dev "$WG_IF" metric "$wg_metric" table "$table" >/dev/null 2>&1 || true
  ip -4 route del prohibit default metric "$fail_metric" table "$table" >/dev/null 2>&1 || true
}

install_direct_failsafe(){
  local mark="$1" comment
  [[ "$mark" =~ ^[0-9]+$ ]] || return 0
  comment="vpswg:${WG_IF}:failsafe:${mark}"
  iptables -w 5 -C OUTPUT -m mark --mark "${mark}/0xffffffff" '!' -o "$WG_IF" \
    -m comment --comment "$comment" -j REJECT --reject-with icmp-net-unreachable >/dev/null 2>&1 \
    || iptables -w 5 -I OUTPUT -m mark --mark "${mark}/0xffffffff" '!' -o "$WG_IF" \
      -m comment --comment "$comment" -j REJECT --reject-with icmp-net-unreachable
}

remove_direct_failsafe(){
  local mark="$1" comment
  [[ "$mark" =~ ^[0-9]+$ ]] || return 0
  comment="vpswg:${WG_IF}:failsafe:${mark}"
  while iptables -w 5 -D OUTPUT -m mark --mark "${mark}/0xffffffff" '!' -o "$WG_IF" \
    -m comment --comment "$comment" -j REJECT --reject-with icmp-net-unreachable >/dev/null 2>&1
  do :; done
}

prepare_policy_rule_migration(){
  if [[ -n "$OLD_MARK_DEC" ]] \
    && [[ "$OLD_MARK_DEC" != "$MARK_DEC" || "$OLD_TABLE_ID" != "$TABLE_ID" || "$OLD_RULE_PRIORITY" != "$RULE_PRIORITY" \
          || "$OLD_WG_ROUTE_METRIC" != "$WG_ROUTE_METRIC" || "$OLD_FAILCLOSE_METRIC" != "$FAILCLOSE_METRIC" ]]
  then
    remove_policy_tuple "$OLD_RULE_PRIORITY" "$OLD_MARK_DEC" "$OLD_TABLE_ID" "$OLD_WG_ROUTE_METRIC" "$OLD_FAILCLOSE_METRIC"
  fi
  if (( LEGACY_POLICY_MIGRATION_NEEDED == 1 )); then
    echo "⚠️ 检测到旧版无固定优先级策略规则，执行一次迁移清理" >&2
    remove_legacy_policy_rules
  fi
}

restore_previous_peer_state(){
  TX_ACTIVE=0
  set +e
  rm -f -- "${CONF_TMP:-}" >/dev/null 2>&1 || true
  install_direct_failsafe "$MARK_DEC"
  install_direct_failsafe "$OLD_MARK_DEC"
  stop_current_wg_for_rollback
  # The new transaction may have enabled a previously absent unit.  Remove
  # that link before restoring the exact pre-transaction enabled state.
  systemctl disable "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  remove_policy_tuple "$RULE_PRIORITY" "$MARK_DEC" "$TABLE_ID" "$WG_ROUTE_METRIC" "$FAILCLOSE_METRIC"

  if [[ -n "$backup" && -s "$backup" ]]; then
    cp -a "$backup" "$CONF_FILE"
  else
    rm -f "$CONF_FILE"
  fi

  if (( had_state == 1 )) && [[ -n "$state_backup" && -s "$state_backup" ]]; then
    cp -a "$state_backup" "$STATE_FILE"
  else
    rm -f "$STATE_FILE"
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
  case "$old_service_enabled" in
    enabled) systemctl enable "wg-quick@${WG_IF}" >/dev/null 2>&1 || true ;;
    enabled-runtime) systemctl enable --runtime "wg-quick@${WG_IF}" >/dev/null 2>&1 || true ;;
    disabled) systemctl disable "wg-quick@${WG_IF}" >/dev/null 2>&1 || true ;;
    masked) systemctl mask "wg-quick@${WG_IF}" >/dev/null 2>&1 || true ;;
    masked-runtime) systemctl mask --runtime "wg-quick@${WG_IF}" >/dev/null 2>&1 || true ;;
  esac

  if (( old_service_active == 1 )) && [[ -n "$backup" && -s "$backup" ]]; then
    systemctl start "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  else
    systemctl stop "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  fi
  if [[ -x /usr/local/sbin/wg_nat_guard.sh && -f "$STATE_FILE" ]] \
    && /usr/local/sbin/wg_nat_guard.sh --manager "$WG_IF" >/dev/null 2>&1
  then
    remove_direct_failsafe "$MARK_DEC"
    remove_direct_failsafe "$OLD_MARK_DEC"
  else
    echo "⚠️ 旧 guard 未能恢复；保留 failsafe OUTPUT 拒绝规则" >&2
  fi
  rm -rf -- "$TX_DIR"
  TX_DIR=""
  set -e
}

need_root
validate_ifname "$WG_IF"
command -v flock >/dev/null 2>&1 || fail "缺少 flock"
install -d -m 755 /run/lock
install -d -m 755 /run/vless-reality
exec 8>/run/vless-reality/temp.lock
flock -w 120 8 || fail "临时节点创建/清理任务仍在运行"
export VR_TEMP_LOCK_HELD=1
exec 9>"/run/lock/vr-vpswg-${WG_IF}.lock"
flock -w 120 9 || fail "另一个 ${WG_IF} 管理任务仍在运行"
if [[ -f "$STATE_FILE" ]]; then
  [[ "$(stat -c %u "$STATE_FILE" 2>/dev/null || echo -1)" == "0" ]] || fail "状态文件必须属于 root"
  state_mode="$(stat -c %a "$STATE_FILE" 2>/dev/null || echo 777)"
  [[ "$state_mode" =~ ^[0-7]{3,4}$ ]] && (( ((8#$state_mode) & 8#022) == 0 )) || fail "状态文件权限不安全"
  old_mark_raw="$(state_value MARK || true)"
  OLD_TABLE_ID="$(state_value TABLE_ID || true)"
  OLD_RULE_PRIORITY="$(state_value RULE_PRIORITY || true)"
  OLD_WG_PORT="$(state_value WG_PORT || true)"
  OLD_FAILCLOSE_METRIC="$(state_value FAILCLOSE_METRIC || true)"
  OLD_WG_ROUTE_METRIC="$(state_value WG_ROUTE_METRIC || true)"
  OLD_FAILCLOSE_METRIC="${OLD_FAILCLOSE_METRIC:-42760}"
  OLD_WG_ROUTE_METRIC="${OLD_WG_ROUTE_METRIC:-10}"
  [[ -n "$old_mark_raw" ]] && OLD_MARK_DEC="$(norm_mark "$old_mark_raw")"
fi
merge_saved_runtime_parameters

NAT_PUB="${1:-}"
ASSIGNED_ADDR="${2:-}"
[[ -n "$NAT_PUB" ]] || {
  echo "用法: wg_nat_set_peer.sh <NAT_PUBLIC_KEY> [VPS_WG_ADDR]"
  echo "通常直接复制 NAT 机 nat.sh add 成功后打印的完整命令。"
  exit 1
}

NAT_PUB="${NAT_PUB//[[:space:]]/}"
NAT_PUB="${NAT_PUB//\"/}"
NAT_PUB="${NAT_PUB#<}"
NAT_PUB="${NAT_PUB%>}"

[[ "$NAT_PUB" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
  || fail "NAT_PUB 不是合法的 WireGuard 公钥：${NAT_PUB}"

[[ -f "$KEY_FILE" ]] || fail "缺少 ${KEY_FILE}，请先执行 vpswg.sh"

# 地址优先级：
# 1. NAT 打印命令传入的第二参数
# 2. 显式环境变量 WG_ADDR
# 3. 已保存 state
# 4. 现有配置 Address
# 5. 默认 .1（仅兼容第一台/旧流程）
if [[ -n "$ASSIGNED_ADDR" ]]; then
  WG_ADDR_FINAL="$(normalize_addr "$ASSIGNED_ADDR")"
elif [[ -n "${WG_ADDR:-}" ]]; then
  WG_ADDR_FINAL="$(normalize_addr "$WG_ADDR")"
elif [[ -n "$(state_value WG_ADDR || true)" ]]; then
  WG_ADDR_FINAL="$(normalize_addr "$(state_value WG_ADDR)")"
elif [[ -n "$(conf_address || true)" ]]; then
  WG_ADDR_FINAL="$(normalize_addr "$(conf_address)")"
else
  WG_ADDR_FINAL="$DEFAULT_WG_ADDR"
fi

MARK_DEC="$(norm_mark "$MARK_RAW")"
validate_ifname "$WG_IF"
validate_uint_range "$WG_PORT" 1 65535 "WG_PORT"
validate_uint_range "$TABLE_ID" 1 2147483647 "TABLE_ID"
(( TABLE_ID < 253 || TABLE_ID > 255 )) || fail "TABLE_ID 不能使用 253-255 保留表"
validate_uint_range "$RULE_PRIORITY" 1 32765 "RULE_PRIORITY"
validate_uint_range "$MARK_DEC" 1 4294967295 "MARK"
validate_uint_range "$FAILCLOSE_METRIC" 1 4294967295 "FAILCLOSE_METRIC"
validate_uint_range "$WG_ROUTE_METRIC" 0 4294967295 "WG_ROUTE_METRIC"
(( WG_ROUTE_METRIC < FAILCLOSE_METRIC )) || fail "WG_ROUTE_METRIC 必须小于 FAILCLOSE_METRIC"
mark_hex="0x$(printf '%x' "$MARK_DEC")"
old_mark_hex=""
[[ -n "$OLD_MARK_DEC" ]] && old_mark_hex="0x$(printf '%x' "$OLD_MARK_DEC")"
while IFS= read -r priority_line; do
  [[ -n "$priority_line" ]] || continue
  allowed=0
  if [[ "$priority_line" =~ fwmark[[:space:]]+(${mark_hex}|${MARK_DEC})(/0xffffffff)? ]] \
    && [[ "$priority_line" =~ lookup[[:space:]]+${TABLE_ID}([[:space:]]|$) ]]; then
    allowed=1
  elif [[ -n "$OLD_MARK_DEC" ]] \
    && [[ "$priority_line" =~ fwmark[[:space:]]+(${old_mark_hex}|${OLD_MARK_DEC})(/0xffffffff)? ]] \
    && [[ "$priority_line" =~ lookup[[:space:]]+${OLD_TABLE_ID}([[:space:]]|$) ]]; then
    allowed=1
  fi
  (( allowed == 1 )) || fail "RULE_PRIORITY=${RULE_PRIORITY} 被其他规则占用：${priority_line}"
done < <(ip -4 rule show | awk -v p="${RULE_PRIORITY}:" '$1 == p {print}')
for temp_meta in /var/lib/vless-reality/temp/*.env; do
  [[ -f "$temp_meta" ]] || continue
  [[ "$(sed -n 's/^LANDING=//p' "$temp_meta" | head -n1)" == "nat" ]] || continue
  [[ "$(sed -n 's/^WG_IF=//p' "$temp_meta" | head -n1)" == "$WG_IF" ]] || continue
  temp_expire="$(sed -n 's/^EXPIRE_EPOCH=//p' "$temp_meta" | head -n1)"
  [[ "$temp_expire" =~ ^[0-9]+$ ]] && (( temp_expire <= $(date +%s) )) && continue
  [[ "$(sed -n 's/^MARK=//p' "$temp_meta" | head -n1)" == "$MARK_DEC" \
     && "$(sed -n 's/^TABLE_ID=//p' "$temp_meta" | head -n1)" == "$TABLE_ID" \
     && "$(sed -n 's/^RULE_PRIORITY=//p' "$temp_meta" | head -n1)" == "$RULE_PRIORITY" ]] \
    || fail "存在使用旧策略 tuple 的活动 NAT 临时节点：$(basename "$temp_meta" .env)"
done
VPS_PRIV="$(cat "$KEY_FILE")"

backup=""
state_backup=""
had_state=0
old_service_active=0
old_service_enabled="$(systemctl is-enabled "wg-quick@${WG_IF}" 2>/dev/null || true)"
if systemctl is-active --quiet "wg-quick@${WG_IF}"; then
  old_service_active=1
fi
LEGACY_POLICY_MIGRATION_NEEDED=0
if conf_uses_legacy_policy_rule "$CONF_FILE"; then
  LEGACY_POLICY_MIGRATION_NEEDED=1
fi
TX_DIR="$(mktemp -d /var/tmp/vr-wg-peer-transaction.XXXXXX)"
if [[ -f "$CONF_FILE" ]]; then
  backup="${TX_DIR}/wg.conf"
  cp -a "$CONF_FILE" "$backup"
fi
if [[ -f "$STATE_FILE" ]]; then
  had_state=1
  state_backup="${TX_DIR}/wg.env"
  cp -a "$STATE_FILE" "$state_backup"
fi
TX_ACTIVE=1

CONF_TMP="$(mktemp "${CONF_FILE}.tmp.XXXXXX")"
cat >"$CONF_TMP" <<CFG
[Interface]
Address = ${WG_ADDR_FINAL}
ListenPort = ${WG_PORT}
PrivateKey = ${VPS_PRIV}
Table = off

PostUp = sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
PostUp = sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1 || true

PostUp = ip -4 rule del priority ${RULE_PRIORITY} fwmark ${MARK_DEC} lookup ${TABLE_ID} 2>/dev/null || true
PostUp = ip -4 rule add priority ${RULE_PRIORITY} fwmark ${MARK_DEC} lookup ${TABLE_ID}
PostUp = ip -4 route show table ${TABLE_ID} | grep -qE "^prohibit default.*metric ${FAILCLOSE_METRIC}([[:space:]]|$)" || ip -4 route add prohibit default metric ${FAILCLOSE_METRIC} table ${TABLE_ID}
PostUp = ip -4 route del default dev %i metric ${WG_ROUTE_METRIC} table ${TABLE_ID} 2>/dev/null || true
PostUp = ip -4 route add default dev %i metric ${WG_ROUTE_METRIC} table ${TABLE_ID}

PostDown = ip -4 route del default dev %i metric ${WG_ROUTE_METRIC} table ${TABLE_ID} 2>/dev/null || true
PostDown = ip -4 route show table ${TABLE_ID} | grep -qE "^prohibit default.*metric ${FAILCLOSE_METRIC}([[:space:]]|$)" || ip -4 route add prohibit default metric ${FAILCLOSE_METRIC} table ${TABLE_ID}

[Peer]
PublicKey = ${NAT_PUB}
AllowedIPs = 0.0.0.0/0
CFG

chmod 600 "$CONF_TMP"
save_state "$WG_ADDR_FINAL" "$MARK_DEC"
[[ -x /usr/local/sbin/wg_nat_guard.sh ]] || fail "缺少 /usr/local/sbin/wg_nat_guard.sh，请重新运行 vpswg.sh"
/usr/local/sbin/wg_nat_guard.sh --manager "$WG_IF"
mv -f "$CONF_TMP" "$CONF_FILE"

prepare_policy_rule_migration
systemctl daemon-reload
systemctl enable "wg-quick@${WG_IF}" >/dev/null
systemctl restart "wg-quick@${WG_IF}"

if ! systemctl is-active --quiet "wg-quick@${WG_IF}"; then
  systemctl --no-pager --full status "wg-quick@${WG_IF}" >&2 || true
  journalctl -u "wg-quick@${WG_IF}" --no-pager -n 120 >&2 || true
  fail "回填 NAT Peer 失败"
fi

/usr/local/sbin/wg_nat_guard.sh --manager "$WG_IF"
for legacy_port in "$OLD_WG_PORT" "$WG_PORT"; do
  [[ "$legacy_port" =~ ^[0-9]+$ ]] || continue
  while iptables -w 5 -D INPUT -p udp --dport "$legacy_port" -m comment --comment "vpswg:${WG_IF}" -j ACCEPT >/dev/null 2>&1; do :; done
done

TX_ACTIVE=0
rm -rf -- "$TX_DIR"
TX_DIR=""

echo "✅ 已回填 NAT 公钥并启动 ${WG_IF}"
echo "VPS WG 地址: ${WG_ADDR_FINAL}"
echo "下一步可执行：/usr/local/sbin/wg_nat_healthcheck.sh"
SH_SET_PEER
chmod 755 "$SET_PEER_TMP"
bash -n "$SET_PEER_TMP"

HEALTH_TMP="$(mktemp /usr/local/sbin/.wg_nat_healthcheck.XXXXXX)"
cat >"$HEALTH_TMP" <<'SH_HEALTH'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

MARK_EXPLICIT="${MARK+x}"
TABLE_ID_EXPLICIT="${TABLE_ID+x}"
RULE_PRIORITY_EXPLICIT="${RULE_PRIORITY+x}"
FAILCLOSE_METRIC_EXPLICIT="${FAILCLOSE_METRIC+x}"
WG_ROUTE_METRIC_EXPLICIT="${WG_ROUTE_METRIC+x}"

WG_IF="${WG_IF:-wg-nat}"
MARK_RAW="${MARK:-2333}"
TABLE_ID="${TABLE_ID:-100}"
RULE_PRIORITY="${RULE_PRIORITY:-31000}"
FAILCLOSE_METRIC="${FAILCLOSE_METRIC:-42760}"
WG_ROUTE_METRIC="${WG_ROUTE_METRIC:-10}"
HANDSHAKE_MAX="${HANDSHAKE_MAX:-180}"
STATE_FILE="/etc/wireguard/${WG_IF}.env"

fail(){ echo "❌ $*" >&2; exit 1; }
need_root(){ [[ ${EUID:-0} -eq 0 ]] || fail "请用 root 运行"; }

norm_mark(){
  local raw="${1,,}"
  raw="${raw//[[:space:]]/}"
  if [[ "$raw" =~ ^0x[0-9a-f]+$ ]]; then
    raw="${raw#0x}"
    (( ${#raw} <= 8 )) || fail "MARK 超出 32 位范围：$1"
    echo "$((16#$raw))"
  elif [[ "$raw" =~ ^[0-9]+$ ]]; then
    (( ${#raw} <= 10 )) || fail "MARK 超出 32 位范围：$1"
    echo "$((10#$raw))"
  else
    fail "MARK 格式不合法：$1"
  fi
}

validate_ifname(){
  [[ -n "$1" && ${#1} -le 15 && "$1" =~ ^[A-Za-z0-9_.-]+$ && "$1" != "." && "$1" != ".." ]] \
    || fail "WG_IF 非法：$1"
}
validate_uint_range(){
  local value="$1" min="$2" max="$3" label="$4"
  [[ "$value" =~ ^[0-9]+$ ]] && (( value >= min && value <= max )) \
    || fail "${label} 必须在 ${min}-${max}：${value}"
}
state_value(){
  local key="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  sed -n "s/^${key}=//p" "$STATE_FILE" | head -n1
}
merge_saved_runtime_parameters(){
  local saved
  [[ -f "$STATE_FILE" ]] || return 0
  if [[ -z "$MARK_EXPLICIT" ]]; then saved="$(state_value MARK || true)"; [[ -n "$saved" ]] && MARK_RAW="$saved"; fi
  if [[ -z "$TABLE_ID_EXPLICIT" ]]; then saved="$(state_value TABLE_ID || true)"; [[ -n "$saved" ]] && TABLE_ID="$saved"; fi
  if [[ -z "$RULE_PRIORITY_EXPLICIT" ]]; then saved="$(state_value RULE_PRIORITY || true)"; [[ -n "$saved" ]] && RULE_PRIORITY="$saved"; fi
  if [[ -z "$FAILCLOSE_METRIC_EXPLICIT" ]]; then saved="$(state_value FAILCLOSE_METRIC || true)"; [[ -n "$saved" ]] && FAILCLOSE_METRIC="$saved"; fi
  if [[ -z "$WG_ROUTE_METRIC_EXPLICIT" ]]; then saved="$(state_value WG_ROUTE_METRIC || true)"; [[ -n "$saved" ]] && WG_ROUTE_METRIC="$saved"; fi
}

need_root
validate_ifname "$WG_IF"
merge_saved_runtime_parameters
MARK_DEC="$(norm_mark "$MARK_RAW")"
validate_ifname "$WG_IF"
validate_uint_range "$TABLE_ID" 1 2147483647 "TABLE_ID"
validate_uint_range "$RULE_PRIORITY" 1 32765 "RULE_PRIORITY"
validate_uint_range "$HANDSHAKE_MAX" 1 86400 "HANDSHAKE_MAX"
validate_uint_range "$MARK_DEC" 1 4294967295 "MARK"
validate_uint_range "$FAILCLOSE_METRIC" 1 4294967295 "FAILCLOSE_METRIC"
validate_uint_range "$WG_ROUTE_METRIC" 0 4294967295 "WG_ROUTE_METRIC"
(( WG_ROUTE_METRIC < FAILCLOSE_METRIC )) || fail "路由 metric 顺序非法"
MARK_HEX="$(printf '0x%x' "$MARK_DEC")"

ip link show dev "$WG_IF" >/dev/null 2>&1 \
  || fail "接口 $WG_IF 不存在/未启动：systemctl restart wg-quick@${WG_IF}"

# Healthcheck is also the preflight used by the NAT-node creator.  Repair the
# owned route/firewall state before testing it, so a recently flushed ruleset
# does not cause a false deployment failure while waiting for the next timer.
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
[[ -x /usr/local/sbin/wg_nat_guard.sh ]] || fail "缺少 wg_nat_guard.sh"
/usr/local/sbin/wg_nat_guard.sh "$WG_IF"

echo "---- route test (mark=${MARK_DEC}) ----"
RG="$(ip route get 1.1.1.1 mark "$MARK_DEC" 2>/dev/null || true)"
echo "${RG:-<empty>}"
grep -qE "\bdev ${WG_IF}\b" <<<"$RG" \
  || { echo "---- ip rule ----" >&2; ip rule show >&2 || true; fail "策略路由未走 ${WG_IF}（mark=${MARK_DEC}）"; }

echo "---- ip rule (fwmark -> table) ----"
if ip -4 rule | grep -qE "^${RULE_PRIORITY}:.*fwmark (${MARK_HEX}|${MARK_DEC}).*lookup ${TABLE_ID}"; then
  echo "OK: ip rule 存在"
else
  echo "⚠️ 未找到预期 ip rule（可能 wg-quick PostUp 未执行）"
fi

echo "---- fail-closed guard ----"
ip -4 route show table "$TABLE_ID" | grep -qE "^default dev ${WG_IF}.*metric ${WG_ROUTE_METRIC}([[:space:]]|$)" \
  || fail "table ${TABLE_ID} 缺少 WireGuard 默认路由"
ip -4 route show table "$TABLE_ID" | grep -qE "^prohibit default.*metric ${FAILCLOSE_METRIC}([[:space:]]|$)" \
  || fail "table ${TABLE_ID} 缺少 prohibit fail-closed 路由"
systemctl is-enabled --quiet "wg-nat-guard@${WG_IF}.timer" || fail "fail-closed watchdog timer 未启用"
systemctl is-active --quiet "wg-nat-guard@${WG_IF}.timer" || fail "fail-closed watchdog timer 未运行"

echo "---- wg show ----"
wg show "$WG_IF" || true

PEERS="$(wg show "$WG_IF" peers 2>/dev/null | wc -l | tr -d ' ')"
(( ${PEERS:-0} > 0 )) || fail "wg-nat 尚未配置 peer：请先执行 NAT 机打印的回填命令"

echo "---- handshake check ----"
HS="$(wg show "$WG_IF" latest-handshakes | awk 'NF>=2{print $2}' | sort -nr | head -n1 || true)"
[[ -n "$HS" ]] || fail "读不到握手时间"
(( HS > 0 )) || fail "从未握手。检查 NAT 机 wg-exit、UDP/${WG_PORT:-51820}、公钥和 Endpoint"

NOW="$(date +%s)"
AGE="$((NOW - HS))"
(( AGE <= HANDSHAKE_MAX )) \
  || fail "握手过旧：${AGE}s（> ${HANDSHAKE_MAX}s）。检查 NAT 机 wg-exit 和 UDP 51820"

echo "---- marked HTTP exit-ip test ----"
EXIT_IP="$(
  python3 - "$MARK_DEC" <<'PY'
import re
import socket
import sys

mark = int(sys.argv[1])
SO_MARK = getattr(socket, "SO_MARK", 36)
targets = [
    ("api.ipify.org", 80, "/"),
    ("ifconfig.me", 80, "/ip"),
    ("ipv4.icanhazip.com", 80, "/"),
]

for host, port, path in targets:
    try:
        infos = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)
    except OSError:
        continue

    for family, socktype, proto, _, sockaddr in infos:
        s = socket.socket(family, socktype, proto)
        try:
            s.settimeout(8)
            s.setsockopt(socket.SOL_SOCKET, SO_MARK, mark)
            s.connect(sockaddr)
            req = (
                "GET {} HTTP/1.1\r\n"
                "Host: {}\r\n"
                "User-Agent: wg-nat-healthcheck/1.0\r\n"
                "Connection: close\r\n\r\n"
            ).format(path, host).encode()
            s.sendall(req)
            chunks = []
            while True:
                part = s.recv(4096)
                if not part:
                    break
                chunks.append(part)
            data = b"".join(chunks)
            body = data.split(b"\r\n\r\n", 1)[-1].decode("ascii", "ignore")
            m = re.search(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", body)
            if m:
                print(m.group(0))
                raise SystemExit(0)
        except OSError:
            pass
        finally:
            s.close()

raise SystemExit(1)
PY
)" || true

[[ -n "$EXIT_IP" ]] || fail "带 mark 的真实出网测试失败。检查策略路由、NAT 机转发/MASQUERADE 和握手状态"
echo "OK EXIT_IP=${EXIT_IP}"
SH_HEALTH
chmod 755 "$HEALTH_TMP"
bash -n "$HEALTH_TMP"

trap '' INT TERM HUP
mv -f -- "$SET_PEER_TMP" "$SET_PEER_SCRIPT"
mv -f -- "$HEALTH_TMP" "$HEALTH_SCRIPT"
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify "$GUARD_SERVICE" "$GUARD_TIMER" >/dev/null
fi
if [[ -n "$OLD_MARK_DEC" ]] \
  && [[ "$OLD_MARK_DEC" != "$MARK_DEC" || "$OLD_TABLE_ID" != "$TABLE_ID" || "$OLD_RULE_PRIORITY" != "$RULE_PRIORITY" ]]
then
  direct_failsafe remove "$OLD_MARK_DEC"
fi
MAIN_TX_ACTIVE=0
rm -rf -- "$MAIN_TX_DIR"
MAIN_TX_DIR=""

echo
echo "✅ VPS 端 WG-NAT 部署完成。"
echo "当前 VPS WG 地址（初始/已保存）: ${CURRENT_WG_ADDR}"
echo "==================== VPS WG 公钥 ===================="
echo "${VPS_PUB}"
echo "======================================================"
echo
echo "下一步：去 NAT 机执行（不需要填写 10.66.66.X/32）："
echo "bash /root/nat.sh add <name> <VPS域名或IP> '${VPS_PUB}'"
echo
echo "例如："
echo "bash /root/nat.sh add hy2 hy2.liucna.com '${VPS_PUB}'"
echo
echo "NAT 成功后会打印一条完整的 wg_nat_set_peer.sh 命令；回到本机原样执行即可。"
