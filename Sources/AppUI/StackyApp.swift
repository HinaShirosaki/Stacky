import SwiftUI
import OSLog
import Store
import WindowKit
import SpacesKit
import LaunchKit

/// Plain AppKit entry point: all UI is the status item / popover / fallback window owned by AppDelegate.
/// (A SwiftUI `App` would need a scene, and a lone `Settings` scene opens an empty window at launch.)
@main @MainActor
enum StackyApp {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // also under `swift run`, where there's no Info.plist LSUIElement
        app.delegate = delegate
        app.run()
    }
}

/// Menu-bar app: the icon opens a popover. The icon can be hidden (notch overflow, System Settings › Menu Bar),
/// so the same UI is also reachable as a window when that happens, during onboarding, and on reopen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let engine = ItemEngine(
        windows: AXWindowProvider(), spaces: makeSpacesBridge(),
        launcher: WorkspaceLauncher(), store: .default)
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    private let log = Logger(subsystem: "app.stacky.AppUI", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--stack-test") {
            let pids = Set(CommandLine.arguments[(i + 1)...].compactMap { pid_t($0) })
            Task { await stackTest(pids: pids); exit(0) }
            return
        }
        if CommandLine.arguments.contains("--dump-windows") {
            Task { await dumpWindows(); exit(0) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            // Diagnostics: `open -n Stacky.app --args --snapshot /path/out.png` renders the UI to a PNG.
            let path = CommandLine.arguments[i + 1]
            showWindow(notice: false) // this instance has no menu bar icon by design
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                // CGWindowListCreateImage is hidden from the Swift SDK but still renders our own window, glass included.
                typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                if let w = window, let sym = dlsym(dlopen(nil, RTLD_LAZY), "CGWindowListCreateImage"),
                   let image = unsafeBitCast(sym, to: Capture.self)(.null, 8, UInt32(w.windowNumber), 1)?.takeRetainedValue() {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
            return
        }
        setUpStatusItem()
        let trusted = Permissions.accessibilityGranted
        log.info("Launched; accessibility trusted: \(trusted, privacy: .public)")
        // Let the menu bar lay the new icon out before judging whether it's visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            let visible = iconVisible
            log.info("Menu bar icon visible: \(visible, privacy: .public)")
            if !trusted || !visible { showWindow() } else if engine.items.isEmpty { showPopover() }
        }
        if trusted { Task { _ = await engine.liveWindows() } } // warm the off-Space probe cache (~0.7 s cold, ~25 ms warm)
        if !trusted {
            // A process's AX trust can stay stale after the user grants it. The system posts this whenever
            // the Accessibility list changes; relaunch so the new grant takes effect. No loop: a relaunched
            // instance only restarts again if the list changes again.
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.relaunchIfStillUntrusted() }
            }
        }
    }

    /// Diagnostics: `open -n --stdout out.txt Stacky.app --args --stack-test <pid>…` folds and releases the
    /// windows of the given apps through a throwaway engine and reports whether their stacking order survived.
    private func stackTest(pids: Set<pid_t>) async {
        let store = ItemStore(url: FileManager.default.temporaryDirectory.appending(path: "stacky-stack-\(UUID()).json"))
        let e = ItemEngine(windows: AXWindowProvider(), spaces: makeSpacesBridge(), launcher: WorkspaceLauncher(), store: store)
        e.addItem(named: "stack-test")
        let id = e.items[0].id
        let live = await e.liveWindows().filter { pids.contains($0.ref.pid) }
        for w in live { await e.toggleWindow(w, among: live, in: id) }
        let ids = Set(live.compactMap(\.windowID))
        func order() -> [CGWindowID] {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            return list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }.filter(ids.contains)
        }
        for round in 1...3 {
            let before = order()
            await e.fold(id)
            try? await Task.sleep(for: .seconds(1))
            await e.release(id)
            try? await Task.sleep(for: .seconds(1.5))
            let after = order()
            print("round \(round): \(before) -> \(after) \(before == after ? "SAME" : "CHANGED")\(e.lastError.map { "  error: \($0)" } ?? "")")
        }
        fflush(stdout)
    }

    /// Diagnostics: `open -n --stdout out.txt Stacky.app --args --dump-windows`. Launch through `open` so
    /// Accessibility is attributed to Stacky, not to the launching terminal.
    private func dumpWindows() async {
        let current = WindowSPI.currentSpace()
        print("trusted: \(Permissions.accessibilityGranted)  current space: \(current.map(String.init) ?? "?")  off-Space SPI: \(WindowSPI.canFindOffSpaceWindows)")
        var live: [LiveWindow] = []
        for pass in ["cold", "warm"] { // warm = what the running app pays once probe caches are filled
            let start = Date()
            live = await engine.liveWindows()
            print("\(pass): \(live.count) windows in \(Int(Date().timeIntervalSince(start) * 1000)) ms\(engine.lastError.map { "  error: \($0)" } ?? "")")
        }
        for w in live {
            let spaces = w.windowID.map(WindowSPI.spaces(of:)) ?? []
            let where_ = w.isMinimized ? "minimized" : spaces.isEmpty ? "space ?" : spaces.contains(current ?? 0) ? "here" : "space \(spaces.map(String.init).joined(separator: ","))"
            print("\(w.bundleID)\t#\(w.windowID.map(String.init) ?? "?")\t\(where_)\t\(w.title)\t\(w.documentURL?.path ?? "-")")
        }
        fflush(stdout)
    }

    private func relaunchIfStillUntrusted() {
        // Give tccd a moment to commit the change before deciding.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [log] in
            guard !Permissions.accessibilityGranted else { return }
            log.info("Accessibility list changed; relaunching to pick up the grant")
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
            try? relaunch.run()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        iconVisible ? showPopover() : showWindow()
        return false
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "Stacky" // keeps the position after the user ⌘-drags it
        item.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Stacky")
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        // Dragging files onto the icon springs the popover open, so they can be dropped on an item.
        // NSWindow forwards dragging-destination messages to its delegate.
        item.button?.window?.registerForDraggedTypes([.fileURL, .URL])
        item.button?.window?.delegate = self

        let host = NSHostingController(rootView: ItemsPopover(engine: engine))
        host.sizingOptions = .preferredContentSize // popover tracks content as cards come and go
        popover.contentViewController = host
        popover.behavior = .transient
    }

    @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !popover.isShown { showPopover() }
        return [] // the drop itself lands on an item card
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return showWindow() }
        window?.close()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// False when the icon is switched off, occluded, or pushed behind the notch by a full menu bar.
    private var iconVisible: Bool {
        guard let w = statusItem?.button?.window, statusItem?.isVisible == true, w.isVisible,
              w.occlusionState.contains(.visible) else { return false }
        if let screen = w.screen, let rightOfNotch = screen.auxiliaryTopRightArea {
            return w.frame.minX >= rightOfNotch.minX
        }
        return true
    }

    // MARK: - Window

    private func showWindow(notice showNotice: Bool = true) {
        popover.performClose(nil)
        if window == nil {
            let notice = iconVisible || !showNotice ? nil
                : "Stacky's menu bar icon is hidden: the menu bar is full or Stacky is off in System Settings › Menu Bar. Quit a menu bar app or ⌘-drag icons to make room."
            let host = NSHostingController(rootView: ItemsPopover(engine: engine, outerGlass: true, notice: notice))
            host.sizingOptions = .preferredContentSize // window tracks content as cards come and go
            // Borderless: no title bar, so no traffic lights and no title-bar inset. The glass container
            // *is* the window's visible shape; Esc / context menu close it.
            let w = GlassWindow(contentViewController: host)
            w.styleMask = [.borderless]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.isMovableByWindowBackground = true
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Borderless windows can't take keyboard focus by default; the name field and Esc need it.
private final class GlassWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Glass (Liquid Glass on macOS 26+, material before)

extension View {
    @ViewBuilder
    func glass(in shape: some Shape, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) }
    }
}

/// GlassEffectContainer lets neighbouring glass shapes render and morph together.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Views

struct ItemsPopover: View {
    @Bindable var engine: ItemEngine
    /// Window mode draws its own outer glass; the menu-bar popover already has one.
    var outerGlass = false
    var notice: String?
    @State private var trusted = Permissions.accessibilityGranted
    @State private var adding = false
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    private let spacing: CGFloat = 8
    /// Gap between the container's edge and the cards.
    private var inset: CGFloat { outerGlass ? 22 : 8 }
    /// Concentric corners: container radius minus the gap. The system popover's corner measures 20 pt
    /// (macOS 26/27); the window-mode glass is 36.
    private var radius: CGFloat { (outerGlass ? 36 : 20) - inset }

    var body: some View {
        VStack(spacing: spacing) {
            if !trusted { permissionBanner }
            if let notice {
                Label(notice, systemImage: "menubar.rectangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Scroll only past 4 cards: a ScrollView has no intrinsic height and would leave empty space.
            if engine.items.isEmpty {
                Text("Create a workspace, then link windows to it or drop files on it.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if engine.items.count > 4 {
                ScrollView { cards }.frame(height: 4 * ItemCard.height + 3 * spacing)
            } else {
                cards
            }
            addRow
            if let error = engine.lastError {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(inset)
        .frame(width: 340)
        .modifier(OuterGlass(enabled: outerGlass))
        .contextMenu { settingsMenu }
        .onExitCommand { if outerGlass { NSApp.keyWindow?.close() } }
        .animation(.smooth, value: trusted)
        .onAppear { Task { await engine.refreshSpace() } }
        .task {
            // No public notification for AX trust changes; poll only while the banner is up.
            while !Task.isCancelled {
                trusted = Permissions.accessibilityGranted
                if trusted { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var cards: some View {
        GlassGroup(spacing: spacing) {
            VStack(spacing: spacing) {
                ForEach(engine.items) { ItemCard(item: $0, engine: engine, cornerRadius: radius) }
            }
        }
    }

    @ViewBuilder
    private var addRow: some View {
        if adding {
            TextField("Workspace name", text: $newName)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($nameFocused)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .glass(in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                // Focus set in the same pass that inserts the field is dropped; ask again once it is in the window.
                .onAppear { DispatchQueue.main.async { nameFocused = true } }
                .onSubmit(commitNew)
                .onExitCommand { adding = false; newName = "" }
        } else {
            Button { adding = true } label: {
                Label("New Workspace", systemImage: "plus")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glass(in: RoundedRectangle(cornerRadius: radius, style: .continuous), interactive: true)
            .help("New workspace")
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Accessibility access needed", systemImage: "lock.shield").font(.headline)
            Text("Stacky folds, restores and raises other apps' windows through the Accessibility API.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open Accessibility Settings") { Permissions.requestAccessibility() }.glassButton()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    @ViewBuilder
    private var settingsMenu: some View {
        Picker("Fold by", selection: $engine.defaultStrategy) {
            Text("Minimize").tag(FoldStrategyKind.minimize)
            Text("Hide App").tag(FoldStrategyKind.appHide)
        }
        Divider()
        if outerGlass { Button("Close Window") { NSApp.keyWindow?.close() } }
        Button("Quit Stacky") { NSApp.terminate(nil) }
    }

    private func commitNew() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { engine.addItem(named: name) }
        newName = ""
        adding = false
    }
}

private struct OuterGlass: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.glass(in: RoundedRectangle(cornerRadius: 36, style: .continuous))
        } else {
            content
        }
    }
}

struct ItemCard: View {
    static let height: CGFloat = 104
    let item: Item
    let engine: ItemEngine
    @State private var picking = false
    @State private var showingLinked = false
    @State private var dropTargeted = false

    var cornerRadius: CGFloat = 12

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: item.isFolded ? "rectangle.stack.fill" : "macwindow.on.rectangle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(item.isFolded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    .frame(width: 34, height: 34)
                    .background(.quaternary, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                tools
            }
            HStack(spacing: 8) {
                contents
                Spacer(minLength: 0)
                Button { Task { item.isFolded ? await engine.release(item.id) : await engine.fold(item.id) } } label: {
                    Label(item.isFolded ? "Release" : "Fold",
                          systemImage: item.isFolded ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(.quaternary, in: Capsule())
                        .contentShape(Capsule())
                }
                // Own colours rather than a system style, which dims in a non-key window and reads as disabled.
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .opacity(item.windows.isEmpty ? 0.35 : 1)
                .disabled(item.windows.isEmpty)
                .help(item.isFolded ? "Bring this workspace's windows back, onto this desktop" : "Minimize this workspace's windows")
            }
        }
        .padding(14)
        .frame(height: Self.height)
        .contentShape(shape)
        .glass(in: shape, interactive: true)
        .overlay {
            if isLinking || dropTargeted { shape.strokeBorder(.tint, lineWidth: 2) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            engine.addPayloads(urls.map(LaunchPayload.init), to: item.id)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .onTapGesture { Task { await engine.activate(item.id) } }
        .help("Click to go to this workspace and open its files")
        .contextMenu {
            Button("Link Frontmost Window") { Task { await engine.bindFrontmostWindow(to: item.id) } }
            Divider()
            Button("Delete Workspace", role: .destructive) { engine.removeItem(item.id) }
        }
    }

    /// Link windows from a list, link by clicking, and manage files.
    private var tools: some View {
        HStack(spacing: 8) {
            Button { showingLinked = true } label: { Image(systemName: "list.bullet") }
                .help("See and remove linked windows and files")
                .popover(isPresented: $showingLinked, arrowEdge: .bottom) { LinkedList(itemID: item.id, engine: engine) }
            Button { picking = true } label: { Image(systemName: "macwindow.badge.plus") }
                .help("Choose windows from a list")
                .popover(isPresented: $picking, arrowEdge: .bottom) { WindowPicker(itemID: item.id, engine: engine) }
            Button { isLinking ? LinkMode.shared.stop() : LinkMode.shared.start(item, engine: engine) } label: {
                Image(systemName: "cursorarrow.click.2")
            }
            .foregroundStyle(isLinking ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .help(isLinking ? "Stop linking" : "Link by clicking windows")
            Menu {
                Button("Add Files or Apps…", action: pickFiles)
                Button("Add URL from Clipboard") {
                    if let s = NSPasteboard.general.string(forType: .string), let url = URL(string: s), url.scheme != nil {
                        engine.addPayloads([LaunchPayload(url)], to: item.id)
                    }
                }
            } label: {
                Image(systemName: "paperclip")
            }
            .menuStyle(.button) // with the plain button style below, so it takes the same colour as its neighbours
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add files, apps or a URL. You can also drop them on this card.")
        }
        .buttonStyle(.plain) // plain honours the foreground style; borderless would draw its own colour
        .foregroundStyle(.primary) // full strength: grey icons read as disabled
        .font(.system(size: 14))
        .frame(height: 28)
        .padding(.horizontal, 8)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }

    /// What the workspace holds, as icons: the apps of its linked windows, then its files, apps and links.
    @ViewBuilder
    private var contents: some View {
        let icons = contentIcons
        if icons.isEmpty {
            Text("Link windows or drop files here").font(.caption).foregroundStyle(.tertiary)
                .frame(height: 22)
        } else {
            HStack(spacing: 5) {
                ForEach(Array(icons.prefix(7).enumerated()), id: \.offset) { _, icon in
                    Group {
                        if let image = icon.image {
                            Image(nsImage: image).resizable()
                        } else {
                            Image(systemName: "globe").resizable().foregroundStyle(.secondary).padding(2)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .help(icon.name)
                }
                if icons.count > 7 {
                    Text("+\(icons.count - 7)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .opacity(item.isFolded ? 0.55 : 1)
        }
    }

    private var contentIcons: [(image: NSImage?, name: String)] {
        let ws = NSWorkspace.shared
        func app(_ id: String) -> (image: NSImage?, name: String) {
            let url = ws.urlForApplication(withBundleIdentifier: id)
            return (url.map { ws.icon(forFile: $0.path) }, url?.deletingPathExtension().lastPathComponent ?? id)
        }
        var seen = Set<String>()
        let windowApps = item.windows.map(\.fingerprint.bundleID).filter { seen.insert($0).inserted }.map(app)
        let payloads = item.payloads.compactMap { p -> (image: NSImage?, name: String)? in
            switch p {
            case .file(let url), .folder(let url, _): (ws.icon(forFile: url.path), p.label)
            case .app(let id): seen.insert(id).inserted ? app(id) : nil // already shown for its window
            case .url: (nil, p.label)
            }
        }
        return windowApps + payloads
    }

    private var isLinking: Bool { LinkMode.shared.itemID == item.id }

    private var subtitle: String {
        if item.isFolded { return "Folded" }
        if item.windows.isEmpty && item.payloads.isEmpty { return "Empty" }
        // The icon row already shows what is linked; where it is matters more than a count.
        if case .released(let home?) = item.state, !engine.visibleSpaces.isEmpty, !engine.visibleSpaces.contains(home) {
            return "Other desktop"
        }
        func count(_ n: Int, _ word: String) -> String? { n == 0 ? nil : "\(n) \(word)\(n == 1 ? "" : "s")" }
        return [count(item.windows.count, "window"), count(item.payloads.count, "file")].compactMap { $0 }.joined(separator: " · ")
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        engine.addPayloads(panel.urls.map(LaunchPayload.init), to: item.id)
    }
}

/// Everything linked to one item, each row removable.
struct LinkedList: View {
    let itemID: Item.ID
    let engine: ItemEngine

    private var item: Item? { engine.items.first { $0.id == itemID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Linked to \(item?.name ?? "")").font(.headline)
            if let item, item.windows.isEmpty, item.payloads.isEmpty {
                Text("Nothing linked yet.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let item, !item.windows.isEmpty {
                        header("Windows")
                        ForEach(item.windows) { w in
                            let app = appInfo(w.fingerprint.bundleID)
                            row(icon: app.icon, title: w.fingerprint.title.isEmpty ? app.name : w.fingerprint.title,
                                detail: app.name) { engine.removeWindow(w.id, from: itemID) }
                        }
                    }
                    if let item, !item.payloads.isEmpty {
                        header("Files, apps and links")
                        ForEach(item.payloads, id: \.self) { p in
                            row(icon: icon(for: p), title: p.label, detail: detail(for: p)) {
                                engine.removePayload(p, from: itemID)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
    }

    private func row(icon: NSImage?, title: String, detail: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon { Image(nsImage: icon).resizable() } else { Image(systemName: "globe").resizable().foregroundStyle(.secondary) }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            Button(action: remove) { Image(systemName: "minus.circle.fill").font(.title3) }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("Remove from this workspace")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func appInfo(_ bundleID: String) -> (icon: NSImage?, name: String) {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        return (url.map { NSWorkspace.shared.icon(forFile: $0.path) }, url?.deletingPathExtension().lastPathComponent ?? bundleID)
    }

    private func icon(for p: LaunchPayload) -> NSImage? {
        switch p {
        case .file(let url), .folder(let url, _): NSWorkspace.shared.icon(forFile: url.path)
        case .app(let id): appInfo(id).icon
        case .url: nil
        }
    }

    private func detail(for p: LaunchPayload) -> String {
        switch p {
        case .file(let url): url.deletingLastPathComponent().path
        case .folder(let url, let app): "\(appInfo(app).name) · \(url.deletingLastPathComponent().path)"
        case .app: "App"
        case .url(let url, _): url.absoluteString
        }
    }
}

/// Live window list for one item: click a row to link / unlink it.
struct WindowPicker: View {
    let itemID: Item.ID
    let engine: ItemEngine
    @State private var live: [LiveWindow] = []
    @State private var loaded = false

    private var item: Item? { engine.items.first { $0.id == itemID } }

    /// Same assignment the engine uses, so the check marks match what fold/release will act on.
    private var linked: Set<WindowHandle> {
        guard let item else { return [] }
        return Set(Rebinder.match(item.windows.map(\.fingerprint), to: live).values.map(\.ref))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Windows in \(item?.name ?? "")").font(.headline)
            if loaded && live.isEmpty {
                Text("No windows found on this Space.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 2) {
                    let linked = linked
                    ForEach(live, id: \.ref) { w in row(w, isLinked: linked.contains(w.ref)) }
                }
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
        .task {
            live = await engine.liveWindows()
            loaded = true
        }
    }

    private func row(_ w: LiveWindow, isLinked: Bool) -> some View {
        let app = NSRunningApplication(processIdentifier: w.ref.pid)
        let appName = app?.localizedName ?? w.bundleID
        return Button {
            Task { await engine.toggleWindow(w, among: live, in: itemID) }
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: app?.icon ?? NSImage()).resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(w.title.isEmpty ? appName : w.title).lineLimit(1).truncationMode(.middle)
                    Text(w.isMinimized ? "\(appName) · minimized" : appName)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isLinked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isLinked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
