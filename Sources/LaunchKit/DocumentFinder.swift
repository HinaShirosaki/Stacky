import AppKit
import CoreServices
import UniformTypeIdentifiers

/// Finds the file behind a window whose app doesn't expose it through Accessibility (Qt, Java and
/// Electron apps mostly): a file named like the window title that the app is registered to open.
/// ponytail: name match via Spotlight, most recently used wins. Same-named files in different folders can
/// resolve to the wrong one, and unindexed volumes resolve to nothing; the user can remove a wrong link.
public enum DocumentFinder {
    /// File names a title may stand for: "report.docx - Word" → ["report.docx - Word", "report.docx", "Word"].
    static let separators = [" — ", " – ", " - ", " | ", " • ", " @ "] // " @ ": Adobe's "name.psd @ 100% (RGB/8)"

    static func nameCandidates(_ title: String) -> [String] {
        var out: [String] = []
        func add(_ raw: String) {
            // Unsaved-change markers: "● name" (Electron), "name*" / "*name" (Qt, GTK, Java).
            var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " *●•"))
            // Trailing status notes: "name.pdf (SECURED)", "name [Read-Only]".
            while let r = s.range(of: #"\s*[\(\[][^\)\]]*[\)\]]$"#, options: .regularExpression) { s.removeSubrange(r) }
            for c in [s, s.replacingOccurrences(of: " .", with: ".")] where c.count >= 3 && !out.contains(c) { out.append(c) }
        }
        add(title)
        var parts = [title]
        for sep in separators { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        parts.forEach(add)
        return Array(out.prefix(8))
    }

    /// Some apps put the whole path in the title: "/Users/me/a.txt - Editor", "Blender [~/scenes/a.blend]".
    static func pathInTitle(_ title: String, exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> URL? {
        var chunks = [title]
        for sep in separators + ["[", "]", "(", ")"] { chunks = chunks.flatMap { $0.components(separatedBy: sep) } }
        for chunk in chunks {
            let s = chunk.trimmingCharacters(in: CharacterSet(charactersIn: " *●•"))
            guard s.count > 1, s.hasPrefix("/") || s.hasPrefix("~/") else { continue }
            let path = (s as NSString).expandingTildeInPath
            if exists(path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    public static func file(forWindowTitled title: String, bundleID: String) -> URL? {
        let ws = NSWorkspace.shared
        guard let app = ws.urlForApplication(withBundleIdentifier: bundleID)?.standardizedFileURL,
              // Browsers title their windows after pages, which may share a name with an unrelated local file.
              !ws.urlsForApplications(toOpen: URL(string: "https://example.com")!).contains(where: { $0.standardizedFileURL == app })
        else { return nil }
        if let exact = pathInTitle(title) { return exact }
        let names = nameCandidates(title)
        guard !names.isEmpty else { return nil }
        func quoted(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "*", with: "\\*")
        }
        // Exact name, or the name without its extension (many apps hide it in the title).
        let clauses = names.flatMap { ["kMDItemFSName == \"\(quoted($0))\"c", "kMDItemFSName == \"\(quoted($0)).*\"c"] }
        guard let query = MDQueryCreate(kCFAllocatorDefault, clauses.joined(separator: " || ") as CFString, nil, nil) else { return nil }
        MDQuerySetMaxCount(query, 200)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return nil }

        var hits: [(url: URL, used: Date)] = []
        for i in 0..<MDQueryGetResultCount(query) {
            let item = unsafeBitCast(MDQueryGetResultAtIndex(query, i), to: MDItem.self)
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String, !path.contains("/Library/") else { continue }
            let url = URL(fileURLWithPath: path)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
                ?? MDItemCopyAttribute(item, kMDItemFSContentChangeDate) as? Date ?? .distantPast
            hits.append((url, used))
        }
        let opens = documentTypes(of: app)
        return hits.sorted { $0.used > $1.used }.first { opens($0.url) }?.url
    }

    /// Whether the app at `app` declares, in its Info.plist, that it opens a file's type. Stricter than
    /// Launch Services' "can open", which lets apps that accept any file claim unrelated same-named files.
    static func documentTypes(of app: URL) -> (URL) -> Bool {
        let generic: Set<String> = ["public.data", "public.item", "public.content", "public.text", "public.plain-text"]
        let declared = Bundle(url: app)?.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let extensions = Set(declared.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] }.map { $0.lowercased() }).subtracting(["*"])
        let types = declared.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
            .filter { !generic.contains($0) }.compactMap { UTType($0) }
        return { url in
            if extensions.contains(url.pathExtension.lowercased()) { return true }
            guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
            return types.contains { type.conforms(to: $0) }
        }
    }
}
