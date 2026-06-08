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

    # 2. 按层级读取 YAML 文件
    if [[ ! -f "$config_file" ]]; then
        printf '%s' "$default_value"
        return 0
    fi

    local IFS='.'
    local parts=($key_path)
    unset IFS

    local in_section=false

    while IFS= read -r line; do
        # 跳过注释和空行
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$(echo "$line" | tr -d '[:space:]')" ]] && continue

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
                val="$(echo "$line" | sed -n 's/^[[:space:]]*[^:]*:[[:space:]]*//p' | sed 's/^"//;s/"$//;s/^'\''//;s/'\''$//;s/[[:space:]]*$//')"
                printf '%s' "$val"
                return 0
            fi
        fi
    done < "$config_file"

    # 3. 未匹配则返回默认值
    printf '%s' "$default_value"
}

# ── 系统通知（跨平台） ───────────────────────────────────────
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
        # 回退到 osascript（系统内置）
        osascript -e "display notification \"$message\" with title \"$title\" sound name \"$sound\"" 2>/dev/null && return 0
        # 最后的回退：纯文本输出（cron 场景）
        printf '[%s] %s: %s\n' "$(get_timestamp)" "$title" "$message" >&2
        return 1
    fi

    # Linux: notify-send
    if [[ "$(uname -s)" == "Linux" ]]; then
        if command -v notify-send &>/dev/null; then
            notify-send "$title" "$message" --expire-time=5000 2>/dev/null && return 0
        fi
        printf '[%s] %s: %s\n' "$(get_timestamp)" "$title" "$message" >&2
        return 1
    fi

    # 未知平台：输出到 stderr
    printf '[%s] %s: %s\n' "$(get_timestamp)" "$title" "$message" >&2
    return 1
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
    local module="${1:-sedentary}"
    local key="$2"
    local state_file
    state_file="$(get_state_file "$module")"
    if [[ -f "$state_file" ]]; then
        grep "^${key}=" "$state_file" 2>/dev/null | cut -d= -f2- || echo ""
    fi
}

write_state() {
    local module="${1:-sedentary}"
    local key="$2"
    local value="$3"
    local state_file
    state_file="$(get_state_file "$module")"

    if [[ -f "$state_file" ]]; then
        if grep -q "^${key}=" "$state_file" 2>/dev/null; then
            # macOS 兼容 sed
            if [[ "$(uname -s)" == "Darwin" ]]; then
                sed -i '' "s|^${key}=.*|${key}=${value}|" "$state_file"
            else
                sed -i "s|^${key}=.*|${key}=${value}|" "$state_file"
            fi
        else
            printf '%s=%s\n' "$key" "$value" >> "$state_file"
        fi
    else
        printf '%s=%s\n' "$key" "$value" > "$state_file"
    fi
}
