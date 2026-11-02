// Full walker. Attaches over the debug port, passes the first-run gates (owner PIN, login, trial from the loopback issuer),
// then visits every route in 2 viewports x 3 languages x 2 themes and records numbers + a small screenshot per visit.
// Product data is not edited beyond what first run does. Output: out/walk-full.json, out/shots/*.jpg
import { chromium } from 'playwright-core';
import fs from 'node:fs';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const port = process.argv[2] || '9222';
const PIN = '24681357';
const ROUTES = (process.env.WALK_ROUTES || '/dashboard,/orders,/orders/confirmation-queue,/products,/customers,/deliveries,/inbox,/accounting,/accounting/cod-reconciliation,/analytics,/analytics/extraction,/automations,/automations/new,/storefronts,/storefronts/new,/settings,/profile,/returns,/risk,/imports,/notifications,/onboarding,/agents').split(',');
const LOCALES = (process.env.WALK_LOCALES || 'en,fr,ar').split(',');
const THEMES = (process.env.WALK_THEMES || 'light,dark').split(',');
const VPS = [{ name: 'desk', w: 1366, h: 768 }, { name: 'phone', w: 390, h: 844 }].filter((v) => (process.env.WALK_VPS || 'desk,phone').split(',').includes(v.name));
const out = { ok: false, gates: {}, visits: [], axeOk: false };
fs.mkdirSync('out/shots', { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let axeSrc = null;
try { axeSrc = fs.readFileSync(require.resolve('axe-core/axe.min.js'), 'utf8'); out.axeOk = true; } catch (e) { out.axeError = String(e).slice(0, 200); }

function pageMetrics() {
  const txt = document.body ? document.body.innerText : '';
  const ar = (txt.match(/[\u0600-\u06FF]/g) || []).length, lat = (txt.match(/[A-Za-z]/g) || []).length;
  const vis = (e) => { const r = e.getBoundingClientRect(); const cs = getComputedStyle(e); return r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none'; };
  const name = (e) => (e.innerText || e.getAttribute('aria-label') || e.getAttribute('title') || (e.getAttribute('aria-labelledby') && document.getElementById(e.getAttribute('aria-labelledby'))?.innerText) || (e.id && document.querySelector(`label[for="${CSS.escape(e.id)}"]`)?.innerText) || (e.labels && e.labels[0]?.innerText) || e.getAttribute('placeholder') || e.querySelector('img[alt]')?.getAttribute('alt') || '').trim();
  const ctl = [...document.querySelectorAll('button,a[href],input:not([type=hidden]),select,textarea,[role=button],[role=tab],[role=switch],[role=checkbox]')].filter(vis);
  const unnamed = ctl.filter((e) => !name(e)).slice(0, 6).map((e) => e.tagName.toLowerCase() + (e.className && typeof e.className === 'string' ? '.' + e.className.split(' ')[0] : ''));
  const small = ctl.filter((e) => { const r = e.getBoundingClientRect(); return r.width < 24 || r.height < 24; });
  const iw = innerWidth;
  const wide = [...document.querySelectorAll('body *')].filter((e) => { if (!vis(e)) return false; const r = e.getBoundingClientRect(); return r.right > iw + 1 && !e.closest('[data-overflow-ok],pre,table,[style*="overflow"]'); }).slice(0, 5).map((e) => e.tagName.toLowerCase() + '.' + String(e.className).split(' ')[0] + ':' + Math.round(e.getBoundingClientRect().right));
  let tiny = 0; const tinySample = [];
  for (const e of document.querySelectorAll('body *')) {
    if (!e.childNodes.length) continue;
    const own = [...e.childNodes].filter((n) => n.nodeType === 3 && n.textContent.trim().length > 1);
    if (!own.length || !vis(e)) continue;
    const fs_ = parseFloat(getComputedStyle(e).fontSize);
    if (fs_ < 11) { tiny++; if (tinySample.length < 4) tinySample.push(Math.round(fs_ * 10) / 10 + 'px:' + own[0].textContent.trim().slice(0, 24)); }
  }
  const keyRe = /^[a-z][a-zA-Z0-9]*(\.[a-zA-Z0-9-]+){1,5}$/;
  const keys = []; const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  while (w.nextNode()) { const t = w.currentNode.textContent.trim(); if (keyRe.test(t) && !/\.(com|dz|js|png|jpg|pdf|csv)$/.test(t) && keys.length < 6) keys.push(t.slice(0, 50)); }
  const latinWords = ar > 0 ? [...new Set((document.querySelector('main')?.innerText || txt).match(/[A-Za-z][A-Za-z'-]{3,}/g) || [])].slice(0, 12) : [];
  return {
    url: location.pathname, title: document.title, lang: document.documentElement.lang, dir: document.documentElement.dir,
    dark: document.documentElement.classList.contains('dark'), preset: document.documentElement.getAttribute('data-theme-preset'),
    heads: [...document.querySelectorAll('h1,h2')].filter(vis).slice(0, 4).map((e) => e.innerText.trim().slice(0, 70)),
    h1: document.querySelectorAll('h1').length, textLen: txt.length, ar, lat,
    overflowX: document.documentElement.scrollWidth - iw, wide, tiny, tinySample, unnamed, smallTargets: small.length,
    smallSample: small.slice(0, 4).map((e) => (name(e) || e.tagName).slice(0, 18) + ':' + Math.round(e.getBoundingClientRect().width) + 'x' + Math.round(e.getBoundingClientRect().height)),
    imgNoAlt: [...document.querySelectorAll('img')].filter((i) => vis(i) && !i.hasAttribute('alt')).length, keys, latinWords,
    alerts: [...document.querySelectorAll('[role=alert]')].filter(vis).slice(0, 3).map((e) => e.innerText.trim().slice(0, 100)),
    timing: (() => { const n = performance.getEntriesByType('navigation')[0]; return n ? { ttfb: Math.round(n.responseStart), dcl: Math.round(n.domContentLoadedEventEnd), load: Math.round(n.loadEventEnd) } : null; })(),
    fcp: (performance.getEntriesByType('paint').find((p) => p.name === 'first-contentful-paint') || {}).startTime | 0,
  };
}

try {
  const browser = await chromium.connectOverCDP(`http://127.0.0.1:${port}`, { timeout: 30000 });
  const ctx = browser.contexts()[0]; const page = ctx.pages()[0];
  let cur = ''; const logs = { console: [], failed: [] };
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type())) logs.console.push({ t: m.type(), x: m.text().slice(0, 220) }); });
  page.on('pageerror', (e) => logs.console.push({ t: 'pageerror', x: String(e).slice(0, 220) }));
  page.on('requestfailed', (r) => { const u = r.url().replace(/^http:\/\/127\.0\.0\.1:\d+/, ''); if (!u.includes('runtime-ui-ready')) logs.failed.push({ u: u.slice(0, 110), e: r.failure()?.errorText }); });
  page.on('response', (r) => { if (r.status() >= 400) logs.failed.push({ u: r.url().replace(/^http:\/\/127\.0\.0\.1:\d+/, '').slice(0, 110), s: r.status() }); });
  await page.setViewportSize({ width: 1366, height: 768 });
  await page.waitForLoadState('domcontentloaded', { timeout: 30000 }).catch(() => {});
  await sleep(1500);
  const origin = new URL(page.url()).origin; out.origin = origin.replace(/:\d+$/, ':PORT');

  // gates
  let path = new URL(page.url()).pathname; out.gates.start = path;
  if (path.startsWith('/setup')) {
    const pins = page.locator('input[inputmode=numeric]');
    await pins.nth(0).fill(PIN); await pins.nth(1).fill(PIN);
    const t0 = Date.now();
    await page.getByRole('button', { name: /get started|commencer|ابدأ/i }).click({ timeout: 8000 });
    await page.waitForURL((u) => new URL(u).pathname !== '/setup', { timeout: 120000 }).catch(() => {});
    out.gates.setupSeconds = Math.round((Date.now() - t0) / 100) / 10; await sleep(1500);
  }
  path = new URL(page.url()).pathname;
  if (path.startsWith('/login')) {
    await page.locator('input[inputmode=numeric]').first().fill(PIN);
    const t1 = Date.now();
    await page.getByRole('button', { name: /unlock|déverrouiller|فتح/i }).click({ timeout: 8000 });
    await page.waitForURL((u) => !new URL(u).pathname.startsWith('/login'), { timeout: 90000 }).catch(() => {});
    out.gates.loginSeconds = Math.round((Date.now() - t1) / 100) / 10; await sleep(2500);
  }
  out.gates.afterLogin = new URL(page.url()).pathname;
  const api = async (p, m = 'GET') => page.evaluate(async ([p, m]) => { try { const r = await fetch(p, { method: m, headers: m === 'POST' ? { 'x-requested-with': 'sahelflow' } : {} }); return { s: r.status, b: (await r.text()).slice(0, 300) }; } catch (e) { return { e: String(e).slice(0, 120) }; } }, [p, m]);
  out.gates.licenseBefore = await api('/api/license/status');
  out.gates.trial = await api('/api/license/trial', 'POST');
  out.gates.licenseAfter = await api('/api/license/status');
  out.gates.me = await api('/api/auth/me');
  await page.goto(origin + '/dashboard', { waitUntil: 'domcontentloaded', timeout: 30000 }).catch(() => {});
  await sleep(3000);
  out.gates.dashboardPath = new URL(page.url()).pathname;
  out.nav = await page.evaluate(() => [...new Set([...document.querySelectorAll('a[href^="/"]')].map((a) => a.getAttribute('href').split('?')[0]))]);

  // matrix
  let n = 0;
  for (const vp of VPS) {
    await page.setViewportSize({ width: vp.w, height: vp.h });
    for (const loc of LOCALES) for (const th of THEMES) {
      await ctx.addCookies([{ name: 'sahelflow-locale', value: loc, url: origin }, { name: 'sahelflow-theme', value: th, url: origin }]);
      await page.evaluate((t) => { try { localStorage.setItem('theme', t); } catch {} }, th).catch(() => {});
      for (const r of ROUTES) {
        const v = { vp: vp.name, loc, th, route: r }; const t0 = Date.now();
        logs.console.length = 0; logs.failed.length = 0;
        try {
          const resp = await page.goto(origin + r, { waitUntil: 'domcontentloaded', timeout: 30000 });
          v.status = resp ? resp.status() : null;
          await sleep(1800);
          Object.assign(v, await page.evaluate(pageMetrics));
          v.okLang = v.lang === loc && v.dir === (loc === 'ar' ? 'rtl' : 'ltr'); v.okTheme = v.dark === (th === 'dark');
          if (axeSrc) {
            try {
              await page.evaluate(axeSrc);
              const a = await page.evaluate(async () => { const res = await window.axe.run(document, { runOnly: ['wcag2a', 'wcag2aa'], resultTypes: ['violations'] }); return res.violations.map((x) => ({ id: x.id, imp: x.impact, n: x.nodes.length, t: (x.nodes[0]?.target || []).join(' ').slice(0, 70) })); });
              v.axe = a;
            } catch (e) { v.axeErr = String(e).slice(0, 100); }
          }
          v.console = logs.console.slice(0, 6); v.failed = logs.failed.slice(0, 6);
          const f = `out/shots/${vp.name}_${loc}_${th}_${r.replace(/\//g, '_')}.jpg`;
          await page.screenshot({ path: f, type: 'jpeg', quality: 45, timeout: 15000 }); v.shot = f;
        } catch (e) { v.error = String(e).slice(0, 200); }
        v.ms = Date.now() - t0; out.visits.push(v); n++;
      }
    }
  }
  out.ok = true; out.count = n;
  await browser.close();
} catch (e) { out.error = String(e).slice(0, 600); }
fs.writeFileSync('out/walk-full.json', JSON.stringify(out));
console.log('walk-full', out.ok ? 'ok' : 'fail', 'visits', out.visits.length);
