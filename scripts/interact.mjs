// Interaction walk. Presses buttons and types through the main seller flows (F1..F8) and records every step.
// usage:  node interact.mjs <cdpPort>              attach to the installed app over the debug port (lab, Windows)
//         node interact.mjs --local http://localhost:3917   launch a browser against a local server
// output: $OUT (default out/interact.json). Each step: flow, name, ok, ms, err, console errors, apiErrors (/api >= 400 with body), non-GET api calls, toast/dialog text.
// Lab mode `interact`: every step has its own try/catch and a 20 s limit (setup/login/demo longer); the whole script stops after 8 minutes.
import { chromium } from 'playwright-core';
import fs from 'node:fs';
import path from 'node:path';

const LOCAL = process.argv[2] === '--local';
const ARG = process.argv[3] || process.argv[2] || '9222';
const PIN = '24681357';
const OUT = process.env.OUT || 'out/interact.json';
const STEP_MS = +(process.env.STEP_MS || (LOCAL ? 90000 : 20000));
const T_START = Date.now(); const TOTAL_MS = +(process.env.TOTAL_MS || 8 * 60 * 1000);
const overTime = () => Date.now() - T_START > TOTAL_MS;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const R = { mode: LOCAL ? 'local' : 'cdp', started: new Date().toISOString(), steps: [], flows: {}, consoleErrors: [], pageErrors: [], notes: {}, focus: null, dup: {}, findings: [] };
fs.mkdirSync(path.dirname(OUT), { recursive: true });
const save = () => { R.updated = new Date().toISOString(); fs.writeFileSync(OUT, JSON.stringify(R, null, 1)); };

let browser, ctx, page, origin;
let buf = null; // collects events during a step
const seenConsole = new Set();
const noise = (t) => /_next\/hmr|webpack-hmr|\[Fast Refresh\]|React DevTools/.test(t);
function attach(p) {
  p.on('console', (m) => { if (m.type() !== 'error') return; const t = m.text().slice(0, 240); if (noise(t)) return; if (buf) buf.console.push(t); const k = t.slice(0, 120) + '|' + new URL(p.url() || 'about:blank', 'http://x').pathname; if (!seenConsole.has(k)) { seenConsole.add(k); R.consoleErrors.push({ page: new URL(p.url() || 'about:blank', 'http://x').pathname, text: t, step: buf ? buf.flow + ':' + buf.name : null }); } });
  p.on('pageerror', (e) => { const t = String(e && e.message ? e.message : e).slice(0, 240); if (noise(t)) return; if (buf) buf.pageerrors.push(t); const k = 'pe|' + t.slice(0, 120); if (!seenConsole.has(k)) { seenConsole.add(k); R.pageErrors.push({ page: new URL(p.url() || 'about:blank', 'http://x').pathname, text: t, step: buf ? buf.flow + ':' + buf.name : null }); } });
  p.on('response', (r) => {
    const u = r.url(); if (!/\/api\//.test(u) || !buf) return;
    const m = r.request().method(), st = r.status(), url = u.replace(/^https?:\/\/[^/]+/, '').slice(0, 110);
    if (m !== 'GET' && buf.apiCalls.length < 20) buf.apiCalls.push({ m, url, status: st });
    if (st >= 400) { const h = { m, url, status: st, body: '' }; buf.apiErrors.push(h); buf.pend.push(r.text().then((t) => { h.body = t.slice(0, 200); }).catch(() => {})); }
  });
  p.on('requestfailed', (r) => { const u = r.url().replace(/^https?:\/\/[^/]+/, ''); if (!buf || /runtime-ui-ready|_next\/hmr/.test(u)) return; if (buf.failed.length < 6) buf.failed.push({ url: u.slice(0, 100), err: (r.failure() || {}).errorText }); });
}
const INIT = () => {
  if (window.__sfObs) return; window.__sfObs = true; window.__sfSeen = [];
  const sel = '[data-sonner-toast],[role=status],[role=alert],[role=alertdialog],[role=dialog]';
  const kind = (e) => (e.matches('[data-sonner-toast]') ? 'toast' : e.matches('[role=alert]') ? 'alert' : e.matches('[role=status]') ? 'status' : 'dialog');
  const push = (e) => { try { const t = (e.innerText || '').trim().replace(/\s+/g, ' '); if (t && window.__sfSeen.length < 60) window.__sfSeen.push({ k: kind(e), t: t.slice(0, 200) }); } catch {} };
  new MutationObserver((ms) => { for (const m of ms) for (const n of m.addedNodes) { if (n.nodeType !== 1) continue; if (n.matches && n.matches(sel)) { push(n); setTimeout(() => push(n), 400); } if (n.querySelectorAll) n.querySelectorAll(sel).forEach((x) => { push(x); setTimeout(() => push(x), 400); }); } }).observe(document, { childList: true, subtree: true });
};

async function dumpControls() {
  return page.evaluate(() => {
    const vis = (e) => { const r = e.getBoundingClientRect(); const cs = getComputedStyle(e); return r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none'; };
    const nm = (e) => (e.getAttribute('aria-label') || e.innerText || e.getAttribute('placeholder') || e.getAttribute('name') || e.getAttribute('title') || '').trim().replace(/\s+/g, ' ').slice(0, 36);
    const dlg = [...document.querySelectorAll('[role=dialog],[role=alertdialog]')].filter(vis).pop();
    const root = dlg || document.querySelector('main') || document.body;
    return { url: location.pathname, dialog: !!dlg, text: (root.innerText || '').trim().replace(/\s+/g, ' ').slice(0, 220),
      controls: [...root.querySelectorAll('button,[role=button],[role=combobox],[role=tab],[role=menuitem],[role=option],input,select,textarea,a[role=button]')].filter(vis).map((e) => (e.getAttribute('role') || e.tagName.toLowerCase()) + ':' + nm(e)).slice(0, 28) };
  });
}
async function toasts() { try { return await page.evaluate(() => { const a = window.__sfSeen || []; window.__sfSeen = []; const live = [...document.querySelectorAll('[data-sonner-toast]')].map((e) => ({ k: 'toast', t: (e.innerText || '').trim().replace(/\s+/g, ' ').slice(0, 200) })); return a.concat(live); }); } catch { return []; } }
let shots = 0;

async function step(flow, name, fn, opt = {}) {
  const s = { flow, name, ok: false, ms: 0, err: null, console: [], pageerrors: [], failed: [], apiErrors: [], apiCalls: [], pend: [], toasts: [], alerts: [], dialog: null };
  const lim = opt.timeout || STEP_MS;
  if (overTime() && !opt.force) { s.err = 'skipped: script time limit reached'; s.skipped = true; delete s.pend; (R.flows[flow] ||= { steps: 0, ok: 0, fail: 0 }); R.flows[flow].steps++; R.flows[flow].fail++; R.steps.push(s); save(); console.log(`SKIP ${flow} ${name}`); return false; }
  buf = s; const t0 = Date.now(); let timer;
  try {
    await Promise.race([fn(s), new Promise((_, rej) => { timer = setTimeout(() => rej(new Error('step timeout ' + lim + ' ms')), lim); })]);
    s.ok = true;
  } catch (e) {
    s.err = String(e && e.message ? e.message : e).split('\n')[0].slice(0, 260);
    try { s.dom = await Promise.race([dumpControls(), sleep(4000).then(() => null)]); } catch {}
  }
  clearTimeout(timer);
  s.ms = Date.now() - t0;
  await sleep(300);
  const seen = await toasts();
  s.toasts = [...new Set(seen.filter((x) => x.k === 'toast').map((x) => x.t))].slice(0, 6);
  s.alerts = [...new Set(seen.filter((x) => x.k === 'alert' || x.k === 'status').map((x) => x.t))].filter((t) => !/^loading$|verifying license/i.test(t)).slice(0, 6);
  s.dialogSeen = [...new Set(seen.filter((x) => x.k === 'dialog').map((x) => x.t))].slice(0, 2).map((t) => t.slice(0, 160));
  try { s.dialog = await Promise.race([page.evaluate(() => { const d = [...document.querySelectorAll('[role=dialog],[role=alertdialog]')].filter((e) => e.getBoundingClientRect().width > 0).pop(); return d ? d.innerText.trim().replace(/\s+/g, ' ').slice(0, 160) : null; }), sleep(3000).then(() => null)]); } catch {}
  try { await Promise.race([Promise.allSettled(s.pend), sleep(2500)]); } catch {}
  delete s.pend; buf = null;
  if (!s.ok && !LOCAL && shots < 12) { shots++; const f = `out/shots/interact_${String(shots).padStart(2, '0')}.jpg`; try { fs.mkdirSync('out/shots', { recursive: true }); await page.screenshot({ path: f, type: 'jpeg', quality: 40, timeout: 8000 }); s.shot = f; } catch {} }
  (R.flows[flow] ||= { steps: 0, ok: 0, fail: 0 }); R.flows[flow].steps++; R.flows[flow][s.ok ? 'ok' : 'fail']++;
  R.steps.push(s); save();
  console.log(`${s.ok ? 'ok  ' : 'FAIL'} ${flow} ${name} ${s.ms}ms${s.err ? ' :: ' + s.err : ''}${s.apiErrors.length ? ' api=' + JSON.stringify(s.apiErrors.map((h) => h.status + ' ' + h.url)) : ''}${s.console.length ? ' console=' + s.console.length : ''}`);
  return s.ok;
}
const expect = (c, msg) => { if (!c) throw new Error('expected: ' + msg); };

async function hydrated(ms = 25000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    const ok = await page.evaluate(() => { const b = document.querySelector('button'); return !!b && Object.keys(b).some((k) => k.startsWith('__reactProps')); }).catch(() => false);
    if (ok) return true; await sleep(300);
  }
  return false;
}
async function go(p, wait = 'domcontentloaded') {
  await page.goto(origin + p, { waitUntil: wait, timeout: LOCAL ? 120000 : 18000 });
  await page.evaluate(INIT).catch(() => {}); await hydrated(); await sleep(500);
}
const dlg = () => page.locator('[role=dialog],[role=alertdialog]').last();
async function fillLabel(root, re, value, fallbackPh) {
  let l = root.getByLabel(re).first();
  if (!(await l.count()) && fallbackPh) l = root.getByPlaceholder(fallbackPh).first();
  await l.fill(String(value), { timeout: 8000 });
}
async function apiJson(p, m = 'GET', body) {
  return page.evaluate(async ([p, m, body]) => { try { const h = { 'x-requested-with': 'sahelflow' }; if (body) h['content-type'] = 'application/json'; const r = await fetch(p, { method: m, headers: h, body: body ? JSON.stringify(body) : undefined }); const t = await r.text(); let j = null; try { j = JSON.parse(t); } catch {} return { s: r.status, j, head: t.slice(0, 160) }; } catch (e) { return { s: -1, head: String(e).slice(0, 100) }; } }, [p, m, body]);
}
// all objects in a JSON tree that look like records (have id) and whose name-ish field contains needle
function findRecords(j, needle) {
  const out = []; const seen = new Set();
  const walk = (x) => { if (!x || typeof x !== 'object' || seen.has(x)) return; seen.add(x); if (Array.isArray(x)) { x.forEach(walk); return; }
    if (typeof x.id === 'string' && [x.name, x.fullName, x.productName, x.title].some((v) => typeof v === 'string' && v.includes(needle))) out.push({ id: x.id, name: x.name || x.fullName || x.title, price: x.price, createdAt: x.createdAt });
    Object.values(x).forEach(walk); };
  walk(j); return out;
}
const rowOf = (text) => page.locator('tr, [role=row]').filter({ hasText: text }).first();
const rowsOf = (text) => page.locator('tr, [role=row]').filter({ hasText: text });

// ---------------------------------------------------------------- session (reuses the lab gates: setup PIN, login, trial, demo data)
async function session() {
  if (LOCAL) {
    browser = await chromium.launch({ executablePath: '/opt/agent-sandbox/tools/playwright-browsers/chromium-1228/chrome-linux64/chrome', headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
    ctx = await browser.newContext({ viewport: { width: 1366, height: 768 }, locale: 'en-US' });
    page = await ctx.newPage(); origin = ARG === '--local' ? process.argv[3] : ARG;
  } else {
    browser = await chromium.connectOverCDP(`http://127.0.0.1:${ARG}`, { timeout: 30000 });
    ctx = browser.contexts()[0];
    for (let i = 0; i < 40; i++) { page = ctx.pages().find((q) => /^https?:\/\/(127\.0\.0\.1|localhost)/.test(q.url())); if (page) break; await sleep(1000); }
    R.notes.pages = ctx.pages().map((q) => q.url().replace(/:\d+/, ':PORT').slice(0, 80));
    page = page || ctx.pages()[0];
    await page.setViewportSize({ width: 1366, height: 768 });
    await page.waitForLoadState('domcontentloaded', { timeout: 30000 }).catch(() => {});
    origin = new URL(page.url()).origin;
  }
  page.setDefaultTimeout(LOCAL ? 60000 : 20000);
  await ctx.addInitScript(INIT); await page.evaluate(INIT).catch(() => {});
  attach(page);
  R.notes.ua = await page.evaluate(() => navigator.userAgent).catch(() => null);
  R.origin = origin.replace(/:\d+$/, ':PORT');
  if (LOCAL) await page.goto(origin + '/setup', { waitUntil: 'domcontentloaded', timeout: 120000 });
  await sleep(1500); await hydrated();
  let p = new URL(page.url()).pathname; R.notes.startPath = p;
  if (p.startsWith('/setup')) {
    await step('G', 'setup: create owner PIN', async () => {
      const btn = page.getByRole('button', { name: /get started|commencer|ابدأ/i });
      for (let i = 0; i < 25; i++) { if (!page.url().includes('/setup')) { R.notes.setupSkipped = 'page left /setup before the PIN was typed (PIN already set in this data folder)'; return; } const pins = page.locator('input[inputmode=numeric]'); await pins.nth(0).fill(PIN); await pins.nth(1).fill(PIN); await sleep(600); if (await btn.isEnabled()) break; await sleep(1500); }
      if (!page.url().includes('/setup')) return;
      await btn.click({ timeout: 8000 });
      await page.waitForURL((u) => new URL(u).pathname !== '/setup', { timeout: 150000 });
    }, { timeout: 200000, force: true });
    await sleep(1500);
  }
  p = new URL(page.url()).pathname;
  if (p.startsWith('/login')) {
    await step('G', 'login with PIN', async () => {
      await page.locator('input[inputmode=numeric]').first().fill(PIN);
      await page.getByRole('button', { name: /unlock|déverrouiller|فتح/i }).click({ timeout: 8000 });
      await page.waitForURL((u) => !new URL(u).pathname.startsWith('/login'), { timeout: 90000 });
    }, { timeout: 120000, force: true });
    await sleep(2000);
  }
  await step('G', 'trial license + demo data', async () => {
    const a = await apiJson('/api/license/trial', 'POST'); R.notes.trial = { s: a.s, head: a.head.slice(0, 100) };
    const d = await apiJson('/api/demo-data', 'POST'); R.notes.demo = { s: d.s, head: d.head.slice(0, 100) };
    expect(d.s < 300 || d.s === 409, 'demo-data ' + d.s);
  }, { timeout: 150000, force: true });
}

// ---------------------------------------------------------------- F1 products
async function F1() {
  const NAME = 'Walk test shirt';
  await step('F1', 'open /products', async () => { await go('/products'); await page.getByRole('heading', { name: /^products$/i }).waitFor(); expect(await page.getByRole('button', { name: /^edit$/i }).count() > 0, 'product rows with Edit buttons'); });
  await step('F1', 'create product (name, price 2500)', async () => {
    await page.getByRole('button', { name: /add product/i }).first().click();
    const d = dlg(); await d.waitFor();
    await fillLabel(d, /product name|name/i, NAME, 'T-shirt Cotton Bio');
    await fillLabel(d, /^price/i, 2500, '1500');
    await d.getByRole('button', { name: /^save$/i }).click();
    await d.waitFor({ state: 'hidden', timeout: 30000 });
  });
  await step('F1', 'new product is in the list', async () => {
    const sb = page.getByPlaceholder(/search products/i); await sb.fill('Walk test'); await sleep(1200);
    await rowOf(NAME).waitFor({ timeout: 15000 });
    const j = await apiJson('/api/products?limit=200&search=Walk'); R.notes.productsApiAfterCreate = { s: j.s, found: findRecords(j.j, NAME).length };
  });
  await step('F1', 'edit price to 2700', async () => {
    await rowOf(NAME).getByRole('button', { name: /^edit$/i }).click();
    const d = dlg(); await d.waitFor();
    await fillLabel(d, /^price/i, 2700, '1500');
    await d.getByRole('button', { name: /save changes|^save$/i }).click();
    await d.waitFor({ state: 'hidden', timeout: 30000 });
    await sleep(1000);
    const t = await rowOf(NAME).innerText(); expect(/2[\s.,\u202f\u00a0]?700/.test(t), 'row shows 2700, got: ' + t.replace(/\s+/g, ' ').slice(0, 80));
  });
  await step('F1', 'delete with confirm dialog', async () => {
    await rowOf(NAME).getByRole('button', { name: /^delete$/i }).click();
    const d = dlg(); await d.waitFor();
    await d.getByRole('button', { name: /delete|confirm|yes|remove/i }).last().click();
    await d.waitFor({ state: 'hidden', timeout: 30000 });
  });
  await step('F1', 'product is gone', async () => {
    await sleep(1000); await page.reload({ waitUntil: 'domcontentloaded' }); await hydrated();
    await page.getByPlaceholder(/search products/i).fill('Walk test'); await sleep(1500);
    expect(await rowsOf(NAME).count() === 0, 'no row left for ' + NAME);
    const j = await apiJson('/api/products?limit=200&search=Walk'); expect(findRecords(j.j, NAME).length === 0, 'API still lists it');
  });
}

// ---------------------------------------------------------------- F2 customers
const PHONE = '0555' + String(Math.floor(100000 + Math.random() * 899999));
const CNAME = 'Walk Tester ' + PHONE.slice(-4);
async function F2() {
  await step('F2', 'open /customers', async () => { await go('/customers'); await page.getByRole('heading', { name: /^customers$/i }).waitFor(); });
  await step('F2', 'create customer with phone', async () => {
    await page.getByRole('button', { name: /new customer/i }).first().click();
    const d = dlg(); await d.waitFor();
    await fillLabel(d, /^name/i, CNAME, 'Ahmed Benali');
    await d.getByPlaceholder(/05|0X|55/).first().fill(PHONE).catch(async () => { await d.getByLabel(/phone/i).first().fill(PHONE); });
    await d.getByRole('button', { name: /^save$/i }).click();
    await d.waitFor({ state: 'hidden', timeout: 30000 });
  });
  await step('F2', 'find it with the search box', async () => {
    const sb = page.getByPlaceholder(/search by name or phone/i); await sb.fill(PHONE.slice(-6)); await sleep(1500);
    await rowOf(CNAME).waitFor({ timeout: 15000 });
  });
  await step('F2', 'open its detail page', async () => {
    const r = rowOf(CNAME);
    const link = r.locator('a[href^="/customers/"]').first();
    if (await link.count()) await link.click(); else await r.getByRole('button', { name: /^view/i }).first().click();
    await page.waitForURL((u) => /^\/customers\/[^/]+/.test(new URL(u).pathname), { timeout: 30000 });
    await hydrated(); await page.getByText(CNAME).first().waitFor({ timeout: 15000 });
  });
}

// ---------------------------------------------------------------- A: orders, Confirm on pending orders (defect A: too little stock)
const statusText = async () => page.evaluate(() => { const main = document.querySelector('main') || document.body; const m = (main.innerText || '').match(/\b(Pending|Confirmed|Shipped|Delivered|Returned|Cancelled|Refused)\b/g); return m ? m.slice(0, 4).join('|') : ''; });
const orderApiStatus = async (id) => { const r = await apiJson('/api/orders/' + id); const j = r.j || {}; return String(j.status || (j.order && j.order.status) || (j.data && j.data.status) || '').toLowerCase(); };
const totalOf = (j) => j && (j.total ?? (j.pagination && j.pagination.total) ?? (j.meta && j.meta.total));
async function FA() {
  let confirmed = null; const tried = new Set();
  await step('A', 'open /orders (list with demo orders)', async () => { await go('/orders'); await page.getByRole('heading', { name: /^orders$/i }).waitFor(); expect(await page.locator('a[href^="/orders/demo-order"]').count() > 0, 'demo order links'); });
  const tryConfirm = async (id, s) => {
    tried.add(id);
    await go('/orders/' + id); await sleep(700); await toasts();
    const before = await orderApiStatus(id); const uiBefore = await statusText();
    s.state = { id, apiStatusBefore: before, uiStatusBefore: uiBefore };
    expect(before === 'pending', 'order is pending (API says ' + before + ')');
    const btn = page.getByRole('button', { name: /^confirm$/i }).first();
    expect(await btn.count() > 0, 'a Confirm button on the order page');
    await btn.click({ timeout: 8000 }); await sleep(500);
    const d = page.locator('[role=dialog],[role=alertdialog]').filter({ visible: true }).last();
    if (await d.count()) { s.state.dialogAfterConfirm = (await d.innerText().catch(() => '')).replace(/\s+/g, ' ').slice(0, 140); const b = d.getByRole('button', { name: /confirm|yes|continue|save|apply|mark/i }).last(); if (await b.count()) await b.click().catch(() => {}); }
    await sleep(2500);
    const after = await orderApiStatus(id); s.state.apiStatusAfter = after;
    expect(after === 'confirmed', 'Confirm did not confirm: API status ' + before + ' -> ' + after);
    confirmed = id;
  };
  for (const id of ['demo-order-025', 'demo-order-023']) await step('A', 'press Confirm on ' + id, (s) => tryConfirm(id, s));
  // control: the first other pending orders (stop at the first one that confirms)
  await step('A', 'control: Confirm on another pending order', async (s) => {
    await go('/orders?status=pending'); await sleep(800);
    const hrefs = await page.locator('a[href^="/orders/"]:not([href*="confirmation"]):not([href*="?"])').evaluateAll((els) => els.map((e) => e.getAttribute('href')));
    const ids = [...new Set(hrefs.map((h) => h.split('/').pop()))].filter((i) => !tried.has(i)).slice(0, 3);
    s.state = { candidates: ids, results: [] };
    for (const id of ids) {
      const fake = {};
      try { await tryConfirm(id, fake); s.state.results.push(Object.assign({ ok: true }, fake.state)); break; }
      catch (e) { s.state.results.push(Object.assign({ id, ok: false, err: String(e.message).slice(0, 140) }, fake.state)); }
    }
    expect(confirmed && !['demo-order-025', 'demo-order-023'].includes(confirmed), 'one other pending order confirmed; tried ' + JSON.stringify(s.state.results.map((r) => r.id + ':' + r.ok)));
  }, { timeout: 40000 });
  await step('A', 'status badge menu offers actions', async (s) => {
    expect(confirmed, 'a confirmed order from the steps above'); await go('/orders/' + confirmed);
    const b = page.getByRole('button', { name: /^(pending|confirmed)$/i }).first(); await b.click(); await sleep(600);
    const items = await page.locator('[role=menuitem],[role=option],[role=menuitemradio]').filter({ visible: true }).allInnerTexts(); s.state = { items: items.map((x) => x.replace(/\s+/g, ' ').slice(0, 40)) };
    await page.keyboard.press('Escape'); await sleep(300);
    expect(items.length > 0, 'menu items');
  });
  await step('A', 'badge menu: Confirmed -> Cancelled', async (s) => {
    expect(confirmed, 'a confirmed order'); await go('/orders/' + confirmed);
    await page.getByRole('button', { name: /^(pending|confirmed)$/i }).first().click(); await sleep(500);
    await page.getByRole('menuitem', { name: /cancel/i }).or(page.getByRole('option', { name: /cancel/i })).first().click({ timeout: 8000 }); await sleep(800);
    const d = page.locator('[role=dialog],[role=alertdialog]').filter({ visible: true }).last();
    if (await d.count()) { s.state = { confirmDialog: (await d.innerText()).replace(/\s+/g, ' ').slice(0, 140) }; const b = d.getByRole('button', { name: /confirm|yes|continue|cancel order|save|apply/i }).last(); await b.click().catch(() => {}); }
    await sleep(2000);
    const st = await orderApiStatus(confirmed); expect(st === 'cancelled', 'API status cancelled, got ' + st);
  });
}

// ---------------------------------------------------------------- B: New order with the EXISTING customer Reda Mokrani (defect B: commune stays blank)
async function FB() {
  const dstate = async () => page.evaluate(() => {
    const vis = (e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
    const d = [...document.querySelectorAll('[role=dialog]')].filter(vis).pop(); if (!d) return null;
    const txt = (d.innerText || '').replace(/\s+/g, ' ');
    const i = txt.search(/Delivery/);
    return { delivery: txt.slice(Math.max(0, i), Math.max(0, i) + 260),
      combos: [...d.querySelectorAll('[role=combobox]')].map((e) => (e.getAttribute('aria-label') || e.innerText || e.getAttribute('placeholder') || '').trim().replace(/\s+/g, ' ').slice(0, 50)),
      selects: [...d.querySelectorAll('select')].map((e) => ({ v: e.value, shown: (e.options[e.selectedIndex] || {}).text })),
      errors: [...d.querySelectorAll('[role=alert],[aria-invalid=true],.text-destructive')].map((e) => (e.innerText || '').trim().replace(/\s+/g, ' ').slice(0, 100)).filter(Boolean),
      create: [...d.querySelectorAll('button')].filter((b) => /^create order$/i.test((b.innerText || '').trim())).map((b) => ({ disabled: b.disabled })) };
  });
  let totalBefore = null, madeInB2 = false;
  await step('B', 'New order: pick customer Reda Mokrani and a product; commune is filled', async (s) => {
    await go('/orders'); totalBefore = totalOf((await apiJson('/api/orders?limit=1')).j); await toasts();
    await page.getByRole('button', { name: /new order/i }).first().click();
    const d = dlg(); await d.waitFor({ timeout: 10000 });
    await d.getByRole('combobox', { name: /select a customer/i }).or(d.getByRole('combobox').first()).first().click(); await sleep(700);
    const custOpt = (await page.getByRole('option').filter({ hasText: /Mokrani/ }).first().innerText().catch(() => '')).replace(/\s+/g, ' ').slice(0, 80);
    await page.getByRole('option').filter({ hasText: /Mokrani/ }).first().click({ timeout: 8000 }); await sleep(1000);
    await d.getByRole('combobox', { name: /add a product/i }).or(d.getByRole('combobox').nth(1)).first().click(); await sleep(700);
    await page.getByRole('option').first().click({ timeout: 8000 }); await sleep(900);
    const st = await dstate(); const wil = (st.combos || []).find((c) => /^\d{1,2}\s*[-\u2014\u2013]/.test(c)) || null;
    const blank = (st.combos || []).filter((c) => /^select\.\.\.$/i.test(c));
    s.state = { totalBefore, customerOption: custOpt, wilayaField: wil, communeSelectText: blank.length ? blank[0] : null, blankSelects: blank.length, combos: st.combos, selects: st.selects, delivery: st.delivery };
    expect(wil, 'Wilaya field filled by the customer pick');
    expect(blank.length === 0, 'Commune field filled (it shows ' + JSON.stringify(blank) + ')');
  });
  await step('B', 'press Create order with the prefilled commune', async (s) => {
    const d = dlg(); await d.waitFor({ timeout: 5000 });
    await d.getByRole('button', { name: /^create order$/i }).click({ timeout: 8000 }); await sleep(2500);
    const open = await d.isVisible().catch(() => false); const st = open ? await dstate() : null;
    s.state = { dialogStillOpen: open, errors: st && st.errors, alerts: st && st.errors };
    if (!open) madeInB2 = true;
    expect(!open, 'dialog closed after Create (still open; errors: ' + JSON.stringify(st && st.errors) + ')');
  });
  await step('B', 'control: choose a commune by hand, then Create order', async (s) => {
    const d = dlg();
    if (!(await d.isVisible().catch(() => false))) { s.state = { note: madeInB2 ? 'order already created in the previous step' : 'dialog was closed' }; expect(madeInB2, 'the New order dialog was closed without an order'); return; }
    const com = d.locator('[role=combobox]').filter({ hasText: /^\s*Select\.\.\.\s*$/ }).first(); expect(await com.count() > 0, 'a blank Commune select');
    await com.click(); await sleep(600);
    const opts = await page.getByRole('option').allInnerTexts(); s.state = { communeOptions: opts.length, first: (opts[0] || '').slice(0, 30), spellingsOfMsila: opts.filter((o) => /m.sila/i.test(o)).map((o) => o.trim()) };
    await page.getByRole('option').first().click({ timeout: 6000 }); await sleep(600);
    await d.getByRole('button', { name: /^create order$/i }).click({ timeout: 8000 }); await sleep(2500);
    const risk = page.locator('[role=alertdialog]').filter({ visible: true }); if (await risk.count()) { s.state.riskDialog = (await risk.last().innerText()).replace(/\s+/g, ' ').slice(0, 160); await risk.last().getByRole('button').last().click().catch(() => {}); await sleep(2000); }
    await d.waitFor({ state: 'hidden', timeout: 10000 });
  });
  await step('B', 'orders total went up by one', async (s) => {
    await sleep(500); const after = totalOf((await apiJson('/api/orders?limit=1')).j); s.state = { totalBefore, after };
    expect(totalBefore != null && after === totalBefore + 1, 'order total +1: ' + totalBefore + ' -> ' + after);
  });
  try { await page.keyboard.press('Escape'); } catch {}
}

// ---------------------------------------------------------------- F4 appearance
async function F4() {
  const html = () => page.evaluate(() => ({ lang: document.documentElement.lang, dir: document.documentElement.dir, dark: document.documentElement.classList.contains('dark'), preset: document.documentElement.dataset.themePreset || null, mode: document.documentElement.dataset.colorMode || null }));
  const closeSettings = async () => { await page.keyboard.press('Escape'); await sleep(700); if (await dlg().isVisible().catch(() => false)) await page.getByRole('button', { name: /^close$/i }).first().click().catch(() => {}); await sleep(500); };
  const langBtn = () => page.getByRole('button', { name: /^(English|Français|العربية)$/ }).first();
  const pickLang = async (label) => { await langBtn().click(); await sleep(400); await page.getByRole('menuitem', { name: label }).or(page.getByRole('option', { name: label })).or(page.getByRole('radio', { name: label })).first().click({ timeout: 8000 }); await sleep(1500); };
  const openAppearance = async () => { await go('/settings'); await page.getByRole('button', { name: /^appearance$/i }).first().click(); await page.locator('[data-theme-preset-option]').first().waitFor({ timeout: 15000 }); };
  await step('F4', 'open settings > Appearance', openAppearance);
  for (const p of ['atlas', 'oasis', 'dune', 'sahel']) {
    await step('F4', 'look: ' + p, async (s) => {
      await page.locator(`[data-theme-preset-option="${p}"]`).first().click(); await sleep(700);
      const h = await html(); s.state = h; expect(h.preset === p, `data-theme-preset=${p}, got ${h.preset}`);
    });
  }
  for (const m of ['dark', 'light']) {
    await step('F4', 'theme: ' + m, async (s) => {
      await page.locator(`[data-theme-mode="${m}"]`).first().click(); await sleep(700);
      const h = await html(); s.state = h; expect(h.dark === (m === 'dark'), `dark class ${m === 'dark'}, got ${h.dark}`);
    });
  }
  await step('F4', 'set Dune + dark, close settings', async (s) => {
    await page.locator('[data-theme-preset-option="dune"]').first().click(); await sleep(400);
    await page.locator('[data-theme-mode="dark"]').first().click(); await sleep(600); await closeSettings();
    const h = await html(); s.state = h; expect(h.preset === 'dune' && h.dark, JSON.stringify(h));
  });
  await step('F4', 'topbar theme button toggles dark', async (s) => {
    const before = (await html()).dark; await page.getByRole('button', { name: /switch to (light|dark) theme/i }).first().click(); await sleep(700);
    const mid = await html(); await page.getByRole('button', { name: /switch to (light|dark) theme/i }).first().click(); await sleep(700);
    const end = await html(); s.state = { before, mid: mid.dark, end: end.dark }; expect(mid.dark !== before && end.dark === before, JSON.stringify(s.state));
  });
  for (const [code, label, dirx] of [['fr', /fran/i, 'ltr'], ['ar', /عرب/i, 'rtl']]) {
    await step('F4', 'language: ' + code, async (s) => {
      await pickLang(label); const h = await html(); s.state = h; expect(h.lang === code && h.dir === dirx, `html lang=${code} dir=${dirx}, got lang=${h.lang} dir=${h.dir}`);
    });
  }
  await step('F4', 'choices persist after reload (Dune, dark, Arabic)', async (s) => {
    const before = await html(); await page.reload({ waitUntil: 'domcontentloaded' }); await hydrated(); await sleep(800);
    const after = await html(); s.state = { before, after };
    expect(before.preset === 'dune' && before.dark && before.lang === 'ar', 'set before reload ' + JSON.stringify(before));
    expect(after.preset === before.preset && after.dark === before.dark && after.lang === before.lang && after.dir === before.dir, 'same after reload: ' + JSON.stringify(after));
  });
  await step('F4', 'persist across a new page (navigate to /orders)', async (s) => {
    await go('/orders'); const h = await html(); s.state = h; expect(h.preset === 'dune' && h.dark && h.lang === 'ar' && h.dir === 'rtl', JSON.stringify(h));
  });
  await step('F4', 'restore English / light / Sahel', async (s) => {
    await pickLang(/english/i); await openAppearance();
    await page.locator('[data-theme-mode="light"]').first().click(); await sleep(400);
    await page.locator('[data-theme-preset-option="sahel"]').first().click(); await sleep(500); await closeSettings();
    const h = await html(); s.state = h; expect(h.lang === 'en' && !h.dark && h.preset === 'sahel', JSON.stringify(h));
  });
}

// ---------------------------------------------------------------- F5 keyboard
async function F5() {
  await step('F5', 'Tab x30 on /dashboard', async (s) => {
    await go('/dashboard'); await sleep(1500);
    await page.evaluate(() => { document.activeElement && document.activeElement.blur && document.activeElement.blur(); window.scrollTo(0, 0); });
    const stops = []; let same = 0, last = null, traps = [];
    for (let i = 1; i <= 30; i++) {
      await page.keyboard.press('Tab'); await sleep(140);
      const st = await page.evaluate((i) => {
        const e = document.activeElement; if (!e || e === document.body) return { i, tag: 'body', name: '', ind: false, id: 0 };
        (window.__sfStops ||= {})[i] = e; e.__sfid ||= ++window.__sfn || (window.__sfn = 1); const cs = getComputedStyle(e);
        const outline = cs.outlineStyle !== 'none' && parseFloat(cs.outlineWidth) > 0 && cs.outlineColor !== 'rgba(0, 0, 0, 0)';
        const shadow = cs.boxShadow !== 'none' && !/^rgba\(0, 0, 0, 0\)/.test(cs.boxShadow);
        const lab = e.getAttribute('aria-label') || (e.getAttribute('aria-labelledby') && document.getElementById(e.getAttribute('aria-labelledby'))?.innerText) || e.innerText || e.getAttribute('title') || e.getAttribute('placeholder') || e.querySelector('img[alt]')?.getAttribute('alt') || '';
        let wrap = false; for (let a = e.parentElement, n = 0; a && n < 4; a = a.parentElement, n++) { const c = getComputedStyle(a); if ((c.boxShadow !== 'none' && !/^rgba\(0, 0, 0, 0\)/.test(c.boxShadow)) || (c.outlineStyle !== 'none' && parseFloat(c.outlineWidth) > 0)) { wrap = true; break; } }
        const r = e.getBoundingClientRect();
        return { wrap, i, tag: e.tagName.toLowerCase(), role: e.getAttribute('role'), name: lab.trim().replace(/\s+/g, ' ').slice(0, 40), href: e.getAttribute('href'), fv: e.matches(':focus-visible'), outline, shadow, outlineCss: cs.outlineStyle + ' ' + cs.outlineWidth + ' ' + cs.outlineColor + ' off ' + cs.outlineOffset, shadowCss: cs.boxShadow.slice(0, 90), ind: outline || shadow, id: e.__sfid, inView: r.bottom > 0 && r.top < innerHeight };
      }, i);
      stops.push(st);
      if (last !== null && st.id === last) same++; else same = 0; last = st.id;
      if (same >= 2) traps.push({ at: i, name: st.name, tag: st.tag });
    }
    for (const x of stops.filter((q) => !q.ind)) {
      x.styleChange = await page.evaluate((i) => { const e = window.__sfStops[i]; const sig = (n) => { const c = getComputedStyle(n); return [c.borderColor, c.backgroundColor, c.outlineColor, c.color, c.boxShadow].join('|'); };
        const nodes = [e]; for (let a = e.parentElement, n = 0; a && n < 3; a = a.parentElement, n++) nodes.push(a);
        e.blur(); const off = nodes.map(sig); e.focus({ focusVisible: true }); const on = nodes.map(sig); e.blur(); return on.some((v, k) => v !== off[k]); }, x.i);
    }
    R.focus = { stops: stops.length, noIndicator: stops.filter((x) => !x.ind).map((x) => ({ i: x.i, tag: x.tag, name: x.name, href: x.href, fv: x.fv, ancestorRing: x.wrap, borderOrColourChangesOnFocus: x.styleChange })), unnamed: stops.filter((x) => !x.name && x.tag !== 'body').map((x) => ({ i: x.i, tag: x.tag, href: x.href })), traps, bodyStops: stops.filter((x) => x.tag === 'body').length, distinct: new Set(stops.map((x) => x.id)).size, list: stops.map((x) => ({ i: x.i, tag: x.tag, name: x.name, fv: x.fv, ring: !!x.ind, outline: x.outlineCss, shadow: x.shadowCss, ancestorRing: x.wrap })), sample: stops.slice(0, 40).map((x) => `${x.i}:${x.tag}:${x.name}:${x.ind ? 'ring' : 'NONE'}`) };
    s.focus = { stops: stops.length, noIndicator: R.focus.noIndicator.length, traps: traps.length, distinct: R.focus.distinct };
    expect(traps.length === 0, 'keyboard trap: ' + JSON.stringify(traps));
    expect(R.focus.noIndicator.length === 0, R.focus.noIndicator.length + ' stops without ring/outline: ' + JSON.stringify(R.focus.noIndicator.map((x) => x.name + (x.borderOrColourChangesOnFocus ? ' (colour changes)' : ' (nothing changes)'))));
  });
  await step('F5', 'dialog by keyboard, Escape, focus returns', async (s) => {
    await go('/products');
    const opener = page.getByRole('button', { name: /add product/i }).first(); await opener.focus(); await sleep(200);
    await page.keyboard.press('Enter'); await dlg().waitFor({ timeout: 15000 }); await sleep(500);
    const inside = await page.evaluate(() => !!document.activeElement.closest('[role=dialog]'));
    await page.keyboard.press('Escape'); await dlg().waitFor({ state: 'hidden', timeout: 10000 }); await sleep(600);
    const back = await page.evaluate(() => { const e = document.activeElement; return { tag: e.tagName.toLowerCase(), name: (e.innerText || e.getAttribute('aria-label') || '').trim().slice(0, 30) }; });
    s.state = { focusInsideDialog: inside, afterEscape: back }; R.notes.dialogKeyboard = s.state;
    expect(inside, 'focus moved into the dialog'); expect(/add product/i.test(back.name), 'focus back on opener, got ' + JSON.stringify(back));
  });
}

// ---------------------------------------------------------------- F6 search
async function F6() {
  await step('F6', 'global search with "a"', async (s) => {
    await go('/dashboard');
    const box = page.getByRole('combobox', { name: /search/i }).first(); await box.click(); await box.fill('a'); await sleep(2500);
    const opts = await page.getByRole('option').allInnerTexts(); s.state = { options: opts.length, sample: opts.map((x) => x.replace(/\s+/g, ' ').slice(0, 50)) }; R.notes.search = s.state;
    expect(opts.length > 0, 'at least one result for "a"');
    await page.keyboard.press('ArrowDown'); await page.keyboard.press('Enter'); await sleep(2000);
    s.state.afterEnter = new URL(page.url()).pathname; expect(s.state.afterEnter !== '/dashboard', 'Enter opened a result, still on ' + s.state.afterEnter);
  });
}

// ---------------------------------------------------------------- F7 notifications and sign-out
async function F7() {
  await step('F7', 'open /notifications', async () => { await go('/notifications'); await page.getByRole('heading', { name: /^notifications$/i }).waitFor(); });
  await step('F7', 'mark one read', async (s) => {
    const tab = page.getByRole('button', { name: /^unread/i }).first(); const before = (await tab.innerText()).replace(/\s+/g, ' ');
    await page.getByRole('button', { name: /^mark as read$/i }).first().click(); await sleep(1500);
    const after = (await page.getByRole('button', { name: /^unread/i }).first().innerText()).replace(/\s+/g, ' '); s.state = { before, after };
    expect(before !== after, `Unread label changed ${before} -> ${after}`);
  });
  await step('F7', 'sign out', async () => {
    await page.getByRole('button', { name: /^user$/i }).first().click(); await sleep(500);
    await page.getByRole('menuitem', { name: /sign out|log out|logout|lock/i }).or(page.getByRole('button', { name: /sign out|log out|logout|lock/i })).first().click({ timeout: 8000 });
    await page.waitForURL((u) => new URL(u).pathname.startsWith('/login'), { timeout: 30000 });
  });
  await step('F7', 'sign in again with the PIN', async () => {
    await hydrated(); await sleep(500);
    const b = page.getByRole('button', { name: /unlock|déverrouiller|فتح/i });
    for (let i = 0; i < 10; i++) { await page.locator('input[inputmode=numeric]').first().fill(PIN); await sleep(300); if (await b.isEnabled()) break; await sleep(800); }
    await b.click(); await page.waitForURL((u) => !new URL(u).pathname.startsWith('/login'), { timeout: 60000 }); await hydrated();
  });
}

// ---------------------------------------------------------------- F8 double click on Save
async function F8() {
  const count = async (url, needle) => { const j = await apiJson(url); return findRecords(j.j, needle).length; };
  let pn = 'Walk dbl product ' + Date.now().toString().slice(-5);
  await step('F8', 'double-click Save on new product', async (s) => {
    await go('/products'); const before = await count('/api/products?limit=200&search=Walk', 'Walk dbl product');
    await page.getByRole('button', { name: /add product/i }).first().click(); const d = dlg(); await d.waitFor();
    await fillLabel(d, /product name|name/i, pn, 'T-shirt Cotton Bio'); await fillLabel(d, /^price/i, 1000, '1500');
    await d.getByRole('button', { name: /^save$/i }).dblclick({ delay: 0 }); await sleep(3500);
    const after = await count('/api/products?limit=200&search=Walk', pn); R.dup.product = { before, afterForThisName: after, newRecords: after }; s.state = R.dup.product;
    expect(after === 1, 'exactly 1 record created, got ' + after);
  });
  await step('F8', 'double-click Save on new customer', async (s) => {
    const nm = 'Walk dbl customer ' + Date.now().toString().slice(-5), ph = '0556' + String(Math.floor(100000 + Math.random() * 899999));
    await go('/customers'); await page.getByRole('button', { name: /new customer/i }).first().click(); const d = dlg(); await d.waitFor();
    await fillLabel(d, /^name/i, nm, 'Ahmed Benali'); await d.getByPlaceholder(/05|0X|55/).first().fill(ph);
    await d.getByRole('button', { name: /^save$/i }).dblclick({ delay: 0 }); await sleep(3500);
    const after = await count('/api/customers?limit=200&search=Walk', nm); R.dup.customer = { name: nm, afterForThisName: after }; s.state = R.dup.customer;
    expect(after === 1, 'exactly 1 record created, got ' + after);
  });
  await step('F8', 'cleanup walk records via API', async (s) => {
    for (const [u, needle, del] of [['/api/products?limit=200&search=Walk', 'Walk dbl product', '/api/products/'], ['/api/products?limit=200&search=Walk', 'Walk test shirt', '/api/products/']]) {
      const j = await apiJson(u); for (const r of findRecords(j.j, needle)) await apiJson(del + r.id, 'DELETE');
    }
  });
}

// ================= leadB additions: B2 commune pre-fill for several saved customers; V validation; X export; R returns/deliveries status menus; RTL Arabic form
async function clearDraftsLB() { return page.evaluate(() => { const gone = []; for (const st of [localStorage, sessionStorage]) for (const k of Object.keys(st)) if (/draft/i.test(k)) { gone.push(k); st.removeItem(k); } return gone; }).catch(() => []); }
async function closeDialogsLB() {
  for (let i = 0; i < 4; i++) {
    const ad = page.locator('[role=alertdialog]').filter({ visible: true });
    if (await ad.count()) { const b = ad.last().getByRole('button', { name: /discard|leave|yes|close|delete|don.t save|abandon/i }).first(); if (await b.count()) await b.click({ timeout: 3000 }).catch(() => {}); else await page.keyboard.press('Escape'); await sleep(500); continue; }
    const d = page.locator('[role=dialog]').filter({ visible: true });
    if (!(await d.count())) return;
    await page.keyboard.press('Escape'); await sleep(600);
  }
}
const msgsIn = (d) => d.evaluate((el) => [...el.querySelectorAll('[role=alert],[aria-invalid=true],.text-destructive,[data-slot=form-message]')].map((e) => (e.innerText || e.getAttribute('aria-label') || '').trim().replace(/\s+/g, ' ').slice(0, 100)).filter(Boolean)).catch(() => []);

async function FB2() {
  const names = ['Mokrani', 'Gacem', 'Slimani', 'Ziani', 'Bensa', 'Brahimi', 'Maouche', 'Benyahia'];
  for (const nm of names) {
    await step('B2', 'saved customer ' + nm + ': commune shown after the pick', async (s) => {
      await go('/orders'); s.drafts = await clearDraftsLB();
      await page.getByRole('button', { name: /new order/i }).first().click(); const d = dlg(); await d.waitFor({ timeout: 10000 });
      await d.getByRole('combobox').first().click(); await sleep(700);
      const opt = page.getByRole('option').filter({ hasText: new RegExp(nm) }).first();
      if (!(await opt.count())) { s.state = { note: 'no such customer in the list' }; await closeDialogsLB(); return; }
      const card = (await opt.innerText()).replace(/\s+/g, ' ').slice(0, 90);
      await opt.click({ timeout: 8000 });
      const t0 = Date.now(); let wil = null, com = null, ms = null, combos = [];
      for (let i = 0; i < 24; i++) {
        await sleep(250);
        combos = (await d.locator('[role=combobox]').allInnerTexts()).map((c) => c.trim().replace(/\s+/g, ' '));
        const wi = combos.findIndex((c) => /^\d{1,2}\s*[-\u2014\u2013]/.test(c));
        wil = wi >= 0 ? combos[wi] : null; com = wi >= 0 ? (combos[wi + 1] ?? null) : null;
        if (com && !/^select\.\.\.$/i.test(com)) { ms = Date.now() - t0; break; }
      }
      s.state = { card, wilaya: wil, commune: com, filledAfterMs: ms, combos: combos.slice(0, 6) };
      await closeDialogsLB();
      expect(ms !== null, 'commune filled within 6 s (card: ' + card + '; wilaya: ' + wil + '; commune: ' + com + ')');
    }, { timeout: 40000 });
  }
}

async function FV() {
  const tot = async (u) => totalOf((await apiJson(u)).j);
  const prodCase = (label, name, price) => step('V', label, async (s) => {
    await go('/products'); const before = await tot('/api/products?limit=1');
    await page.getByRole('button', { name: /add product/i }).first().click(); const d = dlg(); await d.waitFor({ timeout: 10000 });
    if (name !== null) await fillLabel(d, /product name|name/i, name, 'T-shirt Cotton Bio');
    if (price !== null) { const pl = d.getByLabel(/^price/i).first(); const f = (await pl.count()) ? pl : d.getByPlaceholder('1500').first(); await f.fill(String(price)).catch(() => {}); s.priceFieldValue = await f.inputValue().catch(() => null); }
    await d.getByRole('button', { name: /^save$/i }).click({ timeout: 8000 }); await sleep(2500);
    const open = await d.isVisible().catch(() => false); const msgs = open ? await msgsIn(d) : [];
    const after = await tot('/api/products?limit=1');
    s.state = { dialogStillOpen: open, messages: msgs, totalBefore: before, totalAfter: after };
    await closeDialogsLB();
    if (after !== before) { for (const r of findRecords((await apiJson('/api/products?limit=200&search=Walk V')).j, 'Walk V')) await apiJson('/api/products/' + r.id, 'DELETE'); }
    expect(after === before, 'nothing created (total ' + before + ' -> ' + after + ')');
    expect(open && msgs.length > 0, 'the form stays open and says why (open=' + open + ', messages=' + JSON.stringify(msgs) + ')');
  }, { timeout: 40000 });
  await prodCase('product with an empty name is refused with a message', null, 1000);
  await prodCase('product with price -5 is refused with a message', 'Walk V neg price', -5);
  await prodCase('product with price abc is refused with a message', 'Walk V abc price', 'abc');
  const custCase = (label, name, phone) => step('V', label, async (s) => {
    await go('/customers'); const before = await tot('/api/customers?limit=1');
    await page.getByRole('button', { name: /new customer/i }).first().click(); const d = dlg(); await d.waitFor({ timeout: 10000 });
    if (name !== null) await fillLabel(d, /^name/i, name, 'Ahmed Benali');
    await d.getByPlaceholder(/05|0X|55/).first().fill(phone);
    await d.getByRole('button', { name: /^save$/i }).click({ timeout: 8000 }); await sleep(2500);
    const open = await d.isVisible().catch(() => false); const msgs = open ? await msgsIn(d) : [];
    const after = await tot('/api/customers?limit=1');
    s.state = { dialogStillOpen: open, messages: msgs, totalBefore: before, totalAfter: after };
    await closeDialogsLB();
    if (after !== before) { for (const r of findRecords((await apiJson('/api/customers?limit=200&search=Walk V')).j, 'Walk V')) await apiJson('/api/customers/' + r.id, 'DELETE'); }
    expect(after === before, 'nothing created (total ' + before + ' -> ' + after + ')');
    expect(open && msgs.length > 0, 'the form stays open and says why (open=' + open + ', messages=' + JSON.stringify(msgs) + ')');
  }, { timeout: 40000 });
  await custCase('customer with phone 12345 is refused with a message', 'Walk V badphone', '12345');
  await custCase('customer with an empty name is refused with a message', null, '0555123456');
}

async function FX() {
  await step('X', 'open /import-export and press the first Export control', async (s) => {
    await go('/import-export'); await sleep(1000);
    const btns = (await page.getByRole('button').allInnerTexts()).map((b) => b.trim().replace(/\s+/g, ' ').slice(0, 40)).filter(Boolean).slice(0, 30);
    s.state = { buttons: btns };
    const b = page.getByRole('button', { name: /export|exporter|\u062a\u0635\u062f\u064a\u0631/i }).first(); expect((await b.count()) > 0, 'an Export button exists');
    await b.click({ timeout: 8000 }); await sleep(3500); s.state.clicked = true;
  }, { timeout: 40000 });
}

async function FR() {
  for (const [label, path] of [['returns', '/returns'], ['deliveries', '/deliveries']]) {
    await step('R', label + ': open the list and use a status menu', async (s) => {
      await go(path); await sleep(1500);
      const rows = await page.locator('tr, [role=row]').count();
      const trigs = page.locator('main button[aria-haspopup="menu"]').filter({ hasText: /\S/ });
      const n = await trigs.count(); s.state = { rows, triggers: n };
      expect(n > 0, 'a status control (menu button) exists, rows=' + rows);
      const before = (await trigs.first().innerText()).trim().replace(/\s+/g, ' '); await trigs.first().click(); await sleep(600);
      const items = (await page.getByRole('menuitem').allInnerTexts()).map((t) => t.trim()).filter(Boolean); s.state.before = before; s.state.menuItems = items;
      expect(items.length > 0, 'the menu offers actions');
      const safe = page.getByRole('menuitem').filter({ hasNotText: /delete|remove|supprimer|\u062d\u0630\u0641/i }).first();
      s.state.chose = (await safe.innerText().catch(() => '')).trim();
      await safe.click({ timeout: 6000 }); await sleep(2500);
      s.state.after = (await page.locator('main button[aria-haspopup="menu"]').filter({ hasText: /\S/ }).first().innerText().catch(() => '')).trim().replace(/\s+/g, ' ');
    }, { timeout: 45000 });
  }
}

async function FRTL() {
  const html = () => page.evaluate(() => ({ lang: document.documentElement.lang, dir: document.documentElement.dir }));
  const langBtn = () => page.getByRole('button', { name: /^(English|Fran\u00e7ais|\u0627\u0644\u0639\u0631\u0628\u064a\u0629)$/ }).first();
  const pickLang = async (label) => { await langBtn().click(); await sleep(500); await page.getByRole('menuitem', { name: label }).or(page.getByRole('option', { name: label })).or(page.getByRole('radio', { name: label })).first().click(); await sleep(1500); };
  const token = String(Math.floor(10000 + Math.random() * 89999)); const arName = '\u0642\u0645\u064a\u0635 \u0627\u062e\u062a\u0628\u0627\u0631 ' + token;
  await step('RTL', 'switch the interface to Arabic', async (s) => { await go('/products'); await pickLang(/\u0639\u0631\u0628/i); const h = await html(); s.state = h; expect(h.lang === 'ar' && h.dir === 'rtl', JSON.stringify(h)); });
  await step('RTL', 'Arabic product form: dialog is rtl, Arabic name saves exactly', async (s) => {
    await go('/products');
    const add = page.getByRole('button', { name: /\u0625\u0636\u0627\u0641\u0629 \u0645\u0646\u062a\u062c|\u0623\u0636\u0641 \u0645\u0646\u062a\u062c|\u0645\u0646\u062a\u062c \u062c\u062f\u064a\u062f|add product/i }).first();
    expect((await add.count()) > 0, 'an add-product button in Arabic'); await add.click({ timeout: 8000 });
    const d = dlg(); await d.waitFor({ timeout: 10000 });
    s.state = { dialogDir: await d.evaluate((el) => getComputedStyle(el).direction) };
    await d.locator('input[type=text], input:not([type])').first().fill(arName);
    const price = d.locator('input[type=number], input[inputmode=decimal], input[inputmode=numeric]').first(); if (await price.count()) await price.fill('1000').catch(() => {});
    s.state.nameInField = await d.locator('input[type=text], input:not([type])').first().inputValue();
    await d.getByRole('button', { name: /\u062d\u0641\u0638|save/i }).first().click({ timeout: 8000 }); await sleep(3000);
    const recs = findRecords((await apiJson('/api/products?limit=200&search=' + encodeURIComponent(token))).j, token); s.state.found = recs.map((r) => r.name);
    for (const r of recs) await apiJson('/api/products/' + r.id, 'DELETE');
    await closeDialogsLB();
    expect(s.state.dialogDir === 'rtl', 'dialog direction rtl, got ' + s.state.dialogDir);
    expect(recs.length === 1 && recs[0].name === arName, 'the Arabic name is stored exactly: ' + JSON.stringify(s.state.found));
  }, { timeout: 45000 });
  await step('RTL', 'restore English', async (s) => { await go('/products'); await pickLang(/english/i); const h = await html(); s.state = h; expect(h.lang === 'en', JSON.stringify(h)); }, { force: true });
}


// lead B (session 1), set 3b: the commune pre-fill END TO END in the packaged app: first pick -> Create (risk dialog confirmed) -> the stored order
async function FB3() {
  for (const nm of ['Mokrani', 'Gacem', 'Ziani']) {
    await step('B3', 'first pick of ' + nm + ', add a product, Create order, confirm the risk dialog if shown', async (s) => {
      await go('/orders'); s.drafts = await clearDraftsLB();
      const totalBefore = totalOf((await apiJson('/api/orders?limit=1')).j);
      await page.getByRole('button', { name: /new order/i }).first().click(); const d = dlg(); await d.waitFor({ timeout: 10000 });
      await d.getByRole('combobox').first().click(); await sleep(700);
      const opt = page.getByRole('option').filter({ hasText: new RegExp(nm) }).first();
      const card = (await opt.innerText()).replace(/\s+/g, ' ').slice(0, 90);
      await opt.click({ timeout: 8000 });
      let com = null, wil = null;
      for (let i = 0; i < 24; i++) {
        await sleep(250);
        const combos = (await d.locator('[role=combobox]').allInnerTexts()).map((c) => c.trim().replace(/\s+/g, ' '));
        const wi = combos.findIndex((c) => /^\d{1,2}\s*[-\u2014\u2013]/.test(c));
        wil = wi >= 0 ? combos[wi] : null; com = wi >= 0 ? (combos[wi + 1] ?? null) : null;
        if (com && !/^select\.\.\.$/i.test(com)) break;
      }
      await d.getByRole('combobox', { name: /add a product/i }).or(d.getByRole('combobox').nth(1)).first().click(); await sleep(700);
      await page.getByRole('option').first().click({ timeout: 8000 }); await sleep(900);
      s.state = { card, totalBefore, wilayaShown: wil, communeShownBeforeCreate: com };
      const pr = page.waitForResponse((r) => r.request().method() === 'POST' && /\/api\/orders(\?|$)/.test(r.url()), { timeout: 25000 }).catch(() => null);
      await d.getByRole('button', { name: /^create order$/i }).click({ timeout: 8000 }); await sleep(2500);
      const risk = page.locator('[role=alertdialog]').filter({ visible: true });
      if (await risk.count()) { s.state.riskDialog = (await risk.last().innerText()).replace(/\s+/g, ' ').slice(0, 140); await risk.last().getByRole('button').last().click().catch(() => {}); }
      const resp = await pr;
      s.state.postStatus = resp ? resp.status() : null;
      let j = null; try { j = resp ? await resp.json() : null; } catch {}
      const o = j && (j.order || j);
      s.state.stored = o ? { commune: o.commune ?? null, wilaya: o.wilaya ?? null, id: o.id ?? null } : null;
      s.state.head = j ? JSON.stringify(j).slice(0, 200) : null;
      await sleep(800); s.state.dialogStillOpen = await d.isVisible().catch(() => false);
      const after = totalOf((await apiJson('/api/orders?limit=1')).j); s.state.totalAfter = after;
      if (s.state.dialogStillOpen) { await closeDialogsLB(); }
      expect(com && !/^select\.\.\.$/i.test(com), 'commune filled on the FIRST pick (shows ' + JSON.stringify(com) + ')');
      expect(resp && resp.status() === 201, 'POST /api/orders answered 201 (got ' + (resp ? resp.status() : 'nothing') + ')');
      expect(after === totalBefore + 1, 'order total +1: ' + totalBefore + ' -> ' + after);
    }, { timeout: 60000 });
  }
}

const HARD = setTimeout(() => { R.notes.hardStop = 'hard stop at ' + Math.round((Date.now() - T_START) / 1000) + ' s'; R.finished = new Date().toISOString(); R.totals = { steps: R.steps.length, passed: R.steps.filter((x) => x.ok).length, failed: R.steps.filter((x) => !x.ok).length }; save(); console.log('HARD STOP'); process.exit(0); }, TOTAL_MS + 40000);
try {
  await session();
  const only = (process.env.FLOWS || 'B3').split(',');
  const table = { B3: FB3, A: FA, B: FB, B2: FB2, V: FV, X: FX, R: FR, RTL: FRTL, F1, F2, F5, F6, F8, F4, F7 }; // F4 changes language and is restored at its end; F7 signs out, last
  for (const k of ['B3', 'A', 'B', 'B2', 'V', 'X', 'R', 'F1', 'F2', 'F8', 'F5', 'F6', 'RTL', 'F4', 'F7']) if (only.includes(k)) { try { await table[k](); } catch (e) { console.log('flow crashed', k, String(e).slice(0, 200)); R.notes['crash_' + k] = String(e).slice(0, 200); } }
} catch (e) { R.notes.fatal = String(e && e.stack ? e.stack : e).slice(0, 600); console.log('FATAL', R.notes.fatal); }
clearTimeout(HARD);
R.finished = new Date().toISOString();
R.totals = { steps: R.steps.length, passed: R.steps.filter((x) => x.ok).length, failed: R.steps.filter((x) => !x.ok).length };
save(); console.log('TOTALS', JSON.stringify(R.totals));
try { if (LOCAL) await browser.close(); else await browser.close().catch(() => {}); } catch {}
process.exit(0);
