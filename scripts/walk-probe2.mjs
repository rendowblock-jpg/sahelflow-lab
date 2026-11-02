// Probe 2. Attaches to the running app over the debug port. Creates the owner PIN through the real setup form, follows the
// gates (login, licence trial from the loopback issuer), then records every route: status, final path, headings, overflow,
// console problems and a small screenshot. Nothing here edits product data beyond what a normal first run does.
import { chromium } from 'playwright-core';
import fs from 'node:fs';
const port = process.argv[2] || '9222';
const PIN = '24681357';
const out = { ok: false, steps: [], gate: [], api: {}, nav: [], routes: [], console: [], failed: [] };
fs.mkdirSync('out/shots', { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let page;
let mark = 0;
async function snap(label, full = false) {
  const rec = { step: label, t: new Date().toISOString().slice(11, 19) };
  try {
    rec.url = page.url().replace(/^http:\/\/127\.0\.0\.1:\d+/, '');
    rec.title = await page.title();
    rec.doc = await page.evaluate(() => ({
      lang: document.documentElement.lang, dir: document.documentElement.dir, cls: document.documentElement.className.replace(/__variable_[0-9a-f]+\s*/g, '').slice(0, 80),
      preset: document.documentElement.getAttribute('data-theme-preset'), w: innerWidth, h: innerHeight, textLen: document.body ? document.body.innerText.length : 0,
      heads: [...document.querySelectorAll('h1,h2,h3')].slice(0, 8).map((e) => e.innerText.trim().slice(0, 90)),
      buttons: [...document.querySelectorAll('button,[role=button],a[role=button]')].slice(0, 40).map((e) => (e.innerText || e.getAttribute('aria-label') || '').trim().slice(0, 50)),
      alerts: [...document.querySelectorAll('[role=alert],[role=status],[data-sonner-toast]')].slice(0, 5).map((e) => e.innerText.trim().slice(0, 140)),
      overflowX: document.documentElement.scrollWidth - innerWidth,
    }));
    if (full) rec.aria = String(await page.locator('body').ariaSnapshot().catch((e) => String(e))).slice(0, 3500);
    const f = `out/shots/${String(++mark).padStart(2, '0')}_${label.replace(/[^a-z0-9-]/gi, '_').slice(0, 40)}.jpg`;
    await page.screenshot({ path: f, type: 'jpeg', quality: 55, timeout: 15000 }); rec.shot = f;
  } catch (e) { rec.error = String(e).slice(0, 300); }
  return rec;
}
async function api(path, method = 'GET') {
  return page.evaluate(async ([p, m]) => {
    try {
      const r = await fetch(p, { method: m, headers: m === 'POST' ? { 'x-requested-with': 'sahelflow', 'content-type': 'application/json' } : {} });
      const text = await r.text();
      return { status: r.status, body: text.slice(0, 700) };
    } catch (e) { return { error: String(e).slice(0, 200) }; }
  }, [path, method]);
}
try {
  const browser = await chromium.connectOverCDP(`http://127.0.0.1:${port}`, { timeout: 30000 });
  page = browser.contexts()[0].pages()[0];
  let routeNow = '';
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type()) && out.console.length < 300) out.console.push({ route: routeNow, t: m.type(), x: m.text().slice(0, 260) }); });
  page.on('pageerror', (e) => { if (out.console.length < 300) out.console.push({ route: routeNow, t: 'pageerror', x: String(e).slice(0, 260) }); });
  page.on('requestfailed', (r) => { const u = r.url().replace(/^http:\/\/127\.0\.0\.1:\d+/, ''); if (!u.includes('runtime-ui-ready') && out.failed.length < 150) out.failed.push({ route: routeNow, u: u.slice(0, 140), e: r.failure()?.errorText }); });
  page.on('response', (r) => { const s = r.status(); const u = r.url().replace(/^http:\/\/127\.0\.0\.1:\d+/, ''); if (s >= 400 && out.failed.length < 150) out.failed.push({ route: routeNow, u: u.slice(0, 140), status: s }); });
  await page.waitForLoadState('domcontentloaded', { timeout: 20000 }).catch(() => {});
  await sleep(1500);
  out.api.authStatusBefore = await api('/api/auth/status');
  out.steps.push(await snap('setup-initial', true));

  // 1. owner PIN through the real form
  try {
    const pins = page.locator('input[inputmode=numeric]');
    out.pinInputs = await pins.count();
    out.inputAttrs = await page.evaluate(() => [...document.querySelectorAll('input')].map((e) => ({ t: e.type, n: e.name, id: e.id, im: e.inputMode, ac: e.autocomplete })));
    await pins.nth(0).fill(PIN, { timeout: 10000 });
    await pins.nth(1).fill(PIN, { timeout: 10000 });
    await sleep(300);
    out.steps.push(await snap('setup-filled'));
    await page.getByRole('button', { name: /get started|commencer|ابدأ/i }).click({ timeout: 8000 });
  } catch (e) { out.steps.push({ step: 'setup-submit', error: String(e).slice(0, 300) }); }
  await sleep(6000);
  out.steps.push(await snap('after-setup', true));
  out.api.authStatusAfter = await api('/api/auth/status');

  // 2. follow gates a few times
  for (let i = 0; i < 4; i++) {
    const path = new URL(page.url()).pathname;
    out.gate.push({ i, path });
    if (path.startsWith('/login')) {
      try { await page.locator('input[type=password]').first().fill(PIN); await page.keyboard.press('Enter'); } catch {}
      await sleep(5000); out.steps.push(await snap('after-login-' + i, true));
    } else break;
  }
  out.api.licenseBefore = await api('/api/license/status');
  out.api.trial = await api('/api/license/trial', 'POST');
  await sleep(1500);
  out.api.licenseAfter = await api('/api/license/status');
  out.api.me = await api('/api/auth/me');

  // 3. home and nav
  routeNow = '/';
  await page.goto(page.url().replace(/\/[^/]*$/, '') + '/', { waitUntil: 'domcontentloaded', timeout: 30000 }).catch(() => {});
  await sleep(3000);
  out.steps.push(await snap('home', true));
  out.nav = await page.evaluate(() => [...new Set([...document.querySelectorAll('a[href^="/"]')].map((a) => a.getAttribute('href').split('?')[0]))]);

  // 4. routes
  const origin = new URL(page.url()).origin;
  const routes = ['/', '/dashboard', '/orders', '/orders/confirmation-queue', '/products', '/customers', '/deliveries', '/inbox', '/accounting', '/accounting/cod-reconciliation', '/analytics', '/analytics/extraction', '/automations', '/automations/new', '/storefronts', '/storefronts/new', '/settings', '/profile', '/returns', '/risk', '/imports', '/notifications', '/onboarding', '/agents', '/login', '/setup', '/join'];
  for (const r of routes) {
    routeNow = r;
    const rec = { route: r };
    const t0 = Date.now();
    try {
      const resp = await page.goto(origin + r, { waitUntil: 'domcontentloaded', timeout: 30000 });
      rec.status = resp ? resp.status() : null;
      await sleep(1800);
      const s = await snap('route' + r.replace(/\//g, '_'));
      rec.finalPath = s.url; rec.title = s.title; rec.heads = s.doc?.heads; rec.alerts = s.doc?.alerts; rec.overflowX = s.doc?.overflowX; rec.textLen = s.doc?.textLen; rec.shot = s.shot; rec.cls = s.doc?.cls; rec.buttons = s.doc?.buttons?.slice(0, 12);
    } catch (e) { rec.error = String(e).slice(0, 240); }
    rec.ms = Date.now() - t0;
    out.routes.push(rec);
  }
  out.ok = true;
  await browser.close();
} catch (e) { out.error = String(e).slice(0, 600); }
fs.writeFileSync('out/walk2.json', JSON.stringify(out, null, 1));
console.log('walk-probe2', out.ok ? 'ok' : 'fail', 'steps', out.steps.length, 'routes', out.routes.length);
