-- Story 6.1: the Content publication lifecycle with events. Registries, privileges, the five
-- event commands for Media, Pastor and Admin (and their refusals for a plain member, a Pending
-- account and anon), the immutable published revision that stays live while a draft is edited,
-- withdraw and archive, replay, the anonymous public read contract (projection only), the editors'
-- read and the deletion hook with its erase parts. Every account, phone and name is SYNTHETIC
-- (fictional range +1 202 555 0151-0157). Times are church time (Africa/Lusaka).
begin;
select plan(121);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000081' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000081' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+120255501' || (50 + n)::text $$;
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
create function pg_temp.cmd(n int, p_command text, p_expected bigint, p_payload jsonb,
                            p_request uuid default gen_random_uuid())
returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  r := api.content_command(jsonb_build_object(
    'version', 1, 'command', p_command, 'request_id', p_request,
    'expected_revision', p_expected, 'payload', p_payload));
  reset role;
  return r;
end;
$$;
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
-- A church-time clock time p_days church days from today.
create function pg_temp.at(p_days int, p_time text default '10:00') returns timestamptz language sql as
$$ select (((now() at time zone 'Africa/Lusaka')::date + p_days) + p_time::time) at time zone 'Africa/Lusaka' $$;
create function pg_temp.iso(p timestamptz) returns text language sql as
$$ select to_char(p at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') $$;
create function pg_temp.ev(p_title text, p_from timestamptz, p_to timestamptz,
                           p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('title', p_title, 'description', 'SYNTHETIC thanksgiving service and meal.',
                            'starts_at', pg_temp.iso(p_from), 'ends_at', pg_temp.iso(p_to),
                            'location', 'SYNTHETIC Church grounds') || p_extra
$$;

-- Accounts: 1 Admin (also Media); 2 Pastor; 3 Media M; 4 plain member; 5 Pending (no member
-- link); 6 Media B (erased at the end); 7 Media R (role revoked before a replay).
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 7) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 7) n;
select app.platform_set_environment('local', 'pgtap content events');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC Content Member ' || n,
                                                         'pgtap content events')
  from generate_series(1, 7) n where n <> 5;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator)
values (pg_temp.mid(1), 'media', 'israel'), (pg_temp.mid(2), 'pastor', 'israel'),
       (pg_temp.mid(3), 'media', 'israel'), (pg_temp.mid(6), 'media', 'israel'),
       (pg_temp.mid(7), 'media', 'israel');

-- Structure, registries and privileges ----------------------------------------------------------
select has_table('app', t, format('app.%s exists', t))
  from unnest(array['content_kinds', 'content_commands', 'content_erase_parts', 'content_items',
                    'content_audit', 'content_event_revisions']) t;
select ok((select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'app' and c.relkind = 'r' and c.relname like 'content\_%'),
  'RLS is enabled on every Content table');
select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
    cross join unnest(array['anon', 'authenticated', 'service_role']) r
    where n.nspname = 'app' and c.relkind in ('r', 'S') and c.relname like 'content\_%'
      and (has_table_privilege(r, c.oid, 'SELECT') or has_table_privilege(r, c.oid, 'INSERT')
           or has_table_privilege(r, c.oid, 'UPDATE') or has_table_privilege(r, c.oid, 'DELETE'))),
  0, 'no client role has any privilege on a Content table or sequence');
select results_eq(
  $$select (n.nspname || '.' || p.proname)::text collate "C" from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'api') and p.proname like 'content\_%' and p.proname like '%event%'
       and has_function_privilege('anon', p.oid, 'EXECUTE')
       and p.proname not like 'content\_%giving%' -- story 6.3 pins its own
       and p.proname not like '%rsvp%' -- story 6.11 pins its own
       and p.proname not like '%announcement%'
     order by 1$$,
  $$values ('api.content_public_event'::text collate "C"), ('api.content_public_events'),
           ('app.content_public_event'), ('app.content_public_events')$$,
  'anon can execute only the two public event reads (story 6.2 lists its own)');
select results_eq(
  $$select (n.nspname || '.' || p.proname)::text collate "C" from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'api') and p.proname like 'content\_%'
       and (p.proname like '%event%' or p.proname = 'content_command')
       and has_function_privilege('authenticated', p.oid, 'EXECUTE')
       and p.proname not like 'content\_%giving%' -- story 6.3 pins its own
       and p.proname not like '%rsvp%' -- story 6.11 pins its own
       and p.proname not like '%announcement%'
     order by 1$$,
  $$values ('api.content_command'::text collate "C"), ('api.content_public_event'), ('api.content_public_events'),
           ('api.content_staff_events'), ('app.content_command'), ('app.content_public_event'),
           ('app.content_public_events'), ('app.content_staff_events')$$,
  'authenticated can execute only the command and the reads');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('app', 'api') and p.proname like 'content\_%'
              and has_function_privilege('service_role', p.oid, 'EXECUTE')), 0,
  'service_role executes no Content function');
select is_definer('app', 'content_command', array['jsonb'], 'the app entry point is SECURITY DEFINER');
select isnt_definer('api', 'content_command', array['jsonb'], 'the api wrapper uses invoker security');
select is_definer('app', 'content_public_events', array[]::text[], 'the public read body is a definer');
select isnt_definer('api', 'content_public_events', array[]::text[], 'the public api wrapper is invoker');
select results_eq($$select kind, editor_roles from app.content_kinds where kind = 'event' order by 1$$,
  $$values ('event'::text, array['admin', 'pastor', 'media']::text[])$$, 'events are edited by Admin, Pastor and Media');
select results_eq($$select command || ':' || handler || ':' || creates from app.content_commands
                      where kind = 'event' -- story 6.11 pins its RSVP and organiser commands
                        and command not in ('content.rsvp_event', 'content.cancel_rsvp',
                                            'content.set_event_organisers')
                      order by 1$$,
  $$values ('content.archive_event:app.content_event_archive(uuid,bigint,jsonb):false'::text),
           ('content.create_event:app.content_event_create(uuid,bigint,jsonb):true'),
           ('content.publish_event:app.content_event_publish(uuid,bigint,jsonb):false'),
           ('content.save_event:app.content_event_save(uuid,bigint,jsonb):false'),
           ('content.withdraw_event:app.content_event_withdraw(uuid,bigint,jsonb):false')$$,
  'the five event commands are registered');
select is((select a.handler from app.cmd_authorizers a where a.namespace = 'content'),
  'app.content_authorize_command(jsonb)', 'Content registers its authorizer');
select is((select handler from app.identity_deletion_hooks where module = 'content'),
  'app.content_erase_member(jsonb)', 'Content registers one deletion hook');
select results_eq($$select part || ':' || handler from app.content_erase_parts
                      where part = 'event_revisions' order by 1$$,
  $$values ('event_revisions:app.content_event_erase_part(jsonb)'::text)$$, 'the events erase part is registered');
select throws_ok($$select app.content_register_command('content.x', 'event', 'app.cells_command(jsonb)'::regprocedure, false)$$,
  'PCTR1', null, 'a command handler of another module is refused');
select throws_ok($$select app.content_register_command('content.y', 'event', 'app.content_erase_member(jsonb)'::regprocedure, false)$$,
  'PCTR1', null, 'a command handler with the wrong signature is refused');
select throws_ok($$select app.content_register_erase_part('x', 'app.content_erase_member(jsonb)'::regprocedure)$$,
  'PCTR1', null, 'an erase part must answer an integer');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'every Content object has an owner');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function pins search_path');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');
select results_eq(
  $$select column_name::text collate "C" from information_schema.columns
     where table_schema = 'app' and table_name = 'content_audit' order by 1$$,
  $$values ('action'::text collate "C"), ('actor_account_id'), ('actor_capacity'), ('actor_member_id'),
           ('command_request_id'), ('environment'), ('event_id'), ('item_id'), ('kind'), ('occurred_at'),
           ('revision_after'), ('revision_no')$$,
  'the audit row holds ids, codes and revisions only');

-- Create: who may, and what is refused -----------------------------------------------------------
create temp table e1 as select pg_temp.cmd(3, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Harvest Thanksgiving', pg_temp.at(5, '09:00'), pg_temp.at(6, '12:00'))) as r;
create function pg_temp.e1() returns uuid language sql as $$ select (r #>> '{data,event_id}')::uuid from e1 $$;
create function pg_temp.rev(p uuid) returns bigint language sql as $$ select revision from app.content_items where item_id = p $$;
select is((select (r -> 'data') - 'event_id' from e1),
  '{"state": "draft", "revision": 1, "live_revision_no": null, "draft_revision_no": 1}'::jsonb,
  'Media creates a private draft (revision 1, draft revision 1)');
select is((select r ->> 'revision' from e1), '1', 'the envelope carries the revision');
select is(pg_temp.err(pg_temp.cmd(2, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Pastor event', pg_temp.at(3), pg_temp.at(3, '12:00')))), 'ok', 'a Pastor may create');
select is(pg_temp.err(pg_temp.cmd(1, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Admin event', pg_temp.at(4), pg_temp.at(4, '12:00')))), 'ok', 'an Admin may create');
select is((select actor_capacity from app.content_audit a where a.actor_member_id = pg_temp.mid(1) and action = 'created'),
  'admin', 'an Admin holding Media too is recorded as admin');
select is(pg_temp.err(pg_temp.cmd(4, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Member event', pg_temp.at(3), pg_temp.at(3, '12:00')))), 'forbidden',
  'a plain member cannot create');
select is(pg_temp.err(pg_temp.cmd(5, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Pending event', pg_temp.at(3), pg_temp.at(3, '12:00')))), 'forbidden',
  'a Pending account (no member link) cannot create');
select is(pg_temp.err(pg_temp.cmd(4, 'content.create_event', null, '{"oops": 1}')), 'forbidden',
  'refusal comes before validation for a plain member');
select is(pg_temp.read(null, $q$select api.content_command('{"version": 1}'::jsonb)$q$) #>> '{}',
  '42501|permission denied for function content_command|', 'anon cannot execute the command');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_event', null, '{"surprise": true}')),
  'validation_failed|description=required,ends_at=required,location=required,starts_at=required,surprise=unknown_field,title=required',
  'every missing field and an unknown field are named');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Backwards', pg_temp.at(3, '12:00'), pg_temp.at(3, '09:00')))),
  'validation_failed|ends_at=before_start', 'the end must be after the start');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Long', pg_temp.at(3), pg_temp.at(35)))),
  'validation_failed|ends_at=too_long', 'an event lasts at most 31 days');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Far', pg_temp.at(2000), pg_temp.at(2001)))),
  'validation_failed|starts_at=out_of_range', 'the start is at most five years ahead');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_event', null,
  pg_temp.ev(repeat('x', 121), pg_temp.at(3), pg_temp.at(3, '12:00'),
             jsonb_build_object('location', 'SYNTHETIC ' || chr(7), 'starts_at', '2026-10-10 09:00')))),
  'validation_failed|location=invalid,starts_at=invalid,title=too_long', 'text and instant checks');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_event', null,
  pg_temp.ev(chr(9), pg_temp.at(3), pg_temp.at(3, '12:00'),
             jsonb_build_object('description', chr(10) || chr(10), 'location', chr(160) || ' ')))),
  'validation_failed|description=required,location=required,title=required',
  'whitespace only (tabs, line breaks, no-break spaces) is blank');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_event', null,
  pg_temp.ev(chr(160) || 'SYNTHETIC Edges' || chr(9), pg_temp.at(3), pg_temp.at(3, '12:00'),
             jsonb_build_object('description', chr(10) || ' SYNTHETIC body ' || chr(10))))),
  'ok', 'edge whitespace is accepted');
select is((select r.title || '|' || r.description from app.content_event_revisions r
            where r.title like 'SYNTHETIC Edges%'), 'SYNTHETIC Edges|SYNTHETIC body', 'and trimmed');
select throws_ok($$insert into app.content_event_revisions (item_id, revision_no, title, description, starts_at,
                     ends_at, location, saved_by_member, saved_by_account)
                   select item_id, 99, ' ', 'x', now(), now() + interval '1 hour', 'x', created_by_member,
                          created_by_account from app.content_items limit 1$$,
  '23514', null, 'the table refuses a blank title');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Lines', pg_temp.at(3), pg_temp.at(3, '12:00'),
             jsonb_build_object('description', 'Line one' || chr(13) || chr(10) || 'Line two')))),
  'ok', 'a multiline description with Windows line endings is accepted');
select is((select d.description from app.content_event_revisions d join app.content_items i using (item_id)
            where d.title = 'SYNTHETIC Lines'), 'Line one' || chr(10) || 'Line two', 'and normalised');

-- Drafts are private ---------------------------------------------------------------------------------
select is(pg_temp.read(null, 'select api.content_public_events()') -> 'events', '[]'::jsonb,
  'anon sees no draft');
select is(pg_temp.read(null, format('select api.content_public_event(%L::uuid)', pg_temp.e1())),
  '{"event": null}'::jsonb, 'a draft is null to anon by id');
select is(pg_temp.read(5, 'select api.content_public_events()') -> 'events', '[]'::jsonb,
  'a Pending account sees no draft');

-- Publish ----------------------------------------------------------------------------------------------
select is(pg_temp.err(pg_temp.cmd(4, 'content.publish_event', pg_temp.rev(pg_temp.e1()),
  jsonb_build_object('event_id', pg_temp.e1()))), 'forbidden', 'a plain member cannot publish');
create temp table p1 as select pg_temp.cmd(3, 'content.publish_event', 1,
  jsonb_build_object('event_id', pg_temp.e1())) as r;
select is((select (r -> 'data') - 'event_id' from p1),
  '{"state": "published", "revision": 2, "live_revision_no": 1, "draft_revision_no": null}'::jsonb,
  'Media publishes: the draft goes live');
create temp table pub as select pg_temp.read(null, 'select api.content_public_events()') as r;
select is((select jsonb_array_length(r -> 'events') from pub), 1, 'anon reads one published event');
select results_eq($$select k from pub, jsonb_object_keys(r #> '{events,0}') k
                     where k not in ('poster', 'rsvp') order by 1$$, -- story 6.11 pins its own
  $$values ('description'::text), ('ends_at'), ('event_id'), ('location'), ('offline_allowed'), ('publication_revision'),
           ('published_at'), ('starts_at'), ('title')$$,
  'the public projection has exactly these keys');
select ok((select (r #>> '{events,0,offline_allowed}')::boolean from pub),
  'church-authored events are eligible for offline storage');
select is((select r #>> '{events,0,starts_at}' from pub), to_char(pg_temp.at(5, '09:00') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
  'the start is the first day (UTC instant)');
select is((select r #>> '{events,0,ends_at}' from pub), to_char(pg_temp.at(6, '12:00') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
  'the end is the second day (both endpoints kept)');
select ok((select position(pg_temp.mid(3)::text in r::text) = 0 and position(pg_temp.u(3)::text in r::text) = 0
                  and position('SYNTHETIC Content Member' in r::text) = 0 from pub),
  'no editor id or name in the public read');
select is(pg_temp.read(5, 'select api.content_public_events()'), (select r from pub),
  'a Pending account reads the same projection');
select is(pg_temp.read(4, 'select api.content_public_events()'), (select r from pub),
  'a member reads the same projection');
select is(pg_temp.read(null, format('select api.content_public_event(%L::uuid)', pg_temp.e1())) -> 'event',
  (select r #> '{events,0}' from pub), 'the detail read is the same projection');
select is(pg_temp.read(null, format('select api.content_public_event(%L::uuid)', gen_random_uuid())),
  '{"event": null}'::jsonb, 'an unknown id is null');
select is(pg_temp.err(pg_temp.cmd(3, 'content.publish_event', 2, jsonb_build_object('event_id', pg_temp.e1()))),
  'validation_failed|event_id=nothing_to_publish', 'nothing to publish without a draft');

-- Edit a published event: the live revision stays public until a publish -----------------------------
create temp table s1 as select pg_temp.cmd(2, 'content.save_event', 2,
  pg_temp.ev('SYNTHETIC Harvest Thanksgiving (new time)', pg_temp.at(5, '10:00'), pg_temp.at(6, '13:00'),
             jsonb_build_object('event_id', pg_temp.e1()))) as r;
select is((select (r -> 'data') - 'event_id' from s1),
  '{"state": "published", "revision": 3, "live_revision_no": 1, "draft_revision_no": 2}'::jsonb,
  'a Pastor saves a new draft revision of the published event');
select is(pg_temp.read(null, 'select api.content_public_events()') #>> '{events,0,title}',
  'SYNTHETIC Harvest Thanksgiving', 'the published revision stays live while the draft is edited');
select is(pg_temp.err(pg_temp.cmd(3, 'content.save_event', 3,
  pg_temp.ev('SYNTHETIC Harvest Thanksgiving (newer)', pg_temp.at(5, '10:00'), pg_temp.at(6, '13:00'),
             jsonb_build_object('event_id', pg_temp.e1())))), 'ok', 'saving again writes the same open draft');
select is((select count(*)::int from app.content_event_revisions where item_id = pg_temp.e1()), 2,
  'one open draft row, no extra revision');
select is(pg_temp.err(pg_temp.cmd(3, 'content.save_event', 3,
  pg_temp.ev('SYNTHETIC Stale', pg_temp.at(5), pg_temp.at(6), jsonb_build_object('event_id', pg_temp.e1())))),
  'conflict', 'a stale tab is refused');
select is((pg_temp.cmd(3, 'content.save_event', 3,
  pg_temp.ev('SYNTHETIC Stale', pg_temp.at(5), pg_temp.at(6), jsonb_build_object('event_id', pg_temp.e1())))) ->> 'current_revision',
  '4', 'with the current revision');
select is(pg_temp.err(pg_temp.cmd(3, 'content.save_event', 4,
  pg_temp.ev('SYNTHETIC Ghost', pg_temp.at(5), pg_temp.at(6), jsonb_build_object('event_id', gen_random_uuid())))),
  'not_found', 'an unknown event is not found');
select throws_ok(format($$update app.content_event_revisions set title = 'SYNTHETIC tampered'
                          where item_id = %L and revision_no = 1$$, pg_temp.e1()),
  'PCNT1', 'a published content revision is immutable', 'a published revision cannot be rewritten');
create temp table staff1 as select pg_temp.read(3, 'select api.content_staff_events()') as r;
create function pg_temp.staff_e1(p jsonb) returns jsonb language sql as $$
  select e from jsonb_array_elements(p -> 'events') e where e ->> 'event_id' = pg_temp.e1()::text $$;
select is((select pg_temp.staff_e1(r) #>> '{live,title}' from staff1), 'SYNTHETIC Harvest Thanksgiving',
  'editors read the live revision');
select is((select pg_temp.staff_e1(r) #>> '{draft,title}' from staff1), 'SYNTHETIC Harvest Thanksgiving (newer)',
  'and the open draft');
select is((select pg_temp.staff_e1(r) ->> 'published_by' from staff1), 'SYNTHETIC Content Member 3',
  'with who published it');
select is((select pg_temp.staff_e1(r) #>> '{draft,saved_by}' from staff1), 'SYNTHETIC Content Member 3',
  'and who saved the draft');
select is((select r ->> 'capacity' from staff1), 'media', 'the reader''s capacity');
select results_eq($$select k from staff1, jsonb_object_keys(pg_temp.staff_e1(r)) k -- story 6.11 pins its own
                     where k not in ('public_poster', 'rsvp_going', 'organisers', 'sees_names') order by 1$$,
  $$values ('archived_at'::text), ('created_at'), ('created_by'), ('draft'), ('event_id'), ('live'),
           ('published_at'), ('published_by'), ('revision'), ('state'), ('updated_at'), ('withdrawn_at')$$,
  'the editors'' event keys');
create temp table p2 as select pg_temp.cmd(1, 'content.publish_event', 4, jsonb_build_object('event_id', pg_temp.e1())) as r;
select is((select (r -> 'data') - 'event_id' from p2),
  '{"state": "published", "revision": 5, "live_revision_no": 2, "draft_revision_no": null}'::jsonb,
  'publishing the draft replaces the live revision');
select is(pg_temp.read(null, 'select api.content_public_events()') #>> '{events,0,title}',
  'SYNTHETIC Harvest Thanksgiving (newer)', 'the new revision is public');
select is(pg_temp.read(null, 'select api.content_public_events()') #>> '{events,0,publication_revision}',
  '2', 'with its publication revision');
select is((select title from app.content_event_revisions where item_id = pg_temp.e1() and revision_no = 1),
  'SYNTHETIC Harvest Thanksgiving', 'the earlier published revision is kept unchanged');

-- Every editor command is refused to a plain member and a Pending account ---------------------------
select is(pg_temp.err(pg_temp.cmd(n, c, 5, case when c = 'content.save_event'
    then pg_temp.ev('SYNTHETIC No', pg_temp.at(5), pg_temp.at(6), jsonb_build_object('event_id', pg_temp.e1()))
    else jsonb_build_object('event_id', pg_temp.e1()) end)), 'forbidden',
  format('account %s is refused %s', n, c))
  from unnest(array[4, 5]) n
  cross join unnest(array['content.save_event', 'content.publish_event', 'content.withdraw_event',
                          'content.archive_event']) c;
select is(pg_temp.err(pg_temp.cmd(3, 'content.retitle_event', 5, '{}')), 'validation_failed|command=unsupported',
  'an unregistered content command is unsupported');
select is(pg_temp.read(4, 'select api.content_staff_events()') #>> '{}',
  'PT403|forbidden|not_granted', 'a plain member cannot read the editors'' list');
select is(pg_temp.read(5, 'select api.content_staff_events()') #>> '{}',
  'PT403|forbidden|not_linked', 'a Pending account cannot read the editors'' list');
select is(pg_temp.read(null, 'select api.content_staff_events()') #>> '{}',
  '42501|permission denied for function content_staff_events|', 'anon cannot read the editors'' list');

-- Withdraw, republish and archive ----------------------------------------------------------------------
select is(pg_temp.cmd(3, 'content.withdraw_event', 5, jsonb_build_object('event_id', pg_temp.e1())) #>> '{data,state}',
  'withdrawn', 'Media withdraws the event');
select is(pg_temp.read(null, 'select api.content_public_events()') -> 'events', '[]'::jsonb,
  'withdrawal removes it from the public list');
select is(pg_temp.read(null, format('select api.content_public_event(%L::uuid)', pg_temp.e1())),
  '{"event": null}'::jsonb, 'and from the detail read');
select is(pg_temp.err(pg_temp.cmd(3, 'content.withdraw_event', 6, jsonb_build_object('event_id', pg_temp.e1()))),
  'validation_failed|event_id=not_published', 'a withdrawn event cannot be withdrawn again');
select is((pg_temp.cmd(3, 'content.publish_event', 6, jsonb_build_object('event_id', pg_temp.e1())) -> 'data') - 'event_id',
  '{"state": "published", "revision": 7, "live_revision_no": 2, "draft_revision_no": null}'::jsonb,
  'publishing again brings back the live revision');
select is(pg_temp.read(null, 'select api.content_public_events()') #>> '{events,0,title}',
  'SYNTHETIC Harvest Thanksgiving (newer)', 'it is public again');
select is(pg_temp.cmd(2, 'content.archive_event', 7, jsonb_build_object('event_id', pg_temp.e1())) #>> '{data,state}',
  'archived', 'a Pastor archives it');
select is(pg_temp.read(null, 'select api.content_public_events()') -> 'events', '[]'::jsonb,
  'an archived event is not public');
select is(pg_temp.err(pg_temp.cmd(3, 'content.save_event', 8,
  pg_temp.ev('SYNTHETIC After', pg_temp.at(5), pg_temp.at(6), jsonb_build_object('event_id', pg_temp.e1())))),
  'validation_failed|event_id=archived', 'an archived event refuses every later command');
select is(pg_temp.err(pg_temp.cmd(3, 'content.publish_event', 8, jsonb_build_object('event_id', pg_temp.e1()))),
  'validation_failed|event_id=archived', 'including publish');
select results_eq(
  format($$select action from app.content_audit where item_id = %L order by event_id$$, pg_temp.e1()),
  $$values ('created'::text), ('published'), ('draft_saved'), ('draft_saved'), ('published'), ('withdrawn'),
           ('published'), ('archived')$$,
  'every change is audited in order');

-- Ended events, ordering and the projection of several -------------------------------------------------
create temp table e2 as select pg_temp.cmd(3, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Yesterday', pg_temp.at(-1, '09:00'), pg_temp.at(-1, '11:00'))) as r;
select pg_temp.cmd(3, 'content.publish_event', 1, jsonb_build_object('event_id', (r #>> '{data,event_id}')::uuid)) from e2;
create temp table e3 as select pg_temp.cmd(3, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Ongoing', pg_temp.at(-1, '09:00'), pg_temp.at(2, '11:00'))) as r;
select pg_temp.cmd(3, 'content.publish_event', 1, jsonb_build_object('event_id', (r #>> '{data,event_id}')::uuid)) from e3;
create temp table e4 as select pg_temp.cmd(6, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Soon', pg_temp.at(1, '18:00'), pg_temp.at(1, '20:00'))) as r;
select pg_temp.cmd(6, 'content.publish_event', 1, jsonb_build_object('event_id', (r #>> '{data,event_id}')::uuid)) from e4;
select results_eq($$select e ->> 'title' from jsonb_array_elements(pg_temp.read(null, 'select api.content_public_events()') -> 'events') e$$,
  $$values ('SYNTHETIC Ongoing'::text), ('SYNTHETIC Soon')$$,
  'the public list holds ongoing and upcoming events, soonest first; an ended one is left out');
select is(pg_temp.read(null, format('select api.content_public_event(%L::uuid)', (select r #>> '{data,event_id}' from e2))),
  '{"event": null}'::jsonb, 'an ended event is not public by id either');
select is(pg_temp.read(null, format('select api.content_public_event(%L::uuid)', (select r #>> '{data,event_id}' from e3))) #>> '{event,title}',
  'SYNTHETIC Ongoing', 'an ongoing event is public by id');
select is(pg_temp.read(null, 'select api.content_public_events()') ->> 'truncated', 'false', 'not truncated');

-- Replay ----------------------------------------------------------------------------------------------
create temp table rq as select gen_random_uuid() as id;
create temp table e5 as select pg_temp.cmd(7, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Replay', pg_temp.at(9), pg_temp.at(9, '12:00')), (select id from rq)) as r;
select is(pg_temp.cmd(7, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Replay', pg_temp.at(9), pg_temp.at(9, '12:00')), (select id from rq)),
  (select r from e5), 'a replay answers the stored result');
select is((select count(*)::int from app.content_event_revisions where title = 'SYNTHETIC Replay'), 1,
  'and creates nothing twice');
select is(pg_temp.err(pg_temp.cmd(7, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Replay changed', pg_temp.at(9), pg_temp.at(9, '12:00')), (select id from rq))),
  'conflict', 'the same request id with a changed body conflicts');
update app.identity_grants set revoked_at = now(), revoked_by_member = pg_temp.mid(1), revoked_by_account = pg_temp.u(1)
 where member_id = pg_temp.mid(7) and role = 'media';
select is(pg_temp.err(pg_temp.cmd(7, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Replay', pg_temp.at(9), pg_temp.at(9, '12:00')), (select id from rq))),
  'forbidden', 'a replay after the role was removed is refused');
select is(pg_temp.read(7, 'select api.content_staff_events()') #>> '{}', 'PT403|forbidden|not_granted',
  'and the editors'' list is closed to them at once');

-- Deletion: an erased editor reads as a former member ---------------------------------------------------
create temp table before_erase as
  select h from jsonb_array_elements(app.identity_call_deletion_hooks(pg_temp.mid(6), pg_temp.u(6),
                                                                       gen_random_uuid(), 'check')) h
   where h ->> 'module' = 'content';
select ok((select (h ->> 'remaining')::int > 0 from before_erase), 'the check counts Media B''s attribution');
select is((select h ->> 'remaining' from jsonb_array_elements(app.identity_call_deletion_hooks(
             pg_temp.mid(6), pg_temp.u(6), gen_random_uuid(), 'erase')) h where h ->> 'module' = 'content'),
  '0', 'erase leaves nothing of Media B in Content');
select is((select (app.content_erase_member(jsonb_build_object('member_id', pg_temp.mid(6), 'account_id', pg_temp.u(6),
                                                                'deletion_id', gen_random_uuid(), 'phase', 'check'))) ->> 'remaining'),
  '0', 'the check answers 0 afterwards');
create temp table staff2 as select pg_temp.read(3, 'select api.content_staff_events()') as r;
create function pg_temp.staff_by_title(p jsonb, p_title text) returns jsonb language sql as $$
  select e from jsonb_array_elements(p -> 'events') e where e #>> '{live,title}' = p_title $$;
select is((select pg_temp.staff_by_title(r, 'SYNTHETIC Soon') ->> 'published_by' from staff2), 'Former member',
  'the erased editor''s publication reads as a former member');
select is((select pg_temp.staff_by_title(r, 'SYNTHETIC Soon') ->> 'created_by' from staff2), 'Former member',
  'and their creation');
select is((select pg_temp.staff_by_title(r, 'SYNTHETIC Soon') #>> '{live,saved_by}' from staff2), 'Former member',
  'and their saved revision');
select is(pg_temp.read(null, 'select api.content_public_events()') #>> '{events,1,title}', 'SYNTHETIC Soon',
  'the published event itself stays public');
select is((select count(*)::int from app.content_audit where actor_member_id = pg_temp.mid(6)), 0,
  'the audit keeps no id of the erased editor');

select * from finish();
rollback;
