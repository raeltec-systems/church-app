---
title: 'Delete unreferenced private uploads after 30 days'
type: 'feature'
ticket: ''
created: '2026-10-22'
status: 'built'
baseline_revision: 'e1eba4dd4e9d3cf8a32098ba6643b2b971f0d02d'
route: 'full'
route_source: 'pinned'
review: 'quick'
review_source: 'pinned'
lenses_ran: ['quick']
review_loop_iteration: 1
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/initiative-church-app/epic-public-content-and-giving/epic-public-content-and-giving.md'
  - '{project-root}/docs/runbooks/content.md'
  - '{project-root}/docs/runbooks/notifications.md'
  - '{project-root}/docs/runbooks/system-access-and-operations.md'
  - '{project-root}/docs/runbooks/production-promotion-content.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Story 6.2 leaves replaced and abandoned uploads in the private `content-drafts` bucket indefinitely. The owner decided those uploads should be deleted after 30 days.

**Approach:** Run bounded cleanup through the existing notification scheduler and a new purpose-separated system principal. Claim only uploads older than 30 days with no revision-file reference, delete bytes through the Storage API, then remove their metadata; failed deletes remain claimed and retry after a lease expires.

## Boundaries & Constraints

**Always:** Use the existing `pg_cron` → `notifications-worker` path; keep Content cleanup under its own system purpose and credential; never delete objects from SQL; retain objects referenced by any revision, including drafts; recheck under a row lock and prevent new attachments while cleanup is claimed; use only staging project `tmurpotfluignacfueki` for hosted work; never publish staging notifications.

**Never:** Add another scheduler, expose cleanup to a member or editor route, place a service-role key in `notifications-worker`, remove a published or draft revision's object, or approve a policy gate.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Expired orphan | Pending or ready private asset is at least 30 days old and no revision file references it | Existing scheduled worker claims it, Storage removes the object, and Content removes its row | Counts only; retries after the cleanup lease expires |
| Recent or referenced | Asset is younger than 30 days or any revision file references it | Asset and object remain unchanged | No error |
| Storage failure | Claimed object cannot be removed | Keep its row and claim so a later scheduled run retries | Do not finalize or report it deleted |
| Unauthenticated cleanup | Missing or wrong scheduler trigger or system credential | No claim or Storage operation occurs | Coarse 401/403/503 response; content-free logs |

</intent-contract>

## Code Map

- `supabase/migrations/20261022012809_content_rights_banners.sql` -- `content_assets`, `content_revision_files`, upload completion, file attachment validation and preview define which assets may be claimed; keep the public-file plan unchanged.
- `supabase/migrations/20261003154040_bounded_system_access.sql`, `20261007140729_assisted_recovery.sql` and `20261008121248_notifications_worker.sql` -- system command registry, purpose allowlists and notification worker command examples. Register a separate `content_asset_retention` purpose.
- `supabase/functions/content-assets/index.ts` and `logic.mjs` -- existing service-key Storage API path and request parser; add only a trigger-protected internal cleanup action.
- `supabase/functions/notifications-worker/index.ts` -- current scheduler entry point has the low-value trigger but no service-role key; dispatch cleanup to `content-assets` without changing its notification behavior.
- `tools/identity-e2e/worker.mjs`, `tools/identity-e2e/content-banners.mjs` and `tools/identity-e2e/harness.mjs` -- local system credential, scheduler, HTTP and Storage setup patterns.
- `docs/runbooks/content.md`, `docs/runbooks/notifications.md` and `docs/runbooks/production-promotion-content.md` -- document the 30-day rule, credential and existing scheduler handoff.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261022112247_content_asset_retention.sql` -- register two bounded system commands and claim/finalize handlers; add a 30-minute retry claim, exclude any revision reference, guard attachment races, and delete metadata only after Storage succeeds.
- [x] `supabase/functions/content-assets/logic.mjs` and `index.ts` -- parse and authenticate the internal cleanup request, claim via the new system credential, remove only claimed `content-drafts` objects through Storage, and finalize successful ids.
- [x] `supabase/functions/notifications-worker/index.ts` -- dispatch the internal cleanup action using the existing scheduler trigger; log counts only and keep notification processing unchanged.
- [x] `supabase/functions/content-assets/logic.test.mjs`, `supabase/functions/notifications-worker/logic.test.mjs`, and new `supabase/tests/content_retention_test.sql` -- cover request/auth validation, retention boundary, references, retries, bounded claims and allowlists.
- [x] New `tools/identity-e2e/content-retention.mjs` and `.test.mjs` -- exercise the real local worker-to-Storage path with synthetic orphan, recent and referenced assets; clean up all local rows and objects.
- [x] `docs/runbooks/content.md`, `docs/runbooks/notifications.md`, and `docs/runbooks/production-promotion-content.md` -- describe scheduler integration, the separate system credential, the staging principal/credential/Edge secret setup, and owner manual checks.
- [x] Apply the migration verbatim to confirmed staging, deploy both changed Edge Functions, and verify command hashes, module guards, signed-out reads and zero unintended staging notifications. The scheduler integration is deployed fail-closed pending the owner’s staging principal and Edge-secret setup.

**Acceptance Criteria:**
- Given an asset at least 30 days old with no revision-file reference, when the existing scheduler runs, then the Storage object and metadata row are removed.
- Given an asset under 30 days old or referenced by any revision, when cleanup runs, then the object and metadata remain.
- Given a Storage failure or interrupted run, when cleanup is retried after its claim expires, then deletion completes idempotently without exposing the object or duplicating work.
- Given an upload is being attached while cleanup claims it, when either transaction wins the asset lock, then the other operation cannot leave a broken revision reference.
- Given a caller without the scheduled trigger and the Content retention system credential, when it requests cleanup, then no object is claimed or removed.

## Implementation Notes

The owner decision is in the epic Notes dated 2026-10-22. “Unreferenced” is enforced against every revision-file row, not only the live published revision: a draft or historical reference is still a use that should remain intact. The existing notification scheduler is the only scheduler; its worker calls the trigger-protected Content Edge action, which alone holds the purpose-scoped Content credential and Storage key.

Staging assigned migration version `20261022112247`, so the local filename and promotion references were renamed from `20261022105023` to match. The schema and functions are deployed on staging; the owner still needs to create the separate staging principal, register its two-command scope and digest, and add the two `content-assets` Edge secrets before scheduled cleanup can run. Until then the Content action fails closed.

## Plan Change Log

## Review Triage Log

- Quick independent pass: one P2 documentation finding was fixed. Trigger-rotation instructions now update `NOTIFICATIONS_WORKER_TRIGGER` in both `notifications-worker` and `content-assets`; the promotion SQL indentation was corrected. No findings remain.

## Design Notes

Claiming is a two-phase operation because Postgres cannot delete the actual Storage bytes. The database first locks and marks a bounded set as cleanup-claimed; attachment and preview checks reject claimed assets. The Edge function removes bytes using the Storage API, and only then asks the system route to delete metadata. A 30-minute claim timeout lets the existing scheduled worker recover from a crash or Storage outage.

## Verification

**Commands:**
- `npx supabase db reset --local` -- expected: all migrations apply on a fresh local database.
- `npx supabase test db` -- expected: full pgTAP suite passes.
- `node --test supabase/functions/content-assets/logic.test.mjs supabase/functions/notifications-worker/logic.test.mjs tools/identity-e2e/content-retention.test.mjs` -- expected: cleanup unit tests pass.
- `node tools/identity-e2e/content-retention.mjs --evidence _bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.2/f3-content-retention-e2e.jsonl` -- expected: local HTTP cleanup flow passes and leaves no synthetic rows or objects.
- `node tools/ci/check-migrations.mjs --base origin/main` -- expected: ordered unique migrations pass; the migration is ASCII with no backslashes.
- `flutter analyze` and `flutter test` in `packages/design_system`, `packages/client_core`, `apps/mobile` and `apps/staff` -- expected: all four existing client suites remain clean.

**Manual checks:**
- On staging only, verify migration version, system command scope, changed function hashes, module guards and signed-out public reads. Completed against `tmurpotfluignacfueki`; evidence is in `evidence-6.2/staging-verify.md`. Do not manually invoke the scheduled worker on staging.
- Owner action remains: create and register the staging retention principal and set its two `content-assets` Edge secrets. Until then scheduled cleanup remains fail-closed; no staging synthetic upload or notification was used.
