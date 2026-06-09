#!/usr/bin/env bash
# Input:  打榜API地址 / 用户凭据 / 打卡数据
# Output: API响应 / 本地缓存文件 / 离线队列
# Pos:    scripts/lib/leaderboard-client.sh — 打榜PK系统客户端库，被tigang.sh/install.sh引用
#
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

# 不可独立执行，需被 source 引入
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "[FATAL] leaderboard-client.sh 是一个库，不可直接执行。请通过 tigang.sh 或 install.sh 调用。" >&2
    exit 1
fi

# ── 常量 ────────────────────────────────────────────────────
readonly LB_STATE_DIR="${HOME}/.vita/state"
readonly LB_STATE_FILE="${LB_STATE_DIR}/leaderboard.json"
readonly LB_OFFLINE_FILE="${LB_STATE_DIR}/leaderboard-pending.json"
readonly LB_API_TIMEOUT=10
readonly LB_API_CONNECT_TIMEOUT=5

# HMAC-SHA256 共享密钥（需与服务端一致）
readonly SHARED_SECRET="${VITA_HMAC_SECRET:-vita-health-hmac-secret-2026}"

# ── 目录确保 ────────────────────────────────────────────────
_lb_ensure_dir() {
    mkdir -p "$LB_STATE_DIR" 2>/dev/null || true
}

# ── API基地址 ────────────────────────────────────────────────
_lb_api_base() {
    local url="${VITA_LEADERBOARD_URL:-}"
    if [[ -z "$url" ]]; then
        # 尝试从配置文件读取
        if declare -f read_config >/dev/null 2>&1; then
            url="$(read_config "health-leaderboard.api_base_url" "")"
        fi
    fi
    if [[ -z "$url" ]]; then
        url="https://vita-leaderboard.imladrisel.workers.dev"
    fi
    # 去除尾部斜杠
    echo "${url%/}"
}

# ── JSON工具（无jq依赖）─────────────────────────────────────

_lb_json_get_str() {
    local json="$1" key="$2"
    echo "$json" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null \
        | head -1 | sed 's/.*"'"${key}"'"[[:space:]]*:[[:space:]]*"//; s/"$//'
}

_lb_json_get_int() {
    local json="$1" key="$2"
    echo "$json" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[0-9]*" 2>/dev/null \
        | head -1 | sed 's/.*"'"${key}"'"[[:space:]]*:[[:space:]]*//'
}

_lb_json_get_bool() {
    local json="$1" key="$2"
    echo "$json" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\(true\|false\)" 2>/dev/null \
        | head -1 | sed 's/.*"'"${key}"'"[[:space:]]*:[[:space:]]*//'
}

# ── 本地状态读写 ───────────────────────────────────────────

_lb_load_state() {
    _lb_ensure_dir
    if [[ -f "$LB_STATE_FILE" ]]; then
        cat "$LB_STATE_FILE"
    else
        echo '{"user_id":"","display_name":"","registered":false,"privacy_mode":false,"last_sync":""}'
    fi
}

_lb_save_state() {
    _lb_ensure_dir
    echo "$1" > "$LB_STATE_FILE"
}

# ── 离线队列管理 ───────────────────────────────────────────

_lb_load_pending() {
    if [[ -f "$LB_OFFLINE_FILE" ]]; then
        cat "$LB_OFFLINE_FILE"
    else
        echo '[]'
    fi
}

_lb_save_pending() {
    echo "$1" > "$LB_OFFLINE_FILE"
}

_lb_add_pending() {
    local user_id="$1" sets="$2" reps="$3" hold="$4"
    local pending
    pending="$(_lb_load_pending)"
    local now; now="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    local entry="{\"user_id\":\"${user_id}\",\"sets_completed\":${sets},\"reps_per_set\":${reps},\"hold_seconds\":${hold},\"device_id\":\"$(uname -n)\",\"queued_at\":\"${now}\"}"
    if [[ "$pending" == "[]" ]]; then
        pending="[${entry}]"
    else
        pending="${pending%\]},${entry}]"
    fi
    _lb_save_pending "$pending"
}

_lb_flush_pending() {
    local pending="[]"
    if [[ -f "$LB_OFFLINE_FILE" ]]; then
        pending="$(cat "$LB_OFFLINE_FILE")"
    fi
    if [[ "$pending" == "[]" ]]; then
        return 0
    fi

    local flushed=0
    local remaining="["
    local first=true

    # 解析每条待发记录并重试
    while IFS= read -r entry; do
        entry="${entry#,}"
        entry="${entry%\}*}"
        [[ -z "$entry" ]] && continue

        local uid sets reps hold
        uid="$(_lb_json_get_str "{$entry}" "user_id")"
        sets="$(_lb_json_get_int "{$entry}" "sets_completed")"
        reps="$(_lb_json_get_int "{$entry}" "reps_per_set")"
        hold="$(_lb_json_get_int "{$entry}" "hold_seconds")"

        if lb_checkin "$uid" "$sets" "$reps" "$hold" 2>/dev/null; then
            flushed=$((flushed + 1))
        else
            if [[ "$first" != true ]]; then
                remaining="${remaining},"
            fi
            remaining="${remaining}{${entry}}"
            first=false
        fi
    done < <(echo "$pending" | tr '{' '\n' | grep -v '^\[' | grep -v '^$')

    remaining="${remaining}]"
    # 简化的重置逻辑：如果全部消费或队列异常则重置为空
    if [[ "$flushed" -gt 0 ]] && [[ "$remaining" == "[]" ]]; then
        _lb_save_pending '[]'
    elif [[ "$remaining" != "$pending" ]]; then
        # 有部分消费，更新队列
        _lb_save_pending "$remaining"
    fi
}

# ── API调用基础函数 ────────────────────────────────────────

_lb_curl_get() {
    local path="$1"
    local api_base
    api_base="$(_lb_api_base)"
    curl -s -w "\n%{http_code}" \
        --connect-timeout "$LB_API_CONNECT_TIMEOUT" \
        --max-time "$LB_API_TIMEOUT" \
        "${api_base}${path}" 2>/dev/null || echo -e "\n000"
}

_lb_curl_post() {
    local path="$1" data="$2" token="${3:-}" hmac="${4:-}"
    local api_base
    api_base="$(_lb_api_base)"
    local curl_args=(-s -w "\n%{http_code}" -X POST -H "Content-Type: application/json")
    if [[ -n "$token" ]]; then
        curl_args+=(-H "Authorization: Bearer ${token}")
    fi
    if [[ -n "$hmac" ]]; then
        # HMAC header 格式: "timestamp:signature"
        local hmac_ts="${hmac%%:*}"
        local hmac_sig="${hmac##*:}"
        curl_args+=(-H "X-Timestamp: ${hmac_ts}" -H "X-Signature: ${hmac_sig}")
    fi
    curl_args+=(--connect-timeout "$LB_API_CONNECT_TIMEOUT" --max-time "$LB_API_TIMEOUT" -d "$data" "${api_base}${path}")
    curl "${curl_args[@]}" 2>/dev/null || echo -e "\n000"
}

# ── HMAC-SHA256 签名生成 ─────────────────────────────────────
# 客户端签名: hex(HMAC-SHA256(secret, "timestamp:method:path:body"))
# 输出: timestamp:signature (以冒号分隔)
_lb_hmac_sign() {
    local method="$1" path="$2" body="$3"
    local timestamp
    timestamp="$(date +%s)"
    local payload="${timestamp}:${method}:${path}:${body}"
    local sig
    sig="$(echo -n "$payload" | openssl dgst -sha256 -hmac "$SHARED_SECRET" 2>/dev/null | awk '{print $NF}')"
    if [[ -z "$sig" ]]; then
        echo "[ERROR] _lb_hmac_sign: openssl 不可用或签名生成失败" >&2
        return 1
    fi
    echo "${timestamp}:${sig}"
}

# ── 公开API ────────────────────────────────────────────────

# lb_register(display_name) → 输出 user_id 到 stdout, 失败返回1
# 同时更新本地状态文件
lb_register() {
    local display_name="$1"
    if [[ -z "$display_name" ]]; then
        echo "[ERROR] lb_register: display_name 为空" >&2
        return 1
    fi

    local resp http_code
    resp="$(_lb_curl_post "/api/user/register" "{\"display_name\":\"${display_name}\",\"device_id\":\"$(uname -n)\"}")"
    http_code="$(echo "$resp" | tail -1)"
    local body; body="$(echo "$resp" | sed '$d')"

    if [[ "$http_code" != "200" ]] && [[ "$http_code" != "201" ]]; then
        echo "[ERROR] lb_register: API返回 HTTP ${http_code}: ${body}" >&2
        return 1
    fi

    local user_id
    user_id="$(_lb_json_get_str "$body" "user_id")"
    if [[ -z "$user_id" ]]; then
        echo "[ERROR] lb_register: 响应中未找到 user_id: ${body}" >&2
        return 1
    fi

    local token
    token="$(_lb_json_get_str "$body" "token")"
    if [[ -z "$token" ]]; then
        echo "[ERROR] lb_register: 响应中未找到 token: ${body}" >&2
        return 1
    fi

    # 保存本地状态
    mkdir -p "$(dirname "$LB_STATE_FILE")"
    cat > "$LB_STATE_FILE" <<STATEEOF
{"user_id":"${user_id}","token":"${token}","display_name":"${display_name}","registered":true,"privacy_mode":false,"last_sync":"$(date '+%Y-%m-%dT%H:%M:%S%z')"}
STATEEOF

    echo "$user_id"
    return 0
}

# lb_checkin(user_id, sets, reps, hold) → 成功返回0, 网络失败时缓存并返回1
lb_checkin() {
    local user_id="$1" sets="${2:-0}" reps="${3:-0}" hold="${4:-0}"

    if [[ -z "$user_id" ]]; then
        echo "[ERROR] lb_checkin: user_id 为空" >&2
        return 1
    fi

    # 读取 token：优先 read_config，回退到本地状态文件
    local token
    if declare -f read_config >/dev/null 2>&1; then
        token="$(read_config "health-leaderboard.token" "")"
    fi
    if [[ -z "$token" ]]; then
        local state
        state="$(_lb_load_state)"
        token="$(_lb_json_get_str "$state" "token")"
    fi

    local resp http_code
    # 构造请求体（供签名和curl共用，确保签名体=请求体）
    local body
    body="{\"user_id\":\"${user_id}\",\"sets_completed\":${sets},\"reps_per_set\":${reps},\"hold_seconds\":${hold},\"device_id\":\"$(uname -n)\"}"

    # 生成HMAC签名
    local hmac_result
    if ! hmac_result="$(_lb_hmac_sign "POST" "/api/checkin" "$body")"; then
        echo "[ERROR] lb_checkin: HMAC签名生成失败" >&2
        return 1
    fi

    resp="$(_lb_curl_post "/api/checkin" "$body" "$token" "$hmac_result")"
    http_code="$(echo "$resp" | tail -1)"
    local body; body="$(echo "$resp" | sed '$d')"

    if [[ "$http_code" == "200" ]] || [[ "$http_code" == "201" ]]; then
        # 成功，尝试冲刷离线队列
        _lb_flush_pending
        return 0
    fi

    # 网络失败（超时/无响应/5xx），缓存到离线队列
    if [[ "$http_code" == "000" ]] || [[ "$http_code" -ge 500 ]]; then
        echo "[WARN] lb_checkin: 网络不可用 (HTTP ${http_code})，已缓存到离线队列" >&2
        _lb_add_pending "$user_id" "$sets" "$reps" "$hold"
        return 1
    fi

    # 4xx 错误不重试
    echo "[WARN] lb_checkin: 请求被拒绝 (HTTP ${http_code}): ${body}" >&2
    return 1
}

# lb_get_rank(user_id) → 输出JSON排名信息到stdout
lb_get_rank() {
    local user_id="$1"

    if [[ -z "$user_id" ]]; then
        echo '{"error":"user_id为空"}'
        return 1
    fi

    local resp http_code
    resp="$(_lb_curl_get "/api/user/${user_id}")"
    http_code="$(echo "$resp" | tail -1)"
    local body; body="$(echo "$resp" | sed '$d')"

    if [[ "$http_code" != "200" ]]; then
        echo "{\"error\":\"API返回HTTP ${http_code}\"}"
        return 1
    fi

    echo "$body"
    return 0
}

# lb_get_leaderboard(type) → 输出JSON排行榜到stdout
# type: weekly | monthly | alltime
lb_get_leaderboard() {
    local type="${1:-weekly}"

    case "$type" in
        weekly|monthly|alltime) ;;
        *)
            echo "{\"error\":\"不支持的类型: ${type}，可选 weekly/monthly/alltime\"}"
            return 1
            ;;
    esac

    local resp http_code
    resp="$(_lb_curl_get "/api/leaderboard?type=${type}")"
    http_code="$(echo "$resp" | tail -1)"
    local body; body="$(echo "$resp" | sed '$d')"

    if [[ "$http_code" != "200" ]]; then
        echo "{\"error\":\"API返回HTTP ${http_code}\"}"
        return 1
    fi

    echo "$body"
    return 0
}

# lb_get_stats() → 输出JSON全局统计到stdout
lb_get_stats() {
    local resp http_code
    resp="$(_lb_curl_get "/api/stats")"
    http_code="$(echo "$resp" | tail -1)"
    local body; body="$(echo "$resp" | sed '$d')"

    if [[ "$http_code" != "200" ]]; then
        echo "{\"error\":\"API返回HTTP ${http_code}\"}"
        return 1
    fi

    echo "$body"
    return 0
}

# lb_get_user_id() → 从本地状态读取user_id, 未注册返回空
lb_get_user_id() {
    local state
    state="$(_lb_load_state)"
    local user_id registered
    user_id="$(_lb_json_get_str "$state" "user_id")"
    registered="$(_lb_json_get_bool "$state" "registered")"

    if [[ "$registered" == "true" ]] && [[ -n "$user_id" ]]; then
        echo "$user_id"
        return 0
    fi
    return 1
}

# lb_is_registered() → 已注册返回0
lb_is_registered() {
    lb_get_user_id >/dev/null 2>&1
}

# lb_get_pending_count() → 返回离线队列中待发送的打卡数
lb_get_pending_count() {
    local pending
    pending="$(_lb_load_pending)"
    if [[ "$pending" == "[]" ]]; then
        echo "0"
    else
        echo "$pending" | grep -o '"user_id"' | wc -l | tr -d ' '
    fi
}

# lb_set_privacy_mode(on_off) → 设置隐私模式 true/false
lb_set_privacy_mode() {
    local mode="${1:-true}"
    local state
    state="$(_lb_load_state)"
    local user_id display_name registered token
    user_id="$(_lb_json_get_str "$state" "user_id")"
    display_name="$(_lb_json_get_str "$state" "display_name")"
    registered="$(_lb_json_get_bool "$state" "registered")"
    token="$(_lb_json_get_str "$state" "token")"
    cat > "$LB_STATE_FILE" <<STATEEOF
{"user_id":"${user_id}","token":"${token}","display_name":"${display_name}","registered":${registered},"privacy_mode":${mode},"last_sync":"$(date '+%Y-%m-%dT%H:%M:%S%z')"}
STATEEOF
}
