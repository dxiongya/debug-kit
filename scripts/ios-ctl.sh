#!/usr/bin/env bash
# ios-ctl.sh - iOS Simulator control tool for Claude Code
# Zero-dependency: uses only xcrun simctl, xcodebuild, and AppleScript
set -euo pipefail

DEVICE="${IOS_DEVICE:-booted}"
SCREENSHOT_DIR="/tmp"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

# ─── Setup / health diagnose ─────────────────────────────────────────────
#
# `ios-ctl setup` — one-shot environment doctor for the iOS toolchain:
#   1. Check xcrun simctl (must — comes with Xcode)
#   2. Check + install idb-companion via brew (zero-visual tap-bg path)
#   3. Check + install fb-idb (Python CLI for idb-companion)
#   4. Fix protobuf compat (fb-idb 1.1.x requires protobuf 3.20.x exactly)
#   5. Smoke test `idb list-targets` to confirm end-to-end wiring
#
# Failures of optional pieces (idb / fb-idb / protobuf) do NOT abort —
# tap-bg has a swift HID fallback that works without idb. setup just
# reports what's missing so the user knows what to install.

cmd_setup() {
    echo "=== iOS debug toolchain setup ==="
    local issues=0

    # 1. xcrun (mandatory)
    if command -v xcrun >/dev/null 2>&1; then
        ok "xcrun present"
    else
        fail "xcrun missing — install Xcode + Command Line Tools"
        return 1
    fi

    # 2. brew (needed for idb-companion)
    if ! command -v brew >/dev/null 2>&1; then
        warn "Homebrew missing — tap-bg will use HID fallback (visible flicker)."
        echo "    Install: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        ((issues++))
    else
        ok "Homebrew present"
        # 3. idb-companion
        if brew list idb-companion >/dev/null 2>&1; then
            ok "idb-companion installed ($(brew list --versions idb-companion | awk '{print $2}'))"
        else
            echo "  Installing idb-companion via brew (may take a few min)..."
            if brew install idb-companion 2>&1 | tail -3; then
                ok "idb-companion installed"
            else
                warn "idb-companion install failed — tap-bg will use HID fallback"
                ((issues++))
            fi
        fi
    fi

    # 4. fb-idb python CLI
    if command -v pip >/dev/null 2>&1 || command -v pip3 >/dev/null 2>&1; then
        local pip_cmd
        pip_cmd=$(command -v pip3 || command -v pip)
        if "$pip_cmd" show fb-idb >/dev/null 2>&1; then
            local fbidb_ver
            fbidb_ver=$("$pip_cmd" show fb-idb 2>&1 | awk '/^Version:/ {print $2}')
            ok "fb-idb installed (v$fbidb_ver)"
        else
            echo "  Installing fb-idb..."
            if "$pip_cmd" install fb-idb >/dev/null 2>&1; then
                ok "fb-idb installed"
            else
                warn "fb-idb install failed — tap-bg will use HID fallback"
                ((issues++))
            fi
        fi

        # 5. protobuf compat (fb-idb 1.1.x ships generated stubs that require
        #    protobuf >=3.20 and <4. Older or newer = AttributeError in idb_pb2.
        #    This is the silent failure mode that bit us: idb is "installed"
        #    but `idb list-targets` crashes inside protobuf.descriptor_pool.)
        local proto_ver
        proto_ver=$("$pip_cmd" show protobuf 2>&1 | awk '/^Version:/ {print $2}')
        if [[ -z "$proto_ver" ]]; then
            warn "protobuf not installed — installing 3.20.x for fb-idb compat"
            "$pip_cmd" install 'protobuf>=3.20,<4' >/dev/null 2>&1
        elif [[ "$proto_ver" =~ ^3\.(2[0-9]|[3-9][0-9]) ]]; then
            ok "protobuf $proto_ver (compat with fb-idb)"
        else
            warn "protobuf $proto_ver incompatible with fb-idb (needs 3.20.x)"
            echo "  Pinning to 3.20.3..."
            if "$pip_cmd" install 'protobuf>=3.20,<4' >/dev/null 2>&1; then
                ok "protobuf pinned to 3.20.x"
            else
                warn "protobuf pin failed — manually: pip install 'protobuf>=3.20,<4'"
                ((issues++))
            fi
        fi
    else
        warn "pip/pip3 missing — install Python 3 to enable fb-idb (HID fallback only)"
        ((issues++))
    fi

    # 6. Smoke test — does `idb list-targets` actually run?
    if command -v idb >/dev/null 2>&1; then
        if idb list-targets >/dev/null 2>&1; then
            ok "idb smoke test passed — tap-bg will use idb (zero visual impact)"
        else
            warn "idb installed but list-targets failed. Run 'idb list-targets' to see error."
            ((issues++))
        fi
    fi

    echo
    if (( issues == 0 )); then
        ok "Setup complete. tap-bg ready for zero-visual-impact mode."
    else
        warn "Setup complete with $issues issue(s). tap-bg falls back to HID helper (~100ms Simulator flicker, still functional)."
        echo "  To install idb manually: brew install idb-companion && pip install fb-idb && pip install 'protobuf>=3.20,<4'"
    fi
}

# ─── Device Management ───

cmd_devices() {
    echo "=== Available iOS Simulators ==="
    xcrun simctl list devices available | grep -E "(--|Booted|Shutdown)" | head -30
    echo ""
    echo "=== Booted ==="
    xcrun simctl list devices booted
}

cmd_boot() {
    local device="${1:-}"
    if [[ -z "$device" ]]; then
        echo "Usage: ios-ctl boot <device-name-or-udid>"
        echo "Example: ios-ctl boot 'iPhone 16 Pro'"
        return 1
    fi
    echo "Booting $device..."
    xcrun simctl boot "$device" 2>/dev/null || true
    open -a Simulator
    sleep 3
    ok "Simulator booted"
}

cmd_shutdown() {
    echo "Shutting down simulator..."
    xcrun simctl shutdown "$DEVICE" 2>/dev/null || true
    ok "Simulator shut down"
}

# ─── Build & Install ───

cmd_build() {
    local project_dir="${1:-.}"
    local scheme="${2:-}"

    cd "$project_dir"

    # Auto-detect project
    local project_file=""
    if compgen -G "*.xcworkspace" >/dev/null 2>&1; then
        project_file=$(echo *.xcworkspace | head -1)
        local project_flag="-workspace $project_file"
    elif compgen -G "*.xcodeproj" >/dev/null 2>&1; then
        project_file=$(echo *.xcodeproj | head -1)
        local project_flag="-project $project_file"
    elif [[ -f project.yml ]]; then
        echo "Found project.yml, running xcodegen..."
        xcodegen generate 2>&1
        project_file=$(echo *.xcodeproj | head -1)
        local project_flag="-project $project_file"
    else
        fail "No Xcode project found"
        return 1
    fi

    # Auto-detect scheme
    if [[ -z "$scheme" ]]; then
        scheme=$(xcodebuild -list $project_flag 2>/dev/null | grep -A 50 "Schemes:" | grep -v "Schemes:" | head -1 | xargs)
    fi

    echo "Building: $project_file (scheme: $scheme)"

    # Get the booted device name
    local device_name
    device_name=$(xcrun simctl list devices booted | grep "Booted" | sed 's/ (.*//;s/^    //')

    xcodebuild build \
        $project_flag \
        -scheme "$scheme" \
        -destination "platform=iOS Simulator,name=$device_name" \
        -quiet 2>&1

    ok "Build succeeded"

    # Resolve the EXACT built product from build settings — authoritative for this scheme.
    # (The old "newest *.app in DerivedData" heuristic could pick an unrelated app, e.g. Termly.app.)
    local app_path
    app_path=$(xcodebuild $project_flag -scheme "$scheme" -sdk iphonesimulator -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{d=$2} / FULL_PRODUCT_NAME = /{n=$2} END{if(d!=""&&n!="")print d"/"n}')
    # Fallback: legacy heuristic (newest matching .app) only if the settings lookup failed.
    if [[ -z "$app_path" || ! -d "$app_path" ]]; then
        local derived_data="$HOME/Library/Developer/Xcode/DerivedData"
        app_path=$(find "$derived_data" -name "*.app" -path "*/Debug-iphonesimulator/*" -not -name "*Tests*" -not -name "*Runner*" -newer "$project_file" -type d 2>/dev/null | head -1)
    fi

    if [[ -n "$app_path" ]]; then
        # Save for later use
        echo "$app_path" > /tmp/.ios-debug-app-path
        local bundle_id
        bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_path/Info.plist" 2>/dev/null || echo "unknown")
        echo "$bundle_id" > /tmp/.ios-debug-bundle-id
        ok "App: $app_path"
        ok "Bundle ID: $bundle_id"
    fi
}

cmd_install() {
    local app_path="${1:-$(cat /tmp/.ios-debug-app-path 2>/dev/null)}"
    if [[ -z "$app_path" ]]; then
        fail "No app path. Run 'build' first or provide path."
        return 1
    fi
    echo "Installing $app_path..."
    xcrun simctl install "$DEVICE" "$app_path"
    ok "Installed"
}

cmd_launch() {
    local bundle_id="${1:-$(cat /tmp/.ios-debug-bundle-id 2>/dev/null)}"
    if [[ -z "$bundle_id" ]]; then
        fail "No bundle ID. Run 'build' first or provide bundle ID."
        return 1
    fi
    echo "Launching $bundle_id..."
    xcrun simctl launch "$DEVICE" "$bundle_id" 2>&1
    sleep 1
    ok "Launched"
}

cmd_terminate() {
    local bundle_id="${1:-$(cat /tmp/.ios-debug-bundle-id 2>/dev/null)}"
    if [[ -z "$bundle_id" ]]; then
        fail "No bundle ID"
        return 1
    fi
    xcrun simctl terminate "$DEVICE" "$bundle_id" 2>/dev/null || true
    ok "Terminated $bundle_id"
}

cmd_run() {
    # Build + Install + Launch in one command
    local project_dir="${1:-.}"
    cmd_build "$project_dir" "${2:-}"
    cmd_install
    cmd_launch
}

# ─── Visual Inspection ───

cmd_screenshot() {
    local output="${1:-$SCREENSHOT_DIR/ios-screenshot.png}"
    xcrun simctl io "$DEVICE" screenshot "$output" 2>/dev/null
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
    ok "Screenshot saved to $output"
}

cmd_record() {
    local output="${1:-$SCREENSHOT_DIR/ios-recording.mp4}"
    echo "Recording video... Press Ctrl+C to stop"
    xcrun simctl io "$DEVICE" recordVideo --codec=h264 "$output"
}

# ─── Accessibility / UI Hierarchy ───

cmd_tree() {
    local project_dir="${1:-.}"
    cd "$project_dir"

    local project_flag=""
    if compgen -G "*.xcworkspace" >/dev/null 2>&1; then
        project_flag="-workspace $(echo *.xcworkspace | head -1)"
    elif compgen -G "*.xcodeproj" >/dev/null 2>&1; then
        project_flag="-project $(echo *.xcodeproj | head -1)"
    else
        fail "No project found for XCUITest"
        return 1
    fi

    local device_name
    device_name=$(xcrun simctl list devices booted | grep "Booted" | sed 's/ (.*//;s/^    //')

    echo "Dumping accessibility tree via XCUITest..."

    # Find a scheme that contains UITests, or fall back to the first scheme that includes test targets
    local all_schemes
    all_schemes=$(xcodebuild -list $project_flag 2>/dev/null | grep -A 50 "Schemes:" | grep -v "Schemes:" | xargs)

    # Use a scheme that has the UITest target configured
    local scheme
    for s in $all_schemes; do
        if echo "$s" | grep -qi "uitest\|test"; then
            scheme="$s"
            break
        fi
    done
    # If no test scheme found, use the main scheme (it should include the UITest target via dependencies)
    if [[ -z "$scheme" ]]; then
        scheme=$(echo "$all_schemes" | tr ' ' '\n' | head -1)
    fi

    local test_target
    test_target=$(xcodebuild -list $project_flag 2>/dev/null | grep -A 50 "Schemes:" | grep -v "Schemes:" | xargs | tr ' ' '\n' | grep -i "uitest\|test" | head -1 || echo "")

    # Build the UITest target and run
    xcodebuild test \
        $project_flag \
        -scheme "$scheme" \
        -destination "platform=iOS Simulator,name=$device_name" \
        -only-testing:TestAppUITests/AccessibilityDump/testDumpAccessibilityTree \
        -test-timeouts-enabled NO \
        CODE_SIGNING_ALLOWED=NO \
        2>&1 | grep -v "^$" | tail -5

    if [[ -f /tmp/ios-accessibility-tree.json ]]; then
        ok "Accessibility tree saved to /tmp/ios-accessibility-tree.json"
        # Print a summary
        python3 -c "
import json
with open('/tmp/ios-accessibility-tree.json') as f:
    elements = json.load(f)
print(f'  Total elements: {len(elements)}')
types = {}
for e in elements:
    t = e.get('type','?')
    types[t] = types.get(t,0) + 1
for t, c in sorted(types.items()):
    print(f'    {t}: {c}')
print()
print('  Interactive elements:')
for e in elements:
    if e.get('identifier') or e.get('type') in ('button','textField','toggle','slider','link'):
        eid = e.get('identifier') or '-'
        label = e.get('label') or e.get('value') or ''
        frame = e.get('frame',{})
        print(f'    [{e[\"type\"]}] id=\"{eid}\" label=\"{label}\" @ ({frame.get(\"x\",0)},{frame.get(\"y\",0)},{frame.get(\"w\",0)},{frame.get(\"h\",0)})')
" 2>/dev/null
    else
        fail "Accessibility tree file not created"
    fi
}

# ─── Interaction via AppleScript ───

cmd_tap() {
    local x="${1:-}"
    local y="${2:-}"

    if [[ -z "$x" || -z "$y" ]]; then
        echo "Usage: ios-ctl tap <x> <y>"
        echo "       ios-ctl tap identifier <accessibilityId>"
        echo "       ios-ctl tap label <labelText>"
        return 1
    fi

    # If first arg is "identifier" or "label", look up from accessibility tree
    if [[ "$x" == "identifier" || "$x" == "label" ]]; then
        local search_key="$x"
        local search_value="$y"
        if [[ ! -f /tmp/ios-accessibility-tree.json ]]; then
            warn "No accessibility tree. Run 'tree' first. Falling back to screenshot-based approach."
            return 1
        fi
        local coords
        coords=$(/usr/bin/python3 << PYEOF
import json
with open('/tmp/ios-accessibility-tree.json') as f:
    elements = json.load(f)
for e in elements:
    if e.get('$search_key','') == '$search_value' or ('$search_key' == 'label' and '$search_value' in e.get('label','')):
        fr = e['frame']
        print('%d %d' % (fr['x'] + fr['w']//2, fr['y'] + fr['h']//2))
        break
PYEOF
)
        if [[ -z "$coords" ]]; then
            fail "Element not found: $search_key='$search_value'"
            return 1
        fi
        x=$(echo "$coords" | cut -d' ' -f1)
        y=$(echo "$coords" | cut -d' ' -f2)
        echo "  Resolved to ($x, $y)"
    fi

    echo "Tapping at ($x, $y)..."

    # Get simulator content area position, then use Python to send mouse click
    local content_info
    content_info=$(osascript << 'ASEOF'
tell application "Simulator" to activate
delay 0.3
tell application "System Events"
    tell process "Simulator"
        set frontWindow to front window
        set {winX, winY} to position of frontWindow
        set {winW, winH} to size of frontWindow
        set contentX to winX
        set contentY to winY
        set contentW to winW
        set contentH to winH
        set allGroups to every group of frontWindow
        repeat with g in allGroups
            try
                set {gX, gY} to position of g
                set {gW, gH} to size of g
                if gW > 100 and gH > 100 then
                    set contentX to gX
                    set contentY to gY
                    set contentW to gW
                    set contentH to gH
                end if
            end try
        end repeat
        return "" & contentX & " " & contentY & " " & contentW & " " & contentH
    end tell
end tell
ASEOF
)
    local cx cy cw ch
    read -r cx cy cw ch <<< "$content_info"

    # Calculate absolute screen coordinates
    local abs_x abs_y
    abs_x=$(echo "$cx + $x * $cw / 390" | bc)
    abs_y=$(echo "$cy + $y * $ch / 844" | bc)

    # Use osascript (JXA) to send mouse click via CGEvent
    osascript -l JavaScript -e "
        ObjC.import('CoreGraphics');
        var point = $.CGPointMake($abs_x, $abs_y);
        var mouseDown = $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseDown, point, $.kCGMouseButtonLeft);
        $.CGEventPost($.kCGHIDEventTap, mouseDown);
        delay(0.05);
        var mouseUp = $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseUp, point, $.kCGMouseButtonLeft);
        $.CGEventPost($.kCGHIDEventTap, mouseUp);
    " 2>&1

    ok "Tap dispatched at ($x, $y)"
}

# ─── Background tap (no focus steal, cursor restored) ───
#
# Why: cmd_tap activates Simulator and posts via the global HID event
# tap, which (a) brings Simulator to front and (b) physically moves the
# user's cursor. cmd_tap_bg does neither: it posts the click via
# CGEvent.postToPid(simulatorPid) so the event enters the Simulator's
# private event queue without touching frontmost, and warps the cursor
# back to its original position immediately after.
#
# Limitation: iOS UI elements (buttons inside the simulated device) are
# NOT exposed to macOS Accessibility — the Simulator window only
# surfaces window chrome to AX. So we can't use AXPress like macOS apps;
# we still need a coord-based click. The tradeoff is the cursor may
# briefly flash at the click site before the warp restores it.

cmd_tap_bg() {
    local x="${1:-}"
    local y="${2:-}"

    if [[ -z "$x" || -z "$y" ]]; then
        cat << 'USAGE'
Usage: ios-ctl tap-bg <x> <y>
       ios-ctl tap-bg identifier <accessibilityId>
       ios-ctl tap-bg label <labelText>
  Like `tap`, but injects a real iOS touch via idb: does NOT activate the
  Simulator, steal focus, or move the user's cursor. Requires idb installed.
USAGE
        return 1
    fi

    # Selector lookup (identical to cmd_tap)
    if [[ "$x" == "identifier" || "$x" == "label" ]]; then
        local search_key="$x"
        local search_value="$y"
        if [[ ! -f /tmp/ios-accessibility-tree.json ]]; then
            warn "No accessibility tree. Run 'tree' first."
            return 1
        fi
        local coords
        coords=$(/usr/bin/python3 << PYEOF
import json
with open('/tmp/ios-accessibility-tree.json') as f:
    elements = json.load(f)
for e in elements:
    if e.get('$search_key','') == '$search_value' or ('$search_key' == 'label' and '$search_value' in e.get('label','')):
        fr = e['frame']
        print('%d %d' % (fr['x'] + fr['w']//2, fr['y'] + fr['h']//2))
        break
PYEOF
)
        if [[ -z "$coords" ]]; then
            fail "Element not found: $search_key='$search_value'"
            return 1
        fi
        x=$(echo "$coords" | cut -d' ' -f1)
        y=$(echo "$coords" | cut -d' ' -f2)
        echo "  Resolved to device-coords ($x, $y)"
    fi

    local udid
    udid=$(xcrun simctl list devices booted \
        | grep -oE "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}" \
        | head -1)
    if [[ -z "$udid" ]]; then
        fail "No booted simulator. Boot it first with 'ios-ctl boot'."
        return 1
    fi

    # ── Visual indicator setup ─────────────────────────────────────────────
    # Compute abs screen coords UP FRONT (used by both paths). This lets us
    # show a 700ms red ripple at the click site BEFORE the actual tap fires,
    # so the user can see where the tap-bg landed — important context when
    # AI scripts drive UI silently.
    # Disable by setting GODUCK_TAP_QUIET=1.
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _content_info
    _content_info=$(osascript << 'ASEOF'
tell application "System Events"
    tell process "Simulator"
        try
            set frontWindow to front window
            set {winX, winY} to position of frontWindow
            set {winW, winH} to size of frontWindow
            set contentX to winX
            set contentY to winY
            set contentW to winW
            set contentH to winH
            set allGroups to every group of frontWindow
            repeat with g in allGroups
                try
                    set {gX, gY} to position of g
                    set {gW, gH} to size of g
                    if gW > 100 and gH > 100 then
                        set contentX to gX
                        set contentY to gY
                        set contentW to gW
                        set contentH to gH
                    end if
                end try
            end repeat
            return "" & contentX & " " & contentY & " " & contentW & " " & contentH
        on error
            return "ERR"
        end try
    end tell
end tell
ASEOF
)
    if [[ "$_content_info" != "ERR" && -n "$_content_info" ]]; then
        local _cx _cy _cw _ch
        read -r _cx _cy _cw _ch <<< "$_content_info"
        local _ax _ay
        _ax=$(printf "%.0f" "$(echo "$_cx + $x * $_cw / 390" | bc -l)")
        _ay=$(printf "%.0f" "$(echo "$_cy + $y * $_ch / 844" | bc -l)")
        if [[ -z "${GODUCK_TAP_QUIET:-}" ]]; then
            # Fire indicator in background — runs ~700ms then self-exits.
            # Doesn't block the real tap below.
            ( swift "$script_dir/ios-tap-indicator.swift" "$_ax" "$_ay" >/dev/null 2>&1 & )
        fi
    fi

    # Try idb first (zero visual impact — talks to Simulator's touch service
    # directly, bypasses HID). If idb isn't installed or fails, fall back to
    # the swift HID helper which does cursor warp + frontmost restore (visible
    # ~80ms flicker, but functional and doesn't drag user to Simulator).
    #
    # Why the old `postToPid` approach was dropped entirely: the Simulator
    # touch synthesizer reads events from the GLOBAL HID event stream
    # (kCGHIDEventTap) only. CGEvent.postToPid delivers to the process's
    # private queue, which the synthesizer never reads — so those clicks
    # were silently dropped.

    # Path 1: idb — preferred (zero visual impact)
    if command -v idb >/dev/null 2>&1; then
        if idb ui tap --udid "$udid" "$x" "$y" >/dev/null 2>&1; then
            ok "tap-bg ($x, $y) via idb — no focus steal, no cursor move (indicator shown)"
            return 0
        else
            warn "idb ui tap failed (companion not running?), falling back to HID helper"
        fi
    fi

    # Path 2: HID + cursor warp + frontmost restore (swift helper)
    # Compute absolute screen coords using the same translation as cmd_tap.
    # We DO NOT call `tell application "Simulator" to activate` — the whole
    # point is to avoid forced frontmost change. Window position is fetched
    # via "System Events" → process query, which doesn't require activation.
    local content_info
    content_info=$(osascript << 'ASEOF'
tell application "System Events"
    tell process "Simulator"
        try
            set frontWindow to front window
            set {winX, winY} to position of frontWindow
            set {winW, winH} to size of frontWindow
            set contentX to winX
            set contentY to winY
            set contentW to winW
            set contentH to winH
            set allGroups to every group of frontWindow
            repeat with g in allGroups
                try
                    set {gX, gY} to position of g
                    set {gW, gH} to size of g
                    if gW > 100 and gH > 100 then
                        set contentX to gX
                        set contentY to gY
                        set contentW to gW
                        set contentH to gH
                    end if
                end try
            end repeat
            return "" & contentX & " " & contentY & " " & contentW & " " & contentH
        on error
            return "ERR"
        end try
    end tell
end tell
ASEOF
)
    if [[ "$content_info" == "ERR" || -z "$content_info" ]]; then
        fail "Could not read Simulator window geometry. Ensure Simulator is running."
        return 1
    fi
    local cx cy cw ch
    read -r cx cy cw ch <<< "$content_info"

    # Device logical coords are 390x844 (iPhone 16e/Pro logical size).
    # Map to absolute screen pixels at the Simulator content area.
    local abs_x abs_y
    abs_x=$(echo "$cx + $x * $cw / 390" | bc -l)
    abs_y=$(echo "$cy + $y * $ch / 844" | bc -l)
    abs_x=$(printf "%.0f" "$abs_x")
    abs_y=$(printf "%.0f" "$abs_y")

    if swift "$script_dir/ios-bg-click.swift" "$abs_x" "$abs_y" >/dev/null 2>&1; then
        ok "tap-bg ($x, $y) via HID + cursor warp — brief Simulator flicker, cursor & frontmost restored (indicator shown)"
    else
        fail "Both idb and HID fallback failed. Check Accessibility permission on terminal/Claude Code in System Settings → Privacy & Security."
        return 1
    fi
}

cmd_type() {
    local text="${1:-}"
    if [[ -z "$text" ]]; then
        echo "Usage: ios-ctl type <text>"
        return 1
    fi

    echo "Typing: $text"
    osascript -e "
tell application \"Simulator\" to activate
delay 0.3
tell application \"System Events\"
    keystroke \"$text\"
end tell
" 2>&1

    ok "Text typed"
}

cmd_key() {
    local key="${1:-}"
    case "$key" in
        home)
            xcrun simctl ui "$DEVICE" home 2>/dev/null || \
            osascript -e 'tell application "Simulator" to activate' -e 'tell application "System Events" to key code 115 using {command down, shift down}' 2>/dev/null
            ok "Home pressed"
            ;;
        shake)
            # Simulate shake via menu
            osascript -e 'tell application "Simulator" to activate' -e 'delay 0.3' -e 'tell application "System Events" to tell process "Simulator" to click menu item "Shake" of menu "Device" of menu bar 1' 2>/dev/null
            ok "Shake triggered"
            ;;
        *)
            echo "Usage: ios-ctl key <home|shake>"
            ;;
    esac
}

cmd_swipe() {
    local direction="${1:-up}"
    echo "Swiping $direction..."

    osascript -e "
tell application \"Simulator\" to activate
delay 0.3
tell application \"System Events\"
    tell process \"Simulator\"
        set frontWindow to front window
        set {winX, winY} to position of frontWindow
        set {winW, winH} to size of frontWindow
        set centerX to winX + winW / 2
        set centerY to winY + winH / 2
    end tell
end tell

-- Perform swipe via mouse drag
tell application \"System Events\"
    if \"$direction\" is \"up\" then
        -- drag from center-bottom to center-top
        do shell script \"osascript -e 'tell application \\\"System Events\\\"' -e 'click at {\" & centerX & \",\" & (centerY + 100) & \"}' -e 'end tell'\"
    else if \"$direction\" is \"down\" then
        do shell script \"osascript -e 'tell application \\\"System Events\\\"' -e 'click at {\" & centerX & \",\" & (centerY - 100) & \"}' -e 'end tell'\"
    end if
end tell
" 2>/dev/null

    ok "Swipe $direction dispatched"
}

# ─── Logs ───

cmd_log() {
    local seconds="${1:-10}"
    local bundle_id="${2:-$(cat /tmp/.ios-debug-bundle-id 2>/dev/null)}"

    if [[ -z "$bundle_id" ]]; then
        echo "Streaming all simulator logs for ${seconds}s..."
        timeout "$seconds" xcrun simctl spawn "$DEVICE" log stream --level=debug 2>/dev/null || true
    else
        echo "Streaming logs for $bundle_id for ${seconds}s..."
        timeout "$seconds" xcrun simctl spawn "$DEVICE" log stream \
            --predicate "subsystem == '$bundle_id' OR processImagePath CONTAINS '$(echo $bundle_id | sed 's/com\.\w*\.//;s/\.//g')'" \
            --level=debug 2>/dev/null || true
    fi
}

# ─── Settings & Environment ───

cmd_appearance() {
    local mode="${1:-}"
    if [[ -z "$mode" ]]; then
        xcrun simctl ui "$DEVICE" appearance
    else
        xcrun simctl ui "$DEVICE" appearance "$mode"
        ok "Appearance set to $mode"
    fi
}

cmd_statusbar() {
    xcrun simctl status_bar "$DEVICE" override \
        --time "9:41" \
        --batteryState charged \
        --batteryLevel 100 \
        --wifiBars 3 \
        --cellularBars 4
    ok "Status bar overridden (clean screenshot mode)"
}

cmd_location() {
    local lat="${1:-37.7749}"
    local lon="${2:--122.4194}"
    xcrun simctl location "$DEVICE" set "$lat,$lon"
    ok "Location set to $lat, $lon"
}

cmd_permissions() {
    local bundle_id="${1:-$(cat /tmp/.ios-debug-bundle-id 2>/dev/null)}"
    if [[ -z "$bundle_id" ]]; then
        fail "No bundle ID"
        return 1
    fi
    local permission="${2:-all}"
    xcrun simctl privacy "$DEVICE" grant "$permission" "$bundle_id"
    ok "Granted $permission to $bundle_id"
}

cmd_push() {
    local bundle_id="${1:-$(cat /tmp/.ios-debug-bundle-id 2>/dev/null)}"
    local title="${2:-Test Push}"
    local body="${3:-This is a test notification}"

    if [[ -z "$bundle_id" ]]; then
        fail "No bundle ID"
        return 1
    fi

    local payload="/tmp/ios-push-payload.json"
    cat > "$payload" << EOFPUSH
{
    "aps": {
        "alert": {
            "title": "$title",
            "body": "$body"
        },
        "sound": "default",
        "badge": 1
    }
}
EOFPUSH

    xcrun simctl push "$DEVICE" "$bundle_id" "$payload"
    ok "Push notification sent"
}

# ─── Health Check ───

cmd_health() {
    echo "=== iOS App Health Check ==="
    echo ""

    # Check simulator
    local booted
    booted=$(xcrun simctl list devices booted 2>/dev/null | grep "Booted" | head -1)
    if [[ -n "$booted" ]]; then
        ok "Simulator: $booted"
    else
        fail "No booted simulator"
        return 1
    fi

    # Check app
    local bundle_id
    bundle_id=$(cat /tmp/.ios-debug-bundle-id 2>/dev/null || echo "")
    if [[ -n "$bundle_id" ]]; then
        ok "Bundle ID: $bundle_id"
        # Check if app is running
        if xcrun simctl spawn "$DEVICE" launchctl list 2>/dev/null | grep -q "$bundle_id"; then
            ok "App is running"
        else
            warn "App may not be running"
        fi
    else
        warn "No tracked app (run 'build' first)"
    fi

    # Take screenshot
    xcrun simctl io "$DEVICE" screenshot /tmp/ios-health-screenshot.png 2>/dev/null
    ok "Screenshot: /tmp/ios-health-screenshot.png"

    # Check device info
    echo ""
    echo "  Device info:"
    echo "  $(xcrun simctl list devices booted | grep Booted)"
    echo "  Appearance: $(xcrun simctl ui "$DEVICE" appearance 2>/dev/null || echo 'unknown')"

    echo ""
    echo "=== Health check complete ==="
}

# ─── Help ───

cmd_help() {
    cat << 'HELP'
ios-ctl - iOS Simulator control tool for Claude Code

DEVICE MANAGEMENT:
  devices                    List available simulators
  boot <name|udid>           Boot a simulator
  shutdown                   Shutdown current simulator

BUILD & RUN:
  build [dir] [scheme]       Build iOS project (auto-detects project type)
  install [app-path]         Install app on simulator
  launch [bundle-id]         Launch app
  terminate [bundle-id]      Terminate app
  run [dir] [scheme]         Build + Install + Launch in one command

VISUAL:
  screenshot [path]          Take screenshot
  record [path]              Record video (Ctrl+C to stop)
  tree [project-dir]         Dump accessibility tree via XCUITest

INTERACTION:
  tap <x> <y>               Tap at device coordinates
  tap identifier <id>       Tap element by accessibility identifier
  tap label <text>          Tap element by label
  type <text>               Type text (element must be focused)
  key <home|shake>          Press hardware key
  swipe <up|down>           Swipe gesture

MONITORING:
  log [seconds] [bundle-id]  Stream device logs
  health                     Health check

ENVIRONMENT:
  appearance [light|dark]    Get/set appearance
  statusbar                  Override status bar for clean screenshots
  location <lat> <lon>       Set simulated location
  permissions <bundle-id> <perm>  Grant permission
  push [bundle-id] [title] [body] Send push notification

ENV VARS:
  IOS_DEVICE=booted          Device specifier (default: booted)
HELP
}

# ─── Main ───

cmd="${1:-help}"
shift 2>/dev/null || true

case "$cmd" in
    setup)       cmd_setup "$@" ;;
    devices)     cmd_devices "$@" ;;
    boot)        cmd_boot "$@" ;;
    shutdown)    cmd_shutdown "$@" ;;
    build)       cmd_build "$@" ;;
    install)     cmd_install "$@" ;;
    launch)      cmd_launch "$@" ;;
    terminate)   cmd_terminate "$@" ;;
    run)         cmd_run "$@" ;;
    screenshot)  cmd_screenshot "$@" ;;
    record)      cmd_record "$@" ;;
    tree)        cmd_tree "$@" ;;
    tap)         cmd_tap "$@" ;;
    tap-bg)      cmd_tap_bg "$@" ;;
    type)        cmd_type "$@" ;;
    key)         cmd_key "$@" ;;
    swipe)       cmd_swipe "$@" ;;
    log)         cmd_log "$@" ;;
    health)      cmd_health "$@" ;;
    appearance)  cmd_appearance "$@" ;;
    statusbar)   cmd_statusbar "$@" ;;
    location)    cmd_location "$@" ;;
    permissions) cmd_permissions "$@" ;;
    push)        cmd_push "$@" ;;
    help|--help|-h) cmd_help ;;
    *)           echo "Unknown command: $cmd"; cmd_help ;;
esac
