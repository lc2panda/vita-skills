#!/usr/bin/env bash
# Input:  配置参数 / 系统时间 / 用户打卡记录 / 打榜API
# Output: 系统通知 / 打卡记录 / 打榜数据上报 / 日志
# Pos:   核心提醒模块之一，被 scheduler 调度，与打榜系统联动
#
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

set -euo pipefail

# ── 加载 common.sh ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SH="${SCRIPT_DIR}/lib/common.sh"
if [[ ! -f "${COMMON_SH}" ]]; then
    printf '[FATAL] 找不到 common.sh: %s\n' "${COMMON_SH}" >&2
    exit 1
fi
# shellcheck source=./lib/common.sh
source "${COMMON_SH}"

# ── 加载打榜客户端库 ─────────────────────────────────────────
LB_CLIENT="${SCRIPT_DIR}/lib/leaderboard-client.sh"
if [[ -f "${LB_CLIENT}" ]]; then
    # shellcheck source=./lib/leaderboard-client.sh
    source "${LB_CLIENT}"
else
    # 打榜库不存在时，提供占位函数确保脚本不崩溃
    lb_checkin() { return 0; }
    lb_get_rank() { echo '{"error":"打榜库未安装"}'; }
    lb_get_leaderboard() { echo '{"error":"打榜库未安装"}'; }
    lb_get_stats() { echo '{"error":"打榜库未安装"}'; }
    lb_register() { echo "[WARN] 打榜库未安装，跳过注册" >&2; return 0; }
    lb_get_user_id() { return 1; }
    lb_is_registered() { return 1; }
    lb_get_pending_count() { echo "0"; }
fi

# ── 模块常量 ────────────────────────────────────────────────────
readonly MODULE="tigang"
readonly STATE_FILE="${HOME}/.vita/state/tigang.json"

# 确保目录存在
_ensure_dir() { mkdir -p "$1" 2>/dev/null || true; }
_ensure_dir "$(dirname "$STATE_FILE")"

# ── 配置读取 ────────────────────────────────────────────────────

tigang_config() {
    local key="$1"
    local default="${2:-}"
    read_config "health-tigang.${key}" "${default}"
}

# ── 日期计算 ────────────────────────────────────────────────────

_date_diff_days() {
    local d1="$1" d2="$2" e1 e2
    if [[ "$(uname -s)" == "Darwin" ]]; then
        e1="$(date -j -f "%Y-%m-%d" "$d1" "+%s" 2>/dev/null || echo "0")"
        e2="$(date -j -f "%Y-%m-%d" "$d2" "+%s" 2>/dev/null || echo "0")"
    else
        e1="$(date -d "$d1" "+%s" 2>/dev/null || echo "0")"
        e2="$(date -d "$d2" "+%s" 2>/dev/null || echo "0")"
    fi
    echo $(( (e2 - e1) / 86400 ))
}

# 分阶段判定: 初学(第1-4周) / 进阶(第5周+)
stage_from_date() {
    local start_date="$1"
    if [[ -z "$start_date" ]]; then
        echo "beginner"; return
    fi
    local days weeks
    days="$(_date_diff_days "$start_date" "$(date '+%Y-%m-%d')")"
    (( days < 0 )) && days=0
    weeks=$(( days / 7 + 1 ))
    if (( weeks <= 4 )); then
        echo "beginner"
    else
        echo "advanced"
    fi
}

# 获取阶段参数: sets_per_day reps_per_set hold_min hold_max
stage_params() {
    case "$1" in
        beginner) echo "2|10|3|5"  ;;  # 2组/天, 10次/组, 保持3-5秒
        advanced) echo "3|15|5|10" ;;  # 3组/天, 15次/组, 保持5-10秒
        *)        echo "2|10|3|5"  ;;
    esac
}

day_number() {
    local sd="$1"
    [[ -z "$sd" ]] && { echo "?"; return; }
    local d
    d="$(_date_diff_days "$sd" "$(date '+%Y-%m-%d')")"
    echo $(( d + 1 ))
}

days_to_effect() {
    local sd="$1"
    [[ -z "$sd" ]] && { echo "?"; return; }
    local passed
    passed="$(_date_diff_days "$sd" "$(date '+%Y-%m-%d')")"
    local remain=$(( 49 - passed ))  # 7周中值
    (( remain < 0 )) && echo "0" || echo "$remain"
}

# ── JSON 状态读写（不含 jq 依赖） ───────────────────────────────

_json_get_str() {
    # 从单行 JSON 提取 key 对应的字符串值
    local json="$1" key="$2"
    echo "$json" | grep -o "\"${key}\":[[:space:]]*\"[^\"]*\"" 2>/dev/null \
        | head -1 | sed 's/.*"'"${key}"'"[[:space:]]*:[[:space:]]*"//; s/"$//'
}

_json_get_int() {
    local json="$1" key="$2"
    echo "$json" | grep -o "\"${key}\":[[:space:]]*[0-9]*" 2>/dev/null \
        | head -1 | sed 's/.*"'"${key}"'"[[:space:]]*:[[:space:]]*//'
}

_json_get_arr() {
    # 提取 "key":\[...\] 内容（极简匹配）
    local json="$1" key="$2"
    echo "$json" | grep -o "\"${key}\":[[:space:]]*\[[^]]*\]" 2>/dev/null \
        | head -1 | sed 's/.*"'"${key}"'"[[:space:]]*:[[:space:]]*//'
}

_load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo '{"start_date":"","streak":0,"max_streak":0,"total_sets":0,"total_days":0,"today":"","today_done":0,"checkins":[]}'
    fi
}

_save_state() {
    echo "$1" > "$STATE_FILE"
}

# ── 每日结算（日期变更时更新 streak） ──────────────────────────

daily_settle() {
    local state
    state="$(_load_state)"

    local prev_today
    prev_today="$(_json_get_str "$state" "today")"
    local now_today
    now_today="$(date '+%Y-%m-%d')"

    if [[ "$prev_today" == "$now_today" ]]; then
        echo "$state"
        return
    fi

    # 日期变更：检查昨天是否达标
    local yesterday_done streak max_streak total_days start_date stage
    yesterday_done="$(_json_get_int "$state" "today_done")"
    yesterday_done="${yesterday_done:-0}"
    streak="$(_json_get_int "$state" "streak")"; streak="${streak:-0}"
    max_streak="$(_json_get_int "$state" "max_streak")"; max_streak="${max_streak:-0}"
    total_days="$(_json_get_int "$state" "total_days")"; total_days="${total_days:-0}"
    start_date="$(_json_get_str "$state" "start_date")"
    stage="$(stage_from_date "$start_date")"
    local sets_per_day
    sets_per_day="$(echo "$(stage_params "$stage")" | cut -d'|' -f1)"

    if (( yesterday_done >= sets_per_day )) && [[ -n "$prev_today" ]]; then
        streak=$(( streak + 1 ))
        (( streak > max_streak )) && max_streak=$streak
        total_days=$(( total_days + 1 ))
    else
        streak=0
    fi

    cat <<JSONEOF
{"start_date":"${start_date}","streak":${streak},"max_streak":${max_streak},"total_sets":$(_json_get_int "$state" "total_sets"),"total_days":${total_days},"today":"${now_today}","today_done":0,"checkins":[]}
JSONEOF
}

# ── 消息文案 ────────────────────────────────────────────────────

message_for_session() {
    local session="$1" day="$2" remain="$3" streak="$4" sets="$5" reps="$6" hold_min="$7" hold_max="$8"

    local title="" body=""

    case "$session" in
        1)
            title="盆底肌训练时间"
            body="找个舒服的姿势，开始今天的练习吧～"
            ;;
        2)
            title="坚持就是胜利"
            body="第${day}天打卡，距离6-8周见效还有${remain}天"
            ;;
        3)
            title="睡前最后一组"
            body="连续打卡7天！盆底健康是终身投资"
            if (( streak % 7 != 0 )); then
                body="完成今天的训练，${reps}次 × ${hold_min}-${hold_max}秒，深呼吸放松～"
            fi
            ;;
        *)
            title="盆底肌训练时间"
            body="找个舒服的姿势，开始今天的练习吧～"
            ;;
    esac

    printf '%s|%s' "$title" "$body"
}

# ── 打榜上报 ────────────────────────────────────────────────────

report_leaderboard() {
    # 检查打榜是否启用
    local lb_enabled
    lb_enabled="$(tigang_config leaderboard_enabled "false")"
    [[ "$lb_enabled" != "true" ]] && return 0

    local user_id
    user_id="$(lb_get_user_id 2>/dev/null)" || { log_message "DEBUG" "$MODULE" "打榜用户未注册，跳过上报"; return 0; }

    local state today_done
    state="$(_load_state)"
    today_done="$(_json_get_int "$state" "today_done")"
    today_done="${today_done:-0}"

    local start_date stage params reps hold
    start_date="$(tigang_config start_date "")"
    stage="$(stage_from_date "$start_date")"
    params="$(stage_params "$stage")"
    reps="$(echo "$params" | cut -d'|' -f2)"
    hold="$(echo "$params" | cut -d'|' -f3)"

    lb_checkin "$user_id" "$today_done" "$reps" "$hold" 2>/dev/null || true
}

# ── 命令: init ──────────────────────────────────────────────────

cmd_init() {
    echo "=== 提肛锻炼提醒模块初始化 ==="
    echo ""

    local gender start_date reminder_times lb_enabled lb_display today
    today="$(date '+%Y-%m-%d')"

    printf '性别 (male/female/neutral) [neutral]: '
    read -r gender; gender="${gender:-neutral}"

    printf '开始日期 (YYYY-MM-DD) [%s]: ' "$today"
    read -r start_date; start_date="${start_date:-$today}"

    printf '提醒时间 (逗号分隔 HH:MM) [09:00,13:00,20:00]: '
    read -r reminder_times; reminder_times="${reminder_times:-09:00,13:00,20:00}"

    printf '是否参与全球打榜PK? (y/n) [y]: '
    read -r lb_enabled; lb_enabled="${lb_enabled:-y}"

    if [[ "$lb_enabled" == "y" || "$lb_enabled" == "Y" ]]; then
        lb_enabled="true"
        printf '打榜显示名称 [匿名战士]: '
        read -r lb_display; lb_display="${lb_display:-匿名战士}"

        # 调用打榜注册
        echo -n "  注册打榜账号..."
        local lb_uid
        lb_uid="$(lb_register "$lb_display" 2>/dev/null)" || true
        if [[ -n "$lb_uid" ]]; then
            echo " 已加入打榜 (ID: ${lb_uid})"
        else
            echo " 网络不通，将在后台重试"
        fi
    elif [[ "$lb_enabled" == "n" || "$lb_enabled" == "N" ]]; then
        lb_enabled="false"
        if declare -f lb_set_privacy_mode >/dev/null 2>&1; then
            lb_set_privacy_mode "true"
        fi
        echo "  已设置隐私模式，不参与打榜"
    fi

    # 写入状态
    cat > "$STATE_FILE" <<JSONEOF
{"start_date":"${start_date}","streak":0,"max_streak":0,"total_sets":0,"total_days":0,"today":"","today_done":0,"checkins":[]}
JSONEOF

    # 追加配置到 default.yaml
    local cfg="${PROJECT_CONFIG_DIR:-${CONFIG_DIR_DEFAULT}}/default.yaml"
    cat >> "$cfg" <<YAMLEOF

# ── 提肛锻炼提醒模块 ──
health-tigang:
  gender: ${gender}
  start_date: "${start_date}"
  reminder_times: "${reminder_times}"
  leaderboard_enabled: ${lb_enabled}
YAMLEOF

    log_message "INFO" "$MODULE" "初始化完成: gender=${gender} start_date=${start_date} leaderboard=${lb_enabled}"
    echo ""
    echo "=== 初始化完成 ==="
    echo "状态文件: $STATE_FILE"
    echo "配置文件: $cfg"
}

# ── 命令: remind ────────────────────────────────────────────────

cmd_remind() {
    local start_date gender reminder_times
    start_date="$(tigang_config start_date "")"
    gender="$(tigang_config gender "neutral")"
    reminder_times="$(tigang_config reminder_times "09:00,13:00,20:00")"

    if [[ -z "$start_date" ]]; then
        log_message "WARN" "$MODULE" "未配置开始日期，请先运行 init"
        return 1
    fi

    # 智能抑制
    if is_quiet_hours || is_screen_locked || is_in_meeting; then
        log_message "DEBUG" "$MODULE" "当前环境不适合提醒，跳过"
        return 0
    fi

    # 每日结算
    local state
    state="$(daily_settle)"
    _save_state "$state"

    local stage
    stage="$(stage_from_date "$start_date")"
    local sets_per_day reps_per_set hold_min hold_max
    sets_per_day="$(echo "$(stage_params "$stage")" | cut -d'|' -f1)"
    reps_per_set="$(echo "$(stage_params "$stage")" | cut -d'|' -f2)"
    hold_min="$(echo "$(stage_params "$stage")" | cut -d'|' -f3)"
    hold_max="$(echo "$(stage_params "$stage")" | cut -d'|' -f4)"

    # 匹配当前时间到提醒时段
    local now_hhmm now_epoch session
    now_hhmm="$(date '+%H:%M')"
    now_epoch="$(date '+%s')"
    session=0
    local IFS=',' slots slot idx=1 found_slot=""
    read -ra slots <<< "$reminder_times"
    for slot in "${slots[@]}"; do
        slot="$(echo "$slot" | xargs)"
        local slot_epoch=0
        if [[ "$(uname -s)" == "Darwin" ]]; then
            slot_epoch="$(date -j -f "%Y-%m-%d %H:%M" "$(date '+%Y-%m-%d') ${slot}" "+%s" 2>/dev/null || echo "0")"
        else
            slot_epoch="$(date -d "$(date '+%Y-%m-%d') ${slot}" "+%s" 2>/dev/null || echo "0")"
        fi
        local diff=$(( now_epoch - slot_epoch ))
        if (( diff >= -300 && diff <= 300 )); then
            session=$idx; found_slot="$slot"; break
        fi
        idx=$(( idx + 1 ))
    done

    if (( session == 0 )); then
        log_message "DEBUG" "$MODULE" "不在提醒窗口内"
        return 0
    fi

    # 检查是否已全部完成
    local today_done
    today_done="$(_json_get_int "$state" "today_done")"
    today_done="${today_done:-0}"
    if (( today_done >= sets_per_day )); then
        log_message "INFO" "$MODULE" "今日全部完成 (${today_done}/${sets_per_day})"
        return 0
    fi

    # 检查该时段是否已打卡
    local checkins
    checkins="$(_json_get_arr "$state" "checkins")"
    if echo "$checkins" | grep -q "\"${found_slot}\"" 2>/dev/null; then
        log_message "DEBUG" "$MODULE" "时段 ${found_slot} 已打卡"
        return 0
    fi

    # 生成通知
    local day remain streak
    day="$(day_number "$start_date")"
    remain="$(days_to_effect "$start_date")"
    streak="$(_json_get_int "$state" "streak")"; streak="${streak:-0}"

    local msg
    msg="$(message_for_session "$session" "$day" "$remain" "$streak" "$sets_per_day" "$reps_per_set" "$hold_min" "$hold_max")"

    local title body
    title="$(echo "$msg" | cut -d'|' -f1)"
    body="$(echo "$msg" | cut -d'|' -f2)"

    # 连续打卡7天特殊文案
    if (( streak > 0 && streak % 7 == 0 )); then
        title="连续打卡 ${streak} 天里程碑"
        body="你的坚持正在重塑盆底健康。盆底健康是终身投资——继续加油！"
    fi

    send_notification "$title" "$body" "default"
    log_message "REMINDER" "$MODULE" "提醒已发送: slot=${found_slot} session=${session}/${sets_per_day} stage=${stage} day=${day} streak=${streak}"
}

# ── 命令: done ──────────────────────────────────────────────────

cmd_done() {
    local sets="${1:-1}"

    local state
    state="$(daily_settle)"

    local today_done total_sets start_date
    today_done="$(_json_get_int "$state" "today_done")"; today_done="${today_done:-0}"
    total_sets="$(_json_get_int "$state" "total_sets")"; total_sets="${total_sets:-0}"
    start_date="$(_json_get_str "$state" "start_date")"

    local new_done=$(( today_done + sets ))
    local new_total=$(( total_sets + sets ))
    local now="$(date '+%H:%M')"

    # 更新 checkins 数组
    local old_checkins
    old_checkins="$(_json_get_arr "$state" "checkins")"
    local new_checkins
    if [[ -n "$old_checkins" && "$old_checkins" != "[]" ]]; then
        # 非空数组：追加到现有元素后
        old_checkins="${old_checkins%]}"
        new_checkins="${old_checkins},\"${now}\"]"
    else
        new_checkins="[\"${now}\"]"
    fi

    cat > "$STATE_FILE" <<JSONEOF
{"start_date":"${start_date}","streak":$(_json_get_int "$state" "streak"),"max_streak":$(_json_get_int "$state" "max_streak"),"total_sets":${new_total},"total_days":$(_json_get_int "$state" "total_days"),"today":"$(date '+%Y-%m-%d')","today_done":${new_done},"checkins":${new_checkins}}
JSONEOF

    local stage sets_per_day
    stage="$(stage_from_date "$start_date")"
    sets_per_day="$(echo "$(stage_params "$stage")" | cut -d'|' -f1)"

    log_message "INFO" "$MODULE" "打卡: +${sets}组 → 今日 ${new_done}/${sets_per_day}"

    report_leaderboard

    echo "打卡成功！今日已完成 ${new_done}/${sets_per_day} 组"
    if (( new_done >= sets_per_day )); then
        local streak
        streak="$(_json_get_int "$(_load_state)" "streak")"
        echo "今日目标达成！连续打卡 ${streak} 天"
    fi
}

# ── 命令: status ────────────────────────────────────────────────

cmd_status() {
    local state
    state="$(daily_settle)"
    _save_state "$state"

    local start_date
    start_date="$(tigang_config start_date "")"
    local stage
    stage="$(stage_from_date "$start_date")"

    local sets_per_day reps_per_set hold_min hold_max
    sets_per_day="$(echo "$(stage_params "$stage")" | cut -d'|' -f1)"
    reps_per_set="$(echo "$(stage_params "$stage")" | cut -d'|' -f2)"
    hold_min="$(echo "$(stage_params "$stage")" | cut -d'|' -f3)"
    hold_max="$(echo "$(stage_params "$stage")" | cut -d'|' -f4)"

    local streak max_streak total_days total_sets today_done
    streak="$(_json_get_int "$state" "streak")"; streak="${streak:-0}"
    max_streak="$(_json_get_int "$state" "max_streak")"; max_streak="${max_streak:-0}"
    total_days="$(_json_get_int "$state" "total_days")"; total_days="${total_days:-0}"
    total_sets="$(_json_get_int "$state" "total_sets")"; total_sets="${total_sets:-0}"
    today_done="$(_json_get_int "$state" "today_done")"; today_done="${today_done:-0}"

    local day remain
    day="$(day_number "$start_date")"
    remain="$(days_to_effect "$start_date")"

    echo ""
    echo "=== 提肛锻炼状态 ==="
    printf "  开始日期:     %s\n" "$start_date"
    printf "  训练阶段:     %s\n" "$stage"
    printf "  每天目标:     %s 组 × %s 次, 保持 %s-%s 秒\n" "$sets_per_day" "$reps_per_set" "$hold_min" "$hold_max"
    echo "  ─────────────────────────"
    printf "  已坚持天数:   %s\n" "$day"
    printf "  距初见成效:   %s 天\n" "$remain"
    printf "  今日已完成:   %s/%s 组\n" "$today_done" "$sets_per_day"
    printf "  连续打卡:     %s 天\n" "$streak"
    printf "  最长连续:     %s 天\n" "$max_streak"
    printf "  累计打卡天数: %s\n" "$total_days"
    printf "  累计完成组数: %s\n" "$total_sets"
    echo ""

    # ── 打榜排名信息 ──
    if lb_is_registered; then
        local lb_enabled
        lb_enabled="$(tigang_config leaderboard_enabled "false")"
        if [[ "$lb_enabled" == "true" ]]; then
            local rank_info rank_text percentile
            rank_info="$(lb_get_rank "$(lb_get_user_id)" 2>/dev/null)" || true
            rank_text="$(_lb_json_get_int "$rank_info" "rank")"
            if [[ -n "$rank_text" ]] && [[ "$rank_text" != "null" ]]; then
                percentile="$(_lb_json_get_int "$rank_info" "percentile")"
                local score
                score="$(_lb_json_get_int "$rank_info" "score")"
                echo "  ═══ 打榜排名 ═══"
                printf "  当前排名:     #%s\n" "$rank_text"
                [[ -n "$score" ]] && [[ "$score" != "null" ]] && printf "  积分:         %s\n" "$score"
                [[ -n "$percentile" ]] && [[ "$percentile" != "null" ]] && printf "  超越:         %s%% 玩家\n" "$percentile"
            fi
            # 检查离线队列
            local pending_count
            pending_count="$(lb_get_pending_count)"
            if [[ "$pending_count" != "0" ]]; then
                printf "  离线缓存:     %s 条待同步\n" "$pending_count"
            fi
        fi
    fi
    echo ""
}

# ── 命令: leaderboard ──────────────────────────────────────────

cmd_leaderboard() {
    local type="${1:-weekly}"

    case "$type" in
        weekly|monthly|alltime) ;;
        *)
            echo "用法: tigang.sh --leaderboard [weekly|monthly|alltime]"
            return 1
            ;;
    esac

    echo "=== 提肛打榜 (${type}) ==="
    echo ""

    # 全局统计
    local stats total_users total_checkins
    stats="$(lb_get_stats 2>/dev/null)" || true
    total_users="$(_lb_json_get_int "$stats" "total_users")"
    total_checkins="$(_lb_json_get_int "$stats" "total_checkins")"
    if [[ -n "$total_users" ]] && [[ "$total_users" != "null" ]]; then
        printf "全球参与者: %s 人 | 总打卡: %s 次\n" "$total_users" "${total_checkins:-?}"
    fi
    echo ""

    # 排行榜
    local board entries
    board="$(lb_get_leaderboard "$type" 2>/dev/null)" || true

    # 解析排行榜条目：找到 "entries" 数组内的对象，提取 rank/display_name/score/sets
    local entries_str
    entries_str="$(echo "$board" | grep -o '"rank":[[:space:]]*[0-9]*\|"display_name":[[:space:]]*"[^"]*"\|"score":[[:space:]]*[0-9]*\|"sets":[[:space:]]*[0-9]*' 2>/dev/null)" || true

    if [[ -z "$entries_str" ]]; then
        echo "  排行榜数据暂不可用"
        echo ""
        return 0
    fi

    # 简单表格输出
    printf "  %-4s %-16s %-8s %-6s\n" "排名" "昵称" "积分" "组数"
    printf "  %-4s %-16s %-8s %-6s\n" "----" "----------------" "--------" "------"

    local rank disp_name score sets
    while IFS= read -r line; do
        case "$line" in
            *'"rank"'*)
                rank="$(echo "$line" | grep -o '[0-9]*')"
                ;;
            *'"display_name"'*)
                disp_name="$(echo "$line" | sed 's/.*"display_name"[[:space:]]*:[[:space:]]*"//; s/"$//')"
                ;;
            *'"score"'*)
                score="$(echo "$line" | grep -o '[0-9]*')"
                ;;
            *'"sets"'*)
                sets="$(echo "$line" | grep -o '[0-9]*')"
                if [[ -n "$rank" ]]; then
                    printf "  %-4s %-16s %-8s %-6s\n" "#${rank}" "${disp_name:-?}" "${score:-0}" "${sets:-0}"
                    rank="" disp_name="" score="" sets=""
                fi
                ;;
        esac
    done <<< "$entries_str"

    echo ""
    echo "提示: 使用 --leaderboard weekly|monthly|alltime 切换周期"
    return 0
}

# ── 命令: daemon ────────────────────────────────────────────────

cmd_daemon() {
    if ! acquire_lock; then
        log_info "tigang daemon 已在运行"
        return 1
    fi

    log_info "tigang daemon 启动 (PID: $$)"

    setup_signal_handlers "log_info 'tigang daemon 退出'" ""

    local reminder_times interval
    reminder_times="$(tigang_config reminder_times "09:00,13:00,20:00")"
    # 检查间隔 60 秒
    interval=60

    while true; do
        # 检查当前时间是否匹配提醒时段
        local now_hhmm
        now_hhmm="$(date '+%H:%M')"
        local IFS=',' slots slot
        read -ra slots <<< "$reminder_times"
        for slot in "${slots[@]}"; do
            slot="$(echo "$slot" | xargs)"
            if [[ "$now_hhmm" == "$slot" ]]; then
                cmd_remind
                break
            fi
        done
        sleep "$interval"
    done
}

# ── 帮助 ────────────────────────────────────────────────────────

cmd_help() {
    cat <<HELPEOF
提肛锻炼提醒模块 — 用法

  tigang.sh <mode> [options]

模式:
  --remind          发送今日提醒通知（精确到时段）
  --done [N]        确认完成 N 组（默认 1 组）
  --status          查看训练状态与打榜排名
  --daemon          守护进程模式（常驻后台）
  --init            初始化配置（含打榜注册）
  --leaderboard [周期] 查看打榜排行 (weekly/monthly/alltime)
  --help            显示此帮助

示例:
  tigang.sh --init
  tigang.sh --remind
  tigang.sh --done
  tigang.sh --done 2
  tigang.sh --status
  tigang.sh --daemon
  tigang.sh --leaderboard
  tigang.sh --leaderboard monthly

调度:
  crontab 示例（每时段精确调用）:
    0 9 * * *  /path/to/tigang.sh --remind
    0 13 * * * /path/to/tigang.sh --remind
    0 20 * * * /path/to/tigang.sh --remind

  或使用 daemon 模式（推荐）:
    tigang.sh --daemon &

数据位置:
  配置文件: ${PROJECT_CONFIG_DIR:-${CONFIG_DIR_DEFAULT}}/default.yaml
  状态文件: ${STATE_FILE}
  日志文件: $(get_log_file "$MODULE")

分阶段方案:
  初学者 (第1-4周):  2组/天, 10次/组, 保持3-5秒
  进阶者 (第5周+):  3组/天, 15次/组, 保持5-10秒
HELPEOF
}

# ── 主入口 ──────────────────────────────────────────────────────

main() {
    case "${1:-}" in
        --init|init)
            cmd_init
            ;;
        --remind|remind|notify)
            cmd_remind
            ;;
        --done|done)
            shift
            cmd_done "${1:-1}"
            ;;
        --status|status)
            cmd_status
            ;;
        --daemon|daemon)
            cmd_daemon
            ;;
        --leaderboard|leaderboard|--lb)
            shift
            cmd_leaderboard "${1:-weekly}"
            ;;
        --help|help|-h|"")
            cmd_help
            ;;
        --test-notify|test-notify)
            local start_date gender
            start_date="$(tigang_config start_date "$(date '+%Y-%m-%d')")"
            gender="$(tigang_config gender "neutral")"
            local stage sets_per_day reps hold_min hold_max
            stage="$(stage_from_date "$start_date")"
            sets_per_day="$(echo "$(stage_params "$stage")" | cut -d'|' -f1)"
            reps="$(echo "$(stage_params "$stage")" | cut -d'|' -f2)"
            hold_min="$(echo "$(stage_params "$stage")" | cut -d'|' -f3)"
            hold_max="$(echo "$(stage_params "$stage")" | cut -d'|' -f4)"
            local day remain streak
            day="$(day_number "$start_date")"
            remain="$(days_to_effect "$start_date")"
            streak="$(_json_get_int "$(_load_state)" "streak")"; streak="${streak:-0}"
            local msg
            msg="$(message_for_session "1" "$day" "$remain" "$streak" "$sets_per_day" "$reps" "$hold_min" "$hold_max")"
            local title body
            title="$(echo "$msg" | cut -d'|' -f1)"
            body="$(echo "$msg" | cut -d'|' -f2)"
            echo "发送测试通知..."
            printf '  标题: %s\n' "$title"
            printf '  内容: %s\n' "$body"
            send_notification "$title" "$body" "default"
            echo "测试通知已发送"
            ;;
        *)
            log_error "未知模式: ${1:-}"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
