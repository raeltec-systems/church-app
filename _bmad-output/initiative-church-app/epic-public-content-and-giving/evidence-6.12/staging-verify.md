# Story 6.12 staging verification (2026-10-27)

Project `tmurpotfluignacfueki` (staging). Production untouched. No content was published, no
duty was linked, no gate changed and **no notification was sent** on staging (the 4.16-style
review notice is proven locally only: `supabase/tests/content_event_duty_links_test.sql` and
`tools/identity-e2e/content-event-duty-links.mjs`, 10/10, evidence `local-e2e.jsonl`).

- Applied verbatim through the Supabase MCP `apply_migration`; staging recorded version
  `20261027192013` (after entry 10's `20261027191003`). The local file was renamed to
  `supabase/migrations/20261027192013_content_event_duty_links.sql`.
- Function hashes (`md5(replace(pg_get_functiondef(oid), chr(13), ''))`): all 12 added or
  replaced functions match the fresh local reset:

  | Function | md5 |
  |---|---|
  | api.content_staff_event_duty_links(uuid) | efb2d95e4076b5b4eb55b5fdf5dbb16a |
  | app.content_event_archive(uuid, bigint, jsonb) | 5c1a932fdba58b83c4f72d8f86860bb8 |
  | app.content_event_changes(uuid, integer, integer) | 351b337d7d6ee450cbebaf8342c09972 |
  | app.content_event_flag_duties(uuid, integer, text[]) | fa63b9b7437c9e9a06b52e7d84040b69 |
  | app.content_event_publish(uuid, bigint, jsonb) | b5db48cfc1a3385f166ae620d837174b |
  | app.content_event_source_check(jsonb) | 17189abfcf062e480d9655ec64394174 |
  | app.content_event_withdraw(uuid, bigint, jsonb) | 3ef43d25a9c898669cbb821c56a2ddd2 |
  | app.content_staff_event_duty_links(uuid) | 2071f43bc0e53e9de409601521f04500 |
  | app.duties_event_ref_error(uuid) | f22968f0482f93d77887bbefb223136f |
  | app.duties_my_assignment_json(uuid) | ec2ecaa1cec862e6357d2f47cb9486f0 |
  | app.duties_occurrence_event_ref_guard() | 6a4769ec4e5010d3fd81906722946dd8 |
  | app.duties_series_event_ref_guard() | 0030603b8ea102ae69bf39f5447fe060 |

- `app.contract_boundary_violations()` 0, `app.contract_unowned_objects()` 0.
- Link sources: `cells_programme_part:cell_part`, `content_event:event`.
- Signed-out: `api.content_public_events()` answers (1 published SYNTHETIC event) with no duty,
  rota, department, review or flag key; anon has no EXECUTE on
  `api.content_staff_event_duty_links`; authenticated has no EXECUTE on
  `app.duties_event_ref_error`.
- Read-only check of the contract change: `app.duties_event_ref_error(<random uuid>)` answers
  `not_published`; for the published SYNTHETIC event it answers null (linkable).
