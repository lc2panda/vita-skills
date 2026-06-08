#!/usr/bin/env bash
# Input:  bash_history 文件 / tty 设备节点 / 系统时钟
# Output: 心流置信度分数 (0.0-1.0 浮点数), "flow"|"non-flow" 状态标签
# Pos:    提醒调度核心依赖 — 所有提醒模块在触发前查询心流状态以决定推迟或降级
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的md。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ── 配置项 ──────────────────────────────────────────────────────
FLOW_WINDOW_MINUTES="${FLOW_WINDOW_MINUTES:-5}"
FLOW_THRESHOLD="${FLOW_THRESHOLD:-0.65}"
FLOW_HIST_FILE="${FLOW_HIST_FILE:-${HISTFILE:-${HOME}/.bash_history}}"

# ── 内部辅助：统计最近 N 分钟内 bash/zsh history 新建条目数 ─────
_count_recent_history_entries() {
    local hist_file="$FLOW_HIST_FILE"

    # 若 bash_history 不存在，尝试 zsh_history
    if [[ ! -f "$hist_file" ]]; then
        hist_file="${HOME}/.zsh_history"
    fi
    if [[ ! -f "$hist_file" ]]; then
        echo "0"
        return 0
    fi

    local now_epoch cutoff_epoch
    now_epoch=$(date +%s)
    cutoff_epoch=$((now_epoch - FLOW_WINDOW_MINUTES * 60))

    local count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        # zsh extended history 格式: ": <epoch>:<elapsed>;<command>"
        if [[ "$line" =~ ^:[[:space:]]*([0-9]+): ]]; then
            local ts="${BASH_REMATCH[1]}"
            if (( ts >= cutoff_epoch )); then
                count=$((count + 1))
            fi
        fi
    done < "$hist_file"

    echo "$count"
}

# ── 内部辅助：获取最近活跃 tty 设备的最后访问距现在的秒数 ──────
_get_tty_idle_seconds() {
    local tty_names
    tty_names=$(who 2>/dev/null | awk '{print $2}' | grep '^tty' || true)
    if [[ -z "$tty_names" ]]; then
        echo "86400"  # 无活跃tty，返回大值
        return 0
    fi

    local newest_mtime=0 now_epoch
    now_epoch=$(date +%s)

    for tty_name in $tty_names; do
        local dev_node="/dev/${tty_name}"
        if [[ -c "$dev_node" ]]; then
            local mtime
            if [[ "$(uname -s)" == "Darwin" ]]; then
                mtime=$(stat -f '%m' "$dev_node" 2>/dev/null || echo "0")
            else
                mtime=$(stat -c '%Y' "$dev_node" 2>/dev/null || echo "0")
            fi
            if (( mtime > newest_mtime )); then
                newest_mtime=$mtime
            fi
        fi
    done

    if (( newest_mtime > 0 )); then
        echo $(( now_epoch - newest_mtime ))
    else
        echo "86400"
    fi
}

# ═══════════════════════════════════════════════════════════════════
# 核心 API
# ═══════════════════════════════════════════════════════════════════

# detect_flow — 执行心流检测，输出置信度分数 (0.0-1.0)
# 检测维度:
#   A) bash_history 条目活跃度 (权重 0.5)
#   B) tty 设备访问时间活跃度 (权重 0.5)
# Usage: score=$(detect_flow)
detect_flow() {
    local hist_count tty_idle

    # 维度 A: history 条目数 → 分数
    hist_count=$(_count_recent_history_entries)
    local hist_score=0.0
    if (( hist_count >= 20 )); then
        hist_score=1.0
    elif (( hist_count >= 10 )); then
        hist_score=0.8
    elif (( hist_count >= 5 )); then
        hist_score=0.6
    elif (( hist_count >= 2 )); then
        hist_score=0.4
    elif (( hist_count >= 1 )); then
        hist_score=0.2
    fi

    # 维度 B: tty 空闲秒数 → 分数
    tty_idle=$(_get_tty_idle_seconds)
    local tty_score=0.0
    if (( tty_idle <= 10 )); then
        tty_score=1.0
    elif (( tty_idle <= 30 )); then
        tty_score=0.9
    elif (( tty_idle <= 60 )); then
        tty_score=0.7
    elif (( tty_idle <= 120 )); then
        tty_score=0.5
    elif (( tty_idle <= 300 )); then
        tty_score=0.3
    elif (( tty_idle <= 600 )); then
        tty_score=0.1
    fi

    # 加权计算
    local flow_score
    flow_score=$(awk -v hs="$hist_score" -v ts="$tty_score" \
        'BEGIN { printf "%.4f", (0.5 * hs) + (0.5 * ts) }')

    log_debug "flow-detector: hist_entries=${hist_count} hist_score=${hist_score} tty_idle=${tty_idle}s tty_score=${tty_score} → flow_score=${flow_score}"

    echo "${flow_score}"
}

# is_in_flow — 判断当前是否处于心流状态
# 返回码: 0 = 心流中, 1 = 非心流
# Usage: if is_in_flow; then ... fi
is_in_flow() {
    local score
    score=$(detect_flow)
    if awk -v s="$score" -v t="$FLOW_THRESHOLD" 'BEGIN { exit (s > t ? 0 : 1) }'; then
        return 0
    fi
    return 1
}

# get_flow_level — 获取心流等级标签
# 输出: "flow" 或 "non-flow"
# Usage: level=$(get_flow_level)
get_flow_level() {
    local score
    score=$(detect_flow)
    if awk -v s="$score" -v t="$FLOW_THRESHOLD" 'BEGIN { exit (s >= t ? 0 : 1) }'; then
        echo "flow"
    else
        echo "non-flow"
    fi
}

# ═══════════════════════════════════════════════════════════════════
# CLI 入口 (直接执行时)
# ═══════════════════════════════════════════════════════════════════
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-detect}" in
        detect)
            detect_flow
            ;;
        is-flow)
            if is_in_flow; then
                echo "true"
            else
                echo "false"
            fi
            ;;
        level)
            get_flow_level
            ;;
        *)
            echo "Usage: $0 {detect|is-flow|level}" >&2
            exit 1
            ;;
    esac
fi
