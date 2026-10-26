-- Story 6.6 correction: permit reviewed translation codes backed by complete manifests.
-- This forward-only migration leaves the applied 20261023020507 migration unchanged.
-- owner-approved-cleanup: Epic 6.6 review loop 2, recorded in epic Notes; replace the KJV/WEB-only allowlist while retaining complete-manifest validation. No rows are deleted.

alter table app.content_bible_manifest
  drop constraint if exists content_bible_manifest_translation_code_check;
alter table app.content_bible_manifest
  add constraint content_bible_manifest_translation_code_check
  check (translation_code ~ '^[A-Z0-9][A-Z0-9_-]{1,15}$');

alter table app.content_bible_translation_keys
  drop constraint if exists content_bible_translation_keys_translation_code_check;
alter table app.content_bible_translation_keys
  add constraint content_bible_translation_keys_translation_code_check
  check (translation_code ~ '^[A-Z0-9][A-Z0-9_-]{1,15}$');

alter table app.content_bible_revisions
  drop constraint if exists content_bible_revisions_translation_code_check;
alter table app.content_bible_revisions
  add constraint content_bible_revisions_translation_code_check
  check (translation_code ~ '^[A-Z0-9][A-Z0-9_-]{1,15}$');

create function app.content_bible_manifest_complete(p_version integer, p_code text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select count(m.book_id) = 66
     and bool_and(array_lower(m.chapter_counts, 1) = 1
       and array_length(m.chapter_counts, 1) = b.chapter_count
       and not exists (select 1 from unnest(m.chapter_counts) n
                        where n is null or n < 1 or n > 200))
    from app.content_bible_books b
    left join app.content_bible_manifest m on m.book_id = b.book_id
      and m.manifest_version = p_version and m.translation_code = p_code;
$$;

create function app.content_bible_latest_manifest(p_code text)
returns integer
language sql
stable
set search_path = ''
as $$
  select max(m.manifest_version) from app.content_bible_manifest m
   where m.translation_code = p_code
     and app.content_bible_manifest_complete(m.manifest_version, p_code);
$$;

create or replace function app.content_bible_revision_manifest_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not app.content_bible_manifest_complete(new.manifest_version, new.translation_code) then
    raise exception using errcode = 'PCNT1', message = 'Bible verse manifest is not registered';
  end if;
  return new;
end;
$$;

create or replace function app.content_bible_create(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_error text;
  v_code text;
  v_name text;
  v_rights uuid;
  v_manifest integer;
  v_item uuid;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'bible_translation') a;
  v_errors := app.contract_unknown_keys(p_payload,
    array['translation_code','name','rights_id','manifest_version']);
  v_code := p_payload ->> 'translation_code';
  if v_code is null or v_code !~ '^[A-Z0-9][A-Z0-9_-]{1,15}$' then
    v_errors := v_errors || jsonb_build_object('translation_code','invalid');
  end if;
  select t.error, t.value into v_error,v_name from app.content_free_text(p_payload -> 'name',100,false) t;
  if v_error is not null then v_errors := v_errors || jsonb_build_object('name',v_error); end if;
  if v_name is null then v_errors := v_errors || jsonb_build_object('name','required'); end if;
  if app.contract_uuid_error(p_payload -> 'rights_id') is not null then
    v_errors := v_errors || jsonb_build_object('rights_id','invalid');
  else
    v_rights := (p_payload ->> 'rights_id')::uuid;
  end if;
  if coalesce(p_payload ->> 'manifest_version','') !~ '^[1-9][0-9]{0,8}$' then
    v_errors := v_errors || jsonb_build_object('manifest_version','invalid');
  else
    v_manifest := (p_payload ->> 'manifest_version')::integer;
  end if;
  if v_code is not null and v_manifest is not null
     and not app.content_bible_manifest_complete(v_manifest, v_code) then
    v_errors := v_errors || jsonb_build_object('manifest_version','not_registered');
  end if;
  if exists (select 1 from app.content_bible_translation_keys k where k.translation_code = v_code) then
    v_errors := v_errors || jsonb_build_object('translation_code','already_exists');
  end if;
  if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed',v_errors); end if;
  v_item := app.content_item_open('bible_translation',v_actor.member_id,v_actor.account_id,
                                  v_actor.capacity,'content.create_bible_translation');
  insert into app.content_bible_translation_keys(item_id,translation_code) values(v_item,v_code);
  insert into app.content_bible_revisions(item_id,revision_no,translation_code,name,rights_id,
    manifest_version,saved_by_member,saved_by_account)
  values(v_item,1,v_code,v_name,v_rights,v_manifest,v_actor.member_id,v_actor.account_id);
  return app.content_item_outcome(v_item,'translation_id');
end;
$$;

create or replace function app.content_bible_begin_revision(p_actor uuid, p_expected_revision bigint,
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
  v_rights uuid;
  v_manifest integer;
  v_requested_manifest integer;
  v_item app.content_items;
  v_prev app.content_bible_revisions;
  v_no integer;
begin
  select a.* into v_actor from app.content_command_actor(p_actor,'bible_translation') a;
  v_errors := app.contract_unknown_keys(p_payload,array['translation_id','rights_id','manifest_version']);
  v_error := app.contract_uuid_error(p_payload -> 'translation_id');
  if v_error is not null then v_errors := v_errors || jsonb_build_object('translation_id',v_error);
  else v_id := (p_payload ->> 'translation_id')::uuid; end if;
  v_error := app.contract_uuid_error(p_payload -> 'rights_id');
  if v_error is not null then v_errors := v_errors || jsonb_build_object('rights_id',v_error);
  else v_rights := (p_payload ->> 'rights_id')::uuid; end if;
  if p_payload ? 'manifest_version' then
    if coalesce(p_payload ->> 'manifest_version','') !~ '^[1-9][0-9]{0,8}$' then
      v_errors := v_errors || jsonb_build_object('manifest_version','invalid');
    else
      v_requested_manifest := (p_payload ->> 'manifest_version')::integer;
    end if;
  end if;
  if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed',v_errors); end if;
  v_item := app.content_item_lock(v_id,'bible_translation',p_expected_revision,'translation_id');
  select r.* into v_prev from app.content_bible_revisions r
   where r.item_id = v_id and r.revision_no = coalesce(v_item.draft_revision_no,v_item.live_revision_no)
   for share;
  if not found then perform app.cmd_fail('not_found'); end if;
  v_manifest := coalesce(v_requested_manifest,v_prev.manifest_version);
  if not app.content_bible_manifest_complete(v_manifest,v_prev.translation_code) then
    perform app.cmd_fail('validation_failed',jsonb_build_object('manifest_version','not_registered'));
  end if;
  v_no := v_item.last_revision_no + 1;
  insert into app.content_bible_revisions(item_id,revision_no,translation_code,name,rights_id,
    manifest_version,saved_by_member,saved_by_account)
  values(v_id,v_no,v_prev.translation_code,v_prev.name,v_rights,v_manifest,
    v_actor.member_id,v_actor.account_id);
  perform app.content_item_saved(v_item,v_no,v_actor.member_id,v_actor.account_id,
    v_actor.capacity,'content.begin_bible_revision');
  return app.content_item_outcome(v_id,'translation_id');
end;
$$;

create or replace function app.content_bible_manifest_json(p_code text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with selected as (
    select app.content_bible_latest_manifest(p_code) as manifest_version
  )
  select case when selected.manifest_version is null then null else
    jsonb_build_object('translation_code',p_code,
      'manifest_version',selected.manifest_version,
      'chapters',coalesce((
        select jsonb_agg(jsonb_build_object('book_id',m.book_id,
          'chapter',c.chapter,'verse_count',m.chapter_counts[c.chapter])
          order by b.canonical_order,c.chapter)
          from app.content_bible_manifest m
          join app.content_bible_books b on b.book_id=m.book_id
          cross join lateral generate_subscripts(m.chapter_counts,1) c(chapter)
         where m.translation_code=p_code and m.manifest_version=selected.manifest_version
      ),'[]'::jsonb))
  end
  from selected;
$$;

revoke all on function app.content_bible_manifest_complete(integer,text),
  app.content_bible_latest_manifest(text)
  from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
