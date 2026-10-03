# Brief: BIC Kafue app videos (overview + three user journeys)

The owner wants four polished videos. Use the **Motion Reel** plugin (shot list, beat grid, critique loop,
16:9 / 9:16 / 1:1 delivery at -14 LUFS) and **Remotion** where it helps. The first teaser in this folder
(`video.html`, `music.mjs`, `render.mjs`, `README.md`) shows what already works in this repo: driving the
prototypes headlessly, 3x captures, a synthesized score, 60→30 fps motion blur and per-format layouts.

## Source material
- Interactive prototypes: `docs/design-handoff/design/BIC Kafue App.dc.html` (member app, with role
  switcher Guest / Pending / Member / Leader, Light / Dark and "Jump to" screens) and
  `BIC Kafue Admin.dc.html` (web admin, with role switcher Admin / Cell leader / Pastor).
  Both are React-in-browser. To run them headless: serve the folder over HTTP and route the three
  unpkg.com scripts to local copies (see `lib.mjs` and the README).
- Design tokens, type and component rules: `docs/design-handoff/README.md`. Functional truth:
  `docs/design-handoff/spec/Church App - v1 Spec.md` (notifications §, duties, pastoral care, cell meetings).
- Brand: emblem `design/assets/bic-logo*.png`; navy #14246B, water blue #0A7FE0; Outfit / Figtree / JetBrains Mono.

## Approach
Record **real interactions** in the prototypes (Playwright clicks, typing and scrolls that change the
prototype's state, rather than static screenshots), then composite them into designed scenes:
- a synthetic cursor on desktop and a finger/tap ripple on the phone, with smooth eased scrolls
- push notifications sliding in on the phone's lock screen or home screen, then the tap that opens them
- confirmation toasts, status chips changing colour, a kanban card moving column
- split-screen or device hand-offs (laptop → phone) for the cross-device moments. The two prototypes
  don't share state, so stage the hand-off in the edit.
Where a needed screen doesn't exist, design it in the prototype's own components and tokens and
**list each invented screen in the delivery notes** so the owner can approve it for the real app.

## The four videos (about 45–75 s each, all three aspect ratios)
1. **Overview.** Refresh of the current teaser: key features, upbeat.
2. **Pastor journey: pastoral care visit.** Admin (Pastor role) → Pastoral care kanban → *Schedule a visit*
   modal (member, date/time, reason, who's going) → saved → member's phone gets a push notification →
   opens Pastoral visits → show all three responses: **Accept**; **Suggest another time** (pick a slot);
   **Decline** with a reason. → Back on the pastor side the card moves (Confirmed / New time suggested)
   and *Accept new time* closes the loop. The prototypes have the schedule modal, the member's
   accept / suggest / decline flow with reasons, and toasts.
3. **Cell group leader journey: plan and publish the next meeting.** Admin (Cell leader role) → Cell meetings →
   fill in date, venue, Bible study topic and scripture, programme parts with who leads each (18:00 Opening
   prayer – Ruth Zulu, Worship – Abel Sakala, …) with the "What members see" preview updating live →
   **Publish** → members' phones get the notification → My cell shows the next meeting → the member assigned
   a part opens it and responds **Yes / Tentative / Can't make it** → the leader's view shows the
   confirmations. **Not in the prototype yet:** the per-part confirmation on the member side and its status
   on the leader side. Design both in the existing style and flag them as new.
4. **Member journey: a week in the app.** Phone sign-up with OTP → home → duty assigned notification →
   accept (or *Can't make it* → the leader's coverage queue lights up and the slot is reassigned) → Bible and hymn book,
   sermons, giving instructions, calendar → cell meeting recap. Optionally show the leader-coverage side.

## Content rules
- The audience is a church congregation in Kafue, Zambia: warm, joyful, clear, no hype. Respectful scripture use.
- Names, numbers and amounts in the prototypes are placeholders. Keep them fictional and never use real members' details.
- The music must be royalty-free (synthesized is fine) and the cuts should land on the beat.
- Deliver MP4s for each video in 16:9, 9:16 and 1:1, plus a contact sheet per video. Keep the source in
  `docs/teaser/`, with large binaries gitignored.
