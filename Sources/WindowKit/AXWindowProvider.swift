import AppKit
import ApplicationServices
import OSLog
import SpacesKit

/// Accessibility-backed provider. Every AX call runs on one dedicated serial queue, never the main actor.
public actor AXWindowProvider: WindowProvider {
    private let queue = DispatchSerialQueue(label: "app.stacky.ax")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var cache: [WindowHandle: AXUIElement] = [:]
    /// Off-Space windows found by probing, reused while still valid (probing is the expensive part).
    private var offSpaceElements: [CGWindowID: AXUIElement] = [:]
    /// Off-Space window IDs probing couldn't turn into standard AX windows (toolbars, panels): don't re-probe.
    private var unprobeable: Set<CGWindowID> = []
    private let log = Logger(subsystem: "app.stacky.WindowKit", category: "ax")

    public init() {
        // Global AX timeout: hung apps fail fast (kAXErrorCannotComplete) instead of blocking the queue.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
    }

    public func windows() throws -> [LiveWindow] {
        guard AXIsProcessTrusted() else { throw WindowError.notTrusted }
        // Only the on-screen list is in stacking order; the full list is not. Windows that are on screen take
        // their rank from it, the rest (other desktops, minimized) queue up behind in list order.
        let front = Dictionary(Self.cgWindows(onScreenOnly: true).map { ($0.id, $0.z) }, uniquingKeysWith: { a, _ in a })
        let cg = Self.cgWindows(onScreenOnly: false).map { w in
            CGWin(id: w.id, pid: w.pid, bounds: w.bounds, title: w.title, z: front[w.id] ?? front.count + w.z)
        }
        let me = getpid()
        let current = WindowSPI.currentSpace()
        var out: [LiveWindow] = []
        var fresh: [WindowHandle: AXUIElement] = [:]

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != me {
            guard let bundleID = app.bundleIdentifier else { continue }
            let pid = app.processIdentifier
            // Apps that ignore AX or time out simply contribute no windows.
            guard let axWindows = windowElements(of: pid) else { continue }
            var standard = axWindows.filter(isStandardWindow)
            var pool = cg.filter { $0.pid == pid }
            standard += offSpaceWindows(pid: pid, pool: pool, seen: Set(standard.compactMap(WindowSPI.windowID(of:))), current: current)

            for (index, w) in standard.enumerated() {
                guard let frame = frame(of: w) else { continue }
                let title: String = attribute(w, kAXTitleAttribute) ?? ""
                // Exact ID via SPI; fall back to pid + bounds (+ title if Screen Recording grants it).
                let exact = WindowSPI.windowID(of: w)
                let hit = exact.flatMap { id in pool.firstIndex { $0.id == id } }
                    ?? pool.firstIndex { $0.bounds == frame && ($0.title == nil || $0.title == title) }
                    ?? pool.firstIndex { $0.bounds == frame }
                let cgw = hit.map { pool.remove(at: $0) }
                let ref = WindowHandle(pid: pid, key: Int(bitPattern: CFHash(w)))
                fresh[ref] = w
                out.append(LiveWindow(
                    ref: ref, windowID: cgw?.id ?? exact, bundleID: bundleID, title: title,
                    documentURL: (attribute(w, kAXDocumentAttribute) as String?).flatMap(URL.init(string:)),
                    index: index, frame: frame,
                    isMinimized: attribute(w, kAXMinimizedAttribute) ?? false,
                    zOrder: cgw?.z ?? .max))
            }
        }
        cache = fresh
        return out
    }

    public func frontmostWindow() throws -> LiveWindow? {
        let all = try windows()
        let byID = Dictionary(all.compactMap { w in w.windowID.map { ($0, w) } }, uniquingKeysWith: { a, _ in a })
        return Self.cgWindows(onScreenOnly: true).lazy.compactMap { byID[$0.id] }.first
    }

    public func setMinimized(_ minimized: Bool, _ ref: WindowHandle) throws {
        let value: CFBoolean = minimized ? kCFBooleanTrue : kCFBooleanFalse
        try check(AXUIElementSetAttributeValue(element(ref), kAXMinimizedAttribute as CFString, value))
    }

    public func setFrame(_ frame: CGRect, _ ref: WindowHandle) throws {
        let e = try element(ref)
        var origin = frame.origin, size = frame.size
        let pos = AXValueCreate(.cgPoint, &origin)!, sz = AXValueCreate(.cgSize, &size)!
        // Size twice: apps clamp size against the screen at the *old* position.
        try check(AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, sz))
        try check(AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, pos))
        try check(AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, sz))
    }

    public func raise(_ ref: WindowHandle) throws {
        try check(AXUIElementPerformAction(element(ref), kAXRaiseAction as CFString))
        NSRunningApplication(processIdentifier: ref.pid)?.activate()
    }

    public func setHidden(_ hidden: Bool, pid: pid_t) throws {
        guard let app = NSRunningApplication(processIdentifier: pid) else { throw WindowError.windowGone }
        _ = hidden ? app.hide() : app.unhide()
    }

    public func windowID(at point: CGPoint) -> CGWindowID? {
        let me = getpid()
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for d in list { // front to back, all layers
            guard let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.contains(point),
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue } // invisible overlays don't count
            // Whatever is on top decides: menu bar, panels and our own windows link nothing...
            guard (d[kCGWindowLayer as String] as? Int) == 0, (d[kCGWindowOwnerPID as String] as? pid_t) != me else {
                // ...except display-sized system overlays (Dock, Notification Center, Screenshot), which are
                // transparent yet report alpha 1 and would otherwise swallow every click.
                // ponytail: a click on the Dock bar itself links the window behind it.
                if NSScreen.screens.contains(where: { $0.frame.size == r.size }), (d[kCGWindowLayer as String] as? Int) != 0 { continue }
                return nil
            }
            return d[kCGWindowNumber as String] as? CGWindowID
        }
        return nil
    }

    // MARK: - Off-Space windows

    /// Plain AX lists only windows on the current Space (plus minimized ones). CG still knows the others;
    /// for each such window of `pid` that sits on another Space, recover its AX element.
    private func offSpaceWindows(pid: pid_t, pool: [CGWin], seen: Set<CGWindowID>, current: SpaceID?) -> [AXUIElement] {
        guard WindowSPI.canFindOffSpaceWindows, let current else { return [] }
        let offSpace = pool.map(\.id).filter { id in
            guard !seen.contains(id), !unprobeable.contains(id) else { return false }
            let spaces = WindowSPI.spaces(of: id)
            return !spaces.isEmpty && !spaces.contains(current)
        }
        guard !offSpace.isEmpty else { return [] }

        var result: [AXUIElement] = []
        var missing = Set<CGWindowID>()
        for id in offSpace {
            // A cached element is still good if it still answers for the same window.
            if let e = offSpaceElements[id], WindowSPI.windowID(of: e) == id { result.append(e) } else { missing.insert(id) }
        }
        if !missing.isEmpty {
            let found = WindowSPI.offSpaceWindows(pid: pid, wanted: missing)
            for (id, e) in found where isStandardWindow(e) {
                offSpaceElements[id] = e
                result.append(e)
            }
            // Found but not a standard window, or not found within the probe budget: stop asking.
            unprobeable.formUnion(missing.subtracting(found.filter { isStandardWindow($0.value) }.keys))
        }
        return result
    }

    /// An app's AX windows. An app that is busy answers "cannot complete"; skipping it would make its windows
    /// vanish from this enumeration (a release would then leave them folded), so it gets two more chances.
    private func windowElements(of pid: pid_t) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(pid)
        for attempt in 0..<3 {
            var value: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            if err == .success { return value as? [AXUIElement] }
            guard err == .cannotComplete, attempt < 2 else { break }
            usleep(150_000)
        }
        return nil
    }

    private func isStandardWindow(_ e: AXUIElement) -> Bool {
        let subrole: String? = attribute(e, kAXSubroleAttribute)
        if subrole == kAXStandardWindowSubrole { return true }
        // macOS 27 reports a minimized standard window as AXDialog. Dropping it would make every folded
        // window invisible to release. Real dialogs can't be minimized, so this admits nothing else.
        return subrole == kAXDialogSubrole && (attribute(e, kAXMinimizedAttribute) ?? false)
    }

    // MARK: - AX plumbing

    private func element(_ ref: WindowHandle) throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw WindowError.notTrusted }
        guard let e = cache[ref] else { throw WindowError.windowGone }
        return e
    }

    private func check(_ err: AXError) throws {
        switch err {
        case .success: return
        case .apiDisabled: throw WindowError.notTrusted
        case .invalidUIElement: throw WindowError.windowGone
        default:
            log.error("AX error \(err.rawValue)")
            throw WindowError.ax(err.rawValue)
        }
    }

    private func attribute<T>(_ e: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    private func frame(of e: AXUIElement) -> CGRect? {
        func axValue(_ name: String) -> AXValue? {
            guard let v: CFTypeRef = attribute(e, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
            return (v as! AXValue)
        }
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv = axValue(kAXPositionAttribute), AXValueGetValue(pv, .cgPoint, &p),
              let sv = axValue(kAXSizeAttribute), AXValueGetValue(sv, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private struct CGWin { let id: CGWindowID; let pid: pid_t; let bounds: CGRect; let title: String?; let z: Int }

    /// Layer-0 windows, front to back.
    private static func cgWindows(onScreenOnly: Bool) -> [CGWin] {
        let opts: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.enumerated().compactMap { z, d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: b) else { return nil }
            return CGWin(id: id, pid: pid, bounds: bounds, title: d[kCGWindowName as String] as? String, z: z)
        }
    }
}
