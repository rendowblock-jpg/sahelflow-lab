// Attaches to the app's WebView2 over the debug port and records what the page is. No product writes.
import { chromium } from 'playwright-core';
import fs from 'node:fs';
const port = process.argv[2] || '9222';
const out = { ok: false, pages: [], console: [], failed: [] };
fs.mkdirSync('out/shots', { recursive: true });
try {
  const browser = await chromium.connectOverCDP(`http://127.0.0.1:${port}`, { timeout: 20000 });
  out.contexts = browser.contexts().length;
  for (const ctx of browser.contexts()) {
    for (const page of ctx.pages()) {
      page.on('console', (m) => out.console.push({ type: m.type(), text: m.text().slice(0, 300) }));
      page.on('requestfailed', (r) => out.failed.push({ url: r.url().replace(/\?.*$/, '').slice(0, 200), err: r.failure()?.errorText }));
      const rec = { url: page.url().replace(/\?.*$/, ''), title: await page.title().catch(() => null) };
      try {
        rec.viewport = await page.evaluate(() => ({ w: innerWidth, h: innerHeight, dpr: devicePixelRatio }));
        rec.doc = await page.evaluate(() => ({ lang: document.documentElement.lang, dir: document.documentElement.dir, preset: document.documentElement.getAttribute('data-theme-preset'), textLen: document.body.innerText.length, text: document.body.innerText.slice(0, 1500) }));
        rec.nav = await page.evaluate(() => { const n = performance.getEntriesByType('navigation')[0]; return n ? { ttfb: Math.round(n.responseStart), dcl: Math.round(n.domContentLoadedEventEnd), load: Math.round(n.loadEventEnd) } : null; });
        rec.paint = await page.evaluate(() => performance.getEntriesByType('paint').map((p) => ({ n: p.name, t: Math.round(p.startTime) })));
        rec.heapMB = await page.evaluate(() => (performance.memory ? Math.round(performance.memory.usedJSHeapSize / 1e6) : null));
        rec.aria = String(await page.locator('body').ariaSnapshot().catch((e) => String(e))).slice(0, 6000);
        const f = `out/shots/page-${out.pages.length}.png`;
        await page.screenshot({ path: f, timeout: 15000 });
        rec.shot = f;
      } catch (e) { rec.error = String(e).slice(0, 300); }
      out.pages.push(rec);
    }
  }
  await new Promise((r) => setTimeout(r, 3000));
  out.ok = out.pages.length > 0;
  await browser.close();
} catch (e) { out.error = String(e).slice(0, 500); }
fs.writeFileSync('out/cdp.json', JSON.stringify(out, null, 1));
console.log('cdp-probe', out.ok ? 'ok' : 'fail');
