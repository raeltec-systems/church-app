// Member journey + overview recordings (shot lists: member-week/, overview/).
//   node journeys/rec-member.mjs [clip ...]     (no args: all clips)
import { Rec } from './rec.mjs';

const only = process.argv.slice(2);
const btn = (r, t) => r.page.locator('button', { hasText: new RegExp('^\\s*' + t + '\\s*$') });
async function clip(name, setup, steps, file = 'App.html') {
  if (only.length && !only.includes(name)) return;
  const r = await Rec.open(file);
  try {
    if (file === 'App.html') await r.phoneClip();
    await setup(r);
    await r.start(name);
    await steps(r);
    r.save();
  } catch (e) { console.log(`FAILED ${name}: ${e.message}`); r.save({ failed: true }); }
  await r.close();
}
const jump = (r, t) => btn(r, t).last().click();
const field = async (r, name, loc) => { const b = await loc.boundingBox(); await r.tapAt(name, b.x + b.width / 2, b.y + b.height / 2, { anim: 150 }); };
const mid = (r) => ({ x: r.clip.x + 184, y: r.clip.y + 480 });

// sign up -> code -> about you -> request sent -> (approved) member home
await clip('signup', async (r) => { await jump(r, 'Phone sign-up'); }, async (r) => {
  await field(r, 'phone', r.page.locator('input:visible').first());
  await r.type('phone:type', '97 123 4567', { ms: 70 });
  await r.tap('send', 'Send code', { anim: 500 });
  await field(r, 'code', r.page.locator('input:visible').first());
  await r.type('code:type', '482913', { ms: 120 });
  await r.tap('verify', 'Verify', { anim: 500 });
  await field(r, 'name', r.page.locator('input:visible').first());
  await r.type('name:type', 'Mwila Chanda', { ms: 60 });
  await r.tap('cell', 'Mwembeshi Road cell', { exact: false, anim: 300 });
  await r.scroll('form-down', { ...mid(r), by: 500, ms: 900 });
  await r.tap('submit', 'Submit request', { anim: 600 });
  await r.tap('continue', 'Continue to the app', { anim: 500 });
  // the church office approves the membership (staged: done in the admin app)
  await r.act('approved', () => btn(r, 'Member').first().click(), { kind: 'none', anim: 300 });
  await r.scroll('home-down', { ...mid(r), by: 900, ms: 2600 });
  await r.scroll('home-up', { ...mid(r), to: 0, ms: 1400 });
});

await clip('duty', async (r) => { await jump(r, 'Duty detail'); }, async (r) => {
  await r.tap('accept', 'Accept', { anim: 1700 });
});
await clip('duty-no', async (r) => { await jump(r, 'Duty detail'); }, async (r) => {
  await r.tap('cant', 'Can\'t make it', { anim: 700 });
  await field(r, 'note', r.page.locator('textarea:visible').first());
  await r.type('typing', 'Travelling to Lusaka this weekend.', { ms: 55 });
  await r.tap('send', 'Let ', { exact: false, anim: 900 });
});
await clip('coverage', async (r) => {
  await btn(r, 'Leader').first().click(); await jump(r, 'Leader coverage');
  // continuity: the prototype's declined Main door card belongs to a placeholder name; show it as the member from this film
  await r.eval(() => { const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT); let n; while ((n = w.nextNode())) if (n.nodeValue.includes('Joseph Tembo')) n.nodeValue = n.nodeValue.replace('Joseph Tembo', 'Mwila Chanda'); });
}, async (r) => {
  await r.scroll('down', { ...mid(r), by: 520, ms: 1300 });
  await r.tap('reassign', 'Reassign', { idx: -1, anim: 700 });
  const cand = r.page.locator('.jsheet button').first(); const cb = await cand.boundingBox();
  console.log('reassign to', (await cand.innerText()).replace(/\s+/g, ' '));
  const pick = { x: cb.x + cb.width / 2, y: cb.y + cb.height / 2 };
  await r.tapAt('pick', pick.x, pick.y, { anim: 900 });
});
await clip('hymn', async () => {}, async (r) => {
  await r.tap('tab', 'Bible & Hymns', { anim: 300 });
  await r.tap('hymnbook', 'Hymn book', { anim: 300 });
  await r.tap('hymn', 'It Is Well', { exact: false, anim: 400 });
  await r.scroll('read', { ...mid(r), by: 520, ms: 2200 });
});
await clip('sermon', async () => {}, async (r) => {
  await r.tap('tab', 'Sermons', { anim: 300 });
  await r.scroll('list', { ...mid(r), by: 260, ms: 1000 });
  await r.tap('open', 'Built on the Rock', { exact: false, anim: 400 });
  await r.tap('play', 'Play', { exact: false, anim: 400 }).catch((e) => console.log('sermon play:', e.message));
});
await clip('give', async () => {}, async (r) => {
  await r.tap('tab', 'Give', { anim: 300 });
  await r.tap('airtel', 'Airtel Money', { exact: false, anim: 400 });
  await r.tap('copy', 'Copy', { exact: false, anim: 700 }).catch((e) => console.log('give copy:', e.message));
});
await clip('calendar', async () => {}, async (r) => {
  await r.tap('tab', 'Calendar', { anim: 300 });
  await r.scroll('down', { ...mid(r), by: 300, ms: 1100 });
  await r.tap('event', 'Harvest Thanksgiving', { exact: false, anim: 500 });
});
await clip('recap', async (r) => { await jump(r, 'Cell meeting recap'); }, async (r) => {
  await r.scroll('read', { ...mid(r), by: 900, ms: 3200 });
});
await clip('dark', async () => {}, async (r) => {
  await r.act('dark', () => btn(r, 'Dark').first().click(), { kind: 'none', anim: 300 });
  await r.scroll('down', { ...mid(r), by: 500, ms: 1600 });
});
await clip('mycell', async (r) => { await jump(r, 'My cell'); }, async (r) => {
  await r.scroll('down', { ...mid(r), by: 330, ms: 1300 });
});

// overview: a quick tour of the church admin on the web
await clip('admin-tour', async (r) => { await r.state({ prog: [['18:00', 'Opening prayer', 'Ruth Zulu'], ['18:10', 'Worship', 'Abel Sakala'], ['18:30', 'Bible study', 'Peter Lungu'], ['19:10', 'Prayer for one another', 'Grace Banda'], ['19:25', 'Closing prayer', 'Mwila Chanda']] }); }, async (r) => {
  await r.tap('rotas', 'Duty rotas', { kind: 'click', exact: false, anim: 400 });
  await r.tap('meetings', 'Cell meetings', { kind: 'click', exact: false, anim: 400 });
  const topic = r.page.locator('input').nth(4); const b = await topic.boundingBox();
  await r.act('topic', async () => { await topic.click(); await r.page.keyboard.press('Control+A'); await r.page.keyboard.press('Backspace'); }, { kind: 'click', x: b.x + b.width / 2, y: b.y + b.height / 2, anim: 100 });
  await r.type('topic:type', 'Rooted in love', { ms: 55 });
  await r.tap('pastor', 'Pastor', { kind: 'click', anim: 300 });
  await r.tap('care', 'Pastoral care', { kind: 'click', exact: false, anim: 500 });
}, 'Admin.html');
