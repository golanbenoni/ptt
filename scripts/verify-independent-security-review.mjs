#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { verify as verifySignature } from "node:crypto";
import { fileURLToPath } from "node:url";

const root = path.resolve(import.meta.dirname, "..");
const sha256Pattern = /^[a-f0-9]{64}$/u;
const commitPattern = /^[a-f0-9]{40}$/u;

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function unique(values) {
  return [...new Set(values)];
}

export async function readReleaseIdentity() {
  const [project, android] = await Promise.all([
    readFile(path.join(root, "ios/TalkApp/TalkApp.xcodeproj/project.pbxproj"), "utf8"),
    readFile(path.join(root, "android/talk/build.gradle.kts"), "utf8"),
  ]);
  const iosVersions = unique([...project.matchAll(/MARKETING_VERSION = ([^;]+);/gu)].map((match) => match[1].trim()));
  const iosBuilds = unique([...project.matchAll(/CURRENT_PROJECT_VERSION = ([^;]+);/gu)].map((match) => match[1].trim()));
  const androidVersion = android.match(/versionName = "([^"]+)"/u)?.[1];
  const androidBuild = android.match(/versionCode = ([0-9]+)/u)?.[1];

  if (iosVersions.length !== 1 || iosBuilds.length !== 1 || !androidVersion || !androidBuild) {
    throw new Error("mobile release identity is missing or ambiguous");
  }
  if (iosVersions[0] !== androidVersion || iosBuilds[0] !== androidBuild) {
    throw new Error("iOS and Android release identities are not synchronized");
  }
  return { version: androidVersion, build: Number.parseInt(androidBuild, 10) };
}

export function validateAttestation(attestation, expected) {
  const failures = [];
  const fail = (message) => failures.push(message);

  if (!isRecord(attestation)) return ["attestation must be a JSON object"];
  if (attestation.schemaVersion !== 1) fail("schemaVersion must be 1");
  if (attestation.product !== "PTT Talk") fail("product must be PTT Talk");
  if (attestation.commitSha !== expected.commitSha) fail("commitSha does not match the exact release commit");
  if (!commitPattern.test(attestation.commitSha ?? "")) fail("commitSha must be a lowercase full Git SHA");
  if (attestation.version !== expected.version) fail("version does not match the synchronized mobile version");
  if (attestation.build !== expected.build) fail("build does not match the synchronized mobile build");
  if (attestation.decision !== "approved") fail("decision must be approved");

  if (!isRecord(attestation.reviewer)) {
    fail("reviewer metadata is required");
  } else {
    if (typeof attestation.reviewer.organization !== "string" || attestation.reviewer.organization.trim().length < 2) {
      fail("reviewer.organization is required");
    }
    if (typeof attestation.reviewer.lead !== "string" || attestation.reviewer.lead.trim().length < 2) {
      fail("reviewer.lead is required");
    }
    if (attestation.reviewer.independent !== true) fail("reviewer.independent must be true");
  }

  const startedAt = Date.parse(attestation.reviewStartedAt ?? "");
  const completedAt = Date.parse(attestation.reviewCompletedAt ?? "");
  if (!Number.isFinite(startedAt)) fail("reviewStartedAt must be an ISO-8601 timestamp");
  if (!Number.isFinite(completedAt)) fail("reviewCompletedAt must be an ISO-8601 timestamp");
  if (Number.isFinite(startedAt) && Number.isFinite(completedAt) && completedAt < startedAt) {
    fail("reviewCompletedAt cannot precede reviewStartedAt");
  }

  const artifacts = Array.isArray(attestation.artifacts) ? attestation.artifacts : [];
  if (!Array.isArray(attestation.artifacts)) fail("artifacts must be an array");
  for (const platform of ["ios", "android"]) {
    const matches = artifacts.filter((artifact) => isRecord(artifact) && artifact.platform === platform);
    if (matches.length !== 1) {
      fail(`artifacts must contain exactly one ${platform} entry`);
    } else if (!sha256Pattern.test(matches[0].sha256 ?? "")) {
      fail(`${platform} artifact sha256 must be lowercase hexadecimal`);
    }
  }

  const reports = Array.isArray(attestation.reports) ? attestation.reports : [];
  if (!Array.isArray(attestation.reports)) fail("reports must be an array");
  for (const kind of ["executive", "technical"]) {
    const matches = reports.filter((report) => isRecord(report) && report.kind === kind);
    if (matches.length !== 1) {
      fail(`reports must contain exactly one ${kind} entry`);
    } else if (!sha256Pattern.test(matches[0].sha256 ?? "")) {
      fail(`${kind} report sha256 must be lowercase hexadecimal`);
    }
  }

  const requiredScope = [
    "cryptography",
    "applicationPenetration",
    "callKeyDistribution",
    "liveKitE2EE",
    "tokenAndWebhookAuthorization",
    "mobileLifecycle",
    "deploymentExposure",
  ];
  if (!isRecord(attestation.scope)) {
    fail("scope coverage is required");
  } else {
    for (const area of requiredScope) {
      if (attestation.scope[area] !== true) fail(`scope.${area} must be true`);
    }
  }

  if (!isRecord(attestation.openFindings)) {
    fail("openFindings is required");
  } else {
    for (const field of ["critical", "high", "cryptoBlocking"]) {
      if (attestation.openFindings[field] !== 0) fail(`openFindings.${field} must be 0`);
    }
  }
  if (attestation.retestComplete !== true) fail("retestComplete must be true");
  if (!Array.isArray(attestation.untestedAreas)) fail("untestedAreas must be an explicit array");
  if (!Array.isArray(attestation.residualRisks)) fail("residualRisks must be an explicit array");

  return failures;
}

async function main() {
  const attestationPath = process.env.PTT_INDEPENDENT_REVIEW_ATTESTATION_PATH;
  const signaturePath = process.env.PTT_INDEPENDENT_REVIEW_SIGNATURE_PATH;
  const publicKeyPath = process.env.PTT_INDEPENDENT_REVIEW_PUBLIC_KEY_PATH;
  const commitSha = process.env.PTT_REVIEW_CANDIDATE_SHA ?? process.env.GITHUB_SHA;
  if (!attestationPath || !signaturePath || !publicKeyPath || !commitSha) {
    throw new Error("attestation, signature, public-key paths and candidate SHA are required");
  }
  if (!commitPattern.test(commitSha)) throw new Error("candidate SHA must be a lowercase full Git SHA");

  const [attestationBytes, signature, publicKey, release] = await Promise.all([
    readFile(attestationPath),
    readFile(signaturePath),
    readFile(publicKeyPath),
    readReleaseIdentity(),
  ]);
  if (!verifySignature("sha256", attestationBytes, publicKey, signature)) {
    throw new Error("independent security-review signature verification failed");
  }

  let attestation;
  try {
    attestation = JSON.parse(attestationBytes.toString("utf8"));
  } catch {
    throw new Error("independent security-review attestation is not valid JSON");
  }
  const failures = validateAttestation(attestation, { ...release, commitSha });
  if (failures.length) throw new Error(failures.join("\n"));
  console.log(`Independent security review accepted for ${release.version} (${release.build}) at ${commitSha}.`);
}

if (path.resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(`Independent security review rejected: ${error.message}`);
    process.exit(1);
  });
}
