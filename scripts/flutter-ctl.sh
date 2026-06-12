#!/usr/bin/env bash
# flutter-ctl.sh - Flutter app debug tool for Claude Code
# Uses: flutter CLI, Dart VM Service, xcrun simctl (iOS), screencapture
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

STATE_FILE="/tmp/.flutter-debug-state.json"
LOG_FILE="/tmp/flutter-debug.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

save_state() { echo "$1" > "$STATE_FILE"; }
load_state() { cat "$STATE_FILE" 2>/dev/null; }

# ─── Run ───

cmd_run() {
    local project_dir="${1:-.}"
    local device="${FLUTTER_DEVICE:-}"

    cd "$project_dir"

    if [[ ! -f pubspec.yaml ]]; then
        fail "Not a Flutter project (no pubspec.yaml)"
        return 1
    fi

    # Auto-detect device
    if [[ -z "$device" ]]; then
        # Prefer iOS simulator if booted
        if xcrun simctl list devices booted 2>/dev/null | grep -q "Booted"; then
            device="iPhone"
            echo "Auto-detected: iOS Simulator"
        elif [[ -d "/Applications/Google Chrome.app" ]]; then
            device="chrome"
            echo "Auto-detected: Chrome (web)"
        else
            device="macos"
            echo "Auto-detected: macOS"
        fi
    fi

    echo "Running Flutter app on $device..."
    echo "Project: $project_dir"

    # Run flutter in the background, capture the VM service URL
    flutter run -d "$device" --verbose 2>&1 | tee "$LOG_FILE" &
    local flutter_pid=$!

    # Wait for the Dart VM Service URL
    echo "Waiting for Dart VM Service..."
    local vm_url=""
    for i in $(seq 1 60); do
        sleep 2
        vm_url=$(grep -oE "http://127\.0\.0\.1:[0-9]+/[a-zA-Z0-9_=]+/" "$LOG_FILE" 2>/dev/null | tail -1)
        if [[ -n "$vm_url" ]]; then
            break
        fi
        # Also check for "Flutter DevTools" URL
        vm_url=$(grep -oE "Dart VM service is available at: (http://[^ ]+)" "$LOG_FILE" 2>/dev/null | sed 's/.*: //' | tail -1)
        if [[ -n "$vm_url" ]]; then
            break
        fi
    done

    local state="{\"pid\":$flutter_pid,\"device\":\"$device\",\"dir\":\"$project_dir\""
    if [[ -n "$vm_url" ]]; then
        ok "VM Service: $vm_url"
        state="$state,\"vmServiceUrl\":\"$vm_url\""
    else
        warn "VM Service URL not detected after 120s"
    fi
    state="$state}"
    save_state "$state"

    ok "Flutter app running (PID: $flutter_pid)"
    echo "Log: $LOG_FILE"
}

cmd_stop() {
    local state
    state=$(load_state)
    if [[ -n "$state" ]]; then
        local pid
        pid=$(echo "$state" | python3 -c "import sys,json;print(json.load(sys.stdin).get('pid',0))" 2>/dev/null)
        if [[ -n "$pid" && "$pid" != "0" ]]; then
            kill "$pid" 2>/dev/null || true
        fi
    fi
    # Also try sending 'q' to flutter run via its stdin (graceful quit)
    pkill -f "flutter run" 2>/dev/null || true
    pkill -f "flutter_tools" 2>/dev/null || true
    rm -f "$STATE_FILE"

    # Show last log lines
    if [[ -f "$LOG_FILE" ]]; then
        echo "Last output:"
        tail -5 "$LOG_FILE"
    fi
    ok "Flutter app stopped"
}

# ─── Hot Reload ───

cmd_reload() {
    # Send 'r' to flutter run process for hot reload
    local state
    state=$(load_state)
    if [[ -z "$state" ]]; then
        fail "No Flutter app running"
        return 1
    fi
    local pid
    pid=$(echo "$state" | python3 -c "import sys,json;print(json.load(sys.stdin).get('pid',0))" 2>/dev/null)

    # Hot reload by sending SIGUSR1 or writing to stdin
    if kill -0 "$pid" 2>/dev/null; then
        kill -USR1 "$pid" 2>/dev/null || true
        ok "Hot reload triggered"
    else
        fail "Flutter process not running"
    fi
}

cmd_restart() {
    # Send 'R' for hot restart
    local state
    state=$(load_state)
    if [[ -z "$state" ]]; then
        fail "No Flutter app running"
        return 1
    fi
    local pid
    pid=$(echo "$state" | python3 -c "import sys,json;print(json.load(sys.stdin).get('pid',0))" 2>/dev/null)

    if kill -0 "$pid" 2>/dev/null; then
        kill -USR2 "$pid" 2>/dev/null || true
        ok "Hot restart triggered"
    else
        fail "Flutter process not running"
    fi
}

# ─── Screenshot ───

cmd_screenshot() {
    local output="${1:-/tmp/flutter-screenshot.png}"
    local state
    state=$(load_state)
    local device=""
    if [[ -n "$state" ]]; then
        device=$(echo "$state" | python3 -c "import sys,json;print(json.load(sys.stdin).get('device',''))" 2>/dev/null)
    fi

    case "$device" in
        *iPhone*|*iPad*|*ios*|*simulator*)
            xcrun simctl io booted screenshot "$output" 2>/dev/null
            ;;
        *chrome*|*web*)
            local port
            port=$(grep -oE "localhost:[0-9]+" "$LOG_FILE" 2>/dev/null | tail -1 | cut -d: -f2)
            if [[ -n "$port" ]]; then
                CDP_PORT="$port" node "$SCRIPT_DIR/cdp-client.mjs" screenshot "$output" 2>/dev/null
            else
                warn "Cannot detect debug port for web. Taking full screenshot."
                screencapture -x "$output"
            fi
            ;;
        *macos*)
            screencapture -x "$output"
            ;;
        *)
            if xcrun simctl list devices booted 2>/dev/null | grep -q "Booted"; then
                xcrun simctl io booted screenshot "$output" 2>/dev/null
            else
                screencapture -x "$output"
            fi
            ;;
    esac
    # Resize to fit Claude's image dimension limit (max 1900px either side)
    local dims w h MAX=1900
    dims=$(sips -g pixelWidth -g pixelHeight "$output" 2>/dev/null)
    w=$(echo "$dims" | awk '/pixelWidth/{print $2}')
    h=$(echo "$dims" | awk '/pixelHeight/{print $2}')
    if [[ -n "$w" && "$w" -gt "$MAX" ]] && [[ -z "$h" || "$w" -ge "$h" ]]; then
        sips --resampleWidth "$MAX" "$output" >/dev/null 2>&1
    elif [[ -n "$h" && "$h" -gt "$MAX" ]]; then
        sips --resampleHeight "$MAX" "$output" >/dev/null 2>&1
    fi
    ok "Screenshot saved: $output"
}

# ─── Dart VM Service Interaction ───

cmd_vm() {
    local action="${1:-info}"
    local state
    state=$(load_state)
    local vm_url=""
    if [[ -n "$state" ]]; then
        vm_url=$(echo "$state" | python3 -c "import sys,json;print(json.load(sys.stdin).get('vmServiceUrl',''))" 2>/dev/null)
    fi

    if [[ -z "$vm_url" ]]; then
        # Try to find from log (token may contain - _ =)
        vm_url=$(grep -oE "http://127\.0\.0\.1:[0-9]+/[A-Za-z0-9_=-]+/" "$LOG_FILE" 2>/dev/null | tail -1)
    fi

    if [[ -z "$vm_url" ]]; then
        fail "No VM Service URL. Is the app running?"
        return 1
    fi

    case "$action" in
        info)
            echo "VM Service: $vm_url"
            curl -s "${vm_url}getVM" 2>/dev/null | python3 -m json.tool 2>/dev/null | head -30
            ;;
        isolates)
            curl -s "${vm_url}getVM" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for iso in data.get('result',{}).get('isolates',[]):
    print(f\"  {iso.get('name','?')} (id={iso.get('id','?')})\")" 2>/dev/null
            ;;
        widgets)
            # Semantic UI collection via the Flutter inspector over the VM Service WS —
            # works on any target incl. desktop (where there is no native AX tree).
            node "$SCRIPT_DIR/flutter-vm.mjs" "$vm_url" widgets
            ;;
        call)
            # Generic VM Service RPC / service extension. $ISOLATE → main isolate id.
            node "$SCRIPT_DIR/flutter-vm.mjs" "$vm_url" call "$2" "${3:-}"
            ;;
        *)
            echo "Usage: flutter-ctl vm <info|isolates|widgets|call <method> [jsonParams]>"
            ;;
    esac
}

# ─── Tests ───

cmd_test() {
    local project_dir="${1:-.}"
    cd "$project_dir"
    echo "Running Flutter tests..."
    flutter test --reporter compact 2>&1
}

cmd_test_drive() {
    local project_dir="${1:-.}"
    local device="${FLUTTER_DEVICE:-}"
    cd "$project_dir"
    echo "Running integration tests..."
    flutter drive ${device:+"-d" "$device"} 2>&1
}

# ─── Analyze ───

cmd_analyze() {
    local project_dir="${1:-.}"
    cd "$project_dir"
    echo "=== Flutter Analyze ==="
    flutter analyze 2>&1
}

# ─── Logs ───

cmd_log() {
    local seconds="${1:-10}"
    local state
    state=$(load_state)
    local device=""
    if [[ -n "$state" ]]; then
        device=$(echo "$state" | python3 -c "import sys,json;print(json.load(sys.stdin).get('device',''))" 2>/dev/null)
    fi

    case "$device" in
        *iPhone*|*iPad*|*ios*|*simulator*)
            echo "Streaming iOS simulator logs for ${seconds}s..."
            timeout "$seconds" xcrun simctl spawn booted log stream \
                --predicate 'processImagePath CONTAINS "Runner" OR processImagePath CONTAINS "Flutter"' \
                --level=debug 2>/dev/null || true
            ;;
        *)
            echo "Showing Flutter run log (last 30 lines):"
            tail -30 "$LOG_FILE" 2>/dev/null
            ;;
    esac
}

cmd_run_log() {
    local lines="${1:-50}"
    if [[ -f "$LOG_FILE" ]]; then
        echo "=== Flutter Run Log (last $lines lines) ==="
        tail -"$lines" "$LOG_FILE"
    else
        fail "No log file. Run 'run' first."
    fi
}

# ─── Device Interaction (delegates to ios-debug/macos-debug) ───

cmd_tap() {
    local state
    state=$(load_state)
    local device=""
    if [[ -n "$state" ]]; then
        # `|| echo ""` keeps an invalid/empty state from aborting under `set -e` (pipefail).
        device=$(echo "$state" | python3 -c "import sys,json;print(json.load(sys.stdin).get('device',''))" 2>/dev/null || echo "")
    fi

    local SK="$SCRIPT_DIR"
    case "$device" in
        *iPhone*|*iPad*|*ios*|*simulator*)
            # Mobile: simctl/idb HID touches DO reach the Flutter canvas. (Verified.)
            bash "$SK/ios-ctl.sh" tap "$@"
            ;;
        *android*|*emulator*|*pixel*)
            # Mobile: `adb input` reaches the Flutter canvas. (Verified.)
            bash "$SK/android-ctl.sh" tap "$@"
            ;;
        *macos*)
            # Flutter DESKTOP renders a custom canvas with NO AX content, and background
            # CGEventPostToPid clicks do not reach its hit-test (verified). There is no
            # reliable background tap. Prefer a mobile target or a flutter_driver build.
            warn "Flutter desktop has no AX tap target; background clicks don't register."
            warn "Best: drive via a mobile target, or a flutter_driver/integration_test build (semantic)."
            local app_name="${FLUTTER_APP:-$(grep -m1 '^name:' pubspec.yaml 2>/dev/null | awk '{print $2}')}"
            warn "Attempting real-HID frontmost click as best-effort (MAC_INPUT=hid, app='$app_name')..."
            MAC_INPUT=hid MAC_APP="$app_name" bash "$SK/mac-ctl.sh" tap "$@"
            ;;
        *)
            echo "Tap not supported for device: $device"
            echo "Use screenshots + (for desktop) the Dart VM Service / flutter_driver"
            ;;
    esac
}

# ─── Health ───

cmd_health() {
    echo "=== Flutter Debug Health Check ==="

    # Check flutter
    local flutter_ver
    flutter_ver=$(flutter --version 2>/dev/null | head -1)
    ok "Flutter: $flutter_ver"

    # Check running state
    local state
    state=$(load_state)
    if [[ -n "$state" ]]; then
        local pid device vm_url
        pid=$(echo "$state" | python3 -c "import sys,json;print(json.load(sys.stdin).get('pid',0))" 2>/dev/null)
        device=$(echo "$state" | python3 -c "import sys,json;print(json.load(sys.stdin).get('device','?'))" 2>/dev/null)
        vm_url=$(echo "$state" | python3 -c "import sys,json;print(json.load(sys.stdin).get('vmServiceUrl',''))" 2>/dev/null)

        if kill -0 "$pid" 2>/dev/null; then
            ok "App running (PID: $pid, device: $device)"
        else
            warn "App process not running"
        fi
        if [[ -n "$vm_url" ]]; then
            ok "VM Service: $vm_url"
        fi
    else
        warn "No tracked Flutter app"
    fi

    # Check devices
    echo ""
    echo "  Available targets:"
    if xcrun simctl list devices booted 2>/dev/null | grep -q "Booted"; then
        echo "    [iOS] $(xcrun simctl list devices booted | grep Booted | head -1 | xargs)"
    fi
    if [[ -d "/Applications/Google Chrome.app" ]]; then
        echo "    [Web] Chrome"
    fi
    echo "    [macOS] This Mac"

    echo ""
    echo "=== Health check complete ==="
}

# ─── Help ───

cmd_help() {
    cat << 'HELP'
flutter-ctl - Flutter app debug tool for Claude Code

RUN & LIFECYCLE:
  run [dir]              Run Flutter app (auto-detects device: iOS sim > Chrome > macOS)
  stop                   Stop running app
  reload                 Hot reload (preserves state)
  restart                Hot restart (resets state)

INSPECTION:
  screenshot [path]      Capture screenshot (auto-detects: simctl/CDP/screencapture)
  health                 Health check
  vm info                Show Dart VM Service info
  vm widgets             Dump the Flutter widget tree (semantic, VM Service) — works on desktop too
  vm call <m> [json]     Call any VM Service RPC / service extension ($ISOLATE = main isolate)
  vm isolates            List Dart isolates

TESTING:
  test [dir]             Run unit/widget tests
  analyze [dir]          Run flutter analyze

LOGS:
  log [seconds]          Stream device logs
  run-log [lines]        Show flutter run output

INTERACTION:
  tap <x> <y>            Tap on device (delegates to ios-debug/macos-debug)
  tap identifier <id>    Tap by accessibility identifier

ENV VARS:
  FLUTTER_DEVICE         Target device (auto-detected if not set)
HELP
}

# ─── Main ───

cmd="${1:-help}"
shift 2>/dev/null || true

case "$cmd" in
    run)         cmd_run "$@" ;;
    stop)        cmd_stop ;;
    reload)      cmd_reload ;;
    restart)     cmd_restart ;;
    screenshot)  cmd_screenshot "$@" ;;
    vm)          cmd_vm "$@" ;;
    widgets)     cmd_vm widgets ;;
    test)        cmd_test "$@" ;;
    test-drive)  cmd_test_drive "$@" ;;
    analyze)     cmd_analyze "$@" ;;
    log)         cmd_log "$@" ;;
    run-log)     cmd_run_log "$@" ;;
    tap)         cmd_tap "$@" ;;
    health)      cmd_health ;;
    help|--help) cmd_help ;;
    *)           echo "Unknown: $cmd"; cmd_help ;;
esac
