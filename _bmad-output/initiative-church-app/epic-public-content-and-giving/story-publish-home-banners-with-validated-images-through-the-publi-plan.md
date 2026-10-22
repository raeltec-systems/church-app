---
title: 'Publish Home banners with validated images through the public asset path'
type: 'feature'
ticket: '2'
created: '2026-10-21'
status: 'in-progress'
baseline_revision: 'd2ed1540051bda211b0eab50f53acb6e0aca8f1f'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/runbooks/content.md'
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/runbooks/backup-and-restore.md'
  - '{project-root}/.agents/skills/design-taste-frontend/references/app-screens.md'
warnings: ['oversized', 'multiple-goals']
deferred: []
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
- [ ] `supabase/migrations/<version>_content_rights_banners.sql` -- kinds `rights`, `banner`, `asset`; `q5_content_rights` gate; buckets; rights, banner, asset-purpose, asset and revision-file tables with guards; the rights check and file helpers; the commands; public and staff reads; the Edge function's plan and preview reads; erase parts; privileges.
- [ ] `supabase/tests/content_banners_test.sql` + ledger and gate-list updates -- the matrix (Storage presence simulated by rows in `storage.objects`).
- [ ] `supabase/functions/content-assets/{index.ts,logic.mjs,logic.test.mjs}` + `supabase/config.toml` -- upload, sync, preview; sniffing and dimension parsing tested with node.
- [ ] `tools/identity-e2e/content-banners.mjs` + `.test.mjs` -- the verify at the API and Storage (block +44 7700 900501-900509).
- [ ] client_core: `domain/content_banners.dart`, `adapters/supabase_banner_repository.dart`, `adapters/content_file_picker{,_stub,_web}.dart`, `application/banner_controllers.dart`, `presentation/{home_banners,banner_screens}.dart`, routes, providers, composition, fakes, exports; tests under `test/content/`.
- [ ] `apps/staff/lib/app.dart` (Banners and Rights in Content), mobile Home carousel; app tests.
- [ ] Runbooks: `content.md` (banners, rights, Q5, sync, owner check), `backup-and-restore.md` (both buckets), `contracts-and-owner-seams.md` (gate list, registries), `production-promotion-content.md`.

**Acceptance Criteria:**
- Given the local stack with functions served, when the E2E runs, then a Media member uploads a `SYNTHETIC Theme 2026` image and a campaign image, an oversized file and a disguised file are refused with nothing stored, both banners publish and a signed-out caller reads them with fetchable images, and anonymous and member callers cannot fetch a draft, an uncleared or a withdrawn file, cannot list either bucket, and cannot publish with a rights record whose source is missing from the Q5 fixture.
- Given `flutter test`, when run, then a signed-out phone's Home shows the theme card first and the campaign card with text alternatives and opens the original on tap, and staff web shows Banners and Rights only to Media, Pastor and Admin.

## Implementation Notes

## Plan Change Log

## Review Triage Log

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

## Verification

**Commands:**
- `npx supabase db reset --local && npx supabase test db` (under the shared lock) -- expected: all files pass
- `select count(*) from app.contract_boundary_violations()` and `app.contract_unowned_objects()` -- expected: 0
- `node --test supabase/functions/content-assets/logic.test.mjs tools/identity-e2e/content-banners.test.mjs` -- expected: pass
- `node tools/identity-e2e/content-banners.mjs --evidence <file>` (phone switch on, functions served) -- expected: all checks pass
- `flutter analyze && flutter test` in `packages/design_system`, `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: clean, pass
- `node tools/ci/check-migrations.mjs --base origin/main`, `npm run -s ci:secrets`, `npm run -s ci:function-imports` -- expected: pass
