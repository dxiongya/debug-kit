# Tauri Debug Reference

**Script**: `bash ~/.claude/skills/debug-kit/scripts/tauri-ctl.sh <command>`
**Tools**: Tauri CLI, cargo, `mac-ctl.sh` (Accessibility API + CGEvent)
**Env**: `TAURI_APP` (override productName; normally auto-detected from `tauri.conf.json`)

## Key Insight: No CDP, No WebDriver

Tauri 2.x on macOS uses **WKWebView** embedded in an `NSWindow`. Unlike Electron (which exposes a Chrome DevTools Protocol port), Tauri does **not** open any remote debugging interface.

The win: macOS Accessibility API **reads the DOM through WKWebView as native roles**. All web elements — buttons, links, text fields, static text, images — appear in the AX tree with their ARIA labels and visible text. This means `mac-ctl.sh` (which already speaks AX + CGEvent) can inspect and drive Tauri apps without any extra runtime, no tauri-driver, no WebDriver.

```
Tauri process ──┬── Rust runtime (native layer)
                └── WKWebView ──── DOM ──── macOS Accessibility API ──── mac-ctl.sh
```

## Commands

| Category | Command | Description |
|----------|---------|-------------|
| **Lifecycle** | `dev [dir]` | `pnpm tauri dev`, waits up to 300s for native window |
| | `build [dir]` | `pnpm tauri build` (release bundle) |
| | `stop` | Kill dev binary + vite + tauri CLI |
| **Inspection** | `tree` | Full accessibility tree (delegates to mac-ctl.sh) |
| | `read <query>` | Read specific element by text/role |
| | `screenshot [path]` | Window screenshot |
| **Interaction** | `tap <x> <y>` | CGEvent click at screen coords (steals focus + moves cursor) |
| | `type "<text>"` | Type into focused input |
| | `key <keyname>` | Send key event |
| **Background** | `tap-bg <x><y>` / `tap-bg id <axId>` / `tap-bg label <text>` | AXPress through WKWebView's AX bridge — **0 mouse impact**, no focus steal. Same selectors as `mac-ctl tap-bg`. |
| | `type-bg <text> [id\|label\|desc <selector>]` | Set field value via AX — no focus needed. |

### Background interaction is fully supported

Because Tauri's WKWebView bridges DOM elements (with their ARIA labels and visible text) into macOS's AX tree, `tap-bg` works identically to native macOS apps:

```bash
tauri-ctl tap-bg label "Greet"        # press <button>Greet</button> via AXPress
tauri-ctl tap-bg id submit-button     # press by ARIA aria-label or React id
tauri-ctl type-bg "hello" id name-field
```

⚠️ Caveat for React-controlled inputs: setting `kAXValueAttribute` updates the AX layer immediately but may not trigger React's `onChange` — so React state won't update. For React inputs that read from `useState`, prefer typing via key events (which do require Simulator focus). For uncontrolled inputs and non-React stacks (Solid, Vue, Svelte without `v-model` quirks), `type-bg` works as expected.
| | `window ...` | Move/resize/front |
| **Logs & Health** | `log [lines]` | Tail tauri dev log |
| | `health` | Check cargo/pnpm/rustc + tracked state |

## How Detection Works

`pilot.sh` auto-detects a Tauri project by looking for either:
- `src-tauri/tauri.conf.json`, or
- `src-tauri/Cargo.toml`, or
- `@tauri-apps/api` / `@tauri-apps/cli` in `package.json`

The running window's process name comes from `productName` in `tauri.conf.json`. `tauri-ctl.sh` reads it with `jq` (after stripping `//` comments that Tauri allows in its JSON).

## Workflow

```bash
P=~/.claude/skills/debug-kit/scripts

# 1. Start dev mode (blocks until the native window is visible)
bash $P/tauri-ctl.sh dev /path/to/tauri/project

# 2. Dump the accessibility tree — you'll see the DOM as AX roles
bash $P/tauri-ctl.sh tree

# Example output (from a default Tauri + React scaffold):
#   [Link] "Vite logo" @ (647,300 144x151)
#   [Link] "Tauri logo" @ (791,300 134x151)
#   [TextField] "-" @ (677,506 287x42)
#   [Button] "Greet" @ (968,506 83x42)

# 3. Interact: click into the text field, type, then click Greet
bash $P/tauri-ctl.sh tap 720 527
bash $P/tauri-ctl.sh type "Claude"
bash $P/tauri-ctl.sh tap 1009 527

# 4. Verify the new DOM state
bash $P/tauri-ctl.sh tree          # TextField value should now be "Claude"

# 5. Visual evidence
bash $P/tauri-ctl.sh screenshot /tmp/tauri-after.png

# 6. Inspect logs if something failed
bash $P/tauri-ctl.sh log 50

# 7. Stop
bash $P/tauri-ctl.sh stop
```

## Alignment with team-flow Evidence Requirements

For `DEVING → DEV DONE` transitions on a Tauri project, the following evidence forms are natural:

```
验收标准 1: "Greet 按钮点击后显示问候语"
  $ bash tauri-ctl.sh tap 720 527
  $ bash tauri-ctl.sh type "Claude"
  $ bash tauri-ctl.sh tap 1009 527
  $ bash tauri-ctl.sh tree | grep "Hello"
    [StaticText] "Hello, Claude! ..."
  → 通过 ✓

验收标准 2: "release 构建成功"
  $ bash tauri-ctl.sh build
  → 通过 ✓
  Bundle: src-tauri/target/release/bundle/macos/tauri-app.app
```

## State & Logs

| File | Purpose |
|------|---------|
| `/tmp/.tauri-debug-state.json` | Tracked `{pid, name, dir}` after `dev` |
| `/tmp/tauri-debug.log` | Full stdout of `pnpm tauri dev` |

## Requirements

| Tool | Why |
|------|-----|
| `cargo` / `rustc` | Tauri's Rust backend |
| `pnpm` | Frontend tooling (script assumes pnpm; adapt for npm/yarn) |
| `jq` | JSON parsing |
| `swift` CLI | Used by `find-window-id.swift` for `screencapture -l <winID>` (ships with Xcode Command Line Tools; Tauri already depends on these) |
| **macOS Accessibility permission** | For AX tree + CGEvent. System Settings → Privacy & Security → Accessibility → add your terminal (Terminal / iTerm) |
| **macOS Screen Recording permission** | For `screenshot`. System Settings → Privacy & Security → Screen Recording → add your terminal. Then **fully quit & relaunch the terminal** (macOS requires this). See `references/macos.md` §Permissions for the shared rationale — this is the same requirement as any other `mac-ctl.sh`-based platform. |

## Limitations

1. **DOM properties not exposed by AX are invisible.** If you need CSS values, computed styles, network state, or JS console evaluation, AX won't help. Enable `devtools` in `tauri.conf.json` and connect Safari Web Inspector manually (not automatable from this skill).
2. **Tap is coordinate-based.** Unlike Electron/Web via CDP, you can't click by CSS selector. Use `tree` to get coordinates first, then `tap`.
3. **Retina/HiDPI**: `mac-ctl.sh screenshot` automatically handles 2x scaling. Tap coordinates are in logical points, not physical pixels.
4. **Windows/Linux not covered.** This script is macOS-only. On Linux the equivalent would use `at-spi2` + `xdotool`; on Windows UIA + WebView2 DevTools. Stubs welcome.
5. **Screenshot requires Screen Recording permission, no workaround.** `mac-ctl.sh screenshot` calls `screencapture -l <CGWindowID>` (window-targeted, Space-agnostic, robust). Without Screen Recording permission macOS silently redacts other apps' window content to wallpaper pixels — this is a macOS privacy guarantee that *no external tool can bypass*. `debug-kit` deliberately does not inject a Rust snapshot command into the target Tauri app (would break the zero-config promise for external debugging). `tree`, `tap`, `type`, `read` use the Accessibility API and are unaffected.

## Comparison to Other WebView-Based Platforms

| Platform | Debug Protocol | DOM via AX? | Tool |
|----------|---------------|-------------|------|
| Electron | CDP (remote debugging port) | n/a — use CDP | `cdp-client.mjs` |
| Web (Chrome) | CDP | n/a — use CDP | `cdp-client.mjs` + `web-ctl.sh` |
| Tauri | **None** | ✅ **Yes** | `tauri-ctl.sh` → `mac-ctl.sh` |
| Flutter (macos target) | Dart VM Service | partial | `flutter-ctl.sh` |
| React Native (iOS) | Metro + native bridge | via iOS AX | `rn-ctl.sh` → `ios-ctl.sh` |

## Interaction fidelity (verified)

Tauri bridges its WebView DOM into the macOS AX tree, so it is driven through `mac-ctl`.
- **Collection:** `tree` / `read` (AX through WKWebView). *Verified: Greet button + input visible.*
- **T1 semantic (default):** `tap-bg label <text>` → AXPress on the DOM element (matches ARIA/visible text). *Verified end-to-end: pressing "Greet" invoked the Rust command and updated the React UI, fully background (no focus steal).*
- **T2 synthetic:** `tap <x> <y>` → `CGEventPostToPid` coordinates (canvas / unlabeled).
- **T3 real HID:** `MAC_INPUT=hid` when synthetic events are ignored.
- **Caveats (verified):** (1) a DOM `id` is **not** exposed as AXIdentifier in WKWebView — match by visible text/ARIA label, not `tap-bg id <domId>`. (2) Setting a web `<input>` value via AX+AXConfirm does **not** reach a React **controlled** input; for those, type via real keys (T3) or the webview devtools/CDP.
