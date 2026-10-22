# Epic 6.5 staging verification

Date: 2026-10-22
Project: Supabase staging `tmurpotfluignacfueki` only

## Migration history

Before each apply, the staging migration list was checked. It contained the required `20261022012809_content_rights_banners` baseline and Identity name-policy migrations `20261022141846` and `20261022142816`. The two Epic 6.5 migrations are recorded as:

- `20261022153240_content_giving_handoff_offline_unsafe`
- `20261022154622_content_giving_logo_clear`

The second version is the version recorded by Supabase; the local file was renamed to match it.

## Schema and function verification

After both applies, the local definitions and staging definitions matched for the changed functions:

| Function | MD5 |
|---|---|
| `app.content_giving_public_json` | `9726c32a65e71438dbf1b11af0669fff` |
| `app.content_giving_revision_json` | `834f76eec751ef959187d2ec31b058f9` |
| `app.content_giving_save` | `79cc815fe1ec69df84459b79037c370b` |
| `app.content_giving_set_unsafe` | `35ead99989b95556e5ec781abf4bfdbf` |
| `app.content_giving_vocab` | `2e474fb29de1c87abdcbe8020ed94820` |
| `app.content_staff_giving_json` | `068781bcc4db8212ffa44c5cc78f4139` |

`app.contract_boundary_violations()` returned 0 rows and `app.contract_unowned_objects()` returned 0 rows.

## Read and policy checks

- Signed-out giving list returned `sample: true`, an empty `methods` array, and `truncated: false`; an unknown method detail returned `sample: true` and `method: null`.
- The staging environment reports `staging`; `q4_personal_data` remains closed. The current name validator returned an empty error object for an ordinary name, confirming that staging permits live member names while production remains gated.
- No SAMPLE giving methods were published and no staging notifications were sent.

## Client artifact

Built the Android arm64 release APK with the staging URL and publishable key after the final mobile cache change. No production endpoint was used.

- Artifact: `apps/mobile/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` (25,821,978 bytes)
- SHA-256: `4A9C1EEA5A28BD15E4EC54935777D8AD754855435C55FDAB733ED4F2D71FAB1E`
- Full Flutter package tests and analysis passed after the response-stream cancellation change.
