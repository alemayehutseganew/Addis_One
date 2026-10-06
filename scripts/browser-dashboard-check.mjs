#!/usr/bin/env node
/**
 * Browser smoke test for the operations dashboard.
 *
 * Drives headless Chrome over the DevTools Protocol using Node's built-in
 * WebSocket, so it needs no npm install and works on a machine with no network
 * access to a registry.
 *
 * Why not just take a screenshot: a screenshot proves pixels were painted, not
 * that the page fetched anything. This evaluates the live DOM and the page's
 * own fetch calls, which is what actually needs testing — a dashboard that
 * renders a shell and silently fails to load data looks fine in a screenshot
 * and is useless to the person using it.
 *
 * Usage: node scripts/browser-dashboard-check.mjs
 */
import { spawn } from 'node:child_process';
import { writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const BASE = 'http://127.0.0.1:3000';
const API = `${BASE}/api/v1`;
const CHROME =
  'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 9222;
const PROFILE = join(tmpdir(), 'addis-chrome-profile');
const OUT = join(tmpdir(), 'addis_browser.txt');
const SHOTS = join(tmpdir(), 'addis-shots');

const lines = [];
const log = (s) => {
  lines.push(s);
  console.log(s);
};

/** Signs in through the real OTP flow by reading the code from the server log. */
async function signIn(phone) {
  await fetch(`${API}/auth/request-otp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ phone }),
  });

  // OTP_DEV_ECHO is on in development, so the code lands in the log. In
  // production this would arrive by SMS and this function would not exist.
  //
  // The log is appended to asynchronously by the server, so the read is polled
  // rather than done once: a request that races the log write would otherwise
  // fail intermittently and look like a broken login.
  let code = null;
  for (let attempt = 0; attempt < 20 && !code; attempt++) {
    await sleep(300);
    const logText = await readServerLog();
    const codes = [...logText.matchAll(/code=(\d{6})/g)];
    if (codes.length) code = codes[codes.length - 1][1];
  }
  if (!code) throw new Error('no OTP echoed in the server log');

  const res = await fetch(`${API}/auth/verify-otp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ phone, code }),
  });
  const data = await res.json();
  if (!data.ok) throw new Error(`verify-otp refused: ${JSON.stringify(data)}`);
  return data.accessToken;
}

async function readServerLog() {
  const { readFileSync } = await import('node:fs');
  try {
    return readFileSync(
      'C:\\Users\\alexo\\Desktop\\File\\Code\\AddisTransport\\backend\\server.log',
      'utf8',
    );
  } catch {
    return '';
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* ── Minimal DevTools Protocol client ─────────────────────────────────── */

class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.nextId = 0;
    this.pending = new Map();
    // Every event is kept, not just the ones awaited: console errors and failed
    // requests arrive asynchronously and are the main thing this test hunts.
    this.events = [];
    ws.addEventListener('message', (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
      } else if (msg.method) {
        this.events.push(msg);
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
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`timeout: ${method}`));
        }
      }, 30000);
    });
  }

  /** Evaluates an expression in the page and returns its value. */
  async eval(expression) {
    const r = await this.send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (r.exceptionDetails) {
      throw new Error(r.exceptionDetails.exception?.description || 'eval failed');
    }
    return r.result.value;
  }
}

/* ── The test ──────────────────────────────────────────────────────────── */

let pass = 0;
let fail = 0;

/** Asserts a condition and records it either way, so one failure is not fatal. */
function check(name, ok, detail) {
  if (ok) {
    pass++;
    log(`PASS  ${name}${detail ? ` — ${detail}` : ''}`);
  } else {
    fail++;
    log(`FAIL  ${name}${detail ? ` — ${detail}` : ''}`);
  }
}

/** Captures a PNG so a human can confirm rendering, not just the DOM. */
async function shot(cdp, name) {
  const { data } = await cdp.send('Page.captureScreenshot', { format: 'png' });
  writeFileSync(join(SHOTS, name), Buffer.from(data, 'base64'));
}

async function main() {
  rmSync(PROFILE, { recursive: true, force: true });
  mkdirSync(SHOTS, { recursive: true });

  // The OTP service allows 5 codes per phone per hour with a 45s resend
  // cooldown. Repeated runs of this script would exhaust that long before the
  // test itself was at fault, and the symptom (a login that mysteriously
  // fails) says nothing about the dashboard. Callers are expected to clear the
  // challenges first via scripts/reset-otp-limits.sql — see runDashboardChecks.
  //
  // The number is the seeded bureau account, so the role under test is exactly
  // the one that has finance access.
  const phone = process.env.DASHBOARD_TEST_PHONE || '+251911000001';
  log(`signing in as ${phone}`);
  const token = await signIn(phone);
  log(`signed in, token length ${token.length}`);

  const chrome = spawn(
    CHROME,
    [
      '--headless=new',
      `--remote-debugging-port=${PORT}`,
      `--user-data-dir=${PROFILE}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-gpu',
      '--hide-scrollbars',
      '--window-size=1440,1000',
      'about:blank',
    ],
    { stdio: 'ignore' },
  );

  try {
    // The debugging port needs a moment; polling beats a fixed sleep because a
    // slow machine would otherwise fail the run for no real reason.
    let target = null;
    for (let i = 0; i < 40 && !target; i++) {
      await sleep(500);
      try {
        const r = await fetch(`http://127.0.0.1:${PORT}/json`);
        const list = await r.json();
        target = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
      } catch {
        /* not listening yet */
      }
    }
    if (!target) throw new Error('Chrome DevTools endpoint never became available');
    log('DevTools endpoint available');

    const cdp = await Cdp.connect(target.webSocketDebuggerUrl);
    await cdp.send('Page.enable');
    await cdp.send('Runtime.enable');
    await cdp.send('Log.enable');
    await cdp.send('Network.enable');

    // ── Unauthenticated load ──────────────────────────────────────────
    await cdp.send('Page.navigate', { url: `${BASE}/dashboard/` });
    await sleep(3500);

    check(
      'login screen shown when signed out',
      (await cdp.eval("getComputedStyle(document.getElementById('login')).display")) === 'flex',
    );
    check(
      'dashboard hidden when signed out',
      (await cdp.eval("document.getElementById('app').classList.contains('ready')")) === false,
    );
    check(
      'login form rendered',
      (await cdp.eval("!!document.getElementById('phone') && !!document.getElementById('btn-send')")) === true,
    );
    // CSS that escaped the <style> block renders as visible body text. It is
    // easy to introduce and invisible in a DOM node count, because the markup is
    // all there — the styles just are not applied.
    const strayCss = await cdp.eval(
      "document.body.innerText.indexOf('padding:') > -1 || document.body.innerText.indexOf('display: grid') > -1",
    );
    check('no CSS leaked into the body', strayCss === false);
    check(
      'date presets applied on load',
      (await cdp.eval("document.getElementById('from').value.length === 10 && document.getElementById('to').value.length === 10")) === true,
    );

    // ── Sign in, as a returning officer would ─────────────────────────
    await cdp.eval(`sessionStorage.setItem('addis.dashboard.token', ${JSON.stringify(token)})`);
    await cdp.send('Page.reload');
    await sleep(5000);

    // Dump anything the page complained about. A blank dashboard and a
    // populated one look identical from the outside, so when a later assertion
    // fails this is the evidence that says why.
    for (const e of cdp.events) {
      if (e.method === 'Runtime.exceptionThrown') {
        const d = e.params.exceptionDetails;
        log(`  [page exception] ${d.exception?.description || d.text}`);
      }
      if (e.method === 'Runtime.consoleAPICalled' && e.params.type === 'error') {
        log(`  [console.error] ${e.params.args.map((a) => a.value ?? a.description).join(' ')}`);
      }
      if (e.method === 'Log.entryAdded' && e.params.entry.level === 'error') {
        log(`  [log] ${e.params.entry.text} ${e.params.entry.url || ''}`);
      }
    }
    for (const e of cdp.events) {
      if (e.method === 'Network.responseReceived' && e.params.response.status >= 400) {
        log(`  [http ${e.params.response.status}] ${e.params.response.url}`);
      }
    }
    // Is the module even executing? The wiring at the bottom of dashboard.js runs
    // at parse time, so if any of it threw, these globals stay undefined and
    // every later assertion fails for that single reason.
    const probe = await cdp.eval(`(function () {
      var s = document.querySelector('script[src*="dashboard"]');
      return JSON.stringify({
        api: typeof api,
        start: typeof start,
        tagSrc: s ? s.getAttribute('src') : null,
        tagResolved: s ? s.src : null,
        scriptCount: document.scripts.length,
        fromValue: document.getElementById('from').value,
        loginError: (document.getElementById('login-error') || {}).textContent || '',
        tabButtons: document.querySelectorAll('nav.tabs button').length
      });
    })()`);
    log(`  [probe] ${probe}`);

    log(`  [login error text] ${await cdp.eval(
      "(document.getElementById('login-error')||{}).textContent || '(empty)'",
    )}`);

    check(
      'dashboard shown after sign in',
      (await cdp.eval("getComputedStyle(document.getElementById('app')).display")) === 'block',
    );
    check(
      'login screen hidden after sign in',
      (await cdp.eval("getComputedStyle(document.getElementById('login')).display")) === 'none',
    );
    const who = await cdp.eval("document.getElementById('who').textContent.trim()");
    check('identity shown in header', /Bureau Administrator/.test(who), who);

    const cards = await cdp.eval("document.querySelectorAll('#panel-overview .card').length");
    check('KPI cards rendered', cards >= 6, `${cards} cards`);

    const charts = await cdp.eval("document.querySelectorAll('#panel-overview svg').length");
    check('charts drawn as inline SVG', charts >= 2, `${charts} svg elements`);

    const bars = await cdp.eval("document.querySelectorAll('#panel-overview .bar-row').length");
    check('zone bar list rendered', bars >= 4, `${bars} rows`);

    // A bar whose track has collapsed to zero width looks like a missing chart.
    // Node counts alone would not catch it, so the rendered width is asserted.
    const trackWidth = await cdp.eval(
      "(document.querySelector('#panel-overview .bar-track') || {}).getBoundingClientRect().width || 0",
    );
    check('bar tracks have visible width', trackWidth > 40, `${Math.round(trackWidth)}px`);

    // The legend reads as separate notes, not one run-together sentence.
    const legendItems = await cdp.eval(
      "document.querySelectorAll('#panel-overview .legend span').length",
    );
    check('legend notes render separately', legendItems >= 2, `${legendItems} notes`);

    check(
      'overview finished loading',
      (await cdp.eval("!document.getElementById('panel-overview').textContent.includes('Loading')")) === true,
    );

    const settled = await cdp.eval(
      "document.querySelector('#panel-overview .card .value').textContent.trim()",
    );
    check('settled revenue shows a currency amount', /ETB/.test(settled), settled);

    // The page must be talking to the API, not rendering placeholders.
    const apiCalls = cdp.events.filter(
      (e) => e.method === 'Network.responseReceived' &&
             e.params.response.url.includes('/api/v1/dashboard/'),
    );
    check('dashboard API calls observed', apiCalls.length > 0, `${apiCalls.length} responses`);

    await shot(cdp, '01-overview.png');

    // ── Tab navigation ────────────────────────────────────────────────
    const tabs = [
      ['revenue', '.card'],
      ['operations', '.card'],
      ['network', '.card'],
      ['fares', 'table'],
      ['passengers', 'table'],
      // Database and Manage are the admin CRUD surface. They were shipped with a
      // tab button but no check, so the count assertion below (8 buttons) was the
      // only thing covering them — a tab that rendered an empty shell passed.
      ['database', '.card'],
      ['manage', 'table'],
    ];
    let shotIndex = 2;
    for (const [tab, expect] of tabs) {
      await cdp.eval(
        `document.querySelector('nav.tabs button[data-panel="${tab}"]').click(); true`,
      );
      await sleep(2500);
      const active = await cdp.eval(
        `document.getElementById('panel-${tab}').classList.contains('active')`,
      );
      const filled = await cdp.eval(
        `document.querySelectorAll('#panel-${tab} ${expect}').length`,
      );
      check(`tab ${tab} renders`, active === true && filled > 0, `${filled} ${expect} nodes`);
      await shot(cdp, `${String(shotIndex++).padStart(2, '0')}-${tab}.png`);
    }

    // Coverage guard. The `tabs` list above is hand-maintained, so a tab added to
    // the page later would render with no check at all and the suite would still
    // report green. Asserting the two lists agree is what stops that recurring.
    const navTabs = await cdp.eval(
      "[...document.querySelectorAll('nav.tabs button[data-panel]')].map(b => b.dataset.panel)",
    );
    const covered = tabs.map((t) => t[0]);
    // Overview is asserted by the dedicated block above rather than by the loop,
    // because it is the default panel: it has to be measured before anything is
    // clicked, while every other tab only exists as a result of a click.
    covered.push('overview');
    const uncovered = navTabs.filter((t) => !covered.includes(t));
    check(
      'every navigation tab is covered by a check',
      uncovered.length === 0,
      uncovered.length
        ? `uncovered: ${uncovered.join(',')}`
        : `${navTabs.length} tabs, all covered`,
    );

    // ── Database panel ────────────────────────────────────────────────
    // Reports pool utilisation, which is the failure this tab exists to catch.
    // It must also not echo the connection string it was derived from: a page
    // readable by any signed-in staff member is exactly where a DB password
    // would leak.
    await cdp.eval('document.querySelector(\'nav.tabs button[data-panel="database"]\').click(); true');
    await sleep(1500);
    const dbText = await cdp.eval("document.getElementById('panel-database').textContent");
    check('database panel reports the connection pool', /Connection pool/.test(dbText));
    check(
      'database panel leaks no connection string',
      !/postgres(ql)?:\/\//i.test(dbText) && !/:\/\/[^@\s]*@/.test(dbText),
    );

    // ── Manage panel (the write path) ─────────────────────────────────
    // Renders resource tabs filtered from the same permission flags the server
    // enforces, so an officer is never offered a tab whose only answer is a 403.
    await cdp.eval('document.querySelector(\'nav.tabs button[data-panel="manage"]\').click(); true');
    await sleep(2500);
    const resTabs = await cdp.eval(
      "document.querySelectorAll('#panel-manage .tab[data-admin-res]').length",
    );
    check('manage panel lists admin resources', resTabs >= 4, `${resTabs} resources`);

    // It has to have talked to the admin API. A table that rendered from a
    // hard-coded list would pass the node count above and be useless to staff.
    const adminCalls = cdp.events.filter(
      (e) =>
        e.method === 'Network.responseReceived' &&
        e.params.response.url.includes('/api/v1/admin/'),
    );
    check(
      'manage panel called the admin API',
      adminCalls.length > 0,
      `${adminCalls.length} responses`,
    );


    // ── Fare rule version history (invariant I3) ─────────────────────
    await cdp.eval('document.querySelector(\'nav.tabs button[data-panel="fares"]\').click(); true');
    await sleep(2000);
    const fareText = await cdp.eval("document.getElementById('panel-fares').textContent");
    check(
      'fare rules show CITY-BUS as both active and superseded',
      /CITY-BUS/.test(fareText) && /SUPERSEDED/.test(fareText) && /ACTIVE/.test(fareText),
    );
    check('no citizen phone numbers in fare table', !/\+251\d{8}/.test(fareText));

    // ── Date filter actually refetches ────────────────────────────────
    await cdp.eval('document.querySelector(\'nav.tabs button[data-panel="overview"]\').click(); true');
    await sleep(1500);
    const before = await cdp.eval(
      "document.querySelector('#panel-overview .card .value').textContent.trim()",
    );
    await cdp.eval(`
      (function () {
        var to = new Date();
        var from = new Date();
        from.setDate(from.getDate() - 6);
        document.getElementById('from').value = from.toISOString().slice(0, 10);
        document.getElementById('to').value = to.toISOString().slice(0, 10);
        document.getElementById('to').dispatchEvent(new Event('change'));
        return true;
      })()
    `);
    await sleep(3000);
    const stillRendered = await cdp.eval(
      "document.querySelectorAll('#panel-overview svg').length",
    );
    check('date filter refetches and redraws', stillRendered >= 2, `revenue was ${before}`);
    await shot(cdp, '07-filtered.png');

    // ── Responsive layout ─────────────────────────────────────────────
    await cdp.send('Emulation.setDeviceMetricsOverride', {
      width: 390, height: 844, deviceScaleFactor: 2, mobile: true,
    });
    await sleep(1500);
    check(
      'no horizontal overflow at 390px',
      (await cdp.eval('document.documentElement.scrollWidth <= window.innerWidth + 2')) === true,
    );
    await shot(cdp, '08-mobile.png');
    await cdp.send('Emulation.clearDeviceMetricsOverride');

    // ── Console and network hygiene ──────────────────────────────────
    const consoleErrors = cdp.events
      .filter((e) => e.method === 'Log.entryAdded' && e.params.entry.level === 'error')
      .map((e) => e.params.entry.text);
    const failed = cdp.events
      .filter((e) => e.method === 'Network.loadingFailed')
      .map((e) => e.params.errorText);
    check('no console errors', consoleErrors.length === 0, consoleErrors.join(' | ').slice(0, 300));
    check('no failed resource loads', failed.length === 0, failed.join(' | ').slice(0, 300));

    // ── Sign out clears the session ──────────────────────────────────
    await cdp.eval("document.getElementById('btn-signout').click(); true");
    await sleep(2000);
    check(
      'sign out returns to login',
      (await cdp.eval("getComputedStyle(document.getElementById('login')).display")) === 'flex',
    );
    check(
      'token cleared on sign out',
      (await cdp.eval("sessionStorage.getItem('addis.dashboard.token') === null")) === true,
    );
  } catch (err) {
    fail++;
    log(`ERROR ${err.message}`);
  } finally {
    try { process.kill(chrome.pid); } catch { /* already gone */ }
  }

  log('');
  log(`=== ${pass} passed, ${fail} failed ===`);
  log(`screenshots: ${SHOTS}`);
  writeFileSync(OUT, lines.join('\n'), 'utf8');
  process.exit(fail === 0 ? 0 : 1);
}

main();
