// Shared kit for the four journey films. Everything here is a pure function of the beat u.
//
//   import * as M from './lib/motion.js'; import { makeKit } from '../journeys/kit.js';
//   const K = makeKit(M);  ...  await K.start({ clips: [...], draw, hits });
//
// Recorded clips (rec/<name>/clip.json + JPEG frames, made by journeys/rec-*.mjs) are streamed:
// window.seek is wrapped so a frame's images are loaded before it is painted, which keeps memory
// bounded however long the film is. Playback is scheduled in beats against the clip's marks.
export function makeKit(M) {
  const { W, H, FORMAT, E, prog, lerp, clamp, springU, SPRING, font, rrect } = M;
  const C = { navy: '#14246B', blue: '#0A7FE0', ink: '#0E1530', mut: '#586079', paper: '#F4F6FA', line: '#DFE4EE', soft: '#DCE7FA', night: '#0A0F1E' };
  const DISPLAY = 'Display', UI = 'UI';
  const K = { C, DISPLAY, UI, clips: {} };

  // ------------------------------------------------------------ streamed images
  const cache = new Map(); const MISSING = new Set(); let tick = 0; const LIMIT = 90;
  K.img = (src) => {
    const e = cache.get(src);
    if (e && e.ok) { e.last = ++tick; return e.im; }
    MISSING.add(src); return null;
  };
  async function load(srcs) {
    await Promise.all(srcs.map(async (src) => {
      if (cache.get(src)?.ok) return;
      const im = new Image(); im.src = src;
      try { await im.decode(); cache.set(src, { im, ok: true, last: ++tick }); } catch { console.error('image failed', src); cache.set(src, { ok: false }); }
    }));
    if (cache.size > LIMIT) [...cache.entries()].sort((a, b) => (a[1].last || 0) - (b[1].last || 0)).slice(0, cache.size - LIMIT).forEach(([k, v]) => { if (v.im) v.im.src = ''; cache.delete(k); });
  }
  K.start = async ({ clips = [], images = [], draw, hits, samples = 8 }) => {
    await Promise.all(clips.map(async (n) => { K.clips[n] = await fetch(`../rec/${n}/clip.json`).then((r) => r.json()); }));
    await load(images);
    await M.film({ fonts: [font(100, 700, DISPLAY), font(40, 500, UI), font(40, 700, UI)], hits, samples, draw: (ctx, u, t) => draw(ctx, u, t) });
    const orig = window.seek;
    window.seek = async (t) => {
      for (let k = 0; k < 4; k++) { MISSING.clear(); orig(t); if (!MISSING.size) return; await load([...MISSING]); }
    };
    if (!M.RENDER) { const kick = async () => { MISSING.clear(); orig(0); if (MISSING.size) { await load([...MISSING]); orig(0); } }; kick(); }
  };

  // ------------------------------------------------------------ clip playback
  // sched: [{ at: beat, mark: 'start' | markName, dur?: beats (stretch this segment to fit) }]
  const markIdx = (c, m) => (m === 'start' ? 0 : c.marks[m] ?? (() => { throw new Error(`${c.name}: no mark ${m}`); })());
  K.frameIndex = (name, u, sched) => {
    const c = K.clips[name]; const fr = c.frames;
    if (u < sched[0].at) return markIdx(c, sched[0].mark);
    let k = 0; while (k + 1 < sched.length && sched[k + 1].at <= u) k++;
    const e = sched[k]; const i0 = markIdx(c, e.mark);
    const iEnd = k + 1 < sched.length ? markIdx(c, sched[k + 1].mark) : fr.length - 1;
    const span = Math.max(1, fr[Math.max(i0, iEnd)][1] - fr[i0][1]);
    const speed = e.dur ? span / (e.dur * M.GRID.period * 1000) : 1;
    const target = fr[i0][1] + (u - e.at) * M.GRID.period * 1000 * speed;
    let j = i0; while (j + 1 <= iEnd && fr[j + 1][1] <= target) j++;
    return Math.min(j, fr.length - 1);
  };
  K.frame = (name, u, sched) => { const c = K.clips[name]; return K.img(`../rec/${name}/${c.frames[K.frameIndex(name, u, sched)][0]}`); };
  K.frameAt = (name, i) => { const c = K.clips[name]; return K.img(`../rec/${name}/${c.frames[Math.min(i, c.frames.length - 1)][0]}`); };
  // events with the beat they happen at, in schedule order
  K.events = (name, sched, kinds = ['tap', 'click']) => {
    const c = K.clips[name]; const out = [];
    for (const e of sched) for (const ev of c.events) if (ev.mark === e.mark && kinds.includes(ev.kind)) out.push({ ...ev, at: e.at });
    return out.sort((a, b) => a.at - b.at);
  };
  K.drawClip = (ctx, name, u, sched, w, h) => {
    const im = K.frame(name, u, sched); const c = K.clips[name];
    if (im) ctx.drawImage(im, 0, 0, w ?? c.clip.width, h ?? c.clip.height);
  };

  // ------------------------------------------------------------ cursor (laptop) and taps (phone)
  K.cursorPos = (name, u, sched, { start = null } = {}) => {
    const ev = K.events(name, sched, ['click']);
    if (!ev.length) return start || [700, 450];
    const c0 = start || [ev[0].x + 260, ev[0].y + 220];
    let prev = { x: c0[0], y: c0[1], at: -1e9 };
    for (const e of ev) {
      const d = Math.hypot(e.x - prev.x, e.y - prev.y);
      const move = clamp(d / 500, 0.7, 1.8);
      const a = Math.max(prev.at + 0.25, e.at - 0.1 - move), b = e.at - 0.08;
      if (u < b) {
        const p = E.inOutCubic(prog(u, a, b));
        const arc = Math.sin(p * Math.PI) * Math.min(60, d * 0.12);
        const nx = -(e.y - prev.y) / (d || 1), ny = (e.x - prev.x) / (d || 1);
        return [lerp(prev.x, e.x, p) + nx * arc, lerp(prev.y, e.y, p) + ny * arc];
      }
      prev = e;
    }
    return [prev.x, prev.y];
  };
  // draw the cursor in clip css px (call inside the screen transform); size in clip px
  K.cursor = (ctx, name, u, sched, { size = 22, start } = {}) => {
    const [x, y] = K.cursorPos(name, u, sched, { start });
    const ev = K.events(name, sched, ['click']);
    let press = 0; for (const e of ev) press = Math.max(press, M.bump(u, e.at, 0.18));
    for (const e of ev) { // click ring
      const p = prog(u, e.at, e.at + 0.7); if (p <= 0 || p >= 1) continue;
      ctx.beginPath(); ctx.arc(e.x, e.y, 8 + 26 * E.outCubic(p), 0, M.TAU);
      ctx.strokeStyle = `rgba(10,127,224,${0.55 * (1 - p)})`; ctx.lineWidth = 3; ctx.stroke();
    }
    ctx.save(); ctx.translate(x, y); const s = (size / 22) * (1 - 0.14 * press); ctx.scale(s, s);
    ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(0, 21); ctx.lineTo(5.2, 16.2); ctx.lineTo(9, 24.5); ctx.lineTo(12.6, 23); ctx.lineTo(8.9, 14.8); ctx.lineTo(15.6, 14.8); ctx.closePath();
    ctx.shadowColor = 'rgba(0,0,0,.28)'; ctx.shadowBlur = 6; ctx.shadowOffsetY = 2;
    ctx.fillStyle = '#0E1530'; ctx.fill(); ctx.shadowColor = 'transparent';
    ctx.lineWidth = 1.6; ctx.strokeStyle = '#fff'; ctx.stroke();
    ctx.restore();
  };
  K.taps = (ctx, name, u, sched) => {
    for (const e of K.events(name, sched, ['tap'])) K.ripple(ctx, e.x, e.y, u, e.at);
  };
  K.ripple = (ctx, x, y, u, at) => {
    const pre = prog(u, at - 0.35, at), post = prog(u, at, at + 0.75);
    if (pre <= 0 || post >= 1) return;
    const a = pre < 1 ? E.outCubic(pre) : 1 - E.inQuad(post);
    ctx.beginPath(); ctx.arc(x, y, 19 - 3 * M.bump(u, at, 0.15), 0, M.TAU); ctx.fillStyle = `rgba(14,21,48,${0.22 * a})`; ctx.fill();
    ctx.lineWidth = 2; ctx.strokeStyle = `rgba(255,255,255,${0.8 * a})`; ctx.stroke();
    if (post > 0) { ctx.beginPath(); ctx.arc(x, y, 18 + 34 * E.outCubic(post), 0, M.TAU); ctx.strokeStyle = `rgba(10,127,224,${0.5 * (1 - post)})`; ctx.lineWidth = 3; ctx.stroke(); }
  };

  // ------------------------------------------------------------ devices
  // Phone: screen is 368 x 822 css px inside an 11px bezel (the prototype's own 390 x 844 device).
  // h = on-canvas height of the whole device. screen(ctx) draws in screen css px.
  K.phone = (ctx, cx, cy, h, screen, { rot = 0, shadow = 1, alpha = 1 } = {}) => {
    const s = h / 844;
    ctx.save(); ctx.globalAlpha *= alpha; ctx.translate(cx, cy); ctx.rotate(rot); ctx.scale(s, s); ctx.translate(-195, -422);
    if (shadow) { ctx.save(); ctx.shadowColor = `rgba(14,24,70,${0.26 * shadow})`; ctx.shadowBlur = 90; ctx.shadowOffsetY = 40; rrect(ctx, 0, 0, 390, 844, 58); ctx.fillStyle = '#04060C'; ctx.fill(); ctx.restore(); }
    rrect(ctx, 0, 0, 390, 844, 58); ctx.fillStyle = '#04060C'; ctx.fill();
    ctx.lineWidth = 2; ctx.strokeStyle = '#2A2F3D'; ctx.stroke();
    ctx.save(); ctx.translate(11, 11); rrect(ctx, 0, 0, 368, 822, 47); ctx.clip(); ctx.fillStyle = '#F4F6FA'; ctx.fillRect(0, 0, 368, 822);
    screen(ctx);
    ctx.restore(); ctx.restore();
  };
  // Laptop: screen rect at (x, y) w wide (16:10). view(ctx) draws in screen css px (1440 x 900).
  K.laptop = (ctx, x, y, w, view, { base = true, alpha = 1 } = {}) => {
    const h = w * 0.625, pad = w * 0.018;
    ctx.save(); ctx.globalAlpha *= alpha;
    ctx.save(); ctx.shadowColor = 'rgba(14,24,70,.22)'; ctx.shadowBlur = 80; ctx.shadowOffsetY = 36;
    rrect(ctx, x - pad, y - pad, w + 2 * pad, h + 2 * pad * 1.15, pad * 1.4); ctx.fillStyle = '#0B0F1C'; ctx.fill(); ctx.restore();
    if (base) {
      const bw = w * 1.17, bh = w * 0.03, by = y + h + pad * 2.15;
      ctx.beginPath(); ctx.moveTo(x + w / 2 - bw / 2, by); ctx.lineTo(x + w / 2 + bw / 2, by); ctx.lineTo(x + w / 2 + bw / 2 - bh * 0.6, by + bh); ctx.lineTo(x + w / 2 - bw / 2 + bh * 0.6, by + bh); ctx.closePath();
      const g = ctx.createLinearGradient(0, by, 0, by + bh); g.addColorStop(0, '#D9DEE8'); g.addColorStop(1, '#9AA3BC'); ctx.fillStyle = g; ctx.fill();
      rrect(ctx, x + w / 2 - w * 0.08, by, w * 0.16, bh * 0.32, bh * 0.3); ctx.fillStyle = '#AEB6C8'; ctx.fill();
    }
    ctx.save(); ctx.beginPath(); ctx.rect(x, y, w, h); ctx.clip(); ctx.translate(x, y); ctx.scale(w / 1440, w / 1440);
    view(ctx);
    ctx.restore(); ctx.restore();
  };
  // A browser-window card showing part of the admin screen (portrait / square formats).
  K.window = (ctx, x, y, w, h, view, { radius = 26, alpha = 1 } = {}) => {
    ctx.save(); ctx.globalAlpha *= alpha;
    ctx.save(); ctx.shadowColor = 'rgba(14,24,70,.22)'; ctx.shadowBlur = 70; ctx.shadowOffsetY = 30; rrect(ctx, x, y, w, h, radius); ctx.fillStyle = '#fff'; ctx.fill(); ctx.restore();
    rrect(ctx, x, y, w, h, radius); ctx.clip(); ctx.translate(x, y);
    view(ctx, w, h);
    ctx.restore();
  };
  // Camera for a 1440 x 900 admin frame inside a box of bw x bh canvas px: zoom about focus (fx, fy), clamped to the frame.
  K.cam = (ctx, bw, bh, fx, fy, zoom) => {
    const s = Math.max(bw / 1440, bh / 900) * zoom;
    let tx = bw / 2 - fx * s, ty = bh / 2 - fy * s;
    tx = clamp(tx, bw - 1440 * s, 0); ty = clamp(ty, bh - 900 * s, 0);
    ctx.translate(tx, ty); ctx.scale(s, s);
  };

  // ------------------------------------------------------------ lock screen + notifications (new screen 1)
  K.lock = (ctx, { time = '7:42', date = 'Saturday 3 October', dim = 0 } = {}) => {
    const g = ctx.createLinearGradient(0, 0, 368, 822); g.addColorStop(0, '#0B1A5C'); g.addColorStop(0.55, '#14246B'); g.addColorStop(1, '#0A7FE0');
    ctx.fillStyle = g; ctx.fillRect(0, 0, 368, 822);
    const lg = K.img('../journeys/assets/logo-white.png');
    if (lg) { ctx.save(); ctx.globalAlpha = 0.08; ctx.drawImage(lg, 64, 430, 300, 300); ctx.restore(); }
    ctx.fillStyle = '#fff'; ctx.textAlign = 'center';
    ctx.font = font(15, 600, UI); ctx.fillText('9:41', 54, 31); ctx.textAlign = 'right'; ctx.fillText('4G', 316, 31); ctx.textAlign = 'center';
    ctx.font = font(18, 600, UI); ctx.globalAlpha = 0.9; ctx.fillText(date, 184, 112); ctx.globalAlpha = 1;
    ctx.font = font(92, 600, DISPLAY); ctx.fillText(time, 184, 200);
    ctx.textAlign = 'left';
    if (dim) { ctx.fillStyle = `rgba(5,10,30,${dim})`; ctx.fillRect(0, 0, 368, 822); }
  };
  // A push banner in phone screen px. k = 0..1 entrance; app = 'church' | 'sms'
  K.banner = (ctx, { x = 10, y = 54, w = 348, title, body, app = 'church', when = 'now', k = 1, press = 0 }) => {
    if (k <= 0) return { x, y, w, h: 0 };
    ctx.save();
    ctx.font = font(15, 500, UI);
    const lines = wrap(ctx, body, w - 32 - 50);
    const h = 58 + lines.length * 20;
    ctx.translate(x + w / 2, y + h / 2); const s = 0.94 + 0.06 * k - 0.025 * press; ctx.scale(s, s); ctx.translate(-(x + w / 2), -(y + h / 2));
    ctx.translate(0, (1 - k) * -(y + h + 20));
    ctx.shadowColor = 'rgba(5,10,30,.28)'; ctx.shadowBlur = 30; ctx.shadowOffsetY = 10;
    rrect(ctx, x, y, w, h, 24); ctx.fillStyle = 'rgba(248,249,252,0.97)'; ctx.fill(); ctx.shadowColor = 'transparent';
    // app icon
    rrect(ctx, x + 14, y + 14, 38, 38, 10); ctx.fillStyle = app === 'sms' ? '#2DBE60' : C.navy; ctx.fill();
    if (app === 'sms') { ctx.fillStyle = '#fff'; ctx.beginPath(); ctx.ellipse(x + 33, y + 31, 12, 9.5, 0, 0, M.TAU); ctx.fill(); ctx.beginPath(); ctx.moveTo(x + 25, y + 36); ctx.lineTo(x + 22, y + 43); ctx.lineTo(x + 31, y + 39); ctx.fill(); }
    else { const lg = K.img('../journeys/assets/logo-white.png'); if (lg) ctx.drawImage(lg, x + 17, y + 17, 32, 32); }
    ctx.fillStyle = C.ink; ctx.font = font(15, 700, UI); ctx.fillText(title, x + 64, y + 31);
    ctx.fillStyle = '#7A8299'; ctx.font = font(13, 500, UI); ctx.textAlign = 'right'; ctx.fillText(when, x + w - 16, y + 30); ctx.textAlign = 'left';
    ctx.fillStyle = '#2A3150'; ctx.font = font(15, 500, UI);
    lines.forEach((l, i) => ctx.fillText(l, x + 64, y + 52 + i * 20));
    ctx.restore();
    return { x, y, w, h };
  };
  function wrap(ctx, str, maxW) {
    const words = str.split(' '); const out = []; let cur = '';
    for (const w of words) { const t = cur ? cur + ' ' + w : w; if (ctx.measureText(t).width > maxW && cur) { out.push(cur); cur = w; } else cur = t; }
    if (cur) out.push(cur); return out;
  }
  K.wrap = wrap;

  // ------------------------------------------------------------ type
  // Kinetic headline: words rise on springs, staggered; exit drops them. lines: [[text, color], ...]
  K.headline = (ctx, lines, x, y, size, u, u0, { exit = null, align = 'left', lh = 1.02, stagger = 0.12, weight = 700 } = {}) => {
    const f = font(size, weight, DISPLAY); ctx.font = f; ctx.letterSpacing = `${-0.02 * size}px`;
    let n = 0;
    lines.forEach(([str, color], li) => {
      const words = str.split(' ');
      const total = ctx.measureText(str).width;
      let cx = align === 'center' ? x - total / 2 : align === 'right' ? x - total : x;
      const by = y + li * size * lh;
      words.forEach((w) => {
        const ww = ctx.measureText(w + ' ').width;
        const k = springU(u, u0 + n * stagger, SPRING.snappy);
        const out = exit != null ? E.inBack(prog(u, exit + n * 0.03, exit + 0.4 + n * 0.03), 1.3) : 0;
        if (k > 0.001 && out < 1) {
          ctx.save(); ctx.beginPath(); ctx.rect(cx - size, by - size * 1.05, ww + size * 2, size * 1.35); ctx.clip();
          ctx.fillStyle = color; ctx.globalAlpha = Math.min(1, k * 1.4) * (1 - out);
          ctx.fillText(w, cx, by + (1 - k) * size * 0.9 + out * size * 0.9);
          ctx.restore();
        }
        cx += ww; n++;
      });
    });
    ctx.letterSpacing = '0px';
  };
  // largest size <= size at which every line fits maxW
  K.fit = (ctx, lines, size, maxW, weight = 700) => {
    ctx.font = font(100, weight, DISPLAY); ctx.letterSpacing = '-2px';
    const w = Math.max(...lines.map(([t]) => ctx.measureText(t).width)); ctx.letterSpacing = '0px';
    return Math.min(size, Math.floor((100 * maxW) / w));
  };
  K.kicker = (ctx, str, x, y, size, u, u0, { color = C.blue, exit = null, align = 'left' } = {}) => {
    const p = E.outCubic(prog(u, u0, u0 + 0.6)); const out = exit != null ? prog(u, exit, exit + 0.35) : 0;
    if (p <= 0 || out >= 1) return;
    ctx.save(); ctx.globalAlpha = p * (1 - out); ctx.font = font(size, 700, UI); ctx.letterSpacing = `${size * 0.22}px`; ctx.fillStyle = color; ctx.textAlign = align;
    ctx.fillText(str.toUpperCase(), x + (1 - p) * -24, y); ctx.restore(); ctx.letterSpacing = '0px';
  };
  K.body = (ctx, str, x, y, size, u, u0, { color = C.mut, exit = null, maxW = 9999, align = 'left', lh = 1.32, weight = 500 } = {}) => {
    const p = E.outCubic(prog(u, u0, u0 + 0.7)); const out = exit != null ? prog(u, exit, exit + 0.35) : 0;
    if (p <= 0 || out >= 1) return;
    ctx.save(); ctx.globalAlpha = p * (1 - out); ctx.font = font(size, weight, UI); ctx.fillStyle = color; ctx.textAlign = align;
    wrap(ctx, str, maxW).forEach((l, i) => ctx.fillText(l, x, y + i * size * lh + (1 - p) * 20));
    ctx.restore();
  };
  // A small pill label, e.g. "1 · Accept" or a weekday
  K.pill = (ctx, str, x, y, size, k, { bg = C.navy, fg = '#fff', align = 'left' } = {}) => {
    if (k <= 0) return;
    ctx.save(); ctx.font = font(size, 700, UI); const tw = ctx.measureText(str).width; const w = tw + size * 1.4, h = size * 2;
    const x0 = align === 'center' ? x - w / 2 : align === 'right' ? x - w : x;
    ctx.translate(x0 + w / 2, y + h / 2); ctx.scale(k, k); ctx.translate(-(x0 + w / 2), -(y + h / 2));
    rrect(ctx, x0, y, w, h, h / 2); ctx.fillStyle = bg; ctx.fill(); ctx.fillStyle = fg; ctx.textBaseline = 'middle'; ctx.fillText(str, x0 + size * 0.7, y + h / 2 + 1);
    ctx.restore();
  };

  // ------------------------------------------------------------ backgrounds
  K.bg = (ctx, u, { dark = 0 } = {}) => {
    ctx.fillStyle = dark ? M.mix(C.paper, C.night, dark) : C.paper; ctx.fillRect(0, 0, W, H);
    const blobs = [[0.82, 0.18, 0.55, '#DCE7FA'], [0.12, 0.92, 0.45, '#E6ECFB']];
    blobs.forEach(([bx, by, r, col], i) => {
      const x = (bx + 0.03 * M.noise1(u * 0.05, 3 + i)) * W, y = (by + 0.03 * M.noise1(u * 0.05, 7 + i)) * H, R = r * Math.max(W, H);
      const g = ctx.createRadialGradient(x, y, 0, x, y, R); g.addColorStop(0, dark ? 'rgba(20,36,107,.35)' : col); g.addColorStop(1, dark ? 'rgba(20,36,107,0)' : 'rgba(244,246,250,0)');
      ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
    });
  };
  // End card: emblem + lines, shared by all films.
  K.endCard = (ctx, u, u0, { line1, line2 = 'Kafue Brethren in Christ Church App', foot = '' } = {}) => {
    K.bg(ctx, u);
    const s = FORMAT.safe; const portrait = FORMAT.portrait;
    const logo = K.img('../journeys/assets/logo.png');
    const ls = FORMAT.pick({ '16x9': 230, '9x16': 300, '1x1': 220 });
    const k = springU(u, u0 - 0.35, SPRING.bouncy);
    const lx = portrait || FORMAT.square ? W / 2 : s.x + ls / 2, ly = portrait ? s.y + s.h * 0.3 : FORMAT.square ? H * 0.3 : H / 2;
    if (logo && k > 0) { ctx.save(); ctx.translate(lx, ly); ctx.scale(k, k); ctx.rotate((1 - k) * -0.4); ctx.shadowColor = 'rgba(14,24,70,.18)'; ctx.shadowBlur = 40; ctx.shadowOffsetY = 14; ctx.beginPath(); ctx.arc(0, 0, ls / 2, 0, M.TAU); ctx.fillStyle = '#fff'; ctx.fill(); ctx.shadowColor = 'transparent'; ctx.clip(); ctx.drawImage(logo, -ls / 2, -ls / 2, ls, ls); ctx.restore(); }
    const center = portrait || FORMAT.square;
    const tx = center ? W / 2 : lx + ls / 2 + 70, align = center ? 'center' : 'left';
    const size = K.fit(ctx, [[line1]], FORMAT.pick({ '16x9': 96, '9x16': 92, '1x1': 74 }), center ? s.w : W - (lx + ls / 2 + 70) - s.x);
    const ty = portrait ? s.y + s.h * 0.55 : FORMAT.square ? H * 0.6 : H / 2 - 10;
    K.headline(ctx, [[line1, C.navy]], tx, ty, size, u, u0 - 0.1, { align });
    // the app's full name, tracked caps: shrink until it fits the line it sits on
    let ks = FORMAT.pick({ '16x9': 30, '9x16': 34, '1x1': 28 }); const kw = center ? s.w : W - tx - s.x;
    ctx.font = font(ks, 700, UI); ctx.letterSpacing = `${ks * 0.22}px`; const w0 = ctx.measureText(line2.toUpperCase()).width; ctx.letterSpacing = '0px';
    if (w0 > kw) ks = Math.floor(ks * kw / w0);
    K.kicker(ctx, line2, tx, ty + size * 0.9, ks, u, u0 + 0.8, { align });
    if (foot) K.body(ctx, foot, tx, ty + size * 0.9 + FORMAT.pick({ '16x9': 64, '9x16': 76, '1x1': 58 }), FORMAT.pick({ '16x9': 28, '9x16': 32, '1x1': 26 }), u, u0 + 1.2, { align, maxW: center ? s.w : W - tx - s.x });
  };
  return K;
}
