#!/usr/bin/env bash
# Input:  配置参数（间隔、消息模板）、系统时间、HID 空闲时长（屏幕使用估算代理）
# Output: 三级递进系统通知、状态查询、日志到 ~/.vita/logs/eye-care-YYYY-MM-DD.log
# Pos:    核心提醒模块之一，由 cron / launchd / scheduler 调度，支持独立 daemon 运行
#
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

set -euo pipefail

# ── 加载公共库 ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
    source "${SCRIPT_DIR}/lib/common.sh"
else
    echo "[eye-care] 致命错误：找不到 ${SCRIPT_DIR}/lib/common.sh" >&2
    exit 1
fi

# ── 常量 ──────────────────────────────────────────────────
MODULE="eye-care"
CONFIG_SECTION="health-eye-care"          # 对应 config/default.yaml 中的节名
STATE_MODULE="eye_care"                   # 状态文件键前缀（与 read_state/write_state 对齐）

DEFAULT_INTERVAL_MINUTES=50               # 默认提醒间隔（设计 §3.2.1）
DEFAULT_BREAK_SECONDS=60                  # 休息时长
DEFAULT_HARD_LIMIT_MINUTES=90             # 三级触发硬阈值
VIEW_DISTANCE_M=6                         # 远眺距离（20 英尺 ≈ 6 米）

# 二级触发系数（超过 interval * 1.3 进入二级）
LEVEL2_RATIO=130
# 同级别抑制窗口（秒）：避免 cron 每分钟触发时刷屏
SUPPRESS_SECONDS=300
# 休息判定阈值：空闲超过 break_seconds/2 视为已完成休息
BREAK_RATIO=2

# ── 帮助信息 ──────────────────────────────────────────────
show_help() {
    cat <<'EOF'
用眼提醒模块 — 三级递进式用眼健康守护

用法:
  eye-care.sh --remind          发送一次提醒（调度器模式，默认）
  eye-care.sh --status          查看当前状态
  eye-care.sh --daemon          持续守护模式（前台循环，Ctrl-C 退出）

选项:
  --interval N    提醒间隔，分钟（默认 50，范围 45-90）
  --break N       建议休息时长，秒（默认 60）
  -h, --help      帮助

配置 (优先级: 环境变量 > ~/.vita/config > 项目 config/default.yaml):
  health-eye-care.interval_minutes=50
  health-eye-care.break_seconds=60
  health-eye-care.enabled=true
  health-eye-care.dnd_periods=22:00-07:00

设计依据:
  §3.2  用眼提醒模块 — 50 分钟间隔 + 三级递进提醒
  §5.5  心流适配与强提醒机制 — 轻度打扰 → 完全暂停梯度
  §5.7  动态自适应提醒引擎 — JITAI 自适应架构
  蓝光误区纠正 — AAO (American Academy of Ophthalmology) 2017 声明
  20-20-20-20 改良规则 — 每 20 分钟 / 远眺 20 英尺 / 眨眼 20 次 / 持续 20 秒
EOF
}

# ── 参数解析 ──────────────────────────────────────────────
INTERVAL_MINUTES="$DEFAULT_INTERVAL_MINUTES"
BREAK_SECONDS="$DEFAULT_BREAK_SECONDS"
ACTION="remind"                           # 默认动作

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remind)   ACTION="remind"; shift ;;
            --status)   ACTION="status"; shift ;;
            --daemon)   ACTION="daemon"; shift ;;
            --interval) INTERVAL_MINUTES="$2"; shift 2 ;;
            --break)    BREAK_SECONDS="$2"; shift 2 ;;
            -h|--help)  show_help; exit 0 ;;
            *)
                echo "[eye-care] 未知参数: $1（使用 --help 查看帮助）" >&2
                exit 1
                ;;
        esac
    done
}
parse_args "$@"

# ── 配置取值 ──────────────────────────────────────────────
load_params() {
    # 环境变量 / YAML 配置中的值（仅当命令行未覆盖默认值时生效）
    local cfg_interval cfg_break
    cfg_interval="$(read_config "${CONFIG_SECTION}.interval_minutes" "$DEFAULT_INTERVAL_MINUTES")"
    cfg_break="$(read_config "${CONFIG_SECTION}.break_seconds" "$DEFAULT_BREAK_SECONDS")"

    if [[ "$INTERVAL_MINUTES" == "$DEFAULT_INTERVAL_MINUTES" ]]; then
        INTERVAL_MINUTES="${cfg_interval:-$DEFAULT_INTERVAL_MINUTES}"
    fi
    if [[ "$BREAK_SECONDS" == "$DEFAULT_BREAK_SECONDS" ]]; then
        BREAK_SECONDS="${cfg_break:-$DEFAULT_BREAK_SECONDS}"
    fi

    # 参数护盾
    if ! [[ "$INTERVAL_MINUTES" =~ ^[0-9]+$ ]] || \
       [[ "$INTERVAL_MINUTES" -lt 45 ]] || [[ "$INTERVAL_MINUTES" -gt 90 ]]; then
        log_message "WARN" "$MODULE" "间隔参数异常($INTERVAL_MINUTES)，回退默认 $DEFAULT_INTERVAL_MINUTES"
        INTERVAL_MINUTES="$DEFAULT_INTERVAL_MINUTES"
    fi
    if ! [[ "$BREAK_SECONDS" =~ ^[0-9]+$ ]] || [[ "$BREAK_SECONDS" -lt 10 ]]; then
        log_message "WARN" "$MODULE" "休息时长异常($BREAK_SECONDS)，回退默认 $DEFAULT_BREAK_SECONDS"
        BREAK_SECONDS="$DEFAULT_BREAK_SECONDS"
    fi
}
load_params

# ── 模块启用 / 免打扰 / 平台检测 ─────────────────────────

is_enabled() {
    local v
    v="$(read_config "${CONFIG_SECTION}.enabled" "true")"
    [[ "$v" == "true" || "$v" == "1" || "$v" == "yes" ]]
}

is_in_dnd() {
    local periods
    periods="$(read_config "${CONFIG_SECTION}.dnd_periods" "")"
    if [[ -z "$periods" ]]; then
        return 1
    fi
    is_dnd "$periods"
}

get_platform() {
    uname -s
}

# ── 空闲检测（屏幕使用估算代理）───────────────────────────
# SIGPIPE 安全：awk 不提前 exit，读取全部输入后再输出第一条匹配
get_idle_seconds() {
    case "$(get_platform)" in
        Darwin)
            ioreg -c IOHIDSystem 2>/dev/null \
                | awk '/HIDIdleTime/ {if (!_p) {v=int($NF/1000000000); _p=1}} END {if (_p) print v; else print 0}'
            ;;
        Linux)
            if command -v xprintidle &>/dev/null; then
                local ms
                ms="$(xprintidle 2>/dev/null || echo 0)"
                echo $(( ms / 1000 ))
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

read_state_int() {
    local key="$1"
    local raw
    raw="$(read_state "$STATE_MODULE" "$key")"
    # 安全默认：未记录 = 0
    echo "${raw:-0}"
}

write_state_int() {
    local key="$1"
    local val="$2"
    write_state "$STATE_MODULE" "$key" "$val"
}

# ── 三级提醒消息体 ────────────────────────────────────────
# 纯中文，不推荐蓝光眼镜（AAO 指南）；推荐远眺 + 有意识眨眼 + 20-20-20-20 改良版
get_reminder_body_level1() {
    local mins="$1"
    cat <<EOF
屏幕使用 ${mins} 分钟了，远眺 ${VIEW_DISTANCE_M} 米外 20 秒吧！
20-20-20-20 改良规则：每 20 分钟 → 远眺 20 英尺外 → 眨眼 20 次 → 持续 20 秒
AAO 提示：蓝光眼镜缺乏预防眼疲劳的充分证据，远眺和眨眼才是有效措施
EOF
}

get_reminder_body_level2() {
    cat <<EOF
眼睛需要休息！请远眺 ${VIEW_DISTANCE_M} 米外并有意眨眼 10-15 次，让泪膜恢复
原因：专注屏幕时眨眼频率会下降 60% 以上，睑板腺分泌停滞导致蒸发过强型干眼
行动：站起远眺 ${VIEW_DISTANCE_M}m 外物体，完整眨眼 15 次（上睑到下睑，每次约 0.5 秒）
提示：AAO 指出蓝光眼镜并无充分证据预防眼疲劳，远眺和主动眨眼是循证有效方案
EOF
}

get_reminder_body_level3() {
    cat <<EOF
用眼已超 90 分钟！强烈建议闭眼休息 ${BREAK_SECONDS} 秒，助手可继续后台工作
强制行动建议：
  1. 闭眼 ${BREAK_SECONDS} 秒，让睑板腺重新分泌脂质层
  2. 远眺窗外 6m 外物体，让睫状肌解除痉挛
  3. 掌心热敷双眼 30 秒（可选，40-45°C 促进睑板腺分泌）
循证依据：AAO 临床声明确认无证据支持蓝光眼镜；20-20-20-20 改良规则为证据导向方案
EOF
}

# ── 获取指定级别的通知内容 ────────────────────────────────
get_notification_body() {
    local level="$1"
    local screen_minutes="$2"
    case "$level" in
        1) get_reminder_body_level1 "$screen_minutes" ;;
        2) get_reminder_body_level2 ;;
        3) get_reminder_body_level3 ;;
        *) echo "未知提醒级别" ;;
    esac
}

get_notification_title() {
    local level="$1"
    case "$level" in
        1) echo "Vita 用眼提醒" ;;
        2) echo "Vita 用眼提醒（加强）" ;;
        3) echo "Vita 用眼强提醒" ;;
        *) echo "Vita 用眼提醒" ;;
    esac
}

# ── 发送提醒 ──────────────────────────────────────────────
fire_reminder() {
    local level="$1"
    local screen_minutes="$2"
    local title body
    title="$(get_notification_title "$level")"
    body="$(get_notification_body "$level" "$screen_minutes")"

    send_notification "$title" "$body" "Glass"
    log_message "INFO" "$MODULE" \
        "L${level}提醒已发送 | 屏幕用时=${screen_minutes}min | 间隔=${INTERVAL_MINUTES}min | 休息建议=${BREAK_SECONDS}s | ${title}"
}

# ── 记录休息 ──────────────────────────────────────────────
record_break() {
    local idle_s="$1"
    local now
    now="$(date +%s)"
    write_state_int last_break_epoch "$now"
    write_state_int escalation_level "0"
    write_state_int last_reminder_epoch "0"
    log_message "INFO" "$MODULE" "检测到休息（空闲 ${idle_s}s），级别已重置"
}

# ── 决定提醒级别 ──────────────────────────────────────────
determine_level() {
    local elapsed="$1"
    if [[ "$elapsed" -ge "$DEFAULT_HARD_LIMIT_MINUTES" ]]; then
        echo 3
    elif [[ "$elapsed" -ge $(( INTERVAL_MINUTES * LEVEL2_RATIO / 100 )) ]]; then
        echo 2
    elif [[ "$elapsed" -ge "$INTERVAL_MINUTES" ]]; then
        echo 1
    else
        echo 0
    fi
}

# ── 提醒动作（单次调度）────────────────────────────────────
do_remind() {
    if ! is_enabled; then
        return 0
    fi
    if is_in_dnd; then
        return 0
    fi

    local idle_s now_s
    idle_s="$(get_idle_seconds)"
    idle_s="${idle_s:-0}"
    now_s="$(date +%s)"

    # 休息检测
    local break_threshold=$(( BREAK_SECONDS / BREAK_RATIO ))
    if [[ "$idle_s" -ge "$break_threshold" ]]; then
        record_break "$idle_s"
        return 0
    fi

    # 读取状态
    local last_break last_reminder current_level
    last_break="$(read_state_int last_break_epoch)"
    last_reminder="$(read_state_int last_reminder_epoch)"
    current_level="$(read_state_int escalation_level)"

    # 计算连续屏幕用时
    local elapsed=0
    if [[ "$last_break" -gt 0 ]]; then
        elapsed=$(( (now_s - last_break) / 60 ))
    fi

    # 判断新级别
    local new_level
    new_level="$(determine_level "$elapsed")"

    if [[ "$new_level" -le 0 ]]; then
        return 0
    fi

    # 同级别抑制
    if [[ "$new_level" -eq "$current_level" ]] && \
       [[ "$last_reminder" -gt 0 ]] && \
       [[ $(( now_s - last_reminder )) -lt "$SUPPRESS_SECONDS" ]]; then
        return 0
    fi

    # 发送
    fire_reminder "$new_level" "$elapsed"
    write_state_int escalation_level "$new_level"
    write_state_int last_reminder_epoch "$now_s"
}

# ── 状态查询 ──────────────────────────────────────────────
do_status() {
    local idle_s now_s
    idle_s="$(get_idle_seconds)"
    idle_s="${idle_s:-0}"
    now_s="$(date +%s)"

    local last_break last_reminder current_level interval_s break_s hard_limit
    last_break="$(read_state_int last_break_epoch)"
    last_reminder="$(read_state_int last_reminder_epoch)"
    current_level="$(read_state_int escalation_level)"
    interval_s="$INTERVAL_MINUTES"
    break_s="$BREAK_SECONDS"
    hard_limit="$DEFAULT_HARD_LIMIT_MINUTES"

    local elapsed=0
    if [[ "$last_break" -gt 0 ]]; then
        elapsed=$(( (now_s - last_break) / 60 ))
    fi

    local status_enabled="是"
    is_enabled || status_enabled="否"
    local status_dnd="否"
    is_in_dnd && status_dnd="是"

    cat <<EOF
═══════════════════════════════════════
  Vita 用眼提醒 — 当前状态
═══════════════════════════════════════
  模块状态:    ${status_enabled}
  免打扰时段:  ${status_dnd}
  提醒间隔:    ${interval_s} 分钟
  休息建议:    ${break_s} 秒
  硬限制阈值:  ${hard_limit} 分钟
───────────────────────────────────────
  当前空闲:    ${idle_s} 秒
  连续用眼:    ${elapsed} 分钟
  提醒级别:    ${current_level}  (0=无 / 1=初 / 2=加 / 3=强)
───────────────────────────────────────
  上次休息:    $( [[ "$last_break" -gt 0 ]] && date -r "$last_break" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "尚无记录" )
  上次提醒:    $( [[ "$last_reminder" -gt 0 ]] && date -r "$last_reminder" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "尚无记录" )
═══════════════════════════════════════
EOF
}

# ── 守护模式 ──────────────────────────────────────────────
do_daemon() {
    echo "Vita 用眼守护已启动 | 间隔: ${INTERVAL_MINUTES}min | 休息: ${BREAK_SECONDS}s | Ctrl-C 退出"
    log_message "INFO" "$MODULE" "daemon 启动 | interval=${INTERVAL_MINUTES} break=${BREAK_SECONDS}"

    local tick=0
    while true; do
        do_remind
        sleep 30                    # 每 30 秒检查一次
        tick=$(( tick + 1 ))
        # 每 10 分钟记录心跳
        if [[ $(( tick % 20 )) -eq 0 ]]; then
            local elapsed
            local last_break
            last_break="$(read_state_int last_break_epoch)"
            if [[ "$last_break" -gt 0 ]]; then
                elapsed=$(( ($(date +%s) - last_break) / 60 ))
            else
                elapsed=0
            fi
            log_message "DEBUG" "$MODULE" "daemon 心跳 | 连续用眼=${elapsed}min | 级别=$(read_state_int escalation_level)"
        fi
    done
}

# ── 入口 ──────────────────────────────────────────────────
case "$ACTION" in
    remind) do_remind ;;
    status) do_status ;;
    daemon) do_daemon ;;
    *)
        echo "[eye-care] 无效动作: $ACTION" >&2
        show_help
        exit 1
        ;;
esac
