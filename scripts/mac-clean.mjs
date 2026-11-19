#!/usr/bin/env node

import { execFile } from "node:child_process";
import { access, lstat, readdir, rm } from "node:fs/promises";
import { constants } from "node:fs";
import { homedir } from "node:os";
import { createInterface } from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { worktreeCatalog, removeReviewedWorktrees } from "./worktree-review.mjs";
import { historyCatalog, moveHistoryToTrash } from "./history-review.mjs";
import { cleanupCacheTargets, discoverProtectedCacheDirectories, excludeDeniedCache, readCacheExclusions } from "./cache-cleanup.mjs";

const execFileAsync = promisify(execFile);
const homeDir = homedir();
const dataMount = "/System/Volumes/Data";
const scriptPath = fileURLToPath(import.meta.url);
const defaultMinFree = "20gb";
const defaultImageAge = "720h";
const defaultDownloadsMinMb = 100;
const installerExtensions = new Set([".dmg", ".pkg", ".app", ".xip", ".iso", ".zip", ".7z", ".rar", ".tar", ".gz", ".bz2", ".xz"]);

const protectedReviewLabels = [
  ["OrbStack data", "managed VM disk; never delete data.img.raw directly"],
  ["LINE cache", "may contain locally cached chat media; clear from LINE after backup"],
  ["OneDrive data", "use OneDrive Free up space; do not delete synced files"],
  ["Codex sessions", "local task history; never included in cache cleanup"],
  ["Chat history transcripts", "review by date in Chat History Review; move selected files to Trash only after app-close checks"],
  ["Docker.raw", "report and reveal only; never delete or compact from Mac Clean"],
  ["Aerial and macOS-managed data", "open System Settings; do not remove managed files directly"],
  ["Claude VM bundles", "application runtime; do not remove as a generic cache"]
];

function printHelp() {
  console.log(`mac-clean — local macOS/Docker cleanup with a dry-run default

Usage:
  mac-clean                                  Audit disk, Docker, npm, and memory
  mac-clean --apply                          Apply conservative Docker cleanup
  mac-clean --apply --unused-images          Prune unused images older than 30 days
  mac-clean --cache-catalog-json             List individually reviewable caches
  mac-clean --cache-id <id> --apply          Remove selected cache entries after review
  mac-clean --downloads-json                 List large Downloads/install files as JSON
  mac-clean --downloads-json --downloads-min-mb <n>
                                             Filter Downloads by minimum size (default: 100)
  mac-clean --worktrees-json                 Review project worktrees and cleanup eligibility
  mac-clean --worktree-path <path> --apply    Remove selected eligible worktrees; preserve branches
  mac-clean --history-json                  Review Codex, Claude Code, and Antigravity history files
  mac-clean --history-id <id> --apply       Move selected history files to macOS Trash

Options:
  --apply                    Required before any mutation
  --yes                      Skip the final confirmation (still requires --apply)
  --unused-images            Prune unused images with an age filter (default: 720h)
  --cache-catalog-json       Emit the per-cache review catalog as JSON
  --cache-id <id>            Select a catalog cache (repeatable; requires --apply to remove)
  --downloads-json           Emit large files/installers from ~/Downloads as JSON
  --downloads-min-mb <n>     Show files larger than n MB; 0 shows all (default: 100)
  --worktrees-json           Emit worktree sizes, branches, and reasons to retain them
  --worktree-path <path>      Select a reviewed worktree (repeatable; requires --apply to remove)
  --history-json               Emit date-sorted LLM history inventory
  --history-id <id>           Select a reviewed history item (repeatable; requires --apply)
  --min-free <size>          BuildKit target free space (default: 20gb)
  --image-age <duration>     Image prune age filter (default: 720h)
  --no-docker                Skip Docker actions
  --no-protected-audit       Skip protected app-data sizing; keep disk/memory checks
  --help                     Show this help

Safety boundaries:
  - Default mode is read-only.
  - No sudo, no Docker volumes, no containers, no Codex sessions, no OneDrive data.
  - Cache cleanup is opt-in and per-entry; sessions are never cache targets.
  - Busy caches are skipped individually; other selected caches can still clear.
  - VS Code caches denied by macOS permissions are excluded from future reviews.
  - Docker.raw and Aerial/macOS-managed data are report/settings-only.
  - OrbStack's data.img.raw is never touched directly.
  - Memory is observed only; macOS manages RAM itself.
`);
}

function parseArgs(argv) {
  const args = {
    apply: false,
    yes: false,
    unusedImages: false,
    downloadsJson: false,
    downloadsMinMb: defaultDownloadsMinMb,
    cacheCatalogJson: false,
    cacheIds: [],
    worktreesJson: false,
    worktreePaths: [],
    historyJson: false,
    historyIds: [],
    minFree: defaultMinFree,
    imageAge: defaultImageAge,
    noDocker: false,
    noProtectedAudit: false,
    help: false
  };

  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--help" || value === "-h") args.help = true;
    else if (value === "--apply") args.apply = true;
    else if (value === "--yes" || value === "-y") args.yes = true;
    else if (value === "--unused-images") args.unusedImages = true;
    else if (value === "--downloads-json") args.downloadsJson = true;
    else if (value === "--downloads-min-mb") {
      const next = argv[index + 1];
      if (!next || next.startsWith("--")) throw new Error("--downloads-min-mb requires a non-negative number");
      args.downloadsMinMb = parseFileSizeMB(next);
      index += 1;
    }
    else if (value.startsWith("--downloads-min-mb=")) {
      args.downloadsMinMb = parseFileSizeMB(value.slice("--downloads-min-mb=".length));
    }
    else if (value === "--cache-catalog-json") args.cacheCatalogJson = true;
    else if (value === "--worktrees-json") args.worktreesJson = true;
    else if (value === "--history-json") args.historyJson = true;
    else if (value === "--history-id") {
      const next = argv[index + 1];
      if (!next || next.startsWith("--")) throw new Error("--history-id requires an id");
      args.historyIds.push(next);
      index += 1;
    }
    else if (value === "--worktree-path") {
      const next = argv[index + 1];
      if (!next || next.startsWith("--") || !isAbsolute(next)) throw new Error("--worktree-path requires an absolute path");
      args.worktreePaths.push(next);
      index += 1;
    }
    else if (value === "--cache-id") {
      const next = argv[index + 1];
      if (!next || next.startsWith("--")) throw new Error("--cache-id requires an id");
      args.cacheIds.push(next);
      index += 1;
    }
    else if (value === "--no-docker") args.noDocker = true;
    else if (value === "--no-npm") { /* retained as a harmless compatibility option */ }
    else if (value === "--no-protected-audit") args.noProtectedAudit = true;
    else if (value === "--min-free" || value === "--image-age") {
      const next = argv[index + 1];
      if (!next || next.startsWith("--")) throw new Error(`${value} requires a value`);
      if (value === "--min-free") args.minFree = next;
      else args.imageAge = next;
      index += 1;
    } else if (value.startsWith("--min-free=")) args.minFree = value.slice("--min-free=".length);
    else if (value.startsWith("--image-age=")) args.imageAge = value.slice("--image-age=".length);
    else throw new Error(`Unknown option: ${value}`);
  }

  if (args.yes && !args.apply) {
    throw new Error("--yes only makes sense together with --apply");
  }
  if ((args.worktreesJson || args.worktreePaths.length || args.historyJson || args.historyIds.length) &&
      (args.cacheIds.length || args.unusedImages || args.downloadsJson || args.cacheCatalogJson
       || (args.worktreesJson && (args.apply || args.worktreePaths.length))
       || (args.historyJson && (args.apply || args.historyIds.length)))) {
    throw new Error("History/worktree review and cleanup must run as a separate operation");
  }
  return args;
}

function parseFileSizeMB(value) {
  const parsed = Number(value);
  if (!value.trim() || !Number.isFinite(parsed) || parsed < 0 || parsed > 9_007_199_254) {
    throw new Error("--downloads-min-mb requires a non-negative number within the supported size range");
  }
  return parsed;
}

async function pathExists(path) {
  try {
    await access(path, constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

async function capture(command, commandArgs, options = {}) {
  try {
    const result = await execFileAsync(command, commandArgs, {
      cwd: process.cwd(),
      encoding: "utf8",
      maxBuffer: 8 * 1024 * 1024,
      ...options
    });
    return {
      ok: true,
      code: 0,
      stdout: result.stdout ?? "",
      stderr: result.stderr ?? ""
    };
  } catch (error) {
    return {
      ok: false,
      code: error.code ?? 1,
      stdout: error.stdout ?? "",
      stderr: error.stderr ?? error.message ?? String(error)
    };
  }
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes)) return "n/a";
  if (bytes < 1024) return `${Math.round(bytes)} B`;
  const units = ["KiB", "MiB", "GiB", "TiB"];
  let value = bytes;
  let unitIndex = -1;
  do {
    value /= 1024;
    unitIndex += 1;
  } while (value >= 1024 && unitIndex < units.length - 1);
  return `${value.toFixed(value >= 10 ? 1 : 2)} ${units[unitIndex]}`;
}

function parseDf(stdout) {
  const lines = stdout.split("\n").map(line => line.trim()).filter(Boolean);
  const fields = lines.at(-1)?.split(/\s+/) ?? [];
  if (fields.length < 5) return null;
  const sizeBlocks = Number(fields[1]);
  const usedBlocks = Number(fields[2]);
  const availableBlocks = Number(fields[3]);
  if (![sizeBlocks, usedBlocks, availableBlocks].every(Number.isFinite)) return null;
  return {
    size: sizeBlocks * 1024,
    used: usedBlocks * 1024,
    available: availableBlocks * 1024,
    capacity: fields[4]
  };
}

async function diskSnapshot() {
  const result = await capture("df", ["-Pk", dataMount]);
  if (!result.ok) return { error: result.stderr.trim() || "df failed" };
  const parsed = parseDf(result.stdout);
  return parsed ?? { error: "could not parse df output" };
}

async function directorySize(path) {
  if (!(await pathExists(path))) return null;
  const result = await capture("du", ["-sk", path], { timeout: 3000, killSignal: "SIGKILL" });
  if (!result.ok) return null;
  const line = result.stdout.split("\n").map(value => value.trim()).filter(Boolean).at(-1);
  const kib = Number(line?.split(/\s+/)[0]);
  return Number.isFinite(kib) ? kib * 1024 : null;
}

function isWithin(path, root) {
  const rel = relative(resolve(root), resolve(path));
  return rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
}

async function findPnpmStore() {
  const allowedRoots = [join(homeDir, "Library", "pnpm", "store"), join(homeDir, ".local", "share", "pnpm", "store")];
  const result = await capture("pnpm", ["store", "path"], { cwd: homeDir });
  if (result.ok) {
    const candidate = resolve(result.stdout.trim().split(/\r?\n/).at(-1) ?? "");
    if (allowedRoots.some(root => isWithin(candidate, root))) return candidate;
  }
  for (const root of allowedRoots) {
    if (await pathExists(root)) return root;
  }
  return null;
}

async function walkDirectories(root, visit, maxDepth = 7) {
  const pending = [{ path: root, depth: 0 }];
  let visited = 0;
  while (pending.length > 0 && visited < 30000) {
    const current = pending.pop();
    if (!current || current.depth > maxDepth) continue;
    let entries;
    try {
      entries = await readdir(current.path, { withFileTypes: true });
    } catch {
      continue;
    }
    visited += entries.length;
    for (const entry of entries) {
      if (entry.isSymbolicLink()) continue;
      const path = join(current.path, entry.name);
      if (entry.isDirectory()) {
        await visit(path, entry.name, true);
        const lowerName = entry.name.toLowerCase();
        const isPackageBundle = [".pkg", ".app", ".framework", ".bundle", ".plugin"].some(suffix => lowerName.endsWith(suffix));
        if (!entry.name.startsWith(".") && !["node_modules", ".git", "Contents", "Frameworks"].includes(entry.name)
          && !isPackageBundle) {
          pending.push({ path, depth: current.depth + 1 });
        }
      } else if (entry.isFile()) {
        await visit(path, entry.name, false);
      }
    }
  }
}

async function listDownloadCandidates(minSizeBytes, downloadsRoot = join(homeDir, "Downloads")) {
  const items = [];
  await walkDirectories(downloadsRoot, async (path, name, isDirectory) => {
    const extension = name.slice(name.lastIndexOf(".")).toLowerCase();
    const isInstaller = installerExtensions.has(extension);
    if (isDirectory && !([".pkg", ".app"].includes(extension) && isInstaller)) return;
    if (!isDirectory && name === ".DS_Store") return;

    let metadata;
    try {
      metadata = await lstat(path);
    } catch {
      return;
    }
    if (metadata.isSymbolicLink() || (!metadata.isFile() && !metadata.isDirectory())) return;
    const sizeBytes = isDirectory ? (await directorySize(path) ?? 0) : metadata.size;
    if (minSizeBytes > 0 && sizeBytes <= minSizeBytes) return;
    const relative = path.slice(downloadsRoot.length + 1);
    if (!relative || relative.startsWith(`..${sep}`)) return;
    items.push({
      path,
      name,
      relativePath: relative,
      sizeBytes,
      modifiedAtMs: metadata.mtimeMs,
      category: isDirectory ? "Installer package / app bundle" : isInstaller ? "Installer / archive" : "Large file",
      isDirectory
    });
  }, 9);
  items.sort((left, right) => right.sizeBytes - left.sizeBytes);
  return {
    minimumSizeMB: minSizeBytes / 1_000_000,
    items: items.slice(0, 250),
    warnings: items.length > 250 ? ["Showing the 250 largest matching items."] : []
  };
}

async function inspectDockerDisks() {
  const root = join(homeDir, "Library", "Containers", "com.docker.docker", "Data", "vms");
  const items = [];
  await walkDirectories(root, async (path, name, isDirectory) => {
    if (name !== "Docker.raw" || isDirectory) return;
    try {
      const metadata = await lstat(path);
      if (!metadata.isFile() || metadata.isSymbolicLink()) return;
      items.push({
        path,
        logicalSizeBytes: metadata.size,
        allocatedSizeBytes: Number.isFinite(metadata.blocks) ? metadata.blocks * 512 : null,
        modifiedAtMs: metadata.mtimeMs
      });
    } catch { /* a disappearing or inaccessible disk is report-only */ }
  }, 8);
  return items;
}

async function findGroupContainers() {
  const root = join(homeDir, "Library", "Group Containers");
  const directories = await discoverProtectedCacheDirectories(root, { groupNamesOnly: true });
  const find = predicate => {
    const name = directories.find(predicate);
    return name ? join(root, name) : null;
  };
  return {
    orbstack: find(name => name.endsWith(".dev.orbstack")),
    line: find(name => name.endsWith(".jp.naver.line.mac")),
    teams: find(name => name.endsWith(".com.microsoft.teams")),
    onedrive: find(name => name.includes("OneDriveSyncClientSuite"))
  };
}

function createAuditTargets(groups, pnpmStore, excludedCacheIds = new Set()) {
  const targets = [
    { label: "Codex temporary files", path: join(homeDir, ".codex", ".tmp"), policy: "rebuildable" },
    { label: "Codex cache", path: join(homeDir, ".codex", "cache"), policy: "rebuildable" },
    { label: "Codex sessions", path: join(homeDir, ".codex", "sessions"), policy: "protected" },
    { label: "Codex archived sessions", path: join(homeDir, ".codex", "archived_sessions"), policy: "protected" },
    { label: "npm package cache", path: join(homeDir, ".npm", "_cacache"), policy: "rebuildable" },
    { label: "npx downloaded packages", path: join(homeDir, ".npm", "_npx"), policy: "rebuildable" },
    { label: "macOS app caches (aggregate; overlaps entries below)", path: join(homeDir, "Library", "Caches"), policy: "review" },
    { label: "Claude application data", path: join(homeDir, "Library", "Application Support", "Claude"), policy: "protected" },
    { label: "Group Containers (aggregate; overlaps app data)", path: join(homeDir, "Library", "Group Containers"), policy: "review" }
  ];
  if (!excludedCacheIds.has("vscode-vsix")) {
    targets.push({ label: "VS Code downloaded extension packages", path: join(homeDir, "Library", "Application Support", "Code", "CachedExtensionVSIXs"), policy: "rebuildable" });
  }
  if (pnpmStore) targets.push({ label: "pnpm store", path: pnpmStore, policy: "rebuildable" });
  if (groups.orbstack) targets.push({ label: "OrbStack data", path: groups.orbstack, policy: "protected" });
  if (groups.line) targets.push({ label: "LINE data", path: groups.line, policy: "protected" });
  if (groups.onedrive) targets.push({ label: "OneDrive data", path: groups.onedrive, policy: "protected" });
  if (groups.teams) targets.push({ label: "Teams data", path: groups.teams, policy: "review" });
  return targets;
}

async function createCacheCatalog(groups, pnpmStore) {
  const targets = [
    { id: "npm-cacache", label: "npm package cache", path: join(homeDir, ".npm", "_cacache"), detail: "Packages can be downloaded again.", requiredApps: [], requiredProcesses: ["npm", "npx"] },
    { id: "npx", label: "npx package cache", path: join(homeDir, ".npm", "_npx"), detail: "Temporary npx packages; may need to download again.", requiredApps: [], requiredProcesses: ["npm", "npx"] },
    { id: "pnpm-store", label: "pnpm store", path: pnpmStore, detail: "Shared package store; packages will be fetched again if needed.", requiredApps: [], requiredProcesses: ["pnpm"] },
    { id: "vscode-updater", label: "VS Code updater cache", path: join(homeDir, "Library", "Caches", "com.microsoft.VSCode.ShipIt"), detail: "Quit Visual Studio Code before clearing.", requiredApps: ["Visual Studio Code"] },
    { id: "vscode-vsix", label: "VS Code extension download cache", path: join(homeDir, "Library", "Application Support", "Code", "CachedExtensionVSIXs"), detail: "Downloaded VSIX packages only; installed extensions are untouched.", requiredApps: ["Visual Studio Code"] },
    { id: "google-cache", label: "Google / Chrome cache", path: join(homeDir, "Library", "Caches", "Google"), detail: "Quit Google Chrome before clearing.", requiredApps: ["Google Chrome"] },
    { id: "edge-cache", label: "Microsoft Edge cache", path: join(homeDir, "Library", "Caches", "Microsoft Edge"), detail: "Quit Microsoft Edge before clearing.", requiredApps: ["Microsoft Edge"] },
    { id: "antigravity-cache", label: "Antigravity cache", path: join(homeDir, "Library", "Caches", "com.google.antigravity"), detail: "Quit Antigravity before clearing.", requiredApps: ["Antigravity", "Antigravity IDE"] },
    { id: "antigravity-updater", label: "Antigravity updater cache", path: join(homeDir, "Library", "Caches", "com.google.antigravity.ShipIt"), detail: "Quit Antigravity before clearing.", requiredApps: ["Antigravity", "Antigravity IDE"] },
    { id: "playwright-browser-cache", label: "Playwright browser cache", path: join(homeDir, "Library", "Caches", "ms-playwright"), detail: "Browser assets can be downloaded again.", requiredApps: [] },
    { id: "playwright-mcp-cache", label: "Playwright MCP cache", path: join(homeDir, "Library", "Caches", "ms-playwright-mcp"), detail: "Browser automation assets can be downloaded again.", requiredApps: [] },
    { id: "opencode-updater", label: "OpenCode updater cache", path: join(homeDir, "Library", "Caches", "@opencodedesktop-updater"), detail: "Quit OpenCode before clearing; updates can be downloaded again.", requiredApps: ["OpenCode"] },
    { id: "codex-app-cache", label: "Codex app cache", path: join(homeDir, "Library", "Caches", "Codex"), detail: "Quit Codex and ChatGPT before clearing.", requiredApps: ["Codex", "ChatGPT"] },
    { id: "codex-tmp", label: "Codex temporary files (.codex/.tmp)", path: join(homeDir, ".codex", ".tmp"), detail: "Temporary files only; quit Codex and ChatGPT first.", requiredApps: ["Codex", "ChatGPT"] },
    { id: "codex-cache", label: "Codex cache (.codex/cache)", path: join(homeDir, ".codex", "cache"), detail: "Cache only. Codex sessions and archived sessions are never included.", requiredApps: ["Codex", "ChatGPT"] },
    { id: "playwright-cli", label: "Playwright CLI cache", path: join(homeDir, ".cache", "playwright-cli"), detail: "Browser automation assets can be downloaded again.", requiredApps: [] },
    { id: "puppeteer", label: "Puppeteer cache", path: join(homeDir, ".cache", "puppeteer"), detail: "Browser assets can be downloaded again.", requiredApps: [] },
    { id: "prisma", label: "Prisma cache", path: join(homeDir, ".cache", "prisma"), detail: "Generated/downloaded artifacts can be rebuilt.", requiredApps: [] },
    { id: "codex-runtimes", label: "Codex runtime downloads", path: join(homeDir, ".cache", "codex-runtimes"), detail: "May need a large runtime download again; quit Codex and ChatGPT.", requiredApps: ["Codex", "ChatGPT"] }
  ];
  if (!pnpmStore) targets.splice(2, 1);

  const teamsRoots = [
    groups.teams ? join(groups.teams, "Library", "Application Support") : null,
    join(homeDir, "Library", "Containers", "com.microsoft.teams2", "Data", "Library", "Application Support"),
    join(homeDir, "Library", "Containers", "com.microsoft.teams", "Data", "Library", "Application Support")
  ].filter(Boolean);
  const teamCachePaths = new Set();
  for (const root of teamsRoots) {
    for (const path of await discoverProtectedCacheDirectories(root)) teamCachePaths.add(path);
  }
  let teamIndex = 0;
  for (const path of [...teamCachePaths].sort()) {
    targets.push({
      id: `teams-cache-${teamIndex++}`,
      label: `Microsoft Teams ${path.split(sep).at(-1)} cache`,
      path,
      detail: "Known browser/render cache only; quit Microsoft Teams before clearing.",
      requiredApps: ["Microsoft Teams"]
    });
  }

  if (groups.teams) {
    targets.push({
      id: "teams-logs",
      label: "Microsoft Teams logs",
      path: join(groups.teams, "Library", "Application Support", "Logs"),
      detail: "Logs may help troubleshoot Teams; inspect before clearing.",
      requiredApps: ["Microsoft Teams"]
    });
  }
  return targets;
}

async function cacheCatalogJson() {
  const excludedCacheIds = new Set((await readCacheExclusions()).map(item => item.id));
  const groups = await findGroupContainers();
  const pnpmStore = await findPnpmStore();
  const targets = await createCacheCatalog(groups, pnpmStore);
  const items = [];
  for (const target of targets) {
    if (!target.path || excludedCacheIds.has(target.id)) continue;
    let metadata;
    try {
      metadata = await lstat(target.path);
    } catch { continue; }
    if (metadata.isSymbolicLink() || (!metadata.isDirectory() && !metadata.isFile())) continue;
    const measuredSize = await directorySize(target.path);
    const sizeBytes = measuredSize ?? (metadata.isFile() ? metadata.size : null);
    if (sizeBytes === null || sizeBytes <= 0) continue;
    items.push({ ...target, requiredProcesses: target.requiredProcesses ?? [], sizeBytes });
  }
  return { items, protectedPaths: [join(homeDir, ".codex", "sessions"), join(homeDir, ".codex", "archived_sessions")] };
}

async function inspectMemory() {
  const result = await capture("memory_pressure", []);
  if (!result.ok && !result.stdout) return null;
  const match = result.stdout.match(/System-wide memory free percentage:\s*(\d+)%/);
  return {
    freePercent: match ? Number(match[1]) : null,
    output: result.stdout.trim()
  };
}

async function appIsRunning(pattern) {
  const result = await capture("pgrep", ["-f", pattern]);
  if (result.code === "ENOENT") return null;
  if (result.ok) return true;
  return result.code === 1 ? false : null;
}

async function runningApps(requiredLabels = null) {
  const checks = [
    ["Codex", "Codex.app/Contents/MacOS"],
    ["ChatGPT", "ChatGPT.app/Contents/MacOS"],
    ["Microsoft Teams", "Microsoft Teams.app/Contents/MacOS"],
    ["LINE", "LINE.app/Contents/MacOS"],
    ["Visual Studio Code", "Visual Studio Code.app/Contents/MacOS"],
    ["Google Chrome", "Google Chrome.app/Contents/MacOS"],
    ["Microsoft Edge", "Microsoft Edge.app/Contents/MacOS"],
    ["Antigravity", "Antigravity.app/Contents/MacOS"],
    ["Antigravity IDE", "Antigravity IDE.app/Contents/MacOS"],
    ["OpenCode", "OpenCode.app/Contents/MacOS"],
    ["OrbStack", "OrbStack.app/Contents/MacOS"]
  ];
  const selectedChecks = requiredLabels ? checks.filter(([label]) => requiredLabels.includes(label)) : checks;
  const statuses = await Promise.all(selectedChecks.map(async ([label, pattern]) => [label, await appIsRunning(pattern)]));
  return statuses.filter(([, value]) => value !== false).map(([label, value]) => value === true ? label : `${label} (could not verify)`);
}

function packageProcessPattern(name) {
  const escaped = name.replace(/[\\^$.*+?()[\]{}|]/g, "\\$&");
  // Match an executable path (or an npm CLI script path), not a plain
  // `--cache-id npx` argument from this cleanup process itself.
  return `(^|/)${escaped}([._-]|$|[ /])`;
}

async function runningPackageManagers(requiredNames) {
  const statuses = await Promise.all(requiredNames.map(async name => {
    const result = await capture("pgrep", ["-f", packageProcessPattern(name)]);
    const state = result.ok ? true : result.code === 1 ? false : null;
    return [name, state];
  }));
  return statuses.filter(([, state]) => state !== false)
    .map(([name, state]) => state === true ? `${name} process` : `${name} process (could not verify)`);
}

function isAllowedCacheTarget(target, groups, pnpmStore) {
  const allowedRoots = [
    join(homeDir, "Library", "Caches"),
    join(homeDir, ".cache"),
    join(homeDir, ".npm"),
    join(homeDir, ".codex", ".tmp"),
    join(homeDir, ".codex", "cache"),
    join(homeDir, "Library", "Application Support", "Code", "CachedExtensionVSIXs"),
    pnpmStore,
    groups.teams,
    join(homeDir, "Library", "Containers", "com.microsoft.teams2", "Data", "Library", "Application Support"),
    join(homeDir, "Library", "Containers", "com.microsoft.teams", "Data", "Library", "Application Support")
  ].filter(Boolean);
  return isWithin(target.path, homeDir)
    && allowedRoots.some(root => root && isWithin(target.path, root));
}

async function rejectSymlinkAncestors(path) {
  if (!isWithin(path, homeDir) || resolve(path) === resolve(homeDir)) {
    throw new Error(`blocked cache path outside the user's home: ${path}`);
  }
  let current = homeDir;
  for (const component of relative(homeDir, resolve(path)).split(sep).filter(Boolean)) {
    current = join(current, component);
    const metadata = await lstat(current);
    if (metadata.isSymbolicLink()) throw new Error(`refusing symlink in cache path: ${current}`);
  }
}

async function removeCacheTarget(target, groups, pnpmStore) {
  if (!isAllowedCacheTarget(target, groups, pnpmStore)) throw new Error(`blocked cache path: ${target.path}`);
  await rejectSymlinkAncestors(target.path);
  const metadata = await lstat(target.path);
  if (metadata.isSymbolicLink()) throw new Error(`refusing symlink cache path: ${target.path}`);
  if (!metadata.isDirectory() && !metadata.isFile()) throw new Error(`refusing non-file cache path: ${target.path}`);
  await rm(target.path, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
  if (await pathExists(target.path)) {
    throw new Error("path still exists after removal; close the related app and try again");
  }
}

function commandActions(args) {
  const actions = [];
  if (!args.noDocker) {
    actions.push({
      label: `Prune BuildKit cache while targeting at least ${args.minFree} free`,
      command: ["docker", "buildx", "prune", "--force", "--min-free-space", args.minFree]
    });
    actions.push({
      label: "Prune dangling Docker images only",
      command: ["docker", "image", "prune", "--force"]
    });
    if (args.unusedImages) {
      actions.push({
        label: `Prune unused images older than ${args.imageAge}`,
        command: ["docker", "image", "prune", "--all", "--force", "--filter", `until=${args.imageAge}`]
      });
    }
  }
  return actions;
}

function printAudit({ disk, targets, memory, dockerDisks }) {
  console.log("[mac-clean] read-only audit");
  if (disk.error) console.log(`Disk: unavailable (${disk.error})`);
  else console.log(`Disk: ${formatBytes(disk.available)} free / ${formatBytes(disk.size)} total (${disk.capacity})`);

  console.log("\nLargest known areas:");
  for (const target of targets) {
    if (target.size === null) continue;
    const suffix = target.policy === "protected" ? " [protected]" : target.policy === "rebuildable" ? " [rebuildable]" : " [review]";
    console.log(`  ${formatBytes(target.size).padStart(10)}  ${target.label}${suffix}`);
  }

  console.log("\nDocker disk images (report only):");
  if (dockerDisks.length === 0) console.log("  Docker.raw not found in the standard Docker Desktop data path.");
  for (const item of dockerDisks) {
    console.log(`  ${formatBytes(item.allocatedSizeBytes ?? NaN)} allocated / ${formatBytes(item.logicalSizeBytes)} logical  ${item.path}`);
    console.log(`    Modified: ${new Date(item.modifiedAtMs).toLocaleString()}`);
  }

  if (memory?.freePercent !== null) {
    console.log(`\nMemory: ${memory.freePercent}% system-wide free according to memory_pressure`);
  } else {
    console.log("\nMemory: see Activity Monitor; memory_pressure output was unavailable");
  }

  console.log("\nProtected from automatic deletion:");
  for (const [label, reason] of protectedReviewLabels) console.log(`  - ${label}: ${reason}`);
}

async function printPlan(actions, cacheTargets) {
  console.log("\nPlanned actions:");
  if (actions.length === 0 && cacheTargets.length === 0) console.log("  (none)");
  for (const action of actions) console.log(`  - ${action.label}`);
  for (const target of cacheTargets) {
    console.log(`  - Remove ${target.label} (${formatBytes(target.sizeBytes ?? 0)})`);
  }
}

async function confirm() {
  const readline = createInterface({ input, output });
  try {
    const answer = await readline.question("\nProceed with the listed cleanup? [y/N] ");
    return /^(y|yes)$/i.test(answer.trim());
  } finally {
    readline.close();
  }
}

async function executeCommand(action) {
  console.log(`\n[mac-clean] ${action.label}`);
  const result = await capture(action.command[0], action.command.slice(1));
  if (result.stdout.trim()) process.stdout.write(`${result.stdout.trim()}\n`);
  if (result.stderr.trim()) process.stderr.write(`${result.stderr.trim()}\n`);
  if (!result.ok) {
    console.error(`[mac-clean] command failed: ${action.command.join(" ")}`);
    return false;
  }
  return true;
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(`[mac-clean] ${error.message}`);
    process.exitCode = 2;
    return;
  }

  if (args.help) {
    printHelp();
    return;
  }
  if (args.downloadsJson) {
    process.stdout.write(`${JSON.stringify(await listDownloadCandidates(args.downloadsMinMb * 1_000_000))}\n`);
    return;
  }
  if (args.cacheCatalogJson) {
    process.stdout.write(`${JSON.stringify(await cacheCatalogJson())}\n`);
    return;
  }
  if (args.worktreesJson) {
    process.stdout.write(`${JSON.stringify(await worktreeCatalog())}\n`);
    return;
  }
  if (args.historyJson) {
    process.stdout.write(`${JSON.stringify(await historyCatalog())}\n`);
    return;
  }
  if (args.historyIds.length) {
    const catalog = await historyCatalog();
    const selected = [...new Set(args.historyIds)].map(id => catalog.items.find(item => item.id === id));
    if (selected.some(item => !item?.selectable)) {
      console.error("[mac-clean] Selection includes blocked or changed history files. Close the listed apps and scan again; nothing was moved.");
      process.exitCode = 2;
      return;
    }
    const total = selected.reduce((sum, item) => sum + item.sizeBytes, 0);
    for (const item of selected) console.log(`[mac-clean] selected: ${item.label} ${item.relativePath} (${formatBytes(item.sizeBytes)}, ${item.ageDays} days old)`);
    console.log(`[mac-clean] estimated space: ${formatBytes(total)}; files will move to macOS Trash`);
    if (!args.apply) { console.log("[mac-clean] dry-run only; use --apply after review"); return; }
    if (!args.yes && !(await confirm())) { console.log("[mac-clean] cancelled; no changes made"); return; }
    const before = await diskSnapshot();
    const results = await moveHistoryToTrash(args.historyIds, catalog.items);
    for (const item of results) console.log(`[mac-clean] ${item.removed ? "moved" : "skipped"}: ${item.path ?? item.id} — ${item.reason}`);
    const after = await diskSnapshot();
    if (!before.error && !after.error) console.log(`[mac-clean] disk free-space change: ${formatBytes(after.available - before.available)}`);
    if (results.some(item => !item.removed)) process.exitCode = 1;
    return;
  }
  if (args.worktreePaths.length) {
    const catalog = await worktreeCatalog();
    const selected = [...new Set(args.worktreePaths)].map(path => catalog.items.find(item => item.path === path));
    if (selected.some(item => !item?.eligible)) {
      console.error("[mac-clean] Selection includes blocked or unavailable worktrees. Scan again; nothing was removed.");
      process.exitCode = 2;
      return;
    }
    for (const item of selected) console.log(`[mac-clean] eligible: ${item.path} (${formatBytes(item.sizeBytes)}); branch ${item.branch} will remain`);
    if (!args.apply) { console.log("[mac-clean] dry-run only; use --apply after review"); return; }
    if (!args.yes && !(await confirm())) { console.log("[mac-clean] cancelled"); return; }
    const before = await diskSnapshot();
    const results = await removeReviewedWorktrees(args.worktreePaths, {
      expectedHeads: Object.fromEntries(selected.map(item => [item.path, item.head]))
    });
    for (const item of results) console.log(`[mac-clean] ${item.removed ? "removed" : "skipped"}: ${item.path} — ${item.reason}`);
    const after = await diskSnapshot();
    if (!before.error && !after.error) console.log(`[mac-clean] disk free-space change: ${formatBytes(after.available - before.available)}`);
    console.log(`[mac-clean] removed ${results.filter(item => item.removed).length} worktrees; branches preserved`);
    if (results.some(item => !item.removed)) process.exitCode = 1;
    return;
  }
  if (process.platform !== "darwin") {
    console.error("[mac-clean] this host cleanup tool currently supports macOS only");
    process.exitCode = 2;
    return;
  }

  const groups = await findGroupContainers();
  const pnpmStore = await findPnpmStore();
  const excludedCacheIds = new Set((await readCacheExclusions()).map(item => item.id));
  const rawTargets = args.noProtectedAudit ? [] : createAuditTargets(groups, pnpmStore, excludedCacheIds);
  const targets = await Promise.all(rawTargets.map(async target => ({ ...target, size: await directorySize(target.path) })));
  const memory = await inspectMemory();
  const diskBefore = await diskSnapshot();
  const dockerDisks = await inspectDockerDisks();
  printAudit({ disk: diskBefore, targets, memory, dockerDisks });
  if (args.noProtectedAudit) {
    console.log("[mac-clean] protected app-data sizing skipped");
  }

  const actions = commandActions(args);
  let cacheTargets = [];
  if (args.cacheIds.length > 0) {
    const catalog = await cacheCatalogJson();
    const indexed = new Map(catalog.items.map(item => [item.id, item]));
    const selectedIds = [...new Set(args.cacheIds)];
    const missing = selectedIds.filter(id => !indexed.has(id));
    if (missing.length > 0) {
      console.error(`[mac-clean] cache id not found or no longer available: ${missing.join(", ")}`);
      process.exitCode = 2;
      return;
    }
    cacheTargets = selectedIds.map(id => indexed.get(id));
  }
  const plannedActions = cacheTargets.length > 0 ? [] : actions;
  await printPlan(plannedActions, cacheTargets);

  if (!args.apply) {
    console.log("\n[mac-clean] dry-run only; no files or Docker objects were changed");
    console.log("[mac-clean] use --apply after reviewing the plan");
    return;
  }

  if (!args.yes && !(await confirm())) {
    console.log("[mac-clean] cancelled; no changes made");
    return;
  }

  let failures = 0;
  for (const action of plannedActions) {
    if (!(await executeCommand(action))) failures += 1;
  }
  if (cacheTargets.length) {
    const results = await cleanupCacheTargets(cacheTargets, {
      blockersFor: async target => {
        const [apps, processes] = await Promise.all([
          runningApps(target.requiredApps),
          runningPackageManagers(target.requiredProcesses ?? [])
        ]);
        return [...apps, ...processes];
      },
      removeTarget: async target => {
        console.log(`\n[mac-clean] removing ${target.label}`);
        await removeCacheTarget(target, groups, pnpmStore);
      },
      onResult: async result => {
        if (result.removed) {
          console.log(`[mac-clean] removed ${result.target.label}`);
        } else {
          console.error(`[mac-clean] skipped ${result.target.label}: ${result.reason}`);
          try {
            if (await excludeDeniedCache(result.target, result.error)) {
              console.log(`[mac-clean] ${result.target.label} excluded from future scans after permission denial`);
            }
          } catch (error) {
            console.error(`[mac-clean] could not save cache exclusion: ${error.message}`);
          }
        }
      }
    });
    failures += results.filter(result => !result.removed).length;
  }

  const diskAfter = await diskSnapshot();
  if (!diskBefore.error && !diskAfter.error) {
    const delta = diskAfter.available - diskBefore.available;
    console.log(`\n[mac-clean] disk after: ${formatBytes(diskAfter.available)} free / ${diskAfter.capacity}`);
    console.log(`[mac-clean] free-space change: ${delta >= 0 ? "+" : ""}${formatBytes(delta)}`);
  } else if (diskAfter.error) {
    console.log(`\n[mac-clean] disk after: unavailable (${diskAfter.error})`);
  }
  if (failures > 0) {
    console.error(`[mac-clean] completed with ${failures} failed action(s)`);
    process.exitCode = 1;
  } else {
    console.log("[mac-clean] cleanup completed");
  }
}

if (process.argv[1] && resolve(process.argv[1]) === scriptPath) await main();

export { commandActions, formatBytes, listDownloadCandidates, packageProcessPattern, parseArgs, protectedReviewLabels };
