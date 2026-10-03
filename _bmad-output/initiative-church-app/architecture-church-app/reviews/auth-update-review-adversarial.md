# Authentication update — adversarial architecture and privacy review

Date: 2026-10-03
Verdict: **PASS — the initial blocking consistency gap is resolved**

Reviewed AD-2, AD-3, AD-4, AD-13, AD-14, AD-18, AD-19 and AD-20 against the current functional requirements. This attacks independently implemented features that obey the written rules; it does not verify a running provider. No canonical memlogs were read and no contract files were edited.

## Initial blocking finding: recovery authority has no shared invalidation generation

**Location:** AD-20's account-bound password-setup grant, interacting with AD-2's transaction boundary and AD-3/AD-14's credential/account lifecycle.

AD-20 requires a short-lived, single-use, account-bound grant and rejection of expired/replayed grants. It does not bind the grant to the reviewed member/account-link revision or a current recovery/credential generation, nor say which lifecycle changes invalidate an outstanding grant. AD-2 can protect a grant's own revision while the grant remains valid under a different account or recovery state. AD-19 can recheck the grant's unchanged source revision without detecting that its original identity evidence is obsolete.

Two otherwise compliant implementations expose the gap:

1. **Credential settings and staff recovery disagree about outstanding grants.** The recovery module issues grant G for account A after identity review. Before G is consumed, the member completes another recovery or changes the password in the credential-settings feature. That feature revokes sessions as AD-20 requires, but does not revoke G because no invariant requires it. G is still unexpired, unused and account-bound; the recovery module accepts it and resets A again. A capability that should have been superseded survives the credential recovery/rotation boundary. Two independently issued grants can similarly race, each satisfying its own single-use and revision checks.
2. **Account-link correction and recovery disagree about whose identity was checked.** Staff reviews person P1 and issues an unused grant for account A. An authorised identity correction subsequently changes A's approved person/link binding under the explicit reviewed linking workflow. Recovery still accepts the account-bound grant because A and the grant are unchanged. The eventual password sign-in satisfies AD-3 using A's new current member link, although the recovery identity evidence concerned P1. The grant can therefore reach a different person's protected records. A short expiry reduces the window but does not bind the authorization correctly.

**Required invariant, at spine altitude:** Identity owns one current recovery/credential generation for each account. A no-email setup grant must bind to the reviewed account, member/link binding revision and recovery case/generation, not only account ID. Issuance, replacement, cancellation and consumption use that shared authority state. A completed password recovery/change, account relink/credential-binding replacement, cancellation or account deactivation/deletion must invalidate older grants as appropriate; a deliberately held recovery account must remain recoverable through its current authorised case. Recheck the current case, approved binding, generation and reviewer authority at consumption and immediately before privileged Auth execution. Competing attempts must not apply out of order. If an external Auth mutation has an uncertain result, keep the affected recovery transition unresolved and private access fenced until reconciliation; do not let a stale completion approve a newer recovery generation or release a hold. Define which operation can complete/release that fence centrally, preserving independent security holds.

This calls for a shared lifecycle invariant, not SQL table names, a cryptographic implementation or a new church policy decision. The concrete grant transport, expiry value and provider integration can remain foundation work.

## Other attack paths checked

- **OTP or recovery token used against private API/Storage:** AD-3 requires trusted password authentication and a live session; AD-4 applies the same gate across tables, functions, Storage and exports. A feature using only `authenticated` or client flags would violate explicit rules, so this is not an unbound architecture choice.
- **Direct native Auth routes:** AD-20 prohibits SMS providers/hooks/test OTP/SMS MFA, acknowledges reachable alternate endpoints and requires the live password gate. Native email/password aliases use the approved binding. Actual no-SMS behavior and AMR claims remain mandatory provider tests.
- **Privileged worker bypass:** AD-19 already separates human and bounded system authority; AD-4 requires current actor/target/scope checks. No additional general service-role exception is allowed by the current text.
- **Recovery used to clear church/security holds:** AD-3 and AD-20 explicitly prohibit this. The blocking finding concerns the generation and sequencing of recovery authority, not permission to remove unrelated holds.
- **Secret and private-content exposure:** The functional requirements forbid application password/hash/reset-secret storage and logging; AD-13 forbids private bodies in logs/crash/push, and AD-20 requires staff-free password entry. Recovery implementation must preserve these requirements when applying the shared command/progress machinery.

After the generation/invalidation rule is added, rerun this lens against the final AD-20 wording and its contract acceptance checks. No other blocking divergence was found in this pass.

## Resolution and final targeted rereview — 2026-10-03

The final AD-20 resolves the finding. Identity now owns the recovery/credential generation, and a setup grant binds its reviewed case, stable member, Auth account, approved link revision, generation, purpose and expiry. New recovery, reissue, successful reset, relevant credential changes, relinking, cancellation and lifecycle restrictions invalidate obsolete grants. Current case/link/generation and permitted recovery action are checked under the Identity lock, with single consumption and a recorded pending operation before external Auth work.

The former attack paths no longer satisfy the contract: an unused grant from an earlier recovery or password change is superseded, and a grant reviewed for a previous member/link cannot reset the newly linked identity. Concurrent attempts cannot both become current privileged resets. Per-account serialization, operation/generation fencing, and the prohibition on relinking while an earlier external result is unresolved prevent an old operation from overtaking the current case. An uncertain or obsolete result retains the access hold for reconciliation; neither completion nor a successful password sign-in may approve another link or clear an independent hold.

AD-3's live member/account/credential-binding checks and AD-4/AD-19's current scope and owning-module checks remain compatible with this rule. Immediate security denial is explicitly preserved while recovery work is unresolved. Direct native Auth changes are covered by a trusted change-detection obligation before later grant use or private access. This is correctly a foundation validation requirement, not a claim that an unverified provider hook or a cross-system atomic transaction already exists.

The current functional requirements carry the same case/member/account/link/generation, invalidation, serialization and fail-closed invariants. The acceptance map adds unused-old-grant, reissue, credential change, relink, lifecycle, concurrent redemption, uncertain-outcome and stale-completion cases. Both documents preserve the narrower recovery permission and independent holds. No incompatible requirement or additional blocking divergence was found.

**Final verdict: PASS at architecture-contract level.** The initial finding above is retained as review history and is closed by the final wording. Provider integration, race tests, trusted direct-change detection, operational recovery ownership and last-Admin recovery remain implementation/foundation obligations; this review does not establish that those mechanisms are implemented or operational.
