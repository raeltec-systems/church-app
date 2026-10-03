// Cell leader journey: plan and publish the next meeting. Pure function of time; 112 bpm (0.536 s/beat).
// Plan: docs/shotlist.md. Footage: rec/cell-admin (Grace Banda, admin), rec/cell-{mwila,ruth,abel} (members).
import * as M from './lib/motion.js';
import { makeKit } from '../journeys/kit.js';

const { W, H, FORMAT, E, prog, lerp, springU, springKeys, SPRING } = M;
const K = makeKit(M);
const { C } = K;
const P = FORMAT.portrait, SQ = FORMAT.square, LS = FORMAT.landscape;
const S = FORMAT.safe;

const ADMIN = [
  { at: 0, mark: 'start' }, { at: 6.5, mark: 'nav' },
  { at: 8.5, mark: 'date' }, { at: 9, mark: 'date:type' },
  { at: 12, mark: 'venue' }, { at: 12.5, mark: 'venue:type' },
  { at: 15, mark: 'topic' }, { at: 15.5, mark: 'topic:type' },
  { at: 19, mark: 'scripture' }, { at: 19.5, mark: 'scripture:type' },
  { at: 25, mark: 'p1' }, { at: 26.5, mark: 'p1:choose' },
  { at: 28.5, mark: 'p2' }, { at: 30, mark: 'p2:choose' },
  { at: 32, mark: 'p5' }, { at: 33.5, mark: 'p5:choose' },
  { at: 36, mark: 'down' }, { at: 40, mark: 'publish' },
  { at: 80, mark: 'up' }, { at: 82, mark: 'a-mwila' }, { at: 83, mark: 'a-ruth' }, { at: 84, mark: 'a-abel' },
  { at: 85, mark: 'a-peter' }, { at: 86, mark: 'a-grace' },
  { at: 89, mark: 'reassign' }, { at: 90.5, mark: 'reassign:choose' }, { at: 92, mark: 'down2' }, { at: 95, mark: 'update' },
];
const MWILA = [{ at: 52.5, mark: 'start' }, { at: 55, mark: 'scroll' }, { at: 58.5, mark: 'open' }, { at: 63, mark: 'yes' }];
const RUTH = [{ at: 69, mark: 'start' }, { at: 70, mark: 'scroll' }, { at: 72.5, mark: 'open' }, { at: 75.5, mark: 'tent' }];
const ABEL = [{ at: 69, mark: 'start' }, { at: 70, mark: 'scroll' }, { at: 72.5, mark: 'open' }, { at: 73.75, mark: 'note' }, { at: 74.25, mark: 'typing' }, { at: 78.25, mark: 'no' }];

const HITS = [
  [0, 'laptop lands', 'impact'], [1, 'headline', 'whoosh', { len: 0.4 }],
  [6.5, 'cell meetings', 'click'],
  [8.5, 'date field', 'tick'], [9, 'type date', 'type', { len: 1.1, n: 12 }],
  [12, 'venue', 'tick'], [12.5, 'type venue', 'type', { len: 0.6, n: 7 }],
  [15, 'topic', 'tick'], [15.5, 'type topic', 'type', { len: 0.8, n: 9 }],
  [19, 'scripture', 'tick'], [19.5, 'type scripture', 'type', { len: 1, n: 10 }],
  [25, 'menu', 'tick'], [26.5, 'Ruth', 'pop', { pitch: 'D5' }],
  [28.5, 'menu', 'tick'], [30, 'Abel', 'pop', { pitch: 'F#5' }],
  [32, 'menu', 'tick'], [33.5, 'Mwila', 'pop', { pitch: 'A5' }],
  [40, 'publish', 'click'], [40.4, 'published', 'bell', { pitch: 'G5' }],
  [45, 'to phones', 'whoosh', { len: 0.5, from: 2400, to: 500 }],
  [46, 'push Ruth', 'blip', { pitch: 'D6' }], [47, 'push Abel', 'blip', { pitch: 'F#6' }], [48, 'push Mwila', 'blip', { pitch: 'A6' }],
  [52, 'zoom Mwila', 'whoosh', { len: 0.4 }],
  [58.5, 'tap confirm', 'tick'], [58.8, 'sheet', 'pop', { pitch: 'G5' }], [63, 'yes', 'tick'], [63.3, 'confirmed', 'bell', { pitch: 'B5' }],
  [68.5, 'two phones', 'whoosh', { len: 0.4 }],
  [72.5, 'taps', 'tick'], [74.25, 'typing', 'type', { len: 1.8, n: 16 }], [75.5, 'tentative', 'pop', { pitch: 'E5' }], [78.25, 'cant', 'pop', { pitch: 'C5' }],
  [79.5, 'back to laptop', 'whoosh', { len: 0.5, from: 500, to: 2400 }],
  [82, 'chip', 'blip', { pitch: 'G5' }], [83, 'chip', 'blip', { pitch: 'A5' }], [84, 'chip', 'blip', { pitch: 'B5' }], [85, 'chip', 'blip', { pitch: 'D6' }], [86, 'chip', 'blip', { pitch: 'E6' }],
  [89, 'menu', 'tick'], [90.5, 'Lydia', 'pop', { pitch: 'G5' }], [95, 'update', 'click'], [95.4, 'updated', 'bell', { pitch: 'G5' }],
  [100, 'preview', 'whoosh', { len: 0.4 }],
  [108, 'end card', 'impact'], [108, 'logo', 'bell', { pitch: 'G5' }],
];

// ------------------------------------------------------------ admin camera
const focus = (u) => {
  const z = (a, b, c) => FORMAT.pick({ '16x9': a, '9x16': b, '1x1': c });
  return springKeys(u, [
    [0, [720, 450, z(1, 1.05, 1)]], [5, [300, 420, z(1.15, 1.5, 1.2)]],
    [8, [560, 320, z(1.35, 1.55, 1.4)]], [11.5, [560, 340, z(1.35, 1.55, 1.4)]], [14.5, [700, 400, z(1.35, 1.55, 1.4)]],
    [17.5, [1000, 420, z(1.25, 1.35, 1.3)]], [21, [1150, 420, z(1.25, 1.2, 1.2)]],
    [24, [700, 640, z(1.3, 1.5, 1.35)]], [35.5, [640, 650, z(1.2, 1.4, 1.3)]], [38.5, [500, 780, z(1.3, 1.6, 1.4)]],
    [79.5, [760, 520, z(1.25, 1.45, 1.3)]], [81.5, [850, 560, z(1.3, 1.5, 1.35)]],
    [88.5, [800, 560, z(1.3, 1.5, 1.35)]], [91.5, [500, 760, z(1.3, 1.55, 1.4)]],
    [97, [1238, 470, z(1.15, 1.4, 1.2)]],
  ], SPRING.gentle);
};
function admin(ctx, u, bw, bh) {
  const [fx, fy, z] = focus(u);
  ctx.save(); K.cam(ctx, bw, bh, fx, fy, z);
  K.drawClip(ctx, 'cell-admin', u, ADMIN, 1440, 900);
  K.cursor(ctx, 'cell-admin', u, ADMIN, { size: 24, start: [700, 700] });
  ctx.restore();
}
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

// ------------------------------------------------------------ type
const T = {
  x: LS ? S.x : W / 2, align: LS ? 'left' : 'center', y: LS ? 330 : P ? S.y + 110 : S.y + 60,
  size: FORMAT.pick({ '16x9': 84, '9x16': 80, '1x1': 58 }), kick: FORMAT.pick({ '16x9': 24, '9x16': 28, '1x1': 22 }),
  body: FORMAT.pick({ '16x9': 30, '9x16': 32, '1x1': 26 }), maxW: LS ? 640 : S.w,
};
function caption(ctx, u, a, b, kicker, lines, body) {
  if (u < a - 0.5 || u > b + 0.6) return;
  if (kicker) K.kicker(ctx, kicker, T.x, T.y - T.size * 1.05, T.kick, u, a, { exit: b, align: T.align });
  const sz = K.fit(ctx, lines, T.size, T.maxW);
  K.headline(ctx, lines, T.x, T.y, sz, u, a + 0.15, { exit: b, align: T.align });
  if (body) K.body(ctx, body, T.x, T.y + (lines.length - 1) * sz * 1.02 + T.body * 1.9, T.body, u, a + 0.6, { exit: b, align: T.align, maxW: T.maxW });
}
const L1 = (a, b) => (SQ ? [[`${a} ${b}`, C.navy]] : [[a, C.navy], [b, C.blue]]);

// ------------------------------------------------------------ phones
const PUSH = [
  ['Ruth Zulu', 46, 'You’re on Opening prayer at 18:00. Tap to confirm.'],
  ['Abel Sakala', 47, 'You’re on Worship at 18:10. Tap to confirm.'],
  ['Mwila Chanda', 48, 'You’re on Closing prayer at 19:25. Tap to confirm.'],
];
function lockPush(c, u, at, body, open = null) {
  K.lock(c, { time: '16:05', date: 'Friday 2 October' });
  const k = springU(u, at, SPRING.snappy);
  const b = K.banner(c, { y: 250, title: 'Cell meeting · Thu 8 Oct', body, k, press: open ? M.bump(u, open, 0.25) : 0 });
  if (open) K.ripple(c, 184, b.y + b.h / 2, u, open);
  return b;
}
function threePhones(ctx, u) {
  const k = springU(u, 44.8, SPRING.gentle), out = E.inOutCubic(prog(u, 51.5, 52.6));
  const n = P ? 3 : 3;
  PUSH.forEach(([who, at, body], i) => {
    const off = i - 1;
    let cx, cy, h;
    if (LS) { cx = W / 2 + 360 + off * 330; cy = H / 2 + 40; h = 660; }
    else if (P) { cx = W / 2 + off * 330; cy = S.y + 330 + 520; h = 640; }
    else { cx = W / 2 + off * 320; cy = S.y + 180 + 380; h = 600; }
    // Mwila's phone (right) grows into the next shot; the others leave
    const focus = i === 2;
    const tx = focus ? lerp(cx, LS ? 1310 : W / 2, out) : cx - out * 1600 * (i === 0 ? 1 : 0.6);
    const th = focus ? lerp(h, LS ? 940 : P ? 1100 : 760, out) : h;
    const ty = focus ? lerp(cy, LS ? H / 2 + 10 : P ? S.y + 330 + 540 : S.y + 180 + 400, out) : cy;
    const kk = springU(u, 44.8 + i * 0.25, SPRING.gentle);
    if (kk <= 0) return;
    K.phone(ctx, tx + (1 - kk) * 1200, ty, th, (c) => {
      if (focus && u > 52) { K.drawClip(c, 'cell-mwila', u, MWILA, 368, 822); const f = 1 - prog(u, 52, 52.8); if (f > 0) { c.globalAlpha = f; lockPush(c, u, at, body, 51.6); c.globalAlpha = 1; } return; }
      lockPush(c, u, at, body, focus ? 51.6 : null);
    });
    const nk = springU(u, at + 0.3, SPRING.bouncy) * (1 - prog(u, 51.2, 51.6));
    K.pill(ctx, who, tx, ty + th / 2 + 18, FORMAT.pick({ '16x9': 22, '9x16': 26, '1x1': 20 }), nk, { align: 'center', bg: C.navy });
  });
}
function phoneMain(ctx, u) {
  const kl = E.inOutCubic(prog(u, 68, 69.2));
  let cx, cy, h;
  if (LS) { cx = 1310; cy = H / 2 + 10; h = 940; } else if (P) { cx = W / 2; cy = S.y + 330 + 540; h = 1100; } else { cx = W / 2; cy = S.y + 180 + 400; h = 760; }
  K.phone(ctx, cx - kl * 1500, cy, h, (c) => { K.drawClip(c, 'cell-mwila', u, MWILA, 368, 822); K.taps(c, 'cell-mwila', u, MWILA); });
}
function twoPhones(ctx, u) {
  const kin = springU(u, 68.4, SPRING.gentle), out = E.inOutCubic(prog(u, 79.4, 80.6));
  [['cell-ruth', RUTH, 'Ruth Zulu · Tentative', -1], ['cell-abel', ABEL, 'Abel Sakala · Can’t make it', 1]].forEach(([clip, sched, label, side], i) => {
    let cx, cy, h;
    if (LS) { cx = 1240 + side * 250; cy = H / 2 + 10; h = 860; }
    else if (P) { cx = W / 2 + side * 250; cy = S.y + 330 + 520; h = 1000; }
    else { cx = W / 2 + side * 200; cy = S.y + 180 + 380; h = 700; }
    K.phone(ctx, cx + (1 - kin) * 1400 - out * 1800, cy, h, (c) => { K.drawClip(c, clip, u, sched, 368, 822); K.taps(c, clip, u, sched); });
    const k = springU(u, i === 0 ? 75.8 : 78.6, SPRING.bouncy) * (1 - out);
    K.pill(ctx, label, cx - out * 1800, cy + h / 2 + 16, FORMAT.pick({ '16x9': 22, '9x16': 28, '1x1': 20 }), k, { align: 'center', bg: i === 0 ? '#6E4400' : '#A3241A' });
  });
}

function draw(ctx, u) {
  K.bg(ctx, u);
  if (u >= 108) { K.endCard(ctx, u, 108, { line1: 'Every cell, ready for Thursday.', foot: 'Plan once. Everyone sees their part.' }); return; }
  caption(ctx, u, -0.6, 6.4, 'Cell leader journey', L1('Thursday’s meeting,', 'planned in a minute.'));
  caption(ctx, u, 7.5, 23.5, 'Grace Banda · Mwembeshi Road cell', L1('Fill it in once.', 'Members see it live.'), 'Date, venue, Bible study and scripture.');
  caption(ctx, u, 24, 39.5, null, L1('Give every part', 'a leader.'), 'Each person sees their own part on their phone.');
  caption(ctx, u, 40, 51.3, null, L1('Publish. Everyone', 'gets the plan.'));
  caption(ctx, u, 52.6, 67.6, 'Mwila Chanda · member app', L1('Confirm your', 'part in a tap.'));
  caption(ctx, u, 68.6, 79.2, null, L1('Or say maybe,', 'or can’t make it.'));
  caption(ctx, u, 80, 99.6, 'Back with Grace', L1('See who’s ready.', 'Fill the gaps.'), 'Answers appear on each part as they come in.');
  caption(ctx, u, 100, 107.4, null, L1('One plan.', 'Everyone in step.'));

  drawAdmin(ctx, u, -1.2, 44.6);
  if (u > 78) drawAdmin(ctx, u, 79.4, 107.2);
  if (u > 44 && u < 53.5) threePhones(ctx, u);
  if (u >= 52 && u < 70) phoneMain(ctx, u);
  if (u > 68 && u < 81) twoPhones(ctx, u);
}

K.start({
  clips: ['cell-admin', 'cell-mwila', 'cell-ruth', 'cell-abel'],
  images: ['../journeys/assets/logo.png', '../journeys/assets/logo-white.png'],
  hits: HITS, draw,
});
