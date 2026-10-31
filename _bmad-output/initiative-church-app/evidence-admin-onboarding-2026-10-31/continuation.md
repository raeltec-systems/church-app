# Admin onboarding and user management ? continuation boundary

Owner approval is recorded. The plan is in progress, not built or accepted.

## Client functionality in the feature branch

`/setup/admin` is reachable from the staff sign-in landing through **Have an owner setup invitation?** The client validates its form, asks the commissioning service to inspect the invitation, renders the returned privacy notice, and handles new/existing-account setup, refusal, expiry, unavailability, activation pending and uncertain completion. It never creates an Auth session from a provisioning reply. Secrets stay in request bodies and transient form/controller memory; the transport refuses redirects. A pending request is checked by its original ID, including after returning with the same invitation.

`/admin/users?view=members` is an additive Admin-only staff workspace. It opens the existing approved-member search/table and selected-person panel, and routes to the existing applications, grants, credential reviews, recovery-email reviews, assisted recovery, membership lifecycle, deletion and username-dispute screens. Those screens retain their existing server adapters/commands. Old routes remain available. Observed Admin loss clears the workspace and invalidates its cached private providers.

## Functionality still unfinished

The first-Admin endpoint used by the client, `identity-admin-onboarding`, has NOT been implemented. Invitation issuance/revoke/reissue, the durable one-time commissioned marker, account-bound server validation, privileged Auth provisioning, concurrency fencing, uncertain-outcome reconciliation and enrollment lifecycle/erasure integration are missing. No genuine invitation exists and this UI cannot yet create the first real Admin.

The new bounded all-status/role-filtered management directory, ordinary profile/contact correction commands, safe administrative activity projection and selected-person continuity across recovery/lifecycle queues are also unfinished. A dropdown around existing screens is useful navigation, but is not completion of that approved scope.

## Tool block and smallest manual step

A combined source-inspection/migration-preparation call was safety-blocked before execution. It cannot establish which subcommand triggered the block. It was not retried by another route. No new migration was created or applied.

On the connected Windows machine, from the feature worktree, run:

```powershell
cd C:\Users\Administrator\church-app-admin-onboarding
git branch --show-current
npx --no-install supabase migration new identity_admin_onboarding
Start-Sleep -Seconds 2
npx --no-install supabase migration new identity_user_management
Get-ChildItem supabase\migrations\*identity_admin_onboarding*.sql,supabase\migrations\*identity_user_management*.sql |
  Select-Object Name, Length
```

The branch must be `feature/admin-onboarding-user-management`. These commands only create empty timestamped migration files. Return their names/output. They neither implement onboarding nor alter a database; do not apply or deploy them. There is no new SQL script ready for hosted execution yet.

## Resume implementation without reopening the approved scope

Use the approved plan and existing Identity registries/commands. Author and review the forward migrations in those CLI-generated files; do not rewrite historical migrations or broaden table grants. Build and test the actual constrained service/operator route and management projections before treating the client responses as production behavior. Setup must refuse live-data enrollment while its policy gate is closed, and commissioning must never reopen merely because no usable Admin remains.

Run the real isolated database/Auth/HTTP cases with public signup disabled: expiry/revoke/replay/wrong-account, preexisting account collisions, two parallel attempts, interrupted external provisioning and safe reconciliation. Exercise the completed workflows through the normal clients. Keep passwords/invitation tokens out of logs and artifacts; no staff-set password or fabricated first-signup approval.

The existing Vercel deployment and published Android APK are unchanged. No hosted account, grant, policy or notification was changed. Deployment, independent security review, native-device checks and owner acceptance remain separate.
