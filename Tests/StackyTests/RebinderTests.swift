import XCTest
@testable import LaunchKit
@testable import WindowKit

func win(_ title: String, bid: String = "com.a", id: CGWindowID? = nil, doc: URL? = nil,
         index: Int = 0, z: Int = 0, frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100), pid: pid_t = 1) -> LiveWindow {
    LiveWindow(ref: WindowHandle(pid: pid, key: Int(id ?? 0) * 1000 + index), windowID: id, bundleID: bid, title: title,
               documentURL: doc, index: index, frame: frame, isMinimized: false, zOrder: z)
}

final class RebinderTests: XCTestCase {
    func fp(_ w: LiveWindow) -> WindowFingerprint { WindowFingerprint(w) }

    func testWindowIDFastPathBeatsTitle() {
        let m = Rebinder.match([fp(win("Old", id: 7))], to: [win("Old", id: 8), win("New", id: 7)])
        XCTAssertEqual(m[0]?.windowID, 7)
    }

    func testBundleMustMatch() {
        XCTAssertTrue(Rebinder.match([fp(win("Doc", bid: "com.a", id: 1))], to: [win("Doc", bid: "com.b", id: 1)]).isEmpty)
    }

    func testConflictingDocumentNeverMatches() {
        let a = URL(fileURLWithPath: "/a.txt"), b = URL(fileURLWithPath: "/b.txt")
        let m = Rebinder.match([fp(win("a.txt", id: 1, doc: a))], to: [win("a.txt", id: 1, doc: b), win("renamed", id: 2, doc: a)])
        XCTAssertEqual(m[0]?.documentURL, a)
    }

    func testEditorWindowSurvivesSwitchingFiles() {
        let a = URL(fileURLWithPath: "/Users/me/Enana/src/a.py"), b = URL(fileURLWithPath: "/Users/me/Enana/docs/b.md")
        let linked = fp(win("a.py — Enana", id: 7, doc: a))
        // Same window, another file in front: still the linked window.
        XCTAssertEqual(Rebinder.match([linked], to: [win("b.md — Enana", id: 7, doc: b)])[0]?.windowID, 7)
        // After a restart the window ID is new, but it is the same project folder.
        XCTAssertEqual(Rebinder.match([linked], to: [win("b.md — Enana", id: 99, doc: b)])[0]?.windowID, 99)
        // A window on another project is not it, even with a file of the same name.
        let other = URL(fileURLWithPath: "/Users/me/Other/a.py")
        XCTAssertTrue(Rebinder.match([linked], to: [win("a.py — Other", id: 99, doc: other)]).isEmpty)
    }

    func testTitleSurvivesAppRestart() {
        let m = Rebinder.match([fp(win("Project — Notes", id: 7))], to: [win("Project — Notes", id: 99)])
        XCTAssertEqual(m[0]?.windowID, 99)
    }

    func testFuzzyTitle() {
        let m = Rebinder.match([fp(win("Stacky — README.md", id: 1))], to: [win("Stacky — README.md — Edited", id: 2)])
        XCTAssertEqual(m[0]?.windowID, 2)
    }

    func testIndexAloneDoesNotBind() {
        XCTAssertTrue(Rebinder.match([fp(win("Report.pdf", id: 1))], to: [win("Invoice.pdf", id: 2)]).isEmpty)
    }

    func testRestartedAppKeepsItsOnlyWindowWhateverItsTitle() {
        // A chat app updated and came back on another conversation: new process, new ID, new title.
        let chat = fp(win("Build plugin", bid: "com.chat", id: 650))
        let back = win("Justify risk", bid: "com.chat", id: 6028, pid: 2)
        XCTAssertEqual(Rebinder.match([chat], to: [back])[0]?.windowID, 6028)
        // Same process: the linked window was closed, and the one left is another window.
        XCTAssertTrue(Rebinder.match([chat], to: [win("Justify risk", bid: "com.chat", id: 651)]).isEmpty)
        // Two windows came back: no telling which.
        XCTAssertTrue(Rebinder.match([chat], to: [back, win("Other", bid: "com.chat", id: 6029, pid: 2)]).isEmpty)
        // A linked document that is closed is not replaced by whatever the app shows instead.
        let doc = fp(win("key", bid: "com.word", id: 9, doc: URL(fileURLWithPath: "/tmp/key.docx")))
        XCTAssertTrue(Rebinder.match([doc], to: [win("Poly", bid: "com.word", id: 90, pid: 2)]).isEmpty)
        // An old window ID that came back on another process's window is not the linked window.
        XCTAssertNil(Rebinder.score(chat, win("Justify risk", bid: "com.chat", id: 650, pid: 2)))
    }

    func testBrowserWindowSurvivesRestartOnAnotherPage() {
        let a = URL(string: "https://example.com/q/1")!, b = URL(string: "https://example.com/q/2")!
        let linked = fp(win("Grade Submission | Gradescope - Part of group - Chrome - Me", id: 7, doc: a))
        let m = Rebinder.match([linked], to: [win("Inbox - Chrome - Me", id: 98, doc: b, pid: 2),
                                              win("Grade Submission | Gradescope - Chrome - Me", id: 99, doc: b, pid: 2)])
        XCTAssertEqual(m[0]?.windowID, 99)
    }

    func testEditorWindowWithNoFileOpenIsStillItsProject() {
        let a = URL(fileURLWithPath: "/Users/me/Enana/src/a.py")
        XCTAssertEqual(Rebinder.match([fp(win("a.py — Enana", id: 7, doc: a))], to: [win("Enana", id: 99, pid: 2)])[0]?.windowID, 99)
        XCTAssertEqual(Rebinder.match([fp(win("Enana", id: 7))], to: [win("a.py — Enana", id: 99, doc: a, pid: 2)])[0]?.windowID, 99)
        XCTAssertTrue(Rebinder.match([fp(win("a.py — Enana", id: 7, doc: a))], to: [win("Other", id: 99, pid: 2)]).isEmpty)
    }

    func testNoDoubleAssignment() {
        let fps = [fp(win("Untitled", id: 1, index: 0)), fp(win("Untitled", id: 2, index: 1))]
        let m = Rebinder.match(fps, to: [win("Untitled", id: 11, index: 0), win("Untitled", id: 12, index: 1)])
        XCTAssertEqual(m[0]?.windowID, 11)
        XCTAssertEqual(m[1]?.windowID, 12)
    }
}

final class EditorFoldersTests: XCTestCase {
    func testResolvesFolderFromWindowTitle() throws {
        let storage = FileManager.default.temporaryDirectory.appending(path: "stacky-storage-\(UUID()).json")
        try Data(#"{"backupWorkspaces":{"folders":[{"folderUri":"vscode-remote://ssh/Enana"},{"folderUri":"file:///Users/me/Projects/Enana"},{"folderUri":"file:///Volumes/T7%20pro/peptide_counts"}]}}"#.utf8).write(to: storage)
        func folder(_ title: String) -> String? {
            EditorFolders.folder(bundleID: "com.microsoft.VSCode", title: title, storage: storage)?.path
        }
        XCTAssertEqual(folder("digest_1.gbk — Enana"), "/Users/me/Projects/Enana")   // remote URI skipped
        XCTAssertEqual(folder("peptide_counts"), "/Volumes/T7 pro/peptide_counts") // no editor open
        XCTAssertNil(folder("Welcome"))                                             // no folder
        XCTAssertNil(EditorFolders.folder(bundleID: "com.apple.Safari", title: "Enana"))
        // A folder that is no longer open is read off the file the window showed.
        let doc = URL(fileURLWithPath: "/Users/me/Projects/Gone/src/Gone/main.py")
        XCTAssertEqual(EditorFolders.folder(bundleID: "com.microsoft.VSCode", title: "main.py — Gone", document: doc, storage: storage)?.path,
                       "/Users/me/Projects/Gone")
        XCTAssertNil(EditorFolders.enclosingFolder(title: "main.py — Elsewhere", document: doc))
        XCTAssertNil(EditorFolders.enclosingFolder(title: "main.py", document: doc))
    }

    func testTitleToFileNameCandidates() {
        XCTAssertEqual(DocumentFinder.nameCandidates("71715400 .pdf (SECURED)"), ["71715400 .pdf", "71715400.pdf"])
        XCTAssertEqual(DocumentFinder.nameCandidates("report.docx - Word"), ["report.docx - Word", "report.docx", "Word"])
        XCTAssertEqual(DocumentFinder.nameCandidates("plasmid — Edited [Read-Only]"), ["plasmid — Edited", "plasmid", "Edited"])
        XCTAssertEqual(DocumentFinder.nameCandidates(""), [])
        XCTAssertEqual(DocumentFinder.nameCandidates("● notes.md — proj"), ["notes.md — proj", "notes.md", "proj"])
        XCTAssertEqual(DocumentFinder.nameCandidates("logo.psd @ 100% (RGB/8)*"), ["logo.psd @ 100%", "logo.psd", "100%"])
        let exists: (String) -> Bool = { $0 == "/data/a b.blend" || $0 == NSHomeDirectory() + "/x.txt" }
        XCTAssertEqual(DocumentFinder.pathInTitle("Blender [/data/a b.blend]", exists: exists)?.path, "/data/a b.blend")
        XCTAssertEqual(DocumentFinder.pathInTitle("~/x.txt* - Editor", exists: exists)?.path, NSHomeDirectory() + "/x.txt")
        XCTAssertNil(DocumentFinder.pathInTitle("report - Word", exists: exists))
    }
}
