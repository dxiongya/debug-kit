#!/usr/bin/env bash
# android-ctl.sh - Android app debug tool for Claude Code
# Uses: adb, emulator, gradle
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

STATE_FILE="/tmp/.android-debug-state.json"
BUILD_LOG="/tmp/android-debug-build.log"
DK_POINTER="${DK_POINTER:-on}"

save_state() { echo "$1" > "$STATE_FILE"; }
load_state() { cat "$STATE_FILE" 2>/dev/null || echo ""; }

# Virtual pointer for Android = the device's own native touch feedback ("show taps"). It
# draws a ripple/circle exactly where input lands — precise, zero coordinate mapping, and it
# never touches your Mac cursor. Enabled (idempotently) before taps when DK_POINTER != off.
_android_pointer() {
    [[ "$DK_POINTER" == "off" ]] && return 0
    adb shell settings put system show_touches 1 >/dev/null 2>&1 || true
}
android_pointer_off() {
    adb shell settings put system show_touches 0 >/dev/null 2>&1 || true
    adb shell settings put system pointer_location 0 >/dev/null 2>&1 || true
}

# Check adb is available
check_adb() {
    if ! command -v adb &>/dev/null; then
        fail "adb not found. Install Android SDK and ensure adb is in PATH."
        fail "  brew install --cask android-platform-tools"
        fail "  or install Android Studio: https://developer.android.com/studio"
        return 1
    fi
}

# ─── Emulator ───

cmd_emulator_list() {
    check_adb
    echo "=== Available AVDs ==="
    emulator -list-avds 2>/dev/null || warn "emulator command not found"
    echo ""
    echo "=== Connected Devices ==="
    adb devices -l 2>/dev/null
}

cmd_emulator_start() {
    local avd="${1:-}"
    check_adb

    if [[ -z "$avd" ]]; then
        # Auto-detect first AVD
        avd=$(emulator -list-avds 2>/dev/null | head -1)
        if [[ -z "$avd" ]]; then
            fail "No AVD found. Create one in Android Studio or via avdmanager."
            return 1
        fi
        echo "Auto-selected AVD: $avd"
    fi

    echo "Starting emulator: $avd..."
    emulator -avd "$avd" -no-snapshot-load &>/dev/null &
    local emu_pid=$!

    # Wait for boot
    echo "Waiting for emulator to boot..."
    for i in $(seq 1 60); do
        sleep 2
        if adb shell getprop sys.boot_completed 2>/dev/null | grep -q "1"; then
            ok "Emulator booted: $avd"
            save_state "{\"emulatorPid\":$emu_pid,\"avd\":\"$avd\"}"
            return 0
        fi
    done
    warn "Emulator started but boot not confirmed after 120s"
}

cmd_emulator_stop() {
    check_adb
    adb emu kill 2>/dev/null || true
    local state
    state=$(load_state)
    if [[ -n "$state" ]]; then
        local pid
        pid=$(echo "$state" | python3 -c "import sys,json;print(json.load(sys.stdin).get('emulatorPid',0))" 2>/dev/null)
        if [[ -n "$pid" && "$pid" != "0" ]]; then
            kill "$pid" 2>/dev/null || true
        fi
    fi
    rm -f "$STATE_FILE"
    ok "Emulator stopped"
}

# ─── Build & Install ───

cmd_build() {
    local project_dir="${1:-.}"
    local variant="${ANDROID_VARIANT:-debug}"
    cd "$project_dir"

    if [[ ! -f build.gradle ]] && [[ ! -f build.gradle.kts ]] && [[ ! -f settings.gradle ]] && [[ ! -f settings.gradle.kts ]]; then
        fail "Not an Android/Gradle project"
        return 1
    fi

    echo "Building Android app ($variant)..."
    ./gradlew "assemble${variant^}" 2>&1 | tee "$BUILD_LOG" | tail -10

    local apk
    apk=$(find . -name "*.apk" -path "*/$variant/*" 2>/dev/null | head -1)
    if [[ -n "$apk" ]]; then
        ok "APK: $apk"
        echo "$apk" > /tmp/.android-debug-apk
    else
        warn "APK not found in build output"
    fi
}

cmd_install() {
    check_adb
    local apk="${1:-}"

    if [[ -z "$apk" ]] && [[ -f /tmp/.android-debug-apk ]]; then
        apk=$(cat /tmp/.android-debug-apk)
    fi

    if [[ -z "$apk" ]]; then
        fail "No APK specified. Run 'build' first or provide APK path."
        return 1
    fi

    echo "Installing $apk..."
    adb install -r "$apk" 2>&1
    ok "Installed: $apk"
}

cmd_launch() {
    check_adb
    local package="${ANDROID_PACKAGE:-}"
    local activity="${ANDROID_ACTIVITY:-}"

    if [[ -z "$package" ]]; then
        # Try to detect from installed packages
        package=$(adb shell pm list packages -3 2>/dev/null | tail -1 | sed 's/package://')
        echo "Auto-detected package: $package"
    fi

    if [[ -z "$activity" ]]; then
        # Try to find main activity
        activity=$(adb shell cmd package resolve-activity --brief "$package" 2>/dev/null | tail -1)
        if [[ -z "$activity" ]]; then
            activity="$package/.MainActivity"
        fi
        echo "Auto-detected activity: $activity"
    fi

    echo "Launching $activity..."
    adb shell am start -n "$activity" 2>&1
    ok "App launched"
}

cmd_run() {
    local project_dir="${1:-.}"
    cmd_build "$project_dir"
    cmd_install
    cmd_launch
}

cmd_stop_app() {
    check_adb
    local package="${ANDROID_PACKAGE:-}"
    if [[ -z "$package" ]]; then
        package=$(adb shell pm list packages -3 2>/dev/null | tail -1 | sed 's/package://')
    fi
    adb shell am force-stop "$package" 2>/dev/null || true
    ok "App stopped: $package"
}

# ─── Screenshot ───

cmd_screenshot() {
    check_adb
    local output="${1:-/tmp/android-screenshot.png}"

    adb exec-out screencap -p > "$output" 2>/dev/null
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

# ─── Tap / Input ───

cmd_tap() {
    check_adb
    local x="${1:-}"
    local y="${2:-}"

    if [[ -z "$x" || -z "$y" ]]; then
        echo "Usage: android-ctl tap <x> <y>"
        return 1
    fi

    _android_pointer   # native touch feedback (virtual pointer) at the tap site
    adb shell input tap "$x" "$y" 2>/dev/null
    ok "Tap at ($x, $y)"
}

cmd_swipe() {
    check_adb
    local x1="${1:-}" y1="${2:-}" x2="${3:-}" y2="${4:-}" duration="${5:-300}"
    _android_pointer
    adb shell input swipe "$x1" "$y1" "$x2" "$y2" "$duration" 2>/dev/null
    ok "Swipe ($x1,$y1) -> ($x2,$y2)"
}

cmd_type_text() {
    check_adb
    local text="${1:-}"
    if [[ -z "$text" ]]; then
        echo "Usage: android-ctl type \"text\""
        return 1
    fi
    # Replace spaces with %s for adb
    local escaped
    escaped=$(echo "$text" | sed 's/ /%s/g')
    adb shell input text "$escaped" 2>/dev/null
    ok "Typed: $text"
}

cmd_key() {
    check_adb
    local key="${1:-}"
    case "$key" in
        back)    adb shell input keyevent KEYCODE_BACK ;;
        home)    adb shell input keyevent KEYCODE_HOME ;;
        enter)   adb shell input keyevent KEYCODE_ENTER ;;
        tab)     adb shell input keyevent KEYCODE_TAB ;;
        delete)  adb shell input keyevent KEYCODE_DEL ;;
        menu)    adb shell input keyevent KEYCODE_MENU ;;
        *)       adb shell input keyevent "$key" ;;
    esac
    ok "Key: $key"
}

# ─── UI Inspection ───

cmd_tree() {
    check_adb
    local output="${1:-/tmp/android-ui-tree.xml}"

    echo "Dumping UI hierarchy..."
    adb shell uiautomator dump /sdcard/ui-dump.xml 2>/dev/null
    adb pull /sdcard/ui-dump.xml "$output" 2>/dev/null
    adb shell rm /sdcard/ui-dump.xml 2>/dev/null

    ok "UI tree saved: $output"

    # Parse and show summary
    python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('$output')
root = tree.getroot()
for node in root.iter('node'):
    cls = node.get('class','').split('.')[-1]
    text = node.get('text','')
    desc = node.get('content-desc','')
    rid = node.get('resource-id','').split('/')[-1] if '/' in node.get('resource-id','') else node.get('resource-id','')
    bounds = node.get('bounds','')
    if text or desc or rid:
        parts = [cls]
        if rid: parts.append(f'id={rid}')
        if text: parts.append(f'text=\"{text}\"')
        if desc: parts.append(f'desc=\"{desc}\"')
        parts.append(bounds)
        print('  ' + ' | '.join(parts))
" 2>/dev/null || warn "Could not parse UI tree"
}

# ─── Logs ───

cmd_log() {
    check_adb
    local seconds="${1:-10}"
    local package="${ANDROID_PACKAGE:-}"

    echo "Streaming logcat for ${seconds}s..."
    if [[ -n "$package" ]]; then
        timeout "$seconds" adb logcat --pid="$(adb shell pidof "$package" 2>/dev/null)" 2>/dev/null | head -100 || true
    else
        timeout "$seconds" adb logcat "*:W" 2>/dev/null | head -100 || true
    fi
}

cmd_logcat_clear() {
    check_adb
    adb logcat -c 2>/dev/null
    ok "Logcat cleared"
}

# ─── Device Info ───

cmd_devices() {
    check_adb
    echo "=== Connected Devices ==="
    adb devices -l 2>/dev/null

    echo ""
    echo "=== Device Properties ==="
    local serial
    serial=$(adb get-serialno 2>/dev/null || echo "none")
    if [[ "$serial" != "none" ]]; then
        echo "  Model: $(adb shell getprop ro.product.model 2>/dev/null)"
        echo "  Android: $(adb shell getprop ro.build.version.release 2>/dev/null)"
        echo "  SDK: $(adb shell getprop ro.build.version.sdk 2>/dev/null)"
        echo "  Resolution: $(adb shell wm size 2>/dev/null | sed 's/Physical size: //')"
        echo "  Density: $(adb shell wm density 2>/dev/null | sed 's/Physical density: //')"
    fi
}

# ─── App Management ───

cmd_uninstall() {
    check_adb
    local package="${1:-${ANDROID_PACKAGE:-}}"
    if [[ -z "$package" ]]; then
        fail "No package specified"
        return 1
    fi
    adb shell pm uninstall "$package" 2>/dev/null
    ok "Uninstalled: $package"
}

cmd_clear_data() {
    check_adb
    local package="${1:-${ANDROID_PACKAGE:-}}"
    if [[ -z "$package" ]]; then
        fail "No package specified"
        return 1
    fi
    adb shell pm clear "$package" 2>/dev/null
    ok "Data cleared: $package"
}

# ─── Health ───

cmd_health() {
    echo "=== Android Debug Health Check ==="

    # adb
    if command -v adb &>/dev/null; then
        local adb_ver
        adb_ver=$(adb version 2>/dev/null | head -1)
        ok "adb: $adb_ver"
    else
        fail "adb not found"
    fi

    # emulator
    if command -v emulator &>/dev/null; then
        ok "emulator: available"
    else
        warn "emulator not found"
    fi

    # gradle
    if [[ -f ./gradlew ]]; then
        ok "gradlew: found"
    else
        warn "gradlew: not in current directory"
    fi

    # Connected devices
    if command -v adb &>/dev/null; then
        local count
        # NB: `grep -c` PRINTS the count (0) but EXITS 1 on zero matches. Under
        # `set -euo pipefail` that exit aborts the script; `|| echo 0` instead appends a
        # second "0" → "0\n0" and breaks the arithmetic test. `|| true` neutralises the
        # exit code without appending, leaving a clean single-line count.
        count=$(adb devices 2>/dev/null | grep -c "device$" || true); count=${count:-0}
        if [[ "$count" -gt 0 ]]; then
            ok "Connected devices: $count"
            adb devices -l 2>/dev/null | grep "device " | sed 's/^/  /'
        else
            warn "No connected devices"
        fi
    fi

    echo ""
    echo "=== Health check complete ==="
}

# ─── Help ───

cmd_help() {
    cat << 'HELP'
android-ctl - Android app debug tool for Claude Code

EMULATOR:
  emulator-list          List AVDs and connected devices
  emulator-start [avd]   Start emulator (auto-detects AVD)
  emulator-stop          Stop emulator

BUILD & INSTALL:
  build [dir]            Build APK (gradle assembleDebug)
  install [apk]          Install APK to device
  launch                 Launch app
  run [dir]              Build + Install + Launch
  stop-app               Force stop app

INSPECTION:
  screenshot [path]      Capture screenshot via adb
  tree [path]            Dump UI hierarchy (uiautomator)
  devices                Show device info
  health                 Health check

INTERACTION:
  tap <x> <y>            Tap at coordinates (dp)
  swipe <x1> <y1> <x2> <y2> [ms]  Swipe gesture
  type "text"            Type text
  key <name>             Send key: back, home, enter, tab, delete, menu

LOGS:
  log [seconds]          Stream logcat
  logcat-clear           Clear logcat buffer

APP MANAGEMENT:
  uninstall [package]    Uninstall app
  clear-data [package]   Clear app data

ENV VARS:
  ANDROID_PACKAGE        App package name (auto-detected)
  ANDROID_ACTIVITY       Main activity (auto-detected)
  ANDROID_VARIANT        Build variant (default: debug)
HELP
}

# ─── Main ───

cmd="${1:-help}"
shift 2>/dev/null || true

case "$cmd" in
    emulator-list)   cmd_emulator_list ;;
    emulator-start)  cmd_emulator_start "$@" ;;
    emulator-stop)   cmd_emulator_stop ;;
    build)           cmd_build "$@" ;;
    install)         cmd_install "$@" ;;
    launch)          cmd_launch ;;
    run)             cmd_run "$@" ;;
    stop-app)        cmd_stop_app ;;
    screenshot)      cmd_screenshot "$@" ;;
    tap)             cmd_tap "$@" ;;
    swipe)           cmd_swipe "$@" ;;
    pointer)         case "${1:-status}" in
                         on)  _android_pointer; ok "show_touches on (native pointer)" ;;
                         off) android_pointer_off; ok "show_touches off" ;;
                         *)   echo "show_touches = $(adb shell settings get system show_touches 2>/dev/null | tr -d '\r')" ;;
                     esac ;;
    type)            cmd_type_text "$@" ;;
    key)             cmd_key "$@" ;;
    tree)            cmd_tree "$@" ;;
    devices)         cmd_devices ;;
    log)             cmd_log "$@" ;;
    logcat-clear)    cmd_logcat_clear ;;
    uninstall)       cmd_uninstall "$@" ;;
    clear-data)      cmd_clear_data "$@" ;;
    health)          cmd_health ;;
    help|--help)     cmd_help ;;
    *)               echo "Unknown: $cmd"; cmd_help ;;
esac
