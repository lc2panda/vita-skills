#!/usr/bin/env bash
# Input:  被 scheduler.sh 调用，读取配置和系统状态
# Output: 输出心流等级 (none|light|medium|deep) 到 stdout
# Pos:    scripts/flow-detector.sh — 心流检测组件，决定提醒强度

# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ── 检测方法 ──────────────────────────────────────────────

# 方法 1: 进程启发式 — 检查是否有高专注应用在前台 (macOS)
detect_by_process() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "none"
        return
    fi

    # 获取前台应用名
    local front_app
    front_app=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || echo "")
    if [[ -z "$front_app" ]]; then
        echo "none"
        return
    fi

    # 从配置读取高专注应用列表
    local high_focus
    high_focus=$(read_config "high_focus_apps" "" 2>/dev/null | sed 's/,/ /g')
    if [[ -z "$high_focus" ]]; then
        # 内置默认列表
        high_focus="Xcode Terminal iTerm2 IntelliJ IDEA VSCode Sublime Text Vim Emacs"
    fi

    # 检查是否匹配
    for app in $high_focus; do
        if [[ "$front_app" == "$app" ]]; then
            # 高专注应用 + CPU 占用判断深度
            local cpu_usage
            cpu_usage=$(ps -eo %cpu,comm 2>/dev/null | grep -i "$app" | awk '{sum+=$1} END {printf "%.0f", sum}') || cpu_usage=0
            if [[ "$cpu_usage" -gt 80 ]]; then
                echo "deep"
            elif [[ "$cpu_usage" -gt 40 ]]; then
                echo "medium"
            else
                echo "light"
            fi
            return
        fi
    done
    echo "none"
}

# 方法 2: 键盘/鼠标活跃度启发式
detect_by_activity() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "none"
        return
    fi

    # 检查最近 30 秒内的键盘事件
    local idle_ms
    idle_ms=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000000); exit}') || idle_ms=0

    if [[ "$idle_ms" -lt 5 ]]; then
        # 持续活跃 <5秒 → 可能是心流
        echo "medium"
    elif [[ "$idle_ms" -lt 30 ]]; then
        echo "light"
    else
        echo "none"
    fi
}

# ── 综合检测 ──────────────────────────────────────────────

detect_flow_level() {
    # 如果配置中禁用心流检测，直接返回 none
    local flow_enabled
    flow_enabled=$(read_config "flow.enabled" "true")
    if [[ "$flow_enabled" != "true" ]]; then
        echo "none"
        return
    fi

    # 先检查是否处于抑制状态（屏幕锁定/深夜/会议）
    if is_screen_locked; then
        echo "none"
        return
    fi

    # 综合多个检测方法
    local process_level activity_level
    process_level=$(detect_by_process)
    activity_level=$(detect_by_activity)

    # 取较高者
    local levels=("none" "light" "medium" "deep")
    local process_idx=0 activity_idx=0 max_idx=0
    for i in "${!levels[@]}"; do
        [[ "${levels[$i]}" == "$process_level" ]] && process_idx=$i
        [[ "${levels[$i]}" == "$activity_level" ]] && activity_idx=$i
    done
    max_idx=$(( process_idx > activity_idx ? process_idx : activity_idx ))
    echo "${levels[$max_idx]}"
}

# ── 根据心流等级获取延迟倍率 ──────────────────────────────

get_flow_multiplier() {
    local level="${1:-none}"
    case "$level" in
        deep)    echo "4.0" ;;
        medium)  echo "2.5" ;;
        light)   echo "1.5" ;;
        *)       echo "1.0" ;;
    esac
}

# ── 根据心流等级获取通知风格 ──────────────────────────────

get_flow_style() {
    local level="${1:-none}"
    case "$level" in
        deep)    echo "subtle" ;;
        medium)  echo "gentle" ;;
        *)       echo "normal" ;;
    esac
}

# ── 主入口：直接调用时输出当前心流等级 ────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    detect_flow_level
fi
