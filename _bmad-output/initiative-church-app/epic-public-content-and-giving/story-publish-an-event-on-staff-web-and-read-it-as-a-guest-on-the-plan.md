---
title: 'Publish an event on staff web and read it as a guest on the mobile Calendar'
type: 'feature'
ticket: '1'
created: '2026-10-21'
status: 'built'
baseline_revision: 'eca3960356217484f1ffd66a8bba1024359ce13a'
route: 'full'
route_source: 'auto'
review: 'quick'
review_source: 'pinned'
lenses_ran: ['quick']
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/runbooks/command-foundation.md'
  - '{project-root}/docs/runbooks/client-shells.md'
  - '{project-root}/.agents/skills/design-taste-frontend/references/app-screens.md'
warnings: ['oversized', 'multiple-goals']
deferred:
  - summary: >-
      The staff Events controller replaces the list with the failure when a refresh fails, as the
      Duties and Cells staff controllers do.
    evidence: |-
      Reviewer finding 5 (second half). The public reads now keep the last good answer with a
      "Couldn't refresh" notice; the staff screens share the established Duties/Cells pattern
      (protected state dropped on any failure). Changing it belongs to a staff-wide pass, not to
      one screen.
    location: >-
      packages/client_core/lib/src/application/content_controllers.dart (StaffEventsController._reload)
    severity: low
---

<intent-contract>

## Intent

**Problem:** Content has no tables, commands or reads, a signed-out caller gets no tab at all, and members' tabs are the stand-ins Home, Duties and My cell. Nothing a church publishes can reach a guest.

**Approach:** Tracer for epic 6. Add the Content owner's shared publication lifecycle (generic items with private drafts, immutable published revisions, publish, withdraw and archive, attributed content-free audit, per-kind editor roles), a registered command table and one deletion handler with a per-kind erase-part list, the first unauthenticated read contract (published projection only), events (title, description, church-time start and end, location), a staff web **Events** editor, and the mobile public shell (Home and Calendar tabs for everyone; My duties, My follow-ups and My cell on Home cards and the Account menu; Home in its own file).

**Decisions:**
- Decision (agent, under owner pre-approval): public reads are `security definer` `app` functions behind SQL `api` wrappers granted to `anon` and `authenticated`, not `security_invoker` views. Every Content table keeps zero client privileges (the verify's "no client role can write a Content table", and no column of a draft row is ever selectable); the projection is fixed in one function that pgTAP pins key by key. Public reads are not logged per call (anonymous, no personal data).
- Decision (agent, under owner pre-approval): the lifecycle is generic: `app.content_items` (kind, state `draft|published|withdrawn|archived`, `live_revision_no`, `draft_revision_no`, aggregate `revision`) plus one revision table per kind (`app.content_event_revisions`). A save writes the open draft or opens the next revision number; publish makes the draft live (or re-publishes the live revision of a withdrawn item); the live revision stays public until a replacement is published. A published revision's content is immutable (trigger); only attribution may be anonymised.
- Decision (agent, under owner pre-approval): later entries register, never edit: kinds (`app.content_kinds`, with their editor roles: event = admin, pastor, media), commands (`app.content_register_command`) and erase parts (`app.content_register_erase_part`) are rows, so parallel entries (2, 3, 13) do not replace a shared dispatch function.
- Decision (agent, under owner pre-approval): commands are kind-specific (`content.create_event`, `save_event`, `publish_event`, `withdraw_event`, `archive_event`) so later kinds can add checks (rights, verification, linked duties) without touching events. Saves carry every field (absolute state, no patch masks).
- Decision (agent, under owner pre-approval): editor attribution is shown to editors only, as display names; an erased editor reads `Former member` from the API. No Q4 gate on Content (church-authored public content; the only personal data is editor attribution shown to editors). No `SYNTHETIC` prefix is enforced (test data is SYNTHETIC by practice).
- Decision (agent, under owner pre-approval): mobile tabs in this entry are Home and Calendar (the entry's description); Give, Bible & Hymns and Sermons join with entries 3, 6 and 9. Calendar lists upcoming and ongoing events grouped by church month; detail shows both endpoints. Home shows a short Coming up list of real published events for everyone (entry 14 turns it into posters); guests and Pending applicants see no member card.

## Boundaries & Constraints

**Always:** every write through `api.content_command` (1.4 envelope, registered `content` authorizer that share-locks the actor's role grants, replay recheck `app.content_in_scope`); handlers `set search_path = ''`, qualified names, `app.cmd_fail` codes; outcomes carry ids, states and revisions only (no names); ASCII migration with no backslashes; privilege ledgers in `command_foundation_test.sql` updated; times UTC on the wire, church time (Africa/Lusaka) in every UI.

**Never:** posters, files or buckets (entry 2), RSVP or Add to calendar (11), duty links (12), search (14), offline cache or new persistence (4), Calendar overlays (19), a row deletion in an ordinary command, any anon grant other than the two public reads, any change to the staff shell frame or shared staff page frames beyond adding the Events destination.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Create draft | Media/Pastor/Admin, all five fields | item `draft`, revision 1, draft 1; public read unchanged | none |
| Create refused | plain member, Pending, guest; bad or missing field; end before start; > 31 days | `forbidden` / 401 / field codes | nothing written |
| Publish | draft exists | `published`, live = draft, draft null; public read shows it | none |
| Edit published | save_event on a published item | new draft revision; public read still shows the live revision | stale revision: `conflict` |
| Republish | publish with draft | public read shows the new revision | nothing to publish: `validation_failed {event_id: nothing_to_publish}` |
| Withdraw / archive | published item | gone from both public reads; archived refuses every later command (`archived`) | not published: `not_published` |
| Public reads | anon, Pending, member | only `event_id,title,description,starts_at,ends_at,location,publication_revision,published_at` of current published, unended items | unknown/withdrawn id: `{"event": null}` |
| Staff read | editor | every event with live and draft revisions and attribution | plain member 403 `not_granted`; Pending 403; anon 401/permission |
| Tables | any client role | no privilege on any `app.content_*` table | permission denied |
| Replay | same request id/body | stored result; actor who lost the role: `forbidden` | |
| Deletion | editor erased | attribution and audit actor become the nil UUID; staff read says `Former member`; check answers 0 | |

</intent-contract>

## Code Map

- `supabase/migrations/20261013220239_duties_department_tracer.sql` -- template: actor helper, authorizer (`app.cmd_register_authorizer`), in-scope, entry + `api` wrapper, reads behind `app.identity_require_access()`, deletion hook, privilege block.
- `supabase/migrations/20261021094249_cells_programme_publish.sql` (`app.cells_free_text`) -- text validation without backslashes (chr codes).
- `supabase/migrations/20261003134340_cross_epic_contracts.sql` -- `content` module/prefix already registered (edges: platform, identity, duties, followups, notifications); `app.contract_validate_handler`, `app.contract_unknown_keys`, `app.contract_instant_error`, `app.contract_uuid_error`, `app.cmd_utc`.
- `supabase/migrations/20261007174952_member_deletion.sql` -- `app.identity_register_deletion_hook`, `app.identity_call_deletion_hooks`.
- `supabase/tests/command_foundation_test.sql` -- anon and authenticated EXECUTE ledgers.
- `packages/client_core/lib/src/presentation/duties_screens.dart` (`MemberHomeScreen`, `MyDutiesHomeCard`, `_DutiesPage`), `cell_screens.dart` (`MyCellHomeCard`, `MyCellScreen` tabRoot), `account_screen.dart` (menu links), `shell_routing.dart`, `church_widgets.dart` (`ChurchDateBadge`, `MemberTabPage`), `adapters/supabase_api_reader.dart`, `application/cell_controllers.dart` (controller pattern), `testing.dart` (fakes, harness).
- `apps/mobile/lib/app.dart` (tabs, top bar), `apps/staff/lib/app.dart` (destinations only).
- `tools/identity-e2e/cells-meetings.mjs`, `harness.mjs` -- E2E pattern.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261021233523_content_events_tracer.sql` -- lifecycle, registries, events, commands, public and staff reads, deletion handler, privileges.
- [x] `supabase/tests/content_events_test.sql` + ledger update -- the matrix.
- [x] `tools/identity-e2e/content-events.mjs` + `.test.mjs` -- the verify at the API (fictional block +44 7700 900100-900109; see Implementation Notes).
- [x] client_core: `domain/content_events.dart`, `adapters/supabase_content_repository.dart`, `application/content_controllers.dart`, `presentation/{home_screen,calendar_screens,content_screens}.dart`, routes, providers, composition, fakes, exports; tests under `test/content/`.
- [x] `apps/mobile/lib/app.dart` (Home + Calendar tabs for all), `apps/staff/lib/app.dart` (Events for Media, Pastor, Admin); app tests.
- [x] `docs/runbooks/content.md`, `docs/runbooks/production-promotion-content.md`; links from `contracts-and-owner-seams.md` and `client-shells.md`.

**Acceptance Criteria:**
- Given the local stack, when the E2E runs, then a Media member drafts and publishes a two-day `SYNTHETIC Harvest Thanksgiving`, anon reads it with both endpoints, an edited draft leaves the live revision public until republished, withdrawal removes it, anon and Pending read no draft or editor identity, a plain member is refused every command, direct table queries are refused and an erased editor reads as `Former member`.
- Given `flutter test` in each package, when run, then a signed-out phone shows Home and Calendar tabs and the event with both endpoints, and staff web shows Events only to editors.

## Implementation Notes

- Server implemented in this session; the Dart side (client_core, mobile, staff) by a forked
  implementation agent with this plan and the wire contract, reviewed here. Plan to code: as
  designed (generic `app.content_items` + `app.content_event_revisions`, registries for kinds,
  commands and erase parts, definer public reads granted to anon).
- Migration `supabase/migrations/20261021233523_content_events_tracer.sql` (staging's version; the
  local file was `20261021233000` until applied). pgTAP `supabase/tests/content_events_test.sql`
  (120). Ledgers: `command_foundation_test.sql` (anon and authenticated EXECUTE),
  `notifications_routing_test.sql` (the deletion check now lists `content=0`).
- E2E `tools/identity-e2e/content-events.mjs` (10/10, `evidence-6.1/content-events-e2e.jsonl`) and
  `content-events.test.mjs` (5). The plan's block +44 7700 900700-900709 collides with
  `runbooks.mjs` (900700-900719): the run uses the free block 900100-900109. The erased-editor check
  calls Content's registered hook directly (as the 2.11 worker's erase step does), not the whole
  deletion workflow.
- Clients: `domain/content_events.dart`, `adapters/supabase_content_repository.dart` (public reads
  through `SupabaseApiReader.read(public: true)`, which skips the signed-out short-circuit only),
  `application/content_controllers.dart`, `presentation/home_screen.dart` (Home moved out of
  `duties_screens.dart`), `calendar_screens.dart`, `content_screens.dart`; routes `/calendar`,
  `/calendar/events/:id` (mobile, under `memberHome`) and `/content/events`. My duties and My cell
  became pushed screens; Home card and Account menu links push.
- Merged `story/5.8-meetings-held` at c789850 (the staff web redesign): Events sits in a new
  **Content** sidebar group (Media, Pastor, Admin; the coordinator's note said Media and Admin, the
  entry and K1 say Media, Pastor and Admin, which is what is built) and uses the redesign's
  `ChurchPageScaffold` page header (title, the finding line, New event, Reload).
- Flutter after the merge and the review fixes: design_system 14, client_core 778, mobile 60,
  staff 48; analyze clean in all four. Full pgTAP suite PASS (58 files, 4490 tests) on a fresh
  reset; check-migrations and scan-secrets pass.
## Plan Change Log

## Review Triage Log

### 2026-10-21 — Review pass (independent reviewer: the entry's external check plus the quick lens)
- verdicts: 13 findings — high 1, medium 3, low 8, false 0, maybe-false 0 (one finding grouped with
  its root cause)
- findings:
  - `[high]` `[patch]` Whitespace-only text (tab, line breaks, U+00A0) was accepted as a value and
    edge whitespace kept (`btrim` trims spaces only) — `app.content_free_text` now maps Unicode
    spaces to spaces and trims all edge whitespace; the revision table refuses blank text; pgTAP
    cases added. Fixed before staging.
  - `[high]` `[patch]` (same root cause) One such event made both Dart list parsers refuse the whole
    list, so every guest's Calendar and the editors' screen would fail — closed by the server fix;
    the strict parse is kept (a malformed answer stays a failed read, never a guessed value).
  - `[medium]` `[patch]` The staff finding and sections counted a published event with unpublished
    changes as "not published" and left it off "On the calendar" — the finding now counts every
    public event ("N waiting to publish · N on the public calendar"); the section is "Waiting to
    publish".
  - `[medium]` `[patch]` Home showed the guest copy to a signed-in member whose access read failed
    and told Pending applicants to sign in — Home now keeps the member cards on a failed access
    read (each card reports its own failure) and shows a neutral line to signed-in accounts without
    member access; tests added.
  - `[medium]` `[patch]` A failed refresh wiped the public events on screen (app-screens section 11)
    — public reads keep the last good answer and show "Couldn't refresh ... as it was at HH:MM";
    test added. The staff controller's same behaviour is deferred (house pattern of every staff
    controller).
  - `[low]` `[patch]` One-day rows were spoken without a date — the row's spoken label now carries
    the date; test added.
  - `[low]` `[patch]` "No events are published yet" also showed when published events had ended —
    now "No upcoming events" (Calendar, Home, promotion runbook).
  - `[low]` `[patch]` The detail read returned ended events although the matrix says unended items
    only — the projection function now requires `ends_at > now()` for both reads; pgTAP updated.
  - `[low]` `[patch]` Links from `contracts-and-owner-seams.md` and `client-shells.md` were missing —
    added (deletion hook list, a Content registries section, the mobile tabs).
  - `[low]` `[patch]` The E2E phone block differed from the plan with no note — recorded above (the
    plan's block collides with `runbooks.mjs`).
  - `[low]` `[patch]` A format-only change to the staff shell's `_RoleSwitch` — reverted.
  - `[low]` `[patch]` The promotion runbook's rollback sentence mixed two actions — rewritten.
  - `[low]` `[patch]` "a withdrawn event says so instead of an old copy" never loaded a copy — the
    test now loads the event, withdraws it in the fake and reloads.
- External check verdict: PASS (`evidence-6.1/external-check.md`).

## Design Notes

Wire contract (shared by SQL, Dart and the E2E):
- Commands: `content.create_event` (expected null) `{title, description, starts_at, ends_at, location}`; `content.save_event` `{event_id, ...the same five}`; `content.publish_event`, `content.withdraw_event`, `content.archive_event` `{event_id}`; expected = the event's `revision`. Success `data` = `{event_id, revision, state, live_revision_no, draft_revision_no}`. Field codes: text `required|invalid|too_long` (title 120, location 160, description 2000 multiline); instants `required|invalid|out_of_range` (start within 1 year back, 5 years ahead); `ends_at: before_start|too_long` (31 days); `event_id: nothing_to_publish|not_published|archived`.
- `api.content_public_events()` -> `{events: [P], truncated}`; `api.content_public_event(event_id)` -> `{event: P|null}`; P = `{event_id, title, description, starts_at, ends_at, location, publication_revision, published_at}` (instants `YYYY-MM-DDTHH:MM:SS.ffffffZ`).
- `api.content_staff_events()` -> `{capacity, events: [S], truncated}`; S = `{event_id, revision, state, created_at, created_by, updated_at, published_at, published_by, withdrawn_at, archived_at, live: R|null, draft: R|null}`; R = `{revision_no, title, description, starts_at, ends_at, location, saved_at, saved_by}`; `*_by` are display names (`Former member` once erased).

## Verification

**Commands:**
- `npx supabase db reset --local && npx supabase test db` -- expected: all files pass
- `select count(*) from app.contract_boundary_violations()` and `app.contract_unowned_objects()` -- expected: 0
- `node tools/identity-e2e/content-events.mjs --evidence <file>` (phone switch on) and `node --test tools/identity-e2e/content-events.test.mjs` -- expected: all checks pass
- `flutter analyze && flutter test` in `packages/design_system`, `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: clean, pass
- `node tools/ci/check-migrations.mjs --base origin/main` and `npm run -s ci:secrets` -- expected: pass

## Auto Run Result

- **Summary:** Content's publication lifecycle (private drafts, immutable published revisions live
  until replaced, withdraw, archive, content-free audit, per-kind editor roles), registries for
  kinds, commands and erase parts, the first anonymous read contract (events' published
  projection), the editors' read, Content's deletion hook; staff web **Events** (Content group,
  page header); mobile Home and Calendar tabs for everyone, Home in its own file, the public
  Calendar with both endpoints of a multi-day event.
- **Files:** `supabase/migrations/20261021233523_content_events_tracer.sql` (new owner),
  `supabase/tests/content_events_test.sql` (120) and two ledger updates;
  `tools/identity-e2e/content-events.mjs` + `.test.mjs`; client_core domain, adapter, controllers,
  `home_screen.dart`, `calendar_screens.dart`, `content_screens.dart`, routes, fakes, exports;
  `apps/mobile/lib/app.dart` (tabs), `apps/staff/lib/app.dart` (Content group); runbooks
  `content.md`, `production-promotion-content.md`, links in `contracts-and-owner-seams.md` and
  `client-shells.md`; evidence `evidence-6.1/`.
- **Review:** 13 findings, 12 patched (1 high, 3 medium, 8 low), 1 deferred (staff controller keeps
  the house pattern), none rejected.
- **Follow-up review recommended:** true — a high was patched on the first pass. The specific
  unverified risk: the new whitespace normalisation in `app.content_free_text` (Unicode space
  classes) has pgTAP cases but no second reviewer has probed it.
- **Verification:** full pgTAP PASS (4490) on a fresh reset; E2E 10/10; Flutter design_system 14,
  client_core 778, mobile 60, staff 48, analyze clean; check-migrations and scan-secrets pass;
  staging `20261021233523` with function, constraint and column hashes identical to the local reset
  and guards 0 (`evidence-6.1/staging-verify.md`).
- **Residual risks:** the owner's phone and staff-web walkthrough on staging is not done
  (`content.md`, "Owner manual check"); two bottom tabs until entries 3, 6 and 9 add theirs.

