// bg-act.swift — perform AX actions on a target process WITHOUT stealing focus.
//
// Why this exists: JXA System Events bridges only a subset of AX
// attributes — SwiftUI Buttons in particular have nil .name() / .title()
// via JXA, and `accessibilityIdentifier` (kAXIdentifierAttribute) isn't
// bridged at all. The raw AXUIElement C API exposes all of them, and
// also gives us AXUIElementCopyElementAtPosition for coord-based hit
// testing without walking the tree.
//
// Usage:
//   bg-act.swift <pid> press id:<axId>
//   bg-act.swift <pid> press title:<text>          (substring match)
//   bg-act.swift <pid> press desc:<text>           (substring match)
//   bg-act.swift <pid> press point:<x>,<y>
//   bg-act.swift <pid> set-value id:<axId> <text>
//   bg-act.swift <pid> set-value first-textfield <text>
//   bg-act.swift <pid> dump                         (dump rich AX tree to stdout)
//
// Selector kinds:
//   id:    = kAXIdentifierAttribute (SwiftUI's .accessibilityIdentifier)
//   title: = kAXTitleAttribute      (button label, etc.)
//   desc:  = kAXDescriptionAttribute (often generic, e.g. "button")
//   point: = screen coords; uses AXUIElementCopyElementAtPosition
//
// All matches are substring-insensitive for title/desc, exact for id.

import Cocoa
import ApplicationServices

// MARK: - I/O helpers ---------------------------------------------------------

func die(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func say(_ msg: String) {
    print(msg)
}

// MARK: - AX read helpers -----------------------------------------------------

func axStr(_ el: AXUIElement, _ attr: String) -> String? {
    var raw: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, attr as CFString, &raw)
    guard err == .success, let v = raw else { return nil }
    if let s = v as? String { return s }
    return nil
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    var raw: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &raw)
    guard err == .success, let arr = raw as? [AXUIElement] else { return [] }
    return arr
}

func axPosition(_ el: AXUIElement) -> CGPoint? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &raw) == .success,
          let v = raw else { return nil }
    var pt = CGPoint.zero
    if AXValueGetValue(v as! AXValue, .cgPoint, &pt) { return pt }
    return nil
}

func axSize(_ el: AXUIElement) -> CGSize? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &raw) == .success,
          let v = raw else { return nil }
    var sz = CGSize.zero
    if AXValueGetValue(v as! AXValue, .cgSize, &sz) { return sz }
    return nil
}

// MARK: - Search --------------------------------------------------------------

struct Selector {
    enum Kind { case id, title, desc, point }
    let kind: Kind
    let value: String
    let point: CGPoint?

    static func parse(_ s: String) -> Selector? {
        if let r = s.range(of: ":") {
            let k = String(s[..<r.lowerBound])
            let v = String(s[r.upperBound...])
            switch k {
            case "id":    return Selector(kind: .id,    value: v, point: nil)
            case "title": return Selector(kind: .title, value: v, point: nil)
            case "desc":  return Selector(kind: .desc,  value: v, point: nil)
            case "point":
                let parts = v.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 else { return nil }
                return Selector(kind: .point, value: v, point: CGPoint(x: parts[0], y: parts[1]))
            default: return nil
            }
        }
        return nil
    }
}

func matches(_ el: AXUIElement, _ sel: Selector) -> Bool {
    switch sel.kind {
    case .id:
        return axStr(el, kAXIdentifierAttribute) == sel.value
    case .title:
        guard let t = axStr(el, kAXTitleAttribute) else { return false }
        return t.range(of: sel.value, options: .caseInsensitive) != nil
    case .desc:
        guard let d = axStr(el, kAXDescriptionAttribute) else { return false }
        return d.range(of: sel.value, options: .caseInsensitive) != nil
    case .point:
        return false
    }
}

func walk(_ root: AXUIElement, _ sel: Selector, depth: Int = 0) -> AXUIElement? {
    if depth > 30 { return nil }
    if matches(root, sel) { return root }
    for c in axChildren(root) {
        if let hit = walk(c, sel, depth: depth + 1) { return hit }
    }
    return nil
}

func elementAtPoint(app: AXUIElement, x: Double, y: Double) -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    var hit: AXUIElement?
    var raw: AXUIElement?
    let err = AXUIElementCopyElementAtPosition(systemWide, Float(x), Float(y), &raw)
    if err == .success, let r = raw { hit = r }
    return hit
}

// MARK: - Dump (for debugging / tree inspection) ------------------------------

func dump(_ el: AXUIElement, depth: Int = 0, max: Int = 12) {
    if depth > max { return }
    let role = axStr(el, kAXRoleAttribute) ?? "?"
    let title = axStr(el, kAXTitleAttribute) ?? ""
    let desc = axStr(el, kAXDescriptionAttribute) ?? ""
    let id   = axStr(el, kAXIdentifierAttribute) ?? ""
    let val  = axStr(el, kAXValueAttribute) ?? ""
    var line = String(repeating: "  ", count: depth) + "[\(role)]"
    if !title.isEmpty { line += " title=\(title.prefix(40))" }
    if !id.isEmpty    { line += " id=\(id.prefix(40))" }
    if !desc.isEmpty && desc != role.replacingOccurrences(of: "AX", with: "").lowercased() {
        line += " desc=\(desc.prefix(40))"
    }
    if !val.isEmpty   { line += " val=\(val.prefix(40))" }
    if let p = axPosition(el), let s = axSize(el) {
        line += " @ (\(Int(p.x)),\(Int(p.y)) \(Int(s.width))x\(Int(s.height)))"
    }
    say(line)
    for c in axChildren(el) {
        dump(c, depth: depth + 1, max: max)
    }
}

// MARK: - Main ----------------------------------------------------------------

let args = CommandLine.arguments
guard args.count >= 3 else {
    die("usage: bg-act <pid> press|set-value|dump [...]")
}
guard let pidVal = Int32(args[1]) else { die("bad pid: \(args[1])") }
let pid = pid_t(pidVal)
let app = AXUIElementCreateApplication(pid)

switch args[2] {
case "dump":
    dump(app, max: 14)

case "press":
    guard args.count >= 4 else { die("usage: bg-act <pid> press <selector>") }
    guard let sel = Selector.parse(args[3]) else { die("bad selector: \(args[3])") }
    var target: AXUIElement?
    if sel.kind == .point, let p = sel.point {
        target = elementAtPoint(app: app, x: p.x, y: p.y)
    } else {
        target = walk(app, sel)
    }
    guard let t = target else { die("no element matched: \(args[3])", code: 1) }
    let err = AXUIElementPerformAction(t, kAXPressAction as CFString)
    guard err == .success else {
        // Some elements (text fields) don't support press but might support
        // showMenu or another action. Report and exit non-zero.
        die("AXPress failed: error=\(err.rawValue)", code: 4)
    }
    say("ok pressed: \(args[3])")

case "set-value":
    guard args.count >= 5 else { die("usage: bg-act <pid> set-value <selector|first-textfield> <text>") }
    let sel = args[3]
    let text = args[4]
    var target: AXUIElement?
    if sel == "first-textfield" {
        // Walk and pick the first AXTextField / AXTextArea
        func firstField(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
            if depth > 30 { return nil }
            if let r = axStr(el, kAXRoleAttribute), r == "AXTextField" || r == "AXTextArea" || r == "AXSecureTextField" {
                return el
            }
            for c in axChildren(el) {
                if let hit = firstField(c, depth: depth + 1) { return hit }
            }
            return nil
        }
        target = firstField(app)
    } else {
        guard let parsed = Selector.parse(sel) else { die("bad selector: \(sel)") }
        if parsed.kind == .point, let p = parsed.point {
            target = elementAtPoint(app: app, x: p.x, y: p.y)
        } else {
            target = walk(app, parsed)
        }
    }
    guard let t = target else { die("no field matched: \(sel)", code: 1) }
    let err = AXUIElementSetAttributeValue(t, kAXValueAttribute as CFString, text as CFString)
    guard err == .success else {
        die("set kAXValue failed: error=\(err.rawValue)", code: 4)
    }
    say("ok set-value: \(sel) = \(text)")

default:
    die("unknown subcommand: \(args[2])")
}
