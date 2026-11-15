# Open Explorer

A Windows Explorer–style file browser for macOS (SwiftUI + AppKit, macOS 14.4+).

## Build & run

```bash
./build-app.sh
open "build/Open Explorer.app"
```

The script compiles with `swiftc` directly because SwiftPM in the installed Command Line Tools
fails to link package manifests. `Package.swift` is kept so the project can be opened in Xcode.

### App icon

The icon is drawn in code (`Sources/OpenExplorer/IconRenderer.swift`) in four styles that follow
System Settings › Appearance › Icon & widget style: **Default, Dark, Clear, Tinted** (Tinted uses your accent colour).

- **Dock icon:** follows the setting live while the app runs (`AppIconManager.swift` reads `AppleIconAppearanceTheme`).
- **Finder and Launchpad icon:** uses the static `Resources/AppIcon.icns` (Default style). Having the system switch
  these too needs an Icon Composer `.icon` compiled by Xcode 26's `actool`, which the Command Line Tools don't include.
- `build-app.sh` renders the PNGs and `.icns` into `Resources/` whenever the renderer or `scripts/make-icon.swift` changes.

## Features

- **Folder tree (left):** folders only, loaded as you expand. Clicking a folder shows its contents on the right.
  Top-level entries:
  - **Home** (`~`)
  - **This Mac**: the whole disk (`/`)
  - **Mounted volumes**: disk images (DMG, ISO), USB drives, and so on. They appear and disappear as they're mounted
    and unmounted. Use the ⏏ button or right-click › Eject to unmount, like Finder.
  - **Trash** (`~/.Trash`). macOS only lets apps read the Trash with **Full Disk Access**
    (System Settings › Privacy & Security). Without it, the app offers to open the settings or show the Trash in Finder.
- **Detail list (right):** Name, Date Modified, Date Created, Kind, and Size columns. Folders are listed first.
  Click a column header to sort, or use the toolbar Sort menu (name, created, modified, kind, size; ascending or descending).
- **Two-way sync:** opening a folder on the right (or using Back/Forward/Up/address bar) expands and selects it in the tree.
- **Hidden files:** toolbar eye button or `⇧⌘.`. Hidden items appear dimmed.
- **Context menu** (list rows, empty list area, and tree folders): Open, Open in Terminal, Copy Path, Cut, Copy,
  Paste, New File…, New Folder…, Show in Finder, Move to Trash.
- **File-type icons:** colourful icons per file type and per well-known folder (`src`, `node_modules`, `.git`, ...)
  from [vscode-icons](https://github.com/vscode-icons/vscode-icons). Expanded folders in the tree show the open-folder icon,
  and light-mode variants are used in Light appearance. App bundles keep their real icons.
  Switch back to Finder icons with View › File Icons › macOS.
- **Quick Look:** press Space in the file list to preview the selection, as in Finder. Use the arrow keys to move through
  files with the preview open. Space or Esc closes it. It's also in the context menu.
- **Search** (searches the current folder; ⌘F focuses the field, Esc clears it):
  - **Name**: glob patterns on file names, e.g. `*.swift; *.md`, `report*`, `src/*.json` (a `/` matches the path).
    A plain word means "name contains".
  - **Contents**: runs `/usr/bin/grep` inside files (text files only). You can limit it to files matching a glob
    (`Files: *.swift`), and turn on **.\*** for regex (`grep -E`). The Match column shows the first matching line.
  - Options: **Subfolders** (recursive), **Aa** (match case). Results stream in and stop at 5000.
    Hidden files and app bundles are skipped unless hidden files are shown. Opening a folder clears the search.
- **Address bar:** type any path (`~` is supported) and press Return.
- The list auto-refreshes when the current folder changes on disk.

## Shortcuts

| Action | Keys |
|---|---|
| Back / Forward | `⌘[` / `⌘]` |
| Up to enclosing folder | `⌘↑` |
| Quick Look preview | `Space` (arrows switch files, `Space`/`Esc` closes) |
| Open selection | `⌘↓` or double-click / Return |
| Cut / Copy / Paste | `⌘X` / `⌘C` / `⌘V` |
| Copy Path | `⌥⌘C` |
| New File / New Folder | `⌥⌘N` / `⇧⌘N` |
| Open in Terminal | `⌥⌘T` |
| Show hidden files | `⇧⌘.` |
| Find | `⌘F` (Esc clears) |
| Refresh | `⌘R` |
| Home | `⇧⌘H` |

Copy and cut use the system pasteboard, so you can copy files from Finder and paste them here, or the other way around.
Cut files are moved on paste.

## Credits

File-type icons: [vscode-icons](https://github.com/vscode-icons/vscode-icons) v13.0.0 by Roberto Huertas and contributors,
MIT License (bundled at `Resources/vscode-icons/LICENSE.txt` and shipped inside the app).
`scripts/fetch-vscode-icons.sh` downloads the release from Open VSX. It extracts the SVGs and builds `mapping.json`
from the extension's Zed theme manifest, with a few overrides for entries VS Code resolves through language IDs.
Run it again to update the icons (change `VERSION` in the script).

