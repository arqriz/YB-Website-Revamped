
const puppeteer = require('./node_modules/puppeteer');
(async () => {
  let browser;
  try {
    browser = await puppeteer.launch({executablePath: 'C:/Users/nateh/.cache/puppeteer/chrome/win64-136.0.7103.92/chrome-win64/chrome.exe'});
  } catch(e) {
    const cp = require('child_process');
    const which = cp.execSync('node -e "const p = require(require.resolve(\"puppeteer\", {paths: [require(\"os\").homedir() + \"/AppData/Local/Temp/puppeteer-test\"]})); console.log(p.executablePath())"').toString().trim();
    browser = await puppeteer.launch({executablePath: which});
  }
  const page = await browser.newPage();
  await page.setViewport({width: 1400, height: 400});
  await page.goto('http://localhost:3000/', {waitUntil: 'networkidle2'});
  const footerTop = await page.evaluate(() => document.querySelector('footer').getBoundingClientRect().top + window.scrollY);
  await page.evaluate((y) => window.scrollTo(0, y), footerTop - 20);
  await new Promise(r => setTimeout(r, 400));
  await page.screenshot({path: 'temporary screenshots/footer-zoom.png', fullPage: false});
  await browser.close();
})();
