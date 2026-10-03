# Privacy and data-integrity gate

Reviewed 2026-10-03 against the amended architecture spine. The baseline reconciliation corrections to AD-11 and AD-12 are present. The architecture memlog was not read and the spine was not edited.

**Verdict: changes required before finalisation.** The live authorization, separate projections, transactional command ownership, finance revision controls, inbox/provider distinctions and private-file gate are sound. Two cross-boundary mechanisms need tightening, and one revocation ambiguity should be removed.

## P1 — Cached Realtime authorization cannot carry revocable private bodies

**Location:** AD-4 and AD-5.

AD-5 permits “explicitly permitted chat data” in Realtime, while AD-4 relies on equivalent subscription checks and current role/cell membership. A client can join a private Broadcast channel while permitted, lose its group/cell membership, and keep the connection open. A chat implementation may still send private message bodies to that previously authorized connection even though ordinary API reads now deny it.

Official Supabase documentation, checked during this review, states that channel access policies are cached for the connection; the database is not queried for every message. They refresh when the client subscribes or supplies a new JWT. A revoked client cannot be trusted to voluntarily refresh or disconnect. This is a current transport limitation, not a hypothetical missing feature requirement.

**Required tightening:** For this architecture, make protected Realtime traffic invalidation-only, including chat, followed by a fresh authorized read. If private chat bodies remain permitted, require an explicitly verified per-message current-authorization transport before enabling that exception; join-time Broadcast RLS is insufficient. Define invalidation payloads so they contain no private content, names, object paths or anonymous-author linkage. Add a revoked-but-connected socket case to the permission fixtures.

Evidence: <https://supabase.com/docs/guides/realtime/authorization>, sections “How it works” and “Updating RLS policies”; <https://supabase.com/docs/guides/realtime/subscribing-to-database-changes>. The documentation distinguishes Postgres Changes RLS from Broadcast authorization; a chosen transport must be tested against the promised revocation semantics rather than treating them as interchangeable.

## P1 — Restore reconciliation needs a deletion/revocation history newer than the restored snapshot

**Location:** AD-14 and AD-17.

The spine requires reapplying deletion/revocation records before serving a restored system, but places the tombstone/workflow in the same database being backed up. Consider a backup at T0, full deletion or grant revocation at T1, and loss of the live database at T2. Restoring T0 also loses the T1 tombstone. Merely replaying records present in T0 can resurrect private data or authority while appearing to satisfy the current instruction.

**Required tightening:** The restore contract must identify a durably retained, access-restricted reconciliation source that survives rollback of the application snapshot, with a verifiable replay watermark. Its exact provider/retention can remain under Q4/Q9/Q12, but the mechanism cannot rely exclusively on the snapshot being restored. Apply the current deletion/revocation set to database rows, Auth/session access, object bytes and queued work before clients or sending are enabled. If completeness cannot be established, keep the target isolated pending authorized reconciliation. Minimize retained identifiers under the approved policy; this is not permission to keep hidden identity maps indefinitely.

This finding follows from the existing AD-14/17 guarantee and the adopted full-deletion/backup requirements. It does not invent a numeric RPO or select a backup vendor.

## P2 — Make urgent access revocation independent of successor handover

**Location:** AD-14, with AD-4 and AD-7.

“Role removal/deactivation checks last-responsible-person handover, denies protected access and cancels/reassigns affected work transactionally” can be implemented as a transaction that rejects the removal when no replacement owner is available. That interpretation leaves the removed person's access active precisely when a security-sensitive revocation is required. Planned last-Admin deletion and ordinary custody transfer need handover, but a security hold or revoked grant must not wait for that operational work.

**Required clarification:** Immediate denial of the affected scope is unconditional. Missing successor/custody handover creates a restricted, owned exception for the authorized supervisor/recovery operator; it cannot roll back a security revocation. Preserve duties and historic facts as required, and distinguish revoked staff scope from removal of otherwise valid general church membership. Final planned account destruction may still wait for the source-required last-responsible-account recovery/handover path.

## Verified boundaries and implementation gates

- Pending registration/status contracts are explicitly separate from approved member access; full private access resolves current account, credential, session, hold and grant state server-side.
- API exposure is explicit; application objects remain outside exposed schemas; elevated routines require a fixed search path, qualified references, restricted execution and actor/target checks. Read views retain invoker security and table RLS.
- Anonymous prayer identity and replies remain separately protected; task assignment supplies minimum context rather than full source permissions. The implementation's permission fixtures should include audit/idempotency/job metadata joins, because opaque IDs can become identifying when joined. This is enforcement evidence for existing AD-5, not a new blocking design decision.
- Finance exact amounts, person-level independence, fresh count attestations, correction-review authority, aggregate locks and request receipts preserve independently verifiable custody. Both clients share those server commands.
- Leased jobs and request idempotency do not claim exactly-once external delivery. Generic expiring pointers and current-state deep-link checks correctly bound the unavoidable provider acceptance race.
- Protected domain caches and reusable private bearer URLs are excluded; already-displayed/downloaded bytes are not falsely described as remotely erasable.
- Full deletion is tracked across DB, Auth and Storage, with completion evidence and retries. Its remaining architecture gap is the independently recoverable reconciliation history identified above.

No application code, live service permissions, actual provider delivery, backup restore or incident runbook was executed by this review.

## Resolution recheck — 2026-10-03

**Final verdict: PASS. No remaining blockers from this privacy/data-integrity review.** This recheck is limited to the three findings above and the newly added system-principal rule.

- **Realtime finding resolved:** amended AD-5 permits only receive-only, server-published, per-account generic refresh signals, including chat. Payloads exclude private bodies, record IDs, object paths, state and identifying source types. Current recipient filtering and fresh authorized reads remove the cached-channel-body leak; the rule explicitly acknowledges cached channel authorization.
- **Restore finding resolved:** amended AD-14/17 require a minimal, restricted, append-only recovery journal outside both the database and object rollback lifecycle, with deletion manifests before destructive work, ordered revocation/checkpoint watermarks, restored-session invalidation and replay before private serving or sending. Incomplete recovery evidence keeps restored access links/grants disabled pending authorized revalidation. Q4 owns access and retention rather than permitting an indefinite shadow profile.
- **Revocation finding resolved:** amended AD-14 explicitly denies access immediately and states that missing replacement staff cannot preserve access. Pending handover obligations survive for authorized resolution; they can delay final erasure or business completion, never security denial.
- **AD-19 introduces no privacy conflict:** human operations retain live member/session authorization, while separately authenticated system principals receive bounded job/command allowlists and must recheck source/scope/recipient eligibility. Automation cannot impersonate a human or manufacture response, consent, attestation or receipt facts. Distinct executor and initiating-human attribution remains subject to the existing restricted-metadata rules.

Implementation permission, connected-socket revocation, journal-loss/restore and worker-identity tests remain required by AD-18. This pass validates the amended architecture contract, not those future test results.
