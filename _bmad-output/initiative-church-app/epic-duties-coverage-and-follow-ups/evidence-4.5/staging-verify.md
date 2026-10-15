# Story 4.5 - staging verification (tmurpotfluignacfueki, 2026-10-14)

Synthetic data only. Merged `d161644` after the independent review fixes (no blockers; S1 Not
sent after a reload, S2 accept_many lock order, S3 Accept note restored, nits N1-N10). Full local
verification on the merged branch: db:test 2640, every E2E including `duties-responses` 12/12,
Flutter client_core 516 / staff 35 / mobile 50. PR #6 CI green on `d161644`.

| Version | Name | How applied |
|---|---|---|
| 20261014081513 | duties_member_responses | Supabase MCP `apply_migration` in one call (42 KB). Local file renamed from 20261014093012. |

| Check | Result |
|---|---|
| The 93 `app`/`api` `duties_*` functions (purge stub excluded) | aggregate of per-function `md5(pg_get_functiondef)` identical to local (`8b891da0...`, 93 rows) |
| `\u` escapes | none (no backslashes in the migration) |
| Client grants | unchanged: `anon` none; `authenticated` the existing duties entry points only (no execute on `duties_withdraw_acceptance`, `duties_accept_many`, `duties_refuse_ended`, `duties_assignment_occurrence`) |
| After the apply | 0 assignments with `prior_accepted_at` |
| Staging assertions of `tools/ci/verify-hosted.sql` (marker staging, private_access closed, alerting disabled, no recovery hold) | passed |
| Edge Functions | no change in 4.5 |

No owner SQL paste is needed for 4.5 (no new row deletions).

Pending:
- Rebuild the staging APK (new native plugin `share_plus` 13.3.0) before the owner's phone checks.
- Owner: the story 4.5 manual checks in `docs/runbooks/duties.md`.
- Owner acknowledgement of the two review amendments recorded under Decisions in the plan
  (accept_many lock order; calendar UID), which supersede wording in the frozen block.
