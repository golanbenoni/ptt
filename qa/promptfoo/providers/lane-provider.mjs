import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { lstat, readFile, readdir, readlink } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../../..");

// Prompts select an immutable command from this allowlist. No prompt content is
// ever interpolated into a shell command.
const lanes = Object.freeze({
  protocol_contract: "./scripts/check-proto-contract.sh",
  dependency_pins: "node ./scripts/verify-dependency-pins.mjs",
  api_route_coverage: "node ./scripts/verify-api-route-coverage.mjs",
  documentation: "node ./scripts/verify-documentation.mjs",
  store_readiness: "node ./scripts/verify-store-readiness.mjs",
  acoustic_analyzer: "python3 ./scripts/analyze-acoustic-tone.py --self-test",
  physical_device_identity: "./scripts/assert-distinct-device-identities.sh --self-test",
  latency_analyzer:
    "./scripts/assert-latency-samples.sh promptfoo-self-test '90,92,95,93,94,91,90,92,93,94,91,90,92,93,94,91,90,92,93,250' 20 95",
  firebase_configuration: "./scripts/test-firebase-client-config.sh",
  d1_backup_restore:
    "./scripts/verify-d1-backup-restore.sh tests/e2e/d1-backup-fixture.sql 0001_fixture.sql && ! ./scripts/verify-d1-backup-restore.sh tests/e2e/d1-backup-missing-table.sql 0001_fixture.sql",
  admin_web: "npm run typecheck --prefix admin-web && npm run build --prefix admin-web",
  admin_browser: "node ./scripts/test-admin-browser.mjs",
  cloudflare: "npm run check --prefix cloudflare",
  native_rust:
    "cargo fmt --manifest-path native/Cargo.toml --all -- --check && cargo test --manifest-path native/Cargo.toml --locked",
  server_rust:
    "cargo fmt --manifest-path server/Cargo.toml --all -- --check && cargo test --manifest-path server/Cargo.toml --locked",
  rust_static_analysis:
    "cargo clippy --manifest-path native/Cargo.toml --workspace --all-targets --locked -- -D warnings && cargo clippy --manifest-path server/Cargo.toml --workspace --all-targets --locked -- -D warnings",
  swift_wire: "cd ios/PttWire && swift test",
  swift_product:
    "libsignal_root=\"${LIBSIGNAL_ROOT:-$HOME/src/libsignal}\"; test -f \"$libsignal_root/swift/Package.swift\"; test -f \"$libsignal_root/target/debug/libsignal_ffi.a\"; export LIBSIGNAL_SWIFT=\"$libsignal_root/swift\" LIBSIGNAL_FFI=\"$libsignal_root/target/debug\"; cd ios/PttTalk && swift test",
  android_unit:
    "source ./scripts/java21-env.sh && ./gradlew :crypto:test :floor:test :hardware:test :media:test :loopback:test :net:test :talkandroid:testDebugUnitTest :crypto-persistence:lintDebug :talkandroid:lintDebug --no-daemon",
  control_integration: "./scripts/test-control-integration.sh",
  security_audit: "./scripts/test-security-audit-timeout.sh && ./scripts/security-audit.sh",
  helm_contract:
    "helm lint deploy/helm/ptt --set secrets.databasePassword=test-only --set secrets.redisPassword=test-only --set secrets.objectStorePassword=test-only --set secrets.bootstrapToken=test-only-32-byte-bootstrap-token --set secrets.relaySharedSecret=test-only-32-byte-relay-shared-key --set secrets.metricsToken=test-only-32-byte-metrics-access-key && ./scripts/test-helm-apns-separation.sh",
  k3s_clean_install: "./scripts/test-k3s-clean-install.sh",
  android_accessibility: "source ./scripts/java21-env.sh && ./scripts/test-android-accessibility.sh",
  ios_accessibility:
    "libsignal_root=\"${LIBSIGNAL_ROOT:-$PWD/libsignal}\"; if [[ ! -f \"$libsignal_root/swift/Package.swift\" && -f \"$HOME/src/libsignal/swift/Package.swift\" ]]; then libsignal_root=\"$HOME/src/libsignal\"; fi; export LIBSIGNAL_SWIFT=\"$libsignal_root/swift\" LIBSIGNAL_FFI=\"$libsignal_root/target/aarch64-apple-ios-sim/debug\"; ./scripts/test-ios-accessibility.sh",
  public_site_browser: "node ./scripts/test-public-website.mjs",
  physical_four_device: "./scripts/record-physical-acoustic.sh ./scripts/test-four-device-parity.sh",
  physical_ios: "./scripts/record-physical-acoustic.sh ./scripts/test-ios-two-physical-voice.sh",
  physical_restoration: "./scripts/test-physical-reboot-restoration.sh",
  android_soak:
    "PTT_ANDROID_SOAK_ONLY=1 PTT_ANDROID_SOAK_DURATION_SECONDS=28800 PTT_ANDROID_SOAK_INTERVAL_SECONDS=300 ./scripts/test-android-two-physical-voice.sh",
  release_readiness: "node ./scripts/verify-store-readiness.mjs && ./scripts/verify-production-push-readiness.sh",
  release_workflow_proof: "./scripts/verify-release-gates.sh",
  clean_checkout: "test -z \"$(git status --porcelain --untracked-files=all)\"",
});

function redact(value) {
  return String(value)
    .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[redacted-email]")
    .replace(/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/gi, "Bearer [redacted]")
    .replace(/\b(?:token|secret|password|private[_ -]?key|api[_ -]?key)\s*[:=]\s*[^\s,;]+/gi, "$1=[redacted]")
    .replace(/\b[A-Fa-f0-9]{64,}\b/g, "[redacted-hex]");
}

function summarize(stdout, stderr) {
  const combined = redact(`${stdout || ""}\n${stderr || ""}`)
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(-20)
    .join("\n");
  return combined.slice(0, 4000);
}

async function commitId() {
  const { stdout } = await execFileAsync("git", ["rev-parse", "HEAD"], { cwd: root });
  return stdout.trim();
}

async function workspaceEvidence() {
  const status = await execFileAsync("git", ["status", "--porcelain=v1", "-z", "--untracked-files=all"], { cwd: root });
  const records = status.stdout.split("\u0000").filter(Boolean);
  const digest = createHash("sha256");
  const diff = await execFileAsync("git", ["diff", "--binary", "HEAD"], { cwd: root, maxBuffer: 20 * 1024 * 1024 });
  digest.update(diff.stdout);
  async function hashUntracked(relative) {
    const absolute = path.join(root, relative);
    const info = await lstat(absolute);
    digest.update(relative);
    if (info.isSymbolicLink()) {
      digest.update("symlink\0");
      digest.update(await readlink(absolute));
      return;
    }
    if (!info.isDirectory()) {
      digest.update("file\0");
      digest.update(await readFile(absolute));
      return;
    }

    digest.update("directory\0");
    try {
      const nestedHead = await execFileAsync("git", ["-C", absolute, "rev-parse", "HEAD"]);
      const nestedStatus = await execFileAsync("git", ["-C", absolute, "status", "--porcelain=v1", "-z", "--untracked-files=all"]);
      digest.update(nestedHead.stdout);
      digest.update(nestedStatus.stdout);
      return;
    } catch {
      // Ordinary untracked directory: hash each entry in stable order.
    }
    for (const entry of (await readdir(absolute)).sort()) {
      if (entry === ".git") continue;
      await hashUntracked(path.join(relative, entry));
    }
  }

  for (const record of records.filter((value) => value.startsWith("?? ")).sort()) {
    const relative = record.slice(3);
    await hashUntracked(relative);
  }
  return {
    workspaceState: records.length === 0 ? "clean" : "dirty",
    workspaceHash: digest.digest("hex"),
  };
}

export default class PttLaneProvider {
  id() {
    return "ptt-native-gates";
  }

  async callApi(prompt) {
    const lane = String(prompt).trim();
    const command = lanes[lane];
    if (!command) {
      return { error: `Unknown PTT test lane: ${redact(lane)}` };
    }

    const started = Date.now();
    const commit = await commitId();
    const workspace = await workspaceEvidence();
    let status = "passed";
    let exitCode = 0;
    let stdout = "";
    let stderr = "";

    try {
      const result = await execFileAsync("/bin/zsh", ["-lc", command], {
        cwd: root,
        env: {
          ...process.env,
          PROMPTFOO_DISABLE_TELEMETRY: "1",
          PROMPTFOO_DISABLE_REDTEAM_REMOTE_GENERATION: "true",
        },
        maxBuffer: 10 * 1024 * 1024,
        timeout: Number(process.env.PTT_PROMPTFOO_LANE_TIMEOUT_MS || 45 * 60 * 1000),
      });
      stdout = result.stdout;
      stderr = result.stderr;
    } catch (error) {
      status = "failed";
      exitCode = Number.isInteger(error?.code) ? error.code : 1;
      stdout = error?.stdout || "";
      stderr = error?.stderr || error?.message || "Test lane failed";
    }

    const summary = summarize(stdout, stderr);
    const evidenceHash = createHash("sha256")
      .update(`${lane}\u0000${commit}\u0000${workspace.workspaceState}\u0000${workspace.workspaceHash}\u0000${status}\u0000${summary}`)
      .digest("hex");
    const evidence = {
      schemaVersion: 1,
      lane,
      status,
      exitCode,
      durationMs: Date.now() - started,
      commit,
      ...workspace,
      evidenceHash,
      summary,
    };

    return {
      output: JSON.stringify(evidence),
      metadata: {
        lane,
        status,
        durationMs: evidence.durationMs,
        commit,
        ...workspace,
        evidenceHash,
      },
    };
  }
}
