# Evidence: story 2.5 — review applications and link existing or accountless members

**Run:** 2026-10-07, on the LOCAL stack only (Supabase CLI 2.119.0), after `npx supabase db reset` with every migration up to `20261007131600_membership_review_reclaim_sessions.sql`. `local-pgtap.txt` and `local-review-e2e.jsonl` were re-run after the review fixes (below); the smoke and adapter files are from the first run (the fixes did not touch what they exercise). Phone sign-up used the local-only phone switch (`tools/auth-harness/local-phone-auth.mjs on`/`off`): no SMS provider, hook, test OTP or SMS MFA; the E2E confirms `sms_provider` is empty. The switch was turned off afterwards.

**Data:** every record is SYNTHETIC.
- Phone numbers: `+1 202 555 0160–0179` (pgTAP), `+1 202 555 0188–0199` (E2E and adapters). pgTAP also uses `+999…`, an unassigned ITU code, only to prove the fictional-range fence.
- Names start with `SYNTHETIC `; no applicant email was collected.
- Each run removed every user, application, member, link, grant, audit row and receipt it created (`users_left: 0`). The Admin bootstrap leaves append-only operator-journal rows, as 2.3's E2E does.
- No hosted project was changed.

## Results

| File | What it shows | Result |
|---|---|---|
| `local-pgtap.txt` | `npm run db:test` (`supabase test db`): the whole suite, including the new `membership_review_test.sql` (107) and the updated `command_foundation_test.sql` allowlist | 831/831 pass |
| `local-api-smoke.txt` | `npm run db:smoke` with the CLI's default config (phone off), including the new Data API checks | all ok (95) |
| `local-review-e2e.jsonl` | `node tools/identity-e2e/review.mjs`: real GoTrue phone sign-up and the real Data API | 18/18 pass |
| `local-client-adapter-check.txt` | `tools/identity-e2e/live-review-check.sh`: the real Dart adapters (`SupabaseAccountAuthGateway`, `SupabaseReviewRepository`, `SupabaseCommandGateway`, `SupabaseMembershipRepository`, `SupabaseMemberAccessRepository`) | L1–L7 pass |

### The ticket's `verify`, step by step

| Verify clause | Evidence |
|---|---|
| **Approve** one applicant | E2E R10–R15: the applicant applies by phone with no email; an Admin signed in by phone approves after an identity check; the session the applicant applied with is now `401 untrusted_session` (no session from before approval passes); a fresh sign-in reaches the new member; the applicant reads `approved`; the approval is audited with codes only. pgTAP: approval binding (approved phone, binding history `1:application_approved`, provenance, trust epoch), stale revision, decided twice. |
| **Link** a second applicant to an **existing** synthetic member | E2E R20–R22: a member whose old account was unlinked (`account_lost`) is linked to a new applicant's account; the fresh session reaches the **same member id** with **no roles** (the unlink ended the member's `lead_pastor` grant, audited as `role_revoked`), there is still one person with that name, and the old account gets `403 not_linked`. pgTAP: already-linked member (`conflict member_id linked`), held member, unknown member, own member refused. |
| Create an **accountless** member and later **link** a new account to it | E2E R30–R33: Admin records a member with no login (consent `leader_assisted`, a relative's labelled contact number); later the person creates an account, applies and is linked: same member id, contact route and provenance kept. Adapters L4–L7 repeat it through the real Dart adapters. pgTAP: provenance, labelled routes, the consent and label rules, replay. |
| Through the API the member **ID and history are unchanged** | E2E R22 (same id, grants kept, no duplicate person), R33 (same id, contact route and provenance kept); pgTAP "the member keeps its id, name and record", "provenance and contact routes are preserved", "no duplicate person was created". |
| A matching **phone or name never links** automatically | E2E R21/R31: the queue shows Admin a candidate with `same_name` / `contact_route_phone`, and nothing is linked until the Admin chooses; the applicant's own view has no candidates or member ids. pgTAP: the applicant with the same name and the member's contact number stays `not_linked`, with no link created. |
| A **shared contact number gives no access** | E2E R31: the relative whose number is the member's contact route signs up with it and the same name: `403 not_linked`, no link. Then the Admin rejects that request (`contact_church_office`) and re-applying at once is `rate_limited` (R32). |
| On **staff web** | The Members & applications screen is widget-tested in `packages/client_core/test/identity/membership_review_test.dart` (approve, link a candidate, ask for details, reject, unknown outcome resent under the same request id, add a record, unlink, reclaim, sign-out drops the queue) and in the staff shell (`apps/staff/test/staff_app_test.dart` "story 2.5": the entry follows the Admin grant). Staff web was not driven in a browser here; the real adapters were exercised live (adapter check). |

### Also covered

- **Ask for details** (E2E R40): Admin asks for `full_name`; the applicant sees it, corrects that one field, and is approved. This found and fixed a 2.4 bug: a correction carrying only one field failed as `unavailable` (sqlstate 55000, an unassigned PL/pgSQL record read inside an `AND`). `identity_correct_application` is replaced in the 2.5 migration with the same behaviour.
- **Reclaim** (E2E R50–R51): the owner's sign-up with a number someone else registered first is refused (`422`); a number held by a linked account is refused (`conflict`); after an identity check the Admin reclaims it: the holder's request is withdrawn, its old session is `401`, it can no longer sign in, and the owner then signs up with the number and is approved. pgTAP adds: not found, own number, the holder's Auth row kept (phone cleared, banned), the case recorded.
- **Non-Admins** (E2E R11, R14; pgTAP; smoke): applicants and members cannot read the queue or member search or send review commands; an Admin's OTP session is unauthenticated; signed-out callers get 401.
- **Content-free audit** (E2E R60; pgTAP): no audit row contains any phone, name or contact label of the run; the audit table has only id, code and revision columns.

## Review fixes (2026-10-07, coordinator review)

| Finding | Fix | Covered by |
|---|---|---|
| Linking to an existing member handed the account that member's roles and scopes | Unlink ends every active grant through the 2.3 end-grant path (`role_revoked`/`scope_revoked` with the acting Admin, last-usable-Admin refusal kept); link-existing refuses a member with any active grant (`member_id: has_grants`) | pgTAP (grants 0 after unlink, two audit rows by Admin B, `has_grants`); E2E R22 (no roles after relink) |
| Reclaim only banned the holder | The holder's `auth.sessions` and `auth.refresh_tokens` are deleted, in the separate follow-up migration `20261007131600_membership_review_reclaim_sessions.sql` (the main migration has no row deletion) | pgTAP (sessions + refresh tokens = 0) |
| Reclaim had no personal-data gate or fictional-number fence | `identity_applications_open()` required; while Q4 is unapproved only fictional numbers | pgTAP (`out_of_range`, gate closed → `unavailable`) |
| No undo; phone matched only without `+` | Operator procedure `app.identity_undo_phone_reclaim(reclaim_id, operator)` (audited as `phone_reclaim_undone`); reclaim matches both forms | pgTAP (`+` form released, non-operator refused, undo restores and unbans, second undo and number-in-use refused) |
| Approve ignored holds on members the account was linked to before | `forbidden {"application_id": "not_applicant"}` (2.4 rule) | pgTAP |
| Email refusal unexplained to the applicant | Header fixed; new detail code `recovery_email` ("confirm the email on your account or remove it") | pgTAP; widget tests |
| `last_admin` shown as "no longer Admin" | Own notice, no access re-read | widget test |
| `prior_not_approved` counted only rejections | Counts rejected and withdrawn; trigger documented as covering every insert path | migration header |

## Client checks

- **Flutter** (`flutter analyze` and `flutter test`):
  - `packages/client_core`: 200 tests (18 new in `membership_review_test.dart`), analyze clean, `dart format` clean.
  - `apps/mobile`: 19 tests (new "story 2.5" shell test: the applicant sees the decision and no staff data), analyze clean.
  - `apps/staff`: 17 tests (new "story 2.5" sidebar/queue test), analyze clean; `flutter build web` succeeds.
- **Repository checks:**
  - `ci:migrations --base ccr-93e730dd-89lbvg`: 14 migrations, ordered and non-destructive.
  - `ci:secrets` clean; `scan-evidence` clean for this folder and `tools/identity-e2e`; node tool tests 41/41.
- **Regressions** with the phone switch on, after the 2.5 migration: `tools/identity-e2e/run.mjs` 30/30 (2.1/2.2), `grants.mjs` 18/18 (2.3, through the replaced authorizer), `apply.mjs` 27/27 (2.4).

## Not done here (owner or parent)

- **Staging apply** of `20261007063340_membership_review.sql` to `bic-kafue-platform-test`, then a hosted repeat of the review flow. Check on staging that the reclaim's `update auth.users` succeeds for the migration owner (locally `postgres` has UPDATE on `auth.users`; the 2.2 triggers already rely on privileges on that table).
- **The owner's demonstration**: on staff web an Admin approves, links and reclaims; on Android the applicant sees the decision and signs in again after approval.
- Owner gates stay fail-closed: `q4_personal_data` (production refuses review commands that store personal data as `unavailable`), the real first Admin (entry 14).
