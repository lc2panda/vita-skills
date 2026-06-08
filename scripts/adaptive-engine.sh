#!/usr/bin/env bash
# Input:  模块名、响应行为 (completed|dismissed|snoozed) — 可选
# Output: 更新忠诚度评分到 state 文件；输出 score/tier/multiplier 到 stdout
# Pos:    scripts/adaptive-engine.sh — 自适应引擎，根据用户响应调整提醒频率

# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

ACTION="${1:-}"
MODULE="${2:-system}"

# ── 评分存取 ─────────────────────────────────────────────

get_score() {
    local s
    s=$(read_state "adaptive_score" "50")
    printf '%d' "$s" 2>/dev/null || echo "50"
}

set_score() {
    local new="$1"
    [[ "$new" -lt 0 ]] && new=0
    [[ "$new" -gt 100 ]] && new=100
    write_state "adaptive_score" "$new"
    printf '%d' "$new"
}

# ── 计分规则 ─────────────────────────────────────────────

apply_points() {
    local action="$1"
    local current
    current=$(get_score)
    local pts
    case "$action" in
        completed) pts=$(read_config "adaptive.points.completed" "10") ;;
        dismissed) pts=$(read_config "adaptive.points.dismissed" "-5") ;;
        snoozed)   pts=$(read_config "adaptive.points.snoozed" "-3") ;;
        *)         pts=0 ;;
    esac
    local new_score=$(( current + pts ))
    set_score "$new_score"
}

# ── 间隔倍率 ─────────────────────────────────────────────

get_interval_multiplier() {
    local s
    s=$(get_score)
    if   [[ "$s" -lt 30 ]]; then echo "1.5"
    elif [[ "$s" -lt 60 ]]; then echo "1.0"
    elif [[ "$s" -lt 80 ]]; then echo "0.8"
    else                      echo "0.6"
    fi
}

# ── 评分等级描述 ─────────────────────────────────────────

get_score_tier() {
    local s
    s=$(get_score)
    if   [[ "$s" -lt 30 ]]; then echo "iron"
    elif [[ "$s" -lt 60 ]]; then echo "bronze"
    elif [[ "$s" -lt 80 ]]; then echo "silver"
    elif [[ "$s" -lt 95 ]]; then echo "gold"
    else                      echo "diamond"
    fi
}

# ── 今日统计 ─────────────────────────────────────────────

get_today_stats() {
    local dk
    dk=$(date '+%Y%m%d')
    local c d s
    c=$(read_state "stats_${dk}_completed" "0")
    d=$(read_state "stats_${dk}_dismissed" "0")
    s=$(read_state "stats_${dk}_snoozed" "0")
    printf 'completed=%d dismissed=%d snoozed=%d' "$c" "$d" "$s"
}

update_today_stats() {
    local action="$1"
    local dk
    dk=$(date '+%Y%m%d')
    case "$action" in
        completed)
            local val; val=$(read_state "stats_${dk}_completed" "0")
            write_state "stats_${dk}_completed" "$(( val + 1 ))"
            ;;
        dismissed)
            local val; val=$(read_state "stats_${dk}_dismissed" "0")
            write_state "stats_${dk}_dismissed" "$(( val + 1 ))"
            ;;
        snoozed)
            local val; val=$(read_state "stats_${dk}_snoozed" "0")
            write_state "stats_${dk}_snoozed" "$(( val + 1 ))"
            ;;
    esac
}

# ── 输出格式 ─────────────────────────────────────────────

print_status_line() {
    local sc ti mu st
    sc=$(get_score)
    ti=$(get_score_tier)
    mu=$(get_interval_multiplier)
    st=$(get_today_stats)
    printf 'score=%d tier=%s multiplier=%s %s\n' "$sc" "$ti" "$mu" "$st"
}

# ── 主入口 ───────────────────────────────────────────────

case "$ACTION" in
    "")
        get_score
        ;;
    completed|dismissed|snoozed)
        update_today_stats "$ACTION"
        apply_points "$ACTION"
        print_status_line
        ;;
    status)
        print_status_line
        ;;
    reset)
        set_score "$(read_config "adaptive.initial_score" "50")"
        log_message "INFO" "system" "自适应评分已重置"
        ;;
    *)
        log_message "ERROR" "system" "无效操作: $ACTION (可用: completed|dismissed|snoozed|status|reset)"
        exit 1
        ;;
esac
