// Q10 staff-web browser trial harness (disposable, SYNTHETIC data only).
//
// Drives a locally served release build of trials/staff_web in a real
// Chromium-family browser and records evidence: keyboard traversal, focus
// visibility (contrast of the focus change), roles/names from the browser
// accessibility tree (CDP), target sizes, real 200% browser zoom, 200% browser
// font size, CSV download content and a mobile-emulation smoke run.
//
// Usage (see trials/staff_web/README.md):
//   flutter build web --no-web-resources-cdn
//   python3 -m http.server 8766 --bind 127.0.0.1 --directory build/web &
//   PLAYWRIGHT_MODULE=/opt/node22/lib/node_modules/playwright/index.mjs \
//     node tool/browser_trial.mjs
//
// Env: TRIAL_URL, EVIDENCE_DIR, PLAYWRIGHT_MODULE, CHROMIUM_EXECUTABLE (a
// specific Chromium/Chrome build), BROWSER_LABEL (evidence sub-folder name).
//
// Every check has a `kind`:
//   desktop  — a real desktop browser window state (headless), no emulation.
//   emulated — device emulation (mobile viewport/touch/UA); never counted as a
//              pass for a real device in the matrix.
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const { chromium, devices } = await import(process.env.PLAYWRIGHT_MODULE ?? 'playwright');
const TRIAL_URL = process.env.TRIAL_URL ?? 'http://127.0.0.1:8766/';
const LABEL = process.env.BROWSER_LABEL ?? 'chromium';
const EXECUTABLE = process.env.CHROMIUM_EXECUTABLE || undefined;
const ROOT = process.env.EVIDENCE_DIR ??
  path.resolve(here, '../../../_bmad-output/initiative-church-app/epic-platform-baseline/evidence-1.6');
const OUT = path.join(ROOT, LABEL);
const GOLDEN = path.resolve(here, '../test/rota_trial/golden/door-export-after-edit.csv');
rmSync(OUT, { recursive: true, force: true });
mkdirSync(path.join(OUT, 'focus'), { recursive: true });

// The sandbox reports navigator.language as "en-US@posix", which Flutter
// rejects at start-up; real browsers report a BCP 47 tag, so pin one.
const LOCALE = 'en-GB';
const GL_ARGS = ['--enable-unsafe-swiftshader', '--use-gl=swiftshader'];
const LAUNCH = { executablePath: EXECUTABLE, args: GL_ARGS };
const DESKTOP = { width: 1366, height: 900 };
const MIN_TARGET = 44;
const STATUS = '(Confirmed|Confirmed by leader|Awaiting response|Needs contact|Declined|Draft|Unfilled)';
const SLOT_RE = new RegExp(`^(.+), (Sun \\d+ \\w+): (.+), ${STATUS}$`);
const INTERACTIVE = new Set(['button', 'tab', 'textbox', 'link', 'checkbox', 'radio', 'combobox', 'menuitem', 'option', 'switch', 'slider', 'menuitemradio']);

const checks = [];
const log = [];
function check(id, kind, name, pass, detail) {
  checks.push({ id, kind, name, result: pass ? 'pass' : 'fail', detail });
  console.log(`${pass ? 'PASS' : 'FAIL'} ${id} [${kind}] ${name}${pass ? '' : ' — ' + JSON.stringify(detail).slice(0, 600)}`);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const save = (name, data) => writeFileSync(path.join(OUT, name), typeof data === 'string' ? data : JSON.stringify(data, null, 2));

async function openApp(ctx, { before, page: given } = {}) {
  const page = given ?? await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  const cdp = await ctx.newCDPSession(page);
  if (before) await before(page, cdp);
  const t0 = Date.now();
  await page.goto(TRIAL_URL);
  await page.waitForSelector('flt-semantics[role="table"]', { state: 'attached', timeout: 90000 });
  const readyMs = Date.now() - t0;
  await sleep(1200);
  await cdp.send('Accessibility.enable');
  // Record every live-region announcement Flutter writes (it clears each one
  // after ~300 ms and may move its aria-live element into an open dialog).
  await page.evaluate(() => {
    window.__announcements = [];
    new MutationObserver(() => {
      for (const e of document.querySelectorAll('[aria-live]')) {
        const t = e.textContent.trim();
        if (t && window.__announcements.at(-1) !== t) window.__announcements.push(t);
      }
    }).observe(document.body, { subtree: true, childList: true, characterData: true });
  });
  return { page, cdp, readyMs, errors };
}

function axSummary(nodes) {
  return nodes.filter((n) => !n.ignored).map((n) => {
    const props = {};
    for (const p of n.properties ?? []) props[p.name] = p.value?.value;
    return { role: n.role?.value, name: n.name?.value ?? '', ...(Object.keys(props).length ? { props } : {}) };
  });
}
async function axTree(cdp) {
  const { nodes } = await cdp.send('Accessibility.getFullAXTree');
  return axSummary(nodes).filter((n) => !['InlineTextBox', 'generic', 'none'].includes(n.role) || n.name);
}
const count = (ax, role, re) => ax.filter((n) => n.role === role && (!re || re.test(n.name))).length;
const slotsIn = (ax) => ax.filter((n) => n.role === 'button' && SLOT_RE.test(n.name));

/// Interactive accessibility nodes with an empty name, across snapshots.
const unnamedLog = [];
function recordNames(where, ax) {
  for (const n of ax) {
    if ((INTERACTIVE.has(n.role) || /dialog|table|grid|list$/.test(n.role)) && !n.name.trim()) unnamedLog.push({ where, role: n.role });
  }
}
/// Visible interactive elements smaller than 44×44 CSS px, across states.
const smallTargets = [];
let targetStates = 0;
async function recordTargets(page, where) {
  targetStates++;
  const small = await page.evaluate(([min, roles]) => {
    const out = [];
    const vw = innerWidth, vh = innerHeight;
    const els = [...document.querySelectorAll('flt-semantics[role], input, textarea')];
    for (const e of els) {
      const role = e.getAttribute('role') ?? (e.tagName === 'INPUT' || e.tagName === 'TEXTAREA' ? 'textbox' : '');
      if (!roles.includes(role)) continue;
      const box = (e.tagName === 'INPUT' || e.tagName === 'TEXTAREA') ? (e.closest('flt-semantics') ?? e) : e;
      const r = box.getBoundingClientRect();
      if (r.right <= 0 || r.bottom <= 0 || r.left >= vw || r.top >= vh || r.width === 0) continue;
      if (r.left < 0 || r.right > vw || r.top < 0 || r.bottom > vh) continue; // partly scrolled out
      if (r.width < min - 0.5 || r.height < min - 0.5) {
        out.push({ role, name: (e.getAttribute('aria-label') ?? e.textContent ?? '').trim().slice(0, 60), w: Math.round(r.width), h: Math.round(r.height) });
      }
    }
    return out;
  }, [MIN_TARGET, [...INTERACTIVE]]);
  for (const s of small) smallTargets.push({ where, ...s });
}

/// The focused element as the accessibility tree reports it, plus its DOM tag
/// and on-screen rectangle.
async function active(page, cdp) {
  const { result } = await cdp.send('Runtime.evaluate', { expression: 'document.activeElement' });
  const ax = await cdp.send('Accessibility.getPartialAXTree', { objectId: result.objectId, fetchRelatives: false });
  const n = axSummary(ax.nodes)[0] ?? {};
  const dom = await page.evaluate(() => {
    const e = document.activeElement;
    const box = (e.tagName === 'INPUT' || e.tagName === 'TEXTAREA') ? (e.closest('flt-semantics') ?? e) : e;
    const r = box.getBoundingClientRect();
    return { tag: e.tagName, rect: { x: r.x, y: r.y, width: r.width, height: r.height } };
  });
  return { role: n.role, name: n.name, props: n.props, ...dom };
}
async function press(page, cdp, key, note) {
  await page.keyboard.press(key);
  await sleep(350);
  const a = await active(page, cdp);
  log.push({ key, note, role: a.role, name: a.name, tag: a.tag });
  return a;
}
const isApp = (a) => a.tag !== 'BODY' && a.tag !== 'FLUTTER-VIEW' && a.tag !== 'HTML';
async function until(page, cdp, key, test, max, note) {
  let a = await active(page, cdp);
  for (let i = 0; i < max && !test(a); i++) a = await press(page, cdp, key, note);
  return a;
}
const named = (re) => (a) => re.test(a.name ?? '');

/// Choose [option] in the dropdown whose accessible name matches [fieldRe],
/// by keyboard only (Tab/Shift+Tab to the field, Enter, arrows, Enter).
async function pickOption(page, cdp, fieldRe, option, tabKey = 'Tab') {
  let a = await until(page, cdp, tabKey, named(fieldRe), 16, `to ${fieldRe}`);
  a = await press(page, cdp, 'Enter', 'open menu');
  for (let i = 0; i < 14 && a.name !== option; i++) a = await press(page, cdp, 'ArrowDown', `find ${option}`);
  for (let i = 0; i < 14 && a.name !== option; i++) a = await press(page, cdp, 'ArrowUp', `find ${option}`);
  const found = a.name === option;
  a = await press(page, cdp, 'Enter', `choose ${option}`);
  await sleep(300);
  return { found, a };
}

// --- Pixel analysis in a browser canvas (no extra npm packages). ---
let imgPage;
async function analyse(focusedPng, otherPng, clip, ignore) {
  return imgPage.evaluate(async ([a64, b64, clip, ignore]) => {
    const load = async (s) => createImageBitmap(await (await fetch('data:image/png;base64,' + s)).blob());
    const [ia, ib] = await Promise.all([load(a64), load(b64)]);
    const w = Math.min(ia.width, ib.width), h = Math.min(ia.height, ib.height);
    const px = (img) => { const c = new OffscreenCanvas(w, h); const g = c.getContext('2d'); g.drawImage(img, 0, 0); return g.getImageData(0, 0, w, h).data; };
    const da = px(ia), db = px(ib);
    const lin = (v) => { v /= 255; return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; };
    const lum = (d, i) => 0.2126 * lin(d[i]) + 0.7152 * lin(d[i + 1]) + 0.0722 * lin(d[i + 2]);
    let changedWhole = 0, contrast3 = 0;
    const inside = (x, y, r) => x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height;
    const x0 = Math.max(0, Math.floor(clip.x)), y0 = Math.max(0, Math.floor(clip.y));
    const x1 = Math.min(w, Math.ceil(clip.x + clip.width)), y1 = Math.min(h, Math.ceil(clip.y + clip.height));
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4;
      const diff = Math.abs(da[i] - db[i]) + Math.abs(da[i + 1] - db[i + 1]) + Math.abs(da[i + 2] - db[i + 2]);
      if (diff > 30 && !ignore.some((r) => inside(x, y, r))) changedWhole++;
      if (x >= x0 && x < x1 && y >= y0 && y < y1 && diff > 30) {
        const la = lum(da, i), lb = lum(db, i);
        if ((Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05) >= 3) contrast3++;
      }
    }
    const crop = async (img) => {
      const c = new OffscreenCanvas(x1 - x0, y1 - y0);
      c.getContext('2d').drawImage(img, -x0, -y0);
      const b = await c.convertToBlob({ type: 'image/png' });
      return btoa(String.fromCharCode(...new Uint8Array(await b.arrayBuffer())));
    };
    return { changedWhole: changedWhole / (w * h), contrast3, focusedCrop: await crop(ia), otherCrop: await crop(ib) };
  }, [focusedPng.toString('base64'), otherPng.toString('base64'), clip, ignore]);
}
const grow = (r, d) => ({ x: r.x - d, y: r.y - d, width: r.width + 2 * d, height: r.height + 2 * d });
const overlaps = (a, b) => a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;

/// Focus visibility, per control: the focused state must differ from an
/// unfocused state of the same screen by a ≥3:1 contrast change over at least
/// the area of a 2 CSS px perimeter of the control (WCAG 2.2 SC 2.4.13 area
/// rule). The unfocused baseline is another step of the same walk in which
/// focus sat on a control whose box (+10 px) does not touch this one — so a
/// neighbour's ring cannot count — and the rest of the screen outside the two
/// controls is unchanged (<0.5% of pixels differ), so a scroll or re-layout
/// cannot count either.
const focusResults = [];
async function focusAudit(page, cdp, where, key, max, stop, { skipLast = false } = {}) {
  const steps = [{ a: await active(page, cdp), shot: await page.screenshot() }];
  for (let i = 0; i < max; i++) {
    const a = await press(page, cdp, key, `focus audit: ${where}`);
    steps.push({ a, shot: await page.screenshot() });
    if (stop?.(a, steps)) break;
  }
  const vp = page.viewportSize() ?? DESKTOP;
  // skipLast: the final step only provides a baseline (e.g. the page has
  // scrolled for the next control, so the last one has no stable partner).
  for (let k = 0; k < steps.length - (skipLast ? 1 : 0); k++) {
    const a = steps[k].a;
    // Only interactive controls; a route's programmatic focus on its heading
    // (tabindex -1) is not a keyboard stop.
    if (!isApp(a) || !INTERACTIVE.has(a.role)) continue;
    const control = `${a.role}: ${a.name}`;
    if (focusResults.some((r) => r.where === where && r.control === control)) continue;
    const box = a.rect;
    const clip = grow(box, 8);
    const required = Math.round(2 * 2 * (box.width + box.height));
    let best = null;
    const order = steps.map((_, j) => j).filter((j) => j !== k).sort((x, y) => Math.abs(x - k) - Math.abs(y - k));
    for (const j of order) {
      const b = steps[j].a;
      if (isApp(b) && overlaps(grow(b.rect, 10), grow(box, 10))) continue;
      const m = await analyse(steps[k].shot, steps[j].shot, clip, [grow(box, 10), ...(isApp(b) ? [grow(b.rect, 10)] : [])]);
      if (m.changedWhole > 0.005) continue;
      best = { j, m };
      break;
    }
    const n = focusResults.length + 1;
    if (best) {
      writeFileSync(path.join(OUT, 'focus', `${String(n).padStart(2, '0')}-focused.png`), Buffer.from(best.m.focusedCrop, 'base64'));
      writeFileSync(path.join(OUT, 'focus', `${String(n).padStart(2, '0')}-unfocused.png`), Buffer.from(best.m.otherCrop, 'base64'));
    }
    focusResults.push({
      n, where, control, box: { w: Math.round(box.width), h: Math.round(box.height) },
      requiredPixels: required, contrastChangePixels: best?.m.contrast3 ?? null,
      baseline: best ? `step ${best.j} (${steps[best.j].a.role}: ${steps[best.j].a.name ?? '—'})` : 'no stable non-adjacent baseline',
      pass: !!best && best.m.contrast3 >= required && vp.width > 0,
    });
  }
  return steps.map((s) => s.a);
}

// ------------------------------------------------------------- desktop run
async function desktopRun(browser) {
  const ctx = await browser.newContext({ viewport: DESKTOP, locale: LOCALE, acceptDownloads: true });
  const { page, cdp, readyMs, errors } = await openApp(ctx);
  await page.screenshot({ path: path.join(OUT, '01-desktop-grid.png') });

  // C1–C2: accessibility tree of the grid page.
  let ax = await axTree(cdp);
  save('ax-tree-desktop-grid.json', ax);
  recordNames('grid page', ax);
  await recordTargets(page, 'grid page');
  check('C1', 'desktop', 'semantics tree present without a user "enable accessibility" step', count(ax, 'table') === 1, { readyMs });
  const table = ax.find((n) => n.role === 'table');
  const headers = ax.filter((n) => n.role === 'columnheader').map((n) => n.name);
  check('C2a', 'desktop', 'grid is a named table with row/columnheader/cell roles',
    table?.name === 'Ushering rota: positions by Sunday' && count(ax, 'row') === 7 && headers.length === 9 && count(ax, 'cell') >= 54,
    { table, rows: count(ax, 'row'), headers, cells: count(ax, 'cell') });
  check('C2b', 'desktop', 'all 48 slots are buttons named "position, date: member, status"', slotsIn(ax).length === 48, { slots: slotsIn(ax).length });
  const h1 = ax.find((n) => n.role === 'heading' && n.name === 'Duty rotas');
  check('C2c', 'desktop', 'heading, filters, view radios, export and tabs are named',
    h1?.props?.level === 1 && count(ax, 'textbox', /^Filter positions/) === 1 && ax.some((n) => /Filter by status/.test(n.name) && INTERACTIVE.has(n.role)) &&
    count(ax, 'button', /^Export CSV/) === 1 && count(ax, 'tab') === 2 && count(ax, 'tablist') === 1, { h1 });
  const toggles = ax.filter((n) => /^(Grid|List)$/.test(n.name));
  check('C2d', 'desktop', 'view toggle exposes the selected view (radio group, checked)',
    toggles.length === 2 && toggles.every((t) => t.role === 'radio') && toggles.find((t) => t.name === 'Grid')?.props?.checked === 'true' &&
    toggles.find((t) => t.name === 'List')?.props?.checked === 'false' && count(ax, 'radiogroup', /^View$/) === 1, { toggles });

  // C4/C5: Tab order and focus visibility on the page.
  const seq = (await focusAudit(page, cdp, 'page Tab order', 'Tab', 12, (a) => !isApp(a))).slice(1).filter(isApp);
  const names = seq.map((a) => `${a.role}: ${a.name}`);
  const expectOrder = [/^tab: Rota grid trial$/, /^tab: Platform status$/, /^textbox: Filter positions/, /Filter by status/, /^radio: Grid$/, /^radio: List$/, /^button: Export CSV/, /^button: Main door, Sun 4 Oct: /];
  check('C4a', 'desktop', 'Tab reaches every control in visual order and DOM focus follows (never <body> inside the app)',
    expectOrder.every((re, i) => re.test(names[i] ?? '')) && names.length === expectOrder.length, { names });
  check('C4b', 'desktop', 'the grid is a single Tab stop (roving focus)', seq.filter((a) => SLOT_RE.test(a.name ?? '')).length === 1, { names });
  check('C4c', 'desktop', 'every focused control has a role and a non-empty name', seq.every((a) => a.role && a.name), { names });

  // C6: grid keys including all four edges.
  let a = await press(page, cdp, 'Shift+Tab', 'back into grid');
  const back = /^Main door, Sun 4 Oct: /.test(a.name ?? '');
  const moves = [
    ['ArrowLeft', /^Main door, Sun 4 Oct: /, 'left edge'], ['ArrowUp', /^Main door, Sun 4 Oct: /, 'top edge'],
    ['ArrowRight', /^Main door, Sun 11 Oct: /], ['ArrowDown', /^Side door, Sun 11 Oct: /],
    ['End', /^Side door, Sun 22 Nov: /], ['ArrowRight', /^Side door, Sun 22 Nov: /, 'right edge'],
    ['Control+End', /^Children's door, Sun 22 Nov: /], ['ArrowDown', /^Children's door, Sun 22 Nov: /, 'bottom edge'],
    ['Home', /^Children's door, Sun 4 Oct: /], ['Control+Home', /^Main door, Sun 4 Oct: /],
  ];
  const moveLog = [];
  let movesOk = back;
  for (const [key, re, note] of moves) {
    a = await press(page, cdp, key, 'grid navigation');
    const inView = a.rect.x >= 0 && a.rect.x + a.rect.width <= DESKTOP.width;
    moveLog.push({ key, note, got: a.name, ok: re.test(a.name ?? ''), inView });
    movesOk &&= re.test(a.name ?? '') && inView;
  }
  check('C6', 'desktop', 'arrows/Home/End/Control move slot by slot, clamp at all four edges, scroll into view', movesOk, { back, moveLog });

  // C7: slot dialog — naming, focus audit, cancel paths, then a real edit.
  const slotName = async () => slotsIn(await axTree(cdp)).find((n) => /^Main door, Sun 4 Oct: /.test(n.name))?.name;
  const before = await slotName();
  a = await press(page, cdp, 'Enter', 'open slot');
  ax = await axTree(cdp);
  save('ax-tree-desktop-slot-dialog.json', ax);
  recordNames('slot dialog', ax);
  await recordTargets(page, 'slot dialog');
  await page.screenshot({ path: path.join(OUT, '02-desktop-slot-dialog.png') });
  const dlg = ax.find((n) => /dialog/.test(n.role));
  check('C7a', 'desktop', 'slot dialog is role "dialog" named by its title', dlg?.role === 'dialog' && dlg?.name === 'Main door — Sun 4 Oct', { dlg });
  await focusAudit(page, cdp, 'slot dialog', 'Tab', 6, (x, s) => s.filter((y) => y.a.name === x.name).length > 1);
  // Status menu: open it and walk the options.
  a = await until(page, cdp, 'Tab', named(/Status/), 6, 'to Status');
  a = await press(page, cdp, 'Enter', 'open status menu');
  ax = await axTree(cdp);
  save('ax-tree-desktop-status-menu.json', ax);
  recordNames('status menu', ax);
  await recordTargets(page, 'status menu');
  await page.screenshot({ path: path.join(OUT, '03-desktop-status-menu.png') });
  await focusAudit(page, cdp, 'status menu options', 'ArrowDown', 6);
  a = await press(page, cdp, 'Escape', 'close menu');

  // Change member and status, then Escape: nothing changes.
  const editBoth = async () => {
    await pickOption(page, cdp, /Member/, 'Test Ruth D', 'Shift+Tab');
    await pickOption(page, cdp, /Status/, 'Needs contact');
  };
  await editBoth();
  const editedInDialog = JSON.stringify(await axTree(cdp));
  const dialogShowedEdit = /Test Ruth D/.test(editedInDialog) && /Needs contact/.test(editedInDialog);
  a = await press(page, cdp, 'Escape', 'Escape after editing');
  await sleep(400);
  const afterEscape = await slotName();
  const focusAfterEscape = a.name;
  // Reopen, change both, Cancel.
  a = await press(page, cdp, 'Enter', 'reopen slot');
  await editBoth();
  a = await until(page, cdp, 'Tab', (x) => x.name === 'Cancel', 6, 'to Cancel');
  a = await press(page, cdp, 'Enter', 'Cancel after editing');
  await sleep(400);
  const afterCancel = await slotName();
  check('C7b', 'desktop', 'changing member and status then Escape or Cancel leaves the slot unchanged and restores focus',
    dialogShowedEdit && afterEscape === before && afterCancel === before && focusAfterEscape === before && a.name === before,
    { before, dialogShowedEdit, afterEscape, afterCancel, focusAfterEscape, focusAfterCancel: a.name });

  // The real edit: status → Declined, Save.
  a = await press(page, cdp, 'Enter', 'open slot to edit');
  await pickOption(page, cdp, /Status/, 'Declined');
  a = await until(page, cdp, 'Tab', (x) => x.name === 'Save', 6, 'to Save');
  a = await press(page, cdp, 'Enter', 'Save');
  await sleep(900);
  a = await active(page, cdp);
  const live = await page.evaluate(() => window.__announcements.join(' | '));
  const saved = await slotName();
  check('C7c', 'desktop', 'keyboard-only edit saves, focus returns to the slot, and the change is announced politely',
    /, Declined$/.test(saved ?? '') && a.name === saved && /Saved\. Main door, Sun 4 Oct: .+, Declined\./.test(live), { saved, focus: a.name, live });
  await page.screenshot({ path: path.join(OUT, '04-desktop-after-edit.png') });

  // C8: status filter, empty result, position filter.
  await pickOption(page, cdp, /Filter by status/, 'Unfilled', 'Shift+Tab');
  ax = await axTree(cdp);
  save('ax-tree-desktop-status-filter-unfilled.json', ax);
  const shown = slotsIn(ax);
  const hidden = [...new Set(ax.filter((n) => /: hidden by status filter$/.test(n.name)).map((n) => n.name))];
  await page.screenshot({ path: path.join(OUT, '05-desktop-status-filter.png') });
  check('C8a', 'desktop', 'status filter shows only matching slots; others are labelled "hidden by status filter"',
    shown.length > 0 && shown.every((n) => /, Unfilled$/.test(n.name)) && hidden.length > 0 && shown.length + hidden.length === (count(ax, 'row') - 1) * 8,
    { shown: shown.length, hidden: hidden.length, rows: count(ax, 'row') });
  a = await until(page, cdp, 'Shift+Tab', named(/^Filter positions/), 6, 'to position filter');
  await page.keyboard.type('Main door');
  await sleep(300);
  await pickOption(page, cdp, /Filter by status/, 'Draft');
  await sleep(400);
  ax = await axTree(cdp);
  const exportNode = ax.find((n) => n.role === 'button' && /^Export CSV/.test(n.name));
  await page.screenshot({ path: path.join(OUT, '06-desktop-empty-filter.png') });
  check('C8b', 'desktop', 'filters matching no slot show "No slots match" and disable export with a reason',
    ax.some((n) => /^No slots match/.test(n.name)) && exportNode?.props?.disabled === true && ax.some((n) => /Nothing to export/.test(n.name)) && slotsIn(ax).length === 0,
    { exportNode });
  await pickOption(page, cdp, /Filter by status/, 'All statuses');
  a = await until(page, cdp, 'Shift+Tab', named(/^Filter positions/), 6, 'to position filter');
  await page.keyboard.press('Control+A');
  await page.keyboard.type('door');
  await sleep(400);
  ax = await axTree(cdp);
  const doorSlots = slotsIn(ax);
  check('C8c', 'desktop', 'position filter narrows the grid to matching rows', count(ax, 'row') === 4 && doorSlots.length === 24, { rows: count(ax, 'row') });

  // C9: export dialog, preview, focus audit, download.
  a = await until(page, cdp, 'Tab', named(/^Export CSV/), 6, 'to export');
  a = await press(page, cdp, 'Enter', 'open export');
  ax = await axTree(cdp);
  save('ax-tree-desktop-export-dialog.json', ax);
  recordNames('export dialog', ax);
  await recordTargets(page, 'export dialog');
  await page.screenshot({ path: path.join(OUT, '07-desktop-export-preview.png') });
  const edlg = ax.find((n) => /dialog/.test(n.role));
  const text = ax.map((n) => n.name).join('\n');
  const preview = ax.find((n) => /^"Date","Position"/.test(n.name))?.name ?? '';
  check('C9a', 'desktop', 'export dialog is a named "dialog"; preview states scope, columns, exclusions, warning; preview has no private field',
    edlg?.role === 'dialog' && edlg?.name === 'Export rota CSV' && /Scope: 24 rows — positions: matching “door”; status: all/.test(text) &&
    /Not included: phone numbers and care notes/.test(text) && /outside the app’s access/.test(text) && preview.length > 0 && !/\+260|care note/i.test(preview),
    { edlg, preview });
  await focusAudit(page, cdp, 'export dialog', 'Tab', 4, (x, s) => s.filter((y) => y.a.name === x.name).length > 1);
  a = await until(page, cdp, 'Tab', (x) => x.name === 'Download CSV', 6, 'to Download');
  const [download] = await Promise.all([page.waitForEvent('download', { timeout: 15000 }), press(page, cdp, 'Enter', 'download')]);
  const csvPath = path.join(OUT, 'rota-export-door-filter.csv');
  await download.saveAs(csvPath);
  await sleep(700);
  const bytes = readFileSync(csvPath);
  const textCsv = bytes.toString('utf8');
  const rows = parseCsv(textCsv.replace(/^﻿/, ''));
  const body = rows.slice(1);
  const fields = body.flat();
  // Cross-check Member and Status against what the grid exposed for the same slots.
  const labelOf = (iso) => { const d = new Date(iso + 'T12:00:00Z'); return `Sun ${d.getUTCDate()} ${d.toLocaleString('en-GB', { month: 'short', timeZone: 'UTC' })}`; };
  const gridBySlot = Object.fromEntries(doorSlots.map((n) => { const m = SLOT_RE.exec(n.name); return [`${m[1]}|${m[2]}`, { member: m[3], status: m[4] }]; }));
  const mismatches = body.filter((r) => {
    const g = gridBySlot[`${r[1]}|${labelOf(r[0])}`];
    const norm = (v) => v.replace(/\s+/g, ' ').trim();
    const member = norm(r[2].replace(/^'/, '')) || 'no one assigned';
    return !g || norm(g.member) !== member || g.status !== r[3];
  });
  const golden = readFileSync(GOLDEN);
  const csvChecks = {
    filename: download.suggestedFilename(),
    bom: bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf,
    crlfRows: (textCsv.match(/\r\n/g) ?? []).length,
    header: rows[0], rows: body.length, columnsPerRow: [...new Set(body.map((r) => r.length))],
    identicalToGolden: bytes.equals(golden),
    memberStatusMismatchesVsGrid: mismatches,
    rawTriggerFields: fields.filter((f) => /^\s*[=+\-@\t\r]/.test(f)),
    neutralisedFields: fields.filter((f) => /^'\s*[=+\-@\t\r]/.test(f)),
    privateLeak: /\+260|care note/i.test(textCsv),
    editedSlot: body.find((r) => r[0] === '2026-10-04' && r[1] === 'Main door'),
  };
  save('csv-checks.json', csvChecks);
  const triggerKinds = ['=', '+', '-', '@', '\t', '\r', ' '].filter((t) => csvChecks.neutralisedFields.some((f) => f[1] === t));
  check('C9b', 'desktop', 'CSV: BOM, CRLF, allowlisted header, 24×5, and every Member/Status/Note equals the app state (golden file + grid names)',
    csvChecks.bom && JSON.stringify(rows[0]) === JSON.stringify(['Date', 'Position', 'Member', 'Status', 'Note']) && body.length === 24 &&
    csvChecks.columnsPerRow.join() === '5' && csvChecks.crlfRows === 25 && csvChecks.identicalToGolden && mismatches.length === 0,
    { identicalToGolden: csvChecks.identicalToGolden, mismatches });
  check('C9c', 'desktop', 'formula-led values (=, +, -, @, tab, CR, and space-led) are neutralised; none start raw',
    csvChecks.rawTriggerFields.length === 0 && triggerKinds.length === 7, { triggerKinds, raw: csvChecks.rawTriggerFields });
  check('C9d', 'desktop', 'no private field (phone, care note) in the file', !csvChecks.privateLeak, {});
  const live2 = await page.evaluate(() => window.__announcements.join(' | '));
  check('C9e', 'desktop', 'announces "Download started: <file> (24 rows)" rather than claiming the save finished',
    /Download started: bic-kafue-rota-trial-SYNTHETIC\.csv \(24 rows\)\./.test(live2) && !/Downloaded/.test(live2), { live: live2 });

  // C10: list alternative, and the edit shown there too.
  a = await until(page, cdp, 'Shift+Tab', named(/^Filter positions/), 8, 'to filter');
  await page.keyboard.press('Control+A');
  await page.keyboard.press('Backspace');
  await sleep(400);
  a = await until(page, cdp, 'Tab', (x) => x.name === 'List', 6, 'to List');
  a = await press(page, cdp, 'Space', 'switch to list');
  await sleep(500);
  ax = await axTree(cdp);
  save('ax-tree-desktop-list.json', ax);
  recordNames('list view', ax);
  await recordTargets(page, 'list view');
  await page.screenshot({ path: path.join(OUT, '08-desktop-list.png'), fullPage: true });
  const changeButtons = ax.filter((n) => n.role === 'button' && /^Change .+, Sun \d+ \w+$/.test(n.name));
  check('C10a', 'desktop', 'list view: 6 named lists of 48 items, 48 named Change buttons, level-2 headings',
    count(ax, 'list') === 6 && count(ax, 'listitem') === 48 && changeButtons.length === 48 &&
    ax.filter((n) => n.role === 'heading' && n.props?.level === 2 && !/staff web trial/.test(n.name)).length === 6,
    { lists: count(ax, 'list'), items: count(ax, 'listitem'), change: changeButtons.length });
  const listItemText = await page.evaluate(() => {
    const e = document.querySelector('[role="listitem"]');
    return e ? [e, ...e.querySelectorAll('*')].map((x) => x.getAttribute('aria-label') ?? (x.children.length ? '' : x.textContent)).filter(Boolean).join(' | ') : '';
  });
  check('C10b', 'desktop', 'the Declined edit shows in grid, list and CSV alike',
    /, Declined$/.test(saved ?? '') && /Sun 4 Oct/.test(listItemText) && /Declined/.test(listItemText) && csvChecks.editedSlot?.[3] === 'Declined',
    { grid: saved, list: listItemText, csv: csvChecks.editedSlot });
  // Focus audit over a sample of list Change buttons (the first 6 of 48).
  // A taller window for this walk so that Tab does not scroll the page
  // between steps (a scroll would leave no same-layout unfocused baseline).
  await page.setViewportSize({ width: DESKTOP.width, height: 2400 });
  await sleep(800);
  await focusAudit(page, cdp, 'list Change buttons (first 6 of 48)', 'Tab', 8, (x, s) => s.filter((y) => /^Change /.test(y.a.name ?? '')).length >= 6);
  await page.setViewportSize(DESKTOP);
  await sleep(800);
  a = await until(page, cdp, 'Shift+Tab', named(/^Change Main door, Sun 4 Oct$/), 8, 'to first Change');
  const firstChange = a.name;
  a = await press(page, cdp, 'Enter', 'open from list');
  const listDialog = (await axTree(cdp)).find((n) => n.role === 'dialog');
  a = await press(page, cdp, 'Escape', 'close');
  check('C10c', 'desktop', 'list Change opens the same named slot dialog by keyboard; Escape restores focus',
    firstChange === 'Change Main door, Sun 4 Oct' && listDialog?.name === 'Main door — Sun 4 Oct' && a.name === firstChange, { firstChange, listDialog, focusAfter: a.name });

  // Aggregates.
  save('focus-visibility.json', focusResults);
  const failedFocus = focusResults.filter((r) => !r.pass);
  const audited = [...new Set(focusResults.map((r) => r.where))];
  check('C5', 'desktop', `every audited focused control shows a ≥3:1 focus change over ≥ a 2 px perimeter area of its own box (${focusResults.length} controls: ${audited.join('; ')})`,
    failedFocus.length === 0 && focusResults.length >= 20, { failed: failedFocus });
  check('C3', 'desktop', 'every interactive node, table, list and dialog has a non-empty accessible name (grid page, slot dialog, status menu, export dialog, list view)',
    unnamedLog.length === 0, { unnamed: unnamedLog });
  check('C14', 'desktop', `every visible interactive target is at least ${MIN_TARGET}×${MIN_TARGET} CSS px (${targetStates} screen states)`,
    smallTargets.length === 0, { small: smallTargets });
  save('keyboard-log-desktop.json', log);
  check('C0', 'desktop', 'no page errors during the desktop run', errors.length === 0, { errors });
  await ctx.close();
  return { readyMs };
}

/// RFC 4180 parser for the evidence check (quoted fields, doubled quotes).
function parseCsv(s) {
  const rows = []; let row = []; let f = ''; let q = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) {
      if (c === '"') { if (s[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += c;
    } else if (c === '"') q = true;
    else if (c === ',') { row.push(f); f = ''; }
    else if (c === '\r' && s[i + 1] === '\n') { row.push(f); rows.push(row); row = []; f = ''; i++; }
    else f += c;
  }
  if (f || row.length) { row.push(f); rows.push(row); }
  return rows;
}

/// Layout and dialog checks for a scaled (zoom or font-size) state.
async function scaledChecks(page, cdp, prefix) {
  const vp = await page.evaluate(() => ({ width: innerWidth, height: innerHeight, dpr: devicePixelRatio, rootFontSize: getComputedStyle(document.documentElement).fontSize }));
  const ax = await axTree(cdp);
  const geometry = async () => page.evaluate(() => {
    const vw = innerWidth;
    // Text boxes cut by the window edge, outside the grid's own scroller.
    const cut = [];
    for (const e of document.querySelectorAll('flt-semantics')) {
      if (e.children.length && [...e.children].some((c) => c.tagName === 'FLT-SEMANTICS' || c.tagName === 'FLT-SEMANTICS-CONTAINER')) continue;
      const t = (e.getAttribute('aria-label') ?? e.textContent ?? '').trim();
      if (!t) continue;
      if (e.closest('[role="table"]')) continue;
      const r = e.getBoundingClientRect();
      if (r.width === 0) continue;
      if (r.left < -0.5 || r.right > vw + 0.5) cut.push({ t: t.slice(0, 50), left: Math.round(r.left), right: Math.round(r.right) });
    }
    return { cut, pageScrollsHorizontally: document.documentElement.scrollWidth > document.documentElement.clientWidth };
  });
  const g = await geometry();
  await page.screenshot({ path: path.join(OUT, `${prefix}-1-grid.png`) });
  // Reach the far grid column by keyboard: it must scroll into view.
  let a = await until(page, cdp, 'Tab', (x) => SLOT_RE.test(x.name ?? ''), 12, `${prefix} to grid`);
  a = await press(page, cdp, 'End', `${prefix} grid end`);
  const farVisible = /Sun 22 Nov/.test(a.name ?? '') && a.rect.x >= 0 && a.rect.x + a.rect.width <= vp.width + 0.5;
  await page.screenshot({ path: path.join(OUT, `${prefix}-2-grid-end.png`) });
  // Slot dialog at this scale.
  a = await press(page, cdp, 'Enter', `${prefix} open slot`);
  await sleep(400);
  const slotDlg = await dialogFits(page, cdp, `${prefix}-3-slot-dialog`);
  a = await press(page, cdp, 'Escape', `${prefix} close slot`);
  // Export dialog at this scale.
  a = await until(page, cdp, 'Shift+Tab', named(/^Export CSV/), 10, `${prefix} to export`);
  a = await press(page, cdp, 'Enter', `${prefix} open export`);
  await sleep(400);
  const exportDlg = await dialogFits(page, cdp, `${prefix}-4-export-dialog`);
  a = await press(page, cdp, 'Escape', `${prefix} close export`);
  // List view.
  a = await until(page, cdp, 'Shift+Tab', (x) => x.name === 'List', 6, `${prefix} to List`);
  a = await press(page, cdp, 'Space', `${prefix} list view`);
  await sleep(500);
  const listLayout = await page.evaluate(() => [...document.querySelectorAll('[role="listitem"]')].map((e) => { const r = e.getBoundingClientRect(); return { x: r.x, right: r.right }; }));
  const gl = await geometry();
  await page.screenshot({ path: path.join(OUT, `${prefix}-5-list.png`) });
  const listInside = listLayout.length === 48 && listLayout.every((r) => r.x >= 0 && r.right <= vp.width + 0.5);
  return { vp, slots: slotsIn(ax).length, gridCut: g.cut, listCut: gl.cut, pageScrollsHorizontally: g.pageScrollsHorizontally || gl.pageScrollsHorizontally, farVisible, slotDlg, exportDlg, listInside };
}
/// A dialog fits when it is inside the window horizontally, every named
/// control in it is exposed, and no text box in it is cut by its edge.
async function dialogFits(page, cdp, shot) {
  await page.screenshot({ path: path.join(OUT, `${shot}.png`) });
  const ax = await axTree(cdp);
  const dlg = ax.find((n) => n.role === 'dialog');
  const geo = await page.evaluate(() => {
    const d = document.querySelector('[role="dialog"]');
    if (!d) return null;
    const dr = d.getBoundingClientRect();
    const cut = [];
    for (const e of d.querySelectorAll('flt-semantics')) {
      const t = (e.getAttribute('aria-label') ?? e.textContent ?? '').trim();
      const r = e.getBoundingClientRect();
      if (!t || r.width === 0) continue;
      if (r.left < dr.left - 0.5 || r.right > dr.right + 0.5) cut.push({ t: t.slice(0, 50) });
    }
    return { left: dr.left, right: dr.right, vw: innerWidth, cut };
  });
  const buttons = ax.filter((n) => n.role === 'button').map((n) => n.name);
  const ok = !!dlg?.name && !!geo && geo.left >= 0 && geo.right <= geo.vw + 0.5 && geo.cut.length === 0 &&
    (buttons.includes('Save') || buttons.includes('Download CSV')) && buttons.includes('Cancel');
  return { ok, name: dlg?.name, geo, buttons };
}

async function zoomRun() {
  // Real browser zoom: the profile's default zoom level set to 200%, the
  // preference behind the browser's zoom control (Ctrl/Cmd and +).
  const dir = mkdtempSync(path.join(tmpdir(), 'q10-zoom-'));
  mkdirSync(path.join(dir, 'Default'), { recursive: true });
  writeFileSync(path.join(dir, 'Default', 'Preferences'), JSON.stringify({ partition: { default_zoom_level: { x: Math.log(2) / Math.log(1.2) } } }));
  const ctx = await chromium.launchPersistentContext(dir, {
    ...(EXECUTABLE ? { executablePath: EXECUTABLE } : { channel: 'chromium' }),
    viewport: null, locale: LOCALE, args: [...GL_ARGS, `--window-size=${DESKTOP.width},${DESKTOP.height}`],
  });
  const { page, cdp, errors } = await openApp(ctx, { page: ctx.pages()[0] });
  const r = await scaledChecks(page, cdp, '09-zoom200');
  const realZoom = r.vp.dpr === 2 && r.vp.width <= DESKTOP.width / 2 + 1;
  save('zoom-200.json', r);
  check('C11', realZoom ? 'desktop' : 'emulated',
    `200% browser zoom (${realZoom ? 'real browser zoom preference' : 'NOT applied — emulation only'}): all slots exposed, no page-level horizontal scroll, no text cut by the window, far column reachable, both dialogs fit, list fits`,
    realZoom && r.slots === 48 && !r.pageScrollsHorizontally && r.gridCut.length === 0 && r.listCut.length === 0 && r.farVisible && r.slotDlg.ok && r.exportDlg.ok && r.listInside && errors.length === 0, r);
  await ctx.close();
  rmSync(dir, { recursive: true, force: true });
}

async function fontRun(browser, baselineHeading) {
  // 200% browser default font size (16px → 32px): the preference the
  // browser's "Font size" setting changes, set through CDP Page.setFontSizes.
  const ctx = await browser.newContext({ viewport: DESKTOP, locale: LOCALE });
  const { page, cdp, errors } = await openApp(ctx, { before: (_, c) => c.send('Page.setFontSizes', { fontSizes: { standard: 32, fixed: 26 } }) });
  const heading = await headingBox(page);
  const r = await scaledChecks(page, cdp, '10-font200');
  r.headingRatio = heading && baselineHeading ? +(heading.height / baselineHeading.height).toFixed(2) : null;
  save('font-200.json', r);
  check('C12', 'desktop', '200% browser font size: root 32px, text ~2×, all slots exposed, no text cut, far column reachable, both dialogs fit, list fits',
    r.vp.rootFontSize === '32px' && r.headingRatio >= 1.8 && r.slots === 48 && !r.pageScrollsHorizontally && r.gridCut.length === 0 && r.listCut.length === 0 &&
    r.farVisible && r.slotDlg.ok && r.exportDlg.ok && r.listInside && errors.length === 0, r);
  await ctx.close();
}
const headingBox = (page) => page.evaluate(() => {
  const e = [...document.querySelectorAll('[role="heading"], h1, h2')].find((x) => /Duty rotas/.test(x.textContent ?? ''));
  const r = e?.getBoundingClientRect(); return r ? { height: r.height, width: r.width } : null;
});

async function mobileRun(browser) {
  const ctx = await browser.newContext({ ...devices['Pixel 7'], locale: LOCALE });
  const { page, cdp, errors } = await openApp(ctx);
  await page.screenshot({ path: path.join(OUT, '11-android-emulated-grid.png') });
  const ax = await axTree(cdp);
  const rect = await page.evaluate(() => {
    const e = [...document.querySelectorAll('flt-semantics[role="button"]')].find((x) => /^Main door, Sun 4 Oct/.test(x.getAttribute('aria-label') ?? x.textContent ?? ''));
    const r = e?.getBoundingClientRect(); return r ? { x: r.x + r.width / 2, y: r.y + r.height / 2 } : null;
  });
  let dialog = null;
  if (rect) {
    await page.touchscreen.tap(rect.x, rect.y);
    await sleep(800);
    dialog = (await axTree(cdp)).find((n) => n.role === 'dialog');
    await page.screenshot({ path: path.join(OUT, '12-android-emulated-dialog.png') });
  }
  check('C13', 'emulated', 'mobile emulation (Pixel 7 viewport, touch, mobile UA): boots, exposes slots, a tap opens the named slot dialog',
    slotsIn(ax).length === 48 && dialog?.name === 'Main door — Sun 4 Oct' && errors.length === 0, { rect, dialog, errors, note: 'emulation, not a device run' });
  await ctx.close();
}

const browser = await chromium.launch(LAUNCH);
imgPage = await (await browser.newContext()).newPage();
const version = browser.version();
console.log(`browser ${LABEL} ${version}`);
const { readyMs } = await desktopRun(browser);
const bctx = await browser.newContext({ viewport: DESKTOP, locale: LOCALE });
const base = await headingBox((await openApp(bctx)).page);
await bctx.close();
await zoomRun();
await fontRun(browser, base);
await mobileRun(browser);
await browser.close();

const tally = (kind) => {
  const c = checks.filter((x) => x.kind === kind);
  return { passed: c.filter((x) => x.result === 'pass').length, total: c.length };
};
const results = {
  generated: new Date().toISOString(),
  label: LABEL,
  browser: `${LABEL} ${version} (headless)`,
  url: TRIAL_URL,
  readyMs,
  summary: { desktop: tally('desktop'), emulated: tally('emulated') },
  failed: checks.filter((c) => c.result === 'fail').length,
  checks,
};
save('results.json', results);
console.log(`desktop ${results.summary.desktop.passed}/${results.summary.desktop.total}, emulated ${results.summary.emulated.passed}/${results.summary.emulated.total} → ${path.join(OUT, 'results.json')}`);
process.exitCode = results.failed ? 1 : 0;
