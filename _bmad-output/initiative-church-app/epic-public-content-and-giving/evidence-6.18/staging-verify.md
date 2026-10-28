# Story 6.18 staging verification (2026-10-28)

Project `tmurpotfluignacfueki` (staging). Never production.

- Before the apply, staging's latest migration was `20261028064546` (entry 19, `cells_my_meetings`), which touches none of the functions this file replaces (`content_state_ok`, `content_staff_sermon_json`); both still had their 6.1 / 6.9 bodies.
- Applied `content_sermon_drafts_from_duties` verbatim through the Supabase MCP `apply_migration`; staging recorded version **`20261028071717`**; the local file was renamed from `20261028070000` to `20261028071717_content_sermon_drafts_from_duties.sql`.
- Function hashes, `md5(replace(pg_get_functiondef(oid), chr(13), ''))`, staging = fresh local reset (8 of 8):

| Function | md5 |
|---|---|
| `app.content_state_ok` | `915ec9e5e5eb6893de5c79d4a8ff080a` |
| `app.content_staff_sermon_json` | `802df6a1415dc4af2fb508f195d1b4c4` |
| `app.content_sermon_duty_draft_outcome` | `00c4bfec1ece59f1ba509d1aa396fbad` |
| `app.content_sermon_from_duty` | `b3e54bd8c3d3d82467366213bc578953` |
| `app.content_sermon_duty_draft_in_scope` | `b3bd63a16669a562915c0776b7a915ff` |
| `app.content_duty_sermon_draft` | `033c662bfec9883e8a474a63ebb1bdd5` |
| `api.content_duty_sermon_draft` | `c0b8fe2a1f9fe10bbe613c3597ade392` |
| `app.content_sermon_duty_draft_erase_part` | `40eac5fef9f7f3ded8e1f7035968b348` |

- `app.contract_boundary_violations()` = 0, `app.contract_unowned_objects()` = 0; RLS on `app.content_sermon_duty_drafts`, no anon/authenticated table privilege; anon cannot execute `api.content_duty_sermon_draft`; `content.draft_sermon_from_duty` registered as a member command; 0 drafts.
- Signed-out HTTP (publishable key): `content_duty_sermon_draft` 401 (42501); `content_public_sermons` 200 `{"series": [], "sermons": [], "truncated": false}`; `content_staff_sermons` 401; `content_command` (draft_sermon_from_duty) 401; table `content_sermon_duty_drafts` not exposed (406 PGRST106).
- No duty was published, no draft created, nothing published and no notification sent on staging. The ticket's signed-in verify on staging is the owner manual check in `docs/runbooks/content.md` (story 6.18); the same matrix ran locally (pgTAP 48, E2E 9/9, `local-e2e.jsonl`).
