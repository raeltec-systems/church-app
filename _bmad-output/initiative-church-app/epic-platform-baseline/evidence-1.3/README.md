# Evidence 1.3: fenced staff recovery across the Auth boundary

- **Project:** `bic-kafue-auth-test` (`szfyfezfvxyuvovnnakr`). Synthetic accounts only: `…+bicauth-r13-x-*@gmail.com`, created by Auth Admin with `email_confirm`. The only emails sent were the 2 Secure-email-change mails for steps `203`/`204`.
- **Observed:** 2026-10-03, 14:38–14:51 UTC. GoTrue **v2.197.0** (step `05`), Postgres **17.11** (step `03`).
- **Raw log:** [`harness-log.jsonl`](harness-log.jsonl), one redacted JSON line per harness call, keyed by `step`. Ids are digests (`h:` + 10 hex). Grant secrets, operator token, passwords and tokens are never written; `scan-evidence.sh` enforces this in CI.
- **This log replaces the earlier one in full.** That run (function v1–v3, SQL before `008`) is in git history only. Nothing here relies on it, including the v1/v2 server-created sign-in session used for revocation (removed in v3).

## Provenance of this run (code under test = committed code)

| What | Start | End |
|---|---|---|
| Edge Function `harness-recovery` | step `02`: version **4**, `verify_jwt: true`. The sha256 of the deployed `index.ts` and `logic.mjs` (from `get_edge_function`) **equals** the committed files (`34c6b27f…`, `35529901…`). | step `300`: still version 4 with the same `ezbr_sha256` (`list_edge_functions`). The `same_version_and_ezbr_as_step_02` field in that line was added by the operator. |
| Hosted SQL (`001`–`004` = migrations `auth_harness_001`–`008`) | step `03`: per-function and per-trigger `md5` and grants. Every value equals step `04`, which is the committed files applied to a local Postgres 17.11 container. | step `301`: hosted combined digest `f26c2bb6…` (22 functions, 4 triggers) equals step `302` (the committed files). |

The function's own `version` action (step `01`) could not read its source on the platform (`unavailable`). The `get_edge_function` comparison above is the source check.

Commits after the run touched only harness recording, not the function or the SQL:
- `rc-call` now masks `login_email` in what it records. The one affected line (step `32`) was masked after capture; that is its only edit.
- `scan-evidence.sh` now skips `scenarios/`.

## Mechanism under test (harness model of AD-20)

- **Generation** (`harness.rc_account.generation`). It advances on:
  - grant issue;
  - security hold;
  - relink;
  - reconcile;
  - every credential or binding change detected by the triggers.

  A grant is valid only at the exact generation and link revision it was bound to.
- **Trusted detection.** Triggers run inside GoTrue's own transaction:
  - `auth.users`: password, email or phone change, and user delete;
  - `auth.identities`: insert or delete;
  - `auth.mfa_factors`: insert, delete, or a change to `status` or `secret`.

  A binding change (email, phone, identity, MFA, delete) sets `binding_review_required`; delete also sets a hold. A change with no op in flight, on an account whose op is uncertain or was reconciled less than an hour ago, re-opens that op and sets reconcile-required and a hold.
- **Requests.**
  - The member device sends the digest of a secret it generated, plus the login it claims.
  - Staff can bind a request only to the account whose **approved** login matches.
  - A request is single-use, expires after 30 minutes, and is rate limited.
- **Grants and redemption.** Redemption checks against the approved login, never the live Auth email. A hold or a pending binding review refuses both issue and redemption.
- **One unresolved op per account**, enforced by a partial unique index. The account stays blocked until the op is done, or until staff expire it (stuck) or reconcile it.
- **Dispatch** is fenced by generation and records `sessions_at_dispatch`.
- **Completion.**
  - `succeeded` needs all of: Auth reported the apply; exactly one password-only change since dispatch; zero live sessions created before dispatch.
  - `failed` needs a definitive 4xx **and** zero changes.
  - Anything else, including a malformed outcome, is `uncertain`.
  - A late completion, or one on an already finished op, is appended to `late_outcomes` and changes nothing.
- **Reconcile** applies to an `uncertain` op only. It is refused while any session created before dispatch is live. Staff can force it with `force_revoke`: an Auth Admin set of an undisclosed random password, which logs out every session. Reconcile clears `reconcile_required` (**not** the security hold) and sets a trust epoch: only sessions created after it pass the gate.
- **Gate** (`harness_recovery_probe`): all of
  - 1.2's trusted password session;
  - the session was created at or after the trust epoch;
  - no hold;
  - no unresolved op;
  - no pending binding review.
- **Caller authentication.**
  - Platform `verify_jwt` checks the signature.
  - The function refuses any other project ref, URL or issuer.
  - Every call needs the operator token, checked by digest.
  - Staff actions need a trusted password session of an account enrolled **out of band** by SQL (step `15`). The operator token cannot create staff (step `11`).

## Results

| Run | Result | Steps |
|---|---|---|
| Happy path with real pre-dispatch sessions | 3 live sessions at dispatch → op `succeeded` with `pre_dispatch_sessions_live: 0`. Old session dead (probe and refresh fail), old password `invalid_credentials`, fresh login passes the gate. Revocation is done by the Auth Admin password update itself. | `40`–`50`; DB `299` (ma op 1) |
| Unused grant + direct password change | The native change advanced the generation and superseded the grant; redemption is rejected. | `55`–`59` |
| Superseded grant | Reissue supersedes the older grant. | `60`–`64` |
| Replay / expiry | A consumed grant is rejected; a 1 s grant is rejected after expiry. | `51`, `72`–`74` |
| Cross-member | A grant used with another member's login is rejected and burned (the owner's retry also fails). A request claiming member B is refused for account C (`request_for_other_account`), and B's link is refused for account C (`link_mismatch`). The request binds once to B; a second bind is refused (`request_not_open`). | `65`–`71` |
| Definitive Auth failure | Weak password with no change in the window → `failed`. | `77` |
| Admin 4xx **with** a change in the window | Admin `weak_password` plus a concurrent native change → `uncertain`, not `failed`. Reconcile is refused (pre-dispatch session live) until `force_revoke`; the old session is then dead. | `118`–`121`; DB (md op 3) |
| Holds | A hold supersedes the issued grant; redemption and new issue are refused while held; the gate is denied; issue works after release. | `80`–`89` |
| Concurrent resets | 8 parallel redemptions: exactly one `succeeded`, 7 `grant_rejected`; old session dead. | `93`, `94` |
| Pending op + native change | Dispatch is fenced → `obsolete`, no Auth call. Relink is refused while the op is pending. | `100`–`106` |
| Native change racing a dispatched op | Two changes in the window → `uncertain`; relink is blocked until reconcile. | `112`–`114`; DB (md op 2, `changes_since_dispatch: 2`) |
| Lost response | Caller gets 504 `unknown`; op `uncertain`. A fresh login with the applied password is denied (`reconcile_required`); relink and issue are blocked. After reconcile, a session from before the reconcile is denied (`session_after_trust_epoch:false`) and a fresh login is allowed. A grant issued before a relink dies. | `130`–`144` |
| Late outcome while uncertain | The late completion is recorded (`late_outcome_recorded`). Replay of an unfinished op is refused (`not_finished`). | `152`–`154` |
| Late outcome **after** reconcile | Staff reconcile before Auth applies; Auth applies 8 s later. The trigger re-opens the op as uncertain and holds the account (`late_change_reopened_op`), and the gate denies. A second reconcile (forced) leaves the hold in place. | `160`–`167`; DB (mh) |
| Stuck ops | Pending: `expire_stuck` is refused before 30 s, then the op is abandoned (`obsolete`). Dispatched with a crashed worker: the gate is denied while in flight; after 30 s the op is timed out to `uncertain`; reconcile is refused (session live) until `force_revoke`. | `170`–`183` |
| Stale completion | Replaying a finished op's **recorded** outcome is rejected (`stale`) and appended to `late_outcomes`. | `52` |
| Binding: native email change | Both links confirmed → trigger sets binding review. The gate is denied; the old grant is rejected; issue is refused; staff relink approves the new login; then issue and redeem with the new login succeed. | `200`–`212` |
| Binding: native MFA (TOTP) enrolment | Binding review: the gate is denied and issue is refused until staff relink. | `190`–`196` |
| Binding: user deleted (Auth Admin) | Delete and identity-delete events; the account is held and in binding review. | `197`; DB (mg) |
| Caller authentication | See the table below. | `11`, `14`, `20`–`32`, `39` |
| No secret in output or logs | The evidence scan is clean. Platform logs for the run window show 0 matches for each value type in the message **and** all metadata attributes (URL, path, headers, JWT fields), including URL-encoded forms. The `x-harness-operator` header was never logged. | `303` |

### Caller authentication

| Case | Expected | Observed |
|---|---|---|
| No `Authorization` (publishable `apikey` only) | refused | 401 from the **function** (`foreign_or_unsupported_token`): the platform let it through, so the function's own check is what refuses it (`21`) |
| Unsigned JWT claiming this project / another project | 401 | 401 `UNAUTHORIZED_LEGACY_JWT` from the platform (`22`, `23`). No genuinely signed token from another project was used. |
| No operator token | 401 | 401 `operator_required` (`24`) |
| Staff action with anon key / by member session / before staff enrolment | 403 | 403 (`25`, `26`, `14`) |
| Member action with a user session | 403 | 403 `requires_anon` (`27`) |
| Other project ref or URL in body | refused | **400** `wrong_project` (`28`, `29`), by design: the body is invalid for this project |
| Bad tag / unknown action | 400 | 400 `validation_failed` (`30`, `31`; a bad tag no longer returns 500) |
| Operator token tries to create staff | 403 | 403 `staff_enrolment_out_of_band` (`11`) |

Step `39` covers the window of steps `21`–`32`: **0 Auth Admin requests**. The platform's function edge log holds only 9 of those 12 function requests, so the logs are incomplete; the 0 is the count of logged Admin requests.

## Findings

1. **Auth Admin password update revokes every session (v2.197.0).** `adminUserUpdate` runs `UpdatePassword(tx, nil)`, which logs out all of the user's sessions. The completion fence does not rely on this: it verifies it (`sessions_at_dispatch` > 0, then `pre_dispatch_sessions_live: 0`). An amendment to the frozen block is with the owner.
2. **Detection is count-based.** An Admin apply and a native change look the same, so any ambiguity is `uncertain` (`112`, `118`).
3. **Reconcile is still a staff decision.** The DB enforces revoked pre-dispatch sessions (or a forced revoke) and a new trust epoch. Identity must define what staff check before reconciling.
4. **The 1.2 session probe alone is not the gate.** Several sessions pass `harness_private_probe` but fail the recovery gate (e.g. `134`, `139`, `165`, `179`).
5. **Platform behaviour.** `verify_jwt` let through a request with only the publishable `apikey` (`21`). The function's own caller check refused it.
6. **Advisors** (after the earlier run; unchanged in kind):
   - `rls_enabled_no_policy` on the `harness.rc_*` tables (intended: no client access);
   - `authenticated_security_definer_function_executable` for `harness_recovery_probe` and `harness_whoami` (own-session facts only);
   - leaked-password protection is off (dashboard setting).

## Not run (owner-gated or out of scope)

- **Phone.** The phone binding change and phone-only reset identifier wait for 1.2's Phone-provider owner step. The `auth.users.phone` trigger branch was exercised only in the local container.
- **Identity link/unlink by a user.** Needs OAuth or phone. Only Auth Admin delete produced identity events live (`197`); the insert path was exercised in the local container.
- **Real-member data, production SMTP, SMS:** never in scope.
