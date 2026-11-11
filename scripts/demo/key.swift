// key type <text> | key code <keycode> [ctrl|cmd]   — types text slowly, or presses one key (123/124 = left/right arrow, 36 = return, 53 = esc)
import CoreGraphics
import Foundation
let a = CommandLine.arguments
func press(_ code: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        e.flags = flags
        if let text { var u = Array(text.utf16); e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u) }
        e.post(tap: .cghidEventTap); usleep(20_000)
    }
}
if a[1] == "type" { for ch in a[2] { press(0, text: String(ch)); usleep(70_000) } }
else { press(CGKeyCode(a[2])!, flags: a.count > 3 ? (a[3] == "cmd" ? .maskCommand : .maskControl) : []) }
