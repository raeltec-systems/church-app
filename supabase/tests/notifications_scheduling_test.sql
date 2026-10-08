-- Church-time reminder schedules from a versioned policy (story 3.3; AD-9; epic 3 N3).
-- Table-driven: the Q2 policy value and its validation, the four response-deadline bands and
-- creator deadlines, church-local dates (Africa/Lusaka has no DST; month ends; recurrence
-- exceptions), passed offsets, short notice, merging, expiry, no quiet hours, Waiting review
-- dates, snooze clamping, schedule reconciliation, policy re-planning without past-due work,
-- the production gate, guards and privileges. Every member here is SYNTHETIC.
begin;
select plan(79);

-- 'ok <json>' or 'sqlstate|message|detail' of a statement returning jsonb.
create function pg_temp.try(p_sql text) returns text
language plpgsql as $$
declare
  r jsonb;
  v_state text;
  v_msg text;
  v_detail text;
begin
  execute p_sql into r;
  return 'ok ' || coalesce(r::text, 'null');
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
  return v_state || '|' || v_msg || '|' || coalesce(v_detail, '');
end;
$$;
-- Field errors of a PCMD1 failure, or the 'ok ...' text.
create function pg_temp.fe(p_sql text) returns text
language plpgsql as $$
declare
  v text := pg_temp.try(p_sql);
begin
  if v like 'PCMD1|%' then
    return split_part(v, '|', 2) || ' ' || ((split_part(v, '|', 3))::jsonb -> 'field_errors')::text;
  end if;
  return v;
end;
$$;
create function pg_temp.utc(p text) returns timestamptz language sql as $$ select p::timestamptz $$;
create function pg_temp.pol() returns jsonb language sql as $$ select app.notifications_policy() $$;
-- Plan at the fixed reference instant 2026-10-01T08:00:00Z (10:00 in Lusaka).
create function pg_temp.plan(p_type text, p_intent jsonb, p_fresh boolean default true) returns jsonb
language sql as $$
  select app.notifications_plan(pg_temp.pol(), p_type, p_intent, '2026-10-01T08:00:00Z', p_fresh)
$$;
create function pg_temp.at(p_plan jsonb) returns text language sql as $$
  select coalesce(string_agg(e ->> 'scheduled_at' || '=' || (e -> 'anchors')::text, ' ' order by e ->> 'scheduled_at'), '')
    from jsonb_array_elements(p_plan -> 'entries') e
$$;
create function pg_temp.ri(p_starts text, p_extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('assigned_at', '2026-10-01T08:00:00Z', 'starts_at', p_starts) || p_extra
$$;

-- Production (no marker): Q2 unapproved, nothing schedules ------------------------------------
create temp table m (n int primary key, member_id uuid);
with ins as (insert into app.identity_members (display_name, membership_state, is_synthetic)
             select 'SYNTHETIC 3.3 Member ' || n, 'approved', true from generate_series(1, 2) n
             returning member_id)
insert into m select row_number() over (), member_id from ins;
create temp table src (k text primary key, id uuid);
insert into src values ('S1', gen_random_uuid()), ('S2', gen_random_uuid()), ('S3', gen_random_uuid()),
                       ('S4', gen_random_uuid()), ('S5', gen_random_uuid()), ('T1', gen_random_uuid());
insert into app.fixture_reminder_sources (source_id, member_id, due_at, created_by_account)
select s.id, (select member_id from m where n = 1), now(), gen_random_uuid() from src s;
create function pg_temp.sched(p_k text, p_rev bigint, p_type text, p_intent jsonb,
                              p_kinds jsonb default '{"response_deadline": "fixture_response", "starts_at": "fixture_upcoming"}',
                              p_member int default 1, p_fresh boolean default true)
returns jsonb language sql as $$
  select app.notifications_set_schedule(jsonb_build_object(
    'source_type', 'fixture_reminder', 'source_id', (select id from src where k = p_k),
    'source_revision', p_rev, 'recipient_member_id', (select member_id from m where n = p_member),
    'schedule_type', p_type, 'intent', p_intent, 'kinds', p_kinds, 'fresh', p_fresh))
$$;
create function pg_temp.jobs(p_k text, p_state text default 'pending') returns text language sql as $$
  select coalesce(string_agg(reminder_kind || '@r' || source_revision || '+'
                             || round(extract(epoch from scheduled_at - now()) / 3600)::text || 'h',
                             ' ' order by scheduled_at, reminder_kind), '')
    from app.notifications_jobs
   where source_id = (select id from src where k = p_k) and job_state = p_state
$$;
create function pg_temp.rel(p interval) returns text language sql as $$ select app.cmd_utc(now() + p) $$;

select is(split_part(pg_temp.try('select app.notifications_policy()'), '|', 2), 'unavailable',
  'production: the scheduling policy is unavailable while Q2 is unapproved');
select is(pg_temp.fe($$select pg_temp.sched('S1', 1, 'response', pg_temp.ri('2026-11-15T07:00:00Z'))$$),
  'unavailable {"policy": "gate_closed"}', 'production: set_schedule refuses to schedule');
select is(split_part(pg_temp.try('select app.notifications_replan_all()'), '|', 2), 'unavailable',
  'production: re-planning refuses');
select is(split_part(pg_temp.try(format('select app.notifications_snooze_item(%L, gen_random_uuid(), %L)',
            (select member_id from m where n = 1), '1 hour')), '|', 2), 'unavailable',
  'production: snoozing refuses');
select is((select count(*)::int from app.notifications_schedules) + (select count(*)::int from app.notifications_jobs),
  0, 'production: no schedule and no job written');

-- Local: the policy value ----------------------------------------------------------------------
select app.platform_set_environment('local', 'pgtap 3.3');
select is(app.notifications_policy_errors((select fixture_value from app.policy_gates where gate = 'q2_church_time')),
  '{}'::jsonb, 'the labelled fixture is a valid scheduling policy');
select is((select fixture_value ->> 'zone' || '|' || (fixture_value -> 'quiet_hours')::text || '|'
                  || (fixture_value ->> 'policy_version') || '|' || (fixture_value ->> 'fixture_label' like 'TEST FIXTURE%')::text
             from app.policy_gates where gate = 'q2_church_time'),
  'Africa/Lusaka|null|1|true', 'the fixture is Africa/Lusaka, version 1, no quiet hours, labelled');
select is(pg_temp.pol() ->> 'version' || '|' || (pg_temp.pol() ->> 'source') || '|' || (pg_temp.pol() ->> 'zone'),
  '1|fixture|Africa/Lusaka', 'local scheduling uses the fixture, version 1, in Africa/Lusaka');

create temp table bad_policy (name text, patch jsonb, expect text);
insert into bad_policy values
  ('quiet hours window', '{"quiet_hours": {"start": "21:00", "end": "07:00"}}', 'quiet_hours'),
  ('no version', '{"policy_version": null}', 'policy_version'),
  ('unknown zone', '{"zone": "Mars/Olympus"}', 'zone'),
  ('bands not decreasing', '{"deadline_bands": [{"min_lead": "2 days", "before_start": "1 day"}, {"min_lead": "30 days", "before_start": "14 days"}, {"min_lead": "0 minutes", "before_start": "1 day"}]}', 'deadline_bands'),
  ('last band not zero', '{"deadline_bands": [{"min_lead": "2 days", "before_start": "1 day"}]}', 'deadline_bands'),
  ('bad default anchor', '{"default_reminders": {"response": [{"anchor": "deadline", "before": "1 hour"}], "task": []}}', 'default_reminders'),
  ('zero snooze', '{"snooze_choices": ["0 hours"]}', 'snooze_choices'),
  ('bad duration', '{"merge_window": "30 mins"}', 'merge_window'),
  ('unknown key', '{"send_at_night": false}', 'send_at_night');
select is((select string_agg(b.name, ', ') from bad_policy b
            where not (app.notifications_policy_errors(
                         (select fixture_value from app.policy_gates where gate = 'q2_church_time')
                         || b.patch) ? b.expect)),
  null, 'every malformed policy value is refused on the expected field (incl. any quiet-hours window)');

-- An approved value that is not a valid scheduling policy fails closed (rolled back below).
update app.policy_gates set state = 'approved', approved_value = '{"zone": "UTC"}',
       approved_by = 'pgtap', approved_at = now(), approval_note = 'pgtap only'
 where gate = 'q2_church_time';
select is(split_part(pg_temp.try('select app.notifications_policy()'), '|', 2) || ' '
          || ((split_part(pg_temp.try('select app.notifications_policy()'), '|', 3))::jsonb -> 'field_errors')::text,
  'unavailable {"policy": "gate_closed"}', 'an approved value without a valid schedule fails closed');
update app.policy_gates set state = 'unresolved', approved_value = null, approved_by = null,
       approved_at = null, approval_note = null where gate = 'q2_church_time';

-- Response deadlines: the four bands and creator deadlines (now = 2026-10-01T08:00:00Z) --------
create temp table deadline_cases (name text, starts text, creator text, expect text);
insert into deadline_cases values
  ('long: 45 days ahead -> 14 local days before', '2026-11-15T07:00:00Z', null, '2026-11-01T07:00:00.000000Z|default|1|false'),
  ('long: exactly 30 days', '2026-10-31T08:00:00Z', null, '2026-10-17T08:00:00.000000Z|default|1|false'),
  ('medium: 10 days -> 48 hours before', '2026-10-11T07:00:00Z', null, '2026-10-09T07:00:00.000000Z|default|2|false'),
  ('medium: just under 30 days', '2026-10-31T07:59:00Z', null, '2026-10-29T07:59:00.000000Z|default|2|false'),
  ('short: 30 hours -> 24 hours before', '2026-10-02T14:00:00Z', null, '2026-10-01T14:00:00.000000Z|default|3|false'),
  ('passed: 20 hours -> due now (short notice)', '2026-10-02T04:00:00Z', null, '2026-10-01T08:00:00.000000Z|default|3|true'),
  ('creator deadline before the start', '2026-10-11T07:00:00Z', '2026-10-05T10:00:00Z', '2026-10-05T10:00:00.000000Z|creator||false'),
  ('creator deadline at the start', '2026-10-11T07:00:00Z', '2026-10-11T07:00:00Z', '2026-10-11T07:00:00.000000Z|creator||false'),
  ('creator deadline already passed', '2026-10-11T07:00:00Z', '2026-09-30T07:00:00Z', '2026-10-01T08:00:00.000000Z|creator||true'),
  ('month end: 31 March start -> 17 March, same local time', '2026-03-31T07:00:00Z', null, null);
update deadline_cases set expect = '2026-03-17T07:00:00.000000Z|default|1|false' where expect is null;
select is((select string_agg(c.name || ' => ' || d, '; ')
             from deadline_cases c,
                  lateral (select r ->> 'response_deadline' || '|' || (r ->> 'deadline_source') || '|'
                                  || coalesce(r ->> 'band', '') || '|' || (r ->> 'short_notice') as d
                             from app.notifications_response_deadline(
                                    pg_temp.pol(),
                                    case when c.starts like '2026-03%' then '2026-01-31T08:00:00Z'::timestamptz
                                         else '2026-10-01T08:00:00Z'::timestamptz end,
                                    c.starts::timestamptz, c.creator::timestamptz,
                                    case when c.starts like '2026-03%' then '2026-01-31T08:00:00Z'::timestamptz
                                         else '2026-10-01T08:00:00Z'::timestamptz end) r) x
            where d is distinct from c.expect),
  null, 'every deadline band and creator case computes the expected deadline');
select is(pg_temp.fe($$select pg_temp.plan('response', pg_temp.ri('2026-10-11T07:00:00Z', '{"response_deadline": "2026-10-11T07:00:01Z"}'))$$),
  'validation_failed {"response_deadline": "after_start"}', 'a creator deadline after the start is refused');
select is(pg_temp.fe($$select pg_temp.plan('response', jsonb_build_object('assigned_at', '2026-10-12T08:00:00Z', 'starts_at', '2026-10-11T07:00:00Z'))$$),
  'validation_failed {"assigned_at": "after_start"}', 'an assignment after the start is refused');

-- Church-local dates ---------------------------------------------------------------------------
select is(app.notifications_local('2026-01-15T07:00:00Z', 'Africa/Lusaka') || ' ' ||
          app.notifications_local('2026-07-15T07:00:00Z', 'Africa/Lusaka'),
  '2026-01-15T09:00:00 2026-07-15T09:00:00', 'Lusaka is UTC+2 all year (no DST shift between January and July)');
select is(app.cmd_utc(app.notifications_shift('2026-03-29T07:00:00Z', '14 days', -1, 'Africa/Lusaka')) || ' ' ||
          app.cmd_utc(app.notifications_shift('2026-10-01T08:00:00Z', '48 hours', 1, 'Africa/Lusaka')),
  '2026-03-15T07:00:00.000000Z 2026-10-03T08:00:00.000000Z', 'days move on the local calendar; hours are absolute');
select is((select string_agg(o ->> 'local', ' ') from jsonb_array_elements(app.notifications_occurrences(
             pg_temp.pol(), '{"local_start": "2028-01-31T19:00:00", "every": "month"}',
             '2028-01-01T00:00:00Z', '2028-04-15T00:00:00Z')) o),
  '2028-01-31T19:00:00 2028-02-29T19:00:00 2028-03-31T19:00:00',
  'monthly from 31 January clamps to the month end (leap February) and returns to the 31st');
select is((select string_agg((o ->> 'starts_at') || '/' || (o ->> 'local'), ' ') from jsonb_array_elements(app.notifications_occurrences(
             pg_temp.pol(), '{"local_start": "2026-12-27T09:00:00", "every": "week", "exceptions": ["2027-01-03"]}',
             '2026-12-01T00:00:00Z', '2027-01-15T00:00:00Z')) o),
  '2026-12-27T07:00:00.000000Z/2026-12-27T09:00:00 2027-01-10T07:00:00.000000Z/2027-01-10T09:00:00',
  'weekly across the year end skips the exception date (recurrence exception)');
select is((select count(*)::int from jsonb_array_elements(app.notifications_occurrences(
             pg_temp.pol(), '{"local_start": "2026-10-01T09:00:00", "every": "day", "interval": 2}',
             '2026-10-02T00:00:00Z', '2026-10-09T23:00:00Z'))),
  4, 'an interval and a window: only occurrences inside the window (3, 5, 7 and 9 October)');
select is(pg_temp.fe($$select app.notifications_occurrences(pg_temp.pol(), '{"local_start": "2026-10-01T09:00:00", "every": "year", "exceptions": ["2026-02-30"]}', now(), now() + interval '1 day')$$),
  'validation_failed {"every": "invalid", "exceptions": "invalid"}', 'an invalid recurrence rule is refused');
select is(pg_temp.fe($$select app.notifications_occurrences(pg_temp.pol(), '{"local_start": "2026-10-01T09:00:00", "every": "day"}', now(), now() + interval '401 days')$$),
  'validation_failed {"window": "out_of_range"}', 'an unbounded window is refused');

-- The reminder plan ----------------------------------------------------------------------------
create temp table plan_cases (name text, type text, intent jsonb, fresh boolean, expect text);
insert into plan_cases values
  ('default offsets: 24 hours before and at the deadline', 'response', pg_temp.ri('2026-11-15T07:00:00Z'), true,
   '2026-10-31T07:00:00.000000Z=["response_deadline"] 2026-11-01T07:00:00.000000Z=["response_deadline"]'),
  ('passed offset skipped (deadline still ahead)', 'response', pg_temp.ri('2026-10-02T14:00:00Z'), true,
   '2026-10-01T14:00:00.000000Z=["response_deadline"]'),
  ('short notice, fresh: one respond-now entry', 'response', pg_temp.ri('2026-10-02T04:00:00Z'), true,
   '2026-10-01T08:00:00.000000Z=["respond_now"]'),
  ('short notice, re-plan: nothing past due is added', 'response', pg_temp.ri('2026-10-02T04:00:00Z'), false, ''),
  ('two reminders due together are merged', 'response',
   pg_temp.ri('2026-10-11T07:00:00Z', '{"response_deadline": "2026-10-10T07:00:00Z", "reminders": [{"anchor": "response_deadline", "before": "0 minutes"}, {"anchor": "starts_at", "before": "24 hours"}]}'), true,
   '2026-10-10T07:00:00.000000Z=["response_deadline", "starts_at"]'),
  ('inside the merge window: merged at the earlier instant', 'response',
   pg_temp.ri('2026-10-11T07:00:00Z', '{"response_deadline": "2026-10-10T06:40:00Z", "reminders": [{"anchor": "starts_at", "before": "24 hours"}, {"anchor": "response_deadline", "before": "0 minutes"}]}'), true,
   '2026-10-10T06:40:00.000000Z=["response_deadline", "starts_at"]'),
  ('outside the merge window: two entries', 'response',
   pg_temp.ri('2026-10-11T07:00:00Z', '{"response_deadline": "2026-10-10T06:20:00Z", "reminders": [{"anchor": "starts_at", "before": "24 hours"}, {"anchor": "response_deadline", "before": "0 minutes"}]}'), true,
   '2026-10-10T06:20:00.000000Z=["response_deadline"] 2026-10-10T07:00:00.000000Z=["starts_at"]'),
  ('after expiry dropped (expiry defaults to the start)', 'response',
   pg_temp.ri('2026-10-11T07:00:00Z', '{"reminders": [{"anchor": "starts_at", "after": "1 hour"}, {"anchor": "starts_at", "before": "2 hours"}]}'), true,
   '2026-10-11T05:00:00.000000Z=["starts_at"]'),
  ('an explicit later expiry keeps it', 'response',
   pg_temp.ri('2026-10-11T07:00:00Z', '{"expires_at": "2026-10-11T12:00:00Z", "reminders": [{"anchor": "starts_at", "after": "1 hour"}]}'), true,
   '2026-10-11T08:00:00.000000Z=["starts_at"]'),
  ('responded: response reminders stop, start reminders stay', 'response',
   pg_temp.ri('2026-10-11T07:00:00Z', '{"responded": true, "reminders": [{"anchor": "response_deadline", "before": "24 hours"}, {"anchor": "starts_at", "before": "2 hours"}]}'), true,
   '2026-10-11T05:00:00.000000Z=["starts_at"]'),
  ('responded on short notice: no respond-now', 'response', pg_temp.ri('2026-10-02T04:00:00Z', '{"responded": true}'), true, ''),
  ('creator chose no reminders', 'response', pg_temp.ri('2026-11-15T07:00:00Z', '{"reminders": []}'), true, ''),
  ('no quiet hours: 02:00 local is kept as is', 'response',
   pg_temp.ri('2026-10-11T07:00:00Z', '{"response_deadline": "2026-10-05T00:00:00Z", "reminders": [{"anchor": "response_deadline", "before": "0 minutes"}]}'), true,
   '2026-10-05T00:00:00.000000Z=["response_deadline"]'),
  ('task open: at the due time', 'task', '{"due_at": "2026-10-03T08:00:00Z", "task_state": "open"}', true,
   '2026-10-03T08:00:00.000000Z=["deadline"]'),
  ('task waiting: the review date is the deadline', 'task',
   '{"due_at": "2026-10-03T08:00:00Z", "task_state": "waiting", "review_at": "2026-10-09T06:00:00Z"}', true,
   '2026-10-09T06:00:00.000000Z=["deadline"]'),
  ('task overdue: nothing retroactive', 'task', '{"due_at": "2026-09-20T08:00:00Z", "task_state": "in_progress"}', true, ''),
  ('task waiting with a creator offset after the review date', 'task',
   '{"due_at": "2026-10-03T08:00:00Z", "task_state": "waiting", "review_at": "2026-10-09T06:00:00Z", "reminders": [{"anchor": "deadline", "after": "1 day"}]}', true,
   '2026-10-10T06:00:00.000000Z=["deadline"]');
select is((select string_agg(c.name || ' => ' || pg_temp.at(pg_temp.plan(c.type, c.intent, c.fresh)), '; ')
             from plan_cases c where pg_temp.at(pg_temp.plan(c.type, c.intent, c.fresh)) is distinct from c.expect),
  null, 'every plan case schedules the expected entries');
select is(pg_temp.plan('response', pg_temp.ri('2026-11-15T07:00:00Z')) -> 'entries' -> 0 ->> 'local',
  '2026-10-31T09:00:00', 'entries carry the church-local time');
select is(pg_temp.plan('response', pg_temp.ri('2026-11-15T07:00:00Z')) ->> 'policy_version', '1',
  'the plan records the policy version');

create temp table intent_errors (name text, type text, intent jsonb, expect text);
insert into intent_errors values
  ('task anchor on a response', 'response', pg_temp.ri('2026-11-15T07:00:00Z', '{"reminders": [{"anchor": "deadline", "before": "1 hour"}]}'), '{"reminders": "invalid"}'),
  ('both before and after', 'response', pg_temp.ri('2026-11-15T07:00:00Z', '{"reminders": [{"anchor": "starts_at", "before": "1 hour", "after": "1 hour"}]}'), '{"reminders": "invalid"}'),
  ('too many reminders', 'response', pg_temp.ri('2026-11-15T07:00:00Z', jsonb_build_object('reminders', (select jsonb_agg(jsonb_build_object('anchor', 'starts_at', 'before', g || ' hours')) from generate_series(1, 7) g))), '{"reminders": "out_of_range"}'),
  ('offset beyond the policy maximum', 'response', pg_temp.ri('2026-11-15T07:00:00Z', '{"reminders": [{"anchor": "starts_at", "before": "91 days"}]}'), '{"reminders": "out_of_range"}'),
  ('private text in the intent', 'response', pg_temp.ri('2026-11-15T07:00:00Z', '{"note": "call Mrs X"}'), '{"note": "unknown_field"}'),
  ('local time instead of an instant', 'response', '{"assigned_at": "2026-10-01T08:00:00Z", "starts_at": "2026-11-15T09:00:00"}', '{"starts_at": "invalid"}'),
  ('waiting without a review date', 'task', '{"due_at": "2026-10-03T08:00:00Z", "task_state": "waiting"}', '{"review_at": "required"}'),
  ('review date on an open task', 'task', '{"due_at": "2026-10-03T08:00:00Z", "task_state": "open", "review_at": "2026-10-09T06:00:00Z"}', '{"review_at": "must_be_null"}'),
  ('unknown task state', 'task', '{"due_at": "2026-10-03T08:00:00Z", "task_state": "done"}', '{"task_state": "invalid"}');
select is((select string_agg(c.name || ' => ' || pg_temp.fe(format('select pg_temp.plan(%L, %L)', c.type, c.intent)), '; ')
             from intent_errors c
            where pg_temp.fe(format('select pg_temp.plan(%L, %L)', c.type, c.intent)) <> 'validation_failed ' || c.expect),
  null, 'every malformed intent is refused on the expected field');

-- Snooze calculation ---------------------------------------------------------------------------
select is(app.notifications_snooze_at(pg_temp.pol(), '24 hours', '2026-10-01T08:00:00Z', '2026-10-03T08:00:00Z'),
  '{"clamped": false, "scheduled_at": "2026-10-02T08:00:00.000000Z"}'::jsonb, 'a snooze inside the expiry fires after the chosen time');
select is(app.notifications_snooze_at(pg_temp.pol(), '2 days', '2026-10-01T08:00:00Z', '2026-10-02T08:00:00Z'),
  '{"clamped": true, "scheduled_at": "2026-10-02T08:00:00.000000Z"}'::jsonb, 'a snooze past the expiry is clamped to it');
select is(app.notifications_snooze_at(pg_temp.pol(), '1 hour', '2026-10-01T23:30:00Z', null),
  '{"clamped": false, "scheduled_at": "2026-10-02T00:30:00.000000Z"}'::jsonb, 'a snooze lands at night too (no quiet hours)');
select is(pg_temp.fe($$select app.notifications_snooze_at(pg_temp.pol(), '3 hours', now(), null)$$),
  'validation_failed {"choice": "invalid"}', 'a choice outside the policy is refused');
select is(pg_temp.fe($$select app.notifications_snooze_at(pg_temp.pol(), '1 hour', now(), now())$$),
  'conflict {"item_id": "expired"}', 'an expired reminder cannot be snoozed');

-- Schedules and reconciliation (relative to now()) --------------------------------------------
select app.contract_register_reminder_kind('fixture', 'fixture_reminder', 'fixture_response');
select app.contract_register_reminder_kind('fixture', 'fixture_reminder', 'fixture_upcoming');
select app.contract_register_reminder_contract('fixture', 'fixture_reminder', k,
         'app.fixture_reminder_open_check(jsonb)'::regprocedure,
         '{"title": "SYNTHETIC test reminder", "body": "A test reminder is waiting for you.", "link": "/fixture/reminders/{source_id}"}')
  from unnest(array['fixture_response', 'fixture_upcoming']) k;

create temp table r (k text primary key, v jsonb);
insert into r values ('S1a', pg_temp.sched('S1', 1, 'response',
  jsonb_build_object('assigned_at', app.cmd_utc(now()), 'starts_at', pg_temp.rel('45 days'))));
select is((select (v ->> 'enqueued') || '|' || (v ->> 'policy_version') || '|' || (v ->> 'cancelled') from r where k = 'S1a'),
  '2|1|0', 'a long-lead schedule enqueues its two reminders under policy version 1');
select is(pg_temp.jobs('S1'), 'fixture_response@r1+720h fixture_response@r1+744h',
  'the reminders are 24 hours before and at the default deadline (14 days before the start)');
select is((select count(*)::int from app.notifications_jobs j
            join app.notifications_schedules s on s.schedule_id = j.schedule_id
           where j.source_id = (select id from src where k = 'S1') and j.policy_version = 1
             and j.expires_at = now() + interval '45 days' and s.schedule_state = 'active'),
  2, 'jobs record the policy version, the expiry (the start) and their schedule');
select is(pg_temp.sched('S1', 1, 'response', jsonb_build_object('assigned_at', app.cmd_utc(now()), 'starts_at', pg_temp.rel('45 days'))) ->> 'enqueued',
  '0', 'repeating the same schedule enqueues nothing');
select is(pg_temp.jobs('S1'), 'fixture_response@r1+720h fixture_response@r1+744h', 'still exactly two jobs');

-- A material change: new revision and a creator deadline.
update app.fixture_reminder_sources set revision = 2 where source_id = (select id from src where k = 'S1');
select is(pg_temp.fe($$select pg_temp.sched('S1', 1, 'response', jsonb_build_object('assigned_at', app.cmd_utc(now()), 'starts_at', pg_temp.rel('45 days')))$$),
  'conflict {}', 'a schedule for a stale source revision is refused');
select is(pg_temp.sched('S1', 2, 'response', jsonb_build_object('assigned_at', app.cmd_utc(now()), 'starts_at', pg_temp.rel('45 days'),
            'response_deadline', pg_temp.rel('10 days'))) ->> 'cancelled', '2',
  'the change cancels the old revision''s reminders');
select is(pg_temp.jobs('S1') || ' / ' || pg_temp.jobs('S1', 'cancelled'),
  'fixture_response@r2+216h fixture_response@r2+240h / fixture_response@r1+720h fixture_response@r1+744h',
  'and schedules the new revision against the creator deadline');
select is((select string_agg(distinct cancel_reason, ',') from app.notifications_jobs
            where source_id = (select id from src where k = 'S1') and job_state = 'cancelled'),
  'rescheduled', 'the old jobs are cancelled as rescheduled');

-- Short notice: ask for a response now, once per revision.
insert into r values ('S2a', pg_temp.sched('S2', 1, 'response',
  jsonb_build_object('assigned_at', app.cmd_utc(now()), 'starts_at', pg_temp.rel('20 hours'))));
select is((select (v -> 'plan' ->> 'short_notice') || '|' || (v ->> 'enqueued') from r where k = 'S2a'), 'true|1',
  'a short-notice schedule enqueues one reminder');
select is(pg_temp.jobs('S2'), 'fixture_response@r1+0h', 'the response is asked for now');
select is(pg_temp.sched('S2', 1, 'response', jsonb_build_object('assigned_at', app.cmd_utc(now()), 'starts_at', pg_temp.rel('20 hours'))) ->> 'enqueued',
  '0', 'a repeated fresh schedule does not ask again');

-- Kinds and shape checks.
select is(pg_temp.fe($$select pg_temp.sched('S3', 1, 'response', jsonb_build_object('assigned_at', app.cmd_utc(now()), 'starts_at', pg_temp.rel('10 days'), 'reminders', '[{"anchor": "starts_at", "before": "2 hours"}]'::jsonb), '{"response_deadline": "fixture_response"}')$$),
  'validation_failed {"kinds": "required"}', 'an entry whose anchor has no kind is refused');
select is(pg_temp.fe($$select pg_temp.sched('S3', 1, 'response', jsonb_build_object('assigned_at', app.cmd_utc(now()), 'starts_at', pg_temp.rel('10 days')), '{"response_deadline": "fixture_unknown"}')$$),
  'validation_failed {"kinds": "unregistered"}', 'an unregistered kind is refused');
select is(pg_temp.fe($$select pg_temp.sched('T1', 1, 'task', '{"due_at": "2030-01-01T00:00:00Z", "task_state": "open"}', '{"deadline": "fixture_due", "respond_now": "fixture_due"}')$$),
  'validation_failed {"kinds": "invalid"}', 'respond_now is not a task anchor');
select is((split_part(pg_temp.try($$select app.notifications_set_schedule('{"source_type": "fixture_reminder", "body": "x"}')$$), '|', 3))::jsonb -> 'field_errors',
  '{"body": "unknown_field", "kinds": "invalid", "source_id": "required", "recipient_member_id": "required", "schedule_type": "invalid", "source_revision": "required"}'::jsonb,
  'a malformed schedule is refused field by field');
select is((select count(*)::int from app.notifications_schedules where source_id = (select id from src where k = 'S3')),
  0, 'a refused schedule writes nothing');

-- S3: deadline 6 hours ahead (the 24-hours-before reminder has passed).
insert into r values ('S3a', pg_temp.sched('S3', 1, 'response',
  jsonb_build_object('assigned_at', app.cmd_utc(now()), 'starts_at', pg_temp.rel('30 hours'))));
select is(pg_temp.jobs('S3'), 'fixture_response@r1+6h', 'a passed offset is skipped; only the deadline reminder remains');
-- S4 goes stale (revision moved without re-planning); S5 is cancelled by its source.
insert into r values ('S4a', pg_temp.sched('S4', 1, 'response',
  jsonb_build_object('assigned_at', app.cmd_utc(now()), 'starts_at', pg_temp.rel('10 days'))));
update app.fixture_reminder_sources set revision = 2 where source_id = (select id from src where k = 'S4');
insert into r values ('S5a', pg_temp.sched('S5', 1, 'response',
  jsonb_build_object('assigned_at', app.cmd_utc(now()), 'starts_at', pg_temp.rel('10 days'))));
select is(app.notifications_cancel(jsonb_build_object('source_type', 'fixture_reminder',
            'source_id', (select id from src where k = 'S5'), 'reason', 'source_cancelled')) ->> 'cancelled',
  '2', 'the source cancels S5''s jobs');
select is((select schedule_state || '|' || end_reason from app.notifications_schedules
            where source_id = (select id from src where k = 'S5')),
  'ended|source_cancelled', 'and its schedule ends with them');

-- Task with a Waiting review date.
insert into r values ('T1a', pg_temp.sched('T1', 1, 'task',
  jsonb_build_object('due_at', pg_temp.rel('1 day'), 'task_state', 'waiting', 'review_at', pg_temp.rel('5 days')),
  '{"deadline": "fixture_due"}'));
select is(pg_temp.jobs('T1'), 'fixture_due@r1+120h', 'a Waiting task is reminded at its review date');

-- A direct enqueue (story 3.1 path) also records the policy version.
insert into r values ('direct', app.notifications_enqueue(jsonb_build_object(
  'source_type', 'fixture_reminder', 'source_id', (select id from src where k = 'S4'),
  'source_revision', 2, 'recipient_member_id', (select member_id from m where n = 1),
  'reminder_kind', 'fixture_due', 'scheduled_at', pg_temp.rel('3 days'))));
select is((select j.policy_version from app.notifications_jobs j
            where j.job_id = (select (v ->> 'job_id')::uuid from r where k = 'direct')),
  1, 'a direct enqueue records the policy version too');

-- A policy change moves future jobs and never enqueues past-due ones ---------------------------
create temp table due_before as
  select job_id from app.notifications_jobs where job_state = 'pending' and scheduled_at <= now();
update app.policy_gates
   set fixture_value = jsonb_set(jsonb_set(fixture_value, '{policy_version}', '2'),
         '{default_reminders,response}',
         '[{"anchor": "response_deadline", "before": "48 hours"}, {"anchor": "response_deadline", "before": "0 minutes"}]')
 where gate = 'q2_church_time';
insert into r values ('replan2', app.notifications_replan_all('policy_changed'));
select is((select v - 'enqueued' - 'cancelled' from r where k = 'replan2'),
  '{"policy_version": 2, "replanned": 4, "stale": 1, "failed": 0}'::jsonb,
  'the re-plan covers the four current schedules; the moved S4 becomes stale; S5 stays ended');
select is(pg_temp.jobs('S1'), 'fixture_response@r2+192h fixture_response@r2+240h',
  'S1: the 24-hour reminder moved to 48 hours before; the deadline reminder stays');
select is(pg_temp.jobs('S3'), 'fixture_response@r1+6h',
  'S3: the new 48-hours-before offset is already past and is not enqueued');
select is(pg_temp.jobs('S2'), 'fixture_response@r1+0h',
  'S2: the due respond-now job stays and no second one is created');
select is((select count(*)::int from app.notifications_jobs j
            where j.job_state = 'pending' and j.scheduled_at <= now()
              and j.job_id not in (select job_id from due_before)),
  0, 'no past-due job was created by the re-plan');
select is((select count(*)::int from app.notifications_jobs
            where source_id in (select id from src where k in ('S1', 'S3')) and job_state = 'pending'
              and policy_version = 2),
  3, 'the jobs in the new plan apply policy version 2');
select is(pg_temp.jobs('S5') || '|' || (select schedule_state from app.notifications_schedules
                                         where source_id = (select id from src where k = 'S4')),
  '|stale', 'the ended schedule is not revived; the moved source is marked stale');
select is((select count(*)::int from app.notifications_schedules where policy_version = 2 and schedule_state = 'active'),
  4, 'the active schedules record policy version 2');

-- Back to the version 1 offsets (as version 3): the cancelled 24-hour job is reinstated, once.
update app.policy_gates
   set fixture_value = jsonb_set(jsonb_set(fixture_value, '{policy_version}', '3'),
         '{default_reminders,response}',
         '[{"anchor": "response_deadline", "before": "24 hours"}, {"anchor": "response_deadline", "before": "0 minutes"}]')
 where gate = 'q2_church_time';
insert into r values ('replan3', app.notifications_replan_all('policy_changed'));
select is(pg_temp.jobs('S1'), 'fixture_response@r2+216h fixture_response@r2+240h', 'S1 is back on 24 hours before');
select is((select count(*)::int from app.notifications_jobs
            where source_id = (select id from src where k = 'S1') and source_revision = 2
              and scheduled_at = now() + interval '216 hours'),
  1, 'the earlier job was reinstated, not duplicated (one logical key, one job)');

-- Snooze (owner operation) ---------------------------------------------------------------------
select is((app.notifications_sys_deliver_due(gen_random_uuid(), gen_random_uuid(), '{}') -> 'data' ->> 'delivered')::int >= 1,
  true, 'the due respond-now reminder is delivered to the inbox');
create temp table it as
  select i.item_id from app.notifications_inbox_items i join app.notifications_jobs j on j.job_id = i.job_id
   where j.source_id = (select id from src where k = 'S2');
select is((select count(*)::int from it), 1, 'S2 has one inbox item');
select is(app.notifications_snooze_item((select member_id from m where n = 1), (select item_id from it), '1 hour') ->> 'clamped',
  'false', 'the member snoozes it for 1 hour');
select is(pg_temp.jobs('S2'), 'fixture_response@r1+1h', 'one pending reminder for this member an hour from now');
select is(app.notifications_snooze_item((select member_id from m where n = 1), (select item_id from it), '2 days')
            - 'scheduled_at',
  jsonb_build_object('clamped', true, 'expires_at', pg_temp.rel('20 hours')),
  'a 2-day snooze is clamped to the expiry (the start, 20 hours ahead)');
select is(pg_temp.jobs('S2') || ' / ' || (select string_agg(cancel_reason, ',') from app.notifications_jobs
                                          where snoozed_from_item_id = (select item_id from it) and job_state = 'cancelled'),
  'fixture_response@r1+20h / snooze_replaced', 'the new snooze replaces the earlier one');
select is(pg_temp.fe(format('select app.notifications_snooze_item(%L, %L, %L)', (select member_id from m where n = 2), (select item_id from it), '1 hour')),
  'not_found {}', 'another member cannot snooze the item');
select is(pg_temp.fe(format('select app.notifications_snooze_item(%L, %L, %L)', (select member_id from m where n = 1), (select item_id from it), '5 minutes')),
  'validation_failed {"choice": "invalid"}', 'a choice outside the policy is refused');
select is((select count(*)::int from app.notifications_jobs
            where source_id = (select id from src where k = 'S2') and recipient_member_id <> (select member_id from m where n = 1)),
  0, 'snoozing touched no other recipient');
-- The source changes: the snooze is superseded and goes with the old revision.
update app.fixture_reminder_sources set revision = 2 where source_id = (select id from src where k = 'S2');
select is(pg_temp.fe(format('select app.notifications_snooze_item(%L, %L, %L)', (select member_id from m where n = 1), (select item_id from it), '1 hour')),
  'conflict {"item_id": "superseded"}', 'a superseded item cannot be snoozed');
select is(pg_temp.sched('S2', 2, 'response', jsonb_build_object('assigned_at', app.cmd_utc(now()), 'starts_at', pg_temp.rel('20 hours'), 'responded', true)) ->> 'entries',
  '0', 'the member responded at revision 2: no response reminders remain');
select is(pg_temp.jobs('S2') || ' / ' || (select cancel_reason from app.notifications_jobs
                                          where snoozed_from_item_id = (select item_id from it)
                                          order by finished_at desc limit 1),
  ' / source_revised', 'the pending snooze is cancelled with the old revision');

-- Guards and privileges ------------------------------------------------------------------------
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned objects');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function is pinned');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select ok(not exists (
  select 1 from unnest(array['anon', 'authenticated', 'service_role']) r
   cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
   where has_table_privilege(r, 'app.notifications_schedules', p)),
  'no client role has any privilege on schedules');
select ok(not exists (
  select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   cross join unnest(array['anon', 'authenticated', 'service_role']) r
   where n.nspname = 'app' and p.proname ~ '^notifications_'
     and p.proname not in ('notifications_my_inbox', 'notifications_open_item')
     and has_function_privilege(r, p.oid, 'EXECUTE')),
  'no scheduling function is client-executable');
select is((select count(*)::int from information_schema.columns
            where table_schema = 'app' and table_name = 'notifications_schedules'
              and column_name ~ '(text|body|title|note|name)'),
  0, 'a schedule has no text column');

select * from finish();
rollback;
