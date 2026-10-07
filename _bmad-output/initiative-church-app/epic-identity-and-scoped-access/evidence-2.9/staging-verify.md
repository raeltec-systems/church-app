# Story 2.9 — staging verification (tmurpotfluignacfueki, 2026-10-07)

Synthetic data only; fictional numbers +1 202 555 01xx. No password, grant secret, digest or request code recorded.

## Setup

| Step | By | Result |
|---|---|---|
| Migration `20261007140729_assisted_recovery` | parent (MCP `apply_migration`) | applied; all story 2.9 functions identical to local |
| Principal `identity-assisted-recovery` (purpose `identity_assisted_recovery`) | parent | created |
| Credential minted on the owner's machine; digest registered (30 days, expires 2026-11-06) | owner mints, parent registers digest | done; parent never saw the credential |
| Edge Function secret `IDENTITY_RECOVERY_SYSTEM_CREDENTIAL` | owner (dashboard) | set |
| Edge Function `identity-assisted-recovery` (verify_jwt false; callers authenticated by the grant / the database-checked credential) | parent (MCP deploy) | deployed; answered `unavailable` (503) before the secret, `closed` (200) after |

## Adversarial run against staging Auth (`stg29` script, a fresh synthetic member +12025550161)

| # | Check | Result |
|---|---|---|
| S0 | Synthetic member signs up, applies, Admin approves | pass |
| S1 | Help request accepted with an 8-character code | pass |
| S2 | Request for a number with no account gets the same neutral answer | pass |
| S3 | Admin opens a case and issues the grant; no secret, digest or code in Admin responses | pass |
| S4 | Device status: `ready` | pass |
| S5 | Wrong grant secret rejected | pass |
| S6 | Correct secret + new password: `succeeded` | pass |
| S7 | Same grant again: rejected (single use) | pass |
| S8 | Session from before the reset: 401 | pass |
| S9 | Old password refused; new password works; a fresh sign-in has access once past the 5-second trust-epoch margin (an immediate sign-in inside the margin is refused by design) | pass |
| S10 | A grant presented with another member's number is burned; the right number then also fails | pass |
| S11 | Password unchanged after the burned grant | pass |

Uncertain/stuck/reconcile paths and the per-client limit are proven on the local stack (`assisted.mjs` 16/16).
Reconciliation's session revocation on staging needs the owner's paste of `20261007160100`.

## Owner follow-up

Rotate the credential before 2026-11-06 (runbook "Hosted", step 2.4). Test member +12025550161 is part of the
synthetic-user cleanup.
