# Story 4.13 local verification (2026-10-15)

Worktree branch `worktree-agent-a24419b7dfb89c13b` on the integration branch `ccr-93e730dd-89lbvg` (stories 4.1-4.12 merged). No migration, server or client change in this story.

| Check | Result |
|---|---|
| `npx supabase db reset` | 0 |
| `npm run -s db:test` | PASS, 43 files, 3733 tests |
| `npm run -s db:smoke` | pass (exit 0, matrix 15 cases) |
| Every E2E, one at a time, a reset before each (`e2e-suite-summary.txt`) | 30 scripts, every `exit=0`; `duties-pilot` 13/13 |
| `duties-pilot.mjs --staging-path` (the staging branch against the local stack, real 5-minute wait, staging cleanup SQL executed) | 14/14 (`duties-pilot-staging-path-local.jsonl`) |
| `npm run -s contracts:test` | 265 pass, 0 fail |
| `dart test` in `packages/contracts/dart` | 282 pass |
| Node tool tests (the CI set) | 239 pass, 0 fail (`duties-pilot.test.mjs` 10) |
| `npm run -s ci:policy-test` | 56 pass, 0 fail |
| `npm run -s ci:secrets` | clean |
| `npm run -s ci:migrations -- --base origin/main` | 48 ordered, unique, non-destructive |
| `npm run -s ci:function-imports` | ok |
| `scan-evidence.sh` on `evidence-4.13/`, the script and the runbooks (the new CI step) | clean |
| Runbook link anchors (`duties-guides.md`, `duties.md`, `follow-ups.md`, `identity-access.md`, `contracts-and-owner-seams.md`) | 0 broken |
| Flutter | not run: no client code changed |

Not run here: the rehearsal against staging (parent session) and the owner walkthrough (`owner-walkthrough.md`, HITL).
