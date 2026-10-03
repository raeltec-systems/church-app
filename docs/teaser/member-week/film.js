// Member journey: a week in the app. Pure function of time; 120 bpm (0.5 s/beat), 144 beats.
// Plan: docs/shotlist.md. Footage: rec/<clip> from journeys/rec-member.mjs.
import * as M from './lib/motion.js';
import { makeKit } from '../journeys/kit.js';

const { W, H, FORMAT, E, prog, lerp, springU, SPRING } = M;
const K = makeKit(M);
const { C } = K;
const P = FORMAT.portrait, SQ = FORMAT.square, LS = FORMAT.landscape;
const S = FORMAT.safe;

const SIGNUP = [
  { at: 0, mark: 'start' }, { at: 0.5, mark: 'phone' }, { at: 1, mark: 'phone:type' }, { at: 3.5, mark: 'send' },
  { at: 6, mark: 'code' }, { at: 6.5, mark: 'code:type' }, { at: 8.5, mark: 'verify' },
  { at: 9.5, mark: 'name' }, { at: 10, mark: 'name:type' }, { at: 11.75, mark: 'cell' }, { at: 12.5, mark: 'form-down' },
  { at: 14, mark: 'submit' }, { at: 15.5, mark: 'continue' }, { at: 16.6, mark: 'approved' },
  { at: 18, mark: 'home-down' }, { at: 23.4, mark: 'home-up' },
];
const DUTY = [{ at: 29.5, mark: 'start' }, { at: 32, mark: 'accept' }];
const DUTYNO = [{ at: 36, mark: 'start' }, { at: 37.5, mark: 'cant' }, { at: 39.5, mark: 'note' }, { at: 40, mark: 'typing' }, { at: 44.5, mark: 'send' }];
const COVER = [{ at: 45, mark: 'start' }, { at: 46.5, mark: 'down' }, { at: 49.25, mark: 'reassign' }, { at: 51, mark: 'pick' }];
const HYMN = [{ at: 52, mark: 'start' }, { at: 53, mark: 'tab' }, { at: 54.5, mark: 'hymnbook' }, { at: 56.5, mark: 'hymn' }, { at: 58, mark: 'read' }];
const SERMON = [{ at: 64, mark: 'start' }, { at: 64.5, mark: 'tab' }, { at: 66, mark: 'list' }, { at: 69, mark: 'open' }];
const GIVE = [{ at: 74, mark: 'start' }, { at: 75, mark: 'tab' }, { at: 77, mark: 'airtel' }, { at: 80.5, mark: 'copy' }];
const CAL = [{ at: 84, mark: 'start' }, { at: 85, mark: 'tab' }, { at: 87, mark: 'down' }, { at: 91, mark: 'event' }];
const RECAP = [{ at: 99.5, mark: 'start' }, { at: 101, mark: 'read' }];
const MYCELL = [{ at: 108, mark: 'start' }, { at: 109.5, mark: 'down' }];
const DARK = [{ at: 116, mark: 'start' }, { at: 120, mark: 'dark' }, { at: 123, mark: 'down' }];

const HITS = [
  [0, 'phone lands', 'impact'], [0.5, 'tap', 'tick'], [1, 'type number', 'type', { len: 0.8, n: 10 }], [3.5, 'send code', 'click'],
  [5, 'sms', 'blip', { pitch: 'E6' }], [6, 'tap code', 'tick'], [6.5, 'digits', 'type', { len: 0.7, n: 6 }], [8.5, 'verify', 'click'],
  [10, 'type name', 'type', { len: 0.7, n: 8 }], [11.75, 'cell', 'tick'], [14, 'submit', 'click'], [14.3, 'sent', 'bell', { pitch: 'A5' }],
  [15.5, 'continue', 'tick'], [16, 'approved push', 'blip', { pitch: 'C#6' }], [16.6, 'drop', 'impact'],
  [26, 'MON', 'pop', { pitch: 'A5' }], [27, 'duty push', 'blip', { pitch: 'E6' }], [29.5, 'tap push', 'tick'], [32, 'accept', 'click'], [32.8, 'accepted', 'bell', { pitch: 'A5' }],
  [36, 'or', 'whoosh', { len: 0.3 }], [37.5, 'cant', 'tick'], [40, 'typing', 'type', { len: 1.9, n: 18 }], [44.5, 'send', 'click'],
  [45, 'to leader', 'whoosh', { len: 0.4 }], [49.25, 'reassign', 'tick'], [51, 'assigned', 'bell', { pitch: 'C#6' }],
  [52, 'TUE', 'pop', { pitch: 'B5' }], [53, 'tab', 'tick'], [54.5, 'tab', 'tick'], [56.5, 'hymn', 'tick'],
  [64, 'WED', 'pop', { pitch: 'C#6' }], [64.5, 'tab', 'tick'], [69, 'sermon', 'tick'],
  [74, 'THU', 'pop', { pitch: 'D6' }], [75, 'tab', 'tick'], [77, 'airtel', 'tick'], [80.5, 'copy', 'coins'],
  [84, 'FRI', 'pop', { pitch: 'E6' }], [85, 'tab', 'tick'], [91, 'event', 'tick'],
  [96, 'SAT', 'pop', { pitch: 'F#6' }], [97, 'recap push', 'blip', { pitch: 'E6' }], [99.5, 'tap', 'tick'],
  [108, 'next meeting', 'whoosh', { len: 0.3 }],
  [116, 'SUN', 'pop', { pitch: 'A6' }], [120, 'dark', 'whoosh', { len: 0.5, from: 2400, to: 400 }],
  [132, 'wall', 'impact'], [140, 'end card', 'impact'], [140, 'logo', 'bell', { pitch: 'A5' }],
];

// ------------------------------------------------------------ layout
const PH = LS ? { cx: 1300, cy: H / 2 + 10, h: 940 } : P ? { cx: W / 2, cy: S.y + 330 + 560, h: 1150 } : { cx: W / 2 + 180, cy: H / 2 + 30, h: 860 };
const T = {
  x: LS ? S.x : SQ ? S.x : W / 2, align: LS || SQ ? 'left' : 'center', y: LS ? 470 : P ? S.y + 130 : 400,
  size: FORMAT.pick({ '16x9': 92, '9x16': 84, '1x1': 62 }), body: FORMAT.pick({ '16x9': 30, '9x16': 32, '1x1': 26 }),
  maxW: LS ? 760 : SQ ? 400 : S.w,
};
function caption(ctx, u, a, b, lines, body) {
  if (u < a - 0.5 || u > b + 0.6) return;
  const sz = K.fit(ctx, lines, T.size, T.maxW);
  K.headline(ctx, lines, T.x, T.y, sz, u, a + 0.15, { exit: b, align: T.align });
  if (body) K.body(ctx, body, T.x, T.y + (lines.length - 1) * sz * 1.02 + T.body * 1.9, T.body, u, a + 0.6, { exit: b, align: T.align, maxW: T.maxW });
}
const L2 = (a, b) => [[a, C.navy], [b, C.blue]];
const DAYS = [[26, 52, 'Monday'], [52, 64, 'Tuesday'], [64, 74, 'Wednesday'], [74, 84, 'Thursday'], [84, 96, 'Friday'], [96, 116, 'Saturday'], [116, 132, 'Sunday']];
function dayLabel(ctx, u) {
  for (const [a, b, d] of DAYS) {
    const k = springU(u, a, SPRING.bouncy) * (1 - prog(u, b - 0.3, b));
    const y = LS ? T.y - T.size * 1.45 : P ? T.y - T.size * 1.85 : T.y - T.size * 1.75;
    K.pill(ctx, d.toUpperCase(), T.x, y, FORMAT.pick({ '16x9': 26, '9x16': 30, '1x1': 22 }), k, { align: T.align, bg: C.blue });
  }
}

const screen = (clip, sched) => (c, u) => { K.drawClip(c, clip, u, sched, 368, 822); K.taps(c, clip, u, sched); };
// timeline of what the main phone shows
function mainScreen(c, u) {
  if (u < 26) {
    screen('signup', SIGNUP)(c, u);
    K.banner(c, { app: 'sms', title: 'Messages', body: '482913 is your BIC Kafue code. It expires in 10 minutes.', k: springU(u, 5, SPRING.snappy) * (1 - prog(u, 7.6, 8.2)) });
    K.banner(c, { title: 'Welcome to BIC Kafue', body: 'The church office approved your membership. Welcome to the family!', k: springU(u, 15.9, SPRING.snappy) * (1 - prog(u, 19.5, 20.2)) });
    return;
  }
  if (u < 36) {
    if (u < 29.5) {
      K.lock(c, { time: '7:15', date: 'Monday 28 September' });
      const k = springU(u, 27, SPRING.snappy);
      const b = K.banner(c, { y: 250, title: 'New duty · Main door', body: 'Sunday 4 October, report 08:30. Can you serve?', k, press: M.bump(u, 29.3, 0.25) });
      K.ripple(c, 184, b.y + b.h / 2, u, 29.3);
      const o = E.inOutCubic(prog(u, 29.3, 29.5)); if (o > 0) { c.globalAlpha = o; screen('duty', DUTY)(c, u); c.globalAlpha = 1; }
      return;
    }
    screen('duty', DUTY)(c, u); return;
  }
  if (u < 46) { screen('duty-no', DUTYNO)(c, u); return; }
  if (u < 52) { screen('coverage', COVER)(c, u); return; }
  if (u < 64) { screen('hymn', HYMN)(c, u); return; }
  if (u < 74) { screen('sermon', SERMON)(c, u); return; }
  if (u < 84) { screen('give', GIVE)(c, u); return; }
  if (u < 96) { screen('calendar', CAL)(c, u); return; }
  if (u < 108) {
    if (u < 99.5) {
      K.drawClip(c, 'calendar', u, CAL, 368, 822);
      const k = springU(u, 97, SPRING.snappy);
      const b = K.banner(c, { title: 'Meeting recap posted', body: 'Built on the rock · Mwembeshi Road cell, Thu 1 Oct', k, press: M.bump(u, 99.3, 0.25) });
      K.ripple(c, 184, b.y + b.h / 2, u, 99.3);
      return;
    }
    screen('recap', RECAP)(c, u); return;
  }
  if (u < 116) { screen('mycell', MYCELL)(c, u); return; }
  screen('dark', DARK)(c, u);
}
// shot changes inside the phone get a short soft wipe
const CUTS = [36, 52, 64, 74, 84, 108, 116];

function wall(ctx, u) {
  const shots = [['hymn', 30], ['sermon', 46], ['give', 30], ['calendar', 58], ['recap', 70], ['mycell', 65], ['duty', 27], ['dark', 82]];
  const n = LS ? 6 : P ? 6 : 4;
  const cols = LS ? 6 : P ? 3 : 4, rows = Math.ceil(n / cols);
  const h = LS ? 560 : P ? 600 : 440, gap = LS ? 285 : P ? 320 : 245;
  const drift = (u - 136) * (LS ? 8 : 6);
  shots.slice(0, n).forEach(([clip, idx], i) => {
    const col = i % cols, row = Math.floor(i / cols);
    const cx = W / 2 + (col - (cols - 1) / 2) * gap - drift + (row % 2) * 40;
    const cy = (LS ? H / 2 + 90 : P ? S.y + 520 + row * 640 : H / 2 + 90) + (col % 2 ? 30 : -30);
    const k = springU(u, 132 + i * 0.25, SPRING.gentle);
    if (k <= 0) return;
    K.phone(ctx, cx, cy + (1 - k) * 600, h, (c) => { const im = K.frameAt(clip, idx); if (im) c.drawImage(im, 0, 0, 368, 822); }, { rot: (col - (cols - 1) / 2) * 0.02, shadow: 0.6, alpha: 1 - prog(u, 139.4, 140) });
  });
  const sz = FORMAT.pick({ '16x9': 84, '9x16': 80, '1x1': 58 });
  const ty = LS ? 150 : P ? S.y + 80 : S.y + 70;
  K.headline(ctx, [[LS || SQ ? 'A week with your church family.' : 'A week with your', C.navy], ...(P ? [['church family.', C.blue]] : [])], W / 2, ty, sz, u, 132.5, { align: 'center', exit: 139.4 });
}

function draw(ctx, u) {
  const dark = E.inOutCubic(prog(u, 120, 121.5)) * (1 - prog(u, 131, 132));
  K.bg(ctx, u, { dark });
  if (u >= 140) { K.endCard(ctx, u, 140, { line1: 'Your church. In your pocket.', foot: 'Coming soon · “Know therefore that the LORD thy God, he is God, the faithful God.” Deut 7:9' }); return; }
  if (u >= 132) { wall(ctx, u); return; }

  caption(ctx, u, -0.6, 8.6, L2('Joining takes', 'a minute.'), 'Your phone number and a code. No password.');
  caption(ctx, u, 9, 16.2, L2('Tell the church', 'who you are.'), 'The church office checks and approves.');
  caption(ctx, u, 16.6, 25.6, L2('Your church,', 'all in one place.'));
  caption(ctx, u, 26.5, 35.6, L2('A duty?', 'Accept in a tap.'));
  caption(ctx, u, 36.2, 45, L2('Can’t make it?', 'Just say so.'), 'Your leader is told straight away.');
  caption(ctx, u, 45.2, 51.6, L2('The slot is', 'filled in minutes.'), 'Br. Mwansa Phiri reassigns it from his phone.');
  caption(ctx, u, 52.4, 63.6, L2('Bible and', 'hymn book.'));
  caption(ctx, u, 64.4, 73.6, L2('Catch up on', 'Sunday’s sermon.'));
  caption(ctx, u, 74.4, 83.6, L2('Giving,', 'step by step.'), 'Mobile money or bank. The app shows how; it never takes payment.');
  caption(ctx, u, 84.4, 95.6, L2('Never miss', 'what’s on.'));
  caption(ctx, u, 96.4, 107.6, L2('Missed cell?', 'Read the recap.'));
  caption(ctx, u, 108.2, 115.6, L2('Next Thursday,', 'already planned.'));
  if (u > 116) { const dk = dark; const L = [['Sunday evening,', M.mix(C.navy, '#FFFFFF', dk)], ['easy on the eyes.', M.mix(C.blue, '#8EC1FF', dk)]]; if (u < 132) { const sz = K.fit(ctx, L, T.size, T.maxW); K.headline(ctx, L, T.x, T.y, sz, u, 116.6, { exit: 131.4, align: T.align }); } }
  dayLabel(ctx, u);

  const kin = springU(u, -1.2, SPRING.gentle);
  const leaderSplit = E.inOutCubic(prog(u, 44.6, 45.6)) * (1 - E.inOutCubic(prog(u, 51.6, 52.4)));
  K.phone(ctx, PH.cx + (1 - kin) * 1100, PH.cy, PH.h * (1 - 0.03 * leaderSplit), (c) => {
    mainScreen(c, u);
    for (const cut of CUTS) { const w = 0.5 * M.bump(u, cut, 0.25); if (w > 0) { c.fillStyle = `rgba(244,246,250,${w})`; c.fillRect(0, 0, 368, 822); } }
  });
  // leader-coverage hand-off label
  const lk = springU(u, 45.4, SPRING.bouncy) * (1 - prog(u, 51.4, 51.8));
  K.pill(ctx, 'Br. Mwansa Phiri · ushering leader', PH.cx, PH.cy + PH.h / 2 + 16, FORMAT.pick({ '16x9': 22, '9x16': 28, '1x1': 20 }), lk, { align: 'center', bg: C.navy });
}

K.start({
  clips: ['signup', 'duty', 'duty-no', 'coverage', 'hymn', 'sermon', 'give', 'calendar', 'recap', 'mycell', 'dark'],
  images: ['../journeys/assets/logo.png', '../journeys/assets/logo-white.png'],
  hits: HITS, draw,
});
