// ios-tap-indicator.swift — visual feedback cursor for debug-kit tap-bg (v2).
//
// Draws a **macOS-style arrow cursor** at the click site so the user sees a
// realistic pointer "land and click" on whatever was tapped. Not a red
// circle (those read as "warning marker"); this is the system cursor shape
// the user already associates with "something just clicked there".
//
// Visual model:
//   - Classic macOS arrow shape: black fill + white outline (visible on
//     both light and dark UI), tip at exact (x, y) click coord.
//   - Brief tap pulse: arrow scales down to 0.85x at frame 4-8 (click
//     "press") then back to 1.0, then quick fade-out.
//   - Lifetime 700ms total: 0-300ms = full alpha + press animation,
//     300-700ms = fade out.
//
// Tech:
//   - Borderless NSWindow at `.screenSaver` level → floats above ALL
//     other windows including the Simulator content area. Visually this
//     reads as "the cursor is on top of the simulated app", which is
//     exactly what the user asked for ("渲染在要操控的软件内").
//   - `ignoresMouseEvents = true` → cursor click-through, doesn't steal
//     real input.
//
// Usage:
//   swift ios-tap-indicator.swift <absScreenX> <absScreenY>

import Cocoa

let args = CommandLine.arguments
guard args.count >= 3,
      let xVal = Double(args[1]),
      let yVal = Double(args[2]) else {
    FileHandle.standardError.write("usage: ios-tap-indicator <absX> <absY>\n".data(using: .utf8)!)
    exit(2)
}

// CG/screencapture top-left origin → NSWindow bottom-left origin
let mainHeight = NSScreen.main?.frame.height ?? 0
let nsY = mainHeight - yVal

// Window size: cursor fits in 32x40 box (tip at top-left), pulse margin = 8
let winSize: CGFloat = 48
// Position window so click tip lands at (xVal, yVal): tip is in the
// top-left of cursor shape, so window origin = click - (4, 4) inset
let tipInset: CGFloat = 4
let frame = NSRect(
    x: xVal - tipInset,
    y: nsY - winSize + tipInset,  // flip Y for NSWindow
    width: winSize,
    height: winSize
)

final class ArrowCursorView: NSView {
    var pressScale: CGFloat = 1.0   // 1.0 → 0.85 → 1.0 over the press tick
    var alpha: CGFloat = 1.0

    /// Classic macOS arrow shape, tip at top-left (0, h).
    /// Coords are NSView (bottom-left origin), so y values are mirrored.
    /// Drawn in a 28x32 box, tip lands at (0, top).
    private func arrowPath(scale: CGFloat) -> NSBezierPath {
        // Reference coords (in standard top-left-origin, will flip)
        // Tip: (0, 0)
        // Left side: (0, 22)
        // Notch: (7, 19)
        // Tail tip: (12, 30)
        // Tail edge: (16, 28)
        // Notch back: (11, 17)
        // Right edge: (16, 17)
        let p = NSBezierPath()
        let h = bounds.height
        // Pivot for scale = tip point (0, h)
        let tipX: CGFloat = 4
        let tipY: CGFloat = h - 4
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            // Apply scale around tip
            let dx = (x) * scale
            let dy = (y) * scale
            return NSPoint(x: tipX + dx, y: tipY - dy)
        }
        p.move(to: point(0, 0))
        p.line(to: point(0, 22))
        p.line(to: point(6.5, 18.5))
        p.line(to: point(11.5, 29))
        p.line(to: point(15, 27.5))
        p.line(to: point(10, 17))
        p.line(to: point(16, 17))
        p.close()
        return p
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.saveGState()
        ctx.setAlpha(alpha)

        let path = arrowPath(scale: pressScale)
        // White outline (so the cursor is visible on dark backgrounds too)
        NSColor.white.setStroke()
        path.lineWidth = 2.6
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.stroke()
        // Black fill (classic macOS cursor body)
        NSColor.black.setFill()
        path.fill()

        ctx.restoreGState()
    }
}

final class IndicatorAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var cursorView: ArrowCursorView!
    var startTime: Date!
    let totalDuration: TimeInterval = 0.70

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false

        cursorView = ArrowCursorView(frame: NSRect(x: 0, y: 0, width: winSize, height: winSize))
        window.contentView = cursorView
        window.orderFrontRegardless()

        startTime = Date()
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = Date().timeIntervalSince(self.startTime)
            let p = min(elapsed / self.totalDuration, 1.0)

            // Press animation: dip to 0.85x scale around 100-180ms, back to 1.0
            // Phase: 0-100ms idle, 100-180ms compress to 0.85, 180-260ms back to 1.0
            let pressP: Double
            if elapsed < 0.10 {
                pressP = 0
            } else if elapsed < 0.18 {
                pressP = (elapsed - 0.10) / 0.08   // 0 → 1
            } else if elapsed < 0.26 {
                pressP = 1.0 - (elapsed - 0.18) / 0.08  // 1 → 0
            } else {
                pressP = 0
            }
            self.cursorView.pressScale = 1.0 - 0.15 * CGFloat(pressP)

            // Fade out in last 40% of lifetime
            if p < 0.55 {
                self.cursorView.alpha = 1.0
            } else {
                self.cursorView.alpha = max(0, (1.0 - p) / 0.45)
            }

            self.cursorView.needsDisplay = true
            if p >= 1.0 {
                timer.invalidate()
                NSApp.terminate(nil)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = IndicatorAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
