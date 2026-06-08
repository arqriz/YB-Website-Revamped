import puppeteer from 'puppeteer';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const screenshotDir = path.join(__dirname, 'temporary screenshots');

if (!fs.existsSync(screenshotDir)) fs.mkdirSync(screenshotDir, { recursive: true });

const BASE = 'http://localhost:3000';

const PAGES = [
  { slug: 'home',         url: '/' },
  { slug: 'about',        url: '/about.html' },
  { slug: 'how-it-works', url: '/how-it-works.html' },
  { slug: 'gallery',      url: '/gallery.html' },
  { slug: 'our-impact',   url: '/our-impact.html' },
  { slug: 'partner',      url: '/partner.html' },
  { slug: 'find-a-bin',   url: '/find-a-bin.html' },
  { slug: 'blog',         url: '/blog.html' },
  { slug: 'faq',          url: '/faq.html' },
];

// 5 most-used viewport widths globally (StatCounter 2024-2025)
const VIEWPORTS = [
  { width: 360,  height: 800,  label: '360px' },   // #1 Android (Samsung/Pixel)
  { width: 390,  height: 844,  label: '390px' },   // #2 iPhone 14/15 Pro
  { width: 768,  height: 1024, label: '768px' },   // #3 iPad / tablet
  { width: 1280, height: 800,  label: '1280px' },  // #4 Laptop / MacBook
  { width: 1920, height: 1080, label: '1920px' },  // #5 Full HD desktop
];

const browser = await puppeteer.launch({
  headless: 'new',
  args: ['--no-sandbox', '--disable-setuid-sandbox'],
});

let count = 0;

for (const vp of VIEWPORTS) {
  console.log(`\n── Viewport ${vp.label} ──────────────────────────`);
  for (const pg of PAGES) {
    count++;
    const filename = `screenshot-${String(count).padStart(2, '0')}-${pg.slug}-${vp.label}.png`;
    const filepath = path.join(screenshotDir, filename);

    const page = await browser.newPage();
    await page.setViewport({ width: vp.width, height: vp.height });
    await page.goto(BASE + pg.url, { waitUntil: 'networkidle2', timeout: 30000 });

    // Scroll to trigger IntersectionObserver reveals
    await page.evaluate(async () => {
      await new Promise(resolve => {
        let total = 0;
        const dist = 400;
        const timer = setInterval(() => {
          window.scrollBy(0, dist);
          total += dist;
          if (total >= document.body.scrollHeight) {
            clearInterval(timer);
            window.scrollTo(0, 0);
            resolve();
          }
        }, 60);
      });
    });
    await page.evaluate(() => {
      document.querySelectorAll('.reveal').forEach(el => el.classList.add('visible'));
    });
    await new Promise(r => setTimeout(r, 300));

    await page.screenshot({ path: filepath, fullPage: true });
    await page.close();

    console.log(`  [${count}/45] ${filename}`);
  }
}

await browser.close();
console.log(`\nDone — ${count} screenshots saved to ./temporary screenshots/`);
