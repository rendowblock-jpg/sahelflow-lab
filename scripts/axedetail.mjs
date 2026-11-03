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
const VPS = [{ name: 'min', w: 800, h: 560 }, { name: 'xga', w: 1024, h: 768 }, { name: 'desk', w: 1366, h: 768 }, { name: 'phone', w: 390, h: 844 }].filter((v) => (process.env.WALK_VPS || 'min,xga,desk,phone').split(',').includes(v.name));
const out = { ok: false, gates: {}, visits: [], axeOk: false, demo: {}, dyn: {} };
let DYN = [];
const PHONE_STATIC = ['/dashboard', '/orders', '/products', '/customers', '/inbox'];
const ALL_ROUTES = (vp) => (vp.name === 'phone' ? [...PHONE_STATIC, ...DYN] : [...ROUTES, ...DYN]);
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
  const wide = [...document.querySelectorAll('body *')].filter((e) => { if (!vis(e)) return false; const r = e.getBoundingClientRect(); return r.right > iw + 1 && !e.closest('[data-scroll=true],[data-overflow-ok],pre,table,[style*="overflow"]'); }).slice(0, 5).map((e) => e.tagName.toLowerCase() + '.' + String(e.className).split(' ')[0] + ':' + Math.round(e.getBoundingClientRect().right));
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
    url: location.pathname,
    rows: document.querySelectorAll('tbody tr,[role=row]').length,
    bad: (() => { const m = txt.match(/NaN|Invalid Date|undefined|\[object Object\]|\bnull\b|%s|\{\{|\}\}/g); return m ? [...new Set(m)].slice(0, 5) : []; })(),
    clipped: (() => { const o = []; for (const e of document.querySelectorAll('main *')) { if (o.length >= 4 || !vis(e)) continue; const cs = getComputedStyle(e); if ((cs.overflow === 'hidden' || cs.overflowX === 'hidden') && cs.textOverflow !== 'ellipsis' && e.scrollWidth > e.clientWidth + 2 && (e.innerText || '').trim().length > 2) o.push(e.tagName.toLowerCase() + ':' + (e.innerText || '').trim().slice(0, 24) + ':' + e.scrollWidth + '>' + e.clientWidth); } return o; })(), title: document.title, lang: document.documentElement.lang, dir: document.documentElement.dir,
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
  // every API call slower than 800 ms (setup, login, trial, demo load, page data): where do the seconds go?
  out.slowApi = []; let phase = 'start';
  page.on('requestfinished', async (rq) => { try { const u = rq.url().replace(/^http:\/\/127\.0\.0\.1:\d+/, ''); if (!u.startsWith('/api/') || out.slowApi.length >= 60) return; const t = rq.timing(); const d = Math.round(t.responseEnd); if (d > 800) out.slowApi.push({ phase, m: rq.method(), u: u.slice(0, 90), ms: d }); } catch {} });
  await page.setViewportSize({ width: 1366, height: 768 });
  await page.waitForLoadState('domcontentloaded', { timeout: 30000 }).catch(() => {});
  await sleep(1500);
  const origin = new URL(page.url()).origin; out.origin = origin.replace(/:\d+$/, ':PORT');

  // gates
  let path = new URL(page.url()).pathname; out.gates.start = path;
  phase = 'setup';
  out.t_setup0 = Date.now();
  if (path.startsWith('/setup')) {
    const pins = page.locator('input[inputmode=numeric]');
    await pins.nth(0).fill(PIN); await pins.nth(1).fill(PIN);
    const t0 = Date.now();
    await page.getByRole('button', { name: /get started|commencer|ابدأ/i }).click({ timeout: 8000 });
    await page.waitForURL((u) => new URL(u).pathname !== '/setup', { timeout: 120000 }).catch(() => {});
    out.gates.setupSeconds = Math.round((Date.now() - t0) / 100) / 10; await sleep(1500);
  }
  path = new URL(page.url()).pathname;
  phase = 'login';
  if (path.startsWith('/login')) {
    await page.locator('input[inputmode=numeric]').first().fill(PIN);
    const t1 = Date.now();
    await page.getByRole('button', { name: /unlock|déverrouiller|فتح/i }).click({ timeout: 8000 });
    await page.waitForURL((u) => !new URL(u).pathname.startsWith('/login'), { timeout: 90000 }).catch(() => {});
    out.gates.loginSeconds = Math.round((Date.now() - t1) / 100) / 10; await sleep(2500);
  }
  out.gates.afterLogin = new URL(page.url()).pathname;
  const api = async (p, m = 'GET') => page.evaluate(async ([p, m]) => { try { const r = await fetch(p, { method: m, headers: m === 'POST' ? { 'x-requested-with': 'sahelflow' } : {} }); return { s: r.status, b: (await r.text()).slice(0, 300) }; } catch (e) { return { e: String(e).slice(0, 120) }; } }, [p, m]);
  phase = 'trial';
  out.gates.licenseBefore = await api('/api/license/status');
  out.gates.trial = await api('/api/license/trial', 'POST');
  out.gates.licenseAfter = await api('/api/license/status');
  out.gates.me = await api('/api/auth/me');
  // ---- walk 2: the built-in demo workspace gives lists and [id] pages real content
  const apiJson = async (p, m = 'GET') => page.evaluate(async ([p, m]) => { try { const r = await fetch(p, { method: m, headers: m === 'GET' ? {} : { 'x-requested-with': 'sahelflow' } }); const t = await r.text(); let j = null; try { j = JSON.parse(t); } catch {} return { s: r.status, j, len: t.length, head: t.slice(0, 200) }; } catch (e) { return { s: -1, err: String(e).slice(0, 120) }; } }, [p, m]);
  phase = 'demo';
  const dt0 = Date.now();
  const dstat = await apiJson('/api/demo-data');
  out.demo.statusBefore = { s: dstat.s, head: dstat.head };
  const dpost = await apiJson('/api/demo-data', 'POST');
  out.demo.load = { s: dpost.s, seconds: Math.round((Date.now() - dt0) / 100) / 10, head: dpost.head };
  const dafter = await apiJson('/api/demo-data');
  out.demo.statusAfter = { s: dafter.s, head: dafter.head };
  const firstId = (j) => { const seen = new Set(); const walk = (x) => { if (!x || typeof x !== 'object' || seen.has(x)) return null; seen.add(x); if (Array.isArray(x)) { for (const y of x) { if (y && typeof y === 'object' && typeof y.id === 'string') return y.id; } for (const y of x) { const f = walk(y); if (f) return f; } return null; } for (const k of Object.keys(x)) { const f = walk(x[k]); if (f) return f; } return null; }; return walk(j); };
  const lists = { orders: '/api/orders?limit=5', products: '/api/products?limit=5', customers: '/api/customers?limit=5', deliveries: '/api/delivery', returns: '/api/returns', automations: '/api/automations', conversations: '/api/conversations' };
  for (const [k, u] of Object.entries(lists)) { const r = await apiJson(u); out.dyn[k] = { s: r.s, len: r.len, id: r.j ? firstId(r.j) : null }; }
  if (out.dyn.orders?.id) DYN.push('/orders/' + out.dyn.orders.id);
  if (out.dyn.products?.id) DYN.push('/products/' + out.dyn.products.id);
  if (out.dyn.customers?.id) DYN.push('/customers/' + out.dyn.customers.id);
  if (out.dyn.deliveries?.id) DYN.push('/deliveries/' + out.dyn.deliveries.id);
  if (out.dyn.returns?.id) DYN.push('/returns/' + out.dyn.returns.id);
  if (out.dyn.automations?.id) DYN.push('/automations/' + out.dyn.automations.id);
  out.demo.dynRoutes = DYN.slice();
  await sleep(1500);
  await page.goto(origin + '/dashboard', { waitUntil: 'domcontentloaded', timeout: 30000 }).catch(() => {});
  await sleep(3000);
  out.gates.dashboardPath = new URL(page.url()).pathname;
  out.nav = await page.evaluate(() => [...new Set([...document.querySelectorAll('a[href^="/"]')].map((a) => a.getAttribute('href').split('?')[0]))]);

  phase = 'walk';
  // matrix
  let n = 0;
  // pass 1: the whole standard matrix on the default look; pass 2..: the four looks in light, desktop, en + ar (dark is one neutral stack for all looks)
  const DESK = { name: 'desk', w: 1366, h: 768 };
  const PASSES = [{ look: 'default', vps: VPS, locales: LOCALES, themes: THEMES }, ...(process.env.WALK_LOOKS === 'none' ? [] : ['sahel', 'atlas', 'oasis', 'dune'].map((p) => ({ look: p, vps: [DESK], locales: ['en', 'ar'], themes: ['light'] })))];
  out.passes = PASSES.map((p) => p.look);
  for (const pass of PASSES) for (const vp of pass.vps) {
    await page.setViewportSize({ width: vp.w, height: vp.h });
    for (const loc of pass.locales) for (const th of pass.themes) {
      await ctx.addCookies([{ name: 'sahelflow-locale', value: loc, url: origin }, { name: 'sahelflow-theme', value: th, url: origin }]);
      if (pass.look !== 'default') await ctx.addCookies([{ name: 'sahelflow-theme-preset', value: pass.look, url: origin }]);
      await page.evaluate((t) => { try { localStorage.setItem('theme', t); } catch {} }, th).catch(() => {});
      for (const r of ALL_ROUTES(vp)) {
        const v = { vp: vp.name, loc, th, route: r, look: pass.look }; const t0 = Date.now();
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
              const a = await page.evaluate(async () => { const res = await window.axe.run(document, { runOnly: ['wcag2a', 'wcag2aa'], resultTypes: ['violations'] }); return res.violations.map((x) => ({ id: x.id, imp: x.impact, n: x.nodes.length, t: (x.nodes[0]?.target || []).join(' ').slice(0, 70), nodes: x.nodes.slice(0, 6).map((nd) => { const c = (nd.any || []).concat(nd.all || [])[0]; const d = (c && c.data) || {}; return { tg: (nd.target || []).join(' ').slice(0, 90), html: (nd.html || '').slice(0, 170), fg: d.fgColor, bg: d.bgColor, ratio: d.contrastRatio, need: d.expectedContrastRatio, size: d.fontSize, wt: d.fontWeight, msg: d.messageKey }; }) })); });
              v.axe = a;
            } catch (e) { v.axeErr = String(e).slice(0, 100); }
          }
          v.console = logs.console.slice(0, 6); v.failed = logs.failed.slice(0, 6);
          const f = `out/shots/${pass.look === 'default' ? '' : pass.look + '_'}${vp.name}_${loc}_${th}_${r.replace(/\//g, '_')}.jpg`;
          await page.screenshot({ path: f, type: 'jpeg', quality: 45, timeout: 15000 }); v.shot = f;
        } catch (e) { v.error = String(e).slice(0, 200); }
        v.ms = Date.now() - t0; out.visits.push(v); n++;
      }
    }
  }
  // ---- F-0012 on Windows: more than 10 minutes after sign-in, /onboarding must not show wrong ticks; with the fix it asks for the PIN
  phase = 'onboarding';
  out.onb = { minutesSinceSetup: Math.round((Date.now() - out.t_setup0) / 600) / 100 };
  try {
    await ctx.addCookies([{ name: 'sahelflow-locale', value: 'en', url: origin }, { name: 'sahelflow-theme', value: 'light', url: origin }]);
    await ctx.clearCookies({ name: 'sahelflow-theme-preset' }).catch(() => {});
    const f403 = [];
    const on403 = (r) => { if (r.status() === 403) f403.push(r.url().replace(/^http:\/\/127\.0\.0\.1:\d+/, '').split('?')[0]); };
    page.on('response', on403);
    await page.setViewportSize({ width: 1366, height: 768 });
    await page.goto(origin + '/onboarding', { waitUntil: 'domcontentloaded', timeout: 30000 }); await sleep(3500);
    const noticeText = 'Confirm your PIN to check delivery and AI status';
    const ticks = () => page.evaluate(() => document.querySelectorAll('[data-onboarding-wizard] svg.lucide-check').length);
    out.onb.before = { notice: await page.getByText(noticeText).count(), f403: f403.slice(), ticks: await ticks(), heads: await page.evaluate(() => [...document.querySelectorAll('h1,h2')].map((e) => e.innerText.trim().slice(0, 60)).slice(0, 4)) };
    if (out.onb.before.notice > 0) {
      f403.length = 0;
      await page.getByLabel('Enter your PIN').fill(PIN);
      await page.getByRole('button', { name: 'Confirm', exact: true }).click({ timeout: 5000 });
      await sleep(3500);
      out.onb.after = { notice: await page.getByText(noticeText).count(), f403: f403.slice(), ticks: await ticks() };
    }
    page.off('response', on403);
    await page.screenshot({ path: 'out/shots/onboarding_after.jpg', type: 'jpeg', quality: 45, timeout: 15000 });
  } catch (e) { out.onb.error = String(e).slice(0, 200); }
  out.ok = true; out.count = n;
  await browser.close();
} catch (e) { out.error = String(e).slice(0, 600); }
fs.writeFileSync('out/walk-full.json', JSON.stringify(out));
console.log('walk-full', out.ok ? 'ok' : 'fail', 'visits', out.visits.length);
