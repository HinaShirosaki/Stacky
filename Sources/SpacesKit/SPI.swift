import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

/// Every private symbol Stacky uses, resolved once with dlsym. Nothing is linked, so a symbol that
/// disappears in an OS update is just nil here, and the feature using it switches off.
enum SPI {
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let hiServices = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)

    private static func sym<T>(_ handle: UnsafeMutableRawPointer?, _ names: String..., as: T.Type) -> T? {
        guard let handle else { return nil }
        for name in names { if let p = dlsym(handle, name) { return unsafeBitCast(p, to: T.self) } }
        return nil
    }

    // SkyLight: SLS* is the current spelling, CGS* the older alias.
    static let mainConnectionID = sym(skyLight, "SLSMainConnectionID", "CGSMainConnectionID",
                                      as: (@convention(c) () -> Int32).self)
    static let getActiveSpace = sym(skyLight, "SLSGetActiveSpace", "CGSGetActiveSpace",
                                    as: (@convention(c) (Int32) -> UInt64).self)
    static let managedDisplayGetCurrentSpace = sym(skyLight, "SLSManagedDisplayGetCurrentSpace", "CGSManagedDisplayGetCurrentSpace",
                                                   as: (@convention(c) (Int32, CFString) -> UInt64).self)
    static let copySpacesForWindows = sym(skyLight, "SLSCopySpacesForWindows", "CGSCopySpacesForWindows",
                                          as: (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?).self)
    static let copyManagedDisplaySpaces = sym(skyLight, "SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces",
                                              as: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self)
    static let moveWindowsToManagedSpace = sym(skyLight, "SLSMoveWindowsToManagedSpace", "CGSMoveWindowsToManagedSpace",
                                               as: (@convention(c) (Int32, CFArray, UInt64) -> Void).self)
    static let spaceGetType = sym(skyLight, "SLSSpaceGetType", "CGSSpaceGetType",
                                  as: (@convention(c) (Int32, UInt64) -> Int32).self)

    /// The Dock's "Assign To: This Desktop": moves *every* window of the process. Space 0 clears the assignment.
    static let processAssignToSpace = sym(skyLight, "SLSProcessAssignToSpace", "CGSProcessAssignToSpace",
                                          as: (@convention(c) (Int32, Int32, UInt64) -> Int32).self)

    // HIServices (Accessibility).
    static let axGetWindow = sym(hiServices, "_AXUIElementGetWindow",
                                 as: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
    static let axCreateWithRemoteToken = sym(hiServices, "_AXUIElementCreateWithRemoteToken",
                                             as: (@convention(c) (CFData) -> Unmanaged<AXUIElement>?).self)

    static let connection: Int32? = mainConnectionID?()

    static func spaces(of window: CGWindowID) -> [SpaceID] {
        guard let cid = connection, let copy = copySpacesForWindows else { return [] }
        let all: Int32 = 0x7 // current | others | user spaces
        let ids = copy(cid, all, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber]
        return ids?.map(\.uint64Value) ?? []
    }

    static func activeSpace() -> SpaceID? {
        guard let cid = connection, let f = getActiveSpace else { return nil }
        let id = f(cid)
        return id == 0 ? nil : id
    }
}

/// Window-level SPI for WindowKit. Every call degrades to nil / empty when its symbols are missing.
public enum WindowSPI {
    private static let log = Logger(subsystem: "app.stacky.SpacesKit", category: "window-spi")

    /// Exact AX element → CGWindowID mapping.
    public static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let get = SPI.axGetWindow else { return nil }
        var id: CGWindowID = 0
        return get(element, &id) == .success && id != 0 ? id : nil
    }

    /// Spaces a window is on; empty for minimized / non-desktop windows or when SPI is missing.
    public static func spaces(of window: CGWindowID) -> [SpaceID] { SPI.spaces(of: window) }

    public static func currentSpace() -> SpaceID? { SPI.activeSpace() }

    private static func role(of element: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    public static var canFindOffSpaceWindows: Bool {
        SPI.axGetWindow != nil && SPI.axCreateWithRemoteToken != nil && SPI.copySpacesForWindows != nil
    }

    /// AX only lists an app's windows on the current Space. This recreates AX elements for the others by
    /// probing remote element tokens (the technique AltTab uses) and returns those whose window ID is wanted.
    /// ponytail: linear probe of element IDs with a time budget; windows whose element ID lies past the budget
    /// in very long-running apps stay invisible until the user visits their Space once.
    public static func offSpaceWindows(pid: pid_t, wanted: Set<CGWindowID>,
                                       maxElementID: UInt64 = 2000, budget: TimeInterval = 0.15) -> [CGWindowID: AXUIElement] {
        guard !wanted.isEmpty, let create = SPI.axCreateWithRemoteToken, SPI.axGetWindow != nil else { return [:] }
        // Token layout: pid (Int32), 0 (Int32), 'coco' (Int32), element ID (UInt64).
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: pid, toByteOffset: 0, as: Int32.self)
            raw.storeBytes(of: 0, toByteOffset: 4, as: Int32.self)
            raw.storeBytes(of: 0x636F_636F, toByteOffset: 8, as: Int32.self)
        }
        let deadline = Date().addingTimeInterval(budget)
        var found: [CGWindowID: AXUIElement] = [:]
        for elementID in UInt64(0)..<maxElementID {
            if found.count == wanted.count || Date() > deadline { break }
            token.withUnsafeMutableBytes { $0.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self) }
            // _AXUIElementGetWindow also answers for elements *inside* a window (toolbars, buttons),
            // so only the window element itself counts, and the first one wins.
            guard let element = create(token as CFData)?.takeRetainedValue(),
                  let id = windowID(of: element), wanted.contains(id), found[id] == nil,
                  role(of: element) == kAXWindowRole else { continue }
            found[id] = element
        }
        if found.count < wanted.count {
            log.debug("pid \(pid): found \(found.count) of \(wanted.count) off-Space windows")
        }
        return found
    }
}
