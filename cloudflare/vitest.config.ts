import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const migrationsDirectory = join(dirname(fileURLToPath(import.meta.url)), "migrations");
const migrations = readdirSync(migrationsDirectory)
  .filter((name) => /^\d+.*\.sql$/u.test(name))
  .sort()
  .map((name) => ({
    name,
    queries: readFileSync(join(migrationsDirectory, name), "utf8")
      .split(";").map((query) => query.trim()).filter(Boolean),
  }));

export default defineConfig({
  plugins: [cloudflareTest(async () => ({
    wrangler: { configPath: "./wrangler.jsonc", environment: "staging" },
    miniflare: {
      bindings: {
        BOOTSTRAP_TOKEN: "local-test-bootstrap",
        TEST_MIGRATIONS: migrations,
      },
    },
  }))],
  test: { setupFiles: ["./test/apply-migrations.ts"] },
});
