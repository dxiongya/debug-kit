#!/usr/bin/env bash
# rn-ctl.sh - React Native & Expo app debug tool for Claude Code
# Uses: react-native CLI / expo CLI, xcrun simctl (iOS), Metro bundler, ios-debug skill
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

STATE_FILE="/tmp/.rn-debug-state.json"
METRO_LOG="/tmp/rn-debug-metro.log"
BUILD_LOG="/tmp/rn-debug-build.log"
PORT_FILE="/tmp/.rn-debug-port"

save_state() { echo "$1" > "$STATE_FILE"; }
load_state() { cat "$STATE_FILE" 2>/dev/null || echo ""; }

# Metro's default port 8081 is frequently occupied (OrbStack reverse proxy, mitmweb, etc.).
# Pick the first port nothing is LISTENing on; persist it so reload/health agree.
_free_port() {
    local p
    for p in ${RN_METRO_PORT:-} 8081 8082 8083 8088 8090 8097 19000 8099; do
        [ -z "$p" ] && continue
        if ! lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then echo "$p"; return 0; fi
    done
    echo 8081
}
_metro_port() { cat "$PORT_FILE" 2>/dev/null || echo 8081; }

# Detect if project is Expo-based
is_expo() {
    local dir="${1:-.}"
    node -e "
const d=require('$dir/package.json');
const a={...d.dependencies,...d.devDependencies};
process.exit('expo' in a ? 0 : 1);
" 2>/dev/null
}

# Parse JSON field via node (avoids pyenv issues)
json_get() {
    local field="$1"
    node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); console.log(d['$field']||'')" 2>/dev/null
}

# ─── Run (iOS) ───

cmd_run() {
    local project_dir="${1:-.}"
    local device="${RN_DEVICE:-}"
    local scheme="${RN_SCHEME:-}"

    cd "$project_dir"

    if [[ ! -f package.json ]]; then
        fail "Not a React Native / Expo project (no package.json)"
        return 1
    fi

    if is_expo "$project_dir"; then
        cmd_run_expo "$@"
        return
    fi

    # Bare React Native
    # Check if react-native is a dependency
    if ! node -e "const d=require('./package.json'); if(!d.dependencies?.['react-native']) process.exit(1)" 2>/dev/null; then
        fail "react-native not found in package.json dependencies"
        return 1
    fi

    # Install pods if needed
    if [[ -d ios ]] && [[ ! -d ios/Pods ]]; then
        echo "Installing CocoaPods..."
        (cd ios && pod install 2>&1 | tail -3)
    fi

    # Build args
    local args=()
    if [[ -n "$device" ]]; then
        args+=(--simulator "$device")
    fi
    if [[ -n "$scheme" ]]; then
        args+=(--scheme "$scheme")
    fi

    # Pick a free Metro port and build the app to talk to it (8081 is often taken).
    local port; port=$(_free_port); echo "$port" > "$PORT_FILE"
    args+=(--port "$port")
    [[ "$port" != "8081" ]] && warn "Metro :8081 busy → using port $port"

    echo "Building and running React Native app on iOS (Metro :$port)..."
    echo "Project: $project_dir"

    # Run react-native run-ios (starts the packager on --port and builds the app to use it)
    npx react-native run-ios ${args[@]+"${args[@]}"} 2>&1 | tee "$BUILD_LOG" &
    local rn_pid=$!

    # Wait for build to complete and app to launch
    echo "Waiting for build and launch..."
    local metro_url=""
    local success=false
    for i in $(seq 1 120); do
        sleep 2
        if grep -q "success" "$BUILD_LOG" 2>/dev/null; then
            success=true
            break
        fi
        if grep -q "BUILD FAILED\|error:" "$BUILD_LOG" 2>/dev/null; then
            fail "Build failed. Check $BUILD_LOG"
            return 1
        fi
    done

    metro_url=$(grep -oE "http://localhost:[0-9]+" "$BUILD_LOG" 2>/dev/null | head -1)
    if [[ -z "$metro_url" ]]; then
        metro_url="http://localhost:$port"
    fi

    local state="{\"pid\":$rn_pid,\"type\":\"bare\",\"dir\":\"$project_dir\",\"metroUrl\":\"$metro_url\"}"
    save_state "$state"

    if $success; then
        ok "React Native app running (PID: $rn_pid)"
        ok "Metro: $metro_url"
    else
        warn "Build may still be in progress (PID: $rn_pid)"
    fi
    echo "Build log: $BUILD_LOG"
}

# ─── Run Expo ───

cmd_run_expo() {
    local project_dir="${1:-.}"
    local device="${RN_DEVICE:-}"
    local mode="${EXPO_MODE:-go}"  # "go" (Expo Go) or "native" (expo run:ios)

    cd "$project_dir"

    echo "Detected Expo project"
    echo "Project: $project_dir"
    echo "Mode: $mode"

    if [[ "$mode" == "native" ]]; then
        # Native build via expo run:ios (creates ios/ dir if needed)
        echo "Building native iOS app via Expo..."
        local args=()
        if [[ -n "$device" ]]; then
            args+=(--device "$device")
        fi
        npx expo run:ios ${args[@]+"${args[@]}"} 2>&1 | tee "$BUILD_LOG" &
        local expo_pid=$!

        echo "Waiting for build..."
        local success=false
        for i in $(seq 1 120); do
            sleep 2
            if grep -q "Installing\|Launching\|success" "$BUILD_LOG" 2>/dev/null; then
                success=true
                break
            fi
            if grep -q "BUILD FAILED\|Error:" "$BUILD_LOG" 2>/dev/null; then
                fail "Build failed. Check $BUILD_LOG"
                return 1
            fi
        done

        local state="{\"pid\":$expo_pid,\"type\":\"expo-native\",\"dir\":\"$project_dir\"}"
        save_state "$state"

        if $success; then
            ok "Expo native app running (PID: $expo_pid)"
        else
            warn "Build may still be in progress (PID: $expo_pid)"
        fi
    else
        # Expo Go mode: start dev server, open in Expo Go on simulator
        # Start Metro server first (without --ios to avoid interactive version check)
        echo "Starting Expo Metro server..."
        npx expo start 2>&1 | tee "$BUILD_LOG" &
        local expo_pid=$!

        # Wait for Metro to be ready
        echo "Waiting for Metro..."
        local metro_url="http://localhost:8081"
        for i in $(seq 1 30); do
            sleep 2
            if curl -s "$metro_url/status" 2>/dev/null | grep -q "running"; then
                ok "Metro ready"
                break
            fi
        done

        # Open the app in Expo Go via simctl openurl (bypasses CLI version prompts)
        echo "Opening in Expo Go on simulator..."
        xcrun simctl openurl booted "exp://127.0.0.1:8081" 2>/dev/null
        sleep 5

        local state="{\"pid\":$expo_pid,\"type\":\"expo-go\",\"dir\":\"$project_dir\",\"metroUrl\":\"$metro_url\"}"
        save_state "$state"

        ok "Expo Go running (PID: $expo_pid)"
        ok "Metro: $metro_url"
    fi
    echo "Log: $BUILD_LOG"
}

cmd_start_metro() {
    local project_dir="${1:-.}"
    cd "$project_dir"

    local port; port=$(_free_port); echo "$port" > "$PORT_FILE"
    [[ "$port" != "8081" ]] && warn "Metro :8081 busy → using port $port"
    if is_expo "$project_dir"; then
        echo "Starting Expo dev server on :$port..."
        npx expo start --port "$port" > "$METRO_LOG" 2>&1 &
    else
        echo "Starting Metro bundler on :$port..."
        npx react-native start --port "$port" --reset-cache > "$METRO_LOG" 2>&1 &
    fi
    local metro_pid=$!
    echo "{\"metroPid\":$metro_pid}" > /tmp/.rn-metro-pid

    # Poll until the packager actually answers on its port (not just "process alive").
    local up=false i
    for i in $(seq 1 20); do
        if curl -s "http://localhost:$port/status" 2>/dev/null | grep -q "packager-status:running"; then up=true; break; fi
        kill -0 "$metro_pid" 2>/dev/null || break
        sleep 1
    done
    if $up; then
        ok "Metro/Expo dev server running on :$port (PID: $metro_pid)"
        echo "Log: $METRO_LOG"
    else
        fail "Server failed to start on :$port. Check $METRO_LOG"
    fi
}

cmd_stop() {
    # Stop the RN/Expo app process
    local state
    state=$(load_state)
    if [[ -n "$state" ]]; then
        local pid
        pid=$(echo "$state" | json_get pid)
        if [[ -n "$pid" && "$pid" != "0" && "$pid" != "" ]]; then
            kill "$pid" 2>/dev/null || true
        fi
    fi

    # Kill Metro/Expo bundler
    if [[ -f /tmp/.rn-metro-pid ]]; then
        local metro_pid
        metro_pid=$(cat /tmp/.rn-metro-pid | json_get metroPid)
        if [[ -n "$metro_pid" && "$metro_pid" != "0" && "$metro_pid" != "" ]]; then
            kill "$metro_pid" 2>/dev/null || true
        fi
        rm -f /tmp/.rn-metro-pid
    fi

    # Also kill any lingering processes
    pkill -f "react-native.*start" 2>/dev/null || true
    pkill -f "expo start" 2>/dev/null || true
    pkill -f "metro" 2>/dev/null || true

    rm -f "$STATE_FILE"
    ok "React Native / Expo app stopped"
}

# ─── Reload ───

cmd_reload() {
    # Trigger reload via Metro bundler HTTP endpoint (on the chosen port)
    local port; port=$(_metro_port)
    local metro_url="http://localhost:$port"
    local state
    state=$(load_state)
    if [[ -n "$state" ]]; then
        metro_url=$(echo "$state" | json_get metroUrl)
        metro_url="${metro_url:-http://localhost:$port}"
    fi

    curl -s "$metro_url/reload" >/dev/null 2>&1 || \
    curl -s "http://localhost:$port/reload" >/dev/null 2>&1 || true
    ok "Reload triggered (Metro :$port)"
}

# ─── Screenshot ───

cmd_screenshot() {
    local output="${1:-/tmp/rn-screenshot.png}"

    # iOS Simulator screenshot
    if xcrun simctl list devices booted 2>/dev/null | grep -q "Booted"; then
        xcrun simctl io booted screenshot "$output" 2>/dev/null
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
        ok "Screenshot saved: $output (iOS Simulator)"
    else
        fail "No booted iOS Simulator found"
        return 1
    fi
}

# ─── Tap (delegate to ios-debug) ───

cmd_tap() {
    if [[ -f "$SCRIPT_DIR/ios-ctl.sh" ]]; then
        bash "$SCRIPT_DIR/ios-ctl.sh" tap "$@"
    else
        fail "ios-debug skill not found. Install it for tap support."
        return 1
    fi
}

# ─── Type (delegate to ios-debug) ───

cmd_type() {
    if [[ -f "$SCRIPT_DIR/ios-ctl.sh" ]]; then
        bash "$SCRIPT_DIR/ios-ctl.sh" type "$@"
    else
        fail "ios-debug skill not found. Install it for type support."
        return 1
    fi
}

# ─── Accessibility Tree (delegate to ios-debug) ───

cmd_tree() {
    if [[ -f "$SCRIPT_DIR/ios-ctl.sh" ]]; then
        bash "$SCRIPT_DIR/ios-ctl.sh" tree "$@"
    else
        fail "ios-debug skill not found"
        return 1
    fi
}

# ─── Tests ───

cmd_test() {
    local project_dir="${1:-.}"
    cd "$project_dir"
    echo "Running Jest tests..."
    npx jest --verbose 2>&1
}

# ─── Logs ───

cmd_log() {
    local seconds="${1:-10}"

    # iOS Simulator logs filtered for React Native
    if xcrun simctl list devices booted 2>/dev/null | grep -q "Booted"; then
        echo "Streaming iOS simulator logs for ${seconds}s..."
        timeout "$seconds" xcrun simctl spawn booted log stream \
            --predicate 'processImagePath CONTAINS "RNTestApp" OR processImagePath CONTAINS "React" OR subsystem CONTAINS "react"' \
            --level=debug 2>/dev/null | head -100 || true
    else
        warn "No booted simulator. Showing Metro log."
        cmd_metro_log
    fi
}

cmd_metro_log() {
    local lines="${1:-50}"
    if [[ -f "$METRO_LOG" ]]; then
        echo "=== Metro Log (last $lines lines) ==="
        tail -"$lines" "$METRO_LOG"
    elif [[ -f "$BUILD_LOG" ]]; then
        echo "=== Build Log (last $lines lines) ==="
        tail -"$lines" "$BUILD_LOG"
    else
        fail "No log file. Run 'run' or 'start-metro' first."
    fi
}

# ─── Build only ───

cmd_build() {
    local project_dir="${1:-.}"
    local scheme="${RN_SCHEME:-}"
    cd "$project_dir"

    echo "Building React Native iOS app..."

    # Install pods if needed
    if [[ -d ios ]] && [[ ! -d ios/Pods ]]; then
        echo "Installing CocoaPods..."
        (cd ios && pod install 2>&1 | tail -3)
    fi

    local workspace
    workspace=$(ls ios/*.xcworkspace 2>/dev/null | head -1)
    if [[ -z "$workspace" ]]; then
        fail "No .xcworkspace found in ios/"
        return 1
    fi

    if [[ -z "$scheme" ]]; then
        scheme=$(basename "$workspace" .xcworkspace)
    fi

    echo "Building $scheme..."
    xcodebuild -workspace "$workspace" \
        -scheme "$scheme" \
        -configuration Debug \
        -destination 'platform=iOS Simulator,name=iPhone 16' \
        -derivedDataPath ios/build \
        build 2>&1 | tail -20

    ok "Build complete"
}

# ─── Health ───

cmd_health() {
    echo "=== React Native Debug Health Check ==="

    # Node
    local node_ver
    node_ver=$(node --version 2>/dev/null)
    ok "Node: $node_ver"

    # React Native CLI
    local rn_ver
    rn_ver=$(npx react-native --version 2>/dev/null | head -1 || echo "not found")
    ok "React Native CLI: $rn_ver"

    # Metro running? (check the chosen port)
    local mport; mport=$(_metro_port)
    if curl -s "http://localhost:$mport/status" 2>/dev/null | grep -q "packager-status:running"; then
        ok "Metro bundler: running (:$mport)"
    else
        warn "Metro bundler: not running (:$mport)"
    fi

    # iOS Simulator
    if xcrun simctl list devices booted 2>/dev/null | grep -q "Booted"; then
        echo "  iOS Simulator: $(xcrun simctl list devices booted | grep Booted | head -1 | xargs)"
    else
        warn "No booted iOS Simulator"
    fi

    # Running state
    local state
    state=$(load_state)
    if [[ -n "$state" ]]; then
        local pid
        pid=$(echo "$state" | json_get pid)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            ok "App process running (PID: $pid)"
        else
            warn "App process not running"
        fi
    else
        warn "No tracked RN app"
    fi

    echo ""
    echo "=== Health check complete ==="
}

# ─── Help ───

cmd_help() {
    cat << 'HELP'
rn-ctl - React Native & Expo debug tool for Claude Code

RUN & LIFECYCLE:
  run [dir]              Build and run on iOS Simulator (auto-detects Expo vs bare RN)
  start-metro [dir]      Start Metro/Expo dev server only
  build [dir]            Build iOS app only (bare RN)
  stop                   Stop app and Metro/Expo
  reload                 Trigger JS reload

INSPECTION:
  screenshot [path]      Capture iOS Simulator screenshot
  tree                   Dump accessibility tree (via ios-ctl)
  health                 Health check

TESTING:
  test [dir]             Run Jest tests

LOGS:
  log [seconds]          Stream iOS simulator logs
  metro-log [lines]      Show Metro/Expo bundler output

INTERACTION:
  tap <x> <y>            Tap on iOS Simulator (via ios-ctl)
  tap identifier <id>    Tap by accessibility identifier
  tap label <text>       Tap by accessibility label

ENV VARS:
  RN_DEVICE              Simulator name (default: auto)
  RN_SCHEME              Xcode scheme (default: auto from xcworkspace)
  EXPO_MODE              Expo run mode: "go" (Expo Go, default) or "native" (expo run:ios)
HELP
}

# ─── Main ───

cmd="${1:-help}"
shift 2>/dev/null || true

case "$cmd" in
    run)          cmd_run "$@" ;;
    start-metro)  cmd_start_metro "$@" ;;
    build)        cmd_build "$@" ;;
    stop)         cmd_stop ;;
    reload)       cmd_reload ;;
    screenshot)   cmd_screenshot "$@" ;;
    tap)          cmd_tap "$@" ;;
    type)         cmd_type "$@" ;;
    tree)         cmd_tree "$@" ;;
    test)         cmd_test "$@" ;;
    log)          cmd_log "$@" ;;
    metro-log)    cmd_metro_log "$@" ;;
    health)       cmd_health ;;
    help|--help)  cmd_help ;;
    *)            echo "Unknown: $cmd"; cmd_help ;;
esac
