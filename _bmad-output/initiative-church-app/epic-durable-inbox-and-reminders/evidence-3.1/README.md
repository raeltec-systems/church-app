# Evidence: story 3.1 (synthetic due reminder to the durable inbox), LOCAL stack

Recorded 2026-10-08 on the local Supabase stack (synthetic data only). Hosted staging evidence is the owner's demonstration in `docs/runbooks/notifications.md` (Hosted staging) and is not yet recorded.

| File | What it shows |
|---|---|
| `inbox-e2e.jsonl` | `tools/identity-e2e/inbox.mjs`, 12/12 checks. Real GoTrue phone sign-in, PostgREST and the real worker script. The source command writes the source and job together, and the same request id adds nothing. One worker run gives one item; a second run adds nothing. Two racing workers give one item per job. Cancelled and future reminders never become items. Another member, an unlinked account and a signed-out caller see nothing. The worker output is content-free, and cleanup is complete. |
| `live-inbox-check.txt` | `tools/identity-e2e/live-inbox-check.sh`: the real client adapters (`SupabaseCommandGateway`, `SupabaseInboxRepository`). The mobile and staff web clients of one member read the same single item; another member and a signed-out client see nothing. |

Also run (all passing):

- `npm run db:test`: 19 files, including `notifications_inbox_test.sql` (52 assertions).
- `npm run db:smoke`.
- Every `tools/identity-e2e` E2E, each after a reset.
- `contracts:test`, `ci:policy-test` and the offline tool tests.
- `flutter analyze` and `flutter test` for `client_core`, `mobile` and `staff`, plus the staff web build and its bundle secret scan.
- `ci:secrets` and `check-migrations`.
