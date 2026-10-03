# BIC Kafue app — teaser video

A 58-second, 1920×1080 launch teaser built from the real design prototypes in
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
node render.mjs         # -> teaser.mp4
```
To edit copy or timing, change `video.html`; `node stills.mjs 12.5 30` renders single frames for a quick check.
Scene times are shared with the music (`DROP`, `BREAK`, `WALL`, `END` in `music.mjs`), so change both together.
