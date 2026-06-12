// mac-overlay.swift — debug-kit PERSISTENT virtual pointer daemon.
//
// One resident, borderless, transparent, CLICK-THROUGH cursor window that stays alive
// for a whole test session and GLIDES between targets — so a human can watch where
// debug-kit is interacting while the real system cursor is never touched and focus is
// never stolen (events go to the app via CGEventPostToPid / Accessibility separately).
//
// The cursor glyph design is referenced from the open-computer-use project
// (github.com/iFurySt/open-codex-computer-use — experiments/CursorMotion's
// SynthesizedCursorGlyphView), a reverse-engineering of Codex Computer Use's official
// "software cursor": a warm-grey pointer contour over a soft radial fog glow, with
// motion lag, rotation toward travel direction, and a click pulse.
//
// Protocol: the daemon tails a command file (one command per line). Coordinates are
// top-left screen coords (the CGEvent/AX space).
//   move  <x> <y>
//   click <x> <y>
//   drag  <fx> <fy> <tx> <ty>
//   type  <x> <y>
//   key   <x> <y>
//   quit
// It auto-exits after IDLE_TIMEOUT seconds of inactivity. Needs no special permission.

import Cocoa

let CMD_FILE = "/tmp/.debug-kit-ptr-cmds"
let PID_FILE = "/tmp/.debug-kit-ptr.pid"
let IDLE_TIMEOUT: TimeInterval = 45
let WIN: CGFloat = 126
let NEUTRAL_HEADING: CGFloat = -3 * .pi / 4   // glyph points up-left at rest (their calibration)

func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
func fileSize(_ path: String) -> UInt64 {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
}

// ─── Cursor glyph view (ported from open-computer-use SynthesizedCursorGlyphView) ───

// The reference cursor image (the official software-cursor PNG) if a path was passed as
// argv[1]; otherwise nil and we fall back to the procedural rounded triangle.
let REF_IMAGE: NSImage? = {
    let a = CommandLine.arguments
    if a.count > 1, !a[1].isEmpty, let img = NSImage(contentsOfFile: a[1]) { return img }
    return nil
}()

final class CursorGlyphView: NSView {
    var rotation: CGFloat = 0 { didSet { needsDisplay = true } }   // radians, subtle tilt toward travel
    var clickProgress: CGFloat = 0 { didSet { needsDisplay = true } } // 0…1 pulse
    var fogPulse: CGFloat = 0 { didSet { needsDisplay = true } }
    var motionSquash: CGFloat = 0 { didSet { needsDisplay = true } }  // velocity-based compression

    // OpenAI Operator-style pointer: a soft, rounded triangle. Light fill + thin dark
    // edge + soft shadow so it reads on both light and dark UIs, with a faint glow.
    private let fillColor   = NSColor(calibratedWhite: 0.96, alpha: 0.97)
    private let strokeColor = NSColor(calibratedWhite: 0.16, alpha: 0.55)

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); dirtyRect.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let tip = CGPoint(x: bounds.midX, y: bounds.midY)   // tip sits on the action point
        if let img = REF_IMAGE {
            drawReference(img, pulse: clickProgress)
        } else {
            drawGlow(ctx, center: tip, pulse: clickProgress + fogPulse)
            drawPointer(ctx, tip: tip, pulse: clickProgress)
        }
    }

    // Draw the official software-cursor PNG (glow baked in) with the live motion dynamics:
    // a subtle tilt toward travel, velocity-based compression, and a press squash.
    private func drawReference(_ img: NSImage, pulse: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: rotation)
        let press = 1 - pulse * 0.06
        ctx.scaleBy(x: press * (1 - motionSquash), y: press * (1 + motionSquash * 0.4))
        ctx.translateBy(x: -c.x, y: -c.y)
        img.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        ctx.restoreGState()
    }

    // A faint, neutral outer glow — subtle on light UIs, a soft halo on dark ones.
    private func drawGlow(_ ctx: CGContext, center: CGPoint, pulse: CGFloat) {
        let radius = 26 + pulse * 8
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [
            NSColor(calibratedWhite: 0.75, alpha: 0.16 + pulse * 0.10).cgColor,
            NSColor(calibratedWhite: 0.70, alpha: 0.06).cgColor,
            NSColor(calibratedWhite: 0.70, alpha: 0).cgColor,
        ] as CFArray
        guard let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.6, 1]) else { return }
        let c = CGPoint(x: center.x + 6, y: center.y - 8)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c,
                               endRadius: radius, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private func drawPointer(_ ctx: CGContext, tip: CGPoint, pulse: CGFloat) {
        let path = trianglePath(tip: tip)
        ctx.saveGState()
        let sc = 1 - pulse * 0.07                 // subtle press squash, anchored at the tip
        ctx.translateBy(x: tip.x, y: tip.y); ctx.scaleBy(x: sc, y: sc); ctx.translateBy(x: -tip.x, y: -tip.y)

        // soft shadow for depth / visibility on light backgrounds
        ctx.setShadow(offset: CGSize(width: 0.5, height: -1.5),
                      blur: 4.5 + pulse * 1.5,
                      color: NSColor.black.withAlphaComponent(0.34).cgColor)
        ctx.addPath(path); ctx.setFillColor(fillColor.cgColor); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        ctx.addPath(path); ctx.setStrokeColor(strokeColor.cgColor)
        ctx.setLineWidth(1.1); ctx.setLineJoin(.round); ctx.setLineCap(.round); ctx.strokePath()
        ctx.restoreGState()
    }

    // Rounded-corner triangle pointing up-left (tip at `tip`), body opening down-right.
    // Authored tip-at-origin (+x right, +y DOWN) then mapped into the y-up view; corners
    // are rounded with per-vertex radii (sharper tip, softer base) for that crisp-yet-soft look.
    private func trianglePath(tip: CGPoint) -> CGPath {
        let s: CGFloat = 1.5
        func v(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tip.x + x * s, y: tip.y - y * s) }
        let v0 = v(0, 0)      // tip (up-left)
        let v1 = v(1.6, 19)   // bottom-left
        let v2 = v(15, 12.5)  // right
        let p = CGMutablePath()
        p.move(to: CGPoint(x: (v0.x + v1.x) / 2, y: (v0.y + v1.y) / 2))
        p.addArc(tangent1End: v1, tangent2End: v2, radius: 3.4 * s)
        p.addArc(tangent1End: v2, tangent2End: v0, radius: 3.4 * s)
        p.addArc(tangent1End: v0, tangent2End: v1, radius: 2.0 * s)  // tip a touch sharper
        p.closeSubpath()
        return p
    }
}

// ─── Motion: a queue of steps the cursor animates through ───

struct Step {
    var to: CGPoint        // target, top-left screen coords
    var pulse: Bool        // show a click pulse on arrival
}

// A damped spring (Hooke + drag) parameterised the way open-computer-use does it:
// stiffness from `response`, drag from `dampingFraction`. Drives natural lag/settle.
struct Spring {
    let k: CGFloat, c: CGFloat
    init(response: CGFloat, damping: CGFloat) {
        k = pow(2 * .pi / response, 2)
        c = 2 * damping * sqrt(k)
    }
}

// A cubic Bézier travel path, control points shaped per open-computer-use's
// CursorMotionPath so the cursor swings out and curves into the target instead of
// going dead-straight. `point`/`tangent` are sampled by the spring-driven progress.
struct Bezier {
    let p0, c1, c2, p1: CGPoint
    let length: CGFloat

    init(from start: CGPoint, to end: CGPoint) {
        p0 = start; p1 = end
        let dx = end.x - start.x, dy = end.y - start.y
        let dist = max(hypot(dx, dy), 1)
        let nrm = CGPoint(x: -dy / dist, y: dx / dist)          // perpendicular unit
        let curveDir: CGFloat = dx >= 0 ? 1 : -1
        let curveAmount = min(max(dist * 0.22, 28), 110) * curveDir
        let off = CGPoint(x: nrm.x * curveAmount, y: nrm.y * curveAmount)
        c1 = CGPoint(x: start.x + dx * 0.18 + off.x,        y: start.y + dy * 0.10 + off.y)
        c2 = CGPoint(x: start.x + dx * 0.80 + off.x * 0.48, y: start.y + dy * 0.96 + off.y * 0.48)
        length = dist
    }

    func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p1.x,
                       y: a * p0.y + b * c1.y + c * c2.y + d * p1.y)
    }

    func tangent(at t: CGFloat) -> CGVector {
        let u = 1 - t
        let a = 3 * u * u, b = 6 * u * t, c = 3 * t * t
        return CGVector(dx: a * (c1.x - p0.x) + b * (c2.x - c1.x) + c * (p1.x - c2.x),
                        dy: a * (c1.y - p0.y) + b * (c2.y - c1.y) + c * (p1.y - c2.y))
    }
}

final class Daemon: NSObject {
    let window: NSPanel
    let view: CursorGlyphView
    let screenMaxY: CGFloat

    var pos: CGPoint               // current cursor pos (top-left screen coords)
    var path: Bezier?              // active travel path
    var progress: CGFloat = 0      // 0…1 along the path, spring-driven
    var progressVel: CGFloat = 0
    var angle: CGFloat = 0, angleVel: CGFloat = 0
    var queue: [Step] = []
    var step: Step?
    var stepStart: CFTimeInterval = 0
    var pulseStart: CFTimeInterval = -1
    var lastActivity: CFTimeInterval = CACurrentMediaTime()
    var fileOffset: UInt64 = 0

    // Progress spring drives travel along the Bézier (faster than their 1.4s "official"
    // lock so a test run isn't sluggish); the angle spring matches their visual-dynamics
    // angle spring (response 0.24 / damping 0.82).
    let progSpring = Spring(response: 0.5, damping: 0.9)
    let angSpring  = Spring(response: 0.24, damping: 0.82)

    init(start: CGPoint) {
        let primary = NSScreen.screens.first!
        screenMaxY = primary.frame.maxY
        view = CursorGlyphView(frame: NSRect(x: 0, y: 0, width: WIN, height: WIN))
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: WIN, height: WIN),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = view
        pos = start
        super.init()
        place(pos)
        window.orderFrontRegardless()
    }

    // top-left screen point -> Cocoa bottom-left window origin (centered on point)
    func place(_ p: CGPoint) {
        window.setFrameOrigin(NSPoint(x: p.x - WIN / 2, y: screenMaxY - p.y - WIN / 2))
    }

    func enqueue(_ s: Step) { queue.append(s); lastActivity = CACurrentMediaTime() }

    func tick() {
        let now = CACurrentMediaTime()

        // Pop the next step → build a fresh Bézier path from here to its target.
        if step == nil, !queue.isEmpty {
            step = queue.removeFirst()
            path = Bezier(from: pos, to: step!.to)
            progress = 0; progressVel = 0
            stepStart = now
        }

        let dt: CGFloat = 1.0 / 120.0
        var speed: CGFloat = 0

        if let b = path {
            // Spring the progress 0→1, then sample the curve for position + tangent.
            for _ in 0..<2 {
                let f = progSpring.k * (1 - progress) - progSpring.c * progressVel
                progressVel += f * dt; progress += progressVel * dt
            }
            let t = max(0, min(1, progress))
            pos = b.point(at: t)
            let tan = b.tangent(at: t)
            speed = progressVel * b.length            // px/s-ish, for compression
            // Subtle tilt toward the path tangent, capped (their animatedAngleOffsetMax ≈ 0.28).
            let tl = max(hypot(tan.dx, tan.dy), 0.0001)
            let desired = max(-0.28, min(0.28, (-tan.dx / tl) * 0.22 + (tan.dy / tl) * 0.10))
            for _ in 0..<2 {
                let af = angSpring.k * (desired - angle) - angSpring.c * angleVel
                angleVel += af * dt; angle += angleVel * dt
            }
        } else {
            // Idle: relax tilt back to neutral.
            for _ in 0..<2 {
                let af = angSpring.k * (0 - angle) - angSpring.c * angleVel
                angleVel += af * dt; angle += angleVel * dt
            }
        }

        view.motionSquash = min(abs(speed) * 0.00004, 0.02)
        view.rotation = angle

        // Idle drift: a gentle "alive" wander once fully settled.
        var drawPos = pos
        let settledNow = step == nil && queue.isEmpty && pulseStart < 0
        if settledNow {
            drawPos.x += sin(now * 1.3) * 0.6
            drawPos.y += cos(now * 1.05) * 0.5
            view.fogPulse = (sin(now * 1.6) + 1) * 0.10   // only visible in procedural fallback
        } else {
            view.fogPulse = 0
        }
        place(drawPos)

        // Arrival → fire the click pulse, then advance to the next step.
        if let s = step {
            if progress >= 0.99 || (now - stepStart) > 1.6 {
                pos = s.to; path = nil
                if s.pulse { pulseStart = now }
                step = nil
                lastActivity = now
            }
        }

        // Click pulse (~0.26s, 0→1→0).
        if pulseStart >= 0 {
            let pr = CGFloat((now - pulseStart) / 0.26)
            if pr >= 1 { view.clickProgress = 0; pulseStart = -1 }
            else { view.clickProgress = sin(pr * .pi) }
        }

        // Idle auto-quit.
        if now - lastActivity > IDLE_TIMEOUT && step == nil && queue.isEmpty && pulseStart < 0 {
            shutdown()
        }
    }

    // Read newly-appended command lines from the command file.
    func pollCommands() {
        guard let fh = FileHandle(forReadingAtPath: CMD_FILE) else { return }
        defer { try? fh.close() }
        let total = fileSize(CMD_FILE)
        if total < fileOffset { fileOffset = 0 }      // file was truncated/restarted
        if total == fileOffset { return }
        try? fh.seek(toOffset: fileOffset)
        let data = fh.readDataToEndOfFile()
        fileOffset = total
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            handle(String(line).trimmingCharacters(in: .whitespaces))
        }
    }

    func handle(_ line: String) {
        let p = line.split(separator: " ").map(String.init)
        guard let cmd = p.first else { return }
        func num(_ i: Int) -> CGFloat { i < p.count ? CGFloat(Double(p[i]) ?? 0) : 0 }
        switch cmd {
        case "move":
            enqueue(Step(to: CGPoint(x: num(1), y: num(2)), pulse: false))
        case "click", "tap", "type", "key":
            enqueue(Step(to: CGPoint(x: num(1), y: num(2)), pulse: true))
        case "drag":
            enqueue(Step(to: CGPoint(x: num(1), y: num(2)), pulse: true))   // press at source
            enqueue(Step(to: CGPoint(x: num(3), y: num(4)), pulse: true))   // release at target
        case "quit":
            shutdown()
        default: break
        }
    }

    func shutdown() {
        try? FileManager.default.removeItem(atPath: PID_FILE)
        NSApp.terminate(nil)
    }
}

// ─── Boot ───

// Single-instance guard: if a live daemon already owns the PID file, exit.
if let s = try? String(contentsOfFile: PID_FILE, encoding: .utf8), let oldPid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
    if kill(oldPid, 0) == 0 { exit(0) }
}
try? "\(ProcessInfo.processInfo.processIdentifier)".write(toFile: PID_FILE, atomically: true, encoding: .utf8)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Start the cursor near the current real cursor position (so the first glide reads natural).
let mouse = NSEvent.mouseLocation
let primary0 = NSScreen.screens.first!
let startTopLeft = CGPoint(x: mouse.x, y: primary0.frame.maxY - mouse.y)
let daemon = Daemon(start: startTopLeft)
daemon.fileOffset = fileSize(CMD_FILE)

Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
    daemon.pollCommands()
    daemon.tick()
}
app.run()
