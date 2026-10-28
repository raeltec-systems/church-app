-- Epic 6 entry 14 (K5): the top-bar search read, api.content_public_search(query).
--
-- One bounded anonymous read over the published sermons, events and announcements. It returns
-- each match through the kind's existing public projection (app.content_public_sermon_json,
-- app.content_public_event_json, app.content_public_announcement_json), so search shows exactly
-- what the lists and details show: never a draft, a withdrawn or archived item, an ended event,
-- an editor, a name or a member id. Hymns are not on the server (the hymn book is built into the
-- app, entry 7) and Bible text is not searched (epic Notes).
--
--   * Query: trimmed, runs of white space folded to one space, 2 to 100 characters, else
--     22023 `invalid` (detail `query`). Lower-cased and split on spaces; at most the first 8
--     words count. An item matches when its text contains every word (plain substring, no
--     pattern characters, so % and _ match themselves).
--   * Text searched: sermon title, speaker, scripture reference, notes and its published series'
--     title; event title, description and location; announcement title and body.
--   * Ranking per kind: the whole query in the title first, then every word in the title, then
--     the rest; ties keep the kind's own order (sermons newest first, events soonest first,
--     announcements pinned first and then newest).
--   * Page size: at most 10 per kind; `truncated` says a kind had more.
--
-- Registers no command, table or erase part (a read keeps nothing). No destructive statement.
-- ASCII only.

create function app.content_public_search(p_query text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_query text := btrim(regexp_replace(coalesce(p_query, ''), '[[:space:]]+', ' ', 'g'));
  v_lower text;
  v_terms text[];
  v_limit constant integer := 10;
  v_sermons jsonb;
  v_events jsonb;
  v_announcements jsonb;
  v_more boolean := false;
  v_count integer;
begin
  if char_length(v_query) < 2 or char_length(v_query) > 100 then
    raise exception using errcode = '22023', message = 'invalid', detail = 'query';
  end if;
  v_lower := lower(v_query);
  v_terms := (string_to_array(v_lower, ' '))[1:8];

  -- Sermons (published), with the published series title.
  with live as (
    select i.item_id,
           lower(r.title) as title,
           lower(concat_ws(' ', r.title, r.speaker, r.scripture_reference, r.notes,
                           sr.title)) as body,
           r.sermon_date, i.published_at
      from app.content_items i
      join app.content_sermon_revisions r
        on r.item_id = i.item_id and r.revision_no = i.live_revision_no
      left join app.content_items si
        on si.item_id = r.series_id and si.kind = 'sermon_series'
       and si.lifecycle_state = 'published'
      left join app.content_sermon_series_revisions sr
        on sr.item_id = si.item_id and sr.revision_no = si.live_revision_no
     where i.kind = 'sermon' and i.lifecycle_state = 'published'),
  hit as (
    select l.item_id,
           row_number() over (
             order by case when strpos(l.title, v_lower) > 0 then 0
                           when not exists (select 1 from unnest(v_terms) t
                                             where strpos(l.title, t) = 0) then 1
                           else 2 end,
                      l.sermon_date desc nulls last, l.published_at desc, l.item_id) as rn
      from live l
     where not exists (select 1 from unnest(v_terms) t where strpos(l.body, t) = 0))
  select coalesce(jsonb_agg(app.content_public_sermon_json(h.item_id) order by h.rn)
                    filter (where h.rn <= v_limit), '[]'::jsonb),
         count(*)
    into v_sermons, v_count
    from hit h;
  v_more := v_more or v_count > v_limit;

  -- Events (published and not ended).
  with live as (
    select i.item_id,
           lower(r.title) as title,
           lower(concat_ws(' ', r.title, r.description, r.location)) as body,
           r.starts_at
      from app.content_items i
      join app.content_event_revisions r
        on r.item_id = i.item_id and r.revision_no = i.live_revision_no
     where i.kind = 'event' and i.lifecycle_state = 'published' and r.ends_at > now()),
  hit as (
    select l.item_id,
           row_number() over (
             order by case when strpos(l.title, v_lower) > 0 then 0
                           when not exists (select 1 from unnest(v_terms) t
                                             where strpos(l.title, t) = 0) then 1
                           else 2 end,
                      l.starts_at, l.item_id) as rn
      from live l
     where not exists (select 1 from unnest(v_terms) t where strpos(l.body, t) = 0))
  select coalesce(jsonb_agg(app.content_public_event_json(h.item_id) order by h.rn)
                    filter (where h.rn <= v_limit), '[]'::jsonb),
         count(*)
    into v_events, v_count
    from hit h;
  v_more := v_more or v_count > v_limit;

  -- Announcements (published).
  with live as (
    select i.item_id,
           lower(r.title) as title,
           lower(concat_ws(' ', r.title, r.body)) as body,
           r.pinned, i.published_at
      from app.content_items i
      join app.content_announcement_revisions r
        on r.item_id = i.item_id and r.revision_no = i.live_revision_no
     where i.kind = 'announcement' and i.lifecycle_state = 'published'),
  hit as (
    select l.item_id,
           row_number() over (
             order by case when strpos(l.title, v_lower) > 0 then 0
                           when not exists (select 1 from unnest(v_terms) t
                                             where strpos(l.title, t) = 0) then 1
                           else 2 end,
                      l.pinned desc, l.published_at desc, l.item_id) as rn
      from live l
     where not exists (select 1 from unnest(v_terms) t where strpos(l.body, t) = 0))
  select coalesce(jsonb_agg(app.content_public_announcement_json(h.item_id) order by h.rn)
                    filter (where h.rn <= v_limit), '[]'::jsonb),
         count(*)
    into v_announcements, v_count
    from hit h;
  v_more := v_more or v_count > v_limit;

  return jsonb_build_object(
    'query', v_query,
    'sermons', v_sermons,
    'events', v_events,
    'announcements', v_announcements,
    'truncated', v_more);
end;
$$;

comment on function app.content_public_search(text) is
  'Story 6.14: the bounded public search over published sermons, events and announcements, '
  'through their public projections; at most 10 per kind.';

create function api.content_public_search(query text)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select app.content_public_search($1);
$$;

comment on function api.content_public_search(text) is
  'Story 6.14, public (anon and authenticated): search the published sermons, events and '
  'announcements (at most 10 of each).';

revoke all on function app.content_public_search(text) from public, anon, authenticated, service_role;
revoke all on function api.content_public_search(text) from public, anon, authenticated, service_role;
grant execute on function app.content_public_search(text) to anon, authenticated;
grant execute on function api.content_public_search(text) to anon, authenticated;

notify pgrst, 'reload schema';
