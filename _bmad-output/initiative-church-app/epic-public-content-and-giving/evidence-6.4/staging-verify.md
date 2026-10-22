# Story 6.4 staging verification

Date: 2026-10-22
Project: `tmurpotfluignacfueki` (staging only)

- Before applying entry 4, `list_migrations` confirmed the project history included `20261022012809_content_rights_banners`; the latest was F3, `20261022112247_content_asset_retention`.
- Applied `20261022123202_content_public_offline_rights` through the Supabase migration connector. The project history then listed version `20261022123202` as latest.
- Compared the local fresh-reset and staging hashes for `app.content_public_event_json`, `app.content_public_event`, `app.content_public_events`, `app.content_public_banner_json` and `app.content_public_banners`; all five matched.
- Repeated the comparison after the final local reset and review fix; the five staging and local hashes still matched exactly.
- Staging guard checks: `app.contract_boundary_violations() = 0`, `app.contract_unowned_objects() = 0`, exposed Content tables = `0`.
- Executed the two public list functions as `anon`. Both returned zero rows on staging. Every returned row (vacuously) satisfied `offline_allowed = true`; there were no ineligible rows.
- No staging content was created or published. No staging notification was sent. No production project was accessed.

The empty staging lists mean this verifies the signed-out function permissions and response shape, while synthetic row-level eligibility, display-only rights and withdrawal behavior are covered by the local pgTAP and E2E checks.
