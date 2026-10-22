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
- **Who edits.** `app.content_kinds.editor_roles` lists the Identity roles that edit a kind, in the order the audit records the capacity. Events: `admin`, `pastor`, `media` (story 2.3 roles). Giving methods (story 6.3): `admin` only.
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

## Story 6.3: verified giving methods and the Give tab

Migration: `supabase/migrations/20261022011438_content_giving_methods.sql` (the version staging recorded; the local file was `20261021235500` until applied). pgTAP: `supabase/tests/content_giving_test.sql`. E2E: `tools/identity-e2e/content-giving.mjs` (offline tests `content-giving.test.mjs`). Plan: `_bmad-output/initiative-church-app/epic-public-content-and-giving/story-publish-verified-giving-methods-and-show-how-to-give-to-gues-plan.md`.

Instruction-only giving (K15, K16, AD-15): the app shows where and how to give; the giver gives in their provider's own channel. There is no amount, payer, sender, donor, proof, receipt, gift or transaction field in any table, payload, read or screen, and a payload that carries one is refused (`unknown_field`). Offerings (the cell offering register) never extends this API.

### Model (registered through the 6.1 registries; nothing shared is replaced)

- **Kind** `giving_method`, editor roles `admin` only. Media and Pastors are refused every giving command (`forbidden`) and the Admins' read (403 `not_granted`).
- **Method** `app.content_giving_methods`: the fixed `method_type` (`mobile_money`, `bank`, `other`) and `sort_order`.
- **Revisions** `app.content_giving_revisions`: name, purpose, currency, the type's destination fields, the optional starting USSD code (mobile money), 1-12 steps, an optional note and the church contact, plus who saved it, its **verification** (verifier, time, the date the details were tested, how they were tested) and its publication. The table's checks hold each type to its own fields and refuse a published revision that is not verified.
- **Verification (owner decision 2026-10-21).** A destination added or changed by one Admin is verified by a different Admin before members see it. Every saved revision needs its own verification and any save clears it, because every field a giver acts on can redirect a gift (name, numbers, steps, USSD code, contact). The verifier must not be any Admin (member or account) who saved that revision (`saved_by_members`, `saved_by_accounts`), and the tested date is not before the church date the revision was last saved. A save that changes nothing is refused, so nobody becomes a saver by accident, and each save records the names of the fields it changed (`app.content_giving_audit`, action `saved`). The trigger `content_giving_revisions_guard` (SQLSTATE `PCNT1`) refuses a verification by any of the revision's savers or recorded together with a change, refuses any change of a verified draft that keeps its verification, and keeps a published revision immutable (attribution may only be anonymised). In practice: one Admin enters or changes the details, another tests them and verifies, either publishes. If the verifier finds a mistake, the Admin who entered the details fixes it and the other verifies. If both have saved the draft, nobody with a hand in it can verify: a third Admin verifies, or an Admin discards the draft (`content.discard_giving_draft`, a method with a live revision; a never-published draft is archived) and one Admin enters it again.
- **Residual risk (owner question).** Identity lets one Admin approve a member and grant Admin alone, so one person could create a second Admin identity and verify their own destination. The grants are audited (Identity), but a two-person rule for granting Admin would be an Identity change.
- **Order** is outside revisions: `content.move_giving_method` applies at once (order redirects nothing) and is audited.
- **Hide** is the lifecycle's withdraw: the method leaves every public read and stays republishable. Publishing it again brings back its verified live revision when it has no draft; with a draft, publishing publishes the draft, which must be verified first (or discard the draft to bring back the live revision). **Archive** retires it.
- **Audit.** The shared actions (created, draft_saved, published, withdrawn, archived) are in `app.content_audit`; the giving-only ones (`saved` with the changed field names, `verified`, `reordered`, `draft_discarded`) in `app.content_giving_audit`. Both hold ids, codes, field names, positions and revisions only.
- **Gate `q3_giving` (Q3).** Publication calls `app.policy_effective('q3_giving')`: closed in production until Israel approves it (`unavailable {"policy": "gate_closed"}`; drafts and verification still work). Its local/staging fixture is `sample_only`: there a method is published only if its name starts with `SAMPLE ` (`validation_failed {"name": "sample_only"}`). Staging methods use obviously fictional values, never the prototype's `000000`, its bank details or `*000#`.

### Commands (`api.content_command`, 1.4 envelope; expected = the method's `revision`, create: `null`)

| Command | Payload |
|---|---|
| `content.create_giving_method` | `{method_type, ...the type's fields}` |
| `content.save_giving_method` | `{method_id, ...the type's fields}` (every field: the desired draft; the type never changes) |
| `content.verify_giving_method` | `{method_id, tested_on, test_method}` |
| `content.publish_giving_method`, `content.hide_giving_method`, `content.archive_giving_method` | `{method_id}` |
| `content.move_giving_method` | `{method_id, position}` (1-based among the methods that are not archived) |
| `content.discard_giving_draft` | `{method_id}` (a method with a live revision and a draft) |

- Fields of every type: `name` (required, 60), `purpose` (60), `currency` (three letters, upper-cased), `steps` (required, 1-12 single-line items of 200), `note` (200), `contact` (required, 160). `mobile_money` adds `beneficiary` (required, 120), `identifier_kind` (`merchant`, `till` or `phone`), `identifier` (required, up to 40 letters, digits, spaces or hyphens, optional leading `+`) and `ussd_code` (`*`, digits or `*`, then `#`). `bank` adds `bank_name` (required, 80), `beneficiary` (required), `account_number` (required, 4-34 letters, digits, spaces or hyphens), `branch` (80), `branch_code` (20), `swift_code` (8 or 11) and `reference` (120). `other` adds nothing. Another type's field is `unknown_field`.
- Field codes: `required`, `invalid`, `too_long`, `unknown_field`; `steps: too_many`; `tested_on: out_of_range` (a church date from 90 days ago to today), `tested_on: before_saved` (before the day the draft was last saved); `position: out_of_range`; `method_id`: `unchanged`, `nothing_to_verify`, `already_verified`, `saved_by_you`, `not_verified`, `nothing_to_publish`, `not_published`, `nothing_to_discard`, `never_published`, `archived`; `name: sample_only`. Success `data`: `{method_id, revision, state, live_revision_no, draft_revision_no}`.

### Reads

| Endpoint | Who | Returns |
|---|---|---|
| `api.content_public_giving_methods()` | anyone (`anon`, `authenticated`) | `{sample, methods: [P], truncated}`: the published methods in the church's order, at most 50 |
| `api.content_public_giving_method(method_id)` | anyone | `{sample, method: P}` or `{sample, method: null}` (unknown, draft only, hidden, archived) |
| `api.content_staff_giving_methods()` | live member access and Admin | `{capacity, methods: [S], truncated}`: every method with its `live` and `draft` revisions, verification and attribution (`saved_by_you`, `verified_by_you`; `Former member` once erased), in the public order, then the archived ones |

P = `{method_id, method_type, name, purpose, currency, details: [{key, value}], ussd_code, steps, note, contact, verified_on, publication_revision, published_at}`: the copyable values in display order (mobile money `beneficiary`, then `merchant_id`, `till_number` or `phone_number`; bank `bank_name`, `beneficiary`, `account_number`, `branch`, `branch_code`, `swift_code`, `reference`) and the date the church tested the details. Never the verifier, the test notes, editor identity or a draft. `sample` is true off production; the app shows the amber sample banner from it.

### Deletion

The erase part `giving_methods` (`app.content_giving_erase_part`) replaces the member's and account's ids in revision `saved_by` (the last saver and the savers lists), `verified_by` and `published_by` and in `app.content_giving_audit` with the nil UUID. Admins then read the person as `Former member`; published methods stay published. No row deletion, so no `_rows` file.

### Clients

- **Mobile.** The tabs are Home, Give and Calendar (Bible & Hymns and Sermons join between Home and Give with entries 6 and 9). **Give** (`/give`) opens without sign-in: "How to give", the explainer that the app neither processes nor records gifts, the methods in order (name; purpose · currency), and the church contact when every method shares one. A method (`/give/methods/<id>`) shows the sample banner (when `sample`), a Copy button beside each value (it copies exactly the value and announces "<label> copied"), the starting code for mobile money (copyable; the dialler button is entry 5), the numbered steps, the note, **Before you confirm** (check that the provider shows the beneficiary), "Details checked by the church on <date>" and the contact. No amount, success state, giving history or "record my gift". A hidden method disappears on the next refresh; an open one says it is no longer listed.
- **Staff web.** **Giving** (`/content/giving`, sidebar group **Content**, Admin only): the methods in public order with their state (Draft, needs verifying; Verified, ready to publish; Live; Live, changes need verifying; Live, changes ready to publish; Hidden; Archived), Move up and Move down, New method (type chosen once), Edit, Verify (Tested on, How it was tested; disabled for anyone who saved the draft with "You saved changes to these details, so a different Admin must verify them."), Publish, Discard changes, Hide and Archive, and who saved, verified and published each revision.

### Local runs

```bash
npx supabase db reset --local && npx supabase test db
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/content-giving.mjs --evidence _bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.3/content-giving-e2e.jsonl
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/content-giving.test.mjs
```

The E2E uses fictional numbers +44 7700 900510-900518 and removes everything it created.

### Owner manual check on staging (the ticket's verify)

1. Two SYNTHETIC Admins, A and B (staff web, **Roles & access**).
2. As A, **Giving** > **New method** > Mobile money: `SAMPLE Mobile Money`, a SAMPLE beneficiary, merchant ID `990101`, starting code `*990#`, three steps and a contact. Save draft. Then a Bank method `SAMPLE Bank transfer` with a fictional account number. A signed-out phone's **Give** shows neither.
3. As A, Verify is disabled ("You saved these details, ..."). As B, Verify each (tested today, and how). As A, Publish both, then Move the bank method up.
4. On a signed-out phone, **Give** lists both in that order; open each, Copy each value and paste it somewhere: it is exactly the value. The sample banner shows.
5. As A, Edit the bank method's account number and Save draft: Publish is refused until B verifies; meanwhile the phone still shows the old number. (If B also saves the draft, neither can verify it: Discard changes and let A enter it again.) After B verifies and A publishes, the phone shows the new one.
6. As a Media member, a Pastor and a plain member: no **Giving** entry, and `/content/giving` says giving methods are managed by Admins.
