<p align="center"><img src="Resources/AppIcon.png" width="128" alt="Stacky icon"></p>

# Stacky

A menu bar workspace manager for macOS. Group the windows and files of one task into a workspace, fold them away with a click, and bring them back — on the same desktop or a different one.

Requires macOS 14 or later. Developed and tested on macOS 27.

<p align="center"><img src="docs/demo.gif" width="640" alt="Folding a workspace minimizes its three windows; releasing brings them back in the same order"></p>

## What it does

- **Workspaces.** A workspace is a named set of windows, files, folders, apps and links.
- **Fold and release.** Fold minimizes a workspace's windows. Release brings them back where they were, in the same stacking order, onto the desktop you are looking at. Fold on one desktop and release on another to move a whole task across.
- **Go to a workspace.** Click a workspace card to gather its windows on the desktop that already holds most of them, switch there, and open any linked file that has no window yet.
- **Recover from files.** Linking a window also links the file or folder it shows, so a workspace can reopen its documents after the apps have quit or the Mac has restarted.
- **Multiple monitors.** A workspace can span monitors; windows always return to their own monitor.

## Demos

Recorded in a clean virtual machine with made-up documents.

**Sort a messy set of desktops.** Two tasks' windows are scattered over three desktops. One click on each workspace gathers its windows onto a single desktop, leaving one task per desktop.

<p align="center"><img src="docs/demo-sort.gif" width="640" alt="Windows of two tasks mixed across three desktops; clicking each workspace gathers its windows onto one desktop, shown before and after in Mission Control"></p>

**Link windows by clicking them.** Create a workspace, turn on link mode, click each window, press Done. The files behind the windows are linked too.

<p align="center"><img src="docs/demo-link.gif" width="640" alt="Creating a workspace named Thesis and linking three windows to it by clicking them"></p>

**Move a workspace to another desktop.** Fold on Desktop 1, switch to Desktop 2, release: the windows arrive there in the same order.

<p align="center"><img src="docs/demo-desktops.gif" width="640" alt="Folding a workspace on Desktop 1, switching to Desktop 2 in Mission Control, and releasing it there"></p>

**Reopen a workspace from its files.** After the apps have quit, clicking the workspace opens its linked documents again.

<p align="center"><img src="docs/demo-reopen.gif" width="640" alt="Quitting TextEdit and Preview, then clicking the workspace to reopen their documents"></p>

## Install

There are no prebuilt releases yet. Build from source with Xcode or the Swift toolchain installed:

```sh
git clone <this repository>
cd Stacky
scripts/bundle.sh
open build/Stacky.app
```

`bundle.sh` signs the app with the first Developer ID or Apple Development identity in your keychain, or ad-hoc if there is none. With ad-hoc signing macOS forgets the Accessibility permission on every rebuild.

On first launch Stacky asks for **Accessibility** access (System Settings › Privacy & Security › Accessibility). It needs this to read, minimize, move and raise other apps' windows. Stacky is not sandboxed and makes no network connections.

## Use

Click the Stacky icon in the menu bar.

<p align="center"><img src="docs/walkthrough.gif" width="380" alt="Stacky's menu bar list: creating a workspace, linking windows and files, folding and releasing"></p>

| To | Do this |
|---|---|
| Create a workspace | **+ New Workspace**, type a name, press Return |
| Link windows | The cursor icon on a card, then click each window; Esc or **Done** to finish. Or pick from a list with the window icon |
| Link files, folders, apps | Drag them onto a card (dragging onto the menu bar icon opens the list), or use the paperclip |
| See or remove what is linked | The list icon on a card |
| Fold / release | The **Fold** / **Release** button on a card |
| Go to a workspace | Click the card |
| Delete a workspace | Right-click the card |

Right-click the list's background to choose how folding works (minimize windows, or hide whole apps) and to quit.

### What gets linked with a window

| App | Linked |
|---|---|
| VS Code, Cursor, Windsurf, VSCodium and other VS Code forks | The folder the window has open |
| Document apps that report their file (tested with Acrobat and ChemDraw; Preview, Office and other standard document apps should behave the same) | The document |
| Terminal | The working directory |
| Apps that report nothing (many Qt, Java and Electron apps) | A file named like the window title that the app can open, found with Spotlight |

The last rule is a best guess; if it picks the wrong file, remove it from the card's list.

## Limitations

- **Moving a window to another desktop moves its whole app.** macOS no longer lets one app move another app's individual windows between desktops. Stacky uses the one call that still works, which moves every window of that app. Folding and releasing without changing desktop moves nothing.
- **Private system calls.** Desktop (Spaces) support uses undocumented macOS functions that Apple can change in any update. If they disappear, Stacky falls back to working on the current desktop only.
- **Not linked automatically:** JetBrains, Zed and Sublime project folders, Finder windows, browser tabs, and windows with no title.
- **Multiple monitors** are covered by automated tests but have not yet been run on real multi-monitor hardware.

## Development

```sh
swift test          # engine and matching logic, with mocked windows and desktops
scripts/bundle.sh   # build/Stacky.app
swift scripts/make-icon.swift   # regenerate the icon
scripts/make-demo.sh            # regenerate docs/walkthrough.gif from made-up workspaces
```

The code is split into small modules (`WindowKit`, `SpacesKit`, `LaunchKit`, `Store`, `AppUI`). [docs/INTERNALS.md](docs/INTERNALS.md) covers the architecture, the private calls and their risks, measurements, and the built-in diagnostics.

## License

[MIT](LICENSE)
