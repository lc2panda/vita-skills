#!/usr/bin/env bash
# Input:  配置参数（间隔、消息模板）、系统时间、系统空闲时长（屏幕使用时间估算）
# Output: 三级递进系统通知、日志记录到 ~/.vita/logs/eye-care.log
# Pos:    核心提醒模块之一，由提醒调度引擎（cron/launchd/scheduler）按间隔触发
#
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

set -euo pipefail

# ── 路径解析 ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
    source "${SCRIPT_DIR}/lib/common.sh"
else
    echo "[eye-care] FATAL: cannot source common.sh from ${SCRIPT_DIR}/lib/" >&2
    exit 1
fi

MODULE="eye-care"
STATE_FILE="${VITA_STATE_DIR}/${MODULE}.json"

# ── 默认参数 ──────────────────────────────────────────────
DEFAULT_INTERVAL_MINUTES=50        # 默认50分钟（配合同设计 §3.2.1）
DEFAULT_BREAK_SECONDS=60           # 休息60秒
DEFAULT_HARD_LIMIT_MINUTES=90      # 三级硬限制90分钟
DEFAULT_VIEW_DISTANCE_M=6          # 远眺距离6米
DEFAULT_MIN_INTERVAL=45            # 允许最小间隔
DEFAULT_MAX_INTERVAL=90            # 允许最大间隔

# ── 帮助信息 ──────────────────────────────────────────────
show_help() {
    cat <<'EOF'
用法: eye-care.sh [选项]

用眼健康提醒脚本。由调度器定期调用，根据屏幕使用时长发送三级递进提醒。

选项:
  --interval N     提醒间隔（分钟），默认50，范围45-90
  --break N        建议休息时长（秒），默认60
  --once           单次运行后退出（不发通知时静默退出）
  -h, --help       显示此帮助信息

配置:
  ~/.vita/config 中可设置:
    eye_care_interval_minutes=50
    eye_care_break_seconds=60

设计依据:
  §3.2 用眼提醒模块 — 50分钟间隔、三级递进提醒
  §5.5 心流适配与强提醒机制 — 轻度打扰→完全暂停的梯度
  §5.7 动态自适应提醒引擎 — JITAI 自适应架构
  蓝光误区纠正依据：AAO (American Academy of Ophthalmology) 2017 声明
EOF
}

# ── 解析命令行参数 ────────────────────────────────────────
INTERVAL_MINUTES="$DEFAULT_INTERVAL_MINUTES"
BREAK_SECONDS="$DEFAULT_BREAK_SECONDS"
VIEW_DISTANCE_M="$DEFAULT_VIEW_DISTANCE_M"
ONCE_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval)
            INTERVAL_MINUTES="$2"
            shift 2
            ;;
        --break)
            BREAK_SECONDS="$2"
            shift 2
            ;;
        --once)
            ONCE_MODE=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "[eye-care] 未知参数: $1" >&2
            show_help
            exit 1
            ;;
    esac
done

# ── 配置加载（命令行 > 配置文件 > 默认值）────────────────
_load_config_override() {
    local cfg_interval cfg_break
    cfg_interval="$(vita_config_get "eye_care_interval_minutes" "")"
    cfg_break="$(vita_config_get "eye_care_break_seconds" "")"

    # 只在命令行未覆盖时应用配置文件值
    if [[ "$INTERVAL_MINUTES" == "$DEFAULT_INTERVAL_MINUTES" && -n "$cfg_interval" ]]; then
        INTERVAL_MINUTES="$cfg_interval"
    fi
    if [[ "$BREAK_SECONDS" == "$DEFAULT_BREAK_SECONDS" && -n "$cfg_break" ]]; then
        BREAK_SECONDS="$cfg_break"
    fi
}
_load_config_override

# ── 参数校验 ──────────────────────────────────────────────
if ! [[ "$INTERVAL_MINUTES" =~ ^[0-9]+$ ]] || \
   [[ "$INTERVAL_MINUTES" -lt "$DEFAULT_MIN_INTERVAL" ]] || \
   [[ "$INTERVAL_MINUTES" -gt "$DEFAULT_MAX_INTERVAL" ]]; then
    vita_log_warn "$MODULE" "interval=${INTERVAL_MINUTES} 越界，回退默认 $DEFAULT_INTERVAL_MINUTES"
    INTERVAL_MINUTES="$DEFAULT_INTERVAL_MINUTES"
fi

# ── 模块启用检查 ──────────────────────────────────────────
_module_enabled() {
    local enabled
    enabled="$(vita_config_get "eye_care_enabled" "true")"
    [[ "$enabled" == "true" || "$enabled" == "1" || "$enabled" == "yes" ]]
}

# ── 免打扰检查 ────────────────────────────────────────────
_is_do_not_disturb() {
    local dnd_start dnd_end current_h current_m current
    dnd_start="$(vita_config_get "eye_care_dnd_start" "")"
    dnd_end="$(vita_config_get "eye_care_dnd_end" "")"

    if [[ -z "$dnd_start" || -z "$dnd_end" ]]; then
        return 1
    fi

    current_h="$(date +%H)"
    current_m="$(date +%M)"
    current=$((10#$current_h * 60 + 10#$current_m))

    local start_h="${dnd_start%:*}" start_m="${dnd_start#*:}"
    local end_h="${dnd_end%:*}" end_m="${dnd_end#*:}"
    local s=$((10#$start_h * 60 + 10#$start_m))
    local e=$((10#$end_h * 60 + 10#$end_m))

    if [[ $s -le $e ]]; then
        [[ $current -ge $s && $current -le $e ]] && return 0
    else
        # 跨午夜
        [[ $current -ge $s || $current -le $e ]] && return 0
    fi
    return 1
}

# ── 空闲时长检测（代理屏幕使用估算）───────────────────────
_get_idle_seconds() {
    case "${VITA_PLATFORM}" in
        macos)
            ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'
            ;;
        linux)
            if command -v xprintidle &>/dev/null; then
                echo $(( $(xprintidle 2>/dev/null || echo 0) / 1000 ))
            elif [[ -f /proc/interrupts ]]; then
                # 降级：无法精确检测，返回 0（视为活跃）
                echo 0
            else
                echo 0
            fi
            ;;
        *)
            echo 0
            ;;
    esac
}

# ── 状态读写 ──────────────────────────────────────────────
_read_state() {
    if [[ -f "${STATE_FILE}" ]]; then
        cat "${STATE_FILE}"
    else
        echo '{"last_break_epoch":0,"last_reminder_epoch":0,"escalation_level":0}'
    fi
}

_write_state() {
    local last_break="$1"
    local last_reminder="$2"
    local level="$3"
    mkdir -p "$(dirname "${STATE_FILE}")"
    printf '{"last_break_epoch":%s,"last_reminder_epoch":%s,"escalation_level":%s}\n' \
        "$last_break" "$last_reminder" "$level" > "${STATE_FILE}"
}

# ── 获取 Unix 时间戳 ──────────────────────────────────────
_now_epoch() {
    date +%s
}

# ── 三级递进提醒消息 ──────────────────────────────────────
# 设计依据：§3.2 用眼提醒模块 + AAO 蓝光误区纠正
_get_reminder_message() {
    local level="$1"
    local screen_minutes="$2"
    local now
    now="$(get_iso8601)"

    case "$level" in
        1)
            # 一级：轻度提醒 — 友好提示
            echo "👁️ 屏幕使用${screen_minutes}分钟了，远眺${VIEW_DISTANCE_M}米外20秒吧～"
            echo ""
            echo "20-20-20-20改良版：每20分钟 → 远眺20英尺(6米)外 → 眨眼20次 → 持续20秒"
            ;;
        2)
            # 二级：中强度提醒 — 生理机制解释 + 可操作步骤
            echo "🔵 眼晴需要休息！请远眺${VIEW_DISTANCE_M}米外+有意识眨眼10-15次，让泪膜恢复"
            echo ""
            echo "机理：专注屏幕时眨眼频率下降60%以上(Meibomian glands停滞 → 蒸发过强型干眼)"
            echo "行动：站起远眺 ${VIEW_DISTANCE_M}m+ 物体，完整眨眼15次（上睑到下睑，每次0.5秒）"
            echo ""
            echo "注意：AAO指出蓝光眼镜无充分证据预防眼疲劳，远眺+眨眼才是有效措施"
            ;;
        3)
            # 三级：强提醒 — 强烈建议闭眼休息 + AI后台安抚
            echo "⚠️ 用眼已超90分钟！强烈建议闭眼休息${BREAK_SECONDS}秒。AI可以继续后台工作～"
            echo ""
            echo "强制行动："
            echo "  1. 闭眼 ${BREAK_SECONDS} 秒 — 让Meibomian glands重新分泌脂质层"
            echo "  2. 远眺窗外/${VIEW_DISTANCE_M}m外 — 让ciliary muscle解除痉挛"
            echo "  3. 掌心热敷双眼30秒（可选，40-45°C促进睑板腺分泌）"
            echo ""
            echo "AAO临床建议：无证据支持蓝光眼镜；20-20-20-20改良规则为证据导向方案"
            ;;
        *)
            return 1
            ;;
    esac
}

# ── 发送提醒 ──────────────────────────────────────────────
_fire_reminder() {
    local level="$1"
    local screen_minutes="$2"
    local title
    local message

    case "$level" in
        1) title="👁️ Vita 用眼提醒" ;;
        2) title="🔵 Vita 用眼提醒 (级)" ;;
        3) title="⚠️ Vita 用眼强提醒" ;;
        *) return 1 ;;
    esac

    message="$(_get_reminder_message "$level" "$screen_minutes")"

    send_notification "$title" "$message" "default"

    vita_log_info "$MODULE" "级提醒发送 | 屏幕已用=${screen_minutes}min | level=${level}"
}

# ── 记录休息 ──────────────────────────────────────────────
_record_break() {
    local idle="$1"
    local now
    now="$(_now_epoch)"
    _write_state "$now" "$(state_get "$STATE_FILE" "last_reminder_epoch")" 0
    vita_log_info "$MODULE" "检测到休息 | idle=${idle}s | 重置提醒等级"
}

# ── 主逻辑 ────────────────────────────────────────────────
main() {
    # 1. 启用检查
    if ! _module_enabled; then
        vita_log_info "$MODULE" "模块已禁用，跳过"
        [[ "$ONCE_MODE" == true ]] && return 0
        exit 0
    fi

    # 2. 免打扰检查
    if _is_do_not_disturb; then
        [[ "$ONCE_MODE" == true ]] && return 0
        exit 0
    fi

    # 3. 获取空闲时长 & 当前状态
    local idle_seconds now_epoch
    idle_seconds="$(_get_idle_seconds)"
    now_epoch="$(_now_epoch)"

    local state_json
    state_json="$(_read_state)"
    local last_break_epoch last_reminder_epoch escalation_level
    last_break_epoch="$(echo "$state_json" | sed 's/.*"last_break_epoch":\([0-9]*\).*/\1/')"
    last_reminder_epoch="$(echo "$state_json" | sed 's/.*"last_reminder_epoch":\([0-9]*\).*/\1/')"
    escalation_level="$(echo "$state_json" | sed 's/.*"escalation_level":\([0-9]*\).*/\1/')"

    # 默认值
    [[ -z "$last_break_epoch" ]] && last_break_epoch=0
    [[ -z "$last_reminder_epoch" ]] && last_reminder_epoch=0
    [[ -z "$escalation_level" ]] && escalation_level=0

    # 4. 休息检测：如果空闲时长 >= 休息时长的一半，视为已休息
    local break_threshold=$((BREAK_SECONDS / 2))
    if [[ "$idle_seconds" -ge "$break_threshold" ]]; then
        _record_break "$idle_seconds"
        [[ "$ONCE_MODE" == true ]] && return 0
        exit 0
    fi

    # 5. 计算自上次休息以来的屏幕使用时间（分钟）
    local elapsed_minutes=0
    if [[ "$last_break_epoch" -gt 0 ]]; then
        elapsed_minutes=$(( (now_epoch - last_break_epoch) / 60 ))
    fi

    local interval_seconds=$((INTERVAL_MINUTES * 60))
    local hard_limit_seconds=$((DEFAULT_HARD_LIMIT_MINUTES * 60))

    # 6. 判断是否需要发送提醒
    local new_level=0

    # 三级：硬限制 90 分钟
    if [[ "$elapsed_minutes" -ge "$DEFAULT_HARD_LIMIT_MINUTES" ]]; then
        new_level=3
    # 二级：interval * 1.3 (如50→65分钟)
    elif [[ "$elapsed_minutes" -ge $((INTERVAL_MINUTES * 130 / 100)) ]]; then
        new_level=2
    # 一级：配置间隔 (如50分钟)
    elif [[ "$elapsed_minutes" -ge "$INTERVAL_MINUTES" ]]; then
        new_level=1
    fi

    # 7. 如果层级未变化且已发过同层级，抑制重复提醒
    if [[ "$new_level" -gt 0 ]]; then
        # 同级别提醒至少间隔 UPDATE_PERIOD 秒再发（避免 cron 每分钟触发时刷屏）
        local UPDATE_PERIOD=300  # 5分钟
        if [[ "$escalation_level" -eq "$new_level" ]] && \
           [[ "$last_reminder_epoch" -gt 0 ]] && \
           [[ $((now_epoch - last_reminder_epoch)) -lt "$UPDATE_PERIOD" ]]; then
            # 同级别抑制：时间太短不重复发
            :
        else
            _fire_reminder "$new_level" "$elapsed_minutes"
            _write_state "$last_break_epoch" "$now_epoch" "$new_level"
        fi
    fi

    # 8. 如果是 once 模式且未达到任何级别，静默退出
    if [[ "$ONCE_MODE" == true ]]; then
        [[ "$new_level" -eq 0 ]] && return 0
    fi
}

# ── 入口 ──────────────────────────────────────────────────
_acquire_lock() {
    local lock_name="eye-care-${$}"
    if ! acquire_lock "$lock_name"; then
        vita_log_warn "$MODULE" "上一实例仍在运行，跳过本次执行"
        exit 0
    fi
    echo "$lock_name"
}

LOCK_NAME="$(_acquire_lock)"
trap 'release_lock "$LOCK_NAME"' EXIT

main "$@"
