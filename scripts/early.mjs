// Early request probe (walk-probe mode pages3early). Started by walk-probe.ps1 right after the app is launched, in its own process,
// so it keeps running while the harness (stall2.mjs) does setup / login / demo data in parallel.
// usage: node scripts/early.mjs PORT[,PORT...] [SECONDS=660] [DEBUG_PORT=9222]
// 1. wait until the app's local Next server answers GET /api/health (any HTTP status = "first answer"),
// 2. read the per-launch cookie sf_runtime over the debug port (the proxy refuses every request without it) and disconnect again,
// 3. from then on fire ONE request every 200 ms (5 per second), rotating over targets that need no login, each with a 60 s timeout.
// Output: out/early.json (meta + samples). A sample = [k, targetIndex, plannedMs, firedMs, doneMs, status, durationMs, cookieUsed] (absolute unix ms).
import fs from 'node:fs';
const ports = (process.argv[2] || '').split(',').map(Number).filter(Boolean);
const SECONDS = Number(process.argv[3] || process.env.EARLY_SECONDS || 660);
const DEBUG = process.argv[4] || '9222';
const TARGETS = ['/api/health', '/setup', '/api/auth/status', '/login', '/api/license/status'];
const STEP_MS = 200, TIMEOUT_MS = 60000;
fs.mkdirSync('out', { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const meta = { script: 'early.mjs v1', ports, seconds: SECONDS, stepMs: STEP_MS, timeoutMs: TIMEOUT_MS, targets: TARGETS, startedMs: Date.now(), cookie: false, notes: [] };
const samples = [];
let port = 0, cookie = '';
const save = (final) => { try { fs.writeFileSync('out/early.json', JSON.stringify({ ...meta, final: !!final, savedMs: Date.now(), samples })); } catch {} };

async function ask(p, path, timeoutMs, withCookie) {
  const fired = Date.now(); const s = performance.now();
  try {
    const r = await fetch(`http://127.0.0.1:${p}${path}`, { redirect: 'manual', cache: 'no-store', headers: withCookie && cookie ? { cookie: `sf_runtime=${cookie}` } : {}, signal: AbortSignal.timeout(timeoutMs) });
    await r.arrayBuffer();
    return { fired, done: Date.now(), status: r.status, ms: Math.round(performance.now() - s) };
  } catch (e) {
    return { fired, done: Date.now(), status: -1, ms: Math.round(performance.now() - s), err: String(e && (e.cause?.code || e.name || e)).slice(0, 60) };
  }
}

try {
  // 1. first answer
  const give = Date.now() + 240000; let first = null;
  while (!first && Date.now() < give) {
    for (const p of ports) { const r = await ask(p, '/api/health', 3000, false); if (r.status > 0) { first = { ...r, port: p }; break; } }
    if (!first) await sleep(100);
  }
  if (!first) { meta.notes.push('no first answer within 240 s'); save(true); process.exit(0); }
  port = first.port; meta.port = port; meta.firstAnswerMs = first.done; meta.firstAnswerStatus = first.status; meta.firstAnswerDurationMs = first.ms;
  save(false);
  // 2. cookie over the debug port (playwright-core is installed by the workflow), in the background; then disconnect.
  //    Requests sent before the cookie is known get the proxy's own 401 (field c = 0 in the sample).
  (async () => {
    const give2 = Date.now() + 120000;
    while (!cookie && Date.now() < give2) {
      // look at the debug port's plain page list first; attach only once a page is on the app's origin (fewer attach cycles)
      let onApp = false;
      try { const j = await (await fetch(`http://127.0.0.1:${DEBUG}/json`, { signal: AbortSignal.timeout(2000) })).json(); onApp = j.some((t) => t.type === 'page' && String(t.url).startsWith(`http://127.0.0.1:${port}/`)); } catch {}
      if (!onApp) { await sleep(250); continue; }
      try {
        const { chromium } = await import('playwright-core');
        const browser = await chromium.connectOverCDP(`http://127.0.0.1:${DEBUG}`, { timeout: 5000 });
        const cs = await browser.contexts()[0].cookies(`http://127.0.0.1:${port}/`);
        const c = cs.find((x) => x.name === 'sf_runtime');
        if (c) { cookie = c.value; meta.cookieMs = Date.now(); meta.cookie = true; }
        await browser.close().catch(() => {});
      } catch (e) { meta.cookieErr = String(e).slice(0, 120); }
      if (!cookie) await sleep(1000);
    }
  })();
  // 3. the probe. T0 = first scheduled request.
  const T0 = Date.now() + 50; meta.probeStartMs = T0; meta.firstGoodStatus = null;
  const pending = new Set(); let lastSave = Date.now();
  for (let k = 0; ; k++) {
    const planned = T0 + k * STEP_MS;
    if (planned - T0 >= SECONDS * 1000) break;
    const wait = planned - Date.now(); if (wait > 0) await sleep(wait);
    const ti = k % TARGETS.length;
    const usedCookie = cookie ? 1 : 0;
    const pr = ask(port, TARGETS[ti], TIMEOUT_MS, true).then((r) => { samples.push([k, ti, planned, r.fired, r.done, r.status, r.ms, usedCookie]); pending.delete(pr); });
    pending.add(pr);
    if (Date.now() - lastSave > 20000) { save(false); lastSave = Date.now(); }
  }
  await Promise.race([Promise.all([...pending]), sleep(TIMEOUT_MS + 2000)]);
  samples.sort((a, b) => a[0] - b[0]);
  meta.endedMs = Date.now(); meta.count = samples.length;
  save(true);
  console.log('early ok samples', samples.length);
} catch (e) { meta.notes.push('error ' + String(e).slice(0, 300)); save(true); console.log('early fail', String(e).slice(0, 200)); }
process.exit(0);
