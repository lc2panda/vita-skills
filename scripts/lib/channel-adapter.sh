#!/usr/bin/env bash
# Input:  通知标题 (title) / 消息正文 (message) / 目标渠道 (channel: terminal|webhook)
# Output: 系统通知弹窗 或 webhook HTTP JSON POST 请求 + 降级回退终端通知
# Pos:    所有提醒模块的统一通知出口 — 解耦消息渠道与内容生产
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的md。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ── 配置项 ──────────────────────────────────────────────────────
CHANNEL_WEBHOOK_URL="${CHANNEL_WEBHOOK_URL:-${WEBHOOK_URL:-}}"
CHANNEL_MAX_LENGTH="${CHANNEL_MAX_LENGTH:-120}"
CHANNEL_SOURCE_ID="${CHANNEL_SOURCE_ID:-vanilla-health}"

# ── 消息格式化 ──────────────────────────────────────────────────
# 截断消息到指定长度并追加来源标识
_format_message() {
    local msg="$1"
    local max_len="${2:-${CHANNEL_MAX_LENGTH}}"
    local source_id="${3:-${CHANNEL_SOURCE_ID}}"

    if [[ ${#msg} -gt ${max_len} ]]; then
        msg="$(printf '%s' "$msg" | cut -c1-${max_len})..."
    fi
    printf '%s [%s]' "$msg" "$source_id"
}

# ── 渠道: terminal ──────────────────────────────────────────────
# macOS: osascript display notification
# Linux: notify-send
# 回退: 纯文本输出到 stderr
_channel_terminal_send() {
    local title="$1"
    local message="$2"
    local formatted
    formatted="$(_format_message "$message")"

    if [[ "$(uname -s)" == "Darwin" ]]; then
        if osascript -e "display notification \"${formatted}\" with title \"${title}\"" 2>/dev/null; then
            log_debug "channel-adapter: terminal (osascript) OK | title='${title}'"
            return 0
        fi
    elif [[ "$(uname -s)" == "Linux" ]]; then
        if command -v notify-send &>/dev/null; then
            if notify-send "${title}" "${formatted}" --expire-time=5000 2>/dev/null; then
                log_debug "channel-adapter: terminal (notify-send) OK | title='${title}'"
                return 0
            fi
        fi
    fi

    # 回退：纯文本 stderr 输出
    printf '[%s] [NOTIFY] %s: %s\n' "$(get_timestamp)" "${title}" "${formatted}" >&2
    return 1
}

# ── 渠道: webhook ───────────────────────────────────────────────
# 发送 JSON POST 到配置的 webhook URL
# 返回码: 0=成功, 1=HTTP错误, 2=未配置URL
_channel_webhook_send() {
    local title="$1"
    local message="$2"
    local webhook_url="${3:-${CHANNEL_WEBHOOK_URL}}"

    if [[ -z "$webhook_url" ]]; then
        log_warn "channel-adapter" "webhook URL not configured, cannot send"
        return 2
    fi

    local formatted ts payload http_code
    formatted="$(_format_message "$message")"
    ts="$(get_timestamp)"

    # 构造 JSON payload
    payload="{\"title\":\"${title}\",\"message\":\"${formatted}\",\"source\":\"${CHANNEL_SOURCE_ID}\",\"timestamp\":\"${ts}\"}"

    http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        -X POST "${webhook_url}" \
        -H 'Content-Type: application/json' \
        -d "${payload}" \
        --connect-timeout 5 \
        --max-time 10 2>/dev/null || echo "000")

    log_debug "channel-adapter: webhook POST → ${webhook_url} HTTP ${http_code}"

    case "$http_code" in
        200|201|202|204) return 0 ;;
        *)               return 1 ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════
# 核心 API
# ═══════════════════════════════════════════════════════════════════

# send_notification — 多渠道通知分发
# 渠道:
#   terminal  — 直接系统通知 (osascript / notify-send)
#   webhook   — JSON POST 到 webhook URL; 失败自动降级到 terminal
# Usage:
#   send_notification "提醒" "该休息了" "terminal"
#   send_notification "提醒" "该休息了" "webhook"
send_notification() {
    local title="${1:-vanilla-health}"
    local message="${2:-}"
    local channel="${3:-terminal}"

    local rc=0

    case "$channel" in
        terminal)
            _channel_terminal_send "$title" "$message" || rc=$?
            log_info "channel-adapter" "channel=terminal | title='${title}' rc=${rc}"
            return $rc
            ;;
        webhook)
            _channel_webhook_send "$title" "$message" || rc=$?
            if [[ $rc -ne 0 ]]; then
                log_warn "channel-adapter" "webhook failed (rc=${rc}), falling back to terminal"
                rc=0
                _channel_terminal_send "$title" "$message" || rc=$?
            fi
            log_info "channel-adapter" "channel=webhook+fallback | title='${title}' rc=${rc}"
            return $rc
            ;;
        *)
            log_error "channel-adapter" "unknown channel '${channel}', falling back to terminal"
            _channel_terminal_send "$title" "$message" || rc=$?
            return $rc
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════
# CLI 入口 (直接执行时)
# ═══════════════════════════════════════════════════════════════════
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    TITLE="${1:-vanilla-health}"
    MESSAGE="${2:-}"
    CHANNEL="${3:-terminal}"
    send_notification "$TITLE" "$MESSAGE" "$CHANNEL"
fi
