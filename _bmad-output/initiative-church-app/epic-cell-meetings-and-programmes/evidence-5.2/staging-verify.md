# Story 5.2 on staging (`tmurpotfluignacfueki`, bic-kafue-platform-test)

Applied 2026-10-21 by the parent session through the Supabase connector (`apply_migration`), after
5.1 (`20261021073514`). The file has no backslash escapes, so it travelled verbatim.

- Staging recorded `cells_meeting_reminders` as version `20261021081026`; the local file was renamed
  to `supabase/migrations/20261021081026_cells_meeting_reminders.sql`.
- Hosted checks after the apply: marker `staging`, `private_access` closed, alerting disabled, no
  recovery hold; 0 unowned objects, 0 unpinned functions, 0 boundary violations; three
  `cells_meeting` reminder contracts registered.
- Function drift: `md5(pg_get_functiondef(...))` with carriage returns removed, for every `app` and
  `api` function named `cells_*`, compared staging and local: identical for every function 5.1 and
  5.2 create or replace.
- Finding for the owner (not from this epic): `app.cells_text` from story 2.6 differs. Locally its
  format-character class is the ASCII text of `\u` escapes; on staging the same class holds the
  real characters, because the SQL path rewrites `\u` escapes into characters. Behaviour is the
  same. Epic 5 writes such classes with `chr()` codes so this cannot recur.
- Owner manual checks: `docs/runbooks/cells-meetings.md`, story 5.2 (record in `owner-check.md`).
