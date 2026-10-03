# Screens designed for the journey videos (not in the prototypes)

Each one is built from the prototypes' own markup and tokens (Outfit / Figtree / JetBrains Mono, navy #14246B,
water blue #0A7FE0, the existing chips, sheets and toasts). They live in the recording copies that
`journeys/patch.mjs` builds in `journeys/proto/`; the originals in `docs/design-handoff/design/` are unchanged.
Please approve (or change) each one before it goes into the real app.

| # | Screen / state | Used in | Why it was needed | Where |
|---|---|---|---|---|
| 1 | **Lock screen and push notifications** (app icon, title, one or two lines, "now") | all four | Neither prototype has OS-level notifications. Copy follows the spec's notifications section. | drawn in `journeys/kit.js` (`K.lock`, `K.banner`) |
| 2 | **SMS code notification** during phone sign-up | Member | The prototype has the code screen but not the incoming SMS. | `K.banner({ app: 'sms' })` |
| 3 | **Member: "Confirm your part" sheet** on My cell (Yes, I'll lead it / Tentative / note / Can't make it), and the part chip changing to Confirmed / Tentative / Can't make it | Cell leader | Flagged in the brief as missing. Built from the duty "Can't make it?" sheet. | patch "part sheet" in `patch.mjs` |
| 4 | **Leader: per-part status on Cell meetings** (Confirmed / Tentative / Can't make it / Waiting chip on every programme row, "x of 5 parts confirmed", and an "Updated · changed parts are sent to their phones" toast when re-publishing) | Cell leader | Flagged in the brief as missing. Uses the chip colours of the pastoral care board. | patches "prog status …" |
| 5 | **Pastor: declined visit card** (the card returns to *Requested* with a red "Declined by member" box quoting the member's note, and *Schedule visit* to try again) | Pastor | The board has no declined state, but the member app already sends a decline note. | patch "declined card" |
| 6 | **New notification types**: "Pastoral visit request", "Visit confirmed", "Cell meeting · Thu 8 Oct" (your part), "New duty", "Welcome to Kafue BICC" (membership approved), "Meeting recap posted" | as listed | Part of #1, listed so each message can be approved. | in each `film.js` |
| 7 | **Entrance motion** for sheets (slide up), modals and cards (rise), toasts (pop) and status chips (pop) | all four | The prototypes switch states instantly. | patch "motion css" |

## Prototype bug found while recording
- **Sign-up step 3 shows no cell groups**, so *Submit request* can never be enabled. `cellOpts` is built in the
  app logic but never passed to the template. The recording copy fixes it with one line (patch "sign-up cells").
  The same fix is needed in `BIC Kafue App.dc.html`.

## Staging (not new screens)
- The two prototypes don't share state, so each cross-device moment is staged in the edit: the member's answer
  arriving on the pastor's board, members' answers arriving on Grace's programme, and the pastor's
  *Accept new time* reaching the member's phone.
- Before recording, the pastor board's existing Mwila Chanda card is removed so the pastor creates it on camera,
  and three programme parts start on the leader so the leads are chosen on camera.
- On the ushering coverage queue, the declined Main door card belongs to a placeholder name in the prototype;
  it is shown as Mwila Chanda so it matches the member who said she can't make it.
- In the cell leader video, the member who confirms is Mwila Chanda (her part is Closing prayer, as in the
  prototype), Ruth Zulu answers Tentative and Abel Sakala can't make it; Grace then gives Worship to Lydia Banda.
- Native `<select>` lists don't appear in headless screenshots, so an option list in the prototype's style is
  drawn over the real control while the real option is selected.

All names, numbers and amounts are the prototypes' placeholders.

## App name in the videos
Our own copy uses the full name **Kafue Brethren in Christ Church App** (end cards, the overview's opening line,
the sign-up SMS). Push titles that must fit on one line use **Kafue BICC** ("Welcome to Kafue BICC").
Text inside the recorded prototype screens is the prototypes' own and is unchanged.
