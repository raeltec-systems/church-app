# Evidence 1.3: fenced staff recovery across the Auth boundary

- **Project:** `bic-kafue-auth-test` (`szfyfezfvxyuvovnnakr`), synthetic accounts only (`…+bicauth-r13-*@gmail.com`, created by Auth Admin with `email_confirm`, so **no email was sent** by this story).
- **Observed:** 2026-10-03, GoTrue **v2.197.0** (step `00`), Postgres **17.11** (step `300`).
- **Raw log:** [`harness-log.jsonl`](harness-log.jsonl), one redacted JSON line per harness call, keyed by `step`. Ids are digests (`h:` + 10 hex); grant secrets, operator token, passwords and tokens are redacted and never written (`scan-evidence.sh` enforces it in CI).
- **Database state is captured raw, not transcribed:** steps `79`, `199` and `299` are the output of `public.harness_rc_observe()` (exactly [`sql/observe_recovery_state.sql`](../../../../tools/auth-harness/sql/observe_recovery_state.sql)) returned through the function's staff-only `observe` action. Steps `01`, `300`, `301` and `302` are `attach` lines of committed read-only queries.
- **Harness:** [`tools/auth-harness/`](../../../../tools/auth-harness/README.md); scenarios in `tools/auth-harness/scenarios/1.3-*.txt`.

## Mechanism under test (harness model of AD-20)

| Piece | Where | What it does |
|---|---|---|
| Generation | `harness.rc_account.generation` | Advanced by every recovery event: grant (re)issue, relink, reconcile and **any native credential change**. Grants are valid only at the exact generation and link revision they were bound to. |
| Trusted detection | trigger `rc_auth_credential_change` on `auth.users` | Runs inside GoTrue's own transaction when `encrypted_password`, `email` or `phone` changes: advances the generation, supersedes outstanding grants, records the in-flight op (if any). If it fails, GoTrue's write fails (fail closed). |
| Grants | `harness.rc_grant` | Member device generates the secret and sends only its SHA-256 digest (`rc-request`); staff binds case, member, account, link revision, generation, purpose and expiry (`rc-issue`). One issued grant per account (partial unique index). |
| One in flight | `harness.rc_op` + partial unique index | `begin` consumes the grant and records one pending op under the account lock. Pending/dispatched/uncertain ops block new grants, relinks and overlapping resets. |
| Fences | `harness_rc_dispatch`, `harness_rc_complete` | Dispatch requires op generation = account generation; completion accepts success only if Auth reported the apply, **exactly one** password-only change was recorded for the op since dispatch, and **no session created before dispatch is still live** (DB-verified). Anything else: `uncertain`, access held until staff `reconcile`. Late or replayed completions are recorded, never applied. |
| Privileged Auth | Edge Function `harness-recovery` (`verify_jwt` on) | Only holder of the service key (platform env). Refuses other projects/URLs and foreign tokens, requires a registered operator token, and requires a trusted password session of enrolled staff for staff actions. |
| Private-data gate | `public.harness_recovery_probe()` | 1.2's trusted password session **and** no security hold, no unresolved/uncertain op and no unreviewed binding change. (1.2's `harness_private_probe` is the session half only; where the two differ below, the recovery gate is the full predicate.) |

Function versions: v1 for steps `10`–`75`; v2 (adds `observe`) for `79`–`199`; v3 for `200`+. Hosted SQL: migrations `auth_harness_005` (fence), `006` (observe), `007` (DB-verified revocation). The committed files `sql/002_recovery_fence.sql` + `003_recovery_observe.sql` reproduce the hosted definitions exactly: every function and trigger `md5` at step `300` (hosted) equals step `301` (the committed files applied to a local Postgres 17.11 container).

## Results by required run

| Run | Result | Steps |
|---|---|---|
| Happy path | Member-held secret, staff output has no secret (`staff_output_contains_secret:false`); op `succeeded`; both older sessions dead (probe `session_live:false`, refresh `refresh_token_not_found`); old password `invalid_credentials`; fresh password login passes the gate; generation advanced by the trigger in the op's dispatch window. Re-run on v3 with DB-verified revocation: `pre_dispatch_sessions_live: 0`. | `30`–`38`; `240`–`248`; DB `299` (ma events 7–10; mc events 96–99) |
| Unused grant + direct password change | Member B changes password natively (`PUT /user`, 200); trigger advanced generation 2→3 and superseded the unused grant; redemption rejected (`grant_superseded`). | `50`–`54`; DB `299` (mb events 15–16) |
| Superseded grants | Reissue supersedes the older grant; older redemption rejected. | `60`–`64`; DB (mb events 17–21) |
| Replay / expiry | Consumed grant replay rejected (`grant_consumed`); 1 s grant rejected after expiry and marked `expired`. | `39`, `70`–`72`; DB (ma 11, mc 27) |
| Cross-member | A grant for member B presented with member C's identifier is rejected **and burned**; the owner's retry then fails (`grant_burned`). Staff binding member B to account C is refused (`link_mismatch`). | `65`–`68`; DB (mb 22–23, mc 24) |
| Relink blocked by unresolved work | Relink refused while an op is pending (`94`), while uncertain (`125`) and after the race (`236`); new grant refused while in flight/uncertain (`105`, `127`). After `reconcile`, relink succeeds (link revision 2, generation +1) and the grant issued before it is dead (`131`, `grant_superseded`). | `94`, `105`, `125`–`131`, `236`; DB (ma 65–71, md 47, 54, 120) |
| Concurrent resets | 6 (v2) and 8 (v3) parallel redemptions of one grant: exactly one `succeeded`, all others `grant_rejected`; DB shows one op and `grant_consumed` rejections. | `83`, `222`; DB (mc 35–43, 102–112) |
| Pending op + native change | Op begun, member changes password natively, then resume: dispatch fenced → `obsolete` with **no Auth call**; account released. | `93`–`97`; DB (md 46–49) |
| Native change racing a dispatched op | Native change lands between dispatch and the Admin call: two credential changes in the window → `uncertain`, access held, relink blocked until reconcile. | `233`–`238`; DB (md 116–121) |
| Injected transport uncertainty (lost response) | Auth applied, caller got 504 `unknown`; op `uncertain`; a fresh password session is still **denied** by the gate (`reconcile_required`) until staff reconcile. | `122`–`128`, `132`; DB (ma 61–67) |
| Late external outcome | Caller times out first (op `uncertain`), Auth applies afterwards: trigger advances generation; the late completion and a replayed one are recorded as `late_outcome_recorded`, never applied; access held until reconcile. | `143`–`147`, `200`–`202`; DB (mb 74–79, 86) |
| Stale completion | Replaying the completion of a succeeded op is rejected (`stale`). | `40`; DB (ma 12) |
| Holds stay effective | Hold applied while an op is in flight (`in_flight:true`); the reset succeeds; fresh password session is denied (`security_hold:true`) until staff release. | `102`–`110`; DB (md 52–58) |
| Definitive Auth failure | Weak password: Admin 422 `weak_password` → op `failed`, no credential change, account released. | `75`; DB (mc 30–32) |
| Caller authentication | No JWT 401; no operator token 401; staff action with anon key 403; staff action by a non-staff member's trusted session 403; member action with a user session 403; other project ref/URL 400 `wrong_project`. All before any Auth Admin call. | `20`–`26` |
| No secret in output or logs | Evidence scan clean (CI). Platform logs for the run window (auth, audit, edge, function, Postgres, PostgREST, pgbouncer): **0** password-, grant-, operator-token-, JWT- or secret-key-shaped values; the function itself logs nothing but boot/shutdown. | `302` |

## Findings

1. **Auth Admin password update revokes every session on v2.197.0.** `adminUserUpdate` calls `UpdatePassword(tx, nil)`, which runs `Logout` for the user in the same transaction. Step `153`/`154` (function v2 skipped its own extra revocation) still found the old session dead. The original plan assumed the opposite; v3 dropped the self-reported revocation, and the completion fence now verifies it in the database (`pre_dispatch_sessions_live: 0`, steps `214`, `244`, `222`).
2. **Trusted detection works at the database boundary.** Every native and Admin credential change of an enrolled account produced exactly one `native_credential_change` event inside GoTrue's transaction (DB `299`). The detection cannot tell an Admin apply from a native change, so attribution is by count in the dispatch window; ambiguity is `uncertain` (step `233`).
3. **Reconciliation is a manual staff decision in this harness.** It clears the hold flag and advances the generation, but it does not itself re-verify Auth state. The identity epic must define what staff check (for example, live sessions and the credential change events) before reconciling.
4. **The 1.2 session probe alone is not the private-data gate.** Fresh password sessions during an uncertain op pass `harness_private_probe` but fail the recovery gate (steps `124`, `146`, `235`). Identity must use the full predicate.
5. **Advisors** (post-run): `rls_enabled_no_policy` for the `harness.rc_*` tables (intended: no client access at all) and `authenticated_security_definer_function_executable` for `harness_recovery_probe` and 1.2's `harness_whoami` (intended: own-session facts only). `auth_leaked_password_protection` is disabled (dashboard setting, Pro plan).

## Harness notes (not observations)

- In phase 1, the evidence key `grant` held the grant *label* and was redacted by the over-broad secret key list; from step `81` the key is `grant_label`. Step names identify the grant.
- Steps `210`/`211` failed with `invalid_credentials` because the local state still held the pre-`gc4-op` password (that op applied a candidate password and stayed uncertain). The happy path was re-run as `240`–`248`.

## Not run here (owner-gated or out of scope)

- **Phone-specific rows** (phone binding change detection, phone-only reset identifier): need 1.2's owner step to enable the Phone provider. The trigger already watches `phone` and sets `binding_review_required`; the live check waits for that step.
- **Native email change detection:** with Secure email change on, a live run costs two Supabase emails plus both confirmations against the ~2/hour sender limit. The trigger watches `email` the same way; run it with the phone rows.
- Real-member data, production SMTP and any SMS configuration: never in scope.
