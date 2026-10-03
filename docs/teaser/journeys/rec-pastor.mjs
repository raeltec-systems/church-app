// Pastor journey recordings (shot list: pastor-visit/docs/shotlist.md).
//   node journeys/rec-pastor.mjs
import { Rec } from './rec.mjs';

// ---------------------------------------------------------------- laptop: pastoral care board
{
  const r = await Rec.open('Admin.html');
  const p = r.page;
  await p.locator('button', { hasText: /^\s*Pastor\s*$/ }).first().click();
  await p.locator('button', { hasText: /^\s*Pastoral care/ }).first().click();
  // Staging: the prototype already has Mwila Chanda's visit; remove it so the pastor creates it on camera.
  await r.eval(() => { const c = window.__dc; c.setState({ visits: c.D().visits.filter((v) => v.id !== 'v1') }); });
  await r.start('pastor-board');
  await r.tap('open', 'Schedule a visit', { kind: 'click', anim: 600 });
  const sel = p.locator('.jmodal select');
  await r.pick('member', sel.nth(0), 'Mwila Chanda');
  await r.pick('reason', sel.nth(1), 'Prayer for family');
  await r.pick('who', sel.nth(2), 'Rev. Daniel Mweemba');
  const time = p.locator('.jmodal input[type=time]');
  const tb = await time.boundingBox();
  await r.act('time', () => time.fill('10:00'), { kind: 'click', x: tb.x + tb.width / 2, y: tb.y + tb.height / 2, anim: 200 });
  await r.pick('where', sel.nth(3), 'Member’s home');
  await r.tap('send', 'Send to member', { kind: 'click', anim: 900 });
  await r.pause(4200);   // let the toast clear before the outcomes
  r.vt += 300; await r.shot();
  const id = await r.eval(() => window.__dc.state.visits.find((v) => v.member === 'Mwila Chanda').id);

  // Outcomes arrive from the member's phone (staged: the two prototypes don't share state).
  const outcome = (name, patch, toast) => r.act(name, () => r.eval(([id, patch, toast]) => { window.__dc.setVisit(id, patch); window.__dc.toast(toast); }, [id, patch, toast]), { kind: 'none', anim: 900 });
  const quiet = (patch) => r.eval(([id, patch]) => { window.__dc.setVisit(id, patch); window.__dc.setState({ toast: '' }); }, [id, patch]);
  await outcome('o-accept', { st: 'confirmed', detail: 'Rev. Daniel Mweemba · Member’s home' }, 'Mwila Chanda accepted the visit');
  await r.pause(4200); r.vt += 300; await r.shot();
  await r.act('reset1', () => quiet({ st: 'awaiting', detail: 'Rev. Daniel Mweemba · Member’s home' }), { kind: 'none', anim: 500 });
  await outcome('o-decline', { st: 'requested', when: 'Was Sat 10 Oct, 10:00', declined: 'We’ll be in Lusaka that weekend. Another Saturday?', detail: 'Rev. Daniel Mweemba · Member’s home' }, 'Mwila Chanda declined the visit');
  await r.pause(4200); r.vt += 300; await r.shot();
  await r.act('reset2', () => quiet({ st: 'awaiting', when: 'Sat 10 Oct, 10:00', declined: '' }), { kind: 'none', anim: 500 });
  await outcome('o-suggest', { st: 'postponed', when: 'Was Sat 10 Oct, 10:00', alt: 'Tue 13 Oct, 17:30', detail: 'Suggested Tue 13 Oct, 17:30 instead' }, 'Mwila Chanda suggested Tue 13 Oct, 17:30');
  await r.pause(4200); r.vt += 300; await r.shot();
  await r.tap('accept-new', 'Accept new time', { kind: 'click', anim: 900, idx: -1 });
  r.save();
  await r.close();
}

// ---------------------------------------------------------------- phone: Mwila's three responses
const phone = async (name, steps) => {
  const r = await Rec.open('App.html');
  await r.phoneClip();
  await r.find('Pastoral visits', { idx: -1, sel: 'button' }).catch(() => {});
  await r.page.locator('button', { hasText: /^\s*Pastoral visits\s*$/ }).last().click();
  await r.start(name);
  await steps(r);
  r.save();
  await r.close();
};
// the clip rect is the phone screen, so "Jump to" buttons (outside it) are never found by r.find
await phone('visit-accept', async (r) => {
  await r.tap('accept', 'Accept visit', { anim: 900 });
});
await phone('visit-decline', async (r) => {
  await r.tap('decline', 'Decline', { anim: 700 });
  const ta = r.page.locator('textarea:visible').first();
  const b = await ta.boundingBox();
  await r.tapAt('note', b.x + b.width / 2, b.y + b.height / 2, { anim: 150 });
  await r.type('typing', 'We’ll be in Lusaka that weekend. Another Saturday?', { ms: 55 });
  await r.tap('send', 'Decline visit', { anim: 900 });
});
await phone('visit-suggest', async (r) => {
  await r.tap('suggest', 'Suggest another time', { anim: 700 });
  await r.tap('slot', 'Tue 13 Oct, 17:30', { anim: 900 });
});
// After the pastor accepts the new time: the member's screen shows it confirmed.
{
  const r = await Rec.open('App.html');
  await r.phoneClip();
  await r.page.locator('button', { hasText: /^\s*Pastoral visits\s*$/ }).last().click();
  await r.state({ visit: 'postponed', visitAlt: 'Tue 13 Oct, 17:30' });
  await r.start('visit-final');
  await r.act('confirmed', () => r.state({ visit: 'accepted', visitWhen: 'Tue 13 Oct, 17:30' }), { kind: 'none', anim: 400 });
  r.save();
  await r.close();
}
