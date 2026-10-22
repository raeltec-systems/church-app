---
title: 'Publish pinned announcements with an optional generic push'
type: 'feature'
ticket: '13'
created: '2026-10-21'
status: in-progress
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
  - '{project-root}/docs/runbooks/notifications.md'
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/.agents/skills/design-taste-frontend/references/app-screens.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** The church cannot post a short announcement, pin it, or tell members about it. Guests have no announcement to read, and Notifications has no source for a church-wide notice.

**Approach:** A second Content kind, `announcement`, on entry 1's lifecycle through its registries (kind row, commands, erase part; no shared function replaced): title, body and a pinned flag per revision; anonymous reads with pinned first; a staff web **Announcements** editor (Content group); a mobile list, detail and Home section for everyone; and an optional notification on publication through the 3.2 source contract (generic text, deep link `/announcements/{source_id}`, the category `content_announcement`/`announcement_published` members can switch off in 3.7's settings, the inbox item kept) to every member whose current access allows it.

**Decisions:**
- Decision (agent, under owner pre-approval): Notifications has no church-wide fan-out; `app.notifications_enqueue` takes one recipient per logical key. The bounded approach the contracts allow: `content.publish_announcement {notify: true}` enqueues one job per recipient inside the publish transaction, for at most `app.content_announcement_audience_limit()` (1000) recipients; more is refused (`{notify: too_many_recipients}`) and the editor can publish without a notification. Recorded as a gap in `notifications.md` (no Notifications contract change in this entry). Delivery is paced by the worker (`batch_max` per run).
- Decision (agent): recipients are approved members whose 3.5 route is `member` (`app.notifications_recipient_route`), at publish and again at every recheck (`recipient_eligible`), so held, in-review, accountless, deactivated and deleted members get no job, item, push job or direct-contact need; guests and Pending accounts are not members. Content registers no direct-contact route (a public announcement creates no contact need).
- Decision (agent): the pinned flag belongs to the revision (changing it is save + publish), so no new audit action and no replacement of `app.content_state_ok`. `notify` is required on every publish; a revision is notified at most once (`{notify: already_notified}`), so republishing a withdrawn revision never sends a second notice. The source revision of a job is the published revision number; a new published revision or a withdrawal/archive cancels pending jobs (`source_revised` / `source_cancelled`) and opened older items read as out of date.
- Decision (agent): own Dart port, controller and screens (`AnnouncementsRepository`, `announcement_controllers.dart`, `announcement_screens.dart`, `staff_announcements_screen.dart`) so parallel entries 2 and 3 never edit the same class; shared files get one-line registrations only.

## Boundaries & Constraints

**Always:** writes only through `api.content_command` (registered commands, entry 1 authorizer and replay recheck); handlers `set search_path = ''`, `app.cmd_fail` codes, outcomes with ids, states, revisions and the notified count only; Notifications last in the lock order; push and inbox text are the contract's fixed generic text, never the announcement's; ASCII migration, no backslashes, no row deletion, no destructive statement; ledgers updated (`command_foundation_test.sql`, the 6.1 test's registry asserts scoped to events); church time in every UI.

**Never:** a change to entry 1's shared functions (`app.content_state_ok`, the helpers, dispatch, authorizer, deletion hook); a Notifications function change; announcement text in a job, inbox item, push payload, audit or receipt; posters or files (entry 2); top-bar search and the finished Home (entry 14); offline cache (entry 4); edits to the redesign agent's staff screens.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Create / save | Media, Pastor, Admin; `{title, body, pinned}` | draft revision; public reads unchanged | plain member, Pending: `forbidden`; anon 401; `title`/`body` `required|invalid|too_long` (100/1500), `pinned` `required|invalid` |
| Publish, no notice | `{announcement_id, notify: false}` | published; `notified: 0`; anon list shows it | `nothing_to_publish`, `archived`, stale `conflict` |
| Publish with notice | `notify: true` | one job per eligible member (approved, route `member`), `notified: N`; revision records notified_at/by/count | Q2 closed (production): `unavailable`, nothing published; > 1000: `{notify: too_many_recipients}`; revision already notified: `{notify: already_notified}` |
| Worker | due jobs | each eligible member one inbox item (generic title/body, target `/announcements/<id>`); a push job only with a live device and the category on | held/accountless after publish: `ineligible recipient_ineligible`, no need |
| Category off | `notifications.set_push_category {content_announcement, announcement_published, false}` | inbox item, no push job | |
| Push payload | `notifications.push_prepare` | `{title: "Church announcement", body: <generic>, item_id}`; no announcement title or body | |
| Anonymous read | anon, Pending, member | `{announcements: [P], truncated}` pinned first, then newest; P = `{announcement_id, title, body, pinned, publication_revision, published_at}` | unknown/draft/withdrawn/archived id: `{announcement: null}` |
| Withdraw / archive | published | gone from public reads; pending jobs cancelled; an opened older item is out of date | `not_published`, `archived` |
| Edit published | save then publish | draft private, live stays public until republished; old pending jobs cancelled at republish | |
| Staff read | editor | `{capacity, audience: {members, limit}, announcements: [S], truncated}` | member 403 `not_granted`, Pending 403, anon 401 |
| Deletion | editor erased | revision saved/published/notified attribution nil; `Former member`; check 0 | |

</intent-contract>

## Code Map

- `supabase/migrations/20261021233523_content_events_tracer.sql` -- reuse: `content_kinds` row, `content_register_command`, `content_register_erase_part`, `content_command_actor`, `content_free_text`, `content_item_open|lock|draft_no|saved|publish|withdraw|archive|outcome`, `content_editor_name`, revision guard pattern, public/staff read pattern, privilege block.
- `supabase/migrations/20261021111547_cells_absence_notices.sql` -- source check + reminder check + contract registration + enqueue loop pattern.
- `supabase/migrations/20261008135811_notifications_routing.sql` (`app.notifications_recipient_route`) -- current-access route; Duties uses it the same way (`duties_leader_reachable`).
- `supabase/tests/content_events_test.sql`, `command_foundation_test.sql` -- registry and privilege ledgers to extend.
- `tools/identity-e2e/content-events.mjs`, `routing.mjs` (worker credential, holds, accountless, devices), `push.mjs` (outbound gate open/restore) -- E2E patterns; numbers +44 7700 900681-900689.
- Dart: `content_controllers.dart` (`PublicReadController`, `PublicReadState`, `ContentAction`), `calendar_screens.dart` (`staleNotice`, `publicReadProblem`, `EventRowsCard`, `churchShortWhen`), `content_screens.dart` (staff page pattern), `home_screen.dart`, `shell_routing.dart` (`ClientPaths`, `deepLinkTargets`), `providers.dart`, `composition.dart`, `testing.dart`, `church_client_core.dart`; `apps/mobile/lib/app.dart` (`_showsTopBar`), `apps/staff/lib/app.dart` (Content group).

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/<ts>_content_announcements.sql` -- kind, revisions table and guard, audience helpers, source and reminder checks, contract registration, five commands, public and staff reads, erase part, privileges.
- [ ] `supabase/tests/content_announcements_test.sql`; ledgers in `command_foundation_test.sql`; 6.1 test registry asserts scoped to events.
- [ ] `tools/identity-e2e/content-announcements.mjs` + `.test.mjs` -- the verify at the API with the worker and push_prepare.
- [ ] `packages/contracts/fixtures/v1/notification_key.json` -- an announcement key carries no title or body; regenerate Dart fixtures.
- [ ] client_core domain, adapter, controllers, screens, routes, deep link, providers, composition, fakes, exports, Home section; tests `test/content/announcements_test.dart`.
- [ ] `apps/mobile/lib/app.dart` (no top bar on announcement screens), `apps/staff/lib/app.dart` (Announcements for Media, Pastor, Admin); app tests.
- [ ] `docs/runbooks/content.md`, `notifications.md` (the fan-out gap), `production-promotion-content.md`, `contracts-and-owner-seams.md`.

**Acceptance Criteria:**
- Given the local stack, when the E2E runs, then a pinned and an unpinned SYNTHETIC announcement are published (one with a notice), the anonymous read returns both with the pinned one first, each eligible member gets one inbox item and one job, a member with the category off gets the item and no push job, held, accountless and Pending get no job, and no job, item, receipt or push_prepare message carries the announcement's title or body.
- Given `flutter test`, when run, then a signed-out phone opens Home's announcements and the list (pinned first) and detail, the inbox deep link pattern is known, and staff web shows Announcements to editors only with a publish dialog that previews the generic notice.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Design Notes

Wire contract (SQL, Dart and the E2E share it):
- Commands (`api.content_command`): `content.create_announcement` (expected null) `{title, body, pinned}`; `content.save_announcement` `{announcement_id, title, body, pinned}`; `content.publish_announcement` `{announcement_id, notify}`; `content.withdraw_announcement`, `content.archive_announcement` `{announcement_id}`. Success `data` = `{announcement_id, revision, state, live_revision_no, draft_revision_no, notified}` (`notified` on publish only). Field codes: `title` 100, `body` 1500 multiline; `pinned`, `notify` booleans (`required|invalid`); `announcement_id: nothing_to_publish|not_published|archived`; `notify: already_notified|too_many_recipients`.
- `api.content_public_announcements()` -> `{announcements: [P], truncated}` (at most 100); `api.content_public_announcement(announcement_id)` -> `{announcement: P|null}`; P = `{announcement_id, title, body, pinned, publication_revision, published_at}`.
- `api.content_staff_announcements()` -> `{capacity, audience: {members, limit}, announcements: [S], truncated}` (at most 500); S = `{announcement_id, revision, state, created_at, created_by, updated_at, published_at, published_by, withdrawn_at, archived_at, live: R|null, draft: R|null}`; R = `{revision_no, title, body, pinned, saved_at, saved_by, notified_at, notified_by, notified_count}`.
- Notifications: source `content_announcement`, kind `announcement_published`, title `Church announcement`, body `The church has posted an announcement. Open the app to read it.`, link `/announcements/{source_id}`; source revision = published revision number.

## Verification

**Commands:**
- `npx supabase db reset --local && npx supabase test db` -- expected: all files pass
- `select count(*) from app.contract_boundary_violations()` / `app.contract_unowned_objects()` -- expected: 0
- `node tools/identity-e2e/content-announcements.mjs --evidence <file>` (phone switch on) and `node --test tools/identity-e2e/content-announcements.test.mjs` -- expected: all checks pass
- `flutter analyze && flutter test` in `packages/design_system`, `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: clean, pass
- `npm run contracts:test`, `dart test` in `packages/contracts/dart` -- expected: pass
- `node tools/ci/check-migrations.mjs --base origin/main` and `npm run -s ci:secrets` -- expected: pass
