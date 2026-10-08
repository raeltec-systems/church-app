# Milestone 2 — owner's consolidated staging test (collected while building epics 3, 4 and 5)

Run once at the end of milestone 2, on staging (`tmurpotfluignacfueki`) with the milestone 2 builds.
Synthetic data only. Owner Q2 decisions: `owner-decisions-milestone-2.md`.

## Owner steps to do first

1. **Reminder worker credential (3.1).** In your local clone run
   `OPS_STATE_DIR=.ops-state/notifications-worker node tools/ops/system-credential.mjs mint --env staging`
   and send the assistant only the fingerprint it prints; the assistant registers it
   (principal `notifications-worker`, purpose `notifications_worker`, 30 days).

## Scenarios

- **3.1 Inbox:** as a synthetic member on mobile and staff web, create a test reminder due in a
  minute or two, run the worker once
  (`SUPABASE_URL=https://tmurpotfluignacfueki.supabase.co SUPABASE_PUBLISHABLE_KEY=sb_publishable_B7rxJq4-D4PBNohOgz3qmg_SfbQWRSY NOTIFICATIONS_WORKER_CREDENTIAL_FILE=.ops-state/notifications-worker/staging.credential node tools/notifications/worker.mjs run-once`;
  exact flags in `docs/runbooks/notifications.md`, "Hosted staging"), and see exactly one item in
  **Inbox** on both clients. A cancelled reminder never appears.

## Reminders

## Decisions for the owner at the end of milestone 2
