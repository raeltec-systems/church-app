-- Story 6.2: rights records, the q5_content_rights gate, the asset path (uploads into the private
-- draft bucket, the desired public set and its sync plan) and Home banners. Registries,
-- privileges, the buckets, the rights check, the upload checks, banner publication with its
-- refusals, the anonymous banner read (only once the public object is present), withdrawal and
-- rights withdrawal, the editors' reads, the Edge function's plan and preview reads, the erase
-- parts and the closed gate in production. Storage objects are simulated by rows in
-- storage.objects (rolled back). Every account, phone and name is SYNTHETIC (fictional range
-- +1 202 555 0161-0166).
begin;
select plan(152);

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-0000000082' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-0000000082' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.phone(n int) returns text language sql as
$$ select '+120255501' || (60 + n)::text $$;
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
create function pg_temp.at(p_days int, p_time text default '10:00') returns timestamptz language sql as
$$ select (((now() at time zone 'Africa/Lusaka')::date + p_days) + p_time::time) at time zone 'Africa/Lusaka' $$;
create function pg_temp.iso(p timestamptz) returns text language sql as
$$ select to_char(p at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') $$;
create function pg_temp.rev(p uuid) returns bigint language sql as
$$ select revision from app.content_items where item_id = p $$;
create function pg_temp.rights(p_label text, p_source text, p_display boolean, p_offline boolean,
                               p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('label', p_label, 'source_key', p_source,
                            'holder', 'SYNTHETIC Church media team', 'basis', 'church_owned',
                            'clears_display', p_display, 'clears_offline', p_offline,
                            'clears_audio', false,
                            'evidence', 'SYNTHETIC: made by the church media team for testing.') || p_extra
$$;
create function pg_temp.bn(p_kind text, p_year int, p_title text, p_extra jsonb default '{}'::jsonb)
returns jsonb language sql as $$
  select jsonb_build_object('banner_kind', p_kind, 'theme_year', p_year, 'title', p_title,
                            'subtitle', 'Deuteronomy 7:9', 'alt_text', 'SYNTHETIC navy artwork with the theme words',
                            'event_id', null) || p_extra
$$;
create function pg_temp.up(p_item uuid, p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('item_id', p_item, 'purpose', 'banner_image', 'media_type', 'image/png',
                            'byte_size', 3000000, 'width', 1920, 'height', 1080,
                            'sha256', repeat('ab', 32)) || p_extra
$$;
-- A stored object in a bucket, as Storage records it.
create function pg_temp.obj(p_bucket text, p_name text, p_size bigint, p_type text) returns void
language sql as $$
  insert into storage.objects (bucket_id, name, metadata)
  values (p_bucket, p_name, jsonb_build_object('size', p_size, 'mimetype', p_type));
$$;
-- A ready banner_image asset uploaded by account n for item p_item (begin, store, complete).
create function pg_temp.ready_asset(n int, p_item uuid) returns uuid language plpgsql as $$
declare
  r jsonb;
begin
  r := pg_temp.cmd(n, 'content.begin_asset_upload', null, pg_temp.up(p_item));
  perform pg_temp.obj('content-drafts', r #>> '{data,draft_path}', 3000000, 'image/png');
  r := pg_temp.cmd(n, 'content.complete_asset_upload', null,
                   jsonb_build_object('asset_id', r #>> '{data,asset_id}'));
  return (r #>> '{data,asset_id}')::uuid;
end;
$$;

-- Accounts: 1 Admin; 2 Pastor; 3 Media M; 4 plain member; 5 Pending (no member link); 6 Media B
-- (erased at the end).
insert into auth.users (id, aud, role, phone, phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', ltrim(pg_temp.phone(n), '+'), now()
  from generate_series(1, 6) n;
select pg_temp.session(pg_temp.u(n), pg_temp.s(n)) from generate_series(1, 6) n;
select app.platform_set_environment('local', 'pgtap content banners');
create temp table m (n int, member_id uuid);
insert into m select n, app.identity_seed_synthetic_link(pg_temp.u(n), 'SYNTHETIC Banner Member ' || n,
                                                         'pgtap content banners')
  from generate_series(1, 6) n where n <> 5;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n = $1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1), 'israel');
insert into app.identity_grants (member_id, role, granted_by_operator)
values (pg_temp.mid(2), 'pastor', 'israel'), (pg_temp.mid(3), 'media', 'israel'),
       (pg_temp.mid(6), 'media', 'israel');

-- Structure, registries, privileges and buckets ---------------------------------------------------
select has_table('app', t, format('app.%s exists', t))
  from unnest(array['content_rights_revisions', 'content_banner_revisions', 'content_media_types',
                    'content_asset_purposes', 'content_assets', 'content_revision_files',
                    'content_public_conditions']) t;
select results_eq(
  $$select (n.nspname || '.' || p.proname)::text collate "C" from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'api') and p.proname like 'content\_%' and p.proname not like '%event%'
       and p.proname not like '%giving%' and p.proname not like '%announcement%'
       and has_function_privilege('anon', p.oid, 'EXECUTE')
     order by 1$$,
  $$values ('api.content_bible_manifest'::text collate "C"),
           ('api.content_public_banners'), ('api.content_public_bible_chapter'),
           ('api.content_public_bible_translations'), ('app.content_bible_manifest_json'),
           ('app.content_public_banners'), ('app.content_public_bible_chapter'),
           ('app.content_public_bible_translations')$$,
  'anon can execute only the public content reads (besides event reads)');
select results_eq(
  $$select (n.nspname || '.' || p.proname)::text collate "C" from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'api') and p.proname like 'content\_%' and p.proname not like '%event%'
       and p.proname not like '%giving%' and p.proname not like '%announcement%'
       and p.proname <> 'content_command' and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     order by 1$$,
  $$values ('api.content_asset_preview'::text collate "C"), ('api.content_bible_manifest'),
           ('api.content_file_plan'), ('api.content_public_banners'),
           ('api.content_public_bible_chapter'), ('api.content_public_bible_translations'),
           ('api.content_staff_banners'), ('api.content_staff_bibles'), ('api.content_staff_rights'),
           ('app.content_asset_preview'), ('app.content_bible_manifest_json'), ('app.content_file_plan'),
           ('app.content_public_banners'), ('app.content_public_bible_chapter'),
           ('app.content_public_bible_translations'), ('app.content_staff_banners'),
           ('app.content_staff_bibles'), ('app.content_staff_rights')$$,
  'authenticated can execute only the reads (besides the command and the event reads)');
select is_definer('app', 'content_public_banners', array[]::text[], 'the public banner read body is a definer');
select isnt_definer('api', 'content_public_banners', array[]::text[], 'its api wrapper is invoker');
select results_eq($$select kind, editor_roles from app.content_kinds where kind not in ('event', 'giving_method', 'announcement') order by 1$$,
  $$values ('asset'::text, array['admin', 'pastor', 'media']::text[]),
           ('banner', array['admin', 'pastor', 'media']::text[]),
           ('bible_translation', array['admin', 'pastor', 'media']::text[]),
           ('rights', array['admin', 'pastor', 'media']::text[])$$,
  'rights, banners, Bible translations and uploads are for Admin, Pastor and Media');
select results_eq($$select command || ':' || creates from app.content_commands where kind not in ('event', 'giving_method', 'announcement') order by 1$$,
  $$values ('content.archive_banner:false'::text), ('content.archive_bible_translation:false'),
           ('content.archive_rights_record:false'),
           ('content.begin_asset_upload:true'), ('content.begin_bible_revision:false'),
           ('content.complete_asset_upload:true'), ('content.create_banner:true'),
           ('content.create_bible_translation:true'), ('content.create_rights_record:true'),
           ('content.finalize_bible_revision:false'), ('content.import_bible_verses:false'),
           ('content.publish_banner:false'), ('content.publish_bible_translation:false'),
           ('content.save_banner:false'),
           ('content.save_rights_record:false'), ('content.verify_rights_record:false'),
           ('content.withdraw_banner:false'), ('content.withdraw_bible_translation:false'),
           ('content.withdraw_rights_record:false')$$,
  'the nineteen commands are registered');
select results_eq($$select part || ':' || handler from app.content_erase_parts where part not in ('event_revisions', 'giving_methods', 'announcement_revisions', 'event_rsvps') order by 1$$,
  $$values ('asset_uploads:app.content_asset_erase_part(jsonb)'::text),
           ('banner_revisions:app.content_banner_erase_part(jsonb)'),
           ('bible_revisions:app.content_bible_erase_part(jsonb)'),
           ('rights_revisions:app.content_rights_erase_part(jsonb)')$$, 'four erase parts are registered');
select results_eq($$select kind || ':' || handler from app.content_public_conditions
                     where kind = 'banner' order by 1$$, -- story 6.11 pins the event condition
  $$values ('banner:app.content_banner_public_condition(jsonb)'::text)$$,
  'banners register their public condition (a linked event must be public)');
select throws_ok($$select app.content_register_public_condition('event', 'app.content_erase_member(jsonb)'::regprocedure)$$,
  'PCTR1', null, 'a public condition must answer a boolean');
select results_eq(
  $$select gate, decision_ref, state, fixture_value ? 'fixture_label' from app.policy_gates where gate = 'q5_content_rights'$$,
  $$values ('q5_content_rights'::text, 'Q5'::text, 'unresolved'::text, true)$$,
  'the Q5 gate is registered, unresolved, with a labelled fixture');
select is(app.policy_effective('q5_content_rights') ->> 'source', 'fixture', 'locally Q5 reads its fixture');
select is(app.content_q5_uses('synthetic'), array['audio', 'display', 'offline'], 'the fixture lists SYNTHETIC sources');
select is(app.content_q5_uses('acme-press'), array[]::text[], 'an unlisted source has no cleared use');
select is(app.content_q5_uses('church-art'), array[]::text[], 'the church-owned source is intentionally absent from Q5');
select results_eq(
  $$select id, public, file_size_limit, allowed_mime_types from storage.buckets
     where id in ('content-drafts', 'content-public') order by id$$,
  $$values ('content-drafts'::text, false, 10485760::bigint, array['image/png', 'image/jpeg', 'image/webp']::text[]),
           ('content-public', true, 10485760::bigint, array['image/png', 'image/jpeg', 'image/webp']::text[])$$,
  'a private draft bucket and a public bucket, with type and size limits');
select is((select count(*)::int from pg_policies where schemaname = 'storage'), 0,
  'no Storage policy exists: no client role reads, lists or writes either bucket through Storage');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'storage' and p.proname like 'content%'), 0, 'no function is added to storage');
select results_eq(
  $$select purpose, kind, rights_use, max_bytes, min_width, min_height, max_width, max_height, min_ratio, max_ratio
      from app.content_asset_purposes where kind in ('banner', 'giving_method') order by 1$$, -- 6.11 pins event_poster
  $$values ('banner_image'::text, 'banner'::text, 'display'::text, 5242880::bigint, 960, 540, 6000, 6000, 1.30, 2.40),
           ('giving_logo', 'giving_method', 'display', 2097152::bigint, 32, 32, 2000, 2000, 0.20, 5.00)$$,
  'the banner and giving logo purposes have bounded image limits');

-- Rights records -----------------------------------------------------------------------------------
create temp table r1 as select pg_temp.cmd(3, 'content.create_rights_record', null,
  pg_temp.rights('SYNTHETIC theme artwork', 'church-art', true, false)) as r;
create function pg_temp.r1() returns uuid language sql as $$ select (r #>> '{data,rights_id}')::uuid from r1 $$;
select is((select (r -> 'data') - 'rights_id' from r1),
  '{"state": "draft", "revision": 1, "live_revision_no": null, "draft_revision_no": 1}'::jsonb,
  'Media drafts a rights record');
select is(pg_temp.err(pg_temp.cmd(4, 'content.create_rights_record', null,
  pg_temp.rights('SYNTHETIC x', 'synthetic', true, false))), 'forbidden', 'a plain member cannot');
select is(pg_temp.err(pg_temp.cmd(5, 'content.create_rights_record', null,
  pg_temp.rights('SYNTHETIC x', 'synthetic', true, false))), 'forbidden', 'a Pending account cannot');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_rights_record', null, '{"x": 1}')),
  'validation_failed|basis=required,clears_audio=required,clears_display=required,clears_offline=required,evidence=required,holder=required,label=required,source_key=required,x=unknown_field',
  'every missing field is named');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_rights_record', null,
  pg_temp.rights('SYNTHETIC x', 'Bad Key', false, false, '{"basis": "stolen", "clears_audio": "yes"}'))),
  'validation_failed|basis=invalid,clears_audio=invalid,source_key=invalid',
  'source key, basis and flags are checked');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_rights_record', null,
  pg_temp.rights('SYNTHETIC x', 'synthetic', false, false))),
  'validation_failed|clears_display=none_cleared', 'a record must clear at least one use');
select is(app.content_rights_clear(pg_temp.r1(), 'display'), 'not_in_force', 'a draft record clears nothing');
select is(app.content_rights_clear(null, 'display'), 'required', 'no record: required');
select is(app.content_rights_clear(gen_random_uuid(), 'display'), 'unknown', 'no such record: unknown');
select is(pg_temp.err(pg_temp.cmd(4, 'content.verify_rights_record', 1,
  jsonb_build_object('rights_id', pg_temp.r1()))), 'forbidden', 'a plain member cannot verify');
select is(pg_temp.cmd(3, 'content.verify_rights_record', 1, jsonb_build_object('rights_id', pg_temp.r1()))
            #>> '{data,state}', 'published', 'Media verifies: the record is in force');
select is(app.content_rights_clear(pg_temp.r1(), 'display'), null, 'church-owned clears display without Q5 approval');
select is(app.content_rights_clear(pg_temp.r1(), 'offline'), 'use_not_cleared', 'but not offline use');
select is((select verified_by || '|' || (verified_at is not null)::text
             from (select x ->> 'verified_by' as verified_by, x ->> 'verified_at' as verified_at
                     from jsonb_array_elements(pg_temp.read(2, 'select api.content_staff_rights()') -> 'rights') x
                    where x ->> 'rights_id' = pg_temp.r1()::text) s),
  'SYNTHETIC Banner Member 3|true', 'the editors read the verifier and the date (Pastor reading)');
select is((select x -> 'q5_uses' from jsonb_array_elements(pg_temp.read(1, 'select api.content_staff_rights()') -> 'rights') x
            where x ->> 'rights_id' = pg_temp.r1()::text), '[]'::jsonb,
  'and Q5 lists no uses for the church-owned source');
select is(pg_temp.err(pg_temp.cmd(3, 'content.save_rights_record', pg_temp.rev(pg_temp.r1()),
  pg_temp.rights('SYNTHETIC theme artwork v2', 'church-art', true, true, jsonb_build_object('rights_id', pg_temp.r1())))),
  'ok', 'a new draft revision of a verified record');
select is((select live_revision_no || '|' || draft_revision_no from app.content_items where item_id = pg_temp.r1()),
  '1|2', 'the verified revision stays in force until the draft is verified');
select is(app.content_rights_clear(pg_temp.r1(), 'offline'), 'use_not_cleared', 'the unverified draft clears nothing yet');
select throws_ok(format($$update app.content_rights_revisions set evidence = 'changed' where item_id = %L and revision_no = 1$$, pg_temp.r1()),
  'PCNT1', null, 'a verified revision is immutable');
-- Other records used below: a third-party source missing from the Q5 fixture, an offline-only
-- record and one left unverified.
create temp table r2 as select pg_temp.cmd(3, 'content.create_rights_record', null,
  pg_temp.rights('SYNTHETIC licensed photo', 'acme-press', true, false, '{"basis": "licence"}')) as r;
create function pg_temp.r2() returns uuid language sql as $$ select (r #>> '{data,rights_id}')::uuid from r2 $$;
select is(pg_temp.err(pg_temp.cmd(3, 'content.verify_rights_record', 1, jsonb_build_object('rights_id', pg_temp.r2()))),
  'ok', 'a third-party record can be verified');
select is(app.content_rights_clear(pg_temp.r2(), 'display'), 'source_not_cleared',
  'but a source missing from the Q5 value clears nothing');
create temp table r3 as select pg_temp.cmd(3, 'content.create_rights_record', null,
  pg_temp.rights('SYNTHETIC offline only', 'church-art', false, true)) as r;
create function pg_temp.r3() returns uuid language sql as $$ select (r #>> '{data,rights_id}')::uuid from r3 $$;
select is(pg_temp.err(pg_temp.cmd(3, 'content.verify_rights_record', 1, jsonb_build_object('rights_id', pg_temp.r3()))),
  'ok', 'an offline-only record is verified');
create temp table r4 as select pg_temp.cmd(3, 'content.create_rights_record', null,
  pg_temp.rights('SYNTHETIC unverified', 'synthetic', true, false)) as r;
create function pg_temp.r4() returns uuid language sql as $$ select (r #>> '{data,rights_id}')::uuid from r4 $$;

-- Uploads ------------------------------------------------------------------------------------------
create temp table b1 as select pg_temp.cmd(3, 'content.create_banner', null,
  pg_temp.bn('theme', 2026, 'SYNTHETIC Theme 2026')) as r;
create function pg_temp.b1() returns uuid language sql as $$ select (r #>> '{data,banner_id}')::uuid from b1 $$;
select is((select (r -> 'data') - 'banner_id' from b1),
  '{"state": "draft", "revision": 1, "live_revision_no": null, "draft_revision_no": 1}'::jsonb,
  'Media drafts a theme banner');
create temp table u1 as select pg_temp.cmd(3, 'content.begin_asset_upload', null, pg_temp.up(pg_temp.b1())) as r;
select is((select r #>> '{data,state}' from u1), 'pending', 'an upload begins pending');
select ok((select (r #>> '{data,draft_path}') = (r #>> '{data,asset_id}') || '.png' from u1),
  'its draft path is the asset id and the measured type''s extension');
select is((select r ->> 'revision' from u1), '1', 'an upload leaves the banner revision unchanged');
select is(pg_temp.err(pg_temp.cmd(3, 'content.begin_asset_upload', null,
  pg_temp.up(pg_temp.b1(), '{"byte_size": 5242881}'))), 'validation_failed|byte_size=too_large',
  'a file over 5 MiB is refused');
select is(pg_temp.err(pg_temp.cmd(3, 'content.begin_asset_upload', null,
  pg_temp.up(pg_temp.b1(), '{"width": 800, "height": 450}'))), 'validation_failed|height=too_small,width=too_small',
  'an image under 960 x 540 is refused');
select is(pg_temp.err(pg_temp.cmd(3, 'content.begin_asset_upload', null,
  pg_temp.up(pg_temp.b1(), '{"width": 7000, "height": 3500}'))), 'validation_failed|width=too_large',
  'an image over 6000 wide is refused');
select is(pg_temp.err(pg_temp.cmd(3, 'content.begin_asset_upload', null,
  pg_temp.up(pg_temp.b1(), '{"width": 1200, "height": 1200}'))), 'validation_failed|width=bad_ratio',
  'a square image is refused for a 16:9 banner');
select is(pg_temp.err(pg_temp.cmd(3, 'content.begin_asset_upload', null,
  pg_temp.up(pg_temp.b1(), '{"media_type": "image/svg+xml"}'))), 'validation_failed|media_type=unsupported_type',
  'an SVG is refused');
select is(pg_temp.err(pg_temp.cmd(3, 'content.begin_asset_upload', null,
  pg_temp.up(pg_temp.b1(), '{"sha256": "ABC", "purpose": "poster", "x": 1}'))),
  'validation_failed|purpose=unknown,sha256=invalid,x=unknown_field', 'purpose, digest and unknown fields');
select is(pg_temp.err(pg_temp.cmd(3, 'content.begin_asset_upload', null,
  pg_temp.up(gen_random_uuid()))), 'validation_failed|item_id=unknown', 'an unknown item');
select is(pg_temp.err(pg_temp.cmd(3, 'content.begin_asset_upload', null,
  pg_temp.up(pg_temp.r1()))), 'validation_failed|purpose=unsupported', 'a banner image cannot go on a rights record');
select is(pg_temp.err(pg_temp.cmd(4, 'content.begin_asset_upload', null, pg_temp.up(pg_temp.b1()))),
  'forbidden', 'a plain member cannot upload');
select is(pg_temp.err(pg_temp.cmd(5, 'content.begin_asset_upload', null, pg_temp.up(pg_temp.b1()))),
  'forbidden', 'a Pending account cannot upload');
select is(pg_temp.read(null, $q$select api.content_command('{"version": 1}'::jsonb)$q$) #>> '{}',
  '42501|permission denied for function content_command|', 'anon cannot upload');
select is(pg_temp.err(pg_temp.cmd(3, 'content.complete_asset_upload', null,
  jsonb_build_object('asset_id', (select r #>> '{data,asset_id}' from u1)))),
  'validation_failed|asset_id=not_uploaded', 'completing before the object is stored is refused');
select pg_temp.obj('content-drafts', (select r #>> '{data,draft_path}' from u1), 2999999, 'image/png');
select is(pg_temp.err(pg_temp.cmd(3, 'content.complete_asset_upload', null,
  jsonb_build_object('asset_id', (select r #>> '{data,asset_id}' from u1)))),
  'validation_failed|asset_id=mismatch', 'a stored object of another size is refused');
update storage.objects set metadata = jsonb_build_object('size', 3000000, 'mimetype', 'image/png')
 where bucket_id = 'content-drafts' and name = (select r #>> '{data,draft_path}' from u1);
create temp table c1 as select pg_temp.cmd(3, 'content.complete_asset_upload', null,
  jsonb_build_object('asset_id', (select r #>> '{data,asset_id}' from u1))) as r;
select is((select r #>> '{data,state}' from c1), 'ready', 'the matching object makes the asset ready');
select is(pg_temp.err(pg_temp.cmd(2, 'content.complete_asset_upload', null,
  jsonb_build_object('asset_id', (select r #>> '{data,asset_id}' from u1)))), 'ok',
  'completing again is a no-op (a Pastor, also an editor of banners)');
create function pg_temp.a1() returns uuid language sql as $$ select (r #>> '{data,asset_id}')::uuid from u1 $$;
create temp table pending_asset as select pg_temp.cmd(3, 'content.begin_asset_upload', null, pg_temp.up(pg_temp.b1())) as r;

-- Banners: validation and saving -------------------------------------------------------------------
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_banner', null,
  pg_temp.bn('theme', null, 'SYNTHETIC x'))), 'validation_failed|theme_year=required', 'a theme needs its year');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_banner', null,
  pg_temp.bn('campaign', 2026, 'SYNTHETIC x'))), 'validation_failed|theme_year=must_be_null', 'a campaign has no year');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_banner', null,
  pg_temp.bn('theme', 1999, repeat('x', 81), jsonb_build_object('event_id', gen_random_uuid(), 'alt_text', ' ')))),
  'validation_failed|alt_text=required,event_id=must_be_null,theme_year=out_of_range,title=too_long',
  'year range, title length, a text alternative and no event on a theme');
select is(pg_temp.err(pg_temp.cmd(3, 'content.create_banner', null,
  pg_temp.bn('campaign', null, 'SYNTHETIC x', jsonb_build_object('event_id', gen_random_uuid(), 'banner_kind', 'campaign')))),
  'validation_failed|event_id=unknown', 'a linked event must exist');
select is(pg_temp.err(pg_temp.cmd(4, 'content.create_banner', null, pg_temp.bn('theme', 2026, 'SYNTHETIC x'))),
  'forbidden', 'a plain member cannot create a banner');
select is(pg_temp.err(pg_temp.cmd(3, 'content.save_banner', pg_temp.rev(pg_temp.b1()),
  pg_temp.bn('theme', 2026, 'SYNTHETIC Theme 2026', jsonb_build_object(
    'banner_id', pg_temp.b1(), 'image_asset_id', (select r #>> '{data,asset_id}' from pending_asset),
    'image_rights_id', gen_random_uuid())))),
  'validation_failed|image_asset_id=not_ready,image_rights_id=unknown', 'a pending upload and an unknown record are refused');

-- Banners: publication -----------------------------------------------------------------------------
select is(pg_temp.err(pg_temp.cmd(3, 'content.publish_banner', pg_temp.rev(pg_temp.b1()),
  jsonb_build_object('banner_id', pg_temp.b1()))),
  'validation_failed|image_asset_id=required,image_rights_id=required', 'no image, no rights: not publishable');
select is(pg_temp.err(pg_temp.cmd(3, 'content.save_banner', pg_temp.rev(pg_temp.b1()),
  pg_temp.bn('theme', 2026, 'SYNTHETIC Theme 2026', jsonb_build_object(
    'banner_id', pg_temp.b1(), 'image_asset_id', pg_temp.a1(), 'image_rights_id', pg_temp.r4())))), 'ok',
  'the draft gets its image and an unverified record');
select is(pg_temp.err(pg_temp.cmd(3, 'content.publish_banner', pg_temp.rev(pg_temp.b1()),
  jsonb_build_object('banner_id', pg_temp.b1()))), 'validation_failed|image_rights_id=not_in_force',
  'an unverified rights record cannot clear a publication');
select is(pg_temp.err(pg_temp.cmd(3, 'content.save_banner', pg_temp.rev(pg_temp.b1()),
  pg_temp.bn('theme', 2026, 'SYNTHETIC Theme 2026', jsonb_build_object(
    'banner_id', pg_temp.b1(), 'image_asset_id', pg_temp.a1(), 'image_rights_id', pg_temp.r2())))), 'ok',
  'the draft cites the third-party record');
select is(pg_temp.err(pg_temp.cmd(3, 'content.publish_banner', pg_temp.rev(pg_temp.b1()),
  jsonb_build_object('banner_id', pg_temp.b1()))), 'validation_failed|image_rights_id=source_not_cleared',
  'a third-party source missing from the Q5 fixture cannot be published');
select is(pg_temp.err(pg_temp.cmd(3, 'content.save_banner', pg_temp.rev(pg_temp.b1()),
  pg_temp.bn('theme', 2026, 'SYNTHETIC Theme 2026', jsonb_build_object(
    'banner_id', pg_temp.b1(), 'image_asset_id', pg_temp.a1(), 'image_rights_id', pg_temp.r3())))), 'ok',
  'the draft cites the offline-only record');
select is(pg_temp.err(pg_temp.cmd(3, 'content.publish_banner', pg_temp.rev(pg_temp.b1()),
  jsonb_build_object('banner_id', pg_temp.b1()))), 'validation_failed|image_rights_id=use_not_cleared',
  'a record that does not clear display cannot clear a banner');
select is(pg_temp.err(pg_temp.cmd(3, 'content.save_banner', pg_temp.rev(pg_temp.b1()),
  pg_temp.bn('theme', 2026, 'SYNTHETIC Theme 2026', jsonb_build_object(
    'banner_id', pg_temp.b1(), 'image_asset_id', pg_temp.a1(), 'image_rights_id', pg_temp.r1())))), 'ok',
  'the draft cites the SYNTHETIC church record');
select is(pg_temp.err(pg_temp.cmd(4, 'content.publish_banner', pg_temp.rev(pg_temp.b1()),
  jsonb_build_object('banner_id', pg_temp.b1()))), 'forbidden', 'a plain member cannot publish');
select is(pg_temp.read(null, 'select api.content_public_banners()') -> 'banners', '[]'::jsonb, 'anon sees no draft');
select is(pg_temp.cmd(3, 'content.publish_banner', pg_temp.rev(pg_temp.b1()),
  jsonb_build_object('banner_id', pg_temp.b1())) #>> '{data,state}', 'published', 'Media publishes the theme');
create function pg_temp.path(p_item uuid, p_rev int) returns text language sql as
$$ select 'banner/' || p_item::text || '/r' || p_rev::text || '/image.png' $$;
select is(pg_temp.read(null, 'select api.content_public_banners()') -> 'banners', '[]'::jsonb,
  'until its file is placed in the public bucket, the public read names no banner');
select is((select x ->> 'public_image' from jsonb_array_elements(pg_temp.read(3, 'select api.content_staff_banners()') -> 'banners') x
            where x ->> 'banner_id' = pg_temp.b1()::text), 'waiting', 'editors see its image waiting to be placed');
create temp table plan1 as select pg_temp.read(3, 'select api.content_file_plan()') as r;
select is((select r -> 'place' from plan1),
  jsonb_build_array(jsonb_build_object('public_path', pg_temp.path(pg_temp.b1(), 1),
                                       'draft_path', (select r #>> '{data,draft_path}' from u1),
                                       'media_type', 'image/png')),
  'the sync plan places the live revision''s file under a revision-keyed path');
select is((select (r ->> 'waiting') || '|' || (r ->> 'removals_pending') from plan1), '1|0', 'with its counts');
select pg_temp.obj('content-public', pg_temp.path(pg_temp.b1(), 1), 3000000, 'image/png');
create temp table pub as select pg_temp.read(null, 'select api.content_public_banners()') as r;
select is((select jsonb_array_length(r -> 'banners') from pub), 1, 'once placed, anon reads the theme');
select results_eq($$select k from pub, jsonb_object_keys(r #> '{banners,0}') k order by 1$$,
  $$values ('alt_text'::text), ('banner_id'), ('banner_kind'), ('event_id'), ('image'), ('offline_allowed'),
           ('publication_revision'), ('published_at'), ('rights_revision'), ('subtitle'), ('theme_year'), ('title')$$,
  'the public projection has exactly these keys (no draft, editor or rights detail)');
select is((select r #>> '{banners,0,offline_allowed}' from pub), 'false',
  'display-only rights do not clear offline storage');
select is((select r #> '{banners,0,image}' from pub),
  jsonb_build_object('path', pg_temp.path(pg_temp.b1(), 1), 'media_type', 'image/png', 'width', 1920, 'height', 1080),
  'the image is its public path with type and size');
select is((select (r #>> '{banners,0,publication_revision}') || '|' || (r #>> '{banners,0,rights_revision}') from pub),
  '1|1', 'with the publication and rights revisions');
select is(pg_temp.read(5, 'select api.content_public_banners()'), (select r from pub),
  'a Pending account reads the same projection');
select is((select x ->> 'public_image' from jsonb_array_elements(pg_temp.read(3, 'select api.content_staff_banners()') -> 'banners') x
            where x ->> 'banner_id' = pg_temp.b1()::text), 'shown', 'editors see it shown');

-- A campaign linked to an event --------------------------------------------------------------------
create temp table ev as select pg_temp.cmd(3, 'content.create_event', null, jsonb_build_object(
  'title', 'SYNTHETIC Harvest', 'description', 'SYNTHETIC harvest service.', 'starts_at', pg_temp.iso(pg_temp.at(5)),
  'ends_at', pg_temp.iso(pg_temp.at(5, '12:00')), 'location', 'SYNTHETIC Church grounds')) as r;
create function pg_temp.ev() returns uuid language sql as $$ select (r #>> '{data,event_id}')::uuid from ev $$;
create temp table b2 as select pg_temp.cmd(2, 'content.create_banner', null,
  pg_temp.bn('campaign', null, 'SYNTHETIC Harvest campaign', jsonb_build_object('event_id', pg_temp.ev(), 'subtitle', null))) as r;
create function pg_temp.b2() returns uuid language sql as $$ select (r #>> '{data,banner_id}')::uuid from b2 $$;
create temp table a2 as select pg_temp.ready_asset(2, pg_temp.b2()) as a;
select is(pg_temp.err(pg_temp.cmd(2, 'content.save_banner', pg_temp.rev(pg_temp.b2()),
  pg_temp.bn('campaign', null, 'SYNTHETIC Harvest campaign', jsonb_build_object(
    'banner_id', pg_temp.b2(), 'event_id', pg_temp.ev(), 'subtitle', null,
    'image_asset_id', (select a from a2), 'image_rights_id', pg_temp.r1())))), 'ok', 'a Pastor saves a campaign with its image');
select is(pg_temp.err(pg_temp.cmd(2, 'content.save_banner', pg_temp.rev(pg_temp.b2()),
  pg_temp.bn('campaign', null, 'SYNTHETIC Harvest campaign', jsonb_build_object(
    'banner_id', pg_temp.b2(), 'event_id', pg_temp.ev(), 'image_asset_id', pg_temp.a1(), 'image_rights_id', pg_temp.r1())))),
  'validation_failed|image_asset_id=unknown', 'another banner''s upload cannot be cited');
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_banner', pg_temp.rev(pg_temp.b2()),
  jsonb_build_object('banner_id', pg_temp.b2()))), 'validation_failed|event_id=not_published',
  'a campaign linked to an unpublished event cannot be published');
select is(pg_temp.err(pg_temp.cmd(3, 'content.publish_event', pg_temp.rev(pg_temp.ev()),
  jsonb_build_object('event_id', pg_temp.ev()))), 'ok', 'the event is published');
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_banner', pg_temp.rev(pg_temp.b2()),
  jsonb_build_object('banner_id', pg_temp.b2()))), 'ok', 'then the campaign publishes');
select pg_temp.obj('content-public', pg_temp.path(pg_temp.b2(), 1), 3000000, 'image/png');
select is((select string_agg(x ->> 'banner_kind', ',' order by o)
             from jsonb_array_elements(pg_temp.read(null, 'select api.content_public_banners()') -> 'banners')
                  with ordinality as t(x, o)), 'theme,campaign', 'the theme comes first, then campaigns');
select is((select x ->> 'event_id' from jsonb_array_elements(pg_temp.read(null, 'select api.content_public_banners()') -> 'banners') x
            where x ->> 'banner_kind' = 'campaign'), pg_temp.ev()::text, 'the campaign names its event');
select is(pg_temp.err(pg_temp.cmd(3, 'content.withdraw_event', pg_temp.rev(pg_temp.ev()),
  jsonb_build_object('event_id', pg_temp.ev()))), 'ok', 'the event is withdrawn');
select is((select count(*)::int from jsonb_array_elements(pg_temp.read(null, 'select api.content_public_banners()') -> 'banners') x
            where x ->> 'banner_kind' = 'campaign'), 0, 'its campaign leaves Home with it');
select ok((select r -> 'remove' from (select pg_temp.read(3, 'select api.content_file_plan()') as r) s)
            @> jsonb_build_array(pg_temp.path(pg_temp.b2(), 1)),
  'and its public file goes in the removal plan (the event is not public)');
select is((select x ->> 'public_image' from jsonb_array_elements(pg_temp.read(3, 'select api.content_staff_banners()') -> 'banners') x
            where x ->> 'banner_id' = pg_temp.b2()::text), 'event_not_public', 'editors see why');
select is(pg_temp.err(pg_temp.cmd(3, 'content.publish_event', pg_temp.rev(pg_temp.ev()),
  jsonb_build_object('event_id', pg_temp.ev()))), 'ok', 'the event is published again');

-- Edits, republication and withdrawal --------------------------------------------------------------
select is(pg_temp.err(pg_temp.cmd(3, 'content.save_banner', pg_temp.rev(pg_temp.b1()),
  pg_temp.bn('theme', 2026, 'SYNTHETIC Theme 2026 edited', jsonb_build_object(
    'banner_id', pg_temp.b1(), 'image_asset_id', pg_temp.a1(), 'image_rights_id', pg_temp.r1())))), 'ok',
  'an edit of the live theme opens draft revision 2');
select is((select x ->> 'title' from jsonb_array_elements(pg_temp.read(null, 'select api.content_public_banners()') -> 'banners') x
            where x ->> 'banner_id' = pg_temp.b1()::text), 'SYNTHETIC Theme 2026', 'the published revision stays live');
select throws_ok(format($$update app.content_revision_files set rights_id = null where item_id = %L and revision_no = 1$$, pg_temp.b1()),
  'PCNT1', null, 'a published revision''s files are immutable');
select throws_ok(format($$update app.content_banner_revisions set title = 'x' where item_id = %L and revision_no = 1$$, pg_temp.b1()),
  'PCNT1', null, 'a published banner revision is immutable');
select is(pg_temp.err(pg_temp.cmd(3, 'content.publish_banner', pg_temp.rev(pg_temp.b1()),
  jsonb_build_object('banner_id', pg_temp.b1()))), 'ok', 'the edit is published');
create temp table plan2 as select pg_temp.read(3, 'select api.content_file_plan()') as r;
select is((select (r #>> '{place,0,public_path}') || '|' || (r ->> 'remove') from plan2),
  pg_temp.path(pg_temp.b1(), 2) || '|' || jsonb_build_array(pg_temp.path(pg_temp.b1(), 1))::text,
  'the plan places revision 2 and removes revision 1');
select is(pg_temp.read(null, 'select api.content_public_banners()') #>> '{banners,0,banner_kind}', 'campaign',
  'until the new file is placed the theme is not named');
select pg_temp.obj('content-public', pg_temp.path(pg_temp.b1(), 2), 3000000, 'image/png');
select is((select x ->> 'publication_revision' from jsonb_array_elements(pg_temp.read(null, 'select api.content_public_banners()') -> 'banners') x
            where x ->> 'banner_id' = pg_temp.b1()::text), '2', 'then the new revision is public');
select is((select x ->> 'removals_pending' from (select pg_temp.read(3, 'select api.content_staff_banners()') as x) s),
  '1', 'editors see one public file still to remove');
select is(pg_temp.err(pg_temp.cmd(2, 'content.withdraw_banner', pg_temp.rev(pg_temp.b2()),
  jsonb_build_object('banner_id', pg_temp.b2()))), 'ok', 'the campaign is withdrawn');
select is((select count(*)::int from jsonb_array_elements(pg_temp.read(4, 'select api.content_public_banners()') -> 'banners') x
            where x ->> 'banner_id' = pg_temp.b2()::text), 0, 'a member no longer reads it');
select ok((select r -> 'remove' from (select pg_temp.read(3, 'select api.content_file_plan()') as r) s)
            @> jsonb_build_array(pg_temp.path(pg_temp.b2(), 1)), 'its public file is in the removal plan');
select is(pg_temp.err(pg_temp.cmd(3, 'content.withdraw_rights_record', pg_temp.rev(pg_temp.r1()),
  jsonb_build_object('rights_id', pg_temp.r1()))), 'ok', 'the theme''s rights record is withdrawn');
select is(pg_temp.read(null, 'select api.content_public_banners()') -> 'banners', '[]'::jsonb,
  'a banner whose rights no longer clear leaves Home at once');
select is((select x ->> 'public_image' from jsonb_array_elements(pg_temp.read(3, 'select api.content_staff_banners()') -> 'banners') x
            where x ->> 'banner_id' = pg_temp.b1()::text), 'blocked', 'editors see it blocked');
select ok((select r -> 'remove' from (select pg_temp.read(3, 'select api.content_file_plan()') as r) s)
            @> jsonb_build_array(pg_temp.path(pg_temp.b1(), 2)), 'and its public file goes in the removal plan');
select is(pg_temp.err(pg_temp.cmd(3, 'content.verify_rights_record', pg_temp.rev(pg_temp.r1()),
  jsonb_build_object('rights_id', pg_temp.r1()))), 'ok', 'verifying the record again (its open draft revision 2)');
select is((select x ->> 'rights_revision' from jsonb_array_elements(pg_temp.read(null, 'select api.content_public_banners()') -> 'banners') x
            where x ->> 'banner_id' = pg_temp.b1()::text), '2', 'brings the theme back with rights revision 2');
select is((select x ->> 'offline_allowed' from jsonb_array_elements(pg_temp.read(null, 'select api.content_public_banners()') -> 'banners') x
            where x ->> 'banner_id' = pg_temp.b1()::text), 'true',
  'a newly live rights revision that clears offline use enables the cache');
select is(pg_temp.err(pg_temp.cmd(2, 'content.archive_banner', pg_temp.rev(pg_temp.b2()),
  jsonb_build_object('banner_id', pg_temp.b2()))), 'ok', 'a Pastor archives the campaign');
select is(pg_temp.err(pg_temp.cmd(2, 'content.publish_banner', pg_temp.rev(pg_temp.b2()),
  jsonb_build_object('banner_id', pg_temp.b2()))), 'validation_failed|banner_id=archived', 'an archived banner refuses commands');
select is(pg_temp.err(pg_temp.cmd(2, 'content.begin_asset_upload', null, pg_temp.up(pg_temp.b2()))),
  'validation_failed|item_id=archived', 'and uploads');

-- Reads and replay ---------------------------------------------------------------------------------
select is(pg_temp.read(null, 'select api.content_staff_banners()') #>> '{}',
  '42501|permission denied for function content_staff_banners|', 'anon cannot read the editors'' banners');
select is(pg_temp.read(4, 'select api.content_staff_banners()') #>> '{}', 'PT403|forbidden|not_granted',
  'a plain member cannot read the editors'' banners');
select is(pg_temp.read(4, 'select api.content_staff_rights()') #>> '{}', 'PT403|forbidden|not_granted',
  'nor the rights records');
select is(pg_temp.read(5, 'select api.content_staff_rights()') #>> '{}' like 'PT403%', true,
  'a Pending account is refused too');
select is(pg_temp.read(4, 'select api.content_file_plan()') #>> '{}', 'PT403|forbidden|not_granted',
  'a plain member cannot read the sync plan');
select is(pg_temp.read(null, 'select api.content_file_plan()') #>> '{}',
  '42501|permission denied for function content_file_plan|', 'nor can anon');
select is(pg_temp.read(4, format('select api.content_asset_preview(%L::uuid)', pg_temp.a1())) #>> '{}',
  'PT403|forbidden|not_granted', 'a plain member cannot preview a draft file');
select is(pg_temp.read(null, format('select api.content_asset_preview(%L::uuid)', pg_temp.a1())) #>> '{}',
  '42501|permission denied for function content_asset_preview|', 'nor can anon');
select is(pg_temp.read(1, format('select api.content_asset_preview(%L::uuid)', pg_temp.a1())),
  jsonb_build_object('asset', jsonb_build_object('draft_path', (select r #>> '{data,draft_path}' from u1),
                                                 'media_type', 'image/png')),
  'an Admin previews the draft object');
select is(pg_temp.read(3, format('select api.content_asset_preview(%L::uuid)', gen_random_uuid())),
  '{"asset": null}'::jsonb, 'an unknown file previews as null');
create temp table staff as select pg_temp.read(3, 'select api.content_staff_banners()') as r;
select is((select x #>> '{live,rights,display}' from staff, jsonb_array_elements(r -> 'banners') x
            where x ->> 'banner_id' = pg_temp.b1()::text), null, 'the editors read whether the rights clear display');
select is((select (x #> '{live,image}'::text[]) - 'asset_id'::text from staff, jsonb_array_elements(r -> 'banners') x
            where x ->> 'banner_id' = pg_temp.b1()::text),
  '{"media_type": "image/png", "byte_size": 3000000, "width": 1920, "height": 1080}'::jsonb, 'and the image measures');
select is((select x #>> '{draft,event_title}' from staff, jsonb_array_elements(r -> 'banners') x
            where x ->> 'banner_id' = pg_temp.b2()::text), null, 'an archived campaign keeps no draft');
select is((select x #>> '{live,event_title}' from staff, jsonb_array_elements(r -> 'banners') x
            where x ->> 'banner_id' = pg_temp.b2()::text), 'SYNTHETIC Harvest', 'and names its event for editors');
create temp table rep as select gen_random_uuid() as id;
select is(pg_temp.err(pg_temp.cmd(3, 'content.begin_asset_upload', null, pg_temp.up(pg_temp.b1()), (select id from rep))),
  'ok', 'an upload begins');
select is(pg_temp.cmd(3, 'content.begin_asset_upload', null, pg_temp.up(pg_temp.b1()), (select id from rep)) #>> '{data,item_id}',
  pg_temp.b1()::text, 'and its replay returns the stored result (the item is the receipt aggregate)');

-- Deletion -----------------------------------------------------------------------------------------
create temp table b3 as select pg_temp.cmd(6, 'content.create_banner', null,
  pg_temp.bn('theme', 2027, 'SYNTHETIC Theme 2027')) as r;
create temp table rb as select pg_temp.cmd(6, 'content.create_rights_record', null,
  pg_temp.rights('SYNTHETIC by B', 'synthetic', true, false)) as r;
select pg_temp.ready_asset(6, (select (r #>> '{data,banner_id}')::uuid from b3));
select is((app.content_erase_member(jsonb_build_object('phase', 'check', 'member_id', pg_temp.mid(6),
             'account_id', pg_temp.u(6))) ->> 'remaining')::int > 0, true, 'before erasure B''s references are counted');
select is(app.content_erase_member(jsonb_build_object('phase', 'erase', 'member_id', pg_temp.mid(6),
             'account_id', pg_temp.u(6))) ->> 'remaining', '0', 'erasure leaves no reference to B');
select is((select x #>> '{draft,saved_by}' from jsonb_array_elements(pg_temp.read(3, 'select api.content_staff_banners()') -> 'banners') x
            where x ->> 'banner_id' = (select r #>> '{data,banner_id}' from b3)), 'Former member',
  'the editors read B as a former member');
select is((select count(*)::int from app.content_assets where uploaded_by_member = pg_temp.mid(6)), 0,
  'B''s upload attribution is anonymised');

-- Production: Q5 closed until Israel approves it ---------------------------------------------------
select lives_ok($$select app.platform_set_environment('production', 'pgtap content banners')$$, 'marked production');
select is(app.content_rights_clear(pg_temp.r1(), 'display'), null,
  'a verified church-owned record still clears its use in production with Q5 closed');
select is(app.content_rights_clear(pg_temp.r2(), 'display'), 'source_not_cleared',
  'a third-party source still needs Q5 approval in production');
select is(jsonb_array_length(app.content_public_banners() -> 'banners'), 1,
  'the public read still names the church-owned banner when Q5 is closed');

select * from finish();
rollback;
