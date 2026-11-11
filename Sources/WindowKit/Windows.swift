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

    public init(_ w: LiveWindow) {
        bundleID = w.bundleID; title = w.title; documentURL = w.documentURL
        index = w.index; lastWindowID = w.windowID
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
        return out
    }

    /// nil = not a candidate.
    /// ponytail: index alone never binds, so untitled, document-less windows only rebind by CGWindowID (same login session).
    static func score(_ fp: WindowFingerprint, _ w: LiveWindow) -> Int? {
        guard fp.bundleID == w.bundleID else { return nil }
        if let a = fp.documentURL, let b = w.documentURL, a != b { return nil }
        if let id = fp.lastWindowID, id == w.windowID { return 1000 }
        var s = 0
        if fp.documentURL != nil, fp.documentURL == w.documentURL { s += 100 }
        if !fp.title.isEmpty, fp.title == w.title {
            s += 50
        } else {
            let j = similarity(fp.title, w.title)
            if j >= 0.5 { s += Int(40 * j) }
        }
        if fp.index == w.index { s += 5 }
        return s >= 20 ? s : nil
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
