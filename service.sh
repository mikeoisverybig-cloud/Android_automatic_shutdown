#!/system/bin/sh

MOD_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -z "$MOD_DIR" ] || [ "$MOD_DIR" = "/" ]; then
    MOD_DIR="/data/adb/modules/my_shutdown_tool"
fi

LOCK_FILE="$MOD_DIR/shutdown_timer.lock"
LOG_FILE="$MOD_DIR/shutdown_timer.log"
CONFIG_FILE="$MOD_DIR/time.txt"

if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    > "$LOG_FILE"
fi

exec >> "$LOG_FILE" 2>&1
echo "=================================================="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === 自动关机服务启动 ==="

cleanup() {
    rm -f "$LOCK_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 服务已结束/退出"
}

if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null; then
        echo "服务已在运行 (PID: $pid)，退出重复实例"
        exit 0
    fi
    rm -f "$LOCK_FILE"
fi

set -o noclobber
if ! echo $$ > "$LOCK_FILE" 2>/dev/null; then
    echo "锁文件写入冲突，退出"
    exit 0
fi
set +o noclobber

trap 'exit 1' INT TERM HUP
trap cleanup EXIT

while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 5
done

wait_cnt=0
while ! service check notification 2>/dev/null | grep -q "found"; do
    sleep 3
    wait_cnt=$((wait_cnt + 1))
    [ "$wait_cnt" -ge 10 ] && break
done
sleep 5

TAG="shutdown_cancel_timer"
NOTIF_ID=0
NOTIF_TITLE="⚠️ 自动关机倒计时"
BATT_SYSFS="/sys/class/power_supply/battery/status"
THRESHOLD_SEC=600

if [ -f "$CONFIG_FILE" ]; then
    parsed_time=$(head -n1 "$CONFIG_FILE" 2>/dev/null | grep -oE '^[0-9]+')
    if [ -n "$parsed_time" ] && [ "$parsed_time" -ge 10 ] && [ "$parsed_time" -le 86400 ]; then
        THRESHOLD_SEC=$parsed_time
        echo "读取配置成功: ${THRESHOLD_SEC} 秒"
    else
        echo "配置时间异常 ($parsed_time)，回退至默认 600 秒"
    fi
else
    echo "未找到 time.txt，使用默认 600 秒"
fi

CMD_NOTIF_EXTRA=""
if cmd notification help 2>&1 | grep -q "\-\-user"; then
    CMD_NOTIF_EXTRA="--user 0"
    echo "通知能力探测：支持 --user 0"
else
    echo "通知能力探测：不支持 --user 0，使用兼容模式"
fi

check_charging() {
    if [ -f "$BATT_SYSFS" ]; then
        status=$(tr -d '[:space:]' < "$BATT_SYSFS" 2>/dev/null)
        case "$status" in
            Charging|Full) return 0 ;;
        esac
    else
        dumpsys battery 2>/dev/null | grep -qE 'status:[[:space:]]*(2|5)([^0-9]|$)' && return 0
    fi
    return 1
}

format_time() {
    s=$1
    m=$((s / 60))
    rs=$((s % 60))
    if [ "$m" -gt 0 ]; then
        if [ "$rs" -eq 0 ]; then
            echo "${m} 分钟"
        else
            echo "${m} 分 ${rs} 秒"
        fi
    else
        echo "${rs} 秒"
    fi
}

NOTIF_EVER_POSTED=0
NOTIF_SELF_CANCELLED=0

post_notif() {
    if cmd notification post $CMD_NOTIF_EXTRA "$TAG" "$NOTIF_ID" "$NOTIF_TITLE" "$1" >/dev/null 2>&1; then
        NOTIF_EVER_POSTED=1
    else
        echo "[WARN] 通知发送失败，取消关机仅支持插入充电器"
    fi
}

cancel_notif() {
    NOTIF_SELF_CANCELLED=1
    cmd notification cancel $CMD_NOTIF_EXTRA "$TAG" "$NOTIF_ID" >/dev/null 2>&1 || true
}

is_notif_dismissed() {
    [ "$NOTIF_SELF_CANCELLED" -eq 1 ] && return 1
    ! dumpsys notification 2>/dev/null | grep -qE "NotificationRecord.*$TAG|tag=$TAG"
}

if check_charging; then
    echo "开机检测到正在充电，终止关机逻辑"
    exit 0
fi

post_notif "系统将在 $(format_time "$THRESHOLD_SEC") 后关机。滑动清除此通知即可取消！"

countdown=$THRESHOLD_SEC
STEP=10
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
        echo "检测到插入充电器，取消关机"
        cancel_notif
        exit 0
    fi

    if [ "$NOTIF_EVER_POSTED" -eq 1 ] && is_notif_dismissed; then
        echo "用户滑动清除了通知，取消关机"
        exit 0
    fi

    if [ "$countdown" -gt 0 ]; then
        cur_min=$((countdown / 60))
        if [ "$countdown" -le 30 ] || [ "$cur_min" -ne "$last_min" ]; then
            post_notif "系统将在 $(format_time "$countdown") 后关机。滑动清除此通知即可取消！"
            last_min=$cur_min
        fi
    fi
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 倒计时结束，执行关机"
cancel_notif

sync
setprop sys.powerctl shutdown 2>/dev/null || reboot -p
