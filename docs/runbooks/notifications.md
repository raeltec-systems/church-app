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
- Until entry 5, the worker delivers only to an `approved` member. Anyone else ends `ineligible` and gets no item (fail closed). Since story 3.5 recipients are routed by current access (held, deactivated and accountless members go to the source's direct-contact route); see Story 3.5.
- **Deletion hook: since story 3.5** (`app.notifications_erase_member`, and the fixture hook for its sources). Before 3.5, after a full deletion these rows kept the member's ids: `app.notifications_jobs.recipient_member_id`, `app.notifications_inbox_items.recipient_member_id`, and the SYNTHETIC `app.fixture_reminder_sources` (`member_id`, `created_by_account`). Entry 5 registers `app.notifications_erase_member`; the fixture source gets a fixture deletion hook (or is cleaned up with the fixture) at the same time. Only synthetic data exists off production, and production scheduling is gated, so this cannot affect real data before entry 5.
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
   3. Keep the token only in the worker's environment, for example `NOTIFICATIONS_WORKER_CREDENTIAL_FILE=.ops-state/notifications-worker/staging.credential`. There is no Edge Function and no Edge secret in this story. Story 3.4 makes the credential an Edge Function secret of the Cron worker; it never enters the database (see Story 3.4, Hosted staging). Rotate it before 30 days as described in `system-access-and-operations.md`.
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

Migration: `supabase/migrations/20261008121248_notifications_worker.sql` (one file; no row deletions, no destructive statements). Edge Function: `supabase/functions/notifications-worker/` (`index.ts`, `logic.mjs`; `verify_jwt = false` in `supabase/config.toml`). Tests: `supabase/tests/notifications_worker_test.sql` (110), `supabase/functions/notifications-worker/logic.test.mjs`, E2E `tools/identity-e2e/worker.mjs` (17 checks, including a real pg_cron run). Evidence: `_bmad-output/initiative-church-app/epic-durable-inbox-and-reminders/evidence-3.4/`.

### How a job is worked

```
pg_cron (job "notifications-worker")
  -> app.notifications_scheduler_tick()        reads the Vault TRIGGER notifications_worker_trigger
  -> pg_net POST <worker_url> {"action":"run"}  header x-worker-trigger (starts one run, nothing else)
  -> Edge Function notifications-worker         compares the trigger in constant time; holds the
                                                worker's system credential as its own Edge secret
  -> system route notifications.claim           count lapses, expire, lease one batch (fencing tokens)
  -> system route notifications.attempt x n     recheck, then one inbox item / retry / end
  -> system route notifications.release         give back leases left at the run's deadline
```

**Where the secrets live.** The worker's system credential (purpose `notifications_worker`) is only the Edge Function secret `NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL`, set by the owner; it never enters the database, pg_net, Cron or Vault. pg_net carries only the trigger, a random `nwt_<64 hex>` token. The trigger lives in Vault (`notifications_worker_trigger`) and in the Edge secret `NOTIFICATIONS_WORKER_TRIGGER`. While a request waits in `net.http_request_queue` its headers may be readable by other database roles; whoever reads the trigger can only start a run, and a run is idempotent (leases, fencing, one item per job), so an extra run is harmless. A missing or wrong trigger is 401 and starts nothing.

- **Claim** (`notifications.claim {limit?: 1..100}`, at most `batch_max`):
  1. Every lapsed lease whose holder recorded no attempt (the worker crashed, timed out, or lost the answer of an attempt that rolled back) is counted once as a `lapsed` attempt and freed. Lapses count toward `max_attempts` together with failures; at the limit the job ends `obsolete` (`attempts_exhausted`, attempt `exhausted`). A lapse adds no backoff (the lease already delayed the job), so a killed worker's jobs are picked up at once. These are the `reclaimed` count.
  2. Every pending job past its expiry and not under a live lease ends `obsolete` (`finish_reason` `expired`).
  3. Due jobs are leased, fewest failures first, then oldest. Rows another worker holds (`for update skip locked`), jobs under a live lease and jobs still backing off are skipped. Each lease gets a new fencing token from one monotonic sequence and lasts `lease_seconds`.

  Answer: `{jobs: [{job_id, lease_token}], claimed, reclaimed, expired, lease_seconds}`. Every claim writes one content-free row to `app.notifications_worker_runs`.
- **Attempt** (`notifications.attempt {job_id, lease_token}`), in this order:
  1. The token must be the job's current one, held by this principal; otherwise `fenced` and nothing changes.
  2. A job that already ended answers `cancelled` (the source cancelled, re-planned or replaced it after the claim; it is never dispatched) or `finished`.
  3. A lapsed lease is `fenced`; the next claim counts the lapse and reclaims the job.
  4. Past its expiry: `expired` (job `obsolete`, `expired`).
  5. Rechecked now, first failing rule wins:
     - no reminder contract: `obsolete`, `no_contract`;
     - source not current at the job's revision: `obsolete`, `source_changed`;
     - not actionable: `obsolete`, `not_actionable`;
     - the schedule ended, went stale, moved revision or cancelled the kind, or the member responded to a response reminder: `obsolete`, `schedule_changed`;
     - the source no longer admits the recipient: `ineligible`, `recipient_ineligible`;
     - the recipient is no longer an approved member: `ineligible`, `membership_inactive`; since story 3.5 the recipient is routed by current access instead (see Story 3.5: `direct_contact`, `no_direct_contact_route`, `member_deleted`, `membership_inactive`);
     - otherwise the one inbox item: `delivered` (since story 3.5 with one pending member-push job when push is allowed).
  6. If the recheck raises, or a slow owner check is cancelled by the role's statement timeout (SQLSTATE `57014`, caught explicitly), the attempt is `failed`. The job stays pending, counts the failure, releases its lease and backs off `backoff_base_seconds * 2^(failures-1)`, at most `backoff_max_seconds`. When failures plus lapses reach `max_attempts` it ends `obsolete` (`attempts_exhausted`) and the attempt is `exhausted`.

  Every attempt on an existing job writes one row in `app.notifications_attempts`: job, token, principal, request, outcome, finish reason and SQLSTATE only. An unknown job answers `not_found`.
- **Release** (`notifications.release {job_id, lease_token}`): the holder gives back a live lease it will not use. No attempt is counted.
- **One logical outcome.** The inbox item is unique per job, a stale or lapsed token never changes a job, and a cancelled job is never dispatched. An uncertain answer leaves at most a lease to lapse: if the attempt committed, the job is finished; if not, the next claim counts the lapse and reclaims the job. Exactly-once external delivery is not promised (push: story 3.6).
- **`job_state` keeps its 3.1 values**, because widening the CHECK would need DROP CONSTRAINT. `finish_reason` records why a job ended: `delivered`, `expired`, `attempts_exhausted`, `source_changed`, `not_actionable`, `schedule_changed`, `no_contract`, `recipient_ineligible` or `membership_inactive`. Cancelled jobs keep `cancel_reason` (for example `source_cancelled`, `rescheduled`, `snooze_replaced`).
- **`notifications.deliver_due`** (3.1) now runs claim + attempt in one transaction under the same rules, for at most `batch_max` jobs, and answers the same five counts. After a statement-timeout cancel it releases the rest of its batch unused and stops. `tools/notifications/worker.mjs run-once` stays as the operator's manual fallback.

### Central worker policy (`app.notifications_worker_settings`)

| Setting | Default | Bounds |
|---|---|---|
| `lease_seconds` | 120 | 30..900 (the worker stops 15 s before the lease ends: one 10 s call plus a margin) |
| `batch_max` | 25 | 1..100 |
| `max_attempts` (failures plus lapses) | 5 | 1..20 |
| `backoff_base_seconds` / `backoff_max_seconds` | 60 / 3600 (the 3.1 curve: 1, 2, 4 ... 60 minutes) | 1..3600 / 1..86400 |
| `default_ttl_seconds` (expiry of a job without `expires_at`, counted from `scheduled_at`) | 604800 (7 days) | 3600..7776000 |
| `worker_url` | null | local: any `http(s)://<host>/functions/v1/notifications-worker`; staging: exactly `https://tmurpotfluignacfueki.supabase.co/functions/v1/notifications-worker`; production: an `https://<20-letter ref>.supabase.co/...` function (the ref is pinned at entry 10) |

These are operator values, not church policy. Change them as the restricted operator, for example `select app.notifications_configure_worker('{"max_attempts": 4}', 'israel');`. Unknown keys, out-of-bound values and a URL that is not this environment's function are refused. Each change is recorded in `app.ops_operator_actions` (`worker_policy_changed`). **Disable the scheduler before lowering `lease_seconds`** (a run in progress keeps the lease it was given), then enable it again.

### The Edge Function `notifications-worker`

- Call: `POST /functions/v1/notifications-worker` with header `x-worker-trigger: <trigger>` and body `{}` or `{"action": "run", "limit": 1..100}`.
- Secrets (owner-set; never returned or logged): `NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL` (`sysc_<env>_...`) and `NOTIFICATIONS_WORKER_TRIGGER` (`nwt_<64 hex>`). If either is missing or malformed the function answers 503 and does nothing.
- It claims one batch and attempts each job until 50 seconds pass or the lease minus 15 seconds runs out. It releases the jobs left (`deferred`).
- One run at a time per instance (`409 busy`); concurrent instances are kept apart by the leases.
- Answers: `200 {claimed, reclaimed, expired, outcomes: {...}, uncertain, deferred}`; `401` without the right trigger; `403` when the route refuses the credential (unknown, revoked, expired or another purpose); `409` busy; `400` for a bad body; `503` not configured or the route is unreachable.
- It uses the platform-provided `SUPABASE_URL` and `SUPABASE_ANON_KEY` and no service-role key. Its log lines carry counts and outcome codes only.

### Scheduler (pg_cron + pg_net, operator only)

- `app.notifications_scheduler_new_trigger(operator)` generates a new trigger into Vault (`notifications_worker_trigger`), replacing any earlier one. It never returns or logs the value. Recorded as `scheduler_trigger_rotated`.
- `app.notifications_scheduler_enable(operator, every default '1 minute')` creates or replaces this environment's ONE Cron job, `notifications-worker` (`every`: `1 minute` or `<15-59> seconds`). It refuses when another Cron job already runs the tick, when pg_cron is missing, and in production unless `ops_system_access`, `q2_church_time` and `q12_operations` are approved. Recorded as `scheduler_enabled`.
- `app.notifications_scheduler_disable(operator)` removes it (harmless when absent; recorded as `scheduler_disabled` when a job was removed).
- `app.notifications_scheduler_status()` is content-free: environment, whether the gates allow scheduling, the number of scheduler jobs (must be 0 or 1), the schedule, Cron run results in 24 h, whether the URL is set and valid for this environment, whether the trigger is set, the last tick time and outcome (`sent`, `not_configured`, `gate_closed`), the last claim, claims in 24 h, due pending jobs, live leases, attempt outcomes in 24 h and the policy (without the URL).
- The tick (`app.notifications_scheduler_tick()`) answers `not_configured` without a valid URL for this environment or a well-formed trigger. The Cron command text is only `select app.notifications_scheduler_tick()`.
- **Cron history.** pg_cron keeps one `cron.job_run_details` row per run (1440 a day at one minute). Trim it as the database owner, for example weekly: `delete from cron.job_run_details where end_time < now() - interval '7 days';`. This story does not schedule that cleanup.
- The migration enables the `pg_net` and `pg_cron` extensions. It creates no schedule.

### Local runs

```bash
npx supabase db reset
npm run -s db:test                       # supabase/tests/notifications_worker_test.sql (110)
node --test supabase/functions/notifications-worker/logic.test.mjs tools/identity-e2e/worker.test.mjs
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/worker.mjs --evidence <file>.jsonl   # serves the function, runs pg_cron every 15 s
node tools/auth-harness/local-phone-auth.mjs off
```

The E2E mints local credentials and registers only their digests. It generates the trigger with `app.notifications_scheduler_new_trigger`, writes the function's two secrets to a 0600 env file for `supabase functions serve --env-file` (removed afterwards), and removes the Vault trigger, the Cron job and every synthetic row, and restores the default policy. Fictional numbers: pgTAP `+44 7700 900860-900869`, E2E `900870-900879`.

### Hosted staging (parent session, then the owner)

The agent deployed nothing and created no schedule. In order:

1. **Parent session: the migration.** Apply `20261008121248_notifications_worker.sql` to staging (`tmurpotfluignacfueki`) after `20261008102121`, then run `tools/ci/verify-hosted.sql` with `expected_env=staging`. There is no `_rows` file. The migration:
   - enables `pg_net` and `pg_cron` (neither was installed on staging on 2026-10-08);
   - retires `app.ops_operator_actions` by rename to `ops_retired_operator_actions_v2` (rows copied) and recreates it with the scheduler actions;
   - adds the worker policy, attempts, runs and scheduler-state tables, six job columns, the three commands and the operator functions. Any existing `notifications_worker` principal, such as the 3.1 staging one, gets the three commands at once;
   - replaces the bodies of `notifications_sys_deliver_due` and `fixture_reminder_open_check`, and adds `fixture_reminder_sources.check_fault_until`;
   - adds no client grant.

   Check: `select app.notifications_scheduler_status();` answers `"scheduler_jobs": 0`.
2. **Parent session: deploy the function.** Supabase MCP `deploy_edge_function` on `tmurpotfluignacfueki`: name `notifications-worker`, entrypoint `index.ts`, files `supabase/functions/notifications-worker/index.ts` and `logic.mjs`, `verify_jwt: false`. Check: `POST https://tmurpotfluignacfueki.supabase.co/functions/v1/notifications-worker` with body `{}` answers `503 {"outcome":"unavailable"}` until the owner sets the secrets (step 5), then `401` without the trigger.
3. **Parent session: the URL and the trigger.**
   1. `select app.notifications_configure_worker('{"worker_url": "https://tmurpotfluignacfueki.supabase.co/functions/v1/notifications-worker"}', 'israel');`
   2. `select app.notifications_scheduler_new_trigger('israel');` (answers `{"trigger_set": true, ...}`; the value is not shown).
4. **Owner: the worker credential.** The agent and the parent never see it.
   1. Use the 3.1 staging principal `notifications-worker` (it now also holds claim, attempt and release), or create one. Mint a new credential: `OPS_STATE_DIR=.ops-state/notifications-worker node tools/ops/system-credential.mjs mint --env staging --force`. It prints the digest only.
   2. Register the digest in the SQL editor, or hand only the digest to the parent for MCP `execute_sql`: `select app.sys_register_credential((select principal_id from app.sys_principals where name = 'notifications-worker' and environment = 'staging'), '<digest>', 'notifications worker edge staging', interval '30 days', 'israel');`
5. **Owner: the two Edge Function secrets.** Dashboard, project `bic-kafue-platform-test`, **Edge Functions > Secrets** (Project Settings > Edge Functions):
   - `NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL` = the contents of `.ops-state/notifications-worker/staging.credential`;
   - `NOTIFICATIONS_WORKER_TRIGGER` = the value of the Vault secret `notifications_worker_trigger` (**Project Settings > Vault > Secrets**, reveal and copy).

   Do not paste either value into a chat, a ticket or the SQL editor. Then revoke the 3.1 credential if nothing else uses it: `select app.sys_revoke_credential('<old credential_id>', 'israel');`
6. **Parent session: one manual tick, then the schedule.**
   1. Run `select app.notifications_scheduler_tick();` once. It answers `{"tick": "sent"}`; `not_configured` means the URL or the trigger is missing.
   2. After a few seconds, `select app.notifications_scheduler_status();` shows `last_claim_at` set. If it does not, the function answered 401 (the Edge trigger differs from Vault), 403 (credential not registered or revoked) or 503 (a secret is missing); `select status_code from net._http_response order by created desc limit 1;` shows which.
   3. Create the schedule: `select app.notifications_scheduler_enable('israel');` (every minute). `scheduler_jobs` must be 1.
7. **Owner demonstration, with the apps closed.** Use synthetic member A and clients built against staging, as in 3.1.
   1. As A, create a reminder due now (`fixture.reminder_create {"due_at": "<now>"}`), then close both apps. Within about a minute, `app.notifications_scheduler_status()` shows a new claim and `attempts_24h.delivered` grows. Open mobile **Inbox**: one **SYNTHETIC test reminder** is there, and nobody ran a worker.
   2. Transient failure: create a reminder due in 2 minutes, then run `update app.fixture_reminder_sources set check_fault_until = now() + interval '3 minutes' where source_id = '<id>';`. The status shows `attempts_24h.failed`. Once the fault ends and the backoff passes (1, then 2 minutes), the item appears. `select outcome from app.notifications_attempts where job_id = (select job_id from app.notifications_jobs where source_id = '<id>') order by attempted_at;` lists `failed ... delivered`.
   3. Cancelled: create a reminder due in 3 minutes and cancel it (`fixture.reminder_cancel`). It never appears.
   4. The two-worker, killed-worker, stale-token, timeout and lapse cases need control of timing. `tools/identity-e2e/worker.mjs` and the pgTAP suite prove them. To repeat them on staging, use the system route with two staging worker credentials as that script does (claim, move the lease end into the past with `update app.notifications_jobs set lease_expires_at = now() - interval '1 second' where job_id = '<id>';`, claim again, attempt with both tokens).
   5. Clean up as in story 3.1, step 7, deleting the `app.notifications_attempts` rows of those jobs first.
8. **Rotation (owner, every 30 days at most).** Credential: mint with `--force`, register the new digest, replace the Edge secret `NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL`, wait one tick, then revoke the old credential. If it expires, ticks still answer `sent`, the function answers 403 and `last_claim_at` stops moving: rotate. Trigger (any time it may have leaked): `select app.notifications_scheduler_new_trigger('israel');`, then replace the Edge secret `NOTIFICATIONS_WORKER_TRIGGER` with the new Vault value; runs pause (401) between the two steps.
9. **Stop the scheduler** (parent or owner): `select app.notifications_scheduler_disable('israel');`.

### Production

Nothing. The tick and the enable refuse production until `ops_system_access`, `q2_church_time` and `q12_operations` are approved (entry 10). Production then needs its own principal, credential, Edge secrets, trigger, function deploy and `worker_url` (and the production ref pinned in `app.notifications_worker_url_error`).

### Known limits

- Entry 5 routes held and accountless recipients and registers the deletion hook (done in story 3.5; the hook covers `app.notifications_attempts` through their jobs; `app.notifications_worker_runs` holds principal ids only, no member).
- Story 3.6 adds push attempts (`channel` `push`) and their outcomes, and a `push` block in the status (`attempts_24h` now counts inbox attempts only). Entry 8 shows the status in the staff health view.

## Story 3.5: recipients routed by current access; work retired on lifecycle events

Migrations: `supabase/migrations/20261008135811_notifications_routing.sql` (no row deletions; fail-closed stubs) and `supabase/migrations/20261008135900_notifications_routing_rows.sql` (ONLY the two functions that delete rows; applied by hand on hosted projects, like 2.11's rows file). Tests: `supabase/tests/notifications_routing_test.sql` (105), E2E `tools/identity-e2e/routing.mjs` (18 checks). Evidence: `_bmad-output/initiative-church-app/epic-durable-inbox-and-reminders/evidence-3.5/`.

### Routing (at the worker's attempt, after the source and schedule rechecks)

The source's `recipient_eligible` false still ends the job `ineligible` (`recipient_ineligible`). Then the recipient is resolved through CURRENT Identity state (read without locks; AD-2 orders Identity first):

| Recipient now | Inbox item | Member-push job | Direct-contact need | Job ends |
|---|---|---|---|---|
| approved, live link whose account standing is `ok` (active link, approved binding, no open hold, no review) | yes | one `pending` job when the account allows push for the category and has a live token for this member | no | `delivered` |
| approved but held, link in review, or no live link (accountless) | no | no | yes | `ineligible`, `direct_contact` |
| deactivated membership | no | no | yes | `ineligible`, `direct_contact` |
| as above, but the source registered no direct-contact route for the kind | no | no | recorded `unrouted` | `ineligible`, `no_direct_contact_route` |
| deletion tombstone | no | no | no | `ineligible`, `member_deleted` |
| never approved (pending, rejected) | no | no | no | `ineligible`, `membership_inactive` |

- **Needs** (`app.notifications_direct_contact_needs`): one per job, with the notification key, the due time, `route_state` (`routed` or `unrouted`) and the worker principal. Never a contact route: a relative's or household number (Identity contact routes) is never a destination, and the source owner chooses how to contact the member.
- **The source's route.** Notifications hands `{need_id, source_type, source_id, source_revision, recipient_member_id, reminder_kind, scheduled_at}` to the handler registered with `app.contract_register_direct_contact_route` (consumer guide: [contracts-and-owner-seams.md](contracts-and-owner-seams.md#direct-contact-routes-story-35)). It does not say why, so a hold is never disclosed. A raising handler is transient: the attempt is `failed`, nothing is recorded, and the job is retried with backoff.
- The job state keeps its 3.1 values, so the Edge worker's outcomes and `deliver_due`'s five counts are unchanged: routed jobs count as `ineligible`.
- Only the SYNTHETIC `fixture_reminder` source registers a route today (`fixture_reminder_contact_needs`). Duties' **Needs direct contact** list is the first real consumer.
- Dormancy (2.3) is not part of the routing: a dormant but otherwise active account still gets its item, which it sees after its review.

### Device tokens and push settings (members)

`POST /rest/v1/rpc/notifications_command` (`Content-Profile: api`, 1.4 envelope), by a member whose session passes the live-access predicate (a held or in-review account gets `forbidden`):

| Command | `expected_revision` | Payload | Effect |
|---|---|---|---|
| `notifications.register_device` | null | `{token, platform}` (`android` or `ios`) | Registers the token for the caller's account and member. The same token again refreshes the same device (revision + 1). A token live on another account is retired there (`reassigned`). At most 10 live tokens per account: the least recently refreshed is retired (`replaced`). |
| `notifications.retire_device` | device revision | `{device_id}` | Retires the caller's own device (`member_retired`); another account's device is `not_found`; a retired one is `conflict {"device_id": "retired"}`. |
| `notifications.set_push_category` | null to create, the setting's revision to change | `{source_type, reminder_kind, push_enabled}` | Push on or off for one category (a reminder kind with a registered contract; otherwise `validation_failed {"reminder_kind": "unregistered"}`). No setting means on. Turning push off never removes in-app items. |

`POST /rest/v1/rpc/notifications_my_push_settings` returns `{categories: [{source_type, reminder_kind, title, push_enabled, revision}], devices: [{device_id, platform, registered_at, refreshed_at, revision, retired}]}`. No answer or read ever carries a token. Tokens (`app.notifications_device_tokens`) and settings follow the account: member-push work is created only for the member's live linked account. The mobile registration call and push sending are story 3.6 (below); the settings screen is entry 7. Group mutes belong to the conditional chat epic.

### Lifecycle and deletion hooks

- `app.notifications_on_member_lifecycle` is registered for `sessions_revoked`, `access_hold_applied`, `membership_deactivated`, `account_deactivated` and `deletion_requested`. In Identity's transaction it retires the member's live tokens and cancels their pending member-push jobs, with the event name as the reason. `deletion_requested` also cancels the member's pending jobs and ends their active schedules (`member_deleted`). Inbox items stay (a held member sees them again after release). A released hold or a restoration re-registers nothing: the device registers again after sign-in (story 3.6).
- Enqueue and `app.notifications_set_schedule` **skip** a recipient with a deletion tombstone: nothing is written (no job, no schedule written or reactivated) and they answer `{created: false, refused: "member_deleted"}` (enqueue, `job_id` and `job_state` null) or `{schedule_id: null, refused: "member_deleted", ...}` (schedule). They do not raise, so one deleted member never rolls back a source's multi-recipient command. Source owners still drop deleted members through their own lifecycle hooks.
- **Lock order (AD-2).** The worker's attempt and `notifications.register_device` take `FOR KEY SHARE` on the member row before any Notifications lock, and the `deletion_requested` hook skips jobs another transaction holds (`for update skip locked`; the attempt then routes them `member_deleted`), so a deletion, hold or deactivation cannot deadlock with the worker.
- `app.notifications_erase_member` (Identity deletion hook): `erase` removes the member's jobs, their attempts, inbox items, schedules, needs and push jobs, and the account's tokens, settings and push jobs; `check` counts what is left. The fixture deletion hook (`app.fixture_erase_member`, now registered by migration) also erases the member's `fixture_reminder_sources` and `fixture_reminder_contact_needs`, and anonymises the account on reminders the member created for others.
- **Fail closed:** until `20261008135900_notifications_routing_rows.sql` is applied, the two purge functions answer `unavailable` and Identity's `erase_owners` step waits (retried). Requests and every access denial work without it.

### SYNTHETIC fixture additions

`fixture.reminder_create_for {member_id, due_at}` (`expected_revision` null) through `api.fixture_reminder_command`: an Admin creates a reminder for another SYNTHETIC member in any membership state, with or without an account, in `local` or `staging` only. The fixture registers its direct-contact route into `app.fixture_reminder_contact_needs`.

### Local runs

```bash
npx supabase db reset
npm run -s db:test                        # supabase/tests/notifications_routing_test.sql (105)
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/routing.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

Fictional numbers: pgTAP `+44 7700 900880-900888` (the 3.3 suite borrows `900889`), E2E `900890-900899`. The E2E mints its own local `notifications_worker` credential (digest only), uses synthetic device tokens, and removes every row it created.

### Hosted staging (parent session, then the owner)

1. **Parent session:** apply `20261008135811_notifications_routing.sql` to staging after `20261008121248`, then run `tools/ci/verify-hosted.sql` with `expected_env=staging`. It contains no row deletion. It:
   - replaces in place (same signatures and privileges): `app.notifications_attempt`, `app.notifications_enqueue_job`, `app.notifications_set_schedule`, `app.fixture_authorize_command`, `app.fixture_reminder_in_scope`, `app.fixture_reminder_command` (EXECUTE for `authenticated` re-granted) and `app.fixture_erase_member`;
   - adds the direct-contact route registry, four Notifications tables (needs, device tokens, push settings, push jobs) and the fixture's `fixture_reminder_contact_needs`;
   - registers Notifications' five lifecycle hooks, its deletion hook, the fixture deletion hook (if absent) and the `notifications` command authorizer;
   - grants `authenticated` EXECUTE on `api.notifications_command(jsonb)` and `api.notifications_my_push_settings()` (and their `app` entry points) only.
2. **Owner, by hand (staging SQL editor):** apply `20261008135900_notifications_routing_rows.sql`. It replaces two stubs (`app.notifications_deletion_purge_rows(uuid, uuid)`, `app.fixture_deletion_purge_rows(uuid)`). Until then a staging deletion waits at `erase_owners` (`unavailable`) and nothing is erased.
3. **No Edge Function change.** The worker's outcomes are unchanged, so `notifications-worker` needs no redeploy.
4. **Demonstration** (owner, synthetic members only): repeat `tools/identity-e2e/routing.mjs`'s steps against staging with seeded SYNTHETIC members. An Admin places a hold on one member, deactivates another and records an accountless member with a relative's number, then runs `fixture.reminder_create_for` for an active, the held, the deactivated and the accountless member, and the worker once (`"delivered":1, "ineligible":3`). Check in SQL: one inbox item (the active member), three `routed` rows in `app.notifications_direct_contact_needs` and three in `app.fixture_reminder_contact_needs`, nothing for the relative. Then a lost-device hold on a member with a pending push job (device registered through `notifications.register_device` with a synthetic token) shows the token retired and the push job `cancelled`. Clean up as in story 3.1, step 7, plus the new tables.
5. **Production:** nothing new to approve. The fixture command refuses production; routing, tokens and settings work behind the same gates as the rest (Q2 for enqueue, the live-access predicate for members).

## Story 3.6: generic expiring push through FCM; invalid tokens retired

Migration: `supabase/migrations/20261008155801_notifications_push.sql` (one file; no row deletions, no destructive statements, no rows file: push attempts live in `app.notifications_attempts`, which the 3.5 deletion hook already erases). Edge Function: `supabase/functions/notifications-worker/` now has three files, `index.ts`, `logic.mjs` and `fcm.mjs`. Tests: `supabase/tests/notifications_push_test.sql` (96), `supabase/functions/notifications-worker/fcm.test.mjs` and `push-run.test.mjs`, E2E `tools/identity-e2e/push.mjs` (12 checks against a fake FCM endpoint), client tests `packages/client_core/test/notifications/push_test.dart` and the mobile app test. Evidence: `_bmad-output/initiative-church-app/epic-durable-inbox-and-reminders/evidence-3.6/`.

**Push is off until the owner's steps below are done.** Nothing in the repository holds a Firebase project id, app id, API key, service account or APNs key, and the apps ship with the no-op push adapter. The durable inbox and the leaders' direct-contact routes carry every reminder meanwhile.

### How a push is sent

```
worker run (Cron -> Edge Function notifications-worker), after the inbox stage:
  system route notifications.push_claim     count lapsed push leases, expire push jobs, and only
                                            while push_enabled: lease a bounded batch
  for each leased push job:
    notifications.push_prepare              recheck NOW; answer a terminal outcome, or the generic
                                            message and the live devices still owed
    FCM HTTP v1 messages:send x device      OAuth2 access token from the service account (cached)
    notifications.push_record               one attempt row per device answer; retire invalid
                                            tokens; end the push job or retry it with backoff
  notifications.push_release                give back leases left when the run stops early
```

- **Generic and expiring.** Every message is the reminder contract's fixed `title` and `body`, and `data: {"item_id": "<inbox item id>"}`, nothing else. The item id is also the stable notification id: Android `collapse_key` and notification `tag`, APNs `apns-collapse-id`. A retried or duplicated send therefore replaces the notification instead of adding one. The message expires with the push job: Android `ttl` and APNs `apns-expiration`, at most 28 days.
- **Rechecked right before the provider call** (`push_prepare`); the first failing rule wins and the push job ends `obsolete` with that reason. The inbox item is untouched. The rules:
  - past its expiry: `expired`;
  - no reminder contract: `no_contract`;
  - source not current at the job's revision: `source_changed`;
  - not actionable: `not_actionable`;
  - the source no longer admits the recipient: `recipient_ineligible`;
  - the schedule ended, moved or cancelled the kind, or the member responded: `schedule_changed`;
  - the member snoozed the item: `snoozed`;
  - the member no longer routes to the same active linked account: `recipient_changed`;
  - push turned off for the category: `push_disabled`;
  - no live device left: `no_live_token`.

  A raising owner check is transient. Identity's lifecycle hooks (story 3.5) still cancel pending push jobs at once.
- **Provider answers** (`fcm.mjs`), one attempt row each in `app.notifications_attempts` (`channel` `push`, push job, device, HTTP status, FCM error code; never the token or the text):

| FCM answer | Recorded | Effect |
|---|---|---|
| 200 | `accepted` | The provider accepted the message. This is never recorded as delivered, read, responded or consented. |
| 404 `UNREGISTERED`; 400 `INVALID_ARGUMENT` that names the token (a `google.rpc.BadRequest` on the field `message.token`, or FCM's message "The registration token is not a valid FCM registration token") | `token_invalid` | The device is retired (`retire_reason` `provider_invalid`) and is not sent again. |
| Any other 400 (a payload problem), any other 4xx | `rejected` | Not retried for that device, and the token is kept. A payload mistake can never retire every device. |
| 429 / `QUOTA_EXCEEDED` | `transient` | Retried with backoff. The run stops sending and releases the rest of its batch. |
| 5xx, network failure or timeout, APNs `THIRD_PARTY_AUTH_ERROR` | `transient` | Retried with backoff and the same notification id. A lost answer may have been accepted; the collapse id bounds the duplicate. After 3 such answers in one run the run stops sending (`stopped`: `provider_outage`) and releases the rest of its batch, so an outage does not use up every job's attempts. |
| Our own configuration: OAuth refused or unreachable, 401 / 403 on our access token, 403 `SENDER_ID_MISMATCH` (the tokens belong to another Firebase project than the credential) | nothing | No attempt is counted and no token is retired. The job is released and the push stage stops (`stopped`: `oauth_refused`, `oauth_unreachable`, `provider_auth` or `sender_mismatch`). Check the Edge secret and the Firebase project. |

- **Ending a push job** (`push_record`). When no device is owed any more, the job ends:
  - `accepted` when at least one device accepted it;
  - `failed` (`provider_rejected`) when every device rejected it;
  - `obsolete` (`no_live_token`) when every token was invalid.

  A transient answer counts a failure and backs off with the worker's central policy. Failures plus lapses reaching `max_attempts` end the job: `accepted` if some device accepted it, otherwise `failed`, both with finish reason `attempts_exhausted`. A retry sends only to the devices still owed.
- **Leases and fencing** work as for jobs (story 3.4): the same token sequence and settings. The function stops sending 25 seconds before its lease ends (one provider call plus one record call plus a margin; `stopped`: `lease_budget`). It records what it sent and releases the rest, so another worker never re-sends under a newer lease while this one is still sending. A worker that dies after the provider call leaves a lease to lapse. The next claim counts it once (`lapsed`) and sends again with the same notification id. The dead worker's late record is `fenced` and changes nothing about the push job, but its `token_invalid` answers still retire those devices.
- **No token at rest outside the token table.** `push_prepare`'s answer is the only one that carries device tokens. Its kind is registered with `retain_result = false`, so the kernel keeps only `{request_id, retained: false}` in `app.sys_receipts` and a replay is a `conflict`. Function logs, worker answers and the status carry counts and codes only.
- **The switch** `push_enabled` (worker settings, default `false`). Turn it on or off as the restricted operator: `select app.notifications_configure_worker('{"push_enabled": true}', 'israel');`. With it off the claim leases nothing. With no service account secret the function makes an expire-only claim (`notifications.push_claim {"expire_only": true}`). Either way pending push jobs still expire and lapsed push leases are counted. The inbox is unaffected. It is also the kill switch.
- **Status** (`app.notifications_scheduler_status()`): `push: {enabled, pending, leased, ended_24h, attempts_24h, tokens_retired_24h}`. The top-level `attempts_24h` counts inbox attempts only.
- **Edge Function answer**: the 200 body gains `push`. It is `{claimed, reclaimed, expired, enabled, outcomes, sent, uncertain, deferred, stopped?}`, or `{state: "not_configured", reclaimed, expired}` without the FCM secret, or `{state: "unavailable"}`.

### Clients (shared `client_core`, mobile)

- **Port** `PushMessaging` (`lib/src/domain/push_messaging.dart`): permission, token, token refreshes, taps, launch tap and delete token. The default `NoPushMessaging` is used by every build without the Firebase defines; `apps/mobile/lib/push/` holds the real `FirebasePushMessaging` (step 6 below).
- **`PushRegistrationController`**:
  - once the server grants member access, it asks the person once (the operating system dialog) and registers the token with `notifications.register_device`;
  - it registers again when the provider refreshes the token;
  - before **Sign out** it retires the device (`notifications.retire_device`, at most 5 s) and deletes the token at the provider.

  A denial registers nothing, and every reminder is still in the inbox. The device id and revision are kept in memory only.
- **`PushBridge`** (mobile app root): a tapped notification, or the one that launched the app, opens `/inbox/<item id>`. Only a well-formed id is accepted. That screen asks the server every time (story 3.2).
  - Signed out, it offers **Sign in**. After sign-in the person returns to the item: `/sign-in?then=/inbox/<id>`, and `then` accepts nothing but an inbox item path.
  - A superseded or foreign item shows nothing about the source.

### Local runs

```bash
npx supabase db reset
npm run -s db:test                     # supabase/tests/notifications_push_test.sql (96)
node --test supabase/functions/notifications-worker/*.test.mjs tools/identity-e2e/push.test.mjs
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/push.mjs --evidence <file>.jsonl   # fake FCM + supabase functions serve
node tools/auth-harness/local-phone-auth.mjs off
```

The E2E generates a throwaway RSA key pair and a Firebase-shaped service account for the run (never stored) and starts a fake FCM endpoint on the host. The fake's OAuth endpoint verifies the RS256 assertion; its send endpoint answers per device token as scripted. The run points the function at the fake with `NOTIFICATIONS_FCM_TEST_ENDPOINT`, which the function honours only when `SUPABASE_URL` is plain http, so never on a hosted project. Fictional numbers: pgTAP `+44 7700 900900-900909`, E2E `900910-900919`. The installed AOSP emulator is not push evidence (no Google Play services).

### Hosted staging (parent session, then the owner)

Steps 1 and 2 were done by the parent session on 2026-10-08 (evidence: `evidence-3.6/staging-verify.md`). The agent holds no Firebase or Apple credential. In order:

1. **Parent session: the migration.** Apply `20261008155801_notifications_push.sql` to staging (`tmurpotfluignacfueki`) after `20261008135811`, then run `tools/ci/verify-hosted.sql` with `expected_env=staging`. There is no rows file. The migration:
   - adds `app.sys_command_kinds.retain_result` and replaces the body of `app.sys_execute` (same signature and grants);
   - adds the `push_enabled` setting (off), the push-job lease columns, the attempt push columns and the four `notifications.push_*` commands, which the existing staging `notifications_worker` principal gets at once;
   - replaces `app.notifications_configure_worker` and `app.notifications_scheduler_status` in place;
   - adds no client grant.

   Check: `select app.notifications_scheduler_status() -> 'push';` answers `"enabled": false`.
2. **Parent session: redeploy the function.** Supabase MCP `deploy_edge_function` on `tmurpotfluignacfueki`:
   - name `notifications-worker`, entrypoint `index.ts`, `verify_jwt: false`;
   - files `supabase/functions/notifications-worker/index.ts`, `logic.mjs` and **`fcm.mjs`** (new).

   Until step 4 the answer's `push` is `{"state":"not_configured", ...}` (push jobs only expire) and inbox delivery is unchanged.
3. **Owner: the Firebase project** ([Firebase console](https://console.firebase.google.com)):
   1. **Add project**, for example `bic-kafue-staging`. Google Analytics is not needed. Use a separate project for production later.
   2. **Project settings > General > Your apps > Add app > Android**: package name `zm.bickafue.bic_kafue_mobile`. Download `google-services.json` but **do not commit it**. Keep it in your password manager; the client follow-up below needs four values from it.
   3. **Add app > Apple (iOS)**: bundle ID `zm.bickafue.bicKafueMobile`. Download `GoogleService-Info.plist` and keep it, also uncommitted.
   4. **Project settings > Cloud Messaging**: check that **Firebase Cloud Messaging API (V1)** shows *Enabled*. The legacy API is not used.
4. **Owner: the sending credential** (a narrowly scoped service account):
   1. [Google Cloud console](https://console.cloud.google.com) for the same project: **IAM & Admin > Service Accounts > Create service account**, name `bic-push-sender`, role **Firebase Cloud Messaging API Admin** (`roles/firebasecloudmessaging.admin`) only. The default `firebase-adminsdk` account also works, but it holds far more rights.
   2. On the new account: **Keys > Add key > Create new key > JSON**. A file downloads.
   3. Supabase dashboard, project `bic-kafue-platform-test`: **Edge Functions > Secrets > Add new secret**, name `NOTIFICATIONS_FCM_SERVICE_ACCOUNT`, value = the whole JSON file, or its base64: `base64 -w0 key.json` (Linux) or `base64 -i key.json` (macOS). Or from your own terminal: `npx supabase secrets set --project-ref tmurpotfluignacfueki NOTIFICATIONS_FCM_SERVICE_ACCOUNT="$(base64 -w0 key.json)"`.
   4. Delete the downloaded file. Never paste the key into a chat, a ticket, the SQL editor or the repository.
   5. The next worker run answers `push: {"enabled": false, ...}` instead of `not_configured`.
5. **Owner: iOS delivery (APNs)**. Needed only for iPhones; Android works without it.
   1. [Apple Developer](https://developer.apple.com/account) > **Certificates, Identifiers & Profiles > Identifiers**: open `zm.bickafue.bicKafueMobile` (create it if missing) and tick **Push Notifications**.
   2. **Keys > +**: name `BIC Kafue APNs`, tick **Apple Push Notifications service (APNs)**, then Continue and Register. Download the `.p8` file; it can be downloaded only once. Note the **Key ID** and your **Team ID** (top right of the page).
   3. Firebase console > **Project settings > Cloud Messaging > Apple app configuration > APNs Authentication Key > Upload**: the `.p8`, Key ID and Team ID. Keep the `.p8` in your password manager.
6. **Client build with push** (done in code 2026-10-08; the owner builds it). `apps/mobile` has pinned `firebase_core` 4.15.0 and `firebase_messaging` 16.7.0 and the `FirebasePushMessaging` adapter (`apps/mobile/lib/push/`). It needs only the non-secret app identifiers from step 3, passed at build time and **never committed**:

   | `--dart-define` | From |
   |---|---|
   | `FIREBASE_PROJECT_ID` | `google-services.json` `project_info.project_id` |
   | `FIREBASE_SENDER_ID` | `project_info.project_number` |
   | `FIREBASE_API_KEY` | `client[0].api_key[0].current_key` |
   | `FIREBASE_ANDROID_APP_ID` | `client[0].client_info.mobilesdk_app_id` |
   | `FIREBASE_IOS_APP_ID` (optional) | `GoogleService-Info.plist` `GOOGLE_APP_ID` |

   ```bash
   cd apps/mobile
   flutter build apk --release --target-platform android-arm64 \
     --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=... \
     --dart-define=FIREBASE_PROJECT_ID=... --dart-define=FIREBASE_SENDER_ID=... \
     --dart-define=FIREBASE_API_KEY=... --dart-define=FIREBASE_ANDROID_APP_ID=...
   ```

   - Without all four Android values (or if Firebase fails to start) the app keeps the no-op adapter: nothing is asked or registered.
   - With them, `main.dart` overrides `pushMessagingProvider`. Once the server grants member access the app asks for notifications (Android 13+ `POST_NOTIFICATIONS`), registers the token, re-registers on token refresh, and retires it before **Sign out**. A tap opens `/inbox/<item_id>` (sign-in first when needed). A message that arrives while the app is open is not shown; the inbox only re-reads.
   - Android: the Gradle build turns the same four defines into Firebase's string resources (`google_app_id`, `gcm_defaultSenderId`, `google_api_key`, `project_id`), so no `google-services.json` or Google services plugin is used and Firebase also starts when a push wakes a closed app. The default notification channel `reminders` ("Reminders") is created at process start.
   - iOS (owner, in Xcode, once the APNs key of step 5 exists): open `apps/mobile/ios/Runner.xcworkspace` > target Runner > **Signing & Capabilities > + Capability > Push Notifications** (this creates `Runner.entitlements` with `aps-environment`). Background Modes > Remote notifications is already in `Info.plist`. Build with `FIREBASE_IOS_APP_ID` as well. Not done in the repository because a provisioning profile without the Push capability would break signing.
7. **Parent or owner: turn push on for staging** once a device build exists: `select app.notifications_configure_worker('{"push_enabled": true}', 'israel');`.
8. **Owner: the real-device check** (the ticket's verify line). Use a real Android phone with Google Play services, and an iPhone where available, with the build from step 6 signed in as a SYNTHETIC member. Allow notifications when asked.
   1. Close the app (swipe it away). Create a reminder due now for that member (`fixture.reminder_create`, or an Admin's `fixture.reminder_create_for`). Within about a minute a notification shows **SYNTHETIC test reminder / A test reminder is waiting for you.** and nothing else.
   2. Tap it: the app opens **Reminder** for that item, after sign-in if the session has ended, and shows **Still current**.
   3. Denied push: on a second phone or member, deny notifications. A new reminder arrives in **Inbox** and no notification shows. `app.notifications_push_jobs` has no row for it.
   4. Invalid token: uninstall the app on one registered phone, create a reminder and wait one run. `select retire_reason from app.notifications_device_tokens where member_id = '<member>' order by refreshed_at desc;` shows `provider_invalid` for that device. FCM may need some time to report an uninstalled app as unregistered.
   5. Retry with the same notification id. FCM rarely answers a transient error on demand, so the retry itself is proven by the local E2E (`push.mjs` P30: a 503 and then acceptance, both carrying the same item id as collapse id) and by pgTAP. On staging:
      - Airplane mode is not a provider failure. With the phone in airplane mode for a few minutes, FCM accepts the message and holds it; the phone shows ONE notification when it reconnects, and the attempt is `accepted` only.
      - If `select outcome, provider_code from app.notifications_attempts where channel = 'push' and outcome = 'transient';` ever lists rows, each push job's next attempt follows after the backoff, and the phone still shows one notification.
   6. Nothing shows as delivered or read: `select distinct outcome from app.notifications_attempts where channel = 'push';` lists only provider outcomes (`accepted`, `token_invalid`, `rejected`, `transient`, `lapsed`, ...).
9. **Rotation** (service account key, at least yearly or when a person leaves):
   1. Create a new JSON key on `bic-push-sender`.
   2. Replace the Edge secret.
   3. Wait for one run that shows `push.sent.accepted`.
   4. Delete the old key under **Keys**.
10. **Stop push** at any time: `push_enabled` false (above). For a full stop, also delete the Edge secret `NOTIFICATIONS_FCM_SERVICE_ACCOUNT`.

### Production

Nothing yet. Production needs its own Firebase project and service account, its own APNs upload (the same `.p8` may serve both), its own Edge secret, the client build with production identifiers, and `push_enabled` set by the owner after the entry 10 gates.

### Known limits and follow-ups

- **Client wiring.** The real `firebase_messaging` adapter exists (step 6 above); a build without the Firebase defines registers nothing. Not yet checked on a real device (step 8).
- **Sign-out elsewhere.** A device retires its own registration when the person signs out in the app. A session that ends any other way (expiry, revocation by `sessions_revoked`) is covered by the 3.5 lifecycle hooks only for the events they listen to. A plain session expiry leaves the token registered until the next sign-in on that phone; pushes stay generic and every open re-checks the session.
- **Foreground display.** A message arriving while the app is open is not shown (the SDK default on Android and iOS); it only makes an open inbox re-read. The settings screen (push categories) is entry 7, and the staff health view of the `push` status is entry 8.

## Story 3.7: the inbox, notification settings and snooze on mobile and staff web

Migration: `supabase/migrations/20261008183514_notifications_inbox_screens.sql` (one file; no row deletions, no destructive statements, no rows file). Tests: `supabase/tests/notifications_inbox_screens_test.sql`, E2E `tools/identity-e2e/inbox-screens.mjs` (real GoTrue, PostgREST, worker script and **Realtime**, with the captured signal frames), the live adapter check `tools/identity-e2e/live-inbox-check.sh` (steps L11-L18 drive the real Dart `SupabaseInboxSignals` on the private channel), client tests `packages/client_core/test/notifications/inbox_screens_test.dart` and both app tests. Evidence: `_bmad-output/initiative-church-app/epic-durable-inbox-and-reminders/evidence-3.7/`.

### Server contract (additions)

- **Markers.** `api.notifications_my_inbox` items gain `opened` (the member opened the item in the app, on any device; set once by `api.notifications_open_item`) and `snoozed_until` (the member's pending snooze of the item, or null). Neither says anything about push delivery or reading; the clients label them **New** and **Opened** only.
- **Open.** `api.notifications_open_item` marks the item opened on the first open and, for a `current` item only, adds `snooze_choices` (from the Q2 policy; `[]` when the policy is unavailable, for example the production gate closed) and `snoozed_until`. The `superseded` and `not_found` answers are unchanged.
- **Snooze.** `notifications.snooze_item {item_id, choice}` on `api.notifications_command` (`expected_revision` null). It wraps the 3.3 owner operation: current source only, a policy choice (`1 hour`, `24 hours`, `2 days`), clamped to the reminder's expiry, replaces an earlier pending snooze of the same item, and only this member's copy moves. Answer `{item_id, scheduled_at, clamped, expires_at}` at the item's new revision. Refusals: unknown choice `validation_failed {"choice": "invalid"}`, another member's item `not_found`, `conflict {"item_id": "superseded"}` (answered, cancelled, changed, or no longer theirs), `conflict {"item_id": "expired"}`. A response, cancellation or revision of the source cancels the pending snooze (`responded` or the source's reason) and the item then opens out of date.
- **Refresh signal (AD-5).** After an inbox item is added, opened or snoozed, or a snooze job starts or ends, the database publishes ONE Realtime Broadcast per account per transaction: topic `account:<auth user id>`, event `inbox_changed`, payload `{}`, private. No ids, text or source type (captured in `evidence-3.7/inbox-screens-e2e.jsonl`, S20 and S60). Only a recipient whose current route is `member` is signalled; a rolled back change sends nothing; without Realtime nothing is sent and nothing fails. Channel authorisation is one receive-only RLS policy on `realtime.messages`, `notifications_account_refresh_receive` (`authenticated`, broadcast, own topic only); there is no insert policy, so clients cannot send. On hosted Supabase, `postgres` may create it through `supautils.policy_grants` (checked on staging 2026-10-08).
- **SYNTHETIC categories stay out of production.** `app.notifications_category_offered(module)` hides the `fixture` module's categories outside `local` and `staging` (an unmarked database counts as production): `api.notifications_my_push_settings` does not list them and `notifications.set_push_category` answers `validation_failed {"reminder_kind": "unregistered"}` for them.
- **SYNTHETIC fixture** (local/staging only): reminder kind `fixture_reply` (contract and direct-contact route), `fixture.reminder_schedule {starts_at}` (a request starting at `starts_at`, with a response schedule from the 3.3 calculation: short notice, one `respond_now` reminder due now, expiring at the start) and `fixture.reminder_respond {source_id}` at the source revision (the member answers).

### Clients (shared `client_core`, both apps)

- **Inbox** (`/inbox`, the **Inbox** tab once the server grants member access): **New** / **Opened** / **Snoozed until ...** labels; loading, empty, denial and failure states, each recoverable with **Check again**; pull to refresh. While it is open and the app is visible it re-reads on open, on resume, on every `inbox_changed` signal and on every (re)join of the channel (`SupabaseInboxSignals`, private channel), and every 2 minutes, so a missed signal or a project without Realtime still converges. In the background the channel is left and the poll stops; coming back re-reads. A re-read after **Show older reminders** puts the new first page in front of the older pages already shown (deduplicated); a change inside the older range shows after **Check again** from the top. A failed re-read keeps the list shown with **Couldn't check for new reminders**; it never blanks it.
- **Reminder** (`/inbox/<id>`): a current item shows **Remind me later** with the policy's choices. The answer is shown as the server gave it: **Snoozed until ...**, clamped ("it comes back at that time instead"), **out of date**, **ended**, or **We don't know yet** with **Try again** (same `request_id`). Signed out, **Sign in** returns to the item (`/sign-in?then=/inbox/<id>`); the server checks it again.
- **Notification settings** (`/notification-settings`, from the Inbox): one switch per registered category (`notifications.set_push_category` at the shown revision; a conflict reloads and says so). Every row says the Inbox keeps the reminders. Mobile says whether this phone is registered; staff web says the website shows no notifications (browser push is not used) and the settings apply to phones.
- **SYNTHETIC test reminders** (`/fixture/reminders`, from the **Fixture** tab, **SYNTHETIC test reminders**): **Send me a test reminder** (due now), **Send me a test request (starts in 20 h)**, and on the last one **Answer it** / **Cancel it**. A test reminder's **Open** leads to `/fixture/reminders/<id>` with the same two actions. The server refuses all of it in production.

### Local runs

```bash
npx supabase db reset
npm run -s db:test                     # supabase/tests/notifications_inbox_screens_test.sql
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/inbox-screens.mjs --evidence <file>.jsonl   # needs Realtime running
node tools/auth-harness/local-phone-auth.mjs off
npx supabase db reset && FLUTTER_ROOT=/opt/sdk/flutter bash tools/identity-e2e/live-inbox-check.sh
```

Start the stack with Realtime (do not pass `-x realtime`). Fictional numbers: E2E `+44 7700 900930-900939`; live check `900820-900821` (shared with 3.1).

### Hosted staging (parent session, then the owner)

1. **Parent session: the migration.** Apply `20261008183514_notifications_inbox_screens.sql` to staging (`tmurpotfluignacfueki`) after `20261008155801`, then run `tools/ci/verify-hosted.sql` with `expected_env=staging`. No rows file and no Edge Function change (the worker's outcomes are unchanged). It:
   - adds `opened_at` and `snooze_revision` to `app.notifications_inbox_items`, and `responded_at` to `app.fixture_reminder_sources`;
   - replaces in place (same signatures and grants): `app.notifications_my_inbox`, `app.notifications_open_item`, `app.notifications_authorize_command`, `app.notifications_command_in_scope`, `app.notifications_command`, `app.fixture_reminder_open_check`, `app.fixture_authorize_command`, `app.fixture_reminder_command`;
   - adds the publisher, four triggers, the fixture `fixture_reply` contract and commands, and the receive-only policy on `realtime.messages`; no new client grant.

   Checks: `select polname from pg_policy where polrelid = 'realtime.messages'::regclass;` lists `notifications_account_refresh_receive` (outside `local` the migration raises a WARNING if `realtime.messages` is missing; then the policy was not created, the signal cannot work and clients rely on polling); `select app.notifications_scheduler_status() ->> 'scheduler_jobs';` is `1` (the 3.4 Cron worker delivers within a minute).

   **Realtime setting (owner, dashboard):** project **Realtime > Settings**, keep **Allow public access** OFF, so only private (RLS-checked) channels can be joined. If it were on, another client could still not read `account:<uid>` broadcasts (they are published `private`), but turning it off removes public channels as a class; the payload is `{}` either way, so nothing private would leak.

   **Prerequisite (done 2026-10-08):** the staging worker credential and Edge secrets are set and the every-minute schedule is on (`evidence-3.4/staging-verify.md`).
2. **Owner: builds against staging.** Publishable key only, from the dashboard (**Project Settings > API Keys**):
   - Android phone: `cd apps/mobile && flutter build apk --debug --dart-define=SUPABASE_URL=https://tmurpotfluignacfueki.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=<staging publishable key>`, then `adb install -r build/app/outputs/flutter-apk/app-debug.apk` (or copy the APK to the phone).
   - Staff web: `cd apps/staff && flutter build web --no-web-resources-cdn --dart-define=SUPABASE_URL=https://tmurpotfluignacfueki.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=<staging publishable key>`, served as in `client-shells.md`.
   - Sign in on both as the same SYNTHETIC approved member (seeded as in `identity-access.md`), and keep a second SYNTHETIC member B for the isolation check.

### Owner manual checks (phone and web, story 3.7)

Use synthetic members only. Push to the phone needs the 3.6 Firebase steps; without them every check below still holds through the Inbox.

1. **Reach it.** Phone: the **Inbox** tab is in the bottom bar after sign-in. Web: **Inbox** in the sidebar. Both show the same items.
2. **Create test reminders.** Phone: **Fixture** tab > **SYNTHETIC test reminders** > **Send me a test reminder**. Within about a minute the phone's open Inbox shows **SYNTHETIC test reminder** labelled **New** without touching it (the signal), and so does the web Inbox. If it does not appear within 2 minutes, pull down (phone) or **Check again** (web): it must appear then (the fallback).
3. **Open marks Opened, on both clients.** Tap the item on the phone: **Reminder** shows **Open**. Back in the Inbox it is **Opened**; the web Inbox shows **Opened** too within seconds (or after **Check again**). Nothing anywhere says delivered, seen or read.
4. **Follow it.** **Open** leads to **SYNTHETIC test source**.
5. **Snooze.** On the item, **Remind me later > 24 hours**: **Snoozed until <tomorrow, this time>**; the Inbox shows **Snoozed until ...**. Choose **1 hour** to replace it.
6. **Clamp.** **Send me a test request (starts in 20 h)**; open **SYNTHETIC reply reminder** when it arrives and choose **2 days**: the answer says it comes back at the start time instead (about 20 hours from now), not in 2 days.
7. **A response removes the snooze.** On that request, **Open > Answer it**. Back in the Inbox the **Snoozed until** label is gone; opening the reminder says **This reminder is out of date**. Repeat step 5 with a new test reminder and **Cancel it**: same result.
8. **Push off keeps in-app items.** Inbox > **Notification settings**: turn **SYNTHETIC test reminder** off (**Saved**; "Still in your Inbox"). Send another test reminder: it appears in the Inbox (with push wired, no phone notification for it). Turn it on again. The web shows the same switches.
9. **Deep link after sign-in.** On the web, copy the address of an opened reminder (`.../inbox/<id>`), sign out, paste it: **Not signed in** with **Sign in**; after signing in the same reminder opens and is checked again. As member B, the same address shows **This reminder isn't available**.
10. **Signal payload (optional, web).** Browser developer tools > Network > WS > the `realtime/v1/websocket` connection > Messages: after step 2, the `broadcast` frame for `inbox_changed` has `"payload":{}` (Realtime may add a `meta.id` of its own) and no item id, text or source type.
11. **Clean up** as in story 3.1, step 7, deleting snooze jobs first: `delete from app.notifications_jobs where snoozed_from_item_id in (select item_id from app.notifications_inbox_items where recipient_member_id in (<members>));` (after their attempts).

Record the outcome per step in `evidence-3.7/owner-device-check.md` (pass/fail, device model, Android version, browser; no numbers, ids or keys).

### Known limits

- The signal is a hint: Realtime gives no delivery guarantee, so the clients poll every 2 minutes while the Inbox is open and re-read on resume and on every channel rejoin.
- Push categories cover registered reminder kinds only; group mutes stay with the conditional chat epic. Staff web never shows notifications.
- A snooze is offered only on a current item with policy choices. In production the choices stay empty until the owner approves `q2_church_time` (entry 10).
