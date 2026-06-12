#!/usr/bin/env bash
# tauri-ctl.sh - Tauri app debug tool for Claude Code
# Uses: tauri CLI, cargo, mac-ctl.sh (Accessibility API + CGEvent)
#
# Tauri's WKWebView does not expose CDP, but macOS Accessibility API
# reads the DOM *through* WKWebView as native elements. So inspection
# and interaction are delegated to mac-ctl.sh without any extra runtime
# dependency (no tauri-driver, no WebDriver).
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_CTL="$SCRIPT_DIR/mac-ctl.sh"
STATE_FILE="/tmp/.tauri-debug-state.json"
LOG_FILE="/tmp/tauri-debug.log"

save_state() { echo "$1" > "$STATE_FILE"; }

# Requires jq (pre-installed on most dev machines; brew install jq if missing).
if ! command -v jq >/dev/null 2>&1; then
    fail "jq is required but not installed. Run: brew install jq"
    exit 1
fi

# Read productName from tauri.conf.json — that's what the dev binary and
# the running process name are called. Tauri 2.x scaffolds pure JSON, so
# we can feed it to jq directly. (Older Tauri 1.x tooling sometimes
# emitted JSON with comments; if you hit that, pre-process with a proper
# JSONC parser — a naive sed strips URL `//` inside strings.)
_product_name() {
    local project_dir="$1"
    local conf="$project_dir/src-tauri/tauri.conf.json"
    if [[ ! -f "$conf" ]]; then
        fail "Not a Tauri project: $conf not found"
        return 1
    fi
    jq -r '.productName // "tauri-app"' "$conf"
}

_current_app_name() {
    local name="${TAURI_APP:-}"
    if [[ -z "$name" && -f "$STATE_FILE" ]]; then
        name=$(jq -r '.name // empty' "$STATE_FILE" 2>/dev/null || echo "")
    fi
    if [[ -z "$name" ]]; then
        fail "No Tauri app name. Run 'dev' first or set TAURI_APP."
        return 1
    fi
    echo "$name"
}

# ─── Build & Run ───

cmd_dev() {
    local project_dir="${1:-.}"
    cd "$project_dir"

    local name
    name=$(_product_name "$(pwd)") || return 1

    echo "Starting Tauri dev: $name"
    echo "Project: $(pwd)"

    # Run tauri dev in the background. We capture stdout+stderr to LOG_FILE.
    nohup pnpm tauri dev > "$LOG_FILE" 2>&1 &
    local pid=$!
    disown 2>/dev/null || true

    # Wait for the native window to appear — that's the true "ready" signal,
    # not vite's ready message. Poll up to 300s to allow first cargo build
    # (a cold Tauri 2.x build compiles ~400 crates; can take several minutes).
    local ready=0
    for i in $(seq 1 300); do
        sleep 1
        if pgrep -f "target/debug/$name" >/dev/null 2>&1; then
            if osascript -e "tell application \"System Events\" to exists (first process whose name is \"$name\")" 2>/dev/null | grep -q true; then
                ready=1
                break
            fi
        fi
        # Fail fast on cargo errors
        if grep -qE "^error\[E[0-9]+\]|^error:" "$LOG_FILE" 2>/dev/null; then
            fail "Cargo build error detected. See $LOG_FILE"
            tail -20 "$LOG_FILE"
            return 1
        fi
    done

    if [[ "$ready" != "1" ]]; then
        warn "Window did not appear within 90s. Check $LOG_FILE"
        tail -20 "$LOG_FILE"
        return 1
    fi

    save_state "{\"pid\":$pid,\"name\":\"$name\",\"dir\":\"$(pwd)\"}"
    ok "Tauri app running: $name (PID $pid)"
    echo "Log: $LOG_FILE"
}

cmd_build() {
    local project_dir="${1:-.}"
    cd "$project_dir"

    local name
    name=$(_product_name "$(pwd)") || return 1
    echo "Building Tauri release: $name"
    pnpm tauri build 2>&1 | tail -20
    local bundle="src-tauri/target/release/bundle"
    if [[ -d "$bundle" ]]; then
        ok "Bundle dir: $bundle"
        find "$bundle" -maxdepth 3 \( -name "*.app" -o -name "*.dmg" \) 2>/dev/null | head -5
    fi
}

cmd_stop() {
    local name=""
    if [[ -f "$STATE_FILE" ]]; then
        name=$(jq -r '.name // empty' "$STATE_FILE" 2>/dev/null || echo "")
    fi
    # Kill the native binary first (stops the window)
    if [[ -n "$name" ]]; then
        pkill -f "target/debug/$name" 2>/dev/null || true
    fi
    # Kill tauri CLI + its vite child + beforeDevCommand
    pkill -f "@tauri-apps/cli/tauri.js dev" 2>/dev/null || true
    pkill -f "vite.*1430" 2>/dev/null || true
    pkill -f "pnpm tauri dev" 2>/dev/null || true
    rm -f "$STATE_FILE"
    ok "Tauri app stopped"
}

# ─── Inspection (delegate to mac-ctl.sh) ───

cmd_tree() {
    local name; name=$(_current_app_name) || return 1
    MAC_APP="$name" bash "$MAC_CTL" tree "$@"
}

cmd_read() {
    local name; name=$(_current_app_name) || return 1
    MAC_APP="$name" bash "$MAC_CTL" read "$@"
}

cmd_screenshot() {
    local output="${1:-/tmp/tauri-screenshot.png}"
    local name; name=$(_current_app_name) || return 1
    MAC_APP="$name" bash "$MAC_CTL" screenshot "$output"
}

# ─── Interaction (delegate to mac-ctl.sh) ───

cmd_tap() {
    local name; name=$(_current_app_name) || return 1
    MAC_APP="$name" bash "$MAC_CTL" tap "$@"
}

# Background-tap: AXPress via WKWebView's AX bridge — 0 mouse impact.
# Tauri's web UI is fully exposed to macOS Accessibility because WKWebView
# bridges ARIA roles + button text into the AX tree, so id/title/desc
# selectors all work the same way as native AppKit/SwiftUI apps.
cmd_tap_bg() {
    local name; name=$(_current_app_name) || return 1
    MAC_APP="$name" bash "$MAC_CTL" tap-bg "$@"
}

cmd_type() {
    local name; name=$(_current_app_name) || return 1
    MAC_APP="$name" bash "$MAC_CTL" type "$@"
}

cmd_type_bg() {
    local name; name=$(_current_app_name) || return 1
    MAC_APP="$name" bash "$MAC_CTL" type-bg "$@"
}

cmd_key() {
    local name; name=$(_current_app_name) || return 1
    MAC_APP="$name" bash "$MAC_CTL" key "$@"
}

cmd_window() {
    local name; name=$(_current_app_name) || return 1
    MAC_APP="$name" bash "$MAC_CTL" window "$@"
}

# ─── Logs ───

cmd_log() {
    local lines="${1:-50}"
    if [[ -f "$LOG_FILE" ]]; then
        echo "=== Tauri dev log (last $lines lines) ==="
        tail -"$lines" "$LOG_FILE"
    else
        fail "No log file. Run 'dev' first."
    fi
}

# ─── Health ───

cmd_health() {
    echo "=== Tauri debug health check ==="

    if command -v cargo >/dev/null 2>&1; then
        ok "cargo: $(cargo --version)"
    else
        fail "cargo not found"
    fi
    if command -v pnpm >/dev/null 2>&1; then
        ok "pnpm: $(pnpm --version)"
    else
        warn "pnpm not found (npm/yarn also work but tauri-ctl assumes pnpm)"
    fi
    if command -v rustc >/dev/null 2>&1; then
        ok "rustc: $(rustc --version)"
    fi

    if [[ -f "$STATE_FILE" ]]; then
        local pid name
        pid=$(jq -r '.pid // 0' "$STATE_FILE" 2>/dev/null || echo 0)
        name=$(jq -r '.name // empty' "$STATE_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" && "$pid" != "0" ]] && kill -0 "$pid" 2>/dev/null; then
            ok "Tauri app running: $name (PID $pid)"
        else
            warn "Tracked PID $pid not alive"
        fi
    else
        warn "No tracked Tauri app"
    fi

    if [[ -x "$MAC_CTL" ]]; then
        ok "mac-ctl.sh: $MAC_CTL"
    else
        fail "mac-ctl.sh not executable at $MAC_CTL"
    fi
}

# ─── Help ───

cmd_help() {
    cat << 'HELP'
tauri-ctl - Tauri app debug tool for Claude Code

RUN & LIFECYCLE:
  dev [dir]              Start `pnpm tauri dev`, wait for native window
  build [dir]            `pnpm tauri build` (release bundle)
  stop                   Kill tauri dev + vite + native binary

INSPECTION (via macOS Accessibility API — reads DOM through WKWebView):
  tree                   Accessibility tree of the Tauri window (full DOM)
  read <query>           Read specific element by text/role
  screenshot [path]      Capture window

INTERACTION (via CGEvent — no CDP needed):
  tap <x> <y>            Click at screen coords
  type "<text>"          Type text into focused input
  key <keyname>          Send key event
  window ...             Window position/size/front

LOGS & HEALTH:
  log [lines]            Tail tauri dev log
  health                 Toolchain + state check

ENV VARS:
  TAURI_APP              Override productName (normally auto-detected)

NOTES:
  - Tauri 2.x with WKWebView on macOS. Accessibility API exposes the full
    DOM tree as native roles (links, buttons, text fields, etc.). No CDP,
    no tauri-driver, no WebDriver required.
  - `dev` tracks state in /tmp/.tauri-debug-state.json so subsequent
    tree/tap/type/screenshot commands auto-target the running app.
  - For DOM-level assertions beyond what AX exposes, enable devtools in
    tauri.conf.json and inspect manually via Safari Web Inspector.
HELP
}

# ─── Main ───

cmd="${1:-help}"
shift 2>/dev/null || true

case "$cmd" in
    dev)         cmd_dev "$@" ;;
    build)       cmd_build "$@" ;;
    stop)        cmd_stop ;;
    tree)        cmd_tree "$@" ;;
    read)        cmd_read "$@" ;;
    screenshot)  cmd_screenshot "$@" ;;
    tap)         cmd_tap "$@" ;;
    tap-bg)      cmd_tap_bg "$@" ;;
    type-bg)     cmd_type_bg "$@" ;;
    type)        cmd_type "$@" ;;
    key)         cmd_key "$@" ;;
    window)      cmd_window "$@" ;;
    log)         cmd_log "$@" ;;
    health)      cmd_health ;;
    help|--help|-h) cmd_help ;;
    *)           echo "Unknown: $cmd"; cmd_help ;;
esac
