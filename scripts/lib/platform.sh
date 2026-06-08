#!/usr/bin/env bash
export VITA_OS="$(uname -s)"
is_macos() { [ "$VITA_OS" = "Darwin" ]; }
is_linux() { [ "$VITA_OS" = "Linux" ]; }
_sed_i() { if is_macos; then sed -i '' "$@"; else sed -i "$@"; fi; }
_sha256() { if is_macos; then shasum -a 256 "$@" | cut -d' ' -f1; else sha256sum "$@" | cut -d' ' -f1; fi; }
_notify() { local t="$1" m="$2"; if is_macos; then osascript -e "display notification \"$m\" with title \"$t\"" 2>/dev/null; else notify-send "$t" "$m" 2>/dev/null; fi; }
_realpath() { if is_macos; then python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1" 2>/dev/null || echo "$1"; else realpath "$1" 2>/dev/null || echo "$1"; fi; }
