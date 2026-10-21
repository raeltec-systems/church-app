-- Publish an event on staff web and read it as a guest on the mobile Calendar (story 6.1; AD-1,
-- AD-2, AD-4, AD-13, AD-14, AD-15).
--
-- Content becomes an active owner (module `content`, prefix `content_`, registered since story
-- 1.5 with edges to platform, identity, duties, followups and notifications). This tracer adds
-- what every later content kind reuses:
--
--   * The shared publication lifecycle. app.content_items is one aggregate per published thing,
--     whatever its kind: state draft (never published), published, withdrawn or archived; the live
--     revision number (the current published revision, kept while withdrawn), the open private
--     draft revision number and the aggregate revision (the expected_revision of every command).
--     Each kind keeps its revisions in its own table (events: app.content_event_revisions). A save
--     writes the open draft or opens the next revision number; publishing makes the draft live,
--     and the live revision stays public until a replacement is published. A published revision's
--     content is immutable (trigger); only its attribution can be anonymised. Withdraw hides,
--     archive retires (every later command is refused).
--   * Registries instead of shared lists: content kinds with their editor roles
--     (app.content_kinds; events: admin, pastor, media), commands (app.content_register_command)
--     and deletion erase parts (app.content_register_erase_part). Later entries add rows; they
--     never replace the dispatch, the authorizer or the deletion handler.
--   * Commands through the 1.4 envelope (api.content_command, authorizer `content`):
--     content.create_event, content.save_event, content.publish_event, content.withdraw_event and
--     content.archive_event, for the kind's editor roles only.
--   * The first unauthenticated read contract: api.content_public_events() and
--     api.content_public_event(event_id), granted to anon and authenticated, exposing only the
--     current published projection of an event (no draft, editor identity or private field).
--     Security definer functions rather than views, so no client role holds any privilege on a
--     Content table.
--   * The editors' read api.content_staff_events() (live member access and an editor role).
--   * Content-free audit app.content_audit (ids, codes, revisions).
--   * Content's one deletion hook app.content_erase_member: it anonymises lifecycle and audit
--     attribution, then runs every registered erase part (events: revision attribution). No row
--     deletion, so no _rows file.
--
-- Lock order (AD-2): the actor's Identity role grants FOR SHARE (authorizer) -> command receipt ->
-- content item FOR UPDATE -> the kind's revision rows.
--
-- No destructive statements and no row deletions. ASCII only, no backslashes.

-- ---------------------------------------------------------------------------------------------
-- Vocabularies
-- ---------------------------------------------------------------------------------------------

create function app.content_state_ok(p_kind text, p_value text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_value is not null and case p_kind
    when 'lifecycle_state' then p_value in ('draft', 'published', 'withdrawn', 'archived')
    when 'capacity' then p_value in ('admin', 'pastor', 'media')
    when 'audit_action' then p_value in ('created', 'draft_saved', 'published', 'withdrawn',
                                         'archived')
    else false end;
$$;

comment on function app.content_state_ok(text, text) is
  'Content state vocabularies (story 6.1). Later stories widen them by replacing this function.';

-- ---------------------------------------------------------------------------------------------
-- Registries (rows added by each content kind's own migration)
-- ---------------------------------------------------------------------------------------------

-- A content kind and the roles that edit it, in the order a capacity is recorded.
create table app.content_kinds (
  kind text primary key check (kind ~ '^[a-z][a-z0-9_]{0,30}$'),
  editor_roles text[] not null
    check (cardinality(editor_roles) between 1 and 3
           and editor_roles <@ array['admin', 'pastor', 'media']::text[]),
  description text not null check (length(btrim(description)) between 1 and 200),
  registered_at timestamptz not null default now()
);

comment on table app.content_kinds is
  'owner: content. Content kinds and the Identity roles that may edit them (story 6.1).';

-- A content command, its kind and its handler (uuid, bigint, jsonb) -> jsonb.
create table app.content_commands (
  command text primary key check (command ~ '^content[.][a-z][a-z0-9_]{0,62}$'),
  kind text not null references app.content_kinds (kind),
  handler text not null unique,
  creates boolean not null,
  registered_at timestamptz not null default now()
);

comment on table app.content_commands is
  'owner: content. The registered content commands (creates: expected_revision must be null).';

-- A per-kind erase part of the Content deletion handler: (jsonb) -> integer remaining.
create table app.content_erase_parts (
  part text primary key check (part ~ '^[a-z][a-z0-9_]{0,40}$'),
  handler text not null unique,
  registered_at timestamptz not null default now()
);

comment on table app.content_erase_parts is
  'owner: content. Erase parts run by app.content_erase_member, one per kind that keeps member data.';

-- ---------------------------------------------------------------------------------------------
-- The shared lifecycle aggregate and audit
-- ---------------------------------------------------------------------------------------------

create table app.content_items (
  item_id uuid primary key default gen_random_uuid(),
  kind text not null references app.content_kinds (kind),
  lifecycle_state text not null default 'draft'
    check (app.content_state_ok('lifecycle_state', lifecycle_state)),
  live_revision_no integer check (live_revision_no >= 1),
  draft_revision_no integer check (draft_revision_no >= 1),
  last_revision_no integer not null default 1 check (last_revision_no >= 1),
  revision bigint not null default 1 check (revision >= 1),
  created_by_member uuid not null,
  created_by_account uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  published_at timestamptz,
  published_by_member uuid,
  published_by_account uuid,
  withdrawn_at timestamptz,
  archived_at timestamptz,
  check (lifecycle_state <> 'draft' or (live_revision_no is null and draft_revision_no is not null)),
  check (lifecycle_state not in ('published', 'withdrawn') or live_revision_no is not null),
  check (draft_revision_no is null or live_revision_no is null or draft_revision_no > live_revision_no),
  check (coalesce(draft_revision_no, 1) <= last_revision_no
         and coalesce(live_revision_no, 1) <= last_revision_no),
  check ((published_at is null) = (published_by_member is null)
         and (published_by_member is null) = (published_by_account is null)),
  check ((lifecycle_state = 'archived') = (archived_at is not null))
);

create index content_items_kind_state on app.content_items (kind, lifecycle_state);

comment on table app.content_items is
  'owner: content. One published thing of any kind: draft/published/withdrawn/archived, its live '
  'and draft revision numbers and the aggregate revision (story 6.1).';

-- Content-free: ids, codes and revisions only. Never titles, names or free text.
create table app.content_audit (
  event_id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  environment text not null default app.platform_current_environment(),
  action text not null check (app.content_state_ok('audit_action', action)),
  actor_member_id uuid not null,
  actor_account_id uuid not null,
  actor_capacity text not null check (app.content_state_ok('capacity', actor_capacity)),
  command_request_id uuid,
  item_id uuid not null,
  kind text not null,
  revision_no integer,
  revision_after bigint
);

create index content_audit_item on app.content_audit (item_id, event_id);
create index content_audit_actor on app.content_audit (actor_member_id);

comment on table app.content_audit is
  'owner: content. Attributed lifecycle changes of content items: ids, codes and revisions only.';

-- ---------------------------------------------------------------------------------------------
-- Events (the first kind)
-- ---------------------------------------------------------------------------------------------

insert into app.content_kinds (kind, editor_roles, description) values
  ('event', array['admin', 'pastor', 'media'], 'Church events on the public Calendar (story 6.1)');

create table app.content_event_revisions (
  item_id uuid not null references app.content_items (item_id),
  revision_no integer not null check (revision_no >= 1),
  title text not null check (length(title) between 1 and 120),
  description text not null check (length(description) between 1 and 2000),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  location text not null check (length(location) between 1 and 160),
  saved_by_member uuid not null,
  saved_by_account uuid not null,
  saved_at timestamptz not null default now(),
  published_at timestamptz,
  published_by_member uuid,
  published_by_account uuid,
  primary key (item_id, revision_no),
  check (ends_at > starts_at),
  check (ends_at - starts_at <= interval '31 days'),
  check ((published_at is null) = (published_by_member is null)
         and (published_by_member is null) = (published_by_account is null))
);

comment on table app.content_event_revisions is
  'owner: content. Event revisions: the open draft is editable; a published revision is immutable '
  '(only its attribution can be anonymised).';

alter table app.content_kinds enable row level security;
alter table app.content_commands enable row level security;
alter table app.content_erase_parts enable row level security;
alter table app.content_items enable row level security;
alter table app.content_audit enable row level security;
alter table app.content_event_revisions enable row level security;
revoke all on table app.content_kinds, app.content_commands, app.content_erase_parts,
                    app.content_items, app.content_audit, app.content_event_revisions
  from public, anon, authenticated, service_role;
revoke all on sequence app.content_audit_event_id_seq from public, anon, authenticated, service_role;

-- A published revision's content never changes; its attribution may be anonymised.
create function app.content_event_revision_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.published_at is not null
     and (new.item_id, new.revision_no, new.title, new.description, new.starts_at, new.ends_at,
          new.location, new.published_at)
         is distinct from
         (old.item_id, old.revision_no, old.title, old.description, old.starts_at, old.ends_at,
          old.location, old.published_at) then
    raise exception using errcode = 'PCNT1', message = 'a published content revision is immutable';
  end if;
  return new;
end;
$$;

create trigger content_event_revisions_immutable
  before update on app.content_event_revisions
  for each row execute function app.content_event_revision_guard();

-- ---------------------------------------------------------------------------------------------
-- Registration functions (migration-time only; no client role can execute them)
-- ---------------------------------------------------------------------------------------------

-- Registers a content command. The handler must be a Content app function
-- (p_actor uuid, p_expected_revision bigint, p_payload jsonb) returns jsonb with an empty
-- search_path; p_creates means expected_revision must be null (a create).
create function app.content_register_command(p_command text, p_kind text, p_handler regprocedure,
                                             p_creates boolean)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v record;
begin
  if p_command is null or p_command !~ '^content[.][a-z][a-z0-9_]{0,62}$' then
    perform app.contract_registration_fail('a content command is named content.<verb>');
  end if;
  if not exists (select 1 from app.content_kinds k where k.kind = p_kind) then
    perform app.contract_registration_fail('unknown content kind: ' || coalesce(p_kind, '<null>'));
  end if;
  select n.nspname, p.pronargs, p.proargtypes, p.prorettype, p.proretset, p.proconfig
    into v
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where p.oid = p_handler;
  if not found or v.nspname <> 'app'
     or app.contract_function_module(p_handler) is distinct from 'content' then
    perform app.contract_registration_fail(format('handler %s is not a Content app function', p_handler));
  end if;
  if v.pronargs <> 3 or v.proargtypes[0] <> 'uuid'::regtype::oid
     or v.proargtypes[1] <> 'bigint'::regtype::oid or v.proargtypes[2] <> 'jsonb'::regtype::oid
     or v.prorettype <> 'jsonb'::regtype::oid or v.proretset then
    perform app.contract_registration_fail(
      format('handler %s must take (uuid, bigint, jsonb) and return jsonb', p_handler));
  end if;
  if not coalesce('search_path=""' = any (v.proconfig), false) then
    perform app.contract_registration_fail(format('handler %s must set search_path = ''''', p_handler));
  end if;
  insert into app.content_commands (command, kind, handler, creates)
  values (p_command, p_kind, p_handler::text, coalesce(p_creates, false));
end;
$$;

-- Registers an erase part of the Content deletion handler: a Content app function
-- (p_input jsonb) returns integer that, given the 2.11 hook input, anonymises or erases its own
-- rows when phase = erase and always answers how many of the member's references are left.
create function app.content_register_erase_part(p_part text, p_handler regprocedure)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_part is null or p_part !~ '^[a-z][a-z0-9_]{0,40}$' then
    perform app.contract_registration_fail('an erase part is named in lower_snake_case');
  end if;
  insert into app.content_erase_parts (part, handler)
  values (p_part, app.contract_validate_handler('content', p_handler, 'integer'::regtype));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------

-- The capacity in which a member edits a kind: the first of the kind's editor roles the member
-- holds now, or null.
create function app.content_editor_capacity(p_member_id uuid, p_kind text)
returns text
language sql
stable
set search_path = ''
as $$
  select r.role
    from app.content_kinds k
   cross join lateral unnest(k.editor_roles) with ordinality as r (role, ord)
   where k.kind = p_kind and p_member_id is not null
     and app.identity_member_has_role(p_member_id, r.role)
   order by r.ord
   limit 1;
$$;

-- The acting editor of a content command on p_kind (live member access, one of the kind's
-- editor roles). Anything else is forbidden.
create function app.content_command_actor(
  p_actor uuid,
  p_kind text,
  out member_id uuid,
  out account_id uuid,
  out capacity text
)
language plpgsql
set search_path = ''
as $$
begin
  select e.member_id into member_id from app.identity_evaluate_grant(null, null, null) e
   where e.outcome = 'granted';
  if member_id is null then
    perform app.cmd_fail('forbidden');
  end if;
  capacity := app.content_editor_capacity(member_id, p_kind);
  if capacity is null then
    perform app.cmd_fail('forbidden');
  end if;
  account_id := p_actor;
end;
$$;

-- An editor's name as editors read it: the member's display name, or `Former member` once the
-- member was erased (nil UUID) or no longer exists.
create function app.content_editor_name(p_member_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select m.display_name from app.identity_members m
      where m.member_id = p_member_id
        and p_member_id <> '00000000-0000-0000-0000-000000000000'::uuid),
    'Former member');
$$;

-- A text field: trimmed; single-line text has collapsed whitespace; multiline text keeps line
-- breaks (CRLF normalised). Too long: too_long; control or format characters: invalid. A missing
-- or blank value is null with no error (the caller decides whether it is required).
create function app.content_free_text(p_value jsonb, p_max integer, p_multiline boolean,
                                      out error text, out value text)
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return;
  end if;
  if jsonb_typeof(p_value) <> 'string' then
    error := 'invalid';
    return;
  end if;
  value := btrim(p_value #>> '{}');
  if p_multiline then
    value := btrim(replace(value, chr(13) || chr(10), chr(10)));
  else
    value := regexp_replace(value, '[[:space:]]+', ' ', 'g');
  end if;
  if value = '' then
    value := null;
    return;
  end if;
  if length(value) > p_max then
    error := 'too_long';
  elsif (not p_multiline and value ~ '[[:cntrl:]]')
        or (p_multiline and value ~ ('[' || chr(1) || '-' || chr(9) || chr(11) || '-' || chr(31)
                                     || chr(127) || ']'))
        or value ~ ('[' || chr(173) || chr(8203) || '-' || chr(8207) || chr(8234) || '-' || chr(8238)
                    || chr(8288) || '-' || chr(8292) || chr(8294) || '-' || chr(8303) || chr(65279) || ']') then
    error := 'invalid';
  end if;
  if error is not null then
    value := null;
  end if;
end;
$$;

-- A UTC RFC3339 instant (wire contract), or its error code.
create function app.content_instant(p_value jsonb, out error text, out value timestamptz)
language plpgsql
immutable
set search_path = ''
as $$
begin
  error := app.contract_instant_error(p_value);
  if error is null then
    value := (p_value #>> '{}')::timestamptz;
  end if;
end;
$$;

create function app.content_audit_event(
  p_action text,
  p_member uuid,
  p_account uuid,
  p_capacity text,
  p_command text,
  p_item uuid,
  p_kind text,
  p_revision_no integer,
  p_revision_after bigint
) returns void
language sql
set search_path = ''
as $$
  insert into app.content_audit (action, actor_member_id, actor_account_id, actor_capacity,
                                 command_request_id, item_id, kind, revision_no, revision_after)
  values (p_action, p_member, p_account, p_capacity,
          app.cmd_current_request_id(p_account, p_command), p_item, p_kind, p_revision_no,
          p_revision_after);
$$;

-- ---------------------------------------------------------------------------------------------
-- The lifecycle helper (kind-agnostic; every content kind's commands call it)
-- ---------------------------------------------------------------------------------------------

-- Opens a new item of p_kind as a private draft (revision 1, draft revision 1), audited.
create function app.content_item_open(p_kind text, p_member uuid, p_account uuid, p_capacity text,
                                      p_command text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_item uuid;
begin
  insert into app.content_items (kind, lifecycle_state, draft_revision_no, last_revision_no,
                                 created_by_member, created_by_account)
  values (p_kind, 'draft', 1, 1, p_member, p_account)
  returning item_id into v_item;
  perform app.content_audit_event('created', p_member, p_account, p_capacity, p_command, v_item,
                                  p_kind, 1, 1);
  return v_item;
end;
$$;

-- Locks an item of p_kind for a command: not_found when it is absent or of another kind,
-- conflict with the current revision when stale, validation_failed {<p_key>: archived} once
-- archived.
create function app.content_item_lock(p_item_id uuid, p_kind text, p_expected bigint, p_key text)
returns app.content_items
language plpgsql
set search_path = ''
as $$
declare
  v app.content_items;
begin
  select i.* into v from app.content_items i where i.item_id = p_item_id for update;
  if not found or v.kind <> p_kind then
    perform app.cmd_fail('not_found');
  end if;
  if v.revision is distinct from p_expected then
    perform app.cmd_fail('conflict', null, v.revision);
  end if;
  if v.lifecycle_state = 'archived' then
    perform app.cmd_fail('validation_failed', jsonb_build_object(p_key, 'archived'));
  end if;
  return v;
end;
$$;

-- The revision number a draft save writes: the open draft, else the next number.
create function app.content_item_draft_no(p_item app.content_items)
returns integer
language sql
immutable
set search_path = ''
as $$
  select coalesce(p_item.draft_revision_no, p_item.last_revision_no + 1);
$$;

-- Records a saved draft revision p_draft_no (revision + 1, audited). Returns the new revision.
create function app.content_item_saved(p_item app.content_items, p_draft_no integer,
                                       p_member uuid, p_account uuid, p_capacity text,
                                       p_command text)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_revision bigint;
begin
  update app.content_items i
     set draft_revision_no = p_draft_no,
         last_revision_no = greatest(i.last_revision_no, p_draft_no),
         revision = i.revision + 1,
         updated_at = now()
   where i.item_id = p_item.item_id
  returning i.revision into v_revision;
  perform app.content_audit_event('draft_saved', p_member, p_account, p_capacity, p_command,
                                  p_item.item_id, p_item.kind, p_draft_no, v_revision);
  return v_revision;
end;
$$;

-- Publishes: the open draft becomes the live revision (the earlier live revision stops being
-- public in the same statement); with no draft, a withdrawn item's live revision is published
-- again. Returns the published revision number. Nothing to publish:
-- validation_failed {<p_key>: nothing_to_publish}.
create function app.content_item_publish(p_item app.content_items, p_member uuid, p_account uuid,
                                         p_capacity text, p_command text, p_key text)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_no integer;
  v_revision bigint;
begin
  v_no := coalesce(p_item.draft_revision_no,
                   case when p_item.lifecycle_state = 'withdrawn' then p_item.live_revision_no end);
  if v_no is null then
    perform app.cmd_fail('validation_failed', jsonb_build_object(p_key, 'nothing_to_publish'));
  end if;
  update app.content_items i
     set lifecycle_state = 'published',
         live_revision_no = v_no,
         draft_revision_no = null,
         revision = i.revision + 1,
         updated_at = now(),
         published_at = now(),
         published_by_member = p_member,
         published_by_account = p_account,
         withdrawn_at = null
   where i.item_id = p_item.item_id
  returning i.revision into v_revision;
  perform app.content_audit_event('published', p_member, p_account, p_capacity, p_command,
                                  p_item.item_id, p_item.kind, v_no, v_revision);
  return v_no;
end;
$$;

-- Withdraws a published item from every public read (its live revision and any open draft are
-- kept; publishing again brings it back). Not published: validation_failed {<p_key>: not_published}.
create function app.content_item_withdraw(p_item app.content_items, p_member uuid, p_account uuid,
                                          p_capacity text, p_command text, p_key text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_revision bigint;
begin
  if p_item.lifecycle_state <> 'published' then
    perform app.cmd_fail('validation_failed', jsonb_build_object(p_key, 'not_published'));
  end if;
  update app.content_items i
     set lifecycle_state = 'withdrawn',
         withdrawn_at = now(),
         revision = i.revision + 1,
         updated_at = now()
   where i.item_id = p_item.item_id
  returning i.revision into v_revision;
  perform app.content_audit_event('withdrawn', p_member, p_account, p_capacity, p_command,
                                  p_item.item_id, p_item.kind, p_item.live_revision_no, v_revision);
end;
$$;

-- Archives an item (from any state but archived): it leaves every public read and refuses every
-- later command. Its revisions are kept.
create function app.content_item_archive(p_item app.content_items, p_member uuid, p_account uuid,
                                         p_capacity text, p_command text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_revision bigint;
begin
  update app.content_items i
     set lifecycle_state = 'archived',
         archived_at = now(),
         revision = i.revision + 1,
         updated_at = now()
   where i.item_id = p_item.item_id
  returning i.revision into v_revision;
  perform app.content_audit_event('archived', p_member, p_account, p_capacity, p_command,
                                  p_item.item_id, p_item.kind, p_item.live_revision_no, v_revision);
end;
$$;

-- A content command's outcome: ids, state and revisions only (receipts keep it; no names).
create function app.content_item_outcome(p_item_id uuid, p_key text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'content_item',
    'aggregate_id', i.item_id,
    'revision', i.revision,
    'data', jsonb_build_object(p_key, i.item_id, 'revision', i.revision,
                               'state', i.lifecycle_state,
                               'live_revision_no', i.live_revision_no,
                               'draft_revision_no', i.draft_revision_no))
    from app.content_items i where i.item_id = p_item_id;
$$;

-- ---------------------------------------------------------------------------------------------
-- Event commands
-- ---------------------------------------------------------------------------------------------

-- The five event fields of a payload with their field errors: title (120), description (2000,
-- multiline) and location (160) required; starts_at and ends_at UTC instants, the start within a
-- year back and five years ahead, the end after the start and at most 31 days later.
create function app.content_event_fields(
  p_payload jsonb,
  out errors jsonb,
  out title text,
  out description text,
  out starts_at timestamptz,
  out ends_at timestamptz,
  out location text
)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_error text;
begin
  errors := '{}'::jsonb;
  select t.error, t.value into v_error, title from app.content_free_text(p_payload -> 'title', 120, false) t;
  if v_error is null and title is null then
    v_error := 'required';
  end if;
  if v_error is not null then
    errors := errors || jsonb_build_object('title', v_error);
  end if;
  select t.error, t.value into v_error, description
    from app.content_free_text(p_payload -> 'description', 2000, true) t;
  if v_error is null and description is null then
    v_error := 'required';
  end if;
  if v_error is not null then
    errors := errors || jsonb_build_object('description', v_error);
  end if;
  select t.error, t.value into v_error, location
    from app.content_free_text(p_payload -> 'location', 160, false) t;
  if v_error is null and location is null then
    v_error := 'required';
  end if;
  if v_error is not null then
    errors := errors || jsonb_build_object('location', v_error);
  end if;
  select t.error, t.value into v_error, starts_at from app.content_instant(p_payload -> 'starts_at') t;
  if v_error is null
     and (starts_at < now() - interval '366 days' or starts_at > now() + interval '5 years') then
    v_error := 'out_of_range';
  end if;
  if v_error is not null then
    errors := errors || jsonb_build_object('starts_at', v_error);
    starts_at := null;
  end if;
  select t.error, t.value into v_error, ends_at from app.content_instant(p_payload -> 'ends_at') t;
  if v_error is null and starts_at is not null then
    if ends_at <= starts_at then
      v_error := 'before_start';
    elsif ends_at - starts_at > interval '31 days' then
      v_error := 'too_long';
    end if;
  end if;
  if v_error is not null then
    errors := errors || jsonb_build_object('ends_at', v_error);
    ends_at := null;
  end if;
end;
$$;

-- An event_id field of a payload.
create function app.content_event_id(p_payload jsonb, out error text, out value uuid)
language plpgsql
immutable
set search_path = ''
as $$
begin
  error := app.contract_uuid_error(p_payload -> 'event_id');
  if error is null then
    value := (p_payload ->> 'event_id')::uuid;
  end if;
end;
$$;

-- content.create_event {title, description, starts_at, ends_at, location}; expected null. A new
-- private draft (revision 1, draft revision 1). The kind's editor roles only.
create function app.content_event_create(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  select a.* into v_actor from app.content_command_actor(p_actor, 'event') a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['title', 'description', 'starts_at', 'ends_at', 'location']);
  select f.* into v_fields from app.content_event_fields(p_payload) f;
  v_errors := v_errors || v_fields.errors;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_open('event', v_actor.member_id, v_actor.account_id, v_actor.capacity,
                                  'content.create_event');
  insert into app.content_event_revisions (item_id, revision_no, title, description, starts_at,
                                           ends_at, location, saved_by_member, saved_by_account)
  values (v_item, 1, v_fields.title, v_fields.description, v_fields.starts_at, v_fields.ends_at,
          v_fields.location, v_actor.member_id, v_actor.account_id);
  return app.content_item_outcome(v_item, 'event_id');
end;
$$;

-- content.save_event {event_id, title, description, starts_at, ends_at, location}; expected =
-- the event's revision. Writes the open draft, or opens the next draft revision of a published or
-- withdrawn event; the live revision stays public until a publish replaces it.
create function app.content_event_save(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  select a.* into v_actor from app.content_command_actor(p_actor, 'event') a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['event_id', 'title', 'description', 'starts_at', 'ends_at', 'location']);
  select t.error, t.value into v_error, v_id from app.content_event_id(p_payload) t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('event_id', v_error);
  end if;
  select f.* into v_fields from app.content_event_fields(p_payload) f;
  v_errors := v_errors || v_fields.errors;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_lock(v_id, 'event', p_expected_revision, 'event_id');
  v_no := app.content_item_draft_no(v_item);
  insert into app.content_event_revisions as r (item_id, revision_no, title, description, starts_at,
                                                ends_at, location, saved_by_member, saved_by_account)
  values (v_id, v_no, v_fields.title, v_fields.description, v_fields.starts_at, v_fields.ends_at,
          v_fields.location, v_actor.member_id, v_actor.account_id)
  on conflict (item_id, revision_no) do update
     set title = excluded.title,
         description = excluded.description,
         starts_at = excluded.starts_at,
         ends_at = excluded.ends_at,
         location = excluded.location,
         saved_by_member = excluded.saved_by_member,
         saved_by_account = excluded.saved_by_account,
         saved_at = now()
   where r.published_at is null;
  perform app.content_item_saved(v_item, v_no, v_actor.member_id, v_actor.account_id,
                                 v_actor.capacity, 'content.save_event');
  return app.content_item_outcome(v_id, 'event_id');
end;
$$;

-- content.publish_event {event_id}; expected = the event's revision. The open draft goes live
-- (or a withdrawn event's live revision comes back).
create function app.content_event_publish(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_error text;
  v_id uuid;
  v_item app.content_items;
  v_no integer;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'event') a;
  v_errors := app.contract_unknown_keys(p_payload, array['event_id']);
  select t.error, t.value into v_error, v_id from app.content_event_id(p_payload) t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('event_id', v_error);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_lock(v_id, 'event', p_expected_revision, 'event_id');
  v_no := app.content_item_publish(v_item, v_actor.member_id, v_actor.account_id, v_actor.capacity,
                                   'content.publish_event', 'event_id');
  -- A revision published again after a withdrawal keeps its first publication.
  update app.content_event_revisions r
     set published_at = now(),
         published_by_member = v_actor.member_id,
         published_by_account = v_actor.account_id
   where r.item_id = v_id and r.revision_no = v_no and r.published_at is null;
  return app.content_item_outcome(v_id, 'event_id');
end;
$$;

-- content.withdraw_event {event_id}; expected = the event's revision. Published events only.
create function app.content_event_withdraw(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_error text;
  v_id uuid;
  v_item app.content_items;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'event') a;
  v_errors := app.contract_unknown_keys(p_payload, array['event_id']);
  select t.error, t.value into v_error, v_id from app.content_event_id(p_payload) t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('event_id', v_error);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_lock(v_id, 'event', p_expected_revision, 'event_id');
  perform app.content_item_withdraw(v_item, v_actor.member_id, v_actor.account_id,
                                    v_actor.capacity, 'content.withdraw_event', 'event_id');
  return app.content_item_outcome(v_id, 'event_id');
end;
$$;

-- content.archive_event {event_id}; expected = the event's revision. Retires it from any state.
create function app.content_event_archive(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_error text;
  v_id uuid;
  v_item app.content_items;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'event') a;
  v_errors := app.contract_unknown_keys(p_payload, array['event_id']);
  select t.error, t.value into v_error, v_id from app.content_event_id(p_payload) t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('event_id', v_error);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_lock(v_id, 'event', p_expected_revision, 'event_id');
  perform app.content_item_archive(v_item, v_actor.member_id, v_actor.account_id,
                                   v_actor.capacity, 'content.archive_event');
  return app.content_item_outcome(v_id, 'event_id');
end;
$$;

select app.content_register_command('content.create_event', 'event',
  'app.content_event_create(uuid, bigint, jsonb)'::regprocedure, true);
select app.content_register_command('content.save_event', 'event',
  'app.content_event_save(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.publish_event', 'event',
  'app.content_event_publish(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.withdraw_event', 'event',
  'app.content_event_withdraw(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.archive_event', 'event',
  'app.content_event_archive(uuid, bigint, jsonb)'::regprocedure, false);

-- ---------------------------------------------------------------------------------------------
-- Command entry point, the registered `content` authorizer and the replay recheck
-- ---------------------------------------------------------------------------------------------

-- `content.*`: a registered command, a live member session and one of the command's kind's
-- editor roles. The actor's grants of those roles are share-locked here, so a concurrent
-- revocation waits for the command (AD-2: authority rows before the receipt).
create function app.content_authorize_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
  v_kind text;
begin
  select c.kind into v_kind from app.content_commands c where c.command = p_request ->> 'command';
  if v_kind is null then
    return false;
  end if;
  select e.* into r from app.identity_evaluate_grant(null, null, null) e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  if r.outcome <> 'granted' then
    return false;
  end if;
  perform 1
     from app.identity_grants g
     join app.content_kinds k on k.kind = v_kind
    where g.member_id = r.member_id and g.revoked_at is null and g.role = any (k.editor_roles)
      for share of g;
  return app.content_editor_capacity(r.member_id, v_kind) is not null;
end;
$$;

select app.cmd_register_authorizer('content', 'app.content_authorize_command(jsonb)'::regprocedure);

-- Replay recheck (AD-2): the actor still edits the stored item's kind.
create function app.content_in_scope(p_actor uuid, p_aggregate_type text, p_aggregate_id uuid)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_kind text;
begin
  if p_aggregate_type is distinct from 'content_item' or p_aggregate_id is null then
    return false;
  end if;
  select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
   where e.outcome = 'granted';
  if v_member is null then
    return false;
  end if;
  select i.kind into v_kind from app.content_items i where i.item_id = p_aggregate_id for share;
  return v_kind is not null and app.content_editor_capacity(v_member, v_kind) is not null;
end;
$$;

create function app.content_command(p_envelope jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_command app.content_commands;
begin
  if jsonb_typeof(p_envelope) = 'object' and jsonb_typeof(p_envelope -> 'command') = 'string' then
    select c.* into v_command from app.content_commands c where c.command = p_envelope ->> 'command';
  end if;
  return app.cmd_execute(
    p_envelope,
    case when v_command.command is not null then pg_catalog.to_regprocedure(v_command.handler) end,
    'app.content_in_scope(uuid, text, uuid)'::regprocedure,
    not coalesce(v_command.creates, false)
  );
end;
$$;

-- POST /rest/v1/rpc/content_command, Content-Profile: api,
-- body {version, command, request_id, expected_revision, payload}.
create function api.content_command(jsonb)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.content_command($1);
$$;

comment on function api.content_command(jsonb) is
  'Story 6.1: the Content publication lifecycle through the 1.4 envelope (events: '
  'content.create_event, save_event, publish_event, withdraw_event, archive_event).';

-- ---------------------------------------------------------------------------------------------
-- The public read contract (anonymous): the current published projection only
-- ---------------------------------------------------------------------------------------------

-- One published event as anyone may read it: no draft, editor identity or audit field.
create function app.content_public_event_json(p_item_id uuid)
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
    'published_at', app.cmd_utc(i.published_at))
    from app.content_items i
    join app.content_event_revisions r on r.item_id = i.item_id and r.revision_no = i.live_revision_no
   where i.item_id = p_item_id and i.kind = 'event' and i.lifecycle_state = 'published';
$$;

-- The published events that have not ended, soonest first; at most 200 (`truncated` says more
-- exist).
create function app.content_public_events()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with live as (
    select i.item_id, row_number() over (order by r.starts_at, i.item_id) as rn
      from app.content_items i
      join app.content_event_revisions r on r.item_id = i.item_id and r.revision_no = i.live_revision_no
     where i.kind = 'event' and i.lifecycle_state = 'published' and r.ends_at > now())
  select jsonb_build_object(
           'events', coalesce(jsonb_agg(app.content_public_event_json(l.item_id) order by l.rn)
                                filter (where l.rn <= 200), '[]'::jsonb),
           'truncated', count(*) > 200)
    from live l;
$$;

-- One published event, or {"event": null} for an unknown, draft-only, withdrawn or archived id.
create function app.content_public_event(p_event_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('event', app.content_public_event_json(p_event_id));
$$;

create function api.content_public_events()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select app.content_public_events();
$$;

comment on function api.content_public_events() is
  'Story 6.1, public (anon and authenticated): the published events that have not ended.';

create function api.content_public_event(event_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select app.content_public_event($1);
$$;

comment on function api.content_public_event(uuid) is
  'Story 6.1, public (anon and authenticated): one published event, or null.';

-- ---------------------------------------------------------------------------------------------
-- The editors' read
-- ---------------------------------------------------------------------------------------------

create function app.content_event_revision_json(p_item_id uuid, p_revision_no integer)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'revision_no', r.revision_no,
    'title', r.title,
    'description', r.description,
    'starts_at', app.cmd_utc(r.starts_at),
    'ends_at', app.cmd_utc(r.ends_at),
    'location', r.location,
    'saved_at', app.cmd_utc(r.saved_at),
    'saved_by', app.content_editor_name(r.saved_by_member))
    from app.content_event_revisions r
   where r.item_id = p_item_id and r.revision_no = p_revision_no;
$$;

create function app.content_staff_event_json(p_item_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'event_id', i.item_id,
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
    'live', case when i.live_revision_no is not null
                 then app.content_event_revision_json(i.item_id, i.live_revision_no) end,
    'draft', case when i.draft_revision_no is not null
                  then app.content_event_revision_json(i.item_id, i.draft_revision_no) end)
    from app.content_items i
   where i.item_id = p_item_id;
$$;

-- Every event with its live and draft revisions and attribution, for the editors of events
-- (Media, Pastor, Admin): archived ones last, the others latest start first; at most 500.
create function app.content_staff_events()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_capacity text;
  v_result jsonb;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  v_capacity := app.content_editor_capacity(v_member, 'event');
  if v_capacity is null then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  with ranked as (
    select i.item_id,
           row_number() over (
             order by (i.lifecycle_state = 'archived'),
                      coalesce(d.starts_at, l.starts_at) desc nulls last,
                      i.updated_at desc, i.item_id) as rn
      from app.content_items i
      left join app.content_event_revisions l
        on l.item_id = i.item_id and l.revision_no = i.live_revision_no
      left join app.content_event_revisions d
        on d.item_id = i.item_id and d.revision_no = i.draft_revision_no
     where i.kind = 'event')
  select jsonb_build_object(
           'capacity', v_capacity,
           'events', coalesce(jsonb_agg(app.content_staff_event_json(k.item_id) order by k.rn)
                                filter (where k.rn <= 500), '[]'::jsonb),
           'truncated', count(*) > 500)
    into v_result
    from ranked k;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

create function api.content_staff_events()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.content_staff_events();
$$;

comment on function api.content_staff_events() is
  'Story 6.1: every event with its live and draft revisions, for Media, Pastors and Admins.';

-- ---------------------------------------------------------------------------------------------
-- Deletion hook (story 2.11 contract) and the events erase part
-- ---------------------------------------------------------------------------------------------

-- The member's (or account's) references left in the lifecycle rows and the audit.
create function app.content_lifecycle_remaining(p_member_id uuid, p_account_id uuid)
returns integer
language sql
stable
set search_path = ''
as $$
  select ((select count(*) from app.content_items i
            where i.created_by_member = p_member_id or i.published_by_member = p_member_id
               or i.created_by_account = p_account_id or i.published_by_account = p_account_id)
        + (select count(*) from app.content_audit a
            where a.actor_member_id = p_member_id or a.actor_account_id = p_account_id))::integer;
$$;

-- Events erase part: revision attribution becomes the nil UUID (published revisions keep their
-- content; the guard trigger allows attribution changes only).
create function app.content_event_erase_part(p_input jsonb)
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
    update app.content_event_revisions r set saved_by_member = v_nil where r.saved_by_member = v_member;
    update app.content_event_revisions r set published_by_member = v_nil
     where r.published_by_member = v_member;
    if v_account is not null then
      update app.content_event_revisions r set saved_by_account = v_nil
       where r.saved_by_account = v_account;
      update app.content_event_revisions r set published_by_account = v_nil
       where r.published_by_account = v_account;
    end if;
  end if;
  return (select count(*) from app.content_event_revisions r
           where r.saved_by_member = v_member or r.published_by_member = v_member
              or r.saved_by_account = v_account or r.published_by_account = v_account)::integer;
end;
$$;

select app.content_register_erase_part('event_revisions',
  'app.content_event_erase_part(jsonb)'::regprocedure);

-- Content's one deletion hook: erase anonymises lifecycle and audit attribution (nil UUID), then
-- every registered erase part runs with the same input; check only counts. Fail closed: a
-- registered part that is missing or answers anything but a count raises.
create function app.content_erase_member(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_input ->> 'member_id')::uuid;
  v_account uuid := nullif(p_input ->> 'account_id', '')::uuid;
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
  v_left integer;
  v_part record;
  v_proc regprocedure;
  v_n integer;
begin
  if p_input ->> 'phase' = 'erase' then
    update app.content_items i set created_by_member = v_nil where i.created_by_member = v_member;
    update app.content_items i set published_by_member = v_nil where i.published_by_member = v_member;
    update app.content_audit a set actor_member_id = v_nil where a.actor_member_id = v_member;
    if v_account is not null then
      update app.content_items i set created_by_account = v_nil where i.created_by_account = v_account;
      update app.content_items i set published_by_account = v_nil
       where i.published_by_account = v_account;
      update app.content_audit a set actor_account_id = v_nil where a.actor_account_id = v_account;
    end if;
  end if;
  v_left := app.content_lifecycle_remaining(v_member, v_account);
  for v_part in select p.part, p.handler from app.content_erase_parts p order by p.part loop
    v_proc := pg_catalog.to_regprocedure(v_part.handler);
    if v_proc is null then
      raise exception using errcode = 'PCTR1',
        message = format('registered content erase part %s is missing', v_part.handler);
    end if;
    execute format('select %s($1)', v_proc::regproc) into v_n using p_input;
    if v_n is null or v_n < 0 then
      raise exception using errcode = 'PCTR1',
        message = format('content erase part %s answered an unexpected count', v_part.handler);
    end if;
    v_left := v_left + v_n;
  end loop;
  return jsonb_build_object('remaining', v_left);
end;
$$;

comment on function app.content_erase_member(jsonb) is
  'Content deletion hook (story 6.1): anonymise editor attribution and run every erase part.';

select app.identity_register_deletion_hook('content', 'app.content_erase_member(jsonb)'::regprocedure);

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.content_state_ok(text, text),
  app.content_event_revision_guard(),
  app.content_register_command(text, text, regprocedure, boolean),
  app.content_register_erase_part(text, regprocedure),
  app.content_editor_capacity(uuid, text),
  app.content_command_actor(uuid, text),
  app.content_editor_name(uuid),
  app.content_free_text(jsonb, integer, boolean),
  app.content_instant(jsonb),
  app.content_audit_event(text, uuid, uuid, text, text, uuid, text, integer, bigint),
  app.content_item_open(text, uuid, uuid, text, text),
  app.content_item_lock(uuid, text, bigint, text),
  app.content_item_draft_no(app.content_items),
  app.content_item_saved(app.content_items, integer, uuid, uuid, text, text),
  app.content_item_publish(app.content_items, uuid, uuid, text, text, text),
  app.content_item_withdraw(app.content_items, uuid, uuid, text, text, text),
  app.content_item_archive(app.content_items, uuid, uuid, text, text),
  app.content_item_outcome(uuid, text),
  app.content_event_fields(jsonb),
  app.content_event_id(jsonb),
  app.content_event_create(uuid, bigint, jsonb),
  app.content_event_save(uuid, bigint, jsonb),
  app.content_event_publish(uuid, bigint, jsonb),
  app.content_event_withdraw(uuid, bigint, jsonb),
  app.content_event_archive(uuid, bigint, jsonb),
  app.content_authorize_command(jsonb),
  app.content_in_scope(uuid, text, uuid),
  app.content_command(jsonb),
  api.content_command(jsonb),
  app.content_public_event_json(uuid),
  app.content_public_events(),
  app.content_public_event(uuid),
  api.content_public_events(),
  api.content_public_event(uuid),
  app.content_event_revision_json(uuid, integer),
  app.content_staff_event_json(uuid),
  app.content_staff_events(),
  api.content_staff_events(),
  app.content_lifecycle_remaining(uuid, uuid),
  app.content_event_erase_part(jsonb),
  app.content_erase_member(jsonb)
  from public, anon, authenticated, service_role;

grant execute on function app.content_command(jsonb) to authenticated;
grant execute on function api.content_command(jsonb) to authenticated;
grant execute on function app.content_public_events() to anon, authenticated;
grant execute on function api.content_public_events() to anon, authenticated;
grant execute on function app.content_public_event(uuid) to anon, authenticated;
grant execute on function api.content_public_event(uuid) to anon, authenticated;
grant execute on function app.content_staff_events() to authenticated;
grant execute on function api.content_staff_events() to authenticated;

notify pgrst, 'reload schema';
