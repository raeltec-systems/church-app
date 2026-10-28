# Entry 6.14 staging verification (2026-10-28)

Project `tmurpotfluignacfueki` (staging). Production untouched. Nothing published, no gate
changed, no notification sent.

- Before: staging's latest migration was `20261028071717 content_sermon_drafts_from_duties`
  (entry 18). This entry replaces no shared function, so nothing of entry 18 was rebuilt.
- Applied `content_public_search` verbatim (ASCII, no backslashes); staging recorded it as
  `20261028072741`. The local file was renamed to `20261028072741_content_public_search.sql`.
- Function hashes, `md5(replace(pg_get_functiondef(oid), chr(13), ''))`, staging = fresh local
  reset:
  - `app.content_public_search(text)` 92ca83b809420cbb01739234ae3dc428
  - `api.content_public_search(text)` 7c5279365c9544bbffbbf65735df411a
- `app.contract_boundary_violations()` 0, `app.contract_unowned_objects()` 0.
- anon has EXECUTE on `api.content_public_search(text)`; service_role does not.
- Signed-out HTTP (publishable key only, `Content-Profile: api`):
  - `{"query":"synthetic"}` 200 `{"query":"synthetic","sermons":[],"events":[],"announcements":[],"truncated":false}` (staging has no published sermons, events or announcements)
  - `{"query":"%%"}` 200, three empty lists (literal, no wildcard)
  - `{"query":"a"}`, `{"query":null}`, 101 characters: 400 `22023 invalid` (detail `query`)
