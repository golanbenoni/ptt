#!/usr/bin/env node
import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { readReleaseIdentity } from "./verify-independent-security-review.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const verifier = path.join(root, "scripts/verify-independent-security-review.mjs");
const work = await mkdtemp(path.join(tmpdir(), "ptt-independent-review-"));

try {
  const release = await readReleaseIdentity();
  const commitSha = "1234567890abcdef1234567890abcdef12345678";
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const publicKeyPath = path.join(work, "reviewer-public.pem");
  await writeFile(publicKeyPath, publicKey.export({ type: "spki", format: "pem" }));

  const baseline = {
    schemaVersion: 1,
    product: "PTT Talk",
    version: release.version,
    build: release.build,
    commitSha,
    decision: "approved",
    reviewer: { organization: "Independent Security Lab", lead: "Review Lead", independent: true },
    reviewStartedAt: "2026-08-01T00:00:00Z",
    reviewCompletedAt: "2026-08-07T00:00:00Z",
    artifacts: [
      { platform: "ios", sha256: "1".repeat(64) },
      { platform: "android", sha256: "2".repeat(64) },
    ],
    reports: [
      { kind: "executive", sha256: "3".repeat(64) },
      { kind: "technical", sha256: "4".repeat(64) },
    ],
    scope: {
      cryptography: true,
      applicationPenetration: true,
      callKeyDistribution: true,
      liveKitE2EE: true,
      tokenAndWebhookAuthorization: true,
      mobileLifecycle: true,
      deploymentExposure: true,
    },
    openFindings: { critical: 0, high: 0, cryptoBlocking: 0 },
    retestComplete: true,
    untestedAreas: [],
    residualRisks: [],
  };

  async function run(attestation, signedAttestation = attestation) {
    const attestationPath = path.join(work, "attestation.json");
    const signaturePath = path.join(work, "attestation.sig");
    const bytes = Buffer.from(`${JSON.stringify(attestation)}\n`);
    const signedBytes = Buffer.from(`${JSON.stringify(signedAttestation)}\n`);
    await writeFile(attestationPath, bytes);
    await writeFile(signaturePath, sign("sha256", signedBytes, privateKey));
    return spawnSync(process.execPath, [verifier], {
      cwd: root,
      encoding: "utf8",
      env: {
        ...process.env,
        PTT_INDEPENDENT_REVIEW_ATTESTATION_PATH: attestationPath,
        PTT_INDEPENDENT_REVIEW_SIGNATURE_PATH: signaturePath,
        PTT_INDEPENDENT_REVIEW_PUBLIC_KEY_PATH: publicKeyPath,
        PTT_REVIEW_CANDIDATE_SHA: commitSha,
      },
    });
  }

  const accepted = await run(baseline);
  assert.equal(accepted.status, 0, accepted.stderr);
  assert.match(accepted.stdout, /Independent security review accepted/u);

  const openHigh = structuredClone(baseline);
  openHigh.openFindings.high = 1;
  const rejectedFinding = await run(openHigh);
  assert.equal(rejectedFinding.status, 1);
  assert.match(rejectedFinding.stderr, /openFindings\.high must be 0/u);

  const wrongCommit = structuredClone(baseline);
  wrongCommit.commitSha = "abcdef1234567890abcdef1234567890abcdef12";
  const rejectedCommit = await run(wrongCommit);
  assert.equal(rejectedCommit.status, 1);
  assert.match(rejectedCommit.stderr, /commitSha does not match/u);

  const tampered = structuredClone(baseline);
  tampered.decision = "rejected";
  const rejectedSignature = await run(tampered, baseline);
  assert.equal(rejectedSignature.status, 1);
  assert.match(rejectedSignature.stderr, /signature verification failed/u);

  const missingScope = structuredClone(baseline);
  delete missingScope.scope.liveKitE2EE;
  const rejectedScope = await run(missingScope);
  assert.equal(rejectedScope.status, 1);
  assert.match(rejectedScope.stderr, /scope\.liveKitE2EE must be true/u);

  console.log("Independent security-review attestation fixtures: ok");
} finally {
  await rm(work, { recursive: true, force: true });
}
