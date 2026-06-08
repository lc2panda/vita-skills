#!/usr/bin/env bash
# Input:  无参数
# Output: 验证 vita-skills 在 .pandacc 环境下的集成正确性
# Pos:    tests/test-pandacc.sh — .pandacc 集成验证测试

# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

set -euo pipefail

PANDACC_HOME="${HOME}/.pandacc"
SKILL_NAME="vita-health"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

C_GREEN='\033[0;32m'
C_RED='\033[0;31m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'
C_RESET='\033[0m'

assert() {
    local desc="$1"
    local result="$2"
    if [[ "$result" -eq 0 ]]; then
        printf "  ${C_GREEN}PASS${C_RESET} %s\n" "$desc"
        PASS=$((PASS + 1))
    else
        printf "  ${C_RED}FAIL${C_RESET} %s\n" "$desc"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
printf "%b◆ .pandacc 集成验证测试%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
echo "─────────────────────────────────────────"
echo ""

# ── 测试 1: .pandacc 目录存在 ─────────────────────────────────
echo "--- 测试组 1: 环境检测 ---"

[[ -d "$PANDACC_HOME" ]]; rc=$?
assert ".pandacc 目录存在 ($PANDACC_HOME)" $rc

# ── 测试 2: skills 软链接 ─────────────────────────────────────
echo ""
echo "--- 测试组 2: Skills 软链接 ---"

SKILL_LINK="${PANDACC_HOME}/skills/${SKILL_NAME}"
[[ -L "$SKILL_LINK" ]]; rc=$?
assert "Skills 软链接存在: $SKILL_LINK" $rc

if [[ -L "$SKILL_LINK" ]]; then
    LINK_TARGET="$(readlink "$SKILL_LINK")"
    [[ "$LINK_TARGET" == "$REPO_ROOT" ]]; rc=$?
    assert "Skills 软链接指向正确仓库 ($LINK_TARGET)" $rc

    [[ -f "${SKILL_LINK}/SKILL.md" ]]; rc=$?
    assert "通过软链接可访问 SKILL.md" $rc
fi

# ── 测试 3: bin 软链接 ────────────────────────────────────────
echo ""
echo "--- 测试组 3: bin 软链接 ---"

VITA_LINK="${PANDACC_HOME}/bin/vita"
if [[ -L "$VITA_LINK" ]]; then
    assert "bin/vita 软链接存在" 0

    VITA_TARGET="$(readlink "$VITA_LINK")"
    [[ "$VITA_TARGET" == "$REPO_ROOT/scripts/vita" ]]; rc=$?
    assert "bin/vita 指向正确脚本 ($VITA_TARGET)" $rc

    [[ -x "$VITA_LINK" ]]; rc=$?
    assert "bin/vita 可执行" $rc
else
    assert "bin/vita 软链接存在" 1
fi

# ── 测试 4: vita 命令可用性 ───────────────────────────────────
echo ""
echo "--- 测试组 4: CLI 可用性 ---"

if [[ -x "$VITA_LINK" ]] || [[ -x "${REPO_ROOT}/scripts/vita" ]]; then
    VITA_BIN="${VITA_LINK:-${REPO_ROOT}/scripts/vita}"
    "$VITA_BIN" version &>/dev/null; rc=$?
    assert "vita version 命令正常退出" $rc

    OUTPUT="$("$VITA_BIN" version 2>/dev/null || true)"
    [[ -n "$OUTPUT" ]]; rc=$?
    assert "vita version 有输出" $rc
    echo "        输出: $OUTPUT"
else
    assert "vita 命令可用（无可执行文件）" 1
fi

# ── 测试 5: SKILL.md 内容验证 ─────────────────────────────────
echo ""
echo "--- 测试组 5: SKILL.md 元数据 ---"

SKILL_MD="${REPO_ROOT}/SKILL.md"
if [[ -f "$SKILL_MD" ]]; then
    grep -q "name: ${SKILL_NAME}" "$SKILL_MD"; rc=$?
    assert "SKILL.md 声明 name: $SKILL_NAME" $rc

    grep -q "compatibility:" "$SKILL_MD"; rc=$?
    assert "SKILL.md 声明 compatibility 字段" $rc

    grep -q "description:" "$SKILL_MD"; rc=$?
    assert "SKILL.md 声明 description 字段" $rc
else
    assert "SKILL.md 存在" 1
fi

# ── 测试 6: pandacc-install.sh 幂等性 ─────────────────────────
echo ""
echo "--- 测试组 6: 安装脚本幂等性 ---"

INSTALL_SCRIPT="${REPO_ROOT}/scripts/pandacc-install.sh"
if [[ -f "$INSTALL_SCRIPT" ]]; then
    assert "pandacc-install.sh 存在" 0

    # 重复运行应无错退出
    bash "$INSTALL_SCRIPT" &>/dev/null; rc=$?
    assert "pandacc-install.sh 可重复执行（幂等）" $rc
else
    assert "pandacc-install.sh 存在" 1
fi

# ── 测试 7: 四个核心模块脚本可访问 ───────────────────────────
echo ""
echo "--- 测试组 7: 核心模块脚本可访问 ---"

for mod in sedentary.sh eye-care.sh hydration.sh kegel.sh scheduler.sh; do
    MOD_PATH="${REPO_ROOT}/scripts/${mod}"
    [[ -f "$MOD_PATH" ]]; rc=$?
    assert "模块脚本存在: scripts/${mod}" $rc
done

# ── 汇总 ──────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
printf "结果: ${C_GREEN}%d 通过${C_RESET} / ${C_RED}%d 失败${C_RESET} / %d 总计\n" "$PASS" "$FAIL" "$((PASS + FAIL))"

if [[ "$FAIL" -gt 0 ]]; then
    echo ""
    echo "失败项请检查:"
    echo "  1. 是否已运行 scripts/pandacc-install.sh"
    echo "  2. ~/.pandacc/ 目录是否存在"
    echo "  3. 软链接权限是否正常"
    exit 1
else
    echo ""
    printf "%b✓ 所有 .pandacc 集成测试通过%b\n" "${C_GREEN}" "${C_RESET}"
    exit 0
fi
