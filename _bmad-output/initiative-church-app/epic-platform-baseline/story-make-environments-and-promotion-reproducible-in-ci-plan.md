---
title: 'Make environments and promotion reproducible in CI'
type: 'feature'
ticket: '8'
created: '2026-10-03'
status: 'blocked'
blocked_reason: 'Owner gate (ticket unknown + owner-decisions Environments): the production-baseline deployment needs the owner to create the production Supabase project (upgrade org or pause bic-kafue-auth-test), create GitHub environments staging/production with secrets/variables and a required reviewer, and (optionally) a static-host account. Everything up to that deployment is built and verified; steps in docs/runbooks/environments-and-promotion.md "Owner steps" A-C.'
baseline_revision: '85eb9fd5a4aeea15a5888aead7fb5fea6067bbf9'
route: 'full'
route_source: 'auto'
review: 'quick'
review_source: 'pinned'
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/owner-decisions-milestone-1.md'
  - '{project-root}/docs/runbooks/tracer.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Local, hosted staging and a future production differ only by hand-typed URLs; nothing in CI enforces non-destructive, version-ordered migrations, detects hosted migration drift, keeps secrets out of the repo and client bundles, or gives an owner-approved promotion path (P7, AD-17, AD-18).

**Approach:** Add checked, secret-free environment config files, CI policy checks (migration order/non-destructive, drift, secret and bundle scanning, environment separation and synthetic recipients), and a manual promotion workflow that applies backend migrations before building checksummed client artifacts, with production behind a GitHub environment approval and owner-created project/hosting.

## Boundaries & Constraints

**Always:** clients get only project URL + publishable key; secrets live only in GitHub environment secrets; nonproduction may address only synthetic recipients; production config keeps `private_access` and `outbound_sending` disabled; backend promotion precedes client deploy; CI passes from a clean checkout without any owner secret (hosted checks skip with a notice).

**Never:** edit existing migrations, `supabase/config.toml` auth settings, or files of other lanes (`apps/`, `packages/`, `trials/`, `tools/auth-harness/`); configure SMS; create the production project or hosting account; push hosted Auth config.

- Decision (agent, under owner pre-approval): `bic-kafue-platform-test` is staging; marked via `app.platform_set_environment('staging','israel')` after advisors showed only INFO deny-all RLS notes.
- Decision (agent, under owner pre-approval): Flutter bakes `--dart-define` values into the bundle, so "immutable" means one build per (commit, environment), checksummed once in CI and only verified — never rebuilt — at deploy; production deploy uses the artifact built by the same run.
- Decision (agent, under owner pre-approval): DROP/TRUNCATE in a new migration fails CI unless the file carries `-- owner-approved-cleanup: <reason>`; modifying, renaming or deleting an already-merged migration fails.
- Decision (agent, under owner pre-approval): synthetic-recipient enforcement is a shared tool (`tools/env`) plus the closed `outbound_sending` gate; the future sending worker (durable-inbox epic) must call an equivalent server-side guard — no new migration here.
- Decision (agent, under owner pre-approval): hosting deploy is generic (Cloudflare Pages via `wrangler`, used only when the owner's secrets exist); otherwise the verified artifact is the deliverable.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| New additive migration | version > all base versions | policy check passes | — |
| Destructive migration | new file with `drop table` (not in comment/string) | fails naming file/line | passes only with owner-approved-cleanup marker |
| Out-of-order / edited | new version ≤ base max, or merged file changed | fails | — |
| Drift | hosted has version/name absent locally | drift check fails | local-only newer versions reported as pending |
| No token | `SUPABASE_ACCESS_TOKEN` unset | drift job skips with notice | exit 0 |
| Secret in repo/bundle | `sb_secret_…`, service_role JWT, `sbp_…`, private key; any JWT or `service_role` in a web bundle | scan fails | — |
| Recipient in nonproduction | address not matching synthetic patterns | refused | production refused while sending disabled |
| Wrong target | staging job given production ref, or production unset | refused before any deploy | — |

</frozen-after-approval>

## Code Map

- `.github/workflows/ci.yml` -- existing db/auth-harness/flutter jobs; keep green, add `policy` job and bundle scan, add `workflow_call`.
- `supabase/migrations/*.sql` -- 5 migrations, versions 20261003112319..20261003134340; hosted staging list identical (MCP list_migrations).
- `supabase/migrations/20261003134340_cross_epic_contracts.sql:1105-1160` -- `app.platform_environment`, `platform_set_environment`; `policy_gates` `private_access`/`outbound_sending` closed.
- `packages/client_core/lib/composition.dart` -- `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` dart-defines (reuse, do not edit).
- `tools/auth-harness/scan-evidence.sh` -- pattern style to mirror (do not edit).
- `docs/runbooks/tracer.md` -- hosted project notes; Data API exposed-schema owner step.

## Tasks & Acceptance

**Execution:**
- [x] `config/environments/{local,staging,production}.json` -- non-secret config (ref, URL, features, recipients, secret names, approval) -- separation source of truth.
- [x] `tools/env/environments.mjs` + `check-environments.mjs` + `environments.test.mjs` -- validate configs, recipient guard, target resolution -- separation proof.
- [x] `tools/ci/check-migrations.mjs` + test -- naming/order/immutability/destructive policy vs base ref.
- [x] `tools/ci/check-migration-drift.mjs` + test -- compare local vs hosted list (API with token or JSON file).
- [x] `tools/ci/scan-secrets.mjs` + test -- repo and bundle modes.
- [x] `tools/ci/package-web.mjs` -- checksummed manifest + verify mode.
- [x] `tools/ci/verify-hosted.sql` -- marker/gate assertions run after migrations.
- [x] `.github/workflows/ci.yml`, `.github/workflows/promote.yml` -- policy job; manual promotion staging → production (environment-protected).
- [x] `package.json` -- `env:check`, `ci:*` scripts.
- [x] `docs/runbooks/environments-and-promotion.md` -- procedures and exact owner steps.
- [x] `evidence-1.8/` -- marker raw result, drift run, local check outputs.

**Acceptance Criteria:**
- Given a clean checkout without secrets, when CI runs, then all jobs pass and hosted checks skip with notices.
- Given staging, when the drift check runs on the saved hosted list, then it reports in sync.
- Given the promotion workflow targeting production, when no approval or project ref exists, then nothing deploys.

## Implementation Notes

- Implemented directly (no subagent tool available in this run).
- Files: `config/environments/*.json`; `tools/env/environments.mjs` (+test); `tools/ci/{secret-patterns,scan-secrets,check-migrations,check-migration-drift,package-web,hosted-sql}.mjs`, `verify-hosted.sql`, `ci-tools.test.mjs`; `.github/workflows/ci.yml` (new `policy` job, bundle scan step, `workflow_call`, non-cancelling concurrency for callers); `.github/workflows/promote.yml`; `package.json` scripts; `docs/runbooks/environments-and-promotion.md`; one-line staging note in `docs/runbooks/tracer.md`; `evidence-1.8/`.
- Staging marker set on `tmurpotfluignacfueki` after advisors (INFO only); raw results in evidence-1.8.
- Surprise: supabase-dart embeds the literal `"sb_secret_"` prefix in `main.dart.js`, so the bundle scan flags only full secret keys (prefix + body), any JWT and `service_role`; verified by a negative build with a synthetic secret-format key.
- Surprise: the migration policy, replayed against `d437b2b~1`, rejects the earlier rename that aligned 1.5's version with hosted — intended; such alignment must happen before merge.
- Hosted SQL in the promotion goes through the Management API (`/database/query`) because free-plan direct DB hosts are IPv6-only; `supabase db push` uses the CLI's own link.
- The production promotion auto-marks an unmarked database `production` (terminal) under the environment approval; it verifies `private_access`/`outbound_sending` closed and fails otherwise.
- Repo is public and user-owned (`raeltec-systems`): required reviewers are free; runbook also recommends enabling GitHub Secret Protection + push protection.

## Plan Change Log

## Review Triage Log

| Finding | Verdict | Route | Evidence |
|---|---|---|---|
| stripSql ignores dollar quotes / E-strings, hiding DROP | high | patch | reviewer repro: findDestructive returned [] for `$$Don't$$` then `drop table` |
| promote.yml never enforces production approval | high | patch | GitHub auto-creates unprotected environments; repo-level var fallback for project ref |
| promotion path runs check-migrations without --base; staging from any branch | medium | patch | workflow_call event_name is workflow_dispatch, so base rules skipped |
| runbook C6 implies features.* flip reopens promotion | medium | patch (docs) | verify-hosted.sql ignores features.*; validator forbids true. Mechanism itself deferred to release epic |
| runbook says one job; workflow has three | low | patch | promote.yml job graph |
| drop identity/expression allowance undocumented | low | patch | strict code, docs mismatch |

## Verification

**Commands:**
- `node --test tools/env/*.test.mjs tools/ci/*.test.mjs` -- all pass
- `npm run env:check && npm run ci:migrations && npm run ci:secrets` -- pass
- `npm run db:test && npm run db:smoke` -- unchanged green
- staff web build + `node tools/ci/scan-secrets.mjs --bundle apps/staff/build/web` -- clean
- `actionlint` on workflows -- no errors
</content>
</invoke>
