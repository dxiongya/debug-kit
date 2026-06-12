# React Native & Expo Debug Reference

**Script**: `bash ~/.claude/skills/debug-kit/scripts/rn-ctl.sh <command>`
**Tools**: React Native CLI / Expo CLI, Metro bundler, xcodebuild; delegates to ios-ctl for interaction
**Env**: `RN_DEVICE` (simulator name), `RN_SCHEME` (Xcode scheme), `EXPO_MODE` (go/native)

## Expo Auto-Detection

The script auto-detects Expo projects (checks for `expo` in package.json dependencies). For Expo projects:
- **Expo Go mode** (default): Starts Metro server, opens app via `xcrun simctl openurl exp://127.0.0.1:8081`
- **Native mode** (`EXPO_MODE=native`): Runs `npx expo run:ios` for native build

Bare React Native projects use `npx react-native run-ios` as before.

## Commands

| Category | Command | Description |
|----------|---------|-------------|
| **Lifecycle** | `run [dir]` | Build and run on iOS Simulator (auto-detects Expo vs bare RN) |
| | `build [dir]` | Build iOS app only (bare RN) |
| | `start-metro [dir]` | Start Metro/Expo dev server only |
| | `stop` | Stop app and Metro/Expo |
| | `reload` | Trigger JS reload |
| **Inspection** | `screenshot [path]` | Capture iOS Simulator screenshot |
| | `tree` | Dump accessibility tree (via ios-ctl) |
| | `health` | Health check |
| **Testing** | `test [dir]` | Run Jest tests |
| **Logs** | `log [seconds]` | Stream iOS simulator logs |
| | `metro-log [lines]` | Show Metro bundler output |
| **Interaction** | `tap <x> <y>` | Tap at **point** coordinates (via ios-ctl CGEvent) |
| | `tap identifier <id>` | Tap by accessibility identifier |
| | `tap label <text>` | Tap by accessibility label |

## Coordinate System

Screenshots are captured at device pixel resolution (e.g., 1170x2532 for iPhone 16e at 3x). The tap command uses **point coordinates** (device pixels / scale factor).

| Device | Pixels | Scale | Points |
|--------|--------|-------|--------|
| iPhone 16e | 1170x2532 | 3x | 390x844 |
| iPhone 16 | 1170x2532 | 3x | 390x844 |
| iPhone 16 Pro | 1206x2622 | 3x | 402x874 |

To convert screenshot pixel position to tap coordinates: **divide by 3** (or the device's scale factor).

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RN_DEVICE` | Auto | Simulator name (e.g., "iPhone 16e") |
| `RN_SCHEME` | Auto from xcworkspace | Xcode build scheme |
| `EXPO_MODE` | `go` | Expo run mode: `go` (Expo Go) or `native` (`expo run:ios`) |

## Dependencies

- **ios-ctl.sh**: Required for `tap` and `tree` commands (bundled in debug-kit)
- **Node.js**: For Metro bundler and Jest
- **Xcode**: For iOS builds (bare RN and Expo native mode)
- **CocoaPods**: Auto-installed if missing (bare RN)
- **Expo Go**: Must be installed on simulator for Expo Go mode (first run may require interactive `npx expo start --ios` to install)

## Workflow

```bash
P=~/.claude/skills/debug-kit/scripts

# 1. Build and run
bash $P/rn-ctl.sh run /path/to/rn/project

# 2. Screenshot to see current state
bash $P/rn-ctl.sh screenshot /tmp/rn-screen.png

# 3. Interact (use point coordinates, not pixels)
# Screenshot pixels / device scale factor = point coordinates
# iPhone 16e: 3x scale, so divide pixel coords by 3
bash $P/rn-ctl.sh tap 320 263

# 4. Reload after code changes
bash $P/rn-ctl.sh reload

# 5. Run tests
bash $P/rn-ctl.sh test /path/to/rn/project

# 6. Stop
bash $P/rn-ctl.sh stop
```

## Notes

- State is saved to `/tmp/.rn-debug-state.json`
- Build log: `/tmp/rn-debug-build.log`
- Metro log: `/tmp/rn-debug-metro.log`
- CocoaPods are auto-installed on first run if `ios/Pods` doesn't exist
- Metro bundler runs on port 8081 by default
- Use `reload` after JS changes — no rebuild needed for JS-only changes

## Interaction fidelity (verified)

RN renders **native** UIKit/Android views, so native semantic tooling applies (unlike Flutter).
- **Collection:** XCUITest AX tree (iOS) / uiautomator (Android), `simctl io` / `adb screencap`.
- **T1 semantic (default):** match by `testID` → accessibilityIdentifier (XCUITest / uiautomator).
- **T2 synthetic:** `simctl io` / `adb input` at coordinates (delegated via ios-ctl/android-ctl).
- **Requires Metro** for the JS bundle. *Verified: bare RN builds + launches on the iOS sim (after the `rn-ctl` empty-array fix); Metro could not bind in this workspace because ports 8081/8082 are taken by OrbStack/mitmweb — an env conflict, so the JS bundle showed the redbox. Once Metro serves, taps reach RN like any native iOS app.*

> **Metro port + env note (verified):** `rn-ctl` now auto-selects a free Metro port (default
> 8081 is often held by OrbStack/`mitmweb`); it binds, and `health`/`reload` track the chosen
> port. Separately, if a **system HTTP proxy** is enabled (System Settings → Network → Proxies),
> the iOS Simulator routes through it and may fail to reach localhost Metro (redbox: bundle URL
> null) — disable the proxy (or exclude localhost) to load the JS bundle. That is an environment
> setting, outside the skill.
