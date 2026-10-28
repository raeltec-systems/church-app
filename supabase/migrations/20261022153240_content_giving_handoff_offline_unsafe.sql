-- Story 6.5: dialler handoff, offline giving instructions and unsafe-method warning.
-- Extend Story 6.3 on the existing Content revision, rights and command paths.

alter table app.content_giving_methods
  add column unsafe boolean not null default false;

insert into app.content_asset_purposes (purpose, kind, rights_use, media_types, max_bytes,
                                        min_width, min_height, max_width, max_height, min_ratio,
                                        max_ratio, description) values
  ('giving_logo', 'giving_method', 'display', array['image/png', 'image/jpeg', 'image/webp'],
   2097152, 32, 32, 2000, 2000, 0.20, 5.00,
   'A giving provider logo, subject to display and offline rights (story 6.5)');

create or replace function app.content_giving_vocab(p_kind text, p_value text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_value is not null and case p_kind
    when 'method_type' then p_value in ('mobile_money', 'bank', 'other')
    when 'identifier_kind' then p_value in ('merchant', 'till', 'phone')
    when 'audit_action' then p_value in ('saved', 'verified', 'reordered', 'draft_discarded',
                                         'unsafe_flagged', 'unsafe_cleared')
    else false end;
$$;

-- owner-approved-cleanup: Epic 6.5 adds unsafe/logo audit fields to the giving audit allowlist
alter table app.content_giving_audit
  drop constraint content_giving_audit_changed_fields_check;
alter table app.content_giving_audit
  add constraint content_giving_audit_changed_fields_check
  check (changed_fields is null or changed_fields <@ array['name', 'purpose', 'currency', 'steps',
       'note', 'contact', 'beneficiary', 'identifier_kind', 'identifier', 'ussd_code',
       'bank_name', 'account_number', 'branch', 'branch_code', 'swift_code', 'reference',
       'unsafe', 'logo']::text[]);

-- Accept optional logo references on the normal save command. A file uses the existing Content
-- asset upload and rights records; omitting both keys keeps the draft's previous logo. Explicit
-- nulls clear it. Any actual logo change is part of the saved revision and clears verification.
create or replace function app.content_giving_save(p_actor uuid, p_expected_revision bigint,
                                                   p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_error text;
  v_id uuid;
  v_type text;
  v_errors jsonb;
  v_fields record;
  v_item app.content_items;
  v_no integer;
  v_base jsonb;
  v_changed text[];
  v_revision bigint;
  v_old_asset uuid;
  v_old_rights uuid;
  v_new_asset uuid;
  v_new_rights uuid;
  v_asset_error text;
  v_rights_error text;
  v_next_fields jsonb;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'giving_method') a;
  select t.error, t.value into v_error, v_id from app.content_giving_id(p_payload) t;
  if v_error is not null then
    perform app.cmd_fail('validation_failed', jsonb_build_object('method_id', v_error));
  end if;
  select g.method_type into v_type from app.content_giving_methods g where g.item_id = v_id;
  if v_type is null then
    perform app.cmd_fail('not_found');
  end if;
  v_errors := app.contract_unknown_keys(p_payload,
    array['method_id', 'logo_asset_id', 'logo_rights_id'] || app.content_giving_keys(v_type));
  select f.* into v_fields from app.content_giving_fields(v_type, p_payload) f;
  v_errors := v_errors || v_fields.errors;

  select f.asset_id, f.rights_id into v_old_asset, v_old_rights
    from app.content_revision_files f
   where f.item_id = v_id and f.revision_no = coalesce(
     (select i.draft_revision_no from app.content_items i where i.item_id = v_id),
     (select i.live_revision_no from app.content_items i where i.item_id = v_id))
     and f.slot = 'logo';
  v_new_asset := v_old_asset;
  v_new_rights := v_old_rights;
  if p_payload ? 'logo_asset_id' or p_payload ? 'logo_rights_id' then
    if coalesce(jsonb_typeof(p_payload -> 'logo_asset_id'), 'null') = 'null' then
      v_new_asset := null;
    else
      v_error := app.contract_uuid_error(p_payload -> 'logo_asset_id');
      if v_error is null then v_new_asset := (p_payload ->> 'logo_asset_id')::uuid; end if;
      if v_error is not null then v_errors := v_errors || jsonb_build_object('logo_asset_id', v_error); end if;
    end if;
    if coalesce(jsonb_typeof(p_payload -> 'logo_rights_id'), 'null') = 'null' then
      v_new_rights := null;
    else
      v_error := app.contract_uuid_error(p_payload -> 'logo_rights_id');
      if v_error is null then v_new_rights := (p_payload ->> 'logo_rights_id')::uuid; end if;
      if v_error is not null then v_errors := v_errors || jsonb_build_object('logo_rights_id', v_error); end if;
    end if;
    if (v_new_asset is null) <> (v_new_rights is null) then
      v_errors := v_errors || '{"logo_asset_id": "asset_and_rights_required_together"}'::jsonb;
    elsif v_new_asset is not null then
      v_asset_error := app.content_asset_error(v_new_asset, v_id, 'giving_logo');
      v_rights_error := app.content_rights_ref_error(v_new_rights);
      if v_asset_error is not null then
        v_errors := v_errors || jsonb_build_object('logo_asset_id', v_asset_error);
      end if;
      if v_rights_error is not null then
        v_errors := v_errors || jsonb_build_object('logo_rights_id', v_rights_error);
      end if;
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;

  v_item := app.content_item_lock(v_id, 'giving_method', p_expected_revision, 'method_id');
  select app.content_giving_revision_fields(r) into v_base
    from app.content_giving_revisions r
   where r.item_id = v_id and r.revision_no = coalesce(v_item.draft_revision_no, v_item.live_revision_no);
  v_base := v_base || jsonb_build_object('logo', jsonb_build_array(v_old_asset, v_old_rights));
  v_next_fields := v_fields.fields || jsonb_build_object('logo', jsonb_build_array(v_new_asset, v_new_rights));
  v_changed := app.content_giving_changed_fields(v_base, v_next_fields);
  if v_changed is null then
    perform app.cmd_fail('validation_failed', '{"method_id": "unchanged"}');
  end if;
  v_no := app.content_item_draft_no(v_item);
  perform app.content_giving_write_revision(v_id, v_no, v_type, v_fields.fields,
                                            v_actor.member_id, v_actor.account_id);
  v_revision := app.content_item_saved(v_item, v_no, v_actor.member_id, v_actor.account_id,
                                       v_actor.capacity, 'content.save_giving_method');
  if v_new_asset is not null then
    perform app.content_file_attach(v_id, v_no, 'logo', 'giving_logo', v_new_asset, v_new_rights);
  end if;
  perform app.content_giving_audit_event('saved', v_actor.member_id, v_actor.account_id,
                                         'content.save_giving_method', v_id, v_no, null, v_changed,
                                         v_revision);
  return app.content_item_outcome(v_id, 'method_id');
end;
$$;

-- The method-level warning is changed through the command router, audited and revisioned, with no
-- change to the verified content revision or its publication state.
create function app.content_giving_set_unsafe(p_actor uuid, p_expected_revision bigint,
                                              p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_error text;
  v_id uuid;
  v_unsafe boolean;
  v_item app.content_items;
  v_old boolean;
  v_revision bigint;
  v_action text;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'giving_method') a;
  v_errors := app.contract_unknown_keys(p_payload, array['method_id', 'unsafe']);
  select t.error, t.value into v_error, v_id from app.content_giving_id(p_payload) t;
  if v_error is not null then v_errors := v_errors || jsonb_build_object('method_id', v_error); end if;
  select t.error, t.value into v_error, v_unsafe from app.content_payload_bool(p_payload, 'unsafe') t;
  if v_error is not null then v_errors := v_errors || jsonb_build_object('unsafe', v_error); end if;
  if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed', v_errors); end if;

  v_item := app.content_item_lock(v_id, 'giving_method', p_expected_revision, 'method_id');
  if v_item.lifecycle_state = 'archived' then
    perform app.cmd_fail('validation_failed', '{"method_id": "archived"}');
  end if;
  select g.unsafe into v_old from app.content_giving_methods g where g.item_id = v_id for update;
  if v_old = v_unsafe then
    perform app.cmd_fail('validation_failed', '{"unsafe": "unchanged"}');
  end if;
  update app.content_giving_methods g set unsafe = v_unsafe where g.item_id = v_id;
  v_revision := app.content_giving_touch(v_id);
  v_action := case when v_unsafe then 'unsafe_flagged' else 'unsafe_cleared' end;
  perform app.content_giving_audit_event(v_action, v_actor.member_id, v_actor.account_id,
                                         'content.set_giving_method_unsafe', v_id,
                                         coalesce(v_item.live_revision_no, v_item.draft_revision_no),
                                         null, array['unsafe'], v_revision);
  return app.content_item_outcome(v_id, 'method_id');
end;
$$;

select app.content_register_command('content.set_giving_method_unsafe', 'giving_method',
  'app.content_giving_set_unsafe(uuid, bigint, jsonb)'::regprocedure, false);

create or replace function app.content_giving_public_json(p_item_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'method_id', i.item_id,
    'method_type', g.method_type,
    'name', r.name,
    'purpose', r.purpose,
    'currency', r.currency,
    'details', app.content_giving_details(r),
    'ussd_code', r.ussd_code,
    'steps', to_jsonb(r.steps),
    'note', r.note,
    'contact', r.contact,
    'verified_on', to_char(r.tested_on, 'YYYY-MM-DD'),
    'publication_revision', r.revision_no,
    'published_at', app.cmd_utc(i.published_at),
    'unsafe', g.unsafe,
    'logo', case when f.asset_id is not null and app.content_public_file(i.item_id, 'logo') is not null
      then (app.content_public_file(i.item_id, 'logo') || jsonb_build_object(
        'rights_revision', ri.live_revision_no,
        'offline_allowed', app.content_rights_clear(f.rights_id, 'offline') is null))
      else null end)
    from app.content_items i
    join app.content_giving_methods g on g.item_id = i.item_id
    join app.content_giving_revisions r on r.item_id = i.item_id and r.revision_no = i.live_revision_no
    left join app.content_revision_files f on f.item_id = i.item_id
      and f.revision_no = i.live_revision_no and f.slot = 'logo'
    left join app.content_items ri on ri.item_id = f.rights_id
   where i.item_id = p_item_id and i.kind = 'giving_method' and i.lifecycle_state = 'published'
     and r.verified_at is not null;
$$;

create or replace function app.content_giving_revision_json(p_item_id uuid, p_revision_no integer,
                                                            p_member uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
           'revision_no', r.revision_no,
           'name', r.name,
           'purpose', r.purpose,
           'currency', r.currency,
           'steps', to_jsonb(r.steps),
           'note', r.note,
           'contact', r.contact,
           'logo_asset_id', f.asset_id,
           'logo_rights_id', f.rights_id,
           'saved_at', app.cmd_utc(r.saved_at),
           'saved_by', app.content_editor_name(r.saved_by_member),
           'saved_by_you', p_member = any (r.saved_by_members),
           'published_at', app.cmd_utc(r.published_at),
           'published_by', case when r.published_by_member is not null
                                then app.content_editor_name(r.published_by_member) end,
           'verification', case when r.verified_at is not null then jsonb_build_object(
             'verified_at', app.cmd_utc(r.verified_at),
             'verified_by', app.content_editor_name(r.verified_by_member),
             'verified_by_you', r.verified_by_member = p_member,
             'tested_on', to_char(r.tested_on, 'YYYY-MM-DD'),
             'test_method', r.test_method) end)
         || case r.method_type
              when 'mobile_money' then jsonb_build_object(
                'beneficiary', r.beneficiary, 'identifier_kind', r.identifier_kind,
                'identifier', r.identifier, 'ussd_code', r.ussd_code)
              when 'bank' then jsonb_build_object(
                'bank_name', r.bank_name, 'beneficiary', r.beneficiary,
                'account_number', r.account_number, 'branch', r.branch,
                'branch_code', r.branch_code, 'swift_code', r.swift_code,
                'reference', r.reference)
              else '{}'::jsonb end
    from app.content_giving_revisions r
    left join app.content_revision_files f on f.item_id = r.item_id
      and f.revision_no = r.revision_no and f.slot = 'logo'
   where r.item_id = p_item_id and r.revision_no = p_revision_no;
$$;

create or replace function app.content_staff_giving_json(p_item_id uuid, p_position bigint,
                                                         p_member uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'method_id', i.item_id,
    'method_type', g.method_type,
    'position', p_position,
    'revision', i.revision,
    'state', i.lifecycle_state,
    'unsafe', g.unsafe,
    'created_at', app.cmd_utc(i.created_at),
    'created_by', app.content_editor_name(i.created_by_member),
    'updated_at', app.cmd_utc(i.updated_at),
    'published_at', app.cmd_utc(i.published_at),
    'published_by', case when i.published_by_member is not null
                         then app.content_editor_name(i.published_by_member) end,
    'withdrawn_at', app.cmd_utc(i.withdrawn_at),
    'archived_at', app.cmd_utc(i.archived_at),
    'live', case when i.live_revision_no is not null
                 then app.content_giving_revision_json(i.item_id, i.live_revision_no, p_member) end,
    'draft', case when i.draft_revision_no is not null
                  then app.content_giving_revision_json(i.item_id, i.draft_revision_no, p_member) end)
    from app.content_items i
    join app.content_giving_methods g on g.item_id = i.item_id
   where i.item_id = p_item_id;
$$;

revoke all on function app.content_giving_set_unsafe(uuid, bigint, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function app.content_giving_vocab(text, text),
  app.content_giving_public_json(uuid),
  app.content_giving_revision_json(uuid, integer, uuid),
  app.content_staff_giving_json(uuid, bigint, uuid)
  from public, anon, authenticated, service_role;

grant execute on function app.content_public_giving_methods() to anon, authenticated;
grant execute on function api.content_public_giving_methods() to anon, authenticated;
grant execute on function app.content_public_giving_method(uuid) to anon, authenticated;
grant execute on function api.content_public_giving_method(uuid) to anon, authenticated;
grant execute on function app.content_staff_giving_methods() to authenticated;
grant execute on function api.content_staff_giving_methods() to authenticated;

notify pgrst, 'reload schema';
