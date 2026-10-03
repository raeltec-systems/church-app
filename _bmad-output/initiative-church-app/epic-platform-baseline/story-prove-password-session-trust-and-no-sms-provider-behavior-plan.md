---
title: 'Prove password-session trust and no-SMS provider behavior'
type: 'feature'
ticket: '2'
created: '2026-10-03'
status: 'blocked'
blocked_reason: 'Owner dashboard step on bic-kafue-auth-test: Authentication > Sign In / Providers > Phone, Enable Phone provider ON, Confirm phone OFF, no SMS credentials/hook/test OTPs. Until then the phone/password signup and login, same-account email add/verify and phone-user email/password alias rows cannot run. All email-track rows are observed in evidence-1.2.'
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
- [x] `tools/auth-harness/lib.mjs` -- GoTrue/PostgREST REST client, JWT claim decoding, redaction, evidence writer.
- [x] `tools/auth-harness/run.mjs` -- subcommands per matrix row plus `info`; local token state in temp dir.
- [x] `tools/auth-harness/sql/001_trusted_session_probe.sql` -- `harness` schema, probe table, `harness.trusted_password_session()` security-definer predicate, RLS; applied via MCP.
- [x] `tools/auth-harness/lib.test.mjs` -- offline tests for redaction, AMR predicate mirror and link parsing.
- [x] `tools/auth-harness/README.md` -- usage, owner settings, safety rules.
- [x] `.github/workflows/ci.yml` -- add `auth-harness` job running `node --test`.
- [ ] `evidence-1.2/` -- (email track done; phone rows await the owner gate) version, settings, per-scenario JSON and summary.

**Acceptance Criteria:**
- Given the hosted project, when the harness runs, then each matrix row has a redacted evidence file or a recorded owner-gate reason.
- Given any evidence file, when scanned, then no full JWT, refresh token, OTP or password appears.

## Implementation Notes

- Decision (agent, under owner pre-approval): the harness is a dependency-free Node CLI rather than a Dart or supabase_flutter harness. That keeps it out of `apps/` and other lanes, it calls the raw native endpoints the acceptance map requires, and CI can run it offline. Owner decisions: `/home/user/church-app/_bmad-output/initiative-church-app/owner-decisions-milestone-1.md` (main checkout; not on this branch).
- Decision (agent, under owner pre-approval): the probe RPCs live in `public` with a `harness_` prefix. Exposed API schemas are a dashboard setting, so the private table stays in the unexposed `harness` schema behind RLS.
- Implemented directly, not through a subagent. This session has no subagent tool, and the live run needs the MCP and Gmail tools that this session holds.
- Hosted apply: the first `apply_migration`, which contained `drop policy` and `revoke`, came back `cancelled`. Two migrations then applied successfully: a create-only one, and a separate grant-tightening one (`auth_harness_001`/`002`). After the advisor findings, `003` revoked `anon` on `harness_whoami`. The SQL file is the idempotent sum of the three.
- The Supabase MCP has no Auth-config tool and no Management API token is available. Phone provider, phone confirmations, Site URL and redirect allowlist are therefore dashboard-only owner steps.
- The default SMTP limit (2 emails per hour, project-wide) paces the email-dependent steps.
- **Live run.** Observed on 2026-10-03 against GoTrue v2.197.0 and Postgres 17.11. Results and findings are in `evidence-1.2/README.md`; the raw redacted log is `evidence-1.2/harness-log.jsonl`.
- **AMR labels.** Signup-link, magic-link and recovery sessions all carry `amr=[otp]`. Only password grants carry `password`.
- **Password change.** Password change from a session, and password set from a recovery session, delete every other `auth.sessions` row. The deleted sessions' JWTs are then denied only by the live-session check.
- **Recovery session survives.** The recovery session survives its own password set but stays denied.
- **`/recover` existence oracle.** For a known address `/recover` returns 429 when throttled, while an unknown address returns 200. This is recorded as a finding for identity.
- **Evidence labelling.** One evidence line was relabelled from the ad-hoc step `x` to `33b-probe-password-session-A-repeat`. Its content was not changed.

- **Review fixes (2026-10-03, parent review).**
  - **Project guard:** now `assertAllowedOrigin()` in `lib.mjs`. It requires https, the exact host `szfyfezfvxyuvovnnakr.supabase.co`, no port and no userinfo. It covers both `SUPABASE_URL` and email links, with unit tests for the bypass cases.
  - **State storage:** state lives in a private `mkdtemp` directory (`init`, 0700, owner-checked). Reads use `O_NOFOLLOW`; writes go through an `O_EXCL` temp file plus rename at 0600. `cleanup` deletes it.
  - **Links:** `verify-link` reads the link from stdin.
  - **`otp`:** records `create_user` and documents the no-user path.
  - **Raw evidence:** new `attach` command plus committed read-only queries `sql/observe_{probe_grants,account_sessions,auth_logs}.sql`. `note` is commentary only.
  - **CI scan:** moved to `scan-evidence.sh`, which covers JWTs, keys, `Hx!` passwords, `token=`/hex link tokens, unredacted secret JSON keys and unmasked inbox addresses in evidence.
  - **SQL probe:** made exactly reproducible, adding `harness.session_live()` (with the `not_after` check) shared by the predicate and `harness_whoami`, and revoking `anon` everywhere. The hosted project was reconciled with migration `auth_harness_004_reconcile_probe` (the full file), and the result was captured as step 98.
  - **Evidence README:** rewritten so every claim cites log steps.
    - Lines 5 and 6 are marked legacy.
    - Notes 68 and 94 are no longer used as observations.
    - Row 8 (signup-link session not re-probed), row 11 (C not refreshed) and row 16 (phone `/otp` was the no-user path) are corrected.
    - Unsupported items are marked "to re-capture".
    - Inbox addresses are masked.
  - **Cleanup and new runs:** the old fixed-path state file and wrapper were deleted. Steps 98 and 99 were attached from MCP output.

## Plan Change Log

- 2026-10-03, parent review (not a step-04 loop).
  - **Findings:**
    - The project guard used a substring match.
    - The SQL file did not match hosted grants, and the diagnostic omitted `not_after`.
    - Evidence relied on legacy lines and free-text notes.
    - The README overstated rows 8, 11 and 16.
    - The CI scan was too narrow.
    - The state file was unsafe, link tokens were passed in argv, and inbox addresses were unmasked.
  - **Amended:** harness code, tests, CI scan, SQL file plus hosted 004, and the evidence README, as listed in Implementation Notes. The frozen intent is unchanged.
  - **Avoids:** credentials sent to a look-alike host; evidence claims with no captured output; secrets or link tokens leaking through argv, a predictable temp file or evidence that CI fails to scan.
  - **KEEP:**
    - native-endpoint calls with no dependencies;
    - the AMR-plus-live-session predicate;
    - redaction through `scrub()`;
    - step-labelled JSONL evidence;
    - the owner-gated rerun list in the evidence README.

## Review Triage Log

## Verification

**Commands:**
- `node --test tools/auth-harness/*.test.mjs` -- expected: all pass
- `grep -rE 'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{10,}' evidence-1.2` -- expected: no matches
