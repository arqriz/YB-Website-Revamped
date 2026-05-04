import sharp from 'sharp';
import { resolve } from 'path';

const src = process.argv[2];
if (!src) {
  console.error('Usage: node generate-favicons.mjs <source-image>');
  process.exit(1);
}

const source = resolve(src);

const targets = [
  { out: 'favicon_io/android-chrome-512x512.png', size: 512 },
  { out: 'favicon_io/android-chrome-192x192.png', size: 192 },
  { out: 'favicon_io/apple-touch-icon.png',        size: 180 },
  { out: 'favicon_io/favicon-32x32.png',            size: 32  },
  { out: 'favicon_io/favicon-16x16.png',            size: 16  },
  { out: 'brand_assets/favicon-512.png',            size: 512 },
];

for (const { out, size } of targets) {
  await sharp(source)
    .resize(size, size, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toFile(out);
  console.log(`✓ ${out} (${size}×${size})`);
}

console.log('\nDone. Remember to regenerate favicon.ico if needed.');
