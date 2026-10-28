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

## Story 6.5: dialler handoff, offline giving instructions and unsafe warnings

Migrations: `supabase/migrations/20261022153240_content_giving_handoff_offline_unsafe.sql` and `supabase/migrations/20261022154622_content_giving_logo_clear.sql` (applied to staging project `tmurpotfluignacfueki`). Migration history was checked before each apply and the required parent Identity migrations and Content prerequisites were present. No SAMPLE giving methods were published. pgTAP: `supabase/tests/content_giving_test.sql` and `content_banners_test.sql`. E2E: `tools/identity-e2e/content-giving.mjs` (offline contract tests `content-giving.test.mjs`). Client checks: `packages/client_core/test/content/content_giving_test.dart`, `packages/client_core/test/content/public_content_cache_test.dart` and `apps/mobile/test/offline/public_content_cache_adapter_test.dart`.

- **Unsafe warning.** An Admin uses `content.set_giving_method_unsafe` with `{method_id, unsafe}`. The method-level value is audited as `unsafe_flagged` or `unsafe_cleared`, appears in anonymous list/detail projections, and changes without a notification. It does not change or re-verify the published destination revision. Give displays a prominent warning while the current public snapshot says `unsafe: true`.
- **Offline instructions.** Mobile stores only the last successful anonymous public giving list. A failed request can show a matching cached method with its church verification date and “Offline · saved at <time>”; without a saved list, it remains unavailable. A failed refresh preserves the last good snapshot with an offline/stale label. A successful list response replaces it and evicts methods no longer published.
- **Logo.** Provider logos use the existing Content asset and rights path, purpose `giving_logo`, with a 2 MiB limit. Online public projections omit a logo unless its rights clear display. Mobile stores logo bytes only when the projection also clears offline use; image or rights failures leave the giving instructions intact. Logos are keyed by method, publication revision and rights revision.
- **Dialler.** Android can open an external `tel:` intent for a valid starting USSD code. Returning resumes the same detail. If opening fails, the code remains copyable and manual steps remain visible. iOS and unsupported targets retain copy/manual guidance. The app does not report a successful payment.

### Local runs

```bash
npm run db:test -- --local supabase/tests/content_giving_test.sql supabase/tests/content_banners_test.sql
node --test tools/identity-e2e/content-giving.test.mjs
flutter test test/content/content_giving_test.dart test/content/public_content_cache_test.dart
flutter test test/offline/public_content_cache_adapter_test.dart
flutter analyze
```

Run the client-core Flutter commands from `packages/client_core` and the adapter command from `apps/mobile`. The API E2E (`node tools/identity-e2e/content-giving.mjs`) requires the local phone-auth switch and a reset local database. Before applying the migration to staging, list migrations and confirm the required Identity versions `20261022141846` and `20261022142816`, plus Content prerequisites through `20261022123202`, are present.

### Owner manual check on staging

Use an Android staging-configured emulator and an already-published SAMPLE mobile-money method. Do not use a real destination, publish another SAMPLE method, or change production gates. Tap **Open dialler**, return without confirming a payment, and verify the same instructions remain and the app makes no success claim. Copy the code and confirm its manual steps remain available. Load the Give list while online, enable airplane mode, reopen a method and confirm its verification date, offline timestamp and unsafe warning (when flagged) remain visible. Have an Admin flag or clear the SAMPLE method, refresh successfully on the phone, and confirm the warning follows the server. Hide the SAMPLE method, refresh successfully, then confirm it cannot return from cache; also verify that a failed refresh retains a stale last-good snapshot. Republish it after the check to restore staging state. Check a display-only logo appears online but its bytes are not kept offline. Do not create payment records or notifications.

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

## Story 6.4: offline public Calendar and Home content

Migration: `supabase/migrations/20261022123202_content_public_offline_rights.sql` (the version staging recorded; adds the server eligibility flag to the public event and banner projections). pgTAP: `supabase/tests/content_events_test.sql` and `content_banners_test.sql`. E2E: `tools/identity-e2e/content-events.mjs` and `content-banners.mjs` check the added public key and its eligibility. Client checks: `packages/client_core/test/content/public_content_cache_test.dart`, `apps/mobile/test/offline/public_content_cache_adapter_test.dart` and `packages/client_core/test/boundaries_test.dart`.

### What can be kept

- Mobile stores only the anonymous `api.content_public_events()` and `api.content_public_banners()` list projections in its private Application Support directory. The JSON manifest is versioned; banner image files are keyed by banner id, publication revision and rights revision. Event detail, staff reads, drafts, giving records and other public reads have no cache path.
- The server marks church-authored public events `offline_allowed: true`. A banner is eligible only while its current live image rights record clears `offline`; display-only banners remain visible online but are omitted from the mobile snapshot. An eligible banner is stored offline only when its image bytes were also fetched successfully.
- `path_provider` is used by the single mobile-only file adapter. Staff web and unconfigured builds use `NoPublicContentCache`. `connectivity_plus` is only a reconnect signal: a failed public request remains the deciding evidence that the server could not be reached.
- A successful refresh replaces the matching snapshot and removes old banner revision files, including items withdrawn or no longer cleared for offline use. A failed request keeps the last valid snapshot with an “Offline · saved at” state. A failed first request without a snapshot stays an unavailable state, not an empty list.

### Local runs

```bash
npx supabase db reset --local && npx supabase test db
node --test tools/identity-e2e/content-events.test.mjs tools/identity-e2e/content-banners.test.mjs
flutter test test/content/public_content_cache_test.dart test/boundaries_test.dart
flutter test test/offline/public_content_cache_adapter_test.dart
flutter analyze
```

Run each Flutter command from its package directory (`packages/client_core` or `apps/mobile`). Use `node tools/ci/check-migrations.mjs --base origin/main` after creating the migration.

### Owner manual check on staging

Use an Android staging-configured emulator and a church-owned synthetic banner whose rights clear offline use. As a signed-out user, load Home and Calendar once, switch airplane mode on, and confirm the eligible event and banner image remain visible with “Offline · saved at …”. Confirm a display-only banner is absent from the saved state. Restore connectivity, withdraw the synthetic event and banner or suspend the banner's offline right, refresh successfully, then switch airplane mode on again and confirm the withdrawn/ineligible items and old image revisions are absent. This check sends no notification. Do not treat a withdrawal as removed from a device until its next successful refresh observes the server change.

### Owner manual check on staging (the ticket's verify)

1. As a SYNTHETIC Media member on staff web, **Rights** > New: `SYNTHETIC theme artwork`, source `church-art` (not on Q5), basis Church-owned, Display ticked, evidence "SYNTHETIC test artwork". Save, then Verify. Create and verify a third-party record with source `acme-press` (Licence) and a church-owned record with Display unticked and Offline ticked.
2. **Banners** > New banner: Theme, year 2026, title `SYNTHETIC Theme 2026`, reference `Deuteronomy 7:9`, a text alternative. Save draft, then choose a landscape PNG or JPEG of at least 960 x 540. Pick the `acme-press` record and Publish: it is refused (`source_not_cleared`). Pick the `church-art` record and Publish: it succeeds without a Q5 entry. Try the church-owned record whose Display flag is off: publication is refused with `use_not_cleared`. In **Rights**, the `church-art` row says Q5 approval is not required for church-owned images.
3. Try a file over 5 MB and a text file renamed `.png`: both are refused with a message, and nothing is listed.
4. Publish a campaign banner linked to a published SYNTHETIC event the same way.
5. On a signed-out phone, Home opens with the theme card, then the campaign; tap each to open the original image.
6. Withdraw the campaign on staff web: after the sync and a return to Home on the phone, it is gone; its old image link answers 400.

## Story 6.6: read cleared Bible chapters online and offline

Migrations: `20261023020507_content_bible_translations.sql` adds private, revision-scoped translation and verse storage, the initial KJV/WEB chapter-count manifests, bounded import and shared Content lifecycle commands, rights-gated public projections, and the Bible staff catalog. `20261023020509_content_bible_staff_read_gate.sql` keeps the authenticated staff catalog wrapper volatile so its live editor-role check can lock the grant. `20261023033756_content_bible_manifest_registry.sql` permits additional syntactically valid translation codes only when a complete trusted manifest is registered, and lets a re-import select a registered manifest version. `20261023100446_content_bible_web_omitted_verses.sql` records the five blank verse slots present in eBible.org's WEB package, accepts only those trusted empty rows, and exposes omitted verse numbers in public chapter projections. `20261023120311_content_bible_web_source_rights_guard.sql` enforces a matching, verified eBible.org public-domain record for WEB at publication and public/offline reads; it is applied to staging. The WEB package is bundled in the staff app, so editors do not download or format CSV files. These migrations are additive. pgTAP: `supabase/tests/content_bible_test.sql`. Local HTTP E2E: `tools/identity-e2e/content-bible.mjs` (placeholder verse text only). Client/domain and screen tests: `packages/client_core/test/content/bible_test.dart` and `packages/client_core/test/content/bible_screens_test.dart`; mobile adapter and reader coverage is in `apps/mobile/test/offline/public_content_cache_adapter_test.dart` and `apps/mobile/test/mobile_app_test.dart`.

The server keeps imported text private by revision until the complete chapters match the registered manifest and an in-force rights record clears display use. Installing bundled WEB creates only a private draft; a draft eBible rights record can be attached, but display must be verified before publication and offline use has its own check. Anonymous responses contain only published chapters and their named public fields. Offline saving additionally requires offline rights. WEB manifest v2 carries five official omissions; those slots keep their verse numbers and no text is invented. The bundled public-domain source candidate does not approve Q5 or production distribution. The local E2E's KJV/WEB strings are labels for synthetic placeholder verses, never licensed text.

`20261026151013_content_bible_review_hardening.sql` restores a null manifest response for unknown or incomplete editions and anonymizes/checks both saved and published Bible attribution during account deletion. It changes existing Bible functions, adds no row deletion, and needs no owner `_rows` step. The reader refreshes on reconnect, offers an explicit online retry, preserves the selected reference on reload, and ignores obsolete save completions. A withdrawn translation with a live revision and no incomplete draft can be republished directly.

### Local checks

Run all database tests before the local Bible HTTP E2E. The E2E creates synthetic Auth users, removes them after the run, and retains its immutable published KJV/WEB fixtures in the disposable local database; reset before a second run.

```bash
npx supabase db reset --local
npx supabase db lint --local
npx supabase test db --local
node --test tools/identity-e2e/content-bible.test.mjs
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/content-bible.mjs
```

The phone-auth helper is local-only and refuses an SMS provider, credential, hook, test OTP or phone MFA setting. The Bible E2E restores the CLI Auth settings with the helper's `off` mode from `finally` on every exit path; if restoration itself fails, run `node tools/auth-harness/local-phone-auth.mjs off` before continuing. Run each Flutter test from its package directory; use `flutter test` and `flutter analyze` in `packages/client_core`, `apps/mobile`, and `apps/staff` as appropriate.

### Owner manual check on staging

All six Bible migrations through `20261026151013_content_bible_review_hardening.sql` are applied on project `tmurpotfluignacfueki`; history includes `20261022012809_content_rights_banners`. The local filenames match hosted versions. On 2026-10-26, all 28 Bible and staging-phone function hashes match the fresh local replay; staging boundary violations and unowned-object counts are 0. Existing staging data now includes published WEB with all 66 books, 1,189 chapters and offline clearance. Fourteen signed-out HTTP checks pass, including the Genesis/Exodus boundary, the omitted Luke 17:36 slot, exclusion of private fields, and null unknown chapter/manifest responses. The agent made no rights or policy approvals and sent no notification. See `evidence-6.6/staging-public-read-20261026.jsonl`. Physical phone checks below remain due for the entry 15 pilot; API checks do not demonstrate device behavior.

1. In **Rights**, create a staging WEB record for eBible.org as a private draft; confirm the staff installer can use it without treating the rights as verified. Verify the record separately before publication and clear display use; offline use remains separate. Confirm a record without display clearance refuses publication.
2. In staff **Bible**, choose the WEB source rights record and **Install WEB package**. The bundled source is checked against the trusted manifest and imported into a private draft in bounded batches. Finalize and publish only after the rights record is verified for display. Try to finalize a chapter with its terminal verse missing; finalization must fail and the draft must stay out of anonymous reads. Create a second draft with a different available chapter so the reader can demonstrate partial-corpus navigation.
3. On a signed-out phone, open **Bible & Hymns**, choose the cleared translation, book and chapter, switch translations, and navigate only through available chapters. Confirm unpublished or un-cleared text stays absent.
4. For a display-only translation, confirm no download action appears. For an offline-cleared test chapter, save it, relaunch the app in airplane mode, and confirm the saved chapter and its translation/book/chapter reference reopen. Previously saved copies are local files and cannot be remotely erased by a rights change.
5. Confirm an ordinary signed-in member cannot use staff Bible actions and that the staff catalog is available to Media, Pastor and Admin. Remove or withdraw staging fixtures after the demonstration where allowed; do not claim a cached chapter was erased from a device.

Do not approve `q5_content_rights` as part of this check. A staging demonstration does not clear production rights; the production catalog starts empty until the owner approves the source and the record clears display use.

## Story 6.11: event posters, Add to calendar and RSVP within capacity

Migrations: `supabase/migrations/20261027140149_content_event_posters_rsvp.sql` and its row-deletion file `supabase/migrations/20261027140200_content_event_posters_rsvp_rows.sql` (hand-applied on hosted projects, see "The `_rows` file" below). pgTAP: `supabase/tests/content_event_rsvp_test.sql`. E2E: `tools/identity-e2e/content-event-rsvp.mjs` (offline tests `content-event-rsvp.test.mjs`). Plan: `_bmad-output/initiative-church-app/epic-public-content-and-giving/story-show-event-posters-export-events-to-the-phone-calendar-and-r-plan.md`.

### Model (the events kind; nothing shared is replaced except the two registry-driven checks below)

- **Poster.** Optional, on an event revision: an upload of purpose `event_poster` (PNG, JPEG or WebP, at most 5 MiB, 540 x 540 to 6000 x 6000, width/height 0.50 to 2.40) in the file slot `poster`, a rights record (`poster_rights_id`) and a text alternative (`poster_alt_text`, 250). Publication needs a ready upload and a rights record that clears display now (church-owned records need no Q5 entry, story F2). The public path is `event/<event_id>/r<n>/poster.<ext>`; the content-assets sync places it. Events register a public condition: a poster leaves the public bucket at the next sync once its event has ended.
- **RSVP.** Optional on an event revision (`rsvp_enabled`, `rsvp_capacity` 1-10000 or no limit). `app.content_event_rsvps` keeps one row per event and member: `going`, `cancelled` (the member) or `released` (the member's church membership ended before the event). No command deletes a row. RSVP is open from publication until the event starts. Lowering the capacity below the people already going removes nobody: the event reads Full until places free. There is no waitlist and no notification.
- **Capacity under concurrency.** `content.rsvp_event` locks the event's `app.content_items` row (`FOR UPDATE`) before counting, so RSVPs to one event run one at a time and `going` can never exceed the capacity (the E2E races five members for one place, twice). An RSVP never changes the event's `revision`, so editors' saves are not made stale by members.
- **Organisers (owner decision 2026-10-21).** An event's organisers and Admins see the names of the members going; everyone else (other editors, members, guests) sees only the count and the spaces left. Organisers are per event: up to 10 members who hold an event editor role (Media, Pastor or Admin). The editor who creates an event is its first organiser (existing events: their creator, if they still edit events). Only an Admin or a current organiser changes the list (`content.set_event_organisers`), so another editor cannot make themselves an organiser. Names are on staff web only.
- **Member commands.** `app.content_member_commands` lists the Content commands any approved member with live access may send (today the two RSVP commands; entry 8's favourites can reuse it). `app.content_authorize_command` and `app.content_in_scope` read it: a member command key-share-locks the actor's member row before the receipt (a concurrent deactivation waits), its handler reads access again after the lock, and a replayed RSVP is in scope only for its own member. Every other Content command keeps the 6.1 rule (an editor role of the command's kind).
- **Lifecycle hook (story 2.10 contract).** `app.content_on_member_lifecycle` on `membership_deactivated` and `deletion_requested` releases the member's going RSVPs of events that have not started and ends the member's organiser rows; on `scope_revoked` it ends the organiser rows of a member who no longer holds an event editor role. A login hold changes nothing (the RSVP is kept). Restoration brings nothing back.

### Commands (`api.content_command`, 1.4 envelope)

| Command | Who | Expected | Payload |
|---|---|---|---|
| `content.create_event` | event editors | `null` | 6.1 fields + `rsvp_enabled?`, `rsvp_capacity?` (no poster: an upload needs the event) |
| `content.save_event` | event editors | event revision | 6.1 fields + `rsvp_enabled?`, `rsvp_capacity?`, `poster_asset_id?`, `poster_rights_id?`, `poster_alt_text?` (absolute: missing RSVP keys turn RSVP off, missing poster keys leave the draft without a poster) |
| `content.set_event_organisers` | an Admin, or an event editor who is an active organiser | event revision | `{event_id, organiser_ids}` (0-10 distinct members who edit events) |
| `content.rsvp_event` | approved members with live access | `null` | `{event_id}` |
| `content.cancel_rsvp` | approved members with live access | `null` | `{event_id}` |

- New field codes: `rsvp_enabled: invalid`; `rsvp_capacity: invalid|out_of_range|must_be_null`; `poster_asset_id: required|unknown|not_ready|retention_claimed`; `poster_rights_id: required|unknown` (and at publish `not_in_force|use_not_cleared|source_not_cleared`); `poster_alt_text: required|too_long|invalid`; `organiser_ids: required|invalid|too_many|not_editor`.
- RSVP refusals (field `event_id`): `not_public` (not a published event that has not ended), `rsvp_off`, `rsvp_closed` (started), `full`, `not_going` (cancel). A Pending, held or deactivated account: `forbidden`; a guest: HTTP 401. RSVP data: `{rsvp_id, event_id, rsvp_state, going, capacity, spaces_left, full}` (no names); the receipt's aggregate is the RSVP (`content_rsvp`).

### Reads

| Endpoint | Who | Returns |
|---|---|---|
| `api.content_public_events()`, `api.content_public_event(event_id)` | anyone | P gains `poster: null|{path, media_type, width, height, alt_text, offline_allowed}` (only once placed and cleared for display) and `rsvp: null|{capacity, going, spaces_left, full, open}`. Never a name or a member id. |
| `api.content_my_event_rsvp(event_id)` | approved members with live access (Pending 403, guest 401) | `{event_id, rsvp_state: going|cancelled|released|null, updated_at}` |
| `api.content_staff_events()` | event editors | each event gains `public_poster` (`shown`, `waiting`, `blocked`, `ended` or null), `rsvp_going`, `organisers [{member_id, name}]` and `sees_names` (the reader is an Admin or one of its organisers); each revision gains `poster`, `poster_rights`, `poster_alt_text`, `rsvp_enabled`, `rsvp_capacity`; the top level gains `organiser_options` (everyone who edits events) |
| `api.content_staff_event_rsvps(event_id)` | an Admin, or an event editor who is an active organiser (other editors 403 `not_granted`, members 403, guests 401) | `{rsvps: null|{event_id, capacity, going, attendees: [{name, rsvp_at}], truncated}}`: the members going, earliest first, at most 2000 |

### Deletion (story 2.11 hook) and the `_rows` file

The erase part `event_rsvps` (`app.content_rsvp_erase_part`) deletes the member's RSVP and organiser rows through `app.content_rsvp_purge_rows` and anonymises who changed organiser lists (nil UUID); `check` counts what is left. In the main migration the purge is a **fail-closed stub** that answers `unavailable` (`{"deletion": "rows_migration_missing"}`): until the `_rows` file is applied, **every** member deletion's erase step on that project waits and nothing is erased (the 2.11 worker retries). The `_rows` file replaces only that function.

**Owner step (staging, right after the main migration is applied there):** open the staging SQL editor (project `tmurpotfluignacfueki`), paste the whole file `supabase/migrations/20261027140200_content_event_posters_rsvp_rows.sql` (hosted name in the promotion runbook) and run it once. Then check:

```sql
select position('delete from app.content_event_rsvps' in pg_get_functiondef('app.content_rsvp_purge_rows(uuid)'::regprocedure)) > 0;  -- true
select has_function_privilege('authenticated', 'app.content_rsvp_purge_rows(uuid)', 'EXECUTE');  -- false
```

Production applies both files in order with the migrations at promotion (entry 17).

Staging (2026-10-27): the main migration is applied verbatim to `tmurpotfluignacfueki` as version `20261027140149` (the local file carries that version; the `_rows` file is `20261027140200`, after it). 31 of the 32 added or replaced function definitions hash identically to a fresh local replay; the 32nd, `app.content_rsvp_purge_rows`, is the stub until the owner step above. Boundary and unowned counts are 0, RLS is on, client roles hold no grant on the three tables, the existing event's creator was backfilled as its organiser, and the signed-out events read shows `poster: null` and `rsvp: null`. Evidence: `evidence-6.11/staging-verify.md`. **The `_rows` file is not yet applied on staging.**

### Clients

- **Mobile Calendar.** A row with a poster shows it as a 16:9 thumbnail (Home's Coming up too); the detail shows the poster in full with its text alternative, a **Places** row ("8 of 20 places left", "Full (20 places)", or "12 going"), the **RSVP** section and **Add to calendar**. RSVP: a guest gets **Sign in to RSVP**; a signed-in account without member access reads that RSVP is for approved church members; a member answers **I'm going** or, when going, sees **You're going** and **Cancel RSVP** (with a confirmation); a full event says so; an event that has started says RSVP is closed. **Add to calendar** (events that have not ended) hands the phone an `.ics` with both endpoints of a multi-day event, `SEQUENCE` = the publication revision and the copy caveat, through the 4.5 share-sheet handoff; the Duties export is unchanged. Posters and counts are not kept offline (the 6.4 snapshot keeps its shape).
- **Staff web Events.** The form gains **Members can RSVP** with optional **Places**, and, on a saved event, **Poster (optional)**: Choose poster (uploads at once), Remove poster, **Poster rights record**, **Poster description**. An opened event shows its RSVP count (every editor), the poster's public state, its **Organisers**, and for an Admin or an organiser **Who's coming** (read on demand) and **Change organisers**; other editors read that only organisers and Admins see who is coming. Opening Events and every publish, withdraw or archive run the content-assets sync.

### Local runs

```bash
npx supabase db reset --local && npx supabase test db
node --test tools/identity-e2e/content-event-rsvp.test.mjs
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/content-event-rsvp.mjs --evidence _bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.11/content-event-rsvp-e2e.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

The E2E uses fictional numbers +44 7700 900584-900596, serves the content-assets function when it is not running, and removes every row and Storage object it created.

### Owner manual check on staging (the ticket's verify)

Use SYNTHETIC names only. Do not publish an announcement or anything with a notice.

1. Give two SYNTHETIC members Media (**Roles & access**). As Media O on staff web, **Events** > **New event**: `SYNTHETIC Youth Camp`, two days, **Members can RSVP**, **Places** 2. Save draft. Add a poster (a church-owned image), choose a verified church-owned rights record, describe the poster, Save draft, Publish. The opened event says the poster is shown after the sync.
2. Create and publish a three-day `SYNTHETIC Conference`. On a signed-out phone, open each: the camp shows its poster and "2 of 2 places left"; both show their first and last day. **Add to calendar** on each: the phone's calendar entry spans all days (check the three-day one ends on its third day), and the caveat is shown under the button.
3. Members A and B tap **I'm going**; member C sees **Full**. Members C and D tap **I'm going** at the same moment on another capacity-1 event: one is going, the other is told no places are left.
4. Member A cancels: the camp shows one place left and C can take it.
5. An Admin deactivates a member who is going (**Membership status**): the camp's place is free again on the next refresh.
6. A signed-out phone has **Sign in to RSVP**; a Pending account reads that RSVP is for approved church members.
7. Media N (not an organiser) opens the camp on staff web: the count only, "Only this event's organisers and Admins see who is coming", no **Who's coming**. Media O and an Admin open **Who's coming** and see the names. Media O adds Media N with **Change organisers**: Media N now sees the names.
8. Right after the deploy (once), the owner applies the `_rows` file as above; the entry 17 suite reruns the RSVP deletion case on staging after that.

## Story 6.7: the church's Tonga hymn book, built into the app

Owner decision 2026-10-27: the hymn book is the official Brethren in Christ Church Tonga hymn book, "Inyimbo zya Bakristo" (2012 reprint). It ships inside both apps as one file, `packages/client_core/assets/hymn_book/hymn_book.json`, declared as an asset of `church_client_core`: hymns 1..199, then the choruses (Ziindululo) 1..67, each with its section, English title or tune name, hymnal reference (Z.H. = Zulu Hymnal, M.H. = Methodist Hymn Book), key, verses and chorus. There is no migration, table, rights record, staff screen, Content command, staging step or offline-cache key: the server never stores hymn text, and later entries (8, 10, 14) refer to an item by its id (`hymn-12`, `chorus-12`). Everyone reads and searches the book on the phone, signed in or not, with or without a connection.

### Where the book comes from

- `tools/hymn-book/manuscript/inyimbo_zyabakristo.txt` is the PDF's text, extracted with `pdftotext -enc UTF-8 -layout inyimbo_zyabakristo.pdf inyimbo_zyabakristo.txt` (pdftotext 4.06, Git for Windows mingw64). `manuscript/provenance.json` pins the PDF (SHA-256 `0733124a4e5376ea8504e4709b77b7d03117f187a1b8b4fd13768a0f4d621139`, 1,631,474 bytes), the extracted text (SHA-256 of its LF form), the edition (`bicc-tonga-2012`), title and language. The PDF itself is not committed: it is a downloaded file, its text and hash make the build reproducible, and Israel keeps the original.
- `tools/hymn-book/corrections.json` lists every reviewed fix of an extraction glitch, by line number, with the exact extracted text, the fix and why; the converter refuses a fix whose line no longer reads as recorded. It also holds explanations for title differences from the book's indexes of more than two letters (none are needed today).
- `tools/hymn-book/convert.mjs` reads the printed layout (running headers and page numbers dropped; the topical, hymn and chorus indexes read; headings by the next expected number of each sequence; verses by their numbers; `Ciindululo:` choruses), cross-checks every title, number and section against the indexes, and refuses the whole book on any problem. `tools/hymn-book/conversion-report.txt` is its committed report: 0 problems, the 26 corrections and 76 notes (12 one- or two-letter title differences kept as printed, 59 hymns whose page header lags their topical-index section, chorus 24's second chorus, hymn 29's chorus first printed after its verse 2, and hymns 25, 29 and 30, whose verse 1 is a single line that verse 2 completes, so the printed book must show whether the "2" stands on the stanza's second line).

### Replacing or correcting the book

1. Extract the new PDF with the exact command above into `tools/hymn-book/manuscript/`, then update `provenance.json` (PDF hash and size, text hash, edition).
2. Run `node tools/hymn-book/convert.mjs --check`. Fix each reported line with a reviewed entry in `corrections.json` (never by editing the extracted text), or explain a larger title difference there.
3. Write the book and the report: `node tools/hymn-book/convert.mjs --report tools/hymn-book/conversion-report.txt`.
4. Run `node --test tools/hymn-book/convert.test.mjs` (it pins the counts and the PDF hash; update those pins deliberately for a new edition) and the Flutter suites. A corrected book reaches phones only with a new app release.

### Local checks

```bash
node --test tools/hymn-book/convert.test.mjs
node tools/hymn-book/convert.mjs --check
```

Run `flutter analyze` and `flutter test` in `packages/client_core`, `packages/design_system`, `apps/mobile` and `apps/staff`. `packages/client_core/test/content/hymn_book_test.dart` checks the shipped book (199 + 67, sections, ids) and that both bundled fonts (Figtree, Outfit) carry every character it uses; the converter writes U+201F (used as an apostrophe in the book) as U+2019 because neither font has it.

### Owner manual check (the ticket's verify)

On a signed-out Android phone in airplane mode, open **Bible & Hymns**, choose **Hymn book**, and:

1. See the sections as group headers in the printed order (Kutalika Mubungano first; the choruses last under Ziindululo).
2. Search by a number (`24`: hymn 24 is listed before chorus 24), by title words and by first-line words, with and without apostrophes: `wang uuteeli` and `wang' uuteeli` both find hymn 62, "Mwaala Wang’ Uuteeli".
3. Open hymn 1 (English title REVIVE THY WORK, O LORD!, Key of F, three verses with the chorus after each), hymn 3 (one stanza, no key), and chorus 24 (a different chorus after verse 2), and compare them with the printed book.
4. Confirm the app's count matches the converter report: 199 hymns and 67 choruses.

Spot-check list for the PDF: hymns 1, 3, 4, 25, 29, 30, 32, 62, 106, 164, 178, 199 and choruses 1, 24, 26, 34, 67. Hymns 25, 29 and 30 need the printed book: the extraction numbers the second line of their first stanza "2", so the app shows a one-line verse 1.

## Story 6.8: favourite hymns and Hymns for this Sunday

Migrations: `supabase/migrations/20261027182223_content_hymn_lists.sql` (the version staging recorded) and its small rows file `supabase/migrations/20261027182300_content_hymn_lists_rows.sql` (the favourites row purge; **the owner applies it by hand on hosted projects**, below). pgTAP: `supabase/tests/content_hymn_lists_test.sql` (145). E2E: `tools/identity-e2e/content-hymn-lists.mjs` (13 checks; run it after the pgTAP suite on a fresh reset; offline tests `content-hymn-lists.test.mjs`). Plan: `_bmad-output/initiative-church-app/epic-public-content-and-giving/story-save-favourite-hymns-and-set-hymns-for-this-sunday-plan.md`. Evidence: `evidence-6.8/`.

The hymn book is built into the apps (story 6.7). The server holds **item numbers only**: an item is named by its id (`hymn-12`, `chorus-3`) together with the book's edition, and every write is checked against `app.content_hymn_editions` (`bicc-tonga-2012`: hymns 1-199, choruses 1-67). A number outside the edition, a title, a bare number or an unknown edition is refused. A corrected book that keeps its numbers needs no server change; a new edition with other counts needs a migration row before its app release.

### Model

- One content kind, `hymn_book` (editor roles `admin`, `media`), plus the Content scope kind **`worship_leader`** (registered with Identity through 2.3), whose one target is the church's single Sunday-list record `app.content_sunday_hymn_lists` (`list_id` `4f8c2d6e-1b3a-4c5d-8e9f-6a7b0c1d2e08`). Holders of that scope edit `hymn_book` beside Admin and Media. Pastors do not (owner decision 2026-10-21: Media and worship leaders; Admin also manages it).
- Three registries so later kinds add rows instead of replacing shared functions: **member commands** (`app.content_member_commands`, `app.content_register_member_command`: any approved member with live access may send them; their handlers check the rest), **kind scopes** (`app.content_kind_scopes`, `app.content_register_kind_scope`) and **replay scopes** (`app.content_replay_scopes`, `app.content_register_replay_scope`: the AD-2 replay recheck of an aggregate that is not a content item). `app.content_editor_capacity`, `app.content_authorize_command` and `app.content_in_scope` were replaced once to read them; kinds without registry rows behave as before. Story 6.11 (RSVP, `20261027140149`) created the member-command registry first; 6.8 keeps it (`create table if not exists`, the same function bodies) and keeps 6.11's RSVP replay branch in `app.content_in_scope`.
- **Favourites** (`app.content_hymn_favourites`): one row per member and item, `saved` or `removed`. Removal is a state change; rows go only in a member deletion. Only the member reads them.
- **Sunday lists** (`app.content_sunday_hymn_revisions`, `app.content_sunday_hymn_items`): each set or clear of one church-time Sunday is an immutable, attributed revision (who saved it, as Admin, Media or worship leader, when, and the request id); a cleared list is a revision with no items; the latest revision is the Sunday's list. The list record's `revision` is the expected revision of both list commands.

### Commands (`api.content_command`, 1.4 envelope)

| Command | Who | Expected | Payload |
|---|---|---|---|
| `content.save_hymn_favourite` | an approved member with live access | `null` | `{edition, item}`; saving a saved item changes nothing |
| `content.remove_hymn_favourite` | the same | `null` | `{edition, item}`; never saved: `not_found` |
| `content.set_sunday_hymns` | Admin, Media, worship leaders | list revision | `{sunday: "YYYY-MM-DD", edition, items: ["hymn-12", ...]}` (1-12 distinct items, in order); the same list again changes nothing |
| `content.clear_sunday_hymns` | the same | list revision | `{sunday}`; nothing set: `sunday: not_set` |

Field codes: `edition` `required`, `invalid`, `unknown_edition`; `item`/`items` `required`, `invalid`, `out_of_range`, `too_many`, `duplicate`; `sunday` `required`, `invalid`, `not_a_sunday`, `past` (before this Sunday), `too_far` (more than 52 weeks ahead). A plain member, a Pastor and a Pending account are refused the list commands (`forbidden`); Pending and held accounts are refused the favourite commands; anon cannot call any (401). A stale list revision answers `conflict` with `current_revision`. A revoked worship leader is refused at once, replays included.

Worship leaders are granted and removed with the 2.3 grant command (`identity.grant_scope` / `identity.revoke_scope`, `{member_id, scope_kind: "worship_leader", scope_id: <list_id>}`), Admin only, never to themselves; any other `scope_id` answers `scope_id: unknown`.

### Reads

| Endpoint | Who | Returns |
|---|---|---|
| `api.content_public_sunday_hymns()` | anyone (`anon`, `authenticated`) | `{sunday, edition, items, publication_revision}`: **this Sunday** in church time (today on a Sunday, else the coming Sunday) and its item ids in order; `items: []` with `edition`/`publication_revision` null when nothing is set or it was cleared. No name, time or capacity. |
| `api.content_my_hymn_favourites()` | the signed-in member (live access; no member parameter) | `{favourites: [{edition, item, saved_at}], truncated}`, newest first, at most 1000 |
| `api.content_staff_sunday_hymns()` | Admin, Media, worship leaders | `{capacity, list_id, revision, this_sunday, editions, sundays: [{sunday, revision_no, edition, items, saved_at, saved_by, saved_capacity}], worship_leaders, members, members_truncated}`: every Sunday from 8 weeks back to 52 ahead that has a list; `worship_leaders` and `members` (approved members with their grant-set revision, at most 500) for an Admin only, `null` for everyone else |

Nobody, staff included, can read another member's favourites.

### Deletion

Two erase parts of Content's one handler: `hymn_favourites` (`app.content_hymn_favourite_erase_part`) deletes the member's favourites through `app.content_hymn_favourite_purge_rows`, and `sunday_hymn_revisions` (`app.content_sunday_hymns_erase_part`) replaces who saved a list with the nil UUID (editors read **Former member**; the lists stay). `check` counts what is left. The purge is a **fail-closed stub** in the main migration; its body is the `_rows` file. Until the owner applies that file on a hosted project, Content's erase step answers `unavailable` for **every** member deletion (all modules wait at `erase_owners`, including the 4.15 and 5.12 deletion reruns) and nothing is erased. Locally `npx supabase db reset` applies both files.

### Clients

- **Mobile (everyone).** A hymn's bar has a **Save** / **Saved** pill (design handoff screen 5). A member saves or removes the item; it shows as saved only when the server confirmed it, and an unknown outcome offers **Check again** (the same request). A guest is asked to sign in, and a signed-in account without member access is told saving is for approved church members; nothing is sent for either. The hymn book (no search) starts with the member's **Saved** group (newest first, at most five, **See all N** opens **Saved hymns** at `/bible/hymns/saved`); a failed read says so and never looks like none saved. Every item in this Sunday's list carries a **Sunday** chip all that week (the choir practises midweek). **Home** shows **Hymns for this Sunday** (a chip per item: number and title from the book; **Hymn book** opens the tab) from **Saturday 00:00 to Sunday 23:59 church time** (the phone's clock, Africa/Lusaka), only when the server's this-Sunday date is that Sunday and it has items; a failed read on those days says so with Try again. Favourites live in memory for the account (AD-13); the book opens them again on each visit, so a change made on another phone shows.
- **Staff web.** **Sunday hymns** (`/content/sunday-hymns`, sidebar group **Content**, last; Admin, Media and worship leaders): the finding line (this Sunday's and next Sunday's lists), the next eight Sundays with their lists, the chosen Sunday's editor (add from the built-in book by number or title, reorder, remove, **Save list**, **Clear this Sunday** with confirmation, who set it and when) and, for an Admin, **Worship leaders** (remove; choose a member and **Make worship leader**). A member made a worship leader sees the entry on their next navigation.

### Local runs

```bash
npx supabase db reset --local && npx supabase test db
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/content-hymn-lists.mjs --evidence _bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.8/content-hymn-lists-e2e.jsonl
node tools/auth-harness/local-phone-auth.mjs off
node --test tools/identity-e2e/content-hymn-lists.test.mjs
```

The E2E uses fictional numbers +44 7700 900641-900648 and removes everything it created (favourites, the run's Sunday revisions, members, grants and receipts). Flutter: `packages/client_core/test/content/hymn_lists_test.dart` (wire, the Sunday window under a test clock, Home chips, the Sunday chip, the Save pill, Saved hymns, the staff editor), plus one test in each app.

### Owner step on staging: the `_rows` file (right after the main migration)

In the staging SQL editor (project `tmurpotfluignacfueki`), paste the whole of `supabase/migrations/20261027182300_content_hymn_lists_rows.sql` and run it, the same way as `20261013220300_duties_department_tracer_rows.sql`. It replaces one stub (`app.content_hymn_favourite_purge_rows(uuid)`) and changes no schema object. Check:

```sql
select pg_get_functiondef('app.content_hymn_favourite_purge_rows(uuid)'::regprocedure)
       like '%delete from app.content_hymn_favourites f where f.member_id = p_member_id%';   -- true
select has_function_privilege('authenticated', 'app.content_hymn_favourite_purge_rows(uuid)', 'EXECUTE');  -- false
```

Until it is applied, every staging member deletion waits at its erase step (`unavailable`), which is safe.

### Owner manual check on staging (the ticket's verify)

Use SYNTHETIC members only; nothing here sends a notification.

1. As an approved SYNTHETIC member signed in on two phones, open **Bible & Hymns > Hymn book**, open hymn 12 and tap **Save**; it reads **Saved**. On the second phone open the hymn book again: hymn 12 is under **Saved**. Remove it there (**Saved** > tap) and reopen the book on the first phone: it is gone.
2. Sign in as another member: the hymn book shows no Saved group for hymn 12. Sign out: tapping **Save** asks you to sign in and sends nothing.
3. On staff web as an Admin, **Content > Sunday hymns > Worship leaders**: make a SYNTHETIC member a worship leader. As that member (staff web), set next Sunday's list (for example hymns 12, 45 and chorus 3) and save. As a Media member, change it and save. As a plain member (and as a Pastor) **Sunday hymns** is not in the sidebar, and `/content/sunday-hymns` says it is not available.
4. On a signed-out phone the hymn book marks those items **Sunday** during that week. On the Saturday before that Sunday (or with the phone's date set to it), Home shows **Hymns for this Sunday** with the chips; on the Friday it does not. (The widget tests prove the Friday/Saturday boundary under a test clock.)
5. After the `_rows` file is applied, the entry 17 suite reruns the favourites privacy and deletion cases on staging.

### Staging (2026-10-27)

Applied verbatim to `tmurpotfluignacfueki`, which records version `20261027182223` (after 6.11's `20261027140149`); the local files carry that version and `20261027182300` for the rows file. After a fresh local reset, 38 of the 39 added or replaced function definitions hash identically to staging; the 39th, `app.content_hymn_favourite_purge_rows`, is still the fail-closed stub on staging until the owner applies the rows file. Boundary, unowned and unpinned counts are 0; the signed-out public read answers `{"sunday": "2026-11-01", "edition": null, "items": [], "publication_revision": null}`. No list or favourite was created, no gate changed and no notification was sent. Evidence: `evidence-6.8/staging-verify.md`.

## Story 6.9: publish and browse sermons with safe notes

Migration: `20261027083618_content_sermons.sql`. It registers `sermon_series` and `sermon`, their ten lifecycle commands, private revision tables, bounded public/staff reads, the `sermon_series_poster` asset purpose, immutable published revisions and registered attribution erasure. It adds no row deletion, policy approval, notification or second file/cache pipeline. Apply the exact reviewed migration to staging only after listing project `tmurpotfluignacfueki`'s history and confirming prerequisite `20261022012809_content_rights_banners.sql`; match the local filename to the version staging records. Compare every added function's normalized definition hash with a fresh local replay, then require zero boundary violations and unowned objects and verify the signed-out reads. Record the actual staging result in entry 9's evidence; the migration filename alone is not deployment evidence.

Staging (2026-10-27): applied verbatim to `tmurpotfluignacfueki`, which records version `20261027083618`; the local file carries that version. Before the apply, a fresh local reset replayed every migration and the full pgTAP suite passed (65 files, 5,243 tests), and the local HTTP runner passed 16/16. After it, all 33 added sermon/series function definitions hash identically to that fresh local replay, the boundary and unowned counts are 0, the kinds, poster purpose, ten commands, two erase parts, RLS and the absence of client table grants are as migrated, no sermon or series exists, and seven signed-out HTTP checks pass (empty catalog, null unknown detail, refused staff reads and command, unreadable tables). Evidence: `evidence-6.9/staging-verify.md` and `staging-public-read-20261027.jsonl`. No content was published, no gate or rights record changed, no notification was sent and production was not touched.

### Editorial workflow

On staff web, **Content > Sermons** is available to Media, Pastor and Admin. The server checks current access for every staff read, upload and command. A sermon draft can be incomplete, including one later received from a teaching duty; the staff catalog includes all normal drafts regardless of their creator or source. Save title, speaker, sermon date, scripture, notes, optional series and optional YouTube ID. Publication requires complete teaching metadata and validates any supplied series/video. An edited draft leaves the last published revision live until its replacement is published. A stale revision is refused and reloads the current item. Withdraw hides an item while retaining its history; archive retires it.

Series have a title, description, poster text alternative and optional poster. Save the series draft before choosing its poster; upload and attach the file through the existing `content-assets` route with purpose `sermon_series_poster` and a verified rights record. Publishing, withdrawal and archive use the existing file sync. The shared **Rights** screen controls display and offline uses separately. Church-owned records still need verification and the requested use cleared; production third-party uses also need the owner's Q5 clearance. Never treat the fact that YouTube accepts an ID as distribution permission.

| Command through `api.content_command` | Expected revision | Payload |
|---|---|---|
| `content.create_sermon_series` | `null` | `{title, description, alt_text}` |
| `content.save_sermon_series` | series revision | `{series_id, title, description, alt_text, poster_asset_id, poster_rights_id}`; null poster/rights clears that part of the draft |
| `content.publish_sermon_series`, `content.withdraw_sermon_series`, `content.archive_sermon_series` | series revision | `{series_id}` |
| `content.create_sermon` | `null` | `{title, speaker, sermon_date, scripture_reference, notes, series_id, youtube_video_id, video_rights_id}` |
| `content.save_sermon` | sermon revision | `{sermon_id, ...the complete draft fields}` |
| `content.publish_sermon`, `content.withdraw_sermon`, `content.archive_sermon` | sermon revision | `{sermon_id}` |

Notes are church-authored restricted Markdown: paragraphs, headings, emphasis and lists, with inline HTTPS links to exact hosts `ebible.org`, `biblegateway.com`, `www.biblegateway.com`, `youtube.com`, `www.youtube.com` and `youtu.be`. HTML, embedded images, reference links, autolinks, unsafe schemes, disguised hosts, user information and unsupported ports are refused on save. The editor keeps the typed input and shows the notes field error. Enter notes as readable text with the formatting help; no JSON entry is needed.

### Public reading, media failures and saved content

`api.content_public_sermons()` is the canonical anonymous catalog `{sermons, series, truncated}`. `api.content_public_sermon(sermon_id)` returns `{sermon}` with null for a private, withdrawn, archived or unknown sermon. The public projection contains the current published teaching metadata, safe notes and public series/poster metadata only; it excludes editor names, identities, draft fields and private provenance. `api.content_staff_sermons()` and `api.content_staff_sermon_series()` are separate protected editor reads. No client role is granted direct access to either revision table.

The fifth mobile tab order is **Home, Bible & Hymns, Sermons, Give, Calendar**. The tab leads with the current series (the series of the newest sermon that belongs to a published series; no card when none does) on the navy card: its public poster, title, sermon count and description, and tapping it opens the Series view. Latest lists every sermon by date; Series and Speaker group the same rows under each series (sermons outside a series last, under "Not in a series") or each speaker. The search icon beside Latest/Series/Speaker opens a search box that matches titles, series and speakers over the canonical catalog. A card shows a thumbnail column only when one of its rows has a series poster or a playable video, and a play mark only on a sermon with one. Detail separates the player from scripture and notes. The mobile-only player uses the pinned `youtube_player_iframe` dependency in privacy-enhanced mode without autoplay. A malformed ID is refused by the server; a removed/private/unreachable video is reported by the player ("This video is unavailable. You can read the notes below."), without replacing the teaching page. A sermon with no playable video (none recorded, or its rights withdrawn) says "No video is available for this sermon", and an offline or stale page says "Video needs a connection". The server does not poll YouTube. Missing or withdrawn video display clearance removes the playable ID while leaving church-authored notes readable. Audio playback is entry 10 and duty-to-Media draft creation is entry 18.

Withdrawing a series removes its title and poster from the catalog and from every public sermon projection; its still-published sermons remain readable without that series metadata. Run the existing file sync to remove the withdrawn poster's public object. Do not copy private series titles into a replacement public field.

Mobile extends the existing single public cache with the canonical sermon catalog, its publication/rights revisions and saved time. Only the current series keeps its poster on the phone (owner decision 2026-10-27, to save members' data); other series show their posters online only, and their saved poster files are removed on the next save. The catalog is saved as soon as it arrives, with the posters already on the phone; a missing offline-cleared current-series poster is then fetched outside the shared cache queue, three at a time, and saved with the same catalog unless a newer one was saved meanwhile, so a slow poster never delays the list or another tab's saved copy. Search/filter results never replace that canonical snapshot. Only eligible public teaching and offline-cleared posters may be saved; no YouTube media or uncleared thumbnails are downloaded. A successful refresh replaces the saved public set and evicts withdrawn rows/files. Failed refreshes remain visibly failed or stale and preserve the prior committed snapshot; an uncached network failure never appears as an empty catalog. Staff reads, private drafts and editor identities have no persistence path. An already saved offline copy cannot be remotely erased.

Account deletion uses Content's registered erase/check parts for both new revision tables. It anonymizes all four saved/published member/account attribution columns as well as the existing shared item attribution; the staff read reports **Former member**. Content and revision rows remain, so no owner `_rows` file is needed.

On staff web, both lists are grouped into **Waiting to publish**, **Published** and **Withdrawn**, with archived items behind a toggle. Each row carries one mark: Draft, Changes not published, Published, Published, video hidden (its live video's rights no longer clear display), Published, poster waiting or Published, poster not shown, Withdrawn or Archived. Withdraw and Archive ask for confirmation, naming the item. Opening **Sermon series** syncs public poster files, as Banners does.

### Verification and support

Run the full SQL suite on a fresh local reset before the live runner. The runner is guarded to the exact local origin, uses only the fictional phones `+44 7700 900651` through `+44 7700 900656` (the block given to entry 9; the entry's pgTAP file and story 4.8's reminders pgTAP also insert numbers in this range, inside transactions that roll back, so an interrupted runner whose accounts were not removed needs a reset before the next suite run), and uses only SYNTHETIC names, church-authored notes, generated artwork and a fictional video ID. It does not contact YouTube, approve a policy gate or enqueue a notification. Its evidence contains statuses, counts and booleans, not credentials or phone numbers. Published content fixtures remain immutable in the disposable local database; synthetic Auth identities are erased/removed, and a second run requires another reset.

```text
node --test tools/identity-e2e/content-sermons.test.mjs
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/content-sermons.mjs --evidence _bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.9/content-sermons-e2e.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

The runner starts `supabase functions serve` only if `content-assets` is unavailable and stops only the process it started. Its `finally` restores the local phone harness to off. If cleanup or restoration fails, run the final `off` command before continuing. Pure Node helper tests validate the runner's fixtures and exact projection guards; they do not exercise Flutter persistence or physical playback. The entry's Flutter/controller/cache tests and staging release builds provide their own evidence. A broken-link report is handled by an editor checking the published YouTube ID in a browser, correcting or removing it in a new draft, and publishing the replacement; never hide the notes just because a recording is unavailable.

### Owner manual check on staging

1. Confirm entry 9's recorded staging version and definition hashes, zero module guard counts and signed-out public responses. Use SYNTHETIC content and no notification; do not approve a policy gate or access production.
2. With Media, Pastor and Admin accounts, save and publish two synthetic series and sermons. Verify an ordinary member and a Pending account cannot open editor reads or run any of the ten commands. Confirm normal drafts created by another editor are visible to Media.
3. On a signed-out phone, open Sermons, use Latest/Series/Speaker and title search, and open detail through its back bar. Check the poster text alternative, title, speaker/date, scripture and safe notes. Save a revision without publishing; the phone must still show the previous published teaching.
4. Enter HTML, image Markdown, a reference/autolink and a disguised/unallowlisted link. Saving must show a field error and retain the typed input; none of that input may become public.
5. On physical Android and iOS devices in the entry 15 pilot, use an owner-cleared playable video, then a private/removed or unreachable one. Verify no autoplay, the unavailable message, readable scripture/notes and correct player disposal when navigating away. API and widget tests do not prove device playback.
6. Save an eligible catalog, relaunch in airplane mode and verify its saved-time label and local title/series/speaker filtering. Start without a saved catalog to check the honest failure state. Reconnect after withdrawing one sermon; successful refresh must evict it. Confirm an uncleared poster/video is not downloaded.
7. Withdraw a published series while leaving its sermon published: the phone must keep the teaching and remove that series's title/poster. Withdraw the video's rights: the playable ID must disappear and the notes must stay readable.
8. Record redacted pilot results and any device-only failures for entry 15. Q5 source/use approval, physical playback and offline checks remain owner responsibilities until actually witnessed; this checklist records no approval or completion by itself.

## Story 6.10: play a sermon's Facebook video or livestream inside the app

Migration: `20261027191003_content_sermon_facebook_video.sql`. It adds `facebook_video_url` to sermon revisions beside the YouTube id (a revision has at most one video source, checked by storage too), the validator `app.content_sermon_facebook_url`, and in-place replacements of 6.9's own sermon create, save, publish, revision guard, public sermon JSON and staff revision JSON. No row deletion, destructive statement, policy approval, notification or request to Facebook.

Staging (2026-10-27): applied verbatim; staging records `20261027191003` and the local file carries that version. Before the apply, the full pgTAP suite passed on a fresh local reset (66 files, 5,325 tests), then the local HTTP runner passed 9/9. After it, all 7 added or replaced function hashes match the fresh local replay, boundary and unowned counts are 0, the validator is closed to client roles, no sermon exists, and the signed-out catalog and detail answer empty and null. Evidence: `evidence-6.10/staging-verify.md` and `evidence-6.10/content-sermon-facebook-e2e.jsonl`.

### What editors paste

In the sermon editor on staff web, **Facebook video or live link (optional)** sits under the YouTube field. A sermon has one video: filling both is refused. Accepted (any of facebook.com, www., m. or web.facebook.com, https only; tracking after `?` or `#` is dropped) and stored as:

- `facebook.com/<page>/videos/<number>` -> `https://www.facebook.com/<page>/videos/<number>/`
- `facebook.com/watch?v=<number>` or `facebook.com/watch/live/?v=<number>` -> `https://www.facebook.com/watch/?v=<number>`
- `fb.watch/<code>` -> `https://fb.watch/<code>/`

Refused: another host (`not_facebook`), http, a login or port in the link, share (`/share/v/...`), reel or post links, or a repeated `v` (`invalid`), and a page's Live address `facebook.com/<page>/live` (`not_embeddable`): Facebook's embedded player plays one video, not a page's broadcasts. During a broadcast, open it on Facebook and paste its own link (`.../videos/<number>`); the same link plays the recording afterwards. The video uses the sermon's **Video rights record**, which must clear display before the sermon can publish, exactly as YouTube. Withdrawn clearance hides the link and keeps the notes; the staff row then says **Published, video hidden**.

### On the phone

The sermon detail plays the link in Facebook's embedded video player (`https://www.facebook.com/plugins/video.php`) inside a web view (`webview_flutter` 4.14.1, pinned with its Android 4.14.1 and WebKit 3.27.2 implementations). Nothing plays until the viewer taps play; the web view never leaves the player page, so it never shows a Facebook sign-in. A removed, private or sign-in-only video, a network error, or a player that has not loaded within 25 seconds shows "This video is unavailable. You can read the notes below." Offline or stale pages say "Video needs a connection"; the saved catalog never holds a Facebook link. A playable Facebook sermon carries the same play mark in the list as a YouTube one. Facebook's embed rules can change; if public videos stop playing, the unavailable state shows and the notes stay readable.

### Local checks

Run the full SQL suite on a fresh reset first (`supabase/tests/content_sermon_facebook_test.sql` uses fictional phones +44 7700 900111-900114 inside a rolled-back transaction). The runner uses +44 7700 900115-900118, SYNTHETIC names and invented Facebook page names and ids; it contacts neither Facebook nor YouTube, and a second run needs another reset.

```text
node --test tools/identity-e2e/content-sermon-facebook.test.mjs
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/content-sermon-facebook.mjs --evidence _bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.10/content-sermon-facebook-e2e.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

### Owner manual check on staging

1. Install a mobile build that contains entry 10 (a 6.9 build cannot read the new sermon projection). Use SYNTHETIC sermons and a church-owned SYNTHETIC rights record; send no notification and approve no gate.
2. On staff web, save one SYNTHETIC sermon with a public Facebook video link and one with a Facebook live link (`watch/live/?v=...` or the broadcast's `/videos/...` link). Each saved draft shows the stored form. Paste a YouTube link, an `example.com` link, a malformed Facebook link and a page's `/live` address into the Facebook field: each is refused with its own message and your input stays.
3. Attach the verified video rights record and publish both.
4. On an Android emulator (and later the entry 15 physical devices), signed out: open Sermons, see the play mark on both rows, open one and tap play inside the app. Confirm it did not start by itself and no Facebook sign-in appeared.
5. Change one sermon to a removed or private Facebook video (or make the test video private on Facebook) and publish: the detail must show the unavailable message with the scripture and notes readable.
6. Withdraw the rights record: the link disappears and the notes remain. Switch the phone to airplane mode: "Video needs a connection", notes readable.
7. Record the results for entry 15. iOS playback waits for the owner's device in entry 15.

## Story 6.12: duties linked to published events

Migration: `supabase/migrations/20261027192013_content_event_duty_links.sql` (no `_rows` file). pgTAP: `supabase/tests/content_event_duty_links_test.sql`. E2E: `tools/identity-e2e/content-event-duty-links.mjs` (offline tests `content-event-duty-links.test.mjs`, fictional block +44 7700 900291-900297). Plan: `_bmad-output/initiative-church-app/epic-public-content-and-giving/story-link-duties-to-published-events-and-flag-their-review-when-a-plan.md`.

### Model

- Content registers its events as the 1.5 source type `content_event` (check hook `app.content_event_source_check`: current while published at the live revision number; `revision` null while the event is not public) and as the Duties `event` link source.
- A department duty names an event through the Duties `event_ref`. Duties refuses anything but a published event (`validation_failed {"event_ref": "not_published"}`), checking only through `app.contract_check_source` (a Duties contract change, recorded in [contracts-and-owner-seams.md](contracts-and-owner-seams.md), Duties owner operations point 10). A stored link is kept when the event is later withdrawn; clearing a link is always allowed.
- Inside Content's own command, after the event's item row is locked: `content.publish_event` flags the linked duties when the revision going live changes the time (start or end) or the place of the previous live revision (`time`, `place`; a title or description change flags nothing); `content.withdraw_event` and `content.archive_event` of a published event flag `cancelled`. The flag is the 4.11 `app.duties_owner_flag_review` with its 4.16 notice: one "Duty needs review" notice per department and change to each reachable leader and deputy other than the editor. No duty is republished, nothing of the duty changes and no answer is reset; the leader reviews it on the board.
- The public event reads are unchanged: they never name a duty, rota, department or review.

### Reads

- `api.content_staff_event_duty_links(event_id)` (event editors: Media, Pastor, Admin; others 403 `not_granted`; anon refused): `{event_id, linked_duties, reviews_open, truncated}`, counts only (`linked_duties`: published department duties that have not started and name the event; null for an unknown event).
- My duties rows carry `event_ref`; the rota and board already did.

### Clients

- Staff web, Duties > Rota: a date shows "Event: <title> · <date>" (or that it is no longer public); Change has a **Linked event (optional)** picker of published events (the public calendar read), sent as `event_ref` for this date or this and later dates. A link is a reference: nobody is asked again.
- Staff web, Content > Events: an opened published or withdrawn event shows how many duties are linked and how many reviews are open, before Edit, Publish, Withdraw or Archive; the Withdraw and Archive questions repeat it. A failed read says so.
- Mobile, duty detail: an **Event** row with the event's title, date and place, opening the event; an event no longer public says so.

### Local runs

```text
npx supabase db reset --local
npx supabase test db
node --test tools/identity-e2e/content-event-duty-links.test.mjs
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/content-event-duty-links.mjs --evidence _bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.12/local-e2e.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

The E2E queues review notices but never runs the worker, and removes everything it created.

### Owner manual check on staging (the ticket's verify)

Every event change below sends real review notices to the linked departments' leaders and deputies. Do it only with SYNTHETIC departments whose leaders and deputies are test phones, and only when you choose to (the build sent none on staging).

1. As an Admin, give a SYNTHETIC member the leader scope of a `SYNTHETIC Preaching Rota` department and publish a duty there; as Media, publish two SYNTHETIC events and leave a third as a draft.
2. On staff web, Duties > Rota, open the duty's date, Change, and pick the first event in **Linked event**: it saves with "Only linked event change: answers stand.". Try the draft event's id through the API (`duties.revise_duty {event_ref}`): refused `not_published`. Link a second duty to the second event.
3. On staff web, Content > Events, open the first event: "1 duty is linked to this event..." shows before you edit. Edit its start time and publish: the department's leader and deputy each get one "Duty needs review" notice; the duty shows **Needs review** (time) on the board; the member's answer is unchanged.
4. Withdraw the second event: its duty is flagged cancelled, with one notice per leader or deputy; linking a duty to it now is refused.
5. Signed out, open the Calendar and the first event: no duty, rota or department is shown. On the member's phone, the duty detail shows the event and opens it.
6. The leader marks both reviews done on the board.

### Staging (2026-10-27)

Applied as `20261027192013`; all 12 function hashes match the fresh local reset; boundary/unowned 0; signed-out reads checked. No duty was linked and no notification was sent. Evidence: `evidence-6.12/staging-verify.md`.

## Story 6.18: sermon drafts from preaching duties

Migration: `supabase/migrations/20261028071717_content_sermon_drafts_from_duties.sql` (no `_rows` file). pgTAP: `supabase/tests/content_sermon_duty_drafts_test.sql`. E2E: `tools/identity-e2e/content-sermon-duty-drafts.mjs` (offline tests `content-sermon-duty-drafts.test.mjs`, fictional block +44 7700 900116-900121; the pgTAP file uses 900112-900117 inside its rolled-back transaction). Plan: `_bmad-output/initiative-church-app/epic-public-content-and-giving/story-send-a-preaching-duty-s-topic-and-scripture-to-media-as-a-se-plan.md`.

### Model

- `content.draft_sermon_from_duty {occurrence_id}` (expected_revision null) is a Content member command. Its handler reads the duty only through the 4.11 owner read `app.duties_owner_topic`, which answers the duty's current assignee (pending or accepted) or its managers (the department's leader or deputy, or an Admin); anyone else gets `not_found`. A duty with neither topic nor scripture is refused `{"occurrence_id": "no_topic"}`; a cell programme part `{"occurrence_id": "cell_part"}`.
- It creates one private sermon draft per duty occurrence (`app.content_sermon_duty_drafts`, race-safe): title from the topic (the scripture when there is no topic), scripture reference from the scripture, date the duty's start date in church time; no speaker, notes, series or video. A second send by anyone allowed answers the same draft (`created: false`) and changes nothing, even after Media edited or published it.
- The draft is an ordinary 6.9 sermon: only Media, Pastor and Admin see it (Content > Sermons, **Waiting to publish**, marked "From a duty: <duty>, <date> (sent <date>)"), never who sent it. Publishing needs a speaker, so an unfinished draft cannot go public; nothing publishes automatically and no notice is sent.
- Audit: the draft's creation is attributed with the capacity `duty_assignee` or `duty_manager`. Deletion: erase part `sermon_duty_drafts` anonymises the sender.

### Reads

- `api.content_duty_sermon_draft(occurrence_id)` (the duty's assignee or managers; others 403 `not_granted`, Q4 closed 403 `unavailable`, anon refused): `{occurrence_id, can_send, draft: null | {sent_at, published}}`.
- `api.content_staff_sermons` rows carry `from_duty: null | {duty_name, duty_starts_at, sent_at}`.

### Clients

- Mobile, duty detail: when the duty has a topic or scripture (not a cell part, not declined), a **Sermon** section with **Send to Media**, then "Sent to Media on <date>. Media adds the speaker and publishes it." (or "Media has published the sermon."). An unconfirmed send offers **Check again** with the same request; a failed read says so with **Try again**; a refused read shows nothing.
- Staff web, Duties > Rota: the same section on a published date with a topic or scripture, for its managers.
- Staff web, Content > Sermons: the "From a duty" line on the row and at the top of the editor.

### Local runs

```text
npx supabase db reset --local
npx supabase test db
node --test tools/identity-e2e/content-sermon-duty-drafts.test.mjs
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/content-sermon-duty-drafts.mjs --evidence _bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.18/local-e2e.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

The E2E removes everything it created; it never runs the notification worker (publishing the duty queues a `duty_assigned` notice locally, which it removes).

### Owner manual check on staging (the ticket's verify)

Publishing a duty sends its member a real "duty assigned" notice. Use only SYNTHETIC members whose phones are test phones, and only when you choose to (the build sent none on staging).

1. As an Admin, make a SYNTHETIC member leader of a `SYNTHETIC Preaching Rota` department, add a second SYNTHETIC member, and publish a duty for that member; Change the date to add a topic and scripture.
2. On the member's phone, open the duty: **Sermon** shows **Send to Media**. Send it: "Sent. Media will prepare the sermon." Send again through the API (`content.draft_sermon_from_duty`): the same `sermon_id` with `created: false`.
3. As a member without the duty, and as a leader of another department, call the same command and the status read: `not_found` and 403.
4. Signed out, and as a member, the sermon list and `content_public_sermon(<sermon_id>)` show nothing.
5. As Media, on staff web Content > Sermons, the draft is under **Waiting to publish** with "From a duty". Publish is refused until a speaker is added; add it, save and publish: only now is it public, and the member's duty says "Media has published the sermon.".

### Staging (2026-10-28)

Applied as `20261028071717` (after entry 19's `20261028064546`); all 8 added or replaced function hashes match the fresh local reset; boundary/unowned 0; signed-out reads checked. No duty was published, no draft made and no notification sent. Evidence: `evidence-6.18/staging-verify.md`.

