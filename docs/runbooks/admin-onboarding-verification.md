# Owner-invited Admin onboarding: verification and release boundary

This runbook covers the new commissioning service and user-management APIs. It is not permission to activate real enrollment. The approved implementation plan remains in progress.

## What this rehearsal exercises

The two scenarios use the actual locally served `identity-admin-onboarding` Edge Function, the purpose-bound system command, PostgreSQL, GoTrue and the ordinary authenticated APIs. Public registration is disabled. `new` commissions an absent account; `existing` explicitly binds an existing account and authenticates its current password without resetting it. Each scenario races two HTTP submissions, verifies one member/account/link/Admin, signs in normally, exercises member creation, profile correction, replay, conflict, directory filtering, activity projection and permission denials, and checks service logs for setup-secret leakage.

A transaction-scoped pgTAP completion test separately checks purpose isolation, refusal of user-editable provider correlation, single-grant completion, session revocation, held-account replay refusal and enrollment-data erasure. The ordinary user-management schema tests are not a substitute for its unimplemented staff UI.

## Required isolation

Use a separate disposable checkout with a separate Supabase project. The runner refuses `church-app`, hosted endpoints, ports 54321/54322, existing Auth/member rows, a commissioned database, and a pre-existing Edge container. It requires a `church-admin-*` project, validates the Docker container identity, network and ports, and resets that disposable database at the end. Do not weaken these guards to run it against an existing installation.

The recorded verification checkout is:

```text
C:\Users\Administrator\church-admin-final-verification-20261031
```

It uses project `church-admin-backend-20261031`, API 56421, database 56422 and inspector 8483. Its test-only config disables signup and has no credentials. The published evidence contains the exact config and its hash. This is not a config to copy over the normal project's file or any hosted environment.

## Repeat on that disposable checkout (PowerShell)

Docker must be running. Use the repository's locked Node/Supabase tooling. Run these sequentially, not while another checkout uses this same disposable project. Check `$LASTEXITCODE` after each command; stop on a failure.

```powershell
cd C:\Users\Administrator\church-admin-final-verification-20261031

git rev-parse HEAD
npm ci
npx --no-install supabase start -x studio,imgproxy,mailpit,edge-runtime,logflare,vector,supavisor,realtime,postgres-meta
npx --no-install supabase test db

New-Item -ItemType Directory -Force "$env:TEMP\church-admin-owner-evidence" | Out-Null
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/admin-onboarding.mjs --scenario new --evidence "$env:TEMP\church-admin-owner-evidence\new.jsonl"
node tools/auth-harness/local-phone-auth.mjs off

node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/admin-onboarding.mjs --scenario existing --evidence "$env:TEMP\church-admin-owner-evidence\existing.jsonl"
node tools/auth-harness/local-phone-auth.mjs off

npx --no-install supabase stop --no-backup
```

Each scenario removes only its own Edge process/container, removes its temporary secret file, and resets the verified disposable database. Successful cleanup is a recorded assertion, not assumed. A guard refusal is a blocked run, not a pass. Never run a force-removal or reset on another project to make a test start.

Keep Supabase `start` and `status -o env` output private: they can contain local credentials. Share only the redacted JSONL evidence and test summaries after scanning them. Do not share passwords, invitation values, access/refresh tokens, function environment files or raw Auth responses.

## What remains before real enrollment

The normal first-Admin wizard exists, and these tests exercise its actual server protocol, but an authenticated browser/device walkthrough is still required. The following are implementation gaps, not test-environment limitations:

- The complete secure operator CLI for issuing, revoking and inspecting invitations.
- Controlled reconciliation and orphan cleanup when provider creation remains uncertain with no account visible; safe expiry/unclaimed-invitation cleanup. The current code intentionally prevents unsafe reissue rather than claiming recovery is finished.
- The new filtered directory, profile/contact editor and activity view in the normal Users & access screen, plus selected-person continuity through recovery/lifecycle queues. The current workspace still reuses the older screens.

Full new-path deletion/restore coverage, independent security review and owner acceptance remain open. A passing historical restore suite does not establish that every new enrollment scenario has been restored and reconciled.

Real enrollment requires the appropriate approved personal-data notice and privacy policy, environment-specific system credentials and origin configuration, and candidate-specific deployment approval. Setup does not approve these itself. Private access can remain activation-pending after enrollment. Losing the last usable Admin never reopens first-time setup.

No production or staging deployment follows automatically from this runbook, a passing CI run, or a passing local rehearsal. Keep PR #8 draft until the approved scope and required review are complete.
