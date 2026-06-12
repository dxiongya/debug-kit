# Electron Debug Reference

**Script**: `node ~/.claude/skills/debug-kit/scripts/cdp-client.mjs <command>`
**Protocol**: Chrome DevTools Protocol (CDP) over zero-dependency WebSocket (RFC 6455)
**Env**: `CDP_PORT=9222` (default), `CDP_HOST=localhost`, `CDP_WINDOW=0` (multi-window)

## Commands

### Lifecycle

| Command | Description |
|---------|-------------|
| `launch [dev\|build]` | Auto-detect project type (electron-vite / forge / plain), launch with debug port, wait until ready |
| `stop` | Stop tracked process, show last main process output |

### Inspection

| Command | Description |
|---------|-------------|
| `targets` | List all debug targets (pages, service workers, etc.) |
| `health` | Full health check: port, page load, title, readyState, memory |
| `screenshot [path]` | Capture PNG screenshot (default: `/tmp/electron-screenshot.png`) |
| `dom` | Get full page HTML |
| `eval "expression"` | Evaluate JavaScript in renderer and return result |
| `perf` | Navigation timing, FCP, DOM nodes, heap, top 10 resources by duration |
| `a11y` | Accessibility audit: img-alt, button/link labels, heading order, lang, text size |
| `processes` | Electron process tree with PID, RSS, CPU%, command |

### Monitoring

| Command | Description |
|---------|-------------|
| `console [seconds]` | Monitor **main process + renderer** console simultaneously (default: 30s) |
| `network [seconds]` | Monitor HTTP requests/responses with timing (default: 15s) |
| `main-log [lines]` | Show main process log file (default: last 50 lines) |

### Interaction

| Command | Description |
|---------|-------------|
| `click "selector"` | Click element by CSS selector (resolves position, dispatches mousePressed+Released) |
| `type "selector" "text"` | Focus element, type text character by character |
| `key "KeyName"` | Send key press (e.g., `F12`, `Enter`, `Escape`, `ctrl+r`, `meta+shift+i`) |
| `wait "selector" [ms]` | Wait for element to appear in DOM (default timeout: 10000ms) |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CDP_PORT` | `9222` | Debug port for CDP connection |
| `CDP_HOST` | `localhost` | Debug host |
| `CDP_WINDOW` | `0` | Window index for multi-window apps |

## Workflow

```bash
P=~/.claude/skills/debug-kit/scripts

# 1. Launch the app (auto-detects electron-vite/forge/plain)
CDP_PORT=9222 node $P/cdp-client.mjs launch dev

# 2. Verify it started correctly
CDP_PORT=9222 node $P/cdp-client.mjs health

# 3. Take a screenshot
CDP_PORT=9222 node $P/cdp-client.mjs screenshot

# 4. Interact with the app
CDP_PORT=9222 node $P/cdp-client.mjs wait ".my-button" 5000
CDP_PORT=9222 node $P/cdp-client.mjs click ".my-button"

# 5. Monitor what happened
CDP_PORT=9222 node $P/cdp-client.mjs console 10

# 6. Check performance
CDP_PORT=9222 node $P/cdp-client.mjs perf

# 7. Stop when done
CDP_PORT=9222 node $P/cdp-client.mjs stop
```

## How Launch Works

1. Reads `package.json` to detect project type:
   - `electron-vite` -> `npx electron-vite dev -- --remote-debugging-port=PORT`
   - `@electron-forge/cli` -> `npx electron-forge start -- --remote-debugging-port=PORT`
   - Plain electron -> `npx electron MAIN --remote-debugging-port=PORT`
2. Sets `ELECTRON_ENABLE_LOGGING=1` for full console output
3. Redirects main process stdout/stderr to `/tmp/electron-debug-main.log`
4. Saves PID, port, log path to `/tmp/.electron-debug-state.json`
5. Polls debug port until responsive (up to 20s)

## Console Monitoring

The `console` command monitors **two sources simultaneously**:
- **Renderer process**: via CDP WebSocket (Runtime.consoleAPICalled, Runtime.exceptionThrown, Log.entryAdded)
- **Main process**: via tailing the log file written by `launch` (polls every 500ms)

Output is prefixed with `[RENDERER]` or `[MAIN]` to distinguish the source:
```
[22:02:32.171] [RENDERER] [DEBUG] [vite] connected.
[22:02:34.678] [MAIN] pong
```

### IPC Debugging

To debug IPC calls between main and renderer:
1. Launch the app with `launch dev`
2. Start `console` monitoring
3. Trigger the IPC action (e.g., `click` the button that sends IPC)
4. See `[MAIN]` output for `console.log` from IPC handlers

### Multi-Window Apps

For apps with multiple BrowserWindows, set `CDP_WINDOW` to target a specific window:
```bash
CDP_WINDOW=0 CDP_PORT=9222 node ~/.claude/skills/debug-kit/scripts/cdp-client.mjs screenshot  # Main window
CDP_WINDOW=1 CDP_PORT=9222 node ~/.claude/skills/debug-kit/scripts/cdp-client.mjs screenshot  # Second window
```

Use `targets` to list all available windows.

## Architecture

```
cdp-client.mjs
├── MiniWebSocket       Zero-dependency WebSocket client (RFC 6455)
├── State Management    PID/port tracking via /tmp/.electron-debug-state.json
├── CDP HTTP API        /json, /json/version endpoints
├── CDP WebSocket API   Runtime, Console, Log, Network, Page, Input domains
└── Main Process Logs   File tailing of /tmp/electron-debug-main.log
```

Key design decisions:
- **No npm dependencies**: Built-in WebSocket implementation avoids polluting user's project
- **Detached process**: `launch` spawns electron as detached so it survives if the script exits
- **Event listener fix**: MiniWebSocket uses listener arrays (not single callback) to support concurrent CDP subscriptions
- **Session helper**: `withCdpSession()` provides scoped WebSocket lifecycle with proper cleanup

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Port already in use | `lsof -i :9222` to find occupant, use different `CDP_PORT`, or `stop` first |
| No page targets | App may still be loading; use `wait` or retry after a few seconds |
| WebSocket refused | Confirm app is running: check `targets` or `main-log` |
| Screenshot is blank | Page not rendered yet; run `wait "body"` first |
| Main process logs empty | App wasn't started with `launch`; use `main-log` only with `launch` |
| Click hits wrong element | Use more specific CSS selector; check with `eval "document.querySelector('...')?.textContent"` |
| Multi-window confusion | Run `targets` to see all windows, set `CDP_WINDOW=N` |

## Interaction fidelity (verified)

- **Collection:** CDP `health` / `eval` / `dom` / `perf` / `a11y` / `screenshot`. *Verified (eval=4, title="Electron", screenshot ok).*
- **T1 semantic (default):** CDP `click "selector"` / `eval`. Deterministic, no real input.
- **T2 synthetic:** CDP `Input.dispatchMouseEvent` at coords (canvas-only).
- **T3 real OS HID:** rarely needed.

> **Virtual pointer:** same as Web — `click` glides the software cursor to the on-screen click
> location via `cdp-client.mjs` → `dk-pointer.sh`. `DK_POINTER=off` to disable.
