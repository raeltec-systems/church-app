-- Identity live access (story 2.1; AD-3, AD-4, AD-13, AD-20).
--
-- The Identity owner's first records and the ONE server live-access predicate that every
-- protected read, command, subscription and file route uses:
--
--   app.identity_access_evaluate() -> (outcome, member_id, link_id)
--     unauthenticated   no verified JWT subject
--     untrusted_session no `password` entry in the signed `amr`, or no live auth.sessions row for
--                       the JWT's session_id and subject (deleted, expired by not_after), or the
--                       Auth user is deleted or banned
--     not_linked        no live account link, or the member is not church-approved
--     review_required   link not active, the current Auth phone/email differs from the approved
--                       binding, an open hold, or dormancy past the effective setting
--     unavailable       the dormancy setting is unset here (production until entry 14), or the
--                       private_access release gate is closed for this member
--     granted
--
-- AMR alone never grants access: story 1.2 finding F1 showed phone `/otp` with create_user can
-- leave a server-side `password`-AMR session for any number. Access also needs the
-- staff-approved link and binding below. Login, token refresh and denied calls never refresh
-- activity; only a granted protected operation does (dormancy is evaluated first).
--
-- Grants and scopes (entry 3) extend this predicate; they are not modelled here.
--
-- Release gate: private member data is served only when app.policy_is_open('private_access'),
-- except SYNTHETIC members in a database marked local or staging that is not a held restore.
-- verify-hosted.sql keeps the gate itself closed on staging.
--
-- No destructive statements. No client table privileges. Clients reach only the api wrapper.

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

create table app.identity_members (
  member_id uuid primary key default gen_random_uuid(),
  display_name text not null check (length(btrim(display_name)) between 1 and 120),
  membership_state text not null default 'pending'
    check (membership_state in ('pending', 'approved', 'rejected', 'deactivated')),
  -- Synthetic records may be served in local/staging while private_access stays closed.
  is_synthetic boolean not null default false,
  revision bigint not null default 1 check (revision >= 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table app.identity_members is
  'owner: identity. The stable person (member_id). Needs no account, phone or email.';

create table app.identity_account_links (
  link_id uuid primary key default gen_random_uuid(),
  member_id uuid not null references app.identity_members (member_id),
  -- Supabase Auth user id. Deliberately no FK into auth: Identity never adds objects to auth.
  auth_user_id uuid not null,
  link_state text not null default 'active'
    check (link_state in ('active', 'review_required', 'suspended', 'ended')),
  -- Approved credential binding (versioned): normalized E.164 phone username and the optional
  -- verified recovery email. Compared with the CURRENT auth.users values on every check.
  approved_phone text not null check (approved_phone ~ '^\+[1-9][0-9]{7,14}$'),
  approved_recovery_email text check (
    approved_recovery_email is null
    or (approved_recovery_email = lower(btrim(approved_recovery_email))
        and approved_recovery_email ~ '^[^@\s]+@[^@\s]+$')
  ),
  binding_revision bigint not null default 1 check (binding_revision >= 1),
  approved_by text not null check (length(btrim(approved_by)) > 0),
  approved_at timestamptz not null default now(),
  -- Last authorised member activity; null means none yet (approved_at is the baseline).
  last_member_activity_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((link_state = 'ended') = (ended_at is not null))
);

comment on table app.identity_account_links is
  'owner: identity. Member <-> Auth account link with the approved phone/recovery-email binding. '
  'At most one live link per member, per account and per phone username.';

create unique index identity_account_links_one_live_per_member
  on app.identity_account_links (member_id) where link_state <> 'ended';
create unique index identity_account_links_one_live_per_account
  on app.identity_account_links (auth_user_id) where link_state <> 'ended';
create unique index identity_account_links_one_live_per_phone
  on app.identity_account_links (approved_phone) where link_state <> 'ended';

create table app.identity_binding_history (
  link_id uuid not null references app.identity_account_links (link_id),
  binding_revision bigint not null check (binding_revision >= 1),
  approved_phone text not null,
  approved_recovery_email text,
  approved_by text not null,
  approved_at timestamptz not null default now(),
  reason text not null check (length(btrim(reason)) > 0),
  primary key (link_id, binding_revision)
);

comment on table app.identity_binding_history is
  'owner: identity. Every approved binding revision of a link, with approver and reason.';

create table app.identity_holds (
  hold_id uuid primary key default gen_random_uuid(),
  member_id uuid not null references app.identity_members (member_id),
  hold_kind text not null check (hold_kind in ('security', 'access_review', 'login')),
  reason text not null check (length(btrim(reason)) > 0),
  placed_by text not null check (length(btrim(placed_by)) > 0),
  placed_at timestamptz not null default now(),
  released_at timestamptz,
  released_by text,
  check ((released_at is null) = (released_by is null))
);

comment on table app.identity_holds is
  'owner: identity. An unreleased hold denies private access across every session.';

create index identity_holds_open on app.identity_holds (member_id) where released_at is null;

-- Versioned Identity settings (Q1 values). A fixture row is honoured only in a database marked
-- local or staging; production needs an approved row (entry 14), so it fails closed until then.
create table app.identity_settings (
  setting text not null check (setting in ('dormancy_days')),
  version integer not null check (version >= 1),
  value jsonb not null check (jsonb_typeof(value) = 'object'),
  source text not null check (source in ('fixture', 'approved')),
  label text not null check (length(btrim(label)) > 0),
  set_by text not null check (length(btrim(set_by)) > 0),
  set_at timestamptz not null default now(),
  primary key (setting, version),
  check (source <> 'fixture' or label like 'TEST FIXTURE%'),
  check (source <> 'approved' or label not like 'TEST FIXTURE%'),
  check (setting <> 'dormancy_days' or (
    jsonb_typeof(value -> 'days') = 'number'
    and (value ->> 'days') ~ '^[0-9]+$'
    and (value ->> 'days')::integer between 1 and 3650))
);

comment on table app.identity_settings is
  'owner: identity. Versioned Q1 settings. Fixture rows count only in local/staging.';

insert into app.identity_settings (setting, version, value, source, label, set_by) values
  ('dormancy_days', 1, '{"days": 90}', 'fixture',
   'TEST FIXTURE - proposed 90-day dormancy, not church policy', 'story 2.1 migration');

alter table app.identity_members enable row level security;
alter table app.identity_account_links enable row level security;
alter table app.identity_binding_history enable row level security;
alter table app.identity_holds enable row level security;
alter table app.identity_settings enable row level security;

-- No client role touches Identity tables (no policies, no privileges).
revoke all on table app.identity_members, app.identity_account_links,
  app.identity_binding_history, app.identity_holds, app.identity_settings
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------------------------

-- Effective value: the latest approved row; else, only in local/staging, the latest fixture;
-- else null (callers fail closed).
create function app.identity_setting(p_setting text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select s.value from app.identity_settings s
      where s.setting = p_setting and s.source = 'approved'
      order by s.version desc limit 1),
    (select s.value from app.identity_settings s
      where s.setting = p_setting and s.source = 'fixture'
        and app.platform_current_environment() in ('local', 'staging')
      order by s.version desc limit 1)
  );
$$;

-- ---------------------------------------------------------------------------------------------
-- The live-access predicate
-- ---------------------------------------------------------------------------------------------

-- Verified JWT claims of the current request (set by PostgREST after signature checks), or
-- an empty object. Never trusts a claim it cannot parse.
create function app.identity_request_claims()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v jsonb;
begin
  begin
    v := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  exception when others then
    v := null;
  end;
  if v is null or jsonb_typeof(v) <> 'object' then
    return '{}'::jsonb;
  end if;
  return v;
end;
$$;

create function app.identity_access_evaluate()
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
  v_phone text;
  v_email text;
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
  if not exists (
    select 1 from auth.sessions s
     where s.id = v_session and s.user_id = v_sub
       and (s.not_after is null or s.not_after > now())) then
    return query select 'untrusted_session'::text, null::uuid, null::uuid;
    return;
  end if;

  select nullif(btrim(u.phone), ''), lower(nullif(btrim(u.email), ''))
    into v_phone, v_email
    from auth.users u
   where u.id = v_sub
     and u.deleted_at is null
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
  if v_link.link_state <> 'active' then
    return query select 'review_required'::text, v_member.member_id, v_link.link_id;
    return;
  end if;

  -- Current Auth credentials must equal the approved binding. Auth stores the phone without
  -- the leading '+'. A changed, added or removed phone/email needs review before access.
  if v_phone is null
     or '+' || ltrim(v_phone, '+') <> v_link.approved_phone
     or coalesce(v_email, '') <> coalesce(v_link.approved_recovery_email, '') then
    return query select 'review_required'::text, v_member.member_id, v_link.link_id;
    return;
  end if;

  if exists (select 1 from app.identity_holds h
              where h.member_id = v_member.member_id and h.released_at is null) then
    return query select 'review_required'::text, v_member.member_id, v_link.link_id;
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
  'AD-3 live-access predicate for human sessions. Every protected surface must use it.';

-- For RLS policies and owner checks: the caller's member_id when access is granted, else null.
create function app.identity_current_member_id()
returns uuid
language sql
security definer
set search_path = ''
as $$
  select e.member_id from app.identity_access_evaluate() e where e.outcome = 'granted';
$$;

-- Raises the denial for a non-granted outcome. HTTP: 401 for unauthenticated/untrusted
-- sessions, 403 otherwise. message = error vocabulary code, detail = the caller's own reason.
create function app.identity_require_access()
returns table (member_id uuid, link_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  select e.* into r from app.identity_access_evaluate() e;
  if r.outcome = 'granted' then
    return query select r.member_id, r.link_id;
    return;
  end if;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    raise exception using errcode = 'PT401', message = 'unauthenticated', detail = r.outcome;
  elsif r.outcome = 'unavailable' then
    raise exception using errcode = 'PT403', message = 'unavailable', detail = r.outcome;
  else
    raise exception using errcode = 'PT403', message = 'forbidden', detail = r.outcome;
  end if;
end;
$$;

-- Records authorised member activity. Call only after identity_require_access succeeded.
create function app.identity_record_activity(p_link_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update app.identity_account_links l
     set last_member_activity_at = now()
   where l.link_id = p_link_id and l.link_state = 'active';
$$;

-- ---------------------------------------------------------------------------------------------
-- The tracer read: the caller's own member summary
-- ---------------------------------------------------------------------------------------------

create function app.identity_my_member_summary()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member_id uuid;
  v_link_id uuid;
  v_result jsonb;
begin
  select a.member_id, a.link_id into v_member_id, v_link_id from app.identity_require_access() a;
  select jsonb_build_object(
           'member_id', m.member_id,
           'display_name', m.display_name,
           'membership_state', m.membership_state,
           'phone_username', l.approved_phone,
           'has_recovery_email', l.approved_recovery_email is not null,
           'is_synthetic', m.is_synthetic)
    into v_result
    from app.identity_members m
    join app.identity_account_links l on l.member_id = m.member_id
   where m.member_id = v_member_id and l.link_id = v_link_id;
  perform app.identity_record_activity(v_link_id);
  return v_result;
end;
$$;

create function api.identity_my_member_summary()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.identity_my_member_summary();
$$;

comment on function api.identity_my_member_summary() is
  'Story 2.1 tracer read: the signed-in member''s own summary, behind the live-access '
  'predicate. POST /rest/v1/rpc/identity_my_member_summary with Content-Profile: api.';

-- ---------------------------------------------------------------------------------------------
-- Restricted operator seeding (no client grants): a SYNTHETIC approved member linked to an
-- existing Auth account, for local/staging tracer runs only. Admin review and linking is
-- entry 5; this is not that workflow.
-- ---------------------------------------------------------------------------------------------

create function app.identity_seed_synthetic_link(
  p_auth_user_id uuid,
  p_display_name text,
  p_set_by text
) returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_phone text;
  v_email text;
  v_member uuid;
  v_link uuid;
begin
  if app.platform_current_environment() not in ('local', 'staging') then
    raise exception using errcode = '22023',
      message = 'synthetic links are allowed only in a database marked local or staging';
  end if;
  if coalesce(p_display_name, '') !~ '^SYNTHETIC [^[:cntrl:]]{1,100}$' then
    raise exception using errcode = '22023',
      message = 'display name must start with "SYNTHETIC "';
  end if;
  if length(btrim(coalesce(p_set_by, ''))) = 0 then
    raise exception using errcode = '22023', message = 'set_by is required';
  end if;
  select '+' || ltrim(nullif(btrim(u.phone), ''), '+'), lower(nullif(btrim(u.email), ''))
    into v_phone, v_email
    from auth.users u where u.id = p_auth_user_id and u.deleted_at is null;
  if not found or v_phone is null then
    raise exception using errcode = '22023', message = 'no Auth user with a phone username';
  end if;
  -- Reserved fictional ranges only: NANP 202-555-0100..0199, Ofcom drama 07700 900000..900999.
  if v_phone !~ '^\+120255501[0-9]{2}$' and v_phone !~ '^\+447700900[0-9]{3}$' then
    raise exception using errcode = '22023',
      message = 'phone username is not in a reserved fictional range';
  end if;
  if v_email is not null and v_email !~ '(@example\.(test|com)|\.invalid)$' then
    raise exception using errcode = '22023', message = 'recovery email is not synthetic';
  end if;
  insert into app.identity_members (display_name, membership_state, is_synthetic)
  values (btrim(p_display_name), 'approved', true)
  returning member_id into v_member;
  insert into app.identity_account_links (member_id, auth_user_id, approved_phone,
                                          approved_recovery_email, approved_by)
  values (v_member, p_auth_user_id, v_phone, v_email, btrim(p_set_by))
  returning link_id into v_link;
  insert into app.identity_binding_history (link_id, binding_revision, approved_phone,
                                            approved_recovery_email, approved_by, reason)
  values (v_link, 1, v_phone, v_email, btrim(p_set_by), 'SYNTHETIC tracer seed (story 2.1)');
  return v_member;
end;
$$;

comment on function app.identity_seed_synthetic_link(uuid, text, text) is
  'Restricted operator only (no grants). SYNTHETIC approved member + link for local/staging.';

-- ---------------------------------------------------------------------------------------------
-- Privileges: only the read path is executable, and only by authenticated sessions.
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.identity_setting(text),
  app.identity_request_claims(),
  app.identity_access_evaluate(),
  app.identity_current_member_id(),
  app.identity_require_access(),
  app.identity_record_activity(uuid),
  app.identity_my_member_summary(),
  api.identity_my_member_summary(),
  app.identity_seed_synthetic_link(uuid, text, text)
  from public, anon, authenticated, service_role;

grant execute on function app.identity_my_member_summary() to authenticated;
grant execute on function api.identity_my_member_summary() to authenticated;
