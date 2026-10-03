// Cell leader journey recordings (shot list: cell-meeting/docs/shotlist.md).
//   node journeys/rec-cell.mjs
import { Rec } from './rec.mjs';

// ---------------------------------------------------------------- laptop: Grace Banda plans Thursday
{
  const r = await Rec.open('Admin.html');
  const p = r.page;
  await p.locator('button', { hasText: /^\s*Cell leader\s*$/ }).first().click();
  // Staging: three parts start unassigned (on the leader herself) so the leads are chosen on camera.
  await r.state({ prog: [['18:00', 'Opening prayer', 'Grace Banda'], ['18:10', 'Worship', 'Grace Banda'], ['18:30', 'Bible study', 'Peter Lungu'], ['19:10', 'Prayer for one another', 'Grace Banda'], ['19:25', 'Closing prayer', 'Grace Banda']] });
  await r.start('cell-admin');
  await r.tap('nav', 'Cell meetings', { kind: 'click', anim: 400, exact: false });
  const inputs = p.locator('main input, input');
  const field = async (name, i, text) => {
    const loc = p.locator('input').nth(i); const b = await loc.boundingBox();
    await r.act(name, async () => { await loc.click(); await p.keyboard.press('Control+A'); await p.keyboard.press('Backspace'); }, { kind: 'click', x: b.x + b.width / 2, y: b.y + b.height / 2, anim: 120 });
    await r.type(name + ':type', text, { ms: 60 });
  };
  await field('date', 0, 'Thursday 8 October');
  await field('venue', 2, 'Banda home');
  await field('topic', 4, 'Rooted in love');
  await field('scripture', 5, 'Ephesians 3:14–21');
  const who = p.locator('select');
  await r.pick('p1', who.nth(0), 'Ruth Zulu');
  await r.pick('p2', who.nth(1), 'Abel Sakala');
  await r.pick('p5', who.nth(4), 'Mwila Chanda');
  await r.scroll('down', { x: 650, y: 600, by: 400, ms: 900 });
  await r.tap('publish', 'Publish to members', { kind: 'click', anim: 900 });
  await r.pause(4200); r.vt += 300; await r.shot();
  // Answers arrive from members' phones (staged: the prototypes don't share state).
  const ans = (name, key, val) => r.act(name, () => r.eval(([k, v]) => { const c = window.__dc; c.setState({ partSt: { ...(c.state.partSt || {}), [k]: v } }); }, [key, val]), { kind: 'none', anim: 500 });
  await r.scroll('up', { x: 650, y: 500, by: -260, ms: 700 });
  await ans('a-mwila', 'Closing prayer|Mwila Chanda', 'Confirmed');
  await ans('a-ruth', 'Opening prayer|Ruth Zulu', 'Tentative');
  await ans('a-abel', 'Worship|Abel Sakala', 'Can’t make it');
  await ans('a-peter', 'Bible study|Peter Lungu', 'Confirmed');
  await ans('a-grace', 'Prayer for one another|Grace Banda', 'Confirmed');
  await r.pick('reassign', who.nth(1), 'Lydia Banda');
  await r.scroll('down2', { x: 650, y: 600, by: 400, ms: 700 });
  await r.tap('update', 'Update members', { kind: 'click', anim: 900 });
  r.save();
  await r.close();
}

// ---------------------------------------------------------------- phones: three members answer
const member = async (name, me, steps) => {
  const r = await Rec.open('App.html');
  await r.phoneClip();
  if (me) await r.state({ me });
  await r.page.locator('button', { hasText: /^\s*My cell\s*$/ }).last().click();
  await r.start(name);
  await r.scroll('scroll', { x: r.clip.x + 184, y: r.clip.y + 500, by: 330, ms: 1000 });
  await r.tap('open', 'Confirm', { anim: 700 });
  await steps(r);
  r.save();
  await r.close();
};
await member('cell-mwila', null, async (r) => { await r.tap('yes', 'Yes, I\'ll lead it', { anim: 900 }); });
await member('cell-ruth', 'Ruth Zulu', async (r) => { await r.tap('tent', 'Tentative', { anim: 900 }); });
await member('cell-abel', 'Abel Sakala', async (r) => {
  const ta = r.page.locator('textarea:visible').first(); const b = await ta.boundingBox();
  await r.tapAt('note', b.x + b.width / 2, b.y + b.height / 2, { anim: 150 });
  await r.type('typing', 'At a funeral in Mazabuka, sorry.', { ms: 55 });
  await r.tap('no', 'Can\'t make it', { anim: 900 });
});
