#!/usr/bin/env bash
# pilot.sh - Unified app debug router for Claude Code
# Routes commands to platform-specific controllers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo -e "${CYAN}[PILOT]${NC} $*"; }

# ─── Auto-Detect Platform ───

detect_platform() {
    local dir="${1:-.}"

    if [[ -n "${APP_PLATFORM:-}" ]]; then
        echo "$APP_PLATFORM"
        return
    fi

    if [[ -f "$dir/pubspec.yaml" ]]; then
        echo "flutter"
    elif [[ -f "$dir/src-tauri/tauri.conf.json" ]] || [[ -f "$dir/src-tauri/Cargo.toml" ]]; then
        echo "tauri"
    elif compgen -G "$dir/wxt.config.*" >/dev/null 2>&1 || { [[ -f "$dir/manifest.json" ]] && grep -q '"manifest_version"[[:space:]]*:[[:space:]]*3' "$dir/manifest.json" 2>/dev/null; }; then
        echo "chrome-extension"
    elif [[ -f "$dir/package.json" ]]; then
        local detected
        detected=$(node -e "
const d=require('$dir/package.json');
const a={...d.dependencies,...d.devDependencies};
if('@tauri-apps/api' in a || '@tauri-apps/cli' in a) console.log('tauri');
else if('react-native' in a) console.log('react-native');
else if('electron' in a) console.log('electron');
else if('wxt' in a || 'webextension-polyfill' in a) console.log('chrome-extension');
else console.log('web');
" 2>/dev/null)
        echo "${detected:-web}"
    elif ls "$dir"/*.xcodeproj &>/dev/null || ls "$dir"/*.xcworkspace &>/dev/null || [[ -f "$dir/project.yml" ]] || [[ -f "$dir/Package.swift" ]]; then
        if [[ -f "$dir/project.yml" ]]; then
            if grep -q "iOS" "$dir/project.yml" 2>/dev/null; then
                echo "ios"
            else
                echo "macos"
            fi
        else
            echo "macos"
        fi
    elif [[ -f "$dir/build.gradle" ]] || [[ -f "$dir/build.gradle.kts" ]] || [[ -f "$dir/settings.gradle" ]]; then
        echo "android"
    elif ls "$dir"/*.html &>/dev/null; then
        echo "web"
    else
        echo "unknown"
    fi
}

# ─── Route to Platform Script ───

route() {
    local platform="$1"
    shift

    case "$platform" in
        electron)
            CDP_PORT="${CDP_PORT:-9222}" node "$SCRIPT_DIR/cdp-client.mjs" "$@"
            ;;
        ios)
            bash "$SCRIPT_DIR/ios-ctl.sh" "$@"
            ;;
        macos)
            bash "$SCRIPT_DIR/mac-ctl.sh" "$@"
            ;;
        web)
            bash "$SCRIPT_DIR/web-ctl.sh" "$@"
            ;;
        flutter)
            bash "$SCRIPT_DIR/flutter-ctl.sh" "$@"
            ;;
        react-native|rn)
            bash "$SCRIPT_DIR/rn-ctl.sh" "$@"
            ;;
        android)
            bash "$SCRIPT_DIR/android-ctl.sh" "$@"
            ;;
        tauri)
            bash "$SCRIPT_DIR/tauri-ctl.sh" "$@"
            ;;
        chrome-extension|chrome-ext|extension)
            # No dedicated controller: an MV3 extension is driven over CDP via web-ctl
            # (popup/options/content/service-worker targets). See references/chrome-extension.md.
            echo "[pilot] chrome-extension → CDP via web-ctl (see references/chrome-extension.md)" >&2
            bash "$SCRIPT_DIR/web-ctl.sh" "$@"
            ;;
        *)
            fail "Unknown platform: $platform"
            echo "Supported: electron, ios, macos, web, flutter, react-native, android, tauri, chrome-extension"
            return 1
            ;;
    esac
}

# ─── Status ───

cmd_status() {
    echo "=== Debug Kit Status ==="
    echo ""

    for sf in /tmp/.electron-debug-state.json /tmp/.web-debug-state.json /tmp/.flutter-debug-state.json /tmp/.rn-debug-state.json /tmp/.android-debug-state.json /tmp/.tauri-debug-state.json; do
        if [[ -f "$sf" ]]; then
            local name
            name=$(basename "$sf" | sed 's/^\.\(.*\)-state\.json$/\1/' | sed 's/-debug//')
            local content
            content=$(cat "$sf" 2>/dev/null)
            echo "  [$name] $content"
        fi
    done

    if xcrun simctl list devices booted 2>/dev/null | grep -q "Booted"; then
        echo "  [ios-sim] $(xcrun simctl list devices booted | grep Booted | head -1 | xargs)"
    fi

    if [[ -f /tmp/.macos-debug-app-name ]]; then
        echo "  [macos] App: $(cat /tmp/.macos-debug-app-name)"
    fi

    echo ""
    echo "=== Auto-Detect ==="
    local platform
    platform=$(detect_platform ".")
    echo "  Current directory platform: $platform"
}

# ─── Help ───

cmd_help() {
    cat << 'HELP'
pilot.sh - Cross-platform app debug router for Claude Code

USAGE:
  pilot.sh <platform> <command> [args]    Route to platform controller
  pilot.sh auto <command> [args]          Auto-detect platform, then route
  pilot.sh status                         Show running apps across all platforms
  pilot.sh detect [dir]                   Detect project platform

PLATFORMS:
  electron     Electron apps (CDP protocol)
  ios          iOS apps on Simulator (xcrun simctl + CGEvent)
  macos        macOS desktop apps (Accessibility API + CGEvent)
  web          Web apps in Chrome (CDP protocol)
  flutter      Flutter apps (delegates to ios/web/macos)
  react-native React Native / Expo apps (delegates to ios)
  android      Android apps (adb + uiautomator)
  tauri        Tauri apps (delegates to macos; AX API sees DOM)
  chrome-extension  MV3 extensions (CDP via web-ctl; see references/chrome-extension.md)
HELP
}

# ─── Main ───

cmd="${1:-help}"
shift 2>/dev/null || true

case "$cmd" in
    status)
        cmd_status
        ;;
    detect)
        platform=$(detect_platform "${1:-.}")
        echo "$platform"
        ;;
    auto)
        platform=$(detect_platform ".")
        if [[ "$platform" == "unknown" ]]; then
            fail "Cannot auto-detect platform. Use: pilot.sh <platform> <command>"
            exit 1
        fi
        info "Detected: $platform"
        route "$platform" "$@"
        ;;
    help|--help|-h)
        cmd_help
        ;;
    electron|ios|macos|web|flutter|react-native|rn|android|tauri|chrome-extension|chrome-ext)
        route "$cmd" "$@"
        ;;
    *)
        platform=$(detect_platform ".")
        if [[ "$platform" != "unknown" ]]; then
            info "Auto-detected: $platform"
            route "$platform" "$cmd" "$@"
        else
            echo "Unknown command or platform: $cmd"
            cmd_help
        fi
        ;;
esac
