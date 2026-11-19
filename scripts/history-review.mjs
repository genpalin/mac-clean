import { access, lstat, readdir, rename, realpath } from "node:fs/promises";
import { constants } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, extname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const exec = promisify(execFile);
const home = homedir();
const trash = join(home, ".Trash");

const sources = [
  { id: "codex", label: "Codex session", root: join(home, ".codex", "sessions"), pattern: /\.(jsonl|zst)$/i, appLabels: ["Codex", "ChatGPT"], kind: "transcript" },
  { id: "codex-archived", label: "Codex archived session", root: join(home, ".codex", "archived_sessions"), pattern: /\.(jsonl|zst)$/i, appLabels: ["Codex", "ChatGPT"], kind: "transcript" },
  { id: "claude-code", label: "Claude Code project chat", root: join(home, ".claude", "projects"), pattern: /\.jsonl$/i, appLabels: ["Claude", "Claude Code"], kind: "transcript" },
  { id: "claude-app", label: "Claude local agent session", root: join(home, "Library", "Application Support", "Claude", "claude-code-sessions"), pattern: /\.(jsonl|json)$/i, appLabels: ["Claude", "Claude Code"], kind: "transcript" },
  { id: "gemini-cli", label: "Gemini CLI chat", root: join(home, ".gemini", "tmp"), pattern: /\.jsonl$/i, appLabels: ["Gemini CLI"], kind: "transcript" },
  { id: "antigravity", label: "Antigravity conversation", root: join(home, ".gemini", "antigravity", "conversations"), pattern: /\.(db|pb)$/i, appLabels: ["Antigravity"], kind: "conversation-db" },
  { id: "antigravity-ide", label: "Antigravity IDE conversation", root: join(home, ".gemini", "antigravity-ide", "conversations"), pattern: /\.(db|pb)$/i, appLabels: ["Antigravity IDE"], kind: "conversation-db" },
  { id: "antigravity-backup", label: "Antigravity backup conversation", root: join(home, ".gemini", "antigravity-backup", "conversations"), pattern: /\.(db|pb)$/i, appLabels: ["Antigravity", "Antigravity IDE"], kind: "backup-db" }
];

function within(path, root) {
  const rel = relative(resolve(root), resolve(path));
  return rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel);
}

async function exists(path) {
  try { await access(path, constants.F_OK); return true; } catch { return false; }
}

async function walkFiles(root, pattern) {
  const result = [];
  const pending = [root];
  while (pending.length) {
    const current = pending.pop();
    let entries;
    try { entries = await readdir(current, { withFileTypes: true }); } catch { continue; }
    for (const entry of entries) {
      if (entry.name === ".DS_Store" || entry.isSymbolicLink()) continue;
      const path = join(current, entry.name);
      if (entry.isDirectory()) pending.push(path);
      else if (entry.isFile() && pattern.test(entry.name)) result.push(path);
    }
  }
  return result;
}

async function openFiles() {
  try {
    const { stdout } = await exec("/usr/sbin/lsof", ["-n", "-P", "-F", "n"], { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
    return { ok: true, paths: stdout.split("\n").filter(line => line.startsWith("n/")).map(line => line.slice(1)) };
  } catch { return { ok: false, paths: [] }; }
}

async function appRunning(label) {
  const patterns = {
    Codex: "Codex.app/Contents/MacOS",
    ChatGPT: "ChatGPT.app/Contents/MacOS",
    Claude: "Claude.app/Contents/MacOS",
    "Claude Code": "claude",
    Antigravity: "Antigravity.app/Contents/MacOS",
    "Antigravity IDE": "Antigravity IDE.app/Contents/MacOS",
    "Gemini CLI": "gemini"
  };
  try {
    await exec("pgrep", ["-f", patterns[label] ?? label]);
    return true;
  } catch (error) { return error.code === 1 ? false : null; }
}

function ageDays(modifiedAtMs) {
  return Math.max(0, Math.floor((Date.now() - modifiedAtMs) / 86400000));
}

async function makeItem(source, path, openState, appStates) {
  const meta = await lstat(path);
  const rel = relative(source.root, path);
  const id = `${source.id}:${rel}`;
  const reasons = [];
  const open = openState.paths.some(openPath => openPath === path || openPath.startsWith(path + sep));
  const running = source.appLabels.filter(label => appStates.get(label) === true);
  if (!openState.ok) reasons.push("Could not verify open files");
  if (open) reasons.push("File is open");
  if (running.length) reasons.push(`Close ${running.join(" and ")}`);
  if (source.kind === "backup-db") reasons.push("Backup copy; review separately");
  if (!within(path, source.root) || meta.isSymbolicLink()) reasons.push("Outside protected history root");
  return {
    id,
    source: source.id,
    label: source.label,
    path,
    name: basename(path),
    relativePath: rel,
    kind: source.kind,
    sizeBytes: meta.size,
    modifiedAtMs: meta.mtimeMs,
    ageDays: ageDays(meta.mtimeMs),
    selectable: reasons.length === 0,
    reasons,
    appLabels: source.appLabels
  };
}

export async function historyCatalog() {
  const openState = await openFiles();
  const appLabels = [...new Set(sources.flatMap(source => source.appLabels))];
  const appStates = new Map(await Promise.all(appLabels.map(async label => [label, await appRunning(label)])));
  const items = [];
  const warnings = [];
  for (const source of sources) {
    if (!(await exists(source.root))) continue;
    for (const path of await walkFiles(source.root, source.pattern)) {
      try { items.push(await makeItem(source, path, openState, appStates)); } catch { warnings.push(`Could not inspect ${path}`); }
    }
  }
  return {
    items: items.sort((a, b) => a.modifiedAtMs - b.modifiedAtMs),
    warnings: [...(openState.ok ? [] : ["Process inspection is incomplete; history cleanup is disabled."]), ...warnings],
    protectedRoots: [
      join(home, ".codex", "thread_history_1.sqlite"),
      join(home, ".codex", "logs_2.sqlite"),
      join(home, "Library", "Application Support", "Claude", "vm_bundles"),
      join(home, ".gemini", "conversation_summaries.db")
    ]
  };
}

async function revalidate(item) {
  let meta;
  try { meta = await lstat(item.path); } catch { return { ok: false, reason: "File disappeared" }; }
  if (!meta.isFile() || meta.size !== item.sizeBytes || Math.abs(meta.mtimeMs - item.modifiedAtMs) > 1000) {
    return { ok: false, reason: "Changed since review; scan again" };
  }
  return { ok: true };
}

async function trashPath(path) {
  await realpath(trash);
  const destination = join(trash, `${basename(path)}.${randomUUID()}`);
  await rename(path, destination);
  return destination;
}

export async function moveHistoryToTrash(ids, reviewedItems) {
  const freshCatalog = await historyCatalog();
  const selected = new Map(freshCatalog.items.filter(item => ids.includes(item.id)).map(item => [item.id, item]));
  const results = [];
  for (const id of [...new Set(ids)]) {
    const item = selected.get(id);
    if (!item || !item.selectable) { results.push({ id, removed: false, reason: item?.reasons.join("; ") || "Not an eligible history file" }); continue; }
    const current = await revalidate(item);
    if (!current.ok) { results.push({ id, removed: false, path: item.path, reason: current.reason }); continue; }
    try {
      await trashPath(item.path);
      results.push({ id, removed: true, path: item.path, sizeBytes: item.sizeBytes, reason: "Moved to Trash" });
    } catch (error) { results.push({ id, removed: false, path: item.path, reason: error.message }); }
  }
  return results;
}

export { sources };
