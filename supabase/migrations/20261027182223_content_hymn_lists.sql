-- Save favourite hymns and set Hymns for this Sunday (story 6.8; AD-1, AD-2, AD-4, AD-13, AD-14).
--
-- The hymn book is built into both apps (story 6.7, owner decision 2026-10-27): the server never
-- stores hymn text, titles or first lines. Favourites and the Sunday list name an item of the
-- book by its id (hymn-N or chorus-N) together with the book's edition, and every write is
-- checked against the edition's two number ranges in app.content_hymn_editions.
--
--   * One Content kind, hymn_book (editors: Admin and Media, plus the worship_leader scope).
--   * Registries, so later kinds add rows instead of replacing shared functions again:
--       - member commands (app.content_member_commands): any approved member with live access may
--         send them; their handlers check the rest. Story 6.11 (RSVP, 20261027140149) created this
--         registry, app.content_register_member_command and app.content_member_actor first; this
--         file keeps them (create if not exists / the same bodies), so it also replays where 6.11
--         is absent;
--       - kind scopes (app.content_kind_scopes): holders of a registered Content scope edit a kind
--         beside its editor roles (here the worship_leader scope on the Sunday-list record);
--       - replay scopes (app.content_replay_scopes): the AD-2 replay recheck of an aggregate that
--         is not a content item.
--     app.content_editor_capacity, app.content_authorize_command and app.content_in_scope are
--     replaced (same signatures and privileges; bodies copied from 20261027140149 (6.11) and
--     extended through those registries; 6.11's RSVP replay branch is kept). Kinds without a
--     registered scope, member command or replay scope behave exactly as before.
--   * Favourites (owner decision K9): content.save_hymn_favourite and content.remove_hymn_favourite
--     are member commands; removal is a state change. Only the member reads them, through
--     api.content_my_hymn_favourites() (live member access, no member parameter).
--   * Hymns for this Sunday (owner decision 2026-10-21: Media and members given a worship-leader
--     scope; Admin also edits): the church's single Sunday-list record
--     (app.content_sunday_hymn_lists) is the target of the Content scope kind worship_leader,
--     which an Admin grants through the 2.3 grant command, and the aggregate (revision) of
--     content.set_sunday_hymns and content.clear_sunday_hymns. Each set or clear is an immutable,
--     attributed revision of one church-time Sunday (Africa/Lusaka). The public read answers this
--     Sunday's list (today on a Sunday, else the coming Sunday); the apps decide when Home shows it.
--   * Deletion: two erase parts of Content's one handler. hymn_favourites deletes the member's
--     favourites through app.content_hymn_favourite_purge_rows, a fail-closed stub here whose body
--     is the _rows migration the owner applies by hand on hosted projects; sunday_hymn_revisions
--     anonymises who saved a list (nil UUID).
--
-- Lock order (AD-2): the actor's member row FOR KEY SHARE (member commands) or the actor's role
-- and kind-scope grants FOR SHARE (editor commands) -> command receipt -> the favourite row or the
-- Sunday-list record FOR UPDATE -> revision and item rows.
--
-- No destructive statements and no row deletions (see the _rows file). ASCII only, no backslashes.

-- ---------------------------------------------------------------------------------------------
-- The built-in book's editions and the hymn_book kind
-- ---------------------------------------------------------------------------------------------

create table app.content_hymn_editions (
  edition text primary key check (edition ~ '^[a-z0-9][a-z0-9.-]{0,63}$'),
  hymn_count integer not null check (hymn_count between 1 and 999),
  chorus_count integer not null check (chorus_count between 0 and 999),
  description text not null check (length(btrim(description)) between 1 and 200),
  registered_at timestamptz not null default now()
);

comment on table app.content_hymn_editions is
  'owner: content. Editions of the hymn book built into the apps (story 6.7) with their two number '
  'ranges (story 6.8). The server stores item numbers only, never hymn text.';

-- packages/client_core/assets/hymn_book/hymn_book.json: hymns 1..199, choruses 1..67.
insert into app.content_hymn_editions (edition, hymn_count, chorus_count, description) values
  ('bicc-tonga-2012', 199, 67,
   'Inyimbo zya Bakristo, the Brethren in Christ Church Tonga hymn book (2012 reprint)');

insert into app.content_kinds (kind, editor_roles, description) values
  ('hymn_book', array['admin', 'media'],
   'The built-in hymn book: Hymns for this Sunday and members'' favourites, by item number (story 6.8)');

-- ---------------------------------------------------------------------------------------------
-- Registries: member commands, kind scopes and replay scopes
-- ---------------------------------------------------------------------------------------------

-- Content commands any approved member with live access may send (their handlers check the rest).
create table if not exists app.content_member_commands (
  command text primary key references app.content_commands (command),
  registered_at timestamptz not null default now()
);

comment on table app.content_member_commands is
  'owner: content. Commands of approved members (story 6.8: hymn favourites); every other Content '
  'command needs an editor role or a registered scope of its kind.';

-- A Content scope (2.3) whose holders also edit a kind, beside its editor roles: one target record
-- per scope kind.
create table app.content_kind_scopes (
  kind text not null references app.content_kinds (kind),
  scope_kind text not null,
  scope_id uuid not null,
  registered_at timestamptz not null default now(),
  primary key (kind, scope_kind)
);

comment on table app.content_kind_scopes is
  'owner: content. Scopes whose holders edit a content kind beside its editor roles (story 6.8: '
  'worship_leader on the Sunday-list record edits hymn_book).';

-- The AD-2 replay recheck of a Content aggregate that is not a content item:
-- (jsonb {actor, aggregate_id}) -> boolean.
create table app.content_replay_scopes (
  aggregate_type text primary key
    check (aggregate_type ~ '^content_[a-z][a-z0-9_]{0,40}$' and aggregate_type <> 'content_item'),
  handler text not null unique,
  registered_at timestamptz not null default now()
);

comment on table app.content_replay_scopes is
  'owner: content. Replay rechecks of Content aggregates other than content items (story 6.8).';

alter table app.content_hymn_editions enable row level security;
alter table app.content_member_commands enable row level security;
alter table app.content_kind_scopes enable row level security;
alter table app.content_replay_scopes enable row level security;
revoke all on table app.content_hymn_editions, app.content_member_commands, app.content_kind_scopes,
                    app.content_replay_scopes
  from public, anon, authenticated, service_role;

-- Registers a member command (migration-time only): the command must already be registered.
create or replace function app.content_register_member_command(p_command text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from app.content_commands c where c.command = p_command) then
    perform app.contract_registration_fail('unknown content command: ' || coalesce(p_command, '<null>'));
  end if;
  insert into app.content_member_commands (command) values (p_command);
end;
$$;

-- Registers a kind scope (migration-time only): a scope kind Content registered with Identity and
-- the one record whose holders edit p_kind.
create function app.content_register_kind_scope(p_kind text, p_scope_kind text, p_scope_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from app.content_kinds k where k.kind = p_kind) then
    perform app.contract_registration_fail('unknown content kind: ' || coalesce(p_kind, '<null>'));
  end if;
  if not exists (select 1 from app.identity_scope_kinds s
                  where s.scope_kind = p_scope_kind and s.module = 'content') then
    perform app.contract_registration_fail('not a Content scope kind: ' || coalesce(p_scope_kind, '<null>'));
  end if;
  if p_scope_id is null then
    perform app.contract_registration_fail('a kind scope names its target record');
  end if;
  insert into app.content_kind_scopes (kind, scope_kind, scope_id) values (p_kind, p_scope_kind, p_scope_id);
end;
$$;

-- Registers a replay scope (migration-time only): a Content app function (jsonb) returns boolean.
create function app.content_register_replay_scope(p_aggregate_type text, p_handler regprocedure)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_aggregate_type is null or p_aggregate_type !~ '^content_[a-z][a-z0-9_]{0,40}$'
     or p_aggregate_type = 'content_item' then
    perform app.contract_registration_fail(
      'a replay scope names a content_<aggregate> type other than content_item');
  end if;
  insert into app.content_replay_scopes (aggregate_type, handler)
  values (p_aggregate_type, app.contract_validate_handler('content', p_handler, 'boolean'::regtype));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- The shared authority functions, registry-driven (replaced once)
-- ---------------------------------------------------------------------------------------------

-- (Replaced; copied from 20261021233523_content_events_tracer.sql.) The capacity in which a member
-- edits a kind: the first of the kind's editor roles the member holds now; else (story 6.8) the
-- first registered kind scope the member holds now, named by its scope kind; else null.
create or replace function app.content_editor_capacity(p_member_id uuid, p_kind text)
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select r.role
       from app.content_kinds k
      cross join lateral unnest(k.editor_roles) with ordinality as r (role, ord)
      where k.kind = p_kind and p_member_id is not null
        and app.identity_member_has_role(p_member_id, r.role)
      order by r.ord
      limit 1),
    (select s.scope_kind
       from app.content_kind_scopes s
      where s.kind = p_kind and p_member_id is not null
        and app.identity_member_has_scope(p_member_id, s.scope_kind, s.scope_id)
      order by s.scope_kind
      limit 1));
$$;

-- (Replaced; copied from 20261021233523_content_events_tracer.sql.) `content.*`: a registered
-- command and a live member session. A registered member command needs nothing more here: the
-- actor's member row is key-share locked, so a concurrent deactivation of that member waits for the
-- command (its handler reads access again after this lock). Every other command needs one of the
-- kind's editor roles or (story 6.8) one of its registered scopes; the actor's grants of both are
-- share-locked, so a concurrent revocation waits for the command (AD-2: authority rows before the
-- receipt).
create or replace function app.content_authorize_command(p_request jsonb)
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
  if exists (select 1 from app.content_member_commands mc where mc.command = p_request ->> 'command') then
    perform 1 from app.identity_members m where m.member_id = r.member_id for key share;
    return true;
  end if;
  perform 1
     from app.identity_grants g
     join app.content_kinds k on k.kind = v_kind
    where g.member_id = r.member_id and g.revoked_at is null and g.role = any (k.editor_roles)
      for share of g;
  perform 1
     from app.identity_grants g
     join app.content_kind_scopes s on s.kind = v_kind
    where g.member_id = r.member_id and g.revoked_at is null
      and g.scope_kind = s.scope_kind and g.scope_id = s.scope_id
      for share of g;
  return app.content_editor_capacity(r.member_id, v_kind) is not null;
end;
$$;

-- (Replaced; copied from 20261027140149_content_event_posters_rsvp.sql.) Replay recheck (AD-2): a
-- content item is in scope while the actor still edits its kind; an RSVP (story 6.11) while the
-- actor has live member access and the RSVP is theirs; any other aggregate (story 6.8) by its
-- registered replay scope, and none without one.
create or replace function app.content_in_scope(p_actor uuid, p_aggregate_type text, p_aggregate_id uuid)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_kind text;
  v_handler text;
  v_proc regprocedure;
  v_ok boolean;
begin
  if p_aggregate_type is null or p_aggregate_id is null then
    return false;
  end if;
  if p_aggregate_type = 'content_rsvp' then
    select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
     where e.outcome = 'granted';
    return v_member is not null
       and exists (select 1 from app.content_event_rsvps v
                    where v.rsvp_id = p_aggregate_id and v.member_id = v_member);
  end if;
  if p_aggregate_type <> 'content_item' then
    select s.handler into v_handler from app.content_replay_scopes s
     where s.aggregate_type = p_aggregate_type;
    if v_handler is null then
      return false;
    end if;
    v_proc := pg_catalog.to_regprocedure(v_handler);
    if v_proc is null then
      raise exception using errcode = 'PCTR1',
        message = format('registered content replay scope %s is missing', v_handler);
    end if;
    execute format('select %s($1)', v_proc::regproc) into v_ok
      using jsonb_build_object('actor', p_actor, 'aggregate_id', p_aggregate_id);
    return v_ok is true;
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

-- The acting member of a member command: live member access now (read after the authorizer's
-- lock on the member row), else forbidden.
create or replace function app.content_member_actor(p_actor uuid, out member_id uuid, out account_id uuid)
language plpgsql
set search_path = ''
as $$
begin
  select e.member_id into member_id from app.identity_evaluate_grant(null, null, null) e
   where e.outcome = 'granted';
  if member_id is null then
    perform app.cmd_fail('forbidden');
  end if;
  account_id := p_actor;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Book items: an edition and hymn-N / chorus-N within its ranges
-- ---------------------------------------------------------------------------------------------

-- An item's id as the apps name it: hymn-12, chorus-3.
create function app.content_hymn_item_id(p_kind text, p_number integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select p_kind || '-' || p_number::text;
$$;

-- An edition field: a registered edition, or its error (required, invalid, unknown_edition).
create function app.content_hymn_edition(p_value jsonb, out error text, out value text)
language plpgsql
stable
set search_path = ''
as $$
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    error := 'required';
  elsif jsonb_typeof(p_value) <> 'string' or (p_value #>> '{}') !~ '^[a-z0-9][a-z0-9.-]{0,63}$' then
    error := 'invalid';
  elsif not exists (select 1 from app.content_hymn_editions e where e.edition = p_value #>> '{}') then
    error := 'unknown_edition';
  else
    value := p_value #>> '{}';
  end if;
end;
$$;

-- An item field of p_edition: its kind and number when it is hymn-N or chorus-N (no leading zero)
-- within the edition's range for that kind, else its error (required, invalid, out_of_range). With
-- no edition (the caller already has an edition error) only the form is checked.
create function app.content_hymn_item(p_edition text, p_value jsonb,
                                      out error text, out item_kind text, out item_number integer)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_match text[];
  v_count integer;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    error := 'required';
    return;
  end if;
  if jsonb_typeof(p_value) <> 'string' then
    error := 'invalid';
    return;
  end if;
  v_match := regexp_match(p_value #>> '{}', '^(hymn|chorus)-([1-9][0-9]{0,2})$');
  if v_match is null then
    error := 'invalid';
    return;
  end if;
  if p_edition is not null then
    select case v_match[1] when 'hymn' then e.hymn_count else e.chorus_count end
      into v_count
      from app.content_hymn_editions e where e.edition = p_edition;
    if v_count is null or v_match[2]::integer > v_count then
      error := 'out_of_range';
      return;
    end if;
  end if;
  item_kind := v_match[1];
  item_number := v_match[2]::integer;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Favourites (member commands; private to the member)
-- ---------------------------------------------------------------------------------------------

create table app.content_hymn_favourites (
  favourite_id uuid primary key default gen_random_uuid(),
  member_id uuid not null,
  edition text not null references app.content_hymn_editions (edition),
  item_kind text not null check (item_kind in ('hymn', 'chorus')),
  item_number integer not null check (item_number between 1 and 999),
  favourite_state text not null check (favourite_state in ('saved', 'removed')),
  revision bigint not null default 1 check (revision >= 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  saved_at timestamptz not null default now(),
  unique (member_id, edition, item_kind, item_number)
);

create index content_hymn_favourites_saved
  on app.content_hymn_favourites (member_id, saved_at desc) where favourite_state = 'saved';

comment on table app.content_hymn_favourites is
  'owner: content. Members'' favourite hymns (story 6.8): item numbers of the built-in book, private '
  'to the member. Removal is a state change; rows go only in a member deletion (_rows file).';

alter table app.content_hymn_favourites enable row level security;
revoke all on table app.content_hymn_favourites from public, anon, authenticated, service_role;

-- The {edition, item} of a favourite command with its field errors.
create function app.content_hymn_favourite_fields(p_payload jsonb, out errors jsonb, out edition text,
                                                  out item_kind text, out item_number integer)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_error text;
begin
  errors := app.contract_unknown_keys(p_payload, array['edition', 'item']);
  select t.error, t.value into v_error, edition from app.content_hymn_edition(p_payload -> 'edition') t;
  if v_error is not null then
    errors := errors || jsonb_build_object('edition', v_error);
  end if;
  select t.error, t.item_kind, t.item_number into v_error, item_kind, item_number
    from app.content_hymn_item(edition, p_payload -> 'item') t;
  if v_error is not null then
    errors := errors || jsonb_build_object('item', v_error);
  end if;
end;
$$;

-- A favourite command's outcome: the item and its state (receipts keep it; no member id).
create function app.content_hymn_favourite_outcome(p_favourite_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'content_hymn_favourite',
    'aggregate_id', f.favourite_id,
    'revision', f.revision,
    'data', jsonb_build_object('edition', f.edition,
                               'item', app.content_hymn_item_id(f.item_kind, f.item_number),
                               'saved', f.favourite_state = 'saved',
                               'revision', f.revision))
    from app.content_hymn_favourites f
   where f.favourite_id = p_favourite_id;
$$;

-- content.save_hymn_favourite {edition, item}; expected null. Saves the item for the acting member;
-- saving a saved item changes nothing.
create function app.content_hymn_favourite_save(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_fields record;
  v_id uuid;
begin
  select a.* into v_actor from app.content_member_actor(p_actor) a;
  select f.* into v_fields from app.content_hymn_favourite_fields(p_payload) f;
  if v_fields.errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_fields.errors);
  end if;
  insert into app.content_hymn_favourites as f (member_id, edition, item_kind, item_number,
                                                favourite_state)
  values (v_actor.member_id, v_fields.edition, v_fields.item_kind, v_fields.item_number, 'saved')
  on conflict (member_id, edition, item_kind, item_number) do update
     set favourite_state = 'saved',
         revision = f.revision + 1,
         updated_at = now(),
         saved_at = now()
   where f.favourite_state <> 'saved'
  returning f.favourite_id into v_id;
  if v_id is null then
    select f.favourite_id into v_id
      from app.content_hymn_favourites f
     where f.member_id = v_actor.member_id and f.edition = v_fields.edition
       and f.item_kind = v_fields.item_kind and f.item_number = v_fields.item_number;
  end if;
  return app.content_hymn_favourite_outcome(v_id);
end;
$$;

-- content.remove_hymn_favourite {edition, item}; expected null. The acting member's favourite
-- becomes removed (the row stays); removing a removed one changes nothing; never saved: not_found.
create function app.content_hymn_favourite_remove(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_fields record;
  v_id uuid;
begin
  select a.* into v_actor from app.content_member_actor(p_actor) a;
  select f.* into v_fields from app.content_hymn_favourite_fields(p_payload) f;
  if v_fields.errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_fields.errors);
  end if;
  select f.favourite_id into v_id
    from app.content_hymn_favourites f
   where f.member_id = v_actor.member_id and f.edition = v_fields.edition
     and f.item_kind = v_fields.item_kind and f.item_number = v_fields.item_number
     for update;
  if v_id is null then
    perform app.cmd_fail('not_found');
  end if;
  update app.content_hymn_favourites f
     set favourite_state = 'removed',
         revision = f.revision + 1,
         updated_at = now()
   where f.favourite_id = v_id and f.favourite_state = 'saved';
  return app.content_hymn_favourite_outcome(v_id);
end;
$$;

select app.content_register_command('content.save_hymn_favourite', 'hymn_book',
  'app.content_hymn_favourite_save(uuid, bigint, jsonb)'::regprocedure, true);
select app.content_register_command('content.remove_hymn_favourite', 'hymn_book',
  'app.content_hymn_favourite_remove(uuid, bigint, jsonb)'::regprocedure, true);
select app.content_register_member_command('content.save_hymn_favourite');
select app.content_register_member_command('content.remove_hymn_favourite');

-- Replay recheck: the actor still has live member access and the favourite is theirs.
create function app.content_hymn_favourite_in_scope(p_input jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
begin
  select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
   where e.outcome = 'granted';
  return v_member is not null
     and exists (select 1 from app.content_hymn_favourites f
                  where f.favourite_id = (p_input ->> 'aggregate_id')::uuid
                    and f.member_id = v_member);
end;
$$;

select app.content_register_replay_scope('content_hymn_favourite',
  'app.content_hymn_favourite_in_scope(jsonb)'::regprocedure);

-- The caller's own saved hymns (live member access; no member parameter): newest first, at most
-- 1000 (`truncated` says more exist).
create function app.content_my_hymn_favourites()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_result jsonb;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  with saved as (
    select f.edition, f.item_kind, f.item_number, f.saved_at,
           row_number() over (order by f.saved_at desc, f.favourite_id) as rn
      from app.content_hymn_favourites f
     where f.member_id = v_member and f.favourite_state = 'saved')
  select jsonb_build_object(
           'favourites', coalesce(jsonb_agg(jsonb_build_object(
                                    'edition', s.edition,
                                    'item', app.content_hymn_item_id(s.item_kind, s.item_number),
                                    'saved_at', app.cmd_utc(s.saved_at)) order by s.rn)
                                  filter (where s.rn <= 1000), '[]'::jsonb),
           'truncated', count(*) > 1000)
    into v_result
    from saved s;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

create function api.content_my_hymn_favourites()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.content_my_hymn_favourites();
$$;

comment on function api.content_my_hymn_favourites() is
  'Story 6.8: the signed-in member''s own saved hymns (edition and item id), with live access.';

-- ---------------------------------------------------------------------------------------------
-- Hymns for this Sunday
-- ---------------------------------------------------------------------------------------------

-- The church's single Sunday-list record: the target of the worship_leader scope and the
-- aggregate (revision) of the Sunday-list commands.
create table app.content_sunday_hymn_lists (
  list_id uuid primary key,
  singleton boolean not null default true unique check (singleton),
  revision bigint not null default 1 check (revision >= 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table app.content_sunday_hymn_lists is
  'owner: content. The church''s one Sunday-list record (story 6.8): the worship_leader scope''s '
  'target and the expected_revision of the Sunday-list commands.';

insert into app.content_sunday_hymn_lists (list_id) values ('4f8c2d6e-1b3a-4c5d-8e9f-6a7b0c1d2e08');

-- One Sunday's list as saved: an immutable revision (only who saved it can be anonymised). A
-- cleared list is a revision with no items. The latest revision of a Sunday is its current list.
create table app.content_sunday_hymn_revisions (
  list_id uuid not null references app.content_sunday_hymn_lists (list_id),
  sunday date not null check (extract(isodow from sunday) = 7),
  revision_no integer not null check (revision_no >= 1),
  edition text references app.content_hymn_editions (edition),
  item_count integer not null check (item_count between 0 and 12),
  saved_by_member uuid not null,
  saved_by_account uuid not null,
  saved_capacity text not null check (saved_capacity in ('admin', 'media', 'worship_leader')),
  command_request_id uuid,
  saved_at timestamptz not null default now(),
  primary key (sunday, revision_no),
  check ((item_count = 0) = (edition is null))
);

comment on table app.content_sunday_hymn_revisions is
  'owner: content. Revisions of one church-time Sunday''s hymn list (story 6.8): attributed and '
  'immutable; no hymn text.';

-- The items of a revision, in order: item numbers of the built-in book only.
create table app.content_sunday_hymn_items (
  sunday date not null,
  revision_no integer not null,
  position integer not null check (position between 1 and 12),
  item_kind text not null check (item_kind in ('hymn', 'chorus')),
  item_number integer not null check (item_number between 1 and 999),
  primary key (sunday, revision_no, position),
  unique (sunday, revision_no, item_kind, item_number),
  foreign key (sunday, revision_no) references app.content_sunday_hymn_revisions (sunday, revision_no)
);

comment on table app.content_sunday_hymn_items is
  'owner: content. The ordered item numbers of a Sunday hymn list revision (story 6.8).';

alter table app.content_sunday_hymn_lists enable row level security;
alter table app.content_sunday_hymn_revisions enable row level security;
alter table app.content_sunday_hymn_items enable row level security;
revoke all on table app.content_sunday_hymn_lists, app.content_sunday_hymn_revisions,
                    app.content_sunday_hymn_items
  from public, anon, authenticated, service_role;

-- A saved list never changes; only who saved it can be anonymised.
create function app.content_sunday_hymn_revision_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.list_id, new.sunday, new.revision_no, new.edition, new.item_count, new.saved_capacity,
      new.command_request_id, new.saved_at)
     is distinct from
     (old.list_id, old.sunday, old.revision_no, old.edition, old.item_count, old.saved_capacity,
      old.command_request_id, old.saved_at) then
    raise exception using errcode = 'PCNT1', message = 'a Sunday hymn list revision is immutable';
  end if;
  return new;
end;
$$;

create trigger content_sunday_hymn_revisions_immutable
  before update on app.content_sunday_hymn_revisions
  for each row execute function app.content_sunday_hymn_revision_guard();

create function app.content_sunday_hymn_item_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using errcode = 'PCNT1', message = 'a Sunday hymn list revision is immutable';
  return null;
end;
$$;

create trigger content_sunday_hymn_items_immutable
  before update on app.content_sunday_hymn_items
  for each row execute function app.content_sunday_hymn_item_guard();

-- This Sunday in church time (Africa/Lusaka): today on a Sunday, else the coming Sunday.
create function app.content_this_sunday()
returns date
language sql
stable
set search_path = ''
as $$
  select t.d + (7 - extract(isodow from t.d)::integer)
    from (select (now() at time zone 'Africa/Lusaka')::date as d) t;
$$;

-- A sunday field (YYYY-MM-DD): a Sunday from this Sunday to 52 weeks later, else its error
-- (required, invalid, not_a_sunday, past, too_far).
create function app.content_sunday_field(p_value jsonb, out error text, out value date)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_text text;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    error := 'required';
    return;
  end if;
  v_text := p_value #>> '{}';
  if jsonb_typeof(p_value) <> 'string' or v_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    error := 'invalid';
    return;
  end if;
  begin
    value := v_text::date;
  exception when others then
    value := null;
  end;
  if value is null or to_char(value, 'YYYY-MM-DD') <> v_text then
    error := 'invalid';
  elsif extract(isodow from value) <> 7 then
    error := 'not_a_sunday';
  elsif value < app.content_this_sunday() then
    error := 'past';
  elsif value > app.content_this_sunday() + 364 then
    error := 'too_far';
  end if;
  if error is not null then
    value := null;
  end if;
end;
$$;

-- The items field of a set: 1 to 12 distinct items of p_edition, in order, else its error
-- (required, invalid, too_many, out_of_range, duplicate).
create function app.content_sunday_items_field(p_edition text, p_value jsonb, out error text,
                                               out kinds text[], out numbers integer[])
language plpgsql
stable
set search_path = ''
as $$
declare
  v_item jsonb;
  v_error text;
  v_kind text;
  v_number integer;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    error := 'required';
    return;
  end if;
  if jsonb_typeof(p_value) <> 'array' then
    error := 'invalid';
    return;
  end if;
  if jsonb_array_length(p_value) = 0 then
    error := 'required';
    return;
  end if;
  if jsonb_array_length(p_value) > 12 then
    error := 'too_many';
    return;
  end if;
  kinds := array[]::text[];
  numbers := array[]::integer[];
  for v_item in select e.value from jsonb_array_elements(p_value) e loop
    select t.error, t.item_kind, t.item_number into v_error, v_kind, v_number
      from app.content_hymn_item(p_edition, v_item) t;
    if v_error is null
       and exists (select 1 from unnest(kinds, numbers) u (k, n) where u.k = v_kind and u.n = v_number) then
      v_error := 'duplicate';
    end if;
    if v_error is not null then
      error := v_error;
      kinds := null;
      numbers := null;
      return;
    end if;
    kinds := kinds || v_kind;
    numbers := numbers || v_number;
  end loop;
end;
$$;

-- Locks the Sunday-list record for a command: conflict with the current revision when stale.
create function app.content_sunday_list_lock(p_expected bigint)
returns app.content_sunday_hymn_lists
language plpgsql
set search_path = ''
as $$
declare
  v app.content_sunday_hymn_lists;
begin
  select l.* into v from app.content_sunday_hymn_lists l where l.singleton for update;
  if not found then
    perform app.cmd_fail('unavailable');
  end if;
  if v.revision is distinct from p_expected then
    perform app.cmd_fail('conflict', null, v.revision);
  end if;
  return v;
end;
$$;

-- p_sunday's current list (its latest revision), or a row of nulls.
create function app.content_sunday_hymns_current(p_sunday date)
returns app.content_sunday_hymn_revisions
language sql
stable
set search_path = ''
as $$
  select r.* from app.content_sunday_hymn_revisions r
   where r.sunday = p_sunday
   order by r.revision_no desc
   limit 1;
$$;

-- A revision's item ids in order.
create function app.content_sunday_hymn_items_json(p_sunday date, p_revision_no integer)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(app.content_hymn_item_id(i.item_kind, i.item_number) order by i.position),
                  '[]'::jsonb)
    from app.content_sunday_hymn_items i
   where i.sunday = p_sunday and i.revision_no = p_revision_no;
$$;

-- A Sunday-list command's outcome: the record's revision and the Sunday's current revision number.
create function app.content_sunday_hymns_outcome(p_sunday date)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'content_sunday_hymns',
    'aggregate_id', l.list_id,
    'revision', l.revision,
    'data', jsonb_build_object('list_id', l.list_id, 'revision', l.revision,
                               'sunday', to_char(p_sunday, 'YYYY-MM-DD'),
                               'revision_no', (select max(r.revision_no)
                                                 from app.content_sunday_hymn_revisions r
                                                where r.sunday = p_sunday)))
    from app.content_sunday_hymn_lists l
   where l.singleton;
$$;

-- Writes p_sunday's next revision (no items when cleared) and moves the record's revision on.
create function app.content_sunday_hymns_write(p_list app.content_sunday_hymn_lists, p_sunday date,
                                               p_edition text, p_kinds text[], p_numbers integer[],
                                               p_member uuid, p_account uuid, p_capacity text,
                                               p_command text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_no integer;
begin
  select coalesce(max(r.revision_no), 0) + 1 into v_no
    from app.content_sunday_hymn_revisions r where r.sunday = p_sunday;
  insert into app.content_sunday_hymn_revisions (list_id, sunday, revision_no, edition, item_count,
                                                 saved_by_member, saved_by_account, saved_capacity,
                                                 command_request_id)
  values (p_list.list_id, p_sunday, v_no, p_edition, coalesce(cardinality(p_kinds), 0), p_member,
          p_account, p_capacity, app.cmd_current_request_id(p_account, p_command));
  insert into app.content_sunday_hymn_items (sunday, revision_no, position, item_kind, item_number)
  select p_sunday, v_no, u.ord, u.k, u.n
    from unnest(coalesce(p_kinds, array[]::text[]), coalesce(p_numbers, array[]::integer[]))
         with ordinality as u (k, n, ord);
  update app.content_sunday_hymn_lists l
     set revision = l.revision + 1,
         updated_at = now()
   where l.list_id = p_list.list_id;
end;
$$;

-- content.set_sunday_hymns {sunday, edition, items}; expected = the Sunday-list record's revision.
-- Admin, Media and worship leaders. The same list again changes nothing.
create function app.content_sunday_hymns_set(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_error text;
  v_sunday date;
  v_edition text;
  v_items record;
  v_list app.content_sunday_hymn_lists;
  v_current app.content_sunday_hymn_revisions;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'hymn_book') a;
  v_errors := app.contract_unknown_keys(p_payload, array['sunday', 'edition', 'items']);
  select t.error, t.value into v_error, v_sunday from app.content_sunday_field(p_payload -> 'sunday') t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('sunday', v_error);
  end if;
  select t.error, t.value into v_error, v_edition from app.content_hymn_edition(p_payload -> 'edition') t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('edition', v_error);
  end if;
  select t.* into v_items from app.content_sunday_items_field(v_edition, p_payload -> 'items') t;
  if v_items.error is not null then
    v_errors := v_errors || jsonb_build_object('items', v_items.error);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_list := app.content_sunday_list_lock(p_expected_revision);
  v_current := app.content_sunday_hymns_current(v_sunday);
  if v_current.revision_no is not null and v_current.edition is not distinct from v_edition
     and (select array_agg(i.item_kind order by i.position) from app.content_sunday_hymn_items i
           where i.sunday = v_sunday and i.revision_no = v_current.revision_no) = v_items.kinds
     and (select array_agg(i.item_number order by i.position) from app.content_sunday_hymn_items i
           where i.sunday = v_sunday and i.revision_no = v_current.revision_no) = v_items.numbers then
    return app.content_sunday_hymns_outcome(v_sunday);
  end if;
  perform app.content_sunday_hymns_write(v_list, v_sunday, v_edition, v_items.kinds, v_items.numbers,
                                         v_actor.member_id, v_actor.account_id, v_actor.capacity,
                                         'content.set_sunday_hymns');
  return app.content_sunday_hymns_outcome(v_sunday);
end;
$$;

-- content.clear_sunday_hymns {sunday}; expected = the Sunday-list record's revision. A revision
-- with no items; nothing set (or cleared already): validation_failed {sunday: not_set}.
create function app.content_sunday_hymns_clear(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_error text;
  v_sunday date;
  v_list app.content_sunday_hymn_lists;
  v_current app.content_sunday_hymn_revisions;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'hymn_book') a;
  v_errors := app.contract_unknown_keys(p_payload, array['sunday']);
  select t.error, t.value into v_error, v_sunday from app.content_sunday_field(p_payload -> 'sunday') t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('sunday', v_error);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_list := app.content_sunday_list_lock(p_expected_revision);
  v_current := app.content_sunday_hymns_current(v_sunday);
  if v_current.revision_no is null or v_current.item_count = 0 then
    perform app.cmd_fail('validation_failed', '{"sunday": "not_set"}');
  end if;
  perform app.content_sunday_hymns_write(v_list, v_sunday, null, null, null, v_actor.member_id,
                                         v_actor.account_id, v_actor.capacity,
                                         'content.clear_sunday_hymns');
  return app.content_sunday_hymns_outcome(v_sunday);
end;
$$;

select app.content_register_command('content.set_sunday_hymns', 'hymn_book',
  'app.content_sunday_hymns_set(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.clear_sunday_hymns', 'hymn_book',
  'app.content_sunday_hymns_clear(uuid, bigint, jsonb)'::regprocedure, false);

-- Replay recheck: the actor still edits the hymn_book kind (Admin, Media or a worship leader).
create function app.content_sunday_hymns_in_scope(p_input jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
begin
  select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
   where e.outcome = 'granted';
  return v_member is not null
     and exists (select 1 from app.content_sunday_hymn_lists l
                  where l.list_id = (p_input ->> 'aggregate_id')::uuid)
     and app.content_editor_capacity(v_member, 'hymn_book') is not null;
end;
$$;

select app.content_register_replay_scope('content_sunday_hymns',
  'app.content_sunday_hymns_in_scope(jsonb)'::regprocedure);

-- The Content scope kinds' target check (2.3): worship_leader targets the Sunday-list record.
create function app.content_scope_target_ok(p_scope jsonb)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(p_scope ->> 'scope_kind' = 'worship_leader'
                  and exists (select 1 from app.content_sunday_hymn_lists l
                               where l.list_id::text = p_scope ->> 'scope_id'), false);
$$;

select app.identity_register_scope_kind('content', 'worship_leader',
  'app.content_scope_target_ok(jsonb)'::regprocedure,
  'Worship leader: sets Hymns for this Sunday (the church''s single Sunday-list record)');
select app.content_register_kind_scope('hymn_book', 'worship_leader',
  '4f8c2d6e-1b3a-4c5d-8e9f-6a7b0c1d2e08');

-- This Sunday's list as anyone may read it: the date (church time) and the item ids in order,
-- none when nothing is set or the list was cleared. No editor identity, time or capacity.
create function app.content_public_sunday_hymns()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with s as (select app.content_this_sunday() as sunday)
  select jsonb_build_object(
    'sunday', to_char(s.sunday, 'YYYY-MM-DD'),
    'edition', c.edition,
    'items', case when c.item_count > 0
                  then app.content_sunday_hymn_items_json(c.sunday, c.revision_no)
                  else '[]'::jsonb end,
    'publication_revision', case when c.item_count > 0 then c.revision_no end)
    from s
    left join lateral (select r.* from app.content_sunday_hymn_revisions r
                        where r.sunday = s.sunday
                        order by r.revision_no desc
                        limit 1) c on true;
$$;

create function api.content_public_sunday_hymns()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select app.content_public_sunday_hymns();
$$;

comment on function api.content_public_sunday_hymns() is
  'Story 6.8, public (anon and authenticated): this Sunday''s hymn list (item ids of the built-in book).';

-- One Sunday's current list for its editors: items, whether cleared, and who saved it when.
create function app.content_staff_sunday_json(p_sunday date)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'sunday', to_char(c.sunday, 'YYYY-MM-DD'),
    'revision_no', c.revision_no,
    'edition', c.edition,
    'items', app.content_sunday_hymn_items_json(c.sunday, c.revision_no),
    'saved_at', app.cmd_utc(c.saved_at),
    'saved_by', app.content_editor_name(c.saved_by_member),
    'saved_capacity', c.saved_capacity)
    from (select r.* from app.content_sunday_hymn_revisions r
           where r.sunday = p_sunday
           order by r.revision_no desc
           limit 1) c;
$$;

-- For the Sunday list's editors (Admin, Media, worship leaders): the record and its revision, this
-- Sunday, the editions, and every Sunday from 8 weeks back to 52 weeks ahead that has a list. For
-- an Admin also the current worship leaders and the approved members to choose from (at most 500,
-- with their grant-set revision for the 2.3 grant command); null for everyone else.
create function app.content_staff_sunday_hymns()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_capacity text;
  v_admin boolean;
  v_list app.content_sunday_hymn_lists;
  v_this date;
  v_result jsonb;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  v_capacity := app.content_editor_capacity(v_member, 'hymn_book');
  if v_capacity is null then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  v_admin := app.identity_member_has_role(v_member, 'admin');
  select l.* into v_list from app.content_sunday_hymn_lists l where l.singleton;
  v_this := app.content_this_sunday();
  v_result := jsonb_build_object(
    'capacity', v_capacity,
    'list_id', v_list.list_id,
    'revision', v_list.revision,
    'this_sunday', to_char(v_this, 'YYYY-MM-DD'),
    'editions', (select coalesce(jsonb_agg(jsonb_build_object('edition', e.edition,
                                                              'hymns', e.hymn_count,
                                                              'choruses', e.chorus_count)
                                           order by e.edition), '[]'::jsonb)
                   from app.content_hymn_editions e),
    'sundays', (select coalesce(jsonb_agg(app.content_staff_sunday_json(x.sunday) order by x.sunday),
                                '[]'::jsonb)
                  from (select distinct r.sunday from app.content_sunday_hymn_revisions r
                         where r.sunday between v_this - 56 and v_this + 364) x),
    'worship_leaders', case when v_admin then (
      select coalesce(jsonb_agg(jsonb_build_object('member_id', g.member_id,
                                                   'display_name', m.display_name,
                                                   'grants_revision', gs.revision)
                                order by m.display_name collate "C", g.member_id), '[]'::jsonb)
        from app.identity_grants g
        join app.identity_members m on m.member_id = g.member_id
        join app.identity_grant_sets gs on gs.member_id = g.member_id
       where g.scope_kind = 'worship_leader' and g.scope_id = v_list.list_id
         and g.revoked_at is null) end,
    'members', case when v_admin then (
      select coalesce(jsonb_agg(x.obj order by x.display_name collate "C", x.member_id), '[]'::jsonb)
        from (select im.member_id, im.display_name,
                     jsonb_build_object('member_id', im.member_id, 'display_name', im.display_name,
                                        'account', app.identity_member_account_label(im.member_id),
                                        'grants_revision', gs.revision) as obj
                from app.identity_members im
                join app.identity_grant_sets gs on gs.member_id = im.member_id
               where im.membership_state = 'approved'
                 and not exists (select 1 from app.identity_deletions dl
                                  where dl.member_id = im.member_id)
               order by im.display_name collate "C", im.member_id
               limit 500) x) end,
    'members_truncated', case when v_admin then (
      select count(*) > 500 from app.identity_members im
       where im.membership_state = 'approved'
         and not exists (select 1 from app.identity_deletions dl where dl.member_id = im.member_id))
      end);
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

create function api.content_staff_sunday_hymns()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.content_staff_sunday_hymns();
$$;

comment on function api.content_staff_sunday_hymns() is
  'Story 6.8: the Sunday hymn lists for Admin, Media and worship leaders (Admin also the worship '
  'leaders and members to choose from).';

-- ---------------------------------------------------------------------------------------------
-- Deletion: the favourites and Sunday-list erase parts (story 2.11 contract)
-- ---------------------------------------------------------------------------------------------

-- The member's favourite rows: replaced by this story's _rows file (content_hymn_lists_rows). Returns the
-- number of rows removed.
create function app.content_hymn_favourite_purge_rows(p_member_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
begin
  perform app.cmd_fail('unavailable', '{"deletion": "rows_migration_missing"}');
  return null;
end;
$$;

-- Favourites: erase deletes the member's favourites (the purge); check counts what is left.
create function app.content_hymn_favourite_erase_part(p_input jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_input ->> 'member_id')::uuid;
begin
  if p_input ->> 'phase' = 'erase' then
    perform app.content_hymn_favourite_purge_rows(v_member);
  end if;
  return (select count(*) from app.content_hymn_favourites f where f.member_id = v_member)::integer;
end;
$$;

select app.content_register_erase_part('hymn_favourites',
  'app.content_hymn_favourite_erase_part(jsonb)'::regprocedure);

-- Sunday lists: erase replaces who saved a revision with the nil UUID (the lists stay; editors
-- read the person as Former member); check counts what is left.
create function app.content_sunday_hymns_erase_part(p_input jsonb)
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
    update app.content_sunday_hymn_revisions r set saved_by_member = v_nil
     where r.saved_by_member = v_member;
    if v_account is not null then
      update app.content_sunday_hymn_revisions r set saved_by_account = v_nil
       where r.saved_by_account = v_account;
    end if;
  end if;
  return (select count(*) from app.content_sunday_hymn_revisions r
           where r.saved_by_member = v_member or r.saved_by_account = v_account)::integer;
end;
$$;

select app.content_register_erase_part('sunday_hymn_revisions',
  'app.content_sunday_hymns_erase_part(jsonb)'::regprocedure);

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.content_register_member_command(text),
  app.content_register_kind_scope(text, text, uuid),
  app.content_register_replay_scope(text, regprocedure),
  app.content_editor_capacity(uuid, text),
  app.content_authorize_command(jsonb),
  app.content_in_scope(uuid, text, uuid),
  app.content_member_actor(uuid),
  app.content_hymn_item_id(text, integer),
  app.content_hymn_edition(jsonb),
  app.content_hymn_item(text, jsonb),
  app.content_hymn_favourite_fields(jsonb),
  app.content_hymn_favourite_outcome(uuid),
  app.content_hymn_favourite_save(uuid, bigint, jsonb),
  app.content_hymn_favourite_remove(uuid, bigint, jsonb),
  app.content_hymn_favourite_in_scope(jsonb),
  app.content_my_hymn_favourites(),
  api.content_my_hymn_favourites(),
  app.content_sunday_hymn_revision_guard(),
  app.content_sunday_hymn_item_guard(),
  app.content_this_sunday(),
  app.content_sunday_field(jsonb),
  app.content_sunday_items_field(text, jsonb),
  app.content_sunday_list_lock(bigint),
  app.content_sunday_hymns_current(date),
  app.content_sunday_hymn_items_json(date, integer),
  app.content_sunday_hymns_outcome(date),
  app.content_sunday_hymns_write(app.content_sunday_hymn_lists, date, text, text[], integer[], uuid,
                                 uuid, text, text),
  app.content_sunday_hymns_set(uuid, bigint, jsonb),
  app.content_sunday_hymns_clear(uuid, bigint, jsonb),
  app.content_sunday_hymns_in_scope(jsonb),
  app.content_scope_target_ok(jsonb),
  app.content_public_sunday_hymns(),
  api.content_public_sunday_hymns(),
  app.content_staff_sunday_json(date),
  app.content_staff_sunday_hymns(),
  api.content_staff_sunday_hymns(),
  app.content_hymn_favourite_purge_rows(uuid),
  app.content_hymn_favourite_erase_part(jsonb),
  app.content_sunday_hymns_erase_part(jsonb)
  from public, anon, authenticated, service_role;

grant execute on function app.content_my_hymn_favourites() to authenticated;
grant execute on function api.content_my_hymn_favourites() to authenticated;
grant execute on function app.content_public_sunday_hymns() to anon, authenticated;
grant execute on function api.content_public_sunday_hymns() to anon, authenticated;
grant execute on function app.content_staff_sunday_hymns() to authenticated;
grant execute on function api.content_staff_sunday_hymns() to authenticated;

notify pgrst, 'reload schema';
