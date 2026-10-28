# Story 6.11 staging verification (2026-10-27)

Project `tmurpotfluignacfueki` (staging). Production was not touched.

## Apply

- `supabase/migrations/20261027140149_content_event_posters_rsvp.sql` applied verbatim through the
  MCP `apply_migration` (name `content_event_posters_rsvp`); staging records version
  `20261027140149`, after `20261027083618 content_sermons`. The local file was renamed to that
  version; the `_rows` file became `20261027140200_content_event_posters_rsvp_rows.sql`.
- The sermons migration replaces none of this migration's functions, so local order and staging
  order give the same definitions.
- The `_rows` file was **not** applied (owner step, see `docs/runbooks/content.md`, "Deletion and
  the `_rows` file"). Until it is, every member deletion's Content erase step on staging answers
  `unavailable` (`rows_migration_missing`) and erases nothing.

## Before the apply

1 event (published), 1 expected organiser backfill, boundary 0, unowned 0, 48 Content commands,
no `app.content_event_rsvps`.

## After the apply

| Check | Result |
|---|---|
| 32 added or replaced function definitions, `md5(replace(pg_get_functiondef(oid), chr(13), ''))` vs the fresh local replay | 31 equal; `app.content_rsvp_purge_rows(uuid)` differs as expected (staging has the stub, local has the `_rows` body) |
| Stub body contains `rows_migration_missing` | true |
| `contract_boundary_violations()` / `contract_unowned_objects()` | 0 / 0 |
| Content commands | 51 (48 + 3) |
| `app.content_member_commands` | `content.cancel_rsvp`, `content.rsvp_event` |
| Purpose `event_poster` | present |
| Content lifecycle hooks | 3 (membership_deactivated, deletion_requested, scope_revoked) |
| RLS on `content_event_rsvps`, `content_event_organisers` | on |
| Client-role grants on the three new tables | 0 |
| Organisers backfilled | 1 (the existing event's creator) |
| RSVPs | 0 |
| Signed-out (`anon`) `api.content_public_events()` | the one published event, with `poster: null` and `rsvp: null` |
| `anon` may execute `api.content_my_event_rsvp` / `api.content_staff_event_rsvps`; select `app.content_event_rsvps` | false / false / false |

No content was published, no RSVP was made, no gate or rights record changed and no
notification was sent.
