#!/usr/bin/env bash
# Final four-file edition: installs the NAT-egress temporary VLESS node creator.
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
umask 077

INSTALL_TX_ACTIVE=0
INSTALL_TX_DIR=""
PREFLIGHT_TARGET="/usr/local/sbin/vless_nat_preflight.sh"
CREATOR_TARGET="/usr/local/sbin/vless_mktemp_nat.sh"

install_rollback() {
  (( INSTALL_TX_ACTIVE == 1 )) || return 0
  INSTALL_TX_ACTIVE=0
  set +e
  local target key
  rm -f -- "${PREFLIGHT_TMP:-}" "${CREATOR_TMP:-}" 2>/dev/null
  for target in "$PREFLIGHT_TARGET" "$CREATOR_TARGET"; do
    key="$(basename "$target")"
    rm -f -- "$target"
    if [[ -e "${INSTALL_TX_DIR}/${key}.old" || -L "${INSTALL_TX_DIR}/${key}.old" ]]; then
      cp -a -- "${INSTALL_TX_DIR}/${key}.old" "$target"
    fi
  done
  rm -rf -- "$INSTALL_TX_DIR"
}

install_on_exit() {
  local rc=$?
  trap - EXIT ERR
  trap '' INT TERM HUP
  install_rollback || true
  exit "$rc"
}

trap 'install_on_exit' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

[[ ${EUID:-0} -eq 0 ]] || { echo "❌ 请用 root 运行" >&2; exit 1; }
for f in common.sh quota-lib.sh iplimit-lib.sh; do
  [[ -r "/usr/local/lib/vless-reality/${f}" ]] || {
    echo "❌ 缺少 /usr/local/lib/vless-reality/${f}，请先运行同一最终包中的 vless.sh" >&2
    exit 1
  }
done
[[ -x /usr/local/sbin/vless_cleanup_one.sh && -x /usr/local/sbin/vless_run_temp.sh ]] || {
  echo "❌ 临时节点管理组件不完整，请先运行 vless.sh" >&2
  exit 1
}
[[ -x /usr/local/sbin/wg_nat_guard.sh && -x /usr/local/sbin/wg_nat_healthcheck.sh ]] || {
  echo "❌ WireGuard NAT guard/healthcheck 不完整，请先运行同一修复包中的 vpswg.sh" >&2
  exit 1
}

install -d -m 755 /usr/local/sbin /run/lock
exec 9>/run/lock/vless-nat-module-install.lock
flock -w 120 9 || { echo "❌ NAT 临时节点模块安装锁繁忙" >&2; exit 1; }
INSTALL_TX_DIR="$(mktemp -d /var/tmp/vless-nat-module-transaction.XXXXXX)"
for install_target in "$PREFLIGHT_TARGET" "$CREATOR_TARGET"; do
  if [[ -e "$install_target" || -L "$install_target" ]]; then
    cp -a -- "$install_target" "${INSTALL_TX_DIR}/$(basename "$install_target").old"
  fi
done
PREFLIGHT_TMP=""
CREATOR_TMP=""
INSTALL_TX_ACTIVE=1
PREFLIGHT_TMP="$(mktemp /usr/local/sbin/.vless_nat_preflight.XXXXXX)"
CREATOR_TMP="$(mktemp /usr/local/sbin/.vless_mktemp_nat.XXXXXX)"

cat >"$PREFLIGHT_TMP" <<'NAT_PREFLIGHT'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh

TAG="${1:?need TAG}"
vr_is_valid_temp_tag "$TAG" || vr_die "非法临时节点 TAG：${TAG}"
META="$(vr_temp_meta_file "$TAG")"
[[ -f "$META" ]] || vr_die "meta 不存在：${META}"
WG_IF="$(vr_meta_get "$META" WG_IF || true)"
MARK="$(vr_meta_get "$META" MARK || true)"
TABLE_ID="$(vr_meta_get "$META" TABLE_ID || true)"
RULE_PRIORITY="$(vr_meta_get "$META" RULE_PRIORITY || true)"
HANDSHAKE_MAX="$(vr_meta_get "$META" HANDSHAKE_MAX 2>/dev/null || true)"
HANDSHAKE_MAX="${HANDSHAKE_MAX:-180}"
[[ -n "$WG_IF" && "$MARK" =~ ^[0-9]+$ && "$TABLE_ID" =~ ^[0-9]+$ && "$RULE_PRIORITY" =~ ^[0-9]+$ ]] \
  || vr_die "NAT meta 缺少策略路由参数"
[[ "$HANDSHAKE_MAX" =~ ^[0-9]+$ ]] && (( HANDSHAKE_MAX >= 1 && HANDSHAKE_MAX <= 86400 )) || vr_die "HANDSHAKE_MAX 非法"
systemctl is-active --quiet "wg-quick@${WG_IF}.service" || vr_die "wg-quick@${WG_IF} 未运行"
[[ -x /usr/local/sbin/wg_nat_guard.sh ]] || vr_die "缺少 wg_nat_guard.sh"
/usr/local/sbin/wg_nat_guard.sh "$WG_IF"
ROUTE_RESULT="$(ip route get 1.1.1.1 mark "$MARK" 2>/dev/null || true)"
grep -qE "\bdev ${WG_IF}\b" <<<"$ROUTE_RESULT" \
  || vr_die "marked route 未走 ${WG_IF}"
HS="$(wg show "$WG_IF" latest-handshakes 2>/dev/null | awk 'NF>=2{print $2}' | sort -nr | head -n1 || true)"
[[ "$HS" =~ ^[0-9]+$ ]] && (( HS > 0 && $(date +%s) - HS <= HANDSHAKE_MAX )) \
  || vr_die "WireGuard 握手不存在或已超过 ${HANDSHAKE_MAX}s"
NAT_PREFLIGHT

cat >"$CREATOR_TMP" <<'__NAT_MKTEMP_FINAL__'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
CURRENT_ATTEMPT_ACTIVE=0

MARK_EXPLICIT="${MARK+x}"
TABLE_ID_EXPLICIT="${TABLE_ID+x}"
RULE_PRIORITY_EXPLICIT="${RULE_PRIORITY+x}"

rollback_current() {
  CURRENT_ATTEMPT_ACTIVE=0
  if ! FORCE=1 VR_TEMP_LOCK_HELD=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" >/dev/null 2>&1; then
    echo "❌ ${TAG} 回滚未完成；已停止重试，保留 meta 供 watchdog/GC 继续清理" >&2
    return 1
  fi
}

on_error() {
  local rc=$?
  trap - ERR
  echo "❌ ${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}:${BASH_LINENO[0]:-?}: ${BASH_COMMAND}" >&2
  exit "$rc"
}

on_exit() {
  local rc=$?
  trap - EXIT ERR
  trap '' INT TERM HUP
  if (( CURRENT_ATTEMPT_ACTIVE == 1 )) && declare -F rollback_current >/dev/null 2>&1; then
    rollback_current || true
  fi
  exit "$rc"
}
trap 'on_error' ERR
trap 'on_exit' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/iplimit-lib.sh

vr_require_root_supported_os
vr_ensure_runtime_dirs

: "${D:?请用 D=秒 调用，例如：id=nat6 IP_VERSION=6 MARK=2333 D=1200 vless_mktemp_nat.sh}"
DURATION="$D"
PQ_GIB="${PQ_GIB:-}"
IP_LIMIT="${IP_LIMIT:-0}"
IP_STICKY_SECONDS="${IP_STICKY_SECONDS:-120}"
IP_VERSION="${IP_VERSION:-4}"
WG_IF="${WG_IF:-wg-nat}"
MARK_RAW="${MARK:-2333}"
TABLE_ID="${TABLE_ID:-100}"
RULE_PRIORITY="${RULE_PRIORITY:-31000}"
HANDSHAKE_MAX="${HANDSHAKE_MAX:-180}"
MAX_START_RETRIES="${MAX_START_RETRIES:-12}"
PORT_START="${PORT_START:-40000}"
PORT_END="${PORT_END:-50050}"
SERVER_ADDR="${SERVER_ADDR:-}"
TAG_PREFIX="${TAG_PREFIX:-nat}"
HEALTHCHECK="${HEALTHCHECK:-/usr/local/sbin/wg_nat_healthcheck.sh}"
SKIP_HEALTHCHECK="${SKIP_HEALTHCHECK:-0}"

[[ "$DURATION" =~ ^[0-9]+$ && ${#DURATION} -le 10 ]] || vr_die "D 必须是正整数秒"
DURATION=$((10#$DURATION))
(( DURATION > 0 && DURATION <= 2147483647 )) || vr_die "D 必须在 1-2147483647 秒"
[[ "$IP_VERSION" == "4" || "$IP_VERSION" == "6" ]] || vr_die "IP_VERSION 只能是 4 或 6"
[[ "$MAX_START_RETRIES" =~ ^[0-9]+$ && ${#MAX_START_RETRIES} -le 3 ]] || vr_die "MAX_START_RETRIES 必须是 1-100"
MAX_START_RETRIES=$((10#$MAX_START_RETRIES))
(( MAX_START_RETRIES >= 1 && MAX_START_RETRIES <= 100 )) || vr_die "MAX_START_RETRIES 必须是 1-100"
[[ "$PORT_START" =~ ^[0-9]+$ && "$PORT_END" =~ ^[0-9]+$ ]] \
  && (( PORT_START >= 1 && PORT_END <= 65535 && PORT_START <= PORT_END )) || vr_die "PORT_START/PORT_END 无效"
[[ "$IP_LIMIT" =~ ^[0-9]+$ && ${#IP_LIMIT} -le 5 ]] || vr_die "IP_LIMIT 必须是 0-65535"
IP_LIMIT=$((10#$IP_LIMIT))
(( IP_LIMIT <= 65535 )) || vr_die "IP_LIMIT 必须是 0-65535"
[[ "$IP_STICKY_SECONDS" =~ ^[0-9]+$ && ${#IP_STICKY_SECONDS} -le 10 ]] || vr_die "IP_STICKY_SECONDS 必须是正整数"
IP_STICKY_SECONDS=$((10#$IP_STICKY_SECONDS))
(( IP_STICKY_SECONDS > 0 && IP_STICKY_SECONDS <= 2147483647 )) || vr_die "IP_STICKY_SECONDS 必须在 1-2147483647"
[[ "$TABLE_ID" =~ ^[0-9]+$ ]] && (( TABLE_ID > 0 && TABLE_ID <= 2147483647 )) || vr_die "TABLE_ID 必须在 1-2147483647"
(( TABLE_ID < 253 || TABLE_ID > 255 )) || vr_die "TABLE_ID 不能使用 253-255 保留表"
[[ "$RULE_PRIORITY" =~ ^[0-9]+$ ]] && (( RULE_PRIORITY > 0 && RULE_PRIORITY <= 32765 )) || vr_die "RULE_PRIORITY 必须在 1-32765"
[[ "$HANDSHAKE_MAX" =~ ^[0-9]+$ ]] && (( HANDSHAKE_MAX > 0 && HANDSHAKE_MAX <= 86400 )) || vr_die "HANDSHAKE_MAX 必须在 1-86400 秒"
[[ "$SKIP_HEALTHCHECK" == "0" || "$SKIP_HEALTHCHECK" == "1" ]] || vr_die "SKIP_HEALTHCHECK 只能是 0 或 1"
[[ -n "$WG_IF" && ${#WG_IF} -le 15 && "$WG_IF" =~ ^[A-Za-z0-9_.-]+$ && "$WG_IF" != "." && "$WG_IF" != ".." ]] \
  || vr_die "WG_IF 非法：${WG_IF}"
[[ "$HEALTHCHECK" == /* && "$HEALTHCHECK" != *$'\n'* && "$HEALTHCHECK" != *$'\r'* ]] \
  || vr_die "HEALTHCHECK 必须是无换行的绝对路径"

for cmd in python3 openssl ss systemctl timeout getent; do
  command -v "$cmd" >/dev/null 2>&1 || vr_die "缺少命令：${cmd}"
done
[[ -x /usr/local/bin/xray ]] || vr_die "未找到 /usr/local/bin/xray"
[[ -x /usr/local/sbin/vless_run_temp.sh ]] || vr_die "缺少 vless_run_temp.sh"
[[ -x /usr/local/sbin/vless_cleanup_one.sh ]] || vr_die "缺少 vless_cleanup_one.sh"
[[ -x /usr/local/sbin/wg_nat_guard.sh ]] || vr_die "缺少 wg_nat_guard.sh；请先运行同一修复包中的 vpswg.sh"

normalize_mark() {
  local raw="${1,,}"
  raw="${raw//[[:space:]]/}"
  if [[ "$raw" =~ ^0x[0-9a-f]+$ ]]; then
    raw="${raw#0x}"
    (( ${#raw} <= 8 )) || vr_die "MARK 超出 32 位范围：$1"
    printf '%s\n' "$((16#$raw))"
  elif [[ "$raw" =~ ^[0-9]+$ ]]; then
    (( ${#raw} <= 10 )) || vr_die "MARK 超出 32 位范围：$1"
    printf '%s\n' "$((10#$raw))"
  else
    vr_die "MARK 格式不合法：$1"
  fi
}
MARK_DEC="$(normalize_mark "$MARK_RAW")"
[[ "$MARK_DEC" =~ ^[0-9]+$ ]] && (( MARK_DEC > 0 && MARK_DEC <= 4294967295 )) \
  || vr_die "MARK 必须在 1-4294967295"

RAW_ID="${id:-${TAG_PREFIX}-$(date +%Y%m%d%H%M%S)-$(openssl rand -hex 2)}"
SAFE_ID="$(vr_safe_tag "$RAW_ID")"
TAG="$(vr_temp_tag_from_id "$SAFE_ID")"

if [[ "${VR_TEMP_LOCK_HELD:-0}" != "1" ]]; then
  vr_acquire_lock_fd 7 "${VR_LOCK_DIR}/temp.lock" 120 "temp 锁繁忙"
  export VR_TEMP_LOCK_HELD=1
fi

# vpswg.sh owns the policy tuple.  Read it only after taking temp.lock (the
# VPS manager takes the same lock before changing the state), merge omitted
# values, and reject explicit divergence: the guard creates the policy rule
# for this tuple, so merely adding another mark to its reject chain would not
# make a different tuple routable.
WG_STATE_FILE="/etc/wireguard/${WG_IF}.env"
[[ -f "$WG_STATE_FILE" ]] || vr_die "缺少 ${WG_STATE_FILE}；请先运行 vpswg.sh"
[[ "$(stat -c %u "$WG_STATE_FILE" 2>/dev/null || echo -1)" == "0" ]] \
  || vr_die "${WG_STATE_FILE} 必须属于 root"
WG_STATE_MODE="$(stat -c %a "$WG_STATE_FILE" 2>/dev/null || echo 777)"
[[ "$WG_STATE_MODE" =~ ^[0-7]{3,4}$ ]] && (( ((8#$WG_STATE_MODE) & 8#022) == 0 )) \
  || vr_die "${WG_STATE_FILE} 不能被 group/other 写入"
SAVED_MARK="$(sed -n 's/^MARK=//p' "$WG_STATE_FILE" | head -n1)"
SAVED_TABLE_ID="$(sed -n 's/^TABLE_ID=//p' "$WG_STATE_FILE" | head -n1)"
SAVED_RULE_PRIORITY="$(sed -n 's/^RULE_PRIORITY=//p' "$WG_STATE_FILE" | head -n1)"
[[ -n "$SAVED_MARK" && "$SAVED_TABLE_ID" =~ ^[0-9]+$ && "$SAVED_RULE_PRIORITY" =~ ^[0-9]+$ ]] \
  || vr_die "${WG_STATE_FILE} 缺少有效的 MARK/TABLE_ID/RULE_PRIORITY"
[[ -n "$MARK_EXPLICIT" ]] || MARK_RAW="$SAVED_MARK"
[[ -n "$TABLE_ID_EXPLICIT" ]] || TABLE_ID="$SAVED_TABLE_ID"
[[ -n "$RULE_PRIORITY_EXPLICIT" ]] || RULE_PRIORITY="$SAVED_RULE_PRIORITY"
MARK_DEC="$(normalize_mark "$MARK_RAW")"
SAVED_MARK_DEC="$(normalize_mark "$SAVED_MARK")"
[[ "$TABLE_ID" =~ ^[0-9]+$ ]] && (( TABLE_ID > 0 && TABLE_ID <= 2147483647 )) \
  || vr_die "TABLE_ID 必须在 1-2147483647"
(( TABLE_ID < 253 || TABLE_ID > 255 )) || vr_die "TABLE_ID 不能使用 253-255 保留表"
[[ "$RULE_PRIORITY" =~ ^[0-9]+$ ]] && (( RULE_PRIORITY > 0 && RULE_PRIORITY <= 32765 )) \
  || vr_die "RULE_PRIORITY 必须在 1-32765"
[[ "$MARK_DEC" == "$SAVED_MARK_DEC" && "$TABLE_ID" == "$SAVED_TABLE_ID" && "$RULE_PRIORITY" == "$SAVED_RULE_PRIORITY" ]] \
  || vr_die "NAT 临时节点的 MARK/TABLE_ID/RULE_PRIORITY 必须与 ${WG_STATE_FILE} 一致"

EXIST_META="$(vr_temp_meta_file "$TAG")"
if [[ -f "$EXIST_META" ]]; then
  EXIST_EXPIRE="$(vr_meta_get "$EXIST_META" EXPIRE_EPOCH || true)"
  if [[ "$EXIST_EXPIRE" =~ ^[0-9]+$ ]] && (( EXIST_EXPIRE <= $(date +%s) )); then
    FORCE=1 VR_TEMP_LOCK_HELD=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" >/dev/null 2>&1 \
      || vr_die "旧的过期节点 ${TAG} 清理未完成；请先检查 nftables 后重试"
  else
    vr_die "临时节点 ${TAG} 已存在"
  fi
fi

mapfile -t MAIN_INFO < <(vr_read_main_reality)
REALITY_PRIVATE_KEY="${MAIN_INFO[0]:-}"
REALITY_DEST="${MAIN_INFO[1]:-}"
REALITY_SNI="${MAIN_INFO[2]:-}"
MAIN_PORT="${MAIN_INFO[3]:-}"
[[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_DEST" ]] || vr_die "无法从主节点读取 Reality 参数"
[[ -n "$REALITY_SNI" ]] || REALITY_SNI="${REALITY_DEST%%:*}"

vr_load_defaults
PUBLISHED_DOMAIN="$(vr_meta_get "$VR_MAIN_STATE_FILE" PUBLIC_DOMAIN 2>/dev/null || true)"
PUBLISHED_DOMAIN="${PUBLISHED_DOMAIN:-${PUBLIC_DOMAIN:-}}"
LISTEN_ADDR="0.0.0.0"

if [[ "$IP_VERSION" == "6" ]]; then
  [[ -n "${PUBLIC_IPV6_DOMAIN:-}" ]] || vr_die "IP_VERSION=6 时必须在 ${VR_DEFAULTS_FILE} 设置 PUBLIC_IPV6_DOMAIN"
  mapfile -t SERVER_IPV6S < <(vr_get_public_ipv6_candidates)
  (( ${#SERVER_IPV6S[@]} > 0 )) || vr_die "无法检测到可用的公网 IPv6"
  vr_require_domain_aaaa_points_here "$PUBLIC_IPV6_DOMAIN" "${SERVER_IPV6S[@]}"
  PUBLISHED_DOMAIN="$PUBLIC_IPV6_DOMAIN"
  LISTEN_ADDR="::"
fi
[[ -n "$PUBLISHED_DOMAIN" ]] || vr_die "无法获取发布域名"
SERVER_ADDR="${SERVER_ADDR:-$PUBLISHED_DOMAIN}"

validate_server_addr() {
  local host="$1" family="$2" rc
  if python3 - "$host" "$family" <<'PYADDR'
import ipaddress, sys
host, family = sys.argv[1], int(sys.argv[2])
try:
    ip = ipaddress.ip_address(host.strip('[]'))
except ValueError:
    raise SystemExit(2)
raise SystemExit(0 if ip.version == family else 1)
PYADDR
  then
    return 0
  else
    rc=$?
  fi
  if (( rc == 1 )); then return 1; fi
  if [[ "$family" == "6" ]]; then
    getent ahostsv6 "$host" 2>/dev/null | awk 'NF{ok=1} END{exit !ok}'
  else
    getent ahostsv4 "$host" 2>/dev/null | awk 'NF{ok=1} END{exit !ok}'
  fi
}
validate_server_addr "$SERVER_ADDR" "$IP_VERSION" || vr_die "SERVER_ADDR=${SERVER_ADDR} 没有可用的 IPv${IP_VERSION} 地址"
URL_HOST="$(vr_vless_url_host "$SERVER_ADDR")"

PBK_IN="${PBK:-}"
[[ -n "$PBK_IN" ]] || PBK_IN="$(vr_meta_get "$VR_MAIN_STATE_FILE" PBK 2>/dev/null || true)"
[[ -n "$PBK_IN" ]] || PBK_IN="$(vr_main_url_published_pbk 2>/dev/null || true)"
[[ -n "$PBK_IN" ]] || vr_die "无法获取主节点 PBK，请先运行 /root/onekey_reality_ipv4.sh"
PBK_RAW="$(vr_urldecode "$PBK_IN")"
[[ "$PBK_RAW" =~ ^[A-Za-z0-9_+/=-]{40,128}$ ]] \
  || vr_die "PBK 不是有效的 Reality 客户端公钥"

PQ_LIMIT_BYTES=""
if [[ -n "$PQ_GIB" ]]; then
  PQ_LIMIT_BYTES="$(vr_parse_gib_to_bytes "$PQ_GIB")" || vr_die "PQ_GIB 必须是正数"
  [[ "$PQ_LIMIT_BYTES" =~ ^[0-9]+$ ]] && (( PQ_LIMIT_BYTES > 0 )) || vr_die "PQ_GIB 转换失败"
fi

if [[ "$SKIP_HEALTHCHECK" == "1" ]]; then
  echo "⚠️  已按 SKIP_HEALTHCHECK=1 跳过 WireGuard NAT 出口检查" >&2
else
  [[ -x "$HEALTHCHECK" ]] || vr_die "健康检查脚本不存在或不可执行：${HEALTHCHECK}；仅在明确接受风险时设置 SKIP_HEALTHCHECK=1"
  echo "==> 检查 WireGuard NAT 出口..."
  HANDSHAKE_MAX="$HANDSHAKE_MAX" WG_IF="$WG_IF" MARK="$MARK_DEC" TABLE_ID="$TABLE_ID" RULE_PRIORITY="$RULE_PRIORITY" "$HEALTHCHECK" \
    || vr_die "wg-nat 出口不可用"
fi
systemctl start "wg-nat-guard@${WG_IF}.service" >/dev/null
/usr/local/sbin/wg_nat_guard.sh "$WG_IF"

collect_used_ports() {
  ss -ltnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/'
  for meta in "$VR_TEMP_STATE_DIR"/*.env "$VR_QUOTA_STATE_DIR"/*.env "$VR_IPLIMIT_STATE_DIR"/*.env; do
    [[ -f "$meta" ]] || continue
    vr_meta_get "$meta" PORT || true
  done
  [[ "$MAIN_PORT" =~ ^[0-9]+$ ]] && printf '%s\n' "$MAIN_PORT"
}

write_nat_config() {
  local file="$1" listen="$2" port="$3" uuid="$4" short_id="$5"
  VR_CFG_PRIVATE_KEY="$REALITY_PRIVATE_KEY" \
    python3 - "$file" "$listen" "$port" "$uuid" "$short_id" "$TAG" "$REALITY_DEST" "$REALITY_SNI" "$MARK_DEC" <<'PYCFG'
import json, os, sys, tempfile
file, listen, port, uuid, sid, tag, dest, sni, mark = sys.argv[1:]
private_key = os.environ.pop("VR_CFG_PRIVATE_KEY")
cfg = {
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": tag,
    "listen": listen,
    "port": int(port),
    "protocol": "vless",
    "settings": {"clients": [{"id": uuid, "flow": "xtls-rprx-vision"}], "decryption": "none"},
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {"show": False, "dest": dest, "xver": 0, "serverNames": [sni], "privateKey": private_key, "shortIds": [sid]}
    },
    "sniffing": {"enabled": True, "routeOnly": True, "destOverride": ["http", "tls", "quic"]}
  }],
  "outbounds": [
    {"tag": "nat", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}, "streamSettings": {"sockopt": {"mark": int(mark)}}},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {"rules": [{"type": "field", "inboundTag": [tag], "outboundTag": "nat"}]}
}
if listen == "::":
    cfg["inbounds"][0]["streamSettings"]["sockopt"] = {"v6only": True}
dirname = os.path.dirname(file)
os.makedirs(dirname, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix='.natcfg.', dir=dirname, text=True)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        json.dump(cfg, fh, ensure_ascii=False, indent=2)
        fh.write('\n')
    os.chmod(tmp, 0o600)
    os.replace(tmp, file)
finally:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
PYCFG
}

validate_full_state() {
  local meta="$1" port="$2"
  [[ -f "$meta" && -f "$(vr_temp_cfg_file "$TAG")" && -f "$(vr_temp_unit_file "$TAG")" && -f "$(vr_temp_url_file "$TAG")" ]] || return 1
  [[ -f /root/vless_temp_subscription.txt ]] || return 1
  grep -Fxq -- "$VLESS_URL" /root/vless_temp_subscription.txt || return 1
  [[ "$(vr_meta_get "$meta" LANDING || true)" == "nat" ]] || return 1
  [[ "$(vr_meta_get "$meta" SERVER_ADDR || true)" == "$SERVER_ADDR" ]] || return 1
  [[ "$(vr_meta_get "$meta" IP_VERSION || true)" == "$IP_VERSION" ]] || return 1
  [[ "$(vr_il_family_guard_state "$port")" == "active" ]] || return 1
  systemctl is-active --quiet "${TAG}.service" || return 1
  vr_port_is_listening "$port" || return 1
  if [[ -n "$PQ_LIMIT_BYTES" ]]; then
    [[ -f "$(vr_quota_meta_file "$port")" ]] || return 1
    [[ "$(vr_pq_state "$port")" == "active" ]] || return 1
  fi
  if (( IP_LIMIT > 0 )); then
    local imeta
    imeta="$(vr_iplimit_meta_file "$port")"
    [[ -f "$imeta" && "$(vr_meta_get "$imeta" IP_VERSION || true)" == "$IP_VERSION" ]] || return 1
    [[ "$(vr_il_state "$port")" == "active" ]] || return 1
  fi
  /usr/local/sbin/vless_audit.sh --tag "$TAG" >/dev/null 2>&1
}

declare -A FAILED_PORTS=()
ATTEMPT=0
while (( ATTEMPT < MAX_START_RETRIES )); do
  ATTEMPT=$((ATTEMPT + 1))
  mapfile -t USED_PORTS < <(collect_used_ports | awk '/^[0-9]+$/ {print}' | sort -n -u)
  declare -A USED=()
  for p in "${USED_PORTS[@]}"; do USED["$p"]=1; done
  for p in "${!FAILED_PORTS[@]}"; do USED["$p"]=1; done

  PORT=""
  for ((CANDIDATE=PORT_START; CANDIDATE<=PORT_END; CANDIDATE++)); do
    if [[ -z "${USED[$CANDIDATE]+x}" ]]; then PORT="$CANDIDATE"; break; fi
  done
  [[ -n "$PORT" ]] || vr_die "在 ${PORT_START}-${PORT_END} 范围内没有空闲端口"
  CURRENT_ATTEMPT_ACTIVE=1

  UUID="$(/usr/local/bin/xray uuid)"
  SHORT_ID="$(openssl rand -hex 8)"
  CREATE_EPOCH="$(date +%s)"
  EXPIRE_EPOCH=$((CREATE_EPOCH + DURATION))
  CFG="$(vr_temp_cfg_file "$TAG")"
  META="$(vr_temp_meta_file "$TAG")"
  UNIT_FILE="$(vr_temp_unit_file "$TAG")"
  URL_FILE="$(vr_temp_url_file "$TAG")"

  write_nat_config "$CFG" "$LISTEN_ADDR" "$PORT" "$UUID" "$SHORT_ID"
  if ! vr_test_xray_config "$CFG" /usr/local/bin/xray; then
    rollback_current; FAILED_PORTS["$PORT"]=1; continue
  fi

  vr_write_meta "$META" \
    "TAG=${TAG}" "ID=${SAFE_ID}" "PORT=${PORT}" "PUBLIC_DOMAIN=${PUBLISHED_DOMAIN}" \
    "SERVER_ADDR=${SERVER_ADDR}" "IP_VERSION=${IP_VERSION}" "LISTEN_ADDR=${LISTEN_ADDR}" \
    "UUID=${UUID}" "CREATE_EPOCH=${CREATE_EPOCH}" "EXPIRE_EPOCH=${EXPIRE_EPOCH}" \
    "DURATION_SECONDS=${DURATION}" "REALITY_DEST=${REALITY_DEST}" "REALITY_SNI=${REALITY_SNI}" \
    "SHORT_ID=${SHORT_ID}" "PBK=${PBK_RAW}" "PQ_GIB=${PQ_GIB}" "PQ_LIMIT_BYTES=${PQ_LIMIT_BYTES}" \
    "IP_LIMIT=${IP_LIMIT}" "IP_STICKY_SECONDS=${IP_STICKY_SECONDS}" "LANDING=nat" \
    "WG_IF=${WG_IF}" "MARK=${MARK_DEC}" "TABLE_ID=${TABLE_ID}" "RULE_PRIORITY=${RULE_PRIORITY}" \
    "HANDSHAKE_MAX=${HANDSHAKE_MAX}"

  cat >"$UNIT_FILE" <<UNIT
[Unit]
Description=Temporary VLESS NAT ${TAG} IPv${IP_VERSION}
Requisite=wg-quick@${WG_IF}.service
After=network-online.target vless-managed-restore.service wg-quick@${WG_IF}.service
Wants=network-online.target
ConditionPathExists=${CFG}
ConditionPathExists=${META}

[Service]
Type=simple
User=root
Group=root
ExecStartPre=/usr/local/sbin/vless_nat_preflight.sh ${TAG}
ExecStart=/usr/local/sbin/vless_run_temp.sh ${TAG} ${CFG}
ExecStopPost=/usr/local/sbin/vless_cleanup_one.sh ${TAG} --from-stop-post
Restart=on-failure
RestartSec=3s
SuccessExitStatus=0 124 143
TimeoutStopSec=60
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
# 清理脚本需要刷新 /root 下的聚合订阅，因此不隔离 home 目录。
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
UNIT
  chmod 644 "$UNIT_FILE"
  if command -v systemd-analyze >/dev/null 2>&1 \
    && ! systemd-analyze verify "$UNIT_FILE" >/dev/null 2>&1
  then
    rollback_current; FAILED_PORTS["$PORT"]=1; continue
  fi

  if [[ -n "$PQ_LIMIT_BYTES" ]] && ! vr_pq_add_managed_port "$PORT" "$PQ_LIMIT_BYTES" temp "$TAG" "$DURATION" "$EXPIRE_EPOCH"; then
    rollback_current; FAILED_PORTS["$PORT"]=1; continue
  fi
  if (( IP_LIMIT > 0 )); then
    if ! vr_il_add_managed_port "$PORT" "$IP_LIMIT" "$IP_STICKY_SECONDS" temp "$TAG" "$IP_VERSION"; then
      rollback_current; FAILED_PORTS["$PORT"]=1; continue
    fi
  elif ! vr_il_apply_family_guard "$PORT" "$IP_VERSION"; then
    rollback_current; FAILED_PORTS["$PORT"]=1; continue
  fi

  systemctl daemon-reload
  systemctl enable "${TAG}.service" >/dev/null
  if ! systemctl start "${TAG}.service" || ! vr_wait_unit_and_port "${TAG}.service" "$PORT" 3 12; then
    rollback_current; FAILED_PORTS["$PORT"]=1; continue
  fi

  PBK_Q="$(vr_urlencode "$PBK_RAW")"
  SNI_Q="$(vr_urlencode "$REALITY_SNI")"
  TAG_Q="$(vr_urlencode "$TAG")"
  VLESS_URL="vless://${UUID}@${URL_HOST}:${PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${SNI_Q}&fp=chrome&pbk=${PBK_Q}&sid=${SHORT_ID}#${TAG_Q}"
  URL_TMP="$(mktemp "${URL_FILE}.tmp.XXXXXX")"
  printf '%s\n' "$VLESS_URL" >"$URL_TMP"
  chmod 600 "$URL_TMP"
  mv -f "$URL_TMP" "$URL_FILE"
  if ! /usr/local/sbin/vless_temp_sub.sh >/dev/null 2>&1; then
    rollback_current; FAILED_PORTS["$PORT"]=1; continue
  fi

  if ! validate_full_state "$META" "$PORT"; then
    rollback_current; FAILED_PORTS["$PORT"]=1; continue
  fi

  echo "✅ NAT 落地临时节点创建成功"
  echo "TAG: ${TAG}"
  echo "PORT: ${PORT}"
  echo "IP_VERSION: ${IP_VERSION}"
  echo "SERVER_ADDR: ${SERVER_ADDR}"
  echo "WG_IF: ${WG_IF}"
  echo "MARK: ${MARK_DEC}"
  echo "TABLE_ID: ${TABLE_ID}"
  echo "RULE_PRIORITY: ${RULE_PRIORITY}"
  echo "TTL: $(vr_ttl_human "$EXPIRE_EPOCH")"
  echo "到期(北京时间): $(vr_beijing_time "$EXPIRE_EPOCH")"
  [[ -n "$PQ_LIMIT_BYTES" ]] && echo "PQ: $(vr_human_bytes "$PQ_LIMIT_BYTES")"
  (( IP_LIMIT > 0 )) && echo "IP_LIMIT: ${IP_LIMIT} / sticky ${IP_STICKY_SECONDS}s"
  echo "URL: ${VLESS_URL}"
  CURRENT_ATTEMPT_ACTIVE=0
  exit 0
done

vr_die "启动 NAT 临时 VLESS 服务失败，已回滚（尝试次数: ${MAX_START_RETRIES}）"
__NAT_MKTEMP_FINAL__

chmod 755 "$PREFLIGHT_TMP" "$CREATOR_TMP"
bash -n "$PREFLIGHT_TMP" "$CREATOR_TMP"
trap '' INT TERM HUP
mv -f -- "$PREFLIGHT_TMP" "$PREFLIGHT_TARGET"
mv -f -- "$CREATOR_TMP" "$CREATOR_TARGET"
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
INSTALL_TX_ACTIVE=0
rm -rf -- "$INSTALL_TX_DIR"
echo "✅ 已安装 /usr/local/sbin/vless_mktemp_nat.sh"
echo "IPv4 示例：id=nat4 IP_VERSION=4 MARK=2333 D=1200 vless_mktemp_nat.sh"
echo "IPv6 示例：id=nat6 IP_VERSION=6 MARK=2333 D=1200 vless_mktemp_nat.sh"
