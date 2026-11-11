import SwiftUI
import Store

/// "Click a window to link it": a global click monitor plus a floating HUD, until Esc / Done.
/// Global event monitors need Accessibility trust, which the app requires anyway.
@MainActor @Observable
final class LinkMode {
    static let shared = LinkMode()

    private(set) var itemID: Item.ID?
    private(set) var itemName = ""
    private(set) var lastLinked: String?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var hud: NSPanel?

    func start(_ item: Item, engine: ItemEngine) {
        stop()
        itemID = item.id
        itemName = item.name
        lastLinked = nil
        // Monitor handlers are delivered on the main thread.
        let click = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.clicked(engine) }
        }
        let escElsewhere = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { MainActor.assumeIsolated { self?.stop() } }
        }
        let escHere = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, MainActor.assumeIsolated({ self.itemID != nil }) else { return event }
            MainActor.assumeIsolated { self.stop() }
            return nil
        }
        monitors = [click, escElsewhere, escHere].compactMap { $0 }
        showHUD()
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        hud?.orderOut(nil)
        itemID = nil
    }

    private func clicked(_ engine: ItemEngine) {
        guard let id = itemID else { return }
        let p = NSEvent.mouseLocation // AppKit: bottom-left origin of the primary screen
        let point = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
        Task {
            guard let w = await engine.linkWindow(at: point, to: id), itemID == id else { return }
            lastLinked = w.title.isEmpty ? (NSRunningApplication(processIdentifier: w.ref.pid)?.localizedName ?? w.bundleID) : w.title
        }
    }

    private func showHUD() {
        let size = CGSize(width: 380, height: 56)
        if hud == nil {
            let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: LinkHUD(mode: self))
            hud = panel
        }
        guard let hud, let screen = NSScreen.main else { return }
        hud.setFrame(CGRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 12,
                            width: size.width, height: size.height), display: true)
        hud.orderFrontRegardless()
    }
}

struct LinkHUD: View {
    let mode: LinkMode

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cursorarrow.click.2").font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Click windows to link to \(mode.itemName)").font(.headline).lineLimit(1)
                Text(mode.lastLinked.map { "Linked: \($0)" } ?? "Esc to finish")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            // Explicit colours: the HUD panel never becomes key, and system button styles dim themselves in
            // a non-key window, which reads as disabled.
            Button { mode.stop() } label: {
                Text("Done").font(.callout.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(width: 380, height: 56)
        .glass(in: Capsule())
    }
}
