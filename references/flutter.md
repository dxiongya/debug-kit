# Flutter Debug Reference

**Script**: `bash ~/.claude/skills/debug-kit/scripts/flutter-ctl.sh <command>`
**Tools**: Flutter CLI, Dart VM Service; delegates to ios/web/macos scripts for interaction
**Env**: `FLUTTER_DEVICE` (auto-detected if not set)

## Commands

| Category | Command | Description |
|----------|---------|-------------|
| **Lifecycle** | `run [dir]` | Run Flutter app (auto-detects device) |
| | `stop` | Stop running app |
| | `reload` | Hot reload (preserves state) |
| | `restart` | Hot restart (resets state) |
| **Inspection** | `screenshot [path]` | Capture screenshot (auto: simctl/CDP/screencapture) |
| | `health` | Health check (Flutter version, running state, devices) |
| | `vm info` | Show Dart VM Service info |
| | `vm isolates` | List Dart isolates |
| **Testing** | `test [dir]` | Run unit/widget tests (`flutter test`) |
| | `analyze [dir]` | Run `flutter analyze` |
| **Logs** | `log [seconds]` | Stream device logs (iOS) or show run log |
| | `run-log [lines]` | Show flutter run output |
| **Interaction** | `tap <x> <y>` | Tap on device (delegates to ios-ctl/mac-ctl based on device) |
| | `tap identifier <id>` | Tap by accessibility identifier |

## Device Auto-Detection

Priority order:
1. **iOS Simulator** — if a simulator is booted (`xcrun simctl list devices booted`)
2. **Chrome** — if Chrome is installed
3. **macOS** — fallback to macOS desktop

Override with `FLUTTER_DEVICE` environment variable.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `FLUTTER_DEVICE` | Auto-detected | Target device (e.g., `iPhone`, `chrome`, `macos`, or device UDID) |

## Workflow

```bash
P=~/.claude/skills/debug-kit/scripts

# 1. Run the app
bash $P/flutter-ctl.sh run /path/to/flutter/project

# 2. Take screenshot to see current state
bash $P/flutter-ctl.sh screenshot /tmp/flutter-screen.png

# 3. Interact (iOS Simulator example)
bash $P/flutter-ctl.sh tap 200 400

# 4. Hot reload after code changes
bash $P/flutter-ctl.sh reload

# 5. Run tests
bash $P/flutter-ctl.sh test /path/to/flutter/project
bash $P/flutter-ctl.sh analyze /path/to/flutter/project

# 6. Check VM Service
bash $P/flutter-ctl.sh vm info

# 7. Stop
bash $P/flutter-ctl.sh stop
```

## Platform-Specific Interaction

| Device | Screenshot | Tap | Interaction Skill |
|--------|-----------|-----|-------------------|
| iOS Simulator | `xcrun simctl io booted screenshot` | `ios-ctl.sh` CGEvent | `ios-ctl.sh` |
| Chrome (web) | CDP screenshot | CDP click | `cdp-client.mjs` |
| macOS | `screencapture` | `mac-ctl.sh` CGEvent | `mac-ctl.sh` |

## Notes

- State is saved to `/tmp/.flutter-debug-state.json` (PID, device, VM Service URL)
- Flutter run log is at `/tmp/flutter-debug.log`
- Hot reload uses `SIGUSR1`, hot restart uses `SIGUSR2`
- VM Service URL is auto-captured from flutter run output for programmatic inspection
- For iOS Simulator, use device UDID directly if `flutter run` hangs on device discovery: `FLUTTER_DEVICE=<UDID> bash ~/.claude/skills/debug-kit/scripts/flutter-ctl.sh run`

## Interaction fidelity (verified — important)

Flutter renders a **custom canvas**, so native AX-based interaction does NOT apply on desktop.
- **Collection:** screenshots work (macOS via `mac-ctl` window-targeted; mobile via simctl/adb). For UI state use the **Dart VM Service** / `integration_test`.
- **T1 semantic (default & recommended):** drive via the **Dart VM Service / `flutter_driver` / `integration_test`** — the only semantic path for Flutter.
- **Mobile targets (iOS sim / Android):** `simctl io` / `adb input` HID touches DO reach Flutter — use these for coordinate interaction.
- **Desktop (macOS) caveat — verified:** the Flutter window exposes **no AX content** (only window-chrome buttons), and background `CGEventPostToPid` clicks do **not** reach Flutter hit-testing; activation also moves the window. So **do not use the macOS target for tap interaction** — prefer a mobile target or the VM Service. (`flutter-ctl run/screenshot/health` on macOS do work.)

> **VM Service collection (verified):** `flutter-ctl vm widgets` dumps the real widget tree
> (semantic, with text previews) over the Dart VM Service — works even on the macOS desktop
> target where there is no AX tree. `flutter-ctl vm call <method> [json]` calls any VM RPC or
> service extension (`$ISOLATE` → main isolate). For programmatic taps, build with
> `enableFlutterDriverExtension()` and call `ext.flutter.driver` via `vm call`.
