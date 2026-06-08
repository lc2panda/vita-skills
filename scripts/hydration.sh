#!/usr/bin/env bash
# Input: 配置参数(gender/interval/target) / 系统时间 / 当日饮水状态文件
# Output: 系统通知 / 状态文件更新(~/.vita/state/hydration.state) / 日志记录(~/.vita/logs/)
# Pos: 核心提醒模块之一，被 scheduler(cron/launchd) 调度，也可命令行手动交互
#
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的md。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly MODULE="hydration"

# ── 默认参数 ────────────────────────────────────────────────
DEFAULT_INTERVAL_MINUTES=75
DEFAULT_PER_DRINK_ML=200
DEFAULT_MALE_TARGET_ML=2000
DEFAULT_FEMALE_TARGET_ML=1600
DEFAULT_START_TIME="09:00"
DEFAULT_END_TIME="18:00"

# ── 从配置加载参数（支持 YAML 配置和环境变量覆盖） ────────────
load_config() {
    INTERVAL_MINUTES=$(read_config "hydration.interval_minutes" "${DEFAULT_INTERVAL_MINUTES}")
    PER_DRINK_ML=$(read_config "hydration.per_drink_ml" "${DEFAULT_PER_DRINK_ML}")
    GENDER=$(read_config "hydration.gender" "male")
    DAILY_TARGET_ML=$(read_config "hydration.daily_target_ml" "")
    START_TIME=$(read_config "hydration.start_time" "${DEFAULT_START_TIME}")
    END_TIME=$(read_config "hydration.end_time" "${DEFAULT_END_TIME}")

    # 如果未配置每日目标，根据性别自动设定
    if [[ -z "${DAILY_TARGET_ML}" ]]; then
        case "${GENDER}" in
            female|FEMALE|Female) DAILY_TARGET_ML="${DEFAULT_FEMALE_TARGET_ML}" ;;
            *)                    DAILY_TARGET_ML="${DEFAULT_MALE_TARGET_ML}" ;;
        esac
    fi
}

# ── 工具：获取今日日期字符串 YYYY-MM-DD ─────────────────────
_today() {
    date '+%Y-%m-%d'
}

# ── 工具：获取当前 ISO 时间戳 ───────────────────────────────
_now_iso() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

# ── 工具：计算距今分钟数（兼容 macOS / Linux） ──────────────
_minutes_since() {
    local iso_time="$1"
    if [[ -z "${iso_time}" ]] || [[ "${iso_time}" == "null" ]]; then
        echo "9999"
        return
    fi
    local now_epoch
    local then_epoch
    if [[ "$(uname -s)" == "Darwin" ]]; then
        now_epoch=$(date +%s)
        then_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "${iso_time}" +%s 2>/dev/null || echo $((now_epoch - 9999*60)))
    else
        now_epoch=$(date +%s)
        then_epoch=$(date -d "${iso_time}" +%s 2>/dev/null || echo $((now_epoch - 9999*60)))
    fi
    echo $(( (now_epoch - then_epoch) / 60 ))
}

# ── 工具：计算百分比 ───────────────────────────────────────
_calc_pct() {
    local total="$1"
    local target="$2"
    if [[ "${target}" -le 0 ]]; then
        echo "0"
        return
    fi
    echo $(( total * 100 / target ))
}

# ── 工具：检查是否在活跃时段内 ──────────────────────────────
_is_active_hours() {
    local now_min start_min end_min
    now_min=$(( $(date +%H) * 60 + $(date +%M) ))
    start_min=$(( 10#${START_TIME%%:*} * 60 + 10#${START_TIME##*:} ))
    end_min=$(( 10#${END_TIME%%:*} * 60 + 10#${END_TIME##*:} ))
    [[ ${now_min} -ge ${start_min} ]] && [[ ${now_min} -lt ${end_min} ]]
}

# ── 初始化当日状态（新的一天则重置） ──────────────────────────
_init_daily() {
    local stored_date
    stored_date="$(read_state "${MODULE}" "date" || echo "")"
    local today
    today="$(_today)"

    if [[ -z "${stored_date}" ]] || [[ "${stored_date}" != "${today}" ]]; then
        log_message "INFO" "${MODULE}" "新的一天，重置计数器。日期: ${today} (上次: ${stored_date:-无})"
        local max_drinks
        max_drinks=$((DAILY_TARGET_ML / PER_DRINK_ML))
        write_state "${MODULE}" "date" "${today}"
        write_state "${MODULE}" "total_ml" "0"
        write_state "${MODULE}" "count" "0"
        write_state "${MODULE}" "target_ml" "${DAILY_TARGET_ML}"
        write_state "${MODULE}" "per_drink_ml" "${PER_DRINK_ML}"
        write_state "${MODULE}" "interval_minutes" "${INTERVAL_MINUTES}"
        write_state "${MODULE}" "gender" "${GENDER}"
        write_state "${MODULE}" "max_drinks" "${max_drinks}"
        write_state "${MODULE}" "last_drink_time" ""
        write_state "${MODULE}" "last_reminder_time" ""
        write_state "${MODULE}" "reminders_sent" "0"
        log_message "INFO" "${MODULE}" "日状态已初始化: 目标=${DAILY_TARGET_ML}mL, 单次=${PER_DRINK_ML}mL, 间隔=${INTERVAL_MINUTES}min"
        return 1  # 表示已重置
    fi
    return 0  # 无需重置
}

# ── 读取状态值（带默认值） ───────────────────────────────────
_get_state() {
    local key="$1"
    local default="${2:-}"
    local val
    val="$(read_state "${MODULE}" "$key" || echo "")"
    if [[ -z "${val}" ]]; then
        echo "${default}"
    else
        echo "${val}"
    fi
}

# ── 生成提醒消息 ────────────────────────────────────────────
_generate_msg() {
    local total_ml="$1"
    local target_ml="$2"
    local per_drink="$3"
    local minutes_ago="$4"
    local pct
    pct="$(_calc_pct "${total_ml}" "${target_ml}")"

    if [[ "${pct}" -lt 40 ]]; then
        printf '%s|%s' \
            "⚠️ 饮水严重不足！" \
            "今日饮水仅${total_ml}mL，远低于${target_ml}mL目标！请立即补充水分，脱水1%即影响注意力集中。"
    elif [[ "${pct}" -lt 85 ]]; then
        printf '%s|%s' \
            "💧 该喝水了！" \
            "已喝 ${total_ml}/${target_ml}mL (${pct}%)，再来一杯${per_drink}mL吧～"
    else
        printf '%s|%s' \
            "🥤 补充水分" \
            "距离上次饮水已${minutes_ago}分钟，补充${per_drink}mL水分，保持大脑高效运转！今日进度: ${total_ml}/${target_ml}mL (${pct}%)"
    fi
}

# ── 生成目标达成消息 ────────────────────────────────────────
_generate_complete_msg() {
    local target_ml="$1"
    local count="$2"
    printf '%s|%s' \
        "🎉 目标达成！" \
        "今日已饮水${target_ml}mL（${count}杯）。你的大脑会感谢今天的表现。"
}

# ── 记录饮水动作 ────────────────────────────────────────────
action_drink() {
    local now_iso
    now_iso="$(_now_iso)"
    _init_daily || true

    local total_ml count target_ml per_drink max_drinks
    total_ml="$(_get_state "total_ml" "0")"
    count="$(_get_state "count" "0")"
    target_ml="$(_get_state "target_ml" "${DAILY_TARGET_ML}")"
    per_drink="$(_get_state "per_drink_ml" "${PER_DRINK_ML}")"
    max_drinks="$(_get_state "max_drinks" "10")"

    local new_total new_count
    new_total=$((total_ml + per_drink))
    new_count=$((count + 1))

    write_state "${MODULE}" "total_ml" "${new_total}"
    write_state "${MODULE}" "count" "${new_count}"
    write_state "${MODULE}" "last_drink_time" "${now_iso}"

    local pct
    pct="$(_calc_pct "${new_total}" "${target_ml}")"
    log_message "INFO" "${MODULE}" "饮水记录: +${per_drink}mL, 累计=${new_total}mL (${new_count}/${max_drinks}杯), 进度=${pct}%"

    if [[ "${new_total}" -ge "${target_ml}" ]]; then
        local complete_msg title body
        complete_msg="$(_generate_complete_msg "${target_ml}" "${new_count}")"
        title="${complete_msg%%|*}"
        body="${complete_msg##*|}"
        send_notification "${title}" "${body}" "Glass"
        log_message "INFO" "${MODULE}" "当日目标达成! ${new_total}/${target_ml}mL"
    else
        send_notification "已记录饮水" "已喝 ${new_total}/${target_ml}mL (${pct}%)，继续保持！" "Pop"
    fi

    echo "${new_total} ${new_count} ${pct}"
}

# ── 显示状态 ────────────────────────────────────────────────
action_status() {
    _init_daily || true

    local date total_ml count target_ml per_drink gender interval_min last_drink
    date="$(_get_state "date" "$(_today)")"
    total_ml="$(_get_state "total_ml" "0")"
    count="$(_get_state "count" "0")"
    target_ml="$(_get_state "target_ml" "${DAILY_TARGET_ML}")"
    per_drink="$(_get_state "per_drink_ml" "${PER_DRINK_ML}")"
    gender="$(_get_state "gender" "${GENDER}")"
    interval_min="$(_get_state "interval_minutes" "${INTERVAL_MINUTES}")"
    last_drink="$(_get_state "last_drink_time" "")"

    local pct max_drinks
    pct="$(_calc_pct "${total_ml}" "${target_ml}")"
    max_drinks=$((target_ml / per_drink))

    local since_min
    since_min="$(_minutes_since "${last_drink}")"

    echo "========================================"
    echo "  喝水提醒 — 今日状态"
    echo "========================================"
    echo "  日期:       ${date}"
    echo "  性别设定:   ${gender}"
    echo "  已饮水量:   ${total_ml} / ${target_ml} mL"
    echo "  完成杯数:   ${count} / ${max_drinks} 杯 (${pct}%)"
    echo "  单次目标:   ${per_drink} mL"
    echo "  提醒间隔:   ${interval_min} 分钟"
    if [[ "${since_min}" -lt 9999 ]]; then
        echo "  上次饮水:   ${since_min} 分钟前"
    else
        echo "  上次饮水:   今日尚未记录"
    fi
    echo "========================================"

    # 进度条
    local bar_len=20
    local filled
    filled=$((pct * bar_len / 100))
    [[ "${filled}" -gt "${bar_len}" ]] && filled="${bar_len}"
    local empty=$((bar_len - filled))
    printf "  ["
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "] %d%%\n" "${pct}"

    if [[ "${pct}" -ge 100 ]]; then
        echo ""
        echo "  🎉 今日目标已达成！干得漂亮！"
    elif [[ "${pct}" -lt 40 ]]; then
        echo ""
        echo "  ⚠️ 进度落后，记得及时补水！"
    fi
    echo ""
}

# ── 提醒模式 ────────────────────────────────────────────────
action_remind() {
    # 非活跃时段静默退出
    if ! _is_active_hours; then
        return 0
    fi

    _init_daily || true

    local total_ml target_ml per_drink last_reminder last_drink
    total_ml="$(_get_state "total_ml" "0")"
    target_ml="$(_get_state "target_ml" "${DAILY_TARGET_ML}")"
    per_drink="$(_get_state "per_drink_ml" "${PER_DRINK_ML}")"

    # 已达目标，不再提醒
    if [[ "${total_ml}" -ge "${target_ml}" ]]; then
        log_message "INFO" "${MODULE}" "今日目标已达成(${total_ml}/${target_ml}mL)，跳过提醒"
        return 0
    fi

    # 检查距上次提醒的时间间隔
    last_reminder="$(_get_state "last_reminder_time" "")"
    local min_since_reminder
    min_since_reminder="$(_minutes_since "${last_reminder}")"
    if [[ "${min_since_reminder}" -lt "${INTERVAL_MINUTES}" ]]; then
        return 0
    fi

    # 计算距上次实际饮水的时间（用于消息展示）
    last_drink="$(_get_state "last_drink_time" "")"
    local min_since_drink
    min_since_drink="$(_minutes_since "${last_drink}")"
    if [[ "${min_since_drink}" -ge 9999 ]]; then
        min_since_drink="${min_since_reminder}"
    fi

    # 生成并发送提醒
    local reminder_msg title body
    reminder_msg="$(_generate_msg "${total_ml}" "${target_ml}" "${per_drink}" "${min_since_drink}")"
    title="${reminder_msg%%|*}"
    body="${reminder_msg##*|}"

    send_notification "${title}" "${body}" "Glass"
    log_message "REMINDER" "${MODULE}" "提醒已发送 | 进度=${total_ml}/${target_ml}mL | 距上次提醒=${min_since_reminder}min | 距上次饮水=${min_since_drink}min"

    # 更新提醒时间
    local now_iso reminders
    now_iso="$(_now_iso)"
    reminders="$(_get_state "reminders_sent" "0")"
    reminders=$((reminders + 1))
    write_state "${MODULE}" "last_reminder_time" "${now_iso}"
    write_state "${MODULE}" "reminders_sent" "${reminders}"
}

# ── 守护进程模式 ────────────────────────────────────────────
action_daemon() {
    log_message "INFO" "${MODULE}" "守护进程启动 | 间隔=${INTERVAL_MINUTES}min | 目标=${DAILY_TARGET_ML}mL | 活跃时段=${START_TIME}-${END_TIME}"
    echo "喝水提醒守护进程已启动 (间隔=${INTERVAL_MINUTES}分钟, 活跃时段=${START_TIME}-${END_TIME})"

    while true; do
        action_remind
        sleep 60
    done
}

# ── 重置模式 ────────────────────────────────────────────────
action_reset() {
    local today max_drinks
    today="$(_today)"
    max_drinks=$((DAILY_TARGET_ML / PER_DRINK_ML))
    write_state "${MODULE}" "date" "${today}"
    write_state "${MODULE}" "total_ml" "0"
    write_state "${MODULE}" "count" "0"
    write_state "${MODULE}" "target_ml" "${DAILY_TARGET_ML}"
    write_state "${MODULE}" "per_drink_ml" "${PER_DRINK_ML}"
    write_state "${MODULE}" "interval_minutes" "${INTERVAL_MINUTES}"
    write_state "${MODULE}" "gender" "${GENDER}"
    write_state "${MODULE}" "max_drinks" "${max_drinks}"
    write_state "${MODULE}" "last_drink_time" ""
    write_state "${MODULE}" "last_reminder_time" ""
    write_state "${MODULE}" "reminders_sent" "0"
    log_message "INFO" "${MODULE}" "状态已手动重置"
    echo "喝水计数器已重置。目标: ${DAILY_TARGET_ML}mL, 间隔: ${INTERVAL_MINUTES}分钟"
}

# ── 帮助信息 ────────────────────────────────────────────────
action_help() {
    echo "用法: $(basename "$0") [选项]"
    echo ""
    echo "喝水提醒脚本 — 科学补水追踪"
    echo ""
    echo "选项:"
    echo "  (无参数)      提醒模式：检查是否到时间发送提醒通知"
    echo "  -d, --drink   记录一次饮水（+${PER_DRINK_ML}mL），更新进度"
    echo "  -s, --status  显示当日饮水状态和进度"
    echo "  --daemon      守护进程模式：每分钟检查并自动发送提醒"
    echo "  --reset       强制重置当日计数器"
    echo "  -h, --help    显示此帮助信息"
    echo ""
    echo "配置来源（优先级从高到低）:"
    echo "  1. 环境变量: VITA_HYDRATION_INTERVAL_MINUTES 等"
    echo "  2. YAML 配置: \$VITA_CONFIG_FILE 或 config/default.yaml"
    echo "  3. 脚本内置默认值"
    echo ""
    echo "YAML 配置示例:"
    echo "  hydration:"
    echo "    interval_minutes: 75"
    echo "    per_drink_ml: 200"
    echo "    gender: male"
    echo "    daily_target_ml: 2000       # 不设则自动: male=2000, female=1600"
    echo "    start_time: \"09:00\""
    echo "    end_time: \"18:00\""
    echo ""
    echo "环境变量示例:"
    echo "  export VITA_HYDRATION_INTERVAL_MINUTES=90"
    echo "  export VITA_HYDRATION_GENDER=female"
    echo ""
    echo "状态文件: $(get_state_file "${MODULE}")"
    echo "日志文件: $(get_log_file "${MODULE}")"
}

# ── 主入口 ──────────────────────────────────────────────────
main() {
    load_config

    case "${1:-}" in
        -d|--drink|--log|-l)
            action_drink
            ;;
        -s|--status|status)
            action_status
            ;;
        --daemon|daemon)
            action_daemon
            ;;
        --reset|reset)
            action_reset
            ;;
        -h|--help|help)
            action_help
            ;;
        "")
            action_remind
            ;;
        *)
            echo "未知选项: $1" >&2
            action_help
            exit 1
            ;;
    esac
}

main "$@"
