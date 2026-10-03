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

- Only the auth-test project. `run.mjs` refuses any other `SUPABASE_URL`.
- Publishable key only, supplied by environment at run time. Never a secret,
  service-role key or database password.
- Synthetic accounts only: `israelmuyoba+bicauth-<tag>@gmail.com` (owner-approved
  plus-addresses) and test-range phone numbers such as `+260970000101`.
- Passwords are generated per account and kept with live tokens in a local state
  file (`HARNESS_STATE`, default OS temp dir, mode 0600). Never commit it.
- Every evidence line passes through `scrub()`: JWTs become a header + trust-claim
  summary (`sub`/`session_id` as digests), and refresh tokens, link tokens, OTPs
  and passwords are redacted.
- Never configure SMS, an SMS provider, a Send SMS hook, test OTPs or SMS MFA.

## Server-side probe

`sql/001_trusted_session_probe.sql` (applied to the auth-test project only, never
to `supabase/migrations`) creates:

- `harness.trusted_password_session()`: true only when the verified JWT `amr`
  contains `password` **and** `session_id` still exists in `auth.sessions` for
  the same user.
- `harness.private_probe`: a synthetic private table under RLS that uses that
  predicate.
- RPCs `public.harness_private_probe()` (allowed / denied) and
  `public.harness_whoami()` (AMR methods, aal, session-live flag, predicate).

This is the session half of the AD-3 predicate only. Membership, binding, hold
and grant checks belong to the identity epic.

## Usage

```sh
export SUPABASE_URL=https://szfyfezfvxyuvovnnakr.supabase.co
export SUPABASE_PUBLISHABLE_KEY=<publishable key from the dashboard or MCP>
H="node tools/auth-harness/run.mjs"

$H info --step 00-provider-info
$H signup p1 --phone +260970000101 --step 10-phone-signup
$H login p1-a --account p1 --phone +260970000101
$H probe p1-a
$H set-email p1-a --email israelmuyoba+bicauth-p1@gmail.com
$H verify-link p1-email '<link from the inbox>'
$H recover --email israelmuyoba+bicauth-p1@gmail.com
$H set-password p1-rec --account p1
$H refresh p1-b
```

`--step <name>` labels the evidence line. `verify-link` calls `/auth/v1/verify`
exactly as the emailed link would but does not follow the redirect; it records
the redirect origin and the fragment type or error, and keeps the session locally.

Offline unit tests (also in CI): `node --test tools/auth-harness/*.test.mjs`.

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
