# Spec-kernel reconciliation

Date: 2026-10-03

Verdict: **PASS — no kernel requirement was dropped, narrowed, or silently approved.** No corrective action is required by this reconciliation.

Reviewed the saved `architecture-church-app.md` against `../spec-church-app/spec-church-app.md` only. This is the required load-bearing-input reconciliation, not the subsequent architecture technology, adversarial, or implementation gate. The architecture explicitly requires the kernel and every companion; detailed feature behaviours therefore remain binding without being repeated in each AD.

## Capability preservation

| Kernel capability | Architecture owner / rules | Reconciliation |
| --- | --- | --- |
| CAP-1 Public church content | Content; AD-13, AD-15, AD-16 | Guest public access, rights-cleared offline text, publishing and unavailable-media contract retained. Detailed hymn/calendar/search behaviours remain in the adopted kernel/baseline. |
| CAP-2 Instruction-only giving | Content; AD-15 | Public instructions remain separate from Offerings; no payer/payment/result entities introduced. Admin publishing authority remains inherited. |
| CAP-3 Membership, sign-in and recovery | Identity and lifecycle; AD-3, AD-14 | Accountless stable members, bounded applicant access, distinct approval/access/cell states, reviewed linking and resumable full deletion retained. |
| CAP-4 Scoped authority and privacy | All owners; AD-3–AD-5, AD-13 | Current server authority covers every surface; Admin alone gains neither care nor finance, and combined roles do not waive independence. |
| CAP-5 Assigned duties and responses | Duties; AD-2, AD-6, AD-9 | Shared multi-slot assignment/revision engine preserves material reconfirmation, direct-confirmation provenance, stale-response rejection and independent attendance/completion facts. Detailed baseline transition cases remain required. |
| CAP-6 Coverage and follow-up | Duties and Follow-ups; AD-6, AD-7 | One accountable tracker, member My follow-ups access, original overdue history and atomic reassignment/resolution effects retained. |
| CAP-7 Reliable reminders and inbox | Notifications; AD-8, AD-9, AD-17 | Logged inbox/jobs, app-independent scheduling, current-source checks, quiet hours/expiry and direct-contact routing retained; no fabricated delivery/read/consent. |
| CAP-8 Cell attendance and private reports | Cells and Follow-ups; AD-5, AD-7, AD-12 | Private report separation, actual recorded attendance, cancellation/missing distinctions and baseline recorded held-meeting absence rule preserved. |
| CAP-9 Cell programmes | Cells calling Duties; AD-6, AD-12 | Programme duty reuse and current revision responses retained; intended attendance and actual leaders stay separate. |
| CAP-10 Safe recaps | Cells publication; AD-5, AD-13, AD-14 | Explicit safe publication revision, no automatic raw-report release, current-cell authorization and withdrawal/cache limitations retained. |
| CAP-11 Agreed visits | Care and Follow-ups; AD-10 | Both parties' agreement to the same proposal, attributed direct contact, reconfirmation and care-versus-appointment separation retained. |
| CAP-12 Service counts/trends | Services; AD-12 | Aggregate-only counts, missing/zero/cancellation distinctions, versioned corrections/definitions and honest coverage/denominator presentation retained. |
| CAP-13 Aggregate offering custody | Offerings; AD-11 | Two distinct counters, independent receiving person, counted/handed/received facts, partial/discrepant custody, corrections and scoped formula-safe CSV retained; no donor ledger. |
| CAP-14 Private prayer/replies | Prayer; AD-5, AD-14 | Separate anonymous author mapping, author/designated lead-pastor identity access and server-routed private replies retained. Author edit/close/archive details remain adopted. |
| CAP-15 Opt-in directory | Directory; AD-5 | Separate opted-in projection and current access gates retained. Hidden-by-default, field-level opt-in, birthday/youth/assisted-contact restrictions remain adopted and are not weakened. |
| CAP-16 Staff/mobile continuity | Shared API and both clients; AD-1, AD-2, AD-16 | One record/authority contract, essential mobile staff actions, accessible alternatives and unresolved Flutter Web trial retained. |
| CAP-17 Conditional moderated chat | Independent Chat; AD-15 | Chat alone remains conditional; all core workflows must pass without it. Enabled chat inherits moderation, current membership, media and deletion contract. |

## Cross-cutting constraints and non-goals

- Full v1, the six mandatory additions, all seven milestones, and the November 2026 target are explicit in the introduction and release gate. No capability is relabelled an optional pilot or moved beyond v1. The original fewer-than-200/English/volunteer-reviewer context remains inherited; no conflicting scale, language, tenancy or support model is introduced.
- Flutter iOS/Android and shared Supabase authority remain fixed. Flutter Web remains a foundation trial; the alternative framework decision cannot reduce staff portal scope or create a second identity/data store.
- Public-content caching, visibly unconfirmed unsent actions, UTC plus approved church IANA zone, independent reminder execution, server secrets and prototype non-authority all survive. Mobile light/dark, staff light and accessibility requirements are preserved through the design contract.
- AD-15 protects instruction-only giving and chat isolation; AD-12 protects aggregate counts; AD-13 prevents general offline-first behavior. The opening adoption preserves all other non-goals, including automated email/SMS/WhatsApp duty reminders, direct member chat, swaps, family/proxy access, payment features and general ledger scope. No AD introduces a conflicting feature.
- AD-18 retains the 23 compound launch checks, feature tests from milestone 1, both-client parity, native/app-closed/offline/push-denied checks, CI, operational handover and database-plus-file restoration. The pilot/success signal remains required by the adopted kernel; the architecture does not replace it with documentation review.

## Open decisions and approval boundary

All Q1–Q12 remain visibly open with affected activation gates. Numerical 90%/48-hour measures are expressly unapproved; no baseline is invented. Phone-risk policy, SMS/provider selection, church timezone, giving destinations, safeguarding, content rights, care/recap consent, counting definitions, offering currency/independence, web selection and operational targets have not been silently settled.

New engineering mechanisms are labelled Fast-path assumptions. The document explicitly says final status does not approve source policies or claim implementation tests passed. Its local/staging/production topology and version candidates do not claim provisioning, paid-service approval or launch readiness.

No remediation required. Proceed to the independent reviewer gate; this reconciliation supplies no implementation-test evidence.
