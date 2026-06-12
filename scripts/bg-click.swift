// bg-click.swift — post a mouse click to a specific pid+window without stealing focus.
//
// Based on the bgclick-rev-skill methodology (CGEvent.postToPid pattern):
//
//   1. Build the event via `NSEvent.mouseEvent(with:...)`. NSEvent
//      auto-fills ~12 internal CGEvent fields that AppKit's responder
//      chain expects; if you skip this and use `CGEvent(mouseEventSource:)`
//      directly, SwiftUI/AppKit buttons silently ignore the click.
//   2. Extract the underlying CGEvent via `.cgEvent`.
//   3. Manually patch the four fields NSEvent doesn't fill correctly:
//        - kCGMouseEventButtonNumber (.mouseEventButtonNumber, 3)
//        - kCGMouseEventSubtype       (.mouseEventSubtype, 25)
//        - kCGMouseEventWindowUnderMousePointer                       (91)
//        - kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent (92)
//   4. (Optional) set the command-modifier flag — AppKit's "raise
//      window on click" logic is gated by modifier keys; setting cmd
//      suppresses the raise. Some apps however reject cmd-clicks, so
//      `--no-cmd` exists. Default is OFF; relying on postToPid alone
//      is enough for AppKit/SwiftUI in our tests.
//   5. Dispatch via `cgEvent.postToPid(pid)` so the event bypasses the
//      global HID event tap and is delivered directly to the target.
//
// Usage:
//   swift bg-click.swift <pid> <windowID> <x> <y> [down|up|click|move] [--cmd]
//
// Coords are absolute screen coordinates, top-left origin (matches the
// `pos` field in debug-kit's accessibility tree JSON).

import Cocoa
import CoreGraphics

func die(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

let args = CommandLine.arguments
guard args.count >= 5 else {
    die("usage: bg-click <pid> <windowID> <x> <y> [down|up|click|move] [--cmd]")
}
guard let pidVal = Int32(args[1])  else { die("bad pid: \(args[1])") }
guard let winVal = Int(args[2])    else { die("bad windowID: \(args[2])") }
guard let xVal   = Double(args[3]) else { die("bad x: \(args[3])") }
guard let yVal   = Double(args[4]) else { die("bad y: \(args[4])") }

var action = "click"
var useCmd = false
for a in args.dropFirst(5) {
    switch a {
    case "down", "up", "click", "move": action = a
    case "--cmd": useCmd = true
    case "--no-cmd": useCmd = false
    default: die("unknown arg: \(a)")
    }
}

let pid      = pid_t(pidVal)
let windowID = Int64(winVal)
let location = CGPoint(x: xVal, y: yVal)

// CGEventField rawValues for window fields — these constants exist in
// CGEventTypes.h but are not always surfaced as Swift enum cases.
let fWinUnderPointer          = CGEventField(rawValue: 91)!  // kCGMouseEventWindowUnderMousePointer
let fWinUnderPointerHandlable = CGEventField(rawValue: 92)!  // kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent

// Process-global event number — must increment per event for AppKit to
// treat sequential events as belonging to the same gesture.
var eventNumberCounter: Int = 0
func nextEventNumber() -> Int {
    eventNumberCounter += 1
    return eventNumberCounter
}

func nsType(for cg: CGEventType) -> NSEvent.EventType {
    switch cg {
    case .leftMouseDown:  return .leftMouseDown
    case .leftMouseUp:    return .leftMouseUp
    case .mouseMoved:     return .mouseMoved
    default:              return .leftMouseDown
    }
}

func makeEvent(_ type: CGEventType, clickCount: Int = 1) -> CGEvent {
    // Step 1: NSEvent constructor fills 12 internal CGEvent fields that
    // AppKit relies on. windowNumber=0 means "screen coordinates".
    let flags: NSEvent.ModifierFlags = useCmd ? .command : []
    guard let ns = NSEvent.mouseEvent(
        with: nsType(for: type),
        location: location,
        modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        eventNumber: nextEventNumber(),
        clickCount: clickCount,
        pressure: (type == .leftMouseDown) ? 1.0 : 0.0
    ) else { die("NSEvent.mouseEvent returned nil for \(type.rawValue)", code: 3) }

    guard let cg = ns.cgEvent else { die("NSEvent.cgEvent returned nil", code: 3) }

    // Step 2: patch the four window-routing fields.
    cg.setIntegerValueField(.mouseEventButtonNumber, value: 0)
    cg.setIntegerValueField(.mouseEventSubtype,      value: 0)   // NSEventSubtypeMouse = 0
    cg.setIntegerValueField(fWinUnderPointer,          value: windowID)
    cg.setIntegerValueField(fWinUnderPointerHandlable, value: windowID)

    return cg
}

func post(_ type: CGEventType, clickCount: Int = 1) {
    let ev = makeEvent(type, clickCount: clickCount)
    ev.postToPid(pid)
}

// Save the user's actual cursor position so we can restore it after the
// click. macOS updates the system cursor even for postToPid'd events with
// mouseCursorPosition set; we can't suppress that, but we CAN warp it
// back. NSEvent.mouseLocation is in Cocoa coords (bottom-left origin), so
// flip Y to CG screen coords (top-left) for CGWarpMouseCursorPosition.
let savedNS = NSEvent.mouseLocation
let mainHeight = NSScreen.main?.frame.height ?? 0
let savedCG = CGPoint(x: savedNS.x, y: mainHeight - savedNS.y)

switch action {
case "move":
    post(.mouseMoved)
case "down":
    post(.leftMouseDown)
case "up":
    post(.leftMouseUp)
case "click":
    post(.leftMouseDown)
    usleep(50_000)  // 50ms dwell — matches what a user would do
    post(.leftMouseUp)
default:
    die("unreachable")
}

// Restore cursor position so the user's pointer doesn't end up where
// we clicked. The warp is instantaneous; visually you may see a brief
// flash but the pointer never settles at the click site.
CGWarpMouseCursorPosition(savedCG)
// CGAssociateMouseAndMouseCursorPosition(true) re-couples HW input
// to cursor in case the warp left them disassociated.
CGAssociateMouseAndMouseCursorPosition(1)

print("ok pid=\(pid) win=\(windowID) at=\(xVal),\(yVal) action=\(action) cmd=\(useCmd) cursor-restored")
