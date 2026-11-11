// hover <x> <y>: moves the pointer without clicking
import CoreGraphics
import Foundation
let p = CGPoint(x: Double(CommandLine.arguments[1])!, y: Double(CommandLine.arguments[2])!)
let from = CGEvent(source: nil)!.location
for i in 1...30 {
    let t = Double(i) / 30
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: from.x + (p.x - from.x) * t, y: from.y + (p.y - from.y) * t), mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(12_000)
}
