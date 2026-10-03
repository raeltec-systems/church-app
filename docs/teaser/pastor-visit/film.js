// Pastor journey: a pastoral visit. Pure function of time; timing in beats (96 bpm, 0.625 s).
// Plan: docs/shotlist.md. Footage: rec/pastor-board (admin), rec/visit-* (member phone), from journeys/rec-pastor.mjs.
import * as M from './lib/motion.js';
import { makeKit } from '../journeys/kit.js';

const { W, H, FORMAT, E, prog, lerp, clamp, springU, springKeys, SPRING } = M;
const K = makeKit(M);
const { C } = K;
const P = FORMAT.portrait, SQ = FORMAT.square, LS = FORMAT.landscape;
const S = FORMAT.safe;

// ------------------------------------------------------------ schedules (beat -> clip mark)
const BOARD = [
  { at: 0, mark: 'start' }, { at: 7, mark: 'open' },
  { at: 9.5, mark: 'member' }, { at: 11, mark: 'member:choose' },
  { at: 12.5, mark: 'reason' }, { at: 14, mark: 'reason:choose' },
  { at: 15.5, mark: 'who' }, { at: 17, mark: 'who:choose' },
  { at: 18.75, mark: 'time' },
  { at: 20.5, mark: 'where' }, { at: 22, mark: 'where:choose' },
  { at: 25, mark: 'send' },
  { at: 67, mark: 'o-accept' }, { at: 71.9, mark: 'reset1' }, { at: 72, mark: 'o-decline' },
  { at: 76.9, mark: 'reset2' }, { at: 77, mark: 'o-suggest' }, { at: 83, mark: 'accept-new' },
];
const ACCEPT = [{ at: 38, mark: 'start' }, { at: 42.5, mark: 'accept' }];
const DECLINE = [{ at: 48, mark: 'start' }, { at: 49.5, mark: 'decline' }, { at: 51.25, mark: 'note' }, { at: 51.75, mark: 'typing' }, { at: 56.5, mark: 'send' }];
const SUGGEST = [{ at: 58, mark: 'start' }, { at: 59.5, mark: 'suggest' }, { at: 62.5, mark: 'slot' }];
const FINAL = [{ at: 86, mark: 'start' }, { at: 90.5, mark: 'confirmed' }];

const HITS = [
  [0, 'laptop lands', 'impact'],
  [1, 'headline', 'whoosh', { len: 0.4 }],
  [7, 'click schedule', 'click'], [7.3, 'modal', 'pop', { pitch: 'C5' }],
  [9.5, 'member menu', 'tick'], [11, 'member chosen', 'click'],
  [12.5, 'reason menu', 'tick'], [14, 'reason chosen', 'click'],
  [15.5, 'who menu', 'tick'], [17, 'who chosen', 'click'],
  [18.75, 'time', 'click'], [20.5, 'where menu', 'tick'], [22, 'where chosen', 'click'],
  [25, 'send', 'click'], [25.4, 'toast', 'bell', { pitch: 'F5' }], [26, 'card lands', 'pop', { pitch: 'A5' }],
  [32, 'to the phone', 'whoosh', { len: 0.5, from: 2400, to: 500 }],
  [35, 'push arrives', 'blip', { pitch: 'C6' }], [35.2, 'push 2', 'blip', { pitch: 'F6' }],
  [38, 'tap push', 'tick'], [38.1, 'open', 'whoosh', { len: 0.3, from: 800, to: 2600 }],
  [40, 'label accept', 'pop', { pitch: 'F5' }], [42.5, 'tap accept', 'tick'], [42.8, 'confirmed', 'bell', { pitch: 'A5' }],
  [48, 'label decline', 'pop', { pitch: 'G5' }], [49.5, 'tap decline', 'tick'], [51.25, 'tap note', 'tick'],
  [51.75, 'typing', 'type', { len: 2.8, n: 22 }], [56.5, 'decline sent', 'click'], [56.8, 'toast', 'blip', { pitch: 'A5' }],
  [58, 'label suggest', 'pop', { pitch: 'A5' }], [59.5, 'tap suggest', 'tick'], [62.5, 'pick slot', 'tick'], [62.8, 'sent', 'bell', { pitch: 'C6' }],
  [66, 'back to laptop', 'whoosh', { len: 0.5, from: 500, to: 2400 }],
  [67, 'accepted lands', 'pop', { pitch: 'C5' }], [72, 'declined lands', 'pop', { pitch: 'D5' }], [77, 'suggested lands', 'pop', { pitch: 'E5' }],
  [83, 'accept new time', 'click'], [83.4, 'card to confirmed', 'bell', { pitch: 'F5' }],
  [86, 'split', 'whoosh', { len: 0.4 }], [89, 'push confirmed', 'blip', { pitch: 'C6' }], [90.5, 'phone confirmed', 'bell', { pitch: 'A5' }],
  [100, 'end card', 'impact'], [100, 'logo', 'bell', { pitch: 'F5' }],
];

// ------------------------------------------------------------ helpers
const boardFocus = (u) => {
  // camera on the admin frame: [fx, fy, zoom] in admin css px
  const zModal = FORMAT.pick({ '16x9': 1.5, '9x16': 1.5, '1x1': 1.55 });
  const zBoard = FORMAT.pick({ '16x9': 1, '9x16': 1.1, '1x1': 1.0 });
  const zCol = FORMAT.pick({ '16x9': 1.8, '9x16': 2.0, '1x1': 1.8 });
  return springKeys(u, [
    [0, [1240, 300, zBoard]], [6, [1330, 160, P ? 1.5 : 1.2]], [8, [720, 440, zModal]],
    [9, [720, 330, zModal]], [18, [800, 420, zModal]], [24, [770, 560, zModal]],
    [26, [608, 520, zCol]], [30, [608, 520, zCol]],
    [66.5, [840, 440, zBoard]], [67, [842, 520, zCol]], [72, [374, 700, zCol]], [77, [1076, 520, zCol]], [82.5, [1076, 560, zCol]], [84, [842, 600, zCol]], [92, [842, 620, zCol * 1.1]],
  ], SPRING.gentle);
};

function admin(ctx, u, bw, bh) {
  const [fx, fy, z] = boardFocus(u);
  ctx.save();
  K.cam(ctx, bw, bh, fx, fy, z);
  K.drawClip(ctx, 'pastor-board', u, BOARD, 1440, 900);
  K.cursor(ctx, 'pastor-board', u, BOARD, { size: 24, start: [1100, 620] });
  ctx.restore();
}
// the admin on the right (16:9 laptop) or as a window card (9:16, 1:1)
function drawAdmin(ctx, u, enter, leave) {
  const ke = springU(u, enter, SPRING.gentle), kl = leave != null ? E.inOutCubic(prog(u, leave, leave + 1.2)) : 0;
  if (ke <= 0 || kl >= 1) return;
  if (LS) {
    const w = 1100, x = W - S.x - w + 20 + (1 - ke) * 900 - kl * 1800, y = (H - w * 0.625) / 2 - 16;
    K.laptop(ctx, x, y, w, (c) => admin(c, u, 1440, 900));
  } else {
    const w = S.w + 40, h = P ? 1100 : 700, x = (W - w) / 2 - kl * 1300 + (1 - ke) * 1200, y = P ? S.y + 330 : S.y + 180;
    K.window(ctx, x, y, w, h, (c, bw, bh) => admin(c, u, bw, bh));
  }
}
// the member's phone; screen(ctx) draws inside it
function phoneBox(u, enter, leave, side = 'main') {
  const ke = springU(u, enter, SPRING.gentle), kl = leave != null ? E.inOutCubic(prog(u, leave, leave + 1.2)) : 0;
  let cx, cy, h;
  if (LS) { cx = side === 'split' ? 1500 : 1310; cy = side === 'split' ? H / 2 + 90 : H / 2 + 10; h = 940; }
  else if (P) { cx = W / 2; cy = S.y + 330 + 540; h = 1100; }
  else { cx = W / 2; cy = S.y + 180 + 400; h = 760; }
  return { cx: cx + (1 - ke) * (LS ? 900 : 1100) + kl * 1300, cy, h, on: ke > 0 && kl < 1 };
}

// lock screen with the visit request, then the tap that opens the app
function lockAndPush(c, u) {
  const open = E.inOutCubic(prog(u, 38.1, 39.3));
  K.lock(c, { time: '7:42', date: 'Friday 2 October', dim: 0.1 * open });
  const k = springU(u, 35, SPRING.snappy);
  const b = K.banner(c, { y: 250, title: 'Pastoral visit request', body: 'Rev. Daniel Mweemba would like to visit you on Sat 10 Oct, 10:00 at your home.', k, press: M.bump(u, 38, 0.25) });
  K.ripple(c, 184, b.y + b.h / 2, u, 38);
  if (open > 0) {
    // the notification grows into the app
    const x = lerp(b.x, 0, open), y = lerp(b.y, 0, open), w = lerp(b.w, 368, open), h = lerp(b.h, 822, open);
    c.save(); M.rrect(c, x, y, w, h, lerp(24, 47, open)); c.clip();
    c.translate(x, y); c.scale(w / 368, h / 822); c.globalAlpha = Math.min(1, open * 1.6);
    K.drawClip(c, 'visit-accept', u, ACCEPT, 368, 822); c.restore();
  }
}

// ------------------------------------------------------------ type positions per format
const T = {
  x: LS ? S.x : W / 2, align: LS ? 'left' : 'center',
  y: LS ? 330 : P ? S.y + 110 : S.y + 60,
  size: FORMAT.pick({ '16x9': 84, '9x16': 80, '1x1': 58 }),
  kick: FORMAT.pick({ '16x9': 24, '9x16': 28, '1x1': 22 }),
  body: FORMAT.pick({ '16x9': 30, '9x16': 32, '1x1': 26 }),
  maxW: LS ? 640 : S.w,
};
function caption(ctx, u, a, b, kicker, lines, body) {
  if (u < a - 0.5 || u > b + 0.6) return;
  const lh = T.size * 1.02;
  const yk = LS ? T.y - T.size * 1.05 : T.y - T.size * 1.0;
  if (kicker) K.kicker(ctx, kicker, T.x, yk, T.kick, u, a, { exit: b, align: T.align });
  const y0 = T.y, sz = K.fit(ctx, lines, T.size, T.maxW);
  K.headline(ctx, lines, T.x, y0, sz, u, a + 0.15, { exit: b, align: T.align });
  if (body) K.body(ctx, body, T.x, y0 + (lines.length - 1) * sz * 1.02 + T.body * 1.9, T.body, u, a + 0.6, { exit: b, align: T.align, maxW: T.maxW });
}
// portrait/square push the headline into one line where it fits
const L1 = (a, b) => (LS ? [[a, C.navy], [b, C.blue]] : SQ ? [[`${a} ${b}`, C.navy]] : [[a, C.navy], [b, C.blue]]);

const pills = [[40, 48, '1 · Accept'], [48, 58, '2 · Decline with a reason'], [58, 66, '3 · Suggest another time']];
const outcomes = [[67, 72, 'If she accepts', C.navy], [72, 77, 'If she declines', '#A3241A'], [77, 82.5, 'If she suggests a time', C.blue]];

// ------------------------------------------------------------ draw
function draw(ctx, u) {
  K.bg(ctx, u);
  if (u >= 100) { K.endCard(ctx, u, 100, { line1: 'Pastoral care, kept close.', foot: 'Visits stay private between members and the pastoral team.' }); return; }

  // captions
  caption(ctx, u, -0.6, 7.2, 'Pastor journey', L1('A pastoral visit,', 'start to finish.'));
  caption(ctx, u, 8, 24.5, 'Church admin', L1('Schedule it', 'in one step.'), 'Member, reason, who is going, date and place.');
  caption(ctx, u, 25.2, 31.6, null, L1('Sent straight', 'to her phone.'));
  caption(ctx, u, 33, 39.4, 'Member app', L1('A request', 'she can answer.'));
  caption(ctx, u, 40.2, 65.6, 'She has three choices', L1('Accept, decline,', 'or move it.'));
  caption(ctx, u, 66.2, 82.4, 'Back on the pastor’s board', L1('Every answer', 'lands here.'));
  caption(ctx, u, 82.6, 89.5, null, L1('Accept the', 'new time.'));
  if (LS) { K.headline(ctx, [['She is told right away.', C.navy]], S.x, 190, 76, u, 89.8, { exit: 99.4 }); }
  else caption(ctx, u, 89.6, 99.4, null, L1('She is told', 'right away.'), 'Both sides always see the same visit.');

  // laptop / admin window: shots 1-3, 8-9 (and the split in 10)
  drawAdmin(ctx, u, -1.2, 31.6);
  if (u > 64 && u < 100) {
    if (u < 86 || LS) {
      const split = LS ? E.inOutCubic(prog(u, 86, 87.5)) : 0;
      if (LS && split > 0) {
        // shrink to the left half
        const w = lerp(1100, 900, split), x = lerp(W - S.x - 1100 + 20, S.x + 20, split) + (1 - springU(u, 65.5, SPRING.gentle)) * 900, y = lerp((H - 1100 * 0.625) / 2 - 16, 330, split);
        K.laptop(ctx, x, y, w, (c) => admin(c, u, 1440, 900), { alpha: 1 - prog(u, 99.2, 100) });
      } else drawAdmin(ctx, u, 65.5, P || SQ ? 86 : null);
    }
  }
  // outcome labels over the board
  for (const [a, b, label, col] of outcomes) {
    const k = springU(u, a + 0.1, SPRING.bouncy) * (1 - prog(u, b - 0.3, b));
    const py = LS ? 830 : P ? S.y + 330 + 1060 : S.y + 180 + 730;
    K.pill(ctx, label, LS ? W - S.x - 1100 / 2 + 20 : W / 2, py, FORMAT.pick({ '16x9': 30, '9x16': 36, '1x1': 28 }), k, { bg: col, align: 'center' });
  }

  // phone: shots 4-7
  if (u > 31 && u < 67.5) {
    const pb = phoneBox(u, 31.6, 65.6);
    if (pb.on) K.phone(ctx, pb.cx, pb.cy, pb.h, (c) => {
      if (u < 40) { lockAndPush(c, u); return; }
      if (u < 48) { K.drawClip(c, 'visit-accept', u, ACCEPT, 368, 822); K.taps(c, 'visit-accept', u, ACCEPT); }
      else if (u < 58) { K.drawClip(c, 'visit-decline', u, DECLINE, 368, 822); K.taps(c, 'visit-decline', u, DECLINE); }
      else { K.drawClip(c, 'visit-suggest', u, SUGGEST, 368, 822); K.taps(c, 'visit-suggest', u, SUGGEST); }
      // a quick wipe between the three alternatives
      for (const cut of [48, 58]) { const w = 0.5 * M.bump(u, cut, 0.25); if (w > 0) { c.fillStyle = `rgba(244,246,250,${w})`; c.fillRect(0, 0, 368, 822); } }
    });
    for (const [a, b, label] of pills) {
      const k = springU(u, a, SPRING.bouncy) * (1 - prog(u, b - 0.35, b));
      if (LS) K.pill(ctx, label, pb.cx, pb.cy + pb.h / 2 + 22, 28, k, { align: 'center', bg: C.blue });
      else K.pill(ctx, label, W / 2, P ? pb.cy - pb.h / 2 - 96 : S.y + 92, P ? 34 : 24, k, { align: 'center', bg: C.blue });
    }
  }
  // final phone: split (16:9) / hand-off (9:16, 1:1)
  if (u > 85.5) {
    const pb = phoneBox(u, 86, 99.2, 'split');
    if (pb.on) K.phone(ctx, pb.cx, pb.cy, (LS ? 760 : pb.h) * (1 + 0.04 * E.inOutSine(prog(u, 91, 100))), (c) => {
      K.drawClip(c, 'visit-final', u, FINAL, 368, 822);
      const k = springU(u, 89, SPRING.snappy) * (1 - prog(u, 92.5, 93.2));
      K.banner(c, { title: 'Visit confirmed', body: 'Rev. Daniel Mweemba will visit on Tue 13 Oct, 17:30 at your home.', k });
    });
  }
}

K.start({
  clips: ['pastor-board', 'visit-accept', 'visit-decline', 'visit-suggest', 'visit-final'],
  images: ['../journeys/assets/logo.png', '../journeys/assets/logo-white.png'],
  hits: HITS, draw,
});
