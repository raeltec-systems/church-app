import { chromium } from '/opt/node22/lib/node_modules/playwright/index.mjs';
import { spawn } from 'child_process';
const FPS = 30, DUR = 58;
const b = await chromium.launch({ args:['--ignore-certificate-errors'] });
const p = await b.newPage({ viewport:{width:1920,height:1080} });
await p.goto('http://localhost:8124/video.html'); await p.evaluate(() => ready());
const ff = spawn('ffmpeg', ['-v','error','-y','-f','image2pipe','-framerate',String(FPS),'-c:v','mjpeg','-i','-','-i','music.wav','-c:v','libx264','-preset','slow','-crf','18','-pix_fmt','yuv420p','-c:a','aac','-b:a','192k','-shortest','-movflags','+faststart','teaser.mp4'], { stdio:['pipe','inherit','inherit'] });
for (let f = 0; f < FPS * DUR; f++) {
  await p.evaluate(t => render(t), f / FPS);
  const buf = await p.screenshot({ type:'jpeg', quality: 95 });
  if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
  if (f % 300 === 0) console.log('frame', f);
}
ff.stdin.end(); await new Promise(r => ff.on('close', r)); await b.close(); console.log('done');
