// Early request probe (mode "early"). Started by walk-probe.ps1 BEFORE the app is launched; runs until out/sampler.stop exists.
// 1. finds the app's local server (loopback listener that answers /api/internal/runtime-ready with the app's own 401 JSON)
// 2. from the first answer on fires 5 requests per second (one every 200 ms, 5 URLs in turn) and records {i, fired, done, status, url, ck}
// 3. asks the debug port for the webview cookies (CDP) once per second and sends them when present (ck = number of cookies sent):
//    without the launch cookie the app's proxy answers 401/307 (proxy only); with it, pages and API handlers really run.
// Clock: Date.now() (unix ms), the same clock as out/procs.jsonl and out/walk-full.json. Output: out/early.json (rewritten every 15 s).
import fs from 'node:fs';
import { execFile } from 'node:child_process';

const DEBUG_PORT = Number(process.argv[2] || 9222);
const SKIP_PORTS = new Set([8787, DEBUG_PORT]);
const TARGETS = ['/setup', '/login', '/orders', '/api/license/status', '/api/auth/status'];
const STOP = 'out/sampler.stop';
const MAX_MS = 1500 * 1000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
fs.mkdirSync('out', { recursive: true });

const out = { script: 'early.mjs', startedAt: Date.now(), debugPort: DEBUG_PORT, targets: TARGETS, port: null, firstAnswer: null, firstAnswerStatus: null, firstCookieAt: null, cookieNames: [], cookieSource: null, cookieErrors: [], discovery: { tries: 0, candidates: {} }, samples: [], done: false };
let cookieHeader = ''; let cookieCount = 0;
function save() {
  try { fs.writeFileSync('out/early.json.tmp', JSON.stringify(out)); fs.renameSync('out/early.json.tmp', 'out/early.json'); } catch {}
}
const stopped = () => fs.existsSync(STOP) || Date.now() - out.startedAt > MAX_MS;

function listeners() {
  return new Promise((resolve) => {
    if (process.env.EARLY_FAKE_PORT) return resolve([{ port: Number(process.env.EARLY_FAKE_PORT), pid: 0 }]);
    execFile('netstat', ['-ano', '-p', 'TCP'], { timeout: 8000, windowsHide: true, maxBuffer: 8 << 20 }, (err, stdout) => {
      if (err || !stdout) return resolve([]);
      const res = [];
      for (const line of stdout.split(/\r?\n/)) {
        const m = line.match(/^\s*TCP\s+127\.0\.0\.1:(\d+)\s+\S+\s+LISTENING\s+(\d+)/);
        if (m) res.push({ port: Number(m[1]), pid: Number(m[2]) });
      }
      resolve(res);
    });
  });
}

async function get(port, url, cookie, timeoutMs) {
  const fired = Date.now();
  try {
    const r = await fetch(`http://127.0.0.1:${port}${url}`, { redirect: 'manual', cache: 'no-store', headers: cookie ? { cookie } : {}, signal: AbortSignal.timeout(timeoutMs) });
    const body = await r.text();
    return { fired, done: Date.now(), status: r.status, body: body.slice(0, 200) };
  } catch (e) { return { fired, done: Date.now(), status: -1, body: String(e && e.cause && e.cause.code || e).slice(0, 80) }; }
}

// ---- cookies over CDP (raw websocket to the browser endpoint; fallback: page endpoint with Network.getAllCookies)
let WS = null;
async function loadWs() { if (WS) return WS; try { WS = (await import('ws')).default; } catch { WS = globalThis.WebSocket || null; } return WS; }
async function cdpCall(wsUrl, method, params) {
  const W = await loadWs(); if (!W) throw new Error('no websocket');
  return new Promise((resolve, reject) => {
    const s = new W(wsUrl); const timer = setTimeout(() => { try { s.close(); } catch {} reject(new Error('cdp timeout')); }, 4000);
    const onMsg = (ev) => { const data = ev && ev.data !== undefined ? ev.data : ev; let j; try { j = JSON.parse(String(data)); } catch { return; } if (j.id === 1) { clearTimeout(timer); try { s.close(); } catch {} j.error ? reject(new Error(JSON.stringify(j.error).slice(0, 120))) : resolve(j.result); } };
    s.onmessage = onMsg; s.onerror = () => { clearTimeout(timer); reject(new Error('ws error')); };
    s.onopen = () => s.send(JSON.stringify({ id: 1, method, params: params || {} }));
  });
}
async function readCookies() {
  const base = `http://127.0.0.1:${DEBUG_PORT}`;
  const v = await (await fetch(base + '/json/version', { signal: AbortSignal.timeout(2000) })).json();
  let cookies = null;
  try { cookies = (await cdpCall(v.webSocketDebuggerUrl, 'Storage.getCookies')).cookies; out.cookieSource = 'browser Storage.getCookies'; }
  catch (e1) {
    const list = await (await fetch(base + '/json/list', { signal: AbortSignal.timeout(2000) })).json();
    const pg = list.find((x) => x.type === 'page' && x.webSocketDebuggerUrl);
    if (!pg) throw new Error('no page target; browser call failed: ' + e1.message);
    cookies = (await cdpCall(pg.webSocketDebuggerUrl, 'Network.getAllCookies')).cookies; out.cookieSource = 'page Network.getAllCookies';
  }
  return (cookies || []).filter((c) => /^(127\.0\.0\.1|localhost)$/.test(String(c.domain).replace(/^\./, '')));
}
async function cookieLoop() {
  while (!stopped()) {
    try {
      const cs = await readCookies();
      cookieHeader = cs.map((c) => `${c.name}=${c.value}`).join('; '); cookieCount = cs.length;
      if (cs.length && !out.firstCookieAt) out.firstCookieAt = Date.now();
      out.cookieNames = [...new Set([...out.cookieNames, ...cs.map((c) => c.name)])];
    } catch (e) { if (out.cookieErrors.length < 5) out.cookieErrors.push(String(e.message || e).slice(0, 140)); }
    await sleep(1000);
  }
}

// ---- 1. discover the server
let port = null;
const saver = setInterval(save, 15000);
save();
while (!port && !stopped()) {
  out.discovery.tries++;
  const ls = await listeners();
  for (const l of ls) {
    if (SKIP_PORTS.has(l.port)) continue;
    const key = `${l.port}/${l.pid}`;
    const prev = out.discovery.candidates[key];
    if (prev && prev.answered) continue;
    const r = await get(l.port, '/api/internal/runtime-ready', '', 2000);
    out.discovery.candidates[key] = { answered: r.status > 0, status: r.status, body: r.body.slice(0, 80) };
    if (r.status > 0 && /RUNTIME_CREDENTIAL_REJECTED|RUNTIME_SESSION_REQUIRED|AUTH_RUNTIME_MISCONFIGURED/.test(r.body)) {
      port = l.port; out.port = port; out.firstAnswer = r.done; out.firstAnswerFired = r.fired; out.firstAnswerStatus = r.status; break;
    }
  }
  if (!port) await sleep(150);
}
save();

// ---- 2. the loop: 5 requests per second
if (port) {
  cookieLoop();
  const pending = new Set(); let i = 0;
  while (!stopped()) {
    const k = i++; const url = TARGETS[k % TARGETS.length]; const ck = cookieCount;
    const p = get(port, url, cookieHeader, 120000).then((r) => { out.samples.push({ i: k, fired: r.fired, done: r.done, status: r.status, url, ck }); pending.delete(p); });
    pending.add(p);
    await sleep(200);
  }
  await Promise.race([Promise.all([...pending]), sleep(5000)]);
}
clearInterval(saver);
out.samples.sort((a, b) => a.i - b.i);
out.done = true; out.endedAt = Date.now();
save();
console.log('early', port ? 'ok' : 'no-server', 'samples', out.samples.length);
process.exit(0);
