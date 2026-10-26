---
title: 'Show event posters, export events to the phone calendar and RSVP within capacity'
type: 'feature'
ticket: '11'
created: '2026-10-26'
status: in-progress
baseline_revision: '7eb4f866864806ff7baefcb23f2c351786bd93f8'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/runbooks/content.md'
  - '{project-root}/docs/runbooks/identity-access.md'
  - '{project-root}/.agents/skills/design-taste-frontend/references/app-screens.md'
  - '{project-root}/.agents/skills/design-taste-frontend/references/tells.md'
  - '{project-root}/docs/design-handoff/README.md'
warnings: ['oversized', 'multiple-goals']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Events (6.1) have no poster, no way into a phone calendar and no RSVP. Members cannot say they are coming, organisers cannot plan around numbers, and a member who leaves or is deleted would leave places taken.

**Approach:** Extend the events lane only: an optional poster through the 6.2 asset path (purpose `event_poster`, slot `poster`, alt text, rights record), shown as a 16:9 thumbnail in the Calendar list and in full on the detail; Add to calendar on the mobile detail through the 4.5 handoff with the 4.5 iCalendar rules (both endpoints, stale-copy caveat, Duties export unchanged); optional RSVP with an optional capacity for approved members with live access (transactional under the event lock, Full when reached, cancel and release are state changes); per-event organisers; a Content lifecycle hook that releases a deactivated member's future RSVPs; an RSVP erase part whose row deletion lives in a `_rows` migration.

**Decisions:**
- Decision (owner, 2026-10-21): an event's organisers and Admin see the names of members who RSVP; everyone else (other editors, members, guests) sees only the count and the spaces left. This replaces the ticket's "counts only for editors".
- Decision (agent, under owner pre-approval): "an event's organisers" are per event: a list of up to 10 members who hold an event editor role (Media, Pastor, Admin). The editor who creates an event is its first organiser (existing events: their creator). Only an Admin or a current organiser changes the list, so another editor cannot make themselves an organiser. Names are shown on staff web only (organisers are editors); mobile shows counts. Organisers without a staff role (for example a ministry leader) are an owner question, not built.
- Decision (agent): RSVP is open from publication until the event starts; the capacity is optional (no capacity = counts only, never Full). Lowering the capacity below the people already going bumps nobody: the event shows Full until places free. Turning RSVP off keeps the rows; they count again if it is turned back on.
- Decision (agent): member commands go through the one envelope `api.content_command`. A registry `app.content_member_commands` lists commands any approved member with live access may send; `app.content_authorize_command` and `app.content_in_scope` are replaced once, registry-driven, with editor-command behaviour unchanged (entry 8's favourites reuse it). A member command key-share-locks the actor's member row before the receipt, so a concurrent deactivation waits for it and the handler re-reads access after the lock.
- Decision (agent): the offline Calendar snapshot keeps its 6.4 shape: posters and RSVP counts are not cached (online only); the detail stays online only. Display-only rule unchanged.
- Decision (agent): no notification is sent for any RSVP change (nothing new on staging's live push).

## Boundaries & Constraints

**Always:** every write through `api.content_command` with registered commands; the 6.1 lifecycle helper, dispatch and deletion hook unchanged (extend by rows: kinds, purposes, commands, member commands, erase part, public condition, lifecycle hooks); handlers `set search_path = ''`; outcomes carry ids, states, counts and revisions, never names; RSVP and organiser changes are state changes (no row deletion outside the `_rows` file); capacity checked under the event row lock (`FOR UPDATE` on `app.content_items`, never bumping the event revision for an RSVP); lock order actor member row (key share) or role grants (share) -> receipt -> event item -> RSVP and organiser rows; ASCII migrations with no backslashes; privilege ledgers scoped to this entry's functions; SYNTHETIC data only; church time in every UI.

**Never:** names, member ids or per-member state in any public projection or the offline cache; an RSVP for guests, Pending, held or deactivated accounts; a waitlist; changes to the Duties `.ics` bytes; push or inbox notices; Calendar overlays (19), duty links (12), Home poster cards (14); edits to `banner_screens.dart` or `banner_controllers.dart` beyond additive exports; staging notifications; production.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Poster on a draft | editor saves with an uploaded `event_poster` asset, a rights record and alt text | draft revision has the poster; public read unchanged | rights or alt missing: `required`; another item's asset: `unknown` |
| Publish with poster | rights clear display now, asset ready | public event names the poster once sync placed it; ended event: next sync removes it | `poster_rights_id: not_in_force|use_not_cleared|source_not_cleared`, `poster_asset_id: not_ready` |
| Add to calendar | one-day and three-day events | `.ics` with UTC DTSTART/DTEND (both endpoints), SEQUENCE = publication revision, the caveat; Duties `.ics` byte-identical | handoff result text (shared, dismissed, unavailable, failed) |
| RSVP | approved member, RSVP on, not started, places left | `going`, counts and spaces left update | `full`, `rsvp_closed`, `rsvp_off`, `not_public` |
| Already going | second RSVP | success, nothing changes | |
| Capacity race | several members RSVP at once for the last place | exactly one `going`, the others `full`; going never exceeds capacity | |
| Cancel | going member before the start | `cancelled`, place freed, row kept | `not_going`, `rsvp_closed` |
| Deactivation / deletion request | member going to a future event | RSVP `released`, place freed; organiser rows removed; a login hold changes nothing | |
| Guest, Pending | anon / Pending command | refused (`unauthenticated` / `forbidden`); both read counts only | |
| Names | organiser editor or Admin | names read lists the going members | other editor 403 `not_granted`; member 403; anon refused; public JSON has no names |
| Organisers | Admin or organiser sets up to 10 current event editors | rows active or removed, event revision + 1 | non-organiser editor `forbidden`; `organiser_ids: not_editor|too_many|invalid|required` |
| Replay | same request id and body | stored result; a deactivated actor: `forbidden` | |
| Deletion | member erased | RSVP and organiser rows deleted (`_rows`), organiser attribution anonymised, check 0 | before `_rows`: erase answers `unavailable` (fail closed) |

</intent-contract>

## Code Map

- `supabase/migrations/20261021233523_content_events_tracer.sql` -- event lifecycle commands, `app.content_event_revision_guard`, `content_public_event_json` (replaced by 6.4: `20261022123202`), `content_staff_event_json`, `content_event_revision_json`, `content_staff_events`, authorizer, `content_in_scope`, erase-part registry. Event functions are this lane's to replace; shared helpers (`content_item_*`, `content_command`, `content_erase_member`) are not.
- `supabase/migrations/20261022012809_content_rights_banners.sql` -- asset path: `content_asset_purposes`, `content_revision_files` (slot rows; null clears), `content_file_attach` (F3 version in `20261022112247`), `content_asset_error`, `content_rights_ref_error`, `content_rights_clear`, `content_public_file`, `content_live_file`, `content_register_public_condition`, banner save/publish/staff JSON as templates.
- `supabase/migrations/20261015110202_duties_lifecycle.sql` -- lifecycle hook pattern (`app.contract_register_lifecycle_hook`, event JSON `member_id`); `20261013220239`/`20261013220300` -- fail-closed purge stub and `_rows` file pattern.
- `supabase/tests/content_events_test.sql`, `content_banners_test.sql`, `command_foundation_test.sql` (anon/authenticated EXECUTE ledgers), `cross_epic_contracts_test.sql` -- pgTAP style and ledgers.
- `tools/identity-e2e/content-banners.mjs` (functions serve, uploads, sync), `content-events.mjs`, `lifecycle.mjs` (deactivation), `harness.mjs`.
- Dart: `packages/client_core/lib/src/domain/content_events.dart` (models, `EventInput`, `ContentCommands`, `ContentRepository`), `domain/duty_calendar.dart` (4.5 builder, `DutyCalendarExport` port, `CalendarHandoff`), `domain/content_banners.dart` (`StaffImage`, `BannerRights`, `ContentPurposes`, `BannerRepository.uploadImage/syncFiles/publicFileUrl/previewImage`), `adapters/supabase_content_repository.dart`, `application/content_controllers.dart`, `application/duties_controllers.dart` (`dutyCalendarExportProvider`), `presentation/calendar_screens.dart` (`PublicEventRow` shared with Home Coming up, `EventDetailScreen`), `presentation/content_screens.dart` (staff Events form and row), `presentation/duties_screens.dart` (Add to calendar button and result texts), `testing.dart` (`FakeContent`), `test/content/content_events_test.dart`; `apps/mobile/lib/calendar/share_calendar_export.dart` (already wired); `apps/mobile/lib/offline/public_content_cache_adapter.dart` (no change: it serialises only the 6.4 keys).

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/<v>_content_event_posters_rsvp.sql` -- revision columns and guard, purpose, public condition, organisers and RSVP tables, member-command registry with the authorizer and replay recheck, event commands, RSVP and organiser commands, public, member and staff reads, lifecycle hook, erase part with its fail-closed stub, privileges.
- [ ] `supabase/migrations/<v+1>_content_event_posters_rsvp_rows.sql` -- only the purge body (row deletions), hand-applied on staging.
- [ ] `supabase/tests/content_event_rsvp_test.sql` + ledger updates -- the matrix (concurrency proven by the E2E).
- [ ] `tools/identity-e2e/content-event-rsvp.mjs` + `.test.mjs` -- the verify at the API (block +44 7700 900584-900598).
- [ ] client_core: models, `EventCalendar` + `ICalendarText` (Duties delegates, bytes unchanged), repository reads, controllers, Calendar row thumbnail, detail (poster, RSVP, Add to calendar), staff Events (poster, RSVP, organisers, who's coming, sync), fakes, tests.
- [ ] Runbooks `content.md` (story 6.11 section and owner manual check), `production-promotion-content.md` (migrations, the `_rows` step); `identity-access.md` deletion-hook list line.

**Acceptance Criteria:**
- Given the local stack with functions served, when the E2E runs, then a capacity-2 SYNTHETIC event with a poster publishes and a signed-out caller reads its poster and both endpoints of a three-day event, two members RSVP and a third is refused `full`, racers for one place get exactly one `going`, a cancel frees a place, a deactivated member's place is freed, guests and Pending are refused, members and a non-organiser editor cannot read names while the organiser and Admin can, and a member deletion erases the RSVP with the check at 0.
- Given `flutter test`, when run, then the Calendar row shows a 16:9 thumbnail, the detail shows the full poster, RSVP states (guest Sign in, member going/cancel, Full, closed) and Add to calendar with the caveat, staff web edits poster, RSVP and organisers and shows names only when allowed, and the Duties `.ics` tests pass unchanged.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Design Notes

Wire contract (SQL, Dart and the E2E share it):
- `content.create_event` (expected null) `{title, description, starts_at, ends_at, location, rsvp_enabled?, rsvp_capacity?}`; the actor becomes the first organiser.
- `content.save_event` (expected = event revision) `{event_id, the five, rsvp_enabled?, rsvp_capacity?, poster_asset_id?, poster_rights_id?, poster_alt_text?}`. Absolute state: missing or null `rsvp_enabled` = false; missing or null poster keys = no poster. Codes: `rsvp_enabled: invalid`; `rsvp_capacity: invalid|out_of_range (1-10000)|must_be_null` (RSVP off); `poster_asset_id: required (rights or alt without an asset)|unknown|not_ready|retention_claimed`; `poster_rights_id: required|unknown`; `poster_alt_text: required|too_long (250)|invalid`.
- `content.publish_event` additionally refuses a poster that is not ready (`poster_asset_id: not_ready`) or whose rights do not clear display now (`poster_rights_id: <rights code>`).
- `content.set_event_organisers` (expected = event revision) `{event_id, organiser_ids: [uuid] (0-10, distinct)}`: Admin, or an event editor who is an active organiser; else `forbidden`. Codes `organiser_ids: required|invalid|too_many|not_editor`. Data = the event outcome; an unchanged list changes nothing.
- Member commands (expected null; approved member with live access; guests `unauthenticated`, others `forbidden`): `content.rsvp_event {event_id}` -> going (already going: unchanged); codes `event_id: not_public|rsvp_off|rsvp_closed|full`. `content.cancel_rsvp {event_id}` -> cancelled; codes `event_id: not_going|rsvp_closed`. Data `{rsvp_id, event_id, rsvp_state, going, capacity, spaces_left, full}`; receipt aggregate `content_rsvp` (the RSVP id); envelope revision = the RSVP's revision.
- Public event P (both public reads) gains `poster: null|{path, media_type, width, height, alt_text, offline_allowed}` (only once placed in `content-public` with display rights) and `rsvp: null|{capacity: int|null, going, spaces_left: int|null, full, open}` (`open` = not started).
- `api.content_my_event_rsvp(event_id)` (live member access, else 401/403) -> `{event_id, rsvp_state: going|cancelled|released|null, updated_at}`.
- `api.content_staff_events()`: S gains `public_poster: shown|waiting|blocked|ended|null`, `rsvp_going`, `organisers: [{member_id, name}]`, `sees_names`; R gains `poster: {asset_id, media_type, byte_size, width, height}|null`, `poster_rights: {rights_id, label, state, live_revision_no, display}|null`, `poster_alt_text`, `rsvp_enabled`, `rsvp_capacity`; top level gains `organiser_options: [{member_id, name}]` (current event editors).
- `api.content_staff_event_rsvps(event_id)` (Admin, or an event editor who is an active organiser; other editors 403 `not_granted`) -> `{rsvps: null|{event_id, capacity, going, attendees: [{name, rsvp_at}], truncated}}` (going members only, earliest first, at most 2000).
- Purpose `event_poster`: kind event, display, png/jpeg/webp, 5 MiB, 540x540 to 6000x6000, ratio 0.50-2.40; slot `poster`; public path `event/<event_id>/r<n>/poster.<ext>`; event public condition: the live revision has not ended. Staff web calls the `content-assets` sync after every event command and on opening Events.
- `.ics` (client): `UID:event-<event_id>@bickafue.app`, `SEQUENCE:<publication_revision>`, UTC `DTSTART`/`DTEND`, `SUMMARY`, `LOCATION`, `DESCRIPTION` = the description plus the copy caveat; file `event-YYYY-MM-DD.ics` (church date of the start); the text rules (UTC format, TEXT escaping, 75-octet folding) shared with `DutyCalendar` through `ICalendarText`.

## Verification

**Commands:**
- `npx supabase db reset --local && npx supabase test db` (under the shared lock) -- expected: all files pass
- `select count(*) from app.contract_boundary_violations()` and `app.contract_unowned_objects()` -- expected: 0
- `node --test tools/identity-e2e/content-event-rsvp.test.mjs` and `node tools/identity-e2e/content-event-rsvp.mjs --evidence <file>` (phone switch on, functions served) -- expected: all checks pass
- `flutter analyze && flutter test` in `packages/design_system`, `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: clean, pass
- `node tools/ci/check-migrations.mjs --base origin/main`, `npm run -s ci:secrets`, `npm run -s ci:function-imports` -- expected: pass
