# Runbook: restricted identity support (story 2.12)

RESTRICTED. For the church's support Admins, the named recovery and approval owners and the restricted operator. It tells them what to do; the mechanics behind each step (commands, refusals, hosted setup) are in [identity-access.md](identity-access.md), per story, and are not repeated here.

Evidence and the local rehearsal: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/evidence-2.12/`. Rehearsal script: `tools/identity-e2e/runbooks.mjs` (see [Rehearsal](#rehearsal)).

| Runbook | Use it for |
|---|---|
| [RB1 First-Admin setup](#rb1-first-admin-setup) | A new environment has no Admin yet |
| [RB2 Applications, linking and number reclaim](#rb2-applications-linking-and-number-reclaim) | Membership requests, members without a login, a number someone else registered |
| [RB3 Email recovery](#rb3-email-recovery) | Adding a recovery email; a member who forgot the password and has one |
| [RB4 Staff-assisted recovery](#rb4-staff-assisted-recovery) | A member who forgot the password and has no usable recovery email |
| [RB5 Holds, disputes and credential review](#rb5-holds-disputes-and-credential-review) | Lost phone, stolen session, ownership dispute, a sign-in detail changed outside the church's review |
| [RB6 Deactivation and handover](#rb6-deactivation-and-handover) | A member leaves the church, or comes back |
| [RB7 Deletion](#rb7-deletion) | A member asks for their data to be deleted |
| [RB8 Identity-checked last-Admin fallback](#rb8-identity-checked-last-admin-fallback) | No Admin can act any more |

## Roles

Roles, not people. The names are a Q1 decision that the owner fills in at entry 14.

| Role | Who | Holds |
|---|---|---|
| Support Admin | `<named owner: fill at entry 14>` and other Admins | The `admin` role, on staff web. Nothing else: no care, finance, prayer or cell scope (see [Support accounts](#support-accounts-hold-admin-only)) |
| Second Admin | Any other Admin | Needed where one person must not act alone: releasing a hold, restoring a membership, a staff-requested deletion after a hold |
| Named recovery owners | Two people, `<named owner: fill at entry 14>` and `<named owner: fill at entry 14>` | They decide the identity check in RB8 together, and keep the restricted case notes |
| Restricted operator | `israel` (owner decision, 1.9) | Operator procedures as the database owner (SQL editor or the Supabase connector). No client grant reaches them |
| Member | The person being helped | Their own phone, password, mailbox and grant secret. Nobody else ever holds these |

## Rules for every runbook

**Never:**

- Never ask for, hear, type, choose, set, reset or write down a member's password. The member chooses it on their own device. Nobody "sets a temporary password".
- Never show, forward or read out a usable grant, code or link to anyone but its holder:
  - an email confirmation or reset link stays in the member's mailbox;
  - the staff-assisted recovery grant secret never leaves the member's phone;
  - the 8-character request code goes from the member's screen to the office (it only finds the request; staff answers never echo it);
  - system credentials stay in `.ops-state/` and the Edge Function secret.
- Never mint a session or a token for someone, never sign in as a member, and never use the Supabase Auth dashboard or Auth Admin API to change a member's phone, email, password or ban.
- Never edit member data with SQL. The only SQL the operator runs is the operator procedures named here. Reads of audit counts are allowed.
- Never give a support account a care, finance, prayer or cell scope to "see what is wrong". Admin sees no care or finance content by design.
- Never link, merge or approve because a name, phone number or email matches. Matches are hints for the identity check, never a decision.
- Never act on your own record. The server refuses it, and you must not look for a way round.
- Never put real member data, phone numbers, addresses or credentials in a case note, a chat, a ticket or the repository. Case notes hold the date, the runbook, the member id, the identity-check code and who acted.

**Always:**

- **Identity check.** Choose the identity check honestly:
  - `in_person`: the person is in front of you;
  - `established_relationship`: you know them personally and spoke to them directly.
  
  Staff-assisted recovery also records what you saw (`photo_id`, `known_in_person`, `church_records`, `leader_confirmation`). If you are not sure who the person is, stop: refuse with reason `identity_not_confirmed`, or ask them to visit the church office.
- **Unknown outcome.** When the staff screen shows an unknown outcome, press the same action again. It resends the same request id, so nothing happens twice.
- **Signing in again.** Approvals, restores, releases and resets move the account's trust epoch. Tell the member to sign in again, more than a few seconds after you acted.
- **Synthetic only before Q4.** Until Q4 is approved, staging and rehearsals use SYNTHETIC records only, with fictional numbers (`+1 202 555 0100-0199`, `+44 7700 900000-900999`) and `@example.test` or the owner's approved test inboxes.

## Support accounts hold Admin only

- The `admin` role carries no care, finance, prayer or cell-private scope. Scopes are separate grants, owned by their modules, and never travel with Admin, a link or a restoration.
- The rehearsal proves it each run: an Admin-only account, including one restored through RB8, gets `403 not_granted` from the SYNTHETIC care fixture (`api.fixture_scoped_read`, `fixture_care`), the finance fixture (`fixture_finance`) and a cell-private fixture (`api.cells_private_fixture_read`).
- If a support person also serves in a care, finance or cell role, they use that role only for its own work, never for support.

## Where the audit is

Every runbook action is recorded with ids, codes and revisions only: no names, numbers, addresses, passwords or free text. The operator may read counts in the SQL editor, for example `select action, count(*) from app.identity_recovery_audit where member_id = '<member_id>' group by 1;`.

| Table | Records |
|---|---|
| `app.identity_membership_audit` | application decisions, member records, unlinks, reclaims and reclaim undos |
| `app.identity_access_audit` | role and scope grants and revocations, the first-Admin bootstrap (`admin_bootstrapped`) and the RB8 fallback (`admin_fallback_granted`), both with actor `operator` |
| `app.identity_admin_fallbacks` | RB8: reason, identity check, usable Admins before, the confirming owner and the case reference |
| `app.identity_credential_audit` | recovery-email proposals and decisions (2.7) |
| `app.identity_credential_review_audit` | sign-in detail changes, holds, restore and accept (2.8, 2.10 login holds) |
| `app.identity_recovery_audit` | staff-assisted recovery cases, grants and operations (2.9) |
| `app.identity_membership_lifecycle` | deactivations and restorations (2.10) |
| `app.identity_deletion_audit` | deletion requests and steps (2.11) |
| `app.ops_operator_actions` | every operator procedure |
| `app.sys_audit` | every system-route call (assisted recovery and deletion) |

---

## RB1 First-Admin setup

**When:** a new environment (staging now, production at entry 14) has no usable Admin: `select app.identity_usable_admin_count();` returns 0.

**Who:** the restricted operator, for a person the owner has named as first Admin. Then that first Admin, for the second.

**Preconditions:**

- The environment marker is right: `select app.platform_current_environment();`.
- Identity's migrations are applied, and `tools/ci/verify-hosted.sql` passes.
- The first Admin has their own approved member record with a live, usable account link:
  - **staging:** they create an account on mobile (**Account, Create account**) with a fictional number and their own password, and the operator links it with `app.identity_seed_synthetic_link` (SYNTHETIC names only; [identity-access.md, story 2.1](identity-access.md#seeding-a-synthetic-approved-member-restricted-operator-only));
  - **production:** there is no path yet. Applications need an Admin to approve them, and the synthetic seeding refuses production. Naming and linking the first real Admin is an entry 14 decision and needs a reviewed operator procedure that approves that one application after the owner's identity check. Do not improvise it with SQL.

**Steps:**

1. Operator: `select app.identity_bootstrap_admin('<member_id>', 'israel');`. It returns the new grant id only. It is refused while any usable Admin exists, and for a member without a usable link.
2. First Admin: sign in on staff web with their own phone and password. **Roles & access** (`/admin/grants`) and **Members & applications** appear.
3. First Admin: give a second, identity-checked member the Admin role in **Roles & access** (`identity.grant_role`). Two Admins are needed for RB5, RB6 and RB7.
4. Operator, only when Q4 allows it: `select app.identity_designate_lead_pastor('<member_id>', 'israel');`. Only the operator designates the lead pastor; Admins can only remove the role.
5. Operator, when the owner has decided the church contact shown on help screens: `select app.identity_approve_church_setting('operational_contact', '{"route": "<church office route>"}', 'israel', '<decision note>');`.

**Never:**

- Bootstrap a support account that also needs care or finance access.
- Use the bootstrap while an Admin exists. Use RB8 when the existing Admins cannot act.

**Audit evidence:** `identity_access_audit` `admin_bootstrapped` (actor `operator`), `ops_operator_actions` `admin_bootstrapped`; then `role_granted` by the first Admin.

**Back out:** the second Admin removes the role in **Roles & access** (`identity.revoke_role`). The last usable Admin cannot be removed.

## RB2 Applications, linking and number reclaim

**When:** an application waits in **Members & applications, Applications**; a person without a phone or app needs a record; or someone else registered a person's number first (finding F1).

**Who:** a Support Admin. Never for your own application or record.

**Preconditions:**

- The personal-data gate is open (Q4, or staging with SYNTHETIC data).
- The applicant has signed in at least once with the number they applied with.

**Steps, applications:**

1. Open **Members & applications** (`/admin/members`), **Applications**. Read the request: the name, the unverified sign-in username, the cell answer, any earlier requests that were not approved, and the staff-only possible existing records with their signals.
2. Check the person's identity (in person, or by a relationship you already have) and choose the identity check.
3. Decide:
   - **Approve as a new member**: a new approved member;
   - **Link existing**: when the person already has a record (an accountless member, or one whose old account was unlinked). Pick the record from the candidates or a search;
   - **Ask for details** (`full_name`, `cell_choice`, `visit_church_office`, `recovery_email`);
   - **Reject** (`identity_not_confirmed`, `not_known_to_church`, `contact_church_office`). They can send a new request after 7 days.
4. Tell the member to sign in again. Their earlier session ends at approval.
5. Roles never come with approval or linking. Grant them separately (RB1 step 3), after a separate decision.

**Steps, a member without a login:**

1. **All members, Add member record (no login)**: full name, consent basis (`in_person` or `leader_assisted`), and optionally a contact number with whose number it is.
2. When that person later creates their own account and applies, use **Link existing** to that record. The member id and history are kept.

**Steps, a number someone else registered:**

1. Check the claimant's identity in person.
2. **Reclaim a username**: the number, the identity check and a reason (for example `registered_by_someone_else`).
3. If the number belongs to a linked member, the answer is `conflict` (`phone_username: linked`). That is a dispute about a member: handle it with RB5 (`ownership_dispute` hold), then unlink that account explicitly (**Unlink account**, reason `ownership_dispute` or `phone_reclaim`), then reclaim.
4. The person now creates their account with the number and applies; continue with the application steps.

**Never:**

- Approve or link on a matching name or number alone.
- Link an account to a member who has active grants (refused).
- Read a contact number out to someone who is not its holder.

**Audit evidence:** `identity_membership_audit` (`application_approved`, `application_linked`, `application_details_requested`, `application_rejected`, `member_created`, `account_unlinked`, `phone_username_reclaimed`), application events with the deciding Admin's account.

**Back out:**

- A wrong link or approval: **Unlink account** with a reason (ends the link and every grant; the member and history stay). The right person then applies again.
- A mistaken reclaim, while the number is still free: operator `select app.identity_undo_phone_reclaim('<reclaim_id>', 'israel');`.

## RB3 Email recovery

**When:** a member wants to add a recovery email, or a member with an approved recovery email forgot the password.

**Who:** the member, alone, for the reset. A Support Admin approves an added address. Never your own.

**Preconditions:** email recovery is open (`q1_auth_recovery` approved, or staging), and the address is allowed (synthetic or the owner's test inboxes until Q4).

**Steps, adding the email:**

1. Member, on mobile: **My membership, Recovery email**. They enter the address and their current password, then open the confirmation link from their own mailbox. Their access waits in review until approval.
2. Support Admin, **Recovery emails** (`/admin/recovery-emails`): the proposal shows `verified` when the member opened the link. Check the member's identity and approve with the identity check, or don't approve with a reason.
3. Tell the member to sign in again.

**Steps, forgot password (no staff step):**

1. Member: **Sign in, Forgot password?**, then the approved recovery email. The answer is always the same neutral acknowledgement.
2. Member: opens the reset link on the same device, chooses a new password, signs in again.
3. If the link says it cannot be used, the address is not the approved one, or the account is held or in review. Use RB4 or RB5.

**Never:**

- Ask the member to forward the confirmation or reset email, or read the link out.
- Approve an address the member did not confirm themselves (the server refuses `unverified`), or one with other changes on the account (`other_changes`; use RB5).

**Audit evidence:** `identity_credential_audit` (`recovery_email_proposed`, `recovery_email_approved`, `recovery_email_rejected`, `recovery_email_withdrawn`, `recovery_email_reverted`); credential event `email_link_redeemed` for a reset.

**Back out:**

- **Don't approve** returns the account to its approved binding and removes the proposed address from Auth. The member can also **Withdraw this email**.
- Replacing or removing an approved address is a sign-in detail change (RB5).

## RB4 Staff-assisted recovery

**When:** a member forgot the password and has no usable approved recovery email.

**Who:** a Support Admin other than the member, with the member present (in person, or by a relationship you already have).

**Preconditions:**

- Assisted recovery is open (staging, or `q1_auth_recovery` approved).
- The Edge Function `identity-assisted-recovery` is deployed, with its system credential set by the operator ([identity-access.md, story 2.9](identity-access.md#hosted-parent-session--owner)).
- The member's account is linked and not on an `ownership_dispute` hold. A dispute is refused (`disputed`); resolve it with RB5 first.

**Steps:**

1. Member, on their own phone, signed out: **Sign in, Get church help, I need help accessing my account**. They enter their phone number. The phone shows an 8-character request code.
2. Support Admin, **Account recovery** (`/admin/account-recovery`): find the member, choose the identity check and the evidence seen, and **open a case**.
3. The member reads the code from their screen. Type it and **issue the grant**. It lasts 15 minutes and works once.
4. Member: **The office is done: continue**. They choose a new password on their phone.
5. The member signs in again with the new password. Every older session has ended.
6. If the member was on a `lost_device` or unreviewed-password hold (RB5), the hold is now releasable. A Second Admin releases it in **Access reviews**.

**Never:**

- Take the member's phone to type the password for them, or look at it while they type.
- Issue a grant for a code the member did not show you. A code from another number is refused.
- Cancel a case while an operation is dispatched or uncertain.

**If it goes wrong:**

- **Expired or superseded grant:** issue a new one with a new code from the phone.
- **Operation `uncertain` or `stuck`:** the account stays held. Use **Reconcile** with an identity check (every session is revoked), then issue a new grant. After the reset succeeds, a Second Admin releases the hold.
- **Too many attempts** (`rate_limited`): wait 10 minutes. The limits are per phone, per network and church-wide.

**Audit evidence:** `identity_recovery_audit` (`case_opened`, `grant_issued`, `operation_begun`, `operation_dispatched`, `operation_succeeded`, `case_completed`; or `case_cancelled`, `operation_reconciled`), plus `sys_audit` rows for each function step.

**Back out:** **Cancel case** (`identity_not_confirmed`, `member_withdrew`, `opened_in_error`) before the member uses the grant. After a successful reset there is nothing to undo: the member's password is theirs, and if it was set by the wrong person, place a `security_concern` hold (RB5) at once.

## RB5 Holds, disputes and credential review

**When:**

- a lost or stolen phone;
- a suspected stolen session;
- two people claim the same account;
- the church disables someone's login;
- an account shows **Access review required** because a sign-in detail changed outside the church's review.

**Who:** a Support Admin places a hold. A **Second Admin** (not the member, and preferably not the one who placed it) releases it after an identity check. Never your own record.

**Steps, placing a hold** (**Access reviews**, `/admin/credential-reviews`, **Place a hold**; or **Membership status, Disable login (hold)**). Find the member and choose the reason:

| Reason | Use | Effect |
|---|---|---|
| `lost_device` | lost or stolen phone | every session ends at once; release needs the member's own reset first (RB3, or RB4) |
| `security_concern` | stolen session or suspicious change | access waits for review |
| `ownership_dispute` | two people claim the account | access waits for review; recovery is refused until released |
| `login_disabled` | the church disables the login (2.10) | every session ends; membership and grants are kept |

The member sees only the generic **Access review required** screen with the church contact, never the reason.

**Steps, releasing:**

1. Second Admin, **Access reviews**: check the member's identity, then **Release** with the identity check.
2. `password_reset_required` means the member must first reset the password themselves (RB3 or RB4).
3. The member signs in again.

**Steps, credential review** (an account in review with no pending request):

1. **Access reviews, Accounts in access review** shows the approved and current details and what changed.
2. After an identity check, choose:
   - **Restore**: back to the approved phone and email. Extra factors and identities are removed, and every session ends. If the password changed without the member's own reset, a security hold stays until they reset it.
   - **Accept**: the current details become the approved ones. Refused for factors, an unconfirmed email or an unreviewed password.
3. A member-requested change (new number, new or removed email): approve with the identity check, or don't approve. Each needs the member's fresh password sign-in, made by them.

**Never:**

- Release a hold you placed when another Admin is available.
- Accept details you cannot tie to the member's identity check.
- Treat a reset, a new sign-in or an email confirmation as clearing a hold: none of them does.

**Audit evidence:** `identity_credential_review_audit` (`hold_placed`, `hold_released`, `credentials_restored`, `credentials_accepted`, `credential_change_*`), binding history reasons (`credentials_restored`, `phone_username_changed`, and so on), lifecycle events `access_hold_applied`, `access_hold_released`, `sessions_revoked`.

**Back out:**

- A hold placed in error: release it with an identity check.
- A wrong Accept: place a `security_concern` hold, then Restore once the member's real details are known.

## RB6 Deactivation and handover

**When:** a member leaves the church (`member_request`, `moved_away`, `church_decision`), or a deactivated member returns.

**Who:** a Support Admin deactivates. Any other Admin restores after an identity check. Never your own record.

**Steps, deactivation** (**Membership status**, `/admin/membership-status`, **Find a member, Deactivate membership**):

1. Choose the reason and deactivate. Every session ends at once, every grant ends, and issued recovery grants are cancelled. The membership shows as deactivated; cell history and records are kept.
2. `conflict handover_required`: the member is the last responsible person for something an owner module tracks. Hand it over in that module's own screen first, then deactivate again.
3. Pending handovers are listed in **Membership status**. The owning module resolves each in its own workflow.
4. `forbidden last_admin`: the church's last usable Admin. Make another Admin first (RB1 step 3, or RB8 if none can act).

**Steps, restoration:**

1. A returning member: check their identity and **Restore membership** with the identity check.
2. The member signs in again. **No role or scope comes back**: grant them again only after a fresh decision.

**Never:**

- Deactivate to "fix" a sign-in problem. Use RB5.
- Restore a member who is being deleted (refused).

**Audit evidence:** `identity_membership_lifecycle` (`membership_deactivated`, `membership_restored`) with reason, identity check and counts (sessions, grants, recovery grants, obligations); `identity_access_audit` `role_revoked` and `scope_revoked`; handover obligations.

**Back out:** restoration undoes a deactivation (without grants). A deactivation undoes a wrong restoration.

## RB7 Deletion

**When:** a member asks for their data to be deleted.

**Who:**

- **The member, in the app** (mobile **Account, Delete my account**, with their password), when they can use the app.
- **A Support Admin**, for a member who cannot (no login, a held login, an account in review, or a deactivated membership). When the member has a live account, a DIFFERENT Admin must have placed the hold or the deactivation.
- **The restricted operator** runs the deletion worker.

**Preconditions:**

- The deletion function and the worker credential are set up ([identity-access.md, story 2.11](identity-access.md#hosted-parent-session--owner-2)).
- The worker's journal is the environment's recovery journal.
- In production, Q4 retention must be approved, or the erase waits (`policy_gate_closed`) while access is still denied at once.

**Steps:**

1. **The request:**
   - Member route: **Delete my account**, confirm "I understand that this cannot be undone", enter the password. The device signs out.
   - Staff route: **Member deletions** (`/admin/member-deletions`), find the member, choose the identity check, **Delete member**.
2. From this moment every session and sign-in of every account the member ever linked is refused.
3. Operator: run the worker (`tools/identity-deletion/worker.mjs run`, [identity-access.md, story 2.11](identity-access.md#the-worker-and-the-edge-function)) with the deletion credential file and the journal folder. Run one worker per journal. It can be stopped and run again; each run continues where the last stopped.
4. **Member deletions** shows each step. `handover_pending` waits for an owner module; `restore_held` waits for a restore to be reconciled; `policy_gate_closed` waits for Q4.
5. When it shows completed, tell the member (or their contact) that the deletion is complete. Their number can register again.

**Never:**

- Delete the church's last usable Admin (refused). Make another Admin first.
- Delete rows by hand to "finish" a deletion. If a step fails, run the worker again, and report a repeating failure.

**Audit evidence:** `identity_deletion_audit` (`deletion_requested`, `step_done`, `deletion_completed`); journal entries `access_revoked`, `deletion_manifest`, `deletion_completed` (opaque ids only); `sys_audit` per worker call.

**Back out:** none. Deletion cannot be undone, and a restore replays it from the journal. Before step 1, a login hold or a deactivation is the reversible alternative.

## RB8 Identity-checked last-Admin fallback

**When:** no Admin can act any more. Two cases:

| Case | Reason code | Typical cause |
|---|---|---|
| No usable Admin exists | `no_usable_admin` | every Admin is held, in review, dormant or banned |
| Admins exist on paper but none can act | `admins_unreachable` | the only Admin forgot the password and has no recovery email, lost every device, left the church without being deactivated, or died |

In the second case the bootstrap is refused, because the server still counts that Admin as usable, and every Admin-side exit (RB4, RB5, RB6) needs another Admin. Only use RB8 after trying to reach every Admin.

**Who:**

- **Both named recovery owners** together: `<named owner: fill at entry 14>` and `<named owner: fill at entry 14>`. They confirm that no Admin can act, choose the member who becomes Admin, and check that person's identity.
- **The restricted operator** runs the command. The operator may be one of the owners, but not the member who receives the role.
- **Two different people, always.** The command records a second named owner (`confirming_owner`, a short identifier such as `owner-two`) and refuses when it is empty or is the operator. The operator alone can never use RB8.

**Preconditions:**

- The chosen member is an existing, approved member who already uses the app: an account linked through an identity-checked approval or link (RB2), not on hold, not in review, not banned, not dormant, not deactivated, not being deleted, and not already an Admin.
- The chosen member holds **no scope grant** (care, finance, prayer, cell leader or assistant, or any other). A member with a scope is refused: choose someone else, or have the scope removed in its own module first.
- The member has signed in with their own password recently enough not to be dormant.
- The owners have written a restricted case note with a **case reference** (letters, digits and `._:/-`, no spaces, for example `RB8-2026-10-07-01`): the date, "RB8", the member id, the reason code, the identity check code, the two owners and the operator. No phone numbers or passwords.

**Steps:**

1. Owners: confirm the case (try to reach every Admin; read `select app.identity_usable_admin_count();` with the operator).
2. Owners: check the chosen member's identity together, in person (`in_person`) or by a relationship both already have (`established_relationship`).
3. Operator, in the SQL editor of that environment:

   ```sql
   select app.identity_admin_fallback_grant('<member_id>', '<in_person|established_relationship>',
                                            '<no_usable_admin|admins_unreachable>',
                                            '<confirming owner identifier>', '<case reference>', 'israel');
   ```

   It returns `{fallback_id, grant_id, member_id, reason_code, usable_admins_before, revision}`, nothing else. It is refused (no row written) when:
   - the reason does not match the real Admin state;
   - the identity check is missing or unknown;
   - the confirming owner is missing or is the operator, or the case reference is missing or not a reference;
   - the member is not eligible (including holding any scope);
   - the caller is not a restricted operator.
4. The role applies at once, to the member's next protected call, like any `identity.grant_role`: a session the member already has gains Admin, and nothing moves their sign-in epoch. If they are not signed in, they sign in on staff web with **their own** phone and password. Nobody else touches their credentials. **Roles & access** appears.
5. Every Admin sees the label **Admin by operator fallback** on that member in **Roles & access** (`admin_via_fallback` in the read) for as long as the grant lasts. An Admin who did not expect it raises it with the named owners at once.
6. The new Admin helps the unreachable Admin(s) back through the normal runbooks:
   - forgot password: RB4, with the old Admin present;
   - lost phone: RB5 `lost_device`, then RB4;
   - left the church: RB6, with handover;
   - in review: RB5.
7. When at least two Admins can act again, decide whether the fallback Admin keeps the role. If not, another Admin removes it in **Roles & access**.

**Never:**

- Set or reset a password, create a session or token, change an Auth row or use the Auth dashboard for anyone. The command touches no Auth data, and the rehearsal checks the member's password hash, sessions, refresh tokens, one-time tokens, factors, phone, email and ban before and after.
- Give the role to someone who has no app account yet, or to a member whose account is held or in review. Restore the account through the normal runbooks first.
- Give care, finance or any other scope with it.

**Audit evidence:**

- `identity_access_audit` `admin_fallback_granted` (actor `operator`, the member, the grant), distinct from the first-Admin `admin_bootstrapped`;
- `identity_admin_fallbacks` (reason, identity check, usable Admins before, operator, confirming owner, case reference);
- `ops_operator_actions` `admin_fallback_granted` with the grant id;
- the `admin_via_fallback` flag in Roles & access;
- the owners' restricted case note.

**Back out:** another Admin removes the role with `identity.revoke_role` in **Roles & access** (audited as `role_revoked`). The last usable Admin cannot be removed.

---

## Rehearsal

Local (automated, synthetic, fictional numbers `+44 7700 900700-900719`):

```bash
npx supabase db reset                          # empty Admin roster
node tools/auth-harness/local-phone-auth.mjs on
node tools/identity-e2e/runbooks.mjs --evidence <file>.jsonl
node tools/auth-harness/local-phone-auth.mjs off
```

It follows RB1 to RB8 through the same calls as staff web, mobile and the operator. It serves both Edge Functions, runs the real deletion worker and reads mail from the stack's Mailpit. It then checks:

- that no staff answer, operator output, worker output, function log or evidence line contains a password, a grant secret or digest, a request code, an email link or its code, a PKCE verifier, a member token or a system credential (with a positive control);
- that Admin-only support accounts get `403 not_granted` from the care, finance and cell-private fixtures;
- that RB8 needs a second owner, restores Admin access with no Auth change and no session minted, is flagged in Roles & access, and that the unreachable Admin comes back through RB4.

The owner's staging rehearsal is `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/evidence-2.12/owner-rehearsal.md`.
