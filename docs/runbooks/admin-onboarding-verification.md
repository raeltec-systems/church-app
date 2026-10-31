# Owner-invited Admin onboarding: verification and release boundary

This runbook covers the new commissioning service and user-management APIs. It is not permission to activate real enrollment. The approved implementation plan remains in progress.

## What this rehearsal exercises

The two scenarios use the actual locally served `identity-admin-onboarding` Edge Function, the purpose-bound system command, PostgreSQL, GoTrue and the ordinary authenticated APIs. Public registration is disabled. `new` commissions an absent account; `existing` explicitly binds an existing account and authenticates its current password without resetting it. Each scenario races two HTTP submissions, verifies one member/account/link/Admin, signs in normally, exercises member creation, profile correction, replay, conflict, directory filtering, activity projection and permission denials, and checks service logs for setup-secret leakage.

A transaction-scoped pgTAP completion test separately checks purpose isolation, refusal of user-editable provider correlation, single-grant completion, session revocation, held-account replay refusal and enrollment-data erasure. The user-management directory, profile editor, activity and target-specific support screens are implemented; database tests are not a substitute for their normal-interface walkthrough.

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

## Operator recovery and normal browser rehearsals

Run the operator rehearsal **sequentially** after the ordinary HTTP scenarios, with a fresh disposable database and phone sign-in enabled:

```powershell
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/admin-onboarding-operations.mjs --evidence "$env:TEMP\church-admin-owner-evidence\operator.jsonl"
node tools/auth-harness/local-phone-auth.mjs off
```

This drives the actual restricted CLI and GoTrue create/delete endpoints. A lost provider response is deliberately injected at the reservation boundary, not mistaken for a real network outage. It checks revocation, same-state retries, absent/present orphan reconciliation, late-call refusal, unknown deletion, preservation of an existing account and private evidence. Each run resets only its checked disposable database.

The optional rendered browser harness requires a **staff web build configured for this exact local API and publishable key**, Chrome and Playwright already installed in a separate tooling directory. It does not install dependencies or deploy anything:

```powershell
$env:CHURCH_PLAYWRIGHT_MODULE = '<absolute path to the installed playwright module>'
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/admin-onboarding-browser.mjs --web-root '<absolute path to the matching apps/staff/build/web>' --evidence "$env:TEMP\church-admin-owner-evidence\browser\results.jsonl"
node tools/auth-harness/local-phone-auth.mjs off
```

Use the recorded evidence ledger for exact source and tool versions. Do not treat an authored or partially completed harness as a passing scenario. A browser result establishes only the actions it actually exercised; full multi-account role/hold/restoration and device-owner acceptance remain separate. Run a single database/browser harness at a time and wait for its cleanup before starting another.

## What remains before real enrollment

The implementation includes the restricted operator CLI, guarded reconciliation/expiry/orphan cleanup, and normal filtered directory/profile/contact/activity/support UI. Read [operator instructions](admin-onboarding-operations.md) and [owner walkthrough](admin-onboarding-user-management-walkthrough.md).

Independent security review, complete new-path restore/deletion acceptance, any tool-blocked multi-account browser checks and the owner pilot remain open. Passing existing restore regression does not establish every new enrollment recovery scenario. Do not weaken privacy or permission checks to turn an unverified case into a pass.

Real enrollment requires the appropriate approved personal-data notice and privacy policy, environment-specific system credentials and origin configuration, and candidate-specific deployment approval. Setup does not approve these itself. Private access can remain activation-pending after enrollment. Losing the last usable Admin never reopens first-time setup.

No production or staging deployment follows automatically from this runbook, a passing CI run, or a passing local rehearsal. Keep PR #8 draft until the required independent review and release prerequisites are complete.
