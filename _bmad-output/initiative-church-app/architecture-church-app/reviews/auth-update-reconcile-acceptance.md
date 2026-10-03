# Authentication update — acceptance reconciliation

Reviewed 2026-10-03. Verdict: **PASS**. No unresolved reconciliation blockers.

## Inputs and method

Compared the current `spec-church-app/acceptance-map.md` with `functional-requirements.md` and `architecture-church-app/architecture-church-app.md`. Also compared the current launch bullets with the unchanged original `brief-church-app/inputs/church-app-v1-spec-1.2.md` to check preservation. This is document reconciliation, not application or provider verification.

## Findings

- AC-01 through AC-23 each appear exactly once, in order. A deterministic line check confirms all 23 source references point to their corresponding current functional requirement, at lines 603–625. Both the original and current functional sources contain 23 launch bullets.
- Only AC-01, AC-03, AC-04, AC-05 and AC-06 change wording. They adopt the approved authentication change and preserve registration approval, accountless participation, stable member identity, session continuity and identity/security testing. AC-02 and AC-07–AC-23 remain verbatim from the original launch requirements. No non-authentication launch test was removed or weakened.
- AC-01/03/04 cover normalized unique unverified phone usernames, user-chosen passwords, signup with email blank, reviewed identity-preserving linking, mobile/web continuity and no SMS. The source and map retain separate church/cell approval and shared-contact safeguards.
- AC-05/06 and the map's Auth verification detail cover optional email verified and approved on the existing Auth account, recovery-only access, neutral errors, email delivery/expiry/replay/redirect checks, and identity-checked no-email staff assistance. Neither a phone claim nor a new/unverified email can recover the historical account. Passwords remain private to the member, and no dummy email/shared login/custom PIN replaces the approved flow.
- AD-3 and AD-20 explicitly require trusted signed password AMR plus a live `auth.sessions` entry at private-data boundaries. AC-05, the map's direct Auth endpoint checks and its API/role verification boundaries require missing or non-password sessions, including direct OTP/verification/recovery routes, to fail private access. These acceptance obligations cover the architecture's mechanism without treating a hidden UI as enforcement.
- AC-06 and Auth verification detail require fresh password login after reset, invalidation of older sessions on both clients, and preservation of holds, dormancy, identity, roles and history. The functional source explicitly treats trusted server revocation or credential epochs as a foundation obligation; AD-20 requires verifying native versus privileged reset revocation against the deployed Auth version. The contracts agree and make no claim that a still-valid JWT alone proves current access.
- The map retains all other role/API checks, source-revision/concurrency/retry/lifecycle checks, caching/notification/deep-link/audit protections, restore/handover, accessibility, native/browser and visual-reference verification. AD-18 preserves all 23 compound launch checks and detailed source edge cases.

## Limits and remaining gates

No app code, live Auth configuration, SMTP delivery, password flow, session revocation or recovery grant was exercised. Provider behavior, all direct Auth routes and no-email recovery remain mandatory foundation tests; operational owners, policy values and last-Admin support remain the already documented Q1 gates. Passing this reconciliation does not close those gates.
