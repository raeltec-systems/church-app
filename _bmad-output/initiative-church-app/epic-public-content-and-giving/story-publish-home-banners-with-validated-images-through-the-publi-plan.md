---
title: 'Publish Home banners with validated images through the public asset path'
type: 'feature'
ticket: '2'
created: '2026-10-21'
status: 'built'
baseline_revision: 'd2ed1540051bda211b0eab50f53acb6e0aca8f1f'
route: 'full'
route_source: 'auto'
review: 'quick'
review_source: 'pinned'
lenses_ran: ['quick']
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/docs/runbooks/content.md'
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/runbooks/backup-and-restore.md'
  - '{project-root}/.agents/skills/design-taste-frontend/references/app-screens.md'
warnings: ['oversized', 'multiple-goals']
deferred:
  - summary: >-
      Nothing ever removes an object from the private content-drafts bucket (replaced, abandoned
      or archived banners' uploads stay there).
    evidence: |-
      Reviewer finding 6. Ordinary commands delete no rows (epic constraint), and how long uploaded
      images (which may show people) are kept is a Q4 retention decision. The files stay private
      (no policy, preview only to editors of the item's kind). A retention sweep needs Israel's Q4
      answer first; content.md and backup-and-restore.md say so.
    location: >-
      supabase/functions/content-assets/index.ts (upload), app.content_assets
    severity: medium
  - summary: >-
      Upload commands write no app.content_audit row; sync placements and removals are not
      recorded.
    evidence: |-
      Reviewer finding 5. The asset row is the attributed record of an upload (uploader member and
      account, created_at, ready_at, sha256), with the command receipt. Writing content_audit rows
      needs the 6.1 audit vocabulary (app.content_state_ok) widened, a shared function the parallel
      entries must not replace; a later sequential entry can widen it once for all kinds.
    location: >-
      supabase/migrations/20261022012809_content_rights_banners.sql (app.content_asset_begin, app.content_asset_complete)
    severity: low
---

<intent-contract>

## Intent

**Problem:** Content has no rights records, no Storage bucket and no way to put an image in front of a guest. Home has no carousel, and nothing stops third-party material from being published in production before Israel clears it (Q5).

**Approach:** Add a rights registry as a Content kind (`rights`: a revision is drafted, then *verified*, which is entry 1's publish), a kind-agnostic rights check, the `q5_content_rights` gate, two Storage buckets (private `content-drafts`, public `content-public`), an Edge function `content-assets` that measures and stores uploads under the editor's live session and reconciles the public bucket from the database's published set, generic file attachments on content revisions, and Home banners (`banner` kind: the yearly theme first, then campaigns, optionally linked to an event) with a staff web editor and a mobile 16:9 snap carousel.

**Decisions:**
- Decision (agent, under owner pre-approval): rights records reuse entry 1's lifecycle unchanged: kind `rights` (Admin, Pastor, Media); `content.verify_rights_record` is the publish step, so the verifier and date are the revision's publish attribution and a re-verified revision replaces the one in force. Withdraw suspends, archive retires.
- Decision (agent, under owner pre-approval): `q5_content_rights` holds `{"sources": {"<source_key>": ["display"|"offline"|"audio", ...]}}`. The rights check needs the record in force, the use cleared on its live revision AND the record's `source_key` listed with that use in the effective Q5 value; production with Q5 unapproved refuses every file. Following the epic's assumption on the open Q4/Q5 consent question (posters or banners showing people), this applies to every file whatever its basis (church-owned images included) until Israel approves Q5; church-authored text (events) needs no rights record. A malformed Q5 value clears nothing (fail closed). `app.policy_approve` is not changed.
- Decision (agent, under owner pre-approval): no object is added to the `storage` schema (AD-2): the two buckets are rows in `storage.buckets` inserted by the migration, with no policy, so no client role can read, list or write either bucket through Storage, and the public bucket serves only `/object/public/content-public/<path>`. Bytes are written only by the Edge function with the platform's service key, after the database has authorised the editor's live session through `api.content_command`; no new system credential is minted (no hitl step).
- Decision (agent, under owner pre-approval): the database decides what is public and verifies Storage by reading `storage.objects`: the desired public set is every file of a published item's live revision whose asset is ready and whose rights clear the purpose's use; a public projection names a file only when that object is present in `content-public`. The Edge function's `sync` places missing files (copy from drafts) and removes every public object outside the set. Staff web calls `sync` after each banner or rights lifecycle command and on opening Banners; the staff read shows files still waiting or still to remove. There is no scheduler (residual risk, runbook).
- Decision (agent, under owner pre-approval): uploads are attached to an existing item (`item_id`), so a command's receipt aggregate is that content item and entry 1's replay recheck works unchanged; commands are registered under a pseudo-kind `asset` (Admin, Pastor, Media) and each handler then requires the item's own kind's editor roles.
- Decision (agent, under owner pre-approval): the theme card keeps the handoff's navy card (eyebrow, title, reference, rings and white emblem) and its image is the original opened on tap; campaign cards show the image (cover) with a flat dark caption band. A campaign linked to an event is public only while that event is publicly readable.

## Boundaries & Constraints

**Always:** every write through `api.content_command` (registered commands, the `content` authorizer, receipts); entry 1's lifecycle helper, dispatch, authorizer, `content_in_scope` and deletion hook unchanged (extend through `app.content_kinds`, `app.content_register_command`, `app.content_register_erase_part`); handlers `set search_path = ''`; outcomes carry ids, states, revisions and paths only; ASCII migration with no backslashes; privilege ledgers updated; the server ignores the declared type and measures the bytes; private responses `cache-control: no-store`; SYNTHETIC and public-domain content only.

**Never:** a policy, function, trigger or table in `storage`; a signed or reusable URL to a private object; an anon grant other than the public reads; a row deletion in an ordinary command (a cleared image slot is a null, not a delete); offline caching or new persistence (entry 4); posters, logos or audio (5, 9, 10, 11); a change to shared staff frames beyond adding the Content destinations; edits to the screens another agent is redesigning (Coverage, Outcomes, Special assignments, Cell meetings, Plan meeting, My cell group, member panel).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Rights draft and verify | editor; label, source_key, holder, basis, three clears flags, evidence | draft revision 1; verify makes it in force with verifier and date | field codes; all three clears false: `clears_display: none_cleared` |
| Upload | editor of the item's kind; PNG/JPEG/WebP within the purpose's limits | asset `ready` in `content-drafts`, `{asset_id, media_type, byte_size, width, height}` | not an editor 403; archived item `item_id: archived` |
| Oversized | > purpose max (banner 5 MiB) or > 10 MiB body | refused, nothing stored | `file: too_large` / `byte_size: too_large` |
| Disguised | bytes not PNG/JPEG/WebP (e.g. text named .png), or declared type differs from the bytes | refused, nothing stored | `file: unsupported_type` / `file: type_mismatch` |
| Dimensions | below 960x540, above 6000, ratio outside 1.30-2.40 | refused | `width`/`height: too_small|too_large`, `width: bad_ratio` |
| Publish banner | image ready, rights in force clearing display, source in Q5, linked event published | live; public read lists it once its file is placed | `image_asset_id: required`, `image_rights_id: required|unknown|not_in_force|use_not_cleared|source_not_cleared`, `event_id: not_published` |
| Q5 closed (production, unapproved) | any banner | publish refused | `image_rights_id: source_not_cleared` |
| Sync | editor session | missing desired files copied to `content-public`, undesired removed | non-editor 403 |
| Public read | anon, Pending, member | theme(s) first, then campaigns; only banners whose file is present; `image.path` relative to `content-public` | none |
| Withdraw / archive / rights withdrawn | live banner | gone from the public read at once; its public object removed by the next sync | |
| Storage | anon or member token | cannot fetch any `content-drafts` object, list either bucket or fetch a withdrawn public path | 400/404 |
| Deletion | editor erased | rights, banner and asset attribution read `Former member`; check answers 0 | |

</intent-contract>

## Code Map

- `supabase/migrations/20261021233523_content_events_tracer.sql` -- the lifecycle helper (`content_item_open|lock|saved|publish|withdraw|archive|outcome|draft_no`), `content_command_actor`, `content_free_text`, the registries, the event commands and reads (templates for banner and rights), `content_erase_member` and the events erase part. Read only: never replace these functions.
- `supabase/migrations/20261003134340_cross_epic_contracts.sql` -- `app.policy_gates` (insert the new gate row), `app.policy_effective` / `policy_is_open`, `contract_unknown_keys`, `contract_uuid_error`, `cmd_utc`, `cmd_fail`.
- `supabase/tests/content_events_test.sql` -- pgTAP style; `command_foundation_test.sql` -- anon and authenticated EXECUTE ledgers; `cross_epic_contracts_test.sql:322` -- the gates-with-fixtures list (add `q5_content_rights`).
- `supabase/functions/identity-deletion/{index.ts,logic.mjs,logic.test.mjs}`, `_shared/system_access.mjs` (`keyHeaders`, `declaredTooLarge`) -- Edge function layout and helpers; `supabase/config.toml` `[functions.*]`.
- `tools/identity-e2e/content-events.mjs`, `deletion.mjs` (starting and stopping `supabase functions serve`), `harness.mjs` -- E2E pattern.
- client_core: `domain/content_events.dart`, `adapters/supabase_content_repository.dart`, `adapters/supabase_api_reader.dart`, `adapters/supabase_assisted_recovery.dart` (Edge function call over `http`), `adapters/page_address_{stub,web}.dart` (conditional import pattern; `package:web` is already a dependency), `application/content_controllers.dart`, `presentation/{home_screen,content_screens,calendar_screens,shell_routing}.dart`, `application/providers.dart`, `composition.dart`, `testing.dart` (`FakeContent`, harness), `test/boundaries_test.dart` (no persistence; only adapters reach SDKs and `http`).
- `apps/staff/lib/app.dart` -- the Content sidebar group (`editsContent`, `staffEventsDestination`); `apps/mobile/lib/app.dart` -- tabs (no change expected).
- design: `packages/design_system` (`HeroCard`, `HeroWatermark`, `assets/bic-logo-white.png`, `ChurchColors`, `ChurchType`, staff `ChurchPageScaffold`); handoff `docs/design-handoff/README.md` Home item 1, `screenshots/app-01-home-member.png`, `app-18-home-guest.png`.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261022012809_content_rights_banners.sql` -- kinds `rights`, `banner`, `asset`; `q5_content_rights` gate; buckets; rights, banner, asset-purpose, asset and revision-file tables with guards; the rights check and file helpers; the commands; public and staff reads; the Edge function's plan and preview reads; erase parts; privileges.
- [x] `supabase/tests/content_banners_test.sql` + ledger and gate-list updates -- the matrix (Storage presence simulated by rows in `storage.objects`).
- [x] `supabase/functions/content-assets/{index.ts,logic.mjs,logic.test.mjs}` + `supabase/config.toml` -- upload, sync, preview; sniffing and dimension parsing tested with node.
- [x] `tools/identity-e2e/content-banners.mjs` + `.test.mjs` -- the verify at the API and Storage (block +44 7700 900501-900509).
- [x] client_core: `domain/content_banners.dart`, `adapters/supabase_banner_repository.dart`, `adapters/content_file_picker{,_stub,_web}.dart`, `application/banner_controllers.dart`, `presentation/{home_banners,banner_screens}.dart`, routes, providers, composition, fakes, exports; tests under `test/content/`.
- [x] `apps/staff/lib/app.dart` (Banners and Rights in Content), mobile Home carousel; app tests.
- [x] Runbooks: `content.md` (banners, rights, Q5, sync, owner check), `backup-and-restore.md` (both buckets), `contracts-and-owner-seams.md` (gate list, registries), `production-promotion-content.md`.

**Acceptance Criteria:**
- Given the local stack with functions served, when the E2E runs, then a Media member uploads a `SYNTHETIC Theme 2026` image and a campaign image, an oversized file and a disguised file are refused with nothing stored, both banners publish and a signed-out caller reads them with fetchable images, and anonymous and member callers cannot fetch a draft, an uncleared or a withdrawn file, cannot list either bucket, and cannot publish with a rights record whose source is missing from the Q5 fixture.
- Given `flutter test`, when run, then a signed-out phone's Home shows the theme card first and the campaign card with text alternatives and opens the original on tap, and staff web shows Banners and Rights only to Media, Pastor and Admin.

## Implementation Notes

- Server in this session; the Dart side (client_core, mobile, staff) by a forked implementation
  agent working from this plan's wire contract, reviewed here. Plan to code: as designed, plus the
  review fixes below.
- Migration `supabase/migrations/20261022012809_content_rights_banners.sql` (staging's version; the
  local file was `20261022010000` until applied, after entries 3 and 13). pgTAP
  `supabase/tests/content_banners_test.sql` (148). Ledgers: `command_foundation_test.sql` (anon and
  authenticated EXECUTE), `cross_epic_contracts_test.sql` (gates with fixtures),
  `content_events_test.sql` (its registry and privilege assertions scoped to events, so each
  content entry asserts its own).
- The staff read's `public_image` gained `event_not_public` (a campaign whose linked event is not
  public now) beside `shown`, `waiting` and `blocked`; the Dart parser and the Banners row note
  handle it.
- Edge Function `supabase/functions/content-assets/` (`index.ts`, `logic.mjs`, `test-fixtures.mjs`,
  Node tests `logic.test.mjs` 10 and `sanitize.test.mjs` 4); `supabase/config.toml`
  `[functions.content-assets]` with `verify_jwt = false` (the database checks the session).
- E2E `tools/identity-e2e/content-banners.mjs` (15/15, `evidence-6.2/content-banners-e2e.jsonl`) and
  `content-banners.test.mjs` (3); block +44 7700 900501-900509. It starts `supabase functions
  serve` when it is not running (one command string through the shell on Windows).
- Clients: `domain/content_banners.dart` (a new `BannerRepository` and `ContentFilePicker` port; the
  6.1 `ContentRepository` is unchanged), `adapters/supabase_banner_repository.dart`,
  `adapters/content_file_picker{,_stub,_web}.dart` (`package:web`, no pubspec change),
  `application/banner_controllers.dart`, `presentation/home_banners.dart` (carousel and
  `BannerScreen`, route `/home/banners/:bannerId`), `presentation/banner_screens.dart` (staff
  Banners `/content/banners` and Rights `/content/rights`); Banners and Rights sit after Events in
  the staff Content group.
- Runbooks: `content.md` (story 6.2 section and owner check), `backup-and-restore.md` (both
  buckets), `contracts-and-owner-seams.md` (gate list, registries), `production-promotion-content.md`
  (migration, function, checks, Q5 step).
- Staging: migration `20261022012809`; its 56 function hashes are identical to the fresh local
  reset; guards 0; buckets and no storage policy; `content-assets` deployed (version 1) and probed
  signed out (`evidence-6.2/staging-verify.md`). The signed-in walkthrough is the owner's (no
  staging Media password is held here).

## Plan Change Log

## Review Triage Log

### 2026-10-22 — Review pass (independent reviewer: the entry's external check plus the quick lens)
- verdicts: 8 findings — high 2, medium 3, low 3, false 0, maybe-false 0
- findings:
  - `[high]` `[patch]` A campaign's image stayed public after its linked event was withdrawn,
    archived or over (the desired set ignored the event link) — per-kind public conditions
    (`app.content_public_conditions`) now gate the desired set and the live file; banners register
    theirs; pgTAP and E2E C33 added. Fixed before staging.
  - `[high]` `[patch]` Non-images behind a valid header (header-only PNG/WebP, a PNG with HTML
    appended) were accepted and published — `sanitizeImage` keeps only a structurally complete
    image (checksums, exact pixel-data size, frame and scan, one image chunk) and drops anything
    after its end; Node tests and E2E C13/C21 added.
  - `[medium]` `[patch]` Exif (GPS position, camera serial) reached the public bucket — the same
    sanitiser drops Exif, XMP, text chunks and comments; tested for PNG, JPEG and WebP.
  - `[medium]` `[patch]` The Home carousel never refreshed, so a withdrawn banner stayed on a phone
    until restart — it now reloads on resume and when Home is shown again, as the Calendar does;
    Flutter test added.
  - `[medium]` `[defer]` No path removes `content-drafts` objects (orphans, replaced images) — Q4
    retention decision; files stay private; recorded in `deferred` and the runbooks.
  - `[low]` `[defer]` Upload commands write no `app.content_audit` row — the asset row and receipt
    are the attributed record; widening the shared 6.1 vocabulary is not this parallel entry's to
    do; recorded in `deferred`.
  - `[low]` `[reject]` The plan's wire contract omits `event_not_public` — fixing it means editing
    this build's plan contract; the addition is recorded in Implementation Notes instead.
  - `[low]` `[reject]` The loading placeholder collapses when there are no banners — either choice
    shifts the layout once; a church normally has a theme banner, so reserving the slot is the
    smaller shift.
- External check verdict: FAIL on the first pass, PASS after the fixes
  (`evidence-6.2/external-check.md`).

## Design Notes

Wire contract (SQL, Edge function, Dart and the E2E share it):
- Rights: `content.create_rights_record` {label (120), source_key (`^[a-z0-9][a-z0-9-]{1,40}$`), holder (160), basis (`public_domain|licence|permission|church_owned`), clears_display, clears_offline, clears_audio (booleans), evidence (1000, multiline)}; `save_rights_record` {rights_id, ...}; `verify_rights_record`, `withdraw_rights_record`, `archive_rights_record` {rights_id}. Data `{rights_id, revision, state, live_revision_no, draft_revision_no}`.
- Banners: `content.create_banner` {banner_kind (`theme|campaign`), theme_year (theme: 2000-2100; campaign: null), title (80), subtitle (120, optional), alt_text (250), event_id (campaign only, optional)}; `save_banner` {banner_id, the six, image_asset_id, image_rights_id (both optional in a draft)}; `publish_banner|withdraw_banner|archive_banner` {banner_id}.
- Uploads (the Edge function sends them; expected null): `content.begin_asset_upload` {item_id, purpose, media_type, byte_size, width, height, sha256} -> `{asset_id, item_id, state: pending, draft_path}`; `content.complete_asset_upload` {asset_id} checks `storage.objects` (size and mimetype) -> `state: ready`, else `asset_id: not_uploaded|mismatch`. Purpose `banner_image`: kind banner, use display, png/jpeg/webp, 5 MiB, 960x540 to 6000x6000, ratio 1.30-2.40.
- Paths: drafts `<asset_id>.<ext>` in `content-drafts`; public `<kind>/<item_id>/r<revision_no>/<slot>.<ext>` in `content-public` (`ext` png, jpg, webp).
- `api.content_public_banners()` -> `{banners: [P]}` (at most 12) P = `{banner_id, banner_kind, theme_year, title, subtitle, alt_text, event_id, image: {path, media_type, width, height}, publication_revision, rights_revision, published_at}`.
- `api.content_staff_banners()` -> `{capacity, banners: [S], removals_pending, truncated}`; S = `{banner_id, revision, state, created_at, created_by, updated_at, published_at, published_by, withdrawn_at, archived_at, public_image: shown|waiting|blocked|null, live: R|null, draft: R|null}`; R = `{revision_no, banner_kind, theme_year, title, subtitle, alt_text, event_id, event_title, image: {asset_id, media_type, byte_size, width, height}|null, rights: {rights_id, label, state, live_revision_no, display: null|<rights check code>}|null, saved_at, saved_by}`.
- `api.content_staff_rights()` -> `{capacity, rights: [S], truncated}`; S = `{rights_id, revision, state, created_at, created_by, updated_at, verified_at, verified_by, withdrawn_at, archived_at, q5_uses: [..], live: R|null, draft: R|null}`; R = `{revision_no, label, source_key, holder, basis, clears_display, clears_offline, clears_audio, evidence, saved_at, saved_by}`.
- Edge-only reads (editors): `api.content_file_plan()` -> `{place: [{public_path, draft_path, media_type}], remove: [public_path], waiting, removals_pending}`; `api.content_asset_preview(asset_id)` -> `{asset: {draft_path, media_type}|null}`.
- Edge function `content-assets` (verify_jwt false; the caller's `Authorization` is forwarded to PostgREST; CORS `*` without credentials): `POST ?action=upload&item_id=&purpose=` raw bytes -> 200 `{outcome: uploaded, asset_id, media_type, byte_size, width, height}`, 413/415/422 `{outcome: refused, code, field_errors}`, 401, 403, 503; `POST ?action=sync` -> `{outcome: synced, placed, removed, waiting, removals_pending}`; `GET ?action=preview&asset_id=` -> the bytes, `no-store`.

## Auto Run Result

- **Summary:** rights records (a Content kind; verify = publish), the `q5_content_rights` gate, the
  rights check beside the unchanged 6.1 lifecycle helper, private `content-drafts` and public
  `content-public` buckets with no storage object added, the `content-assets` Edge Function
  (measured and sanitised uploads under the editor's live session, the public-bucket sync from the
  database's desired set, draft previews), file slots on revisions, per-kind public conditions, Home
  banners with staff web Banners and Rights and the mobile 16:9 carousel with tap-to-open original.
- **Review:** 8 findings: 4 patched (2 high, 2 medium), 2 deferred (1 medium, 1 low), 2 rejected
  (low; reasons in the triage log).
- **Follow-up review recommended:** true. Two highs were patched on the first pass. The specific
  unverified risk is the new image sanitiser (`sanitizeImage`) on real-world files: progressive and
  restart-marker JPEGs from phones, APNG and interlaced PNGs, and lossless or alpha WebP. Its tests
  use constructed files.
- **Verification:**
  - Full pgTAP on a fresh reset: PASS (59 files, 4638).
  - Local guards: 0.
  - E2E: 15/15. Node tests: 17/17.
  - Flutter: see the final merge note below.
  - check-migrations, check-function-imports and scan-secrets: pass.
  - Staging: `20261022012809`, with hashes identical to the local reset.
- **Residual risks:**
  - No scheduler runs the sync: a withdrawn file stays fetchable at its old path until an editor's sync runs (staff web runs it after every lifecycle command and when Banners opens).
  - Exif orientation is dropped with the metadata.
  - The owner's signed-in staging walkthrough is not done.

## Verification

**Commands:**
- `npx supabase db reset --local && npx supabase test db` (under the shared lock) -- expected: all files pass
- `select count(*) from app.contract_boundary_violations()` and `app.contract_unowned_objects()` -- expected: 0
- `node --test supabase/functions/content-assets/logic.test.mjs tools/identity-e2e/content-banners.test.mjs` -- expected: pass
- `node tools/identity-e2e/content-banners.mjs --evidence <file>` (phone switch on, functions served) -- expected: all checks pass
- `flutter analyze && flutter test` in `packages/design_system`, `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: clean, pass
- `node tools/ci/check-migrations.mjs --base origin/main`, `npm run -s ci:secrets`, `npm run -s ci:function-imports` -- expected: pass
