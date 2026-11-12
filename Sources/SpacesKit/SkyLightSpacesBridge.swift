import AppKit
import ColorSync
import OSLog

/// Picks the SkyLight bridge when its SPI resolves, otherwise the documented-API fallback.
public func makeSpacesBridge() -> any SpacesBridge {
    if let sky = SkyLightSpacesBridge() { return sky }
    Logger(subsystem: "app.stacky.SpacesKit", category: "spi").warning("SkyLight SPI unavailable; using public fallback")
    return PublicSpacesBridge()
}

/// Private SkyLight SPI (symbols resolved at runtime in `SPI`). All calls run on one serial queue.
public actor SkyLightSpacesBridge: SpacesBridge {
    private let queue = DispatchSerialQueue(label: "app.stacky.spi")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let log = Logger(subsystem: "app.stacky.SpacesKit", category: "spi")
    private let cid: Int32

    /// Whether the move SPI resolved. Whether the OS *honours* it is only known per call (see `move`).
    public nonisolated let canMoveWindows: Bool

    /// nil when the minimum SPI (connection, current space, window→space lookup) is missing.
    public init?() {
        guard let cid = SPI.connection, SPI.copySpacesForWindows != nil,
              SPI.getActiveSpace != nil || SPI.managedDisplayGetCurrentSpace != nil else { return nil }
        self.cid = cid
        canMoveWindows = SPI.moveWindowsToManagedSpace != nil || SPI.processAssignToSpace != nil
    }

    public func currentSpace() -> SpaceID? {
        if let id = SPI.activeSpace() { return id }
        guard let f = SPI.managedDisplayGetCurrentSpace,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue(),
              let s = CFUUIDCreateString(nil, uuid) else { return nil }
        let id = f(cid, s)
        return id == 0 ? nil : id
    }

    public func layout() -> [DisplaySpaces] {
        let displays = SPI.copyManagedDisplaySpaces?(cid)?.takeRetainedValue() as? [[String: Any]] ?? []
        return displays.compactMap { d in
            guard let id = d["Display Identifier"] as? String,
                  let current = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? SpaceID else { return nil }
            let spaces = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { $0["ManagedSpaceID"] as? SpaceID }
            return DisplaySpaces(display: id, current: current, spaces: spaces)
        }
    }

    public func space(of window: CGWindowID) -> SpaceID? { SPI.spaces(of: window).first }

    /// No SPI switches Spaces cleanly without the Dock scripting addition (SIP off).
    /// Returning false lets the caller raise a window there instead; macOS then follows it.
    public func switchTo(_ space: SpaceID) -> Bool { false }

    /// Returns true only if every window is verifiably on `space` afterwards.
    public func move(_ windows: [CGWindowID], to space: SpaceID) -> Bool {
        guard !windows.isEmpty else { return false }
        if let type = SPI.spaceGetType, type(cid, space) != 0 { // 0 = user desktop; never move into fullscreen/system spaces
            log.warning("Refusing move to non-desktop space \(space)")
            return false
        }
        let pending = { windows.filter { self.space(of: $0) != space } }
        var left = pending()
        if left.isEmpty { return true }

        // Per-window move: macOS 14.5+ honours it only for the caller's own windows.
        SPI.moveWindowsToManagedSpace?(cid, left.map { NSNumber(value: $0) } as CFArray, space)
        left = pending()

        // ponytail: per-process fallback drags *all* of the owning app's windows along, bound or not.
        // No per-window SPI works cross-process (verified on 27.2); upgrade path is the Dock scripting addition.
        if !left.isEmpty, let assign = SPI.processAssignToSpace {
            for pid in Set(left.compactMap(Self.owner)) {
                _ = assign(cid, pid, space)
                _ = assign(cid, pid, 0) // clear, or the app's future windows would keep opening on `space`
            }
            left = pending()
        }
        if !left.isEmpty { log.warning("Space move had no effect on \(left.count) of \(windows.count) windows; OS likely restricts it") }
        return left.isEmpty
    }

    public func setOnAllDesktops(_ pid: pid_t, _ on: Bool) {
        if on {
            _ = SPI.processAssignToAllSpaces?(cid, pid)
        } else if let assign = SPI.processAssignToSpace, let here = currentSpace() {
            _ = assign(cid, pid, here)
            _ = assign(cid, pid, 0) // clear, or the app's later windows would keep opening on `here`
        }
    }

    private static func owner(of window: CGWindowID) -> pid_t? {
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]]
        return info?.first?[kCGWindowOwnerPID as String] as? pid_t
    }
}
