// Recorder: drives the patched prototypes (journeys/proto/, served on :8125) with real clicks, typing
// and scrolls, and saves what the screen does as a frame sequence the films play back.
//
// Each clip is rec/<name>/ with NNNN.jpg frames and clip.json:
//   frames: [[file, vt]]   vt = virtual ms on the clip's own clock
//   marks:  { name: index } the frame showing the state just before that action
//   events: [{ mark, kind: tap|click|type|scroll, x, y }]  positions in clip css px (cursor, ripples)
// CSS animations are slowed with the DevTools Animation domain while capturing, so the entrance
// motion of sheets, toasts and modals is recorded frame by frame and plays back at real speed.
import { chromium } from '/opt/node22/lib/node_modules/playwright/index.mjs';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const VENDOR = path.resolve(HERE, '../vendor');
export const REC = path.resolve(HERE, '../rec');
const RATE = 0.2;

const norm = (s) => (s || '').trim().replace(/\s+/g, ' ');

export class Rec {
  static async open(file, { vp = { width: 1440, height: 900 }, dsf = 2, query = '' } = {}) {
    const r = new Rec();
    r.browser = await chromium.launch({ args: ['--ignore-certificate-errors', '--font-render-hinting=none'] });
    r.page = await r.browser.newPage({ viewport: vp, deviceScaleFactor: dsf });
    r.page.on('pageerror', (e) => console.log('pageerror:', e.message));
    await r.page.route('https://unpkg.com/**', (q) => q.fulfill({ body: fs.readFileSync(path.join(VENDOR, q.request().url().split('/').pop())), contentType: 'application/javascript' }));
    await r.page.goto(`http://localhost:8125/${file}${query}`);
    await r.page.waitForFunction(() => window.__dc, null, { timeout: 30000 });
    await r.page.evaluate(() => document.fonts.ready);
    await r.page.waitForTimeout(800);
    r.cdp = await r.page.context().newCDPSession(r.page);
    await r.cdp.send('Animation.enable');
    r.dsf = dsf;
    r.clip = { x: 0, y: 0, width: vp.width, height: vp.height };
    return r;
  }
  async phoneClip() {
    // The prototype's 390x844 device has an 11px bezel; record the screen inside it (the films draw the bezel).
    const b = await this.page.evaluate(() => {
      const d = [...document.querySelectorAll('div')].find((e) => { const r = e.getBoundingClientRect(); return Math.round(r.width) === 390 && Math.round(r.height) === 844; });
      const r = d.getBoundingClientRect(); return { x: r.x, y: r.y };
    });
    this.clip = { x: b.x + 11, y: b.y + 11, width: 368, height: 822 };
    return this.clip;
  }
  state(patch) { return this.page.evaluate((p) => new Promise((res) => window.__dc.setState(p, res)), patch); }
  eval(fn, arg) { return this.page.evaluate(fn, arg); }
  async close() { await this.browser.close(); }

  // ------------------------------------------------------------ clip lifecycle
  async start(name) {
    this.name = name; this.dir = path.join(REC, name);
    fs.rmSync(this.dir, { recursive: true, force: true }); fs.mkdirSync(this.dir, { recursive: true });
    this.frames = []; this.marks = {}; this.events = []; this.vt = 0; this.last = null; this.n = 0;
    await this.page.waitForTimeout(250);
    await this.shot();
  }
  async shot() {
    const buf = await this.page.screenshot({ type: 'jpeg', quality: 90, clip: this.clip });
    if (this.last && buf.equals(this.last)) { this.frames.push([this.frames.at(-1)[0], this.vt]); return false; }
    const f = String(this.n++).padStart(4, '0') + '.jpg';
    fs.writeFileSync(path.join(this.dir, f), buf);
    this.frames.push([f, this.vt]); this.last = buf;
    return true;
  }
  mark(name) {
    if (name in this.marks) throw new Error(`${this.name}: duplicate mark ${name}`);
    this.marks[name] = this.frames.length - 1;
  }
  save(extra = {}) {
    // collapse runs of identical frames (keep the first of each run)
    const fr = this.frames, keep = [], remap = new Map();
    fr.forEach((x, i) => { if (i > 0 && x[0] === fr[i - 1][0] && !Object.values(this.marks).includes(i)) { remap.set(i, keep.length - 1); return; } remap.set(i, keep.length); keep.push(x); });
    const marks = Object.fromEntries(Object.entries(this.marks).map(([k, i]) => [k, remap.get(i)]));
    const out = { name: this.name, clip: this.clip, dsf: this.dsf, frames: keep, marks, events: this.events, ...extra };
    fs.writeFileSync(path.join(this.dir, 'clip.json'), JSON.stringify(out));
    console.log(`rec/${this.name}: ${keep.length} frames (${this.n} files), ${Object.keys(marks).length} marks`);
    return out;
  }

  // ------------------------------------------------------------ capture an action
  // Mark, slow CSS animations down, run the action, then record what happens for `anim` virtual ms.
  async act(name, fn, { anim = 520, kind = 'tap', x = null, y = null, settle = 0 } = {}) {
    this.mark(name);
    if (x != null) this.events.push({ mark: name, kind, x: x - this.clip.x, y: y - this.clip.y });
    await this.cdp.send('Animation.setPlaybackRate', { playbackRate: RATE });
    const base = this.vt;
    const t0 = Date.now();
    await fn();
    let still = 0;
    for (;;) {
      this.vt = base + (Date.now() - t0) * RATE;
      const changed = await this.shot();
      still = changed ? 0 : still + 1;
      if (this.vt - base > anim && still >= 2) break;
      if (this.vt - base > anim * 4) break;
    }
    await this.cdp.send('Animation.setPlaybackRate', { playbackRate: 1 });
    if (settle) { await this.page.waitForTimeout(settle); this.vt += 60; await this.shot(); }
    this.vt += 40;
  }

  // Find a visible, unobscured control by its text inside the clip (last match wins with idx:-1).
  async find(text, { exact = true, idx = 0, sel = 'button,[role=button],a,input,select,label,textarea' } = {}) {
    const pts = await this.page.evaluate(([text, exact, sel, clip]) => {
      const norm = (s) => (s || '').trim().replace(/\s+/g, ' ');
      return [...document.querySelectorAll(sel)].filter((b) => { const t = norm(b.innerText || b.placeholder || b.value); return exact ? t === text : t.includes(text); }).map((b) => {
        const r = b.getBoundingClientRect(); const x = r.x + r.width / 2, y = r.y + r.height / 2;
        const inside = x >= clip.x && x <= clip.x + clip.width && y >= clip.y && y <= clip.y + clip.height;
        const top = document.elementFromPoint(x, y);
        return r.width > 0 && inside && top && (b === top || b.contains(top)) ? { x, y } : null;
      }).filter(Boolean);
    }, [text, exact, sel, this.clip]);
    if (!pts.length) {
      // clickable rows are often plain divs: take the smallest visible element whose text matches
      const alt = await this.page.evaluate(([text, exact, clip]) => {
        const norm = (s) => (s || '').trim().replace(/\s+/g, ' ');
        const hit = [...document.querySelectorAll('div,span,li,p')].filter((b) => { const t = norm(b.innerText); return exact ? t === text : t.includes(text); }).map((b) => {
          const r = b.getBoundingClientRect(); const x = r.x + r.width / 2, y = r.y + r.height / 2;
          const inside = x >= clip.x && x <= clip.x + clip.width && y >= clip.y && y <= clip.y + clip.height;
          const top = document.elementFromPoint(x, y);
          return r.width > 0 && inside && top && (b === top || b.contains(top) || top.contains(b)) ? { x, y, a: r.width * r.height } : null;
        }).filter(Boolean).sort((a, b) => a.a - b.a);
        return hit[0] || null;
      }, [text, exact, this.clip]);
      if (alt) return alt;
      throw new Error(`${this.name}: no visible "${text}"`);
    }
    return idx < 0 ? pts.at(idx) : pts[idx];
  }
  async tap(name, text, opts = {}) {
    const c = await this.find(text, opts);
    await this.act(name, () => this.page.mouse.click(c.x, c.y), { ...opts, x: c.x, y: c.y, kind: opts.kind || 'tap' });
  }
  async tapAt(name, x, y, opts = {}) {
    await this.act(name, () => this.page.mouse.click(x, y), { ...opts, x, y, kind: opts.kind || 'tap' });
  }

  // Type into a focused field one character at a time; each keystroke is a frame `ms` apart.
  async type(name, str, { ms = 75 } = {}) {
    this.mark(name);
    for (const ch of str) { await this.page.keyboard.type(ch); this.vt += ms; await this.shot(); }
    this.vt += 40;
  }
  // Replace a text field's content by selecting it and typing.
  async retype(name, locator, str, opts) {
    await locator.click({ clickCount: 3 }); await this.page.keyboard.press('Backspace');
    await this.type(name, str, opts);
  }

  // Eased scroll of the scroll container under (x, y) to an absolute scrollTop (or by delta).
  async scroll(name, { x, y, to = null, by = 0, ms = 1100 } = {}) {
    this.mark(name);
    this.events.push({ mark: name, kind: 'scroll', x: x - this.clip.x, y: y - this.clip.y });
    const [from, max] = await this.page.evaluate(([x, y]) => {
      let e = document.elementFromPoint(x, y);
      while (e && !(e.scrollHeight > e.clientHeight + 2 && /(auto|scroll)/.test(getComputedStyle(e).overflowY))) e = e.parentElement;
      window.__scr = e || document.scrollingElement; return [window.__scr.scrollTop, window.__scr.scrollHeight - window.__scr.clientHeight];
    }, [x, y]);
    const target = Math.max(0, Math.min(max, to != null ? to : from + by));
    const n = Math.max(2, Math.round(ms / 16.7));
    const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2);
    for (let i = 1; i <= n; i++) {
      await this.page.evaluate((v) => { window.__scr.scrollTop = v; }, from + (target - from) * ease(i / n));
      this.vt += ms / n; await this.shot();
    }
    this.vt += 40;
    return target;
  }

  // A native <select>: draw an open option list in the prototype's style over the real control,
  // highlight the choice, then really select it (headless screenshots never show native popups).
  async pick(name, locator, label, { menuMs = 260, cursor = 'click' } = {}) {
    const box = await locator.boundingBox();
    const x = box.x + box.width / 2, y = box.y + box.height / 2;
    await this.act(name, async () => {
      await locator.evaluate((sel, label) => {
        const r = sel.getBoundingClientRect(); const opts = [...sel.options].map((o) => o.text);
        const m = document.createElement('div'); m.id = '__menu';
        Object.assign(m.style, { position: 'fixed', left: r.left + 'px', top: r.bottom + 4 + 'px', width: Math.max(r.width, 220) + 'px', zIndex: 999, background: '#fff', border: '1px solid #DFE4EE', borderRadius: '12px', boxShadow: '0 18px 40px rgba(14,21,48,.18)', padding: '6px', font: '500 14px Figtree, sans-serif', color: '#0E1530', maxHeight: '300px', overflow: 'hidden', animation: 'jModal .22s cubic-bezier(.2,.9,.25,1)' });
        const i0 = Math.max(0, opts.indexOf(label) - 3);
        opts.slice(i0, i0 + 8).forEach((t) => { const o = document.createElement('div'); o.textContent = t; Object.assign(o.style, { padding: '8px 10px', borderRadius: '8px', ...(t === label ? { background: '#E3EEFC', color: '#0B4FA6', fontWeight: 700 } : {}) }); m.appendChild(o); });
        document.body.appendChild(m);
      }, label);
    }, { x, y, kind: cursor, anim: menuMs });
    const lbox = await this.page.evaluate((label) => { const o = [...document.querySelectorAll('#__menu > div')].find((d) => d.textContent === label); const r = o.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; }, label);
    await this.act(name + ':choose', async () => {
      await this.page.evaluate(() => document.getElementById('__menu').remove());
      await locator.selectOption({ label });
    }, { x: lbox.x, y: lbox.y, kind: cursor, anim: 120 });
  }
  // Just wait (the screen holds); used so marks line up with the shot list.
  async pause(ms) { await this.page.waitForTimeout(ms); }
}
