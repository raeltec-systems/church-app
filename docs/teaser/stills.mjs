import { chromium } from '/opt/node22/lib/node_modules/playwright/index.mjs';
const [f, ...ts] = process.argv.slice(2);
const [W, H] = { '16x9': [1920, 1080], '9x16': [1080, 1920], '1x1': [1080, 1080] }[f];
const b = await chromium.launch({ args:['--ignore-certificate-errors'] });
const p = await b.newPage({ viewport:{width:W,height:H} });
p.on('pageerror', e => console.log('E:', e.message));
await p.goto('http://localhost:8124/video.html?f=' + f); await p.evaluate(() => ready());
for (const t of ts) { await p.evaluate(t => render(t), +t); await p.screenshot({ path: `st-${f}-${t}.jpg`, quality: 70, type:'jpeg' }); }
await b.close();
