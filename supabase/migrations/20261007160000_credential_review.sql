-- Change credentials under review and hold access (story 2.8; AD-3, AD-4, AD-14, AD-20, AC-05).
-- Builds on the live-access predicate, the 2.2 credential detection and trust epoch, holds, the
-- 1.4 command envelope with the registered `identity` authorizer, the 1.5 lifecycle dispatch and
-- the 2.7 recovery-email flow; nothing here forks them.
--
--   * Reviewed credential changes (member request, Admin decision, Identity applies to Auth):
--       identity.request_credential_change   expected null  {change_kind, phone_username? | email?}
--       identity.withdraw_credential_change  expected = change revision  {change_id}
--       identity.approve_credential_change   expected = change revision  {change_id, identity_check}
--       identity.reject_credential_change    expected = change revision  {change_id, reason?}
--     Kinds: phone_username (a new unverified phone username), recovery_email_replace (a new
--     address), recovery_email_remove. A request needs a granted session whose own password
--     sign-in is at most 10 minutes old (2.7 window), one pending change or 2.7 proposal per
--     account and at most 5 requests per 24 hours. A phone or removal request leaves Auth as it
--     is until an Admin approves it after an identity check; the approval writes auth.users
--     server-side (phone + phone_confirmed_at, never an SMS or OTP; or the email cleared with its
--     change tokens neutralised), records binding revision n+1 (link `active`, trust epoch
--     moved) and revokes every Auth session of the account. A replacement removes the old address
--     from Auth at once (double_confirm_changes stays on, so the old address is never required),
--     which puts the account into access review exactly as a 2.7 addition does; the client then
--     runs native updateUser(new) on the same account and the Admin approves only a CONFIRMED new
--     address. Reject and withdraw of a replacement restore the approved address.
--   * Holds (Admin, expected = member revision):
--       identity.place_hold    {member_id, reason_code}   ownership_dispute -> access_review;
--                                                         security_concern, lost_device -> security
--       identity.release_hold  {member_id, hold_id, identity_check}
--     A hold denies every session (2.1/2.2). lost_device also revokes every Auth session of the
--     account. Placing dispatches the contract v1 lifecycle event access_hold_applied (device-
--     registration owners hook it; no new event is added), releasing dispatches
--     access_hold_released and moves the trust epoch, so sessions opened during the hold sign in
--     again. Nobody places or releases a hold on their own member record.
--   * Credential review of a detected direct Auth change (2.2) or 2.7 `other_changes`:
--       identity.restore_credentials  {member_id, identity_check}   Auth back to the approved
--         binding (phone, email, change tokens; MFA factors and non-phone/email identities
--         removed), every session revoked, binding revision n+1. The exit for a stolen-session
--         PUT /user email change (the 2.7 carried risk).
--       identity.accept_credentials   {member_id, identity_check}   the current Auth phone and
--         confirmed email become binding revision n+1, only without MFA factors or foreign
--         identities and with permitted, free values.
--     Both refuse while a change or 2.7 proposal is pending (decide it first).
--   * Reads: api.identity_my_credentials() (own; granted or in review: a generic `access`, the
--     approved values, the pending change or proposal, the church contact) and
--     api.identity_admin_credential_queue() (Admin: pending changes, accounts in review, holds).
--     Audit: app.identity_credential_review_audit (ids, codes and revisions only).
--
-- Direct Auth changes, /recover, login, reset and email verification never clear a hold or
-- approve a binding: holds are released only by identity.release_hold, and a binding changes
-- only through an Admin decision that records a new binding_revision.
--
-- Auth ROW deletions (sessions, refresh tokens, MFA factors, identities) are not in this file:
-- app.identity_revoke_auth_sessions and app.identity_remove_auth_extras are fail-closed stubs
-- here (every command that needs them answers `unavailable`) and are replaced with the deletions
-- by 20261007160100_credential_review_auth_rows.sql, which the owner applies by hand.
--
-- No destructive statements and no row deletions. No client table privileges.

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

create table app.identity_credential_changes (
  change_id uuid primary key default gen_random_uuid(),
  link_id uuid not null references app.identity_account_links (link_id),
  member_id uuid not null references app.identity_members (member_id),
  auth_user_id uuid not null,
  change_kind text not null
    check (change_kind in ('phone_username', 'recovery_email_replace', 'recovery_email_remove')),
  new_phone text check (new_phone is null or new_phone ~ '^\+[1-9][0-9]{7,14}$'),
  new_email text check (
    new_email is null
    or (new_email = lower(new_email) and length(new_email) between 6 and 254
        and new_email ~ '^[a-z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-z0-9-]+(\.[a-z0-9-]+)+$')),
  change_state text not null default 'pending'
    check (change_state in ('pending', 'approved', 'rejected', 'withdrawn')),
  revision bigint not null default 1 check (revision >= 1),
  is_synthetic boolean not null,
  requested_request_id uuid,
  requested_at timestamptz not null default clock_timestamp(),
  decided_at timestamptz,
  decided_by_member uuid references app.identity_members (member_id),
  decided_by_account uuid,
  identity_check text check (identity_check in ('established_relationship', 'in_person')),
  decision_reason text
    check (decision_reason in ('identity_not_confirmed', 'contact_church_office')),
  binding_revision_after bigint,
  check ((change_kind = 'phone_username') = (new_phone is not null)),
  check ((change_kind = 'recovery_email_replace') = (new_email is not null)),
  check ((change_state = 'pending') = (decided_at is null)),
  check (decision_reason is null or change_state = 'rejected'),
  check ((change_state = 'approved') = (binding_revision_after is not null)),
  check (change_state <> 'approved' or identity_check is not null),
  check ((change_state in ('approved', 'rejected'))
         = (decided_by_member is not null and decided_by_account is not null))
);

comment on table app.identity_credential_changes is
  'owner: identity. A member''s request to change the phone username or to replace or remove '
  'the approved recovery email, and the Admin decision that applies it (story 2.8).';

create unique index identity_credential_changes_one_pending
  on app.identity_credential_changes (link_id) where change_state = 'pending';
create index identity_credential_changes_by_link
  on app.identity_credential_changes (link_id, requested_at);

-- Content-free: ids, codes and revisions only. Never a phone number or an email address.
create table app.identity_credential_review_audit (
  event_id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  environment text not null default app.platform_current_environment(),
  action text not null check (action in (
    'credential_change_requested', 'credential_change_approved', 'credential_change_rejected',
    'credential_change_withdrawn', 'credential_change_reverted', 'hold_placed', 'hold_released',
    'credentials_restored', 'credentials_accepted')),
  actor_member_id uuid not null,
  actor_account_id uuid not null,
  request_id uuid,
  member_id uuid not null,
  link_id uuid,
  change_id uuid,
  change_kind text,
  hold_id uuid,
  hold_kind text,
  reason_code text check (reason_code ~ '^[a-z][a-z0-9_]{0,62}$'),
  identity_check text check (identity_check in ('established_relationship', 'in_person')),
  binding_revision_after bigint,
  revision_after bigint,
  sessions_revoked integer
);

comment on table app.identity_credential_review_audit is
  'owner: identity. Attributed credential changes, holds and credential reviews (AD-4, AD-19): '
  'ids, codes and revisions only.';

create index identity_credential_review_audit_member
  on app.identity_credential_review_audit (member_id, event_id);

-- Holds gain the attributed workflow fields (2.1's reason/placed_by/released_by stay filled).
alter table app.identity_holds
  add column reason_code text
    check (reason_code in ('ownership_dispute', 'security_concern', 'lost_device')),
  add column placed_by_member uuid,
  add column placed_by_account uuid,
  add column released_by_member uuid,
  add column released_by_account uuid,
  add column release_identity_check text
    check (release_identity_check in ('established_relationship', 'in_person')),
  add column sessions_revoked integer;

alter table app.identity_credential_changes enable row level security;
alter table app.identity_credential_review_audit enable row level security;
revoke all on table app.identity_credential_changes, app.identity_credential_review_audit
  from public, anon, authenticated, service_role;
revoke all on sequence app.identity_credential_review_audit_event_id_seq
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Auth row helpers: fail-closed stubs, replaced by 20261007160100 (row deletions live there)
-- ---------------------------------------------------------------------------------------------

-- Revokes every Auth session (and refresh token) of the account; returns how many sessions.
create function app.identity_revoke_auth_sessions(p_auth_user_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
begin
  raise exception using errcode = '0A000',
    message = 'identity Auth row helpers are not installed (20261007160100)';
end;
$$;

-- Removes MFA factors, identities of providers other than phone/email, and email identities of
-- any address other than p_keep_email; returns how many rows.
create function app.identity_remove_auth_extras(p_auth_user_id uuid, p_keep_email text)
returns integer
language plpgsql
set search_path = ''
as $$
begin
  raise exception using errcode = '0A000',
    message = 'identity Auth row helpers are not installed (20261007160100)';
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Settings, triggers and shared helpers
-- ---------------------------------------------------------------------------------------------

-- Abuse limit: credential-change requests per link per rolling 24 hours.
create function app.identity_credential_change_limit()
returns integer
language sql
immutable
set search_path = ''
as $$ select 5 $$;

-- While Q4 is unapproved a phone username must be in a reserved fictional range.
create function app.identity_phone_username_permitted(p_phone text)
returns boolean
language sql
set search_path = ''
as $$
  select app.policy_is_open('q4_personal_data')
      or p_phone ~ '^\+120255501[0-9]{2}$'
      or p_phone ~ '^\+447700900[0-9]{3}$';
$$;

-- Releasing a hold moves the trust epoch of the member's live link: sessions opened while the
-- hold was open (for example by whoever had the lost device) must sign in again.
create function app.identity_on_hold_released()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link uuid;
  v_generation bigint;
  v_epoch timestamptz;
begin
  update app.identity_account_links l
     set sessions_valid_after = greatest(coalesce(l.sessions_valid_after, '-infinity'),
                                         clock_timestamp()),
         updated_at = now()
   where l.member_id = new.member_id and l.link_state <> 'ended'
  returning l.link_id, l.credential_generation, l.sessions_valid_after
       into v_link, v_generation, v_epoch;
  if v_link is not null then
    insert into app.identity_credential_events (link_id, source, kinds, binding_review,
                                                generation_after, epoch_after)
    values (v_link, 'identity_holds', array['hold_released'], false, v_generation, v_epoch);
  end if;
  return null;
end;
$$;

create trigger identity_hold_release_epoch
  after update of released_at on app.identity_holds
  for each row
  when (old.released_at is null and new.released_at is not null)
  execute function app.identity_on_hold_released();

-- One pending credential change OR 2.7 recovery-email proposal per account: a 2.7 proposal is
-- refused while a credential change is pending (raised inside the 2.7 command).
create function app.identity_on_recovery_email_proposal_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (select 1 from app.identity_credential_changes c
              where c.link_id = new.link_id and c.change_state = 'pending') then
    perform app.cmd_fail('conflict', '{"email": "pending_change"}');
  end if;
  return new;
end;
$$;

create trigger identity_recovery_email_pending_change
  before insert on app.identity_recovery_email_proposals
  for each row
  execute function app.identity_on_recovery_email_proposal_insert();

-- Auth's current phone in the binding's E.164 form ('+' and digits), or null.
create function app.identity_auth_phone(p_auth_user_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select '+' || ltrim(nullif(btrim(coalesce(u.phone, '')), ''), '+')
    from auth.users u where u.id = p_auth_user_id;
$$;

-- The account has an MFA factor or an identity of a provider other than phone/email.
create function app.identity_auth_has_extras(p_auth_user_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from auth.mfa_factors f where f.user_id = p_auth_user_id)
      or exists (select 1 from auth.identities i
                  where i.user_id = p_auth_user_id and i.provider not in ('phone', 'email'));
$$;

-- Is this phone username held by another Auth account or another live link?
create function app.identity_phone_username_taken(p_phone text, p_auth_user_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from auth.users u
                  where u.phone in (ltrim(p_phone, '+'), p_phone) and u.id <> p_auth_user_id)
      or exists (select 1 from app.identity_account_links l
                  where l.approved_phone = p_phone and l.link_state <> 'ended'
                    and l.auth_user_id <> p_auth_user_id);
$$;

-- Is this email held by another Auth account (as its email or a pending change)?
create function app.identity_email_taken(p_email text, p_auth_user_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from auth.users u
                  where u.id <> p_auth_user_id
                    and (lower(nullif(btrim(u.email), '')) = p_email
                         or lower(coalesce(u.email_change, '')) = p_email));
$$;

-- Makes outstanding one-time tokens of these types unusable (GoTrue looks them up there).
create function app.identity_neutralise_auth_tokens(p_auth_user_id uuid, p_types text[])
returns void
language sql
set search_path = ''
as $$
  update auth.one_time_tokens t
     set token_hash = 'revoked-' || gen_random_uuid()::text, updated_at = now()
   where t.user_id = p_auth_user_id and t.token_type::text = any (p_types);
$$;

-- Records binding revision n+1 with these values (clears the 2.2 binding review), returns the
-- link to `active` and moves the trust epoch: only sessions opened after it pass.
create function app.identity_record_binding(
  p_link_id uuid,
  p_phone text,
  p_email text,
  p_by text,
  p_reason text
) returns app.identity_account_links
language plpgsql
set search_path = ''
as $$
declare
  v_link app.identity_account_links;
begin
  update app.identity_account_links l
     set approved_phone = p_phone,
         approved_recovery_email = p_email,
         binding_revision = l.binding_revision + 1,
         link_state = 'active',
         approved_by = p_by,
         sessions_valid_after = greatest(coalesce(l.sessions_valid_after, '-infinity'),
                                         clock_timestamp()),
         updated_at = now()
   where l.link_id = p_link_id
  returning l.* into v_link;
  insert into app.identity_binding_history (link_id, binding_revision, approved_phone,
                                            approved_recovery_email, approved_by, reason)
  values (v_link.link_id, v_link.binding_revision, v_link.approved_phone,
          v_link.approved_recovery_email, p_by, p_reason);
  return v_link;
end;
$$;

create function app.identity_bump_member(p_member_id uuid)
returns bigint
language sql
set search_path = ''
as $$
  update app.identity_members m
     set revision = m.revision + 1, updated_at = now()
   where m.member_id = p_member_id
  returning m.revision;
$$;

create function app.identity_review_audit_add(
  p_action text,
  p_actor_member uuid,
  p_actor_account uuid,
  p_request uuid,
  p_member uuid,
  p_link uuid,
  p_change app.identity_credential_changes,
  p_hold app.identity_holds,
  p_reason text,
  p_identity_check text,
  p_binding_revision bigint,
  p_revision bigint,
  p_sessions integer
) returns void
language sql
set search_path = ''
as $$
  insert into app.identity_credential_review_audit (
    action, actor_member_id, actor_account_id, request_id, member_id, link_id, change_id,
    change_kind, hold_id, hold_kind, reason_code, identity_check, binding_revision_after,
    revision_after, sessions_revoked)
  values (p_action, p_actor_member, p_actor_account, p_request, p_member, p_link,
          p_change.change_id, p_change.change_kind, p_hold.hold_id, p_hold.hold_kind, p_reason,
          p_identity_check, p_binding_revision, p_revision, p_sessions);
$$;

-- ---------------------------------------------------------------------------------------------
-- Views of a change
-- ---------------------------------------------------------------------------------------------

-- A replacement's new address is held by Auth, confirmed.
create function app.identity_credential_change_verified(p_row app.identity_credential_changes)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_row.change_kind = 'recovery_email_replace' and exists (
    select 1 from auth.users u
     where u.id = p_row.auth_user_id
       and lower(nullif(btrim(u.email), '')) = p_row.new_email
       and u.email_confirmed_at is not null);
$$;

-- Binding-relevant Auth state beyond what the change itself explains: an MFA factor or foreign
-- identity, an Auth phone other than the approved one, an Auth email other than the approved
-- one (a replacement's own new address and its removed old one excepted), or a recorded phone,
-- delete, identity-removed/moved or MFA change since the request.
create function app.identity_credential_change_other_changes(p_row app.identity_credential_changes)
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.identity_auth_has_extras(p_row.auth_user_id)
      or exists (
           select 1 from auth.users u
             join app.identity_account_links l on l.link_id = p_row.link_id
            where u.id = p_row.auth_user_id
              and (app.identity_auth_phone(u.id) is distinct from l.approved_phone
                   or (p_row.change_kind <> 'recovery_email_replace'
                       and (coalesce(lower(nullif(btrim(u.email), '')), '')
                              <> coalesce(l.approved_recovery_email, '')
                            or (l.approved_recovery_email is not null
                                and u.email_confirmed_at is null)))
                   or (p_row.change_kind = 'recovery_email_replace'
                       and nullif(btrim(coalesce(u.email, '')), '') is not null
                       and lower(btrim(u.email)) <> p_row.new_email)))
      or exists (
           select 1 from app.identity_credential_events e
            where e.link_id = p_row.link_id
              and e.at >= p_row.requested_at
              and e.kinds && array['phone', 'soft_deleted', 'user_deleted', 'identity_removed',
                                   'identity_moved', 'mfa_added', 'mfa_changed', 'mfa_removed']);
$$;

create function app.identity_credential_change_member_json(p_row app.identity_credential_changes)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'change_id', p_row.change_id,
    'revision', p_row.revision,
    'change_kind', p_row.change_kind,
    'phone_username', p_row.new_phone,
    'email', p_row.new_email,
    'state', p_row.change_state,
    'verified', case when p_row.change_kind = 'recovery_email_replace'
                     then app.identity_credential_change_verified(p_row) end,
    'requested_at', p_row.requested_at,
    'decided_at', p_row.decided_at,
    'decision_reason', p_row.decision_reason));
$$;

create function app.identity_credential_change_admin_json(p_row app.identity_credential_changes)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select app.identity_credential_change_member_json(p_row) || jsonb_build_object(
    'member_id', p_row.member_id,
    'display_name', (select m.display_name from app.identity_members m
                      where m.member_id = p_row.member_id),
    'current_phone_username', (select l.approved_phone from app.identity_account_links l
                                where l.link_id = p_row.link_id),
    'has_recovery_email', (select l.approved_recovery_email is not null
                             from app.identity_account_links l where l.link_id = p_row.link_id),
    'access_review', (select l.link_state <> 'active' or l.binding_review_required
                        from app.identity_account_links l where l.link_id = p_row.link_id),
    'phone_available', case when p_row.change_kind = 'phone_username'
                            then not app.identity_phone_username_taken(p_row.new_phone,
                                                                       p_row.auth_user_id) end,
    'verified', app.identity_credential_change_verified(p_row),
    'other_changes', app.identity_credential_change_other_changes(p_row),
    'own_account', p_row.auth_user_id
                   = nullif(app.identity_request_claims() ->> 'sub', '')::uuid,
    'is_synthetic', p_row.is_synthetic);
$$;

create function app.identity_credential_change_outcome(p_change_id uuid, p_admin boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'identity_credential_change',
    'aggregate_id', c.change_id,
    'revision', c.revision,
    'data', case when p_admin then app.identity_credential_change_admin_json(c)
                 else app.identity_credential_change_member_json(c) end)
    from app.identity_credential_changes c
   where c.change_id = p_change_id;
$$;

-- A member's open holds (Admin view).
create function app.identity_member_holds_json(p_member_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'member_id', m.member_id,
    'revision', m.revision,
    'account', app.identity_member_account_label(m.member_id),
    'holds', coalesce((
      select jsonb_agg(jsonb_build_object('hold_id', h.hold_id, 'hold_kind', h.hold_kind,
                                          'reason_code', h.reason_code, 'placed_at', h.placed_at)
                       order by h.placed_at, h.hold_id)
        from app.identity_holds h
       where h.member_id = m.member_id and h.released_at is null), '[]'::jsonb))
    from app.identity_members m
   where m.member_id = p_member_id;
$$;

create function app.identity_member_holds_outcome(p_member_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'identity_member',
    'aggregate_id', p_member_id,
    'revision', (select m.revision from app.identity_members m where m.member_id = p_member_id),
    'data', app.identity_member_holds_json(p_member_id));
$$;

-- ---------------------------------------------------------------------------------------------
-- Auth writes (the Identity owner as the server-side principal, inside the Admin or member
-- command; the 2.2 triggers record each change and the binding revision that follows clears it)
-- ---------------------------------------------------------------------------------------------

-- Puts the approved recovery email back on the account after a replacement was rejected or
-- withdrawn: the new address leaves auth.users (pending or confirmed), its change tokens are
-- neutralised, and the approved address returns confirmed (unless another account took it).
-- The review this caused is lifted with binding revision n+1 when the account now matches the
-- approved binding and nothing else changed. Returns true when the review was lifted.
create function app.identity_revert_credential_change(
  p_row app.identity_credential_changes,
  p_by text
) returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_link app.identity_account_links;
  v_other boolean;
begin
  if p_row.change_kind <> 'recovery_email_replace' then
    return false;
  end if;
  select l.* into v_link from app.identity_account_links l where l.link_id = p_row.link_id
     for update;
  if v_link.link_state = 'ended' or v_link.auth_user_id <> p_row.auth_user_id then
    return false;
  end if;
  v_other := app.identity_auth_has_extras(p_row.auth_user_id)
             or app.identity_auth_phone(p_row.auth_user_id) is distinct from v_link.approved_phone
             or exists (
                  select 1 from app.identity_credential_events e
                   where e.link_id = p_row.link_id and e.at >= p_row.requested_at
                     and e.kinds && array['phone', 'soft_deleted', 'user_deleted',
                                          'identity_removed', 'identity_moved', 'mfa_added',
                                          'mfa_changed', 'mfa_removed']);
  update auth.users u
     set email = case
                   when (nullif(btrim(coalesce(u.email, '')), '') is null
                         or lower(btrim(u.email)) = p_row.new_email)
                        and (v_link.approved_recovery_email is null
                             or not app.identity_email_taken(v_link.approved_recovery_email, u.id))
                     then v_link.approved_recovery_email
                   else u.email end,
         email_confirmed_at = case
                   when (nullif(btrim(coalesce(u.email, '')), '') is null
                         or lower(btrim(u.email)) = p_row.new_email)
                        and (v_link.approved_recovery_email is null
                             or not app.identity_email_taken(v_link.approved_recovery_email, u.id))
                     then case when v_link.approved_recovery_email is null then null
                               else now() end
                   else u.email_confirmed_at end,
         email_change = case when lower(coalesce(u.email_change, '')) = p_row.new_email
                             then '' else u.email_change end,
         email_change_token_new = case when lower(coalesce(u.email_change, '')) = p_row.new_email
                                       then '' else u.email_change_token_new end,
         email_change_token_current = case when lower(coalesce(u.email_change, '')) = p_row.new_email
                                           then '' else u.email_change_token_current end,
         email_change_confirm_status = case when lower(coalesce(u.email_change, '')) = p_row.new_email
                                            then 0 else u.email_change_confirm_status end,
         email_change_sent_at = case when lower(coalesce(u.email_change, '')) = p_row.new_email
                                     then null else u.email_change_sent_at end
   where u.id = p_row.auth_user_id;
  perform app.identity_neutralise_auth_tokens(p_row.auth_user_id,
    array['email_change_token_new', 'email_change_token_current']);
  select l.* into v_link from app.identity_account_links l where l.link_id = p_row.link_id;
  if v_other or not v_link.binding_review_required
     or v_link.link_state not in ('active', 'review_required')
     or not exists (
          select 1 from auth.users u
           where u.id = p_row.auth_user_id
             and coalesce(lower(nullif(btrim(u.email), '')), '')
                 = coalesce(v_link.approved_recovery_email, '')
             and (v_link.approved_recovery_email is null or u.email_confirmed_at is not null)) then
    return false;
  end if;
  perform app.identity_record_binding(v_link.link_id, v_link.approved_phone,
    v_link.approved_recovery_email, p_by, 'credential_change_reverted');
  return true;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Member commands
-- ---------------------------------------------------------------------------------------------

-- identity.request_credential_change {change_kind, phone_username? | email?}: the granted
-- member's own account, fresh password sign-in.
create function app.identity_request_credential_change(
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
  v_kind text;
  v_phone text;
  v_email text;
  v_link app.identity_account_links;
  v_member app.identity_members;
  v_row app.identity_credential_changes;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.request_credential_change');
begin
  select e.* into r from app.identity_access_evaluate() e;
  if r.outcome is distinct from 'granted' then
    perform app.cmd_fail('forbidden');
  end if;
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  if coalesce(jsonb_typeof(p_payload -> 'change_kind'), 'null') = 'null' then
    perform app.cmd_fail('validation_failed', '{"change_kind": "required"}');
  elsif jsonb_typeof(p_payload -> 'change_kind') <> 'string'
        or p_payload ->> 'change_kind' not in ('phone_username', 'recovery_email_replace',
                                               'recovery_email_remove') then
    perform app.cmd_fail('validation_failed', '{"change_kind": "invalid"}');
  end if;
  v_kind := p_payload ->> 'change_kind';
  v_errors := app.contract_unknown_keys(p_payload, case v_kind
    when 'phone_username' then array['change_kind', 'phone_username']
    when 'recovery_email_replace' then array['change_kind', 'email']
    else array['change_kind'] end);
  if v_kind = 'phone_username' then
    if coalesce(jsonb_typeof(p_payload -> 'phone_username'), 'null') = 'null' then
      v_errors := v_errors || '{"phone_username": "required"}';
    elsif jsonb_typeof(p_payload -> 'phone_username') <> 'string'
          or p_payload ->> 'phone_username' !~ '^\+[1-9][0-9]{7,14}$' then
      v_errors := v_errors || '{"phone_username": "invalid"}';
    else
      v_phone := p_payload ->> 'phone_username';
      if not app.identity_phone_username_permitted(v_phone) then
        v_errors := v_errors || '{"phone_username": "out_of_range"}';
      end if;
    end if;
  elsif v_kind = 'recovery_email_replace' then
    if coalesce(jsonb_typeof(p_payload -> 'email'), 'null') = 'null' then
      v_errors := v_errors || '{"email": "required"}';
    elsif jsonb_typeof(p_payload -> 'email') <> 'string' then
      v_errors := v_errors || '{"email": "invalid"}';
    else
      v_email := lower(btrim(p_payload ->> 'email'));
      if length(v_email) not between 6 and 254
         or v_email !~ '^[a-z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-z0-9-]+(\.[a-z0-9-]+)+$' then
        v_errors := v_errors || '{"email": "invalid"}';
      elsif not app.identity_recovery_email_permitted(v_email) then
        v_errors := v_errors || '{"email": "unsupported"}';
      end if;
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  if not app.identity_applications_open()
     or (v_kind <> 'phone_username' and not app.identity_email_recovery_open()) then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  if not app.identity_session_recent_password() then
    perform app.cmd_fail('forbidden', '{"session": "reauthenticate"}');
  end if;

  select l.* into v_link from app.identity_account_links l where l.link_id = r.link_id for update;
  if v_link.link_state <> 'active' or v_link.binding_review_required
     or v_link.auth_user_id <> p_actor then
    perform app.cmd_fail('forbidden');
  end if;
  if exists (select 1 from app.identity_credential_changes c
              where c.link_id = v_link.link_id and c.change_state = 'pending')
     or exists (select 1 from app.identity_recovery_email_proposals p
                 where p.link_id = v_link.link_id and p.proposal_state = 'pending') then
    perform app.cmd_fail('conflict', '{"change_id": "pending"}');
  end if;
  if v_kind = 'phone_username' then
    if v_phone = v_link.approved_phone then
      perform app.cmd_fail('validation_failed', '{"phone_username": "unchanged"}');
    end if;
    if app.identity_phone_username_taken(v_phone, p_actor) then
      perform app.cmd_fail('conflict', '{"phone_username": "unavailable"}');
    end if;
  else
    if v_link.approved_recovery_email is null then
      perform app.cmd_fail('validation_failed', '{"change_kind": "no_recovery_email"}');
    end if;
    if v_kind = 'recovery_email_replace' then
      if v_email = v_link.approved_recovery_email then
        perform app.cmd_fail('validation_failed', '{"email": "unchanged"}');
      end if;
      if app.identity_email_taken(v_email, p_actor) then
        perform app.cmd_fail('conflict', '{"email": "unavailable"}');
      end if;
    end if;
  end if;
  if (select count(*) from app.identity_credential_changes c
       where c.link_id = v_link.link_id and c.requested_at > now() - interval '24 hours')
     >= app.identity_credential_change_limit() then
    perform app.cmd_fail('rate_limited');
  end if;
  select m.* into v_member from app.identity_members m where m.member_id = v_link.member_id;

  insert into app.identity_credential_changes (link_id, member_id, auth_user_id, change_kind,
                                               new_phone, new_email, is_synthetic,
                                               requested_request_id)
  values (v_link.link_id, v_member.member_id, p_actor, v_kind, v_phone, v_email,
          v_member.is_synthetic, v_request)
  returning * into v_row;
  perform app.identity_review_audit_add('credential_change_requested', v_member.member_id, p_actor,
    v_request, v_member.member_id, v_link.link_id, v_row, null, null, null, null, v_row.revision,
    null);
  perform app.identity_record_activity(v_link.link_id);

  if v_kind = 'recovery_email_replace' then
    -- The old address leaves Auth now, so the new one is confirmed alone (double_confirm_changes
    -- stays on and the old address is never required). The 2.2 detection puts the account into
    -- access review until the Admin decides, as a 2.7 addition does.
    update auth.users u
       set email = null, email_confirmed_at = null, email_change = '',
           email_change_token_new = '', email_change_token_current = '',
           email_change_confirm_status = 0, email_change_sent_at = null
     where u.id = p_actor;
    perform app.identity_neutralise_auth_tokens(p_actor,
      array['email_change_token_new', 'email_change_token_current']);
  end if;
  return app.identity_credential_change_outcome(v_row.change_id, false);
end;
$$;

-- identity.withdraw_credential_change {change_id}: the member's own pending change, also while
-- the account waits in review. A replacement returns the approved address.
create function app.identity_withdraw_credential_change(
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
  v_row app.identity_credential_changes;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.withdraw_credential_change');
begin
  select e.* into r from app.identity_access_evaluate() e;
  if r.outcome not in ('granted', 'review_required') or r.link_id is null then
    perform app.cmd_fail('forbidden');
  end if;
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, array['change_id']);
  v_err := app.contract_uuid_error(p_payload -> 'change_id');
  if v_err is not null then
    v_errors := v_errors || jsonb_build_object('change_id', v_err);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  select c.* into v_row from app.identity_credential_changes c
   where c.change_id = (p_payload ->> 'change_id')::uuid
     for update;
  -- Another account's change is indistinguishable from a missing one.
  if not found or v_row.auth_user_id <> p_actor or v_row.link_id <> r.link_id then
    perform app.cmd_fail('not_found');
  end if;
  if v_row.change_state <> 'pending' or v_row.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_row.revision);
  end if;
  update app.identity_credential_changes c
     set change_state = 'withdrawn', revision = c.revision + 1, decided_at = now()
   where c.change_id = v_row.change_id
  returning c.* into v_row;
  perform app.identity_review_audit_add('credential_change_withdrawn', v_row.member_id, p_actor,
    v_request, v_row.member_id, v_row.link_id, v_row, null, null, null, null, v_row.revision, null);
  if app.identity_revert_credential_change(v_row, 'member:' || v_row.member_id::text) then
    perform app.identity_review_audit_add('credential_change_reverted', v_row.member_id, p_actor,
      v_request, v_row.member_id, v_row.link_id, v_row, null, null, null,
      (select l.binding_revision from app.identity_account_links l where l.link_id = v_row.link_id),
      v_row.revision, null);
  end if;
  return app.identity_credential_change_outcome(v_row.change_id, false);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Admin commands: credential changes
-- ---------------------------------------------------------------------------------------------

-- Validates {change_id, identity_check?, reason?}, then locks the pending change at the expected
-- revision. The Admin's own account is refused (separation of duty).
create function app.identity_lock_credential_change(
  p_payload jsonb,
  p_allowed text[],
  p_identity_check_required boolean,
  p_expected_revision bigint,
  p_actor_account uuid
) returns app.identity_credential_changes
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_err text;
  v_row app.identity_credential_changes;
begin
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, p_allowed);
  v_err := app.contract_uuid_error(p_payload -> 'change_id');
  if v_err is not null then
    v_errors := v_errors || jsonb_build_object('change_id', v_err);
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
  select c.* into v_row from app.identity_credential_changes c
   where c.change_id = (p_payload ->> 'change_id')::uuid
     for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_row.auth_user_id = p_actor_account then
    perform app.cmd_fail('forbidden', '{"change_id": "unsupported"}');
  end if;
  if v_row.change_state <> 'pending' or v_row.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_row.revision);
  end if;
  return v_row;
end;
$$;

-- identity.approve_credential_change {change_id, identity_check}
create function app.identity_approve_credential_change(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_row app.identity_credential_changes;
  v_link app.identity_account_links;
  v_by text;
  v_sessions integer;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.approve_credential_change');
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_by := 'admin:' || v_actor.member_id::text;
  v_row := app.identity_lock_credential_change(p_payload, array['change_id', 'identity_check'],
    true, p_expected_revision, v_actor.account_id);
  if not app.identity_applications_open()
     or (v_row.change_kind <> 'phone_username' and not app.identity_email_recovery_open()) then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  select l.* into v_link from app.identity_account_links l where l.link_id = v_row.link_id
     for update;
  if v_link.link_state not in ('active', 'review_required')
     or v_link.auth_user_id <> v_row.auth_user_id
     or not exists (select 1 from app.identity_members m
                     where m.member_id = v_link.member_id and m.membership_state = 'approved') then
    perform app.cmd_fail('conflict', '{"change_id": "stale"}', v_row.revision);
  end if;
  if not exists (select 1 from auth.users u
                  where u.id = v_row.auth_user_id and u.deleted_at is null
                    and not coalesce(u.is_anonymous, false)
                    and (u.banned_until is null or u.banned_until <= now())) then
    perform app.cmd_fail('conflict', '{"change_id": "stale"}', v_row.revision);
  end if;
  if v_row.change_kind = 'recovery_email_replace'
     and not app.identity_credential_change_verified(v_row) then
    perform app.cmd_fail('validation_failed', '{"recovery_email": "unverified"}');
  end if;
  if app.identity_credential_change_other_changes(v_row) then
    -- Anything beyond this change: reject it, then restore or accept the account's credentials.
    perform app.cmd_fail('conflict', '{"change_id": "other_changes"}', v_row.revision);
  end if;
  if v_row.change_kind = 'phone_username'
     and app.identity_phone_username_taken(v_row.new_phone, v_row.auth_user_id) then
    -- Never overwritten or merged: the holder's number is reclaimed (2.5) or the request rejected.
    perform app.cmd_fail('conflict', '{"phone_username": "taken"}', v_row.revision);
  end if;

  -- Apply to Auth server-side (no SMS, no OTP). The 2.2 triggers record the change; the binding
  -- revision below clears the review it causes.
  if v_row.change_kind = 'phone_username' then
    update auth.users u
       set phone = ltrim(v_row.new_phone, '+'), phone_confirmed_at = now(), phone_change = '',
           phone_change_token = '', phone_change_sent_at = null
     where u.id = v_row.auth_user_id;
    update auth.identities i
       set identity_data = i.identity_data || jsonb_build_object('phone', ltrim(v_row.new_phone, '+')),
           updated_at = now()
     where i.user_id = v_row.auth_user_id and i.provider = 'phone';
    perform app.identity_neutralise_auth_tokens(v_row.auth_user_id, array['phone_change_token']);
  elsif v_row.change_kind = 'recovery_email_remove' then
    update auth.users u
       set email = null, email_confirmed_at = null, email_change = '',
           email_change_token_new = '', email_change_token_current = '',
           email_change_confirm_status = 0, email_change_sent_at = null
     where u.id = v_row.auth_user_id;
    perform app.identity_neutralise_auth_tokens(v_row.auth_user_id,
      array['email_change_token_new', 'email_change_token_current']);
  end if;

  v_link := app.identity_record_binding(v_link.link_id,
    case when v_row.change_kind = 'phone_username' then v_row.new_phone else v_link.approved_phone end,
    case v_row.change_kind when 'recovery_email_replace' then v_row.new_email
                           when 'recovery_email_remove' then null
                           else v_link.approved_recovery_email end,
    v_by,
    case v_row.change_kind when 'phone_username' then 'phone_username_changed'
                           when 'recovery_email_replace' then 'recovery_email_replaced'
                           else 'recovery_email_removed' end);
  -- Obsolete sessions end now on every device (the epoch above already denies them).
  v_sessions := app.identity_revoke_auth_sessions(v_row.auth_user_id);

  update app.identity_credential_changes c
     set change_state = 'approved', revision = c.revision + 1, decided_at = now(),
         decided_by_member = v_actor.member_id, decided_by_account = v_actor.account_id,
         identity_check = p_payload ->> 'identity_check',
         binding_revision_after = v_link.binding_revision
   where c.change_id = v_row.change_id
  returning c.* into v_row;
  perform app.identity_review_audit_add('credential_change_approved', v_actor.member_id,
    v_actor.account_id, v_request, v_row.member_id, v_row.link_id, v_row, null, null,
    v_row.identity_check, v_link.binding_revision, v_row.revision, v_sessions);
  return app.identity_credential_change_outcome(v_row.change_id, true);
end;
$$;

-- identity.reject_credential_change {change_id, reason?}: the decision; a replacement returns the
-- approved address (app.identity_revert_credential_change).
create function app.identity_reject_credential_change(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_row app.identity_credential_changes;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.reject_credential_change');
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_row := app.identity_lock_credential_change(p_payload, array['change_id', 'reason'], false,
    p_expected_revision, v_actor.account_id);
  update app.identity_credential_changes c
     set change_state = 'rejected', revision = c.revision + 1, decided_at = now(),
         decided_by_member = v_actor.member_id, decided_by_account = v_actor.account_id,
         decision_reason = p_payload ->> 'reason'
   where c.change_id = v_row.change_id
  returning c.* into v_row;
  perform app.identity_review_audit_add('credential_change_rejected', v_actor.member_id,
    v_actor.account_id, v_request, v_row.member_id, v_row.link_id, v_row, null,
    v_row.decision_reason, null, null, v_row.revision, null);
  if app.identity_revert_credential_change(v_row, 'admin:' || v_actor.member_id::text) then
    perform app.identity_review_audit_add('credential_change_reverted', v_actor.member_id,
      v_actor.account_id, v_request, v_row.member_id, v_row.link_id, v_row, null, null, null,
      (select l.binding_revision from app.identity_account_links l where l.link_id = v_row.link_id),
      v_row.revision, null);
  end if;
  return app.identity_credential_change_outcome(v_row.change_id, true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Admin commands on a member: holds and credential review
-- ---------------------------------------------------------------------------------------------

-- Validates the payload, refuses the Admin's own member record (no self-approval of a hold or
-- review) and locks the member at the expected revision.
create function app.identity_lock_reviewed_member(
  p_payload jsonb,
  p_allowed text[],
  p_identity_check_required boolean,
  p_expected_revision bigint,
  p_actor_member uuid
) returns app.identity_members
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_err text;
  v_member app.identity_members;
begin
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, p_allowed);
  v_err := app.contract_uuid_error(p_payload -> 'member_id');
  if v_err is not null then
    v_errors := v_errors || jsonb_build_object('member_id', v_err);
  end if;
  if 'identity_check' = any (p_allowed) then
    v_err := app.identity_check_value(p_payload -> 'identity_check', p_identity_check_required);
    if v_err is not null then
      v_errors := v_errors || jsonb_build_object('identity_check', v_err);
    end if;
  end if;
  if 'hold_id' = any (p_allowed) then
    v_err := app.contract_uuid_error(p_payload -> 'hold_id');
    if v_err is not null then
      v_errors := v_errors || jsonb_build_object('hold_id', v_err);
    end if;
  end if;
  if 'reason_code' = any (p_allowed) then
    if coalesce(jsonb_typeof(p_payload -> 'reason_code'), 'null') = 'null' then
      v_errors := v_errors || '{"reason_code": "required"}';
    elsif jsonb_typeof(p_payload -> 'reason_code') <> 'string'
          or p_payload ->> 'reason_code' not in ('ownership_dispute', 'security_concern',
                                                 'lost_device') then
      v_errors := v_errors || '{"reason_code": "invalid"}';
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  if (p_payload ->> 'member_id')::uuid = p_actor_member then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  select m.* into v_member from app.identity_members m
   where m.member_id = (p_payload ->> 'member_id')::uuid
     for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_member.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_member.revision);
  end if;
  return v_member;
end;
$$;

-- identity.place_hold {member_id, reason_code}
create function app.identity_place_hold(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_member app.identity_members;
  v_link app.identity_account_links;
  v_hold app.identity_holds;
  v_reason text;
  v_sessions integer;
  v_revision bigint;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.place_hold');
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_member := app.identity_lock_reviewed_member(p_payload, array['member_id', 'reason_code'],
    false, p_expected_revision, v_actor.member_id);
  v_reason := p_payload ->> 'reason_code';
  if v_member.membership_state <> 'approved' then
    perform app.cmd_fail('conflict', '{"member_id": "not_approved"}', v_member.revision);
  end if;
  if exists (select 1 from app.identity_holds h
              where h.member_id = v_member.member_id and h.released_at is null
                and h.reason_code = v_reason) then
    perform app.cmd_fail('conflict', '{"reason_code": "already_held"}', v_member.revision);
  end if;
  select l.* into v_link from app.identity_account_links l
   where l.member_id = v_member.member_id and l.link_state <> 'ended'
     for update;
  -- The 2.2 hold trigger moves the trust epoch of the live link.
  insert into app.identity_holds (member_id, hold_kind, reason, placed_by, reason_code,
                                  placed_by_member, placed_by_account)
  values (v_member.member_id,
          case when v_reason = 'ownership_dispute' then 'access_review' else 'security' end,
          v_reason, 'admin:' || v_actor.member_id::text, v_reason, v_actor.member_id,
          v_actor.account_id)
  returning * into v_hold;
  if v_reason = 'lost_device' and v_link.link_id is not null then
    -- Lost or compromised device: every Auth session of the account ends now.
    v_sessions := app.identity_revoke_auth_sessions(v_link.auth_user_id);
    update app.identity_holds h set sessions_revoked = v_sessions where h.hold_id = v_hold.hold_id
    returning * into v_hold;
  end if;
  v_revision := app.identity_bump_member(v_member.member_id);
  perform app.identity_review_audit_add('hold_placed', v_actor.member_id, v_actor.account_id,
    v_request, v_member.member_id, v_link.link_id, null, v_hold, v_reason, null, null,
    v_revision, v_sessions);
  -- Registered owner hooks (for example device registrations) run in this transaction.
  perform app.contract_dispatch_lifecycle(jsonb_build_object(
    'event', 'access_hold_applied',
    'member_id', v_member.member_id,
    'occurred_at', app.cmd_utc(now()),
    'identity_revision', v_revision));
  return app.identity_member_holds_outcome(v_member.member_id);
end;
$$;

-- identity.release_hold {member_id, hold_id, identity_check}: only another Admin, after an
-- identity check. Moves the trust epoch (identity_on_hold_released).
create function app.identity_release_hold(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_member app.identity_members;
  v_hold app.identity_holds;
  v_revision bigint;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.release_hold');
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_member := app.identity_lock_reviewed_member(p_payload,
    array['member_id', 'hold_id', 'identity_check'], true, p_expected_revision, v_actor.member_id);
  select h.* into v_hold from app.identity_holds h
   where h.hold_id = (p_payload ->> 'hold_id')::uuid and h.member_id = v_member.member_id
     for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_hold.released_at is not null then
    perform app.cmd_fail('conflict', '{"hold_id": "released"}', v_member.revision);
  end if;
  update app.identity_holds h
     set released_at = now(), released_by = 'admin:' || v_actor.member_id::text,
         released_by_member = v_actor.member_id, released_by_account = v_actor.account_id,
         release_identity_check = p_payload ->> 'identity_check'
   where h.hold_id = v_hold.hold_id
  returning * into v_hold;
  v_revision := app.identity_bump_member(v_member.member_id);
  perform app.identity_review_audit_add('hold_released', v_actor.member_id, v_actor.account_id,
    v_request, v_member.member_id,
    (select l.link_id from app.identity_account_links l
      where l.member_id = v_member.member_id and l.link_state <> 'ended'),
    null, v_hold, v_hold.reason_code, v_hold.release_identity_check, null, v_revision, null);
  perform app.contract_dispatch_lifecycle(jsonb_build_object(
    'event', 'access_hold_released',
    'member_id', v_member.member_id,
    'occurred_at', app.cmd_utc(now()),
    'identity_revision', v_revision));
  return app.identity_member_holds_outcome(v_member.member_id);
end;
$$;

-- Locks the member's live link for a credential review: a live (active or review_required)
-- link of an existing Auth account with no pending change or 2.7 proposal.
create function app.identity_lock_review_link(p_member app.identity_members)
returns app.identity_account_links
language plpgsql
set search_path = ''
as $$
declare
  v_link app.identity_account_links;
begin
  select l.* into v_link from app.identity_account_links l
   where l.member_id = p_member.member_id and l.link_state <> 'ended'
     for update;
  if not found or v_link.link_state not in ('active', 'review_required') then
    perform app.cmd_fail('conflict', '{"member_id": "not_linked"}', p_member.revision);
  end if;
  if not exists (select 1 from auth.users u
                  where u.id = v_link.auth_user_id and u.deleted_at is null) then
    perform app.cmd_fail('conflict', '{"member_id": "account_deleted"}', p_member.revision);
  end if;
  if exists (select 1 from app.identity_credential_changes c
              where c.link_id = v_link.link_id and c.change_state = 'pending')
     or exists (select 1 from app.identity_recovery_email_proposals p
                 where p.link_id = v_link.link_id and p.proposal_state = 'pending') then
    perform app.cmd_fail('conflict', '{"member_id": "pending_change"}', p_member.revision);
  end if;
  return v_link;
end;
$$;

-- identity.restore_credentials {member_id, identity_check}: Auth back to the approved binding,
-- every session revoked, binding revision n+1.
create function app.identity_restore_credentials(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_member app.identity_members;
  v_link app.identity_account_links;
  v_sessions integer;
  v_revision bigint;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.restore_credentials');
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_member := app.identity_lock_reviewed_member(p_payload, array['member_id', 'identity_check'],
    true, p_expected_revision, v_actor.member_id);
  v_link := app.identity_lock_review_link(v_member);
  if v_link.auth_user_id = v_actor.account_id then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  if app.identity_phone_username_taken(v_link.approved_phone, v_link.auth_user_id) then
    perform app.cmd_fail('conflict', '{"member_id": "phone_taken"}', v_member.revision);
  end if;
  if v_link.approved_recovery_email is not null
     and app.identity_email_taken(v_link.approved_recovery_email, v_link.auth_user_id) then
    perform app.cmd_fail('conflict', '{"member_id": "email_taken"}', v_member.revision);
  end if;

  update auth.users u
     set phone = ltrim(v_link.approved_phone, '+'),
         phone_confirmed_at = case when app.identity_auth_phone(u.id) = v_link.approved_phone
                                   then coalesce(u.phone_confirmed_at, now()) else now() end,
         phone_change = '', phone_change_token = '', phone_change_sent_at = null,
         email = v_link.approved_recovery_email,
         email_confirmed_at = case
           when v_link.approved_recovery_email is null then null
           when lower(nullif(btrim(coalesce(u.email, '')), '')) = v_link.approved_recovery_email
             then coalesce(u.email_confirmed_at, now())
           else now() end,
         email_change = '', email_change_token_new = '', email_change_token_current = '',
         email_change_confirm_status = 0, email_change_sent_at = null
   where u.id = v_link.auth_user_id;
  update auth.identities i
     set identity_data = i.identity_data
                         || jsonb_build_object('phone', ltrim(v_link.approved_phone, '+')),
         updated_at = now()
   where i.user_id = v_link.auth_user_id and i.provider = 'phone'
     and i.identity_data ->> 'phone' is distinct from ltrim(v_link.approved_phone, '+');
  perform app.identity_neutralise_auth_tokens(v_link.auth_user_id,
    array['email_change_token_new', 'email_change_token_current', 'phone_change_token']);
  perform app.identity_remove_auth_extras(v_link.auth_user_id, v_link.approved_recovery_email);
  v_sessions := app.identity_revoke_auth_sessions(v_link.auth_user_id);
  v_link := app.identity_record_binding(v_link.link_id, v_link.approved_phone,
    v_link.approved_recovery_email, 'admin:' || v_actor.member_id::text, 'credentials_restored');
  v_revision := app.identity_bump_member(v_member.member_id);
  perform app.identity_review_audit_add('credentials_restored', v_actor.member_id,
    v_actor.account_id, v_request, v_member.member_id, v_link.link_id, null, null, null,
    p_payload ->> 'identity_check', v_link.binding_revision, v_revision, v_sessions);
  return app.identity_member_holds_outcome(v_member.member_id);
end;
$$;

-- identity.accept_credentials {member_id, identity_check}: the account's current Auth phone and
-- confirmed email become binding revision n+1 (no MFA factor or foreign identity; values
-- permitted and free), every session revoked.
create function app.identity_accept_credentials(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_member app.identity_members;
  v_link app.identity_account_links;
  v_phone text;
  v_email text;
  v_confirmed boolean;
  v_sessions integer;
  v_revision bigint;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.accept_credentials');
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_member := app.identity_lock_reviewed_member(p_payload, array['member_id', 'identity_check'],
    true, p_expected_revision, v_actor.member_id);
  v_link := app.identity_lock_review_link(v_member);
  if v_link.auth_user_id = v_actor.account_id then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  if not app.identity_applications_open() then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  if app.identity_auth_has_extras(v_link.auth_user_id) then
    perform app.cmd_fail('conflict', '{"member_id": "unsupported_factors"}', v_member.revision);
  end if;
  select app.identity_auth_phone(u.id), lower(nullif(btrim(u.email), '')),
         u.email_confirmed_at is not null
    into v_phone, v_email, v_confirmed
    from auth.users u where u.id = v_link.auth_user_id;
  if v_phone is null or v_phone !~ '^\+[1-9][0-9]{7,14}$'
     or not app.identity_phone_username_permitted(v_phone)
     or app.identity_phone_username_taken(v_phone, v_link.auth_user_id) then
    perform app.cmd_fail('conflict', '{"member_id": "phone_unsupported"}', v_member.revision);
  end if;
  if v_email is not null
     and (not v_confirmed or not app.identity_recovery_email_permitted(v_email)
          or v_email !~ '^[a-z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-z0-9-]+(\.[a-z0-9-]+)+$') then
    perform app.cmd_fail('conflict', '{"member_id": "email_unverified"}', v_member.revision);
  end if;
  perform app.identity_neutralise_auth_tokens(v_link.auth_user_id,
    array['email_change_token_new', 'email_change_token_current', 'phone_change_token']);
  update auth.users u
     set email_change = '', email_change_token_new = '', email_change_token_current = '',
         email_change_confirm_status = 0, email_change_sent_at = null,
         phone_change = '', phone_change_token = '', phone_change_sent_at = null
   where u.id = v_link.auth_user_id
     and (coalesce(u.email_change, '') <> '' or coalesce(u.phone_change, '') <> '');
  v_sessions := app.identity_revoke_auth_sessions(v_link.auth_user_id);
  v_link := app.identity_record_binding(v_link.link_id, v_phone, v_email,
    'admin:' || v_actor.member_id::text, 'credentials_accepted');
  v_revision := app.identity_bump_member(v_member.member_id);
  perform app.identity_review_audit_add('credentials_accepted', v_actor.member_id,
    v_actor.account_id, v_request, v_member.member_id, v_link.link_id, null, null, null,
    p_payload ->> 'identity_check', v_link.binding_revision, v_revision, v_sessions);
  return app.identity_member_holds_outcome(v_member.member_id);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- 2.7 `other_changes`: email identities of addresses this account had approved or reviewed are
-- not new changes (Auth keeps an email identity after its address was removed or replaced).
-- Same signature and body otherwise.
-- ---------------------------------------------------------------------------------------------

create or replace function app.identity_recovery_email_other_changes(
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
                            and q.email = lower(coalesce(i.identity_data ->> 'email', '')))
                       -- Story 2.8: nor of an address once approved for this link or
                       -- reviewed as a replacement.
                       and not exists (
                         select 1 from app.identity_binding_history h
                          where h.link_id = p_row.link_id
                            and h.approved_recovery_email
                                = lower(coalesce(i.identity_data ->> 'email', '')))
                       and not exists (
                         select 1 from app.identity_credential_changes c
                          where c.link_id = p_row.link_id
                            and c.new_email = lower(coalesce(i.identity_data ->> 'email', ''))))))
      or exists (
           select 1 from app.identity_credential_events e
            where e.link_id = p_row.link_id
              and e.at >= p_row.proposed_at
              and e.kinds && array['phone', 'soft_deleted', 'user_deleted', 'identity_removed',
                                   'identity_moved', 'mfa_added', 'mfa_changed', 'mfa_removed']);
$$;

-- ---------------------------------------------------------------------------------------------
-- Command endpoint and authorizer
-- ---------------------------------------------------------------------------------------------

create function app.identity_credential_in_scope(p_actor uuid, p_aggregate_type text,
                                                 p_aggregate_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_aggregate_id is not null and case p_aggregate_type
    when 'identity_credential_change' then exists (
      select 1 from app.identity_credential_changes c where c.change_id = p_aggregate_id)
    when 'identity_member' then exists (
      select 1 from app.identity_members m where m.member_id = p_aggregate_id)
    else false end;
$$;

create function app.identity_credential_command(p_envelope jsonb)
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
      when 'identity.request_credential_change'
        then 'app.identity_request_credential_change(uuid, bigint, jsonb)'::regprocedure
      when 'identity.withdraw_credential_change'
        then 'app.identity_withdraw_credential_change(uuid, bigint, jsonb)'::regprocedure
      when 'identity.approve_credential_change'
        then 'app.identity_approve_credential_change(uuid, bigint, jsonb)'::regprocedure
      when 'identity.reject_credential_change'
        then 'app.identity_reject_credential_change(uuid, bigint, jsonb)'::regprocedure
      when 'identity.place_hold'
        then 'app.identity_place_hold(uuid, bigint, jsonb)'::regprocedure
      when 'identity.release_hold'
        then 'app.identity_release_hold(uuid, bigint, jsonb)'::regprocedure
      when 'identity.restore_credentials'
        then 'app.identity_restore_credentials(uuid, bigint, jsonb)'::regprocedure
      when 'identity.accept_credentials'
        then 'app.identity_accept_credentials(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.identity_credential_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'identity.request_credential_change'
  );
end;
$$;

-- POST /rest/v1/rpc/identity_credential_command, Content-Profile: api,
-- body {version, command, request_id, expected_revision, payload}.
create function api.identity_credential_command(jsonb)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.identity_credential_command($1);
$$;

comment on function api.identity_credential_command(jsonb) is
  'Story 2.8: reviewed phone-username and recovery-email changes, holds and credential review '
  '(1.4 command envelope).';

-- The registered `identity` authorizer: application commands keep the 2.4 applicant check; the
-- member requests (recovery-email proposal, credential change) need a granted session, the
-- withdrawals a linked trusted session (also in review); every decision, hold and review
-- command shares the 2.3 Admin branch unchanged.
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
  if coalesce(p_request ->> 'command', '') in ('identity.propose_recovery_email',
                                                'identity.request_credential_change') then
    return app.identity_authorize_member_credential_command(p_request);
  end if;
  if coalesce(p_request ->> 'command', '') in ('identity.withdraw_recovery_email',
                                                'identity.withdraw_credential_change') then
    return app.identity_authorize_member_withdraw_command(p_request);
  end if;
  if coalesce(p_request ->> 'command', '') not in (
       'identity.grant_role', 'identity.revoke_role', 'identity.grant_scope',
       'identity.revoke_scope',
       'identity.approve_application', 'identity.link_application',
       'identity.request_application_details', 'identity.reject_application',
       'identity.create_member', 'identity.unlink_account', 'identity.reclaim_phone_username',
       'identity.approve_recovery_email', 'identity.reject_recovery_email',
       'identity.approve_credential_change', 'identity.reject_credential_change',
       'identity.place_hold', 'identity.release_hold', 'identity.restore_credentials',
       'identity.accept_credentials') then
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

-- The member's own sign-in details and current request, also while the account is in review
-- (the help screen). `access` is generic: it never says whether a hold, a dispute or a change
-- is the reason. Signed-out/untrusted: 401; not linked: 403.
create function app.identity_my_credentials()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_link app.identity_account_links;
  v_pending app.identity_credential_changes;
  v_latest app.identity_credential_changes;
  v_proposal app.identity_recovery_email_proposals;
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
  select c.* into v_pending from app.identity_credential_changes c
   where c.link_id = v_link.link_id and c.change_state = 'pending';
  select c.* into v_latest from app.identity_credential_changes c
   where c.link_id = v_link.link_id and c.change_state <> 'pending'
   order by c.decided_at desc, c.change_id
   limit 1;
  select p.* into v_proposal from app.identity_recovery_email_proposals p
   where p.link_id = v_link.link_id and p.proposal_state = 'pending';
  if r.outcome = 'granted' then
    perform app.identity_record_activity(v_link.link_id);
  end if;
  return jsonb_build_object(
    'access', r.outcome,
    'phone_username', v_link.approved_phone,
    'recovery_email', v_link.approved_recovery_email,
    'pending_change', case when v_pending.change_id is null then null
                           else app.identity_credential_change_member_json(v_pending) end,
    'last_change', case when v_latest.change_id is null then null
                        else app.identity_credential_change_member_json(v_latest) end,
    'pending_recovery_email', case when v_proposal.proposal_id is null then null
                                   else app.identity_recovery_email_member_json(v_proposal) end,
    'can_request', r.outcome = 'granted' and v_pending.change_id is null
                   and v_proposal.proposal_id is null and app.identity_applications_open(),
    'church_contact', app.identity_church_setting('operational_contact') ->> 'route',
    'recent_sign_in_minutes', extract(epoch from app.identity_recent_password_window())::int / 60);
end;
$$;

create function api.identity_my_credentials()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.identity_my_credentials();
$$;

comment on function api.identity_my_credentials() is
  'Story 2.8: the signed-in member''s own sign-in details and current request, also while access '
  'is in review. POST /rest/v1/rpc/identity_my_credentials with Content-Profile: api.';

-- Admin only: pending credential changes, accounts waiting in access review with no pending
-- request (the change kinds Identity recorded, the current Auth values), and open holds.
create function app.identity_admin_credential_queue()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_member uuid;
  v_link_id uuid;
  v_changes jsonb;
  v_reviews jsonb;
  v_holds jsonb;
begin
  select g.member_id, g.link_id into v_actor_member, v_link_id
    from app.identity_require_grant('admin', null, null) g;
  select coalesce(jsonb_agg(app.identity_credential_change_admin_json(x)
                            || jsonb_build_object('member_revision', m.revision)
                            order by x.requested_at, x.change_id), '[]'::jsonb)
    into v_changes
    from (select c.* from app.identity_credential_changes c
           where c.change_state = 'pending'
           order by c.requested_at, c.change_id
           limit 100) x
    join app.identity_members m on m.member_id = x.member_id;
  select coalesce(jsonb_agg(y.obj order by y.updated_at, y.member_id), '[]'::jsonb)
    into v_reviews
    from (
      select l.updated_at, m.member_id, jsonb_build_object(
               'member_id', m.member_id,
               'display_name', m.display_name,
               'member_revision', m.revision,
               'link_state', l.link_state,
               'binding_review', l.binding_review_required,
               'phone_username', l.approved_phone,
               'recovery_email', l.approved_recovery_email,
               'auth_phone_username', app.identity_auth_phone(l.auth_user_id),
               'auth_email', (select lower(nullif(btrim(u.email), '')) from auth.users u
                               where u.id = l.auth_user_id),
               'auth_email_confirmed', (select u.email_confirmed_at is not null from auth.users u
                                         where u.id = l.auth_user_id),
               'extra_factors', app.identity_auth_has_extras(l.auth_user_id),
               'change_kinds', coalesce((
                 select jsonb_agg(distinct k order by k)
                   from app.identity_credential_events e, unnest(e.kinds) k
                  where e.link_id = l.link_id and e.binding_review and e.source like 'auth\_%'
                    and e.at >= (select max(h.approved_at) from app.identity_binding_history h
                                  where h.link_id = l.link_id)), '[]'::jsonb),
               'own_account', l.auth_user_id
                              = nullif(app.identity_request_claims() ->> 'sub', '')::uuid,
               'is_synthetic', m.is_synthetic) as obj
        from app.identity_account_links l
        join app.identity_members m on m.member_id = l.member_id
       where l.link_state in ('active', 'review_required')
         and (l.binding_review_required or l.link_state = 'review_required')
         and not exists (select 1 from app.identity_credential_changes c
                          where c.link_id = l.link_id and c.change_state = 'pending')
         and not exists (select 1 from app.identity_recovery_email_proposals p
                          where p.link_id = l.link_id and p.proposal_state = 'pending')
       order by l.updated_at, m.member_id
       limit 100) y;
  select coalesce(jsonb_agg(z.obj order by z.placed_at, z.hold_id), '[]'::jsonb)
    into v_holds
    from (
      select h.placed_at, h.hold_id, jsonb_build_object(
               'hold_id', h.hold_id,
               'member_id', m.member_id,
               'display_name', m.display_name,
               'member_revision', m.revision,
               'hold_kind', h.hold_kind,
               'reason_code', h.reason_code,
               'placed_at', h.placed_at,
               'own_member', m.member_id = v_actor_member,
               'is_synthetic', m.is_synthetic) as obj
        from app.identity_holds h
        join app.identity_members m on m.member_id = h.member_id
       where h.released_at is null
       order by h.placed_at, h.hold_id
       limit 200) z;
  perform app.identity_record_activity(v_link_id);
  return jsonb_build_object('changes', v_changes, 'reviews', v_reviews, 'holds', v_holds);
end;
$$;

create function api.identity_admin_credential_queue()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.identity_admin_credential_queue();
$$;

comment on function api.identity_admin_credential_queue() is
  'Story 2.8: Admin-only credential changes, accounts in access review and open holds.';

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.identity_revoke_auth_sessions(uuid),
  app.identity_remove_auth_extras(uuid, text),
  app.identity_credential_change_limit(),
  app.identity_phone_username_permitted(text),
  app.identity_on_hold_released(),
  app.identity_on_recovery_email_proposal_insert(),
  app.identity_auth_phone(uuid),
  app.identity_auth_has_extras(uuid),
  app.identity_phone_username_taken(text, uuid),
  app.identity_email_taken(text, uuid),
  app.identity_neutralise_auth_tokens(uuid, text[]),
  app.identity_record_binding(uuid, text, text, text, text),
  app.identity_bump_member(uuid),
  app.identity_review_audit_add(text, uuid, uuid, uuid, uuid, uuid,
                                app.identity_credential_changes, app.identity_holds, text, text,
                                bigint, bigint, integer),
  app.identity_credential_change_verified(app.identity_credential_changes),
  app.identity_credential_change_other_changes(app.identity_credential_changes),
  app.identity_credential_change_member_json(app.identity_credential_changes),
  app.identity_credential_change_admin_json(app.identity_credential_changes),
  app.identity_credential_change_outcome(uuid, boolean),
  app.identity_member_holds_json(uuid),
  app.identity_member_holds_outcome(uuid),
  app.identity_revert_credential_change(app.identity_credential_changes, text),
  app.identity_request_credential_change(uuid, bigint, jsonb),
  app.identity_withdraw_credential_change(uuid, bigint, jsonb),
  app.identity_lock_credential_change(jsonb, text[], boolean, bigint, uuid),
  app.identity_approve_credential_change(uuid, bigint, jsonb),
  app.identity_reject_credential_change(uuid, bigint, jsonb),
  app.identity_lock_reviewed_member(jsonb, text[], boolean, bigint, uuid),
  app.identity_place_hold(uuid, bigint, jsonb),
  app.identity_release_hold(uuid, bigint, jsonb),
  app.identity_lock_review_link(app.identity_members),
  app.identity_restore_credentials(uuid, bigint, jsonb),
  app.identity_accept_credentials(uuid, bigint, jsonb),
  app.identity_recovery_email_other_changes(app.identity_recovery_email_proposals),
  app.identity_credential_in_scope(uuid, text, uuid),
  app.identity_credential_command(jsonb),
  api.identity_credential_command(jsonb),
  app.identity_authorize_command(jsonb),
  app.identity_my_credentials(),
  api.identity_my_credentials(),
  app.identity_admin_credential_queue(),
  api.identity_admin_credential_queue()
  from public, anon, authenticated, service_role;

grant execute on function app.identity_credential_command(jsonb) to authenticated;
grant execute on function api.identity_credential_command(jsonb) to authenticated;
grant execute on function app.identity_my_credentials() to authenticated;
grant execute on function api.identity_my_credentials() to authenticated;
grant execute on function app.identity_admin_credential_queue() to authenticated;
grant execute on function api.identity_admin_credential_queue() to authenticated;
