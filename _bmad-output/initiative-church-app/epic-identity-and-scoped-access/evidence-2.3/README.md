# Evidence: story 2.3 — grant scoped roles with audited, immediate effect

**Run:** 2026-10-06, on the LOCAL stack only (Supabase CLI 2.119.0), after `npx supabase db reset` with all migrations up to `20261006235500_identity_grants.sql`.

**Data:** every record is SYNTHETIC. Numbers come only from `+1 202 555 0131–0158` and emails only from `@example.test`. Each run deleted every user, link, member, grant, audit row and fixture target it created. No hosted project was changed.

## Results

| File | What it shows | Result |
|---|---|---|
| `local-pgtap.txt` | `npm run db:test`, including `identity_grants_test.sql` (94 assertions) | 608/608 pass |
| `local-api-smoke.txt` | `npm run db:smoke`, including the new Data API checks: signed-out callers get no EXECUTE on the four new functions; an unlinked account reads no access and gets a `forbidden` envelope | all ok |
| `local-grants-e2e.jsonl` | `node tools/identity-e2e/grants.mjs`: real GoTrue sessions and the real Data API | 18/18 pass |
| `local-client-adapter-check.txt` | `tools/identity-e2e/live-grants-check.sh`: the real `SupabaseCommandGateway` and `SupabaseGrantsRepository` | L1–L8 pass |

The E2E steps in `local-grants-e2e.jsonl` cover:

- **G02** Operator bootstrap, audited with the operator's name.
- **G10–G13** An Admin grants Pastor to a member who is already signed in twice, as a "mobile" session and a second "browser tab". Both sessions show Pastor on their very next call, using the same access tokens and with no sign-in again.
- **G14** The audit row is content-free and attributed: actor member, acting account and `request_id`.
- **G15** A stale tab gets `conflict` with `current_revision`.
- **G16** A replay returns the stored result; a changed payload under the same `request_id` gets `conflict`.
- **G17** A revocation applies to both open sessions at their next call.
- **G18** A removed Admin's still-open tab is refused on both the read and the command.
- **G19** The last Admin cannot be removed.
- **G20** A combined Admin + Pastor + Media member and an Admin-only member both get 403 on the care and finance fixture surfaces.
- **G21** A scope grants exactly its target, and its revocation takes effect at the next call.
- **G22** An Admin on a magic-link (otp AMR) session gets `unauthenticated`.
- **G23** Two Admins removing each other at the same moment: one succeeds, the other gets `forbidden`, there is no deadlock, and one usable Admin remains.
- **G24** Every revocation is audited.

The pgTAP file `identity_grants_test.sql` also covers:

- privileges;
- a content-free audit schema;
- clean registry guards;
- church settings: unset in an unmarked (production) database, the fixture honoured only in local;
- operator-only approval;
- bootstrap refusals, and the recovery bootstrap when every Admin is held;
- the helpers composing the predicate (an OTP session never passes);
- validation, `not_found` and `expected_revision` refusals;
- the `lead_pastor` setting gate;
- registration guards;
- the 1.4 fixture path kept for commands outside a registered namespace.

Client tests:

| Package | Tests | What the new tests cover |
|---|---|---|
| `client_core` | 154 | `grants_test.dart`: strict wire mapping, denial mapping, the access controller ending an untrusted session, a fresh read on every navigation, and the Admin screen's envelope, conflict reload, last-Admin notice, removed-Admin stale tab and unknown-outcome check-again |
| `apps/staff` | 16 | The sidebar gains and loses **Roles & access** at the next navigation |
| `apps/mobile` | 17 | An already signed-in session shows a role granted and then revoked elsewhere, after navigation or resume, with no sign-out |

`flutter analyze` is clean in all three packages, and the staff web release build succeeds. `ci:migrations --base origin/main` reports the migrations ordered and non-destructive. `ci:secrets` and `scan-evidence` on this folder are clean.

## Not shown here

These need hosted access or the owner:

- **Staging apply.** The parent session applies `20261006235500_identity_grants.sql` to `bic-kafue-platform-test` after review. It needs the 2.1 and 2.2 migrations, which are already on staging.
- **The device demonstration of the ticket's verify line.** Grant and revoke on the staff web build against staging, and watch an already signed-in Android session and an open browser tab change at the next request. Steps:
  1. Seed two synthetic links as the restricted operator.
  2. Run `select app.identity_bootstrap_admin('<admin member_id>', 'israel');` on staging.
  3. Sign in to staff web as that Admin, and sign the member in on the phone.
  4. Grant Pastor under **Roles & access**. On the phone, switch tab or resume the app, and **Access** lists Pastor.
  5. Remove it, and the phone's next read shows it is gone.
  6. Remove your own Admin while you are the only Admin. The refusal message appears.
- **Q-value gates.** These stay unset in production until the owner decides:
  - The `lead_pastor_designation` setting (Q4).
  - The `operational_contact` setting (Q1).
  - The first real Admin (entry 14).

  Record each approval with `app.identity_approve_church_setting(...)` or `app.identity_bootstrap_admin(...)` as the restricted operator.

## Review fixes (2026-10-06)

The review found the following problems, and each one is fixed:

- **Separation of duty.** An Admin can no longer grant itself a role or scope (`forbidden`, `{"member_id": "unsupported"}`), and no audit row is written.
- **Lead pastor.** No Admin command can grant `lead_pastor`. Only the restricted operator assigns it, with `app.identity_designate_lead_pastor(member_id, operator)` behind the Q4 setting or fixture, and the assignment is audited and journalled.
- **Usable Admin.** The definition now uses the predicate's own non-session conditions. Those conditions are factored into `app.identity_account_standing` and `app.identity_link_dormancy`, and the predicate is rebuilt from them with the same outcomes and order. The 2.1 and 2.2 pgTAP pass unchanged.
- **Comment on concurrent holds.** It is corrected: a hold or link change made concurrently can still leave zero usable Admins, and the bootstrap is the way out.
- **Operator journal.** The bootstrap, the church-setting approval and the lead-pastor designation are journalled in `app.ops_operator_actions`. The 1.9 table was retired by rename and recreated with a wider action list, because widening its CHECK would need a DROP.
- **Sequences.** All privileges on `identity_access_audit_event_id_seq` and the journal sequences are revoked from client roles, and the pgTAP privilege check now covers sequences.
- **Real-format Zambian numbers.** They are removed from the branch: the grants test, the 1.5 contract fixtures (`member_ref`), and the 1.2 harness SQL, scripts and tests now use fictional values.
- **Client denial hook.** Every protected denial now goes through `noteProtectedDenial`: grant commands, roster reads, fixture commands and the member summary. Each one re-reads access.
- **Navigation refresh.** `AccessRefresher` always refreshes. The controller merges overlapping reads (a request made during a read in flight is followed by one more read), and that pending re-read is dropped on every terminal path, including an untrusted answer.
- **Failed roster reload.** It drops the members and their buttons.

Tests run for these fixes:

| Check | Result |
|---|---|
| pgTAP `identity_grants_test.sql` | 113 pass (was 94); adds self-grant refusals, lead-pastor designation, dormant/banned Admins for both the last-Admin refusal and the bootstrap, journal rows and sequence privileges |
| `identity_live_access`, `identity_session_trust`, `system_access`, `cross_epic_contracts`, `command_foundation` | pass (545 total in that run) |
| client_core | 161 pass (adds coalescing, untrusted dropping a pending re-read, the denial hook from fixture and summary, failed reload, self-grant) |
| mobile, staff | 17 and 16 pass |
| contracts | TS 226 and Dart 243 pass |
| `ci:migrations` | ordered and non-destructive |

`local-pgtap.txt`, `local-api-smoke.txt` and `local-grants-e2e.jsonl` above are from the run before these fixes. The full re-run is done by the parent.
