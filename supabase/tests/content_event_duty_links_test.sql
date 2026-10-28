-- Story 6.12: duties linked to published events. The Duties contract change (event_ref must name
-- a published event of a registered event link source, through app.contract_check_source), the
-- content_event source type and link source, the editors' linked-duty count, and the review flags
-- with the 4.16 notice (one per department, reachable leaders and deputies other than the editor)
-- when a published event's time or place changes or it is withdrawn or archived; no duty is
-- republished and no answer is reset; the public event read names no duty. HTTP evidence:
-- tools/identity-e2e/content-event-duty-links.mjs. Every account, phone and name is SYNTHETIC
-- (fictional range +1 202 555 0181-0188). Times are church time (Africa/Lusaka).
begin;
select plan(47);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000612' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000612' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '120255501' || (80 + n)::text $$;
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
create function pg_temp.call(n int, p_endpoint text, p_command text, p_expected bigint, p_payload jsonb)
returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  execute format('select api.%I($1)', p_endpoint) into r using jsonb_build_object(
    'version', 1, 'command', p_command, 'request_id', gen_random_uuid(),
    'expected_revision', p_expected, 'payload', p_payload);
  reset role;
  return r;
end;
$$;
create function pg_temp.cmd(n int, p_command text, p_expected bigint, p_payload jsonb)
returns jsonb language sql as
$$ select pg_temp.call(n, 'content_command', p_command, p_expected, p_payload) $$;
create function pg_temp.duties(n int, p_command text, p_expected bigint, p_payload jsonb)
returns jsonb language sql as
$$ select pg_temp.call(n, 'duties_command', p_command, p_expected, p_payload) $$;
create function pg_temp.err(r jsonb) returns text language sql as $$
  select coalesce(r ->> 'code', 'ok') || coalesce('|' || (select string_agg(k || '=' || v, ',' order by k)
                                                           from jsonb_each_text(r -> 'field_errors') f(k, v)), '')
$$;
-- A read as account n (or anon when n is null): its JSON, or 'SQLSTATE|message|detail'.
create function pg_temp.read(n int, p_sql text) returns jsonb
language plpgsql as $$
declare
  r jsonb;
  v_state text; v_msg text; v_detail text;
begin
  if n is null then
    perform set_config('request.jwt.claims', '{"role": "anon"}', true);
    set local role anon;
  else
    perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
    set local role authenticated;
  end if;
  begin
    execute p_sql into r;
    reset role;
    return r;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
    reset role;
    return to_jsonb(v_state || '|' || v_msg || '|' || coalesce(v_detail, ''));
  end;
end;
$$;
create function pg_temp.at(p_days int, p_time text default '10:00') returns timestamptz language sql as
$$ select (((now() at time zone 'Africa/Lusaka')::date + p_days) + p_time::time) at time zone 'Africa/Lusaka' $$;
create function pg_temp.iso(p timestamptz) returns text language sql as
$$ select to_char(p at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') $$;
create function pg_temp.ev(p_title text, p_from timestamptz, p_place text default 'SYNTHETIC Main hall')
returns jsonb language sql as $$
  select jsonb_build_object('title', p_title, 'description', 'SYNTHETIC service for testing.',
                            'starts_at', pg_temp.iso(p_from), 'ends_at', pg_temp.iso(p_from + interval '2 hours'),
                            'location', p_place)
$$;
create function pg_temp.rev(p uuid) returns bigint language sql as
$$ select revision from app.content_items where item_id = p $$;

-- Accounts: 1 Admin; 2 Media (event editor, no Duties scope); 3 leader L of the Preaching Rota
-- (D); 4 deputy P of D; 5 member M of D; 6 leader K of the Ushers (E); 7 member N of E.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', pg_temp.phone(n), now() from generate_series(1, 7) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 7) n;
select app.platform_set_environment('local', 'pgtap 6.12');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 6.12 Member ' || n, 'pgtap 6.12')
  from generate_series(1, 7) n;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
create function pg_temp.who(p uuid) returns int language sql as $$ select n from m where member_id = p $$;
create function pg_temp.grev(n int) returns bigint language sql as
$$ select revision from app.identity_grant_sets where member_id = pg_temp.mid($1) $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(2), 'media', 'israel');

create function pg_temp.dep(p_name text) returns uuid language sql as $$
  select (pg_temp.duties(1, 'duties.create_department', null, jsonb_build_object('name', p_name))
          #>> '{data,department_id}')::uuid
$$;
create temp table deps as select pg_temp.dep('SYNTHETIC Preaching Rota') as d, pg_temp.dep('SYNTHETIC 6.12 Ushers') as e;
create function pg_temp.d() returns uuid language sql as $$ select d from deps $$;
create function pg_temp.e() returns uuid language sql as $$ select e from deps $$;
create function pg_temp.drev(p uuid) returns bigint language sql as
$$ select revision from app.duties_departments where department_id = p $$;
create function pg_temp.grant_scope(p_member int, p_kind text, p_scope uuid) returns jsonb language sql as $$
  select pg_temp.call(1, 'identity_grant_command', 'identity.grant_scope', pg_temp.grev(p_member),
    jsonb_build_object('member_id', pg_temp.mid(p_member), 'scope_kind', p_kind, 'scope_id', p_scope))
$$;
create function pg_temp.add(n int, p_department uuid) returns jsonb language sql as $$
  select pg_temp.duties(1, 'duties.add_member', pg_temp.drev(p_department),
    jsonb_build_object('department_id', p_department, 'member_id', pg_temp.mid(n)))
$$;
select pg_temp.grant_scope(3, 'department_leader', pg_temp.d());
select pg_temp.grant_scope(4, 'department_deputy', pg_temp.d());
select pg_temp.grant_scope(6, 'department_leader', pg_temp.e());
select pg_temp.add(n, pg_temp.d()) from unnest(array[3, 5]) n;
select pg_temp.add(n, pg_temp.e()) from unnest(array[6, 7]) n;

create temp table pubs (tag text primary key, r jsonb);
create function pg_temp.pub(p_tag text, p_member int, p_days int, p_leader int, p_department uuid)
returns jsonb language plpgsql as $$
declare
  r jsonb;
begin
  r := pg_temp.duties(p_leader, 'duties.publish_duty', null, jsonb_build_object(
         'department_id', p_department, 'member_id', pg_temp.mid(p_member),
         'duty_name', 'SYNTHETIC Duty ' || p_tag, 'location', 'SYNTHETIC hall',
         'starts_at', app.cmd_utc(pg_temp.at(p_days))));
  if r ->> 'code' is not null then
    raise exception 'publish % failed: %', p_tag, r;
  end if;
  insert into pubs values (p_tag, r);
  return r;
end;
$$;
create function pg_temp.occ(p_tag text) returns uuid language sql as
$$ select (r #>> '{data,occurrence_id}')::uuid from pubs where tag = p_tag $$;
create function pg_temp.asg(p_tag text) returns uuid language sql as
$$ select (r #>> '{data,assignment_id}')::uuid from pubs where tag = p_tag $$;
create function pg_temp.orev(p_occ uuid) returns bigint language sql as
$$ select revision from app.duties_occurrences where occurrence_id = p_occ $$;
create function pg_temp.link(p_tag text, p_leader int, p_event uuid) returns jsonb language sql as $$
  select pg_temp.duties(p_leader, 'duties.revise_duty', pg_temp.orev(pg_temp.occ(p_tag)), jsonb_build_object(
    'occurrence_id', pg_temp.occ(p_tag), 'event_ref', p_event))
$$;
create function pg_temp.flags(p_tag text) returns text language sql as $$
  select coalesce(string_agg(array_to_string(f.changed, '+') || '@' || f.revision, ','), 'none')
    from app.duties_review_flags f where f.occurrence_id = pg_temp.occ(p_tag) and f.cleared_at is null
$$;
-- The review notices: recipient:flagged duty@flag revision.
create function pg_temp.notices() returns text language sql as $$
  select coalesce(string_agg(pg_temp.who(j.recipient_member_id)::text || ':'
                             || (select p.tag from pubs p join app.duties_review_flags f
                                   on f.occurrence_id = (p.r #>> '{data,occurrence_id}')::uuid
                                  where f.flag_id = j.source_id) || '@' || j.source_revision, ','
                             order by pg_temp.who(j.recipient_member_id), j.source_revision), '')
    from app.notifications_jobs j
   where j.source_type = 'duties_review' and j.reminder_kind = 'duty_review_flagged'
$$;
create function pg_temp.count(n int, p_event uuid) returns jsonb language sql as
$$ select pg_temp.read(n, format('select api.content_staff_event_duty_links(%L::uuid)', p_event)) $$;

create temp table v (k text primary key, id uuid);
create function pg_temp.e(p_k text) returns uuid language sql as $$ select id from v where k = p_k $$;
insert into v select 'e1', (pg_temp.cmd(2, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Sunday service', pg_temp.at(20))) #>> '{data,event_id}')::uuid;
insert into v select 'e2', (pg_temp.cmd(2, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Youth evening', pg_temp.at(21))) #>> '{data,event_id}')::uuid;
insert into v select 'e3', (pg_temp.cmd(2, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Draft retreat', pg_temp.at(22))) #>> '{data,event_id}')::uuid;
select pg_temp.pub('X', 5, 20, 3, pg_temp.d());
select pg_temp.pub('Z', 5, 21, 3, pg_temp.d());
select pg_temp.pub('Y', 7, 20, 6, pg_temp.e());

-- Registries and privileges -------------------------------------------------------------------
select is((select module || ':' || check_hook from app.contract_source_types where source_type = 'content_event'),
  'content:app.content_event_source_check(jsonb)', 'Content owns the content_event source type with its check hook');
select is((select module || ':' || role from app.duties_link_sources where source_type = 'content_event'),
  'content:event', 'content_event is registered with Duties as the event link source');
select is((select count(*)::int from pg_trigger t join pg_class c on c.oid = t.tgrelid
            where t.tgname in ('duties_occurrences_event_ref', 'duties_series_event_ref')
              and c.relname in ('duties_occurrences', 'duties_series')), 2,
  'occurrences and series check every event_ref they set');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('app', 'api')
              and p.proname in ('duties_event_ref_error', 'duties_occurrence_event_ref_guard',
                                'duties_series_event_ref_guard', 'content_event_source_check',
                                'content_event_flag_duties', 'content_event_changes',
                                'content_staff_event_duty_links')
              and has_function_privilege('anon', p.oid, 'EXECUTE')), 0, 'anon executes none of the new functions');
select results_eq(
  $$select (n.nspname || '.' || p.proname)::text collate "C" from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'api')
       and p.proname in ('duties_event_ref_error', 'duties_occurrence_event_ref_guard',
                         'duties_series_event_ref_guard', 'content_event_source_check',
                         'content_event_flag_duties', 'content_event_changes',
                         'content_staff_event_duty_links')
       and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     order by 1$$,
  $$values ('api.content_staff_event_duty_links'::text collate "C"), ('app.content_staff_event_duty_links')$$,
  'authenticated executes only the editors'' count read');
select is_definer('app', 'content_staff_event_duty_links', array['uuid'], 'the count read body is a definer');
select isnt_definer('api', 'content_staff_event_duty_links', array['uuid'], 'its api wrapper is invoker');

-- Only a published event can be linked -----------------------------------------------------------
select is(pg_temp.err(pg_temp.link('X', 3, pg_temp.e('e1'))), 'validation_failed|event_ref=not_published',
  'a draft event cannot be linked');
select is(pg_temp.err(pg_temp.link('X', 3, gen_random_uuid())), 'validation_failed|event_ref=not_published',
  'an unknown id cannot be linked');
select is(pg_temp.err(pg_temp.link('X', 3, pg_temp.d())), 'validation_failed|event_ref=not_published',
  'another kind of id (a department) cannot be linked');
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_event', pg_temp.rev(pg_temp.e(k)),
            jsonb_build_object('event_id', pg_temp.e(k)))), 'ok', 'Media publishes ' || k)
  from unnest(array['e1', 'e2']) k;
select is((app.content_event_source_check(jsonb_build_object('source_type', 'content_event',
            'source_id', pg_temp.e('e1'), 'source_revision', 1))), '{"current": true, "revision": 1}'::jsonb,
  'the check hook: a published event is current at its live revision number');
select is((app.content_event_source_check(jsonb_build_object('source_type', 'content_event',
            'source_id', pg_temp.e('e3'), 'source_revision', 1))), '{"current": false, "revision": null}'::jsonb,
  'the check hook: a draft reveals no revision');
create temp table xbefore as select a.response, a.revision as arev, o.revision as orev
  from app.duties_assignments a join app.duties_slots s using (slot_id) join app.duties_occurrences o using (occurrence_id)
 where a.assignment_id = pg_temp.asg('X');
select is(array[pg_temp.link('X', 3, pg_temp.e('e1')) #>> '{data,change}', pg_temp.link('Y', 6, pg_temp.e('e1')) #>> '{data,change}',
                pg_temp.link('Z', 3, pg_temp.e('e2')) #>> '{data,change}'],
  array['reference', 'reference', 'reference'], 'leaders link X and Y to the Sunday service and Z to the youth evening');
select is((select count(*)::int from app.notifications_jobs j where j.source_type = 'duties_assignment'
            and j.reminder_kind = 'duty_updated' and j.recipient_member_id = pg_temp.mid(5)), 0,
  'linking sends the member no update notice');
select is((select x ->> 'event_ref' from jsonb_array_elements(pg_temp.read(5, 'select api.duties_my_duties()') -> 'assignments') x
            where x ->> 'assignment_id' = pg_temp.asg('X')::text), pg_temp.e('e1')::text,
  'the member''s duty detail carries the linked event');
select is(pg_temp.err(pg_temp.duties(3, 'duties.revise_duty', pg_temp.orev(pg_temp.occ('Z')), jsonb_build_object(
            'occurrence_id', pg_temp.occ('Z'), 'event_ref', null))), 'ok', 'clearing a link is always allowed');
select is(pg_temp.link('Z', 3, pg_temp.e('e2')) #>> '{data,change}', 'reference', 'and Z is linked again');

-- The editors' count, before a change ------------------------------------------------------------
select is(pg_temp.count(2, pg_temp.e('e1')) - 'event_id',
  '{"linked_duties": 2, "reviews_open": 0, "truncated": false}'::jsonb,
  'Media sees two duties linked to the Sunday service (counts only)');
select is(pg_temp.count(1, pg_temp.e('e2')) -> 'linked_duties', '1'::jsonb, 'the Admin sees one for the youth evening');
select is(pg_temp.count(2, pg_temp.e('e3')) -> 'linked_duties', '0'::jsonb, 'none for the draft');
select is(pg_temp.count(2, gen_random_uuid()) -> 'linked_duties', 'null'::jsonb, 'an unknown event answers null');
select is(pg_temp.count(3, pg_temp.e('e1')) #>> '{}', 'PT403|forbidden|not_granted',
  'a department leader who edits no events cannot read it');
select is(left(pg_temp.count(null, pg_temp.e('e1')) #>> '{}', 5), '42501', 'anon cannot call it');

-- A time change: flagged once per department, nothing of the duty changes --------------------------
select is(pg_temp.err(pg_temp.cmd(2, 'content.save_event', pg_temp.rev(pg_temp.e('e1')),
            jsonb_build_object('event_id', pg_temp.e('e1')) || pg_temp.ev('SYNTHETIC Sunday service', pg_temp.at(20, '11:00')))),
  'ok', 'Media saves a new time for the Sunday service');
select is(pg_temp.flags('X'), 'none', 'saving a draft flags nothing');
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_event', pg_temp.rev(pg_temp.e('e1')),
            jsonb_build_object('event_id', pg_temp.e('e1')))), 'ok', 'and publishes it');
select is(array[pg_temp.flags('X'), pg_temp.flags('Y'), pg_temp.flags('Z')], array['time@1', 'time@1', 'none'],
  'the two linked duties are flagged for a time change; the other event''s duty is not');
select is(pg_temp.notices(), '3:X@1,4:X@1,6:Y@1',
  'one notice per department: the Preaching Rota''s leader and deputy and the Ushers'' leader');
select is((select count(*)::int from app.notifications_jobs where source_type = 'duties_review'
            and recipient_member_id in (pg_temp.mid(1), pg_temp.mid(2), pg_temp.mid(5), pg_temp.mid(7))), 0,
  'the editor, the Admin and the members get no review notice');
select is((select array[a.response, a.revision::text, o.revision::text]
             from app.duties_assignments a join app.duties_slots s using (slot_id) join app.duties_occurrences o using (occurrence_id)
            where a.assignment_id = pg_temp.asg('X')),
  (select array[response, arev::text, (orev + 1)::text] from xbefore),
  'no duty is republished and no answer is reset (the occurrence moved only for its link)');
select is(pg_temp.count(2, pg_temp.e('e1')) -> 'reviews_open', '2'::jsonb, 'the editor now sees two open reviews');

-- A title-only change flags nothing; a place change merges ---------------------------------------------
select is(pg_temp.err(pg_temp.cmd(2, 'content.save_event', pg_temp.rev(pg_temp.e('e1')),
            jsonb_build_object('event_id', pg_temp.e('e1')) || pg_temp.ev('SYNTHETIC Sunday service (renamed)', pg_temp.at(20, '11:00')))),
  'ok', 'Media renames the Sunday service');
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_event', pg_temp.rev(pg_temp.e('e1')),
            jsonb_build_object('event_id', pg_temp.e('e1')))) || '|' || pg_temp.flags('X'), 'ok|time@1',
  'a title change is not a time, place or cancellation change');
select pg_temp.cmd(2, 'content.save_event', pg_temp.rev(pg_temp.e('e1')),
  jsonb_build_object('event_id', pg_temp.e('e1')) || pg_temp.ev('SYNTHETIC Sunday service (renamed)', pg_temp.at(20, '11:00'), 'SYNTHETIC Tent'));
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_event', pg_temp.rev(pg_temp.e('e1')),
            jsonb_build_object('event_id', pg_temp.e('e1')))) || '|' || pg_temp.flags('X') || '|' || pg_temp.flags('Y'),
  'ok|place+time@2|place+time@2', 'a place change merges into the open flags');
select is((select count(*)::int from app.notifications_jobs where source_type = 'duties_review'), 6,
  'and sends a fresh notice per department (three more)');

-- Cancellation: withdrawing and archiving a published event ---------------------------------------------
select is(pg_temp.err(pg_temp.cmd(2, 'content.withdraw_event', pg_temp.rev(pg_temp.e('e2')),
            jsonb_build_object('event_id', pg_temp.e('e2')))) || '|' || pg_temp.flags('Z'), 'ok|cancelled@1',
  'withdrawing the youth evening flags its duty as cancelled');
select is((select count(*)::int from app.notifications_jobs where source_type = 'duties_review'
            and recipient_member_id in (pg_temp.mid(3), pg_temp.mid(4))
            and source_id = (select flag_id from app.duties_review_flags where occurrence_id = pg_temp.occ('Z'))), 2,
  'the Preaching Rota''s leader and deputy are told once each');
select is((select event_ref from app.duties_occurrences where occurrence_id = pg_temp.occ('Z')), pg_temp.e('e2'),
  'the duty keeps its link');
select is(pg_temp.err(pg_temp.link('X', 3, pg_temp.e('e2'))), 'validation_failed|event_ref=not_published',
  'a withdrawn event cannot be newly linked');
select is(pg_temp.err(pg_temp.duties(3, 'duties.revise_duty', pg_temp.orev(pg_temp.occ('Z')), jsonb_build_object(
            'occurrence_id', pg_temp.occ('Z'), 'location', 'SYNTHETIC Side room'))), 'ok',
  'a duty whose event was withdrawn can still be edited');
select is(pg_temp.err(pg_temp.cmd(2, 'content.archive_event', pg_temp.rev(pg_temp.e('e2')),
            jsonb_build_object('event_id', pg_temp.e('e2')))) || '|' || pg_temp.flags('Z'), 'ok|cancelled@1',
  'archiving the withdrawn event flags nothing more');
select is(pg_temp.err(pg_temp.cmd(2, 'content.archive_event', pg_temp.rev(pg_temp.e('e1')),
            jsonb_build_object('event_id', pg_temp.e('e1')))) || '|' || pg_temp.flags('Y'), 'ok|cancelled+place+time@3',
  'archiving the published Sunday service flags its duties as cancelled');

-- The public read never names a duty -------------------------------------------------------------------
insert into v select 'e4', (pg_temp.cmd(2, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Prayer night', pg_temp.at(23))) #>> '{data,event_id}')::uuid;
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_event', pg_temp.rev(pg_temp.e('e4')),
            jsonb_build_object('event_id', pg_temp.e('e4')))), 'ok', 'Media publishes another event');
select is((select count(*)::int from jsonb_array_elements(pg_temp.read(null, 'select api.content_public_events()') -> 'events') e,
                  jsonb_object_keys(e) k
            where k ~ '(dut|rota|depart|review|flag)'), 0, 'the public event list carries no duty, rota or review key');
select is(pg_temp.read(null, format('select api.content_public_event(%L::uuid)', pg_temp.e('e4')))::text ~* '(dut|rota|depart)',
  false, 'the public event read reveals no duty or rota');

select * from finish();
rollback;
