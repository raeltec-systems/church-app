# Evidence: story 2.8, change credentials under review and hold access

All runs are LOCAL (Supabase CLI stack, GoTrue v2.197.0, Mailpit catching email; nothing left the machine), 2026-10-07, with SYNTHETIC numbers (+44 7700 900300–900359) and `@example.test` addresses. Nothing was run against a hosted project; no SMS setting exists or was touched.

| File | What it shows |
|---|---|
| `credentials-e2e.jsonl` | `tools/identity-e2e/credentials.mjs`, 15/15 (after the review fixes), through real GoTrue, PostgREST and Mailpit (redacted: statuses, codes and booleans only) |
| `live-adapter-check.txt` | `tools/identity-e2e/live-credentials-check.sh`, C1–C4: the real Dart adapters (C4: a lost-device hold is not released before the member's reset) (credential repository, command gateway, password re-check, grants and summary reads) |
| `local-pgtap.txt` | `npm run db:test`: 1121 tests, including `credential_review_test.sql` (125) |
| `local-api-smoke.txt` | `npm run db:smoke` story 2.8 lines (phone provider off, CLI default config) |

Client widget tests: `packages/client_core/test/identity/credential_review_test.dart` (24: help screen and review gate, sign-in details, Admin credential review), plus the shell tests in `apps/mobile/test/mobile_app_test.dart` and `apps/staff/test/staff_app_test.dart` (story 2.8 cases).

## The verify bullet, row by row

| Verify bullet | Evidence |
|---|---|
| Change a username under review (API and both clients) | E2E `C10` (request with a fresh sign-in; access unchanged until approval; a member cannot approve; Admin approves after an identity check; older sessions and refresh refused; the old number fails; the new number + same password is granted); live `C1`–`C2`; pgTAP "Phone username change"; widgets (mobile request, staff approve) |
| Change a recovery email under review | E2E `C20`–`C22` (replacement: old address leaves Auth, account in review, one confirmation link to the new address only, approval; removal); pgTAP "Recovery email replaced / withdrawn / removed"; widgets |
| Place and remove a hold | E2E `C30`, `C32`, `C40`–`C41`; live `C3`–`C4`; pgTAP "Holds" and "Lost device"; widgets (staff place/release) |
| A direct Auth change, forgot password, login, reset or email verification never clears a hold or approves a binding | E2E `C31` (`/recover` + reset + fresh login under a hold: still `review_required`; an Auth Admin phone change: hold still open, binding review pending), `C32` (release leaves the binding in review; only restore approves), `C20` (email verification approves nothing, the unapproved address cannot reset); pgTAP "Nothing but an authorised release clears it" |
| Held sessions see only the help screen | E2E `C30` (`403 review_required`; the own read answers generically, no reason keys); live `C3`; widgets (gate on every private route, mobile and staff shells) |
| Revoked sessions lose private access | E2E `C10`, `C40`, `C50` (`401 untrusted_session`, refresh refused); live `C2`, `C3`; pgTAP (`auth.sessions` rows gone) |
| Lost device calls registered device-registration hooks | E2E `C40` (SYNTHETIC `app.fixture_record_lifecycle` on `access_hold_applied`, same transaction), `C32` (`access_hold_released`); pgTAP |
| Stolen-session `PUT /user` email change (2.7 carried risk) | E2E `C50` (review; Admin restore removes the address and revokes the thief's session; the member signs in again) |
| A reviewed path for 2.7 `other_changes` | E2E `C60` (approval refused `other_changes`; restore waits for the pending proposal; reject, then accept the changed number); pgTAP (MFA factor: accept refused, restore removes it) |
| No SMS | E2E `C99`; smoke |
| Review fix HIGH: a reset link issued before a restore or a reject is dead | E2E `C70` (restore; 2.8 replacement reject); pgTAP (restore, 2.7 reject, 2.8 revert: no matching token in `auth.users` or `auth.one_time_tokens`) |
| Review fix: password changed by a stolen session | E2E `C51` (accept refused `password_unreviewed`; restore keeps a security hold; release refused `password_reset_required` until the member's own email reset); E2E `C41` and pgTAP for the lost-device hold |
| Review fix: approve/accept/withdraw while held | pgTAP (`conflict {"member_id": "held"}`; withdraw `forbidden`) |
| Review fix: device hooks | `sessions_revoked` (new v1 event) on approve, restore, accept and lost-device holds: E2E `C10`, `C32`, `C40`; pgTAP, including a raising hook rolling back the lost-device hold and the restore |
| Review fix: generic own reads while in review | pgTAP (`identity_my_credentials` and 2.7 `identity_my_recovery_email` carry no phone or address); E2E `C20`, `C30`, recovery `X13` |
| Review fix: fail-closed stub | pgTAP (stub body in place: approval answers `unavailable`, nothing changes) |

## Findings

1. **`double_confirm_changes` stays on.** A replacement therefore removes the old address server-side first, so the new one is confirmed alone and the old address is never required; the account waits in review, as a 2.7 addition does. It also keeps a stolen session from moving an approved recovery email.
2. **Auth writes happen inside the Admin command.** The 2.2 triggers record each write and move the account into review; the binding revision recorded in the same transaction lifts it again. Session, factor and identity row deletions live in `20261007160100` (applied by hand on hosted); without it those commands answer `unavailable`.
3. **Release moves the trust epoch.** Sessions opened during a hold (for example on a lost device) must sign in again after the release (pgTAP, E2E `C41`).
4. **Device registrations.** The new contract v1 event `sessions_revoked` (SQL list, fixtures, Dart, TypeScript) is dispatched with every session revocation; holds also dispatch `access_hold_applied`/`access_hold_released`.
5. **Residual risk.** A stolen session can still change the password (`secure_password_change` off). After the review fixes a restore then keeps a security hold until the member's own reset; members without an approved recovery email wait for staff-assisted recovery (entry 9) (deferred-work).
7. **Contract gap (pre-existing, reported).** The shared v1 contract allows only 11 field-error codes, so the real Dart client maps any refusal carrying a domain code (2.5 `last_admin`, 2.7 `reauthenticate`, 2.8 `password_reset_required`, ...) to an unknown outcome; widget tests use fakes and miss it. Live check C4 shows it. Not changed here.
8. **Regressions (after the fixes).** `run` 30, `grants` 18, `review` 18, `apply` 27, `cells` 13, `recovery` 20 (X13 now expects no address in review): all pass.
6. **Phone switch.** Found off; on only for the E2E and the live adapter check; off again.
