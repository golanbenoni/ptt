import { copyFile, mkdir } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = resolve(repositoryRoot, 'website');
const destination = resolve(repositoryRoot, 'admin-web/dist/site');
const assets = [
  'index.html',
  'style.css',
  'icon.png',
  'iphone-release.png',
  'android-release.png',
  'og.png',
];

await mkdir(destination, { recursive: true });
await Promise.all(
  assets.map((asset) => copyFile(resolve(source, asset), resolve(destination, asset))),
);

console.log('PTT Talk website assets are ready for the Cloudflare deployment.');
