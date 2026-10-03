// usage: node render.mjs <16x9|9x16|1x1>  -> teaser-<fmt>.mp4
// Captures at 60 fps and blends frame pairs into 30 fps output for natural motion blur.
import { chromium } from '/opt/node22/lib/node_modules/playwright/index.mjs';
import { spawn } from 'child_process';
const FMT = process.argv[2] || '16x9', CAP = 60, DUR = 58;
const [W, H] = { '16x9': [1920, 1080], '9x16': [1080, 1920], '1x1': [1080, 1080] }[FMT];
const b = await chromium.launch({ args:['--ignore-certificate-errors'] });
const p = await b.newPage({ viewport:{ width:W, height:H } });
await p.goto('http://localhost:8124/video.html?f=' + FMT); await p.evaluate(() => ready());
const ff = spawn('ffmpeg', ['-v','error','-y','-f','image2pipe','-framerate',String(CAP),'-c:v','mjpeg','-i','-','-i','master.wav',
  '-vf','tmix=frames=2:weights=1 1,fps=30','-c:v','libx264','-preset','slow','-crf','17','-profile:v','high','-pix_fmt','yuv420p',
  '-c:a','aac','-b:a','192k','-ar','48000','-shortest','-movflags','+faststart',`teaser-${FMT}.mp4`], { stdio:['pipe','inherit','inherit'] });
for (let f = 0; f < CAP * DUR; f++) {
  await p.evaluate(t => render(t), f / CAP);
  const buf = await p.screenshot({ type:'jpeg', quality: 94 });
  if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
  if (f % 600 === 0) console.log(FMT, 'frame', f);
}
ff.stdin.end(); await new Promise(r => ff.on('close', r)); await b.close(); console.log(FMT, 'done');
