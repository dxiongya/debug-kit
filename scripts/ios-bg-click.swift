// ios-bg-click.swift — tap the iOS Simulator with **minimal visual disruption**
// when idb is unavailable.
//
// Background context (debugging story):
//   1. First attempt used `CGEvent.postToPid(simulatorPid)` — the Simulator
//      touch synthesizer reads from the GLOBAL HID stream only, so per-process
//      events were silently dropped.
//   2. Second attempt used `CGEvent.post(.cghidEventTap)` WITHOUT activating
//      Simulator — but macOS HID routes events to the *frontmost* application.
//      If Terminal/IDE is frontmost, the Simulator never receives the click.
//
// Working approach (this version):
//   1. Save user's cursor position + the current frontmost app
//   2. Activate Simulator (HID needs target to be frontmost)
//   3. Post the click via `.cghidEventTap` — now reaches Simulator
//   4. Immediately re-activate user's previous app
//   5. Warp cursor back to original position
//
// Visual cost (cannot be eliminated without idb):
//   - ~80-120ms: Simulator briefly raises to front, then user's app raises
//     back. Cursor blinks at click site for ~16ms before warp.
//
// For zero-visual-impact use, install idb:
//   pip install fb-idb && brew install idb-companion
//
// Usage:
//   swift ios-bg-click.swift <absScreenX> <absScreenY>

import Cocoa
import CoreGraphics

func die(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    die("usage: ios-bg-click <absX> <absY>")
}
guard let xVal = Double(args[1]), let yVal = Double(args[2]) else { die("bad coords") }
let location = CGPoint(x: xVal, y: yVal)

// Snapshot user state BEFORE any side effects.
let savedNS = NSEvent.mouseLocation
let mainHeight = NSScreen.main?.frame.height ?? 0
let savedCG = CGPoint(x: savedNS.x, y: mainHeight - savedNS.y)
let savedFront = NSWorkspace.shared.frontmostApplication

// Find Simulator app to activate it.
let simulatorBundleID = "com.apple.iphonesimulator"
let workspace = NSWorkspace.shared
let simulator = workspace.runningApplications.first { $0.bundleIdentifier == simulatorBundleID }

guard let simulator else {
    die("Simulator app not running. Boot with `xcrun simctl boot ...` then open Simulator.app.", code: 4)
}

func activate(_ app: NSRunningApplication) {
    if #available(macOS 14.0, *) {
        app.activate()
    } else {
        app.activate(options: [.activateIgnoringOtherApps])
    }
}

func postClick() {
    guard let down = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseDown,
        mouseCursorPosition: location,
        mouseButton: .left
    ) else { die("CGEvent down create failed", code: 3) }
    down.setIntegerValueField(.mouseEventClickState, value: 1)
    down.post(tap: .cghidEventTap)

    usleep(50_000)  // 50ms dwell — matches a real human click

    guard let up = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseUp,
        mouseCursorPosition: location,
        mouseButton: .left
    ) else { die("CGEvent up create failed", code: 3) }
    up.setIntegerValueField(.mouseEventClickState, value: 1)
    up.post(tap: .cghidEventTap)
}

// Step 1: Activate Simulator so HID events route to it.
activate(simulator)

// Activation is async — wait briefly for it to actually take frontmost.
// 60ms is a balance between "long enough that Simulator is reliably front"
// and "short enough that visual disruption stays minimal".
var waited: Double = 0
while waited < 0.20 {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == simulator.processIdentifier {
        break
    }
    usleep(20_000)
    waited += 0.020
}

// Step 2: Click. HID stream now lands on Simulator.
postClick()

// Step 3: Immediately re-activate user's previous app (if different).
// Doing this within the same execution flow keeps the visible Simulator
// frontmost time to ~100-150ms total.
if let savedFront,
   savedFront.processIdentifier != simulator.processIdentifier
{
    activate(savedFront)
}

// Step 4: Warp cursor home. CGWarpMouseCursorPosition is synchronous + instant.
CGWarpMouseCursorPosition(savedCG)
CGAssociateMouseAndMouseCursorPosition(1)

// Brief settle window for the activate() to land, then warp once more
// (sometimes the activation hands a different window the cursor focus).
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.10))
CGWarpMouseCursorPosition(savedCG)

print("ok ios-bg-click at=(\(Int(xVal)),\(Int(yVal))) cursor+frontmost restored")
