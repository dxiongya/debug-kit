# Android Debug Reference

**Script**: `bash ~/.claude/skills/debug-kit/scripts/android-ctl.sh <command>`
**Tools**: adb, emulator, gradle, uiautomator
**Env**: `ANDROID_PACKAGE`, `ANDROID_ACTIVITY`, `ANDROID_VARIANT=debug`

## Prerequisites

```bash
# Install Android platform tools (adb)
brew install --cask android-platform-tools

# For emulator, install Android Studio or command-line tools
# https://developer.android.com/studio
```

## Commands

### Emulator
| Command | Description |
|---------|-------------|
| `emulator-list` | List AVDs and connected devices |
| `emulator-start [avd]` | Start emulator (auto-selects first AVD) |
| `emulator-stop` | Stop emulator |

### Build & Install
| Command | Description |
|---------|-------------|
| `build [dir]` | Build APK (gradle assembleDebug) |
| `install [apk]` | Install APK to device |
| `launch` | Launch app (auto-detects package + activity) |
| `run [dir]` | Build + Install + Launch |
| `stop-app` | Force stop app |

### Inspection
| Command | Description |
|---------|-------------|
| `screenshot [path]` | Capture screenshot via adb |
| `tree [path]` | Dump UI hierarchy via uiautomator (XML with resource-ids, text, bounds) |
| `devices` | Device info: model, Android version, SDK, resolution, density |
| `health` | Health check |

### Interaction
| Command | Description |
|---------|-------------|
| `tap <x> <y>` | Tap at **dp coordinates** |
| `swipe <x1> <y1> <x2> <y2> [ms]` | Swipe gesture |
| `type "text"` | Type text |
| `key <name>` | Send key: `back`, `home`, `enter`, `tab`, `delete`, `menu` |

### Logs & App Management
| Command | Description |
|---------|-------------|
| `log [seconds]` | Stream logcat (filtered by app PID if package set) |
| `logcat-clear` | Clear logcat buffer |
| `uninstall [package]` | Uninstall app |
| `clear-data [package]` | Clear app data |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ANDROID_PACKAGE` | Auto-detected | App package name |
| `ANDROID_ACTIVITY` | Auto-detected | Main activity |
| `ANDROID_VARIANT` | `debug` | Build variant |

## Workflow

```bash
P=~/.claude/skills/debug-kit/scripts

# 1. Start emulator
bash $P/android-ctl.sh emulator-start

# 2. Build and run
bash $P/android-ctl.sh run /path/to/android/project

# 3. Screenshot
bash $P/android-ctl.sh screenshot /tmp/android-screen.png

# 4. Interact
bash $P/android-ctl.sh tap 540 960
bash $P/android-ctl.sh type "hello"
bash $P/android-ctl.sh key back

# 5. Inspect UI
bash $P/android-ctl.sh tree

# 6. Check logs
bash $P/android-ctl.sh log 5

# 7. Stop
bash $P/android-ctl.sh stop-app
bash $P/android-ctl.sh emulator-stop
```

## Key Differences from iOS

| Feature | Android (adb) | iOS (simctl) |
|---------|--------------|--------------|
| Tap | `adb shell input tap x y` (dp coordinates) | CGEvent (screen coordinates) |
| Screenshot | `adb exec-out screencap -p` | `xcrun simctl io booted screenshot` |
| UI Tree | `uiautomator dump` (XML) | XCUITest (JSON) |
| Type | `adb shell input text` | Accessibility API |
| Logs | `adb logcat` | `xcrun simctl spawn log stream` |
| Key events | `adb shell input keyevent` | AppleScript/JXA |

## Notes

- `adb shell input tap` uses **dp coordinates** (not pixels). Use `adb shell wm size` to get screen dimensions.
- `uiautomator dump` captures the full UI hierarchy as XML, including resource-ids, text, content-desc, and bounds.
- `adb logcat` can be filtered by PID using `--pid` flag for app-specific logs.
- This skill has **NOT been tested on this machine** (no Android SDK installed). Install Android SDK to use.

## Interaction fidelity (verified)

- **Collection:** `tree` (uiautomator dump — resource-id/bounds/desc) and `adb screencap`. *Verified on Pixel_3a / API 32.*
- **T1 semantic (default):** target by node (resource-id / text) via uiautomator. Deterministic.
- **T2 device input:** `adb shell input tap/swipe/text` at coordinates — this IS the device input layer (touch screens have no "real cursor"), so it doubles as the real-user path. *Verified: tap/swipe/back/home.*
- Note: `health` mis-handles the 0-device case (arithmetic error from `grep -c ... || echo 0`); harmless when a device is attached.

> **Virtual pointer:** `tap`/`swipe` enable the device's native touch feedback
> (`show_touches`) so the emulator draws where input lands — precise, no mapping, never touches
> your Mac cursor. `android-ctl pointer on|off|status`; `DK_POINTER=off` to skip.
