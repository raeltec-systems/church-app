# Milestone 2 — owner's consolidated staging test (collected while building epics 3, 4 and 5)

Run once at the end of milestone 2, on staging (`tmurpotfluignacfueki`) with the milestone 2 builds.
Synthetic data only. Owner Q2 decisions: `owner-decisions-milestone-2.md`.

## Owner steps to do first

1. ~~Reminder worker credential (3.1, 3.4).~~ Done 2026-10-08 (registered, expires 2026-11-07).
2. ~~Two Edge Function secrets (3.4).~~ Done 2026-10-08; the every-minute schedule is on and verified.
3. ~~Paste in the staging SQL Editor (3.5).~~ Done 2026-10-08 (`20261008135900_notifications_routing_rows.sql`, verified).

4. **Phone push through Firebase (3.6, optional for the first pass).** Push is off until you do this;
   the inbox carries every reminder meanwhile. Follow `docs/runbooks/notifications.md`, story 3.6,
   "Hosted staging", steps 3 to 5: create a Firebase project (for example `bic-kafue-staging`) with
   the Android app `zm.bickafue.bic_kafue_mobile` and the iOS app `zm.bickafue.bicKafueMobile`;
   create the service account `bic-push-sender` with only the **Firebase Cloud Messaging API Admin**
   role and put its JSON key in the staging Edge secret `NOTIFICATIONS_FCM_SERVICE_ACCOUNT` (never in
   a chat); upload an APNs `.p8` key if you will test an iPhone. Then send the assistant only the
   NON-secret app identifiers (project id, sender id, Android and iOS app ids, the API key from
   `google-services.json`) so it can build the push-enabled app, and say "push ready".

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

- **3.5 Routing:** a reminder for a held member, a deactivated member and a member with no login
  never reaches them; it appears instead on the source's "Needs direct contact" list (test source:
  ask the assistant to show it). A member's push on/off per category (once 3.7 adds the screen) never
  removes in-app items. Deleting a member (after the rows paste) leaves none of their reminders,
  devices or settings.

- **3.6 Push (after owner step 4 and the push build):** signed in as a synthetic member on a real
  Android phone with Google Play services (and an iPhone if you set up APNs), allow notifications
  and close the app. A test reminder due now shows one phone notification with only the generic
  title and text (no names, numbers or links); tapping it opens the item in **Inbox**. Uninstall the
  app, trigger another reminder: the assistant shows the device token retired and the reminder still
  in the inbox. Turning push off for the category (3.7 screen) stops phone notifications but not
  inbox items.

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
