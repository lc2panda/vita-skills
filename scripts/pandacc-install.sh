#!/usr/bin/env bash
# Input:  无参数；由用户或 install.sh 自动调用
# Output: 将 vita-skills 集成到 ~/.pandacc/ 体系（skills 软链接、bin 软链接）
# Pos:    scripts/pandacc-install.sh — .pandacc 体系专用集成安装器

# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

set -euo pipefail

PANDACC_HOME="${HOME}/.pandacc"
SKILL_NAME="vita-health"
# 本脚本位于 vita-skills/scripts/，仓库根目录为其父目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VITA_BIN="${REPO_ROOT}/scripts/vita"

# ── 颜色 ──────────────────────────────────────────────────────
C_GREEN='\033[0;32m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'
C_RESET='\033[0m'

# ── 检测 ──────────────────────────────────────────────────────

detect_pandacc() {
    if [[ -d "$PANDACC_HOME" ]]; then
        echo "  .pandacc 目录已检测到: $PANDACC_HOME"
        return 0
    else
        echo "  .pandacc 目录未找到 ($PANDACC_HOME)，跳过集成"
        return 1
    fi
}

# ── Skills 目录软链接 ─────────────────────────────────────────

link_skill() {
    local target="${PANDACC_HOME}/skills/${SKILL_NAME}"

    if [[ -L "$target" ]]; then
        local existing; existing="$(readlink "$target")"
        if [[ "$existing" == "$REPO_ROOT" ]]; then
            echo "  技能软链接已存在: ${target} -> ${REPO_ROOT}"
            return 0
        else
            echo "  技能软链接指向不同路径 (${existing})，重新创建..."
            rm "$target"
        fi
    elif [[ -e "$target" ]]; then
        echo "  目标路径已存在且非软链接 ($target)，备份后覆盖..."
        mv "$target" "${target}.bak-$(date +%Y%m%d%H%M%S)"
    fi

    mkdir -p "${PANDACC_HOME}/skills"
    ln -s "$REPO_ROOT" "$target"
    echo "  技能软链接已创建: ${target} -> ${REPO_ROOT}"
}

# ── bin 目录软链接 ────────────────────────────────────────────

link_bin() {
    local bin_dir="${PANDACC_HOME}/bin"
    local target="${bin_dir}/vita"

    mkdir -p "$bin_dir"

    if [[ -L "$target" ]]; then
        local existing; existing="$(readlink "$target")"
        if [[ "$existing" == "$VITA_BIN" ]]; then
            echo "  bin 软链接已存在: ${target} -> ${VITA_BIN}"
            return 0
        else
            echo "  bin 软链接指向不同路径 (${existing})，重新创建..."
            rm "$target"
        fi
    elif [[ -e "$target" ]]; then
        echo "  目标路径已存在且非软链接 ($target)，备份后覆盖..."
        mv "$target" "${target}.bak-$(date +%Y%m%d%H%M%S)"
    fi

    ln -s "$VITA_BIN" "$target"
    chmod +x "$VITA_BIN" 2>/dev/null || true
    echo "  bin 软链接已创建: ${target} -> ${VITA_BIN}"
}

# ── Shell profile 补充（确保 PATH 含 .pandacc/bin） ──────────

ensure_path() {
    local profile_file=""
    if [[ "$SHELL" == *"zsh"* ]]; then
        profile_file="$HOME/.zshrc"
    elif [[ "$SHELL" == *"bash"* ]]; then
        profile_file="$HOME/.bashrc"
    else
        profile_file="$HOME/.profile"
    fi

    local path_line="export PATH=\"${PANDACC_HOME}/bin:\$PATH\""
    if grep -q "${PANDACC_HOME}/bin" "$profile_file" 2>/dev/null; then
        echo "  PATH 已包含 ${PANDACC_HOME}/bin (in ${profile_file})"
    else
        echo "" >> "$profile_file"
        echo "# Panda CLI .pandacc 集成 (vita-skills)" >> "$profile_file"
        echo "$path_line" >> "$profile_file"
        echo "  PATH 行已追加到: ${profile_file}"
    fi
}

# ── 创建 _meta.json ───────────────────────────────────────────

create_meta() {
    local meta_file="${REPO_ROOT}/_meta.json"

    # 仅在 _meta.json 不存在时创建（仓库可能已包含）
    if [[ -f "${meta_file}" ]]; then
        echo "  _meta.json 已存在，跳过创建"
        return 0
    fi

    local now_ms=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))

    cat > "${meta_file}" << EOF
{
  "ownerId": "local",
  "slug": "${SKILL_NAME}",
  "version": "1.0.0",
  "publishedAt": ${now_ms}
}
EOF
    echo "  _meta.json 已创建: ${meta_file}"
}


# ── 主流程 ────────────────────────────────────────────────────

main() {
    echo ""
    printf "%b◆ Vita Skills → .pandacc 集成安装%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
    echo "─────────────────────────────────────────"
    echo ""

    if ! detect_pandacc; then
        exit 0
    fi

    link_skill
    link_bin
    ensure_path
    create_meta

    echo ""
    printf "%b✓ .pandacc 集成完成%b\n" "${C_GREEN}" "${C_RESET}"
    echo ""
    echo "验证:"
    echo "  ls -la ${PANDACC_HOME}/skills/${SKILL_NAME}"
    echo "  ls -la ${PANDACC_HOME}/bin/vita"
    echo "  ${PANDACC_HOME}/bin/vita status"
    echo "  source ~/.zshrc  # 使 PATH 生效"
    echo ""
}

main
