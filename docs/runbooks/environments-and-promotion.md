# Runbook: environments and promotion (story 1.8)

This runbook covers:

- three separate environments
- reviewed, non-destructive migration promotion
- immutable client builds
- secret scanning
- the owner-gated production baseline

Architecture: AD-17 and AD-18. Owner decisions: `_bmad-output/initiative-church-app/owner-decisions-milestone-1.md`.

## Environments

| | local | staging | production |
|---|---|---|---|
| Supabase | `supabase start` (Docker) | `bic-kafue-platform-test`, ref `tmurpotfluignacfueki`, eu-central-1, free plan | **not created yet** (owner gate) |
| Database marker (`app.platform_current_environment()`) | unset, so the database behaves as production; tests set `local` | `staging`, set 2026-10-03 by `israel` | set to `production` by the first promotion |
| Fixture policy values (Q2, Q9) | only when marked `local` | yes, labelled | never |
| `private_access` / `outbound_sending` gates | closed | closed | closed until the owner approves them in that database |
| Recipients | synthetic only (`*@example.test`, `*@example.com`, `*.invalid`) | synthetic only, plus the owner test inbox `israelmuyoba+<tag>@gmail.com` | none (sending disabled) |
| SMS | never | never | never |
| Secrets live in | nowhere (the local key comes from `npx supabase status`) | GitHub environment `staging` | GitHub environment `production` (required reviewer) |
| Staff web host | `flutter run` / `python3 -m http.server` | static host branch `staging` (optional) | static host branch `main` |

The non-secret settings are in `config/environments/{local,staging,production}.json`. `npm run env:check` enforces these rules:

- Each environment has its own project, and a non-production config never names the production ref.
- Every non-production recipient pattern is a reserved domain or the owner's plus-tagged test inbox.
- Production keeps `private_access`, `outbound_sending` and `sms` false, has no recipients and deploys only through the approval-protected `production` environment.
- The configs contain no secret-like values.

`tools/env/environments.mjs` exports these functions:

- `recipientAllowed` and `assertRecipients`: non-production sends only to synthetic recipients; production refuses everything while sending is disabled.
- `resolveDeployTarget`: a job for one environment cannot be pointed at another environment's project.

The future sending worker (durable-inbox epic) must use these guards or a server-side equivalent, and it must also respect the closed `outbound_sending` gate.

Clients only ever receive `SUPABASE_URL` and a publishable key (`sb_publishable_…`) through `--dart-define`. The secret key, service-role key, database password and access token are server/CI-only.

## What CI checks on every push and pull request (`.github/workflows/ci.yml`)

These checks need no secrets, so they pass from a clean checkout before any owner step.

- **policy**:
  - tests for the policy tools (`npm run ci:policy-test`)
  - `env:check`
  - the **migration policy** (`tools/ci/check-migrations.mjs --base <PR base | previous push>`):
    - Names follow `<14-digit version>_<snake>.sql`, and versions are unique.
    - Already-merged migrations are immutable: no edit, rename or delete.
    - Each new version is later than every merged version.
    - `DROP` / `TRUNCATE` outside comments and string literals fails unless the file has a `-- owner-approved-cleanup: <decision reference>` line. String literals include `'…'`, `E'…'` and dollar-quoted strings that are not function or `DO` bodies. Function and `DO` bodies are scanned as code. These forms are allowed:
      - `DROP NOT NULL`
      - `DROP DEFAULT`
      - `ON COMMIT DROP`
      - `DROP IDENTITY IF EXISTS` and `DROP EXPRESSION IF EXISTS`. Without `IF EXISTS`, these two still fail.
    - To retire an object, revoke all privileges and rename it (`retired_<name>_v0`). Drops wait for an owner-approved cleanup migration.
  - the **repository secret scan** (`npm run ci:secrets`), which looks for:
    - `sb_secret_…`, `sbp_…` access tokens, any JWT, private keys, GitHub tokens, long bearer tokens
    - `postgres://` URLs with a real password
  - **staging drift** (`npm run ci:drift:staging`):
    - It compares `supabase/migrations` with the hosted history from the Management API.
    - It fails when the hosted project has a version the repository lacks, a version's name differs, or a version would be applied out of order.
    - Newer local versions are reported as *pending*.
    - Until the `SUPABASE_ACCESS_TOKEN` repository secret exists, it prints a notice and passes.
- **db**: pgTAP permission and concurrency tests, Data API smoke tests and contract fixtures on the local stack (unchanged).
- **flutter**:
  - analyze, test and web builds (unchanged)
  - then the **bundle secret scan**: no JWT, `service_role` or secret key in `build/web`

To run the same checks locally:

```sh
npm ci
npm run ci:policy-test && npm run env:check && npm run ci:migrations -- --base origin/main && npm run ci:secrets
node tools/ci/check-migration-drift.mjs --env staging --hosted-file <list.json>   # e.g. saved MCP list_migrations output
```

## Promotion (`.github/workflows/promote.yml`, manual)

Start it from Actions, then **promote**, then **Run workflow** with target `staging` or `production`, on `main`. The workflow has four jobs, ordered by `needs`. Each job fails closed, and a failed job stops every job after it.

- **`checks`** reruns all CI checks from a clean checkout (`workflow_call`).
- **`preflight`** runs without a GitHub environment, so it never auto-creates one:
  - It refuses any ref other than `main`, for staging and production alike.
  - It runs `check-migrations.mjs --base origin/main` on full history.
  - For production only, it reads `GET /repos/{owner}/{repo}/environments/production` with `github.token`. It fails unless the environment exists and has a `required_reviewers` rule with at least one reviewer.
  - For production only, it fails if `SUPABASE_PROJECT_REF` resolves outside the environment, meaning it is defined at repository or organization level. The ref must live only on the `production` environment.
- **`staging-precondition`** runs for production only. Staging must already be synced with this commit (`--require-synced`).
- **`promote`** runs in the target environment, so production waits for the required reviewer's approval. Its steps run in this order:

1. It refuses any ref other than `main` again, and refuses a production run with no environment-scoped `SUPABASE_PROJECT_REF`.
2. It guards the target:
   - Staging takes its ref from `config/environments/staging.json`. Production takes it from the `SUPABASE_PROJECT_REF` variable.
   - A ref that belongs to another environment is refused.
   - Missing secrets fail with the exact owner step.
   - A key that is not `sb_publishable_…` is refused.
3. It runs the drift check, so nothing is applied over unexplained hosted changes.
4. Backend first:
   - `supabase link`
   - `supabase db push --dry-run`
   - `supabase db push` (no `--include-all`, so out-of-order versions are refused)
   - the drift check again with `--require-synced`
5. It handles the environment marker:
   - An unmarked database is marked with the target name.
   - A database that carries a different marker stops the run.
   - `tools/ci/verify-hosted.sql` then asserts the marker and that `private_access` and `outbound_sending` are closed.
6. Clients second:
   - It builds `apps/staff` once for this commit and environment with the URL and publishable key.
   - It runs the bundle secret scan.
   - It seals the build: a per-file SHA-256 (`staff-web-<env>.SHA256SUMS`) plus a manifest with the environment, commit, API URL and tree hash.
   - It uploads the artifact `staff-web-<env>-<sha>` and keeps it for 90 days.
7. Deploy:
   - It runs `package-web.mjs verify` (wrong environment or commit, added, missing or changed files all fail).
   - Then it runs `wrangler pages deploy` of exactly that directory.
   - Without the hosting secrets, the job ends after the upload with a notice. The verified artifact is the deliverable.

For production, all of the following must hold:

- the run is on `main`
- the `production` environment is protected by required reviewers (checked by `preflight`)
- `SUPABASE_PROJECT_REF` is scoped to the environment
- staging is synced with this commit
- the reviewer approves the run

Command versions stay backwards compatible (AD-17 expand/contract). Old command versions are retained until supported clients migrate, so a backend promoted first never breaks clients already deployed. Rollback is forward repair: add a new migration. There is no destructive down-migration.

Edge functions and scheduled jobs do not exist yet. When they arrive, add their deploy step between steps 4 and 6.

Mobile builds follow the same rule (`--dart-define`, one build per commit and environment). Store release signing is owned by the release epic.

## Owner steps (exact)

Do these in GitHub at **github.com/raeltec-systems/church-app**.

### A. GitHub environments (needed before the first promotion)

1. Go to **Settings → Environments → New environment**, name it `staging`, and choose **Configure environment**.
   - Under **Deployment branches and tags**, choose **Selected branches and tags** and add `main`.
   - Under **Environment secrets → Add environment secret**, add:
     - `SUPABASE_ACCESS_TOKEN`: a personal access token from supabase.com → **Account → Access Tokens → Generate new token** (name it `github-ci-staging`).
     - `SUPABASE_DB_PASSWORD`: the `bic-kafue-platform-test` database password. If it is not known, reset it in Dashboard → **Project Settings → Database → Reset database password**.
   - Under **Environment variables → Add environment variable**, add:
     - `SUPABASE_PUBLISHABLE_KEY`: the `sb_publishable_…` key from Dashboard → **Project Settings → API Keys**. Never use the legacy anon JWT or a secret key; the workflow refuses them.
2. Create a second environment named `production` and configure it the same way, plus protection:
   - Under **Deployment protection rules**, tick **Required reviewers** and add `raeltec-systems` (the repository owner account; required reviewers are free because the repository is public). Leave **Prevent self-review** unticked while you are the only maintainer. Save the protection rules.
   - Under **Deployment branches and tags**, choose **Selected branches and tags** and add `main`.
   - Add the secrets `SUPABASE_ACCESS_TOKEN` and `SUPABASE_DB_PASSWORD` for the **production** project only, after step C.
   - Add the variables `SUPABASE_PROJECT_REF` (the new production ref) and `SUPABASE_PUBLISHABLE_KEY` (the production `sb_publishable_…` key).
   - Put `SUPABASE_PROJECT_REF` **only** on this environment, never under repository variables. The `preflight` job refuses a production run while a repository-level value exists, and also while the environment has no Required reviewers rule.
3. Optional, to turn on the drift check in every CI run: go to **Settings → Secrets and variables → Actions → Repository secrets** and add `SUPABASE_ACCESS_TOKEN`. A token for the staging account is enough; it is read-only use. After step C, also add the repository variable `PRODUCTION_PROJECT_REF`, so `env:check` proves no non-production config names it.

4. Recommended, because the repository is public: go to **Settings → Advanced Security** (named **Code security** on some accounts) and enable **Secret Protection** and **Push protection**. They are free for public repositories, and GitHub's scanner then backs up `ci:secrets`. Secrets are never passed to workflows from fork pull requests, so the drift check skips there.

### B. Staff web hosting (when you want a URL)

Create a free Cloudflare account, then follow these steps:

1. Go to **Workers & Pages → Create → Pages → Upload assets**.
2. Create a project named, for example, `bic-kafue-staff`. Upload any placeholder; the workflow deploys the real files.
3. Go to **My Profile → API Tokens → Create Token → Custom token**:
   - Permission: **Account → Cloudflare Pages → Edit**.
   - Copy the token.
4. In each GitHub environment, add:
   - secret `CLOUDFLARE_API_TOKEN`
   - secret `CLOUDFLARE_ACCOUNT_ID` (the dashboard's right sidebar shows it)
   - variable `CLOUDFLARE_PAGES_PROJECT` (`bic-kafue-staff`)

The workflow deploys staging builds to the `staging` branch preview and production builds to `main`.

Netlify works the same way. Replace the last workflow step with:

```sh
npx netlify-cli deploy --dir "$dir" --prod --site "$NETLIFY_SITE_ID"
```

and add `NETLIFY_AUTH_TOKEN` / `NETLIFY_SITE_ID`.

### C. Production baseline (owner gate, blocked today)

1. Create the production Supabase project:
   - Either upgrade the org, or pause `bic-kafue-auth-test` to free a free-plan slot.
   - Choose region and name (Q10). Suggested name: `bic-kafue-production`. Record the ref.
2. In that project's Dashboard, go to **Project Settings → Data API**:
   - Set *Exposed schemas* to `api` only (remove `public` and `graphql_public`).
   - Set *Extra search path* to `api`.
3. In **Authentication → Sign In / Providers**:
   - Keep **Phone** provider off.
   - Configure no SMS provider, no Send SMS hook, no test OTPs and no phone MFA.
4. Fill in the `production` GitHub environment (step A2).
5. Run **promote** with target `staging` and check that it is green. Then run **promote** with target `production` and approve the deployment when GitHub asks. The first run marks the database `production`, which is terminal. It verifies that `private_access` and `outbound_sending` are closed.
6. System access, operators and alerting in production follow `system-access-and-operations.md` (story 1.9): the system route stays closed there until the owner approves `ops_system_access`, and alerting stays off until Q12 thresholds and the restricted alert destination are approved.
7. Do not approve the `private_access` or `outbound_sending` gates (`app.policy_approve`) until their release epics say so. Opening either gate is out of scope for milestone 1. While a gate is open, every promotion to that environment fails, because `tools/ci/verify-hosted.sql` requires both gates closed. Changing `features.*` does not help either: `env:check` rejects `true`. A later release epic must change `verify-hosted.sql` and the validator (`tools/env/environments.mjs`) together to allow an approved gate.

## Evidence

The evidence for this story is in `_bmad-output/initiative-church-app/epic-platform-baseline/evidence-1.8/README.md`.
