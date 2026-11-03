# Admin onboarding and user-management audit

Observed 31 October 2026 at source `6f5cfe78afb99f0e572a285ad7421215eb6e978b`. This is a source/design inspection, not a new signed-in UI acceptance run. Implementation has not started. Feature branch: `feature/admin-onboarding-user-management`, a clean isolated worktree based on the current acceptance branch; verified main remains `c96cd562b2650c37f5d3d879cb12891419700139`.

## What the product already has

It would be incorrect to describe user management as absent. The source has membership applications and identity-checked approvals/linking; accountless member records; a searchable member table with a detail panel; explicit role grants/revocations; credential review, login holds, recovery, deactivation/restoration, deletion and handover. These are real screens, adapters and server operations, not just proposed runbook topics. Their existence is distinct from fresh end-to-end verification on the deployed candidate.

| Capability | Concrete reuse point |
| --- | --- |
| Applications, linking, accountless records and member search | `packages/client_core/lib/src/presentation/membership_review_screen.dart`; `supabase/migrations/20261007063340_membership_review.sql` |
| Member detail with roles, hold, deactivate and unlink actions | `packages/client_core/lib/src/presentation/member_detail_panel.dart` |
| Role/scoped-access administration | `packages/client_core/lib/src/presentation/access_screens.dart`; `supabase/migrations/20261006234820_identity_grants.sql` |
| Recovery, credential and lifecycle workflows | `assisted_recovery_screens.dart`, `credential_screens.dart`, `membership_lifecycle_screen.dart`, `member_deletion_screens.dart` under `packages/client_core/lib/src/presentation/` |
| Real server adapters | `supabase_review_repository.dart`, `supabase_grants_repository.dart`, `supabase_credential_review_repository.dart`, `supabase_membership_lifecycle_repository.dart`, `supabase_member_deletion_repository.dart` under `packages/client_core/lib/src/adapters/` |
| Existing navigation | `apps/staff/lib/app.dart` People section; `packages/client_core/lib/src/presentation/shell_routing.dart` existing `/admin/*` routes |

## Confirmed gaps and constraints

**First real Admin enrollment is missing.** `docs/runbooks/production-promotion-identity.md` explicitly records that the production first-Admin path is not implemented. `app.identity_bootstrap_admin` can grant Admin only to an already approved member with a usable account link. Synthetic seeding is not the production enrollment solution.

**There is a deployment-order deadlock, not merely a missing button.** Production public signup remains disabled until the privacy gate and first-Admin setup have completed. A procedure that only approves an already-created application does not on its own explain how that first Auth account is safely created while signup is closed. Resolve this through a narrowly authorised enrollment path; never temporarily open public signup and promote the first registrant.

**The owner identity is already decided.** `owner-decisions-milestone-2.md`, G8, names Israel as the first real Admin. Do not ask him to choose the first Admin again. Personal identifiers and passwords belong in the deployment/setup flow, not in repository examples or chat.

**The current directory is approved-member-only.** `app.identity_admin_member_search` filters `membership_state = 'approved'`. Deactivated members are managed elsewhere. The table separately loads every grants-roster page to obtain roles. A unified management view needs its own bounded server projection and explicit filters; silently widening the existing search could break approved-member linking/pickers.

**The existing profile panel is not a general account editor.** It distinguishes contact routes from login credentials, but currently presents an approved-member profile rather than a complete lifecycle view. Add auditable ordinary profile/contact corrections and state-aware navigation to the existing protected workflows. A profile edit must never directly change an Auth username, recovery binding, password, hold or role.

**Existing audit storage is not a new activity viewer.** Reuse the Identity audit records through a restricted, bounded projection of allowed metadata. Do not expose raw audit tables, tokens, Auth internals, historical contact values, private care notes or finance data.

## Proposed normal experience

The one-time first-Admin wizard opens only with explicit owner/operator authorisation. The intended person chooses their own password, completes the required profile/privacy steps, and reaches a clear result or resumable failure. Subsequent private use requires ordinary password sign-in and all existing policy/session checks. Creating the first Admin must not automatically approve privacy, private-access, sending or retention gates.

A staff **Users & access** destination brings together the searchable member/account directory, applications, role and scope summary, targeted access/recovery actions and administrative activity. Membership status, account status and permissions remain separate concepts. Existing `/admin/*` links continue to work. Routine staff access remains a deliberate role grant to an identity-checked member, not an automatic consequence of registration or matching a phone number.

The profile can offer approved actions in context, including recovery review, hold/release, deactivation/restoration and deletion status. These must call the existing owner commands and preserve their two-person, last-Admin, handover and stale-revision rules. A generic link to an unrelated queue is insufficient where the user must continue working on a selected person.

## Setup design proposed for owner approval

Recommended: an operator-issued, short-lived, single-use setup invitation bound to the intended enrollment and environment. Public signup stays closed. A constrained server route provisions the Auth account only after validating that authorisation; the browser/mobile client never receives server authority. For an existing account, require fresh password authentication and explicit account binding instead of resetting or claiming it by username.

The initial authorisation is the trust root: no anonymous visitor can request their own Admin invitation. An operator commissioning command is acceptable once per environment; everyday member/staff work must then use the normal app. Manual delivery avoids assuming SMTP/SMS is configured. The setup secret is not a password, must be hashed at rest, excluded from URLs/logs/analytics and never stored as ordinary profile data. Propose 24-hour expiry, explicit revoke/reissue and at most one active first-Admin enrollment.

Persist a terminal commissioned marker, including on upgrade where any earlier Admin grant proves an environment was already commissioned. Zero currently usable Admins must NOT reopen first-time setup; the existing independently checked last-Admin recovery remains separate. Record the authorised identity-check basis and commissioning provenance without fabricating a normal Admin's self-approval.

Auth creation and the database transaction are separate systems. Reserve a durable operation identity before the external call; fence concurrent requests and reconcile uncertain outcomes only against server-owned correlation. No success until the approved member/account link, intended Admin grant, audit record and consumed enrollment are consistent. A collision, cancellation, expiry or changed authority must not leave a privileged orphan or silently adopt an unrelated account. Extend lifecycle/deletion/journal coverage to new enrollment records before activation.

This is a proposal, not an approved security-policy change or an implemented flow. The BMAD plan retains its human checkpoint before coding this new privileged enrollment path.

## Design evidence and validation boundary

Inspected `docs/design-handoff/screenshots/admin-02-applications.png` and `admin-03-members-panel.png`. Preserve their navy sidebar, light canvas, segmented navigation, member table/selected row and detail panel, using `packages/design_system` and the binding `spec-church-app/design-contract.md`. Do not copy simulated role switches, example identities, unavailable fields or fake counts. Mobile's five public tabs stay unchanged.

Implementation must prove first-use, reused/expired/revoked/wrong-account tokens, parallel setup, closed signup, provider timeout/recovery, existing-account collision, role revocation, no-Admin care/finance access and last-Admin protection. Execute normal web/mobile UI flows plus database/HTTP tests. The current source/design audit does not prove these new cases passed.

No migration, app change, account grant, policy approval, deployment, content publication or notification send occurred during this audit. Epic 6 acceptance and the separate Epic 7 plan remain unchanged.

## Primary provider documentation checked

- Supabase Auth `createUser`: https://supabase.com/docs/reference/javascript/auth-admin-createuser — privileged user creation is server-only; this is not proof of the proposed end-to-end enrollment protocol.
- Supabase sessions: https://supabase.com/docs/guides/auth/sessions — preserve the repository's live-session checks, not only a cached JWT.
- Supabase database functions: https://supabase.com/docs/guides/database/functions — retain restricted execute privileges and hardened explicit-schema functions.
- Changelog index fetched on 31 October 2026. No dependency upgrade was performed. Provider-specific failure/correlation behaviour remains an implementation test obligation.

## Planning validation

The rendered BMAD build workflow and step-02 were followed for the new feature. The draft has 1,361 tokens under `o200k_base`, all ten required plan sections and one explicit commissioning-design question. All 23 inspected source/design references checked on disk exist. Targeted credential scanning of the two new planning documents found no findings; staged whitespace validation passed. These are document checks, not application/security tests or independent review. No runtime source, migration, dependency lock, policy setting or acceptance status was edited.
