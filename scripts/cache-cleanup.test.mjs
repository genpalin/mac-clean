import test from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { cleanupCacheTargets, discoverProtectedCacheDirectories, excludeDeniedCache, readCacheExclusions } from "./cache-cleanup.mjs";

test("protected cache discovery finds only known cache directories and does not follow links", async () => {
  const root = await mkdtemp(join(tmpdir(), "mac-clean-cache-discovery-"));
  try {
    await mkdir(join(root, "Microsoft", "MSTeams", "Cache"), { recursive: true });
    await mkdir(join(root, "Microsoft", "MSTeams", "GPUCache"));
    await mkdir(join(root, "Microsoft", "MSTeams", "IndexedDB"));
    await symlink(join(root, "Microsoft"), join(root, "linked-app"));
    assert.deepEqual(await discoverProtectedCacheDirectories(root, { groupNamesOnly: true }), ["Microsoft"]);
    const caches = await discoverProtectedCacheDirectories(root);
    assert.deepEqual(caches.sort(), [join(root, "Microsoft", "MSTeams", "Cache"), join(root, "Microsoft", "MSTeams", "GPUCache")]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("a busy cache is skipped while another selected cache still clears", async () => {
  const targets = [{ id: "codex-cache" }, { id: "vscode-vsix" }];
  const removed = [];
  const results = await cleanupCacheTargets(targets, {
    blockersFor: async target => target.id === "codex-cache" ? ["Codex"] : [],
    removeTarget: async target => removed.push(target.id)
  });
  assert.deepEqual(removed, ["vscode-vsix"]);
  assert.equal(results[0].removed, false);
  assert.match(results[0].reason, /Close: Codex/);
  assert.equal(results[1].removed, true);
});

test("VS Code permission failures persist an exclusion without stopping the rest of a batch", async () => {
  const root = await mkdtemp(join(tmpdir(), "mac-clean-exclusions-"));
  const path = join(root, "settings", "cache-exclusions.json");
  const denied = Object.assign(new Error("operation not permitted"), { code: "EPERM" });
  const targets = [{ id: "vscode-vsix", path: "/test/Code/CachedExtensionVSIXs" }, { id: "prisma" }];
  try {
    assert.deepEqual(await readCacheExclusions(path), []);
    const removed = [];
    const results = await cleanupCacheTargets(targets, {
      blockersFor: async () => [],
      removeTarget: async target => {
        if (target.id === "vscode-vsix") throw denied;
        removed.push(target.id);
      },
      onResult: async result => { await excludeDeniedCache(result.target, result.error, path); }
    });
    assert.deepEqual(removed, ["prisma"]);
    assert.equal(results[0].removed, false);
    assert.equal(results[1].removed, true);
    const exclusions = await readCacheExclusions(path);
    assert.equal(exclusions.length, 1);
    assert.equal(exclusions[0].id, "vscode-vsix");
    assert.equal(exclusions[0].code, "EPERM");
    await excludeDeniedCache(targets[0], denied, path);
    assert.equal((await readCacheExclusions(path)).length, 1);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("busy, transient and unrelated cache failures do not become permanent exclusions", async () => {
  const root = await mkdtemp(join(tmpdir(), "mac-clean-exclusion-policy-"));
  const path = join(root, "cache-exclusions.json");
  try {
    for (const code of ["EBUSY", "ENOENT"]) {
      const error = Object.assign(new Error(code), { code });
      assert.equal(await excludeDeniedCache({ id: "vscode-updater" }, error, path), false);
    }
    const error = Object.assign(new Error("denied"), { code: "EACCES" });
    assert.equal(await excludeDeniedCache({ id: "codex-cache" }, error, path), false);
    assert.deepEqual(await readCacheExclusions(path), []);
    assert.equal(await excludeDeniedCache({ id: "vscode-updater", path: "/test/updater" }, error, path), true);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
