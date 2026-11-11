// click <x> <y> [move-seconds]: glides the pointer to a point (in screen points) and left-clicks there.
import CoreGraphics
import Foundation
let a = CommandLine.arguments
let to = CGPoint(x: Double(a[1])!, y: Double(a[2])!), secs = a.count > 3 ? Double(a[3])! : 0.5
let from = CGEvent(source: nil)!.location
let steps = max(1, Int(secs * 60))
for i in 1...steps {
    let t = Double(i) / Double(steps), e = t * t * (3 - 2 * t) // ease in-out
    let p = CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(16_000)
}
usleep(150_000)
for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: to, mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(60_000)
}
