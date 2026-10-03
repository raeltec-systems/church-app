# Auth update reconciliation — delivery and decisions

**Final verdict: PASS — D1 resolved below.** The initial review requested one bounded wording correction. Delivery-and-decisions itself preserves the approved scope and correctly retires the SMS decision gates. One sentence in the functional requirements can reintroduce an unintended global email-infrastructure gate.

Reviewed 2026-10-03. Inputs: `../../spec-church-app/delivery-and-decisions.md`, current kernel, functional requirements and architecture spine; compared delivery against `/workspace/work/auth-update/before/spec-church-app/delivery-and-decisions.md`. This is contract reconciliation, not application/provider validation. No canonical documents or memlogs were edited by this review.

## Finding

**D1 — Clarify email activation gate in functional requirements.** At `functional-requirements.md:565`, “Configure and budget production email delivery and validate the no-email recovery mechanism before private launch” can be read as requiring email infrastructure before any private phone/password access. Delivery Q1 and architecture Deferred Q1 explicitly state that email setup gates email recovery, not phone/password login for members without email. Split the sentence so production email delivery must be ready before self-service email recovery is enabled, while the staff-assisted no-email procedure must be validated before private launch. This is a consistency clarification of the already approved optional-email route; it needs no new user policy decision.

## Reconciled requirements

| Check | Result |
| --- | --- |
| Approved authentication | Phone username/password, optional verified same-account recovery email, no SMS and identity-checked staff recovery without email match CAP-3 and AD-3/AD-20. No phone-possession proof or automatic number-based member linking is introduced. |
| Q1 scope | Remaining questions concern approval/recovery owners, password/abuse/dormancy policy, production email setup/budget and a tested assisted procedure. SMS vendor, sender, route, spend, SMS-only risk acceptance and fallback-selection gates are explicitly retired. The inherited proposed 90-day dormancy remains provisional. |
| Optional email | Delivery Q1 explicitly permits password login without email; its operating notes preserve email omission, prohibit fabricated addresses and require approved staff assistance. The finding above is confined to a different companion's ambiguous activation wording. |
| Approval continuity | Existing separate church/cell approval and current holds remain. No routine new-device or returning-session approval requirement is added. Functional requirements expressly preserve ordinary password sign-in without blanket reapproval. |
| Q2–Q12 | All eleven rows are byte-for-byte unchanged against the before snapshot. Timezone/reminder policy, giving, safeguards, rights, module owners, care, counts, custody, web trial, provisional targets and operational acceptance retain their original scope and gates. |
| Seven milestones | All seven remain in order. Only milestone 1's auth description changes to phone/password and no-SMS recovery; its shared access/web trial/handover scope is intact. |
| Full v1 commitment | Full v1 remains targeted for November 2026. Programmes, recaps, visits, service counts, staff web and cell offerings remain required; chat alone remains conditional. No auth change defers an addition or weakens its permission/correction checks. |
| Delivery quality | Ticket-sized changes, milestone foundations, permission/RLS, transition/concurrency and worker CI tests, support/restore runbooks and private-data limits on Admin support remain intact. |
| External dependencies | SMS carrier/sender lead times and spending disappear; production verification/recovery email, stores, hosting, backend/storage and SDK maintenance remain explicit operational work. No provider, production address, cost or church policy is silently selected. |
| Success evidence | All five measure rows and their limits are preserved, including provisional Q11 numbers, explicit member response versus leader confirmation, timing uncertainty and provider acceptance versus delivery. |

After D1 is clarified, delivery reconciliation passes without further policy or scope decisions.

## D1 resolution — 2026-10-03

**Final verdict: PASS.** Rechecked the revised `functional-requirements.md:565`. Production email is now required before enabling email verification/recovery; the no-email recovery mechanism must be validated before private launch. The sentence explicitly preserves otherwise valid phone/password access for members without email when email delivery is unavailable. D1 is resolved and no further delivery-reconciliation correction is required.
