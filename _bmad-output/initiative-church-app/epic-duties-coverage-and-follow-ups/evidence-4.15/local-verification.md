# Story 4.15: local verification (2026-10-15)

Worktree of story 4.15 on `ccr-93e730dd-89lbvg` (baseline `4ca9fe2`), local stack only, SYNTHETIC
data and fictional numbers. No hosted project, staging, GitHub or production was touched; no SMS
provider is configured. The container restarted twice during the run; every result below comes
from a complete run after the code it covers was committed (the closing suite was rerun after the
second restart; nothing in `apps/`, `packages/` or `supabase/` changed in this story).

## The closing suite (`tools/identity-e2e/duties-staging-suite.mjs`)

| Run | Result |
|---|---|
| Local target (fresh reset) | scenarios **22/22**, matrix cells **253/253** (12 reads x 11 principals + 11 probes x 11 principals), 44/44 checks; every user, member, department, cell, task, job and receipt removed; worker credential revoked (`duties-staging-suite-local.jsonl`, `-summary.md`) |
| `--staging-path` (sign-up, application, approval; no SQL check; cleanup SQL executed) | scenarios **22/22**, matrix **253/253**, 44/44; `S99-staging-cleanup-sql-removes-the-run` rows left 0 (`duties-staging-suite-staging-path.jsonl`, `-summary.md`) |
| Two consecutive staging-path runs on one database (`--rerun-state`, first with `--keep`): people, departments A and B, the accountless member and the relinked lifecycle member reused | run 1 44/44, run 2 44/44 (before the first restart, on the same suite code) |
| Offline tests `duties-staging-suite.test.mjs` | 9/9 (guards, numbers, calendar, both expectation tables, cleanup SQL, summary, refusals before any call) |

Expected answers came from the SQL. Three suite assumptions were corrected by reading the code,
not by copying results: a member reads their own outcome's correction reason (story 4.10) and
the instructions of a duty they hold (so neither is a leak); `duties.clear_review` by another
department's leader answers `forbidden` (owner decision 2026-10-15 item 4); a follow-up's
assignment notice is retired when the owner acts before delivery (so the suite waits for
delivery first). **No product defect was found; no migration.**

## After the independent review (2026-10-15)

The review found nothing blocking. Fixes: S01 or S02 failing now stops the run before any duty is
written; a reused department must be SYNTHETIC and the reused accountless record must be the
suite's; the cleanup SQL refuses any database not marked `staging` (the `--staging-path` proof
uses the same guard for `local`), touches only SYNTHETIC `SYNTHETIC Closing Suite...` departments
and also removes schedules keyed on occurrences, cases, flags and departments; state, temporary
and cleanup files are chmod 0600 after each write; S96 asserts `404 PGRST202` (function not in
the `api` schema) and `406 PGRST106` (the `app` schema is not exposed); per-run departments leave
the state once a cleanup removed them. Docs: the owner runs the staging suite (it needs the
Admin's password); runs never overlap; audit and lifecycle history stays on purpose; the
`ops_system_access` value is written out; the q12 tolerance is recorded only; the APK build log's
proxy line was removed. Reruns after the fixes, one at a time, no pgTAP running: offline tests
`tools/identity-e2e/*.test.mjs` 166 pass (suite 9/9); closing suite local **22/22, 253/253**;
`--staging-path` **22/22, 253/253**, cleanup SQL rows left 0. The evidence files in this folder
are from these reruns.

## Database and E2E (a reset before each E2E, one at a time; pgTAP never concurrent)

- `npx supabase db reset` exit 0; `npm run db:test` **Files=45, Tests=3845, PASS**; `npm run db:smoke` exit 0.
- E2E (scratchpad `e2e-main.sh` list plus the closing suite): run 0, grants 0, apply 27/27,
  review 18/18, cells 13/13, recovery 20/20, credentials 15/15, assisted 16/16, lifecycle 9/9,
  deletion 12/12, runbooks 16/16, inbox 13/13, source-contracts 10/10, worker 17/17, routing
  18/18, push 12/12, inbox-screens 12/12, duties 13/13, duties-revisions 13/13, duties-rota 17/17,
  duties-overlaps 13/13, duties-responses 12/12, followups 15/15, followups-reminders 12/12,
  duties-reminders 17/17, duties-coverage 12/12, duties-outcomes 11/11, duties-owner-ops 13/13, duties-lifecycle 16/16, duties-pilot 13/13, duties-decisions 11/11 (these six after the second restart, each after a reset), duties-staging-suite 44/44 (and `--staging-path` 44/44).

## Node, contracts and policy

- `npm run contracts:test` 265 pass; Dart contracts (`packages/contracts/dart`, `dart test`) 282 pass.
- `node --test tools/auth-harness/*.test.mjs tools/identity-e2e/*.test.mjs supabase/functions/*/*.test.mjs tools/identity-deletion/*.test.mjs tools/notifications/*.test.mjs` 261 pass.
- `npm run ci:policy-test` 56 pass; `ci:secrets` clean (1635 files); `ci:migrations -- --base origin/main` 50 migrations, non-destructive; `ci:function-imports` clean; `env:check` valid.
- Evidence scan (the new CI step): clean for `evidence-4.15`, the suite and the runbooks.

## Flutter (3.47.6)

| Package | analyze --fatal-infos | test | test, TZ=America/New_York |
|---|---|---|---|
| packages/client_core | no issues | 655 pass | 655 pass |
| apps/staff | no issues | 40 pass | 40 pass |
| apps/mobile | no issues | 55 pass | 55 pass |

## Builds

`builds.md`: staff web sealed as staging (refused as production), APK arm64 release sha256
`722b65526dd3c40916179a2caaddd8011052b187e8b64d7ef0657cab2c2e3f81`, both bundle scans clean.
