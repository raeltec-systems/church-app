# Story 6.6 staging verification

Date: 2026-10-26 (resumed verification; the earlier empty-catalog observation was on 2026-10-23)

## Target and migration

- Supabase project: `tmurpotfluignacfueki` (staging only).
- Before applying the final Bible migration, the project's migration history included `20261022012809_content_rights_banners` as required by the handoff.
- Applied the prepared WEB source-rights guard SQL after the owner authorized staging application. Supabase recorded it as `20261023120311_content_bible_web_source_rights_guard`; the local migration filename now matches the hosted version.
- Six Story 6.6 migrations are recorded through `20261026151013_content_bible_review_hardening`.
- The last migration restores null unknown/incomplete manifests and anonymizes/checks all four saved/published attribution columns. It has no row deletion or owner `_rows` step.
- All 28 Bible and staging-phone function hashes match the fresh local migration replay.
- No production project was accessed. This agent published no Bible text, changed no policy gate or rights record, and sent no staging notification.

## Read-only staging results after application

- `app.contract_boundary_violations()`: 0.
- `app.contract_unowned_objects()`: 0.
- Existing staging data now has published WEB: 66 books, 1,189 chapters and `offline_allowed: true`.
- Fourteen signed-out HTTP checks pass against the staging public API with only the publishable key. They cover the catalog, Genesis/Exodus boundary, Genesis 1 and 50, Exodus 1, Luke 17, exclusion of private fields, preservation of the omitted Luke 17:36 slot, and null unknown chapter/manifest responses.
- Redacted HTTP metadata is in `staging-public-read-20261026.jsonl`; it contains no tokens or verse text.
- Q5 was not changed by this run; no production clearance is implied.

## Not verified

- Physical signed-out phone acceptance remains due: reading a chapter, switching translations, canonical navigation, display-only download denial, and reopening an offline-cleared chapter after app relaunch in airplane mode.
- The successful public API checks do not demonstrate physical device behavior; the remaining device checks are carried to the entry 15 pilot.

## Independent review

- Four findings were fixed: publication-only deletion attribution, reconnect recovery, obsolete save completions and republishing a withdrawn live revision.
- The reviewer rechecked the corrections and reported no remaining actionable findings.
- Focused regressions pass: pgTAP 83/83 and Flutter Bible tests 22/22.

## Approval review

- Automatic approval review initially rejected the migration by treating it as an owner-only hand-applied file. The handoff explicitly authorizes connector migrations and reserves owner hand application for entries 8/11's `_rows` files.
- After that distinction and the non-destructive function-only scope were checked, the same connector accepted the verbatim migration as version `20261026151013`.


## Final local verification

- Fresh replay: 85 migrations.
- Full pgTAP: 64 files, 5106 assertions, all pass. Timing fixtures ran first; every file ran once with unchanged thresholds. Earlier alphabetical runs exposed the pre-existing Duties timing sensitivity.
- Flutter analysis clean; actual test cases: client_core 929, mobile 81, staff 59, design_system 19. Focused Bible tests: 22/22.
- Local HTTP: 7/7, helper tests 5/5, fictional account cleanup count 0 and phone auth restored off.
- Both staging release builds pass. Staff preview is HTTP 200 at localhost:8767.
