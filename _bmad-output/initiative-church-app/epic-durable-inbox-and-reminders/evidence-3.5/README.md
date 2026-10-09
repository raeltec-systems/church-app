# Evidence: story 3.5 (recipient routing, device tokens, push settings, lifecycle and deletion hooks), LOCAL stack

Recorded 2026-10-08 on the local Supabase stack (synthetic data only). Nothing was applied or deployed on a hosted project. Hosted staging evidence is the owner's demonstration in `docs/runbooks/notifications.md` (Story 3.5, Hosted staging) and is not yet recorded.

| File | What it shows |
|---|---|
| `routing-e2e.jsonl` | `tools/identity-e2e/routing.mjs`, 18/18 checks, through real GoTrue phone sign-in, PostgREST, the real Identity commands and the worker script. Members register devices; no answer or read carries a token (R10, R11); push settings by category with revisions (R12). A hold and a deactivation retire the members' tokens in Identity's transaction (R20); a held member cannot register (R21). An accountless member has a relative's number as contact route (R22). The Admin enqueues reminders for an active, a held, a deactivated and the accountless member through the API (R30); one worker run delivers one item and routes three needs to the source's direct-contact route (R31-R33); only the active account gets member-push work (R34); the relative gets no job, item, push job or need, and no need carries a number (R35). A lost-device hold (sessions revoked) retires the token and cancels the pending push job, keeping the item (R40). A member's own deletion request retires tokens, cancels push and pending jobs (R50), an enqueue for them afterwards is skipped without failing the source command (R51), and the deletion hooks erase everything so the check answers zero for every owner (R52). Worker output is content-free (R60); cleanup is complete (R99). |

Also run (all passing):

- `npm run db:test`: 23 files, 1940 assertions, including `notifications_routing_test.sql` (105).
- `npm run db:smoke`.
- Every `tools/identity-e2e` E2E (run, grants, apply, review, cells, recovery, credentials, assisted, lifecycle, deletion, runbooks, inbox, source-contracts, worker, routing), each after a reset.
- `contracts:test`, the offline tool tests (`node --test tools/**/*.test.mjs supabase/functions/*/logic.test.mjs`).
- `ci:secrets` and `check-migrations` (also against the base revision).
- No Flutter package changed in this story.
