// Staff shell browser smoke check (SYNTHETIC data only).
//
// Drives a locally served release build of apps/staff, built against an
// already-running local API with the publishable key only, in Chromium:
//   - the tracer read shows the API value;
//   - browser Tab order starts at the named navigation tabs, and every focus
//     stop has a role and a name;
//   - keyboard-only: open Fixture command (focus stays on its tab), type an
//     intent key, Create; the
//     signed-out command is refused honestly ("sign-in required"), never
//     "Saved";
//   - narrow window (390 px) and 200% browser font size: compact layout, no
//     page-level horizontal scroll.
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
mkdirSync(OUT, { recursive: true });

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

async function active(page) {
  return page.evaluate(() => {
    const el = document.activeElement;
    if (!el || el === document.body) return { role: 'body', name: '' };
    return {
      role: el.getAttribute('role') ?? el.tagName.toLowerCase(),
      name: (el.getAttribute('aria-label') ?? el.textContent ?? '').trim().slice(0, 80),
    };
  });
}

const text = async (page, t, timeout = 15000) => {
  try {
    await page.getByText(t, { exact: false }).first().waitFor({ timeout });
    return true;
  } catch {
    return false;
  }
};

// S1–S4: desktop window.
{
  const { ctx, page, errors } = await open({ width: 1280, height: 800 });
  check('S1', 'tracer read shows the local API value', await text(page, 'Status: operational'));
  await page.screenshot({ path: path.join(OUT, '01-status.png') });

  const stops = [];
  for (let i = 0; i < 6; i++) {
    await page.keyboard.press('Tab');
    stops.push(await active(page));
  }
  check(
    'S2',
    'Tab starts at the named navigation tabs; every stop has a role and a name',
    stops[0].role === 'tab' &&
      /Platform status/.test(stops[0].name) &&
      stops[1].role === 'tab' &&
      /Fixture command/.test(stops[1].name) &&
      stops.every((s) => s.role !== 'body' && s.name.length > 0),
    { stops },
  );

  // Back to the Fixture tab, keyboard only.
  await page.keyboard.press('Shift+Tab');
  let guard = 0;
  while (!/Fixture command/.test((await active(page)).name) && guard++ < 10) {
    await page.keyboard.press('Shift+Tab');
  }
  await page.keyboard.press('Enter');
  const onFixture = await text(page, 'Create a counter');
  await page.waitForTimeout(500);
  const afterNav = await active(page);
  const fixtureStops = [];
  let typed = false;
  for (let i = 0; i < 12 && !typed; i++) {
    await page.keyboard.press('Tab');
    const a = await active(page);
    fixtureStops.push(a);
    if (/Intent key/.test(a.name)) {
      await page.keyboard.type('SYNTHETIC browser smoke');
      typed = true;
    }
  }
  await page.keyboard.press('Tab');
  const createStop = await active(page);
  await page.keyboard.press('Enter');
  const refused = await text(page, 'Not saved: sign-in required');
  const claimedSaved = await text(page, 'The server confirmed', 1500);
  check(
    'S3',
    'keyboard-only fixture command, signed out: refused honestly, never Saved',
    onFixture &&
      afterNav.role === 'tab' &&
      /Fixture command/.test(afterNav.name) &&
      typed &&
      /Create counter/.test(createStop.name) &&
      refused &&
      !claimedSaved,
    { afterNav, fixtureStops, createStop, refused, claimedSaved },
  );
  await page.screenshot({ path: path.join(OUT, '02-fixture-refused.png') });
  check('S4', 'no page errors (desktop)', errors.length === 0, { errors });
  await ctx.close();
}

// S5: narrow window and 200% browser font size.
for (const [id, label, viewport, fontPx] of [
  ['S5a', 'narrow 390 px window', { width: 390, height: 844 }, null],
  ['S5b', '200% browser font size', { width: 1280, height: 800 }, 32],
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
