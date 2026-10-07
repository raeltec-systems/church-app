# Evidence: story 2.12, write and rehearse the restricted identity runbooks

**Plan:** `../story-write-and-rehearse-the-restricted-identity-runbooks-plan.md`.

**Runbooks:** `docs/runbooks/identity-support.md` (RB1-RB8). The fallback mechanics are in `docs/runbooks/identity-access.md`, section "Identity-checked last-Admin fallback (story 2.12, restricted operator)".

All runs are LOCAL (Supabase CLI stack, GoTrue v2.197.0), on 2026-10-07, with synthetic fictional numbers only:

- No hosted project was touched.
- No SMS provider, hook, test OTP or SMS MFA exists.
- The phone switch was on only for the E2E runs and is off again.

## Files

| File | What it shows |
|---|---|
| `runbooks-e2e.jsonl` | `tools/identity-e2e/runbooks.mjs`: 16/16 checks. Statuses, codes, counts and booleans only. The run checks its own evidence for secrets, codes, numbers and addresses (`R101`) |
| `owner-rehearsal.md` | The owner's staging checklist (hitl), for the consolidated owner test |

## The verify bullet, row by row

| Case | Evidence |
|---|---|
| Each runbook can be followed with synthetic records | E2E `R01` (RB1 bootstrap, second Admin by command), `R10`-`R11` (RB2 approve, accountless record, reclaim, explicit link), `R20` (RB3 add, confirm, approve, member-only reset), `R30` (RB5 lost device + RB4 assisted reset + release by a second Admin), `R31` (dispute hold), `R32` (credential review restore), `R40` (RB6 handover-blocked deactivation, reviewed restoration without roles), `R50` (RB7 in-app deletion, worker completes it), `R60`-`R62` (RB8) |
| No step shows a password or usable grant/code to the wrong party | E2E `R90`. Every staff answer (44), every operator output (13; procedures, refusals, worker output) and the function log were scanned for 73 values: every password, grant secret, digest, request code, email link and its token, PKCE verifier and code, member access and refresh token, and system credential. Also scanned for JWT-shaped and bcrypt-shaped strings. 0 found, with a positive control. `R101`: the evidence file holds no secret, code, number or address |
| Admin-only support reaches no care or finance fixture | E2E `R02` (a support account holding only `admin`) and `R62` (the Admin restored through RB8): `fixture_scoped_read` care and finance, and `cells_private_fixture_read`, each `403 not_granted` |
| Last-Admin fallback without a credential shortcut | E2E `R60`: the sole Admin is signed out and cannot sign in; the bootstrap and a fallback with the wrong reason, no identity check, or the operator as its own confirming owner are refused. `R61`: the operator command (with a second owner and a case reference) returns ids and codes only; the member's password hash, `updated_at`, `last_sign_in_at`, phone, email, ban, sessions, refresh and one-time tokens and factors are unchanged; their existing session is Admin at once and an own-password sign-in is Admin; audited with the distinct `admin_fallback_granted` (`identity_access_audit`, `ops_operator_actions`) and `identity_admin_fallbacks` (both owners, case reference). `R62`: the unreachable Admin is brought back through RB4, and their Roles & access read flags the fallback Admin (`admin_via_fallback`). pgTAP `identity_admin_fallback_test.sql` (47): privileges (live and retired tables), rows copied, retention rule, pinned refusal messages (operator, check, reason vs. state, confirming owner empty or the operator, case reference, accountless, unknown, held, in review, dormant, deleted, deactivated, banned, holding a scope, already Admin), nothing written on refusal, no Auth change, both reasons, the roster flag |

## Regressions (same stack, same day, reset before each)

- `db:test`: 17 files, 1482 tests. `db:smoke`: pass.
- E2Es: `run` 30, `grants` 18, `apply` 27, `review` 18, `cells` 13, `recovery` 20, `credentials` 15, `assisted` 16, `lifecycle` 9, `deletion` 12, `runbooks` 16, all passed.
- Offline unit tests 87/87, `contracts:test` 239/239, `ci:secrets` clean, `ci:migrations` (base `origin/main`) pass.
- Review fixes (story 2.12) added the **Admin by operator fallback** label on staff web Roles & access: `flutter analyze` and `flutter test` pass for `packages/client_core` (345) and `apps/staff` (26); `apps/mobile` analyze passes. The Flutter live adapter checks were not rerun (only a parsed flag and a label changed).

## Not run here (owner, staging)

- The parent session applies `20261007193513_identity_admin_fallback.sql` to staging (no row deletions; no owner setting).
- Israel follows `owner-rehearsal.md` on staging.
- Owner names stay `<named owner: fill at entry 14>`.
- Production first-Admin linking has no path yet (RB1); it is an entry 14 decision.
