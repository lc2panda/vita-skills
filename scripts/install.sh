#!/usr/bin/env bash
# Input:  安装模式 (auto|interactive)，由 vita setup 或其他脚本调用
# Output: 创建 ~/.vita/ 目录结构，复制默认配置，可选 shell profile 集成；开机自启不再静默注册，需用户显式执行 'vita autostart enable'
# Pos:    scripts/install.sh — 首次安装与配置向导

# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 加载打榜客户端库 ─────────────────────────────────────────
LB_CLIENT="${SCRIPT_DIR}/lib/leaderboard-client.sh"
if [[ -f "${LB_CLIENT}" ]]; then
    set +u  # 库内部可能引用未设置变量
    source "${LB_CLIENT}"
    set -u
fi

# 直接定义基本变量（避免 source common.sh 时的循环依赖）
VITA_HOME="${HOME}/.vita"
CONFIG_DIR="$VITA_HOME/config"
LOG_DIR="$VITA_HOME/logs"
STATE_DIR="$VITA_HOME/state"
RUN_DIR="$VITA_HOME/run"

MODE="${1:-auto}"

# ── 目录创建 ──────────────────────────────────────────────

create_dirs() {
    echo "创建目录结构..."
    mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$STATE_DIR" "$RUN_DIR"
    echo "  ~/.vita/"
    echo "  ~/.vita/config/"
    echo "  ~/.vita/logs/"
    echo "  ~/.vita/state/"
    echo "  ~/.vita/run/"
    echo ""
}

# ── 复制默认配置 ──────────────────────────────────────────

copy_config() {
    echo "创建默认配置..."

    local default_config="$SCRIPT_DIR/../config/default.yaml"
    local user_config="$CONFIG_DIR/config.yaml"

    if [[ -f "$user_config" ]]; then
        echo "  配置文件已存在: $user_config"
        if [[ "$MODE" == "interactive" ]]; then
            read -r -p "  是否覆盖？[y/N] " confirm
            if [[ ! "$confirm" =~ ^[Yy] ]]; then
                echo "  保留现有配置"
                return 0
            fi
        else
            echo "  保留现有配置"
            return 0
        fi
    fi

    if [[ -f "$default_config" ]]; then
        cp "$default_config" "$user_config"
        echo "  配置已复制到: $user_config"
    else
        echo "  警告: 默认配置文件未找到 ($default_config)"
        echo "  将创建最小配置..."
        cat > "$user_config" << 'MINCONFIG'
# Vita 健康守护 — 用户配置
# 完整配置项参见 config/default.yaml
MINCONFIG
    fi
    echo ""
}

# ── 交互式配置 ────────────────────────────────────────────

interactive_setup() {
    if [[ "$MODE" != "interactive" ]]; then
        return
    fi

    echo "◆ 个性化设置"
    echo "─────────────────────────────────────────"

    # 性别
    echo ""
    read -r -p "性别 (male/female/other) [male]: " gender
    gender="${gender:-male}"

    # ── 打榜注册 ──
    echo ""
    echo "◆ 全球打榜PK"
    echo "─────────────────────────────────────────"
    echo "和其他玩家比拼锻炼完成率，查看排行榜排名。"
    read -r -p "是否参与打榜？[Y/n] " leaderboard_enabled
    leaderboard_enabled="${leaderboard_enabled:-y}"

    if [[ "$leaderboard_enabled" =~ ^[Yy] ]]; then
        leaderboard_enabled="true"
        read -r -p "打榜显示名称 [匿名战士]: " lb_display
        lb_display="${lb_display:-匿名战士}"

        if declare -f lb_register >/dev/null 2>&1; then
            echo -n "  注册打榜账号..."
            local lb_uid
            lb_uid="$(lb_register "$lb_display" 2>/dev/null)" || true
            if [[ -n "$lb_uid" ]]; then
                echo " 已加入 (ID: ${lb_uid})"
            else
                echo " 网络不通，将在首次联网时自动重试"
            fi
        else
            echo "  打榜客户端库未找到，跳过注册 (leaderboard-client.sh)"
        fi
    else
        leaderboard_enabled="false"
        if declare -f lb_set_privacy_mode >/dev/null 2>&1; then
            lb_set_privacy_mode "true" 2>/dev/null || true
        fi
        echo "  已设置隐私模式，不参与打榜"
    fi

    # 久坐提醒间隔
    echo ""
    echo "◆ 提醒间隔设置"
    echo "─────────────────────────────────────────"
    read -r -p "久坐提醒间隔 (分钟) [30]: " sed_interval
    sed_interval="${sed_interval:-30}"
    read -r -p "护眼提醒间隔 (分钟) [50]: " eye_interval
    eye_interval="${eye_interval:-50}"
    read -r -p "喝水提醒间隔 (分钟) [75]: " hyd_interval
    hyd_interval="${hyd_interval:-75}"

    echo ""
    echo "◆ 提肛设置"
    echo "─────────────────────────────────────────"
    if [[ "$gender" == "female" ]]; then
        echo "提肛训练对女性尤为重要——可预防压力性尿失禁、改善产后恢复。"
    else
        echo "提肛训练对男性同样重要——可增强盆底肌、改善排尿控制。"
    fi
    read -r -p "启用提肛提醒？[Y/n] " tigang_enabled
    tigang_enabled="${tigang_enabled:-y}"
    [[ "$tigang_enabled" =~ ^[Yy] ]] && tigang_enabled="true" || tigang_enabled="false"

    # 更新配置
    local config_file="$CONFIG_DIR/config.yaml"
    if [[ -f "$config_file" ]]; then
        # 使用临时文件
        local tmp_config; tmp_config=$(mktemp)
        sed -e "s/interval_minutes: 30/interval_minutes: ${sed_interval}/" \
            -e "s/interval_minutes: 50/interval_minutes: ${eye_interval}/" \
            -e "s/interval_minutes: 75/interval_minutes: ${hyd_interval}/" \
            -e "s/leaderboard_enabled: false/leaderboard_enabled: ${leaderboard_enabled}/" \
            "$config_file" > "$tmp_config"
        mv "$tmp_config" "$config_file"
    fi

    echo ""
    echo "✓ 个性化设置完成"
    echo ""
}

# ── shell profile 集成 ─────────────────────────────────────

setup_profile() {
    echo "◆ Shell 自动加载"
    echo "─────────────────────────────────────────"

    local profile_file=""
    local shell_name=""

    # 检测 shell
    if [[ "$SHELL" == *"zsh"* ]]; then
        profile_file="$HOME/.zshrc"
        shell_name="zsh"
    elif [[ "$SHELL" == *"bash"* ]]; then
        if [[ -f "$HOME/.bash_profile" ]]; then
            profile_file="$HOME/.bash_profile"
        else
            profile_file="$HOME/.bashrc"
        fi
        shell_name="bash"
    else
        profile_file="$HOME/.profile"
        shell_name="sh"
    fi

    local vita_path="$SCRIPT_DIR/vita"
    local alias_line="alias vita='$vita_path'"

    if grep -q "alias vita=" "$profile_file" 2>/dev/null; then
        echo "  alias 已存在于 $profile_file"
    else
        if [[ "$MODE" == "interactive" ]]; then
            read -r -p "是否添加 'vita' 别名到 $profile_file？[Y/n] " confirm
            confirm="${confirm:-y}"
            if [[ ! "$confirm" =~ ^[Yy] ]]; then
                echo "  已跳过"
                return
            fi
        fi
        echo "" >> "$profile_file"
        echo "# Vita 健康守护" >> "$profile_file"
        echo "$alias_line" >> "$profile_file"
        echo "  已添加别名到 $profile_file"
    fi

    echo ""
}

# ── crontab/launchd 设置 ──────────────────────────────────

setup_autostart() {
    echo "◆ 开机自启设置"
    echo "─────────────────────────────────────────"

    if [[ "$MODE" != "interactive" ]]; then
        echo "  开机自启需要手动设置: vita autostart enable"
        echo ""
        return
    fi

    read -r -p "是否设置开机自启？[Y/n] " confirm
    confirm="${confirm:-y}"
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        echo "  已跳过"
        echo ""
        return
    fi

    if [[ "$(uname -s)" == "Darwin" ]]; then
        setup_launchd
    else
        setup_systemd
    fi
    echo ""
}

setup_launchd() {
    local plist_path="$HOME/Library/LaunchAgents/com.vanilla.vita.plist"
    local vita_path="$SCRIPT_DIR/vita"

    # 如果已存在则跳过
    if [[ -f "$plist_path" ]]; then
        echo "  LaunchAgent 已存在: $plist_path"
        return
    fi

    cat > "$plist_path" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.vanilla.vita</string>
    <key>ProgramArguments</key>
    <array>
        <string>$vita_path</string>
        <string>start</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/launchd.log</string>
</dict>
</plist>
PLISTEOF

    # 加载
    launchctl load "$plist_path" 2>/dev/null || true
    echo "  LaunchAgent 已创建并加载: $plist_path"
}

setup_systemd() {
    local service_path="$HOME/.config/systemd/user/com.vanilla.vita.service"
    local vita_path="$SCRIPT_DIR/vita"

    mkdir -p "$HOME/.config/systemd/user"

    if [[ -f "$service_path" ]]; then
        echo "  systemd 用户单元已存在: $service_path"
        return
    fi

    cat > "$service_path" << SYSTEMDEOF
[Unit]
Description=Vita Health Guardian

[Service]
ExecStart=$vita_path start
ExecStop=$vita_path stop
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
SYSTEMDEOF

    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable com.vanilla.vita.service 2>/dev/null || true
    echo "  systemd 用户单元已创建: $service_path"
}

# ── 安装完成 ──────────────────────────────────────────────

# ── .pandacc 集成 ─────────────────────────────────────────

setup_pandacc() {
    echo "◆ .pandacc 集成检测"
    echo "─────────────────────────────────────────"

    local pandacc_dir="${HOME}/.pandacc"
    if [[ ! -d "$pandacc_dir" ]]; then
        echo "  .pandacc 目录未找到，跳过集成"
        echo ""
        return 0
    fi

    echo "  检测到 .pandacc 体系，自动配置集成..."

    local pandacc_install="${SCRIPT_DIR}/pandacc-install.sh"
    if [[ -f "$pandacc_install" ]]; then
        bash "$pandacc_install"
    else
        echo "  警告: pandacc-install.sh 未找到，使用内联集成"

        # Skills 软链接
        local skill_link="${pandacc_dir}/skills/vita-health"
        local repo_root; repo_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
        mkdir -p "${pandacc_dir}/skills"
        if [[ ! -L "$skill_link" ]]; then
            ln -s "$repo_root" "$skill_link"
            echo "  技能软链接已创建: ${skill_link}"
        else
            echo "  技能软链接已存在"
        fi

        # bin 软链接
        local bin_link="${pandacc_dir}/bin/vita"
        mkdir -p "${pandacc_dir}/bin"
        if [[ ! -L "$bin_link" ]]; then
            ln -s "${repo_root}/scripts/vita" "$bin_link"
            echo "  bin 软链接已创建: ${bin_link}"
        else
            echo "  bin 软链接已存在"
        fi
    fi

    echo ""
}

# ── 安装完成 ──────────────────────────────────────────────

print_summary() {
    echo ""
    printf "%b◆ 安装完成！%b\n" "${C_GREEN}" "${C_RESET}"
    echo "─────────────────────────────────────────"
    echo ""
    echo "目录结构:"
    echo "  ~/.vita/config/    — 配置文件"
    echo "  ~/.vita/logs/      — 日志文件"
    echo "  ~/.vita/state/     — 状态数据"
    echo "  ~/.vita/run/       — 运行时文件"
    echo ""
    echo "下一步:"
    echo "  source ~/.zshrc    # 重新加载 shell 配置"
    echo "  vita start         # 启动健康守护"
    echo "  vita status        # 查看状态"
    echo "  vita test          # 测试提醒"
    echo ""
}

# ── 主流程 ────────────────────────────────────────────────

main() {
    echo ""
    printf "%b◆ Vita 健康守护安装 (%s)%b\n" "${C_BOLD}${C_CYAN}" "$MODE" "${C_RESET}"
    echo "─────────────────────────────────────────"
    echo ""

    create_dirs
    copy_config
    interactive_setup
    setup_profile
    setup_autostart
    setup_pandacc
    print_summary
}

main
