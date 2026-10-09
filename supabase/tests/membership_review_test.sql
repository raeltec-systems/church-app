-- Review applications and link existing or accountless members (story 2.5; AD-2, AD-3, AD-4,
-- AD-19, AD-20). Admin decides applications, records accountless members, links an applicant's
-- account to a new or existing member, unlinks, and reclaims a phone username; every decision is
-- audited without content; nothing links automatically. HTTP evidence with real phone sign-up:
-- tools/identity-e2e/review.mjs. Every account, phone and name here is SYNTHETIC (fictional
-- range +1 202 555 0160-0179); +999 is an unassigned ITU code used only to prove the fence.
begin;
select plan(107);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000025' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000025' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+120255501' || (60 + n)::text $$;

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

-- A session row (created p_age ago; a negative age is a session opened after now()).
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
-- A fresh password session of account n, opened after every epoch so far (sign in again).
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
create function pg_temp.review(p_claims jsonb, p_command text, p_expected bigint, p_payload jsonb,
                               p_request uuid default gen_random_uuid())
returns jsonb language sql as $$
  select pg_temp.cmd(p_claims, 'api.identity_review_command', p_command, p_expected, p_payload,
                     p_request)
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

create function pg_temp.submit(n int, p_name text default null) returns jsonb language sql as $$
  select pg_temp.cmd(pg_temp.c(n), 'api.identity_application_command',
    'identity.submit_application', null,
    jsonb_build_object('full_name', coalesce(p_name, 'SYNTHETIC Applicant ' || n),
                       'cell_choice', '{"choice": "not_sure"}'::jsonb,
                       'privacy_notice_version', 'draft-2026-10-07'))
$$;
create function pg_temp.app_of(n int) returns app.identity_membership_applications
language sql as $$
  select a.* from app.identity_membership_applications a
   where a.auth_user_id = pg_temp.u(n) order by a.submitted_at desc limit 1
$$;
create function pg_temp.app_id(n int) returns uuid language sql as
$$ select (pg_temp.app_of(n)).application_id $$;
create function pg_temp.app_rev(n int) returns bigint language sql as
$$ select (pg_temp.app_of(n)).revision $$;

-- Fixtures. Accounts: 1 Admin A, 2 Admin B, 3-7 applicants, 8 a plain member, 9 the holder of a
-- phone username someone else claims (unlinked, with an open application), 10 a linked account
-- whose username is claimed, 11 an applicant whose Auth email is unverified, 12 an applicant who
-- shares the contact number recorded for an accountless member.
-- 13 an account once linked to a member who is on hold, 14 a holder whose phone Auth stores
-- WITH a leading '+'.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 13) n;
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
values (pg_temp.u(14), 'authenticated', 'authenticated', pg_temp.phone(14), now());
update auth.users set email = 'synthetic-2-5-unverified@example.test' where id = pg_temp.u(11);
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 14) n;
insert into auth.refresh_tokens (instance_id, token, user_id, revoked, session_id)
values ('00000000-0000-0000-0000-000000000000', 'synthetic-2-5-refresh-9', pg_temp.u(9)::text, false, pg_temp.s(9));
select pg_temp.session(pg_temp.u(1), pg_temp.s(21), 'otp');

-- Structure and privileges ---------------------------------------------------------------------
select ok((select count(*) from information_schema.tables where table_schema = 'app'
            and table_name in ('identity_member_provenance', 'identity_contact_routes',
                               'identity_phone_reclaims', 'identity_membership_audit')) = 4,
  'provenance, contact-route, reclaim and audit tables exist');
select ok(not exists (
  select 1 from unnest(array['app.identity_member_provenance', 'app.identity_contact_routes',
                             'app.identity_phone_reclaims', 'app.identity_membership_audit']) t
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, t, p))
  and not exists (
  select 1 from unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['USAGE', 'SELECT', 'UPDATE']) p
   where has_sequence_privilege(r, 'app.identity_membership_audit_event_id_seq', p)),
  'no client role has any privilege on the new tables or the audit sequence');
select is((select array_agg(column_name::text order by column_name::text)
             from information_schema.columns
            where table_schema = 'app' and table_name = 'identity_membership_audit'),
  array['action', 'actor_account_id', 'actor_member_id', 'application_id', 'environment',
        'event_id', 'identity_check', 'link_id', 'member_id', 'occurred_at', 'operator', 'reason_code',
        'reclaim_id', 'request_id', 'requested_fields', 'revision_after', 'target_account_id'],
  'the audit holds ids, codes, revisions and the operator name only (no member name, phone, email or free text)');
select ok(not has_function_privilege('anon', 'api.identity_review_command(jsonb)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.identity_admin_application_queue(timestamptz, uuid)', 'EXECUTE')
          and not has_function_privilege('anon', 'api.identity_admin_member_search(text, text, uuid)', 'EXECUTE'),
  'signed-out callers cannot execute the review command or the Admin reads');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');

-- Environment, Admins, a member, cells and applications -----------------------------------------
select app.platform_set_environment('local', 'pgtap 2.5');
select app.cells_seed_synthetic_cells('pgtap 2.5');
create temp table m as
select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 2.5 Seeded ' || n, 'pgtap 2.5') as member_id
  from (values (1), (2), (8), (10)) v(n);
select app.identity_bootstrap_admin((select member_id from m where n = 1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator)
values ((select member_id from m where n = 2), 'admin', 'israel');
select pg_temp.submit(n) from generate_series(3, 7) n;
select pg_temp.submit(9, 'SYNTHETIC Squatter Name');
select pg_temp.submit(11);
select pg_temp.submit(12, 'SYNTHETIC Ruth Mwale');
-- An application from Admin A's own account (an Admin is never an applicant through the API;
-- this row stands for one left open from before A was linked).
insert into app.identity_membership_applications (auth_user_id, phone_username, full_name, cell_choice,
                                                  privacy_notice_version, is_synthetic)
values (pg_temp.u(1), pg_temp.phone(1), 'SYNTHETIC 2.5 Seeded 1', 'not_sure', 'draft-2026-10-07', true);

-- Account 13: an ended link to a member who is on hold, and an open request left from before.
create temp table held13 as
with mem as (
  insert into app.identity_members (display_name, membership_state, is_synthetic)
  values ('SYNTHETIC 2.5 Held Earlier', 'approved', true) returning member_id)
select member_id from mem;
insert into app.identity_account_links (member_id, auth_user_id, link_state, approved_phone,
                                        approved_by, ended_at)
select member_id, pg_temp.u(13), 'ended', pg_temp.phone(13), 'pgtap 2.5', now() from held13;
insert into app.identity_holds (member_id, hold_kind, reason, placed_by)
select member_id, 'security', 'SYNTHETIC hold', 'pgtap 2.5' from held13;
insert into app.identity_membership_applications (auth_user_id, phone_username, full_name, cell_choice,
                                                  privacy_notice_version, is_synthetic)
values (pg_temp.u(13), pg_temp.phone(13), 'SYNTHETIC Applicant 13', 'not_sure', 'draft-2026-10-07', true);

-- Who may review --------------------------------------------------------------------------------
select is(pg_temp.read(pg_temp.c(3), 'select api.identity_admin_application_queue()'),
  'PT403|forbidden|not_linked', 'an applicant cannot read the review queue');
select is(pg_temp.read(pg_temp.c(8), 'select api.identity_admin_application_queue()'),
  'PT403|forbidden|not_granted', 'a member without Admin cannot read the review queue');
select is(pg_temp.read(pg_temp.claims(pg_temp.u(1), pg_temp.s(21)), 'select api.identity_admin_member_search()'),
  'PT401|unauthenticated|untrusted_session', 'an Admin''s OTP session cannot search members');
select is(pg_temp.review(pg_temp.c(3), 'identity.approve_application', pg_temp.app_rev(3),
  jsonb_build_object('application_id', pg_temp.app_id(3), 'identity_check', 'in_person')) ->> 'code',
  'forbidden', 'an applicant cannot approve (even their own request)');
select is(pg_temp.review(pg_temp.c(8), 'identity.create_member', null,
  '{"full_name": "SYNTHETIC X", "consent_basis": "in_person"}') ->> 'code',
  'forbidden', 'a member without Admin cannot create members');
select is(pg_temp.review(pg_temp.claims(pg_temp.u(1), pg_temp.s(21)), 'identity.reject_application',
  pg_temp.app_rev(3), jsonb_build_object('application_id', pg_temp.app_id(3))) ->> 'code',
  'unauthenticated', 'an Admin''s OTP session is unauthenticated for review commands');

-- Accountless member records ------------------------------------------------------------------
select is(pg_temp.review(pg_temp.c(1), 'identity.create_member', null,
  '{"full_name": "Ruth Mwale", "consent_basis": "in_person"}') -> 'field_errors',
  '{"full_name": "invalid"}'::jsonb, 'while Q4 is unapproved a member name must be SYNTHETIC');
select is(pg_temp.review(pg_temp.c(1), 'identity.create_member', null,
  jsonb_build_object('full_name', 'SYNTHETIC X', 'consent_basis', 'in_person',
    'assisted_by_member_id', (select member_id from m where n = 8),
    'contact_route', '{"phone": "+99900000251", "belongs_to": "relative", "extra": 1}'::jsonb)) -> 'field_errors',
  '{"assisted_by_member_id": "must_be_null", "contact_route.phone": "out_of_range", "contact_route.extra": "unknown_field", "contact_route.holder_label": "required"}'::jsonb,
  'every field error at once: assisting member only when leader-assisted, fictional contact phones, labelled relative numbers');
select is(pg_temp.review(pg_temp.c(1), 'identity.create_member', null, '{"full_name": "SYNTHETIC X"}') -> 'field_errors',
  '{"consent_basis": "required"}'::jsonb, 'the person''s consent basis is required');
create temp table accountless as
select pg_temp.review(pg_temp.c(1), 'identity.create_member', null,
  jsonb_build_object('full_name', 'SYNTHETIC  Ruth   Mwale', 'consent_basis', 'leader_assisted',
    'assisted_by_member_id', (select member_id from m where n = 8),
    'contact_route', jsonb_build_object('phone', pg_temp.phone(12), 'belongs_to', 'relative',
                                        'holder_label', 'Daughter''s phone'))) as r,
  '00000000-0000-4000-a000-000000002501'::uuid as req;
select is((select r #>> '{data,account}' from accountless) || '|' || (select r #>> '{data,origin}' from accountless)
          || '|' || (select r #>> '{data,display_name}' from accountless)
          || '|' || (select r #>> '{data,contact_routes,0,belongs_to}' from accountless)
          || '|' || (select r #>> '{data,contact_routes,0,holder_label}' from accountless),
  'no_login|admin_record|SYNTHETIC Ruth Mwale|relative|Daughter''s phone',
  'an accountless approved member is recorded with a labelled contact route (whose number it is)');
create temp table ruth as select (r #>> '{data,member_id}')::uuid as member_id from accountless;
select is((select consent_basis || ':' || (assisted_by_member = (select member_id from m where n = 8))::text
                  || ':' || (recorded_by_member = (select member_id from m where n = 1))::text
             from app.identity_member_provenance where member_id = (select member_id from ruth)),
  'leader_assisted:true:true', 'provenance records consent basis, assisting leader and the recording Admin');
select is((select action || ':' || reason_code || ':' || revision_after from app.identity_membership_audit
            where member_id = (select member_id from ruth)),
  'member_created:leader_assisted:1', 'creating a member is audited with codes only');
create temp table repl as
select pg_temp.review(pg_temp.c(1), 'identity.create_member', null,
  '{"full_name": "SYNTHETIC Replay Person", "consent_basis": "in_person"}',
  '00000000-0000-4000-a000-000000002502') as first;
select is(pg_temp.review(pg_temp.c(1), 'identity.create_member', null,
  '{"full_name": "SYNTHETIC Replay Person", "consent_basis": "in_person"}',
  '00000000-0000-4000-a000-000000002502') #>> '{data,member_id}',
  (select first #>> '{data,member_id}' from repl), 'a replayed create returns the stored member');
select is((select count(*)::int from app.identity_members where display_name = 'SYNTHETIC Replay Person'), 1,
  'a replay creates no second member');

-- A shared contact number and a matching name never link or grant -------------------------------
select is(pg_temp.read(pg_temp.c(12), 'select api.identity_my_member_summary()'),
  'PT403|forbidden|not_linked',
  'an applicant whose phone is a member''s contact route and whose name matches stays not_linked');
select ok(not exists (select 1 from app.identity_account_links where auth_user_id = pg_temp.u(12)),
  'no link was created from the matching phone or name');
create temp table q as select pg_temp.readj(pg_temp.c(1), 'select api.identity_admin_application_queue()') as j;
select is((select jsonb_array_length(j -> 'applications') from q), 10,
  'the Admin queue lists every open application');
select is((select c -> 'signals' from q, jsonb_array_elements(j -> 'applications') a,
                  jsonb_array_elements(a -> 'candidates') c
            where a ->> 'application_id' = pg_temp.app_id(12)::text
              and c ->> 'member_id' = (select member_id::text from ruth)),
  '["same_name", "contact_route_phone"]'::jsonb,
  'the queue shows Admin the accountless member as a duplicate candidate with its signals');
select is((select (c ->> 'link_eligible') || ':' || (c ->> 'account')
             from q, jsonb_array_elements(j -> 'applications') a, jsonb_array_elements(a -> 'candidates') c
            where a ->> 'application_id' = pg_temp.app_id(12)::text
              and c ->> 'member_id' = (select member_id::text from ruth)),
  'true:no_login', 'the candidate is accountless and may be linked');
select ok((select (a ->> 'own_account')::boolean from q, jsonb_array_elements(j -> 'applications') a
            where a ->> 'application_id' = (select application_id::text from app.identity_membership_applications
                                             where auth_user_id = pg_temp.u(1))),
  'the queue marks the Admin''s own application');
select ok(not (pg_temp.readj(pg_temp.c(12), 'select api.identity_my_application()') -> 'application' ?| array['candidates', 'member_id', 'prior_not_approved']),
  'the applicant''s own view carries no candidates, member ids or review data');

-- Approve as a new member ------------------------------------------------------------------------
select is(pg_temp.review(pg_temp.c(1), 'identity.approve_application', pg_temp.app_rev(3),
  jsonb_build_object('application_id', pg_temp.app_id(3))) -> 'field_errors',
  '{"identity_check": "required"}'::jsonb, 'approval needs a recorded identity check');
select is(pg_temp.review(pg_temp.c(1), 'identity.approve_application', pg_temp.app_rev(3) + 1,
  jsonb_build_object('application_id', pg_temp.app_id(3), 'identity_check', 'in_person')) - 'request_id' - 'message',
  jsonb_build_object('code', 'conflict', 'field_errors', '{}'::jsonb, 'current_revision', 1),
  'a stale revision is a conflict');
select is(pg_temp.review(pg_temp.c(1), 'identity.approve_application',
  (select revision from app.identity_membership_applications where auth_user_id = pg_temp.u(1)),
  jsonb_build_object('application_id', (select application_id from app.identity_membership_applications
                                         where auth_user_id = pg_temp.u(1)),
                     'identity_check', 'in_person')) - 'request_id' - 'message',
  '{"code": "forbidden", "field_errors": {"application_id": "unsupported"}}'::jsonb,
  'separation of duty: an Admin cannot approve an application from their own account');
create temp table appr as
select pg_temp.review(pg_temp.c(1), 'identity.approve_application', pg_temp.app_rev(3),
  jsonb_build_object('application_id', pg_temp.app_id(3), 'identity_check', 'established_relationship')) as r;
select is((select r #>> '{data,church_status}' from appr) || '|' || (select r ->> 'revision' from appr),
  'approved|2', 'approval answers the decided application');
select is((select m2.display_name || '|' || m2.membership_state || '|' || l.approved_phone || '|'
                  || l.link_state || '|' || (l.sessions_valid_after is not null)::text
             from app.identity_account_links l join app.identity_members m2 on m2.member_id = l.member_id
            where l.auth_user_id = pg_temp.u(3)),
  'SYNTHETIC Applicant 3|approved|' || pg_temp.phone(3) || '|active|true',
  'a new approved member is linked with the approved phone binding and a trust epoch');
select is((select h.binding_revision || ':' || h.reason from app.identity_binding_history h
             join app.identity_account_links l on l.link_id = h.link_id where l.auth_user_id = pg_temp.u(3)),
  '1:application_approved', 'the binding history records the approval');
select is((select origin || ':' || identity_check from app.identity_member_provenance p
             join app.identity_account_links l on l.member_id = p.member_id where l.auth_user_id = pg_temp.u(3)),
  'application:established_relationship', 'provenance records the application and the identity check');
select is(pg_temp.read(pg_temp.c(3), 'select api.identity_my_member_summary()'),
  'PT401|unauthenticated|untrusted_session', 'the session opened before approval does not pass');
create temp table f3 as select pg_temp.fresh(3) as c;
select is(pg_temp.readj((select c from f3), 'select api.identity_my_member_summary()') ->> 'member_id',
  (select r #>> '{data,member_id}' from appr), 'a fresh sign-in reaches the new member');
select is(pg_temp.readj((select c from f3), 'select api.identity_my_application()') #>> '{application,church_status}',
  'approved', 'the applicant reads their decided status');
select is((select action || ':' || identity_check || ':' || (member_id is not null)::text || ':'
                  || (actor_member_id = (select member_id from m where n = 1))::text
             from app.identity_membership_audit where application_id = pg_temp.app_id(3)),
  'application_approved:established_relationship:true:true', 'the approval is audited with codes and ids');
select is((select array_agg(event order by event_id) from app.identity_application_events
            where application_id = pg_temp.app_id(3)),
  array['submitted', 'approved'], 'the application history records the decision');
select is(pg_temp.review(pg_temp.c(1), 'identity.reject_application', pg_temp.app_rev(3),
  jsonb_build_object('application_id', pg_temp.app_id(3))) ->> 'code',
  'conflict', 'a decided application cannot be decided again');

select is(pg_temp.review(pg_temp.c(1), 'identity.approve_application', pg_temp.app_rev(13),
  jsonb_build_object('application_id', pg_temp.app_id(13), 'identity_check', 'in_person')) - 'request_id' - 'message',
  '{"code": "forbidden", "field_errors": {"application_id": "not_applicant"}}'::jsonb,
  'an account once linked to a member on hold is never approved (2.4 applicant rule)');
select ok(not exists (select 1 from app.identity_account_links where auth_user_id = pg_temp.u(13) and link_state <> 'ended'),
  'the refused approval created no link');

-- Link to an existing (accountless) member -------------------------------------------------------
select is(pg_temp.review(pg_temp.c(1), 'identity.link_application', pg_temp.app_rev(12),
  jsonb_build_object('application_id', pg_temp.app_id(12), 'member_id', (select member_id from m where n = 1),
                     'identity_check', 'in_person')) - 'request_id' - 'message',
  '{"code": "forbidden", "field_errors": {"member_id": "unsupported"}}'::jsonb,
  'separation of duty: an Admin cannot link an account to their own member');
select is(pg_temp.review(pg_temp.c(1), 'identity.link_application', pg_temp.app_rev(12),
  jsonb_build_object('application_id', pg_temp.app_id(12), 'member_id', (select member_id from m where n = 8),
                     'identity_check', 'in_person')) - 'request_id' - 'message',
  jsonb_build_object('code', 'conflict', 'current_revision', 1, 'field_errors', '{"member_id": "linked"}'::jsonb),
  'a member who already has a live link cannot get a second one');
select is(pg_temp.review(pg_temp.c(1), 'identity.link_application', pg_temp.app_rev(12),
  jsonb_build_object('application_id', pg_temp.app_id(12), 'member_id', gen_random_uuid(),
                     'identity_check', 'in_person')) -> 'field_errors',
  '{"member_id": "invalid"}'::jsonb, 'an unknown member cannot be linked');
create temp table held as
select (pg_temp.review(pg_temp.c(1), 'identity.create_member', null,
  '{"full_name": "SYNTHETIC Held Person", "consent_basis": "in_person"}') #>> '{data,member_id}')::uuid as member_id;
insert into app.identity_holds (member_id, hold_kind, reason, placed_by)
select member_id, 'security', 'SYNTHETIC hold', 'pgtap 2.5' from held;
select is(pg_temp.review(pg_temp.c(1), 'identity.link_application', pg_temp.app_rev(12),
  jsonb_build_object('application_id', pg_temp.app_id(12), 'member_id', (select member_id from held),
                     'identity_check', 'in_person')) -> 'field_errors',
  '{"member_id": "held"}'::jsonb, 'a held member cannot be linked');
create temp table granted as
select (pg_temp.review(pg_temp.c(1), 'identity.create_member', null,
  '{"full_name": "SYNTHETIC Granted Person", "consent_basis": "in_person"}') #>> '{data,member_id}')::uuid as member_id;
insert into app.identity_grants (member_id, role, granted_by_operator)
select member_id, 'media', 'israel' from granted;
select is(pg_temp.review(pg_temp.c(1), 'identity.link_application', pg_temp.app_rev(12),
  jsonb_build_object('application_id', pg_temp.app_id(12), 'member_id', (select member_id from granted),
                     'identity_check', 'in_person')) -> 'field_errors',
  '{"member_id": "has_grants"}'::jsonb, 'a member still holding a grant cannot be linked (grants never travel with a link)');
create temp table lnk as
select pg_temp.review(pg_temp.c(1), 'identity.link_application', pg_temp.app_rev(12),
  jsonb_build_object('application_id', pg_temp.app_id(12), 'member_id', (select member_id from ruth),
                     'identity_check', 'in_person')) as r;
select is((select r #>> '{data,member_id}' from lnk), (select member_id::text from ruth),
  'the application is approved onto the existing member');
select is((select display_name || '|' || membership_state || '|' || revision from app.identity_members
            where member_id = (select member_id from ruth)),
  'SYNTHETIC Ruth Mwale|approved|2', 'the member keeps its id, name and record (revision moves with the link)');
select is((select origin || ':' || consent_basis from app.identity_member_provenance
            where member_id = (select member_id from ruth))
          || '|' || (select count(*) from app.identity_contact_routes where member_id = (select member_id from ruth)),
  'admin_record:leader_assisted|1', 'provenance and contact routes are preserved');
select is(pg_temp.readj(pg_temp.fresh(12), 'select api.identity_my_member_summary()') ->> 'member_id',
  (select member_id::text from ruth), 'a fresh sign-in of the linked account reaches the same member id');
select is((select count(*)::int from app.identity_members where display_name ilike '%Ruth Mwale%'), 1,
  'no duplicate person was created');
select is((select action from app.identity_membership_audit where application_id = pg_temp.app_id(12)),
  'application_linked', 'the link is audited');

-- Binding checks at approval ---------------------------------------------------------------------
update auth.users set phone = '12025550179' where id = pg_temp.u(4);
select is(pg_temp.review(pg_temp.c(1), 'identity.approve_application', pg_temp.app_rev(4),
  jsonb_build_object('application_id', pg_temp.app_id(4), 'identity_check', 'in_person')) -> 'field_errors',
  '{"phone_username": "changed"}'::jsonb, 'an account whose phone changed after applying is not approved');
update auth.users set phone = ltrim(pg_temp.phone(4), '+') where id = pg_temp.u(4);
select is(pg_temp.review(pg_temp.c(1), 'identity.approve_application', pg_temp.app_rev(11),
  jsonb_build_object('application_id', pg_temp.app_id(11), 'identity_check', 'in_person')) -> 'field_errors',
  '{"recovery_email": "unverified"}'::jsonb, 'an unverified Auth email is never approved into the binding');
select ok(not exists (select 1 from app.identity_members where display_name in ('SYNTHETIC Applicant 4', 'SYNTHETIC Applicant 11')),
  'a refused approval creates nothing');

-- Ask for details, reject, re-apply --------------------------------------------------------------
select is(pg_temp.review(pg_temp.c(1), 'identity.request_application_details', pg_temp.app_rev(5),
  jsonb_build_object('application_id', pg_temp.app_id(5), 'requested', '["birthday"]'::jsonb)) -> 'field_errors',
  '{"requested": "invalid"}'::jsonb, 'only the listed detail codes can be requested');
select is(pg_temp.review(pg_temp.c(1), 'identity.request_application_details', pg_temp.app_rev(11),
  jsonb_build_object('application_id', pg_temp.app_id(11), 'requested', '["recovery_email"]'::jsonb)) #>> '{data,details_requested}',
  '["recovery_email"]', 'an unverified email is explained to the applicant with its own code');
select is(pg_temp.review(pg_temp.c(1), 'identity.request_application_details', pg_temp.app_rev(5),
  jsonb_build_object('application_id', pg_temp.app_id(5), 'requested', 'full_name')) -> 'field_errors',
  '{"requested": "invalid"}'::jsonb, 'requested must be a list');
select is(pg_temp.review(pg_temp.c(1), 'identity.request_application_details', pg_temp.app_rev(5),
  jsonb_build_object('application_id', pg_temp.app_id(5), 'requested', '["visit_church_office", "full_name"]'::jsonb)) #>> '{data,church_status}',
  'details_requested', 'Admin asks for details');
select is(pg_temp.readj(pg_temp.c(5), 'select api.identity_my_application()') -> 'application' -> 'details_requested',
  '["full_name", "visit_church_office"]'::jsonb, 'the applicant sees which details were requested');
select is(pg_temp.cmd(pg_temp.c(5), 'api.identity_application_command', 'identity.correct_application',
  pg_temp.app_rev(5), jsonb_build_object('application_id', pg_temp.app_id(5), 'full_name', 'SYNTHETIC Applicant Five'))
  #>> '{data,church_status}', 'awaiting_approval', 'the applicant''s correction returns it to review');
select ok((pg_temp.app_of(5)).details_requested is null
          and not (pg_temp.readj(pg_temp.c(5), 'select api.identity_my_application()') -> 'application' ? 'details_requested'),
  'answering the request clears it');
select is(pg_temp.review(pg_temp.c(1), 'identity.reject_application', pg_temp.app_rev(6),
  jsonb_build_object('application_id', pg_temp.app_id(6), 'reason', 'you are not welcome')) -> 'field_errors',
  '{"reason": "invalid"}'::jsonb, 'a rejection reason is a code, never free text');
select is(pg_temp.review(pg_temp.c(1), 'identity.reject_application', pg_temp.app_rev(6),
  jsonb_build_object('application_id', pg_temp.app_id(6), 'reason', 'identity_not_confirmed',
                     'identity_check', 'in_person')) #>> '{data,church_status}',
  'not_approved', 'Admin rejects with a reason code');
create temp table rej as select pg_temp.readj(pg_temp.c(6), 'select api.identity_my_application()') -> 'application' as a;
select is((select (a ->> 'decision_reason') || '|' || ((a ->> 'reapply_from')::timestamptz > now() + interval '6 days')::text from rej),
  'identity_not_confirmed|true', 'the applicant sees the reason code and when they may re-apply');
select is(pg_temp.submit(6) ->> 'code', 'rate_limited', 're-applying within 7 days of a rejection is refused');
update app.identity_membership_applications set decided_at = now() - interval '8 days',
       submitted_at = now() - interval '9 days'
 where auth_user_id = pg_temp.u(6) and application_state = 'rejected';
select is(pg_temp.submit(6) #>> '{data,church_status}', 'awaiting_approval',
  'after the cooldown the account may send a NEW request');
select is((select count(*)::int from app.identity_membership_applications where auth_user_id = pg_temp.u(6)), 2,
  'the rejected request is kept in history');
select is((select (a ->> 'prior_not_approved')::int
             from jsonb_array_elements(pg_temp.readj(pg_temp.c(1), 'select api.identity_admin_application_queue()') -> 'applications') a
            where a ->> 'application_id' = pg_temp.app_id(6)::text), 1,
  'the queue tells Admin about earlier requests that were not approved');
select is((select array_agg(action || ':' || coalesce(reason_code, '-') || ':' || coalesce(array_to_string(requested_fields, ','), '-') order by event_id)
             from app.identity_membership_audit where application_id in (pg_temp.app_id(5),
               (select application_id from app.identity_membership_applications where auth_user_id = pg_temp.u(6) and application_state = 'rejected'))),
  array['application_details_requested:-:full_name,visit_church_office', 'application_rejected:identity_not_confirmed:-'],
  'asking for details and rejecting are audited with codes only');

-- Unlink ----------------------------------------------------------------------------------------
create temp table m8 as select member_id, revision from app.identity_members where member_id = (select member_id from m where n = 8);
select is(pg_temp.review(pg_temp.c(1), 'identity.unlink_account', (select revision from m8),
  jsonb_build_object('member_id', (select member_id from m8))) -> 'field_errors',
  '{"reason": "required"}'::jsonb, 'unlinking needs a reason code');
select is(pg_temp.review(pg_temp.c(1), 'identity.unlink_account', (select revision from m8) + 5,
  jsonb_build_object('member_id', (select member_id from m8), 'reason', 'account_lost')) ->> 'code',
  'conflict', 'unlinking needs the member''s current revision');
select is(pg_temp.review(pg_temp.c(1), 'identity.unlink_account',
  (select revision from app.identity_members where member_id = (select member_id from m where n = 1)),
  jsonb_build_object('member_id', (select member_id from m where n = 1), 'reason', 'account_lost')) -> 'field_errors',
  '{"member_id": "unsupported"}'::jsonb, 'separation of duty: an Admin cannot unlink their own account');
insert into app.identity_grants (member_id, role, granted_by_operator)
values ((select member_id from m8), 'pastor', 'israel'), ((select member_id from m8), 'admin', 'israel');
create temp table unl as
select pg_temp.review(pg_temp.c(2), 'identity.unlink_account', (select revision from m8),
  jsonb_build_object('member_id', (select member_id from m8), 'reason', 'ownership_dispute')) as r;
select is((select r #>> '{data,account}' from unl), 'no_login', 'the member is now without a login');
select is(pg_temp.read(pg_temp.fresh(8), 'select api.identity_my_member_summary()'),
  'PT403|forbidden|not_linked', 'the unlinked account has no member access, even after signing in again');
select is((select display_name || '|' || membership_state from app.identity_members where member_id = (select member_id from m8))
          || '|' || (select count(*) from app.identity_grants where member_id = (select member_id from m8) and revoked_at is null),
  'SYNTHETIC 2.5 Seeded 8|approved|0', 'the member and its record are kept; its grants end with the link');
select is((select array_agg(a.action || ':' || a.role || ':' || (a.actor_member_id = (select member_id from m where n = 2))::text
                            || ':' || (a.request_id is not null)::text order by a.role)
             from app.identity_access_audit a where a.target_member_id = (select member_id from m8)),
  array['role_revoked:admin:true:true', 'role_revoked:pastor:true:true'],
  'each ended grant is audited through the 2.3 path with the acting Admin');
select ok(app.identity_member_link_eligible((select member_id from m8)),
  'after unlinking, the member can be linked again (with no grants)');
select is((select action || ':' || reason_code from app.identity_membership_audit where member_id = (select member_id from m8)),
  'account_unlinked:ownership_dispute', 'the unlink is audited');

-- Reclaim a phone username (F1) -------------------------------------------------------------------
select is(pg_temp.review(pg_temp.c(1), 'identity.reclaim_phone_username', null,
  '{"phone_username": "0971234"}') -> 'field_errors',
  '{"identity_check": "required", "phone_username": "invalid"}'::jsonb, 'reclaim needs an E.164 username and an identity check');
select is(pg_temp.review(pg_temp.c(1), 'identity.reclaim_phone_username', null,
  '{"phone_username": "+99900000251", "identity_check": "in_person"}') -> 'field_errors',
  '{"phone_username": "out_of_range"}'::jsonb, 'while Q4 is unapproved only fictional numbers can be reclaimed');
-- The personal-data gate, closed for this one check (restored below; the test rolls back).
create or replace function app.identity_applications_open() returns boolean
language sql stable set search_path = '' as $$ select false $$;
select is(pg_temp.review(pg_temp.c(1), 'identity.reclaim_phone_username', null,
  jsonb_build_object('phone_username', pg_temp.phone(9), 'identity_check', 'in_person')) - 'request_id' - 'message',
  '{"code": "unavailable", "field_errors": {"policy": "gate_closed"}}'::jsonb,
  'reclaim is behind the personal-data gate');
create or replace function app.identity_applications_open() returns boolean
language sql stable set search_path = '' as $$
  select not app.rcv_serving_hold()
     and (app.policy_is_open('q4_personal_data')
          or app.platform_current_environment() in ('local', 'staging'));
$$;
select is(pg_temp.review(pg_temp.c(1), 'identity.reclaim_phone_username', null,
  '{"phone_username": "+12025550178", "identity_check": "in_person"}') ->> 'code',
  'not_found', 'a username no account holds cannot be reclaimed');
select is(pg_temp.review(pg_temp.c(1), 'identity.reclaim_phone_username', null,
  jsonb_build_object('phone_username', pg_temp.phone(1), 'identity_check', 'in_person')) -> 'field_errors',
  '{"phone_username": "unsupported"}'::jsonb, 'an Admin cannot reclaim their own username');
select is(pg_temp.review(pg_temp.c(1), 'identity.reclaim_phone_username', null,
  jsonb_build_object('phone_username', pg_temp.phone(10), 'identity_check', 'in_person')) - 'request_id' - 'message',
  '{"code": "conflict", "field_errors": {"phone_username": "linked"}}'::jsonb,
  'a username held by a linked account is never taken silently: unlink explicitly first');
create temp table rc as
select pg_temp.review(pg_temp.c(1), 'identity.reclaim_phone_username', null,
  jsonb_build_object('phone_username', pg_temp.phone(9), 'identity_check', 'in_person',
                     'reason', 'registered_by_someone_else')) as r;
select is((select r #>> '{data,released}' from rc) || '|' || (select r #>> '{data,application_withdrawn}' from rc),
  'true|true', 'the username is released and the holder''s open request withdrawn');
select is((select coalesce(phone, '-') || '|' || (banned_until > now() + interval '50 years')::text from auth.users where id = pg_temp.u(9)),
  '-|true', 'the holder keeps its Auth row but loses the phone and is banned');
select is(pg_temp.read(pg_temp.c(9), 'select api.identity_my_application()'),
  'PT401|unauthenticated|untrusted_session', 'the holder''s old session no longer works');
select is((select count(*)::int from auth.sessions where user_id = pg_temp.u(9))
          + (select count(*)::int from auth.refresh_tokens where user_id = pg_temp.u(9)::text), 0,
  'the holder''s Auth sessions and refresh tokens are revoked');
select is((pg_temp.app_of(9)).application_state, 'withdrawn', 'the holder''s request is withdrawn, not deleted');
select lives_ok($$insert into auth.users (id, aud, role, phone, phone_confirmed_at)
                  values ('00000000-0000-4000-8000-000000002599', 'authenticated', 'authenticated', '12025550169', now())$$,
  'the reclaimed username can be registered by the person it belongs to');
select is((select action || ':' || identity_check || ':' || reason_code from app.identity_membership_audit
            where action = 'phone_username_reclaimed'),
  'phone_username_reclaimed:in_person:registered_by_someone_else', 'the reclaim is audited without the number');
select is((select count(*)::int from app.identity_phone_reclaims where released_account_id = pg_temp.u(9)), 1,
  'the reclaim case is recorded');

-- A phone stored WITH '+', and the restricted-operator undo
create temp table rc14 as
select pg_temp.review(pg_temp.c(1), 'identity.reclaim_phone_username', null,
  jsonb_build_object('phone_username', pg_temp.phone(14), 'identity_check', 'established_relationship')) as r;
select is((select r #>> '{data,released}' from rc14) || '|' || (select coalesce(phone, '-') from auth.users where id = pg_temp.u(14)),
  'true|-', 'a phone username Auth stores with a leading + is matched and released');
select throws_ok(format('select app.identity_undo_phone_reclaim(%L, %L)', (select r #>> '{data,reclaim_id}' from rc14), 'nobody'),
  '42501', null, 'only a restricted operator can undo a reclaim');
select lives_ok(format('select app.identity_undo_phone_reclaim(%L, %L)', (select r #>> '{data,reclaim_id}' from rc14), 'israel'),
  'the operator undoes the reclaim while the number is free');
select is((select phone || '|' || (banned_until is null)::text from auth.users where id = pg_temp.u(14)),
  '12025550174|true', 'the account gets its phone username back and is unbanned');
select is((select action || ':' || operator || ':' || (actor_member_id is null)::text from app.identity_membership_audit
            where action = 'phone_reclaim_undone'),
  'phone_reclaim_undone:israel:true', 'the undo is audited with the operator');
select throws_ok(format('select app.identity_undo_phone_reclaim(%L, %L)', (select r #>> '{data,reclaim_id}' from rc14), 'israel'),
  '22023', 'the reclaim was already undone', 'a reclaim is undone once');
select throws_ok(format('select app.identity_undo_phone_reclaim(%L, %L)',
                        (select reclaim_id from app.identity_phone_reclaims where released_account_id = pg_temp.u(9)), 'israel'),
  '22023', 'the phone username is in use again; it cannot be given back',
  'an undo never takes the number from the person who registered it since');

-- Member search -----------------------------------------------------------------------------------
create temp table srch as select pg_temp.readj(pg_temp.c(1), 'select api.identity_admin_member_search(''ruth'')') as j;
select is((select jsonb_array_length(j -> 'members') from srch), 1, 'Admin finds the member by name');
select is((select j #>> '{members,0,account}' from srch) || '|' || (select j #>> '{members,0,link_eligible}' from srch),
  'app_account|false', 'the search shows the account state and that the member is linked now');
select is(jsonb_array_length(pg_temp.readj(pg_temp.c(1), 'select api.identity_admin_member_search(''%'')') -> 'members'), 0,
  'search patterns are literal (no wildcard injection)');

-- Nothing about candidates or reviews leaks to applicants -------------------------------------------
select is(pg_temp.read(pg_temp.c(7), 'select api.identity_admin_member_search(''ruth'')'),
  'PT403|forbidden|not_linked', 'an applicant cannot search members');
select ok((select bool_and(not (j ? 'candidates')) from (
            select pg_temp.readj(pg_temp.c(n), 'select api.identity_my_application()') -> 'application' as j
              from generate_series(4, 7) n) x),
  'no applicant view carries duplicate candidates');

select * from finish();
rollback;
