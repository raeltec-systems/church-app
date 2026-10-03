# Authentication update review — 2026-10-03

**PASS — the approved authentication change is adopted by the spec and architecture.**

Phone number is an unverified username, used with a password. Email is optional; recovery requires a previously verified, approved email on the same account. Members without email use identity-checked staff assistance. Registration, sign-in, credential changes and recovery send no SMS. Church/cell approvals, existing security holds and stable member identity remain separate from authentication.

## Updated contract

- [Spec kernel](../../spec-church-app/spec-church-app.md): CAP-3 and dependent constraints; all 17 capability IDs retained.
- [Current functional requirements](../../spec-church-app/functional-requirements.md): full baseline plus approved authentication update. Original spec 1.2 remains unchanged as an audit source.
- [Design contract](../../spec-church-app/design-contract.md): password forms, optional recovery email and staff-help states supersede prototype OTP interactions; all 32 screenshot references retained.
- [Delivery and decisions](../../spec-church-app/delivery-and-decisions.md): Q1 authentication route resolved; operational setup remains gated. All six additions and seven milestones remain in v1.
- [Acceptance map](../../spec-church-app/acceptance-map.md): all 23 compound launch checks retained, with updated authentication checks and negative recovery cases.
- [Architecture](../architecture-church-app.md): AD-3 amended and AD-20 added; existing AD IDs remain stable.

## Independent reviews

| Review | Final result |
| --- | --- |
| [Functional baseline preservation](auth-update-reconcile-requirements.md) | PASS |
| [Spec kernel reconciliation](auth-update-reconcile-kernel.md) | PASS |
| [Design reconciliation](auth-update-reconcile-design.md) | PASS |
| [Delivery reconciliation](auth-update-reconcile-delivery.md) | PASS after email activation gate clarification |
| [Acceptance reconciliation](auth-update-reconcile-acceptance.md) | PASS |
| [Architecture rubric](auth-update-review-rubric.md) | PASS |
| [Technology evidence](auth-update-review-evidence.md) | PASS, including final recovery correction |
| [Adversarial compatibility](auth-update-review-adversarial.md) | PASS after recovery-grant correction |

## Resolved corrections

- Production email setup gates verification/email recovery, not otherwise valid phone/password access for members without email.
- Assisted password-setup grants bind the current reviewed case, member, account, approved link revision and recovery/credential generation. Replacement, credential changes, relinking, cancellation and lifecycle restrictions invalidate obsolete grants. Concurrency control, serialized external resets and fencing prevent replay or stale completion from acting on a different current identity or clearing a hold.
- Direct Auth routes remain subject to trusted password-authentication and live-session gates. Optional email is a native same-account alias; the product UI is phone-first, and recovery or OTP sessions alone grant no private access.

## Verification and limits

Architecture lint reports zero findings. Static checks confirm 17 mapped capabilities, 20 ascending AD IDs, all 23 launch-check references, 32 unchanged screenshot references and 58 resolving local references across six contract files. All 16 non-auth capability blocks, 18 prior non-auth AD blocks and 18 non-auth launch bullets are unchanged. Original brief/spec inputs and design-handoff files have no git diff; whitespace checks pass.

This validates documents, not a running auth implementation. No application code, provider configuration, deployment or live data was changed. Trusted direct-credential-change detection, assisted recovery, session invalidation and concurrency handling must be proved against the deployed provider in the foundation milestone. Operational owners, password/abuse/dormancy controls and production email configuration remain Q1 implementation gates; other policy gates remain as recorded. The next workflow is bmad-ticket using the updated spec and adopted architecture.
