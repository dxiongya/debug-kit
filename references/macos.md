# macOS Debug Reference

For native UI feature validation, read [macos-validation.md](macos-validation.md) first. It adds test/data isolation, deterministic window opening, reliable selectors, popover checks, and safe local installation to this command reference.

**Tool routing**: Use the current host's prescribed UI tool when available. In Codex with `cua_repl`, read its returned documentation and perform live UI interactions there; do not run the bundled UI scripts as an alternative permission or targeting workaround. Builds and XCTest remain CLI operations. The background/virtual-pointer behavior documented below applies to the bundled backend, not automatically to external tools.

**Script**: `MAC_APP=AppName bash "$DEBUG_KIT_ROOT/scripts/mac-ctl.sh" <command>` (resolve `DEBUG_KIT_ROOT` from the skill catalog).
**Tools**: Accessibility API (System Events), `CGEventPostToPid`, AppleScript, `mac-input.js` (background backend), `mac-overlay.swift` (virtual pointer)
**Env**: `MAC_APP` (required — must match process name in Activity Monitor), `MAC_INPUT` (bg|hid), `MAC_POINTER` (on|off)

## Background interaction + virtual pointer (default)

The helper caches app paths in shared `/tmp` files and targets apps by name. It prefers Xcode build settings to locate the product, with a DerivedData search fallback. When production and QA copies coexist, use an explicit build directory and verified app path/bundle identity rather than trusting cached names or fallback discovery. Its `terminate` fallback uses name-based process matching; stop only an exact, freshly verified task-owned PID instead in multi-instance sessions. Refresh the tree after each state change before any cached coordinate lookup.

By default (`MAC_INPUT=bg`), all interaction is delivered **in the background**: clicks,
drags, scrolls and keystrokes are posted straight to the target app via
`CGEventPostToPid`, and element presses / text entry go through the Accessibility API
(`AXPress`, set value). This means **your real mouse cursor never moves and focus is
never stolen** — you can keep working while a test drives the app underneath.

So you can still *watch* what the test is doing, a **persistent virtual pointer**
(`mac-overlay.swift`, compiled+cached to `/tmp/.debug-kit-overlay`) stays resident for the
session and **glides one cursor between action points** with a soft click pulse. It's a
borderless, click-through window — draws on top but blocks nothing, needs no permission,
and auto-exits after ~45s idle. Manage it with `pointer start|stop|status`; it also
auto-starts on first interaction. Disable entirely with `MAC_POINTER=off`.

The cursor glyph is the **official Codex/Operator "software cursor"** — rendered from the
vendored asset `scripts/assets/software-cursor.png` (extracted by the open-computer-use
project; see `scripts/assets/NOTICE.md`). If that asset is absent, the daemon falls back to
a procedural rounded-triangle pointer. To use your own glyph, replace that PNG (252×252,
transparent, glow baked in) — the daemon picks it up on next start.

Its **motion** is ported from open-computer-use's `CursorMotion` model: the cursor is
spring-driven (so it accelerates, glides and settles naturally rather than easing linearly),
tilts subtly toward travel direction (capped ~0.28 rad), compresses slightly with velocity,
and drifts gently when idle, with a soft click pulse on arrival.

The interaction verbs mirror OpenAI's computer-use action model (click, double_click via
`clicks`, drag, scroll, move, type, keypress) with top-left pixel coordinates.

Set `MAC_INPUT=hid` to fall back to the **legacy** behavior (CGEvent at the HID tap +
app activation), which *does* move the real cursor and bring the app forward. Use it
only for apps that ignore posted/AX events (rare).

## Key Advantage Over iOS/Electron

macOS apps expose their full UI tree via the **Accessibility API** (System Events). This means:
- **`read`**: Instantly see all text, values, checkbox states, slider positions — no screenshots needed
- **`tree`**: Full element dump with types, positions, sizes — JSON format
- **`tap label "Show Alert"`**: Click by element name — no coordinate math
- **`menu "File > New Window"`**: Directly invoke menu items

This makes macOS the most AI-friendly platform to test — the AI can "see" the app state programmatically.

## Commands

### Build & Run
| Command | Description |
|---------|-------------|
| `build [dir] [scheme]` | Build project (auto-detects xcodeproj/xcworkspace/project.yml/Package.swift) |
| `launch [app-path]` | Launch built app |
| `terminate [app-name]` | Quit app |
| `run [dir] [scheme]` | Build + Launch |

### Inspection (Accessibility API — no Screen Recording needed)
| Command | Description |
|---------|-------------|
| `tree` | Dump full accessibility tree as JSON (buttons, text fields, sliders, etc.) |
| `read` | Read current UI state — shows all text values, checkbox states, slider positions |
| `health` | Process info (PID, memory) + window count + UI state |

### Interaction (background by default — no cursor movement, no focus steal)
| Command | Description |
|---------|-------------|
| `tap <x> <y>` | Click at absolute screen coordinates (`CGEventPostToPid`) |
| `tap label <text>` | Click element by name/label (`AXPress`) |
| `tap desc <description>` | Click element by accessibility description (`AXPress`) |
| `drag <fx> <fy> <tx> <ty>` | Smooth 20-step drag between two points |
| `scroll <dy> [dx] [x] [y]` | Scroll wheel — `dy<0` scrolls down |
| `page_scroll <up\|down> [n]` | Page up/down `n` times (PageUp/PageDown keys) |
| `type <text>` | Type into the focused field (AX set value; full Unicode) |
| `key <keyspec>` | Send key: `return`, `tab`, `escape`, `cmd+s`, `cmd+q`, `shift+tab` |
| `menu` | List all available menus and items |
| `menu "Menu > Item"` | Click a specific menu item |

### Window Management
| Command | Description |
|---------|-------------|
| `window info` | Show window positions and sizes |
| `window move <x> <y>` | Move window |
| `window resize <w> <h>` | Resize window |
| `window focus` | Bring app to front |

### Other
| Command | Description |
|---------|-------------|
| `screenshot [path]` | Capture window (requires Screen Recording permission) |
| `log [seconds]` | Stream console logs |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MAC_APP` | Auto-detected from build | App name (must match process name in Activity Monitor) |
| `MAC_INPUT` | `bg` | `bg` = background (no cursor/focus disruption); `hid` = legacy (moves real cursor, activates app) |
| `MAC_POINTER` | `on` | `on` = draw the virtual pointer overlay where each background action lands; `off` = no overlay |
| `DK_FIDELITY` | `semantic` | Cross-platform intent tier — all values stay background (real cursor never moved); does NOT enable HID |

## Workflow

Bundled-backend example, when the host allows it and the app is an isolated test instance. Resolve `DEBUG_KIT_ROOT` as described in `SKILL.md`.

```bash
DEBUG_KIT_SCRIPTS="$DEBUG_KIT_ROOT/scripts"

# 1. Build and launch
MAC_APP=MyApp bash "$DEBUG_KIT_SCRIPTS/mac-ctl.sh" run /path/to/project

# 2. Read current UI state
MAC_APP=MyApp bash "$DEBUG_KIT_SCRIPTS/mac-ctl.sh" read

# 3. Interact — all background; your cursor/focus are never disturbed,
#    and a virtual pointer shows where each action lands.
MAC_APP=MyApp bash "$DEBUG_KIT_SCRIPTS/mac-ctl.sh" tree
MAC_APP=MyApp bash "$DEBUG_KIT_SCRIPTS/mac-ctl.sh" tap label "New item"
MAC_APP=MyApp bash "$DEBUG_KIT_SCRIPTS/mac-ctl.sh" tree
MAC_APP=MyApp bash "$DEBUG_KIT_SCRIPTS/mac-ctl.sh" tap label "Name"
MAC_APP=MyApp bash "$DEBUG_KIT_SCRIPTS/mac-ctl.sh" type "Disposable test item"
MAC_APP=MyApp bash "$DEBUG_KIT_SCRIPTS/mac-ctl.sh" key return
MAC_APP=MyApp bash "$DEBUG_KIT_SCRIPTS/mac-ctl.sh" read
MAC_APP=MyApp bash "$DEBUG_KIT_SCRIPTS/mac-ctl.sh" scroll -5 # scroll the view down
# For drag, first inspect the current tree/screenshot and use observed coordinates.

# Turn off the overlay only for headless/CI. Real HID requires explicit user opt-in.
# MAC_POINTER=off MAC_APP=MyApp bash "$DEBUG_KIT_SCRIPTS/mac-ctl.sh" tap label "New item"

# 4. Verify state changed
MAC_APP=MyApp bash "$DEBUG_KIT_SCRIPTS/mac-ctl.sh" read

# 5. Test menu
MAC_APP=MyApp bash "$DEBUG_KIT_SCRIPTS/mac-ctl.sh" menu "File > New Window"

# 6. Stop only the exact test instance after verifying its PID/path.
```

## How `read` Works

Uses JXA (JavaScript for Automation) to traverse the Accessibility tree via `System Events`:
- Queries `AXStaticText` for visible text and labels
- Queries `AXTextField` for input values
- Queries `AXCheckBox` for toggle states (0/1)
- Queries `AXSlider` for slider values (0.0-1.0)
- No screenshots, no screen recording, no external tools

## How `tap` Works

**Background mode (default):**
- `tap label/desc <text>` finds the element in the Accessibility tree and performs its
  `AXPress` action directly — no coordinates, no cursor, works even when the app is not
  frontmost. It prints the element's center so the virtual pointer can be drawn there.
- `tap <x> <y>` posts mouseDown+mouseUp to the app's PID via `CGEventPostToPid`. The
  visible cursor does not move; the app receives the click at those coordinates.

**HID mode (`MAC_INPUT=hid`):** looks up the element's coordinates from the tree, then
sends the click at the HID event tap (`CGEventPost(kCGHIDEventTap, …)`) after activating
the app — this moves the real cursor, like the original behavior.

## How background typing works

`type` finds the focused text element (or the first text field), **sets its AX value, then
performs the `AXConfirm` action** — the confirm is what makes SwiftUI/AppKit `@State`
bindings actually update (they refresh on commit, not on a programmatic value write). This
enters full Unicode text fully in the background: no app activation, no focus steal, no
per-key events. If no text element is found it falls back to posting key events to the PID.
`key` always posts real key-down/up events (with `cmd`/`ctrl`/`alt`/`shift` flags) via
`CGEventPostToPid`.

## Architecture

```
mac-ctl.sh ──┬── mac-input.js   (JXA: CGEventPostToPid + AX actions — the background backend)
             └── mac-overlay     (Swift daemon: resident click-through virtual pointer that
                                  glides between targets; reads /tmp/.debug-kit-ptr-cmds; compiled to /tmp)
```

## Permissions

Inspect existing access first. Do not grant Accessibility/Screen Recording, reset TCC, or weaken signing/security settings to make a test pass without the necessary user authorization. If blocked, report which checks could not run and use permitted read-only/model checks. The setup instructions below are for user-approved permission changes, not automatic remediation.

| Feature | Permission | How to Grant |
|---------|-----------|--------------|
| `tree`, `read`, `tap`, `type`, `key`, `drag`, `scroll`, `menu` | **Accessibility** | System Settings → Privacy & Security → Accessibility |
| `screenshot` | **Screen Recording** | System Settings → Privacy & Security → Screen Recording |
| virtual pointer overlay | none | — (drawing only) |

Grant permissions to **the terminal that hosts Claude Code** — Terminal.app, iTerm2, or whichever shell you run `claude` in. All interaction (including background `CGEventPostToPid` posting and AX actions) needs Accessibility; `screenshot` additionally needs Screen Recording. The virtual pointer overlay needs no permission.

> Note: macOS sandboxing can block Accessibility-tree reads (the process hangs on `System Events` queries). If `tree`/`read`/`tap label` hang but coordinate clicks work, the host process lacks AX access — grant Accessibility and fully relaunch the terminal.

**After toggling a permission, you MUST fully quit (`⌘Q`) and relaunch the terminal.** macOS does not apply permission changes to already-running processes; restarting the Claude Code session alone is not enough.

Quick path to the Screen Recording pane:
```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
```

### The silent-redaction trap

On macOS Sonoma+, when Screen Recording permission is **denied**, `screencapture` does **not error**. Instead:

- `screencapture -x` (full-screen) succeeds, but your own app's windows are rendered normally while **other apps' window contents are replaced with desktop wallpaper pixels** — a privacy guarantee.
- `screencapture -l <windowID>` fails with `could not create image from window`.

The first behavior is especially nasty: a screenshot "succeeds" but shows wallpaper instead of your target app. `mac-ctl.sh screenshot` now uses `screencapture -l <winID>` as the primary path (via `find-window-id.swift`) so the failure mode is a clear error rather than a silent wallpaper image. If you see the "screencapture -l failed" warning, it's almost always this permission issue.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "No app name" | Set `MAC_APP=AppName` or run `build` first |
| Tap not working | Check exact target, fresh tree, focus, and existing Accessibility access; ask the user if access is missing |
| App ignores background clicks/keys | Inspect the failure first; `MAC_INPUT=hid` requires explicit user opt-in, not an automatic retry |
| No virtual pointer appears | Need `swiftc` (Xcode CLT) to build the overlay; or `MAC_POINTER=off` is set |
| `tree`/`tap label` hang but coords work | Check sandbox/Accessibility access; request necessary user action rather than bypassing the blocked path |
| `read` shows nothing | App may not support Accessibility; try `tree` for raw dump |
| Screenshot blank | Check existing Screen Recording access; use permitted AX inspection or ask the user for missing access |
| Menu click fails | Ensure exact menu item name; use `menu` without args to list items |
| Build fails | Run `xcodegen generate` first if using project.yml |

## Interaction fidelity (verified)

- **Collection:** AX tree / `read` (semantic) and `screencapture -l <wid>` window-targeted — always preferred.
- **T1 semantic (default):** `tap label/desc` → AXPress; `type` → AX set-value **+ AXConfirm** (commits SwiftUI/AppKit `@State`). No cursor, deterministic. *Verified on MacTestApp (SwiftUI).*
- **T2 synthetic:** `tap <x> <y>` / `drag` / `scroll` → `CGEventPostToPid` (no real cursor). For canvas/custom-drawn UI. *Verified.*
- **T3 real HID (on request):** `MAC_INPUT=hid` → real cursor + app activation, for true end-user simulation.
- **Virtual pointer** (`MAC_POINTER=on|off`) is a visualization layer over any tier — not the actuator except at T3.
