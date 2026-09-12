# Native macOS validation and local installation

Use for SwiftUI/AppKit apps, especially menu-bar panels, popovers, clipboard utilities, and a development build that may replace an installed app. These practices came from a real clipboard-app session: focused model tests and live accessibility-driven checks were useful; repeated XCTest event failures and shared-pasteboard pollution were not successful verification techniques.

## 1. Establish the test boundary before launching

- Inspect repository instructions, dirty changes, Xcode/SDK version, scheme, app target, bundle ID, entitlements, and installed app path. Preserve unrelated edits. Use explicit build output paths; do not select the first `.app` found under DerivedData.
- Distinguish production and QA by **bundle identity, process executable, preferences suite, and database URL**. A launch argument is effective only if application code actually reads it. Confirm the testing branch executes before constructing persistent storage or starting background services.
- Prefer injected in-memory models for logic tests; use a dedicated temporary on-disk store for persistence/reopen tests. Use independent preferences for folder definitions, window state, and shortcuts. Check shared App Groups, Keychain groups, sync, login-item registration, and updater behavior if the app uses them.
- Build a QA identity with a target-specific bundle suffix if the project supports it. For example, an app target may define `org.example.App$(APP_BUNDLE_SUFFIX)` and a QA build pass `APP_BUNDLE_SUFFIX=.QA`. This is a project configuration pattern, **not** a built-in Xcode flag. Verify the resulting `CFBundleIdentifier` and test-host settings; remove the suffix for a production-identity build.
- Select a running app by verified full path/bundle ID, not its display name. Two apps called “MyApp” can cause automation to operate on the installed copy. If identity or fixture isolation is uncertain, stop before clicking or typing.

### Clipboard isolation is separate

The general pasteboard is machine-wide. A QA bundle ID and temporary database do **not** stop the user's installed clipboard manager from recording test strings. Restoring the pasteboard afterward does not remove recorded history or recover entries evicted by its size limit.

Prefer fixture injection into the QA model and a mock/named pasteboard for automated logic tests. For a necessary real-copy/paste check, arrange a controlled window with the user and pause/quit the specific production watcher only when authorized. Account for other running clipboard watchers. Do not overwrite clipboard changes the user makes during the test; restore only the known test-owned state and supported formats. If shared-resource isolation cannot be established, skip the real pasteboard mutation and report that limitation.

## 2. Build and test with traceable outputs

Run focused model tests before UI automation. For stateful features, useful invariants include:

| Behavior | Observable check |
|---|---|
| Toggle versus save | Pinning and favoriting remain independent; action clicks do not paste or dismiss the panel |
| Folder identity | Rename changes only the display name; stable IDs preserve membership |
| Validation | Empty/duplicate names are rejected; cancel leaves state unchanged |
| Filtering | Search, new copies, and moving an item preserve the active folder scope |
| Retention | History trimming and ordinary clear preserve saved items; explicit destructive clear follows its documented behavior |
| Persistence | Reopen a fresh model container at the isolated store URL and check saved membership, not just the same in-memory object |

Adapt this matrix to the requested feature rather than testing unrelated capabilities.

Use an explicit scheme, configuration, destination, DerivedData directory, and unique result bundle. Example only, with project-specific values to resolve before execution:

```bash
DEBUG_RUN_DIR=$(mktemp -d /tmp/native-app-check.XXXXXX)
xcodebuild -project /resolved/project/MyApp.xcodeproj \
  -scheme MyApp -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DEBUG_RUN_DIR/DerivedData" \
  -resultBundlePath "$DEBUG_RUN_DIR/ModelTests.xcresult" \
  -only-testing:MyAppTests/HistoryTests test \
  > "$DEBUG_RUN_DIR/model-tests.log" 2>&1
```

Use the architecture and test identifiers actually present. Preserve the process exit code; if piping logs, enable `pipefail`. Retain concise logs and result paths. On Xcode versions that support it, inspect `xcrun xcresulttool get test-results summary --path ...`; otherwise consult the installed tool's help. Derive pass counts from the completed result, never from “Testing started.”

Use the project's existing signing configuration first. Local ad-hoc signing can suit an authorized development build; it is not a reason to disable sandboxing, hardened runtime, or OS protections, and does not establish distribution trust. Verify the app's expected entitlements and identity before launching or replacing it.

## 3. Make native UI tests deterministic

### Open the actual panel

Menu-bar icons may be outside visible display bounds; global shortcuts may conflict or differ from defaults. Do not repeatedly click an offscreen status item or send a guessed hotkey. For an editable app, consider a DEBUG-only, testing-only `show-on-launch` path that opens the QA panel after initialization. Verify this code path and test flag exist; do not assume arbitrary arguments implement it. It must not open production storage or alter normal release startup.

### Target the intended control

- Scope accessibility IDs by location and stable item identity, e.g. `favorite-row-<id>` versus `favorite-preview-<id>`. A shared “Add to favorites” label plus `firstMatch` can target an invisible preview instead of the row button.
- Wait for the intended window/control to exist and, for XCTest actions, be hittable. After a click, assert the resulting popover or changed state before typing. Re-query after movement, scrolling, filtering, or dismissal.
- With `cua_repl`, load its documented entry point and follow the returned API. Inspect AX state, perform the targeted action, then inspect fresh AX state. Do not reuse numeric indexes across changed trees or invent helper methods.
- For Chinese names, test the text field's actual value and the saved label. If simulated typing fails, a supported accessibility `setValue` plus Save/Return can verify the save path, but does not prove IME/keyboard composition works. Report that distinction.

### Check popover focus and event handling

For transient panels, verify that opening a popover does not close its parent, steal selection, clear search, or invoke global row shortcuts while typing. Check Return submits only the editor, Escape cancels only the intended surface, and focus returns correctly after dismissal. Any editing-state guard should reset on every dismissal path; verify outside-click dismissal too. Keep row-content paste actions separate from sibling pin/star buttons.

### Diagnose, do not brute-force retries

Capture the first failure with its step, AX state/screenshot, and result log. Distinguish:

- **Product failure:** expected state is wrong after a confirmed action on the correct control.
- **Targeting/focus failure:** wrong instance, duplicate ID, hidden control, parent panel closed, or stale tree.
- **Environment/runner failure:** accessibility access unavailable, event synthesis timeout, or offscreen system UI.

Make one evidence-based correction and rerun the focused case. If the same failure persists, stop repeating the sequence; use a permitted live UI check on the isolated app or report what is blocked. Do not enable permissions automatically or treat a manual pass as an XCTest pass.

## 4. Visually inspect what AX cannot prove

Use non-sensitive fixtures. Review the relevant screen/popover at realistic size, including selected/unselected and empty states, long Chinese folder names, and overflow when multiple folders exist. Inspect applicable light/dark appearances without silently changing the user's system preferences.

For icon consistency, use a coherent symbol family (SF Symbols in a native app), shared rendering size/weight/scale for equivalent controls, aligned baselines, spacing, and consistent hit targets. Communicate active states consistently across row and preview (e.g. outline/filled pin and star), not by color alone. Verify contrast on selected rows and that compact folder controls remain readable. A shared icon component helps enforce the rule; an AX tree alone cannot verify the result.

## 5. Replace a local app only within the user's request

1. Resolve the exact installed app, running executable, data paths, and current identity/version. Ask before expanding a diagnostic task into installation.
2. Back up the installed bundle, preferences, and a consistent database snapshot in a unique recoverable directory. For SQLite, use its backup API/`.backup`, not a copy of only the live `.sqlite` file while WAL writes may exist. Record counts and stable-ID/state summaries without printing private clipboard contents.
3. Stop only the exact intended process when authorized. Build the final configuration with the production identity, verify signing and expected entitlements, and keep the old app recoverable. Do not recursively delete broad paths or overwrite the only backup.
4. Install the verified artifact, launch the exact installed path, and confirm it is the running executable. Check migration success, expected data invariants, and a minimal non-destructive UI smoke test. Production smoke tests should not create fixture data, unpin user entries, or exercise clear/delete.
5. Investigate differences before restoring anything. Retention limits, real user edits, and test pollution can all change counts. If the user confirms they changed a state, preserve it. For suspected test effects, retain both snapshots, explain what is known, and agree on a targeted recovery that preserves new user data. A backup is a recovery option, not authorization to roll back.

Do not claim installation preserves every record merely because the app launches. If verification is blocked, leave a usable previous build or explain the specific installed state and recovery path.

## 6. Close with evidence

Report only the relevant outcome: implemented/installed status, exact automated results, independently verified UI actions, limitations, and backup location when an installation occurred. If testing touched real data, disclose it promptly. Keep private screenshots, text, paths, timestamps, and fixture IDs from a past user session out of reusable skill instructions.

### Quick scenario checks for future skill changes

- Two same-name apps are running and the QA store is temporary: verify exact identity **and** shared pasteboard exposure before any mutation.
- A star click finds no editor after two attempts: inspect scoped control identity/focus, then switch verification method or stop; do not keep typing into whichever field is focused.
- A user says their missing pins were deliberately removed: preserve current pins; do not restore the older snapshot.
- A user asks only to diagnose a popover bug: inspect and report; do not install a new app or grant new OS permissions.

These are review scenarios, not claims of executed automated tests.
