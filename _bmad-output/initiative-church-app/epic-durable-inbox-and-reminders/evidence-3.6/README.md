# Evidence: story 3.6 (generic expiring push through FCM, invalid-token retirement), LOCAL stack

Recorded 2026-10-08 on the local Supabase stack (synthetic data only). Nothing was applied or deployed on a hosted project. No Firebase project, service account or APNs key was used: the FCM HTTP v1 provider is a FAKE endpoint started by the E2E. It has an OAuth token endpoint that verifies the run's RS256 assertion, and a send endpoint that answers per device token as scripted. Real-device evidence (Android with Google Play services, and iOS) is the owner's step 8 in `docs/runbooks/notifications.md`, Story 3.6, and is not yet recorded. The installed AOSP emulator is not push evidence.

| File | What it shows |
|---|---|
| `push-e2e.jsonl` | `tools/identity-e2e/push.mjs`, 12/12 checks, through real GoTrue phone sign-in, PostgREST, the system route and `supabase functions serve` with the fake FCM. See the list below. |

The checks in `push-e2e.jsonl`:

- **P01:** members register devices; no answer carries a token.
- **P10:** with push off the inbox items are delivered and nothing is sent.
- **P11:** a member without a registered device (push denied) and a member who turned the category off get the inbox item and no push job.
- **P20, P21:** with push on, one message per live device. Each message is generic: the contract's fixed title and body, `data` = the item id only, and the item id as the Android collapse key and tag and as the APNs collapse id, with an expiry.
- **P22:** an `UNREGISTERED` answer retires that token (`provider_invalid`) and keeps the other.
- **P23:** the OAuth assertion is verified by the fake.
- **P30:** a 503 is retried after the backoff with the same notification id, then accepted.
- **P40:** an expired push job is never sent.
- **P50:** the pushed item id opens the item only with the member's session (401 signed out, `not_found` for another member).
- **P60:** no push attempt or inbox item claims delivery or reading.
- **P70:** function responses, function log, status and system receipts hold no token, key, access token, text or id.
- **P99:** cleanup is complete and push is off again.

Also run (all passing):

- `npm run db:test`: 24 files, 2036 assertions, including `notifications_push_test.sql` (96). It covers leases, prepare rechecks, provider answers, retirement, retry, exhaustion, lapses and fencing (a fenced record still retires invalid tokens), the expire-only claim, the kernel's `retain_result` (no token in `app.sys_receipts`, replay = conflict), status and deletion.
- `npm run db:smoke`.
- Every `tools/identity-e2e` E2E (run, grants, apply, review, cells, recovery, credentials, assisted, lifecycle, deletion, runbooks, inbox, source-contracts, worker, routing, push), each after a reset.
- `contracts:test`; the offline tool and function tests (`node --test tools/*/*.test.mjs supabase/functions/*/*.test.mjs`, including `fcm.test.mjs` and `push-run.test.mjs`).
- `flutter analyze` and `flutter test` in `packages/client_core` (`test/notifications/push_test.dart`), `apps/mobile` (story 3.6 widget test) and `apps/staff`.
- `ci:secrets` and `check-migrations`.
