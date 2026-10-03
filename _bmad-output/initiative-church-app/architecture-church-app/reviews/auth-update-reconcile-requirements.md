# Authentication update — requirements reconciliation

Date: 2026-10-03
Verdict: **PASS**

This is a document reconciliation, not verification of a running Auth backend or application. No canonical memlogs were consulted and no contract files were edited during this review.

## Inputs checked

- Current `spec-church-app/functional-requirements.md` against the complete original `brief-church-app/inputs/church-app-v1-spec-1.2.md` using an independent line diff.
- Updated `architecture-church-app/architecture-church-app.md`, especially AD-3, AD-4, AD-14, AD-18, AD-20 and Q1.
- Spec kernel, design contract, delivery/decisions companion and acceptance map for current authority, authentication propagation and stale SMS/OTP requirements.
- Owner-approved delta: phone number and password; optional verified email recovery; no SMS; identity-checked staff-assisted recovery when email is unavailable.

## Reconciliation

1. **Approved authentication is represented consistently.** Functional requirements lines 72–133 and AD-20 use native Supabase phone/password, distinguish the normalized unverified username from phone ownership, attach optional email to the same account, and preserve the no-email staff route. A verified approved recovery binding is required; ordinary contact email or number possession cannot recover or claim a historical member. Passwords stay in Supabase Auth; staff never handles them. The no-email grant mechanism is explicitly an engineering assumption that must pass foundation validation.
2. **Access and recovery preserve the existing privacy contract.** Member identity remains independent of the login. Current approval, credential binding, holds, dormancy and scopes remain authoritative on mobile and web. AD-3 and AD-20 require trusted password authentication and live session checks, keep recovery-only sessions outside private data, require fresh password sign-in after reset, and preserve security holds. Public reset requests alone cannot suspend another person's account. Accountless participation, explicit reviewed linking, last-Admin continuity and staff recovery without care/finance access are retained.
3. **No current SMS-OTP obligation remains.** Remaining SMS/OTP mentions in the current contract prohibit or test unsupported routes, distinguish historical screenshots, or explain deferred scope. SMS vendor, route, sender, spend, OTP delivery and SMS-only recycled-number acceptance gates have been removed from Q1 and launch criteria. Email delivery remains an operational requirement for the optional email feature; it does not make email mandatory for phone/password accounts. Provider-native email/password aliases are explicitly subjected to the same account and authority gates, so a phone-first UI is not mistaken for API enforcement.
4. **The full non-authentication baseline is preserved.** The independent diff contains 33 changed spans; 566 original lines are retained exactly. Every changed span concerns document provenance, authentication, related contact/account boundaries, costs, rollout or acceptance. The only edits inside domain sections are visitor signup and the shared staff sign-in route. Duties, programmes, recaps, visits, attendance/reporting, offering custody, giving, content, prayer, directory, tasks, notifications, chat conditionality and other domain rules retain their original requirements. All six first-release additions, seven milestones, CAP-1 through CAP-17 and all 23 compound launch checks remain present. Updated authentication checks replace the obsolete checks without reducing the launch-check count.
5. **Authority and traceability are clear.** The kernel adopts the current functional companion and architecture. Both explicitly identify original 1.2 as an unchanged audit source, avoiding simultaneous authority for the old OTP flow. The architecture sources point to the current companion. Design overrides replace code-entry/resend interactions, and acceptance-map AC-01 through AC-06 trace the revised authentication and recovery checks.

No critical source-preservation or cross-document contradiction found. Provider configuration, signed-claim behavior, email delivery, session revocation and the no-email handoff still require the implementation validation already required by the foundation contract.
