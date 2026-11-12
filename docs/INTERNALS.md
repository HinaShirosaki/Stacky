# Stacky internals

How Stacky is built, what private system calls it relies on, and what was measured. For what the app does and how to use it, see the [README](../README.md).

## Build & run

```sh
swift test               # state machine + rebinding heuristic, fully mocked
scripts/bundle.sh        # build/Stacky.app, Hardened Runtime, signed with your dev identity
open build/Stacky.app
```

`bundle.sh` signs with the first Developer ID or Apple Development identity in your keychain; pass one explicitly to override. The app is not sandboxed.
A stable identity keeps the Accessibility grant across rebuilds. The ad-hoc fallback (used when there is no identity) loses it on every build.

## Modules

| Module | Role |
|---|---|
| `WindowKit` | `WindowProvider`, the AX implementation on a dedicated serial queue, `WindowFingerprint` + `Rebinder` |
| `SpacesKit` | `SpacesBridge`, the only place Spaces SPI may live. `PublicSpacesBridge` is the no-SPI fallback |
| `LaunchKit` | Opens files, apps and URLs via `NSWorkspace` |
| `Store` | `Item` model, JSON store (`~/Library/Application Support/Stacky/items.json`), `FoldStrategy`, `ItemEngine` state machine |
| `AppUI` | Menu-bar executable |

## Linking a window links its file

Linking a window also links what it shows, so the workspace can reopen it in the same app after the app quits. Nothing here is a per-app list; each step works for any app that fits it.

1. **VS Code and anything built on it** (Cursor, Windsurf, VSCodium, …): the folder the window has open, read from the editor's own `storage.json`. Detected by that file existing, not by bundle ID.
2. **The window's Accessibility document**: checked with Acrobat, ChemDraw and VS Code; standard Cocoa document apps (Preview, Pages, Keynote, Numbers, TextEdit, Office) are expected to work the same way but are untested. Terminal reports its working directory, which reopens as a Terminal window there.
3. **A path in the title**: apps that title windows with the full path.
4. **The title as a file name**, for apps that expose nothing (mostly Qt, Java and Electron): Spotlight finds files named like the title, with or without extension, after stripping status notes and unsaved markers. The most recently used file whose type the app declares in its `Info.plist` wins.

Known gaps: JetBrains IDEs, Zed and Sublime project folders; Finder windows; browser tabs; apps with untitled windows; files on volumes Spotlight doesn't index. Step 4 can pick the wrong one of two same-named files; remove it from the card's list.

## Multiple monitors

A workspace can span monitors. Each linked window's frame and desktop are saved when it is folded, and every operation works monitor by monitor (`SpacesBridge.layout()`):
- **Release** puts each window back on the monitor it was folded on, onto the desktop that monitor shows now. A window whose monitor is gone comes to the active desktop and keeps its current frame.
- **Clicking a card** gathers windows per monitor: on each one, onto the desktop holding most of that monitor's windows. Windows never change monitor.
- A card reads "Other desktop" only when its home desktop is showing on no monitor.

Covered by mocked tests only; not yet run on a real multi-monitor setup. The per-app move fallback (see Status) is at its worst here: moving one window of an app can drag that app's windows from another monitor along.

## Shared apps

`ItemEngine.sharedApps` (bundle IDs, stored in user defaults) marks apps that every workspace uses. Fold, release and the card click filter their windows out, so a workspace never minimizes or moves them. The all-desktops assignment belongs to a running process, not to the app, so `pinSharedApps()` reapplies it when Stacky starts and whenever an app launches.

Live check: `STACKY_STICKY_PID=<pid> STACKY_STICKY_WINDOW=<window id> swift test --filter AllDesktops`.

## Permissions

- **Accessibility** (required): reads window titles, frames and documents, and minimizes, moves and raises windows. The popover shows a banner that deep-links to the settings pane. If the permission is revoked while the app runs, operations stop with an error and item state is left unchanged.
- **Screen Recording** (optional, later): exposes `kCGWindowName`, which improves AX↔CGWindow matching and enables thumbnails.

## Status

**Phase 1 (done):** `MinimizeFold` and `AppHideFold` work end to end, on a single Space, with no SPI.
- AX only lists windows on the current Space. This is solved in Phase 3 by cross-Space enumeration, below.
- Without the SPI bridge, Space IDs are unknown. Clicking an Item raises its windows, and macOS follows them to their Space.

**Phase 3 (in progress):** `SkyLightSpacesBridge` is done. Items record real home Space IDs.
- Release moves the item's windows to the current Space, so fold on one desktop and release on another transfers them.
- The per-window move is ignored for other apps' windows, so Release falls back to `ProcessAssignToSpace`.
- That fallback moves **every** window of each owning app, bound to the item or not. The assignment is cleared straight after, so the app's later windows open normally.
- If neither path lands, windows reappear on the Space they were folded from and raising them takes you there.

**Dropped:** `ParkingSpaceFold`. Parking windows on a hidden Space is blocked for other processes' windows since macOS 14.5. Verified on 27.0.1: `SpaceCreate` + add/remove and managed moves both no-op unless the caller owns the window.

**Not yet built:** the item editor window with thumbnails and drag-to-bind, AppleScript tab grouping, global hotkeys, and Screen Recording onboarding.

## SPI risk surface

All SPI lives in `Sources/SpacesKit/SkyLightSpacesBridge.swift`. Nothing is linked: SkyLight is `dlopen`ed and each symbol is `dlsym`ed (`SLS*`, falling back to `CGS*`).
- If `MainConnectionID`, `CopySpacesForWindows`, and either `GetActiveSpace` or `ManagedDisplayGetCurrentSpace` are missing, the app falls back to `PublicSpacesBridge`.
- Any other missing symbol turns off just that feature.

| SPI | Used for | Known risk |
|---|---|---|
| `MainConnectionID`, `GetActiveSpace`, `ManagedDisplayGetCurrentSpace` | current Space | stable for years |
| `CopySpacesForWindows` (mask 0x7) | Space of a window | stable |
| `SpaceGetType` | refuse moves into fullscreen/system Spaces | stable |
| `MoveWindowsToManagedSpace` | Release onto current Space | **since macOS 14.5, ignored for other processes' windows** |
| `ProcessAssignToSpace` | fallback for the above; whole-app granularity | works on 27.2; may be restricted in any update |
| `ProcessAssignToAllSpaces` | shared apps: show an app's windows on every desktop | works on 27.2; undone with `ProcessAssignToSpace` (current Space, then 0) |
| `_AXUIElementGetWindow` (HIServices) | exact AX element → CGWindowID | stable, used by most window managers |
| `_AXUIElementCreateWithRemoteToken` (HIServices) | AX elements for windows on other Spaces (AltTab's technique) | token layout could change; probing is time-boxed |

**Cross-Space enumeration.** Plain AX lists only windows on the current Space. For each app window that CG reports on another Space, Stacky probes remote AX element tokens: it accepts only `AXWindow` elements, stops once every wanted window is found, and gives up after 2000 IDs or 150 ms. Found elements are cached, and IDs that never turn up are not probed again.
- Measured on macOS 27.0.1: 14 windows across Spaces 4, 8, 9 and 102 in about 750 ms cold and 25 ms warm. The app warms the cache at launch.
- Real windows sat at element IDs 42–350.

Run `open -n --stdout out.txt build/Stacky.app --args --dump-windows` to see what Stacky can see. `--stack-test <pid>…` folds and releases the windows of the given apps through a throwaway engine and reports whether their stacking order survived; `--snapshot <png>` renders the UI. Launch it through `open` so Accessibility is attributed to Stacky.

Every move is checked afterwards with `CopySpacesForWindows`. `move` returns true only if the windows actually landed, and a failure is logged but doesn't break the fold or release.
Switching Spaces has no clean SPI without the Dock scripting addition (which requires SIP off). Stacky raises a window on the target Space instead, and macOS follows it.

Verified on macOS 27.0.1 (26A434):
- All symbols resolve.
- Current-Space and window-to-Space lookups pass against the live window server (`SkyLightTests`).
- Cross-process move works only through `ProcessAssignToSpace`.

Checked on macOS 27.2 (26B123) against a test window owned by another process:
- `MoveWindowsToManagedSpace`, `SpaceAddWindowsAndRemoveFromSpaces` and `AddWindowsToSpaces` + `RemoveWindowsFromSpaces` have no effect.
- `ProcessAssignToSpace` moves all of the process's windows, minimized ones included. Assigning Space 0 afterwards clears it.
- To repeat: `STACKY_MOVE_WINDOW=<window id> STACKY_MOVE_SPACE=<space id> swift test --filter CrossProcess`.

## Recording the demo

`docs/demo.gif` is a real screen recording, made in a throwaway [Tart](https://tart.run) VM so no personal windows or files appear. The helpers are in `scripts/demo/`.

1. Clone and start a Cirrus Labs macOS base image (`tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest stacky-demo`, `tart run stacky-demo --no-graphics`). These images have SIP off and already let SSH sessions capture the screen and post input events.
2. Copy `build/Stacky.app` in and grant it Accessibility by adding an `app.stacky.Stacky` row to the VM's system `TCC.db`.
3. Open a few made-up documents, run `seed.py` to write a matching workspace, and launch Stacky.
4. Record with `screencapture -v -V 13 -C demo.mov` while `click` (built from `click.swift`) clicks the menu bar icon, then Fold, then Release. Positions are in screen points.
5. On the host, `mov2gif demo.mov docs/demo.gif 8 640 1.2 12.2` (frames per second, width, start and end seconds).

The other clips (`demo-link.gif`, `demo-desktops.gif`, `demo-reopen.gif`) are made the same way with different click sequences; `key` (from `key.swift`) types text and presses keys. Two things to know:
- A synthetic ⌘Q leaves the Command flag on later synthetic clicks, and ⌘-click on a menu bar icon does not open it. `click.swift` clears the flags for that reason.
- Synthetic Control-arrow does not switch desktops; open Mission Control (`open -a "Mission Control"`) and click the desktop instead. Clicking the wallpaper triggers "show desktop".

- `demo-sort.gif` needs windows spread over several desktops first: `spaces move <pid> <desktop number>` (from `spaces.swift`) moves all of an app's windows, and `hover` moves the pointer without clicking. In Mission Control the desktop thumbnails shift depending on which desktop is current, so measure their positions from a screenshot before scripting a click.

Recording on macOS 26.6 also confirmed, outside the development machine, that `ProcessAssignToSpace` moves a folded workspace to another desktop.

`docs/walkthrough.gif` needs no VM: `scripts/make-demo.sh` renders the app's own window against made-up data.
