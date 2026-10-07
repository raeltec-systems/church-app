# Runbook: promote the identity workflows to the production baseline (story 2.14)

Status: **prepared, not executed.** There is no production project yet. Nothing in this file has
run against production. Run it, in this order, only after the owner (Israel) has created the
production project and decided each gate below.

Related runbooks: [environments-and-promotion.md](environments-and-promotion.md) (the promotion
workflow, owner steps A-C), [identity-access.md](identity-access.md) (per-story mechanics and the
"Hosted" sections), [identity-support.md](identity-support.md) (RB1-RB8),
[system-access-and-operations.md](system-access-and-operations.md),
[backup-and-restore.md](backup-and-restore.md). Staging evidence for this package:
`_bmad-output/initiative-church-app/epic-identity-and-scoped-access/evidence-2.14/`.

## What "promoted" means here

Production receives the same migrations, Edge Functions and client builds as staging, and then
shows every workflow deployed but **visibly disabled** wherever its gate is not approved. Each
gate is either approved by the owner (a recorded decision) or left closed, and a closed gate
fails closed:

- the release gate `private_access` and `outbound_sending` stay **closed** in milestone 1
  (`tools/ci/verify-hosted.sql` refuses a promotion while either is open);
- with no approved `dormancy_days` row, the live-access predicate answers `unavailable` to every
  member, so no private member data is served even if a later epic opens `private_access`;
- applications, the cell chooser and the Cells reads are closed until `q4_personal_data` is
  approved (`accepting_applications: false`, commands `unavailable {"policy": "gate_closed"}`);
- email recovery and staff-assisted recovery stay closed until `q1_auth_recovery` is approved;
- the system route (both Edge Functions use it) stays closed until `ops_system_access` is approved;
- deletion requests still deny access at once, but erasure waits until
  `identity_deletion_retention` is approved.

Production never gets fixture values: the labelled TEST FIXTURE rows (dormancy 90 days, the
lead-pastor designation, deletion retention) are honoured only in databases marked `local` or
`staging`.

## Ordered steps

### 1. Preconditions (owner)

1. Production Supabase project created and recorded (environments runbook, step C1), Data API
   exposing `api` only (C2), GitHub `production` environment with required reviewer and its
   secrets/variables (A2). Staff web host if wanted (B).
2. Staging is synced with the commit to promote: `npm run ci:drift:staging` reports no pending
   version, and the staging suite (`tools/identity-e2e/staging-suite.mjs`) passed on that commit
   (see "Staging gate" below).
3. The owner has decided every gate in the table below as **approve** or **leave closed**, in
   writing (the decision note text is used in the SQL below).

### 2. Auth settings (owner, Management API; the dashboard refuses the phone settings)

The identity workflows sign in with a phone-number username and a password **without SMS**. The
environments runbook step C3 ("keep the Phone provider off") predates identity; for identity the
production Auth settings are the same as on staging (owner decision 2026-10-06):

```http
PATCH https://api.supabase.com/v1/projects/<production ref>/config/auth
Authorization: Bearer <owner personal access token>
Content-Type: application/json

{"external_phone_enabled": true, "sms_autoconfirm": true, "hook_send_sms_enabled": false,
 "mfa_phone_enroll_enabled": false, "mfa_phone_verify_enabled": false,
 "external_anonymous_users_enabled": false, "double_confirm_changes": true}
```

- No `sms_provider`, no SMS credential, no `sms_test_otp`. Check with `GET` on the same URL and
  `GET https://<production ref>.supabase.co/auth/v1/settings` (`external.phone: true`,
  `phone_autoconfirm: true`).
- `site_url`: the production staff web origin. `uri_allow_list`: append (never replace)
  `zm.bickafue.mobile://callback/auth/recovery,zm.bickafue.mobile://callback/auth/email-confirmed`
  and, if staff web is on another host than `site_url`, `https://<staff host>/**`.
- Password policy and Auth rate limits: set only the values the owner approved for gate G3/G4
  (below); otherwise leave Supabase's defaults (the clients already require 8-72 bytes).
- Email: leave the built-in sender until gate G1 is approved. With G1 closed no flow needs email.

### 3. Database (promotion workflow, reviewer approval)

Run **promote** with target `staging`, then with target `production` (environments runbook,
"Promotion"). The production run applies every migration with `supabase db push` from the files
**verbatim**, including the three files that were owner-pasted on staging because the Supabase
connector cannot apply row deletions (`20261007131600_membership_review_reclaim_sessions`,
`20261007160100_credential_review_auth_rows`, `20261007175000_member_deletion_rows`). Nothing is
pasted by hand in production. The first run marks the database `production` (terminal) and runs
`tools/ci/verify-hosted.sql`, which must report: marker `production`, `private_access` and
`outbound_sending` closed, alerting disabled, no recovery hold, and the proven Auth schema
`20260831180000` for the 2.7 reset gate (if production's GoTrue is newer, stop: run the reset-gate
canary and the recovery E2E first, then add the version there).

After the run, confirm the migration owner's privileges the hand-pasted files need on staging
(read-only, SQL editor):

```sql
select has_table_privilege('postgres', 'auth.sessions', 'delete'),
       has_table_privilege('postgres', 'auth.refresh_tokens', 'delete'),
       has_table_privilege('postgres', 'auth.audit_log_entries', 'delete'),
       has_table_privilege('postgres', 'auth.users', 'delete');   -- all true
```

### 4. Edge Functions (owner or parent session; the promote workflow has no function step yet)

```sh
npx supabase functions deploy identity-assisted-recovery --project-ref <production ref> --no-verify-jwt
npx supabase functions deploy identity-deletion          --project-ref <production ref> --no-verify-jwt
```

Both answer `unavailable` (503) until their system credential exists and `ops_system_access` is
approved: that is their visibly disabled state. Do **not** set `IDENTITY_RECOVERY_SYSTEM_CREDENTIAL`
until gate G7 is approved. If the project's legacy API keys are disabled, the functions also
answer `unavailable` (identity-access.md, story 2.9 Hosted step 3).

### 5. Clients (one build per commit and environment)

- Staff web: built, scanned, sealed and deployed by the promote workflow (`staff-web-production-<sha>`).
- Mobile: `flutter build apk --release --target-platform android-arm64 --dart-define=SUPABASE_URL=https://<production ref>.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=<production sb_publishable_ key>` in `apps/mobile`; scan with `node tools/ci/scan-secrets.mjs --bundle <unzipped apk>`. Store signing belongs to the release epic; this build is for the owner's verification only.

### 6. Gates: approve, or leave fail-closed

Each approval is one owner decision recorded in the production database by the restricted
operator (Israel). Leaving a gate closed needs no action. **Never improvise an approval in SQL
that this table does not name.**

| # | Gate (spec) | Approve: what the owner decides, then the exact step | Left closed: what production shows |
|---|---|---|---|
| G1 | Email sender / SMTP and the send-email hook (Q1; owner decision 2026-10-07 #2) | Owner creates the sender account (e.g. Resend) and its domain, sets Auth **SMTP** in the dashboard (Authentication → Emails → SMTP settings). The send-email hook that makes `/recover` answers identical for registered and unknown addresses is **not built yet** (deferred-work entry from 2.14); build, test and deploy it before approving G2. | Built-in sender, not used by any production flow; email recovery stays closed by G2. |
| G2 | `q1_auth_recovery` (Q1: recovery owners, the tested assisted procedure, email recovery) | After G1 and the named reviewers: `select app.policy_approve('q1_auth_recovery', '{"email_recovery": true, "assisted_procedure": "identity-support.md RB4", "reviewers": ["<names>"]}', 'israel', '<decision note>');` | Recovery email proposals and approvals answer `unavailable {"policy": "gate_closed"}`; the reset gate refuses every recovery link; the assisted-recovery function answers `closed`/`unavailable`; staff web **Account recovery** shows `accepting: false`. |
| G3 | Dormancy period (Q1) | Needs an approved `app.identity_settings` row (`dormancy_days`, `source = 'approved'`). There is **no operator function** for it yet: add a reviewed migration (or operator function) that inserts version 2 with the owner's value and decision label, promoted like any migration. | No approved row: the predicate answers `unavailable` to every member (fail closed). |
| G4 | Password and abuse policy (Q1) | Auth: `password_min_length` (and required characters) and Auth rate limits for sign-in/sign-up/token refresh by Management API `PATCH .../config/auth`; leaked-password protection needs a paid plan. The assisted-recovery limits are already decided (10/client/10 min, 5/number/h, 120/church/10 min). | Supabase defaults; clients still require 8-72 bytes. No member access exists while G3/G5 are closed. |
| G5 | Live personal data `q4_personal_data` (Q4: privacy notice wording, youth/contact safeguards) | Approve the privacy notice (a new version needs a migration and client text), then `select app.policy_approve('q4_personal_data', '{"privacy_notice": "<version>"}', 'israel', '<decision note>');` | Applications closed (`accepting_applications: false`), chooser lists nothing, Cells reads/commands `unavailable`; only `SYNTHETIC` names and fictional numbers would be accepted, and synthetic seeding refuses production. |
| G6 | Deletion retention `identity_deletion_retention` (Q4: retention and backup periods) | Owner approves what is erased/anonymised and journal/backup retention, chooses the production journal and object store (backup-and-restore.md), then `select app.policy_approve('identity_deletion_retention', '{"retention": "<decision>"}', 'israel', '<note>');`, registers the deletion worker's production credential and schedules the worker. | Deletion requests still end access at once; the Auth and erase steps wait (`policy_gate_closed`); staff web **Member deletions** shows `accepting: false`. |
| G7 | System route `ops_system_access` (1.9) | `select app.policy_approve('ops_system_access', '{"commands": [...]}', 'israel', '<note>');`, then mint and register the two production credentials (assisted recovery, deletion worker) per system-access-and-operations.md; set the function secret. | Both Edge Functions answer `unavailable`. |
| G8 | First real Admin (Q1 approval owners) | **Open question below.** | No usable Admin: no staff screen works; nothing can be approved. |
| G9 | `private_access` / `outbound_sending` (release) | Not in milestone 1: a later release epic changes `verify-hosted.sql` and `tools/env/environments.mjs` together. | Closed; promotions verify it. |
| G10 | Church settings: `operational_contact` (Q1), `lead_pastor_designation` (Q4) | `select app.identity_approve_church_setting('operational_contact', '{"route": "<church office route>"}', 'israel', '<note>');`; the lead pastor only after Q4 (`app.identity_designate_lead_pastor`). | Help screens say "contact the church office"; the lead-pastor role cannot be assigned or used. |

### 7. Verify that production shows the gates disabled (read-only, SQL editor)

```sql
select app.platform_current_environment() as env;                       -- production
select g.gate, app.policy_is_open(g.gate) as open from app.policy_gates g order by 1;
-- every gate false unless the owner approved it in step 6
select app.identity_setting('dormancy_days') as dormancy;                -- null unless G3 approved
select app.identity_applications_open() as applications_open,           -- false unless G5
       app.identity_email_recovery_open() as email_recovery_open,       -- false unless G2 (and G5)
       app.identity_assisted_recovery_open() as assisted_recovery_open, -- false unless G2 (and G5)
       app.identity_usable_admin_count() as usable_admins;              -- 0 until G8
select setting, source, label from app.identity_settings;                -- fixture rows exist but do not count here
select count(*) from app.identity_members;                               -- 0 before any approval
```

Then through the public API with the production publishable key (no account needed):

- `POST https://<production ref>.supabase.co/functions/v1/identity-assisted-recovery` with
  a `status` action for a made-up digest (64 zeros) answers `503 {"outcome": "unavailable"}`
  (no credential / G7 closed).
- `POST /rest/v1/rpc/identity_my_member_summary` without a session answers 401.
- `POST /auth/v1/otp {"phone": "+12025550199"}` must not send anything (no SMS provider). Do not
  run it against a real number.

And on the clients (owner, production builds): the mobile app opens, **Create account** works
only once G5 is decided (until then the account would reach "No member access yet" and
**Join the church** shows that applications are closed); staff web shows the sign-in page and,
with no Admin, no Admin destinations.

Record the outputs in `evidence-2.14/production-verify.md` (never personal data, keys or tokens).

### Staging gate (before step 3)

```sh
STAGING_PUBLISHABLE_KEY=<staging sb_publishable_ key> \
STAGING_SUITE_STATE=<file outside the repo> STAGING_SUITE_ADMIN=<file outside the repo, {"pw": ...}> \
node tools/identity-e2e/staging-suite.mjs --evidence <evidence>/staging-suite.jsonl --summary <evidence>/staging-suite-summary.md
```

Every check passes (findings are reviewed separately), and the owner's email run, deletion
worker run and device demonstration (`evidence-2.14/owner-demonstration.md`) are done.

## Open question for the owner: the first real Admin (from 2.12, RB1)

Production has no path to the first real Admin: applications need an Admin to approve them, and
`app.identity_seed_synthetic_link` refuses production (synthetic names and fictional numbers
only). `app.identity_bootstrap_admin` then needs an approved member with a usable link. Options:

1. **Reviewed operator procedure (recommended).** A small migration adds an operator-only
   function that approves exactly one pending application **while `identity_usable_admin_count()`
   is 0**, after the owner's in-person identity check, records the check and the confirming owner
   (like RB8's two-person rule), and then bootstraps that member as Admin. Audited and journalled;
   refuses once any usable Admin exists. Needs G5 approved (a real name and number), its own
   story, pgTAP and a staging rehearsal.
2. **Approve the application by hand in SQL.** Not acceptable (RB1 says do not improvise it).
3. **Leave production without an Admin** until a later release. Production then stays fully
   fail-closed, which is the current state.

Until the owner chooses, production stays at option 3.

## Also decided at this gate (from 2.7)

GoTrue's `/recover` can reveal through its rate-limit replies and timing whether an address is
registered. The owner chose (2026-10-07) a church sender with a send-email hook (G1). Until the
hook is built and G2 approved, email recovery is closed in production, so the platform behaviour
is not reachable through any production flow.
