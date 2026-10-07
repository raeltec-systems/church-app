# Runbook: identity live access (story 2.1)

Architecture: AD-3, AD-4, AD-13, AD-20. Migration: `supabase/migrations/20261006215842_identity_live_access.sql`.
Evidence: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/evidence-2.1/`.

## What exists

- **Identity records** (non-exposed `app` schema, RLS on, no client privileges):
  - `identity_members`: the stable person (`member_id`), membership state, `is_synthetic`.
  - `identity_account_links`: member to Auth account, with the approved credential binding (E.164 phone username, optional recovery email, `binding_revision`). There is at most one live link per member, per account and per phone.
  - `identity_binding_history`: every approved binding revision.
  - `identity_holds`: an open hold denies every session.
  - `identity_settings`: versioned Q1 settings. Only `dormancy_days` exists so far.
- **The one predicate**, `app.identity_access_evaluate()`. It returns `granted` only when all of these hold:
  1. The signed JWT `amr` contains `password`, and there is a live `auth.sessions` row for its `session_id` and subject, with `not_after` not passed.
  2. The Auth user is neither deleted nor banned.
  3. The account has a live link to an `approved` member.
  4. The link is `active`.
  5. The current `auth.users` phone and email equal the approved binding.
  6. The member has no open hold.
  7. The last member activity is inside the effective dormancy setting. This is checked **before** any refresh.
  8. The release gate allows it (see below).

  Otherwise it returns `unauthenticated`, `untrusted_session`, `not_linked`, `review_required` or `unavailable`.

  Story 1.2 finding F1 (phone `/otp` can leave a `password`-AMR session for any number) is why AMR alone never grants access.
- **Helpers for later owners**:
  - `app.identity_current_member_id()` is meant for RLS policies.
  - `app.identity_require_access()` raises the HTTP-mapped denial.
  - `app.identity_record_activity(link_id)` records activity. Call it only after access was granted.

  Grants and scopes extend the predicate in entry 3.
- **The tracer read**: `POST /rest/v1/rpc/identity_my_member_summary` with `Content-Profile: api`.
  - Success returns 200 with `{member_id, display_name, membership_state, phone_username, has_recovery_email, is_synthetic}`, and records activity.
  - A denial returns 401 or 403 with `message` set to `unauthenticated`, `forbidden` or `unavailable` and `details` set to the caller's own reason.
  - Signed-out callers have no EXECUTE.

## Release gate and settings

- Private member data is served when `app.policy_is_open('private_access')`.
- Exception: a `SYNTHETIC` member (`is_synthetic`) in a database marked `local` or `staging` that is not a held restore. This lets staging demonstrate the tracer while `verify-hosted.sql` keeps the gate itself closed.
- `dormancy_days` has a labelled fixture: `TEST FIXTURE - proposed 90-day dormancy, not church policy`. It is honoured only in `local` and `staging`.
- Production has no approved row, so access there is `unavailable` until the owner approves the Q1 values (entry 14). An approved row is a new `version` with `source = 'approved'`.

## Sign-in on the clients (no SMS)

- Both apps have an **Account** destination (`/account`), plus `/sign-in` and `/create-account`, from `packages/client_core`.
- The phone username is any country code, normalized to E.164 by `normalizePhoneUsername`. +260 is only the picker's initial value.
- The clients use native `signUp(phone, password)` and `signInWithPassword(phone, password)` only. They have no OTP, code entry or resend.
- Errors are generic.
- Story 2.2: only the Auth session persists (mobile: Keystore/Keychain via `flutter_secure_storage`, "after first unlock, this device only"; staff web: the tab's `sessionStorage`, so a reload keeps it and closing the tab ends it). Protected member data stays in memory. See [Session trust (story 2.2)](#session-trust-story-22).
- Sign-out (local scope) ends this device's session and clears protected state.

## Local runs

- Run the pgTAP tests with `npm run db:test`. Run the HTTP checks with `npm run db:smoke`, which includes `supabase/tests/identity_api_smoke.sh`. Both work with the CLI's default config: phone is off, so the smoke signs in through the verified-email alias of a phone account.
- Phone sign-in end to end:
  1. `node tools/auth-harness/local-phone-auth.mjs on`. This is **local only**. It recreates the CLI auth container with `GOTRUE_EXTERNAL_PHONE_ENABLED=true` and `GOTRUE_SMS_AUTOCONFIRM=true`, and refuses if any SMS provider, credential, hook, test OTP or phone MFA is present.
  2. `node tools/identity-e2e/run.mjs [--evidence file.jsonl]`.
  3. `node tools/auth-harness/local-phone-auth.mjs off`. This restores the exact values the CLI had for both keys, which `on` recorded in a container label. `supabase stop && supabase start` also restores the CLI's config.
- To exercise the real client adapters, run `packages/client_core/tool/live_identity_check.dart`. See its header.

## Seeding a synthetic approved member (restricted operator only)

There is no Admin linking UI yet (entry 5). For tracer runs in `local` or `staging` only, use:

```sql
select app.identity_seed_synthetic_link(
  (select id from auth.users where phone = '12025550150'),  -- Auth stores digits without '+'
  'SYNTHETIC Staging Member', 'israel');
```

The function refuses in these cases:

- the database is not marked `local` or `staging`;
- the name does not start with `SYNTHETIC `;
- the phone is outside the reserved fictional ranges (`+1 202 555 0100–0199`, `+44 7700 900000–900999`);
- the email is not synthetic.

It binds the account's **current** Auth phone and email.

## Owner steps for the hosted staging demonstration

The staging project is `bic-kafue-platform-test`, ref `tmurpotfluignacfueki`.

1. **Apply the pending migrations in version order.** Staging ends at `20261003155428`, so apply `20261006215306_recovery_journal (+ 20261006215400_recovery_journal_hold)` (pending since story 1.10) first, then `20261006215842_identity_live_access`.
   - Use either the `promote` workflow, or the Supabase connector's `apply_migration` with the exact file contents and names.
   - Then run `tools/ci/verify-hosted.sql` with `expected_env=staging`.
2. **Enable phone sign-in without SMS.** Use the same Management API call already used on `bic-kafue-auth-test` (the dashboard refuses it). Use your own personal access token, and never paste it into the repo or the chat:

   ```http
   PATCH https://api.supabase.com/v1/projects/tmurpotfluignacfueki/config/auth
   Authorization: Bearer <owner personal access token>
   Content-Type: application/json

   {"external_phone_enabled": true, "sms_autoconfirm": true, "hook_send_sms_enabled": false,
    "mfa_phone_enroll_enabled": false, "mfa_phone_verify_enabled": false}
   ```

   - The body sets no `sms_provider`, no SMS credential fields and no `sms_test_otp`.
   - Check with `GET` on the same URL, then `GET https://tmurpotfluignacfueki.supabase.co/auth/v1/settings`. Expect `external.phone: true` and `phone_autoconfirm: true`.
3. **Build the clients against staging.** Pass `--dart-define=SUPABASE_URL=https://tmurpotfluignacfueki.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=<staging sb_publishable_…>`:
   - for a native target: `flutter run` / `flutter build apk` in `apps/mobile`;
   - for staff web: `flutter build web` in `apps/staff`.
4. **Demonstrate the flows.**
   1. On mobile: **Account**, then **Create account** with `+1 202 555 0150` and a password you choose. The screen shows **No member access yet**.
   2. Seed the link as above (SQL editor or connector).
   3. On mobile: **Check again** shows the summary.
   4. On staff web: **My account**, then **Sign in** with the same number and password. It shows the same summary with no re-approval.
   5. Unlinked account: create `+1 202 555 0151`. It shows **No member access yet**.
   6. Signed out: **Sign out**. The screen returns to the sign-in prompt and the summary is gone.
   7. Direct table query: `GET /rest/v1/identity_members` with `Accept-Profile: app` returns 406, and with `Accept-Profile: api` returns 404.
   8. No SMS: `POST /auth/v1/otp {"phone":"+12025550152"}` returns 500 "Unable to get SMS provider", and no message is sent.
      - This probe is the F1 path. Besides the 500, it **creates a phone-confirmed Auth user for `+1 202 555 0152`**, and that user can end up with a live session whose AMR is `password`. It has no member link, so step 4.6's denial still applies. You must delete it in step 5.
5. **Clean up.** Delete the synthetic links and members, then the Auth users for `+1 202 555 0150–0152`. Include `0152`, the user the `/otp` probe created; deleting an Auth user also ends its sessions. Use the same statements as `tools/identity-e2e/run.mjs` `cleanup`, then check that `select count(*) from auth.users where phone in ('12025550150','12025550151','12025550152')` returns 0.

## Session trust (story 2.2)

Migration: `supabase/migrations/20261006223524_identity_session_trust.sql`. Evidence: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/evidence-2.2/`. Not applied to hosted: it is the owner's promotion step, after `20261006215842_identity_live_access`.

### What changed in the predicate

`app.identity_access_evaluate()` keeps its signature. In addition to the 2.1 checks it now requires:

- `password` in the **server's** session AMR record (`auth.mfa_amr_claims`) as well as in the signed JWT `amr`. Magic-link, email-OTP, signup-link and recovery sessions carry `otp` and stay denied, also after refresh.
- a non-anonymous Auth user;
- an approved recovery email only while Auth holds it **confirmed**;
- no pending **binding review** (`binding_review_required`);
- a session created more than **5 s** (`app.identity_epoch_margin()`) after the link's **trust epoch** (`sessions_valid_after`); otherwise `untrusted_session` (sign in again).

Order: session/JWT, link and member, link state, binding, holds, trust epoch, dormancy (on the stored activity, before any refresh), release gate. Denials never write activity.

### Trusted detection of direct Auth changes (the 1.3 mechanism, owned by Identity)

Triggers run inside GoTrue's own transaction and act only on accounts with a live link (unlinked accounts are ignored):

| Auth change | Effect on the link |
|---|---|
| phone, email, soft delete, hard delete (`auth.users`); identity added, removed or re-pointed to another user/provider id (`auth.identities`); MFA factor added, changed or removed (`auth.mfa_factors`; no-op updates ignored) | `binding_review_required` set (whatever the link state; survives reverts, suspension and unsuspension), an `active` link → `review_required`, generation +1, trust epoch moved |
| password (native `PUT /user`, recovery, Auth Admin), ban or unban | generation +1, trust epoch moved (every earlier session must sign in again, including the one that changed the password) |
| hold placed (`identity_holds` insert); any `link_state` change, including re-approval | trust epoch moved, event recorded |
| a new link for an account or member that had one (relink after `ended`) | starts with a trust epoch and the next generation; a first link has none |

`app.identity_credential_events` records each change by **kind only** (no phone, email or secret values). If a trigger fails, GoTrue's write fails too (fail closed).

Re-approving a link after review (entries 5/8) records a new `binding_revision` (which alone clears `binding_review_required`) and sets `link_state = 'active'`; that moves the epoch again, so only sessions created after the approval pass. Until those workflows exist, a restricted operator does it in SQL for synthetic accounts only.

Known limits:

- GoTrue's lock order around the triggers is not under our control (1.3 limit F).
- The epoch (database clock, stamped inside the changing transaction) is compared with GoTrue's session `created_at` plus a 5 s margin. A GoTrue clock **ahead** of the database by more than the margin, or a session created while the changing transaction is held open longer than the margin, can still be admitted (fail open); keep Auth and database clocks synchronised. A GoTrue clock behind only delays a fresh sign-in (fail closed).

### Clients

- Only the Auth session persists (see "Sign-in on the clients"). Reopening the app restores it and the SDK refreshes it; the server re-checks it on every read.
- When the predicate answers `untrusted_session` (signed out or revoked elsewhere, a credential change, a hold, a pre-approval session), the client ends the session on the device, removes the stored session, clears protected state and shows **Please sign in again**. `review_required`, `not_linked` and `unavailable` keep the session and withhold only the data. A JWT that PostgREST itself rejects (`PGRST301`/`PGRST303`, expired or invalid) is refreshed once and retried; it never ends the session by itself.
- Returning to the foreground asks the server again before the summary is relied on.
- Staff web also keeps the SDK's PKCE code-verifier store (browser `localStorage`, from supabase_flutter); no sign-in flow here uses it and it never holds tokens or member data.

### Local runs

- `npm run db:test` includes `supabase/tests/identity_session_trust_test.sql`; `npm run db:smoke` adds refresh, magic-link and recovery sessions and a direct email change through the real API (CLI default config).
- With `node tools/auth-harness/local-phone-auth.mjs on`: `node tools/identity-e2e/run.mjs` (steps `E30`–`E45`), then `FLUTTER_ROOT=<flutter sdk> bash tools/identity-e2e/live-adapter-check.sh` for the real client adapters (refresh, reopen from the stored session, revocation from another device, sign-out). Then `node tools/auth-harness/local-phone-auth.mjs off`.
- Cleanup of synthetic accounts must delete `app.identity_credential_events` rows before their links (foreign key); the E2E and smoke scripts do.

## Scoped roles and grants (story 2.3)

Architecture: AD-2, AD-3, AD-4, AD-19. Migration: `supabase/migrations/20261006234820_identity_grants.sql`.
Evidence: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/evidence-2.3/`.

### Model

- **Roles** (`app.identity_roles`): `admin`, `pastor`, `media`, `lead_pastor`, held independently. No role implies a care, finance or any other scope.
  - `lead_pastor` is never granted by an Admin command. Only the restricted operator assigns it, naming one member: `select app.identity_designate_lead_pastor('<member_id>', 'israel');`. The assignment is audited and journalled.
    - It works only while the Identity church setting `lead_pastor_designation` (Q4) is in force. A labelled TEST FIXTURE enables the setting in local and staging only; in production it stays unset, so the role can be neither assigned nor used.
    - An Admin may still remove the role with `identity.revoke_role`.
- **Scope kinds** (`app.identity_scope_kinds`): each owning module registers its kinds at migration time with `app.identity_register_scope_kind(module, kind, target_hook, description)`. The target hook is `(jsonb {scope_kind, scope_id}) -> boolean` and checks that the target exists.
  - This story registers only the SYNTHETIC `fixture_care` and `fixture_finance` kinds.
  - Cells registers `cell` at entry 6; Care, Offerings, Prayer and the other owners register their own kinds.
- **Grants** (`app.identity_grants`): one active row per member and role, or per member and scope. Each row records who granted and revoked it (member and acting account, or the restricted operator).
- **Grant sets** (`app.identity_grant_sets`): one revisioned aggregate per member. Its revision is the `expected_revision` of every grant command.
- **Audit** (`app.identity_access_audit`): action, actor (member and account, or operator), `request_id`, target, grant, role or scope, and the new revision. It holds ids and codes only, never names, phones, emails or free text.
- **Church settings** (`app.identity_church_settings`): `lead_pastor_designation` and `operational_contact` (Q1).
  - With no approved row, a setting is unset and fails closed.
  - Fixture rows count only in local and staging.
  - The restricted operator records an owner decision with `app.identity_approve_church_setting(setting, value, 'israel', '<decision note>')`.

### Immediate effect

Every helper first calls `app.identity_access_evaluate()` and then reads the current grant rows. A grant or revocation therefore applies to the next protected call of a session that is already signed in. Nothing about grants is cached in the JWT, and the client never caches grants beyond its account generation.

Helpers for owner code (none of them is client-executable):

| Helper | Use |
|---|---|
| `app.identity_evaluate_grant(role, scope_kind, scope_id)` | Returns `(outcome, member_id, link_id)`. The outcome is the predicate's own denial, `not_granted` or `granted`. |
| `app.identity_has_role(role)`, `app.identity_has_scope(kind, id)` | Booleans for RLS policies and reads. |
| `app.identity_require_grant(role, kind, id, lock)` | Raises 401 or 403 (detail `not_granted` when only the grant is missing). With `lock => true` it share-locks the grant row for a command, so a concurrent revocation waits. Do not lock in GET or read-only requests. |

### Commands (1.4 envelope)

Send `POST /rest/v1/rpc/identity_grant_command` with `Content-Profile: api` and the body `{version: 1, command, request_id, expected_revision, payload}`.

| Command | Payload |
|---|---|
| `identity.grant_role`, `identity.revoke_role` | `{member_id, role}` |
| `identity.grant_scope`, `identity.revoke_scope` | `{member_id, scope_kind, scope_id}` |

- **Who may call**: an Admin whose session passes the predicate. The platform's `app.cmd_authorize` calls the authorizer registered for the `identity` namespace (`app.cmd_authorizers`). Other owners register their own authorizer with `app.cmd_register_authorizer(module, handler)`. Commands outside a registered namespace keep the 1.4 fixture grants.
- **Locks**: the admin catalogue row FOR UPDATE, then the actor's Admin grant FOR SHARE, then the receipt, then the target grant set FOR UPDATE. Two Admins removing each other are serialised: exactly one succeeds (E2E `G23`).
- **Results and refusals**:

  | Outcome | Response |
  |---|---|
  | Success | `data = {member_id, revision, roles, scopes}` |
  | Stale tab | `conflict` with `current_revision` |
  | Not an Admin, or Admin removed | `forbidden` |
  | Untrusted session | `unauthenticated` |
  | Last usable Admin | `forbidden`, `{"role": "unsupported"}` |
  | Role whose setting is unset | `unavailable`, `{"policy": "gate_closed"}` |
  | Unregistered kind or unknown target | `validation_failed` (`scope_kind: unregistered`, `scope_id: unknown`) |

- **Requirements**: a role needs an approved member with a live account link. A scope needs an approved member.
- **Separation of duty**: no grant command (role or scope) may target the acting Admin's own member record: `forbidden`, `{"member_id": "unsupported"}`, with nothing audited. An Admin may still revoke its own grants, subject to the last-Admin rule. `identity.grant_role` with `lead_pastor` returns `forbidden`, `{"role": "unsupported"}`.
- **Side effects**: every revocation dispatches the `scope_revoked` lifecycle event to registered owner hooks inside the same transaction.
- **Usable Admin**: an active Admin grant whose account passes every non-session condition of the predicate (`app.identity_account_standing` = `ok`, and `app.identity_link_dormancy` is null).
  - Those conditions are: the Auth user is not deleted, banned or anonymous; the member is approved; the link is active with no binding review; the Auth phone and email equal the approved binding; there is no open hold; and the account is not dormant.
  - The predicate itself is built from the same two helpers.
- **Concurrency**: grant commands are serialised, so two Admins removing each other cannot both succeed. A hold, link change or Auth change that commits at the same time is not serialised and is never blocked, so it can leave zero usable Admins. The way out is the bootstrap below, which is allowed exactly while no usable Admin exists.

### Reads

| Endpoint | Returns |
|---|---|
| `api.identity_my_access()` | The caller's roles and scopes. Clients build navigation from it. |
| `api.identity_admin_member_grants(after_display_name, after_member_id)` | Admin only. Pages of 50 approved members with `account` (`app_account`, `no_login` or `access_review`), their grants, and the role catalogue with `available`. It carries no care, finance or contact fields. |
| `api.fixture_scoped_read(scope_kind, scope_id)` | SYNTHETIC. Readable only with that exact scope. |

### Bootstrap and recovery Admin (restricted operator)

```sql
select app.identity_bootstrap_admin('<member_id>', 'israel');
```

- The bootstrap is allowed only while no usable Admin exists: the first Admin, or recovery when every Admin is held or in review.
- The member must be approved, with an active link and no binding review.
- It is audited as `admin_bootstrapped` with the operator and journalled in `app.ops_operator_actions`.
- The church-setting approval and the lead-pastor designation are journalled there too.
- The 1.9 journal table was retired by rename (`app.ops_retired_operator_actions_v0`, rows copied, privileges revoked) and recreated with a wider action list, because widening its CHECK needs a DROP. Drop the retired table in a later owner-approved cleanup.
- Staging uses synthetic Admins. Naming the first real Admin is the production gate at entry 14.

### Clients

- Both shells read `api.identity_my_access` again on every navigation (each navigation builds a new shell) and when the app resumes.
- Staff web shows **My access** when access is granted and **Roles & access** (`/admin/grants`) while the answer includes Admin. Mobile shows **Access** with the current roles.
- Navigation is presentation only. A refused grant command triggers a fresh access read, so a removed Admin's open tab loses the entry at once, and the grant screen then shows the server's denial instead of members.
- Unknown command outcomes are checked again under the same `request_id`.

### Local runs

```bash
npx supabase db reset           # empty Admin roster
node tools/identity-e2e/grants.mjs --evidence <file>.jsonl
FLUTTER_ROOT=/opt/sdk/flutter bash tools/identity-e2e/live-grants-check.sh
```

Both sign in through the verified email alias of synthetic phone accounts, so the CLI phone gate stays off. Both clean up every user, link, member, grant, audit row and fixture target they create.

## Membership applications and the safe cell choice (story 2.4)

Migration: `supabase/migrations/20261007050512_membership_applications.sql`.

### Model

- **Application (Identity).** `app.identity_membership_applications` holds one applicant account's request: the full name, the phone username as submitted (unverified), the privacy-notice version and the cell choice (`cell`, `not_sure` or `not_in_cell`).
  - Each account has at most one open request (`submitted` or `needs_details`).
  - `app.identity_application_events` records ids, revisions, events and changed field **names** only.
  - The state CHECKs already list the later review states (`needs_details`, `approved`, `rejected`, `withdrawn`) for entry 5, because widening a CHECK would need a destructive statement.
- **Applying grants nothing.** It creates no member, account link, grant, scope or cell membership. The applicant keeps getting `not_linked` from the live-access predicate on every member surface.
- **Cells (first records).** `app.cells_cells` holds the cell records. `app.cells_signup_options` is the separately persisted safe projection (AD-5): a label and a broad area, plus listing metadata. Nothing else about a cell, such as leaders, members, addresses, phones, chat or reports, reaches an applicant.
- **Cell check without a Cells dependency.** Cells registers the 1.5 source type `cells_signup_option` with the check hook `app.cells_signup_option_check`. Identity validates a chosen cell through `app.contract_check_source`, so the Identity module still depends on nothing but platform. A chosen option must be listed here and must still be at the chosen revision. Otherwise the result is `validation_failed {"cell_id": "invalid"}` and the client reloads the list.
- **Personal-data gate (Q4).** Applications and the chooser are open only when the database is not a held restore (in any environment) **and** either `q4_personal_data` is approved or the database is marked local or staging.
  - While Q4 is unapproved, the applicant's phone username must be in a reserved fictional range (`+1 202 555 0100–0199`, `+44 7700 900000–900999`) and the full name must start with `SYNTHETIC `.
  - When closed, commands answer `unavailable {"policy": "gate_closed"}`, the read reports `accepting_applications: false`, and the chooser lists nothing.
- **Who is an applicant.** A trusted password session of an account with **no live account link** and **no open hold** on any member it was ever linked to (`app.identity_applicant_outcome()`). An account linked to a pending, rejected or deactivated member, or held, gets `forbidden` with reason `not_applicant`.
- **Name rules.** Every Unicode whitespace run collapses to one space and the ends are trimmed. Unicode control and format characters (Cc/Cf, including bidi overrides such as U+202E) are refused on `full_name`.
- **Abuse limit.** At most 10 corrections per application per rolling 24 hours (`app.identity_application_correction_limit()`); beyond that the answer is `rate_limited`.
  - Deferred: sign-up rate limits are Supabase Auth's own settings (Q1 owner configuration).
  - Re-applying after a rejection was decided in entry 5: see [Re-applying after a rejection](#re-applying-after-a-rejection).
- **Nested field errors** use dotted paths: `cell_choice.choice`, `cell_choice.cell_id`, `cell_choice.cell_revision`, and `cell_choice.<unknown key>` for each unknown key.
- **Privacy notice.** The notice is a labelled DRAFT (`draft-2026-10-07`), and the clients bundle its text. The church approves the wording under Q4. A new version needs a new migration and a new client text.

### Commands (1.4 envelope) and reads

| Endpoint | Who | What |
|---|---|---|
| `api.identity_application_command` `identity.submit_application` | trusted password session whose predicate outcome is `not_linked` | `expected_revision` null; payload `{full_name, cell_choice {choice, cell_id?, cell_revision?}, privacy_notice_version}`. A second open request gets `conflict` + `current_revision`. |
| `api.identity_application_command` `identity.correct_application` | same | `expected_revision` = the application revision; payload `{application_id, full_name?, cell_choice?}`. A stale revision or a decided request gets `conflict`. Another account's id gets `not_found`. Answering `needs_details` returns the request to `submitted`. |
| `api.identity_my_application()` | applicant (`not_linked`) or member (`granted`) | The caller's own request (open first, else latest), the privacy notice and `accepting_applications`. |
| `api.cells_signup_options()` | applicant or member | `{options: [{cell_id, label, broad_area, revision}]}`. SYNTHETIC options are listed only in local/staging. |

- The registered `identity` command authorizer now dispatches. Application commands need the `not_linked` outcome: members and accounts in access review get `forbidden`, and untrusted sessions get `unauthenticated`. The grant branch is the 2.3 body unchanged.
- No payload can set a membership or cell status. Unknown fields are refused as `unknown_field`.

### Cells until entry 6 (restricted operator)

```sql
select app.cells_seed_synthetic_cells('<operator>');   -- local/staging only; idempotent
```

The function seeds three SYNTHETIC cells and options (`…c241`–`…c243`). It refuses an unmarked or production database. Production has no cells until Admin cell setup (entry 6) and the church's real cell list, which is an owner gate. Until then the chooser offers only **I'm not sure** and **I'm not in a cell yet**.

### Clients

- **Mobile.**
  - After Create account, the app opens **Join the church** (`/membership`). The form asks for the full name and **Which cell group do you belong to?** The choices are the listed cells (label and broad area), **I'm not sure** and **I'm not in a cell yet**.
  - The form also shows the draft privacy notice, and a note that email is optional and that staff will help in person without a recovery email.
  - A new request needs the explicit "I have read the privacy notice" checkbox (unchecked by default). If the app has no bundled text for the server's notice version, sending is disabled and the screen sends the applicant to the church office.
  - The status card shows **Church approval** and **Cell group** as separate states, and offers **Correct my request** while the church has not decided.
  - When the outcome is unknown, Check again resends the same request id.
  - The Account page's "No member access yet" state links to the request.
- **Staff web.** Sign-in and Create account stay as before and continue to the account page. The route exists, but staff web has no entry point to it.

### Local runs

```bash
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/apply.mjs --evidence <file>.jsonl
FLUTTER_ROOT=/opt/sdk/flutter bash tools/identity-e2e/live-application-check.sh
node tools/auth-harness/local-phone-auth.mjs off
```

Both scripts sign up real phone accounts without email, using fictional numbers. They seed the SYNTHETIC cells when none exist and remove every user, application, event, receipt and seeded cell they created.

## Membership review, linking, accountless members and reclaim (story 2.5)

Migrations: `supabase/migrations/20261007063340_membership_review.sql` and the small follow-up `20261007131600_membership_review_reclaim_sessions.sql` (the reclaim's session revocation; it contains row deletions, so the owner applies it by hand after the main file).
Evidence: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/evidence-2.5/`.

### Who may do what

Every command and read below needs a live Admin: the session passes `app.identity_access_evaluate()` and the member holds Admin now. Commands go through the registered `identity` authorizer (the 2.3 Admin branch, serialised on the admin catalogue row); the reads call `app.identity_require_grant('admin')`. Applicants and members get `forbidden`, untrusted sessions `unauthenticated`.

Separation of duty: an Admin cannot decide an application sent from their own account, link an account to their own member record, unlink their own account, or reclaim their own username (`forbidden`, field error `unsupported`).

### Commands (`POST /rest/v1/rpc/identity_review_command`, `Content-Profile: api`)

| Command | `expected_revision` | Payload | Effect |
|---|---|---|---|
| `identity.approve_application` | application revision | `{application_id, identity_check}` | New approved member (name from the request), provenance `application`, link to the applicant's account |
| `identity.link_application` | application revision | `{application_id, member_id, identity_check}` | The applicant's account joins an EXISTING approved member with no live link, no hold and no active grant; member id, record and history are kept |
| `identity.request_application_details` | application revision | `{application_id, requested[], identity_check?}` | `needs_details`; `requested` ⊆ `full_name`, `cell_choice`, `visit_church_office`, `recovery_email` (confirm the email on the account or remove it) |
| `identity.reject_application` | application revision | `{application_id, reason?, identity_check?}` | `rejected`; `reason` ∈ `identity_not_confirmed`, `not_known_to_church`, `contact_church_office` |
| `identity.create_member` | null | `{full_name, consent_basis, assisted_by_member_id?, contact_route?{phone, belongs_to, holder_label?}}` | Approved member WITHOUT a login; provenance `admin_record`; `consent_basis` ∈ `in_person`, `leader_assisted` |
| `identity.unlink_account` | member revision | `{member_id, reason}` | Ends the live link and every active grant of the member (2.3 path: `role_revoked`/`scope_revoked` audit with the acting Admin); member and history kept; `account_deactivated` dispatched to owner hooks |
| `identity.reclaim_phone_username` | null | `{phone_username, identity_check, reason?}` | Releases a username held by an UNLINKED account (see below) |

- `identity_check` ∈ `established_relationship`, `in_person`. Approve and link require it.
- **The link.** Approve and link bind the applicant account's **current** Auth phone (which must still equal the phone username it applied with, otherwise `validation_failed {"phone_username": "changed"}`) and its current email. An unconfirmed email refuses the link (`validation_failed {"recovery_email": "unverified"}`); ask for details with `recovery_email` so the applicant is told. An account once linked to a member who is on hold is refused (`forbidden {"application_id": "not_applicant"}`).
- **Grants never travel with a link.** Unlinking ends the member's grants; link-existing refuses a member with any active grant (`member_id: has_grants`). After linking, grant roles through the audited 2.3 commands (`lead_pastor` only by the operator). They write binding history revision 1 (`application_approved` / `application_linked`) and set the link's trust epoch at the approval, so **the applicant must sign in again**: the session they applied with is `untrusted_session`, and a sign-in more than 5 s later is granted.
- **One live link** per member, per account and per phone username: a second is `conflict` with field error `linked` (`member_id`, `application_id` or `phone_username`). Unlink first, explicitly.
- **Nothing is automatic.** A matching name, phone username or contact route never links, merges, approves or discloses anything. A shared contact number gives no access.
- **Last Admin.** Unlinking an Admin's account is refused (`forbidden {"member_id": "last_admin"}`, shown as its own notice) when no other usable Admin would remain (defence in depth: the acting Admin always counts).

### Reclaiming a phone username (F1)

Someone may register a person's number first (for example through the `/otp` path of finding F1). After checking the claimant's identity, an Admin sends `identity.reclaim_phone_username`. It is behind the personal-data gate and, while Q4 is unapproved, accepts only fictional numbers; the number matches Auth's stored phone with or without `+`.

- If the account holding the number has a **live member link**, the answer is `conflict {"phone_username": "linked"}`: that is a dispute about a member. Unlink that account explicitly (reason `ownership_dispute` or `phone_reclaim`) and then reclaim.
- Otherwise, in one transaction, Identity clears the holder's Auth phone, bans it (100 years, GoTrue's own ban form), deletes its Auth sessions and refresh tokens (follow-up migration), withdraws its open application and records a reclaim case (`app.identity_phone_reclaims`). The holder's Auth row is kept, never merged or deleted.
- The person the number belongs to can then create an account with it and apply; the Admin approves or links as usual.
- To undo a mistaken reclaim, the restricted operator runs `select app.identity_undo_phone_reclaim('<reclaim_id>', 'israel');` while the number is still free: the account is unbanned and gets its phone back; the withdrawn application stays withdrawn. It is audited as `phone_reclaim_undone` with the operator. It is not in `app.ops_operator_actions`, whose action list has no fitting value (widening it needs the retire-and-recreate cleanup).

These are the only places Identity writes Auth rows from SQL (phone, phone confirmation, ban, the holder's sessions); the 2.2 credential triggers ignore it because the holder has no live link. Hosted: confirm on staging that the migration owner may update `auth.users` (the 2.2 triggers already needed privileges on that table).

### Reads

| Endpoint | Returns |
|---|---|
| `api.identity_admin_application_queue(after_submitted_at, after_application_id)` | Open applications, oldest first, 25 per page. Each has the applicant's request, `prior_not_approved` (earlier rejected or withdrawn requests from the account), `own_account` and staff-only `candidates`: approved members with `signals` (`same_name`, `similar_name`, `contact_route_phone`, `linked_phone_username`), `account` and `link_eligible`. |
| `api.identity_admin_member_search(query, after_display_name, after_member_id)` | Approved members (with or without a login) by name or contact number (literal match), 25 per page, with `account`, `link_eligible`, `origin`, `revision` and labelled `contact_routes`. |

The applicant's own read (`api.identity_my_application`) gains `decision_reason`, `details_requested` and `reapply_from` (each only when it applies). It never carries candidates, member ids or reviewer data.

### Re-applying after a rejection

A rejected account may send a **new** application 7 days after the decision (`app.identity_reapply_cooldown()`); earlier it gets `rate_limited`. The guard is a BEFORE INSERT trigger, so it covers every insert path. The rejected request stays in history, and the queue shows Admin how many earlier requests were not approved.

### Audit

`app.identity_membership_audit` records every decision, record, unlink, reclaim and reclaim undo with ids, codes, revisions and (for the undo) the operator name only (`application_approved`, `application_linked`, `application_details_requested`, `application_rejected`, `application_withdrawn`, `member_created`, `account_unlinked`, `phone_username_reclaimed`, `phone_reclaim_undone`). Grants ended by an unlink are in `app.identity_access_audit` as `role_revoked`/`scope_revoked`. Application events also get the decision (`approved`, `details_requested`, `rejected`, `withdrawn`) with the Admin's account as actor.

### Clients

- **Staff web.** Admins see **Members & applications** (`/admin/members`) in the sidebar while the server's current answer includes Admin.
  - **Applications**: each request with the unverified sign-in username, the cell answer (confirmation is separate, entry 6), earlier requests not approved, staff-only possible existing records with their signals, an identity-check choice, and **Approve as a new member**, **Link existing** (to a candidate or a searched record), **Ask for details** and **Reject** (optional reason). Approve and link stay disabled until an identity check is chosen; the Admin's own request is shown as one another Admin must decide.
  - **All members**: search, account state (App account, No login, Access review), labelled contact routes, **Unlink account** with a reason, and **Add member record (no login)** with consent basis and an optional contact number and whose it is.
  - **Reclaim a username**: number, identity check, optional reason.
  - Unknown outcomes are checked again under the same request id; any refused or denied answer re-reads the Admin's access.
- **Mobile.** The request status shows the church decision separately from the cell: details requested (what was asked), not approved (reason and when a new request can be sent, then **Send a new request**), approved.

### Local runs

```bash
npx supabase db reset                          # empty Admin roster
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/review.mjs --evidence <file>.jsonl
FLUTTER_ROOT=/opt/sdk/flutter bash tools/identity-e2e/live-review-check.sh
node tools/auth-harness/local-phone-auth.mjs off
```

Both use fictional numbers (`+1 202 555 0188–0199`) and remove every user, application, member, link, grant, audit row and receipt they create. The bootstrap they perform leaves append-only operator-journal rows (as 2.3's E2E does), so reset before re-running `identity_grants_test.sql`.

## Cells: setup, confirmation and transfer (story 2.6)

Migration: `supabase/migrations/20261007140000_cell_membership.sql` (no row deletions; one file).
Evidence: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/evidence-2.6/`.

### Model (Cells owns it)

- **Cells** (`app.cells_cells`, sign-up projection `app.cells_signup_options` from 2.4): an Admin creates and edits them. Applicants only ever see the sign-up label and broad area.
- **Leaders and assistants are Identity scope grants**: Cells registers the scope kinds `cell_leader` and `cell_assistant` (scope id = cell id). Give or remove them with the 2.3 commands `identity.grant_scope` / `identity.revoke_scope` (audited in `app.identity_access_audit`, immediate effect). Leaders confirm requests for their cell; assistants have the cell's private access but do not confirm.
- **Requests** (`app.cells_membership_requests`): `join` or `change`, from an approved application (Cells creates it the first time a Cells read or command runs after the approval, once per application, only for a member with no Cells history), from the member, or from an Admin on a member's behalf. One open request per member. A request grants nothing.
- **Confirmed membership** (`app.cells_memberships`): zero or one current primary cell per member (partial unique index), with start/end dates; ended rows are kept as history.
- **Per-member revision** (`app.cells_member_states`): the `expected_revision` of every request command for that member.
- **Audit** (`app.cells_membership_audit`): ids, codes, revisions, the actor and the capacity they acted in (`admin`, `cell_leader`, `member`). No names, labels or numbers.
- **Cell-private access rule** for later owners: `app.cells_member_has_private_access(member_id, cell_id)` = a current primary membership in the cell, or a leader/assistant scope for it. Use it only with the member the live-access predicate returned. The Admin role alone gives none. `api.cells_private_fixture_read(cell_id)` is its SYNTHETIC fixture surface.
- Personal-data gate: every Cells command and read needs `app.identity_applications_open()`; while Q4 is unapproved, cell names, labels and areas must start `SYNTHETIC `.

### Commands (`POST /rest/v1/rpc/cells_command`, `Content-Profile: api`)

The `cells` authorizer is registered in the 2.3 authorizer registry (namespace = module). It needs a live member session (`unauthenticated` otherwise) and share-locks the actor's Admin and cell-scope grants; each handler checks the capacity.

| Command | Who | `expected_revision` | Payload |
|---|---|---|---|
| `cells.create_cell` | Admin | null | `{name, signup_label, broad_area, listed?, sort_order?}` |
| `cells.update_cell` | Admin | cell revision | `{cell_id, name?, signup_label?, broad_area?, listed?}` |
| `cells.request_change` | the member; an Admin for any member (`member_id`) | member's Cells revision | `{cell_id, cell_revision (the sign-up option revision), member_id?}` |
| `cells.confirm_request` | the leader of the requested cell, or an Admin | member's Cells revision | `{request_id, cell_id?}` (`cell_id`: Admin only; required for a request without a cell) |
| `cells.decline_request` | the leader (refers it to the Admin follow-up queue) or an Admin (final) | member's Cells revision | `{request_id, reason?}`; `reason` ∈ `not_in_this_cell`, `not_known_to_leader`, `member_withdrew`, `no_cell_for_now` |
| `cells.cancel_request` | the member (own request) or an Admin | member's Cells revision | `{request_id}` |

- Nobody confirms or declines their own membership (`forbidden {"member_id": "unsupported"}`); a member cannot request for someone else.
- A change to the current cell is `validation_failed {"cell_id": "current"}`; a second open request is `conflict {"member_id": "open_request"}`; a decided request is `conflict {"request_id": "decided"}`.
- **Transfer**: confirming a request of a member who already has a primary cell ends the old membership (`transferred`) and starts the new one in the same transaction, then dispatches the contract v1 lifecycle event `cell_transferred` (`identity_revision` = the member's new Cells revision; Cells is now its emitter) to every hook registered with `app.contract_register_lifecycle_hook`. A failing hook rolls the transfer back. Church membership, account links and grants are not touched. Owners that will need the old and new cell ids (duties, chat, follow-ups, programmes) need a contract version change; none is fabricated here.
- `app.fixture_record_lifecycle(jsonb)` is a SYNTHETIC hook. The migration does **not** register it; tests and the local E2E register it and remove it again.

### Reads

| Endpoint | Who | Returns |
|---|---|---|
| `api.cells_my_cell()` | a member with live access | `{member_id, revision, primary {cell_id, label, broad_area, since}, open_request, last_decision}` |
| `api.cells_leader_queue()` | holders of a `cell_leader` or `cell_assistant` scope (`403 not_granted` otherwise) | each cell they serve with its roster; leaders also get the cell's pending requests |
| `api.cells_admin_overview()` | Admin | cells with leaders/assistants and their grant revisions, every open request (`follow_up` = no cell chosen or referred by a leader), approved members with their cell and revisions (at most 500) |

### Clients

- **Staff web.** **Cells** (`/admin/cells`, Admin): follow-up queue, requests waiting for a leader, cells with their leaders/assistants (give or remove the role), list/hide for sign-up, add a cell, and request a cell for a member (for example one without a login). **My cell group** (`/cells/leader`, shown while the caller holds a cell scope): requests to confirm or pass to the office, and the roster.
- **Mobile.** **My cell** (`/my-cell`, shown with member access): the confirmed cell (separately from church membership), the open request with **Cancel**, and **Ask to join/change cell** from the safe chooser.
- Unknown outcomes are checked again under the same request id; a refused or denied answer re-reads the caller's access.

### Local runs

```bash
npx supabase db reset                          # empty Admin roster
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/cells.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

The E2E uses `+44 7700 900260–900264` and removes everything it created, including its hook registration.

### Hosted (owner / parent session)

Apply `20261007140000_cell_membership.sql` after `20261007131600`. Production keeps no cells until the church's real cell list is set up by an Admin after Q4 approval (entry 14); staging uses SYNTHETIC cells.
