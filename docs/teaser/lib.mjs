import { chromium } from '/opt/node22/lib/node_modules/playwright/index.mjs';
import fs from 'fs';
const V = new URL('./vendor/', import.meta.url).pathname;
export async function open(file, vp, dsf=3) {
  const b = await chromium.launch({ args:['--ignore-certificate-errors'] });
  const p = await b.newPage({ viewport: vp, deviceScaleFactor: dsf });
  p.on('pageerror', e => console.log('E:', e.message));
  await p.route('https://unpkg.com/**', r => r.fulfill({ body: fs.readFileSync(V + r.request().url().split('/').pop()), contentType: 'application/javascript' }));
  await p.goto('http://localhost:8123/' + encodeURIComponent(file));
  await p.waitForTimeout(3500);
  return { b, p };
}
