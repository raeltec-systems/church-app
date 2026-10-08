# Runbook: durable inbox and reminders (epic 3)

Architecture: AD-1, AD-2, AD-8, AD-9, AD-19. Owner decisions: `_bmad-output/initiative-church-app/owner-decisions-milestone-2.md` (Q2: Africa/Lusaka, creator-configured reminders, member snooze, no quiet hours).

## Story 3.1: a synthetic due reminder reaches the durable inbox

Migration: `supabase/migrations/20261008073631_notifications_inbox.sql` (one file; no row deletions, no destructive statements). Evidence: `_bmad-output/initiative-church-app/epic-durable-inbox-and-reminders/evidence-3.1/`.

### What exists

- **Notifications owner tables** (`app`, RLS on, no client privileges):
  - `notifications_jobs`: one row per AD-8 logical key (`source_type, source_id, source_revision, recipient_member_id, reminder_kind, scheduled_at`, unique). It records the source revision and the applied Q2 policy (`policy_source` = `fixture` or `approved`, `policy_digest` = sha256 of the effective `q2_church_time` value; numbered policy versions arrive with entry 3). States: `pending`, `delivered`, `cancelled` (with `cancel_reason`), `obsolete` (the source moved on), `ineligible` (the recipient is no longer an approved member).
  - `notifications_inbox_items`: exactly one row per delivered job (unique `job_id`). It holds the recipient, the reminder kind and the due and delivery times. It holds no source id, no revision and no text.
- **Owner operations** for source owners. Call them inside your own command's transaction; no client can execute them. See [contracts-and-owner-seams.md](contracts-and-owner-seams.md#notifications-owner-operations-story-31).
- **Worker step** `notifications.deliver_due {limit?: 1..100}` (default 50) on the 1.9 system route, purpose `notifications_worker`. In one transaction it:
  1. claims due `pending` jobs, oldest first, with `for update skip locked`;
  2. rechecks each source through its owner's registered hook (`app.contract_check_source`) and the recipient's membership;
  3. writes one inbox item per job.

  It answers counts only: `claimed`, `delivered`, `obsolete`, `ineligible`, `failed`. A job whose recheck raises stays `pending`, is counted `failed`, records `failed_attempts` and `last_failed_at`, writes a content-free log line (`notifications.deliver_due job recheck failed: sqlstate ...`) and backs off min(2^(failures-1), 60) minutes. Jobs with fewer failures are claimed first, so a failing job never blocks later due jobs. Entry 4 replaces this minimal bookkeeping with attempts, leases and the central retry policy. A cancelled, delivered or future job is never touched. Racing runs skip each other's rows, and the unique `job_id` makes a second item impossible.
- **Worker script** `tools/notifications/worker.mjs run-once [--limit n]`: one step over the system route. It holds the `notifications_worker` credential (`NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL`, or `NOTIFICATIONS_WORKER_CREDENTIAL_FILE`) and the publishable key, and no service-role key. It prints one JSON line of counts. Entry 4 replaces it with the Cron-triggered Edge worker with leases, attempts, retries and expiry.
- **Read** `POST /rest/v1/rpc/notifications_my_inbox` (`Content-Profile: api`), behind the 2.1 live-access predicate. It returns `{items: [{item_id, reminder_kind, due_at, delivered_at}], next}`: newest first, in pages of 50. `next` is null on the last page, or `{after_delivered_at, after_item_id}`; pass both values back as the body to read the next older page (one without the other is 400). It records member activity. The clients show **Show older reminders** while a next page exists. A denial is 401/403 like the other private reads, and signed-out callers have no EXECUTE.
- **SYNTHETIC source** `fixture_reminder` (owner: `fixture`, kind `fixture_due`). `POST /rest/v1/rpc/fixture_reminder_command` (1.4 envelope) takes two commands:
  - `fixture.reminder_create {due_at}` (`expected_revision` null) creates a reminder for the caller's own member and enqueues its job in the same transaction.
  - `fixture.reminder_cancel {source_id}` (at the source revision) cancels the source and its pending jobs together.

  Both work only in `local` or `staging`, for a granted SYNTHETIC member. Refusals: `conflict` (stale revision, or `{"source_id": "cancelled"}`), `not_found` (not yours), `unavailable {"policy": "gate_closed"}` (production marker), `forbidden` (no member access).
- **Clients**: an **Inbox** destination (`/inbox`) on mobile (tab) and staff web (sidebar), shown while the server grants member access. Items stay in memory for one account generation. The list is read again when the screen opens, on **Check again** and when the app returns to the foreground. Browser push is not used.

### Gates and known limits

- Enqueue needs the Q2 gate: the labelled fixture in `local` and `staging` (`q2_church_time`; entry 3 moves it to Africa/Lusaka). In production, enqueue answers `unavailable` until the owner approves `q2_church_time`. The system route there also needs `ops_system_access`.
- Until entry 5, the worker delivers only to an `approved` member. Anyone else ends `ineligible` and gets no item (fail closed). Holds, accountless members, the direct-contact route, device tokens and push all arrive later.
- **No deletion hook yet.** After a full deletion these rows keep the member's ids until entry 5 registers the deletion hooks: `app.notifications_jobs.recipient_member_id`, `app.notifications_inbox_items.recipient_member_id`, and the SYNTHETIC `app.fixture_reminder_sources` (`member_id`, `created_by_account`). Entry 5 registers `app.notifications_erase_member`; the fixture source gets a fixture deletion hook (or is cleaned up with the fixture) at the same time. Only synthetic data exists off production, and production scheduling is gated, so this cannot affect real data before entry 5.
- A cancellation that commits after the worker's recheck cannot retract the item (AD-8). Since story 3.2, opening the item re-reads the source and shows the generic superseded state (below).

### Local runs

```bash
npx supabase db reset
npm run -s db:test                       # supabase/tests/notifications_inbox_test.sql
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/inbox.mjs --evidence <file>.jsonl    # real GoTrue, PostgREST, worker script
node tools/auth-harness/local-phone-auth.mjs off
FLUTTER_ROOT=/opt/sdk/flutter bash tools/identity-e2e/live-inbox-check.sh   # real client adapters
node --test tools/notifications/*.test.mjs
```

Each run mints its own local `notifications_worker` credential and registers only the digest. Afterwards it revokes the credential, disables the principal and removes every synthetic row it created. Fictional numbers: pgTAP `+44 7700 900800-900809`, E2E `900810-900819`, live check `900820-900821`.

### Hosted staging (parent session, then the owner)

1. **Parent session:** apply `20261008073631_notifications_inbox.sql` to staging (`tmurpotfluignacfueki`) after `20261007193513`, then run `tools/ci/verify-hosted.sql` with `expected_env=staging`. The file has no row deletion, so there is no `_rows` file to paste. It adds:
   - two Notifications tables and the SYNTHETIC `fixture_reminder_sources`;
   - the `fixture` command authorizer;
   - the dependency edge `fixture -> notifications`;
   - one system command of the new purpose `notifications_worker`;
   - grants for `authenticated` on `api.notifications_my_inbox()` and `api.fixture_reminder_command(jsonb)` only.
2. **Owner (restricted operator): the worker's credential.** The agent never sees it.
   1. Run `OPS_STATE_DIR=.ops-state/notifications-worker node tools/ops/system-credential.mjs mint --env staging`. It prints the digest only. The token stays in that gitignored folder, mode 0600.
   2. In the staging SQL editor (or the connector), run `select app.sys_register_credential(app.sys_create_principal('notifications-worker', 'notifications_worker', 'israel'), '<digest>', 'notifications worker staging', interval '30 days', 'israel');`.
   3. Keep the token only in the worker's environment, for example `NOTIFICATIONS_WORKER_CREDENTIAL_FILE=.ops-state/notifications-worker/staging.credential`. There is no Edge Function and no Edge secret in this story. Entry 4 moves the credential into the Cron worker's server secret store (Supabase Vault). Rotate it before 30 days as described in `system-access-and-operations.md`.
3. **Demonstration** (owner, synthetic members only). Use two seeded SYNTHETIC members A and B (`identity-access.md`, "Seeding a synthetic approved member") and clients built against staging (`--dart-define=SUPABASE_URL=https://tmurpotfluignacfueki.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=<staging publishable key>`).
   1. As A, run the synthetic source command once with A's access token (any HTTP client, or `tools/identity-e2e/inbox.mjs` adapted to the staging origin):
      `POST /rest/v1/rpc/fixture_reminder_command`, header `Content-Profile: api`, body `{"version":1,"command":"fixture.reminder_create","request_id":"<new uuid>","expected_revision":null,"payload":{"due_at":"<now, UTC RFC3339>"}}`.
   2. Run the worker once: `SUPABASE_URL=https://tmurpotfluignacfueki.supabase.co SUPABASE_PUBLISHABLE_KEY=<publishable key> NOTIFICATIONS_WORKER_CREDENTIAL_FILE=.ops-state/notifications-worker/staging.credential node tools/notifications/worker.mjs run-once`. Expect `"delivered":1`.
   3. Mobile as A: **Inbox** shows one **SYNTHETIC test reminder**. Staff web as A: **Inbox** shows the same single item.
   4. Repeat step 1 with the same `request_id` and body: the same answer comes back, and no second job is created. Run step 2 again: `"delivered":0`, and the inbox still shows one item.
   5. Create a second reminder, cancel it (`fixture.reminder_cancel {source_id}` with `expected_revision` 1), then run the worker: `"delivered":0`. The cancelled reminder never appears.
   6. As B: **Inbox** is empty. Signed out: the Inbox entry is gone, and `POST /rest/v1/rpc/notifications_my_inbox` with the publishable key only answers 401.
   7. Clean up the synthetic rows: inbox items, jobs and fixture sources of A and B, then the members as in `identity-access.md`. Revoke the credential afterwards if the run is finished: `select app.sys_revoke_credential('<credential_id>', 'israel');`.
4. **Production:** nothing in this story. Production scheduling waits for the owner's `q2_church_time` approval (entry 10) and `ops_system_access`. The fixture command refuses production by itself.

## Story 3.2: source contracts, generic text and authorised deep links

Migration: `supabase/migrations/20261008090057_notifications_source_contracts.sql` (one file; no row deletions, no destructive statements). Evidence: `_bmad-output/initiative-church-app/epic-durable-inbox-and-reminders/evidence-3.2/`. The owner-facing steps for a new source are the consumer guide in [contracts-and-owner-seams.md](contracts-and-owner-seams.md#reminder-contracts-consumer-guide-story-32).

### What exists

- **Reminder contracts** (`app.contract_reminder_contracts`, platform registry, no client privileges): per source type and reminder kind, the owner's reminder check, fixed generic `title` and `body`, and a deep-link `link` template. Registered only with `app.contract_register_reminder_contract` in the owner's migration. `app.contract_check_reminder(notification_key)` calls the check and refuses any answer other than exactly `{current, revision, actionable, recipient_eligible}`.
- **Enqueue** now also refuses an unregistered source type, a kind without a contract and any extra key on the notification key (`unknown_field`), before anything is written.
- **Worker** (`notifications.deliver_due`) rechecks through the contract: not current or not actionable ends the job `obsolete`; a recipient the source no longer admits, or who is no longer an approved member, ends it `ineligible`. A job whose kind has no reminder contract ends `obsolete` at once (never retried). The answer is still counts only.
- **Inbox read** items now carry the registered generic `title` and `body`: `{item_id, reminder_kind, title, body, due_at, delivered_at}`.
- **Open** `POST /rest/v1/rpc/notifications_open_item` with body `{"item_id": "<uuid>"}` (`Content-Profile: api`), behind the live-access predicate (401/403 like the other reads; a missing id is 400). It re-reads the source now and answers one of:
  - `{item_id, reminder_kind, title, body, due_at, delivered_at, state: "current", target: "/<route>/<source id>"}` when the check says current, actionable and recipient eligible;
  - the same fields with `state: "superseded"` and `target: null` otherwise (stale revision, cancelled, revoked scope, expired, or no contract), with no reason and no source content;
  - `{"state": "not_found"}` for an id that is not one of the caller's items.

  A check that raises or answers malformed makes the open fail with HTTP 503 and the fixed message `source_check_failed` (no detail, no hook name; the server log records only the SQLSTATE) rather than guess a state. It records member activity.
- **SYNTHETIC adapters** on `fixture_reminder` (`POST /rest/v1/rpc/fixture_reminder_command`, local/staging, SYNTHETIC members only):
  - `fixture.reminder_create {due_at, reminder_kind?}`: the optional kind lets the API show that an unregistered kind is refused (`validation_failed {"reminder_kind": "unregistered"}`, nothing written).
  - `fixture.reminder_change {source_id, change}` at the current revision: `revise` (revision + 1, older pending jobs cancelled `source_revised`, a job enqueued at the new revision), `revoke` (the recipient's SYNTHETIC scope is revoked, revision kept, pending jobs cancelled `scope_revoked`) or `expire` (expires now, revision kept, pending jobs cancelled `source_expired`). With the existing `fixture.reminder_cancel` these give the five cases: current, stale revision, cancelled, revoked scope and expired.
- **Clients** (mobile and staff web, shared `client_core`): tapping an inbox item opens `/inbox/<item id>`, which asks the server every time it opens, on **Check again** and on return to the foreground. A current item shows **Open** when this build knows the target route (`ClientPaths.deepLinkTargets`; empty until Duties adds its screen), otherwise "Still current". A superseded item shows "This reminder is out of date" and nothing else. Nothing is stored beyond the screen and the account generation.

### Local runs

```bash
npx supabase db reset
npm run -s db:test                       # supabase/tests/notifications_source_contracts_test.sql (80)
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/source-contracts.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
FLUTTER_ROOT=/opt/sdk/flutter bash tools/identity-e2e/live-inbox-check.sh   # now also opens the item
```

Fictional numbers: pgTAP `+44 7700 900830-900839`, E2E `900840-900849`.

### Hosted staging (parent session, then the owner)

1. **Parent session:** apply `20261008090057_notifications_source_contracts.sql` to staging after `20261008073631`, then run `tools/ci/verify-hosted.sql` with `expected_env=staging`. No `_rows` file. It adds the `contract_reminder_contracts` registry (one row: `fixture_reminder`/`fixture_due`), three columns on the SYNTHETIC `fixture_reminder_sources`, and a grant for `authenticated` on `api.notifications_open_item(uuid)` only. It replaces the enqueue, worker and inbox-read bodies; no privilege on them changes.
2. **Owner demonstration** (synthetic members A and B and the worker credential from story 3.1; clients built against staging as in 3.1):
   1. As A, create five reminders due now (`fixture.reminder_create {"due_at": "<now>"}`) and run the worker once: `"delivered":5`. Mobile **Inbox** shows five **SYNTHETIC test reminder** items with the text "A test reminder is waiting for you.".
   2. Change four of them with A's token (each at `expected_revision` 1): `fixture.reminder_change {"source_id": "<2nd>", "change": "revise"}`, `fixture.reminder_cancel {"source_id": "<3rd>"}`, `fixture.reminder_change {"source_id": "<4th>", "change": "revoke"}`, `fixture.reminder_change {"source_id": "<5th>", "change": "expire"}`.
   3. On mobile and on staff web, open each item. The first shows **Still current**; the other four show **This reminder is out of date** and nothing about the source.
   4. Run the worker again: `"delivered":1` (the revised reminder). Its new item opens as **Still current**.
   5. Through the API, `fixture.reminder_create {"due_at": "<now>", "reminder_kind": "fixture_unknown"}` answers `validation_failed {"reminder_kind": "unregistered"}`, and `{"due_at": "<now>", "body": "x"}` answers `{"body": "unknown_field"}`.
   6. As B, `POST /rest/v1/rpc/notifications_open_item {"item_id": "<A's first item>"}` answers `{"state": "not_found"}`; signed out it answers 401.
   7. Clean up as in story 3.1, step 7.
3. **Production:** nothing. Reminder contracts carry no policy; enqueue stays closed there until `q2_church_time` is approved.

## Story 3.3: church-time reminder schedules

Migration: `supabase/migrations/20261008102121_notifications_scheduling.sql` (one file; no row deletions, no destructive statements). Tests: `supabase/tests/notifications_scheduling_test.sql` (96, table-driven). Source owners follow the consumer guide in [contracts-and-owner-seams.md](contracts-and-owner-seams.md#reminder-schedules-consumer-guide-story-33).

### The policy value (`q2_church_time`)

All tunables live in the value; nothing is a code constant. Local and staging use this labelled TEST FIXTURE: the agent's reading of the owner's Q2 decisions of 2026-10-08, not approved church policy.

```json
{"policy_version": 1, "zone": "Africa/Lusaka", "quiet_hours": null,
 "deadline_bands": [{"min_lead": "30 days", "before_start": "14 days"},
                    {"min_lead": "72 hours", "before_start": "48 hours"},
                    {"min_lead": "0 minutes", "before_start": "24 hours"}],
 "default_reminders": {"response": [{"anchor": "response_deadline", "before": "24 hours"},
                                    {"anchor": "response_deadline", "before": "0 minutes"}],
                       "task": [{"anchor": "deadline", "before": "0 minutes"}]},
 "merge_window": "30 minutes", "snooze_choices": ["1 hour", "24 hours", "2 days"],
 "max_reminders": 6, "max_offset": "90 days"}
```

- **Limits**: `merge_window` is at most 1 day and every band's `before_start` at most `max_offset`.
- **Durations** are `<n> minute(s)|hour(s)|day(s)` with n from 0 to 9999. Whole days move on the church-local calendar (the same local time on another date). Hours and minutes are absolute. Africa/Lusaka is UTC+2 all year.
- **`policy_version`** is a positive integer. Jobs and schedules record it, with the source (`fixture` or `approved`) and the sha256 digest of the value. Give every changed value a higher version.
- **No quiet hours** (owner decision). `quiet_hours` must be present and `null`; a window is refused.
- `app.notifications_policy_errors(value)` returns the field errors of a value (`{}` = valid). Scheduling uses `app.notifications_policy()`. It fails closed with `unavailable {"policy": "gate_closed"}` when the gate is closed (production until approval) or the value is invalid. The server log then records only `q2_church_time is not a valid scheduling policy (source ...)`.

### The calculation

- **Response deadline** (`app.notifications_response_deadline`). The creator's deadline is used as given and refused after the start (`{"response_deadline": "after_start"}`). Otherwise the first band whose `min_lead` fits (start minus assignment) gives start minus `before_start`, never later than the start. With the fixture that means: 30 days or more ahead, 14 days before; 72 hours to 30 days, 48 hours before (so at least 24 hours to respond); more than 24 hours, 24 hours before; otherwise **short notice**. A deadline at or before now is short notice: the effective deadline is now. The answer is never later than the start, even when the start has passed.
- **Plan** (`app.notifications_plan`). It computes the entries from the creator's reminder specs, or from the policy default for the schedule type. Then:
  - entries at or before now are skipped (passed offsets);
  - a fresh short-notice response schedule gets one `respond_now` entry now, once per source revision;
  - entries after `expires_at` are dropped (the default expiry of a response is its start);
  - entries inside `merge_window` of a group's first entry are merged into that one entry, which lists every anchor;
  - a responded assignment has no response-deadline reminders;
  - a Waiting task uses its `review_at` as its deadline.
- **Occurrences** (`app.notifications_occurrences`): a church-local rule `{local_start, every: day|week|month, interval?, exceptions?: [local dates]}` over a window of at most 400 days. A month end clamps from the first date (31 Jan, 28/29 Feb, 31 Mar). The walk starts just before the window however old the rule is; more than 1000 steps is `validation_failed {"window": "out_of_range"}`, never a silent empty list.
- **Snooze** (`app.notifications_snooze_at`): now plus a choice listed in the policy, clamped to the expiry. An expired reminder is refused.

### Schedules and reconciliation

- `app.notifications_schedules` (RLS on, no client privileges): one row per source and recipient. It holds the intent (instants, booleans, enums and reminder specs, no text), the reminder kind per anchor, the last plan and the policy version. States: `active`, `ended` (`app.notifications_cancel` without a kind ended it; with a kind the schedule stays active and records the kind in `cancelled_kinds` until the next revision), `stale` (the source moved past the revision before a re-plan).
- `app.notifications_set_schedule` (source owners, inside their command) stores the intent and reconciles that source and recipient's jobs in the same transaction:
  - a pending job no longer in the plan is cancelled `rescheduled` when it is in the future or belongs to an older revision; a due job at the current revision is left for the worker;
  - a member's pending snooze survives unless the revision moved (then `source_revised`);
  - each entry is enqueued once; a future job cancelled `rescheduled` earlier is reinstated, not duplicated;
  - a merge already sent stays sent: an entry within the merge window after a job of this schedule that is already due or delivered is not enqueued again (`covered`);
  - kinds the source cancelled at this revision are not planned again, and once the intent says `responded`, pending snoozes of response kinds are cancelled (`responded`);
  - nothing at or before now is enqueued, except the one `respond_now`.
- Jobs now record `policy_version`, `expires_at`, `schedule_id` and `snoozed_from_item_id`.
- `app.notifications_snooze_item(member, item, choice)` defers one delivered item for its recipient only. Entry 7 wraps it for the signed-in member. Refusals: `not_found` (not the member's item), `validation_failed {"choice": "invalid"}`, `conflict {"item_id": "superseded"}` (the source moved, was cancelled or no longer admits the member; the schedule ended; the kind was cancelled; or it is a response reminder and the member has responded) and `conflict {"item_id": "expired"}`. A new snooze replaces the item's pending one (`snooze_replaced`).
- **Policy change.** `app.notifications_replan_all(reason)` is operator only. It re-plans every active schedule under the current policy in one transaction and answers counts only: `{policy_version, replanned, stale, failed, enqueued, cancelled}`. Future jobs move. Past-due work is never enqueued, and no second `respond_now` is sent. A schedule whose source moved becomes `stale`; its source re-plans it on its next change. Platform functions may not call Notifications, so `policy_approve` cannot trigger the re-plan: run it right after every approval or fixture change.

### Known limits

- The deletion hook (entry 5) must also cover `app.notifications_schedules.recipient_member_id`, alongside the tables listed under story 3.1.
- The worker (entry 4) does not yet end a job past its `expires_at`. Until then, an expired job that is still pending is rechecked through its source contract as before.
- Q12 must set the reminder-lateness tolerance before release.

### Local runs

```bash
npx supabase db reset
npm run -s db:test          # supabase/tests/notifications_scheduling_test.sql (96)
```

### Hosted staging (parent session)

1. Apply `20261008102121_notifications_scheduling.sql` to staging after `20261008090057`, then run `tools/ci/verify-hosted.sql` with `expected_env=staging`. There is no `_rows` file. The migration:
   - replaces the `q2_church_time` fixture value (UTC to Africa/Lusaka, version 1);
   - adds `notifications_schedules` and four nullable columns on `notifications_jobs`;
   - replaces the bodies of `notifications_enqueue` and `notifications_cancel`, with no privilege change;
   - adds no client grant.
2. Check the fixture: `select app.notifications_policy_errors(fixture_value) from app.policy_gates where gate = 'q2_church_time';` answers `{}`.
3. Run the calculation once as a smoke check, for example `select app.notifications_plan(app.notifications_policy(), 'response', '{"assigned_at": "2026-10-01T08:00:00Z", "starts_at": "2026-11-15T07:00:00Z"}', '2026-10-01T08:00:00Z', true);`. Expect `band` 1, `response_deadline` `2026-11-01T07:00:00.000000Z` and two entries at local 09:00.
4. Re-plan any existing schedules (none yet on staging): `select app.notifications_replan_all('policy_changed');` answers `"replanned": 0`.

### Production (owner, entry 10)

Nothing is scheduled in production until Israel approves `q2_church_time`:

1. Decide the values: confirm or adjust the bands, the default reminders, the merge window and the snooze choices above. Drop `fixture_label` and set `policy_version` to 1.
2. Check the value: `select app.notifications_policy_errors('<value>'::jsonb);` must answer `{}`.
3. Approve it: `select app.policy_approve('q2_church_time', '<value>'::jsonb, 'Israel Muyoba', 'Q2 owner decision <date>');`.
4. Re-plan: `select app.notifications_replan_all('policy_changed');`.
