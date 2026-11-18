import AppKit

/// VS Code and its forks expose the active *file* through Accessibility, never the folder a window has open.
/// The folder is recovered by matching the window title's folder name against the editor's own list of
/// open folders (`backupWorkspaces.folders` in its storage.json).
/// ponytail: matches by folder name, so two open folders with the same name resolve to the first; remote
/// (SSH/container) folders and custom `window.title` formats without the folder name are not resolved.
public enum EditorFolders {
    /// Bundle ID → directory name under ~/Library/Application Support, where it differs from the app's name.
    /// Forks (Cursor, Windsurf, VSCodium, Positron, …) use their app name and need no entry.
    static let supportDirs = [
        "com.microsoft.VSCode": "Code",
        "com.microsoft.VSCodeInsiders": "Code - Insiders",
        "com.visualstudio.code.oss": "Code - OSS",
    ]

    /// Title parts, e.g. "main.py — Enana" → ["main.py", "Enana"].
    static func titleParts(_ title: String) -> [String] {
        title.components(separatedBy: " — ").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The editor's storage.json, if `bundleID` is VS Code or anything built on it. Only that family keeps
    /// this file at this path, so its presence is the test.
    public static func storage(for bundleID: String) -> URL? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let names = [supportDirs[bundleID], app?.deletingPathExtension().lastPathComponent,
                     app.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleName"] as? String }]
        return names.compactMap { $0 }.map { support.appending(path: "\($0)/User/globalStorage/storage.json") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The local folder open in the editor window titled `title`, if any. `document` is the file the window
    /// shows; it recovers the folder of a window that has closed since and left the editor's list.
    public static func folder(bundleID: String, title: String, document: URL? = nil, storage: URL? = nil) -> URL? {
        guard let file = storage ?? self.storage(for: bundleID) else { return nil }
        let root = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let folders = (root?["backupWorkspaces"] as? [String: Any])?["folders"] as? [[String: Any]] ?? []
        let urls = folders.compactMap { ($0["folderUri"] as? String).flatMap(URL.init(string:)) }.filter(\.isFileURL)
        // Folder name sits after the editor name, so search from the end.
        for part in titleParts(title).reversed() {
            if let hit = urls.first(where: { $0.lastPathComponent == part }) { return hit }
        }
        return enclosingFolder(title: title, document: document)
    }

    /// "main.py — Enana" showing /Users/me/Enana/src/main.py → /Users/me/Enana: the folder the title names,
    /// found in the file's own path. Outermost wins when the name repeats (repo/pkg layouts open the repo).
    static func enclosingFolder(title: String, document: URL?) -> URL? {
        let parts = titleParts(title)
        guard parts.count > 1, var url = document, url.isFileURL else { return nil }
        let above = url.pathComponents.dropLast()
        guard let depth = parts.reversed().lazy.compactMap({ above.firstIndex(of: $0) }).first, depth > 0 else { return nil }
        while url.pathComponents.count > depth + 1 { url.deleteLastPathComponent() }
        return url
    }
}
