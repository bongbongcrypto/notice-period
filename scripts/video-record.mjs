#!/usr/bin/env node
/* Demo video recorder, run by .github/workflows/video.yml on GitHub's runner only (never on a local machine).

     node scripts/video-record.mjs PLAN.json OUT_DIR [--voice edge|espeak|none]

   Drives the runner's Google Chrome (CHROME_BIN) over the DevTools protocol with Node 22's global WebSocket and fetch;
   no dependency. PLAN.json is written by scripts/video-check.py. Per shot it writes OUT_DIR/<id>/ and one entry of
   OUT_DIR/manifest.json:
     still     one PNG of the viewport (after an optional jump to an element)
     zoom      one PNG of one element's region, rendered at a higher scale (the region is widened to 16:9)
     scroll    a JPEG held for holdBefore seconds, then one JPEG per 1/30 s while the page scrolls to an element
     realtime  JPEGs as fast as Chrome returns them, each with its wall-clock time, so the clip plays at real speed;
               a replay starts by setting the page's #run=N address, which the page itself replays
     card      video/endcard.html, filled from the plan with textContent only
     clip      a file in the repository, only checked to exist here
   Waits are on content: text that must appear (a block number, a hash), text that must be gone (a loading or
   bot-check page), then quiet network. Chrome runs with its sandbox; only if it cannot start that way does it run with
   --no-sandbox, and the manifest says so. The user agent is Chrome's own: nothing here hides that it is automated.
   A shot that fails leaves OUT_DIR/debug/<id>.png and .txt; an optional shot is then skipped, any other fails the
   run after the remaining shots were tried. */

import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const FPS = 30;

function die(msg) {
  console.error(`video-record: ${msg}`);
  process.exit(1);
}

function parseArgs(argv) {
  const pos = [];
  let voice = 'edge';
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--voice') voice = argv[(i += 1)];
    else pos.push(argv[i]);
  }
  if (pos.length !== 2) die('usage: video-record.mjs PLAN.json OUT_DIR [--voice edge|espeak|none]');
  if (!['edge', 'espeak', 'none'].includes(voice)) die(`unknown voice engine ${voice}`);
  return { plan: resolve(pos[0]), out: resolve(pos[1]), voice };
}

/* ---------- image size (PNG IHDR, JPEG SOFn) ---------- */

function imageSize(buf) {
  if (buf.length > 24 && buf.readUInt32BE(0) === 0x89504e47) return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20) };
  if (buf.length > 4 && buf[0] === 0xff && buf[1] === 0xd8) {
    let i = 2;
    while (i + 9 < buf.length) {
      if (buf[i] !== 0xff) { i += 1; continue; }
      const m = buf[i + 1];
      if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) return { w: buf.readUInt16BE(i + 7), h: buf.readUInt16BE(i + 5) };
      if (m === 0xd8 || m === 0x01 || (m >= 0xd0 && m <= 0xd7)) { i += 2; continue; }
      i += 2 + buf.readUInt16BE(i + 2);
    }
  }
  return null;
}

/* ---------- Chrome ---------- */

async function launchChrome(bin, noSandbox) {
  const profile = mkdtempSync(join(tmpdir(), 'np-video-'));
  const args = [
    '--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-sync',
    '--disable-background-networking', '--disable-component-update', '--disable-default-apps',
    '--mute-audio', '--hide-scrollbars', '--lang=en-US', '--force-color-profile=srgb',
    '--window-size=1280,720', 'about:blank',
  ];
  if (noSandbox) args.unshift('--no-sandbox');
  let err = '';
  let spawnError = null;
  const proc = spawn(bin, args, { stdio: ['ignore', 'ignore', 'pipe'] });
  proc.on('error', (e) => { spawnError = e; });
  proc.stderr.on('data', (d) => { err = (err + d).slice(-8000); });
  const tail = () => err.trim().split('\n').slice(-6).join(' | ');
  const portFile = join(profile, 'DevToolsActivePort');
  const t0 = Date.now();
  while (Date.now() - t0 < 30000) {
    if (spawnError) return { error: `could not start ${bin}: ${spawnError.message}`, profile };
    if (proc.exitCode !== null || proc.signalCode !== null) return { error: `Chrome exited (${proc.exitCode ?? proc.signalCode}): ${tail()}`, profile };
    if (existsSync(portFile)) {
      const lines = readFileSync(portFile, 'utf8').split('\n').map((s) => s.trim());
      if (/^\d+$/.test(lines[0] || '') && (lines[1] || '').startsWith('/devtools/browser/')) {
        try {
          const info = await (await fetch(`http://127.0.0.1:${lines[0]}/json/version`)).json();
          if (info.webSocketDebuggerUrl) return { proc, profile, ws: info.webSocketDebuggerUrl, product: info.Browser, userAgent: info['User-Agent'], stderr: tail };
        } catch (e) { /* the port file can precede the listener by a moment */ }
      }
    }
    await sleep(100);
  }
  proc.kill('SIGKILL');
  return { error: `Chrome did not open its DevTools port within 30 s: ${tail()}`, profile };
}

class Cdp {
  constructor(url) {
    this.url = url;
    this.next = 0;
    this.pending = new Map();
    this.listeners = new Set();
  }

  open() {
    return new Promise((resolveOpen, rejectOpen) => {
      const ws = new WebSocket(this.url);
      this.ws = ws;
      let opened = false;
      ws.onopen = () => { opened = true; resolveOpen(); };
      ws.onerror = (ev) => { if (!opened) rejectOpen(new Error(`DevTools WebSocket failed: ${(ev && ev.message) || 'error event'}`)); };
      ws.onclose = (ev) => {
        if (!opened) rejectOpen(new Error(`DevTools WebSocket closed before it opened (code ${ev.code} ${ev.reason || ''})`));
        for (const p of this.pending.values()) p.reject(new Error(`DevTools connection closed during ${p.method}`));
        this.pending.clear();
      };
      ws.onmessage = (ev) => this.message(ev.data);
    });
  }

  message(data) {
    const msg = JSON.parse(typeof data === 'string' ? data : Buffer.from(data).toString('utf8'));
    if (msg.id !== undefined) {
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      if (msg.error) p.reject(new Error(`${p.method}: ${msg.error.message}`));
      else p.resolve(msg.result || {});
      return;
    }
    for (const fn of this.listeners) fn(msg);
  }

  send(method, params = {}, sessionId = undefined, timeoutMs = 60000) {
    this.next += 1;
    const id = this.next;
    const payload = { id, method, params };
    if (sessionId) payload.sessionId = sessionId;
    return new Promise((ok, fail) => {
      const timer = setTimeout(() => { this.pending.delete(id); fail(new Error(`${method}: no answer in ${timeoutMs / 1000} s`)); }, timeoutMs);
      this.pending.set(id, { method, resolve: (v) => { clearTimeout(timer); ok(v); }, reject: (e) => { clearTimeout(timer); fail(e); } });
      this.ws.send(JSON.stringify(payload));
    });
  }

  on(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
}

const norm = (s) => String(s).replace(/\u00a0/g, ' ').replace(/(\d),(?=\d)/g, '$1').replace(/\s+/g, ' ').toLowerCase();

class Tab {
  constructor(cdp, sessionId, targetId, vp) {
    this.cdp = cdp;
    this.sid = sessionId;
    this.tid = targetId;
    this.vp = vp;
    this.inflight = new Map();
    this.lastNet = performance.now();
    this.loads = 0;
    this.doc = null;
    this.url = 'about:blank';
    this.off = cdp.on((m) => {
      if (m.sessionId !== this.sid) return;
      const p = m.params || {};
      switch (m.method) {
        case 'Network.requestWillBeSent': this.inflight.set(p.requestId, p.request && p.request.url); this.lastNet = performance.now(); break;
        case 'Network.loadingFinished':
        case 'Network.loadingFailed': this.inflight.delete(p.requestId); this.lastNet = performance.now(); break;
        case 'Network.responseReceived': if (p.type === 'Document' && p.frameId === this.tid) this.doc = { url: p.response.url, status: p.response.status }; break;
        case 'Page.loadEventFired': this.loads += 1; break;
        default: break;
      }
    });
  }

  static async open(cdp, vp) {
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    const tab = new Tab(cdp, sessionId, targetId, vp);
    await tab.send('Page.enable');
    await tab.send('Runtime.enable');
    await tab.send('Network.enable');
    await tab.send('Emulation.setDeviceMetricsOverride', { width: vp.width, height: vp.height, deviceScaleFactor: vp.scale, mobile: false, screenWidth: vp.width, screenHeight: vp.height });
    await tab.send('Emulation.setTimezoneOverride', { timezoneId: 'UTC' });
    await tab.send('Emulation.setLocaleOverride', { locale: 'en-US' }).catch(() => {});
    await tab.send('Emulation.setEmulatedMedia', { media: 'screen', features: [{ name: 'prefers-color-scheme', value: 'light' }, { name: 'prefers-reduced-motion', value: 'no-preference' }] });
    await tab.send('Emulation.setFocusEmulationEnabled', { enabled: true }).catch(() => {});
    await tab.send('Page.bringToFront').catch(() => {});
    return tab;
  }

  send(method, params = {}, timeoutMs = 60000) { return this.cdp.send(method, params, this.sid, timeoutMs); }

  async close() {
    this.off();
    await this.cdp.send('Target.closeTarget', { targetId: this.tid }).catch(() => {});
  }

  async goto(url, timeoutMs = 60000) {
    const before = this.loads;
    this.doc = null;
    const r = await this.send('Page.navigate', { url });
    if (r.errorText) throw new Error(`could not open ${url}: ${r.errorText}`);
    const t0 = performance.now();
    while (this.loads === before) {
      if (performance.now() - t0 > timeoutMs) throw new Error(`no load event from ${url} in ${timeoutMs / 1000} s`);
      await sleep(100);
    }
    if (this.doc && this.doc.status >= 400) throw new Error(`${url} answered HTTP ${this.doc.status}`);
    this.url = url;
  }

  async eval(expression, awaitPromise = false) {
    const r = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise });
    if (r.exceptionDetails) {
      const d = r.exceptionDetails;
      throw new Error(`page script failed: ${(d.exception && d.exception.description) || d.text}`);
    }
    return r.result ? r.result.value : undefined;
  }

  async text() { return String((await this.eval('document.body ? document.body.innerText : ""')) || ''); }

  async settle(quietMs = 800, maxMs = 15000) {
    const t0 = performance.now();
    while (performance.now() - t0 < maxMs) {
      if (this.inflight.size === 0 && performance.now() - this.lastNet >= quietMs) return true;
      await sleep(100);
    }
    return false;
  }

  async paint() {
    await this.eval('new Promise((r) => { let done = false; const f = () => { if (!done) { done = true; r(true); } }; requestAnimationFrame(() => requestAnimationFrame(f)); setTimeout(f, 500); })', true);
  }

  async capture(file, opts = {}) {
    const params = { format: opts.format || 'png', fromSurface: true, captureBeyondViewport: false };
    if (params.format === 'jpeg') params.quality = opts.quality || 90;
    if (opts.clip) params.clip = opts.clip;
    const { data } = await this.send('Page.captureScreenshot', params, 60000);
    const buf = Buffer.from(data, 'base64');
    writeFileSync(file, buf);
    const size = imageSize(buf);
    if (opts.expect && (!size || size.w !== opts.expect.w || size.h !== opts.expect.h)) {
      throw new Error(`${file}: ${size ? `${size.w}x${size.h}` : 'unknown size'}, expected ${opts.expect.w}x${opts.expect.h}`);
    }
    return size;
  }
}

/* ---------- waits and positions ---------- */

async function waitFor(tab, w, timeoutMs, entry) {
  if (!w) return;
  const t0 = performance.now();
  for (;;) {
    let ok = true;
    const why = [];
    if (w.js) {
      const v = await tab.eval(`(function () { try { return !!(${w.js}); } catch (e) { return false; } })()`);
      if (!v) { ok = false; why.push(`script condition ${w.js.slice(0, 60)}`); }
    }
    const text = norm(await tab.text());
    for (const s of w.textAll || []) if (!text.includes(norm(s))) { ok = false; why.push(`text "${s}"`); }
    if ((w.textAny || []).length && !w.textAny.some((s) => text.includes(norm(s)))) { ok = false; why.push(`any of ${JSON.stringify(w.textAny)}`); }
    const bad = (w.notText || []).filter((s) => text.includes(norm(s)));
    if (bad.length) { ok = false; why.push(`text gone: ${JSON.stringify(bad)}`); }
    if (ok) {
      entry.waitedSeconds = Number(((performance.now() - t0) / 1000).toFixed(1));
      return;
    }
    if (performance.now() - t0 > timeoutMs) throw new Error(`waited ${timeoutMs / 1000} s for ${why.join('; ')}`);
    await sleep(500);
  }
}

function locateJs(t) {
  return `(function () {
    const t = ${JSON.stringify(t)};
    const wants = (Array.isArray(t.text) ? t.text : [t.text || '']).map((s) => s.toLowerCase());
    const all = Array.from(document.querySelectorAll(t.selector || '*'));
    for (const want of wants) {
      const hit = (e) => { const s = (e.textContent || '').replace(/\\s+/g, ' ').trim().toLowerCase(); return !want || (t.match === 'contains' ? s.includes(want) : s.startsWith(want)); };
      let c = all.filter(hit);
      if (t.match === 'contains') c = c.filter((e) => !c.some((o) => o !== e && e.contains(o)));
      const e = c[0];
      if (!e) continue;
      const r = e.getBoundingClientRect();
      return { found: want, x: r.left + window.scrollX, y: r.top + window.scrollY, w: r.width, h: r.height,
        vw: window.innerWidth, vh: window.innerHeight, sh: document.documentElement.scrollHeight, sy: window.scrollY };
    }
    return null;
  })()`;
}

async function locate(tab, t) {
  const r = await tab.eval(locateJs(t));
  if (!r) return null;
  const off = t.offset ?? 24;
  let y = r.y - off;
  if (t.align === 'bottom') y = r.y + r.h - r.vh + off;
  if (t.align === 'center') y = r.y + r.h / 2 - r.vh / 2;
  r.scrollY = Math.round(Math.max(0, Math.min(y, r.sh - r.vh)));
  return r;
}

const scrollTo = (tab, y) => tab.eval(`window.scrollTo({ top: ${Math.round(y)}, left: 0, behavior: 'instant' })`);

async function position(tab, s, entry) {
  if (s.scrollTop) { await scrollTo(tab, 0); return; }
  if (!s.target) return;
  const r = await locate(tab, s.target);
  if (!r) {
    if (s.target.required === false) { entry.warnings.push(`target ${JSON.stringify(s.target.text || s.target.selector)} not found; no jump`); return; }
    throw new Error(`target ${JSON.stringify(s.target)} not found on the page`);
  }
  await scrollTo(tab, r.scrollY);
}

/* ---------- shots ---------- */

async function prepare(tab, s, entry) {
  if (s.url && (s.fresh || tab.url !== s.url)) await tab.goto(s.url);
  await waitFor(tab, s.wait, (s.waitSeconds || 60) * 1000, entry);
  const quiet = await tab.settle(800, 15000);
  if (!quiet) entry.warnings.push('network did not go quiet within 15 s (long polling or a slow request); captured anyway');
  if (s.soft && s.soft.textAny) {
    const text = norm(await tab.text());
    if (!s.soft.textAny.some((x) => text.includes(norm(x)))) entry.warnings.push(`none of ${JSON.stringify(s.soft.textAny)} is on the page; it may show a fallback (a time not shown, a check that failed): look at this shot in the contact sheet`);
  }
  if (s.soft && s.soft.notText) {
    const text = norm(await tab.text());
    const seen = s.soft.notText.filter((x) => text.includes(norm(x)));
    if (seen.length) entry.warnings.push(`${JSON.stringify(seen)} is on the page; the caption may no longer match it: look at this shot in the contact sheet`);
  }
  if (s.explorer) {
    const text = norm(await tab.text());
    if (/loading\.\.\.|loading\u2026/.test(text)) entry.warnings.push('the page text still has "Loading..." somewhere; check the contact sheet');
  }
}

async function shotStill(tab, s, dir, entry, expect) {
  await prepare(tab, s, entry);
  await position(tab, s, entry);
  await tab.paint();
  await sleep((s.pause ?? 0.8) * 1000);
  await tab.capture(join(dir, 'still.png'), { expect });
  return { files: ['still.png'] };
}

async function shotZoom(tab, s, dir, entry, manifest) {
  await prepare(tab, s, entry);
  await scrollTo(tab, 0);
  await tab.paint();
  await sleep((s.pause ?? 0.8) * 1000);
  if (s.live === 'morpho') {
    manifest.live.morpho = await tab.eval(`({ problem: (document.getElementById('problem') || {}).textContent || '',
      source: (document.getElementById('problem-src') || {}).textContent || '', readAt: new Date().toISOString() })`);
    entry.live = manifest.live.morpho;
  }
  const r = await locate(tab, s.target);
  if (!r) throw new Error(`zoom target ${JSON.stringify(s.target)} not found`);
  const m = s.margin ?? 32;
  let w = Math.max(r.w + 2 * m, ((r.h + 2 * m) * 16) / 9);
  w = Math.min(w, r.vw);
  const h = (w * 9) / 16;
  const x = Math.max(0, Math.min(r.x + r.w / 2 - w / 2, r.vw - w));
  const y = Math.max(0, r.y + r.h / 2 - h / 2);
  /* rendered at least as sharp as a full frame (video-make.py scales the image into 1920x1080) */
  const scale = Math.min(4, Math.max(1, (r.vw * (tab.vp.scale || 1)) / w));
  const size = await tab.capture(join(dir, 'zoom.png'), { clip: { x, y, width: w, height: h, scale } });
  entry.zoom = { x, y, w, h, scale, size };
  return { files: ['zoom.png'] };
}

async function shotScroll(tab, s, dir, entry, expect) {
  await prepare(tab, s, entry);
  if (s.from) {
    const r0 = await locate(tab, s.from);
    if (!r0) throw new Error(`scroll start ${JSON.stringify(s.from)} not found`);
    await scrollTo(tab, r0.scrollY);
  } else {
    await position(tab, s, entry);
  }
  await tab.paint();
  await sleep((s.pause ?? 0.8) * 1000);
  const frames = [];
  await tab.capture(join(dir, 'f0000.jpg'), { format: 'jpeg', quality: 92, expect });
  frames.push({ file: 'f0000.jpg', d: Number(s.holdBefore || 2) });
  const y0 = await tab.eval('window.scrollY');
  const r1 = s.to ? await locate(tab, s.to) : null;
  if (!r1) {
    entry.warnings.push(`scroll end ${JSON.stringify(s.to && (s.to.text || s.to.selector))} not found; held the first frame`);
    if (s.to && s.to.required !== false) throw new Error(`scroll end ${JSON.stringify(s.to)} not found`);
    return { frames };
  }
  entry.scrollFound = r1.found;
  const n = Math.max(1, Math.round(Number(s.scrollSeconds || 2) * FPS));
  const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
  for (let i = 1; i <= n; i += 1) {
    await scrollTo(tab, y0 + (r1.scrollY - y0) * ease(i / n));
    await tab.paint();
    const f = `f${String(i).padStart(4, '0')}.jpg`;
    await tab.capture(join(dir, f), { format: 'jpeg', quality: 92, expect });
    frames.push({ file: f, d: 1 / FPS });
  }
  return { frames };
}

async function shotRealtime(tab, s, dir, entry, expect) {
  await prepare(tab, s, entry);
  await scrollTo(tab, 0);
  await tab.paint();
  // At least captureSeconds; with untilText, on until the replay's own receipt check has answered (one of those
  // texts is on screen next to "replay of run #N"), then HOLD more seconds so the answer is readable, capped at
  // maxCaptureSeconds. The clip lasts exactly as long as it was captured (captureSeconds in the result).
  const HOLD = 1.5;
  const minSeconds = Number(s.captureSeconds);
  const until = (s.untilText || []).map(norm);
  const maxSeconds = until.length ? Math.max(minSeconds, Number(s.maxCaptureSeconds || minSeconds)) : minSeconds;
  const n = s.start && s.start.hash ? s.start.hash.replace('#run=', '') : null;
  const runRe = n ? new RegExp(`replay of run #${n}(?![0-9])`, 'i') : null;
  const stateText = async () => String(await tab.eval(`(document.getElementById('state') || document.body).innerText`));
  const frames = [];
  const t0 = performance.now();
  if (n) await tab.eval(`window.location.hash = ${JSON.stringify(s.start.hash)}`);
  let i = 0;
  let endAt = until.length ? null : 0;
  let lastPoll = -1;
  let elapsed = 0;
  for (;;) {
    elapsed = (performance.now() - t0) / 1000;
    if (elapsed >= maxSeconds) break;
    if (endAt === null && elapsed - lastPoll >= 0.5) {
      lastPoll = elapsed;
      const text = norm(await stateText());
      if ((!runRe || runRe.test(text)) && until.some((u) => text.includes(u))) endAt = elapsed;
    }
    if (endAt !== null && elapsed >= Math.max(minSeconds, endAt + HOLD)) break;
    const t = (performance.now() - t0) / 1000;
    const f = `f${String(i).padStart(4, '0')}.jpg`;
    await tab.capture(join(dir, f), { format: 'jpeg', quality: 90, expect });
    frames.push({ file: f, t: Number(t.toFixed(4)) });
    i += 1;
  }
  const seconds = Number(elapsed.toFixed(3));
  const gaps = frames.slice(1).map((fr, k) => fr.t - frames[k].t);
  entry.fps = Number((frames.length / Math.max(seconds, 0.001)).toFixed(1));
  entry.maxGap = Number((gaps.length ? Math.max(...gaps) : seconds).toFixed(3));
  entry.captured = seconds;
  if (entry.fps < 4) entry.warnings.push(`only ${entry.fps} frames per second captured; the replay will look jerky`);
  if (n) {
    entry.pageText = (await stateText()).slice(0, 600);
    if (!runRe.test(entry.pageText)) throw new Error(`the page did not show the replay of run ${n} after ${s.start.hash}: ${entry.pageText.slice(0, 160)}`);
  }
  if (until.length) {
    if (endAt === null) entry.warnings.push(`the replay's receipt check did not answer within ${maxSeconds} s; the clip ends before it`);
    else entry.checkAnsweredAt = Number(endAt.toFixed(3));
    if (/could not re-check/i.test(entry.pageText || '')) entry.warnings.push(`the page could not re-check run ${n} against the chains; the clip shows its recorded copy`);
  }
  return { frames, captureSeconds: seconds };
}

async function shotCard(tab, s, dir, entry, plan, voice, expect) {
  const card = { ...plan.card, foot: voice === 'none' ? plan.card.footNoVoice : plan.card.footVoice };
  await tab.goto(pathToFileURL(join(ROOT, 'video', 'endcard.html')).href);
  const ok = await tab.eval(`(function (d) { if (typeof window.fillCard !== 'function') return false; window.fillCard(d); return true; })(${JSON.stringify(card)})`);
  if (!ok) throw new Error('video/endcard.html has no fillCard');
  await tab.eval('document.fonts ? document.fonts.ready.then(() => true) : true', true);
  await tab.paint();
  await sleep(300);
  await tab.capture(join(dir, 'still.png'), { expect });
  return { files: ['still.png'] };
}

async function runShot(tab, s, dir, entry, manifest, plan, voice) {
  const expect = { w: Math.round(plan.viewport.width * plan.viewport.scale), h: Math.round(plan.viewport.height * plan.viewport.scale) };
  switch (s.type) {
    case 'still': return shotStill(tab, s, dir, entry, expect);
    case 'zoom': return shotZoom(tab, s, dir, entry, manifest);
    case 'scroll': return shotScroll(tab, s, dir, entry, expect);
    case 'realtime': return shotRealtime(tab, s, dir, entry, expect);
    case 'card': return shotCard(tab, s, dir, entry, plan, voice, expect);
    default: throw new Error(`unknown shot type ${s.type}`);
  }
}

function withTimeout(promise, ms, what) {
  let timer;
  return Promise.race([promise, new Promise((_, fail) => { timer = setTimeout(() => fail(new Error(`${what} took longer than ${ms / 1000} s`)), ms); })])
    .finally(() => clearTimeout(timer));
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (typeof WebSocket !== 'function' || typeof fetch !== 'function') die(`Node ${process.versions.node} has no global WebSocket or fetch; Node 22 or later is needed`);
  const plan = JSON.parse(readFileSync(args.plan, 'utf8'));
  const bin = process.env.CHROME_BIN || 'google-chrome';
  mkdirSync(join(args.out, 'debug'), { recursive: true });
  const manifest = { startedAt: new Date().toISOString(), voice: args.voice, node: process.versions.node, viewport: plan.viewport, noSandbox: false, shots: {}, live: {}, warnings: [] };
  const save = () => writeFileSync(join(args.out, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);

  let chrome = await launchChrome(bin, false);
  if (chrome.error) {
    const first = chrome.error;
    console.log(`::warning::Chrome did not start with its sandbox (${first}); trying again with --no-sandbox`);
    rmSync(chrome.profile, { recursive: true, force: true });
    chrome = await launchChrome(bin, true);
    manifest.noSandbox = true;
    manifest.warnings.push(`Chrome ran with --no-sandbox: with the sandbox it reported ${first}`);
  }
  if (chrome.error) die(chrome.error);
  manifest.chrome = chrome.product;
  manifest.userAgent = chrome.userAgent;
  console.log(`${chrome.product}${manifest.noSandbox ? ' (no sandbox)' : ''}, Node ${process.versions.node}`);
  const cdp = new Cdp(chrome.ws);
  try {
    await cdp.open();
  } catch (e) {
    die(`${e.message}. Chrome's last stderr lines: ${chrome.stderr()}`);
  }

  let tab = await Tab.open(cdp, plan.viewport);
  const failed = [];
  for (const s of plan.shots) {
    const entry = { id: s.id, type: s.type, url: s.url || null, status: 'ok', warnings: [] };
    const t0 = performance.now();
    if (s.type === 'clip') {
      if (!existsSync(join(ROOT, s.file))) { entry.status = 'failed'; entry.error = `clip ${s.file} missing`; failed.push(s.id); }
      manifest.shots[s.id] = entry;
      save();
      continue;
    }
    const dir = join(args.out, s.id);
    mkdirSync(dir, { recursive: true });
    try {
      Object.assign(entry, await withTimeout(runShot(tab, s, dir, entry, manifest, plan, args.voice), (s.timeout || 150) * 1000, `shot ${s.id}`));
    } catch (e) {
      entry.status = s.optional ? 'skipped' : 'failed';
      entry.error = String((e && e.message) || e);
      console.log(`::${s.optional ? 'warning' : 'error'}::shot ${s.id}: ${entry.error}`);
      try {
        await tab.capture(join(args.out, 'debug', `${s.id}.png`));
        writeFileSync(join(args.out, 'debug', `${s.id}.txt`), `${tab.url}\n\n${(await tab.text()).slice(0, 8000)}\n`);
      } catch (e2) { entry.debugError = String(e2.message || e2); }
      if (!s.optional) failed.push(s.id);
      await tab.close();
      tab = await Tab.open(cdp, plan.viewport);
    }
    entry.tookSeconds = Number(((performance.now() - t0) / 1000).toFixed(1));
    for (const w of entry.warnings) console.log(`::warning::shot ${s.id}: ${w}`);
    console.log(`${s.id} ${s.type} ${entry.status} in ${entry.tookSeconds} s${entry.fps ? `, ${entry.fps} fps, largest gap ${entry.maxGap} s` : ''}`);
    manifest.shots[s.id] = entry;
    save();
  }
  manifest.finishedAt = new Date().toISOString();
  save();
  await cdp.send('Browser.close', {}, undefined, 10000).catch(() => {});
  try { chrome.proc.kill('SIGKILL'); } catch (e) { /* already gone */ }
  rmSync(chrome.profile, { recursive: true, force: true });
  if (failed.length) die(`shots failed: ${failed.join(', ')} (screenshots in debug/)`);
  console.log(`recorded ${Object.keys(manifest.shots).length} shots`);
  process.exit(0);
}

main().catch((e) => die(e && e.stack ? e.stack : String(e)));
