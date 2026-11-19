import { execFile } from "node:child_process";
import { lstat, readdir, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join, relative, resolve, sep, isAbsolute } from "node:path";
import { promisify } from "node:util";

const exec = promisify(execFile);
const defaultRoot = homedir();
const maximumProjectDepth = 6;
const skippedProjectDirectories = new Set(["node_modules", "dist", "build", "vendor"]);
const protectedHomeDirectories = new Set(["Library", "Applications", "OrbStack", "Movies", "Music", "Pictures", "Public"]);

function within(path, root) {
  const rel = relative(root, path);
  return rel !== "" && rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel);
}

function isProtectedHomePath(path, root) {
  if (root !== defaultRoot || !within(path, root)) return false;
  return protectedHomeDirectories.has(relative(root, path).split(sep)[0]);
}

async function command(name, args, cwd) {
  try {
    const result = await exec(name, args, {
      cwd, encoding: "utf8", maxBuffer: 32 * 1024 * 1024, timeout: 30000,
      env: { ...process.env, GIT_OPTIONAL_LOCKS: "0" }
    });
    return { ok: true, ...result };
  } catch (error) {
    return { ok: false, code: error.code, stdout: error.stdout ?? "", stderr: error.stderr ?? error.message };
  }
}

// Linked worktrees and symlinked folders are never used as discovery roots.
async function repositories(root) {
  const found = [];
  const pending = [{ path: root, depth: 0 }];
  while (pending.length) {
    const { path, depth } = pending.pop();
    let entries;
    try { entries = await readdir(path, { withFileTypes: true }); } catch { continue; }
    if (entries.some(entry => entry.name === ".git" && entry.isDirectory())) {
      found.push(path);
      continue;
    }
    if (depth >= maximumProjectDepth) continue;
    for (const entry of entries) {
      if (!entry.isDirectory() || entry.isSymbolicLink() || entry.name.startsWith(".")
          || skippedProjectDirectories.has(entry.name)
          || (depth === 0 && protectedHomeDirectories.has(entry.name))) continue;
      pending.push({ path: join(path, entry.name), depth: depth + 1 });
    }
  }
  return found;
}

function parseWorktrees(output) {
  return output.split("\0\0").filter(Boolean).map(record => {
    const fields = record.split("\0");
    return {
      path: fields.find(field => field.startsWith("worktree "))?.slice(9),
      head: fields.find(field => field.startsWith("HEAD "))?.slice(5) ?? "",
      branch: fields.find(field => field.startsWith("branch "))?.slice(7).replace(/^refs\/heads\//, "") ?? "(detached)",
      locked: fields.some(field => field === "locked" || field.startsWith("locked ")),
      prunable: fields.some(field => field === "prunable" || field.startsWith("prunable "))
    };
  });
}

async function openPaths() {
  // Includes cwd and open files. A failed/truncated inventory blocks cleanup.
  const result = await command("/usr/sbin/lsof", ["-n", "-P", "-F", "n"]);
  return {
    ok: result.ok && !result.stderr.trim(),
    paths: result.stdout.split("\n").filter(line => line.startsWith("n/")).map(line => line.slice(1))
  };
}

async function disposableIgnoredFiles(path, repo, output) {
  const unknown = [];
  for (const file of output.split("\0").filter(Boolean)) {
    try {
      const absolute = join(path, file);
      const metadata = await lstat(absolute);
      if ([".DS_Store", "tsconfig.tsbuildinfo"].includes(file) && metadata.isFile()) continue;
      // Unlinking this entry preserves the canonical project's shared dependency directory.
      if (file === "node_modules" && metadata.isSymbolicLink()
          && await realpath(absolute) === await realpath(join(repo, "node_modules"))) continue;
    } catch { /* Missing/changing files are not assumed safe. */ }
    unknown.push(file);
  }
  return unknown;
}

async function inspect(repo, entry, root, activity) {
  const reasons = [];
  const path = resolve(entry.path);
  const item = { ...entry, path, repoPath: repo, name: basename(path), sizeBytes: 0, eligible: false, reasons };
  if (!within(path, root) || isProtectedHomePath(path, root) || path === repo || entry.locked || entry.prunable) {
    reasons.push("Outside searched project folders, primary checkout, locked, or stale registration");
    return item;
  }
  if (relative(root, path).split(sep).includes(".codex-worktrees")) {
    reasons.push("Codex-managed worktree: archive through Codex to preserve its snapshot");
  }
  try {
    if (!(await lstat(path)).isDirectory() || await realpath(path) !== path) {
      reasons.push("Linked or non-directory path"); return item;
    }
  } catch { reasons.push("Worktree folder unavailable"); return item; }
  const [status, ignored, main, size, common] = await Promise.all([
    command("git", ["status", "--porcelain=v1", "-z", "--untracked-files=all"], path),
    command("git", ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], path),
    command("git", ["merge-base", "--is-ancestor", entry.head, "refs/heads/main"], repo),
    command("du", ["-sk", path]),
    command("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], path)
  ]);
  item.sizeBytes = Number(size.stdout.trim().split(/\s+/)[0]) * 1024 || 0;
  if (!size.ok) reasons.push("Could not measure storage");
  if (!common.ok || resolve(common.stdout.trim()) !== join(repo, ".git")) reasons.push("Repository identity changed");
  if (!status.ok || !ignored.ok) reasons.push("Could not verify Git files");
  if (status.stdout) reasons.push("Uncommitted or untracked files");
  // Small generated metadata and verified shared dependency links are disposable.
  // Everything else (including .env and local media/data) blocks removal.
  const ignoredLocalFiles = await disposableIgnoredFiles(path, repo, ignored.stdout);
  item.ignoredLocalFiles = ignoredLocalFiles;
  if (ignoredLocalFiles.length) reasons.push(`Ignored local files require review: ${ignoredLocalFiles.slice(0,3).join(", ")}`);
  if (!main.ok) reasons.push("Not contained in local main, or main unavailable");
  if (!activity.ok) reasons.push("Could not verify running processes/open files");
  if (activity.paths.some(open => open === path || open.startsWith(path + sep))) reasons.push("In use by a running process");
  item.eligible = reasons.length === 0;
  return item;
}

export async function worktreeCatalog({ root = defaultRoot, activity } = {}) {
  root = resolve(root);
  const warnings = [];
  try {
    if (await realpath(root) !== root) throw new Error("Projects root must not be a symlink");
  } catch (error) { return { items: [], warnings: [error.message] }; }
  activity ??= await openPaths();
  if (!activity.ok) warnings.push("Process inspection is incomplete; cleanup is disabled.");
  const items = [];
  for (const repo of await repositories(root)) {
    const result = await command("git", ["worktree", "list", "--porcelain", "-z"], repo);
    if (!result.ok) { warnings.push(`Could not list worktrees: ${repo}`); continue; }
    const entries = parseWorktrees(result.stdout).filter(entry => entry.path && resolve(entry.path) !== repo);
    for (const entry of entries) {
      // Worktrees outside the user's home are never selected by this tool.
      if (within(resolve(entry.path), root)) items.push(await inspect(repo, entry, root, activity));
    }
  }
  return { items: items.sort((a, b) => b.sizeBytes - a.sizeBytes), warnings };
}

export async function removeReviewedWorktrees(paths, { root = defaultRoot, activity, expectedHeads = {} } = {}) {
  const results = [];
  root = resolve(root);
  const reviewed = await worktreeCatalog({ root, activity });
  for (const path of [...new Set(paths)]) {
    // Re-check state and processes immediately before EACH removal.
    const previous = reviewed.items.find(item => item.path === path);
    const registry = previous ? await command("git", ["worktree", "list", "--porcelain", "-z"], previous.repoPath) : null;
    const entry = registry?.ok ? parseWorktrees(registry.stdout).find(entry => entry.path === path) : null;
    const item = entry ? await inspect(previous.repoPath, entry, root, activity ?? await openPaths()) : null;
    if (!item?.eligible || (expectedHeads[path] && expectedHeads[path] !== item.head)) {
      results.push({ path, removed: false, reason: item?.reasons.join("; ") || "Not an eligible registered worktree, or HEAD changed" });
      continue;
    }
    const result = await command("git", ["worktree", "remove", "--", path], item.repoPath);
    results.push({ path, removed: result.ok, branch: item.branch, sizeBytes: item.sizeBytes,
      reason: result.ok ? "Branch preserved" : result.stderr.trim() });
  }
  return results;
}
