# Story 5.12 external check fixes on staging (`tmurpotfluignacfueki`, bic-kafue-platform-test)

Applied on 2026-10-21 by the parent session through the Supabase connector (`apply_migration`), after 5.9. The file is ASCII only, with no backslashes, and travelled verbatim.

- Staging recorded `cells_external_check_fixes` as `20261021132636`, and the local file was renamed to match.
- Function drift: `md5(pg_get_functiondef(...))` (carriage returns removed) was compared for `app.cells_confirm_request` and `app.cells_record_actual_leaders`. Both match a fresh local reset.
- Verification of the fixes: `external-check-fixes-verify.txt` (db:test 4238 tests pass on a fresh reset; cells, records, transfer, pilot and absence E2E all pass).
