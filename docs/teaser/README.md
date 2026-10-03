# BIC Kafue app — teaser video

A 58-second launch teaser, in 16:9 (1920×1080), 9:16 (1080×1920) and 1:1 (1080×1080), built from the real design prototypes in
`docs/design-handoff/design/`. The soundtrack is synthesized from scratch in
`music.mjs`, so it's royalty-free.

## Storyboard (120 BPM, cuts land on the beat)
| Time | Scene |
|---|---|
| 0–6s | The Sunday-morning group chat: "Who's on the main door?", "What hymn number was that?" Then "Sound familiar?" |
| 6–10s | "What if it was all in one place?" The emblem reveal, with a riser building to the drop |
| 10–14s | **Drop.** "Your church. In your pocket." |
| 14–38s | 8 features, 3s each: Sermons · Bible & hymns · Duties (tap to accept) · Calendar · Cell groups · Pastoral visits (tap) · Giving · Dark mode |
| 38–46s | Church admin web app: duty rotas, cell meetings, pastor overview, pastoral care |
| 46–50s | Wall of phone screens: "Made for our church family." |
| 50–58s | Logo, "Coming soon.", the platforms, and the 2026 theme verse (Deut 7:9) |

## Re-render
Needs Node 22, Playwright (Chromium) and ffmpeg.

```sh
cd docs/teaser
mkdir -p vendor && for u in @babel/standalone@7.29.0/babel.min.js react-dom@18.3.1/umd/react-dom.production.min.js react@18.3.1/umd/react.production.min.js; do curl -sSL "https://unpkg.com/$u" -o "vendor/$(basename $u)"; done
cp ../design-handoff/design/assets/bic-logo.png logo.png
cp ../design-handoff/design/assets/bic-logo-white.png logo-white.png
npx http-server ../design-handoff/design -p 8123 -s &   # prototypes
npx http-server . -p 8124 -s &                          # video page
node capture.mjs        # 3x screenshots of every app/admin screen -> shots/
node music.mjs          # -> music.wav
# master to -14 LUFS / -1 dBTP (run loudnorm once to measure, then plug the numbers in):
ffmpeg -i music.wav -af loudnorm=I=-14:TP=-1:LRA=11:print_format=json -f null -
ffmpeg -i music.wav -af "loudnorm=I=-14:TP=-1:LRA=16:measured_I=..:measured_TP=..:measured_LRA=..:measured_thresh=..:linear=true,aresample=48000" master.wav
node render.mjs 16x9    # also 9x16 and 1x1 -> teaser-<fmt>.mp4 (60 fps capture blended to 30 fps for motion blur)
```
To edit copy or timing, change `video.html`; `./sheet.sh 9x16 6 4 12.5 30 41` renders a contact sheet of frames for review.
Layouts for each format live in `LAYOUTS` at the top of the script in `video.html`.
Scene times are shared with the music (`DROP`, `BREAK`, `WALL`, `END` in `music.mjs`), so change both together.

---

# Journey videos (overview + pastor, cell leader, member)

Four films made with the **Motion Reel** pipeline (beat grid, signed-off shot list, critique loop, -14 LUFS
mix) from **real clicks, typing and scrolls** recorded in the prototypes. Brief: `JOURNEYS-BRIEF.md`.
Screens that had to be designed, the prototype bug fixed for recording, and all staging: `JOURNEYS-NEW-SCREENS.md`.

| Film | Folder | Length | Beat grid |
|---|---|---|---|
| Overview | `overview/` | 60 s | 120 bpm, synth house in D |
| Pastor: a pastoral visit | `pastor-visit/` | 65 s | 96 bpm, synth lo-fi in F |
| Cell leader: plan the next meeting | `cell-meeting/` | 60 s | 112 bpm, synth lo-fi in G |
| Member: a week in the app | `member-week/` | 72 s | 120 bpm, synth house in A |

Each folder has `film.js` (the film, a pure function of time), `docs/shotlist.md` (what was approved, plus
the changes made while building) and `docs/critique.md` (three critique rounds).

```
journeys/patch.mjs     builds journeys/proto/{App,Admin}.html: recording copies with the designed screens
journeys/rec.mjs       the recorder (real input, slowed CSS animation capture, tap/click positions)
journeys/rec-*.mjs     one script per journey -> rec/<clip>/ (frames + clip.json)
journeys/kit.js        shared film parts: streamed clips, phone/laptop, cursor, taps, lock screen, pushes, type
journeys/round.sh      one critique round: contact sheets (all formats), SFX, mix, hits, sync check
journeys/final.sh      final picture (30 fps, motion blur) + mix + posters -> out/delivery/
```

## Re-render
Needs Node 22, Playwright (Chromium), ffmpeg, uv and the Motion Reel plugin
(`claude plugin install motion-reel@anthropic-plugin-directory`).

```sh
cd docs/teaser
# vendor scripts + logos as in the first teaser above, then:
mkdir -p journeys/assets && cp logo.png logo-white.png journeys/assets/
mkdir -p node_modules && ln -sfn /opt/node22/lib/node_modules/playwright node_modules/playwright
node journeys/patch.mjs
npx http-server journeys/proto -p 8125 -s &        # the recorder drives these copies
node journeys/rec-pastor.mjs && node journeys/rec-cell.mjs && node journeys/rec-member.mjs
SK=~/.claude/plugins/cache/anthropic-plugin-directory/motion-reel/*/skills/motion-reel
for f in overview pastor-visit cell-meeting member-week; do uv run $SK/scripts/beats.py $f --synth ...; done   # see beats.json; music.wav is gitignored
for f in overview pastor-visit cell-meeting member-week; do journeys/final.sh $f; done
```
The exact `beats.py` settings are in the table above (`--flavor`, `--bpm`, `--tonic`, `--mode major`, and
`--drop 5 / 2 / 2 / 4`, `--seed 7 / 3 / 5 / 11` for overview / pastor / cell / member).
