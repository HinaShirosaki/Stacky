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

    /// The local folder open in the editor window titled `title`, if any.
    public static func folder(bundleID: String, title: String, storage: URL? = nil) -> URL? {
        guard let file = storage ?? self.storage(for: bundleID),
              let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folders = (root["backupWorkspaces"] as? [String: Any])?["folders"] as? [[String: Any]] else { return nil }
        let urls = folders.compactMap { ($0["folderUri"] as? String).flatMap(URL.init(string:)) }.filter(\.isFileURL)
        // Folder name sits after the editor name, so search from the end.
        for part in titleParts(title).reversed() {
            if let hit = urls.first(where: { $0.lastPathComponent == part }) { return hit }
        }
        return nil
    }
}
