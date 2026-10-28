-- My duty history holds every kind of duty (owner decision 2026-10-21): the member reads their
-- department duties and cell programme parts together or by kind; a department leader reading the
-- member's history still sees only their department; a cell part has no completion outcome and is
-- left out of the outcome figures. Every account, phone and name here is SYNTHETIC (fictional range
-- +1 202 555 0193-0196).
begin;
select plan(20);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000061' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000061' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+120255501' || (92 + n)::text $$;
create function pg_temp.claims(p_sub uuid, p_session uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'sub', p_sub, 'role', 'authenticated', 'aal', 'aal1', 'session_id', p_session,
    'is_anonymous', false,
    'amr', jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', 1790000000)))
$$;
create function pg_temp.c(n int) returns jsonb language sql as
$$ select pg_temp.claims(pg_temp.u(n), pg_temp.s(n)) $$;
create function pg_temp.session(p_user uuid, p_session uuid) returns uuid language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at)
  values (p_session, p_user, 'aal1', clock_timestamp() - interval '1 hour');
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now(), now(), 'password');
  select p_session;
$$;
create function pg_temp.cmd(p_claims jsonb, p_fn text, p_command text, p_expected bigint,
                            p_payload jsonb, p_request uuid default gen_random_uuid())
returns jsonb language plpgsql as $$
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
create function pg_temp.read(n int, p_sql text) returns text language plpgsql as $$
declare
  r jsonb;
  v_state text; v_msg text; v_detail text;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
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
create function pg_temp.readj(n int, p_sql text) returns jsonb language sql as
$$ select substr(pg_temp.read(n, p_sql), 4)::jsonb $$;

-- Fixtures. 1 Admin, 2 the member, 3 leader of the department, 4 another member.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from (values (1), (2), (3), (4)) v(n);
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from (values (1), (2), (3), (4)) v(n);
select app.platform_set_environment('local', 'pgtap history kinds');
create temp table m as
select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC History Member ' || n,
                                           'pgtap history kinds') as member_id
  from (values (1), (2), (3), (4)) v(n);
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');

create temp table dd as select pg_temp.cmd(pg_temp.c(1), 'api.duties_command', 'duties.create_department',
  null, '{"name": "SYNTHETIC History Ushers"}') as r;
create function pg_temp.d() returns uuid language sql as $$ select (r #>> '{data,department_id}')::uuid from dd $$;
create temp table cc as select pg_temp.cmd(pg_temp.c(1), 'api.cells_command', 'cells.create_cell', null,
  '{"name": "SYNTHETIC History Cell", "signup_label": "SYNTHETIC History", "broad_area": "SYNTHETIC Kafue East"}') as r;
create function pg_temp.cell() returns uuid language sql as $$ select (r #>> '{data,cell_id}')::uuid from cc $$;
select pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.grant_scope',
  (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(3)),
  jsonb_build_object('member_id', pg_temp.mid(3), 'scope_kind', 'department_leader', 'scope_id', pg_temp.d()));
select pg_temp.cmd(pg_temp.c(1), 'api.duties_command', 'duties.add_member',
  (select revision from app.duties_departments where department_id = pg_temp.d()),
  jsonb_build_object('department_id', pg_temp.d(), 'member_id', pg_temp.mid(2)));

-- Four duties for member 2: a past and an upcoming one of each kind. The past department duty and
-- the past cell part were accepted; the upcoming ones wait for an answer.
create function pg_temp.duty(p_name text, p_department uuid, p_cell uuid, p_at timestamptz,
                             p_accepted boolean) returns uuid language plpgsql as $$
declare
  v_occ uuid;
  v_slot uuid;
  v_asg uuid;
begin
  insert into app.duties_occurrences (department_id, cell_id, duty_name, starts_at, ends_at,
                                      created_by_member, created_by_account)
  values (p_department, p_cell, p_name, p_at, p_at + interval '1 hour', pg_temp.mid(1), pg_temp.u(1))
  returning occurrence_id into v_occ;
  insert into app.duties_slots (occurrence_id) values (v_occ) returning slot_id into v_slot;
  insert into app.duties_assignments (slot_id, member_id, response_deadline, assigned_by_member,
                                      assigned_by_account, response, responded_at, response_provenance)
  values (v_slot, pg_temp.mid(2), p_at - interval '1 day', pg_temp.mid(1), pg_temp.u(1),
          case when p_accepted then 'accepted' else 'pending' end,
          case when p_accepted then p_at - interval '2 days' end,
          case when p_accepted then 'member' end)
  returning assignment_id into v_asg;
  return v_asg;
end;
$$;
create temp table a as select
  pg_temp.duty('SYNTHETIC Door', pg_temp.d(), null, now() - interval '10 days', true) as dep_past,
  pg_temp.duty('SYNTHETIC Door', pg_temp.d(), null, now() + interval '10 days', false) as dep_next,
  pg_temp.duty('SYNTHETIC Opening prayer', null, pg_temp.cell(), now() - interval '3 days', true) as cell_past,
  pg_temp.duty('SYNTHETIC Worship', null, pg_temp.cell(), now() + interval '4 days', false) as cell_next;

-- The member's own history: every kind -----------------------------------------------------------
create temp table own as select pg_temp.readj(2, 'select api.duties_member_history()') as j;
select is(jsonb_array_length((select j from own) -> 'entries'), 4,
  'the member reads all four duties: department duties and cell parts');
select is((select j -> 'kinds' from own), '{"department": 2, "cell": 2, "special": 0}'::jsonb,
  'kinds counts the positions of each kind (special assignments: duties_special_assignments_test.sql)');
select is((select e ->> 'owner_kind' from own, jsonb_array_elements(j -> 'entries') e
            where e ->> 'assignment_id' = (select cell_past from a)::text), 'cell',
  'a cell part is marked as a cell part');
select is((select e ->> 'cell_id' from own, jsonb_array_elements(j -> 'entries') e
            where e ->> 'assignment_id' = (select cell_past from a)::text), pg_temp.cell()::text,
  'a cell part carries its cell id (its name is the Cells module''s)');
select ok((select e -> 'department_id' = 'null'::jsonb and e -> 'department_name' = 'null'::jsonb
             from own, jsonb_array_elements(j -> 'entries') e
            where e ->> 'assignment_id' = (select cell_past from a)::text),
  'a cell part has no department');
select is((select e ->> 'department_name' from own, jsonb_array_elements(j -> 'entries') e
            where e ->> 'assignment_id' = (select dep_past from a)::text), 'SYNTHETIC History Ushers',
  'a department duty still names its department');
select is((select e ->> 'outcome_state' from own, jsonb_array_elements(j -> 'entries') e
            where e ->> 'assignment_id' = (select cell_past from a)::text), 'not_tracked',
  'a past cell part keeps no completion outcome');
select is((select e ->> 'outcome_state' from own, jsonb_array_elements(j -> 'entries') e
            where e ->> 'assignment_id' = (select dep_past from a)::text), 'unrecorded',
  'a past department duty with no outcome reads unrecorded');
select is((select e ->> 'outcome_state' from own, jsonb_array_elements(j -> 'entries') e
            where e ->> 'assignment_id' = (select cell_next from a)::text), 'upcoming',
  'an upcoming cell part reads upcoming');
select is((select j #>> '{summary,held}' from own), '2',
  'both past duties count as held');
select is((select j #>> '{summary,accepted}' from own), '2',
  'both past answers count as accepted');
select is((select j #>> '{summary,unrecorded}' from own), '1',
  'only the department duty counts as not recorded (a cell part never has an outcome)');
select is((select j ->> 'upcoming' from own), '2', 'two upcoming duties');

-- Filtered by kind ------------------------------------------------------------------------------
create temp table onlycell as select pg_temp.readj(2, 'select api.duties_member_history(kind => ''cell'')') as j;
select is((select array_agg(e ->> 'owner_kind') from onlycell, jsonb_array_elements(j -> 'entries') e),
  array['cell', 'cell'], 'kind cell lists the cell parts only');
select is((select j #>> '{summary,held}' || '/' || (j ->> 'upcoming') from onlycell), '1/1',
  'the summary and the upcoming count follow the filter');
select is((select j -> 'kinds' from onlycell), '{"department": 2, "cell": 2, "special": 0}'::jsonb,
  'kinds stays the reader''s whole view under a filter');
select is(pg_temp.read(2, 'select api.duties_member_history(kind => ''sideways'')'),
  'PT400|validation_failed|kind', 'an unknown kind is refused');

-- A department leader: the member's department duties only --------------------------------------
create temp table lead as select pg_temp.readj(3, format('select api.duties_member_history(%L::uuid)', pg_temp.mid(2))) as j;
select is((select array_agg(distinct e ->> 'owner_kind') from lead, jsonb_array_elements(j -> 'entries') e),
  array['department'], 'the department leader never sees the member''s cell parts');
select is((select j -> 'kinds' from lead), '{"department": 2, "cell": 0, "special": 0}'::jsonb,
  'kinds counts only what the leader may see');

-- Anyone else is refused as before ---------------------------------------------------------------
select is(pg_temp.read(4, format('select api.duties_member_history(%L::uuid)', pg_temp.mid(2))),
  'PT403|forbidden|not_granted', 'another member cannot read the history');

select * from finish();
rollback;
