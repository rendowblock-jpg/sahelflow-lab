// Attaches to the running app over the debug port, records what it shows at first start, then asks the page's own origin for a
// list of routes and records status, final URL, title and a small screenshot for each. No product writes beyond what a visit does.
import { chromium } from 'playwright-core';
import fs from 'node:fs';
const port = process.argv[2] || '9222';
const out = { ok: false, steps: [], console: [], failed: [] };
fs.mkdirSync('out/shots', { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function describe(page, label) {
  const rec = { step: label };
  try {
    rec.url = page.url(); rec.title = await page.title();
    rec.doc = await page.evaluate(() => ({
      lang: document.documentElement.lang, dir: document.documentElement.dir, cls: document.documentElement.className.slice(0, 120),
      theme: document.documentElement.getAttribute('data-theme'), preset: document.documentElement.getAttribute('data-theme-preset'),
      w: innerWidth, h: innerHeight, dpr: devicePixelRatio, textLen: document.body ? document.body.innerText.length : 0,
      h1: [...document.querySelectorAll('h1,h2')].slice(0, 6).map((e) => e.innerText.slice(0, 80)),
      buttons: [...document.querySelectorAll('button,[role=button]')].slice(0, 30).map((e) => (e.innerText || e.getAttribute('aria-label') || '').trim().slice(0, 50)),
      inputs: [...document.querySelectorAll('input,select,textarea')].slice(0, 20).map((e) => ({ t: e.type, n: e.name || e.id, ph: (e.placeholder || '').slice(0, 40) })),
      links: [...new Set([...document.querySelectorAll('a[href]')].map((a) => a.getAttribute('href')))].slice(0, 120),
    }));
    rec.aria = String(await page.locator('body').ariaSnapshot().catch((e) => String(e))).slice(0, 5000);
    const f = `out/shots/${label.replace(/[^a-z0-9-]/gi, '_')}.png`;
    await page.screenshot({ path: f, timeout: 15000 }); rec.shot = f;
  } catch (e) { rec.error = String(e).slice(0, 300); }
  return rec;
}
try {
  const browser = await chromium.connectOverCDP(`http://127.0.0.1:${port}`, { timeout: 30000 });
  const ctx = browser.contexts()[0];
  const page = ctx.pages()[0];
  page.on('console', (m) => { if (out.console.length < 200) out.console.push({ t: m.type(), x: m.text().slice(0, 240), u: page.url().replace(/\?.*$/, '') }); });
  page.on('requestfailed', (r) => { if (out.failed.length < 100) out.failed.push({ u: r.url().replace(/\?.*$/, '').slice(0, 160), e: r.failure()?.errorText }); });
  await page.waitForLoadState('networkidle', { timeout: 20000 }).catch(() => {});
  out.steps.push(await describe(page, 'initial'));
  const origin = new URL(page.url()).origin;
  out.origin = origin.replace(/:\d+$/, ':PORT');
  const routes = ['/', '/login', '/setup', '/onboarding', '/dashboard', '/orders', '/products', '/customers', '/deliveries', '/inbox', '/accounting', '/analytics', '/automations', '/storefronts', '/settings', '/profile', '/returns', '/risk', '/imports', '/notifications', '/agents'];
  for (const r of routes) {
    const rec = { step: 'route ' + r };
    const t0 = Date.now();
    try {
      const resp = await page.goto(origin + r, { waitUntil: 'domcontentloaded', timeout: 30000 });
      rec.status = resp ? resp.status() : null;
      await page.waitForLoadState('networkidle', { timeout: 8000 }).catch(() => {});
      await sleep(600);
      rec.finalPath = new URL(page.url()).pathname; rec.title = await page.title();
      rec.h = await page.evaluate(() => [...document.querySelectorAll('h1,h2')].slice(0, 3).map((e) => e.innerText.slice(0, 60)));
      rec.textLen = await page.evaluate(() => (document.body ? document.body.innerText.length : 0));
      const f = `out/shots/route_${r.replace(/\//g, '_') || '_root'}.png`;
      await page.screenshot({ path: f, timeout: 15000 }); rec.shot = f;
    } catch (e) { rec.error = String(e).slice(0, 240); }
    rec.ms = Date.now() - t0;
    out.steps.push(rec);
  }
  out.ok = true;
  await browser.close();
} catch (e) { out.error = String(e).slice(0, 600); }
fs.writeFileSync('out/walk-probe.json', JSON.stringify(out, null, 1));
console.log('walk-probe', out.ok ? 'ok' : 'fail', 'steps', out.steps.length);
