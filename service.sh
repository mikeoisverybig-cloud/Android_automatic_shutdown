
#!/system/bin/sh
umask 077

MOD_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -z "$MOD_DIR" ] && MOD_DIR="/data/adb/modules/my_shutdown_tool"

if [ ! -d "$MOD_DIR" ]; then
    mkdir -p "$MOD_DIR" 2>/dev/null || { printf '%s\n' "FATAL: 无法创建模块目录 $MOD_DIR"; exit 1; }
    chmod 700 "$MOD_DIR"
fi

LOCK_FILE="$MOD_DIR/shutdown_timer.lock"
LOCK_DIR="${LOCK_FILE}.dir"
LOG_FILE="$MOD_DIR/shutdown_timer.log"
CONFIG_FILE="$MOD_DIR/time.txt"

DEBUG=${DEBUG:-0}
STEP=10
NOTIF_WAIT_MAX=10
LOG_MAX_SIZE=1048576
BOOT_WAIT_MAX=120

log() { printf '%s\n' "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_info()  { log "[INFO] $*"; }
log_warn()  { log "[WARN] $*"; }
log_error() { log "[ERROR] $*"; }
log_debug() { [ "$DEBUG" -eq 1 ] && log "[DEBUG] $*"; }

# rotate log if too large
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_SIZE" ]; then
    > "$LOG_FILE"
fi
exec >> "$LOG_FILE" 2>&1

log "=================================================="
log "=== 自动关机服务启动 (V27.21 debug) ==="

# Early environment dump (helpful when no notification appears)
log_info "ENV: user=$(id 2>/dev/null || echo unknown) PATH=${PATH:-unset} SHELL=${SHELL:-unset}"
log_info "ENV: getenforce=$(getenforce 2>/dev/null || echo unknown) sys.boot_completed=$(getprop sys.boot_completed 2>/dev/null || echo unknown)"
if command -v cmd >/dev/null 2>&1; then
    log_info "ENV: cmd exists at $(command -v cmd)"
else
    log_warn "ENV: cmd not found in PATH"
fi

trap 'log_warn "捕获到 SIGINT"; exit 130' INT
trap 'log_warn "捕获到 SIGTERM"; exit 143' TERM
trap 'log_warn "捕获到 SIGHUP"; exit 129' HUP
trap ':' EXIT

cleanup() {
    log_debug "cleanup invoked (NOTIF_POSTED=${NOTIF_POSTED:-0})"
    if [ "${NOTIF_POSTED:-0}" -eq 1 ]; then
        log_debug "cleanup: calling cancel_notif"
        cancel_notif
    fi

    if [ -d "$LOCK_DIR" ]; then
        lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
        if [ -n "$lock_pid" ] && [ "$lock_pid" = "$$" ]; then
            rm -rf "$LOCK_DIR" 2>/dev/null || true
            log_debug "cleanup: removed lock dir"
        else
            log_warn "cleanup: lock dir not owned by this pid (lock_pid=${lock_pid:-none})"
        fi
    fi
    log "服务已结束/退出"
}

_script_abs="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
_script_base="$(basename "$0")"

# Try to remove stale lock dir if present and dead
if [ -d "$LOCK_DIR" ]; then
    old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        if tr '\0' ' ' < "/proc/$old_pid/cmdline" 2>/dev/null | grep -qF "$_script_abs"; then
            log_info "已有实例运行 (PID: $old_pid)，退出"
            exit 0
        elif tr '\0' ' ' < "/proc/$old_pid/cmdline" 2>/dev/null | grep -qF "$_script_base"; then
            log_info "已有实例运行 (PID: $old_pid)，退出"
            exit 0
        fi
        log_warn "锁目录 PID $old_pid 存在但非本脚本，清理"
    fi
    rm -rf "$LOCK_DIR" 2>/dev/null || true
fi

# Create lock dir atomically
if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
    chmod 700 "$LOCK_DIR" 2>/dev/null || true
    log_debug "acquired lock dir ($LOCK_DIR) pid=$$"
else
    # try to detect live owner
    if [ -f "$LOCK_DIR/pid" ]; then
        old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            log_error "另一个实例已创建锁 (PID: $old_pid)，退出"
            exit 0
        fi
    fi
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
        chmod 700 "$LOCK_DIR" 2>/dev/null || true
        log_debug "acquired lock dir after cleanup"
    else
        log_error "无法获取锁，退出"
        exit 0
    fi
fi

trap cleanup EXIT

# Wait for services
elapsed=0
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
    elapsed=$((elapsed + 2))
    if [ "$elapsed" -ge "$BOOT_WAIT_MAX" ]; then
        log_warn "等待 sys.boot_completed 超时 ${BOOT_WAIT_MAX}s，继续"
        break
    fi
done

wait_cnt=0
while ! dumpsys notification >/dev/null 2>&1; do
    sleep 3
    wait_cnt=$((wait_cnt + 1))
    if [ "$wait_cnt" -ge "$NOTIF_WAIT_MAX" ]; then
        log_warn "等待 notification service 超时，继续（通知功能可能受限）"
        break
    fi
done
sleep 1

# Capabilities and config
if command -v cmd >/dev/null 2>&1; then
    NOTIF_CAPABLE=1
else
    NOTIF_CAPABLE=0
fi

TAG="shutdown_cancel_timer"
NOTIF_ID=0
NOTIF_TITLE="⚠️ 自动关机倒计时"
BATT_SYSFS_CANDIDATES="/sys/class/power_supply/battery/status /sys/class/power_supply/bms/status /sys/class/power_supply/main/status"
THRESHOLD_SEC=600

if [ -f "$CONFIG_FILE" ]; then
    parsed_time=$(head -n1 "$CONFIG_FILE" 2>/dev/null | grep -oE '^[0-9]+')
    if [ -n "$parsed_time" ] && [ "$parsed_time" -ge 10 ] && [ "$parsed_time" -le 86400 ]; then
        THRESHOLD_SEC=$parsed_time
        log_info "读取配置: ${THRESHOLD_SEC}s"
    else
        log_warn "配置异常 ($parsed_time)，使用默认 ${THRESHOLD_SEC}s"
    fi
else
    log_info "未找到 time.txt，使用默认 ${THRESHOLD_SEC}s"
fi

# Functions
check_charging() {
    seen_any_sysfs=0
    seen_non_charging=0

    for _batt_path in $BATT_SYSFS_CANDIDATES; do
        [ -f "$_batt_path" ] || continue
        seen_any_sysfs=1
        status=$(tr -d '[:space:]' < "$_batt_path" 2>/dev/null)
        case "$status" in
            Charging|Full)
                [ "$DEBUG" -eq 1 ] && log_debug "sysfs $_batt_path reports Charging/Full"
                return 0
                ;;
            ""|Unknown)
                [ "$DEBUG" -eq 1 ] && log_debug "sysfs $_batt_path empty/Unknown"
                continue
                ;;
            *)
                [ "$DEBUG" -eq 1 ] && log_debug "sysfs $_batt_path reports non-charging: $status"
                seen_non_charging=1
                ;;
        esac
    done

    if [ "$seen_any_sysfs" -eq 1 ]; then
        if [ "$seen_non_charging" -eq 1 ]; then
            [ "$DEBUG" -eq 1 ] && log_debug "sysfs 有明确非充电状态 -> 未充电"
            return 1
        fi
        [ "$DEBUG" -eq 1 ] && log_debug "sysfs 存在但均为空/Unknown -> 回退 dumpsys"
    fi

    dumpsys battery 2>/dev/null | grep -qE 'status:[[:space:]]*(2|5)([^0-9]|$)' && return 0
    return 1
}

format_time() {
    _s=$1
    _m=$((_s / 60))
    _rs=$((_s % 60))
    if [ "$_m" -gt 0 ]; then
        if [ "$_rs" -eq 0 ]; then
            printf '%s\n' "${_m} 分钟"
        else
            printf '%s\n' "${_m} 分 ${_rs} 秒"
        fi
    else
        printf '%s\n' "${_rs} 秒"
    fi
}

# Notification state
NOTIF_POSTED=0
NOTIF_SWIPE_OK=0
NOTIF_SELF_CANCELLED=0
NOTIF_CANCEL_USER=""
NOTIF_STRATEGY=""

# Helper: record cmd stderr to debug files and log first lines
_record_cmd_err() {
    # $1 = filename suffix, $2... = command
    suffix="$1"; shift
    outf="$LOCK_DIR/post_err_${suffix}"
    # run command, capture stderr
    "$@" >/dev/null 2> "$outf" || true
    if [ -s "$outf" ]; then
        head_line=$(sed -n '1p' "$outf" 2>/dev/null || echo "")
        log_warn "post_err_${suffix}: ${head_line}"
    else
        log_debug "post_err_${suffix}: (empty)"
    fi
}

post_notif() {
    [ "$NOTIF_CAPABLE" -ne 1 ] && { log_warn "post_notif: NOTIF_CAPABLE=0, skip"; return 1; }
    _msg="$1"

    # Try cached strategy first
    if [ -n "$NOTIF_STRATEGY" ]; then
        case "$NOTIF_STRATEGY" in
            alert)
                if cmd notification post --user 0 --channel alert "$TAG" "$NOTIF_ID" "$NOTIF_TITLE" "$_msg" >/dev/null 2>&1; then
                    NOTIF_CANCEL_USER="--user 0"; NOTIF_POSTED=1; NOTIF_SWIPE_OK=1; NOTIF_SELF_CANCELLED=0
                    [ "$DEBUG" -eq 1 ] && log_debug "通知发送成功 (缓存策略: alert)"
                    return 0
                fi
                ;;
            default)
                if cmd notification post --user 0 --channel default "$TAG" "$NOTIF_ID" "$NOTIF_TITLE" "$_msg" >/dev/null 2>&1; then
                    NOTIF_CANCEL_USER="--user 0"; NOTIF_POSTED=1; NOTIF_SWIPE_OK=1; NOTIF_SELF_CANCELLED=0
                    [ "$DEBUG" -eq 1 ] && log_debug "通知发送成功 (缓存策略: default)"
                    return 0
                fi
                ;;
            user0)
                if cmd notification post --user 0 "$TAG" "$NOTIF_ID" "$NOTIF_TITLE" "$_msg" >/dev/null 2>&1; then
                    NOTIF_CANCEL_USER="--user 0"; NOTIF_POSTED=1; NOTIF_SWIPE_OK=1; NOTIF_SELF_CANCELLED=0
                    [ "$DEBUG" -eq 1 ] && log_debug "通知发送成功 (缓存策略: --user 0)"
                    return 0
                fi
                ;;
            none)
                if cmd notification post "$TAG" "$NOTIF_ID" "$NOTIF_TITLE" "$_msg" >/dev/null 2>&1; then
                    NOTIF_CANCEL_USER=""; NOTIF_POSTED=1; NOTIF_SWIPE_OK=1; NOTIF_SELF_CANCELLED=0
                    [ "$DEBUG" -eq 1 ] && log_debug "通知发送成功 (缓存策略: none)"
                    return 0
                fi
                ;;
        esac
        NOTIF_STRATEGY=""
    fi

    # Strategy chain with diagnostics
    if cmd notification post --user 0 --channel alert "$TAG" "$NOTIF_ID" "$NOTIF_TITLE" "$_msg" >/dev/null 2> "$LOCK_DIR/post_err_alert"; then
        NOTIF_CANCEL_USER="--user 0"; NOTIF_POSTED=1; NOTIF_SWIPE_OK=1; NOTIF_SELF_CANCELLED=0; NOTIF_STRATEGY="alert"
        [ "$DEBUG" -eq 1 ] && log_debug "通知发送成功 (策略: alert)"
        return 0
    else
        [ -s "$LOCK_DIR/post_err_alert" ] && log_warn "post_err_alert: $(sed -n '1p' $LOCK_DIR/post_err_alert 2>/dev/null || echo '')"
    fi

    if cmd notification post --user 0 --channel default "$TAG" "$NOTIF_ID" "$NOTIF_TITLE" "$_msg" >/dev/null 2> "$LOCK_DIR/post_err_default"; then
        NOTIF_CANCEL_USER="--user 0"; NOTIF_POSTED=1; NOTIF_SWIPE_OK=1; NOTIF_SELF_CANCELLED=0; NOTIF_STRATEGY="default"
        [ "$DEBUG" -eq 1 ] && log_debug "通知发送成功 (策略: default)"
        return 0
    else
        [ -s "$LOCK_DIR/post_err_default" ] && log_warn "post_err_default: $(sed -n '1p' $LOCK_DIR/post_err_default 2>/dev/null || echo '')"
    fi

    if cmd notification post --user 0 "$TAG" "$NOTIF_ID" "$NOTIF_TITLE" "$_msg" >/dev/null 2> "$LOCK_DIR/post_err_user0"; then
        NOTIF_CANCEL_USER="--user 0"; NOTIF_POSTED=1; NOTIF_SWIPE_OK=1; NOTIF_SELF_CANCELLED=0; NOTIF_STRATEGY="user0"
        [ "$DEBUG" -eq 1 ] && log_debug "通知发送成功 (策略: --user 0)"
        return 0
    else
        [ -s "$LOCK_DIR/post_err_user0" ] && log_warn "post_err_user0: $(sed -n '1p' $LOCK_DIR/post_err_user0 2>/dev/null || echo '')"
    fi

    if cmd notification post "$TAG" "$NOTIF_ID" "$NOTIF_TITLE" "$_msg" >/dev/null 2> "$LOCK_DIR/post_err_none"; then
        NOTIF_CANCEL_USER=""; NOTIF_POSTED=1; NOTIF_SWIPE_OK=1; NOTIF_SELF_CANCELLED=0; NOTIF_STRATEGY="none"
        [ "$DEBUG" -eq 1 ] && log_debug "通知发送成功 (策略: none)"
        return 0
    else
        [ -s "$LOCK_DIR/post_err_none" ] && log_warn "post_err_none: $(sed -n '1p' $LOCK_DIR/post_err_none 2>/dev/null || echo '')"
    fi

    # All failed: record dumpsys snapshot if debug
    log_warn "所有通知策略均失败，记录 dumpsys snapshot（仅 DEBUG=1）"
    if [ "$DEBUG" -eq 1 ]; then
        dumpsys notification 2>/dev/null | sed -n '1,200p' > "$LOCK_DIR/dumpsys_notification_snapshot" 2>/dev/null || true
        log_warn "dumpsys snapshot saved to $LOCK_DIR/dumpsys_notification_snapshot (first line: $(sed -n '1p' $LOCK_DIR/dumpsys_notification_snapshot 2>/dev/null || echo none))"
    fi

    [ "${NOTIF_POSTED:-0}" -ne 1 ] && NOTIF_POSTED=0
    NOTIF_SWIPE_OK=0
    NOTIF_STRATEGY=""
    return 1
}

cancel_notif() {
    [ "${NOTIF_POSTED:-0}" -ne 1 ] && return 0
    NOTIF_SELF_CANCELLED=1
    # record cancel stderr for debugging
    cmd notification cancel $NOTIF_CANCEL_USER "$TAG" "$NOTIF_ID" >/dev/null 2> "$LOCK_DIR/cancel_err" || true
    if [ -s "$LOCK_DIR/cancel_err" ]; then
        log_warn "cancel_err: $(sed -n '1p' $LOCK_DIR/cancel_err 2>/dev/null || echo '')"
    else
        [ "$DEBUG" -eq 1 ] && log_debug "cancel_notif: cancel command executed (no stderr)"
    fi
    NOTIF_POSTED=0
}

is_notif_dismissed() {
    [ "${NOTIF_POSTED:-0}" -ne 1 ] && return 1
    [ "${NOTIF_SWIPE_OK:-0}" -ne 1 ] && return 1
    [ "${NOTIF_SELF_CANCELLED:-0}" -eq 1 ] && return 1

    # record dumpsys snippet for debug
    if [ "$DEBUG" -eq 1 ]; then
        dumpsys notification 2>/dev/null | sed -n '1,200p' > "$LOCK_DIR/dumpsys_for_is_notif" 2>/dev/null || true
        log_debug "is_notif_dismissed: dumpsys snapshot saved"
    fi

    if ! dumpsys notification 2>/dev/null | grep -qF "$TAG"; then
        [ "$DEBUG" -eq 1 ] && log_debug "is_notif_dismissed: TAG not found in dumpsys"
        return 0
    fi
    return 1
}

# Timing helpers (calc_countdown from V27.20)
calc_countdown() {
    if [ "$use_uptime" -eq 1 ]; then
        # POSIX-safe read
        read -r _u _ < /proc/uptime 2>/dev/null || true
        if [ -n "${_u:-}" ]; then
            now_uptime=${_u%.*}
            case "$now_uptime" in ''|*[!0-9]*)
                now_uptime=0
                ;;
            esac
        else
            now_uptime=0
        fi

        if [ "$now_uptime" -gt 0 ]; then
            last_good_uptime="$now_uptime"
            last_good_ts=$(date +%s)
            countdown=$(( target_uptime - now_uptime ))
        else
            if [ -n "${last_good_uptime:-}" ] && [ -n "${last_good_ts:-}" ] && [ "$last_good_uptime" -gt 0 ] && [ "$last_good_ts" -gt 0 ]; then
                now_ts=$(date +%s)
                elapsed_since_last=$(( now_ts - last_good_ts ))
                if [ "$elapsed_since_last" -lt 0 ]; then
                    elapsed_since_last=0
                fi
                remaining=$(( target_uptime - last_good_uptime - elapsed_since_last ))
                [ "$remaining" -lt 0 ] && remaining=0
                target_ts=$(( now_ts + remaining ))
                use_uptime=0
                countdown=$remaining
                [ "$DEBUG" -eq 1 ] && log_debug "calc_countdown: uptime 不可用，热切换至 date (remaining=${remaining}s)"
            else
                target_ts=$(( $(date +%s) + THRESHOLD_SEC ))
                use_uptime=0
                countdown=$THRESHOLD_SEC
                [ "$DEBUG" -eq 1 ] && log_debug "calc_countdown: 无可靠 uptime 历史，回退至 date (remaining=${countdown}s)"
            fi
        fi
    else
        countdown=$(( target_ts - $(date +%s) ))
    fi

    if [ "${countdown:-0}" -lt 0 ]; then
        countdown=0
    fi
}

# Initialize uptime anchor (POSIX-safe)
read -r _u _ < /proc/uptime 2>/dev/null || true
if [ -n "${_u:-}" ]; then
    start_uptime=${_u%.*}
    case "$start_uptime" in ''|*[!0-9]*)
        start_uptime=0
        ;;
    esac
else
    start_uptime=0
fi

if [ "$start_uptime" -gt 0 ]; then
    target_uptime=$(( start_uptime + THRESHOLD_SEC ))
    use_uptime=1
    last_good_uptime="$start_uptime"
    last_good_ts=$(date +%s)
    [ "$DEBUG" -eq 1 ] && log_debug "使用 uptime 单调锚点 start_uptime=${start_uptime}"
else
    target_ts=$(( $(date +%s) + THRESHOLD_SEC ))
    use_uptime=0
    last_good_uptime=0
    last_good_ts=0
    [ "$DEBUG" -eq 1 ] && log_debug "无法读取 uptime，回退 date 锚点"
fi

# Initial charging check
if check_charging; then
    log_info "开机检测到正在充电，退出"
    exit 0
fi

INIT_MSG="系统将在 $(format_time "$THRESHOLD_SEC") 后关机。滑动清除此通知即可取消！"
post_notif "$INIT_MSG"

# If posted, verify dumpsys shows it (debug)
if [ "${NOTIF_POSTED:-0}" -eq 1 ] && [ "$DEBUG" -eq 1 ]; then
    sleep 2
    dumpsys notification 2>/dev/null | sed -n '1,200p' > "$LOCK_DIR/post_verify_dumpsys" 2>/dev/null || true
    log_debug "post_notif verify: saved dumpsys to $LOCK_DIR/post_verify_dumpsys"
fi

# Main loop
loop_cnt=0
last_min=-1

while true; do
    calc_countdown

    if [ "$countdown" -le 0 ]; then
        if check_charging; then
            log_info "倒计时归零时检测到充电，取消关机"
            exit 0
        fi
        break
    fi

    if [ "$countdown" -lt "$STEP" ]; then
        sleep_time=$countdown
    else
        sleep_time=$STEP
    fi

    sleep "$sleep_time"

    calc_countdown

    loop_cnt=$((loop_cnt + 1))

    if check_charging; then
        log_info "检测到插入充电器，取消关机"
        exit 0
    fi

    if [ "${NOTIF_SWIPE_OK:-0}" -eq 1 ]; then
        if [ $((loop_cnt % 2)) -eq 0 ] || [ "$countdown" -le 60 ]; then
            if is_notif_dismissed; then
                log_info "用户滑动清除了通知，取消关机"
                exit 0
            fi
        fi
    fi

    cur_min=$((countdown / 60))
    if [ "$countdown" -le 30 ] || [ "$cur_min" -ne "$last_min" ]; then
        post_notif "系统将在 $(format_time "$countdown") 后关机。滑动清除此通知即可取消！"
        last_min=$cur_min
    fi
done

log_info "倒计时结束，执行关机"
# rely on EXIT trap to cancel notification; also attempt explicit cancel for robustness
if [ "${NOTIF_POSTED:-0}" -eq 1 ]; then
    cancel_notif
fi
sync
setprop sys.powerctl shutdown 2>/dev/null || reboot -p
