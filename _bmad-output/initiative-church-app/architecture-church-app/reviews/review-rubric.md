# Good-spine rubric review

Date: 2026-10-03

**Verdict: PASS with one non-blocking provenance correction.** The spine fixes the initiative's shared divergence points, covers all capabilities and operational dimensions, and keeps unresolved policies behind bounded activation gates. No critical or high finding was identified. Mechanical lint was reported separately as clean; this review addresses semantic quality and does not claim application tests passed.

Reviewed the draft spine against `.agents/skills/bmad-architecture/references/reviewer-gate.md`, the adopted specification's architecture/access requirements and the linked backend evidence. No architecture memlog was read or changed. No spine edits were made.

## Actionable finding

### R-01 — Medium: distinguish adopted requirements from new mechanisms inside adopted ADs

**Location:** Fast-path status; AD-3, AD-7, AD-9 and AD-18.

**Evidence:** The legend says `[ADOPTED]` marks source requirements. Several ADs correctly retain source behaviour while also fixing a newly proposed shared mechanism: checking a live Auth session (AD-3), the exact `source_type/source_id/purpose` task uniqueness identity (AD-7), a retained scheduling-policy version and one shared calculation (AD-9), and SQL/wire-contract authority plus common Dart/TypeScript fixtures before consumers (AD-18). The source requires live revocation, shared tasks, consistent schedules, shared server commands and tests; it does not explicitly settle all those mechanisms. The mechanisms fit the requirements, but the whole-AD label overstates their provenance.

**Consequence:** A later agent or reviewer can mistake a fast-path architectural proposal for an already accepted source decision. This matters especially when first foundation work evaluates those choices.

**Disposition: autofix.** Preserve stable AD IDs and adopted behaviour. Add inline `[ASSUMPTION]` labels to the novel clauses, or identify these as mixed adopted requirements/proposed mechanisms and list which mechanisms are proposed. No owner-policy decision or extra application test is needed for this document correction.

## Rubric coverage

| Criterion | Assessment |
| --- | --- |
| Named paradigm and initiative altitude | Pass. Modular monolith, authoritative shared backend and layered clients are explicit. The contract governs independently built features without prescribing a migration-ready schema or complete class tree. |
| Actual prevented divergence | Pass. The 18 ADs address authority, transactional transitions, identity, safe projections, assignments, follow-ups, notifications, time, care consent, custody, metrics, caching/files, lifecycle, isolation, clients, operations and integration. These are genuine cross-feature seams. |
| Rule enforceability | Pass. Rules give observable constraints: grants/RLS, explicit ownership, revisions, receipts, uniqueness, current-state checks, state separation, durable jobs, private-cache exclusions and environment boundaries. Values requiring owner approval are separately gated. |
| Assumptions versus inherited choices | Pass with R-01. Flutter/Supabase and source behaviour remain inherited; novel topology, API, worker, file and environment mechanisms are generally marked. Mixed AD provenance needs the small correction above. |
| Architecture/rule/diagram consistency | Pass. Client application/domain ports remain independent of SDK adapters; cross-domain orchestration can coordinate owner operations, and owner modules cannot call back into orchestration. The runtime/deployment diagrams supplement that static dependency rule. Workers can perform source checks through orchestration without a forbidden Notifications-to-owner dependency. |
| Every altitude-owned dimension addressed | Pass. Client and backend boundaries, data ownership, cross-feature transactions, identity, files, transport, environment isolation, migration compatibility, secrets, operators/alerts, provider/region/budget gates, backups and restoration all have a rule or explicit gate. |
| Safe deferral | Pass. Payload/schema details require a shared foundation contract before consumer work; worker policy values must be centralized before enablement; the web framework is selected after a trial and before dependent implementation. No deferred item authorizes independently chosen conflicting defaults. |
| Technology reality checks | Pass at document level. Linked dated research supports managed backend constraints; the Stack labels exact versions as seed candidates and records that resolution/build/provisioning remain future checks. No live infrastructure state or successful dependency solve is implied. Separate configured technology review remains authoritative for exhaustive URL/version checking. |
| Brownfield/inheritance consistency | Pass. No application code or parent architecture is asserted. The document adopts the specification rather than treating design prototypes as implementation or permission authority. |
| Capability coverage | Pass. CAP-1 through CAP-17 have explicit owners and relevant ADs. All six additions remain v1; Chat alone is conditional. The acceptance reconciliation maps all 23 compound launch checks. |
| Minimal structural seed | Pass. A compact starting tree, stack and two deployment/context diagrams give a cold start without turning optional framework/provider details into settled implementation. |
| Approval and verification claims | Pass. Final document status is explicitly separate from church policy approval, provider/store readiness and application verification. Required native/client/API/provider/restore tests are implementation/release obligations. |

## AD enforceability walk

| AD | Enforceable divergence boundary |
| --- | --- |
| AD-1 | One environment authority, explicit record owners and transactionally coordinated owner operations. |
| AD-2 | Shared API exposure, command revision/idempotency receipt, global lock ordering and atomic state/audit/task/job effects. |
| AD-3 | Stable person/account distinction and current server-side trust checks; R-01 concerns provenance, not adequacy. |
| AD-4 | Same current scope at every protected surface, including workers and combined-role cases. |
| AD-5 | Distinct safe projections and restricted identity/private fields before data reaches another audience. |
| AD-6 | One assignment engine and unambiguous material revision/reconfirmation/provenance semantics. |
| AD-7 | Shared task identity, owner/lifecycle semantics and transactionally coupled source effects; provenance clarification only. |
| AD-8 | Logged canonical jobs, unique logical notifications, leases/fencing and current pre-send checks, with honest external-effect limits. |
| AD-9 | Shared approved time/schedule interpretation and reconciliation; provenance clarification only. |
| AD-10 | Consent belongs to a current care proposal, and appointment state does not erase outstanding care. |
| AD-11 | Exact person-independent custody facts and attributed correction/export semantics. |
| AD-12 | Actual observations, definition versions, denominators and missing/zero/cancelled distinctions. |
| AD-13 | Persistent public-only domain caching, revalidated private-file delivery and explicit limits of offline revocation. |
| AD-14 | Atomic local lifecycle changes plus durable externally resumable deletion and restore reconciliation. |
| AD-15 | Public giving cannot acquire payer/payment records; core features cannot depend on optional chat. |
| AD-16 | One server contract across clients, accessible alternatives and a gated web-framework choice. |
| AD-17 | Isolated environments, authenticated scheduling, compatible releases and database-plus-file recovery. |
| AD-18 | Common contract foundations and relevant tests precede independent consumers/release; provenance clarification only. |

No blocking change is requested beyond the separate configured reviewers' findings, if any. R-01 can be corrected directly during finalization.

## Provenance recheck — 2026-10-03

**Verdict: PASS. R-01 resolved.** AD-3 now explicitly marks the central predicate/live-session mechanism as an assumption; AD-7 separates its proposed source/purpose identity key from adopted task behaviour; AD-9 labels the scheduling-policy version/shared calculator; AD-18 separates proposed contract/fixture foundations from adopted verification obligations. The changed Realtime mechanism in AD-5 is explicitly an assumption, and the new AD-19 system-principal mechanism is also marked as an assumption. Stable existing AD IDs and inherited requirements remain intact. No remaining actionable provenance issue was found. This recheck was limited to provenance changes, as requested.
