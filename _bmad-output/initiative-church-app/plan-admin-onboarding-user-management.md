---
title: 'First Admin onboarding and user management'
type: 'feature'
ticket: ''
created: '2026-10-31'
status: 'draft'
baseline_revision: '6f5cfe78afb99f0e572a285ad7421215eb6e978b'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/spec-church-app/design-contract.md'
  - '{project-root}/docs/runbooks/identity-support.md'
---

<frozen-after-approval reason="human-owned intent; locks only after approval">

## Intent

**Problem:** First production Admin enrollment is missing; signup waits for that Admin. Existing user management is substantial but fragmented.

**Approach:** Complete owner-authorised enrollment and a Users & access workspace over existing Identity operations. Israel is already the nominated first Admin. Preserve the member/account/role model.

## Boundaries & Constraints

**Always:** Current-session checks, separate membership/account/scope states, last-Admin and handover protection, audited changes, policy gates and approved design. Users choose passwords privately. One-time commissioning never reopens merely because usable-Admin count becomes zero.

**Never:** First-signup-wins, staff-set passwords, impersonation, broad Auth/table access, phone-based auto-linking or Admin care/finance access. No hosted mutation, deployment, merge, policy approval or acceptance closure in this build scope.

## I/O & Edge-Case Matrix

| State/action | Required behaviour |
| --- | --- |
| Authorised setup; public signup closed | One intended member/link/Admin; ordinary password sign-in follows. |
| Invalid, expired, revoked, replayed or wrong-account authority | Refuse without privilege change. |
| Parallel setup, provider timeout or account collision | Fence/reconcile one operation; never reset/adopt an unrelated account. |
| Commissioned environment loses all Admins | Setup remains closed; existing recovery applies. |
| Search/filter/select/change person | Bounded current data; correct owner commands, revisions and audit. |
| Stale session, lost connection, conflicting edit | Deny or retry truthfully; clear protected state when access ends. |

</frozen-after-approval>

## Code Map

Read `admin-onboarding-user-management-audit.md` for inspected source locations. Reuse `membership_review_screen.dart`, `member_detail_panel.dart`, access/recovery/lifecycle screens and adapters under `packages/client_core/lib/src/`. Preserve approved-only search for existing pickers; add a dedicated bounded management projection. Reuse Identity registries and external-operation fencing, not a second auth store.

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/`: CLI-generate forward enrollment and management migrations. Implement restricted commissioning/provenance, durable terminal state, commands, bounded directory/activity reads and safe profile/contact corrections; register erasure ownership.
- [ ] `supabase/functions/identity-admin-onboarding/`, `tools/ops/admin-onboarding.mjs`: constrained Auth provisioning and restricted issue/revoke/status, with server-owned correlation, rate limits, secret hygiene and uncertain-outcome recovery. Public signup and session trust remain unchanged.
- [ ] `packages/client_core/lib/src/`: add `domain/admin_onboarding.dart`, `application/admin_onboarding_controllers.dart`, `adapters/supabase_admin_onboarding_repository.dart`, `presentation/admin_onboarding_screen.dart`; wire real status, submission and retry.
- [ ] Same source root: add `domain/user_management.dart`, `application/user_management_controllers.dart`, `adapters/supabase_user_management_repository.dart`, `presentation/user_management_screen.dart`. Provide search/state/role filters, selected-person profile/contact edits and activity; integrate existing approvals, role grants, recovery, holds, deactivation/restoration and deletion with target context and current safeguards.
- [ ] `packages/client_core/lib/composition.dart`, `packages/client_core/lib/src/presentation/shell_routing.dart`, `apps/staff/lib/app.dart`: real providers/navigation, compatible old routes, unchanged mobile tabs.
- [ ] `supabase/tests/admin_onboarding_test.sql`, `supabase/tests/user_management_test.sql`, `tools/identity-e2e/admin-onboarding.mjs` and matching Flutter/Edge tests: matrix, privacy, concurrent setup, real HTTP/provider recovery and cleanup.
- [ ] `docs/runbooks/identity-support.md`, `docs/runbooks/production-promotion-identity.md`: replace gap statements only after evidence; document activation and actual user walkthrough.

**Acceptance:**
- Given owner-authorised enrollment and closed signup, when setup completes, then the intended person can sign in as Admin without manual table editing; no policy gate is implicitly opened.
- Given each role/account state, when using the normal management UI, then persistence, audit, permission denials and recovery concern the correct person; contact edits never change login bindings.
- Given concurrent clients or revoked authority, when actions run, then no duplicate privilege or unauthorised detail survives.
- Given the approved references, when using desktop/narrow layouts and keyboard/text scaling, then the table/detail and error/retry flows remain usable.

## Open Questions

1. Approve **owner-issued, account-bound setup invitation** (recommended: 24-hour expiry, secure manual delivery, revoke/reissue), or retain **operator approval of a pending application**? The former supplies normal onboarding while public signup stays closed. The latter still needs an authorised initial Auth-enrollment step. Neither allows public self-promotion. Record this security choice before coding; activation approvals remain separate.

## Implementation Notes

Investigation only; new isolated branch, baseline preserved. Full route exceeds 100 lines. BMAD step-02 human checkpoint remains open. No independent review or new feature tests have run. Epic 6/7 statuses remain unchanged.

## Plan Change Log

## Review Triage Log

## Verification

Run pinned `supabase test db` in an isolated project; real HTTP setup with signup disabled and simultaneous/replay/timeout cases. Run `flutter analyze`, `flutter test` in affected packages/apps, `flutter build web`, `flutter build apk` and bundle scanning. Repeat identity/grant/recovery/lifecycle regressions. Witness staff and Android flows on the same candidate. Retain failures and require independent security review before rollout; hosted SQL and Vercel/APK publication need separate approval.
