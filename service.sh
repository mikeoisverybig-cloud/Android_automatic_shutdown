#!/system/bin/sh

umask 077

MOD_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -z "$MOD_DIR" ] || [ "$MOD_DIR" = "/" ]; then
    MOD_DIR="/data/adb/modules/my_shutdown_tool"
fi

if [ ! -d "$MOD_DIR" ]; then
    mkdir -p "$MOD_DIR" 2>/dev/null || { echo "FATAL: 无法创建模块目录 $MOD_DIR"; exit 1; }
    chmod 700 "$MOD_DIR"
fi

LOCK_FILE="$MOD_DIR/shutdown_timer.lock"
LOG_FILE="$MOD_DIR/shutdown_timer.log"
CONFIG_FILE="$MOD_DIR/time.txt"
PKG_CACHE="$MOD_DIR/.user_pkg_cache"
SYS_PKG_CACHE="$MOD_DIR/.system_pkg_cache"

DEBUG=${DEBUG:-0}
STEP=10
NOTIF_WAIT_MAX=10
LOG_MAX_SIZE=1048576
BATT_STATUS_PATH=""
LOCK_MODE=""
LOCK_DIR="${LOCK_FILE}.d"

log()       { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_info()  { log "[INFO]  $*"; }
log_warn()  { log "[WARN]  $*"; }
log_error() { log "[ERROR] $*"; }
log_debug() { [ "$DEBUG" -eq 1 ] && log "[DEBUG] $*"; }

if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_SIZE" ]; then
    tail -n 200 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
fi

exec >> "$LOG_FILE" 2>&1
log "=================================================="
log "=== 自动关机服务启动 (V28 Production) ==="

TAG="shutdown_timer"
NOTIF_ID=$(printf '%s' "$TAG" | cksum 2>/dev/null | cut -d' ' -f1)
[ -z "$NOTIF_ID" ] && NOTIF_ID=$(( $$ % 9000 + 1000 ))
NOTIF_CAPABLE=0
NOTIF_TITLE="⚠️ 自动关机倒计时"
NOTIF_EVER_POSTED=0
command -v cmd >/dev/null 2>&1 && NOTIF_CAPABLE=1

cancel_notif() {
    if [ "$NOTIF_EVER_POSTED" -ne 1 ]; then return 0; fi
    cmd notification cancel --user 0 "$TAG" "$NOTIF_ID" >/dev/null 2>&1 || true
    cmd notification cancel "$TAG" "$NOTIF_ID" >/dev/null 2>&1 || true
    NOTIF_EVER_POSTED=0
}

cleanup() {
    cancel_notif
    case "$LOCK_MODE" in
        flock)
            exec 9>&- 2>/dev/null
            ;;
        mkdir)
            rm -rf "$LOCK_DIR" 2>/dev/null
            ;;
    esac
    log "服务已结束/退出"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

_script_abs="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"

UPTIME=$(cat /proc/uptime 2>/dev/null | cut -d. -f1)
if [ -n "$UPTIME" ] && [ "$UPTIME" -lt 120 ]; then
    rm -f "$LOCK_FILE" 2>/dev/null
    rm -rf "$LOCK_DIR" 2>/dev/null
fi

for _stale_pid_src in "$LOCK_FILE" "$LOCK_DIR/pid"; do
    [ -f "$_stale_pid_src" ] || continue
    old_pid=$(cat "$_stale_pid_src" 2>/dev/null || echo "")
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        if tr '\0' ' ' < "/proc/$old_pid/cmdline" 2>/dev/null | grep -qF "$_script_abs"; then
            log_info "服务已在运行 (PID: $old_pid)，退出重复实例"
            exit 0
        fi
        log_warn "PID $old_pid 存活但非本实例，判定为 stale-lock 并清理"
    fi
    rm -f "$LOCK_FILE" 2>/dev/null
    rm -rf "$LOCK_DIR" 2>/dev/null
    break
done

if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log_error "flock 获取失败，退出"
        exit 0
    fi
    echo $$ > "$LOCK_FILE"
    chmod 600 "$LOCK_FILE" 2>/dev/null
    LOCK_MODE="flock"
else
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid"
        chmod 700 "$LOCK_DIR" 2>/dev/null
        LOCK_MODE="mkdir"
    else
        log_error "另一个实例已存在 (mkdir 锁)，退出"
        exit 0
    fi
fi

while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 5; done

wait_cnt=0
while ! dumpsys notification >/dev/null 2>&1; do
    sleep 3
    wait_cnt=$((wait_cnt + 1))
    if [ "$wait_cnt" -ge "$NOTIF_WAIT_MAX" ]; then
        break
    fi
done
sleep 3

check_charging() {
    local status
    if [ -z "$BATT_STATUS_PATH" ]; then
        if [ -f "/sys/class/power_supply/battery/status" ]; then
            BATT_STATUS_PATH="/sys/class/power_supply/battery/status"
        else
            BATT_STATUS_PATH=$(find /sys/class/power_supply -maxdepth 2 -name "status" 2>/dev/null | head -1)
        fi
    fi

    if [ -n "$BATT_STATUS_PATH" ] && [ -f "$BATT_STATUS_PATH" ]; then
        status=$(tr -d '[:space:]' < "$BATT_STATUS_PATH" 2>/dev/null)
        case "$status" in
            Charging|Full) return 0 ;;
        esac
    fi
    dumpsys battery 2>/dev/null | grep -qE 'status:[[:space:]]*(2|5)([^0-9]|$)' && return 0
    return 1
}

format_time() {
    local _s _m _rs
    _s=$1
    _m=$((_s / 60))
    _rs=$((_s % 60))
    if [ "$_m" -gt 0 ]; then
        if [ "$_rs" -eq 0 ]; then
            echo "${_m} 分钟"
        else
            echo "${_m} 分 ${_rs} 秒"
        fi
    else
        echo "${_rs} 秒"
    fi
}

get_fg_pkg() {
    local _pkg _raw _retry=0
    while [ "$_retry" -lt 2 ]; do
        _raw=$(dumpsys activity activities 2>/dev/null | \
               grep -m1 -E "mResumedActivity|topResumedActivity")
        if [ -n "$_raw" ]; then
            _pkg=$(echo "$_raw" | grep -oE '[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+/[a-zA-Z0-9_.]+' | cut -d/ -f1)
            if [ -n "$_pkg" ]; then break; fi
            _pkg=$(echo "$_raw" | grep -oE 'ActivityRecord\{[^}]*[[:space:]]+[a-zA-Z0-9_.]+/' | grep -oE '[a-zA-Z0-9_.]+/' | cut -d/ -f1)
            if [ -n "$_pkg" ]; then break; fi
        fi
        sleep 1
        _retry=$((_retry + 1))
    done

    if [ -z "$_pkg" ]; then
        _raw=$(dumpsys window windows 2>/dev/null | grep -m1 "mCurrentFocus")
        if [ -n "$_raw" ]; then
            _pkg=$(echo "$_raw" | grep -oE '[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+/[a-zA-Z0-9_.]+' | cut -d/ -f1)
        fi
    fi

    if [ "$DEBUG" -eq 1 ] && [ -z "$_pkg" ] && [ -n "$_raw" ]; then
        dumpsys activity activities 2>/dev/null | head -n 5 >> "$LOG_FILE"
    fi
    echo "$_pkg"
}

is_system_ui() {
    case "$1" in
        ""|null|android) return 0 ;;
        com.android.systemui|com.android.settings|com.android.packageinstaller|com.android.keyguard) return 0 ;;
        com.android.launcher*|com.miui.home|com.oppo.launcher|com.vivo.launcher|com.huawei.android.launcher|com.google.android.apps.nexuslauncher|com.coloros.launcher|com.sec.android.app.launcher) return 0 ;;
        *) return 1 ;;
    esac
}

init_pkg_cache() {
    if [ -f "$PKG_CACHE" ] && [ -f "$SYS_PKG_CACHE" ]; then
        if find "$PKG_CACHE" -mmin +1440 2>/dev/null | grep -q .; then
            log_info "包缓存已过期 (>24h)，执行重建"
            rm -f "$PKG_CACHE" "$SYS_PKG_CACHE"
        fi
    fi

    if [ ! -f "$PKG_CACHE" ] || [ ! -f "$SYS_PKG_CACHE" ]; then
        local pm_wait=0
        while ! pm path android >/dev/null 2>&1; do
            sleep 2
            pm_wait=$((pm_wait + 2))
            if [ "$pm_wait" -ge 30 ]; then
                break
            fi
        done
        pm list packages -3 2>/dev/null | sed 's/^package://' > "$PKG_CACHE.tmp" 2>/dev/null \
            && mv -f "$PKG_CACHE.tmp" "$PKG_CACHE"
        pm list packages -s 2>/dev/null | sed 's/^package://' > "$SYS_PKG_CACHE.tmp" 2>/dev/null \
            && mv -f "$SYS_PKG_CACHE.tmp" "$SYS_PKG_CACHE"
        log_debug "已原子化重建缓存"
    fi
}

is_user_app() {
    if grep -qxF "$1" "$SYS_PKG_CACHE" 2>/dev/null; then return 1; fi
    if grep -qxF "$1" "$PKG_CACHE" 2>/dev/null; then return 0; fi
    if pm path "$1" 2>/dev/null | grep -q "/data/app/"; then
        echo "$1" >> "$PKG_CACHE" 2>/dev/null
        return 0
    fi
    return 1
}

TAG="shutdown_timer"
NOTIF_ID=$(printf '%s' "$TAG" | cksum 2>/dev/null | cut -d' ' -f1)
[ -z "$NOTIF_ID" ] && NOTIF_ID=$(( $$ % 9000 + 1000 ))

NOTIF_CAPABLE=0
NOTIF_TITLE="⚠️ 自动关机倒计时"
NOTIF_EVER_POSTED=0
command -v cmd >/dev/null 2>&1 && NOTIF_CAPABLE=1 || log_warn "缺少 cmd，通知降级"

post_notif() {
    if [ "$NOTIF_CAPABLE" -ne 1 ]; then
        log_warn "无 cmd 环境，降级记录日志: $1"
        return 1
    fi
    local _msg="$1" _extra
    for _extra in "--user 0 --channel alert" "--user 0 --channel default" "--user 0" ""; do
        if cmd notification post $_extra "$TAG" "$NOTIF_ID" "$NOTIF_TITLE" "$_msg" >/dev/null 2>&1; then
            NOTIF_EVER_POSTED=1
            return 0
        fi
    done
    return 1
}

THRESHOLD_SEC=600
if [ -f "$CONFIG_FILE" ]; then
    parsed_time=$(head -n1 "$CONFIG_FILE" 2>/dev/null | grep -oE '^[0-9]+')
    if [ -n "$parsed_time" ] && [ "$parsed_time" -ge 10 ] && [ "$parsed_time" -le 86400 ]; then
        THRESHOLD_SEC=$parsed_time
        log_info "读取配置成功: ${THRESHOLD_SEC} 秒"
    fi
fi

check_charging >/dev/null
init_pkg_cache

if check_charging; then
    log_info "取消关机 (原因: 开机检测到插入充电器)"
    exit 0
fi

INIT_FG_PKG="$(get_fg_pkg)"
log_info "初始前台: ${INIT_FG_PKG:-未知}"

post_notif "系统将在 $(format_time "$THRESHOLD_SEC") 后关机。打开应用或充电可取消！"

countdown=$THRESHOLD_SEC
last_min=-1

while [ "$countdown" -gt 0 ]; do
    if [ "$countdown" -ge "$STEP" ]; then
        sleep "$STEP"
        countdown=$((countdown - STEP))
    else
        sleep "$countdown"
        countdown=0
    fi

    if check_charging; then
        log_info "取消关机 (原因: 运行期检测到插入充电器)"
        cancel_notif
        exit 0
    fi

    CURR_FG="$(get_fg_pkg)"
    if [ -n "$CURR_FG" ] && [ "$CURR_FG" != "$INIT_FG_PKG" ] && ! is_system_ui "$CURR_FG" && is_user_app "$CURR_FG"; then
        log_info "取消关机 (原因: 前台切换至第三方应用 $CURR_FG)"
        cancel_notif
        exit 0
    fi

    if [ "$countdown" -gt 0 ]; then
        cur_min=$((countdown / 60))
        if [ "$countdown" -le 30 ] || [ "$cur_min" -ne "$last_min" ]; then
            post_notif "系统将在 $(format_time "$countdown") 后关机。打开应用或充电可取消！"
            last_min=$cur_min
        fi
    fi
done

cancel_notif
sync

log_info "触发 sys.powerctl shutdown"
setprop sys.powerctl shutdown 2>/dev/null

log_info "等待 Init 接管 (超时 10s)..."
_wait=0
while [ "$_wait" -lt 10 ]; do
    sleep 1
    _wait=$((_wait + 1))
done

log_warn "Init 未响应或关机延迟，采集现场快照并强制 reboot"
if [ "$DEBUG" -eq 1 ]; then
    log_debug "Logcat快照: $(logcat -d -t 10 -v time 2>/dev/null | tail -n 3 | tr '\n' ';')"
    log_debug "Kernel快照: $(dmesg 2>/dev/null | tail -n 3 | tr '\n' ';')"
fi
reboot -p
sleep 5

log_error "所有关机方式均失败！脚本异常终止"
