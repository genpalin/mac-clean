#!/usr/bin/env node

import { access, cp, mkdir } from "node:fs/promises";
import { constants } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const source = join(root, "dist", "Mac Clean.app");
const target = join(homedir(), "Applications", "Mac Clean.app");
const replace = process.argv.includes("--replace");

async function exists(path) {
  try {
    await access(path, constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

if (!(await exists(source))) {
  console.error("[mac-clean-app] build the app first with: npm run mac:app:build");
  process.exit(2);
}
if ((await exists(target)) && !replace) {
  console.error(`[mac-clean-app] target already exists: ${target}`);
  console.error("[mac-clean-app] use --replace only when you explicitly want to replace it");
  process.exit(2);
}

await mkdir(dirname(target), { recursive: true });
await cp(source, target, { recursive: true, force: true });
console.log(`[mac-clean-app] installed ${target}`);
console.log("Open it from Finder, or run: open ~/Applications/'Mac Clean.app'");
