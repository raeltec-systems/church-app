-- Story 6.11: event posters, RSVP within capacity and the organisers' names. Registries and
-- privileges; the poster on a draft, its publication checks and public projection; RSVP for
-- approved members (going, already going, full, cancel, closed, off, not public) and its refusals
-- for Pending and anon; the names read for organisers and Admins only; the organisers command;
-- the lifecycle hook (a login hold keeps an RSVP, a deactivation releases future ones, a revoked
-- last editor role ends an organiser role); replay; the RSVP erase part and its fail-closed stub.
-- Concurrent RSVPs are proven by the E2E (content-event-rsvp.mjs). Every account, phone and name
-- is SYNTHETIC (fictional range +1 202 555 0171-0181). Times are church time (Africa/Lusaka).
begin;
select plan(136);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000611' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000611' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+120255501' || (70 + n)::text $$;
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
create function pg_temp.call(n int, p_endpoint text, p_command text, p_expected bigint, p_payload jsonb,
                             p_request uuid default gen_random_uuid())
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
create function pg_temp.cmd(n int, p_command text, p_expected bigint, p_payload jsonb,
                            p_request uuid default gen_random_uuid())
returns jsonb language sql as
$$ select pg_temp.call(n, 'content_command', p_command, p_expected, p_payload, p_request) $$;
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
create function pg_temp.ev(p_title text, p_from timestamptz, p_to timestamptz,
                           p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('title', p_title, 'description', 'SYNTHETIC youth camp with meals.',
                            'starts_at', pg_temp.iso(p_from), 'ends_at', pg_temp.iso(p_to),
                            'location', 'SYNTHETIC Camp grounds') || p_extra
$$;
create function pg_temp.rev(p uuid) returns bigint language sql as
$$ select revision from app.content_items where item_id = p $$;
create function pg_temp.rights(p_label text, p_display boolean, p_offline boolean) returns jsonb language sql as $$
  select jsonb_build_object('label', p_label, 'source_key', 'church-posters',
                            'holder', 'SYNTHETIC Church media team', 'basis', 'church_owned',
                            'clears_display', p_display, 'clears_offline', p_offline,
                            'clears_audio', false,
                            'evidence', 'SYNTHETIC: designed by the church media team for testing.')
$$;
create function pg_temp.up(p_item uuid, p_width int default 1920, p_height int default 1080)
returns jsonb language sql as $$
  select jsonb_build_object('item_id', p_item, 'purpose', 'event_poster', 'media_type', 'image/png',
                            'byte_size', 2000000, 'width', p_width, 'height', p_height,
                            'sha256', repeat('cd', 32))
$$;
create function pg_temp.obj(p_bucket text, p_name text, p_size bigint, p_type text) returns void
language sql as $$
  insert into storage.objects (bucket_id, name, metadata)
  values (p_bucket, p_name, jsonb_build_object('size', p_size, 'mimetype', p_type));
$$;
-- A ready event_poster asset uploaded by account n for event p_item (begin, store, complete).
create function pg_temp.poster(n int, p_item uuid) returns uuid language plpgsql as $$
declare
  r jsonb;
begin
  r := pg_temp.cmd(n, 'content.begin_asset_upload', null, pg_temp.up(p_item));
  perform pg_temp.obj('content-drafts', r #>> '{data,draft_path}', 2000000, 'image/png');
  r := pg_temp.cmd(n, 'content.complete_asset_upload', null,
                   jsonb_build_object('asset_id', r #>> '{data,asset_id}'));
  return (r #>> '{data,asset_id}')::uuid;
end;
$$;
create function pg_temp.rsvp(n int, p_event uuid, p_command text default 'content.rsvp_event',
                             p_request uuid default gen_random_uuid())
returns jsonb language sql as
$$ select pg_temp.cmd(n, p_command, null, jsonb_build_object('event_id', p_event), p_request) $$;
create function pg_temp.pub(p_event uuid) returns jsonb language sql as
$$ select pg_temp.read(null, format('select api.content_public_event(%L::uuid)', p_event)) -> 'event' $$;
create function pg_temp.staff(n int, p_event uuid) returns jsonb language sql as $$
  select e from jsonb_array_elements(pg_temp.read(n, 'select api.content_staff_events()') -> 'events') e
   where e ->> 'event_id' = p_event::text $$;
create function pg_temp.names(n int, p_event uuid) returns jsonb language sql as
$$ select pg_temp.read(n, format('select api.content_staff_event_rsvps(%L::uuid)', p_event)) $$;
create function pg_temp.attendees(n int, p_event uuid) returns text language sql as $$
  select string_agg(a ->> 'name', ',' order by a ->> 'name')
    from jsonb_array_elements(pg_temp.names(n, p_event) #> '{rsvps,attendees}') a $$;

-- Accounts: 1 Admin; 2 Media O (organiser); 3 Media N (not an organiser); 4-6 members A, B, C;
-- 7 Pending (no member link); 8 member D (login hold); 9 member E (deactivated); 10 member F
-- (erased); 11 Media R (role revoked).
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 11) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 11) n;
select app.platform_set_environment('local', 'pgtap content event rsvp');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC Rsvp Member ' || n,
                                                         'pgtap content event rsvp')
  from generate_series(1, 11) n where n <> 7;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
create function pg_temp.mrev(n int) returns bigint language sql as
$$ select revision from app.identity_members where member_id = pg_temp.mid($1) $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator)
values (pg_temp.mid(2), 'media', 'israel'), (pg_temp.mid(3), 'media', 'israel'),
       (pg_temp.mid(11), 'media', 'israel');
create temp table v (k text primary key, id uuid, j jsonb);

-- Structure, registries and privileges ----------------------------------------------------------
select has_table('app', t, format('app.%s exists', t))
  from unnest(array['content_event_organisers', 'content_event_rsvps', 'content_member_commands']) t;
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
            cross join unnest(array['anon', 'authenticated', 'service_role']) r
            where n.nspname = 'app'
              and c.relname in ('content_event_organisers', 'content_event_rsvps', 'content_member_commands')
              and (not c.relrowsecurity or has_table_privilege(r, c.oid, 'SELECT')
                   or has_table_privilege(r, c.oid, 'INSERT') or has_table_privilege(r, c.oid, 'UPDATE')
                   or has_table_privilege(r, c.oid, 'DELETE'))),
  0, 'the three new tables have RLS on and no client privilege');
select results_eq(
  $$select purpose, kind, rights_use, max_bytes, min_width, min_height, max_width, max_height, min_ratio, max_ratio
      from app.content_asset_purposes where purpose = 'event_poster'$$,
  $$values ('event_poster'::text, 'event'::text, 'display'::text, 5242880::bigint, 540, 540, 6000, 6000, 0.50, 2.40)$$,
  'the event poster purpose has bounded image limits');
select is((select handler from app.content_public_conditions where kind = 'event'),
  'app.content_event_public_condition(jsonb)', 'events register their public condition (not ended)');
select results_eq($$select command || ':' || handler || ':' || creates from app.content_commands
                      where command in ('content.rsvp_event', 'content.cancel_rsvp', 'content.set_event_organisers')
                      order by 1$$,
  $$values ('content.cancel_rsvp:app.content_event_rsvp_cancel(uuid,bigint,jsonb):true'::text),
           ('content.rsvp_event:app.content_event_rsvp_going(uuid,bigint,jsonb):true'),
           ('content.set_event_organisers:app.content_event_set_organisers(uuid,bigint,jsonb):false')$$,
  'the RSVP and organiser commands are registered under events');
select results_eq($$select command from app.content_member_commands where command like '%rsvp%' order by 1$$,
  $$values ('content.cancel_rsvp'::text), ('content.rsvp_event')$$, 'the two RSVP commands are member commands');
select is((select handler from app.content_erase_parts where part = 'event_rsvps'),
  'app.content_rsvp_erase_part(jsonb)', 'the RSVP erase part is registered');
select is((select string_agg(event, ',' order by event) from app.contract_lifecycle_hooks where module = 'content'),
  'deletion_requested,membership_deactivated,scope_revoked', 'Content hooks three lifecycle events');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('app', 'api') and (p.proname like '%rsvp%' or p.proname like '%organiser%')
              and has_function_privilege('anon', p.oid, 'EXECUTE')), 0,
  'anon executes no RSVP or organiser function');
select results_eq(
  $$select (n.nspname || '.' || p.proname)::text collate "C" from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'api') and (p.proname like '%rsvp%' or p.proname like '%organiser%')
       and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     order by 1$$,
  $$values ('api.content_my_event_rsvp'::text collate "C"), ('api.content_staff_event_rsvps'),
           ('app.content_my_event_rsvp'), ('app.content_staff_event_rsvps')$$,
  'authenticated executes only the own-RSVP read and the names read');
select is_definer('app', 'content_staff_event_rsvps', array['uuid'], 'the names read body is a definer');
select isnt_definer('api', 'content_staff_event_rsvps', array['uuid'], 'its api wrapper is invoker');
select is((select a.handler from app.cmd_authorizers a where a.namespace = 'content'),
  'app.content_authorize_command(jsonb)', 'Content keeps its one authorizer');
select throws_ok($$select app.content_register_member_command('content.no_such_command')$$,
  'PCTR1', null, 'only a registered command can be a member command');

-- An event with RSVP: creation and its field codes ---------------------------------------------------
insert into v select 'e1', (pg_temp.cmd(2, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Youth Camp', pg_temp.at(5, '09:00'), pg_temp.at(7, '17:00'),
             '{"rsvp_enabled": true, "rsvp_capacity": 2}')) #>> '{data,event_id}')::uuid, null;
create function pg_temp.e(p_k text) returns uuid language sql as $$ select id from v where k = p_k $$;
select ok(pg_temp.e('e1') is not null, 'Media O creates a three-day event with RSVP and two places');
select is((select r.rsvp_enabled::text || ':' || r.rsvp_capacity from app.content_event_revisions r
            where r.item_id = pg_temp.e('e1')), 'true:2', 'its draft keeps the RSVP settings');
select is((select string_agg(o.member_id::text || ':' || o.organiser_state, ',') from app.content_event_organisers o
            where o.item_id = pg_temp.e('e1')), pg_temp.mid(2)::text || ':active',
  'the creator is the first organiser');
select is(pg_temp.err(pg_temp.cmd(2, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC No', pg_temp.at(5), pg_temp.at(6), '{"rsvp_capacity": 5}'))),
  'validation_failed|rsvp_capacity=must_be_null', 'a capacity needs RSVP on');
select is(pg_temp.err(pg_temp.cmd(2, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC No', pg_temp.at(5), pg_temp.at(6), '{"rsvp_enabled": true, "rsvp_capacity": 0}'))),
  'validation_failed|rsvp_capacity=out_of_range', 'a capacity is at least one');
select is(pg_temp.err(pg_temp.cmd(2, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC No', pg_temp.at(5), pg_temp.at(6), '{"rsvp_enabled": "yes", "rsvp_capacity": 2.5}'))),
  'validation_failed|rsvp_capacity=invalid,rsvp_enabled=invalid', 'RSVP fields are typed');
select is(pg_temp.err(pg_temp.cmd(2, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC No', pg_temp.at(5), pg_temp.at(6), '{"poster_asset_id": null}'))),
  'validation_failed|poster_asset_id=unknown_field', 'a new event takes no poster yet (upload after creating it)');

-- The poster: upload, draft, publication checks --------------------------------------------------------
select is(pg_temp.err(pg_temp.cmd(2, 'content.begin_asset_upload', null, pg_temp.up(pg_temp.e('e1'), 500, 500))),
  'validation_failed|height=too_small,width=too_small', 'a poster smaller than 540 px is refused');
select is(pg_temp.err(pg_temp.cmd(2, 'content.begin_asset_upload', null, pg_temp.up(pg_temp.e('e1'), 1800, 600))),
  'validation_failed|width=bad_ratio', 'a banner-shaped strip is not a poster');
select is(pg_temp.err(pg_temp.cmd(4, 'content.begin_asset_upload', null, pg_temp.up(pg_temp.e('e1')))),
  'forbidden', 'a plain member cannot upload a poster');
insert into v values ('a1', pg_temp.poster(2, pg_temp.e('e1')), null);
select ok(pg_temp.e('a1') is not null, 'Media O uploads a poster for the event');
insert into v select 'r1', (pg_temp.cmd(2, 'content.create_rights_record', null,
  pg_temp.rights('SYNTHETIC camp poster', true, false)) #>> '{data,rights_id}')::uuid, null;
select is(pg_temp.err(pg_temp.cmd(2, 'content.verify_rights_record', 1, jsonb_build_object('rights_id', pg_temp.e('r1')))),
  'ok', 'its church-owned rights record is verified');
insert into v select 'r2', (pg_temp.cmd(2, 'content.create_rights_record', null,
  pg_temp.rights('SYNTHETIC unverified poster', true, true)) #>> '{data,rights_id}')::uuid, null;
create function pg_temp.save_e1(p_extra jsonb) returns jsonb language sql as $$
  select pg_temp.cmd(2, 'content.save_event', pg_temp.rev(pg_temp.e('e1')),
    pg_temp.ev('SYNTHETIC Youth Camp', pg_temp.at(5, '09:00'), pg_temp.at(7, '17:00'),
               jsonb_build_object('event_id', pg_temp.e('e1'), 'rsvp_enabled', true, 'rsvp_capacity', 2)
               || p_extra)) $$;
select is(pg_temp.err(pg_temp.save_e1(jsonb_build_object('poster_asset_id', pg_temp.e('a1')))),
  'validation_failed|poster_alt_text=required,poster_rights_id=required', 'a poster needs its rights record and alt text');
select is(pg_temp.err(pg_temp.save_e1('{"poster_alt_text": "SYNTHETIC tents by a lake"}')),
  'validation_failed|poster_asset_id=required', 'alt text without a poster is refused');
select is(pg_temp.err(pg_temp.save_e1(jsonb_build_object('poster_asset_id', gen_random_uuid(),
  'poster_rights_id', pg_temp.e('r1'), 'poster_alt_text', 'SYNTHETIC tents by a lake'))),
  'validation_failed|poster_asset_id=unknown', 'an upload of another item is unknown');
select is(pg_temp.err(pg_temp.save_e1(jsonb_build_object('poster_asset_id', pg_temp.e('a1'),
  'poster_rights_id', pg_temp.e('r2'), 'poster_alt_text', 'SYNTHETIC tents by a lake'))),
  'ok', 'a draft may cite an unverified rights record');
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_event', pg_temp.rev(pg_temp.e('e1')),
  jsonb_build_object('event_id', pg_temp.e('e1')))),
  'validation_failed|poster_rights_id=not_in_force', 'publication refuses a poster whose rights are not in force');
select is(pg_temp.err(pg_temp.save_e1(jsonb_build_object('poster_asset_id', pg_temp.e('a1'),
  'poster_rights_id', pg_temp.e('r1'), 'poster_alt_text', 'SYNTHETIC tents by a lake'))),
  'ok', 'Media O saves the poster with the verified rights record');
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_event', pg_temp.rev(pg_temp.e('e1')),
  jsonb_build_object('event_id', pg_temp.e('e1')))), 'ok', 'and publishes the event');
select is(pg_temp.pub(pg_temp.e('e1')) -> 'poster', 'null'::jsonb,
  'the public read names no poster until its object is placed');
select ok(exists (select 1 from app.content_public_files_desired() d where d.item_id = pg_temp.e('e1') and d.slot = 'poster'),
  'the poster is in the desired public set');
insert into v select 'path', null, to_jsonb(d.public_path) from app.content_public_files_desired() d
 where d.item_id = pg_temp.e('e1') and d.slot = 'poster';
select is((select j #>> '{}' from v where k = 'path'), 'event/' || pg_temp.e('e1') || '/r1/poster.png',
  'under the revision-keyed public path');
select is((pg_temp.staff(2, pg_temp.e('e1'))) ->> 'public_poster', 'waiting', 'editors see it waiting for the sync');
select pg_temp.obj('content-public', (select j #>> '{}' from v where k = 'path'), 2000000, 'image/png');
select is(pg_temp.pub(pg_temp.e('e1')) -> 'poster',
  jsonb_build_object('path', 'event/' || pg_temp.e('e1') || '/r1/poster.png', 'media_type', 'image/png',
                     'width', 1920, 'height', 1080, 'alt_text', 'SYNTHETIC tents by a lake',
                     'offline_allowed', false),
  'once placed, anyone reads the poster with its alt text (display only, not offline)');
select is((pg_temp.staff(2, pg_temp.e('e1'))) ->> 'public_poster', 'shown', 'and editors see it shown');
select results_eq($$select k from jsonb_object_keys(pg_temp.pub(pg_temp.e('e1'))) k order by 1$$,
  $$values ('description'::text), ('ends_at'), ('event_id'), ('location'), ('offline_allowed'), ('poster'),
           ('publication_revision'), ('published_at'), ('rsvp'), ('starts_at'), ('title')$$,
  'the public projection has exactly these keys');
select is(pg_temp.pub(pg_temp.e('e1')) -> 'rsvp',
  '{"capacity": 2, "going": 0, "spaces_left": 2, "full": false, "open": true}'::jsonb,
  'the public RSVP: two places, none taken, open');
select is(pg_temp.pub(pg_temp.e('e1')) ->> 'starts_at', to_char(pg_temp.at(5, '09:00') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
  'the first day is kept');
select is(pg_temp.pub(pg_temp.e('e1')) ->> 'ends_at', to_char(pg_temp.at(7, '17:00') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
  'and the third');
select results_eq($$select k from jsonb_object_keys(pg_temp.staff(2, pg_temp.e('e1')) -> 'live') k order by 1$$,
  $$values ('description'::text), ('ends_at'), ('location'), ('poster'), ('poster_alt_text'), ('poster_rights'),
           ('revision_no'), ('rsvp_capacity'), ('rsvp_enabled'), ('saved_at'), ('saved_by'), ('starts_at'), ('title')$$,
  'the editors'' revision keys');
select is((pg_temp.staff(2, pg_temp.e('e1'))) #>> '{live,poster_rights,display}', null,
  'its rights clear display (church-owned, no Q5 needed)');

-- RSVP: going, already going, full, cancel, refusals -----------------------------------------------
insert into v select 'e1rev', null, to_jsonb(pg_temp.rev(pg_temp.e('e1')));
create temp table g4 as select pg_temp.rsvp(4, pg_temp.e('e1')) as r;
select is((select (r -> 'data') - 'rsvp_id' - 'event_id' from g4),
  '{"rsvp_state": "going", "going": 1, "capacity": 2, "spaces_left": 1, "full": false}'::jsonb,
  'member A is going');
select is((select (r ->> 'revision')::int from g4), 1, 'the envelope revision is the RSVP''s');
insert into v select 'g4', (r #>> '{data,rsvp_id}')::uuid, null from g4;
select is((pg_temp.rsvp(4, pg_temp.e('e1')) -> 'data') ->> 'rsvp_id', pg_temp.e('g4')::text,
  'answering again changes nothing (the same RSVP)');
select is((select revision from app.content_event_rsvps where rsvp_id = pg_temp.e('g4')), 1::bigint,
  'and its revision stays');
create temp table g5 as select gen_random_uuid() as req;
select is(pg_temp.err(pg_temp.rsvp(5, pg_temp.e('e1'), 'content.rsvp_event', (select req from g5))), 'ok', 'member B is going');
select is(pg_temp.pub(pg_temp.e('e1')) -> 'rsvp',
  '{"capacity": 2, "going": 2, "spaces_left": 0, "full": true, "open": true}'::jsonb, 'the event is full');
select is(pg_temp.err(pg_temp.rsvp(6, pg_temp.e('e1'))), 'validation_failed|event_id=full', 'member C is refused: full');
select is(pg_temp.rev(pg_temp.e('e1')), (select (j #>> '{}')::bigint from v where k = 'e1rev'),
  'RSVPs never change the event''s revision');
select is(pg_temp.err(pg_temp.rsvp(7, pg_temp.e('e1'))), 'forbidden', 'a Pending account cannot RSVP');
select ok(pg_temp.read(null, format($q$select api.content_command(jsonb_build_object('version', 1,
  'command', 'content.rsvp_event', 'request_id', gen_random_uuid(), 'expected_revision', null,
  'payload', jsonb_build_object('event_id', %L)))$q$, pg_temp.e('e1'))) #>> '{}' like '42501|%',
  'a guest cannot RSVP');
select is(pg_temp.read(4, format('select api.content_my_event_rsvp(%L::uuid)', pg_temp.e('e1'))) ->> 'rsvp_state',
  'going', 'member A reads their own RSVP');
select is(pg_temp.read(6, format('select api.content_my_event_rsvp(%L::uuid)', pg_temp.e('e1'))) -> 'rsvp_state',
  'null'::jsonb, 'member C has none');
select ok(pg_temp.read(7, format('select api.content_my_event_rsvp(%L::uuid)', pg_temp.e('e1'))) #>> '{}' like 'PT403|%',
  'a Pending account has no RSVP read');
select ok(pg_temp.read(null, format('select api.content_my_event_rsvp(%L::uuid)', pg_temp.e('e1'))) #>> '{}' like '42501|%',
  'nor has a guest');
select is((pg_temp.rsvp(4, pg_temp.e('e1'), 'content.cancel_rsvp') -> 'data') - 'rsvp_id' - 'event_id',
  '{"rsvp_state": "cancelled", "going": 1, "capacity": 2, "spaces_left": 1, "full": false}'::jsonb,
  'member A cancels: a place is free');
select is((select count(*)::int from app.content_event_rsvps where item_id = pg_temp.e('e1')), 2,
  'the cancelled RSVP is kept as a row');
select is(pg_temp.err(pg_temp.rsvp(4, pg_temp.e('e1'), 'content.cancel_rsvp')), 'validation_failed|event_id=not_going',
  'cancelling twice is refused');
select is(pg_temp.err(pg_temp.rsvp(6, pg_temp.e('e1'))), 'ok', 'member C takes the freed place');
select is(pg_temp.err(pg_temp.rsvp(4, pg_temp.e('e1'))), 'validation_failed|event_id=full',
  'member A cannot come back while it is full');
select is(pg_temp.err(pg_temp.rsvp(4, gen_random_uuid())), 'validation_failed|event_id=not_public', 'an unknown event is not public');
select is(pg_temp.err(pg_temp.rsvp(4, gen_random_uuid(), 'content.cancel_rsvp')), 'validation_failed|event_id=not_going',
  'nor can it be cancelled');
select is(pg_temp.err(pg_temp.cmd(4, 'content.rsvp_event', null, jsonb_build_object('event_id', pg_temp.e('e1'), 'x', 1))),
  'validation_failed|x=unknown_field', 'unknown payload keys are refused');
select is(pg_temp.err(pg_temp.cmd(4, 'content.rsvp_event', 3, jsonb_build_object('event_id', pg_temp.e('e1')))),
  'validation_failed|expected_revision=must_be_null', 'an RSVP takes no expected revision');

-- Other events: no capacity, RSVP off, a draft, started, ended with a poster --------------------------
insert into v select 'e2', (pg_temp.cmd(2, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Prayer Breakfast', pg_temp.at(9, '07:00'), pg_temp.at(9, '09:00'), '{"rsvp_enabled": true}')) #>> '{data,event_id}')::uuid, null;
select is(pg_temp.err(pg_temp.rsvp(4, pg_temp.e('e2'))), 'validation_failed|event_id=not_public', 'a draft event is not public');
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_event', 1, jsonb_build_object('event_id', pg_temp.e('e2')))), 'ok',
  'an event with RSVP and no capacity is published');
select is(pg_temp.err(pg_temp.rsvp(4, pg_temp.e('e2'))), 'ok', 'member A goes to it');
select is(pg_temp.pub(pg_temp.e('e2')) -> 'rsvp',
  '{"capacity": null, "going": 1, "spaces_left": null, "full": false, "open": true}'::jsonb,
  'without a capacity it never fills');
insert into v select 'e3', (pg_temp.cmd(2, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Choir Practice', pg_temp.at(3), pg_temp.at(3, '12:00'))) #>> '{data,event_id}')::uuid, null;
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_event', 1, jsonb_build_object('event_id', pg_temp.e('e3')))), 'ok',
  'an event without RSVP is published');
select is(pg_temp.pub(pg_temp.e('e3')) -> 'rsvp', 'null'::jsonb, 'its public read has no RSVP');
select is(pg_temp.err(pg_temp.rsvp(4, pg_temp.e('e3'))), 'validation_failed|event_id=rsvp_off', 'RSVP is off for it');
insert into v select 'e4', (pg_temp.cmd(2, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Conference', now() - interval '1 hour', pg_temp.at(2, '17:00'), '{"rsvp_enabled": true, "rsvp_capacity": 50}')) #>> '{data,event_id}')::uuid, null;
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_event', 1, jsonb_build_object('event_id', pg_temp.e('e4')))), 'ok',
  'an event that has started is published');
select is(pg_temp.pub(pg_temp.e('e4')) #>> '{rsvp,open}', 'false', 'its RSVP reads closed');
select is(pg_temp.err(pg_temp.rsvp(4, pg_temp.e('e4'))), 'validation_failed|event_id=rsvp_closed', 'nobody can RSVP once it starts');
-- A fixture: member B's RSVP from before the start (no command can create one now).
insert into app.content_event_rsvps (item_id, member_id, rsvp_state) values (pg_temp.e('e4'), pg_temp.mid(9), 'going');
select is(pg_temp.err(pg_temp.rsvp(9, pg_temp.e('e4'), 'content.cancel_rsvp')), 'validation_failed|event_id=rsvp_closed',
  'nor cancel');
insert into v select 'e5', (pg_temp.cmd(2, 'content.create_event', null,
  pg_temp.ev('SYNTHETIC Past Fair', now() - interval '3 days', now() - interval '2 days')) #>> '{data,event_id}')::uuid, null;
insert into v values ('a5', pg_temp.poster(2, pg_temp.e('e5')), null);
select is(pg_temp.err(pg_temp.cmd(2, 'content.save_event', pg_temp.rev(pg_temp.e('e5')),
  pg_temp.ev('SYNTHETIC Past Fair', now() - interval '3 days', now() - interval '2 days',
             jsonb_build_object('event_id', pg_temp.e('e5'), 'poster_asset_id', pg_temp.e('a5'),
                                'poster_rights_id', pg_temp.e('r1'), 'poster_alt_text', 'SYNTHETIC fair stalls')))),
  'ok', 'an ended event gets a poster');
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_event', pg_temp.rev(pg_temp.e('e5')),
  jsonb_build_object('event_id', pg_temp.e('e5')))), 'ok', 'and is published');
select is((pg_temp.staff(2, pg_temp.e('e5'))) ->> 'public_poster', 'ended', 'its poster reads ended');
select ok(not exists (select 1 from app.content_public_files_desired() d where d.item_id = pg_temp.e('e5')),
  'and leaves the desired public set (the next sync removes it)');

-- Names: organisers and Admins only ---------------------------------------------------------------------
select is(pg_temp.attendees(2, pg_temp.e('e1')), 'SYNTHETIC Rsvp Member 5,SYNTHETIC Rsvp Member 6',
  'the organiser reads who is going');
select is(pg_temp.names(2, pg_temp.e('e1')) #> '{rsvps,going}', '2'::jsonb, 'with the count');
select is(pg_temp.attendees(1, pg_temp.e('e1')), 'SYNTHETIC Rsvp Member 5,SYNTHETIC Rsvp Member 6',
  'an Admin reads them too');
select is(pg_temp.names(3, pg_temp.e('e1')) #>> '{}', 'PT403|forbidden|not_granted',
  'another editor is refused the names');
select is(pg_temp.names(4, pg_temp.e('e1')) #>> '{}', 'PT403|forbidden|not_granted', 'and so is a member');
select ok(pg_temp.names(null, pg_temp.e('e1')) #>> '{}' like '42501|%', 'and a guest');
select is(pg_temp.names(2, gen_random_uuid()), '{"rsvps": null}'::jsonb, 'an unknown event has no names');
select is(((pg_temp.staff(3, pg_temp.e('e1'))) ->> 'sees_names')::boolean, false,
  'the staff list tells another editor they read counts only');
select is((pg_temp.staff(3, pg_temp.e('e1'))) ->> 'rsvp_going', '2', 'and gives them the count');
select ok(position('SYNTHETIC Rsvp Member 5' in pg_temp.read(3, 'select api.content_staff_events()')::text) = 0
          and position(pg_temp.mid(5)::text in pg_temp.read(3, 'select api.content_staff_events()')::text) = 0,
  'no member going is named in the editors'' list');
select ok(position('SYNTHETIC Rsvp Member' in pg_temp.read(null, 'select api.content_public_events()')::text) = 0
          and position(pg_temp.mid(5)::text in pg_temp.read(null, 'select api.content_public_events()')::text) = 0,
  'nor in the public read');

-- Organisers -------------------------------------------------------------------------------------------
create function pg_temp.org(n int, p_ids jsonb, p_expected bigint default null) returns jsonb language sql as $$
  select pg_temp.cmd(n, 'content.set_event_organisers', coalesce(p_expected, pg_temp.rev(pg_temp.e('e1'))),
                     jsonb_build_object('event_id', pg_temp.e('e1'), 'organiser_ids', p_ids)) $$;
select is(pg_temp.err(pg_temp.org(3, jsonb_build_array(pg_temp.mid(3)))), 'forbidden',
  'an editor who is not an organiser cannot make themselves one');
select is(pg_temp.err(pg_temp.org(4, jsonb_build_array(pg_temp.mid(4)))), 'forbidden', 'nor can a member');
select is(pg_temp.err(pg_temp.org(2, jsonb_build_array(pg_temp.mid(2), pg_temp.mid(4)))),
  'validation_failed|organiser_ids=not_editor', 'organisers must edit events');
select is(pg_temp.err(pg_temp.org(2, jsonb_build_array(pg_temp.mid(2), pg_temp.mid(2)))),
  'validation_failed|organiser_ids=invalid', 'a member is listed once');
select is(pg_temp.err(pg_temp.org(2, (select jsonb_agg(gen_random_uuid()) from generate_series(1, 11)))),
  'validation_failed|organiser_ids=too_many', 'at most ten organisers');
select is(pg_temp.err(pg_temp.cmd(2, 'content.set_event_organisers', pg_temp.rev(pg_temp.e('e1')),
  jsonb_build_object('event_id', pg_temp.e('e1')))), 'validation_failed|organiser_ids=required', 'the list is required');
select is(pg_temp.err(pg_temp.org(2, jsonb_build_array(pg_temp.mid(2), pg_temp.mid(3)), 1)), 'conflict',
  'a stale tab is refused');
insert into v select 'e1rev2', null, to_jsonb(pg_temp.rev(pg_temp.e('e1')));
select is(pg_temp.err(pg_temp.org(2, jsonb_build_array(pg_temp.mid(2), pg_temp.mid(3)))), 'ok',
  'the organiser adds Media N');
select is(pg_temp.rev(pg_temp.e('e1')), (select (j #>> '{}')::bigint + 1 from v where k = 'e1rev2'),
  'the event''s revision moves on');
select is(pg_temp.attendees(3, pg_temp.e('e1')), 'SYNTHETIC Rsvp Member 5,SYNTHETIC Rsvp Member 6',
  'Media N now reads the names');
select is((pg_temp.staff(3, pg_temp.e('e1'))) -> 'organisers',
  jsonb_build_array(jsonb_build_object('member_id', pg_temp.mid(2), 'name', 'SYNTHETIC Rsvp Member 2'),
                    jsonb_build_object('member_id', pg_temp.mid(3), 'name', 'SYNTHETIC Rsvp Member 3')),
  'the staff list names the organisers');
insert into v select 'e1rev3', null, to_jsonb(pg_temp.rev(pg_temp.e('e1')));
select is(pg_temp.err(pg_temp.org(3, jsonb_build_array(pg_temp.mid(3), pg_temp.mid(2)))), 'ok', 'an unchanged list is accepted');
select is(pg_temp.rev(pg_temp.e('e1')), (select (j #>> '{}')::bigint from v where k = 'e1rev3'), 'and changes nothing');
select is(pg_temp.err(pg_temp.org(1, jsonb_build_array(pg_temp.mid(2), pg_temp.mid(11)))), 'ok',
  'an Admin who is not an organiser sets the list');
select is(pg_temp.names(3, pg_temp.e('e1')) #>> '{}', 'PT403|forbidden|not_granted', 'Media N reads counts only again');
select is((select organiser_state from app.content_event_organisers
            where item_id = pg_temp.e('e1') and member_id = pg_temp.mid(3)), 'removed', 'its row is kept as removed');
select ok(jsonb_array_length(pg_temp.read(3, 'select api.content_staff_events()') -> 'organiser_options') = 4,
  'the options are everyone who edits events now (Admin and three Media)');

-- Replay ---------------------------------------------------------------------------------------------------
create temp table rp as select pg_temp.rsvp(5, pg_temp.e('e1'), 'content.rsvp_event', (select req from g5)) as r;
select is((select r #>> '{data,rsvp_state}' from rp), 'going', 'a replay returns the stored answer');
-- The replay recheck runs with member B's claims (set by the call above).
select is(app.content_in_scope(pg_temp.u(5), 'content_rsvp', (select (r #>> '{data,rsvp_id}')::uuid from rp)), true,
  'member B''s own RSVP is in scope on a replay');
select is(app.content_in_scope(pg_temp.u(5), 'content_rsvp', pg_temp.e('g4')), false,
  'another member''s RSVP is not');

-- Lifecycle: a hold keeps, a deactivation releases, a revoked role ends an organiser role -------------------
select is(pg_temp.err(pg_temp.rsvp(8, pg_temp.e('e2'))), 'ok', 'member D goes to the breakfast');
select is(pg_temp.err(pg_temp.call(1, 'identity_credential_command', 'identity.place_hold', pg_temp.mrev(8),
  jsonb_build_object('member_id', pg_temp.mid(8), 'reason_code', 'login_disabled'))), 'ok', 'the Admin holds member D''s login');
select is((select rsvp_state from app.content_event_rsvps where item_id = pg_temp.e('e2') and member_id = pg_temp.mid(8)),
  'going', 'a login hold keeps the RSVP');
select is(pg_temp.err(pg_temp.rsvp(9, pg_temp.e('e2'))), 'ok', 'member E goes to the breakfast');
select is(pg_temp.err(pg_temp.call(1, 'identity_lifecycle_command', 'identity.deactivate_membership', pg_temp.mrev(9),
  jsonb_build_object('member_id', pg_temp.mid(9), 'reason_code', 'moved_away'))), 'ok', 'the Admin deactivates member E');
select is((select rsvp_state from app.content_event_rsvps where item_id = pg_temp.e('e2') and member_id = pg_temp.mid(9)),
  'released', 'the future RSVP is released');
select is(pg_temp.pub(pg_temp.e('e2')) #>> '{rsvp,going}', '2', 'and its place is free (A and D remain)');
select is((select rsvp_state from app.content_event_rsvps where item_id = pg_temp.e('e4') and member_id = pg_temp.mid(9)),
  'going', 'an RSVP to an event already under way is kept');
select is(pg_temp.err(pg_temp.call(1, 'identity_grant_command', 'identity.revoke_role', pg_temp.mrev(11),
  jsonb_build_object('member_id', pg_temp.mid(11), 'role', 'media'))), 'ok', 'the Admin removes Media R''s role');
select is((select organiser_state from app.content_event_organisers
            where item_id = pg_temp.e('e1') and member_id = pg_temp.mid(11)), 'removed',
  'Media R is no longer an organiser');

-- Deletion -------------------------------------------------------------------------------------------------
select is(pg_temp.err(pg_temp.rsvp(10, pg_temp.e('e2'))), 'ok', 'member F goes to the breakfast');
select ok((app.content_erase_member(jsonb_build_object('phase', 'check', 'member_id', pg_temp.mid(10),
  'account_id', pg_temp.u(10))) ->> 'remaining')::int > 0, 'the deletion check sees member F''s RSVP');
select is(app.content_erase_member(jsonb_build_object('phase', 'erase', 'member_id', pg_temp.mid(10),
  'account_id', pg_temp.u(10))), '{"remaining": 0}'::jsonb, 'erase leaves nothing of member F');
select is((select count(*)::int from app.content_event_rsvps where member_id = pg_temp.mid(10)), 0,
  'member F''s RSVP rows are deleted');
select is(app.content_erase_member(jsonb_build_object('phase', 'erase', 'member_id', pg_temp.mid(2),
  'account_id', pg_temp.u(2))), '{"remaining": 0}'::jsonb, 'erasing the organiser leaves nothing of them');
select is((select count(*)::int from app.content_event_organisers o
            where o.member_id = pg_temp.mid(2) or o.changed_by_member = pg_temp.mid(2)
               or o.changed_by_account = pg_temp.u(2)), 0,
  'their organiser rows are gone and who changed lists is anonymised');
-- Without the _rows migration's body the erase fails closed (the hosted rule).
create or replace function app.content_rsvp_purge_rows(p_member_id uuid) returns integer
language plpgsql set search_path = '' as $$
begin
  perform app.cmd_fail('unavailable', '{"deletion": "rows_migration_missing"}');
  return null;
end; $$;
select throws_ok(format($$select app.content_erase_member(jsonb_build_object('phase', 'erase',
  'member_id', %L, 'account_id', %L))$$, pg_temp.mid(4), pg_temp.u(4)),
  'PCMD1', 'unavailable', 'the stub refuses to erase until the rows migration is applied');
select is((app.content_erase_member(jsonb_build_object('phase', 'check', 'member_id', pg_temp.mid(4),
  'account_id', pg_temp.u(4))) ->> 'remaining')::int, 2, 'and the check still counts member A''s two RSVPs');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violation');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned object');

select * from finish();
rollback;
