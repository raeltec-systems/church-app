-- Recover a password through a verified same-account email (story 2.7; AD-3, AD-4, AD-20,
-- AC-06). Builds on the live-access predicate, the 2.2 credential detection and trust epoch,
-- holds, the 1.4 command envelope with the registered `identity` authorizer and the 2.5 review
-- pattern; nothing here forks them.
--
--   * A member adds an OPTIONAL recovery email to the SAME Auth account:
--       identity.propose_recovery_email  expected null   {email}
--     needs a granted session whose own password sign-in is at most 10 minutes old
--     (identity_recent_password_window()), and only while the approved binding has no recovery
--     email (replacing or removing one is the credential-change review of entry 8). The client
--     then calls native updateUser(email) on the same account; GoTrue's own email-change link
--     (PKCE, allowlisted redirect) verifies it. Until an Admin approves, the 2.2 detection keeps
--     the account in access review: AD-3 says an unapproved email change blocks private access.
--   * An Admin approves it into the credential binding after an identity check:
--       identity.approve_recovery_email  expected = proposal revision  {proposal_id, identity_check}
--       identity.reject_recovery_email   expected = proposal revision  {proposal_id, reason?}
--     and the member may withdraw their own pending proposal, also while in review:
--       identity.withdraw_recovery_email expected = proposal revision  {proposal_id}
--     Approval records binding revision n+1 with the email (clearing the 2.2 binding review),
--     returns the link to `active` and moves the trust epoch, so the member signs in again. It is
--     refused unless the current Auth email equals the proposal and is confirmed, the Auth phone
--     equals the approved phone, the account has no MFA factor and only phone/email identities,
--     and no other binding change (phone, delete, identity removed/moved, MFA) happened since the
--     proposal, or when the Auth email change came before the proposal (credential event time).
--     Reject and withdraw return the account to its approved binding (the lockout exit): the
--     proposed address leaves auth.users (pending or confirmed), its email-change tokens are
--     cleared, and the review it caused is lifted with a new binding revision.
--   * The reset gate: GoTrue's public /recover (and magic-link) routes stay reachable, so the
--     redemption itself is guarded. An auth.users trigger on recovery-token redemption (the
--     token cleared with the password unchanged; GoTrue v2.197.0 writes exactly that row update
--     at /verify) refuses unless the account's live link is `active` with no binding review, the
--     member is approved, the approved recovery email equals the current, CONFIRMED Auth email,
--     the Auth phone equals the approved phone, the account is not deleted or banned, and email
--     recovery is open (q1_auth_recovery approved, or a database marked local/staging; never a
--     held restore). Holds and dormancy do not block the reset and stay in force. A refused
--     redemption fails GoTrue's verify, so no recovery session exists. An allowed redemption is
--     recorded as the credential event `email_link_redeemed` (kind only, no epoch move); the
--     password set that follows moves the epoch through the 2.2 trigger, and GoTrue signs out
--     every other session.
--   * Recovery sessions (AMR `recovery`/`otp`) never pass the predicate (2.2), so they read no
--     private data; the clients use them only to set the password, then require a fresh
--     password sign-in.
--   * Reads: api.identity_my_recovery_email() (the member's own state, also while in review)
--     and api.identity_admin_recovery_email_queue() (Admin). Audit: app.identity_credential_audit
--     (ids, codes and revisions only; never the email).
--
-- Personal data: proposals need app.identity_applications_open(); while Q4 is unapproved the
-- email must be synthetic (@example.test/.com, .invalid) or, in staging only, one of the
-- owner-approved israelmuyoba+<tag>@gmail.com inboxes. Emails are plain ASCII addresses.
--
-- No destructive statements and no row deletions. No client table privileges.

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

create table app.identity_recovery_email_proposals (
  proposal_id uuid primary key default gen_random_uuid(),
  link_id uuid not null references app.identity_account_links (link_id),
  member_id uuid not null references app.identity_members (member_id),
  auth_user_id uuid not null,
  email text not null check (
    email = lower(email) and length(email) between 6 and 254
    and email ~ '^[a-z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-z0-9-]+(\.[a-z0-9-]+)+$'),
  proposal_state text not null default 'pending'
    check (proposal_state in ('pending', 'approved', 'rejected', 'superseded', 'withdrawn')),
  revision bigint not null default 1 check (revision >= 1),
  is_synthetic boolean not null,
  proposed_request_id uuid,
  proposed_at timestamptz not null default clock_timestamp(),
  decided_at timestamptz,
  decided_by_member uuid references app.identity_members (member_id),
  decided_by_account uuid,
  identity_check text check (identity_check in ('established_relationship', 'in_person')),
  decision_reason text check (decision_reason in ('identity_not_confirmed', 'contact_church_office')),
  binding_revision_after bigint,
  check ((proposal_state = 'pending') = (decided_at is null)),
  check (decision_reason is null or proposal_state = 'rejected'),
  check ((proposal_state = 'approved') = (binding_revision_after is not null)),
  check (proposal_state <> 'approved' or identity_check is not null),
  check ((proposal_state in ('approved', 'rejected'))
         = (decided_by_member is not null and decided_by_account is not null))
);

comment on table app.identity_recovery_email_proposals is
  'owner: identity. A member''s request to add a recovery email to the same Auth account, and '
  'the Admin decision that approves it into the credential binding (story 2.7).';

create unique index identity_recovery_email_one_pending
  on app.identity_recovery_email_proposals (link_id) where proposal_state = 'pending';
create index identity_recovery_email_by_link
  on app.identity_recovery_email_proposals (link_id, proposed_at);

-- Content-free: ids, codes and revisions only. Never the email address.
create table app.identity_credential_audit (
  event_id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  environment text not null default app.platform_current_environment(),
  action text not null check (action in (
    'recovery_email_proposed', 'recovery_email_superseded', 'recovery_email_approved',
    'recovery_email_rejected', 'recovery_email_withdrawn', 'recovery_email_reverted')),
  actor_member_id uuid not null,
  actor_account_id uuid not null,
  request_id uuid,
  proposal_id uuid not null,
  member_id uuid not null,
  link_id uuid not null,
  identity_check text check (identity_check in ('established_relationship', 'in_person')),
  reason_code text check (reason_code ~ '^[a-z][a-z0-9_]{0,62}$'),
  binding_revision_after bigint,
  revision_after bigint not null
);

comment on table app.identity_credential_audit is
  'owner: identity. Attributed recovery-email proposals and decisions (AD-4, AD-19): ids, codes '
  'and revisions only.';

create index identity_credential_audit_member on app.identity_credential_audit (member_id, event_id);

alter table app.identity_recovery_email_proposals enable row level security;
alter table app.identity_credential_audit enable row level security;
revoke all on table app.identity_recovery_email_proposals, app.identity_credential_audit
  from public, anon, authenticated, service_role;
revoke all on sequence app.identity_credential_audit_event_id_seq
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Settings and gates
-- ---------------------------------------------------------------------------------------------

-- A credential change needs a password sign-in at most this old on the calling session.
create function app.identity_recent_password_window()
returns interval
language sql
immutable
set search_path = ''
as $$ select interval '10 minutes' $$;

-- Abuse limit: proposals per link per rolling 24 hours.
create function app.identity_recovery_email_proposal_limit()
returns integer
language sql
immutable
set search_path = ''
as $$ select 5 $$;

-- Email recovery (Q1: email delivery and recovery procedure) is open when the owner approved
-- q1_auth_recovery, or in a database marked local/staging; never while serving a held restore.
create function app.identity_email_recovery_open()
returns boolean
language sql
set search_path = ''
as $$
  select not app.rcv_serving_hold()
     and (app.policy_is_open('q1_auth_recovery')
          or app.platform_current_environment() in ('local', 'staging'));
$$;

-- While Q4 is unapproved only synthetic addresses may be stored: example/.invalid domains, and
-- in staging the owner-approved test inboxes israelmuyoba+<tag>@gmail.com.
create function app.identity_recovery_email_permitted(p_email text)
returns boolean
language sql
set search_path = ''
as $$
  select app.policy_is_open('q4_personal_data')
      or p_email ~ '(@example\.(test|com)|\.invalid)$'
      or (app.platform_current_environment() = 'staging'
          and p_email ~ '^israelmuyoba\+[a-z0-9._-]{1,40}@gmail\.com$');
$$;

-- The calling session (JWT session_id) holds a server-recorded password sign-in within the
-- window. Used after the predicate granted the same session.
create function app.identity_session_recent_password()
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
      from auth.mfa_amr_claims c
     where c.session_id = nullif(app.identity_request_claims() ->> 'session_id', '')::uuid
       and c.authentication_method = 'password'
       and greatest(c.created_at, c.updated_at) > now() - app.identity_recent_password_window());
$$;

-- ---------------------------------------------------------------------------------------------
-- The reset gate on recovery-link redemption
-- ---------------------------------------------------------------------------------------------

-- May the Auth account with these CURRENT values redeem an email link (recovery or magic link)?
create function app.identity_email_recovery_eligible(
  p_auth_user_id uuid,
  p_email text,
  p_email_confirmed_at timestamptz,
  p_phone text,
  p_deleted_at timestamptz,
  p_banned_until timestamptz
) returns boolean
language sql
set search_path = ''
as $$
  select p_deleted_at is null
     and (p_banned_until is null or p_banned_until <= now())
     and p_email_confirmed_at is not null
     and nullif(btrim(coalesce(p_email, '')), '') is not null
     and exists (
       select 1
         from app.identity_account_links l
         join app.identity_members m on m.member_id = l.member_id
        where l.auth_user_id = p_auth_user_id
          and l.link_state = 'active'
          and not l.binding_review_required
          and m.membership_state = 'approved'
          and l.approved_recovery_email is not null
          and l.approved_recovery_email = lower(btrim(p_email))
          and l.approved_phone = '+' || ltrim(nullif(btrim(coalesce(p_phone, '')), ''), '+'))
     and app.identity_email_recovery_open();
$$;

create function app.identity_on_auth_email_link_redeemed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app.identity_email_recovery_eligible(new.id, new.email, new.email_confirmed_at, new.phone,
                                              new.deleted_at, new.banned_until) then
    -- Fails GoTrue's /verify: no recovery or magic-link session is created. The message names no
    -- account, email or reason.
    raise exception using errcode = '42501', message = 'email link not accepted';
  end if;
  insert into app.identity_credential_events (link_id, source, kinds, binding_review,
                                              generation_after, epoch_after)
  select l.link_id, 'auth_users', array['email_link_redeemed'], false, l.credential_generation,
         l.sessions_valid_after
    from app.identity_account_links l
   where l.auth_user_id = new.id and l.link_state <> 'ended';
  return new;
end;
$$;

-- Redemption = the recovery token cleared while the password is unchanged (a password update
-- also clears the token, in the same row update, and is not a redemption).
create trigger identity_email_link_gate
  before update of recovery_token on auth.users
  for each row
  when (coalesce(old.recovery_token, '') <> ''
        and coalesce(new.recovery_token, '') = ''
        and old.encrypted_password is not distinct from new.encrypted_password)
  execute function app.identity_on_auth_email_link_redeemed();

-- ---------------------------------------------------------------------------------------------
-- Views of a proposal
-- ---------------------------------------------------------------------------------------------

-- Auth currently holds exactly this email, confirmed, for the proposal's account.
create function app.identity_recovery_email_verified(p_row app.identity_recovery_email_proposals)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from auth.users u
     where u.id = p_row.auth_user_id
       and lower(nullif(btrim(u.email), '')) = p_row.email
       and u.email_confirmed_at is not null);
$$;

-- Binding-relevant Auth changes on the proposal's account other than adding this email: a
-- changed phone, an MFA factor, a non-phone/email identity, an email identity for another
-- address, or a recorded phone/delete/identity-removed/moved/MFA change since the proposal.
create function app.identity_recovery_email_other_changes(
  p_row app.identity_recovery_email_proposals
) returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
           select 1 from auth.users u
             join app.identity_account_links l on l.link_id = p_row.link_id
            where u.id = p_row.auth_user_id
              and ('+' || ltrim(nullif(btrim(coalesce(u.phone, '')), ''), '+'))
                  is distinct from l.approved_phone)
      or exists (select 1 from auth.mfa_factors f where f.user_id = p_row.auth_user_id)
      or exists (
           select 1 from auth.identities i
            where i.user_id = p_row.auth_user_id
              and (i.provider not in ('phone', 'email')
                   or (i.provider = 'email'
                       and lower(coalesce(i.identity_data ->> 'email', '')) <> p_row.email
                       -- Auth keeps the email identity of an address that was later
                       -- rejected or withdrawn (and reverted); that is not a new change.
                       and not exists (
                         select 1 from app.identity_recovery_email_proposals q
                          where q.link_id = p_row.link_id
                            and q.proposal_state in ('rejected', 'withdrawn')
                            and q.email = lower(coalesce(i.identity_data ->> 'email', ''))))))
      or exists (
           select 1 from app.identity_credential_events e
            where e.link_id = p_row.link_id
              and e.at >= p_row.proposed_at
              and e.kinds && array['phone', 'soft_deleted', 'user_deleted', 'identity_removed',
                                   'identity_moved', 'mfa_added', 'mfa_changed', 'mfa_removed']);
$$;

-- The member's own view (their address is theirs to see).
create function app.identity_recovery_email_member_json(p_row app.identity_recovery_email_proposals)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'proposal_id', p_row.proposal_id,
    'revision', p_row.revision,
    'email', p_row.email,
    'state', p_row.proposal_state,
    'verified', app.identity_recovery_email_verified(p_row),
    'proposed_at', p_row.proposed_at,
    'decided_at', p_row.decided_at,
    'decision_reason', p_row.decision_reason));
$$;

-- The Admin's view: the member's name, the address, verification, other changes, own account.
create function app.identity_recovery_email_admin_json(p_row app.identity_recovery_email_proposals)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select app.identity_recovery_email_member_json(p_row) || jsonb_build_object(
    'member_id', p_row.member_id,
    'display_name', (select m.display_name from app.identity_members m
                      where m.member_id = p_row.member_id),
    'phone_username', (select l.approved_phone from app.identity_account_links l
                        where l.link_id = p_row.link_id),
    'access_review', (select l.link_state <> 'active' or l.binding_review_required
                        from app.identity_account_links l where l.link_id = p_row.link_id),
    'other_changes', app.identity_recovery_email_other_changes(p_row),
    'own_account', p_row.auth_user_id
                   = nullif(app.identity_request_claims() ->> 'sub', '')::uuid,
    'is_synthetic', p_row.is_synthetic);
$$;

create function app.identity_recovery_email_outcome(p_proposal_id uuid, p_admin boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'identity_recovery_email_proposal',
    'aggregate_id', p.proposal_id,
    'revision', p.revision,
    'data', case when p_admin then app.identity_recovery_email_admin_json(p)
                 else app.identity_recovery_email_member_json(p) end)
    from app.identity_recovery_email_proposals p
   where p.proposal_id = p_proposal_id;
$$;

create function app.identity_credential_audit_add(
  p_action text,
  p_actor_member uuid,
  p_actor_account uuid,
  p_request uuid,
  p_row app.identity_recovery_email_proposals,
  p_identity_check text,
  p_reason text,
  p_binding_revision bigint
) returns void
language sql
set search_path = ''
as $$
  insert into app.identity_credential_audit (action, actor_member_id, actor_account_id, request_id,
                                             proposal_id, member_id, link_id, identity_check,
                                             reason_code, binding_revision_after, revision_after)
  values (p_action, p_actor_member, p_actor_account, p_request, p_row.proposal_id, p_row.member_id,
          p_row.link_id, p_identity_check, p_reason, p_binding_revision, p_row.revision);
$$;

-- ---------------------------------------------------------------------------------------------
-- Member command
-- ---------------------------------------------------------------------------------------------

-- identity.propose_recovery_email {email}: the granted member's own account, fresh password.
create function app.identity_propose_recovery_email(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  r record;
  v_errors jsonb;
  v_email text;
  v_link app.identity_account_links;
  v_member app.identity_members;
  v_prior app.identity_recovery_email_proposals;
  v_row app.identity_recovery_email_proposals;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.propose_recovery_email');
begin
  select e.* into r from app.identity_access_evaluate() e;
  if r.outcome is distinct from 'granted' then
    perform app.cmd_fail('forbidden');
  end if;
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, array['email']);
  if coalesce(jsonb_typeof(p_payload -> 'email'), 'null') = 'null' then
    v_errors := v_errors || '{"email": "required"}';
  elsif jsonb_typeof(p_payload -> 'email') <> 'string' then
    v_errors := v_errors || '{"email": "invalid"}';
  else
    v_email := lower(btrim(p_payload ->> 'email'));
    if length(v_email) not between 6 and 254
       or v_email !~ '^[a-z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-z0-9-]+(\.[a-z0-9-]+)+$' then
      v_errors := v_errors || '{"email": "invalid"}';
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  if not app.identity_applications_open() or not app.identity_email_recovery_open() then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  if not app.identity_recovery_email_permitted(v_email) then
    perform app.cmd_fail('validation_failed', '{"email": "unsupported"}');
  end if;
  if not app.identity_session_recent_password() then
    perform app.cmd_fail('forbidden', '{"session": "reauthenticate"}');
  end if;

  select l.* into v_link from app.identity_account_links l where l.link_id = r.link_id for update;
  if v_link.link_state <> 'active' or v_link.binding_review_required
     or v_link.auth_user_id <> p_actor then
    perform app.cmd_fail('forbidden');
  end if;
  if v_link.approved_recovery_email is not null then
    -- Replacing or removing an approved recovery email is the entry 8 credential review.
    perform app.cmd_fail('validation_failed', '{"email": "already_approved"}');
  end if;
  if (select count(*) from app.identity_recovery_email_proposals p
       where p.link_id = v_link.link_id
         and p.proposed_at > now() - interval '24 hours')
     >= app.identity_recovery_email_proposal_limit() then
    perform app.cmd_fail('rate_limited');
  end if;
  select m.* into v_member from app.identity_members m where m.member_id = v_link.member_id;

  for v_prior in
    update app.identity_recovery_email_proposals p
       set proposal_state = 'superseded', decided_at = now(), revision = p.revision + 1
     where p.link_id = v_link.link_id and p.proposal_state = 'pending'
    returning p.*
  loop
    perform app.identity_credential_audit_add('recovery_email_superseded', v_member.member_id,
      p_actor, v_request, v_prior, null, null, null);
  end loop;

  insert into app.identity_recovery_email_proposals (link_id, member_id, auth_user_id, email,
                                                     is_synthetic, proposed_request_id)
  values (v_link.link_id, v_member.member_id, p_actor, v_email, v_member.is_synthetic, v_request)
  returning * into v_row;
  perform app.identity_credential_audit_add('recovery_email_proposed', v_member.member_id, p_actor,
    v_request, v_row, null, null, null);
  perform app.identity_record_activity(v_link.link_id);
  return app.identity_recovery_email_outcome(v_row.proposal_id, false);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Admin commands
-- ---------------------------------------------------------------------------------------------

-- Validates {proposal_id, identity_check?, reason?}, then locks the pending proposal at the
-- expected revision. The Admin's own account is refused (separation of duty).
create function app.identity_lock_recovery_email_proposal(
  p_payload jsonb,
  p_allowed text[],
  p_identity_check_required boolean,
  p_expected_revision bigint,
  p_actor_account uuid
) returns app.identity_recovery_email_proposals
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_err text;
  v_row app.identity_recovery_email_proposals;
begin
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, p_allowed);
  v_err := app.contract_uuid_error(p_payload -> 'proposal_id');
  if v_err is not null then
    v_errors := v_errors || jsonb_build_object('proposal_id', v_err);
  end if;
  if 'identity_check' = any (p_allowed) then
    v_err := app.identity_check_value(p_payload -> 'identity_check', p_identity_check_required);
    if v_err is not null then
      v_errors := v_errors || jsonb_build_object('identity_check', v_err);
    end if;
  end if;
  if 'reason' = any (p_allowed) and coalesce(jsonb_typeof(p_payload -> 'reason'), 'null') <> 'null'
     and (jsonb_typeof(p_payload -> 'reason') <> 'string'
          or p_payload ->> 'reason' not in ('identity_not_confirmed', 'contact_church_office')) then
    v_errors := v_errors || '{"reason": "invalid"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  select p.* into v_row from app.identity_recovery_email_proposals p
   where p.proposal_id = (p_payload ->> 'proposal_id')::uuid
     for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_row.auth_user_id = p_actor_account then
    perform app.cmd_fail('forbidden', '{"proposal_id": "unsupported"}');
  end if;
  if v_row.proposal_state <> 'pending' or v_row.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_row.revision);
  end if;
  return v_row;
end;
$$;

-- identity.approve_recovery_email {proposal_id, identity_check}
create function app.identity_approve_recovery_email(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_row app.identity_recovery_email_proposals;
  v_link app.identity_account_links;
  v_by text;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.approve_recovery_email');
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_by := 'admin:' || v_actor.member_id::text;
  v_row := app.identity_lock_recovery_email_proposal(p_payload,
    array['proposal_id', 'identity_check'], true, p_expected_revision, v_actor.account_id);
  if not app.identity_applications_open() or not app.identity_email_recovery_open() then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  select l.* into v_link from app.identity_account_links l where l.link_id = v_row.link_id
     for update;
  if v_link.link_state not in ('active', 'review_required')
     or v_link.auth_user_id <> v_row.auth_user_id
     or v_link.approved_recovery_email is not null
     or not exists (select 1 from app.identity_members m
                     where m.member_id = v_link.member_id and m.membership_state = 'approved') then
    perform app.cmd_fail('conflict', '{"proposal_id": "stale"}', v_row.revision);
  end if;
  if not exists (select 1 from auth.users u
                  where u.id = v_row.auth_user_id and u.deleted_at is null
                    and not coalesce(u.is_anonymous, false)
                    and (u.banned_until is null or u.banned_until <= now())) then
    perform app.cmd_fail('conflict', '{"proposal_id": "stale"}', v_row.revision);
  end if;
  if not app.identity_recovery_email_verified(v_row) then
    perform app.cmd_fail('validation_failed', '{"recovery_email": "unverified"}');
  end if;
  -- The proposal must come before the Auth email change (by the 2.2 credential event time):
  -- an address confirmed before the member proposed it is not this flow. The proposal's own
  -- recent-password check is otherwise advisory: GoTrue's updateUser does not re-check it.
  if coalesce((select max(e.at) from app.identity_credential_events e
                where e.link_id = v_row.link_id and 'email' = any (e.kinds)), '-infinity')
     <= v_row.proposed_at then
    perform app.cmd_fail('conflict', '{"proposal_id": "stale"}', v_row.revision);
  end if;
  if app.identity_recovery_email_other_changes(v_row) then
    -- Anything beyond adding this email goes to the credential-change review (entry 8).
    perform app.cmd_fail('conflict', '{"proposal_id": "other_changes"}', v_row.revision);
  end if;

  -- New binding revision (clears the 2.2 binding review), link active again, and a trust epoch
  -- now: only sessions opened after the approval pass.
  update app.identity_account_links l
     set approved_recovery_email = v_row.email,
         binding_revision = l.binding_revision + 1,
         link_state = 'active',
         approved_by = v_by,
         sessions_valid_after = greatest(coalesce(l.sessions_valid_after, '-infinity'),
                                         clock_timestamp()),
         updated_at = now()
   where l.link_id = v_link.link_id
  returning l.* into v_link;
  insert into app.identity_binding_history (link_id, binding_revision, approved_phone,
                                            approved_recovery_email, approved_by, reason)
  values (v_link.link_id, v_link.binding_revision, v_link.approved_phone,
          v_link.approved_recovery_email, v_by, 'recovery_email_approved');

  update app.identity_recovery_email_proposals p
     set proposal_state = 'approved', revision = p.revision + 1, decided_at = now(),
         decided_by_member = v_actor.member_id, decided_by_account = v_actor.account_id,
         identity_check = p_payload ->> 'identity_check',
         binding_revision_after = v_link.binding_revision
   where p.proposal_id = v_row.proposal_id
  returning p.* into v_row;
  perform app.identity_credential_audit_add('recovery_email_approved', v_actor.member_id,
    v_actor.account_id, v_request, v_row, v_row.identity_check, null, v_link.binding_revision);
  return app.identity_recovery_email_outcome(v_row.proposal_id, true);
end;
$$;

-- Returns the proposal's account to its approved binding: the lockout exit. The Identity owner
-- runs it as the server-side principal for this one allowlisted effect, on behalf of the
-- deciding Admin or the member. Both are audited separately: `recovery_email_rejected` or
-- `_withdrawn` names the initiator; `recovery_email_reverted` records the executed effect. The
-- Auth write is the same kind as the 2.5 reclaim's:
--   * the proposed address leaves auth.users, whether pending (email_change) or confirmed but
--     unapproved (email);
--   * its email-change tokens are cleared, and the one_time_tokens rows are neutralised, so a
--     confirmation link opened later changes nothing;
--   * the review this change caused is lifted with a new binding revision (same phone, same
--     approved email). The link returns to `active`, which also moves the trust epoch, so the
--     member signs in again. When anything else changed (other_changes), the review stays for
--     the entry 8 credential review.
-- Returns true when the access review was lifted.
create function app.identity_revert_recovery_email(
  p_row app.identity_recovery_email_proposals,
  p_by text
) returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_link app.identity_account_links;
  v_other boolean;
begin
  select l.* into v_link from app.identity_account_links l where l.link_id = p_row.link_id
     for update;
  if v_link.link_state = 'ended' or v_link.auth_user_id <> p_row.auth_user_id then
    return false;
  end if;
  v_other := app.identity_recovery_email_other_changes(p_row);
  update auth.users u
     set email = case when lower(nullif(btrim(u.email), '')) = p_row.email
                      then v_link.approved_recovery_email else u.email end,
         email_confirmed_at = case when lower(nullif(btrim(u.email), '')) = p_row.email
                                        and v_link.approved_recovery_email is null
                                   then null else u.email_confirmed_at end,
         email_change = case when lower(coalesce(u.email_change, '')) = p_row.email
                             then '' else u.email_change end,
         email_change_token_new = case when lower(coalesce(u.email_change, '')) = p_row.email
                                       then '' else u.email_change_token_new end,
         email_change_token_current = case when lower(coalesce(u.email_change, '')) = p_row.email
                                           then '' else u.email_change_token_current end,
         email_change_confirm_status = case when lower(coalesce(u.email_change, '')) = p_row.email
                                            then 0 else u.email_change_confirm_status end,
         email_change_sent_at = case when lower(coalesce(u.email_change, '')) = p_row.email
                                     then null else u.email_change_sent_at end
   where u.id = p_row.auth_user_id
     and (lower(nullif(btrim(u.email), '')) = p_row.email
          or lower(coalesce(u.email_change, '')) = p_row.email);
  -- GoTrue also looks email-change tokens up here: make any outstanding one unusable.
  update auth.one_time_tokens t
     set token_hash = 'revoked-' || gen_random_uuid()::text, updated_at = now()
   where t.user_id = p_row.auth_user_id
     and t.token_type in ('email_change_token_new', 'email_change_token_current');
  select l.* into v_link from app.identity_account_links l where l.link_id = p_row.link_id;
  if v_other or not v_link.binding_review_required
     or v_link.link_state not in ('active', 'review_required') then
    return false;
  end if;
  update app.identity_account_links l
     set binding_revision = l.binding_revision + 1,
         link_state = 'active',
         sessions_valid_after = greatest(coalesce(l.sessions_valid_after, '-infinity'),
                                         clock_timestamp()),
         updated_at = now()
   where l.link_id = v_link.link_id
  returning l.* into v_link;
  insert into app.identity_binding_history (link_id, binding_revision, approved_phone,
                                            approved_recovery_email, approved_by, reason)
  values (v_link.link_id, v_link.binding_revision, v_link.approved_phone,
          v_link.approved_recovery_email, p_by, 'recovery_email_reverted');
  return true;
end;
$$;

-- identity.reject_recovery_email {proposal_id, reason?}: the decision, then the account back on
-- its approved binding (app.identity_revert_recovery_email).
create function app.identity_reject_recovery_email(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_row app.identity_recovery_email_proposals;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.reject_recovery_email');
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_row := app.identity_lock_recovery_email_proposal(p_payload,
    array['proposal_id', 'reason'], false, p_expected_revision, v_actor.account_id);
  update app.identity_recovery_email_proposals p
     set proposal_state = 'rejected', revision = p.revision + 1, decided_at = now(),
         decided_by_member = v_actor.member_id, decided_by_account = v_actor.account_id,
         decision_reason = p_payload ->> 'reason'
   where p.proposal_id = v_row.proposal_id
  returning p.* into v_row;
  perform app.identity_credential_audit_add('recovery_email_rejected', v_actor.member_id,
    v_actor.account_id, v_request, v_row, null, v_row.decision_reason, null);
  if app.identity_revert_recovery_email(v_row, 'admin:' || v_actor.member_id::text) then
    perform app.identity_credential_audit_add('recovery_email_reverted', v_actor.member_id,
      v_actor.account_id, v_request, v_row, null, null,
      (select l.binding_revision from app.identity_account_links l where l.link_id = v_row.link_id));
  end if;
  return app.identity_recovery_email_outcome(v_row.proposal_id, true);
end;
$$;

-- identity.withdraw_recovery_email {proposal_id} (expected = proposal revision): the member's
-- own pending proposal only, also while the account waits in review (the lockout exit). The
-- account returns to its approved binding (app.identity_revert_recovery_email).
create function app.identity_withdraw_recovery_email(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  r record;
  v_errors jsonb;
  v_err text;
  v_row app.identity_recovery_email_proposals;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.withdraw_recovery_email');
begin
  select e.* into r from app.identity_access_evaluate() e;
  if r.outcome not in ('granted', 'review_required') or r.link_id is null then
    perform app.cmd_fail('forbidden');
  end if;
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, array['proposal_id']);
  v_err := app.contract_uuid_error(p_payload -> 'proposal_id');
  if v_err is not null then
    v_errors := v_errors || jsonb_build_object('proposal_id', v_err);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  select p.* into v_row from app.identity_recovery_email_proposals p
   where p.proposal_id = (p_payload ->> 'proposal_id')::uuid
     for update;
  -- Another account's proposal is indistinguishable from a missing one.
  if not found or v_row.auth_user_id <> p_actor or v_row.link_id <> r.link_id then
    perform app.cmd_fail('not_found');
  end if;
  if v_row.proposal_state <> 'pending' or v_row.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_row.revision);
  end if;
  update app.identity_recovery_email_proposals p
     set proposal_state = 'withdrawn', revision = p.revision + 1, decided_at = now()
   where p.proposal_id = v_row.proposal_id
  returning p.* into v_row;
  perform app.identity_credential_audit_add('recovery_email_withdrawn', v_row.member_id, p_actor,
    v_request, v_row, null, null, null);
  if app.identity_revert_recovery_email(v_row, 'member:' || v_row.member_id::text) then
    perform app.identity_credential_audit_add('recovery_email_reverted', v_row.member_id, p_actor,
      v_request, v_row, null, null,
      (select l.binding_revision from app.identity_account_links l where l.link_id = v_row.link_id));
  end if;
  return app.identity_recovery_email_outcome(v_row.proposal_id, false);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Command endpoint and authorizer
-- ---------------------------------------------------------------------------------------------

create function app.identity_recovery_email_in_scope(p_actor uuid, p_aggregate_type text,
                                                     p_aggregate_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_aggregate_type = 'identity_recovery_email_proposal'
     and exists (select 1 from app.identity_recovery_email_proposals p
                  where p.proposal_id = p_aggregate_id);
$$;

create function app.identity_recovery_email_command(p_envelope jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_command text;
begin
  if jsonb_typeof(p_envelope) = 'object' and jsonb_typeof(p_envelope -> 'command') = 'string' then
    v_command := p_envelope ->> 'command';
  end if;
  return app.cmd_execute(
    p_envelope,
    case v_command
      when 'identity.propose_recovery_email'
        then 'app.identity_propose_recovery_email(uuid, bigint, jsonb)'::regprocedure
      when 'identity.approve_recovery_email'
        then 'app.identity_approve_recovery_email(uuid, bigint, jsonb)'::regprocedure
      when 'identity.reject_recovery_email'
        then 'app.identity_reject_recovery_email(uuid, bigint, jsonb)'::regprocedure
      when 'identity.withdraw_recovery_email'
        then 'app.identity_withdraw_recovery_email(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.identity_recovery_email_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'identity.propose_recovery_email'
  );
end;
$$;

-- POST /rest/v1/rpc/identity_recovery_email_command, Content-Profile: api,
-- body {version, command, request_id, expected_revision, payload}.
create function api.identity_recovery_email_command(jsonb)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.identity_recovery_email_command($1);
$$;

comment on function api.identity_recovery_email_command(jsonb) is
  'Story 2.7: a member proposes a recovery email for the same account; an Admin approves it into '
  'the credential binding or rejects it (1.4 command envelope).';

-- Member credential commands: a granted (live, approved, current-binding) session.
create function app.identity_authorize_member_credential_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  select e.* into r from app.identity_access_evaluate() e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  return r.outcome = 'granted';
end;
$$;

-- Withdrawing one's own proposal: a trusted password session of a linked account, also while
-- access waits in review (granted or review_required), so the member is never stuck.
create function app.identity_authorize_member_withdraw_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  select e.* into r from app.identity_access_evaluate() e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  return r.outcome in ('granted', 'review_required') and r.link_id is not null;
end;
$$;

-- The registered `identity` authorizer: application commands keep the 2.4 applicant check, the
-- member recovery-email proposal needs a granted session, the withdrawal a linked trusted
-- session (also in review), and the grant, review (2.5) and
-- recovery-email decision commands share the 2.3 Admin branch unchanged.
create or replace function app.identity_authorize_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  if coalesce(p_request ->> 'command', '') in ('identity.submit_application',
                                                'identity.correct_application') then
    return app.identity_authorize_application_command(p_request);
  end if;
  if coalesce(p_request ->> 'command', '') = 'identity.propose_recovery_email' then
    return app.identity_authorize_member_credential_command(p_request);
  end if;
  if coalesce(p_request ->> 'command', '') = 'identity.withdraw_recovery_email' then
    return app.identity_authorize_member_withdraw_command(p_request);
  end if;
  if coalesce(p_request ->> 'command', '') not in (
       'identity.grant_role', 'identity.revoke_role', 'identity.grant_scope',
       'identity.revoke_scope',
       'identity.approve_application', 'identity.link_application',
       'identity.request_application_details', 'identity.reject_application',
       'identity.create_member', 'identity.unlink_account', 'identity.reclaim_phone_username',
       'identity.approve_recovery_email', 'identity.reject_recovery_email') then
    return false;
  end if;
  select e.* into r from app.identity_evaluate_grant('admin', null, null) e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  if r.outcome <> 'granted' then
    return false;
  end if;
  perform 1 from app.identity_roles ro where ro.role = 'admin' for update;
  perform 1 from app.identity_grants g
   where g.member_id = r.member_id and g.role = 'admin' and g.revoked_at is null
     for share;
  return found;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------------------------

-- The member's own recovery-email state, also while the account is in review (for example while
-- a verified email waits for approval). Signed-out/untrusted: 401; not linked: 403.
create function app.identity_my_recovery_email()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_link app.identity_account_links;
  v_latest app.identity_recovery_email_proposals;
begin
  select e.* into r from app.identity_access_evaluate() e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    raise exception using errcode = 'PT401', message = 'unauthenticated', detail = r.outcome;
  elsif r.outcome = 'unavailable' then
    raise exception using errcode = 'PT403', message = 'unavailable', detail = r.outcome;
  elsif r.outcome not in ('granted', 'review_required') or r.link_id is null then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = r.outcome;
  end if;
  select l.* into v_link from app.identity_account_links l where l.link_id = r.link_id;
  select p.* into v_latest from app.identity_recovery_email_proposals p
   where p.link_id = v_link.link_id
   order by p.proposed_at desc, p.proposal_id
   limit 1;
  if r.outcome = 'granted' then
    perform app.identity_record_activity(v_link.link_id);
  end if;
  return jsonb_build_object(
    'access', r.outcome,
    'approved_email', v_link.approved_recovery_email,
    'proposal', case when v_latest.proposal_id is null then null
                     else app.identity_recovery_email_member_json(v_latest) end,
    'can_propose', r.outcome = 'granted' and v_link.approved_recovery_email is null
                   and app.identity_applications_open() and app.identity_email_recovery_open(),
    'recent_sign_in_minutes', extract(epoch from app.identity_recent_password_window())::int / 60);
end;
$$;

create function api.identity_my_recovery_email()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.identity_my_recovery_email();
$$;

comment on function api.identity_my_recovery_email() is
  'Story 2.7: the signed-in member''s own recovery email (approved address and the latest '
  'proposal). POST /rest/v1/rpc/identity_my_recovery_email with Content-Profile: api.';

-- Admin only: pending recovery-email proposals, oldest first (at most 100).
create function app.identity_admin_recovery_email_queue()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link_id uuid;
  v_rows jsonb;
begin
  select g.link_id into v_link_id from app.identity_require_grant('admin', null, null) g;
  select coalesce(jsonb_agg(app.identity_recovery_email_admin_json(x) order by x.proposed_at,
                            x.proposal_id), '[]'::jsonb)
    into v_rows
    from (select p.* from app.identity_recovery_email_proposals p
           where p.proposal_state = 'pending'
           order by p.proposed_at, p.proposal_id
           limit 100) x;
  perform app.identity_record_activity(v_link_id);
  return jsonb_build_object('proposals', v_rows);
end;
$$;

create function api.identity_admin_recovery_email_queue()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.identity_admin_recovery_email_queue();
$$;

comment on function api.identity_admin_recovery_email_queue() is
  'Story 2.7: Admin-only queue of pending recovery-email proposals with verification state.';

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.identity_recent_password_window(),
  app.identity_recovery_email_proposal_limit(),
  app.identity_email_recovery_open(),
  app.identity_recovery_email_permitted(text),
  app.identity_session_recent_password(),
  app.identity_email_recovery_eligible(uuid, text, timestamptz, text, timestamptz, timestamptz),
  app.identity_on_auth_email_link_redeemed(),
  app.identity_recovery_email_verified(app.identity_recovery_email_proposals),
  app.identity_recovery_email_other_changes(app.identity_recovery_email_proposals),
  app.identity_recovery_email_member_json(app.identity_recovery_email_proposals),
  app.identity_recovery_email_admin_json(app.identity_recovery_email_proposals),
  app.identity_recovery_email_outcome(uuid, boolean),
  app.identity_credential_audit_add(text, uuid, uuid, uuid, app.identity_recovery_email_proposals,
                                    text, text, bigint),
  app.identity_propose_recovery_email(uuid, bigint, jsonb),
  app.identity_lock_recovery_email_proposal(jsonb, text[], boolean, bigint, uuid),
  app.identity_approve_recovery_email(uuid, bigint, jsonb),
  app.identity_reject_recovery_email(uuid, bigint, jsonb),
  app.identity_revert_recovery_email(app.identity_recovery_email_proposals, text),
  app.identity_withdraw_recovery_email(uuid, bigint, jsonb),
  app.identity_authorize_member_withdraw_command(jsonb),
  app.identity_recovery_email_in_scope(uuid, text, uuid),
  app.identity_recovery_email_command(jsonb),
  api.identity_recovery_email_command(jsonb),
  app.identity_authorize_member_credential_command(jsonb),
  app.identity_authorize_command(jsonb),
  app.identity_my_recovery_email(),
  api.identity_my_recovery_email(),
  app.identity_admin_recovery_email_queue(),
  api.identity_admin_recovery_email_queue()
  from public, anon, authenticated, service_role;

grant execute on function app.identity_recovery_email_command(jsonb) to authenticated;
grant execute on function api.identity_recovery_email_command(jsonb) to authenticated;
grant execute on function app.identity_my_recovery_email() to authenticated;
grant execute on function api.identity_my_recovery_email() to authenticated;
grant execute on function app.identity_admin_recovery_email_queue() to authenticated;
grant execute on function api.identity_admin_recovery_email_queue() to authenticated;
