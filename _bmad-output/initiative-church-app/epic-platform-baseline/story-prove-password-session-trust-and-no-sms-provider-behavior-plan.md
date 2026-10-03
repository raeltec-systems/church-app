---
title: 'Prove password-session trust and no-SMS provider behavior'
type: 'feature'
ticket: '2'
created: '2026-10-03'
status: 'in-progress'
baseline_revision: 'dfa367db1bae7ae6ade7dfab75cfaf2de99b853a'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/architecture-church-app/reviews/technology-auth-update.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** AD-3/AD-20 rely on unproven hosted-Auth behaviour: phone/password without SMS, signed password AMR, live-session checks, neutral recovery, denial of OTP/magic-link/recovery sessions and session revocation on password change. Identity work must not build on these until they are observed against the deployed Auth version.

**Approach:** A retained, dependency-free Node harness in `tools/auth-harness/` calls native GoTrue endpoints directly against the isolated `bic-kafue-auth-test` project, plus a harness-only SQL probe (a private table behind a trusted-password + live-session predicate). Each run writes redacted JSON evidence to `evidence-1.2/`; links from owner-approved plus-address inboxes are fed into it.

## Boundaries & Constraints

**Always:** Only project `szfyfezfvxyuvovnnakr`; synthetic accounts (`+26097…` test-range phones, `israelmuyoba+bicauth-<tag>@gmail.com`). Publishable key only, from env at run time. Evidence redacts JWTs to header + needed claims, never stores access/refresh tokens, OTPs, link tokens or passwords. Harness state with live tokens stays in the OS temp dir. Predicate requires a `password` entry in signed `amr` and a live `auth.sessions` row for `session_id`.

**Never:** Configure SMS, an SMS provider, Send SMS hook, test OTPs or SMS MFA. Touch `supabase/migrations`, `apps/`, `trials/` or the platform project. Use service-role/secret keys. Read any mail beyond Supabase Auth mails to the approved plus-addresses.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Phone/password signup | phone + password, confirmations off, no SMS provider | one Auth user, session with `amr=[password]`, no SMS | provider disabled → record owner gate |
| Password login | correct / wrong password | probe allowed / `invalid_credentials` neutral error | — |
| Same-account email | `PUT /user {email}` then verify link | same user id, `email_confirmed_at` set, no second user | unverified email cannot recover |
| Email/password alias | verified email + same password | same user id, `amr password`, probe allowed | — |
| OTP / magic-link session | `/otp` email → `/verify` | session amr without `password` | probe denied |
| Recovery session | `/recover` → `/verify` | amr `otp`/`recovery`; probe denied even after password update | fresh password login allowed |
| Neutral recovery | `/recover` unknown vs known email | identical status/body | — |
| Password change | `PUT /user {password}` from session A | session B row deleted; B's unexpired JWT probe denied, B refresh fails | — |
| Phone OTP | `/otp {phone}` | no SMS sent, no session | error recorded |

</frozen-after-approval>

## Code Map

- `supabase/` -- backend lane; do NOT edit. Root `package.json` scripts belong to backend lane; harness runs via `node tools/auth-harness/...` with no deps.
- `.github/workflows/ci.yml` -- add an offline `node --test tools/auth-harness` job only.
- Hosted Auth observed at planning: GoTrue `v2.197.0`; `/auth/v1/settings` shows `phone:false`, `mailer_autoconfirm:false`, `sms_provider:"twilio"` (default, unconfigured). MCP tools expose no Auth-config write; phone provider, site URL and redirect allowlist are dashboard settings.
- Research `technology-auth-update.md` -- implicit `/verify` labels recovery as `otp`; `UpdatePassword` keeps current session, deletes others.

## Tasks & Acceptance

**Execution:**
- [ ] `tools/auth-harness/lib.mjs` -- GoTrue/PostgREST REST client, JWT claim decoding, redaction, evidence writer.
- [ ] `tools/auth-harness/run.mjs` -- subcommands per matrix row plus `info`; local token state in temp dir.
- [ ] `tools/auth-harness/sql/001_trusted_session_probe.sql` -- `harness` schema, probe table, `harness.trusted_password_session()` security-definer predicate, RLS; applied via MCP.
- [ ] `tools/auth-harness/lib.test.mjs` -- offline tests for redaction, AMR predicate mirror and link parsing.
- [ ] `tools/auth-harness/README.md` -- usage, owner settings, safety rules.
- [ ] `.github/workflows/ci.yml` -- add `auth-harness` job running `node --test`.
- [ ] `evidence-1.2/` -- version, settings, per-scenario JSON and summary.

**Acceptance Criteria:**
- Given the hosted project, when the harness runs, then each matrix row has a redacted evidence file or a recorded owner-gate reason.
- Given any evidence file, when scanned, then no full JWT, refresh token, OTP or password appears.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `node --test tools/auth-harness/` -- expected: all pass
- `grep -rE 'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{10,}' evidence-1.2` -- expected: no matches
