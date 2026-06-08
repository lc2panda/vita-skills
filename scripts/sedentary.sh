#!/usr/bin/env bash
# Input:  config/default.yaml (sedentary 段) 或 ~/.vanilla-health/config.yaml
# Output: 系统通知（macOS osascript / Linux notify-send），三级递进久坐提醒消息
# Pos:    scripts/sedentary.sh — 久坐提醒执行脚本，由提醒调度引擎按间隔触发
#
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

set -euo pipefail

INTERVAL_MINUTES="${VITA_SEDENTARY_INTERVAL:-30}"
BREAK_SECONDS="${VITA_SEDENTARY_BREAK:-120}"
HARD_LIMIT_MINUTES="${VITA_SEDENTARY_HARD_LIMIT:-120}"

MESSAGE_L1="该起身活动了——站起来，做两个深呼吸，打开肩膀。"
MESSAGE_L2="研究显示：每30分钟起身2分钟，可降低血糖25%。现在活动一下？只需绕办公桌走两圈。"
MESSAGE_L3="没关系，现在开始也不晚。试试这个：站起来，双手举过头顶，深吸气——只要20秒。你的血管会感谢你的。"

# TODO: 实现心流检测 + 三级递进逻辑 + 系统通知发送
echo "[sedentary] interval=${INTERVAL_MINUTES}min break=${BREAK_SECONDS}s hard_limit=${HARD_LIMIT_MINUTES}min"
