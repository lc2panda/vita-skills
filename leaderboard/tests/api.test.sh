#!/bin/bash
# Input: 无（独立测试脚本）
# Output: PASS/FAIL 计数 + 汇总
# Pos: leaderboard/tests/api.test.sh — API 状态码验证
set -euo pipefail

API_BASE="${VITA_API_URL:-https://vita-leaderboard.imladrisel.workers.dev}"
PASS=0; FAIL=0; TOTAL=0

check_status() {
  local name="$1"; local method="$2"; local path="$3"; local expected="${4:-200}"
  TOTAL=$((TOTAL + 1))
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -X "$method" "$API_BASE$path" 2>/dev/null || echo "000")
  if [ "$code" = "$expected" ] || { [ "$expected" = "20x" ] && [[ "$code" =~ ^20 ]]; }; then
    echo "  PASS [$code] $name"; PASS=$((PASS + 1))
  else
    echo "  FAIL [$code] $name (expected $expected)"; FAIL=$((FAIL + 1))
  fi
}

echo "=== API 端点状态码验证 ==="
check_status "health"      GET  "/api/health"          200
check_status "leaderboard" GET  "/api/leaderboard"     200
check_status "users"       GET  "/api/users"           200
check_status "stats"       GET  "/api/stats"           200
check_status "register"    POST "/api/user/register"   20x
check_status "challenge_detail" GET "/api/challenge/test-id" 200

echo ""
echo "=== 汇总: $PASS/$TOTAL 通过, $FAIL 失败 ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
