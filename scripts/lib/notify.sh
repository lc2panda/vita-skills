#!/usr/bin/env bash
# Input:  通知标题 / 消息正文 / 声音名称
# Output: 跨平台系统通知（macOS terminal-notifier/osascript, Linux notify-send）
# Pos:    scripts/lib/notify.sh — 由 common.sh 懒加载，提供跨平台通知能力
#
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

# send_notification — 跨平台系统通知
# Usage: send_notification <title> <message> [sound]
# 返回: 0 成功, 1 失败
send_notification() {
    local title="${1:-香草健康}"
    local message="${2:-}"
    local sound="${3:-Glass}"

    # macOS: 优先使用 terminal-notifier，回退到 osascript
    if [[ "$(uname -s)" == "Darwin" ]]; then
        if command -v terminal-notifier &>/dev/null; then
            terminal-notifier \
                -title "$title" \
                -message "$message" \
                -sound "$sound" \
                -timeout 5 \
                2>/dev/null && return 0
        fi
        osascript -e "display notification \"$message\" with title \"$title\" sound name \"$sound\"" 2>/dev/null && return 0
        printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$title" "$message" >&2
        return 1
    fi

    # Linux: notify-send
    if [[ "$(uname -s)" == "Linux" ]]; then
        if command -v notify-send &>/dev/null; then
            notify-send "$title" "$message" --expire-time=5000 2>/dev/null && return 0
        fi
        printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$title" "$message" >&2
        return 1
    fi

    # 未知平台
    printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$title" "$message" >&2
    return 1
}
