#!/usr/bin/env node
/*
 * scripts/shoot.js — Playwright screenshots for the vector-calendar web build.
 *
 * Pipeline (per spec):
 *   1. Start the local stub API  (python3 scripts/stub_api.py → :9473)
 *   2. Serve build/web           (python3 -m http.server 9474 → :9474)
 *   3. Launch Chromium, mobile viewport 390×844
 *   4. Wait for Flutter boot (poll DOM for <canvas>, ≤15s)
 *   5. Wait for app data to render, then capture each main screen
 *   6. Regenerate the README Screenshots section
 *   7. Tear down both servers
 *
 * Notes on Flutter web:
 *   - The UI is rendered entirely onto a <canvas>; Playwright DOM locators
 *     do not apply. Screenshots therefore use scrolling + waits instead of
 *     element clicks (the app is read-only in the default CI build anyway).
 *   - deviceScaleFactor 2 matches a real phone's Retina-class density, so
 *     the Liquid Glass blur and hairline borders look correct.
 */

'use strict';

const { chromium } = require('playwright');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..');
const SHOT_DIR = path.join(REPO, 'screenshots');
const API_URL = 'http://localhost:9473';
const APP_URL = 'http://localhost:9474';
const BOOT_TIMEOUT_MS = 15000;
const DATA_WAIT_MS = 8000; // Flutter boot + network round-trip + render

fs.mkdirSync(SHOT_DIR, { recursive: true });

const sleep = ms => new Promise(r => setTimeout(r, ms));

function waitForUrl(url, timeoutMs = 20000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    (function tick() {
      fetch(url)
        .then(() => resolve())
        .catch(() => {
          if (Date.now() - start > timeoutMs) reject(new Error(`Timeout: ${url}`));
          else setTimeout(tick, 250);
        });
    })();
  });
}

async function waitForFlutterBoot(page) {
  // Flutter web mounts its <canvas> INSIDE <flutter-view>'s shadow root, so a
  // plain document.querySelector('canvas') finds nothing. Walk shadow roots.
  const start = Date.now();
  while (Date.now() - start < BOOT_TIMEOUT_MS) {
    const ready = await page.evaluate(() => {
      function findCanvas(root) {
        if (!root) return null;
        if (root.querySelector) {
          const c = root.querySelector('canvas');
          if (c) return c;
        }
        const els = root.querySelectorAll ? Array.from(root.querySelectorAll('*')) : [];
        for (const el of els) {
          if (el.shadowRoot) {
            const found = findCanvas(el.shadowRoot);
            if (found) return found;
          }
        }
        return null;
      }
      const c = findCanvas(document);
      return !!(c && c.width > 0 && c.height > 0);
    });
    if (ready) return;
    await sleep(250);
  }
  throw new Error(`Flutter did not boot within ${BOOT_TIMEOUT_MS}ms`);
}

// Wait until the app has actually fetched its calendar month data (via the
// stub's /__stats hit counter) before snapping screenshots.
async function waitForAppData(timeoutMs = 20000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(API_URL + '/__stats');
      const j = await res.json();
      if (j && j.stats && j.stats.calendar_range > 0) return true;
    } catch (e) { /* stub still warming up — retry */ }
    await sleep(300);
  }
  return false;
}

async function shoot(page, filename) {
  await page.screenshot({ path: path.join(SHOT_DIR, filename), fullPage: false });
  console.log(`  ✓ ${filename}`);
}

// ── Screenshot plan ──────────────────────────────────────────────────────────
// The single-page layout (top → bottom) is:
//   nav bar (month name)
//   "Calendar" title + event count
//   month grid card (busy dots, selected day ring, today circle)
//   day agenda card (all-day strip + hour grid + timed blocks)
//   inbox card (undated work)
// We capture each visual region by scrolling to it first.

const SHOTS = [
  {
    file: '01-month-grid.png',
    desc: 'Month grid — November 2026, busy-day dots, today ring, selected day',
    scrollY: 0,
  },
  {
    file: '02-day-agenda.png',
    desc: 'Day agenda — hour grid (05:00–24:00), timed event blocks, all-day strip',
    scrollY: 520,
  },
  {
    file: '03-inbox.png',
    desc: 'Undated inbox — work without a scheduled time',
    scrollY: 900,
  },
  {
    file: '04-full-page.png',
    desc: 'Full page — month grid, day agenda, and inbox in one view',
    fullPage: true,
  },
];

async function main() {
  console.log('→ Starting stub API (scripts/stub_api.py)...');
  const stub = spawn('python3', ['scripts/stub_api.py'], {
    cwd: REPO,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  stub.stdout.on('data', d => process.stdout.write(`[stub] ${d}`));
  stub.stderr.on('data', d => process.stderr.write(`[stub] ${d}`));

  console.log('→ Serving build/web (python3 -m http.server 9474)...');
  const web = spawn('python3', ['-m', 'http.server', '9474', '--directory', 'build/web'], {
    cwd: REPO,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  web.stdout.on('data', d => process.stdout.write(`[web] ${d}`));
  web.stderr.on('data', d => process.stderr.write(`[web] ${d}`));

  let page = null;
  try {
    await Promise.all([waitForUrl(API_URL + '/diag'), waitForUrl(APP_URL + '/index.html')]);
    console.log('→ Both servers up.');

    const browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({
      viewport: { width: 390, height: 844 },
      deviceScaleFactor: 2,
      isMobile: true,
      hasTouch: true,
      colorScheme: 'light',
    });
    page = await context.newPage();

    console.log('→ Opening app...');
    await page.goto(APP_URL, { waitUntil: 'load', timeout: 60000 });

    console.log('→ Waiting for Flutter boot (≤15s)...');
    await waitForFlutterBoot(page);
    console.log('  Flutter is up.');

    // Confirm the app actually fetched data (the stub counts hits), then
    // give CanvasKit a moment to repaint before screenshotting.
    console.log('→ Waiting for app data from stub (≤20s)...');
    const gotData = await waitForAppData();
    if (!gotData) {
      console.log('  ⚠ /__stats reported no data yet — proceeding after a settle delay.');
    } else {
      console.log('  ✓ App fetched calendar data.');
    }
    await sleep(1500);

    for (const shot of SHOTS) {
      if (typeof shot.scrollY === 'number') {
        await page.mouse.wheel(0, shot.scrollY);
        await sleep(900);
      }
      await page.screenshot({
        path: path.join(SHOT_DIR, shot.file),
        fullPage: !!shot.fullPage,
      });
      console.log(`  ✓ ${shot.file}`);
      if (!shot.fullPage) await sleep(400);
    }

    // Scroll back to top so the full-page capture starts clean.
    await page.mouse.wheel(0, -5000);
    await sleep(800);

    await browser.close();
  } catch (err) {
    console.error('✗ Error during shoot:', err);
    try { await page.screenshot({ path: path.join(SHOT_DIR, '00-error.png') }); } catch (e) {}
    process.exit(1);
  } finally {
    stub.kill('SIGKILL');
    web.kill('SIGKILL');
  }

  // ── Regenerate README Screenshots section ──────────────────────────────
  const README = path.join(REPO, 'README.md');
  const BEGIN = '<!-- SCREENSHOTS-AUTO:BEGIN -->';
  const END = '<!-- SCREENSHOTS-AUTO:END -->';

  const lines = SHOTS.map(s => `| ![${s.file}](screenshots/${s.file}) | ${s.desc} |`);

  const section = [
    '## Screenshots',
    '',
    'Captured by CI (`.github/workflows/screenshots.yml`) with Playwright against a',
    'local stub API (`scripts/stub_api.py`) serving realistic November 2026 data.',
    'Viewport: 390×844, device scale 2×, CanvasKit renderer, Liquid Glass UI.',
    '',
    '| Screen | Description |',
    '|--------|-------------|',
    ...lines,
    '',
  ].join('\n');

  const markerBlock = `${BEGIN}\n${section}${END}`;
  let readme = fs.readFileSync(README, 'utf8');
  if (readme.includes(BEGIN) && readme.includes(END)) {
    readme = readme.replace(
      new RegExp(`${BEGIN}[\\s\\S]*?${END}`),
      markerBlock
    );
  } else {
    // Insert before the Architecture section, or append if not found.
    const anchor = readme.includes('## Architecture')
      ? '## Architecture'
      : '## Build';
    readme = readme.replace(anchor, markerBlock + '\n\n' + anchor);
  }
  fs.writeFileSync(README, readme, 'utf8');
  console.log('  ✓ README Screenshots section updated.');

  const files = fs.readdirSync(SHOT_DIR).filter(f => f.endsWith('.png')).sort();
  console.log(`→ ${files.length} screenshots captured: ${files.join(', ')}`);
  console.log('→ Done.');
}

main().catch(err => {
  console.error('FATAL:', err);
  process.exit(1);
});
