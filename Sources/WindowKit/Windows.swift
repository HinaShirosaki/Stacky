import AppKit
import ApplicationServices
import CoreGraphics

/// Opaque handle to a live window for the current enumeration. Not persisted.
public struct WindowHandle: Hashable, Sendable {
    public let pid: pid_t
    public let key: Int
    public init(pid: pid_t, key: Int) { self.pid = pid; self.key = key }
}

public struct LiveWindow: Hashable, Sendable {
    public var ref: WindowHandle
    public var windowID: CGWindowID?
    public var bundleID: String
    public var title: String
    public var documentURL: URL?
    /// Index among the app's standard AX windows.
    public var index: Int
    public var frame: CGRect
    public var isMinimized: Bool
    /// Position in the CGWindowList (0 = frontmost). `Int.max` when unknown.
    public var zOrder: Int

    public init(ref: WindowHandle, windowID: CGWindowID?, bundleID: String, title: String, documentURL: URL?,
                index: Int, frame: CGRect, isMinimized: Bool, zOrder: Int) {
        self.ref = ref; self.windowID = windowID; self.bundleID = bundleID; self.title = title
        self.documentURL = documentURL; self.index = index; self.frame = frame
        self.isMinimized = isMinimized; self.zOrder = zOrder
    }
}

public enum WindowError: LocalizedError, Equatable {
    case notTrusted, windowGone, ax(Int32)
    public var errorDescription: String? {
        switch self {
        case .notTrusted: "Accessibility permission is not granted."
        case .windowGone: "The window no longer exists."
        case .ax(let code): "Accessibility call failed (\(code))."
        }
    }
}

public protocol WindowProvider: Sendable {
    func windows() async throws -> [LiveWindow]
    func frontmostWindow() async throws -> LiveWindow?
    func setMinimized(_ minimized: Bool, _ ref: WindowHandle) async throws
    func setFrame(_ frame: CGRect, _ ref: WindowHandle) async throws
    /// Raise the window and activate its app.
    func raise(_ ref: WindowHandle) async throws
    func setHidden(_ hidden: Bool, pid: pid_t) async throws
    /// Topmost normal app window under `point` (global, top-left origin); nil for menu bar, Dock, own windows.
    func windowID(at point: CGPoint) async -> CGWindowID?
}

/// What we persist to re-identify a window after its app restarts.
public struct WindowFingerprint: Codable, Hashable, Sendable {
    public var bundleID: String
    public var title: String
    public var documentURL: URL?
    public var index: Int
    public var lastWindowID: CGWindowID?
    /// The process the window belonged to when last seen. A different one now means the app restarted.
    public var pid: pid_t?

    public init(_ w: LiveWindow) {
        bundleID = w.bundleID; title = w.title; documentURL = w.documentURL
        index = w.index; lastWindowID = w.windowID; pid = w.ref.pid
    }
}

public enum Rebinder {
    /// Greedy best-score assignment of fingerprints to live windows. Key = fingerprint index.
    /// ponytail: greedy, not optimal assignment; fine for tens of windows per item.
    public static func match(_ fps: [WindowFingerprint], to live: [LiveWindow]) -> [Int: LiveWindow] {
        var pairs: [(score: Int, fp: Int, w: Int)] = []
        for (i, fp) in fps.enumerated() {
            for (j, w) in live.enumerated() {
                if let s = score(fp, w) { pairs.append((s, i, j)) }
            }
        }
        pairs.sort { ($0.score, -$0.fp, -$0.w) > ($1.score, -$1.fp, -$1.w) }
        var out: [Int: LiveWindow] = [:]
        var used = Set<Int>()
        for p in pairs where out[p.fp] == nil && !used.contains(p.w) {
            out[p.fp] = live[p.w]
            used.insert(p.w)
        }
        // An app that restarted (an update, a reboot) gives its windows new IDs, and a chat or browser window
        // has a new title by then too, so nothing above recognises it. If the app left exactly one linked
        // window unmatched and shows exactly one window nothing else claimed, that window is the one.
        // Windows on a file are left out: the file says which window it is, and reopens it when it is gone.
        // ponytail: one window per app only; an app that comes back with several retitled windows stays
        // unmatched until relinked. Telling those apart needs more than the fingerprint holds (frame, tab URLs).
        for bundle in Set(fps.map(\.bundleID)) {
            let lost = fps.indices.filter { out[$0] == nil && fps[$0].bundleID == bundle }
            let free = live.indices.filter { !used.contains($0) && live[$0].bundleID == bundle }
            guard lost.count == 1, free.count == 1, fps[lost[0]].pid != live[free[0]].ref.pid,
                  file(fps[lost[0]].documentURL) == nil, file(live[free[0]].documentURL) == nil else { continue }
            out[lost[0]] = live[free[0]]
        }
        return out
    }

    /// Only a file tells windows apart. A browser reports the page address, which changes with every click.
    private static func file(_ url: URL?) -> URL? { url.flatMap { $0.isFileURL ? $0 : nil } }

    /// nil = not a candidate.
    /// ponytail: index alone never binds, so untitled, document-less windows only rebind by CGWindowID (same login session).
    static func score(_ fp: WindowFingerprint, _ w: LiveWindow) -> Int? {
        guard fp.bundleID == w.bundleID else { return nil }
        // Window IDs start over at login, so an old ID can come back on another window of the same app.
        let sameID = fp.lastWindowID != nil && fp.lastWindowID == w.windowID && (fp.pid == nil || fp.pid == w.ref.pid)
        let a = file(fp.documentURL), b = file(w.documentURL)
        if let a, let b, a != b {
            // A different file usually means a different window. Two exceptions, both scored below a
            // window that still shows the linked file (100):
            // - the very same window now showing another file, as editors do when you switch files;
            // - after a restart, an editor window on the same project: both files sit inside the folder
            //   named at the end of the title ("main.py — Enana").
            if sameID { return 90 }
            if let project = projectName(fp.title), project == projectName(w.title),
               a.pathComponents.contains(project), b.pathComponents.contains(project) {
                return 60 + (fp.index == w.index ? 5 : 0)
            }
            return nil
        }
        if sameID { return 1000 }
        var s = 0
        if fp.documentURL != nil, fp.documentURL == w.documentURL { s += 100 }
        if !fp.title.isEmpty, fp.title == w.title {
            s += 50
        } else {
            let j = similarity(fp.title, w.title)
            if j >= 0.5 { s += Int(40 * j) }
        }
        // An editor window with no file open is titled after its folder alone ("Enana"): the same project
        // as "main.py — Enana" when the one file known sits inside that folder.
        if s < 60, let known = a ?? b, (a == nil) != (b == nil),
           let project = projectName(fp.title) ?? projectName(w.title),
           [fp.title, w.title].allSatisfy({ ($0 == project || projectName($0) == project) }),
           known.pathComponents.contains(project) {
            s = 60
        }
        if fp.index == w.index { s += 5 }
        return s >= 20 ? s : nil
    }

    /// The last part of an editor-style title, "file — project" → "project"; nil for titles without parts.
    static func projectName(_ title: String) -> String? {
        let parts = title.components(separatedBy: " — ")
        guard parts.count > 1, let last = parts.last?.trimmingCharacters(in: .whitespaces), last.count >= 2 else { return nil }
        return last
    }

    /// Token Jaccard similarity.
    static func similarity(_ a: String, _ b: String) -> Double {
        func tokens(_ s: String) -> Set<Substring> { Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }) }
        let x = tokens(a), y = tokens(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }
}

public enum Permissions {
    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    public static func requestAccessibility() {
        // Registers the app in the Accessibility list; the settings pane covers the "previously denied" case.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
