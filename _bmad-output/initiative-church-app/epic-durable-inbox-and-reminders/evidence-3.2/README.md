# Evidence: story 3.2 (source contracts, generic payloads, authorised deep links), LOCAL stack

Recorded 2026-10-08 on the local Supabase stack (synthetic data only). Hosted staging evidence is the owner's demonstration in `docs/runbooks/notifications.md` (Story 3.2, Hosted staging) and is not yet recorded.

| File | What it shows |
|---|---|
| `source-contracts-e2e.jsonl` | `tools/identity-e2e/source-contracts.mjs`, 10/10 checks. Real GoTrue phone sign-in, PostgREST and the real worker script. An unregistered kind and a payload with private fields are refused and write nothing. Five SYNTHETIC reminders are delivered with the registered generic text. After revise, cancel, revoke and expire, the current item opens with its authorised target and the other four open as the generic superseded state with no target and no source id; the revised source's new item opens as current. Another member gets `not_found`, a signed-out caller 401. Cleanup is complete. |
| `live-inbox-check.txt` | `tools/identity-e2e/live-inbox-check.sh` with the real client adapters: as in 3.1, plus L9 (staff web opens the item: current, with its target) and L10 (member B opening it learns nothing). L1 (empty inbox at start) also passed; its line shares the terminal line of the build-hook progress and was not captured by the filter. |

Also run (all passing):

- `npm run db:test`: 20 files, 1629 assertions, including `notifications_source_contracts_test.sql` (80, with the review fixes) and the updated `notifications_inbox_test.sql`.
- `npm run db:smoke` (including `contract_fixtures_check.sh` with the new fixture cases).
- Every `tools/identity-e2e` E2E (run, grants, apply, review, cells, recovery, credentials, assisted, lifecycle, deletion, runbooks, inbox, source-contracts), each after a reset.
- `contracts:test` (TypeScript, 242), `dart test` and `dart test -p chrome` in `packages/contracts/dart`, `ci:policy-test` and the offline tool tests.
- `flutter analyze` and `flutter test` for `client_core` (379), `mobile` and `staff`, and the staff web build.
- `ci:secrets` and `check-migrations`.
