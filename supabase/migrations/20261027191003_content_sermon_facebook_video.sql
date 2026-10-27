-- Story 6.10: a sermon's video may be a public Facebook video or live broadcast instead of a
-- YouTube video (owner decision 2026-10-27: background audio is descoped; sermons start with
-- video links only). Extends the sermon kind of story 6.9; its own sermon functions are replaced
-- in place (same signatures and privileges) and one validator is added:
--
--   * app.content_sermon_revisions gains facebook_video_url, stored only in a canonical form, and
--     a check that a revision has at most one video source (YouTube or Facebook).
--   * app.content_sermon_facebook_url validates a pasted link against an exact allowlist and
--     normalises it. Hosts: facebook.com, www.facebook.com, m.facebook.com, web.facebook.com and
--     fb.watch; https only, no userinfo, port or encoded path. Forms and their stored value:
--       facebook.com/<page>/videos/<id>          -> https://www.facebook.com/<page>/videos/<id>/
--       facebook.com/watch?v=<id> (also /watch/live/?v=<id>)
--                                                -> https://www.facebook.com/watch/?v=<id>
--       fb.watch/<code>                          -> https://fb.watch/<code>/
--     Query strings and fragments of the accepted forms (share tracking) are dropped.
--     facebook.com/<page>/live (and /live_videos) names a page's broadcasts, not one video:
--     Facebook's embedded player cannot play it, so it is refused as not_embeddable; the live
--     broadcast's own /videos/<id> link plays live and afterwards as its recording.
--   * The same rights check as YouTube: publishing a revision with either source needs a
--     verified rights record that clears display, and the public projection names the link only
--     while that record still clears display. Withdrawn clearance keeps the notes readable.
--   * The public sermon projection gains facebook_video_url; the staff revision gains it too.
--
-- No server requests to Facebook, no destructive statements, no row deletions, no policy
-- approvals. ASCII only, no backslashes.

alter table app.content_sermon_revisions
  add column facebook_video_url text
    check (facebook_video_url ~ ('^https://(www[.]facebook[.]com/([A-Za-z0-9][A-Za-z0-9.-]{0,99}/videos/[0-9]{5,25}/'
      || '|watch/[?]v=[0-9]{5,25})|fb[.]watch/[A-Za-z0-9_-]{5,32}/)$')),
  add constraint content_sermon_revisions_one_video_source
    check (num_nonnulls(youtube_video_id, facebook_video_url) <= 1);

comment on column app.content_sermon_revisions.facebook_video_url is
  'Story 6.10: a public Facebook video or live broadcast in canonical form; at most one video source per revision.';

-- Validates and normalises a pasted Facebook link. Returns (null, null) for an absent or blank
-- value; errors: invalid (not text or a malformed link), not_facebook (another host),
-- not_embeddable (a page's /live address), too_long.
create function app.content_sermon_facebook_url(p_value jsonb, out error text, out value text)
language plpgsql immutable set search_path = '' as $$
declare v_raw text; v_m text[]; v_host text; v_path text; v_query text; v_ids text[];
begin
  select t.error, t.value into error, v_raw from app.content_free_text(p_value, 500, false) t;
  if error is not null or v_raw is null then return; end if;
  v_m := regexp_match(v_raw,
    '^https://([A-Za-z0-9.-]+)(/[A-Za-z0-9._/-]*)?([?][A-Za-z0-9._~%=&+-]*)?(#[A-Za-z0-9._~%=&+/-]*)?$');
  if v_m is null then error := 'invalid'; return; end if;
  v_host := lower(v_m[1]);
  v_path := coalesce(v_m[2], '/');
  v_query := coalesce(substr(v_m[3], 2), '');
  if v_host = 'fb.watch' then
    v_m := regexp_match(v_path, '^/([A-Za-z0-9_-]{5,32})/?$');
    if v_m is null then error := 'invalid'; return; end if;
    value := 'https://fb.watch/' || v_m[1] || '/';
    return;
  end if;
  if v_host not in ('facebook.com', 'www.facebook.com', 'm.facebook.com', 'web.facebook.com') then
    error := 'not_facebook';
    return;
  end if;
  if v_path ~ '^/watch(/live)?/?$' then
    select array_agg(x[2]) into v_ids
      from regexp_matches(v_query, '(^|&)v=([^&]*)', 'g') x;
    if coalesce(array_length(v_ids, 1), 0) <> 1 or v_ids[1] !~ '^[0-9]{5,25}$' then
      error := 'invalid';
      return;
    end if;
    value := 'https://www.facebook.com/watch/?v=' || v_ids[1];
    return;
  end if;
  v_m := regexp_match(v_path, '^/([A-Za-z0-9][A-Za-z0-9.-]{0,99})/videos/([0-9]{5,25})/?$');
  if v_m is not null then
    value := 'https://www.facebook.com/' || v_m[1] || '/videos/' || v_m[2] || '/';
    return;
  end if;
  if v_path ~ '^/[A-Za-z0-9][A-Za-z0-9.-]{0,99}/live(_videos)?/?$' then
    error := 'not_embeddable';
    return;
  end if;
  error := 'invalid';
end;
$$;

-- (Replaced; from 20261027083618_content_sermons.sql.) The Facebook link is content too.
create or replace function app.content_sermon_revision_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.published_at is not null and
     (new.item_id, new.revision_no, new.title, new.speaker, new.sermon_date,
      new.scripture_reference, new.notes, new.series_id, new.youtube_video_id,
      new.facebook_video_url, new.video_rights_id, new.saved_at, new.published_at) is distinct from
     (old.item_id, old.revision_no, old.title, old.speaker, old.sermon_date,
      old.scripture_reference, old.notes, old.series_id, old.youtube_video_id,
      old.facebook_video_url, old.video_rights_id, old.saved_at, old.published_at) then
    raise exception using errcode = 'PCNT1', message = 'a published content revision is immutable';
  end if;
  return new;
end;
$$;

-- (Replaced; from 20261027083618_content_sermons.sql.) Accepts facebook_video_url; a draft has at
-- most one video source.
create or replace function app.content_sermon_create(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v_actor record; v_fields record; v_errors jsonb; v_error text; v_facebook text; v_id uuid;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'sermon') a;
  v_errors := app.contract_unknown_keys(p_payload, array['title', 'speaker', 'sermon_date', 'scripture_reference', 'notes', 'series_id', 'youtube_video_id', 'facebook_video_url', 'video_rights_id']);
  select f.* into v_fields from app.content_sermon_fields(p_payload) f;
  v_errors := v_errors || v_fields.errors;
  select t.error, t.value into v_error, v_facebook from app.content_sermon_facebook_url(p_payload -> 'facebook_video_url') t;
  if v_error is null and v_facebook is not null and v_fields.youtube_video_id is not null then v_error := 'one_source'; end if;
  if v_error is not null then v_errors := v_errors || jsonb_build_object('facebook_video_url', v_error); end if;
  if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed', v_errors); end if;
  v_id := app.content_item_open('sermon', v_actor.member_id, v_actor.account_id, v_actor.capacity, 'content.create_sermon');
  insert into app.content_sermon_revisions (item_id, revision_no, title, speaker, sermon_date, scripture_reference,
    notes, series_id, youtube_video_id, facebook_video_url, video_rights_id, saved_by_member, saved_by_account)
  values (v_id, 1, v_fields.title, v_fields.speaker, v_fields.sermon_date, v_fields.scripture_reference,
    v_fields.notes, v_fields.series_id, v_fields.youtube_video_id, v_facebook, v_fields.video_rights_id,
    v_actor.member_id, v_actor.account_id);
  return app.content_item_outcome(v_id, 'sermon_id');
end;
$$;

-- (Replaced; from 20261027083618_content_sermons.sql.) As content_sermon_create.
create or replace function app.content_sermon_save(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v_actor record; v_fields record; v_errors jsonb; v_error text; v_facebook text; v_id uuid;
  v_item app.content_items; v_no integer;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'sermon') a;
  v_errors := app.contract_unknown_keys(p_payload, array['sermon_id', 'title', 'speaker', 'sermon_date', 'scripture_reference', 'notes', 'series_id', 'youtube_video_id', 'facebook_video_url', 'video_rights_id']);
  select t.error, t.value into v_error, v_id from app.content_payload_uuid(p_payload, 'sermon_id') t;
  if v_error is not null then v_errors := v_errors || jsonb_build_object('sermon_id', v_error); end if;
  select f.* into v_fields from app.content_sermon_fields(p_payload) f;
  v_errors := v_errors || v_fields.errors;
  select t.error, t.value into v_error, v_facebook from app.content_sermon_facebook_url(p_payload -> 'facebook_video_url') t;
  if v_error is null and v_facebook is not null and v_fields.youtube_video_id is not null then v_error := 'one_source'; end if;
  if v_error is not null then v_errors := v_errors || jsonb_build_object('facebook_video_url', v_error); end if;
  if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed', v_errors); end if;
  v_item := app.content_item_lock(v_id, 'sermon', p_expected_revision, 'sermon_id');
  v_no := app.content_item_draft_no(v_item);
  insert into app.content_sermon_revisions as r (item_id, revision_no, title, speaker, sermon_date, scripture_reference,
    notes, series_id, youtube_video_id, facebook_video_url, video_rights_id, saved_by_member, saved_by_account)
  values (v_id, v_no, v_fields.title, v_fields.speaker, v_fields.sermon_date, v_fields.scripture_reference,
    v_fields.notes, v_fields.series_id, v_fields.youtube_video_id, v_facebook, v_fields.video_rights_id,
    v_actor.member_id, v_actor.account_id)
  on conflict (item_id, revision_no) do update set title = excluded.title, speaker = excluded.speaker,
    sermon_date = excluded.sermon_date, scripture_reference = excluded.scripture_reference, notes = excluded.notes,
    series_id = excluded.series_id, youtube_video_id = excluded.youtube_video_id,
    facebook_video_url = excluded.facebook_video_url, video_rights_id = excluded.video_rights_id,
    saved_by_member = excluded.saved_by_member, saved_by_account = excluded.saved_by_account, saved_at = now()
  where r.published_at is null;
  perform app.content_item_saved(v_item, v_no, v_actor.member_id, v_actor.account_id, v_actor.capacity, 'content.save_sermon');
  return app.content_item_outcome(v_id, 'sermon_id');
end;
$$;

-- (Replaced; from 20261027083618_content_sermons.sql.) Either video source needs display rights.
create or replace function app.content_sermon_publish(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
    if v_rev.youtube_video_id is not null or v_rev.facebook_video_url is not null then
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

-- (Replaced; from 20261027083618_content_sermons.sql.) The Facebook link is public only while its
-- rights record clears display, exactly as the YouTube id.
create or replace function app.content_public_sermon_json(p_item_id uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'sermon_id', i.item_id, 'title', r.title, 'speaker', r.speaker, 'sermon_date', r.sermon_date::text,
    'scripture_reference', r.scripture_reference, 'notes', r.notes,
    'series', app.content_public_sermon_series_json(r.series_id),
    'youtube_video_id', case when app.content_rights_clear(r.video_rights_id, 'display') is null then r.youtube_video_id end,
    'facebook_video_url', case when app.content_rights_clear(r.video_rights_id, 'display') is null then r.facebook_video_url end,
    'rights_revision', case when (r.youtube_video_id is not null or r.facebook_video_url is not null)
      and app.content_rights_clear(r.video_rights_id, 'display') is null then ri.live_revision_no end,
    'publication_revision', r.revision_no, 'published_at', app.cmd_utc(i.published_at), 'offline_allowed', true)
  from app.content_items i
  join app.content_sermon_revisions r on r.item_id = i.item_id and r.revision_no = i.live_revision_no
  left join app.content_items ri on ri.item_id = r.video_rights_id
  where i.item_id = p_item_id and i.kind = 'sermon' and i.lifecycle_state = 'published';
$$;

-- (Replaced; from 20261027083618_content_sermons.sql.) Editors see the stored Facebook link.
create or replace function app.content_sermon_revision_json(p_item_id uuid, p_revision_no integer)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('revision_no', r.revision_no, 'title', r.title, 'speaker', coalesce(r.speaker, ''),
    'sermon_date', r.sermon_date::text, 'scripture_reference', coalesce(r.scripture_reference, ''),
    'notes', r.notes, 'series_id', r.series_id, 'youtube_video_id', r.youtube_video_id,
    'facebook_video_url', r.facebook_video_url,
    'video_rights', app.content_sermon_rights_json(r.video_rights_id),
    'saved_at', app.cmd_utc(r.saved_at), 'saved_by', app.content_editor_name(r.saved_by_member))
  from app.content_sermon_revisions r where r.item_id = p_item_id and r.revision_no = p_revision_no;
$$;

revoke all on function app.content_sermon_facebook_url(jsonb) from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
