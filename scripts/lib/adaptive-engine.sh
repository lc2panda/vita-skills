#!/usr/bin/env bash
# Input:  activity records from state files / reminder & response events
# Output: score level (L1-L4), adjusted interval, trend, churn status
# Pos:    scheduler engine core — all modules query adaptive engine before triggering reminders
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的md。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ── 路径常量 ─────────────────────────────────────────────────
readonly ADAPTIVE_STATE_FILE="${VITA_STATE_DIR:-$STATE_DIR_DEFAULT}/adaptive.json"
readonly ADAPTIVE_MAX_HISTORY_DAYS=7

# ═══════════════════════════════════════════════════════════════
# 内部辅助：JSON 状态文件读写（纯 bash + python3，与 common.sh 一致）
# ═══════════════════════════════════════════════════════════════

# 初始化自适应引擎状态文件
_init_adaptive_state() {
    _ensure_dir "$(dirname "$ADAPTIVE_STATE_FILE")"
    if [[ ! -f "$ADAPTIVE_STATE_FILE" ]]; then
        local today
        today="$(date '+%Y-%m-%d')"
        python3 -c "
import json, sys
state = {
    'modules': {
        'sedentary':  {'reminded': 0, 'responded': 0, 'delay_total_min': 0, 'quality_total': 0, 'quality_count': 0},
        'eye_care':   {'reminded': 0, 'responded': 0, 'delay_total_min': 0, 'quality_total': 0, 'quality_count': 0},
        'hydration':  {'reminded': 0, 'responded': 0, 'delay_total_min': 0, 'quality_total': 0, 'quality_count': 0},
        'kegel':      {'reminded': 0, 'responded': 0, 'delay_total_min': 0, 'quality_total': 0, 'quality_count': 0}
    },
    'today_date': '$today',
    'streak': {'current': 0, 'last_active_date': ''},
    'history': [],
    'churn': {'silent_days': 0, 'status': 'active'},
    'skip_patterns': {}
}
json.dump(state, sys.stdout, indent=2)
" > "$ADAPTIVE_STATE_FILE"
        log_debug "adaptive: 初始化状态文件 $ADAPTIVE_STATE_FILE"
    fi
}

# 从 adaptive.json 读取单个值（点号路径，如 modules.sedentary.reminded）
_json_read() {
    local path="$1"
    local default="${2:-0}"
    if [[ ! -f "$ADAPTIVE_STATE_FILE" ]]; then
        echo "$default"
        return 0
    fi
    python3 -c "
import json, sys
try:
    with open('$ADAPTIVE_STATE_FILE') as f:
        data = json.load(f)
    parts = '$path'.split('.')
    val = data
    for p in parts:
        val = val.get(p, {}) if isinstance(val, dict) else val
    if val is None or val == {}:
        print('$default')
    else:
        print(val)
except Exception:
    print('$default')
" 2>/dev/null || echo "$default"
}

# 写入 adaptive.json 单个值（点号路径）
_json_write() {
    local path="$1"
    local value="$2"
    _init_adaptive_state
    python3 -c "
import json, sys
with open('$ADAPTIVE_STATE_FILE') as f:
    data = json.load(f)
parts = '$path'.split('.')
container = data
for p in parts[:-1]:
    if p not in container:
        container[p] = {}
    container = container[p]
try:
    val = json.loads('$value')
except Exception:
    val = '$value'
container[parts[-1]] = val
with open('$ADAPTIVE_STATE_FILE', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
    log_debug "adaptive: _json_write $path = $value"
}

# ── 日期轮转检查 ─────────────────────────────────────────────
_rotate_if_new_day() {
    local today
    today="$(date '+%Y-%m-%d')"
    local stored_date
    stored_date="$(_json_read "today_date" "")"

    if [[ "$stored_date" != "$today" ]]; then
        log_debug "adaptive: 检测到新的一天 ($stored_date → $today)，执行日轮转"
        python3 -c "
import json, sys, math
from datetime import datetime

today = '$(date '+%Y-%m-%d')'
with open('$ADAPTIVE_STATE_FILE') as f:
    data = json.load(f)

old_date = data.get('today_date', '')

# 内部函数：计算综合评分
def _compute_daily_score(d):
    m = d.get('modules', {})
    total_reminded = sum(x.get('reminded', 0) for x in m.values())
    total_responded = sum(x.get('responded', 0) for x in m.values())
    total_delay = sum(x.get('delay_total_min', 0) for x in m.values())
    q_total = sum(x.get('quality_total', 0) for x in m.values())
    q_count = sum(x.get('quality_count', 0) for x in m.values())

    cr = 50
    if total_reminded > 0:
        rate = total_responded / total_reminded
        cr = int(min(100, rate * 100))

    rs = 50
    if total_responded > 0:
        avg_delay = total_delay / total_responded
        rs = max(0, 100 - int((avg_delay / 30.0) * 100))

    streak = d.get('streak', {}).get('current', 0)
    if streak <= 0:
        sd = 0
    elif streak == 1:
        sd = 20
    else:
        sd = int(min(100, 20 + 80 * math.log(streak) / math.log(365)))

    qs = 50
    if q_count > 0:
        qs = int((q_total / q_count) * 100)

    sp = 100
    skip_data = d.get('skip_patterns', {})
    penalty = 0
    for mod, slots in skip_data.items():
        for slot, count in slots.items():
            if count >= 3:
                penalty += 5 * min(2, count // 3)
    sp = max(0, 100 - penalty)

    return cr * 0.30 + rs * 0.25 + sd * 0.20 + qs * 0.15 + sp * 0.10

def _score_to_level(score):
    if score >= 80: return 'L4'
    elif score >= 60: return 'L3'
    elif score >= 40: return 'L2'
    else: return 'L1'

# 1. 计算今日总分并追加到历史
total_score = _compute_daily_score(data)
data.setdefault('history', []).append({
    'date': old_date if old_date else today,
    'score': round(total_score, 1),
    'level': _score_to_level(total_score)
})
# 只保留最近 7 天
seen = set()
trimmed = []
for h in reversed(data['history']):
    d = h.get('date','')
    if d not in seen:
        seen.add(d)
        trimmed.insert(0, h)
    if len(seen) >= 7:
        break
data['history'] = trimmed

# 2. 更新 streak
had_any_response = any(
    m.get('responded', 0) > 0
    for m in data.get('modules', {}).values()
)
if had_any_response:
    if data['streak']['last_active_date'] == old_date or data['streak']['last_active_date'] == '':
        data['streak']['current'] += 1
    elif old_date and data['streak']['last_active_date']:
        last = datetime.strptime(data['streak']['last_active_date'], '%Y-%m-%d')
        old = datetime.strptime(old_date, '%Y-%m-%d')
        if (old - last).days == 1:
            data['streak']['current'] += 1
        else:
            data['streak']['current'] = 1
    data['streak']['last_active_date'] = old_date if old_date else today
else:
    data['churn']['silent_days'] = data.get('churn', {}).get('silent_days', 0) + 1
    if data['churn']['silent_days'] >= 7:
        data['churn']['status'] = 'silent'
    elif data['churn']['silent_days'] >= 5:
        data['churn']['status'] = 'paused'
    elif data['churn']['silent_days'] >= 3:
        data['churn']['status'] = 'warning'

if had_any_response and data['churn'].get('silent_days', 0) > 0:
    data['churn']['silent_days'] = 0
    data['churn']['status'] = 'active'

# 3. 重置今日模块计数
for m in data.get('modules', {}).values():
    m['reminded'] = 0
    m['responded'] = 0
    m['delay_total_min'] = 0
    m['quality_total'] = 0
    m['quality_count'] = 0

data['today_date'] = today
with open('$ADAPTIVE_STATE_FILE', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || true
    fi
}

# ═══════════════════════════════════════════════════════════════
# 公开 API：事件记录
# ═══════════════════════════════════════════════════════════════

# 记录一次提醒已发送
# Usage: record_reminder "sedentary"
record_reminder() {
    local module="${1:-sedentary}"
    _init_adaptive_state
    _rotate_if_new_day
    local current
    current="$(_json_read "modules.${module}.reminded" 0)"
    _json_write "modules.${module}.reminded" "$(( current + 1 ))"
    log_debug "adaptive: record_reminder ${module} → $(( current + 1 ))"
}

# 记录一次用户响应（完成了提醒对应的动作）
# Usage: record_response "sedentary" [delay_seconds] [quality_0_to_1]
record_response() {
    local module="${1:-sedentary}"
    local delay_seconds="${2:-0}"
    local quality="${3:-1.0}"

    _init_adaptive_state
    _rotate_if_new_day

    local responded
    responded="$(_json_read "modules.${module}.responded" 0)"
    _json_write "modules.${module}.responded" "$(( responded + 1 ))"

    local delay_min
    delay_min=$(python3 -c "print(int($delay_seconds / 60))" 2>/dev/null || echo "0")
    local total_delay
    total_delay="$(_json_read "modules.${module}.delay_total_min" 0)"
    _json_write "modules.${module}.delay_total_min" "$(( total_delay + delay_min ))"

    local q_total q_count
    q_total="$(_json_read "modules.${module}.quality_total" 0)"
    q_count="$(_json_read "modules.${module}.quality_count" 0)"
    python3 -c "
import json, sys
with open('$ADAPTIVE_STATE_FILE') as f:
    data = json.load(f)
data['modules']['${module}']['quality_total'] = ${q_total} + float('${quality}')
data['modules']['${module}']['quality_count'] = ${q_count} + 1
with open('$ADAPTIVE_STATE_FILE', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || true

    local silent_days
    silent_days="$(_json_read "churn.silent_days" 0)"
    if (( silent_days > 0 )); then
        _json_write "churn.silent_days" 0
        _json_write "churn.status" '"active"'
    fi

    log_debug "adaptive: record_response ${module} delay=${delay_seconds}s quality=${quality}"
}

# 记录一次提醒被跳过（用于 skip_pattern 分析）
# Usage: record_skip "sedentary" "09:00"
record_skip() {
    local module="${1:-sedentary}"
    local time_slot="${2:-}"
    _init_adaptive_state

    if [[ -z "$time_slot" ]]; then
        time_slot="$(date '+%H:00')"
    fi

    python3 -c "
import json, sys
with open('$ADAPTIVE_STATE_FILE') as f:
    data = json.load(f)
sp = data.setdefault('skip_patterns', {}).setdefault('$module', {})
sp['$time_slot'] = sp.get('$time_slot', 0) + 1
data['skip_patterns']['$module'] = sp
with open('$ADAPTIVE_STATE_FILE', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || true

    log_debug "adaptive: record_skip ${module} @ ${time_slot}"
}

# ═══════════════════════════════════════════════════════════════
# 内部：5 维忠诚度评分计算
# ═══════════════════════════════════════════════════════════════

# 维度1：打卡率 (30%) — 实际响应次数 / 提醒次数
_dim_checkin_rate() {
    python3 -c "
import json, sys
try:
    with open('$ADAPTIVE_STATE_FILE') as f:
        data = json.load(f)
except Exception:
    print('50')
    sys.exit(0)

modules = data.get('modules', {})
total_reminded = sum(m.get('reminded', 0) for m in modules.values())
total_responded = sum(m.get('responded', 0) for m in modules.values())

if total_reminded == 0:
    print('50')
else:
    rate = total_responded / total_reminded
    print(int(min(100, rate * 100)))
" 2>/dev/null || echo "50"
}

# 维度2：响应速度 (25%) — 平均延迟越短分越高
_dim_response_speed() {
    python3 -c "
import json, sys
try:
    with open('$ADAPTIVE_STATE_FILE') as f:
        data = json.load(f)
except Exception:
    print('50')
    sys.exit(0)

modules = data.get('modules', {})
total_responded = sum(m.get('responded', 0) for m in modules.values())
total_delay = sum(m.get('delay_total_min', 0) for m in modules.values())

if total_responded == 0:
    print('50')
else:
    avg_delay = total_delay / total_responded
    score = max(0, 100 - (avg_delay / 30.0) * 100)
    print(int(score))
" 2>/dev/null || echo "50"
}

# 维度3：连续打卡天数 (20%) — logarithmic scaling
_dim_streak_days() {
    local streak
    streak="$(_json_read "streak.current" 0)"
    python3 -c "
import math, sys
streak = int($streak)
if streak <= 0:
    print('0')
elif streak == 1:
    print('20')
else:
    score = 20 + 80 * math.log(streak) / math.log(365)
    print(int(min(100, score)))
" 2>/dev/null || echo "0"
}

# 维度4：完成质量 (15%) — 是否按推荐完成
_dim_quality_score() {
    python3 -c "
import json, sys
try:
    with open('$ADAPTIVE_STATE_FILE') as f:
        data = json.load(f)
except Exception:
    print('50')
    sys.exit(0)

modules = data.get('modules', {})
q_total = sum(m.get('quality_total', 0) for m in modules.values())
q_count = sum(m.get('quality_count', 0) for m in modules.values())

if q_count == 0:
    print('50')
else:
    avg_quality = q_total / q_count
    print(int(avg_quality * 100))
" 2>/dev/null || echo "50"
}

# 维度5：规律跳过扣分 (10%) — 检测特定时段的持续跳过模式
_dim_skip_pattern() {
    python3 -c "
import json, sys
try:
    with open('$ADAPTIVE_STATE_FILE') as f:
        data = json.load(f)
except Exception:
    print('100')
    sys.exit(0)

sp = data.get('skip_patterns', {})
if not sp:
    print('100')
    sys.exit(0)

penalty = 0
for module, slots in sp.items():
    for slot, count in slots.items():
        if count >= 3:
            penalty += 5 * min(2, count // 3)

print(max(0, 100 - penalty))
" 2>/dev/null || echo "100"
}

# ═══════════════════════════════════════════════════════════════
# 核心 API：评分与等级
# ═══════════════════════════════════════════════════════════════

# 计算 5 维加权综合评分 (0-100)
# Usage: score=$(get_score)
get_score() {
    _init_adaptive_state
    _rotate_if_new_day

    local checkin_rate response_speed streak_days quality_score skip_pattern
    checkin_rate="$(_dim_checkin_rate)"
    response_speed="$(_dim_response_speed)"
    streak_days="$(_dim_streak_days)"
    quality_score="$(_dim_quality_score)"
    skip_pattern="$(_dim_skip_pattern)"

    local weighted
    weighted=$(python3 -c "
cr = float($checkin_rate)
rs = float($response_speed)
sd = float($streak_days)
qs = float($quality_score)
sp = float($skip_pattern)
score = cr * 0.30 + rs * 0.25 + sd * 0.20 + qs * 0.15 + sp * 0.10
print(int(round(score)))
" 2>/dev/null || echo "50")

    log_debug "adaptive: get_score → cr=${checkin_rate} rs=${response_speed} sd=${streak_days} qs=${quality_score} sp=${skip_pattern} → ${weighted}"
    echo "$weighted"
}

# 将评分映射为等级
# Usage: level=$(get_level)
get_level() {
    local s
    s="$(get_score)"
    if (( s >= 80 )); then
        echo "L4"
    elif (( s >= 60 )); then
        echo "L3"
    elif (( s >= 40 )); then
        echo "L2"
    else
        echo "L1"
    fi
}

# ═══════════════════════════════════════════════════════════════
# 间隔调整矩阵 V2（4模块 × 4等级）
# ═══════════════════════════════════════════════════════════════

# 调整提醒间隔（秒）
# Usage: adjusted=$(adj_interval "sedentary" 1800)
adj_interval() {
    local module="${1:-sedentary}"
    local default_interval="${2:-1800}"
    local level
    level="$(get_level)"

    local adjusted
    case "$level" in
        L4)
            adjusted=$(python3 -c "print(int($default_interval * 1.05))" 2>/dev/null || echo "$default_interval")
            ;;
        L3)
            adjusted="$default_interval"
            ;;
        L2)
            adjusted=$(python3 -c "print(int($default_interval * 0.85))" 2>/dev/null || echo $(( default_interval * 85 / 100 )))
            ;;
        L1)
            adjusted=$(python3 -c "print(int($default_interval * 0.70))" 2>/dev/null || echo $(( default_interval * 70 / 100 )))
            ;;
        *)
            adjusted="$default_interval"
            ;;
    esac

    log_debug "adaptive: adj_interval ${module} default=${default_interval}s level=${level} → ${adjusted}s"
    echo "$adjusted"
}

# 获取消息紧迫度等级（用于低分场景增加文案强度）
# Usage: urgency=$(get_urgency)
get_urgency() {
    local level
    level="$(get_level)"
    case "$level" in
        L4|L3) echo "normal" ;;
        L2)    echo "strong" ;;
        L1)    echo "urgent" ;;
        *)     echo "normal" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
# 流失预警
# ═══════════════════════════════════════════════════════════════

# 获取流失状态
# Usage: status=$(get_churn_status)
get_churn_status() {
    _init_adaptive_state
    _rotate_if_new_day
    _json_read "churn.status" '"active"' | tr -d '"'
}

# 获取连续无响应天数
get_silent_days() {
    _init_adaptive_state
    _json_read "churn.silent_days" 0
}

# 检查是否应触发流失预警（返回码：0 = 应预警）
check_churn_warning() {
    local status
    status="$(get_churn_status)"
    case "$status" in
        warning|paused|silent) return 0 ;;
        *) return 1 ;;
    esac
}

# 检查是否进入静默模式
is_silent_mode() {
    local status
    status="$(get_churn_status)"
    [[ "$status" == "silent" ]] && return 0 || return 1
}

# 检查是否建议暂停
is_paused_mode() {
    local status
    status="$(get_churn_status)"
    [[ "$status" == "paused" ]] && return 0 || return 1
}

# ═══════════════════════════════════════════════════════════════
# 趋势分析
# ═══════════════════════════════════════════════════════════════

# 获取近 7 天评分趋势
# Usage: trend=$(get_trend)
get_trend() {
    _init_adaptive_state
    _rotate_if_new_day

    python3 -c "
import json, sys
try:
    with open('$ADAPTIVE_STATE_FILE') as f:
        data = json.load(f)
except Exception:
    print('stable')
    sys.exit(0)

history = data.get('history', [])
if len(history) < 3:
    print('stable')
    sys.exit(0)

recent = sorted(history, key=lambda x: x.get('date', ''))[-7:]
scores = [h.get('score', 0) for h in recent if h.get('score') is not None]

if len(scores) < 3:
    print('stable')
    sys.exit(0)

n = len(scores)
first_half = sum(scores[:max(1, n//3)]) / max(1, n//3)
last_half = sum(scores[-max(1, n//3):]) / max(1, n//3)

diff = last_half - first_half
if diff > 5:
    print('rising')
elif diff < -5:
    print('falling')
else:
    print('stable')
" 2>/dev/null || echo "stable"
}

# 获取最近 7 天的历史评分数组（空格分隔）
get_history_scores() {
    _init_adaptive_state
    python3 -c "
import json, sys
try:
    with open('$ADAPTIVE_STATE_FILE') as f:
        data = json.load(f)
except Exception:
    print('')
    sys.exit(0)

history = data.get('history', [])
scores = [str(h.get('score', 0)) for h in history[-7:]]
print(' '.join(scores))
" 2>/dev/null || echo ""
}

# ═══════════════════════════════════════════════════════════════
# 便捷聚合 API
# ═══════════════════════════════════════════════════════════════

# 获取完整自适应状态摘要（JSON）
get_adaptive_summary() {
    _init_adaptive_state
    _rotate_if_new_day

    local score level urgency trend churn silent_days interval_mult
    score="$(get_score)"
    level="$(get_level)"
    urgency="$(get_urgency)"
    trend="$(get_trend)"
    churn="$(get_churn_status)"
    silent_days="$(get_silent_days)"

    case "$level" in
        L4) interval_mult="1.05" ;;
        L3) interval_mult="1.00" ;;
        L2) interval_mult="0.85" ;;
        L1) interval_mult="0.70" ;;
        *)  interval_mult="1.00" ;;
    esac

    printf '{"score":%s,"level":"%s","urgency":"%s","trend":"%s","churn":"%s","silent_days":%s,"interval_multiplier":%s}' \
        "$score" "$level" "$urgency" "$trend" "$churn" "$silent_days" "$interval_mult"
}

# 打印人类可读的自适应引擎状态报告
adaptive_report() {
    _init_adaptive_state
    _rotate_if_new_day

    local score level urgency trend churn silent_days
    score="$(get_score)"
    level="$(get_level)"
    urgency="$(get_urgency)"
    trend="$(get_trend)"
    churn="$(get_churn_status)"
    silent_days="$(get_silent_days)"

    local cr rs sd qs sp
    cr="$(_dim_checkin_rate)"
    rs="$(_dim_response_speed)"
    sd="$(_dim_streak_days)"
    qs="$(_dim_quality_score)"
    sp="$(_dim_skip_pattern)"

    echo "========== 自适应引擎状态报告 =========="
    echo "综合评分:  ${score}/100  (等级: ${level})"
    echo "消息紧迫度: ${urgency}"
    echo "趋势:       ${trend}"
    echo "流失状态:   ${churn} (连续静默 ${silent_days} 天)"
    echo ""
    echo "--- 5 维评分明细 ---"
    echo "打卡率 (30%):   ${cr}/100"
    echo "响应速度 (25%): ${rs}/100"
    echo "连续天数 (20%): ${sd}/100"
    echo "完成质量 (15%): ${qs}/100"
    echo "跳过模式 (10%): ${sp}/100"
    echo ""
    echo "--- 间隔调整 ---"
    echo "久坐默认 1800s → $(adj_interval "sedentary" 1800)s"
    echo "用眼默认 3000s → $(adj_interval "eye_care" 3000)s"
    echo "喝水默认 4500s → $(adj_interval "hydration" 4500)s"
    echo ""
    echo "--- 近 7 天历史评分 ---"
    get_history_scores
    echo "=========================================="
}

# 重置自适应引擎状态
reset_adaptive() {
    if [[ -f "$ADAPTIVE_STATE_FILE" ]]; then
        rm -f "$ADAPTIVE_STATE_FILE"
    fi
    _init_adaptive_state
    log_info "自适应引擎状态已重置"
}

# ═══════════════════════════════════════════════════════════════
# CLI 入口
# ═══════════════════════════════════════════════════════════════
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        score)
            get_score
            ;;
        level)
            get_level
            ;;
        adj)
            adj_interval "${2:-sedentary}" "${3:-1800}"
            ;;
        urgency)
            get_urgency
            ;;
        trend)
            get_trend
            ;;
        churn)
            get_churn_status
            ;;
        silent-days)
            get_silent_days
            ;;
        check-churn)
            check_churn_warning && echo "warning" || echo "ok"
            ;;
        silent-mode)
            is_silent_mode && echo "yes" || echo "no"
            ;;
        paused-mode)
            is_paused_mode && echo "yes" || echo "no"
            ;;
        record-reminder)
            record_reminder "${2:-sedentary}"
            ;;
        record-response)
            record_response "${2:-sedentary}" "${3:-0}" "${4:-1.0}"
            ;;
        record-skip)
            record_skip "${2:-sedentary}" "${3:-}"
            ;;
        summary)
            get_adaptive_summary
            ;;
        report)
            adaptive_report
            ;;
        reset)
            reset_adaptive
            ;;
        history)
            get_history_scores
            ;;
        *)
            echo "Usage: $0 {score|level|adj|urgency|trend|churn|record-reminder|record-response|record-skip|summary|report|reset|history}" >&2
            exit 1
            ;;
    esac
fi
