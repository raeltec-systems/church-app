# Evidence: story 3.4 (leased and fenced worker, Cron and the Edge Function), LOCAL stack

Recorded 2026-10-08 on the local Supabase stack (synthetic data only). Nothing was applied, deployed or scheduled on a hosted project. Hosted staging evidence is the owner's app-closed demonstration in `docs/runbooks/notifications.md` (Story 3.4, Hosted staging) and is not yet recorded.

| File | What it shows |
|---|---|
| `worker-e2e.jsonl` | `tools/identity-e2e/worker.mjs`, 15/15 checks. Real GoTrue phone sign-in, PostgREST, the system route, the Edge Function `notifications-worker` served locally, Supabase Vault, pg_net and pg_cron. Two concurrent claims lease disjoint jobs and give one item per job (W10). A worker killed mid-lease is reclaimed with a higher fencing token; its late attempt and a stale token are fenced (W20, W21). A job cancelled after the claim, a source revised after enqueue, a revoked recipient grant and expired jobs (at the claim and at the attempt) each end in one recorded state with one attempt row (W30-W34). A transient owner-check failure backs off and is retried to delivery, with the SQLSTATE only recorded (W40). The Edge Function refuses a missing, malformed, other-purpose or unknown credential and runs a batch with the worker's (W02, W50). A pg_cron job (every 5 s) delivers a due reminder with no client involved; its command holds no credential; the scheduler is then removed (W60, W61). Responses, the function log and the status are content-free (W70). Cleanup is complete (W99). |

Also run (all passing):

- `npm run db:test`: 22 files, 1808 assertions, including `notifications_worker_test.sql` (83).
- `npm run db:smoke`.
- Every `tools/identity-e2e` E2E, each after a reset (run, grants, apply, review, cells, recovery, credentials, assisted, lifecycle, deletion, runbooks, inbox, source-contracts, worker), and `live-inbox-check.sh` (real client adapters).
- `contracts:test`, `ci:policy-test`, `env:check`, the offline tool tests including `supabase/functions/notifications-worker/logic.test.mjs`.
- `ci:secrets` and `check-migrations` (also against the base revision).
- No Flutter package changed in this story.
