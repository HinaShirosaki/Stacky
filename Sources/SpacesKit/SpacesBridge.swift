import CoreGraphics

public typealias SpaceID = UInt64

/// One monitor and its desktops. With "Displays have separate Spaces" on (the default) every monitor has
/// its own list; with it off there is a single entry covering all monitors.
public struct DisplaySpaces: Sendable, Equatable {
    public var display: String
    /// The desktop this monitor is showing.
    public var current: SpaceID
    public var spaces: [SpaceID]
    public init(display: String, current: SpaceID, spaces: [SpaceID]) {
        self.display = display; self.current = current; self.spaces = spaces
    }
}

/// The only door to Spaces. SPI implementations live behind this; callers must tolerate nil/false.
public protocol SpacesBridge: Sendable {
    var canMoveWindows: Bool { get }
    /// The desktop showing on the monitor with keyboard focus.
    func currentSpace() async -> SpaceID?
    /// Every monitor with its desktops; empty when unknown.
    func layout() async -> [DisplaySpaces]
    func space(of window: CGWindowID) async -> SpaceID?
    func switchTo(_ space: SpaceID) async -> Bool
    func move(_ windows: [CGWindowID], to space: SpaceID) async -> Bool
}

/// Documented-API fallback: macOS exposes no Space IDs publicly, so everything is "unknown".
/// Raising a window via AX still makes macOS switch to its Space (default System Settings).
public struct PublicSpacesBridge: SpacesBridge {
    public init() {}
    public var canMoveWindows: Bool { false }
    public func currentSpace() async -> SpaceID? { nil }
    public func layout() async -> [DisplaySpaces] { [] }
    public func space(of window: CGWindowID) async -> SpaceID? { nil }
    public func switchTo(_ space: SpaceID) async -> Bool { false }
    public func move(_ windows: [CGWindowID], to space: SpaceID) async -> Bool { false }
}
