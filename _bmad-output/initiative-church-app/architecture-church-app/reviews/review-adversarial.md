# Adversarial integration review

Reviewed: `architecture-church-app.md`, draft dated 2026-10-03. Scope: literal compliance by independently implemented modules; architecture memlog was not read. The source spec and its decision register were used to check the two seams below.

## Verdict

Needs two targeted clarifications before handoff. The spine already closes the substantial permission, safe-projection, idempotency, lifecycle and notification-delivery gaps. These findings concern cross-module authority and execution context, not schema or payload detail that AD-18 correctly reserves for a single shared foundation contract.

## A1 — High: choose the authoritative cell-meeting schedule and generation owner

**Affected:** AD-1 (line 62), AD-6 (line 92), AD-9, CAP-8/CAP-9.

AD-1 assigns “occurrences ... and recurrence” to Duties while assigning “meetings” to Cells. A cell meeting is itself a recurring occurrence. AD-6 prevents cloned assignments, but does not distinguish the meeting occurrence's identity/schedule from the duty occurrence identities linked to it.

**Two locally compliant implementations:** Cells generates weekly meeting records and owns moving/cancelling their dates. Duties independently generates cell-owned recurring duty occurrences, each with stable series/nominal identity, and links programme parts to those duties. Both mutate only their own records, use the shared scheduler, preserve unique assignments and use correct transactions when invoked. They nevertheless create two schedule authorities for the same cell programme. A Duties series edit can move assignments without updating the meeting; a Cells move can leave the Duties generator recreating future occurrences from the old pattern. The current source-reference and payload conventions do not determine which generator must defer to the other.

**Fix:** State which module owns canonical cell-meeting recurrence, occurrence identity and meeting schedule. A suitable choice is Cells, with Duties owning only the associated duty/slot/assignment records. Require an explicit canonical meeting reference, prohibit an independent Duties recurrence for programme-generated parts, and specify the cross-owner operation for meeting changes: flag affected published parts and require leader publication of revised assignments atomically, cancelling obsolete work under the baseline rule. Preserve the separate flag-for-owning-leader rule for links to an independently owned department duty. Exact columns and operation names can remain in the foundation contract.

**Evidence:** Spec 1.2, “Cell groups” / “Meetings” and “Meeting programmes”, especially its rule that meeting time/venue changes flag linked parts and require revised assignments to be published atomically. This is an ownership clarification, not a new product behavior.

## A2 — Medium: distinguish authenticated people from bounded system-command actors

**Affected:** AD-2 (line 68), AD-3 (line 74), AD-4 (line 80), AD-8 and AD-14.

AD-3 binds every protected read/command and requires `auth.uid()`, a live Auth session and an approved member/account link before private access. AD-2 requires actor-scoped request receipts. The worker has an explicitly verified server credential under AD-17, but its distinct actor/authorization context is not defined. A service credential normally has neither a member identity nor a live end-user Auth session.

**Two locally compliant implementations:** Identity supplies the literal shared access predicate and command actor resolver, denying a caller with no live member session. Notifications builds the stipulated server-authenticated worker and calls the shared source/actionability commands using its service context. The worker is correctly authenticated and bounded, yet every required protected read fails the universal member predicate. Another team could instead impersonate the recipient, making receipt/audit attribution and permission evaluation disagree with Identity's model. AD-4's prohibition on arbitrary service work identifies the concern but does not establish the positive shared contract.

**Fix:** Limit AD-3's session/account predicate to user-initiated access and explicitly define a separate bounded system principal for approved worker/lifecycle operations. Keep recipient/source eligibility checks live; never grant system work by inventing a member session or interpreting a missing user as permission. Specify that shared request receipts/audit identify the actor kind and stable principal, and that system operations are exposed only through an allowlisted authenticated orchestration entry point. The exact credential, identifiers and command payloads remain foundation detail. That orchestration layer can call source owners and Notifications, preserving the dependency direction while performing the required presend checks.

## Other attacks closed by existing rules

- Parallel web/mobile transition logic is forbidden by AD-2/AD-16/AD-18.
- A task assignee inheriting private source data is forbidden by AD-4/AD-5/AD-7.
- Replayed financial writes, stale consent and source/job partial commits are explicitly forbidden by AD-2/AD-6/AD-10/AD-11.
- Uncertain push delivery cannot honestly be presented as exactly once or as consent under AD-8.
- Prototype authorization, private persistent caches, reusable private bearer URLs, duplicate finance authority and chat dependence are explicitly excluded.
- Per-feature enums, exact payloads, page sizes, indexes and retry values are not findings: their common foundation or activation gate is explicit.

No spine edits were made by this reviewer.

## Resolution review — 2026-10-03

**Final verdict: PASS.** Rechecked the saved AD-1/AD-6, AD-3 and new AD-19, plus their interaction with AD-2/AD-8/AD-14/AD-17/AD-18. This was a focused recheck of the findings and obvious conflicts introduced by their fixes, not a new implementation verification.

- **A1 resolved:** Cells now exclusively owns canonical meeting schedules/recurrence and generates stable meeting identity. Duties owns standalone recurrence and cannot generate a second cell-meeting calendar. Programme positions link uniquely to duty slots; Cells invokes Duties transactionally, while a linked department duty retains its independent owner-review boundary. Exact operation schemas appropriately remain subject to the shared foundation gate.
- **A2 resolved:** AD-3 now scopes the member/session predicate to human-originated access. AD-19 defines independently authenticated, environment-bound system principals with command allowlists, separate human/system authorization contracts, live source/recipient checks and distinct executor/initiator attribution. It forbids impersonation and prevents automation from manufacturing member consent or financial attestations.

No blocking new conflicts were found in these changes. Original findings above are retained as review history and are closed.
