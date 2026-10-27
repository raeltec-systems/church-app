---
title: "Play a sermon's Facebook video or livestream inside the app"
type: 'feature'
ticket: '10'
created: '2026-10-27'
status: built
baseline_revision: '554ddd9'
route: 'full'
route_source: 'auto'
review: 'deferred'
review_source: 'owner'
lenses_ran: []
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '_bmad-output/initiative-church-app/epic-public-content-and-giving/codex-handoff-prompt.md'
  - '_bmad-output/initiative-church-app/epic-public-content-and-giving/epic-public-content-and-giving.md'
  - '_bmad-output/initiative-church-app/epic-public-content-and-giving/story-publish-and-browse-sermons-with-the-youtube-player-and-safe-plan.md'
  - 'docs/design-handoff/README.md'
deferred:
  - summary: >-
      Review is deferred to the epic pull request review (owner instruction 2026-10-27: build only, no review passes).
    evidence: |-
      The owner has a separate review agent review the epic PR; no reviewer subagent or review pass ran for this entry.
    location: >-
      whole entry
    severity: n/a
---

<intent-contract>

## Intent

**Problem:** The church streams and records its services on Facebook, but a sermon can carry only a YouTube video (entry 9). Background audio was descoped (owner decision 2026-10-27), so entry 10 lets a sermon's video be a public Facebook video or live broadcast, played inside the app.

**Approach:** Add the Facebook source beside YouTube on the sermon kind of 6.9: one new nullable column stored only in a normal form, an exact-allowlist validator and normaliser on the server, the same display-rights check, the same public projection rule, a staff field, and a mobile player that loads Facebook's embedded video player (`/plugins/video.php`) in a pinned web view.

## Boundaries & Constraints

**Always:** Replace only the sermon kind's own functions (same signatures and privileges). A revision has at most one video source. The server validates and normalises; the client mirrors the rules only to explain a refusal before sending. Publishing a revision with either source needs a verified rights record that clears display; the public projection names the link only while it still clears display. No autoplay, no Facebook sign-in, no Facebook media in the public cache. SYNTHETIC data only; fictional phones +44 7700 900111-900121.

**Never:** Replace YouTube, request Facebook from the server, cache a Facebook link offline, let the web view navigate away from the player page, approve a policy gate, send a notification, touch production.

## I/O & Edge-Case Matrix

| Scenario | Input / state | Expected outcome | Failure handling |
|---|---|---|---|
| Video link | `facebook.com/<page>/videos/<id>` (any of facebook.com, www., m., web.; tracking query or fragment) | Stored as `https://www.facebook.com/<page>/videos/<id>/` | Other forms refused |
| Watch / live link | `facebook.com/watch?v=<id>`, `facebook.com/watch/live/?v=<id>` | Stored as `https://www.facebook.com/watch/?v=<id>` | Repeated or non-numeric `v` refused (`invalid`) |
| Short link | `fb.watch/<code>` | Stored as `https://fb.watch/<code>/` | Extra path refused |
| Page Live address | `facebook.com/<page>/live` or `/live_videos` | Refused `not_embeddable` (the embedded player needs one video; a broadcast's own `/videos/<id>` link plays live and afterwards) | Staff copy says what to paste instead |
| Not Facebook / malformed | Another host, http, userinfo, port, encoded path, share/reel/posts links | Refused `not_facebook` or `invalid` | Typed input kept |
| Two sources | YouTube id and Facebook link together | Refused `one_source`; storage check refuses too | Typed input kept |
| Publish | Facebook link without cleared display rights | `video_rights_id=required` / rights reason | Draft stays private |
| Rights withdrawn | Published Facebook sermon | Link and rights revision omitted; notes readable | Mobile shows "No video is available" |
| Player | Removed, private or sign-in-only video, network error, no web view | "This video is unavailable. You can read the notes below." | Notes and scripture stay readable |
| Offline | Saved catalog | Saved teaching never carries a link; "Video needs a connection" | Player never starts |

</intent-contract>

## Code Map

- `supabase/migrations/20261027183503_content_sermon_facebook_video.sql` (new): `facebook_video_url` column with a normal-form check and the one-source check; `app.content_sermon_facebook_url(jsonb)`; replaced 6.9 sermon functions: revision guard, create, save, publish, public sermon JSON, staff revision JSON. Entries 11 and 8 (already on staging) replace no sermon function, so this builds on 6.9's definitions.
- `supabase/tests/content_sermon_facebook_test.sql` (new); `content_sermons_test.sql`: the public key list gains `facebook_video_url`.
- `tools/identity-e2e/content-sermon-facebook.mjs` and `.test.mjs` (new); `content-sermons.mjs` and its test: the public key list gains `facebook_video_url`.
- `packages/client_core/lib/src/domain/content_sermons.dart`: `normalizeSermonFacebookUrl`, `isNormalFacebookVideoUrl`, `facebookSermonEmbedUri`, `PublicSermon.facebookVideoUrl`/`hasVideo`, `SermonInput.facebookVideoUrl`, staff revision parse; cache JSON drops the link.
- `application/sermon_controllers.dart`: the listing comparison includes the link. `presentation/sermon_screens.dart`: `sermonFacebookPlayerBuilderProvider` seam; list media slot and play mark use `hasVideo`; detail picks the source. `presentation/sermon_staff_screens.dart`: Facebook field, refusal copy, "Published, video hidden" for either source. `lib/testing.dart`: `publicSermonData(facebookUrl:)`.
- `apps/mobile/lib/sermons/facebook_sermon_player.dart` (new), `main.dart`, `offline/public_content_cache_adapter.dart` (refuses a saved link), `pubspec.yaml`/`pubspec.lock` (webview packages pinned at the versions youtube_player_iframe already locked).
- Tests: `packages/client_core/test/content/sermon_facebook_test.dart`, `apps/mobile/test/facebook_sermon_player_test.dart`, `apps/mobile/test/offline/public_content_cache_adapter_test.dart`.
- Runbooks `docs/runbooks/content.md`, `docs/runbooks/production-promotion-content.md`; epic Notes.

## Tasks & Acceptance

- [x] Migration, validator, rights and projection rules; pgTAP.
- [x] Local HTTP runner and helper tests.
- [x] Client domain, staff field, mobile seam and list/detail; Flutter tests.
- [x] Mobile Facebook player in a pinned web view.
- [x] Staging apply and verification; runbooks; epic Notes.

**Acceptance Criteria:**
- Given each accepted Facebook form, when an editor saves it, then the server stores the one normal form and the public projection shows it once published with cleared display rights.
- Given a non-Facebook, malformed or page-Live link, or two video sources, when saved, then the server refuses it with a field reason and the staff field explains it.
- Given a published Facebook sermon, when a signed-out phone opens it, then Facebook's embedded player loads without autoplay or sign-in; a removed or private video shows the unavailable message and the notes stay readable.
- Given withdrawn video clearance or no connection, then no player starts and the notes stay readable; the saved catalog never holds a Facebook link.
- Given the Sermons list, then a row with a playable Facebook video carries the same play mark as a YouTube one.

## Design Notes

- **Staff web:** the editor keeps the YouTube field (its key and behaviour unchanged) and adds "Facebook video or live link (optional)" below it, in the same form, with plain refusal copy per reason. The form intro says a sermon has one video, from YouTube or Facebook, needing verified display rights. Two filled fields are refused on the Facebook field.
- **Mobile:** the detail's player slot is the same 16:9 rounded slot as YouTube; the same three honest states (unavailable, no video, needs a connection). The list's play mark and media column follow `hasVideo`, so both sources read the same. No new chrome.
- **Player:** `webview_flutter` 4.14.1 (Android 4.14.1, WebKit 3.27.2), the versions `youtube_player_iframe` 6.0.2 already locked, now direct and pinned. The web view loads `https://www.facebook.com/plugins/video.php?href=<stored link>&autoplay=false&show_text=false&width=<slot width>&height=<16:9>`; Android requires a user gesture for media and iOS requires user action for audio and video, with inline playback. The top-level page may only be the player page: any other main-frame navigation is prevented, and one to Facebook's login or checkpoint page marks the video unavailable (a private video asks for sign-in; the app never shows it). A read-only page probe confirms a video element or play control, or detects Facebook's own unavailable/sign-in text; a main-frame load error, an HTTP error on the player page, or no confirmation within 25 seconds also shows the unavailable state. Android full screen uses the web view's custom-view callbacks on a black full-screen route.

## Decisions

- **Page Live address refused.** `facebook.com/<page>/live` names a page's broadcasts, not one video; Facebook's embedded player plays only a specific video URL. During a broadcast its own link (`/<page>/videos/<id>` or `watch/live/?v=<id>`) plays live, and the same link plays the recording afterwards, so the editor pastes that. Refused as `not_embeddable` with copy that says so.
- **Normal forms.** Numeric-id links keep the page name (`/<page>/videos/<id>/`); watch and watch/live links become `watch/?v=<id>`; `fb.watch` short links are stored as they are, because resolving them needs a request to Facebook, which the server never makes. Share (`/share/v/...`), reel and post links are refused, not guessed.
- **Same rights column.** The Facebook link uses the sermon's existing `video_rights_id` and the same display clearance; no new rights field.
- **Strict client model.** The public sermon gains a required `facebook_video_url` key, as every public field is exact. A 6.9 build reading the new projection refuses it; the epic ships to production as one release, and staging test phones need the new build (no published sermon exists on staging). Saved 6.9 catalogs no longer parse and are treated as no saved copy.
- **Fictional phones:** pgTAP 900111-900114 (rolled back); HTTP runner 900115-900118.

## Verification

- Migration `supabase/migrations/20261027191003_content_sermon_facebook_video.sql` (created as `20261027183503`, renamed to the version staging recorded): ASCII only, no backslash, no CR; `node tools/ci/check-migrations.mjs --base origin/main`: 87 migrations ordered, unique and non-destructive.
- Fresh local reset under the shared-database lock, then the full pgTAP suite: 66 files, 5,325 tests, all pass (new `content_sermon_facebook_test.sql`: 82 tests).
- Local HTTP runner `tools/identity-e2e/content-sermon-facebook.mjs`: 9/9 (evidence `evidence-6.10/content-sermon-facebook-e2e.jsonl`); synthetic accounts removed and local phone auth restored to off. Helper tests: `content-sermon-facebook.test.mjs` 5/5, `content-sermons.test.mjs` 8/8.
- Flutter on the branch before the story-branch merge: `flutter analyze` clean in all four packages; tests pass: design_system 19, client_core 1,033, mobile 94, staff 60.
- After merging `story/5.8-meetings-held` (`b4de38d`, which brings in 6.11 and 6.8; merge `46b0e12`; runbook conflicts resolved keeping both sides): migration checker 91 migrations ordered and non-destructive; locked `flutter pub get`, `flutter analyze` clean in all four packages; tests pass: design_system 19, client_core 1,086, mobile 95, staff 61. The SQL and HTTP checks above ran before the merge; 6.11 and 6.8 change no sermon function.
- Staging `tmurpotfluignacfueki`: applied verbatim as `20261027191003`; all 7 added/replaced function hashes match the fresh local replay; boundary/unowned 0; validator closed to client roles; signed-out catalog `{"series":[],"sermons":[],"truncated":false}` and unknown detail `{"sermon":null}`; app tables unreachable (406). Evidence `evidence-6.10/staging-verify.md`. No content was published, no gate or rights record changed, no notification sent, production untouched.
- Not verified here: playback on an Android emulator or a device (no APK built, by instruction, to save disk), a removed or private video on a device, and iOS. These are the owner's staging check and the entry 15 pilot. The web-view probe for Facebook's unavailable/sign-in text is a heuristic against Facebook's current player page.

## Review

Deferred to the epic pull request review (owner instruction 2026-10-27). No review pass ran.
