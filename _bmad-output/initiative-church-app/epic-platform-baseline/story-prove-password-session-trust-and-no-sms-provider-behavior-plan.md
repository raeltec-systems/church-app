---
title: 'Prove password-session trust and no-SMS provider behavior'
type: 'feature'
ticket: '2'
created: '2026-10-03'
status: 'done'
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

**Always:** Only project `szfyfezfvxyuvovnnakr`; synthetic accounts (phones only from ranges reserved as fictional, e.g. `+1 202 555 0100–0199`; never a guessed "test" range inside a live national plan such as Zambia's `+260…`; `israelmuyoba+bicauth-<tag>@gmail.com`). Publishable key only, from env at run time. Evidence redacts JWTs to header + needed claims, never stores access/refresh tokens, OTPs, link tokens or passwords. Harness state with live tokens stays in the OS temp dir. Predicate requires a `password` entry in signed `amr` and a live `auth.sessions` row for `session_id`.

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


**Owner decisions (2026-10-06, renegotiated by the owner):**
- Synthetic phones: the original `+26097…` "test range" was an unresearched assumption; Zambia's +260 plan has several live operator ranges (e.g. 97/96/95/77/76/57). Tests use only reserved fictional ranges. The product itself is not Zambia-only: sign-in numbers are any country code in international format (FR, design contract: "+260 is an initial country-picker presentation"); validation must not assume Zambian operator prefixes.
- F1 accepted as an identity-epic constraint: a phone `/otp` with create_user can register any number and leave a server-side session carrying `password` AMR without tokens reaching the caller. Member access therefore requires the staff-approved binding (AD-3), never AMR alone, and staff need a way to reclaim a number registered by someone else (2.1/2.2/2.5).
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
- [ ] `evidence-1.2/` -- version, settings, per-scenario JSON and summary. Email track on hosted (2026-10-03) and LOCAL; phone track on hosted (2026-10-06, steps `H00`–`H98`) after the owner's Management API change; owner readback in `owner-management-api-readback.txt`. Open: owner acceptance of F1 (phone `/otp` row only partially met) and of the phone-range change.
- [x] `tools/auth-harness/` hosted phone track -- `signup --no-password`, read-only `sql/observe_{phone_sms_state,auth_sms_attempts,auth_audit_actions,cleanup_1_2_phone_run}.sql`, the executed `sql/cleanup_1_2_phone_run.sql`, `scenarios/1.2-hosted-{a-phone,b-email-alias,c-recovery,d-signup-link}.txt` (owner inbox masked as `<inbox>`, expanded by `run-script.mjs` from `HARNESS_INBOX_LOCAL`).
- [x] `tools/auth-harness/` LOCAL target -- `HARNESS_TARGET=local` (exact `http://127.0.0.1:54321`), `local-mailpit-link.mjs`, `local-auth-logs.mjs`, `sql/local/observe_local_*`, `sql/local/10_local_api_probe_wrappers.sql`, `scenarios/1.2-local-rerun.sh`, plus unit tests for the local guard.

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

- **LOCAL rerun (2026-10-03, resumed build; owner direction pending, parent chose the reversible "local now, hosted parity later" option).**
  - **Authorisation:** the parent authorised this builder, as the only one running, to use the local Supabase stack. The frozen "Only project `szfyfezfvxyuvovnnakr`" boundary is not renegotiated. The local run is labelled LOCAL throughout, kept in a separate log, and treated as supporting evidence, not hosted proof.
  - **Decision (agent, under owner pre-approval):** the harness gained a separate `HARNESS_TARGET=local` origin rather than a widened hosted guard. Each target accepts only its own exact origin, and unit tests cover both directions.
  - **Finding (blocking):** Supabase CLI 2.119.0 refuses to enable phone without an SMS provider. With `[auth.sms] enable_signup = true` and no provider it prints `WARN: no SMS provider is enabled. Disabling phone login` and sets `GOTRUE_EXTERNAL_PHONE_ENABLED=false`. Its condition needs `twilio`, `twilio_verify`, `messagebird`, `textlocal` or `vonage` to be **enabled**; a hook or test OTPs would not satisfy it. Per the brief, nothing was configured to get past it.
    - Evidence: `evidence-1.2/local-cli-phone-gate.txt` and log steps `L00`, `L10`–`L14`.
    - Both config surfaces tried (the hosted dashboard and the local CLI) now refuse. GoTrue itself was not tested with phone on and no provider. That would need a direct env override on the auth container, which was not authorised and was not done.
    - This is an **AD-20 risk at the configuration-surface level**. It is not yet a GoTrue-level contradiction.
  - **Email track re-captured on LOCAL GoTrue v2.197.0** (the same version as hosted, with identical probe definitions by md5). This covers the legacy steps 22/23 (`L20`–`L24b`), and probe plus refresh of **every** other session after both the password change (`L60`–`L64`) and the recovery reset (`L70`–`L80`). All results match the hosted findings, and the local GoTrue log has 0 SMS mentions (`L91`).
  - **`supabase/config.toml`:** the change was temporary (`[auth.sms] enable_signup = true`; `[auth.email] enable_confirmations = true` for hosted parity) and was reverted. The commit leaves the file unchanged, because the sms flag has no effect under this CLI and only adds a warning.
  - **Local clean-up and checks:** `supabase db reset` removed the harness objects. `npm run db:test`, `db:smoke` and `recovery:rehearse`, the harness tests, `scan-evidence.sh`, `ci:secrets`, `ci:policy-test` and `ci:migrations` all pass.
  - **Hosted parity (named gate, not dropped): identity/production gate "AD-20 hosted phone provider without SMS".**
    - **Owner step:** Management API `PATCH https://api.supabase.com/v1/projects/szfyfezfvxyuvovnnakr/config/auth` with the owner's own personal access token, and this body: `{"external_phone_enabled": true, "sms_autoconfirm": true, "hook_send_sms_enabled": false, "mfa_phone_enroll_enabled": false, "mfa_phone_verify_enabled": false}`.
      - The body sets no `sms_provider`, no `sms_*` provider credential fields and no `sms_test_otp`.
      - Verify with `GET` on the same URL, then with `/auth/v1/settings`.
    - **If the API refuses** without SMS credentials: escalate to an architecture decision on AD-20, for example a different identifier model or an accepted SMS provider. Do not configure one inside 1.2.
    - **If it succeeds:** run the "Still owner-gated" list in `evidence-1.2/README.md` with the hosted harness.

- **Hosted phone track (2026-10-06, resumed build after the owner's Management API PATCH).** Details and step citations: `evidence-1.2/README.md`, "Hosted phone track".
  - **Owner-supplied evidence:** the owner's `GET …/config/auth` readback (`external_phone_enabled:true`, `sms_autoconfirm:true`, `sms_provider:"twilio"`, `sms_test_otp:null`; owner states no credentials were set) is recorded verbatim and labelled owner-supplied in `evidence-1.2/owner-management-api-readback.txt`. `"twilio"` is the default label. The harness corroborated it (`H00`); every phone `/otp` returned 500 "Unable to get SMS provider", logged as "missing Twilio account SID" (`H20`, `H21`, `H39`, `H68`, `H73`).
  - **Decision (agent, under owner pre-approval; owner acceptance requested):** synthetic phones use the NANP fictional range `+1 202 555 0100–0199`, not the `+26097…` named in the frozen block, because `+26097` is a live Zambian mobile range. The frozen block is unchanged; the deviation is listed in `blocked_reason`.
  - **AD-20 holds for phone+password, with F1 as an open constraint.** Phone+password signup and login give `amr=[password]` sessions that pass the predicate; wrong password and unknown phone get the same `invalid_credentials`; passwordless `/signup` is refused; no SMS was sent (`H72`, `H73`, `H96`, `H97`; "0 successful sends" is inferred from every SMS-channel request ending 500 with a provider error). The configuration-surface risk of 2026-10-03 is resolved: the Management API accepts phone without an SMS provider, while the dashboard and local CLI do not. Production must use the same API step.
  - **Matrix row "Phone OTP" is only partially met (F1).** `/otp {phone, create_user:true}` (`H21`) returned 500 and no tokens, but `H25` shows a phone-confirmed user and a live `auth.sessions` row whose AMR claim is `password`, although no password was supplied. On this path `amr=password` does not prove a user-supplied password, so the identity predicate must not rely on AMR alone: it needs the app-side, staff-approved binding (AD-3). Since `sms_autoconfirm` lets anyone register any number, staff also need a number-reclaim path.
  - **Same account and alias (`H30`–`H38`, `H70`, `H95`):** `PUT /user {email}` from a phone session, then the emailed link, gave the same `sub`, identities `[email, phone]` and one user; the email-change session is `amr=[otp]` and denied. A pending address produced no recovery audit event (`H31`, `H95`); non-delivery is inferred. The verified email with the same password signs in to the same user with `amr=[password]`.
  - **Every session probed and refreshed** after the password change (`H41a`–`H45b`) and after the recovery reset (`H56a`–`H59b`): all others revoked (`session_live=false`, `/user` 403, refresh `refresh_token_not_found`); the changing session and the recovery session survive; the recovery session stays denied until logout (`H65`–`H67`).
  - **Signup-link scenario reproduced on hosted with `…+bicauth-e2`** (`1.2-hosted-d-signup-link.txt`): legacy lines 5–6 → `H83`–`H86`; row-8 signup-link gap → `H87`–`H91`; SMS-log check → `H92` (window end later than capture; superseded by `H96`/`H97` with fixed bounds 17:03:30–18:03:40Z). It is a reproduction on a new account, not evidence about the original `e1` sessions. Paced past the 2-per-hour SMTP limit (`H80` refused 429).
  - **Cleanup (`H93`, `H94`, `H98`):** the scoped delete in `sql/cleanup_1_2_phone_run.sql` removed this run's 3 synthetic users and 2 probe rows. `H94`: 0 phone users, tokens and factors. `H98`: 0 run users or orphan probe rows left; `e1` and the 17 story-1.3 accounts still present. The harness state dir and the scratch link files were removed.

## Plan Change Log

- 2026-10-06, review fixes (coordinator review of the hosted phone run). Phone `/otp` row downgraded to partial (F1); status `blocked` pending owner acceptance of F1 and the phone-range change. Added audit and cleanup observations (`H95`–`H98`), committed the executed cleanup SQL, narrowed SQL comments, corrected the `H92` window, labelled reproduced rows, masked the owner inbox in scenario files and extended the scan to them, and fixed `signup --no-password` evidence/state. The frozen block is unchanged.
- 2026-10-06, resumed build (hosted phone track). The owner's Management API change cleared the configuration gate. The former "Still owner-gated" list ran on hosted. Added harness `signup --no-password`, read-only observation queries and four hosted scenario files. The phone range moved to the NANP fictional range (Decision above). The frozen block is unchanged.

- 2026-10-03, resumed build (LOCAL rerun). The local stack was used under parent authorisation. The local CLI phone gate is recorded as the blocking finding. The email-track gaps (legacy 22/23, and the every-session probe and refresh after revocation) were closed on LOCAL. The hosted owner step changed from the dashboard to the Management API. The frozen block is unchanged.

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

**Pass 1 (quick lens, independent reviewer), 2026-10-03.** Verdicts: high 2 · medium 5 · low 3 · false 0. All 10 were patched. Evidence gaps that need new live captures go into the owner-gated rerun. Until then the README is corrected to match the log.

| # | Finding | Verdict | Route | Evidence / action |
|---|---------|---------|-------|-------------------|
| 1 | The project guard is a substring match, so lookalike hosts receive keys and passwords | high | patch | `run.mjs:99`, `:177`. Fix: strict https plus an exact hostname check. |
| 2 | The probe SQL file leaves anon EXECUTE on `harness_whoami`, and the file differs from the hosted state | medium | patch | Revoked from public only. Fix: revoke from anon too and match the hosted state. |
| 3 | The `session_live` diagnostic and the predicate disagree on `not_after` | low | patch | Align the diagnostic with the predicate. |
| 4 | Log lines 5–6 come from an uncommitted harness version | medium | patch (rerun) | Recapture them or mark them legacy. |
| 5 | README rows 8, 11 and 16 overstate the log; `/otp` 422 is the no-user path | high (evidence integrity) | patch (rerun) | Correct the rows now. The rerun probes every session and exercises `/otp` for the existing phone user. |
| 6 | Manual note lines are presented as observations | medium | patch | Use a captured query or log subcommand. |
| 7 | The CI evidence scan misses refresh tokens, OTPs, passwords and link tokens | medium | patch | Extend the patterns so CI enforces the AC. |
| 8 | The state file uses a predictable path, its mode is set only on creation, and it follows symlinks | medium | patch | Fix: `mkdtemp` 0700, exclusive no-follow open, and cleanup. |
| 9 | The link token is passed as a CLI argument | low | patch | Fix: read it from stdin or a file. |
| 10 | The full owner email address is committed in the README | low | patch | Mask it consistently. |

## Verification

**Commands:**
- `node --test tools/auth-harness/*.test.mjs` -- expected: all pass
- `grep -rE 'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{10,}' evidence-1.2` -- expected: no matches
- `bash tools/auth-harness/scan-evidence.sh` -- expected: clean
