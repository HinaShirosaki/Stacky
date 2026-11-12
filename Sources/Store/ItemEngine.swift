import AppKit
import CoreGraphics
import Foundation
import Observation
import OSLog
import WindowKit
import SpacesKit
import LaunchKit

public enum EngineError: LocalizedError {
    case noFrontmostWindow
    public var errorDescription: String? { "No window to bind. Click the window you want first." }
}

/// Item state machine + view model. Lives on the main actor; all AX/SPI work is awaited on their own executors.
@MainActor @Observable
public final class ItemEngine {
    public private(set) var items: [Item]
    /// The desktops currently showing, one per monitor.
    public private(set) var visibleSpaces: Set<SpaceID> = []
    /// Workspaces with a window on a desktop that isn't showing: there is somewhere to go.
    public private(set) var away: Set<Item.ID> = []
    /// Workspaces with a linked file or app that has no window: there is something to open.
    public private(set) var unopened: Set<Item.ID> = []
    public var lastError: String?
    /// Bundle IDs of apps every workspace uses (Mail, chat, music). Their windows show on every desktop and
    /// are never folded or moved for one workspace, since that would take them away from the others.
    public private(set) var sharedApps: Set<String> {
        didSet { UserDefaults.standard.set(sharedApps.sorted(), forKey: "sharedApps") }
    }
    public var defaultStrategy: FoldStrategyKind {
        didSet { UserDefaults.standard.set(defaultStrategy.rawValue, forKey: "foldStrategy") }
    }

    @ObservationIgnored private let windows: any WindowProvider
    @ObservationIgnored private let spaces: any SpacesBridge
    @ObservationIgnored private let launcher: any Launching
    @ObservationIgnored private let store: ItemStore
    @ObservationIgnored private var busy: Set<Item.ID> = []
    @ObservationIgnored private let unfoldSettle: Duration
    /// (window title, bundle ID) → file, for windows without an Accessibility document.
    @ObservationIgnored private let documentFinder: (String, String) -> URL?
    /// Whether a saved frame still lands on a connected monitor.
    @ObservationIgnored private let isOnScreen: (CGRect) -> Bool
    @ObservationIgnored private let log = Logger(subsystem: "app.stacky.Store", category: "engine")

    public init(windows: any WindowProvider, spaces: any SpacesBridge, launcher: any Launching, store: ItemStore,
                unfoldSettle: Duration = .milliseconds(400),
                documentFinder: @escaping (String, String) -> URL? = DocumentFinder.file(forWindowTitled:bundleID:),
                isOnScreen: @escaping (CGRect) -> Bool = { frame in
                    var count: UInt32 = 0
                    return CGGetDisplaysWithRect(frame, 0, nil, &count) == .success && count > 0
                }) {
        self.documentFinder = documentFinder
        self.isOnScreen = isOnScreen
        self.unfoldSettle = unfoldSettle
        self.windows = windows
        self.spaces = spaces
        self.launcher = launcher
        self.store = store
        items = store.load()
        sharedApps = Set(UserDefaults.standard.stringArray(forKey: "sharedApps") ?? [])
        defaultStrategy = UserDefaults.standard.string(forKey: "foldStrategy").flatMap(FoldStrategyKind.init) ?? .minimize
        // One-time upgrade of workspaces saved by earlier versions. Not repeated, so an app the user removes
        // from a workspace afterwards stays removed.
        if !UserDefaults.standard.bool(forKey: "linkedAppsOfWindows") {
            for i in items.indices { items[i].linkAppsOfWindows() }
            if (try? store.save(items)) != nil { UserDefaults.standard.set(true, forKey: "linkedAppsOfWindows") }
        }
    }

    // MARK: - Editing

    public func addItem(named name: String) {
        items.append(Item(name: name))
        save()
    }

    public func removeItem(_ id: Item.ID) {
        items.removeAll { $0.id == id }
        save()
    }

    public func addPayloads(_ payloads: [LaunchPayload], to id: Item.ID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].payloads += payloads.filter { !items[i].payloads.contains($0) }
        save()
    }

    public func removeWindow(_ window: BoundWindow.ID, from id: Item.ID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].windows.removeAll { $0.id == window }
        save()
    }

    public func removePayload(_ payload: LaunchPayload, from id: Item.ID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].payloads.removeAll { $0 == payload }
        save()
    }

    /// Linking a window also links the file it shows, so the item can reopen it after the app quits.
    private func link(_ w: LiveWindow, to item: inout Item) {
        item.windows.append(BoundWindow(fingerprint: WindowFingerprint(w)))
        // An editor window with a folder open is recovered by its folder, not by whichever file is in front.
        // Otherwise the window's own document (a directory for Terminal), reopened in the same app; apps
        // that expose none get a lookup by window title.
        let target = EditorFolders.folder(bundleID: w.bundleID, title: w.title)
            ?? w.documentURL.flatMap { $0.isFileURL ? $0 : nil }
            ?? documentFinder(w.title, w.bundleID)
        // A window with no file behind it (Calculator, Mail, a browser) still links its app, so a click on the
        // workspace can at least bring the app back after it quit.
        let payload = target.map { LaunchPayload.folder($0, app: w.bundleID) } ?? .app(bundleID: w.bundleID)
        if !item.payloads.contains(payload) { item.payloads.append(payload) }
    }

    public func bindFrontmostWindow(to id: Item.ID) async {
        await run(id) { item in
            guard let w = try await self.windows.frontmostWindow() else { throw EngineError.noFrontmostWindow }
            let already = Rebinder.match(item.windows.map(\.fingerprint), to: [w]).isEmpty == false
            if !already { self.link(w, to: &item) }
        }
    }

    /// Every window the provider can see, front-most first.
    public func liveWindows() async -> [LiveWindow] {
        do {
            return try await windows.windows().sorted { $0.zOrder < $1.zOrder }
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    /// Links `window` to the item, or unlinks it if already linked. `live` must be the list it came from,
    /// so the same assignment the UI shows decides which binding gets removed.
    public func toggleWindow(_ window: LiveWindow, among live: [LiveWindow], in id: Item.ID) async {
        await run(id) { item in
            let linked = Rebinder.match(item.windows.map(\.fingerprint), to: live)
            if let i = linked.first(where: { $0.value.ref == window.ref })?.key {
                item.windows.remove(at: i)
            } else {
                self.link(window, to: &item)
            }
        }
    }

    /// Link mode: links the window under `point` (global, top-left origin) unless already linked.
    /// Returns the window hit, or nil if there was nothing linkable there.
    @discardableResult
    public func linkWindow(at point: CGPoint, to id: Item.ID) async -> LiveWindow? {
        guard let wid = await windows.windowID(at: point) else { return nil }
        var hit: LiveWindow?
        await run(id) { item in
            let live = try await self.windows.windows()
            guard let w = live.first(where: { $0.windowID == wid }) else { return }
            hit = w
            let linked = Rebinder.match(item.windows.map(\.fingerprint), to: live)
            if !linked.values.contains(where: { $0.ref == w.ref }) { self.link(w, to: &item) }
        }
        return hit
    }

    // MARK: - Shared apps

    public func setShared(_ bundleID: String, _ shared: Bool) async {
        if shared { sharedApps.insert(bundleID) } else { sharedApps.remove(bundleID) }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            await spaces.setOnAllDesktops(app.processIdentifier, shared)
        }
    }

    /// The all-desktops assignment belongs to a running process, so it is applied again whenever Stacky or
    /// a shared app starts.
    public func pinSharedApps() async {
        for id in sharedApps {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                await spaces.setOnAllDesktops(app.processIdentifier, true)
            }
        }
    }

    /// The windows a workspace may fold or move: everything linked except shared apps' windows.
    private func own(_ bound: [(index: Int, window: LiveWindow)]) -> [(index: Int, window: LiveWindow)] {
        bound.filter { !sharedApps.contains($0.window.bundleID) }
    }

    /// Where each workspace stands right now; decides whether its card offers Go / Open at all.
    public func refreshStatus() async {
        await refreshSpace()
        guard let live = try? await windows.windows() else { return }
        var away: Set<Item.ID> = [], unopened: Set<Item.ID> = []
        for item in items {
            let matched = Array(Rebinder.match(item.windows.map(\.fingerprint), to: live).values)
            for w in matched where !sharedApps.contains(w.bundleID) {
                if let id = w.windowID, let space = await spaces.space(of: id), !visibleSpaces.contains(space) {
                    away.insert(item.id)
                    break
                }
            }
            if !item.pendingPayloads(live: matched).isEmpty { unopened.insert(item.id) }
        }
        self.away = away
        self.unopened = unopened
    }

    public func refreshSpace() async {
        let shown = await spaces.layout().map(\.current)
        if let active = await spaces.currentSpace() { visibleSpaces = Set(shown + [active]) } else { visibleSpaces = Set(shown) }
    }

    // MARK: - Fold / release / activate

    public func fold(_ id: Item.ID) async { await run(id) { try await self.fold(&$0) } }
    public func release(_ id: Item.ID) async { await run(id) { try await self.release(&$0) } }
    public func activate(_ id: Item.ID) async { await run(id) { try await self.activate(&$0) } }

    private func fold(_ item: inout Item) async throws {
        guard case .released = item.state else { return }
        let kind = item.foldStrategy ?? defaultStrategy
        let bound = own(try await rebind(&item))
        for (i, w) in bound {
            item.windows[i].savedFrame = w.frame
            item.windows[i].savedZ = w.zOrder
            if let wid = w.windowID { item.windows[i].savedSpace = await spaces.space(of: wid) }
        }
        try await kind.strategy.fold(bound.map(\.window), using: windows)
        item.state = .folded(by: kind)
    }

    private func release(_ item: inout Item) async throws {
        guard case .folded(let kind) = item.state else { return }
        let active = await spaces.currentSpace()
        let layout = await spaces.layout()
        let bound = own(try await rebind(&item))
        // Each window returns to the monitor it was folded on, onto whatever desktop that monitor shows now.
        // A window whose monitor is gone (or unknown) comes to the desktop in front of the user.
        var groups: [SpaceID: [CGWindowID]] = [:]
        for b in bound {
            guard let id = b.window.windowID ?? item.windows[b.index].fingerprint.lastWindowID else { continue }
            let saved = item.windows[b.index].savedSpace
            let monitor = layout.first { d in saved.map(d.spaces.contains) ?? false }
            if let target = monitor?.current ?? active { groups[target, default: []].append(id) }
        }
        func moveAll() async {
            guard spaces.canMoveWindows else { return }
            for (space, ids) in groups.sorted(by: { $0.key < $1.key }) { _ = await spaces.move(ids, to: space) }
        }
        // Move while still folded so windows reappear in place, not on the Space they were folded from;
        // again after unfolding for windows that only became movable then (no-op when already there).
        await moveAll()
        // Unfold back to front: a window lands on top as it reappears, so the stack rebuilds in order.
        try await kind.strategy.unfold(backToFront(item, bound).map(\.window), using: windows)
        try? await Task.sleep(for: unfoldSettle) // un-minimize animates; raising mid-animation is ignored
        await moveAll()
        for (i, w) in bound {
            // A frame on a monitor that is no longer connected would put the window out of reach.
            if let f = item.windows[i].savedFrame, isOnScreen(f) { try await attempt { try await self.windows.setFrame(f, w.ref) } }
        }
        // Home = where most of the item ended up. Since macOS 14.5 the OS may refuse the move: windows then
        // reappear on the Space they were folded from, so record where they really are.
        let main = groups.max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }
        var home = main?.key ?? active
        if let first = main?.value.first, let actual = await spaces.space(of: first), actual != home {
            let name = item.name
            log.info("\(name, privacy: .public): windows stayed on space \(actual); following them")
            home = actual
        }
        try await raise(item, bound)
        item.state = .released(spaceID: home)
        await refreshSpace()
    }

    /// The card's click: go to the workspace. Gathers its windows on the desktop that already holds most
    /// of them, goes there, and opens whatever linked file has no window. Windows keep their stacking order.
    private func activate(_ item: inout Item) async throws {
        let bound: [(index: Int, window: LiveWindow)]
        if item.isFolded {
            try await release(&item) // unfolds onto the current desktop and raises
            bound = try await rebind(&item)
        } else {
            bound = try await rebind(&item)
            let active = await spaces.currentSpace()
            let layout = await spaces.layout()
            var location: [CGWindowID: SpaceID] = [:]
            for b in own(bound) {
                if let id = b.window.windowID, let space = await spaces.space(of: id) { location[id] = space }
            }
            // Monitors are handled one by one: a window never changes monitor, only desktop.
            var perMonitor: [String: [CGWindowID]] = [:]
            for (id, space) in location {
                perMonitor[layout.first { $0.spaces.contains(space) }?.display ?? "", default: []].append(id)
            }
            var home: (space: SpaceID, count: Int)?
            for (monitor, ids) in perMonitor.sorted(by: { $0.key < $1.key }) {
                let current = layout.first { $0.display == monitor }?.current ?? active
                var counts: [SpaceID: Int] = [:]
                for id in ids { counts[location[id]!, default: 0] += 1 }
                // Most windows wins; on a tie, the desktop already showing beats travelling.
                func rank(_ e: (key: SpaceID, value: Int)) -> Int { e.value * 2 + (e.key == current ? 1 : 0) }
                guard let target = counts.max(by: { rank($0) < rank($1) })?.key else { continue }
                let strays = ids.filter { location[$0] != target }.sorted()
                if !strays.isEmpty, spaces.canMoveWindows { _ = await spaces.move(strays, to: target) }
                if target != current, !(await spaces.switchTo(target)) {
                    // No SPI switches desktops: raising a window there makes macOS follow it. Raise only the
                    // workspace's own front window, so nothing is reordered within the workspace.
                    let there = bound.filter { $0.window.windowID.flatMap { location[$0] } == target }
                    if let front = there.min(by: { $0.window.zOrder < $1.window.zOrder }) {
                        try await attempt { try await self.windows.raise(front.window.ref) }
                    }
                }
                if ids.count > home?.count ?? 0 { home = (target, ids.count) }
            }
            if let home {
                item.state = .released(spaceID: home.space)
                await refreshSpace()
            }
        }
        launcher.launch(item.pendingPayloads(live: bound.map(\.window)))
    }

    // MARK: - Helpers

    /// The item's windows from the bottom of the stack to the top, as saved at fold time.
    private func backToFront(_ item: Item, _ bound: [(index: Int, window: LiveWindow)]) -> [(index: Int, window: LiveWindow)] {
        bound.sorted {
            (item.windows[$0.index].savedZ ?? $0.window.zOrder) > (item.windows[$1.index].savedZ ?? $1.window.zOrder)
        }
    }

    /// Raises back to front, so the windows end up stacked as they were and the topmost one is focused.
    /// Each raise activates the window's app; the pause lets that land before the next app is activated,
    /// otherwise macOS drops the later activations and windows of different apps end up out of order.
    private func raise(_ item: Item, _ bound: [(index: Int, window: LiveWindow)]) async throws {
        for b in backToFront(item, bound) {
            try await attempt { try await self.windows.raise(b.window.ref) }
            try? await Task.sleep(for: unfoldSettle / 4)
        }
    }

    /// Re-identifies bound windows and refreshes their fingerprints so title drift is tracked.
    private func rebind(_ item: inout Item) async throws -> [(index: Int, window: LiveWindow)] {
        let matches = Rebinder.match(item.windows.map(\.fingerprint), to: try await windows.windows())
        for (i, w) in matches {
            var fp = WindowFingerprint(w)
            fp.lastWindowID = fp.lastWindowID ?? item.windows[i].fingerprint.lastWindowID // don't lose a known ID
            item.windows[i].fingerprint = fp
        }
        return matches.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Serializes operations per item and commits only on success.
    private func run(_ id: Item.ID, _ body: (inout Item) async throws -> Void) async {
        guard !busy.contains(id), var item = items.first(where: { $0.id == id }) else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            try await body(&item)
            guard let i = items.firstIndex(where: { $0.id == id }) else { return } // deleted meanwhile
            items[i] = item
            lastError = nil
            save()
            await refreshStatus()
        } catch {
            log.error("\(item.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            lastError = "\(item.name): \(error.localizedDescription)"
        }
    }

    private func save() {
        do { try store.save(items) } catch {
            log.error("Save failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
