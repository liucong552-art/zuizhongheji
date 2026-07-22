#!/usr/bin/env bash
# Final four-file edition: VLESS/Reality main installer and IPv4/IPv6 temporary-node manager.
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
umask 077

DEFAULTS_FILE="/etc/default/vless-reality"

die() {
  echo "❌ $*" >&2
  exit 1
}

check_supported_os() {
  [[ "$(id -u)" -eq 0 ]] || die "请以 root 运行本脚本"
  (( BASH_VERSINFO[0] >= 4 )) || die "需要 Bash 4.0 或更高版本"
  command -v apt-get >/dev/null 2>&1 || die "本脚本需要 apt-get（Debian/Ubuntu 系）"
  command -v dpkg >/dev/null 2>&1 || die "未找到 dpkg"

  local release_file="${VR_OS_RELEASE_FILE:-/etc/os-release}"
  local ID="" ID_LIKE="" VERSION_ID="" PRETTY_NAME=""
  local os_id os_id_like os_version pretty major
  if [[ ! -r "$release_file" && "$release_file" == "/etc/os-release" && -r /usr/lib/os-release ]]; then
    release_file="/usr/lib/os-release"
  fi
  [[ -r "$release_file" ]] || die "无法读取 os-release：${release_file}"

  # shellcheck disable=SC1090
  . "$release_file"
  os_id="${ID,,}"
  os_id_like=" ${ID_LIKE,,} "
  os_version="${VERSION_ID:-0}"
  pretty="${PRETTY_NAME:-${ID:-unknown} ${os_version}}"

  case "$os_id" in
    debian)
      major="${os_version%%.*}"
      [[ "$major" =~ ^[0-9]+$ ]] && (( major >= ${VR_MIN_DEBIAN_MAJOR:-11} )) \
        || die "${pretty} 太旧；最低支持 Debian ${VR_MIN_DEBIAN_MAJOR:-11}"
      ;;
    ubuntu)
      dpkg --compare-versions "$os_version" ge "${VR_MIN_UBUNTU_VERSION:-20.04}" \
        || die "${pretty} 太旧；最低支持 Ubuntu ${VR_MIN_UBUNTU_VERSION:-20.04}"
      ;;
    *)
      if [[ "$os_id_like" == *" debian "* && "${VR_ALLOW_DEBIAN_DERIVATIVE:-0}" == "1" ]]; then
        echo "⚠️  Debian 衍生系统兼容模式：${pretty}" >&2
      elif [[ "${VR_ALLOW_UNSUPPORTED_OS:-0}" == "1" ]]; then
        echo "⚠️  未正式支持的系统，按 VR_ALLOW_UNSUPPORTED_OS=1 继续：${pretty}" >&2
      else
        die "不支持的系统：${pretty}；支持 Debian ${VR_MIN_DEBIAN_MAJOR:-11}+ / Ubuntu ${VR_MIN_UBUNTU_VERSION:-20.04}+"
      fi
      ;;
  esac
}

apt_install_with_universe_retry() {
  local -a packages=("$@")
  if apt-get install -y --no-install-recommends "${packages[@]}"; then
    return 0
  fi

  local release_file="${VR_OS_RELEASE_FILE:-/etc/os-release}"
  local ID=""
  if [[ ! -r "$release_file" && "$release_file" == "/etc/os-release" && -r /usr/lib/os-release ]]; then
    release_file="/usr/lib/os-release"
  fi
  if [[ -r "$release_file" ]]; then
    # shellcheck disable=SC1090
    . "$release_file"
  fi
  if [[ "${ID,,}" == "ubuntu" ]]; then
    echo "⚠️  首次依赖安装失败，尝试启用 Ubuntu Universe 后重试..." >&2
    apt-get install -y --no-install-recommends software-properties-common >/dev/null 2>&1 || true
    if command -v add-apt-repository >/dev/null 2>&1; then
      add-apt-repository -y universe >/dev/null 2>&1 || true
      apt-get update -o Acquire::Retries=3
      apt-get install -y --no-install-recommends "${packages[@]}" && return 0
    fi
  fi
  die "依赖安装失败；请检查软件源、网络以及 Ubuntu Universe 是否已启用"
}

need_basic_tools() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -o Acquire::Retries=3
  apt_install_with_universe_retry \
    ca-certificates curl openssl python3 nftables iproute2 coreutils util-linux procps kmod findutils
  local cmd
  for cmd in curl openssl python3 nft ip ss flock timeout sha256sum systemctl getent find; do
    command -v "$cmd" >/dev/null 2>&1 || die "依赖安装后仍缺少命令：${cmd}"
  done
  [[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')" == "systemd" ]] || \
    die "当前系统不是以 systemd 作为 PID 1"
}

install_defaults() {
  install -d -m 755 /etc/default
  if [[ ! -f "$DEFAULTS_FILE" ]]; then
    cat >"$DEFAULTS_FILE" <<'VR_DEFAULTS'
# IPv4 main node domain. Its A record must point to this VPS.
PUBLIC_DOMAIN=

# Optional IPv6 temporary-node domain. Its AAAA record must point to this VPS.
PUBLIC_IPV6_DOMAIN=

# Reality camouflage target.
CAMOUFLAGE_DOMAIN=www.apple.com
REALITY_DEST=www.apple.com:443
REALITY_SNI=www.apple.com

# Main IPv4 node.
PORT=443
NODE_NAME=VLESS-REALITY-IPv4
VR_DEFAULTS
  elif ! grep -qE '^[[:space:]]*PUBLIC_IPV6_DOMAIN=' "$DEFAULTS_FILE"; then
    cat >>"$DEFAULTS_FILE" <<'VR_MIGRATE'

# Optional IPv6 temporary-node domain. Its AAAA record must point to this VPS.
PUBLIC_IPV6_DOMAIN=
VR_MIGRATE
  fi
  chown root:root "$DEFAULTS_FILE"
  chmod 600 "$DEFAULTS_FILE"
}

BUNDLE_TX_ACTIVE=0
BUNDLE_TX_DIR=""
BUNDLE_MAIN="/root/onekey_reality_ipv4.sh"
BUNDLE_AUDIT="/root/vless_temp_audit_ipv4_all.sh"

bundle_rollback() {
  (( BUNDLE_TX_ACTIVE == 1 )) || return 0
  BUNDLE_TX_ACTIVE=0
  set +e
  local path key
  for path in "$BUNDLE_MAIN" "$BUNDLE_AUDIT"; do
    key="$(basename "$path")"
    rm -f -- "$path"
    if [[ -e "${BUNDLE_TX_DIR}/${key}.old" || -L "${BUNDLE_TX_DIR}/${key}.old" ]]; then
      cp -a -- "${BUNDLE_TX_DIR}/${key}.old" "$path"
    fi
  done
  rm -rf -- "$BUNDLE_TX_DIR"
}

bundle_on_exit() {
  local rc=$?
  trap - EXIT ERR
  trap '' INT TERM HUP
  bundle_rollback || true
  exit "$rc"
}

trap 'bundle_on_exit' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

check_supported_os
need_basic_tools
install_defaults

install -d -m 755 /run/lock
exec 9>/run/lock/vless-reality-bundle-install.lock
flock -w 300 9 || die "VLESS 安装锁繁忙"

BUNDLE_TX_DIR="$(mktemp -d /root/.vless-bundle-transaction.XXXXXX)"
for bundle_path in "$BUNDLE_MAIN" "$BUNDLE_AUDIT"; do
  if [[ -e "$bundle_path" || -L "$bundle_path" ]]; then
    cp -a -- "$bundle_path" "${BUNDLE_TX_DIR}/$(basename "$bundle_path").old"
  fi
done
BUNDLE_MAIN_TMP="${BUNDLE_TX_DIR}/onekey_reality_ipv4.sh.new"
BUNDLE_AUDIT_TMP="${BUNDLE_TX_DIR}/vless_temp_audit_ipv4_all.sh.new"
BUNDLE_TX_ACTIVE=1

cat >"$BUNDLE_MAIN_TMP" <<'__FINAL_MAIN__'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

XRAY_CACHE_DIR="/usr/local/src/xray-core"
DEFAULTS_FILE="/etc/default/vless-reality"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
XRAY_UNIT_FILE="/etc/systemd/system/xray.service"
MAIN_STATE_DIR="/var/lib/vless-reality/main"
MAIN_STATE_FILE="${MAIN_STATE_DIR}/main.env"
MAIN_LOCK_FILE="/run/vless-reality/main-install.lock"

TX_ACTIVE=0
TX_DIR=""
OLD_SERVICE_ACTIVE=0
OLD_SERVICE_ENABLED=""

die() {
  echo "❌ $*" >&2
  if (( TX_ACTIVE == 1 )); then
    trap - ERR
    trap '' INT TERM HUP
    rollback_transaction || true
  fi
  exit 1
}

on_error() {
  local rc=$?
  trap - ERR
  trap '' INT TERM HUP
  echo "❌ ${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}:${BASH_LINENO[0]:-?}: ${BASH_COMMAND}" >&2
  if (( TX_ACTIVE == 1 )); then
    rollback_transaction || true
  fi
  exit "$rc"
}
on_exit() {
  local rc=$?
  trap - EXIT ERR
  trap '' INT TERM HUP
  if (( TX_ACTIVE == 1 )); then
    rollback_transaction || true
  fi
  exit "$rc"
}

trap 'on_error' ERR
trap 'on_exit' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

curl4() {
  curl -4fsS --connect-timeout 5 --max-time 90 --retry 3 --retry-delay 1 "$@"
}

check_supported_os() {
  [[ "$(id -u)" -eq 0 ]] || die "请以 root 运行本脚本"
  (( BASH_VERSINFO[0] >= 4 )) || die "需要 Bash 4.0 或更高版本"
  command -v apt-get >/dev/null 2>&1 || die "本脚本需要 apt-get（Debian/Ubuntu 系）"
  command -v dpkg >/dev/null 2>&1 || die "未找到 dpkg"

  local release_file="${VR_OS_RELEASE_FILE:-/etc/os-release}"
  local ID="" ID_LIKE="" VERSION_ID="" PRETTY_NAME=""
  local os_id os_id_like os_version pretty major
  if [[ ! -r "$release_file" && "$release_file" == "/etc/os-release" && -r /usr/lib/os-release ]]; then
    release_file="/usr/lib/os-release"
  fi
  [[ -r "$release_file" ]] || die "无法读取 os-release：${release_file}"

  # shellcheck disable=SC1090
  . "$release_file"
  os_id="${ID,,}"
  os_id_like=" ${ID_LIKE,,} "
  os_version="${VERSION_ID:-0}"
  pretty="${PRETTY_NAME:-${ID:-unknown} ${os_version}}"

  case "$os_id" in
    debian)
      major="${os_version%%.*}"
      [[ "$major" =~ ^[0-9]+$ ]] && (( major >= ${VR_MIN_DEBIAN_MAJOR:-11} )) \
        || die "${pretty} 太旧；最低支持 Debian ${VR_MIN_DEBIAN_MAJOR:-11}"
      ;;
    ubuntu)
      dpkg --compare-versions "$os_version" ge "${VR_MIN_UBUNTU_VERSION:-20.04}" \
        || die "${pretty} 太旧；最低支持 Ubuntu ${VR_MIN_UBUNTU_VERSION:-20.04}"
      ;;
    *)
      if [[ "$os_id_like" == *" debian "* && "${VR_ALLOW_DEBIAN_DERIVATIVE:-0}" == "1" ]]; then
        echo "⚠️  Debian 衍生系统兼容模式：${pretty}" >&2
      elif [[ "${VR_ALLOW_UNSUPPORTED_OS:-0}" == "1" ]]; then
        echo "⚠️  未正式支持的系统，按 VR_ALLOW_UNSUPPORTED_OS=1 继续：${pretty}" >&2
      else
        die "不支持的系统：${pretty}；支持 Debian ${VR_MIN_DEBIAN_MAJOR:-11}+ / Ubuntu ${VR_MIN_UBUNTU_VERSION:-20.04}+"
      fi
      ;;
  esac
}

apt_install_with_universe_retry() {
  local -a packages=("$@")
  if apt-get install -y --no-install-recommends "${packages[@]}"; then
    return 0
  fi

  local release_file="${VR_OS_RELEASE_FILE:-/etc/os-release}"
  local ID=""
  if [[ ! -r "$release_file" && "$release_file" == "/etc/os-release" && -r /usr/lib/os-release ]]; then
    release_file="/usr/lib/os-release"
  fi
  if [[ -r "$release_file" ]]; then
    # shellcheck disable=SC1090
    . "$release_file"
  fi
  if [[ "${ID,,}" == "ubuntu" ]]; then
    echo "⚠️  首次依赖安装失败，尝试启用 Ubuntu Universe 后重试..." >&2
    apt-get install -y --no-install-recommends software-properties-common >/dev/null 2>&1 || true
    if command -v add-apt-repository >/dev/null 2>&1; then
      add-apt-repository -y universe >/dev/null 2>&1 || true
      apt-get update -o Acquire::Retries=3
      apt-get install -y --no-install-recommends "${packages[@]}" && return 0
    fi
  fi
  die "依赖安装失败；请检查软件源、网络以及 Ubuntu Universe 是否已启用"
}

need_basic_tools() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -o Acquire::Retries=3
  apt_install_with_universe_retry \
    ca-certificates curl openssl python3 iproute2 coreutils util-linux procps kmod findutils
  local cmd
  for cmd in curl openssl python3 ip ss flock timeout sha256sum systemctl getent find; do
    command -v "$cmd" >/dev/null 2>&1 || die "依赖安装后仍缺少命令：${cmd}"
  done
  [[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')" == "systemd" ]] || \
    die "当前系统不是以 systemd 作为 PID 1"
}

acquire_main_lock() {
  install -d -m 755 /run/vless-reality
  exec 6>"$MAIN_LOCK_FILE"
  flock -w 120 6 || die "另一个主节点安装或更新任务正在运行"
  exec 7>/run/vless-reality/temp.lock
  flock -w 120 7 || die "临时节点创建/清理任务仍在运行"
  export VR_TEMP_LOCK_HELD=1
}

normalize_domain() {
  python3 - "$1" <<'PYDOMAIN'
import ipaddress
import re
import sys
raw = (sys.argv[1] or '').strip().rstrip('.')
if not raw or any(ch.isspace() for ch in raw) or any(ch in raw for ch in '/?#@[]:'):
    raise SystemExit(1)
try:
    ipaddress.ip_address(raw)
    raise SystemExit(1)
except ValueError:
    pass
try:
    value = raw.encode('idna').decode('ascii').lower()
except Exception:
    raise SystemExit(1)
if len(value) > 253:
    raise SystemExit(1)
for label in value.split('.'):
    if not label or len(label) > 63 or not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?', label):
        raise SystemExit(1)
print(value)
PYDOMAIN
}

normalize_reality_dest() {
  python3 - "$1" <<'PYDEST'
import ipaddress
import re
import sys
raw = (sys.argv[1] or '').strip()
if not raw or any(ch.isspace() for ch in raw) or any(ch in raw for ch in '"\r\n/?#@'):
    raise SystemExit(1)

def domain(value):
    value = value.rstrip('.')
    try:
        out = value.encode('idna').decode('ascii').lower()
    except Exception:
        raise SystemExit(1)
    if len(out) > 253:
        raise SystemExit(1)
    for label in out.split('.'):
        if not label or len(label) > 63 or not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?', label):
            raise SystemExit(1)
    return out

if raw.startswith('['):
    m = re.fullmatch(r'\[([0-9A-Fa-f:]+)\]:(\d+)', raw)
    if not m:
        raise SystemExit(1)
    host = str(ipaddress.IPv6Address(m.group(1)))
    port = int(m.group(2))
    out = f'[{host}]:{port}'
else:
    if ':' not in raw:
        raise SystemExit(1)
    host, port_text = raw.rsplit(':', 1)
    port = int(port_text)
    try:
        host = str(ipaddress.ip_address(host))
    except ValueError:
        host = domain(host)
    out = f'{host}:{port}'
if not 1 <= port <= 65535:
    raise SystemExit(1)
print(out)
PYDEST
}

load_defaults() {
  [[ -f "$DEFAULTS_FILE" ]] || die "未找到 ${DEFAULTS_FILE}"
  [[ "$(stat -c %u "$DEFAULTS_FILE" 2>/dev/null || echo -1)" == "0" ]] \
    || die "${DEFAULTS_FILE} 必须属于 root"
  local defaults_mode
  defaults_mode="$(stat -c %a "$DEFAULTS_FILE" 2>/dev/null || echo 777)"
  [[ "$defaults_mode" =~ ^[0-7]{3,4}$ ]] && (( ((8#$defaults_mode) & 8#022) == 0 )) \
    || die "${DEFAULTS_FILE} 不能被 group/other 写入"
  set -a
  # shellcheck disable=SC1090
  . "$DEFAULTS_FILE"
  set +a

  [[ -n "${PUBLIC_DOMAIN:-}" ]] || die "${DEFAULTS_FILE} 中必须设置 PUBLIC_DOMAIN"
  PUBLIC_DOMAIN="$(normalize_domain "$PUBLIC_DOMAIN")" || die "PUBLIC_DOMAIN 不是有效域名"

  PORT="${PORT:-443}"
  NODE_NAME="${NODE_NAME:-VLESS-REALITY-IPv4}"
  [[ "$NODE_NAME" != *$'\n'* && "$NODE_NAME" != *$'\r'* ]] || die "NODE_NAME 不能包含换行"

  if [[ -n "${CAMOUFLAGE_DOMAIN:-}" ]]; then
    CAMOUFLAGE_DOMAIN="$(normalize_domain "$CAMOUFLAGE_DOMAIN")" || die "CAMOUFLAGE_DOMAIN 不是有效域名"
    REALITY_DEST="${REALITY_DEST:-${CAMOUFLAGE_DOMAIN}:443}"
    REALITY_SNI="${REALITY_SNI:-${CAMOUFLAGE_DOMAIN}}"
  fi

  [[ -n "${REALITY_DEST:-}" ]] || die "${DEFAULTS_FILE} 中必须设置 REALITY_DEST（或 CAMOUFLAGE_DOMAIN）"
  [[ -n "${REALITY_SNI:-}" ]] || die "${DEFAULTS_FILE} 中必须设置 REALITY_SNI（或 CAMOUFLAGE_DOMAIN）"
  REALITY_DEST="$(normalize_reality_dest "$REALITY_DEST")" || die "REALITY_DEST 必须是有效的 host:port"
  REALITY_SNI="$(normalize_domain "$REALITY_SNI")" || die "REALITY_SNI 不是有效域名"
  [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "PORT 必须是 1-65535 的整数"
}

is_public_ipv4() {
  python3 - "$1" <<'PYIP'
import ipaddress, sys
try:
    ip = ipaddress.ip_address((sys.argv[1] or '').strip())
    raise SystemExit(0 if ip.version == 4 and ip.is_global else 1)
except Exception:
    raise SystemExit(1)
PYIP
}

get_public_ipv4_candidates() {
  local ip url
  {
    for url in \
      "https://api.ipify.org" \
      "https://ifconfig.me/ip" \
      "https://ipv4.icanhazip.com"
    do
      ip="$(curl4 "$url" 2>/dev/null | tr -d ' \n\r' || true)"
      [[ -n "$ip" ]] && is_public_ipv4 "$ip" && printf '%s\n' "$ip" || true
    done

    ip -4 -o addr show scope global 2>/dev/null \
      | awk '{split($4,a,"/"); print a[1]}' \
      | while read -r ip; do
          [[ -n "$ip" ]] || continue
          is_public_ipv4 "$ip" && printf '%s\n' "$ip" || true
        done
  } | awk 'NF && !seen[$0]++'
}

resolve_domain_ipv4s() {
  getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
}

require_domain_points_here() {
  local domain="$1"
  shift
  local resolved_ip candidate ok=1
  local -a resolved candidates
  mapfile -t resolved < <(resolve_domain_ipv4s "$domain")
  candidates=("$@")
  (( ${#resolved[@]} > 0 )) || die "无法解析 PUBLIC_DOMAIN=${domain} 的 IPv4 A 记录"
  (( ${#candidates[@]} > 0 )) || die "无法检测到可用的公网 IPv4"

  for resolved_ip in "${resolved[@]}"; do
    for candidate in "${candidates[@]}"; do
      if [[ "$resolved_ip" == "$candidate" ]]; then
        ok=0
        break 2
      fi
    done
  done
  (( ok == 0 )) || die "PUBLIC_DOMAIN=${domain} 的 A 记录未匹配本机公网 IPv4；A=${resolved[*]}；本机候选=${candidates[*]}"
}

xray_arch_suffix() {
  case "$(uname -m)" in
    x86_64|amd64) printf '64\n' ;;
    aarch64|arm64) printf 'arm64-v8a\n' ;;
    *) die "不支持的 CPU 架构: $(uname -m)；仅支持 x86_64/amd64 与 aarch64/arm64" ;;
  esac
}

xray_resolve_release_version() {
  local version="${XRAY_VERSION:-}"
  if [[ -z "$version" && -f "$MAIN_STATE_FILE" ]]; then
    version="$(sed -n 's/^XRAY_VERSION=//p' "$MAIN_STATE_FILE" | head -n1)"
  fi
  version="${version:-latest}"
  if [[ "$version" == "latest" ]]; then
    local final_url tag
    final_url="$(curl4 -L -o /dev/null -w '%{url_effective}' 'https://github.com/XTLS/Xray-core/releases/latest')" || \
      die "无法解析 Xray-core latest；可指定 XRAY_VERSION=vX.Y.Z"
    final_url="${final_url%%\?*}"
    final_url="${final_url%/}"
    tag="${final_url##*/}"
    [[ "$tag" =~ ^v[0-9][A-Za-z0-9._-]*$ ]] || die "无法从 latest 跳转地址解析版本: ${final_url}"
    printf '%s\n' "$tag"
    return 0
  fi
  [[ "$version" == v* ]] || version="v${version}"
  [[ "$version" =~ ^v[0-9][A-Za-z0-9._-]*$ ]] || die "非法 XRAY_VERSION；示例: latest 或 v26.1.23"
  printf '%s\n' "$version"
}

xray_release_asset_name() {
  printf 'Xray-linux-%s.zip\n' "$(xray_arch_suffix)"
}

xray_expected_sha256() {
  local dgst_file="$1"
  awk '
    {
      line = tolower($0)
      if (line ~ /sha2?-?256/) {
        for (i = NF; i >= 1; i--) {
          token = tolower($i)
          gsub(/[^0-9a-f]/, "", token)
          if (length(token) == 64 && token ~ /^[0-9a-f]+$/) {
            print token
            exit
          }
        }
      }
    }
  ' "$dgst_file"
}

verify_xray_release_archive() {
  local zip_file="$1" dgst_file="$2" expected actual
  [[ -s "$zip_file" ]] || die "Xray 压缩包不存在或为空: ${zip_file}"
  [[ -s "$dgst_file" ]] || die "Xray 校验文件不存在或为空: ${dgst_file}"
  expected="$(xray_expected_sha256 "$dgst_file")"
  [[ -n "$expected" ]] || die "无法从 ${dgst_file} 解析 SHA256"
  actual="$(sha256sum "$zip_file" | awk '{print tolower($1)}')"
  [[ "$actual" == "$expected" ]] || die "Xray 压缩包 SHA256 校验失败；期望=${expected}；实际=${actual}"
  if [[ -n "${XRAY_SHA256:-}" ]]; then
    local pinned="${XRAY_SHA256,,}"
    [[ "$pinned" =~ ^[0-9a-f]{64}$ ]] || die "XRAY_SHA256 必须是 64 位十六进制"
    [[ "$actual" == "$pinned" ]] || die "Xray 压缩包与显式 XRAY_SHA256 不一致；固定值=${pinned}；实际=${actual}"
  fi
}

xray_release_archive_is_valid() {
  local zip_file="$1" dgst_file="$2" expected actual pinned
  [[ -s "$zip_file" && -s "$dgst_file" ]] || return 1
  expected="$(xray_expected_sha256 "$dgst_file")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
  actual="$(sha256sum "$zip_file" 2>/dev/null | awk '{print tolower($1)}')"
  [[ "$actual" == "$expected" ]] || return 1
  if [[ -n "${XRAY_SHA256:-}" ]]; then
    pinned="${XRAY_SHA256,,}"
    [[ "$pinned" =~ ^[0-9a-f]{64}$ && "$actual" == "$pinned" ]] || return 1
  fi
}

prefetch_xray_release() {
  local version asset release_dir base_url zip_file dgst_file
  version="$(xray_resolve_release_version)"
  asset="$(xray_release_asset_name)"
  release_dir="${XRAY_CACHE_DIR}/${version}"
  base_url="https://github.com/XTLS/Xray-core/releases/download/${version}"
  zip_file="${release_dir}/${asset}"
  dgst_file="${zip_file}.dgst"
  install -d -m 755 "$release_dir"

  if xray_release_archive_is_valid "$zip_file" "$dgst_file"; then
    echo "✓ 使用已校验的 Xray 缓存: ${version}/${asset}"
  else
    rm -f "${zip_file}.tmp" "${dgst_file}.tmp"
    echo "⬇ 下载 Xray-core 官方 Release: ${version}/${asset}"
    if ! curl4 -L "${base_url}/${asset}" -o "${zip_file}.tmp"; then
      rm -f "${zip_file}.tmp"
      die "下载 Xray 压缩包失败"
    fi
    echo "⬇ 下载官方校验文件: ${asset}.dgst"
    if ! curl4 -L "${base_url}/${asset}.dgst" -o "${dgst_file}.tmp"; then
      rm -f "${zip_file}.tmp" "${dgst_file}.tmp"
      die "下载 Xray 校验文件失败"
    fi
    # Verify the temporary pair before publishing either cache file.  A bad
    # digest, truncated download, pin mismatch or signal therefore cannot
    # replace the last known-good cache entry.
    verify_xray_release_archive "${zip_file}.tmp" "${dgst_file}.tmp"
    mv -f "${zip_file}.tmp" "$zip_file"
    mv -f "${dgst_file}.tmp" "$dgst_file"
    chmod 644 "$zip_file" "$dgst_file"
  fi

  XRAY_SELECTED_VERSION="$version"
  XRAY_SELECTED_ZIP="$zip_file"
  export XRAY_SELECTED_VERSION XRAY_SELECTED_ZIP
}

extract_xray_binary_from_zip() {
  local zip_file="$1" work_dir="$2"
  python3 - "$zip_file" "$work_dir" <<'PYZIP'
import os
import stat
import sys
import zipfile
zip_file, work_dir = sys.argv[1], sys.argv[2]
out_path = os.path.join(work_dir, "xray")
try:
    with zipfile.ZipFile(zip_file) as zf:
        names = [n for n in zf.namelist() if not n.endswith('/') and os.path.basename(n) == 'xray']
        if len(names) != 1:
            raise RuntimeError(f'expected exactly one xray binary, found {len(names)}')
        data = zf.read(names[0])
except Exception as exc:
    print(f'解压 Xray 失败: {exc}', file=sys.stderr)
    raise SystemExit(1)
with open(out_path, 'wb') as fh:
    fh.write(data)
os.chmod(out_path, stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR |
                  stat.S_IRGRP | stat.S_IXGRP |
                  stat.S_IROTH | stat.S_IXOTH)
PYZIP
}

write_xray_systemd_unit() {
  local tmp="${XRAY_UNIT_FILE}.tmp.$$"
  install -d -m 755 /etc/systemd/system
  cat >"$tmp" <<UNIT
[Unit]
Description=Xray VLESS Reality Service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/bin/xray run -config ${XRAY_CONFIG_FILE}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1000000
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
  chmod 644 "$tmp"
  mv -f "$tmp" "$XRAY_UNIT_FILE"
}

install_xray_binary() {
  prefetch_xray_release
  local work_dir staged
  work_dir="$(mktemp -d "${XRAY_CACHE_DIR}/extract.XXXXXX")"
  extract_xray_binary_from_zip "$XRAY_SELECTED_ZIP" "$work_dir"
  [[ -s "${work_dir}/xray" ]] || die "解压后的 xray 二进制为空"
  "${work_dir}/xray" version >/dev/null 2>&1 || die "解压出的 xray 无法执行"

  install -d -m 755 /usr/local/bin
  staged="/usr/local/bin/xray.new.$$"
  install -m 755 -o root -g root "${work_dir}/xray" "$staged"
  "$staged" version >/dev/null 2>&1 || die "暂存的 xray 无法执行"
  local active_cfg
  if [[ -f "$XRAY_CONFIG_FILE" ]]; then
    "$staged" run -test -config "$XRAY_CONFIG_FILE" >/dev/null \
      || die "新 Xray 无法加载现有主配置，拒绝替换二进制"
  fi
  # Temporary configs are stored directly in XRAY_CONFIG_DIR and their tags
  # always begin with vless-temp-.  Test every one before replacing the binary
  # so a later watchdog/reboot cannot discover an incompatibility too late.
  for active_cfg in "${XRAY_CONFIG_DIR}"/vless-temp-*.json; do
    [[ -f "$active_cfg" ]] || continue
    "$staged" run -test -config "$active_cfg" >/dev/null \
      || die "新 Xray 无法加载临时节点配置：${active_cfg}；拒绝替换二进制"
  done
  mv -f "$staged" /usr/local/bin/xray
  rm -rf "$work_dir"
  /usr/local/bin/xray version
}

write_main_config() {
  local uuid="$1" private_key="$2" short_id="$3"
  local tmp="${XRAY_CONFIG_FILE}.tmp.$$"
  install -d -m 755 "$XRAY_CONFIG_DIR" "$MAIN_STATE_DIR"
  VR_CFG_PRIVATE_KEY="$private_key" \
    python3 - "$tmp" "$PORT" "$uuid" "$REALITY_DEST" "$REALITY_SNI" "$short_id" <<'PYCFG'
import json
import os
import sys
path, port, uuid, dest, sni, short_id = sys.argv[1:]
private_key = os.environ.pop("VR_CFG_PRIVATE_KEY")
cfg = {
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "listen": "0.0.0.0",
        "port": int(port),
        "protocol": "vless",
        "settings": {
            "clients": [{"id": uuid, "flow": "xtls-rprx-vision"}],
            "decryption": "none",
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": False,
                "dest": dest,
                "xver": 0,
                "serverNames": [sni],
                "privateKey": private_key,
                "shortIds": [short_id],
            },
        },
        "sniffing": {
            "enabled": True,
            "routeOnly": True,
            "destOverride": ["http", "tls", "quic"],
        },
    }],
    "outbounds": [
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"},
    ],
}
with open(path, 'w', encoding='utf-8') as fh:
    json.dump(cfg, fh, ensure_ascii=False, indent=2)
    fh.write('\n')
os.chmod(path, 0o600)
PYCFG
  chown root:root "$tmp"
  mv -f "$tmp" "$XRAY_CONFIG_FILE"
}

test_main_config() {
  /usr/local/bin/xray run -test -config "$XRAY_CONFIG_FILE" >/dev/null
}

enable_bbr() {
  echo "=== 1. 尝试启用 BBR ==="
  cat >/etc/sysctl.d/99-bbr.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSCTL
  modprobe tcp_bbr 2>/dev/null || true
  if ! sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1; then
    echo "⚠ 当前内核未接受全部 BBR 参数，继续安装 Xray" >&2
  fi
  echo "当前拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
}

extract_reality_keys() {
  local key_out="$1" private_key public_key

  private_key="$(
    printf '%s\n' "$key_out" | awk -F':[[:space:]]*' '
      /^[[:space:]]*(PrivateKey|Private key)[[:space:]]*:[[:space:]]*/ {
        value=$2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if (value != "") { print value; exit }
      }
    '
  )"
  public_key="$(
    printf '%s\n' "$key_out" | awk -F':[[:space:]]*' '
      /^[[:space:]]*(PublicKey|Public key|Password|Password \(PublicKey\))[[:space:]]*:[[:space:]]*/ {
        value=$2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if (value != "") { print value; exit }
      }
    '
  )"

  [[ "$private_key" =~ ^[A-Za-z0-9_+/=-]{40,128}$ ]] || return 1
  [[ "$public_key" =~ ^[A-Za-z0-9_+/=-]{40,128}$ ]] || return 1
  printf '%s\n%s\n' "$private_key" "$public_key"
}

load_reusable_credentials() {
  [[ -f "$MAIN_STATE_FILE" && -f "$XRAY_CONFIG_FILE" ]] || return 1
  [[ "$(stat -c %u "$MAIN_STATE_FILE" 2>/dev/null || echo -1)" == "0" ]] || return 1
  [[ "$(stat -c %u "$XRAY_CONFIG_FILE" 2>/dev/null || echo -1)" == "0" ]] || return 1
  local mode config_mode
  mode="$(stat -c %a "$MAIN_STATE_FILE" 2>/dev/null || echo 777)"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( ((8#$mode) & 8#022) == 0 )) || return 1
  config_mode="$(stat -c %a "$XRAY_CONFIG_FILE" 2>/dev/null || echo 777)"
  [[ "$config_mode" =~ ^[0-7]{3,4}$ ]] && (( ((8#$config_mode) & 8#022) == 0 )) || return 1
  python3 - "$MAIN_STATE_FILE" "$XRAY_CONFIG_FILE" <<'PYCREDS'
import json, re, sys
state_file, config_file = sys.argv[1:]
state = {}
with open(state_file, encoding='utf-8') as fh:
    for raw in fh:
        raw = raw.rstrip('\n')
        if '=' in raw and not raw.lstrip().startswith('#'):
            key, value = raw.split('=', 1)
            state[key] = value
with open(config_file, encoding='utf-8') as fh:
    cfg = json.load(fh)
inbound = cfg['inbounds'][0]
uuid = inbound['settings']['clients'][0]['id']
reality = inbound['streamSettings']['realitySettings']
private_key = reality['privateKey']
short_id = reality['shortIds'][0]
public_key = state.get('PBK', '')
if (uuid != state.get('UUID') or private_key != state.get('PRIVATE_KEY') or
        short_id != state.get('SHORT_ID')):
    raise SystemExit(1)
if not re.fullmatch(r'[0-9a-fA-F-]{36}', uuid):
    raise SystemExit(1)
if not re.fullmatch(r'[A-Za-z0-9_+/=-]{40,128}', private_key):
    raise SystemExit(1)
if not re.fullmatch(r'[A-Za-z0-9_+/=-]{40,128}', public_key):
    raise SystemExit(1)
if not re.fullmatch(r'[0-9a-fA-F]{16}', short_id):
    raise SystemExit(1)
print(uuid)
print(private_key)
print(public_key)
print(short_id.lower())
PYCREDS
}

urlencode() {
  python3 - "$1" <<'PYURL'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PYURL
}

wait_main_stable() {
  local consecutive=0 attempt
  for ((attempt=1; attempt<=15; attempt++)); do
    if systemctl is-active --quiet xray.service \
      && ss -ltnH 2>/dev/null | awk -v p="$PORT" '$4 ~ ":"p"$" {found=1} END{exit !found}'
    then
      consecutive=$((consecutive + 1))
      (( consecutive >= 3 )) && return 0
    else
      consecutive=0
    fi
    sleep 1
  done
  return 1
}

cleanup_transaction_temps() {
  rm -f -- \
    /usr/local/bin/xray.new.* \
    "${XRAY_CONFIG_FILE}.tmp."* \
    "${XRAY_UNIT_FILE}.tmp."* \
    "${MAIN_STATE_FILE}.tmp."* \
    /root/vless_reality_vision_url.txt.tmp.* \
    /root/v2ray_subscription_base64.txt.tmp.*
  if [[ -d "$XRAY_CACHE_DIR" ]]; then
    find "$XRAY_CACHE_DIR" -maxdepth 1 -type d -name 'extract.*' -exec rm -rf -- {} + 2>/dev/null || true
    find "$XRAY_CACHE_DIR" -mindepth 2 -maxdepth 2 -type f \
      \( -name 'Xray-linux-*.zip.tmp' -o -name 'Xray-linux-*.zip.dgst.tmp' \) \
      -delete 2>/dev/null || true
  fi
}

tx_backup_file() {
  local path="$1" key="$2"
  if [[ -e "$path" || -L "$path" ]]; then
    cp -a -- "$path" "${TX_DIR}/${key}"
    : >"${TX_DIR}/${key}.present"
  fi
}

tx_restore_file() {
  local path="$1" key="$2"
  rm -f -- "$path"
  if [[ -f "${TX_DIR}/${key}.present" ]]; then
    install -d -m 755 "$(dirname "$path")"
    cp -a -- "${TX_DIR}/${key}" "$path"
  fi
}

begin_transaction() {
  cleanup_transaction_temps
  TX_DIR="$(mktemp -d /var/tmp/vless-main-transaction.XXXXXX)"
  OLD_SERVICE_ACTIVE=0
  systemctl is-active --quiet xray.service 2>/dev/null && OLD_SERVICE_ACTIVE=1 || true
  OLD_SERVICE_ENABLED="$(systemctl is-enabled xray.service 2>/dev/null || true)"

  tx_backup_file /usr/local/bin/xray xray.bin
  tx_backup_file "$XRAY_CONFIG_FILE" config.json
  tx_backup_file "$XRAY_UNIT_FILE" xray.service
  tx_backup_file "$MAIN_STATE_FILE" main.env
  tx_backup_file /root/vless_reality_vision_url.txt main.url
  tx_backup_file /root/v2ray_subscription_base64.txt main.sub
  tx_backup_file /etc/sysctl.d/99-bbr.conf bbr.conf
  sysctl -n net.core.default_qdisc 2>/dev/null >"${TX_DIR}/old.default_qdisc" || true
  sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null >"${TX_DIR}/old.tcp_congestion_control" || true
  TX_ACTIVE=1
}

rollback_transaction() {
  (( TX_ACTIVE == 1 )) || return 0
  set +e
  echo "↩ 正在回滚 Xray 主节点事务..." >&2
  timeout 30 systemctl stop xray.service >/dev/null 2>&1 || true
  if [[ "$(systemctl is-active xray.service 2>/dev/null || true)" =~ ^(active|activating|deactivating)$ ]]; then
    systemctl kill --kill-who=all --signal=KILL xray.service >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
      [[ "$(systemctl is-active xray.service 2>/dev/null || true)" =~ ^(active|activating|deactivating)$ ]] || break
      sleep 1
    done
  fi
  systemctl disable xray.service >/dev/null 2>&1 || true

  tx_restore_file /usr/local/bin/xray xray.bin
  tx_restore_file "$XRAY_CONFIG_FILE" config.json
  tx_restore_file "$XRAY_UNIT_FILE" xray.service
  tx_restore_file "$MAIN_STATE_FILE" main.env
  tx_restore_file /root/vless_reality_vision_url.txt main.url
  tx_restore_file /root/v2ray_subscription_base64.txt main.sub
  tx_restore_file /etc/sysctl.d/99-bbr.conf bbr.conf
  if [[ -s "${TX_DIR}/old.default_qdisc" ]]; then
    sysctl -w "net.core.default_qdisc=$(cat "${TX_DIR}/old.default_qdisc")" >/dev/null 2>&1 || true
  fi
  if [[ -s "${TX_DIR}/old.tcp_congestion_control" ]]; then
    sysctl -w "net.ipv4.tcp_congestion_control=$(cat "${TX_DIR}/old.tcp_congestion_control")" >/dev/null 2>&1 || true
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
  case "$OLD_SERVICE_ENABLED" in
    enabled) systemctl enable xray.service >/dev/null 2>&1 || true ;;
    enabled-runtime) systemctl enable --runtime xray.service >/dev/null 2>&1 || true ;;
    disabled) systemctl disable xray.service >/dev/null 2>&1 || true ;;
    masked) systemctl mask xray.service >/dev/null 2>&1 || true ;;
    masked-runtime) systemctl mask --runtime xray.service >/dev/null 2>&1 || true ;;
  esac
  if (( OLD_SERVICE_ACTIVE == 1 )); then
    timeout 30 systemctl restart xray.service >/dev/null 2>&1 || true
  fi

  cleanup_transaction_temps
  TX_ACTIVE=0
  rm -rf "$TX_DIR"
  TX_DIR=""
  set -e
}

commit_transaction() {
  cleanup_transaction_temps
  TX_ACTIVE=0
  rm -rf "$TX_DIR"
  TX_DIR=""
}

validate_effective_xray_unit() {
  local effective_user effective_exec
  effective_user="$(systemctl show xray.service -p User --value)"
  effective_exec="$(systemctl show xray.service -p ExecStart --value)"
  [[ -z "$effective_user" || "$effective_user" == "root" ]] || \
    die "xray.service 的有效 User 被 drop-in 覆盖为 ${effective_user}"
  [[ "$effective_exec" == *"/usr/local/bin/xray"* ]] || \
    die "xray.service 的有效 ExecStart 未使用 /usr/local/bin/xray；请检查 drop-in"
  [[ "$effective_exec" == *"${XRAY_CONFIG_FILE}"* ]] || \
    die "xray.service 的有效 ExecStart 未使用 ${XRAY_CONFIG_FILE}；请检查 drop-in"
}

save_main_state() {
  local uuid="$1" private_key="$2" public_key="$3" short_id="$4"
  local tmp="${MAIN_STATE_FILE}.tmp.$$"
  install -d -m 700 "$MAIN_STATE_DIR"
  cat >"$tmp" <<STATE
PUBLIC_DOMAIN=${PUBLIC_DOMAIN}
CAMOUFLAGE_DOMAIN=${CAMOUFLAGE_DOMAIN:-}
REALITY_DEST=${REALITY_DEST}
REALITY_SNI=${REALITY_SNI}
PORT=${PORT}
NODE_NAME=${NODE_NAME}
UUID=${uuid}
PRIVATE_KEY=${private_key}
PBK=${public_key}
SHORT_ID=${short_id}
XRAY_VERSION=${XRAY_SELECTED_VERSION:-unknown}
INSTALL_EPOCH=$(date +%s)
STATE
  chmod 600 "$tmp"
  mv -f "$tmp" "$MAIN_STATE_FILE"
}

write_subscription_outputs() {
  local uuid="$1" public_key="$2" short_id="$3"
  local pbk_q sni_q name_q vless_url raw_tmp sub_tmp
  pbk_q="$(urlencode "$public_key")"
  sni_q="$(urlencode "$REALITY_SNI")"
  name_q="$(urlencode "$NODE_NAME")"
  vless_url="vless://${uuid}@${PUBLIC_DOMAIN}:${PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${sni_q}&fp=chrome&pbk=${pbk_q}&sid=${short_id}#${name_q}"

  raw_tmp="/root/vless_reality_vision_url.txt.tmp.$$"
  sub_tmp="/root/v2ray_subscription_base64.txt.tmp.$$"
  printf '%s\n' "$vless_url" >"$raw_tmp"
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    printf '%s' "$vless_url" | base64 -w0 >"$sub_tmp"
  else
    printf '%s' "$vless_url" | base64 | tr -d '\n' >"$sub_tmp"
  fi
  chmod 600 "$raw_tmp" "$sub_tmp"
  mv -f "$raw_tmp" /root/vless_reality_vision_url.txt
  mv -f "$sub_tmp" /root/v2ray_subscription_base64.txt

  echo
  echo "================== 节点信息 =================="
  cat /root/vless_reality_vision_url.txt
  echo
  echo "Base64 订阅："
  cat /root/v2ray_subscription_base64.txt
  echo
}

main() {
  check_supported_os
  acquire_main_lock
  need_basic_tools
  load_defaults
  ROTATE_CREDENTIALS="${ROTATE_CREDENTIALS:-0}"
  [[ "$ROTATE_CREDENTIALS" == "0" || "$ROTATE_CREDENTIALS" == "1" ]] \
    || die "ROTATE_CREDENTIALS 只能是 0 或 1"

  local -a server_ips
  mapfile -t server_ips < <(get_public_ipv4_candidates)
  (( ${#server_ips[@]} > 0 )) || die "无法检测到可用的公网 IPv4（可能被阻断或处于 NAT 后）"
  require_domain_points_here "$PUBLIC_DOMAIN" "${server_ips[@]}"

  echo "服务器公网 IPv4 候选: ${server_ips[*]}"
  echo "PUBLIC_DOMAIN: ${PUBLIC_DOMAIN}"
  echo "REALITY_DEST: ${REALITY_DEST}"
  echo "REALITY_SNI: ${REALITY_SNI}"
  echo "端口: ${PORT}"

  begin_transaction
  enable_bbr

  echo
  echo "=== 2. 安装 / 更新 Xray-core ==="
  install_xray_binary
  write_xray_systemd_unit

  echo
  echo "=== 3. 准备 UUID 与 Reality 密钥 ==="
  local uuid key_out private_key public_key short_id reusable_out
  local -a kp reusable
  reusable_out=""
  if [[ "$ROTATE_CREDENTIALS" == "0" ]]; then
    reusable_out="$(load_reusable_credentials 2>/dev/null || true)"
    if [[ -z "$reusable_out" && ( -f "$MAIN_STATE_FILE" || -f "$XRAY_CONFIG_FILE" ) ]]; then
      die "检测到现有主节点状态但凭据不一致；为避免意外失效，请先修复状态，或显式使用 ROTATE_CREDENTIALS=1"
    fi
  fi
  if [[ -n "$reusable_out" ]]; then
    mapfile -t reusable <<<"$reusable_out"
  else
    reusable=()
  fi
  if (( ${#reusable[@]} == 4 )); then
    uuid="${reusable[0]}"
    private_key="${reusable[1]}"
    public_key="${reusable[2]}"
    short_id="${reusable[3]}"
    echo "✓ 复用现有客户端凭据；如需轮换请显式设置 ROTATE_CREDENTIALS=1"
  else
    uuid="$(/usr/local/bin/xray uuid)"
    key_out="$(/usr/local/bin/xray x25519)"
    mapfile -t kp < <(extract_reality_keys "$key_out")
    (( ${#kp[@]} == 2 )) || {
      echo "$key_out" >&2
      die "无法解析 xray x25519 输出"
    }
    private_key="${kp[0]}"
    public_key="${kp[1]}"
    short_id="$(openssl rand -hex 8)"
  fi

  echo
  echo "=== 4. 写入并预检配置 ==="
  write_main_config "$uuid" "$private_key" "$short_id"
  test_main_config

  echo
  echo "=== 5. 重启并验证 xray.service ==="
  systemctl daemon-reload
  validate_effective_xray_unit
  systemctl enable xray.service >/dev/null
  systemctl restart xray.service
  if ! wait_main_stable; then
    systemctl --no-pager --full status xray.service >&2 || true
    journalctl -u xray.service --no-pager -n 120 >&2 || true
    die "xray 主节点稳定性校验失败"
  fi

  save_main_state "$uuid" "$private_key" "$public_key" "$short_id"
  write_subscription_outputs "$uuid" "$public_key" "$short_id"
  commit_transaction

  echo
  echo "✅ 主节点安装完成"
  echo "   Xray 版本: ${XRAY_SELECTED_VERSION}"
  echo "   IPv4 域名: ${PUBLIC_DOMAIN}"
  echo "   临时 IPv6 节点可通过 IP_VERSION=6 创建。"
}

main "$@"
__FINAL_MAIN__

cat >"$BUNDLE_AUDIT_TMP" <<'__FINAL_AUDIT__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
umask 077

die() {
  echo "❌ $*" >&2
  exit 1
}

check_supported_os() {
  [[ "$(id -u)" -eq 0 ]] || die "请以 root 运行本脚本"
  (( BASH_VERSINFO[0] >= 4 )) || die "需要 Bash 4.0 或更高版本"
  command -v apt-get >/dev/null 2>&1 || die "本脚本需要 apt-get（Debian/Ubuntu 系）"
  command -v dpkg >/dev/null 2>&1 || die "未找到 dpkg"

  local release_file="${VR_OS_RELEASE_FILE:-/etc/os-release}"
  local ID="" ID_LIKE="" VERSION_ID="" PRETTY_NAME=""
  local os_id os_id_like os_version pretty major
  if [[ ! -r "$release_file" && "$release_file" == "/etc/os-release" && -r /usr/lib/os-release ]]; then
    release_file="/usr/lib/os-release"
  fi
  [[ -r "$release_file" ]] || die "无法读取 os-release：${release_file}"

  # shellcheck disable=SC1090
  . "$release_file"
  os_id="${ID,,}"
  os_id_like=" ${ID_LIKE,,} "
  os_version="${VERSION_ID:-0}"
  pretty="${PRETTY_NAME:-${ID:-unknown} ${os_version}}"

  case "$os_id" in
    debian)
      major="${os_version%%.*}"
      [[ "$major" =~ ^[0-9]+$ ]] && (( major >= ${VR_MIN_DEBIAN_MAJOR:-11} )) \
        || die "${pretty} 太旧；最低支持 Debian ${VR_MIN_DEBIAN_MAJOR:-11}"
      ;;
    ubuntu)
      dpkg --compare-versions "$os_version" ge "${VR_MIN_UBUNTU_VERSION:-20.04}" \
        || die "${pretty} 太旧；最低支持 Ubuntu ${VR_MIN_UBUNTU_VERSION:-20.04}"
      ;;
    *)
      if [[ "$os_id_like" == *" debian "* && "${VR_ALLOW_DEBIAN_DERIVATIVE:-0}" == "1" ]]; then
        echo "⚠️  Debian 衍生系统兼容模式：${pretty}" >&2
      elif [[ "${VR_ALLOW_UNSUPPORTED_OS:-0}" == "1" ]]; then
        echo "⚠️  未正式支持的系统，按 VR_ALLOW_UNSUPPORTED_OS=1 继续：${pretty}" >&2
      else
        die "不支持的系统：${pretty}；支持 Debian ${VR_MIN_DEBIAN_MAJOR:-11}+ / Ubuntu ${VR_MIN_UBUNTU_VERSION:-20.04}+"
      fi
      ;;
  esac
}

apt_install_with_universe_retry() {
  local -a packages=("$@")
  if apt-get install -y --no-install-recommends "${packages[@]}"; then
    return 0
  fi

  local release_file="${VR_OS_RELEASE_FILE:-/etc/os-release}"
  local ID=""
  if [[ ! -r "$release_file" && "$release_file" == "/etc/os-release" && -r /usr/lib/os-release ]]; then
    release_file="/usr/lib/os-release"
  fi
  if [[ -r "$release_file" ]]; then
    # shellcheck disable=SC1090
    . "$release_file"
  fi
  if [[ "${ID,,}" == "ubuntu" ]]; then
    echo "⚠️  首次依赖安装失败，尝试启用 Ubuntu Universe 后重试..." >&2
    apt-get install -y --no-install-recommends software-properties-common >/dev/null 2>&1 || true
    if command -v add-apt-repository >/dev/null 2>&1; then
      add-apt-repository -y universe >/dev/null 2>&1 || true
      apt-get update -o Acquire::Retries=3
      apt-get install -y --no-install-recommends "${packages[@]}" && return 0
    fi
  fi
  die "依赖安装失败；请检查软件源、网络以及 Ubuntu Universe 是否已启用"
}

need_basic_tools() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -o Acquire::Retries=3
  apt_install_with_universe_retry \
    ca-certificates curl openssl python3 nftables iproute2 coreutils util-linux procps kmod findutils
}

check_runtime() {
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl"
  [[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')" == "systemd" ]] || \
    die "当前系统不是以 systemd 作为 PID 1"
  command -v nft >/dev/null 2>&1 || die "未找到 nft"
  command -v flock >/dev/null 2>&1 || die "未找到 flock"
  command -v timeout >/dev/null 2>&1 || die "未找到 timeout"
}

check_nft_features() {
  if ! nft -c -f - >/dev/null 2>&1 <<'NFT_PROBE'
add table inet vr_feature_probe
add chain inet vr_feature_probe input { type filter hook input priority 0; policy accept; }
add chain inet vr_feature_probe output { type filter hook output priority 0; policy accept; }
add counter inet vr_feature_probe c_in
add counter inet vr_feature_probe c_out
add quota inet vr_feature_probe q { over 1048576 bytes used 0 bytes }
add set inet vr_feature_probe s4 { type ipv4_addr; size 4; flags timeout,dynamic; timeout 120s; }
add set inet vr_feature_probe s6 { type ipv6_addr; size 4; flags timeout,dynamic; timeout 120s; }
add rule inet vr_feature_probe input meta nfproto ipv4 tcp dport 65534 ip saddr @s4 update @s4 { ip saddr timeout 120s } accept
add rule inet vr_feature_probe input meta nfproto ipv4 tcp dport 65534 add @s4 { ip saddr timeout 120s } accept
add rule inet vr_feature_probe input meta nfproto ipv6 tcp dport 65534 ip6 saddr @s6 update @s6 { ip6 saddr timeout 120s } accept
add rule inet vr_feature_probe input meta nfproto ipv6 tcp dport 65534 add @s6 { ip6 saddr timeout 120s } accept
add rule inet vr_feature_probe input tcp dport 65534 quota name "q" drop
add rule inet vr_feature_probe input tcp dport 65534 counter name "c_in"
add rule inet vr_feature_probe output tcp sport 65534 quota name "q" drop
add rule inet vr_feature_probe output tcp sport 65534 counter name "c_out"
NFT_PROBE
  then
    die "当前 nftables 不支持本脚本所需的 named counter、quota、IPv4/IPv6 timeout dynamic set 或 update 表达式"
  fi
}

MODULE_TX_ACTIVE=0
MODULE_TX_DIR=""
declare -A MODULE_UNIT_ACTIVE=()
declare -A MODULE_UNIT_ENABLED=()
MODULE_TIMERS=(vless-gc.timer pq-save.timer pq-reset.timer vless-managed-watchdog.timer)
MODULE_WORKER_SERVICES=(
  vless-gc.service pq-save.service pq-reset.service
  vless-managed-watchdog.service vless-managed-restore.service
  vless-managed-shutdown-save.service
)
MODULE_UNITS=(
  vless-gc.timer pq-save.timer pq-reset.timer vless-managed-watchdog.timer
  vless-managed-restore.service vless-managed-shutdown-save.service
)
MODULE_TARGETS=(
  /etc/tmpfiles.d/vless-reality.conf
  /etc/systemd/system/pq-reset.service
  /etc/systemd/system/pq-reset.timer
  /etc/systemd/system/pq-save.service
  /etc/systemd/system/pq-save.timer
  /etc/systemd/system/vless-gc.service
  /etc/systemd/system/vless-gc.timer
  /etc/systemd/system/vless-managed-restore.service
  /etc/systemd/system/vless-managed-watchdog.service
  /etc/systemd/system/vless-managed-watchdog.timer
  /etc/systemd/system/vless-managed-shutdown-save.service
  /usr/local/lib/vless-reality/common.sh
  /usr/local/lib/vless-reality/render_table.py
  /usr/local/lib/vless-reality/iplimit-lib.sh
  /usr/local/lib/vless-reality/quota-lib.sh
  /usr/local/sbin/iplimit_restore_all.sh
  /usr/local/sbin/pq_add.sh
  /usr/local/sbin/pq_audit.sh
  /usr/local/sbin/pq_del.sh
  /usr/local/sbin/ip_set.sh
  /usr/local/sbin/ip_del.sh
  /usr/local/sbin/pq_reset_due.sh
  /usr/local/sbin/pq_restore_all.sh
  /usr/local/sbin/pq_save_state.sh
  /usr/local/sbin/vless_audit.sh
  /usr/local/sbin/vless_cleanup_one.sh
  /usr/local/sbin/vless_clear_all.sh
  /usr/local/sbin/vless_gc.sh
  /usr/local/sbin/vless_mktemp.sh
  /usr/local/sbin/vless_restore_all.sh
  /usr/local/sbin/vless_managed_watchdog.sh
  /usr/local/sbin/vless_run_temp.sh
  /usr/local/sbin/vless_temp_sub.sh
  /root/vless_temp_subscription.txt
  /root/vless_temp_subscription_base64.txt
)

module_key_for_path() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

module_restore_enabled() {
  local unit="$1" state="$2"
  case "$state" in
    enabled) systemctl enable "$unit" >/dev/null 2>&1 || true ;;
    enabled-runtime) systemctl enable --runtime "$unit" >/dev/null 2>&1 || true ;;
    disabled) systemctl disable "$unit" >/dev/null 2>&1 || true ;;
    masked) systemctl mask "$unit" >/dev/null 2>&1 || true ;;
    masked-runtime) systemctl mask --runtime "$unit" >/dev/null 2>&1 || true ;;
  esac
}

module_begin_transaction() {
  local path key unit
  MODULE_TX_DIR="$(mktemp -d /var/tmp/vless-module-transaction.XXXXXX)"
  for path in "${MODULE_TARGETS[@]}"; do
    key="$(module_key_for_path "$path")"
    if [[ -e "$path" || -L "$path" ]]; then
      cp -a -- "$path" "${MODULE_TX_DIR}/${key}"
      : >"${MODULE_TX_DIR}/${key}.present"
    fi
  done
  for unit in "${MODULE_UNITS[@]}"; do
    MODULE_UNIT_ACTIVE["$unit"]=0
    # Only long-lived timer activity is meaningful to restore.  Restarting a
    # transient oneshot that happened to be active at the snapshot while this
    # installer still owns its locks can deadlock the rollback.
    if [[ "$unit" == *.timer ]]; then
      systemctl is-active --quiet "$unit" 2>/dev/null && MODULE_UNIT_ACTIVE["$unit"]=1 || true
    fi
    MODULE_UNIT_ENABLED["$unit"]="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  done
  MODULE_TX_ACTIVE=1
}

module_rollback() {
  (( MODULE_TX_ACTIVE == 1 )) || return 0
  MODULE_TX_ACTIVE=0
  set +e
  echo "↩ 正在回滚 VLESS 管理模块安装..." >&2
  timeout 30 systemctl stop "${MODULE_TIMERS[@]}" >/dev/null 2>&1 || true
  local path key unit
  # A Persistent timer can queue its worker just before it is stopped.  The
  # installer may already own that worker's locks, so do not wait indefinitely
  # and do not restore script files underneath a queued/running shell.
  for unit in "${MODULE_WORKER_SERVICES[@]}"; do
    timeout 10 systemctl stop "$unit" >/dev/null 2>&1 || true
    if [[ "$(systemctl is-active "$unit" 2>/dev/null || true)" =~ ^(active|activating|deactivating)$ ]]; then
      systemctl kill --kill-who=all --signal=KILL "$unit" >/dev/null 2>&1 || true
    fi
  done
  for unit in "${MODULE_UNITS[@]}"; do
    systemctl disable "$unit" >/dev/null 2>&1 || true
  done
  for path in "${MODULE_TARGETS[@]}"; do
    key="$(module_key_for_path "$path")"
    rm -f -- "$path"
    if [[ -f "${MODULE_TX_DIR}/${key}.present" ]]; then
      install -d -m 755 "$(dirname "$path")"
      cp -a -- "${MODULE_TX_DIR}/${key}" "$path"
    fi
  done
  systemctl daemon-reload >/dev/null 2>&1 || true
  # The new restore helper may already have rebuilt the owned nftables tables
  # before a later unit/timer step failed.  Restoring only files would leave a
  # first installation half-applied, or leave rules produced by the failed
  # version beside scripts from the previous version.  Reconcile while the
  # installer still owns temp -> quota -> iplimit locks.
  if [[ "${VR_TEMP_LOCK_HELD:-0}" == "1" \
        && "${VR_PQ_LOCK_HELD:-0}" == "1" \
        && "${VR_IL_LOCK_HELD:-0}" == "1" ]]; then
    if [[ -x /usr/local/sbin/vless_restore_all.sh ]]; then
      if ! timeout 60 env \
        VR_TEMP_LOCK_HELD=1 VR_PQ_LOCK_HELD=1 VR_IL_LOCK_HELD=1 \
        /usr/local/sbin/vless_restore_all.sh >/dev/null 2>&1
      then
        echo "⚠️  旧管理模块的 nftables 状态未能自动恢复；请在退出后运行 vless_restore_all.sh" >&2
      fi
    else
      # No previous restore helper means this was a first deployment.  These
      # two tables are exclusively owned by this module, so removing them
      # restores the pre-install runtime state instead of leaving a hidden
      # partial setup.
      nft delete table inet vr_pq >/dev/null 2>&1 || true
      nft delete table inet vr_iplimit >/dev/null 2>&1 || true
    fi
  fi
  for unit in "${MODULE_UNITS[@]}"; do
    module_restore_enabled "$unit" "${MODULE_UNIT_ENABLED[$unit]:-}"
    if [[ "${MODULE_UNIT_ACTIVE[$unit]:-0}" == "1" ]]; then
      systemctl start "$unit" >/dev/null 2>&1 || true
    fi
  done
  rm -rf -- "$MODULE_TX_DIR"
  MODULE_TX_DIR=""
  set -e
}

module_on_error() {
  local rc=$?
  echo "❌ ${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}:${BASH_LINENO[0]:-?}: ${BASH_COMMAND}" >&2
  return "$rc"
}

module_on_exit() {
  local rc=$?
  trap - EXIT ERR
  trap '' INT TERM HUP
  if (( MODULE_TX_ACTIVE == 1 )); then module_rollback || true; fi
  exit "$rc"
}

module_commit() {
  MODULE_TX_ACTIVE=0
  rm -rf -- "$MODULE_TX_DIR"
  MODULE_TX_DIR=""
}

quiesce_module_workers() {
  local unit state i
  for unit in "${MODULE_WORKER_SERVICES[@]}"; do
    # Give a normally finishing oneshot a short grace period before asking
    # systemd to stop it.  No installer locks are held yet, so it can finish.
    for ((i=1; i<=10; i++)); do
      state="$(systemctl is-active "$unit" 2>/dev/null || true)"
      [[ "$state" =~ ^(active|activating|deactivating)$ ]] || break
      sleep 1
    done
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    if [[ "$state" =~ ^(active|activating|deactivating)$ ]]; then
      timeout 20 systemctl stop "$unit" >/dev/null 2>&1 || true
      state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    fi
    if [[ "$state" =~ ^(active|activating|deactivating)$ ]]; then
      systemctl kill --kill-who=all --signal=KILL "$unit" >/dev/null 2>&1 || true
      sleep 1
      state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    fi
    [[ ! "$state" =~ ^(active|activating|deactivating)$ ]] \
      || die "无法停止旧的模块工作单元：${unit}"
  done
}

check_supported_os
command -v flock >/dev/null 2>&1 || die "缺少 flock（util-linux）"
install -d -m 755 /run/vless-reality
exec 6>/run/vless-reality/module-install.lock
flock -w 120 6 || die "另一个管理模块安装或刷新任务正在运行"
need_basic_tools
check_runtime
check_nft_features
module_begin_transaction
trap 'module_on_error' ERR
trap 'module_on_exit' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
timeout 30 systemctl stop "${MODULE_TIMERS[@]}" >/dev/null 2>&1 || true
quiesce_module_workers
exec 7>/run/vless-reality/temp.lock
flock -w 120 7 || die "temp 锁繁忙"
export VR_TEMP_LOCK_HELD=1
exec 9>/run/vless-reality/portquota.lock
flock -w 120 9 || die "portquota 锁繁忙"
export VR_PQ_LOCK_HELD=1
exec 8>/run/vless-reality/iplimit.lock
flock -w 120 8 || die "iplimit 锁繁忙"
export VR_IL_LOCK_HELD=1

# 重复安装前先把旧 named counter 合并进持久状态；否则随后重建 nft
# 对象会把上次保存之后的实时用量清零，等价于意外返还配额。
if [[ -x /usr/local/sbin/pq_save_state.sh ]]; then
  VR_PQ_LOCK_HELD=1 /usr/local/sbin/pq_save_state.sh \
    || die "刷新管理模块前保存现有配额失败"
fi

install -d -m 755 \
  /usr/local/lib/vless-reality \
  /usr/local/sbin \
  /var/lib/vless-reality \
  /run/vless-reality \
  /etc/tmpfiles.d \
  /etc/systemd/system
cat >'/etc/tmpfiles.d/vless-reality.conf' <<'__VR_FILE_1__'
d /run/vless-reality 0755 root root -
__VR_FILE_1__
chmod 644 '/etc/tmpfiles.d/vless-reality.conf'
systemd-tmpfiles --create /etc/tmpfiles.d/vless-reality.conf >/dev/null 2>&1 || true

cat >'/etc/systemd/system/pq-reset.service' <<'__VR_FILE_2__'
[Unit]
Description=Reset eligible managed quotas every 30 days
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pq_reset_due.sh
__VR_FILE_2__
chmod 644 '/etc/systemd/system/pq-reset.service'

cat >'/etc/systemd/system/pq-reset.timer' <<'__VR_FILE_3__'
[Unit]
Description=Check for due quota resets

[Timer]
OnBootSec=15min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
__VR_FILE_3__
chmod 644 '/etc/systemd/system/pq-reset.timer'

cat >'/etc/systemd/system/pq-save.service' <<'__VR_FILE_4__'
[Unit]
Description=Persist managed port quota usage and rebuild counters
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pq_save_state.sh
__VR_FILE_4__
chmod 644 '/etc/systemd/system/pq-save.service'

cat >'/etc/systemd/system/pq-save.timer' <<'__VR_FILE_5__'
[Unit]
Description=Run quota save every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
__VR_FILE_5__
chmod 644 '/etc/systemd/system/pq-save.timer'

cat >'/etc/systemd/system/vless-gc.service' <<'__VR_FILE_6__'
[Unit]
Description=GC expired temporary VLESS nodes
After=local-fs.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vless_gc.sh
__VR_FILE_6__
chmod 644 '/etc/systemd/system/vless-gc.service'

cat >'/etc/systemd/system/vless-gc.timer' <<'__VR_FILE_7__'
[Unit]
Description=Run VLESS temp GC regularly

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
__VR_FILE_7__
chmod 644 '/etc/systemd/system/vless-gc.timer'

cat >'/etc/systemd/system/vless-managed-restore.service' <<'__VR_FILE_8__'
[Unit]
Description=Restore managed VLESS quota, IP-family guards and IP-limit rules
After=local-fs.target systemd-tmpfiles-setup.service nftables.service
Before=multi-user.target
ConditionPathIsDirectory=/var/lib/vless-reality

[Service]
Type=oneshot
ExecStartPre=/bin/mkdir -p /run/vless-reality
ExecStartPre=/usr/bin/systemd-tmpfiles --create /etc/tmpfiles.d/vless-reality.conf
ExecStart=/usr/local/sbin/vless_restore_all.sh

[Install]
WantedBy=multi-user.target
__VR_FILE_8__
chmod 644 '/etc/systemd/system/vless-managed-restore.service'

cat >'/etc/systemd/system/vless-managed-watchdog.service' <<'__VR_FILE_WATCHDOG_SERVICE__'
[Unit]
Description=Repair missing managed VLESS nftables rules
After=local-fs.target network-online.target nftables.service
Wants=network-online.target
ConditionPathIsDirectory=/var/lib/vless-reality

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vless_managed_watchdog.sh
__VR_FILE_WATCHDOG_SERVICE__
chmod 644 '/etc/systemd/system/vless-managed-watchdog.service'

cat >'/etc/systemd/system/vless-managed-watchdog.timer' <<'__VR_FILE_WATCHDOG_TIMER__'
[Unit]
Description=Check managed VLESS nftables rules every minute

[Timer]
OnBootSec=90s
OnUnitActiveSec=1min
RandomizedDelaySec=10s
AccuracySec=10s

[Install]
WantedBy=timers.target
__VR_FILE_WATCHDOG_TIMER__
chmod 644 '/etc/systemd/system/vless-managed-watchdog.timer'

cat >'/etc/systemd/system/vless-managed-shutdown-save.service' <<'__VR_FILE_9__'
[Unit]
Description=Save managed VLESS quota usage before shutdown/reboot
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target poweroff.target kexec.target
After=local-fs.target

[Service]
Type=oneshot
ExecStartPre=/bin/mkdir -p /run/vless-reality
ExecStart=/usr/local/sbin/pq_save_state.sh
TimeoutStartSec=120

[Install]
WantedBy=shutdown.target
WantedBy=halt.target
WantedBy=reboot.target
WantedBy=poweroff.target
WantedBy=kexec.target
__VR_FILE_9__
chmod 644 '/etc/systemd/system/vless-managed-shutdown-save.service'

cat >'/usr/local/lib/vless-reality/common.sh' <<'__VR_FILE_10__'
#!/usr/bin/env bash
set -Eeuo pipefail

VR_BASE_DIR="/usr/local/lib/vless-reality"
VR_STATE_DIR="/var/lib/vless-reality"
VR_MAIN_STATE_DIR="${VR_STATE_DIR}/main"
VR_TEMP_STATE_DIR="${VR_STATE_DIR}/temp"
VR_QUOTA_STATE_DIR="${VR_STATE_DIR}/quota"
VR_IPLIMIT_STATE_DIR="${VR_STATE_DIR}/iplimit"
VR_XRAY_DIR="/usr/local/etc/xray"
VR_DEFAULTS_FILE="/etc/default/vless-reality"
VR_LOCK_DIR="/run/vless-reality"
VR_MAIN_STATE_FILE="${VR_MAIN_STATE_DIR}/main.env"

vr_die() {
  echo "❌ $*" >&2
  exit 1
}

vr_require_root_supported_os() {
  [[ "$(id -u)" -eq 0 ]] || vr_die "请以 root 身份运行"
  (( BASH_VERSINFO[0] >= 4 )) || vr_die "需要 Bash 4.0 或更高版本"
  command -v apt-get >/dev/null 2>&1 || vr_die "本脚本需要 apt-get（Debian/Ubuntu 系）"
  command -v dpkg >/dev/null 2>&1 || vr_die "未找到 dpkg"
  command -v systemctl >/dev/null 2>&1 || vr_die "未找到 systemctl"
  [[ -d /run/systemd/system ]] || vr_die "当前系统不是以 systemd 作为 PID 1"

  local release_file="${VR_OS_RELEASE_FILE:-/etc/os-release}"
  local ID="" ID_LIKE="" VERSION_ID="" PRETTY_NAME=""
  local os_id os_id_like os_version pretty major
  if [[ ! -r "$release_file" && "$release_file" == "/etc/os-release" && -r /usr/lib/os-release ]]; then
    release_file="/usr/lib/os-release"
  fi
  [[ -r "$release_file" ]] || vr_die "无法读取 os-release：${release_file}"

  # shellcheck disable=SC1090
  . "$release_file"
  os_id="${ID,,}"
  os_id_like=" ${ID_LIKE,,} "
  os_version="${VERSION_ID:-0}"
  pretty="${PRETTY_NAME:-${ID:-unknown} ${os_version}}"

  case "$os_id" in
    debian)
      major="${os_version%%.*}"
      [[ "$major" =~ ^[0-9]+$ ]] && (( major >= ${VR_MIN_DEBIAN_MAJOR:-11} )) \
        || vr_die "${pretty} 太旧；最低支持 Debian ${VR_MIN_DEBIAN_MAJOR:-11}"
      ;;
    ubuntu)
      dpkg --compare-versions "$os_version" ge "${VR_MIN_UBUNTU_VERSION:-20.04}" \
        || vr_die "${pretty} 太旧；最低支持 Ubuntu ${VR_MIN_UBUNTU_VERSION:-20.04}"
      ;;
    *)
      if [[ "$os_id_like" == *" debian "* && "${VR_ALLOW_DEBIAN_DERIVATIVE:-0}" == "1" ]]; then
        echo "⚠️  Debian 衍生系统兼容模式：${pretty}" >&2
      elif [[ "${VR_ALLOW_UNSUPPORTED_OS:-0}" == "1" ]]; then
        echo "⚠️  未正式支持的系统，按 VR_ALLOW_UNSUPPORTED_OS=1 继续：${pretty}" >&2
      else
        vr_die "不支持的系统：${pretty}；支持 Debian ${VR_MIN_DEBIAN_MAJOR:-11}+ / Ubuntu ${VR_MIN_UBUNTU_VERSION:-20.04}+"
      fi
      ;;
  esac
}

vr_ensure_runtime_dirs() {
  install -d -m 755 \
    "$VR_BASE_DIR" \
    "$VR_STATE_DIR" \
    "$VR_XRAY_DIR" \
    "$VR_LOCK_DIR"
  install -d -m 700 \
    "$VR_MAIN_STATE_DIR" \
    "$VR_TEMP_STATE_DIR" \
    "$VR_QUOTA_STATE_DIR" \
    "$VR_IPLIMIT_STATE_DIR"
}

vr_ensure_lock_dir() {
  install -d -m 755 "$VR_LOCK_DIR"
}

vr_open_lock_fd() {
  local fd="$1" file="$2"
  case "$fd" in
    7) exec 7>"$file" ;;
    8) exec 8>"$file" ;;
    9) exec 9>"$file" ;;
    *) vr_die "不允许的锁文件描述符：${fd}" ;;
  esac
}

vr_acquire_lock_fd() {
  local fd="$1" file="$2" wait_seconds="${3:-20}" fail_msg="${4:-锁繁忙}"
  vr_ensure_lock_dir
  vr_open_lock_fd "$fd" "$file"
  flock -w "$wait_seconds" "$fd" || vr_die "$fail_msg"
}

vr_try_lock_fd() {
  local fd="$1" file="$2"
  vr_ensure_lock_dir
  vr_open_lock_fd "$fd" "$file"
  flock -n "$fd"
}

vr_curl4() {
  curl -4fsS --connect-timeout 5 --max-time 60 --retry 3 --retry-delay 1 "$@"
}

vr_is_public_ipv4() {
  local ip="${1:-}"
  python3 - "$ip" <<'PY'
import ipaddress, sys
ip = (sys.argv[1] or '').strip()
try:
    addr = ipaddress.ip_address(ip)
    if addr.version == 4 and addr.is_global:
        raise SystemExit(0)
except Exception:
    pass
raise SystemExit(1)
PY
}

vr_get_public_ipv4_candidates() {
  local ip url
  {
    for url in \
      "https://api.ipify.org" \
      "https://ifconfig.me/ip" \
      "https://ipv4.icanhazip.com"
    do
      ip="$(vr_curl4 "$url" 2>/dev/null | tr -d ' \n\r' || true)"
      if [[ -n "$ip" ]] && vr_is_public_ipv4 "$ip"; then
        printf '%s\n' "$ip"
      fi
    done

    ip -4 -o addr show scope global 2>/dev/null \
      | awk '{split($4,a,"/"); print a[1]}' \
      | while read -r ip; do
          [[ -n "$ip" ]] || continue
          vr_is_public_ipv4 "$ip" && printf '%s\n' "$ip" || true
        done
  } | awk 'NF && !seen[$0]++'
}

vr_get_public_ipv4() {
  vr_get_public_ipv4_candidates | head -n1
}

vr_curl6() {
  curl -6fsS --connect-timeout 5 --max-time 60 --retry 3 --retry-delay 1 "$@"
}

vr_is_public_ipv6() {
  local ip="${1:-}"
  python3 - "$ip" <<'PY6'
import ipaddress, sys
try:
    addr = ipaddress.ip_address((sys.argv[1] or '').strip())
    raise SystemExit(0 if addr.version == 6 and addr.is_global else 1)
except Exception:
    raise SystemExit(1)
PY6
}

vr_get_public_ipv6_candidates() {
  local ip url
  {
    for url in \
      "https://api64.ipify.org" \
      "https://ipv6.icanhazip.com"
    do
      ip="$(vr_curl6 "$url" 2>/dev/null | tr -d ' \n\r' || true)"
      if [[ -n "$ip" ]] && vr_is_public_ipv6 "$ip"; then
        printf '%s\n' "$ip"
      fi
    done

    ip -6 -o addr show scope global 2>/dev/null \
      | awk '{split($4,a,"/"); print a[1]}' \
      | while read -r ip; do
          [[ -n "$ip" ]] || continue
          vr_is_public_ipv6 "$ip" && printf '%s\n' "$ip" || true
        done
  } | awk 'NF && !seen[$0]++'
}

vr_get_public_ipv6() {
  vr_get_public_ipv6_candidates | head -n1
}

vr_resolve_domain_ipv6s() {
  local domain="${1:-}"
  getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | sort -u
}

vr_ip_equal() {
  python3 - "$1" "$2" <<'PYIP'
import ipaddress, sys
try:
    raise SystemExit(0 if ipaddress.ip_address(sys.argv[1]) == ipaddress.ip_address(sys.argv[2]) else 1)
except Exception:
    raise SystemExit(1)
PYIP
}

vr_require_domain_aaaa_points_here() {
  local domain="$1"
  shift
  local resolved_ip candidate ok=1
  local -a resolved candidates
  mapfile -t resolved < <(vr_resolve_domain_ipv6s "$domain")
  candidates=("$@")
  (( ${#resolved[@]} > 0 )) || vr_die "无法解析 PUBLIC_IPV6_DOMAIN=${domain} 的 IPv6 AAAA 记录"
  (( ${#candidates[@]} > 0 )) || vr_die "未检测到本机可用的公网 IPv6"

  for resolved_ip in "${resolved[@]}"; do
    for candidate in "${candidates[@]}"; do
      if vr_ip_equal "$resolved_ip" "$candidate"; then
        ok=0
        break 2
      fi
    done
  done

  (( ok == 0 )) || vr_die "PUBLIC_IPV6_DOMAIN=${domain} 的 AAAA 记录未匹配本机公网 IPv6；AAAA=${resolved[*]}；本机候选=${candidates[*]}"
}

vr_normalize_domain() {
  python3 - "$1" <<'PYDOMAIN'
import ipaddress
import re
import sys
raw = (sys.argv[1] or '').strip().rstrip('.')
if not raw or any(ch.isspace() for ch in raw) or any(ch in raw for ch in '/?#@[]:'):
    raise SystemExit(1)
try:
    ipaddress.ip_address(raw)
    raise SystemExit(1)
except ValueError:
    pass
try:
    value = raw.encode('idna').decode('ascii').lower()
except Exception:
    raise SystemExit(1)
if len(value) > 253:
    raise SystemExit(1)
for label in value.split('.'):
    if not label or len(label) > 63 or not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?', label):
        raise SystemExit(1)
print(value)
PYDOMAIN
}

vr_vless_url_host() {
  local host="$1"
  if [[ "$host" == *:* && ( "${host:0:1}" != "[" || "${host: -1}" != "]" ) ]]; then
    printf '[%s]\n' "$host"
  else
    printf '%s\n' "$host"
  fi
}

vr_write_reality_config() {
  local file="$1" listen_addr="$2" port="$3" uuid="$4" dest="$5" sni="$6" private_key="$7" short_id="$8"
  local tmp="${file}.tmp.$$"
  VR_CFG_PRIVATE_KEY="$private_key" \
    python3 - "$tmp" "$listen_addr" "$port" "$uuid" "$dest" "$sni" "$short_id" <<'PYCFG'
import json
import os
import sys
path, listen_addr, port, uuid, dest, sni, short_id = sys.argv[1:]
private_key = os.environ.pop("VR_CFG_PRIVATE_KEY")
cfg = {
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "listen": listen_addr,
        "port": int(port),
        "protocol": "vless",
        "settings": {
            "clients": [{"id": uuid, "flow": "xtls-rprx-vision"}],
            "decryption": "none",
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": False,
                "dest": dest,
                "xver": 0,
                "serverNames": [sni],
                "privateKey": private_key,
                "shortIds": [short_id],
            },
        },
        "sniffing": {
            "enabled": True,
            "routeOnly": True,
            "destOverride": ["http", "tls", "quic"],
        },
    }],
    "outbounds": [
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"},
    ],
}
if listen_addr == "::":
    cfg["inbounds"][0]["streamSettings"]["sockopt"] = {"v6only": True}
with open(path, 'w', encoding='utf-8') as fh:
    json.dump(cfg, fh, ensure_ascii=False, indent=2)
    fh.write('\n')
os.chmod(path, 0o600)
PYCFG
  mv -f "$tmp" "$file"
  chown root:root "$file" 2>/dev/null || true
  chmod 600 "$file" 2>/dev/null || true
}

vr_test_xray_config() {
  local cfg="$1" bin="${2:-/usr/local/bin/xray}"
  [[ -x "$bin" ]] || vr_die "未找到 xray 可执行文件: ${bin}"
  "$bin" run -test -config "$cfg" >/dev/null
}

vr_load_defaults() {
  [[ -f "$VR_DEFAULTS_FILE" ]] || vr_die "未找到 ${VR_DEFAULTS_FILE}"
  [[ "$(stat -c %u "$VR_DEFAULTS_FILE" 2>/dev/null || echo -1)" == "0" ]] \
    || vr_die "${VR_DEFAULTS_FILE} 必须属于 root"
  local defaults_mode
  defaults_mode="$(stat -c %a "$VR_DEFAULTS_FILE" 2>/dev/null || echo 777)"
  [[ "$defaults_mode" =~ ^[0-7]{3,4}$ ]] && (( ((8#$defaults_mode) & 8#022) == 0 )) \
    || vr_die "${VR_DEFAULTS_FILE} 不能被 group/other 写入"
  set -a
  # shellcheck disable=SC1090
  . "$VR_DEFAULTS_FILE"
  set +a

  [[ -n "${PUBLIC_DOMAIN:-}" ]] || vr_die "${VR_DEFAULTS_FILE} 中必须设置 PUBLIC_DOMAIN"
  PUBLIC_DOMAIN="$(vr_normalize_domain "$PUBLIC_DOMAIN")" || vr_die "PUBLIC_DOMAIN 不是有效域名"
  if [[ -n "${PUBLIC_IPV6_DOMAIN:-}" ]]; then
    PUBLIC_IPV6_DOMAIN="$(vr_normalize_domain "$PUBLIC_IPV6_DOMAIN")" || vr_die "PUBLIC_IPV6_DOMAIN 不是有效域名"
  fi

  PORT="${PORT:-443}"
  NODE_NAME="${NODE_NAME:-VLESS-REALITY-IPv4}"
  [[ "$NODE_NAME" != *$'\n'* && "$NODE_NAME" != *$'\r'* ]] || vr_die "NODE_NAME 不能包含换行"

  if [[ -n "${CAMOUFLAGE_DOMAIN:-}" ]]; then
    CAMOUFLAGE_DOMAIN="$(vr_normalize_domain "$CAMOUFLAGE_DOMAIN")" || vr_die "CAMOUFLAGE_DOMAIN 不是有效域名"
    REALITY_DEST="${REALITY_DEST:-${CAMOUFLAGE_DOMAIN}:443}"
    REALITY_SNI="${REALITY_SNI:-${CAMOUFLAGE_DOMAIN}}"
  fi
  [[ -n "${REALITY_DEST:-}" ]] || vr_die "${VR_DEFAULTS_FILE} 中必须设置 REALITY_DEST（或 CAMOUFLAGE_DOMAIN）"
  [[ -n "${REALITY_SNI:-}" ]] || vr_die "${VR_DEFAULTS_FILE} 中必须设置 REALITY_SNI（或 CAMOUFLAGE_DOMAIN）"
  REALITY_SNI="$(vr_normalize_domain "$REALITY_SNI")" || vr_die "REALITY_SNI 不是有效域名"
  [[ "$REALITY_DEST" != *$'\n'* && "$REALITY_DEST" != *$'\r'* && "$REALITY_DEST" != *'"'* ]] || vr_die "REALITY_DEST 包含非法字符"
  [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || vr_die "PORT 必须是 1-65535 的整数"
}

vr_urlencode() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}

vr_urldecode() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.unquote(sys.argv[1]))
PY
}

vr_parse_gib_to_bytes() {
  python3 - "$1" <<'PY'
from decimal import Decimal, ROUND_DOWN
import sys
raw = (sys.argv[1] or '').strip()
try:
    d = Decimal(raw)
    if d <= 0:
        raise ValueError
except Exception:
    raise SystemExit(1)
bytes_val = (d * (1024 ** 3)).to_integral_value(rounding=ROUND_DOWN)
# Bash arithmetic below is signed 64-bit.  Leave ample headroom for the final
# packet/counter addition so a near-limit quota cannot wrap negative.
if bytes_val > 9000000000000000000:
    raise SystemExit(1)
print(int(bytes_val))
PY
}

vr_base64_one_line() {
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

vr_meta_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  awk -F= -v k="$key" '$0 !~ /^[[:space:]]*#/ && $1==k {sub($1"=", ""); print; exit}' "$file"
}

vr_meta_upsert() {
  local file="$1" key="$2" value="$3" tmp
  install -d -m 700 "$(dirname "$file")"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  if [[ -f "$file" ]] && grep -q "^${key}=" "$file" 2>/dev/null; then
    awk -F= -v k="$key" -v v="$value" '
      BEGIN { done = 0 }
      $1 == k { print k "=" v; done = 1; next }
      { print }
      END { if (!done) print k "=" v }
    ' "$file" >"$tmp"
  else
    if [[ -f "$file" ]]; then
      cat "$file" >"$tmp"
    fi
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$file" || return 1
}

vr_write_meta() {
  local file="$1"
  shift
  local tmp
  install -d -m 700 "$(dirname "$file")"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  : >"$tmp"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >>"$tmp"
  done
  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$file" || return 1
}

vr_port_is_listening() {
  local port="$1"
  ss -ltnH 2>/dev/null | awk -v p="$port" '$4 ~ ":"p"$" {found=1} END{exit !found}'
}

vr_wait_unit_and_port() {
  local unit="$1" port="$2"
  local need_consecutive="${3:-3}"
  local max_checks="${4:-12}"
  local consecutive=0
  local i
  for ((i=1; i<=max_checks; i++)); do
    if systemctl is-active --quiet "$unit" && vr_port_is_listening "$port"; then
      consecutive=$((consecutive + 1))
      if (( consecutive >= need_consecutive )); then
        return 0
      fi
    else
      consecutive=0
    fi
    sleep 1
  done
  return 1
}

vr_unit_state() {
  local unit="$1" state
  state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  case "$state" in
    active|reloading|inactive|failed|activating|deactivating) ;;
    "") if [[ -f "/etc/systemd/system/${unit}" || -f "/lib/systemd/system/${unit}" ]]; then state="inactive"; else state="missing"; fi ;;
    *) ;;
  esac
  printf '%s\n' "$state"
}

vr_human_bytes() {
  python3 - "$1" <<'PY'
import sys
n = int(sys.argv[1])
units = ['B', 'KiB', 'MiB', 'GiB', 'TiB']
v = float(n)
for u in units:
    if v < 1024 or u == units[-1]:
        print(f"{v:.2f}{u}")
        break
    v /= 1024.0
PY
}

vr_pct_text() {
  local used="$1" total="$2"
  python3 - "$used" "$total" <<'PY'
import sys
u = int(sys.argv[1])
t = int(sys.argv[2])
if t <= 0:
    print('N/A')
else:
    print(f"{(u * 100.0) / t:.1f}%")
PY
}

vr_ttl_human() {
  local expire_epoch="${1:-0}"
  if [[ -z "$expire_epoch" || ! "$expire_epoch" =~ ^[0-9]+$ ]]; then
    printf 'N/A\n'
    return 0
  fi
  local now left d h m s
  now="$(date +%s)"
  left=$((expire_epoch - now))
  if (( left <= 0 )); then
    printf 'expired\n'
    return 0
  fi
  d=$((left / 86400))
  h=$(((left % 86400) / 3600))
  m=$(((left % 3600) / 60))
  s=$((left % 60))
  printf '%02dd%02dh%02dm%02ds\n' "$d" "$h" "$m" "$s"
}

vr_beijing_time() {
  local epoch="${1:-0}"
  if [[ -z "$epoch" || ! "$epoch" =~ ^[0-9]+$ ]]; then
    printf 'N/A\n'
    return 0
  fi
  TZ='Asia/Shanghai' date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S'
}

vr_safe_tag() {
  local raw="$1"
  [[ "$raw" =~ ^[A-Za-z0-9._-]+$ ]] || vr_die "非法 id/tag: ${raw}；仅允许字母、数字、点、下划线、连字符"
  (( ${#raw} <= 96 )) || vr_die "id/tag 过长（最多 96 个 ASCII 字符）"
  printf '%s\n' "$raw"
}

vr_is_valid_temp_tag() {
  local tag="${1:-}"
  [[ "$tag" =~ ^vless-temp-[A-Za-z0-9._-]+$ && ${#tag} -le 107 ]]
}

vr_temp_tag_from_id() {
  local raw_id="$1"
  printf 'vless-temp-%s\n' "$raw_id"
}

vr_temp_meta_file() {
  printf '%s/%s.env\n' "$VR_TEMP_STATE_DIR" "$1"
}

vr_temp_cfg_file() {
  printf '%s/%s.json\n' "$VR_XRAY_DIR" "$1"
}

vr_temp_unit_file() {
  printf '/etc/systemd/system/%s.service\n' "$1"
}

vr_temp_url_file() {
  printf '%s/%s.url\n' "$VR_TEMP_STATE_DIR" "$1"
}

vr_temp_meta_by_port() {
  local wanted_port="$1" meta candidate_port tag found=""
  [[ "$wanted_port" =~ ^[0-9]+$ ]] || vr_die "端口必须为整数：${wanted_port}"
  for meta in "$VR_TEMP_STATE_DIR"/*.env; do
    [[ -f "$meta" ]] || continue
    candidate_port="$(vr_meta_get "$meta" PORT 2>/dev/null || true)"
    [[ "$candidate_port" == "$wanted_port" ]] || continue
    tag="$(vr_meta_get "$meta" TAG 2>/dev/null || true)"
    vr_is_valid_temp_tag "$tag" || vr_die "端口 ${wanted_port} 对应的临时节点 TAG 非法：${meta}"
    [[ "$tag" == "$(basename "$meta" .env)" ]] \
      || vr_die "端口 ${wanted_port} 对应的临时节点 TAG 与文件名不一致：${meta}"
    [[ -z "$found" ]] || vr_die "多个临时节点占用同一端口 ${wanted_port}，拒绝修改管理状态"
    found="$meta"
  done
  if [[ -n "$found" ]]; then
    printf '%s\n' "$found"
  fi
}

vr_quota_meta_file() {
  printf '%s/%s.env\n' "$VR_QUOTA_STATE_DIR" "$1"
}

vr_iplimit_meta_file() {
  printf '%s/%s.env\n' "$VR_IPLIMIT_STATE_DIR" "$1"
}

vr_collect_orphan_temp_tags_from_aux() {
  local meta owner_kind owner_tag
  for meta in "$VR_QUOTA_STATE_DIR"/*.env "$VR_IPLIMIT_STATE_DIR"/*.env; do
    [[ -f "$meta" ]] || continue
    owner_kind="$(vr_meta_get "$meta" OWNER_KIND 2>/dev/null || true)"
    owner_tag="$(vr_meta_get "$meta" OWNER_TAG 2>/dev/null || true)"
    [[ "$owner_kind" == "temp" ]] || continue
    vr_is_valid_temp_tag "$owner_tag" || continue
    [[ -f "$(vr_temp_meta_file "$owner_tag")" ]] && continue
    printf '%s\n' "$owner_tag"
  done | sort -u
}

vr_collect_temp_tags() {
  local meta unit tag
  {
    for meta in "$VR_TEMP_STATE_DIR"/*.env; do
      [[ -f "$meta" ]] || continue
      tag="$(vr_meta_get "$meta" TAG 2>/dev/null || true)"
      vr_is_valid_temp_tag "$tag" || continue
      [[ "$tag" == "$(basename "$meta" .env)" ]] || continue
      printf '%s\n' "$tag"
    done
    for unit in /etc/systemd/system/vless-temp-*.service; do
      [[ -f "$unit" ]] || continue
      tag="$(basename "$unit" .service)"
      vr_is_valid_temp_tag "$tag" || continue
      printf '%s\n' "$tag"
    done
    vr_collect_orphan_temp_tags_from_aux || true
  } | awk 'NF {print}' | sort -u
}

vr_temp_owner_port_from_aux() {
  local tag="$1"
  local file port
  for file in "$VR_QUOTA_STATE_DIR"/*.env "$VR_IPLIMIT_STATE_DIR"/*.env; do
    [[ -f "$file" ]] || continue
    if [[ "$(vr_meta_get "$file" OWNER_TAG || true)" == "$tag" ]]; then
      port="$(vr_meta_get "$file" PORT || true)"
      if [[ "$port" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$port"
        return 0
      fi
    fi
  done
  return 1
}

vr_temp_port_from_any() {
  local tag="$1"
  local meta cfg port
  meta="$(vr_temp_meta_file "$tag")"
  if [[ -f "$meta" ]]; then
    port="$(vr_meta_get "$meta" PORT || true)"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  fi
  if port="$(vr_temp_owner_port_from_aux "$tag" 2>/dev/null || true)"; then
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  fi
  cfg="$(vr_temp_cfg_file "$tag")"
  if [[ -f "$cfg" ]]; then
    port="$(python3 - "$cfg" <<'PY'
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as fh:
        cfg = json.load(fh)
    print(cfg['inbounds'][0]['port'])
except Exception:
    pass
PY
)"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  fi
  return 1
}

vr_read_main_reality() {
  local main_cfg="${VR_XRAY_DIR}/config.json"
  [[ -f "$main_cfg" ]] || vr_die "未找到主节点配置 ${main_cfg}，请先执行 /root/onekey_reality_ipv4.sh"
  python3 - "$main_cfg" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    cfg = json.load(fh)
ib = cfg.get('inbounds', [{}])[0]
rs = ib.get('streamSettings', {}).get('realitySettings', {})
sni_list = rs.get('serverNames', []) or []
print(rs.get('privateKey', ''))
print(rs.get('dest', ''))
print(sni_list[0] if sni_list else '')
print(ib.get('port', ''))
PY
}

vr_read_main_published() {
  local pbk public_domain port node_name short_id uuid
  pbk="$(vr_meta_get "$VR_MAIN_STATE_FILE" PBK 2>/dev/null || true)"
  public_domain="$(vr_meta_get "$VR_MAIN_STATE_FILE" PUBLIC_DOMAIN 2>/dev/null || true)"
  port="$(vr_meta_get "$VR_MAIN_STATE_FILE" PORT 2>/dev/null || true)"
  node_name="$(vr_meta_get "$VR_MAIN_STATE_FILE" NODE_NAME 2>/dev/null || true)"
  short_id="$(vr_meta_get "$VR_MAIN_STATE_FILE" SHORT_ID 2>/dev/null || true)"
  uuid="$(vr_meta_get "$VR_MAIN_STATE_FILE" UUID 2>/dev/null || true)"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$pbk" "$public_domain" "$port" "$node_name" "$short_id" "$uuid"
}

vr_main_url_published_pbk() {
  if [[ -f /root/vless_reality_vision_url.txt ]]; then
    sed -n '1p' /root/vless_reality_vision_url.txt 2>/dev/null | grep -o 'pbk=[^&]*' | head -n1 | cut -d= -f2
  fi
}

vr_current_public_domain() {
  local value
  value="$(vr_meta_get "$VR_MAIN_STATE_FILE" PUBLIC_DOMAIN 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    vr_load_defaults >/dev/null 2>&1 || true
    value="${PUBLIC_DOMAIN:-}"
  fi
  printf '%s\n' "$value"
}
__VR_FILE_10__
chmod 644 '/usr/local/lib/vless-reality/common.sh'

cat >'/usr/local/lib/vless-reality/render_table.py' <<'__VR_FILE_11__'
#!/usr/bin/env python3
import os
import shutil
import sys
import unicodedata

SCHEMAS = {
    "vless": [
        {"name": "NAME",  "min":  8, "ideal": 15, "max": 32, "align": "left",  "weight": 10},
        {"name": "STATE", "min":  6, "ideal":  6, "max":  8, "align": "left",  "weight":  1},
        {"name": "PORT",  "min":  5, "ideal":  5, "max":  5, "align": "right", "weight":  1},
        {"name": "IPV",   "min":  3, "ideal":  3, "max":  3, "align": "right", "weight":  1},
        {"name": "LISN",  "min":  4, "ideal":  4, "max":  4, "align": "left",  "weight":  1},
        {"name": "QUOTA", "min":  6, "ideal":  6, "max":  6, "align": "left",  "weight":  1},
        {"name": "LIMIT", "min":  7, "ideal":  8, "max": 12, "align": "right", "weight":  1},
        {"name": "USED",  "min":  7, "ideal":  8, "max": 12, "align": "right", "weight":  1},
        {"name": "LEFT",  "min":  7, "ideal":  8, "max": 12, "align": "right", "weight":  1},
        {"name": "USE%",  "min":  6, "ideal":  6, "max":  6, "align": "right", "weight":  1},
        {"name": "TTL",   "min":  6, "ideal":  8, "max": 12, "align": "left",  "weight":  2},
        {"name": "EXPBJ", "min":  8, "ideal": 12, "max": 19, "align": "left",  "weight":  3},
        {"name": "IPLM",  "min":  4, "ideal":  4, "max":  4, "align": "right", "weight":  1},
        {"name": "IPACT", "min":  5, "ideal":  5, "max":  5, "align": "right", "weight":  1},
        {"name": "STKY",  "min":  4, "ideal":  4, "max":  4, "align": "right", "weight":  1},
    ],
    "pq": [
        {"name": "PORT",   "min":  5, "ideal":  5, "max":  5, "align": "right", "weight":  1},
        {"name": "OWNER",  "min": 10, "ideal": 20, "max": 40, "align": "left",  "weight": 10},
        {"name": "STATE",  "min":  6, "ideal":  6, "max":  8, "align": "left",  "weight":  1},
        {"name": "LIMIT",  "min":  7, "ideal":  8, "max": 12, "align": "right", "weight":  1},
        {"name": "USED",   "min":  7, "ideal":  8, "max": 12, "align": "right", "weight":  1},
        {"name": "LEFT",   "min":  7, "ideal":  8, "max": 12, "align": "right", "weight":  1},
        {"name": "USE%",   "min":  6, "ideal":  6, "max":  6, "align": "right", "weight":  1},
        {"name": "RESET",  "min":  5, "ideal":  5, "max":  8, "align": "left",  "weight":  1},
        {"name": "NEXTBJ", "min":  8, "ideal": 12, "max": 19, "align": "left",  "weight":  3},
    ],
}


def char_width(ch: str) -> int:
    if not ch or ch in "\n\r" or unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def text_width(text: str) -> int:
    return sum(char_width(ch) for ch in text)


def take_prefix(text: str, width: int):
    out = []
    used = 0
    idx = 0
    while idx < len(text):
        ch = text[idx]
        if ch == "\n":
            idx += 1
            break
        w = char_width(ch)
        if used + w > width:
            break
        out.append(ch)
        used += w
        idx += 1
    return "".join(out), text[idx:]


def split_point(text: str, width: int) -> int:
    prefix, _ = take_prefix(text, width)
    if len(prefix) == len(text):
        return len(text)

    for i in range(len(prefix) - 1, -1, -1):
        ch = prefix[i]
        prev = prefix[i - 1] if i > 0 else ""

        if ch.isspace():
            return i + 1
        if ch in "/_-:@":
            return i + 1
        if i > 0 and prev.isdigit() and ch.isalpha():
            return i

    return len(prefix)


def wrap_cell(text: str, width: int):
    text = "-" if text in (None, "") else str(text)
    text = text.replace("\r", "")
    lines = []

    for part in text.split("\n"):
        part = part.strip()
        if not part:
            lines.append("")
            continue

        while part:
            if text_width(part) <= width:
                lines.append(part)
                break

            cut = split_point(part, width)
            left = part[:cut].rstrip()
            part = part[cut:].lstrip()

            if not left:
                left, part = take_prefix(part, width)

            lines.append(left)

    return lines or ["-"]


def pad(text: str, width: int, align: str):
    text = "" if text is None else str(text)
    if text_width(text) > width:
        text = take_prefix(text, width)[0]
    spaces = " " * max(0, width - text_width(text))
    return spaces + text if align == "right" else text + spaces


def border(left: str, mid: str, right: str, widths):
    return left + mid.join("━" * w for w in widths) + right


def terminal_columns() -> int:
    env_cols = os.environ.get("COLUMNS", "").strip()
    if env_cols.isdigit() and int(env_cols) > 0:
        return int(env_cols)
    return shutil.get_terminal_size(fallback=(120, 24)).columns


def allocate_widths(schema):
    mins = [c["min"] for c in schema]
    ideals = [c["ideal"] for c in schema]
    maxs = [c["max"] for c in schema]
    weights = [max(1, int(c.get("weight", 1))) for c in schema]

    widths = ideals[:]
    available = max(sum(mins), terminal_columns() - (len(schema) + 1))
    current = sum(widths)

    if current > available:
        deficit = current - available
        order = sorted(range(len(schema)), key=lambda i: (weights[i], ideals[i] - mins[i]), reverse=True)
        changed = True
        while deficit > 0 and changed:
            changed = False
            for i in order:
                if deficit <= 0:
                    break
                if widths[i] > mins[i]:
                    widths[i] -= 1
                    deficit -= 1
                    changed = True
    elif current < available:
        extra = available - current
        order = sorted(range(len(schema)), key=lambda i: (weights[i], maxs[i] - ideals[i]), reverse=True)
        changed = True
        while extra > 0 and changed:
            changed = False
            for i in order:
                if extra <= 0:
                    break
                if widths[i] < maxs[i]:
                    widths[i] += 1
                    extra -= 1
                    changed = True

    return widths


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in SCHEMAS:
        print("usage: render_table.py <vless|pq>", file=sys.stderr)
        sys.exit(2)

    schema = SCHEMAS[sys.argv[1]]
    headers = [c["name"] for c in schema]
    aligns = [c["align"] for c in schema]
    widths = allocate_widths(schema)

    rows = []
    for raw in sys.stdin:
        raw = raw.rstrip("\n")
        if not raw:
            continue
        cols = raw.split("\t")
        if len(cols) < len(schema):
            cols += [""] * (len(schema) - len(cols))
        rows.append(cols[:len(schema)])

    if not rows:
        rows = [["-"] * len(schema)]

    print(border("┏", "┳", "┓", widths))
    print("┃" + "│".join(pad(h, w, "left") for h, w in zip(headers, widths)) + "┃")
    print(border("┣", "╋", "┫", widths))

    for idx, row in enumerate(rows):
        wrapped = [wrap_cell(col, width) for col, width in zip(row, widths)]
        height = max(len(parts) for parts in wrapped)

        for line_no in range(height):
            out = []
            for col_idx, parts in enumerate(wrapped):
                text = parts[line_no] if line_no < len(parts) else ""
                out.append(pad(text, widths[col_idx], aligns[col_idx]))
            print("┃" + "│".join(out) + "┃")

        if idx != len(rows) - 1:
            print(border("┣", "╋", "┫", widths))

    print(border("┗", "┻", "┛", widths))


if __name__ == "__main__":
    main()
__VR_FILE_11__
chmod 755 '/usr/local/lib/vless-reality/render_table.py'

cat >'/usr/local/lib/vless-reality/iplimit-lib.sh' <<'__VR_FILE_12__'
#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh

VR_IL_TABLE="vr_iplimit"
VR_IL_INPUT_CHAIN="il_input"
VR_IL_LOCK_FILE="${VR_LOCK_DIR}/iplimit.lock"

vr_il_lock() {
  if [[ "${VR_IL_LOCK_HELD:-0}" != "1" ]]; then
    vr_acquire_lock_fd 8 "$VR_IL_LOCK_FILE" 20 "iplimit 锁繁忙"
    export VR_IL_LOCK_HELD=1
  fi
}

vr_il_set_name() {
  local port="$1" ip_version="${2:-4}"
  if [[ "$ip_version" == "6" ]]; then
    printf 'vr_il6_%s\n' "$port"
  else
    printf 'vr_il4_%s\n' "$port"
  fi
}
vr_il_comment_refresh() { printf 'vr-il-refresh-%s\n' "$1"; }
vr_il_comment_claim() { printf 'vr-il-claim-%s\n' "$1"; }
vr_il_comment_drop() { printf 'vr-il-drop-%s\n' "$1"; }
vr_il_comment_family() { printf 'vr-il-family-%s\n' "$1"; }

vr_il_meta_owner_exists() {
  local meta="$1" owner_tag owner_kind
  owner_tag="$(vr_meta_get "$meta" OWNER_TAG 2>/dev/null || true)"
  owner_kind="$(vr_meta_get "$meta" OWNER_KIND 2>/dev/null || true)"
  if [[ "$owner_kind" == "temp" && -n "$owner_tag" ]]; then
    [[ -f "$(vr_temp_meta_file "$owner_tag")" ]] || return 1
  fi
  return 0
}

vr_il_ensure_base() {
  vr_ensure_runtime_dirs || return 1
  command -v nft >/dev/null 2>&1 || vr_die "未找到 nft 命令"
  if ! nft list table inet "$VR_IL_TABLE" >/dev/null 2>&1; then
    nft add table inet "$VR_IL_TABLE" || return 1
  fi
  if ! nft list chain inet "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" >/dev/null 2>&1; then
    nft add chain inet "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" '{ type filter hook input priority -10; policy accept; }' || return 1
  fi
}

vr_il_delete_rules_with_comment() {
  local comment="$1"
  nft -a list chain inet "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" 2>/dev/null \
    | awk -v c="comment \"${comment}\"" '$0 ~ c {print $NF}' \
    | sort -rn \
    | while read -r handle; do
        [[ -n "$handle" ]] || continue
        nft delete rule inet "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" handle "$handle" >/dev/null 2>&1 || true
      done
}

vr_il_rule_comment_exists() {
  local comment="$1"
  local rules

  # Avoid `nft | grep -q` under pipefail: grep may exit early after a match,
  # causing nft to receive SIGPIPE and turning a real match into a false error.
  rules="$(
    nft -a list chain inet "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" 2>/dev/null || true
  )"
  [[ "$rules" == *"comment \"${comment}\""* ]]
}

vr_il_delete_port_rules() {
  local port="$1"
  vr_il_delete_rules_with_comment "$(vr_il_comment_refresh "$port")"
  vr_il_delete_rules_with_comment "$(vr_il_comment_claim "$port")"
  vr_il_delete_rules_with_comment "$(vr_il_comment_drop "$port")"
  vr_il_delete_rules_with_comment "$(vr_il_comment_family "$port")"
}

vr_il_delete_port_sets() {
  local port="$1"
  nft delete set inet "$VR_IL_TABLE" "$(vr_il_set_name "$port" 4)" >/dev/null 2>&1 || true
  nft delete set inet "$VR_IL_TABLE" "$(vr_il_set_name "$port" 6)" >/dev/null 2>&1 || true
  nft delete set inet "$VR_IL_TABLE" "vr_il_${port}" >/dev/null 2>&1 || true
}

vr_il_append_atomic_deletes() {
  local batch="$1" port="$2" comment handle set_name
  for comment in \
    "$(vr_il_comment_refresh "$port")" \
    "$(vr_il_comment_claim "$port")" \
    "$(vr_il_comment_drop "$port")" \
    "$(vr_il_comment_family "$port")"
  do
    while IFS= read -r handle; do
      [[ "$handle" =~ ^[0-9]+$ ]] || continue
      printf 'delete rule inet %s %s handle %s\n' "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" "$handle" >>"$batch"
    done < <(
      nft -a list chain inet "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" 2>/dev/null \
        | awk -v c="comment \"${comment}\"" '$0 ~ c {print $NF}' | sort -rn
    )
  done
  for set_name in "$(vr_il_set_name "$port" 4)" "$(vr_il_set_name "$port" 6)" "vr_il_${port}"; do
    if nft list set inet "$VR_IL_TABLE" "$set_name" >/dev/null 2>&1; then
      printf 'delete set inet %s %s\n' "$VR_IL_TABLE" "$set_name" >>"$batch"
    fi
  done
}

vr_il_failsafe_block_port() {
  local port="$1" batch
  vr_il_ensure_base || return 1
  batch="$(mktemp "${VR_LOCK_DIR}/iplimit-failsafe.XXXXXX")"
  vr_il_append_atomic_deletes "$batch" "$port"
  printf 'add rule inet %s %s tcp dport %s drop comment "%s"\n' \
    "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" "$port" "$(vr_il_comment_drop "$port")" >>"$batch"
  if ! nft -f "$batch"; then
    rm -f "$batch"
    return 1
  fi
  rm -f "$batch"
}

vr_il_apply_family_guard() {
  local port="$1" ip_version="${2:-4}" batch handle
  [[ "$port" =~ ^[0-9]+$ ]] || vr_die "vr_il_apply_family_guard: bad port ${port}"
  [[ "$ip_version" == "4" || "$ip_version" == "6" ]] || vr_die "IP_VERSION 只能是 4 或 6"
  vr_il_lock
  vr_il_ensure_base || return 1
  batch="$(mktemp "${VR_LOCK_DIR}/iplimit-family.XXXXXX")"
  while IFS= read -r handle; do
    [[ "$handle" =~ ^[0-9]+$ ]] || continue
    printf 'delete rule inet %s %s handle %s\n' "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" "$handle" >>"$batch"
  done < <(
    nft -a list chain inet "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" 2>/dev/null \
      | awk -v c="comment \"$(vr_il_comment_family "$port")\"" '$0 ~ c {print $NF}' | sort -rn
  )
  if [[ "$ip_version" == "6" ]]; then
    printf 'add rule inet %s %s meta nfproto ipv4 tcp dport %s drop comment "%s"\n' \
      "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" "$port" "$(vr_il_comment_family "$port")" >>"$batch"
  else
    printf 'add rule inet %s %s meta nfproto ipv6 tcp dport %s drop comment "%s"\n' \
      "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" "$port" "$(vr_il_comment_family "$port")" >>"$batch"
  fi
  if ! nft -f "$batch"; then
    rm -f "$batch"
    vr_il_failsafe_block_port "$port" || true
    return 1
  fi
  rm -f "$batch"
}

vr_il_family_guard_state() {
  local port="$1"
  if nft -a list chain inet "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" 2>/dev/null \
      | grep -Fq "comment \"$(vr_il_comment_family "$port")\""; then
    printf 'active\n'
  else
    printf 'stale\n'
  fi
}

vr_il_rebuild_port() {
  local port="$1" ip_limit="$2" sticky_seconds="$3" ip_version="${4:-4}" batch
  [[ "$port" =~ ^[0-9]+$ ]] || vr_die "vr_il_rebuild_port: bad port ${port}"
  [[ "$ip_limit" =~ ^[0-9]+$ ]] && (( ip_limit > 0 )) || vr_die "vr_il_rebuild_port: bad limit ${ip_limit}"
  [[ "$sticky_seconds" =~ ^[0-9]+$ ]] && (( sticky_seconds > 0 )) || vr_die "vr_il_rebuild_port: bad sticky ${sticky_seconds}"
  [[ "$ip_version" == "4" || "$ip_version" == "6" ]] || vr_die "vr_il_rebuild_port: bad IP_VERSION ${ip_version}"

  vr_il_lock
  vr_il_ensure_base || return 1
  batch="$(mktemp "${VR_LOCK_DIR}/iplimit-rebuild.XXXXXX")"
  vr_il_append_atomic_deletes "$batch" "$port"

  if [[ "$ip_version" == "6" ]]; then
    cat >>"$batch" <<EOF_RULES
add rule inet ${VR_IL_TABLE} ${VR_IL_INPUT_CHAIN} meta nfproto ipv4 tcp dport ${port} drop comment "$(vr_il_comment_family "$port")"
add set inet ${VR_IL_TABLE} $(vr_il_set_name "$port" 6) { type ipv6_addr; size ${ip_limit}; flags timeout,dynamic; timeout ${sticky_seconds}s; }
add rule inet ${VR_IL_TABLE} ${VR_IL_INPUT_CHAIN} meta nfproto ipv6 tcp dport ${port} ip6 saddr @$(vr_il_set_name "$port" 6) update @$(vr_il_set_name "$port" 6) { ip6 saddr timeout ${sticky_seconds}s } accept comment "$(vr_il_comment_refresh "$port")"
add rule inet ${VR_IL_TABLE} ${VR_IL_INPUT_CHAIN} meta nfproto ipv6 tcp dport ${port} add @$(vr_il_set_name "$port" 6) { ip6 saddr timeout ${sticky_seconds}s } accept comment "$(vr_il_comment_claim "$port")"
add rule inet ${VR_IL_TABLE} ${VR_IL_INPUT_CHAIN} meta nfproto ipv6 tcp dport ${port} drop comment "$(vr_il_comment_drop "$port")"
EOF_RULES
  else
    cat >>"$batch" <<EOF_RULES
add rule inet ${VR_IL_TABLE} ${VR_IL_INPUT_CHAIN} meta nfproto ipv6 tcp dport ${port} drop comment "$(vr_il_comment_family "$port")"
add set inet ${VR_IL_TABLE} $(vr_il_set_name "$port" 4) { type ipv4_addr; size ${ip_limit}; flags timeout,dynamic; timeout ${sticky_seconds}s; }
add rule inet ${VR_IL_TABLE} ${VR_IL_INPUT_CHAIN} meta nfproto ipv4 tcp dport ${port} ip saddr @$(vr_il_set_name "$port" 4) update @$(vr_il_set_name "$port" 4) { ip saddr timeout ${sticky_seconds}s } accept comment "$(vr_il_comment_refresh "$port")"
add rule inet ${VR_IL_TABLE} ${VR_IL_INPUT_CHAIN} meta nfproto ipv4 tcp dport ${port} add @$(vr_il_set_name "$port" 4) { ip saddr timeout ${sticky_seconds}s } accept comment "$(vr_il_comment_claim "$port")"
add rule inet ${VR_IL_TABLE} ${VR_IL_INPUT_CHAIN} meta nfproto ipv4 tcp dport ${port} drop comment "$(vr_il_comment_drop "$port")"
EOF_RULES
  fi
  if ! nft -f "$batch"; then
    rm -f "$batch"
    vr_il_failsafe_block_port "$port" || true
    return 1
  fi
  rm -f "$batch"
}

vr_il_write_meta() {
  local port="$1" owner_kind="$2" owner_tag="$3" ip_limit="$4" sticky_seconds="$5" ip_version="${6:-4}"
  vr_write_meta "$(vr_iplimit_meta_file "$port")" \
    "PORT=${port}" \
    "OWNER_KIND=${owner_kind}" \
    "OWNER_TAG=${owner_tag}" \
    "IP_LIMIT=${ip_limit}" \
    "IP_STICKY_SECONDS=${sticky_seconds}" \
    "IP_VERSION=${ip_version}" \
    "SET_NAME=$(vr_il_set_name "$port" "$ip_version")" \
    "CREATED_EPOCH=$(date +%s)"
}

vr_il_add_managed_port() {
  local port="$1" ip_limit="$2" sticky_seconds="$3" owner_kind="${4:-temp}" owner_tag="${5:-}" ip_version="${6:-4}"
  [[ "$port" =~ ^[0-9]+$ ]] || vr_die "端口必须为整数"
  [[ "$ip_limit" =~ ^[0-9]+$ ]] && (( ip_limit > 0 )) || vr_die "IP_LIMIT 必须为正整数"
  [[ "$sticky_seconds" =~ ^[0-9]+$ ]] && (( sticky_seconds > 0 )) || vr_die "IP_STICKY_SECONDS 必须为正整数"
  [[ "$ip_version" == "4" || "$ip_version" == "6" ]] || vr_die "IP_VERSION 只能是 4 或 6"
  vr_il_lock
  vr_il_ensure_base || return 1
  # Keep metadata and the nftables rules as one interruption-safe commit.  A
  # caller still receives its pending signal after this short child finishes,
  # while the child and nft process ignore ordinary termination signals.
  (
    trap '' INT TERM HUP
    vr_il_write_meta "$port" "$owner_kind" "$owner_tag" "$ip_limit" "$sticky_seconds" "$ip_version" \
      && vr_il_rebuild_port "$port" "$ip_limit" "$sticky_seconds" "$ip_version"
  ) || return 1
}

vr_il_delete_managed_port() {
  local port="$1" batch
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  vr_il_lock
  if nft list table inet "$VR_IL_TABLE" >/dev/null 2>&1; then
    batch="$(mktemp "${VR_LOCK_DIR}/iplimit-delete.XXXXXX")"
    vr_il_append_atomic_deletes "$batch" "$port"
    if ! nft -f "$batch"; then
      rm -f "$batch"
      return 1
    fi
    rm -f "$batch"
  fi
  rm -f "$(vr_iplimit_meta_file "$port")"
}

vr_il_restore_one() {
  local meta="$1"
  [[ -f "$meta" ]] || return 0
  vr_il_meta_owner_exists "$meta" || return 0
  local port ip_limit sticky_seconds ip_version
  port="$(vr_meta_get "$meta" PORT || true)"
  ip_limit="$(vr_meta_get "$meta" IP_LIMIT || true)"
  sticky_seconds="$(vr_meta_get "$meta" IP_STICKY_SECONDS || true)"
  ip_version="$(vr_meta_get "$meta" IP_VERSION 2>/dev/null || true)"
  ip_version="${ip_version:-4}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  [[ "$ip_limit" =~ ^[0-9]+$ ]] && (( ip_limit > 0 )) || return 0
  [[ "$sticky_seconds" =~ ^[0-9]+$ ]] && (( sticky_seconds > 0 )) || return 0
  [[ "$ip_version" == "4" || "$ip_version" == "6" ]] || ip_version=4
  vr_il_rebuild_port "$port" "$ip_limit" "$sticky_seconds" "$ip_version" || return 1
}

vr_il_active_ips() {
  local port="$1" ip_version="${2:-}" set_name
  if [[ -z "$ip_version" ]]; then
    ip_version="$(vr_meta_get "$(vr_iplimit_meta_file "$port")" IP_VERSION 2>/dev/null || true)"
    ip_version="${ip_version:-4}"
  fi
  set_name="$(vr_il_set_name "$port" "$ip_version")"
  nft -j list set inet "$VR_IL_TABLE" "$set_name" 2>/dev/null \
    | python3 -c '
import ipaddress
import json
import sys
version = int(sys.argv[1])
try:
    obj = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
values = []
def walk(x):
    if isinstance(x, dict):
        for k, v in x.items():
            if k == "val" and isinstance(v, str):
                try:
                    ip = ipaddress.ip_address(v)
                    if ip.version == version:
                        values.append(str(ip))
                except Exception:
                    pass
            walk(v)
    elif isinstance(x, list):
        for v in x:
            walk(v)
walk(obj)
print(" ".join(dict.fromkeys(values)))
' "$ip_version"
}

vr_il_active_count() {
  local port="$1" ips
  ips="$(vr_il_active_ips "$port" || true)"
  if [[ -z "$ips" ]]; then
    printf '0\n'
  else
    wc -w <<<"$ips" | tr -d ' '
  fi
}

vr_il_state() {
  local port="$1"
  local meta ip_version set_name rules comment

  meta="$(vr_iplimit_meta_file "$port")"
  [[ -f "$meta" ]] || { printf 'none\n'; return 0; }

  ip_version="$(vr_meta_get "$meta" IP_VERSION 2>/dev/null || true)"
  ip_version="${ip_version:-4}"
  if [[ "$ip_version" != "4" && "$ip_version" != "6" ]]; then
    printf 'stale\n'
    return 0
  fi

  set_name="$(vr_il_set_name "$port" "$ip_version")"
  if ! nft list set inet "$VR_IL_TABLE" "$set_name" >/dev/null 2>&1; then
    printf 'stale\n'
    return 0
  fi

  # Read one consistent chain snapshot instead of invoking nft four times.
  rules="$(
    nft -a list chain inet "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" 2>/dev/null || true
  )"
  [[ -n "$rules" ]] || { printf 'stale\n'; return 0; }

  for comment in \
    "$(vr_il_comment_refresh "$port")" \
    "$(vr_il_comment_claim "$port")" \
    "$(vr_il_comment_drop "$port")" \
    "$(vr_il_comment_family "$port")"
  do
    if [[ "$rules" != *"comment \"${comment}\""* ]]; then
      printf 'stale\n'
      return 0
    fi
  done

  printf 'active\n'
}
__VR_FILE_12__
chmod 644 '/usr/local/lib/vless-reality/iplimit-lib.sh'

cat >'/usr/local/lib/vless-reality/quota-lib.sh' <<'__VR_FILE_13__'
#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh

VR_PQ_TABLE="vr_pq"
VR_PQ_INPUT_CHAIN="pq_input"
VR_PQ_OUTPUT_CHAIN="pq_output"
VR_PQ_LOCK_FILE="${VR_LOCK_DIR}/portquota.lock"

vr_pq_lock() {
  if [[ "${VR_PQ_LOCK_HELD:-0}" != "1" ]]; then
    vr_acquire_lock_fd 9 "$VR_PQ_LOCK_FILE" 20 "portquota 锁繁忙"
    export VR_PQ_LOCK_HELD=1
  fi
}

vr_pq_counter_in() { printf 'vr_pq_in_%s\n' "$1"; }
vr_pq_counter_out() { printf 'vr_pq_out_%s\n' "$1"; }
vr_pq_quota_obj() { printf 'vr_pq_q_%s\n' "$1"; }
vr_pq_comment_count_in() { printf 'vr-pq-count-in-%s\n' "$1"; }
vr_pq_comment_count_out() { printf 'vr-pq-count-out-%s\n' "$1"; }
vr_pq_comment_drop_in() { printf 'vr-pq-drop-in-%s\n' "$1"; }
vr_pq_comment_drop_out() { printf 'vr-pq-drop-out-%s\n' "$1"; }

vr_pq_meta_owner_exists() {
  local meta="$1"
  local owner_tag owner_kind
  owner_tag="$(vr_meta_get "$meta" OWNER_TAG 2>/dev/null || true)"
  owner_kind="$(vr_meta_get "$meta" OWNER_KIND 2>/dev/null || true)"
  if [[ "$owner_kind" == "temp" && -n "$owner_tag" ]]; then
    [[ -f "$(vr_temp_meta_file "$owner_tag")" ]] || return 1
  fi
  return 0
}

vr_pq_ensure_base() {
  vr_ensure_runtime_dirs || return 1
  command -v nft >/dev/null 2>&1 || vr_die "未找到 nft 命令"
  if ! nft list table inet "$VR_PQ_TABLE" >/dev/null 2>&1; then
    nft add table inet "$VR_PQ_TABLE" || return 1
  fi
  if ! nft list chain inet "$VR_PQ_TABLE" "$VR_PQ_INPUT_CHAIN" >/dev/null 2>&1; then
    nft add chain inet "$VR_PQ_TABLE" "$VR_PQ_INPUT_CHAIN" '{ type filter hook input priority 0; policy accept; }' || return 1
  fi
  if ! nft list chain inet "$VR_PQ_TABLE" "$VR_PQ_OUTPUT_CHAIN" >/dev/null 2>&1; then
    nft add chain inet "$VR_PQ_TABLE" "$VR_PQ_OUTPUT_CHAIN" '{ type filter hook output priority 0; policy accept; }' || return 1
  fi
}

vr_pq_delete_rules_with_comment() {
  local chain="$1" comment="$2"
  nft -a list chain inet "$VR_PQ_TABLE" "$chain" 2>/dev/null \
    | awk -v c="comment \"${comment}\"" '$0 ~ c {print $NF}' \
    | sort -rn \
    | while read -r handle; do
        [[ -n "$handle" ]] || continue
        nft delete rule inet "$VR_PQ_TABLE" "$chain" handle "$handle" >/dev/null 2>&1 || true
      done
}

vr_pq_rule_comment_exists() {
  local chain="$1" comment="$2"
  local rules

  # Avoid `nft | grep -q` under pipefail for the same SIGPIPE reason as the
  # IP-limit state checker.
  rules="$(
    nft -a list chain inet "$VR_PQ_TABLE" "$chain" 2>/dev/null || true
  )"
  [[ "$rules" == *"comment \"${comment}\""* ]]
}

vr_pq_delete_port_rules() {
  local port="$1"
  vr_pq_delete_rules_with_comment "$VR_PQ_INPUT_CHAIN" "$(vr_pq_comment_drop_in "$port")"
  vr_pq_delete_rules_with_comment "$VR_PQ_INPUT_CHAIN" "$(vr_pq_comment_count_in "$port")"
  vr_pq_delete_rules_with_comment "$VR_PQ_OUTPUT_CHAIN" "$(vr_pq_comment_drop_out "$port")"
  vr_pq_delete_rules_with_comment "$VR_PQ_OUTPUT_CHAIN" "$(vr_pq_comment_count_out "$port")"
}

vr_pq_delete_port_objects() {
  local port="$1"
  nft delete counter inet "$VR_PQ_TABLE" "$(vr_pq_counter_in "$port")" >/dev/null 2>&1 || true
  nft delete counter inet "$VR_PQ_TABLE" "$(vr_pq_counter_out "$port")" >/dev/null 2>&1 || true
  nft delete quota inet "$VR_PQ_TABLE" "$(vr_pq_quota_obj "$port")" >/dev/null 2>&1 || true
}

vr_pq_append_atomic_deletes() {
  local batch="$1" port="$2" chain comment handle object kind name
  while IFS='|' read -r chain comment; do
    while IFS= read -r handle; do
      [[ "$handle" =~ ^[0-9]+$ ]] || continue
      printf 'delete rule inet %s %s handle %s\n' "$VR_PQ_TABLE" "$chain" "$handle" >>"$batch"
    done < <(
      nft -a list chain inet "$VR_PQ_TABLE" "$chain" 2>/dev/null \
        | awk -v c="comment \"${comment}\"" '$0 ~ c {print $NF}' | sort -rn
    )
  done <<EOF_COMMENTS
${VR_PQ_INPUT_CHAIN}|$(vr_pq_comment_drop_in "$port")
${VR_PQ_INPUT_CHAIN}|$(vr_pq_comment_count_in "$port")
${VR_PQ_OUTPUT_CHAIN}|$(vr_pq_comment_drop_out "$port")
${VR_PQ_OUTPUT_CHAIN}|$(vr_pq_comment_count_out "$port")
EOF_COMMENTS
  for object in \
    "counter|$(vr_pq_counter_in "$port")" \
    "counter|$(vr_pq_counter_out "$port")" \
    "quota|$(vr_pq_quota_obj "$port")"
  do
    kind="${object%%|*}"
    name="${object#*|}"
    if nft list "$kind" inet "$VR_PQ_TABLE" "$name" >/dev/null 2>&1; then
      printf 'delete %s inet %s %s\n' "$kind" "$VR_PQ_TABLE" "$name" >>"$batch"
    fi
  done
}

vr_pq_failsafe_block_port() {
  local port="$1" batch
  vr_pq_ensure_base || return 1
  batch="$(mktemp "${VR_LOCK_DIR}/quota-failsafe.XXXXXX")"
  vr_pq_append_atomic_deletes "$batch" "$port"
  printf 'add rule inet %s %s tcp dport %s drop comment "%s"\n' \
    "$VR_PQ_TABLE" "$VR_PQ_INPUT_CHAIN" "$port" "$(vr_pq_comment_drop_in "$port")" >>"$batch"
  printf 'add rule inet %s %s tcp sport %s drop comment "%s"\n' \
    "$VR_PQ_TABLE" "$VR_PQ_OUTPUT_CHAIN" "$port" "$(vr_pq_comment_drop_out "$port")" >>"$batch"
  if ! nft -f "$batch"; then
    rm -f "$batch"
    return 1
  fi
  rm -f "$batch"
}

vr_pq_rebuild_port() {
  local port="$1" remaining_bytes="$2" batch
  [[ "$port" =~ ^[0-9]+$ ]] || vr_die "vr_pq_rebuild_port: bad port ${port}"
  [[ "$remaining_bytes" =~ ^[0-9]+$ ]] || vr_die "vr_pq_rebuild_port: bad remaining ${remaining_bytes}"

  vr_pq_lock
  vr_pq_ensure_base || return 1
  batch="$(mktemp "${VR_LOCK_DIR}/quota-rebuild.XXXXXX")"
  vr_pq_append_atomic_deletes "$batch" "$port"

  if (( remaining_bytes > 0 )); then
    cat >>"$batch" <<EOF_RULES
add counter inet ${VR_PQ_TABLE} $(vr_pq_counter_in "$port")
add counter inet ${VR_PQ_TABLE} $(vr_pq_counter_out "$port")
add quota inet ${VR_PQ_TABLE} $(vr_pq_quota_obj "$port") { over ${remaining_bytes} bytes used 0 bytes }
add rule inet ${VR_PQ_TABLE} ${VR_PQ_INPUT_CHAIN} tcp dport ${port} quota name "$(vr_pq_quota_obj "$port")" drop comment "$(vr_pq_comment_drop_in "$port")"
add rule inet ${VR_PQ_TABLE} ${VR_PQ_INPUT_CHAIN} tcp dport ${port} counter name "$(vr_pq_counter_in "$port")" comment "$(vr_pq_comment_count_in "$port")"
add rule inet ${VR_PQ_TABLE} ${VR_PQ_OUTPUT_CHAIN} tcp sport ${port} quota name "$(vr_pq_quota_obj "$port")" drop comment "$(vr_pq_comment_drop_out "$port")"
add rule inet ${VR_PQ_TABLE} ${VR_PQ_OUTPUT_CHAIN} tcp sport ${port} counter name "$(vr_pq_counter_out "$port")" comment "$(vr_pq_comment_count_out "$port")"
EOF_RULES
  else
    cat >>"$batch" <<EOF_RULES
add rule inet ${VR_PQ_TABLE} ${VR_PQ_INPUT_CHAIN} tcp dport ${port} drop comment "$(vr_pq_comment_drop_in "$port")"
add rule inet ${VR_PQ_TABLE} ${VR_PQ_OUTPUT_CHAIN} tcp sport ${port} drop comment "$(vr_pq_comment_drop_out "$port")"
EOF_RULES
  fi
  if ! nft -f "$batch"; then
    rm -f "$batch"
    vr_pq_failsafe_block_port "$port" || true
    return 1
  fi
  rm -f "$batch"
}

vr_pq_counter_bytes() {
  local obj="$1"
  nft list counter inet "$VR_PQ_TABLE" "$obj" 2>/dev/null \
    | awk '/bytes/ { for (i = 1; i <= NF; i++) if ($i == "bytes") { gsub(/[^0-9]/, "", $(i+1)); print $(i+1); exit } }'
}

vr_pq_quota_used_bytes() {
  local obj="$1"
  nft -n list quota inet "$VR_PQ_TABLE" "$obj" 2>/dev/null \
    | awk '/used/ { for (i = 1; i <= NF; i++) if ($i == "used") { gsub(/[^0-9]/, "", $(i+1)); print $(i+1); exit } }'
}

vr_pq_live_used_bytes() {
  local port="$1"
  local quota_b in_b out_b
  # The named quota is the enforcing stateful object and counts the packet
  # that crosses the threshold as well as later over-limit packets.  The
  # following counters sit after an `over ... drop` rule, so by themselves
  # they can undercount the threshold-crossing packet and accidentally return
  # a small amount of quota at each save/rebuild cycle.
  quota_b="$(vr_pq_quota_used_bytes "$(vr_pq_quota_obj "$port")" || true)"
  if [[ "$quota_b" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$quota_b"
    return 0
  fi
  in_b="$(vr_pq_counter_bytes "$(vr_pq_counter_in "$port")" || true)"
  out_b="$(vr_pq_counter_bytes "$(vr_pq_counter_out "$port")" || true)"
  in_b="${in_b:-0}"
  out_b="${out_b:-0}"
  [[ "$in_b" =~ ^[0-9]+$ ]] || in_b=0
  [[ "$out_b" =~ ^[0-9]+$ ]] || out_b=0
  printf '%s\n' $((in_b + out_b))
}

vr_pq_state() {
  local port="$1"
  local meta
  meta="$(vr_quota_meta_file "$port")"
  [[ -f "$meta" ]] || { printf 'none\n'; return 0; }
  local original saved live used left rebuild_pending
  rebuild_pending="$(vr_meta_get "$meta" REBUILD_PENDING 2>/dev/null || true)"
  if [[ "$rebuild_pending" == "1" ]]; then
    printf 'stale\n'
    return 0
  fi
  original="$(vr_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  saved="$(vr_meta_get "$meta" SAVED_USED_BYTES || true)"
  original="${original:-0}"
  saved="${saved:-0}"
  [[ "$original" =~ ^[0-9]+$ && "$saved" =~ ^[0-9]+$ ]] || { printf 'stale\n'; return 0; }
  live="$(vr_pq_live_used_bytes "$port" || true)"
  live="${live:-0}"
  used=$((saved + live))
  left=$((original - used))
  if (( left <= 0 )); then
    if vr_pq_rule_comment_exists "$VR_PQ_INPUT_CHAIN" "$(vr_pq_comment_drop_in "$port")" \
      && vr_pq_rule_comment_exists "$VR_PQ_OUTPUT_CHAIN" "$(vr_pq_comment_drop_out "$port")"
    then
      printf 'exhausted\n'
    else
      printf 'stale\n'
    fi
    return 0
  fi
  if nft list counter inet "$VR_PQ_TABLE" "$(vr_pq_counter_in "$port")" >/dev/null 2>&1 \
    && nft list counter inet "$VR_PQ_TABLE" "$(vr_pq_counter_out "$port")" >/dev/null 2>&1 \
    && nft list quota inet "$VR_PQ_TABLE" "$(vr_pq_quota_obj "$port")" >/dev/null 2>&1 \
    && vr_pq_rule_comment_exists "$VR_PQ_INPUT_CHAIN" "$(vr_pq_comment_drop_in "$port")" \
    && vr_pq_rule_comment_exists "$VR_PQ_INPUT_CHAIN" "$(vr_pq_comment_count_in "$port")" \
    && vr_pq_rule_comment_exists "$VR_PQ_OUTPUT_CHAIN" "$(vr_pq_comment_drop_out "$port")" \
    && vr_pq_rule_comment_exists "$VR_PQ_OUTPUT_CHAIN" "$(vr_pq_comment_count_out "$port")"
  then
    printf 'active\n'
  else
    printf 'stale\n'
  fi
}

vr_pq_write_meta() {
  local port="$1" original="$2" saved="$3" remaining="$4" owner_kind="$5" owner_tag="$6" duration_seconds="$7" expire_epoch="$8" next_reset_epoch="$9" interval_seconds="${10}" created_epoch="${11}" last_reset_epoch="${12}" last_save_epoch="${13}" rebuild_pending="${14:-0}"
  vr_write_meta "$(vr_quota_meta_file "$port")" \
    "PORT=${port}" \
    "ORIGINAL_LIMIT_BYTES=${original}" \
    "SAVED_USED_BYTES=${saved}" \
    "LIMIT_BYTES=${remaining}" \
    "OWNER_KIND=${owner_kind}" \
    "OWNER_TAG=${owner_tag}" \
    "DURATION_SECONDS=${duration_seconds}" \
    "EXPIRE_EPOCH=${expire_epoch}" \
    "RESET_INTERVAL_SECONDS=${interval_seconds}" \
    "NEXT_RESET_EPOCH=${next_reset_epoch}" \
    "CREATED_EPOCH=${created_epoch}" \
    "LAST_RESET_EPOCH=${last_reset_epoch}" \
    "LAST_SAVE_EPOCH=${last_save_epoch}" \
    "REBUILD_PENDING=${rebuild_pending}"
}

vr_pq_add_managed_port() {
  local port="$1" original_bytes="$2" owner_kind="${3:-manual}" owner_tag="${4:-}" duration_seconds="${5:-0}" expire_epoch="${6:-0}"
  [[ "$port" =~ ^[0-9]+$ ]] || vr_die "端口必须为整数"
  [[ "$original_bytes" =~ ^[0-9]+$ ]] || vr_die "original_bytes 必须为整数"
  (( original_bytes > 0 )) || vr_die "配额必须大于 0"

  vr_pq_lock
  vr_pq_ensure_base || return 1

  local created_epoch interval_seconds next_reset_epoch
  created_epoch="$(date +%s)"
  interval_seconds=0
  next_reset_epoch=0
  if [[ "$duration_seconds" =~ ^[0-9]+$ ]] && (( duration_seconds > 2592000 )); then
    interval_seconds=2592000
    next_reset_epoch=$((created_epoch + interval_seconds))
  fi

  (
    trap '' INT TERM HUP
    vr_pq_write_meta "$port" "$original_bytes" 0 "$original_bytes" "$owner_kind" "$owner_tag" "${duration_seconds:-0}" "${expire_epoch:-0}" "$next_reset_epoch" "$interval_seconds" "$created_epoch" 0 "$created_epoch" 1 \
      && vr_pq_rebuild_port "$port" "$original_bytes" \
      && vr_meta_upsert "$(vr_quota_meta_file "$port")" REBUILD_PENDING 0
  ) || return 1
}

vr_pq_delete_managed_port() {
  local port="$1" batch
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  vr_pq_lock
  if nft list table inet "$VR_PQ_TABLE" >/dev/null 2>&1; then
    batch="$(mktemp "${VR_LOCK_DIR}/quota-delete.XXXXXX")"
    vr_pq_append_atomic_deletes "$batch" "$port"
    if ! nft -f "$batch"; then
      rm -f "$batch"
      return 1
    fi
    rm -f "$batch"
  fi
  rm -f "$(vr_quota_meta_file "$port")"
}

vr_pq_save_one() {
  local meta="$1"
  [[ -f "$meta" ]] || return 0
  vr_pq_meta_owner_exists "$meta" || return 0

  local port original saved live new_saved left next_reset_epoch interval_seconds created_epoch last_reset_epoch owner_kind owner_tag duration_seconds expire_epoch rebuild_pending pending_remaining
  port="$(vr_meta_get "$meta" PORT || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  rebuild_pending="$(vr_meta_get "$meta" REBUILD_PENDING 2>/dev/null || true)"
  if [[ "$rebuild_pending" == "1" ]]; then
    pending_remaining="$(vr_meta_get "$meta" LIMIT_BYTES 2>/dev/null || true)"
    [[ "$pending_remaining" =~ ^[0-9]+$ ]] || pending_remaining=0
    (
      trap '' INT TERM HUP
      vr_pq_rebuild_port "$port" "$pending_remaining" \
        && vr_meta_upsert "$meta" REBUILD_PENDING 0
    ) || return 1
    return 0
  fi
  original="$(vr_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  saved="$(vr_meta_get "$meta" SAVED_USED_BYTES || true)"
  owner_kind="$(vr_meta_get "$meta" OWNER_KIND || true)"
  owner_tag="$(vr_meta_get "$meta" OWNER_TAG || true)"
  duration_seconds="$(vr_meta_get "$meta" DURATION_SECONDS || true)"
  expire_epoch="$(vr_meta_get "$meta" EXPIRE_EPOCH || true)"
  next_reset_epoch="$(vr_meta_get "$meta" NEXT_RESET_EPOCH || true)"
  interval_seconds="$(vr_meta_get "$meta" RESET_INTERVAL_SECONDS || true)"
  created_epoch="$(vr_meta_get "$meta" CREATED_EPOCH || true)"
  last_reset_epoch="$(vr_meta_get "$meta" LAST_RESET_EPOCH || true)"
  original="${original:-0}"
  saved="${saved:-0}"
  [[ "$original" =~ ^[0-9]+$ && "$saved" =~ ^[0-9]+$ ]] || return 1
  live="$(vr_pq_live_used_bytes "$port" || true)"
  live="${live:-0}"
  new_saved=$((saved + live))
  if (( new_saved > original )); then
    new_saved="$original"
  fi
  left=$((original - new_saved))
  if (( left < 0 )); then
    left=0
  fi
  # Writing the accumulated counter value before rebuilding is deliberately
  # fail-closed on power loss.  Shield the two-step commit from INT/TERM/HUP so
  # ordinary interruption cannot leave the old live counters beside the new
  # saved value (which would otherwise double-count on the next repair).
  (
    trap '' INT TERM HUP
    vr_pq_write_meta "$port" "$original" "$new_saved" "$left" "$owner_kind" "$owner_tag" "${duration_seconds:-0}" "${expire_epoch:-0}" "${next_reset_epoch:-0}" "${interval_seconds:-0}" "${created_epoch:-$(date +%s)}" "${last_reset_epoch:-0}" "$(date +%s)" 1 \
      && vr_pq_rebuild_port "$port" "$left" \
      && vr_meta_upsert "$meta" REBUILD_PENDING 0
  ) || return 1
}

vr_pq_restore_one() {
  local meta="$1"
  [[ -f "$meta" ]] || return 0
  vr_pq_meta_owner_exists "$meta" || return 0
  local port remaining
  port="$(vr_meta_get "$meta" PORT || true)"
  remaining="$(vr_meta_get "$meta" LIMIT_BYTES || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  [[ "$remaining" =~ ^[0-9]+$ ]] || remaining=0
  (
    trap '' INT TERM HUP
    vr_pq_rebuild_port "$port" "$remaining" \
      && vr_meta_upsert "$meta" REBUILD_PENDING 0
  ) || return 1
}

vr_pq_reset_due_one() {
  local meta="$1"
  [[ -f "$meta" ]] || return 0
  vr_pq_meta_owner_exists "$meta" || return 0

  local port original owner_kind owner_tag duration_seconds expire_epoch interval_seconds next_reset_epoch created_epoch now last_reset_epoch
  port="$(vr_meta_get "$meta" PORT || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  original="$(vr_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  owner_kind="$(vr_meta_get "$meta" OWNER_KIND || true)"
  owner_tag="$(vr_meta_get "$meta" OWNER_TAG || true)"
  duration_seconds="$(vr_meta_get "$meta" DURATION_SECONDS || true)"
  expire_epoch="$(vr_meta_get "$meta" EXPIRE_EPOCH || true)"
  interval_seconds="$(vr_meta_get "$meta" RESET_INTERVAL_SECONDS || true)"
  next_reset_epoch="$(vr_meta_get "$meta" NEXT_RESET_EPOCH || true)"
  created_epoch="$(vr_meta_get "$meta" CREATED_EPOCH || true)"
  last_reset_epoch="$(vr_meta_get "$meta" LAST_RESET_EPOCH || true)"

  [[ "$original" =~ ^[0-9]+$ ]] && (( original > 0 )) || return 1

  [[ "$interval_seconds" =~ ^[0-9]+$ ]] || interval_seconds=0
  (( interval_seconds > 0 )) || return 0
  now="$(date +%s)"
  [[ "$next_reset_epoch" =~ ^[0-9]+$ ]] || next_reset_epoch=0
  (( next_reset_epoch > 0 )) || return 0
  if [[ "$expire_epoch" =~ ^[0-9]+$ ]] && (( expire_epoch > 0 && expire_epoch <= now )); then
    return 0
  fi
  (( now >= next_reset_epoch )) || return 0

  while (( next_reset_epoch <= now )); do
    next_reset_epoch=$((next_reset_epoch + interval_seconds))
  done

  (
    trap '' INT TERM HUP
    vr_pq_write_meta "$port" "$original" 0 "$original" "$owner_kind" "$owner_tag" "${duration_seconds:-0}" "${expire_epoch:-0}" "$next_reset_epoch" "$interval_seconds" "${created_epoch:-$now}" "$now" "$now" 1 \
      && vr_pq_rebuild_port "$port" "$original" \
      && vr_meta_upsert "$meta" REBUILD_PENDING 0
  ) || return 1
}
__VR_FILE_13__
chmod 644 '/usr/local/lib/vless-reality/quota-lib.sh'

cat >'/usr/local/sbin/iplimit_restore_all.sh' <<'__VR_FILE_14__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/iplimit-lib.sh

vr_ensure_runtime_dirs
vr_il_lock
rc=0
now="$(date +%s)"

for meta in "$VR_TEMP_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  port="$(vr_meta_get "$meta" PORT || true)"
  ip_version="$(vr_meta_get "$meta" IP_VERSION 2>/dev/null || true)"
  expire_epoch="$(vr_meta_get "$meta" EXPIRE_EPOCH 2>/dev/null || true)"
  ip_version="${ip_version:-4}"
  [[ "$port" =~ ^[0-9]+$ ]] || continue
  [[ "$ip_version" == "4" || "$ip_version" == "6" ]] || ip_version=4
  if [[ "$expire_epoch" =~ ^[0-9]+$ ]] && (( expire_epoch <= now )); then
    continue
  fi
  vr_il_apply_family_guard "$port" "$ip_version" || rc=1
done

for meta in "$VR_IPLIMIT_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  vr_il_restore_one "$meta" || rc=1
done
exit "$rc"
__VR_FILE_14__
chmod 755 '/usr/local/sbin/iplimit_restore_all.sh'

cat >'/usr/local/sbin/pq_add.sh' <<'__VR_FILE_15__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh

PORT="${1:-}"
GIB="${2:-}"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || vr_die "用法: pq_add.sh <端口> <GiB>"
[[ -n "$GIB" ]] || vr_die "用法: pq_add.sh <端口> <GiB>"
BYTES="$(vr_parse_gib_to_bytes "$GIB")" || vr_die "GiB 必须为正数"
vr_ensure_runtime_dirs
vr_acquire_lock_fd 7 "${VR_LOCK_DIR}/temp.lock" 120 "temp 锁繁忙"
export VR_TEMP_LOCK_HELD=1
TEMP_META="$(vr_temp_meta_by_port "$PORT")"
TEMP_TAG=""
if [[ -n "$TEMP_META" ]]; then
  TEMP_TAG="$(vr_meta_get "$TEMP_META" TAG)"
fi

(
  trap '' INT TERM HUP
  if [[ -n "$TEMP_META" ]]; then
    # 手工改配额仍绑定临时节点以便到期清理，但不自动开启 30 天重置。
    vr_pq_add_managed_port "$PORT" "$BYTES" temp "$TEMP_TAG" 0 0
    vr_meta_upsert "$TEMP_META" PQ_LIMIT_BYTES "$BYTES"
    vr_meta_upsert "$TEMP_META" PQ_GIB "$GIB"
  else
    vr_pq_add_managed_port "$PORT" "$BYTES" manual ""
  fi
)
if [[ -n "$TEMP_TAG" ]]; then
  echo "✅ 已为临时节点 ${TEMP_TAG}（端口 ${PORT}）手工设置总配额 $(vr_human_bytes "$BYTES")；不启用 30 天自动重置"
else
  echo "✅ 已为端口 ${PORT} 设置总配额 $(vr_human_bytes "$BYTES")"
fi
__VR_FILE_15__
chmod 755 '/usr/local/sbin/pq_add.sh'

cat >'/usr/local/sbin/pq_audit.sh' <<'__VR_FILE_16__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh

TMP_ROWS="$(mktemp)"
trap 'rm -f "$TMP_ROWS"' EXIT

for meta in "$VR_QUOTA_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  PORT="$(vr_meta_get "$meta" PORT || true)"
  OWNER_KIND="$(vr_meta_get "$meta" OWNER_KIND || true)"
  OWNER_TAG="$(vr_meta_get "$meta" OWNER_TAG || true)"
  ORIGINAL="$(vr_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  SAVED="$(vr_meta_get "$meta" SAVED_USED_BYTES || true)"
  NEXT_RESET_EPOCH="$(vr_meta_get "$meta" NEXT_RESET_EPOCH || true)"
  RESET_INTERVAL_SECONDS="$(vr_meta_get "$meta" RESET_INTERVAL_SECONDS || true)"

  [[ "$PORT" =~ ^[0-9]+$ ]] || continue
  ORIGINAL="${ORIGINAL:-0}"
  SAVED="${SAVED:-0}"
  LIVE="$(vr_pq_live_used_bytes "$PORT" || true)"
  LIVE="${LIVE:-0}"
  USED=$((SAVED + LIVE))
  LEFT=$((ORIGINAL - USED))
  if (( LEFT < 0 )); then
    LEFT=0
  fi
  OWNER="${OWNER_KIND:-manual}"
  if [[ -n "$OWNER_TAG" ]]; then
    OWNER="${OWNER_KIND:-manual}:${OWNER_TAG}"
  fi
  STATE="$(vr_pq_state "$PORT")"
  if [[ "$RESET_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] && (( RESET_INTERVAL_SECONDS > 0 )); then
    RESET='30d'
    NEXT_RESET_BJ="$(vr_beijing_time "$NEXT_RESET_EPOCH")"
  else
    RESET='-'
    NEXT_RESET_BJ='-'
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$PORT" \
    "$OWNER" \
    "$STATE" \
    "$(vr_human_bytes "$ORIGINAL")" \
    "$(vr_human_bytes "$USED")" \
    "$(vr_human_bytes "$LEFT")" \
    "$(vr_pct_text "$USED" "$ORIGINAL")" \
    "$RESET" \
    "$NEXT_RESET_BJ" >>"$TMP_ROWS"
done

sort -t $'\t' -k1,1n "$TMP_ROWS" | /usr/local/lib/vless-reality/render_table.py pq
__VR_FILE_16__
chmod 755 '/usr/local/sbin/pq_audit.sh'

cat >'/usr/local/sbin/pq_del.sh' <<'__VR_FILE_17__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh

PORT="${1:-}"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || vr_die "用法: pq_del.sh <端口>"
vr_ensure_runtime_dirs
vr_acquire_lock_fd 7 "${VR_LOCK_DIR}/temp.lock" 120 "temp 锁繁忙"
export VR_TEMP_LOCK_HELD=1
TEMP_META="$(vr_temp_meta_by_port "$PORT")"
TEMP_TAG=""
OLD_PQ_GIB=""
OLD_PQ_LIMIT_BYTES=""
if [[ -n "$TEMP_META" ]]; then
  TEMP_TAG="$(vr_meta_get "$TEMP_META" TAG)"
  OLD_PQ_GIB="$(vr_meta_get "$TEMP_META" PQ_GIB 2>/dev/null || true)"
  OLD_PQ_LIMIT_BYTES="$(vr_meta_get "$TEMP_META" PQ_LIMIT_BYTES 2>/dev/null || true)"
fi

(
  trap '' INT TERM HUP
  if [[ -n "$TEMP_META" ]]; then
    # 先撤销临时节点的期望，再删除实际限制；短窗口内只会多保留旧限制。
    # 普通删除失败时恢复期望，启动门禁/watchdog 仍会 fail-closed。
    vr_meta_upsert "$TEMP_META" PQ_LIMIT_BYTES ""
    vr_meta_upsert "$TEMP_META" PQ_GIB ""
    if ! vr_pq_delete_managed_port "$PORT"; then
      vr_meta_upsert "$TEMP_META" PQ_LIMIT_BYTES "$OLD_PQ_LIMIT_BYTES" || true
      vr_meta_upsert "$TEMP_META" PQ_GIB "$OLD_PQ_GIB" || true
      exit 1
    fi
  else
    vr_pq_delete_managed_port "$PORT"
  fi
)
if [[ -n "$TEMP_TAG" ]]; then
  echo "✅ 已删除临时节点 ${TEMP_TAG}（端口 ${PORT}）的配额管理"
else
  echo "✅ 已删除端口 ${PORT} 的配额管理"
fi
__VR_FILE_17__
chmod 755 '/usr/local/sbin/pq_del.sh'

cat >'/usr/local/sbin/ip_set.sh' <<'__VR_FILE_IP_SET__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/iplimit-lib.sh

PORT="${1:-}"
IP_LIMIT="${2:-}"
STICKY_SECONDS="${3:-}"

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || vr_die "用法: ip_set.sh <端口> <limit> [sticky_seconds]"
[[ "$IP_LIMIT" =~ ^[0-9]+$ ]] && (( IP_LIMIT > 0 )) || vr_die "limit 必须是正整数"

vr_ensure_runtime_dirs
vr_acquire_lock_fd 7 "${VR_LOCK_DIR}/temp.lock" 120 "temp 锁繁忙"
export VR_TEMP_LOCK_HELD=1
META="$(vr_iplimit_meta_file "$PORT")"
OWNER_KIND="manual"
OWNER_TAG=""
IP_VERSION=""

if [[ -f "$META" ]]; then
  IP_VERSION="$(vr_meta_get "$META" IP_VERSION 2>/dev/null || true)"
  if [[ -z "$STICKY_SECONDS" ]]; then
    STICKY_SECONDS="$(vr_meta_get "$META" IP_STICKY_SECONDS || true)"
  fi
fi

TEMP_META="$(vr_temp_meta_by_port "$PORT")"
if [[ -n "$TEMP_META" ]]; then
  OWNER_KIND="temp"
  OWNER_TAG="$(vr_meta_get "$TEMP_META" TAG)"
  IP_VERSION="$(vr_meta_get "$TEMP_META" IP_VERSION 2>/dev/null || true)"
fi

STICKY_SECONDS="${STICKY_SECONDS:-120}"
IP_VERSION="${IP_VERSION:-4}"
[[ "$STICKY_SECONDS" =~ ^[0-9]+$ ]] && (( STICKY_SECONDS > 0 )) || vr_die "sticky_seconds 必须是正整数"
[[ "$IP_VERSION" == "4" || "$IP_VERSION" == "6" ]] || vr_die "IP_VERSION 只能是 4 或 6"
[[ -n "$OWNER_KIND" ]] || OWNER_KIND="manual"

(
  trap '' INT TERM HUP
  vr_il_add_managed_port "$PORT" "$IP_LIMIT" "$STICKY_SECONDS" "$OWNER_KIND" "$OWNER_TAG" "$IP_VERSION"
  if [[ -n "$TEMP_META" ]]; then
    # nftables 生效后再提交期望状态；中途断电最多造成审计不一致，不会放开端口。
    vr_meta_upsert "$TEMP_META" IP_LIMIT "$IP_LIMIT"
    vr_meta_upsert "$TEMP_META" IP_STICKY_SECONDS "$STICKY_SECONDS"
  fi
)
echo "✅ 已将端口 ${PORT} 的 IP_LIMIT 设为 ${IP_LIMIT}（STICKY=${STICKY_SECONDS}s）"
__VR_FILE_IP_SET__
chmod 755 '/usr/local/sbin/ip_set.sh'

cat >'/usr/local/sbin/ip_del.sh' <<'__VR_FILE_IP_DEL__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/iplimit-lib.sh

PORT="${1:-}"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || vr_die "用法: ip_del.sh <端口>"

vr_ensure_runtime_dirs
vr_acquire_lock_fd 7 "${VR_LOCK_DIR}/temp.lock" 120 "temp 锁繁忙"
export VR_TEMP_LOCK_HELD=1
TEMP_META="$(vr_temp_meta_by_port "$PORT")"
IP_VERSION=""
OLD_IP_LIMIT=""
if [[ -n "$TEMP_META" ]]; then
  IP_VERSION="$(vr_meta_get "$TEMP_META" IP_VERSION 2>/dev/null || true)"
  IP_VERSION="${IP_VERSION:-4}"
  [[ "$IP_VERSION" == "4" || "$IP_VERSION" == "6" ]] || vr_die "临时节点 IP_VERSION 非法：${TEMP_META}"
  OLD_IP_LIMIT="$(vr_meta_get "$TEMP_META" IP_LIMIT 2>/dev/null || true)"
  OLD_IP_LIMIT="${OLD_IP_LIMIT:-0}"
  [[ "$OLD_IP_LIMIT" =~ ^[0-9]+$ ]] || vr_die "临时节点 IP_LIMIT 非法：${TEMP_META}"
fi

(
  trap '' INT TERM HUP
  if [[ -n "$TEMP_META" ]]; then
    # 先把期望改为 0，再删除数量限制并恢复协议族隔离；短窗口内仍由
    # 旧限制保护。任一步失败都恢复旧期望，实际规则失败路径会 block。
    vr_meta_upsert "$TEMP_META" IP_LIMIT 0
    if ! vr_il_delete_managed_port "$PORT" \
      || ! vr_il_apply_family_guard "$PORT" "$IP_VERSION"
    then
      vr_meta_upsert "$TEMP_META" IP_LIMIT "$OLD_IP_LIMIT" || true
      exit 1
    fi
  else
    vr_il_delete_managed_port "$PORT"
  fi
)
echo "✅ 已删除端口 ${PORT} 的 IP 数量限制；临时节点的协议族隔离规则已保留"
__VR_FILE_IP_DEL__
chmod 755 '/usr/local/sbin/ip_del.sh'


cat >'/usr/local/sbin/pq_reset_due.sh' <<'__VR_FILE_18__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh

vr_ensure_runtime_dirs
vr_pq_lock
rc=0
for meta in "$VR_QUOTA_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  vr_pq_reset_due_one "$meta" || rc=1
done
exit "$rc"
__VR_FILE_18__
chmod 755 '/usr/local/sbin/pq_reset_due.sh'

cat >'/usr/local/sbin/pq_restore_all.sh' <<'__VR_FILE_19__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh

vr_ensure_runtime_dirs
vr_pq_lock
rc=0
for meta in "$VR_QUOTA_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  vr_pq_restore_one "$meta" || rc=1
done
exit "$rc"
__VR_FILE_19__
chmod 755 '/usr/local/sbin/pq_restore_all.sh'

cat >'/usr/local/sbin/pq_save_state.sh' <<'__VR_FILE_20__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh

vr_ensure_runtime_dirs
vr_pq_lock
rc=0
for meta in "$VR_QUOTA_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  vr_pq_save_one "$meta" || rc=1
done
exit "$rc"
__VR_FILE_20__
chmod 755 '/usr/local/sbin/pq_save_state.sh'

cat >'/usr/local/sbin/vless_audit.sh' <<'__VR_FILE_21__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/iplimit-lib.sh

FILTER_TAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      FILTER_TAG="${2:-}"
      shift 2
      ;;
    *)
      vr_die "未知参数: $1"
      ;;
  esac
done

quota_summary() {
  local port="$1"
  local meta state original saved live used left
  meta="$(vr_quota_meta_file "$port")"
  if [[ ! -f "$meta" ]]; then
    printf 'none|-|-|-|-\n'
    return 0
  fi
  original="$(vr_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  saved="$(vr_meta_get "$meta" SAVED_USED_BYTES || true)"
  original="${original:-0}"
  saved="${saved:-0}"
  live="$(vr_pq_live_used_bytes "$port" || true)"
  live="${live:-0}"
  used=$((saved + live))
  left=$((original - used))
  if (( left < 0 )); then
    left=0
  fi
  state="$(vr_pq_state "$port")"
  printf '%s|%s|%s|%s|%s\n' \
    "$state" \
    "$(vr_human_bytes "$original")" \
    "$(vr_human_bytes "$used")" \
    "$(vr_human_bytes "$left")" \
    "$(vr_pct_text "$used" "$original")"
}

ip_summary() {
  local port="$1"
  local meta ip_limit sticky active_count
  meta="$(vr_iplimit_meta_file "$port")"
  if [[ ! -f "$meta" ]]; then
    printf '%s\n' '-|-|-'
    return 0
  fi
  ip_limit="$(vr_meta_get "$meta" IP_LIMIT || true)"
  sticky="$(vr_meta_get "$meta" IP_STICKY_SECONDS || true)"
  active_count="$(vr_il_active_count "$port" || true)"
  printf '%s|%s|%s\n' "${ip_limit:-0}" "${active_count:-0}" "${sticky:-0}"
}

TMP_ROWS="$(mktemp)"
trap 'rm -f "$TMP_ROWS"' EXIT

if [[ -z "$FILTER_TAG" ]]; then
  MAIN_PORT="$(vr_meta_get "$VR_MAIN_STATE_FILE" PORT 2>/dev/null || true)"
  if [[ ! "$MAIN_PORT" =~ ^[0-9]+$ ]]; then
    vr_load_defaults >/dev/null 2>&1 || true
    MAIN_PORT="${PORT:-443}"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "main/xray.service" \
    "$(vr_unit_state xray.service)" \
    "$MAIN_PORT" \
    "4" \
    "$(if vr_port_is_listening "$MAIN_PORT"; then echo yes; else echo no; fi)" \
    "none" "-" "-" "-" "-" "permanent" "-" "-" "-" "-" >>"$TMP_ROWS"
fi

FOUND=0
AUDIT_RC=0
for TAG in $(vr_collect_temp_tags); do
  [[ -n "$TAG" ]] || continue
  if [[ -n "$FILTER_TAG" && "$TAG" != "$FILTER_TAG" ]]; then
    continue
  fi
  FOUND=1
  META="$(vr_temp_meta_file "$TAG")"
  PORT="$(vr_temp_port_from_any "$TAG" 2>/dev/null || true)"
  UNIT_STATE="$(vr_unit_state "${TAG}.service")"
  if [[ "$PORT" =~ ^[0-9]+$ ]] && vr_port_is_listening "$PORT"; then
    LISTEN="yes"
  else
    LISTEN="no"
  fi

  if [[ -f "$META" ]]; then
    EXPIRE_EPOCH="$(vr_meta_get "$META" EXPIRE_EPOCH || true)"
    IP_VERSION="$(vr_meta_get "$META" IP_VERSION 2>/dev/null || true)"
    IP_VERSION="${IP_VERSION:-4}"
    EXPECTED_PQ="$(vr_meta_get "$META" PQ_LIMIT_BYTES 2>/dev/null || true)"
    EXPECTED_IP_LIMIT="$(vr_meta_get "$META" IP_LIMIT 2>/dev/null || true)"
    EXPECTED_IP_LIMIT="${EXPECTED_IP_LIMIT:-0}"
    LANDING="$(vr_meta_get "$META" LANDING 2>/dev/null || true)"
    TTL_TEXT="$(vr_ttl_human "$EXPIRE_EPOCH")"
    EXPIRE_BJ="$(vr_beijing_time "$EXPIRE_EPOCH")"
  else
    EXPIRE_EPOCH=""
    IP_VERSION="-"
    EXPECTED_PQ=""
    EXPECTED_IP_LIMIT="0"
    LANDING=""
    TTL_TEXT="missing"
    EXPIRE_BJ="missing"
  fi

  if [[ "$PORT" =~ ^[0-9]+$ ]]; then
    IFS='|' read -r QUOTA_STATE LIMIT USED LEFT USEP < <(quota_summary "$PORT")
    IFS='|' read -r IPLIM IPACT STICKY < <(ip_summary "$PORT")
  else
    QUOTA_STATE="none"
    LIMIT="-"
    USED="-"
    LEFT="-"
    USEP="-"
    IPLIM="-"
    IPACT="-"
    STICKY="-"
  fi

  if [[ ! -f "$META" || ! "$PORT" =~ ^[0-9]+$ || "$UNIT_STATE" != "active" || "$LISTEN" != "yes" \
        || ! -f "$(vr_temp_cfg_file "$TAG")" || ! -f "$(vr_temp_unit_file "$TAG")" || ! -s "$(vr_temp_url_file "$TAG")" ]]; then
    AUDIT_RC=1
  fi
  URL_VALUE="$(sed -n '1p' "$(vr_temp_url_file "$TAG")" 2>/dev/null || true)"
  [[ -n "$URL_VALUE" && -f /root/vless_temp_subscription.txt ]] \
    && grep -Fxq -- "$URL_VALUE" /root/vless_temp_subscription.txt \
    || AUDIT_RC=1
  if [[ ! "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]] || (( EXPIRE_EPOCH <= $(date +%s) )); then
    AUDIT_RC=1
  fi
  if [[ "$PORT" =~ ^[0-9]+$ ]]; then
    if [[ "$EXPECTED_PQ" =~ ^[0-9]+$ ]] && (( EXPECTED_PQ > 0 )); then
      [[ -f "$(vr_quota_meta_file "$PORT")" && ( "$QUOTA_STATE" == "active" || "$QUOTA_STATE" == "exhausted" ) ]] || AUDIT_RC=1
    fi
    if [[ "$EXPECTED_IP_LIMIT" =~ ^[0-9]+$ ]] && (( EXPECTED_IP_LIMIT > 0 )); then
      [[ -f "$(vr_iplimit_meta_file "$PORT")" && "$(vr_il_state "$PORT")" == "active" ]] || AUDIT_RC=1
      [[ "$(vr_meta_get "$(vr_iplimit_meta_file "$PORT")" IP_LIMIT 2>/dev/null || true)" == "$EXPECTED_IP_LIMIT" ]] || AUDIT_RC=1
    else
      [[ "$(vr_il_family_guard_state "$PORT")" == "active" ]] || AUDIT_RC=1
    fi
  fi
  if [[ "$LANDING" == "nat" ]]; then
    AUDIT_WG_IF="$(vr_meta_get "$META" WG_IF 2>/dev/null || true)"
    AUDIT_MARK="$(vr_meta_get "$META" MARK 2>/dev/null || true)"
    [[ -n "$AUDIT_WG_IF" && "$AUDIT_MARK" =~ ^[0-9]+$ ]] || AUDIT_RC=1
    if [[ -n "$AUDIT_WG_IF" && "$AUDIT_MARK" =~ ^[0-9]+$ ]]; then
      systemctl is-active --quiet "wg-quick@${AUDIT_WG_IF}.service" || AUDIT_RC=1
      ip route get 1.1.1.1 mark "$AUDIT_MARK" 2>/dev/null | grep -qE "\bdev ${AUDIT_WG_IF}\b" || AUDIT_RC=1
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$TAG" \
    "$UNIT_STATE" \
    "${PORT:--}" \
    "$IP_VERSION" \
    "$LISTEN" \
    "$QUOTA_STATE" \
    "$LIMIT" \
    "$USED" \
    "$LEFT" \
    "$USEP" \
    "$TTL_TEXT" \
    "$EXPIRE_BJ" \
    "$IPLIM" \
    "$IPACT" \
    "$STICKY" >>"$TMP_ROWS"
done

if [[ -n "$FILTER_TAG" && "$FOUND" -eq 0 ]]; then
  AUDIT_RC=1
fi

sort -t $'\t' -k3,3n "$TMP_ROWS" | /usr/local/lib/vless-reality/render_table.py vless
exit "$AUDIT_RC"
__VR_FILE_21__
chmod 755 '/usr/local/sbin/vless_audit.sh'

cat >'/usr/local/sbin/vless_cleanup_one.sh' <<'__VR_FILE_22__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/iplimit-lib.sh

TAG="${1:?need TAG}"
MODE="${2:-}"
FORCE="${FORCE:-0}"
vr_is_valid_temp_tag "$TAG" || vr_die "非法临时节点 TAG：${TAG}"
META="$(vr_temp_meta_file "$TAG")"
CFG="$(vr_temp_cfg_file "$TAG")"
UNIT_FILE="$(vr_temp_unit_file "$TAG")"
URL_FILE="$(vr_temp_url_file "$TAG")"
UNIT_NAME="${TAG}.service"
FROM_STOP_POST=0
[[ "$MODE" == "--from-stop-post" ]] && FROM_STOP_POST=1

if [[ "${VR_TEMP_LOCK_HELD:-0}" != "1" ]]; then
  if (( FROM_STOP_POST == 1 )); then
    if ! vr_try_lock_fd 7 "${VR_LOCK_DIR}/temp.lock"; then
      exit 0
    fi
  else
    vr_acquire_lock_fd 7 "${VR_LOCK_DIR}/temp.lock" 120 "temp 锁繁忙"
  fi
  export VR_TEMP_LOCK_HELD=1
fi

# Save/read/delete quota state under the same locks as timer and watchdog
# writers.  Acquire once in the global temp -> quota -> iplimit order so the
# pre-delete save cannot race before the delete helper's later lock.
vr_pq_lock
vr_il_lock

PORT="$(vr_temp_port_from_any "$TAG" 2>/dev/null || true)"
cleanup_rc=0

if (( FROM_STOP_POST == 1 )) && [[ "$FORCE" != "1" ]] && [[ "$PORT" =~ ^[0-9]+$ ]]; then
  vr_pq_save_one "$(vr_quota_meta_file "$PORT")" >/dev/null 2>&1 || true
fi

if [[ "$FORCE" != "1" && -f "$META" ]]; then
  EXPIRE_EPOCH="$(vr_meta_get "$META" EXPIRE_EPOCH || true)"
  if [[ "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]]; then
    NOW="$(date +%s)"
    if (( EXPIRE_EPOCH > NOW )); then
      exit 0
    fi
  fi
fi

if systemctl list-unit-files "$UNIT_NAME" >/dev/null 2>&1 || [[ -f "$UNIT_FILE" ]]; then
  # ExecStopPost runs while this very unit is still "deactivating".  Calling
  # systemctl stop on ourselves from that hook would wait for the hook and can
  # deadlock until the outer timeout.  An external cleanup may stop/wait/kill;
  # the stop-post path only verifies that the process and listening socket are
  # already gone before removing persistent state and nftables protection.
  UNIT_STATE="$(systemctl is-active "$UNIT_NAME" 2>/dev/null || true)"
  if (( FROM_STOP_POST == 0 )) && [[ "$UNIT_STATE" =~ ^(active|activating|deactivating)$ ]]; then
    if ! timeout 15 systemctl stop "$UNIT_NAME" >/dev/null 2>&1; then
      systemctl kill --kill-who=all --signal=KILL "$UNIT_NAME" >/dev/null 2>&1 || true
    fi
    for _ in 1 2 3 4 5; do
      UNIT_STATE="$(systemctl is-active "$UNIT_NAME" 2>/dev/null || true)"
      [[ "$UNIT_STATE" =~ ^(active|activating|deactivating)$ ]] || break
      sleep 1
    done
  fi
  UNIT_STATE="$(systemctl is-active "$UNIT_NAME" 2>/dev/null || true)"
  if { (( FROM_STOP_POST == 0 )) && [[ "$UNIT_STATE" =~ ^(active|activating|deactivating)$ ]]; } \
    || { [[ "$PORT" =~ ^[0-9]+$ ]] && vr_port_is_listening "$PORT"; }
  then
    echo "⚠️  ${TAG} 进程或监听端口仍未停止；保留配置、meta 与防护规则供下次重试" >&2
    exit 1
  fi
  systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
  systemctl reset-failed "$UNIT_NAME" >/dev/null 2>&1 || true
fi
if [[ "$PORT" =~ ^[0-9]+$ ]] && vr_port_is_listening "$PORT"; then
  echo "⚠️  ${TAG} 的端口 ${PORT} 仍在监听；拒绝撤销 nftables 防护" >&2
  exit 1
fi

if [[ "$PORT" =~ ^[0-9]+$ ]]; then
  # Keep inherited lock ownership when cleanup is called by vless_mktemp.sh.
  # Resetting these flags would make the child wait on locks held by its parent.
  vr_pq_delete_managed_port "$PORT" || cleanup_rc=1
  vr_il_delete_managed_port "$PORT" || cleanup_rc=1
fi

rm -f "$CFG" "$UNIT_FILE" "$URL_FILE"
if (( cleanup_rc == 0 )); then
  rm -f "$META"
else
  echo "⚠️  ${TAG} 的 nftables 清理未完成，保留 meta 供 GC/watchdog 重试" >&2
fi
/usr/local/sbin/vless_temp_sub.sh >/dev/null 2>&1 || cleanup_rc=1
systemctl daemon-reload >/dev/null 2>&1 || true
exit "$cleanup_rc"
__VR_FILE_22__
chmod 755 '/usr/local/sbin/vless_cleanup_one.sh'

cat >'/usr/local/sbin/vless_clear_all.sh' <<'__VR_FILE_23__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh

vr_ensure_runtime_dirs
vr_acquire_lock_fd 7 "${VR_LOCK_DIR}/temp.lock" 120 "temp 锁繁忙"
export VR_TEMP_LOCK_HELD=1

mapfile -t TAGS < <(vr_collect_temp_tags)

rc=0
for tag in "${TAGS[@]:-}"; do
  [[ -n "$tag" ]] || continue
  FORCE=1 VR_TEMP_LOCK_HELD=1 /usr/local/sbin/vless_cleanup_one.sh "$tag" || rc=1
done

/usr/local/sbin/vless_temp_sub.sh >/dev/null 2>&1 || rc=1
systemctl daemon-reload >/dev/null 2>&1 || rc=1
exit "$rc"
__VR_FILE_23__
chmod 755 '/usr/local/sbin/vless_clear_all.sh'

cat >'/usr/local/sbin/vless_gc.sh' <<'__VR_FILE_24__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh

vr_ensure_runtime_dirs
if [[ "${VR_TEMP_LOCK_HELD:-0}" != "1" ]]; then
  if ! vr_try_lock_fd 7 "${VR_LOCK_DIR}/temp.lock"; then
    exit 0
  fi
  export VR_TEMP_LOCK_HELD=1
fi

NOW="$(date +%s)"
rc=0
for meta in "$VR_TEMP_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  TAG="$(vr_meta_get "$meta" TAG || true)"
  EXPIRE_EPOCH="$(vr_meta_get "$meta" EXPIRE_EPOCH || true)"
  vr_is_valid_temp_tag "$TAG" || { rc=1; continue; }
  [[ "$TAG" == "$(basename "$meta" .env)" ]] || { rc=1; continue; }
  [[ "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]] || continue
  if (( EXPIRE_EPOCH <= NOW )); then
    FORCE=1 VR_TEMP_LOCK_HELD=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" || rc=1
  fi
done

for TAG in $(vr_collect_orphan_temp_tags_from_aux); do
  [[ -n "$TAG" ]] || continue
  FORCE=1 VR_TEMP_LOCK_HELD=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" || rc=1
done
exit "$rc"
__VR_FILE_24__
chmod 755 '/usr/local/sbin/vless_gc.sh'

cat >'/usr/local/sbin/vless_mktemp.sh' <<'__VR_FILE_25__'
#!/usr/bin/env bash
set -Eeuo pipefail
CURRENT_ATTEMPT_ACTIVE=0

on_error() {
  local rc=$?
  # ERR 路径自己完成一次回滚；关闭 EXIT trap，确保错误路径只清理一次。
  trap - ERR EXIT
  trap '' INT TERM HUP
  echo "❌ ${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}:${BASH_LINENO[0]:-?}: ${BASH_COMMAND}" >&2
  if (( CURRENT_ATTEMPT_ACTIVE == 1 )); then
    rollback_current || true
  fi
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
umask 077

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/iplimit-lib.sh

: "${D:?请用 D=秒 vless_mktemp.sh 调用，例如：id=tmp001 IP_VERSION=6 IP_LIMIT=1 PQ_GIB=1 D=1200 vless_mktemp.sh}"
[[ "$D" =~ ^[0-9]+$ && ${#D} -le 10 ]] || vr_die "D 必须是正整数秒"
D=$((10#$D))
(( D > 0 && D <= 2147483647 )) || vr_die "D 必须在 1-2147483647 秒"

RAW_ID="${id:-tmp-$(date +%Y%m%d%H%M%S)-$(openssl rand -hex 2)}"
SAFE_ID="$(vr_safe_tag "$RAW_ID")"
TAG="$(vr_temp_tag_from_id "$SAFE_ID")"
PORT_START="${PORT_START:-40000}"
PORT_END="${PORT_END:-50050}"
MAX_START_RETRIES="${MAX_START_RETRIES:-12}"
IP_LIMIT="${IP_LIMIT:-0}"
IP_STICKY_SECONDS="${IP_STICKY_SECONDS:-120}"
PQ_GIB="${PQ_GIB:-}"
IP_VERSION="${IP_VERSION:-4}"

[[ "$IP_VERSION" == "4" || "$IP_VERSION" == "6" ]] || vr_die "IP_VERSION 只能是 4 或 6"
[[ "$PORT_START" =~ ^[0-9]+$ && "$PORT_END" =~ ^[0-9]+$ ]] \
  && (( PORT_START >= 1 && PORT_END <= 65535 && PORT_START <= PORT_END )) || vr_die "PORT_START/PORT_END 无效"
[[ "$MAX_START_RETRIES" =~ ^[0-9]+$ && ${#MAX_START_RETRIES} -le 3 ]] || vr_die "MAX_START_RETRIES 必须是 1-100"
MAX_START_RETRIES=$((10#$MAX_START_RETRIES))
(( MAX_START_RETRIES >= 1 && MAX_START_RETRIES <= 100 )) || vr_die "MAX_START_RETRIES 必须是 1-100"
[[ "$IP_LIMIT" =~ ^[0-9]+$ && ${#IP_LIMIT} -le 5 ]] || vr_die "IP_LIMIT 必须是 0-65535"
IP_LIMIT=$((10#$IP_LIMIT))
(( IP_LIMIT <= 65535 )) || vr_die "IP_LIMIT 必须是 0-65535"
[[ "$IP_STICKY_SECONDS" =~ ^[0-9]+$ && ${#IP_STICKY_SECONDS} -le 10 ]] || vr_die "IP_STICKY_SECONDS 必须是正整数"
IP_STICKY_SECONDS=$((10#$IP_STICKY_SECONDS))
(( IP_STICKY_SECONDS > 0 && IP_STICKY_SECONDS <= 2147483647 )) || vr_die "IP_STICKY_SECONDS 必须在 1-2147483647"

vr_require_root_supported_os
vr_ensure_runtime_dirs
if [[ "${VR_TEMP_LOCK_HELD:-0}" != "1" ]]; then
  vr_acquire_lock_fd 7 "${VR_LOCK_DIR}/temp.lock" 120 "temp 锁繁忙"
  export VR_TEMP_LOCK_HELD=1
fi

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
PUBLISHED_DOMAIN="${PUBLISHED_DOMAIN:-$PUBLIC_DOMAIN}"
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
URL_HOST="$(vr_vless_url_host "$PUBLISHED_DOMAIN")"

PBK_IN="${PBK:-}"
[[ -n "$PBK_IN" ]] || PBK_IN="$(vr_meta_get "$VR_MAIN_STATE_FILE" PBK 2>/dev/null || true)"
[[ -n "$PBK_IN" ]] || PBK_IN="$(vr_main_url_published_pbk 2>/dev/null || true)"
[[ -n "$PBK_IN" ]] || vr_die "无法获取主节点 PBK，请先运行 /root/onekey_reality_ipv4.sh 或手动传入 PBK=<...>"
PBK_RAW="$(vr_urldecode "$PBK_IN")"
[[ "$PBK_RAW" =~ ^[A-Za-z0-9_+/=-]{40,128}$ ]] \
  || vr_die "PBK 不是有效的 Reality 客户端公钥"

PQ_LIMIT_BYTES=""
if [[ -n "$PQ_GIB" ]]; then
  PQ_LIMIT_BYTES="$(vr_parse_gib_to_bytes "$PQ_GIB")" || vr_die "PQ_GIB 必须是正数"
  [[ "$PQ_LIMIT_BYTES" =~ ^[0-9]+$ ]] && (( PQ_LIMIT_BYTES > 0 )) || vr_die "PQ_GIB 转换失败"
fi

collect_used_ports() {
  ss -ltnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/'
  for meta in "$VR_TEMP_STATE_DIR"/*.env "$VR_QUOTA_STATE_DIR"/*.env "$VR_IPLIMIT_STATE_DIR"/*.env; do
    [[ -f "$meta" ]] || continue
    vr_meta_get "$meta" PORT || true
  done
  [[ "$MAIN_PORT" =~ ^[0-9]+$ ]] && printf '%s\n' "$MAIN_PORT"
}

rollback_current() {
  CURRENT_ATTEMPT_ACTIVE=0
  if ! FORCE=1 VR_TEMP_LOCK_HELD=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" >/dev/null 2>&1; then
    echo "❌ ${TAG} 回滚未完成；已停止重试，保留 meta 供 watchdog/GC 继续清理" >&2
    return 1
  fi
}

validate_full_state() {
  local meta="$1" port="$2"
  [[ -f "$meta" ]] || return 1
  [[ -f "$(vr_temp_cfg_file "$TAG")" ]] || return 1
  [[ -f "$(vr_temp_unit_file "$TAG")" ]] || return 1
  [[ -f "$(vr_temp_url_file "$TAG")" ]] || return 1
  [[ -f /root/vless_temp_subscription.txt ]] || return 1
  grep -Fxq -- "$VLESS_URL" /root/vless_temp_subscription.txt || return 1
  [[ -n "$(vr_meta_get "$meta" EXPIRE_EPOCH || true)" ]] || return 1
  [[ "$(vr_meta_get "$meta" PORT || true)" == "$port" ]] || return 1
  [[ "$(vr_il_family_guard_state "$port")" == "active" ]] || return 1
  systemctl is-active --quiet "${TAG}.service" || return 1
  vr_port_is_listening "$port" || return 1
  if [[ -n "$PQ_LIMIT_BYTES" ]]; then
    local qmeta
    qmeta="$(vr_quota_meta_file "$port")"
    [[ -f "$qmeta" ]] || return 1
    [[ "$(vr_meta_get "$qmeta" ORIGINAL_LIMIT_BYTES || true)" == "$PQ_LIMIT_BYTES" ]] || return 1
    [[ -n "$(vr_meta_get "$qmeta" SAVED_USED_BYTES || true)" ]] || return 1
    [[ -n "$(vr_meta_get "$qmeta" LIMIT_BYTES || true)" ]] || return 1
    [[ "$(vr_pq_state "$port")" == "active" ]] || return 1
  fi
  if (( IP_LIMIT > 0 )); then
    local imeta
    imeta="$(vr_iplimit_meta_file "$port")"
    [[ -f "$imeta" ]] || return 1
    [[ "$(vr_meta_get "$imeta" IP_LIMIT || true)" == "$IP_LIMIT" ]] || return 1
    [[ "$(vr_meta_get "$imeta" IP_VERSION 2>/dev/null || true)" == "$IP_VERSION" ]] || return 1
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
    if [[ -z "${USED[$CANDIDATE]+x}" ]]; then
      PORT="$CANDIDATE"
      break
    fi
  done
  [[ -n "$PORT" ]] || vr_die "在 ${PORT_START}-${PORT_END} 范围内没有空闲端口"
  CURRENT_ATTEMPT_ACTIVE=1

  UUID="$(/usr/local/bin/xray uuid)"
  SHORT_ID="$(openssl rand -hex 8)"
  CREATE_EPOCH="$(date +%s)"
  EXPIRE_EPOCH=$((CREATE_EPOCH + D))
  CFG="$(vr_temp_cfg_file "$TAG")"
  META="$(vr_temp_meta_file "$TAG")"
  UNIT_FILE="$(vr_temp_unit_file "$TAG")"
  URL_FILE="$(vr_temp_url_file "$TAG")"

  vr_write_reality_config "$CFG" "$LISTEN_ADDR" "$PORT" "$UUID" "$REALITY_DEST" "$REALITY_SNI" "$REALITY_PRIVATE_KEY" "$SHORT_ID"
  if ! vr_test_xray_config "$CFG" /usr/local/bin/xray; then
    rm -f "$CFG"
    vr_die "生成的临时节点 Xray 配置未通过校验"
  fi

  vr_write_meta "$META" \
    "TAG=${TAG}" \
    "ID=${SAFE_ID}" \
    "PORT=${PORT}" \
    "PUBLIC_DOMAIN=${PUBLISHED_DOMAIN}" \
    "IP_VERSION=${IP_VERSION}" \
    "LISTEN_ADDR=${LISTEN_ADDR}" \
    "UUID=${UUID}" \
    "CREATE_EPOCH=${CREATE_EPOCH}" \
    "EXPIRE_EPOCH=${EXPIRE_EPOCH}" \
    "DURATION_SECONDS=${D}" \
    "REALITY_DEST=${REALITY_DEST}" \
    "REALITY_SNI=${REALITY_SNI}" \
    "SHORT_ID=${SHORT_ID}" \
    "PBK=${PBK_RAW}" \
    "PQ_GIB=${PQ_GIB}" \
    "PQ_LIMIT_BYTES=${PQ_LIMIT_BYTES}" \
    "IP_LIMIT=${IP_LIMIT}" \
    "IP_STICKY_SECONDS=${IP_STICKY_SECONDS}"

  cat >"$UNIT_FILE" <<UNIT
[Unit]
Description=Temporary VLESS ${TAG} IPv${IP_VERSION}
After=network-online.target vless-managed-restore.service
Wants=network-online.target
ConditionPathExists=${CFG}
ConditionPathExists=${META}

[Service]
Type=simple
User=root
Group=root
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
    rollback_current
    FAILED_PORTS["$PORT"]=1
    continue
  fi

  if [[ -n "$PQ_LIMIT_BYTES" ]]; then
    if ! vr_pq_add_managed_port "$PORT" "$PQ_LIMIT_BYTES" temp "$TAG" "$D" "$EXPIRE_EPOCH"; then
      rollback_current
      FAILED_PORTS["$PORT"]=1
      continue
    fi
  fi

  if (( IP_LIMIT > 0 )); then
    if ! vr_il_add_managed_port "$PORT" "$IP_LIMIT" "$IP_STICKY_SECONDS" temp "$TAG" "$IP_VERSION"; then
      rollback_current
      FAILED_PORTS["$PORT"]=1
      continue
    fi
  else
    if ! vr_il_apply_family_guard "$PORT" "$IP_VERSION"; then
      rollback_current
      FAILED_PORTS["$PORT"]=1
      continue
    fi
  fi

  systemctl daemon-reload
  systemctl enable "${TAG}.service" >/dev/null

  if ! systemctl start "${TAG}.service"; then
    rollback_current
    FAILED_PORTS["$PORT"]=1
    continue
  fi
  if ! vr_wait_unit_and_port "${TAG}.service" "$PORT" 3 12; then
    rollback_current
    FAILED_PORTS["$PORT"]=1
    continue
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
    rollback_current
    FAILED_PORTS["$PORT"]=1
    continue
  fi

  if ! validate_full_state "$META" "$PORT"; then
    echo "❌ ${TAG} 最终状态校验失败" >&2
    echo "   PORT=${PORT}" >&2
    echo "   IP_VERSION=${IP_VERSION}" >&2
    echo "   IP_LIMIT=${IP_LIMIT}" >&2
    echo "   IP_LIMIT_STATE=$(vr_il_state "$PORT")" >&2
    echo "   FAMILY_GUARD_STATE=$(vr_il_family_guard_state "$PORT")" >&2
    if [[ -n "$PQ_LIMIT_BYTES" ]]; then
      echo "   QUOTA_STATE=$(vr_pq_state "$PORT")" >&2
    fi
    echo "   UNIT_STATE=$(systemctl is-active "${TAG}.service" 2>/dev/null || true)" >&2

    echo "----- nftables IP-limit chain -----" >&2
    nft -a list chain inet "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" >&2 || true

    if [[ -n "$PQ_LIMIT_BYTES" ]]; then
      echo "----- nftables quota input chain -----" >&2
      nft -a list chain inet "$VR_PQ_TABLE" "$VR_PQ_INPUT_CHAIN" >&2 || true
      echo "----- nftables quota output chain -----" >&2
      nft -a list chain inet "$VR_PQ_TABLE" "$VR_PQ_OUTPUT_CHAIN" >&2 || true
    fi

    echo "----- VLESS audit -----" >&2
    /usr/local/sbin/vless_audit.sh --tag "$TAG" >&2 || true

    echo "----- systemd journal -----" >&2
    journalctl -u "${TAG}.service" -n 80 --no-pager >&2 || true

    rollback_current
    FAILED_PORTS["$PORT"]=1
    continue
  fi

  echo "✅ 临时节点创建成功"
  echo "TAG: ${TAG}"
  echo "PORT: ${PORT}"
  echo "IP_VERSION: ${IP_VERSION}"
  echo "TTL: $(vr_ttl_human "$EXPIRE_EPOCH")"
  echo "到期(北京时间): $(vr_beijing_time "$EXPIRE_EPOCH")"
  [[ -n "$PQ_LIMIT_BYTES" ]] && echo "PQ: $(vr_human_bytes "$PQ_LIMIT_BYTES")"
  if (( IP_LIMIT > 0 )); then
    echo "IP_LIMIT: ${IP_LIMIT}"
    echo "IP_STICKY_SECONDS: ${IP_STICKY_SECONDS}"
  fi
  echo "URL: ${VLESS_URL}"
  CURRENT_ATTEMPT_ACTIVE=0
  exit 0
done

vr_die "临时节点创建失败，已回滚（尝试次数: ${MAX_START_RETRIES}）"
__VR_FILE_25__
chmod 755 '/usr/local/sbin/vless_mktemp.sh'

cat >'/usr/local/sbin/vless_restore_all.sh' <<'__VR_FILE_26__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

rc=0
/usr/local/sbin/vless_gc.sh || rc=1
/usr/local/sbin/pq_restore_all.sh || rc=1
/usr/local/sbin/iplimit_restore_all.sh || rc=1
exit "$rc"
__VR_FILE_26__
chmod 755 '/usr/local/sbin/vless_restore_all.sh'

cat >'/usr/local/sbin/vless_managed_watchdog.sh' <<'__VR_FILE_WATCHDOG__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# 只在检测到规则/对象缺失时恢复，正常情况下不重建，避免清空活跃 IP timeout set。
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/iplimit-lib.sh

vr_require_root_supported_os
vr_ensure_runtime_dirs

if ! vr_try_lock_fd 7 "${VR_LOCK_DIR}/temp.lock"; then
  exit 0
fi
export VR_TEMP_LOCK_HELD=1
# Keep the global order temp -> quota -> iplimit.  The watchdog reads and may
# rewrite quota metadata before vr_pq_rebuild_port(), so relying on the rebuild
# function's late lock would still leave a race with pq-save/reset.
vr_pq_lock
vr_il_lock
rc=0
now="$(date +%s)"

stop_temp_listener_failclosed() {
  local tag="$1"
  vr_is_valid_temp_tag "$tag" || return 1
  if ! timeout 20 systemctl stop "${tag}.service" >/dev/null 2>&1; then
    systemctl kill --kill-who=all --signal=KILL "${tag}.service" >/dev/null 2>&1 || true
  fi
}

for meta in "$VR_QUOTA_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  port="$(vr_meta_get "$meta" PORT 2>/dev/null || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || continue
  if [[ "$(vr_pq_state "$port")" == "stale" ]]; then
    echo "⚠️  修复 quota:${port}" >&2
    vr_pq_save_one "$meta" || rc=1
  fi
done

for meta in "$VR_IPLIMIT_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  port="$(vr_meta_get "$meta" PORT 2>/dev/null || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || continue
  if [[ "$(vr_il_state "$port")" == "stale" ]]; then
    echo "⚠️  修复 iplimit:${port}" >&2
    vr_il_restore_one "$meta" || rc=1
  fi
done

# IP_LIMIT=0 的临时节点没有 iplimit meta，但仍必须有地址族隔离规则。
for meta in "$VR_TEMP_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  tag="$(vr_meta_get "$meta" TAG 2>/dev/null || true)"
  file_tag="$(basename "$meta" .env)"
  port="$(vr_meta_get "$meta" PORT 2>/dev/null || true)"
  expire="$(vr_meta_get "$meta" EXPIRE_EPOCH 2>/dev/null || true)"
  ip_version="$(vr_meta_get "$meta" IP_VERSION 2>/dev/null || true)"
  ip_limit="$(vr_meta_get "$meta" IP_LIMIT 2>/dev/null || true)"
  pq_limit="$(vr_meta_get "$meta" PQ_LIMIT_BYTES 2>/dev/null || true)"
  ip_version="${ip_version:-4}"
  ip_limit="${ip_limit:-0}"
  if ! vr_is_valid_temp_tag "$tag" || [[ "$tag" != "$file_tag" ]]; then
    echo "❌ 临时节点元数据 TAG 非法或与文件名不一致：${meta}" >&2
    vr_is_valid_temp_tag "$file_tag" && stop_temp_listener_failclosed "$file_tag" || true
    rc=1
    continue
  fi
  if [[ ! "$port" =~ ^[0-9]+$ \
        || ! "$expire" =~ ^[0-9]+$ \
        || ( "$ip_version" != "4" && "$ip_version" != "6" ) \
        || ! "$ip_limit" =~ ^[0-9]+$ \
        || ${#ip_limit} -gt 5 ]]; then
    echo "❌ 临时节点 ${tag} 的防护元数据非法，停止监听并保留状态供人工检查" >&2
    stop_temp_listener_failclosed "$tag" || true
    rc=1
    continue
  fi

  if (( expire <= now )); then
    FORCE=1 VR_TEMP_LOCK_HELD=1 /usr/local/sbin/vless_cleanup_one.sh "$tag" || rc=1
    continue
  fi

  if (( ip_limit == 0 )) && [[ "$(vr_il_family_guard_state "$port")" == "stale" ]]; then
    echo "⚠️  修复 family:${port}" >&2
    vr_il_apply_family_guard "$port" "$ip_version" || rc=1
  fi

  # If an nftables repair failed, do not leave an already-running listener in
  # a fail-open state.  Stop it while retaining its metadata; a later watchdog
  # pass will restart it only after every requested guard is healthy again.
  protection_ready=1
  quota_ready=1
  if [[ -n "$pq_limit" ]]; then
    if [[ ! "$pq_limit" =~ ^[0-9]+$ || ${#pq_limit} -gt 19 ]] || (( pq_limit <= 0 )); then
      protection_ready=0
      quota_ready=0
    else
      case "$(vr_pq_state "$port")" in
        active|exhausted) ;;
        *) protection_ready=0; quota_ready=0 ;;
      esac
    fi
  fi
  if (( ip_limit > 0 )); then
    [[ "$(vr_il_state "$port")" == "active" ]] || protection_ready=0
  else
    [[ "$(vr_il_family_guard_state "$port")" == "active" ]] || protection_ready=0
  fi
  if (( protection_ready == 0 )); then
    echo "❌ 临时节点 ${tag} 的 nftables 防护未就绪，停止监听并等待下轮修复" >&2
    if [[ -n "$pq_limit" ]] && (( quota_ready == 1 )); then
      vr_pq_save_one "$(vr_quota_meta_file "$port")" >/dev/null 2>&1 || true
    fi
    stop_temp_listener_failclosed "$tag" || true
    rc=1
    continue
  fi

  node_healthy=0
  if systemctl is-active --quiet "${tag}.service" && vr_port_is_listening "$port"; then
    node_healthy=1
  fi
  landing="$(vr_meta_get "$meta" LANDING 2>/dev/null || true)"
  if (( node_healthy == 1 )) && [[ "$landing" == "nat" ]]; then
    wg_if="$(vr_meta_get "$meta" WG_IF 2>/dev/null || true)"
    mark="$(vr_meta_get "$meta" MARK 2>/dev/null || true)"
    handshake_max="$(vr_meta_get "$meta" HANDSHAKE_MAX 2>/dev/null || true)"
    handshake_max="${handshake_max:-180}"
    hs=""
    [[ -n "$wg_if" && "$mark" =~ ^[0-9]+$ && "$handshake_max" =~ ^[0-9]+$ ]] || node_healthy=0
    if (( node_healthy == 1 )); then
      systemctl is-active --quiet "wg-quick@${wg_if}.service" || node_healthy=0
      ip route get 1.1.1.1 mark "$mark" 2>/dev/null | grep -qE "\bdev ${wg_if}\b" || node_healthy=0
      hs="$(wg show "$wg_if" latest-handshakes 2>/dev/null | awk 'NF>=2{print $2}' | sort -nr | head -n1 || true)"
      [[ "$hs" =~ ^[0-9]+$ ]] && (( hs > 0 && now - hs <= handshake_max )) || node_healthy=0
    fi
  fi

  if (( node_healthy == 1 )); then
    if [[ "$(vr_meta_get "$meta" WATCHDOG_FAILURES 2>/dev/null || true)" != "0" ]]; then
      vr_meta_upsert "$meta" WATCHDOG_FAILURES 0
    fi
    continue
  fi

  echo "⚠️  临时节点 ${tag} 未运行，尝试恢复" >&2
  systemctl reset-failed "${tag}.service" >/dev/null 2>&1 || true
  if systemctl restart "${tag}.service" >/dev/null 2>&1 \
    && vr_wait_unit_and_port "${tag}.service" "$port" 2 8
  then
    vr_meta_upsert "$meta" WATCHDOG_FAILURES 0
    vr_meta_upsert "$meta" WATCHDOG_LAST_FAILURE_EPOCH 0
    continue
  fi

  failures="$(vr_meta_get "$meta" WATCHDOG_FAILURES 2>/dev/null || true)"
  [[ "$failures" =~ ^[0-9]+$ ]] || failures=0
  failures=$((failures + 1))
  vr_meta_upsert "$meta" WATCHDOG_FAILURES "$failures"
  vr_meta_upsert "$meta" WATCHDOG_LAST_FAILURE_EPOCH "$now"
  if (( failures >= 3 )); then
    echo "❌ 临时节点 ${tag} 连续恢复失败 ${failures} 次，执行清理" >&2
    FORCE=1 VR_TEMP_LOCK_HELD=1 /usr/local/sbin/vless_cleanup_one.sh "$tag" || rc=1
  else
    rc=1
  fi
done

# 每轮都重建聚合订阅；即使节点本身无变化，外部误删/截断订阅文件也能自愈。
VR_TEMP_LOCK_HELD=1 /usr/local/sbin/vless_temp_sub.sh >/dev/null 2>&1 || rc=1
exit "$rc"
__VR_FILE_WATCHDOG__
chmod 755 '/usr/local/sbin/vless_managed_watchdog.sh'

cat >'/usr/local/sbin/vless_run_temp.sh' <<'__VR_FILE_27__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/iplimit-lib.sh

TAG="${1:?need TAG}"
CFG="${2:?need CONFIG}"
vr_is_valid_temp_tag "$TAG" || vr_die "非法临时节点 TAG：${TAG}"
META="$(vr_temp_meta_file "$TAG")"
XRAY_BIN="$(command -v xray || echo /usr/local/bin/xray)"

[[ -x "$XRAY_BIN" ]] || vr_die "未找到 xray 可执行文件"
[[ -f "$CFG" ]] || vr_die "配置不存在: ${CFG}"
[[ -f "$META" ]] || vr_die "meta 不存在: ${META}"

# Never start a temporary listener without its requested quota/IP guard.  The
# boot restore service normally runs first, but an ordering dependency alone
# does not prevent startup after that oneshot has failed.  This read-only gate
# leaves the unit failed/restarting until the watchdog repairs the rules.
PORT="$(vr_meta_get "$META" PORT 2>/dev/null || true)"
PQ_LIMIT_BYTES="$(vr_meta_get "$META" PQ_LIMIT_BYTES 2>/dev/null || true)"
IP_LIMIT="$(vr_meta_get "$META" IP_LIMIT 2>/dev/null || true)"
IP_VERSION="$(vr_meta_get "$META" IP_VERSION 2>/dev/null || true)"
IP_LIMIT="${IP_LIMIT:-0}"
IP_VERSION="${IP_VERSION:-4}"
[[ "$PORT" =~ ^[0-9]+$ && "$IP_LIMIT" =~ ^[0-9]+$ ]] || vr_die "临时节点防护元数据非法: ${META}"
[[ "$IP_VERSION" == "4" || "$IP_VERSION" == "6" ]] || vr_die "临时节点 IP_VERSION 非法: ${META}"
if [[ -n "$PQ_LIMIT_BYTES" ]]; then
  [[ "$PQ_LIMIT_BYTES" =~ ^[0-9]+$ ]] || vr_die "临时节点配额元数据非法: ${META}"
  case "$(vr_pq_state "$PORT")" in
    active|exhausted) ;;
    *) vr_die "端口 ${PORT} 的配额防护未就绪，等待 watchdog 修复" ;;
  esac
fi
if (( IP_LIMIT > 0 )); then
  [[ "$(vr_il_state "$PORT")" == "active" ]] \
    || vr_die "端口 ${PORT} 的 IP_LIMIT 防护未就绪，等待 watchdog 修复"
else
  [[ "$(vr_il_family_guard_state "$PORT")" == "active" ]] \
    || vr_die "端口 ${PORT} 的协议族隔离未就绪，等待 watchdog 修复"
fi

EXPIRE_EPOCH="$(vr_meta_get "$META" EXPIRE_EPOCH || true)"
[[ "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]] || vr_die "bad EXPIRE_EPOCH in ${META}"

NOW="$(date +%s)"
REMAIN=$((EXPIRE_EPOCH - NOW))
if (( REMAIN <= 0 )); then
  # 由本 unit 的 ExecStopPost 执行清理，避免进程在 ExecStart 内停止自身 unit。
  exit 0
fi

exec timeout --foreground "$REMAIN" "$XRAY_BIN" run -config "$CFG"
__VR_FILE_27__
chmod 755 '/usr/local/sbin/vless_run_temp.sh'


cat >'/usr/local/sbin/vless_temp_sub.sh' <<'__VR_FILE_SUB__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
umask 077

OUT_RAW="/root/vless_temp_subscription.txt"
OUT_B64="/root/vless_temp_subscription_base64.txt"
TMP="$(mktemp)"
RAW_TMP="$(mktemp /root/.vless_temp_subscription.txt.XXXXXX)"
B64_TMP="$(mktemp /root/.vless_temp_subscription_base64.txt.XXXXXX)"
SUB_TX_DIR="$(mktemp -d /root/.vless-subscription-transaction.XXXXXX)"
SUB_TX_ACTIVE=0

sub_on_exit() {
  local rc=$? path key
  trap - EXIT ERR
  trap '' INT TERM HUP
  rm -f -- "$TMP" "$RAW_TMP" "$B64_TMP"
  if (( SUB_TX_ACTIVE == 1 )); then
    for path in "$OUT_RAW" "$OUT_B64"; do
      key="$(basename "$path")"
      rm -f -- "$path"
      if [[ -f "${SUB_TX_DIR}/${key}.present" ]]; then
        cp -a -- "${SUB_TX_DIR}/${key}" "$path"
      fi
    done
  fi
  rm -rf -- "$SUB_TX_DIR"
  exit "$rc"
}
trap 'sub_on_exit' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

vr_ensure_runtime_dirs
if [[ "${VR_TEMP_LOCK_HELD:-0}" != "1" ]]; then
  vr_acquire_lock_fd 7 "${VR_LOCK_DIR}/temp.lock" 120 "temp 锁繁忙"
  export VR_TEMP_LOCK_HELD=1
fi
NOW="$(date +%s)"
for meta in "$VR_TEMP_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  tag="$(vr_meta_get "$meta" TAG || true)"
  exp="$(vr_meta_get "$meta" EXPIRE_EPOCH || true)"
  vr_is_valid_temp_tag "$tag" || continue
  [[ "$tag" == "$(basename "$meta" .env)" ]] || continue
  [[ "$exp" =~ ^[0-9]+$ ]] || continue
  (( exp > NOW )) || continue
  port="$(vr_meta_get "$meta" PORT 2>/dev/null || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || continue
  systemctl is-active --quiet "${tag}.service" || continue
  vr_port_is_listening "$port" || continue
  url_file="$(vr_temp_url_file "$tag")"
  [[ -s "$url_file" ]] || continue
  sed -n '1p' "$url_file" >>"$TMP"
done

sort -u "$TMP" >"$RAW_TMP"
vr_base64_one_line <"$RAW_TMP" >"$B64_TMP"
chmod 600 "$RAW_TMP" "$B64_TMP"
for path in "$OUT_RAW" "$OUT_B64"; do
  key="$(basename "$path")"
  if [[ -e "$path" || -L "$path" ]]; then
    cp -a -- "$path" "${SUB_TX_DIR}/${key}"
    : >"${SUB_TX_DIR}/${key}.present"
  fi
done
SUB_TX_ACTIVE=1
mv -f "$RAW_TMP" "$OUT_RAW"
mv -f "$B64_TMP" "$OUT_B64"
SUB_TX_ACTIVE=0
rm -rf -- "$SUB_TX_DIR"
printf 'RAW: %s\nBASE64: %s\n' "$OUT_RAW" "$OUT_B64"
__VR_FILE_SUB__
chmod 755 '/usr/local/sbin/vless_temp_sub.sh'

for generated_script in \
  /usr/local/lib/vless-reality/common.sh \
  /usr/local/lib/vless-reality/iplimit-lib.sh \
  /usr/local/lib/vless-reality/quota-lib.sh \
  /usr/local/sbin/iplimit_restore_all.sh \
  /usr/local/sbin/pq_add.sh /usr/local/sbin/pq_audit.sh /usr/local/sbin/pq_del.sh \
  /usr/local/sbin/ip_set.sh /usr/local/sbin/ip_del.sh \
  /usr/local/sbin/pq_reset_due.sh /usr/local/sbin/pq_restore_all.sh /usr/local/sbin/pq_save_state.sh \
  /usr/local/sbin/vless_audit.sh /usr/local/sbin/vless_cleanup_one.sh \
  /usr/local/sbin/vless_clear_all.sh /usr/local/sbin/vless_gc.sh \
  /usr/local/sbin/vless_mktemp.sh /usr/local/sbin/vless_restore_all.sh \
  /usr/local/sbin/vless_managed_watchdog.sh /usr/local/sbin/vless_run_temp.sh \
  /usr/local/sbin/vless_temp_sub.sh
do
  bash -n "$generated_script" || die "生成脚本语法检查失败：${generated_script}"
done
python3 - /usr/local/lib/vless-reality/render_table.py <<'PY_COMPILE'
import pathlib, sys
compile(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'), sys.argv[1], 'exec')
PY_COMPILE

systemctl daemon-reload
if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify \
    /etc/systemd/system/pq-reset.service /etc/systemd/system/pq-reset.timer \
    /etc/systemd/system/pq-save.service /etc/systemd/system/pq-save.timer \
    /etc/systemd/system/vless-gc.service /etc/systemd/system/vless-gc.timer \
    /etc/systemd/system/vless-managed-restore.service \
    /etc/systemd/system/vless-managed-watchdog.service /etc/systemd/system/vless-managed-watchdog.timer \
    /etc/systemd/system/vless-managed-shutdown-save.service >/dev/null
fi
# 首次恢复在当前进程内执行，显式继承安装器已持有的三把锁；若通过
# systemd 启动，子进程看不到 VR_*_LOCK_HELD，会反向等待父进程而死锁。
VR_TEMP_LOCK_HELD=1 VR_PQ_LOCK_HELD=1 VR_IL_LOCK_HELD=1 \
  /usr/local/sbin/vless_restore_all.sh \
  || die "管理规则首次恢复失败；已回滚模块文件和 unit 状态"
/usr/local/sbin/vless_temp_sub.sh >/dev/null \
  || die "临时节点订阅刷新失败；已回滚模块文件和 unit 状态"

systemctl enable vless-gc.timer >/dev/null
systemctl enable pq-save.timer >/dev/null
systemctl enable pq-reset.timer >/dev/null
systemctl enable vless-managed-watchdog.timer >/dev/null
systemctl enable vless-managed-restore.service >/dev/null
systemctl enable vless-managed-shutdown-save.service >/dev/null
for timer in "${MODULE_TIMERS[@]}"; do
  systemctl start "$timer" || die "timer 启动失败：${timer}"
  systemctl is-active --quiet "$timer" || die "timer 未处于 active：${timer}"
done
module_commit

cat <<'USE'
✅ 后续模块已安装或刷新：
  - IPv4/IPv6 临时 VLESS 节点
  - nftables 端口流量配额
  - IPv4/IPv6 来源地址槽位限制
  - 协议族隔离、自动清理、保存、重启恢复和运行时规则自愈
  - 临时节点 RAW/Base64 聚合订阅
  - 审计命令

常用命令：
  id=tmp4 IP_VERSION=4 IP_LIMIT=1 PQ_GIB=1 D=1200 vless_mktemp.sh
  id=tmp6 IP_VERSION=6 IP_LIMIT=1 PQ_GIB=1 D=1200 vless_mktemp.sh
  vless_audit.sh
  pq_audit.sh
  vless_temp_sub.sh
  vless_clear_all.sh
USE
__FINAL_AUDIT__

chmod 755 "$BUNDLE_MAIN_TMP" "$BUNDLE_AUDIT_TMP"
bash -n "$BUNDLE_MAIN_TMP" "$BUNDLE_AUDIT_TMP"

# 两个入口脚本作为一个短事务提交；提交阶段屏蔽普通终止信号，任一步
# 失败都会由 EXIT trap 恢复旧文件或删除首次部署产生的新文件。
trap '' INT TERM HUP
mv -f -- "$BUNDLE_MAIN_TMP" "$BUNDLE_MAIN"
mv -f -- "$BUNDLE_AUDIT_TMP" "$BUNDLE_AUDIT"
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

bash "$BUNDLE_AUDIT"
BUNDLE_TX_ACTIVE=0
rm -rf -- "$BUNDLE_TX_DIR"

cat <<'DONE'
============================================================
✅ 最终版已写入并安装管理模块。

先编辑：
  /etc/default/vless-reality

安装或更新 IPv4 主节点：
  bash /root/onekey_reality_ipv4.sh

固定 Xray 版本：
  XRAY_VERSION=vX.Y.Z bash /root/onekey_reality_ipv4.sh

创建 IPv4 临时节点：
  id=tmp4 IP_VERSION=4 IP_LIMIT=1 PQ_GIB=1 D=1200 vless_mktemp.sh

创建 IPv6 临时节点：
  id=tmp6 IP_VERSION=6 IP_LIMIT=1 PQ_GIB=1 D=1200 vless_mktemp.sh

审计及订阅：
  vless_audit.sh
  pq_audit.sh
  vless_temp_sub.sh

说明：
  - 主节点保持 IPv4。
  - IPv6 临时节点需要设置 PUBLIC_IPV6_DOMAIN，并配置正确 AAAA。
  - 脚本不会自动启用 nftables.service；规则由独立恢复服务管理。
============================================================
DONE
