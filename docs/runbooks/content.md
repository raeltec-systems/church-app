# Runbook: public church content (epic 6)

Related: [contracts-and-owner-seams.md](contracts-and-owner-seams.md) (owner registry, deletion hooks), [command-foundation.md](command-foundation.md) (the 1.4 envelope), [client-shells.md](client-shells.md) (the mobile tabs), [production-promotion-content.md](production-promotion-content.md).

## Story 6.1: the publication lifecycle, events and the first public read

Migration: `supabase/migrations/20261021233523_content_events_tracer.sql` (the version staging recorded). pgTAP: `supabase/tests/content_events_test.sql`. E2E: `tools/identity-e2e/content-events.mjs` (offline tests `content-events.test.mjs`). Plan: `_bmad-output/initiative-church-app/epic-public-content-and-giving/story-publish-an-event-on-staff-web-and-read-it-as-a-guest-on-the-plan.md`.

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
- Field codes: `title` (120), `location` (160), `description` (2000, multiline, CRLF normalised): `required`, `invalid`, `too_long`. Text is trimmed of all edge whitespace (tabs, line breaks and Unicode spaces such as the no-break space count), so whitespace alone is `required`; the tables also refuse a blank value. `starts_at`, `ends_at` (UTC RFC3339): `required`, `invalid`, `out_of_range` (start within a year back and five years ahead); `ends_at`: `before_start`, `too_long` (more than 31 days). `event_id`: `nothing_to_publish`, `not_published`, `archived`.
- Refusals: `forbidden` for anyone without one of the kind's editor roles (a plain member, a Pending account with no member link), before any validation; `unauthenticated` for an untrusted session; `not_found`; `conflict` with `current_revision`. Anon cannot call the command (HTTP 401). A replay after the actor lost the role is `forbidden`.

### Reads

| Endpoint | Who | Returns |
|---|---|---|
| `api.content_public_events()` | anyone, signed in or not (`anon`, `authenticated`) | `{events: [P], truncated}`: published events that have not ended, soonest first, at most 200 |
| `api.content_public_event(event_id)` | anyone | `{event: P}` for a published event that has not ended, otherwise `{event: null}` (unknown, draft only, withdrawn, archived or ended) |
| `api.content_staff_events()` | live member access and an editor role for events | `{capacity, events: [S], truncated}`: every event with its `live` and `draft` revisions and attribution (display names; `Former member` once erased), archived last, at most 500. A plain member: 403 `not_granted`; a Pending account: 403 `not_linked`; anon: 401 |

P = `{event_id, title, description, starts_at, ends_at, location, publication_revision, published_at}`, and nothing else. Public reads are security definer functions, not views: no client role holds any privilege on any `app.content_*` table, and public reads are not logged per call (anonymous, no personal data).

### Deletion (story 2.11 hook)

`app.content_erase_member` is Content's one registered hook. `erase` replaces the member's and account's ids in `content_items` (created, published) and `content_audit` with the nil UUID, then runs every row of `app.content_erase_parts` with the same input (events: `app.content_event_erase_part`, revision `saved_by`/`published_by`). `check` only counts. Editors then read the person as `Former member`; published content stays published. No row is deleted, so there is no `_rows` file (entries 8 and 11 add parts with their own `_rows` files).

### Clients

- **Mobile.** The bottom tabs are **Home** and **Calendar** for everyone: signed out, Pending and members (owner decision 2026-10-21: the design's five tabs; Give, Bible & Hymns and Sermons join with entries 3, 6 and 9). My duties, My follow-ups and My cell are reached from their Home cards and the Account menu (pushed screens with a back arrow). Home lives in `home_screen.dart`: members get the greeting and their cards; guests and Pending get a welcome line and no member card; everyone gets **Coming up** (the next published events). **Calendar** lists the published events that have not ended, by church month; a multi-day event shows both endpoints in the list and on the detail (`/calendar/events/<id>`). A withdrawn (or ended) event disappears on the next refresh; an open detail says it is no longer on the calendar. A refresh that fails keeps what is shown and says from what time it is ("Couldn't refresh"); nothing is stored on the phone (entry 4 adds the offline cache).
- **Staff web.** **Events** (`/content/events`, sidebar group **Content**) for Media, Pastors and Admins: the staff page header (title, the finding line, New event, Reload), sections (Waiting to publish, On the calendar, Withdrawn, Past, Archived), one status mark per row, the live and draft versions with who saved and published them, and Edit, Publish (changes), Withdraw and Archive.

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

## Story 6.13: pinned announcements with an optional generic notice

Migration: `supabase/migrations/20261022011557_content_announcements.sql` (the version staging recorded). pgTAP: `supabase/tests/content_announcements_test.sql` (137). E2E: `tools/identity-e2e/content-announcements.mjs` (offline tests `content-announcements.test.mjs`). Plan: `_bmad-output/initiative-church-app/epic-public-content-and-giving/story-publish-pinned-announcements-with-an-optional-generic-push-plan.md`. Evidence: `evidence-6.13/`.

### Model

- A second content kind, `announcement` (editors: `admin`, `pastor`, `media`), on the 6.1 lifecycle through its registries only (kind row, five registered commands, erase part); no shared function was replaced. Revisions live in `app.content_announcement_revisions`: `title` (100), `body` (1500, multiline), `pinned`, who saved and first published the revision, and its notice record (`notified_at`, `notified_by_*`, `notified_count`). A published revision is immutable and is notified at most once (trigger, `PCNT1`).
- **Pinned belongs to the revision.** Pinning or unpinning a published announcement is Edit (tick or untick Pinned), Save draft, Publish changes; the published version stays as it is until then.

### Commands (`api.content_command`)

| Command | Expected | Payload |
|---|---|---|
| `content.create_announcement` | `null` | `{title, body, pinned}` |
| `content.save_announcement` | item revision | `{announcement_id, title, body, pinned}` (every field) |
| `content.publish_announcement` | item revision | `{announcement_id, notify}` (`notify` required, boolean) |
| `content.withdraw_announcement`, `content.archive_announcement` | item revision | `{announcement_id}` |

- Success `data`: `{announcement_id, revision, state, live_revision_no, draft_revision_no}`; a publish adds `notified` (jobs queued; 0 without a notice).
- Field codes: `title`/`body` `required`, `invalid`, `too_long`; `pinned`/`notify` `required`, `invalid`; `announcement_id` `nothing_to_publish`, `not_published`, `archived`; `notify` `already_notified` (that revision had its notice; publishing a withdrawn announcement again never notifies twice) and `too_many_recipients` (more than the limit below). With Q2 closed (production until Israel approves `q2_church_time`) a publish with a notice answers `unavailable {"policy": "gate_closed"}` and nothing is published; without a notice it works.
- Refusals as for events: `forbidden` for anyone without an editor role, `unauthenticated`, `not_found` (also an event's id), `conflict` with `current_revision`; anon 401.

### The notice (Notifications 3.2 source contract)

- Source type `content_announcement`, kind `announcement_published`, check `app.content_announcement_reminder_check`, title **Church announcement**, body **The church has posted an announcement. Open the app to read it.**, link `/announcements/{source_id}`. Nothing of the announcement ever enters a job, inbox item, push payload, receipt or audit row: the key carries ids and the published revision number only, and phones and the inbox show the fixed text.
- **Who gets it.** Every approved member whose 3.5 route is `member` (a live link in good standing, no hold, no review), evaluated at publish (`app.content_announcement_audience()`) and again at every recheck (`recipient_eligible`). Held, in-review, accountless, deactivated and deleted members get no job, inbox item, push job or direct-contact need (Content registers no direct-contact route); Pending accounts and guests are not members. The member's push setting decides the push only: with the category **Church announcement** off (Inbox > Notification settings) the inbox item still arrives.
- **Pace and bound.** Notifications has no church-wide fan-out (it enqueues one recipient per logical key; see [notifications.md](notifications.md#story-613-church-wide-notices-from-content)), so the publish transaction enqueues one job per member, at most `app.content_announcement_audience_limit()` (1000), falling due `app.content_announcement_pace()` (20) a minute: other reminders falling due meanwhile are never held back by more than about a minute, and the last of 1000 members is reached after about 50 minutes. Publishing with a notice to 1000 members took about 2 s locally (statement timeout 8 s).
- **Cancellation.** Publishing a newer revision cancels the earlier revision's pending jobs (`source_revised`); withdrawal and archive cancel them (`source_cancelled`). An inbox item already delivered stays; once the announcement is withdrawn or replaced it opens as out of date.

### Reads

| Endpoint | Who | Returns |
|---|---|---|
| `api.content_public_announcements()` | anyone (`anon`, `authenticated`) | `{announcements: [P], truncated}`: published announcements, pinned first, then the most recently published, at most 100 |
| `api.content_public_announcement(announcement_id)` | anyone | `{announcement: P}` or `{announcement: null}` (unknown, draft only, withdrawn, archived) |
| `api.content_staff_announcements()` | live member access and an editor role | `{capacity, audience: {members, limit, per_minute}, notice: {title, body}, announcements: [S], truncated}`: archived last, the others most recently changed first, at most 500; S as for events with `live`/`draft` revisions R = `{revision_no, title, body, pinned, saved_at, saved_by, notified_at, notified_by, notified_count}` |

P = `{announcement_id, title, body, pinned, publication_revision, published_at}` and nothing else.

### Deletion

The erase part `announcement_revisions` (`app.content_announcement_erase_part`) anonymises who saved, published and notified each revision; the notice record and the published text stay. No row deletion, so no `_rows` file.

### Clients

- **Mobile (everyone, signed in or not).** Home's **Announcements** section shows the pinned announcements (at most three) with **See all**; it says "No pinned announcements." or "No announcements right now." and never shows a failed read as empty; it asks again when Home or the app comes back. **Announcements** (`/announcements`, a pushed screen with a back bar) lists **Pinned** then **Latest**; one announcement (`/announcements/<id>`) shows the title, when it was posted (church time) and the text, or "This announcement is no longer published". The inbox item's **Open** leads there (`ClientPaths.deepLinkTargets`), on staff web too.
- **Staff web.** **Announcements** (`/content/announcements`, sidebar group **Content**, Media, Pastors and Admins): the finding line, **New announcement**, sections Waiting to publish, Pinned, Published, Withdrawn and the archived toggle, the versions with who saved, published and queued a notice, and Edit, Publish, Withdraw, Archive. **Publish** opens a dialog with **Also send a notice to members' phones** (off by default; disabled with the reason when that version already had its notice or the audience is over the limit), how many members can get it and roughly how long it takes, the exact text phones show (from the server), and, when publishing a change of a notified announcement, that the earlier version's undelivered notices stop.

### Local runs

```bash
npx supabase db reset --local && npx supabase test db
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/content-announcements.mjs --evidence _bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.13/content-announcements-e2e.jsonl
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/content-announcements.test.mjs
```

The E2E uses fictional numbers +44 7700 900681-900689 (the pgTAP file uses the same block inside its rolled-back transaction), opens `outbound_sending` and the push switch for its own run and puts both back, and removes everything it created.

### Owner manual check on staging (the ticket's verify)

Staging has `outbound_sending` open and push on, so a notice reaches every registered SYNTHETIC phone. Use SYNTHETIC members only.

1. Prepare four SYNTHETIC members: A (phone app signed in, notifications allowed), B (signed in; **Inbox > Notification settings > Church announcement** off), C held (**Login holds**), D with no account (an Admin records them without a login). Give a fifth member Media.
2. As Media on staff web, **Announcements > New announcement**: `SYNTHETIC Harvest week`, Pinned ticked, Save draft; a signed-out phone shows nothing. **Publish** without the notice.
3. Create `SYNTHETIC Choir practice moved` (not pinned) and **Publish** with **Also send a notice to members' phones**: the confirmation names how many members the notice is queued for.
4. A signed-out phone: Home shows **SYNTHETIC Harvest week** under Announcements; **See all** lists it under Pinned and the choir one under Latest.
5. Within a few minutes A's phone shows **Church announcement / The church has posted an announcement. Open the app to read it.** and nothing else; tapping it opens the choir announcement. B gets no notification but finds the item in **Inbox**. C and D get nothing.
6. Read the rows in the SQL editor (`<id>` is the choir announcement's id from staff web's address or `select item_id from app.content_announcement_revisions where title = 'SYNTHETIC Choir practice moved'`):
   ```sql
   select m.display_name, j.job_state, j.finish_reason, i.item_id is not null as inbox_item, p.push_state
     from app.notifications_jobs j join app.identity_members m on m.member_id = j.recipient_member_id
     left join app.notifications_inbox_items i on i.job_id = j.job_id
     left join app.notifications_push_jobs p on p.job_id = j.job_id
    where j.source_type = 'content_announcement' and j.source_id = '<id>' order by 1;
   select a.outcome, count(*) from app.notifications_attempts a join app.notifications_jobs j on j.job_id = a.job_id
    where j.source_id = '<id>' group by 1;
   select count(*) from app.notifications_jobs j
    where j.source_id = '<id>' and to_jsonb(j)::text like '%Choir%';   -- 0
   ```
   Expect one job and one inbox item per reachable member, a push job only for members with a device and the category on (none for B), no row for C or D, and 0 for the last query.
7. Withdraw the choir announcement: phones drop it on refresh and A's inbox item opens as out of date. **Publish again**: the notice box is disabled ("Members already had a notice about this version").
8. Clean up: archive both announcements; remove the SYNTHETIC members as in `identity-access.md`.
