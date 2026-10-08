
- source_plan: `_bmad-output/initiative-church-app/epic-platform-baseline/story-make-environments-and-promotion-reproducible-in-ci-plan.md`
  summary: verify-hosted.sql fails promotion whenever a release gate is open and the env validator forbids features.* true, so a release epic that opens a gate must change both together.
  evidence: 1.8 quick review; milestone 1 keeps both gates closed by design.

- source_plan: `_bmad-output/initiative-church-app/epic-platform-baseline/story-provide-bounded-system-access-and-restricted-operations-plan.md`
  summary: Unauthenticated calls to system_command each insert a sys_audit row with no rate limit or retention.
  evidence: 1.9 quick review; app.sys_execute steps 1–2 audit every rejected credential; rate/retention wait for Q12 thresholds.

- source_plan: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-sign-in-with-a-phone-username-and-reach-a-live-access-checke-plan.md`
  summary: Persist member sessions across app restarts with platform-secured token storage (mobile keystore/keychain adapter for supabase_flutter; an explicit staff-web storage policy), keeping protected domain state in memory.
  evidence: 2.1 keeps `persistSession: false` from 1.7 (fail-closed: extra sign-ins, never extra access); I2 "sessions persist" needs a secure-storage dependency and native setup that 2.1 did not add.

- source_plan: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-sign-in-with-a-phone-username-and-reach-a-live-access-checke-plan.md`
  summary: Staff number-reclaim path for a phone username squatted through phone `/otp` create_user (F1); 2.1 reproduced the unlinked user row locally (evidence-2.1 E18).
  evidence: owner decision 2026-10-06 (F1 accepted as constraint); 2.1 only guarantees such accounts get no member access.

- source_plan: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-enforce-live-session-trust-across-alternate-auth-routes-plan.md`
  summary: Run the 2.2 session-persistence path (flutter_secure_storage Keystore/Keychain restore after app restart) on a real Android/iOS device or emulator, and repeat the 2.2 alternate-route checks on hosted staging after the owner promotes 20261006220500_identity_session_trust.
  evidence: 2.2 closed the 2.1 persistence deferral with platform-secured storage, verified by widget tests, the plugin mock and the live SDK restore path only; no device toolchain here and staging promotion is owner-gated.

- source_plan: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-change-credentials-under-review-and-hold-access-plan.md`
  summary: A stolen live session can still change the PASSWORD through GoTrue `PUT /user` (`secure_password_change` is off and its reauthentication nonce would need SMS for phone users); the thief can then sign in until the member reports it.
  evidence: story 2.8 resolves the email-change lockout (double confirmation keeps the approved address, restore + lost-device hold revoke every session) and, after its review, keeps a restored account on a security hold until the member's own reset when the password changed unreviewed; members without an approved recovery email then wait for staff-assisted recovery (entry 9), which must record reset evidence that identity_member_reset_since accepts. A server-side password-change gate needs an owner decision on GoTrue settings.

- source_plan: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-recover-access-with-staff-assistance-and-a-single-use-grant-plan.md`
  summary: Run the story 2.9 adversarial matrix (tools/identity-e2e/assisted.mjs cases) against staging Auth once the parent applies 20261007140729 and the owner registers the staging system credential, sets the IDENTITY_RECOVERY_SYSTEM_CREDENTIAL Edge Function secret and the function is deployed.
  evidence: 2.9 ran every case locally (12/12, live adapter check R1-R4); staging needs a secret only the owner may handle.

- source_plan: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-recover-access-with-staff-assistance-and-a-single-use-grant-plan.md`
  summary: Cloudflare/WAF optional - an edge rule in front of the assisted-recovery function (and a retention job for app.identity_recovery_client_attempts rows). The per-client limit itself is done (owner decision 2026-10-07: per-IP limit in the function (10/IP/10 min), church cap 120/10 min, per-number 5/h).
  evidence: the function keys the limit on the first x-forwarded-for hop; if staging shows the gateway appends to a client-sent header, a WAF rule closes that gap.

- source_plan: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-hold-deactivate-and-restore-membership-with-handover-obligat-plan.md`
  summary: Real owners (Duties, Follow-ups, Offerings custody, Chat, Directory, device registrations) must register their handover hooks (`app.identity_register_handover_hook`) and `membership_deactivated` / `sessions_revoked` lifecycle hooks before their modules activate; Cells may want one for the last leader of a cell.
  evidence: story 2.10 delivers the Identity side and proves ordering and atomicity only with the SYNTHETIC fixture hooks; a deactivated member's confirmed cell membership is kept (facts), and no Cells hook exists yet.

- source_plan: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-hold-deactivate-and-restore-membership-with-handover-obligat-plan.md`
  summary: Run the story 2.10 matrix (tools/identity-e2e/lifecycle.mjs cases) and the staff web/mobile demonstration on staging once the parent applies 20261007151523 (applied 2026-10-07).
  evidence: every case ran locally (8/8, pgTAP 76); no owner-only step is needed for staging.

- source_plan: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-delete-a-member-fully-through-a-resumable-workflow-plan.md`
  summary: Run the story 2.11 deletion matrix (tools/identity-e2e/deletion.mjs cases) on staging after the parent applies 20261007174952, the owner hand-applies 20261007175000_member_deletion_rows.sql (and confirms the migration owner may delete auth.audit_log_entries rows), the identity-deletion function is deployed and the owner registers the worker's identity_deletion credential; mirror the journal segments to the restricted Drive folder.
  evidence: every case ran locally (E2E 11/11, pgTAP 91); staging needs a hand-applied row-deletion file and a credential only the owner may handle.

- source_plan: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-delete-a-member-fully-through-a-resumable-workflow-plan.md`
  summary: Applicants without a member record (pending, rejected or withdrawn applications) have no deletion route yet; their application and account are not erased by 2.11.
  evidence: the ticket covers members (in-app and staff routes need a member record); the erase step does remove applications of a deleted member's account.

- source_plan: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-delete-a-member-fully-through-a-resumable-workflow-plan.md`
  summary: Real owners (device registrations, Duties, Chat, Directory, Prayer, Storage objects) must register deletion hooks (app.identity_register_deletion_hook) before they activate, and Q4 must approve identity_deletion_retention (what is erased or anonymised, and journal/backup retention) before production erasure runs; production also needs a scheduled worker and its credential.
  evidence: 2.11 erases Identity and Cells data and proves owner hooks only with the SYNTHETIC fixture hook; production requests deny access but erasure waits on the closed gate by design.

- source_plan: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-refactor-sweep-plan.md`
  summary: Minimise personal data in stored command receipts: recovery-email (2.7) command results keep the email, phone or name in `result`, and 2.5 outcomes follow the same pattern, and replays return that stored answer; store only what a replay needs (ids, states, codes).
  evidence: 2.7 review triage routed it to the 2.13 refactor sweep; 2.13 kept it out because shrinking stored results changes replay answers and the receipts already written (behaviour, not cleanup). Needs its own entry, ideally with Q4 retention.

- source_plan: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-verify-identity-end-to-end-and-promote-it-to-production-plan.md`
  summary: Build the Supabase send-email hook (owner decision 2026-10-07 #2) that sends Auth emails through the church's own sender so `/recover` answers and timing are identical for registered and unknown addresses; deploy and test it on staging before `q1_auth_recovery` is approved in production.
  evidence: 2.14 found it not built; production email recovery stays fail-closed (gate G1/G2 in docs/runbooks/production-promotion-identity.md) until the owner creates the sender account and the hook exists.

- source_plan: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-verify-identity-end-to-end-and-promote-it-to-production-plan.md`
  summary: Add a reviewed restricted-operator procedure for the first real production Admin (approve exactly one application while no usable Admin exists, owner identity check, two-person record, then bootstrap), and an operator function or migration path to approve the `dormancy_days` Identity setting.
  evidence: 2.14 promotion package, gates G3 and G8: production has no path to either today, so it stays fail-closed; the owner chooses the first-Admin option.

- source_plan: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-verify-identity-end-to-end-and-promote-it-to-production-plan.md`
  summary: Add an Edge Function deploy step (identity-assisted-recovery, identity-deletion) to `.github/workflows/promote.yml` between the database and client steps.
  evidence: the 1.8 workflow predates Edge Functions ("add their deploy step between steps 4 and 6"); 2.14's production package deploys them by hand.

- source_plan: `_bmad-output/initiative-church-app/epic-durable-inbox-and-reminders/story-send-generic-expiring-push-through-fcm-and-retire-invalid-to-plan.md`
  summary: Add the real `firebase_messaging` adapter for `PushMessaging` in `apps/mobile` (pinned `firebase_core`/`firebase_messaging`, `FirebaseOptions` from `--dart-define`s, Android `POST_NOTIFICATIONS`, iOS Push Notifications capability, `aps-environment` and remote-notification background mode, override `pushMessagingProvider` in `main.dart`), then run the owner's real-device check.
  evidence: 3.6 built the port, registration, tap handling and the server/Edge sender with a default-off no-op adapter; real wiring needs the owner's Firebase app identifiers and an APNs key (runbook notifications.md, Story 3.6, steps 3-8), which no agent holds.
  status: adapter done 2026-10-08 (pinned firebase_core 4.15.0 / firebase_messaging 16.7.0, `apps/mobile/lib/push/`, build-time `FIREBASE_*` defines, Android `POST_NOTIFICATIONS` and default channel, iOS remote-notification background mode; see the plan's "Client follow-up (done)"). Remaining (owner): build with the real defines, add the iOS Push Notifications capability in Xcode, and run the real-device check (runbook steps 6-8).

- source_plan: `_bmad-output/initiative-church-app/epic-durable-inbox-and-reminders/story-send-generic-expiring-push-through-fcm-and-retire-invalid-to-plan.md`
  summary: Retire a device's push registration when its Auth session ends without an in-app sign-out (plain expiry or sign-out elsewhere), not only on the 3.5 lifecycle events.
  evidence: 3.6 retires the registration before an in-app sign-out only; pushes stay generic and every open re-checks the session, so this is a privacy refinement, not a leak of content.
