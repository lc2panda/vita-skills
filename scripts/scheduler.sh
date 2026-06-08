#!/usr/bin/env bash
# Input:  由 vita CLI 的 start 命令启动，读取 config/default.yaml
# Output: 后台守护进程 — 独立计时器管理四大模块提醒，联动心流检测/频道适配/自适应引擎
# Pos:    scripts/scheduler.sh — 核心调度守护，vita 系统的运行时引擎

# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ── 子脚本路径 ───────────────────────────────────────────
FLOW_DETECTOR="$SCRIPT_DIR/flow-detector.sh"
CHANNEL_ADAPTER="$SCRIPT_DIR/channel-adapter.sh"
ADAPTIVE_ENGINE="$SCRIPT_DIR/adaptive-engine.sh"

# ── 全局状态文件 ─────────────────────────────────────────
STATE_RUNNING="$STATE_DIR_DEFAULT/scheduler_running"
STATE_LAST_TRIGGER="$STATE_DIR_DEFAULT/last_trigger"

# ── 日志 ─────────────────────────────────────────────────
SCHEDULER_LOG="$LOG_DIR_DEFAULT/scheduler.log"

# ── 确保所需目录存在 ─────────────────────────────────────
_ensure_dir "$STATE_DIR_DEFAULT"
_ensure_dir "$LOG_DIR_DEFAULT"

# ── 读取模块配置 ─────────────────────────────────────────

read_module_enabled() {
    local module="$1"
    local val
    # 兼容两种 key 格式: health-sedentary.enabled 和 modules.sedentary.enabled
    val=$(read_config "health-${module}.enabled" "")
    if [[ -z "$val" ]]; then
        val=$(read_config "modules.${module}.enabled" "true")
    fi
    [[ "$val" == "true" ]] && return 0 || return 1
}

read_module_interval() {
    local module="$1"
    local default="$2"
    local val
    val=$(read_config "health-${module}.interval_minutes" "")
    if [[ -z "$val" ]]; then
        val=$(read_config "modules.${module}.interval_minutes" "$default")
    fi
    echo "${val:-$default}"
}

read_module_schedule() {
    local module="$1"
    if [[ "$module" != "kegel" ]]; then
        echo ""
        return
    fi

    # 从配置读取 reminders_per_day，默认 3 次
    local per_day
    per_day=$(read_config "health-${module}.reminders_per_day" "3")
    per_day=${per_day:-3}

    case "$per_day" in
        2) echo "10:00 16:00" ;;
        3) echo "09:00 14:00 20:00" ;;
        *) echo "09:00 14:00 20:00" ;;
    esac
}

# ── 获取模块上次触发时间 ─────────────────────────────────

get_last_trigger() {
    local module="$1"
    read_state "last_trigger_${module}" "0"
}

set_last_trigger() {
    local module="$1"
    write_state "last_trigger_${module}" "$(date +%s)"
}

# ── 获取当前有效的抑制策略 ────────────────────────────────

get_suppression_policy() {
    # 按优先级检查抑制规则
    # 返回: 策略名 或空字符串(不抑制)

    # 1. 用户空闲 (暂停)
    local idle_enabled
    idle_enabled=$(read_config "suppression.user_idle.enabled" "true")
    if [[ "$idle_enabled" == "true" ]] && is_user_idle; then
        echo "pause"
        return
    fi

    # 2. 屏幕锁定 (暂停)
    local lock_enabled
    lock_enabled=$(read_config "suppression.screen_locked.enabled" "true")
    if [[ "$lock_enabled" == "true" ]] && is_screen_locked; then
        echo "pause"
        return
    fi

    # 3. 会议模式 (静默)
    local meeting_enabled
    meeting_enabled=$(read_config "suppression.meeting.enabled" "true")
    if [[ "$meeting_enabled" == "true" ]] && is_in_meeting; then
        echo "silent"
        return
    fi

    # 4. 深夜静默 (仅日志)
    local quiet_enabled
    quiet_enabled=$(read_config "suppression.quiet_hours.enabled" "true")
    if [[ "$quiet_enabled" == "true" ]] && is_quiet_hours; then
        echo "log_only"
        return
    fi

    # 无抑制
    echo ""
}

# ── 获取有效间隔（考虑心流和自适应） ───────────────────────

get_effective_interval() {
    local module="$1"
    local base_interval="$2"

    # 如果模块有固定时间调度（kegel），不适用间隔计算
    if [[ "$module" == "kegel" ]]; then
        echo "$base_interval"
        return
    fi

    # 1. 获取自适应引擎的间隔倍率
    local adaptive_multiplier
    adaptive_multiplier=$(bash "$ADAPTIVE_ENGINE" 2>/dev/null |
        awk -F'=' '/multiplier/ {print $NF}' 2>/dev/null) || adaptive_multiplier="1.0"

    # 2. 获取心流倍率
    local flow_level
    flow_level=$(bash "$FLOW_DETECTOR" 2>/dev/null | tail -1) || flow_level="none"
    local flow_multiplier
    flow_multiplier=$(source "$FLOW_DETECTOR" >/dev/null 2>&1 && get_flow_multiplier "$flow_level" 2>/dev/null) || flow_multiplier="1.0"

    # 3. 计算有效间隔 = 基础间隔 * 自适应倍率 * 心流倍率
    local effective
    effective=$(awk "BEGIN { printf \"%.0f\", $base_interval * $adaptive_multiplier * $flow_multiplier }" 2>/dev/null) || effective="$base_interval"

    # 4. 钳制到模块最小/最大值
    local min_int max_int
    min_int=$(read_config "health-${module}.interval_minutes" "20")
    # min_interval 可能在 modules 节
    if [[ "$min_int" == "" ]]; then
        min_int=$(read_config "modules.${module}.interval_minutes" "20")
    fi

    if [[ "$effective" -lt "$min_int" ]]; then effective="$min_int"; fi
    if [[ "$effective" -gt 120 ]]; then effective=120; fi

    printf '%d' "$effective"
}

# ── 获取随机消息 ─────────────────────────────────────────

get_random_message() {
    local module="$1"
    # 从模块配置获取消息模板列表，或使用内置默认
    case "$module" in
        sedentary)
            local msgs=(
                "久坐超过 30 分钟了，起来走走吧，Comdr。"
                "该活动一下了，站起来伸展一下。"
                "坐久了不利于脊椎，起来活动 2 分钟吧。"
            )
            ;;
        eye-care)
            local msgs=(
                "眼睛该休息了，试试 20-20-20 法则。"
                "闭眼休息 20 秒，看远处 20 英尺。"
                "眨眼几次，放松眼部肌肉。"
            )
            ;;
        hydration)
            local msgs=(
                "该喝水了，保持水分充足。"
                "喝杯水吧，目标每天 2L。"
                "补充水分时间到，去接杯水。"
            )
            ;;
        kegel)
            local msgs=(
                "凯格尔时间到，专注盆底肌收缩训练。"
                "给盆底肌做个锻炼吧，坚持 10 秒 x 10 组。"
                "凯格尔提醒：收紧、保持、放松。"
            )
            ;;
        *)
            local msgs=("健康提醒。")
            ;;
    esac
    local idx=$(( RANDOM % ${#msgs[@]} ))
    echo "${msgs[$idx]}"
}

# ── 触发单个模块提醒 ─────────────────────────────────────

trigger_module() {
    local module="$1"
    local module_label="$2"

    # 检查模块是否启用
    if ! read_module_enabled "$module"; then
        log_message "INFO" "system" "[模块禁用] $module_label"
        return
    fi

    # 检查抑制策略
    local suppression
    suppression=$(get_suppression_policy)

    # 获取消息和心流风格
    local message
    message=$(get_random_message "$module")

    local flow_style
    flow_style=$(bash "$FLOW_DETECTOR" 2>/dev/null | tail -1 |
        while read -r level; do
            source "$FLOW_DETECTOR" >/dev/null 2>&1 || true
            get_flow_style "${level:-none}"
        done) || flow_style="normal"

    # 如果抑制策略是 log_only，更新最后触发时间但不更新间隔
    # 这样醒来后会在之前的时间点基础上继续
    if [[ "$suppression" == "log_only" || "$suppression" == "pause" ]]; then
        bash "$CHANNEL_ADAPTER" "$module_label" "$message" "$flow_style" "$suppression"
        # 不更新 last_trigger，以便恢复后立即检查
        return 0
    fi

    # 正常触发：通过 channel-adapter 分发
    bash "$CHANNEL_ADAPTER" "$module_label" "$message" "$flow_style" "$suppression"
    set_last_trigger "$module"

    # 记录到调度日志
    log_message "TRIGGER" "$module" "$message"
}

# ── 检查 kegel 固定时间是否命中 ──────────────────────────

check_kegel_schedule() {
    local current_time
    current_time=$(date +%H:%M)

    local schedule
    schedule=$(read_module_schedule "kegel")

    for sched_time in $schedule; do
        if [[ "$current_time" == "$sched_time" ]]; then
            # 检查今天是否已触发
            local today_key
            today_key="kegel_$(date +%Y%m%d)_${sched_time//:/}"
            local triggered
            triggered=$(read_state "$today_key" "0")
            if [[ "$triggered" == "0" ]]; then
                trigger_module "kegel" "凯格尔训练"
                write_state "$today_key" "1"
            fi
        fi
    done
}

# ── 检查并触发基于间隔的模块 ────────────────────────────

check_interval_module() {
    local module="$1"
    local label="$2"
    local base_interval="$3"

    # kegel 不使用间隔触发，由 schedule 处理
    if [[ "$module" == "kegel" ]]; then
        return
    fi

    local last_trigger
    last_trigger=$(get_last_trigger "$module")
    local now; now=$(date +%s)

    local effective_interval
    effective_interval=$(get_effective_interval "$module" "$base_interval")

    local elapsed_minutes=$(( (now - last_trigger) / 60 ))

    if [[ "$elapsed_minutes" -ge "$effective_interval" ]]; then
        trigger_module "$module" "$label"
    fi
}

# ── 崩溃恢复 ─────────────────────────────────────────────

mark_running() {
    echo $$ > "$STATE_RUNNING"
}

clear_running() {
    rm -f "$STATE_RUNNING"
}

# ── 主循环 ───────────────────────────────────────────────

run_scheduler() {
    log_message "INFO" "system" "Vita 调度器启动 (PID: $$)"

    # 标记运行中
    mark_running

    # 获取各模块基础间隔
    local sed_interval;  sed_interval=$(read_module_interval "sedentary" "30")
    local eye_interval;  eye_interval=$(read_module_interval "eye-care" "50")
    local hyd_interval;  hyd_interval=$(read_module_interval "hydration" "75")
    # kegel 使用 schedule，不设间隔

    local tick
    tick=$(read_config "daemon.tick_seconds" "10")

    # 主循环
    while true; do
        # 检查抑制状态（暂停时跳过间隔检查）
        local suppression
        suppression=$(get_suppression_policy)

        if [[ "$suppression" != "pause" ]]; then
            # 检查基于间隔的模块
            check_interval_module "sedentary" "久坐提醒" "$sed_interval"
            check_interval_module "eye-care" "护眼提醒" "$eye_interval"
            check_interval_module "hydration" "喝水提醒" "$hyd_interval"
        else
            log_message "DEBUG" "system" "调度器暂停 (抑制策略: $suppression)"
        fi

        # 检查固定时间的 kegel
        check_kegel_schedule

        # 等待
        sleep "$tick"
    done
}

# ── 单次模式（用于测试或手动触发） ──────────────────────

run_once() {
    log_message "INFO" "system" "Vita 调度器单次运行"

    local sed_interval;  sed_interval=$(read_module_interval "sedentary" "30")
    local eye_interval;  eye_interval=$(read_module_interval "eye-care" "50")
    local hyd_interval;  hyd_interval=$(read_module_interval "hydration" "75")

    check_interval_module "sedentary" "久坐提醒" "$sed_interval"
    check_interval_module "eye-care" "护眼提醒" "$eye_interval"
    check_interval_module "hydration" "喝水提醒" "$hyd_interval"
    check_kegel_schedule

    log_message "INFO" "system" "单次调度完成"
}

# ── 入口 ─────────────────────────────────────────────────

main() {
    local mode="${1:-daemon}"

    case "$mode" in
        daemon)
            # 获取锁
            if ! acquire_lock; then
                exit 1
            fi
            # 信号处理
            setup_signal_handlers "clear_running"
            # 进入主循环
            run_scheduler
            ;;
        once)
            run_once
            ;;
        *)
            echo "用法: $0 {daemon|once}"
            exit 1
            ;;
    esac
}

main "${1:-daemon}"
