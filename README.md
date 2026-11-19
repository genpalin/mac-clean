# mac-clean

`mac-clean` is a local-first macOS disk review and cleanup utility. The native
Mac Clean app provides selectable, recoverable file cleanup and a read-only
audit; the CLI is the transparent engine for Docker cleanup and cache inventory.

## Global installation

Install a user-level command at `~/.local/bin/mac-clean`:

```bash
npm run mac:clean:install
```

If the command is not found, add the directory to the current shell's PATH:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

The installed command points to the source in this repository so updates remain
auditable in git.

## Read-only review

The default command audits disk, memory, and selected app-data sizes without
changing files or Docker objects:

```bash
mac-clean
```

It reports Docker Desktop `Docker.raw` logical size, actual allocated blocks,
and last modification time. Mac Clean can reveal that file in Finder, but never
deletes, moves, or compacts it. Aerial and other macOS-managed storage is
directed to System Settings, not removed by this tool.

Codex `.tmp` and `cache` are reported separately from `sessions` and
`archived_sessions`. Only the first two can appear in the opt-in cache review;
session history is never included in a cleanup action.

## Cleanup actions

The conservative Docker cleanup requires an explicit apply flag:

```bash
mac-clean --apply
```

This prunes Docker BuildKit cache and dangling images only. It does not use
`sudo`, remove containers or volumes, or clean package caches. Unused images
older than 30 days are a separate opt-in action:

```bash
mac-clean --apply --unused-images
```

There is no “all unused images” action. Package/app caches are instead shown as
individual, size-labelled entries:

```bash
mac-clean --cache-catalog-json
```

In the app, select only the entries to clear. For CLI use, pass one or more IDs
from that JSON catalog; the command asks for confirmation and checks relevant
apps before removing only those allowlisted paths:

```bash
mac-clean --no-docker --no-protected-audit --cache-id npx --apply
```

Each selected cache has its app/process checks repeated immediately before
removal. Busy caches are skipped individually; other safe selected caches still
clear. If either VS Code cache fails with `EPERM` or `EACCES`, Mac Clean records
its ID in `~/Library/Application Support/Mac Clean/cache-exclusions.json` and
omits it from future cache reviews and its individual audit entry. Busy apps
and temporary errors never create a permanent exclusion. Removing an entry
from that file opts it back into review after permissions have been resolved.
Protected app-directory discovery runs in a separate process with a time limit;
unavailable locations are skipped rather than blocking the entire cache review.

The catalog separates npm, npx, pnpm, VS Code updater and downloaded VSIX
packages, browser caches, Codex app cache, `.codex/.tmp`, `.codex/cache`, known
Teams browser/render caches, and rebuildable developer caches. Installed VS
Code extensions and Codex sessions are not cache targets.

The app's `Large Files / Downloads` review has an inline `File size > [n] MB`
filter (100 MB by default; enter `0` for all sizes). Select `Filter` or press
Return to list larger files and installer packages from `~/Downloads`, with
size and modification date. MB uses decimal units (1,000,000 bytes). Changing
the filter clears all selections; Select All applies only to visible results.
Selected items move to macOS Trash after confirmation and metadata revalidation.
The read-only CLI inventory is:

```bash
mac-clean --downloads-json
mac-clean --downloads-json --downloads-min-mb 500
```

## Worktree review

`Worktrees Review` inventories registered Git working copies in local projects
under `~/` (up to six directory levels deep). It skips hidden folders,
`~/Library`, `~/Applications`, `~/OrbStack`, media libraries, and generated
dependency/build folders so app-managed data is not searched as project content.
`Select All` selects only eligible copies: contained in local `main`, clean,
unlocked, no open files/process working directory, and no unreviewed ignored data.
Only root `.DS_Store`, `tsconfig.tsbuildinfo`, and a verified `node_modules`
symlink to the canonical repository's dependency folder may accompany removal.
`.env`, other ignored local data, and unknown process state block cleanup.
Codex-managed `.codex-worktrees` copies are retained for Codex's snapshot flow.

```bash
mac-clean --worktrees-json
mac-clean --worktree-path /absolute/path/to/reviewed/worktree
mac-clean --worktree-path /absolute/path/to/reviewed/worktree --apply
```

Removal rechecks each selection and uses `git worktree remove` without force.
Branches and committed history remain. Local `main` ancestry does not prove the
branch was pushed; this feature does not delete branches or Git objects.
Reported folder sizes are estimates; APFS shared blocks can affect space gained.

## Chat history review

`Chat History Review` inventories hidden local transcript and conversation files
for Codex, ChatGPT/Codex sessions, Claude Code, Gemini CLI, Antigravity, and
Antigravity IDE. Items are sorted from oldest to newest and include size, last
modified time, age, source, and the app that must be closed. `Select All` only
selects eligible items; `Select >30 days` selects eligible older history.
Use `File size > [n] MB` and select `Filter` (or press Return) to show only
individual history files larger than that value, before grouping by date.
Enter `0` for all sizes. Changing the filter clears selections; bulk actions
include only eligible files in the currently displayed date groups.

The inventory deliberately excludes Codex indexes/log databases, Claude VM
runtime bundles, app caches, settings, browser profiles, login data, and
Antigravity backup copies. Those are shown as protected context or omitted from
the deletion list. ChatGPT web browser storage is not treated as a transcript.

```bash
mac-clean --history-json
mac-clean --history-id 'codex:2026/09/09/rollout-....jsonl' --apply
```

Cleanup requires Codex/ChatGPT, Claude, Gemini CLI, Antigravity, or Antigravity
IDE to be closed as applicable. Each selected file is rechecked for path, size,
date, and open handles, then moved to macOS Trash. The tool does not alter
provider indexes or Git repositories. Empty Trash only after confirming the
corresponding app still opens and displays its remaining history.

## Deliberately protected data

Mac Clean never directly removes:

- Codex sessions or archived sessions
- Docker `Docker.raw`, Docker volumes, or containers
- OrbStack VM data
- LINE chat/media data or OneDrive synced data
- Aerial and macOS-managed storage
- Claude runtime bundles

Use each app's own controls or System Settings for those areas.

## Mac Clean app

Build and install the native app:

```bash
npm run mac:app:build
npm run mac:app:install -- --replace
```

After installation, open `~/Applications/Mac Clean.app` from Finder. Mac Clean
runs as a menu-bar app without a Dock icon. Clicking its menu-bar icon shows
`Open Mac Clean`, `Snapshot`, `Capture Delay`, and `Safe Disk Cleanup`, plus
`Quit Mac Clean`. `Capture Delay` is saved across launches; choose Off, 3, 5,
10 seconds, or Custom (0–60 seconds).
Safe Disk Cleanup asks for confirmation and runs without opening the main
window. Optional login launch does not perform scans or cleanup automatically.

Screenshot & Markup is available from the main window and with two configurable
global shortcuts. Set them directly in the two fields at the bottom of the main
window: Quick Capture records full-screen capture, and Area Capture records
region selection. The settings are saved for future launches.
`Control-Option-Command-S` selects an area by default;
`Shift-Control-Option-Command-F` captures the whole display under the pointer by
default and opens it directly in the editor.
Capture waits for the configured delay, then takes a frozen snapshot of each
display. For area selection, click the first corner, move the pointer to preview
the selection, then click the opposite corner to capture it. Releasing the mouse
keeps the selection open. Press Escape to cancel. Frozen screen capture requires
macOS 14 or later.
Pinned screenshots remain visible in that snapshot,
so a selection can include several pins. The editor also shows the captured
image dimensions. It supports outlined or filled
rectangles and ellipses with standard or thick outlines, pixelated mosaic regions, text notes, and
semi-transparent text watermarks. Watermark text can be saved as reusable
presets from the seal button. Each capture opens as its own borderless floating
preview with the editing toolbar visible, so annotations stay independent. Press
Pin to keep the image; the next capture is enabled only after pinning this image
or closing it with Escape. Once pinned, the toolbar hides; right-click the image
to show or hide it. Pinned images have no frame or drop shadow. With the toolbar
hidden, drag the image to arrange multiple pins; show the toolbar to edit or
unpin it. The compact glass toolbar is a separate floating panel that follows
the image, stays at a fixed size while the image zooms, and automatically uses
the side with more available screen space. It overlaps the image only when
neither outside edge has room. Capture again to create another preview; pinned
image toolbars are hidden while capturing and restored afterward. The main Mac Clean window stays
hidden during capture and while screenshot editors are open; use the menu-bar
icon to bring it back. Select any object to drag it; shape and mosaic handles
resize it. Rectangle, ellipse, and mosaic tools stay active for repeated marks.
Choose the text tool and click the image to type directly; scroll up or down to
resize text. Undo, copy to clipboard, and PNG, JPEG, or TIFF export are
available. Captures are not added to a history or saved automatically. The main
Mac Clean window also keeps a compact maximum width after screenshot actions.
macOS may request screen capture access the first time the
feature is used. The local build keeps a stable code identity so permission survives rebuilds. If you
previously enabled an older build, remove its Mac Clean entry in Screen & System
Audio Recording, add `~/Applications/Mac Clean.app`, and enable it again. Fully
quit and reopen Mac Clean before capturing. If access is denied, the app stays
open and offers a System Settings button instead of launching Settings itself.
