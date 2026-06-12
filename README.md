# debug-kit

> An AI‑agent toolkit that **drives, inspects, and tests real apps across 9 platforms** — entirely in the background, **without ever moving your real mouse or stealing focus**, with a virtual cursor you can watch.

**debug-kit** gives an AI agent — like [Claude Code](https://claude.com/claude-code) — *hands and eyes* on real applications across **macOS, iOS, Android, Web, Electron, Flutter, React Native, Tauri, and Chrome Extensions**. Build, launch, screenshot, read the UI tree, tap, type, drag, scroll, inspect, and stream logs — through **one unified interface** that auto‑detects the project type.

Its defining principle: **never hijack the human's machine.** Every interaction is delivered in the background (Accessibility actions, `CGEventPostToPid`, CDP, `simctl`/`adb`, the Dart VM Service), so your real cursor never moves and focus is never stolen — while a **resident "software cursor" glides to each action**, so you can *see* exactly where the AI is working.

## Why it's different

- 🖱️ **Background by default — your cursor is sacred.** Clicks/keys/scrolls go straight to the target app; the system pointer stays exactly where you left it, focus never jumps. Real HID (which moves the cursor) is a manual, opt‑in escape hatch only.
- 👻 **A virtual pointer on every platform.** A gliding, click‑through software cursor (Codex/Operator‑style) shows where the AI taps — screen overlay on macOS/Tauri/Web/Electron, sim overlay on iOS, native touch feedback on Android.
- 🧠 **Semantic‑first, not pixel‑guessing.** Reads structured UI via the Accessibility tree (macOS/iOS), CDP DOM (Web/Electron), uiautomator (Android), and the Flutter VM Service — then acts by element, not coordinates, when possible.
- 🧩 **One router, nine platforms.** `pilot.sh auto <command>` detects the project (`package.json`, `pubspec.yaml`, `*.xcodeproj`, `build.gradle`, `src-tauri/`, `manifest.json` MV3…) and dispatches to the right controller.
- ⚡ **Zero heavyweight deps.** Plain bash + Node built‑ins + a little Swift/JXA. No Selenium, no Playwright runtime.

## Supported platforms

| Platform | Driven via | Virtual pointer |
|----------|-----------|-----------------|
| macOS | Accessibility + `CGEventPostToPid` | software cursor (screen) |
| iOS | `xcrun simctl` + XCUITest | sim overlay indicator |
| Android | `adb` + uiautomator | native `show_touches` |
| Web | Chrome + CDP | software cursor (CSS→screen) |
| Electron | CDP | software cursor (CSS→screen) |
| Flutter | Dart VM Service + mobile/desktop targets | mobile native / desktop screen |
| React Native | Metro + delegates to iOS | via iOS |
| Tauri | Accessibility through WKWebView | software cursor (via macOS) |
| Chrome Extension | CDP against extension pages | software cursor (via Web) |

## Install (as a Claude Code skill)

```bash
git clone git@github.com:dxiongya/debug-kit.git
bash debug-kit/install.sh          # symlinks into ~/.claude/skills/debug-kit
# (or: bash debug-kit/install.sh --copy   to copy instead of symlink)
```

Then in Claude Code, the `debug-kit` skill auto‑triggers on "run the app", "test the app",
"take screenshot", "tap button", etc. The scripts under `scripts/` also work standalone.

## Example

```bash
P=~/.claude/skills/debug-kit/scripts

# auto-detect the project and drive it
bash $P/pilot.sh auto run                    # build + launch
bash $P/pilot.sh auto tree                   # dump the semantic UI tree
bash $P/pilot.sh auto tap label "Login"      # background AXPress — your cursor untouched
bash $P/pilot.sh auto type "hello@example.com"
bash $P/pilot.sh auto screenshot

# or target a platform explicitly
MAC_APP=MyApp bash $P/mac-ctl.sh tap label incrementButton
bash $P/android-ctl.sh tap 540 1000          # native touch feedback shown on device
bash $P/flutter-ctl.sh vm widgets            # semantic widget tree over the VM Service
```

## How it works

debug-kit runs on a **macOS host** and drives each platform with its *native, professional*
protocol — never screen‑scraping when a real API exists. A small shared service
(`dk-pointer.sh` + a Swift overlay daemon) renders the virtual cursor in screen space, fed by
each controller after it maps the action to absolute screen coordinates. An
**interaction‑fidelity ladder** (semantic → synthetic → manual‑HID) keeps everything in the
background unless you explicitly ask for a real‑cursor click.

Knobs: `DK_POINTER=off` (hide the virtual pointer), `DK_FIDELITY=semantic|synthetic|real`,
`MAC_INPUT=hid` (the only path that moves your real cursor — manual opt‑in).

## Requirements

- **macOS** host. Grant **Accessibility** + **Screen Recording** to your terminal
  (System Settings → Privacy & Security), then fully relaunch it.
- Per‑platform toolchains as needed: Xcode (iOS/macOS), Android SDK + emulator,
  Node + Chrome (Web/Electron), Flutter SDK, Rust + Tauri CLI.
- Optional: Swift toolchain (`swiftc`) for the virtual‑pointer overlay — degrades gracefully if absent.

See `references/<platform>.md` for each platform's full command set and the
"best testing recipe", and `SKILL.md` for the interaction‑fidelity policy.

## Credits

- The virtual‑cursor glyph & motion are referenced from the **open‑computer‑use** project
  (a reverse‑engineering of Codex Computer Use's software cursor); see
  `scripts/assets/NOTICE.md`.
- The interaction action model aligns with **OpenAI's computer‑use** tool spec.

## License

MIT — see [LICENSE](./LICENSE).
