-- Story F3: 30-day private upload retention through the purpose-separated system commands.
-- The Edge and Storage API path is exercised by tools/identity-e2e/content-retention.mjs.
begin;
select plan(22);

create function pg_temp.token(p_fill text) returns text language sql as $$
  select 'sysc_local_' || repeat(p_fill, 43)
$$;
create function pg_temp.digest(p_token text) returns text language sql as $$
  select encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
$$;
create function pg_temp.sys(p_fill text, p_command text, p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql as $$
declare
  r jsonb;
begin
  perform set_config('request.headers', jsonb_build_object('x-system-credential', pg_temp.token(p_fill))::text, true);
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  set local role anon;
  r := api.system_command(jsonb_build_object('version', 1, 'command', p_command,
    'request_id', gen_random_uuid(), 'payload', p_payload));
  reset role;
  return r;
end;
$$;
create function pg_temp.claim(p_fill text, p_claim_id uuid, p_limit integer default 25)
returns jsonb language sql as $$
  select pg_temp.sys(p_fill, 'content.asset_retention_claim',
    jsonb_build_object('claim_id', p_claim_id, 'limit', p_limit))
$$;
create function pg_temp.finalize(p_fill text, p_claim_id uuid, p_asset_ids uuid[])
returns jsonb language sql as $$
  select pg_temp.sys(p_fill, 'content.asset_retention_finalize',
    jsonb_build_object('claim_id', p_claim_id, 'asset_ids', to_jsonb(p_asset_ids)))
$$;
create function pg_temp.attach_result(p_asset_id uuid) returns text language plpgsql as $$
begin
  perform app.content_file_attach('00000000-0000-4000-8000-00000006f301', 1, 'image',
                                  'banner_image', p_asset_id, null);
  return 'attached';
exception when sqlstate 'PCMD1' then
  return 'refused';
end;
$$;

select app.platform_set_environment('local', 'pgtap content asset retention');
create temporary table t_ids (purpose text primary key, principal_id uuid, credential_id uuid);
insert into t_ids (purpose, principal_id) values
  ('retention', app.sys_create_principal('content-retention-test', 'content_asset_retention', 'israel')),
  ('probe', app.sys_create_principal('content-retention-wrong-purpose', 'synthetic_probe', 'israel'));
update t_ids t set credential_id = (app.sys_register_credential(t.principal_id,
  pg_temp.digest(pg_temp.token(case t.purpose when 'retention' then 'A' else 'B' end)),
  'pgtap content retention', interval '2 hours', 'israel') ->> 'credential_id')::uuid;

select has_column('app', 'content_assets', 'retention_claim_id', 'assets store the current cleanup claim');
select has_column('app', 'content_assets', 'retention_claimed_at', 'assets store claim time for the 30-minute retry');
select ok(not exists (
  select 1 from unnest(array['anon', 'authenticated', 'service_role']) r
   where has_table_privilege(r, 'app.content_assets', 'SELECT')
      or has_table_privilege(r, 'app.content_assets', 'UPDATE')
      or has_table_privilege(r, 'app.content_assets', 'DELETE')),
  'no client role can inspect, claim or delete Content assets');
select results_eq(
  $$select command::text || ':' || purpose from app.sys_command_kinds
     where command like 'content.asset_retention_%' order by command$$,
  $$values ('content.asset_retention_claim:content_asset_retention'::text),
           ('content.asset_retention_finalize:content_asset_retention'::text)$$,
  'the two cleanup commands have their own system purpose');
select is((select count(*)::integer from app.sys_principal_commands pc
            join t_ids t on t.principal_id = pc.principal_id where t.purpose = 'retention'),
          2, 'a retention principal receives only its two purpose commands');
select is(pg_temp.sys('B', 'content.asset_retention_claim',
          jsonb_build_object('claim_id', gen_random_uuid(), 'limit', 1)) ->> 'code',
          'forbidden', 'a principal of another purpose cannot claim Content assets');
select is(pg_temp.sys('C', 'content.asset_retention_claim',
          jsonb_build_object('claim_id', gen_random_uuid(), 'limit', 1)) ->> 'code',
          'unauthenticated', 'an unregistered Content credential cannot claim assets');

create temporary table t_asset_ids (n integer primary key, asset_id uuid unique);
create temporary table t_claim_results (label text primary key, result jsonb not null);
insert into app.content_items (item_id, kind, draft_revision_no, last_revision_no,
                               created_by_member, created_by_account)
values ('00000000-0000-4000-8000-00000006f301', 'banner', 1, 1,
        '00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000000');
insert into t_asset_ids select n, gen_random_uuid() from generate_series(1, 30) n;
insert into app.content_assets (asset_id, item_id, purpose, state, media_type, byte_size, width, height,
                                sha256, draft_path, uploaded_by_member, uploaded_by_account,
                                created_at, ready_at, retention_claim_id, retention_claimed_at)
select x.asset_id, '00000000-0000-4000-8000-00000006f301', 'banner_image',
       case when x.n = 1 then 'pending' else 'ready' end,
       'image/png', 100, 960, 540, repeat('a', 64), x.asset_id::text || '.png',
       '00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000000',
       case when x.n = 2 then now() - interval '29 days'
            else now() - interval '31 days' + x.n * interval '1 second' end,
       case when x.n = 1 then null else now() - interval '31 days' end,
       case when x.n = 4 then '00000000-0000-4000-8000-00000006f399'::uuid end,
       case when x.n = 4 then now() end
  from t_asset_ids x;
insert into app.content_revision_files (item_id, revision_no, slot, purpose, asset_id)
select '00000000-0000-4000-8000-00000006f301', 1, 'image', 'banner_image', asset_id
  from t_asset_ids where n = 3;
insert into storage.objects (bucket_id, name, metadata)
select 'content-drafts', a.draft_path, '{"size": "100", "mimetype": "image/png"}'::jsonb
  from app.content_assets a join t_asset_ids x using (asset_id) where x.n = 1;

insert into t_claim_results values ('first', pg_temp.claim('A', '00000000-0000-4000-8000-00000006f310', 25));
insert into t_claim_results values ('live_retry', pg_temp.claim('A', '00000000-0000-4000-8000-00000006f311', 25));
select is((select (result #>> '{data,claimed}')::integer from t_claim_results where label = 'first'),
  25, 'a cleanup claim is bounded to at most 25 rows');
select is((select count(*)::integer from t_claim_results r,
            jsonb_array_elements(r.result -> '{data,assets}') a
            where r.label = 'live_retry' and a ->> 'asset_id' =
                  (select asset_id::text from t_asset_ids where n = 5)),
  0, 'a failed asset stays claimed until its 30-minute lease expires');
select is((select count(*)::integer from app.content_assets a join t_asset_ids x using (asset_id)
            where x.n = 2 and a.retention_claim_id is null),
          1, 'an upload younger than 30 days remains unclaimed');
select is((select count(*)::integer from app.content_assets a join t_asset_ids x using (asset_id)
            where x.n = 3 and a.retention_claim_id is null),
          1, 'an asset referenced by a revision remains unclaimed');
select is((select count(*)::integer from app.content_assets a join t_asset_ids x using (asset_id)
            where x.n = 4 and a.retention_claim_id = '00000000-0000-4000-8000-00000006f399'),
          1, 'a live claim is not worked a second time');
select is((select count(*)::integer from app.content_assets a join t_asset_ids x using (asset_id)
            where x.n = 1 and a.retention_claim_id = '00000000-0000-4000-8000-00000006f310'),
          1, 'an old pending upload with no revision reference can be claimed');
select is(app.content_asset_error((select asset_id from t_asset_ids where n = 5),
          '00000000-0000-4000-8000-00000006f301', 'banner_image'),
          'retention_claimed', 'asset validation identifies a cleanup-claimed upload');
select is(pg_temp.attach_result((select asset_id from t_asset_ids where n = 5)),
          'refused', 'the locked attachment path refuses a cleanup-claimed upload');

select is((pg_temp.finalize('A', '00000000-0000-4000-8000-00000006f310',
          array[(select asset_id from t_asset_ids where n = 1)] ) #>> '{data,deleted}')::integer,
          1, 'metadata is finalized only for an ID in the current claim');
select is((select count(*)::integer from app.content_assets a join t_asset_ids x using (asset_id) where x.n = 1),
          0, 'successful finalization removes the metadata row');
select is((select count(*)::integer from storage.objects o
            where o.bucket_id = 'content-drafts'
              and o.name = (select asset_id::text || '.png' from t_asset_ids where n = 1)),
          1, 'SQL finalization leaves Storage bytes untouched');

-- n=5 was in the first claim but is deliberately not finalized, as if Storage failed.
update app.content_assets a set retention_claimed_at = now() - interval '31 minutes'
  from t_asset_ids x where a.asset_id = x.asset_id and x.n = 5;
insert into t_claim_results values ('expired_retry',
  pg_temp.claim('A', '00000000-0000-4000-8000-00000006f312', 25));
select is((select (result #>> '{data,claimed}')::integer from t_claim_results where label = 'expired_retry'),
  1,
  'a failed deletion becomes claimable after its 30-minute lease expires');
select is((pg_temp.finalize('A', '00000000-0000-4000-8000-00000006f310',
          array[(select asset_id from t_asset_ids where n = 5)] ) #>> '{data,deleted}')::integer,
          0, 'a stale claim cannot finalize an asset claimed by a later run');
select is((pg_temp.finalize('A', '00000000-0000-4000-8000-00000006f312',
          array[(select asset_id from t_asset_ids where n = 5)] ) #>> '{data,deleted}')::integer,
          1, 'the retry can finalize the asset under its current claim');
select is((select count(*)::integer from app.content_assets a join t_asset_ids x using (asset_id)
            where x.n in (2, 3, 4)), 3, 'recent, referenced and previously claimed metadata remains');

select * from finish();
rollback;
