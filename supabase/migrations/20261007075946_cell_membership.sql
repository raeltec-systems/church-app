-- Confirm and transfer primary cell membership (story 2.6; AD-1, AD-2, AD-3, AD-4, AD-5, AD-14).
--
-- Cells owns cell setup, requests and confirmed primary membership. It builds on the live-access
-- predicate and grant helpers (2.1-2.3), the 2.4 cell records and safe sign-up projection, and
-- the 2.5 approved applications; nothing here forks them.
--
--   * Admin cell setup (cells.create_cell, cells.update_cell): name, safe sign-up label, broad
--     area, listed. Behind the personal-data gate (app.identity_applications_open()); while Q4
--     is unapproved every text starts `SYNTHETIC ` and the cell is synthetic.
--   * Leader and assistant are Identity scope grants of the Cells-registered kinds `cell_leader`
--     and `cell_assistant` (scope_id = cell_id), given and removed with the audited 2.3 commands
--     identity.grant_scope / identity.revoke_scope. Leaders confirm requests for their cell;
--     assistants have the cell's private access but do not confirm.
--   * Requests (app.cells_membership_requests): `join` or `change`, from an approved application
--     (created here, idempotently, the first time a Cells read or command runs after approval;
--     Identity never calls Cells), from the member (cells.request_change) or from an Admin on a
--     member's behalf. One open request per member. A request grants nothing.
--   * Confirmation is separate from church approval: the leader of the requested cell, or a live
--     Admin (who may choose the cell, which resolves the follow-up queue), confirms with
--     cells.confirm_request. A leader's cells.decline_request refers the request to the Admin
--     follow-up queue; an Admin's decline is final. The member or an Admin may cancel.
--   * At most one current primary membership per member (partial unique index). Confirming a
--     request of a member who already has a primary cell is an atomic transfer: the old
--     membership ends (and with it every cell-private access derived from it), the new one
--     starts, and the contract v1 lifecycle event `cell_transferred` is dispatched to the
--     registered owner hooks in the same transaction (a failing hook rolls everything back).
--     Church membership, account links and grants are not touched.
--   * app.cells_member_has_private_access(member, cell): the cell-private access rule for later
--     owners (current primary membership, or a leader/assistant scope). api.cells_private_fixture_read
--     is its SYNTHETIC fixture surface.
--   * Reads: api.cells_my_cell (the member's own cell and open request), api.cells_leader_queue
--     (leaders/assistants: their cells' rosters; leaders: open requests for their cells),
--     api.cells_admin_overview (Admin: cells, leaders, all open requests with the follow-up flag,
--     approved members with their cell).
--   * Content-free audit app.cells_membership_audit: ids, codes and revisions only.
--   * Commands use the 1.4 envelope through api.cells_command and the `cells` authorizer in the
--     2.3 registry (namespace = module, so Identity's authorizer cannot own `cells.*`).
--   * SYNTHETIC fixture hook app.fixture_record_lifecycle(jsonb): defined here, registered only by
--     tests and the local E2E, so no synthetic hook runs on a hosted project.
--
-- Lock order (AD-2): the actor's Identity grant rows FOR SHARE (authorizer) -> command receipt
-- -> the member's Cells state FOR UPDATE -> request / membership / cell rows.
--
-- No destructive statements. No client table privileges.

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

-- One revisioned Cells aggregate per member (expected_revision of the member's cell commands).
-- No foreign key across owners: member ids are checked against Identity in the commands.
create table app.cells_member_states (
  member_id uuid primary key,
  revision bigint not null default 1 check (revision >= 1),
  updated_at timestamptz not null default now()
);

comment on table app.cells_member_states is
  'owner: cells. One revisioned primary-cell aggregate per member.';

create table app.cells_membership_requests (
  request_id uuid primary key default gen_random_uuid(),
  member_id uuid not null references app.cells_member_states (member_id),
  kind text not null check (kind in ('join', 'change')),
  origin text not null check (origin in ('application', 'member', 'admin')),
  -- The approved Identity application this request came from (no FK across owners).
  application_id uuid unique,
  choice text not null check (choice in ('cell', 'not_sure', 'not_in_cell')),
  requested_cell_id uuid references app.cells_cells (cell_id),
  request_state text not null default 'pending'
    check (request_state in ('pending', 'referred', 'confirmed', 'declined', 'cancelled')),
  requested_by_member uuid,
  requested_by_account uuid,
  decided_by_member uuid,
  decided_by_account uuid,
  decided_as text check (decided_as in ('admin', 'cell_leader', 'member')),
  decision_reason text check (decision_reason in ('not_in_this_cell', 'not_known_to_leader',
                                                  'member_withdrew', 'no_cell_for_now',
                                                  'cancelled_by_admin')),
  resulting_membership_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  decided_at timestamptz,
  check ((choice = 'cell') = (requested_cell_id is not null)),
  check ((origin = 'application') = (application_id is not null)),
  check ((request_state in ('confirmed', 'declined', 'cancelled')) = (decided_at is not null)),
  check ((request_state = 'confirmed') = (resulting_membership_id is not null))
);

comment on table app.cells_membership_requests is
  'owner: cells. Join/change requests for a primary cell. A request grants nothing.';

create unique index cells_membership_requests_one_open
  on app.cells_membership_requests (member_id) where request_state in ('pending', 'referred');
create index cells_membership_requests_open_cell
  on app.cells_membership_requests (requested_cell_id) where request_state = 'pending';

create table app.cells_memberships (
  membership_id uuid primary key default gen_random_uuid(),
  member_id uuid not null references app.cells_member_states (member_id),
  cell_id uuid not null references app.cells_cells (cell_id),
  -- v1 has primary memberships only; other ministries are departments or groups.
  is_primary boolean not null default true check (is_primary),
  request_id uuid not null references app.cells_membership_requests (request_id),
  confirmed_by_member uuid not null,
  confirmed_by_account uuid not null,
  confirmed_as text not null check (confirmed_as in ('admin', 'cell_leader')),
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  end_reason text check (end_reason in ('transferred')),
  ended_by_request uuid references app.cells_membership_requests (request_id),
  check ((ended_at is null) = (end_reason is null)),
  check ((ended_at is null) = (ended_by_request is null))
);

comment on table app.cells_memberships is
  'owner: cells. Confirmed primary cell memberships with effective dates (zero or one current).';

create unique index cells_memberships_one_current_primary
  on app.cells_memberships (member_id) where ended_at is null and is_primary;
create index cells_memberships_current_by_cell
  on app.cells_memberships (cell_id) where ended_at is null;

alter table app.cells_membership_requests
  add constraint cells_membership_requests_resulting_fk
  foreign key (resulting_membership_id) references app.cells_memberships (membership_id);

-- Content-free: ids, codes and revisions only. Never names, phones or free text.
create table app.cells_membership_audit (
  event_id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  environment text not null default app.platform_current_environment(),
  action text not null check (action in ('cell_created', 'cell_updated', 'request_opened',
                                         'request_confirmed', 'request_referred',
                                         'request_declined', 'request_cancelled',
                                         'membership_started', 'membership_transferred')),
  actor_kind text not null check (actor_kind in ('member', 'system')),
  actor_member_id uuid,
  actor_account_id uuid,
  actor_capacity text check (actor_capacity in ('admin', 'cell_leader', 'member')),
  command_request_id uuid,
  cell_id uuid,
  from_cell_id uuid,
  member_id uuid,
  membership_request_id uuid,
  membership_id uuid,
  reason_code text,
  revision_after bigint,
  check (actor_kind <> 'member' or (actor_member_id is not null and actor_account_id is not null
                                    and actor_capacity is not null
                                    and command_request_id is not null)),
  check (actor_kind <> 'system' or (actor_member_id is null and actor_account_id is null))
);

comment on table app.cells_membership_audit is
  'owner: cells. Attributed cell setup and membership decisions: ids, codes and revisions only.';

create index cells_membership_audit_member on app.cells_membership_audit (member_id, event_id);

-- SYNTHETIC: every lifecycle call a registered fixture hook received, with its transaction id
-- (to prove that hooks run inside the emitting transaction).
create table app.fixture_lifecycle_calls (
  call_id bigint generated always as identity primary key,
  event text not null,
  member_id uuid not null,
  identity_revision bigint not null,
  xact_id xid8 not null default pg_current_xact_id(),
  called_at timestamptz not null default now()
);

comment on table app.fixture_lifecycle_calls is
  'owner: fixture. SYNTHETIC record of lifecycle hook calls (registered only by tests/E2E).';

alter table app.cells_member_states enable row level security;
alter table app.cells_membership_requests enable row level security;
alter table app.cells_memberships enable row level security;
alter table app.cells_membership_audit enable row level security;
alter table app.fixture_lifecycle_calls enable row level security;
revoke all on table app.cells_member_states, app.cells_membership_requests, app.cells_memberships,
                    app.cells_membership_audit, app.fixture_lifecycle_calls
  from public, anon, authenticated, service_role;
revoke all on sequence app.cells_membership_audit_event_id_seq, app.fixture_lifecycle_calls_call_id_seq
  from public, anon, authenticated, service_role;

-- Cells emits cell_transferred (contract v1 stub list, 1.5). In this event `identity_revision`
-- carries the member's Cells revision (app.cells_member_states) after the move, not an Identity
-- revision. The v1 payload has no cell ids: a v2 payload with from_cell_id / to_cell_id is needed
-- before any real owner (duties, chat, follow-ups, programmes) registers a hook for it.
update app.contract_lifecycle_events
   set emitter_module = 'cells',
       description = 'Confirmed primary cell membership moved to another cell. identity_revision '
                     'carries the member''s Cells revision; v2 (from_cell_id, to_cell_id) is '
                     'needed before a real owner hooks it'
 where event = 'cell_transferred';

-- ---------------------------------------------------------------------------------------------
-- Scope kinds: cell leader and assistant (Identity grant model, 2.3)
-- ---------------------------------------------------------------------------------------------

create function app.cells_scope_target_ok(p_scope jsonb)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from app.cells_cells c
                  where c.cell_id::text = p_scope ->> 'scope_id' and c.cell_state = 'active');
$$;

select app.identity_register_scope_kind('cells', 'cell_leader',
  'app.cells_scope_target_ok(jsonb)'::regprocedure,
  'Leads one cell: confirms its membership requests and has its private access');
select app.identity_register_scope_kind('cells', 'cell_assistant',
  'app.cells_scope_target_ok(jsonb)'::regprocedure,
  'Assists one cell: has its private access; does not confirm membership');

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------

-- The cell-private access rule for later owners: a current primary membership in the cell, or
-- an active leader/assistant scope for it. Takes effect only through the live-access predicate
-- (callers pass the member the predicate returned). An Admin role alone gives none.
create function app.cells_member_has_private_access(p_member_id uuid, p_cell_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_member_id is not null and p_cell_id is not null
     and (exists (select 1 from app.cells_memberships m
                   where m.member_id = p_member_id and m.cell_id = p_cell_id and m.ended_at is null)
          or app.identity_member_has_scope(p_member_id, 'cell_leader', p_cell_id)
          or app.identity_member_has_scope(p_member_id, 'cell_assistant', p_cell_id));
$$;

-- Requests for members approved through an application: one per application, created once,
-- only for a member that has no Cells history at all (a relinked member keeps its own).
create function app.cells_sync_application_requests()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_count integer;
begin
  with fresh as (
    select a.application_id, a.member_id, a.auth_user_id, a.cell_choice, a.cell_id
      from app.identity_membership_applications a
      join app.identity_members m on m.member_id = a.member_id
     where a.application_state = 'approved' and m.membership_state = 'approved'
       and not exists (select 1 from app.cells_membership_requests r where r.member_id = a.member_id)
       and not exists (select 1 from app.cells_memberships cm where cm.member_id = a.member_id)
       and (a.cell_id is null or exists (select 1 from app.cells_cells c where c.cell_id = a.cell_id))
  ), states as (
    insert into app.cells_member_states (member_id)
    select distinct f.member_id from fresh f
    on conflict (member_id) do nothing
  ), opened as (
    insert into app.cells_membership_requests (member_id, kind, origin, application_id, choice,
                                               requested_cell_id, requested_by_account)
    select distinct on (f.member_id) f.member_id, 'join', 'application', f.application_id,
           f.cell_choice, f.cell_id, f.auth_user_id
      from fresh f
     order by f.member_id, f.application_id
    on conflict do nothing
    returning request_id, member_id, requested_cell_id
  )
  insert into app.cells_membership_audit (action, actor_kind, member_id, membership_request_id,
                                          cell_id, revision_after)
  select 'request_opened', 'system', o.member_id, o.request_id, o.requested_cell_id, 1
    from opened o;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- The acting member of a cells command (authorised in this transaction) and whether Admin.
create function app.cells_command_actor(
  p_actor uuid,
  out member_id uuid,
  out account_id uuid,
  out is_admin boolean
)
language plpgsql
set search_path = ''
as $$
begin
  select e.member_id into member_id from app.identity_evaluate_grant(null, null, null) e
   where e.outcome = 'granted';
  if member_id is null then
    perform app.cmd_fail('forbidden');
  end if;
  account_id := p_actor;
  is_admin := app.identity_member_has_role(member_id, 'admin');
end;
$$;

-- Personal-data gate (Q4) for every Cells membership command and read.
create function app.cells_require_open()
returns void
language plpgsql
set search_path = ''
as $$
begin
  if not app.identity_applications_open() then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
end;
$$;

-- Locks the member's Cells state (created at revision 1 for an approved member) and checks the
-- expected revision.
create function app.cells_lock_member(p_member_id uuid, p_expected bigint)
returns app.cells_member_states
language plpgsql
set search_path = ''
as $$
declare
  v_state app.cells_member_states;
begin
  if not exists (select 1 from app.identity_members m
                  where m.member_id = p_member_id and m.membership_state = 'approved') then
    perform app.cmd_fail('not_found');
  end if;
  insert into app.cells_member_states (member_id) values (p_member_id)
  on conflict (member_id) do nothing;
  select s.* into v_state from app.cells_member_states s where s.member_id = p_member_id for update;
  if p_expected is distinct from v_state.revision then
    perform app.cmd_fail('conflict', null, v_state.revision);
  end if;
  return v_state;
end;
$$;

create function app.cells_bump_member(p_member_id uuid)
returns bigint
language sql
set search_path = ''
as $$
  update app.cells_member_states s
     set revision = s.revision + 1, updated_at = now()
   where s.member_id = p_member_id
  returning s.revision;
$$;

create function app.cells_label(p_cell_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(o.label, c.name)
    from app.cells_cells c
    left join app.cells_signup_options o on o.cell_id = c.cell_id
   where c.cell_id = p_cell_id;
$$;

-- The member's own view: current primary cell (safe label and area) and open request.
create function app.cells_member_json(p_member_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'member_id', p_member_id,
    'revision', coalesce((select s.revision from app.cells_member_states s
                           where s.member_id = p_member_id), 1),
    'primary', (select jsonb_build_object(
                         'membership_id', m.membership_id, 'cell_id', m.cell_id,
                         'label', app.cells_label(m.cell_id),
                         'broad_area', coalesce(o.broad_area, c.broad_area),
                         'since', app.cmd_utc(m.started_at))
                  from app.cells_memberships m
                  join app.cells_cells c on c.cell_id = m.cell_id
                  left join app.cells_signup_options o on o.cell_id = m.cell_id
                 where m.member_id = p_member_id and m.ended_at is null),
    'open_request', (select jsonb_build_object(
                              'request_id', r.request_id, 'kind', r.kind, 'origin', r.origin,
                              'choice', r.choice, 'state', r.request_state,
                              'cell_id', r.requested_cell_id,
                              'label', app.cells_label(r.requested_cell_id),
                              'created_at', app.cmd_utc(r.created_at))
                       from app.cells_membership_requests r
                      where r.member_id = p_member_id
                        and r.request_state in ('pending', 'referred')),
    'last_decision', (select jsonb_build_object(
                               'request_id', r.request_id, 'state', r.request_state,
                               'reason', r.decision_reason,
                               'decided_at', app.cmd_utc(r.decided_at))
                        from app.cells_membership_requests r
                       where r.member_id = p_member_id and r.decided_at is not null
                       order by r.decided_at desc, r.request_id
                       limit 1));
$$;

create function app.cells_member_outcome(p_member_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'cells_member_cell',
    'aggregate_id', p_member_id,
    'revision', (select s.revision from app.cells_member_states s where s.member_id = p_member_id),
    'data', app.cells_member_json(p_member_id));
$$;

-- Staff view of one cell (Admin): setup, sign-up projection, leaders and assistants.
create function app.cells_cell_json(p_cell_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'cell_id', c.cell_id,
    'name', c.name,
    'broad_area', c.broad_area,
    'signup_label', o.label,
    'listed', coalesce(o.listed, false),
    -- The sign-up option revision while it is offered (cell_revision of cells.request_change).
    'signup_revision', app.cells_option_revision(c.cell_id),
    'cell_state', c.cell_state,
    'is_synthetic', c.is_synthetic,
    'revision', c.revision,
    'leaders', coalesce((
      select jsonb_agg(jsonb_build_object('member_id', g.member_id, 'display_name', m.display_name,
                                          'grants_revision', gs.revision)
                       order by m.display_name, g.member_id)
        from app.identity_grants g
        join app.identity_members m on m.member_id = g.member_id
        join app.identity_grant_sets gs on gs.member_id = g.member_id
       where g.scope_kind = 'cell_leader' and g.scope_id = c.cell_id and g.revoked_at is null),
      '[]'::jsonb),
    'assistants', coalesce((
      select jsonb_agg(jsonb_build_object('member_id', g.member_id, 'display_name', m.display_name,
                                          'grants_revision', gs.revision)
                       order by m.display_name, g.member_id)
        from app.identity_grants g
        join app.identity_members m on m.member_id = g.member_id
        join app.identity_grant_sets gs on gs.member_id = g.member_id
       where g.scope_kind = 'cell_assistant' and g.scope_id = c.cell_id and g.revoked_at is null),
      '[]'::jsonb),
    'member_count', (select count(*)::int from app.cells_memberships cm
                      where cm.cell_id = c.cell_id and cm.ended_at is null))
    from app.cells_cells c
    left join app.cells_signup_options o on o.cell_id = c.cell_id
   where c.cell_id = p_cell_id;
$$;

create function app.cells_cell_outcome(p_cell_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'cells_cell',
    'aggregate_id', p_cell_id,
    'revision', (select c.revision from app.cells_cells c where c.cell_id = p_cell_id),
    'data', app.cells_cell_json(p_cell_id));
$$;

-- A staff text field (name, label, area): collapsed whitespace, 1..80 characters, no control or
-- format characters; `SYNTHETIC ` first while Q4 is unapproved.
create function app.cells_text(p_payload jsonb, p_key text, p_required boolean, inout errors jsonb,
                               out value text)
language plpgsql
set search_path = ''
as $$
declare
  v jsonb := p_payload -> p_key;
begin
  if v is null or jsonb_typeof(v) = 'null' then
    if p_required then
      errors := errors || jsonb_build_object(p_key, 'required');
    end if;
    return;
  end if;
  if jsonb_typeof(v) <> 'string' then
    errors := errors || jsonb_build_object(p_key, 'invalid');
    return;
  end if;
  value := btrim(regexp_replace(v #>> '{}', '\s+', ' ', 'g'));
  if value = '' then
    errors := errors || jsonb_build_object(p_key, 'required');
    value := null;
  elsif length(value) > 80 or value ~ '[[:cntrl:]]'
        or value ~ '[\u00ad\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u206f\ufeff]'
        or (not app.policy_is_open('q4_personal_data') and value !~ '^SYNTHETIC ') then
    errors := errors || jsonb_build_object(p_key, 'invalid');
    value := null;
  end if;
end;
$$;

create function app.cells_audit(
  p_action text,
  p_actor_member uuid,
  p_actor_account uuid,
  p_capacity text,
  p_command text,
  p_member_id uuid,
  p_cell_id uuid,
  p_from_cell uuid,
  p_request uuid,
  p_membership uuid,
  p_reason text,
  p_revision bigint
) returns void
language sql
set search_path = ''
as $$
  insert into app.cells_membership_audit (action, actor_kind, actor_member_id, actor_account_id,
                                          actor_capacity, command_request_id, cell_id,
                                          from_cell_id, member_id, membership_request_id,
                                          membership_id, reason_code, revision_after)
  values (p_action, 'member', p_actor_member, p_actor_account, p_capacity,
          app.cmd_current_request_id(p_actor_account, p_command), p_cell_id, p_from_cell,
          p_member_id, p_request, p_membership, p_reason, p_revision);
$$;

-- ---------------------------------------------------------------------------------------------
-- Commands: Admin cell setup
-- ---------------------------------------------------------------------------------------------

-- cells.create_cell {name, signup_label, broad_area, listed?, sort_order?}; expected null.
create function app.cells_create_cell(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_name text;
  v_label text;
  v_area text;
  v_cell uuid;
  v_synthetic boolean := not app.policy_is_open('q4_personal_data');
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  if not v_actor.is_admin then
    perform app.cmd_fail('forbidden');
  end if;
  v_errors := app.contract_unknown_keys(p_payload,
                array['name', 'signup_label', 'broad_area', 'listed', 'sort_order']);
  select t.errors, t.value into v_errors, v_name from app.cells_text(p_payload, 'name', true, v_errors) t;
  select t.errors, t.value into v_errors, v_label
    from app.cells_text(p_payload, 'signup_label', true, v_errors) t;
  select t.errors, t.value into v_errors, v_area
    from app.cells_text(p_payload, 'broad_area', true, v_errors) t;
  if coalesce(jsonb_typeof(p_payload -> 'listed'), 'boolean') <> 'boolean' then
    v_errors := v_errors || '{"listed": "invalid"}';
  end if;
  if p_payload ? 'sort_order' and not app.contract_integer_in(p_payload -> 'sort_order', 0, 10000) then
    v_errors := v_errors || '{"sort_order": "out_of_range"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  insert into app.cells_cells (name, broad_area, is_synthetic, created_by)
  values (v_name, v_area, v_synthetic, 'admin:' || v_actor.member_id::text)
  returning cell_id into v_cell;
  insert into app.cells_signup_options (cell_id, label, broad_area, sort_order, listed, is_synthetic)
  values (v_cell, v_label, v_area, coalesce((p_payload ->> 'sort_order')::numeric::int, 0),
          coalesce((p_payload ->> 'listed')::boolean, true), v_synthetic);
  perform app.cells_audit('cell_created', v_actor.member_id, v_actor.account_id, 'admin', 'cells.create_cell', null, v_cell,
                          null, null, null, null, 1);
  return app.cells_cell_outcome(v_cell);
end;
$$;

-- cells.update_cell {cell_id, name?, signup_label?, broad_area?, listed?}; expected = cell revision.
create function app.cells_update_cell(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_cell app.cells_cells;
  v_name text;
  v_label text;
  v_area text;
  v_revision bigint;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  if not v_actor.is_admin then
    perform app.cmd_fail('forbidden');
  end if;
  v_errors := app.contract_unknown_keys(p_payload,
                array['cell_id', 'name', 'signup_label', 'broad_area', 'listed']);
  if app.contract_uuid_error(p_payload -> 'cell_id') is not null then
    v_errors := v_errors || jsonb_build_object('cell_id', app.contract_uuid_error(p_payload -> 'cell_id'));
  end if;
  select t.errors, t.value into v_errors, v_name from app.cells_text(p_payload, 'name', false, v_errors) t;
  select t.errors, t.value into v_errors, v_label
    from app.cells_text(p_payload, 'signup_label', false, v_errors) t;
  select t.errors, t.value into v_errors, v_area
    from app.cells_text(p_payload, 'broad_area', false, v_errors) t;
  if coalesce(jsonb_typeof(p_payload -> 'listed'), 'boolean') <> 'boolean' then
    v_errors := v_errors || '{"listed": "invalid"}';
  end if;
  if v_errors = '{}'::jsonb and v_name is null and v_label is null and v_area is null
     and not (p_payload ? 'listed') then
    v_errors := '{"payload": "required"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  select c.* into v_cell from app.cells_cells c
   where c.cell_id = (p_payload ->> 'cell_id')::uuid for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_cell.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_cell.revision);
  end if;
  update app.cells_cells c
     set name = coalesce(v_name, c.name), broad_area = coalesce(v_area, c.broad_area),
         revision = c.revision + 1, updated_at = now()
   where c.cell_id = v_cell.cell_id
  returning c.revision into v_revision;
  if v_label is not null or v_area is not null or p_payload ? 'listed' then
    insert into app.cells_signup_options (cell_id, label, broad_area, listed, is_synthetic)
    values (v_cell.cell_id, coalesce(v_label, v_cell.name), coalesce(v_area, v_cell.broad_area),
            coalesce((p_payload ->> 'listed')::boolean, true), v_cell.is_synthetic)
    on conflict (cell_id) do update
      set label = coalesce(v_label, app.cells_signup_options.label),
          broad_area = coalesce(v_area, app.cells_signup_options.broad_area),
          listed = coalesce((p_payload ->> 'listed')::boolean, app.cells_signup_options.listed),
          revision = app.cells_signup_options.revision + 1, updated_at = now();
  end if;
  perform app.cells_audit('cell_updated', v_actor.member_id, v_actor.account_id, 'admin', 'cells.update_cell', null,
                          v_cell.cell_id, null, null, null, null, v_revision);
  return app.cells_cell_outcome(v_cell.cell_id);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Commands: requests, confirmation and transfer
-- ---------------------------------------------------------------------------------------------

-- cells.request_change {cell_id, cell_revision, member_id?}; expected = the member's Cells
-- revision. The member for themselves, or an Admin for any approved member (member_id). The cell
-- must be a listed sign-up option at that revision.
create function app.cells_request_change(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_member uuid;
  v_capacity text := 'member';
  v_cell uuid;
  v_current record;
  v_request uuid;
  v_revision bigint;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['cell_id', 'cell_revision', 'member_id']);
  if app.contract_uuid_error(p_payload -> 'cell_id') is not null then
    v_errors := v_errors || jsonb_build_object('cell_id', app.contract_uuid_error(p_payload -> 'cell_id'));
  end if;
  if app.contract_revision_error(p_payload -> 'cell_revision') is not null then
    v_errors := v_errors || jsonb_build_object('cell_revision',
                                               app.contract_revision_error(p_payload -> 'cell_revision'));
  end if;
  if app.contract_uuid_error(p_payload -> 'member_id', true) is not null then
    v_errors := v_errors || jsonb_build_object('member_id',
                                               app.contract_uuid_error(p_payload -> 'member_id', true));
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  v_member := coalesce((p_payload ->> 'member_id')::uuid, v_actor.member_id);
  if v_member <> v_actor.member_id then
    if not v_actor.is_admin then
      perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
    end if;
    v_capacity := 'admin';
  end if;
  perform app.cells_sync_application_requests();
  perform app.cells_lock_member(v_member, p_expected_revision);
  v_cell := (p_payload ->> 'cell_id')::uuid;
  if app.cells_option_revision(v_cell) is distinct from (p_payload ->> 'cell_revision')::numeric::bigint then
    perform app.cmd_fail('validation_failed', '{"cell_id": "invalid"}');
  end if;
  select m.membership_id, m.cell_id into v_current
    from app.cells_memberships m where m.member_id = v_member and m.ended_at is null;
  if v_current.cell_id = v_cell then
    perform app.cmd_fail('validation_failed', '{"cell_id": "current"}');
  end if;
  if exists (select 1 from app.cells_membership_requests r
              where r.member_id = v_member and r.request_state in ('pending', 'referred')) then
    perform app.cmd_fail('conflict', '{"member_id": "open_request"}', p_expected_revision);
  end if;
  insert into app.cells_membership_requests (member_id, kind, origin, choice, requested_cell_id,
                                             requested_by_member, requested_by_account)
  values (v_member, case when v_current.membership_id is null then 'join' else 'change' end,
          case v_capacity when 'admin' then 'admin' else 'member' end, 'cell', v_cell,
          v_actor.member_id, v_actor.account_id)
  returning request_id into v_request;
  v_revision := app.cells_bump_member(v_member);
  perform app.cells_audit('request_opened', v_actor.member_id, v_actor.account_id, v_capacity, 'cells.request_change', v_member,
                          v_cell, v_current.cell_id, v_request, null, null, v_revision);
  return app.cells_member_outcome(v_member);
end;
$$;

-- Validates {request_id, ...allowed}, locks the request's member and the open request.
create function app.cells_lock_open_request(p_payload jsonb, p_allowed text[], p_expected bigint)
returns app.cells_membership_requests
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_member uuid;
  v_request app.cells_membership_requests;
begin
  v_errors := app.contract_unknown_keys(p_payload, p_allowed);
  if app.contract_uuid_error(p_payload -> 'request_id') is not null then
    v_errors := v_errors || jsonb_build_object('request_id',
                                               app.contract_uuid_error(p_payload -> 'request_id'));
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  perform app.cells_sync_application_requests();
  select r.member_id into v_member from app.cells_membership_requests r
   where r.request_id = (p_payload ->> 'request_id')::uuid;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  perform app.cells_lock_member(v_member, p_expected);
  select r.* into v_request from app.cells_membership_requests r
   where r.request_id = (p_payload ->> 'request_id')::uuid for update;
  if v_request.request_state not in ('pending', 'referred') then
    perform app.cmd_fail('conflict', '{"request_id": "decided"}', p_expected);
  end if;
  return v_request;
end;
$$;

-- In what capacity may the actor decide this request? 'admin', 'cell_leader' or null.
create function app.cells_decider(
  p_actor_member uuid,
  p_is_admin boolean,
  p_request app.cells_membership_requests
)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_is_admin then 'admin'
    when p_request.request_state = 'pending' and p_request.requested_cell_id is not null
         and app.identity_member_has_scope(p_actor_member, 'cell_leader',
                                           p_request.requested_cell_id) then 'cell_leader'
  end;
$$;

-- cells.confirm_request {request_id, cell_id?}; expected = the member's Cells revision.
-- The leader of the requested cell, or an Admin (who may name the cell; required for a request
-- without one). A member with a current primary cell is TRANSFERRED atomically.
create function app.cells_confirm_request(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_request app.cells_membership_requests;
  v_capacity text;
  v_cell uuid;
  v_old record;
  v_membership uuid;
  v_revision bigint;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  if app.contract_uuid_error(p_payload -> 'cell_id', true) is not null then
    perform app.cmd_fail('validation_failed',
      jsonb_build_object('cell_id', app.contract_uuid_error(p_payload -> 'cell_id', true)));
  end if;
  v_request := app.cells_lock_open_request(p_payload, array['request_id', 'cell_id'],
                                           p_expected_revision);
  v_capacity := app.cells_decider(v_actor.member_id, v_actor.is_admin, v_request);
  if v_capacity is null then
    perform app.cmd_fail('forbidden');
  end if;
  -- Separation of duty: nobody confirms their own cell membership.
  if v_request.member_id = v_actor.member_id then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  v_cell := coalesce((p_payload ->> 'cell_id')::uuid, v_request.requested_cell_id);
  if v_cell is null then
    perform app.cmd_fail('validation_failed', '{"cell_id": "required"}');
  end if;
  if v_capacity = 'cell_leader' and v_cell <> v_request.requested_cell_id then
    perform app.cmd_fail('forbidden', '{"cell_id": "unsupported"}');
  end if;
  perform 1 from app.cells_cells c where c.cell_id = v_cell and c.cell_state = 'active' for share;
  if not found then
    perform app.cmd_fail('validation_failed', '{"cell_id": "invalid"}');
  end if;
  select m.membership_id, m.cell_id into v_old
    from app.cells_memberships m
   where m.member_id = v_request.member_id and m.ended_at is null
     for update;
  if v_old.cell_id = v_cell then
    perform app.cmd_fail('validation_failed', '{"cell_id": "current"}');
  end if;
  -- End the old primary membership first (one current primary per member).
  if v_old.membership_id is not null then
    update app.cells_memberships m
       set ended_at = now(), end_reason = 'transferred', ended_by_request = v_request.request_id
     where m.membership_id = v_old.membership_id;
  end if;
  insert into app.cells_memberships (member_id, cell_id, request_id, confirmed_by_member,
                                     confirmed_by_account, confirmed_as)
  values (v_request.member_id, v_cell, v_request.request_id, v_actor.member_id, v_actor.account_id,
          v_capacity)
  returning membership_id into v_membership;
  update app.cells_membership_requests r
     set request_state = 'confirmed', decided_at = now(), updated_at = now(),
         decided_by_member = v_actor.member_id, decided_by_account = v_actor.account_id,
         decided_as = v_capacity, resulting_membership_id = v_membership
   where r.request_id = v_request.request_id;
  v_revision := app.cells_bump_member(v_request.member_id);
  perform app.cells_audit('request_confirmed', v_actor.member_id, v_actor.account_id, v_capacity, 'cells.confirm_request',
                          v_request.member_id, v_cell, v_old.cell_id, v_request.request_id,
                          v_membership, null, v_revision);
  perform app.cells_audit(case when v_old.membership_id is null then 'membership_started'
                               else 'membership_transferred' end, v_actor.member_id, v_actor.account_id, v_capacity, 'cells.confirm_request', v_request.member_id,
                          v_cell, v_old.cell_id, v_request.request_id, v_membership, null,
                          v_revision);
  if v_old.membership_id is not null then
    -- AD-14: registered owners (duties, chat, follow-ups, programmes ...) move or end their
    -- old-cell obligations inside this transaction; one failing hook rolls the transfer back.
    perform app.contract_dispatch_lifecycle(jsonb_build_object(
      'event', 'cell_transferred',
      'member_id', v_request.member_id,
      'occurred_at', app.cmd_utc(now()),
      'identity_revision', v_revision));
  end if;
  return app.cells_member_outcome(v_request.member_id);
end;
$$;

-- cells.decline_request {request_id, reason?}; expected = the member's Cells revision. A leader
-- refers the request to the Admin follow-up queue; an Admin's decline is final.
create function app.cells_decline_request(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_request app.cells_membership_requests;
  v_capacity text;
  v_reason text;
  v_revision bigint;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  if p_payload ? 'reason' and (jsonb_typeof(p_payload -> 'reason') <> 'string'
       or p_payload ->> 'reason' not in ('not_in_this_cell', 'not_known_to_leader',
                                         'member_withdrew', 'no_cell_for_now')) then
    perform app.cmd_fail('validation_failed', '{"reason": "invalid"}');
  end if;
  v_reason := p_payload ->> 'reason';
  v_request := app.cells_lock_open_request(p_payload, array['request_id', 'reason'],
                                           p_expected_revision);
  v_capacity := app.cells_decider(v_actor.member_id, v_actor.is_admin, v_request);
  if v_capacity is null then
    perform app.cmd_fail('forbidden');
  end if;
  if v_request.member_id = v_actor.member_id then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  if v_capacity = 'cell_leader' then
    update app.cells_membership_requests r
       set request_state = 'referred', updated_at = now(), decision_reason = v_reason
     where r.request_id = v_request.request_id;
  else
    update app.cells_membership_requests r
       set request_state = 'declined', decided_at = now(), updated_at = now(),
           decided_by_member = v_actor.member_id, decided_by_account = v_actor.account_id,
           decided_as = 'admin', decision_reason = v_reason
     where r.request_id = v_request.request_id;
  end if;
  v_revision := app.cells_bump_member(v_request.member_id);
  perform app.cells_audit(case v_capacity when 'cell_leader' then 'request_referred'
                                          else 'request_declined' end, v_actor.member_id, v_actor.account_id, v_capacity, 'cells.decline_request', v_request.member_id,
                          v_request.requested_cell_id, null, v_request.request_id, null, v_reason,
                          v_revision);
  return app.cells_member_outcome(v_request.member_id);
end;
$$;

-- cells.cancel_request {request_id}; expected = the member's Cells revision. The member's own
-- request, or an Admin.
create function app.cells_cancel_request(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_request app.cells_membership_requests;
  v_capacity text;
  v_revision bigint;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  v_request := app.cells_lock_open_request(p_payload, array['request_id'], p_expected_revision);
  if v_request.member_id = v_actor.member_id then
    v_capacity := 'member';
  elsif v_actor.is_admin then
    v_capacity := 'admin';
  else
    perform app.cmd_fail('forbidden');
  end if;
  update app.cells_membership_requests r
     set request_state = 'cancelled', decided_at = now(), updated_at = now(),
         decided_by_member = v_actor.member_id, decided_by_account = v_actor.account_id,
         decided_as = v_capacity,
         decision_reason = case v_capacity when 'admin' then 'cancelled_by_admin'
                                           else 'member_withdrew' end
   where r.request_id = v_request.request_id;
  v_revision := app.cells_bump_member(v_request.member_id);
  perform app.cells_audit('request_cancelled', v_actor.member_id, v_actor.account_id, v_capacity, 'cells.cancel_request',
                          v_request.member_id, v_request.requested_cell_id, null,
                          v_request.request_id, null,
                          case v_capacity when 'admin' then 'cancelled_by_admin'
                                          else 'member_withdrew' end,
                          v_revision);
  return app.cells_member_outcome(v_request.member_id);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Command entry point and the registered `cells` authorizer
-- ---------------------------------------------------------------------------------------------

-- `cells.*`: a live member session (identity_evaluate_grant); handlers check Admin, leader
-- scope or self. The actor's Admin and cell leader/assistant grants are share-locked here, so a
-- concurrent revocation waits for the command (AD-2: authority rows before the receipt).
create function app.cells_authorize_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  if coalesce(p_request ->> 'command', '') not in (
       'cells.create_cell', 'cells.update_cell', 'cells.request_change', 'cells.confirm_request',
       'cells.decline_request', 'cells.cancel_request') then
    return false;
  end if;
  select e.* into r from app.identity_evaluate_grant(null, null, null) e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  if r.outcome <> 'granted' then
    return false;
  end if;
  perform 1 from app.identity_grants g
   where g.member_id = r.member_id and g.revoked_at is null
     and (g.role = 'admin' or g.scope_kind in ('cell_leader', 'cell_assistant'))
     for share;
  return true;
end;
$$;

select app.cmd_register_authorizer('cells', 'app.cells_authorize_command(jsonb)'::regprocedure);

create function app.cells_in_scope(p_actor uuid, p_aggregate_type text, p_aggregate_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_aggregate_id is not null and case p_aggregate_type
    when 'cells_cell' then exists (select 1 from app.cells_cells c where c.cell_id = p_aggregate_id)
    when 'cells_member_cell' then exists (select 1 from app.cells_member_states s
                                           where s.member_id = p_aggregate_id)
    else false end;
$$;

create function app.cells_command(p_envelope jsonb)
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
      when 'cells.create_cell' then 'app.cells_create_cell(uuid, bigint, jsonb)'::regprocedure
      when 'cells.update_cell' then 'app.cells_update_cell(uuid, bigint, jsonb)'::regprocedure
      when 'cells.request_change' then 'app.cells_request_change(uuid, bigint, jsonb)'::regprocedure
      when 'cells.confirm_request' then 'app.cells_confirm_request(uuid, bigint, jsonb)'::regprocedure
      when 'cells.decline_request' then 'app.cells_decline_request(uuid, bigint, jsonb)'::regprocedure
      when 'cells.cancel_request' then 'app.cells_cancel_request(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.cells_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'cells.create_cell'
  );
end;
$$;

-- POST /rest/v1/rpc/cells_command, Content-Profile: api,
-- body {version, command, request_id, expected_revision, payload}.
create function api.cells_command(jsonb)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.cells_command($1);
$$;

comment on function api.cells_command(jsonb) is
  'Story 2.6: cell setup, membership requests, leader/Admin confirmation and atomic transfer '
  '(cells.create_cell, update_cell, request_change, confirm_request, decline_request, '
  'cancel_request) through the 1.4 command envelope.';

-- ---------------------------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------------------------

-- Raises the read-side denial for a closed personal-data gate.
create function app.cells_require_open_read()
returns void
language plpgsql
set search_path = ''
as $$
begin
  if not app.identity_applications_open() then
    raise exception using errcode = 'PT403', message = 'unavailable', detail = 'unavailable';
  end if;
end;
$$;

-- The signed-in member's own cell, open request and last decision.
create function app.cells_my_cell()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  perform app.cells_require_open_read();
  perform app.cells_sync_application_requests();
  perform app.identity_record_activity(v_link);
  return app.cells_member_json(v_member);
end;
$$;

create function api.cells_my_cell()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.cells_my_cell();
$$;

comment on function api.cells_my_cell() is
  'Story 2.6: the signed-in member''s primary cell (safe label), open request and last decision.';

-- Leaders and assistants: each cell they serve with its current roster; leaders also see the
-- open (pending) requests for their cell. Nobody else is listed.
create function app.cells_leader_queue()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_result jsonb;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  if not exists (select 1 from app.identity_grants g
                  where g.member_id = v_member and g.revoked_at is null
                    and g.scope_kind in ('cell_leader', 'cell_assistant')) then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  perform app.cells_require_open_read();
  perform app.cells_sync_application_requests();
  select jsonb_build_object('cells', coalesce(jsonb_agg(x.obj order by x.name, x.cell_id), '[]'::jsonb))
    into v_result
    from (
      select c.cell_id, c.name, jsonb_build_object(
               'cell_id', c.cell_id,
               'name', c.name,
               'broad_area', c.broad_area,
               'role', case when bool_or(g.scope_kind = 'cell_leader') then 'leader' else 'assistant' end,
               'members', coalesce((
                 select jsonb_agg(jsonb_build_object('member_id', m.member_id,
                                                     'display_name', im.display_name,
                                                     'since', app.cmd_utc(m.started_at))
                                  order by im.display_name, m.member_id)
                   from app.cells_memberships m
                   join app.identity_members im on im.member_id = m.member_id
                  where m.cell_id = c.cell_id and m.ended_at is null), '[]'::jsonb),
               'requests', case when bool_or(g.scope_kind = 'cell_leader') then coalesce((
                 select jsonb_agg(jsonb_build_object(
                                    'request_id', r.request_id, 'member_id', r.member_id,
                                    'display_name', im.display_name, 'kind', r.kind,
                                    'origin', r.origin, 'member_revision', s.revision,
                                    'own_record', r.member_id = v_member,
                                    'created_at', app.cmd_utc(r.created_at))
                                  order by r.created_at, r.request_id)
                   from app.cells_membership_requests r
                   join app.cells_member_states s on s.member_id = r.member_id
                   join app.identity_members im on im.member_id = r.member_id
                  where r.requested_cell_id = c.cell_id and r.request_state = 'pending'),
                 '[]'::jsonb) else '[]'::jsonb end) as obj
        from app.identity_grants g
        join app.cells_cells c on c.cell_id = g.scope_id
       where g.member_id = v_member and g.revoked_at is null
         and g.scope_kind in ('cell_leader', 'cell_assistant')
       group by c.cell_id, c.name, c.broad_area
    ) x;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

create function api.cells_leader_queue()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.cells_leader_queue();
$$;

comment on function api.cells_leader_queue() is
  'Story 2.6: leaders/assistants: their cells'' rosters; leaders: open requests for their cells.';

-- Admin only: every cell with its leaders and assistants, every open request (follow_up = no
-- cell chosen or referred by a leader) and the approved members with their cell (at most 500,
-- a church of under 200). Membership metadata only: no cell-private content.
create function app.cells_admin_overview()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link uuid;
  v_member uuid;
begin
  select g.member_id, g.link_id into v_member, v_link from app.identity_require_grant('admin', null, null) g;
  perform app.cells_require_open_read();
  perform app.cells_sync_application_requests();
  perform app.identity_record_activity(v_link);
  return jsonb_build_object(
    'cells', coalesce((select jsonb_agg(app.cells_cell_json(c.cell_id) order by c.name, c.cell_id)
                         from app.cells_cells c
                        where not c.is_synthetic
                           or app.platform_current_environment() in ('local', 'staging')),
                      '[]'::jsonb),
    'requests', coalesce((
      select jsonb_agg(jsonb_build_object(
               'request_id', r.request_id, 'member_id', r.member_id,
               'display_name', im.display_name, 'kind', r.kind, 'origin', r.origin,
               'choice', r.choice, 'state', r.request_state,
               'requested_cell_id', r.requested_cell_id,
               'requested_cell_name', (select c.name from app.cells_cells c
                                        where c.cell_id = r.requested_cell_id),
               'current_cell_id', cm.cell_id,
               'current_cell_name', (select c.name from app.cells_cells c where c.cell_id = cm.cell_id),
               'reason', r.decision_reason,
               'follow_up', r.requested_cell_id is null or r.request_state = 'referred',
               'member_revision', s.revision,
               'own_record', r.member_id = v_member,
               'created_at', app.cmd_utc(r.created_at))
             order by r.created_at, r.request_id)
        from app.cells_membership_requests r
        join app.cells_member_states s on s.member_id = r.member_id
        join app.identity_members im on im.member_id = r.member_id
        left join app.cells_memberships cm on cm.member_id = r.member_id and cm.ended_at is null
       where r.request_state in ('pending', 'referred')), '[]'::jsonb),
    'members', coalesce((
      select jsonb_agg(x.obj order by x.display_name collate "C", x.member_id)
        from (
          select im.member_id, im.display_name, jsonb_build_object(
                   'member_id', im.member_id, 'display_name', im.display_name,
                   'account', app.identity_member_account_label(im.member_id),
                   'grants_revision', gs.revision,
                   'cell_revision', coalesce(s.revision, 1),
                   'cell_id', cm.cell_id,
                   'open_request_id', (select r.request_id from app.cells_membership_requests r
                                        where r.member_id = im.member_id
                                          and r.request_state in ('pending', 'referred'))) as obj
            from app.identity_members im
            join app.identity_grant_sets gs on gs.member_id = im.member_id
            left join app.cells_member_states s on s.member_id = im.member_id
            left join app.cells_memberships cm on cm.member_id = im.member_id and cm.ended_at is null
           where im.membership_state = 'approved'
           order by im.display_name collate "C", im.member_id
           limit 500) x), '[]'::jsonb));
end;
$$;

create function api.cells_admin_overview()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.cells_admin_overview();
$$;

comment on function api.cells_admin_overview() is
  'Story 2.6: Admin-only cells, leaders, open requests (follow-up flagged) and members'' cells.';

-- SYNTHETIC cell-private surface: readable only by a current member, leader or assistant of the
-- cell (app.cells_member_has_private_access) through the live-access predicate.
create function app.cells_private_fixture_read(p_cell_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
begin
  select a.member_id into v_member from app.identity_require_access() a;
  if p_cell_id is null or not app.cells_member_has_private_access(v_member, p_cell_id) then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  return jsonb_build_object('cell_id', p_cell_id, 'content', 'SYNTHETIC cell-private fixture surface');
end;
$$;

create function api.cells_private_fixture_read(cell_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.cells_private_fixture_read(cell_id);
$$;

comment on function api.cells_private_fixture_read(uuid) is
  'SYNTHETIC (story 2.6): a cell-private stand-in readable only with current cell access.';

-- ---------------------------------------------------------------------------------------------
-- SYNTHETIC fixture lifecycle hook (registered only by tests and the local E2E)
-- ---------------------------------------------------------------------------------------------

create function app.fixture_record_lifecycle(p_event jsonb)
returns void
language sql
set search_path = ''
as $$
  insert into app.fixture_lifecycle_calls (event, member_id, identity_revision)
  values (p_event ->> 'event', (p_event ->> 'member_id')::uuid,
          (p_event ->> 'identity_revision')::bigint);
$$;

comment on function app.fixture_record_lifecycle(jsonb) is
  'SYNTHETIC lifecycle hook: records the call and its transaction id. Register only in tests.';

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.cells_scope_target_ok(jsonb),
  app.cells_member_has_private_access(uuid, uuid),
  app.cells_sync_application_requests(),
  app.cells_command_actor(uuid),
  app.cells_require_open(),
  app.cells_lock_member(uuid, bigint),
  app.cells_bump_member(uuid),
  app.cells_label(uuid),
  app.cells_member_json(uuid),
  app.cells_member_outcome(uuid),
  app.cells_cell_json(uuid),
  app.cells_cell_outcome(uuid),
  app.cells_text(jsonb, text, boolean, jsonb),
  app.cells_audit(text, uuid, uuid, text, text, uuid, uuid, uuid, uuid, uuid, text, bigint),
  app.cells_create_cell(uuid, bigint, jsonb),
  app.cells_update_cell(uuid, bigint, jsonb),
  app.cells_request_change(uuid, bigint, jsonb),
  app.cells_lock_open_request(jsonb, text[], bigint),
  app.cells_decider(uuid, boolean, app.cells_membership_requests),
  app.cells_confirm_request(uuid, bigint, jsonb),
  app.cells_decline_request(uuid, bigint, jsonb),
  app.cells_cancel_request(uuid, bigint, jsonb),
  app.cells_authorize_command(jsonb),
  app.cells_in_scope(uuid, text, uuid),
  app.cells_command(jsonb),
  api.cells_command(jsonb),
  app.cells_require_open_read(),
  app.cells_my_cell(),
  api.cells_my_cell(),
  app.cells_leader_queue(),
  api.cells_leader_queue(),
  app.cells_admin_overview(),
  api.cells_admin_overview(),
  app.cells_private_fixture_read(uuid),
  api.cells_private_fixture_read(uuid),
  app.fixture_record_lifecycle(jsonb)
  from public, anon, authenticated, service_role;

grant execute on function app.cells_command(jsonb) to authenticated;
grant execute on function api.cells_command(jsonb) to authenticated;
grant execute on function app.cells_my_cell() to authenticated;
grant execute on function api.cells_my_cell() to authenticated;
grant execute on function app.cells_leader_queue() to authenticated;
grant execute on function api.cells_leader_queue() to authenticated;
grant execute on function app.cells_admin_overview() to authenticated;
grant execute on function api.cells_admin_overview() to authenticated;
grant execute on function app.cells_private_fixture_read(uuid) to authenticated;
grant execute on function api.cells_private_fixture_read(uuid) to authenticated;

notify pgrst, 'reload schema';
