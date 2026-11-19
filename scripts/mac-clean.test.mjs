import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { commandActions, formatBytes, listDownloadCandidates, packageProcessPattern, parseArgs, protectedReviewLabels } from "./mac-clean.mjs";

test("cache selections require explicit IDs and do not select Docker actions implicitly", () => {
  const args = parseArgs(["--cache-id", "npx", "--cache-id", "codex-cache", "--apply"]);
  assert.deepEqual(args.cacheIds, ["npx", "codex-cache"]);
  assert.equal(args.apply, true);
});

test("Downloads review accepts a non-negative size filter", () => {
  assert.equal(parseArgs(["--downloads-json"]).downloadsMinMb, 100);
  assert.equal(parseArgs(["--downloads-json", "--downloads-min-mb", "512.5"]).downloadsMinMb, 512.5);
  assert.equal(parseArgs(["--downloads-json", "--downloads-min-mb=0"]).downloadsMinMb, 0);
  for (const value of ["-1", "", "NaN", "Infinity", "1e100"]) {
    assert.throws(() => parseArgs([`--downloads-min-mb=${value}`]), /non-negative/);
  }
});

test("Downloads size filter includes only larger files, including installers, and never follows links", async () => {
  const root = await mkdtemp(join(tmpdir(), "mac-clean-downloads-"));
  try {
    await writeFile(join(root, "small.dmg"), Buffer.alloc(9));
    await writeFile(join(root, "boundary.bin"), Buffer.alloc(10));
    await writeFile(join(root, "large.bin"), Buffer.alloc(11));
    await writeFile(join(root, "empty.bin"), "");
    await symlink(join(root, "large.bin"), join(root, "linked.bin"));
    const filtered = await listDownloadCandidates(10, root);
    assert.deepEqual(filtered.items.map(item => item.name), ["large.bin"]);
    const all = await listDownloadCandidates(0, root);
    assert.equal(all.items.length, 4);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("conservative cleanup does not include npm or broad unused-image pruning", () => {
  const actions = commandActions({ noDocker: false, minFree: "20gb", unusedImages: false, imageAge: "720h" });
  assert.equal(actions.length, 2);
  assert.ok(actions.every(action => !action.command.includes("npm")));
  assert.ok(actions.every(action => !action.command.includes("--all")));
});

test("aged unused-image cleanup remains a separate explicit action", () => {
  const actions = commandActions({ noDocker: false, minFree: "20gb", unusedImages: true, imageAge: "720h" });
  assert.ok(actions.some(action => action.command.includes("--filter")));
  assert.ok(actions.every(action => !action.command.includes("npm")));
});

test("the destructive all-unused-images switch is no longer accepted", () => {
  assert.throws(() => parseArgs(["--all-unused-images"]), /Unknown option/);
});

test("sessions and Docker/Aerial managed data remain protected", () => {
  const labels = new Map(protectedReviewLabels);
  assert.match(labels.get("Codex sessions"), /never included/);
  assert.match(labels.get("Docker.raw"), /never delete/);
  assert.match(labels.get("Aerial and macOS-managed data"), /System Settings/);
});

test("byte formatting stays readable", () => {
  assert.equal(formatBytes(0), "0 B");
  assert.match(formatBytes(1024 ** 2), /MiB$/);
});

test("package process checks do not match cache IDs in the cleanup command", () => {
  const pattern = new RegExp(packageProcessPattern("npx"));
  assert.equal(pattern.test("/usr/bin/env node /Users/test/mac-clean.mjs --cache-id npx --apply"), false);
  assert.equal(pattern.test("/opt/homebrew/bin/npx install"), true);
  assert.equal(pattern.test("/opt/homebrew/lib/node_modules/npm/bin/npx-cli.js install"), true);
});
