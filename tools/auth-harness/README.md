# Auth provider harness (stories 1.2 and 1.3)

A retained, dependency-free harness that calls native Supabase Auth (GoTrue) and
PostgREST endpoints directly against the **isolated** project
`bic-kafue-auth-test` (`szfyfezfvxyuvovnnakr`). It proves the AD-3/AD-20
assumptions: phone/password with no SMS, signed `password` AMR, live-session
checks, neutral recovery, denial of OTP / magic-link / recovery sessions, and
session revocation on password change.

Evidence lands in
`_bmad-output/initiative-church-app/epic-platform-baseline/evidence-1.2/`.

## Safety rules

- Only the auth-test project. `SUPABASE_URL` and every emailed link are parsed,
  and must be exactly `https://szfyfezfvxyuvovnnakr.supabase.co`: https, that
  exact hostname, no port and no userinfo. Anything else is refused before a
  request is sent. Substring matches such as
  `https://szfyfezfvxyuvovnnakr.attacker.example` fail.
- Publishable key only, supplied by environment at run time. Never a secret,
  service-role key or database password.
- Synthetic accounts only: `israelmuyoba+bicauth-<tag>@gmail.com` (owner-approved
  plus-addresses) and phones in the NANP fictional range `+1 202 555 0100–0199`
  (never assignable), e.g. `+12025550101`.
- Passwords are generated per account and kept with live tokens in a private
  state directory, `HARNESS_STATE_DIR`:
  - `init` creates it with `mkdtemp`, mode 0700, owned by you.
  - The state file is read with `O_NOFOLLOW` and written through an `O_EXCL`
    temp file plus rename, mode 0600.
  - `cleanup` deletes the directory. Run it at the end of every session, and
    never commit the directory.
- One-use email links are read from **stdin**, never from argv, so they stay out
  of the process list and shell history.
- Every evidence line passes through `scrub()`: JWTs become a header + trust-claim
  summary (`sub`/`session_id` as digests), and refresh tokens, link tokens, OTPs
  and passwords are redacted. `scan-evidence.sh` (run in CI) fails on:
  - JWTs and keys;
  - harness passwords;
  - `token=` values and hex link tokens;
  - unredacted secret-bearing JSON keys;
  - unmasked inbox addresses in evidence.
- Evidence claims cite harness calls or `attach` lines, which hold raw output
  from a committed read-only query in `sql/observe_*.sql` run through the
  Supabase MCP. `note` lines are commentary, not observations.
- Never configure SMS, an SMS provider, a Send SMS hook, test OTPs or SMS MFA.

## Server-side probe

`sql/001_trusted_session_probe.sql` (applied to the auth-test project only, never
to `supabase/migrations`) creates:

- `harness.trusted_password_session()`: true only when the verified JWT `amr`
  contains `password` **and** `harness.session_live()` is true. That means
  `session_id` still exists in `auth.sessions` for the same user, with
  `not_after` not passed.
- `harness.private_probe`: a synthetic private table under RLS that uses that
  predicate.
- RPCs `public.harness_private_probe()` (allowed / denied) and
  `public.harness_whoami()` (AMR methods, aal, the same `session_live`, and the
  predicate). Both are executable by `authenticated` only.

This is the session half of the AD-3 predicate only. Membership, binding, hold
and grant checks belong to the identity epic.

## Usage

```sh
export SUPABASE_URL=https://szfyfezfvxyuvovnnakr.supabase.co
export SUPABASE_PUBLISHABLE_KEY=<publishable key from the dashboard or MCP>
H="node tools/auth-harness/run.mjs"
eval "$($H init)"                      # exports HARNESS_STATE_DIR

$H info --step 00-provider-info
$H signup p1 --phone +12025550101 --step 10-phone-signup
$H login p1-a --account p1 --phone +12025550101
$H probe p1-a
$H otp --phone +12025550101            # existing user: the no-SMS path
$H signup p2 --phone +12025550103 --no-password   # must be refused
$H set-email p1-a --email <approved plus-address for tag p1>
$H verify-link p1-email < link.txt     # link on stdin, never argv
$H recover --email <approved plus-address for tag p1>
$H verify-link p1-rec < link.txt
$H set-password p1-rec --account p1
$H probe p1-a && $H refresh p1-a      # every other session, after each change
$H attach --source sql/observe_account_sessions.sql --step 68-sessions < result.json
$H cleanup                             # removes tokens and passwords
```

`--step <name>` labels the evidence line. `verify-link` calls `/auth/v1/verify`
exactly as the emailed link would but does not follow the redirect. It records
the redirect origin and the fragment type or error, and keeps the session locally.
`otp` sends `create_user:false`. For a phone with no user, Auth answers
`otp_disabled` before any provider logic, so target an existing user.

Offline checks (also in CI): `node --test tools/auth-harness/*.test.mjs` and
`bash tools/auth-harness/scan-evidence.sh`.

## LOCAL target (story 1.2 local rerun)

- **Enabling it.** `HARNESS_TARGET=local` switches the single allowed origin to exactly `http://127.0.0.1:54321`, the local Supabase CLI stack.
  - Local mode never accepts the hosted project, and hosted mode never accepts local.
  - Each evidence line carries `harness_target: "LOCAL"`.
  - The default log is `evidence-1.2/local-harness-log.jsonl`.
- **The script.** `scenarios/1.2-local-rerun.sh` is the recorded run, and its header lists its preconditions:
  - the probe plus `sql/local/10_local_api_probe_wrappers.sql` applied to the local DB;
  - the local publishable key in the environment.
- **Helpers.**
  - `local-mailpit-link.mjs` reads verify links from the local Mailpit for piping into `verify-link`.
  - `local-auth-logs.mjs` summarises the local GoTrue log for `attach`.
  - `sql/local/observe_local_*` hold the local read-only queries.
- **Cleanup.** Run `supabase db reset` afterwards to remove the harness objects.
- **Known gate.** Supabase CLI 2.119.0 forces the phone provider off unless an SMS provider is enabled. See `evidence-1.2/local-cli-phone-gate.txt`. Never enable one to get past this; the phone track runs on hosted instead.

## Hosted settings the harness needs

The Supabase MCP tools cannot change Auth configuration, and the dashboard
refuses to enable the Phone provider without SMS credentials. The owner
therefore set the phone settings for `bic-kafue-auth-test` through the
Management API (done 2026-10-06; body and checks in
`evidence-1.2/README.md`, "Former owner gate"):

1. **Phone:** `external_phone_enabled: true`, `sms_autoconfirm: true`,
   `hook_send_sms_enabled: false`, phone MFA off, and **no** `sms_*` provider
   credentials or `sms_test_otp`. `sms_provider` keeps its default label
   `twilio`; every phone `/otp` must fail with "Unable to get SMS provider".
2. **Email** (dashboard): keep **Confirm email** on and **Secure email change** on.
3. **URL Configuration** (dashboard): Site URL and redirect allowlist only
   when a real redirect is under test. The harness works with the default
   `http://localhost:3000`, because it never follows the redirect.

Hosted phone-track run (story 1.2, 2026-10-06): scenarios
`1.2-hosted-a-phone.txt` → `b-email-alias` → `c-recovery` → `d-signup-link`,
with the hand-run steps listed in each header, plus the read-only queries
`sql/observe_phone_sms_state.sql` (MCP `execute_sql`) and
`sql/observe_auth_sms_attempts.sql` (MCP `query_logs`). The default SMTP allows
2 Auth emails per hour, so part D runs an hour after parts B/C. Delete the
run's synthetic users afterwards and attach `observe_phone_sms_state.sql`.

## Story 1.3: fenced assisted recovery

Evidence lands in `evidence-1.3/` (set `HARNESS_EVIDENCE` to its
`harness-log.jsonl`). Results and findings: `evidence-1.3/README.md`.

### Hosted pieces (auth-test project only)

- `sql/002_recovery_fence.sql`, `003_recovery_observe.sql`,
  `004_review_fixes.sql` (migrations `auth_harness_005`-`008`; together with
  `001` they are the exact hosted definitions):
  - `harness.rc_*` tables, with RLS on and no client grants;
  - triggers on `auth.users`, `auth.identities` and `auth.mfa_factors` that
    advance the recovery generation inside GoTrue's transaction;
  - service-only `harness_rc_*` RPCs;
  - `public.harness_recovery_probe()`, the full private-data gate.
- `functions/harness-recovery/` is the Edge Function (`verify_jwt` on).
  - Deploy it with the Supabase MCP `deploy_edge_function`, sending files
    `index.ts` and `logic.mjs`.
  - It is the only holder of the service key, which it reads from the
    platform environment.
  - It refuses any other project, URL or token issuer, and requires the
    operator token.
  - Staff actions also need a trusted password session of an account
    enrolled out of band (`sql/enroll_staff.sql`). The operator token cannot
    create staff.
  - Fault injection exists for the adversarial runs only:
    `stop_after_begin`, `crash_after_dispatch`, `delay_apply`,
    `lost_response`, `late_apply`, `late_apply_background`.

### Running (the sequence recorded in evidence-1.3)

```sh
eval "$($H init)"
export SUPABASE_ANON_JWT=<legacy anon key>    # the function gateway needs a JWT
$H rc-operator-token                           # prints the digest only
# MCP: sql/register_operator_token.sql with that digest
$H rc-version --step 01-function-version-start
# MCP get_edge_function -> node edge-function-fingerprint.mjs -> attach (02);
# MCP sql/observe_recovery_definitions.sql -> attach (03); same query on the
# committed files in a local container -> attach (04)
node run-script.mjs scenarios/1.3-a-setup.txt
# MCP: sql/enroll_staff.sql for the staff account -> attach (15)
node run-script.mjs scenarios/1.3-b-callers.txt
# MCP query_logs: sql/observe_admin_calls.sql for the part-B window -> attach (39)
node run-script.mjs scenarios/1.3-c-grants.txt
node run-script.mjs scenarios/1.3-d-fences.txt
$H login me-s1 --account me --email <me plus-address> --step 200-login-member-e
node run-script.mjs scenarios/1.3-e-email-pre.txt   # sends 2 Auth emails
$H verify-link me-email-new --step 203-... < link-to-new-address.txt
$H verify-link me-email-cur --step 204-... < link-to-current-address.txt
node run-script.mjs scenarios/1.3-f-email-post.txt
# end: list_edge_functions (300); observe_recovery_definitions_digest.sql
# hosted (301) and committed (302); observe_log_secret_scan.sql (303)
$H cleanup
```

Second review (function v5, hosted `009`): run `scenarios/1.3-g-review2-setup.txt`, enrol `r13-x-staff2` with `sql/enroll_staff.sql`, then run `scenarios/1.3-h-review2-runs.txt`.

The LOCAL assertion test runs in a throwaway container with `--network none`: apply `sql/local/00_stubs.sql` as supabase_admin, then `001`-`005` as postgres, then `sql/local/test_fence.sql` as supabase_admin. It raises on any failed check.

Account tags must be new for each project run, because Auth refuses an
existing address. The member's grant secret (`hg_…`) and chosen password stay
in the state dir. Staff output carries only the grant id, generation and
expiry. `rc-call` sends deliberately wrong callers; never put a real secret in
`--body`.
