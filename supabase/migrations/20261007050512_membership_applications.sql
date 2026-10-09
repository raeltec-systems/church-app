-- Membership applications with a safe cell choice (story 2.4; AD-1, AD-2, AD-3, AD-4, AD-5).
--
-- Cells (first records of the Cells owner):
--   * app.cells_cells: the cell record. Entry 6 adds Admin setup, leaders and venues; until then
--     cells come only from the restricted, non-production SYNTHETIC seed
--     app.cells_seed_synthetic_cells. The real cell list is an owner gate (entries 6/14).
--   * app.cells_signup_options: the separately persisted safe sign-up projection (AD-5): a
--     church-approved label and a broad area only. Never members, leaders, addresses, phones,
--     chat or reports. SYNTHETIC options are listed only in a database marked local or staging.
--   * api.cells_signup_options(): the chooser read, for trusted password sessions that are
--     applicants (`not_linked`) or members (`granted`).
--   * Source type `cells_signup_option` (1.5 seam) with a check hook, so Identity validates a
--     chosen cell through app.contract_check_source without depending on Cells.
--
-- Identity:
--   * app.identity_membership_applications: one applicant account's correctable request (name,
--     privacy-notice version, cell choice `cell` | `not_sure` | `not_in_cell`). It creates no
--     member, link, grant, scope or cell membership: the applicant still gets `not_linked` from
--     app.identity_access_evaluate() everywhere. Review/linking is entry 5; cell confirmation
--     and the follow-up queue are entry 6. The state CHECKs already list their states, because
--     widening a CHECK later would need a destructive statement.
--   * app.identity_application_events: content-free history (ids, revisions, changed field names).
--   * Commands (1.4 envelope) through api.identity_application_command:
--       identity.submit_application  expected_revision null
--         payload {full_name, cell_choice {choice, cell_id?, cell_revision?}, privacy_notice_version}
--       identity.correct_application expected_revision = the application's revision
--         payload {application_id, full_name?, cell_choice?}
--     The registered `identity` authorizer now dispatches: application commands need a trusted
--     password session whose predicate outcome is `not_linked`; grant commands keep the 2.3 body.
--   * api.identity_my_application(): the caller's own application and the privacy notice.
--   * Personal-data gate: applications (and the chooser) are open only when the database is not
--     a held restore AND (q4_personal_data is approved, or the database is marked local/staging).
--     While Q4 is unapproved the applicant's phone username must be in a reserved fictional range
--     and the full name must start with `SYNTHETIC `. Otherwise `unavailable` / validation_failed.
--   * Who is an applicant: a trusted password session (the predicate's own session checks) of an
--     account with NO live account link and no open hold on any member it was ever linked to.
--     An account linked to a pending, rejected or deactivated member, or held, is refused.
--   * Abuse limit: APPLICATION_CORRECTION_LIMIT = 10 corrections per application per rolling
--     24 hours (app.identity_application_correction_limit()); beyond it `rate_limited`.
--     Deferred (not built here): sign-up rate limits are Supabase Auth's own settings;
--     re-applying after a rejection is decided with review in entry 5.
--   * Field errors inside cell_choice use dotted paths (`cell_choice.choice`,
--     `cell_choice.cell_id`, `cell_choice.<unknown key>`), each unknown key reported on itself.
--
-- No destructive statements. No client table privileges.

-- ---------------------------------------------------------------------------------------------
-- Cells: records, the safe sign-up projection and the SYNTHETIC seed
-- ---------------------------------------------------------------------------------------------

create table app.cells_cells (
  cell_id uuid primary key default gen_random_uuid(),
  name text not null check (name = btrim(name) and length(name) between 1 and 80
                            and name !~ '[[:cntrl:]]'),
  broad_area text not null check (broad_area = btrim(broad_area)
                                  and length(broad_area) between 1 and 80
                                  and broad_area !~ '[[:cntrl:]]'),
  cell_state text not null default 'active' check (cell_state in ('active', 'retired')),
  is_synthetic boolean not null default false,
  revision bigint not null default 1 check (revision >= 1),
  created_by text not null check (length(btrim(created_by)) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table app.cells_cells is
  'owner: cells. Cell records. Story 2.4 seeds SYNTHETIC cells only; Admin setup is entry 6.';

create table app.cells_signup_options (
  cell_id uuid primary key references app.cells_cells (cell_id),
  label text not null check (label = btrim(label) and length(label) between 1 and 80
                             and label !~ '[[:cntrl:]]'),
  broad_area text not null check (broad_area = btrim(broad_area)
                                  and length(broad_area) between 1 and 80
                                  and broad_area !~ '[[:cntrl:]]'),
  sort_order integer not null default 0,
  listed boolean not null default true,
  is_synthetic boolean not null,
  revision bigint not null default 1 check (revision >= 1),
  updated_at timestamptz not null default now()
);

comment on table app.cells_signup_options is
  'owner: cells. AD-5 safe sign-up projection: church-approved label and broad area only.';

alter table app.cells_cells enable row level security;
alter table app.cells_signup_options enable row level security;
revoke all on table app.cells_cells, app.cells_signup_options
  from public, anon, authenticated, service_role;

-- Is this option offered to applicants here and now? SYNTHETIC options only in local/staging.
create function app.cells_option_revision(p_cell_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  select o.revision
    from app.cells_signup_options o
    join app.cells_cells c on c.cell_id = o.cell_id
   where o.cell_id = p_cell_id
     and o.listed and c.cell_state = 'active'
     and (not o.is_synthetic or app.platform_current_environment() in ('local', 'staging'));
$$;

-- Restricted operator only (no grants): SYNTHETIC cells and their options for local/staging,
-- idempotent. Returns the number of listed synthetic options.
create function app.cells_seed_synthetic_cells(p_set_by text)
returns integer
language plpgsql
set search_path = ''
as $$
begin
  if app.platform_current_environment() not in ('local', 'staging') then
    raise exception using errcode = '22023',
      message = 'synthetic cells are allowed only in a database marked local or staging';
  end if;
  if length(btrim(coalesce(p_set_by, ''))) = 0 then
    raise exception using errcode = '22023', message = 'set_by is required';
  end if;
  insert into app.cells_cells (cell_id, name, broad_area, is_synthetic, created_by) values
    ('00000000-0000-4000-c000-00000000c241', 'SYNTHETIC Riverside Cell', 'SYNTHETIC North side', true, btrim(p_set_by)),
    ('00000000-0000-4000-c000-00000000c242', 'SYNTHETIC Hilltop Cell', 'SYNTHETIC East side', true, btrim(p_set_by)),
    ('00000000-0000-4000-c000-00000000c243', 'SYNTHETIC Market Cell', 'SYNTHETIC Town centre', true, btrim(p_set_by))
  on conflict (cell_id) do nothing;
  insert into app.cells_signup_options (cell_id, label, broad_area, sort_order, is_synthetic) values
    ('00000000-0000-4000-c000-00000000c241', 'SYNTHETIC Riverside', 'SYNTHETIC North side', 10, true),
    ('00000000-0000-4000-c000-00000000c242', 'SYNTHETIC Hilltop', 'SYNTHETIC East side', 20, true),
    ('00000000-0000-4000-c000-00000000c243', 'SYNTHETIC Market', 'SYNTHETIC Town centre', 30, true)
  on conflict (cell_id) do nothing;
  return (select count(*)::integer from app.cells_signup_options o
           where o.is_synthetic and o.listed);
end;
$$;

comment on function app.cells_seed_synthetic_cells(text) is
  'Restricted operator only (no grants). SYNTHETIC cells + sign-up options for local/staging.';

-- 1.5 source-type check hook: {"current": the option is listed here AND its revision matches,
-- "revision": its current revision when listed}.
create function app.cells_signup_option_check(p_source jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_revision bigint := app.cells_option_revision((p_source ->> 'source_id')::uuid);
begin
  if v_revision is null then
    return '{"current": false}'::jsonb;
  end if;
  return jsonb_build_object(
    'current', v_revision = (p_source ->> 'source_revision')::numeric::bigint,
    'revision', v_revision);
end;
$$;

select app.contract_register_source_type(
  'cells', 'cells_signup_option', 'app.cells_signup_option_check(jsonb)'::regprocedure);

-- The chooser read: label, broad area and revision of each listed option. Allowed for trusted
-- password sessions of applicants (`not_linked`) and members (`granted`, for a later change
-- request); access review shows only the help screen, so it is refused.
create function app.cells_signup_options()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outcome text;
begin
  v_outcome := app.identity_applicant_outcome();
  if v_outcome in ('unauthenticated', 'untrusted_session') then
    raise exception using errcode = 'PT401', message = 'unauthenticated', detail = v_outcome;
  elsif v_outcome = 'unavailable' then
    raise exception using errcode = 'PT403', message = 'unavailable', detail = v_outcome;
  elsif v_outcome not in ('not_linked', 'granted') then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = v_outcome;
  end if;
  -- Personal-data gate (Q4) and held restores: nothing is offered while applications are closed.
  if not app.identity_applications_open() then
    return '{"options": []}'::jsonb;
  end if;
  return jsonb_build_object('options', coalesce((
    select jsonb_agg(jsonb_build_object(
             'cell_id', o.cell_id, 'label', o.label, 'broad_area', o.broad_area,
             'revision', o.revision)
           order by o.sort_order, o.label, o.cell_id)
      from app.cells_signup_options o
     where app.cells_option_revision(o.cell_id) is not null), '[]'::jsonb));
end;
$$;

create function api.cells_signup_options()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.cells_signup_options();
$$;

comment on function api.cells_signup_options() is
  'Story 2.4: the safe cell chooser (label, broad area, revision). POST '
  '/rest/v1/rpc/cells_signup_options with Content-Profile: api.';

-- ---------------------------------------------------------------------------------------------
-- Identity: applications and their content-free history
-- ---------------------------------------------------------------------------------------------

create table app.identity_membership_applications (
  application_id uuid primary key default gen_random_uuid(),
  -- The applicant's Supabase Auth account (no FK into auth, as for account links).
  auth_user_id uuid not null,
  -- The account's phone username when submitted: unverified, never an ownership claim.
  phone_username text not null check (phone_username ~ '^\+[1-9][0-9]{7,14}$'),
  full_name text not null check (full_name = btrim(full_name) and length(full_name) between 1 and 120
                                 and full_name !~ '[[:cntrl:]]'),
  cell_choice text not null check (cell_choice in ('cell', 'not_sure', 'not_in_cell')),
  -- Cells' signup option id and the revision the applicant chose (no FK across owners).
  cell_id uuid,
  cell_option_revision bigint check (cell_option_revision >= 1),
  privacy_notice_version text not null check (privacy_notice_version ~ '^[a-z0-9][a-z0-9_.-]{0,62}$'),
  application_state text not null default 'submitted'
    check (application_state in ('submitted', 'needs_details', 'approved', 'rejected', 'withdrawn')),
  is_synthetic boolean not null,
  revision bigint not null default 1 check (revision >= 1),
  submitted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  decided_at timestamptz,
  check ((cell_choice = 'cell') = (cell_id is not null)),
  check ((cell_id is null) = (cell_option_revision is null)),
  check ((application_state in ('approved', 'rejected', 'withdrawn')) = (decided_at is not null))
);

comment on table app.identity_membership_applications is
  'owner: identity. Correctable membership request of one applicant account. Grants nothing.';

create unique index identity_membership_applications_one_open
  on app.identity_membership_applications (auth_user_id)
  where application_state in ('submitted', 'needs_details');
create index identity_membership_applications_account
  on app.identity_membership_applications (auth_user_id, submitted_at desc);

create table app.identity_application_events (
  event_id bigint generated always as identity primary key,
  application_id uuid not null references app.identity_membership_applications (application_id),
  revision bigint not null check (revision >= 1),
  event text not null check (event in ('submitted', 'corrected', 'details_requested', 'approved',
                                       'rejected', 'withdrawn')),
  actor_auth_user_id uuid not null,
  request_id uuid,
  -- Field NAMES only (full_name, cell_choice); never values.
  changed_fields text[] not null default '{}'
    check (changed_fields <@ array['full_name', 'cell_choice', 'privacy_notice_version']),
  at timestamptz not null default now()
);

comment on table app.identity_application_events is
  'owner: identity. Application history: ids, revisions, events and changed field names only.';

create index identity_application_events_application
  on app.identity_application_events (application_id, event_id);

alter table app.identity_membership_applications enable row level security;
alter table app.identity_application_events enable row level security;
revoke all on table app.identity_membership_applications, app.identity_application_events
  from public, anon, authenticated, service_role;
revoke all on sequence app.identity_application_events_event_id_seq
  from public, anon, authenticated, service_role;

-- APPLICATION_CORRECTION_LIMIT: corrections per application per rolling 24 hours.
create function app.identity_application_correction_limit()
returns integer
language sql
immutable
set search_path = ''
as $$
  select 10;
$$;

-- The predicate outcome for applicant surfaces: as app.identity_access_evaluate(), except that
-- `not_linked` becomes `not_applicant` when the account still has a live link (to a pending,
-- rejected or deactivated member) or any member it was ever linked to has an open hold.
create function app.identity_applicant_outcome()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_outcome text;
  v_sub uuid;
begin
  select e.outcome into v_outcome from app.identity_access_evaluate() e;
  if v_outcome <> 'not_linked' then
    return v_outcome;
  end if;
  -- The predicate verified this subject's session before answering not_linked.
  v_sub := (app.identity_request_claims() ->> 'sub')::uuid;
  if exists (select 1 from app.identity_account_links l
              where l.auth_user_id = v_sub and l.link_state <> 'ended')
     or exists (select 1 from app.identity_account_links l
                  join app.identity_holds h on h.member_id = l.member_id
                 where l.auth_user_id = v_sub and h.released_at is null) then
    return 'not_applicant';
  end if;
  return 'not_linked';
end;
$$;

-- The privacy notice the applicant acknowledges. A labelled DRAFT until the church approves
-- the text under Q4; the client shows the bundled text for this version.
create function app.identity_privacy_notice()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select '{"version": "draft-2026-10-07", "draft": true}'::jsonb;
$$;

-- Personal-data gate for applications and the chooser (Q4): never in a held restore; otherwise
-- the approved gate, or a database marked local/staging.
create function app.identity_applications_open()
returns boolean
language sql
stable
set search_path = ''
as $$
  select not app.rcv_serving_hold()
     and (app.policy_is_open('q4_personal_data')
          or app.platform_current_environment() in ('local', 'staging'));
$$;

create function app.identity_application_json(p_row app.identity_membership_applications)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'application_id', p_row.application_id,
    'revision', p_row.revision,
    'application_state', p_row.application_state,
    'church_status', case p_row.application_state
                       when 'submitted' then 'awaiting_approval'
                       when 'needs_details' then 'details_requested'
                       when 'approved' then 'approved'
                       when 'rejected' then 'not_approved'
                       else 'withdrawn' end,
    'full_name', p_row.full_name,
    'phone_username', p_row.phone_username,
    'cell_choice', jsonb_build_object('choice', p_row.cell_choice, 'cell_id', p_row.cell_id,
                                      'cell_revision', p_row.cell_option_revision),
    -- Cell confirmation is separate from church approval and belongs to entry 6: a chosen cell
    -- is only requested; an unresolved choice waits for an Admin follow-up.
    'cell_status', case when p_row.cell_choice = 'cell' then 'requested' else 'follow_up' end,
    'privacy_notice_version', p_row.privacy_notice_version,
    'is_synthetic', p_row.is_synthetic,
    'submitted_at', app.cmd_utc(p_row.submitted_at),
    'updated_at', app.cmd_utc(p_row.updated_at));
$$;

create function app.identity_application_outcome(p_row app.identity_membership_applications)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'identity_membership_application',
    'aggregate_id', p_row.application_id,
    'revision', p_row.revision,
    'data', app.identity_application_json(p_row));
$$;

-- full_name: every Unicode whitespace run collapses to one space and the ends are trimmed
-- (regex trim, so NBSP, tab and newline edges go too); then 1..120 characters with no Unicode
-- control (Cc) or format (Cf, including bidi overrides such as U+202E) characters. While Q4 is
-- unapproved (local/staging synthetic data) the name must start with `SYNTHETIC `.
create function app.identity_application_name(p_value jsonb, inout errors jsonb, out full_name text)
language plpgsql
set search_path = ''
as $$
declare
  c_space constant text :=
    '[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+';
  c_format constant text :=
    '[\u0001-\u001F\u007F-\u009F\u00AD\u0600-\u0605\u061C\u06DD\u070F\u0890\u0891\u08E2'
    '\u180E\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u206F\uFEFF\uFFF9-\uFFFB'
    '\U000110BD\U000110CD\U00013430-\U0001343F\U0001BCA0-\U0001BCA3\U0001D173-\U0001D17A'
    '\U000E0001\U000E0020-\U000E007F]';
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    errors := errors || '{"full_name": "required"}';
    return;
  end if;
  if jsonb_typeof(p_value) <> 'string' then
    errors := errors || '{"full_name": "invalid"}';
    return;
  end if;
  full_name := regexp_replace(regexp_replace(p_value #>> '{}', c_space, ' ', 'g'),
                              '^ | $', '', 'g');
  if full_name = '' then
    errors := errors || '{"full_name": "required"}';
    full_name := null;
  elsif length(full_name) > 120 or full_name ~ c_format or full_name ~ '[[:cntrl:]]'
        or (not app.policy_is_open('q4_personal_data') and full_name !~ '^SYNTHETIC ') then
    errors := errors || '{"full_name": "invalid"}';
    full_name := null;
  end if;
end;
$$;

-- cell_choice {choice, cell_id?, cell_revision?}. A chosen cell must be a listed sign-up option
-- at that revision, checked through the Cells-registered source hook (1.5 seam).
create function app.identity_application_cell_choice(
  p_value jsonb,
  inout errors jsonb,
  out choice text,
  out cell_id uuid,
  out cell_revision bigint
)
language plpgsql
set search_path = ''
as $$
declare
  v_err text;
  v_check jsonb;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    errors := errors || '{"cell_choice": "required"}';
    return;
  end if;
  if jsonb_typeof(p_value) <> 'object' then
    errors := errors || '{"cell_choice": "must_be_object"}';
    return;
  end if;
  -- Each unknown nested key is reported on itself, with its dotted path.
  errors := errors || coalesce((
    select jsonb_object_agg('cell_choice.' || k, 'unknown_field')
      from jsonb_object_keys(p_value) k
     where k not in ('choice', 'cell_id', 'cell_revision')), '{}'::jsonb);
  if jsonb_typeof(p_value -> 'choice') is distinct from 'string' then
    errors := errors || '{"cell_choice.choice": "required"}';
    return;
  end if;
  choice := p_value ->> 'choice';
  if choice not in ('cell', 'not_sure', 'not_in_cell') then
    errors := errors || '{"cell_choice.choice": "invalid"}';
    choice := null;
    return;
  end if;
  if choice <> 'cell' then
    if coalesce(jsonb_typeof(p_value -> 'cell_id'), 'null') <> 'null' then
      errors := errors || '{"cell_choice.cell_id": "must_be_null"}';
    end if;
    if coalesce(jsonb_typeof(p_value -> 'cell_revision'), 'null') <> 'null' then
      errors := errors || '{"cell_choice.cell_revision": "must_be_null"}';
    end if;
    return;
  end if;
  v_err := app.contract_uuid_error(p_value -> 'cell_id');
  if v_err is not null then
    errors := errors || jsonb_build_object('cell_choice.cell_id', v_err);
  end if;
  if app.contract_revision_error(p_value -> 'cell_revision') is not null then
    errors := errors || jsonb_build_object('cell_choice.cell_revision',
                                           app.contract_revision_error(p_value -> 'cell_revision'));
  end if;
  if errors <> '{}'::jsonb then
    return;
  end if;
  cell_id := (p_value ->> 'cell_id')::uuid;
  cell_revision := (p_value ->> 'cell_revision')::numeric::bigint;
  v_check := app.contract_check_source(jsonb_build_object(
    'source_type', 'cells_signup_option', 'source_id', cell_id, 'source_revision', cell_revision));
  if not (v_check ->> 'current')::boolean then
    errors := errors || '{"cell_choice.cell_id": "invalid"}';
  end if;
end;
$$;

-- The applicant's phone username from Auth now; in local/staging it must be fictional.
create function app.identity_applicant_phone(p_actor uuid)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_phone text;
begin
  select '+' || ltrim(nullif(btrim(u.phone), ''), '+') into v_phone
    from auth.users u where u.id = p_actor;
  if v_phone is null or v_phone !~ '^\+[1-9][0-9]{7,14}$' then
    perform app.cmd_fail('validation_failed', '{"phone_username": "required"}');
  end if;
  if not app.policy_is_open('q4_personal_data')
     and v_phone !~ '^\+120255501[0-9]{2}$' and v_phone !~ '^\+447700900[0-9]{3}$' then
    perform app.cmd_fail('validation_failed', '{"phone_username": "out_of_range"}');
  end if;
  return v_phone;
end;
$$;

-- identity.submit_application (create; expected_revision null).
create function app.identity_submit_application(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_name record;
  v_cell record;
  v_phone text;
  v_open app.identity_membership_applications;
  v_row app.identity_membership_applications;
begin
  if not app.identity_applications_open() then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(
    p_payload, array['full_name', 'cell_choice', 'privacy_notice_version']);
  select n.* into v_name from app.identity_application_name(p_payload -> 'full_name', '{}') n;
  v_errors := v_errors || v_name.errors;
  select c.* into v_cell from app.identity_application_cell_choice(p_payload -> 'cell_choice', '{}') c;
  v_errors := v_errors || v_cell.errors;
  if jsonb_typeof(p_payload -> 'privacy_notice_version') is distinct from 'string' then
    v_errors := v_errors || '{"privacy_notice_version": "required"}';
  elsif p_payload ->> 'privacy_notice_version' <> app.identity_privacy_notice() ->> 'version' then
    v_errors := v_errors || '{"privacy_notice_version": "invalid"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_phone := app.identity_applicant_phone(p_actor);

  select a.* into v_open from app.identity_membership_applications a
   where a.auth_user_id = p_actor and a.application_state in ('submitted', 'needs_details')
     for update;
  if found then
    perform app.cmd_fail('conflict', null, v_open.revision);
  end if;

  begin
    insert into app.identity_membership_applications (
      auth_user_id, phone_username, full_name, cell_choice, cell_id, cell_option_revision,
      privacy_notice_version, is_synthetic)
    values (p_actor, v_phone, v_name.full_name, v_cell.choice, v_cell.cell_id, v_cell.cell_revision,
            p_payload ->> 'privacy_notice_version',
            app.platform_current_environment() in ('local', 'staging'))
    returning * into v_row;
  exception when unique_violation then
    -- A concurrent submit from the same account committed first.
    perform app.cmd_fail('conflict');
  end;
  insert into app.identity_application_events (application_id, revision, event,
                                               actor_auth_user_id, request_id, changed_fields)
  values (v_row.application_id, 1, 'submitted', p_actor,
          app.cmd_current_request_id(p_actor, 'identity.submit_application'),
          array['full_name', 'cell_choice', 'privacy_notice_version']);
  return app.identity_application_outcome(v_row);
end;
$$;

-- identity.correct_application (expected_revision = the application's revision). Omitted fields
-- stay as they are; the applicant can never set the application or cell status.
create function app.identity_correct_application(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_err text;
  v_name record;
  v_cell record;
  v_row app.identity_membership_applications;
  v_changed text[] := '{}';
begin
  if not app.identity_applications_open() then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, array['application_id', 'full_name', 'cell_choice']);
  v_err := app.contract_uuid_error(p_payload -> 'application_id');
  if v_err is not null then
    v_errors := v_errors || jsonb_build_object('application_id', v_err);
  end if;
  if not (p_payload ? 'full_name' or p_payload ? 'cell_choice') then
    v_errors := v_errors || '{"payload": "required"}';
  end if;
  if p_payload ? 'full_name' then
    select n.* into v_name from app.identity_application_name(p_payload -> 'full_name', '{}') n;
    v_errors := v_errors || v_name.errors;
  end if;
  if p_payload ? 'cell_choice' then
    select c.* into v_cell from app.identity_application_cell_choice(p_payload -> 'cell_choice', '{}') c;
    v_errors := v_errors || v_cell.errors;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;

  -- Only the caller's own application exists for them; anything else is not found.
  select a.* into v_row from app.identity_membership_applications a
   where a.application_id = (p_payload ->> 'application_id')::uuid and a.auth_user_id = p_actor
     for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_row.revision <> p_expected_revision
     or v_row.application_state not in ('submitted', 'needs_details') then
    perform app.cmd_fail('conflict', null, v_row.revision);
  end if;

  if p_payload ? 'full_name' and v_name.full_name <> v_row.full_name then
    v_changed := v_changed || 'full_name'::text;
    v_row.full_name := v_name.full_name;
  end if;
  if p_payload ? 'cell_choice'
     and (v_cell.choice <> v_row.cell_choice or v_cell.cell_id is distinct from v_row.cell_id
          or v_cell.cell_revision is distinct from v_row.cell_option_revision) then
    v_changed := v_changed || 'cell_choice'::text;
    v_row.cell_choice := v_cell.choice;
    v_row.cell_id := v_cell.cell_id;
    v_row.cell_option_revision := v_cell.cell_revision;
  end if;
  if v_changed = '{}'::text[] then
    -- Nothing to correct: the current state is the answer (no new revision).
    return app.identity_application_outcome(v_row);
  end if;
  if (select count(*) from app.identity_application_events e
       where e.application_id = v_row.application_id and e.event = 'corrected'
         and e.at > now() - interval '24 hours')
     >= app.identity_application_correction_limit() then
    perform app.cmd_fail('rate_limited');
  end if;

  update app.identity_membership_applications a
     set full_name = v_row.full_name,
         cell_choice = v_row.cell_choice,
         cell_id = v_row.cell_id,
         cell_option_revision = v_row.cell_option_revision,
         -- A correction answers a request for details: back to the review queue.
         application_state = 'submitted',
         revision = a.revision + 1,
         updated_at = now()
   where a.application_id = v_row.application_id
  returning * into v_row;
  insert into app.identity_application_events (application_id, revision, event,
                                               actor_auth_user_id, request_id, changed_fields)
  values (v_row.application_id, v_row.revision, 'corrected', p_actor,
          app.cmd_current_request_id(p_actor, 'identity.correct_application'), v_changed);
  return app.identity_application_outcome(v_row);
end;
$$;

-- Replay seam: the receipt must name the caller's own application.
create function app.identity_application_in_scope(
  p_actor uuid,
  p_aggregate_type text,
  p_aggregate_id uuid
) returns boolean
language sql
stable
set search_path = ''
as $$
  select p_aggregate_type = 'identity_membership_application' and p_aggregate_id is not null
     and exists (select 1 from app.identity_membership_applications a
                  where a.application_id = p_aggregate_id and a.auth_user_id = p_actor);
$$;

-- Applicant authorization: a trusted password session (the live-access predicate's own session
-- checks) of an account with no live link and no open hold (app.identity_applicant_outcome).
-- Members, held, linked-but-unapproved accounts and accounts in review are refused; untrusted
-- sessions are `unauthenticated`.
create function app.identity_authorize_application_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_outcome text;
begin
  v_outcome := app.identity_applicant_outcome();
  if v_outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  return v_outcome = 'not_linked';
end;
$$;

-- The registered `identity` authorizer (2.3), now dispatching: application commands go to the
-- applicant check above; the grant branch below is the 2.3 body unchanged.
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
  if coalesce(p_request ->> 'command', '') not in ('identity.grant_role', 'identity.revoke_role',
                                     'identity.grant_scope', 'identity.revoke_scope') then
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

create function app.identity_application_command(p_envelope jsonb)
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
      when 'identity.submit_application'
        then 'app.identity_submit_application(uuid, bigint, jsonb)'::regprocedure
      when 'identity.correct_application'
        then 'app.identity_correct_application(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.identity_application_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'identity.submit_application'
  );
end;
$$;

-- POST /rest/v1/rpc/identity_application_command, Content-Profile: api,
-- body {version, command, request_id, expected_revision, payload}.
create function api.identity_application_command(jsonb)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.identity_application_command($1);
$$;

comment on function api.identity_application_command(jsonb) is
  'Story 2.4: an applicant submits or corrects their own membership application '
  '(identity.submit_application, identity.correct_application) through the 1.4 envelope.';

-- The caller's own application (the open one, else the latest) and the privacy notice. Allowed
-- for trusted password sessions of applicants and members; refused for access review.
create function app.identity_my_application()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outcome text;
  v_sub uuid;
  v_row app.identity_membership_applications;
begin
  v_outcome := app.identity_applicant_outcome();
  if v_outcome in ('unauthenticated', 'untrusted_session') then
    raise exception using errcode = 'PT401', message = 'unauthenticated', detail = v_outcome;
  elsif v_outcome = 'unavailable' then
    raise exception using errcode = 'PT403', message = 'unavailable', detail = v_outcome;
  elsif v_outcome not in ('not_linked', 'granted') then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = v_outcome;
  end if;
  -- The predicate verified this subject's session above.
  v_sub := (app.identity_request_claims() ->> 'sub')::uuid;
  select a.* into v_row from app.identity_membership_applications a
   where a.auth_user_id = v_sub
   order by (a.application_state in ('submitted', 'needs_details')) desc, a.submitted_at desc
   limit 1;
  return jsonb_build_object(
    'application', case when v_row.application_id is null then null
                        else app.identity_application_json(v_row) end,
    'privacy_notice', app.identity_privacy_notice(),
    'accepting_applications', app.identity_applications_open());
end;
$$;

create function api.identity_my_application()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.identity_my_application();
$$;

comment on function api.identity_my_application() is
  'Story 2.4: the caller''s own membership application and the privacy notice. POST '
  '/rest/v1/rpc/identity_my_application with Content-Profile: api.';

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.cells_option_revision(uuid),
  app.cells_seed_synthetic_cells(text),
  app.cells_signup_option_check(jsonb),
  app.cells_signup_options(),
  api.cells_signup_options(),
  app.identity_application_correction_limit(),
  app.identity_applicant_outcome(),
  app.identity_privacy_notice(),
  app.identity_applications_open(),
  app.identity_application_json(app.identity_membership_applications),
  app.identity_application_outcome(app.identity_membership_applications),
  app.identity_application_name(jsonb, jsonb),
  app.identity_application_cell_choice(jsonb, jsonb),
  app.identity_applicant_phone(uuid),
  app.identity_submit_application(uuid, bigint, jsonb),
  app.identity_correct_application(uuid, bigint, jsonb),
  app.identity_application_in_scope(uuid, text, uuid),
  app.identity_authorize_application_command(jsonb),
  app.identity_authorize_command(jsonb),
  app.identity_application_command(jsonb),
  api.identity_application_command(jsonb),
  app.identity_my_application(),
  api.identity_my_application()
  from public, anon, authenticated, service_role;

grant execute on function app.cells_signup_options() to authenticated;
grant execute on function api.cells_signup_options() to authenticated;
grant execute on function app.identity_application_command(jsonb) to authenticated;
grant execute on function api.identity_application_command(jsonb) to authenticated;
grant execute on function app.identity_my_application() to authenticated;
grant execute on function api.identity_my_application() to authenticated;

notify pgrst, 'reload schema';
