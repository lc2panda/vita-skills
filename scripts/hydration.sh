#!/usr/bin/env bash
# Input:  config/default.yaml (hydration 段) 或 ~/.vanilla-health/config.yaml
# Output: 系统通知（含进度反馈），日志记录每日饮水统计
# Pos:    scripts/hydration.sh — 喝水提醒执行脚本，由提醒调度引擎按间隔触发
#
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

set -euo pipefail

INTERVAL_MINUTES="${VITA_HYDRATION_INTERVAL:-75}"
TARGET_PER_DRINK_ML="${VITA_HYDRATION_AMOUNT:-200}"
DAILY_TARGET_ML="${VITA_HYDRATION_DAILY:-2000}"
START_TIME="${VITA_HYDRATION_START:-09:00}"
END_TIME="${VITA_HYDRATION_END:-18:00}"

MESSAGE="喝水时间 | 该补充${TARGET_PER_DRINK_ML}mL（约1杯）了"

# TODO: 实现进度追踪（今日已饮/总目标）+ 系统通知 + 日统计持久化
echo "[hydration] interval=${INTERVAL_MINUTES}min amount=${TARGET_PER_DRINK_ML}mL daily=${DAILY_TARGET_ML}mL window=${START_TIME}-${END_TIME}"
