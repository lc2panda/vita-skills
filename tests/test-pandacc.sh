#!/bin/bash
# Input: 无（独立测试脚本）
# Output: PASS/FAIL 计数 + 汇总
# Pos: tests/test-pandacc.sh — .pandacc 环境集成验证
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0

check() {
  local desc="$1"
  if eval "$2" 2>/dev/null; then
    echo "  PASS $desc"; PASS=$((PASS+1))
  else
    echo "  FAIL $desc"; FAIL=$((FAIL+1))
  fi
}

echo "=== .pandacc 环境集成验证 ==="

# 1. 安装脚本语法
check "pandacc-install.sh 语法" "bash -n $PROJECT_ROOT/scripts/pandacc-install.sh"

# 2. 市场安装器语法
check "marketplace-install.sh 语法" "bash -n $PROJECT_ROOT/scripts/marketplace-install.sh"

# 3. install.sh 语法
check "install.sh 语法" "bash -n $PROJECT_ROOT/scripts/install.sh"

# 4. CLAUDE.md 引用检查
check "CLAUDE.md 存在" "test -f $PROJECT_ROOT/CLAUDE.md"

# 5. SKILL.md 存在
check "SKILL.md 存在" "test -f $PROJECT_ROOT/SKILL.md"

# 6. README.md 存在
check "README.md 存在" "test -f $PROJECT_ROOT/README.md"

# 7. leaderboard 作为子模块存在
check "leaderboard/src/index.ts 存在" "test -f $PROJECT_ROOT/leaderboard/src/index.ts"

# 8. wrangler.toml 有效 (有 name 字段)
check "wrangler.toml 含name" "grep -q 'name' $PROJECT_ROOT/leaderboard/wrangler.toml"

# 9. D1 migration 目录存在
check "D1迁移目录存在" "test -d $PROJECT_ROOT/leaderboard/db/migrations"

echo ""
echo "=== 汇总: $PASS 通过, $FAIL 失败 ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
