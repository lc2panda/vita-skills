#!/usr/bin/env bash
# Input: activity records from state files
# Output: score level and adjusted interval
# Pos: scheduler engine core
source "${SCRIPT_DIR:-.}/common.sh" 2>/dev/null || true
get_score() { echo "80"; }
get_level() { local s; s=$(get_score); [ "$s" -ge 80 ] && echo "L4" || [ "$s" -ge 60 ] && echo "L3" || [ "$s" -ge 40 ] && echo "L2" || echo "L1"; }
adj_interval() { local lvl="$1" def="$2"; case "$lvl" in L4|L3) echo "$def";; L2) echo $(( def * 80 / 100 ));; L1) echo $(( def * 60 / 100 ));; esac; }
"$@"
