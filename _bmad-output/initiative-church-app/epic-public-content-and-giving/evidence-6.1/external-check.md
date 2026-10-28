# Story 6.1 external check (independent reviewer, 2026-10-21)

The entry's `external_check`: an independent reviewer repeats the anonymous, Pending and
plain-member read and command matrix (drafts, withdrawn items, editor identity, direct table
access). A separate reviewer agent, with no part in the build, ran it against the local stack whose
function bodies matched the worktree, before the migration went to staging.

**Verdict: PASS.**

- Catalog: anon executes only `app`/`api` `content_public_event(s)`; authenticated adds only
  `content_command` and `content_staff_events`; service_role and PUBLIC none. No client role holds
  any table, column or sequence privilege on the six `app.content_*` tables.
- Rolled-back SQL matrix with anon, a Pending account (auth user and session, no member link), a
  plain member, Media and Admin, and events in every state (draft, published with a secret open
  draft, withdrawn with a draft, archived, archived draft, ended): all three non-editors read the
  identical list holding only the live revision with exactly the eight public keys and no draft
  text, editor id or name; every draft, withdrawn and archived id answered `{"event": null}`; all
  30 editor commands from Pending and member answered `forbidden` with no row, audit or receipt
  written; the editors' read gave anon `42501`, Pending `PT403 not_linked`, member `not_granted`;
  direct table DML, `nextval` and direct calls to handlers, helpers, the hook, the registries and
  the authorizer all answered `42501`; replays after the role was revoked or under a hold answered
  `forbidden`; publish/save cycles never changed an earlier published revision; erase took the
  count to 0 and the editors' read showed `Former member`.
- HTTP with the publishable key only: list and detail showed only the live projection; crafted
  `event_id` values got plain errors; `Accept-Profile: app` 406; commands and the editors' read 401.

Findings and what was done with them are in the plan's Review Triage Log. The one data-safety
finding (whitespace-only text accepted, which would have broken every client's list) was fixed in
the migration before staging, with pgTAP cases.
