// Tile the frame at each mark (plus the last frame) of a recorded clip, for checking.
//   node journeys/marksheet.mjs <clip> <out.png> [cols] [thumbW]
import fs from 'node:fs'; import path from 'node:path'; import { spawnSync } from 'node:child_process';
const [clip, out, cols = 4, tw = 480] = process.argv.slice(2);
const dir = path.resolve('rec', clip); const J = JSON.parse(fs.readFileSync(path.join(dir, 'clip.json')));
const idx = [...new Set([...Object.values(J.marks).map(i => i + 1).filter(i => i < J.frames.length), J.frames.length - 1])].sort((a, b) => a - b);
const tmp = fs.mkdtempSync('/tmp/claude-0/ms-'); idx.forEach((i, k) => fs.copyFileSync(path.join(dir, J.frames[i][0]), path.join(tmp, `${String(k).padStart(3, '0')}.jpg`)));
const rows = Math.ceil(idx.length / cols);
spawnSync('ffmpeg', ['-loglevel', 'error', '-y', '-framerate', '1', '-i', path.join(tmp, '%03d.jpg'), '-vf', `scale=${tw}:-2,pad=iw+6:ih+6:3:3:gray,tile=${cols}x${rows}`, '-frames:v', '1', out], { stdio: 'inherit' });
console.log(Object.entries(J.marks).map(([k, v]) => `${k}@${v}`).join(' '));
