import { chromium } from '/opt/node22/lib/node_modules/playwright/index.mjs';
const b = await chromium.launch({ args:['--ignore-certificate-errors'] });
const p = await b.newPage({ viewport:{width:1920,height:1080} });
p.on('pageerror', e => console.log('E:', e.message));
await p.goto('http://localhost:8124/video.html'); await p.evaluate(() => ready());
const ts = process.argv.slice(2).map(Number);
for (const t of ts) { await p.evaluate(t => render(t), t); await p.screenshot({ path: `still-${t}.jpg`, quality: 70, type:'jpeg' }); }
await b.close();
