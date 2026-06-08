#!/usr/bin/env bash
# Input:  无 — 读取环境变量/系统信息
# Output: 设置用户级默认配置变量，可被 ~/.vitarc 覆盖
# Pos:    scripts/lib/vitarc.sh — 用户级配置加载，允许 ~/.vitarc 覆盖项目默认值
#
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

# ═══════════════════════════════════════════════════════════════════
# vitarc — 用户级配置加载器
# ═══════════════════════════════════════════════════════════════════
# 加载顺序:
#   1. 本项目 config/default.yaml (核心默认值，由 common.sh 管理)
#   2. ~/.vitarc (用户级覆盖，此脚本管理)
#   3. 环境变量 (最高优先级)
#
# ~/.vitarc 格式: 标准的 bash 变量定义文件，可覆盖:
#   - 提醒间隔、阈值、免打扰时段
#   - 通知偏好、日志级别
#   - 心流检测灵敏度
#   - 打榜服务器地址
#
# 示例 ~/.vitarc:
#   export VITA_SEDENTARY_INTERVAL=45
#   export VITA_EYE_INTERVAL=25
#   export VITA_DND="22:00-08:00"
#   export VITA_LOG_LEVEL="INFO"
#   export VITA_LEADERBOARD_URL="https://my-server.com/api"
# ═══════════════════════════════════════════════════════════════════

# 加载用户级配置
_load_vitarc() {
    local vitarc_file="${HOME}/.vitarc"
    if [[ -f "$vitarc_file" ]]; then
        # 安全加载: 仅在子 shell 中解析，只导出白名单变量
        while IFS='=' read -r key val; do
            [[ -z "$key" ]] && continue
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            key="${key##[[:space:]]}"
            key="${key%%[[:space:]]}"
            # 移除 export 前缀
            key="${key#export }"
            # 只允许 VITA_ 前缀的变量
            if [[ "$key" =~ ^VITA_ ]]; then
                val="${val#[\"\']}"
                val="${val%[\"\']}"
                val="${val##[[:space:]]}"
                val="${val%%[[:space:]]}"
                export "${key}=${val}"
            fi
        done < "$vitarc_file"
        return 0
    fi
    return 1
}

# 自动加载（首次 source 时执行）
_load_vitarc || true
