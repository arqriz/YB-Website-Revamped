// compress-images.mjs
// Resizes and compresses the hero slideshow photos to web-friendly sizes.
// Run once: node compress-images.mjs
// Requires: npm install sharp

import sharp from 'sharp';
import { readdir, mkdir } from 'fs/promises';
import { join, extname, basename } from 'path';

const INPUT_DIR  = './Chosen Pictures';
const OUTPUT_DIR = './Chosen Pictures/web';
const TARGET_WIDTH = 1920;   // max width in px
const JPEG_QUALITY = 82;     // 0–100, 80-85 is the sweet spot

const SLIDESHOW_PHOTOS = [
  '_DSC3418.jpg',
  '_DSC3439.jpg',
  '_DSC3447.jpg',
  '_DSC3521.jpg',
  '_DSC3520.jpg',
];

await mkdir(OUTPUT_DIR, { recursive: true });

for (const file of SLIDESHOW_PHOTOS) {
  const input  = join(INPUT_DIR, file);
  const output = join(OUTPUT_DIR, file);

  const { size: before } = await import('fs').then(fs =>
    fs.promises.stat(input)
  );

  await sharp(input)
    .resize({ width: TARGET_WIDTH, withoutEnlargement: true })
    .jpeg({ quality: JPEG_QUALITY, mozjpeg: true })
    .toFile(output);

  const { size: after } = await import('fs').then(fs =>
    fs.promises.stat(output)
  );

  const pct = Math.round((1 - after / before) * 100);
  console.log(`${file}: ${(before/1024/1024).toFixed(1)}MB → ${(after/1024).toFixed(0)}KB  (-${pct}%)`);
}

console.log('\nDone. Compressed files are in: Chosen Pictures/web/');
console.log('Update index.html paths from "Chosen%20Pictures/" to "Chosen%20Pictures/web/" once you\'re happy with the results.');
