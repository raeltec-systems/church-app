-- Confirm and transfer primary cell membership (story 2.6; AD-1, AD-2, AD-3, AD-4, AD-14).
-- Admin cell setup, cell leader/assistant scopes (2.3 grant model), requests from approved
-- applications, members and Admins, leader/Admin confirmation separate from church approval,
-- the Admin follow-up queue, and the atomic confirmed transfer that ends old-cell access and runs
-- the registered `cell_transferred` hooks in the same transaction. HTTP evidence with real phone
-- sign-up: tools/identity-e2e/cells.mjs. Every account, phone and name here is SYNTHETIC
-- (fictional range +1 202 555 0120-0139).
begin;
select plan(88);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000026' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000026' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+120255501' || (20 + n)::text $$;

create function pg_temp.claims(p_sub uuid, p_session uuid, p_method text default 'password')
returns jsonb
language sql as $$
  select jsonb_build_object(
    'sub', p_sub, 'role', 'authenticated', 'aal', 'aal1', 'session_id', p_session,
    'is_anonymous', false,
    'amr', jsonb_build_array(jsonb_build_object('method', p_method, 'timestamp', 1790000000)))
$$;
create function pg_temp.c(n int) returns jsonb language sql as
$$ select pg_temp.claims(pg_temp.u(n), pg_temp.s(n)) $$;

create function pg_temp.session(p_user uuid, p_session uuid, p_method text default 'password',
                                p_age interval default interval '1 hour')
returns uuid
language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at)
  values (p_session, p_user, 'aal1', clock_timestamp() - p_age);
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now(), now(), p_method);
  select p_session;
$$;
-- A fresh password session of account n, opened after every trust epoch so far.
create function pg_temp.fresh(n int) returns jsonb language plpgsql as $$
declare
  v_session uuid := gen_random_uuid();
begin
  perform pg_temp.session(pg_temp.u(n), v_session, 'password', interval '-1 minute');
  return pg_temp.claims(pg_temp.u(n), v_session);
end;
$$;

create function pg_temp.cmd(p_claims jsonb, p_fn text, p_command text, p_expected bigint,
                            p_payload jsonb, p_request uuid default gen_random_uuid())
returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
  set local role authenticated;
  execute format('select %s($1)', p_fn) into r using jsonb_build_object(
         'version', 1, 'command', p_command, 'request_id', p_request,
         'expected_revision', p_expected, 'payload', p_payload);
  reset role;
  return r;
end;
$$;
create function pg_temp.cells(p_claims jsonb, p_command text, p_expected bigint, p_payload jsonb,
                              p_request uuid default gen_random_uuid())
returns jsonb language sql as $$
  select pg_temp.cmd(p_claims, 'api.cells_command', p_command, p_expected, p_payload, p_request)
$$;

create function pg_temp.read(p_claims jsonb, p_sql text) returns text
language plpgsql as $$
declare
  r jsonb;
  v_state text; v_msg text; v_detail text;
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, '{}'::jsonb)::text, true);
  set local role authenticated;
  begin
    execute p_sql into r;
    reset role;
    return 'ok ' || coalesce(r::text, 'null');
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
    reset role;
    return v_state || '|' || v_msg || '|' || coalesce(v_detail, '');
  end;
end;
$$;
create function pg_temp.readj(p_claims jsonb, p_sql text) returns jsonb language sql as
$$ select substr(pg_temp.read(p_claims, p_sql), 4)::jsonb $$;
create function pg_temp.private(p_claims jsonb, p_cell uuid) returns text language sql as
$$ select case when r like 'ok %SYNTHETIC cell-private fixture surface%' then 'ok' else r end
     from (select pg_temp.read(p_claims, format('select api.cells_private_fixture_read(%L)', p_cell)) as r) q $$;

-- Fixtures. 1 Admin A, 2 Admin B, 3 leader of X, 4 leader of Y, 5 assistant of X, 6 an applicant
-- who asks for X, 7 a member an Admin moves, 8 a plain member, 9 an applicant who is not sure.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 9) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 9) n;
select pg_temp.session(pg_temp.u(1), pg_temp.s(21), 'otp');

-- Structure, privileges and guards ----------------------------------------------------------------
select ok((select count(*) from information_schema.tables where table_schema = 'app'
            and table_name in ('cells_member_states', 'cells_membership_requests',
                               'cells_memberships', 'cells_membership_audit',
                               'fixture_lifecycle_calls')) = 5,
  'member state, request, membership, audit and fixture-call tables exist');
select ok(not exists (
  select 1 from unnest(array['app.cells_member_states', 'app.cells_membership_requests',
                             'app.cells_memberships', 'app.cells_membership_audit',
                             'app.fixture_lifecycle_calls']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p)),
  'no client role has any privilege on the new tables');
select is((select array_agg(column_name::text order by column_name::text)
             from information_schema.columns
            where table_schema = 'app' and table_name = 'cells_membership_audit'),
  array['action', 'actor_account_id', 'actor_capacity', 'actor_kind', 'actor_member_id', 'cell_id',
        'command_request_id', 'environment', 'event_id', 'from_cell_id', 'member_id',
        'membership_id', 'membership_request_id', 'occurred_at', 'reason_code', 'revision_after'],
  'the audit holds ids, codes and revisions only (no names, phones or free text)');
select ok(not has_function_privilege('anon', 'api.cells_command(jsonb)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.cells_my_cell()', 'EXECUTE')
          and not has_function_privilege('anon', 'api.cells_leader_queue()', 'EXECUTE')
          and not has_function_privilege('anon', 'api.cells_admin_overview()', 'EXECUTE')
          and not has_function_privilege('anon', 'api.cells_private_fixture_read(uuid)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.fixture_record_lifecycle(jsonb)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'app.cells_member_has_private_access(uuid, uuid)', 'EXECUTE'),
  'signed-out callers reach none of the cells endpoints; helpers and the fixture hook are server-only');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select is((select array_agg(k.scope_kind || ':' || k.module order by k.scope_kind)
             from app.identity_scope_kinds k where k.module = 'cells'),
  array['cell_assistant:cells', 'cell_leader:cells'],
  'Cells registers the cell leader and assistant scope kinds in the Identity grant model');
select is((select a.handler from app.cmd_authorizers a where a.namespace = 'cells'),
  'app.cells_authorize_command(jsonb)', 'the cells authorizer is registered for cells.*');
select is((select e.emitter_module from app.contract_lifecycle_events e where e.event = 'cell_transferred'),
  'cells', 'Cells emits cell_transferred');
select is((select count(*)::int from app.contract_lifecycle_hooks h where h.event = 'cell_transferred'), 0,
  'no hook is registered by the migration (the SYNTHETIC hook is registered only by tests)');

-- Environment, members, Admins --------------------------------------------------------------------
select app.platform_set_environment('local', 'pgtap 2.6');
create temp table m as
select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 2.6 Member ' || n, 'pgtap 2.6') as member_id
  from (values (1), (2), (3), (4), (5), (7), (8)) v(n);
create function pg_temp.mid(n int) returns uuid language sql as
$$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(2), 'admin', 'israel');

-- Admin cell setup --------------------------------------------------------------------------------
select is(pg_temp.cells(pg_temp.c(8), 'cells.create_cell', null,
  '{"name": "SYNTHETIC X", "signup_label": "SYNTHETIC X", "broad_area": "SYNTHETIC North"}') ->> 'code',
  'forbidden', 'a member without Admin cannot create a cell');
select is(pg_temp.cells(pg_temp.claims(pg_temp.u(1), pg_temp.s(21)), 'cells.create_cell', null,
  '{"name": "SYNTHETIC X", "signup_label": "SYNTHETIC X", "broad_area": "SYNTHETIC North"}') ->> 'code',
  'unauthenticated', 'an Admin''s OTP session is unauthenticated for cells commands');
select is(pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "Riverside", "signup_label": "", "extra": 1}') -> 'field_errors',
  '{"name": "invalid", "signup_label": "required", "broad_area": "required", "extra": "unknown_field"}'::jsonb,
  'every field error at once; while Q4 is unapproved cell names are SYNTHETIC');
create temp table cx as select pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "SYNTHETIC 2.6 Cell X", "signup_label": "SYNTHETIC  X  label", "broad_area": "SYNTHETIC North"}') as r;
create temp table cy as select pg_temp.cells(pg_temp.c(1), 'cells.create_cell', null,
  '{"name": "SYNTHETIC 2.6 Cell Y", "signup_label": "SYNTHETIC Y label", "broad_area": "SYNTHETIC South"}') as r;
create function pg_temp.x() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from cx $$;
create function pg_temp.y() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from cy $$;
select is((select r #>> '{data,signup_label}' from cx) || '|' || (select r ->> 'revision' from cx)
          || '|' || (select r #>> '{data,listed}' from cx),
  'SYNTHETIC X label|1|true', 'an Admin creates a cell with its safe sign-up label (whitespace collapsed)');
select ok(app.cells_option_revision(pg_temp.x()) = 1 and app.cells_option_revision(pg_temp.y()) = 1,
  'new cells are listed in the safe chooser');
select is(pg_temp.cells(pg_temp.c(1), 'cells.update_cell', 7,
  jsonb_build_object('cell_id', pg_temp.x(), 'broad_area', 'SYNTHETIC North bank')) ->> 'code',
  'conflict', 'a stale cell revision is a conflict');
select is(pg_temp.cells(pg_temp.c(1), 'cells.update_cell', 1,
  jsonb_build_object('cell_id', pg_temp.x(), 'broad_area', 'SYNTHETIC North bank')) #>> '{data,broad_area}',
  'SYNTHETIC North bank', 'an Admin updates the cell; the sign-up option follows');
select is(app.cells_option_revision(pg_temp.x()), 2::bigint, 'the option revision moved (choosers reload)');
select is((select string_agg(action, ',' order by event_id) from app.cells_membership_audit),
  'cell_created,cell_created,cell_updated', 'cell setup is audited');

-- Leaders and assistants are Identity scope grants (2.3 command) -----------------------------------
create function pg_temp.grant_scope(p_admin int, p_member int, p_kind text, p_cell uuid) returns jsonb
language sql as $$
  select pg_temp.cmd(pg_temp.c(p_admin), 'api.identity_grant_command', 'identity.grant_scope',
    (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(p_member)),
    jsonb_build_object('member_id', pg_temp.mid(p_member), 'scope_kind', p_kind, 'scope_id', p_cell))
$$;
select is(pg_temp.grant_scope(1, 3, 'cell_leader', '00000000-0000-4000-8000-00000000dead') -> 'field_errors',
  '{"scope_id": "unknown"}'::jsonb, 'a leader scope needs an existing cell (Cells target hook)');
select is(pg_temp.grant_scope(1, 3, 'cell_leader', pg_temp.x()) #>> '{data,scopes,0,scope_kind}', 'cell_leader',
  'an Admin makes member 3 the leader of X with identity.grant_scope');
select pg_temp.grant_scope(1, 4, 'cell_leader', pg_temp.y());
select pg_temp.grant_scope(1, 5, 'cell_assistant', pg_temp.x());
select is(jsonb_array_length((select r #> '{data,leaders}' from (select pg_temp.cells(pg_temp.c(1), 'cells.update_cell', 2,
  jsonb_build_object('cell_id', pg_temp.x(), 'listed', true)) as r) q)), 1,
  'the cell view lists its leader');

-- Applications: a chosen cell and an unresolved choice, approved by an Admin ------------------------
select pg_temp.cmd(pg_temp.c(6), 'api.identity_application_command', 'identity.submit_application', null,
  jsonb_build_object('full_name', 'SYNTHETIC 2.6 Applicant Six',
    'cell_choice', jsonb_build_object('choice', 'cell', 'cell_id', pg_temp.x(),
                                      'cell_revision', app.cells_option_revision(pg_temp.x())),
    'privacy_notice_version', 'draft-2026-10-07'));
select pg_temp.cmd(pg_temp.c(9), 'api.identity_application_command', 'identity.submit_application', null,
  jsonb_build_object('full_name', 'SYNTHETIC 2.6 Applicant Nine', 'cell_choice', '{"choice": "not_sure"}'::jsonb,
    'privacy_notice_version', 'draft-2026-10-07'));
create function pg_temp.app_of(n int) returns app.identity_membership_applications language sql as
$$ select a.* from app.identity_membership_applications a where a.auth_user_id = pg_temp.u(n) $$;
select is(pg_temp.read(pg_temp.c(3), 'select api.cells_leader_queue()') like 'ok %"requests": []%', true,
  'before the church approves, the leader sees no request (an application is not a cell request)');
create temp table approved as
select n, (pg_temp.cmd(pg_temp.c(1), 'api.identity_review_command', 'identity.approve_application',
          (pg_temp.app_of(n)).revision,
          jsonb_build_object('application_id', (pg_temp.app_of(n)).application_id,
                             'identity_check', 'in_person')) #>> '{data,member_id}')::uuid as member_id
  from (values (6), (9)) v(n);
insert into m select n, member_id from approved;
select is((select count(*)::int from app.cells_memberships), 0,
  'church approval confirms no cell membership');

create temp table lq3 as select pg_temp.readj(pg_temp.c(3), 'select api.cells_leader_queue()') as r;
select is((select r #>> '{cells,0,role}' from lq3) || '|' || (select r #>> '{cells,0,requests,0,display_name}' from lq3)
          || '|' || (select r #>> '{cells,0,requests,0,kind}' from lq3)
          || '|' || (select jsonb_array_length(r #> '{cells,0,requests}') from lq3),
  'leader|SYNTHETIC 2.6 Applicant Six|join|1',
  'the leader of X sees the approved applicant''s request (and not the unresolved one)');
select is(pg_temp.readj(pg_temp.c(4), 'select api.cells_leader_queue()') #> '{cells,0,requests}', '[]'::jsonb,
  'the leader of Y sees no request for X');
select is(pg_temp.readj(pg_temp.c(5), 'select api.cells_leader_queue()') #>> '{cells,0,role}', 'assistant',
  'an assistant reads the roster');
select is(pg_temp.readj(pg_temp.c(5), 'select api.cells_leader_queue()') #> '{cells,0,requests}', '[]'::jsonb,
  'an assistant sees no requests to confirm');
select is(pg_temp.read(pg_temp.c(8), 'select api.cells_leader_queue()'), 'PT403|forbidden|not_granted',
  'a member who leads no cell cannot read a leader queue');
select is(pg_temp.read(pg_temp.c(3), 'select api.cells_admin_overview()'), 'PT403|forbidden|not_granted',
  'a leader cannot read the Admin overview');
create temp table ov as select pg_temp.readj(pg_temp.c(1), 'select api.cells_admin_overview()') as r;
select is((select string_agg((e ->> 'choice') || ':' || (e ->> 'follow_up'), ',' order by e ->> 'choice')
             from ov, jsonb_array_elements(r -> 'requests') e),
  'cell:false,not_sure:true', 'the Admin sees both requests; the unresolved choice is in the follow-up queue');
select is((select count(*)::int from app.cells_membership_requests where origin = 'application'), 2,
  'one request per approved application (reads do not duplicate them)');

create function pg_temp.req(n int) returns app.cells_membership_requests language sql as
$$ select r.* from app.cells_membership_requests r where r.member_id = pg_temp.mid(n)
    order by (r.request_state in ('pending', 'referred')) desc, r.request_id limit 1 $$;
create function pg_temp.rev(n int) returns bigint language sql as
$$ select coalesce((select s.revision from app.cells_member_states s where s.member_id = pg_temp.mid(n)), 1) $$;

-- Confirming a join -------------------------------------------------------------------------------
select is(pg_temp.private(pg_temp.fresh(6), pg_temp.x()), 'PT403|forbidden|not_granted',
  'before confirmation the approved member has no cell-private access');
select is(pg_temp.cells(pg_temp.c(4), 'cells.confirm_request', pg_temp.rev(6),
  jsonb_build_object('request_id', (pg_temp.req(6)).request_id)) ->> 'code', 'forbidden',
  'the leader of another cell cannot confirm');
select is(pg_temp.cells(pg_temp.c(5), 'cells.confirm_request', pg_temp.rev(6),
  jsonb_build_object('request_id', (pg_temp.req(6)).request_id)) ->> 'code', 'forbidden',
  'an assistant cannot confirm');
select is(pg_temp.cells(pg_temp.c(3), 'cells.confirm_request', pg_temp.rev(6) + 5,
  jsonb_build_object('request_id', (pg_temp.req(6)).request_id)) ->> 'code', 'conflict',
  'a stale member revision is a conflict');
select is(pg_temp.cells(pg_temp.c(3), 'cells.confirm_request', pg_temp.rev(6),
  jsonb_build_object('request_id', (pg_temp.req(6)).request_id, 'cell_id', pg_temp.y())) -> 'field_errors',
  '{"cell_id": "unsupported"}'::jsonb, 'a leader cannot confirm into another cell');
create temp table conf6 as select pg_temp.cells(pg_temp.c(3), 'cells.confirm_request', pg_temp.rev(6),
  jsonb_build_object('request_id', (pg_temp.req(6)).request_id)) as r;
select is((select r #>> '{data,primary,cell_id}' from conf6) || '|' || (select r #>> '{data,primary,label}' from conf6),
  pg_temp.x()::text || '|SYNTHETIC X label', 'the leader confirms: X is the member''s primary cell');
select is(pg_temp.private(pg_temp.fresh(6), pg_temp.x()), 'ok',
  'the confirmed member reaches X''s private surface');
select is(pg_temp.private(pg_temp.fresh(6), pg_temp.y()), 'PT403|forbidden|not_granted',
  'but not Y''s');
select is(pg_temp.private(pg_temp.c(5), pg_temp.x()), 'ok',
  'the assistant reaches X''s private surface');
select is(pg_temp.private(pg_temp.c(1), pg_temp.x()), 'PT403|forbidden|not_granted',
  'the Admin role alone gives no cell-private access');
select is(pg_temp.readj(pg_temp.fresh(6), 'select api.cells_my_cell()') #>> '{primary,cell_id}', pg_temp.x()::text,
  'the member reads their own confirmed cell');

-- The Admin follow-up queue ------------------------------------------------------------------------
select is(pg_temp.cells(pg_temp.c(3), 'cells.confirm_request', pg_temp.rev(9),
  jsonb_build_object('request_id', (pg_temp.req(9)).request_id, 'cell_id', pg_temp.x())) ->> 'code',
  'forbidden', 'a leader cannot resolve an unresolved choice (Admin follow-up)');
select is(pg_temp.cells(pg_temp.c(1), 'cells.confirm_request', pg_temp.rev(9),
  jsonb_build_object('request_id', (pg_temp.req(9)).request_id)) -> 'field_errors',
  '{"cell_id": "required"}'::jsonb, 'resolving a follow-up needs the cell the Admin checked');
select is(pg_temp.cells(pg_temp.c(1), 'cells.confirm_request', pg_temp.rev(9),
  jsonb_build_object('request_id', (pg_temp.req(9)).request_id, 'cell_id', pg_temp.y())) #>> '{data,primary,cell_id}',
  pg_temp.y()::text, 'an Admin records the confirmation after checking with the leader');

-- Change requests -------------------------------------------------------------------------------
select is(pg_temp.cells(pg_temp.fresh(6), 'cells.request_change', pg_temp.rev(6),
  jsonb_build_object('cell_id', pg_temp.x(), 'cell_revision', app.cells_option_revision(pg_temp.x()))) -> 'field_errors',
  '{"cell_id": "current"}'::jsonb, 'a change to the current cell is refused');
select is(pg_temp.cells(pg_temp.fresh(6), 'cells.request_change', pg_temp.rev(6),
  jsonb_build_object('cell_id', pg_temp.y(), 'cell_revision', 99)) -> 'field_errors',
  '{"cell_id": "invalid"}'::jsonb, 'a change needs the listed option at its current revision');
select is(pg_temp.cells(pg_temp.c(8), 'cells.request_change', pg_temp.rev(6),
  jsonb_build_object('member_id', pg_temp.mid(6), 'cell_id', pg_temp.y(),
                     'cell_revision', app.cells_option_revision(pg_temp.y()))) -> 'field_errors',
  '{"member_id": "unsupported"}'::jsonb, 'a member cannot request a change for someone else');
create temp table chg as select pg_temp.cells(pg_temp.fresh(6), 'cells.request_change', pg_temp.rev(6),
  jsonb_build_object('cell_id', pg_temp.y(), 'cell_revision', app.cells_option_revision(pg_temp.y()))) as r;
select is((select r #>> '{data,open_request,kind}' from chg) || '|' || (select r #>> '{data,primary,cell_id}' from chg),
  'change|' || pg_temp.x()::text, 'the member asks to move to Y: a change request, still in X');
select is(pg_temp.cells(pg_temp.fresh(6), 'cells.request_change', pg_temp.rev(6),
  jsonb_build_object('cell_id', pg_temp.y(), 'cell_revision', app.cells_option_revision(pg_temp.y()))) ->> 'code',
  'conflict', 'one open request per member');
select is(pg_temp.private(pg_temp.fresh(6), pg_temp.y()), 'PT403|forbidden|not_granted',
  'a request grants nothing in the requested cell');

-- Atomic transfer: a failing hook rolls everything back -------------------------------------------
create function app.fixture_fail_lifecycle(p_event jsonb) returns void language plpgsql set search_path = '' as $$
begin
  raise exception 'SYNTHETIC hook failure';
end;
$$;
select app.contract_register_lifecycle_hook('fixture', 'cell_transferred', 'app.fixture_fail_lifecycle(jsonb)'::regprocedure);
create temp table before_transfer as
select (select row(im.revision, im.membership_state, im.updated_at)::text from app.identity_members im
         where im.member_id = pg_temp.mid(6)) as member_row,
       (select gs.revision from app.identity_grant_sets gs where gs.member_id = pg_temp.mid(6)) as grants_rev,
       (select row(l.link_id, l.link_state, l.sessions_valid_after, l.binding_revision)::text
          from app.identity_account_links l where l.member_id = pg_temp.mid(6) and l.link_state <> 'ended') as link_row;
select is(pg_temp.cells(pg_temp.c(4), 'cells.confirm_request', pg_temp.rev(6),
  jsonb_build_object('request_id', (pg_temp.req(6)).request_id)) ->> 'code', 'unavailable',
  'a failing owner hook fails the transfer');
select is((select string_agg(cell_id::text || ':' || (ended_at is null)::text, ',') from app.cells_memberships
            where member_id = pg_temp.mid(6)) || '|' || (pg_temp.req(6)).request_state,
  pg_temp.x()::text || ':true|pending', 'and rolls it back: still in X, the request still pending');

-- The registered transfer hook runs in the confirming transaction
update app.contract_lifecycle_hooks set handler = 'app.fixture_record_lifecycle(jsonb)'
 where event = 'cell_transferred' and module = 'fixture';
select is(pg_temp.cells(pg_temp.c(3), 'cells.confirm_request', pg_temp.rev(6),
  jsonb_build_object('request_id', (pg_temp.req(6)).request_id)) ->> 'code', 'forbidden',
  'the old cell''s leader cannot confirm the move into another cell');
create temp table moved as select pg_temp.cells(pg_temp.c(4), 'cells.confirm_request', pg_temp.rev(6),
  jsonb_build_object('request_id', (pg_temp.req(6)).request_id), '00000000-0000-4000-a000-000000002601') as r;
select is((select r #>> '{data,primary,cell_id}' from moved), pg_temp.y()::text,
  'the leader of Y confirms the change: Y is the primary cell');
select is((select count(*)::int from app.cells_memberships where member_id = pg_temp.mid(6) and ended_at is null), 1,
  'exactly one current primary membership');
select is((select end_reason || ':' || ended_by_request::text from app.cells_memberships
            where member_id = pg_temp.mid(6) and cell_id = pg_temp.x()),
  'transferred:' || (select r #>> '{data,open_request,request_id}' from chg), 'the old membership ended as transferred (history kept)');
select is(pg_temp.private(pg_temp.fresh(6), pg_temp.x()), 'PT403|forbidden|not_granted',
  'the old cell''s private surface is denied at once');
select is(pg_temp.private(pg_temp.fresh(6), pg_temp.y()), 'ok',
  'the new cell''s private surface opens');
select is((select string_agg(event || ':' || identity_revision::text || ':' || (xact_id = pg_current_xact_id())::text, ',')
             from app.fixture_lifecycle_calls where member_id = pg_temp.mid(6)),
  'cell_transferred:' || pg_temp.rev(6)::text || ':true',
  'the registered transfer hook ran once, in the confirming transaction, with the member''s new revision');
select is((select row(im.revision, im.membership_state, im.updated_at)::text from app.identity_members im
            where im.member_id = pg_temp.mid(6)), (select member_row from before_transfer),
  'church membership is unchanged by the transfer');
select ok((select gs.revision from app.identity_grant_sets gs where gs.member_id = pg_temp.mid(6))
            = (select grants_rev from before_transfer)
          and (select row(l.link_id, l.link_state, l.sessions_valid_after, l.binding_revision)::text
                 from app.identity_account_links l where l.member_id = pg_temp.mid(6) and l.link_state <> 'ended')
            = (select link_row from before_transfer),
  'grants and the account link are unchanged by the transfer');
select is(pg_temp.cells(pg_temp.c(4), 'cells.confirm_request', (select (r ->> 'revision')::bigint from moved) - 1,
  jsonb_build_object('request_id', (select (r #>> '{data,open_request,request_id}')::uuid from chg)), '00000000-0000-4000-a000-000000002601') -> 'data' -> 'primary' ->> 'cell_id',
  pg_temp.y()::text, 'resending the same request replays the stored result');
select is((select count(*)::int from app.fixture_lifecycle_calls where member_id = pg_temp.mid(6)), 1,
  'a replay runs no hook again');
select is((select string_agg(action || ':' || actor_capacity || ':' || coalesce(from_cell_id::text, '-'), ',' order by event_id)
             from app.cells_membership_audit where member_id = pg_temp.mid(6) and action like 'membership%'),
  'membership_started:cell_leader:-,membership_transferred:cell_leader:' || pg_temp.x()::text,
  'the start and the transfer are audited with the deciding capacity');

-- Decline (leader refers, Admin declines), cancel and separation of duty ---------------------------
select is(pg_temp.cells(pg_temp.c(1), 'cells.request_change', pg_temp.rev(7),
  jsonb_build_object('member_id', pg_temp.mid(7), 'cell_id', pg_temp.x(),
                     'cell_revision', app.cells_option_revision(pg_temp.x()))) #>> '{data,open_request,origin}',
  'admin', 'an Admin requests a cell for a member (for example one without a login)');
select is(pg_temp.cells(pg_temp.c(3), 'cells.decline_request', pg_temp.rev(7),
  jsonb_build_object('request_id', (pg_temp.req(7)).request_id, 'reason', 'free text')) -> 'field_errors',
  '{"reason": "invalid"}'::jsonb, 'decline reasons are codes');
select is(pg_temp.cells(pg_temp.c(3), 'cells.decline_request', pg_temp.rev(7),
  jsonb_build_object('request_id', (pg_temp.req(7)).request_id, 'reason', 'not_known_to_leader')) #>> '{data,open_request,state}',
  'referred', 'the leader''s decline refers the request to the Admin follow-up queue');
select is(pg_temp.cells(pg_temp.c(3), 'cells.confirm_request', pg_temp.rev(7),
  jsonb_build_object('request_id', (pg_temp.req(7)).request_id)) ->> 'code', 'forbidden',
  'a referred request is no longer the leader''s to confirm');
select is((select e ->> 'follow_up' from jsonb_array_elements(pg_temp.readj(pg_temp.c(1), 'select api.cells_admin_overview()') -> 'requests') e
            where e ->> 'member_id' = pg_temp.mid(7)::text), 'true', 'it is in the Admin follow-up queue');
select is(pg_temp.cells(pg_temp.c(1), 'cells.decline_request', pg_temp.rev(7),
  jsonb_build_object('request_id', (pg_temp.req(7)).request_id, 'reason', 'no_cell_for_now')) #>> '{data,last_decision,state}',
  'declined', 'an Admin''s decline is final');
select is(pg_temp.cells(pg_temp.c(8), 'cells.request_change', pg_temp.rev(8),
  jsonb_build_object('cell_id', pg_temp.x(), 'cell_revision', app.cells_option_revision(pg_temp.x()))) #>> '{data,open_request,kind}',
  'join', 'a member without a cell asks to join one');
select is(pg_temp.cells(pg_temp.c(7), 'cells.cancel_request', pg_temp.rev(8),
  jsonb_build_object('request_id', (pg_temp.req(8)).request_id)) ->> 'code', 'forbidden',
  'another member cannot cancel it');
select is(pg_temp.cells(pg_temp.c(8), 'cells.cancel_request', pg_temp.rev(8),
  jsonb_build_object('request_id', (pg_temp.req(8)).request_id)) #>> '{data,last_decision,state}',
  'cancelled', 'the member cancels their own request');
select is(pg_temp.cells(pg_temp.c(3), 'cells.request_change', pg_temp.rev(3),
  jsonb_build_object('cell_id', pg_temp.x(), 'cell_revision', app.cells_option_revision(pg_temp.x()))) #>> '{data,open_request,kind}',
  'join', 'a leader asks to join their own cell');
select is(pg_temp.cells(pg_temp.c(3), 'cells.confirm_request', pg_temp.rev(3),
  jsonb_build_object('request_id', (pg_temp.req(3)).request_id)) -> 'field_errors',
  '{"member_id": "unsupported"}'::jsonb, 'nobody confirms their own cell membership');
select is(pg_temp.cells(pg_temp.c(1), 'cells.confirm_request', pg_temp.rev(3),
  jsonb_build_object('request_id', (pg_temp.req(3)).request_id)) #>> '{data,primary,cell_id}',
  pg_temp.x()::text, 'another person (an Admin) confirms it');
select is(pg_temp.cells(pg_temp.c(1), 'cells.confirm_request', pg_temp.rev(3),
  jsonb_build_object('request_id', (pg_temp.req(3)).request_id)) ->> 'code', 'conflict',
  'a decided request cannot be decided again');

-- Scope revocation is immediate --------------------------------------------------------------------
select is(pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.revoke_scope',
  (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(5)),
  jsonb_build_object('member_id', pg_temp.mid(5), 'scope_kind', 'cell_assistant', 'scope_id', pg_temp.x()))
  #> '{data,scopes}', '[]'::jsonb, 'an Admin removes the assistant');
select is(pg_temp.private(pg_temp.c(5), pg_temp.x()), 'PT403|forbidden|not_granted',
  'the former assistant loses the cell''s private access on the next call');

-- Reads for members and denials ---------------------------------------------------------------------
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(21)), 'select api.cells_my_cell()'),
  'PT401|unauthenticated|untrusted_session', 'an OTP session cannot read cells');
select is(pg_temp.readj(pg_temp.c(7), 'select api.cells_my_cell()') #>> '{last_decision,reason}', 'no_cell_for_now',
  'the member sees the decision as a code');
select is(pg_temp.readj(pg_temp.c(7), 'select api.cells_my_cell()') -> 'primary', 'null'::jsonb,
  'a declined member has no primary cell');

-- Audit content -----------------------------------------------------------------------------------
select is((select count(*)::int from app.cells_membership_audit a
            where a::text like '%SYNTHETIC%' or a::text like '%2025550%'), 0,
  'the audit carries no names, labels or numbers');
select is((select count(*)::int from app.cells_membership_audit a
            where a.actor_kind = 'member' and a.command_request_id is null), 0,
  'every member action is attributed to its command request');
select is((select count(*)::int from app.cells_membership_audit a
            where a.action = 'request_opened' and a.actor_kind = 'system'), 2,
  'application requests are opened by the system (from the approved applications)');

select * from finish();
rollback;
