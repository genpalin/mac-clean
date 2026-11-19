#!/usr/bin/env node

import { chmod, cp, mkdir, mkdtemp, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const root = dirname(dirname(fileURLToPath(import.meta.url)));
const appRoot = join(root, "dist", "Mac Clean.app");
const contents = join(appRoot, "Contents");
const binaryDir = join(contents, "MacOS");
const resourcesDir = join(contents, "Resources");
const sourcePath = join(root, "mac-clean-app", "MacCleanApp.swift");
const mainPath = join(root, "mac-clean-app", "main.swift");
const screenshotMarkupPath = join(root, "mac-clean-app", "ScreenshotMarkup.swift");
const frozenScreenCapturePath = join(root, "mac-clean-app", "FrozenScreenCapture.swift");
const infoPath = join(root, "mac-clean-app", "Info.plist");
const iconAssetPath = join(root, "mac-clean-app", "assets", "MacClean.icns");
const binaryPath = join(binaryDir, "MacClean");

if (process.platform !== "darwin") {
  console.error("[mac-clean-app] native app build requires macOS");
  process.exit(2);
}

await rm(appRoot, { recursive: true, force: true });
await mkdir(binaryDir, { recursive: true });
await mkdir(resourcesDir, { recursive: true });

const moduleCachePath = await mkdtemp(join(tmpdir(), "mac-clean-swift-module-cache-"));
try {
  await execFileAsync("/usr/bin/swiftc", [
    mainPath,
    sourcePath,
    screenshotMarkupPath,
    frozenScreenCapturePath,
    "-O",
    "-module-cache-path",
    moduleCachePath,
    "-framework",
    "AppKit",
    "-framework",
    "Carbon",
    "-framework",
    "Foundation",
    "-framework",
    "ScreenCaptureKit",
    "-o",
    binaryPath
  ], { cwd: root, maxBuffer: 4 * 1024 * 1024 });
} finally {
  await rm(moduleCachePath, { recursive: true, force: true });
}

await cp(infoPath, join(contents, "Info.plist"));
await cp(iconAssetPath, join(resourcesDir, "MacClean.icns"));

await chmod(binaryPath, 0o755);
await execFileAsync("/usr/bin/codesign", [
  "--force",
  "--deep",
  "--sign",
  "-",
  "-r",
  '=designated => identifier "com.local-loop.mac-clean" and info[MacCleanCodeIdentity] = "8F7C4D1A-3E69-4B35-9F12-CC2A77B6401D"',
  appRoot
], { cwd: root, maxBuffer: 4 * 1024 * 1024 });
console.log(`[mac-clean-app] built ${appRoot}`);
