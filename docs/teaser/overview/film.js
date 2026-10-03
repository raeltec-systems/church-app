// Overview: the BIC Kafue app in 60 seconds. Pure function of time; 120 bpm (0.5 s/beat), 120 beats, drop at 20.
// Plan: docs/shotlist.md. Footage: the member and admin recordings in rec/ (journeys/rec-*.mjs).
import * as M from './lib/motion.js';
import { makeKit } from '../journeys/kit.js';

const { W, H, FORMAT, E, prog, lerp, springU, springKeys, SPRING, font, rrect } = M;
const K = makeKit(M);
const { C } = K;
const P = FORMAT.portrait, SQ = FORMAT.square, LS = FORMAT.landscape;
const S = FORMAT.safe;

const HOME = [{ at: 20, mark: 'home-down' }, { at: 22.5, mark: 'home-up', dur: 1 }];
const DUTY = [{ at: 31, mark: 'start' }, { at: 32.5, mark: 'accept' }];
const HYMN = [{ at: 36, mark: 'start' }, { at: 36.5, mark: 'tab' }, { at: 37.5, mark: 'hymnbook' }, { at: 39, mark: 'hymn' }, { at: 40, mark: 'read' }];
const SERMON = [{ at: 44, mark: 'start' }, { at: 44.5, mark: 'tab' }, { at: 45.5, mark: 'list' }, { at: 48, mark: 'open' }];
const CAL = [{ at: 52, mark: 'start' }, { at: 52.5, mark: 'tab' }, { at: 53.5, mark: 'down' }, { at: 56.5, mark: 'event' }];
const CELL = [{ at: 60, mark: 'start' }, { at: 60.5, mark: 'down' }];
const VISIT = [{ at: 68, mark: 'start' }, { at: 70, mark: 'accept' }];
const GIVE = [{ at: 76, mark: 'start' }, { at: 76.5, mark: 'tab' }, { at: 78, mark: 'airtel' }, { at: 80.5, mark: 'copy' }];
const DARK = [{ at: 84, mark: 'start' }, { at: 86.5, mark: 'dark' }, { at: 88, mark: 'down' }];
const ADMIN = [{ at: 92, mark: 'start' }, { at: 93, mark: 'rotas' }, { at: 96.5, mark: 'meetings' }, { at: 97.5, mark: 'topic' }, { at: 98, mark: 'topic:type' }, { at: 100.5, mark: 'pastor' }, { at: 101.5, mark: 'care' }];

const HITS = [
  [0, 'bubble 1', 'pop', { pitch: 'A5' }], [1.5, 'bubble 2', 'pop', { pitch: 'D6' }], [3, 'bubble 3', 'pop', { pitch: 'F#5' }],
  [4.5, 'bubble 4', 'pop', { pitch: 'B5' }], [6, 'bubble 5', 'pop', { pitch: 'E6' }], [8, 'sound familiar', 'thud'],
  [12, 'what if', 'whoosh', { len: 0.5 }], [14, 'emblem', 'bell', { pitch: 'D6' }], [20, 'DROP', 'riser', { len: 3 }], [20, 'drop', 'impact'],
  [28, 'duties', 'whoosh', { len: 0.3 }], [29, 'push', 'blip', { pitch: 'A6' }], [31, 'tap', 'tick'], [32.5, 'accept', 'click'], [33.3, 'accepted', 'bell', { pitch: 'A5' }],
  [36, 'hymns', 'whoosh', { len: 0.3 }], [37.5, 'tab', 'tick'], [39, 'hymn', 'tick'],
  [44, 'sermons', 'whoosh', { len: 0.3 }], [48, 'sermon', 'tick'],
  [52, 'calendar', 'whoosh', { len: 0.3 }], [56.5, 'event', 'tick'],
  [60, 'cell', 'whoosh', { len: 0.3 }], [62, 'part', 'blip', { pitch: 'D6' }],
  [68, 'visits', 'whoosh', { len: 0.3 }], [70, 'accept visit', 'click'], [70.3, 'confirmed', 'bell', { pitch: 'F#5' }],
  [76, 'giving', 'whoosh', { len: 0.3 }], [78, 'airtel', 'tick'], [80.5, 'copy', 'coins'],
  [84, 'dark mode', 'whoosh', { len: 0.3 }], [86.5, 'dark', 'whoosh', { len: 0.5, from: 2400, to: 400 }],
  [92, 'admin', 'impact'], [93, 'rotas', 'click'], [96.5, 'meetings', 'click'], [98, 'typing', 'type', { len: 0.8, n: 9 }], [100.5, 'pastor', 'click'], [101.5, 'care', 'click'],
  [104, 'wall', 'impact'], [108, 'family', 'swell'], [116, 'end card', 'impact'], [116, 'logo', 'bell', { pitch: 'D6' }],
];

// ------------------------------------------------------------ intro: the Sunday group chat (type only)
const CHAT = [
  [-1.2, 'Who’s on the main door on Sunday?', 'Esther', 0], [-0.2, 'What hymn number was that?? 🙏', 'Peter', 1],
  [3, 'Is cell still at the Bandas’ on Thursday?', 'Ruth', 0], [4.5, 'Sorry, who did I give my offering envelope to?', 'Abel', 1],
  [6, 'Can someone send the sermon notes?', 'Joyce', 0],
];
function intro(ctx, u) {
  K.bg(ctx, u);
  if (u < 12) chat(ctx, u);
  titles(ctx, u);
}
function chat(ctx, u) {
  const out = E.inBack(prog(u, 11, 12), 1.2);
  const fs = FORMAT.pick({ '16x9': 44, '9x16': 44, '1x1': 36 }), bw = FORMAT.pick({ '16x9': 1000, '9x16': 920, '1x1': 900 });
  const x0 = LS ? W / 2 - bw / 2 : (W - bw) / 2;
  const base = LS ? H * 0.72 : P ? H * 0.62 : H * 0.7;
  CHAT.forEach(([at, txt, who, side], i) => {
    const k = springU(u, at, SPRING.bouncy); if (k <= 0) return;
    const later = CHAT.filter((c) => u >= c[0] && c[0] > at).length; // pushed up by newer bubbles
    const step = fs * 3.2;
    const y = base - springKeys(u, [[0, 0], ...CHAT.slice(i + 1).map((c, j) => [c[0], (j + 1) * step])], SPRING.snappy) + (1 - k) * 60;
    ctx.save(); ctx.globalAlpha = Math.min(1, k) * (1 - out) * (1 - 0.12 * later);
    ctx.font = font(fs, 500, K.UI); const tw = Math.min(bw - 80, ctx.measureText(txt).width);
    const w = tw + fs * 1.4, h = fs * 2.1, x = side ? x0 + bw - w : x0;
    ctx.translate(x + w / 2, y + h / 2); ctx.scale(k, k); ctx.translate(-(x + w / 2), -(y + h / 2));
    rrect(ctx, x, y, w, h, h / 2); ctx.fillStyle = side ? C.blue : '#fff'; ctx.fill();
    ctx.fillStyle = side ? '#fff' : C.ink; ctx.fillText(txt, x + fs * 0.7, y + h * 0.66);
    ctx.font = font(fs * 0.55, 700, K.UI); ctx.fillStyle = C.mut; ctx.fillText(who, x + (side ? w - ctx.measureText(who).width - 8 : 8), y - 8);
    ctx.restore();
  });
}
function titles(ctx, u) {
  const sz = FORMAT.pick({ '16x9': 110, '9x16': 110, '1x1': 84 });
  K.headline(ctx, [['Sound familiar?', C.navy]], W / 2, LS ? 230 : S.y + 140, sz, u, 8, { align: 'center', exit: 11.4 });
  // what if it was all in one place? -> the emblem
  if (u > 11.5) {
    K.headline(ctx, [['What if it was all', C.navy], ['in one place?', C.blue]], W / 2, LS ? 300 : P ? S.y + 260 : S.y + 150, FORMAT.pick({ '16x9': 96, '9x16': 96, '1x1': 72 }), u, 12, { align: 'center', exit: 19.6 });
    const logo = K.img('../journeys/assets/logo.png'); const k = springU(u, 14, SPRING.bouncy) * (1 - E.inBack(prog(u, 19.4, 20), 1.5));
    const ls = FORMAT.pick({ '16x9': 280, '9x16': 380, '1x1': 280 });
    if (logo && k > 0) { ctx.save(); ctx.translate(W / 2, LS ? 690 : P ? H * 0.58 : H * 0.62); ctx.scale(k, k); ctx.rotate((1 - k) * 0.5 + 0.03 * Math.sin(u)); ctx.beginPath(); ctx.arc(0, 0, ls / 2, 0, M.TAU); ctx.fillStyle = '#fff'; ctx.shadowColor = 'rgba(14,24,70,.18)'; ctx.shadowBlur = 50; ctx.fill(); ctx.shadowColor = 'transparent'; ctx.drawImage(logo, -ls / 2, -ls / 2, ls, ls); ctx.restore(); }
  }
}

// ------------------------------------------------------------ features
const FEATURES = [
  [20, 28, 'Your church.', 'In your pocket.', 'Brethren in Christ Church Kafue'],
  [28, 36, 'Duties,', 'answered in a tap.', 'Your leader sees it straight away.'],
  [36, 44, 'Bible and', 'hymn book.', 'Find hymn 58 before the first verse ends.'],
  [44, 52, 'Every sermon,', 'any time.', 'Listen again, read the notes.'],
  [52, 60, 'What’s on,', 'all month.', 'Services, fellowship days, youth camp.'],
  [60, 68, 'Your cell', 'group.', 'Next meeting, who leads each part.'],
  [68, 76, 'Pastoral', 'visits.', 'Private between you and the pastoral team.'],
  [76, 84, 'Giving,', 'made clear.', 'Mobile money and bank steps. The app never takes payment.'],
  [84, 92, 'Easy on', 'the eyes.', 'Dark mode for evening services.'],
  [92, 104, 'Run by the', 'church office.', 'Duty rotas, cell meetings and pastoral care on the web.'],
];
const PH = LS ? { cx: 1340, cy: H / 2 + 10, h: 960 } : P ? { cx: W / 2, cy: S.y + 330 + 560, h: 1150 } : { cx: W / 2 + 190, cy: H / 2 + 30, h: 880 };
const T = { x: S.x, y: LS ? 470 : P ? S.y + 130 : 420, align: LS || SQ ? 'left' : 'center', size: FORMAT.pick({ '16x9': 104, '9x16': 90, '1x1': 64 }), body: FORMAT.pick({ '16x9': 32, '9x16': 34, '1x1': 26 }), maxW: LS ? 640 : SQ ? 420 : S.w };
if (P) T.x = W / 2;
const screen = (clip, sched) => (c, u) => { K.drawClip(c, clip, u, sched, 368, 822); K.taps(c, clip, u, sched); };
function phoneScreen(c, u) {
  if (u < 28) { K.drawClip(c, 'signup', u, HOME, 368, 822); return; }
  if (u < 36) {
    if (u < 31) {
      K.lock(c, { time: '7:15', date: 'Monday 28 September' });
      const b = K.banner(c, { y: 250, title: 'New duty · Main door', body: 'Sunday 4 October, report 08:30. Can you serve?', k: springU(u, 29, SPRING.snappy), press: M.bump(u, 30.8, 0.25) });
      K.ripple(c, 184, b.y + b.h / 2, u, 30.8); return;
    }
    screen('duty', DUTY)(c, u); return;
  }
  if (u < 44) return screen('hymn', HYMN)(c, u);
  if (u < 52) return screen('sermon', SERMON)(c, u);
  if (u < 60) return screen('calendar', CAL)(c, u);
  if (u < 68) return screen('mycell', CELL)(c, u);
  if (u < 76) return screen('visit-accept', VISIT)(c, u);
  if (u < 84) return screen('give', GIVE)(c, u);
  return screen('dark', DARK)(c, u);
}
function admin(ctx, u) {
  const k = springU(u, 91.6, SPRING.gentle), out = E.inOutCubic(prog(u, 103.4, 104.2));
  const view = (c, bw, bh, z, f) => { c.save(); K.cam(c, bw, bh, f[0], f[1], z); K.drawClip(c, 'admin-tour', u, ADMIN, 1440, 900); K.cursor(c, 'admin-tour', u, ADMIN, { size: 24, start: [900, 600] }); c.restore(); };
  const f = springKeys(u, [[92, [400, 300]], [96, [700, 380]], [99.5, [300, 300]], [101.5, [800, 400]]], SPRING.gentle);
  if (LS) K.laptop(ctx, W - S.x - 1100 + 20 + (1 - k) * 900 - out * 1500, (H - 1100 * 0.625) / 2 - 16, 1100, (c) => view(c, 1440, 900, 1, f));
  else { const w = S.w + 40, h = P ? 900 : 640; K.window(ctx, (W - w) / 2 + (1 - k) * 1200 - out * 1500, P ? S.y + 330 : S.y + 150, w, P ? 1100 : 780, (c, bw, bh) => view(c, bw, bh, P ? 1.25 : 1.05, f)); }
}
function wall(ctx, u) {
  const shots = [['hymn', 30], ['sermon', 46], ['give', 30], ['calendar', 58], ['visit-accept', 26], ['mycell', 65], ['duty', 27], ['dark', 82], ['recap', 70], ['coverage', 120]];
  const cols = LS ? 6 : P ? 3 : 4, rows = LS ? 1 : P ? 3 : 1;
  const h = LS ? 560 : P ? 560 : 450, gap = LS ? 290 : P ? 320 : 250;
  const n = cols * rows;
  const drift = (u - 108) * (LS ? 10 : 6);
  shots.slice(0, n).forEach(([clip, idx], i) => {
    const col = i % cols, row = Math.floor(i / cols);
    const cx = W / 2 + (col - (cols - 1) / 2) * gap - drift * (row % 2 ? -1 : 1);
    const cy = (LS ? H / 2 + 110 : P ? S.y + 470 + row * 560 : H / 2 + 120) + (col % 2 ? 30 : -30);
    const k = springU(u, 104 + i * 0.2, SPRING.gentle);
    if (k <= 0) return;
    K.phone(ctx, cx, cy + (1 - k) * 700, h, (c) => { const im = K.frameAt(clip, idx); if (im) c.drawImage(im, 0, 0, 368, 822); }, { rot: (col - (cols - 1) / 2) * 0.025, shadow: 0.5, alpha: 1 - prog(u, 115.4, 116) });
  });
  K.headline(ctx, [['Made for our church family.', C.navy]], W / 2, LS ? 170 : P ? S.y + 90 : S.y + 70, FORMAT.pick({ '16x9': 88, '9x16': 72, '1x1': 60 }), u, 106, { align: 'center', exit: 115.4 });
}

function draw(ctx, u) {
  if (u < 20) { intro(ctx, u); return; }
  const dark = E.inOutCubic(prog(u, 86.5, 88)) * (1 - prog(u, 91.5, 92.2));
  K.bg(ctx, u, { dark });
  if (u >= 116) { K.endCard(ctx, u, 116, { line1: 'Your church. In your pocket.', foot: 'Coming soon to Android and iPhone · “Know therefore that the LORD thy God, he is God, the faithful God.” Deut 7:9' }); return; }
  if (u >= 104) { wall(ctx, u); return; }
  for (const [a, b, l1, l2, body] of FEATURES) {
    if (u < a - 0.5 || u > b + 0.6) continue;
    const L = [[l1, M.mix(C.navy, '#FFFFFF', dark)], [l2, M.mix(C.blue, '#8EC1FF', dark)]];
    if (a === 92 && SQ) { // admin: the window takes the frame, the line goes on top
      K.headline(ctx, [[`${l1} ${l2}`, C.navy]], W / 2, S.y + 90, 60, u, a + 0.1, { exit: b - 0.4, align: 'center' });
      continue;
    }
    const sz = K.fit(ctx, L, a === 20 ? T.size * 1.15 : T.size, T.maxW);
    K.headline(ctx, L, T.x, T.y, sz, u, a + 0.1, { exit: b - 0.4, align: T.align });
    K.body(ctx, body, T.x, T.y + sz * 1.02 + T.body * 1.9, T.body, u, a + 0.6, { exit: b - 0.4, align: T.align, maxW: T.maxW, color: dark > 0.5 ? '#9AA3BC' : C.mut });
  }
  if (u < 92.5) {
    const k = springU(u, 19.6, SPRING.bouncy), out = E.inOutCubic(prog(u, 91.4, 92.4));
    const q = 0.05 * M.wobble(u - 20, 2.2, 5);
    K.phone(ctx, PH.cx + out * 1300, PH.cy + (1 - k) * 900, PH.h * (1 + q), (c) => {
      phoneScreen(c, u);
      for (let cut = 28; cut <= 84; cut += 8) { const w = 0.5 * M.bump(u, cut, 0.25); if (w > 0) { c.fillStyle = `rgba(244,246,250,${w})`; c.fillRect(0, 0, 368, 822); } }
    });
  }
  if (u > 91) admin(ctx, u);
}

K.start({
  clips: ['signup', 'duty', 'hymn', 'sermon', 'calendar', 'mycell', 'visit-accept', 'give', 'dark', 'admin-tour', 'recap', 'coverage'],
  images: ['../journeys/assets/logo.png', '../journeys/assets/logo-white.png'],
  hits: HITS, draw,
});
