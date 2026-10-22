---
title: 'Publish pinned announcements with an optional generic push'
type: 'feature'
ticket: '13'
created: '2026-10-21'
status: built
baseline_revision: 'd2ed1540051bda211b0eab50f53acb6e0aca8f1f'
route: 'full'
route_source: 'auto'
review: 'quick'
review_source: 'pinned'
lenses_ran: ['external-check']
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/docs/runbooks/content.md'
  - '{project-root}/docs/runbooks/notifications.md'
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/.agents/skills/design-taste-frontend/references/app-screens.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The verify's scenario on staging (publish a pinned and an unpinned SYNTHETIC announcement, one
      with a notice, and read the inbox, job, attempt and push-job rows) is the owner manual check.
    evidence: |-
      Staging has outbound_sending open, push_enabled on and 30 reachable SYNTHETIC members, so a
      real publication with a notice pushes to registered phones within minutes; the agent published
      nothing there. Staging function, constraint, column and registration hashes equal a fresh
      local reset, where the E2E proves the scenario 14/14. Steps with the SQL: content.md, story
      6.13, "Owner manual check on staging"; real-phone receipt is entry 15.
    location: docs/runbooks/content.md
    severity: medium
  - summary: >-
      Publishing with a notice to the 1000-member limit is unmeasured on hosted compute.
    evidence: |-
      Reviewer finding 5: about 1.8-2.0 s locally through api.content_command against the 8 s
      statement timeout; staging has 30 reachable members, so no realistic hosted measurement. A
      larger church or slower host needs the Notifications audience operation recorded in
      notifications.md, story 6.13.
    location: supabase/migrations/20261022011557_content_announcements.sql (app.content_announcement_publish)
    severity: low
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
- [x] `supabase/migrations/20261022011557_content_announcements.sql` -- kind, revisions table and guard, audience helpers, source and reminder checks, contract registration, five commands, public and staff reads, erase part, privileges.
- [x] `supabase/tests/content_announcements_test.sql`; ledgers in `command_foundation_test.sql`; 6.1 test registry asserts scoped to events.
- [x] `tools/identity-e2e/content-announcements.mjs` + `.test.mjs` -- the verify at the API with the worker and push_prepare.
- [x] `packages/contracts/fixtures/v1/notification_key.json` -- an announcement key carries no title or body; regenerate Dart fixtures.
- [x] client_core domain, adapter, controllers, screens, routes, deep link, providers, composition, fakes, exports, Home section; tests `test/content/announcements_test.dart`.
- [x] `apps/mobile/lib/app.dart` (no top bar on announcement screens), `apps/staff/lib/app.dart` (Announcements for Media, Pastor, Admin); app tests.
- [x] `docs/runbooks/content.md`, `notifications.md` (the fan-out gap), `production-promotion-content.md`, `contracts-and-owner-seams.md`.

**Acceptance Criteria:**
- Given the local stack, when the E2E runs, then a pinned and an unpinned SYNTHETIC announcement are published (one with a notice), the anonymous read returns both with the pinned one first, each eligible member gets one inbox item and one job, a member with the category off gets the item and no push job, held, accountless and Pending get no job, and no job, item, receipt or push_prepare message carries the announcement's title or body.
- Given `flutter test`, when run, then a signed-out phone opens Home's announcements and the list (pinned first) and detail, the inbox deep link pattern is known, and staff web shows Announcements to editors only with a publish dialog that previews the generic notice.

## Implementation Notes

- Server in this session; the Dart side (client_core, mobile, staff) by a forked implementation
  agent with this plan and the migration as the wire contract, reviewed here (an unrelated
  formatter hunk in the staff shell's `_RoleSwitch` and a Home doc comment were put back).
- Migration `supabase/migrations/20261022011557_content_announcements.sql` (staging's version; the
  local file was `20261022003000` until applied). It only registers: kind row, five commands, the
  erase part, the `content_announcement` source type, kind and reminder contract. pgTAP
  `content_announcements_test.sql` (137); ledgers: `command_foundation_test.sql` (anon and
  authenticated EXECUTE) and the 6.1 test's registry and privilege asserts scoped to events (later
  kinds no longer break them).
- Fan-out finding: Notifications has no audience operation (`app.notifications_enqueue` takes one
  recipient per logical key), so publish enqueues one job per reachable member in its own
  transaction, at most 1000, paced at 20 a minute (review fix: the worker claims oldest first, 25
  per run, so an unpaced notice held every other reminder back for up to 40 minutes). Recorded in
  `notifications.md`, story 6.13; no Notifications function changed. Measured locally: audience 73
  ms and 1000 enqueues about 2.0 s.
- Recipients use the 3.5 route both at publish and in the reminder check's `recipient_eligible`,
  so held, in-review, unlinked, deactivated and deleted members end `ineligible` with no
  direct-contact need (Content registers no route).
- E2E `tools/identity-e2e/content-announcements.mjs` (14/14,
  `evidence-6.13/content-announcements-e2e.jsonl`) and `.test.mjs` (7). It drives the system route
  with its own `notifications_worker` credential (deliver_due, push_claim, push_prepare,
  push_release) and opens `outbound_sending` and the push switch for its run only, restoring both.
  Numbers +44 7700 900681-900689 (pgTAP uses the same block inside its rolled-back transaction);
  `duties.md` reserved 900670-900689 for 4.8 but only 900670-900679 is used, so its note now says so.
- Contract fixtures: `notification_key.json` gains a valid announcement key and an invalid one
  carrying title, body and pinned (`unknown_field`); `fixtures.g.dart` regenerated; SQL, Dart and
  TypeScript agree.
- Clients: `domain/content_announcements.dart`, `adapters/supabase_announcements_repository.dart`,
  `application/announcement_controllers.dart`, `presentation/announcement_screens.dart` (list,
  detail, Home section), `presentation/staff_announcements_screen.dart`; routes `/announcements`,
  `/announcements/:id` (both apps, so the staff web inbox opens a notice too) and
  `/content/announcements`; the deep-link pattern; one line each in `home_screen.dart`,
  `providers.dart`, `composition.dart`, `supabase_adapters.dart`, `church_client_core.dart`,
  `testing.dart`, `apps/mobile/lib/app.dart` (no top bar on the announcement screens) and
  `apps/staff/lib/app.dart` (Content group).
- Staging: applied right after entry 3's `20261022011438_content_giving_methods` (its own agent);
  hashes in `evidence-6.13/staging-verify.md`.

## Plan Change Log

## Review Triage Log

### 2026-10-22 — Review pass (independent reviewer: the coordinator's external check plus the quick lens)
- verdicts: 12 findings — high 0, medium 6, low 6, false 0, maybe-false 0
- findings:
  - `[medium]` `[patch]` Runbooks not updated (the migration pointed at a notifications.md record that did not exist; no promotion row; seams said events were the only anonymous reads; no content.md section) — written: content.md 6.13, notifications.md 6.13 (the fan-out gap), the promotion row and checks, seams, client-shells.
  - `[medium]` `[defer]` The verify's scenario was not run on staging — staging has push on and the outbound gate open, so a real notice reaches registered phones; recorded as the owner manual check (frontmatter `deferred`), with hash parity and the local E2E as evidence.
  - `[medium]` `[patch]` The regenerated `fixtures.g.dart` was not committed (`fixtures_files_test` would fail on the committed tree) — committed.
  - `[medium]` `[patch]` A large notice held back every other reminder for up to about 40 minutes (all jobs due at once, the worker claims oldest first, 25 per run) — jobs now fall due at `app.content_announcement_pace()` (20) a minute; pgTAP checks the spread.
  - `[low]` `[defer]` Publish time at the 1000 limit is close enough to the 8 s timeout to watch on hosted compute — measured about 2 s locally; recorded in frontmatter `deferred` and notifications.md.
  - `[low]` `[patch]` The publish handler locked the revision row only after Notifications when a withdrawn revision was republished — it now locks the row before the cancel and the enqueues.
  - `[low]` `[patch]` Staff copy said members were notified when a notice is only queued — "Published with a notice", "Notice queued <when> for N members".
  - `[medium]` `[patch]` Publishing a change silently cancels the earlier version's undelivered notices — the publish dialog says so when the live version had a notice.
  - `[medium]` `[patch]` Home's pinned section never re-read (a withdrawn pinned announcement stayed until the list was opened); the detail did not re-read on resume — both now re-read on revisit and on return to the app.
  - `[low]` `[defer]` A hold committing between the announcement check and the worker's own route read could record one `unrouted` direct-contact need (key only) — Notifications-side timing; recorded as a known limit in notifications.md.
  - `[low]` `[patch]` The dialog's preview text was hard-coded in the client — the staff read now serves the registered `notice {title, body}` and the pace; the client shows them.
  - `[low]` `[patch]` `duties.md` reserved 900670-900689 while 6.13 uses 900681-900689 — the note now says 900670-900679 is 4.8's (the only numbers it uses).
- External check verdict: PASS with findings (`evidence-6.13/external-check.md`): no announcement content reaches a push preview, payload, row, receipt, audit or Realtime signal.

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

## Auto Run Result

- **Summary:** Announcements on the 6.1 lifecycle through its registries: title, body and pinned
  per revision; anonymous reads (pinned first); staff web **Announcements** with a publish dialog
  previewing the server's generic notice; mobile Home section, list and detail for everyone; an
  optional notice on publication through the 3.2 source contract to every member the app can
  reach (inbox item always, push when the device and category allow), at most 1000, paced at 20 a
  minute, one per revision, cancelled by a newer revision, withdrawal or archive.
- **Fan-out:** no Notifications audience operation exists; the bounded per-recipient approach is
  built and the gap recorded in notifications.md (no Notifications contract change).
- **Verification:** full pgTAP PASS (59 files, 4627) on a fresh reset; guards 0; E2E 14/14 and
  offline 7/7; contract fixtures SQL 262 cases, Dart 284, TypeScript 267; Flutter design_system
  14, client_core 812, mobile 61, staff 51, analyze clean; check-migrations and scan-secrets pass;
  staging `20261022011557` with the 26 announcement functions, the 24 shared functions it calls,
  the table and the registrations hash-identical to a fresh local reset, guards 0, signed-out HTTP
  reads as expected.
- **Review:** 12 findings, 9 patched, 3 deferred (staging scenario to the owner check, hosted
  publish timing, a Notifications-side race), none rejected.
- **Follow-up review recommended:** true — the pace (scheduled_at spread) and the new staff read
  fields were added after the review; pgTAP and the E2E cover them, no second reviewer has.
- **Residual risks:** the owner's staging walkthrough and real-phone receipt (entry 15) are not
  done; a church larger than 1000 reachable members cannot send a notice until Notifications gains
  an audience operation.
