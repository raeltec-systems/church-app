-- Identity live session trust across alternate Auth routes (story 2.2; AD-3, AD-13, AD-20).
--
-- Hardens the 2.1 predicate app.identity_access_evaluate() (same signature, replaced in place):
--
--   * Trusted detection (the 1.3 mechanism, owned by Identity). Triggers on auth.users,
--     auth.identities and auth.mfa_factors run inside GoTrue's own transaction. For a LINKED
--     account every credential change advances app.identity_account_links.credential_generation
--     and sets the link's session trust epoch (sessions_valid_after); a binding change (phone,
--     email, identity added/removed/moved, MFA factor, delete) also sets the durable
--     binding_review_required flag (and moves an active link to review_required). The flag
--     persists through value reverts, suspension and unsuspension; only a re-approval that
--     records a new binding_revision clears it. Only change kinds are recorded, never
--     phone/email values or secrets. Unlinked accounts are ignored.
--   * A hold placed on a member, or any link state change, also sets the trust epoch (and
--     records an event), so the sessions it was meant to stop never come back when it clears,
--     and a re-approved link admits only sessions created after the approval.
--   * A link inserted for an account or member that had an earlier link (a relink after
--     `ended`) starts with a trust epoch at its creation and the next credential generation, so
--     no session from before the relink passes. A first link for a fresh signup has no epoch.
--   * The predicate now also requires: `password` in the SERVER's session AMR record
--     (auth.mfa_amr_claims) as well as in the signed JWT `amr`; no pending binding review; a
--     session created more than the safety margin (5 s, identity_epoch_margin()) after the
--     link's trust epoch; a non-anonymous Auth user; and, when a recovery email is approved,
--     that the current Auth email is confirmed.
--
-- Order of the predicate's checks (first failure wins):
--   unauthenticated -> untrusted_session (JWT/session/user) -> not_linked -> review_required
--   (link state, binding, holds) -> untrusted_session (session older than the trust epoch)
--   -> unavailable (unset dormancy) -> review_required (dormancy, prior activity) -> unavailable
--   (release gate) -> granted.
--
-- Known limits (inherited from 1.3, see evidence-1.3 "Known limits"):
--   * F: the triggers take the Identity link row lock inside GoTrue transactions that already
--     hold auth.* row locks. Identity never touches auth.* rows while holding a link lock, so no
--     inversion is known, but GoTrue's internal lock order is not under our control.
--   * The trust epoch (database clock_timestamp() inside the changing transaction) is compared
--     with GoTrue's session created_at (GoTrue's clock). A session must be created MORE than
--     identity_epoch_margin() (5 s) after the epoch. Residual cases: (a) a GoTrue clock AHEAD of
--     the database by more than the margin could admit a session opened just before the change
--     (fail open); a GoTrue clock behind only delays fresh sign-ins (fail closed); (b) a session
--     created while the changing transaction is still open, more than the margin after the
--     epoch was stamped (a transaction held open > 5 s), is admitted (fail open). Both need
--     clock sync and short Auth transactions; neither is reachable by a client alone.
--
-- No destructive statements. No client privileges. The api wrapper and its grants are unchanged.

-- ---------------------------------------------------------------------------------------------
-- Link columns
-- ---------------------------------------------------------------------------------------------

alter table app.identity_account_links
  add column credential_generation bigint not null default 1 check (credential_generation >= 1),
  add column sessions_valid_after timestamptz,
  add column binding_review_required boolean not null default false;

comment on column app.identity_account_links.credential_generation is
  'AD-20 recovery/credential generation: advanced by every detected Auth credential change.';
comment on column app.identity_account_links.sessions_valid_after is
  'Session trust epoch: only Auth sessions created more than identity_epoch_margin() after it '
  'may pass the predicate.';
comment on column app.identity_account_links.binding_review_required is
  'A direct Auth binding change was detected. Cleared only by a re-approval that records a new '
  'binding_revision; never by reverting the value or by a link state change.';

-- Safety margin between a trust epoch and an admissible session (clock skew / commit delay).
create function app.identity_epoch_margin()
returns interval
language sql
immutable
set search_path = ''
as $$ select interval '5 seconds' $$;

-- ---------------------------------------------------------------------------------------------
-- Credential events (kinds only; no values)
-- ---------------------------------------------------------------------------------------------

create table app.identity_credential_events (
  event_id bigint generated always as identity primary key,
  link_id uuid not null references app.identity_account_links (link_id),
  source text not null
    check (source in ('auth_users', 'auth_identities', 'auth_mfa_factors', 'identity_holds',
                      'identity_account_links')),
  kinds text[] not null check (cardinality(kinds) > 0),
  binding_review boolean not null,
  generation_after bigint not null,
  epoch_after timestamptz,
  at timestamptz not null default clock_timestamp()
);

comment on table app.identity_credential_events is
  'owner: identity. Detected Auth credential changes and trust-epoch moves for linked accounts. '
  'Kinds only: never phone, email, password or token values.';

create index identity_credential_events_link on app.identity_credential_events (link_id, event_id);

alter table app.identity_credential_events enable row level security;
revoke all on table app.identity_credential_events from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Detection
-- ---------------------------------------------------------------------------------------------

-- Records a credential change on the LIVE link of p_auth_user_id (if any): advances the
-- generation, sets the trust epoch, and for a binding change moves an active link to review.
create function app.identity_note_credential_change(
  p_auth_user_id uuid,
  p_source text,
  p_kinds text[],
  p_binding boolean
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link uuid;
  v_generation bigint;
  v_epoch timestamptz;
begin
  if p_auth_user_id is null or cardinality(p_kinds) = 0 then
    return;
  end if;
  update app.identity_account_links l
     set credential_generation = l.credential_generation + 1,
         sessions_valid_after = greatest(coalesce(l.sessions_valid_after, '-infinity'),
                                         clock_timestamp()),
         link_state = case when p_binding and l.link_state = 'active'
                           then 'review_required' else l.link_state end,
         binding_review_required = l.binding_review_required or p_binding,
         updated_at = now()
   where l.auth_user_id = p_auth_user_id and l.link_state <> 'ended'
  returning l.link_id, l.credential_generation, l.sessions_valid_after
       into v_link, v_generation, v_epoch;
  if v_link is null then
    return;
  end if;
  insert into app.identity_credential_events (link_id, source, kinds, binding_review,
                                              generation_after, epoch_after)
  values (v_link, p_source, p_kinds, p_binding, v_generation, v_epoch);
end;
$$;

create function app.identity_on_auth_user_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kinds text[] := '{}';
  v_binding boolean := false;
begin
  if tg_op = 'DELETE' then
    perform app.identity_note_credential_change(old.id, 'auth_users', array['user_deleted'], true);
    return null;
  end if;
  if new.phone is distinct from old.phone then
    v_kinds := array_append(v_kinds, 'phone'); v_binding := true;
  end if;
  if new.email is distinct from old.email then
    v_kinds := array_append(v_kinds, 'email'); v_binding := true;
  end if;
  if new.deleted_at is distinct from old.deleted_at then
    v_kinds := array_append(v_kinds, 'soft_deleted'); v_binding := true;
  end if;
  if new.encrypted_password is distinct from old.encrypted_password then
    v_kinds := array_append(v_kinds, 'password');
  end if;
  if new.banned_until is distinct from old.banned_until then
    v_kinds := array_append(v_kinds, 'ban_changed');
  end if;
  perform app.identity_note_credential_change(new.id, 'auth_users', v_kinds, v_binding);
  return null;
end;
$$;

create function app.identity_on_auth_identity_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform app.identity_note_credential_change(new.user_id, 'auth_identities',
      array['identity_added'], true);
  elsif tg_op = 'DELETE' then
    perform app.identity_note_credential_change(old.user_id, 'auth_identities',
      array['identity_removed'], true);
  else
    -- An identity re-pointed to another user or provider id: both accounts are affected.
    perform app.identity_note_credential_change(old.user_id, 'auth_identities',
      array['identity_moved'], true);
    if new.user_id is distinct from old.user_id then
      perform app.identity_note_credential_change(new.user_id, 'auth_identities',
        array['identity_moved'], true);
    end if;
  end if;
  return null;
end;
$$;

create function app.identity_on_auth_mfa_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    perform app.identity_note_credential_change(old.user_id, 'auth_mfa_factors',
      array['mfa_removed'], true);
  else
    perform app.identity_note_credential_change(new.user_id, 'auth_mfa_factors',
      array[case tg_op when 'INSERT' then 'mfa_added' else 'mfa_changed' end], true);
  end if;
  return null;
end;
$$;

-- If any of these fail, GoTrue's own write fails too: no unrecorded change (fail closed).
create trigger identity_credential_change
  after update of phone, email, encrypted_password, deleted_at, banned_until on auth.users
  for each row
  when (old.phone is distinct from new.phone
        or old.email is distinct from new.email
        or old.encrypted_password is distinct from new.encrypted_password
        or old.deleted_at is distinct from new.deleted_at
        or old.banned_until is distinct from new.banned_until)
  execute function app.identity_on_auth_user_change();

create trigger identity_credential_delete
  after delete on auth.users
  for each row
  execute function app.identity_on_auth_user_change();

create trigger identity_credential_identity_change
  after insert or delete on auth.identities
  for each row
  execute function app.identity_on_auth_identity_change();

create trigger identity_credential_identity_moved
  after update of user_id, provider_id, provider on auth.identities
  for each row
  when ((old.user_id, old.provider_id, old.provider)
        is distinct from (new.user_id, new.provider_id, new.provider))
  execute function app.identity_on_auth_identity_change();

create trigger identity_credential_mfa_change
  after insert or delete on auth.mfa_factors
  for each row
  execute function app.identity_on_auth_mfa_change();

create trigger identity_credential_mfa_update
  after update of status, secret, phone, factor_type on auth.mfa_factors
  for each row
  when ((old.status, old.secret, old.phone, old.factor_type)
        is distinct from (new.status, new.secret, new.phone, new.factor_type))
  execute function app.identity_on_auth_mfa_change();

-- Every link state change moves the trust epoch: leaving 'active' (review, suspension, end)
-- stops existing sessions, and returning to 'active' (the reviewed re-approval of entries 5/8)
-- admits only sessions created after the approval, never one opened while access was in review
-- (the 1.3 reconcile rule). The pending binding review flag survives everything except a
-- re-approval that records a new binding_revision.
create function app.identity_on_link_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.binding_revision > old.binding_revision then
    new.binding_review_required := false;  -- re-approval recorded a new binding revision
  elsif old.binding_review_required then
    new.binding_review_required := true;   -- nothing else clears a pending binding review
  end if;
  if new.link_state is distinct from old.link_state then
    new.sessions_valid_after := greatest(coalesce(new.sessions_valid_after, '-infinity'),
                                         clock_timestamp());
    insert into app.identity_credential_events (link_id, source, kinds, binding_review,
                                                generation_after, epoch_after)
    values (new.link_id, 'identity_account_links', array['link_' || new.link_state],
            new.binding_review_required, new.credential_generation, new.sessions_valid_after);
  end if;
  return new;
end;
$$;

create trigger identity_link_state_epoch
  before update on app.identity_account_links
  for each row
  execute function app.identity_on_link_update();

-- A relink (a new link for an account or member that had one before) starts with a trust epoch
-- at its creation and the next credential generation; a first link keeps no epoch.
create function app.identity_on_link_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prior_generation bigint;
begin
  select max(l.credential_generation) into v_prior_generation
    from app.identity_account_links l
   where l.auth_user_id = new.auth_user_id or l.member_id = new.member_id;
  if v_prior_generation is not null then
    new.credential_generation := greatest(new.credential_generation, v_prior_generation + 1);
    new.sessions_valid_after := greatest(coalesce(new.sessions_valid_after, '-infinity'),
                                         clock_timestamp());
  end if;
  return new;
end;
$$;

create trigger identity_link_insert_epoch
  before insert on app.identity_account_links
  for each row
  execute function app.identity_on_link_insert();

create function app.identity_on_link_inserted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.sessions_valid_after is not null then
    insert into app.identity_credential_events (link_id, source, kinds, binding_review,
                                                generation_after, epoch_after)
    values (new.link_id, 'identity_account_links', array['link_relinked'], false,
            new.credential_generation, new.sessions_valid_after);
  end if;
  return null;
end;
$$;

create trigger identity_link_inserted_event
  after insert on app.identity_account_links
  for each row
  execute function app.identity_on_link_inserted();

-- A hold placed on a member moves the trust epoch of the member's live link.
create function app.identity_on_hold_placed()
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
    values (v_link, 'identity_holds', array['hold_' || new.hold_kind], false, v_generation,
            v_epoch);
  end if;
  return null;
end;
$$;

create trigger identity_hold_epoch
  after insert on app.identity_holds
  for each row
  execute function app.identity_on_hold_placed();

-- ---------------------------------------------------------------------------------------------
-- The live-access predicate (replaces 2.1's body; same signature and grants)
-- ---------------------------------------------------------------------------------------------

create or replace function app.identity_access_evaluate()
returns table (outcome text, member_id uuid, link_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_uuid constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  v_claims jsonb := app.identity_request_claims();
  v_sub uuid;
  v_session uuid;
  v_session_created timestamptz;
  v_phone text;
  v_email text;
  v_email_confirmed boolean;
  v_link app.identity_account_links;
  v_member app.identity_members;
  v_days integer;
begin
  if coalesce(v_claims ->> 'sub', '') !~* c_uuid then
    return query select 'unauthenticated'::text, null::uuid, null::uuid;
    return;
  end if;
  v_sub := (v_claims ->> 'sub')::uuid;

  -- Session half (story 1.2): signed `password` AMR AND a live session row for this subject.
  if coalesce(v_claims ->> 'role', '') <> 'authenticated'
     or coalesce(v_claims ->> 'is_anonymous', 'false') = 'true'
     or jsonb_typeof(v_claims -> 'amr') is distinct from 'array'
     or not exists (
       select 1 from jsonb_array_elements(v_claims -> 'amr') a(entry)
        where jsonb_typeof(a.entry) = 'object' and a.entry ->> 'method' = 'password')
     or coalesce(v_claims ->> 'session_id', '') !~* c_uuid then
    return query select 'untrusted_session'::text, null::uuid, null::uuid;
    return;
  end if;
  v_session := (v_claims ->> 'session_id')::uuid;
  select s.created_at into v_session_created
    from auth.sessions s
   where s.id = v_session and s.user_id = v_sub
     and (s.not_after is null or s.not_after > now());
  if not found then
    return query select 'untrusted_session'::text, null::uuid, null::uuid;
    return;
  end if;
  -- Story 2.2: the server's own record of how this session authenticated must also say
  -- `password` (a custom access-token hook cannot mint trust by rewriting the JWT amr).
  if not exists (
    select 1 from auth.mfa_amr_claims c
     where c.session_id = v_session and c.authentication_method = 'password') then
    return query select 'untrusted_session'::text, null::uuid, null::uuid;
    return;
  end if;

  select nullif(btrim(u.phone), ''), lower(nullif(btrim(u.email), '')),
         u.email_confirmed_at is not null
    into v_phone, v_email, v_email_confirmed
    from auth.users u
   where u.id = v_sub
     and u.deleted_at is null
     and not coalesce(u.is_anonymous, false)
     and (u.banned_until is null or u.banned_until <= now());
  if not found then
    return query select 'untrusted_session'::text, null::uuid, null::uuid;
    return;
  end if;

  -- Approved member link (AD-3). No row lock: the predicate must also run inside read-only
  -- (GET) requests; a command that mutates under this access locks its own rows.
  select l.* into v_link
    from app.identity_account_links l
   where l.auth_user_id = v_sub and l.link_state <> 'ended';
  if not found then
    return query select 'not_linked'::text, null::uuid, null::uuid;
    return;
  end if;
  select m.* into v_member from app.identity_members m where m.member_id = v_link.member_id;
  if v_member.membership_state <> 'approved' then
    return query select 'not_linked'::text, null::uuid, null::uuid;
    return;
  end if;
  -- A detected direct Auth binding change keeps the link in review until the authorised
  -- workflow accepts it, even if the value is changed back.
  if v_link.link_state <> 'active' or v_link.binding_review_required then
    return query select 'review_required'::text, v_member.member_id, v_link.link_id;
    return;
  end if;

  -- Current Auth credentials must equal the approved binding. Auth stores the phone without
  -- the leading '+'. An approved recovery email counts only while Auth has it confirmed.
  if v_phone is null
     or '+' || ltrim(v_phone, '+') <> v_link.approved_phone
     or coalesce(v_email, '') <> coalesce(v_link.approved_recovery_email, '')
     or (v_link.approved_recovery_email is not null and not v_email_confirmed) then
    return query select 'review_required'::text, v_member.member_id, v_link.link_id;
    return;
  end if;

  if exists (select 1 from app.identity_holds h
              where h.member_id = v_member.member_id and h.released_at is null) then
    return query select 'review_required'::text, v_member.member_id, v_link.link_id;
    return;
  end if;

  -- Sessions from before a credential change, hold or review stay dead: sign in again.
  if v_link.sessions_valid_after is not null
     and (v_session_created is null
          or v_session_created <= v_link.sessions_valid_after + app.identity_epoch_margin()) then
    return query select 'untrusted_session'::text, null::uuid, null::uuid;
    return;
  end if;

  -- Dormancy against the PREVIOUSLY stored activity, before any refresh.
  v_days := (app.identity_setting('dormancy_days') ->> 'days')::integer;
  if v_days is null then
    return query select 'unavailable'::text, v_member.member_id, v_link.link_id;
    return;
  end if;
  if coalesce(v_link.last_member_activity_at, v_link.approved_at)
       < now() - make_interval(days => v_days) then
    return query select 'review_required'::text, v_member.member_id, v_link.link_id;
    return;
  end if;

  if not (app.policy_is_open('private_access')
          or (v_member.is_synthetic
              and app.platform_current_environment() in ('local', 'staging')
              and not app.rcv_serving_hold())) then
    return query select 'unavailable'::text, v_member.member_id, v_link.link_id;
    return;
  end if;

  return query select 'granted'::text, v_member.member_id, v_link.link_id;
end;
$$;

comment on function app.identity_access_evaluate() is
  'AD-3 live-access predicate for human sessions (2.1, hardened by 2.2). Every protected '
  'surface must use it.';

-- ---------------------------------------------------------------------------------------------
-- Privileges: nothing new is client-executable.
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.identity_access_evaluate(),
  app.identity_note_credential_change(uuid, text, text[], boolean),
  app.identity_on_auth_user_change(),
  app.identity_on_auth_identity_change(),
  app.identity_on_auth_mfa_change(),
  app.identity_epoch_margin(),
  app.identity_on_link_update(),
  app.identity_on_link_insert(),
  app.identity_on_link_inserted(),
  app.identity_on_hold_placed()
  from public, anon, authenticated, service_role;
