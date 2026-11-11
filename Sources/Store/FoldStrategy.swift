import OSLog
import WindowKit

public enum FoldStrategyKind: String, Codable, CaseIterable, Sendable {
    case minimize, appHide
    // A SkyLight "parking Space" strategy was specced but dropped: since macOS 14.5 the window server refuses
    // Space changes to other processes' windows (verified on 27.0.1: SpaceCreate + add/remove and managed moves
    // both no-op unless the caller owns the window).

    /// Unknown values (e.g. the removed `parkingSpace`) decode as `.minimize` instead of failing the whole store.
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .minimize
    }

    var strategy: any FoldStrategy {
        switch self {
        case .minimize: MinimizeFold()
        case .appHide: AppHideFold()
        }
    }
}

public protocol FoldStrategy {
    func fold(_ windows: [LiveWindow], using provider: any WindowProvider) async throws
    func unfold(_ windows: [LiveWindow], using provider: any WindowProvider) async throws
}

public struct MinimizeFold: FoldStrategy {
    public func fold(_ windows: [LiveWindow], using p: any WindowProvider) async throws {
        for w in windows { try await attempt { try await p.setMinimized(true, w.ref) } }
    }
    public func unfold(_ windows: [LiveWindow], using p: any WindowProvider) async throws {
        for w in windows { try await attempt { try await p.setMinimized(false, w.ref) } }
    }
}

/// Coarsest: hides every window of each owning app, bound or not.
public struct AppHideFold: FoldStrategy {
    public func fold(_ windows: [LiveWindow], using p: any WindowProvider) async throws {
        for pid in Set(windows.map(\.ref.pid)) { try await attempt { try await p.setHidden(true, pid: pid) } }
    }
    public func unfold(_ windows: [LiveWindow], using p: any WindowProvider) async throws {
        for pid in Set(windows.map(\.ref.pid)) { try await attempt { try await p.setHidden(false, pid: pid) } }
    }
}

private let log = Logger(subsystem: "app.stacky.Store", category: "fold")

/// Per-window failures (vanished window, app ignoring AX) are logged and skipped; lost permission aborts.
func attempt(_ op: () async throws -> Void) async throws {
    do { try await op() }
    catch WindowError.notTrusted { throw WindowError.notTrusted }
    catch { log.warning("Window op skipped: \(error.localizedDescription, privacy: .public)") }
}
