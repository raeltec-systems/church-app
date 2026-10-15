# Owner decisions for the milestone 2 build run (Q2)

Recorded 2026-10-08 from Israel Muyoba's answers. They resolve spec decision **Q2** for milestone 2 (durable inbox and reminders, duties and follow-ups, cell meetings and programmes) and replace the Q2 proposals in `spec-church-app/delivery-and-decisions.md` where they differ. The milestone 1 constraints still hold: synthetic data only off production, no SMS, production gated.

| Area | Decision | Notes for the build |
|------|----------|---------------------|
| **Time zone** | `Africa/Lusaka` (IANA). | The church's single zone for schedules, deadlines and reminder times. Stored instants stay UTC; local dates/times are computed in this zone. |
| **Pilot cells** | **Shikoswe Cell** and **Estates C5/C7 Cell** (C5/C7 is one cell, not two). | Real names are production configuration only. Staging and tests use synthetic stand-ins (`SYNTHETIC Shikoswe Cell`, `SYNTHETIC Estates C5/C7 Cell`). |
| **Pilot department** | Not chosen yet. | Use a synthetic stand-in (`SYNTHETIC Preaching Rota`); the owner names the real one before the pilot. |
| **Response deadlines** | Set per duty/rota by the person creating it, with defaults that depend on lead time. Long-standing assignments (e.g. the preaching rota, created and assigned at the start of each quarter) get a deadline **2 weeks to 1 month before** the duty. Short-notice assignments (e.g. assigned during the week for the coming Sunday) get **48 to 24 hours before**. | Agent interpretation (adjustable, owner may refine): the creator may set any deadline before the duty start. Default when not set: if the duty starts 30 days or more after assignment, 14 days before start; if it starts 2 to 30 days after assignment, 48 hours before start; if it starts within 48 hours, 24 hours before start, or immediately due if that has passed. Never later than the duty start. |
| **Reminders** | **Configurable by the person setting the task** (which reminders, how long before). The **assigned member can snooze** a reminder: remind me in 2 days, 24 hours, 1 hour, and similar. | The creator's reminder offsets are stored per duty/task. Snooze is a per-recipient, per-reminder deferral; it never changes the duty, its deadline or anyone else's reminders, and a snoozed reminder still stops once the member responds or the duty is cancelled. Default offsets when the creator sets none: at the deadline and 24 hours before it (Q2 proposal). |
| **Quiet hours** | **None.** This is a community app and is not meant to spam people. | Reminders are sent when due, at any hour. The no-spam intent is met by sending only what the creator configured and the member's own snoozes, deduplicating, and stopping reminders once the member has answered. |

Still open under Q2: leaders and deputies for the pilot cells and department (named at the pilot; staging uses synthetic members).

## Production setup (2026-10-13)

- Production Supabase project created by the parent session on the owner's instruction:
  `bic-kafue-production`, ref `vwufdgggbkpwwbkuxrqk`, region eu-central-1, organisation
  "Raeltec Systems Limited" (free plan). Empty: no migrations, no environment marker yet (the
  first promotion sets `production`). Its ref is held only in the GitHub `production` environment
  variable `SUPABASE_PROJECT_REF`, never in `config/environments/production.json` (env:check rule).
- Owner states (2026-10-13) that `q2_church_time` (the Q2 values above), `ops_system_access` and
  `q12_operations` are approved. They are recorded in the production database with
  `app.policy_approve(..., 'israel', ...)` after the first promotion creates the schema; the Q12
  value still needs the reminder-lateness tolerance figure.
- Firebase: the owner may reuse the staging Firebase project `kbicc-church-app` for production;
  production gets its own service-account key in its own Edge secret, so either can be revoked
  alone. (Decision pending the owner's confirmation.)
- 2026-10-14: Firebase confirmed. Production reuses Firebase project `kbicc-church-app` with its own
  `bic-push-sender` JSON key, saved by the owner as the production Edge secret
  `NOTIFICATIONS_FCM_SERVICE_ACCOUNT` (separate from the staging key, so either can be revoked alone).
- 2026-10-14: Q12 reminder-lateness tolerance = **10 minutes** (owner accepted the recommendation:
  a due reminder not delivered within 10 minutes counts as a fault). Recorded as part of the
  `q12_operations` approval value at the first production promotion.

## Duties and Follow-ups decisions (2026-10-15)

The owner answered the open epic 4 decisions after seeing an independent opinion and the agent's
recommendation on each. The owner's choice is recorded; where it differs from what was built, the
change is scheduled as a follow-up build.

| # | Decision | Owner's choice | Status |
|---|---|---|---|
| 1 | Q4: contact details a department leader or deputy may see (coverage queue) | **Labelled contact routes only** (the numbers the member registered, with their label), for their own department's members only | Approved. Recorded as the `q4_personal_data` contact scope at the next production promotion. |
| 2 | Q4: `identity_deletion_retention` | **Anonymise**: keep duty and task history as "a former member"; erase notes and free text | Approved. Recorded at the next production promotion. |
| 3 | Story 4.5: calendar entry identity (occurrence and slot, `SEQUENCE` = slot revision) | **Accept** | Acknowledged (supersedes the frozen-block wording). |
| 4 | Story 4.11: `duties.clear_review` answers `forbidden` to a non-manager | **Accept** | Acknowledged (supersedes the frozen-block wording). |
| 5 | Story 4.12: one vacancy notice per department per change | **Accept** | Acknowledged (supersedes the frozen-block wording). |
| 6 | Cells: may a cell programme see who holds a linked department duty | **No**: filled or not only | As built. |
| 7 | Mismatch on a linked meeting or event | **Flag and notify**: one notice to the department's leaders and deputies per department per change | Change to build (the follow-up story). |
| 8 | Should leaders learn why a position became vacant | **Yes, show the reason** (owner chose against both recommendations) | Change to build: a coarse reason category shown to the department's leaders and deputies only. |
| 9 | A reachable deputy counts as the department's responsible person | **Yes** | As built. |
| 10 | Last leader's scope revoked first bypasses the handover rule | **Fix before the live pilot** | Change to build: an Identity grant-revocation handover hook. |
| 11 | Staging pilot rehearsal (4.13) sign-in | **The owner runs the command** with their synthetic Admin password | Owner action. |
| 12 | Reminder defaults (bands 14 days / 48 h / 24 h; reminders 24 h before and at the deadline, plus 24 h before the start) | **Accept** | As built (policy settings, tunable after the pilot). |
| 13 | Minimum answer window before Short notice | **Accept 1 hour** | As built. |
| 14 | Pilot department | **Music Department** | Named. Its leaders (a Music Director, a Vice-Music Director, a Secretary and a Treasurer) were named by the owner in the session; their names are production configuration only and are not stored in this repository. Staging keeps `SYNTHETIC Preaching Rota`. |
