#!/usr/bin/env bash
# portbw Debian/Ubuntu zuizhongheji optional TCP+UDP shared bandwidth release: portbw-install.sh + portbw.py
# This entry point both bootstraps from GitHub and installs the program and units.
# Never resets root qdisc, flushes foreign nft tables, or modifies node services.
set -Eeuo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log() { printf '[portbw] %s\n' "$*"; }
die() { printf '[portbw] 错误：%s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'HELP'
用法：
  bash <(curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/portbw-install.sh')
  bash portbw-install.sh [install|update] [--iface eth0] [--nft-only]

Debian/Ubuntu + systemd + root：自动补齐依赖、核对源码哈希、识别默认路由网卡，
并安装 nft + tc 双层限速、开机恢复服务和每30秒自检 timer。
已有配置和端口规则保留。--nft-only 必须手动指定，不会静默降级。
HELP
}

ACTION=install
IFACE=''
EXPLICIT_IFACE=0
NFT_ONLY=0
if (($#)) && [[ "$1" == install || "$1" == update ]]; then ACTION="$1"; shift; fi
while (($#)); do
  case "$1" in
    --iface) (($# >= 2)) || die '--iface 需要网卡名称'; IFACE="$2"; EXPLICIT_IFACE=1; shift 2 ;;
    --iface=*) IFACE="${1#*=}"; EXPLICIT_IFACE=1; shift ;;
    --nft-only) NFT_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

[[ ${EUID:-999} -eq 0 ]] || die '请使用 root 执行'
[[ -f /etc/os-release ]] || die '无法识别系统；仅支持 Debian/Ubuntu'
# shellcheck source=/etc/os-release
. /etc/os-release
case "${ID:-}" in debian|ubuntu) ;; *) die "不支持的发行版：${ID:-unknown}" ;; esac
[[ -d /run/systemd/system ]] || die 'PID1 必须是 systemd；不支持非 systemd 容器'
command -v apt-get >/dev/null && command -v dpkg-query >/dev/null || die '需要 apt-get/dpkg'

# Install only packages missing from the package database. No git or pip needed.
PACKAGES=(ca-certificates curl python3 nftables iproute2 util-linux coreutils)
MISSING=()
for pkg in "${PACKAGES[@]}"; do
  if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -qx 'install ok installed'; then
    MISSING+=("$pkg")
  fi
done
if ((${#MISSING[@]})); then
  log "自动安装缺少的依赖：${MISSING[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -o Acquire::Retries=3
  apt-get install -y --no-install-recommends -o DPkg::Lock::Timeout=120 "${MISSING[@]}"
fi
for cmd in curl sha256sum python3 nft tc ip ss flock timeout systemctl install mktemp; do
  command -v "$cmd" >/dev/null || die "依赖安装后仍缺少命令：$cmd"
done

# Bash process substitution has /dev/fd/N as BASH_SOURCE[0]. If a real local
# install.sh exists, use a local copy of portbw.py; otherwise fetch from GitHub.
SOURCE_SCRIPT="${BASH_SOURCE[0]}"
WORK=''
cleanup_source() {
  if [[ -n "$WORK" && -d "$WORK" ]]; then rm -rf -- "$WORK"; fi
}
trap cleanup_source EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
if [[ ( "${SOURCE_SCRIPT##*/}" == portbw-install.sh || "${SOURCE_SCRIPT##*/}" == install.sh ) && -f "$SOURCE_SCRIPT" ]]; then
  SRC="$(cd -- "$(dirname -- "$SOURCE_SCRIPT")" && pwd -P)"
  [[ -f "$SRC/portbw.py" ]] || die '本地缺少 portbw.py；请与 portbw-install.sh 放在同一目录'
  log "使用本地源码：$SRC"
else
  WORK="$(mktemp -d /var/tmp/portbw-src.XXXXXXXX)"
  SRC="$WORK"
  BASE='https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main'
  log '从 GitHub main 下载限速主体 portbw.py ...'
  curl -fL --retry 3 --connect-timeout 15 --max-time 120 \
    --proto '=https' --tlsv1.2 --silent --show-error \
    "$BASE/portbw.py" -o "$SRC/portbw.py" || die 'GitHub 主体文件下载失败；检查 main 根目录是否有 portbw.py'
fi

# Embedded manifest: only TWO executable files need to exist online.
# The sha256 of portbw.py must change together with this value in the installer.
EXPECTED_PORTBW_SHA256='489ffd94b8b6d25f02954e6ce0965cd382098f20155125aeaefb4a9fe3735c14'
ACTUAL_PORTBW_SHA256="$(sha256sum "$SRC/portbw.py" | awk '{print $1}')"
[[ "$ACTUAL_PORTBW_SHA256" == "$EXPECTED_PORTBW_SHA256" ]] || die "portbw.py SHA256 不符：实际 $ACTUAL_PORTBW_SHA256；为避免旧版混装已停止"
python3 -B - "$SRC/portbw.py" <<'PY' || die 'portbw.py 语法校验失败'
import ast,sys
with open(sys.argv[1], encoding='utf8') as fp:
    ast.parse(fp.read(), filename=sys.argv[1])
PY
log '源码哈希与 Python 语法校验通过'

# An existing install retains its bound interface and nft-only mode.
CONF='/etc/portbw/config.json'
if [[ -f "$CONF" ]]; then
  config_info="$(python3 -B - "$CONF" <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1],encoding='utf8'))
print(cfg.get('iface',''))
print('yes' if cfg.get('tc_enabled',True) else 'no')
PY
)" || die "已有配置解析失败：$CONF"
  if ((EXPLICIT_IFACE == 0)); then IFACE="$(printf '%s\n' "$config_info" | sed -n '1p')"; fi
  if [[ "$(printf '%s\n' "$config_info" | sed -n '2p')" == no ]] && ((NFT_ONLY == 0)); then
    NFT_ONLY=1
    log '保留现有 nft-only 模式'
  fi
fi
if [[ -z "$IFACE" ]]; then
  route="$(ip -4 route get 1.1.1.1 2>/dev/null || true)"
  if [[ ! "$route" =~ [[:space:]]dev[[:space:]]([a-zA-Z0-9_.-]+) ]]; then
    route="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null || true)"
  fi
  if [[ "$route" =~ [[:space:]]dev[[:space:]]([a-zA-Z0-9_.-]+) ]]; then
    IFACE="${BASH_REMATCH[1]}"
  else
    die '无法从默认路由识别网卡；请手动 --iface ens3（不猜测网卡）'
  fi
  case "$IFACE" in
    lo|wg*|tun*|tap*|tailscale*|docker*|veth*)
      die "默认路由使用隧道/虚拟网卡 $IFACE；为保护 WireGuard，请显式 --iface 指定真实出口" ;;
  esac
fi
[[ "$IFACE" =~ ^[a-zA-Z0-9_.-]{1,15}$ ]] || die "网卡名称非法：$IFACE"
ip link show dev "$IFACE" >/dev/null || die "网卡不存在：$IFACE"
log "安装配置：$ID / $IFACE / $([[ $NFT_ONLY == 1 ]] && echo nft-only || echo nft+tc)"

# Install/upgrade atomically without replacing existing Xray/WG/3proxy units.
# An inner subshell owns its own EXIT trap to roll back replaced files if needed;
# the outer EXIT trap only deletes the temporary downloaded source.
install_files() (
  set -Eeuo pipefail
  umask 077
  install -d -m 0755 /usr/local/lib/portbw /usr/local/sbin
  install -d -m 0700 /run/portbw
  exec 9>/run/portbw/install.lock
  flock -w 120 9 || die '安装锁繁忙；拒绝并发安装'

  PROGRAM=/usr/local/lib/portbw/portbw.py
  WRAPPER=/usr/local/sbin/portbw
  BACKUP=''
  SUCCESS=0
  ARMED=0
  STAGED=()
  PRESENT=()
  OLD_TIMER_ACTIVE=0
  OLD_WORKER_ACTIVE=0
  systemctl is-active --quiet portbw-watch.timer && OLD_TIMER_ACTIVE=1 || true
  systemctl is-active --quiet portbw-watch.service && OLD_WORKER_ACTIVE=1 || true

  rollback_on_exit() {
    status=$?
    trap - EXIT ERR INT TERM HUP
    if ((SUCCESS == 0 && ARMED == 1)); then
      for idx in "${!PRESENT[@]}"; do
        target="${PRESENT[$idx]}"
        if [[ -f "$BACKUP/$idx.present" ]]; then
          cp -a -- "$BACKUP/$idx.old" "$target" || printf '回滚失败：%s\n' "$target" >&2
        else
          rm -f -- "$target" || true
        fi
      done
      printf '[portbw] 安装失败；已尝试回滚程序文件。未清空已有内核限速规则。\n' >&2
    fi
    if ((${#STAGED[@]})); then rm -f -- "${STAGED[@]}" || true; fi
    if [[ -n "$BACKUP" ]]; then rm -rf -- "$BACKUP" || true; fi
    if ((SUCCESS == 0 && OLD_TIMER_ACTIVE == 1)); then
      systemctl start portbw-watch.timer >/dev/null 2>&1 || true
    fi
    exit "$status"
  }
  trap rollback_on_exit EXIT
  BACKUP="$(mktemp -d /var/tmp/portbw-backup.XXXXXXXX)"
  for path in "$PROGRAM" "$WRAPPER"; do
    idx="${#PRESENT[@]}"
    if [[ -e "$path" || -L "$path" ]]; then
      cp -a -- "$path" "$BACKUP/$idx.old"
      : > "$BACKUP/$idx.present"
    fi
    PRESENT+=("$path")
  done
  ARMED=1

  systemctl stop portbw-watch.timer >/dev/null 2>&1 || true
  if ((OLD_WORKER_ACTIVE)); then
    timeout 30 systemctl stop portbw-watch.service >/dev/null 2>&1 || die '旧 portbw 工作进程无法停止，拒绝更新'
  fi

  STAGED=("$PROGRAM.new.$$" "$WRAPPER.new.$$")
  install -m 0700 "$SRC/portbw.py" "${STAGED[0]}"
  mv -f -- "${STAGED[0]}" "$PROGRAM"
  cat > "${STAGED[1]}" <<'WRAPPER_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exec /usr/bin/python3 /usr/local/lib/portbw/portbw.py "$@"
WRAPPER_EOF
  chmod 0755 "${STAGED[1]}"
  mv -f -- "${STAGED[1]}" "$WRAPPER"

  python_args=(install --iface "$IFACE")
  if ((NFT_ONLY)); then python_args+=(--nft-only); fi
  "$WRAPPER" "${python_args[@]}"
  "$WRAPPER" audit || die '安装后审计未通过，未认定安装成功'
  systemctl is-enabled --quiet portbw-watch.timer || die '自动检查 timer 未启用'
  systemctl is-active --quiet portbw-watch.timer || die '自动检查 timer 未启动'
  SUCCESS=1
)

install_files  # standalone call: Bash errexit must remain active inside the subshell
log '安装完成！nft/tc 与 systemd 校验通过。现在可运行：portbw set 40001 10 20'
