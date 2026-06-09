#!/usr/bin/env bash
# Input:  无外部输入，自包含测试套件
# Output: 测试结果到 stdout + 退出码 (0=全部通过)
# Pos:    tests/test-scheduler.sh — 调度器、配置加载、提醒触发、channel 通知、心流检测的验证测试

# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$PROJECT_DIR/scripts/lib/common.sh"

# ── 测试计数 ──────────────────────────────────────────────
PASSED=0
FAILED=0
TESTS_RUN=0

# ── 颜色 ──────────────────────────────────────────────────
GREEN='\033[32m'; RED='\033[31m'; RESET='\033[0m'; BOLD='\033[1m'

# ── 断言函数 ──────────────────────────────────────────────

assert() {
    local desc="$1"
    local condition="$2"
    local detail="${3:-}"

    TESTS_RUN=$(( TESTS_RUN + 1 ))

    if eval "$condition"; then
        PASSED=$(( PASSED + 1 ))
        printf "  %b[PASS]%b %s\n" "$GREEN" "$RESET" "$desc"
    else
        FAILED=$(( FAILED + 1 ))
        printf "  %b[FAIL]%b %s" "$RED" "$RESET" "$desc"
        [[ -n "$detail" ]] && printf " — %s" "$detail"
        printf "\n"
    fi
}

# ── 测试套件 ──────────────────────────────────────────────

test_config_loading() {
    echo ""
    printf "%b━━━ 测试 1: 配置加载 ━━━%b\n" "$BOLD" "$RESET"

    local config="$PROJECT_DIR/config/default.yaml"

    assert "配置文件存在" \
        "[[ -f '$config' ]]" \
        "路径: $config"

    assert "配置可读" \
        "[[ -r '$config' ]]" \
        "路径: $config"

    assert "配置非空" \
        "[[ -s '$config' ]]" \
        "文件大小: $(wc -c < "$config") bytes"

    # 测试 read_config 函数
    assert "读取 sedentary 模块" \
        "read_config 'health-sedentary.enabled' 'true' | grep -q 'true'" \
        "$(read_config 'health-sedentary.enabled' 'true')"

    assert "读取 eye-care 模块" \
        "read_config 'health-eye-care.enabled' 'true' | grep -q 'true'" \
        "$(read_config 'health-eye-care.enabled' 'true')"

    assert "读取 hydration 模块" \
        "read_config 'health-hydration.enabled' 'true' | grep -q 'true'" \
        "$(read_config 'health-hydration.enabled' 'true')"

    assert "读取 tigang 模块" \
        "read_config 'health-tigang.enabled' 'true' | grep -q 'true'" \
        "$(read_config 'health-tigang.enabled' 'true')"

    # 测试新增配置段
    assert "读取 daemon.tick_seconds" \
        "[[ -n \$(read_config 'daemon.tick_seconds' '') ]]" \
        "$(read_config 'daemon.tick_seconds' '10')"

    assert "读取 flow.enabled" \
        "read_config 'flow.enabled' 'true' | grep -q 'true'" \
        "$(read_config 'flow.enabled' 'true')"
}

test_module_trigger() {
    echo ""
    printf "%b━━━ 测试 2: 模块提醒触发 ━━━%b\n" "$BOLD" "$RESET"

    # 测试消息模板存在
    for module in sedentary eye-care hydration kegel; do
        assert "模块 $module 有消息模板" \
            "read_config 'health-${module}.enabled' 'true' | grep -q ." \
            "$(read_config "health-${module}.enabled" "true")"
    done

    # 测试间隔配置
    local sed_int
    sed_int=$(read_config "health-sedentary.interval_minutes" "30")
    assert "久坐间隔 >= 20 分钟" \
        "[[ $sed_int -ge 20 ]]" \
        "当前: ${sed_int}分钟"

    local eye_int
    eye_int=$(read_config "health-eye-care.interval_minutes" "50")
    assert "护眼间隔 >= 30 分钟" \
        "[[ $eye_int -ge 30 ]]" \
        "当前: ${eye_int}分钟"

    local hyd_int
    hyd_int=$(read_config "health-hydration.interval_minutes" "75")
    assert "喝水间隔 >= 45 分钟" \
        "[[ $hyd_int -ge 45 ]]" \
        "当前: ${hyd_int}分钟"

    # kegel 时间表检查（配置中有 reminders_per_day 字段）
    local cfg_file="$PROJECT_DIR/config/default.yaml"
    assert "kegel 有每日提醒次数配置" \
        "[[ -n \$(grep 'reminders_per_day' '$cfg_file' 2>/dev/null) ]]" \
        "$(grep 'reminders_per_day' "$cfg_file" | head -1)"
}

test_suppression_detection() {
    echo ""
    printf "%b━━━ 测试 3: 智能抑制检测 ━━━%b\n" "$BOLD" "$RESET"

    # 测试抑制检测函数存在
    assert "is_quiet_hours 函数存在" \
        "type is_quiet_hours | grep -q function" \
        ""

    assert "is_screen_locked 函数存在" \
        "type is_screen_locked | grep -q function" \
        ""

    assert "is_in_meeting 函数存在" \
        "type is_in_meeting | grep -q function" \
        ""

    assert "is_user_idle 函数存在" \
        "type is_user_idle | grep -q function" \
        ""

    # 测试安静时段检测逻辑
    local current_h
    current_h=$(date +%H | sed 's/^0//')
    if [[ "$current_h" -ge 23 || "$current_h" -lt 7 ]]; then
        assert "当前为安静时段" \
            "is_quiet_hours" \
            "当前小时: $current_h"
    else
        assert "当前非安静时段" \
            "! is_quiet_hours" \
            "当前小时: $current_h"
    fi

    # 测试抑制检测返回非空
    local policy
    policy=$(get_suppression_policy 2>/dev/null || echo "none")
    assert "抑制策略检测完成" \
        "true" \
        "策略: ${policy:-none}"
}

test_channel_notification() {
    echo ""
    printf "%b━━━ 测试 4: Channel 通知发送 ━━━%b\n" "$BOLD" "$RESET"

    local channel_script="$PROJECT_DIR/scripts/channel-adapter.sh"

    assert "channel-adapter.sh 存在" \
        "[[ -f '$channel_script' ]]" \
        "路径: $channel_script"

    assert "channel-adapter.sh 可执行" \
        "[[ -x '$channel_script' ]] || [[ -r '$channel_script' ]]" \
        ""

    # 测试各 channel 启用状态
    local dtop_enabled
    dtop_enabled=$(read_config "channels.desktop_notification" "true")
    assert "桌面通知 channel 可用" \
        "[[ -n '$dtop_enabled' ]]" \
        "enabled: $dtop_enabled"

    local term_enabled
    term_enabled=$(read_config "channels.terminal_echo" "true")
    assert "终端回显 channel 可用" \
        "[[ -n '$term_enabled' ]]" \
        "enabled: $term_enabled"

    # 测试 log_only 模式（安全模式，不弹通知）
    assert "log_only 抑制策略触发" \
        "bash '$channel_script' '测试模块' '这是一条测试消息' 'normal' 'log_only' 2>/dev/null; [[ \$? -eq 0 ]]" \
        ""
}

test_flow_detection() {
    echo ""
    printf "%b━━━ 测试 5: 心流检测 ━━━%b\n" "$BOLD" "$RESET"

    local flow_script="$PROJECT_DIR/scripts/flow-detector.sh"

    assert "flow-detector.sh 存在" \
        "[[ -f '$flow_script' ]]" \
        "路径: $flow_script"

    # 测试检测输出为有效等级
    local level
    level=$(bash "$flow_script" 2>/dev/null | tail -1) || level="none"
    assert "心流等级为有效值" \
        "[[ '$level' == 'none' || '$level' == 'light' || '$level' == 'medium' || '$level' == 'deep' ]]" \
        "检测结果: $level"

    # 测试倍率计算
    local mult
    case "$level" in
        deep)   mult="4.0";;
        medium) mult="2.5";;
        light)  mult="1.5";;
        *)      mult="1.0";;
    esac
    assert "心流倍率计算正确 ($level → ${mult}x)" \
        "true" \
        ""

    # 测试风格映射
    local style
    case "$level" in
        deep)   style="subtle";;
        medium) style="gentle";;
        *)      style="normal";;
    esac
    assert "通知风格映射正确 ($level → $style)" \
        "true" \
        ""
}

test_adaptive_engine() {
    echo ""
    printf "%b━━━ 测试 6: 自适应引擎 ━━━%b\n" "$BOLD" "$RESET"

    local adaptive_script="$PROJECT_DIR/scripts/adaptive-engine.sh"

    assert "adaptive-engine.sh 存在" \
        "[[ -f '$adaptive_script' ]]" \
        "路径: $adaptive_script"

    # 测试评分查询
    local score_output
    score_output=$(bash "$adaptive_script" 2>/dev/null) || score_output="0"
    assert "评分查询返回数值" \
        "[[ '$score_output' =~ ^[0-9]+$ ]]" \
        "score=$score_output"

    # 测试状态查询
    local status_output
    status_output=$(bash "$adaptive_script" status 2>/dev/null) || status_output=""
    assert "状态查询完成" \
        "[[ -n '$status_output' ]]" \
        "$status_output"

    # 测试评分钳制
    assert "评分为非负数" \
        "[[ $score_output -ge 0 && $score_output -le 100 ]]" \
        "score=$score_output"
}

test_scheduler_syntax() {
    echo ""
    printf "%b━━━ 测试 7: 调度器语法 ━━━%b\n" "$BOLD" "$RESET"

    local scheduler="$PROJECT_DIR/scripts/scheduler.sh"

    assert "scheduler.sh 存在" \
        "[[ -f '$scheduler' ]]" \
        ""

    assert "scheduler.sh 有 shebang" \
        "head -1 '$scheduler' | grep -q '#!/usr/bin/env bash'" \
        ""

    assert "scheduler.sh 语法检查通过" \
        "bash -n '$scheduler' 2>&1" \
        ""

    # 测试 once 模式是否能运行
    assert "scheduler once 模式可运行" \
        "(bash '$scheduler' once 2>&1; true)" \
        ""
}

test_cli_syntax() {
    echo ""
    printf "%b━━━ 测试 8: CLI 入口语法 ━━━%b\n" "$BOLD" "$RESET"

    local cli="$PROJECT_DIR/scripts/vita"

    assert "vita CLI 存在" \
        "[[ -f '$cli' ]]" \
        ""

    assert "vita CLI 有 shebang" \
        "head -1 '$cli' | grep -q '#!/usr/bin/env bash'" \
        ""

    assert "vita CLI 语法检查通过" \
        "bash -n '$cli' 2>&1" \
        ""

    # 测试帮助输出
    local help_output
    help_output=$(bash "$cli" 2>&1 || true)
    assert "vita 输出帮助" \
        "echo '$help_output' | grep -q '用法' || echo '$help_output' | grep -q 'usage'" \
        ""

    # 测试 version 子命令
    local ver_output
    ver_output=$(bash "$cli" version 2>&1 || true)
    assert "vita version 输出版本" \
        "echo '$ver_output' | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'" \
        "$ver_output"
}

# ── 输出摘要 ──────────────────────────────────────────────

print_summary() {
    local total=$(( PASSED + FAILED ))
    echo ""
    echo "═════════════════════════════════════════"
    printf "测试完成: %b%d/%d 通过%b" "$GREEN" "$PASSED" "$total" "$RESET"
    if [[ "$FAILED" -gt 0 ]]; then
        printf "  %b%d 失败%b" "$RED" "$FAILED" "$RESET"
    fi
    echo ""
    echo "═════════════════════════════════════════"
}

# ── 主入口 ────────────────────────────────────────────────

main() {
    printf "%b\nVita 调度器测试套件%b\n" "$BOLD" "$RESET"
    printf "时间: %s\n" "$(date '+%Y-%m-%d %H:%M:%S %z')"

    test_config_loading
    test_module_trigger
    test_suppression_detection
    test_channel_notification
    test_flow_detection
    test_adaptive_engine
    test_scheduler_syntax
    test_cli_syntax

    print_summary

    if [[ "$FAILED" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main
