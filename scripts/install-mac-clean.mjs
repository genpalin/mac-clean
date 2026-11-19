#!/usr/bin/env node

import { chmod, mkdir, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const homeDir = homedir();
const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const targetDir = join(homeDir, ".local", "bin");
const targetPath = join(targetDir, "mac-clean");
const sourcePath = join(repoRoot, "scripts", "mac-clean.mjs");
const launcher = `#!/bin/sh\nexec /usr/bin/env node ${JSON.stringify(sourcePath)} "$@"\n`;

await mkdir(targetDir, { recursive: true });
await writeFile(targetPath, launcher, { mode: 0o755 });
await chmod(targetPath, 0o755);
console.log(`Installed ${targetPath}`);
console.log(`Source: ${sourcePath}`);
console.log("If mac-clean is not found, add ~/.local/bin to PATH and open a new shell:");
console.log('  export PATH="$HOME/.local/bin:$PATH"');
