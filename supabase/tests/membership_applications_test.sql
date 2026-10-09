-- Membership applications with a safe cell choice (story 2.4; AD-2, AD-3, AD-4, AD-5).
-- An applicant (trusted password session, no approved member link) submits and corrects their
-- own application through the 1.4 envelope; the Cells sign-up projection exposes names and broad
-- areas only; applying grants nothing, so the applicant stays `not_linked` on every member
-- surface. HTTP evidence with real phone sign-up: tools/identity-e2e/apply.mjs. Every account,
-- phone and name here is SYNTHETIC (fictional range +1 202 555 0141-0149); +999 is an
-- unassigned ITU country code used only to prove the non-fictional fence.
begin;
select plan(97);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000024' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000024' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.req(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-a000-0000000024' || lpad(n::text, 2, '0'))::uuid $$;

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

create function pg_temp.session(p_user uuid, p_session uuid, p_method text default 'password')
returns uuid
language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at)
  values (p_session, p_user, 'aal1', clock_timestamp() - interval '1 hour');
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now(), now(), p_method);
  select p_session;
$$;

-- One application command envelope as the session in p_claims.
create function pg_temp.cmd(p_claims jsonb, p_command text, p_expected bigint, p_payload jsonb,
                            p_request uuid default gen_random_uuid(),
                            p_fn text default 'api.identity_application_command')
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

-- A read as the session in p_claims: 'ok' plus the result, or sqlstate|message|detail.
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

create function pg_temp.submit(n int, p_choice jsonb, p_name text default null,
                               p_request uuid default gen_random_uuid()) returns jsonb
language sql as $$
  select pg_temp.cmd(pg_temp.c(n), 'identity.submit_application', null,
    jsonb_build_object('full_name', coalesce(p_name, 'SYNTHETIC Applicant ' || n),
                       'cell_choice', p_choice, 'privacy_notice_version', 'draft-2026-10-07'),
    p_request)
$$;

create function pg_temp.cell(n int, p_rev int default 1) returns jsonb language sql as
$$ select jsonb_build_object('choice', 'cell',
            'cell_id', ('00000000-0000-4000-c000-00000000c24' || n)::uuid, 'cell_revision', p_rev) $$;

-- Fixtures: applicants 1-4 (fictional phones), 5 an approved member, 6 a held member,
-- 7 an account with no phone, 8 a non-fictional (+999, unassigned) phone.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', '120255501' || (40 + n)::text, now()
  from generate_series(1, 6) n;
insert into auth.users (id, aud, role, email, email_confirmed_at)
values (pg_temp.u(7), 'authenticated', 'authenticated', 'synthetic-2-4-nophone@example.test', now());
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
values (pg_temp.u(8), 'authenticated', 'authenticated', '99900000248', now());
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', '120255501' || (40 + n)::text, now()
  from generate_series(9, 12) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 12) n;
select pg_temp.session(pg_temp.u(1), pg_temp.s(21), 'otp');

-- Structure and privileges ---------------------------------------------------------------------
select has_table('app', 'identity_membership_applications', 'applications table exists');
select has_table('app', 'cells_signup_options', 'cells sign-up projection exists');
select ok(not exists (
  select 1 from unnest(array['app.identity_membership_applications', 'app.identity_application_events',
                             'app.cells_cells', 'app.cells_signup_options']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p))
  and not exists (
  select 1 from unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['USAGE', 'SELECT', 'UPDATE']) p
   where has_sequence_privilege(r, 'app.identity_application_events_event_id_seq', p)),
  'no client role has any privilege on application, event or cells tables or the event sequence');
select ok(not exists (
  select 1 from information_schema.columns
   where table_schema = 'app' and table_name = 'cells_signup_options'
     and column_name not in ('cell_id', 'label', 'broad_area', 'sort_order', 'listed',
                             'is_synthetic', 'revision', 'updated_at')),
  'the sign-up projection persists only label, broad area and listing metadata');
select is((select module from app.contract_source_types where source_type = 'cells_signup_option'),
  'cells', 'Cells registered the cells_signup_option source type (1.5 seam)');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_boundary_violations()), 0,
  'no boundary violations (Identity never reaches Cells directly)');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select ok(not has_function_privilege('anon', 'api.identity_application_command(jsonb)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.identity_my_application()', 'EXECUTE')
          and not has_function_privilege('anon', 'api.cells_signup_options()', 'EXECUTE'),
  'signed-out callers cannot execute the application command or reads');

-- Unmarked database = production behaviour --------------------------------------------------
select throws_ok($$select app.cells_seed_synthetic_cells('pgtap 2.4')$$, '22023', null,
  'the synthetic cell seed refuses an unmarked (production) database');
insert into app.cells_cells (cell_id, name, broad_area, is_synthetic, created_by)
values ('00000000-0000-4000-c000-00000000c241', 'SYNTHETIC Riverside Cell', 'SYNTHETIC North side', true, 'pgtap');
insert into app.cells_signup_options (cell_id, label, broad_area, is_synthetic)
values ('00000000-0000-4000-c000-00000000c241', 'SYNTHETIC Riverside', 'SYNTHETIC North side', true);
select is(pg_temp.readj(pg_temp.c(1), 'select api.cells_signup_options()'), '{"options": []}'::jsonb,
  'production: SYNTHETIC options are never listed');
select is(pg_temp.submit(1, '{"choice": "not_sure"}') - 'request_id' - 'message',
  '{"code": "unavailable", "field_errors": {"policy": "gate_closed"}}'::jsonb,
  'production with q4_personal_data closed: applications are unavailable');
select is(pg_temp.readj(pg_temp.c(1), 'select api.identity_my_application()') -> 'accepting_applications',
  'false'::jsonb, 'production: my_application says applications are not being accepted');

select app.platform_set_environment('local', 'pgtap 2.4');
select is(app.cells_seed_synthetic_cells('pgtap 2.4'), 3, 'local: three SYNTHETIC cells are seeded (idempotently)');
select app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 2.4 Member ' || n, 'pgtap 2.4')
  from generate_series(5, 6) n;
insert into app.identity_holds (member_id, hold_kind, reason, placed_by)
select l.member_id, 'security', 'SYNTHETIC hold', 'pgtap 2.4'
  from app.identity_account_links l where l.auth_user_id = pg_temp.u(6);
-- Accounts that are not applicants: linked to a pending (9), rejected (10) or deactivated (11)
-- member, or (12) an ended link whose member still has an open hold.
create temp table odd_members as
  with ins as (
    insert into app.identity_members (display_name, membership_state, is_synthetic)
    select 'SYNTHETIC 2.4 Odd ' || n, st, true
      from (values (9, 'pending'), (10, 'rejected'), (11, 'deactivated'), (12, 'approved')) v(n, st)
    returning member_id, display_name)
  select (regexp_match(display_name, '([0-9]+)$'))[1]::int as n, member_id from ins;
insert into app.identity_account_links (member_id, auth_user_id, link_state, approved_phone,
                                        approved_by, ended_at)
select o.member_id, pg_temp.u(o.n), case when o.n = 12 then 'ended' else 'active' end,
       '+120255501' || (40 + o.n)::text, 'pgtap 2.4', case when o.n = 12 then now() end
  from odd_members o;
insert into app.identity_holds (member_id, hold_kind, reason, placed_by)
select member_id, 'security', 'SYNTHETIC hold', 'pgtap 2.4' from odd_members where n = 12;
create temp table before_counts as
  select (select count(*) from app.identity_members) members,
         (select count(*) from app.identity_account_links) links,
         (select count(*) from app.identity_grants) grants;

-- The cell chooser -----------------------------------------------------------------------------
select is((select array_agg(distinct k order by k) from jsonb_array_elements(
            pg_temp.readj(pg_temp.c(1), 'select api.cells_signup_options()') -> 'options') o(v),
            jsonb_object_keys(o.v) k),
  array['broad_area', 'cell_id', 'label', 'revision'],
  'an applicant sees only cell_id, label, broad area and revision');
select is(jsonb_array_length(pg_temp.readj(pg_temp.c(1), 'select api.cells_signup_options()') -> 'options'),
  3, 'local: the three SYNTHETIC options are listed');
select is(pg_temp.readj(pg_temp.c(5), 'select api.cells_signup_options()') -> 'options',
  pg_temp.readj(pg_temp.c(1), 'select api.cells_signup_options()') -> 'options',
  'an approved member sees the same safe list');
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(21), 'otp'), 'select api.cells_signup_options()'),
  'PT401|unauthenticated|untrusted_session', 'an OTP session cannot read the chooser');
select is(pg_temp.read(pg_temp.c(6), 'select api.cells_signup_options()'),
  'PT403|forbidden|review_required', 'an account in access review cannot read the chooser');
select is(pg_temp.read('{}', 'select api.cells_signup_options()'),
  'PT401|unauthenticated|unauthenticated', 'no JWT subject: unauthenticated');

-- Submitting each choice -----------------------------------------------------------------------
create temp table r1 as select pg_temp.submit(1, pg_temp.cell(1), null, pg_temp.req(1)) as r;
select is((select r -> 'revision' from r1), '1'::jsonb, 'submit with a cell: revision 1');
select is((select (r -> 'data') - 'application_id' - 'submitted_at' - 'updated_at' from r1),
  jsonb_build_object('revision', 1, 'application_state', 'submitted', 'church_status', 'awaiting_approval',
    'full_name', 'SYNTHETIC Applicant 1', 'phone_username', '+12025550141',
    'cell_choice', pg_temp.cell(1), 'cell_status', 'requested',
    'privacy_notice_version', 'draft-2026-10-07', 'is_synthetic', true),
  'the answer shows church approval and the requested cell separately');
select is(pg_temp.submit(2, '{"choice": "not_sure"}') #>> '{data,cell_status}', 'follow_up',
  'I''m not sure: the cell waits for an Admin follow-up');
select is(pg_temp.submit(3, '{"choice": "not_in_cell"}') #>> '{data,cell_status}', 'follow_up',
  'I''m not in a cell yet: the cell waits for an Admin follow-up');
select is(pg_temp.submit(4, '{"choice": "not_sure"}', '  SYNTHETIC   Spaced   Name ') #>> '{data,full_name}',
  'SYNTHETIC Spaced Name', 'the name is trimmed and its whitespace collapsed');
select is((select array_agg(e.event || ':' || array_to_string(e.changed_fields, ',') order by e.event_id)
             from app.identity_application_events e join app.identity_membership_applications a using (application_id)
            where a.auth_user_id = pg_temp.u(1)),
  array['submitted:full_name,cell_choice,privacy_notice_version'],
  'the submission is recorded with field names only');
select is((select request_id from app.identity_application_events e join app.identity_membership_applications a using (application_id)
            where a.auth_user_id = pg_temp.u(1)), pg_temp.req(1),
  'the event is attributed to the command''s request');

-- Applying grants nothing ----------------------------------------------------------------------
select ok((select members = (select count(*) from app.identity_members)
              and links = (select count(*) from app.identity_account_links)
              and grants = (select count(*) from app.identity_grants) from before_counts),
  'applying creates no member, link or grant');
select is(pg_temp.read(pg_temp.c(1), 'select api.identity_my_member_summary()'),
  'PT403|forbidden|not_linked', 'the applicant cannot read a member summary');
select is(pg_temp.read(pg_temp.c(1), 'select api.identity_my_access()'),
  'PT403|forbidden|not_linked', 'the applicant has no access read (no roles or scopes)');
select is(pg_temp.read(pg_temp.c(1), 'select api.identity_admin_member_grants(null, null)'),
  'PT403|forbidden|not_linked', 'the applicant cannot read the member roster');
select is(pg_temp.read(pg_temp.c(1), $$select api.fixture_scoped_read('fixture_care', '00000000-0000-4000-b000-000000000001')$$),
  'PT403|forbidden|not_linked', 'the applicant cannot reach a scoped private surface');
select is(split_part(pg_temp.read(pg_temp.c(1), 'select to_jsonb(a) from app.identity_membership_applications a limit 1'), '|', 1),
  '42501', 'the applicant cannot select application rows directly');
select is(split_part(pg_temp.read(pg_temp.c(1), 'select to_jsonb(c) from app.cells_cells c limit 1'), '|', 1),
  '42501', 'the applicant cannot select cell records directly');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.grant_role', 1,
            jsonb_build_object('member_id', gen_random_uuid(), 'role', 'admin'),
            gen_random_uuid(), 'api.identity_grant_command') ->> 'code',
  'forbidden', 'the applicant cannot send a grant command');

-- Own application only -------------------------------------------------------------------------
select is(pg_temp.readj(pg_temp.c(1), 'select api.identity_my_application()') #>> '{application,application_id}',
  (select r #>> '{data,application_id}' from r1), 'the applicant reads their own application');
select isnt(pg_temp.readj(pg_temp.c(2), 'select api.identity_my_application()') #>> '{application,application_id}',
  (select r #>> '{data,application_id}' from r1), 'another applicant reads only theirs');
select is(pg_temp.readj(pg_temp.c(5), 'select api.identity_my_application()') -> 'application',
  'null'::jsonb, 'a member with no application reads none');
select is(pg_temp.readj(pg_temp.c(1), 'select api.identity_my_application()') -> 'privacy_notice',
  '{"version": "draft-2026-10-07", "draft": true}'::jsonb, 'the privacy notice is a labelled draft');
select is(pg_temp.read(pg_temp.c(6), 'select api.identity_my_application()'),
  'PT403|forbidden|review_required', 'access review shows no application data');

-- Who may apply --------------------------------------------------------------------------------
select is(pg_temp.submit(1, '{"choice": "not_sure"}') - 'request_id' - 'message',
  '{"code": "conflict", "field_errors": {}, "current_revision": 1}'::jsonb,
  'a second open application is a conflict with the current revision');
select is(pg_temp.submit(5, '{"choice": "not_sure"}') ->> 'code', 'forbidden', 'an approved member cannot apply');
select is(pg_temp.submit(6, '{"choice": "not_sure"}') ->> 'code', 'forbidden', 'an account in access review cannot apply');
select is(pg_temp.cmd(pg_temp.claims(pg_temp.u(1), pg_temp.s(21), 'otp'), 'identity.submit_application', null,
            '{"full_name": "x", "cell_choice": {"choice": "not_sure"}, "privacy_notice_version": "draft-2026-10-07"}')
          ->> 'code', 'unauthenticated', 'an OTP session cannot apply');
select is(pg_temp.submit(7, '{"choice": "not_sure"}') -> 'field_errors', '{"phone_username": "required"}'::jsonb,
  'an account without a phone username cannot apply');
select is(pg_temp.submit(8, '{"choice": "not_sure"}') -> 'field_errors', '{"phone_username": "out_of_range"}'::jsonb,
  'local/staging: a phone outside the fictional ranges is refused');

-- Validation -----------------------------------------------------------------------------------
select is(pg_temp.cmd(pg_temp.c(8), 'identity.submit_application', null,
            '{"full_name": "SYNTHETIC X", "cell_choice": {"choice": "not_sure"}, "privacy_notice_version": "draft-2026-10-07", "membership_state": "approved", "cell_status": "confirmed"}')
          -> 'field_errors',
  '{"membership_state": "unknown_field", "cell_status": "unknown_field"}'::jsonb,
  'an applicant cannot set membership or cell status');
select is(pg_temp.cmd(pg_temp.c(8), 'identity.submit_application', null,
            '{"full_name": "   ", "cell_choice": {"choice": "not_sure", "cell_id": "00000000-0000-4000-c000-00000000c241"}, "privacy_notice_version": "v0"}')
          -> 'field_errors',
  '{"full_name": "required", "cell_choice.cell_id": "must_be_null", "privacy_notice_version": "invalid"}'::jsonb,
  'every field error is reported at once');
select is(pg_temp.cmd(pg_temp.c(8), 'identity.submit_application', null,
            '{"full_name": "SYNTHETIC X", "cell_choice": {"choice": "maybe"}, "privacy_notice_version": "draft-2026-10-07"}')
          -> 'field_errors', '{"cell_choice.choice": "invalid"}'::jsonb, 'an unknown choice is invalid');
update app.cells_signup_options set listed = false where cell_id = '00000000-0000-4000-c000-00000000c243';
select is(pg_temp.submit(8, pg_temp.cell(3)) -> 'field_errors', '{"cell_choice.cell_id": "invalid"}'::jsonb,
  'an unlisted cell cannot be chosen');
update app.cells_signup_options set revision = 2 where cell_id = '00000000-0000-4000-c000-00000000c242';
select is(pg_temp.submit(8, pg_temp.cell(2, 1)) -> 'field_errors', '{"cell_choice.cell_id": "invalid"}'::jsonb,
  'a stale option revision cannot be chosen (reload the list)');
select is(pg_temp.submit(8, jsonb_build_object('choice', 'cell', 'cell_id', gen_random_uuid(), 'cell_revision', 1))
          -> 'field_errors', '{"cell_choice.cell_id": "invalid"}'::jsonb, 'an unknown cell id cannot be chosen');
select is(jsonb_array_length(pg_temp.readj(pg_temp.c(1), 'select api.cells_signup_options()') -> 'options'),
  2, 'the unlisted option leaves the chooser');

-- Correction -----------------------------------------------------------------------------------
create temp table app1 as select (r #>> '{data,application_id}')::uuid as id from r1;
create temp table c1 as select pg_temp.cmd(pg_temp.c(1), 'identity.correct_application', 1,
  jsonb_build_object('application_id', (select id from app1), 'full_name', 'SYNTHETIC Applicant One',
                     'cell_choice', '{"choice": "not_sure"}'::jsonb), pg_temp.req(2)) as r;
select is((select r -> 'revision' from c1), '2'::jsonb, 'a correction bumps the revision');
select is((select r #>> '{data,full_name}' || '/' || (r #>> '{data,cell_status}') from c1),
  'SYNTHETIC Applicant One/follow_up', 'the correction changes the name and the cell choice');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.correct_application', 1,
  jsonb_build_object('application_id', (select id from app1), 'full_name', 'SYNTHETIC Again')) - 'request_id' - 'message',
  '{"code": "conflict", "field_errors": {}, "current_revision": 2}'::jsonb,
  'a stale expected_revision is a conflict with the current revision');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.correct_application', 1,
  jsonb_build_object('application_id', (select id from app1), 'full_name', 'SYNTHETIC Applicant One',
                     'cell_choice', '{"choice": "not_sure"}'::jsonb), pg_temp.req(2)),
  (select r from c1), 'a replay of the same request returns the stored result');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.correct_application', 2,
  jsonb_build_object('application_id', (select id from app1), 'full_name', 'SYNTHETIC Changed'), pg_temp.req(2)) ->> 'code',
  'conflict', 'the same request id with a changed body is a conflict');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.correct_application', 2,
  jsonb_build_object('application_id', (select id from app1), 'application_state', 'approved')) -> 'field_errors',
  '{"application_state": "unknown_field", "payload": "required"}'::jsonb,
  'a correction cannot set the application state');
select is(pg_temp.cmd(pg_temp.c(2), 'identity.correct_application', 2,
  jsonb_build_object('application_id', (select id from app1), 'full_name', 'SYNTHETIC Takeover')) ->> 'code',
  'not_found', 'another applicant''s application is not found');
select is(pg_temp.cmd(pg_temp.c(1), 'identity.correct_application', null,
  jsonb_build_object('application_id', (select id from app1), 'full_name', 'SYNTHETIC X')) -> 'field_errors',
  '{"expected_revision": "required"}'::jsonb, 'a correction needs expected_revision');
select is((select array_agg(e.event || ':' || array_to_string(e.changed_fields, ',') order by e.event_id)
             from app.identity_application_events e where e.application_id = (select id from app1)),
  array['submitted:full_name,cell_choice,privacy_notice_version', 'corrected:full_name,cell_choice'],
  'history keeps one event per change, with field names only');
update app.identity_membership_applications set application_state = 'needs_details'
 where application_id = (select id from app1);
select is(pg_temp.cmd(pg_temp.c(1), 'identity.correct_application', 2,
  jsonb_build_object('application_id', (select id from app1), 'cell_choice', pg_temp.cell(1))) #>> '{data,church_status}',
  'awaiting_approval', 'answering a request for details returns the application to review');
update app.identity_membership_applications set application_state = 'approved', decided_at = now()
 where auth_user_id = pg_temp.u(3);
select is(pg_temp.cmd(pg_temp.c(3), 'identity.correct_application',
  (select revision from app.identity_membership_applications where auth_user_id = pg_temp.u(3)),
  jsonb_build_object('application_id', (select application_id from app.identity_membership_applications where auth_user_id = pg_temp.u(3)),
                     'full_name', 'SYNTHETIC Late')) ->> 'code',
  'conflict', 'a decided application can no longer be corrected');
select is(pg_temp.readj(pg_temp.c(3), 'select api.identity_my_application()') #>> '{application,church_status}',
  'approved', 'church status is reported from the application state');
select ok((select members = (select count(*) from app.identity_members)
              and links = (select count(*) from app.identity_account_links)
              and grants = (select count(*) from app.identity_grants) from before_counts),
  'corrections create no member, link or grant either');

-- Not applicants: linked to a pending/rejected/deactivated member, or a held member -----------
select is(pg_temp.submit(n, '{"choice": "not_sure"}') ->> 'code', 'forbidden',
  'an account linked to a ' || st || ' member cannot apply')
  from (values (9, 'pending'), (10, 'rejected'), (11, 'deactivated')) v(n, st);
select is(pg_temp.submit(12, '{"choice": "not_sure"}') ->> 'code', 'forbidden',
  'an account whose (ended-link) member has an open hold cannot apply');
select is(pg_temp.read(pg_temp.c(n), 'select api.cells_signup_options()'),
  'PT403|forbidden|not_applicant', 'account ' || n || ' (not an applicant) cannot read the chooser')
  from generate_series(9, 12) n;
select is(pg_temp.read(pg_temp.c(11), 'select api.identity_my_application()'),
  'PT403|forbidden|not_applicant', 'a deactivated member''s account reads no application');

-- Name normalisation ---------------------------------------------------------------------------
select is(pg_temp.cmd(pg_temp.c(4), 'identity.correct_application',
  (select revision from app.identity_membership_applications where auth_user_id = pg_temp.u(4)),
  jsonb_build_object('application_id', (select application_id from app.identity_membership_applications where auth_user_id = pg_temp.u(4)),
                     'full_name', E'\t SYNTHETIC\tTab\nNew Line 　\n')) #>> '{data,full_name}',
  'SYNTHETIC Tab New Line', 'tab, newline and NBSP edges are trimmed and runs collapsed');
select is(pg_temp.submit(8, '{"choice": "not_sure"}', E'SYNTHETIC ‮evil') -> 'field_errors',
  '{"full_name": "invalid"}'::jsonb,
  'a bidi override (U+202E) in the name is refused');
select is(pg_temp.submit(8, '{"choice": "not_sure"}', E'SYNTHETIC zero​width') -> 'field_errors',
  '{"full_name": "invalid"}'::jsonb, 'a zero-width format character is refused');
select is(pg_temp.submit(8, '{"choice": "not_sure"}', E'  \t\n') -> 'field_errors',
  '{"full_name": "required"}'::jsonb, 'a name of only whitespace is required, not a server error');
select is(pg_temp.submit(8, '{"choice": "not_sure"}', 'Real Looking Name') -> 'field_errors',
  '{"full_name": "invalid"}'::jsonb, 'local/staging: the name must start with SYNTHETIC');

-- Nested field errors use dotted paths -----------------------------------------------------
select is(pg_temp.submit(8, '{"choice": "not_sure", "leader": "x", "members": []}') -> 'field_errors',
  '{"cell_choice.leader": "unknown_field", "cell_choice.members": "unknown_field"}'::jsonb,
  'each unknown cell_choice key is reported on itself with its dotted path');
select is(pg_temp.submit(8, '{"choice": "cell"}') -> 'field_errors',
  '{"cell_choice.cell_id": "required", "cell_choice.cell_revision": "required"}'::jsonb,
  'a chosen cell needs cell_choice.cell_id and cell_choice.cell_revision');
select is(pg_temp.submit(8, '{}') -> 'field_errors',
  '{"cell_choice.choice": "required"}'::jsonb, 'a missing choice is cell_choice.choice');

-- Correction cap ---------------------------------------------------------------------------
insert into app.identity_application_events (application_id, revision, event, actor_auth_user_id, changed_fields)
select a.application_id, 1, 'corrected', a.auth_user_id, array['full_name']
  from app.identity_membership_applications a, generate_series(1, 10)
 where a.auth_user_id = pg_temp.u(2);
select is(pg_temp.cmd(pg_temp.c(2), 'identity.correct_application', 1,
  jsonb_build_object('application_id', (select application_id from app.identity_membership_applications where auth_user_id = pg_temp.u(2)),
                     'full_name', 'SYNTHETIC Eleventh')) ->> 'code',
  'rate_limited', 'the 11th correction within 24 hours is rate limited');
update app.identity_application_events e set at = now() - interval '25 hours'
  from app.identity_membership_applications a
 where e.application_id = a.application_id and a.auth_user_id = pg_temp.u(2) and e.event = 'corrected';
select is(pg_temp.cmd(pg_temp.c(2), 'identity.correct_application', 1,
  jsonb_build_object('application_id', (select application_id from app.identity_membership_applications where auth_user_id = pg_temp.u(2)),
                     'full_name', 'SYNTHETIC Eleventh')) ->> 'revision',
  '2', 'corrections older than 24 hours no longer count');
select is(app.identity_application_correction_limit(), 10, 'the correction limit is 10 per 24 hours');

-- Dispatch keeps the grant branch and refuses cross-wiring --------------------------------------
select is(pg_temp.cmd(pg_temp.c(4), 'identity.submit_application', null, '{}', gen_random_uuid(),
                      'api.identity_grant_command') -> 'field_errors',
  '{"command": "unsupported"}'::jsonb, 'the grant entry point does not run application commands');
select is(pg_temp.cmd(pg_temp.c(4), 'identity.grant_role', 1, '{}', gen_random_uuid(),
                      'api.identity_application_command') -> 'field_errors',
  '{"command": "unsupported"}'::jsonb, 'the application entry point does not run grant commands');
select is(app.identity_authorize_command('{"command": "identity.unknown"}'), false,
  'the dispatching authorizer still refuses unknown identity commands');

-- A held restore closes applications in local/staging too ---------------------------------------
select ok(app.identity_applications_open(), 'local, not held: applications are open');
update app.rcv_recovery_state set state = 'restored_held', restore_id = gen_random_uuid(),
       updated_by = 'pgtap 2.4';
select is(pg_temp.submit(8, '{"choice": "not_sure"}') - 'request_id' - 'message',
  '{"code": "unavailable", "field_errors": {"policy": "gate_closed"}}'::jsonb,
  'local + held restore: applications are unavailable');
update app.rcv_recovery_state set state = 'live', restore_id = null, updated_by = 'pgtap 2.4';
select ok(app.identity_applications_open(), 'live again: applications are open');

-- Production: the chooser is gated too, and a held restore stays closed even with Q4 approved.
select app.platform_set_environment('production', 'pgtap 2.4');
insert into app.cells_cells (cell_id, name, broad_area, is_synthetic, created_by)
values ('00000000-0000-4000-c000-00000000c249', 'Real Cell', 'Real area', false, 'pgtap');
insert into app.cells_signup_options (cell_id, label, broad_area, is_synthetic)
values ('00000000-0000-4000-c000-00000000c249', 'Real Cell', 'Real area', false);
select is(pg_temp.readj(pg_temp.c(1), 'select api.cells_signup_options()'), '{"options": []}'::jsonb,
  'production with q4 closed: even a non-synthetic cell is not listed');
select app.policy_approve('q4_personal_data', '{"note": "pgtap only"}', 'pgtap', 'pgtap 2.4 rolled back');
select ok(app.identity_applications_open(), 'production with q4 approved and live: open');
select is(jsonb_array_length(pg_temp.readj(pg_temp.c(1), 'select api.cells_signup_options()') -> 'options'), 1,
  'production with q4 approved: only the non-synthetic option is listed');
update app.rcv_recovery_state set state = 'restored_held', restore_id = gen_random_uuid(),
       updated_by = 'pgtap 2.4';
select ok(not app.identity_applications_open(), 'production held restore: applications closed even with q4 approved');
select is(pg_temp.readj(pg_temp.c(1), 'select api.cells_signup_options()'), '{"options": []}'::jsonb,
  'production held restore: nothing is listed');

select * from finish();
rollback;
