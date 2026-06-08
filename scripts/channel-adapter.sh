#!/usr/bin/env bash
# Input:  模块名、消息文本、通知风格、抑制策略（由 scheduler.sh 传入）
# Output: 向所有已启用的 channel 分发通知
# Pos:    scripts/channel-adapter.sh — 多通道适配器，分发提醒到桌面通知/终端/TTS/日志

# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ── 参数 ──────────────────────────────────────────────────
MODULE="${1:-unknown}"
MESSAGE="${2:-}"
STYLE="${3:-normal}"        # normal | gentle | subtle
SUPPRESS_POLICY="${4:-}"    # silent | log_only | pause | degrade | bypass

# ── Channel 分发函数 ──────────────────────────────────────

# macOS 桌面通知
channel_desktop() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        return 1
    fi

    local title sound subtitle

    case "$MODULE" in
        sedentary) title="久坐提醒"; sound="Glass";;
        eye-care)  title="护眼提醒"; sound="Glass";;
        hydration) title="喝水提醒"; sound="Glass";;
        kegel)     title="凯格尔训练"; sound="Glass";;
        *)         title="健康提醒"; sound="Glass";;
    esac

    case "$STYLE" in
        subtle) subtitle="温和提醒";;
        gentle) subtitle="渐进提醒";;
        *)      subtitle="";;
    esac

    local cmd="display notification \"$MESSAGE\" with title \"$title\""
    [[ -n "$subtitle" ]] && cmd="$cmd subtitle \"$subtitle\""
    cmd="$cmd sound name \"$sound\""

    osascript -e "$cmd" 2>/dev/null || true
}

# 终端回显
channel_terminal() {
    local icon
    case "$MODULE" in
        sedentary) icon="[椅]";;
        eye-care)  icon="[眼]";;
        hydration) icon="[水]";;
        kegel)     icon="[凯]";;
        *)         icon="[♡]";;
    esac

    local style_color
    case "$STYLE" in
        subtle) style_color="${C_DIM:-}";;
        gentle) style_color="${C_BLUE:-}";;
        *)      style_color="${C_GREEN:-}";;
    esac

    printf "%b%s %s%b\n" "${style_color}" "$icon" "$MESSAGE" "${C_RESET:-}" >&2
}

# TTS 语音 (macOS say 命令)
channel_tts() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        return 1
    fi

    local voice="Ting-Ting"
    [[ "$STYLE" == "subtle" ]] && voice="Mei-Jia"

    say -v "$voice" "$MESSAGE" 2>/dev/null &
}

# 日志记录
channel_log() {
    local module_id="${MODULE// /-}"
    log_message "REMINDER" "$module_id" "[$STYLE] $MESSAGE"
}

# ── 检查 channel 是否启用 ────────────────────────────────

is_channel_enabled() {
    local channel="$1"
    local key="channels.${channel}"
    local val
    val=$(read_config "$key" "true")
    [[ "$val" == "true" ]] && return 0 || return 1
}

# ── 主分发逻辑 ───────────────────────────────────────────

dispatch() {
    # 1. 总是记录到日志
    channel_log

    # 2. 检查抑制策略
    case "$SUPPRESS_POLICY" in
        silent)
            # 静默：只记录，不发通知
            log_info "system" "[抑制=静默] $MODULE: $MESSAGE"
            return 0
            ;;
        pause)
            log_info "system" "[抑制=暂停] $MODULE 提醒已暂停，记录到日志"
            channel_log
            return 0
            ;;
        log_only)
            log_info "system" "[抑制=仅日志] $MODULE: $MESSAGE"
            return 0
            ;;
        degrade)
            # 降级：只用终端回显，不用桌面通知
            if is_channel_enabled "terminal_echo"; then
                channel_terminal
            fi
            return 0
            ;;
    esac

    # 3. 正常分发到所有启用 channel
    local dispatched=0

    if is_channel_enabled "desktop_notification"; then
        channel_desktop && ((dispatched++)) || true
    fi

    if is_channel_enabled "terminal_echo"; then
        channel_terminal && ((dispatched++)) || true
    fi

    if is_channel_enabled "tts"; then
        channel_tts && ((dispatched++)) || true
    fi

    log_info "system" "已分发 $MODULE 提醒到 $dispatched 个 channel"
}

# ── 主入口 ────────────────────────────────────────────────
dispatch
