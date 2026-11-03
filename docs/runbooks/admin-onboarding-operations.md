# Owner-invited first Admin: restricted operations

This is the implementation runbook, not deployment approval. The feature is on the Admin-onboarding branch. The currently published staff site/APK must not be assumed to contain it. Never run local rehearsals against hosted projects.

## Who does what

The owner nominates the intended first Admin. The restricted operator `israel` checks that identity, prepares one account-bound invitation, and delivers it privately. The intended person opens **Have an owner setup invitation?**, enters the invitation and phone username, chooses their own password (or proves their existing password), reads the current approved notice, and completes setup. They then sign in normally. The operator never asks for, chooses, views or resets that password.

This is **first installation**, not account recovery. If the commissioning marker is already set, including installations that previously had an Admin, the wizard cannot reopen it. Use normal Users & access or the identity-checked last-Admin recovery procedure in [identity support](identity-support.md#rb8-identity-checked-last-admin-fallback). Never clear the latch or delete historical grants to make first-time setup available.

## Deployment prerequisites (separate approval)

Before issuing any hosted invitation, the release reviewer must establish all of the following:

- Both new feature migrations are reviewed, applied to the intended environment, and verified, including the Auth insert/update/deferred-commit guards. Promote via the repository's controlled process; do not paste individual function bodies into a serving database.
- The `identity-admin-onboarding` Edge Function is deployed with JWT gateway verification disabled **for this function only**. Its invitation and purpose-bound system command authenticate setup; disabling the gateway is not permission to skip those checks.
- Set server-only `IDENTITY_ADMIN_SETUP_ENVIRONMENT`, `IDENTITY_ADMIN_SETUP_SYSTEM_CREDENTIAL` and `IDENTITY_ADMIN_SETUP_ALLOWED_ORIGINS`. The origins are exact approved staff origins, without paths or wildcards. The platform's Auth admin/service key stays in the function, never the staff build, browser, invitation or repository.
- Register the system credential digest for a principal whose sole purpose is `identity_admin_onboarding` and whose command is `identity.admin_setup`, using the existing restricted system-access procedures. Do not reuse a notification/deletion/recovery principal. Follow [system access](system-access-and-operations.md) for credential protection, rotation and revocation. The credential is not an invitation.
- Phone/password Auth is available without SMS. Public signup can remain disabled throughout first-Admin setup. Opening ordinary registration is a separate rollout decision.
- Live enrollment requires **explicit approved Q4** and a reviewed `privacy_notice` object in its approved value: a version token and notice text. Code does not supply or approve church policy. Local/staging fictional enrollment uses the clearly labelled synthetic notice only. The independent `private_access` gate remains authoritative; a prepared account may correctly report **activation pending**.

The staff client receives only `SUPABASE_URL` and the publishable key. Do not put any server credential in a Dart define or a Vercel client environment.

## Issue an invitation

From the repository, use the pinned Node 22 toolchain. Run `node tools/ops/admin-onboarding.mjs --help` for the complete syntax. All commands require an explicit environment and target confirmation.

Example **only after staging release approval and prerequisites**:

```powershell
node tools/ops/admin-onboarding.mjs issue `
  --env staging `
  --project-ref tmurpotfluignacfueki `
  --confirm-target tmurpotfluignacfueki `
  --state-dir "$env:USERPROFILE\.church-ops\staging\admin-setup-001"
```

The CLI asks for the intended normalized phone username, whether this is fictional test data, the identity-check code, the non-personal case reference, and an explicit existing Auth account id or blank for a new account. A matching phone never automatically claims an account. For an existing account, use the reviewed exact account id; the person will prove their current password in the wizard.

Hosted operator calls require `SUPABASE_ACCESS_TOKEN` in the process environment. Hosted orphan deletion additionally requires `SUPABASE_SECRET_KEY` in that environment. Do not paste either value into a shell command, a transcript, a chat, an invitation, or the repository. Use the established private credential mechanism. Production also requires the separately configured approved production project reference; an unknown target is refused.

A local rehearsal uses `--env local --confirm-target <exact isolated project_id>` instead of `--project-ref`. The CLI checks the matching local Docker container and the database environment marker; it does not select the first running database.

The state directory is private. New directories are owner-only (with system access on Windows); existing insecure or symlinked material is refused, not silently repaired. The CLI writes **`invitation.json` before contacting the database**, so an interrupted response does not lose the only usable invitation. It contains the secret and intended phone. Open it privately and deliver only the invitation to its intended holder through the agreed private channel. Never put it in a URL. The CLI's printed result contains state and expiry, not the usable invitation, password or server key.

An optional `--request-file` accepts a **private** JSON file with exactly:

```json
{
  "phone_username": "+447700900818",
  "existing_account": null,
  "synthetic": true,
  "identity_check": "in_person",
  "case_reference": "SETUP-local-example"
}
```

This is fictional test data, not a real-user template to execute in production. The file cannot contain a password, chosen role or arbitrary provider metadata. Do not add one.

## Interrupted issue or setup

Use the **same state directory**:

```powershell
node tools/ops/admin-onboarding.mjs status --env staging --project-ref tmurpotfluignacfueki --confirm-target tmurpotfluignacfueki --state-dir "$env:USERPROFILE\.church-ops\staging\admin-setup-001"
```

If issue lost its response, status looks up its prepared digest. Retrying `issue` with the same private state preserves the invitation and original expiry; it does not mint another or extend the 24-hour window. An issued invitation is not a completed account.

The app's **Check setup status** reconciles the original request and never automatically resends a password. `pending`/`uncertain` is not success. An operator should first check status and communicate with the intended holder before cancelling an unresolved attempt.

## Revoke, reconcile and clean up

Use the same target arguments as above, changing the verb:

| Verb | Purpose and effect |
| --- | --- |
| `status` | Read state without provisioning or granting access. |
| `revoke` | Immediately removes invitation authority. An in-flight new-account creation may still require reconciliation. |
| `reconcile` / `cleanup` | Explicitly cancels an uncompleted attempt, fences any late provider creation, and resolves its orphan account if safely attributable. This is not an automatic retry of enrollment. |
| `candidates` | Lists up to 25 actionable expired/revoked/failed/provisioning entries without usable codes or personal contact values. No state directory is needed. |

For a listed entry, `--invitation-id <id>` may be used instead of a state directory with status/revoke/reconcile/cleanup. A state directory and explicit id cannot select different records.

Outcomes must be interpreted literally:

- **`cleaned`**: no new-account orphan remains. Its temporary invitation data is erased, and late provider writes are fenced. The precise orphan's contact-bearing Auth audit entries are removed; unrelated Auth history is untouched. An existing-account invitation cleanup leaves the account and password intact.
- **`cleanup_pending`**: provider deletion is unconfirmed or the account is still visible. Reissue remains blocked. Retry reconciliation; do not edit tables or reset the password.
- **`operator_review_required`**: account correlation/history does not permit automatic orphan deletion. Stop and use a reviewed identity-support decision. Never delete an unrelated or linked account to clear this state.
- **`completed`**: an actual commissioned member/Admin is never removed by this command. After invitation expiry, cleanup may remove only its temporary enrollment material; the permanent installation latch and normal account remain.

A cleaned/expired invitation is not reusable. After confirming cleanup, issue a new invitation using a **new private state directory**. Check identity again as appropriate. Remove private local invitation files once no longer needed, under the approved operator retention procedure. Do not retain them in test evidence.

## Normal app verification

The onboarding wizard must complete through the rendered staff client, followed by ordinary password sign-in. An endpoint returning `completed` alone is not UI acceptance. For Users & access, use [the staff walkthrough](admin-onboarding-user-management-walkthrough.md). For isolated operator/Auth regression commands, use [verification](admin-onboarding-verification.md).

No command here implicitly approves Q4, private access, production system access, notification sending, a deployment, a merge or owner acceptance.
