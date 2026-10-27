-- Story 6.10: a sermon's public Facebook video or live link. All fixtures are SYNTHETIC; UK
-- phones are fictional Ofcom numbers (+44 7700 900111-900114, the entry's block; rolled back
-- with the test). Facebook ids and page names are invented.
begin;
select no_plan();

create function pg_temp.u(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-8000-00000006a0' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.s(n int) returns uuid language sql as
$$ select ('00000000-0000-4000-9000-00000006a0' || lpad(n::text, 2, '0'))::uuid $$;
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
create function pg_temp.anon(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  set local role anon;
  execute p_sql into r;
  reset role;
  return r;
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
    'scripture_reference', 'Psalm 23:1', 'notes', '# SYNTHETIC notes' || chr(10) || chr(10) || 'Read **with faith**.',
    'series_id', null, 'youtube_video_id', null, 'facebook_video_url', null, 'video_rights_id', null) || p_extra
$$;
create function pg_temp.fb(p text) returns text language sql as $$
  select coalesce(t.error, 'ok') || '|' || coalesce(t.value, '') from app.content_sermon_facebook_url(to_jsonb(p)) t
$$;

insert into auth.users(id,aud,role,phone,phone_confirmed_at)
select pg_temp.u(n), 'authenticated', 'authenticated', '447700900' || (110+n)::text, now()
from generate_series(1,4) n;
insert into auth.sessions(id,user_id,aal,created_at)
select pg_temp.s(n),pg_temp.u(n),'aal1',clock_timestamp()-interval '1 hour' from generate_series(1,4) n;
insert into auth.mfa_amr_claims(id,session_id,created_at,updated_at,authentication_method)
select gen_random_uuid(),pg_temp.s(n),now(),now(),'password' from generate_series(1,4) n;
select app.platform_set_environment('local','pgtap SYNTHETIC sermon facebook');
create temp table m(n int,member_id uuid);
insert into m select n,app.identity_seed_synthetic_link(pg_temp.u(n),'SYNTHETIC Facebook Sermon '||n,'pgtap sermon facebook')
from generate_series(1,4) n;
create function pg_temp.mid(n int) returns uuid language sql as $$ select member_id from m where m.n=$1 $$;
select app.identity_bootstrap_admin(pg_temp.mid(1),'israel');
insert into app.identity_grants(member_id,role,granted_by_operator)
values(pg_temp.mid(2),'media','israel'),(pg_temp.mid(4),'pastor','israel');

-- Schema
select has_column('app','content_sermon_revisions','facebook_video_url','sermon revisions carry a Facebook link');
select col_is_null('app','content_sermon_revisions','facebook_video_url','the Facebook link is optional');
select table_privs_are('app','content_sermon_revisions',r,array[]::text[],r||' still cannot touch sermon revisions')
from unnest(array['anon','authenticated','service_role']) r;
select ok(not has_function_privilege(r,'app.content_sermon_facebook_url(jsonb)','execute'),
  r||' cannot call the Facebook validator') from unnest(array['anon','authenticated','service_role']) r;

-- The validator: exact allowlist, normalised output
select is(pg_temp.fb(i), o, 'accepted and normalised: '||i) from (values
  ('https://www.facebook.com/SyntheticChurch/videos/1234567890123456/', 'ok|https://www.facebook.com/SyntheticChurch/videos/1234567890123456/'),
  ('https://facebook.com/SyntheticChurch/videos/1234567890123456', 'ok|https://www.facebook.com/SyntheticChurch/videos/1234567890123456/'),
  ('https://m.facebook.com/synthetic.church/videos/1234567890?mibextid=abc123', 'ok|https://www.facebook.com/synthetic.church/videos/1234567890/'),
  ('https://web.facebook.com/Synthetic-Church-1234/videos/987654321/#top', 'ok|https://www.facebook.com/Synthetic-Church-1234/videos/987654321/'),
  ('https://WWW.Facebook.com/SyntheticChurch/videos/1234567890/', 'ok|https://www.facebook.com/SyntheticChurch/videos/1234567890/'),
  ('https://www.facebook.com/watch?v=1234567890123456', 'ok|https://www.facebook.com/watch/?v=1234567890123456'),
  ('https://www.facebook.com/watch/?v=1234567890123456&ref=sharing', 'ok|https://www.facebook.com/watch/?v=1234567890123456'),
  ('https://www.facebook.com/watch/live/?ref=watch_permalink&v=1234567890123456', 'ok|https://www.facebook.com/watch/?v=1234567890123456'),
  ('  https://fb.watch/aBc_12-XyZ/  ', 'ok|https://fb.watch/aBc_12-XyZ/'),
  ('https://fb.watch/aBc12?mibextid=x', 'ok|https://fb.watch/aBc12/')
) v(i, o);
select is(pg_temp.fb(i), o, 'refused: '||i) from (values
  ('https://www.youtube.com/watch?v=abcdefghijk', 'not_facebook|'),
  ('https://example.org/SyntheticChurch/videos/1234567890/', 'not_facebook|'),
  ('https://facebook.com.evil.test/SyntheticChurch/videos/1234567890/', 'not_facebook|'),
  ('https://evilfacebook.com/SyntheticChurch/videos/1234567890/', 'not_facebook|'),
  ('https://l.facebook.com/l.php?u=https%3A%2F%2Fevil.test', 'not_facebook|'),
  ('http://www.facebook.com/SyntheticChurch/videos/1234567890/', 'invalid|'),
  ('https://user@www.facebook.com/SyntheticChurch/videos/1234567890/', 'invalid|'),
  ('https://www.facebook.com:443/SyntheticChurch/videos/1234567890/', 'invalid|'),
  ('https://www.facebook.com/SyntheticChurch/videos/12ab34/', 'invalid|'),
  ('https://www.facebook.com/SyntheticChurch/videos/', 'invalid|'),
  ('https://www.facebook.com/SyntheticChurch/posts/1234567890/', 'invalid|'),
  ('https://www.facebook.com/SyntheticChurch/videos/some-title/1234567890/', 'invalid|'),
  ('https://www.facebook.com/share/v/AbCdEf123/', 'invalid|'),
  ('https://www.facebook.com/reel/1234567890123', 'invalid|'),
  ('https://www.facebook.com/plugins/video.php?href=x', 'invalid|'),
  ('https://www.facebook.com/watch/?v=123&v=456789', 'invalid|'),
  ('https://www.facebook.com/watch/?video=1234567890', 'invalid|'),
  ('https://www.facebook.com/watch/?v=12ab', 'invalid|'),
  ('https://www.facebook.com/%53ynthetic/videos/1234567890/', 'invalid|'),
  ('https://www.facebook.com/Synthetic Church/videos/1234567890/', 'invalid|'),
  ('https://www.facebook.com/SyntheticChurch/videos/1234567890/"onload="x', 'invalid|'),
  ('javascript:alert(1)', 'invalid|'),
  ('https://fb.watch/ab/', 'invalid|'),
  ('https://fb.watch/abcde/more/', 'invalid|'),
  ('https://www.facebook.com/SyntheticChurch/live', 'not_embeddable|'),
  ('https://www.facebook.com/SyntheticChurch/live/', 'not_embeddable|'),
  ('https://www.facebook.com/SyntheticChurch/live_videos/', 'not_embeddable|')
) v(i, o);
select is(pg_temp.fb('https://www.facebook.com/SyntheticChurch/videos/' || repeat('1', 490)), 'too_long|', 'over 500 characters is too long');
select is((select coalesce(t.error,'ok')||'|'||coalesce(t.value,'') from app.content_sermon_facebook_url('123'::jsonb) t), 'invalid|', 'a non-string is invalid');
select is((select coalesce(t.error,'ok')||'|'||coalesce(t.value,'') from app.content_sermon_facebook_url('null'::jsonb) t), 'ok|', 'null means no Facebook link');
select is(pg_temp.fb('   '), 'ok|', 'a blank link means no Facebook link');
select is(pg_temp.fb(split_part(pg_temp.fb(i), '|', 2)), pg_temp.fb(i), 'normalisation is idempotent: '||i)
from unnest(array['https://m.facebook.com/synthetic.church/videos/1234567890?x=1',
  'https://www.facebook.com/watch/live/?v=1234567890123456', 'https://fb.watch/aBc12?x=1']) i;

-- Commands
create temp table fb1 as select pg_temp.cmd(2,'content.create_sermon',null,pg_temp.sermon('SYNTHETIC Facebook recording',
  '{"facebook_video_url":"https://m.facebook.com/SyntheticChurch/videos/1234567890123456/?mibextid=abc"}')) r;
create function pg_temp.fb1() returns uuid language sql as $$ select (r#>>'{data,sermon_id}')::uuid from fb1 $$;
select is(pg_temp.err((select r from fb1)),'ok','Media saves a sermon draft with a pasted Facebook link');
select is((select facebook_video_url from app.content_sermon_revisions where item_id=pg_temp.fb1()),
  'https://www.facebook.com/SyntheticChurch/videos/1234567890123456/','the link is stored normalised');
select is(app.content_staff_sermon_json(pg_temp.fb1())#>>'{draft,facebook_video_url}',
  'https://www.facebook.com/SyntheticChurch/videos/1234567890123456/','editors read the stored link');
select is(pg_temp.err(pg_temp.cmd(2,'content.create_sermon',null,pg_temp.sermon('SYNTHETIC Bad',
  '{"youtube_video_id":"abcdefghijk","facebook_video_url":"https://fb.watch/aBc12/"}'))),
  'validation_failed|facebook_video_url=one_source','a sermon has at most one video source');
select is(pg_temp.err(pg_temp.cmd(2,'content.create_sermon',null,pg_temp.sermon('SYNTHETIC Bad',
  '{"facebook_video_url":"https://example.org/SyntheticChurch/videos/1234567890/"}'))),
  'validation_failed|facebook_video_url=not_facebook','a non-Facebook link is refused');
select is(pg_temp.err(pg_temp.cmd(2,'content.create_sermon',null,pg_temp.sermon('SYNTHETIC Bad',
  '{"facebook_video_url":"https://www.facebook.com/SyntheticChurch/videos/abc/"}'))),
  'validation_failed|facebook_video_url=invalid','a malformed Facebook link is refused');
select is(pg_temp.err(pg_temp.cmd(2,'content.create_sermon',null,pg_temp.sermon('SYNTHETIC Bad',
  '{"facebook_video_url":"https://www.facebook.com/SyntheticChurch/live/"}'))),
  'validation_failed|facebook_video_url=not_embeddable','a page live address is refused as not embeddable');
select is(pg_temp.err(pg_temp.cmd(2,'content.save_sermon',pg_temp.rev(pg_temp.fb1()),pg_temp.sermon('SYNTHETIC Bad',
  jsonb_build_object('sermon_id',pg_temp.fb1(),'youtube_video_id','abcdefghijk',
    'facebook_video_url','https://fb.watch/aBc12/')))),
  'validation_failed|facebook_video_url=one_source','saving keeps the one-source rule');
select is(pg_temp.err(pg_temp.cmd(3,'content.create_sermon',null,pg_temp.sermon('SYNTHETIC Member',
  '{"facebook_video_url":"https://fb.watch/aBc12/"}'))),'forbidden','a plain member cannot save a sermon');
select is(pg_temp.err(pg_temp.cmd(2,'content.publish_sermon',pg_temp.rev(pg_temp.fb1()),jsonb_build_object('sermon_id',pg_temp.fb1()))),
  'validation_failed|video_rights_id=required','a Facebook video needs rights before publication');

create temp table ri as select pg_temp.cmd(2,'content.create_rights_record',null,
  '{"label":"SYNTHETIC Facebook sermon rights","source_key":"synthetic-facebook-pgtap","holder":"SYNTHETIC Church","basis":"church_owned",
  "clears_display":true,"clears_offline":false,"clears_audio":false,"evidence":"SYNTHETIC church recording"}') r;
create function pg_temp.ri() returns uuid language sql as $$ select (r#>>'{data,rights_id}')::uuid from ri $$;
select is(pg_temp.err(pg_temp.cmd(2,'content.verify_rights_record',1,jsonb_build_object('rights_id',pg_temp.ri()))),'ok',
  'church-owned synthetic rights verified without a policy approval');
select is(pg_temp.err(pg_temp.cmd(2,'content.save_sermon',pg_temp.rev(pg_temp.fb1()),pg_temp.sermon('SYNTHETIC Facebook recording',
  jsonb_build_object('sermon_id',pg_temp.fb1(),'facebook_video_url','https://www.facebook.com/SyntheticChurch/videos/1234567890123456/',
    'video_rights_id',pg_temp.ri())))),'ok','rights attached to the Facebook draft');
select is(pg_temp.err(pg_temp.cmd(2,'content.publish_sermon',pg_temp.rev(pg_temp.fb1()),jsonb_build_object('sermon_id',pg_temp.fb1()))),
  'ok','Media publishes the Facebook sermon');

create temp table fb2 as select pg_temp.cmd(4,'content.create_sermon',null,pg_temp.sermon('SYNTHETIC Facebook live',
  jsonb_build_object('facebook_video_url','https://www.facebook.com/watch/live/?ref=watch_permalink&v=2345678901234567',
    'video_rights_id',pg_temp.ri()))) r;
create function pg_temp.fb2() returns uuid language sql as $$ select (r#>>'{data,sermon_id}')::uuid from fb2 $$;
select is(pg_temp.err(pg_temp.cmd(4,'content.publish_sermon',1,jsonb_build_object('sermon_id',pg_temp.fb2()))),
  'ok','Pastor publishes a sermon with a Facebook live link');

-- Public reads
select is(pg_temp.anon(format('select api.content_public_sermon(%L)',pg_temp.fb1()))#>>'{sermon,facebook_video_url}',
  'https://www.facebook.com/SyntheticChurch/videos/1234567890123456/','a signed-out caller reads the cleared Facebook link');
select is(pg_temp.anon(format('select api.content_public_sermon(%L)',pg_temp.fb1()))#>'{sermon,youtube_video_id}',
  'null'::jsonb,'the Facebook sermon has no YouTube id');
select is(pg_temp.anon(format('select api.content_public_sermon(%L)',pg_temp.fb1()))#>>'{sermon,rights_revision}',
  '1','the playable link cites its rights revision');
select is(pg_temp.anon(format('select api.content_public_sermon(%L)',pg_temp.fb2()))#>>'{sermon,facebook_video_url}',
  'https://www.facebook.com/watch/?v=2345678901234567','the live link is public in its normal form');
select is((select count(*)::int from jsonb_array_elements(pg_temp.anon('select api.content_public_sermons()')->'sermons') e
  where e->>'sermon_id' in (pg_temp.fb1()::text, pg_temp.fb2()::text) and e->>'facebook_video_url' is not null),
  2,'the canonical catalog lists both Facebook sermons as playable');
select results_eq($$select k from jsonb_object_keys(app.content_public_sermon_json(pg_temp.fb1())) k order by 1$$,
  $$select unnest(array['facebook_video_url','notes','offline_allowed','publication_revision','published_at','rights_revision',
    'scripture_reference','series','sermon_date','sermon_id','speaker','title','youtube_video_id']) order by 1$$,
  'the public sermon has exactly its public fields');

-- Storage rules
select throws_ok(format($$update app.content_sermon_revisions set facebook_video_url='https://fb.watch/zzzzz/' where item_id=%L$$,pg_temp.fb1()),
  'PCNT1',null,'a published Facebook link is immutable');
select throws_ok(format($$insert into app.content_sermon_revisions(item_id,revision_no,title,youtube_video_id,facebook_video_url,saved_by_member,saved_by_account)
  values (%L,99,'SYNTHETIC x','abcdefghijk','https://fb.watch/aBc12/',%L,%L)$$,pg_temp.fb1(),pg_temp.mid(2),pg_temp.u(2)),
  '23514',null,'storage refuses two video sources');
select throws_ok(format($$insert into app.content_sermon_revisions(item_id,revision_no,title,facebook_video_url,saved_by_member,saved_by_account)
  values (%L,99,'SYNTHETIC x','https://m.facebook.com/SyntheticChurch/videos/1234567890/',%L,%L)$$,pg_temp.fb1(),pg_temp.mid(2),pg_temp.u(2)),
  '23514',null,'storage keeps only the normal form');

-- Withdrawn clearance hides the video and keeps the notes
select is(pg_temp.err(pg_temp.cmd(1,'content.withdraw_rights_record',pg_temp.rev(pg_temp.ri()),jsonb_build_object('rights_id',pg_temp.ri()))),
  'ok','Admin withdraws the video clearance');
select is(app.content_public_sermon_json(pg_temp.fb1())->'facebook_video_url','null'::jsonb,'withdrawn clearance removes the Facebook link');
select is(app.content_public_sermon_json(pg_temp.fb1())->'rights_revision','null'::jsonb,'a hidden video has no rights revision');
select is(app.content_public_sermon_json(pg_temp.fb1())->>'notes',pg_temp.sermon('x')->>'notes','the notes stay readable');
select is(app.content_staff_sermon_json(pg_temp.fb1())#>>'{live,video_rights,display}','not_in_force',
  'editors see why the video is hidden');

select is((select count(*)::int from app.contract_boundary_violations()),0,'no module boundary violation');
select is((select count(*)::int from app.contract_unowned_objects()),0,'no unowned object');
select * from finish();
rollback;
