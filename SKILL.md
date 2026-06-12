---
name: debug-kit
description: >
  Cross-platform app debug and testing skill for Claude Code.
  Build, launch, screenshot, tap, type, inspect, and monitor applications
  across 9 platforms: Electron, iOS, macOS, Web, Flutter, React Native, Android, Tauri, Chrome Extension.
  Auto-detects project type from package.json, pubspec.yaml, xcodeproj, build.gradle, src-tauri/, manifest.json (MV3).
  TRIGGER when: user says "run the app", "test the app", "take screenshot", "tap button",
  "debug", "launch", "check if it works", "hot reload", "monitor console", "check logs",
  or is working on ANY app project and wants to build, run, test, or verify changes.
  Also trigger when the user asks to interact with a running app, inspect UI elements,
  check performance, run accessibility audits, or simulate user input.
license: MIT
metadata:
  author: daxiongya
  version: "1.2.0"
  type: utility
  mode: assistive
---

# Debug Kit

Cross-platform app debug toolkit. One skill to build, launch, interact with, and inspect apps across 9 platforms.

## Step 1: Determine Platform

Use `pilot.sh detect` or check project files manually:

| Marker File | Platform | Reference | macOS perms† |
|-------------|----------|-----------|:-:|
| `pubspec.yaml` | **Flutter** | `references/flutter.md` | only for macOS target |
| `package.json` + `react-native` dep | **React Native** | `references/react-native.md` | — |
| `package.json` + `electron` dep | **Electron** | `references/electron.md` | — |
| `package.json` (other) or `*.html` | **Web** | `references/web.md` | — |
| `*.xcodeproj` / `project.yml` (iOS) | **iOS** | `references/ios.md` | — |
| `*.xcodeproj` / `project.yml` (macOS) | **macOS** | `references/macos.md` | **required** |
| `build.gradle` / `settings.gradle` | **Android** | `references/android.md` | — |
| `src-tauri/tauri.conf.json` / `src-tauri/Cargo.toml` | **Tauri** | `references/tauri.md` | **required** |
| `manifest.json` (manifest_version: 3) + `wxt.config.*` | **Chrome Extension** | `references/chrome-extension.md` | — |

† **macOS perms** = Accessibility + Screen Recording on the terminal hosting Claude Code. Only the platforms that drive *native macOS windows* through `mac-ctl.sh` need these (macOS, Tauri, Flutter when targeting macOS). Every other platform reads pixels through its own protocol (CDP / simctl / adb) and needs nothing extra. See `references/macos.md` §Permissions for the setup steps and the "silent wallpaper redaction" gotcha when permission is missing.

**After identifying the platform, read the corresponding `references/<platform>.md` for full command documentation.**

## Step 2: Use the Right Script

```bash
P=~/.claude/skills/debug-kit/scripts

# Electron (CDP protocol)
CDP_PORT=9222 node $P/cdp-client.mjs <command>

# iOS (xcrun simctl + CGEvent)
bash $P/ios-ctl.sh <command>

# macOS (Accessibility API + CGEventPostToPid, background by default + virtual pointer)
MAC_APP=AppName bash $P/mac-ctl.sh <command>

# Web (CDP via Chrome)
bash $P/web-ctl.sh <command>

# Flutter (delegates to ios/web/macos)
bash $P/flutter-ctl.sh <command>

# React Native (delegates to ios)
bash $P/rn-ctl.sh <command>

# Android (adb + uiautomator)
bash $P/android-ctl.sh <command>

# Chrome Extension (web-ext + CDP)
# See references/chrome-extension.md

# Tauri (delegates to mac-ctl.sh — AX API reads DOM through WKWebView)
bash $P/tauri-ctl.sh <command>
```

Or use the unified router: `bash $P/pilot.sh <platform> <command>` / `bash $P/pilot.sh auto <command>`

## Universal Capabilities

Every platform supports these core operations (read platform reference for exact command names):

| Capability | Description |
|-----------|-------------|
| **Run** | Build and launch the app |
| **Stop** | Stop the running app |
| **Screenshot** | Capture current state as PNG |
| **Tap / Click** | Simulate touch/click at coordinates or by element identifier |
| **Drag / Scroll** | Drag between points, scroll the view (macOS: background, with virtual pointer) |
| **Type** | Input text into focused element |
| **Health** | Check environment, dependencies, running state |
| **Logs** | Stream or read app output |
| **Test** | Run platform test suite (Jest / XCTest / flutter test / etc.) |

## Interaction Fidelity — never move the user's real cursor

**This is the core policy. (1) Collection is always native/semantic. (2) Every
mouse-controlling action is delivered in the BACKGROUND and represented by the *virtual
pointer* — the real system cursor is NEVER moved and focus is never stolen. (3) Moving the
real cursor (HID) is a manual-only escape hatch, never automatic.**

**Collection / inspection (screenshots, UI state, a11y, perf, logs): ALWAYS native/semantic.**
The virtual pointer plays no role here. Use the AX tree / XCUITest, CDP DOM/eval, uiautomator
dump, the Dart VM Service, and native window-targeted screenshots (`screencapture -l`,
`simctl io`, `adb screencap`, CDP screenshot). These are structured, deterministic, and don't
disturb the app.

**Interaction tiers — both are BACKGROUND (real cursor never moves); use the higher one when a handle exists:**

| Tier | How | Traits | When |
|------|-----|--------|------|
| **T1 semantic** | AXPress / set-value+AXConfirm (macOS/iOS); CDP `click`/`eval` (Web/Electron/Tauri-webview); uiautomator / `input` by node (Android); VM Service / `flutter_driver` (Flutter) | no real cursor, deterministic, fastest, CI-friendly | **default** |
| **T2 synthetic** | `CGEventPostToPid` (macOS), `simctl io` (iOS), `adb input` (Android) at coordinates — **no real cursor moved**, virtual pointer glides to show it | background; for canvases / games / custom-drawn UI with no semantic handle | **auto-fallback** when no element handle |

**Any mouse-controlling action shows the virtual pointer** (it glides to the target and
pulses) — that is how the "mouse" is represented, *without ever touching the user's real
cursor*. The virtual pointer is a visualization layer over T1/T2; toggle off only for
headless/CI (`MAC_POINTER=off`).

**Escape hatch — real HID (moves your real cursor): `MAC_INPUT=hid`, manual opt-in only.**
Never selected automatically. Use it solely for the rare app that ignores background events
(e.g. some games, or a Flutter *desktop* canvas) — and know it WILL move your real cursor and
activate the app. For Flutter prefer the Dart VM Service / a `flutter_driver` build instead;
on a mobile target, `simctl`/`adb` device input reaches Flutter without touching your cursor.

**Unified knob:** `DK_FIDELITY=semantic|synthetic|real` (default `semantic`) — all values stay
in background mode and never touch the real cursor; it expresses intent (semantic vs
coordinate) and **does not** enable HID. Moving the real cursor remains a deliberate,
explicit `MAC_INPUT=hid` only.

### Virtual pointer — global coverage (per-platform mechanism)

Every platform shows a *virtual pointer* (where the AI is interacting) without moving the
user's real cursor. Toggle off everywhere with `DK_POINTER=off`. Mechanism per platform:

| Platform | Virtual-pointer mechanism |
|----------|---------------------------|
| macOS | `mac-overlay` software cursor — a resident, click-through screen overlay that glides between points (`dk-pointer.sh` / `mac-ctl`). |
| Tauri | same `mac-overlay` (via `mac-ctl`, window coords are screen coords). |
| Web / Electron / Chrome-extension | `mac-overlay`, fed by `cdp-client.mjs`: maps CSS click coords → screen points (`window.screenX/Y` + top-chrome offset). |
| Flutter (desktop) | `mac-overlay` (via `mac-ctl`); (mobile target → uses iOS/Android mechanism). |
| iOS | `ios-tap-indicator.swift` — screen overlay drawn over the Simulator window at the tap site. |
| React Native | via iOS (`ios-ctl` → `ios-tap-indicator`). |
| Android | the device's **native touch feedback** (`settings put system show_touches 1`) — drawn on the device, precise, no mapping. |

Shared service: `dk-pointer.sh` (ensure/feed/stop the resident software cursor by screen
coordinates) backs the macOS-family overlays; iOS and Android use their platform-native
indicators.

## Per-platform testing recipes (best scheme)

Collection is always native/semantic; interaction stays background (see fidelity policy).

| Platform | Recommended flow (collect → interact → verify) |
|----------|------------------------------------------------|
| **macOS** | `run` → `tree`/`read` (AX) → `tap label`(AXPress)/`type`(AX+AXConfirm)/`drag`/`scroll` → `read` + `screenshot` |
| **iOS** | `run` → `tree` (XCUITest) → `tap identifier`/`tap`/`type` (simctl io) → `screenshot` |
| **Android** | `run`/`launch` → `tree` (uiautomator) → `tap`/`swipe`/`type` (adb input) → `screenshot` |
| **Web** | `launch <url>` → `dom`/`eval`/`a11y` → `click "sel"`/`type "sel" "txt"` → `screenshot`/`eval` |
| **Electron** | `launch dev` → `health`/`eval`/`dom` → `click`/`type`/`key` → `screenshot` |
| **Flutter** | `run` → `vm widgets` (semantic tree) → **mobile target** `tap` (HID reaches canvas) or `vm call` → `vm widgets`/`screenshot` |
| **React Native** | `run` (auto-picks free Metro port) → `tree`/`tap`/`type` (via iOS) → `screenshot` |
| **Tauri** | `dev` → `tree`/`read` (AX through WKWebView) → `tap-bg label`(AXPress)/`type-bg` → `screenshot` |
| **Chrome Extension** | open the extension page → CDP via `web-ctl` (`dom`/`eval`/`click`/`screenshot`); auto-detected from `manifest.json` (MV3)/`wxt.config.*` |

## Composition

Scripts share infrastructure and delegate across platforms:

```
Electron  ─── cdp-client.mjs (zero-dep WebSocket + CDP) ──→ dk-pointer.sh (screen cursor)
Web       ─── web-ctl.sh ──── cdp-client.mjs (reuses same CDP) ──→ dk-pointer.sh
iOS       ─── ios-ctl.sh (simctl + JXA CGEvent) ──→ ios-tap-indicator.swift
macOS     ─── mac-ctl.sh ──┬── mac-input.js (background: CGEventPostToPid + AX actions)
                           └── mac-overlay  (virtual pointer overlay, Swift)
Flutter   ─── flutter-ctl.sh ──┬── ios-ctl.sh (iOS target) · flutter-vm.mjs (VM Service)
                               ├── cdp-client.mjs (Web target)
                               └── mac-ctl.sh (macOS target)
React Native ─ rn-ctl.sh ──── ios-ctl.sh (iOS interaction)
Android   ─── android-ctl.sh (adb + uiautomator; native show_touches pointer)
Tauri     ─── tauri-ctl.sh ──── mac-ctl.sh (AX API reads DOM through WKWebView)
Chrome Ext ── (pilot → web-ctl) ── cdp-client.mjs (CDP against extension pages)

dk-pointer.sh ── shared software-cursor service (mac-overlay) used by the macOS-family
                 platforms; iOS/Android use platform-native touch indicators.
```
