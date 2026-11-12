import Foundation
import OSLog
import WindowKit
import SpacesKit
import LaunchKit

public struct BoundWindow: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var fingerprint: WindowFingerprint
    // Captured at fold time so release is faithful.
    public var savedFrame: CGRect?
    public var savedSpace: SpaceID?
    public var savedZ: Int?

    public init(fingerprint: WindowFingerprint) { self.fingerprint = fingerprint }
}

public enum ItemState: Codable, Hashable, Sendable {
    /// spaceID = home Space; nil when the Spaces bridge can't tell.
    case released(spaceID: SpaceID?)
    /// Remembers the strategy used, so release undoes the right thing even if settings changed meanwhile.
    case folded(by: FoldStrategyKind)
}

public struct Item: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var windows: [BoundWindow] = []
    public var payloads: [LaunchPayload] = []
    public var state: ItemState = .released(spaceID: nil)
    /// Per-item override of the default strategy.
    public var foldStrategy: FoldStrategyKind?

    public init(name: String) { self.name = name }

    public var isFolded: Bool { if case .folded = state { true } else { false } }

    /// Adds the app of every linked window that nothing in the item would reopen. Workspaces saved before
    /// linking a window also linked its app need this once, or a quit app (a browser, say) never comes back.
    mutating func linkAppsOfWindows() {
        for id in windows.map(\.fingerprint.bundleID) {
            let covered = payloads.contains { p in
                switch p {
                case .app(let app), .folder(_, let app): app == id
                case .file, .url: false
                }
            }
            if !covered { payloads.append(.app(bundleID: id)) }
        }
    }

    /// Idempotent launch: skip payloads that already have a live window bound to this item.
    func pendingPayloads(live: [LiveWindow]) -> [LaunchPayload] {
        /// A window already shows `url`: by its document, or (apps that expose none) by its name in the title.
        func isOpen(_ url: URL, in app: String?) -> Bool {
            let name = url.deletingPathExtension().lastPathComponent
            return live.contains { w in
                (app == nil || w.bundleID == app)
                    && (w.documentURL?.standardizedFileURL == url.standardizedFileURL
                        || (name.count >= 3 && w.title.localizedCaseInsensitiveContains(name)))
            }
        }
        return payloads.filter { p in
            switch p {
            case .file(let url): !isOpen(url, in: nil)
            case .app(let id): !live.contains { $0.bundleID == id }
            case .folder(let url, let app): !isOpen(url, in: app)
            // ponytail: "tab already open" approximated by "browser window bound"; per-tab check needs AppleScript.
            case .url(_, let browser): !live.contains { $0.bundleID == browser }
            }
        }
    }
}

/// JSON file in Application Support.
public struct ItemStore: Sendable {
    public let url: URL
    private static let log = Logger(subsystem: "app.stacky.Store", category: "persistence")

    public init(url: URL) { self.url = url }

    public static var `default`: ItemStore {
        // STACKY_STORE points the app at another file: demo data for screenshots, or a scratch store while developing.
        if let path = ProcessInfo.processInfo.environment["STACKY_STORE"] { return ItemStore(url: URL(fileURLWithPath: path)) }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let new = dir.appending(path: "Stacky"), old = dir.appending(path: "Kanade")
        // The app was called Kanade; carry its folder over once. Fails harmlessly if either side is missing or new exists.
        try? FileManager.default.moveItem(at: old, to: new)
        return ItemStore(url: new.appending(path: "items.json"))
    }

    public func load() -> [Item] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try JSONDecoder().decode([Item].self, from: Data(contentsOf: url))
        } catch {
            // Never silently overwrite user data: move the bad file aside first.
            let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: backup)
            Self.log.error("Unreadable store moved to \(backup.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    public func save(_ items: [Item]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(items).write(to: url, options: .atomic)
    }
}
