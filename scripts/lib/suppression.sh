#!/usr/bin/env bash
# Input:  系统状态（进程列表/IO注册表/摄像头状态/系统时钟）
# Output: 抑制策略判定结果（返回码 0=应抑制, 1=不抑制）
# Pos:    scripts/lib/suppression.sh — 由 common.sh 懒加载，提供屏幕锁定/会议/空闲/深夜检测
#
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

# 屏幕锁定/休眠检测 (macOS)
is_screen_locked() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        pgrep -x "loginwindow" > /dev/null 2>&1 || return 0
        local locked
        locked=$(python3 -c '
import Quartz
d = Quartz.CGSessionCopyCurrentDictionary()
print("1" if not d or d.get("CGSSessionScreenIsLocked", False) else "0")
' 2>/dev/null) || locked="0"
        [[ "$locked" == "1" ]] && return 0
    fi
    return 1
}

# 会议模式检测 (摄像头/麦克风占用)
is_in_meeting() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        if lsof -c "VDCAssistant" 2>/dev/null | grep -q "AppleCamera"; then
            return 0
        fi
        if pgrep -i -f "zoom\|Microsoft Teams\|FaceTime\|Google Meet\|ciscowebex\|Skype" > /dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

# 深夜静默判定 (23:00-07:00)
is_quiet_hours() {
    local hour
    hour=$(date +%H | sed 's/^0//')
    if [[ "$hour" -ge 23 || "$hour" -lt 7 ]]; then
        return 0
    fi
    return 1
}

# 用户空闲检测 (键盘/鼠标无输入 >5 分钟) — 仅 macOS
is_user_idle() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local idle_ms
        idle_ms=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000); exit}') || idle_ms=0
        if [[ "$idle_ms" -gt 300000 ]]; then
            return 0
        fi
    fi
    return 1
}
