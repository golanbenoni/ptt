#!/usr/bin/env node
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const root = path.resolve(import.meta.dirname, "..");

async function filesBelow(relative) {
  const base = path.join(root, relative);
  const entries = await readdir(base, { withFileTypes: true });
  const result = [];
  for (const entry of entries) {
    const child = path.join(relative, entry.name);
    if (entry.isDirectory()) result.push(...(await filesBelow(child)));
    else result.push(child);
  }
  return result;
}

function routeCalls(source) {
  const routes = [];
  let offset = 0;
  while ((offset = source.indexOf(".route(", offset)) !== -1) {
    let cursor = offset + ".route(".length;
    let depth = 1;
    let quote = null;
    let escaped = false;
    for (; cursor < source.length && depth > 0; cursor += 1) {
      const character = source[cursor];
      if (quote) {
        if (escaped) escaped = false;
        else if (character === "\\") escaped = true;
        else if (character === quote) quote = null;
        continue;
      }
      if (character === '"' || character === "'") quote = character;
      else if (character === "(") depth += 1;
      else if (character === ")") depth -= 1;
    }
    const call = source.slice(offset, cursor);
    const route = call.match(/\.route\(\s*"([^"]+)"/u)?.[1];
    if (route?.startsWith("/v1/")) {
      const methods = [...call.matchAll(/\b(get|post|put|delete)\s*\(/gu)].map((match) => match[1].toUpperCase());
      routes.push({ path: route, methods: [...new Set(methods)] });
    }
    offset = cursor;
  }
  return routes;
}

function routePattern(route) {
  const escaped = route.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // Implementations use framework placeholders, regular-expression captures,
  // template variables, and concrete UUIDs for the same path segment.
  return new RegExp(escaped.replace(/\\\{[^}]+\\\}/g, "[\\s\\S]{1,120}?"), "u");
}

const rustSource = await readFile(path.join(root, "server/control/src/main.rs"), "utf8");
const routes = routeCalls(rustSource);
const uniqueRoutes = new Map(routes.map((route) => [route.path, route]));
if (uniqueRoutes.size < 60) {
  console.error(`Route parser found only ${uniqueRoutes.size} v1 routes; expected at least 60.`);
  process.exit(1);
}

const testModuleOffset = rustSource.indexOf("#[cfg(test)]");
const testFiles = [
  ...(await filesBelow("cloudflare/test")),
  ...(await filesBelow("tests/e2e")),
  "scripts/test-control-integration.sh",
  "scripts/test-k3s-clean-install.sh",
];
let testCorpus = testModuleOffset >= 0 ? rustSource.slice(testModuleOffset) : "";
for (const relative of testFiles) {
  testCorpus += `\n${await readFile(path.join(root, relative), "utf8")}`;
}

const cloudflareSource = (await readFile(path.join(root, "cloudflare/src/index.ts"), "utf8"))
  .replaceAll("\\/", "/");
const uncovered = [];
const parityMissing = [];
for (const route of uniqueRoutes.values()) {
  const pattern = routePattern(route.path);
  if (!pattern.test(testCorpus)) uncovered.push(`${route.methods.join("|")} ${route.path}`);
  if (!pattern.test(cloudflareSource)) parityMissing.push(route.path);
}

if (uncovered.length || parityMissing.length) {
  if (uncovered.length) console.error(`Routes absent from the executable test corpus:\n${uncovered.join("\n")}`);
  if (parityMissing.length) console.error(`Routes absent from the Cloudflare implementation:\n${parityMissing.join("\n")}`);
  process.exit(1);
}

console.log(`${uniqueRoutes.size} v1 route paths are present in tests and both service implementations.`);
