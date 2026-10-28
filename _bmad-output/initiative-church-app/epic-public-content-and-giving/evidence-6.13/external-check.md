# Story 6.13 external check (independent reviewer, 2026-10-22)

The coordinator's external check for this entry: an independent reviewer checks the change against
the entry's verify and K14, especially that no announcement content reaches a push preview. A
separate reviewer agent, with no part in the build, reviewed the diff and probed the local stack
(fresh reset, under the shared-database lock) before the migration went to staging.

**Verdict: PASS with findings.**

- No content leaks: a marked title and body were searched for in jobs, attempts, inbox items,
  push jobs, direct-contact needs, command receipts and the Content audit (0 matches); the two
  Realtime messages were `inbox_changed` with payload `{}`; no content or notifications table is in
  a publication; the `notifications.push_prepare` message is the contract's generic text and the
  inbox item id only.
- Recipients: after a publication with a notice the reviewer deactivated a member, ended a link,
  added a deletion tombstone, set a binding review and banned an Auth user; all five jobs ended
  `ineligible|recipient_ineligible` with no inbox item, push job or direct-contact need. Pending
  accounts got no job; only members with a device and the category on got a push job.
- No shared lifecycle or Notifications function is replaced; permission matrix, privilege
  ledgers, the Q2 refusal, replay, one notice per revision and the erase part match the plan.
- Runs: full pgTAP 59 files / 4623 tests, two rolled-back probes (1000 reachable members; state
  changes between publish and delivery), check-migrations, the offline E2E tests and the Flutter
  suites, all passing.

Findings and what was done with each are in the plan's Review Triage Log (runbooks, fixtures
commit, a large notice holding back other reminders, lock order, wording, earlier notices, Home
refresh, the hard-coded preview text, the phone-range note); none was a content leak.
