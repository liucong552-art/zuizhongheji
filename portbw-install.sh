#!/usr/bin/env bash
# portbw v5.2.2 rolling hold release; local pair or remote bootstrap from zuizhongheji/main.
# Always check the exact embedded SHA256 before installing Python payload.
# Never resets root qdisc, flushes foreign nft tables, or modifies node services.
set -Eeuo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log() { printf '[portbw] %s\n' "$*"; }
die() { printf '[portbw] 错误：%s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'HELP'
用法：
  bash ./portbw-install.sh [install|update] [--iface eth0] [--nft-only]
  bash <(curl -fsSL https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main/portbw-install.sh) [install|update] [--iface eth0]

Debian/Ubuntu + systemd + root：自动补齐依赖、核对源码哈希、识别默认路由网卡，
并安装 nft + tc 双层限速、开机恢复服务和每1秒自检 timer（best effort）。
自动检测服务内置 systemd 启动频率限流修复，不需要手工添加 drop-in。
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

# Accept the two-file local bundle or a remote process-substitution bootstrap.
# A normal local file MUST have a colocated portbw.py; do not silently mix files.
SOURCE_SCRIPT="${BASH_SOURCE[0]:-}"
WORK=''
cleanup_source() {
  if [[ -n "$WORK" ]]; then rm -rf -- "$WORK"; fi
}
trap cleanup_source EXIT
case "${SOURCE_SCRIPT##*/}" in
  portbw-install.sh|install.sh)
    [[ -f "$SOURCE_SCRIPT" ]] || die '本地安装文件不存在'
    SRC="$(cd -- "$(dirname -- "$SOURCE_SCRIPT")" && pwd -P)"
    [[ -f "$SRC/portbw.py" ]] || die '本地缺少 portbw.py；请放在同一目录'
    log "本地源码：$SRC"
    ;;
  *)
    # curl HTTPS + pinned payload digest protect against stale/mismatched uploads.
    WORK="$(mktemp -d /var/tmp/portbw-src.XXXXXXXX)"
    SRC="$WORK"
    BASE='https://raw.githubusercontent.com/liucong552-art/zuizhongheji/refs/heads/main'
    log "远程下载正式版主体：$BASE/portbw.py"
    curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 --max-time 90 \
      "$BASE/portbw.py" -o "$SRC/portbw.py" || die '正式仓库源码下载失败；请核对发布情况'
    ;;
esac

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

# The downloaded or local Python file is verified against the same fixed manifest.
[[ -f "$SRC/portbw.py" ]] || die '缺少 portbw.py'

# Embedded manifest: only TWO executable files need to exist online.
# The sha256 of portbw.py must change together with this value in the installer.
EXPECTED_PORTBW_SHA256='face2509536f182d9fe894b98515d5ad9dfb46c36c5555cca3286228a7984f5b'
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
  UNIT_NAMES=(portbw-restore.service portbw-watch.service portbw-watch.timer)
  OLD_ENABLED=()
  OLD_ACTIVE=()
  for unit in "${UNIT_NAMES[@]}"; do
    OLD_ENABLED+=("$(systemctl is-enabled "$unit" 2>/dev/null || true)")
    OLD_ACTIVE+=("$(systemctl is-active "$unit" 2>/dev/null || true)")
  done
  systemctl is-active --quiet portbw-watch.timer && OLD_TIMER_ACTIVE=1 || true
  systemctl is-active --quiet portbw-watch.service && OLD_WORKER_ACTIVE=1 || true

  rollback_on_exit() {
    status=$?
    trap - EXIT ERR INT TERM HUP
    if ((SUCCESS == 0 && ARMED == 1)); then
      systemctl stop portbw-watch.timer >/dev/null 2>&1 || true
      rollback_failed=0
      for idx in "${!PRESENT[@]}"; do
        target="${PRESENT[$idx]}"
        if [[ -f "$BACKUP/$idx.present" ]]; then
          temp_restore="$target.rollback.$$"
          if cp -a -- "$BACKUP/$idx.old" "$temp_restore" && mv -f -- "$temp_restore" "$target"; then
            :
          else
            rollback_failed=1
            printf '回滚失败：%s\n' "$target" >&2
          fi
        else
          rm -f -- "$target" || rollback_failed=1
        fi
      done
      systemctl daemon-reload >/dev/null 2>&1 || rollback_failed=1
      for idx in "${!UNIT_NAMES[@]}"; do
        unit="${UNIT_NAMES[$idx]}"
        case "${OLD_ENABLED[$idx]}" in
          enabled|linked) systemctl enable "$unit" >/dev/null 2>&1 || rollback_failed=1 ;;
          enabled-runtime|linked-runtime) systemctl enable --runtime "$unit" >/dev/null 2>&1 || rollback_failed=1 ;;
          *) systemctl disable "$unit" >/dev/null 2>&1 || true ;;
        esac
        # Do not rerun the old one-shot worker while restoring files.
        if [[ "$unit" == portbw-watch.timer && "${OLD_ACTIVE[$idx]}" == active ]]; then
          systemctl start "$unit" >/dev/null 2>&1 || rollback_failed=1
        fi
      done
      printf '[portbw] 安装失败；已尝试回滚程序、配置与 systemd 文件。端口意图状态保留，内核规则未清空；请核对 portbw audit。\n' >&2
      if ((rollback_failed)); then
        printf '[portbw] 部分回滚失败，保留备份：%s\n' "$BACKUP" >&2
        BACKUP=''
      fi
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
  for path in "$PROGRAM" "$WRAPPER" /etc/portbw/config.json \
      /etc/systemd/system/portbw-restore.service \
      /etc/systemd/system/portbw-watch.service /etc/systemd/system/portbw-watch.timer; do
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
  # Defense in depth: verify the effective setting after the nested installer.
  [[ "$(systemctl show portbw-watch.service -p StartLimitIntervalUSec)" == 'StartLimitIntervalUSec=0' ]] || \
    die 'portbw-watch.service 的有效 StartLimitIntervalSec 非 0；拒绝报告安装成功'
  SUCCESS=1
)

install_files  # standalone call: Bash errexit must remain active inside the subshell
log '安装完成！nft/tc 与 systemd 校验通过。现在可运行：portbw set 40001 10 20'
