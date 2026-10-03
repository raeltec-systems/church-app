# Auth provider harness (story 1.2)

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
  plus-addresses) and test-range phone numbers such as `+260970000101`.
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
$H signup p1 --phone +260970000101 --step 10-phone-signup
$H login p1-a --account p1 --phone +260970000101
$H probe p1-a
$H otp --phone +260970000101           # existing user: the no-SMS path
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

## Hosted settings the harness needs (dashboard only)

The Supabase MCP tools cannot change Auth configuration, so the owner sets these
in the dashboard for `bic-kafue-auth-test`:

1. **Authentication → Sign In / Providers → Phone**: enable **Phone provider**,
   turn **Confirm phone** off, and leave the SMS provider credentials empty. Do
   not add a Send SMS hook or test OTPs.
2. **Authentication → Sign In / Providers → Email**: keep **Confirm email** on and
   **Secure email change** on.
3. **Authentication → URL Configuration**: Site URL and redirect allowlist only
   when a real redirect is under test. The harness works with the default
   `http://localhost:3000`, because it never follows the redirect.
