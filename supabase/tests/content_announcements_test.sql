-- Story 6.13: pinned announcements with an optional generic notice. The kind and its registries,
-- privileges, the five commands for Media, Pastor and Admin (and their refusals for a plain member,
-- a Pending account and anon), drafts that stay private, the anonymous read (pinned first,
-- projection only), the notice on publication (one job per member the app can notify now; held,
-- deactivated and accountless members, Pending accounts and guests get none), the worker's inbox
-- items and push jobs (a member who turned the category off gets the item only), the generic push
-- message (no announcement text), cancellation on withdrawal, archive and a newer revision, one
-- notice per revision, the recipient recheck, the limit, replay, the Q2 gate and the deletion
-- erase part. Every account, phone and name is SYNTHETIC (fictional +44 7700 900681-900689).
begin;
select plan(137);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000613' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000613' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.w(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-c000-0000000613' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+4477009006' || (80 + n)::text $$;
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
-- A 1.4 command as account n on api.<endpoint>.
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
create temp table m (n int primary key, member_id uuid);
grant select on m to authenticated;
create function pg_temp.mid(p_n int) returns uuid language plpgsql as
$$ begin return (select member_id from m where n = p_n); end $$;
create function pg_temp.an(p_title text, p_pinned boolean, p_extra jsonb default '{}'::jsonb) returns jsonb
language sql as $$
  select jsonb_build_object('title', p_title, 'body', 'SYNTHETIC body of ' || p_title || '. Bring a friend.',
                            'pinned', p_pinned) || p_extra
$$;
create function pg_temp.rev(p uuid) returns bigint language sql as
$$ select revision from app.content_items where item_id = p $$;
create function pg_temp.deliver() returns jsonb language sql as
$$ select app.notifications_sys_deliver_due(gen_random_uuid(), gen_random_uuid(), '{}') -> 'data' $$;
-- Jobs of an announcement, as 'member n:state|reason' sorted by n.
create function pg_temp.jobs(p_item uuid) returns text language sql as $$
  select coalesce(string_agg(m.n || ':' || j.job_state || '|' || coalesce(j.finish_reason, j.cancel_reason, '-'),
                             ',' order by m.n), '')
    from app.notifications_jobs j join m on m.member_id = j.recipient_member_id
   where j.source_type = 'content_announcement' and j.source_id = p_item
$$;
create function pg_temp.items(p_item uuid) returns text language sql as $$
  select coalesce(string_agg(m.n::text, ',' order by m.n), '')
    from app.notifications_inbox_items i join app.notifications_jobs j on j.job_id = i.job_id
    join m on m.member_id = i.recipient_member_id
   where j.source_type = 'content_announcement' and j.source_id = p_item
$$;
create function pg_temp.pushes(p_item uuid) returns text language sql as $$
  select coalesce(string_agg(m.n::text, ',' order by m.n), '')
    from app.notifications_push_jobs p join app.notifications_jobs j on j.job_id = p.job_id
    join m on m.member_id = p.recipient_member_id
   where j.source_type = 'content_announcement' and j.source_id = p_item
$$;
create function pg_temp.item_for(p_item uuid, n int) returns uuid language sql as $$
  select i.item_id from app.notifications_inbox_items i join app.notifications_jobs j on j.job_id = i.job_id
   where j.source_type = 'content_announcement' and j.source_id = p_item and i.recipient_member_id = pg_temp.mid(n)
   order by i.delivered_at desc limit 1
$$;
create function pg_temp.titles(p jsonb) returns text language sql as $$
  select string_agg(e ->> 'title', ' / ' order by o) from jsonb_array_elements(p -> 'announcements') with ordinality x(e, o)
$$;

-- Accounts: 1 Admin; 2 Pastor; 3 Media M; 4 member A (device); 5 Pending (no member link);
-- 6 member B (device, category off); 7 Media E (erased at the end); 8 member C (device, held);
-- 9 member D (device, deactivated). Member 10 is approved without any account.
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 9) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 9) n;
select app.platform_set_environment('local', 'pgtap content announcements');
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC Announce Member ' || n,
                                                         'pgtap content announcements')
  from generate_series(1, 9) n where n <> 5;
with x as (insert into app.identity_members (display_name, membership_state, is_synthetic)
           values ('SYNTHETIC Announce Accountless', 'approved', true) returning member_id)
insert into m select 10, member_id from x;
create function pg_temp.mrev(n int) returns bigint language sql as
$$ select revision from app.identity_members where member_id = pg_temp.mid($1) $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator)
values (pg_temp.mid(2), 'pastor', 'israel'), (pg_temp.mid(3), 'media', 'israel'),
       (pg_temp.mid(7), 'media', 'israel');
create temp table v (k text primary key, id uuid, j jsonb);
grant select on v to authenticated;

-- Structure, registries and privileges ----------------------------------------------------------
select has_table('app', 'content_announcement_revisions', 'app.content_announcement_revisions exists');
select ok((select c.relrowsecurity from pg_class c where c.oid = 'app.content_announcement_revisions'::regclass),
  'RLS is enabled on the revisions table');
select is((select count(*)::int from unnest(array['anon', 'authenticated', 'service_role']) r
            where has_table_privilege(r, 'app.content_announcement_revisions', 'SELECT')
               or has_table_privilege(r, 'app.content_announcement_revisions', 'INSERT')
               or has_table_privilege(r, 'app.content_announcement_revisions', 'UPDATE')
               or has_table_privilege(r, 'app.content_announcement_revisions', 'DELETE')),
  0, 'no client role has any privilege on the revisions table');
select results_eq(
  $$select (n.nspname || '.' || p.proname)::text collate "C" from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'api') and p.proname like 'content\_%announcement%'
       and has_function_privilege('anon', p.oid, 'EXECUTE') order by 1$$,
  $$values ('api.content_public_announcement'::text collate "C"), ('api.content_public_announcements'),
           ('app.content_public_announcement'), ('app.content_public_announcements')$$,
  'anon can execute only the two public announcement reads');
select results_eq(
  $$select (n.nspname || '.' || p.proname)::text collate "C" from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'api') and p.proname like 'content\_%announcement%'
       and has_function_privilege('authenticated', p.oid, 'EXECUTE') order by 1$$,
  $$values ('api.content_public_announcement'::text collate "C"), ('api.content_public_announcements'),
           ('api.content_staff_announcements'), ('app.content_public_announcement'),
           ('app.content_public_announcements'), ('app.content_staff_announcements')$$,
  'authenticated can execute only the public reads and the editors'' read');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('app', 'api') and p.proname like 'content\_%announcement%'
              and has_function_privilege('service_role', p.oid, 'EXECUTE')), 0,
  'service_role executes no announcement function');
select is_definer('app', 'content_public_announcements', array[]::text[], 'the public read body is a definer');
select isnt_definer('api', 'content_public_announcements', array[]::text[], 'the public api wrapper is invoker');
select results_eq($$select editor_roles from app.content_kinds where kind = 'announcement'$$,
  $$values (array['admin', 'pastor', 'media']::text[])$$, 'announcements are edited by Admin, Pastor and Media');
select results_eq($$select command || ':' || handler || ':' || creates from app.content_commands
                    where kind = 'announcement' order by 1$$,
  $$values ('content.archive_announcement:app.content_announcement_archive(uuid,bigint,jsonb):false'::text),
           ('content.create_announcement:app.content_announcement_create(uuid,bigint,jsonb):true'),
           ('content.publish_announcement:app.content_announcement_publish(uuid,bigint,jsonb):false'),
           ('content.save_announcement:app.content_announcement_save(uuid,bigint,jsonb):false'),
           ('content.withdraw_announcement:app.content_announcement_withdraw(uuid,bigint,jsonb):false')$$,
  'the five announcement commands are registered');
select is((select handler from app.content_erase_parts where part = 'announcement_revisions'),
  'app.content_announcement_erase_part(jsonb)', 'the announcements erase part is registered');
select is((select handler from app.identity_deletion_hooks where module = 'content'),
  'app.content_erase_member(jsonb)', 'Content still has its one deletion hook');
select is((select module || '|' || check_hook from app.contract_source_types where source_type = 'content_announcement'),
  'content|app.content_announcement_source_check(jsonb)', 'Content owns the announcement source type');
select is((select module || '|' || check_hook || '|' || title || '|' || body || '|' || link
             from app.contract_reminder_contracts
            where source_type = 'content_announcement' and reminder_kind = 'announcement_published'),
  'content|app.content_announcement_reminder_check(jsonb)|Church announcement|The church has posted an announcement. Open the app to read it.|/announcements/{source_id}',
  'the notice contract: generic text and the deep link');
select is((select count(*)::int from app.contract_direct_contact_routes where source_type = 'content_announcement'), 0,
  'no direct-contact route: a public announcement creates no contact need');
select is((select count(*)::int from app.contract_unowned_objects()), 0, 'every object has an owner');
select is((select count(*)::int from app.contract_unpinned_functions()), 0, 'every function pins search_path');
select is((select count(*)::int from app.contract_boundary_violations()), 0, 'no boundary violations');

-- Create and save: who may, and what is refused ---------------------------------------------------
insert into v (k, j) values ('a1', pg_temp.cmd(3, 'content.create_announcement', null,
  pg_temp.an('SYNTHETIC Harvest week', true)));
create function pg_temp.a1() returns uuid language sql as $$ select (j #>> '{data,announcement_id}')::uuid from v where k = 'a1' $$;
select is((select (j -> 'data') - 'announcement_id' from v where k = 'a1'),
  '{"state": "draft", "revision": 1, "live_revision_no": null, "draft_revision_no": 1}'::jsonb,
  'Media creates a private draft');
select is(pg_temp.err(pg_temp.cmd(2, 'content.create_announcement', null, pg_temp.an('SYNTHETIC Pastor note', false))),
  'ok', 'a Pastor may create');
select is(pg_temp.err(pg_temp.cmd(1, 'content.create_announcement', null, pg_temp.an('SYNTHETIC Admin note', false))),
  'ok', 'an Admin may create');
select is(pg_temp.err(pg_temp.cmd(4, 'content.create_announcement', null, pg_temp.an('SYNTHETIC Member note', false))),
  'forbidden', 'a plain member cannot create');
select is(pg_temp.err(pg_temp.cmd(5, 'content.create_announcement', null, pg_temp.an('SYNTHETIC Pending note', false))),
  'forbidden', 'a Pending account cannot create');
select is(pg_temp.read(null, $q$select api.content_command('{"version": 1}'::jsonb)$q$) #>> '{}',
  '42501|permission denied for function content_command|', 'anon cannot execute the command');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_announcement', null, '{"surprise": 1}')),
  'validation_failed|body=required,pinned=required,surprise=unknown_field,title=required',
  'every missing field and an unknown field are named');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_announcement', null,
  jsonb_build_object('title', repeat('x', 101), 'body', repeat('y', 1501), 'pinned', 'yes'))),
  'validation_failed|body=too_long,pinned=invalid,title=too_long', 'length and type checks');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_announcement', null,
  jsonb_build_object('title', 'SYNTHETIC ' || chr(7), 'body', chr(10) || chr(160), 'pinned', null))),
  'validation_failed|body=required,pinned=required,title=invalid', 'control characters and blank text');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_announcement', null,
  pg_temp.an('SYNTHETIC Lines', false, jsonb_build_object('body', 'Line one' || chr(13) || chr(10) || 'Line two')))),
  'ok', 'a multiline body is accepted');
select is((select r.body from app.content_announcement_revisions r where r.title = 'SYNTHETIC Lines'),
  'Line one' || chr(10) || 'Line two', 'with its line endings normalised');
select is(pg_temp.read(null, 'select api.content_public_announcements()'),
  '{"announcements": [], "truncated": false}'::jsonb, 'anon sees no draft');
select is(pg_temp.read(null, format('select api.content_public_announcement(%L::uuid)', pg_temp.a1())),
  '{"announcement": null}'::jsonb, 'a draft is null to anon by id');
select is(pg_temp.read(5, 'select api.content_public_announcements()') -> 'announcements', '[]'::jsonb,
  'a Pending account sees no draft');

-- Devices, the category switch, a hold and a deactivation (before any notice) --------------------
select pg_temp.call(n, 'notifications_command', 'notifications.register_device', null,
         jsonb_build_object('token', 'fcm-' || repeat(chr(96 + n), 40) || ':APA91b', 'platform', 'android'))
  from unnest(array[4, 6, 8, 9]) n;
select is(pg_temp.err(pg_temp.call(6, 'notifications_command', 'notifications.set_push_category', null,
            '{"source_type": "content_announcement", "reminder_kind": "announcement_published", "push_enabled": false}')),
  'ok', 'member B turns the announcements category off');
select ok((pg_temp.read(4, 'select api.notifications_my_push_settings()') -> 'categories')
            @> '[{"source_type": "content_announcement", "reminder_kind": "announcement_published", "title": "Church announcement", "push_enabled": true}]'::jsonb,
  'the category is offered to members, on by default');
select is(pg_temp.call(1, 'identity_credential_command', 'identity.place_hold', pg_temp.mrev(8),
            jsonb_build_object('member_id', pg_temp.mid(8), 'reason_code', 'security_concern')) ->> 'code',
  null, 'the Admin places a hold on member C');
select is(pg_temp.call(1, 'identity_lifecycle_command', 'identity.deactivate_membership', pg_temp.mrev(9),
            jsonb_build_object('member_id', pg_temp.mid(9), 'reason_code', 'church_decision')) ->> 'code',
  null, 'the Admin deactivates member D');
select results_eq($$select x from app.content_announcement_audience() x order by 1$$,
  $$select member_id from m where n in (1, 2, 3, 4, 6, 7) order by 1$$,
  'the audience: approved members the app can reach (not held, deactivated or accountless)');
select is(pg_temp.read(3, 'select api.content_staff_announcements()') -> 'audience',
  '{"members": 6, "limit": 1000, "per_minute": 20}'::jsonb,
  'editors see how many members a notice reaches now, the limit and the pace');
select is(pg_temp.read(3, 'select api.content_staff_announcements()') -> 'notice',
  '{"title": "Church announcement", "body": "The church has posted an announcement. Open the app to read it."}'::jsonb,
  'editors read the registered generic text phones show');

-- The limit: more members than one notice may reach --------------------------------------------
create or replace function app.content_announcement_audience_limit() returns integer language sql immutable
set search_path = '' as $$ select 5 $$;
select is(pg_temp.err(pg_temp.cmd(3, 'content.publish_announcement', 1,
            jsonb_build_object('announcement_id', pg_temp.a1(), 'notify', true))),
  'validation_failed|notify=too_many_recipients', 'more members than the limit is refused');
select is((select lifecycle_state from app.content_items where item_id = pg_temp.a1()), 'draft',
  'and nothing was published');
create or replace function app.content_announcement_audience_limit() returns integer language sql immutable
set search_path = '' as $$ select 1000 $$;

-- Publish without a notice (pinned) -------------------------------------------------------------
select is(pg_temp.err(pg_temp.cmd(3, 'content.publish_announcement', 1, jsonb_build_object('announcement_id', pg_temp.a1()))),
  'validation_failed|notify=required', 'notify is required');
select is(pg_temp.err(pg_temp.cmd(3, 'content.publish_announcement', 1,
            jsonb_build_object('announcement_id', pg_temp.a1(), 'notify', 'yes'))),
  'validation_failed|notify=invalid', 'notify is a boolean');
select is(pg_temp.err(pg_temp.cmd(4, 'content.publish_announcement', 1,
            jsonb_build_object('announcement_id', pg_temp.a1(), 'notify', false))),
  'forbidden', 'a plain member cannot publish');
insert into v (k, j) values ('p1', pg_temp.cmd(3, 'content.publish_announcement', 1,
  jsonb_build_object('announcement_id', pg_temp.a1(), 'notify', false)));
select is((select (j -> 'data') - 'announcement_id' from v where k = 'p1'),
  '{"state": "published", "revision": 2, "notified": 0, "live_revision_no": 1, "draft_revision_no": null}'::jsonb,
  'published without a notice: notified 0');
select is(pg_temp.jobs(pg_temp.a1()), '', 'no job without a notice');
insert into v (k, j) values ('pub1', pg_temp.read(null, 'select api.content_public_announcements()'));
select results_eq($$select x.key from v, jsonb_object_keys(v.j #> '{announcements,0}') x(key) where v.k = 'pub1' order by 1$$,
  $$values ('announcement_id'::text), ('body'), ('pinned'), ('publication_revision'), ('published_at'), ('title')$$,
  'the public projection has exactly these keys');
select is((select (j #> '{announcements,0}') - 'announcement_id' - 'published_at' from v where k = 'pub1'),
  '{"title": "SYNTHETIC Harvest week", "body": "SYNTHETIC body of SYNTHETIC Harvest week. Bring a friend.", "pinned": true, "publication_revision": 1}'::jsonb,
  'anon reads the published announcement');
select ok((select position(pg_temp.mid(3)::text in j::text) = 0 and position(pg_temp.u(3)::text in j::text) = 0
                  and position('SYNTHETIC Announce Member' in j::text) = 0 from v where k = 'pub1'),
  'no editor id or name in the public read');
select is(pg_temp.read(5, 'select api.content_public_announcements()'), (select j from v where k = 'pub1'),
  'a Pending account reads the same projection');
select is(pg_temp.read(4, 'select api.content_public_announcements()'), (select j from v where k = 'pub1'),
  'a member reads the same projection');
select is(pg_temp.read(null, format('select api.content_public_announcement(%L::uuid)', pg_temp.a1())) -> 'announcement',
  (select j #> '{announcements,0}' from v where k = 'pub1'), 'the detail read is the same projection');
select is(pg_temp.read(null, format('select api.content_public_announcement(%L::uuid)', gen_random_uuid())),
  '{"announcement": null}'::jsonb, 'an unknown id is null');
select is(pg_temp.err(pg_temp.cmd(3, 'content.publish_announcement', 2,
            jsonb_build_object('announcement_id', pg_temp.a1(), 'notify', false))),
  'validation_failed|announcement_id=nothing_to_publish', 'nothing to publish without a draft');

-- Publish with a notice (unpinned) ---------------------------------------------------------------
insert into v (k, j) values ('a2', pg_temp.cmd(7, 'content.create_announcement', null,
  pg_temp.an('SYNTHETIC Choir practice moved', false)));
create function pg_temp.a2() returns uuid language sql as $$ select (j #>> '{data,announcement_id}')::uuid from v where k = 'a2' $$;
insert into v (k, id) values ('rq', gen_random_uuid());
insert into v (k, j) values ('p2', pg_temp.cmd(7, 'content.publish_announcement', 1,
  jsonb_build_object('announcement_id', pg_temp.a2(), 'notify', true), (select id from v where k = 'rq')));
select is((select (j -> 'data') - 'announcement_id' from v where k = 'p2'),
  '{"state": "published", "revision": 2, "notified": 6, "live_revision_no": 1, "draft_revision_no": null}'::jsonb,
  'published with a notice to six members');
select is(pg_temp.jobs(pg_temp.a2()), '1:pending|-,2:pending|-,3:pending|-,4:pending|-,6:pending|-,7:pending|-',
  'one pending job per member the app can reach; none for the held, deactivated or accountless member');
select is((select count(*)::int from app.notifications_jobs j
            where j.source_type = 'content_announcement' and j.source_id = pg_temp.a2()
              and (j.recipient_member_id = pg_temp.mid(8) or j.recipient_member_id = pg_temp.mid(9)
                   or j.recipient_member_id = pg_temp.mid(10))), 0,
  'held, deactivated and accountless members get no job');
select is((select count(distinct (j.source_revision, j.reminder_kind, j.scheduled_at))::int from app.notifications_jobs j
            where j.source_type = 'content_announcement' and j.source_id = pg_temp.a2()), 1,
  'the jobs share the published revision, the kind and one due time');
select is((select string_agg(distinct j.source_revision::text || '|' || j.reminder_kind, ',') from app.notifications_jobs j
            where j.source_type = 'content_announcement' and j.source_id = pg_temp.a2()),
  '1|announcement_published', 'the job revision is the published revision number');
select is((select r.notified_count || '|' || (r.notified_by_member = pg_temp.mid(7)) from app.content_announcement_revisions r
            where r.item_id = pg_temp.a2() and r.revision_no = 1), '6|true', 'the revision records the notice');
select is(pg_temp.cmd(7, 'content.publish_announcement', 1,
            jsonb_build_object('announcement_id', pg_temp.a2(), 'notify', true), (select id from v where k = 'rq')),
  (select j from v where k = 'p2'), 'a replay answers the stored result');
select is((select count(*)::int from app.notifications_jobs j
            where j.source_type = 'content_announcement' and j.source_id = pg_temp.a2()), 6,
  'and enqueues nothing twice');
select is(pg_temp.titles(pg_temp.read(null, 'select api.content_public_announcements()')),
  'SYNTHETIC Harvest week / SYNTHETIC Choir practice moved', 'anon reads both, the pinned one first');

-- The worker: inbox items, push jobs, the open target, the generic push message ------------------
select is(pg_temp.deliver() ->> 'delivered', '6', 'the worker delivers six inbox items');
select is(pg_temp.jobs(pg_temp.a2()),
  '1:delivered|delivered,2:delivered|delivered,3:delivered|delivered,4:delivered|delivered,6:delivered|delivered,7:delivered|delivered',
  'every job is delivered');
select is(pg_temp.items(pg_temp.a2()), '1,2,3,4,6,7', 'each eligible member gets one inbox item');
select is((select count(*)::int from app.notifications_attempts a join app.notifications_jobs j on j.job_id = a.job_id
            where j.source_type = 'content_announcement' and j.source_id = pg_temp.a2() and a.outcome = 'delivered'), 6,
  'one delivered attempt row per job');
select is(pg_temp.pushes(pg_temp.a2()), '4', 'a push job only for the member with a device and the category on');
select is((select count(*)::int from app.notifications_direct_contact_needs n where n.source_type = 'content_announcement'), 0,
  'no direct-contact need');
insert into v (k, j) values ('inbox4', pg_temp.read(4, 'select api.notifications_my_inbox()'));
select is((select e - 'item_id' - 'due_at' - 'delivered_at' from v, jsonb_array_elements(j -> 'items') e
            where v.k = 'inbox4' and (e ->> 'item_id')::uuid = pg_temp.item_for(pg_temp.a2(), 4)),
  '{"reminder_kind": "announcement_published", "title": "Church announcement", "body": "The church has posted an announcement. Open the app to read it.", "opened": false, "snoozed_until": null}'::jsonb,
  'the inbox item carries the generic text only');
insert into v (k, j) values ('open4', pg_temp.read(4, format('select api.notifications_open_item(%L::uuid)',
                                                            pg_temp.item_for(pg_temp.a2(), 4))));
select is((select j ->> 'state' || '|' || (j ->> 'target') from v where k = 'open4'),
  'current|/announcements/' || pg_temp.a2(), 'opening it points at the announcement');
select ok((select position('Choir' in j::text) = 0 from v where k = 'open4'), 'the opened item carries no announcement text');
select ok((select bool_and(position('Choir' in to_jsonb(j)::text) = 0 and position('Bring a friend' in to_jsonb(j)::text) = 0)
             from app.notifications_jobs j where j.source_id = pg_temp.a2()),
  'no job row carries the announcement''s title or body');
select ok((select bool_and(position('Choir' in to_jsonb(i)::text) = 0) from app.notifications_inbox_items i
            join app.notifications_jobs j on j.job_id = i.job_id where j.source_id = pg_temp.a2()),
  'no inbox row carries it');
select ok(not exists (select 1 from app.cmd_receipts r where r.result::text like '%Choir%'), 'no receipt carries it');
update app.policy_gates set state = 'approved', approved_value = '{}', approved_by = 'pgtap',
       approved_at = now(), approval_note = 'synthetic push tests' where gate = 'outbound_sending';
select app.notifications_configure_worker('{"push_enabled": true}', 'israel');
insert into v (k, j) values ('claim', app.notifications_push_claim(pg_temp.w(1), gen_random_uuid(), 25));
insert into v (k, j) values ('prep', (
  select app.notifications_push_prepare(pg_temp.w(1), gen_random_uuid(), (e ->> 'push_job_id')::uuid,
                                        (e ->> 'lease_token')::bigint)
    from v, jsonb_array_elements(v.j -> 'jobs') e where v.k = 'claim' limit 1));
select is((select j ->> 'outcome' from v where k = 'prep'), 'send', 'the push is prepared for the live device');
select is((select (j -> 'message') - 'ttl_seconds' - 'expires_at_epoch' from v where k = 'prep'),
  jsonb_build_object('notification_id', pg_temp.item_for(pg_temp.a2(), 4), 'item_id', pg_temp.item_for(pg_temp.a2(), 4),
                     'title', 'Church announcement', 'body', 'The church has posted an announcement. Open the app to read it.'),
  'the push message is the generic text and the inbox item id');
select ok((select position('Choir' in j::text) = 0 and position('Bring a friend' in j::text) = 0 from v where k = 'prep'),
  'no push payload carries the announcement''s title or body');
select app.notifications_configure_worker('{"push_enabled": false}', 'israel');

-- Withdraw: pending notices cancelled, an opened item goes out of date --------------------------
insert into v (k, j) values ('a3', pg_temp.cmd(2, 'content.create_announcement', null,
  pg_temp.an('SYNTHETIC Youth camp', false)));
create function pg_temp.a3() returns uuid language sql as $$ select (j #>> '{data,announcement_id}')::uuid from v where k = 'a3' $$;
select is(pg_temp.cmd(2, 'content.publish_announcement', 1, jsonb_build_object('announcement_id', pg_temp.a3(), 'notify', true))
            #>> '{data,notified}', '6', 'a Pastor publishes with a notice');
select is(pg_temp.cmd(2, 'content.withdraw_announcement', 2, jsonb_build_object('announcement_id', pg_temp.a3()))
            #>> '{data,state}', 'withdrawn', 'and withdraws it before the worker runs');
select is(pg_temp.jobs(pg_temp.a3()),
  '1:cancelled|source_cancelled,2:cancelled|source_cancelled,3:cancelled|source_cancelled,4:cancelled|source_cancelled,6:cancelled|source_cancelled,7:cancelled|source_cancelled',
  'every pending notice is cancelled');
select is(pg_temp.deliver() ->> 'delivered', '0', 'the worker delivers nothing for it');
select is(pg_temp.read(null, format('select api.content_public_announcement(%L::uuid)', pg_temp.a3())),
  '{"announcement": null}'::jsonb, 'a withdrawn announcement is not public');
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_announcement', 3,
            jsonb_build_object('announcement_id', pg_temp.a3(), 'notify', true))),
  'validation_failed|notify=already_notified', 'publishing it again cannot notify a second time');
select is((select lifecycle_state from app.content_items where item_id = pg_temp.a3()), 'withdrawn',
  'and stays withdrawn');
select is(pg_temp.cmd(2, 'content.publish_announcement', 3, jsonb_build_object('announcement_id', pg_temp.a3(), 'notify', false))
            #>> '{data,state}', 'published', 'it can be published again without a notice');
select is(pg_temp.cmd(3, 'content.withdraw_announcement', 2, jsonb_build_object('announcement_id', pg_temp.a2()))
            #>> '{data,state}', 'withdrawn', 'Media withdraws the delivered announcement');
select is(pg_temp.read(4, format('select api.notifications_open_item(%L::uuid)', pg_temp.item_for(pg_temp.a2(), 4))) ->> 'state',
  'superseded', 'its inbox item now opens out of date, and stays in the inbox');
select is(pg_temp.err(pg_temp.cmd(3, 'content.withdraw_announcement', 3, jsonb_build_object('announcement_id', pg_temp.a2()))),
  'validation_failed|announcement_id=not_published', 'a withdrawn announcement cannot be withdrawn again');

-- A newer revision: old pending notices cancelled, the new one notified --------------------------
insert into v (k, j) values ('a4', pg_temp.cmd(3, 'content.create_announcement', null,
  pg_temp.an('SYNTHETIC Baptism class', false)));
create function pg_temp.a4() returns uuid language sql as $$ select (j #>> '{data,announcement_id}')::uuid from v where k = 'a4' $$;
select pg_temp.cmd(3, 'content.publish_announcement', 1, jsonb_build_object('announcement_id', pg_temp.a4(), 'notify', true));
select is(pg_temp.err(pg_temp.cmd(3, 'content.save_announcement', 2,
            pg_temp.an('SYNTHETIC Baptism class (new date)', true, jsonb_build_object('announcement_id', pg_temp.a4())))),
  'ok', 'Media saves a pinned draft of the published announcement');
select is(pg_temp.read(null, format('select api.content_public_announcement(%L::uuid)', pg_temp.a4())) #>> '{announcement,title}',
  'SYNTHETIC Baptism class', 'the published revision stays live while the draft is edited');
select is(pg_temp.read(null, format('select api.content_public_announcement(%L::uuid)', pg_temp.a4())) #>> '{announcement,pinned}',
  'false', 'unpinned until the change is published');
select throws_ok(format($$update app.content_announcement_revisions set title = 'SYNTHETIC tampered'
                          where item_id = %L and revision_no = 1$$, pg_temp.a4()),
  'PCNT1', 'a published content revision is immutable', 'a published revision cannot be rewritten');
select throws_ok(format($$update app.content_announcement_revisions set notified_count = 0
                          where item_id = %L and revision_no = 1$$, pg_temp.a4()),
  'PCNT1', 'a revision is notified at most once', 'nor its notice record');
select is(pg_temp.cmd(3, 'content.publish_announcement', 3, jsonb_build_object('announcement_id', pg_temp.a4(), 'notify', true))
            #>> '{data,notified}', '6', 'publishing the change notifies again for the new revision');
select is((select string_agg(x, ',' order by x) from (
             select distinct j.source_revision || ':' || j.job_state || '|' || coalesce(j.cancel_reason, '-') as x
               from app.notifications_jobs j where j.source_id = pg_temp.a4()) d),
  '1:cancelled|source_revised,2:pending|-', 'the older revision''s pending notices are cancelled');
-- One transaction has one now(): give the publications distinct times for the order check.
update app.content_items set published_at = now() - interval '3 hours' where item_id = pg_temp.a1();
update app.content_items set published_at = now() - interval '1 hour' where item_id = pg_temp.a3();
select is(pg_temp.titles(pg_temp.read(null, 'select api.content_public_announcements()')),
  'SYNTHETIC Baptism class (new date) / SYNTHETIC Harvest week / SYNTHETIC Youth camp',
  'pinned first (the newest publication first), then the others newest first');

-- The recheck: a member held after the publication gets nothing ----------------------------------
select is(pg_temp.call(1, 'identity_credential_command', 'identity.place_hold', pg_temp.mrev(2),
            jsonb_build_object('member_id', pg_temp.mid(2), 'reason_code', 'security_concern')) ->> 'code',
  null, 'the Admin places a hold on the Pastor after the publication');
select pg_temp.deliver();
select is((select j.job_state || '|' || j.finish_reason from app.notifications_jobs j
            where j.source_id = pg_temp.a4() and j.source_revision = 2 and j.recipient_member_id = pg_temp.mid(2)),
  'ineligible|recipient_ineligible', 'the recheck ends the held member''s job without an inbox item');
select is((select count(*)::int from app.notifications_direct_contact_needs n where n.source_type = 'content_announcement'), 0,
  'and records no direct-contact need');
select is(pg_temp.items(pg_temp.a4()), '1,3,4,6,7', 'the others get their inbox item');

-- Archive, refusals and the editors' read -----------------------------------------------------------
select is(pg_temp.cmd(1, 'content.archive_announcement', pg_temp.rev(pg_temp.a4()),
            jsonb_build_object('announcement_id', pg_temp.a4())) #>> '{data,state}', 'archived', 'an Admin archives it');
select is(pg_temp.read(null, format('select api.content_public_announcement(%L::uuid)', pg_temp.a4())),
  '{"announcement": null}'::jsonb, 'an archived announcement is not public');
select is(pg_temp.err(pg_temp.cmd(3, 'content.publish_announcement', pg_temp.rev(pg_temp.a4()),
            jsonb_build_object('announcement_id', pg_temp.a4(), 'notify', false))),
  'validation_failed|announcement_id=archived', 'an archived announcement refuses every later command');
select is(pg_temp.err(pg_temp.cmd(n, c, pg_temp.rev(pg_temp.a1()), case c
    when 'content.save_announcement' then pg_temp.an('SYNTHETIC No', false, jsonb_build_object('announcement_id', pg_temp.a1()))
    when 'content.publish_announcement' then jsonb_build_object('announcement_id', pg_temp.a1(), 'notify', false)
    else jsonb_build_object('announcement_id', pg_temp.a1()) end)), 'forbidden',
  format('account %s is refused %s', n, c))
  from unnest(array[4, 5]) n
  cross join unnest(array['content.save_announcement', 'content.publish_announcement', 'content.withdraw_announcement',
                          'content.archive_announcement']) c;
select is(pg_temp.err(pg_temp.cmd(3, 'content.save_announcement', pg_temp.rev(pg_temp.a1()),
            pg_temp.an('SYNTHETIC Ghost', false, jsonb_build_object('announcement_id', gen_random_uuid())))),
  'not_found', 'an unknown announcement is not found');
insert into v (k, j) values ('ev', pg_temp.cmd(3, 'content.create_event', null, jsonb_build_object(
  'title', 'SYNTHETIC Event', 'description', 'SYNTHETIC event.', 'location', 'SYNTHETIC Hall',
  'starts_at', app.cmd_utc(now() + interval '2 days'), 'ends_at', app.cmd_utc(now() + interval '2 days 2 hours'))));
select is(pg_temp.err(pg_temp.cmd(3, 'content.save_announcement', 1,
            pg_temp.an('SYNTHETIC Wrong kind', false,
                       jsonb_build_object('announcement_id', (select j #>> '{data,event_id}' from v where k = 'ev'))))),
  'not_found', 'an event id is not an announcement');
select is(pg_temp.err(pg_temp.cmd(3, 'content.save_announcement', 1,
            pg_temp.an('SYNTHETIC Stale', false, jsonb_build_object('announcement_id', pg_temp.a1())))),
  'conflict', 'a stale tab is refused');
insert into v (k, j) values ('staff', pg_temp.read(3, 'select api.content_staff_announcements()'));
create function pg_temp.staff_of(p_item uuid) returns jsonb language sql as $$
  select e from v, jsonb_array_elements(v.j -> 'announcements') e
   where v.k = 'staff' and (e ->> 'announcement_id')::uuid = p_item $$;
select results_eq($$select k from jsonb_object_keys(pg_temp.staff_of(pg_temp.a2())) k order by 1$$,
  $$values ('announcement_id'::text), ('archived_at'), ('created_at'), ('created_by'), ('draft'), ('live'),
           ('published_at'), ('published_by'), ('revision'), ('state'), ('updated_at'), ('withdrawn_at')$$,
  'the editors'' announcement keys');
select results_eq($$select k from jsonb_object_keys(pg_temp.staff_of(pg_temp.a2()) -> 'live') k order by 1$$,
  $$values ('body'::text), ('notified_at'), ('notified_by'), ('notified_count'), ('pinned'), ('revision_no'),
           ('saved_at'), ('saved_by'), ('title')$$,
  'the editors'' revision keys');
select is((select pg_temp.staff_of(pg_temp.a2()) #>> '{live,notified_by}') || '|' || (pg_temp.staff_of(pg_temp.a2()) #>> '{live,notified_count}'),
  'SYNTHETIC Announce Member 7|6', 'editors see who notified and how many');
select is(pg_temp.staff_of(pg_temp.a1()) #>> '{live,notified_at}', null, 'an announcement published without a notice has none');
select is((select j ->> 'capacity' from v where k = 'staff'), 'media', 'the reader''s capacity');
select is((select (e ->> 'state') from v, jsonb_array_elements(v.j -> 'announcements') with ordinality x(e, o)
            where v.k = 'staff' order by o desc limit 1), 'archived', 'archived announcements come last');
select is(pg_temp.read(4, 'select api.content_staff_announcements()') #>> '{}',
  'PT403|forbidden|not_granted', 'a plain member cannot read the editors'' list');
select is(pg_temp.read(5, 'select api.content_staff_announcements()') #>> '{}',
  'PT403|forbidden|not_linked', 'a Pending account cannot read the editors'' list');
select is(pg_temp.read(null, 'select api.content_staff_announcements()') #>> '{}',
  '42501|permission denied for function content_staff_announcements|', 'anon cannot read the editors'' list');
select results_eq(
  format($$select action from app.content_audit where item_id = %L order by event_id$$, pg_temp.a4()),
  $$values ('created'::text), ('published'), ('draft_saved'), ('published'), ('archived')$$,
  'every change is audited in order');
select ok(not exists (select 1 from app.content_audit a where a.kind = 'announcement' and a::text like '%SYNTHETIC%'),
  'the audit is content-free');

-- Deletion: an erased editor reads as a former member ---------------------------------------------
select ok((select (h ->> 'remaining')::int > 0 from jsonb_array_elements(app.identity_call_deletion_hooks(
             pg_temp.mid(7), pg_temp.u(7), gen_random_uuid(), 'check')) h where h ->> 'module' = 'content'),
  'the check counts Media E''s attribution');
select is((app.content_announcement_erase_part(jsonb_build_object('member_id', pg_temp.mid(7), 'account_id', pg_temp.u(7),
                                                                 'deletion_id', gen_random_uuid(), 'phase', 'check'))),
  1, 'the announcements part counts the revision Media E saved, published and notified');
select is((select h ->> 'remaining' from jsonb_array_elements(app.identity_call_deletion_hooks(
             pg_temp.mid(7), pg_temp.u(7), gen_random_uuid(), 'erase')) h where h ->> 'module' = 'content'),
  '0', 'erase leaves nothing of Media E in Content');
insert into v (k, j) values ('staff2', pg_temp.read(3, 'select api.content_staff_announcements()'));
select is((select e #>> '{live,saved_by}' || '|' || (e ->> 'published_by') || '|' || (e #>> '{live,notified_by}')
             from v, jsonb_array_elements(v.j -> 'announcements') e
            where v.k = 'staff2' and (e ->> 'announcement_id')::uuid = pg_temp.a2()),
  'Former member|Former member|Former member', 'who saved, published and notified now read as a former member');
select is((select r.notified_count from app.content_announcement_revisions r where r.item_id = pg_temp.a2()), 6,
  'the notice record itself is kept');

-- Pace: a large notice falls due a few members a minute, so other reminders are not held back --
create or replace function app.content_announcement_pace() returns integer language sql immutable
set search_path = '' as $$ select 2 $$;
insert into v (k, j) values ('a6', pg_temp.cmd(3, 'content.create_announcement', null,
  pg_temp.an('SYNTHETIC Paced notice', false)));
select is(pg_temp.cmd(3, 'content.publish_announcement', 1,
            jsonb_build_object('announcement_id', (select (j #>> '{data,announcement_id}')::uuid from v where k = 'a6'),
                               'notify', true)) #>> '{data,notified}', '5', 'a notice to five members at two a minute');
select is((select string_agg(x::text, ',' order by x) from (
             select count(*) as x from app.notifications_jobs j
              where j.source_id = (select (j2 #>> '{data,announcement_id}')::uuid from (select j as j2 from v where k = 'a6') q)
              group by j.scheduled_at) d), '1,2,2',
  'its jobs fall due two now, two a minute later and the last one after two minutes');
select is((select extract(epoch from max(j.scheduled_at) - min(j.scheduled_at))::int from app.notifications_jobs j
            where j.source_id = (select (j2 #>> '{data,announcement_id}')::uuid from (select j as j2 from v where k = 'a6') q)),
  120, 'spread over two minutes');
create or replace function app.content_announcement_pace() returns integer language sql immutable
set search_path = '' as $$ select 20 $$;

-- Q2 closed (production until Israel approves it): a notice is unavailable, nothing is published --
-- The gate without its local fixture answers as in production (rolled back with the test).
update app.policy_gates set fixture_value = null where gate = 'q2_church_time';
insert into v (k, j) values ('a5', pg_temp.cmd(3, 'content.create_announcement', null,
  pg_temp.an('SYNTHETIC Production check', false)));
select is(pg_temp.err(pg_temp.cmd(3, 'content.publish_announcement', 1,
            jsonb_build_object('announcement_id', (select (j #>> '{data,announcement_id}')::uuid from v where k = 'a5'),
                               'notify', true))),
  'unavailable|policy=gate_closed', 'with Q2 closed a notice is unavailable');
select is((select lifecycle_state from app.content_items
            where item_id = (select (j #>> '{data,announcement_id}')::uuid from v where k = 'a5')),
  'draft', 'and the announcement stays a draft');
select is(pg_temp.cmd(3, 'content.publish_announcement', 1,
            jsonb_build_object('announcement_id', (select (j #>> '{data,announcement_id}')::uuid from v where k = 'a5'),
                               'notify', false)) #>> '{data,state}',
  'published', 'publishing without a notice still works');

select * from finish();
rollback;
