# Runbook: public church content (epic 6)

Related: [contracts-and-owner-seams.md](contracts-and-owner-seams.md) (owner registry, deletion hooks), [command-foundation.md](command-foundation.md) (the 1.4 envelope), [client-shells.md](client-shells.md) (the mobile tabs), [production-promotion-content.md](production-promotion-content.md).

## Story 6.1: the publication lifecycle, events and the first public read

Migration: `supabase/migrations/20261021233000_content_events_tracer.sql` (renamed to its hosted version when applied to staging). pgTAP: `supabase/tests/content_events_test.sql`. E2E: `tools/identity-e2e/content-events.mjs` (offline tests `content-events.test.mjs`). Plan: `_bmad-output/initiative-church-app/epic-public-content-and-giving/story-publish-an-event-on-staff-web-and-read-it-as-a-guest-on-the-plan.md`.

### Model (Content owns it)

- **One lifecycle for every kind.** `app.content_items` is one aggregate per published thing: `kind`, `lifecycle_state` (`draft` = never published, `published`, `withdrawn`, `archived`), `live_revision_no` (the current published revision; kept while withdrawn), `draft_revision_no` (the open private draft) and `revision` (the `expected_revision` of every command). Each kind keeps its revisions in its own table; events use `app.content_event_revisions`.
  - A save writes the open draft, or opens the next revision number when the item has none. The live revision stays public until a publish replaces it.
  - Publish makes the open draft live. With no draft, publish brings back a withdrawn item's live revision.
  - Withdraw hides the item from every public read (it stays republishable). Archive retires it; every later command answers `validation_failed {"<kind>_id": "archived"}`.
  - A published revision's content never changes (trigger `content_event_revisions_immutable`, SQLSTATE `PCNT1`); only its attribution can be anonymised.
- **Who edits.** `app.content_kinds.editor_roles` lists the Identity roles that edit a kind, in the order the audit records the capacity. Events: `admin`, `pastor`, `media` (story 2.3 roles). Giving methods (entry 3) will be `admin` only.
- **Audit.** `app.content_audit`: action (`created`, `draft_saved`, `published`, `withdrawn`, `archived`), actor member and account, capacity, request id, item, kind, revision numbers. No titles, names or free text.
- **No row deletion** in any command; nothing is ever removed, only states change.

### For later content kinds (entries 2-14): register, never edit

1. `insert into app.content_kinds (kind, editor_roles, description) values (...)`.
2. Create the kind's revision table (with an immutability trigger like `app.content_event_revision_guard`) and its handlers `app.content_<kind>_<verb>(p_actor uuid, p_expected_revision bigint, p_payload jsonb) returns jsonb`. Each handler starts with `app.content_command_actor(p_actor, '<kind>')`, locks with `app.content_item_lock`, and calls the lifecycle helper: `app.content_item_open`, `app.content_item_draft_no`, `app.content_item_saved`, `app.content_item_publish`, `app.content_item_withdraw`, `app.content_item_archive`, and returns `app.content_item_outcome(item, '<kind>_id')`. Kind-specific checks (rights, verification, linked duties) go in the kind's own handler before the helper call.
3. `select app.content_register_command('content.<verb>_<kind>', '<kind>', 'app.content_<kind>_<verb>(uuid, bigint, jsonb)'::regprocedure, <creates>);` The dispatch (`app.content_command`), the authorizer and the replay recheck read this table; nobody replaces them.
4. A kind that keeps member data registers an erase part: `select app.content_register_erase_part('<part>', 'app.content_<kind>_erase_part(jsonb)'::regprocedure);` It gets the 2.11 hook input, anonymises (or, through a `_rows` migration under the hosted rule, deletes) its rows when `phase` is `erase`, and always answers the number of the member's references left.
5. Add the kind's public read as a definer `app` function plus an invoker `api` wrapper granted to `anon, authenticated`, projecting only published fields, and add it to the anon ledger in `command_foundation_test.sql`.

### Commands (`POST /rest/v1/rpc/content_command`, `Content-Profile: api`, 1.4 envelope)

| Command | Expected | Payload |
|---|---|---|
| `content.create_event` | `null` | `{title, description, starts_at, ends_at, location}` |
| `content.save_event` | event revision | `{event_id, title, description, starts_at, ends_at, location}` (every field: the desired draft) |
| `content.publish_event`, `content.withdraw_event`, `content.archive_event` | event revision | `{event_id}` |

- Success `data`: `{event_id, revision, state, live_revision_no, draft_revision_no}` (no names: receipts keep it).
- Field codes: `title` (120), `location` (160), `description` (2000, multiline, CRLF normalised): `required`, `invalid`, `too_long`. `starts_at`, `ends_at` (UTC RFC3339): `required`, `invalid`, `out_of_range` (start within a year back and five years ahead); `ends_at`: `before_start`, `too_long` (more than 31 days). `event_id`: `nothing_to_publish`, `not_published`, `archived`.
- Refusals: `forbidden` for anyone without one of the kind's editor roles (a plain member, a Pending account with no member link), before any validation; `unauthenticated` for an untrusted session; `not_found`; `conflict` with `current_revision`. Anon cannot call the command (HTTP 401). A replay after the actor lost the role is `forbidden`.

### Reads

| Endpoint | Who | Returns |
|---|---|---|
| `api.content_public_events()` | anyone, signed in or not (`anon`, `authenticated`) | `{events: [P], truncated}`: published events that have not ended, soonest first, at most 200 |
| `api.content_public_event(event_id)` | anyone | `{event: P}` or `{event: null}` (unknown, draft only, withdrawn or archived) |
| `api.content_staff_events()` | live member access and an editor role for events | `{capacity, events: [S], truncated}`: every event with its `live` and `draft` revisions and attribution (display names; `Former member` once erased), archived last, at most 500. A plain member: 403 `not_granted`; a Pending account: 403 `not_linked`; anon: 401 |

P = `{event_id, title, description, starts_at, ends_at, location, publication_revision, published_at}`, and nothing else. Public reads are security definer functions, not views: no client role holds any privilege on any `app.content_*` table, and public reads are not logged per call (anonymous, no personal data).

### Deletion (story 2.11 hook)

`app.content_erase_member` is Content's one registered hook. `erase` replaces the member's and account's ids in `content_items` (created, published) and `content_audit` with the nil UUID, then runs every row of `app.content_erase_parts` with the same input (events: `app.content_event_erase_part`, revision `saved_by`/`published_by`). `check` only counts. Editors then read the person as `Former member`; published content stays published. No row is deleted, so there is no `_rows` file (entries 8 and 11 add parts with their own `_rows` files).

### Clients

- **Mobile.** The bottom tabs are **Home** and **Calendar** for everyone: signed out, Pending and members (owner decision 2026-10-21: the design's five tabs; Give, Bible & Hymns and Sermons join with entries 3, 6 and 9). My duties, My follow-ups and My cell are reached from their Home cards and the Account menu (pushed screens with a back arrow). Home lives in `home_screen.dart`: members get the greeting and their cards; guests and Pending get a welcome line and no member card; everyone gets **Coming up** (the next published events). **Calendar** lists the published events by church month; a multi-day event shows both endpoints in the list and on the detail (`/calendar/events/<id>`). A withdrawn event disappears on the next refresh; an open detail says it is no longer on the calendar.
- **Staff web.** **Events** (`/content/events`) for Media, Pastors and Admins: the finding line, New event, sections (Not published yet, On the calendar, Withdrawn, Past, Archived), one status mark per row, the live and draft versions with who saved and published them, and Edit, Publish (changes), Withdraw and Archive.

### Local runs

```bash
npx supabase db reset --local && npx supabase test db
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/content-events.mjs --evidence _bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.1/content-events-e2e.jsonl
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/content-events.test.mjs
```

The E2E uses fictional numbers +44 7700 900100-900109 and removes everything it created.

### Owner manual check on staging (the ticket's verify)

1. Give a SYNTHETIC member the Media role (staff web, **Roles & access**).
2. As that member on staff web, **Events** > **New event**: `SYNTHETIC Harvest Thanksgiving`, Saturday 09:00 to Sunday 12:00, a place and a description. Save draft; check a signed-out phone's Calendar does not show it. Publish.
3. On a signed-out phone: **Calendar** shows it with both days; open it: Starts and Ends show both endpoints.
4. On staff web, Edit the title and Save draft: the phone (pull to refresh) still shows the published title. Publish changes: the phone shows the new title after a refresh.
5. Withdraw: the phone no longer lists it after a refresh.
6. As a plain member on staff web: no **Events** entry, and `/content/events` says Events are managed by Media, Pastors and Admins.
