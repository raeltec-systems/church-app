// Staff web (staging build) tracer in headless Chromium: hosted value, network failure, Try again.
// Usage: node tracer.mjs <build_dir> <evidence_dir>
import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { readFile, writeFile } from 'node:fs/promises';
import { join, extname, normalize } from 'node:path';
const require = createRequire('/opt/node-tools/node_modules/');
const { chromium } = require('playwright-core');

const [dir, out] = process.argv.slice(2);
const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.wasm': 'application/wasm', '.css': 'text/css', '.png': 'image/png', '.ico': 'image/x-icon', '.ttf': 'font/ttf', '.otf': 'font/otf', '.frag': 'text/plain', '.bin': 'application/octet-stream', '.svg': 'image/svg+xml' };
const server = createServer(async (req, res) => {
  let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (p.endsWith('/')) p += 'index.html';
  try {
    const body = await readFile(join(dir, normalize(p)));
    res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' });
    res.end(body);
  } catch { res.writeHead(404); res.end(); }
}).listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${server.address().port}/`;

const log = [];
const step = (name, data) => { const l = { step: name, at: new Date().toISOString(), ...data }; log.push(l); console.log(JSON.stringify(l)); };
const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome',
  proxy: process.env.HTTPS_PROXY ? { server: process.env.HTTPS_PROXY, bypass: '127.0.0.1,localhost' } : undefined });
step('browser', { version: browser.version(), headless: true, origin: 'http://staff-web.test/ (route-fulfilled from the sealed staging build directory)', build_dir: dir });
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
// Serve the sealed build from disk under a synthetic origin (no proxy hop for local files).
const ORIGIN = 'http://staff-web.test/';
await page.route('http://staff-web.test/**', async (route) => {
  let p = decodeURIComponent(new URL(route.request().url()).pathname);
  if (p.endsWith('/')) p += 'index.html';
  try { const body = await readFile(join(dir, normalize(p))); await route.fulfill({ status: 200, body, contentType: types[extname(p)] || 'application/octet-stream' }); }
  catch { await route.fulfill({ status: 404, body: '' }); }
});
const api = [];
page.on('response', (r) => { if (r.url().includes('supabase.co')) api.push({ url: r.url().replace(/apikey=[^&]+/, 'apikey=<redacted>'), status: r.status(), at: new Date().toISOString() }); });
page.on('requestfailed', (r) => { if (r.url().includes('supabase.co')) api.push({ url: r.url(), failed: r.failure()?.errorText, at: new Date().toISOString() }); });

async function semanticsText() {
  await page.evaluate(() => { const p = document.querySelector('flt-semantics-placeholder'); if (p) p.click(); });
  await page.waitForTimeout(800);
  return page.evaluate(() => {
    const host = document.querySelector('flt-semantics-host') || document.body;
    const t = new Set();
    host.querySelectorAll('*').forEach((e) => { const a = e.getAttribute('aria-label'); if (a) t.add(a.trim()); if (!e.children.length && e.textContent.trim()) t.add(e.textContent.trim()); });
    return [...t];
  });
}
async function waitFor(re, ms = 30000) {
  const end = Date.now() + ms; let last = [];
  while (Date.now() < end) { last = await semanticsText(); if (last.some((s) => re.test(s))) return last; await page.waitForTimeout(1000); }
  throw new Error(`timeout waiting for ${re}: ${JSON.stringify(last)}`);
}
let ok = true;
try {
  await page.goto(ORIGIN, { waitUntil: 'load' });
  const t1 = await waitFor(/operational/i);
  await page.screenshot({ path: join(out, '1-initial-hosted.png') });
  step('initial', { texts: t1, api: api.splice(0) });

  await page.route('**/*.supabase.co/**', (r) => r.abort('internetdisconnected'));
  await page.reload({ waitUntil: 'load' });
  const t2 = await waitFor(/Couldn't reach the server/);
  await page.screenshot({ path: join(out, '2-network-blocked.png') });
  step('network_blocked', { texts: t2, api: api.splice(0) });

  await page.unroute('**/*.supabase.co/**');
  const clicked = await page.evaluate(() => {
    const els = [...document.querySelectorAll('flt-semantics [role="button"], flt-semantics-host [role="button"], [role="button"]')];
    const b = els.find((e) => /Try again/.test(e.getAttribute('aria-label') || e.textContent || ''));
    if (b) { b.click(); return true; } return false;
  });
  if (!clicked) await page.getByRole('button', { name: 'Try again' }).click();
  const t3 = await waitFor(/operational/i);
  await page.screenshot({ path: join(out, '3-recovered.png') });
  step('recovered_after_try_again', { clicked_via_semantics: clicked, texts: t3, api: api.splice(0) });
} catch (e) {
  ok = false; step('error', { message: String(e.message || e) });
  await page.screenshot({ path: join(out, 'error.png') }).catch(() => {});
}
await browser.close(); server.close();
await writeFile(join(out, 'tracer-log.jsonl'), log.map((l) => JSON.stringify(l)).join('\n') + '\n');
process.exitCode = ok ? 0 : 1;
