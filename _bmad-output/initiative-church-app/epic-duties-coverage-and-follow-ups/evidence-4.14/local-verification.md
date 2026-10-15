# Story 4.14 local verification (2026-10-15)

The worktree branch builds on the integration branch `ccr-93e730dd-89lbvg`, with stories 4.1-4.13 merged (baseline `e398b5fc8dcbbb1d3c515538cb534ee2d094c886`). The baselines come from `evidence-4.13/local-verification.md` and from runs on the baseline before any change.

| Check | Baseline | After 4.14 |
|---|---|---|
| `npx supabase db reset` | 0 | 0 (49 migrations) |
| `npm run -s db:test` | PASS, 43 files, 3733 tests | PASS, 44 files, 3737 tests (+4: `duties_comments_test.sql`) |
| `npm run -s db:smoke` | exit 0 | exit 0 (139 ok lines, no failure) |
| Function bodies, ACLs and comments (805 app/api/public functions) | - | bodies and ACLs identical; only the 4 refreshed comments differ (`function-md5-diff.txt`) |
| Every E2E, one at a time, with a reset before each (`e2e-suite-summary.txt`) | 30 scripts, every `exit=0` | identical: 30 scripts, every `exit=0`, same N/N counts; duties and follow-ups JSONL in `e2e/` |
| `npm run -s contracts:test` | 265 | 265 pass, 0 fail (fixtures unchanged) |
| `dart test` in `packages/contracts/dart` | 282 | 282 pass |
| Node tool tests (the CI set) | 239 | 244 pass, 0 fail (+5: `duties-shared.test.mjs`) |
| `npm run -s ci:policy-test` | 56 | 56 pass |
| `npm run -s ci:secrets` | clean | clean |
| `npm run -s ci:migrations -- --base origin/main` | 48 | 49 ordered, unique, non-destructive |
| `npm run -s ci:function-imports` | ok | ok |
| client_core `flutter analyze` / `flutter test` | clean / 637 | clean / 644 (+6 sweep tests, +1 Follow-ups in-flight reload test) |
| client_core, `TZ=America/New_York` on `test/duties` and `test/followups` | pass | 176 and 37 pass |
| staff `flutter analyze` / `flutter test` | - | clean / 40 |
| mobile `flutter analyze` / `flutter test` | - | clean / 55 |
| `scan-evidence.sh` on `evidence-4.14/`, `duties-shared.mjs`, the migration and the runbooks (the new CI step) | - | clean |

Mutation checks:
- Removing the C5 line makes the new Follow-ups test fail.
- With the old comments, `duties_comments_test.sql` fails tests 2 and 4.

Not run here: the staging apply of `20261015130404_duties_comment_refresh.sql` (parent session).
