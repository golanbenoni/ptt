#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

async function repositoryFile(relativePath) {
  return readFile(path.join(root, relativePath), "utf8");
}

async function workflow(name) {
  return readFile(path.join(root, ".github", "workflows", name), "utf8");
}

function requireText(source, pattern, message) {
  if (!pattern.test(source)) throw new Error(message);
}

function rejectText(source, pattern, message) {
  if (pattern.test(source)) throw new Error(message);
}

for (const name of ["android-test-release.yml", "ios-test-release.yml"]) {
  const source = await workflow(name);
  requireText(
    source,
    /run:\s*\.\/scripts\/verify-release-gates\.sh/,
    `${name} must run the exact-commit release aggregator before upload`,
  );
  rejectText(
    source,
    /PTT_(?:SKIP|DEFER)_[A-Z0-9_]*GATE/,
    `${name} must not defer any release gate before store upload`,
  );
  requireText(
    source,
    /PTT_INTERNAL_TEST_DISTRIBUTION:\s*["']?1["']?/,
    `${name} must identify its upload as internal-test distribution`,
  );
}

const soak = await workflow("android-soak.yml");
requireText(
  soak,
  /runs-on:\s*\[self-hosted,\s*macOS,\s*ARM64,\s*ptt-physical\]/,
  "android-soak.yml must target the runner that owns the authorized USB devices",
);
rejectText(
  soak,
  /runs-on:\s*\[[^\]]*ptt-build[^\]]*\]/,
  "android-soak.yml must not schedule physical USB testing on a generic build runner",
);
requireText(
  soak,
  /PTT_SKIP_PHYSICAL_RELEASE_GATE:\s*["']?1["']?/,
  "android-soak.yml must allow the independent four-device gate to run in parallel",
);
requireText(
  soak,
  /PTT_SKIP_ANDROID_SOAK_GATE:\s*["']?1["']?/,
  "android-soak.yml must defer only its own result while producing soak evidence",
);

const physical = await workflow("physical-release.yml");
requireText(
  physical,
  /PTT_SKIP_PHYSICAL_RELEASE_GATE:\s*["']?1["']?/,
  "physical-release.yml must defer its own result while producing physical evidence",
);
requireText(
  physical,
  /PTT_SKIP_ANDROID_SOAK_GATE:\s*["']?1["']?/,
  "physical-release.yml must allow the independent soak gate to run in parallel",
);

for (const [name, source] of [
  ["android-soak.yml", soak],
  ["physical-release.yml", physical],
  ["ios-physical-release.yml", await workflow("ios-physical-release.yml")],
]) {
  requireText(
    source,
    /PTT_SKIP_INDEPENDENT_SECURITY_REVIEW_GATE:\s*["']?1["']?/,
    `${name} must allow the independent signed review to run in parallel`,
  );
  requireText(
    source,
    /PTT_SKIP_ENCRYPTED_CALLS_RELEASE_GATE:\s*["']?1["']?/,
    `${name} must allow the independent public-media gate to run in parallel`,
  );
}

const androidCalls = await workflow("android-call-physical.yml");
requireText(
  androidCalls,
  /test-android-two-device-call-unauthorized-observer\.sh/,
  "android-call-physical.yml must prove an unauthorized SFU subscriber cannot decrypt call media",
);

const iosRelease = await repositoryFile("scripts/ios-release.sh");
rejectText(
  iosRelease,
  /["']PROVISIONING_PROFILE_SPECIFIER=\$PROFILE_NAME["']|["']CODE_SIGN_STYLE=Manual["']/,
  "ios-release.sh must not apply app-only signing settings to Swift package targets",
);
requireText(
  iosRelease,
  /["']PTT_IOS_PROFILE=\$PROFILE_NAME["']/,
  "ios-release.sh must pass the selected profile through the app-target build setting",
);

const iosProject = await repositoryFile(
  "ios/TalkApp/TalkApp.xcodeproj/project.pbxproj",
);
requireText(
  iosProject,
  /PROVISIONING_PROFILE_SPECIFIER = "\$\(PTT_IOS_PROFILE\)";/,
  "the iOS app target must own its provisioning-profile setting",
);
requireText(
  iosProject,
  /CODE_SIGN_IDENTITY = "\$\(PTT_IOS_SIGNING_IDENTITY\)";/,
  "the iOS app target must own its signing-identity setting",
);

const iosTestRelease = await workflow("ios-test-release.yml");
requireText(
  iosTestRelease,
  /app-store-connect-profile\.mjs ensure-testflight/,
  "ios-test-release.yml must verify processing and internal-group assignment after upload",
);

console.log("Internal store workflows require every automated exact-commit gate; physical, soak, and signed-review evidence remain mandatory for production promotion.");
