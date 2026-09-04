#!/usr/bin/env node
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const root = path.resolve(import.meta.dirname, "..");
const failures = [];

for (const name of await readdir(path.join(root, ".github/workflows"))) {
  if (!name.endsWith(".yml") && !name.endsWith(".yaml")) continue;
  const relative = `.github/workflows/${name}`;
  const lines = (await readFile(path.join(root, relative), "utf8")).split(/\r?\n/);
  lines.forEach((line, index) => {
    const match = line.match(/\buses:\s*([^\s#]+)@([^\s#]+)/);
    if (!match || match[1].startsWith("./") || match[1].startsWith("docker://")) return;
    if (!/^[a-f0-9]{40}$/.test(match[2])) {
      failures.push(`${relative}:${index + 1}: action is not pinned to a full commit SHA`);
    }
  });
}

for (const relative of [
  "admin-web/package.json",
  "cloudflare/package.json",
  "qa/promptfoo/package.json",
]) {
  const manifest = JSON.parse(await readFile(path.join(root, relative), "utf8"));
  for (const section of ["dependencies", "devDependencies", "optionalDependencies"]) {
    for (const [name, version] of Object.entries(manifest[section] || {})) {
      if (version === "latest" || version === "*" || /^(?:workspace:)?[~^><=]/.test(version)) {
        failures.push(`${relative}: ${section}.${name} is not an exact version (${version})`);
      }
    }
  }
}

if (failures.length) {
  console.error(failures.join("\n"));
  process.exit(1);
}
console.log("GitHub Actions and npm manifests use immutable pins.");
