# Runbook: promote Duties and Follow-ups to the production baseline (story 4.15)

Status: **prepared, not executed.** Nothing in this file has run against production. The owner
(Israel) merges PR #6 into `main` and runs **promote** himself, only after epic 4 is complete
(owner decision 2026-10-15). This file is what the owner and the restricted operator do **after**
that promotion for Duties and Follow-ups. It does not repeat the identity package: follow
[production-promotion-identity.md](production-promotion-identity.md) for the database step, the
Auth settings, the Edge Functions, the clients and the identity gates G1-G11, and come back here
for the epic 3 and epic 4 approvals and the pilot department.

Related: [duties.md](duties.md) (story 4.15 at the end: the closing suite),
[follow-ups.md](follow-ups.md), [notifications.md](notifications.md) (stories 3.3, 3.4, 3.10),
[system-access-and-operations.md](system-access-and-operations.md),
[environments-and-promotion.md](environments-and-promotion.md). Staging evidence:
`_bmad-output/initiative-church-app/epic-duties-coverage-and-follow-ups/evidence-4.15/`.

## What production shows before any approval (the deployed, visibly disabled baseline)

Duties and Follow-ups are deployed with every other workflow, and stay closed until their gates
are approved. While a gate is unapproved, production must show exactly this:

| Gate unapproved | Server answer | What the clients show |
|---|---|---|
| `q4_personal_data` (G5) | Every Duties and Follow-ups read answers `403 unavailable`; every command answers `unavailable {"policy": "gate_closed"}` and writes nothing (`app.identity_applications_open()` is false). No department can be created, so no pilot names can be entered. Leaders' contact routes are never returned. | **Not available yet** on My duties, Duties, Rota, Coverage, Departments and My follow-ups (mobile and staff web). The Home cards show nothing to do. |
| `q2_church_time` (with Q4 open) | Follow-ups stays closed as a whole: `app.followups_reminders_ready()` is false, so its reads answer `403 unavailable` and its commands `unavailable` (story 4.7, "approve Q4 only together with or after Q2"). Duties reminders are skipped and audited `reminders_skipped` (`policy_unavailable`); nothing is enqueued. | My follow-ups: **Not available yet**. Duties work, but no reminder reaches anyone. |
| `ops_system_access`, `q2_church_time` or `q12_operations` | `app.notifications_scheduler_enable` and the tick refuse production; no Cron job exists (`scheduler_jobs: 0`); the Edge worker answers `503` without its secrets. `tools/ci/verify-hosted.sql` fails a promotion that finds a scheduler job while any of the three is closed. | Nothing is delivered: the inbox stays empty; staff web **Reminder health** shows the scheduler as not configured. |
| `identity_deletion_retention` (G6) | A deletion request still ends access at once; the erase step (Duties and Follow-ups anonymisation included) waits `policy_gate_closed`. | Staff web **Member deletions** shows `accepting: false`. |
| No first real Admin (G8) | Nothing can be approved, no department created. | No Admin destinations on staff web. |

No migration of epic 4 approves anything. There are no fixture values in production: the labelled
TEST FIXTURE rows (the Q2 policy, the deletion retention) are honoured only in databases marked
`local` or `staging`.

## Ordered steps after promotion

Prerequisites: the identity package steps 1-5 are done (database, Auth with sign-up closed, the
Edge Functions `identity-assisted-recovery`, `identity-deletion` and `notifications-worker`, which
the promote workflow deploys with `--no-verify-jwt` since story 3.10, clients built), and the verification in step 7 of that file
passed. Every SQL statement below runs once, as the restricted operator, in the production SQL
editor. Record each owner decision note verbatim.

### 1. Scheduling and reminders: `q2_church_time`, `q12_operations`, `ops_system_access` (owner-approved 2026-10-13/14)

1. **`q2_church_time`.** Take the staging fixture value (`select fixture_value from
   app.policy_gates where gate = 'q2_church_time';` on staging), drop `fixture_label`, set
   `"policy_version": 1`, keep `"zone": "Africa/Lusaka"`, no quiet hours (`"quiet_hours": null`),
   the bands 14 days / 48 h / 24 h and the default reminders (24 h before and at the answer-by
   time, 24 h before the start), as decided (owner-decisions-milestone-2.md, Q2 and 2026-10-15
   item 12). Then, in production:

   ```sql
   select app.notifications_policy_errors('<value>'::jsonb);   -- must answer {}
   select app.policy_approve('q2_church_time', '<value>'::jsonb, 'israel',
     'Owner decision 2026-10-08 (Q2), confirmed 2026-10-13 and 2026-10-15: church time Africa/Lusaka, no quiet hours');
   select app.notifications_replan_all('policy_changed');      -- replanned 0 on an empty database
   ```

2. **`q12_operations`** with the reminder-lateness tolerance of **10 minutes** (owner decision
   2026-10-14):

   ```sql
   select app.policy_approve('q12_operations', '{"reminder_lateness_tolerance": "10 minutes"}'::jsonb, 'israel',
     'Owner decision 2026-10-14 (Q12): a due reminder not delivered within 10 minutes is a fault');
   ```

   The 10 minutes are **recorded only**: no code reads the value. Opening the gate is what lets
   the scheduler run in production; the tolerance is the yardstick the owner and operator use when
   reading **Reminder health** (a reminder delivered later than 10 minutes after it was due is a
   fault to report).

3. **`ops_system_access`** (identity G7). Staging never approves this gate (system access is open
   in `local` and `staging` without it), so there is no staging value to copy. No code reads the
   approved value either: the gate only has to be open, and what each production principal may run
   is fixed by its purpose in `app.sys_command_kinds`. The value records what the owner approved.
   **This one approval replaces the value identity G7 would record** (`policy_approve` overwrites
   the gate's value), so it names all three purposes:

   ```sql
   select app.policy_approve('ops_system_access', '{
     "notifications_worker": ["notifications.claim", "notifications.attempt", "notifications.release",
       "notifications.deliver_due", "notifications.push_claim", "notifications.push_prepare",
       "notifications.push_record", "notifications.push_release"],
     "identity_assisted_recovery": ["identity.assisted_recovery_request", "identity.assisted_recovery_status",
       "identity.assisted_reset_begin", "identity.assisted_reset_dispatch", "identity.assisted_reset_complete"],
     "identity_deletion": ["identity.deletion_queue", "identity.deletion_next", "identity.deletion_advance",
       "identity.deletion_auth_begin", "identity.deletion_auth_complete", "identity.deletion_journal_ack",
       "identity.deletion_journal_catch_up"]}'::jsonb, 'israel',
     'Owner decision 2026-10-13: the system route for the notifications worker, assisted recovery and deletion workers');
   ```

   Opening the gate does not switch on the identity functions: each still answers `unavailable`
   until its own production credential is registered and its Edge secret set (identity G2, G6 and
   G7 in production-promotion-identity.md). Check the list against the database first:
   `select purpose, array_agg(command order by command) from app.sys_command_kinds group by 1;`
   (`synthetic_probe` is not approved for production).

Check: `select app.policy_is_open(g) from unnest(array['q2_church_time','q12_operations','ops_system_access']) g;`
answers three `true`.

### 2. The notifications worker: credential digest, Edge secrets, trigger and schedule

The owner minted the production worker credential already and sends only its **digest**
(owner decision 2026-10-15); the token never leaves the owner's machine and never enters the
database. The steps are notifications.md story 3.4 "Hosted staging" with production values:

1. Register the digest (operator, SQL editor):

   ```sql
   select app.sys_register_credential(
     app.sys_create_principal('notifications-worker', 'notifications_worker', 'israel'),
     '<64-hex digest the owner sent>', 'notifications worker edge production', interval '30 days', 'israel');
   ```

2. Point the worker at the production function and make a trigger:

   ```sql
   select app.notifications_configure_worker(
     '{"worker_url": "https://<production ref>.supabase.co/functions/v1/notifications-worker"}', 'israel');
   select app.notifications_scheduler_new_trigger('israel');   -- {"trigger_set": true}; the value is not shown
   ```

3. Edge secrets (owner, dashboard **Edge Functions > Secrets**, production project):
   `NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL` = the minted token; `NOTIFICATIONS_WORKER_TRIGGER` =
   the Vault secret `notifications_worker_trigger` (**Project Settings > Vault > Secrets**, reveal
   and copy). `NOTIFICATIONS_FCM_SERVICE_ACCOUNT` is already saved (2026-10-14); push stays off
   (`push_enabled: false`, G9 `outbound_sending` closed) until the owner turns it on.
4. Prove one tick, then schedule:

   ```sql
   select app.notifications_scheduler_tick();          -- {"tick": "sent"}
   select app.notifications_scheduler_status();        -- last_claim_at set within a few seconds
   select app.notifications_scheduler_enable('israel'); -- scheduler_jobs: 1 (refused while step 1 is incomplete)
   ```

   A 401/403/503 in `net._http_response` means a wrong trigger, an unregistered credential or a
   missing secret (notifications.md story 3.4, step 7). Rotate the credential within 30 days.

### 3. Live personal data: `q4_personal_data` with the labelled-contact scope (G5), only with or after Q2

Owner decision 2026-10-15, item 1: a department leader or deputy sees **only the labelled contact
routes** (the numbers the member registered, with whose they are), for **their own department's
members only**. That is what the server returns once the gate is open
(`app.identity_scoped_contact_routes`; never a phone username, never a hold or deletion reason),
so no code change is needed. Record it with the privacy-notice approval of identity G5:

```sql
-- Only after step 1 (q2_church_time approved), or in the same session after it.
select app.policy_approve('q4_personal_data',
  '{"privacy_notice": "<approved version>", "leader_contacts": "labelled_routes_own_department"}'::jsonb, 'israel',
  'Owner decisions 2026-10-15 (Q4 item 1: leaders and deputies see labelled contact routes of their own department only) and <privacy notice decision>');
```

Approving Q4 before Q2 is not wrong but leaves Follow-ups closed (`gate_closed`) until Q2: do
step 1 first. Then G8 (first real Admin) and G11 (sign-up open) follow the identity package.

### 4. Deletion retention: `identity_deletion_retention` = anonymise (G6)

Owner decision 2026-10-15, item 2: **anonymise**. Duty and task history is kept as "a former
member"; notes and free text about the member are erased. This is how the Duties and Follow-ups
deletion hooks are built (duties.md: `duties_erase_member` clears notes, reasons and attempt notes
and anonymises actors with the nil UUID; follow-ups.md likewise), and Identity's kept records are
anonymised by `app.identity_deletion_retention_rules`.

```sql
select app.policy_approve('identity_deletion_retention',
  '{"retention": "anonymise", "duties_followups": "history kept as a former member; notes and free text erased"}'::jsonb,
  'israel', 'Owner decision 2026-10-15 (Q4 item 2): anonymise');
```

Erasure then runs only when the deletion worker runs: its production credential, the journal
store and its schedule are identity G6/G7 (production-promotion-identity.md, step 6), still owner
items.

### 5. Identity gates already documented

G3 dormancy **180 days** (`app.identity_approve_setting('dormancy_days', '{"days": 180}', ...)`),
G4 password policy and Auth rate limits, and G11 public sign-up are exactly as in
[production-promotion-identity.md](production-promotion-identity.md), step 6. Without G3 the
live-access predicate answers `unavailable` to every member, so Duties stays closed for everyone
even with Q4 open.

### 6. The pilot department: Music Department (owner decision 2026-10-15, item 14)

Only after G5, G8 and G11 (real members can register and be approved) and G3:

1. The leaders register in the app and the Admin approves their applications (identity-access.md,
   story 2.4).
2. Staff web as the Admin, **Departments > Add department**: `Music Department` (not
   `SYNTHETIC`: synthetic departments are hidden outside local and staging).
3. **Roles & access** (or **Departments**): the **Music Director** as department **leader**; the
   **Vice-Music Director**, the **Secretary** and the **Treasurer** as department **deputies**.
   Their names are production configuration only: never write them in this repository, in
   evidence or in a ticket.
4. **Departments > Add a member** for each serving member (members without a login are added as
   member records with a labelled contact route, consented in person).
5. The leader creates the first rota on staff web **Rota** (duties-guides.md has the leader
   guide). Reminders flow once step 2 is done.

Revoking the last reachable leader's scope is refused **Hand over first** (story 4.16): give the
role to someone else first.

### 7. Read-only verification checklist (production SQL editor; record outputs without personal data)

```sql
select app.platform_current_environment();                                   -- production
select g.gate, app.policy_is_open(g.gate) from app.policy_gates g
 where g.gate in ('q2_church_time','q12_operations','ops_system_access','q4_personal_data',
                  'identity_deletion_retention','outbound_sending','private_access') order by 1;
                                       -- true only for the gates approved above; outbound_sending
                                       -- and private_access false unless separately approved
select app.identity_applications_open() as duties_open,                      -- false until G5
       app.followups_reminders_ready() as followups_policy_ready;            -- false until Q2
select app.notifications_scheduler_status() ->> 'scheduler_jobs' as jobs,    -- 0 until step 2.4, then 1
       app.notifications_scheduler_status() ->> 'last_tick_outcome' as tick;
select app.notifications_scheduler_status() -> 'push' ->> 'enabled' as push; -- false
select count(*) as departments, count(*) filter (where is_synthetic) as synthetic
  from app.duties_departments;                                               -- 0 / 0 before the pilot; then 1 / 0
select count(*) from app.duties_occurrences;                                 -- 0 before the pilot
select count(*) from app.followups_tasks;                                    -- 0 before the pilot
select count(*) from app.identity_members;                                   -- 0 before G5
```

Through the public API with the production publishable key (no account): `POST
/rest/v1/rpc/duties_my_duties` and `/rest/v1/rpc/followups_my_tasks` without a session answer
`401`. With an approved member session while Q4 is closed they answer `403` `unavailable`; on the
clients, **Not available yet**.

And `tools/ci/verify-hosted.sql` runs inside promote (environments-and-promotion.md): it fails
the promotion when a notifications scheduler job exists before `ops_system_access`, `q2_church_time`
and `q12_operations` are all approved.

Record the outputs in `evidence-4.15/production-verify.md` (to be written at promotion; never
names, numbers, keys or tokens).

## Staging gate (before the owner promotes)

1. The closing suite passes on staging on the commit to promote, run by the owner (it needs the
   synthetic Admin's password; duties.md, story 4.15, and owner-demonstration.md section 0), its
   cleanup SQL run by the parent session, and the independent rerun after that cleanup.
2. The 4.13 pilot rehearsal on staging (`duties-pilot.mjs --target staging`, owner decision 11).
3. The owner's demonstration (`evidence-4.15/owner-demonstration.md`) is witnessed.
4. PR #6 is merged into `main`; the owner runs **promote** (staging, then production).
