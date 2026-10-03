// Q10 staff-web browser trial harness (disposable, SYNTHETIC data only).
//
// Drives a locally served release build of trials/staff_web in a real browser
// and records evidence: keyboard traversal, focus visibility (pixel diffs),
// roles/names from the browser accessibility tree (CDP), 200% zoom, 200%
// browser font size, CSV download content and a mobile-emulation smoke run.
//
// Usage (see trials/staff_web/README.md):
//   flutter build web --no-web-resources-cdn
//   python3 -m http.server 8766 --bind 127.0.0.1 --directory build/web &
//   PLAYWRIGHT_MODULE=/opt/node22/lib/node_modules/playwright/index.mjs \
//     node tool/browser_trial.mjs
//
// Env: TRIAL_URL, EVIDENCE_DIR, PLAYWRIGHT_MODULE, CHROMIUM_EXECUTABLE (use a
// specific Chromium/Chrome build), BROWSER_LABEL (evidence sub-folder name).
// Chromium only: CDP is used for the accessibility tree.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const { chromium, devices } = await import(
  process.env.PLAYWRIGHT_MODULE ?? 'playwright'
);
const TRIAL_URL = process.env.TRIAL_URL ?? 'http://127.0.0.1:8766/';
const LABEL = process.env.BROWSER_LABEL ?? 'chromium';
const ROOT = process.env.EVIDENCE_DIR ??
  path.resolve(here, '../../../_bmad-output/initiative-church-app/epic-platform-baseline/evidence-1.6');
const OUT = path.join(ROOT, LABEL);
mkdirSync(OUT, { recursive: true });

// The sandbox reports navigator.language as "en-US@posix", which Flutter
// rejects at start-up; real browsers report a BCP 47 tag, so pin one.
const LOCALE = 'en-GB';
const LAUNCH = {
  executablePath: process.env.CHROMIUM_EXECUTABLE || undefined,
  args: ['--enable-unsafe-swiftshader', '--use-gl=swiftshader'],
};
const DESKTOP = { width: 1366, height: 900 };
const STATUS = '(Confirmed|Confirmed by leader|Awaiting response|Needs contact|Declined|Draft|Unfilled)';
const SLOT_RE = new RegExp(`^(.+), (Sun \\d+ \\w+): (.+), ${STATUS}$`);
const INTERACTIVE = new Set(['button', 'tab', 'textbox', 'link', 'checkbox', 'radio', 'combobox', 'menuitem', 'option', 'switch', 'slider']);

const checks = [];
const log = [];
function check(id, name, pass, detail) {
  checks.push({ id, name, result: pass ? 'pass' : 'fail', detail });
  console.log(`${pass ? 'PASS' : 'FAIL'} ${id} ${name}${pass ? '' : ' — ' + JSON.stringify(detail).slice(0, 400)}`);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const save = (name, data) => writeFileSync(path.join(OUT, name), typeof data === 'string' ? data : JSON.stringify(data, null, 2));

async function openApp(ctx, before) {
  const page = await ctx.newPage();
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
  // from the DOM after about 300 ms).
  await page.evaluate(() => {
    window.__announcements = [];
    // Flutter may move its aria-live element into an open modal dialog, so
    // watch the whole document and note whether a dialog was open.
    new MutationObserver(() => {
      for (const e of document.querySelectorAll('[aria-live]')) {
        const t = e.textContent.trim();
        const entry = `${t}${e.closest('[aria-modal="true"]') ? ' [inside dialog]' : ''}`;
        if (t && window.__announcements.at(-1) !== entry) window.__announcements.push(entry);
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

/// The focused element as the accessibility tree reports it, plus its DOM tag
/// and on-screen rectangle.
async function active(page, cdp) {
  const { result } = await cdp.send('Runtime.evaluate', { expression: 'document.activeElement' });
  const ax = await cdp.send('Accessibility.getPartialAXTree', { objectId: result.objectId, fetchRelatives: false });
  const n = axSummary(ax.nodes)[0] ?? {};
  const dom = await page.evaluate(() => {
    const e = document.activeElement;
    const r = e.getBoundingClientRect();
    return { tag: e.tagName, rect: { x: r.x, y: r.y, width: r.width, height: r.height } };
  });
  return { role: n.role, name: n.name, props: n.props, ...dom };
}
async function press(page, cdp, key, note) {
  await page.keyboard.press(key);
  await sleep(300);
  const a = await active(page, cdp);
  log.push({ key, note, role: a.role, name: a.name, tag: a.tag });
  return a;
}
const isApp = (a) => a.tag !== 'BODY' && a.tag !== 'FLUTTER-VIEW' && a.tag !== 'HTML';

// --- Pixel comparison, done in a browser canvas (no extra npm packages). ---
let imgPage;
async function compare(a, b) {
  return imgPage.evaluate(async ([a64, b64]) => {
    const load = async (s) => createImageBitmap(await (await fetch('data:image/png;base64,' + s)).blob());
    const [ia, ib] = await Promise.all([load(a64), load(b64)]);
    const w = Math.min(ia.width, ib.width), h = Math.min(ia.height, ib.height);
    const px = (img) => { const c = new OffscreenCanvas(w, h); const g = c.getContext('2d'); g.drawImage(img, 0, 0); return g.getImageData(0, 0, w, h).data; };
    const da = px(ia), db = px(ib);
    let changed = 0, accA = 0, accB = 0;
    const acc = (d, i) => Math.abs(d[i] - 10) < 45 && Math.abs(d[i + 1] - 127) < 45 && Math.abs(d[i + 2] - 224) < 45;
    for (let i = 0; i < da.length; i += 4) {
      if (Math.abs(da[i] - db[i]) + Math.abs(da[i + 1] - db[i + 1]) + Math.abs(da[i + 2] - db[i + 2]) > 30) changed++;
      if (acc(da, i)) accA++;
      if (acc(db, i)) accB++;
    }
    return { changedRatio: +(changed / (w * h)).toFixed(4), accentFocused: accA, accentUnfocused: accB, w, h };
  }, [a.toString('base64'), b.toString('base64')]);
}
const clipOf = (rect, vp) => {
  const x = Math.max(0, rect.x - 6), y = Math.max(0, rect.y - 6);
  return { x, y, width: Math.min(vp.width - x, rect.width + 12), height: Math.min(vp.height - y, rect.height + 12) };
};

async function desktopRun(browser) {
  const ctx = await browser.newContext({ viewport: DESKTOP, locale: LOCALE, acceptDownloads: true });
  const { page, cdp, readyMs, errors } = await openApp(ctx);
  await page.screenshot({ path: path.join(OUT, '01-desktop-grid.png') });

  // C1/C2/C3: accessibility tree.
  const ax = await axTree(cdp);
  save('ax-tree-desktop-grid.json', ax);
  check('C1', 'semantics tree is present without a user "enable accessibility" step', count(ax, 'table') === 1, { readyMs });
  const headers = ax.filter((n) => n.role === 'columnheader').map((n) => n.name);
  const slots = ax.filter((n) => n.role === 'button' && SLOT_RE.test(n.name));
  check('C2a', 'grid exposes table/row/columnheader/cell roles', count(ax, 'table') === 1 && count(ax, 'row') === 7 && headers.length === 9 && count(ax, 'cell') >= 54,
    { rows: count(ax, 'row'), headers, cells: count(ax, 'cell') });
  check('C2b', 'all 48 slots are buttons named "position, date: member, status"', slots.length === 48, { slots: slots.length, sample: slots.slice(0, 3).map((s) => s.name) });
  const h1 = ax.find((n) => n.role === 'heading' && n.name === 'Duty rotas');
  check('C2c', 'page heading, filter field, view toggle, export and tabs are named', !!h1 && h1.props?.level === 1 &&
    count(ax, 'textbox', /^Filter positions/) === 1 && count(ax, 'radio', /^Grid$/) === 1 && count(ax, 'radio', /^List$/) === 1 &&
    count(ax, 'button', /^Export CSV/) === 1 && count(ax, 'tab') === 2, { h1 });
  const toggles = ax.filter((n) => /^(Grid|List)$/.test(n.name));
  check('C2d', 'view toggle exposes which view is selected (radio, checked)',
    toggles.length === 2 && toggles.every((t) => t.role === 'radio') && toggles.find((t) => t.name === 'Grid')?.props?.checked === 'true' &&
    toggles.find((t) => t.name === 'List')?.props?.checked === 'false', { toggles });
  const unnamed = ax.filter((n) => INTERACTIVE.has(n.role) && !n.name.trim());
  check('C3', 'every interactive node has a non-empty accessible name', unnamed.length === 0, { unnamed });

  // C4/C5: Tab traversal and focus visibility.
  const seq = [];
  const shots = [];
  for (let i = 0; i < 12; i++) {
    const a = await press(page, cdp, 'Tab', 'traversal');
    if (shots.length) {
      const prev = shots[shots.length - 1];
      prev.unfocused = await page.screenshot({ clip: prev.clip });
    }
    if (!isApp(a)) break;
    seq.push(a);
    const clip = clipOf(a.rect, DESKTOP);
    shots.push({ a, clip, focused: await page.screenshot({ clip }) });
  }
  const names = seq.map((a) => `${a.role}: ${a.name}`);
  const slotStops = seq.filter((a) => SLOT_RE.test(a.name ?? ''));
  const expectOrder = ['tab: Rota grid trial', 'tab: Platform status', /^textbox: Filter positions/, 'radio: Grid', 'radio: List', /^button: Export CSV/, /^button: Main door, Sun 4 Oct: /];
  const orderOk = expectOrder.every((e, i) => (typeof e === 'string' ? names[i] === e : e.test(names[i] ?? '')));
  check('C4a', 'Tab reaches every control in visual order, DOM focus follows (not <body>)', orderOk && seq.every(isApp), { names });
  check('C4b', 'the grid is one Tab stop (roving focus) and Tab then leaves the page content', slotStops.length === 1 && names.length === 7, { slotStops: slotStops.length });
  check('C4c', 'every focused control has a role and a name', seq.every((a) => a.role && a.name), { names });
  const vis = [];
  for (const s of shots) {
    if (!s.unfocused) continue;
    const d = await compare(s.focused, s.unfocused);
    vis.push({ control: `${s.a.role}: ${s.a.name}`, ...d });
    writeFileSync(path.join(OUT, `focus-${vis.length}-focused.png`), s.focused);
    writeFileSync(path.join(OUT, `focus-${vis.length}-unfocused.png`), s.unfocused);
  }
  save('focus-visibility.json', vis);
  check('C5', 'every focused control looks visibly different from its unfocused state (≥3% of pixels in its box)',
    vis.length === seq.length && vis.every((v) => v.changedRatio >= 0.03), vis.map((v) => [v.control, v.changedRatio, v.accentFocused - v.accentUnfocused]));

  // Back into the grid with Shift+Tab, then arrow keys.
  let a = await press(page, cdp, 'Shift+Tab', 'return to grid');
  const back = /^Main door, Sun 4 Oct: /.test(a.name);
  const moves = [
    ['ArrowLeft', /^Main door, Sun 4 Oct: /], ['ArrowUp', /^Main door, Sun 4 Oct: /],
    ['ArrowRight', /^Main door, Sun 11 Oct: /], ['ArrowDown', /^Side door, Sun 11 Oct: /],
    ['End', /^Side door, Sun 22 Nov: /], ['Control+End', /^Children's door, Sun 22 Nov: /],
    ['Home', /^Children's door, Sun 4 Oct: /], ['Control+Home', /^Main door, Sun 4 Oct: /],
  ];
  const moveLog = [];
  let movesOk = back;
  for (const [key, re] of moves) {
    a = await press(page, cdp, key, 'grid navigation');
    const inView = a.rect.x >= 0 && a.rect.x + a.rect.width <= DESKTOP.width;
    moveLog.push({ key, got: a.name, ok: re.test(a.name), inView });
    movesOk &&= re.test(a.name) && inView;
  }
  check('C6', 'arrow/Home/End/Control keys move focus slot by slot, stop at edges and scroll into view', movesOk, { back, moveLog });

  // C7: operate a slot with the keyboard only.
  a = await press(page, cdp, 'Enter', 'open slot');
  let axd = await axTree(cdp);
  const dialog = axd.find((n) => /dialog/.test(n.role));
  save('ax-tree-desktop-slot-dialog.json', axd);
  await page.screenshot({ path: path.join(OUT, '02-desktop-slot-dialog.png') });
  const dialogOk = !!dialog && /Main door — Sun 4 Oct/.test(JSON.stringify(axd));
  for (let i = 0; i < 8 && !/Status/.test(a.name ?? ''); i++) a = await press(page, cdp, 'Tab', 'to status field');
  a = await press(page, cdp, 'Enter', 'open status menu');
  await page.screenshot({ path: path.join(OUT, '03-desktop-status-menu.png') });
  for (let i = 0; i < 8 && !/^Declined/.test(a.name ?? ''); i++) a = await press(page, cdp, 'ArrowDown', 'choose status');
  a = await press(page, cdp, 'Enter', 'select status');
  for (let i = 0; i < 6 && a.name !== 'Save'; i++) a = await press(page, cdp, 'Tab', 'to Save');
  a = await press(page, cdp, 'Enter', 'save');
  await sleep(900);
  a = await active(page, cdp);
  const live = await page.evaluate(() => window.__announcements.join(' | '));
  axd = await axTree(cdp);
  const savedSlot = axd.find((n) => n.role === 'button' && /^Main door, Sun 4 Oct: .+, Declined$/.test(n.name));
  check('C7a', 'keyboard-only slot edit: dialog opens, status changes, focus returns to the slot', dialogOk && !!savedSlot && /^Main door, Sun 4 Oct: .+, Declined$/.test(a.name ?? ''),
    { dialog, focusedAfter: a.name, savedSlot: savedSlot?.name });
  const announced = /Saved\. Main door, Sun 4 Oct: .+, Declined\.\s*(\||$)/.test(live);
  check('C7b', 'the change is announced through the polite live region', announced, { live });
  a = await press(page, cdp, 'Enter', 'reopen slot');
  a = await press(page, cdp, 'Escape', 'cancel with Escape');
  axd = await axTree(cdp);
  check('C7c', 'Escape closes the dialog without changes and restores focus', !axd.some((n) => /dialog/.test(n.role)) && /^Main door, Sun 4 Oct: .+, Declined$/.test(a.name ?? ''), { focused: a.name });
  await page.screenshot({ path: path.join(OUT, '04-desktop-after-edit.png') });

  // C8: filter by keyboard, empty state.
  for (let i = 0; i < 6 && !/^Filter positions/.test(a.name ?? ''); i++) a = await press(page, cdp, 'Shift+Tab', 'to filter');
  await page.keyboard.type('zzz');
  await sleep(500);
  axd = await axTree(cdp);
  const exportNode = axd.find((n) => n.role === 'button' && /^Export CSV/.test(n.name));
  const emptyOk = axd.some((n) => /No positions match/.test(n.name)) && exportNode?.props?.disabled === true &&
    axd.some((n) => /Nothing to export/.test(n.name));
  await page.screenshot({ path: path.join(OUT, '05-desktop-empty-filter.png') });
  check('C8a', 'a filter matching nothing says so and disables export with a reason', emptyOk, { exportNode });
  for (let i = 0; i < 3; i++) await page.keyboard.press('Backspace');
  await page.keyboard.type('door');
  await sleep(500);
  axd = await axTree(cdp);
  check('C8b', 'filtering positions narrows the grid rows', count(axd, 'row') === 4 && axd.filter((n) => n.role === 'button' && SLOT_RE.test(n.name)).length === 24,
    { rows: count(axd, 'row') });

  // C9: CSV preview and download.
  for (let i = 0; i < 6 && !/^Export CSV/.test(a.name ?? ''); i++) a = await press(page, cdp, 'Tab', 'to export');
  a = await press(page, cdp, 'Enter', 'open export');
  axd = await axTree(cdp);
  save('ax-tree-desktop-export-dialog.json', axd);
  await page.screenshot({ path: path.join(OUT, '06-desktop-export-preview.png') });
  const previewText = JSON.stringify(axd);
  const previewOk = /Scope: 3 positions × 8 Sundays = 24 rows/.test(previewText) && /Not included: phone numbers and care notes/.test(previewText) &&
    /outside the app’s access/.test(previewText);
  for (let i = 0; i < 6 && !/Download CSV/.test(a.name ?? ''); i++) a = await press(page, cdp, 'Tab', 'to download');
  const [download] = await Promise.all([page.waitForEvent('download', { timeout: 15000 }), press(page, cdp, 'Enter', 'download')]);
  const csvPath = path.join(OUT, 'rota-export-door-filter.csv');
  await download.saveAs(csvPath);
  const bytes = readFileSync(csvPath);
  const text = bytes.toString('utf8');
  const csv = parseCsv(text.replace(/^﻿/, ''));
  const header = csv[0];
  const body = csv.slice(1);
  const fields = body.flat();
  const rawTrigger = fields.filter((f) => /^\s*[=+\-@\t\r]/.test(f));
  const neutralised = fields.filter((f) => /^'\s*[=+\-@\t\r]/.test(f));
  const csvChecks = {
    filename: download.suggestedFilename(),
    bom: bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf,
    crlfRows: (text.match(/\r\n/g) ?? []).length,
    header,
    rows: body.length,
    columnsPerRow: [...new Set(body.map((r) => r.length))],
    positions: [...new Set(body.map((r) => r[1]))],
    rawTriggerFields: rawTrigger,
    neutralisedFields: neutralised,
    privateLeak: /\+260|care note/i.test(text),
    editedSlot: body.find((r) => r[0] === '2026-10-04' && r[1] === 'Main door'),
  };
  save('csv-checks.json', csvChecks);
  check('C9a', 'export preview states scope, columns, exclusions and the outside-access warning', previewOk, {});
  check('C9b', 'downloaded CSV: BOM, allowlisted header, 24 filtered rows, 5 columns each, CRLF',
    csvChecks.bom && JSON.stringify(header) === JSON.stringify(['Date', 'Position', 'Member', 'Status', 'Note']) && body.length === 24 &&
    csvChecks.columnsPerRow.length === 1 && csvChecks.columnsPerRow[0] === 5 && csvChecks.positions.every((p) => /door/i.test(p)) && csvChecks.crlfRows === 25,
    csvChecks);
  check('C9c', 'formula-led values are neutralised with a leading apostrophe; none start raw', rawTrigger.length === 0 && neutralised.length >= 3,
    { rawTrigger, neutralised });
  check('C9d', 'no private field (phone, care note) is in the file', !csvChecks.privateLeak, {});
  check('C9e', 'the keyboard edit made in the grid is in the export', csvChecks.editedSlot?.[3] === 'Declined', { editedSlot: csvChecks.editedSlot });

  // C10: list alternative.
  a = await active(page, cdp);
  for (let i = 0; i < 8 && !/^Filter positions/.test(a.name ?? ''); i++) a = await press(page, cdp, 'Shift+Tab', 'to filter');
  await page.keyboard.press('Control+A');
  await page.keyboard.press('Backspace');
  await sleep(400);
  for (let i = 0; i < 4 && a.name !== 'List'; i++) a = await press(page, cdp, 'Tab', 'to List');
  a = await press(page, cdp, 'Space', 'switch to list');
  await sleep(500);
  axd = await axTree(cdp);
  save('ax-tree-desktop-list.json', axd);
  await page.screenshot({ path: path.join(OUT, '07-desktop-list.png'), fullPage: true });
  const changeButtons = axd.filter((n) => n.role === 'button' && /^Change .+, Sun \d+ \w+$/.test(n.name));
  check('C10a', 'list view: 6 lists, 48 list items, 48 named Change buttons, level-2 headings',
    count(axd, 'list') === 6 && count(axd, 'listitem') === 48 && changeButtons.length === 48 &&
    axd.filter((n) => n.role === 'heading' && n.props?.level === 2 && !/staff web trial/.test(n.name)).length === 6,
    { lists: count(axd, 'list'), items: count(axd, 'listitem'), change: changeButtons.length });
  const listToggle = axd.filter((n) => n.role === 'button' && /^(Grid|List)$/.test(n.name));
  a = await press(page, cdp, 'Tab', 'into list');
  for (let i = 0; i < 4 && !/^Change /.test(a.name ?? ''); i++) a = await press(page, cdp, 'Tab', 'to first Change');
  const firstChange = a.name;
  a = await press(page, cdp, 'Enter', 'open from list');
  axd = await axTree(cdp);
  const listDialog = axd.some((n) => /dialog/.test(n.role));
  a = await press(page, cdp, 'Escape', 'close');
  check('C10b', 'list items are operable by keyboard (Change opens the same slot dialog)', /^Change Main door, Sun 4 Oct$/.test(firstChange ?? '') && listDialog && a.name === firstChange,
    { firstChange, listDialog, focusAfter: a.name, listToggle });
  save('keyboard-log-desktop.json', log);
  check('C0', 'no page errors during the desktop run', errors.length === 0, { errors });
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

async function scaledChecks(page, cdp, vp, prefix, id) {
  const ax = await axTree(cdp);
  const slots = ax.filter((n) => n.role === 'button' && SLOT_RE.test(n.name)).length;
  const layout = await page.evaluate(() => {
    const pick = (role, re) => [...document.querySelectorAll(`[role="${role}"], input`)].filter((e) => re.test(e.getAttribute('aria-label') ?? e.textContent ?? e.placeholder ?? ''));
    const rects = {};
    for (const [k, role, re] of [['filter', 'textbox', /Filter/], ['grid', 'radio', /^Grid$/], ['list', 'radio', /^List$/], ['export', 'button', /^Export/]]) {
      const e = pick(role, re)[0] ?? (k === 'filter' ? document.querySelector('input') : null);
      if (e) { const r = e.getBoundingClientRect(); rects[k] = { x: r.x, right: r.right, width: r.width, height: r.height }; }
    }
    const h = [...document.querySelectorAll('[role="heading"], h1, h2')].find((e) => /Duty rotas/.test(e.textContent ?? ''));
    const hr = h?.getBoundingClientRect();
    return {
      rects,
      heading: hr ? { height: hr.height, width: hr.width } : null,
      pageScrollsHorizontally: document.documentElement.scrollWidth > document.documentElement.clientWidth,
      rootFontSize: getComputedStyle(document.documentElement).fontSize,
    };
  });
  const toolbarInside = Object.values(layout.rects).length === 4 && Object.values(layout.rects).every((r) => r.x >= 0 && r.right <= vp.width + 0.5);
  await page.screenshot({ path: path.join(OUT, `${prefix}-grid.png`) });
  // Reach the far edge of the grid by keyboard; it must scroll into view.
  let a = await active(page, cdp);
  for (let i = 0; i < 10 && !SLOT_RE.test(a.name ?? ''); i++) a = await press(page, cdp, 'Tab', `${prefix} to grid`);
  a = await press(page, cdp, 'End', `${prefix} grid end`);
  const farVisible = /Sun 22 Nov/.test(a.name ?? '') && a.rect.x >= 0 && a.rect.x + a.rect.width <= vp.width + 0.5;
  await page.screenshot({ path: path.join(OUT, `${prefix}-grid-end.png`) });
  for (let i = 0; i < 10 && a.name !== 'List'; i++) a = await press(page, cdp, 'Shift+Tab', `${prefix} to List`);
  a = await press(page, cdp, 'Enter', `${prefix} list view`);
  await sleep(500);
  const listLayout = await page.evaluate(() => [...document.querySelectorAll('[role="listitem"]')].map((e) => {
    const r = e.getBoundingClientRect(); return { x: r.x, right: r.right };
  }));
  await page.screenshot({ path: path.join(OUT, `${prefix}-list.png`) });
  const listInside = listLayout.length === 48 && listLayout.every((r) => r.x >= 0 && r.right <= vp.width + 0.5);
  return { slots, layout, toolbarInside, farVisible, listInside, id };
}

async function zoomRun(browser) {
  // 200% browser zoom on a 1366×900 window = a 683×450 CSS viewport at 2 device px per CSS px.
  const vp = { width: 683, height: 450 };
  const ctx = await browser.newContext({ viewport: vp, deviceScaleFactor: 2, locale: LOCALE });
  const { page, cdp, errors } = await openApp(ctx);
  const r = await scaledChecks(page, cdp, vp, '08-zoom200', 'C11');
  save('zoom-200.json', r);
  check('C11', '200% zoom: all slots exposed, toolbar wraps inside the window, no page-level horizontal scroll, grid end reachable, list fits',
    r.slots === 48 && r.toolbarInside && !r.layout.pageScrollsHorizontally && r.farVisible && r.listInside && errors.length === 0, r);
  await ctx.close();
}

async function fontRun(browser, baselineHeading) {
  // 200% browser default font size (16px → 32px): the same preference the
  // browser's "Font size" setting changes, set through CDP Page.setFontSizes.
  const ctx = await browser.newContext({ viewport: DESKTOP, locale: LOCALE });
  const { page, cdp, errors } = await openApp(ctx, (_, c) => c.send('Page.setFontSizes', { fontSizes: { standard: 32, fixed: 26 } }));
  const r = await scaledChecks(page, cdp, DESKTOP, '09-font200', 'C12');
  r.baselineHeading = baselineHeading;
  r.headingRatio = r.layout.heading && baselineHeading ? +(r.layout.heading.height / baselineHeading.height).toFixed(2) : null;
  save('font-200.json', r);
  check('C12', '200% browser font size: root font 32px, text renders ~2×, all slots exposed, toolbar inside, grid end reachable, list fits',
    r.layout.rootFontSize === '32px' && r.headingRatio >= 1.8 && r.slots === 48 && r.toolbarInside && r.farVisible && r.listInside && errors.length === 0, r);
  await ctx.close();
}

async function baselineHeading(browser) {
  const ctx = await browser.newContext({ viewport: DESKTOP, locale: LOCALE });
  const { page } = await openApp(ctx);
  const h = await page.evaluate(() => {
    const e = [...document.querySelectorAll('[role="heading"], h1, h2')].find((x) => /Duty rotas/.test(x.textContent ?? ''));
    const r = e?.getBoundingClientRect(); return r ? { height: r.height, width: r.width } : null;
  });
  await ctx.close();
  return h;
}

async function mobileRun(browser) {
  const device = devices['Pixel 7'];
  const ctx = await browser.newContext({ ...device, locale: LOCALE });
  const { page, cdp, errors } = await openApp(ctx);
  await page.screenshot({ path: path.join(OUT, '10-android-emulated-grid.png') });
  const ax = await axTree(cdp);
  // Tap the first slot by its semantics rectangle.
  const rect = await page.evaluate(() => {
    const e = [...document.querySelectorAll('flt-semantics[role="button"]')].find((x) => /^Main door, Sun 4 Oct/.test(x.getAttribute('aria-label') ?? x.textContent ?? ''));
    const r = e?.getBoundingClientRect(); return r ? { x: r.x + r.width / 2, y: r.y + r.height / 2 } : null;
  });
  let dialog = false;
  if (rect) {
    await page.touchscreen.tap(rect.x, rect.y);
    await sleep(800);
    dialog = (await axTree(cdp)).some((n) => /dialog/.test(n.role));
    await page.screenshot({ path: path.join(OUT, '11-android-emulated-dialog.png') });
  }
  check('C13', 'mobile emulation (Pixel 7 viewport, touch, mobile UA): boots, exposes slots, a tap opens the slot dialog',
    ax.filter((n) => n.role === 'button' && SLOT_RE.test(n.name)).length === 48 && dialog && errors.length === 0, { rect, dialog, errors, classification: 'emulated, not a device run' });
  await ctx.close();
}

const browser = await chromium.launch(LAUNCH);
imgPage = await (await browser.newContext()).newPage();
const version = browser.version();
console.log(`browser ${LABEL} ${version}`);
const { readyMs } = await desktopRun(browser);
const base = await baselineHeading(browser);
await zoomRun(browser);
await fontRun(browser, base);
await mobileRun(browser);
await browser.close();

const results = {
  generated: new Date().toISOString(),
  label: LABEL,
  browser: `${LABEL} ${version}`,
  url: TRIAL_URL,
  readyMs,
  passed: checks.filter((c) => c.result === 'pass').length,
  failed: checks.filter((c) => c.result === 'fail').length,
  checks,
};
save('results.json', results);
console.log(`${results.passed} passed, ${results.failed} failed → ${path.join(OUT, 'results.json')}`);
process.exitCode = results.failed ? 1 : 0;
