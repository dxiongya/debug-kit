#!/usr/bin/env bash
# dk-pointer.sh — shared virtual-pointer service for debug-kit.
#
# Drives the resident software-cursor overlay (mac-overlay) by absolute SCREEN coordinates,
# so ANY platform whose UI renders in a macOS window (macOS apps, Chrome/Electron, Flutter
# desktop, the iOS Simulator window, …) can show *where the AI is interacting* — a gliding
# virtual pointer — WITHOUT moving the user's real cursor.
#
# Two ways to use it:
#   source dk-pointer.sh ;  dk_pointer tap <screenX> <screenY>     # functions, for bash ctls
#   bash   dk-pointer.sh    tap <screenX> <screenY>                # CLI, for non-bash callers
#                          stop                                    # stop the resident pointer
#
# Coordinates are top-left absolute screen points. Same daemon/protocol as mac-ctl (one
# shared resident cursor). Env: DK_POINTER=on|off (default on; MAC_POINTER honored as alias).

_DKP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DKP_SRC="$_DKP_DIR/mac-overlay.swift"
DKP_BIN="/tmp/.debug-kit-overlay"
DKP_GLYPH="$_DKP_DIR/assets/software-cursor.png"
DKP_PID="/tmp/.debug-kit-ptr.pid"
DKP_CMDS="/tmp/.debug-kit-ptr-cmds"

dk_pointer_enabled() { [[ "${DK_POINTER:-${MAC_POINTER:-on}}" != "off" ]]; }

_dkp_alive() { local p; p=$(cat "$DKP_PID" 2>/dev/null) || return 1; [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }

# Compile (once) + start the resident cursor daemon. Returns non-zero if disabled/unavailable.
dk_pointer_ensure() {
    dk_pointer_enabled || return 1
    [[ "$(uname)" == "Darwin" ]] || return 1
    if [[ ! -x "$DKP_BIN" || "$DKP_SRC" -nt "$DKP_BIN" ]]; then
        command -v swiftc >/dev/null 2>&1 || return 1
        swiftc -O "$DKP_SRC" -o "$DKP_BIN" 2>/dev/null || return 1
    fi
    if ! _dkp_alive; then
        : > "$DKP_CMDS"; rm -f "$DKP_PID"
        local g=""; [[ -f "$DKP_GLYPH" ]] && g="$DKP_GLYPH"
        ( "$DKP_BIN" "$g" >/dev/null 2>&1 & ) 2>/dev/null || true
        local i; for i in $(seq 1 15); do _dkp_alive && break; sleep 0.1; done
    fi
    _dkp_alive
}

# Glide the resident cursor to a screen point. Usage: dk_pointer <move|tap|click|drag|type|key> <x> <y> [x2 y2]
dk_pointer() {
    dk_pointer_enabled || return 0
    dk_pointer_ensure || return 0
    echo "$*" >> "$DKP_CMDS"
}

dk_pointer_stop() {
    if _dkp_alive; then echo "quit" >> "$DKP_CMDS"; sleep 0.3; fi
    pkill -f "$DKP_BIN" 2>/dev/null || true
    rm -f "$DKP_PID"
}

# CLI mode (executed, not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        stop)  dk_pointer_stop ;;
        status) _dkp_alive && echo "pointer running (pid $(cat "$DKP_PID"))" || echo "pointer not running" ;;
        ""|-h|--help) echo "usage: dk-pointer.sh <move|tap|click|drag> <screenX> <screenY> [x2 y2] | stop | status" ;;
        *)     dk_pointer "$@" ;;
    esac
fi
