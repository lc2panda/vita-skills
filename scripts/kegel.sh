#!/usr/bin/env bash
# Input:  config/default.yaml (kegel 段) 或 ~/.vanilla-health/config.yaml
# Output: 系统通知（隐私文案），分阶段凯格尔训练提醒
# Pos:    scripts/kegel.sh — 提肛锻炼提醒执行脚本，由提醒调度引擎按次数触发
#
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

set -euo pipefail

REMINDERS_PER_DAY="${VITA_KEGEL_REMINDERS:-3}"
STAGE="${VITA_KEGEL_STAGE:-beginner}"
PRIVACY_MODE="${VITA_KEGEL_PRIVACY:-true}"

# 分阶段参数
case "$STAGE" in
  beginner)  HOLD_SEC=3  REPS=10  SETS=3 ;;
  transition) HOLD_SEC=5 REPS=8   SETS=3 ;;
  standard)  HOLD_SEC=5  REPS=10  SETS=3 ;;
  advanced)  HOLD_SEC=10 REPS=15  SETS=3 ;;
  *)         HOLD_SEC=3  REPS=10  SETS=3 ;;
esac

MESSAGE="起身活动一下 | 今天还有若干组核心锻炼未完成"

# TODO: 实现隐私模式文案 + 系统通知 + 每日计数重置
echo "[kegel] reminders_per_day=${REMINDERS_PER_DAY} stage=${STAGE} hold=${HOLD_SEC}s reps=${REPS} sets=${SETS} privacy=${PRIVACY_MODE}"
