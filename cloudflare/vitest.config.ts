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
      // The worker performs a real readiness probe before advertising calls.
      // Keep the test deterministic without adding a production bypass flag.
      outboundService: async (request) => new Response(
        new URL(request.url).hostname === "calls.ptt.test" ? "ok" : "not found",
        { status: new URL(request.url).hostname === "calls.ptt.test" ? 200 : 404 },
      ),
      bindings: {
        BOOTSTRAP_TOKEN: "local-test-bootstrap",
        LIVEKIT_URL: "wss://calls.ptt.test",
        LIVEKIT_API_KEY: "test-api-key",
        LIVEKIT_API_SECRET: "test-only-secret-with-at-least-32-bytes",
        TEST_MIGRATIONS: migrations,
      },
    },
  }))],
  test: { setupFiles: ["./test/apply-migrations.ts"] },
});
