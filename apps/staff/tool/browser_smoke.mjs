// Staff shell browser smoke check (SYNTHETIC data only).
//
// Drives a locally served release build of apps/staff, built against an
// already-running local API with the publishable key only, in Chromium:
//   S1  the tracer read shows the API value (recorded);
//   S2  browser Tab order: starts at the named navigation tabs, every stop
//       is unique with a role and a name, and Tab reaches the end of the page;
//   S3  focus visibility: every Tab stop shows a >=3:1 contrast change over
//       at least a 2 px perimeter area of its own box (1.6 C5 rule);
//   S4  keyboard-only: open Fixture command (focus stays on its tab), type an
//       intent key, Create; focus moves to the request-state banner, which
//       reports the signed-out refusal honestly ("sign-in required"), never
//       "Saved";
//   S5  no page errors;
//   S6  narrow window (390 px) and 200% browser font size: no page-level
//       horizontal scroll.
//
// Usage (see docs/runbooks/client-shells.md):
//   flutter build web --no-web-resources-cdn \
//     --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
//     --dart-define=SUPABASE_PUBLISHABLE_KEY=<local publishable key>
//   python3 -m http.server 8767 --bind 127.0.0.1 --directory build/web &
//   PLAYWRIGHT_MODULE=/opt/node22/lib/node_modules/playwright/index.mjs \
//     node tool/browser_smoke.mjs
//
// Env: STAFF_URL, EVIDENCE_DIR, PLAYWRIGHT_MODULE, CHROMIUM_EXECUTABLE.
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE ?? 'playwright');
const URL = process.env.STAFF_URL ?? 'http://127.0.0.1:8767/';
const OUT =
  process.env.EVIDENCE_DIR ??
  path.resolve(
    here,
    '../../../_bmad-output/initiative-church-app/epic-platform-baseline/evidence-1.7',
  );
mkdirSync(path.join(OUT, 'focus'), { recursive: true });

const results = [];
const check = (id, name, pass, detail = {}) => {
  results.push({ id, name, pass: !!pass, detail });
  console.log(`${pass ? 'PASS' : 'FAIL'} ${id} ${name}`);
};

const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM_EXECUTABLE || undefined,
  args: ['--enable-unsafe-swiftshader', '--use-gl=swiftshader'],
});

async function open(viewport, extra = {}) {
  // The sandbox reports navigator.language as en-US@posix, which Flutter
  // rejects; real browsers report a valid tag (1.6 finding 14).
  const ctx = await browser.newContext({ viewport, locale: 'en-GB', ...extra });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto(URL);
  await page.getByRole('tab', { name: 'Platform status' }).waitFor({ timeout: 60000 });
  return { ctx, page, errors };
}

/// The focused element: role, accessible name, box. `inApp` is false when
/// focus left the Flutter view (end of the page).
async function active(page) {
  return page.evaluate(() => {
    const el = document.activeElement;
    const inApp = !!el && el !== document.body && !!el.closest('flt-semantics-host, flutter-view');
    const r = el?.getBoundingClientRect();
    return {
      inApp,
      tag: el?.tagName ?? null,
      role: el?.getAttribute('role') ?? el?.tagName.toLowerCase() ?? null,
      name: (el?.getAttribute('aria-label') || (el?.tagName === 'FLUTTER-VIEW' ? '' : el?.textContent) || '')
        .trim().slice(0, 120),
      rect: r ? { x: r.x, y: r.y, width: r.width, height: r.height } : null,
    };
  });
}
const isStop = (a) => a.inApp && a.tag !== 'FLUTTER-VIEW';
const key = (a) => `${a.role}|${a.name}|${Math.round(a.rect?.x ?? 0)},${Math.round(a.rect?.y ?? 0)}`;

const text = async (page, t, timeout = 15000) => {
  try {
    await page.getByText(t, { exact: false }).first().waitFor({ timeout });
    return true;
  } catch {
    return false;
  }
};

// --- Focus visibility: pixel analysis in a browser canvas (as in 1.6 C5). ---
const imgCtx = await browser.newContext();
const imgPage = await imgCtx.newPage();
async function contrastChange(focusedPng, otherPng, clip) {
  return imgPage.evaluate(async ([a64, b64, clip]) => {
    const load = async (s) => createImageBitmap(await (await fetch('data:image/png;base64,' + s)).blob());
    const [ia, ib] = await Promise.all([load(a64), load(b64)]);
    const w = Math.min(ia.width, ib.width), h = Math.min(ia.height, ib.height);
    const px = (img) => { const c = new OffscreenCanvas(w, h); const g = c.getContext('2d'); g.drawImage(img, 0, 0); return g.getImageData(0, 0, w, h).data; };
    const da = px(ia), db = px(ib);
    const lin = (v) => { v /= 255; return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; };
    const lum = (d, i) => 0.2126 * lin(d[i]) + 0.7152 * lin(d[i + 1]) + 0.0722 * lin(d[i + 2]);
    const x0 = Math.max(0, Math.floor(clip.x)), y0 = Math.max(0, Math.floor(clip.y));
    const x1 = Math.min(w, Math.ceil(clip.x + clip.width)), y1 = Math.min(h, Math.ceil(clip.y + clip.height));
    let contrast3 = 0;
    for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
      const i = (y * w + x) * 4;
      const diff = Math.abs(da[i] - db[i]) + Math.abs(da[i + 1] - db[i + 1]) + Math.abs(da[i + 2] - db[i + 2]);
      if (diff <= 30) continue;
      const la = lum(da, i), lb = lum(db, i);
      if ((Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05) >= 3) contrast3++;
    }
    const crop = async (img) => {
      const c = new OffscreenCanvas(Math.max(1, x1 - x0), Math.max(1, y1 - y0));
      c.getContext('2d').drawImage(img, -x0, -y0);
      const b = await c.convertToBlob({ type: 'image/png' });
      return btoa(String.fromCharCode(...new Uint8Array(await b.arrayBuffer())));
    };
    return { contrast3, focusedCrop: await crop(ia), otherCrop: await crop(ib) };
  }, [focusedPng.toString('base64'), otherPng.toString('base64'), clip]);
}
const grow = (r, d) => ({ x: r.x - d, y: r.y - d, width: r.width + 2 * d, height: r.height + 2 * d });
const overlaps = (a, b) => a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;

/// Tabs through the page from the current focus until focus repeats or leaves
/// the app, recording each stop with a screenshot.
async function walk(page, max = 30) {
  const steps = [];
  const seen = new Set();
  let end = 'max';
  for (let i = 0; i < max; i++) {
    await page.keyboard.press('Tab');
    await page.waitForTimeout(150);
    const a = await active(page);
    if (!a.inApp) { end = 'left the page'; break; }
    if (!isStop(a)) continue;
    if (seen.has(key(a))) { end = `wrapped to ${a.role}: ${a.name}`; break; }
    seen.add(key(a));
    steps.push({ a, shot: await page.screenshot() });
  }
  return { steps, end };
}

const focusResults = [];
async function focusAudit(where, steps) {
  for (let k = 0; k < steps.length; k++) {
    const a = steps[k].a;
    const box = a.rect;
    const required = Math.round(2 * 2 * (box.width + box.height));
    let best = null;
    const order = steps.map((_, j) => j).filter((j) => j !== k)
      .sort((x, y) => Math.abs(x - k) - Math.abs(y - k));
    for (const j of order) {
      if (overlaps(grow(steps[j].a.rect, 10), grow(box, 10))) continue;
      best = { j, m: await contrastChange(steps[k].shot, steps[j].shot, grow(box, 8)) };
      break;
    }
    const n = String(focusResults.length + 1).padStart(2, '0');
    if (best) {
      writeFileSync(path.join(OUT, 'focus', `${n}-focused.png`), Buffer.from(best.m.focusedCrop, 'base64'));
      writeFileSync(path.join(OUT, 'focus', `${n}-unfocused.png`), Buffer.from(best.m.otherCrop, 'base64'));
    }
    focusResults.push({
      n, where, control: `${a.role}: ${a.name}`,
      requiredPixels: required, contrastChangePixels: best?.m.contrast3 ?? null,
      baseline: best ? `${steps[best.j].a.role}: ${steps[best.j].a.name}` : 'none',
      pass: !!best && best.m.contrast3 >= required,
    });
  }
}

// S1–S5: desktop window.
{
  const { ctx, page, errors } = await open({ width: 1280, height: 800 });
  const statusShown = await text(page, 'Status: operational');
  const statusValue = await page.evaluate(() =>
    [...document.querySelectorAll('flt-semantics, [aria-label]')]
      .map((e) => (e.getAttribute('aria-label') ?? e.textContent ?? '').trim())
      .filter((t) => /^Status: /.test(t))
      .slice(0, 1));
  check('S1', 'tracer read shows the local API value', statusShown && statusValue.length > 0, { statusValue });
  await page.screenshot({ path: path.join(OUT, '01-status.png') });

  const statusWalk = await walk(page);
  const stops = statusWalk.steps.map((s) => s.a);
  check(
    'S2',
    'Tab: named tabs first, every stop unique with a role and a name, reaches the end of the page',
    stops.length >= 3 &&
      stops[0].role === 'tab' && /Platform status/.test(stops[0].name) &&
      stops[1].role === 'tab' && /Fixture command/.test(stops[1].name) &&
      stops.every((s) => s.role && s.name.length > 0) &&
      new Set(stops.map(key)).size === stops.length &&
      statusWalk.end !== 'max',
    { stops: stops.map(({ role, name }) => ({ role, name })), end: statusWalk.end },
  );
  await focusAudit('platform status page', statusWalk.steps);

  // Keyboard only: go to the Fixture tab.
  await page.keyboard.press('Shift+Tab');
  let guard = 0;
  while (!/Fixture command/.test((await active(page)).name) && guard++ < 12) {
    await page.keyboard.press('Shift+Tab');
  }
  await page.keyboard.press('Enter');
  const onFixture = await text(page, 'Create a counter');
  await page.waitForTimeout(500);
  const afterNav = await active(page);

  const fixtureWalk = await walk(page);
  await focusAudit('fixture command page', fixtureWalk.steps);
  check(
    'S3',
    `every Tab stop shows a >=3:1 focus change over >= a 2 px perimeter area (${focusResults.length} controls)`,
    focusResults.length >= 6 && focusResults.every((r) => r.pass),
    { focusResults },
  );

  // Focus the intent field, type, Tab to Create, Enter.
  guard = 0;
  while (!/Intent key/.test((await active(page)).name) && guard++ < 15) {
    await page.keyboard.press('Tab');
  }
  await page.keyboard.type('SYNTHETIC browser smoke');
  await page.keyboard.press('Tab');
  const createStop = await active(page);
  await page.keyboard.press('Enter');
  const refused = await text(page, 'Not saved: sign-in required');
  await page.waitForTimeout(800);
  const afterSubmit = await active(page);
  const claimedSaved = await text(page, 'The server confirmed', 1500);
  check(
    'S4',
    'keyboard-only command, signed out: focus moves to the refusal banner; never Saved',
    onFixture &&
      afterNav.role === 'tab' && /Fixture command/.test(afterNav.name) &&
      /Create counter/.test(createStop.name) &&
      refused &&
      /^Not saved: sign-in required/.test(afterSubmit.name) &&
      !claimedSaved,
    {
      afterNav: { role: afterNav.role, name: afterNav.name },
      createStop: { role: createStop.role, name: createStop.name },
      afterSubmit: { role: afterSubmit.role, name: afterSubmit.name },
      refused, claimedSaved,
    },
  );
  await page.screenshot({ path: path.join(OUT, '02-fixture-refused.png') });
  check('S5', 'no page errors (desktop)', errors.length === 0, { errors });
  await ctx.close();
}

// S6: narrow window and 200% browser font size.
for (const [id, label, viewport, fontPx] of [
  ['S6a', 'narrow 390 px window', { width: 390, height: 844 }, null],
  ['S6b', '200% browser font size', { width: 1280, height: 800 }, 32],
]) {
  const { ctx, page, errors } = await open(viewport);
  if (fontPx) {
    // Flutter Web reads the text scale from the root font-size.
    await page.addStyleTag({ content: `html { font-size: ${fontPx}px !important; }` });
    await page.waitForTimeout(1500);
  }
  await page.getByRole('tab', { name: 'Fixture command' }).click();
  await text(page, 'Create a counter');
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth > window.innerWidth + 1,
  );
  check(id, `${label}: fixture screen renders, no page-level horizontal scroll`,
    !overflow && errors.length === 0, { overflow, errors });
  await page.screenshot({ path: path.join(OUT, `03-${id}.png`) });
  await ctx.close();
}

await browser.close();
const passed = results.filter((r) => r.pass).length;
writeFileSync(
  path.join(OUT, 'results.json'),
  JSON.stringify({ url: URL, passed, total: results.length, results }, null, 2),
);
console.log(`${passed}/${results.length} passed`);
process.exit(passed === results.length ? 0 : 1);
