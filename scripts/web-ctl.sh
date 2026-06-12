#!/usr/bin/env bash
# web-ctl.sh - Browser-based web app debug tool for Claude Code
# Reuses the CDP client from electron-debug, connects to Chrome/Edge
set -euo pipefail

CDP_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cdp-client.mjs"
STATE_FILE="/tmp/.web-debug-state.json"

# Find a free port starting from $1
find_free_port() {
    local port="${1:-9333}"
    while lsof -i ":$port" &>/dev/null; do
        port=$((port + 1))
    done
    echo "$port"
}

# Determine port: explicit CDP_PORT > saved state > auto-find free
if [[ -n "${CDP_PORT:-}" ]]; then
    PORT="$CDP_PORT"
elif [[ -f "$STATE_FILE" ]]; then
    PORT=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$STATE_FILE','utf8')).port||9333)" 2>/dev/null)
else
    PORT=9333
fi
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

# ─── Launch ───

cmd_launch() {
    local url="${1:-}"
    local browser="${WEB_BROWSER:-chrome}"

    # Find browser
    local browser_path=""
    case "$browser" in
        chrome|Chrome)
            browser_path="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
            ;;
        edge|Edge)
            browser_path="/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
            ;;
        brave|Brave)
            browser_path="/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
            ;;
        *)
            browser_path="$browser"
            ;;
    esac

    if [[ ! -x "$browser_path" ]]; then
        fail "Browser not found: $browser_path"
        return 1
    fi

    # Check if current port already has a debug session
    if curl -s "http://localhost:$PORT/json/version" >/dev/null 2>&1; then
        ok "Debug port $PORT already active"
        if [[ -n "$url" ]]; then
            echo "Opening: $url"
            CDP_PORT=$PORT node "$CDP_SCRIPT" eval "window.location.href='$url'" 2>/dev/null || true
        fi
        return 0
    fi

    # Auto-find free port for new launch
    PORT=$(find_free_port "$PORT")
    echo "Launching $browser with debug port $PORT..."

    # Create a temp user data dir to avoid conflicts with existing Chrome sessions
    local user_data_dir="/tmp/web-debug-chrome-profile"
    mkdir -p "$user_data_dir"

    "$browser_path" \
        --remote-debugging-port="$PORT" \
        --user-data-dir="$user_data_dir" \
        --no-first-run \
        --no-default-browser-check \
        ${url:+"$url"} &

    local pid=$!
    echo "{\"pid\":$pid,\"port\":$PORT,\"browser\":\"$browser\"}" > "$STATE_FILE"

    # Wait for debug port
    echo "Waiting for debug port..."
    for i in $(seq 1 15); do
        sleep 1
        if curl -s "http://localhost:$PORT/json/version" >/dev/null 2>&1; then
            local version
            version=$(curl -s "http://localhost:$PORT/json/version" | python3 -c "import sys,json;print(json.load(sys.stdin).get('Browser','?'))" 2>/dev/null)
            ok "Browser ready: $version (port $PORT)"
            return 0
        fi
    done
    warn "Browser started but debug port not responding after 15s"
}

cmd_open() {
    local url="${1:-}"
    if [[ -z "$url" ]]; then
        echo "Usage: web-ctl open <url>"
        return 1
    fi
    echo "Opening: $url"
    CDP_PORT=$PORT node "$CDP_SCRIPT" eval "window.location.href='$url'" 2>/dev/null
    sleep 1
    ok "Navigated to $url"
}

cmd_stop() {
    if [[ -f "$STATE_FILE" ]]; then
        local pid
        pid=$(python3 -c "import json;print(json.load(open('$STATE_FILE')).get('pid',0))" 2>/dev/null)
        if [[ -n "$pid" && "$pid" != "0" ]]; then
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "$STATE_FILE"
    fi
    # Also kill any Chrome instances on our debug port
    pkill -f "remote-debugging-port=$PORT" 2>/dev/null || true
    ok "Browser stopped"
}

# ─── Dev Server ───

cmd_serve() {
    local dir="${1:-.}"
    local serve_port="${2:-3000}"

    cd "$dir"

    # Auto-detect and start dev server
    if [[ -f "package.json" ]]; then
        local has_dev
        has_dev=$(python3 -c "import json;s=json.load(open('package.json')).get('scripts',{});print('dev' if 'dev' in s else 'start' if 'start' in s else '')" 2>/dev/null)

        if [[ -n "$has_dev" ]]; then
            echo "Starting dev server (npm run $has_dev)..."
            npm run "$has_dev" > /tmp/web-debug-server.log 2>&1 &
            echo $! > /tmp/.web-debug-server-pid
            sleep 3

            # Detect the actual URL from output
            local url
            url=$(grep -oE "https?://localhost:[0-9]+" /tmp/web-debug-server.log | head -1)
            if [[ -z "$url" ]]; then
                url="http://localhost:$serve_port"
            fi
            ok "Dev server: $url (log: /tmp/web-debug-server.log)"
            echo "$url" > /tmp/.web-debug-url

            # Launch browser if not already running
            cmd_launch "$url"
            return
        fi
    fi

    # Fallback: serve static files with Python
    echo "Serving static files from $dir on port $serve_port..."
    python3 -m http.server "$serve_port" --directory "$dir" > /tmp/web-debug-server.log 2>&1 &
    echo $! > /tmp/.web-debug-server-pid
    local url="http://localhost:$serve_port"
    echo "$url" > /tmp/.web-debug-url
    ok "Static server: $url"
    cmd_launch "$url"
}

cmd_stop_server() {
    if [[ -f /tmp/.web-debug-server-pid ]]; then
        kill "$(cat /tmp/.web-debug-server-pid)" 2>/dev/null || true
        rm -f /tmp/.web-debug-server-pid
    fi
    ok "Dev server stopped"
}

# ─── CDP Commands (delegated to cdp-client.mjs) ───

cmd_cdp() {
    CDP_PORT=$PORT node "$CDP_SCRIPT" "$@"
}

cmd_screenshot() {
    local output="${1:-/tmp/web-screenshot.png}"
    CDP_PORT=$PORT node "$CDP_SCRIPT" screenshot "$output"
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
}

cmd_eval() {
    CDP_PORT=$PORT node "$CDP_SCRIPT" eval "$@"
}

cmd_console() {
    local seconds="${1:-30}"
    CDP_PORT=$PORT node "$CDP_SCRIPT" console "$seconds"
}

cmd_network() {
    local seconds="${1:-15}"
    CDP_PORT=$PORT node "$CDP_SCRIPT" network "$seconds"
}

cmd_perf() {
    CDP_PORT=$PORT node "$CDP_SCRIPT" perf
}

cmd_dom() {
    CDP_PORT=$PORT node "$CDP_SCRIPT" dom
}

cmd_a11y() {
    CDP_PORT=$PORT node "$CDP_SCRIPT" a11y
}

cmd_health() {
    CDP_PORT=$PORT node "$CDP_SCRIPT" health
}

cmd_targets() {
    CDP_PORT=$PORT node "$CDP_SCRIPT" targets
}

cmd_click() {
    CDP_PORT=$PORT node "$CDP_SCRIPT" click "$@"
}

cmd_type_text() {
    # Focus element then type via CDP
    local selector="${1:-}"
    local text="${2:-}"
    if [[ -z "$selector" || -z "$text" ]]; then
        echo "Usage: web-ctl type \"selector\" \"text\""
        return 1
    fi
    CDP_PORT=$PORT node "$CDP_SCRIPT" eval "document.querySelector('$selector')?.focus()"
    sleep 0.2

    # Type via CDP Input.insertText
    CDP_PORT=$PORT node "$CDP_SCRIPT" eval "
        const el = document.querySelector('$selector');
        if (el) {
            el.value = '$text';
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
        }
    "
    ok "Typed into $selector"
}

cmd_wait() {
    local selector="${1:-}"
    local timeout_ms="${2:-10000}"
    if [[ -z "$selector" ]]; then
        echo "Usage: web-ctl wait \"selector\" [timeoutMs]"
        return 1
    fi
    CDP_PORT=$PORT node "$CDP_SCRIPT" wait "$selector" "$timeout_ms" 2>/dev/null || \
    CDP_PORT=$PORT node "$CDP_SCRIPT" eval "
        new Promise((resolve, reject) => {
            if (document.querySelector('$selector')) { resolve(true); return; }
            const observer = new MutationObserver(() => {
                if (document.querySelector('$selector')) {
                    observer.disconnect();
                    resolve(true);
                }
            });
            observer.observe(document.body, {childList: true, subtree: true});
            setTimeout(() => { observer.disconnect(); reject('timeout'); }, $timeout_ms);
        }).then(() => 'found').catch(() => 'timeout')
    "
}

# ─── Responsive Testing ───

cmd_viewport() {
    local preset="${1:-}"
    local w="" h=""

    case "$preset" in
        mobile|iphone)   w=375; h=812 ;;
        tablet|ipad)     w=768; h=1024 ;;
        desktop)         w=1440; h=900 ;;
        *)
            if [[ "$preset" =~ ^[0-9]+x[0-9]+$ ]]; then
                w="${preset%x*}"; h="${preset#*x}"
            else
                echo "Usage: web-ctl viewport <mobile|tablet|desktop|WxH>"
                return 1
            fi
            ;;
    esac

    CDP_PORT=$PORT node "$CDP_SCRIPT" eval "
        // Resize via CDP Emulation
        window.resizeTo($w, $h);
    "

    # Also set via CDP Emulation domain
    echo "Setting viewport to ${w}x${h}..."
    CDP_PORT=$PORT node "$CDP_SCRIPT" eval "
        document.documentElement.style.maxWidth = '${w}px';
        document.body.style.maxWidth = '${w}px';
        'viewport set to ${w}x${h}'
    "
    ok "Viewport: ${w}x${h}"
}

# ─── Help ───

cmd_help() {
    cat << 'HELP'
web-ctl - Browser web app debug tool for Claude Code
Reuses CDP client from electron-debug to control Chrome/Edge/Brave.

LIFECYCLE:
  launch [url]           Launch Chrome with debug port
  open <url>             Navigate to URL
  stop                   Stop debug browser
  serve [dir] [port]     Start dev server + launch browser
  stop-server            Stop dev server

INSPECTION (via CDP):
  targets                List browser tabs/targets
  health                 Health check
  screenshot [path]      Capture page screenshot
  dom                    Get page HTML
  eval "expression"      Evaluate JS in page
  perf                   Performance metrics
  a11y                   Accessibility audit

MONITORING:
  console [seconds]      Monitor console output
  network [seconds]      Monitor network requests

INTERACTION:
  click "selector"       Click element
  type "selector" "text" Type text into element
  wait "selector" [ms]   Wait for element

RESPONSIVE:
  viewport <preset|WxH>  Set viewport (mobile/tablet/desktop/WxH)

ENV VARS:
  CDP_PORT=9333          Debug port (default: 9333)
  WEB_BROWSER=chrome     Browser (chrome/edge/brave)
HELP
}

# ─── Main ───

cmd="${1:-help}"
shift 2>/dev/null || true

case "$cmd" in
    launch)      cmd_launch "$@" ;;
    open)        cmd_open "$@" ;;
    stop)        cmd_stop ;;
    serve)       cmd_serve "$@" ;;
    stop-server) cmd_stop_server ;;
    targets)     cmd_targets ;;
    health)      cmd_health ;;
    screenshot)  cmd_screenshot "$@" ;;
    dom)         cmd_dom ;;
    eval)        cmd_eval "$@" ;;
    perf)        cmd_perf ;;
    a11y)        cmd_a11y ;;
    console)     cmd_console "$@" ;;
    network)     cmd_network "$@" ;;
    click)       cmd_click "$@" ;;
    type)        cmd_type_text "$@" ;;
    wait)        cmd_wait "$@" ;;
    viewport)    cmd_viewport "$@" ;;
    help|--help) cmd_help ;;
    *)           echo "Unknown: $cmd"; cmd_help ;;
esac
