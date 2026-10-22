-- Story 6.4: state the public offline decision in each anonymous projection.
-- Only the two mobile list projections are cached; the event detail keeps its
-- public shape plus the same church-authored eligibility flag.

create or replace function app.content_public_event_json(p_item_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'event_id', i.item_id,
    'title', r.title,
    'description', r.description,
    'starts_at', app.cmd_utc(r.starts_at),
    'ends_at', app.cmd_utc(r.ends_at),
    'location', r.location,
    'publication_revision', r.revision_no,
    'published_at', app.cmd_utc(i.published_at),
    'offline_allowed', true)
    from app.content_items i
    join app.content_event_revisions r on r.item_id = i.item_id and r.revision_no = i.live_revision_no
   where i.item_id = p_item_id and i.kind = 'event' and i.lifecycle_state = 'published'
     and r.ends_at > now();
$$;

create or replace function app.content_public_banner_json(p_item_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'banner_id', i.item_id,
    'banner_kind', r.banner_kind,
    'theme_year', r.theme_year,
    'title', r.title,
    'subtitle', r.subtitle,
    'alt_text', r.alt_text,
    'event_id', r.event_id,
    'image', x.image,
    'publication_revision', r.revision_no,
    'rights_revision', rights.live_revision_no,
    'published_at', app.cmd_utc(i.published_at),
    'offline_allowed', rights.offline_allowed)
    from app.content_items i
    join app.content_banner_revisions r on r.item_id = i.item_id and r.revision_no = i.live_revision_no
   cross join lateral (select app.content_public_file(i.item_id, 'image') as image) x
   cross join lateral (
     select ri.live_revision_no,
            app.content_rights_clear(f.rights_id, 'offline') is null as offline_allowed
       from app.content_revision_files f
       join app.content_items ri on ri.item_id = f.rights_id
      where f.item_id = i.item_id and f.revision_no = i.live_revision_no and f.slot = 'image'
   ) rights
   where i.item_id = p_item_id and i.kind = 'banner' and i.lifecycle_state = 'published'
     and x.image is not null
     and app.content_banner_public_condition(jsonb_build_object('item_id', i.item_id));
$$;

comment on function app.content_public_event_json(uuid) is
  'Story 6.4: the current public event projection; church-authored events are offline eligible.';
comment on function app.content_public_banner_json(uuid) is
  'Story 6.4: the current public banner projection with offline eligibility from its live image rights.';
