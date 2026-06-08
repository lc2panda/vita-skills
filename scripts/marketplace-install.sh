#!/usr/bin/env bash
# Input:  无参数；通过 curl pipe 调用，支持 marketplace 一键安装
# Output: 自动检测环境 → 克隆/更新仓库 → 创建软链接 → 初始化配置 → 输出成功提示
# Pos:    scripts/marketplace-install.sh — marketplace 一键安装入口

# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

set -euo pipefail

# ── 常量 ──────────────────────────────────────────────────────────
REPO_URL="https://github.com/lc2panda/vita-skills.git"
INSTALL_DIR="${HOME}/vita-skills"
SKILL_NAME="vita-health"
VITA_BIN="${INSTALL_DIR}/scripts/vita"

# ── 颜色 ──────────────────────────────────────────────────────────
C_GREEN='\033[0;32m'
C_CYAN='\033[0;36m'
C_YELLOW='\033[0;33m'
C_RED='\033[0;31m'
C_BOLD='\033[1m'
C_RESET='\033[0m'

# ── 工具函数 ─────────────────────────────────────────────────────

info()    { printf "%b[INFO]%b %s\n"    "${C_CYAN}" "${C_RESET}" "$*"; }
success() { printf "%b[OK]%b %s\n"      "${C_GREEN}" "${C_RESET}" "$*"; }
warn()    { printf "%b[WARN]%b %s\n"    "${C_YELLOW}" "${C_RESET}" "$*"; }
error()   { printf "%b[ERROR]%b %s\n"   "${C_RED}" "${C_RESET}" "$*"; }

# ── 环境检测 ─────────────────────────────────────────────────────

detect_environment() {
    local has_pandacc=false
    local has_git=false
    local has_bash=true

    # 检测 .pandacc 目录
    if [[ -d "${HOME}/.pandacc" ]]; then
        has_pandacc=true
    fi

    # 检测 git
    if command -v git &>/dev/null; then
        has_git=true
    fi

    # 返回检测结果（通过全局变量传递）
    PANDACC_DETECTED="$has_pandacc"
    GIT_DETECTED="$has_git"
    BASH_DETECTED="$has_bash"
}

# ── 仓库操作 ─────────────────────────────────────────────────────

clone_or_update_repo() {
    if [[ "$GIT_DETECTED" != "true" ]]; then
        error "未检测到 git 命令，无法克隆仓库"
        error "请先安装 git: https://git-scm.com/downloads"
        exit 1
    fi

    if [[ -d "$INSTALL_DIR/.git" ]]; then
        info "检测到已有仓库，执行更新..."
        cd "$INSTALL_DIR"
        git fetch origin 2>/dev/null || warn "git fetch 失败，继续使用本地版本"
        git reset --hard origin/main 2>/dev/null || warn "git reset 失败，使用当前本地版本"
        success "仓库已更新至最新版本"
    else
        info "克隆仓库到 ${INSTALL_DIR} ..."
        if [[ -d "$INSTALL_DIR" ]]; then
            # 目录存在但不是 git 仓库，备份
            local backup="${INSTALL_DIR}.bak-$(date +%Y%m%d%H%M%S)"
            warn "目标路径已存在且非 git 仓库，备份至 ${backup}"
            mv "$INSTALL_DIR" "$backup"
        fi
        git clone "$REPO_URL" "$INSTALL_DIR"
        success "仓库克隆完成"
    fi
}

# ── 独立模式安装 ─────────────────────────────────────────────────

install_standalone() {
    info "执行独立模式安装..."

    # 确保 vita 脚本可执行
    chmod +x "$VITA_BIN" 2>/dev/null || true

    # 添加 shell alias
    local profile_file=""
    if [[ "$SHELL" == *"zsh"* ]]; then
        profile_file="$HOME/.zshrc"
    elif [[ "$SHELL" == *"bash"* ]]; then
        profile_file="$HOME/.bashrc"
    else
        profile_file="$HOME/.profile"
    fi

    local alias_line="alias vita='${VITA_BIN}'"
    if grep -q "alias vita=" "$profile_file" 2>/dev/null; then
        info "vita alias 已存在于 ${profile_file}"
    else
        echo "" >> "$profile_file"
        echo "# Vita Skills 健康管理系统" >> "$profile_file"
        echo "$alias_line" >> "$profile_file"
        success "vita alias 已添加到 ${profile_file}"
        info "请执行 source ${profile_file} 或重启终端使其生效"
    fi

    # 运行配置初始化
    if [[ -x "${INSTALL_DIR}/scripts/install.sh" ]]; then
        info "运行配置初始化..."
        bash "${INSTALL_DIR}/scripts/install.sh" auto
        success "配置初始化完成"
    fi
}

# ── .pandacc 集成 ─────────────────────────────────────────────────

install_pandacc() {
    info "检测到 .pandacc 目录，执行集成安装..."

    # 确保 pandacc-install.sh 可执行
    chmod +x "${INSTALL_DIR}/scripts/pandacc-install.sh" 2>/dev/null || true

    if [[ -x "${INSTALL_DIR}/scripts/pandacc-install.sh" ]]; then
        # pandacc-install.sh 直接读取 REPO_ROOT，需要从正确的目录运行
        cd "${INSTALL_DIR}/scripts"
        bash ./pandacc-install.sh
        success ".pandacc 集成完成"
    else
        # 回退到手动集成
        warn "pandacc-install.sh 不可用，执行手动集成..."

        # Skills 软链接
        local skills_target="${HOME}/.pandacc/skills/${SKILL_NAME}"
        mkdir -p "${HOME}/.pandacc/skills"
        if [[ -L "$skills_target" ]]; then
            rm "$skills_target"
        elif [[ -e "$skills_target" ]]; then
            mv "$skills_target" "${skills_target}.bak-$(date +%Y%m%d%H%M%S)"
        fi
        ln -s "$INSTALL_DIR" "$skills_target"
        info "技能软链接已创建: ${skills_target} -> ${INSTALL_DIR}"

        # bin 软链接
        local bin_target="${HOME}/.pandacc/bin/vita"
        mkdir -p "${HOME}/.pandacc/bin"
        if [[ -L "$bin_target" ]]; then
            rm "$bin_target"
        elif [[ -e "$bin_target" ]]; then
            mv "$bin_target" "${bin_target}.bak-$(date +%Y%m%d%H%M%S)"
        fi
        ln -s "$VITA_BIN" "$bin_target"
        chmod +x "$VITA_BIN" 2>/dev/null || true
        info "bin 软链接已创建: ${bin_target} -> ${VITA_BIN}"

        success ".pandacc 手动集成完成"
    fi

    # 确保 PATH 包含 .pandacc/bin
    local profile_file=""
    if [[ "$SHELL" == *"zsh"* ]]; then
        profile_file="$HOME/.zshrc"
    elif [[ "$SHELL" == *"bash"* ]]; then
        profile_file="$HOME/.bashrc"
    else
        profile_file="$HOME/.profile"
    fi

    local path_line='export PATH="$HOME/.pandacc/bin:$PATH"'
    if ! grep -q ".pandacc/bin" "$profile_file" 2>/dev/null; then
        echo "" >> "$profile_file"
        echo "# Panda CLI .pandacc 集成 (vita-skills)" >> "$profile_file"
        echo "$path_line" >> "$profile_file"
        success "PATH 已追加到 ${profile_file}"
    fi
}

# ── 运行初始化配置 ────────────────────────────────────────────────

run_init_config() {
    if [[ "$PANDACC_DETECTED" != "true" ]]; then
        # 独立模式下安装脚本已处理配置初始化，此处不再重复
        return 0
    fi

    if [[ -x "${INSTALL_DIR}/scripts/install.sh" ]]; then
        info "运行配置初始化..."
        bash "${INSTALL_DIR}/scripts/install.sh" auto
        success "配置初始化完成"
    fi
}

# ── 输出安装完成信息 ─────────────────────────────────────────────

print_success() {
    echo ""
    printf "%b" "${C_BOLD}${C_GREEN}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║         香草健康管理安装完成！              ║"
    echo "╚══════════════════════════════════════════════╝"
    printf "%b\n" "${C_RESET}"
    echo ""
    echo "  安装路径: ${INSTALL_DIR}"

    if [[ "$PANDACC_DETECTED" == "true" ]]; then
        echo "  集成模式: Panda CLI (.pandacc)"
        echo ""
        echo "  快速开始:"
        echo "    source ~/.zshrc     # 使 PATH 生效"
        echo "    vita start          # 启动健康守护"
        echo "    vita status         # 查看运行状态"
    else
        echo "  集成模式: 独立安装"
        echo ""
        echo "  快速开始:"
        echo "    source ~/.zshrc     # 使 alias 生效（或重启终端）"
        echo "    vita start          # 启动健康守护"
        echo "    vita status         # 查看运行状态"
    fi

    if [[ "$PANDACC_DETECTED" != "true" ]]; then
        echo ""
        echo "  可选: 后续如需集成到 Panda CLI，执行:"
        echo "    bash ${INSTALL_DIR}/scripts/pandacc-install.sh"
    fi

    echo ""
}

# ── 主流程 ────────────────────────────────────────────────────────

main() {
    echo ""
    printf "%b◆ 香草健康管理 (Vita Skills) — Marketplace 安装%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
    echo "──────────────────────────────────────────────────"
    echo ""

    detect_environment

    info "环境检测结果:"
    info "  .pandacc: ${PANDACC_DETECTED}"
    info "  git:      ${GIT_DETECTED}"
    echo ""

    # 1. 克隆/更新仓库
    clone_or_update_repo

    # 2. 集成安装
    if [[ "$PANDACC_DETECTED" == "true" ]]; then
        install_pandacc
    else
        install_standalone
    fi

    # 3. 初始化配置
    run_init_config

    # 4. 输出结果
    print_success
}

main "$@"
