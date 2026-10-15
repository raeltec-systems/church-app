-- Apply the owner's epic 4 decisions (story 4.16; owner-decisions-milestone-2.md items 7, 8 and 10,
-- and the Q1 G3 setting; AD-2, AD-7, AD-14, AD-19):
--   * item 7: a linked event change that flags department duties sends one `duty_review_flagged`
--     notice per department and change to each reachable leader and deputy (a held deputy, the
--     Admin role alone, Pastor, another department's leader and members get none); a second
--     change sends a fresh one; a cleared review is no longer actionable; with Q2 closed the flags
--     are kept, the notice is skipped and audited; a timing check over 60 linked duties;
--   * item 8: a vacated position carries a coarse reason (removed, no longer active, deleted) that
--     only the department's leaders and deputies read, on the board and in the coverage queue;
--     erasure keeps the category;
--   * item 10: revoking the scope of a department's last reachable leader or deputy is refused
--     `handover_required` (nothing changes) until another reachable one exists; the member's own
--     remaining grant counts; a revocation records the Follow-ups obligations it leaves (against
--     the grant) and the 4.12 pending list still lists them;
--   * G3: app.identity_approve_setting is refused for a non-operator and client roles, validates,
--     and an approved dormancy version is honoured by the live-access predicate while the labelled
--     fixture row stays.
-- HTTP evidence: tools/identity-e2e/duties-decisions.mjs.
-- Every account, phone and name is SYNTHETIC (fictional range +44 7700 900850-900859). Duty times
-- are fixed church-time (Africa/Lusaka) clock times on whole days, never the current clock time.
begin;
select plan(106);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000004160' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000004160' || lpad(n::text, 2, '0'))::uuid $$;
-- 1-10 -> 900850-900859.
create function pg_temp.phone(n int) returns text language sql as
$$ select '447700900' || (849 + n)::text $$;
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
create function pg_temp.call(n int, p_endpoint text, p_command text, p_expected bigint,
                             p_payload jsonb, p_request uuid default gen_random_uuid())
returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  execute format('select api.%I($1)', p_endpoint) into r using jsonb_build_object(
    'version', 1, 'command', p_command, 'request_id', p_request,
    'expected_revision', p_expected, 'payload', p_payload);
  reset role;
  return r;
end;
$$;
create function pg_temp.duties(n int, p_command text, p_expected bigint, p_payload jsonb)
returns jsonb language sql as $$
  select pg_temp.call(n, 'duties_command', p_command, p_expected, p_payload)
$$;
create function pg_temp.readj(n int, p_sql text) returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  execute p_sql into r;
  reset role;
  return r;
end;
$$;
create function pg_temp.fx(n int, p_fn text, p_input jsonb) returns jsonb
language plpgsql as $$
declare
  r jsonb;
  v_state text; v_msg text; v_detail text;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  begin
    execute format('select app.%I($1)', p_fn) into r using p_input;
    return r;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
    if v_state = 'PCMD1' then
      return jsonb_build_object('code', v_msg) || coalesce(v_detail::jsonb, '{}'::jsonb);
    end if;
    return jsonb_build_object('sqlstate', v_state, 'message', v_msg);
  end;
end;
$$;
create function pg_temp.err(r jsonb) returns text language sql as $$
  select coalesce(r ->> 'code', r ->> 'sqlstate', 'ok')
         || coalesce('|' || (select string_agg(k || '=' || v, ',' order by k)
                               from jsonb_each_text(r -> 'field_errors') f(k, v)), '')
$$;
create function pg_temp.run() returns jsonb language sql as
$$ select (app.notifications_sys_deliver_due(gen_random_uuid(), gen_random_uuid(), '{}') -> 'data') - 'actor' $$;
create function pg_temp.at(p_days int, p_time text default '10:00') returns timestamptz language sql as
$$ select (((now() at time zone 'Africa/Lusaka')::date + p_days) + p_time::time) at time zone 'Africa/Lusaka' $$;
create function pg_temp.day(p_days int) returns text language sql as
$$ select to_char((now() at time zone 'Africa/Lusaka')::date + p_days, 'YYYY-MM-DD') $$;

-- (Review fixes S1, S2, N4 and N5 are tested below.)
-- Accounts: 1 Admin A (no scope); 2 leader L of D; 3 deputy P of D (not a member of D); 4 member M
-- (removed from D); 5 member N (deactivated); 6 member Q (deleted); 7 Pastor; 8 deputy H of D (login
-- hold); 9 leader K, the only leader of E; 10 leader J of G (another department).
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', pg_temp.phone(n), now() from generate_series(1, 10) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 10) n;
select app.platform_set_environment('local', 'pgtap 4.16');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 4.16 Member ' || n, 'pgtap 4.16')
  from generate_series(1, 10) n;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
create function pg_temp.who(p uuid) returns int language sql as $$ select n from m where member_id = p $$;
create function pg_temp.mrev(n int) returns bigint language sql as
$$ select revision from app.identity_members where member_id = pg_temp.mid($1) $$;
create function pg_temp.grev(n int) returns bigint language sql as
$$ select revision from app.identity_grant_sets where member_id = pg_temp.mid($1) $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(7), 'pastor', 'israel');

create function pg_temp.dep(p_name text) returns uuid language sql as $$
  select (pg_temp.duties(1, 'duties.create_department', null, jsonb_build_object('name', p_name))
          #>> '{data,department_id}')::uuid
$$;
create temp table deps as select pg_temp.dep('SYNTHETIC Preaching Rota') as d, pg_temp.dep('SYNTHETIC 4.16 Ushers') as e,
                                 pg_temp.dep('SYNTHETIC 4.16 Stewards') as g;
create function pg_temp.d() returns uuid language sql as $$ select d from deps $$;
create function pg_temp.e() returns uuid language sql as $$ select e from deps $$;
create function pg_temp.g() returns uuid language sql as $$ select g from deps $$;
create function pg_temp.drev(p uuid) returns bigint language sql as
$$ select revision from app.duties_departments where department_id = p $$;
create function pg_temp.grant_scope(p_member int, p_kind text, p_scope uuid) returns jsonb language sql as $$
  select pg_temp.call(1, 'identity_grant_command', 'identity.grant_scope', pg_temp.grev(p_member),
    jsonb_build_object('member_id', pg_temp.mid(p_member), 'scope_kind', p_kind, 'scope_id', p_scope))
$$;
create function pg_temp.revoke_scope(p_member int, p_kind text, p_scope uuid) returns jsonb language sql as $$
  select pg_temp.call(1, 'identity_grant_command', 'identity.revoke_scope', pg_temp.grev(p_member),
    jsonb_build_object('member_id', pg_temp.mid(p_member), 'scope_kind', p_kind, 'scope_id', p_scope))
$$;
create function pg_temp.holds(p_member int, p_kind text, p_scope uuid) returns boolean language sql as $$
  select exists (select 1 from app.identity_grants g where g.member_id = pg_temp.mid(p_member)
                  and g.scope_kind = p_kind and g.scope_id = p_scope and g.revoked_at is null)
$$;
create function pg_temp.add(n int, p_department uuid) returns jsonb language sql as $$
  select pg_temp.duties(1, 'duties.add_member', pg_temp.drev(p_department),
    jsonb_build_object('department_id', p_department, 'member_id', pg_temp.mid(n)))
$$;
select pg_temp.grant_scope(2, 'department_leader', pg_temp.d());
select pg_temp.grant_scope(3, 'department_deputy', pg_temp.d());
select pg_temp.grant_scope(8, 'department_deputy', pg_temp.d());
select pg_temp.grant_scope(9, 'department_leader', pg_temp.e());
select pg_temp.grant_scope(10, 'department_leader', pg_temp.g());
select pg_temp.add(n, pg_temp.d()) from unnest(array[2, 4, 5, 6]) n;
select pg_temp.add(9, pg_temp.e());
select pg_temp.add(10, pg_temp.g());
-- H's login hold: H stays deputy of D but the app cannot reach H.
select is(pg_temp.err(pg_temp.call(1, 'identity_credential_command', 'identity.place_hold', pg_temp.mrev(8),
            jsonb_build_object('member_id', pg_temp.mid(8), 'reason_code', 'login_disabled'))), 'ok',
  'setup: the deputy H is on a login hold');

-- One-position duties, each on its own church day at 10:00.
create temp table pubs (tag text primary key, r jsonb);
create function pg_temp.pub(p_tag text, p_member int, p_days int, p_leader int default 2,
                            p_department uuid default null)
returns jsonb language plpgsql as $$
declare
  r jsonb;
begin
  r := pg_temp.duties(p_leader, 'duties.publish_duty', null, jsonb_build_object(
         'department_id', coalesce(p_department, pg_temp.d()), 'member_id', pg_temp.mid(p_member),
         'duty_name', 'Duty ' || p_tag, 'location', 'SYNTHETIC hall',
         'starts_at', app.cmd_utc(pg_temp.at(p_days))));
  if r ->> 'code' is not null then
    raise exception 'publish % failed: %', p_tag, r;
  end if;
  insert into pubs values (p_tag, r);
  return r;
end;
$$;
create function pg_temp.a(p_tag text) returns uuid language sql as
$$ select (r #>> '{data,assignment_id}')::uuid from pubs where tag = p_tag $$;
create function pg_temp.occ(p_tag text) returns uuid language sql as
$$ select (r #>> '{data,occurrence_id}')::uuid from pubs where tag = p_tag $$;
create function pg_temp.slot(p_tag text) returns uuid language sql as
$$ select slot_id from app.duties_assignments where assignment_id = pg_temp.a(p_tag) $$;
create function pg_temp.orev(p_occ uuid) returns bigint language sql as
$$ select revision from app.duties_occurrences where occurrence_id = p_occ $$;

-- ===================================================================================================
-- Item 7: the mismatch notice (one per department and change, reachable leaders and deputies only)
-- ===================================================================================================
select app.contract_register_source_type('fixture', 'fixture_event', 'app.fixture_event_check(jsonb)'::regprocedure);
select app.duties_register_link_source('fixture', 'fixture_event', 'event');
insert into app.fixture_events (title) values ('SYNTHETIC 4.16 Event');
create function pg_temp.ev() returns uuid language sql as
$$ select event_id from app.fixture_events where title = 'SYNTHETIC 4.16 Event' $$;
select pg_temp.pub('EV2', 2, 12);                       -- D, the later one
select pg_temp.pub('EV1', 2, 11);                       -- D, the soonest
select pg_temp.pub('EV3', 9, 13, 9, pg_temp.e());       -- E
create function pg_temp.link(p_tag text, p_leader int) returns text language sql as $$
  select pg_temp.duties(p_leader, 'duties.revise_duty', pg_temp.orev(pg_temp.occ(p_tag)), jsonb_build_object(
    'occurrence_id', pg_temp.occ(p_tag), 'event_ref', pg_temp.ev())) #>> '{data,change}'
$$;
select is(array[pg_temp.link('EV1', 2), pg_temp.link('EV2', 2), pg_temp.link('EV3', 9)],
  array['reference', 'reference', 'reference'], 'setup: three department duties (two in D, one in E) name the event');
create function pg_temp.flag(p_tag text) returns app.duties_review_flags language sql as
$$ select f.* from app.duties_review_flags f where f.occurrence_id = pg_temp.occ(p_tag) and f.cleared_at is null $$;
-- The review notices: recipient:flagged duty@flag revision, in a stable order.
create function pg_temp.notices(p_state text default 'pending') returns text language sql as $$
  select coalesce(string_agg(pg_temp.who(j.recipient_member_id)::text || ':'
                             || (select p.tag from pubs p join app.duties_review_flags f
                                   on f.occurrence_id = (p.r #>> '{data,occurrence_id}')::uuid
                                  where f.flag_id = j.source_id) || '@' || j.source_revision, ','
                             order by pg_temp.who(j.recipient_member_id), j.source_revision,
                                      (select p.tag from pubs p join app.duties_review_flags f
                                         on f.occurrence_id = (p.r #>> '{data,occurrence_id}')::uuid
                                        where f.flag_id = j.source_id)), '')
    from app.notifications_jobs j
   where j.source_type = 'duties_review' and j.reminder_kind = 'duty_review_flagged'
     and (p_state is null or j.job_state = p_state)
$$;

select is(pg_temp.fx(1, 'fixture_event_changed', jsonb_build_object('event_id', pg_temp.ev(),
            'changed', '["time"]'::jsonb)) ->> 'flagged', '3', 'the event moved: three department duties are flagged');
select is(pg_temp.notices(), '2:EV1@1,3:EV1@1,9:EV3@1',
  'one notice per department: D''s leader and deputy (keyed by D''s soonest flagged duty) and E''s leader');
select is((select count(*)::int from app.notifications_jobs
            where source_type = 'duties_review' and recipient_member_id in (pg_temp.mid(1), pg_temp.mid(7),
                  pg_temp.mid(8), pg_temp.mid(10), pg_temp.mid(4), pg_temp.mid(5), pg_temp.mid(6))), 0,
  'the held deputy, the Admin role alone, Pastor, another department''s leader and members get none');
select is((select string_agg(k, ',' order by k) from (
            select (app.duties_review_alert_check(jsonb_build_object(
                      'source_id', (pg_temp.flag('EV1')).flag_id, 'source_revision', 1,
                      'recipient_member_id', pg_temp.mid(n))) ->> 'recipient_eligible') || ':' || n as k
              from unnest(array[2, 3, 8, 9, 10, 1, 7]) n) x),
  'false:1,false:10,false:7,false:8,false:9,true:2,true:3',
  'delivery rechecks the recipient: D''s reachable leader and deputy only');
select pg_temp.run();
select is((select string_agg(pg_temp.who(i.recipient_member_id)::text, ',' order by pg_temp.who(i.recipient_member_id))
             from app.notifications_inbox_items i where i.reminder_kind = 'duty_review_flagged'),
  '2,3,9', 'each recipient gets one inbox item');
select is((select title || '|' || body || '|' || link from app.contract_reminder_contracts
            where source_type = 'duties_review' and reminder_kind = 'duty_review_flagged'),
  'Duty needs review|Something a duty in your department is linked to has changed. Open the Duties board to review it.|/duties/leader/reviews',
  'generic text with a deep link to the leader board''s reviews');
select is((select string_agg(x ->> 'title' || '|' || (x ->> 'body'), ',')
             from jsonb_array_elements(pg_temp.readj(3, 'select api.notifications_my_inbox()') -> 'items') x
            where x ->> 'reminder_kind' = 'duty_review_flagged'),
  'Duty needs review|Something a duty in your department is linked to has changed. Open the Duties board to review it.',
  'the deputy''s inbox shows the generic notice (no event, field, duty or person)');

-- A second change (Q2 open): a fresh notice per department; the same key never queues twice.
select is(pg_temp.fx(1, 'fixture_event_changed', jsonb_build_object('event_id', pg_temp.ev(),
            'changed', '["place"]'::jsonb)) ->> 'flagged', '3', 'the event changed again: the open flags merge');
select is(pg_temp.notices(null), '2:EV1@1,2:EV1@2,3:EV1@1,3:EV1@2,9:EV3@1,9:EV3@2',
  'a fresh notice per department and change (deduplicated by the flag revision)');
select is((app.notifications_enqueue(jsonb_build_object('source_type', 'duties_review',
            'source_id', (pg_temp.flag('EV1')).flag_id, 'source_revision', 2, 'recipient_member_id', pg_temp.mid(2),
            'reminder_kind', 'duty_review_flagged',
            'scheduled_at', (select app.cmd_utc(scheduled_at) from app.notifications_jobs
                              where source_id = (pg_temp.flag('EV1')).flag_id and source_revision = 2
                                and recipient_member_id = pg_temp.mid(2)))) ->> 'created'), 'false',
  'the same change never queues a second notice to the same leader');
select is((app.duties_review_alert_check(jsonb_build_object('source_id', (pg_temp.flag('EV1')).flag_id,
            'source_revision', 1, 'recipient_member_id', pg_temp.mid(2))) ->> 'current'), 'true',
  'review S2: the first change''s notice stays current while a duty of that source in D is still open');

-- The department reviews its duties: the notice stays while any duty of the change is open (S2).
select is((app.duties_review_alert_check(jsonb_build_object('source_id', (pg_temp.flag('EV1')).flag_id,
            'source_revision', 2, 'recipient_member_id', pg_temp.mid(3))) ->> 'actionable'), 'true',
  'before the review, D''s current notice is actionable');
create temp table ev1flag as select (pg_temp.flag('EV1')).flag_id;
select is(pg_temp.err(pg_temp.duties(2, 'duties.clear_review', (pg_temp.flag('EV1')).revision,
            jsonb_build_object('flag_id', (pg_temp.flag('EV1')).flag_id))), 'ok', 'L marks the first duty reviewed');
select is((select (c ->> 'current') || '|' || (c ->> 'actionable') || '|' || (c ->> 'revision')
             from (select app.duties_review_alert_check(jsonb_build_object('source_id', (select flag_id from ev1flag),
                     'source_revision', 2, 'recipient_member_id', pg_temp.mid(3))) as c) x), 'true|true|2',
  'review S2: with the second duty of the change still open, D''s notice stays current and actionable');
select is((app.duties_review_source_check(jsonb_build_object('source_type', 'duties_review',
            'source_id', (select flag_id from ev1flag), 'source_revision', 2)) ->> 'current'), 'true',
  'and its inbox item is still current');
select is(pg_temp.err(pg_temp.duties(3, 'duties.clear_review', (pg_temp.flag('EV2')).revision,
            jsonb_build_object('flag_id', (pg_temp.flag('EV2')).flag_id))), 'ok', 'P marks the second duty reviewed');
select is((select (c ->> 'current') || '|' || (c ->> 'actionable')
             from (select app.duties_review_alert_check(jsonb_build_object('source_id', (select flag_id from ev1flag),
                     'source_revision', 2, 'recipient_member_id', pg_temp.mid(3))) as c) x), 'false|false',
  'with every duty of the change reviewed, D''s notice is no longer current');
select is((app.duties_review_alert_check(jsonb_build_object('source_id', (pg_temp.flag('EV3')).flag_id,
            'source_revision', 2, 'recipient_member_id', pg_temp.mid(9))) ->> 'actionable'), 'true',
  'E''s notice is not affected');

-- Q2 closed: the flags are recorded, the notice is skipped and audited.
update app.policy_gates set fixture_value = fixture_value || '{"zone": "Mars/Base"}' where gate = 'q2_church_time';
create temp table qjobs as select count(*)::int as n from app.notifications_jobs where source_type = 'duties_review';
select is(pg_temp.fx(1, 'fixture_event_changed', jsonb_build_object('event_id', pg_temp.ev(),
            'changed', '["label"]'::jsonb)) ->> 'flagged', '3', 'with Q2 unavailable the change is still flagged');
select is((select count(*)::int from app.duties_review_flags where source_id = pg_temp.ev() and cleared_at is null), 3,
  'the flags are recorded (two new in D, E''s merged)');
select is((select count(*)::int from app.notifications_jobs where source_type = 'duties_review'), (select n from qjobs),
  'no notice is queued');
select is((select string_agg(code || ':' || case department_id when pg_temp.d() then 'D' when pg_temp.e() then 'E' end,
                             ',' order by code, case department_id when pg_temp.d() then 'D' when pg_temp.e() then 'E' end)
             from app.duties_audit where action = 'reminders_skipped'
              and department_id in (pg_temp.d(), pg_temp.e()) and member_id is null),
  'policy_unavailable:D,policy_unavailable:E', 'the skip is audited once per department');
update app.policy_gates set fixture_value = fixture_value || '{"zone": "Africa/Lusaka"}' where gate = 'q2_church_time';

-- Review N4: a change made by D's leader is not notified to that leader.
create temp table n4 as select (select count(*)::int from app.notifications_jobs
                                  where source_type = 'duties_review' and recipient_member_id = pg_temp.mid(2)) as l,
                               (select count(*)::int from app.notifications_jobs
                                  where source_type = 'duties_review' and recipient_member_id = pg_temp.mid(3)) as p;
select is(pg_temp.fx(2, 'fixture_event_changed', jsonb_build_object('event_id', pg_temp.ev(),
            'changed', '["time"]'::jsonb)) ->> 'flagged', '3', 'L reports the event change');
select is(array[(select count(*)::int from app.notifications_jobs where source_type = 'duties_review'
                   and recipient_member_id = pg_temp.mid(2)) - (select l from n4),
                (select count(*)::int from app.notifications_jobs where source_type = 'duties_review'
                   and recipient_member_id = pg_temp.mid(3)) - (select p from n4)],
  array[0, 1], 'the deputy is told; L, who made the change, is not');

-- Timing: one change over 60 linked duties in D (one notice per leader).
create temp table many as
  select pg_temp.duties(2, 'duties.publish_duty', null, jsonb_build_object(
           'department_id', pg_temp.d(), 'member_id', pg_temp.mid(2), 'duty_name', 'SYNTHETIC many ' || n,
           'location', 'SYNTHETIC hall', 'starts_at', app.cmd_utc(pg_temp.at(30 + n)))) as r
    from generate_series(1, 60) n;
-- (Setup shortcut: the reference is set directly; revise_duty sets it one duty at a time above.)
update app.duties_occurrences set event_ref = pg_temp.ev()
 where occurrence_id in (select (r #>> '{data,occurrence_id}')::uuid from many);
select is((select count(*)::int from app.duties_occurrences where event_ref = pg_temp.ev()), 63,
  'setup: 60 more duties name the event');
create temp table t0 as select clock_timestamp() as t,
  (select count(*)::int from app.notifications_jobs where source_type = 'duties_review') as jobs;
create temp table tflag as select pg_temp.fx(1, 'fixture_event_changed', jsonb_build_object('event_id', pg_temp.ev(),
            'changed', '["time"]'::jsonb)) as r;
create temp table t1 as select clock_timestamp() as t;
select is((select r ->> 'flagged' from tflag), '63', 'the change flags 63 duties');
select ok((select t from t1) - (select t from t0) < interval '3 seconds',
  'flagging 63 duties with their notices stays well under the 8 s statement timeout');
select diag('timing: flag 63 duties and queue their notices: '
            || round(extract(epoch from (select t from t1) - (select t from t0)) * 1000) || ' ms');
select is((select count(*)::int from app.notifications_jobs where source_type = 'duties_review') - (select jobs from t0), 3,
  'still one notice per leader and department (D: L and P; E: K)');

-- Review N5: 144 more duties of D before the linked ones push them past the board's first 200; every
-- duty with an open review is still listed.
select is((select count(*)::int from (
             select pg_temp.duties(2, 'duties.publish_duty', null, jsonb_build_object(
                      'department_id', pg_temp.d(), 'member_id', pg_temp.mid(2), 'duty_name', 'SYNTHETIC filler',
                      'location', 'SYNTHETIC hall',
                      'starts_at', app.cmd_utc(pg_temp.at(14 + n / 12, lpad((6 + n % 12)::text, 2, '0') || ':00')),
                      'ends_at', app.cmd_utc(pg_temp.at(14 + n / 12, lpad((6 + n % 12)::text, 2, '0') || ':50')))) as r
               from generate_series(0, 143) n) x where r ->> 'code' is null), 144,
  'setup: 144 more duties of D come before the linked ones');
create temp table n5t0 as select clock_timestamp() as t;
create temp table n5 as select pg_temp.readj(2, 'select api.duties_leader_board()') as b;
create temp table n5t1 as select clock_timestamp() as t;
select ok((select t from n5t1) - (select t from n5t0) < interval '3 seconds',
  'the board with 200 duties plus the reviewed ones stays well under the 8 s statement timeout');
select diag('timing: leader board with ' || (select jsonb_array_length(dep -> 'duties') from n5,
              jsonb_array_elements(b -> 'departments') dep where dep ->> 'department_id' = pg_temp.d()::text)
            || ' duties in D: ' || round(extract(epoch from (select t from n5t1) - (select t from n5t0)) * 1000) || ' ms');
select is((select (dep ->> 'duties_truncated') || '|' || jsonb_array_length(dep -> 'duties')
             from n5, jsonb_array_elements(b -> 'departments') dep where dep ->> 'department_id' = pg_temp.d()::text),
  'true|' || (200 + (select count(*) from app.duties_occurrences o
                      where o.department_id = pg_temp.d() and o.event_ref = pg_temp.ev()
                        and o.occurrence_id not in (select occurrence_id from app.duties_occurrences
                                                     where department_id = pg_temp.d() and occurrence_state = 'published'
                                                     order by starts_at limit 200)))::text,
  'the board lists its first 200 duties plus every later duty with an open review');
select is((select count(*)::int from app.duties_review_flags f join app.duties_occurrences o on o.occurrence_id = f.occurrence_id
            where f.cleared_at is null and o.department_id = pg_temp.d()
              and f.occurrence_id::text not in (select dd ->> 'occurrence_id' from n5,
                                                  jsonb_array_elements(b -> 'departments') dep,
                                                  jsonb_array_elements(dep -> 'duties') dd)), 0,
  'no open review of D is missing from the board');

-- ===================================================================================================
-- Item 8: the vacancy reason (the department's leaders and deputies only)
-- ===================================================================================================
select pg_temp.pub('VR', 4, 21);
select pg_temp.pub('VI', 5, 22);
select pg_temp.pub('VD', 6, 23);
select pg_temp.pub('RV', 4, 24);
-- A revised (not vacated) history entry stays as it was.
select is(pg_temp.duties(2, 'duties.revise_duty', pg_temp.orev(pg_temp.occ('RV')), jsonb_build_object(
    'occurrence_id', pg_temp.occ('RV'), 'starts_at', app.cmd_utc(pg_temp.at(24, '11:00')))) #>> '{data,change}',
  'material', 'setup: a material change ends RV''s first assignment as revised');
select is(pg_temp.err(pg_temp.duties(1, 'duties.remove_member', pg_temp.drev(pg_temp.d()),
            jsonb_build_object('department_id', pg_temp.d(), 'member_id', pg_temp.mid(4)))), 'ok',
  'the Admin removes M from D');
select is(pg_temp.err(pg_temp.call(1, 'identity_lifecycle_command', 'identity.deactivate_membership', pg_temp.mrev(5),
            jsonb_build_object('member_id', pg_temp.mid(5), 'reason_code', 'moved_away'))), 'ok',
  'the Admin deactivates N');
create temp table del as select pg_temp.call(6, 'identity_deletion_command', 'identity.request_my_deletion',
  null, '{"confirm": "delete_my_account"}'::jsonb) as r;
select is(pg_temp.err((select r from del)), 'ok', 'Q deletes their own account');
select is((select string_agg(end_reason || ':' || vacancy_reason, ',' order by assignment_id = pg_temp.a('VR') desc,
                             assignment_id = pg_temp.a('VI') desc)
             from app.duties_assignments where assignment_id in (pg_temp.a('VR'), pg_temp.a('VI'), pg_temp.a('VD'))),
  'vacated:removed_from_department,vacated:member_inactive,vacated:member_deleted',
  'each vacated assignment records its coarse reason code');
select is((select vacancy_reason from app.duties_assignments where assignment_id = pg_temp.a('RV')), null,
  'a revised assignment has none');
select throws_ok(format($$update app.duties_assignments set vacancy_reason = 'member_inactive' where assignment_id = %L$$,
                        pg_temp.a('RV')), '23514', null, 'a reason only goes with end reason vacated');
select throws_ok(format($$update app.duties_assignments set vacancy_reason = 'SYNTHETIC free text' where assignment_id = %L$$,
                        pg_temp.a('VR')), '23514', null, 'and only one of the three codes (no free text)');

-- The board's history entry.
create function pg_temp.hist(n int, p_tag text) returns jsonb language sql as $$
  select h from jsonb_array_elements(pg_temp.readj(n, 'select api.duties_leader_board()') -> 'departments') dep,
                jsonb_array_elements(dep -> 'duties') o, jsonb_array_elements(o -> 'positions') p,
                jsonb_array_elements(p -> 'history') h
   where o ->> 'occurrence_id' = pg_temp.occ(p_tag)::text
   order by h ->> 'ended_at' desc limit 1
$$;
select is(array[pg_temp.hist(2, 'VR') ->> 'vacancy_reason', pg_temp.hist(2, 'VI') ->> 'vacancy_reason',
                pg_temp.hist(2, 'VD') ->> 'vacancy_reason'],
  array['removed_from_department', 'member_inactive', 'member_deleted'], 'D''s leader reads the reason on the board');
select is(pg_temp.hist(3, 'VI') ->> 'vacancy_reason', 'member_inactive', 'and so does D''s deputy');
select is(array[pg_temp.hist(1, 'VI') ? 'vacancy_reason', (pg_temp.hist(1, 'VI') ->> 'vacancy_reason') is null],
  array[true, true], 'the Admin role alone reads the vacated entry without a reason');
select is(pg_temp.hist(7, 'VI') ->> 'vacancy_reason', null, 'so does Pastor');
select is((select count(*)::int from jsonb_array_elements(pg_temp.readj(10, 'select api.duties_leader_board()') -> 'departments') dep
            where dep ->> 'department_id' = pg_temp.d()::text), 0, 'another department''s leader does not see D at all');
select is((select h ? 'vacancy_reason'
             from jsonb_array_elements(pg_temp.readj(2, 'select api.duties_leader_board()') -> 'departments') dep,
                  jsonb_array_elements(dep -> 'duties') o, jsonb_array_elements(o -> 'positions') p,
                  jsonb_array_elements(p -> 'history') h
            where o ->> 'occurrence_id' = pg_temp.occ('RV')::text and h ->> 'end_reason' = 'revised'), false,
  'a revised history entry is unchanged (no reason key)');
select ok(position('moved_away' in pg_temp.readj(2, 'select api.duties_leader_board()')::text) = 0
          and position('member_left' in pg_temp.readj(2, 'select api.duties_leader_board()')::text) = 0,
  'no Identity reason code or audit code reaches the leader');

-- The coverage queue.
create function pg_temp.cpos(n int, p_slot uuid) returns jsonb language sql as $$
  select p from jsonb_array_elements(pg_temp.readj(n, format('select api.duties_coverage(%L::date, %L::date)',
                                                              pg_temp.day(20), pg_temp.day(25))) -> 'departments') dep,
                jsonb_array_elements(dep -> 'positions') p
   where p ->> 'slot_id' = p_slot::text
$$;
select is(array[pg_temp.cpos(2, pg_temp.slot('VR')) #>> '{vacated,reason}', pg_temp.cpos(2, pg_temp.slot('VI')) #>> '{vacated,reason}',
                pg_temp.cpos(3, pg_temp.slot('VD')) #>> '{vacated,reason}'],
  array['removed_from_department', 'member_inactive', 'member_deleted'], 'the coverage queue shows the reason to D''s leader and deputy');
select is(array[(pg_temp.cpos(1, pg_temp.slot('VI')) #>> '{vacated,since}') is not null,
                (pg_temp.cpos(1, pg_temp.slot('VI')) #>> '{vacated,reason}') is null,
                (pg_temp.cpos(7, pg_temp.slot('VI')) #>> '{vacated,reason}') is null],
  array[true, true, true], 'the Admin''s and Pastor''s operational view shows the flag without a reason');
select is(pg_temp.cpos(10, pg_temp.slot('VI')), null, 'another department''s leader sees no position of D');

-- Erasure keeps the category (no person, no free text).
create function pg_temp.deln() returns app.identity_deletions language sql as
$$ select d.* from app.identity_deletions d where d.member_id = pg_temp.mid(6) $$;
select is(app.identity_deletion_blocker(pg_temp.deln(), 'erase_owners'), null, 'Q has nothing to hand over');
select is((select (r ->> 'remaining')::int from jsonb_array_elements(app.identity_call_deletion_hooks(
             pg_temp.mid(6), pg_temp.u(6), (pg_temp.deln()).deletion_id, 'erase')) r where r ->> 'module' = 'duties'), 0,
  'the erase phase leaves nothing of Q in Duties');
select is((select (member_id = '00000000-0000-0000-0000-000000000000')::text || '|' || vacancy_reason
             from app.duties_assignments where assignment_id = pg_temp.a('VD')),
  'true|member_deleted', 'the anonymised assignment keeps only the category');
select is((pg_temp.hist(2, 'VD') ->> 'vacancy_reason') || '|' || coalesce(pg_temp.hist(2, 'VD') ->> 'display_name', 'none'),
  'member_deleted|none', 'the leader reads "Member deleted" with no name');

-- ===================================================================================================
-- Item 10: last-leader protection on scope revocation (the Identity handover-hook seam)
-- ===================================================================================================
-- E: K is the only leader; H (held) is made a deputy of E too, and does not count.
select pg_temp.grant_scope(8, 'department_deputy', pg_temp.e());
create temp table kgrant as select grant_id from app.identity_grants
 where member_id = pg_temp.mid(9) and scope_kind = 'department_leader' and scope_id = pg_temp.e() and revoked_at is null;
create temp table kbefore as select pg_temp.grev(9) as rev,
  (select count(*)::int from app.identity_access_audit where grant_id = (select grant_id from kgrant)) as audit;
select is(pg_temp.err(pg_temp.revoke_scope(9, 'department_leader', pg_temp.e())), 'conflict|member_id=handover_required',
  'revoking the last reachable leader''s scope is refused until handover (a held deputy does not count)');
select is(array[pg_temp.holds(9, 'department_leader', pg_temp.e())::text, (pg_temp.grev(9) = (select rev from kbefore))::text,
                ((select count(*)::int from app.identity_access_audit where grant_id = (select grant_id from kgrant))
                   = (select audit from kbefore))::text,
                (select count(*)::int from app.identity_handover_obligations where member_id = pg_temp.mid(9))::text],
  array['true', 'true', 'true', '0'], 'nothing changed: the grant, its revision, the audit and no obligation');
select is((pg_temp.revoke_scope(9, 'department_leader', pg_temp.e()) ->> 'current_revision')::bigint, pg_temp.grev(9),
  'the refusal names the current grant revision');
select is(pg_temp.err(pg_temp.grant_scope(10, 'department_leader', pg_temp.e())), 'ok', 'the Admin makes J a leader of E too');
select is(pg_temp.err(pg_temp.revoke_scope(9, 'department_leader', pg_temp.e())), 'ok',
  'with another reachable leader the revocation is allowed');
select is(pg_temp.holds(9, 'department_leader', pg_temp.e()), false, 'K''s scope ends');
select is((select count(*)::int from app.identity_access_audit where grant_id = (select grant_id from kgrant)
              and action = 'scope_revoked'), 1, 'audited once, as before');
select is((app.duties_review_alert_check(jsonb_build_object('source_id', (pg_temp.flag('EV3')).flag_id,
            'source_revision', (pg_temp.flag('EV3')).revision, 'recipient_member_id', pg_temp.mid(9))) ->> 'recipient_eligible'),
  'false', 'K''s pending review notice is refused at delivery');

-- D: a deputy may go while the leader stays; a member's own remaining grant counts.
create temp table t3 as select gen_random_uuid() as src;
select is(pg_temp.err(pg_temp.call(2, 'followups_command', 'followups.create_task', null, jsonb_build_object(
         'source_type', 'fixture_followup', 'source_id', (select src from t3), 'source_revision', 1,
         'purpose', 'synthetic_check_in', 'owner_member_id', pg_temp.mid(3), 'supervisor_member_id', pg_temp.mid(2),
         'scope_kind', 'department_leader', 'scope_id', pg_temp.d(),
         'next_action', 'SYNTHETIC: phone and check in', 'due_at', app.cmd_utc(pg_temp.at(9))))), 'ok',
  'setup: P owns a follow-up task of D (P is not a member of D), supervised by L');
create function pg_temp.task3() returns app.followups_tasks language sql as
$$ select t.* from app.followups_tasks t where t.source_id = (select src from t3) $$;
create temp table pgrant as select grant_id from app.identity_grants
 where member_id = pg_temp.mid(3) and scope_kind = 'department_deputy' and scope_id = pg_temp.d() and revoked_at is null;
-- No hand-over budget left in this transaction: the obligation the revocation records stays pending.
select set_config('followups.handover_budget', pg_temp.mid(3)::text || ':0', true);
select is(pg_temp.err(pg_temp.revoke_scope(3, 'department_deputy', pg_temp.d())), 'ok',
  'D''s deputy may be revoked while its leader is reachable');
select is((select string_agg(owner_module || ':' || obligation_kind || ':' || obligation_state || ':'
                             || (revoked_grant_id = (select grant_id from pgrant))::text || ':'
                             || (lifecycle_event_id is null)::text, ',')
             from app.identity_handover_obligations where member_id = pg_temp.mid(3)),
  'followups:followup_task:pending:true:true', 'the revocation records P''s real Follow-ups obligation against the grant');
select is((select string_agg(obligation_kind, ',') from app.followups_pending_handovers() where member_id = pg_temp.mid(3)),
  'followup_task', 'the 4.12 Follow-ups pending list still lists it');
select is((select count(*)::int from jsonb_array_elements(pg_temp.readj(1, 'select api.identity_admin_membership_lifecycle()') -> 'handovers') h
            where h ->> 'member_id' = pg_temp.mid(3)::text and h ->> 'owner_module' = 'followups'), 1,
  'and the Admin''s membership status shows the pending handover');
select is(pg_temp.err(pg_temp.call(1, 'followups_command', 'followups.complete_handover', null,
            jsonb_build_object('member_id', pg_temp.mid(3)))), 'ok', 'the Admin continues the handover');
select is((select obligation_state || ':' || resolution from app.identity_handover_obligations where member_id = pg_temp.mid(3)),
  'resolved:handed_over', 'the task moved and its obligation is resolved');
select is(pg_temp.who((pg_temp.task3()).owner_member_id), 2, 'to the task''s supervisor, L');

select is(pg_temp.err(pg_temp.grant_scope(2, 'department_deputy', pg_temp.d())), 'ok', 'setup: L is also a deputy of D');
select is(pg_temp.err(pg_temp.revoke_scope(2, 'department_leader', pg_temp.d())), 'ok',
  'L''s leader scope may go: L''s own deputy scope still makes D reachable');
select is(pg_temp.err(pg_temp.revoke_scope(2, 'department_deputy', pg_temp.d())), 'conflict|member_id=handover_required',
  'L''s last scope of D is refused (the held deputy H does not count)');
select is(pg_temp.holds(2, 'department_deputy', pg_temp.d()), true, 'and L keeps it');
select is(pg_temp.err(pg_temp.revoke_scope(10, 'department_leader', pg_temp.g())), 'conflict|member_id=handover_required',
  'the same rule protects another department''s only leader');
-- Review S1: unlinking G's only leader is never refused (a security action), but records the
-- department's handover against the ended grant; a later deactivation follows the 4.12 rules.
create temp table jgrant as select grant_id from app.identity_grants
 where member_id = pg_temp.mid(10) and scope_kind = 'department_leader' and scope_id = pg_temp.g() and revoked_at is null;
select is(pg_temp.err(pg_temp.call(1, 'identity_review_command', 'identity.unlink_account', pg_temp.mrev(10),
            jsonb_build_object('member_id', pg_temp.mid(10), 'reason', 'account_lost'))), 'ok',
  'unlinking the department''s only leader is not refused');
select is((select string_agg(owner_module || ':' || obligation_kind || ':' || obligation_state || ':'
                             || case subject_id when pg_temp.g() then 'G' when pg_temp.e() then 'E' end || ':'
                             || (revoked_grant_id is not null and lifecycle_event_id is null)::text, ','
                             order by case subject_id when pg_temp.g() then 'G' when pg_temp.e() then 'E' end)
             from app.identity_handover_obligations where member_id = pg_temp.mid(10)),
  'duties:department_leader:pending:E:true,duties:department_leader:pending:G:true',
  'both departments J was the last reachable leader of (E and G) get a handover recorded against the ended grants');
select is((select count(*)::int from app.identity_handover_obligations
            where member_id = pg_temp.mid(10) and subject_id = pg_temp.g() and revoked_grant_id = (select grant_id from jgrant)), 1,
  'G''s against G''s grant');
select is((select (d ->> 'needs_leader') || '|' || jsonb_array_length(d -> 'handovers')
             from jsonb_array_elements(pg_temp.readj(1, 'select api.duties_admin_overview()') -> 'departments') d
            where d ->> 'department_id' = pg_temp.g()::text), 'true|1', 'Departments shows G needs a leader and a pending handover');
select is((select count(*)::int from jsonb_array_elements(pg_temp.readj(1, 'select api.identity_admin_membership_lifecycle()') -> 'handovers') h
            where h ->> 'member_id' = pg_temp.mid(10)::text), 2, 'Membership status shows them too');
select is(pg_temp.err(pg_temp.call(1, 'identity_lifecycle_command', 'identity.deactivate_membership', pg_temp.mrev(10),
            jsonb_build_object('member_id', pg_temp.mid(10), 'reason_code', 'church_decision'))), 'ok',
  'a later deactivation of J follows the 4.12 rules (J holds no scope any more)');
select is((select count(*)::int from app.identity_handover_obligations where member_id = pg_temp.mid(10)
              and obligation_state = 'pending'), 2, 'the departments'' handovers stay pending');
select is(pg_temp.err(pg_temp.grant_scope(9, 'department_leader', pg_temp.g())), 'ok', 'the Admin makes K the leader of G');
select is(pg_temp.err(pg_temp.duties(1, 'duties.resolve_handover', pg_temp.drev(pg_temp.g()),
            jsonb_build_object('department_id', pg_temp.g()))), 'ok', 'and marks the handover done');
select is((select string_agg(case subject_id when pg_temp.g() then 'G' else 'E' end || ':' || obligation_state, ','
                             order by case subject_id when pg_temp.g() then 'G' else 'E' end)
             from app.identity_handover_obligations where member_id = pg_temp.mid(10)),
  'E:pending,G:resolved', 'G''s is resolved; E''s waits for E''s own leader');
select is(app.identity_revoked_scope() is null, true, 'outside a revocation no revoked scope is readable');
select is((select count(*)::int from app.identity_handover_obligations where revoked_grant_id is not null
              and lifecycle_event_id is not null), 0, 'an obligation has exactly one origin');
select is(app.duties_report_handover(jsonb_build_object('event', 'membership_deactivated', 'member_id', pg_temp.mid(2))),
  jsonb_build_object('obligations', jsonb_build_array(jsonb_build_object(
    'kind', 'department_leader', 'subject_id', pg_temp.d(), 'last_responsible', true))),
  'the 4.12 deactivation rule is unchanged (L is D''s last reachable leader or deputy)');

-- ===================================================================================================
-- G3: the operator path to approve dormancy_days
-- ===================================================================================================
select is(array[has_function_privilege('anon', 'app.identity_approve_setting(text, jsonb, text, text)', 'EXECUTE'),
                has_function_privilege('authenticated', 'app.identity_approve_setting(text, jsonb, text, text)', 'EXECUTE'),
                has_function_privilege('service_role', 'app.identity_approve_setting(text, jsonb, text, text)', 'EXECUTE')],
  array[false, false, false], 'no client role may approve a setting');
select throws_ok($$select app.identity_approve_setting('dormancy_days', '{"days": 180}', 'SYNTHETIC nobody', 'Owner decision 2026-10-15')$$,
  '42501', 'not an active restricted operator', 'a non-operator is refused');
select throws_ok($$select app.identity_approve_setting('lead_pastor_designation', '{"days": 180}', 'israel', 'Owner decision')$$,
  '22023', 'unknown identity setting', 'only an Identity setting');
select throws_ok($$select app.identity_approve_setting('dormancy_days', '{"days": 180}', 'israel', 'TEST FIXTURE value')$$,
  '22023', 'an owner decision note is required', 'a fixture label is never an approval');
select throws_ok($$select app.identity_approve_setting('dormancy_days', '{"days": 0}', 'israel', 'Owner decision')$$,
  '22023', null, 'the value is validated (1-3650 days)');
select throws_ok($$select app.identity_approve_setting('dormancy_days', '{"days": "180"}', 'israel', 'Owner decision')$$,
  '22023', null, 'a string is not a number of days');
-- A member last active 120 days ago is dormant under the 90-day fixture.
update app.identity_account_links set last_member_activity_at = now() - interval '120 days' where member_id = pg_temp.mid(7);
create function pg_temp.outcome(n int) returns text language plpgsql as $$
declare
  v text;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  select e.outcome into v from app.identity_access_evaluate() e;
  return v;
end;
$$;
select is(pg_temp.outcome(7), 'review_required', 'under the labelled 90-day fixture the Pastor is dormant');
select is(app.identity_approve_setting('dormancy_days', '{"days": 180}', 'israel',
            'Owner decision 2026-10-15: 180 days (SYNTHETIC test approval)'), 2, 'the operator approves version 2');
select is(app.identity_setting('dormancy_days'), '{"days": 180}'::jsonb, 'the approved version is in force');
select is(pg_temp.outcome(7), 'granted', 'and honoured: 120 days is within 180');
select is((select string_agg(version || ':' || source || ':' || (value ->> 'days'), ',' order by version)
             from app.identity_settings where setting = 'dormancy_days'),
  '1:fixture:90,2:approved:180', 'the labelled fixture row is left as it was');
select is((select count(*)::int from app.identity_access_audit where action = 'church_setting_approved'
              and setting = 'dormancy_days' and operator = 'israel' and revision_after = 2), 1, 'audited with the setting');
select is((select count(*)::int from app.ops_operator_actions where action = 'church_setting_approved' and operator = 'israel'
              and occurred_at >= now()), 1, 'and in the operator journal');

-- ===================================================================================================
-- Privileges and guards
-- ===================================================================================================
select is((select count(*)::int from information_schema.routine_privileges
            where routine_schema = 'app' and grantee in ('anon', 'authenticated', 'PUBLIC', 'service_role')
              and routine_name in ('duties_vacancy_reason', 'duties_review_source_check', 'duties_review_alert_check',
                                   'duties_review_key_open', 'identity_scope_revoked_event',
                                   'identity_collect_revocation_handover', 'identity_record_revocation_obligations',
                                   'identity_revoked_scope', 'identity_end_grant_record', 'identity_approve_setting')), 0,
  'nothing new is client-executable');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');

select * from finish();
rollback;
