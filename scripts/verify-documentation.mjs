import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');
const fail = (message) => { throw new Error(`Documentation verification failed: ${message}`); };
const one = (source, expression, label) => {
  const values = [...source.matchAll(expression)].map((match) => match[1]);
  const unique = [...new Set(values)];
  if (unique.length !== 1) fail(`${label} must resolve to one value; found ${unique.join(', ') || 'none'}`);
  return unique[0];
};

const android = read('android/talk/build.gradle.kts');
const ios = read('ios/TalkApp/TalkApp.xcodeproj/project.pbxproj');
const version = one(android, /^\s*versionName\s*=\s*"([^"]+)"/gm, 'Android version');
const build = one(android, /^\s*versionCode\s*=\s*(\d+)/gm, 'Android build');
if (version !== one(ios, /^\s*MARKETING_VERSION\s*=\s*([^;]+);/gm, 'iOS version')) {
  fail('Android and iOS versions differ');
}
if (build !== one(ios, /^\s*CURRENT_PROJECT_VERSION\s*=\s*([^;]+);/gm, 'iOS build')) {
  fail('Android and iOS build numbers differ');
}

const versionedDocuments = [
  'README.md',
  'docs/CURRENT_STATE.md',
  'docs/ANDROID_RELEASE.md',
  'ios/README.md',
  'cloudflare/README.md',
  'deploy/helm/ptt/README.md',
  'store/metadata/PRIVACY_DISCLOSURES.md',
  'store/metadata/TEST_GROUPS.md',
  'store/metadata/en-US.md',
];
for (const document of versionedDocuments) {
  const contents = read(document);
  if (!contents.includes(version) || !contents.includes(build)) {
    fail(`${document} is not labeled with ${version} and build ${build}`);
  }
}

const markdownFiles = execFileSync('rg', ['--files', '-g', '*.md'], {
  cwd: root,
  encoding: 'utf8',
}).trim().split('\n').filter(Boolean);

for (const document of markdownFiles) {
  const contents = read(document);
  if (!document.startsWith('research/')) {
    const staleVersions = [...contents.matchAll(/\b0\.1\.\d+\b/g)]
      .map((match) => match[0])
      .filter((candidate) => candidate !== version);
    if (staleVersions.length) fail(`${document} contains stale version ${staleVersions[0]}`);
  }

  for (const match of contents.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
    let target = match[1].trim().split('#')[0];
    if (!target || /^(https?:|mailto:)/.test(target)) continue;
    if (target.startsWith('<') && target.endsWith('>')) target = target.slice(1, -1);
    const resolved = target.startsWith('/')
      ? target
      : path.resolve(root, path.dirname(document), target);
    if (!fs.existsSync(resolved)) fail(`${document} links to missing local path ${match[1]}`);
  }
}

const currentState = read('docs/CURRENT_STATE.md');
const rustControl = read('server/control/src/main.rs');
const adminSessionRoutes = [
  '/v1/admin/session/start',
  '/v1/admin/session/consume',
  '/v1/admin/session/revoke',
];
const rustHasAdminSessions = adminSessionRoutes.every((route) => rustControl.includes(route));
const documentsSayMissing = currentState.includes('does not yet expose the three short-lived admin');
if (rustHasAdminSessions === documentsSayMissing) {
  fail('CURRENT_STATE.md does not match Rust admin-session route parity');
}

for (const required of ['docs/CURRENT_STATE.md', 'docs/USER_GUIDE.md', 'docs/ADMIN_GUIDE.md']) {
  if (!read('README.md').includes(required)) fail(`README.md does not link ${required}`);
}

console.log(`Documentation verified for PTT Talk ${version} (${build}): ${markdownFiles.length} Markdown files.`);
