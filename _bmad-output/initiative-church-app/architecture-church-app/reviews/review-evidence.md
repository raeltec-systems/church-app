# Technology evidence reviewer gate

Date: 2026-10-03

Verdict: **PASS after correction — no unresolved technology-evidence blocker.** All reviewed technology decisions have an appropriate documented or repository-reality basis and accurately state their verification limits. The saved AD-5 correction was reread and resolves E1 below.

## Resolved finding

### E1 — Cached Realtime channel authorization cannot enforce current chat-content access

Original severity: blocking before architecture finalization. Status: resolved in the saved AD-5.

AD-4 requires scope revocation to hold despite stale tokens/tabs. The reviewed AD-5 nevertheless permits “explicitly permitted chat data” on Realtime without selecting a mechanism that checks current permission per event. Supabase's official Realtime Authorization documentation states: “Client access policies are cached for the duration of the connection. Your database is not queried for every Channel message.” Policies refresh on subscription or a new JWT, so private Broadcast-channel membership alone cannot prove current permission after church membership or roles change.

The saved correction makes all Realtime payloads, including chat, receive-only per-account generic refresh hints. It expressly excludes private bodies, record IDs, paths, state and identifying source types; filters currently eligible recipients at the publisher; acknowledges cached channel authorization; and requires a current authorized read on refresh, deep link, resume and reconnect. This resolves the provider conflict. Client refresh/reconnect is no longer the sole protection against content disclosure.

Sources freshly read for this review:

- <https://supabase.com/docs/guides/realtime/authorization> — Broadcast/Presence policy caching and refresh points.
- <https://supabase.com/docs/guides/realtime/postgres-changes> — each change is checked for subscriber access; DELETE events have separate limitations, so this is not a blanket substitute without deliberate design.

Raw copies: `/workspace/work/bmad-architecture/review-realtime-source.md` and `review-pg-source.md`.

## Verified technology and reality coverage

| Decisions | Evidence and conclusion |
| --- | --- |
| AD-1 modular backend/owners | The repository has no application implementation or conflicting deployed topology. Source requirements require shared identity, duties, follow-ups, notifications and records; a single transaction-capable managed Postgres backend supports the proposed monolith. Ownership/dependency choices are correctly marked engineering assumptions rather than vendor guarantees. |
| AD-2 transactional commands/read surface | Official Supabase docs support custom exposed schemas, explicit object grants, RLS, invoker functions, justified private definer functions, and PostgreSQL 15+ invoker views. PostgreSQL 17 documentation confirms row locks and consistent lock ordering; logged records can commit atomically with domain changes. Idempotency, receipts, lock ordering and authority predicates remain implementation work, not claimed platform magic. |
| AD-3–AD-5 identity/privacy | Supabase Auth session documentation establishes session-ID checks and stale JWT limits. Current account binding, roles and domain privacy are explicit application requirements. Reserved-schema restrictions and function privilege defaults were checked. E1 is resolved by content-free refresh signaling and fresh authorized reads. |
| AD-6–AD-7 assignments/follow-ups | Reality-checked against adopted source requirements; proposed constraints, revisions and multi-owner effects fit transactional Postgres. No external service capability is presumed. |
| AD-8 notifications | Supabase documents Cron/pg_net invocation, but pg_net queues are unlogged; the spine correctly uses logged application jobs/inbox as authority. PostgreSQL locking supports bounded queue claims. Leases, fencing, retry/dedupe and final current-state checks require tests; the spine neither claims exactly-once push nor equates provider acceptance with delivery. |
| AD-9 time, AD-10 visits, AD-11 money, AD-12 observations | Source-derived state distinctions, approved time-zone policy, exact decimal amounts and historical facts are represented as application/database contracts. No provider behavior is invented to supply consent, attendance or financial independence. |
| AD-13 caching/files | Current Storage docs establish authenticated private retrieval and signed-URL limitations; the spine requires an authenticated access-checking route and no-store private responses. It does not claim logout can revoke a previously issued bearer URL or erase downloaded information. |
| AD-14 lifecycle/deletion | Storage API deletion, JWT revocation limits and resumable external effects were researched. The access-denied tombstone plus current predicates prevents a partial cleanup from being treated as authorized access; resumability and restoration reconciliation still need tests. |
| AD-15 public giving/chat isolation | Domain boundaries are adopted product requirements, not undocumented provider behavior. No payment provider integration or automatic content-rights clearance is introduced. |
| AD-16 clients/starter | Official Flutter create/CLI/new-app guides and Supabase's Flutter quickstart all support the selected official starter. Riverpod/go_router/Supabase/Firebase package roles match their published manifests/docs. Web semantics/DataTable limits justify the retained web trial. No third-party starter or untested production web framework is selected. |
| AD-17 environments/operations | Separate managed projects and configured credentials are feasible topology assumptions. Current Edge auth documentation supports verified server-only credentials; a publishable key is expressly insufficient. Database backups exclude object bytes, correctly requiring separate file backup/restore. Region, plans, production costs, runtime inventory and recovery targets remain provisioning/owner gates. |
| AD-18 release gates | The existing repository contains no app/SDK build evidence. The spine explicitly gates implementation, concurrency/permission, native/browser, provider and restoration testing; it correctly excludes the current AOSP emulator as FCM proof. |

## Version and compatibility check

Independently reread the raw official Flutter stable manifest and all five pub.dev package manifests retained in `flutter-sources/`. They match the stack exactly: Flutter 3.47.6, Dart 3.13.5, flutter_riverpod 3.4.3, go_router 18.0.2, supabase_flutter 2.18.0, firebase_core 4.15.0 and firebase_messaging 16.7.0. Their declared SDK constraints admit the selected SDK, including Messaging's declared Firebase Core range.

The current Supabase PostgreSQL release announcement supports PostgreSQL 17.11 as a new-project target from 2026-09-28. Actual project build, extension inventory, hosted Edge runtime and local deployment-tool pins remain provisioning checks. The spine correctly avoids invented managed-service patch pins and notes that managed extension SQL version pinning is ignored.

This is declared compatibility and documented fit only. Dependency solving, platform deployment floors, compilation, credentials, end-to-end delivery and application/provider behavior have not been tested. Both technology evidence files and the spine say so. A reference to an optional package in research does not silently select it as an application dependency.

## Additional official sources checked during this gate

- <https://www.postgresql.org/docs/17/explicit-locking.html> — row-level locks, consistent lock ordering and deadlock risks.
- <https://www.postgresql.org/docs/17/sql-select.html> — `SKIP LOCKED` is suitable for queue-like consumers, not a general consistent read guarantee.
- <https://www.postgresql.org/docs/17/sql-createview.html> — `security_invoker` checks underlying relation privileges as the caller; foundation migrations must include intended SELECT grants as well as RLS.
- <https://supabase.com/docs/guides/api/using-custom-schemas> — explicit API schema exposure and USAGE/object grants; the guide's broad example grants are not a least-privilege prescription.

Foundation implementation must verify the api/app grant matrix, invoker-view reads, restricted definer execution, provider worker credentials and denied paths. These are already covered by AD-2/AD-4/AD-18 and do not require a second architecture blocker.
