#!/usr/bin/env bash
# Input: user provided display string
# Output: ok/invalid and device fingerprint
# Pos: setup wizard utility
validate() { local n="$1"; [ "${#n}" -ge 2 ] && [ "${#n}" -le 20 ] && [[ "$n" =~ ^[a-zA-Z0-9_\ -]+$ ]] && echo "ok" || echo "invalid"; }
device_id() { echo "$(hostname 2>/dev/null || echo unknown)-$(uname -s 2>/dev/null || echo unknown)" | shasum -a 256 2>/dev/null | cut -c1-16; }
"$@"
