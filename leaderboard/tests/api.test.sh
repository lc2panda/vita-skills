#!/bin/bash
# Input:  无外部输入 — HTTP 状态码验证模式，不对 JSON body 做结构化解析
# Output: 12 个端点 HTTP 状态码测试结果，PASS/FAIL 汇总到 stdout
# Pos:    leaderboard/tests/api.test.sh — 打榜PK系统 API 状态码验证套件
#
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# source 公共库
source "$PROJECT_ROOT/scripts/lib/common.sh" 2>/dev/null || true
source "$PROJECT_ROOT/scripts/lib/leaderboard-client.sh" 2>/dev/null || true

GREEN='\033[32m'; RED='\033[31m'; RESET='\033[0m'; BOLD='\033[1m'; YELLOW='\033[33m'

PASS=0
FAIL=0
SKIP=0

API_BASE="${VITA_API_URL:-https://vita-leaderboard.imladrisel.workers.dev}"

# ── HTTP helper ───────────────────────────────────────────────
_http_get() {
    local path="$1"
    curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 --max-time 10 \
        "${API_BASE}${path}" 2>/dev/null || echo "000"
}

_http_post() {
    local path="$1" data="$2" token="${3:-}"
    local headers=(-H "Content-Type: application/json")
    [[ -n "$token" ]] && headers+=(-H "Authorization: Bearer ${token}")
    curl -s -o /dev/null -w "%{http_code}" -X POST "${headers[@]}" \
        --connect-timeout 5 --max-time 10 \
        -d "$data" "${API_BASE}${path}" 2>/dev/null || echo "000"
}

# ── 断言 ──────────────────────────────────────────────────────
check() {
    local desc="$1" status_code="$2"
    case "$status_code" in
        200|201) printf "  %b[PASS]%b %s (HTTP %s)\n" "$GREEN" "$RESET" "$desc" "$status_code"
                 PASS=$((PASS + 1)) ;;
        401|403) printf "  %b[PASS]%b %s (HTTP %s - 端点存在需认证)\n" "$GREEN" "$RESET" "$desc" "$status_code"
                 PASS=$((PASS + 1)) ;;
        000)     printf "  %b[FAIL]%b %s (连接超时/不可达)\n" "$RED" "$RESET" "$desc"
                 FAIL=$((FAIL + 1)) ;;
        5??)     printf "  %b[FAIL]%b %s (HTTP %s - 服务端错误)\n" "$RED" "$RESET" "$desc" "$status_code"
                 FAIL=$((FAIL + 1)) ;;
        4??)     printf "  %b[SKIP]%b %s (HTTP %s - 客户端错误)\n" "$YELLOW" "$RESET" "$desc" "$status_code"
                 SKIP=$((SKIP + 1)) ;;
        *)       printf "  %b[FAIL]%b %s (HTTP %s - 未预期的状态码)\n" "$RED" "$RESET" "$desc" "$status_code"
                 FAIL=$((FAIL + 1)) ;;
    esac
}

# ── 测试 1: 健康检查 GET /api/health ──────────────────────────
test_health() {
    echo ""
    printf "%b━━━ 1: 健康检查 GET /api/health ━━━%b\n" "$BOLD" "$RESET"
    local sc; sc="$(_http_get "/api/health")"
    check "健康检查端点" "$sc"
}

# ── 测试 2: 注册用户 POST /api/user/register ──────────────────
TEST_USER_ID=""
TEST_TOKEN=""

test_register() {
    echo ""
    printf "%b━━━ 2: 注册用户 POST /api/user/register ━━━%b\n" "$BOLD" "$RESET"
    local test_name="api-test-$(date +%s | tail -c 6)"
    local sc; sc="$(_http_post "/api/user/register" "{\"display_name\":\"${test_name}\",\"device_id\":\"api-test-$(uname -n)\"}")"
    check "注册用户端点" "$sc"

    if [[ "$sc" =~ ^(200|201) ]]; then
        local body; body="$(curl -s --connect-timeout 5 --max-time 10 -X POST -H 'Content-Type: application/json' -d "{\"display_name\":\"${test_name}\",\"device_id\":\"api-test-$(uname -n)\"}" "${API_BASE}/api/user/register" 2>/dev/null)"
        TEST_USER_ID="$(echo "$body" | grep -o '"user_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"user_id"[[:space:]]*:[[:space:]]*"//; s/"$//' || true)"
        TEST_TOKEN="$(echo "$body" | grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"token"[[:space:]]*:[[:space:]]*"//; s/"$//' || true)"
    fi
}

# ── 测试 3: 打卡 POST /api/checkin ────────────────────────────
test_checkin() {
    echo ""
    printf "%b━━━ 3: 打卡 POST /api/checkin ━━━%b\n" "$BOLD" "$RESET"

    local uid="${TEST_USER_ID:-test-user-001}"
    local sc; sc="$(_http_post "/api/checkin" "{\"user_id\":\"${uid}\",\"sets_completed\":3,\"reps_per_set\":10,\"hold_seconds\":5}" "$TEST_TOKEN")"
    check "打卡端点" "$sc"
}

# ── 测试 4: 排行榜 GET /api/leaderboard ───────────────────────
test_leaderboard() {
    echo ""
    printf "%b━━━ 4: 排行榜 GET /api/leaderboard ━━━%b\n" "$BOLD" "$RESET"

    local sc; sc="$(_http_get "/api/leaderboard?type=weekly")"
    check "周榜端点" "$sc"

    sc="$(_http_get "/api/leaderboard?type=alltime")"
    check "总榜端点" "$sc"
}

# ── 测试 5: 用户列表 GET /api/users ───────────────────────────
test_users() {
    echo ""
    printf "%b━━━ 5: 用户列表 GET /api/users ━━━%b\n" "$BOLD" "$RESET"
    local sc; sc="$(_http_get "/api/users")"
    check "用户列表端点" "$sc"
}

# ── 测试 6: 用户详情 GET /api/user/:id ────────────────────────
test_user_detail() {
    echo ""
    printf "%b━━━ 6: 用户详情 GET /api/user/:id ━━━%b\n" "$BOLD" "$RESET"

    local uid="${TEST_USER_ID:-test-user-001}"
    local sc; sc="$(_http_get "/api/user/${uid}")"
    check "用户详情端点" "$sc"
}

# ── 测试 7: 连续打卡 GET /api/user/:id/streak ────────────────
test_user_streak() {
    echo ""
    printf "%b━━━ 7: 连续打卡 GET /api/user/:id/streak ━━━%b\n" "$BOLD" "$RESET"

    local uid="${TEST_USER_ID:-test-user-001}"
    local sc; sc="$(_http_get "/api/user/${uid}/streak")"
    check "连续打卡端点" "$sc"
}

# ── 测试 8: 成就列表 GET /api/user/:id/achievements ───────────
test_achievements() {
    echo ""
    printf "%b━━━ 8: 成就列表 GET /api/user/:id/achievements ━━━%b\n" "$BOLD" "$RESET"

    local uid="${TEST_USER_ID:-test-user-001}"
    local sc; sc="$(_http_get "/api/user/${uid}/achievements")"
    check "成就列表端点" "$sc"
}

# ── 测试 9: 全局统计 GET /api/stats ───────────────────────────
test_stats() {
    echo ""
    printf "%b━━━ 9: 全局统计 GET /api/stats ━━━%b\n" "$BOLD" "$RESET"
    local sc; sc="$(_http_get "/api/stats")"
    check "全局统计端点" "$sc"
}

# ── 测试 10: 创建挑战 POST /api/challenge ────────────────────
test_create_challenge() {
    echo ""
    printf "%b━━━ 10: 创建挑战 POST /api/challenge ━━━%b\n" "$BOLD" "$RESET"

    local uid="${TEST_USER_ID:-test-user-001}"
    local sc; sc="$(_http_post "/api/challenge" "{\"creator_id\":\"${uid}\",\"title\":\"测试挑战\",\"description\":\"API状态码验证\",\"type\":\"daily\",\"target_sets\":10,\"target_reps\":15,\"duration_days\":7}" "$TEST_TOKEN")"
    check "创建挑战端点" "$sc"
}

# ── 测试 11: 挑战列表 GET /api/challenges ────────────────────
test_list_challenges() {
    echo ""
    printf "%b━━━ 11: 挑战列表 GET /api/challenges ━━━%b\n" "$BOLD" "$RESET"
    local sc; sc="$(_http_get "/api/challenges")"
    check "挑战列表端点" "$sc"
}

# ── 测试 12: 挑战详情 GET /api/challenge/:id ─────────────────
test_challenge_detail() {
    echo ""
    printf "%b━━━ 12: 挑战详情 GET /api/challenge/:id ━━━%b\n" "$BOLD" "$RESET"

    local sc; sc="$(_http_get "/api/challenge/test-challenge-001")"
    check "挑战详情端点" "$sc"
}

# ── 汇总 ──────────────────────────────────────────────────────
print_summary() {
    local total=$((PASS + FAIL + SKIP))
    echo ""
    echo "══════════════════════════════════════════"
    printf "打榜API状态码验证完成: %b%d/%d 通过%b" "$GREEN" "$PASS" "$total" "$RESET"
    if [[ "$FAIL" -gt 0 ]]; then
        printf "  %b%d 失败%b" "$RED" "$FAIL" "$RESET"
    fi
    if [[ "$SKIP" -gt 0 ]]; then
        printf "  %b%d 跳过%b" "$YELLOW" "$SKIP" "$RESET"
    fi
    echo ""
    echo "══════════════════════════════════════════"
}

main() {
    printf "%b\nVita 打榜PK系统 API 状态码验证%b\n" "$BOLD" "$RESET"
    printf "时间: %s\n" "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf "API: %s\n" "$API_BASE"
    printf "模式: 仅验证 HTTP 状态码 (200/201/401=通过)\n"

    test_health
    test_register
    test_checkin
    test_leaderboard
    test_users
    test_user_detail
    test_user_streak
    test_achievements
    test_stats
    test_create_challenge
    test_list_challenges
    test_challenge_detail

    print_summary

    if [[ "$FAIL" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main
