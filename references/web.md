# Web Debug Reference

**Script**: `bash ~/.claude/skills/debug-kit/scripts/web-ctl.sh <command>`
**Protocol**: CDP (reuses `cdp-client.mjs`)
**Env**: `CDP_PORT=9333` (default, avoids conflict with regular Chrome on 9222), `WEB_BROWSER=chrome` (chrome/edge/brave)

## Commands

### Lifecycle
| Command | Description |
|---------|-------------|
| `launch [url]` | Launch Chrome with debug port, isolated profile |
| `open <url>` | Navigate to URL |
| `stop` | Stop debug browser |
| `serve [dir] [port]` | Start dev server + launch browser |
| `stop-server` | Stop dev server |

### Inspection (via CDP)
| Command | Description |
|---------|-------------|
| `targets` | List browser tabs |
| `health` | Health check |
| `screenshot [path]` | Capture page screenshot (default: `/tmp/web-screenshot.png`) |
| `dom` | Get page HTML |
| `eval "expression"` | Evaluate JS in page |
| `perf` | Performance: FCP, DOM nodes, heap, resources |
| `a11y` | Accessibility audit |

### Monitoring
| Command | Description |
|---------|-------------|
| `console [sec]` | Monitor console output (default: 30s) |
| `network [sec]` | Monitor HTTP requests (default: 15s) |

### Interaction
| Command | Description |
|---------|-------------|
| `click "selector"` | Click element by CSS selector |
| `type "selector" "text"` | Type into input element |
| `wait "selector" [ms]` | Wait for element to appear |

### Responsive
| Command | Description |
|---------|-------------|
| `viewport mobile` | 375x812 (iPhone) |
| `viewport tablet` | 768x1024 (iPad) |
| `viewport desktop` | 1440x900 |
| `viewport WxH` | Custom (e.g., `viewport 1920x1080`) |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CDP_PORT` | `9333` | Debug port (uses 9333 to avoid conflicts with regular Chrome on 9222) |
| `WEB_BROWSER` | `chrome` | Browser: `chrome`, `edge`, `brave` |

## Workflow

```bash
P=~/.claude/skills/debug-kit/scripts

# For projects with dev server (React, Next.js, Vue, etc.)
bash $P/web-ctl.sh serve /path/to/project

# For static HTML files
bash $P/web-ctl.sh launch "file:///path/to/index.html"

# Interact and verify
bash $P/web-ctl.sh click "#loginButton"
bash $P/web-ctl.sh type "#email" "user@example.com"
bash $P/web-ctl.sh screenshot /tmp/result.png

# Performance & accessibility
bash $P/web-ctl.sh perf
bash $P/web-ctl.sh a11y

# Responsive testing
bash $P/web-ctl.sh viewport mobile
bash $P/web-ctl.sh a11y

# Cleanup
bash $P/web-ctl.sh stop
bash $P/web-ctl.sh stop-server
```

## Notes

- Chrome must be launched with `--user-data-dir` to enable debug port (creates isolated profile at `/tmp/web-debug-chrome-profile`)
- For localhost dev servers, use `127.0.0.1` instead of `localhost` if connection issues occur
- For static files, use `file:///` protocol directly — no server needed
- All CDP commands from `electron-debug` work here (same protocol)
- `serve` auto-detects: `npm run dev` > `npm run start` > `python3 -m http.server`

## Interaction fidelity (verified)

- **Collection:** CDP `dom` / `eval` / `a11y` / `perf` / `screenshot` — semantic, deterministic. *Verified (Web Test App).*
- **T1 semantic (default):** `click "selector"` / `eval` dispatch in-page events. Best fidelity for the DOM.
- **T2 synthetic:** CDP `Input.dispatchMouseEvent` at coordinates (rare; for canvas).
- **T3 real OS HID:** almost never needed for web; only for OS-level / cross-app flows.

> **Virtual pointer:** `click` glides the resident software cursor to the element's on-screen
> position (window origin + CSS coords + top-chrome offset) via `dk-pointer.sh` — no real cursor
> moved. Disable with `DK_POINTER=off`.
