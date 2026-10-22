-- Publish Home banners with validated images through the public asset path (story 6.2; AD-2,
-- AD-4, AD-13, AD-14, AD-15, AD-17, AD-19).
--
-- Extends story 6.1's Content owner through its registries only (kinds, commands, erase parts);
-- the lifecycle helper, dispatch, authorizer, replay recheck and deletion hook are unchanged.
--
--   * Rights registry: kind `rights` (Admin, Pastor, Media). A rights record is a content item
--     whose revisions hold the source key, label, holder, basis (public domain, licence,
--     permission, church-owned), the cleared uses (display, offline, audio) and the evidence.
--     Verifying a revision is the lifecycle's publish: the verifier and the date are that
--     revision's publish attribution, and a re-verified revision replaces the one in force.
--     Withdraw suspends a record, archive retires it.
--   * The rights check app.content_rights_clear(rights_id, use), which kinds with third-party
--     material call beside the lifecycle helper: the record must be in force, its live revision
--     must clear the use, and its source key must be listed with that use in the effective value
--     of the new policy gate `q5_content_rights` ({"sources": {"<source_key>": [uses]}}). The gate
--     is closed in production until Israel approves it; local and staging read a labelled
--     fixture listing only SYNTHETIC and public-domain sources. Following the epic's assumption on
--     the open Q4/Q5 consent question, every file is gated this way whatever its basis.
--   * The asset path. Two Storage buckets are rows in storage.buckets: `content-drafts`
--     (private) and `content-public` (public). No policy, function, trigger or table is added to
--     the storage schema (AD-2), so no client role can read, list or write either bucket through
--     Storage; the public bucket serves only /object/public/content-public/<path>. The Edge
--     function `content-assets` measures an upload (type from the bytes, size, dimensions),
--     asks this database to authorise it under the editor's live session
--     (content.begin_asset_upload), stores the bytes in `content-drafts` with the platform's
--     service key and confirms them (content.complete_asset_upload, which reads storage.objects).
--     Upload limits live in the purpose registry app.content_asset_purposes.
--   * Files on revisions: app.content_revision_files attaches an asset and its rights record to
--     a slot of a content revision; only the open draft's rows can change. The desired public
--     set is every file of a published item's live revision whose asset is ready and whose
--     rights clear the purpose's use, under the revision-keyed path
--     <kind>/<item_id>/r<revision_no>/<slot>.<ext>. The Edge function's sync places the missing
--     ones (api.content_file_plan) and removes every public object outside the set; a public
--     projection names a file only once its object is present in `content-public`.
--   * Per-kind public conditions (app.content_public_conditions): a published item's files stay
--     public only while its kind's condition holds; banners register theirs (a campaign linked to
--     an event only while that event is public).
--   * Home banners: kind `banner` (Admin, Pastor, Media), the yearly theme or a campaign,
--     optionally linked to an event; content.create_banner, save_banner, publish_banner,
--     withdraw_banner, archive_banner; the anonymous api.content_public_banners() and the
--     editors' api.content_staff_banners() and api.content_staff_rights().
--   * Erase parts for rights revisions, banner revisions and asset uploads (attribution becomes
--     the nil UUID; no row deletion, so no _rows file).
--
-- Lock order (AD-2): the actor's role grants FOR SHARE (authorizer) -> command receipt -> content
-- item FOR UPDATE (lifecycle) or FOR SHARE (uploads) -> asset row FOR UPDATE.
--
-- No destructive statements and no row deletions. ASCII only, no backslashes.

-- ---------------------------------------------------------------------------------------------
-- Kinds, the Q5 gate and the buckets
-- ---------------------------------------------------------------------------------------------

insert into app.content_kinds (kind, editor_roles, description) values
  ('rights', array['admin', 'pastor', 'media'],
   'Rights records for files and third-party text (story 6.2)'),
  ('banner', array['admin', 'pastor', 'media'],
   'Home banners: the yearly theme and campaigns (story 6.2)'),
  ('asset', array['admin', 'pastor', 'media'],
   'Uploads into the private draft area; the target item kind decides who may (story 6.2)');

insert into app.policy_gates (gate, decision_ref, description, fixture_value) values
  ('q5_content_rights', 'Q5',
   'Bible translation, hymn book, lyric, recording, image and offline distribution rights; '
   'gates publishing any file or third-party text that cites a rights record',
   '{"fixture_label": "TEST FIXTURE - SYNTHETIC and public-domain sources only, not church clearance", '
   '"sources": {"synthetic": ["display", "offline", "audio"], "kjv": ["display", "offline"], '
   '"web": ["display", "offline"]}}');

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('content-drafts', 'content-drafts', false, 10485760,
   array['image/png', 'image/jpeg', 'image/webp']),
  ('content-public', 'content-public', true, 10485760,
   array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

create table app.content_rights_revisions (
  item_id uuid not null references app.content_items (item_id),
  revision_no integer not null check (revision_no >= 1),
  label text not null check (length(label) between 1 and 120 and label ~ '[^[:space:]]'),
  source_key text not null check (source_key ~ '^[a-z0-9][a-z0-9-]{1,40}$'),
  holder text not null check (length(holder) between 1 and 160 and holder ~ '[^[:space:]]'),
  basis text not null check (basis in ('public_domain', 'licence', 'permission', 'church_owned')),
  clears_display boolean not null,
  clears_offline boolean not null,
  clears_audio boolean not null,
  evidence text not null check (length(evidence) between 1 and 1000 and evidence ~ '[^[:space:]]'),
  saved_by_member uuid not null,
  saved_by_account uuid not null,
  saved_at timestamptz not null default now(),
  published_at timestamptz,
  published_by_member uuid,
  published_by_account uuid,
  primary key (item_id, revision_no),
  check (clears_display or clears_offline or clears_audio),
  check ((published_at is null) = (published_by_member is null)
         and (published_by_member is null) = (published_by_account is null))
);

comment on table app.content_rights_revisions is
  'owner: content. Rights record revisions (story 6.2): a verified revision is immutable (only its '
  'attribution can be anonymised); its publish attribution is the verifier and the date.';

create table app.content_banner_revisions (
  item_id uuid not null references app.content_items (item_id),
  revision_no integer not null check (revision_no >= 1),
  banner_kind text not null check (banner_kind in ('theme', 'campaign')),
  theme_year integer check (theme_year between 2000 and 2100),
  title text not null check (length(title) between 1 and 80 and title ~ '[^[:space:]]'),
  subtitle text check (subtitle is null or (length(subtitle) between 1 and 120
                                             and subtitle ~ '[^[:space:]]')),
  alt_text text not null check (length(alt_text) between 1 and 250 and alt_text ~ '[^[:space:]]'),
  event_id uuid references app.content_items (item_id),
  saved_by_member uuid not null,
  saved_by_account uuid not null,
  saved_at timestamptz not null default now(),
  published_at timestamptz,
  published_by_member uuid,
  published_by_account uuid,
  primary key (item_id, revision_no),
  check ((banner_kind = 'theme') = (theme_year is not null)),
  check (banner_kind = 'campaign' or event_id is null),
  check ((published_at is null) = (published_by_member is null)
         and (published_by_member is null) = (published_by_account is null))
);

comment on table app.content_banner_revisions is
  'owner: content. Home banner revisions (story 6.2); the image is a file slot '
  '(app.content_revision_files, slot image).';

-- Media types the asset path stores, with the file extension of their paths.
create table app.content_media_types (
  media_type text primary key check (media_type ~ '^[a-z]+/[a-z0-9.+-]+$'),
  extension text not null unique check (extension ~ '^[a-z0-9]{2,5}$'),
  registered_at timestamptz not null default now()
);

comment on table app.content_media_types is
  'owner: content. Media types of uploaded files and their path extensions (story 6.2).';

insert into app.content_media_types (media_type, extension) values
  ('image/png', 'png'), ('image/jpeg', 'jpg'), ('image/webp', 'webp');

-- What an upload is for: the kind whose editors may upload it, the rights use its publication
-- needs, and the limits the server checks.
create table app.content_asset_purposes (
  purpose text primary key check (purpose ~ '^[a-z][a-z0-9_]{0,40}$'),
  kind text not null references app.content_kinds (kind),
  rights_use text not null check (rights_use in ('display', 'offline', 'audio')),
  media_types text[] not null check (cardinality(media_types) between 1 and 8),
  max_bytes bigint not null check (max_bytes between 1 and 10485760),
  min_width integer not null check (min_width >= 1),
  min_height integer not null check (min_height >= 1),
  max_width integer not null check (max_width <= 20000),
  max_height integer not null check (max_height <= 20000),
  min_ratio numeric not null check (min_ratio > 0),
  max_ratio numeric not null,
  description text not null check (length(btrim(description)) between 1 and 200),
  registered_at timestamptz not null default now(),
  check (max_width >= min_width and max_height >= min_height and max_ratio >= min_ratio)
);

comment on table app.content_asset_purposes is
  'owner: content. Upload purposes and their limits (story 6.2); later kinds add rows.';

insert into app.content_asset_purposes (purpose, kind, rights_use, media_types, max_bytes,
                                        min_width, min_height, max_width, max_height, min_ratio,
                                        max_ratio, description) values
  ('banner_image', 'banner', 'display', array['image/png', 'image/jpeg', 'image/webp'], 5242880,
   960, 540, 6000, 6000, 1.30, 2.40, 'A Home banner image, shown 16:9 (story 6.2)');

-- An uploaded file in the private draft area, for one content item.
create table app.content_assets (
  asset_id uuid primary key,
  item_id uuid not null references app.content_items (item_id),
  purpose text not null references app.content_asset_purposes (purpose),
  state text not null default 'pending' check (state in ('pending', 'ready')),
  media_type text not null references app.content_media_types (media_type),
  byte_size bigint not null check (byte_size between 1 and 10485760),
  width integer not null check (width between 1 and 20000),
  height integer not null check (height between 1 and 20000),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  draft_path text not null unique check (draft_path ~ '^[0-9a-f-]{36}[.][a-z0-9]{2,5}$'),
  uploaded_by_member uuid not null,
  uploaded_by_account uuid not null,
  created_at timestamptz not null default now(),
  ready_at timestamptz,
  check ((state = 'ready') = (ready_at is not null))
);

create index content_assets_item on app.content_assets (item_id);

comment on table app.content_assets is
  'owner: content. Uploads in the private content-drafts bucket (story 6.2): pending until the '
  'database has seen the stored object, then ready. Never public by themselves.';

-- The files of a content revision: one asset and its rights record per slot. Only the item's
-- open draft revision can change (published revisions are immutable).
create table app.content_revision_files (
  item_id uuid not null references app.content_items (item_id),
  revision_no integer not null check (revision_no >= 1),
  slot text not null check (slot ~ '^[a-z][a-z0-9_]{0,30}$'),
  purpose text not null references app.content_asset_purposes (purpose),
  asset_id uuid references app.content_assets (asset_id),
  rights_id uuid references app.content_items (item_id),
  updated_at timestamptz not null default now(),
  primary key (item_id, revision_no, slot)
);

create index content_revision_files_asset on app.content_revision_files (asset_id);
create index content_revision_files_rights on app.content_revision_files (rights_id);

comment on table app.content_revision_files is
  'owner: content. Files attached to content revisions (story 6.2); the open draft only changes.';

-- A kind's extra condition for its published items to be public (and so for their files to stay
-- in the public bucket): a Content app function (p_input jsonb {item_id}) returns boolean. A kind
-- with no row has none. Banners: a campaign linked to an event only while that event is public.
create table app.content_public_conditions (
  kind text primary key references app.content_kinds (kind),
  handler text not null unique,
  registered_at timestamptz not null default now()
);

comment on table app.content_public_conditions is
  'owner: content. Per-kind conditions for a published item (and its files) to be public (story 6.2).';

alter table app.content_rights_revisions enable row level security;
alter table app.content_banner_revisions enable row level security;
alter table app.content_media_types enable row level security;
alter table app.content_asset_purposes enable row level security;
alter table app.content_assets enable row level security;
alter table app.content_revision_files enable row level security;
alter table app.content_public_conditions enable row level security;
revoke all on table app.content_rights_revisions, app.content_banner_revisions,
                    app.content_media_types, app.content_asset_purposes, app.content_assets,
                    app.content_revision_files, app.content_public_conditions
  from public, anon, authenticated, service_role;

-- A verified (published) rights revision never changes its content; attribution may be anonymised.
create function app.content_rights_revision_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.published_at is not null
     and (new.item_id, new.revision_no, new.label, new.source_key, new.holder, new.basis,
          new.clears_display, new.clears_offline, new.clears_audio, new.evidence, new.published_at)
         is distinct from
         (old.item_id, old.revision_no, old.label, old.source_key, old.holder, old.basis,
          old.clears_display, old.clears_offline, old.clears_audio, old.evidence, old.published_at) then
    raise exception using errcode = 'PCNT1', message = 'a published content revision is immutable';
  end if;
  return new;
end;
$$;

create trigger content_rights_revisions_immutable
  before update on app.content_rights_revisions
  for each row execute function app.content_rights_revision_guard();

create function app.content_banner_revision_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.published_at is not null
     and (new.item_id, new.revision_no, new.banner_kind, new.theme_year, new.title, new.subtitle,
          new.alt_text, new.event_id, new.published_at)
         is distinct from
         (old.item_id, old.revision_no, old.banner_kind, old.theme_year, old.title, old.subtitle,
          old.alt_text, old.event_id, old.published_at) then
    raise exception using errcode = 'PCNT1', message = 'a published content revision is immutable';
  end if;
  return new;
end;
$$;

create trigger content_banner_revisions_immutable
  before update on app.content_banner_revisions
  for each row execute function app.content_banner_revision_guard();

-- A revision's files change only while that revision is the item's open draft.
create function app.content_revision_files_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_item uuid := coalesce(new.item_id, old.item_id);
  v_no integer := coalesce(new.revision_no, old.revision_no);
begin
  if not exists (select 1 from app.content_items i
                  where i.item_id = v_item and i.draft_revision_no = v_no)
     or (tg_op = 'UPDATE' and (new.item_id, new.revision_no) is distinct from (old.item_id, old.revision_no)) then
    raise exception using errcode = 'PCNT1', message = 'a published content revision is immutable';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger content_revision_files_draft_only
  before insert or update or delete on app.content_revision_files
  for each row execute function app.content_revision_files_guard();

-- ---------------------------------------------------------------------------------------------
-- Helpers: payload fields, the Q5 list and the rights check
-- ---------------------------------------------------------------------------------------------

-- A uuid field p_key of a payload.
create function app.content_payload_uuid(p_payload jsonb, p_key text, out error text, out value uuid)
language plpgsql
immutable
set search_path = ''
as $$
begin
  error := app.contract_uuid_error(p_payload -> p_key);
  if error is null then
    value := (p_payload ->> p_key)::uuid;
  end if;
end;
$$;

-- An optional uuid field: missing or null is no value and no error.
create function app.content_payload_optional_uuid(p_payload jsonb, p_key text,
                                                  out error text, out value uuid)
language plpgsql
immutable
set search_path = ''
as $$
begin
  if coalesce(jsonb_typeof(p_payload -> p_key), 'null') = 'null' then
    return;
  end if;
  select t.error, t.value into error, value from app.content_payload_uuid(p_payload, p_key) t;
end;
$$;

-- A whole-number field (JSON integer): missing or null is no value; anything else is invalid.
create function app.content_payload_int(p_payload jsonb, p_key text, out error text, out value bigint)
language plpgsql
immutable
set search_path = ''
as $$
begin
  if coalesce(jsonb_typeof(p_payload -> p_key), 'null') = 'null' then
    return;
  end if;
  if jsonb_typeof(p_payload -> p_key) <> 'number' or (p_payload ->> p_key) !~ '^-?[0-9]{1,12}$' then
    error := 'invalid';
    return;
  end if;
  value := (p_payload ->> p_key)::bigint;
end;
$$;

-- A required boolean field.
create function app.content_payload_bool(p_payload jsonb, p_key text, out error text, out value boolean)
language plpgsql
immutable
set search_path = ''
as $$
begin
  if coalesce(jsonb_typeof(p_payload -> p_key), 'null') = 'null' then
    error := 'required';
  elsif jsonb_typeof(p_payload -> p_key) <> 'boolean' then
    error := 'invalid';
  else
    value := (p_payload -> p_key)::boolean;
  end if;
end;
$$;

-- The uses the effective q5_content_rights value lists for a source key. Closed gate, unknown
-- source or a malformed value: none (fail closed).
create function app.content_q5_uses(p_source_key text)
returns text[]
language plpgsql
stable
set search_path = ''
as $$
declare
  v_value jsonb;
  v_uses jsonb;
begin
  if p_source_key is null then
    return array[]::text[];
  end if;
  begin
    v_value := app.policy_effective('q5_content_rights') -> 'value';
  exception when sqlstate 'PCMD1' then
    return array[]::text[];
  end;
  v_uses := v_value -> 'sources' -> p_source_key;
  if jsonb_typeof(v_uses) is distinct from 'array' then
    return array[]::text[];
  end if;
  return coalesce(
    (select array_agg(distinct u.value #>> '{}' order by u.value #>> '{}')
       from jsonb_array_elements(v_uses) u
      where jsonb_typeof(u.value) = 'string' and (u.value #>> '{}') in ('display', 'offline', 'audio')),
    array[]::text[]);
end;
$$;

-- The rights check (beside the lifecycle helper; every kind with files or third-party text calls
-- it): null when the record clears p_use now, else why not: required (no record), unknown (no
-- such rights record), not_in_force (draft, withdrawn or archived), use_not_cleared (its live
-- revision does not clear the use) or source_not_cleared (the source is not listed with that
-- use in the effective Q5 value; production before Israel approves Q5).
create function app.content_rights_clear(p_rights_id uuid, p_use text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_item app.content_items;
  v_rev app.content_rights_revisions;
begin
  if p_rights_id is null then
    return 'required';
  end if;
  select i.* into v_item from app.content_items i where i.item_id = p_rights_id and i.kind = 'rights';
  if not found then
    return 'unknown';
  end if;
  if v_item.lifecycle_state <> 'published' then
    return 'not_in_force';
  end if;
  select r.* into v_rev from app.content_rights_revisions r
   where r.item_id = p_rights_id and r.revision_no = v_item.live_revision_no;
  if not coalesce(case p_use when 'display' then v_rev.clears_display
                             when 'offline' then v_rev.clears_offline
                             when 'audio' then v_rev.clears_audio end, false) then
    return 'use_not_cleared';
  end if;
  if not (p_use = any (app.content_q5_uses(v_rev.source_key))) then
    return 'source_not_cleared';
  end if;
  return null;
end;
$$;

comment on function app.content_rights_clear(uuid, text) is
  'Story 6.2 rights check: null when the rights record clears the use (in force, cleared on its '
  'live revision, source listed in the effective q5_content_rights value), else the reason code.';

-- ---------------------------------------------------------------------------------------------
-- Helpers: per-kind public conditions, public paths and Storage presence
-- ---------------------------------------------------------------------------------------------

-- Registers a kind's public condition (migration-time only).
create function app.content_register_public_condition(p_kind text, p_handler regprocedure)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from app.content_kinds k where k.kind = p_kind) then
    perform app.contract_registration_fail('unknown content kind: ' || coalesce(p_kind, '<null>'));
  end if;
  insert into app.content_public_conditions (kind, handler)
  values (p_kind, app.contract_validate_handler('content', p_handler, 'boolean'::regtype));
end;
$$;

-- Whether a published item of p_kind meets its kind's public condition now (true when the kind
-- registered none). Fail closed: a registered handler that is missing or answers null is false.
create function app.content_item_public(p_kind text, p_item_id uuid)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare
  v_handler text;
  v_proc regprocedure;
  v_ok boolean;
begin
  select c.handler into v_handler from app.content_public_conditions c where c.kind = p_kind;
  if v_handler is null then
    return true;
  end if;
  v_proc := pg_catalog.to_regprocedure(v_handler);
  if v_proc is null then
    return false;
  end if;
  execute format('select %s($1)', v_proc::regproc) into v_ok
    using jsonb_build_object('item_id', p_item_id);
  return coalesce(v_ok, false);
end;
$$;

-- The revision-keyed public path of a file slot.
create function app.content_public_path(p_kind text, p_item_id uuid, p_revision_no integer,
                                        p_slot text, p_extension text)
returns text
language sql
immutable
set search_path = ''
as $$
  select p_kind || '/' || p_item_id::text || '/r' || p_revision_no::text || '/' || p_slot || '.'
         || p_extension;
$$;

-- Whether an object is present in the public bucket (Storage's own table, read only).
create function app.content_public_object_present(p_path text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from storage.objects o
                  where o.bucket_id = 'content-public' and o.name = p_path);
$$;

-- Every file that should be public now: the files of each published item's live revision whose
-- asset is ready, whose rights clear the purpose's use and whose item meets its kind's public
-- condition (app.content_public_conditions).
create function app.content_public_files_desired()
returns table (item_id uuid, slot text, public_path text, draft_path text, media_type text)
language sql
stable
set search_path = ''
as $$
  select i.item_id, f.slot,
         app.content_public_path(i.kind, i.item_id, f.revision_no, f.slot, t.extension),
         a.draft_path, a.media_type
    from app.content_items i
    join app.content_revision_files f on f.item_id = i.item_id and f.revision_no = i.live_revision_no
    join app.content_assets a on a.asset_id = f.asset_id and a.item_id = i.item_id and a.state = 'ready'
    join app.content_asset_purposes p on p.purpose = f.purpose
    join app.content_media_types t on t.media_type = a.media_type
   where i.lifecycle_state = 'published'
     and app.content_rights_clear(f.rights_id, p.rights_use) is null
     and app.content_item_public(i.kind, i.item_id);
$$;

-- One item's file in a slot when it should be public now (the same rule as the desired set, for
-- one item): its public path and the asset's type and size. No row otherwise.
create function app.content_live_file(p_item_id uuid, p_slot text)
returns table (public_path text, draft_path text, media_type text, width integer, height integer)
language sql
stable
set search_path = ''
as $$
  select app.content_public_path(i.kind, i.item_id, f.revision_no, f.slot, t.extension),
         a.draft_path, a.media_type, a.width, a.height
    from app.content_items i
    join app.content_revision_files f
      on f.item_id = i.item_id and f.revision_no = i.live_revision_no and f.slot = p_slot
    join app.content_assets a on a.asset_id = f.asset_id and a.item_id = i.item_id and a.state = 'ready'
    join app.content_asset_purposes p on p.purpose = f.purpose
    join app.content_media_types t on t.media_type = a.media_type
   where i.item_id = p_item_id and i.lifecycle_state = 'published'
     and app.content_rights_clear(f.rights_id, p.rights_use) is null
     and app.content_item_public(i.kind, i.item_id);
$$;

-- A published item's live file in a slot as public projections show it, only once its object is
-- present in the public bucket: {path, media_type, width, height}, else null.
create function app.content_public_file(p_item_id uuid, p_slot text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('path', l.public_path, 'media_type', l.media_type, 'width', l.width,
                            'height', l.height)
    from app.content_live_file(p_item_id, p_slot) l
   where app.content_public_object_present(l.public_path);
$$;

-- Objects in the public bucket that are not in the desired set (still to remove).
create function app.content_public_removals()
returns table (public_path text)
language sql
stable
set search_path = ''
as $$
  with desired as materialized (
    select d.public_path from app.content_public_files_desired() d)
  select o.name
    from storage.objects o
   where o.bucket_id = 'content-public'
     and not exists (select 1 from desired d where d.public_path = o.name);
$$;

-- ---------------------------------------------------------------------------------------------
-- Rights records
-- ---------------------------------------------------------------------------------------------

-- The rights fields of a payload: label (120), source_key, holder (160), basis, the three clears
-- flags (at least one true) and evidence (1000, multiline).
create function app.content_rights_fields(
  p_payload jsonb,
  out errors jsonb,
  out label text,
  out source_key text,
  out holder text,
  out basis text,
  out clears_display boolean,
  out clears_offline boolean,
  out clears_audio boolean,
  out evidence text
)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_error text;
begin
  errors := '{}'::jsonb;
  select t.error, t.value into v_error, label from app.content_free_text(p_payload -> 'label', 120, false) t;
  if v_error is null and label is null then
    v_error := 'required';
  end if;
  if v_error is not null then
    errors := errors || jsonb_build_object('label', v_error);
  end if;
  if coalesce(jsonb_typeof(p_payload -> 'source_key'), 'null') = 'null' then
    errors := errors || '{"source_key": "required"}';
  elsif jsonb_typeof(p_payload -> 'source_key') <> 'string'
        or (p_payload ->> 'source_key') !~ '^[a-z0-9][a-z0-9-]{1,40}$' then
    errors := errors || '{"source_key": "invalid"}';
  else
    source_key := p_payload ->> 'source_key';
  end if;
  select t.error, t.value into v_error, holder from app.content_free_text(p_payload -> 'holder', 160, false) t;
  if v_error is null and holder is null then
    v_error := 'required';
  end if;
  if v_error is not null then
    errors := errors || jsonb_build_object('holder', v_error);
  end if;
  if coalesce(jsonb_typeof(p_payload -> 'basis'), 'null') = 'null' then
    errors := errors || '{"basis": "required"}';
  elsif jsonb_typeof(p_payload -> 'basis') <> 'string'
        or (p_payload ->> 'basis') not in ('public_domain', 'licence', 'permission', 'church_owned') then
    errors := errors || '{"basis": "invalid"}';
  else
    basis := p_payload ->> 'basis';
  end if;
  select t.error, t.value into v_error, clears_display from app.content_payload_bool(p_payload, 'clears_display') t;
  if v_error is not null then
    errors := errors || jsonb_build_object('clears_display', v_error);
  end if;
  select t.error, t.value into v_error, clears_offline from app.content_payload_bool(p_payload, 'clears_offline') t;
  if v_error is not null then
    errors := errors || jsonb_build_object('clears_offline', v_error);
  end if;
  select t.error, t.value into v_error, clears_audio from app.content_payload_bool(p_payload, 'clears_audio') t;
  if v_error is not null then
    errors := errors || jsonb_build_object('clears_audio', v_error);
  end if;
  if clears_display is false and clears_offline is false and clears_audio is false then
    errors := errors || '{"clears_display": "none_cleared"}';
  end if;
  select t.error, t.value into v_error, evidence
    from app.content_free_text(p_payload -> 'evidence', 1000, true) t;
  if v_error is null and evidence is null then
    v_error := 'required';
  end if;
  if v_error is not null then
    errors := errors || jsonb_build_object('evidence', v_error);
  end if;
end;
$$;

-- content.create_rights_record {label, source_key, holder, basis, clears_display, clears_offline,
-- clears_audio, evidence}; expected null. A new rights record draft (not in force).
create function app.content_rights_create(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_fields record;
  v_errors jsonb;
  v_item uuid;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'rights') a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['label', 'source_key', 'holder', 'basis', 'clears_display', 'clears_offline',
                      'clears_audio', 'evidence']);
  select f.* into v_fields from app.content_rights_fields(p_payload) f;
  v_errors := v_errors || v_fields.errors;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_open('rights', v_actor.member_id, v_actor.account_id, v_actor.capacity,
                                  'content.create_rights_record');
  insert into app.content_rights_revisions (item_id, revision_no, label, source_key, holder, basis,
                                            clears_display, clears_offline, clears_audio, evidence,
                                            saved_by_member, saved_by_account)
  values (v_item, 1, v_fields.label, v_fields.source_key, v_fields.holder, v_fields.basis,
          v_fields.clears_display, v_fields.clears_offline, v_fields.clears_audio, v_fields.evidence,
          v_actor.member_id, v_actor.account_id);
  return app.content_item_outcome(v_item, 'rights_id');
end;
$$;

-- content.save_rights_record {rights_id, ...the eight fields}; expected = its revision. Writes the
-- open draft or opens the next one; the verified revision stays in force until a new one is
-- verified.
create function app.content_rights_save(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_fields record;
  v_errors jsonb;
  v_error text;
  v_id uuid;
  v_item app.content_items;
  v_no integer;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'rights') a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['rights_id', 'label', 'source_key', 'holder', 'basis', 'clears_display',
                      'clears_offline', 'clears_audio', 'evidence']);
  select t.error, t.value into v_error, v_id from app.content_payload_uuid(p_payload, 'rights_id') t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('rights_id', v_error);
  end if;
  select f.* into v_fields from app.content_rights_fields(p_payload) f;
  v_errors := v_errors || v_fields.errors;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_lock(v_id, 'rights', p_expected_revision, 'rights_id');
  v_no := app.content_item_draft_no(v_item);
  insert into app.content_rights_revisions as r (item_id, revision_no, label, source_key, holder,
                                                 basis, clears_display, clears_offline,
                                                 clears_audio, evidence, saved_by_member,
                                                 saved_by_account)
  values (v_id, v_no, v_fields.label, v_fields.source_key, v_fields.holder, v_fields.basis,
          v_fields.clears_display, v_fields.clears_offline, v_fields.clears_audio, v_fields.evidence,
          v_actor.member_id, v_actor.account_id)
  on conflict (item_id, revision_no) do update
     set label = excluded.label,
         source_key = excluded.source_key,
         holder = excluded.holder,
         basis = excluded.basis,
         clears_display = excluded.clears_display,
         clears_offline = excluded.clears_offline,
         clears_audio = excluded.clears_audio,
         evidence = excluded.evidence,
         saved_by_member = excluded.saved_by_member,
         saved_by_account = excluded.saved_by_account,
         saved_at = now()
   where r.published_at is null;
  perform app.content_item_saved(v_item, v_no, v_actor.member_id, v_actor.account_id,
                                 v_actor.capacity, 'content.save_rights_record');
  return app.content_item_outcome(v_id, 'rights_id');
end;
$$;

-- The payload of a {<key>} lifecycle command: its id, or the failure.
create function app.content_lifecycle_id(p_payload jsonb, p_key text)
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_error text;
  v_id uuid;
begin
  v_errors := app.contract_unknown_keys(p_payload, array[p_key]);
  select t.error, t.value into v_error, v_id from app.content_payload_uuid(p_payload, p_key) t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object(p_key, v_error);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  return v_id;
end;
$$;

-- content.verify_rights_record {rights_id}; expected = its revision. The open draft revision is
-- verified and comes into force (or a withdrawn record's revision comes back into force); the
-- actor is its verifier.
create function app.content_rights_verify(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_id uuid;
  v_item app.content_items;
  v_no integer;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'rights') a;
  v_id := app.content_lifecycle_id(p_payload, 'rights_id');
  v_item := app.content_item_lock(v_id, 'rights', p_expected_revision, 'rights_id');
  v_no := app.content_item_publish(v_item, v_actor.member_id, v_actor.account_id, v_actor.capacity,
                                   'content.verify_rights_record', 'rights_id');
  update app.content_rights_revisions r
     set published_at = now(),
         published_by_member = v_actor.member_id,
         published_by_account = v_actor.account_id
   where r.item_id = v_id and r.revision_no = v_no and r.published_at is null;
  return app.content_item_outcome(v_id, 'rights_id');
end;
$$;

-- content.withdraw_rights_record {rights_id}: suspends a record in force; every file citing it
-- leaves the public reads at once and its public object is removed by the next sync.
create function app.content_rights_withdraw(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_id uuid;
  v_item app.content_items;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'rights') a;
  v_id := app.content_lifecycle_id(p_payload, 'rights_id');
  v_item := app.content_item_lock(v_id, 'rights', p_expected_revision, 'rights_id');
  perform app.content_item_withdraw(v_item, v_actor.member_id, v_actor.account_id,
                                    v_actor.capacity, 'content.withdraw_rights_record', 'rights_id');
  return app.content_item_outcome(v_id, 'rights_id');
end;
$$;

-- content.archive_rights_record {rights_id}: retires a record from any state.
create function app.content_rights_archive(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_id uuid;
  v_item app.content_items;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'rights') a;
  v_id := app.content_lifecycle_id(p_payload, 'rights_id');
  v_item := app.content_item_lock(v_id, 'rights', p_expected_revision, 'rights_id');
  perform app.content_item_archive(v_item, v_actor.member_id, v_actor.account_id,
                                   v_actor.capacity, 'content.archive_rights_record');
  return app.content_item_outcome(v_id, 'rights_id');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Uploads (sent by the content-assets Edge function under the editor's session)
-- ---------------------------------------------------------------------------------------------

-- content.begin_asset_upload {item_id, purpose, media_type, byte_size, width, height, sha256};
-- expected null. The measured file is checked against the purpose's limits for an editor of the
-- item's kind; a pending asset and its draft path are returned. Nothing is public.
create function app.content_asset_begin(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_error text;
  v_item_id uuid;
  v_item app.content_items;
  v_purpose app.content_asset_purposes;
  v_type text;
  v_ext text;
  v_size bigint;
  v_width bigint;
  v_height bigint;
  v_asset uuid := gen_random_uuid();
  v_path text;
begin
  v_errors := app.contract_unknown_keys(p_payload,
                array['item_id', 'purpose', 'media_type', 'byte_size', 'width', 'height', 'sha256']);
  select t.error, t.value into v_error, v_item_id from app.content_payload_uuid(p_payload, 'item_id') t;
  if v_error is null then
    select i.* into v_item from app.content_items i where i.item_id = v_item_id for share;
    if not found then
      v_error := 'unknown';
    end if;
  end if;
  if v_error is not null then
    perform app.cmd_fail('validation_failed', v_errors || jsonb_build_object('item_id', v_error));
  end if;
  -- Only an editor of the item's own kind may upload for it.
  select a.* into v_actor from app.content_command_actor(p_actor, v_item.kind) a;
  if v_item.lifecycle_state = 'archived' then
    v_errors := v_errors || '{"item_id": "archived"}';
  end if;
  if jsonb_typeof(p_payload -> 'purpose') is distinct from 'string' then
    v_errors := v_errors || jsonb_build_object('purpose',
                  case when coalesce(jsonb_typeof(p_payload -> 'purpose'), 'null') = 'null'
                       then 'required' else 'invalid' end);
  else
    select p.* into v_purpose from app.content_asset_purposes p where p.purpose = p_payload ->> 'purpose';
    if not found then
      v_errors := v_errors || '{"purpose": "unknown"}';
    elsif v_purpose.kind <> v_item.kind then
      v_errors := v_errors || '{"purpose": "unsupported"}';
    end if;
  end if;
  if jsonb_typeof(p_payload -> 'media_type') is distinct from 'string' then
    v_errors := v_errors || '{"media_type": "required"}';
  else
    v_type := p_payload ->> 'media_type';
    select t.extension into v_ext from app.content_media_types t where t.media_type = v_type;
    if v_ext is null or (v_purpose.purpose is not null and not (v_type = any (v_purpose.media_types))) then
      v_errors := v_errors || '{"media_type": "unsupported_type"}';
    end if;
  end if;
  select t.error, t.value into v_error, v_size from app.content_payload_int(p_payload, 'byte_size') t;
  if v_error is null and v_size is null then
    v_error := 'required';
  elsif v_error is null and v_size < 1 then
    v_error := 'invalid';
  elsif v_error is null and v_purpose.purpose is not null and v_size > v_purpose.max_bytes then
    v_error := 'too_large';
  end if;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('byte_size', v_error);
  end if;
  select t.error, t.value into v_error, v_width from app.content_payload_int(p_payload, 'width') t;
  if v_error is null and v_width is null then
    v_error := 'required';
  elsif v_error is null and v_width < 1 then
    v_error := 'invalid';
  elsif v_error is null and v_purpose.purpose is not null and v_width < v_purpose.min_width then
    v_error := 'too_small';
  elsif v_error is null and v_purpose.purpose is not null and v_width > v_purpose.max_width then
    v_error := 'too_large';
  end if;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('width', v_error);
  end if;
  select t.error, t.value into v_error, v_height from app.content_payload_int(p_payload, 'height') t;
  if v_error is null and v_height is null then
    v_error := 'required';
  elsif v_error is null and v_height < 1 then
    v_error := 'invalid';
  elsif v_error is null and v_purpose.purpose is not null and v_height < v_purpose.min_height then
    v_error := 'too_small';
  elsif v_error is null and v_purpose.purpose is not null and v_height > v_purpose.max_height then
    v_error := 'too_large';
  end if;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('height', v_error);
  end if;
  if v_purpose.purpose is not null and not (v_errors ? 'width') and not (v_errors ? 'height')
     and ((v_width::numeric / v_height) < v_purpose.min_ratio
          or (v_width::numeric / v_height) > v_purpose.max_ratio) then
    v_errors := v_errors || '{"width": "bad_ratio"}';
  end if;
  if jsonb_typeof(p_payload -> 'sha256') is distinct from 'string' then
    v_errors := v_errors || '{"sha256": "required"}';
  elsif (p_payload ->> 'sha256') !~ '^[0-9a-f]{64}$' then
    v_errors := v_errors || '{"sha256": "invalid"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_path := v_asset::text || '.' || v_ext;
  insert into app.content_assets (asset_id, item_id, purpose, media_type, byte_size, width, height,
                                  sha256, draft_path, uploaded_by_member, uploaded_by_account)
  values (v_asset, v_item.item_id, v_purpose.purpose, v_type, v_size, v_width, v_height,
          p_payload ->> 'sha256', v_path, v_actor.member_id, v_actor.account_id);
  return jsonb_build_object(
    'aggregate_type', 'content_item',
    'aggregate_id', v_item.item_id,
    'revision', v_item.revision,
    'data', jsonb_build_object('asset_id', v_asset, 'item_id', v_item.item_id, 'state', 'pending',
                               'draft_path', v_path, 'media_type', v_type, 'byte_size', v_size,
                               'width', v_width, 'height', v_height));
end;
$$;

-- content.complete_asset_upload {asset_id}; expected null. The asset becomes ready once its object
-- is in content-drafts with the declared size and type (read from storage.objects); idempotent.
create function app.content_asset_complete(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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

-- Attaches (or clears) a file slot of an item's open draft revision; the caller validated it.
create function app.content_file_attach(p_item_id uuid, p_revision_no integer, p_slot text,
                                        p_purpose text, p_asset_id uuid, p_rights_id uuid)
returns void
language sql
set search_path = ''
as $$
  insert into app.content_revision_files as f (item_id, revision_no, slot, purpose, asset_id, rights_id)
  values (p_item_id, p_revision_no, p_slot, p_purpose, p_asset_id, p_rights_id)
  on conflict (item_id, revision_no, slot) do update
     set purpose = excluded.purpose,
         asset_id = excluded.asset_id,
         rights_id = excluded.rights_id,
         updated_at = now();
$$;

-- Why an asset cannot go into an item's slot of p_purpose: unknown (no such asset for this item and
-- purpose) or not_ready; null when it can.
create function app.content_asset_error(p_asset_id uuid, p_item_id uuid, p_purpose text)
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
    when not exists (select 1 from app.content_assets a
                      where a.asset_id = p_asset_id and a.state = 'ready') then 'not_ready'
  end;
$$;

-- Why a rights record cannot be cited: unknown (not a rights record, or archived); null when it can.
create function app.content_rights_ref_error(p_rights_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_rights_id is null then null
    when not exists (select 1 from app.content_items i
                      where i.item_id = p_rights_id and i.kind = 'rights'
                        and i.lifecycle_state <> 'archived') then 'unknown'
  end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Banners
-- ---------------------------------------------------------------------------------------------

-- The banner fields of a payload: banner_kind (theme|campaign), theme_year (theme: 2000-2100,
-- campaign: null), title (80), subtitle (120, optional), alt_text (250) and event_id (campaign
-- only, optional: an event that is not archived).
create function app.content_banner_fields(
  p_payload jsonb,
  out errors jsonb,
  out banner_kind text,
  out theme_year integer,
  out title text,
  out subtitle text,
  out alt_text text,
  out event_id uuid
)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_error text;
  v_year bigint;
begin
  errors := '{}'::jsonb;
  if coalesce(jsonb_typeof(p_payload -> 'banner_kind'), 'null') = 'null' then
    errors := errors || '{"banner_kind": "required"}';
  elsif jsonb_typeof(p_payload -> 'banner_kind') <> 'string'
        or (p_payload ->> 'banner_kind') not in ('theme', 'campaign') then
    errors := errors || '{"banner_kind": "invalid"}';
  else
    banner_kind := p_payload ->> 'banner_kind';
  end if;
  select t.error, t.value into v_error, v_year from app.content_payload_int(p_payload, 'theme_year') t;
  if v_error is null and banner_kind = 'theme' then
    if v_year is null then
      v_error := 'required';
    elsif v_year not between 2000 and 2100 then
      v_error := 'out_of_range';
    end if;
  elsif v_error is null and banner_kind = 'campaign' and v_year is not null then
    v_error := 'must_be_null';
  end if;
  if v_error is not null then
    errors := errors || jsonb_build_object('theme_year', v_error);
  elsif banner_kind = 'theme' then
    theme_year := v_year::integer;
  end if;
  select t.error, t.value into v_error, title from app.content_free_text(p_payload -> 'title', 80, false) t;
  if v_error is null and title is null then
    v_error := 'required';
  end if;
  if v_error is not null then
    errors := errors || jsonb_build_object('title', v_error);
  end if;
  select t.error, t.value into v_error, subtitle
    from app.content_free_text(p_payload -> 'subtitle', 120, false) t;
  if v_error is not null then
    errors := errors || jsonb_build_object('subtitle', v_error);
  end if;
  select t.error, t.value into v_error, alt_text
    from app.content_free_text(p_payload -> 'alt_text', 250, false) t;
  if v_error is null and alt_text is null then
    v_error := 'required';
  end if;
  if v_error is not null then
    errors := errors || jsonb_build_object('alt_text', v_error);
  end if;
  select t.error, t.value into v_error, event_id
    from app.content_payload_optional_uuid(p_payload, 'event_id') t;
  if v_error is null and event_id is not null then
    if banner_kind = 'theme' then
      v_error := 'must_be_null';
    elsif not exists (select 1 from app.content_items e
                       where e.item_id = event_id and e.kind = 'event'
                         and e.lifecycle_state <> 'archived') then
      v_error := 'unknown';
    end if;
  end if;
  if v_error is not null then
    errors := errors || jsonb_build_object('event_id', v_error);
    event_id := null;
  end if;
end;
$$;

-- content.create_banner {banner_kind, theme_year, title, subtitle, alt_text, event_id}; expected
-- null. A new private draft with no image yet (an upload needs the banner to exist).
create function app.content_banner_create(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_fields record;
  v_errors jsonb;
  v_item uuid;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'banner') a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['banner_kind', 'theme_year', 'title', 'subtitle', 'alt_text', 'event_id']);
  select f.* into v_fields from app.content_banner_fields(p_payload) f;
  v_errors := v_errors || v_fields.errors;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_open('banner', v_actor.member_id, v_actor.account_id, v_actor.capacity,
                                  'content.create_banner');
  insert into app.content_banner_revisions (item_id, revision_no, banner_kind, theme_year, title,
                                            subtitle, alt_text, event_id, saved_by_member,
                                            saved_by_account)
  values (v_item, 1, v_fields.banner_kind, v_fields.theme_year, v_fields.title, v_fields.subtitle,
          v_fields.alt_text, v_fields.event_id, v_actor.member_id, v_actor.account_id);
  return app.content_item_outcome(v_item, 'banner_id');
end;
$$;

-- content.save_banner {banner_id, banner_kind, theme_year, title, subtitle, alt_text, event_id,
-- image_asset_id, image_rights_id}; expected = the banner's revision. Absolute state: a null
-- image or rights record clears that part of the draft (a null, never a row deletion).
create function app.content_banner_save(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_fields record;
  v_errors jsonb;
  v_error text;
  v_id uuid;
  v_asset uuid;
  v_rights uuid;
  v_item app.content_items;
  v_no integer;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'banner') a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['banner_id', 'banner_kind', 'theme_year', 'title', 'subtitle', 'alt_text',
                      'event_id', 'image_asset_id', 'image_rights_id']);
  select t.error, t.value into v_error, v_id from app.content_payload_uuid(p_payload, 'banner_id') t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('banner_id', v_error);
  end if;
  select f.* into v_fields from app.content_banner_fields(p_payload) f;
  v_errors := v_errors || v_fields.errors;
  select t.error, t.value into v_error, v_asset
    from app.content_payload_optional_uuid(p_payload, 'image_asset_id') t;
  if v_error is null and v_id is not null then
    v_error := app.content_asset_error(v_asset, v_id, 'banner_image');
  end if;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('image_asset_id', v_error);
  end if;
  select t.error, t.value into v_error, v_rights
    from app.content_payload_optional_uuid(p_payload, 'image_rights_id') t;
  if v_error is null then
    v_error := app.content_rights_ref_error(v_rights);
  end if;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('image_rights_id', v_error);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_lock(v_id, 'banner', p_expected_revision, 'banner_id');
  v_no := app.content_item_draft_no(v_item);
  insert into app.content_banner_revisions as r (item_id, revision_no, banner_kind, theme_year,
                                                 title, subtitle, alt_text, event_id,
                                                 saved_by_member, saved_by_account)
  values (v_id, v_no, v_fields.banner_kind, v_fields.theme_year, v_fields.title, v_fields.subtitle,
          v_fields.alt_text, v_fields.event_id, v_actor.member_id, v_actor.account_id)
  on conflict (item_id, revision_no) do update
     set banner_kind = excluded.banner_kind,
         theme_year = excluded.theme_year,
         title = excluded.title,
         subtitle = excluded.subtitle,
         alt_text = excluded.alt_text,
         event_id = excluded.event_id,
         saved_by_member = excluded.saved_by_member,
         saved_by_account = excluded.saved_by_account,
         saved_at = now()
   where r.published_at is null;
  perform app.content_item_saved(v_item, v_no, v_actor.member_id, v_actor.account_id,
                                 v_actor.capacity, 'content.save_banner');
  perform app.content_file_attach(v_id, v_no, 'image', 'banner_image', v_asset, v_rights);
  return app.content_item_outcome(v_id, 'banner_id');
end;
$$;

-- content.publish_banner {banner_id}; expected = the banner's revision. The revision going live
-- (the open draft, or a withdrawn banner's live revision) needs a ready image, a rights record
-- that clears display (in force, Q5) and, when linked, an event that is publicly readable now.
create function app.content_banner_publish(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_id uuid;
  v_item app.content_items;
  v_no integer;
  v_rev app.content_banner_revisions;
  v_file app.content_revision_files;
  v_errors jsonb := '{}'::jsonb;
  v_error text;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'banner') a;
  v_id := app.content_lifecycle_id(p_payload, 'banner_id');
  v_item := app.content_item_lock(v_id, 'banner', p_expected_revision, 'banner_id');
  v_no := coalesce(v_item.draft_revision_no,
                   case when v_item.lifecycle_state = 'withdrawn' then v_item.live_revision_no end);
  if v_no is not null then
    select r.* into v_rev from app.content_banner_revisions r
     where r.item_id = v_id and r.revision_no = v_no;
    select f.* into v_file from app.content_revision_files f
     where f.item_id = v_id and f.revision_no = v_no and f.slot = 'image';
    if v_file.asset_id is null
       or not exists (select 1 from app.content_assets a
                       where a.asset_id = v_file.asset_id and a.state = 'ready') then
      v_errors := v_errors || '{"image_asset_id": "required"}';
    end if;
    v_error := app.content_rights_clear(v_file.rights_id, 'display');
    if v_error is not null then
      v_errors := v_errors || jsonb_build_object('image_rights_id', v_error);
    end if;
    if v_rev.event_id is not null and app.content_public_event_json(v_rev.event_id) is null then
      v_errors := v_errors || '{"event_id": "not_published"}';
    end if;
    if v_errors <> '{}'::jsonb then
      perform app.cmd_fail('validation_failed', v_errors);
    end if;
  end if;
  v_no := app.content_item_publish(v_item, v_actor.member_id, v_actor.account_id, v_actor.capacity,
                                   'content.publish_banner', 'banner_id');
  update app.content_banner_revisions r
     set published_at = now(),
         published_by_member = v_actor.member_id,
         published_by_account = v_actor.account_id
   where r.item_id = v_id and r.revision_no = v_no and r.published_at is null;
  return app.content_item_outcome(v_id, 'banner_id');
end;
$$;

-- content.withdraw_banner {banner_id}: off Home at once; its public object goes at the next sync.
create function app.content_banner_withdraw(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_id uuid;
  v_item app.content_items;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'banner') a;
  v_id := app.content_lifecycle_id(p_payload, 'banner_id');
  v_item := app.content_item_lock(v_id, 'banner', p_expected_revision, 'banner_id');
  perform app.content_item_withdraw(v_item, v_actor.member_id, v_actor.account_id,
                                    v_actor.capacity, 'content.withdraw_banner', 'banner_id');
  return app.content_item_outcome(v_id, 'banner_id');
end;
$$;

-- content.archive_banner {banner_id}: retires it from any state.
create function app.content_banner_archive(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_id uuid;
  v_item app.content_items;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'banner') a;
  v_id := app.content_lifecycle_id(p_payload, 'banner_id');
  v_item := app.content_item_lock(v_id, 'banner', p_expected_revision, 'banner_id');
  perform app.content_item_archive(v_item, v_actor.member_id, v_actor.account_id,
                                   v_actor.capacity, 'content.archive_banner');
  return app.content_item_outcome(v_id, 'banner_id');
end;
$$;

select app.content_register_command('content.create_rights_record', 'rights',
  'app.content_rights_create(uuid, bigint, jsonb)'::regprocedure, true);
select app.content_register_command('content.save_rights_record', 'rights',
  'app.content_rights_save(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.verify_rights_record', 'rights',
  'app.content_rights_verify(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.withdraw_rights_record', 'rights',
  'app.content_rights_withdraw(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.archive_rights_record', 'rights',
  'app.content_rights_archive(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.begin_asset_upload', 'asset',
  'app.content_asset_begin(uuid, bigint, jsonb)'::regprocedure, true);
select app.content_register_command('content.complete_asset_upload', 'asset',
  'app.content_asset_complete(uuid, bigint, jsonb)'::regprocedure, true);
select app.content_register_command('content.create_banner', 'banner',
  'app.content_banner_create(uuid, bigint, jsonb)'::regprocedure, true);
select app.content_register_command('content.save_banner', 'banner',
  'app.content_banner_save(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.publish_banner', 'banner',
  'app.content_banner_publish(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.withdraw_banner', 'banner',
  'app.content_banner_withdraw(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.archive_banner', 'banner',
  'app.content_banner_archive(uuid, bigint, jsonb)'::regprocedure, false);

-- The banner kind's public condition: a campaign linked to an event is public (and keeps its
-- file in the public bucket) only while that event is publicly readable (published, not ended).
create function app.content_banner_public_condition(p_input jsonb)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select r.event_id is null or app.content_public_event_json(r.event_id) is not null
      from app.content_items i
      join app.content_banner_revisions r
        on r.item_id = i.item_id and r.revision_no = i.live_revision_no
     where i.item_id = (p_input ->> 'item_id')::uuid), false);
$$;

select app.content_register_public_condition('banner',
  'app.content_banner_public_condition(jsonb)'::regprocedure);

-- ---------------------------------------------------------------------------------------------
-- The public read (anonymous): published banners whose image is in the public bucket
-- ---------------------------------------------------------------------------------------------

-- One banner as anyone may read it, or null when it is not public now: not published, its image
-- not placed (or its rights no longer clear it), or linked to an event that is not public.
create function app.content_public_banner_json(p_item_id uuid)
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
    'rights_revision', (select ri.live_revision_no
                          from app.content_revision_files f
                          join app.content_items ri on ri.item_id = f.rights_id
                         where f.item_id = i.item_id and f.revision_no = i.live_revision_no
                           and f.slot = 'image'),
    'published_at', app.cmd_utc(i.published_at))
    from app.content_items i
    join app.content_banner_revisions r on r.item_id = i.item_id and r.revision_no = i.live_revision_no
   cross join lateral (select app.content_public_file(i.item_id, 'image') as image) x
   where i.item_id = p_item_id and i.kind = 'banner' and i.lifecycle_state = 'published'
     and x.image is not null
     and app.content_banner_public_condition(jsonb_build_object('item_id', i.item_id));
$$;

-- The Home carousel: the yearly theme first (latest year first), then campaigns (latest
-- published first); at most 12.
create function app.content_public_banners()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with live as (
    select x.banner,
           row_number() over (order by (r.banner_kind = 'campaign'), r.theme_year desc nulls last,
                                       i.published_at desc, i.item_id) as rn
      from app.content_items i
      join app.content_banner_revisions r
        on r.item_id = i.item_id and r.revision_no = i.live_revision_no
     cross join lateral (select app.content_public_banner_json(i.item_id) as banner) x
     where i.kind = 'banner' and i.lifecycle_state = 'published' and x.banner is not null)
  select jsonb_build_object(
           'banners', coalesce(jsonb_agg(l.banner order by l.rn) filter (where l.rn <= 12),
                               '[]'::jsonb),
           'truncated', count(*) > 12)
    from live l;
$$;

create function api.content_public_banners()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select app.content_public_banners();
$$;

comment on function api.content_public_banners() is
  'Story 6.2, public (anon and authenticated): the Home banners whose images are public.';

-- ---------------------------------------------------------------------------------------------
-- The editors' reads
-- ---------------------------------------------------------------------------------------------

-- The editor's capacity for p_kind, or 403 not_granted; records the activity.
create function app.content_require_editor(p_kind text, out member_id uuid, out capacity text)
language plpgsql
set search_path = ''
as $$
declare
  v_link uuid;
begin
  select a.member_id, a.link_id into member_id, v_link from app.identity_require_access() a;
  capacity := app.content_editor_capacity(member_id, p_kind);
  if capacity is null then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  perform app.identity_record_activity(v_link);
end;
$$;

create function app.content_rights_revision_json(p_item_id uuid, p_revision_no integer)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'revision_no', r.revision_no,
    'label', r.label,
    'source_key', r.source_key,
    'holder', r.holder,
    'basis', r.basis,
    'clears_display', r.clears_display,
    'clears_offline', r.clears_offline,
    'clears_audio', r.clears_audio,
    'evidence', r.evidence,
    'saved_at', app.cmd_utc(r.saved_at),
    'saved_by', app.content_editor_name(r.saved_by_member))
    from app.content_rights_revisions r
   where r.item_id = p_item_id and r.revision_no = p_revision_no;
$$;

create function app.content_staff_rights_json(p_item_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'rights_id', i.item_id,
    'revision', i.revision,
    'state', i.lifecycle_state,
    'created_at', app.cmd_utc(i.created_at),
    'created_by', app.content_editor_name(i.created_by_member),
    'updated_at', app.cmd_utc(i.updated_at),
    'verified_at', app.cmd_utc(l.published_at),
    'verified_by', case when l.published_by_member is not null
                        then app.content_editor_name(l.published_by_member) end,
    'withdrawn_at', app.cmd_utc(i.withdrawn_at),
    'archived_at', app.cmd_utc(i.archived_at),
    'q5_uses', to_jsonb(app.content_q5_uses(coalesce(l.source_key, d.source_key))),
    'live', case when i.live_revision_no is not null
                 then app.content_rights_revision_json(i.item_id, i.live_revision_no) end,
    'draft', case when i.draft_revision_no is not null
                  then app.content_rights_revision_json(i.item_id, i.draft_revision_no) end)
    from app.content_items i
    left join app.content_rights_revisions l
      on l.item_id = i.item_id and l.revision_no = i.live_revision_no
    left join app.content_rights_revisions d
      on d.item_id = i.item_id and d.revision_no = i.draft_revision_no
   where i.item_id = p_item_id;
$$;

-- Every rights record with its live (verified) and draft revisions, for the editors of rights:
-- archived ones last, the others by label; at most 500.
create function app.content_staff_rights()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_editor record;
  v_result jsonb;
begin
  select e.* into v_editor from app.content_require_editor('rights') e;
  with ranked as (
    select i.item_id,
           row_number() over (
             order by (i.lifecycle_state = 'archived'),
                      lower(coalesce(l.label, d.label)), i.item_id) as rn
      from app.content_items i
      left join app.content_rights_revisions l
        on l.item_id = i.item_id and l.revision_no = i.live_revision_no
      left join app.content_rights_revisions d
        on d.item_id = i.item_id and d.revision_no = i.draft_revision_no
     where i.kind = 'rights')
  select jsonb_build_object(
           'capacity', v_editor.capacity,
           'rights', coalesce(jsonb_agg(app.content_staff_rights_json(k.item_id) order by k.rn)
                                filter (where k.rn <= 500), '[]'::jsonb),
           'truncated', count(*) > 500)
    into v_result
    from ranked k;
  return v_result;
end;
$$;

create function api.content_staff_rights()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.content_staff_rights();
$$;

comment on function api.content_staff_rights() is
  'Story 6.2: every rights record with its verified and draft revisions, for Media, Pastors and Admins.';

create function app.content_banner_revision_json(p_item_id uuid, p_revision_no integer)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'revision_no', r.revision_no,
    'banner_kind', r.banner_kind,
    'theme_year', r.theme_year,
    'title', r.title,
    'subtitle', r.subtitle,
    'alt_text', r.alt_text,
    'event_id', r.event_id,
    'event_title', (select coalesce(el.title, ed.title)
                      from app.content_items e
                      left join app.content_event_revisions el
                        on el.item_id = e.item_id and el.revision_no = e.live_revision_no
                      left join app.content_event_revisions ed
                        on ed.item_id = e.item_id and ed.revision_no = e.draft_revision_no
                     where e.item_id = r.event_id),
    'image', (select jsonb_build_object('asset_id', a.asset_id, 'media_type', a.media_type,
                                        'byte_size', a.byte_size, 'width', a.width,
                                        'height', a.height)
                from app.content_revision_files f
                join app.content_assets a on a.asset_id = f.asset_id
               where f.item_id = r.item_id and f.revision_no = r.revision_no and f.slot = 'image'),
    'rights', (select jsonb_build_object(
                        'rights_id', ri.item_id,
                        'label', coalesce(rl.label, rd.label),
                        'state', ri.lifecycle_state,
                        'live_revision_no', ri.live_revision_no,
                        'display', app.content_rights_clear(ri.item_id, 'display'))
                 from app.content_revision_files f
                 join app.content_items ri on ri.item_id = f.rights_id
                 left join app.content_rights_revisions rl
                   on rl.item_id = ri.item_id and rl.revision_no = ri.live_revision_no
                 left join app.content_rights_revisions rd
                   on rd.item_id = ri.item_id and rd.revision_no = ri.draft_revision_no
                where f.item_id = r.item_id and f.revision_no = r.revision_no and f.slot = 'image'),
    'saved_at', app.cmd_utc(r.saved_at),
    'saved_by', app.content_editor_name(r.saved_by_member))
    from app.content_banner_revisions r
   where r.item_id = p_item_id and r.revision_no = p_revision_no;
$$;

-- A published banner's public image state: shown (its object is in the public bucket), waiting
-- (it should be public; the next sync places it), event_not_public (linked to an event that is not
-- public now) or blocked (its image or rights no longer allow it). Null when not published.
create function app.content_banner_public_image(p_item_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when i.lifecycle_state <> 'published' then null
    when not app.content_banner_public_condition(jsonb_build_object('item_id', i.item_id))
      then 'event_not_public'
    when not exists (select 1 from app.content_live_file(i.item_id, 'image')) then 'blocked'
    when app.content_public_file(i.item_id, 'image') is null then 'waiting'
    else 'shown'
  end
    from app.content_items i
    left join app.content_banner_revisions r
      on r.item_id = i.item_id and r.revision_no = i.live_revision_no
   where i.item_id = p_item_id;
$$;

create function app.content_staff_banner_json(p_item_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'banner_id', i.item_id,
    'revision', i.revision,
    'state', i.lifecycle_state,
    'created_at', app.cmd_utc(i.created_at),
    'created_by', app.content_editor_name(i.created_by_member),
    'updated_at', app.cmd_utc(i.updated_at),
    'published_at', app.cmd_utc(i.published_at),
    'published_by', case when i.published_by_member is not null
                         then app.content_editor_name(i.published_by_member) end,
    'withdrawn_at', app.cmd_utc(i.withdrawn_at),
    'archived_at', app.cmd_utc(i.archived_at),
    'public_image', app.content_banner_public_image(i.item_id),
    'live', case when i.live_revision_no is not null
                 then app.content_banner_revision_json(i.item_id, i.live_revision_no) end,
    'draft', case when i.draft_revision_no is not null
                  then app.content_banner_revision_json(i.item_id, i.draft_revision_no) end)
    from app.content_items i
   where i.item_id = p_item_id;
$$;

-- Every banner with its live and draft revisions, its public image state and the count of public
-- objects still to remove, for the editors of banners: archived ones last, then the theme first,
-- then latest change first; at most 200.
create function app.content_staff_banners()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_editor record;
  v_result jsonb;
begin
  select e.* into v_editor from app.content_require_editor('banner') e;
  with ranked as (
    select i.item_id,
           row_number() over (
             order by (i.lifecycle_state = 'archived'),
                      (coalesce(d.banner_kind, l.banner_kind) = 'campaign'),
                      i.updated_at desc, i.item_id) as rn
      from app.content_items i
      left join app.content_banner_revisions l
        on l.item_id = i.item_id and l.revision_no = i.live_revision_no
      left join app.content_banner_revisions d
        on d.item_id = i.item_id and d.revision_no = i.draft_revision_no
     where i.kind = 'banner')
  select jsonb_build_object(
           'capacity', v_editor.capacity,
           'banners', coalesce(jsonb_agg(app.content_staff_banner_json(k.item_id) order by k.rn)
                                 filter (where k.rn <= 200), '[]'::jsonb),
           'removals_pending', (select count(*) from app.content_public_removals()),
           'truncated', count(*) > 200)
    into v_result
    from ranked k;
  return v_result;
end;
$$;

create function api.content_staff_banners()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.content_staff_banners();
$$;

comment on function api.content_staff_banners() is
  'Story 6.2: every Home banner with its live and draft revisions, for Media, Pastors and Admins.';

-- The content-assets Edge function's sync plan (any content editor): public files to place (at
-- most 50 per call) and public objects to remove (at most 200 per call), with the full counts.
create function app.content_file_plan()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_editor record;
begin
  select e.* into v_editor from app.content_require_editor('asset') e;
  return (
    with place as (
      select d.public_path, d.draft_path, d.media_type
        from app.content_public_files_desired() d
       where not app.content_public_object_present(d.public_path)),
    remove as (
      select r.public_path from app.content_public_removals() r)
    select jsonb_build_object(
             'place', coalesce((select jsonb_agg(jsonb_build_object('public_path', p.public_path,
                                                                    'draft_path', p.draft_path,
                                                                    'media_type', p.media_type)
                                                 order by p.public_path)
                                  from (select * from place order by public_path limit 50) p),
                               '[]'::jsonb),
             'remove', coalesce((select jsonb_agg(x.public_path order by x.public_path)
                                   from (select * from remove order by public_path limit 200) x),
                                '[]'::jsonb),
             'waiting', (select count(*) from place),
             'removals_pending', (select count(*) from remove)));
end;
$$;

create function api.content_file_plan()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.content_file_plan();
$$;

comment on function api.content_file_plan() is
  'Story 6.2: the public files to place and remove (for the content-assets Edge function; editors).';

-- The draft object of an asset, for the Edge function's preview (editors of the asset's item kind
-- only): {asset: {draft_path, media_type}} or {asset: null}.
create function app.content_asset_preview(p_asset_id uuid)
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
   where a.asset_id = p_asset_id and a.state = 'ready'
     and app.content_editor_capacity(v_editor.member_id, i.kind) is not null;
  return jsonb_build_object('asset', v_result);
end;
$$;

create function api.content_asset_preview(asset_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.content_asset_preview($1);
$$;

comment on function api.content_asset_preview(uuid) is
  'Story 6.2: the draft object of an uploaded file, for the content-assets preview (editors).';

-- ---------------------------------------------------------------------------------------------
-- Erase parts (story 2.11 contract, run by story 6.1's Content deletion hook)
-- ---------------------------------------------------------------------------------------------

-- Rights revisions: saved and verified attribution becomes the nil UUID.
create function app.content_rights_erase_part(p_input jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_input ->> 'member_id')::uuid;
  v_account uuid := nullif(p_input ->> 'account_id', '')::uuid;
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
begin
  if p_input ->> 'phase' = 'erase' then
    update app.content_rights_revisions r set saved_by_member = v_nil where r.saved_by_member = v_member;
    update app.content_rights_revisions r set published_by_member = v_nil
     where r.published_by_member = v_member;
    if v_account is not null then
      update app.content_rights_revisions r set saved_by_account = v_nil
       where r.saved_by_account = v_account;
      update app.content_rights_revisions r set published_by_account = v_nil
       where r.published_by_account = v_account;
    end if;
  end if;
  return (select count(*) from app.content_rights_revisions r
           where r.saved_by_member = v_member or r.published_by_member = v_member
              or r.saved_by_account = v_account or r.published_by_account = v_account)::integer;
end;
$$;

-- Banner revisions: saved and published attribution becomes the nil UUID.
create function app.content_banner_erase_part(p_input jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_input ->> 'member_id')::uuid;
  v_account uuid := nullif(p_input ->> 'account_id', '')::uuid;
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
begin
  if p_input ->> 'phase' = 'erase' then
    update app.content_banner_revisions r set saved_by_member = v_nil where r.saved_by_member = v_member;
    update app.content_banner_revisions r set published_by_member = v_nil
     where r.published_by_member = v_member;
    if v_account is not null then
      update app.content_banner_revisions r set saved_by_account = v_nil
       where r.saved_by_account = v_account;
      update app.content_banner_revisions r set published_by_account = v_nil
       where r.published_by_account = v_account;
    end if;
  end if;
  return (select count(*) from app.content_banner_revisions r
           where r.saved_by_member = v_member or r.published_by_member = v_member
              or r.saved_by_account = v_account or r.published_by_account = v_account)::integer;
end;
$$;

-- Uploads: uploader attribution becomes the nil UUID (the file itself is church content).
create function app.content_asset_erase_part(p_input jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_input ->> 'member_id')::uuid;
  v_account uuid := nullif(p_input ->> 'account_id', '')::uuid;
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
begin
  if p_input ->> 'phase' = 'erase' then
    update app.content_assets a set uploaded_by_member = v_nil where a.uploaded_by_member = v_member;
    if v_account is not null then
      update app.content_assets a set uploaded_by_account = v_nil where a.uploaded_by_account = v_account;
    end if;
  end if;
  return (select count(*) from app.content_assets a
           where a.uploaded_by_member = v_member or a.uploaded_by_account = v_account)::integer;
end;
$$;

select app.content_register_erase_part('rights_revisions',
  'app.content_rights_erase_part(jsonb)'::regprocedure);
select app.content_register_erase_part('banner_revisions',
  'app.content_banner_erase_part(jsonb)'::regprocedure);
select app.content_register_erase_part('asset_uploads',
  'app.content_asset_erase_part(jsonb)'::regprocedure);

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.content_rights_revision_guard(),
  app.content_banner_revision_guard(),
  app.content_revision_files_guard(),
  app.content_payload_uuid(jsonb, text),
  app.content_payload_optional_uuid(jsonb, text),
  app.content_payload_int(jsonb, text),
  app.content_payload_bool(jsonb, text),
  app.content_register_public_condition(text, regprocedure),
  app.content_item_public(text, uuid),
  app.content_banner_public_condition(jsonb),
  app.content_q5_uses(text),
  app.content_rights_clear(uuid, text),
  app.content_public_path(text, uuid, integer, text, text),
  app.content_public_object_present(text),
  app.content_public_files_desired(),
  app.content_live_file(uuid, text),
  app.content_public_file(uuid, text),
  app.content_public_removals(),
  app.content_rights_fields(jsonb),
  app.content_rights_create(uuid, bigint, jsonb),
  app.content_rights_save(uuid, bigint, jsonb),
  app.content_lifecycle_id(jsonb, text),
  app.content_rights_verify(uuid, bigint, jsonb),
  app.content_rights_withdraw(uuid, bigint, jsonb),
  app.content_rights_archive(uuid, bigint, jsonb),
  app.content_asset_begin(uuid, bigint, jsonb),
  app.content_asset_complete(uuid, bigint, jsonb),
  app.content_file_attach(uuid, integer, text, text, uuid, uuid),
  app.content_asset_error(uuid, uuid, text),
  app.content_rights_ref_error(uuid),
  app.content_banner_fields(jsonb),
  app.content_banner_create(uuid, bigint, jsonb),
  app.content_banner_save(uuid, bigint, jsonb),
  app.content_banner_publish(uuid, bigint, jsonb),
  app.content_banner_withdraw(uuid, bigint, jsonb),
  app.content_banner_archive(uuid, bigint, jsonb),
  app.content_public_banner_json(uuid),
  app.content_public_banners(),
  api.content_public_banners(),
  app.content_require_editor(text),
  app.content_rights_revision_json(uuid, integer),
  app.content_staff_rights_json(uuid),
  app.content_staff_rights(),
  api.content_staff_rights(),
  app.content_banner_revision_json(uuid, integer),
  app.content_banner_public_image(uuid),
  app.content_staff_banner_json(uuid),
  app.content_staff_banners(),
  api.content_staff_banners(),
  app.content_file_plan(),
  api.content_file_plan(),
  app.content_asset_preview(uuid),
  api.content_asset_preview(uuid),
  app.content_rights_erase_part(jsonb),
  app.content_banner_erase_part(jsonb),
  app.content_asset_erase_part(jsonb)
  from public, anon, authenticated, service_role;

grant execute on function app.content_public_banners() to anon, authenticated;
grant execute on function api.content_public_banners() to anon, authenticated;
grant execute on function app.content_staff_rights() to authenticated;
grant execute on function api.content_staff_rights() to authenticated;
grant execute on function app.content_staff_banners() to authenticated;
grant execute on function api.content_staff_banners() to authenticated;
grant execute on function app.content_file_plan() to authenticated;
grant execute on function api.content_file_plan() to authenticated;
grant execute on function app.content_asset_preview(uuid) to authenticated;
grant execute on function api.content_asset_preview(uuid) to authenticated;

notify pgrst, 'reload schema';
