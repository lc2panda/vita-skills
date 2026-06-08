#!/usr/bin/env bash
# ===========================================================================
# Input:  调用方传入的参数 / 系统环境 / 配置文件
# Output: 日志条目 / 系统通知 / 心流判定结果 / 配置键值
# Pos:    所有提醒脚本的公共依赖库，提供日志、配置、通知、心流检测等基础能力
# ===========================================================================
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的md。

set -euo pipefail

# ── 路径常量 ─────────────────────────────────────────────────
readonly VITA_ROOT="${VITA_ROOT:-${HOME}/.vita}"
readonly LOG_DIR_DEFAULT="${VITA_ROOT}/logs"
readonly CONFIG_DIR_DEFAULT="${VITA_ROOT}/config"
readonly STATE_DIR_DEFAULT="${VITA_ROOT}/state"

# 项目内 config 路径（从 scripts/lib/ → 项目根 config/）
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_CONFIG_DIR="$(cd "${_COMMON_DIR}/../../config" 2>/dev/null && pwd || echo '')"

# 懒加载基路径（指向 lib 目录，供 notify.sh / suppression.sh 等使用）
readonly _LAZY_BASE="${_COMMON_DIR}"

# ── 确保目录存在 ─────────────────────────────────────────────
_ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" 2>/dev/null || return 1
    fi
}

# ── 获取时间戳（ISO 8601, +08:00 时区） ─────────────────────
# Usage: ts=$(get_timestamp)
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S %z'
}

# ── 获取日志文件路径（按日期分文件） ────────────────────────
# Usage: log_file=$(get_log_file [module_name])
get_log_file() {
    local module="${1:-sedentary}"
    local log_dir="${VITA_LOG_DIR:-${LOG_DIR_DEFAULT}}"
    _ensure_dir "$log_dir"
    printf '%s/%s-%s.log' "$log_dir" "$module" "$(date '+%Y-%m-%d')"
}

# ── 获取状态文件路径 ─────────────────────────────────────────
# Usage: state_file=$(get_state_file [module_name])
get_state_file() {
    local module="${1:-sedentary}"
    local state_dir="${VITA_STATE_DIR:-${STATE_DIR_DEFAULT}}"
    _ensure_dir "$state_dir"
    printf '%s/%s.state' "$state_dir" "$module"
}

# ── 日志记录 ─────────────────────────────────────────────────
# Usage: log_message <level> <module> <message>
# level: INFO | WARN | ERROR | REMINDER | RESPONSE
log_message() {
    local level="${1:-INFO}"
    local module="${2:-sedentary}"
    local message="${3:-}"
    local log_file
    log_file="$(get_log_file "$module")"
    _ensure_dir "$(dirname "$log_file")"

    printf '[%s] [%s] [%s] %s\n' \
        "$(get_timestamp)" "$level" "$module" "$message" >> "$log_file"
}

# ── 简单 YAML 配置读取（不依赖 yq） ──────────────────────────
# 层级路径用点号分隔，如 "health-sedentary.interval_minutes"
# 优先读取环境变量 VITA_SEDENTARY_INTERVAL_MINUTES，若无则读 YAML
# Usage: value=$(read_config "health-sedentary.interval_minutes" "30")
read_config() {
    local key_path="$1"
    local default_value="${2:-}"
    local config_file="${VITA_CONFIG_FILE:-${PROJECT_CONFIG_DIR}/default.yaml}"

    # 1. 环境变量覆盖：将 key_path 转为大写并替换 . 和 - 为 _
    #    如 health-sedentary.interval_minutes → VITA_HEALTH_SEDENTARY_INTERVAL_MINUTES
    local env_key
    env_key="VITA_$(echo "$key_path" | tr '[:lower:].-' '[:upper:]__')"
    if [[ -n "${!env_key:-}" ]]; then
        printf '%s' "${!env_key}"
        return 0
    fi

    # 2. 配置缓存（基于文件 mtime，有效期 5 分钟）
    local _config_cache_dir="${STATE_DIR_DEFAULT}/cache/config"
    local _config_cache_ttl=300
    local _cache_key_safe="${key_path//\//_}"
    local _cache_file="${_config_cache_dir}/${_cache_key_safe}"
    if [[ -f "$_cache_file" ]]; then
        local _cache_ts _now
        _cache_ts=$(stat -f '%m' "$_cache_file" 2>/dev/null || stat -c '%Y' "$_cache_file" 2>/dev/null || echo "0")
        _now=$(date +%s)
        # 检查缓存是否在 TTL 内，且不早于配置文件 mtime
        local _config_mtime
        _config_mtime=$(stat -f '%m' "$config_file" 2>/dev/null || stat -c '%Y' "$config_file" 2>/dev/null || echo "0")
        if [[ $((_now - _cache_ts)) -lt $_config_cache_ttl ]] && [[ "$_cache_ts" -ge "$_config_mtime" ]]; then
            cat "$_cache_file" 2>/dev/null
            return 0
        fi
    fi

    # 3. 按层级读取 YAML 文件
    if [[ ! -f "$config_file" ]]; then
        printf '%s' "$default_value"
        return 0
    fi

    local IFS='.'
    local parts=($key_path)
    unset IFS

    local in_section=false
    local collecting_list=false
    local list_values=""

    while IFS= read -r line; do
        # 跳过注释和空行
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$(echo "$line" | tr -d '[:space:]')" ]] && continue

        # 如果在收集列表项且遇到非列表行，停止收集
        if [[ "$collecting_list" == true ]]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(.*) ]]; then
                local item="${BASH_REMATCH[1]}"
                item="$(echo "$item" | sed 's/^"//;s/"$//;s/^'\''//;s/'\''$//;s/[[:space:]]*$//')"
                if [[ -z "$list_values" ]]; then
                    list_values="$item"
                else
                    list_values="${list_values},${item}"
                fi
                continue
            else
                # 列表收集完成
                printf '%s' "$list_values"
                return 0
            fi
        fi

        # 检测 section 头（如 health-sedentary:）
        if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_-]*)[[:space:]]*:[[:space:]]*$ ]]; then
            local section_name="${BASH_REMATCH[1]}"
            if [[ "$section_name" == "${parts[0]}" ]]; then
                in_section=true
            else
                in_section=false
            fi
            continue
        fi

        # 如果不在目标 section 中，跳过
        if [[ "$in_section" != true ]]; then
            continue
        fi

        # 在 section 内匹配 key（只有一级缩进）
        local indent_key
        indent_key="$(echo "$line" | sed -n 's/^[[:space:]]*\([a-zA-Z_][a-zA-Z0-9_-]*\)[[:space:]]*:[[:space:]]*\(.*\)/\1/p')"
        if [[ -n "$indent_key" ]]; then
            if [[ "$indent_key" == "${parts[1]}" ]]; then
                local val
                val="$(echo "$line" | sed -n 's/^[[:space:]]*[^:]*:[[:space:]]*//p' | sed 's/[[:space:]]*#.*//; s/^"//; s/"$//; s/^'\''//; s/'\''$//; s/[[:space:]]*$//')"

                # 空值可能是 YAML 列表的开头（key: 后无值，下一行开始是 - item）
                if [[ -z "$val" ]]; then
                    collecting_list=true
                    # 继续读取下一行看是否为列表项
                    continue
                fi

                # 处理内联空数组 []
                if [[ "$val" == "[]" ]]; then
                    _ensure_dir "$_config_cache_dir" 2>/dev/null || true
                    printf '' | tee "$_cache_file" 2>/dev/null
                    return 0
                fi

                _ensure_dir "$_config_cache_dir" 2>/dev/null || true
                printf '%s' "$val" | tee "$_cache_file" 2>/dev/null
                return 0
            fi
        fi
    done < "$config_file"

    # 循环结束后，如果仍在收集列表，输出已收集的值
    if [[ "$collecting_list" == true ]]; then
        _ensure_dir "$_config_cache_dir" 2>/dev/null || true
        printf '%s' "$list_values" | tee "$_cache_file" 2>/dev/null
        return 0
    fi

    # 4. 未匹配则返回默认值
    _ensure_dir "$_config_cache_dir" 2>/dev/null || true
    printf '%s' "$default_value" | tee "$_cache_file" 2>/dev/null
}

# ── 系统通知（跨平台，懒加载） ─────────────────────────────────
# Usage: send_notification <title> <message> [sound]
# 首次调用时懒加载 notify.sh 以节省启动时间
send_notification() {
    if [[ -f "${_LAZY_BASE}/notify.sh" ]]; then
        source "${_LAZY_BASE}/notify.sh" || true
    else
        local title="${1:-通知}" message="${2:-}"
        printf '[%s] %s: %s\n' "$(get_timestamp)" "$title" "$message" >&2
        return 1
    fi
    send_notification "$@"
}


# ── 心流检测 ─────────────────────────────────────────────────
# 通过检测 shell history 文件最近修改时间来判定终端活跃度
# Usage: detect_flow [window_minutes]
# 返回: 0 表示检测到心流（终端活跃）, 1 表示未检测到
detect_flow() {
    local window_minutes="${1:-5}"
    local now
    now="$(date +%s)"
    local active=false

    # 检查 ZSH history 修改时间
    local zsh_hist="${HISTFILE:-${HOME}/.zsh_history}"
    if [[ -f "$zsh_hist" ]]; then
        local hist_mtime
        hist_mtime="$(stat -f '%m' "$zsh_hist" 2>/dev/null || stat -c '%Y' "$zsh_hist" 2>/dev/null || echo 0)"
        if (( hist_mtime > 0 && now - hist_mtime < window_minutes * 60 )); then
            active=true
        fi
    fi

    # 检查 Bash history 修改时间
    if [[ "$active" != true ]]; then
        local bash_hist="${HOME}/.bash_history"
        if [[ -f "$bash_hist" ]]; then
            local hist_mtime
            hist_mtime="$(stat -f '%m' "$bash_hist" 2>/dev/null || stat -c '%Y' "$bash_hist" 2>/dev/null || echo 0)"
            if (( hist_mtime > 0 && now - hist_mtime < window_minutes * 60 )); then
                active=true
            fi
        fi
    fi

    # 补充检查：是否有活跃的终端进程（TTY 绑定）
    if [[ "$active" != true ]]; then
        local tty_count
        tty_count="$(who 2>/dev/null | grep -c 'tty' 2>/dev/null || echo 0)"
        if (( tty_count > 0 )); then
            active=true
        fi
    fi

    if [[ "$active" == true ]]; then
        return 0
    fi
    return 1
}

# ── 免打扰时段检查 ───────────────────────────────────────────
# 检查当前时间是否在免打扰时段内
# config 中 dnd_periods 的格式为 "HH:MM-HH:MM"
# Usage: is_dnd "10:00-11:00,14:00-15:00" → 返回 0 表示在 DND 中
is_dnd() {
    local dnd_list="$1"
    local now_minutes
    now_minutes=$(date +%H:%M 2>/dev/null || echo "00:00")
    local current_total
    current_total=$(( $(echo "$now_minutes" | cut -d: -f1) * 60 + $(echo "$now_minutes" | cut -d: -f2) ))

    local IFS=','
    local periods
    read -ra periods <<< "$dnd_list"
    for period in "${periods[@]}"; do
        period="$(echo "$period" | tr -d '[:space:]')"
        [[ -z "$period" ]] && continue
        local start_str="${period%%-*}"
        local end_str="${period##*-}"
        local start_total=$(( $(echo "$start_str" | cut -d: -f1) * 60 + $(echo "$start_str" | cut -d: -f2) ))
        local end_total=$(( $(echo "$end_str" | cut -d: -f1) * 60 + $(echo "$end_str" | cut -d: -f2) ))

        if (( current_total >= start_total && current_total < end_total )); then
            return 0
        fi
    done
    return 1
}

# ── 读取/写入状态文件（key=value 格式） ──────────────────────
read_state() {
    local module key default
    if [[ $# -eq 2 ]]; then
        # 简化调用: read_state "key" "default_value"
        module="system"
        key="$1"
        default="${2:-}"
    else
        module="${1:-sedentary}"
        key="$2"
        default="${3:-}"
    fi
    local state_file
    state_file="$(get_state_file "$module")"
    if [[ -f "$state_file" ]]; then
        local val
        val=$(grep "^${key}=" "$state_file" 2>/dev/null | cut -d= -f2-)
        echo "${val:-$default}"
    else
        echo "$default"
    fi
}

write_state() {
    local module key value
    if [[ $# -eq 2 ]]; then
        # 简化调用: write_state "key" "value" (使用默认模块)
        module="system"
        key="$1"
        value="$2"
    else
        module="${1:-sedentary}"
        key="$2"
        value="$3"
    fi
    local state_file
    state_file="$(get_state_file "$module")"

    if [[ -f "$state_file" ]]; then
        # 原子写入：先写临时文件，再 mv，防止并发写损坏
        local _tmp_state="${state_file}.tmp.$$"
        if grep -q "^${key}=" "$state_file" 2>/dev/null; then
            # macOS 兼容 sed
            if [[ "$(uname -s)" == "Darwin" ]]; then
                sed "s|^${key}=.*|${key}=${value}|" "$state_file" > "$_tmp_state"
            else
                sed "s|^${key}=.*|${key}=${value}|" "$state_file" > "$_tmp_state"
            fi
            mv "$_tmp_state" "$state_file"
        else
            cp "$state_file" "$_tmp_state"
            printf '%s=%s\n' "$key" "$value" >> "$_tmp_state"
            mv "$_tmp_state" "$state_file"
        fi
    else
        printf '%s=%s\n' "$key" "$value" > "$state_file"
    fi
}

# ═══════════════════════════════════════════════════════════════
# 日志轮转函数
# ═══════════════════════════════════════════════════════════════
# 自动清理 30 天前的日志，限制单文件最大 10MB
# Usage: log_rotate [log_dir]
#   默认清理 LOG_DIR 下的日志；可指定其他目录
log_rotate() {
    local target_dir="${1:-${LOG_DIR:-${STATE_DIR_DEFAULT}/logs}}"
    local max_age_days=30
    local max_size_mb=10

    if [[ ! -d "$target_dir" ]]; then
        return 0
    fi

    # 1. 清理超过 max_age_days 的日志文件
    find "$target_dir" -name "*.log" -type f -mtime "+${max_age_days}" -exec rm -f {} \; 2>/dev/null || true

    # 2. 对当前日志文件做大小轮转（>10MB 时截断保留尾部 1MB）
    while IFS= read -r -d '' logfile; do
        local _size
        _size=$(wc -c < "$logfile" 2>/dev/null || echo "0")
        if [[ "$_size" -gt $((max_size_mb * 1024 * 1024)) ]]; then
            # 保留最后 1MB 作为备份上下文
            tail -c $((1024 * 1024)) "$logfile" > "${logfile}.old"
            :> "$logfile"
        fi
    done < <(find "$target_dir" -name "*.log" -type f -print0 2>/dev/null)
}

# 以下为调度器/CLI 扩展函数 (v0.1.0)
# ═══════════════════════════════════════════════════════════════

# ── 颜色常量 ─────────────────────────────────────────────────
if [[ -n "${TERM:-}" ]] && [[ "$TERM" != "dumb" ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_RED='\033[31m'
    C_GREEN='\033[32m'
    C_YELLOW='\033[33m'
    C_BLUE='\033[34m'
    C_MAGENTA='\033[35m'
    C_CYAN='\033[36m'
    C_WHITE='\033[37m'
    C_BG_BLUE='\033[44m'
    C_BG_YELLOW='\033[43m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''
    C_BLUE=''; C_MAGENTA=''; C_CYAN=''; C_WHITE=''; C_BG_BLUE=''; C_BG_YELLOW=''
fi

# ── PID 与锁文件 ─────────────────────────────────────────────
VITA_PID_FILE="${VITA_PID_FILE:-$STATE_DIR_DEFAULT/vita.pid}"
VITA_LOCK_FILE="${VITA_LOCK_FILE:-$STATE_DIR_DEFAULT/vita.lock}"

acquire_lock() {
    _ensure_dir "$STATE_DIR_DEFAULT"
    if [[ -f "$VITA_LOCK_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$VITA_LOCK_FILE" 2>/dev/null || true)
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            log_info "system" "vita 守护进程已在运行 (PID: $old_pid)" >&2
            return 1
        else
            log_info "system" "清理残留锁文件 (stale PID: ${old_pid:-unknown})" >&2
            rm -f "$VITA_LOCK_FILE" "$VITA_PID_FILE"
        fi
    fi
    echo $$ > "$VITA_LOCK_FILE"
    echo $$ > "$VITA_PID_FILE"
    return 0
}

_lock_file_was_owned_by_us=false
release_lock() {
    if [[ -f "$VITA_PID_FILE" ]]; then
        local pid
        pid=$(cat "$VITA_PID_FILE" 2>/dev/null || true)
        if [[ "$pid" == "$$" ]]; then
            rm -f "$VITA_LOCK_FILE" "$VITA_PID_FILE"
        fi
    fi
}

get_active_pid() {
    if [[ -f "$VITA_PID_FILE" ]]; then
        local pid
        pid=$(cat "$VITA_PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            printf '%s' "$pid"
            return 0
        fi
    fi
    return 1
}

# ── 智能抑制检测（懒加载） ────────────────────────────────
# 抑制检测器统一懒加载入口
# 首次调用时 source suppression.sh，后续调用直接走真实实现
_lazy_suppression() {
    if [[ -n "${__LAZY_SUPPRESSION_SOURCED:-}" ]]; then
        return 0
    fi
    __LAZY_SUPPRESSION_SOURCED=1
    if [[ -f "${_LAZY_BASE}/suppression.sh" ]]; then
        source "${_LAZY_BASE}/suppression.sh" || true
    fi
}

# 屏幕锁定/休眠检测 (懒加载 → suppression.sh)
is_screen_locked() {
    _lazy_suppression
    is_screen_locked "$@"
}

# 会议模式检测 (懒加载 → suppression.sh)
is_in_meeting() {
    _lazy_suppression
    is_in_meeting "$@"
}

# 深夜静默判定 (懒加载 → suppression.sh)
is_quiet_hours() {
    _lazy_suppression
    is_quiet_hours "$@"
}

# 用户空闲检测 (懒加载 → suppression.sh)
is_user_idle() {
    _lazy_suppression
    is_user_idle "$@"
}

# ── 简便日志函数（对 log_message 的封装） ────────────────────
# 同时定义短别名（log_info/log_warn/log_error/log_debug），供调度器/CLI 使用
log_info() {
    printf "%b[INFO]%b %s  %s\n" "${C_GREEN:-}" "${C_RESET:-}" "$(get_timestamp)" "$*" >&2
}
log_warn() {
    printf "%b[WARN]%b %s  %s\n" "${C_YELLOW:-}" "${C_RESET:-}" "$(get_timestamp)" "$*" >&2
}
log_error() {
    printf "%b[ERROR]%b %s  %s\n" "${C_RED:-}" "${C_RESET:-}" "$(get_timestamp)" "$*" >&2
}
log_debug() {
    if [[ "${VITA_DEBUG:-0}" == "1" ]]; then
        printf "%b[DEBUG]%b %s  %s\n" "${C_DIM:-}" "${C_RESET:-}" "$(get_timestamp)" "$*" >&2
    fi
}

log_info_to_stderr() { log_info "$@"; }
log_warn_to_stderr() { log_warn "$@"; }
log_error_to_stderr() { log_error "$@"; }
log_debug_to_stderr() { log_debug "$@"; }

# ── 信号处理 ──────────────────────────────────────────────
# 用法: setup_signal_handlers "cleanup_cmd" "reload_cmd"
setup_signal_handlers() {
    local cleanup_fn="${1:-}"
    local reload_fn="${2:-}"
    trap 'log_info "system" "收到 SIGTERM/SIGINT，正在优雅退出..."; '"$cleanup_fn"'; release_lock; exit 0' TERM INT
    trap 'log_info "system" "收到 SIGHUP，重新加载配置..."; '"$reload_fn"' ' HUP
}

# ── 快捷时间函数 ──────────────────────────────────────────
current_hour() {
    date +%H | sed 's/^0//'
}

current_minute() {
    date +%M | sed 's/^0//'
}

# ── 版本信息 ──────────────────────────────────────────────
readonly VITA_VERSION="0.1.0"
readonly VITA_CODENAME="Vanilla"
readonly VITA_SERIES="Alpha"

# ── 加载用户级配置覆盖 ────────────────────────────────────
# ~/.vitarc 可覆盖项目默认值（由 vitarc.sh 管理）
if [[ -f "${_LAZY_BASE}/vitarc.sh" ]]; then
    source "${_LAZY_BASE}/vitarc.sh" 2>/dev/null || true
fi

# ── 启动时自动执行日志轮转 ─────────────────────────────────
# 每次 source common.sh 时检查一次日志目录
log_rotate
