---
title: 'Show the inbox, notification settings and snooze on mobile and staff web'
type: 'feature'
ticket: '7'
created: '2026-10-08'
status: 'built'
baseline_revision: '5db8b266ebaaed7cc690a318df528e524b9642b0'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/notifications.md'
  - '{project-root}/docs/runbooks/client-shells.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Members can list and open inbox items (3.1, 3.2), but cannot tell new from opened items, cannot snooze, have no push-settings screen, and an open inbox only re-reads on open, resume or **Check again** (N6).

**Approach:** Extend the existing reads and `notifications_command` (no new client-executable function): opened/snoozed markers on items, `notifications.snooze_item` wrapping 3.3's `app.notifications_snooze_item`, and a server-published per-account Realtime broadcast with an empty payload. Shared `client_core` screens serve both clients: inbox markers, a snooze action, a notification-settings screen and signal-driven re-reads.

**Decisions (agent, under owner pre-approval, 2026-10-08):**
- Refresh signal = Realtime Broadcast from the database on a private per-account channel (see Design Notes). AD-5 requires channel authorisation, which on Supabase is an RLS SELECT policy on `realtime.messages`; adding that one policy is accepted as the narrow exception to "no custom objects in realtime" (no table, function or INSERT policy there), like Identity's triggers on `auth.users`. Clients also poll every 2 minutes while the inbox is open, so a project without Realtime still converges.
- Unread/opened = whether the member opened the item in the app (server `opened_at`, set on first open). Labels "New" and "Opened"; no "delivered", "seen" or "read".
- Snooze is a member command (`notifications.snooze_item`, `expected_revision` null; the item's revision bumps). A response is shown with SYNTHETIC fixture commands `fixture.reminder_schedule {starts_at}` and `fixture.reminder_respond {source_id}` (local/staging only) over the real 3.3 schedule path; the fixture check stops being actionable once responded.
- Settings live at `/notification-settings`, linked from the Inbox on both clients; staff web shows the same categories (push reaches phones only; browser push is not used).
- Decision (agent, under owner pre-approval, resumed build): so the owner can verify on a real phone without other tools, the existing SYNTHETIC **Fixture** tab links to `/fixture/reminders` (create a due-now reminder, a 20-hour request, answer, cancel through the existing fixture commands, refused in production), and the fixture contract link `/fixture/reminders/<uuid>` is registered as a known deep-link target so **Open** can be followed. Reversible: remove the route and the pattern.
- Decision (agent, under owner pre-approval, resumed build): an item from a server without markers (`opened` absent) shows no marker rather than "New", so a client ahead of the migration never makes an unread claim.

## Boundaries & Constraints

**Always:** server decides every state; markers say only what the app did ("New" = not opened in the app, "Opened" = opened in the app), never push delivery or reading; snooze choices come from the policy (1 hour, 24 hours, 2 days); a snooze is clamped to the source expiry and dies with a response, a cancellation or a revision; push off never removes in-app items; signal payload `{}` with event `inbox_changed` on topic `account:<own auth uid>`, published only to a recipient whose route is `member`, after commit; every signal, resume and reconnect causes a fresh authorised read; protected state memory-only per account generation (AD-13); hosted migration rules (no DROP/TRUNCATE/`delete from`, ASCII, search_path, no anon grants).

**Never:** browser push; ids, text or source types in a signal payload; client INSERT on `realtime.messages`; new tables or functions in `realtime`; editing hand-pasted staging functions; staging changes or deployments.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Open marks opened | first open of own item | `opened: true` in list; signal sent once | not own item: `not_found`, nothing marked |
| Snooze | current item, `24 hours` | `{scheduled_at, clamped:false, expires_at}`; list shows snoozed until | unknown choice `validation_failed`; foreign `not_found` |
| Snooze past expiry | `2 days`, source starts in 20 h | `clamped: true`, at the expiry; client says it could not be later | expired: `conflict {"item_id":"expired"}` |
| Response / cancel | member responds or source cancelled | pending snooze cancelled (`responded` / source reason); `snoozed_until` null; open = out of date | snooze again: `conflict superseded` |
| Push off | category off, new reminder | item in inbox, no push job | stale revision: `conflict`, Reload |
| Signal | item delivered/opened/snoozed/snooze ended | one `inbox_changed` `{}` per account per transaction | Realtime absent: no error, clients still re-read on open/resume/poll |
| Foreign channel | B joins `account:<A>` | join refused (RLS) | client keeps working without signals |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261008073631_notifications_inbox.sql`, `20261008090057_notifications_source_contracts.sql` (`app.notifications_my_inbox`, `app.notifications_open_item`, fixture check/create/command), `20261008102121_notifications_scheduling.sql` (`app.notifications_snooze_item`, `set_schedule`, `snooze_at`), `20261008135811_notifications_routing.sql` (`notifications_command`, authorizer, in_scope, `notifications_recipient_route`, push settings, fixture command/authorizer) -- replace in place with identical signatures.
- `packages/client_core/lib/src/{domain/inbox.dart,application/inbox_controllers.dart,presentation/inbox_screen.dart,adapters/supabase_inbox_repository.dart}`, `lib/testing.dart` (`FakeInbox`, `ClientTestHarness`), `lib/composition.dart`, `shell_routing.dart` (`ClientPaths`, `signInThen`/`continuationFrom` already return to `/inbox/<id>` after sign-in).
- `apps/mobile/lib/app.dart`, `apps/staff/lib/app.dart` and their tests.
- Tests asserting exact inbox key sets: `supabase/tests/notifications_inbox_test.sql:227`; superseded open key set stays unchanged.
- Built (resumed run): `lib/src/domain/notification_settings.dart` (categories, `InboxSignals` port), `lib/src/adapters/supabase_notification_settings.dart` (settings read, private Realtime channel adapter), `lib/src/application/{inbox_controllers.dart (inboxLiveProvider, SnoozeController),notification_settings_controllers.dart,fixture_reminder_controller.dart}`, `lib/src/presentation/{inbox_screen.dart,notification_settings_screen.dart,fixture_reminder_screens.dart}`, `tool/live_inbox_check.dart` + `tools/identity-e2e/live-inbox-check.sh` (L11-L18).

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261008181657_notifications_inbox_screens.sql` -- inbox items gain `opened_at`, `revision`; list adds `opened`, `snoozed_until`; open marks opened and (current only) adds `snooze_choices`, `snoozed_until`; `notifications.snooze_item {item_id, choice}`; refresh publisher triggers + receive-only policy on `realtime.messages` (guarded); fixture `reminder_schedule`/`reminder_respond` and `fixture_response` contract -- N6 server parts.
- [x] `supabase/tests/notifications_inbox_screens_test.sql` (+ update `notifications_inbox_test.sql` key set) -- markers, snooze, clamp, response/cancel, push off, signal payload capture, privileges.
- [x] `tools/identity-e2e/inbox-screens.mjs` (+ `.test.mjs`) -- real GoTrue/PostgREST/Realtime: signal frame capture, foreign join refused, snooze/clamp/response/cancel, push off.
- [x] `client_core` domain/adapters/controllers/screens -- `InboxSignals` port + Supabase adapter, settings repository, snooze and push-category controllers, markers, settings screen, route `/notification-settings`; fakes in `testing.dart`; tests.
- [x] apps mobile/staff -- link to settings; app tests for both clients.
- [x] `docs/runbooks/notifications.md` -- story 3.7 section with owner checks.
- [x] SYNTHETIC test reminders screen (`/fixture/reminders`, `/fixture/reminders/<id>`) linked from the Fixture tab -- the owner's phone check needs no other tool.
- [x] `tools/identity-e2e/live-inbox-check.sh` / `packages/client_core/tool/live_inbox_check.dart` -- the real Dart adapters on the local stack, including the private Realtime channel.

**Acceptance Criteria:**
- Given a signed-out person opening `/inbox/<id>` on either client, when they sign in, then they land on that item and the server rechecks it.
- Given an open inbox, when the server signals `inbox_changed`, then the list is re-read without user action.

## Implementation Notes

- Resumed from `wip/3.7-wip.patch` (server, pgTAP, E2E). Verified as found: migration sorts after `20261008155801`, ASCII, every function pins `search_path`, no anon grant, no DROP/TRUNCATE/`delete from`. Hosted compatibility read-only on staging (2026-10-08): `realtime.messages` is owned by `supabase_realtime_admin`, `postgres` has BYPASSRLS and `supautils.policy_grants` lists `realtime.messages`, so the guarded `create policy` and the definer insert work there as locally. Staging policy offers `1 hour, 24 hours, 2 days`.
- Added one pgTAP case (57 now): the member command on an expired reminder answers `conflict {"item_id": "expired"}` and writes nothing (the matrix row's error column).
- Clients: `InboxSignals` port; `SupabaseInboxSignals` joins `account:<auth uid>` as a private channel and emits on every broadcast and every (re)join; `inboxLiveProvider` (watched by the Inbox screen only) re-reads on each emission and every 2 minutes; pull to refresh. Snooze, settings and fixture commands keep the request for an identical resend after an unknown outcome.
- Staging finding: the 3.4 Cron worker is not scheduled yet (`scheduler_jobs` 0, no claim ever); the runbook lists it as a prerequisite of the phone check, with the manual `worker.mjs run-once` fallback.

- Review fixes (2026-10-08): SYNTHETIC `fixture` categories hidden from `notifications_my_push_settings` and refused by `set_push_category` outside local/staging (`app.notifications_category_offered`, both replaced in place in the 3.7 migration); publisher checks the per-member transaction cache before routing and runs wholly inside its exception block; a WARNING outside `local` when `realtime.messages` is missing; inbox re-reads merge the first page in front of loaded older pages, a failed re-read keeps the list (`refreshFailed`), a refresh requested during **Show older** runs after it; the channel and poll stop while the app is hidden. pgTAP now 65 (fixture commands refused for a non-SYNTHETIC member and in production; production hides/refuses SYNTHETIC categories); client tests for each.

## Owner checks (phone and web)

Exact steps: `docs/runbooks/notifications.md`, story 3.7, "Hosted staging" and "Owner manual checks" (11 steps: reach, signal, Opened on both, follow, snooze, clamp, response/cancel, push off, deep link after sign-in, captured payload in the browser, clean up). Prerequisites: parent applies `20261008181657` to staging; owner/parent finish story 3.4 staging steps 4-6 (or run the worker by hand); owner builds the APK and staff web against staging with the publishable key.

## Design Notes

Refresh signal decision: Realtime Broadcast from the database on a private channel (works on hosted Supabase; spike confirmed locally). A SECURITY DEFINER publisher inserts `{topic: 'account:'||uid, event: 'inbox_changed', payload: '{}', private: true}` into `realtime.messages` (not `realtime.send`, which injects an `id` into the payload), once per account per transaction, inside a subtransaction that swallows failures (Realtime absent, no partition). One SELECT policy for `authenticated` (`extension = 'broadcast'` and topic = own `account:<uid>`), created only if `realtime.messages` exists; no INSERT policy, so clients cannot send. Fallback: clients re-read on open, resume, reconnect and every 2 minutes while the inbox is open.

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- all pass
- `node tools/identity-e2e/inbox-screens.mjs --evidence <f>` (Realtime running) -- all checks pass; all E2Es in e2e-main.sh pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff`; `node --test tools/**/*.test.mjs`; `npm run -s contracts:test`; scan-secrets; check-migrations -- pass
- `npx supabase db reset && FLUTTER_ROOT=/opt/sdk/flutter bash tools/identity-e2e/live-inbox-check.sh` -- L1-L18 pass (real Dart adapters, private Realtime channel)
