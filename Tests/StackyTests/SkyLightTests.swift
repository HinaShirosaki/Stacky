import XCTest
import CoreGraphics
import SpacesKit

/// Talks to the real window server; skipped where the SPI doesn't resolve.
final class SkyLightTests: XCTestCase {
    func testResolvesCurrentSpaceAndWindowSpaces() async throws {
        guard let bridge = SkyLightSpacesBridge() else { throw XCTSkip("SkyLight SPI unavailable") }
        let current = await bridge.currentSpace()
        XCTAssertNotNil(current)
        let layout = await bridge.layout()
        XCTAssertTrue(layout.contains { $0.current == current && $0.spaces.contains($0.current) }, "active desktop must belong to a monitor")

        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let id = list.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 })?[kCGWindowNumber as String] as? CGWindowID
        else { throw XCTSkip("No on-screen window") }
        let space = await bridge.space(of: id)
        XCTAssertNotNil(space)
        let bogus = await bridge.space(of: 0xFFFF_FFF0)
        XCTAssertNil(bogus, "bogus window id must not resolve")
    }

    /// Opt-in live check against another process's window:
    /// STACKY_MOVE_WINDOW=<CGWindowID> STACKY_MOVE_SPACE=<other desktop's space ID> swift test --filter CrossProcess
    func testCrossProcessMoveThereAndBack() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let bridge = SkyLightSpacesBridge(), let w = env["STACKY_MOVE_WINDOW"].flatMap(CGWindowID.init),
              let target = env["STACKY_MOVE_SPACE"].flatMap(SpaceID.init), let home = await bridge.space(of: w)
        else { throw XCTSkip("set STACKY_MOVE_WINDOW and STACKY_MOVE_SPACE") }
        let there = await bridge.move([w], to: target)
        XCTAssertTrue(there)
        let back = await bridge.move([w], to: home)
        XCTAssertTrue(back)
    }

    /// Opt-in live check against another process: STACKY_STICKY_PID=<pid> STACKY_STICKY_WINDOW=<one of its window ids>
    /// swift test --filter AllDesktops   (needs at least two desktops)
    func testShowOnAllDesktopsAndBack() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let bridge = SkyLightSpacesBridge(), let pid = env["STACKY_STICKY_PID"].flatMap(pid_t.init),
              let window = env["STACKY_STICKY_WINDOW"].flatMap(CGWindowID.init)
        else { throw XCTSkip("set STACKY_STICKY_PID and STACKY_STICKY_WINDOW") }
        let desktops = await bridge.layout().flatMap(\.spaces).count
        await bridge.setOnAllDesktops(pid, true)
        XCTAssertGreaterThan(WindowSPI.spaces(of: window).count, 1, "window should be on every desktop (\(desktops) known)")
        await bridge.setOnAllDesktops(pid, false)
        let here = await bridge.currentSpace()
        XCTAssertEqual(WindowSPI.spaces(of: window), [here].compactMap { $0 })
    }
}

final class WindowSPITests: XCTestCase {
    func testOffSpaceSPIResolvesAndProbingIsBounded() throws {
        guard WindowSPI.canFindOffSpaceWindows else { throw XCTSkip("Window SPI unavailable") }
        let start = Date()
        // Our own pid has no windows: the probe must give up within its budget, not hang.
        XCTAssertTrue(WindowSPI.offSpaceWindows(pid: getpid(), wanted: [0xFFFF_FFF0], budget: 0.2).isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}
