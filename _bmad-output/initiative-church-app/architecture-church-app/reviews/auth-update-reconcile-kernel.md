# Auth update reconciliation — spec kernel

**Verdict: PASS.** No blocking mismatch between the current spec kernel and architecture spine for the approved phone/password, optional verified email recovery and no-SMS change.

Reviewed 2026-10-03. Inputs: `../architecture-church-app.md`, `../../spec-church-app/spec-church-app.md`, with targeted corroboration from the new functional-requirements companion and acceptance map. This is source reconciliation, not a claim of deployed Auth or application verification. Canonical memlogs were not read or changed.

| Check | Result |
| --- | --- |
| Stable capability identity | Kernel retains exactly CAP-1 through CAP-17, with one intent and one success statement each. The architecture map contains the same 17 IDs exactly once. Existing AD-1 through AD-19 remain; AD-20 captures the approved auth change. |
| CAP-3 approved authentication | Phone username/password without SMS, optional verified same-account recovery email, and identity-checked assistance without email match AD-3 and AD-20. Phone ownership is not inferred from a username or provider auto-confirmation. |
| Identity and authority | Kernel separates stable member identity, approval, cell confirmation and access review; AD-3 preserves that separation, reviewed linking and live holds/session/binding checks. Recovery grants no membership, new identity or private-data entitlement. CAP-4 remains consistent with the architecture's shared authorization predicate. |
| Alternate native routes | Kernel does not promise server-enforced recovery-only email or ban a native same-account email/password alias. Its non-goal is a separate email-first product flow. AD-20 makes the provider limitation explicit while retaining the phone-first UI and identical private-access gates. |
| Companion authority | `functional-requirements.md` becomes the current detailed contract; original spec 1.2 remains audit-only. The kernel adopts the architecture as a required companion, and the architecture names the current kernel/functional/design/delivery/acceptance sources. All five companion paths resolve. Behavioral requirements remain in the spec; implementation decisions remain in the architecture. |
| Remaining capability scope | All six first-release additions, seven milestones, November 2026 target, fewer than 200 members, shared Flutter/Supabase mobile/web records and conditional chat remain aligned. No other capability is removed or made optional by the auth change. |
| Constraints and non-goals | No SMS signup/login/recovery, no shared credentials or phone-based automatic merge, and no custom password store match AD-3/AD-20. Public caching, sensitive-data privacy, independent consent/attendance/receipt facts, instruction-only giving and web accessibility gates remain intact. |
| Success and unresolved decisions | The kernel preserves outcome-based capability success and 23 compound launch checks. Q1 now covers operational owners, password/abuse/dormancy controls, email configuration and assisted recovery; removed SMS vendor/risk/fallback gates are not reintroduced. AD-20 and Deferred agree. Q2–Q12 retain their original policy/acceptance scope, including provisional numerical targets. |

The spine is correctly still marked `draft` during reconciliation and reviewer gates; finalization should follow those gates. Provider behavior and account-recovery mechanisms remain subject to foundation/deployed-version tests, as explicitly stated in AD-18/AD-20 and the technology evidence. No kernel-level correction is required before the reviewer gate.
