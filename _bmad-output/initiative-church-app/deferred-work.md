
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
