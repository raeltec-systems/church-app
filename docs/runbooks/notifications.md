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

  It answers counts only: `claimed`, `delivered`, `obsolete`, `ineligible`, `failed`. A job whose recheck raises stays `pending`, is counted `failed`, records `failed_attempts` and `last_failed_at`, writes a content-free log line (`notifications.deliver_due job recheck failed: sqlstate ...`) and backs off min(2^(failures-1), 60) minutes. Jobs with fewer failures are claimed first, so a failing job never blocks later due jobs. Since story 3.4 the step is claim + attempt in one transaction under the central worker policy (leases, attempts, retry limit, expiry); see Story 3.4. A cancelled, delivered or future job is never touched. Racing runs skip each other's rows, and the unique `job_id` makes a second item impossible.
- **Worker script** `tools/notifications/worker.mjs run-once [--limit n]`: one step over the system route. It holds the `notifications_worker` credential (`NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL`, or `NOTIFICATIONS_WORKER_CREDENTIAL_FILE`) and the publishable key, and no service-role key. It prints one JSON line of counts. Since story 3.4 it is the operator's manual fallback; the Cron-triggered Edge worker `notifications-worker` does the scheduled work.
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
   3. Keep the token only in the worker's environment, for example `NOTIFICATIONS_WORKER_CREDENTIAL_FILE=.ops-state/notifications-worker/staging.credential`. There is no Edge Function and no Edge secret in this story. Story 3.4 moves the credential into Supabase Vault for the Cron worker (see Story 3.4, Hosted staging). Rotate it before 30 days as described in `system-access-and-operations.md`.
3. **Demonstration** (owner, synthetic members only). Use two seeded SYNTHETIC members A and B (`identity-access.md`, "Seeding a synthetic approved member") and clients built against staging (`--dart-define=SUPABASE_URL=https://tmurpotfluignacfueki.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=<staging publishable key>`).
   1. As A, run the synthetic source command once with A's access token (any HTTP client, or `tools/identity-e2e/inbox.mjs` adapted to the staging origin):
      `POST /rest/v1/rpc/fixture_reminder_command`, header `Content-Profile: api`, body `{"version":1,"command":"fixture.reminder_create","request_id":"<new uuid>","expected_revision":null,"payload":{"due_at":"<now, UTC RFC3339>"}}`.
   2. Run the worker once: `SUPABASE_URL=https://tmurpotfluignacfueki.supabase.co SUPABASE_PUBLISHABLE_KEY=<publishable key> NOTIFICATIONS_WORKER_CREDENTIAL_FILE=.ops-state/notifications-worker/staging.credential node tools/notifications/worker.mjs run-once`. Expect `"delivered":1`.
   3. Mobile as A: **Inbox** shows one **SYNTHETIC test reminder**. Staff web as A: **Inbox** shows the same single item.
   4. Repeat step 1 with the same `request_id` and body: the same answer comes back, and no second job is created. Run step 2 again: `"delivered":0`, and the inbox still shows one item.
   5. Create a second reminder, cancel it (`fixture.reminder_cancel {source_id}` with `expected_revision` 1), then run the worker: `"delivered":0`. The cancelled reminder never appears.
   6. As B: **Inbox** is empty. Signed out: the Inbox entry is gone, and `POST /rest/v1/rpc/notifications_my_inbox` with the publishable key only answers 401.
   7. Clean up the synthetic rows: inbox items, worker attempts (since story 3.4), jobs and fixture sources of A and B, then the members as in `identity-access.md`. Revoke the credential afterwards if the run is finished: `select app.sys_revoke_credential('<credential_id>', 'israel');`.
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
- Since story 3.4 the worker ends a pending job past its `expires_at` (or past `scheduled_at` plus the central default expiry) `obsolete` with `finish_reason` `expired`.
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

## Story 3.4: the leased and fenced worker, Cron and the Edge Function

Migration: `supabase/migrations/20261008121500_notifications_worker.sql` (one file; no row deletions, no destructive statements). Edge Function: `supabase/functions/notifications-worker/` (`index.ts`, `logic.mjs`; `verify_jwt = false` in `supabase/config.toml`). Tests: `supabase/tests/notifications_worker_test.sql` (83), `supabase/functions/notifications-worker/logic.test.mjs`, E2E `tools/identity-e2e/worker.mjs` (15 checks, including a real pg_cron run). Evidence: `_bmad-output/initiative-church-app/epic-durable-inbox-and-reminders/evidence-3.4/`.

### How a job is worked

```
pg_cron (job "notifications-worker")
  -> app.notifications_scheduler_tick()        reads Vault secret notifications_worker_credential
  -> pg_net POST <worker_url> {"action":"run"}  header x-system-credential (never stored elsewhere)
  -> Edge Function notifications-worker         forwards the credential; holds none of its own
  -> system route notifications.claim           one batch, leases + fencing tokens
  -> system route notifications.attempt x n     recheck, then one inbox item / retry / end
```

- **Claim** (`notifications.claim {limit?: 1..100}`, at most `batch_max`):
  - first it ends every pending job past its expiry that is not under a live lease (`obsolete`, `finish_reason` `expired`);
  - then it leases due jobs, fewest failures first, then oldest. It skips rows another worker holds (`for update skip locked`), jobs under a live lease and jobs still backing off;
  - each lease gets a new fencing token from one monotonic sequence and lasts `lease_seconds`. A lapsed lease (a worker that died) is reclaimed with a higher token (`reclaimed`);
  - answer: `{jobs: [{job_id, lease_token}], claimed, reclaimed, expired, lease_seconds}`. Every claim writes one content-free row to `app.notifications_worker_runs`.
- **Attempt** (`notifications.attempt {job_id, lease_token}`), in this order:
  1. The token must be the job's current one, held by this principal; otherwise `fenced` and nothing changes.
  2. A job that already ended answers `cancelled` (the source cancelled it after the claim; it is never dispatched) or `finished`.
  3. A lapsed lease is `fenced`; the next claim reclaims the job.
  4. Past its expiry: `expired` (job `obsolete`, `expired`).
  5. Rechecked now, first failing rule wins:
     - no reminder contract: `obsolete`, `no_contract`;
     - source not current at the job's revision: `obsolete`, `source_changed`;
     - not actionable: `obsolete`, `not_actionable`;
     - the schedule ended, went stale, moved revision or cancelled the kind, or the member responded to a response reminder: `obsolete`, `schedule_changed`;
     - the source no longer admits the recipient: `ineligible`, `recipient_ineligible`;
     - the recipient is no longer an approved member: `ineligible`, `membership_inactive`;
     - otherwise the one inbox item: `delivered`.
  6. If the recheck raises, the attempt is `failed`. The job stays pending, counts the failure, releases its lease and backs off `backoff_base_seconds * 2^(failures-1)`, at most `backoff_max_seconds`. At `max_attempts` it ends `obsolete` (`attempts_exhausted`) and the attempt is `exhausted`.

  Every attempt on an existing job writes one row in `app.notifications_attempts`: job, token, principal, request, outcome, finish reason and SQLSTATE only. An unknown job answers `not_found`.
- **One logical outcome.** The inbox item is unique per job, a stale or lapsed token never changes a job, and a cancelled job is never dispatched. If the Edge Function loses an answer, at most a lease is left to lapse: the next claim reclaims the job, and if the attempt had committed the job is already finished. Exactly-once external delivery is not promised (push arrives in entry 6).
- **`job_state` keeps its 3.1 values**, because widening the CHECK would need DROP CONSTRAINT. `finish_reason` records why a job ended: `delivered`, `expired`, `attempts_exhausted`, `source_changed`, `not_actionable`, `schedule_changed`, `no_contract`, `recipient_ineligible` or `membership_inactive`. Cancelled jobs keep `cancel_reason`.
- **`notifications.deliver_due`** (3.1) now runs claim + attempt in one transaction under the same rules and answers the same five counts. `tools/notifications/worker.mjs run-once` stays as the operator's manual fallback.

### Central worker policy (`app.notifications_worker_settings`)

| Setting | Default | Bounds |
|---|---|---|
| `lease_seconds` | 120 | 5..900 |
| `batch_max` | 25 | 1..100 |
| `max_attempts` | 5 | 1..20 |
| `backoff_base_seconds` / `backoff_max_seconds` | 60 / 3600 (the 3.1 curve: 1, 2, 4 ... 60 minutes) | 1..3600 / 1..86400 |
| `default_ttl_seconds` (expiry of a job without `expires_at`, counted from `scheduled_at`) | 604800 (7 days) | 3600..7776000 |
| `worker_url` | null | `https://<host>/functions/v1/notifications-worker` |

These are operator values, not church policy. Change them as the restricted operator, for example `select app.notifications_configure_worker('{"max_attempts": 4}', 'israel');`. Unknown keys and out-of-bound values are refused.

### The Edge Function `notifications-worker`

- Call: `POST /functions/v1/notifications-worker` with header `x-system-credential: <notifications_worker credential>` and body `{}` or `{"action": "run", "limit": 1..100}`.
- It claims one batch and attempts each job until 50 seconds pass or the lease (minus 5 seconds) runs out. Jobs left are counted `deferred` and their leases lapse.
- Answers: `200 {claimed, reclaimed, expired, outcomes: {...}, uncertain, deferred}`; `401` without a well-formed credential; `403` when the route refuses it (unknown, revoked, expired or another purpose); `400` for a bad body; `503` when the route is unreachable.
- It uses only the platform-provided `SUPABASE_URL` and `SUPABASE_ANON_KEY`: no secret of its own and no service-role key. Its log lines carry counts and outcome codes only.

### Scheduler (pg_cron + pg_net, operator only)

- `app.notifications_scheduler_enable(operator, every default '1 minute')` creates or replaces this environment's ONE Cron job, `notifications-worker` (`every`: `1 minute` or `<1-59> seconds`). It refuses when another Cron job already runs the tick, when pg_cron is missing, and in production unless `ops_system_access`, `q2_church_time` and `q12_operations` are approved.
- `app.notifications_scheduler_disable(operator)` removes it (harmless when absent).
- `app.notifications_scheduler_status()` is content-free: environment, whether the gates allow scheduling, the number of scheduler jobs (must be 0 or 1), the schedule, Cron run results in 24 h, whether the URL is set, the last tick time and outcome (`sent`, `not_configured`, `gate_closed`), the last claim, claims in 24 h, due pending jobs, live leases, attempt outcomes in 24 h and the policy (without the URL).
- The tick (`app.notifications_scheduler_tick()`) reads the credential from Vault at run time and sends it in a header with pg_net. The Cron command text is only `select app.notifications_scheduler_tick()`. pg_net keeps the outgoing request, with its headers, in `net.http_request_queue` only until it is sent; only the database owner can read it.
- The migration enables the `pg_net` and `pg_cron` extensions. It creates no schedule.

### Local runs

```bash
npx supabase db reset
npm run -s db:test                       # supabase/tests/notifications_worker_test.sql (83)
node --test supabase/functions/notifications-worker/logic.test.mjs tools/identity-e2e/worker.test.mjs
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/worker.mjs --evidence <file>.jsonl   # serves the function, runs pg_cron every 5 s
node tools/auth-harness/local-phone-auth.mjs off
```

The E2E mints local credentials and registers only their digests. It stores one as the local Vault secret for the Cron run, then removes it, the Cron job and every synthetic row, and restores the default policy. Fictional numbers: pgTAP `+44 7700 900860-900869`, E2E `900870-900879`.

### Hosted staging (parent session, then the owner)

The agent deployed nothing and created no schedule. In order:

1. **Parent session: the migration.** Apply `20261008121500_notifications_worker.sql` to staging (`tmurpotfluignacfueki`) after `20261008102121`, then run `tools/ci/verify-hosted.sql` with `expected_env=staging`. There is no `_rows` file. The migration:
   - enables `pg_net` and `pg_cron` (neither was installed on staging on 2026-10-08);
   - adds the worker policy, attempts, runs and scheduler-state tables, five job columns, the two commands and the operator functions. Any existing `notifications_worker` principal, such as the 3.1 staging one, gets the two commands at once;
   - replaces the bodies of `notifications_sys_deliver_due` and `fixture_reminder_open_check`, and adds `fixture_reminder_sources.check_fault_until`;
   - adds no client grant.

   Check: `select app.notifications_scheduler_status();` answers `"scheduler_jobs": 0`.
2. **Parent session: deploy the function.** Supabase MCP `deploy_edge_function` on `tmurpotfluignacfueki`: name `notifications-worker`, entrypoint `index.ts`, files `supabase/functions/notifications-worker/index.ts` and `logic.mjs`, `verify_jwt: false`. No Edge secret is needed. Check: `POST https://tmurpotfluignacfueki.supabase.co/functions/v1/notifications-worker` with body `{}` and no credential answers `401 {"outcome":"unauthenticated"}`.
3. **Parent session: the URL** (not a secret): `select app.notifications_configure_worker('{"worker_url": "https://tmurpotfluignacfueki.supabase.co/functions/v1/notifications-worker"}', 'israel');`
4. **Owner: the worker credential in Vault.** The agent and the parent never see it.
   1. Use the 3.1 staging principal `notifications-worker` (it now also holds claim and attempt), or create one. Mint a new credential: `OPS_STATE_DIR=.ops-state/notifications-worker node tools/ops/system-credential.mjs mint --env staging --force`. It prints the digest only.
   2. Register the digest in the SQL editor, or hand only the digest to the parent for MCP `execute_sql`: `select app.sys_register_credential((select principal_id from app.sys_principals where name = 'notifications-worker' and environment = 'staging'), '<digest>', 'notifications worker cron staging', interval '30 days', 'israel');`
   3. Store the token in Vault: Dashboard, project `bic-kafue-platform-test`, **Project Settings > Vault > Secrets > Add new secret**. Name: `notifications_worker_credential`. Value: the contents of `.ops-state/notifications-worker/staging.credential`. Do not paste it into a chat, a ticket or the SQL editor history.
   4. Revoke the 3.1 credential if nothing else uses it: `select app.sys_revoke_credential('<old credential_id>', 'israel');`
5. **Parent session: one manual tick, then the schedule.**
   1. Run `select app.notifications_scheduler_tick();` once. It answers `{"tick": "sent"}`; `not_configured` means the URL or the Vault secret is missing or malformed.
   2. After a few seconds, `select app.notifications_scheduler_status();` shows `last_claim_at` set.
   3. Create the schedule: `select app.notifications_scheduler_enable('israel');` (every minute). `scheduler_jobs` must be 1.
6. **Owner demonstration, with the apps closed.** Use synthetic member A and clients built against staging, as in 3.1.
   1. As A, create a reminder due now (`fixture.reminder_create {"due_at": "<now>"}`), then close both apps. Within about a minute, `app.notifications_scheduler_status()` shows a new claim and `attempts_24h.delivered` grows. Open mobile **Inbox**: one **SYNTHETIC test reminder** is there, and nobody ran a worker.
   2. Transient failure: create a reminder due in 2 minutes, then run `update app.fixture_reminder_sources set check_fault_until = now() + interval '3 minutes' where source_id = '<id>';`. The status shows `attempts_24h.failed`. Once the fault ends and the backoff passes (1, then 2 minutes), the item appears. `select outcome from app.notifications_attempts where job_id = (select job_id from app.notifications_jobs where source_id = '<id>') order by attempted_at;` lists `failed ... delivered`.
   3. Cancelled: create a reminder due in 3 minutes and cancel it (`fixture.reminder_cancel`). It never appears.
   4. The two-worker, killed-worker and stale-token cases need control of timing. `tools/identity-e2e/worker.mjs` and the pgTAP suite prove them. To repeat them on staging, use the system route with two staging worker credentials exactly as that script does: shorten the lease with `select app.notifications_configure_worker('{"lease_seconds": 5}', 'israel');`, claim, wait it out, claim again, attempt with both tokens, then restore `lease_seconds` 120.
   5. Clean up as in story 3.1, step 7, deleting the `app.notifications_attempts` rows of those jobs first.
7. **Rotation (owner, every 30 days at most).** Mint with `--force`, register the new digest, update the Vault secret's value in the Dashboard (same name), wait one tick, then revoke the old credential. If the credential expires, ticks still answer `sent`, but the function answers 403 and `last_claim_at` stops moving: rotate.
8. **Stop the scheduler** (parent or owner): `select app.notifications_scheduler_disable('israel');`.

### Production

Nothing. The tick and the enable refuse production until `ops_system_access`, `q2_church_time` and `q12_operations` are approved (entry 10). Production then needs its own principal, credential, Vault secret, function deploy and `worker_url`.

### Known limits

- Entry 5 routes held and accountless recipients and registers the deletion hook. It must also cover `app.notifications_attempts` (job ids only) and `app.notifications_worker_runs` (principal ids only).
- Entry 6 adds push attempts (`channel` `push`) and their outcomes. Entry 8 shows the status in the staff health view.
