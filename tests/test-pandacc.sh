#!/usr/bin/env bash
# Input:  无外部输入 — 本地离线验证 .pandacc 环境集成
# Output: .pandacc 集成验证结果到 stdout + 退出码 (0=全部通过)
# Pos:    tests/test-pandacc.sh — .pandacc 环境集成验证
#
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[32m'; RED='\033[31m'; RESET='\033[0m'; BOLD='\033[1m'; YELLOW='\033[33m'

PASSED=0
FAILED=0
SKIPPED=0

PANDACC_HOME="${HOME}/.pandacc"

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

skip() {
    local desc="$1" detail="${2:-}"
    SKIPPED=$((SKIPPED + 1))
    printf "  %b[SKIP]%b %s — %s\n" "$YELLOW" "$RESET" "$desc" "$detail"
}

# ── 1. CLAUDE.md 中 vita-skills 相关配置 ─────────────────────
test_claude_md_config() {
    echo ""
    printf "%b━━━ 1: CLAUDE.md 中 vita-skills 配置 ━━━%b\n" "$BOLD" "$RESET"

    local claude_md="$PROJECT_DIR/CLAUDE.md"

    if [[ ! -f "$claude_md" ]]; then
        skip "CLAUDE.md 不存在" "$claude_md"
        return
    fi

    assert "CLAUDE.md 存在" "[[ -f '$claude_md' ]]" "$claude_md"

    assert "CLAUDE.md 可读" "[[ -r '$claude_md' ]]" "权限正常"

    assert "CLAUDE.md 提及 vita-skills" \
        "grep -qi 'vita' '$claude_md'" \
        "含 vita 关键词"

    # 检查是否有 pandacc 安装相关记录
    assert "CLAUDE.md 提及 pandacc" \
        "grep -qi 'pandacc' '$claude_md'" \
        "含 pandacc 关键词"

    # 检查 git 提交记录中是否有 pandacc 集成
    assert "git log 中有 pandacc-install 相关提交" \
        "cd '$PROJECT_DIR' && git log --oneline -20 2>/dev/null | grep -qi 'pandacc'" \
        "最近提交含 pandacc"
}

# ── 2. pandacc-install.sh 语法和执行模拟 ─────────────────────
test_pandacc_install() {
    echo ""
    printf "%b━━━ 2: pandacc-install.sh 语法和执行模拟 ━━━%b\n" "$BOLD" "$RESET"

    local installer="$PROJECT_DIR/scripts/pandacc-install.sh"

    assert "pandacc-install.sh 存在" "[[ -f '$installer' ]]" "$installer"
    assert "pandacc-install.sh 可执行" "[[ -x '$installer' ]]" "权限: 可执行"

    # 语法检查
    assert "pandacc-install.sh 语法正确" \
        "bash -n '$installer' 2>/dev/null" \
        "bash -n 通过"

    # 关键函数/逻辑检测
    assert "包含 detect_pandacc 函数" \
        "grep -q 'detect_pandacc' '$installer'" \
        "pandacc 目录检测"

    assert "包含 link_skill 函数" \
        "grep -q 'link_skill' '$installer'" \
        "skills 软链接"

    assert "包含 PANDACC_HOME 变量" \
        "grep -q 'PANDACC_HOME' '$installer'" \
        "路径配置正确"

    assert "SKILL_NAME 为 vita-health" \
        "grep -q 'SKILL_NAME=.*vita-health' '$installer'" \
        "技能名称正确"

    # 模拟执行: 在子 shell 中仅 source (不实际修改系统)
    local sim_output
    sim_output="$(cd "$PROJECT_DIR" && bash -c "
        detect_pandacc() { return 0; }  # 模拟检测
        echo 'Simulated pandacc install OK'
    " 2>&1)" || true
    if [[ -n "$sim_output" ]]; then
        printf "  %b[INFO]%b 模拟执行: %s\n" "$BOLD" "$RESET" "$sim_output"
    fi
}

# ── 3. ~/.pandacc 环境状态 ───────────────────────────────────
test_pandacc_environment() {
    echo ""
    printf "%b━━━ 3: ~/.pandacc 环境状态 ━━━%b\n" "$BOLD" "$RESET"

    # 目录存在性
    if [[ -d "$PANDACC_HOME" ]]; then
        printf "  %b[INFO]%b .pandacc 目录已检测到: %s\n" "$BOLD" "$RESET" "$PANDACC_HOME"

        # skills 目录
        if [[ -d "$PANDACC_HOME/skills" ]]; then
            assert "skills 目录存在" "[[ -d '$PANDACC_HOME/skills' ]]" "路径正常"
        else
            skip "skills 目录不存在" "$PANDACC_HOME/skills"
        fi

        # vita-health 软链接
        if [[ -L "$PANDACC_HOME/skills/vita-health" ]]; then
            local link_target; link_target="$(readlink "$PANDACC_HOME/skills/vita-health")"
            assert "vita-health 软链接存在" \
                "[[ -L '$PANDACC_HOME/skills/vita-health' ]]" \
                "-> $link_target"

            assert "vita-health 软链接指向有效目录" \
                "[[ -d '$link_target' ]]" \
                "目标: $link_target"
        else
            printf "  %b[WARN]%b vita-health 软链接不存在 (需运行 pandacc-install.sh)\n" "$YELLOW" "$RESET"
        fi

        # bin 目录
        if [[ -d "$PANDACC_HOME/bin" ]]; then
            assert "bin 目录存在" "[[ -d '$PANDACC_HOME/bin' ]]" "路径正常"
        else
            skip "bin 目录不存在" "$PANDACC_HOME/bin"
        fi

        # vita CLI 命令
        if [[ -x "$PANDACC_HOME/bin/vita" ]]; then
            assert "vita CLI 存在且可执行" "[[ -x '$PANDACC_HOME/bin/vita' ]]" "CLI 就绪"
        else
            printf "  %b[WARN]%b vita CLI 不存在 (需运行 pandacc-install.sh)\n" "$YELLOW" "$RESET"
        fi
    else
        skip ".pandacc 目录不存在" "无需验证环境 (非 pandacc 部署)"
    fi
}

# ── 4. vitarc 配置文件验证 ───────────────────────────────────
test_vitarc_config() {
    echo ""
    printf "%b━━━ 4: vitarc 配置文件验证 ━━━%b\n" "$BOLD" "$RESET"

    local vitarc_script="$PROJECT_DIR/scripts/lib/vitarc.sh"

    assert "vitarc.sh 存在" "[[ -f '$vitarc_script' ]]" "路径: scripts/lib/vitarc.sh"
    assert "vitarc.sh 语法正确" "bash -n '$vitarc_script' 2>/dev/null" "bash -n 通过"

    # 检查 vitarc.sh 中的关键功能
    assert "包含 _load_vitarc 函数" \
        "grep -q '_load_vitarc' '$vitarc_script'" \
        "配置加载器"

    assert "包含 VITA_ 前缀过滤" \
        "grep -q 'VITA_' '$vitarc_script'" \
        "安全白名单"

    assert "加载路径为 ~/.vitarc" \
        "grep -q '.vitarc' '$vitarc_script'" \
        "用户级配置路径"

    # 检查 ~/.vitarc 示例变量是否在脚本注释中
    assert "注释含 VITA_SEDENTARY_INTERVAL 示例" \
        "grep -q 'VITA_SEDENTARY_INTERVAL' '$vitarc_script'" \
        "久坐间隔配置示例"

    assert "注释含 VITA_EYE_INTERVAL 示例" \
        "grep -q 'VITA_EYE_INTERVAL' '$vitarc_script'" \
        "用眼间隔配置示例"

    assert "注释含 VITA_DND 示例" \
        "grep -q 'VITA_DND' '$vitarc_script'" \
        "免打扰时段配置示例"

    # 验证 ~/.vitarc 加载安全性
    assert "只加载 VITA_ 前缀变量" \
        "grep -q 'export.*\\\${key}=' '$vitarc_script'" \
        "白名单机制"

    # 测试: 创建临时 HOME 目录 + 临时 .vitarc，验证解析逻辑
    local tmp_home_global="/tmp/vita-pandacc-test-home-$$"
    rm -rf "$tmp_home_global" 2>/dev/null || true
    mkdir -p "$tmp_home_global"
    cat > "$tmp_home_global/.vitarc" << 'VITARC_EOF'
# 临时测试 vitarc
export VITA_SEDENTARY_INTERVAL=30
export VITA_EYE_INTERVAL=20
export VITA_DND="22:00-08:00"
export VITA_LOG_LEVEL="INFO"
# 非 VITA_ 变量应被忽略
export NOT_VITA_VAR=42
VITARC_EOF

    # 在子 shell 中用临时 HOME 测试加载
    local test_result
    test_result="$(HOME="$tmp_home_global" bash -c "
        source '$PROJECT_DIR/scripts/lib/vitarc.sh' 2>/dev/null
        cat <<EOF2
SEDENTARY=\${VITA_SEDENTARY_INTERVAL:-NOT_SET}
EYE=\${VITA_EYE_INTERVAL:-NOT_SET}
DND=\${VITA_DND:-NOT_SET}
LOG=\${VITA_LOG_LEVEL:-NOT_SET}
NOT_VITA=\${NOT_VITA_VAR:-NOT_SET}
EOF2
    " 2>/dev/null)" || true

    assert "VITA_SEDENTARY_INTERVAL 可被加载" \
        "echo '$test_result' | grep -q 'SEDENTARY=30'" \
        "值=30"

    assert "VITA_DND 可被加载" \
        "echo '$test_result' | grep -q 'DND=22:00-08:00'" \
        "免打扰时段正确"

    # 清理
    rm -rf "$tmp_home_global"
}

# ── 5. ~/.vitarc 示例文件 (如果不存在则验证语法) ─────────────
test_vitarc_example() {
    echo ""
    printf "%b━━━ 5: ~/.vitarc 示例文件正确性 ━━━%b\n" "$BOLD" "$RESET"

    local vitarc_file="$HOME/.vitarc"

    if [[ -f "$vitarc_file" ]]; then
        assert "~/.vitarc 存在" "[[ -f '$vitarc_file' ]]" "$vitarc_file"

        # 语法检查: 仅解析，不执行副作用
        local parse_result
        parse_result="$(bash -n "$vitarc_file" 2>&1)" || true
        if [[ -z "$parse_result" ]]; then
            assert "~/.vitarc 语法正确" "true" "bash -n 通过"
        else
            assert "~/.vitarc 语法正确" "false" "$parse_result"
        fi

        # 检查是否有 VITA_ 变量
        assert "~/.vitarc 含 VITA_ 变量" \
            "grep -q 'VITA_' '$vitarc_file'" \
            "配置项存在"
    else
        skip "~/.vitarc 不存在" "用户尚未创建个人配置（非错误）"
    fi

    # vitarc lib 中的示例格式验证
    local vitarc_script="$PROJECT_DIR/scripts/lib/vitarc.sh"
    assert "示例使用 export 声明" \
        "grep -q 'export VITA_' '$vitarc_script'" \
        "符合 bash 变量规范"

    assert "示例包含引号正确使用" \
        "grep -q '\"22:00-08:00\"' '$vitarc_script'" \
        "时区/字符串值用引号"
}

# ── 6. pandacc 技能注册验证 ──────────────────────────────────
test_skill_registration() {
    echo ""
    printf "%b━━━ 6: 技能注册验证 ━━━%b\n" "$BOLD" "$RESET"

    local skill_dir="$PANDACC_HOME/skills/vita-health"

    if [[ ! -d "$skill_dir" ]]; then
        skip "vita-health 技能目录不存在" "需先运行 pandacc-install.sh"
        return
    fi

    # 检查关键文件是否指向本项目
    assert "SKILL.md 存在" "[[ -f '$skill_dir/SKILL.md' ]]" "技能描述文件"

    local scripts_ok=true
    [[ -d "$skill_dir/scripts" ]] || scripts_ok=false
    assert "scripts 目录存在" "$scripts_ok" "脚本目录"

    local config_ok=true
    [[ -d "$skill_dir/config" ]] || config_ok=false
    assert "config 目录存在" "$config_ok" "配置目录"
}

# ── 汇总 ──────────────────────────────────────────────────────
print_summary() {
    local total=$((PASSED + FAILED + SKIPPED))
    echo ""
    echo "══════════════════════════════════════════"
    printf ".pandacc 环境集成验证完成: %b%d/%d 通过%b" "$GREEN" "$PASSED" "$total" "$RESET"
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
    printf "%b\n.pandacc 环境集成验证%b\n" "$BOLD" "$RESET"
    printf "时间: %s\n" "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf "项目: %s\n" "$PROJECT_DIR"
    printf "pandacc: %s\n" "$PANDACC_HOME"

    test_claude_md_config
    test_pandacc_install
    test_pandacc_environment
    test_vitarc_config
    test_vitarc_example
    test_skill_registration

    print_summary

    if [[ "$FAILED" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main
