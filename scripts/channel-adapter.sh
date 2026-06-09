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

# WeChat (iLink Bot API) 消息推送
channel_wechat() {
    local cred_file="$HOME/.pandacc/channels/wechat/credentials.json"
    local token_file="$HOME/.pandacc/channels/wechat/context-tokens.json"

    if [[ ! -f "$cred_file" ]]; then
        log_info "wechat" "凭证文件不存在，跳过微信通知"
        return 1
    fi

    MODULE="$MODULE" MESSAGE="$MESSAGE" \
    CRED_FILE="$cred_file" TOKEN_FILE="$token_file" \
    python3 -c "
import json, os, sys, urllib.request, random, time

# 读取凭证
with open(os.environ['CRED_FILE']) as f:
    cred = json.load(f)
token = cred.get('token', '')
base_url = cred.get('baseUrl', '')
user_id = cred.get('userId', '')
if not token or not base_url or not user_id:
    sys.exit(10)

# 读取 context_token
context_token = ''
tok_path = os.environ.get('TOKEN_FILE', '')
if tok_path:
    try:
        with open(tok_path) as f:
            tokens = json.load(f)
            context_token = tokens.get(user_id, '')
    except Exception:
        pass

# 组装消息
module = os.environ['MODULE']
message = os.environ['MESSAGE']
wechat_msg = f'\U0001f33f [{module}] {message}'

# 构建请求 body
body = json.dumps({
    'msg': {
        'from_user_id': '',
        'to_user_id': user_id,
        'client_id': f'vita-{int(time.time())}-{random.randint(10000,99999)}',
        'message_type': 2,
        'message_state': 2,
        'item_list': [{'type': 1, 'text_item': {'text': wechat_msg}}],
        'context_token': context_token
    },
    'base_info': {'channel_version': '1.0.0'}
}, ensure_ascii=False).encode('utf-8')

# 构建 Headers
headers = {
    'Content-Type': 'application/json',
    'AuthorizationType': 'ilink_bot_token',
    'Authorization': f'Bearer {token}',
    'X-WECHAT-UIN': str(random.randint(100000000, 999999999)),
    'iLink-App-Id': 'bot',
    'iLink-App-ClientVersion': '131081'
}

# 发送请求
url = f'{base_url}/ilink/bot/sendmessage'
req = urllib.request.Request(url, data=body, headers=headers, method='POST')
try:
    resp = urllib.request.urlopen(req, timeout=10)
    resp_body = json.loads(resp.read().decode('utf-8'))
    code = resp_body.get('code', resp_body.get('errcode', 0))
    if code != 0:
        print(json.dumps(resp_body, ensure_ascii=False))
        sys.exit(20)
    sys.exit(0)
except Exception as e:
    print(str(e))
    sys.exit(30)
" 2>/dev/null

    local rc=$?
    if [[ $rc -eq 0 ]]; then
        log_info "wechat" "微信消息发送成功"
        return 0
    elif [[ $rc -eq 10 ]]; then
        log_info "wechat" "凭证缺失，跳过微信通知"
        return 1
    else
        log_warn "wechat" "微信消息发送失败 (exit=$rc)"
        return 1
    fi
}

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
        tigang)     title="提肛训练"; sound="Glass";;
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
        tigang)     icon="[提]";;
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

    if is_channel_enabled "wechat"; then
        channel_wechat && ((dispatched++)) || true
    fi

    log_info "system" "已分发 $MODULE 提醒到 $dispatched 个 channel"
}

# ── 主入口 ────────────────────────────────────────────────
dispatch
