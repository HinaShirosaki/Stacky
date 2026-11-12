<p align="center"><img src="Resources/AppIcon.png" width="128" alt="Stacky icon"></p>

<h1 align="center">Stacky</h1>

<p align="center"><b>One click puts a whole project away. One click brings it back.</b><br>A menu bar workspace manager for macOS 14 and later.</p>

<p align="center"><img src="docs/demo-sort.gif" width="640" alt="Windows of two tasks mixed across three desktops; clicking each workspace gathers its windows onto one desktop, shown before and after in Mission Control"></p>

## Who it's for

Stacky is for people who work on several projects at once, with lots of files and windows, and who spend too much time dragging them between desktops.

A paper, a codebase and a grant report each have their own editor windows, PDFs, terminals and folders. By the afternoon they are mixed across every desktop, and switching tasks means hunting for the right windows. Stacky groups each project's windows and files into a **workspace**. You fold a workspace away when you stop and bring it back when you return, on whichever desktop you're using.

## Quick start

```sh
git clone https://github.com/HinaShirosaki/Stacky.git
cd Stacky
scripts/install.sh
```

Then click the stacked-layers icon in the menu bar and allow Accessibility access when asked. For requirements, updating and troubleshooting, see [Install](#install).

## What it does

Every demo below was recorded in a clean virtual machine with made-up documents.

### Sort a messy set of desktops

Click a workspace to gather its windows onto the desktop that already holds most of them and switch there. Linked files that have no window yet open too. The demo above shows two tasks spread across three desktops sorted into one task per desktop, with two clicks.

### Link windows by clicking them

A workspace is a named set of windows, files, folders, apps and links. Turn on link mode and click the windows that belong together. The file or folder behind each window is linked as well.

<p align="center"><img src="docs/demo-link.gif" width="640" alt="Creating a workspace named Thesis and linking three windows to it by clicking them"></p>

### Fold here, release anywhere

**Fold** minimizes a workspace's windows. **Release** brings them back in the same stacking order onto the desktop you're on. To move a whole task across, fold it on one desktop and release it on another.

<p align="center"><img src="docs/demo-desktops.gif" width="640" alt="Folding a workspace on Desktop 1, switching to Desktop 2 in Mission Control, and releasing it there"></p>

### Reopen after a restart

Because a workspace links the files behind its windows, clicking it reopens those documents after their apps have quit or the Mac has restarted.

<p align="center"><img src="docs/demo-reopen.gif" width="640" alt="Quitting TextEdit and Preview, then clicking the workspace to reopen their documents"></p>

### Also

- **Multiple monitors.** A workspace can span monitors, and windows always return to their own monitor.
- **Shared apps.** Apps that serve every task, such as Mail, chat or music, follow you to every desktop and are never folded with a workspace. See [Shared apps](#shared-apps).

## Install

There are no prebuilt downloads yet, so Stacky is built on your Mac. It takes about a minute.

**You need** macOS 14 or later and Apple's command line tools. If you're not sure you have them, run `xcode-select --install`; it says so if they're already installed. Full Xcode works too.

**1. Build and install.** In Terminal:

```sh
git clone https://github.com/HinaShirosaki/Stacky.git
cd Stacky
scripts/install.sh
```

This builds Stacky, copies it to `/Applications` (or `~/Applications` if you can't write there), and opens it. The stacked-layers icon appears in the menu bar.

**2. Allow Accessibility.** Click the icon. A banner asks for Accessibility access and opens the right page in System Settings › Privacy & Security › Accessibility; turn Stacky on there. Stacky needs this to read, minimize, move and raise other apps' windows. It is not sandboxed and makes no network connections.

**3. Optional: start at login.** System Settings › General › Login Items › Open at Login › **+**, then choose Stacky.

### Update

```sh
cd Stacky
git pull
scripts/install.sh
```

Your workspaces are kept.

### Uninstall

Quit Stacky (gear button › Quit), then delete `Stacky.app` from Applications and the folder `~/Library/Application Support/Stacky`. Remove it from the Accessibility list in System Settings.

### Troubleshooting

- **No icon in the menu bar.** The menu bar may be full or hidden behind the notch. Quit another menu bar app, or ⌘-drag icons to make room. When its icon can't be seen, Stacky opens its list as a window instead.
- **Stacky asks for Accessibility again after every update.** The build is signed with your Developer ID or Apple Development certificate if you have one (any free Apple account in Xcode › Settings › Accounts gives you one). Without one it is signed ad-hoc, and macOS treats each build as a new app: switch Stacky off and on again in the Accessibility list.
- **`swift: command not found` or `xcrun: error`.** Run `xcode-select --install`, then `scripts/install.sh` again.

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
| Mark an app as shared | The gear button › **Shared Apps** |

The gear button (or a right-click on the list's background) also sets how folding works (minimize windows, or hide whole apps) and quits Stacky.

### What gets linked with a window

| App | Linked |
|---|---|
| VS Code, Cursor, Windsurf, VSCodium and other VS Code forks | The folder the window has open |
| Document apps that report their file (tested with Acrobat and ChemDraw; Preview, Office and other standard document apps should behave the same) | The document |
| Terminal | The working directory |
| Apps that report nothing (many Qt, Java and Electron apps) | A file named like the window title that the app can open, found with Spotlight |
| Any window with no file behind it (Calculator, Mail, a browser) | The app itself, so it can be relaunched |

The Spotlight rule is a best guess; if it picks the wrong file, remove it from the card's list. A relaunched app opens its own default window, not the exact window you had.

### Shared apps

Some apps serve every task: Mail, chat, music. Mark them under the gear button › **Shared Apps** and Stacky will:

- show their windows on every desktop, so they follow you;
- never fold or move them for one workspace, even if a window of theirs is linked to it.

The list offers the apps that are running. Unmarking an app puts its windows back on the desktop you are on.

## Limitations

- **Moving a window to another desktop moves its whole app.** macOS no longer lets one app move another app's individual windows between desktops. Stacky uses the one call that still works, which moves every window of that app. For an app used by several workspaces, mark it as [shared](#shared-apps) so it is left alone. Folding and releasing without changing desktop moves nothing.
- **Private system calls.** Desktop (Spaces) support uses undocumented macOS functions that Apple can change in any update. If they disappear, Stacky falls back to working on the current desktop only.
- **Not linked automatically:** JetBrains, Zed and Sublime project folders, Finder windows, browser tabs, and windows with no title.
- **Multiple monitors** are covered by automated tests but have not yet been run on real multi-monitor hardware.

Developed and tested on macOS 27.

## Development

```sh
swift test                      # engine and matching logic, with mocked windows and desktops
scripts/bundle.sh               # build/Stacky.app without installing it
swift scripts/make-icon.swift   # regenerate the icon
scripts/make-demo.sh            # regenerate docs/walkthrough.gif from made-up workspaces
```

The code is split into small modules (`WindowKit`, `SpacesKit`, `LaunchKit`, `Store`, `AppUI`). [docs/INTERNALS.md](docs/INTERNALS.md) covers the architecture, the private calls and their risks, measurements, and the built-in diagnostics.

## License

[MIT](LICENSE)
