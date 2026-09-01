import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const update = process.argv.includes('--update');
const privacyUrl = 'https://ptttalk.app/privacy';
const legacyHashes = new Set([
  '0b93cb810c01ada40955f99925d23ba9940ddbcf2a6e6f73245e36377115b798',
  '0c83b62903835539b049e448a1fcd6361e8a61e898c8df9a693ecc77fa0cda4a',
]);

const read = (relative) => fs.readFileSync(path.join(root, relative));
const text = (relative) => read(relative).toString('utf8');
const fail = (message) => { throw new Error(`Store readiness failed: ${message}`); };
const one = (source, expression, label) => {
  const values = [...source.matchAll(expression)].map((match) => match[1]);
  const unique = [...new Set(values)];
  if (unique.length !== 1) fail(`${label} must resolve to one value; found ${unique.join(', ') || 'none'}`);
  return unique[0];
};

const androidBuildFile = text('android/talk/build.gradle.kts');
const iosProjectFile = text('ios/TalkApp/TalkApp.xcodeproj/project.pbxproj');
const androidVersion = one(androidBuildFile, /^\s*versionName\s*=\s*"([^"]+)"/gm, 'Android version');
const androidBuild = one(androidBuildFile, /^\s*versionCode\s*=\s*(\d+)/gm, 'Android build');
const iosVersion = one(iosProjectFile, /^\s*MARKETING_VERSION\s*=\s*([^;]+);/gm, 'iOS version');
const iosBuild = one(iosProjectFile, /^\s*CURRENT_PROJECT_VERSION\s*=\s*([^;]+);/gm, 'iOS build');
if (androidVersion !== iosVersion || androidBuild !== iosBuild) {
  fail(`mobile versions differ: Android ${androidVersion} (${androidBuild}), iOS ${iosVersion} (${iosBuild})`);
}

const documents = [
  'store/metadata/en-US.md',
  'store/metadata/PRIVACY_DISCLOSURES.md',
  'store/metadata/TEST_GROUPS.md',
  'PRIVACY.md',
  'website/index.html',
];
for (const document of documents) {
  const contents = text(document);
  if (contents.includes('golanbenoni.github.io/ptt-talk-privacy')) fail(`${document} contains the retired privacy URL`);
}
for (const document of ['store/metadata/en-US.md', 'store/metadata/PRIVACY_DISCLOSURES.md']) {
  if (!text(document).includes(privacyUrl)) fail(`${document} does not contain the public privacy URL`);
}
for (const document of ['store/metadata/PRIVACY_DISCLOSURES.md', 'store/metadata/TEST_GROUPS.md']) {
  if (!text(document).includes(`${androidVersion} (${androidBuild})`)) fail(`${document} is not labeled ${androidVersion} (${androidBuild})`);
}
const privacy = text('PRIVACY.md');
if (!privacy.includes('Effective date: August 31, 2026')) fail('repository privacy policy does not match the public effective date');
const normalizedPrivacy = privacy.replace(/\s+/g, ' ');
for (const phrase of ['text, files, voice notes, and video', 'encrypted mailbox and chat envelopes']) {
  if (!normalizedPrivacy.includes(phrase)) fail(`repository privacy policy is missing: ${phrase}`);
}

const androidActivity = text('android/talk/src/main/kotlin/app/ptt/talk/TalkActivity.kt');
const androidFixture = text('android/talk/src/debug/kotlin/app/ptt/talk/AccessibilityFixtureActivity.kt');
if (!androidActivity.includes('BuildConfig.DEBUG && intent.getBooleanExtra(EXTRA_DEBUG_ALLOW_SCREENSHOTS, false)')) {
  fail('Android screenshots are not limited to the explicit debug fixture');
}
if (!androidActivity.includes('window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)')) {
  fail('Android release screenshot protection is missing');
}
if (!androidFixture.includes('putExtra(EXTRA_DEBUG_ALLOW_SCREENSHOTS, true)')) {
  fail('Android screenshot fixture does not opt in explicitly');
}
if (!text('ios/TalkApp/TalkApp/TalkView.swift').includes('--ptt-screenshot-fixture')) {
  fail('iOS screenshot fixture is missing');
}

const screenshotSpecs = {
  'store/screenshots/ios/iphone-release.png': [1320, 2868, 'iPhone Talk'],
  'store/screenshots/ios/iphone-chat.png': [1320, 2868, 'iPhone Chat'],
  'store/screenshots/ios/iphone-settings.png': [1320, 2868, 'iPhone Settings'],
  'store/screenshots/ios/ipad-release.png': [2064, 2752, 'iPad Talk'],
  'store/screenshots/ios/ipad-chat.png': [2064, 2752, 'iPad Chat'],
  'store/screenshots/ios/ipad-settings.png': [2064, 2752, 'iPad Settings'],
  'store/screenshots/android/phone-release.png': [1080, 1920, 'Android Talk'],
  'store/screenshots/android/phone-chat.png': [1080, 1920, 'Android Chat'],
  'store/screenshots/android/phone-onboarding.png': [1080, 1920, 'Android onboarding'],
  'store/screenshots/android/phone-security.png': [1080, 1920, 'Android security and devices'],
};

const screenshotEntries = {};
for (const [relative, [expectedWidth, expectedHeight, surface]] of Object.entries(screenshotSpecs)) {
  if (!fs.existsSync(path.join(root, relative))) fail(`missing screenshot ${relative}`);
  const bytes = read(relative);
  if (bytes.length < 24 || bytes.subarray(1, 4).toString() !== 'PNG') fail(`${relative} is not a PNG`);
  const width = bytes.readUInt32BE(16);
  const height = bytes.readUInt32BE(20);
  const colorType = bytes[25];
  if (width !== expectedWidth || height !== expectedHeight) {
    fail(`${relative} is ${width}x${height}; expected ${expectedWidth}x${expectedHeight}`);
  }
  if (colorType === 4 || colorType === 6) fail(`${relative} contains an alpha channel`);
  if (relative.includes('/android/') && Math.max(width, height) > 2 * Math.min(width, height)) {
    fail(`${relative} exceeds Google Play's 2:1 maximum aspect ratio`);
  }
  const sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  if (legacyHashes.has(sha256)) fail(`${relative} is a retired encrypted-tone harness screenshot`);
  screenshotEntries[relative] = { sha256, width, height, surface, source: 'real debug app fixture' };
}

const manifestPath = path.join(root, 'store/release-assets.json');
const expectedManifest = {
  schemaVersion: 1,
  version: androidVersion,
  build: Number(androidBuild),
  privacyUrl,
  screenshots: screenshotEntries,
};
if (update) {
  fs.writeFileSync(manifestPath, `${JSON.stringify(expectedManifest, null, 2)}\n`);
  console.log(`Updated ${path.relative(root, manifestPath)} for ${androidVersion} (${androidBuild})`);
} else {
  if (!fs.existsSync(manifestPath)) fail('store/release-assets.json is missing; run this script with --update after recapturing');
  const actualManifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  if (JSON.stringify(actualManifest) !== JSON.stringify(expectedManifest)) {
    fail('release asset manifest does not match versions, policy URL, or screenshot bytes; recapture and run with --update');
  }
  console.log(`Store readiness passed for synchronized release ${androidVersion} (${androidBuild})`);
}
