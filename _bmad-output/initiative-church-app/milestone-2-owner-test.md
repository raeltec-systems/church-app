# Milestone 2 — owner's consolidated staging test (collected while building epics 3, 4 and 5)

Run once at the end of milestone 2, on staging (`tmurpotfluignacfueki`) with the milestone 2 builds.
Synthetic data only. Owner Q2 decisions: `owner-decisions-milestone-2.md`.

## Owner steps to do first

1. **Reminder worker credential (3.1, 3.4).** In your local clone run
   `OPS_STATE_DIR=.ops-state/notifications-worker node tools/ops/system-credential.mjs mint --env staging`
   (add `--force` if a staging credential already exists there) and send the assistant only the
   fingerprint it prints; the assistant registers it (principal `notifications-worker`, 30 days).
2. **Two Edge Function secrets (3.4).** Supabase dashboard, staging project, **Edge Functions >
   Secrets**: add `NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL` = the contents of
   `.ops-state/notifications-worker/staging.credential`, and `NOTIFICATIONS_WORKER_TRIGGER` = the
   value of the Vault secret `notifications_worker_trigger` (**Project Settings > Vault > Secrets**,
   reveal and copy; the assistant already created it). Do not paste either value into a chat.
   Then tell the assistant "secrets set": it runs one test tick and switches on the every-minute
   schedule.

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

- **3.4 Reminders with the apps closed:** as a synthetic member create a test reminder due now,
  close both apps; within about a minute the item is in **Inbox** on both clients with nobody
  running anything. A test reminder whose check is made to fail for 3 minutes still arrives once the
  fault ends (the assistant sets the fault). A cancelled one never arrives. Details:
  `docs/runbooks/notifications.md`, story 3.4, Hosted staging step 7.

## Reminders

- Rotate the staging notifications-worker credential at least every 30 days (mint with `--force`,
  send the fingerprint, replace the Edge secret `NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL`).

## Decisions for the owner at the end of milestone 2

- **Q2 scheduling values (3.3)** before production: confirm or adjust the TEST FIXTURE in
  `docs/runbooks/notifications.md` (story 3.3): Africa/Lusaka; default deadline 14 days before when
  assigned 30+ days ahead, 48 h before when 72 h+ ahead, 24 h before when more than 24 h ahead,
  otherwise respond now; default reminders 24 h before the deadline and at the deadline; snooze
  1 h / 24 h / 2 days; merge reminders within 30 minutes; no quiet hours. Then approve
  `q2_church_time` and run the re-plan, as the runbook says.
