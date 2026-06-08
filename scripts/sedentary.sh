#!/usr/bin/env bash
# ===========================================================================
# Input:  配置参数（间隔、消息模板）/ 系统时间 / 终端活跃状态 / 状态文件
# Output: 系统通知 / 日志记录 / 状态更新
# Pos:    核心提醒模块之一，被 scheduler 调度或独立 --daemon 运行
# ===========================================================================
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly MODULE="sedentary"

# ── 获取提醒消息（三级递进 + 心流覆盖）──────────────────────

get_message_title() {
    local level="${1:-1}"
    local in_flow="${2:-false}"
    if [[ "$in_flow" == "true" ]]; then
        echo "工作专注中"
        return
    fi
    case $level in
        1) echo "该起身活动了" ;;
        2) echo "久坐提醒" ;;
        3) echo "健康警告" ;;
        *) echo "该起身活动了" ;;
    esac
}

get_message_body() {
    local level="${1:-1}"
    local in_flow="${2:-false}"
    if [[ "$in_flow" == "true" ]]; then
        echo "你已专注约__TOTAL__分钟，完成手头任务后记得起身活动__ACTIVITY__。"
        return
    fi
    case $level in
        1) echo "已经坐了约__INTERVAL__分钟，起来活动一下吧，哪怕一分钟也好。"
           ;;
        2) echo "久坐已超过__INTERVAL__分钟，简单伸展只需20秒，对脊柱很好。"
           ;;
        3) echo "连续久坐超过__TOTAL__分钟，为了健康请立即起身活动2-3分钟。"
           ;;
        *) echo "已经坐了约__INTERVAL__分钟，起来活动一下吧。"
           ;;
    esac
}

get_activity_suggestion() {
    local sitting_minutes="${1:-0}"
    if (( sitting_minutes < 45 )); then
        echo "微中断约20秒：转一转脖子，耸耸肩，活动手腕。"
    elif (( sitting_minutes < 90 )); then
        echo "轻活动约2-3分钟：站起来走一走，踮踮脚尖。"
    elif (( sitting_minutes < 120 )); then
        echo "中活动约5分钟：去接杯水，看窗外远眺，做几组伸展。"
    else
        echo "长活动约10分钟：下楼走走，做眼保健操，全身活动。"
    fi
}

get_activity_duration() {
    local sitting_minutes="${1:-0}"
    if (( sitting_minutes < 45 )); then
        echo "20秒"
    elif (( sitting_minutes < 90 )); then
        echo "2-3分钟"
    elif (( sitting_minutes < 120 )); then
        echo "5分钟"
    else
        echo "10分钟"
    fi
}

# ── 获取累积久坐时长（分钟）─────────────────────────────────

get_sitting_minutes() {
    local start_ts
    start_ts="$(read_state "$MODULE" "session_start_ts")"
    if [[ -z "$start_ts" ]]; then
        start_ts="$(date +%s)"
        write_state "$MODULE" "session_start_ts" "$start_ts"
    fi
    local now_ts
    now_ts="$(date +%s)"
    echo $(( (now_ts - start_ts) / 60 ))
}

# ── 核心提醒逻辑 ────────────────────────────────────────────

do_remind() {
    # 1. 读取配置
    local enabled
    enabled="$(read_config "health-sedentary.enabled" "true")"
    if [[ "$enabled" != "true" ]]; then
        log_message "INFO" "$MODULE" "模块禁用，跳过提醒"
        return 0
    fi

    local interval="30"
    interval="$(read_config "health-sedentary.interval_minutes" "30")"

    local hard_limit="120"
    hard_limit="$(read_config "health-sedentary.hard_limit_minutes" "120")"

    # 2. 参数校验
    if ! echo "$interval" | grep -qE '^[0-9]+$'; then
        log_message "ERROR" "$MODULE" "无效间隔参数: $interval, 使用默认值30"
        interval=30
    fi
    if (( interval < 25 )); then
        interval=25
    elif (( interval > 60 )); then
        interval=60
    fi

    # 3. 免打扰检查
    local dnd_raw
    dnd_raw="$(read_config "health-sedentary.do_not_disturb" "")"
    if [[ -n "$dnd_raw" ]] && is_dnd "$dnd_raw"; then
        log_message "INFO" "$MODULE" "免打扰时段，跳过提醒"
        return 0
    fi

    # 4. 智能抑制检测
    if is_quiet_hours; then
        log_message "INFO" "$MODULE" "深夜静默，跳过提醒"
        return 0
    fi
    # 注：is_screen_locked 在部分 macOS 版本存在误报，暂不启用
    # 用户可通过手动锁定屏幕 + 系统勿扰模式控制通知

    # 5. 心流检测
    local in_flow=false
    local flow_window=5
    flow_window="$(read_config "health-sedentary.flow_window_minutes" "5")"
    if detect_flow "$flow_window"; then
        in_flow=true
    fi

    # 6. 状态读取
    local consecutive_count=0
    consecutive_count="$(read_state "$MODULE" "consecutive_count")"
    consecutive_count="${consecutive_count:-0}"

    local sitting_minutes
    sitting_minutes="$(get_sitting_minutes)"

    # 7. 是否该提醒了？
    local last_ts=0
    last_ts="$(read_state "$MODULE" "last_reminder_ts")"
    last_ts="${last_ts:-0}"

    local now_ts
    now_ts="$(date +%s)"
    local elapsed_since_last=$(( (now_ts - last_ts) / 60 ))

    # 心流状态下适当延后（但不超过硬上限）
    if [[ "$in_flow" == true ]]; then
        if (( sitting_minutes < hard_limit && elapsed_since_last < interval + 10 )); then
            log_message "INFO" "$MODULE" "心流中，延后提醒（已坐${sitting_minutes}分钟）"
            return 0
        fi
    else
        # 未到提醒间隔且未达硬上限
        if (( elapsed_since_last < interval && sitting_minutes < hard_limit )); then
            return 0
        fi
    fi

    # 8. 确定提醒等级（基于过去已发生的提醒次数）
    # 首次 → L1, 已提醒1次仍未响应 → L2, 已提醒>=2次或超硬上限 → L3
    local level=1
    if (( consecutive_count >= 1 && consecutive_count < 2 )); then
        level=2
    fi
    if (( consecutive_count >= 2 || sitting_minutes >= hard_limit )); then
        level=3
    fi

    # 9. 构建消息
    local activity_suggestion
    activity_suggestion="$(get_activity_suggestion "$sitting_minutes")"

    local activity_duration
    activity_duration="$(get_activity_duration "$sitting_minutes")"

    local title
    title="$(get_message_title "$level" "$in_flow")"

    local body
    body="$(get_message_body "$level" "$in_flow")"
    body="${body//__INTERVAL__/$interval}"
    body="${body//__TOTAL__/$sitting_minutes}"
    body="${body//__ACTIVITY__/$activity_duration}"
    body="${body} 建议：${activity_suggestion}"

    # 10. 发送通知
    local sound="Glass"
    if (( level >= 3 )); then
        sound="Basso"
    fi

    send_notification "$title" "$body" "$sound"
    local notify_rc=$?

    # 11. 日志
    log_message "REMINDER" "$MODULE" \
        "L${level} flow=${in_flow} sitting=${sitting_minutes}min consecutive=${consecutive_count} interval=${interval}min notify=${notify_rc}"

    # 12. 终端输出
    printf '[L%d] %s\n' "$level" "$body"

    # 13. 更新状态
    write_state "$MODULE" "last_reminder_ts" "$now_ts"
    write_state "$MODULE" "last_reminder_level" "$level"
    write_state "$MODULE" "consecutive_count" "$((consecutive_count + 1))"
    write_state "$MODULE" "total_sitting_minutes" "$sitting_minutes"
}

# ── 状态查看 ────────────────────────────────────────────────

show_status() {
    local session_start
    session_start="$(read_state "$MODULE" "session_start_ts")"
    local consecutive
    consecutive="$(read_state "$MODULE" "consecutive_count")"
    consecutive="${consecutive:-0}"
    local last_ts
    last_ts="$(read_state "$MODULE" "last_reminder_ts")"
    local last_level
    last_level="$(read_state "$MODULE" "last_reminder_level")"
    local enabled
    enabled="$(read_config "health-sedentary.enabled" "true")"
    local interval
    interval="$(read_config "health-sedentary.interval_minutes" "30")"

    echo "模块: $MODULE"
    echo "启用状态: $enabled"
    echo "提醒间隔: ${interval} 分钟"

    if [[ -n "$session_start" ]]; then
        local now_ts sitting
        now_ts="$(date +%s)"
        sitting=$(( (now_ts - session_start) / 60 ))
        echo "当前久坐: ${sitting} 分钟"
        echo "连续提醒: ${consecutive} 次"
        echo "上次提醒等级: L${last_level:-无}"
        if [[ -n "$last_ts" ]]; then
            echo "上次提醒时间: $(date -r "$last_ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$last_ts")"
        fi
    else
        echo "状态: 尚未初始化"
    fi
}

# ── 重置状态 ────────────────────────────────────────────────

reset_state() {
    local now_ts
    now_ts="$(date +%s)"
    write_state "$MODULE" "session_start_ts" "$now_ts"
    write_state "$MODULE" "consecutive_count" "0"
    write_state "$MODULE" "last_reminder_ts" "0"
    write_state "$MODULE" "last_reminder_level" "0"
    write_state "$MODULE" "total_sitting_minutes" "0"
    log_message "RESPONSE" "$MODULE" "用户手动重置久坐状态"
    echo "久坐计时已重置。记得多活动！"
}

# ── 守护进程模式 ────────────────────────────────────────────

run_daemon() {
    local tick_seconds=10
    tick_seconds="$(read_config "daemon.tick_seconds" "10")"

    _ensure_dir "$LOG_DIR_DEFAULT"
    _ensure_dir "$STATE_DIR_DEFAULT"

    log_info "daemon" "久坐提醒守护启动，检查间隔 ${tick_seconds}s"

    # 信号处理
    trap 'log_info "daemon" "收到终止信号，退出守护"; exit 0' TERM INT

    while true; do
        do_remind
        sleep "$tick_seconds"
    done
}

# ── 命令行入口 ──────────────────────────────────────────────

case "${1:-}" in
    --remind)
        do_remind
        ;;
    --status)
        show_status
        ;;
    --daemon | --daemonize)
        run_daemon
        ;;
    --reset)
        reset_state
        ;;
    --interval=*)
        export VITA_SEDENTARY_INTERVAL_MINUTES="${1#*=}"
        do_remind
        ;;
    *)
        echo "用法: $(basename "$0") <模式>"
        echo "  --remind      立即执行一次提醒检查"
        echo "  --status      查看当前久坐状态"
        echo "  --daemon      进入守护进程模式（循环检查）"
        echo "  --reset       重置久坐计时（起身活动后使用）"
        echo "  --interval=N  临时指定提醒间隔（分钟，25-60）"
        exit 1
        ;;
esac
