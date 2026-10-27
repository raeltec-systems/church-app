-- Story 6.6: revisioned Bible imports, complete manifest chapters, rights gates,
-- anonymous projections and editor permissions. All translation text is SYNTHETIC.
begin;
select no_plan();

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000083' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000083' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+120255501' || (20 + n)::text $$;
create function pg_temp.c(n int) returns jsonb language sql as $$
  select jsonb_build_object('sub', pg_temp.u(n), 'role', 'authenticated', 'aal', 'aal1',
    'session_id', pg_temp.s(n), 'is_anonymous', false,
    'amr', jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', 1790000000)))
$$;
create function pg_temp.session(p_user uuid, p_session uuid) returns uuid language sql as $$
  insert into auth.sessions (id,user_id,aal,created_at)
  values (p_session,p_user,'aal1',clock_timestamp() - interval '1 hour');
  insert into auth.mfa_amr_claims (id,session_id,created_at,updated_at,authentication_method)
  values (gen_random_uuid(),p_session,now(),now(),'password');
  select p_session;
$$;
create function pg_temp.cmd(n int,p_command text,p_expected bigint,p_payload jsonb)
returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims',pg_temp.c(n)::text,true);
  set local role authenticated;
  r := api.content_command(jsonb_build_object('version',1,'command',p_command,
    'request_id',gen_random_uuid(),'expected_revision',p_expected,'payload',p_payload));
  reset role;
  return r;
end;
$$;
create function pg_temp.err(r jsonb) returns text language sql as $$
  select coalesce(r ->> 'code','ok') || coalesce('|' || (select string_agg(k || '=' || v,',' order by k)
    from jsonb_each_text(case when jsonb_typeof(r -> 'field_errors') = 'object'
      then r -> 'field_errors' else '{}'::jsonb end) f(k,v)),'')
$$;
create function pg_temp.read(n int,p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; v_state text; v_msg text; v_detail text;
begin
  if n is null then
    perform set_config('request.jwt.claims','{"role":"anon"}',true);
    set local role anon;
  else
    perform set_config('request.jwt.claims',pg_temp.c(n)::text,true);
    set local role authenticated;
  end if;
  begin
    execute p_sql into r;
    reset role;
    return r;
  exception when others then
    get stacked diagnostics v_state=returned_sqlstate,v_msg=message_text,v_detail=pg_exception_detail;
    reset role;
    return to_jsonb(v_state || '|' || v_msg || '|' || coalesce(v_detail,''));
  end;
end;
$$;
create function pg_temp.rights(p_source text,p_display boolean,p_offline boolean) returns jsonb language sql as $$
  select jsonb_build_object('label','SYNTHETIC Bible source','source_key',p_source,
    'holder','SYNTHETIC Church media team','basis',case when p_source='church-art' then 'church_owned' else 'licence' end,
    'clears_display',p_display,'clears_offline',p_offline,'clears_audio',false,
    'evidence','SYNTHETIC church-created text for local tests.')
$$;
create function pg_temp.web_rights() returns jsonb language sql as $$
  select jsonb_build_object('label','SYNTHETIC World English Bible (WEB)',
    'source_key','web','holder','SYNTHETIC eBible.org public-domain source',
    'basis','public_domain','clears_display',true,'clears_offline',false,
    'clears_audio',false,'evidence','SYNTHETIC source verification: https://ebible.org/engwebp/copyright.htm')
$$;
create function pg_temp.revision(p_id uuid) returns bigint language sql as
$$ select revision from app.content_items where item_id=p_id $$;
create function pg_temp.verse_rows(p_count int,p_prefix text) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object('book_id','GEN','chapter',1,'verse',n,
    'text',p_prefix || ' verse ' || n::text) order by n)
    from generate_series(1,p_count) n
$$;

insert into auth.users (id,aud,role,phone,phone_confirmed_at)
select pg_temp.u(n),'authenticated','authenticated',ltrim(pg_temp.phone(n),'+'),now()
  from generate_series(1,4) n;
select pg_temp.session(pg_temp.u(n),pg_temp.s(n)) from generate_series(1,4) n;
select app.platform_set_environment('local','pgtap content bible');
create temp table m(n int,member_id uuid);
insert into m select n,app.identity_seed_synthetic_link(pg_temp.u(n),'SYNTHETIC Bible Editor ' || n,
  'pgtap content bible') from generate_series(1,4) n;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n=$1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1),'israel');
insert into app.identity_grants(member_id,role,granted_by_operator)
values(pg_temp.mid(2),'pastor','israel'),(pg_temp.mid(3),'media','israel');

-- Schema, manifest metadata and role registries -----------------------------------------------
select has_table('app','content_bible_revisions','revision storage exists');
select has_table('app','content_bible_verses','private verse storage exists');
select has_table('app','content_bible_manifest','trusted count manifest exists');
select is((select kind || ':' || array_to_string(editor_roles, ',')
  from app.content_kinds where kind='bible_translation'),
  'bible_translation:admin,pastor,media',
  'Admin, Pastor and Media edit translations');
select is((select array_to_string(array_agg(command || ':' || creates order by command), '|')
  from app.content_commands where kind='bible_translation'),
  'content.archive_bible_translation:false|content.begin_bible_revision:false|content.create_bible_translation:true|content.finalize_bible_revision:false|content.import_bible_verses:false|content.publish_bible_translation:false|content.withdraw_bible_translation:false',
  'Bible lifecycle commands use shared Content dispatch');
select is((select count(*)::int from app.content_bible_manifest where manifest_version=1 and translation_code='KJV'),66,
  'KJV manifest covers all canonical books');
select is((select count(*)::int from app.content_bible_manifest where manifest_version=1 and translation_code='WEB'),66,
  'WEB manifest covers all canonical books');
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts)
  select 2,'TST99',book_id,chapter_counts from app.content_bible_manifest
   where manifest_version=1 and translation_code='KJV';
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts)
  select 3,'PARTIAL',book_id,chapter_counts from app.content_bible_manifest
   where manifest_version=1 and translation_code='KJV' and book_id <> 'REV';
select ok(app.content_bible_manifest_complete(2,'TST99'),
  'an additional syntactically valid code is accepted with all 66 registered books');
select ok(not app.content_bible_manifest_complete(3,'PARTIAL'),
  'an incomplete additional-code manifest is not trusted');
select is(app.content_bible_latest_manifest('TST99'),2,
  'the public manifest selects its highest complete version');
select is(app.content_bible_latest_manifest('WEB'),2,
  'WEB selects the manifest version that records source omissions');
select is(app.content_bible_manifest_omissions(2,'WEB','LUK',17)::text,'{36}',
  'WEB Luke 17 trusts its omitted verse 36 slot');
select is((pg_temp.read(null,'select api.content_bible_manifest(''WEB'')') #>> '{manifest_version}'),'2',
  'anonymous WEB manifest read exposes the current trusted version');
select is((pg_temp.read(null,$$select (select chapter.value from jsonb_array_elements(
  api.content_bible_manifest('WEB')->'chapters') as chapter(value)
  where chapter.value->>'book_id'='LUK' and chapter.value->>'chapter'='17')
  #>> '{omitted_verses}'$$)),'[36]',
  'anonymous WEB manifest read exposes the exact omitted slot');
select is(app.content_bible_manifest_count(1,'KJV','GEN',1),31,'KJV Genesis 1 has 31 verses');
select is(app.content_bible_manifest_count(1,'WEB','GEN',1),31,'WEB Genesis 1 has 31 verses');
select is((pg_temp.read(null,'select api.content_bible_manifest(''KJV'')') #>> '{chapters,0,verse_count}'),'31',
  'anonymous client reads only the trusted manifest projection');
select is((pg_temp.read(null,'select api.content_bible_manifest(''TST99'')') #>> '{manifest_version}'),'2',
  'anonymous client reads the complete registered manifest version for an additional code');
select is(pg_temp.read(null,'select api.content_bible_manifest(''PARTIAL'')'),null::jsonb,
  'unregistered incomplete manifests have no public projection');
select ok(not has_table_privilege('anon','app.content_bible_verses','SELECT')
  and not has_table_privilege('authenticated','app.content_bible_verses','SELECT')
  and not has_table_privilege('service_role','app.content_bible_verses','SELECT'),
  'client and service roles have no direct verse table access');
select is((select count(*)::int from unnest(array['anon','authenticated','service_role']) as roles(role_name)
  cross join unnest(array['app.content_bible_books','app.content_bible_manifest',
    'app.content_bible_translation_keys','app.content_bible_revisions','app.content_bible_verses'])
    as tables(relation_name)
  where has_table_privilege(roles.role_name,tables.relation_name,'SELECT')
     or has_table_privilege(roles.role_name,tables.relation_name,'INSERT')
     or has_table_privilege(roles.role_name,tables.relation_name,'UPDATE')
     or has_table_privilege(roles.role_name,tables.relation_name,'DELETE')),0,
  'client and service roles have no direct Bible table access');
select ok(has_function_privilege('anon','app.content_public_bible_translations()','EXECUTE')
  and has_function_privilege('authenticated','app.content_public_bible_chapter(uuid,text,integer)','EXECUTE')
  and not has_function_privilege('anon','app.content_bible_manifest_complete(integer,text)','EXECUTE')
  and not has_function_privilege('authenticated','app.content_bible_latest_manifest(text)','EXECUTE')
  and not has_function_privilege('anon','app.content_staff_bibles()','EXECUTE')
  and has_function_privilege('authenticated','app.content_staff_bibles()','EXECUTE'),
  'only anonymous public reads and authenticated staff reads have execute access');
select is((select provolatile::text from pg_proc where oid='api.content_staff_bibles()'::regprocedure),'v',
  'staff reads can lock the active editor grant');

-- Rights records and a private KJV translation with uncleared display rights -------------------
create temp table blocked_rights as select pg_temp.cmd(3,'content.create_rights_record',null,
  pg_temp.rights('acme-press',true,true)) as r;
create function pg_temp.blocked_rights() returns uuid language sql as
$$ select (r #>> '{data,rights_id}')::uuid from blocked_rights $$;
select is(pg_temp.err(pg_temp.cmd(3,'content.verify_rights_record',1,
  jsonb_build_object('rights_id',pg_temp.blocked_rights()))),'ok','Media verifies the synthetic rights record');
select is(app.content_rights_clear(pg_temp.blocked_rights(),'display'),'source_not_cleared',
  'an unlisted source cannot clear display use');
create temp table blocked as select pg_temp.cmd(3,'content.create_bible_translation',null,
  jsonb_build_object('translation_code','KJV','name','SYNTHETIC KJV fixture',
    'rights_id',pg_temp.blocked_rights(),'manifest_version',1)) as r;
create function pg_temp.blocked_id() returns uuid language sql as
$$ select (r #>> '{data,translation_id}')::uuid from blocked $$;
select is(pg_temp.err((select r from blocked)),'ok','Media creates a private KJV draft');
select is(pg_temp.err(pg_temp.cmd(3,'content.import_bible_verses',pg_temp.revision(pg_temp.blocked_id()),
  jsonb_build_object('translation_id',pg_temp.blocked_id(),'revision_no',1,'rows',pg_temp.verse_rows(31,'SYNTHETIC KJV')))),
  'ok','all rows of the chapter import into revision 1');
select is(pg_temp.err(pg_temp.cmd(3,'content.finalize_bible_revision',pg_temp.revision(pg_temp.blocked_id()),
  jsonb_build_object('translation_id',pg_temp.blocked_id(),'revision_no',1))),'ok',
  'the complete manifest chapter finalizes');
select is(pg_temp.err(pg_temp.cmd(3,'content.publish_bible_translation',pg_temp.revision(pg_temp.blocked_id()),
  jsonb_build_object('translation_id',pg_temp.blocked_id()))),'validation_failed|translation_id=source_not_cleared',
  'publication is refused while display rights are blocked');
select is(pg_temp.read(null,'select api.content_public_bible_translations()') -> 'translations','[]'::jsonb,
  'anonymous list hides unpublished or rights-blocked text');
select is(pg_temp.read(null,format('select api.content_public_bible_chapter(%L::uuid,%L,%s)',
  pg_temp.blocked_id(),'GEN',1)) #> '{chapter}','null'::jsonb,'anonymous chapter projection stays empty');

-- Rights-cleared WEB publication, anonymous reads and offline-rights projection -----------------
create temp table cleared_rights as select pg_temp.cmd(3,'content.create_rights_record',null,
  pg_temp.rights('church-art',true,false)) as r;
create function pg_temp.cleared_rights() returns uuid language sql as
$$ select (r #>> '{data,rights_id}')::uuid from cleared_rights $$;
select is(pg_temp.err(pg_temp.cmd(3,'content.verify_rights_record',1,
  jsonb_build_object('rights_id',pg_temp.cleared_rights()))),'ok','the church-owned record clears display use');
select is(app.content_rights_clear(pg_temp.cleared_rights(),'display'),null,'display clearance is in force');
select is(app.content_rights_clear(pg_temp.cleared_rights(),'offline'),'use_not_cleared',
  'offline use remains uncleared');
create temp table web_rights as select pg_temp.cmd(2,'content.create_rights_record',null,
  pg_temp.web_rights()) as r;
create function pg_temp.web_rights_id() returns uuid language sql as
$$ select (r #>> '{data,rights_id}')::uuid from web_rights $$;
select is(pg_temp.err(pg_temp.cmd(2,'content.verify_rights_record',1,
  jsonb_build_object('rights_id',pg_temp.web_rights_id()))),'ok',
  'the fixture WEB rights record is independently verified');
select is(app.content_bible_rights_clear(pg_temp.web_rights_id(),'WEB','display'),null,
  'matching public-domain eBible.org rights clear WEB display');
select is(app.content_bible_rights_clear(pg_temp.cleared_rights(),'WEB','display'),'source_mismatch',
  'a generic church-owned display right cannot authorize WEB text');
create temp table extensible as select pg_temp.cmd(2,'content.create_bible_translation',null,
  jsonb_build_object('translation_code','TST99','name','SYNTHETIC additional translation',
    'rights_id',pg_temp.cleared_rights(),'manifest_version',2)) as r;
create function pg_temp.extensible_id() returns uuid language sql as
$$ select (r #>> '{data,translation_id}')::uuid from extensible $$;
select is(pg_temp.err((select r from extensible)),'ok',
  'staff can create an additional code backed by a complete manifest');
select is(pg_temp.err(pg_temp.cmd(2,'content.create_bible_translation',null,
  jsonb_build_object('translation_code','PARTIAL','name','SYNTHETIC incomplete manifest',
    'rights_id',pg_temp.cleared_rights(),'manifest_version',3))),
  'validation_failed|manifest_version=not_registered',
  'staff cannot create a code with only a partial manifest');
select is(pg_temp.err(pg_temp.cmd(2,'content.begin_bible_revision',pg_temp.revision(pg_temp.extensible_id()),
  jsonb_build_object('translation_id',pg_temp.extensible_id(),'rights_id',pg_temp.cleared_rights(),
    'manifest_version',2))),'ok',
  're-import can select a registered manifest version for the same translation code');
select is((select manifest_version::text from app.content_bible_revisions
  where item_id=pg_temp.extensible_id() and revision_no=2),'2',
  'the revision retains the selected manifest version');
create temp table wrong_web as select pg_temp.cmd(2,'content.create_bible_translation',null,
  jsonb_build_object('translation_code','WEB','name','SYNTHETIC mismatched WEB fixture',
    'rights_id',pg_temp.cleared_rights(),'manifest_version',2)) as r;
create function pg_temp.wrong_web_id() returns uuid language sql as
$$ select (r #>> '{data,translation_id}')::uuid from wrong_web $$;
select is(pg_temp.err((select r from wrong_web)),'ok','a WEB draft can be held privately while rights are reviewed');
select is(pg_temp.err(pg_temp.cmd(2,'content.import_bible_verses',pg_temp.revision(pg_temp.wrong_web_id()),
  jsonb_build_object('translation_id',pg_temp.wrong_web_id(),'revision_no',1,'rows',
    pg_temp.verse_rows(31,'SYNTHETIC WEB mismatch')))),'ok',
  'a rights-mismatched WEB draft can be prepared privately');
select is(pg_temp.err(pg_temp.cmd(2,'content.finalize_bible_revision',pg_temp.revision(pg_temp.wrong_web_id()),
  jsonb_build_object('translation_id',pg_temp.wrong_web_id(),'revision_no',1))),'ok',
  'a complete rights-mismatched WEB draft remains private');
select is(pg_temp.err(pg_temp.cmd(2,'content.publish_bible_translation',pg_temp.revision(pg_temp.wrong_web_id()),
  jsonb_build_object('translation_id',pg_temp.wrong_web_id()))),
  'validation_failed|translation_id=source_mismatch',
  'WEB cannot be published with an unrelated church-owned rights record');

create temp table web as select pg_temp.cmd(2,'content.begin_bible_revision',pg_temp.revision(pg_temp.wrong_web_id()),
  jsonb_build_object('translation_id',pg_temp.wrong_web_id(),
    'rights_id',pg_temp.web_rights_id(),'manifest_version',2)) as r;
create function pg_temp.web_id() returns uuid language sql as
$$ select (r #>> '{data,translation_id}')::uuid from web $$;
select is(pg_temp.err((select r from web)),'ok','Pastor opens a corrected WEB revision with matching rights');
select is(pg_temp.err(pg_temp.cmd(2,'content.import_bible_verses',pg_temp.revision(pg_temp.web_id()),
  jsonb_build_object('translation_id',pg_temp.web_id(),'revision_no',2,'rows',
    pg_temp.verse_rows(31,'SYNTHETIC WEB') ||
    (select jsonb_agg(jsonb_build_object('book_id','LUK','chapter',17,'verse',n,
      'text',case when n=36 then '' else 'SYNTHETIC WEB Luke 17 verse ' || n::text end)
      order by n) from generate_series(1,37) n)))),
  'ok','Pastor imports WEB text and its trusted blank verse slot');
select is(pg_temp.read(null,'select api.content_public_bible_translations()') #>> '{translations,0}',null,
  'the complete draft is still private before publication');
select is(pg_temp.err(pg_temp.cmd(2,'content.finalize_bible_revision',pg_temp.revision(pg_temp.web_id()),
  jsonb_build_object('translation_id',pg_temp.web_id(),'revision_no',2))),'ok','Pastor finalizes the complete draft');
select is(pg_temp.err(pg_temp.cmd(2,'content.publish_bible_translation',pg_temp.revision(pg_temp.web_id()),
  jsonb_build_object('translation_id',pg_temp.web_id()))),'ok','Pastor publishes with display clearance');
select is(pg_temp.read(null,'select api.content_public_bible_translations()') #>> '{translations,0,translation_code}',
  'WEB','anonymous list reads the published WEB translation');
select is((pg_temp.read(null,format('select api.content_public_bible_chapter(%L::uuid,%L,%s)',
  pg_temp.web_id(),'GEN',1)) #>> '{chapter,verses,30,verse}'),'31',
  'anonymous chapter projection contains every verse through the trusted terminal count');
select is((pg_temp.read(null,format('select api.content_public_bible_chapter(%L::uuid,%L,%s)',
  pg_temp.web_id(),'GEN',1)) #>> '{chapter,offline_allowed}'),'false',
  'display-only publication returns offline_allowed false');
select is((pg_temp.read(null,format('select api.content_public_bible_chapter(%L::uuid,%L,%s)',
  pg_temp.web_id(),'LUK',17)) #>> '{chapter,omitted_verses}'),'[36]',
  'public WEB chapter retains the omitted verse number');
select is((pg_temp.read(null,format('select api.content_public_bible_chapter(%L::uuid,%L,%s)',
  pg_temp.web_id(),'LUK',17)) #>> '{chapter,verses,35,verse}'),'37',
  'public WEB verse text resumes at verse 37 without fabricated text');
select is((select array_agg(k order by k)::text from jsonb_object_keys(
  pg_temp.read(null,format('select api.content_public_bible_chapter(%L::uuid,%L,%s)',pg_temp.web_id(),'GEN',1)
    ) -> 'chapter') k),
  '{book_id,chapter,offline_allowed,omitted_verses,publication_revision,published_at,translation_code,translation_id,translation_name,verse_count,verses}',
  'the public chapter shape contains only the named public projection fields');

-- Missing terminal verse, revision preservation and monotonic re-import numbering ----------------
select is(pg_temp.err(pg_temp.cmd(3,'content.begin_bible_revision',pg_temp.revision(pg_temp.web_id()),
  jsonb_build_object('translation_id',pg_temp.web_id(),'rights_id',pg_temp.cleared_rights()))),'ok',
  're-import starts a new revision after the live one');
select is((select draft_revision_no::text from app.content_items where item_id=pg_temp.web_id()),'3',
  'the first re-import after publication is revision 3');
select is(pg_temp.err(pg_temp.cmd(3,'content.import_bible_verses',pg_temp.revision(pg_temp.web_id()),
  jsonb_build_object('translation_id',pg_temp.web_id(),'revision_no',3,'rows',pg_temp.verse_rows(30,'SYNTHETIC truncated')))),
  'ok','an incomplete chapter may remain private while chunks are being imported');
select is(pg_temp.err(pg_temp.cmd(3,'content.finalize_bible_revision',pg_temp.revision(pg_temp.web_id()),
  jsonb_build_object('translation_id',pg_temp.web_id(),'revision_no',3))),
  'validation_failed|revision_no=incomplete_chapter','missing terminal verse blocks finalization');
select is((pg_temp.read(null,format('select api.content_public_bible_chapter(%L::uuid,%L,%s)',
  pg_temp.web_id(),'GEN',1)) #>> '{chapter,publication_revision}'),'2',
  'incomplete draft leaves the prior published revision live');
select is((select count(*)::int from app.content_bible_verses where item_id=pg_temp.web_id() and revision_no=2),68,
  'published rows are retained');
select is((select count(*)::int from app.content_bible_verses where item_id=pg_temp.web_id() and revision_no=3),30,
  'incomplete prior draft rows are retained');
select is(pg_temp.err(pg_temp.cmd(3,'content.begin_bible_revision',pg_temp.revision(pg_temp.web_id()),
  jsonb_build_object('translation_id',pg_temp.web_id(),'rights_id',pg_temp.cleared_rights()))),'ok',
  'a retry opens the next revision without overwriting either earlier revision');
select is((select last_revision_no::text || '|' || draft_revision_no::text
  from app.content_items where item_id=pg_temp.web_id()),'4|4','retry begins at revision 4');
select is((select count(*)::int from app.content_bible_verses where item_id=pg_temp.web_id()),129,
  'all previous verses remain after retry starts');
select throws_ok(format($$delete from app.content_bible_verses where item_id=%L and revision_no=2$$,pg_temp.web_id()),
  'PCNT1',null,'published verse rows are immutable');

-- Role and table boundaries ----------------------------------------------------------------------
select is(pg_temp.read(2,'select api.content_staff_bibles()') #>> '{capacity}','pastor',
  'Pastor can read the staff catalog');
select is(pg_temp.read(3,'select api.content_staff_bibles()') #>> '{capacity}','media',
  'Media can read the staff catalog');
select is(pg_temp.read(1,'select api.content_staff_bibles()') #>> '{capacity}','admin',
  'Admin can read the staff catalog');
select is(pg_temp.err(pg_temp.cmd(4,'content.create_bible_translation',null,
  jsonb_build_object('translation_code','KJV','name','SYNTHETIC forbidden','rights_id',pg_temp.cleared_rights(),
    'manifest_version',1))),'forbidden','plain member cannot create a translation');
select is(pg_temp.read(null,'select api.content_staff_bibles()') #>> '{}',
  '42501|permission denied for function content_staff_bibles|','anonymous cannot read staff state');
select ok(not has_table_privilege('anon','app.content_bible_revisions','SELECT')
  and not has_table_privilege('authenticated','app.content_bible_revisions','SELECT'),
  'draft revisions are private to the command and staff projections');
select is(pg_temp.read(null,'select api.content_public_bible_translations()') #>> '{translations,0,translation_code}',
  'WEB','anonymous reads never expose the private KJV or WEB draft revisions');

-- A published WEB revision stops reading when its live rights revision no longer matches --------
select is(pg_temp.err(pg_temp.cmd(2,'content.save_rights_record',pg_temp.revision(pg_temp.web_rights_id()),
  pg_temp.rights('church-art',true,true) || jsonb_build_object('rights_id',pg_temp.web_rights_id()))),
  'ok','an unrelated replacement rights revision can be recorded for review');
select is(pg_temp.err(pg_temp.cmd(2,'content.verify_rights_record',pg_temp.revision(pg_temp.web_rights_id()),
  jsonb_build_object('rights_id',pg_temp.web_rights_id()))),'ok',
  'the unrelated church-owned rights revision becomes the current record');
select is(app.content_bible_rights_clear(pg_temp.web_rights_id(),'WEB','display'),'source_mismatch',
  'a later nonmatching rights revision fails WEB display reads');
select is(app.content_bible_rights_clear(pg_temp.web_rights_id(),'WEB','offline'),'source_mismatch',
  'a later nonmatching rights revision fails WEB offline reads');
select is(pg_temp.read(null,'select api.content_public_bible_translations()') -> 'translations','[]'::jsonb,
  'a previously published WEB translation disappears when its live rights source changes');
select is(pg_temp.read(null,format('select api.content_public_bible_chapter(%L::uuid,%L,%s)',
  pg_temp.web_id(),'GEN',1)) #> '{chapter}','null'::jsonb,
  'the previously published WEB chapter becomes unreadable after its rights source changes');

-- Deletion clears publisher identity even when no saved attribution remains.
update app.content_bible_revisions
   set saved_by_member = '00000000-0000-0000-0000-000000000000',
       saved_by_account = '00000000-0000-0000-0000-000000000000'
 where saved_by_member = pg_temp.mid(2);
select results_eq($$select part || ':' || handler from app.content_erase_parts where part = 'bible_revisions'$$,
  $$values ('bible_revisions:app.content_bible_erase_part(jsonb)'::text)$$,
  'the Bible erase part is registered with Content''s deletion hook');
select is(app.content_bible_erase_part(jsonb_build_object('member_id',pg_temp.mid(2),
  'account_id',pg_temp.u(2),'phase','check')),1,
  'deletion check counts publication-only attribution');
select is(app.content_bible_erase_part(jsonb_build_object('member_id',pg_temp.mid(2),
  'account_id',pg_temp.u(2),'phase','erase')),0,
  'deletion erases and counts every Bible attribution column');
select ok((select published_by_member = '00000000-0000-0000-0000-000000000000'::uuid
  and published_by_account = '00000000-0000-0000-0000-000000000000'::uuid
  from app.content_bible_revisions where item_id = pg_temp.web_id() and revision_no = 2),
  'published Bible history retains no deleted publisher identity');

select * from finish();
rollback;
