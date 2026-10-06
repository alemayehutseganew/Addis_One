#!/usr/bin/env node
/**
 * Opens the operations dashboard in a real (non-headless) browser, signed in.
 *
 * Signing in first is the point: an officer asked to "see the dashboard" wants
 * to see the dashboard, not a login form. The token is placed into
 * sessionStorage and the page is reloaded, so the page boots exactly as it would
 * for someone returning the next morning.
 *
 * The browser is deliberately left open. This script is a convenience for
 * looking at the screen, not a test — scripts/browser-dashboard-check.mjs is what
 * asserts anything.
 *
 * Usage: node scripts/open-dashboard.mjs [phone]
 */
import { spawn } from 'node:child_process';
import { readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const BASE = 'http://127.0.0.1:3000';
const API = `${BASE}/api/v1`;
const CHROME = 'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 9333;
const LOG =
  'C:\\Users\\alexo\\Desktop\\File\\Code\\AddisTransport\\backend\\server.log';
const TOKEN_KEY = 'addis.dashboard.token';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Signs in through the real OTP flow. The code is read from the server log,
 * which is where OTP_DEV_ECHO writes it in development.
 *
 * Polled rather than read once because the server appends to the log
 * asynchronously, and a single read races it often enough to be annoying.
 */
async function signIn(phone) {
  await fetch(`${API}/auth/request-otp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ phone }),
  });

  let code = null;
  for (let i = 0; i < 25 && !code; i++) {
    await sleep(300);
    let text = '';
    try {
      text = readFileSync(LOG, 'utf8');
    } catch {
      continue;
    }
    const codes = [...text.matchAll(/code=(\d{6})/g)];
    if (codes.length) code = codes[codes.length - 1][1];
  }
  if (!code) throw new Error('no OTP found in the server log');

  const res = await fetch(`${API}/auth/verify-otp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ phone, code }),
  });
  const data = await res.json();
  if (!data.ok) throw new Error(`sign-in refused: ${JSON.stringify(data)}`);
  return data.accessToken;
}

/** Waits for the DevTools endpoint and returns the open page target. */
async function findPage() {
  for (let i = 0; i < 40; i++) {
    await sleep(500);
    try {
      const list = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
      const page = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
      if (page) return page;
    } catch {
      /* not listening yet */
    }
  }
  throw new Error('Chrome DevTools endpoint never became available');
}

/** Minimal CDP client: enough to seed storage and reload. */
class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.nextId = 0;
    this.pending = new Map();
    ws.addEventListener('message', (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && this.pending.has(msg.id)) {
        this.pending.get(msg.id)(msg.result);
        this.pending.delete(msg.id);
      }
    });
  }

  static async connect(url) {
    const ws = new WebSocket(url);
    await new Promise((resolve, reject) => {
      ws.addEventListener('open', resolve, { once: true });
      ws.addEventListener('error', reject, { once: true });
    });
    return new Cdp(ws);
  }

  send(method, params = {}) {
    const id = ++this.nextId;
    return new Promise((resolve) => {
      this.pending.set(id, resolve);
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          resolve(null);
        }
      }, 20000);
    });
  }

  eval(expression) {
    return this.send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
  }
}

const phone = process.argv[2] || '+251911000001';
const token = await signIn(phone);

// A dedicated profile directory is required, not optional. Chrome is already
// running for this user, and a launch without --user-data-dir is absorbed by
// that existing instance: the new --remote-debugging-port is ignored and the
// endpoint never appears, so the sign-in step silently cannot happen.
// A separate profile guarantees its own process, window and port, and leaves the
// user's own browsing session untouched.
const PROFILE = join(tmpdir(), 'addis-dashboard-window');
try {
  rmSync(PROFILE, { recursive: true, force: true });
} catch {
  // A window from an earlier run still holds the directory. Chrome reuses an
  // existing profile happily, so this is not worth failing over — only worth
  // not crashing on, since the profile directory is a scratch path.
}

spawn(
  CHROME,
  [
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${PROFILE}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--window-size=1440,960',
    'about:blank',
  ],
  { stdio: 'ignore', detached: true },
).unref();

const page = await findPage();
const cdp = await Cdp.connect(page.webSocketDebuggerUrl);
await cdp.send('Page.enable');
await cdp.send('Runtime.enable');

// Load the origin first: sessionStorage is per-origin, so writing it on
// about:blank would silently do nothing and the page would land on the login
// form with no visible reason why.
await cdp.send('Page.navigate', { url: `${BASE}/dashboard/` });
await sleep(2500);
await cdp.eval(
  `sessionStorage.setItem(${JSON.stringify(TOKEN_KEY)}, ${JSON.stringify(token)})`,
);
await cdp.send('Page.reload');
await sleep(3500);

const shown = await cdp.eval(
  "getComputedStyle(document.getElementById('app')).display",
);
console.log(
  shown?.result?.value === 'block'
    ? `dashboard open and signed in for ${phone} — see the Chrome window`
    : `browser opened but the dashboard did not render (app display: ${shown?.result?.value})`,
);

// Capture what the live window is showing, so the outcome is verifiable rather
// than taken on trust from a window title.
const shot = await cdp.send('Page.captureScreenshot', { format: 'png' });
if (shot?.data) {
  const shotPath = join(tmpdir(), 'addis-live-window.png');
  writeFileSync(shotPath, Buffer.from(shot.data, 'base64'));
  console.log(`screenshot: ${shotPath}`);
}

// Visit each visible panel so the caller is told what is actually on screen.
for (const name of ['overview', 'revenue', 'operations', 'network', 'fares', 'passengers']) {
  await cdp.eval(
    `document.querySelector('nav.tabs button[data-panel="${name}"]').click(); true`,
  );
  await sleep(1200);
  const info = await cdp.eval(
    `(function () {
       var p = document.getElementById('panel-${name}');
       return JSON.stringify({
         cards: p.querySelectorAll('.card').length,
         rows: p.querySelectorAll('tbody tr').length,
         charts: p.querySelectorAll('svg').length,
         stillLoading: p.textContent.indexOf('Loading') > -1
       });
     })()`,
  );
  console.log(`  ${name}: ${info?.result?.value}`);
}

// Leave the overview up; it is the natural landing view.
await cdp.eval(
  'document.querySelector(\'nav.tabs button[data-panel="overview"]\').click(); true',
);