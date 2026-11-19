# Mac Clean app

The native app is a small AppKit menu-bar app with an optional control window
and a shortcut around the reviewed `mac-clean` CLI. It does not appear in the
Dock, run a timer, scan in the background, start Docker, or keep a second
cleanup policy in memory. Commands are spawned only when the user selects a
menu item.

`Launch Mac Clean at Login` is optional and off by default. When enabled, the
app registers itself with macOS using `SMAppService`; it is one resident app,
not a separate helper daemon. macOS may ask for approval in System Settings >
General > Login Items.

## Build and install

```bash
npm run mac:app:build
npm run mac:app:install
```

After installation, launch `Mac Clean.app` from Finder under Home >
Applications. It stays in the menu bar without a Dock icon. Click the menu-bar
icon to open the control window, start a screenshot, or run safe disk cleanup.
The app includes a custom metallic disk/checkmark icon.

The app expects the CLI at `~/.local/bin/mac-clean`; install it first from this project with:

```bash
npm run mac:clean:install
```

The app is installed per-user under `~/Applications` (Finder > Home >
Applications), so it needs no sudo or privileged helper. It can be replaced explicitly with:

```bash
npm run mac:app:install -- --replace
```

## Menu actions

- `Scan / Dry Run` is read-only.
- The app starts as a menu-bar resident without opening the main window or showing a Dock icon. Closing the window leaves the menu-bar icon and screenshot shortcut available.
- Clicking the Mac Clean menu-bar icon shows `Open Mac Clean`, `Snapshot`, `Capture Delay`, and `Safe Disk Cleanup`; `Quit Mac Clean` is at the bottom. Capture delay is saved across launches and can be set to Off, 3, 5, 10, or a custom 0–60 seconds. Safe cleanup asks for confirmation, runs without opening the main window, and briefly shows completion in the menu bar. Its full output is available in the control window afterward.
- `Launch Mac Clean at Login` can be toggled from the window. It is off by default and does not run cleanup automatically.
- `Safe Disk Cleanup` runs only the conservative Docker BuildKit/dangling-image cleanup after confirmation; package caches are reviewed separately.
- `Unused Images (30 days)` additionally prunes old unused Docker images.
- `Large Files / Downloads` has an inline `File size > [n] MB` filter (default 100; `0` shows all sizes). Select `Filter` or press Return to refresh the files and installer packages from `~/Downloads`, including size and modification date. MB uses 1,000,000 bytes. Changing the filter clears selections; `Select All` only applies to visible items. Selected items move to macOS Trash after confirmation and metadata revalidation using the reviewed threshold.
- `Cache Review` shows one checkbox per allowlisted cache with its own size and app-close requirements. npm, npx, pnpm, VS Code download/updater, Teams browser caches, and Codex temporary/cache paths are reviewed independently. `Select All` / `Deselect All` applies to the current review list.
- Cache cleanup rechecks each selected entry separately and skips busy entries while clearing other safe selections. VS Code updater/download caches that fail with `EPERM` or `EACCES` are recorded in `~/Library/Application Support/Mac Clean/cache-exclusions.json` and omitted from future reviews and individual audit sizing. App-running and temporary errors do not permanently hide a cache.
- Protected Group Container/Teams discovery and cache sizing have time limits. Unavailable locations are skipped so a pending macOS privacy prompt cannot hold the entire cache review open indefinitely.
- `Worktrees Review` lists registered copies under `~/projects` with sizes, branches, and eligibility reasons. Only clean, unlocked copies contained in local `main`, with no active open files or unreviewed ignored data, can be selected. Verified shared `node_modules` links and root build/Finder metadata are disposable. Select All skips blocked copies. Removal revalidates state and uses `git worktree remove` without force, preserving branches and committed history. Codex-managed `.codex-worktrees` copies remain protected.
- `Chat History Review` inventories hidden Codex session files, Claude Code JSONL transcripts, Gemini CLI chats, and Antigravity/Antigravity IDE conversation databases and protobuf files. The inline `File size > [n] MB` filter applies to each file before grouping by date; `0` shows all sizes. Changing the filter clears selections. Rows are sorted oldest first with size, last-used date, age, source, app-close requirements, and a reason when blocked. `Select All` and `Select >30 days` apply only to eligible files in the visible groups. Antigravity backups, app indexes, runtime bundles, caches, settings, credentials, and browser storage are protected or omitted. Selected transcripts move to macOS Trash only after revalidation.
- Codex `.tmp` and `.cache` are separate from `sessions` and `archived_sessions`; session history is never eligible for cleanup.
- Docker Desktop `Docker.raw` is report-only: the audit shows allocated and logical sizes plus last modification time. Finder reveal is inspection-only.
- Aerial and macOS-managed storage are directed to System Settings and are never deleted directly.
- Cleanup buttons skip protected app-data sizing, so they do not repeatedly request access to Group Containers, LINE, OneDrive, Teams, or other protected app data. Use `Scan / Dry Run` when a full protected-data audit is needed.
- `Scan / Dry Run` is the single disk/memory audit button in the header; its output includes the memory snapshot. The standalone Memory Snapshot card was removed, and the launch snapshot remains in `LIVE DETAIL` without auto-refresh.
- Scan, inventory, selection, and cleanup output stays in the main window's `LIVE DETAIL` panel. Download/cache checklists use that space; destructive actions still require a confirmation dialog.
- Review checkboxes and action buttons use larger hit targets; selecting all still shows the selected count and requires the existing confirmation before any cleanup.
- `Open Activity Monitor` opens Apple's built-in memory inspector.
- Screenshot capture has two configurable global shortcuts at the bottom of the main window: Quick Capture for direct full-screen capture (`Shift-Control-Option-Command-F` by default) and Area Capture for area selection (`Control-Option-Command-S` by default). Click either field to record its shortcut; Escape cancels recording. The full-screen shortcut captures the display under the pointer and opens it directly in the editor. For area capture, click the first corner, move the pointer to preview the selection, then click the opposite corner to capture. Escape cancels area selection. Both actions wait for the configured delay and use frozen display snapshots that include pinned screenshots. Frozen capture requires macOS 14 or later.

There is intentionally no generic `purge RAM` action. macOS manages compressed
memory and file cache; Memory Pressure and Swap Used are the useful health
signals.
