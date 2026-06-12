# iOS Debug Reference

**Script**: `bash ~/.claude/skills/debug-kit/scripts/ios-ctl.sh <command>`
**Tools**: xcrun simctl, xcodebuild, AppleScript, JXA + CGEvent
**Env**: `IOS_DEVICE=booted` (default, or UDID)

## Architecture

```
ios-ctl.sh
├── xcrun simctl        Simulator lifecycle, screenshots, logs, settings
├── xcodebuild          Build & XCUITest accessibility tree dump
├── AppleScript         Window position detection, keyboard input
├── JXA + CGEvent       Precise touch simulation via mouse events
└── Accessibility Tree  XCUITest-based UI element dump (JSON)
```

**Key innovation**: Touch simulation uses `CGEventCreateMouseEvent` via JXA to send real mouse click events at precise screen coordinates, which the Simulator converts to touch events. Coordinates are mapped from device logical points to screen pixels by detecting the Simulator's content area position.

## Commands

### Setup / Diagnose
| Command | Description |
|---------|-------------|
| `setup` | One-shot environment doctor: checks xcrun, installs idb-companion (brew) + fb-idb (pip), pins protobuf to 3.20.x (required by fb-idb 1.1.x), smoke-tests `idb list-targets`. Run once after first install. Idempotent — re-runs only fix what's broken. |

### Device Management
| Command | Description |
|---------|-------------|
| `devices` | List available simulators (booted/shutdown) |
| `boot <name>` | Boot a simulator (e.g., `boot "iPhone 16 Pro"`) |
| `shutdown` | Shutdown current simulator |

### Build & Run
| Command | Description |
|---------|-------------|
| `build [dir] [scheme]` | Build project (auto-detects xcodeproj/xcworkspace/project.yml) |
| `install [app-path]` | Install app on simulator |
| `launch [bundle-id]` | Launch app |
| `terminate [bundle-id]` | Terminate app |
| `run [dir] [scheme]` | Build + Install + Launch in one command |

### Visual Inspection
| Command | Description |
|---------|-------------|
| `screenshot [path]` | Take PNG screenshot (default: `/tmp/ios-screenshot.png`) |
| `record [path]` | Record video (Ctrl+C to stop) |
| `tree [project-dir]` | Dump accessibility tree as JSON via XCUITest |

### Interaction (foreground — activates Simulator + moves cursor)
| Command | Description |
|---------|-------------|
| `tap <x> <y>` | Tap at device coordinates |
| `tap identifier <id>` | Tap element by accessibility identifier (uses tree data) |
| `tap label <text>` | Tap element by label text |

### Background interaction (no focus steal, cursor restored)
| Command | Description |
|---------|-------------|
| `tap-bg <x> <y>` | Tap without activating Simulator; cursor warps back to original position |
| `tap-bg identifier <id>` | Same, by AX identifier |
| `tap-bg label <text>` | Same, by label text |

**How `tap-bg` works**: iOS UI inside the Simulator is NOT exposed to macOS Accessibility — only the Simulator window's chrome is. So we can't use `AXPress` like we can on macOS apps; the click must be coordinate-based. tap-bg has two paths:

**Path 1 — `idb ui tap` (preferred, zero visual impact)**: idb talks directly to the Simulator's touch-injection service, bypassing HID entirely. The Simulator never raises, your cursor never moves. Requires:
- `brew install idb-companion`
- `pip install fb-idb`
- `pip install 'protobuf>=3.20,<4'` ← **silent gotcha**: fb-idb 1.1.x has generated stubs that crash on older / newer protobuf. Run `ios-ctl setup` to handle this for you.

**Path 2 — HID + cursor warp fallback (when idb unavailable)**: Activates Simulator briefly, posts CGEvent via global HID stream (the touch synthesizer only reads from there), then immediately re-activates your previous app and warps cursor back. Visible side effect: ~100-150ms Simulator flicker.

**Why NOT `CGEvent.postToPid`**: the Simulator touch synthesizer reads events from the GLOBAL HID stream (kCGHIDEventTap) only. `postToPid` delivers to the target's private queue, which the synthesizer never reads — events get silently dropped. We tried this for months, it doesn't work; both `ios-bg-click.swift` and `tap-bg` no longer use it.
| `type <text>` | Type text (element must be focused first via tap) |
| `key <home\|shake>` | Press hardware key |

### Monitoring & Environment
| Command | Description |
|---------|-------------|
| `log [seconds] [bundle-id]` | Stream device logs |
| `health` | Health check (simulator, app, screenshot) |
| `appearance [light\|dark]` | Get/set appearance mode |
| `statusbar` | Override status bar for clean screenshots (9:41, full battery) |
| `location <lat> <lon>` | Set simulated location |
| `permissions <bundle-id> <perm>` | Grant permission (camera, photos, etc.) |
| `push [bundle-id] [title] [body]` | Send simulated push notification |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `IOS_DEVICE` | `booted` | Simulator device specifier (UDID or "booted") |

## Workflow

```bash
P=~/.claude/skills/debug-kit/scripts

# 1. Build and launch
bash $P/ios-ctl.sh run /path/to/project

# 2. Get the accessibility tree (for identifier-based taps)
bash $P/ios-ctl.sh tree /path/to/project

# 3. Interact with the app
bash $P/ios-ctl.sh tap identifier myButton
bash $P/ios-ctl.sh tap identifier textField
bash $P/ios-ctl.sh type "Hello World"

# 4. Take screenshot to verify
bash $P/ios-ctl.sh screenshot /tmp/result.png

# 5. Test dark mode
bash $P/ios-ctl.sh appearance dark
bash $P/ios-ctl.sh screenshot /tmp/dark-mode.png
bash $P/ios-ctl.sh appearance light

# 6. Clean up
bash $P/ios-ctl.sh terminate
```

## How Tap Works

1. If `tap identifier <id>` or `tap label <text>`, look up coordinates from `/tmp/ios-accessibility-tree.json` (generated by `tree` command)
2. Get Simulator window position and content area via AppleScript
3. Map device coordinates → absolute screen coordinates: `screenX = contentX + deviceX * scale`
4. Send `CGEventCreateMouseEvent` (mouseDown + mouseUp) via JXA at the calculated position
5. Simulator converts the mouse click into a touch event

## How Tree Works

1. Runs a XCUITest (`testDumpAccessibilityTree`) that queries all UI elements by type
2. Collects: type, identifier, label, value, frame (x, y, w, h), enabled, hittable
3. Outputs flat JSON array to `/tmp/ios-accessibility-tree.json`
4. Supported types: button, staticText, textField, secureTextField, image, toggle, slider, link, cell, navigationBar, tabBar, alert, scrollView, table

### Requirements for Tree Command

The iOS project needs a `TestAppUITests` target with the `AccessibilityDump.swift` test file. The test project template at `test-workspace/ios-app/Tests/AccessibilityDump.swift` provides this.

For existing projects, copy the `Tests/AccessibilityDump.swift` file and add a UI testing target that depends on the main app target.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| No booted simulator | Run `devices` to see available, then `boot "iPhone 16 Pro"` |
| Build fails: no code signing | Set `CODE_SIGNING_ALLOWED=NO` in project settings |
| Tap not hitting target | Re-run `tree` to refresh coordinates (they change if UI updates) |
| Tap hits wrong spot | Check Simulator window isn't resized; coordinates assume 1:1 scale |
| Tree command fails | Ensure scheme includes UITests target in its test action |
| Type not working | Must `tap` a text field first to focus it |
| Permission denied (Accessibility) | Grant Terminal/IDE accessibility permission in System Settings > Privacy |

## Interaction fidelity (verified)

iOS apps inside the Simulator are driven via XCUITest + `simctl`/`idb`; macOS AX does NOT see
inside the Simulator (only its window chrome).
- **Collection:** `tree` (XCUITest accessibility dump) and `simctl io booted screenshot`. *Verified: tree = 18 elements, screenshot ok on iPhone 16e.*
- **T1 semantic (default):** target by accessibility **identifier / label** via XCUITest.
- **T2 synthetic:** `tap <x> <y>` / `swipe` via `simctl io` / `idb` at coordinates — no real cursor. *Verified: tap dispatched.*
- **T3 real-user (`tap-bg`):** HID tap + cursor-warp-back / tap indicator, for true end-user simulation without leaving the cursor moved. Use when realism matters; otherwise stay on T1/T2.
