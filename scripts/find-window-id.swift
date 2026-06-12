// find-window-id.swift — print the CGWindowID of an app's main window.
//
// Usage: swift find-window-id.swift <process-name>
// Outputs a single integer on success, or nothing on failure (exit 1).
//
// Why: `screencapture -l <winID>` captures a specific window regardless
// of Space / occlusion, but macOS doesn't expose CGWindowID through
// Accessibility API or AppleScript. CoreGraphics is the canonical source.

import Cocoa
import CoreGraphics

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: find-window-id <process-name>\n".data(using: .utf8)!)
    exit(2)
}
let targetName = CommandLine.arguments[1].lowercased()

let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly)
guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}

// Pick the largest window belonging to the matching process, skipping
// layer != 0 (menu bar, dock) and tiny helper windows.
var bestID: Int? = nil
var bestArea: CGFloat = 0
for w in info {
    let owner = (w[kCGWindowOwnerName as String] as? String)?.lowercased() ?? ""
    guard owner == targetName || owner.contains(targetName) else { continue }
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    guard layer == 0 else { continue }
    let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let width = bounds["Width"] ?? 0
    let height = bounds["Height"] ?? 0
    let area = width * height
    if area > bestArea {
        bestArea = area
        bestID = w[kCGWindowNumber as String] as? Int
    }
}

if let id = bestID {
    print(id)
} else {
    exit(1)
}
