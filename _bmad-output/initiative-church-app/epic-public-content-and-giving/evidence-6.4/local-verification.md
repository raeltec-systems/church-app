# Story 6.4 local verification

Date: 2026-10-22

- `npx supabase db reset --local` completed with the final migration version `20261022123202_content_public_offline_rights.sql`.
- `npx supabase test db`: 62 files, 4,988 tests, all passed. The event and banner tests include the new public eligibility assertions and updated pgTAP plan totals.
- `node --test tools/identity-e2e/content-events.test.mjs tools/identity-e2e/content-banners.test.mjs`: 9/9 passed.
- `node tools/identity-e2e/content-events.mjs`: 10/10 passed; `content-banners.mjs`: 16/16 passed. Both ran only against the guarded local stack with synthetic data and cleaned up their rows and objects.
- Full Flutter analysis: no issues in `packages/design_system`, `packages/client_core`, `apps/mobile` and `apps/staff`.
- Focused review regression `flutter test test/content/public_content_cache_test.dart`: 4/4 passed, including preservation of the prior in-memory value and timestamps after a cache miss.
- Full Flutter tests: `packages/design_system` 19, `packages/client_core` 894, `apps/mobile` 70 and `apps/staff` 56; all passed.
- Migration checker: 72 migrations ordered, unique and non-destructive relative to `origin/main` (the checker recognizes the existing owner-approved cleanup markers in two earlier migrations).
- The local phone-auth switch was restored to the local CLI's original configuration after E2E runs.

Not run: airplane-mode checks on a physical/emulated staging-configured device. The runbook records that owner manual check; the local widget/cache tests and staging signed-out reads provide automated coverage without seeding staging content.
