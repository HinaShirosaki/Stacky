import XCTest
import WindowKit
import SpacesKit
import LaunchKit
@testable import Store

actor MockWindows: WindowProvider {
    var live: [LiveWindow]
    var front: String?
    var trusted = true
    var calls: [String] = []
    var under: CGWindowID?

    init(_ live: [LiveWindow]) { self.live = live }

    func set(front: String?) { self.front = front }
    func set(trusted: Bool) { self.trusted = trusted }
    func set(under: CGWindowID?) { self.under = under }
    func windowID(at point: CGPoint) -> CGWindowID? { under }
    func replace(_ live: [LiveWindow]) { self.live = live }
    func move(_ title: String, to frame: CGRect) { live[live.firstIndex { $0.title == title }!].frame = frame }

    func windows() throws -> [LiveWindow] {
        guard trusted else { throw WindowError.notTrusted }
        return live
    }
    func frontmostWindow() throws -> LiveWindow? { try windows().first { $0.title == front } }
    func setMinimized(_ v: Bool, _ ref: WindowHandle) throws {
        let i = try index(ref)
        live[i].isMinimized = v
        calls.append("min \(v) \(live[i].title)")
    }
    func setFrame(_ f: CGRect, _ ref: WindowHandle) throws { live[try index(ref)].frame = f }
    func raise(_ ref: WindowHandle) throws { calls.append("raise \(live[try index(ref)].title)") }
    func setHidden(_ hidden: Bool, pid: pid_t) throws { calls.append("hide \(hidden) \(pid)") }

    private func index(_ ref: WindowHandle) throws -> Int {
        guard trusted else { throw WindowError.notTrusted }
        guard let i = live.firstIndex(where: { $0.ref == ref }) else { throw WindowError.windowGone }
        return i
    }
}

final class MockSpaces: SpacesBridge, @unchecked Sendable {
    var current: SpaceID? = 1
    var canMoveWindows = true
    var moved: [([CGWindowID], SpaceID)] = []
    var switched: [SpaceID] = []
    /// Where windows "really" are; unset windows follow the current space.
    var windowSpace: [CGWindowID: SpaceID] = [:]
    var displays: [DisplaySpaces] = []
    func currentSpace() async -> SpaceID? { current }
    func layout() async -> [DisplaySpaces] { displays }
    func space(of window: CGWindowID) async -> SpaceID? { windowSpace[window] ?? current }
    func switchTo(_ space: SpaceID) async -> Bool { switched.append(space); current = space; return true }
    func move(_ windows: [CGWindowID], to space: SpaceID) async -> Bool { moved.append((windows, space)); return true }
    func setOnAllDesktops(_ pid: pid_t, _ on: Bool) async {}
}

final class MockLauncher: Launching {
    var launched: [[LaunchPayload]] = []
    func launch(_ payloads: [LaunchPayload]) { launched.append(payloads) }
}

@MainActor
final class EngineTests: XCTestCase {
    let fA = CGRect(x: 10, y: 10, width: 500, height: 400)
    let fB = CGRect(x: 600, y: 10, width: 300, height: 300)
    var mock: MockWindows!
    var spaces: MockSpaces!
    var launcher: MockLauncher!
    var storeURL: URL!

    /// Engine with one item "Work" bound to windows A (front) and B; C is unbound.
    func makeEngine() async -> ItemEngine {
        mock = MockWindows([win("A", id: 1, z: 0, frame: fA), win("B", id: 2, index: 1, z: 1, frame: fB), win("C", bid: "com.c", id: 3, z: 2)])
        spaces = MockSpaces()
        launcher = MockLauncher()
        storeURL = FileManager.default.temporaryDirectory.appending(path: "stacky-\(UUID()).json")
        let engine = ItemEngine(windows: mock, spaces: spaces, launcher: launcher, store: ItemStore(url: storeURL), unfoldSettle: .zero,
                                documentFinder: { title, _ in title == "C" ? URL(fileURLWithPath: "/tmp/C.dat") : nil },
                                isOnScreen: { $0.minX < 5000 })
        engine.addItem(named: "Work")
        for t in ["A", "B"] {
            await mock.set(front: t)
            await engine.bindFrontmostWindow(to: id(engine))
        }
        return engine
    }

    func id(_ e: ItemEngine) -> Item.ID { e.items[0].id }

    func testLinkingAWindowLinksItsDocumentOnce() async {
        let e = await makeEngine()
        let doc = URL(fileURLWithPath: "/tmp/report.pdf")
        var live = await mock.live
        live[2].documentURL = doc
        await mock.replace(live)
        await e.toggleWindow(live[2], among: live, in: id(e)) // link C
        XCTAssertEqual(e.items[0].payloads, [.folder(doc, app: "com.c")]) // reopened in the app it was linked from
        await e.toggleWindow(live[2], among: live, in: id(e)) // unlink, relink: no duplicate
        await e.toggleWindow(live[2], among: live, in: id(e))
        XCTAssertEqual(e.items[0].payloads, [.folder(doc, app: "com.c")])
        e.removePayload(.folder(doc, app: "com.c"), from: id(e))
        XCTAssertEqual(e.items[0].payloads, [])
        XCTAssertEqual(LaunchPayload(URL(string: "https://example.com/a")!), .url(URL(string: "https://example.com/a")!, browser: nil))
    }

    func testWindowWithoutDocumentIsLinkedByTitleAndNotReopenedWhileOpen() async {
        let e = await makeEngine()
        let live = await mock.live
        await e.toggleWindow(live[2], among: live, in: id(e)) // C exposes no document: finder resolves by title
        let found = LaunchPayload.folder(URL(fileURLWithPath: "/tmp/C.dat"), app: "com.c")
        XCTAssertEqual(e.items[0].payloads, [found])
        XCTAssertEqual(e.items[0].pendingPayloads(live: []), [found])
        e.addPayloads([.folder(URL(fileURLWithPath: "/tmp/Window C notes.txt"), app: "com.c")], to: id(e))
        var titled = live[2]; titled.title = "window c notes — Edited"
        XCTAssertEqual(e.items[0].pendingPayloads(live: [titled]), [found]) // the notes file is already showing
    }

    func testRemoveWindowUnlinksOnlyThatWindow() async {
        let e = await makeEngine()
        e.removeWindow(e.items[0].windows[0].id, from: id(e))
        XCTAssertEqual(e.items[0].windows.map(\.fingerprint.title), ["B"])
    }

    func testFoldThenReleaseRestoresFramesZOrderAndSpace() async {
        let e = await makeEngine()
        XCTAssertEqual(e.items[0].windows.count, 2)

        await e.fold(id(e))
        let minimized = await mock.live.filter(\.isMinimized).map(\.title)
        XCTAssertEqual(minimized, ["A", "B"])
        XCTAssertEqual(e.items[0].state, .folded(by: .minimize))
        XCTAssertEqual(e.items[0].windows[0].savedFrame, fA)

        await mock.move("A", to: .zero)
        spaces.current = 5
        await e.release(id(e))

        let live = await mock.live
        XCTAssertFalse(live.contains(where: \.isMinimized))
        XCTAssertEqual(live[0].frame, fA)
        XCTAssertEqual(e.items[0].state, .released(spaceID: 5))
        XCTAssertEqual(spaces.moved.first?.0, [1, 2])
        XCTAssertEqual(spaces.moved.first?.1, 5)
        let raises = await mock.calls.filter { $0.hasPrefix("raise") }
        XCTAssertEqual(raises, ["raise B", "raise A"]) // back to front
        XCTAssertNil(e.lastError)
    }

    func testToggleWindowLinksAndUnlinks() async {
        let e = await makeEngine() // A, B linked
        let live = await e.liveWindows()
        XCTAssertEqual(live.map(\.title), ["A", "B", "C"]) // front-most first

        await e.toggleWindow(live[2], among: live, in: id(e))
        XCTAssertEqual(e.items[0].windows.map(\.fingerprint.title), ["A", "B", "C"])
        await e.toggleWindow(live[0], among: live, in: id(e))
        XCTAssertEqual(e.items[0].windows.map(\.fingerprint.title), ["B", "C"])
    }

    func testLinkModeLinksClickedWindowOnce() async {
        let e = await makeEngine() // A, B linked
        await mock.set(under: 3)   // C
        let hit = await e.linkWindow(at: .zero, to: id(e))
        XCTAssertEqual(hit?.title, "C")
        await e.linkWindow(at: .zero, to: id(e))
        await mock.set(under: 1)   // A: already linked
        await e.linkWindow(at: .zero, to: id(e))
        XCTAssertEqual(e.items[0].windows.map(\.fingerprint.title), ["A", "B", "C"])

        await mock.set(under: nil) // menu bar / Dock / nothing
        let none = await e.linkWindow(at: .zero, to: id(e))
        XCTAssertNil(none)
    }

    func testReleaseFollowsWindowsWhenOSRefusesMove() async {
        let e = await makeEngine()
        spaces.current = 4
        await e.fold(id(e))
        spaces.current = 9
        spaces.canMoveWindows = false
        spaces.windowSpace = [1: 4, 2: 4] // un-minimized back onto the Space they came from
        await e.release(id(e))
        XCTAssertEqual(e.items[0].state, .released(spaceID: 4))
        let raises = await mock.calls.filter { $0.hasPrefix("raise") }
        XCTAssertEqual(raises, ["raise B", "raise A"])
    }

    func testRebindKeepsKnownWindowIDWhenLiveOneIsUnknown() async {
        let e = await makeEngine()
        await mock.replace([win("A", id: nil, z: 0, frame: fA), win("B", id: nil, index: 1, z: 1, frame: fB)])
        await e.fold(id(e))
        XCTAssertEqual(e.items[0].windows.map(\.fingerprint.lastWindowID), [1, 2])
    }

    func testFoldAndReleaseAreIdempotent() async {
        let e = await makeEngine()
        await e.fold(id(e))
        await e.fold(id(e))
        await e.release(id(e))
        await e.release(id(e))
        let mins = await mock.calls.filter { $0.hasPrefix("min") }
        XCTAssertEqual(mins, ["min true A", "min true B", "min false B", "min false A"])
    }

    func testVanishedWindowIsSkipped() async {
        let e = await makeEngine()
        await mock.replace(await mock.live.filter { $0.title != "B" })
        await e.fold(id(e))
        XCTAssertTrue(e.items[0].isFolded)
        XCTAssertNil(e.lastError)
    }

    func testRevokedPermissionLeavesStateUntouched() async {
        let e = await makeEngine()
        await mock.set(trusted: false)
        await e.fold(id(e))
        XCTAssertFalse(e.items[0].isFolded)
        XCTAssertNotNil(e.lastError)
    }

    func testRebindsAfterAppRestart() async {
        let e = await makeEngine()
        await mock.replace([win("A", id: 50, z: 0, frame: fA), win("C", bid: "com.c", id: 3)])
        await e.fold(id(e))
        let mins = await mock.calls.filter { $0.hasPrefix("min") }
        XCTAssertEqual(mins, ["min true A"])
        XCTAssertEqual(e.items[0].windows[0].fingerprint.lastWindowID, 50)
    }

    func testAppHideStrategyHidesApps() async {
        let e = await makeEngine()
        e.defaultStrategy = .appHide
        defer { e.defaultStrategy = .minimize }
        await e.fold(id(e))
        XCTAssertEqual(e.items[0].state, .folded(by: .appHide))
        let hides = await mock.calls.filter { $0.hasPrefix("hide") }
        XCTAssertEqual(hides, ["hide true 1"])
    }

    func testActivateSwitchesSpaceAndLaunchesOnlyMissingPayloads() async {
        let e = await makeEngine()
        let file = URL(fileURLWithPath: "/tmp/notes.md")
        let link = URL(string: "https://example.com")!
        e.addPayloads([.app(bundleID: "com.a"), .file(file), .url(link, browser: "com.browser")], to: id(e))
        spaces.current = 2
        await e.fold(id(e))
        await e.release(id(e)) // home = 2
        spaces.current = 1
        spaces.windowSpace = [1: 2, 2: 2] // the windows stayed on desktop 2

        await e.activate(id(e))
        XCTAssertEqual(spaces.switched, [2])
        XCTAssertEqual(launcher.launched, [[.file(file), .url(link, browser: "com.browser")]])
    }

    func testActivateGathersOnTheDesktopWithMostWindowsWithoutReordering() async {
        let e = await makeEngine()
        let live = await mock.live
        await e.toggleWindow(live[2], among: live, in: id(e)) // link C too
        spaces.moved = []

        await e.activate(id(e)) // everything here already: nothing moves, switches or is raised
        XCTAssertTrue(spaces.moved.isEmpty && spaces.switched.isEmpty)

        spaces.windowSpace = [1: 2, 2: 2, 3: 1] // A and B on desktop 2, C here on 1
        await e.activate(id(e))
        XCTAssertEqual(spaces.moved.map(\.0), [[3]])
        XCTAssertEqual(spaces.moved.map(\.1), [2])
        XCTAssertEqual(spaces.switched, [2])
        XCTAssertEqual(e.items[0].state, .released(spaceID: 2))
        let raised = await mock.calls.contains { $0.hasPrefix("raise") }
        XCTAssertFalse(raised, "going to a workspace must not reorder its windows")
    }

    /// Two monitors: left shows desktop 1 of [1, 2], right shows 11 of [11, 12]. A lives left, B right.
    func testTwoMonitorsKeepWindowsOnTheirOwnMonitor() async {
        let e = await makeEngine()
        spaces.displays = [DisplaySpaces(display: "L", current: 1, spaces: [1, 2]),
                           DisplaySpaces(display: "R", current: 11, spaces: [11, 12])]
        spaces.windowSpace = [1: 1, 2: 11]
        spaces.moved = []

        await e.activate(id(e)) // each window is on its monitor's visible desktop: nothing to do
        XCTAssertTrue(spaces.moved.isEmpty && spaces.switched.isEmpty, "windows must not be gathered across monitors")

        await e.fold(id(e))
        spaces.displays[0].current = 2  // the user changes desktop on both monitors while folded
        spaces.displays[1].current = 12
        spaces.current = 2
        spaces.moved = []
        await e.release(id(e))
        // A returns to the left monitor's desktop, B to the right monitor's: never both to the active one.
        XCTAssertEqual(Set(spaces.moved.map { "\($0.0)->\($0.1)" }), ["[1]->2", "[2]->12"])
    }

    func testFrameOnDisconnectedMonitorIsNotRestored() async {
        let e = await makeEngine()
        await mock.move("B", to: CGRect(x: 6000, y: 0, width: 300, height: 300)) // on a second monitor
        await e.fold(id(e))
        await mock.move("B", to: fB) // monitor unplugged: macOS pulled the window back
        await e.release(id(e))
        let frame = await mock.live.first { $0.title == "B" }!.frame
        XCTAssertEqual(frame, fB)
    }

    func testSharedAppIsNeitherFoldedNorMoved() async {
        let e = await makeEngine()
        let live = await mock.live
        await e.toggleWindow(live[2], among: live, in: id(e)) // link C, an app every workspace uses
        await e.setShared("com.c", true)

        await e.fold(id(e))
        let minimized = await mock.live.filter(\.isMinimized).map(\.title)
        XCTAssertEqual(minimized, ["A", "B"], "the shared window stays up for the other workspaces")
        await e.release(id(e))

        spaces.windowSpace = [1: 2, 2: 2, 3: 1] // A and B on desktop 2, shared C on 1
        spaces.moved = []
        await e.activate(id(e))
        XCTAssertFalse(spaces.moved.contains { $0.0.contains(3) }, "going to a workspace must not drag a shared app along")
        XCTAssertEqual(spaces.switched.last, 2)
        await e.setShared("com.c", false) // the setting is persisted: don't leak it into other tests
        XCTAssertTrue(e.sharedApps.isEmpty)
    }

    func testActivateFoldedItemReleasesFirst() async {
        let e = await makeEngine()
        await e.fold(id(e))
        await e.activate(id(e))
        XCTAssertFalse(e.items[0].isFolded)
        let minimized = await mock.live.contains(where: \.isMinimized)
        XCTAssertFalse(minimized)
    }

    func testRemovedStrategyDecodesAsMinimize() throws {
        let json = Data(#"["parkingSpace", "appHide"]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([FoldStrategyKind].self, from: json), [.minimize, .appHide])
    }

    func testPersistenceRoundTripAndCorruptBackup() async throws {
        let e = await makeEngine()
        await e.fold(id(e))
        XCTAssertEqual(ItemStore(url: storeURL).load(), e.items)

        try Data("garbage".utf8).write(to: storeURL)
        XCTAssertEqual(ItemStore(url: storeURL).load(), [])
        let siblings = try FileManager.default.contentsOfDirectory(atPath: storeURL.deletingLastPathComponent().path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix(storeURL.lastPathComponent + ".corrupt-") })
    }
}
