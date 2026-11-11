import AppKit
import OSLog

public enum LaunchPayload: Codable, Hashable, Sendable {
    case file(URL)
    case app(bundleID: String)
    /// `browser` = bundle ID; nil opens in the default browser.
    case url(URL, browser: String?)
    /// A file or folder opened with a specific app (`app` = bundle ID): the document of a linked window,
    /// a VS Code workspace folder, a Terminal directory. (Named `folder` for stored-data compatibility.)
    case folder(URL, app: String)

    /// Whatever the user picked or dropped: an .app bundle, any other file, or a web link.
    public init(_ url: URL) {
        if !url.isFileURL { self = .url(url, browser: nil) }
        else if url.pathExtension == "app", let id = Bundle(url: url)?.bundleIdentifier { self = .app(bundleID: id) }
        else { self = .file(url) }
    }

    public var label: String {
        switch self {
        case .file(let url): url.lastPathComponent
        case .folder(let url, _): url.lastPathComponent + (url.hasDirectoryPath ? "/" : "")
        case .app(let id): NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent ?? id
        case .url(let url, _): url.host().map { $0 + (url.path.count > 1 ? url.path : "") } ?? url.absoluteString
        }
    }
}

public protocol Launching {
    func launch(_ payloads: [LaunchPayload])
}

public struct WorkspaceLauncher: Launching {
    private static let log = Logger(subsystem: "app.stacky.LaunchKit", category: "launch")
    public init() {}

    /// Fire-and-forget: everything opens at once, failures are logged.
    public func launch(_ payloads: [LaunchPayload]) {
        let ws = NSWorkspace.shared
        let cfg = NSWorkspace.OpenConfiguration()
        var urlsByBrowser: [String?: [URL]] = [:]

        for p in payloads {
            switch p {
            case .file(let url):
                ws.open(url, configuration: cfg, completionHandler: Self.report(url.path))
            case .folder(let url, let id):
                guard let app = ws.urlForApplication(withBundleIdentifier: id) else {
                    Self.log.error("No app for \(id, privacy: .public)")
                    continue
                }
                ws.open([url], withApplicationAt: app, configuration: cfg, completionHandler: Self.report(url.path))
            case .app(let id):
                guard let app = ws.urlForApplication(withBundleIdentifier: id) else {
                    Self.log.error("No app for \(id, privacy: .public)")
                    continue
                }
                ws.openApplication(at: app, configuration: cfg, completionHandler: Self.report(id))
            case .url(let url, let browser):
                urlsByBrowser[browser, default: []].append(url)
            }
        }
        // ponytail: one open() per browser; browsers usually tab these into the front window.
        // AppleScript "new window with these tabs" for Safari/Chromium comes later.
        for (browser, urls) in urlsByBrowser {
            if let app = browser.flatMap(ws.urlForApplication(withBundleIdentifier:)) {
                ws.open(urls, withApplicationAt: app, configuration: cfg, completionHandler: Self.report(browser ?? ""))
            } else {
                urls.forEach { ws.open($0) }
            }
        }
    }

    private static func report(_ what: String) -> @Sendable (NSRunningApplication?, Error?) -> Void {
        { _, error in
            if let error { log.error("Launch \(what, privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
