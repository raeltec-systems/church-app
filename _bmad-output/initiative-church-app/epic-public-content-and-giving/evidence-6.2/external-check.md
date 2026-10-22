# Story 6.2 external check (independent reviewer), 2026-10-22

The entry's external check: an independent reviewer tries to read draft, uncleared and withdrawn files, and to upload a disallowed type. A context-free reviewer agent ran it against the LOCAL stack at commit `9f8bbc1`. It reset the database, served the `content-assets` function, used fictional phones +44 7700 900505-900509 and SYNTHETIC data, cleaned up and released the shared lock. It also reviewed the change statically against the entry, K2, K3, K6, AD-2, AD-13, AD-19 and the screen rules.

## First verdict: FAIL

The reviewer's probes are in the session scratchpad (`probe-6.2.mjs`, `probe-6.2b.mjs` and their `.jsonl` results). In summary:

- **Refused:**
  - 416 attempts to fetch draft files: anonymous, member, Pending and Media callers; the public, authenticated and info routes; render; path traversal and encoding tricks; signed URLs.
  - Every uncleared or unpublished revision path.
  - A withdrawn banner's and a suspended record's files after the sync.
  - Listing either bucket, including through S3 ListObjectsV2 with a member token.
  - Every direct write, copy, move and delete into either bucket.
  - SVG, HTML, GIF and BMP uploads, a declared-type mismatch, bad ratio, oversize with and without Content-Length, and an empty body.
  - Forged command calls, wrong items and purposes, member, Pending and anonymous tokens, replays after a role was revoked, and every non-editor read.
- **Public read:** identical for anonymous, Pending and member callers, with exactly 11 keys; no draft path, asset id, rights detail or editor identity.
- **Leaked or accepted:**
  1. A campaign's image stayed fetchable at its public path after its linked event was withdrawn or archived. The desired public set ignored the event link. It was even placed when the event was withdrawn before the first sync.
  2. Non-images behind a valid header were accepted and published: a 33-byte PNG header with no pixels, a header-only WebP, and a PNG with an HTML document appended.
  3. A JPEG's Exif (a SYNTHETIC GPS position and camera serial) reached the public bucket unchanged.

## Fixes (all before the staging apply)

1. **Per-kind public conditions** (`app.content_public_conditions`, `app.content_register_public_condition`, `app.content_item_public`). The desired public set and the per-item live file now require the kind's condition. Banners register `app.content_banner_public_condition`: a campaign linked to an event is public only while that event is publicly readable. A file whose event leaves the calendar goes into the sync's removal plan, and is never placed while the event is not public.
   - pgTAP: the condition is registered, a non-boolean handler is refused, and the withdrawn event's campaign file is in the removal plan.
   - E2E C33: the event is withdrawn, the sync removes the campaign file (anonymous GET 400), the event is published again and the file comes back.
2. **Sanitising uploads** (`sanitizeImage` in `content-assets/logic.mjs`). Only a structurally complete image is kept:
   - PNG: chunk checksums, consecutive image data that inflates to exactly the size the header claims, IEND;
   - JPEG: frame before scan, at least one scan, end of image;
   - WebP: exactly one image chunk, no animation, RIFF size rewritten.

   Text, Exif, XMP and comment segments are dropped, and so is anything after the image's end. Pixels are never re-encoded. Size and sha256 are those of the kept bytes. A header alone, a truncated or a corrupted file is `invalid_image`; an area over 6000 x 6000 is `too_large`.
   - Node tests: `sanitize.test.mjs`, 4.
   - E2E C13: a header-only PNG is refused with 415 `invalid_image`.
   - E2E C21: an HTML document appended to the campaign image is dropped. The public file's bytes equal the clean image.
3. **Exif and metadata** are removed by the same sanitiser (finding 3).
4. **Home carousel refresh** (finding 4: it never reloaded). It now asks again on app resume and when Home is shown again, as the Calendar does. Flutter test: a banner withdrawn on the server leaves Home after the app resumes.

## Findings not changed

- **No audit row for uploads** (finding 5). The asset row is itself the attributed record of an upload: uploader member and account, `created_at`, `ready_at` and sha256. Together with the command receipt, it records each upload. Writing `app.content_audit` rows would mean widening 6.1's shared audit vocabulary (`app.content_state_ok`), which the parallel entries must not replace. Sync placements and removals follow audited lifecycle commands mechanically.
- **Draft files are never removed** (finding 6). Deferred. Ordinary commands delete nothing (epic constraint), and retention of uploaded images is a Q4 decision. The files stay private. Recorded in the plan's `deferred` list and in `content.md` and `backup-and-restore.md`.
- **The plan's wire contract does not list `event_not_public`** (finding 7). The plan's Implementation Notes record the addition. The review rules forbid editing the plan's contract to settle a finding.
- **The loading placeholder collapses when there are no banners** (finding 8). Either choice moves the layout once: reserving the slot moves it when no banner exists, and not reserving it moves it when one does. A church normally has a yearly theme banner, so reserving the slot is the smaller shift.

## Re-run after the fixes

- pgTAP `content_banners_test.sql`: 148/148. The full suite on a fresh reset: 59 files, 4638 tests, PASS.
- E2E `content-banners.mjs`: 15/15.
- Node: 17/17 (`logic.test.mjs`, `sanitize.test.mjs`, `content-banners.test.mjs`).
- client_core banner tests: 25/25.

**Verdict after the fixes: PASS.** No draft, uncleared or withdrawn file (including a campaign whose event left the calendar) is fetchable after the sync, and no disallowed or non-image upload is stored.
