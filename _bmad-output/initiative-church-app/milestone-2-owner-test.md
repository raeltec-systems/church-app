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
- **3.2 Opening a reminder:** tap an inbox item while it is current: it shows "Still current".
  Then change the test reminder (revise, expire or revoke, per `docs/runbooks/notifications.md`
  "Story 3.2", Hosted staging step 2) and open the same item again: it shows the generic "out of
  date" state with nothing about why. Inbox titles and texts never contain names, numbers or links.

## Reminders

## Decisions for the owner at the end of milestone 2

- **Q2 scheduling values (3.3)** before production: confirm or adjust the TEST FIXTURE in
  `docs/runbooks/notifications.md` (story 3.3): Africa/Lusaka; default deadline 14 days before when
  assigned 30+ days ahead, 48 h before when 72 h+ ahead, 24 h before when more than 24 h ahead,
  otherwise respond now; default reminders 24 h before the deadline and at the deadline; snooze
  1 h / 24 h / 2 days; merge reminders within 30 minutes; no quiet hours. Then approve
  `q2_church_time` and run the re-plan, as the runbook says.
