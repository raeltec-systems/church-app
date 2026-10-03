# Design input reconciliation

Date: 2026-10-03
Verdict: **PASS — no load-bearing design contradiction or omission found.**

Compared `../architecture-church-app.md` with `../../spec-church-app/design-contract.md` and `../../../../docs/design-handoff/README.md`. This review checks architectural support for the design, not implementation fidelity or rendered accessibility. The spine explicitly adopts the design contract; repeating every token, screen and screenshot here is unnecessary.

| Boundary | Reconciliation |
| --- | --- |
| Source authority and native implementation | The opening contract and AD-16 preserve specification behaviour over obsolete prototype logic, native Flutter mobile, and reference-only HTML/React/runtime. Sample data, role switches and timers cannot become production authority. |
| Shared visual and accessibility system | AD-16 gives both surfaces one semantic token/component system, mobile light/dark and staff light, with keyboard/list alternatives. The adopted design contract remains binding for native safe areas, focus, names, targets, scalable text, contrast, five-tab navigation and screenshot fidelity. No architecture rule overrides these details. |
| Staff web feasibility | AD-16 and Q10 keep Flutter Web conditional on grid, keyboard, screen-reader, CSV and browser checks; failure triggers an explicit alternative-framework decision while retaining portal scope and shared server contracts. Q12 retains the supported-device/browser decision. |
| Honest interaction and concurrency | AD-2, AD-6, AD-8, AD-10 and the client-state convention require server-confirmed outcomes, revision checks, attributed direct confirmation and unknown-outcome recovery. AD-16 retains recoverable form input. These support pending/error/conflict states and reject simulated success, drag-to-consent, auto-completion and stale acceptance. |
| Role-aware routes and safe presentation | AD-3–AD-5 and AD-13 check current access on data reads and deep links, separate audience-safe projections, prevent Admin-only care/finance fetches, and constrain memory/file caches. This supports corrected staff navigation and forbids hiding sensitive fields only after retrieval. |
| Independent facts in reports, care and custody | AD-5–AD-7 and AD-10–AD-12 preserve separate recap publication, actual attendance, visit agreement/outcome, follow-up responsibility, counters, handover and independent receipt. Their presentation remains distinct under the adopted contract. |
| Full scope beyond screenshot coverage | The 17-capability map and AD-18 retain all launch/design checks; CAP-16 covers mobile/staff continuity. Missing screenshot coverage cannot remove recorder, counter, visitor, ordinary task-owner, prayer, directory, recovery or operational work. CAP-17 remains the sole conditional module. |
| External handoffs, metrics and private state | AD-8, AD-12, AD-13 and AD-15 reject fabricated delivery/media/giving completion, misleading metrics and durable private offline caches. The design contract continues to govern actual copy, user-visible return/error states and calendar-export caveats. |

## Actionable gaps

None blocking at initiative architecture altitude. Later feature reviews must test implementation against the adopted design contract and its screenshot map; this reconciliation is not evidence that those checks pass.

## Inherited open-policy gates

Q1–Q12 remain open as recorded by the specification. In particular, contact/consent and recap archive policy, offering currency/custody policy, metric definitions, church time, actual giving/content rights, chat inclusion and the web trial/support matrix cannot be inferred from the handoff examples. The spine preserves these gates without turning the design README's superseded workflow examples into approved policy.
