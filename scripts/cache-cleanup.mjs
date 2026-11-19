import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const defaultExclusionsPath = join(homedir(), "Library", "Application Support", "Mac Clean", "cache-exclusions.json");
const excludableIds = new Set(["vscode-updater", "vscode-vsix"]);
const execFileAsync = promisify(execFile);

// An OS privacy prompt can leave opendir pending indefinitely. Keep protected
// discovery in a disposable process so a timeout releases all its FS workers.
export async function discoverProtectedCacheDirectories(root, { groupNamesOnly = false, timeoutMs = 2000 } = {}) {
  const worker = `
    import { readdir } from 'node:fs/promises';
    import { join } from 'node:path';
    const root = process.argv[1];
    const groups = process.argv[2] === 'groups';
    const result = [];
    const pending = [{ path: root, depth: 0 }];
    let visited = 0;
    while (pending.length && visited < 30000) {
      const current = pending.pop();
      let entries;
      try { entries = await readdir(current.path, { withFileTypes: true }); }
      catch { continue; }
      visited += entries.length;
      for (const entry of entries) {
        if (!entry.isDirectory() || entry.isSymbolicLink()) continue;
        const path = join(current.path, entry.name);
        if (groups) result.push(entry.name);
        else {
          if (['Cache', 'Code Cache', 'GPUCache'].includes(entry.name)) result.push(path);
          else if (current.depth < 6 && !entry.name.startsWith('.')
            && !/\\.(app|bundle|framework|plugin)$/i.test(entry.name)) {
            pending.push({ path, depth: current.depth + 1 });
          }
        }
      }
      if (groups) break;
    }
    process.stdout.write(JSON.stringify(result));
  `;
  try {
    const { stdout } = await execFileAsync(process.execPath, [
      "--input-type=module", "-e", worker, root, groupNamesOnly ? "groups" : "teams"
    ], { encoding: "utf8", timeout: timeoutMs, killSignal: "SIGKILL", maxBuffer: 2 * 1024 * 1024 });
    const paths = JSON.parse(stdout);
    return Array.isArray(paths) ? paths.filter(path => typeof path === "string") : [];
  } catch {
    return [];
  }
}

export function isPermissionDenied(error) {
  return ["EACCES", "EPERM"].includes(error?.code);
}

export async function readCacheExclusions(path = defaultExclusionsPath) {
  try {
    const data = JSON.parse(await readFile(path, "utf8"));
    return Array.isArray(data.items) ? data.items.filter(item => excludableIds.has(item.id)) : [];
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw new Error(`Could not read cache exclusions: ${error.message}`);
  }
}

export async function excludeDeniedCache(target, error, path = defaultExclusionsPath) {
  if (!excludableIds.has(target.id) || !isPermissionDenied(error)) return false;
  const items = (await readCacheExclusions(path)).filter(item => item.id !== target.id);
  items.push({ id: target.id, path: target.path, code: error.code, excludedAt: new Date().toISOString() });
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify({ version: 1, items }, null, 2)}\n`, { mode: 0o600 });
  return true;
}

// Inspect each selected entry again immediately before clearing it. A busy or
// inaccessible cache must not prevent another independently safe entry clearing.
export async function cleanupCacheTargets(targets, { blockersFor, removeTarget, onResult }) {
  const results = [];
  for (const target of targets) {
    let result;
    try {
      const blockers = await blockersFor(target);
      if (blockers.length) {
        result = { target, removed: false, reason: `Close: ${blockers.join(", ")}` };
      } else {
        await removeTarget(target);
        result = { target, removed: true };
      }
    } catch (error) {
      result = { target, removed: false, reason: error.message, error };
    }
    results.push(result);
    await onResult?.(result);
  }
  return results;
}
