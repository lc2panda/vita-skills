#!/usr/bin/env bash
# Input:  无外部输入 — 本地离线验证，检查脚本语法、配置文件存在性、函数定义
# Output: 端到端测试结果到 stdout + 退出码 (0=全部通过)
# Pos:    tests/test-e2e.sh — 端到端集成验证 (离线模式)
#
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# source 公共库
source "$PROJECT_DIR/scripts/lib/common.sh" 2>/dev/null || true

GREEN='\033[32m'; RED='\033[31m'; RESET='\033[0m'; BOLD='\033[1m'; YELLOW='\033[33m'

PASSED=0
FAILED=0
SKIPPED=0

# ── 断言 ──────────────────────────────────────────────────────
assert() {
    local desc="$1" condition="$2" detail="${3:-}"
    if eval "$condition"; then
        PASSED=$((PASSED + 1))
        printf "  %b[PASS]%b %s\n" "$GREEN" "$RESET" "$desc"
    else
        FAILED=$((FAILED + 1))
        printf "  %b[FAIL]%b %s — %s\n" "$RED" "$RESET" "$desc" "${detail:-条件不满足}"
    fi
}

# ── 1. 调度器启动与停止 ──────────────────────────────────────
test_scheduler_lifecycle() {
    echo ""
    printf "%b━━━ 1: 调度器启动与停止 ━━━%b\n" "$BOLD" "$RESET"

    assert "scheduler.sh 存在" \
        "[[ -f '$PROJECT_DIR/scripts/scheduler.sh' ]]" \
        "路径: scripts/scheduler.sh"

    assert "scheduler.sh 可读" \
        "[[ -r '$PROJECT_DIR/scripts/scheduler.sh' ]]" \
        "路径: scripts/scheduler.sh"

    assert "scheduler.sh 语法正确" \
        "bash -n '$PROJECT_DIR/scripts/scheduler.sh' 2>/dev/null" \
        "bash -n 检查通过"

    assert "scheduler.sh 定义 start_scheduler 或 main" \
        "grep -qE '(start_scheduler|^main\b)' '$PROJECT_DIR/scripts/scheduler.sh'" \
        "入口函数存在"

    assert "scheduler.sh source common.sh" \
        "grep -qE 'source.*common\.sh' '$PROJECT_DIR/scripts/scheduler.sh'" \
        "依赖 common.sh"
}

# ── 2. 四大提醒模块 ──────────────────────────────────────────
test_four_modules() {
    echo ""
    printf "%b━━━ 2: 四大提醒模块 ━━━%b\n" "$BOLD" "$RESET"

    local config="$PROJECT_DIR/config/default.yaml"

    # 久坐模块
    assert "久坐(sedentary) 配置存在" \
        "grep -qE '(sedentary|久坐)' '$config'" \
        "config/default.yaml"

    assert "久坐间隔 > 0" \
        "grep -E 'interval_minutes' '$config' | head -1 | grep -q '[1-9]'" \
        "interval_minutes 是正整数"

    # 用眼模块
    assert "用眼(eye) 配置存在" \
        "grep -qE '(eye-care|eye_care|eye\.)' '$config'" \
        "config/default.yaml"

    # 喝水模块
    assert "喝水(hydration) 配置存在" \
        "grep -qE '(hydration|喝水)' '$config'" \
        "config/default.yaml"

    # 提肛模块
    assert "提肛(kegel/tigang) 配置存在" \
        "grep -qE '(kegel|tigang|提肛)' '$config'" \
        "config/default.yaml"
}

# ── 3. 心流检测 ──────────────────────────────────────────────
test_flow_detector() {
    echo ""
    printf "%b━━━ 3: 心流检测 ━━━%b\n" "$BOLD" "$RESET"

    local fd="$PROJECT_DIR/scripts/flow-detector.sh"

    assert "flow-detector.sh 存在" "[[ -f '$fd' ]]" "路径: scripts/flow-detector.sh"
    assert "flow-detector.sh 语法正确" "bash -n '$fd' 2>/dev/null" "bash -n 通过"

    assert "包含 detect_by_process" \
        "grep -q 'detect_by_process' '$fd'" \
        "函数定义存在"

    assert "包含 detect_by_activity" \
        "grep -q 'detect_by_activity' '$fd'" \
        "活动检测函数存在"

    assert "输出心流等级 (none/light/medium/deep)" \
        "grep -qE '(none|light|medium|deep)' '$fd'" \
        "等级枚举存在"
}

# ── 4. Channel 通知分发 ──────────────────────────────────────
test_channel_adapter() {
    echo ""
    printf "%b━━━ 4: Channel 通知分发 ━━━%b\n" "$BOLD" "$RESET"

    local ca="$PROJECT_DIR/scripts/channel-adapter.sh"

    assert "channel-adapter.sh 存在" "[[ -f '$ca' ]]" "路径: scripts/channel-adapter.sh"
    assert "channel-adapter.sh 语法正确" "bash -n '$ca' 2>/dev/null" "bash -n 通过"

    assert "channel_adapter 或 main 函数存在" \
        "grep -qE '(channel_adapter|^main\b)' '$ca' || grep -q 'channel_' '$ca'" \
        "通知分发逻辑存在"

    # 检查 channel 类型
    assert "包含 terminal channel" \
        "grep -qE 'channel_terminal' '$ca'" \
        "终端通知 channel"

    assert "包含桌面通知 channel" \
        "grep -qE '(channel_notify|desktop|osascript)' '$ca'" \
        "桌面通知 channel"
}

# ── 5. 打榜系统集成 ──────────────────────────────────────────
test_leaderboard_integration() {
    echo ""
    printf "%b━━━ 5: 打榜系统集成 (注册→打卡→查分) ━━━%b\n" "$BOLD" "$RESET"

    local lb="$PROJECT_DIR/scripts/lib/leaderboard-client.sh"

    assert "leaderboard-client.sh 存在" "[[ -f '$lb' ]]" "路径: scripts/lib/leaderboard-client.sh"
    assert "leaderboard-client.sh 语法正确" "bash -n '$lb' 2>/dev/null" "bash -n 通过"

    # 验证 leaderboard-client.sh 中的关键函数
    assert "包含 register_user 函数" \
        "grep -qE 'register_user|lb_register' '$lb'" \
        "注册函数"

    assert "包含 checkin 函数" \
        "grep -qE 'lb_checkin|submit_checkin' '$lb'" \
        "打卡函数"

    assert "包含 leaderboard 查询函数" \
        "grep -qE 'lb_leaderboard|get_leaderboard' '$lb'" \
        "排行榜查询函数"

    assert "scheduler.sh 集成 leaderboard-client" \
        "grep -q 'leaderboard-client' '$PROJECT_DIR/scripts/scheduler.sh'" \
        "scheduler.sh source 打榜库"
}

# ── 6. 自适应引擎 ────────────────────────────────────────────
test_adaptive_engine() {
    echo ""
    printf "%b━━━ 6: 自适应引擎 ━━━%b\n" "$BOLD" "$RESET"

    local ae="$PROJECT_DIR/scripts/adaptive-engine.sh"

    assert "adaptive-engine.sh 存在" "[[ -f '$ae' ]]" "路径: scripts/adaptive-engine.sh"
    assert "adaptive-engine.sh 语法正确" "bash -n '$ae' 2>/dev/null" "bash -n 通过"

    assert "包含 get_score 函数" \
        "grep -q 'get_score' '$ae'" \
        "忠诚度评分读取"

    assert "包含 set_score 函数" \
        "grep -q 'set_score' '$ae'" \
        "忠诚度评分更新"

    assert "分数范围限制 (0-100)" \
        "grep -qE '[[:space:]]-lt[[:space:]]+0' '$ae' && grep -qE '[[:space:]]-gt[[:space:]]+100' '$ae'" \
        "边界保护 (lt 0 / gt 100)"

    assert "scheduler.sh 集成 adaptive-engine" \
        "grep -q 'adaptive-engine' '$PROJECT_DIR/scripts/scheduler.sh'" \
        "scheduler.sh source 自适应引擎"
}

# ── 7. 跨模块交互 ────────────────────────────────────────────
test_cross_module() {
    echo ""
    printf "%b━━━ 7: 跨模块交互 ━━━%b\n" "$BOLD" "$RESET"

    # scheduler.sh 应 source 所有子模块
    local sched="$PROJECT_DIR/scripts/scheduler.sh"

    assert "scheduler.sh 引用 flow-detector" \
        "grep -q 'flow-detector' '$sched'" \
        "调度器 -> 心流检测"

    assert "scheduler.sh 引用 channel-adapter" \
        "grep -q 'channel-adapter' '$sched'" \
        "调度器 -> channel适配器"

    assert "scheduler.sh 引用 adaptive-engine" \
        "grep -q 'adaptive-engine' '$sched'" \
        "调度器 -> 自适应引擎"

    # 公共库完整性
    local common="$PROJECT_DIR/scripts/lib/common.sh"
    assert "common.sh 存在" "[[ -f '$common' ]]" "基础库"
    assert "common.sh 定义 read_config" "grep -q 'read_config' '$common'" "配置读取器"
    assert "common.sh 定义 log_info" "grep -q 'log_info' '$common'" "日志函数"

    local notify="$PROJECT_DIR/scripts/lib/notify.sh"
    assert "notify.sh 存在" "[[ -f '$notify' ]]" "通知库"
    assert "notify.sh 语法正确" "bash -n '$notify' 2>/dev/null" "bash -n 通过"

    local supp="$PROJECT_DIR/scripts/lib/suppression.sh"
    assert "suppression.sh 存在" "[[ -f '$supp' ]]" "抑制策略库"
    assert "suppression.sh 语法正确" "bash -n '$supp' 2>/dev/null" "bash -n 通过"
}

# ── 8. 配置文件完整性 ────────────────────────────────────────
test_config_integrity() {
    echo ""
    printf "%b━━━ 8: 配置文件完整性 ━━━%b\n" "$BOLD" "$RESET"

    assert "default.yaml 存在" \
        "[[ -f '$PROJECT_DIR/config/default.yaml' ]]" \
        "主配置"

    assert "schema.yaml 存在" \
        "[[ -f '$PROJECT_DIR/config/schema.yaml' ]]" \
        "配置模式"

    assert "default.yaml 非空" \
        "[[ -s '$PROJECT_DIR/config/default.yaml' ]]" \
        "$(wc -c < "$PROJECT_DIR/config/default.yaml") bytes"

    assert "default.yaml 含 health- 模块段" \
        "grep -q 'health-' '$PROJECT_DIR/config/default.yaml'" \
        "模块配置段存在"
}

# ── 汇总 ──────────────────────────────────────────────────────
print_summary() {
    local total=$((PASSED + FAILED + SKIPPED))
    echo ""
    echo "══════════════════════════════════════════"
    printf "端到端集成测试(离线)完成: %b%d/%d 通过%b" "$GREEN" "$PASSED" "$total" "$RESET"
    if [[ "$FAILED" -gt 0 ]]; then
        printf "  %b%d 失败%b" "$RED" "$FAILED" "$RESET"
    fi
    if [[ "$SKIPPED" -gt 0 ]]; then
        printf "  %b%d 跳过%b" "$YELLOW" "$SKIPPED" "$RESET"
    fi
    echo ""
    echo "══════════════════════════════════════════"
}

# ── 主入口 ────────────────────────────────────────────────────
main() {
    printf "%b\nVita 端到端集成测试 (离线验证模式)%b\n" "$BOLD" "$RESET"
    printf "时间: %s\n" "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf "项目: %s\n" "$PROJECT_DIR"
    printf "模式: 语法检查 + 文件存在 + 函数定义 + 配置完整性\n"

    test_scheduler_lifecycle
    test_four_modules
    test_flow_detector
    test_channel_adapter
    test_leaderboard_integration
    test_adaptive_engine
    test_cross_module
    test_config_integrity

    print_summary

    if [[ "$FAILED" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main
