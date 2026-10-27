-- Story 6.9: series and sermons extend Content's registries and shared lifecycle.
-- Church-authored notes remain readable when a video or series is withdrawn.
-- No server requests to YouTube, no row deletions, no policy approvals.

insert into app.content_kinds (kind, editor_roles, description) values
  ('sermon_series', array['admin', 'pastor', 'media'], 'Sermon series and optional cleared posters (story 6.9)'),
  ('sermon', array['admin', 'pastor', 'media'], 'Church-authored sermon notes and cleared YouTube references (story 6.9)');

insert into app.content_asset_purposes (purpose, kind, rights_use, media_types, max_bytes,
  min_width, min_height, max_width, max_height, min_ratio, max_ratio, description) values
  ('sermon_series_poster', 'sermon_series', 'display', array['image/png', 'image/jpeg', 'image/webp'],
   5242880, 960, 540, 6000, 6000, 1.30, 2.40, 'A sermon series poster shown at 16:9 (story 6.9)');

-- Links are deliberately narrower than a general Markdown implementation. In particular,
-- links with a title, a reference, escaped punctuation or a second authority are refused.
create function app.content_sermon_link_ok(p_url text)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(p_url ~ ('^https://(ebible[.]org|biblegateway[.]com|www[.]biblegateway[.]com|youtube[.]com|www[.]youtube[.]com|youtu[.]be)([/?#][^[:space:]()<>' || chr(34) || chr(39) || ']*)?$'), false)
    and position(chr(92) in coalesce(p_url, '')) = 0;
$$;

create function app.content_sermon_notes_error(p_notes text)
returns text language plpgsql immutable set search_path = '' as $$
declare
  v_rest text := coalesce(p_notes, '');
  v_at integer;
  v_link text[];
  v_plain text := '';
  v_line text;
begin
  if length(v_rest) > 20000 then return 'too_long'; end if;
  if v_rest ~ '[<>`|]' or position('![' in v_rest) > 0
     or position('~~' in v_rest) > 0 or position(chr(92) in v_rest) > 0 then
    return 'unsupported_markdown';
  end if;
  while position('[' in v_rest) > 0 loop
    v_at := position('[' in v_rest);
    v_plain := v_plain || left(v_rest, v_at - 1);
    v_rest := substr(v_rest, v_at);
    v_link := regexp_match(v_rest, '^[[]([^][]+)[]][(]([^()[:space:]]+)[)]');
    if v_link is null or not app.content_sermon_link_ok(v_link[2])
       or position(chr(10) in v_link[1]) > 0
       or position('[' in v_link[2]) > 0 or position(']' in v_link[2]) > 0 then
      return 'unsafe_link';
    end if;
    v_plain := v_plain || ' ';
    v_rest := substr(v_rest, length(v_link[1]) + length(v_link[2]) + 5);
  end loop;
  v_plain := v_plain || v_rest;
  if position(']' in v_plain) > 0 or v_plain ~* '(https?://|www[.])' then
    return 'unsupported_markdown';
  end if;
  foreach v_line in array string_to_array(v_plain, chr(10)) loop
    if v_line ~ '^ {4}' or v_line ~ '^[[:space:]]*#{7,}'
       or v_line ~ '^[[:space:]]*([-*_]{3,}|={3,})[[:space:]]*$' then
      return 'unsupported_markdown';
    end if;
  end loop;
  return null;
end;
$$;

create table app.content_sermon_series_revisions (
  item_id uuid not null references app.content_items (item_id),
  revision_no integer not null check (revision_no >= 1),
  title text not null check (length(title) between 1 and 120),
  description text not null default '' check (length(description) <= 2000),
  alt_text text not null default '' check (length(alt_text) <= 250),
  saved_by_member uuid not null,
  saved_by_account uuid not null,
  saved_at timestamptz not null default now(),
  published_at timestamptz,
  published_by_member uuid,
  published_by_account uuid,
  primary key (item_id, revision_no),
  check ((published_at is null) = (published_by_member is null)
     and (published_by_member is null) = (published_by_account is null))
);
comment on table app.content_sermon_series_revisions is
  'owner: content. Revisioned sermon series copy; posters reuse content_revision_files (story 6.9).';

create table app.content_sermon_revisions (
  item_id uuid not null references app.content_items (item_id),
  revision_no integer not null check (revision_no >= 1),
  title text not null check (length(title) between 1 and 160),
  speaker text check (length(speaker) between 1 and 160),
  sermon_date date,
  scripture_reference text check (length(scripture_reference) between 1 and 250),
  notes text not null default '' check (app.content_sermon_notes_error(notes) is null),
  series_id uuid references app.content_items (item_id),
  youtube_video_id text check (youtube_video_id ~ '^[A-Za-z0-9_-]{11}$'),
  video_rights_id uuid references app.content_items (item_id),
  saved_by_member uuid not null,
  saved_by_account uuid not null,
  saved_at timestamptz not null default now(),
  published_at timestamptz,
  published_by_member uuid,
  published_by_account uuid,
  primary key (item_id, revision_no),
  check ((published_at is null) = (published_by_member is null)
     and (published_by_member is null) = (published_by_account is null))
);
comment on table app.content_sermon_revisions is
  'owner: content. Church-authored notes, optional series and rights-cleared video references (story 6.9).';

alter table app.content_sermon_series_revisions enable row level security;
alter table app.content_sermon_revisions enable row level security;
revoke all on table app.content_sermon_series_revisions, app.content_sermon_revisions
  from public, anon, authenticated, service_role;

create function app.content_sermon_series_revision_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.published_at is not null and
     (new.item_id, new.revision_no, new.title, new.description, new.alt_text,
      new.saved_at, new.published_at) is distinct from
     (old.item_id, old.revision_no, old.title, old.description, old.alt_text,
      old.saved_at, old.published_at) then
    raise exception using errcode = 'PCNT1', message = 'a published content revision is immutable';
  end if;
  return new;
end;
$$;
create trigger content_sermon_series_revision_guard before update on app.content_sermon_series_revisions
  for each row execute function app.content_sermon_series_revision_guard();

create function app.content_sermon_revision_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.published_at is not null and
     (new.item_id, new.revision_no, new.title, new.speaker, new.sermon_date,
      new.scripture_reference, new.notes, new.series_id, new.youtube_video_id,
      new.video_rights_id, new.saved_at, new.published_at) is distinct from
     (old.item_id, old.revision_no, old.title, old.speaker, old.sermon_date,
      old.scripture_reference, old.notes, old.series_id, old.youtube_video_id,
      old.video_rights_id, old.saved_at, old.published_at) then
    raise exception using errcode = 'PCNT1', message = 'a published content revision is immutable';
  end if;
  return new;
end;
$$;
create trigger content_sermon_revision_guard before update on app.content_sermon_revisions
  for each row execute function app.content_sermon_revision_guard();

create function app.content_sermon_series_fields(p_payload jsonb,
  out errors jsonb, out title text, out description text, out alt_text text)
language plpgsql immutable set search_path = '' as $$
declare v_error text;
begin
  errors := '{}'::jsonb;
  select t.error, t.value into v_error, title from app.content_free_text(p_payload -> 'title', 120, false) t;
  if v_error is null and title is null then v_error := 'required'; end if;
  if v_error is not null then errors := errors || jsonb_build_object('title', v_error); end if;
  select t.error, t.value into v_error, description from app.content_free_text(p_payload -> 'description', 2000, true) t;
  if v_error is not null then errors := errors || jsonb_build_object('description', v_error); end if;
  description := coalesce(description, '');
  select t.error, t.value into v_error, alt_text from app.content_free_text(p_payload -> 'alt_text', 250, false) t;
  if v_error is not null then errors := errors || jsonb_build_object('alt_text', v_error); end if;
  alt_text := coalesce(alt_text, '');
end;
$$;

create function app.content_sermon_fields(p_payload jsonb,
  out errors jsonb, out title text, out speaker text, out sermon_date date,
  out scripture_reference text, out notes text, out series_id uuid,
  out youtube_video_id text, out video_rights_id uuid)
language plpgsql stable set search_path = '' as $$
declare v_error text; v_raw text;
begin
  errors := '{}'::jsonb;
  select t.error, t.value into v_error, title from app.content_free_text(p_payload -> 'title', 160, false) t;
  if v_error is null and title is null then v_error := 'required'; end if;
  if v_error is not null then errors := errors || jsonb_build_object('title', v_error); end if;
  select t.error, t.value into v_error, speaker from app.content_free_text(p_payload -> 'speaker', 160, false) t;
  if v_error is not null then errors := errors || jsonb_build_object('speaker', v_error); end if;
  select t.error, t.value into v_error, scripture_reference from app.content_free_text(p_payload -> 'scripture_reference', 250, false) t;
  if v_error is not null then errors := errors || jsonb_build_object('scripture_reference', v_error); end if;
  if coalesce(jsonb_typeof(p_payload -> 'sermon_date'), 'null') <> 'null' then
    v_raw := p_payload ->> 'sermon_date';
    begin
      if jsonb_typeof(p_payload -> 'sermon_date') <> 'string' or v_raw !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
         or v_raw::date::text <> v_raw then
        errors := errors || '{"sermon_date":"invalid"}';
      else sermon_date := v_raw::date;
      end if;
    exception when others then errors := errors || '{"sermon_date":"invalid"}';
    end;
  end if;
  select t.error, t.value into v_error, notes from app.content_free_text(p_payload -> 'notes', 20000, true) t;
  if v_error is null then v_error := app.content_sermon_notes_error(notes); end if;
  if v_error is not null then errors := errors || jsonb_build_object('notes', v_error); end if;
  notes := coalesce(notes, '');
  select t.error, t.value into v_error, series_id from app.content_payload_optional_uuid(p_payload, 'series_id') t;
  if v_error is null and series_id is not null and not exists
     (select 1 from app.content_items i where i.item_id = series_id and i.kind = 'sermon_series' and i.lifecycle_state <> 'archived') then
    v_error := 'unknown';
  end if;
  if v_error is not null then errors := errors || jsonb_build_object('series_id', v_error); end if;
  select t.error, t.value into v_error, youtube_video_id from app.content_free_text(p_payload -> 'youtube_video_id', 11, false) t;
  if v_error is null and youtube_video_id is not null and youtube_video_id !~ '^[A-Za-z0-9_-]{11}$' then v_error := 'invalid'; end if;
  if v_error is not null then errors := errors || jsonb_build_object('youtube_video_id', v_error); end if;
  select t.error, t.value into v_error, video_rights_id from app.content_payload_optional_uuid(p_payload, 'video_rights_id') t;
  if v_error is null then v_error := app.content_rights_ref_error(video_rights_id); end if;
  if v_error is not null then errors := errors || jsonb_build_object('video_rights_id', v_error); end if;
end;
$$;

create function app.content_sermon_series_create(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v_actor record; v_fields record; v_errors jsonb; v_id uuid;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'sermon_series') a;
  v_errors := app.contract_unknown_keys(p_payload, array['title', 'description', 'alt_text']);
  select f.* into v_fields from app.content_sermon_series_fields(p_payload) f;
  v_errors := v_errors || v_fields.errors;
  if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed', v_errors); end if;
  v_id := app.content_item_open('sermon_series', v_actor.member_id, v_actor.account_id, v_actor.capacity, 'content.create_sermon_series');
  insert into app.content_sermon_series_revisions (item_id, revision_no, title, description, alt_text, saved_by_member, saved_by_account)
  values (v_id, 1, v_fields.title, v_fields.description, v_fields.alt_text, v_actor.member_id, v_actor.account_id);
  return app.content_item_outcome(v_id, 'series_id');
end;
$$;

create function app.content_sermon_series_save(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v_actor record; v_fields record; v_errors jsonb; v_error text; v_id uuid;
  v_item app.content_items; v_no integer; v_asset uuid; v_rights uuid;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'sermon_series') a;
  v_errors := app.contract_unknown_keys(p_payload, array['series_id', 'title', 'description', 'alt_text', 'poster_asset_id', 'poster_rights_id']);
  select t.error, t.value into v_error, v_id from app.content_payload_uuid(p_payload, 'series_id') t;
  if v_error is not null then v_errors := v_errors || jsonb_build_object('series_id', v_error); end if;
  select f.* into v_fields from app.content_sermon_series_fields(p_payload) f;
  v_errors := v_errors || v_fields.errors;
  select t.error, t.value into v_error, v_asset from app.content_payload_optional_uuid(p_payload, 'poster_asset_id') t;
  if v_error is null and v_id is not null then v_error := app.content_asset_error(v_asset, v_id, 'sermon_series_poster'); end if;
  if v_error is not null then v_errors := v_errors || jsonb_build_object('poster_asset_id', v_error); end if;
  select t.error, t.value into v_error, v_rights from app.content_payload_optional_uuid(p_payload, 'poster_rights_id') t;
  if v_error is null then v_error := app.content_rights_ref_error(v_rights); end if;
  if v_error is not null then v_errors := v_errors || jsonb_build_object('poster_rights_id', v_error); end if;
  if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed', v_errors); end if;
  v_item := app.content_item_lock(v_id, 'sermon_series', p_expected_revision, 'series_id');
  v_no := app.content_item_draft_no(v_item);
  insert into app.content_sermon_series_revisions as r (item_id, revision_no, title, description, alt_text, saved_by_member, saved_by_account)
  values (v_id, v_no, v_fields.title, v_fields.description, v_fields.alt_text, v_actor.member_id, v_actor.account_id)
  on conflict (item_id, revision_no) do update set title = excluded.title, description = excluded.description,
    alt_text = excluded.alt_text, saved_by_member = excluded.saved_by_member, saved_by_account = excluded.saved_by_account, saved_at = now()
  where r.published_at is null;
  perform app.content_item_saved(v_item, v_no, v_actor.member_id, v_actor.account_id, v_actor.capacity, 'content.save_sermon_series');
  perform app.content_file_attach(v_id, v_no, 'poster', 'sermon_series_poster', v_asset, v_rights);
  return app.content_item_outcome(v_id, 'series_id');
end;
$$;

create function app.content_sermon_create(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v_actor record; v_fields record; v_errors jsonb; v_id uuid;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'sermon') a;
  v_errors := app.contract_unknown_keys(p_payload, array['title', 'speaker', 'sermon_date', 'scripture_reference', 'notes', 'series_id', 'youtube_video_id', 'video_rights_id']);
  select f.* into v_fields from app.content_sermon_fields(p_payload) f;
  v_errors := v_errors || v_fields.errors;
  if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed', v_errors); end if;
  v_id := app.content_item_open('sermon', v_actor.member_id, v_actor.account_id, v_actor.capacity, 'content.create_sermon');
  insert into app.content_sermon_revisions (item_id, revision_no, title, speaker, sermon_date, scripture_reference,
    notes, series_id, youtube_video_id, video_rights_id, saved_by_member, saved_by_account)
  values (v_id, 1, v_fields.title, v_fields.speaker, v_fields.sermon_date, v_fields.scripture_reference,
    v_fields.notes, v_fields.series_id, v_fields.youtube_video_id, v_fields.video_rights_id, v_actor.member_id, v_actor.account_id);
  return app.content_item_outcome(v_id, 'sermon_id');
end;
$$;

create function app.content_sermon_save(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v_actor record; v_fields record; v_errors jsonb; v_error text; v_id uuid; v_item app.content_items; v_no integer;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'sermon') a;
  v_errors := app.contract_unknown_keys(p_payload, array['sermon_id', 'title', 'speaker', 'sermon_date', 'scripture_reference', 'notes', 'series_id', 'youtube_video_id', 'video_rights_id']);
  select t.error, t.value into v_error, v_id from app.content_payload_uuid(p_payload, 'sermon_id') t;
  if v_error is not null then v_errors := v_errors || jsonb_build_object('sermon_id', v_error); end if;
  select f.* into v_fields from app.content_sermon_fields(p_payload) f;
  v_errors := v_errors || v_fields.errors;
  if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed', v_errors); end if;
  v_item := app.content_item_lock(v_id, 'sermon', p_expected_revision, 'sermon_id');
  v_no := app.content_item_draft_no(v_item);
  insert into app.content_sermon_revisions as r (item_id, revision_no, title, speaker, sermon_date, scripture_reference,
    notes, series_id, youtube_video_id, video_rights_id, saved_by_member, saved_by_account)
  values (v_id, v_no, v_fields.title, v_fields.speaker, v_fields.sermon_date, v_fields.scripture_reference,
    v_fields.notes, v_fields.series_id, v_fields.youtube_video_id, v_fields.video_rights_id, v_actor.member_id, v_actor.account_id)
  on conflict (item_id, revision_no) do update set title = excluded.title, speaker = excluded.speaker,
    sermon_date = excluded.sermon_date, scripture_reference = excluded.scripture_reference, notes = excluded.notes,
    series_id = excluded.series_id, youtube_video_id = excluded.youtube_video_id, video_rights_id = excluded.video_rights_id,
    saved_by_member = excluded.saved_by_member, saved_by_account = excluded.saved_by_account, saved_at = now()
  where r.published_at is null;
  perform app.content_item_saved(v_item, v_no, v_actor.member_id, v_actor.account_id, v_actor.capacity, 'content.save_sermon');
  return app.content_item_outcome(v_id, 'sermon_id');
end;
$$;

create function app.content_sermon_series_publish(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v_actor record; v_id uuid; v_item app.content_items; v_no integer;
  v_rev app.content_sermon_series_revisions; v_file app.content_revision_files; v_error text; v_errors jsonb := '{}';
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'sermon_series') a;
  v_id := app.content_lifecycle_id(p_payload, 'series_id');
  v_item := app.content_item_lock(v_id, 'sermon_series', p_expected_revision, 'series_id');
  v_no := coalesce(v_item.draft_revision_no, case when v_item.lifecycle_state = 'withdrawn' then v_item.live_revision_no end);
  if v_no is not null then
    select r.* into v_rev from app.content_sermon_series_revisions r where r.item_id = v_id and r.revision_no = v_no;
    select f.* into v_file from app.content_revision_files f where f.item_id = v_id and f.revision_no = v_no and f.slot = 'poster';
    if v_file.asset_id is not null then
      v_error := app.content_asset_error(v_file.asset_id, v_id, 'sermon_series_poster');
      if v_error is not null then v_errors := v_errors || jsonb_build_object('poster_asset_id', v_error); end if;
      v_error := app.content_rights_clear(v_file.rights_id, 'display');
      if v_error is not null then v_errors := v_errors || jsonb_build_object('poster_rights_id', v_error); end if;
      if v_rev.alt_text = '' then v_errors := v_errors || '{"alt_text":"required"}'; end if;
    end if;
    if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed', v_errors); end if;
  end if;
  v_no := app.content_item_publish(v_item, v_actor.member_id, v_actor.account_id, v_actor.capacity, 'content.publish_sermon_series', 'series_id');
  update app.content_sermon_series_revisions r set published_at = now(), published_by_member = v_actor.member_id,
    published_by_account = v_actor.account_id where r.item_id = v_id and r.revision_no = v_no and r.published_at is null;
  return app.content_item_outcome(v_id, 'series_id');
end;
$$;

create function app.content_sermon_publish(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v_actor record; v_id uuid; v_item app.content_items; v_no integer;
  v_rev app.content_sermon_revisions; v_error text; v_errors jsonb := '{}';
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'sermon') a;
  v_id := app.content_lifecycle_id(p_payload, 'sermon_id');
  v_item := app.content_item_lock(v_id, 'sermon', p_expected_revision, 'sermon_id');
  v_no := coalesce(v_item.draft_revision_no, case when v_item.lifecycle_state = 'withdrawn' then v_item.live_revision_no end);
  if v_no is not null then
    select r.* into v_rev from app.content_sermon_revisions r where r.item_id = v_id and r.revision_no = v_no;
    if v_rev.speaker is null then v_errors := v_errors || '{"speaker":"required"}'; end if;
    if v_rev.sermon_date is null then v_errors := v_errors || '{"sermon_date":"required"}'; end if;
    if v_rev.scripture_reference is null then v_errors := v_errors || '{"scripture_reference":"required"}'; end if;
    if v_rev.series_id is not null and not exists
       (select 1 from app.content_items i where i.item_id = v_rev.series_id and i.kind = 'sermon_series' and i.lifecycle_state = 'published') then
      v_errors := v_errors || '{"series_id":"not_published"}';
    end if;
    if v_rev.youtube_video_id is not null then
      v_error := app.content_rights_clear(v_rev.video_rights_id, 'display');
      if v_error is not null then v_errors := v_errors || jsonb_build_object('video_rights_id', v_error); end if;
    end if;
    if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed', v_errors); end if;
  end if;
  v_no := app.content_item_publish(v_item, v_actor.member_id, v_actor.account_id, v_actor.capacity, 'content.publish_sermon', 'sermon_id');
  update app.content_sermon_revisions r set published_at = now(), published_by_member = v_actor.member_id,
    published_by_account = v_actor.account_id where r.item_id = v_id and r.revision_no = v_no and r.published_at is null;
  return app.content_item_outcome(v_id, 'sermon_id');
end;
$$;

create function app.content_sermon_series_withdraw(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v_actor record; v_id uuid; v_item app.content_items;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'sermon_series') a;
  v_id := app.content_lifecycle_id(p_payload, 'series_id');
  v_item := app.content_item_lock(v_id, 'sermon_series', p_expected_revision, 'series_id');
  perform app.content_item_withdraw(v_item, v_actor.member_id, v_actor.account_id, v_actor.capacity, 'content.withdraw_sermon_series', 'series_id');
  return app.content_item_outcome(v_id, 'series_id');
end;
$$;
create function app.content_sermon_series_archive(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v_actor record; v_id uuid; v_item app.content_items;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'sermon_series') a;
  v_id := app.content_lifecycle_id(p_payload, 'series_id');
  v_item := app.content_item_lock(v_id, 'sermon_series', p_expected_revision, 'series_id');
  perform app.content_item_archive(v_item, v_actor.member_id, v_actor.account_id, v_actor.capacity, 'content.archive_sermon_series');
  return app.content_item_outcome(v_id, 'series_id');
end;
$$;
create function app.content_sermon_withdraw(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v_actor record; v_id uuid; v_item app.content_items;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'sermon') a;
  v_id := app.content_lifecycle_id(p_payload, 'sermon_id');
  v_item := app.content_item_lock(v_id, 'sermon', p_expected_revision, 'sermon_id');
  perform app.content_item_withdraw(v_item, v_actor.member_id, v_actor.account_id, v_actor.capacity, 'content.withdraw_sermon', 'sermon_id');
  return app.content_item_outcome(v_id, 'sermon_id');
end;
$$;
create function app.content_sermon_archive(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v_actor record; v_id uuid; v_item app.content_items;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'sermon') a;
  v_id := app.content_lifecycle_id(p_payload, 'sermon_id');
  v_item := app.content_item_lock(v_id, 'sermon', p_expected_revision, 'sermon_id');
  perform app.content_item_archive(v_item, v_actor.member_id, v_actor.account_id, v_actor.capacity, 'content.archive_sermon');
  return app.content_item_outcome(v_id, 'sermon_id');
end;
$$;

select app.content_register_command('content.create_sermon_series', 'sermon_series', 'app.content_sermon_series_create(uuid,bigint,jsonb)'::regprocedure, true);
select app.content_register_command('content.save_sermon_series', 'sermon_series', 'app.content_sermon_series_save(uuid,bigint,jsonb)'::regprocedure, false);
select app.content_register_command('content.publish_sermon_series', 'sermon_series', 'app.content_sermon_series_publish(uuid,bigint,jsonb)'::regprocedure, false);
select app.content_register_command('content.withdraw_sermon_series', 'sermon_series', 'app.content_sermon_series_withdraw(uuid,bigint,jsonb)'::regprocedure, false);
select app.content_register_command('content.archive_sermon_series', 'sermon_series', 'app.content_sermon_series_archive(uuid,bigint,jsonb)'::regprocedure, false);
select app.content_register_command('content.create_sermon', 'sermon', 'app.content_sermon_create(uuid,bigint,jsonb)'::regprocedure, true);
select app.content_register_command('content.save_sermon', 'sermon', 'app.content_sermon_save(uuid,bigint,jsonb)'::regprocedure, false);
select app.content_register_command('content.publish_sermon', 'sermon', 'app.content_sermon_publish(uuid,bigint,jsonb)'::regprocedure, false);
select app.content_register_command('content.withdraw_sermon', 'sermon', 'app.content_sermon_withdraw(uuid,bigint,jsonb)'::regprocedure, false);
select app.content_register_command('content.archive_sermon', 'sermon', 'app.content_sermon_archive(uuid,bigint,jsonb)'::regprocedure, false);

-- A missing or withdrawn series contributes no metadata. A blocked poster is omitted while
-- church-authored series copy remains public. Rights revisions are metadata, never provenance.
create function app.content_public_sermon_series_json(p_item_id uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'series_id', i.item_id, 'title', r.title, 'description', r.description, 'alt_text', r.alt_text,
    'poster', case when x.poster is not null then x.poster || jsonb_build_object(
      'rights_revision', ri.live_revision_no,
      'offline_allowed', app.content_rights_clear(f.rights_id, 'offline') is null) end,
    'publication_revision', r.revision_no, 'published_at', app.cmd_utc(i.published_at),
    'offline_allowed', true)
  from app.content_items i
  join app.content_sermon_series_revisions r on r.item_id = i.item_id and r.revision_no = i.live_revision_no
  left join app.content_revision_files f on f.item_id = i.item_id and f.revision_no = i.live_revision_no and f.slot = 'poster'
  left join app.content_items ri on ri.item_id = f.rights_id
  cross join lateral (select app.content_public_file(i.item_id, 'poster') as poster) x
  where i.item_id = p_item_id and i.kind = 'sermon_series' and i.lifecycle_state = 'published';
$$;

create function app.content_public_sermon_json(p_item_id uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'sermon_id', i.item_id, 'title', r.title, 'speaker', r.speaker, 'sermon_date', r.sermon_date::text,
    'scripture_reference', r.scripture_reference, 'notes', r.notes,
    'series', app.content_public_sermon_series_json(r.series_id),
    'youtube_video_id', case when app.content_rights_clear(r.video_rights_id, 'display') is null then r.youtube_video_id end,
    'rights_revision', case when r.youtube_video_id is not null and app.content_rights_clear(r.video_rights_id, 'display') is null then ri.live_revision_no end,
    'publication_revision', r.revision_no, 'published_at', app.cmd_utc(i.published_at), 'offline_allowed', true)
  from app.content_items i
  join app.content_sermon_revisions r on r.item_id = i.item_id and r.revision_no = i.live_revision_no
  left join app.content_items ri on ri.item_id = r.video_rights_id
  where i.item_id = p_item_id and i.kind = 'sermon' and i.lifecycle_state = 'published';
$$;

-- The canonical bounded catalog is never filtered on the server. Client searches and offline
-- filters operate over this same complete snapshot (200 sermons and 100 series at most).
create function app.content_public_sermons()
returns jsonb language sql stable security definer set search_path = '' as $$
  with sermons as (
    select i.item_id, row_number() over (order by r.sermon_date desc, i.published_at desc, i.item_id) as rn
    from app.content_items i join app.content_sermon_revisions r on r.item_id = i.item_id and r.revision_no = i.live_revision_no
    where i.kind = 'sermon' and i.lifecycle_state = 'published'
  ), series as (
    select i.item_id, row_number() over (order by i.published_at desc, i.item_id) as rn
    from app.content_items i where i.kind = 'sermon_series' and i.lifecycle_state = 'published'
  )
  select jsonb_build_object(
    'sermons', (select coalesce(jsonb_agg(app.content_public_sermon_json(s.item_id) order by s.rn) filter (where s.rn <= 200), '[]'::jsonb) from sermons s),
    'series', (select coalesce(jsonb_agg(app.content_public_sermon_series_json(s.item_id) order by s.rn) filter (where s.rn <= 100), '[]'::jsonb) from series s),
    'truncated', (select count(*) > 200 from sermons) or (select count(*) > 100 from series));
$$;

create function app.content_public_sermon(p_sermon_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('sermon', app.content_public_sermon_json(p_sermon_id));
$$;
create function api.content_public_sermons()
returns jsonb language sql security invoker set search_path = '' as $$
  select app.content_public_sermons();
$$;
create function api.content_public_sermon(sermon_id uuid)
returns jsonb language sql security invoker set search_path = '' as $$
  select app.content_public_sermon(sermon_id);
$$;
comment on function api.content_public_sermons() is 'Story 6.9: canonical public sermon and series catalog, no drafts or attribution.';
comment on function api.content_public_sermon(uuid) is 'Story 6.9: one current published sermon; an unavailable video never hides its notes.';

create function app.content_sermon_rights_json(p_rights_id uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('rights_id', i.item_id, 'label', coalesce(l.label, d.label),
    'state', i.lifecycle_state, 'live_revision_no', i.live_revision_no,
    'display', app.content_rights_clear(i.item_id, 'display'))
  from app.content_items i
  left join app.content_rights_revisions l on l.item_id = i.item_id and l.revision_no = i.live_revision_no
  left join app.content_rights_revisions d on d.item_id = i.item_id and d.revision_no = i.draft_revision_no
  where i.item_id = p_rights_id and i.kind = 'rights';
$$;
create function app.content_sermon_series_revision_json(p_item_id uuid, p_revision_no integer)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('revision_no', r.revision_no, 'title', r.title, 'description', r.description,
    'alt_text', r.alt_text,
    'poster', (select jsonb_build_object('asset_id', a.asset_id, 'media_type', a.media_type,
      'byte_size', a.byte_size, 'width', a.width, 'height', a.height) from app.content_assets a where a.asset_id = f.asset_id),
    'rights', app.content_sermon_rights_json(f.rights_id), 'saved_at', app.cmd_utc(r.saved_at),
    'saved_by', app.content_editor_name(r.saved_by_member))
  from app.content_sermon_series_revisions r
  left join app.content_revision_files f on f.item_id = r.item_id and f.revision_no = r.revision_no and f.slot = 'poster'
  where r.item_id = p_item_id and r.revision_no = p_revision_no;
$$;
create function app.content_sermon_revision_json(p_item_id uuid, p_revision_no integer)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('revision_no', r.revision_no, 'title', r.title, 'speaker', coalesce(r.speaker, ''),
    'sermon_date', r.sermon_date::text, 'scripture_reference', coalesce(r.scripture_reference, ''),
    'notes', r.notes, 'series_id', r.series_id, 'youtube_video_id', r.youtube_video_id,
    'video_rights', app.content_sermon_rights_json(r.video_rights_id),
    'saved_at', app.cmd_utc(r.saved_at), 'saved_by', app.content_editor_name(r.saved_by_member))
  from app.content_sermon_revisions r where r.item_id = p_item_id and r.revision_no = p_revision_no;
$$;

create function app.content_staff_sermon_series_json(p_item_id uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('series_id', i.item_id, 'revision', i.revision, 'state', i.lifecycle_state,
    'created_at', app.cmd_utc(i.created_at), 'created_by', app.content_editor_name(i.created_by_member),
    'updated_at', app.cmd_utc(i.updated_at), 'published_at', app.cmd_utc(i.published_at),
    'published_by', case when i.published_by_member is not null then app.content_editor_name(i.published_by_member) end,
    'withdrawn_at', app.cmd_utc(i.withdrawn_at), 'archived_at', app.cmd_utc(i.archived_at),
    -- A poster is optional: a published series without one has no image state.
    'public_image', case when i.lifecycle_state = 'published' and exists (
        select 1 from app.content_revision_files pf where pf.item_id = i.item_id
           and pf.revision_no = i.live_revision_no and pf.slot = 'poster' and pf.asset_id is not null)
      then case
      when not exists (select 1 from app.content_live_file(i.item_id, 'poster')) then 'blocked'
      when app.content_public_file(i.item_id, 'poster') is null then 'waiting' else 'shown' end end,
    'live', app.content_sermon_series_revision_json(i.item_id, i.live_revision_no),
    'draft', app.content_sermon_series_revision_json(i.item_id, i.draft_revision_no))
  from app.content_items i where i.item_id = p_item_id and i.kind = 'sermon_series';
$$;
create function app.content_staff_sermon_json(p_item_id uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('sermon_id', i.item_id, 'revision', i.revision, 'state', i.lifecycle_state,
    'created_at', app.cmd_utc(i.created_at), 'created_by', app.content_editor_name(i.created_by_member),
    'updated_at', app.cmd_utc(i.updated_at), 'published_at', app.cmd_utc(i.published_at),
    'published_by', case when i.published_by_member is not null then app.content_editor_name(i.published_by_member) end,
    'withdrawn_at', app.cmd_utc(i.withdrawn_at), 'archived_at', app.cmd_utc(i.archived_at),
    'live', app.content_sermon_revision_json(i.item_id, i.live_revision_no),
    'draft', app.content_sermon_revision_json(i.item_id, i.draft_revision_no))
  from app.content_items i where i.item_id = p_item_id and i.kind = 'sermon';
$$;

-- Every normal sermon draft is returned regardless of who created it or where it originated.
create function app.content_staff_sermons()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_editor record; v_result jsonb;
begin
  select e.* into v_editor from app.content_require_editor('sermon') e;
  with ranked as (
    select i.item_id, row_number() over (order by (i.lifecycle_state = 'archived'), i.updated_at desc, i.item_id) as rn
    from app.content_items i where i.kind = 'sermon')
  select jsonb_build_object('capacity', v_editor.capacity,
    'sermons', coalesce(jsonb_agg(app.content_staff_sermon_json(k.item_id) order by k.rn) filter (where k.rn <= 200), '[]'::jsonb),
    'truncated', count(*) > 200) into v_result from ranked k;
  return v_result;
end;
$$;
create function app.content_staff_sermon_series()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_editor record; v_result jsonb;
begin
  select e.* into v_editor from app.content_require_editor('sermon_series') e;
  with ranked as (
    select i.item_id, row_number() over (order by (i.lifecycle_state = 'archived'), i.updated_at desc, i.item_id) as rn
    from app.content_items i where i.kind = 'sermon_series')
  select jsonb_build_object('capacity', v_editor.capacity,
    'series', coalesce(jsonb_agg(app.content_staff_sermon_series_json(k.item_id) order by k.rn) filter (where k.rn <= 200), '[]'::jsonb),
    'removals_pending', (select count(*) from app.content_public_removals()),
    'truncated', count(*) > 200) into v_result from ranked k;
  return v_result;
end;
$$;
create function api.content_staff_sermons()
returns jsonb language sql security invoker set search_path = '' as $$ select app.content_staff_sermons(); $$;
create function api.content_staff_sermon_series()
returns jsonb language sql security invoker set search_path = '' as $$ select app.content_staff_sermon_series(); $$;
comment on function api.content_staff_sermons() is 'Story 6.9: all sermon drafts and live revisions, for Media, Pastor and Admin.';
comment on function api.content_staff_sermon_series() is 'Story 6.9: series drafts and live revisions with rights and file state, for editors.';

create function app.content_sermon_erase_part(p_input jsonb)
returns integer language plpgsql set search_path = '' as $$
declare v_member uuid := (p_input ->> 'member_id')::uuid;
  v_account uuid := nullif(p_input ->> 'account_id', '')::uuid;
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
begin
  if p_input ->> 'phase' = 'erase' then
    update app.content_sermon_revisions set saved_by_member = v_nil where saved_by_member = v_member;
    update app.content_sermon_revisions set published_by_member = v_nil where published_by_member = v_member;
    if v_account is not null then
      update app.content_sermon_revisions set saved_by_account = v_nil where saved_by_account = v_account;
      update app.content_sermon_revisions set published_by_account = v_nil where published_by_account = v_account;
    end if;
  end if;
  return (select count(*) from app.content_sermon_revisions r where r.saved_by_member = v_member
    or r.published_by_member = v_member or r.saved_by_account = v_account or r.published_by_account = v_account)::integer;
end;
$$;
create function app.content_sermon_series_erase_part(p_input jsonb)
returns integer language plpgsql set search_path = '' as $$
declare v_member uuid := (p_input ->> 'member_id')::uuid;
  v_account uuid := nullif(p_input ->> 'account_id', '')::uuid;
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
begin
  if p_input ->> 'phase' = 'erase' then
    update app.content_sermon_series_revisions set saved_by_member = v_nil where saved_by_member = v_member;
    update app.content_sermon_series_revisions set published_by_member = v_nil where published_by_member = v_member;
    if v_account is not null then
      update app.content_sermon_series_revisions set saved_by_account = v_nil where saved_by_account = v_account;
      update app.content_sermon_series_revisions set published_by_account = v_nil where published_by_account = v_account;
    end if;
  end if;
  return (select count(*) from app.content_sermon_series_revisions r where r.saved_by_member = v_member
    or r.published_by_member = v_member or r.saved_by_account = v_account or r.published_by_account = v_account)::integer;
end;
$$;
select app.content_register_erase_part('sermon_revisions', 'app.content_sermon_erase_part(jsonb)'::regprocedure);
select app.content_register_erase_part('sermon_series_revisions', 'app.content_sermon_series_erase_part(jsonb)'::regprocedure);

revoke all on function app.content_sermon_link_ok(text), app.content_sermon_notes_error(text),
  app.content_sermon_series_revision_guard(), app.content_sermon_revision_guard(),
  app.content_sermon_series_fields(jsonb), app.content_sermon_fields(jsonb),
  app.content_sermon_series_create(uuid,bigint,jsonb), app.content_sermon_series_save(uuid,bigint,jsonb),
  app.content_sermon_series_publish(uuid,bigint,jsonb), app.content_sermon_series_withdraw(uuid,bigint,jsonb),
  app.content_sermon_series_archive(uuid,bigint,jsonb), app.content_sermon_create(uuid,bigint,jsonb),
  app.content_sermon_save(uuid,bigint,jsonb), app.content_sermon_publish(uuid,bigint,jsonb),
  app.content_sermon_withdraw(uuid,bigint,jsonb), app.content_sermon_archive(uuid,bigint,jsonb),
  app.content_public_sermon_series_json(uuid), app.content_public_sermon_json(uuid),
  app.content_public_sermons(), app.content_public_sermon(uuid),
  api.content_public_sermons(), api.content_public_sermon(uuid),
  app.content_sermon_rights_json(uuid), app.content_sermon_series_revision_json(uuid,integer),
  app.content_sermon_revision_json(uuid,integer), app.content_staff_sermon_series_json(uuid),
  app.content_staff_sermon_json(uuid), app.content_staff_sermons(), app.content_staff_sermon_series(),
  api.content_staff_sermons(), api.content_staff_sermon_series(),
  app.content_sermon_erase_part(jsonb), app.content_sermon_series_erase_part(jsonb)
  from public, anon, authenticated, service_role;
grant execute on function app.content_public_sermons(), api.content_public_sermons(),
  app.content_public_sermon(uuid), api.content_public_sermon(uuid) to anon, authenticated;
grant execute on function app.content_staff_sermons(), api.content_staff_sermons(),
  app.content_staff_sermon_series(), api.content_staff_sermon_series() to authenticated;

notify pgrst, 'reload schema';
