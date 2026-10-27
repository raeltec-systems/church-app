-- Story 6.9. All fixtures are SYNTHETIC; UK phones are fictional Ofcom numbers
-- (+44 7700 900651-900656, the entry's block; rolled back with the test).
begin;
select no_plan();

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000097' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000097' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.c(n int) returns jsonb language sql as $$
  select jsonb_build_object('sub', pg_temp.u(n), 'role', 'authenticated', 'aal', 'aal1',
    'session_id', pg_temp.s(n), 'is_anonymous', false,
    'amr', jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', 1790000000)))
$$;
create function pg_temp.cmd(n int, p_command text, p_expected bigint, p_payload jsonb,
  p_request uuid default gen_random_uuid()) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', pg_temp.c(n)::text, true);
  set local role authenticated;
  r := api.content_command(jsonb_build_object('version', 1, 'command', p_command,
    'request_id', p_request, 'expected_revision', p_expected, 'payload', p_payload));
  reset role;
  return r;
end;
$$;
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
create function pg_temp.err(r jsonb) returns text language sql as $$
  select coalesce(r ->> 'code', 'ok') || coalesce('|' || (select string_agg(k || '=' || v, ',' order by k)
    from jsonb_each_text(r -> 'field_errors') f(k,v)), '')
$$;
create function pg_temp.rev(p uuid) returns bigint language sql as $$
  select revision from app.content_items where item_id = p
$$;
create function pg_temp.sermon(p_title text, p_extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('title', p_title, 'speaker', 'SYNTHETIC Speaker', 'sermon_date', '2026-10-25',
    'scripture_reference', 'Psalm 23:1', 'notes', '# Hope' || chr(10) || chr(10) || 'Read **with faith** and *care*.' || chr(10) ||
      '- First point' || chr(10) || '1. Second point' || chr(10) || '[Read scripture](https://ebible.org/eng-kjv/PSA023.htm)',
    'series_id', null, 'youtube_video_id', null, 'video_rights_id', null) || p_extra
$$;
create function pg_temp.series(p_title text, p_extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('title', p_title, 'description', 'SYNTHETIC church-authored series notes',
    'alt_text', 'SYNTHETIC landscape poster') || p_extra
$$;

insert into auth.users(id,aud,role,phone,phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', '447700900' || (650+n)::text, now()
from generate_series(1,6) n;
insert into auth.sessions(id,user_id,aal,created_at)
select pg_temp.s(n),pg_temp.u(n),'aal1',clock_timestamp()-interval '1 hour' from generate_series(1,6) n;
insert into auth.mfa_amr_claims(id,session_id,created_at,updated_at,authentication_method)
select gen_random_uuid(),pg_temp.s(n),now(),now(),'password' from generate_series(1,6) n;
select app.platform_set_environment('local','pgtap SYNTHETIC sermons');
create temp table m(n int,member_id uuid);
insert into m select n,app.identity_seed_synthetic_link(pg_temp.u(n),'SYNTHETIC Sermon Editor '||n,'pgtap sermons')
from generate_series(1,6) n where n <> 5;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n=$1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1),'israel');
insert into app.identity_grants(member_id,role,granted_by_operator)
values(pg_temp.mid(2),'pastor','israel'),(pg_temp.mid(3),'media','israel'),(pg_temp.mid(6),'media','israel');

select has_table('app',t,'sermon revision table exists: '||t)
from unnest(array['content_sermon_revisions','content_sermon_series_revisions']) t;
select ok((select bool_and(relrowsecurity) from pg_class
  where oid in ('app.content_sermon_revisions'::regclass,'app.content_sermon_series_revisions'::regclass)),
  'RLS enabled on both new tables');
select table_privs_are('app',t,r,array[]::text[],r||' cannot touch '||t)
from unnest(array['content_sermon_revisions','content_sermon_series_revisions']) t
cross join unnest(array['anon','authenticated','service_role']) r;
select results_eq($$select kind,editor_roles from app.content_kinds where kind in ('sermon','sermon_series') order by 1$$,
  $$values ('sermon'::text,array['admin','pastor','media']::text[]),('sermon_series',array['admin','pastor','media']::text[])$$,
  'only three content roles edit sermons and series');
select is((select count(*)::int from app.content_commands where kind in ('sermon','sermon_series') and command in (
  'content.create_sermon','content.save_sermon','content.publish_sermon','content.withdraw_sermon','content.archive_sermon',
  'content.create_sermon_series','content.save_sermon_series','content.publish_sermon_series','content.withdraw_sermon_series','content.archive_sermon_series')),10,
  'ten lifecycle commands are registered');
select results_eq($$select part from app.content_erase_parts where part in ('sermon_revisions','sermon_series_revisions') order by 1$$,
  $$values ('sermon_revisions'::text),('sermon_series_revisions')$$,'both revision erase parts are registered');
select is((select kind||':'||rights_use||':'||max_bytes from app.content_asset_purposes where purpose='sermon_series_poster'),
  'sermon_series:display:5242880','poster uses existing bounded purpose pipeline');
-- Scope this story's grant assertion to its own function names so later audio/duty entries
-- can register their own endpoints without changing this security regression.
create temp table own_sermon_functions(proname text primary key);
insert into own_sermon_functions select unnest(array[
  'content_sermon_link_ok','content_sermon_notes_error','content_sermon_series_revision_guard','content_sermon_revision_guard',
  'content_sermon_series_fields','content_sermon_fields','content_sermon_series_create','content_sermon_series_save',
  'content_sermon_create','content_sermon_save','content_sermon_series_publish','content_sermon_publish',
  'content_sermon_series_withdraw','content_sermon_series_archive','content_sermon_withdraw','content_sermon_archive',
  'content_public_sermon_series_json','content_public_sermon_json','content_public_sermons','content_public_sermon',
  'content_sermon_rights_json','content_sermon_series_revision_json','content_sermon_revision_json',
  'content_staff_sermon_series_json','content_staff_sermon_json','content_staff_sermons','content_staff_sermon_series',
  'content_sermon_erase_part','content_sermon_series_erase_part']);
select results_eq($$select (n.nspname||'.'||p.proname)::text collate "C" from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname in ('app','api') and p.proname in (select proname from own_sermon_functions)
    and has_function_privilege('anon',p.oid,'execute') order by 1$$,
  $$values ('api.content_public_sermon'::text collate "C"),('api.content_public_sermons'),('app.content_public_sermon'),('app.content_public_sermons')$$,
  'anon has only the two public read pairs');
select results_eq($$select (n.nspname||'.'||p.proname)::text collate "C" from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname in ('app','api') and p.proname in (select proname from own_sermon_functions)
    and has_function_privilege('authenticated',p.oid,'execute') order by 1$$,
  $$values ('api.content_public_sermon'::text collate "C"),('api.content_public_sermons'),('api.content_staff_sermon_series'),('api.content_staff_sermons'),
  ('app.content_public_sermon'),('app.content_public_sermons'),('app.content_staff_sermon_series'),('app.content_staff_sermons')$$,
  'authenticated only gains public and editor read pairs');
select is_definer('app','content_public_sermons',array[]::text[],'public catalog runs as owner');
select isnt_definer('api','content_public_sermons',array[]::text[],'public wrapper remains invoker');

select is(app.content_sermon_notes_error(pg_temp.sermon('SYNTHETIC notes')->>'notes'),null,'headings emphasis lists and safe links pass');
select is(app.content_sermon_notes_error('Hope! A literal ~ and unmatched * are plain text.'),null,'ordinary punctuation stays readable');
select ok(app.content_sermon_link_ok(url),'allowlisted exact HTTPS link: '||url)
from unnest(array['https://ebible.org','https://biblegateway.com/passage/?search=Psalm23',
  'https://www.biblegateway.com/','https://youtube.com/watch?v=abc','https://www.youtube.com/','https://youtu.be/abcdefghijk']) url;
select ok(app.content_sermon_notes_error(notes) is not null,'unsafe or unsupported notes refused: '||notes)
from unnest(array['<script>alert(1)</script>','![image](https://ebible.org/a.png)',
  '[x](javascript:alert)','[x](http://ebible.org/)','[x](https://example.org/)',
  '[x](https://ebible.org.evil.test/)','[x](https://ebible.org@evil.test/)',
  '[x](https://evil.test@ebible.org/)','[x](https://ebible.org:443/)',
  '[x](https://ebible.org:8443/)','[x](https://%65bible.org/)',
  '[x][ref]','[ref]: https://ebible.org/','<https://ebible.org/>',
  '[x](https://ebible.org/ "title")','`code`','> quote','a | table','~~strike~~',
  '    indented code','####### too deep','[x](https://ebible.org/(nested))',
  '[x](https://ebible.org/'||chr(92)||'evil)', 'https://ebible.org/', 'WWW.ebible.org',
  '[line'||chr(10)||'break](https://ebible.org/)', '[x](https://ebible.org/[bad])']) notes;

create temp table se1 as select pg_temp.cmd(3,'content.create_sermon_series',null,pg_temp.series('SYNTHETIC Hope')) r;
create temp table se2 as select pg_temp.cmd(6,'content.create_sermon_series',null,pg_temp.series('SYNTHETIC Faith')) r;
create function pg_temp.se1() returns uuid language sql as $$ select (r#>>'{data,series_id}')::uuid from se1 $$;
create function pg_temp.se2() returns uuid language sql as $$ select (r#>>'{data,series_id}')::uuid from se2 $$;
select is((select r#>>'{data,state}' from se1),'draft','Media creates a series draft');
select is((select r#>>'{data,state}' from se2),'draft','another Media creates a series draft');
select is(pg_temp.read(null,'select api.content_public_sermons()')->'series','[]'::jsonb,'draft series stay private');

create temp table sr1 as select pg_temp.cmd(3,'content.create_sermon',null,'{"title":"SYNTHETIC Incomplete"}') r;
create function pg_temp.sr1() returns uuid language sql as $$ select (r#>>'{data,sermon_id}')::uuid from sr1 $$;
select is((select r#>>'{data,state}' from sr1),'draft','an incomplete duty-compatible draft can be stored');
select is(pg_temp.err(pg_temp.cmd(3,'content.publish_sermon',1,jsonb_build_object('sermon_id',pg_temp.sr1()))),
  'validation_failed|scripture_reference=required,sermon_date=required,speaker=required','publication requires complete teaching metadata');
select is(pg_temp.read(null,format('select api.content_public_sermon(%L)',pg_temp.sr1())),'{"sermon":null}'::jsonb,
  'draft detail is unavailable anonymously');
select is(jsonb_array_length(pg_temp.read(2,'select api.content_staff_sermons()')->'sermons'),1,
  'Pastor staff list includes another creator''s incomplete draft');

select is(pg_temp.err(pg_temp.cmd(n,'content.create_sermon',null,pg_temp.sermon('SYNTHETIC Refused'))),'forbidden',
  'non-editor cannot create sermon: '||n) from unnest(array[4,5]) n;
select is(pg_temp.err(pg_temp.cmd(n,'content.create_sermon_series',null,pg_temp.series('SYNTHETIC Refused'))),'forbidden',
  'non-editor cannot create series: '||n) from unnest(array[4,5]) n;
select matches(pg_temp.read(null,'select api.content_staff_sermons()')#>>'{}','^42501','anon cannot read sermon editor list');
select matches(pg_temp.read(n,'select api.content_staff_sermons()')#>>'{}','^PT403','non-editor staff list denied: '||n)
from unnest(array[4,5]) n;
select matches(pg_temp.read(n,'select api.content_staff_sermon_series()')#>>'{}','^PT403','non-editor series list denied: '||n)
from unnest(array[4,5]) n;
select is(pg_temp.err(pg_temp.cmd(3,'content.create_sermon',null,pg_temp.sermon('SYNTHETIC Bad',jsonb_build_object('notes','[x](https://evil.test/)')))),
  'validation_failed|notes=unsafe_link','unsafe notes report a field error');
select is(pg_temp.err(pg_temp.cmd(3,'content.create_sermon',null,pg_temp.sermon('SYNTHETIC Bad','{"sermon_date":"2026-02-30"}'))),
  'validation_failed|sermon_date=invalid','impossible dates are field errors');
select is(pg_temp.err(pg_temp.cmd(3,'content.create_sermon',null,pg_temp.sermon('SYNTHETIC Bad','{"youtube_video_id":"https://youtu.be/abc"}'))),
  'validation_failed|youtube_video_id=too_long','only the video identifier is accepted');

create temp table ri1 as select pg_temp.cmd(3,'content.create_rights_record',null,
  '{"label":"SYNTHETIC Sermon rights","source_key":"synthetic-sermon-pgtap","holder":"SYNTHETIC Church", "basis":"church_owned",
  "clears_display":true,"clears_offline":false,"clears_audio":false,"evidence":"SYNTHETIC test artwork and recording"}') r;
create function pg_temp.ri1() returns uuid language sql as $$ select (r#>>'{data,rights_id}')::uuid from ri1 $$;
select is(pg_temp.err(pg_temp.cmd(3,'content.verify_rights_record',1,jsonb_build_object('rights_id',pg_temp.ri1()))),'ok',
  'church-owned synthetic rights verified without a policy approval');
create temp table upload1 as select pg_temp.cmd(3,'content.begin_asset_upload',null,jsonb_build_object(
  'item_id',pg_temp.se1(),'purpose','sermon_series_poster','media_type','image/png',
  'byte_size',3000000,'width',1920,'height',1080,'sha256',repeat('ab',32))) r;
select is((select r#>>'{data,state}' from upload1),'pending','series poster uses existing upload command');
insert into storage.objects(bucket_id,name,metadata)
select 'content-drafts',r#>>'{data,draft_path}','{"size":3000000,"mimetype":"image/png"}'::jsonb from upload1;
select is(pg_temp.err(pg_temp.cmd(3,'content.complete_asset_upload',null,
  jsonb_build_object('asset_id',(select r#>>'{data,asset_id}' from upload1)))),'ok','stored poster is completed');
select is(pg_temp.err(pg_temp.cmd(3,'content.save_sermon_series',1,pg_temp.series('SYNTHETIC Hope',jsonb_build_object(
  'series_id',pg_temp.se1(),'poster_asset_id',(select r#>>'{data,asset_id}' from upload1),'poster_rights_id',null)))),'ok',
  'an incomplete poster attachment can be drafted');
select is(pg_temp.err(pg_temp.cmd(3,'content.publish_sermon_series',2,jsonb_build_object('series_id',pg_temp.se1()))),
  'validation_failed|poster_rights_id=required','poster publication needs cleared rights');
select is(pg_temp.err(pg_temp.cmd(3,'content.save_sermon_series',2,pg_temp.series('SYNTHETIC Hope',jsonb_build_object(
  'series_id',pg_temp.se1(),'poster_asset_id',(select r#>>'{data,asset_id}' from upload1),'poster_rights_id',pg_temp.ri1())))),'ok','poster rights attach');
select is(pg_temp.err(pg_temp.cmd(2,'content.publish_sermon_series',3,jsonb_build_object('series_id',pg_temp.se1()))),'ok','Pastor publishes series');
select is(pg_temp.err(pg_temp.cmd(6,'content.publish_sermon_series',1,jsonb_build_object('series_id',pg_temp.se2()))),'ok','Media publishes poster-free series');
select is(app.content_staff_sermon_series_json(pg_temp.se2())->'public_image','null'::jsonb,
  'a published series without a poster has no poster state for editors');
select is(jsonb_array_length(pg_temp.read(null,'select api.content_public_sermons()')->'series'),2,
  'both published series appear before they contain sermons');
select is(app.content_public_sermon_series_json(pg_temp.se1())->'poster','null'::jsonb,'poster stays absent until public file exists');
select is(app.content_staff_sermon_series_json(pg_temp.se1())->>'public_image','waiting',
  'editors see the published poster waiting for the file sync');
insert into storage.objects(bucket_id,name,metadata)
select 'content-public',public_path,jsonb_build_object('size',3000000,'mimetype','image/png')
from app.content_public_files_desired() where item_id=pg_temp.se1();
select is(app.content_public_sermon_series_json(pg_temp.se1())#>>'{poster,offline_allowed}','false','display-only poster remains online only');
select is(app.content_public_sermon_series_json(pg_temp.se1())#>>'{poster,rights_revision}','1','poster cites rights revision without private id');
select is(app.content_staff_sermon_series_json(pg_temp.se1())->>'public_image','shown',
  'editors see the placed poster');

select is(pg_temp.err(pg_temp.cmd(3,'content.save_sermon',1,pg_temp.sermon('SYNTHETIC Shepherd',jsonb_build_object(
  'sermon_id',pg_temp.sr1(),'series_id',pg_temp.se1(),'youtube_video_id','abcdefghijk')))),'ok','complete teaching draft saved without video clearance');
select is(pg_temp.err(pg_temp.cmd(3,'content.publish_sermon',2,jsonb_build_object('sermon_id',pg_temp.sr1()))),
  'validation_failed|video_rights_id=required','supplied video needs rights before publication');
select is(pg_temp.err(pg_temp.cmd(3,'content.save_sermon',2,pg_temp.sermon('SYNTHETIC Shepherd',jsonb_build_object(
  'sermon_id',pg_temp.sr1(),'series_id',pg_temp.se1(),'youtube_video_id','abcdefghijk','video_rights_id',pg_temp.ri1())))),'ok','video clearance attached');
select is(pg_temp.err(pg_temp.cmd(1,'content.publish_sermon',3,jsonb_build_object('sermon_id',pg_temp.sr1()))),'ok','Admin publishes sermon');
select is(pg_temp.read(null,format('select api.content_public_sermon(%L)',pg_temp.sr1()))#>>'{sermon,youtube_video_id}',
  'abcdefghijk','public detail offers cleared video id');
select is(pg_temp.read(null,format('select api.content_public_sermon(%L)',pg_temp.sr1()))#>>'{sermon,series,title}',
  'SYNTHETIC Hope','only live series copy is projected');
select is(pg_temp.read(5,'select api.content_public_sermons()'),pg_temp.read(null,'select api.content_public_sermons()'),
  'Pending reads the identical anonymous projection');
select is(pg_temp.read(4,'select api.content_public_sermons()'),pg_temp.read(null,'select api.content_public_sermons()'),
  'member reads the identical anonymous projection');
select is((select jsonb_object_keys(app.content_public_sermon_json(pg_temp.sr1())) except
  select unnest(array['sermon_id','title','speaker','sermon_date','scripture_reference','notes','series','youtube_video_id','rights_revision','publication_revision','published_at','offline_allowed']) limit 1),
  null,'public sermon has no attribution or private source fields');
select throws_ok($$update app.content_sermon_revisions set notes='changed' where item_id=pg_temp.sr1()$$,
  'PCNT1',null,'published sermon notes are immutable');
select throws_ok($$update app.content_sermon_series_revisions set title='changed' where item_id=pg_temp.se1()$$,
  'PCNT1',null,'published series copy is immutable');

select is(pg_temp.err(pg_temp.cmd(2,'content.save_sermon',pg_temp.rev(pg_temp.sr1()),pg_temp.sermon('SYNTHETIC Revised',
  jsonb_build_object('sermon_id',pg_temp.sr1(),'series_id',pg_temp.se1())))),'ok','Pastor saves replacement draft');
select is(app.content_public_sermon_json(pg_temp.sr1())->>'title','SYNTHETIC Shepherd','last publication remains live while revision is drafted');
select is(pg_temp.err(pg_temp.cmd(3,'content.save_sermon',4,pg_temp.sermon('SYNTHETIC Stale',jsonb_build_object('sermon_id',pg_temp.sr1())))),
  'conflict','stale revision refuses overwriting another editor');
select is(pg_temp.err(pg_temp.cmd(3,'content.publish_sermon',pg_temp.rev(pg_temp.sr1()),jsonb_build_object('sermon_id',pg_temp.sr1()))),'ok',
  'Media publishes replacement');
select is(app.content_public_sermon_json(pg_temp.sr1())->>'title','SYNTHETIC Revised','replacement becomes public atomically');
select is(app.content_public_sermon_json(pg_temp.sr1())->>'publication_revision','2','publication revision increments');

-- A separate sermon authored and published by actor 6 exercises all four erase columns.
create temp table sr2 as select pg_temp.cmd(6,'content.create_sermon',null,pg_temp.sermon('SYNTHETIC Faith',
  jsonb_build_object('series_id',pg_temp.se2(),'youtube_video_id','abcdefghijk','video_rights_id',pg_temp.ri1()))) r;
create function pg_temp.sr2() returns uuid language sql as $$ select (r#>>'{data,sermon_id}')::uuid from sr2 $$;
select is(pg_temp.err(pg_temp.cmd(6,'content.publish_sermon',1,jsonb_build_object('sermon_id',pg_temp.sr2()))),'ok','second synthetic sermon published');
select is(pg_temp.err(pg_temp.cmd(2,'content.withdraw_rights_record',pg_temp.rev(pg_temp.ri1()),jsonb_build_object('rights_id',pg_temp.ri1()))),'ok',
  'video and poster clearance withdrawn');
select is(app.content_public_sermon_json(pg_temp.sr2())->'youtube_video_id','null'::jsonb,'withdrawn clearance removes playable id');
select is(app.content_public_sermon_json(pg_temp.sr2())->'rights_revision','null'::jsonb,'blocked video has no playable rights revision');
select is(app.content_public_sermon_json(pg_temp.sr2())->>'notes',pg_temp.sermon('SYNTHETIC x')->>'notes','church-authored notes survive video rights withdrawal');
select is(app.content_public_sermon_series_json(pg_temp.se1())->'poster','null'::jsonb,'poster immediately disappears after clearance withdrawal');
select ok(exists(select 1 from app.content_public_removals() where public_path like 'sermon_series/%'),'shared sync marks blocked poster for removal');
select is(pg_temp.err(pg_temp.cmd(2,'content.withdraw_sermon_series',pg_temp.rev(pg_temp.se1()),jsonb_build_object('series_id',pg_temp.se1()))),'ok','series can be withdrawn');
select is(app.content_public_sermon_json(pg_temp.sr1())->'series','null'::jsonb,'series withdrawal removes its metadata from still-published sermon');
select isnt(app.content_public_sermon_json(pg_temp.sr1()),null,'sermon teaching remains published');
select is(jsonb_array_length(app.content_public_sermons()->'series'),1,'withdrawn series leaves canonical catalog');

select is(pg_temp.err(pg_temp.cmd(4,'content.withdraw_sermon',pg_temp.rev(pg_temp.sr1()),jsonb_build_object('sermon_id',pg_temp.sr1()))),'forbidden','member cannot withdraw sermon');
select is(pg_temp.err(pg_temp.cmd(2,'content.withdraw_sermon',pg_temp.rev(pg_temp.sr1()),jsonb_build_object('sermon_id',pg_temp.sr1()))),'ok','Pastor withdraws sermon');
select is(app.content_public_sermon_json(pg_temp.sr1()),null,'withdrawn sermon disappears');
select is(pg_temp.err(pg_temp.cmd(2,'content.publish_sermon',pg_temp.rev(pg_temp.sr1()),jsonb_build_object('sermon_id',pg_temp.sr1()))),
  'validation_failed|series_id=not_published','republishing validates the supplied series again');
select is(pg_temp.err(pg_temp.cmd(2,'content.save_sermon',pg_temp.rev(pg_temp.sr1()),pg_temp.sermon('SYNTHETIC Revised',
  jsonb_build_object('sermon_id',pg_temp.sr1())))),'ok','withdrawn sermon can detach withdrawn series');
select is(pg_temp.err(pg_temp.cmd(2,'content.publish_sermon',pg_temp.rev(pg_temp.sr1()),jsonb_build_object('sermon_id',pg_temp.sr1()))),'ok',
  'detached sermon can be republished');
select is(pg_temp.err(pg_temp.cmd(1,'content.archive_sermon',pg_temp.rev(pg_temp.sr1()),jsonb_build_object('sermon_id',pg_temp.sr1()))),'ok','Admin archives sermon');
select is(app.content_public_sermon_json(pg_temp.sr1()),null,'archived sermon is not public');
select is(pg_temp.err(pg_temp.cmd(1,'content.publish_sermon',pg_temp.rev(pg_temp.sr1()),jsonb_build_object('sermon_id',pg_temp.sr1()))),
  'validation_failed|sermon_id=archived','archived item refuses publication');
select ok((app.content_erase_member(jsonb_build_object('phase','check','member_id',pg_temp.mid(6),'account_id',pg_temp.u(6)))->>'remaining')::int>0,
  'deletion check counts save and publish identities');
select is(app.content_erase_member(jsonb_build_object('phase','erase','member_id',pg_temp.mid(6),'account_id',pg_temp.u(6)))->>'remaining','0',
  'registered erase removes every actor reference');
select is((select count(*)::int from app.content_sermon_revisions where saved_by_member=pg_temp.mid(6) or published_by_member=pg_temp.mid(6)
  or saved_by_account=pg_temp.u(6) or published_by_account=pg_temp.u(6)),0,'all four sermon attribution columns erased');
select is((select count(*)::int from app.content_sermon_series_revisions where saved_by_member=pg_temp.mid(6) or published_by_member=pg_temp.mid(6)
  or saved_by_account=pg_temp.u(6) or published_by_account=pg_temp.u(6)),0,'all four series attribution columns erased');
select is(app.content_sermon_revision_json(pg_temp.sr2(),1)->>'saved_by','Former member','staff sees anonymized attribution');
select isnt(app.content_public_sermon_json(pg_temp.sr2()),null,'erasure preserves public sermon copy');
select is((select count(*)::int from app.contract_boundary_violations()),0,'no module boundary violation');
select is((select count(*)::int from app.contract_unowned_objects()),0,'no unowned object');
select * from finish();
rollback;
