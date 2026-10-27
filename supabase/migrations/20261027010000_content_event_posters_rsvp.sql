-- Show event posters, export events to the phone calendar and RSVP within capacity (story 6.11;
-- AD-1, AD-2, AD-4, AD-13, AD-14, AD-17).
--
-- Extends the events kind of story 6.1. Its own event functions are replaced in place (same
-- signatures and privileges); 6.2's asset path and the Content registries are reused by rows:
--
--   * Posters: upload purpose `event_poster` (display), file slot `poster` on an event revision,
--     the alt text on the revision, and a rights record that must clear display when the
--     revision goes live. Events register a public condition: a poster stays in the public
--     bucket while its event has not ended. The public projection names the poster only once
--     its object is present in content-public.
--   * RSVP: optional on an event revision (rsvp_enabled, optional rsvp_capacity). One row per
--     event and member (app.content_event_rsvps), going, cancelled or released; no command ever
--     deletes one. content.rsvp_event and content.cancel_rsvp are member commands: any approved
--     member with live access may send them (registry app.content_member_commands). The capacity
--     is checked under the event's item row lock, so concurrent RSVPs can never exceed it. An
--     RSVP never changes the event's revision (editors' optimistic concurrency is untouched).
--   * Organisers (owner decision 2026-10-21: an event's organisers and Admin see the names of
--     members who RSVP; everyone else sees only the count and the spaces left): per event, up to
--     10 members who hold an event editor role. The creator is the first organiser; only an Admin
--     or a current organiser changes the list (content.set_event_organisers). Names are read
--     through api.content_staff_event_rsvps only; every other projection carries counts.
--   * The Content authorizer and replay recheck are replaced once, registry-driven: a registered
--     member command needs only live member access (its handler checks the rest) and key-share
--     locks the actor's member row first; every other command keeps the 6.1 rule. A replayed
--     RSVP is in scope only for the member it belongs to.
--   * A Content lifecycle hook: membership_deactivated and deletion_requested release the
--     member's going RSVPs of events that have not started and remove them as an organiser;
--     scope_revoked removes them as an organiser once they hold no event editor role. A login
--     hold changes nothing (the RSVP is kept).
--   * An erase part (event_rsvps): RSVP and organiser rows of the member are deleted by
--     app.content_rsvp_purge_rows, a fail-closed stub here whose body is the _rows migration the
--     owner applies by hand on hosted projects; organiser attribution becomes the nil UUID.
--
-- Lock order (AD-2): the actor's member row FOR KEY SHARE (member commands) or the actor's role
-- grants FOR SHARE (editor commands) -> command receipt -> the event's item row FOR UPDATE -> RSVP,
-- organiser and revision rows. Identity's lifecycle transaction locks the member row FOR UPDATE
-- before the hooks run, so a member command and a deactivation of the same member serialise.
--
-- No destructive statements and no row deletions (see the _rows file). ASCII only, no backslashes.

-- ---------------------------------------------------------------------------------------------
-- Event revisions: poster alt text and RSVP settings
-- ---------------------------------------------------------------------------------------------

alter table app.content_event_revisions
  add column poster_alt_text text
    check (poster_alt_text is null
           or (length(poster_alt_text) between 1 and 250 and poster_alt_text ~ '[^[:space:]]')),
  add column rsvp_enabled boolean not null default false,
  add column rsvp_capacity integer check (rsvp_capacity between 1 and 10000),
  add constraint content_event_revisions_rsvp_capacity check (rsvp_enabled or rsvp_capacity is null);

comment on column app.content_event_revisions.poster_alt_text is
  'Story 6.11: the text alternative of the revision''s poster (file slot poster).';
comment on column app.content_event_revisions.rsvp_enabled is
  'Story 6.11: whether approved members may RSVP to this revision of the event.';
comment on column app.content_event_revisions.rsvp_capacity is
  'Story 6.11: the number of places when RSVP is on; null means no limit.';

-- (Replaced; copied from 20261021233523_content_events_tracer.sql.) The 6.11 columns are content
-- too: a published revision never changes them.
create or replace function app.content_event_revision_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.published_at is not null
     and (new.item_id, new.revision_no, new.title, new.description, new.starts_at, new.ends_at,
          new.location, new.poster_alt_text, new.rsvp_enabled, new.rsvp_capacity, new.published_at)
         is distinct from
         (old.item_id, old.revision_no, old.title, old.description, old.starts_at, old.ends_at,
          old.location, old.poster_alt_text, old.rsvp_enabled, old.rsvp_capacity, old.published_at) then
    raise exception using errcode = 'PCNT1', message = 'a published content revision is immutable';
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- The poster: an upload purpose and the events' public condition
-- ---------------------------------------------------------------------------------------------

insert into app.content_asset_purposes (purpose, kind, rights_use, media_types, max_bytes,
                                        min_width, min_height, max_width, max_height, min_ratio,
                                        max_ratio, description) values
  ('event_poster', 'event', 'display', array['image/png', 'image/jpeg', 'image/webp'], 5242880,
   540, 540, 6000, 6000, 0.50, 2.40,
   'An event poster: a 16:9 thumbnail in the Calendar and in full on the detail (story 6.11)');

-- The event kind's public condition: a published event (and so its poster in the public bucket)
-- is public while its live revision has not ended.
create function app.content_event_public_condition(p_input jsonb)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select r.ends_at > now()
      from app.content_items i
      join app.content_event_revisions r
        on r.item_id = i.item_id and r.revision_no = i.live_revision_no
     where i.item_id = (p_input ->> 'item_id')::uuid and i.kind = 'event'), false);
$$;

select app.content_register_public_condition('event',
  'app.content_event_public_condition(jsonb)'::regprocedure);

-- ---------------------------------------------------------------------------------------------
-- Tables: organisers, RSVPs and the member-command registry
-- ---------------------------------------------------------------------------------------------

-- An event's organisers: members holding an event editor role who, with every Admin, read the
-- names of the members going. Removal is a state change; rows go only in a member deletion.
create table app.content_event_organisers (
  item_id uuid not null references app.content_items (item_id),
  member_id uuid not null,
  organiser_state text not null default 'active' check (organiser_state in ('active', 'removed')),
  created_at timestamptz not null default now(),
  changed_at timestamptz not null default now(),
  changed_by_member uuid,
  changed_by_account uuid,
  primary key (item_id, member_id),
  check ((changed_by_member is null) = (changed_by_account is null))
);

create index content_event_organisers_member on app.content_event_organisers (member_id);
create index content_event_organisers_changed_by on app.content_event_organisers (changed_by_member);

comment on table app.content_event_organisers is
  'owner: content. Event organisers (story 6.11): they and Admins read RSVP names. changed_by is '
  'null for a system change (backfill, lifecycle).';

-- One member's answer to one event: going, cancelled (by the member) or released (the member's
-- church membership ended before the event). Cancel and release free the place; no command
-- deletes a row.
create table app.content_event_rsvps (
  rsvp_id uuid primary key default gen_random_uuid(),
  item_id uuid not null references app.content_items (item_id),
  member_id uuid not null,
  rsvp_state text not null check (rsvp_state in ('going', 'cancelled', 'released')),
  revision bigint not null default 1 check (revision >= 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  going_at timestamptz not null default now(),
  unique (item_id, member_id)
);

create index content_event_rsvps_going on app.content_event_rsvps (item_id) where rsvp_state = 'going';
create index content_event_rsvps_member on app.content_event_rsvps (member_id);

comment on table app.content_event_rsvps is
  'owner: content. Event RSVPs (story 6.11): one row per event and member; cancel and release are '
  'state changes. Personal data: read by the member, and by name only by organisers and Admins.';

-- Content commands any approved member with live access may send (their handlers check the rest).
create table app.content_member_commands (
  command text primary key references app.content_commands (command),
  registered_at timestamptz not null default now()
);

comment on table app.content_member_commands is
  'owner: content. Commands of approved members (story 6.11: RSVP); every other Content command '
  'needs an editor role of its kind.';

alter table app.content_event_organisers enable row level security;
alter table app.content_event_rsvps enable row level security;
alter table app.content_member_commands enable row level security;
revoke all on table app.content_event_organisers, app.content_event_rsvps, app.content_member_commands
  from public, anon, authenticated, service_role;

-- Registers a member command (migration-time only): the command must already be registered.
create function app.content_register_member_command(p_command text)
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

-- The existing events' creators become their first organisers while they still edit events.
insert into app.content_event_organisers (item_id, member_id)
select i.item_id, i.created_by_member
  from app.content_items i
 where i.kind = 'event'
   and i.created_by_member <> '00000000-0000-0000-0000-000000000000'::uuid
   and app.content_editor_capacity(i.created_by_member, 'event') is not null;

-- ---------------------------------------------------------------------------------------------
-- The authorizer and the replay recheck (registry-driven; editor commands unchanged)
-- ---------------------------------------------------------------------------------------------

-- (Replaced; copied from 20261021233523_content_events_tracer.sql.) A registered member command
-- needs a live member session only: the actor's member row is key-share locked first, so a
-- concurrent deactivation of that member waits for the command (its handler reads access again
-- after this lock). Every other command: a registered command, a live member session and one of
-- the command's kind's editor roles, whose grants are share-locked (AD-2: authority rows before
-- the receipt).
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
  return app.content_editor_capacity(r.member_id, v_kind) is not null;
end;
$$;

-- (Replaced; copied from 20261021233523_content_events_tracer.sql.) Replay recheck (AD-2): a
-- content item is in scope while the actor still edits its kind; an RSVP (story 6.11) while the
-- actor still has live member access and the RSVP is theirs.
create or replace function app.content_in_scope(p_actor uuid, p_aggregate_type text, p_aggregate_id uuid)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_kind text;
begin
  if p_aggregate_type is null or p_aggregate_type not in ('content_item', 'content_rsvp')
     or p_aggregate_id is null then
    return false;
  end if;
  select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
   where e.outcome = 'granted';
  if v_member is null then
    return false;
  end if;
  if p_aggregate_type = 'content_rsvp' then
    return exists (select 1 from app.content_event_rsvps v
                    where v.rsvp_id = p_aggregate_id and v.member_id = v_member);
  end if;
  select i.kind into v_kind from app.content_items i where i.item_id = p_aggregate_id for share;
  return v_kind is not null and app.content_editor_capacity(v_member, v_kind) is not null;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------

-- The acting member of a member command: live member access now (read after the authorizer's
-- lock on the member row), else forbidden.
create function app.content_member_actor(p_actor uuid, out member_id uuid, out account_id uuid)
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

-- How many members are going to an event now.
create function app.content_event_going(p_item_id uuid)
returns integer
language sql
stable
set search_path = ''
as $$
  select count(*)::integer from app.content_event_rsvps v
   where v.item_id = p_item_id and v.rsvp_state = 'going';
$$;

-- Does a member read the names of an event's RSVPs: an Admin, or an event editor who is one of
-- the event's active organisers.
create function app.content_event_sees_names(p_member_id uuid, p_item_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_member_id is not null
     and (app.identity_member_has_role(p_member_id, 'admin')
          or (app.content_editor_capacity(p_member_id, 'event') is not null
              and exists (select 1 from app.content_event_organisers o
                           where o.item_id = p_item_id and o.member_id = p_member_id
                             and o.organiser_state = 'active')));
$$;

-- The 6.11 fields of an event payload with their field errors: rsvp_enabled (a boolean; missing
-- or null is false) and rsvp_capacity (1-10000, only with RSVP on); with p_poster, the poster:
-- poster_asset_id (an event_poster upload of this event), poster_rights_id (a rights record that
-- is not archived) and poster_alt_text (250), all three or none.
create function app.content_event_extras(
  p_payload jsonb,
  p_item_id uuid,
  p_poster boolean,
  out errors jsonb,
  out rsvp_enabled boolean,
  out rsvp_capacity integer,
  out poster_asset_id uuid,
  out poster_rights_id uuid,
  out poster_alt_text text
)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_error text;
  v_capacity bigint;
begin
  errors := '{}'::jsonb;
  rsvp_enabled := false;
  if coalesce(jsonb_typeof(p_payload -> 'rsvp_enabled'), 'null') <> 'null' then
    if jsonb_typeof(p_payload -> 'rsvp_enabled') <> 'boolean' then
      errors := errors || '{"rsvp_enabled": "invalid"}';
    else
      rsvp_enabled := (p_payload -> 'rsvp_enabled')::boolean;
    end if;
  end if;
  select t.error, t.value into v_error, v_capacity
    from app.content_payload_int(p_payload, 'rsvp_capacity') t;
  if v_error is null and v_capacity is not null then
    if not rsvp_enabled then
      v_error := 'must_be_null';
    elsif v_capacity < 1 or v_capacity > 10000 then
      v_error := 'out_of_range';
    end if;
  end if;
  if v_error is not null then
    errors := errors || jsonb_build_object('rsvp_capacity', v_error);
  else
    rsvp_capacity := v_capacity::integer;
  end if;
  if not p_poster then
    return;
  end if;
  select t.error, t.value into v_error, poster_asset_id
    from app.content_payload_optional_uuid(p_payload, 'poster_asset_id') t;
  if v_error is not null then
    errors := errors || jsonb_build_object('poster_asset_id', v_error);
  end if;
  select t.error, t.value into v_error, poster_rights_id
    from app.content_payload_optional_uuid(p_payload, 'poster_rights_id') t;
  if v_error is not null then
    errors := errors || jsonb_build_object('poster_rights_id', v_error);
  end if;
  select t.error, t.value into v_error, poster_alt_text
    from app.content_free_text(p_payload -> 'poster_alt_text', 250, false) t;
  if v_error is not null then
    errors := errors || jsonb_build_object('poster_alt_text', v_error);
  end if;
  if errors ?| array['poster_asset_id', 'poster_rights_id', 'poster_alt_text'] then
    return;
  end if;
  if poster_asset_id is null then
    if poster_rights_id is not null or poster_alt_text is not null then
      errors := errors || '{"poster_asset_id": "required"}';
    end if;
    return;
  end if;
  v_error := app.content_asset_error(poster_asset_id, p_item_id, 'event_poster');
  if v_error is not null then
    errors := errors || jsonb_build_object('poster_asset_id', v_error);
  end if;
  if poster_rights_id is null then
    errors := errors || '{"poster_rights_id": "required"}';
  else
    v_error := app.content_rights_ref_error(poster_rights_id);
    if v_error is not null then
      errors := errors || jsonb_build_object('poster_rights_id', v_error);
    end if;
  end if;
  if poster_alt_text is null then
    errors := errors || '{"poster_alt_text": "required"}';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Event commands (replaced; same signatures)
-- ---------------------------------------------------------------------------------------------

-- (Replaced; copied from 20261021233523_content_events_tracer.sql.) content.create_event
-- {title, description, starts_at, ends_at, location, rsvp_enabled?, rsvp_capacity?}; expected
-- null. A new private draft; the creator becomes the event's first organiser. A poster needs the
-- event to exist first (an upload is attached to an item), so it comes with a save.
create or replace function app.content_event_create(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_fields record;
  v_extras record;
  v_errors jsonb;
  v_item uuid;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'event') a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['title', 'description', 'starts_at', 'ends_at', 'location', 'rsvp_enabled',
                      'rsvp_capacity']);
  select f.* into v_fields from app.content_event_fields(p_payload) f;
  select x.* into v_extras from app.content_event_extras(p_payload, null, false) x;
  v_errors := v_errors || v_fields.errors || v_extras.errors;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_open('event', v_actor.member_id, v_actor.account_id, v_actor.capacity,
                                  'content.create_event');
  insert into app.content_event_revisions (item_id, revision_no, title, description, starts_at,
                                           ends_at, location, rsvp_enabled, rsvp_capacity,
                                           saved_by_member, saved_by_account)
  values (v_item, 1, v_fields.title, v_fields.description, v_fields.starts_at, v_fields.ends_at,
          v_fields.location, v_extras.rsvp_enabled, v_extras.rsvp_capacity, v_actor.member_id,
          v_actor.account_id);
  insert into app.content_event_organisers (item_id, member_id, changed_by_member, changed_by_account)
  values (v_item, v_actor.member_id, v_actor.member_id, v_actor.account_id);
  return app.content_item_outcome(v_item, 'event_id');
end;
$$;

-- (Replaced; copied from 20261021233523_content_events_tracer.sql.) content.save_event {event_id,
-- title, description, starts_at, ends_at, location, rsvp_enabled?, rsvp_capacity?,
-- poster_asset_id?, poster_rights_id?, poster_alt_text?}; expected = the event's revision.
-- Absolute state: missing RSVP keys turn RSVP off, missing poster keys leave the draft without a
-- poster (a null file slot, never a row deletion). The live revision stays public until a
-- publish replaces it.
create or replace function app.content_event_save(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_fields record;
  v_extras record;
  v_errors jsonb;
  v_error text;
  v_id uuid;
  v_item app.content_items;
  v_no integer;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'event') a;
  v_errors := app.contract_unknown_keys(p_payload,
                array['event_id', 'title', 'description', 'starts_at', 'ends_at', 'location',
                      'rsvp_enabled', 'rsvp_capacity', 'poster_asset_id', 'poster_rights_id',
                      'poster_alt_text']);
  select t.error, t.value into v_error, v_id from app.content_event_id(p_payload) t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('event_id', v_error);
  end if;
  select f.* into v_fields from app.content_event_fields(p_payload) f;
  select x.* into v_extras from app.content_event_extras(p_payload, v_id, true) x;
  v_errors := v_errors || v_fields.errors || v_extras.errors;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_lock(v_id, 'event', p_expected_revision, 'event_id');
  -- The upload row is locked and checked again under the lock, so a retention cleanup claim
  -- cannot slip in between the check and the attachment (lock order: item, then asset).
  if v_extras.poster_asset_id is not null then
    perform 1 from app.content_assets a where a.asset_id = v_extras.poster_asset_id for update;
    v_error := app.content_asset_error(v_extras.poster_asset_id, v_id, 'event_poster');
    if v_error is not null then
      perform app.cmd_fail('validation_failed', jsonb_build_object('poster_asset_id', v_error));
    end if;
  end if;
  v_no := app.content_item_draft_no(v_item);
  insert into app.content_event_revisions as r (item_id, revision_no, title, description, starts_at,
                                                ends_at, location, poster_alt_text, rsvp_enabled,
                                                rsvp_capacity, saved_by_member, saved_by_account)
  values (v_id, v_no, v_fields.title, v_fields.description, v_fields.starts_at, v_fields.ends_at,
          v_fields.location, v_extras.poster_alt_text, v_extras.rsvp_enabled,
          v_extras.rsvp_capacity, v_actor.member_id, v_actor.account_id)
  on conflict (item_id, revision_no) do update
     set title = excluded.title,
         description = excluded.description,
         starts_at = excluded.starts_at,
         ends_at = excluded.ends_at,
         location = excluded.location,
         poster_alt_text = excluded.poster_alt_text,
         rsvp_enabled = excluded.rsvp_enabled,
         rsvp_capacity = excluded.rsvp_capacity,
         saved_by_member = excluded.saved_by_member,
         saved_by_account = excluded.saved_by_account,
         saved_at = now()
   where r.published_at is null;
  perform app.content_item_saved(v_item, v_no, v_actor.member_id, v_actor.account_id,
                                 v_actor.capacity, 'content.save_event');
  perform app.content_file_attach(v_id, v_no, 'poster', 'event_poster', v_extras.poster_asset_id,
                                  v_extras.poster_rights_id);
  return app.content_item_outcome(v_id, 'event_id');
end;
$$;

-- (Replaced; copied from 20261021233523_content_events_tracer.sql.) content.publish_event
-- {event_id}; expected = the event's revision. The revision going live (the open draft, or a
-- withdrawn event's live revision) needs, when it has a poster, a ready upload and a rights
-- record that clears display now (in force, Q5 for third-party material).
create or replace function app.content_event_publish(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  v_file app.content_revision_files;
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
  v_no := coalesce(v_item.draft_revision_no,
                   case when v_item.lifecycle_state = 'withdrawn' then v_item.live_revision_no end);
  if v_no is not null then
    select f.* into v_file from app.content_revision_files f
     where f.item_id = v_id and f.revision_no = v_no and f.slot = 'poster';
    if v_file.asset_id is not null then
      if not exists (select 1 from app.content_assets a
                      where a.asset_id = v_file.asset_id and a.state = 'ready'
                        and a.retention_claim_id is null) then
        v_errors := v_errors || '{"poster_asset_id": "not_ready"}';
      end if;
      v_error := app.content_rights_clear(v_file.rights_id, 'display');
      if v_error is not null then
        v_errors := v_errors || jsonb_build_object('poster_rights_id', v_error);
      end if;
      if v_errors <> '{}'::jsonb then
        perform app.cmd_fail('validation_failed', v_errors);
      end if;
    end if;
  end if;
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

-- content.set_event_organisers {event_id, organiser_ids}; expected = the event's revision. An
-- Admin, or an event editor who is an active organiser of the event, sets the whole list (0-10
-- distinct members who hold an event editor role now). Members left out become removed; the
-- event's revision moves on. An unchanged list changes nothing.
create function app.content_event_set_organisers(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  v_raw jsonb;
  v_ids uuid[];
  v_count integer;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'event') a;
  v_errors := app.contract_unknown_keys(p_payload, array['event_id', 'organiser_ids']);
  select t.error, t.value into v_error, v_id from app.content_event_id(p_payload) t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('event_id', v_error);
  end if;
  v_raw := p_payload -> 'organiser_ids';
  if coalesce(jsonb_typeof(v_raw), 'null') = 'null' then
    v_errors := v_errors || '{"organiser_ids": "required"}';
  elsif jsonb_typeof(v_raw) <> 'array'
        or exists (select 1 from jsonb_array_elements(v_raw) e
                    where app.contract_uuid_error(e.value) is not null) then
    v_errors := v_errors || '{"organiser_ids": "invalid"}';
  else
    select coalesce(array_agg(distinct (e.value #>> '{}')::uuid), array[]::uuid[]), count(*)::integer
      into v_ids, v_count
      from jsonb_array_elements(v_raw) e;
    if cardinality(v_ids) <> v_count then
      v_errors := v_errors || '{"organiser_ids": "invalid"}';
    elsif v_count > 10 then
      v_errors := v_errors || '{"organiser_ids": "too_many"}';
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  -- The named members' event-editor grants are share-locked before they are checked (Identity
  -- rows before Content rows, AD-2): a revocation running now either waits for this command (and
  -- its scope_revoked hook then ends the new organiser row) or is seen by the check.
  perform 1
     from app.identity_grants g
     join app.content_kinds k on k.kind = 'event'
    where g.member_id = any (v_ids) and g.revoked_at is null and g.role = any (k.editor_roles)
      for share of g;
  if exists (select 1 from unnest(v_ids) u (id)
              where app.content_editor_capacity(u.id, 'event') is null) then
    perform app.cmd_fail('validation_failed', '{"organiser_ids": "not_editor"}');
  end if;
  v_item := app.content_item_lock(v_id, 'event', p_expected_revision, 'event_id');
  if not app.content_event_sees_names(v_actor.member_id, v_id) then
    perform app.cmd_fail('forbidden');
  end if;
  if (select coalesce(array_agg(o.member_id order by o.member_id), array[]::uuid[])
        from app.content_event_organisers o
       where o.item_id = v_id and o.organiser_state = 'active')
     = (select coalesce(array_agg(u.id order by u.id), array[]::uuid[]) from unnest(v_ids) u (id)) then
    return app.content_item_outcome(v_id, 'event_id');
  end if;
  update app.content_event_organisers o
     set organiser_state = 'removed',
         changed_at = now(),
         changed_by_member = v_actor.member_id,
         changed_by_account = v_actor.account_id
   where o.item_id = v_id and o.organiser_state = 'active' and not (o.member_id = any (v_ids));
  insert into app.content_event_organisers as o (item_id, member_id, changed_by_member,
                                                 changed_by_account)
  select v_id, u.id, v_actor.member_id, v_actor.account_id from unnest(v_ids) u (id)
  on conflict (item_id, member_id) do update
     set organiser_state = 'active',
         changed_at = now(),
         changed_by_member = excluded.changed_by_member,
         changed_by_account = excluded.changed_by_account
   where o.organiser_state <> 'active';
  update app.content_items i
     set revision = i.revision + 1,
         updated_at = now()
   where i.item_id = v_id;
  return app.content_item_outcome(v_id, 'event_id');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- RSVP commands (member commands)
-- ---------------------------------------------------------------------------------------------

-- An RSVP command's outcome: ids, state and counts only (receipts keep it; no names). The
-- receipt's aggregate is the RSVP, so a replay is in scope only for its member.
create function app.content_event_rsvp_outcome(p_rsvp_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'content_rsvp',
    'aggregate_id', v.rsvp_id,
    'revision', v.revision,
    'data', jsonb_build_object(
      'rsvp_id', v.rsvp_id,
      'event_id', v.item_id,
      'rsvp_state', v.rsvp_state,
      'going', g.n,
      'capacity', r.rsvp_capacity,
      'spaces_left', case when r.rsvp_capacity is null then null
                          else greatest(r.rsvp_capacity - g.n, 0) end,
      'full', r.rsvp_capacity is not null and g.n >= r.rsvp_capacity))
    from app.content_event_rsvps v
    join app.content_items i on i.item_id = v.item_id
    left join app.content_event_revisions r
      on r.item_id = i.item_id and r.revision_no = i.live_revision_no
   cross join lateral (select app.content_event_going(v.item_id) as n) g
   where v.rsvp_id = p_rsvp_id;
$$;

-- content.rsvp_event {event_id}; expected null. An approved member with live access says they are
-- going to a public event with RSVP on that has not started. The event's item row is locked, so
-- RSVPs to one event run one at a time and the count read here is final: going never exceeds
-- the capacity. Already going: nothing changes. Refusals (field event_id): not_public (not a
-- published event that has not ended), rsvp_off, rsvp_closed (started), full.
create function app.content_event_rsvp_going(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_id uuid;
  v_item app.content_items;
  v_rev app.content_event_revisions;
  v_rsvp app.content_event_rsvps;
begin
  select a.* into v_actor from app.content_member_actor(p_actor) a;
  v_id := app.content_lifecycle_id(p_payload, 'event_id');
  select i.* into v_item from app.content_items i where i.item_id = v_id and i.kind = 'event' for update;
  if not found or v_item.lifecycle_state <> 'published' then
    perform app.cmd_fail('validation_failed', '{"event_id": "not_public"}');
  end if;
  select r.* into v_rev from app.content_event_revisions r
   where r.item_id = v_id and r.revision_no = v_item.live_revision_no;
  if v_rev.ends_at <= now() then
    perform app.cmd_fail('validation_failed', '{"event_id": "not_public"}');
  end if;
  if not v_rev.rsvp_enabled then
    perform app.cmd_fail('validation_failed', '{"event_id": "rsvp_off"}');
  end if;
  if v_rev.starts_at <= now() then
    perform app.cmd_fail('validation_failed', '{"event_id": "rsvp_closed"}');
  end if;
  select v.* into v_rsvp from app.content_event_rsvps v
   where v.item_id = v_id and v.member_id = v_actor.member_id for update;
  if v_rsvp.rsvp_state = 'going' then
    return app.content_event_rsvp_outcome(v_rsvp.rsvp_id);
  end if;
  if v_rev.rsvp_capacity is not null and app.content_event_going(v_id) >= v_rev.rsvp_capacity then
    perform app.cmd_fail('validation_failed', '{"event_id": "full"}');
  end if;
  if v_rsvp.rsvp_id is null then
    insert into app.content_event_rsvps (item_id, member_id, rsvp_state)
    values (v_id, v_actor.member_id, 'going')
    returning * into v_rsvp;
  else
    update app.content_event_rsvps v
       set rsvp_state = 'going',
           revision = v.revision + 1,
           updated_at = now(),
           going_at = now()
     where v.rsvp_id = v_rsvp.rsvp_id;
  end if;
  return app.content_event_rsvp_outcome(v_rsvp.rsvp_id);
end;
$$;

-- content.cancel_rsvp {event_id}; expected null. The member's going RSVP becomes cancelled before
-- the event starts and the place is free again (the row is kept). Refusals (field event_id):
-- not_going, rsvp_closed (started).
create function app.content_event_rsvp_cancel(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_id uuid;
  v_item app.content_items;
  v_rsvp app.content_event_rsvps;
  v_starts timestamptz;
begin
  select a.* into v_actor from app.content_member_actor(p_actor) a;
  v_id := app.content_lifecycle_id(p_payload, 'event_id');
  select i.* into v_item from app.content_items i where i.item_id = v_id and i.kind = 'event' for update;
  select v.* into v_rsvp from app.content_event_rsvps v
   where v.item_id = v_id and v.member_id = v_actor.member_id for update;
  if v_rsvp.rsvp_id is null or v_rsvp.rsvp_state <> 'going' then
    perform app.cmd_fail('validation_failed', '{"event_id": "not_going"}');
  end if;
  select r.starts_at into v_starts from app.content_event_revisions r
   where r.item_id = v_id and r.revision_no = v_item.live_revision_no;
  if v_starts is null or v_starts <= now() then
    perform app.cmd_fail('validation_failed', '{"event_id": "rsvp_closed"}');
  end if;
  update app.content_event_rsvps v
     set rsvp_state = 'cancelled',
         revision = v.revision + 1,
         updated_at = now()
   where v.rsvp_id = v_rsvp.rsvp_id;
  return app.content_event_rsvp_outcome(v_rsvp.rsvp_id);
end;
$$;

select app.content_register_command('content.set_event_organisers', 'event',
  'app.content_event_set_organisers(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.rsvp_event', 'event',
  'app.content_event_rsvp_going(uuid, bigint, jsonb)'::regprocedure, true);
select app.content_register_command('content.cancel_rsvp', 'event',
  'app.content_event_rsvp_cancel(uuid, bigint, jsonb)'::regprocedure, true);
select app.content_register_member_command('content.rsvp_event');
select app.content_register_member_command('content.cancel_rsvp');

comment on function api.content_command(jsonb) is
  'Stories 6.1-6.11: the Content publication lifecycle through the 1.4 envelope (registered '
  'commands; editor commands need an editor role of their kind, member commands such as '
  'content.rsvp_event live member access).';

-- ---------------------------------------------------------------------------------------------
-- The public read (anonymous): the poster and the RSVP counts, never names
-- ---------------------------------------------------------------------------------------------

-- A live revision's poster as public projections show it, only once its object is present in
-- the public bucket and its rights clear display now: {path, media_type, width, height,
-- alt_text, offline_allowed}; null otherwise.
create function app.content_event_public_poster(p_item_id uuid, p_revision_no integer,
                                                p_alt_text text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select x.file || jsonb_build_object(
           'alt_text', p_alt_text,
           'offline_allowed', app.content_rights_clear(f.rights_id, 'offline') is null)
    from (select app.content_public_file(p_item_id, 'poster') as file) x
    left join app.content_revision_files f
      on f.item_id = p_item_id and f.revision_no = p_revision_no and f.slot = 'poster'
   where x.file is not null;
$$;

-- A live revision's RSVP as everyone reads it (counts only), or null when RSVP is off.
create function app.content_event_public_rsvp(p_item_id uuid, p_enabled boolean,
                                              p_capacity integer, p_starts_at timestamptz)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select case when p_enabled then
    jsonb_build_object(
      'capacity', p_capacity,
      'going', g.n,
      'spaces_left', case when p_capacity is null then null else greatest(p_capacity - g.n, 0) end,
      'full', p_capacity is not null and g.n >= p_capacity,
      'open', p_starts_at > now())
  end
    from (select app.content_event_going(p_item_id) as n) g;
$$;

-- (Replaced; copied from 20261022123202_content_public_offline_rights.sql.) One published event
-- that has not ended, as anyone may read it, with its poster and RSVP counts (story 6.11). Null
-- for anything else.
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
    'offline_allowed', true,
    'poster', app.content_event_public_poster(i.item_id, r.revision_no, r.poster_alt_text),
    'rsvp', app.content_event_public_rsvp(i.item_id, r.rsvp_enabled, r.rsvp_capacity, r.starts_at))
    from app.content_items i
    join app.content_event_revisions r on r.item_id = i.item_id and r.revision_no = i.live_revision_no
   where i.item_id = p_item_id and i.kind = 'event' and i.lifecycle_state = 'published'
     and r.ends_at > now();
$$;

comment on function app.content_public_event_json(uuid) is
  'Stories 6.1, 6.4, 6.11: the current public event projection (offline eligible), its poster '
  'and RSVP counts; never a draft, an editor, a name or a member id.';

-- ---------------------------------------------------------------------------------------------
-- The member's own RSVP
-- ---------------------------------------------------------------------------------------------

-- The caller's RSVP to an event (live member access, else 401/403): {event_id, rsvp_state,
-- updated_at}; rsvp_state null when the member never answered.
create function app.content_my_event_rsvp(p_event_id uuid)
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
  select jsonb_build_object('event_id', v.item_id, 'rsvp_state', v.rsvp_state,
                            'updated_at', app.cmd_utc(v.updated_at))
    into v_result
    from app.content_event_rsvps v
   where v.item_id = p_event_id and v.member_id = v_member;
  perform app.identity_record_activity(v_link);
  return coalesce(v_result, jsonb_build_object('event_id', p_event_id, 'rsvp_state', null,
                                               'updated_at', null));
end;
$$;

create function api.content_my_event_rsvp(event_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.content_my_event_rsvp($1);
$$;

comment on function api.content_my_event_rsvp(uuid) is
  'Story 6.11: the caller''s own RSVP to an event (approved members with live access).';

-- ---------------------------------------------------------------------------------------------
-- The editors' reads
-- ---------------------------------------------------------------------------------------------

-- (Replaced; copied from 20261021233523_content_events_tracer.sql.) One event revision for
-- editors, with its poster, poster rights, alt text and RSVP settings (story 6.11).
create or replace function app.content_event_revision_json(p_item_id uuid, p_revision_no integer)
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
    'poster', (select jsonb_build_object('asset_id', a.asset_id, 'media_type', a.media_type,
                                         'byte_size', a.byte_size, 'width', a.width,
                                         'height', a.height)
                 from app.content_revision_files f
                 join app.content_assets a on a.asset_id = f.asset_id
                where f.item_id = r.item_id and f.revision_no = r.revision_no and f.slot = 'poster'),
    'poster_rights', (select jsonb_build_object(
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
                       where f.item_id = r.item_id and f.revision_no = r.revision_no
                         and f.slot = 'poster'),
    'poster_alt_text', r.poster_alt_text,
    'rsvp_enabled', r.rsvp_enabled,
    'rsvp_capacity', r.rsvp_capacity,
    'saved_at', app.cmd_utc(r.saved_at),
    'saved_by', app.content_editor_name(r.saved_by_member))
    from app.content_event_revisions r
   where r.item_id = p_item_id and r.revision_no = p_revision_no;
$$;

-- A published event's public poster state: shown (in the public bucket), waiting (the next sync
-- places it), blocked (its upload or rights no longer allow it) or ended (the event is over; the
-- next sync removes it). Null when not published or when the live revision has no poster.
create function app.content_event_poster_state(p_item_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when i.lifecycle_state <> 'published' then null
    when not exists (select 1 from app.content_revision_files f
                      where f.item_id = i.item_id and f.revision_no = i.live_revision_no
                        and f.slot = 'poster' and f.asset_id is not null) then null
    when not app.content_event_public_condition(jsonb_build_object('item_id', i.item_id)) then 'ended'
    when not exists (select 1 from app.content_live_file(i.item_id, 'poster')) then 'blocked'
    when app.content_public_file(i.item_id, 'poster') is null then 'waiting'
    else 'shown'
  end
    from app.content_items i
   where i.item_id = p_item_id;
$$;

-- (Replaced; copied from 20261021233523_content_events_tracer.sql.) One event for editors with
-- its public poster state, the number going and its active organisers (story 6.11). Whether the
-- reader sees names is added per reader by app.content_staff_events.
create or replace function app.content_staff_event_json(p_item_id uuid)
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
    'public_poster', app.content_event_poster_state(i.item_id),
    'rsvp_going', app.content_event_going(i.item_id),
    'organisers', coalesce((
      select jsonb_agg(jsonb_build_object('member_id', o.member_id,
                                          'name', app.content_editor_name(o.member_id))
                       order by app.content_editor_name(o.member_id), o.member_id)
        from app.content_event_organisers o
       where o.item_id = i.item_id and o.organiser_state = 'active'), '[]'::jsonb),
    'live', case when i.live_revision_no is not null
                 then app.content_event_revision_json(i.item_id, i.live_revision_no) end,
    'draft', case when i.draft_revision_no is not null
                  then app.content_event_revision_json(i.item_id, i.draft_revision_no) end)
    from app.content_items i
   where i.item_id = p_item_id;
$$;

-- The members who may be named organisers: everyone holding an event editor role now, by name.
create function app.content_event_organiser_options()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('member_id', x.member_id, 'name', x.name)
                            order by x.name, x.member_id), '[]'::jsonb)
    from (select distinct g.member_id, app.content_editor_name(g.member_id) as name
            from app.identity_grants g
            join app.content_kinds k on k.kind = 'event'
           where g.revoked_at is null and g.role = any (k.editor_roles)
             and app.content_editor_capacity(g.member_id, 'event') is not null) x;
$$;

-- (Replaced; copied from 20261021233523_content_events_tracer.sql.) Every event for the editors
-- of events, each with whether the reader sees its RSVP names (story 6.11), and the members who
-- may be named organisers.
create or replace function app.content_staff_events()
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
           'events', coalesce(jsonb_agg(app.content_staff_event_json(k.item_id)
                                        || jsonb_build_object('sees_names',
                                             app.content_event_sees_names(v_member, k.item_id))
                                        order by k.rn)
                                filter (where k.rn <= 500), '[]'::jsonb),
           'organiser_options', app.content_event_organiser_options(),
           'truncated', count(*) > 500)
    into v_result
    from ranked k;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

-- The names of the members going to an event, earliest first (at most 2000), for an Admin or an
-- event editor who is one of its active organisers; other editors 403 not_granted. Unknown or not
-- an event: {"rsvps": null}.
create function app.content_staff_event_rsvps(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_editor record;
  v_item app.content_items;
  v_capacity integer;
begin
  select e.* into v_editor from app.content_require_editor('event') e;
  select i.* into v_item from app.content_items i where i.item_id = p_event_id and i.kind = 'event';
  if not found then
    return jsonb_build_object('rsvps', null);
  end if;
  if not app.content_event_sees_names(v_editor.member_id, p_event_id) then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  select r.rsvp_capacity into v_capacity from app.content_event_revisions r
   where r.item_id = p_event_id
     and r.revision_no = coalesce(v_item.live_revision_no, v_item.draft_revision_no);
  return jsonb_build_object('rsvps', (
    with going as (
      select v.going_at, app.content_editor_name(v.member_id) as name,
             row_number() over (order by v.going_at, v.rsvp_id) as rn
        from app.content_event_rsvps v
       where v.item_id = p_event_id and v.rsvp_state = 'going')
    select jsonb_build_object(
             'event_id', p_event_id,
             'capacity', v_capacity,
             'going', count(*),
             'attendees', coalesce(jsonb_agg(jsonb_build_object('name', g.name,
                                                                'rsvp_at', app.cmd_utc(g.going_at))
                                             order by g.rn) filter (where g.rn <= 2000), '[]'::jsonb),
             'truncated', count(*) > 2000)
      from going g));
end;
$$;

create function api.content_staff_event_rsvps(event_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.content_staff_event_rsvps($1);
$$;

comment on function api.content_staff_event_rsvps(uuid) is
  'Story 6.11: who is going to an event (names), for Admins and the event''s organisers only.';

-- ---------------------------------------------------------------------------------------------
-- The Content lifecycle hook (story 2.10 contract)
-- ---------------------------------------------------------------------------------------------

-- Runs inside Identity's lifecycle transaction (a raise rolls the whole change back).
-- membership_deactivated and deletion_requested: the member's going RSVPs of events that have
-- not started are released (state change; the place is free) and the member stops being an
-- organiser. scope_revoked: a member who no longer holds an event editor role stops being an
-- organiser. A login hold changes nothing.
create function app.content_on_member_lifecycle(p_event jsonb)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_event ->> 'member_id')::uuid;
begin
  if v_member is null then
    return;
  end if;
  if p_event ->> 'event' in ('membership_deactivated', 'deletion_requested') then
    update app.content_event_rsvps v
       set rsvp_state = 'released',
           revision = v.revision + 1,
           updated_at = now()
      from app.content_items i
      join app.content_event_revisions r
        on r.item_id = i.item_id and r.revision_no = i.live_revision_no
     where v.member_id = v_member and v.rsvp_state = 'going' and i.item_id = v.item_id
       and r.starts_at > now();
  end if;
  if p_event ->> 'event' in ('membership_deactivated', 'deletion_requested')
     or (p_event ->> 'event' = 'scope_revoked'
         and app.content_editor_capacity(v_member, 'event') is null) then
    update app.content_event_organisers o
       set organiser_state = 'removed',
           changed_at = now(),
           changed_by_member = null,
           changed_by_account = null
     where o.member_id = v_member and o.organiser_state = 'active';
  end if;
end;
$$;

comment on function app.content_on_member_lifecycle(jsonb) is
  'Content lifecycle hook (story 6.11): deactivation and deletion release future RSVPs and end '
  'organiser roles; a revoked last event-editor role ends organiser roles.';

select app.contract_register_lifecycle_hook('content', e,
         'app.content_on_member_lifecycle(jsonb)'::regprocedure)
  from unnest(array['membership_deactivated', 'deletion_requested', 'scope_revoked']) e;

-- ---------------------------------------------------------------------------------------------
-- The RSVP erase part (story 2.11 contract) and its fail-closed row stub
-- ---------------------------------------------------------------------------------------------

-- The member's RSVP and organiser rows: replaced by the _rows migration of this story. Returns
-- the number of rows removed.
create function app.content_rsvp_purge_rows(p_member_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
begin
  perform app.cmd_fail('unavailable', '{"deletion": "rows_migration_missing"}');
  return null;
end;
$$;

-- RSVPs and organisers: erase deletes the member's RSVP and organiser rows (the purge) and
-- anonymises who changed organiser lists (nil UUID); check counts what is left.
create function app.content_rsvp_erase_part(p_input jsonb)
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
    perform app.content_rsvp_purge_rows(v_member);
    update app.content_event_organisers o set changed_by_member = v_nil
     where o.changed_by_member = v_member;
    if v_account is not null then
      update app.content_event_organisers o set changed_by_account = v_nil
       where o.changed_by_account = v_account;
    end if;
  end if;
  return ((select count(*) from app.content_event_rsvps v where v.member_id = v_member)
        + (select count(*) from app.content_event_organisers o
            where o.member_id = v_member or o.changed_by_member = v_member
               or o.changed_by_account = v_account))::integer;
end;
$$;

select app.content_register_erase_part('event_rsvps',
  'app.content_rsvp_erase_part(jsonb)'::regprocedure);

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.content_register_member_command(text),
  app.content_event_public_condition(jsonb),
  app.content_member_actor(uuid),
  app.content_event_going(uuid),
  app.content_event_sees_names(uuid, uuid),
  app.content_event_extras(jsonb, uuid, boolean),
  app.content_event_set_organisers(uuid, bigint, jsonb),
  app.content_event_rsvp_outcome(uuid),
  app.content_event_rsvp_going(uuid, bigint, jsonb),
  app.content_event_rsvp_cancel(uuid, bigint, jsonb),
  app.content_event_public_poster(uuid, integer, text),
  app.content_event_public_rsvp(uuid, boolean, integer, timestamptz),
  app.content_my_event_rsvp(uuid),
  api.content_my_event_rsvp(uuid),
  app.content_event_poster_state(uuid),
  app.content_event_organiser_options(),
  app.content_staff_event_rsvps(uuid),
  api.content_staff_event_rsvps(uuid),
  app.content_on_member_lifecycle(jsonb),
  app.content_rsvp_purge_rows(uuid),
  app.content_rsvp_erase_part(jsonb)
  from public, anon, authenticated, service_role;

grant execute on function app.content_my_event_rsvp(uuid) to authenticated;
grant execute on function api.content_my_event_rsvp(uuid) to authenticated;
grant execute on function app.content_staff_event_rsvps(uuid) to authenticated;
grant execute on function api.content_staff_event_rsvps(uuid) to authenticated;

notify pgrst, 'reload schema';
