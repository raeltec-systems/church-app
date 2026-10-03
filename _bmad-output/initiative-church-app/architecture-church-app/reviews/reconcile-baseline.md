# Baseline reconciliation

Reviewed 2026-10-03 against the complete adopted `../../brief-church-app/inputs/church-app-v1-spec-1.2.md`, the spec kernel, delivery/decision companion and acceptance map. This review did not read the architecture run's memlog or change the spine.

**Verdict: preserved, with two targeted clarifications before finalisation.** No approved capability has been silently removed or replaced. The spine correctly keeps detailed source requirements mandatory rather than reproducing every screen, field and schedule. Existing Q1–Q12 policy gates remain inherited open decisions, not new findings.

## Actionable clarifications

1. **AD-11 — make correction authority and renewed evidence explicit.** The source's Cell offerings / Count, handover and receipt step 5 (baseline line 414) requires renewed counter attestations for a count correction and an independent authorised finance reviewer for a receipt correction. The spine currently says “renews affected attestations” and specifies receiver independence, but does not explicitly bind the correction reviewer. Tighten to require both counters' fresh attestations against the corrected amount/currency revision and an independent authorised reviewer for receipt corrections. This closes a seam between count, receipt and correction implementations without deciding a new church policy.
2. **AD-12 — separate reporting approval from success-target approval.** The final sentence couples Q8/Q11 to “production comparisons or success claims”. Q8 owns service/cell counting definitions and comparable reporting periods; Q11 concerns the approval status, baseline and interpretation of the 90%/48-hour success proxies. Make Q8 gate production reporting definitions/comparisons and Q11 gate claims against those numerical success targets. Do not accidentally block otherwise approved service/cell trends on the unrelated Q11 clarification. The spine's Deferred table already expresses the narrower Q11 gate correctly.

## Preserved boundaries checked

| Load-bearing source requirement | Architecture treatment |
| --- | --- |
| Full v1, all six additions, seven milestones; chat alone conditional | Opening contract, AD-15/18, complete CAP-1–CAP-17 map |
| Stable accountless person identity; reviewed linking; separate approval/access/cell states; prior-activity dormancy and trusted credential comparison | AD-3/4/14; source Auth/membership and Access/reliability sections retained |
| Basic Admin member/contact administration distinct from private care/finance access; combined roles do not waive independent custody | AD-4/5/11 |
| Prayer text separate from anonymous identity; private pastoral reply routing and no identity leakage through care/tasks | AD-5 explicitly permits opaque server-side reply routing while preserving the identity boundary |
| One owning scope and one current assignment; programme links reuse existing duties; notes-only changes preserve consent; accepted duties retain eligible pre-service reminders | AD-6; source Duties and Programme sections retained |
| Cross-scope display links do not transfer mutation authority or let a cell transfer cancel a department-owned duty | AD-6/14 |
| Shared owner/supervisor/task registry; ordinary practical notes versus restricted source notes; Waiting review deadline and source-specific reminder schedule | AD-5/7/8/9 |
| Durable inbox independent of push; bounded retries, current-source checks, expiry, direct-contact fallback and no delivery/read/consent inference | AD-8/9/18; external dispatch race explicitly bounded instead of promising impossible retraction |
| Attendance notice, duty response, actual attendance/leader, visit consent and care-task status remain distinct facts | AD-6/7/10/12 |
| Safe separately published recaps, opted-in directory and narrow audience projections rather than client-side hidden columns | AD-5/13 |
| Atomic exact-money custody, distinct person identities, partial/discrepant facts, idempotency, scoped formula-safe CSV and restricted audit | AD-2/4/11/12, subject to correction clarification above |
| Current reporting definitions, historical cell roster, missing/zero/cancelled distinctions and no unique-person claims from aggregates | AD-12, subject to gate clarification above |
| Public giving remains instruction-only; private finance never leaks into profiles/public APIs | AD-15 plus source Giving instructions retained |
| Public offline text/instructions with refresh/withdrawal handling; private care/finance/programme/recap records not persisted for offline browsing | AD-13/15; the source still supplies verification-date/offline-label detail |
| Deactivation/hold/deletion distinctions, task/custody handover, Auth plus DB plus Storage deletion and approved non-personal retention | AD-14/17 |
| Shared mobile/web commands, server validation, optimistic concurrency, essential mobile actions, accessible web alternatives and conditional Flutter Web choice | AD-2/16/18 and Q10 gate |
| UTC/church IANA scheduling, protected scheduled endpoints, separate file/database backups and restricted restore/support operations | AD-9/17/18 |
| All detailed launch checks remain in force; documentation review does not claim implementation or production-policy validation | AD-18 and opening fast-path status |

## Scope of the verdict

This is source-preservation reconciliation, not a live Supabase permission test, dependency build, operational-policy approval or proof of reliable dispatch. The required technical-reality, adversarial compatibility and rubric reviews remain separate gates. No new source contradiction was identified beyond the already recorded Q11 mismatch.
