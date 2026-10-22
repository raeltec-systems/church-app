-- Retain only private Content uploads that no revision uses (story F3; AD-2, AD-13, AD-19).
--
-- The existing notification scheduler starts the Edge worker. A separate system purpose lets
-- content-assets claim old assets, delete bytes through the Storage API, then remove metadata.
-- Storage bytes are never deleted by SQL. Attach and preview refuse an asset while a cleanup
-- claim exists. A failed or interrupted delete remains claimed for 30 minutes, then is retried.
--
-- A reference from any revision, including a draft or historical revision, keeps an asset.

alter table app.content_assets
  add column retention_claim_id uuid,
  add column retention_claimed_at timestamptz,
  add constraint content_assets_retention_claim_pair
    check ((retention_claim_id is null) = (retention_claimed_at is null));

comment on column app.content_assets.retention_claim_id is
  'Story F3: the system cleanup claim that may remove this private upload after Storage succeeds.';
comment on column app.content_assets.retention_claimed_at is
  'Story F3: claim time; an abandoned or failed delete is retryable after 30 minutes.';

-- A cleanup-claimed asset cannot be attached or previewed while the Storage delete is pending.
create or replace function app.content_asset_error(p_asset_id uuid, p_item_id uuid, p_purpose text)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_asset_id is null then null
    when not exists (select 1 from app.content_assets a
                      where a.asset_id = p_asset_id and a.item_id = p_item_id
                        and a.purpose = p_purpose) then 'unknown'
    when exists (select 1 from app.content_assets a
                  where a.asset_id = p_asset_id and a.retention_claim_id is not null) then 'retention_claimed'
    when not exists (select 1 from app.content_assets a
                      where a.asset_id = p_asset_id and a.state = 'ready') then 'not_ready'
  end;
$$;

create or replace function app.content_file_attach(p_item_id uuid, p_revision_no integer, p_slot text,
                                                    p_purpose text, p_asset_id uuid, p_rights_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_asset app.content_assets;
begin
  if p_asset_id is not null then
    select a.* into v_asset from app.content_assets a
     where a.asset_id = p_asset_id and a.item_id = p_item_id and a.purpose = p_purpose
       for update;
    if not found then
      perform app.cmd_fail('validation_failed', '{"image_asset_id": "unknown"}');
    end if;
    if v_asset.retention_claim_id is not null then
      perform app.cmd_fail('validation_failed', '{"image_asset_id": "retention_claimed"}');
    end if;
    if v_asset.state <> 'ready' then
      perform app.cmd_fail('validation_failed', '{"image_asset_id": "not_ready"}');
    end if;
  end if;
  insert into app.content_revision_files as f (item_id, revision_no, slot, purpose, asset_id, rights_id)
  values (p_item_id, p_revision_no, p_slot, p_purpose, p_asset_id, p_rights_id)
  on conflict (item_id, revision_no, slot) do update
     set purpose = excluded.purpose,
         asset_id = excluded.asset_id,
         rights_id = excluded.rights_id,
         updated_at = now();
end;
$$;

create or replace function app.content_asset_complete(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_id uuid;
  v_asset app.content_assets;
  v_item app.content_items;
  v_meta jsonb;
begin
  v_id := app.content_lifecycle_id(p_payload, 'asset_id');
  select a.* into v_asset from app.content_assets a where a.asset_id = v_id;
  if not found then
    perform app.cmd_fail('validation_failed', '{"asset_id": "unknown"}');
  end if;
  select i.* into v_item from app.content_items i where i.item_id = v_asset.item_id for share;
  select a.* into v_actor from app.content_command_actor(p_actor, v_item.kind) a;
  select a.* into v_asset from app.content_assets a where a.asset_id = v_id for update;
  if v_asset.retention_claim_id is not null then
    perform app.cmd_fail('validation_failed', '{"asset_id": "retention_claimed"}');
  end if;
  if v_asset.state = 'pending' then
    select o.metadata into v_meta from storage.objects o
     where o.bucket_id = 'content-drafts' and o.name = v_asset.draft_path;
    if not found then
      perform app.cmd_fail('validation_failed', '{"asset_id": "not_uploaded"}');
    end if;
    if coalesce(v_meta ->> 'size', '') !~ '^[0-9]{1,12}$'
       or (v_meta ->> 'size')::bigint <> v_asset.byte_size
       or (v_meta ->> 'mimetype') is distinct from v_asset.media_type then
      perform app.cmd_fail('validation_failed', '{"asset_id": "mismatch"}');
    end if;
    update app.content_assets a set state = 'ready', ready_at = now() where a.asset_id = v_id;
  end if;
  return jsonb_build_object(
    'aggregate_type', 'content_item',
    'aggregate_id', v_item.item_id,
    'revision', v_item.revision,
    'data', jsonb_build_object('asset_id', v_id, 'item_id', v_item.item_id, 'state', 'ready',
                               'media_type', v_asset.media_type, 'byte_size', v_asset.byte_size,
                               'width', v_asset.width, 'height', v_asset.height));
end;
$$;

create or replace function app.content_asset_preview(p_asset_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_editor record;
  v_result jsonb;
begin
  select e.* into v_editor from app.content_require_editor('asset') e;
  select jsonb_build_object('draft_path', a.draft_path, 'media_type', a.media_type)
    into v_result
    from app.content_assets a
    join app.content_items i on i.item_id = a.item_id
   where a.asset_id = p_asset_id and a.state = 'ready' and a.retention_claim_id is null
     and app.content_editor_capacity(v_editor.member_id, i.kind) is not null;
  return jsonb_build_object('asset', v_result);
end;
$$;

-- A bounded claim payload. The Edge function supplies one UUID and 1..25; neither caller text
-- nor a path is accepted from the worker.
create function app.content_asset_retention_check_claim(p_payload jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_errors jsonb := app.contract_unknown_keys(p_payload, array['claim_id', 'limit']);
  v_error text;
begin
  v_error := app.contract_uuid_error(p_payload -> 'claim_id');
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('claim_id', v_error);
  end if;
  if p_payload ? 'limit' and not app.contract_integer_in(p_payload -> 'limit', 1, 25) then
    v_errors := v_errors || '{"limit": "invalid"}';
  end if;
  return v_errors;
end;
$$;

-- Finalize only IDs that the Storage API confirmed removed. A lease that has expired or been
-- replaced is fenced; an asset that acquired any revision reference is never deleted.
create function app.content_asset_retention_check_finalize(p_payload jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_errors jsonb := app.contract_unknown_keys(p_payload, array['claim_id', 'asset_ids']);
  v_error text;
  v_id jsonb;
  v_seen jsonb := '[]'::jsonb;
begin
  v_error := app.contract_uuid_error(p_payload -> 'claim_id');
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('claim_id', v_error);
  end if;
  if jsonb_typeof(p_payload -> 'asset_ids') is distinct from 'array' then
    v_errors := v_errors || '{"asset_ids": "invalid"}';
  elsif jsonb_array_length(p_payload -> 'asset_ids') not between 1 and 25 then
    v_errors := v_errors || '{"asset_ids": "invalid"}';
  else
    for v_id in select value from jsonb_array_elements(p_payload -> 'asset_ids') loop
      v_error := app.contract_uuid_error(v_id);
      if v_error is not null or v_seen @> jsonb_build_array(v_id) then
        v_errors := v_errors || '{"asset_ids": "invalid"}';
      else
        v_seen := v_seen || jsonb_build_array(v_id);
      end if;
    end loop;
  end if;
  return v_errors;
end;
$$;

create function app.content_asset_retention_claim(p_principal uuid, p_request uuid, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_claim uuid := (p_payload ->> 'claim_id')::uuid;
  v_limit integer := least(coalesce((p_payload ->> 'limit')::integer, 25), 25);
  v_asset record;
  v_assets jsonb := '[]'::jsonb;
begin
  -- First select uses NOT EXISTS for efficiency. Each candidate is then checked again in a new
  -- statement after its row lock is held, so an attachment that won the asset lock is observed.
  for v_asset in
    select a.asset_id, a.draft_path
      from app.content_assets a
     where a.created_at <= clock_timestamp() - interval '30 days'
       and (a.retention_claimed_at is null
            or a.retention_claimed_at <= clock_timestamp() - interval '30 minutes')
       and not exists (select 1 from app.content_revision_files f where f.asset_id = a.asset_id)
     order by a.created_at, a.asset_id
     for update of a skip locked
     limit v_limit
  loop
    if not exists (select 1 from app.content_revision_files f where f.asset_id = v_asset.asset_id) then
      update app.content_assets a
         set retention_claim_id = v_claim, retention_claimed_at = clock_timestamp()
       where a.asset_id = v_asset.asset_id;
      v_assets := v_assets || jsonb_build_array(jsonb_build_object(
        'asset_id', v_asset.asset_id, 'draft_path', v_asset.draft_path));
    end if;
  end loop;
  return jsonb_build_object('data', jsonb_build_object(
    'claim_id', v_claim,
    'assets', v_assets,
    'claimed', jsonb_array_length(v_assets)));
end;
$$;

create function app.content_asset_retention_finalize(p_principal uuid, p_request uuid, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_claim uuid := (p_payload ->> 'claim_id')::uuid;
  v_id uuid;
  v_deleted integer := 0;
begin
  for v_id in select (e.value #>> '{}')::uuid from jsonb_array_elements(p_payload -> 'asset_ids') e
  loop
    perform 1 from app.content_assets a
     where a.asset_id = v_id and a.retention_claim_id = v_claim
       and a.retention_claimed_at > clock_timestamp() - interval '30 minutes'
       for update;
    if found and not exists (select 1 from app.content_revision_files f where f.asset_id = v_id) then
      delete from app.content_assets a where a.asset_id = v_id and a.retention_claim_id = v_claim;
      if found then
        v_deleted := v_deleted + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('data', jsonb_build_object('deleted', v_deleted));
end;
$$;

insert into app.sys_command_kinds (command, purpose, description, payload_check, handler) values
  ('content.asset_retention_claim', 'content_asset_retention',
   'Story F3: claim a bounded set of 30-day-old private uploads unused by every revision',
   'app.content_asset_retention_check_claim(jsonb)',
   'app.content_asset_retention_claim(uuid, uuid, jsonb)'),
  ('content.asset_retention_finalize', 'content_asset_retention',
   'Story F3: remove metadata for the claimed uploads confirmed deleted by Storage',
   'app.content_asset_retention_check_finalize(jsonb)',
   'app.content_asset_retention_finalize(uuid, uuid, jsonb)');

revoke all on function app.content_asset_retention_check_claim(jsonb),
  app.content_asset_retention_check_finalize(jsonb),
  app.content_asset_retention_claim(uuid, uuid, jsonb),
  app.content_asset_retention_finalize(uuid, uuid, jsonb)
  from public, anon, authenticated, service_role;

revoke all on function app.content_asset_error(uuid, uuid, text),
  app.content_file_attach(uuid, integer, text, text, uuid, uuid),
  app.content_asset_complete(uuid, bigint, jsonb),
  app.content_asset_preview(uuid)
  from public, anon, authenticated, service_role;

grant execute on function app.content_asset_preview(uuid) to authenticated;
