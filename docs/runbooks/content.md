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
- **Verification (owner decision 2026-10-21; tenure decision 2026-10-22).** A destination added or changed by one Admin is verified by a different Admin before members see it. Every saved revision needs its own verification and any save clears it, because every field a giver acts on can redirect a gift (name, numbers, steps, USSD code, contact). The verifier must not be any Admin (member or account) who saved that revision (`saved_by_members`, `saved_by_accounts`), and the tested date is not before the church date the revision was last saved. A save that changes nothing is refused, so nobody becomes a saver by accident, and each save records the names of the fields it changed (`app.content_giving_audit`, action `saved`). The trigger `content_giving_revisions_guard` (SQLSTATE `PCNT1`) refuses a verification by any of the revision's savers or recorded together with a change, refuses any change of a verified draft that keeps its verification, and keeps a published revision immutable (attribution may only be anonymised). In practice: one Admin enters or changes the details, another tests them and verifies, either publishes. If the verifier finds a mistake, the Admin who entered the details fixes it and the other verifies. If both have saved the draft, nobody with a hand in it can verify: a third Admin verifies, or an Admin discards the draft (`content.discard_giving_draft`, a method with a live revision; a never-published draft is archived) and one Admin enters it again. The server also requires the verifier's active Admin grant to be at least 14 elapsed 24-hour days old. Identity adds `admin_tenure` (`granted_at`, `admin_since`, `granted_by`) to `api.identity_my_access()` for the current caller only; it is not part of the Admin roster. `app.content_giving_verify` reads this registered self-read contract and returns `admin_tenure: not_eligible` when the grant is recent or the context is missing or malformed. The check compares the grant timestamp to server time; the Lusaka `admin_since` date is display only. The staff Verify dialog shows “Admin since <date>, granted by <name>” and offers Refresh access when the context needs reloading.
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
- Field codes: `required`, `invalid`, `too_long`, `unknown_field`; `steps: too_many`; `tested_on: out_of_range` (a church date from 90 days ago to today), `tested_on: before_saved` (before the day the draft was last saved); `admin_tenure: not_eligible` (the active grant is younger than 14 elapsed days or the self-read context is unavailable); `position: out_of_range`; `method_id`: `unchanged`, `nothing_to_verify`, `already_verified`, `saved_by_you`, `not_verified`, `nothing_to_publish`, `not_published`, `nothing_to_discard`, `never_published`, `archived`; `name: sample_only`. Success `data`: `{method_id, revision, state, live_revision_no, draft_revision_no}`.

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
- **Staff web.** **Giving** (`/content/giving`, sidebar group **Content**, Admin only): the methods in public order with their state (Draft, needs verifying; Verified, ready to publish; Live; Live, changes need verifying; Live, changes ready to publish; Hidden; Archived), Move up and Move down, New method (type chosen once), Edit, Verify (shows “Admin since <date>, granted by <name>” and the 14-full-day rule; Refresh access appears if grant context is missing or the server refuses it; still disabled for anyone who saved the draft with "You saved changes to these details, so a different Admin must verify them."), Publish, Discard changes, Hide and Archive, and who saved, verified and published each revision.

### Local runs

```bash
npx supabase db reset --local && npx supabase test db
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/content-giving.mjs --evidence _bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.3/content-giving-e2e.jsonl
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/content-giving.test.mjs
```

The E2E uses fictional numbers +44 7700 900510-900518, checks a just-granted Admin is refused without a revision change, checks the self-read grantor, and removes everything it created.

### Owner manual check on staging (the ticket's verify)

1. Two SYNTHETIC Admins, A and B (staff web, **Roles & access**).
2. As A, **Giving** > **New method** > Mobile money: `SAMPLE Mobile Money`, a SAMPLE beneficiary, merchant ID `990101`, starting code `*990#`, three steps and a contact. Save draft. Then a Bank method `SAMPLE Bank transfer` with a fictional account number. A signed-out phone's **Give** shows neither.
3. As A, Verify is disabled ("You saved these details, ..."). Before B verifies, let a recently granted Admin C open Verify: C sees their own “Admin since <date>, granted by <name>” context, and the server refuses with `admin_tenure: not_eligible` without changing the method revision. As B, Verify each (tested today, and how). As A, Publish both, then Move the bank method up. An Admin with at least 14 full elapsed days can verify when the existing checks pass; pgTAP pins the exact boundary.
4. On a signed-out phone, **Give** lists both in that order; open each, Copy each value and paste it somewhere: it is exactly the value. The sample banner shows.
5. As A, Edit the bank method's account number and Save draft: Publish is refused until B verifies; meanwhile the phone still shows the old number. (If B also saves the draft, neither can verify it: Discard changes and let A enter it again.) After B verifies and A publishes, the phone shows the new one.
6. As a Media member, a Pastor and a plain member: no **Giving** entry, and `/content/giving` says giving methods are managed by Admins.

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

## Story 6.2: rights records, the Q5 gate, the asset path and Home banners

Migration: `supabase/migrations/20261022012809_content_rights_banners.sql` (the version staging recorded). pgTAP: `supabase/tests/content_banners_test.sql`. Edge Function: `supabase/functions/content-assets/` (Node tests `logic.test.mjs`, `sanitize.test.mjs`). E2E: `tools/identity-e2e/content-banners.mjs` (offline tests `content-banners.test.mjs`). Plan: `_bmad-output/initiative-church-app/epic-public-content-and-giving/story-publish-home-banners-with-validated-images-through-the-publi-plan.md`.

### Rights records (kind `rights`)

- A rights record is a content item of kind `rights` (Admin, Pastor, Media) and reuses the 6.1 lifecycle unchanged. Its revisions (`app.content_rights_revisions`) hold `label`, `source_key` (`^[a-z0-9][a-z0-9-]{1,40}$`, the key the Q5 value names), `holder`, `basis` (`public_domain`, `licence`, `permission`, `church_owned`), `clears_display`, `clears_offline`, `clears_audio` (at least one) and `evidence` (1000, multiline).
- **Verifying is publishing.** `content.verify_rights_record` puts the open draft revision in force; the verifier and the date are that revision's publish attribution (`verified_by`, `verified_at` in the editors' read). Saving a record in force opens a new draft revision; the verified one stays in force until the new one is verified. `withdraw_rights_record` suspends a record (every file citing it leaves the public reads at once); `archive_rights_record` retires it.
- **The rights check** `app.content_rights_clear(rights_id, use)` answers null when the live record is in force and explicitly clears the requested use, else `required`, `unknown`, `not_in_force`, `use_not_cleared` or `source_not_cleared`. A `church_owned` record bypasses only the Q5 source-list check; its lifecycle and per-use flag still apply. Every other basis requires the source and use on Q5. Every kind with files or third-party text calls the helper before publishing, and public reads call it again on every read.

### The Q5 gate (`q5_content_rights`)

- Value: `{"sources": {"<source_key>": ["display" | "offline" | "audio", ...]}}`. A non-church-owned source clears a use only when the effective value lists it. A closed gate, an unknown source or a malformed value clears nothing (fail closed). A live, verified `church_owned` record whose revision explicitly clears the requested use does not need a Q5 entry.
- Local and staging read the labelled fixture: `synthetic` (display, offline, audio), `kjv` and `web` (display, offline). Production reads nothing until Israel approves the gate.
- **Third-party files** need their source and use on the Q5 list. Church-owned images are exempt, but still need a verified live record and the requested use flag. Church-authored text (events, announcements, sermon notes) cites no rights record and needs no Q5 entry.
- Approving (owner only, per environment): `select app.policy_approve('q5_content_rights', '{"sources": {"<source>": ["display"]}}', '<owner name>', '<decision reference>');`. `app.policy_approve` does not check this shape: check the value against third-party rights records first (`select source_key, label from app.content_rights_revisions`), because a misspelt source key clears nothing. Do not add church-owned sources merely to make their images publishable.

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
- **Private draft-file retention (Story F3).** Replaced and abandoned uploads remain private in `content-drafts` until they are at least 30 days old. The existing `notifications-worker` scheduler asks the `content-assets` Edge Function to claim a bounded batch of assets with no `content_revision_files` reference in any revision. It deletes bytes through the Storage API, then removes metadata. A draft or historical revision reference keeps the file. A failed or interrupted delete stays claimed for a 30-minute lease and is retried; while claimed, an asset cannot be attached or previewed. This never deletes from `content-public`, and has no member/editor action.
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
node tools/identity-e2e/content-retention.mjs --evidence _bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.2/f3-content-retention-e2e.jsonl
node --test supabase/functions/content-assets/logic.test.mjs supabase/functions/notifications-worker/logic.test.mjs tools/identity-e2e/content-retention.test.mjs
```

The E2E starts `supabase functions serve` when it is not running and stops it afterwards. It uses fictional numbers +44 7700 900501-900509 and removes everything it created, Storage objects included. Run the pgTAP suite on a fresh reset before the E2E: its admin bootstrap leaves restricted-operator journal rows behind.

### Staging setup (done for 6.2)

- Migration applied as `20261022012809`; buckets created by it.
- Edge Function `content-assets` deployed with `verify_jwt = false` (the MCP `deploy_edge_function` with `index.ts`, `logic.mjs` and `../_shared/system_access.mjs`). It needs no secret of its own: it uses the platform-provided `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY`.

### Story F3: retention setup and staging checks

Migration: `20261022112247_content_asset_retention.sql`. It registers `content.asset_retention_claim` and `content.asset_retention_finalize` under the separate `content_asset_retention` system purpose. The existing Notifications schedule remains the only scheduler. See `notifications.md`, Story F3, for the worker handoff and secret locations.

After applying the migration to staging project `tmurpotfluignacfueki`, deploy the updated `content-assets` and `notifications-worker` functions with `verify_jwt = false`. The owner creates one staging principal with purpose `content_asset_retention`, mints a staging system credential into a private local state directory, and registers only its digest in staging. Set the raw credential only as the `content-assets` Edge secret `CONTENT_ASSET_RETENTION_SYSTEM_CREDENTIAL`; copy the existing Vault `notifications_worker_trigger` into `content-assets` as `NOTIFICATIONS_WORKER_TRIGGER`. The Notifications worker keeps its existing trigger and `notifications_worker` credential and receives no Storage/service-role key or Content credential. Do not paste any token into SQL, chat, a ticket, or evidence.

Owner/operator checks (staging only):

1. Confirm migration version `20261022112247`, the two command registrations with purpose `content_asset_retention`, and exactly those two commands granted to the retention principal. Confirm the function hashes against the reviewed local migration state.
2. Confirm `verify-hosted.sql` passes for staging, no app table grants expose `content_assets`, and module guards pass. Signed-out public banner reads continue to work; `content-assets?action=retention-cleanup` without the trigger answers a coarse refusal and claims nothing.
3. Let the existing scheduler run naturally. Do not manually invoke the scheduled worker on staging. Confirm its status advances, the worker reports only retention counts/status, and no synthetic or unintended Notifications jobs were created. Do not create test uploads in staging.
4. For local functional evidence, run `tools/identity-e2e/content-retention.mjs`; it creates and removes only synthetic local rows and Storage objects. Staging credential rotation/revocation remains owner-controlled.

### Owner manual check on staging (the ticket's verify)

1. As a SYNTHETIC Media member on staff web, **Rights** > New: `SYNTHETIC theme artwork`, source `church-art` (not on Q5), basis Church-owned, Display ticked, evidence "SYNTHETIC test artwork". Save, then Verify. Create and verify a third-party record with source `acme-press` (Licence) and a church-owned record with Display unticked and Offline ticked.
2. **Banners** > New banner: Theme, year 2026, title `SYNTHETIC Theme 2026`, reference `Deuteronomy 7:9`, a text alternative. Save draft, then choose a landscape PNG or JPEG of at least 960 x 540. Pick the `acme-press` record and Publish: it is refused (`source_not_cleared`). Pick the `church-art` record and Publish: it succeeds without a Q5 entry. Try the church-owned record whose Display flag is off: publication is refused with `use_not_cleared`. In **Rights**, the `church-art` row says Q5 approval is not required for church-owned images.
3. Try a file over 5 MB and a text file renamed `.png`: both are refused with a message, and nothing is listed.
4. Publish a campaign banner linked to a published SYNTHETIC event the same way.
5. On a signed-out phone, Home opens with the theme card, then the campaign; tap each to open the original image.
6. Withdraw the campaign on staff web: after the sync and a return to Home on the phone, it is gone; its old image link answers 400.
