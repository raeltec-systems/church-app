// Uplifting 120 BPM track, I–V–vi–IV in D. 58s. Synthesized from scratch (royalty-free).
import fs from 'fs';
const SR = 44100, DUR = 58, N = SR * DUR;
const L = new Float32Array(N), R = new Float32Array(N);
const BEAT = 0.5, BAR = 2;
const hz = m => 440 * Math.pow(2, (m - 69) / 12);
let seed = 7; const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647) * 2 - 1;
const add = (i, l, r = l) => { if (i >= 0 && i < N) { L[i] += l; R[i] += r; } };
// chords (midi): D, A, Bm, G
const CH = [[50, 54, 57, 62, 66], [45, 52, 57, 61, 64], [47, 54, 59, 62, 66], [43, 50, 55, 59, 62]];
const ROOT = [38, 33, 35, 31];
const chordAt = t => Math.floor(t / BAR) % 4;
const DROP = 10, BREAK = 38, WALL = 46, END = 50;

// PAD (detuned saws, one-pole lowpass), whole song
function pad(t0, t1, notes, vol, cutoff) {
  const st = [];
  for (const n of notes) for (const d of [-0.12, 0.12]) st.push({ f: hz(n + 12 * 0) * Math.pow(2, d / 12), ph: Math.random(), lp: 0, pan: d < 0 ? 0.7 : 1.3 });
  const a = 0.25, rl = 0.6;
  for (let i = Math.floor(t0 * SR); i < Math.min(N, (t1 + rl) * SR); i++) {
    const t = i / SR, e = Math.min(1, (t - t0) / a) * (t > t1 ? Math.max(0, 1 - (t - t1) / rl) : 1);
    const k = 1 - Math.exp(-2 * Math.PI * cutoff / SR);
    let l = 0, r = 0;
    for (const s of st) { s.ph += s.f / SR; s.ph -= Math.floor(s.ph); const x = 2 * s.ph - 1; s.lp += k * (x - s.lp); l += s.lp * (2 - s.pan); r += s.lp * s.pan; }
    add(i, l * vol * e / st.length, r * vol * e / st.length);
  }
}
for (let b = 0; b < 29; b++) {
  const t0 = b * BAR; if (t0 >= 56) break;
  const last = t0 >= END;
  const notes = last ? CH[0] : CH[b % 4];
  const t1 = last ? 57 : t0 + BAR;
  const cut = t0 < 6 ? 700 : t0 < DROP ? 1200 : 1800;
  pad(t0, t1, notes, t0 < DROP ? 0.22 : 0.18, cut);
  if (last) break;
}
// PLUCK
function pluck(t, m, v, pan = 1) {
  const f = hz(m), i0 = Math.floor(t * SR);
  for (let j = 0; j < SR * 0.6; j++) {
    const tt = j / SR, e = Math.exp(-tt * 9);
    const x = (Math.sin(2 * Math.PI * f * tt) + 0.35 * Math.sin(4 * Math.PI * f * tt) + 0.12 * Math.sin(6 * Math.PI * f * tt)) * e * v;
    add(i0 + j, x * (2 - pan), x * pan);
  }
}
const arpPat = [0, 2, 1, 3, 4, 3, 2, 1];
for (let k = 0; ; k++) {
  const t = 6 + k * 0.25; if (t >= END) break;
  if (t >= BREAK && t < BREAK + 1) continue;
  const c = CH[chordAt(t)], n = c[arpPat[k % 8]] + 12;
  const v = t < DROP ? 0.05 + 0.06 * (t - 6) / 4 : 0.11;
  pluck(t, n, v, k % 2 ? 1.35 : 0.65);
}
// delay on plucks region handled by global echo below
// KICK
function kick(t, v = 1) {
  const i0 = Math.floor(t * SR); let ph = 0;
  for (let j = 0; j < SR * 0.35; j++) {
    const tt = j / SR, f = 45 + 110 * Math.exp(-tt * 30);
    ph += 2 * Math.PI * f / SR;
    const x = Math.sin(ph) * Math.exp(-tt * 9) * 0.9 * v + (j < 80 ? rnd() * 0.2 * v : 0);
    add(i0 + j, x);
  }
}
function noiseHit(t, len, decay, v, hp, pan = 1) {
  const i0 = Math.floor(t * SR); let prev = 0, lp = 0;
  for (let j = 0; j < SR * len; j++) {
    const n = rnd(); const h = n - prev; prev = n; // crude highpass
    const x = (hp ? h : n) * Math.exp(-j / SR * decay) * v;
    add(i0 + j, x * (2 - pan), x * pan);
  }
}
function clap(t) { for (const o of [0, 0.011, 0.022]) noiseHit(t + o, 0.18, 22, 0.14, true); }
function bass(t, m, len, v) {
  const f = hz(m), i0 = Math.floor(t * SR);
  for (let j = 0; j < SR * len; j++) {
    const tt = j / SR, e = Math.min(1, tt / 0.01) * Math.exp(-tt * 3) * Math.min(1, (len - tt) / 0.03);
    add(i0 + j, (Math.sin(2 * Math.PI * f * tt) + 0.25 * Math.sin(4 * Math.PI * f * tt)) * e * v);
  }
}
for (let t = DROP; t < END; t += BEAT) {
  const bi = Math.round(t / BEAT);
  const breakdown = t >= BREAK && t < BREAK + 2;
  if (!breakdown) kick(t, t >= WALL ? 1.05 : 1);
  if (bi % 2 === 1 && !breakdown) clap(t);
  if (!breakdown) noiseHit(t + 0.25, 0.05, 60, 0.07, true, 1.3);
  const r = ROOT[chordAt(t)];
  bass(t + 0.25, r + 12, 0.22, 0.28); // offbeat bounce
  if (bi % 2 === 0) bass(t, r, 0.24, 0.3);
}
// intro ticks (chat pops)
[0.35, 1.15, 1.95, 2.75, 3.55, 4.35, 4.85, 5.25].forEach((t, i) => pluck(t, 81 + (i % 3) * 2, 0.07, 1));
// RISERS
function riser(t0, t1, v) {
  let lp = 0;
  for (let i = Math.floor(t0 * SR); i < t1 * SR; i++) {
    const p = (i / SR - t0) / (t1 - t0), k = 0.01 + 0.4 * p * p;
    lp += k * (rnd() - lp); add(i, lp * v * p * p, lp * v * p * p * 0.9);
  }
}
riser(7, DROP, 0.5); riser(36, BREAK, 0.25); riser(BREAK + 1, BREAK + 2, 0.3); riser(44, WALL, 0.3); riser(48, END, 0.4);
// IMPACTS
function impact(t, v) { kick(t, 1.4 * v); noiseHit(t, 1.6, 2.2, 0.12 * v, false); }
impact(DROP, 1); impact(END, 1.1); impact(WALL, 0.6);
// whooshes on feature cuts
for (let t = 14; t < BREAK; t += 3) { let lp = 0; for (let j = 0; j < SR * 0.35; j++) { const p = j / (SR * 0.35); lp += (0.02 + 0.2 * Math.sin(Math.PI * p)) * (rnd() - lp); add(Math.floor((t - 0.3) * SR) + j, lp * 0.12 * Math.sin(Math.PI * p)); } }
// final bell chord
[62, 66, 69, 74, 78].forEach((m, i) => pluck(END + i * 0.06, m + 12, 0.08, i % 2 ? 1.3 : 0.7));
// stereo echo (dotted 8th) + gentle room
const D = Math.floor(0.375 * SR);
for (let i = D; i < N; i++) { L[i] += R[i - D] * 0.22; R[i] += L[i - D] * 0.22; }
// master: fade in/out, soft clip, normalize
let pk = 0;
for (let i = 0; i < N; i++) { const t = i / SR; const g = Math.min(1, t / 0.3) * Math.min(1, (DUR - t) / 2.5) * (t < 9.9 ? 2.2 : 1); L[i] = Math.tanh(L[i] * 1.3 * g); R[i] = Math.tanh(R[i] * 1.3 * g); pk = Math.max(pk, Math.abs(L[i]), Math.abs(R[i])); }
const buf = Buffer.alloc(44 + N * 4);
buf.write('RIFF', 0); buf.writeUInt32LE(36 + N * 4, 4); buf.write('WAVEfmt ', 8); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(2, 22); buf.writeUInt32LE(SR, 24); buf.writeUInt32LE(SR * 4, 28); buf.writeUInt16LE(4, 32); buf.writeUInt16LE(16, 34); buf.write('data', 36); buf.writeUInt32LE(N * 4, 40);
for (let i = 0; i < N; i++) { buf.writeInt16LE(Math.round(L[i] / pk * 0.89 * 32767), 44 + i * 4); buf.writeInt16LE(Math.round(R[i] / pk * 0.89 * 32767), 46 + i * 4); }
fs.writeFileSync('music.wav', buf); console.log('ok', pk);
