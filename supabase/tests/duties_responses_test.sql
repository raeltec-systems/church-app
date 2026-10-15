-- Respond from My duties with later decline and bulk acceptance (story 4.5; AD-2, AD-6):
-- duties.withdraw_acceptance ("Can't make it anymore"), duties.accept_many (all or nothing),
-- cell-owned assignments (refused until story 4.11, answered since), the My duties keys (owner kind, earlier
-- acceptance, leader names), the leader projections, receipts, audit, jobs and the history
-- guard. HTTP evidence (including the concurrent race): tools/identity-e2e/duties-responses.mjs.
-- Every account, phone and name is SYNTHETIC (fictional range +44 7700 900550-900559).
begin;
select plan(74);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000045' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000045' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+447700900' || (550 + n)::text $$;
create function pg_temp.c(n int) returns jsonb language sql as $$
  select jsonb_build_object(
    'sub', pg_temp.u(n), 'role', 'authenticated', 'aal', 'aal1', 'session_id', pg_temp.s(n),
    'is_anonymous', false,
    'amr', jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', 1790000000)))
$$;
create function pg_temp.session(p_user uuid, p_session uuid) returns uuid language sql as $$
  insert into auth.sessions (id, user_id, aal, created_at)
  values (p_session, p_user, 'aal1', clock_timestamp() - interval '1 hour');
  insert into auth.mfa_amr_claims (id, session_id, created_at, updated_at, authentication_method)
  values (gen_random_uuid(), p_session, now(), now(), 'password');
  select p_session;
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
create function pg_temp.duties(n int, p_command text, p_expected bigint, p_payload jsonb,
                               p_request uuid default gen_random_uuid())
returns jsonb language sql as $$
  select pg_temp.cmd(pg_temp.c(n), 'api.duties_command', p_command, p_expected, p_payload, p_request)
$$;
create function pg_temp.read(n int, p_sql text) returns text
language plpgsql as $$
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
create function pg_temp.sunday(k int) returns date language sql as $$
  select ((now() at time zone 'Africa/Lusaka')::date + 4)
         + ((7 - extract(dow from (now() at time zone 'Africa/Lusaka')::date + 4)::int) % 7) + 7 * k
$$;
create function pg_temp.lt(k int, t text) returns timestamptz language sql as
$$ select (pg_temp.sunday(k) + t::time) at time zone 'Africa/Lusaka' $$;
create function pg_temp.utc(k int, t text) returns text language sql as
$$ select app.cmd_utc(pg_temp.lt(k, t)) $$;

-- Accounts: 1 Admin; 2 leader of D; 3 deputy of D; 4 member M (in D); 5 member O (in D);
-- 6 leader of the SYNTHETIC cell C.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 6) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 6) n;
select app.platform_set_environment('local', 'pgtap 4.5');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 4.5 Member ' || n, 'pgtap 4.5')
  from generate_series(1, 6) n;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');

create temp table dd as select pg_temp.duties(1, 'duties.create_department', null,
  '{"name": "SYNTHETIC Preaching Rota"}') as r;
create function pg_temp.d() returns uuid language sql as $$ select (r #>> '{data,department_id}')::uuid from dd $$;
create temp table cc as
  with ins as (insert into app.cells_cells (name, broad_area, is_synthetic, created_by)
               values ('SYNTHETIC 4.5 Cell', 'SYNTHETIC area', true, 'pgtap 4.5') returning cell_id)
  select cell_id from ins;
create function pg_temp.grant_scope(p_member int, p_kind text, p_scope uuid) returns jsonb
language sql as $$
  select pg_temp.cmd(pg_temp.c(1), 'api.identity_grant_command', 'identity.grant_scope',
    (select s.revision from app.identity_grant_sets s where s.member_id = pg_temp.mid(p_member)),
    jsonb_build_object('member_id', pg_temp.mid(p_member), 'scope_kind', p_kind, 'scope_id', p_scope))
$$;
select pg_temp.grant_scope(2, 'department_leader', pg_temp.d());
select pg_temp.grant_scope(3, 'department_deputy', pg_temp.d());
select pg_temp.grant_scope(6, 'cell_leader', (select cell_id from cc));
create function pg_temp.add(n int) returns jsonb language sql as $$
  select pg_temp.duties(1, 'duties.add_member',
    (select revision from app.duties_departments where department_id = pg_temp.d()),
    jsonb_build_object('department_id', pg_temp.d(), 'member_id', pg_temp.mid(n)))
$$;
select pg_temp.add(4);
select pg_temp.add(5);

-- A one-off duty of D for member p_member on Sunday k, 10:00-11:00 church time; its assignment id.
create temp table pubs (k int, member int, r jsonb);
create function pg_temp.pub(p_member int, k int) returns uuid language plpgsql as $$
declare
  r jsonb;
begin
  r := pg_temp.duties(2, 'duties.publish_duty', null, jsonb_build_object(
         'department_id', pg_temp.d(), 'member_id', pg_temp.mid(p_member), 'duty_name', 'Sunday duty ' || k,
         'location', 'SYNTHETIC hall', 'instructions', 'SYNTHETIC private instructions',
         'starts_at', pg_temp.utc(k, '10:00'), 'ends_at', pg_temp.utc(k, '11:00'),
         'response_deadline', app.cmd_utc(pg_temp.lt(k, '10:00') - interval '1 day')));
  insert into pubs values (k, p_member, r);
  return (r #>> '{data,assignment_id}')::uuid;
end;
$$;
create function pg_temp.a(p_member int, k int) returns uuid language sql as
$$ select (r #>> '{data,assignment_id}')::uuid from pubs where member = p_member and pubs.k = $2 $$;
create function pg_temp.occ(p_member int, k int) returns uuid language sql as
$$ select (r #>> '{data,occurrence_id}')::uuid from pubs where member = p_member and pubs.k = $2 $$;
create function pg_temp.row(p_id uuid) returns app.duties_assignments language sql as
$$ select a.* from app.duties_assignments a where a.assignment_id = p_id $$;
create function pg_temp.rev(p_id uuid) returns bigint language sql as
$$ select revision from app.duties_assignments where assignment_id = p_id $$;
create function pg_temp.answer(n int, p_id uuid, p_response text) returns jsonb language sql as $$
  select pg_temp.duties(n, 'duties.respond', pg_temp.rev(p_id),
                        jsonb_build_object('assignment_id', p_id, 'response', p_response))
$$;
create function pg_temp.withdraw(n int, p_id uuid, p_expected bigint default null,
                                 p_extra jsonb default '{}', p_request uuid default gen_random_uuid())
returns jsonb language sql as $$
  select pg_temp.duties(n, 'duties.withdraw_acceptance', coalesce(p_expected, pg_temp.rev(p_id)),
                        jsonb_build_object('assignment_id', p_id) || p_extra, p_request)
$$;
create function pg_temp.items(p_ids uuid[]) returns jsonb language sql as $$
  select jsonb_build_object('assignments', coalesce(jsonb_agg(jsonb_build_object(
           'assignment_id', i, 'revision', pg_temp.rev(i)) order by o), '[]'::jsonb))
    from unnest(p_ids) with ordinality as t(i, o)
$$;
create function pg_temp.many(n int, p_ids uuid[], p_request uuid default gen_random_uuid())
returns jsonb language sql as $$
  select pg_temp.duties(n, 'duties.accept_many', null, pg_temp.items(p_ids), p_request)
$$;
create function pg_temp.jobs(p_id uuid) returns text language sql as $$
  select coalesce(string_agg(job_state, ',' order by enqueued_at), '')
    from app.notifications_jobs where source_type = 'duties_assignment' and source_id = p_id
      -- Story 4.8's reminders are checked in duties_reminders_test.sql.
      and reminder_kind not in ('duty_response_due', 'duty_starting')
$$;

select pg_temp.pub(4, k) from generate_series(0, 9) k;
select pg_temp.pub(5, 0);

-- Later decline ("Can't make it anymore") ---------------------------------------------------------
select is(pg_temp.answer(4, pg_temp.a(4, 0), 'accepted') #>> '{data,response}', 'accepted', 'M accepts duty 0');
create temp table accepted_at as select responded_at as t from app.duties_assignments where assignment_id = pg_temp.a(4, 0);
select is((select (r ->> 'code') || '|' || (r ->> 'current_revision')
             from (select pg_temp.withdraw(4, pg_temp.a(4, 0), 1) as r) x),
  'conflict|2', 'a withdrawal at an old revision is refused with the current revision');
select is(pg_temp.withdraw(5, pg_temp.a(4, 0), 2) ->> 'code', 'not_found', 'someone else cannot withdraw it');
select is(pg_temp.withdraw(4, pg_temp.a(4, 0), null, '{"response": "declined"}') #>> '{code}', 'validation_failed',
  'an unknown key is refused');
select is(pg_temp.withdraw(4, pg_temp.a(4, 0), null, jsonb_build_object('note', repeat('x', 281)))
            #>> '{field_errors,note}', 'invalid', 'a note over 280 characters is refused');
create temp table wd_req as select gen_random_uuid() as id;
create temp table wd as select pg_temp.withdraw(4, pg_temp.a(4, 0), null,
  '{"note": "SYNTHETIC: travelling that weekend."}', (select id from wd_req)) as r;
select is((select (r #>> '{data,response}') || '|' || (r #>> '{data,withdrawn}') || '|' || (r ->> 'revision') from wd),
  'declined|true|3', 'M withdraws the acceptance: declined, at the next revision');
select is((select string_agg(k, ',' order by k) from wd, jsonb_object_keys(r -> 'data') k),
  'assignment_id,response,revision,withdrawn', 'the answer holds ids and states only');
select is((select (x.response || '|' || (x.prior_accepted_at = (select t from accepted_at))::text || '|'
                   || (x.responded_at >= x.prior_accepted_at)::text || '|' || x.response_provenance || '|'
                   || x.response_note || '|' || (x.responded_by_member = pg_temp.mid(4))::text)
             from pg_temp.row(pg_temp.a(4, 0)) x),
  'declined|true|true|member|SYNTHETIC: travelling that weekend.|true',
  'the earlier acceptance time is kept; the withdrawal is the response now, with its note');
select is(pg_temp.jobs(pg_temp.a(4, 0)), 'cancelled', 'the duty''s pending job was cancelled');
select is((select count(*)::int from app.duties_audit where action = 'acceptance_withdrawn' and code = 'declined'
             and assignment_id = pg_temp.a(4, 0) and actor_member_id = pg_temp.mid(4)), 1,
  'the withdrawal is audited (content-free)');
select is((select count(*)::int from app.cmd_receipts where result::text like '%travelling%')
          + (select count(*)::int from app.duties_audit a where a::text like '%travelling%'), 0,
  'the note stays out of receipts and audit');
select is(pg_temp.withdraw(4, pg_temp.a(4, 0), 2, '{"note": "SYNTHETIC: travelling that weekend."}',
                           (select id from wd_req)),
  (select r from wd), 'replaying the same request returns the stored result');
select is((select count(*)::int from app.duties_audit where action = 'acceptance_withdrawn'), 1, 'and records nothing new');
select is((select (r ->> 'code') || '|' || (r #>> '{field_errors,assignment_id}')
             from (select pg_temp.withdraw(4, pg_temp.a(4, 0)) as r) x),
  'conflict|responded', 'a declined duty cannot be withdrawn again');
select is((select (r ->> 'code') || '|' || (r #>> '{field_errors,assignment_id}')
             from (select pg_temp.withdraw(4, pg_temp.a(4, 1)) as r) x),
  'conflict|not_accepted', 'a pending duty is answered with Accept or Can''t make it, not withdrawn');
select is((select (r ->> 'code') || '|' || (r #>> '{field_errors,assignment_id}')
             from (select pg_temp.answer(4, pg_temp.a(4, 0), 'accepted') as r) x),
  'conflict|responded', 'duties.respond still refuses a second answer');
-- Only the member's own acceptance can be withdrawn (fail closed for answers recorded another way:
-- story 4.9 adds Confirmed by leader, provenance `leader`, staged here directly).
create temp table state_def as
  select pg_catalog.pg_get_functiondef('app.duties_state_ok(text, text)'::regprocedure) as d;
select ok((select d from state_def) like '%p_value in (''member'', ''leader'')%',
  'the provenance vocabulary is member and (story 4.9) leader');
select is(pg_temp.answer(4, pg_temp.a(4, 8), 'accepted') #>> '{data,response}', 'accepted', 'M accepts duty 8');
update app.duties_assignments set response_provenance = 'leader', confirmed_channel = 'phone' where assignment_id = pg_temp.a(4, 8);
select is((select (r ->> 'code') || '|' || (r #>> '{field_errors,assignment_id}')
             from (select pg_temp.withdraw(4, pg_temp.a(4, 8)) as r) x),
  'conflict|responded', 'an acceptance not recorded by the member cannot be withdrawn here');
select is((pg_temp.row(pg_temp.a(4, 8))).response, 'accepted', 'and nothing changed');
update app.duties_assignments set response_provenance = 'member', confirmed_channel = null where assignment_id = pg_temp.a(4, 8);

-- The leader sees it at once, the member sees their earlier acceptance --------------------------
create temp table board as select jsonb_path_query_first(pg_temp.readj(2, 'select api.duties_leader_board()'),
  '$.departments[0].duties[*] ? (@.occurrence_id == $o)', jsonb_build_object('o', pg_temp.occ(4, 0))) as j;
select is((select (j #>> '{positions,0,assignment,response}') || '|'
                  || ((j #>> '{positions,0,assignment,prior_accepted_at}') is not null)::text || '|'
                  || (j #>> '{positions,0,assignment,note}') from board),
  'declined|true|SYNTHETIC: travelling that weekend.', 'the leader board shows the later decline with its note');
select is((select (x ->> 'confirmed') || '|' || (x #>> '{positions,0,assignment,response}') || '|'
                  || ((x #>> '{positions,0,assignment,prior_accepted_at}') is not null)::text
             from (select app.duties_rota_occurrence_json(pg_temp.occ(4, 0), '{}'::jsonb) as x) y),
  '0|declined|true', 'the rota projection shows it too and confirmed drops to 0');
create temp table mine as select pg_temp.readj(4, 'select api.duties_my_duties()') as j;
create function pg_temp.my(p_id uuid) returns jsonb language sql as $$
  select x from mine, jsonb_array_elements(j -> 'assignments') x where x ->> 'assignment_id' = p_id::text
$$;
select is((select (x ->> 'owner_kind') || '|' || (x ->> 'response') || '|' || ((x ->> 'prior_accepted_at') is not null)::text
             from (select pg_temp.my(pg_temp.a(4, 0)) as x) y),
  'department|declined|true', 'My duties shows the owner kind and the earlier acceptance');
select is((select pg_temp.my(pg_temp.a(4, 0)) -> 'leaders'),
  '[{"role": "leader", "display_name": "SYNTHETIC 4.5 Member 2"}, {"role": "deputy", "display_name": "SYNTHETIC 4.5 Member 3"}]'::jsonb,
  'and the department''s leader and deputy names, leader first, with no contact details');
select is((select pg_temp.my(pg_temp.a(4, 1)) ->> 'prior_accepted_at'), null, 'a never-accepted duty has none');
select is((select pg_temp.my(pg_temp.a(4, 0)) ->> 'slot_id'), (pg_temp.row(pg_temp.a(4, 0))).slot_id::text,
  'My duties carries the slot id (a calendar entry''s stable id across revisions)');

-- Started, superseded, cancelled ------------------------------------------------------------------
select is(pg_temp.answer(4, pg_temp.a(4, 2), 'accepted') #>> '{data,response}', 'accepted', 'M accepts duty 2');
update app.duties_occurrences set starts_at = now() - interval '1 hour', ends_at = now() + interval '1 hour',
                                  reporting_at = null
 where occurrence_id = pg_temp.occ(4, 2);
select is((select (r ->> 'code') || '|' || (r #>> '{field_errors,assignment_id}')
             from (select pg_temp.withdraw(4, pg_temp.a(4, 2)) as r) x),
  'validation_failed|started', 'a duty that has started cannot be withdrawn here');
select is(pg_temp.answer(4, pg_temp.a(4, 3), 'accepted') #>> '{data,response}', 'accepted', 'M accepts duty 3');
create temp table old3 as select pg_temp.a(4, 3) as id, pg_temp.rev(pg_temp.a(4, 3)) as rev;
select is(pg_temp.duties(2, 'duties.revise_duty',
            (select revision from app.duties_occurrences where occurrence_id = pg_temp.occ(4, 3)),
            jsonb_build_object('occurrence_id', pg_temp.occ(4, 3), 'starts_at', pg_temp.utc(3, '09:00'),
                               'response_deadline', app.cmd_utc(pg_temp.lt(3, '09:00') - interval '1 day')))
            #>> '{data,change}', 'material', 'the leader moves duty 3 (a new pending revision)');
select is((select (r ->> 'code') || '|' || (r #>> '{field_errors,assignment_id}') || '|' || (r #>> '{field_errors,starts_at}')
             from (select pg_temp.withdraw(4, (select id from old3), (select rev from old3)) as r) x),
  'conflict|superseded|changed', 'withdrawing the old revision is refused with what changed');
select is(pg_temp.answer(4, pg_temp.a(4, 9), 'accepted') #>> '{data,response}', 'accepted', 'M accepts duty 9');
update app.duties_assignments set assignment_state = 'cancelled', ended_at = now(), end_reason = 'cancelled'
 where assignment_id = pg_temp.a(4, 9);
select is((select (r ->> 'code') || '|' || (r #>> '{field_errors,assignment_id}')
             from (select pg_temp.withdraw(4, pg_temp.a(4, 9), 2) as r) x),
  'conflict|cancelled', 'a cancelled duty cannot be withdrawn');

-- Bulk acceptance --------------------------------------------------------------------------------
create temp table bulk_req as select gen_random_uuid() as id;
create temp table bulk as select pg_temp.many(4, array[pg_temp.a(4, 6), pg_temp.a(4, 4), pg_temp.a(4, 5)],
  (select id from bulk_req)) as r;
select is((select (r #>> '{data,response}') || '|' || (r #>> '{data,count}') || '|'
                  || jsonb_array_length(r #> '{data,assignments}') from bulk),
  'accepted|3|3', 'M accepts three of the four listed dates together');
select is((select r #>> '{data,assignments,0,assignment_id}' from bulk), pg_temp.a(4, 4)::text,
  'the answer lists them in date order (the first is the receipt''s aggregate)');
select is((select string_agg(response, ',' order by k) from (
             select k, (pg_temp.row(pg_temp.a(4, k))).response from generate_series(4, 7) k) x),
  'accepted,accepted,accepted,pending', 'exactly the three selected are accepted; the fourth still waits');
select is((select count(distinct command_request_id)::int || '|' || count(*)
             from app.duties_audit where action = 'response_recorded' and code = 'accepted'
              and assignment_id in (pg_temp.a(4, 4), pg_temp.a(4, 5), pg_temp.a(4, 6))),
  '1|3', 'each is audited under the one request');
select is(pg_temp.jobs(pg_temp.a(4, 4)) || '/' || pg_temp.jobs(pg_temp.a(4, 7)), 'cancelled/pending',
  'their pending jobs are cancelled; the unselected one keeps its job');
select is(pg_temp.duties(4, 'duties.accept_many', null,
            (select r -> 'data' from bulk) - 'response' - 'count', (select id from bulk_req))
            ->> 'code', 'conflict', 'a different body under the same request id is not replayed');
select is(pg_temp.duties(4, 'duties.accept_many', null, jsonb_build_object('assignments', jsonb_build_array(
            jsonb_build_object('assignment_id', pg_temp.a(4, 6), 'revision', 1),
            jsonb_build_object('assignment_id', pg_temp.a(4, 4), 'revision', 1),
            jsonb_build_object('assignment_id', pg_temp.a(4, 5), 'revision', 1))), (select id from bulk_req)),
  (select r from bulk), 'replaying the same request (a timeout retried) returns the stored result');
select is((select count(*)::int from app.duties_audit where action = 'response_recorded' and code = 'accepted'
             and assignment_id in (pg_temp.a(4, 4), pg_temp.a(4, 5), pg_temp.a(4, 6))), 3, 'and records nothing new');

-- All or nothing
create temp table mixed as select pg_temp.many(4, array[pg_temp.a(4, 7), pg_temp.a(4, 4)]) as r;
select is((select (r ->> 'code') || '|' || (r #>> '{field_errors,assignments}') || '|'
                  || (r -> 'field_errors' ->> ('assignment:' || pg_temp.a(4, 4))) from mixed),
  'conflict|changed|responded', 'an already answered date refuses the whole selection, naming it');
select is((pg_temp.row(pg_temp.a(4, 7))).response, 'pending', 'and nothing was accepted');
select is((select r -> 'field_errors' ? ('assignment:' || pg_temp.a(4, 7)) from mixed), false,
  'the date that could be accepted is not named');
select is(pg_temp.duties(4, 'duties.accept_many', null, jsonb_build_object('assignments', jsonb_build_array(
            jsonb_build_object('assignment_id', pg_temp.a(4, 7), 'revision', 9))))
            -> 'field_errors' ->> ('assignment:' || pg_temp.a(4, 7)), 'stale',
  'a date at another revision is refused as stale');
select is(pg_temp.many(4, array[pg_temp.a(4, 7), (select id from old3)])
            -> 'field_errors' ->> ('assignment:' || (select id from old3)), 'superseded',
  'a superseded date is named');
select is(pg_temp.many(4, array[pg_temp.a(4, 7), pg_temp.a(4, 9)])
            -> 'field_errors' ->> ('assignment:' || pg_temp.a(4, 9)), 'cancelled', 'a cancelled date is named');
select pg_temp.pub(4, 10);
update app.duties_occurrences set starts_at = now() - interval '1 hour', ends_at = now() + interval '1 hour'
 where occurrence_id = pg_temp.occ(4, 10);
select is(pg_temp.many(4, array[pg_temp.a(4, 7), pg_temp.a(4, 10)])
            -> 'field_errors' ->> ('assignment:' || pg_temp.a(4, 10)), 'started', 'a started date is named');
select is(pg_temp.many(4, array[pg_temp.a(4, 7), pg_temp.a(5, 0)]) ->> 'code', 'not_found',
  'someone else''s duty in the selection: not found, nothing disclosed');
select is(pg_temp.duties(4, 'duties.accept_many', null, jsonb_build_object('assignments', jsonb_build_array(
            jsonb_build_object('assignment_id', pg_temp.a(4, 7), 'revision', pg_temp.rev(pg_temp.a(4, 7))),
            jsonb_build_object('assignment_id', gen_random_uuid(), 'revision', 1)))) ->> 'code', 'not_found',
  'an unknown id: not found');
select is((pg_temp.row(pg_temp.a(4, 7))).response || '|' || (pg_temp.row(pg_temp.a(5, 0))).response,
  'pending|pending', 'nothing was accepted by the refused selections');

-- Validation
select is(pg_temp.duties(4, 'duties.accept_many', null, '{"assignments": []}') #>> '{field_errors,assignments}',
  'required', 'an empty selection is refused');
select is(pg_temp.duties(4, 'duties.accept_many', null, jsonb_build_object('assignments',
            (select jsonb_agg(jsonb_build_object('assignment_id', gen_random_uuid(), 'revision', 1))
               from generate_series(1, 51))))
            #>> '{field_errors,assignments}', 'too_many', 'more than 50 dates are refused');
select is(pg_temp.duties(4, 'duties.accept_many', null, jsonb_build_object('assignments', jsonb_build_array(
            jsonb_build_object('assignment_id', pg_temp.a(4, 7), 'revision', 1),
            jsonb_build_object('assignment_id', pg_temp.a(4, 7), 'revision', 1))))
            #>> '{field_errors,assignments}', 'duplicate', 'a date listed twice is refused');
select is(pg_temp.duties(4, 'duties.accept_many', null, jsonb_build_object('assignments', jsonb_build_array(
            jsonb_build_object('assignment_id', pg_temp.a(4, 7), 'revision', 1.5))))
            #>> '{field_errors,assignments}', 'invalid', 'a non-integer revision is refused');
select is(pg_temp.duties(4, 'duties.accept_many', null, jsonb_build_object('assignments', jsonb_build_array(
            jsonb_build_object('assignment_id', pg_temp.a(4, 7), 'revision', 1, 'note', 'x'))))
            #>> '{field_errors,assignments}', 'invalid', 'an item with an unknown key is refused');
select is(pg_temp.duties(4, 'duties.accept_many', null, jsonb_build_object('assignments', jsonb_build_array('x')))
            #>> '{field_errors,assignments}', 'invalid', 'an item that is not an object is refused');
select is(pg_temp.duties(4, 'duties.accept_many', 1, pg_temp.items(array[pg_temp.a(4, 7)]))
            #>> '{field_errors,expected_revision}', 'must_be_null', 'expected_revision must be null');

-- A later decline after a bulk acceptance; the leader sees both at once
select is(pg_temp.withdraw(4, pg_temp.a(4, 5)) #>> '{data,response}', 'declined',
  'a date accepted in bulk can be withdrawn later');
create temp table board2 as select pg_temp.readj(2, 'select api.duties_leader_board()') as j;
select is((select string_agg((d #>> '{positions,0,assignment,response}')
                             || case when d #>> '{positions,0,assignment,prior_accepted_at}' is not null then '*' else '' end,
                             ',' order by d ->> 'starts_at')
             from board2, jsonb_array_elements(j #> '{departments,0,duties}') d
            where d ->> 'occurrence_id' in (pg_temp.occ(4, 4)::text, pg_temp.occ(4, 5)::text,
                                            pg_temp.occ(4, 6)::text, pg_temp.occ(4, 7)::text)),
  'accepted,declined*,accepted,pending', 'the leader board shows each answer at once');

-- Cell-owned assignments: unreachable until entry 11; since story 4.11 answered like any duty ----
create temp table cell_asg (id uuid);
do $$
declare
  v_occ uuid;
  v_slot uuid;
begin
  insert into app.duties_occurrences (cell_id, duty_name, starts_at, ends_at, created_by_member, created_by_account)
  values ((select cell_id from cc), 'SYNTHETIC cell part', pg_temp.lt(8, '18:00'), pg_temp.lt(8, '19:00'),
          pg_temp.mid(6), pg_temp.u(6))
  returning occurrence_id into v_occ;
  insert into app.duties_slots (occurrence_id, position_no, position_name) values (v_occ, 1, 'Prayer')
  returning slot_id into v_slot;
  with a as (
    insert into app.duties_assignments (slot_id, member_id, response_deadline, assigned_by_member, assigned_by_account)
    values (v_slot, pg_temp.mid(4), pg_temp.lt(8, '17:00'), pg_temp.mid(6), pg_temp.u(6))
    returning assignment_id)
  insert into cell_asg select assignment_id from a;
end;
$$;
select is(pg_temp.many(4, array[pg_temp.a(4, 7), (select id from cell_asg)]) #>> '{data,count}', '2',
  'story 4.11: duties.accept_many accepts a selection with a cell programme part');
select is((pg_temp.row((select id from cell_asg))).response || '|' || (pg_temp.row(pg_temp.a(4, 7))).response,
  'accepted|accepted', 'both are accepted by the member');
select is(pg_temp.answer(4, (select id from cell_asg), 'declined') -> 'field_errors',
  '{"assignment_id": "responded"}'::jsonb,
  'story 4.11: duties.respond reaches the cell part (already answered here)');
select is((select x ->> 'owner_kind' || '|' || coalesce(x ->> 'department_name', 'none')
             from jsonb_array_elements(pg_temp.readj(4, 'select api.duties_my_duties()') -> 'assignments') x
            where x ->> 'assignment_id' = (select id from cell_asg)::text),
  'cell|none', 'story 4.11: My duties lists it as a cell part (no department)');
select is((select x -> 'leaders'
             from jsonb_array_elements(pg_temp.readj(4, 'select api.duties_my_duties()') -> 'assignments') x
            where x ->> 'assignment_id' = (select id from cell_asg)::text),
  jsonb_build_array(jsonb_build_object('display_name', 'SYNTHETIC 4.5 Member 6', 'role', 'leader')),
  'with the cell''s leader by name');

-- Grants, history guard, vocabulary ---------------------------------------------------------------
select is((select count(*)::int from information_schema.routine_privileges
            where routine_schema = 'app' and grantee in ('anon', 'authenticated', 'PUBLIC', 'service_role')
              and routine_name in ('duties_withdraw_acceptance', 'duties_accept_many', 'duties_refuse_ended',
                                   'duties_assignment_occurrence')), 0,
  'the new functions are not executable by any client role');
select ok((select proconfig @> array['search_path=""'] from pg_proc
            where oid = 'app.duties_accept_many(uuid, bigint, jsonb)'::regprocedure)
       and (select proconfig @> array['search_path=""'] from pg_proc
             where oid = 'app.duties_withdraw_acceptance(uuid, bigint, jsonb)'::regprocedure),
  'the new commands set an empty search_path');
select throws_ok(format('update app.duties_assignments set prior_accepted_at = now() where assignment_id = %L',
                        (select id from old3)),
  'P0001', 'ended duties assignments are immutable', 'an ended assignment''s prior acceptance cannot change');
select throws_ok(format('update app.duties_assignments set prior_accepted_at = now() where assignment_id = %L',
                        pg_temp.a(4, 7)),
  '23514', null, 'only a declined answer may carry a prior acceptance');
select ok(app.duties_state_ok('audit_action', 'acceptance_withdrawn')
          and app.duties_state_ok('audit_action', 'overlap_override'),
  'the audit vocabulary gains acceptance_withdrawn and keeps the 4.4 actions');

-- Deletion: the hook still leaves nothing of the erased member ------------------------------------
select is((app.duties_erase_member(jsonb_build_object('member_id', pg_temp.mid(4), 'account_id', pg_temp.u(4),
                                                     'phase', 'check')) ->> 'remaining')::int > 0, true,
  'before erasure the member''s duties are counted');
select is((select count(*)::int from app.duties_assignments where prior_accepted_at is not null
             and member_id = pg_temp.mid(4)), 2, 'the two withdrawn acceptances are the member''s');
select is((select (r ->> 'remaining')::int from jsonb_array_elements(
             app.identity_call_deletion_hooks(pg_temp.mid(4), pg_temp.u(4), gen_random_uuid(), 'erase')) r
            where r ->> 'module' = 'duties'), 0, 'the erase phase leaves nothing of M in Duties, withdrawn duties included');
select is((select count(*)::int || '|' || count(*) filter (
                    where response_note is null
                      and member_id = '00000000-0000-0000-0000-000000000000'
                      and responded_by_member = '00000000-0000-0000-0000-000000000000')
             from app.duties_assignments
            where prior_accepted_at is not null),
  '2|2', 'each withdrawn duty stays as an anonymous fact: the note is cleared and the member is the nil UUID');

select * from finish();
rollback;
