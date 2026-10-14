# Evidence: story 2.9, staff-assisted recovery with a single-use grant

Plan: `../story-recover-access-with-staff-assistance-and-a-single-use-grant-plan.md`. Runbook: `docs/runbooks/identity-access.md`, section "Staff-assisted recovery with a single-use grant (story 2.9)".

All runs are LOCAL (Supabase CLI stack, GoTrue v2.197.0, edge-runtime v1.77.1), on 2026-10-07, with synthetic fictional numbers only. No hosted project was touched. No SMS provider, hook, test OTP or SMS MFA exists. The phone switch was on only for the E2E and the live check, and is off again.

## Files

| File | What it shows |
|---|---|
| `assisted-e2e.jsonl` | `tools/identity-e2e/assisted.mjs`: 16/16 checks through real GoTrue, PostgREST, the system route and the served Edge Function. Statuses, codes and booleans only. |
| `live-adapter-check.txt` | `tools/identity-e2e/live-assisted-check.sh`: the REAL client adapters (`SupabaseAssistedRecoveryGateway` on the phone, `SupabaseCommandGateway` and `SupabaseRecoveryCasesRepository` on staff web, `SupabaseAccountAuthGateway`, `SupabaseMemberAccessRepository`), R1 to R4 pass. |

## The verify bullet, row by row

| Case | Evidence |
|---|---|
| A valid grant works once | E2E `A10` (redeem `succeeded`, replay `rejected`); live `R3`; pgTAP `assisted_recovery_test.sql` |
| Fresh password sign-in is required | E2E `A10` (old session 401, old refresh token refused, old password 400, new password sign-in with `password` AMR granted); live `R4` |
| An unused grant after reissue | E2E `A11`; pgTAP |
| A direct password change | E2E `A12` (native `PUT /user`); pgTAP (generation moved: `superseded:stale`) |
| Relink or deactivation | E2E `A13` (unlink kills the grant), `A16` (relink refused while unresolved), `A17` (relink possible after reconcile); pgTAP |
| Concurrent redemption | E2E `A14`: 6 parallel redemptions of one grant through the function: exactly one `succeeded`, exactly one password signs in, one operation |
| Cross-member use | E2E `A15`: another member's case cannot bind the request (`mismatch`); the grant presented with another number is rejected and burned |
| An uncertain or late Auth result | E2E `A16`: a lost Auth answer is `uncertain`; the account stays held (`review_required`) even after the Auth change applies late; the late completion is recorded only; no new grant until reconciled; reconcile signs out every session and keeps the hold. pgTAP also covers a pre-dispatch session surviving, a stuck operation, an obsolete pending operation and an Auth refusal (`failed`) |
| Cancel between begin and dispatch (review fix) | E2E `A21`: the case is cancelled after begin; dispatch is refused, no password applied, the operation obsolete; pgTAP also covers a case closed under a dispatched operation (no success effects, hold kept) |
| Deactivation (review fix) | E2E `A22`: deactivated after begin, dispatch refused; deactivated during an open case, no grant. pgTAP also covers deactivation after dispatch (uncertain, hold kept) |
| Binding revision and pre-reset sessions (review fixes) | pgTAP: a binding revision moved after begin refuses dispatch; a session created after dispatch but before the password change keeps the outcome uncertain and the account held |
| Request flooding and body size (review fixes) | E2E `A23`: 12 concurrent requests for one number, exactly 5 received (advisory locks); a 5 KB body is refused with 413. The per-client limit is A24 |
| Per-client limit (owner decision 2026-10-07) | E2E `A24`: 10 requests from one client address accepted, the 11th `rate_limited`; another address accepted; a redeem attempt from the limited address `rate_limited` (grant untouched); 10 requests with unparseable addresses accepted and the 11th limited (shared `unknown` bucket); only keyed hashes stored. pgTAP and node tests cover the same |
| Holds stay | E2E `A18`: a lost-device hold survives the reset, and its release is allowed only after it; a dispute hold refuses recovery |
| Expired grant | E2E `A19`; pgTAP |
| No password or usable grant in staff screens, responses or logs | E2E `A20`: every password, grant secret and digest of the run was searched for in all staff answers, all device answers, the recovery tables and the system audit/receipts, and in the logs of the function, GoTrue, PostgREST, Kong and Postgres: 0 hits. Staff answers also hold no request code. Widget tests check that no `arg_` secret is ever shown |

## Not run here (staging)

- The same matrix against staging Auth needs the parent's apply of `20261007140729`, the owner's staging credential and Edge Function secret, and the function deployment (runbook "Hosted"). Then repeat the `assisted.mjs` cases with synthetic numbers on staging.
