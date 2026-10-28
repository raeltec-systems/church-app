-- Story 6.18: a preaching duty's topic and scripture sent to Media as a sermon draft. The duty's
-- current assignee or its managers send it through content.draft_sermon_from_duty, which reads the
-- duty only through the 4.11 owner read app.duties_owner_topic; one private draft per occurrence;
-- a second send answers the same draft; others are refused; the draft is invisible to anonymous
-- callers and members and is public only after Media completes and publishes it. HTTP evidence:
-- tools/identity-e2e/content-sermon-duty-drafts.mjs. Every account and name is SYNTHETIC; phones
-- are fictional (+44 7700 900112-900117, the entry's block; rolled back with the test).
-- Times are church time (Africa/Lusaka).
begin;
select plan(48);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000618' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000618' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '4477009001' || (11 + n)::text $$;
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
                             p_request uuid default null)
returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  execute format('select api.%I($1)', p_endpoint) into r using jsonb_build_object(
    'version', 1, 'command', p_command, 'request_id', coalesce(p_request, gen_random_uuid()),
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
create function pg_temp.rev(p uuid) returns bigint language sql as
$$ select revision from app.content_items where item_id = p $$;

-- Accounts: 1 Admin; 2 Media; 3 leader L of the Preaching Rota (D); 4 member M of D (the
-- assignee); 5 member O of D (not assigned); 6 leader K of the Ushers (E).
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', pg_temp.phone(n), now() from generate_series(1, 6) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 6) n;
select app.platform_set_environment('local', 'pgtap 6.18');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC 6.18 Member ' || n, 'pgtap 6.18')
  from generate_series(1, 6) n;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
create function pg_temp.grev(n int) returns bigint language sql as
$$ select revision from app.identity_grant_sets where member_id = pg_temp.mid($1) $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator) values (pg_temp.mid(2), 'media', 'israel');

create function pg_temp.dep(p_name text) returns uuid language sql as $$
  select (pg_temp.duties(1, 'duties.create_department', null, jsonb_build_object('name', p_name))
          #>> '{data,department_id}')::uuid
$$;
create temp table deps as select pg_temp.dep('SYNTHETIC Preaching Rota') as d, pg_temp.dep('SYNTHETIC 6.18 Ushers') as e;
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
select pg_temp.grant_scope(6, 'department_leader', pg_temp.e());
select pg_temp.add(n, pg_temp.d()) from unnest(array[3, 4, 5]) n;
select pg_temp.add(6, pg_temp.e());

-- Duties of member 4 in D: X (topic and scripture), W (scripture only), Z (neither), V (declined).
create temp table pubs (tag text primary key, r jsonb);
create function pg_temp.pub(p_tag text, p_days int, p_topic text, p_scripture text) returns jsonb
language plpgsql as $$
declare
  r jsonb;
  v_rev bigint;
begin
  r := pg_temp.duties(3, 'duties.publish_duty', null, jsonb_build_object(
         'department_id', pg_temp.d(), 'member_id', pg_temp.mid(4),
         'duty_name', 'SYNTHETIC Duty ' || p_tag, 'location', 'SYNTHETIC hall',
         'starts_at', app.cmd_utc(pg_temp.at(p_days))));
  if r ->> 'code' is not null then
    raise exception 'publish % failed: %', p_tag, r;
  end if;
  insert into pubs values (p_tag, r);
  if p_topic is not null or p_scripture is not null then
    select o.revision into v_rev from app.duties_occurrences o where o.occurrence_id = (r #>> '{data,occurrence_id}')::uuid;
    r := pg_temp.duties(3, 'duties.revise_duty', v_rev, jsonb_build_object(
           'occurrence_id', r #>> '{data,occurrence_id}', 'topic', p_topic, 'scripture', p_scripture));
    if r ->> 'code' is not null then
      raise exception 'revise % failed: %', p_tag, r;
    end if;
  end if;
  return r;
end;
$$;
create function pg_temp.occ(p_tag text) returns uuid language sql as
$$ select (r #>> '{data,occurrence_id}')::uuid from pubs where tag = p_tag $$;
select pg_temp.pub('X', 10, 'SYNTHETIC Walking in the light', 'SYNTHETIC 1 John 1:5-10');
select pg_temp.pub('W', 11, null, 'SYNTHETIC Psalm 23');
select pg_temp.pub('Z', 12, null, null);
select pg_temp.pub('V', 13, 'SYNTHETIC Declined topic', null);
create function pg_temp.send(n int, p_tag text) returns jsonb language sql as
$$ select pg_temp.cmd(n, 'content.draft_sermon_from_duty', null, jsonb_build_object('occurrence_id', pg_temp.occ(p_tag))) $$;
create function pg_temp.status(n int, p_tag text) returns jsonb language sql as
$$ select pg_temp.read(n, format('select api.content_duty_sermon_draft(%L::uuid)', pg_temp.occ(p_tag))) $$;
create function pg_temp.sermon(p_tag text) returns uuid language sql as
$$ select d.sermon_id from app.content_sermon_duty_drafts d where d.occurrence_id = pg_temp.occ(p_tag) $$;

-- Registries and privileges -------------------------------------------------------------------
select is((select kind || ':' || handler || ':' || creates from app.content_commands
            where command = 'content.draft_sermon_from_duty'),
  'sermon:app.content_sermon_from_duty(uuid,bigint,jsonb):true', 'the command is a create of the sermon kind');
select ok(exists (select 1 from app.content_member_commands where command = 'content.draft_sermon_from_duty'),
  'it is a member command: its handler checks the duty through Duties');
select is((select handler from app.content_replay_scopes where aggregate_type = 'content_sermon_duty_draft'),
  'app.content_sermon_duty_draft_in_scope(jsonb)', 'the replay recheck is registered');
select is((select handler from app.content_erase_parts where part = 'sermon_duty_drafts'),
  'app.content_sermon_duty_draft_erase_part(jsonb)', 'the erase part is registered');
select ok((select relrowsecurity from pg_class where oid = 'app.content_sermon_duty_drafts'::regclass)
  and not has_table_privilege('authenticated', 'app.content_sermon_duty_drafts', 'select')
  and not has_table_privilege('anon', 'app.content_sermon_duty_drafts', 'select'),
  'no client role reads the link table');
select ok(has_function_privilege('authenticated', 'api.content_duty_sermon_draft(uuid)', 'execute')
  and not has_function_privilege('anon', 'api.content_duty_sermon_draft(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'app.content_sermon_from_duty(uuid,bigint,jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'app.content_sermon_duty_draft_in_scope(jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'app.content_sermon_duty_draft_erase_part(jsonb)', 'execute'),
  'only the status read is client-executable, and only signed in');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violation');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'no unowned object');

-- Status before sending ----------------------------------------------------------------------
select is(pg_temp.status(4, 'X') - 'occurrence_id', '{"can_send": true, "draft": null}'::jsonb,
  'the assignee can send a duty with a topic; nothing sent yet');
select is(pg_temp.status(3, 'Z') - 'occurrence_id', '{"can_send": false, "draft": null}'::jsonb,
  'a manager reads it too; a duty with neither topic nor scripture cannot be sent');
select is(pg_temp.status(5, 'X') #>> '{}', 'PT403|forbidden|not_granted', 'a member without the duty is refused');
select is(pg_temp.status(6, 'X') #>> '{}', 'PT403|forbidden|not_granted', 'a leader of another department is refused');
select is(pg_temp.status(2, 'X') #>> '{}', 'PT403|forbidden|not_granted', 'Media does not read the duty');
select is(left(pg_temp.status(null, 'X') #>> '{}', 5), '42501', 'anonymous callers are refused');

-- Refusals -----------------------------------------------------------------------------------
select is(pg_temp.err(pg_temp.send(5, 'X')), 'not_found', 'a member without the duty cannot send it');
select is(pg_temp.err(pg_temp.send(6, 'X')), 'not_found', 'a leader of another department cannot send it');
select is(pg_temp.err(pg_temp.send(2, 'X')), 'not_found', 'Media cannot pull a duty itself');
select is(pg_temp.err(pg_temp.send(3, 'Z')), 'validation_failed|occurrence_id=no_topic',
  'a duty with neither topic nor scripture is refused');
select is(pg_temp.err(pg_temp.cmd(4, 'content.draft_sermon_from_duty', null, '{}')),
  'validation_failed|occurrence_id=required', 'the occurrence is required');
select is(pg_temp.err(pg_temp.cmd(4, 'content.draft_sermon_from_duty', null,
  jsonb_build_object('occurrence_id', pg_temp.occ('X'), 'title', 'x'))),
  'validation_failed|title=unknown_field', 'no other field is accepted (no speaker or private field)');
select is(pg_temp.err(pg_temp.cmd(4, 'content.draft_sermon_from_duty', null,
  jsonb_build_object('occurrence_id', gen_random_uuid()))), 'not_found', 'an unknown occurrence is not found');
select is(pg_temp.err(pg_temp.duties(4, 'duties.respond',
  (select a.revision from app.duties_assignments a where a.assignment_id = (select (r #>> '{data,assignment_id}')::uuid from pubs where tag = 'V')),
  jsonb_build_object('assignment_id', (select r #>> '{data,assignment_id}' from pubs where tag = 'V'),
                     'response', 'declined', 'note', 'SYNTHETIC away'))), 'ok', 'setup: member 4 declines V');
select is(pg_temp.err(pg_temp.send(4, 'V')), 'not_found', 'a member who declined is no longer the current assignee');
select is((select count(*)::int from app.content_sermon_duty_drafts), 0, 'no refused send made a draft');

-- The assignee sends; a second send answers the same draft -------------------------------------
create temp table first as select pg_temp.send(4, 'X') as r;
select is((select pg_temp.err(r) || '|' || (r #>> '{data,created}') from first), 'ok|true',
  'the assignee sends the duty to Media');
select is((select (r #>> '{data,sermon_id}')::uuid from first), pg_temp.sermon('X'), 'it answers the draft');
select is((select row(r.title, r.speaker, r.sermon_date, r.scripture_reference, r.notes, r.series_id,
                      r.youtube_video_id, r.facebook_video_url, r.video_rights_id)::text
             from app.content_sermon_revisions r where r.item_id = pg_temp.sermon('X')),
  row('SYNTHETIC Walking in the light', null::text, (pg_temp.at(10) at time zone 'Africa/Lusaka')::date,
      'SYNTHETIC 1 John 1:5-10', '', null::uuid, null::text, null::text, null::uuid)::text,
  'title from the topic, scripture and church date; no speaker, notes, series or video');
select is((select lifecycle_state || ':' || coalesce(live_revision_no::text, '-') from app.content_items
            where item_id = pg_temp.sermon('X')), 'draft:-', 'it is a private draft');
select is((select actor_capacity || ':' || action from app.content_audit where item_id = pg_temp.sermon('X')),
  'duty_assignee:created', 'its creation is attributed to the assignee');
select is((select pg_temp.err(r) || '|' || (r #>> '{data,created}') || '|' || (r #>> '{data,sermon_id}')
             from (select pg_temp.send(4, 'X') as r) t),
  'ok|false|' || pg_temp.sermon('X'), 'a second send returns the same draft');
select is((select pg_temp.err(r) || '|' || (r #>> '{data,created}') || '|' || (r #>> '{data,sermon_id}')
             from (select pg_temp.send(3, 'X') as r) t),
  'ok|false|' || pg_temp.sermon('X'), 'the department leader gets the same draft');
select is((select pg_temp.err(r) || '|' || (r #>> '{data,created}')
             from (select pg_temp.send(1, 'X') as r) t), 'ok|false', 'an Admin manages it too');
create temp table rq as select gen_random_uuid() as id;
select is((select pg_temp.call(4, 'content_command', 'content.draft_sermon_from_duty', null,
            jsonb_build_object('occurrence_id', pg_temp.occ('X')), id) #>> '{data,sermon_id}' from rq),
  pg_temp.sermon('X')::text, 'a request sent again replays');
select is((select pg_temp.call(4, 'content_command', 'content.draft_sermon_from_duty', null,
            jsonb_build_object('occurrence_id', pg_temp.occ('X')), id) #>> '{data,sermon_id}' from rq),
  pg_temp.sermon('X')::text, 'the replay recheck keeps the assignee in scope');
select is((select count(*)::int from app.content_items i join app.content_sermon_duty_drafts d on d.sermon_id = i.item_id
            where d.occurrence_id = pg_temp.occ('X')), 1, 'one draft per occurrence');

-- Scripture only, sent by a manager ----------------------------------------------------------
select is(pg_temp.err(pg_temp.send(3, 'W')), 'ok', 'the leader sends a duty with scripture only');
select is((select r.title || '|' || a.actor_capacity from app.content_sermon_revisions r
             join app.content_audit a on a.item_id = r.item_id where r.item_id = pg_temp.sermon('W')),
  'SYNTHETIC Psalm 23|duty_manager', 'its title is the scripture; attributed to a manager');

-- Invisible until Media completes and publishes it --------------------------------------------
select is(pg_temp.read(null, format('select api.content_public_sermon(%L::uuid)', pg_temp.sermon('X'))) -> 'sermon',
  'null'::jsonb, 'anonymous callers cannot read the draft');
select ok(not (pg_temp.read(4, 'select api.content_public_sermons()')::text like '%Walking in the light%'),
  'members do not see it in the public catalog');
select is(pg_temp.read(4, 'select api.content_staff_sermons()') #>> '{}', 'PT403|forbidden|not_granted',
  'the assignee cannot open the staff sermon list');
select is((select (s -> 'from_duty') - 'sent_at'::text from jsonb_array_elements(pg_temp.read(2, 'select api.content_staff_sermons()') -> 'sermons') s
            where s ->> 'sermon_id' = pg_temp.sermon('X')::text),
  jsonb_build_object('duty_name', 'SYNTHETIC Duty X', 'duty_starts_at', app.cmd_utc(pg_temp.at(10))),
  'Media sees the draft marked as from a duty, never who sent it');
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_sermon', pg_temp.rev(pg_temp.sermon('X')),
  jsonb_build_object('sermon_id', pg_temp.sermon('X')))), 'validation_failed|speaker=required',
  'an incomplete draft cannot be published');
select is(pg_temp.err(pg_temp.cmd(2, 'content.save_sermon', pg_temp.rev(pg_temp.sermon('X')),
  jsonb_build_object('sermon_id', pg_temp.sermon('X'), 'title', 'SYNTHETIC Walking in the light',
    'speaker', 'SYNTHETIC Preacher', 'sermon_date', ((pg_temp.at(10) at time zone 'Africa/Lusaka')::date)::text,
    'scripture_reference', 'SYNTHETIC 1 John 1:5-10', 'notes', 'SYNTHETIC notes.'))), 'ok', 'Media completes it');
select is(pg_temp.read(null, format('select api.content_public_sermon(%L::uuid)', pg_temp.sermon('X'))) -> 'sermon',
  'null'::jsonb, 'still nothing public before publishing');
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_sermon', pg_temp.rev(pg_temp.sermon('X')),
  jsonb_build_object('sermon_id', pg_temp.sermon('X')))), 'ok', 'Media publishes it');
select is(pg_temp.read(null, format('select api.content_public_sermon(%L::uuid)', pg_temp.sermon('X'))) #>> '{sermon,speaker}',
  'SYNTHETIC Preacher', 'now it is public');
select is(pg_temp.status(4, 'X') #> '{draft,published}', 'true'::jsonb, 'the assignee sees it was published');

-- Deletion -----------------------------------------------------------------------------------
select is(app.content_sermon_duty_draft_erase_part(jsonb_build_object('phase', 'erase',
  'member_id', pg_temp.mid(4), 'account_id', pg_temp.u(4))), 0, 'erase anonymises the sender');

select * from finish();
rollback;
