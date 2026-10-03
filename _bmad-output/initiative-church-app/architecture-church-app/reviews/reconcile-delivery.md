# Delivery and decision reconciliation

Reviewed: 2026-10-03
Source: `../spec-church-app/delivery-and-decisions.md`
Target: `architecture-church-app.md` (draft, AD-1–AD-18)

## Verdict

**Pass with two narrow gate corrections recommended.** The architecture preserves the delivery commitment, policy proposals and operating constraints. No capability is deferred out of v1, no external provider is silently selected, and no numerical operational objective is invented. The following wording currently couples otherwise independent activation gates more broadly than the source.

## Findings

### Medium — AD-12 ties operational count comparisons to Q11 success-target approval

AD-12 ends: “Q8/Q11 approve definitions and targets before production comparisons or success claims.” Q8 supplies the service/count reporting definitions; Q11 concerns approval and measurement of the brief's success proxies. Read literally, an unanswered 90% response target or 48-hour visibility target could prevent the service-count comparison feature from operating after its own Q8 definitions are approved. The source permits independent work and gates other operational items at the affected module.

**Recommended correction:** distinguish the dependencies: “Q8 approves operational counting/reporting definitions before production comparisons; Q11 approves success-measure definitions, baselines and numerical targets before claims against those measures.” This keeps provisional success targets visible without creating a new counts activation dependency.

### Medium — AD-14 applies Q9 retention to all live personal data

AD-14 ends: “Q4/Q9 retention and backup handling are required before live personal data.” Q4 privacy/deletion/backup policy governs personal data generally, while Q9 is the offering/custody/export/retention decision. Read literally, an unresolved finance-retention decision could block unrelated member foundations or care pilots. The source says other operational items are settled before the affected module goes live and do not block unrelated foundation work.

**Recommended correction:** “Q4 privacy, deletion and backup handling gate live personal data; Q9 retention and custody policy additionally gate live Offerings data.” Apply the same affected-surface reading to the Deferred table: youth-specific approvals block youth/contact features, while general privacy/deletion safeguards govern all applicable personal data.

## Preservation checks

| Source obligation | Architecture evidence | Result |
| --- | --- | --- |
| Full v1, all seven milestones by November 2026; six additions fixed | Opening contract; full CAP map; AD-18; Q6 Deferred | Preserved |
| Single volunteer owner; small, reviewed ticket work; shared foundations before dependents | Source remains required companion; AD-18 foundation contract; CI owner review; spec adoption then ticket breakdown | Preserved by reference and compatible structure |
| RLS/permission, concurrency and worker tests from milestone 1 | AD-18; AD-2/AD-8 mechanisms; explicit absence of implementation evidence | Preserved |
| Written support, handover, media, reminder and database/file restoration procedures without Admin private-content access | Required source companion; AD-4/AD-5/AD-17/AD-18; runbook seed | Preserved |
| Q1 remains build-blocking for affected Auth integration; no selected provider or risk acceptance | AD-3; Q1 Deferred; synthetic/assisted preparation explicitly permitted | Preserved |
| Q2 zone/timing/quiet-hour proposals remain proposals; no chat-timezone inference | AD-9; Q2 Deferred | Preserved |
| Q3 actual giving details and Q5 content rights verified before publication | AD-15; Q3/Q5 Deferred | Preserved |
| Q4 youth/privacy/retention and Q7 care/recap/consent decisions remain unresolved | AD-5/AD-10/AD-14; Q4/Q7 Deferred | Preserved, subject to the narrow gate correction above |
| Q6 module owners/rollout unresolved; only chat optional | AD-15; Q6 Deferred; CAP-17 mapped separately | Preserved |
| Q8 definitions/proposed reporting defaults and Q9 currency/custody/retention are not silently promoted | AD-11/AD-12; source proposals explicitly retained; Q8/Q9 Deferred | Preserved, subject to gate corrections above |
| Q10 Flutter Web is a trial, React/Next alternative allowed; no chosen host/domain | AD-16/AD-17; Q10 Deferred | Preserved |
| Q11 90% and 48h numerical proxies remain provisional and distinct from correctness gates | Q11 Deferred; required source companion | Preserved; AD-12 wording should separate operational comparisons |
| Q12 no invented platform floors, latency/availability, reminder tolerance or RPO/RTO | AD-9/AD-17/AD-18; Q12 Deferred | Preserved |
| Accepted duty still gets eligible pre-service reminders; provider acceptance does not prove delivery/read | AD-6/AD-8 | Preserved |
| 48h queue target not a replacement response-deadline rule; no false retrospective short-notice claim | Required source companion; AD-9 short-notice handling; Q11 Deferred | Preserved |
| Sender registration/network tests and store accounts/review have external lead time; instruction-only giving does not guarantee store approval | Required source companion; Q1 integration gates; AD-18 explicitly denies store approval | Preserved by reference |
| Hosting/backend/SMS/storage/email/store/maintenance costs remain unselected and need current quotes | AD-17; Q1/Q10/region-plan Deferred; no paid service provisioned | Preserved |
| Assisted no-login participation and single-reviewer/adoption risk remain supported | AD-3/AD-6/AD-8; required source companion | Preserved |

The spine does not need to repeat the milestone table, every external lead-time estimate or every proposed numerical policy. Its opening instruction requires the complete companion set, and the architecture does not override those details. No architecture memlog was read, and no spine changes were made by this reviewer.
