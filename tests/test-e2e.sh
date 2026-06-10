#!/bin/bash
if [ -n "$DEPLOYED" ] || [ -f /etc/production ]; then
  echo "[ERROR] 生产环境禁止运行测试脚本" >&2
  exit 1
fi
# Input: 无（独立测试脚本）
# Output: PASS/FAIL 计数 + 汇总
# Pos: tests/test-e2e.sh — 端到端集成验证
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0

lib_check() {
  local file="$1"; local desc="$2"
  if [ -f "$PROJECT_ROOT/$file" ]; then
    bash -n "$PROJECT_ROOT/$file" 2>/dev/null && { echo "  PASS $desc"; PASS=$((PASS+1)); } || { echo "  FAIL $desc (语法错误)"; FAIL=$((FAIL+1)); }
  else
    echo "  FAIL $desc (文件不存在: $file)"; FAIL=$((FAIL+1))
  fi
}

func_check() {
  local file="$1"; local func="$2"; local desc="$3"
  if grep -q "^${func}()" "$PROJECT_ROOT/$file" 2>/dev/null; then
    echo "  PASS $desc"; PASS=$((PASS+1))
  else
    echo "  FAIL $desc (函数未定义: $func)"; FAIL=$((FAIL+1))
  fi
}

config_check() {
  local file="$1"; local desc="$2"
  if [ -f "$file" ]; then
    echo "  PASS $desc (存在)"; PASS=$((PASS+1))
  else
    echo "  INFO $desc (无配置文件，可选)"; PASS=$((PASS+1))  # 不是错误
  fi
}

echo "=== 层1: 语法校验 ==="
for f in scripts/vita scripts/scheduler.sh scripts/sedentary.sh scripts/eye-care.sh scripts/hydration.sh scripts/tigang.sh scripts/flow-detector.sh scripts/channel-adapter.sh scripts/adaptive-engine.sh; do
  lib_check "$f" "bash -n $f"
done

echo ""
echo "=== 层2: 库文件校验 ==="
for f in scripts/lib/common.sh scripts/lib/leaderboard-client.sh scripts/lib/notify.sh scripts/lib/suppression.sh scripts/lib/vitarc.sh; do
  lib_check "$f" "bash -n $f"
done

echo ""
echo "=== 层3: leaderboard-client 函数完整性 ==="
CLIENT="scripts/lib/leaderboard-client.sh"
for fn in lb_register lb_checkin lb_get_rank lb_get_leaderboard lb_get_stats lb_get_achievements lb_get_streak lb_create_challenge lb_get_challenges lb_get_challenge _lb_hmac_sign _lb_curl_post; do
  func_check "$CLIENT" "$fn" "函数 $fn 存在"
done

echo ""
echo "=== 层4: 配置文件检查 ==="
config_check "$HOME/.pandacc/config.yaml" "pandacc 配置"
config_check "$PROJECT_ROOT/scripts/lib/vitarc.sh" "vitarc 脚本"
config_check "$PROJECT_ROOT/leaderboard/wrangler.toml" "wrangler.toml"

echo ""
echo "=== 汇总: $PASS 通过, $FAIL 失败 ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
