import { copyFile, mkdir } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const website = resolve(root, 'website');

await copyFile(
  resolve(root, 'store/screenshots/ios/iphone-release.png'),
  resolve(website, 'iphone-release.png'),
);
await copyFile(
  resolve(root, 'store/screenshots/android/phone-release.png'),
  resolve(website, 'android-release.png'),
);

for (const destination of [
  resolve(root, 'store/privacy-public'),
  resolve(root, 'store/privacy-site/public'),
]) {
  await mkdir(destination, { recursive: true });
  for (const asset of ['icon.png', 'iphone-release.png', 'android-release.png', 'og.png']) {
    await copyFile(resolve(website, asset), resolve(destination, asset));
  }
}

console.log('Synchronized current PTT Talk artwork across website surfaces.');
