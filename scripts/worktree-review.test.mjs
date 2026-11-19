import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, mkdir, writeFile, rm, access, realpath, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { worktreeCatalog, removeReviewedWorktrees } from "./worktree-review.mjs";

test("worktree cleanup preserves branches and rejects dirty, ignored, active, locked, and unmerged work", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "mac-clean-worktree-test-")));
  const repo = join(root, "project");
  const git = (args, cwd = repo) => execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  const activity = { ok: true, paths: [] };
  try {
    await mkdir(repo);
    git(["init", "-b", "main"]);
    git(["config", "user.name", "Mac Clean Test"]);
    git(["config", "user.email", "mac-clean@example.invalid"]);
    await writeFile(join(repo, ".gitignore"), ".env\nnode_modules\ntsconfig.tsbuildinfo\n.DS_Store\n");
    await writeFile(join(repo, "source.txt"), "committed\n");
    git(["add", "."]);
    git(["commit", "-m", "fixture"]);
    await mkdir(join(repo, "node_modules"));
    await writeFile(join(repo, "node_modules", "shared.txt"), "keep shared dependency");
    const paths = {};
    for (const name of ["clean", "dirty", "ignored", "active", "locked", "unmerged", "race"]) {
      paths[name] = join(repo, ".worktrees", name);
      git(["worktree", "add", "-b", `test-${name}`, paths[name], "main"]);
    }
    await writeFile(join(paths.dirty, "new.txt"), "local work");
    await symlink(join(repo, "node_modules"), join(paths.clean, "node_modules"));
    await writeFile(join(paths.clean, "tsconfig.tsbuildinfo"), "generated build cache");
    await writeFile(join(paths.ignored, ".env"), "local setting");
    git(["worktree", "lock", paths.locked]);
    await writeFile(join(paths.unmerged, "feature.txt"), "feature");
    git(["add", "."], paths.unmerged);
    git(["commit", "-m", "not merged"], paths.unmerged);
    const observed = { ok: true, paths: [join(paths.active, "source.txt")] };
    const catalog = await worktreeCatalog({ root, activity: observed });
    assert.equal(catalog.items.length, 7);
    const byName = new Map(catalog.items.map(item => [item.name, item]));
    assert.equal(byName.get("clean").eligible, true);
    for (const name of ["dirty", "ignored", "active", "locked", "unmerged"]) assert.equal(byName.get(name).eligible, false, name);
    assert.match(byName.get("ignored").reasons.join(), /Ignored/);
    // Revalidation catches files added after the review, including Git-ignored data.
    await writeFile(join(paths.race, ".env"), "created after scan");
    const removed = await removeReviewedWorktrees([paths.clean, paths.race, paths.ignored, repo, join(root, "unknown")], { root, activity });
    assert.equal(removed[0].removed, true);
    assert.ok(removed.slice(1).every(item => !item.removed));
    await assert.rejects(access(paths.clean));
    assert.ok(git(["show-ref", "--verify", "refs/heads/test-clean"]));
    await access(join(repo, "node_modules", "shared.txt"));
    assert.ok(git(["worktree", "list"]).includes(paths.ignored));
    const uncertain = await worktreeCatalog({ root, activity: { ok: false, paths: [] } });
    assert.ok(uncertain.items.every(item => !item.eligible));
  } finally {
    // Delete only this test's uniquely allocated temporary fixture.
    await rm(root, { recursive: true, force: true });
  }
});
