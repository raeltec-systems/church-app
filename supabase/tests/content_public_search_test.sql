-- Epic 6 entry 14: the bounded public search read (api.content_public_search). All fixtures are
-- SYNTHETIC; UK phones are fictional Ofcom numbers (+44 7700 900571-900574, the entry's block;
-- rolled back with the test).
begin;
select plan(42);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000614' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000614' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.c(n int) returns jsonb language sql as $$
  select jsonb_build_object('sub', pg_temp.u(n), 'role', 'authenticated', 'aal', 'aal1',
    'session_id', pg_temp.s(n), 'is_anonymous', false,
    'amr', jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', 1790000000)))
$$;
create function pg_temp.cmd(n int, p_command text, p_expected bigint, p_payload jsonb) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  r := api.content_command(jsonb_build_object('version', 1, 'command', p_command,
    'request_id', gen_random_uuid(), 'expected_revision', p_expected, 'payload', p_payload));
  reset role;
  return r;
end;
$$;
-- A read as anon (n null) or as a signed-in account; an error comes back as 'state|message|detail'.
create function pg_temp.read(n int, p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; v_state text; v_msg text; v_detail text;
begin
  if n is null then
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
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
create function pg_temp.search(n int, q text) returns jsonb language sql as $$
  select pg_temp.read(n, format('select api.content_public_search(%L)', q))
$$;
create temp table v(k text primary key, id uuid);
-- The ids found for one kind, in order, as the fixture keys.
create function pg_temp.found(r jsonb, p_kind text, p_id text) returns text language sql as $$
  select coalesce(string_agg(v.k, ',' order by x.o), '')
    from jsonb_array_elements(r -> p_kind) with ordinality x(e, o)
    join v on v.id = (x.e ->> p_id)::uuid
$$;
create function pg_temp.at(p_days int, p_time text default '10:00') returns timestamptz language sql as
$$ select (((now() at time zone 'Africa/Lusaka')::date + p_days) + p_time::time) at time zone 'Africa/Lusaka' $$;
create function pg_temp.iso(p timestamptz) returns text language sql as
$$ select to_char(p at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') $$;

insert into auth.users(id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', '447700900' || (570 + n)::text, now()
  from generate_series(1, 4) n;
insert into auth.sessions(id, user_id, aal, created_at)
select pg_temp.s(n), pg_temp.u(n), 'aal1', clock_timestamp() - interval '1 hour' from generate_series(1, 4) n;
insert into auth.mfa_amr_claims(id, session_id, created_at, updated_at, authentication_method)
select gen_random_uuid(), pg_temp.s(n), now(), now(), 'password' from generate_series(1, 4) n;
select app.platform_set_environment('local', 'pgtap SYNTHETIC search');
-- 1 Admin, 2 Media, 3 plain member; 4 has an account and no member (a Pending applicant).
create temp table m(n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC Search ' || n, 'pgtap search')
  from generate_series(1, 3) n;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants(member_id, role, granted_by_operator) values (pg_temp.mid(2), 'media', 'israel');

-- Structure and privileges ----------------------------------------------------------------------
select has_function('api', 'content_public_search', array['text'], 'api.content_public_search(text) exists');
select is_definer('app', 'content_public_search', array['text'], 'the search body is a definer');
select isnt_definer('api', 'content_public_search', array['text'], 'its api wrapper is invoker');
select ok(has_function_privilege('anon', 'api.content_public_search(text)', 'execute')
          and has_function_privilege('authenticated', 'api.content_public_search(text)', 'execute'),
  'anon and authenticated may search');
select ok(not has_function_privilege('service_role', 'api.content_public_search(text)', 'execute')
          and not has_function_privilege('public', 'app.content_public_search(text)', 'execute'),
  'no other role holds EXECUTE');
select is((select count(*)::int from app.content_commands where command like '%search%'), 0,
  'search registers no command');

-- Fixtures: published, draft, withdrawn and ended items of each kind -------------------------------
-- Sermons: s1 in the series "SYNTHETIC Psalms of trust", s2 plain, s3 a draft, s4 withdrawn.
insert into v values ('series', (pg_temp.cmd(2, 'content.create_sermon_series', null,
  '{"title":"SYNTHETIC Psalms of trust","description":"","alt_text":"SYNTHETIC poster"}') #>> '{data,series_id}')::uuid);
select pg_temp.cmd(2, 'content.publish_sermon_series', 1, jsonb_build_object('series_id', (select id from v where k = 'series')));
create function pg_temp.sermon(p_title text, p_speaker text, p_scripture text, p_notes text, p_series uuid,
                               p_date text) returns jsonb language sql as $$
  select jsonb_build_object('title', p_title, 'speaker', p_speaker, 'sermon_date', p_date,
    'scripture_reference', p_scripture, 'notes', p_notes, 'series_id', p_series,
    'youtube_video_id', null, 'video_rights_id', null)
$$;
insert into v values ('s1', (pg_temp.cmd(2, 'content.create_sermon', null, pg_temp.sermon(
  'SYNTHETIC The Lord is my shepherd', 'SYNTHETIC Pastor Banda', 'Psalm 23:1-6', 'Rest by still waters.',
  (select id from v where k = 'series'), '2026-10-18')) #>> '{data,sermon_id}')::uuid);
insert into v values ('s2', (pg_temp.cmd(2, 'content.create_sermon', null, pg_temp.sermon(
  'SYNTHETIC Faith that works', 'SYNTHETIC Elder Phiri', 'James 2:14-26', 'A shepherd''s care for the flock.',
  null, '2026-10-25')) #>> '{data,sermon_id}')::uuid);
insert into v values ('s3', (pg_temp.cmd(2, 'content.create_sermon', null, pg_temp.sermon(
  'SYNTHETIC Shepherd draft', 'SYNTHETIC Pastor Banda', 'John 10:11', 'Draft only.', null, '2026-10-26'))
  #>> '{data,sermon_id}')::uuid);
insert into v values ('s4', (pg_temp.cmd(2, 'content.create_sermon', null, pg_temp.sermon(
  'SYNTHETIC Shepherd withdrawn', 'SYNTHETIC Pastor Banda', 'John 10:14', 'Withdrawn.', null, '2026-10-11'))
  #>> '{data,sermon_id}')::uuid);
select pg_temp.cmd(2, 'content.publish_sermon', 1, jsonb_build_object('sermon_id', id)) from v where k in ('s1', 's2', 's4');
select pg_temp.cmd(2, 'content.withdraw_sermon', 2, jsonb_build_object('sermon_id', id)) from v where k = 's4';

-- Events: e1 next week, e2 tomorrow, e3 a draft, e4 withdrawn.
create function pg_temp.ev(p_title text, p_from timestamptz, p_to timestamptz, p_where text) returns jsonb
language sql as $$
  select jsonb_build_object('title', p_title, 'description', 'SYNTHETIC gathering with tea.',
    'starts_at', pg_temp.iso(p_from), 'ends_at', pg_temp.iso(p_to), 'location', p_where)
$$;
insert into v values ('e1', (pg_temp.cmd(2, 'content.create_event', null, pg_temp.ev('SYNTHETIC Youth camp',
  pg_temp.at(7, '09:00'), pg_temp.at(7, '17:00'), 'SYNTHETIC Kafue river grounds')) #>> '{data,event_id}')::uuid);
insert into v values ('e2', (pg_temp.cmd(2, 'content.create_event', null, pg_temp.ev('SYNTHETIC Choir practice',
  pg_temp.at(1, '18:00'), pg_temp.at(1, '20:00'), 'SYNTHETIC Youth hall')) #>> '{data,event_id}')::uuid);
insert into v values ('e3', (pg_temp.cmd(2, 'content.create_event', null, pg_temp.ev('SYNTHETIC Youth draft',
  pg_temp.at(2, '09:00'), pg_temp.at(2, '10:00'), 'SYNTHETIC Hall')) #>> '{data,event_id}')::uuid);
insert into v values ('e4', (pg_temp.cmd(2, 'content.create_event', null, pg_temp.ev('SYNTHETIC Youth withdrawn',
  pg_temp.at(3, '09:00'), pg_temp.at(3, '10:00'), 'SYNTHETIC Hall')) #>> '{data,event_id}')::uuid);
select pg_temp.cmd(2, 'content.publish_event', 1, jsonb_build_object('event_id', id)) from v where k in ('e1', 'e2', 'e4');
select pg_temp.cmd(2, 'content.withdraw_event', 2, jsonb_build_object('event_id', id)) from v where k = 'e4';

-- Announcements: a1 pinned, a2 not pinned, a3 a draft.
create function pg_temp.an(p_title text, p_body text, p_pinned boolean) returns jsonb language sql as $$
  select jsonb_build_object('title', p_title, 'body', p_body, 'pinned', p_pinned)
$$;
insert into v values ('a1', (pg_temp.cmd(2, 'content.create_announcement', null, pg_temp.an(
  'SYNTHETIC Harvest week', 'SYNTHETIC Bring produce for the harvest; 100% welcome_all.', true)) #>> '{data,announcement_id}')::uuid);
insert into v values ('a2', (pg_temp.cmd(2, 'content.create_announcement', null, pg_temp.an(
  'SYNTHETIC Youth harvest supper', 'SYNTHETIC Supper after the service.', false)) #>> '{data,announcement_id}')::uuid);
insert into v values ('a3', (pg_temp.cmd(2, 'content.create_announcement', null, pg_temp.an(
  'SYNTHETIC Harvest draft', 'SYNTHETIC Draft.', true)) #>> '{data,announcement_id}')::uuid);
select pg_temp.cmd(2, 'content.publish_announcement', 1, jsonb_build_object('announcement_id', id, 'notify', false))
  from v where k in ('a1', 'a2');

select is((select count(*)::int from app.content_items i join v on v.id = i.item_id
            where i.lifecycle_state = 'published'), 7, 'fixtures: seven published items (and the series)');

-- What a search returns ------------------------------------------------------------------------
select is(jsonb_object_keys_sorted, 'announcements,events,query,sermons,truncated', 'the answer has exactly five keys')
  from (select string_agg(k, ',' order by k) as jsonb_object_keys_sorted
          from jsonb_object_keys(pg_temp.search(null, 'synthetic')) k) x;
select is(pg_temp.found(pg_temp.search(null, 'shepherd'), 'sermons', 'sermon_id'), 's1,s2',
  'a word finds published sermons by title and by notes, the title match first (drafts and withdrawn left out)');
select is(pg_temp.search(null, 'shepherd') -> 'sermons' -> 0,
  app.content_public_sermon_json((select id from v where k = 's1')),
  'a sermon comes back as its public projection, byte for byte');
select is(pg_temp.found(pg_temp.search(null, 'psalms of trust'), 'sermons', 'sermon_id'), 's1',
  'the published series title finds its sermons');
select is(pg_temp.found(pg_temp.search(null, 'banda'), 'sermons', 'sermon_id'), 's1', 'the speaker is searched');
select is(pg_temp.found(pg_temp.search(null, 'james 2'), 'sermons', 'sermon_id'), 's2', 'the scripture is searched');
select is(pg_temp.found(pg_temp.search(null, 'youth'), 'events', 'event_id'), 'e1,e2',
  'events: title match first, then the location match; drafts and withdrawn left out');
select is(pg_temp.search(null, 'youth') -> 'events' -> 0,
  app.content_public_event_json((select id from v where k = 'e1')), 'an event comes back as its public projection');
select is(pg_temp.found(pg_temp.search(null, 'kafue river'), 'events', 'event_id'), 'e1', 'the location is searched');
select is(pg_temp.found(pg_temp.search(null, 'harvest'), 'announcements', 'announcement_id'), 'a1,a2',
  'announcements: pinned first among title matches; the draft is left out');
select is(pg_temp.search(null, 'harvest') -> 'announcements' -> 0,
  app.content_public_announcement_json((select id from v where k = 'a1')),
  'an announcement comes back as its public projection');
select is(pg_temp.found(pg_temp.search(null, 'supper'), 'announcements', 'announcement_id'), 'a2',
  'the body is searched');
select is(pg_temp.found(pg_temp.search(null, 'youth'), 'announcements', 'announcement_id'), 'a2',
  'one word can find several kinds');
select is(pg_temp.found(pg_temp.search(null, 'HARVEST   Week'), 'announcements', 'announcement_id'), 'a1',
  'case and extra spaces do not matter; every word must match');
select is(pg_temp.search(null, '  HARVEST   Week ') ->> 'query', 'HARVEST Week', 'the query is echoed trimmed and folded');
select is(pg_temp.found(pg_temp.search(null, '100%'), 'announcements', 'announcement_id'), 'a1',
  'a percent sign matches itself');
select is(pg_temp.found(pg_temp.search(null, 'welcome_all'), 'announcements', 'announcement_id'), 'a1',
  'an underscore matches itself');
select is(pg_temp.found(pg_temp.search(null, 'h%t'), 'announcements', 'announcement_id'), '',
  'pattern characters are not wildcards');
select is(pg_temp.search(null, 'nothing matches this'),
  '{"query": "nothing matches this", "sermons": [], "events": [], "announcements": [], "truncated": false}'::jsonb,
  'no match: three empty lists, not truncated');
select is(pg_temp.search(4, 'harvest'), pg_temp.search(null, 'harvest'), 'a Pending account reads what a guest reads');
select is(pg_temp.search(3, 'shepherd'), pg_temp.search(null, 'shepherd'), 'a member reads what a guest reads');
select ok(pg_temp.search(null, 'synthetic')::text !~ 'saved_by|created_by|member_id|Search [123]',
  'no editor, attribution or member id in an answer');

-- Bounds ---------------------------------------------------------------------------------------
select is(pg_temp.search(null, 'a') #>> '{}', '22023|invalid|query', 'one character is refused');
select is(pg_temp.search(null, '   ') #>> '{}', '22023|invalid|query', 'blank is refused');
select is(pg_temp.read(null, 'select api.content_public_search(null)') #>> '{}', '22023|invalid|query',
  'null is refused');
select is(pg_temp.search(null, repeat('x', 101)) #>> '{}', '22023|invalid|query', '101 characters are refused');
select is(pg_temp.search(null, repeat('x', 100)) -> 'sermons', '[]'::jsonb, '100 characters are accepted');
select is(pg_temp.found(pg_temp.search(null, 'harvest week x1 x2 x3 x4 x5 x6 nine'), 'announcements', 'announcement_id'), '',
  'eight words count');
select is(pg_temp.found(pg_temp.search(null, 'harvest synthetic synthetic synthetic synthetic synthetic synthetic week ninth-word-ignored'),
  'announcements', 'announcement_id'), 'a1', 'a ninth word is ignored');

-- Twelve matching announcements: ten come back and truncated says more exist.
select pg_temp.cmd(2, 'content.publish_announcement', 1, jsonb_build_object('announcement_id',
  (pg_temp.cmd(2, 'content.create_announcement', null, pg_temp.an('SYNTHETIC Bulk notice ' || n,
    'SYNTHETIC bulk body.', false)) #>> '{data,announcement_id}')::uuid, 'notify', false))
  from generate_series(1, 12) n;
select is(jsonb_array_length(pg_temp.search(null, 'bulk notice') -> 'announcements'), 10, 'at most ten of a kind');
select is(pg_temp.search(null, 'bulk notice') -> 'truncated', 'true'::jsonb, 'truncated says more exist');
select is(pg_temp.search(null, 'harvest') -> 'truncated', 'false'::jsonb, 'a small answer is not truncated');

-- An event that has ended is not found (as on the public list).
insert into v values ('e5', (pg_temp.cmd(2, 'content.create_event', null, pg_temp.ev('SYNTHETIC Youth yesterday',
  pg_temp.at(-1, '09:00'), pg_temp.at(-1, '11:00'), 'SYNTHETIC Hall')) #>> '{data,event_id}')::uuid);
select pg_temp.cmd(2, 'content.publish_event', 1, jsonb_build_object('event_id', id)) from v where k = 'e5';
select is(pg_temp.found(pg_temp.search(null, 'youth'), 'events', 'event_id'), 'e1,e2', 'an ended event is not found');

select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no module boundary violation');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned object');

select * from finish();
rollback;
