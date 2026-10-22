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

## Story 6.2: rights records, the Q5 gate, the asset path and Home banners

Migration: `supabase/migrations/20261022012809_content_rights_banners.sql` (the version staging recorded). pgTAP: `supabase/tests/content_banners_test.sql`. Edge Function: `supabase/functions/content-assets/` (Node tests `logic.test.mjs`, `sanitize.test.mjs`). E2E: `tools/identity-e2e/content-banners.mjs` (offline tests `content-banners.test.mjs`). Plan: `_bmad-output/initiative-church-app/epic-public-content-and-giving/story-publish-home-banners-with-validated-images-through-the-publi-plan.md`.

### Rights records (kind `rights`)

- A rights record is a content item of kind `rights` (Admin, Pastor, Media) and reuses the 6.1 lifecycle unchanged. Its revisions (`app.content_rights_revisions`) hold `label`, `source_key` (`^[a-z0-9][a-z0-9-]{1,40}$`, the key the Q5 value names), `holder`, `basis` (`public_domain`, `licence`, `permission`, `church_owned`), `clears_display`, `clears_offline`, `clears_audio` (at least one) and `evidence` (1000, multiline).
- **Verifying is publishing.** `content.verify_rights_record` puts the open draft revision in force; the verifier and the date are that revision's publish attribution (`verified_by`, `verified_at` in the editors' read). Saving a record in force opens a new draft revision; the verified one stays in force until the new one is verified. `withdraw_rights_record` suspends a record (every file citing it leaves the public reads at once); `archive_rights_record` retires it.
- **The rights check** `app.content_rights_clear(rights_id, use)` answers null when the record clears the use now, else `required`, `unknown`, `not_in_force`, `use_not_cleared` or `source_not_cleared`. Every kind with files or third-party text calls it before publishing, and the public reads call it again on every read.

### The Q5 gate (`q5_content_rights`)

- Value: `{"sources": {"<source_key>": ["display" | "offline" | "audio", ...]}}`. A source clears a use only when the effective value lists it. A closed gate, an unknown source or a malformed value clears nothing (fail closed).
- Local and staging read the labelled fixture: `synthetic` (display, offline, audio), `kjv` and `web` (display, offline). Production reads nothing until Israel approves the gate.
- Following the epic's assumption on the open Q4/Q5 question (do banners or posters showing people need recorded consent?), **every file** needs its source on the Q5 list, church-owned images included. Church-authored text (events, announcements, sermon notes) cites no rights record and needs no Q5 entry.
- Approving (owner only, per environment): `select app.policy_approve('q5_content_rights', '{"sources": {"<source>": ["display"]}}', '<owner name>', '<decision reference>');`. `app.policy_approve` does not check this shape: check the value against the rights records first (`select source_key, label from app.content_rights_revisions`), because a misspelt source key clears nothing.

### The asset path

- **Buckets** (rows in `storage.buckets`, created by the migration): `content-drafts` (private) and `content-public` (public), both limited to PNG, JPEG and WebP and 10 MiB. No policy, function, trigger or table is added to the storage schema, so no client role can read, list or write either bucket through Storage. The public bucket serves only `/storage/v1/object/public/content-public/<path>`.
- **Uploads** go through the Edge Function `content-assets` (`POST ?action=upload&item_id=<uuid>&purpose=banner_image`, raw bytes) under the editor's live session; staff web calls it. The function:
  1. reads at most 10 MiB;
  2. measures and sanitises the bytes. Only a structurally complete PNG (checksums, image data of exactly the size the header claims), JPEG (frame, scans and end of image) or WebP (one image chunk; no animation) is kept. Its metadata (Exif with GPS or camera serial, XMP, text chunks, comments) and anything appended after its end are dropped. Pixels are never re-encoded. Refusals: `file: unsupported_type` (not one of the three, whatever its name or declared type), `invalid_image` (a header alone, truncated, corrupted), `type_mismatch` (the declared type contradicts the bytes), `too_large`;
  3. asks the database (`content.begin_asset_upload`), which checks the caller edits the item's kind and the purpose's limits (`app.content_asset_purposes`: banner images 5 MiB, 960 x 540 to 6000 x 6000, width/height 1.30 to 2.40);
  4. stores the kept bytes in `content-drafts` as `<asset_id>.<ext>` with the platform's service key;
  5. confirms them (`content.complete_asset_upload`): the database reads `storage.objects` and requires the stored size and type.

  Because sanitising drops metadata, a phone photo loses its Exif orientation: rotate a photo before uploading it. Banners are normally designed artwork.
- **Files on revisions.** `app.content_revision_files` attaches an asset and its rights record to a slot of a revision (banners: slot `image`). Only the open draft's rows can change (trigger, `PCNT1`).
- **What is public.** The desired public set is every file of a published item's live revision whose asset is ready, whose rights clear the purpose's use (`display` for images) and whose item meets its kind's public condition (`app.content_public_conditions`; banners: a campaign linked to an event only while that event is public). Its path is revision-keyed: `<kind>/<item_id>/r<revision_no>/<slot>.<ext>`. A public read names a file only once its object is present in `content-public`.
- **Sync** (`POST ?action=sync`, any content editor): copies each desired file that is missing from `content-drafts` to its public path and deletes every object in `content-public` outside the desired set. Staff web calls it after each banner publish, withdraw and archive, after each rights verify, withdraw and archive, and when Banners opens. Until a sync runs, a newly published banner is not on Home (its file is not public yet) and a withdrawn banner's file is still fetchable at its old path, although no read names it. The Banners screen shows both counts ("waiting", "public files to remove") with a Sync button. There is no scheduler: if a withdrawal must be enforced at once, open Banners or press Sync. Public objects are cached for at most 5 minutes (`max-age=300`).
- **Preview** (`GET ?action=preview&asset_id=<uuid>`, editors of the item's kind): the draft bytes with `cache-control: no-store, private`. No signed or reusable URL exists for a private object.
- **Draft files are kept.** Nothing deletes from `content-drafts` (ordinary commands delete nothing, and retention is a Q4 decision). Replaced and abandoned uploads stay private there.
- **Registering a new purpose** (entries 5, 6, 7, 9, 10 and 11): insert a row into `app.content_asset_purposes` (kind, rights use, media types, limits), a row into `app.content_media_types` for any new type, and widen both buckets' `allowed_mime_types`. A new type also needs measuring and sanitising support in `content-assets/logic.mjs`. The kind's save command attaches files with `app.content_file_attach(item, draft_no, slot, purpose, asset, rights)` (after `app.content_item_saved`), and checks `app.content_asset_error` and `app.content_rights_ref_error`. Its publish command checks `app.content_rights_clear(rights, use)`. Its public read uses `app.content_public_file(item, slot)`. A kind whose items are public only under a condition registers it with `app.content_register_public_condition(kind, 'app.content_<kind>_public_condition(jsonb)')`.

### Banners (kind `banner`)

| Command | Expected | Payload |
|---|---|---|
| `content.create_banner` | `null` | `{banner_kind, theme_year, title, subtitle, alt_text, event_id}` |
| `content.save_banner` | banner revision | `{banner_id, banner_kind, theme_year, title, subtitle, alt_text, event_id, image_asset_id, image_rights_id}` (every field; a null image or rights record clears that part of the draft) |
| `content.publish_banner`, `withdraw_banner`, `archive_banner` | banner revision | `{banner_id}` |
| `content.create_rights_record` | `null` | `{label, source_key, holder, basis, clears_display, clears_offline, clears_audio, evidence}` |
| `content.save_rights_record` | rights revision | `{rights_id, ...the eight}` |
| `content.verify_rights_record`, `withdraw_rights_record`, `archive_rights_record` | rights revision | `{rights_id}` |
| `content.begin_asset_upload`, `complete_asset_upload` | `null` | sent by `content-assets` only |

- Fields: `banner_kind` `theme` or `campaign`; `theme_year` required for a theme (2000-2100) and `must_be_null` for a campaign; `title` (80), `subtitle` (120, optional), `alt_text` (250, the text alternative, required); `event_id` (campaign only; an event that is not archived).
- Publishing needs a ready image (`image_asset_id: required`), a rights record that clears display (`image_rights_id: required | unknown | not_in_force | use_not_cleared | source_not_cleared`) and, when linked, a publicly readable event (`event_id: not_published`).

### Reads

| Endpoint | Who | Returns |
|---|---|---|
| `api.content_public_banners()` | anyone (`anon`, `authenticated`) | `{banners: [P], truncated}`: the theme first (latest year first), then campaigns (latest published first), at most 12; only banners whose image is in the public bucket, whose rights still clear display and whose linked event (if any) is public |
| `api.content_staff_banners()` | editors of banners | `{capacity, banners: [S], removals_pending, truncated}`; `public_image`: `shown`, `waiting` (sync places it), `event_not_public`, `blocked` (rights no longer clear) or null |
| `api.content_staff_rights()` | editors of rights | `{capacity, rights: [S], truncated}` with `verified_by`, `verified_at` and `q5_uses` (what the effective Q5 value lists for the record's source) |
| `api.content_file_plan()`, `api.content_asset_preview(asset_id)` | content editors (used by `content-assets`) | the sync plan; a draft object's path and type |

P = `{banner_id, banner_kind, theme_year, title, subtitle, alt_text, event_id, image: {path, media_type, width, height}, publication_revision, rights_revision, published_at}`; `image.path` is relative to the `content-public` bucket.

### Deletion

Erase parts `rights_revisions`, `banner_revisions` and `asset_uploads` replace the member's and account's ids with the nil UUID (saved, verified, published and uploaded attribution). No row is deleted, so there is no `_rows` file. Uploaded files are church content and stay.

### Clients

- **Mobile Home** opens with a 16:9 snap carousel (cards 310 px wide, radius 20). The theme card is the handoff's navy card (eyebrow `THEME FOR <year>`, title, reference, rings and the white emblem), and its uploaded image is the original a tap opens. A campaign card shows its image with a flat caption band. A tap opens the banner screen: the original image (pinch to zoom, described by its text alternative), title, subtitle and **See event** when one is linked. The carousel asks again when the app returns to the foreground and when Home is shown again. Images are held in memory only (entry 4 adds the offline cache).
- **Staff web** (Content group, Media, Pastor and Admin): **Banners** (`/content/banners`) shows the finding line, the waiting and removal counts with **Sync**, the sections Waiting to publish, On Home, Withdrawn and Archived, and the editor. In the editor, save the draft first; then choose an image (uploaded at once, previewed) and a verified rights record. **Rights** (`/content/rights`) lists the records with their basis, cleared uses, whether the Q5 list covers display, and who verified them, with the editor and Verify, Withdraw and Archive.

### Local runs

```bash
npx supabase db reset --local && npx supabase test db
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/content-banners.mjs --evidence _bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.2/content-banners-e2e.jsonl
node tools/auth-harness/local-phone-auth.mjs off
node --test supabase/functions/content-assets/logic.test.mjs supabase/functions/content-assets/sanitize.test.mjs tools/identity-e2e/content-banners.test.mjs
```

The E2E starts `supabase functions serve` when it is not running and stops it afterwards. It uses fictional numbers +44 7700 900501-900509 and removes everything it created, Storage objects included. Run the pgTAP suite on a fresh reset before the E2E: its admin bootstrap leaves restricted-operator journal rows behind.

### Staging setup (done for 6.2)

- Migration applied as `20261022012809`; buckets created by it.
- Edge Function `content-assets` deployed with `verify_jwt = false` (the MCP `deploy_edge_function` with `index.ts`, `logic.mjs` and `../_shared/system_access.mjs`). It needs no secret of its own: it uses the platform-provided `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY`.

### Owner manual check on staging (the ticket's verify)

1. As a SYNTHETIC Media member on staff web, **Rights** > New: `SYNTHETIC theme artwork`, source `synthetic`, basis Church-owned, Display ticked, evidence "SYNTHETIC test artwork". Save, then Verify. Create a second record with source `acme-press` (Licence) and verify it too.
2. **Banners** > New banner: Theme, year 2026, title `SYNTHETIC Theme 2026`, reference `Deuteronomy 7:9`, a text alternative. Save draft, then choose a landscape PNG or JPEG of at least 960 x 540. Pick the `acme-press` record and Publish: it is refused (the source is not on the Q5 list). Pick the `synthetic` record, Save and Publish.
3. Try a file over 5 MB and a text file renamed `.png`: both are refused with a message, and nothing is listed.
4. Publish a campaign banner linked to a published SYNTHETIC event the same way.
5. On a signed-out phone, Home opens with the theme card, then the campaign; tap each to open the original image.
6. Withdraw the campaign on staff web: after the sync and a return to Home on the phone, it is gone; its old image link answers 400.
