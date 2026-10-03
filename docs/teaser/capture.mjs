import { open } from './lib.mjs';
const btn = (p, t, last) => { const l = p.locator('button').filter({ hasText: new RegExp('^\\s*' + t.replace(/[&]/g,'.') + '\\s*$') }); return last ? l.last() : l.first(); };
// APP
{
  const { b, p } = await open('BIC Kafue App.dc.html', { width: 1100, height: 950 }, 3);
  const phone = p.locator('div').filter({ has: p.locator('button', { hasText: 'Calendar' }) }).locator('xpath=.').and(p.locator('div')).first(); const box = await p.evaluate(()=>{const d=[...document.querySelectorAll('div')].find(d=>{const r=d.getBoundingClientRect();return Math.round(r.width)===390&&Math.round(r.height)===844});const r=d.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}}); console.log(box);
  const snap = async n => { await p.waitForTimeout(700); await p.screenshot({ path: `shots/app-${n}.png`, clip: box, omitBackground: true }); console.log('app', n); };
  const jump = async t => { await btn(p, t, true).click(); };
  await snap('home');
  await btn(p,'Bible & Hymns').click(); await snap('bible');
  await btn(p,'Hymn book',true).click(); await snap('hymns');
  await btn(p,'Sermons').click(); await snap('sermons');
  await btn(p,'Give').click(); await snap('give');
  await btn(p,'Calendar').click(); await snap('calendar');
  for (const t of ['My duties','Duty detail','My cell','Cell meeting recap','Pastoral visits','Give instructions','Phone sign-up','Profile']) { await jump(t); await snap(t.toLowerCase().replace(/ /g,'-')); }
  await btn(p,'Leader').click(); await jump('Home'); await snap('home-leader');
  await jump('Leader coverage'); await snap('leader-coverage');
  await btn(p,'Member').click(); await btn(p,'Dark').click(); await jump('Home'); await snap('home-dark');
  await btn(p,'Bible & Hymns').click(); await snap('bible-dark');
  await btn(p,'Light').click(); await btn(p,'Guest').click(); await jump('Home'); await snap('home-guest');
  await b.close();
}
// ADMIN
{
  const { b, p } = await open('BIC Kafue Admin.dc.html', { width: 1440, height: 900 }, 2);
  const snap = async n => { await p.waitForTimeout(600); await p.screenshot({ path: `shots/admin-${n}.png` }); console.log('admin', n); };
  const nav = async t => { await p.locator('button').filter({ hasText: new RegExp('^\\s*' + t) }).first().click(); };
  await snap('overview');
  for (const t of ['Members','Cell groups','Duty rotas','Cell meetings']) { await nav(t); await snap(t.toLowerCase().replace(/ /g,'-')); }
  await nav('Cell leader'); await snap('leader-home');
  console.log(await p.evaluate(()=>[...document.querySelectorAll('button')].map(b=>b.innerText.trim().replace(/\n/g,' ')).filter(Boolean).join(' | ')));
  await nav('Pastor'); await snap('pastor-home');
  console.log(await p.evaluate(()=>[...document.querySelectorAll('button')].map(b=>b.innerText.trim().replace(/\n/g,' ')).filter(Boolean).join(' | ')));
  for (const t of ['Cell reports','Cell giving','Pastoral care']) { await nav(t); await snap(t.toLowerCase().replace(/ /g,'-')); }
  await b.close();
}
