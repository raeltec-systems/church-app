# Evidence: story 3.4 (leased and fenced worker, Cron and the Edge Function), LOCAL stack

Recorded 2026-10-08 on the local Supabase stack (synthetic data only), after the independent review fixes. Nothing was applied, deployed or scheduled on a hosted project. Hosted staging evidence is the owner's app-closed demonstration in `docs/runbooks/notifications.md` (Story 3.4, Hosted staging) and is not yet recorded.

| File | What it shows |
|---|---|
| `worker-e2e.jsonl` | `tools/identity-e2e/worker.mjs`, 17/17 checks. Real GoTrue phone sign-in, PostgREST, the system route, the Edge Function `notifications-worker` served locally with its two secrets (worker credential, trigger), Supabase Vault, pg_net and pg_cron. The function starts nothing without the right trigger, including when given a credential instead (W02). Two concurrent claims lease disjoint jobs and give one item per job (W10). A worker killed mid-lease: the lapse is counted, the job is reclaimed with a higher fencing token, the late attempt and a stale token are fenced (W20, W21). A job cancelled after the claim, a source revised after enqueue, a revoked recipient grant and expired jobs (at the claim and at the attempt) each end in one recorded state (W30-W34). A transient owner-check failure backs off and is retried to delivery (W40). The function runs a batch (W50). A pg_cron job (every 15 s) delivers a due reminder with no client involved (W60) and is removed (W61). No system credential is in the pg_net queue, Vault or Cron (W62). A revoked worker credential is refused (W63). Responses, the function log and the status are content-free (W70). Cleanup is complete (W99). |

Also run (all passing):

- `npm run db:test`: 22 files, 1835 assertions, including `notifications_worker_test.sql` (110: fencing, lapse counting and exhaustion, statement-timeout cancel caught, deliver_due batch cap and release, re-plan and re-snooze after the claim, URL pinning, operator journal, trigger rotation, queue without credentials).
- `npm run db:smoke`.
- Every `tools/identity-e2e` E2E, each after a reset, and `live-inbox-check.sh` (real client adapters).
- `contracts:test`, `ci:policy-test`, `env:check`, the offline tool tests including `supabase/functions/notifications-worker/logic.test.mjs`.
- `ci:secrets` and `check-migrations` (also against the base revision).
- No Flutter package changed in this story.
