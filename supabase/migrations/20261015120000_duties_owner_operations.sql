-- Expose Duties and Follow-ups owner operations for programmes and later owners (story 4.11;
-- AD-1, AD-2, AD-6, AD-7, AD-18). A forward migration on the Duties owner (20261013220239 ..
-- 20261015002121 are not edited). It adds:
--
--   * Link sources (app.duties_link_sources, app.duties_register_link_source): a source owner
--     registers, in its own migration, a source type it owns (1.5 registry) as a `cell_part`
--     (Cells, or a SYNTHETIC fixture_ source) or an `event` (Content, or a SYNTHETIC fixture_
--     source). The module needs a dependency edge to duties. The part and the event travel as
--     contract v1 `source_ref` values; every operation rechecks them through
--     app.contract_check_source at the given revision.
--   * Owner operations, called by a registered owner INSIDE its own command's transaction (never
--     client-executable). The actor is the live session (Identity), never a payload field:
--       app.duties_owner_put_part      create or revise one cell-owned published occurrence for a
--                                      part, with 1-10 positions keyed by a stable position key
--                                      (the 4.2 revision engine; 4.4 overlap gate; 4.8 deadlines)
--       app.duties_owner_cancel_part   cancel it (the 4.3 cancellation) and end its display links
--       app.duties_owner_link_duty     display-link a part position to a department-owned position
--       app.duties_owner_unlink        end a display link
--       app.duties_owner_flag_review   flag an owner-review mismatch on the department duties a
--                                      changed meeting or event is linked to (nothing else changes)
--       app.duties_owner_part          the part's positions (responses, no notes, no reasons;
--                                      display links show no people)
--       app.duties_owner_conflicts     the 4.4 conflict query for a cell's leader or assistant
--       app.duties_owner_event_links   the duties that name an event (ids, states, open review)
--       app.duties_owner_topic         the sermon-draft topic/scripture read
--   * The stable part/position-to-slot link (app.duties_part_links): one active link per
--     (source_type, source_id, position_key); an owned link is permanent and its slot is linked
--     once; a second concurrent link is refused cleanly (`conflict {"position_key": "linked"}`).
--   * Owner-review flags (app.duties_review_flags) and the client command duties.clear_review
--     (the department's leader, deputy or Admin; expected = the flag revision). The board and the
--     rota show open flags (codes only) and how many programme parts link each duty.
--   * Cell parts for their member: My duties lists them, respond / withdraw_acceptance /
--     accept_many answer them, notices and member reminders are sent and checked as for a
--     department duty (eligibility: the assignee, still an active member). Leader alerts, the
--     coverage queue, leader confirmation, contact attempts and outcomes stay department-only
--     (fail closed; the first contract change Cells needs, recorded in the 4.11 plan).
--   * The SYNTHETIC Cells-like caller (module fixture, new edges fixture -> duties and fixture ->
--     followups): a part table and an event table with check hooks, and caller bodies that lock
--     their own row, then call Duties and Follow-ups. Its registrations happen only in tests and
--     the local E2E.
--
-- Authority: the actor must hold cell_leader or cell_assistant for the part's cell now; the Admin
-- role alone, Pastor and department scopes are forbidden. A department duty is never changed by
-- an owner operation (anything not linkable is not_found); a cell-owned occurrence is never
-- managed through api.duties_command (unchanged: not_found).
--
-- Privacy: no response note, override or confirmation reason, contact data or person of another
-- owner crosses (display links carry no people). Audit rows hold codes only.
--
-- Gates: the Q4 personal-data gate on every operation and read; Q2 through the Notifications
-- calls (production stays inert).
--
-- Replaced bodies (each copied from its latest version, keeping every earlier review fix; changes
-- are marked "Story 4.11"):
--   from 20261015002121 (4.10): duties_state_ok, duties_authorize_command, duties_command,
--     duties_my_assignment_json, duties_deletion_remaining, duties_erase_member (S1 lock order).
--   from 20261014212507 (4.9): duties_respond, duties_accept_many (the 4.5 lock order),
--     duties_apply_change, duties_plan_reminders (4.8 memoised policy, reachable leaders, fresh
--     keys, passed-deadline alerts; 4.9 decline alerts kept), duties_occurrence_json (3-argument;
--     B1 reason gating), duties_rota_occurrence_json (2-argument).
--   from 20261014171038 (4.8): duties_withdraw_acceptance.
--   from 20261014052239 (4.4): duties_my_duties.
--   from 20261014001142 (4.2): duties_update_reminder_check.
--   from 20261013220239 (4.1): duties_assignment_reminder_check.
--
-- Lock order (AD-2): the caller's Identity grant rows (its authorizer) -> the caller's own source
-- row -> Duties: department FOR SHARE -> series FOR SHARE -> occurrence -> slots -> member
-- advisory locks -> assignments -> links / flags -> Follow-ups -> Notifications last.
--
-- No destructive statements, no row deletions (no _rows file). No new client grant (the clear
-- command goes through api.duties_command). ASCII only.


-- ---------------------------------------------------------------------------------------------
-- Vocabularies (widened: cell capacities, link kinds and roles, review fields, audit actions)
-- ---------------------------------------------------------------------------------------------

create or replace function app.duties_state_ok(p_kind text, p_value text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_value is not null and case p_kind
    when 'department_state' then p_value in ('active')
    when 'occurrence_state' then p_value in ('draft', 'published', 'cancelled')
    when 'assignment_state' then p_value in ('current', 'superseded', 'cancelled')
    when 'assignment_end_reason' then p_value in ('revised', 'cancelled')
    when 'response' then p_value in ('pending', 'accepted', 'declined')
    -- Story 4.9: `leader` = Confirmed by leader (a phone or in-person confirmation).
    when 'response_provenance' then p_value in ('member', 'leader')
    -- Story 4.11: a cell's leader or assistant acting through an owner operation.
    when 'capacity' then p_value in ('admin', 'department_leader', 'department_deputy', 'member',
                                     'cell_leader', 'cell_assistant')
    when 'change_class' then p_value in ('published', 'material', 'notes', 'reference', 'cancelled')
    when 'slot_field' then p_value in ('duty_name', 'starts_at', 'ends_at', 'reporting_at',
                                       'location', 'member_id', 'instructions', 'topic',
                                       'scripture', 'event_ref', 'position_name')
    when 'deadline_source' then p_value in ('creator', 'default')
    when 'series_every' then p_value in ('day', 'week', 'month')
    -- Story 4.9: how a leader reached (or tried to reach) a member, and what came of it.
    when 'contact_channel' then p_value in ('phone', 'message', 'in_person', 'other')
    when 'contact_outcome' then p_value in ('no_answer', 'left_message', 'will_answer',
                                            'cannot_serve', 'other')
    when 'case_close' then p_value in ('accepted', 'confirmed', 'superseded', 'cancelled',
                                       'replaced', 'started')
    -- Story 4.10: what the leader recorded after the duty.
    when 'completion_outcome' then p_value in ('completed', 'excused', 'no_show')
    -- Story 4.11: owner links and owner-review flags.
    when 'link_kind' then p_value in ('owned', 'linked')
    when 'link_role' then p_value in ('cell_part', 'event')
    when 'review_field' then p_value in ('time', 'place', 'label', 'assignee', 'cancelled')
    when 'audit_action' then p_value in ('department_created', 'member_added', 'duty_published',
                                         'response_recorded', 'duty_revised', 'series_created',
                                         'draft_assigned', 'draft_revised', 'series_revised',
                                         'occurrence_cancelled', 'overlap_override',
                                         'acceptance_withdrawn', 'reminders_set',
                                         'reminders_skipped', 'contact_attempt_recorded',
                                         'leader_confirmed', 'position_cancelled',
                                         'followup_skipped', 'outcome_recorded',
                                         'outcome_corrected',
                                         -- Story 4.11.
                                         'part_created', 'part_revised', 'part_cancelled',
                                         'duty_linked', 'duty_unlinked', 'review_flagged',
                                         'review_cleared')
    else false end;
$$;

create function app.duties_review_fields_ok(p_fields text[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_fields is not null and cardinality(p_fields) between 1 and 5
     and not exists (select 1 from unnest(p_fields) f where not app.duties_state_ok('review_field', f));
$$;

comment on function app.duties_review_fields_ok(text[]) is
  'Story 4.11: 1-5 owner-review field codes (time, place, label, assignee, cancelled).';


-- ---------------------------------------------------------------------------------------------
-- The SYNTHETIC Cells-like caller's dependency edges (fixture stands in for Cells)
-- ---------------------------------------------------------------------------------------------

insert into app.contract_module_dependencies (from_module, to_module)
values ('fixture', 'duties'), ('fixture', 'followups')
on conflict do nothing;


-- ---------------------------------------------------------------------------------------------
-- Link sources, part/position links and owner-review flags
-- ---------------------------------------------------------------------------------------------

create table app.duties_link_sources (
  source_type text primary key references app.contract_source_types (source_type),
  module text not null references app.contract_modules (module),
  role text not null check (app.duties_state_ok('link_role', role)),
  registered_at timestamptz not null default now()
);

comment on table app.duties_link_sources is
  'Story 4.11: source types registered with Duties as a cell programme part (role cell_part) or '
  'a linked event (role event). Written only by app.duties_register_link_source.';

alter table app.duties_link_sources enable row level security;
revoke all on table app.duties_link_sources from public, anon, authenticated, service_role;

create table app.duties_part_links (
  link_id uuid primary key default gen_random_uuid(),
  source_type text not null references app.duties_link_sources (source_type),
  source_id uuid not null,
  position_key text not null check (position_key ~ '^[a-z0-9][a-z0-9_-]{0,63}$'),
  link_kind text not null check (app.duties_state_ok('link_kind', link_kind)),
  cell_id uuid not null,
  occurrence_id uuid not null references app.duties_occurrences (occurrence_id) on delete cascade,
  slot_id uuid not null references app.duties_slots (slot_id) on delete cascade,
  source_revision bigint not null check (source_revision >= 1),
  linked_by_member uuid not null,
  linked_by_account uuid not null,
  linked_at timestamptz not null default now(),
  ended_at timestamptz,
  ended_by_member uuid,
  ended_by_account uuid,
  constraint duties_part_links_ended check ((ended_at is null) = (ended_by_member is null)
                                             and (ended_at is null) = (ended_by_account is null)),
  -- An owned link (a cell-owned slot) is permanent: the part/position-to-slot link is stable.
  constraint duties_part_links_owned_permanent check (link_kind = 'linked' or ended_at is null)
);

comment on table app.duties_part_links is
  'Story 4.11: the stable link from a caller''s part and position key to a Duties slot. `owned`: '
  'the slot of a cell-owned occurrence the caller created through Duties (permanent). `linked`: '
  'a display link to a department-owned position (no authority moves; ends when unlinked or the '
  'part is cancelled). One active link per (source_type, source_id, position_key).';

create unique index duties_part_links_active
  on app.duties_part_links (source_type, source_id, position_key) where ended_at is null;
create unique index duties_part_links_owned_slot
  on app.duties_part_links (slot_id) where link_kind = 'owned';
create index duties_part_links_slot on app.duties_part_links (slot_id) where ended_at is null;
create index duties_part_links_occurrence on app.duties_part_links (occurrence_id) where ended_at is null;
create index duties_part_links_linked_by on app.duties_part_links (linked_by_member);

alter table app.duties_part_links enable row level security;
revoke all on table app.duties_part_links from public, anon, authenticated, service_role;

-- Links never change, except that a display link ends once, the caller's part revision moves
-- forward and erasure anonymises the actors.
-- A direct DELETE is refused; only the cascade from the slot or occurrence (the local test
-- clean-ups) may remove a row.
create function app.duties_part_link_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
begin
  if tg_op = 'DELETE' then
    if pg_catalog.pg_trigger_depth() > 1 then
      return old;
    end if;
    raise exception using errcode = 'P0001', message = 'duties part links are permanent';
  end if;
  if (new.link_id, new.source_type, new.source_id, new.position_key, new.link_kind, new.cell_id,
      new.occurrence_id, new.slot_id, new.linked_at)
     is distinct from
     (old.link_id, old.source_type, old.source_id, old.position_key, old.link_kind, old.cell_id,
      old.occurrence_id, old.slot_id, old.linked_at)
     -- The caller's part revision only moves forward.
     or new.source_revision < old.source_revision
     or (new.linked_by_member is distinct from old.linked_by_member
         and new.linked_by_member is distinct from v_nil)
     or (new.linked_by_account is distinct from old.linked_by_account
         and new.linked_by_account is distinct from v_nil)
     or (old.ended_at is not null and new.ended_at is distinct from old.ended_at)
     or (old.ended_at is not null
         and new.ended_by_member is distinct from old.ended_by_member
         and new.ended_by_member is distinct from v_nil)
     or (old.ended_at is not null
         and new.ended_by_account is distinct from old.ended_by_account
         and new.ended_by_account is distinct from v_nil) then
    raise exception using errcode = 'P0001', message = 'duties part links are permanent';
  end if;
  return new;
end;
$$;

create trigger duties_part_links_permanent
  before update or delete on app.duties_part_links
  for each row execute function app.duties_part_link_guard();

create table app.duties_review_flags (
  flag_id uuid primary key default gen_random_uuid(),
  occurrence_id uuid not null references app.duties_occurrences (occurrence_id) on delete cascade,
  source_type text not null references app.duties_link_sources (source_type),
  source_id uuid not null,
  source_revision bigint not null check (source_revision >= 1),
  changed text[] not null check (app.duties_review_fields_ok(changed)),
  revision bigint not null default 1 check (revision >= 1),
  flagged_by_member uuid not null,
  flagged_by_account uuid not null,
  flagged_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  cleared_at timestamptz,
  cleared_by_member uuid,
  cleared_by_account uuid,
  constraint duties_review_flags_cleared check ((cleared_at is null) = (cleared_by_member is null)
                                                 and (cleared_at is null) = (cleared_by_account is null))
);

comment on table app.duties_review_flags is
  'Story 4.11: owner-review mismatches. A linked meeting or event changed (codes only); the '
  'department duty itself, its answers, revisions and reminders are unchanged until the '
  'department''s leader reviews it (duties.clear_review). One open flag per occurrence and source.';

create unique index duties_review_flags_open
  on app.duties_review_flags (occurrence_id, source_type, source_id) where cleared_at is null;
create index duties_review_flags_flagged_by on app.duties_review_flags (flagged_by_member);
create index duties_review_flags_cleared_by on app.duties_review_flags (cleared_by_member)
  where cleared_by_member is not null;

alter table app.duties_review_flags enable row level security;
revoke all on table app.duties_review_flags from public, anon, authenticated, service_role;

-- A part's events: which duties name an event (the linked-event reference, story 4.3's column).
create index duties_occurrences_event_ref on app.duties_occurrences (event_ref)
  where event_ref is not null;


-- ---------------------------------------------------------------------------------------------
-- Registration (owners, in their own migration)
-- ---------------------------------------------------------------------------------------------

create function app.duties_register_link_source(p_module text, p_source_type text, p_role text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform app.contract_require_source_owner(p_module, p_source_type);
  if not app.duties_state_ok('link_role', p_role) then
    perform app.contract_registration_fail('role must be cell_part or event');
  end if;
  if not exists (select 1 from app.contract_module_dependencies d
                  where d.from_module = p_module and d.to_module = 'duties') then
    perform app.contract_registration_fail(
      format('module %s has no dependency edge to duties', p_module));
  end if;
  -- Cell-owned occurrences are created for Cells only; events belong to Content. A SYNTHETIC
  -- fixture_ source may stand in for either (tests and the local E2E).
  if not ((p_role = 'cell_part' and p_module = 'cells')
          or (p_role = 'event' and p_module = 'content')
          or (p_module = 'fixture' and p_source_type ~ '^fixture_')) then
    perform app.contract_registration_fail(
      format('module %s may not register a %s source', p_module, p_role));
  end if;
  if exists (select 1 from app.duties_link_sources s
              where s.source_type = p_source_type and s.role <> p_role)
     and (exists (select 1 from app.duties_part_links l where l.source_type = p_source_type)
          or exists (select 1 from app.duties_review_flags f where f.source_type = p_source_type)) then
    perform app.contract_registration_fail('a source in use keeps its role');
  end if;
  insert into app.duties_link_sources (source_type, module, role)
  values (p_source_type, p_module, p_role)
  on conflict (source_type) do update set role = excluded.role, registered_at = now();
end;
$$;

comment on function app.duties_register_link_source(text, text, text) is
  'Story 4.11: register a source type the module owns as a Duties link source (cell_part: Cells '
  'or a SYNTHETIC fixture_ source; event: Content or a SYNTHETIC fixture_ source). The module '
  'needs a dependency edge to duties. Refused with SQLSTATE PCTR1.';


-- ---------------------------------------------------------------------------------------------
-- Owner operation helpers
-- ---------------------------------------------------------------------------------------------

-- The field errors of a part or event reference (contract v1 source_ref; the revision is
-- optional for reads).
create function app.duties_owner_ref_errors(p_input jsonb, p_need_revision boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select case
    when p_need_revision or p_input ? 'source_revision'
      then app.contract_check('source_ref', jsonb_build_object(
             'source_type', p_input -> 'source_type', 'source_id', p_input -> 'source_id',
             'source_revision', p_input -> 'source_revision')) -> 'field_errors'
    else app.contract_check('source_ref', jsonb_build_object(
           'source_type', p_input -> 'source_type', 'source_id', p_input -> 'source_id',
           'source_revision', 1)) -> 'field_errors'
  end;
$$;

-- A stable position key: a lower-case token or a lower-case uuid (1-64 characters).
create function app.duties_position_key_error(p_value jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_value is null or jsonb_typeof(p_value) = 'null' then 'required'
    when jsonb_typeof(p_value) <> 'string' then 'invalid'
    when (p_value #>> '{}') !~ '^[a-z0-9][a-z0-9_-]{0,63}$' then 'invalid'
  end;
$$;

-- The actor of an owner operation is the live session (never a payload field). With a cell, the
-- actor must hold that cell's leader or assistant scope now (the Admin role alone, Pastor and
-- department scopes do not count).
create function app.duties_owner_session(p_cell_id uuid, OUT member_id uuid, OUT account_id uuid,
                                         OUT capacity text)
returns record
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  select e.* into r from app.identity_evaluate_grant(null, null, null) e;
  if r.outcome is null or r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  if r.outcome <> 'granted' then
    perform app.cmd_fail('forbidden');
  end if;
  member_id := r.member_id;
  select l.auth_user_id into account_id from app.identity_account_links l
   where l.link_id = r.link_id and l.member_id = r.member_id and l.link_state = 'active';
  if account_id is null then
    perform app.cmd_fail('forbidden');
  end if;
  capacity := 'member';
  if p_cell_id is not null then
    capacity := case
      when app.identity_member_has_scope(member_id, 'cell_leader', p_cell_id) then 'cell_leader'
      when app.identity_member_has_scope(member_id, 'cell_assistant', p_cell_id) then 'cell_assistant'
    end;
    if capacity is null then
      perform app.cmd_fail('forbidden');
    end if;
  end if;
end;
$$;

-- The caller's part or event: registered with Duties in this role, and current at the given
-- revision (the caller has written its own row first). Answers the reference.
create function app.duties_owner_source(p_input jsonb, p_role text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_ref jsonb := jsonb_build_object('source_type', p_input -> 'source_type',
                                    'source_id', p_input -> 'source_id',
                                    'source_revision', p_input -> 'source_revision');
  v_check jsonb;
begin
  if not exists (select 1 from app.duties_link_sources s
                  where s.source_type = p_input ->> 'source_type' and s.role = p_role) then
    perform app.cmd_fail('validation_failed', '{"source_type": "unregistered"}');
  end if;
  v_check := app.contract_check_source(v_ref);
  if not coalesce((v_check ->> 'current')::boolean, false) then
    perform app.cmd_fail('conflict', '{"source_revision": "stale"}');
  end if;
  return v_ref;
end;
$$;

-- The part's positions from the input, in input order, or field errors.
create function app.duties_owner_positions(p_input jsonb, OUT errors jsonb, OUT keys text[],
                                           OUT names text[], OUT members uuid[])
returns record
language plpgsql
set search_path = ''
as $$
declare
  v_items jsonb := p_input -> 'positions';
  v_item jsonb;
  v_key text;
  v_errs jsonb;
  v_name text;
  v_member uuid;
begin
  errors := '{}'::jsonb;
  keys := '{}';
  names := '{}';
  members := '{}';
  if jsonb_typeof(v_items) is distinct from 'array' then
    errors := jsonb_build_object('positions',
                case when coalesce(jsonb_typeof(v_items), 'null') = 'null' then 'required' else 'invalid' end);
    return;
  end if;
  if jsonb_array_length(v_items) not between 1 and 10 then
    errors := '{"positions": "out_of_range"}';
    return;
  end if;
  for v_item in select x from jsonb_array_elements(v_items) x loop
    if jsonb_typeof(v_item) is distinct from 'object'
       or app.contract_unknown_keys(v_item, array['position_key', 'position_name', 'member_id']) <> '{}'::jsonb
       or app.duties_position_key_error(v_item -> 'position_key') is not null then
      errors := '{"positions": "invalid"}';
      return;
    end if;
    v_key := v_item ->> 'position_key';
    if v_key = any (keys) then
      errors := '{"positions": "duplicate"}';
      return;
    end if;
    select t.errors, t.value into v_errs, v_name
      from app.duties_text(v_item, 'position_name', false, 60, false, '{}'::jsonb) t;
    v_member := null;
    if coalesce(jsonb_typeof(v_item -> 'member_id'), 'null') <> 'null' then
      if app.contract_uuid_error(v_item -> 'member_id') is not null then
        v_errs := v_errs || '{"member_id": "invalid"}';
      else
        v_member := (v_item ->> 'member_id')::uuid;
      end if;
    end if;
    if v_errs <> '{}'::jsonb then
      errors := errors || jsonb_build_object('position:' || v_key, 'invalid');
    end if;
    keys := keys || v_key;
    names := names || v_name;
    members := members || v_member;
  end loop;
  if errors = '{}'::jsonb
     and (select count(distinct lower(n)) from unnest(names) n where n is not null)
         <> (select count(*) from unnest(names) n where n is not null) then
    errors := '{"positions": "duplicate_name"}';
  end if;
end;
$$;

-- Cancel one position of a published occurrence the caller has locked (story 4.9's position
-- cancellation, for a position a revised part no longer has): the slot is cancelled, its current
-- assignment ends `cancelled` with a generic notice to a pending or accepted assignee, and every
-- pending job of the position's assignments is cancelled. Returns the notification work for the
-- caller to run last.
create function app.duties_owner_cancel_slot(p_occ app.duties_occurrences, p_slot_id uuid,
                                             p_actor_member uuid, p_actor_account uuid,
                                             p_capacity text, p_command text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_revision bigint;
  v_slot_revision bigint;
  v_end_revision bigint;
  v_old app.duties_assignments;
  v_ops jsonb := '[]'::jsonb;
  v_id uuid;
begin
  perform pg_catalog.set_config('app.duties_actor', jsonb_build_object(
    'member', p_actor_member, 'account', p_actor_account, 'capacity', p_capacity,
    'command', p_command)::text, true);
  update app.duties_occurrences o set revision = o.revision + 1
   where o.occurrence_id = p_occ.occurrence_id returning o.revision into v_revision;
  update app.duties_slots s
     set cancelled_at = now(), cancelled_by_member = p_actor_member,
         cancelled_by_account = p_actor_account, revision = s.revision + 1
   where s.slot_id = p_slot_id
  returning s.revision into v_slot_revision;
  select a.* into v_old from app.duties_assignments a
   where a.slot_id = p_slot_id and a.assignment_state = 'current' for update;
  if v_old.assignment_id is not null then
    update app.duties_assignments a
       set assignment_state = 'cancelled', ended_at = now(), end_reason = 'cancelled',
           revision = a.revision + 1
     where a.assignment_id = v_old.assignment_id
    returning a.revision into v_end_revision;
    if v_old.response in ('pending', 'accepted') and app.duties_notice_recipient(v_old.member_id) then
      v_ops := v_ops || jsonb_build_array(jsonb_build_object('op', 'enqueue', 'counts', true,
        'key', jsonb_build_object(
          'source_type', 'duties_assignment', 'source_id', v_old.assignment_id,
          'source_revision', v_end_revision, 'recipient_member_id', v_old.member_id,
          'reminder_kind', 'duty_cancelled', 'scheduled_at', app.cmd_utc(now()))));
    end if;
  end if;
  insert into app.duties_slot_revisions (slot_id, slot_revision, occurrence_id,
                                         occurrence_revision, change_class, changed_fields,
                                         duty_name, starts_at, ends_at, reporting_at, location,
                                         instructions, topic, scripture, event_ref, member_id,
                                         assignment_id, response_deadline, created_by_member,
                                         created_by_account, command_request_id)
  values (p_slot_id, v_slot_revision, p_occ.occurrence_id, v_revision, 'cancelled', '{}',
          p_occ.duty_name, p_occ.starts_at, p_occ.ends_at, p_occ.reporting_at, p_occ.location,
          p_occ.instructions, p_occ.topic, p_occ.scripture, p_occ.event_ref, null, null, null,
          p_actor_member, p_actor_account, null);
  perform app.duties_audit_series_event('position_cancelled', p_actor_member, p_actor_account,
                                        p_capacity, p_command, p_occ.department_id, p_occ.series_id,
                                        p_occ.occurrence_id, v_old.assignment_id, v_old.member_id,
                                        null, v_revision);
  for v_id in select a.assignment_id from app.duties_assignments a where a.slot_id = p_slot_id
               order by a.assignment_id loop
    v_ops := jsonb_build_array(jsonb_build_object('op', 'cancel', 'source_id', v_id,
                                                  'reason', 'source_cancelled')) || v_ops;
  end loop;
  return v_ops;
end;
$$;

-- The part's positions as its caller sees them (owned and display links). Responses and their
-- flags only: no notes, reasons or contact data; a display link shows no people.
create function app.duties_owner_positions_json(p_source_type text, p_source_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x.obj order by x.kind_order, x.position_no, x.position_key), '[]'::jsonb)
    from (
      select 0 as kind_order, s.position_no, l.position_key, jsonb_build_object(
               'position_key', l.position_key,
               'kind', 'owned',
               'slot_id', s.slot_id,
               'position_no', s.position_no,
               'position_name', s.position_name,
               'slot_revision', s.revision,
               'cancelled', s.cancelled_at is not null,
               'assignment', (
                 select jsonb_build_object(
                          'assignment_id', a.assignment_id,
                          'revision', a.revision,
                          'member_id', a.member_id,
                          'display_name', app.duties_display_name(a.member_id),
                          'response', a.response,
                          'response_provenance', a.response_provenance,
                          'response_deadline', app.cmd_utc(a.response_deadline),
                          'deadline_source', a.deadline_source,
                          'short_notice', a.short_notice,
                          'needs_contact', app.duties_needs_contact(a, o) is not null)
                   from app.duties_assignments a
                  where a.slot_id = s.slot_id and a.assignment_state = 'current')) as obj
        from app.duties_part_links l
        join app.duties_slots s on s.slot_id = l.slot_id
        join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
       where l.source_type = p_source_type and l.source_id = p_source_id and l.link_kind = 'owned'
      union all
      select 1, null, l.position_key, jsonb_build_object(
               'position_key', l.position_key,
               'kind', 'linked',
               'link_id', l.link_id,
               'slot_id', s.slot_id,
               'occurrence_id', o.occurrence_id,
               'department_id', o.department_id,
               -- A synthetic department is never named outside local and staging.
               'department_name', case when not d.is_synthetic
                                         or app.platform_current_environment() in ('local', 'staging')
                                       then d.name end,
               'duty_name', o.duty_name,
               'position_name', s.position_name,
               'starts_at', app.cmd_utc(o.starts_at),
               'ends_at', case when o.ends_at is not null then app.cmd_utc(o.ends_at) end,
               'reporting_at', case when o.reporting_at is not null then app.cmd_utc(o.reporting_at) end,
               'state', o.occurrence_state,
               'cancelled', s.cancelled_at is not null,
               'filled', exists (select 1 from app.duties_assignments a
                                  where a.slot_id = s.slot_id and a.assignment_state = 'current'
                                    and a.response <> 'declined'),
               'linked_at', app.cmd_utc(l.linked_at))
        from app.duties_part_links l
        join app.duties_slots s on s.slot_id = l.slot_id
        join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
        left join app.duties_departments d on d.department_id = o.department_id
       where l.source_type = p_source_type and l.source_id = p_source_id and l.link_kind = 'linked'
         and l.ended_at is null) x;
$$;

-- An answer of the put and cancel operations: ids, revisions, states and counts only.
create function app.duties_owner_part_answer(p_source_type text, p_source_id uuid,
                                             p_occurrence_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'occurrence_id', o.occurrence_id,
    'revision', o.revision,
    'state', o.occurrence_state,
    'positions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'position_key', l.position_key,
               'slot_id', s.slot_id,
               'cancelled', s.cancelled_at is not null,
               'assignment_id', a.assignment_id,
               'assignment_revision', a.revision,
               'response', a.response)
             order by s.position_no)
        from app.duties_part_links l
        join app.duties_slots s on s.slot_id = l.slot_id
        left join app.duties_assignments a on a.slot_id = s.slot_id and a.assignment_state = 'current'
       where l.source_type = p_source_type and l.source_id = p_source_id
         and l.link_kind = 'owned'), '[]'::jsonb))
    from app.duties_occurrences o
   where o.occurrence_id = p_occurrence_id;
$$;


-- ---------------------------------------------------------------------------------------------
-- Owner operation: create or revise a cell-owned part (inside the caller's transaction)
-- ---------------------------------------------------------------------------------------------
--
-- Input: {source_type, source_id, source_revision, cell_id, expected_revision (null to create;
-- the occurrence revision to revise), duty_name, starts_at, ends_at?, reporting_at?, location?,
-- instructions?, topic?, scripture?, event_ref?, response_deadline?, override_reason?,
-- positions: [{position_key, position_name?, member_id?}] (1-10)}.
--
-- Create: one published cell-owned occurrence, one slot and one permanent owned link per
-- position, a pending assignment for each named member (duty_assigned notice, 4.8 reminders).
-- Revise (the desired state of the part): a position no longer listed is cancelled; a position
-- whose member changes is released first; the occurrence fields then change through the 4.2
-- engine (material changes ask the kept members again, notes-only changes keep their answers);
-- new positions are added; new members are asked. A renamed position or a cancelled key is
-- refused (use a new key); an identical put changes nothing.
-- Every new or re-asked assignment passes the 4.4 overlap gate (override_reason). Refusals:
-- validation_failed, forbidden, unauthenticated, conflict ({"source_revision": "stale"}, the
-- expected revision, {"position:<key>": "linked"}, {"source_id": "linked"}), unavailable
-- (Q4, or Q2 through Notifications).
create function app.duties_owner_put_part(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_cmd constant text := 'duties.owner_put_part';
  v_errors jsonb;
  v_pos record;
  v_cell uuid;
  v_has_expected boolean;
  v_expected bigint;
  v_name text;
  v_starts timestamptz;
  v_ends timestamptz;
  v_reporting timestamptz;
  v_location text;
  v_instructions text;
  v_topic text;
  v_scripture text;
  v_event uuid;
  v_deadline timestamptz;
  v_reason text;
  v_actor record;
  v_ref jsonb;
  v_source_type text;
  v_source_id uuid;
  v_source_revision bigint;
  v_occ_id uuid;
  v_old app.duties_occurrences;
  v_new app.duties_occurrences;
  v_cur app.duties_occurrences;
  v_change jsonb;
  v_ops jsonb := '[]'::jsonb;
  v_created jsonb := '[]'::jsonb;
  v_slot uuid;
  v_link uuid;
  v_key text;
  v_n integer;
  i integer;
  v_fields_changed boolean := false;
  v_material boolean := false;
  v_changed_any boolean := false;
  v_asks boolean := false;
  v_next_no integer;
  v_revision bigint;
  v_recorded integer := 0;
  v_notified jsonb;
  v_is_create boolean;
  v_plan jsonb;
  v_new_slots jsonb := '{}'::jsonb;
  r record;
begin
  if jsonb_typeof(p_input) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"input": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_input, array['source_type', 'source_id',
                'source_revision', 'cell_id', 'expected_revision', 'duty_name', 'starts_at',
                'ends_at', 'reporting_at', 'location', 'instructions', 'topic', 'scripture',
                'event_ref', 'response_deadline', 'override_reason', 'positions'])
              || app.duties_owner_ref_errors(p_input, true);
  select t.errors, t.value into v_errors, v_cell from app.duties_uuid(p_input, 'cell_id', v_errors) t;
  v_has_expected := coalesce(jsonb_typeof(p_input -> 'expected_revision'), 'null') <> 'null';
  if v_has_expected then
    if app.contract_revision_error(p_input -> 'expected_revision') is not null then
      v_errors := v_errors || '{"expected_revision": "invalid"}';
    else
      v_expected := (p_input ->> 'expected_revision')::numeric::bigint;
    end if;
  end if;
  select t.errors, t.value into v_errors, v_name
    from app.duties_text(p_input, 'duty_name', true, 80, false, v_errors) t;
  select t.errors, t.value into v_errors, v_starts
    from app.duties_instant(p_input, 'starts_at', true, v_errors) t;
  select t.errors, t.value into v_errors, v_ends
    from app.duties_instant(p_input, 'ends_at', false, v_errors) t;
  select t.errors, t.value into v_errors, v_reporting
    from app.duties_instant(p_input, 'reporting_at', false, v_errors) t;
  select t.errors, t.value into v_errors, v_location
    from app.duties_text(p_input, 'location', false, 120, false, v_errors) t;
  select t.errors, t.value into v_errors, v_instructions
    from app.duties_text(p_input, 'instructions', false, 1000, true, v_errors) t;
  select t.errors, t.value into v_errors, v_topic
    from app.duties_text(p_input, 'topic', false, 120, false, v_errors) t;
  select t.errors, t.value into v_errors, v_scripture
    from app.duties_text(p_input, 'scripture', false, 120, false, v_errors) t;
  if coalesce(jsonb_typeof(p_input -> 'event_ref'), 'null') <> 'null' then
    select t.errors, t.value into v_errors, v_event from app.duties_uuid(p_input, 'event_ref', v_errors) t;
  end if;
  select t.errors, t.value into v_errors, v_deadline
    from app.duties_instant(p_input, 'response_deadline', false, v_errors) t;
  select t.errors, t.value into v_errors, v_reason
    from app.duties_text(p_input, 'override_reason', false, 280, true, v_errors) t;
  select p.* into v_pos from app.duties_owner_positions(p_input) p;
  v_errors := v_errors || v_pos.errors;
  if not (v_errors ? 'starts_at' or v_errors ? 'ends_at' or v_errors ? 'reporting_at') then
    v_errors := v_errors || app.duties_times_errors(v_starts, v_ends, v_reporting,
                                                     array['starts_at', 'ends_at', 'reporting_at']);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select s.* into v_actor from app.duties_owner_session(v_cell) s;
  v_ref := app.duties_owner_source(p_input, 'cell_part');
  v_source_type := v_ref ->> 'source_type';
  v_source_id := (v_ref ->> 'source_id')::uuid;
  v_source_revision := (v_ref ->> 'source_revision')::numeric::bigint;
  v_n := cardinality(v_pos.keys);

  select l.occurrence_id into v_occ_id from app.duties_part_links l
   where l.source_type = v_source_type and l.source_id = v_source_id and l.link_kind = 'owned'
   limit 1;
  v_is_create := v_occ_id is null;

  if v_is_create then
    if v_has_expected then
      perform app.cmd_fail('validation_failed', '{"expected_revision": "must_be_null"}');
    end if;
    -- A key the part already uses for a display link stays that link.
    select l.position_key into v_key from app.duties_part_links l
     where l.source_type = v_source_type and l.source_id = v_source_id and l.ended_at is null
       and l.position_key = any (v_pos.keys)
     order by l.position_key limit 1;
    if v_key is not null then
      perform app.cmd_fail('conflict', jsonb_build_object('position:' || v_key, 'linked'));
    end if;
    perform app.duties_lock_members(v_pos.members);
    v_errors := '{}'::jsonb;
    for i in 1 .. v_n loop
      if v_pos.members[i] is not null and not app.duties_member_active(v_pos.members[i]) then
        v_errors := v_errors || jsonb_build_object('position:' || v_pos.keys[i], 'unknown_member');
      end if;
    end loop;
    if v_errors <> '{}'::jsonb then
      perform app.cmd_fail('validation_failed', v_errors);
    end if;
    insert into app.duties_occurrences (cell_id, duty_name, starts_at, ends_at, reporting_at,
                                        location, instructions, topic, scripture, event_ref,
                                        occurrence_state, created_by_member, created_by_account)
    values (v_cell, v_name, v_starts, v_ends, v_reporting, v_location, v_instructions, v_topic,
            v_scripture, v_event, 'published', v_actor.member_id, v_actor.account_id)
    returning * into v_cur;
    for i in 1 .. v_n loop
      insert into app.duties_slots (occurrence_id, position_no, position_name)
      values (v_cur.occurrence_id, i, v_pos.names[i])
      returning slot_id into v_slot;
      insert into app.duties_slot_revisions (slot_id, slot_revision, occurrence_id,
                                             occurrence_revision, change_class, changed_fields,
                                             duty_name, starts_at, ends_at, reporting_at, location,
                                             instructions, topic, scripture, event_ref, member_id,
                                             assignment_id, response_deadline, created_by_member,
                                             created_by_account, command_request_id)
      values (v_slot, 1, v_cur.occurrence_id, v_cur.revision, 'published', '{}', v_cur.duty_name,
              v_cur.starts_at, v_cur.ends_at, v_cur.reporting_at, v_cur.location,
              v_cur.instructions, v_cur.topic, v_cur.scripture, v_cur.event_ref, null, null, null,
              v_actor.member_id, v_actor.account_id, null);
      -- Race-safe: a concurrent create of the same part waits on the unique index, then finds
      -- the key taken and is refused cleanly (its whole transaction rolls back).
      insert into app.duties_part_links (source_type, source_id, position_key, link_kind, cell_id,
                                         occurrence_id, slot_id, source_revision,
                                         linked_by_member, linked_by_account)
      values (v_source_type, v_source_id, v_pos.keys[i], 'owned', v_cell, v_cur.occurrence_id,
              v_slot, v_source_revision, v_actor.member_id, v_actor.account_id)
      on conflict (source_type, source_id, position_key) where ended_at is null do nothing
      returning link_id into v_link;
      if v_link is null then
        perform app.cmd_fail('conflict', '{"source_id": "linked"}');
      end if;
    end loop;
    perform app.duties_audit_series_event('part_created', v_actor.member_id, v_actor.account_id,
                                          v_actor.capacity, v_cmd, null, null, v_cur.occurrence_id,
                                          null, null, null, v_cur.revision);
    -- Each named member is asked through the 4.2 engine (deadline or 4.8 default, notice, plan).
    for i in 1 .. v_n loop
      continue when v_pos.members[i] is null;
      select o.* into v_cur from app.duties_occurrences o where o.occurrence_id = v_cur.occurrence_id;
      select l.slot_id into v_slot from app.duties_part_links l
       where l.source_type = v_source_type and l.source_id = v_source_id
         and l.position_key = v_pos.keys[i] and l.link_kind = 'owned';
      v_change := app.duties_apply_change(v_cur, v_cur, v_slot, v_pos.members[i], true, v_deadline,
                                          'response_deadline', v_actor.member_id,
                                          v_actor.account_id, v_actor.capacity, v_cmd, false);
      v_created := v_created || coalesce(v_change -> 'created', '[]'::jsonb);
      v_ops := v_ops || coalesce(v_change -> 'ops', '[]'::jsonb);
    end loop;
    v_occ_id := v_cur.occurrence_id;
    v_changed_any := true;
  else
    -- Revise: the occurrence first (AD-2: occurrence, slots, then the members' locks).
    select o.* into v_old from app.duties_occurrences o where o.occurrence_id = v_occ_id for update;
    if v_old.cell_id is distinct from v_cell then
      perform app.cmd_fail('not_found');
    end if;
    if not v_has_expected then
      perform app.cmd_fail('validation_failed', '{"expected_revision": "required"}');
    end if;
    if v_old.revision <> v_expected then
      perform app.cmd_fail('conflict', null, v_old.revision);
    end if;
    if v_old.occurrence_state = 'cancelled' then
      perform app.cmd_fail('validation_failed', '{"source_id": "cancelled"}');
    end if;
    if app.duties_occurrence_start(v_old) <= now() then
      perform app.cmd_fail('validation_failed', '{"source_id": "started"}');
    end if;
    perform 1 from app.duties_slots s where s.occurrence_id = v_occ_id order by s.position_no for update;
    perform app.duties_lock_members(v_pos.members);

    -- The part's current positions (owned links) against what the input asks of each.
    select coalesce(jsonb_agg(jsonb_build_object(
             'position_key', coalesce(c.position_key, w.position_key),
             'slot_id', c.slot_id, 'position_no', c.position_no, 'current_name', c.position_name,
             'cancelled', coalesce(c.cancelled, false), 'current_member', c.current_member,
             'wanted', w.position_key is not null, 'wanted_name', w.wanted_name,
             'wanted_member', w.wanted_member, 'ord', w.ord)), '[]'::jsonb)
      into v_plan
      from (select l.position_key, s.slot_id, s.position_no, s.position_name,
                   s.cancelled_at is not null as cancelled,
                   (select a.member_id from app.duties_assignments a
                     where a.slot_id = s.slot_id and a.assignment_state = 'current') as current_member
              from app.duties_part_links l join app.duties_slots s on s.slot_id = l.slot_id
             where l.source_type = v_source_type and l.source_id = v_source_id
               and l.link_kind = 'owned') c
      full join (select k.key as position_key, k.ord::integer as ord,
                        v_pos.names[k.ord] as wanted_name, v_pos.members[k.ord] as wanted_member
                   from unnest(v_pos.keys) with ordinality k(key, ord)) w
        on w.position_key = c.position_key;
    v_errors := '{}'::jsonb;
    for r in select * from jsonb_to_recordset(v_plan) as x(position_key text, slot_id uuid,
               position_no integer, current_name text, cancelled boolean, current_member uuid,
               wanted boolean, wanted_name text, wanted_member uuid, ord integer)
              where x.wanted order by x.ord loop
      if r.slot_id is not null and r.cancelled then
        v_errors := v_errors || jsonb_build_object('position:' || r.position_key, 'cancelled');
      elsif r.slot_id is not null and r.current_name is distinct from r.wanted_name then
        v_errors := v_errors || jsonb_build_object('position:' || r.position_key, 'renamed');
      elsif r.wanted_member is not null and r.wanted_member is distinct from r.current_member
            and not app.duties_member_active(r.wanted_member) then
        v_errors := v_errors || jsonb_build_object('position:' || r.position_key, 'unknown_member');
      end if;
    end loop;
    if v_errors <> '{}'::jsonb then
      perform app.cmd_fail('validation_failed', v_errors);
    end if;
    -- A new key the part already uses for a display link stays that link.
    select l.position_key into v_key from app.duties_part_links l
     where l.source_type = v_source_type and l.source_id = v_source_id and l.ended_at is null
       and l.link_kind = 'linked'
       and l.position_key in (select x.position_key
                                from jsonb_to_recordset(v_plan) as x(position_key text, slot_id uuid)
                               where x.slot_id is null)
     order by l.position_key limit 1;
    if v_key is not null then
      perform app.cmd_fail('conflict', jsonb_build_object('position:' || v_key, 'linked'));
    end if;
    if jsonb_array_length(v_plan) > 50 then
      perform app.cmd_fail('validation_failed', '{"positions": "too_many"}');
    end if;

    v_new := v_old;
    v_new.duty_name := v_name;
    v_new.starts_at := v_starts;
    v_new.ends_at := v_ends;
    v_new.reporting_at := v_reporting;
    v_new.location := v_location;
    v_new.instructions := v_instructions;
    v_new.topic := v_topic;
    v_new.scripture := v_scripture;
    v_new.event_ref := v_event;
    v_fields_changed := (v_new.duty_name, v_new.starts_at, v_new.ends_at, v_new.reporting_at,
                         v_new.location, v_new.instructions, v_new.topic, v_new.scripture,
                         v_new.event_ref)
                        is distinct from
                        (v_old.duty_name, v_old.starts_at, v_old.ends_at, v_old.reporting_at,
                         v_old.location, v_old.instructions, v_old.topic, v_old.scripture,
                         v_old.event_ref);
    v_material := (v_new.duty_name, v_new.starts_at, v_new.ends_at, v_new.reporting_at,
                   v_new.location)
                  is distinct from
                  (v_old.duty_name, v_old.starts_at, v_old.ends_at, v_old.reporting_at,
                   v_old.location);
    select v_fields_changed or coalesce(bool_or(
             (x.slot_id is not null and not x.cancelled and not x.wanted)
             or x.slot_id is null
             or (x.slot_id is not null and x.wanted and x.wanted_member is distinct from x.current_member)),
             false),
           -- Somebody is asked: a kept member after a material change, or a new member.
           coalesce(bool_or((v_material and x.slot_id is not null and x.wanted
                             and x.current_member is not null
                             and x.wanted_member is not distinct from x.current_member)
                            or (x.wanted and x.wanted_member is not null
                                and x.wanted_member is distinct from x.current_member)), false)
      into v_changed_any, v_asks
      from jsonb_to_recordset(v_plan) as x(slot_id uuid, cancelled boolean, current_member uuid,
                                           wanted boolean, wanted_member uuid);
    if v_deadline is not null and not v_asks then
      perform app.cmd_fail('validation_failed', '{"response_deadline": "not_material"}');
    end if;
    if not v_changed_any then
      return jsonb_build_object('created', false, 'changed', false, 'notices_queued', 0,
                                'overrides_recorded', 0)
             || app.duties_owner_part_answer(v_source_type, v_source_id, v_occ_id);
    end if;

    -- a) Positions the part no longer has are cancelled (4.9 rules).
    for r in select * from jsonb_to_recordset(v_plan) as x(slot_id uuid, position_no integer,
               cancelled boolean, wanted boolean)
              where x.slot_id is not null and not x.cancelled and not x.wanted
              order by x.position_no loop
      select o.* into v_cur from app.duties_occurrences o where o.occurrence_id = v_occ_id;
      v_ops := v_ops || app.duties_owner_cancel_slot(v_cur, r.slot_id, v_actor.member_id,
                                                     v_actor.account_id, v_actor.capacity, v_cmd);
    end loop;
    -- b) A position whose member changes releases its current member first (nobody who is being
    --    replaced is asked again in between).
    for r in select * from jsonb_to_recordset(v_plan) as x(slot_id uuid, position_no integer,
               current_member uuid, wanted boolean, wanted_member uuid)
              where x.slot_id is not null and x.wanted and x.current_member is not null
                and x.wanted_member is distinct from x.current_member
              order by x.position_no loop
      select o.* into v_cur from app.duties_occurrences o where o.occurrence_id = v_occ_id;
      v_change := app.duties_apply_change(v_cur, v_cur, r.slot_id, null, true, null,
                                          'response_deadline', v_actor.member_id,
                                          v_actor.account_id, v_actor.capacity, v_cmd, false);
      v_ops := v_ops || coalesce(v_change -> 'ops', '[]'::jsonb);
    end loop;
    -- c) The occurrence's own fields (a material change asks the kept members again).
    if v_fields_changed then
      select o.* into v_cur from app.duties_occurrences o where o.occurrence_id = v_occ_id;
      v_change := app.duties_apply_change(v_cur, v_new, null, null, false,
                                          case when v_material then v_deadline end,
                                          'response_deadline', v_actor.member_id,
                                          v_actor.account_id, v_actor.capacity, v_cmd, false);
      v_created := v_created || coalesce(v_change -> 'created', '[]'::jsonb);
      v_ops := v_ops || coalesce(v_change -> 'ops', '[]'::jsonb);
    end if;
    -- d) New positions (one occurrence revision for the new structure).
    if exists (select 1 from jsonb_to_recordset(v_plan) as x(slot_id uuid) where x.slot_id is null) then
      update app.duties_occurrences o set revision = o.revision + 1
       where o.occurrence_id = v_occ_id returning * into v_cur;
      select coalesce(max(s.position_no), 0) into v_next_no from app.duties_slots s
       where s.occurrence_id = v_occ_id;
      for r in select * from jsonb_to_recordset(v_plan) as x(position_key text, slot_id uuid,
                 wanted_name text, ord integer)
                where x.slot_id is null order by x.ord loop
        v_next_no := v_next_no + 1;
        insert into app.duties_slots (occurrence_id, position_no, position_name)
        values (v_occ_id, v_next_no, r.wanted_name)
        returning slot_id into v_slot;
        insert into app.duties_slot_revisions (slot_id, slot_revision, occurrence_id,
                                               occurrence_revision, change_class, changed_fields,
                                               duty_name, starts_at, ends_at, reporting_at,
                                               location, instructions, topic, scripture, event_ref,
                                               member_id, assignment_id, response_deadline,
                                               created_by_member, created_by_account,
                                               command_request_id)
        values (v_slot, 1, v_occ_id, v_cur.revision, 'published', '{}', v_cur.duty_name,
                v_cur.starts_at, v_cur.ends_at, v_cur.reporting_at, v_cur.location,
                v_cur.instructions, v_cur.topic, v_cur.scripture, v_cur.event_ref, null, null,
                null, v_actor.member_id, v_actor.account_id, null);
        v_link := null;
        insert into app.duties_part_links (source_type, source_id, position_key, link_kind,
                                           cell_id, occurrence_id, slot_id, source_revision,
                                           linked_by_member, linked_by_account)
        values (v_source_type, v_source_id, r.position_key, 'owned', v_cell, v_occ_id, v_slot,
                v_source_revision, v_actor.member_id, v_actor.account_id)
        on conflict (source_type, source_id, position_key) where ended_at is null do nothing
        returning link_id into v_link;
        if v_link is null then
          perform app.cmd_fail('conflict', jsonb_build_object('position:' || r.position_key, 'linked'));
        end if;
        v_new_slots := v_new_slots || jsonb_build_object(r.position_key, v_slot);
      end loop;
    end if;
    -- e) New members are asked (kept positions whose member changed, and new positions).
    for r in select * from jsonb_to_recordset(v_plan) as x(position_key text, slot_id uuid,
               current_member uuid, wanted boolean, wanted_member uuid, ord integer)
              where x.wanted and x.wanted_member is not null
                and x.wanted_member is distinct from x.current_member
              order by x.ord loop
      select o.* into v_cur from app.duties_occurrences o where o.occurrence_id = v_occ_id;
      v_change := app.duties_apply_change(v_cur, v_cur,
                                          coalesce(r.slot_id, (v_new_slots ->> r.position_key)::uuid),
                                          r.wanted_member, true, v_deadline, 'response_deadline',
                                          v_actor.member_id, v_actor.account_id, v_actor.capacity,
                                          v_cmd, false);
      v_created := v_created || coalesce(v_change -> 'created', '[]'::jsonb);
      v_ops := v_ops || coalesce(v_change -> 'ops', '[]'::jsonb);
    end loop;
    select o.revision into v_revision from app.duties_occurrences o where o.occurrence_id = v_occ_id;
    perform app.duties_audit_series_event('part_revised', v_actor.member_id, v_actor.account_id,
                                          v_actor.capacity, v_cmd, null, null, v_occ_id, null,
                                          null, case when v_material then 'material' end,
                                          v_revision);
  end if;

  -- The 4.4 overlap gate on every assignment this put created (a carried one keeps its reason).
  v_recorded := app.duties_gate_created(v_created, v_reason, v_actor.member_id, v_actor.account_id,
                                        v_actor.capacity, v_cmd);
  -- The caller's revision of the part is kept on its links (a later operation names a newer one).
  update app.duties_part_links l set source_revision = v_source_revision
   where l.source_type = v_source_type and l.source_id = v_source_id and l.link_kind = 'owned'
     and l.source_revision < v_source_revision;
  -- Follow-ups and Notifications last (AD-2).
  v_notified := app.duties_notify(v_ops);
  return jsonb_build_object('created', v_is_create, 'changed', v_changed_any,
                            'notices_queued', (v_notified ->> 'queued')::integer,
                            'overrides_recorded', v_recorded)
         || app.duties_owner_part_answer(v_source_type, v_source_id, v_occ_id);
end;
$$;

comment on function app.duties_owner_put_part(jsonb) is
  'Story 4.11 owner operation (not client-executable): create or revise the cell-owned Duties '
  'occurrence of a registered cell_part source inside the caller''s transaction, with stable '
  'position keys. The actor is the live session holding cell_leader or cell_assistant of the cell.';


-- ---------------------------------------------------------------------------------------------
-- Owner operation: cancel a cell-owned part
-- ---------------------------------------------------------------------------------------------
--
-- Input: {source_type, source_id, source_revision, cell_id, expected_revision}. The 4.3
-- cancellation (every current assignment cancelled, a generic notice to pending or accepted
-- assignees, every pending job cancelled); the part's display links end. The owned links stay
-- (history).
create function app.duties_owner_cancel_part(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_cmd constant text := 'duties.owner_cancel_part';
  v_errors jsonb;
  v_cell uuid;
  v_actor record;
  v_ref jsonb;
  v_occ_id uuid;
  v_occ app.duties_occurrences;
  v_result jsonb;
  v_notified jsonb;
  v_ended integer;
  v_revision bigint;
begin
  if jsonb_typeof(p_input) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"input": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_input, array['source_type', 'source_id',
                'source_revision', 'cell_id', 'expected_revision'])
              || app.duties_owner_ref_errors(p_input, true)
              || jsonb_strip_nulls(jsonb_build_object('expected_revision',
                   app.contract_revision_error(p_input -> 'expected_revision')));
  select t.errors, t.value into v_errors, v_cell from app.duties_uuid(p_input, 'cell_id', v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select s.* into v_actor from app.duties_owner_session(v_cell) s;
  v_ref := app.duties_owner_source(p_input, 'cell_part');
  select l.occurrence_id into v_occ_id from app.duties_part_links l
   where l.source_type = v_ref ->> 'source_type' and l.source_id = (v_ref ->> 'source_id')::uuid
     and l.link_kind = 'owned'
   limit 1;
  if v_occ_id is null then
    perform app.cmd_fail('not_found');
  end if;
  select o.* into v_occ from app.duties_occurrences o where o.occurrence_id = v_occ_id for update;
  if v_occ.cell_id is distinct from v_cell then
    perform app.cmd_fail('not_found');
  end if;
  if v_occ.revision <> (p_input ->> 'expected_revision')::numeric::bigint then
    perform app.cmd_fail('conflict', null, v_occ.revision);
  end if;
  if v_occ.occurrence_state = 'cancelled' then
    perform app.cmd_fail('validation_failed', '{"source_id": "cancelled"}');
  end if;
  if app.duties_occurrence_start(v_occ) <= now() then
    perform app.cmd_fail('validation_failed', '{"source_id": "started"}');
  end if;
  v_result := app.duties_cancel_one(v_occ, v_actor.member_id, v_actor.account_id, v_actor.capacity,
                                    v_cmd);
  update app.duties_part_links l
     set ended_at = now(), ended_by_member = v_actor.member_id, ended_by_account = v_actor.account_id
   where l.source_type = v_ref ->> 'source_type' and l.source_id = (v_ref ->> 'source_id')::uuid
     and l.link_kind = 'linked' and l.ended_at is null;
  get diagnostics v_ended = row_count;
  select o.revision into v_revision from app.duties_occurrences o where o.occurrence_id = v_occ_id;
  perform app.duties_audit_series_event('part_cancelled', v_actor.member_id, v_actor.account_id,
                                        v_actor.capacity, v_cmd, null, null, v_occ_id, null, null,
                                        null, v_revision);
  v_notified := app.duties_notify(v_result -> 'ops');
  return jsonb_build_object('created', false, 'changed', true,
                            'assignments_cancelled', (v_result ->> 'assignments_cancelled')::integer,
                            'links_ended', v_ended,
                            'notices_queued', (v_notified ->> 'queued')::integer)
         || app.duties_owner_part_answer(v_ref ->> 'source_type', (v_ref ->> 'source_id')::uuid,
                                         v_occ_id);
end;
$$;

comment on function app.duties_owner_cancel_part(jsonb) is
  'Story 4.11 owner operation (not client-executable): cancel the cell-owned occurrence of a '
  'part (4.3 cancellation) and end its display links, inside the caller''s transaction.';


-- ---------------------------------------------------------------------------------------------
-- Owner operations: display-link a department duty, end a display link
-- ---------------------------------------------------------------------------------------------
--
-- Link input: {source_type, source_id, source_revision, cell_id, position_key, slot_id}. The
-- target must be a position (not cancelled) of a published department-owned occurrence that has
-- not started; anything else is not_found (no disclosure). Nothing of the duty changes: it is
-- locked FOR SHARE only, keeps its revision, its answers and its reminders, and only its
-- department manages it. One active link per part position.
create function app.duties_owner_link_duty(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_cmd constant text := 'duties.owner_link_duty';
  v_errors jsonb;
  v_cell uuid;
  v_slot_id uuid;
  v_actor record;
  v_ref jsonb;
  v_target record;
  v_occ app.duties_occurrences;
  v_link uuid;
begin
  if jsonb_typeof(p_input) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"input": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_input, array['source_type', 'source_id',
                'source_revision', 'cell_id', 'position_key', 'slot_id'])
              || app.duties_owner_ref_errors(p_input, true)
              || jsonb_strip_nulls(jsonb_build_object('position_key',
                   app.duties_position_key_error(p_input -> 'position_key')));
  select t.errors, t.value into v_errors, v_cell from app.duties_uuid(p_input, 'cell_id', v_errors) t;
  select t.errors, t.value into v_errors, v_slot_id from app.duties_uuid(p_input, 'slot_id', v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select s.* into v_actor from app.duties_owner_session(v_cell) s;
  v_ref := app.duties_owner_source(p_input, 'cell_part');
  select o.occurrence_id, o.department_id, o.series_id into v_target
    from app.duties_slots s join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where s.slot_id = v_slot_id;
  if v_target.occurrence_id is null or v_target.department_id is null then
    perform app.cmd_fail('not_found');
  end if;
  -- The department's order (AD-2): department, series, occurrence and the position, FOR SHARE.
  perform 1 from app.duties_departments d
   where d.department_id = v_target.department_id and d.department_state = 'active' for share;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_target.series_id is not null then
    perform 1 from app.duties_series r where r.series_id = v_target.series_id for share;
  end if;
  select o.* into v_occ from app.duties_occurrences o
   where o.occurrence_id = v_target.occurrence_id for share;
  perform 1 from app.duties_slots s where s.slot_id = v_slot_id and s.cancelled_at is null for share;
  if not found or v_occ.occurrence_state <> 'published' or v_occ.department_id is null
     or app.duties_occurrence_start(v_occ) <= now() then
    perform app.cmd_fail('not_found');
  end if;
  -- Race-safe: a concurrent link of the same part position waits on the unique index, then is
  -- refused cleanly.
  insert into app.duties_part_links (source_type, source_id, position_key, link_kind, cell_id,
                                     occurrence_id, slot_id, source_revision, linked_by_member,
                                     linked_by_account)
  values (v_ref ->> 'source_type', (v_ref ->> 'source_id')::uuid, p_input ->> 'position_key',
          'linked', v_cell, v_occ.occurrence_id, v_slot_id,
          (v_ref ->> 'source_revision')::numeric::bigint, v_actor.member_id, v_actor.account_id)
  on conflict (source_type, source_id, position_key) where ended_at is null do nothing
  returning link_id into v_link;
  if v_link is null then
    perform app.cmd_fail('conflict', '{"position_key": "linked"}');
  end if;
  perform app.duties_audit_series_event('duty_linked', v_actor.member_id, v_actor.account_id,
                                        v_actor.capacity, v_cmd, v_occ.department_id,
                                        v_occ.series_id, v_occ.occurrence_id, null, null, null,
                                        v_occ.revision);
  return jsonb_build_object('link_id', v_link, 'kind', 'linked',
                            'position_key', p_input ->> 'position_key', 'slot_id', v_slot_id,
                            'occurrence_id', v_occ.occurrence_id,
                            'occurrence_revision', v_occ.revision);
end;
$$;

comment on function app.duties_owner_link_duty(jsonb) is
  'Story 4.11 owner operation (not client-executable): display-link a part position to a '
  'published department-owned position that has not started. Never clones or changes the duty; '
  'its department keeps sole authority.';

-- Unlink input: {source_type, source_id, source_revision, cell_id, position_key}.
create function app.duties_owner_unlink(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_cmd constant text := 'duties.owner_unlink';
  v_errors jsonb;
  v_cell uuid;
  v_actor record;
  v_ref jsonb;
  v_link app.duties_part_links;
begin
  if jsonb_typeof(p_input) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"input": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_input, array['source_type', 'source_id',
                'source_revision', 'cell_id', 'position_key'])
              || app.duties_owner_ref_errors(p_input, true)
              || jsonb_strip_nulls(jsonb_build_object('position_key',
                   app.duties_position_key_error(p_input -> 'position_key')));
  select t.errors, t.value into v_errors, v_cell from app.duties_uuid(p_input, 'cell_id', v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select s.* into v_actor from app.duties_owner_session(v_cell) s;
  v_ref := app.duties_owner_source(p_input, 'cell_part');
  select l.* into v_link from app.duties_part_links l
   where l.source_type = v_ref ->> 'source_type' and l.source_id = (v_ref ->> 'source_id')::uuid
     and l.position_key = p_input ->> 'position_key' and l.ended_at is null
     for update;
  if v_link.link_id is null or v_link.cell_id is distinct from v_cell then
    perform app.cmd_fail('not_found');
  end if;
  if v_link.link_kind = 'owned' then
    perform app.cmd_fail('validation_failed', '{"position_key": "owned"}');
  end if;
  update app.duties_part_links l
     set ended_at = now(), ended_by_member = v_actor.member_id, ended_by_account = v_actor.account_id
   where l.link_id = v_link.link_id;
  perform app.duties_audit_series_event('duty_unlinked', v_actor.member_id, v_actor.account_id,
                                        v_actor.capacity, v_cmd, null, null, v_link.occurrence_id,
                                        null, null, null, null);
  return jsonb_build_object('link_id', v_link.link_id, 'ended', true);
end;
$$;

comment on function app.duties_owner_unlink(jsonb) is
  'Story 4.11 owner operation (not client-executable): end a part position''s display link to a '
  'department duty (nothing of the duty changes).';


-- ---------------------------------------------------------------------------------------------
-- Owner operation: flag an owner-review mismatch
-- ---------------------------------------------------------------------------------------------
--
-- Input: {source_type, source_id, source_revision, cell_id (cell_part sources), changed: [codes]}.
-- A cell_part source flags the department duties its positions display-link; an event source
-- flags the published department duties whose event_ref is the event. Only duties that are
-- published and have not started. The duty, its answers, revisions and reminders do not change
-- (the department's leader reviews it); a second flag merges into the open one.
create function app.duties_owner_flag_review(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_cmd constant text := 'duties.owner_flag_review';
  v_errors jsonb;
  v_cell uuid;
  v_role text;
  v_changed text[];
  v_actor record;
  v_ref jsonb;
  v_source_type text;
  v_source_id uuid;
  v_revision bigint;
  v_targets uuid[];
  v_flags integer := 0;
  v_occ uuid;
  v_flag record;
begin
  if jsonb_typeof(p_input) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"input": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_input, array['source_type', 'source_id',
                'source_revision', 'cell_id', 'changed'])
              || app.duties_owner_ref_errors(p_input, true);
  if jsonb_typeof(p_input -> 'changed') is distinct from 'array'
     or exists (select 1 from jsonb_array_elements(p_input -> 'changed') e
                 where jsonb_typeof(e) <> 'string') then
    v_errors := v_errors || jsonb_build_object('changed',
                  case when coalesce(jsonb_typeof(p_input -> 'changed'), 'null') = 'null'
                       then 'required' else 'invalid' end);
  else
    select array_agg(distinct e #>> '{}' order by e #>> '{}') into v_changed
      from jsonb_array_elements(p_input -> 'changed') e;
    if not app.duties_review_fields_ok(v_changed) then
      v_errors := v_errors || '{"changed": "invalid"}';
    end if;
  end if;
  select s.role into v_role from app.duties_link_sources s
   where s.source_type = p_input ->> 'source_type';
  if v_role = 'cell_part' or p_input ? 'cell_id' then
    select t.errors, t.value into v_errors, v_cell from app.duties_uuid(p_input, 'cell_id', v_errors) t;
  end if;
  if v_role = 'event' and p_input ? 'cell_id' then
    v_errors := v_errors || '{"cell_id": "must_be_null"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  if v_role is null then
    perform app.cmd_fail('validation_failed', '{"source_type": "unregistered"}');
  end if;
  -- A cell's change is flagged by that cell's leader or assistant; an event's by any member with
  -- live access (Content authorises its own editors before calling).
  select s.* into v_actor from app.duties_owner_session(v_cell) s;
  v_ref := app.duties_owner_source(p_input, v_role);
  v_source_type := v_ref ->> 'source_type';
  v_source_id := (v_ref ->> 'source_id')::uuid;
  v_revision := (v_ref ->> 'source_revision')::numeric::bigint;
  if v_role = 'cell_part' then
    select coalesce(array_agg(distinct l.occurrence_id), '{}') into v_targets
      from app.duties_part_links l
     where l.source_type = v_source_type and l.source_id = v_source_id and l.link_kind = 'linked'
       and l.ended_at is null and l.cell_id = v_cell;
  else
    select coalesce(array_agg(o.occurrence_id), '{}') into v_targets
      from app.duties_occurrences o
     where o.event_ref = v_source_id and o.department_id is not null;
  end if;
  -- AD-2: the departments, then the occurrences (series date order), FOR SHARE; nothing of the
  -- duties is written.
  perform 1 from app.duties_departments d
   where d.department_id in (select o.department_id from app.duties_occurrences o
                              where o.occurrence_id = any (v_targets))
   order by d.department_id for share;
  for v_occ in select o.occurrence_id from app.duties_occurrences o
                where o.occurrence_id = any (v_targets)
                order by o.series_id nulls last, o.series_date nulls last, o.starts_at, o.occurrence_id
                  for share loop
    continue when not exists (select 1 from app.duties_occurrences o
                               where o.occurrence_id = v_occ and o.occurrence_state = 'published'
                                 and app.duties_occurrence_start(o) > now());
    insert into app.duties_review_flags as f (occurrence_id, source_type, source_id,
                                              source_revision, changed, flagged_by_member,
                                              flagged_by_account)
    values (v_occ, v_source_type, v_source_id, v_revision, v_changed, v_actor.member_id,
            v_actor.account_id)
    on conflict (occurrence_id, source_type, source_id) where cleared_at is null do update
       set changed = (select array_agg(distinct x order by x)
                        from unnest(f.changed || excluded.changed) x),
           source_revision = greatest(f.source_revision, excluded.source_revision),
           revision = f.revision + 1, updated_at = now()
    returning f.flag_id, f.revision into v_flag;
    v_flags := v_flags + 1;
    perform app.duties_audit_series_event('review_flagged', v_actor.member_id, v_actor.account_id,
                                          case when v_role = 'cell_part' then v_actor.capacity
                                               else 'member' end,
                                          v_cmd,
                                          (select o.department_id from app.duties_occurrences o
                                            where o.occurrence_id = v_occ),
                                          null, v_occ, null, null, null, v_flag.revision);
  end loop;
  return jsonb_build_object('flagged', v_flags);
end;
$$;

comment on function app.duties_owner_flag_review(jsonb) is
  'Story 4.11 owner operation (not client-executable): a linked meeting (cell_part) or event '
  'changed; flag the published department duties it is linked to for their department''s '
  'review. Never reschedules, republishes or resets answers.';


-- ---------------------------------------------------------------------------------------------
-- Owner reads (called inside the caller's authorised read; not client-executable)
-- ---------------------------------------------------------------------------------------------

-- The part as its cell's leader or assistant sees it: {source_type, source_id, cell_id}.
create function app.duties_owner_part(p_input jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_cell uuid;
  v_actor record;
  v_occ app.duties_occurrences;
begin
  if jsonb_typeof(p_input) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"input": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_input, array['source_type', 'source_id',
                'source_revision', 'cell_id'])
              || app.duties_owner_ref_errors(p_input, false);
  select t.errors, t.value into v_errors, v_cell from app.duties_uuid(p_input, 'cell_id', v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select s.* into v_actor from app.duties_owner_session(v_cell) s;
  if not exists (select 1 from app.duties_link_sources s
                  where s.source_type = p_input ->> 'source_type' and s.role = 'cell_part') then
    perform app.cmd_fail('validation_failed', '{"source_type": "unregistered"}');
  end if;
  select o.* into v_occ from app.duties_occurrences o
   where o.occurrence_id = (select l.occurrence_id from app.duties_part_links l
                             where l.source_type = p_input ->> 'source_type'
                               and l.source_id = (p_input ->> 'source_id')::uuid
                               and l.link_kind = 'owned' limit 1);
  if v_occ.occurrence_id is not null and v_occ.cell_id is distinct from v_cell then
    perform app.cmd_fail('not_found');
  end if;
  if exists (select 1 from app.duties_part_links l
              where l.source_type = p_input ->> 'source_type'
                and l.source_id = (p_input ->> 'source_id')::uuid
                and l.ended_at is null and l.cell_id is distinct from v_cell) then
    perform app.cmd_fail('not_found');
  end if;
  return jsonb_build_object(
    'occurrence', case when v_occ.occurrence_id is not null then jsonb_build_object(
                    'occurrence_id', v_occ.occurrence_id, 'revision', v_occ.revision,
                    'state', v_occ.occurrence_state, 'cell_id', v_occ.cell_id,
                    'duty_name', v_occ.duty_name, 'starts_at', app.cmd_utc(v_occ.starts_at),
                    'ends_at', case when v_occ.ends_at is not null then app.cmd_utc(v_occ.ends_at) end,
                    'reporting_at', case when v_occ.reporting_at is not null
                                         then app.cmd_utc(v_occ.reporting_at) end,
                    'location', v_occ.location, 'instructions', v_occ.instructions,
                    'topic', v_occ.topic, 'scripture', v_occ.scripture,
                    'event_ref', v_occ.event_ref,
                    'started', app.duties_occurrence_start(v_occ) <= now()) end,
    'positions', app.duties_owner_positions_json(p_input ->> 'source_type',
                                                 (p_input ->> 'source_id')::uuid));
end;
$$;

comment on function app.duties_owner_part(jsonb) is
  'Story 4.11 owner read (not client-executable): a part''s cell-owned occurrence and positions '
  'for its cell''s leader or assistant (responses and flags; no notes or reasons; display links '
  'show no people).';

-- Conflicts of one member over a time range, for a cell's leader or assistant planning a part:
-- {cell_id, member_id, starts_at, ends_at?, reporting_at?, slot_id? (excluded)}. The 4.4 rules:
-- the viewer's own cell's parts and departments they manage in full, every other conflict as a
-- busy time only, never instructions.
create function app.duties_owner_conflicts(p_input jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_cell uuid;
  v_member uuid;
  v_starts timestamptz;
  v_ends timestamptz;
  v_reporting timestamptz;
  v_slot uuid;
  v_actor record;
begin
  if jsonb_typeof(p_input) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"input": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_input, array['cell_id', 'member_id', 'starts_at',
                'ends_at', 'reporting_at', 'slot_id']);
  select t.errors, t.value into v_errors, v_cell from app.duties_uuid(p_input, 'cell_id', v_errors) t;
  select t.errors, t.value into v_errors, v_member from app.duties_uuid(p_input, 'member_id', v_errors) t;
  select t.errors, t.value into v_errors, v_starts
    from app.duties_instant(p_input, 'starts_at', true, v_errors) t;
  select t.errors, t.value into v_errors, v_ends
    from app.duties_instant(p_input, 'ends_at', false, v_errors) t;
  select t.errors, t.value into v_errors, v_reporting
    from app.duties_instant(p_input, 'reporting_at', false, v_errors) t;
  if coalesce(jsonb_typeof(p_input -> 'slot_id'), 'null') <> 'null' then
    select t.errors, t.value into v_errors, v_slot from app.duties_uuid(p_input, 'slot_id', v_errors) t;
  end if;
  if v_errors = '{}'::jsonb and v_ends is not null and v_ends <= v_starts then
    v_errors := '{"ends_at": "before_start"}';
  end if;
  if v_errors = '{}'::jsonb and v_reporting is not null and v_reporting > v_starts then
    v_errors := '{"reporting_at": "after_start"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select s.* into v_actor from app.duties_owner_session(v_cell) s;
  return app.duties_conflicts_json(v_actor.member_id, v_member,
                                   app.duties_busy_range_of(v_starts, v_ends, v_reporting),
                                   v_slot, null, null);
end;
$$;

comment on function app.duties_owner_conflicts(jsonb) is
  'Story 4.11 owner read (not client-executable): one member''s conflicting duties over a time '
  'range for a cell''s leader or assistant, with the 4.4 disclosure rules.';

-- The duties that name an event (the linked-event reference): {source_type, source_id} of a
-- registered event source. Ids, departments, revisions, states and whether a review is open;
-- no names, people or text. At most 200.
create function app.duties_owner_event_links(p_input jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_actor record;
  v_result jsonb;
begin
  if jsonb_typeof(p_input) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"input": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_input, array['source_type', 'source_id', 'source_revision'])
              || app.duties_owner_ref_errors(p_input, false);
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select s.* into v_actor from app.duties_owner_session(null) s;
  if not exists (select 1 from app.duties_link_sources s
                  where s.source_type = p_input ->> 'source_type' and s.role = 'event') then
    perform app.cmd_fail('validation_failed', '{"source_type": "unregistered"}');
  end if;
  with linked as (
    select o.* from app.duties_occurrences o
     where o.event_ref = (p_input ->> 'source_id')::uuid and o.department_id is not null
       and o.occurrence_state <> 'draft'
  ), firsts as (
    select l.* from linked l order by l.starts_at, l.occurrence_id limit 200
  )
  select jsonb_build_object(
           'duties', coalesce((select jsonb_agg(jsonb_build_object(
                        'occurrence_id', f.occurrence_id, 'department_id', f.department_id,
                        'revision', f.revision, 'state', f.occurrence_state,
                        'starts_at', app.cmd_utc(f.starts_at),
                        'review_open', exists (
                          select 1 from app.duties_review_flags r
                           where r.occurrence_id = f.occurrence_id and r.cleared_at is null
                             and r.source_type = p_input ->> 'source_type'
                             and r.source_id = (p_input ->> 'source_id')::uuid))
                      order by f.starts_at, f.occurrence_id) from firsts f), '[]'::jsonb),
           'truncated', (select count(*) from linked) > 200)
    into v_result;
  return v_result;
end;
$$;

comment on function app.duties_owner_event_links(jsonb) is
  'Story 4.11 owner read (not client-executable): the published department duties that name an '
  'event (event_ref), with open-review state; ids and states only.';

-- The sermon-draft read: {occurrence_id}. The occurrence's duty, times, topic and scripture for
-- its current assignee (pending or accepted) or for whoever manages it (the department's leader,
-- deputy or Admin; the cell's leader or assistant). Anything else is not_found. The media team
-- reviews the draft on the Content side before anything is published.
create function app.duties_owner_topic(p_input jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_occurrence_id uuid;
  v_actor record;
  v_occ app.duties_occurrences;
  v_position text;
  v_assigned boolean;
begin
  if jsonb_typeof(p_input) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"input": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_input, array['occurrence_id']);
  select t.errors, t.value into v_errors, v_occurrence_id
    from app.duties_uuid(p_input, 'occurrence_id', v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select s.* into v_actor from app.duties_owner_session(null) s;
  select o.* into v_occ from app.duties_occurrences o where o.occurrence_id = v_occurrence_id;
  if v_occ.occurrence_id is null or v_occ.occurrence_state <> 'published' then
    perform app.cmd_fail('not_found');
  end if;
  select s.position_name, true into v_position, v_assigned
    from app.duties_slots s join app.duties_assignments a on a.slot_id = s.slot_id
   where s.occurrence_id = v_occ.occurrence_id and s.cancelled_at is null
     and a.assignment_state = 'current' and a.response in ('pending', 'accepted')
     and a.member_id = v_actor.member_id
   order by s.position_no limit 1;
  if not coalesce(v_assigned, false)
     and not (v_occ.department_id is not null
              and app.duties_manage_capacity(v_actor.member_id, v_occ.department_id) is not null)
     and not (v_occ.cell_id is not null
              and (app.identity_member_has_scope(v_actor.member_id, 'cell_leader', v_occ.cell_id)
                   or app.identity_member_has_scope(v_actor.member_id, 'cell_assistant', v_occ.cell_id))) then
    perform app.cmd_fail('not_found');
  end if;
  return jsonb_build_object(
    'occurrence_id', v_occ.occurrence_id, 'revision', v_occ.revision,
    'owner_kind', case when v_occ.cell_id is null then 'department' else 'cell' end,
    'department_id', v_occ.department_id, 'cell_id', v_occ.cell_id,
    'duty_name', v_occ.duty_name, 'position_name', v_position,
    'starts_at', app.cmd_utc(v_occ.starts_at), 'topic', v_occ.topic,
    'scripture', v_occ.scripture, 'event_ref', v_occ.event_ref,
    'assigned', coalesce(v_assigned, false));
end;
$$;

comment on function app.duties_owner_topic(jsonb) is
  'Story 4.11 owner read (not client-executable): the sermon-draft topic/scripture reference of '
  'a published duty, for its current assignee or its managers.';


-- ---------------------------------------------------------------------------------------------
-- Client command: duties.clear_review (the department reviews a mismatch)
-- ---------------------------------------------------------------------------------------------
--
-- Payload {flag_id}; expected_revision = the flag's revision; keyed to the occurrence aggregate
-- (a replay rechecks that the actor still manages the department). The department's leader,
-- deputy or Admin; anyone else forbidden. Nothing of the duty changes.
create function app.duties_clear_review(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_flag_id uuid;
  v_occurrence uuid;
  v_department uuid;
  v_series uuid;
  v_capacity text;
  v_flag app.duties_review_flags;
  v_revision bigint;
  v_cmd constant text := 'duties.clear_review';
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['flag_id']);
  select t.errors, t.value into v_errors, v_flag_id from app.duties_uuid(p_payload, 'flag_id', v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select f.occurrence_id into v_occurrence from app.duties_review_flags f where f.flag_id = v_flag_id;
  select o.department_id, o.series_id into v_department, v_series
    from app.duties_occurrences o where o.occurrence_id = v_occurrence;
  if v_occurrence is null or v_department is null then
    perform app.cmd_fail('not_found');
  end if;
  -- AD-2: department, series, occurrence FOR SHARE, then the flag.
  perform 1 from app.duties_departments d
   where d.department_id = v_department and d.department_state = 'active' for share;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  v_capacity := app.duties_manage_capacity(v_actor.member_id, v_department);
  if v_capacity is null then
    perform app.cmd_fail('forbidden');
  end if;
  if v_series is not null then
    perform 1 from app.duties_series r where r.series_id = v_series for share;
  end if;
  perform 1 from app.duties_occurrences o where o.occurrence_id = v_occurrence for share;
  select f.* into v_flag from app.duties_review_flags f where f.flag_id = v_flag_id for update;
  if v_flag.cleared_at is not null then
    perform app.cmd_fail('conflict', '{"flag_id": "cleared"}', v_flag.revision);
  end if;
  if v_flag.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_flag.revision);
  end if;
  update app.duties_review_flags f
     set cleared_at = now(), cleared_by_member = v_actor.member_id,
         cleared_by_account = v_actor.account_id, revision = f.revision + 1, updated_at = now()
   where f.flag_id = v_flag_id
  returning f.revision into v_revision;
  perform app.duties_audit_series_event('review_cleared', v_actor.member_id, v_actor.account_id,
                                        v_capacity, v_cmd, v_department, v_series, v_occurrence,
                                        null, null, null, v_revision);
  return jsonb_build_object(
    'aggregate_type', 'duties_occurrence', 'aggregate_id', v_occurrence, 'revision', v_revision,
    'data', jsonb_build_object('flag_id', v_flag_id, 'occurrence_id', v_occurrence,
                               'revision', v_revision, 'cleared', true));
end;
$$;

comment on function app.duties_clear_review(uuid, bigint, jsonb) is
  'Story 4.11 command duties.clear_review: the department''s leader, deputy or Admin marks an '
  'owner-review mismatch reviewed (expected = the flag revision). Nothing of the duty changes.';

-- The open owner-review flags of an occurrence (codes only), for the department's reads.
create function app.duties_review_json(p_occurrence_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'flag_id', f.flag_id,
           'revision', f.revision,
           'source', s.role,
           'changed', to_jsonb(f.changed),
           'flagged_at', app.cmd_utc(f.flagged_at),
           'updated_at', app.cmd_utc(f.updated_at))
         order by f.flagged_at, f.flag_id), '[]'::jsonb)
    from app.duties_review_flags f
    join app.duties_link_sources s on s.source_type = f.source_type
   where f.occurrence_id = p_occurrence_id and f.cleared_at is null;
$$;

-- How many programme parts display-link the occurrence's positions now.
create function app.duties_linked_parts(p_occurrence_id uuid)
returns integer
language sql
stable
set search_path = ''
as $$
  select count(distinct (l.source_type, l.source_id))::integer
    from app.duties_part_links l
   where l.occurrence_id = p_occurrence_id and l.link_kind = 'linked' and l.ended_at is null;
$$;


-- ---------------------------------------------------------------------------------------------
-- Replaced bodies (each copied from its latest version; changes marked "Story 4.11")
-- ---------------------------------------------------------------------------------------------

-- (Replaced, story 4.11; copied from 20261015002121_duties_outcomes.sql.)
create or replace function app.duties_authorize_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  if coalesce(p_request ->> 'command', '') not in (
       'duties.create_department', 'duties.add_member', 'duties.publish_duty', 'duties.respond',
       'duties.revise_duty', 'duties.create_series', 'duties.assign_slot', 'duties.publish_drafts',
       'duties.revise_series', 'duties.cancel_occurrence', 'duties.cancel_series',
       'duties.withdraw_acceptance', 'duties.accept_many', 'duties.set_reminders',
       'duties.record_contact_attempt', 'duties.confirm_by_leader', 'duties.cancel_position',
       -- Story 4.10.
       'duties.record_outcome', 'duties.correct_outcome',
       -- Story 4.11: the department reviews an owner-review mismatch.
       'duties.clear_review') then
    return false;
  end if;
  select e.* into r from app.identity_evaluate_grant(null, null, null) e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  if r.outcome <> 'granted' then
    return false;
  end if;
  perform 1 from app.identity_grants g
   where g.member_id = r.member_id and g.revoked_at is null
     and (g.role = 'admin' or g.scope_kind in ('department_leader', 'department_deputy'))
     for share;
  return true;
end;
$$;

-- (Replaced, story 4.11; copied from 20261015002121_duties_outcomes.sql.)
create or replace function app.duties_command(p_envelope jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_command text;
begin
  if jsonb_typeof(p_envelope) = 'object' and jsonb_typeof(p_envelope -> 'command') = 'string' then
    v_command := p_envelope ->> 'command';
  end if;
  return app.cmd_execute(
    p_envelope,
    case v_command
      when 'duties.create_department'
        then 'app.duties_create_department(uuid, bigint, jsonb)'::regprocedure
      when 'duties.add_member' then 'app.duties_add_member(uuid, bigint, jsonb)'::regprocedure
      when 'duties.publish_duty' then 'app.duties_publish_duty(uuid, bigint, jsonb)'::regprocedure
      when 'duties.respond' then 'app.duties_respond(uuid, bigint, jsonb)'::regprocedure
      when 'duties.revise_duty' then 'app.duties_revise_duty(uuid, bigint, jsonb)'::regprocedure
      -- Story 4.8: creating a series also takes the creator's reminders.
      when 'duties.create_series'
        then 'app.duties_create_series_with_reminders(uuid, bigint, jsonb)'::regprocedure
      when 'duties.assign_slot' then 'app.duties_assign_slot(uuid, bigint, jsonb)'::regprocedure
      when 'duties.publish_drafts' then 'app.duties_publish_drafts(uuid, bigint, jsonb)'::regprocedure
      when 'duties.revise_series' then 'app.duties_revise_series(uuid, bigint, jsonb)'::regprocedure
      when 'duties.cancel_occurrence'
        then 'app.duties_cancel_occurrence(uuid, bigint, jsonb)'::regprocedure
      when 'duties.cancel_series' then 'app.duties_cancel_series(uuid, bigint, jsonb)'::regprocedure
      when 'duties.withdraw_acceptance'
        then 'app.duties_withdraw_acceptance(uuid, bigint, jsonb)'::regprocedure
      when 'duties.accept_many' then 'app.duties_accept_many(uuid, bigint, jsonb)'::regprocedure
      when 'duties.set_reminders' then 'app.duties_set_reminders(uuid, bigint, jsonb)'::regprocedure
      -- Story 4.9: the coverage work (answers are keyed to the occurrence, so a replay rechecks
      -- that the actor still manages its department).
      when 'duties.record_contact_attempt'
        then 'app.duties_record_contact_attempt(uuid, bigint, jsonb)'::regprocedure
      when 'duties.confirm_by_leader'
        then 'app.duties_confirm_by_leader(uuid, bigint, jsonb)'::regprocedure
      when 'duties.cancel_position'
        then 'app.duties_cancel_position(uuid, bigint, jsonb)'::regprocedure
      -- Story 4.10: completion outcomes (keyed to the occurrence, as 4.9).
      when 'duties.record_outcome'
        then 'app.duties_record_outcome(uuid, bigint, jsonb)'::regprocedure
      when 'duties.correct_outcome'
        then 'app.duties_correct_outcome(uuid, bigint, jsonb)'::regprocedure
      -- Story 4.11: keyed to the occurrence (a replay rechecks that the actor still manages its
      -- department); expected = the flag revision.
      when 'duties.clear_review'
        then 'app.duties_clear_review(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.duties_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'duties.create_department'
      and v_command is distinct from 'duties.publish_duty'
      and v_command is distinct from 'duties.create_series'
      and v_command is distinct from 'duties.accept_many'
  );
end;
$$;

-- (Replaced, story 4.11; copied from 20261015002121_duties_outcomes.sql.)
create or replace function app.duties_my_assignment_json(p_assignment_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'assignment_id', a.assignment_id,
    'revision', a.revision,
    'occurrence_id', o.occurrence_id,
    'slot_id', a.slot_id,
    -- Story 4.11: a cell programme part (no department; the cell's leaders and assistants).
    'owner_kind', case when o.cell_id is not null then 'cell' else 'department' end,
    'department_id', d.department_id,
    'department_name', d.name,
    'cell_id', o.cell_id,
    'duty_name', o.duty_name,
    'position_name', s.position_name,
    'starts_at', app.cmd_utc(o.starts_at),
    'ends_at', case when o.ends_at is not null then app.cmd_utc(o.ends_at) end,
    'reporting_at', case when o.reporting_at is not null then app.cmd_utc(o.reporting_at) end,
    'location', o.location,
    'instructions', o.instructions,
    'topic', o.topic,
    'scripture', o.scripture,
    'response', a.response,
    'response_provenance', a.response_provenance,
    'confirmed_channel', a.confirmed_channel,
    'response_deadline', app.cmd_utc(a.response_deadline),
    'deadline_source', a.deadline_source,
    'short_notice', a.short_notice,
    'reminders', o.reminders,
    'responded_at', case when a.responded_at is not null then app.cmd_utc(a.responded_at) end,
    'prior_accepted_at', case when a.prior_accepted_at is not null
                              then app.cmd_utc(a.prior_accepted_at) end,
    'note', a.response_note,
    -- Story 4.10: the member's own completion outcome (with its note and corrections) once the
    -- duty has started on the current assignment; null while unrecorded.
    'outcome', case when a.assignment_state = 'current' and o.occurrence_state = 'published'
                    then app.duties_outcome_json(a.assignment_id, 20) end,
    'slot_revision', a.slot_revision,
    'changes', case when p.member_id = a.member_id
                    then to_jsonb(app.duties_changes_since(a.slot_id, a.slot_revision - 1, a.slot_revision)) end,
    'previous_response', case when p.member_id = a.member_id then p.response end,
    'previous_assignment_ids', app.duties_previous_assignment_ids(a.assignment_id),
    'notes_updated_at', (select app.cmd_utc(t.ts) from (
                           select app.duties_notes_updated_at(a.slot_id, a.slot_revision) as ts) t
                          where t.ts is not null),
    'leaders', coalesce((
      select jsonb_agg(jsonb_build_object(
               'display_name', m.display_name,
               'role', case g.scope_kind when 'department_leader' then 'leader'
                                         when 'cell_leader' then 'leader'
                                         when 'cell_assistant' then 'assistant'
                                         else 'deputy' end)
             order by (g.scope_kind in ('department_deputy', 'cell_assistant')),
                      m.display_name collate "C", g.member_id)
        from app.identity_grants g
        join app.identity_members m on m.member_id = g.member_id
       where g.revoked_at is null
         and ((o.department_id is not null and g.scope_id = o.department_id
               and g.scope_kind in ('department_leader', 'department_deputy'))
              or (o.cell_id is not null and g.scope_id = o.cell_id
                  and g.scope_kind in ('cell_leader', 'cell_assistant')))
         and m.membership_state = 'approved'
         and not exists (select 1 from app.identity_deletions dl where dl.member_id = m.member_id)),
      '[]'::jsonb))
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
    left join app.duties_departments d on d.department_id = o.department_id
    left join app.duties_assignments p on p.assignment_id = a.supersedes_assignment_id
   where a.assignment_id = p_assignment_id;
$$;

-- (Replaced, story 4.11; copied from 20261015002121_duties_outcomes.sql.)
create or replace function app.duties_deletion_remaining(p_member_id uuid, p_account_id uuid)
returns integer
language sql
stable
set search_path = ''
as $$
  select ((select count(*) from app.duties_department_members dm
            where dm.member_id = p_member_id or dm.added_by_member = p_member_id
               or dm.added_by_account = p_account_id)
        + (select count(*) from app.duties_assignments a
            where a.member_id = p_member_id or a.responded_by_member = p_member_id
               or a.assigned_by_member = p_member_id or a.responded_by_account = p_account_id
               or a.assigned_by_account = p_account_id or a.override_by_member = p_member_id
               or a.override_by_account = p_account_id)
        + (select count(*) from app.duties_occurrences o
            where o.created_by_member = p_member_id or o.created_by_account = p_account_id)
        + (select count(*) from app.duties_departments d
            where d.created_by_member = p_member_id or d.created_by_account = p_account_id)
        + (select count(*) from app.duties_series r
            where r.created_by_member = p_member_id or r.created_by_account = p_account_id)
        + (select count(*) from app.duties_slots s
            where s.draft_member_id = p_member_id or s.draft_override_by_member = p_member_id
               or s.draft_override_by_account = p_account_id
               or s.cancelled_by_member = p_member_id or s.cancelled_by_account = p_account_id)
        + (select count(*) from app.duties_slot_revisions r
            where r.member_id = p_member_id or r.created_by_member = p_member_id
               or r.created_by_account = p_account_id)
        + (select count(*) from app.duties_audit au
            where au.actor_member_id = p_member_id or au.member_id = p_member_id
               or au.actor_account_id = p_account_id)
        -- Story 4.9.
        + (select count(*) from app.duties_coverage_cases c
            where c.opened_by_member = p_member_id or c.opened_by_account = p_account_id)
        + (select count(*) from app.duties_contact_attempts t
            where t.recorded_by_member = p_member_id or t.recorded_by_account = p_account_id)
        -- Story 4.10: outcomes they recorded, and text about their own duties.
        + (select count(*) from app.duties_outcomes x
            where x.recorded_by_member = p_member_id or x.recorded_by_account = p_account_id)
        + (select count(*) from app.duties_outcomes x
             join app.duties_assignments a on a.assignment_id = x.assignment_id
            where a.member_id = p_member_id
              and (x.note is not null or x.correction_reason is not null))
        -- Story 4.11: links they made or ended, and owner-review flags they raised or cleared.
        + (select count(*) from app.duties_part_links l
            where l.linked_by_member = p_member_id or l.linked_by_account = p_account_id
               or l.ended_by_member = p_member_id or l.ended_by_account = p_account_id)
        + (select count(*) from app.duties_review_flags f
            where f.flagged_by_member = p_member_id or f.flagged_by_account = p_account_id
               or f.cleared_by_member = p_member_id or f.cleared_by_account = p_account_id))::integer;
$$;

-- (Replaced, story 4.11; copied from 20261014212507_duties_coverage.sql.)
create or replace function app.duties_respond(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_assignment_id uuid;
  v_note text;
  v_assignment app.duties_assignments;
  v_occurrence app.duties_occurrences;
  v_revision bigint;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['assignment_id', 'response', 'note']);
  select t.errors, t.value into v_errors, v_assignment_id
    from app.duties_uuid(p_payload, 'assignment_id', v_errors) t;
  if jsonb_typeof(p_payload -> 'response') is distinct from 'string' then
    v_errors := v_errors || jsonb_build_object('response',
                  case when p_payload ? 'response' then 'invalid' else 'required' end);
  elsif p_payload ->> 'response' not in ('accepted', 'declined') then
    v_errors := v_errors || '{"response": "invalid"}';
  end if;
  select t.errors, t.value into v_errors, v_note
    from app.duties_text(p_payload, 'note', false, 280, true, v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  select a.* into v_assignment from app.duties_assignments a
   where a.assignment_id = v_assignment_id for update;
  -- Someone else's assignment is not found (no disclosure).
  if not found or v_assignment.member_id <> v_actor.member_id then
    perform app.cmd_fail('not_found');
  end if;
  -- Story 4.11: a cell programme part is answered like a department duty (the 4.5 refusal of
  -- cell-owned assignments ends here).
  v_occurrence := app.duties_assignment_occurrence(v_assignment.slot_id);
  perform app.duties_refuse_ended(v_assignment, v_actor.member_id);
  if v_assignment.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_assignment.revision);
  end if;
  if v_assignment.response <> 'pending' then
    perform app.cmd_fail('conflict', '{"assignment_id": "responded"}', v_assignment.revision);
  end if;
  if app.duties_occurrence_start(v_occurrence) <= now() then
    perform app.cmd_fail('validation_failed', '{"assignment_id": "started"}');
  end if;
  update app.duties_assignments a
     set response = p_payload ->> 'response', responded_at = now(),
         responded_by_member = v_actor.member_id, responded_by_account = v_actor.account_id,
         response_provenance = 'member', response_note = v_note, revision = a.revision + 1
   where a.assignment_id = v_assignment.assignment_id
  returning a.revision into v_revision;
  perform app.duties_audit_event('response_recorded', v_actor.member_id, v_actor.account_id,
                                 'member', 'duties.respond', v_occurrence.department_id,
                                 v_occurrence.occurrence_id, v_assignment.assignment_id,
                                 v_assignment.member_id, p_payload ->> 'response', v_revision);
  -- Story 4.9: an acceptance resolves the coverage case (Follow-ups, before Notifications); a
  -- decline keeps it open (the position still needs cover).
  if p_payload ->> 'response' = 'accepted' then
    perform app.duties_close_cases(array[v_assignment.assignment_id], 'accepted', v_actor.member_id,
                                   v_actor.account_id, 'member', 'duties.respond');
  end if;
  perform app.notifications_cancel(jsonb_build_object(
    'source_type', 'duties_assignment', 'source_id', v_assignment.assignment_id,
    'reason', 'responded'));
  -- Story 4.8: the leaders' alert stops; an acceptance keeps its pre-service reminders.
  -- Story 4.9: a decline alerts the leaders.
  perform app.duties_after_answer(v_assignment.assignment_id, v_actor.member_id, v_actor.account_id,
                                  'duties.respond');
  return jsonb_build_object(
    'aggregate_type', 'duties_assignment', 'aggregate_id', v_assignment.assignment_id,
    'revision', v_revision,
    -- Ids and states only (the note stays out of the receipt); clients read My duties again.
    'data', jsonb_build_object('assignment_id', v_assignment.assignment_id, 'revision', v_revision,
                               'response', p_payload ->> 'response'));
end;
$$;

-- (Replaced, story 4.11; copied from 20261014212507_duties_coverage.sql.)
create or replace function app.duties_accept_many(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_items jsonb := p_payload -> 'assignments';
  v_item jsonb;
  v_ids uuid[] := '{}';
  v_revs jsonb := '{}';
  v_found integer;
  v_row record;
  v_problems jsonb := '{}';
  v_code text;
  v_first uuid;
  v_first_revision bigint;
  v_done jsonb := '[]';
  v_revision bigint;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['assignments']);
  if jsonb_typeof(v_items) is distinct from 'array' then
    v_errors := v_errors || jsonb_build_object('assignments',
                  case when p_payload ? 'assignments' then 'invalid' else 'required' end);
  elsif jsonb_array_length(v_items) = 0 then
    v_errors := v_errors || '{"assignments": "required"}';
  elsif jsonb_array_length(v_items) > 50 then
    v_errors := v_errors || '{"assignments": "too_many"}';
  else
    for v_item in select x from jsonb_array_elements(v_items) x loop
      -- Checked one step at a time (SQL does not promise the order of OR operands).
      v_code := null;
      if jsonb_typeof(v_item) is distinct from 'object' then
        v_code := 'invalid';
      elsif app.contract_unknown_keys(v_item, array['assignment_id', 'revision']) <> '{}'::jsonb
            or app.contract_uuid_error(v_item -> 'assignment_id') is not null
            or jsonb_typeof(v_item -> 'revision') is distinct from 'number' then
        v_code := 'invalid';
      elsif (v_item ->> 'revision')::numeric <> trunc((v_item ->> 'revision')::numeric)
            or (v_item ->> 'revision')::numeric not between 1 and 9007199254740991 then
        v_code := 'invalid';
      end if;
      if v_code is not null then
        v_errors := v_errors || '{"assignments": "invalid"}';
        exit;
      end if;
      if (v_item ->> 'assignment_id')::uuid = any(v_ids) then
        v_errors := v_errors || '{"assignments": "duplicate"}';
        exit;
      end if;
      v_ids := v_ids || (v_item ->> 'assignment_id')::uuid;
      v_revs := v_revs || jsonb_build_object(v_item ->> 'assignment_id',
                                             (v_item ->> 'revision')::numeric::bigint);
    end loop;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  -- Every item must be the member's own assignment; anything else is not found, without saying
  -- which (no disclosure). Story 4.11: cell programme parts are included.
  select count(*) into v_found
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where a.assignment_id = any(v_ids) and a.member_id = v_actor.member_id;
  if v_found <> cardinality(v_ids) then
    perform app.cmd_fail('not_found');
  end if;
  -- AD-2: occurrences FOR SHARE, then the assignments FOR UPDATE, in one order: series, then
  -- series date (the order duties.revise_series and duties.cancel_series lock a series' dates
  -- in, which differs from start order once one date was moved by duties.revise_duty), then
  -- start and id. One-off duties (no series) come after every series date.
  perform 1 from app.duties_occurrences o
   where o.occurrence_id in (select s.occurrence_id from app.duties_assignments a
                               join app.duties_slots s on s.slot_id = a.slot_id
                              where a.assignment_id = any(v_ids))
   order by o.series_id nulls last, o.series_date nulls last, o.starts_at, o.occurrence_id
     for share;
  perform 1 from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where a.assignment_id = any(v_ids)
   order by o.series_id nulls last, o.series_date nulls last, o.starts_at, o.occurrence_id,
            s.position_no, a.assignment_id
     for update of a;
  for v_row in
    select a.*, o.occurrence_id as occ_id, o.department_id as dept_id,
           app.duties_occurrence_start(o) as start_at
      from app.duties_assignments a
      join app.duties_slots s on s.slot_id = a.slot_id
      join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
     where a.assignment_id = any(v_ids)
     order by o.series_id nulls last, o.series_date nulls last, o.starts_at, o.occurrence_id,
              s.position_no, a.assignment_id
  loop
    if v_row.member_id is distinct from v_actor.member_id then
      perform app.cmd_fail('not_found');
    end if;
    v_code := case
      when v_row.assignment_state = 'superseded' then 'superseded'
      when v_row.assignment_state <> 'current' then 'cancelled'
      when v_row.response <> 'pending' then 'responded'
      when v_row.revision is distinct from (v_revs ->> v_row.assignment_id::text)::bigint then 'stale'
      when v_row.start_at <= now() then 'started'
    end;
    if v_code is not null then
      v_problems := v_problems || jsonb_build_object('assignment:' || v_row.assignment_id, v_code);
    end if;
  end loop;
  if v_problems <> '{}'::jsonb then
    perform app.cmd_fail('conflict', '{"assignments": "changed"}'::jsonb || v_problems);
  end if;
  for v_row in
    select a.assignment_id, a.member_id, o.occurrence_id as occ_id, o.department_id as dept_id
      from app.duties_assignments a
      join app.duties_slots s on s.slot_id = a.slot_id
      join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
     where a.assignment_id = any(v_ids)
     order by o.series_id nulls last, o.series_date nulls last, o.starts_at, o.occurrence_id,
              s.position_no, a.assignment_id
  loop
    update app.duties_assignments a
       set response = 'accepted', responded_at = now(),
           responded_by_member = v_actor.member_id, responded_by_account = v_actor.account_id,
           response_provenance = 'member', response_note = null, revision = a.revision + 1
     where a.assignment_id = v_row.assignment_id
    returning a.revision into v_revision;
    perform app.duties_audit_event('response_recorded', v_actor.member_id, v_actor.account_id,
                                   'member', 'duties.accept_many', v_row.dept_id, v_row.occ_id,
                                   v_row.assignment_id, v_row.member_id, 'accepted', v_revision);
    if v_first is null then
      v_first := v_row.assignment_id;
      v_first_revision := v_revision;
    end if;
    v_done := v_done || jsonb_build_array(jsonb_build_object('assignment_id', v_row.assignment_id,
                                                             'revision', v_revision));
  end loop;
  -- Story 4.9: the accepted dates' coverage cases close (Follow-ups, before Notifications).
  perform app.duties_close_cases(v_ids, 'accepted', v_actor.member_id, v_actor.account_id, 'member',
                                 'duties.accept_many');
  -- Notifications last.
  for v_row in select x ->> 'assignment_id' as id from jsonb_array_elements(v_done) x loop
    perform app.notifications_cancel(jsonb_build_object(
      'source_type', 'duties_assignment', 'source_id', v_row.id, 'reason', 'responded'));
    -- Story 4.8: the leaders' alert stops; the pre-service reminders are planned again.
    perform app.duties_after_answer(v_row.id::uuid, v_actor.member_id, v_actor.account_id,
                                    'duties.accept_many');
  end loop;
  return jsonb_build_object(
    'aggregate_type', 'duties_assignment', 'aggregate_id', v_first,
    'revision', v_first_revision,
    'data', jsonb_build_object('response', 'accepted', 'count', jsonb_array_length(v_done),
                               'assignments', v_done));
end;
$$;

-- (Replaced, story 4.11; copied from 20261014212507_duties_coverage.sql.)
create or replace function app.duties_apply_change(
  p_old app.duties_occurrences,
  p_new app.duties_occurrences,
  p_target_slot uuid,
  p_member uuid,
  p_member_given boolean,
  p_deadline timestamptz,
  p_deadline_key text,
  p_actor_member uuid,
  p_actor_account uuid,
  p_capacity text,
  p_command text,
  p_skip_unchanged boolean
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
  v_changed text[] := '{}';
  v_member_changed boolean := false;
  v_occ_material boolean;
  v_material boolean;
  v_notify boolean;
  v_window_changed boolean;
  v_carry boolean;
  v_class text;
  v_revision bigint;
  v_slot app.duties_slots;
  v_old app.duties_assignments;
  v_old_revision bigint;
  v_slot_revision bigint;
  v_slot_changed text[];
  v_is_target boolean;
  v_slot_material boolean;
  v_new_member uuid;
  v_current uuid;
  v_current_member uuid;
  v_current_revision bigint;
  v_current_deadline timestamptz;
  v_response text;
  v_superseded uuid;
  v_request uuid := app.cmd_current_request_id(p_actor_account, p_command);
  v_ops jsonb := '[]'::jsonb;
  v_created integer := 0;
  v_created_list jsonb := '[]'::jsonb;
  v_report jsonb;
  v_need_deadline boolean;
  v_start timestamptz := coalesce(p_new.reporting_at, p_new.starts_at);
  v_cur_target uuid;
  -- Story 4.8: the deadline every new assignment of this change takes, where it came from and
  -- whether it is Short notice.
  v_deadline timestamptz := p_deadline;
  v_deadline_source text := 'creator';
  v_short boolean := false;
  v_default jsonb;
  v_notice text;
  r record;
begin
  -- Story 4.9 review S1: the change's actor for app.duties_notify.
  perform pg_catalog.set_config('app.duties_actor', jsonb_build_object(
    'member', p_actor_member, 'account', p_actor_account, 'capacity', p_capacity,
    'command', p_command)::text, true);
  if p_member_given then
    -- Story 4.9: a cancelled position is never given again.
    if exists (select 1 from app.duties_slots s
                where s.slot_id = p_target_slot and s.cancelled_at is not null) then
      perform app.cmd_fail('validation_failed', '{"slot_id": "cancelled"}');
    end if;
    select a.member_id into v_cur_target from app.duties_assignments a
     where a.slot_id = p_target_slot and a.assignment_state = 'current';
    v_member_changed := p_member is distinct from v_cur_target;
  end if;
  if p_new.duty_name is distinct from p_old.duty_name then
    v_changed := array_append(v_changed, 'duty_name');
  end if;
  if p_new.starts_at is distinct from p_old.starts_at then
    v_changed := array_append(v_changed, 'starts_at');
  end if;
  if p_new.ends_at is distinct from p_old.ends_at then
    v_changed := array_append(v_changed, 'ends_at');
  end if;
  if p_new.reporting_at is distinct from p_old.reporting_at then
    v_changed := array_append(v_changed, 'reporting_at');
  end if;
  if p_new.location is distinct from p_old.location then
    v_changed := array_append(v_changed, 'location');
  end if;
  if p_new.instructions is distinct from p_old.instructions then
    v_changed := array_append(v_changed, 'instructions');
  end if;
  if p_new.topic is distinct from p_old.topic then
    v_changed := array_append(v_changed, 'topic');
  end if;
  if p_new.scripture is distinct from p_old.scripture then
    v_changed := array_append(v_changed, 'scripture');
  end if;
  if p_new.event_ref is distinct from p_old.event_ref then
    v_changed := array_append(v_changed, 'event_ref');
  end if;
  v_window_changed := v_changed && array['starts_at', 'ends_at', 'reporting_at'];
  v_occ_material := exists (select 1 from unnest(v_changed) f
                             where app.duties_slot_field_class(f) = 'material');
  v_material := v_occ_material or v_member_changed;
  -- 4.2: an answer-by with a change that asks nobody again is refused (before "unchanged").
  if not v_material and p_deadline is not null and p_deadline_key = 'response_deadline' then
    perform app.cmd_fail('validation_failed', '{"response_deadline": "not_material"}');
  end if;
  if cardinality(v_changed) = 0 and not v_member_changed then
    if p_skip_unchanged then
      return null;
    end if;
    perform app.cmd_fail('validation_failed', '{"occurrence_id": "unchanged"}');
  end if;
  v_notify := v_changed && array['instructions', 'topic', 'scripture'];
  -- A change of reference fields only (the linked event) is recorded as `reference`: no notice,
  -- and My duties does not report it as a details update.
  v_class := case when v_material then 'material' when v_notify then 'notes' else 'reference' end;

  -- A new pending assignment takes the leader's answer-by, or (story 4.8) without one the shared
  -- 3.3 lead-time default for an assignment made now: Short notice when that has already passed.
  -- Story 4.11: releasing a cell part's member (no new member) asks nobody.
  v_need_deadline := (v_member_changed and (p_member is not null or p_old.cell_id is null))
    or (v_occ_material and exists (
          select 1 from app.duties_slots s join app.duties_assignments a on a.slot_id = s.slot_id
           where s.occurrence_id = p_old.occurrence_id and a.assignment_state = 'current'));
  if v_need_deadline then
    if p_deadline is null then
      v_default := app.duties_default_deadline(v_start);
      v_deadline := (v_default ->> 'response_deadline')::timestamptz;
      v_deadline_source := 'default';
      v_short := (v_default ->> 'short_notice')::boolean;
    elsif p_deadline <= now() then
      perform app.cmd_fail('validation_failed', jsonb_build_object(p_deadline_key,
        case when p_deadline_key = 'deadline_before' then 'passed' else 'past' end));
    elsif p_deadline >= v_start then
      perform app.cmd_fail('validation_failed', jsonb_build_object(p_deadline_key, 'after_start'));
    end if;
  end if;
  -- Who will be asked: a new assignee must serve in the department; a kept assignee who can no
  -- longer serve (erased, left, under deletion) needs reassignment first (fail closed).
  if v_member_changed and p_old.cell_id is not null then
    -- Story 4.11: a cell part asks an active member (the cell's roster is its owner's check, in
    -- the caller's transaction); no member leaves a visible gap.
    if p_member is not null and not app.duties_member_active(p_member) then
      perform app.cmd_fail('validation_failed', '{"member_id": "unknown"}');
    end if;
  elsif v_member_changed and not app.duties_can_serve(p_member, p_old.department_id) then
    perform 1 from app.duties_department_members dm
     where dm.department_id = p_old.department_id and dm.member_id = p_member and dm.ended_at is null;
    if not found then
      perform app.cmd_fail('validation_failed', '{"member_id": "not_in_department"}');
    end if;
    perform app.cmd_fail('validation_failed', '{"member_id": "unknown"}');
  end if;
  if v_occ_material then
    for r in select a.member_id, s.slot_id from app.duties_slots s
               join app.duties_assignments a on a.slot_id = s.slot_id
              where s.occurrence_id = p_old.occurrence_id and a.assignment_state = 'current'
                and not (v_member_changed and s.slot_id = p_target_slot) loop
      if p_old.cell_id is not null then
        -- Story 4.11: a kept cell part member must still be an active member.
        if not app.duties_member_active(r.member_id) then
          perform app.cmd_fail('validation_failed', '{"member_id": "required_reassign"}');
        end if;
      else
        perform 1 from app.duties_department_members dm
         where dm.department_id = p_old.department_id and dm.member_id = r.member_id
           and dm.ended_at is null for share;
        if not (found and app.duties_member_active(r.member_id)) then
          perform app.cmd_fail('validation_failed', '{"member_id": "required_reassign"}');
        end if;
      end if;
    end loop;
  end if;
  if v_member_changed and p_old.cell_id is null then
    perform 1 from app.duties_department_members dm
     where dm.department_id = p_old.department_id and dm.member_id = p_member
       and dm.ended_at is null for share;
  end if;

  update app.duties_occurrences o
     set duty_name = p_new.duty_name, starts_at = p_new.starts_at, ends_at = p_new.ends_at,
         reporting_at = p_new.reporting_at, location = p_new.location,
         instructions = p_new.instructions, topic = p_new.topic, scripture = p_new.scripture,
         event_ref = p_new.event_ref, revision = o.revision + 1
   where o.occurrence_id = p_old.occurrence_id
  returning o.revision into v_revision;

  -- Story 4.9: cancelled positions are left as they are (no revision, no assignment).
  for v_slot in select s.* from app.duties_slots s where s.occurrence_id = p_old.occurrence_id
                   and s.cancelled_at is null
                 order by s.position_no for update loop
    v_is_target := v_member_changed and v_slot.slot_id = p_target_slot;
    v_slot_changed := v_changed;
    if v_is_target then
      v_slot_changed := (select coalesce(array_agg(f order by array_position(
                            array['duty_name', 'starts_at', 'ends_at', 'reporting_at', 'location',
                                  'member_id', 'instructions', 'topic', 'scripture', 'event_ref'], f)), '{}')
                           from unnest(array_append(v_changed, 'member_id')) f);
    end if;
    if cardinality(v_slot_changed) = 0 then
      continue;
    end if;
    v_slot_material := v_occ_material or v_is_target;
    update app.duties_slots s set revision = s.revision + 1 where s.slot_id = v_slot.slot_id
    returning s.revision into v_slot_revision;
    v_old := null;
    select a.* into v_old from app.duties_assignments a
     where a.slot_id = v_slot.slot_id and a.assignment_state = 'current' for update;
    v_current := null;
    v_current_member := null;
    v_current_revision := null;
    v_current_deadline := null;
    v_response := null;
    v_superseded := null;
    v_new_member := case when v_is_target then p_member else v_old.member_id end;
    if v_slot_material and v_old.assignment_id is not null then
      update app.duties_assignments a
         set assignment_state = 'superseded', ended_at = now(), end_reason = 'revised',
             revision = a.revision + 1
       where a.assignment_id = v_old.assignment_id
      returning a.revision into v_old_revision;
      v_superseded := v_old.assignment_id;
    end if;
    if v_slot_material and v_new_member is not null then
      -- Story 4.4: the same person at the same times, still pending or accepted, keeps the
      -- earlier override (no new check).
      -- A declined assignee asked again is a new commitment (checked like any other).
      v_carry := v_old.assignment_id is not null and v_new_member = v_old.member_id
                 and not v_window_changed and v_old.response in ('pending', 'accepted');
      insert into app.duties_assignments (slot_id, member_id, response_deadline, assigned_by_member,
                                          assigned_by_account, slot_revision,
                                          supersedes_assignment_id, override_reason,
                                          override_overlaps, override_by_member,
                                          override_by_account, override_at, deadline_source,
                                          short_notice)
      values (v_slot.slot_id, v_new_member, v_deadline, p_actor_member, p_actor_account,
              v_slot_revision, v_old.assignment_id,
              case when v_carry then v_old.override_reason end,
              case when v_carry then v_old.override_overlaps end,
              case when v_carry then v_old.override_by_member end,
              case when v_carry then v_old.override_by_account end,
              case when v_carry then v_old.override_at end, v_deadline_source, v_short)
      returning assignment_id, member_id, revision, response_deadline, response
           into v_current, v_current_member, v_current_revision, v_current_deadline, v_response;
      v_created := v_created + 1;
      v_created_list := v_created_list || jsonb_build_array(jsonb_build_object(
        'assignment_id', v_current, 'carried', v_carry));
    elsif not v_slot_material and v_old.assignment_id is not null then
      v_current := v_old.assignment_id;
      v_current_member := v_old.member_id;
      v_current_revision := v_old.revision;
      v_current_deadline := v_old.response_deadline;
      v_response := v_old.response;
    end if;
    insert into app.duties_slot_revisions (slot_id, slot_revision, occurrence_id,
                                           occurrence_revision, change_class, changed_fields,
                                           duty_name, starts_at, ends_at, reporting_at, location,
                                           instructions, topic, scripture, event_ref, member_id,
                                           assignment_id, response_deadline, created_by_member,
                                           created_by_account, command_request_id)
    values (v_slot.slot_id, v_slot_revision, p_old.occurrence_id, v_revision,
            case when v_slot_material then 'material' else v_class end, v_slot_changed,
            p_new.duty_name, p_new.starts_at, p_new.ends_at, p_new.reporting_at, p_new.location,
            p_new.instructions, p_new.topic, p_new.scripture, p_new.event_ref, v_current_member,
            v_current, v_current_deadline, p_actor_member, p_actor_account, v_request);
    perform app.duties_audit_series_event('duty_revised', p_actor_member, p_actor_account,
                                          p_capacity, p_command, p_old.department_id,
                                          p_old.series_id, p_old.occurrence_id,
                                          coalesce(v_current, v_superseded), v_current_member,
                                          case when v_slot_material then 'material' else v_class end,
                                          v_revision);

    -- Notification work (run by the caller after every Duties row is written).
    if v_slot_material then
      if v_old.assignment_id is not null then
        v_ops := v_ops || jsonb_build_array(jsonb_build_object(
          'op', 'cancel', 'source_id', v_old.assignment_id, 'reason', 'source_revised'));
      end if;
      v_notice := null;
      if v_current is not null and app.duties_notice_recipient(v_current_member) then
        v_notice := case when v_current_member = v_old.member_id then 'duty_changed'
                         else 'duty_assigned' end;
        v_ops := v_ops || jsonb_build_array(jsonb_build_object('op', 'enqueue', 'counts', true,
          'key', jsonb_build_object(
            'source_type', 'duties_assignment', 'source_id', v_current, 'source_revision', 1,
            'recipient_member_id', v_current_member,
            'reminder_kind', v_notice,
            'scheduled_at', app.cmd_utc(now()))));
      end if;
      -- Story 4.8: the new assignment's reminders and its leaders' alert (a fresh plan; on Short
      -- notice the notice above is the member's "respond now").
      if v_current is not null then
        v_ops := v_ops || jsonb_build_array(jsonb_build_object(
          'op', 'plan', 'assignment_id', v_current, 'fresh', true, 'notice', v_notice));
      end if;
      if v_old.assignment_id is not null and v_current_member is distinct from v_old.member_id
         and v_old.member_id is distinct from v_nil
         and app.duties_notice_recipient(v_old.member_id) then
        v_ops := v_ops || jsonb_build_array(jsonb_build_object('op', 'enqueue', 'counts', false,
          'key', jsonb_build_object(
            'source_type', 'duties_assignment', 'source_id', v_old.assignment_id,
            'source_revision', v_old_revision, 'recipient_member_id', v_old.member_id,
            'reminder_kind', 'duty_released', 'scheduled_at', app.cmd_utc(now()))));
      end if;
    elsif v_notify and v_current is not null and v_response in ('pending', 'accepted')
          and app.duties_notice_recipient(v_current_member) then
      v_ops := v_ops || jsonb_build_array(jsonb_build_object(
        'op', 'replace', 'source_id', v_current, 'source_revision', v_current_revision,
        'recipient', v_current_member));
    end if;

    if v_report is null or v_is_target then
      v_report := jsonb_build_object(
        'slot_id', v_slot.slot_id, 'slot_revision', v_slot_revision, 'assignment_id', v_current,
        'assignment_revision', v_current_revision, 'superseded_assignment_id', v_superseded,
        'response', v_response);
    end if;
  end loop;

  return coalesce(v_report, '{}'::jsonb) || jsonb_build_object(
    'revision', v_revision, 'change', v_class, 'assignments_created', v_created,
    'created', v_created_list, 'ops', v_ops);
end;
$$;

-- (Replaced, story 4.11; copied from 20261014212507_duties_coverage.sql.)
-- As in 4.8 (review fixes 1, 2, 6 kept); story 4.9: the loop that cancels the alerts of leaders no
-- longer in the list only touches the overdue and short-notice alerts, so a pending decline
-- alert is never cancelled by a re-plan.
create or replace function app.duties_plan_reminders(p_assignment_id uuid, p_fresh boolean, p_notice text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_a app.duties_assignments;
  v_o app.duties_occurrences;
  v_policy jsonb;
  v_start timestamptz;
  v_intent jsonb;
  v_leaders uuid[] := '{}';
  v_leader uuid;
  v_member jsonb;
  v_alerts integer := 0;
  v_late integer := 0;
  v_job jsonb;
begin
  select a.* into v_a from app.duties_assignments a where a.assignment_id = p_assignment_id;
  if not found or v_a.assignment_state <> 'current' then
    return '{"planned": false}'::jsonb;
  end if;
  v_o := app.duties_assignment_occurrence(v_a.slot_id);
  v_start := app.duties_occurrence_start(v_o);
  -- Story 4.11: a cell programme part plans its member's reminders too.
  if v_o.occurrence_state <> 'published' or v_start <= now() then
    return '{"planned": false}'::jsonb;
  end if;
  v_policy := app.notifications_policy();
  v_intent := jsonb_build_object(
    'assigned_at', app.cmd_utc(least(v_a.assigned_at, v_a.response_deadline)),
    'starts_at', app.cmd_utc(v_start),
    'response_deadline', app.cmd_utc(v_a.response_deadline),
    'responded', v_a.response <> 'pending');
  if v_a.response <> 'declined' and app.duties_notice_recipient(v_a.member_id) then
    v_member := app.notifications_set_schedule(jsonb_build_object(
      'source_type', 'duties_assignment', 'source_id', v_a.assignment_id,
      'source_revision', v_a.revision, 'recipient_member_id', v_a.member_id,
      'schedule_type', 'response',
      'intent', v_intent || jsonb_build_object('reminders',
                                               app.duties_reminder_specs(v_policy, v_o.reminders)),
      -- Review fix 6: before the member answers, the pre-service reminder asks for the answer
      -- (duty_response_due); after an acceptance it is `duty_starting`.
      'kinds', jsonb_build_object('response_deadline', 'duty_response_due',
                                  'starts_at', case when v_a.response = 'pending'
                                                    then 'duty_response_due' else 'duty_starting' end,
                                  'respond_now', coalesce(p_notice, 'duty_response_due')),
      'fresh', p_fresh));
  end if;

  -- Story 4.11: leader alerts stay department-only (a cell part's leaders are alerted once the
  -- cell-scope coverage contract exists; fail closed until then).
  if v_a.response = 'pending' and v_o.department_id is not null then
    v_leaders := app.duties_alert_recipients(v_o.department_id, v_a.member_id);
  end if;
  -- Leaders no longer in the list (or an answered assignment) lose their pending alert.
  -- Story 4.9: only the overdue and short-notice alerts (a decline alert is not re-planned).
  for v_leader in select distinct j.recipient_member_id from app.notifications_jobs j
                   where j.source_type = 'duties_coverage' and j.source_id = v_a.assignment_id
                     and j.job_state = 'pending'
                     and j.reminder_kind in ('duty_response_overdue', 'duty_short_notice')
                     and not (j.recipient_member_id = any (v_leaders))
                   order by j.recipient_member_id loop
    perform app.notifications_cancel(jsonb_build_object(
      'source_type', 'duties_coverage', 'source_id', v_a.assignment_id,
      'recipient_member_id', v_leader, 'reason', 'not_recipient',
      'reminder_kind', 'duty_response_overdue'));
    perform app.notifications_cancel(jsonb_build_object(
      'source_type', 'duties_coverage', 'source_id', v_a.assignment_id,
      'recipient_member_id', v_leader, 'reason', 'not_recipient',
      'reminder_kind', 'duty_short_notice'));
  end loop;
  -- Review fix 1: one alert job per leader, enqueued directly (a fixed rule on a stored
  -- deadline needs no schedule): `duty_short_notice` now on Short notice, otherwise
  -- `duty_response_overdue` at the deadline, or now when the deadline has already passed and
  -- this leader has no live alert at this revision (a passed deadline never drops it).
  foreach v_leader in array v_leaders loop
    v_alerts := v_alerts + 1;
    continue when exists (select 1 from app.notifications_jobs j
                           where j.source_type = 'duties_coverage' and j.source_id = v_a.assignment_id
                             and j.recipient_member_id = v_leader
                             and j.source_revision = v_a.revision
                             and j.reminder_kind in ('duty_response_overdue', 'duty_short_notice')
                             and j.job_state <> 'cancelled');
    v_job := app.notifications_enqueue(jsonb_build_object(
      'source_type', 'duties_coverage', 'source_id', v_a.assignment_id,
      'source_revision', v_a.revision, 'recipient_member_id', v_leader,
      'reminder_kind', case when v_a.short_notice then 'duty_short_notice' else 'duty_response_overdue' end,
      'scheduled_at', app.cmd_utc(greatest(v_a.response_deadline, now()))));
    if coalesce((v_job ->> 'created')::boolean, false) and v_a.response_deadline <= now()
       and not (p_fresh and v_a.short_notice) then
      v_late := v_late + 1;
    end if;
  end loop;
  return jsonb_build_object('planned', true,
                            'member_entries', coalesce((v_member ->> 'entries')::integer, 0),
                            'leaders', v_alerts, 'late_alerts', v_late);
end;
$$;

-- (Replaced, story 4.11; copied from 20261014212507_duties_coverage.sql.)
create or replace function app.duties_occurrence_json(p_occurrence_id uuid, p_with_notes boolean, p_counts jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'occurrence_id', o.occurrence_id,
    'department_id', o.department_id,
    'series_id', o.series_id,
    'duty_name', o.duty_name,
    'starts_at', app.cmd_utc(o.starts_at),
    'ends_at', case when o.ends_at is not null then app.cmd_utc(o.ends_at) end,
    'reporting_at', case when o.reporting_at is not null then app.cmd_utc(o.reporting_at) end,
    'location', o.location,
    'instructions', o.instructions,
    'topic', o.topic,
    'scripture', o.scripture,
    'event_ref', o.event_ref,
    'reminders', o.reminders,
    'state', o.occurrence_state,
    'revision', o.revision,
    'published_at', app.cmd_utc(o.published_at),
    -- Story 4.11: open owner-review mismatches (codes only) and linked programme parts.
    'reviews', app.duties_review_json(o.occurrence_id),
    'linked_parts', app.duties_linked_parts(o.occurrence_id),
    'positions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'slot_id', s.slot_id,
               'position_no', s.position_no,
               'position_name', s.position_name,
               'slot_revision', s.revision,
               -- Story 4.9: a cancelled position (no longer required).
               'cancelled', s.cancelled_at is not null,
               'assignment', (
                 select jsonb_build_object(
                          'assignment_id', a.assignment_id,
                          'member_id', a.member_id,
                          'display_name', app.duties_display_name(a.member_id),
                          'response', a.response,
                          'response_provenance', a.response_provenance,
                          'confirmation', case when a.response_provenance = 'leader' then jsonb_build_object(
                                            'by', app.duties_display_name(a.responded_by_member),
                                            'at', app.cmd_utc(a.responded_at),
                                            'channel', a.confirmed_channel,
                                            -- Review B1: the department's leaders and
                                            -- deputies only (never the Admin role alone).
                                            'reason', case when p_with_notes
                                                            and app.duties_manage_capacity(
                                                                  nullif(pg_catalog.current_setting('app.duties_viewer', true), '')::uuid,
                                                                  o.department_id)
                                                                in ('department_leader', 'department_deputy')
                                                           then a.confirmed_reason end) end,
                          'response_deadline', app.cmd_utc(a.response_deadline),
                          'deadline_source', a.deadline_source,
                          'short_notice', a.short_notice,
                          'needs_contact', app.duties_needs_contact(a, o),
                          'responded_at', case when a.responded_at is not null
                                               then app.cmd_utc(a.responded_at) end,
                          'prior_accepted_at', case when a.prior_accepted_at is not null
                                                    then app.cmd_utc(a.prior_accepted_at) end,
                          'note', case when p_with_notes then a.response_note end,
                          'revision', a.revision,
                          'slot_revision', a.slot_revision,
                          'changes', case when a.supersedes_assignment_id is not null
                                          then to_jsonb(app.duties_changes_since(
                                                 s.slot_id, a.slot_revision - 1, a.slot_revision)) end,
                          'notes_updated_at', (select app.cmd_utc(t.ts) from (
                                                 select app.duties_notes_updated_at(s.slot_id, a.slot_revision) as ts) t
                                                where t.ts is not null),
                          'overlaps', coalesce((p_counts ->> s.slot_id::text)::integer, 0),
                          'override', app.duties_override_json(a))
                   from app.duties_assignments a
                  where a.slot_id = s.slot_id and a.assignment_state = 'current'),
               'history', coalesce((
                 select jsonb_agg(h.obj order by h.ended_at desc, h.assignment_id)
                   from (select a.assignment_id, a.ended_at, jsonb_build_object(
                                  'assignment_id', a.assignment_id,
                                  'member_id', a.member_id,
                                  'display_name', app.duties_display_name(a.member_id),
                                  'state', a.assignment_state,
                                  'end_reason', a.end_reason,
                                  'ended_at', app.cmd_utc(a.ended_at),
                                  'response', a.response,
                                  'responded_at', case when a.responded_at is not null
                                                       then app.cmd_utc(a.responded_at) end,
                                  'prior_accepted_at', case when a.prior_accepted_at is not null
                                                            then app.cmd_utc(a.prior_accepted_at) end,
                                  'response_provenance', a.response_provenance,
                                  'note', case when p_with_notes then a.response_note end,
                                  'slot_revision', a.slot_revision) as obj
                           from app.duties_assignments a
                          where a.slot_id = s.slot_id and a.assignment_state <> 'current'
                          order by a.ended_at desc, a.assignment_id
                          limit 20) h), '[]'::jsonb))
             order by s.position_no)
        from app.duties_slots s where s.occurrence_id = o.occurrence_id), '[]'::jsonb))
    from app.duties_occurrences o
   where o.occurrence_id = p_occurrence_id;
$$;

-- (Replaced, story 4.11; copied from 20261014212507_duties_coverage.sql.)
create or replace function app.duties_rota_occurrence_json(p_occurrence_id uuid, p_counts jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'occurrence_id', o.occurrence_id,
    'series_date', to_char(o.series_date, 'YYYY-MM-DD'),
    'state', o.occurrence_state,
    'revision', o.revision,
    'duty_name', o.duty_name,
    'starts_at', app.cmd_utc(o.starts_at),
    'ends_at', case when o.ends_at is not null then app.cmd_utc(o.ends_at) end,
    'reporting_at', case when o.reporting_at is not null then app.cmd_utc(o.reporting_at) end,
    'location', o.location,
    'instructions', o.instructions,
    'topic', o.topic,
    'scripture', o.scripture,
    'event_ref', o.event_ref,
    'reminders', o.reminders,
    'started', app.duties_occurrence_start(o) <= now(),
    -- Story 4.11: open owner-review mismatches (codes only) and linked programme parts.
    'reviews', app.duties_review_json(o.occurrence_id),
    'linked_parts', app.duties_linked_parts(o.occurrence_id),
    -- Story 4.9: a cancelled position is no longer required.
    'required', (select count(*) from app.duties_slots s
                  where s.occurrence_id = o.occurrence_id and s.cancelled_at is null),
    'confirmed', (select count(*) from app.duties_slots s
                    join app.duties_assignments a on a.slot_id = s.slot_id
                   where s.occurrence_id = o.occurrence_id and a.assignment_state = 'current'
                     and a.response = 'accepted'),
    'positions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'slot_id', s.slot_id,
               'position_no', s.position_no,
               'position_name', s.position_name,
               'slot_revision', s.revision,
               'cancelled', s.cancelled_at is not null,
               'draft', case when s.draft_member_id is not null then jsonb_build_object(
                          'member_id', s.draft_member_id,
                          'display_name', app.duties_display_name(s.draft_member_id),
                          'available', app.duties_can_serve(s.draft_member_id, o.department_id),
                          'overlaps', coalesce((p_counts ->> s.slot_id::text)::integer, 0),
                          'override_reason', case when s.draft_member_id::text is distinct from
                                                          pg_catalog.current_setting('app.duties_viewer', true)
                                                  then s.draft_override_reason end) end,
               'assignment', (
                 select jsonb_build_object(
                          'assignment_id', a.assignment_id,
                          'member_id', a.member_id,
                          'display_name', app.duties_display_name(a.member_id),
                          'response', a.response,
                          'response_provenance', a.response_provenance,
                          'response_deadline', app.cmd_utc(a.response_deadline),
                          'deadline_source', a.deadline_source,
                          'short_notice', a.short_notice,
                          'needs_contact', app.duties_needs_contact(a, o),
                          'prior_accepted_at', case when a.prior_accepted_at is not null
                                                    then app.cmd_utc(a.prior_accepted_at) end,
                          'revision', a.revision,
                          'available', app.duties_can_serve(a.member_id, o.department_id),
                          'overlaps', coalesce((p_counts ->> s.slot_id::text)::integer, 0),
                          'override', app.duties_override_json(a))
                   from app.duties_assignments a
                  where a.slot_id = s.slot_id and a.assignment_state = 'current'))
             order by s.position_no)
        from app.duties_slots s where s.occurrence_id = o.occurrence_id), '[]'::jsonb))
    from app.duties_occurrences o
   where o.occurrence_id = p_occurrence_id;
$$;

-- (Replaced, story 4.11; copied from 20261014171038_duties_reminders.sql.)
create or replace function app.duties_withdraw_acceptance(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_assignment_id uuid;
  v_note text;
  v_assignment app.duties_assignments;
  v_occurrence app.duties_occurrences;
  v_revision bigint;
begin
  select a.* into v_actor from app.duties_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['assignment_id', 'note']);
  select t.errors, t.value into v_errors, v_assignment_id
    from app.duties_uuid(p_payload, 'assignment_id', v_errors) t;
  select t.errors, t.value into v_errors, v_note
    from app.duties_text(p_payload, 'note', false, 280, true, v_errors) t;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.duties_require_open();
  -- Ownership first, without a lock: someone else's or unknown is not found (no disclosure, and
  -- no lock taken on a row the actor may not touch). Then lock and re-check. Story 4.11: a cell
  -- programme part is withdrawn like a department duty.
  if not exists (select 1 from app.duties_assignments a
                   join app.duties_slots s on s.slot_id = a.slot_id
                   join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
                  where a.assignment_id = v_assignment_id and a.member_id = v_actor.member_id) then
    perform app.cmd_fail('not_found');
  end if;
  select a.* into v_assignment from app.duties_assignments a
   where a.assignment_id = v_assignment_id for update;
  if not found or v_assignment.member_id is distinct from v_actor.member_id then
    perform app.cmd_fail('not_found');
  end if;
  v_occurrence := app.duties_assignment_occurrence(v_assignment.slot_id);
  perform app.duties_refuse_ended(v_assignment, v_actor.member_id);
  if v_assignment.revision is distinct from p_expected_revision then
    perform app.cmd_fail('conflict', null, v_assignment.revision);
  end if;
  if v_assignment.response = 'pending' then
    perform app.cmd_fail('conflict', '{"assignment_id": "not_accepted"}', v_assignment.revision);
  end if;
  -- Only the member's own acceptance can be withdrawn here. An answer recorded any other way
  -- (a leader confirming on the member's behalf, entry 9) fails closed as already answered.
  if v_assignment.response <> 'accepted'
     or v_assignment.response_provenance is distinct from 'member' then
    perform app.cmd_fail('conflict', '{"assignment_id": "responded"}', v_assignment.revision);
  end if;
  if app.duties_occurrence_start(v_occurrence) <= now() then
    perform app.cmd_fail('validation_failed', '{"assignment_id": "started"}');
  end if;
  update app.duties_assignments a
     set response = 'declined', prior_accepted_at = a.responded_at, responded_at = now(),
         responded_by_member = v_actor.member_id, responded_by_account = v_actor.account_id,
         response_provenance = 'member', response_note = v_note, revision = a.revision + 1
   where a.assignment_id = v_assignment.assignment_id
  returning a.revision into v_revision;
  perform app.duties_audit_event('acceptance_withdrawn', v_actor.member_id, v_actor.account_id,
                                 'member', 'duties.withdraw_acceptance', v_occurrence.department_id,
                                 v_occurrence.occurrence_id, v_assignment.assignment_id,
                                 v_assignment.member_id, 'declined', v_revision);
  perform app.notifications_cancel(jsonb_build_object(
    'source_type', 'duties_assignment', 'source_id', v_assignment.assignment_id,
    'reason', 'responded'));
  -- Story 4.8: the leaders' alert stops (a decline keeps no reminder).
  perform app.duties_after_answer(v_assignment.assignment_id, v_actor.member_id, v_actor.account_id,
                                  'duties.withdraw_acceptance');
  return jsonb_build_object(
    'aggregate_type', 'duties_assignment', 'aggregate_id', v_assignment.assignment_id,
    'revision', v_revision,
    'data', jsonb_build_object('assignment_id', v_assignment.assignment_id, 'revision', v_revision,
                               'response', 'declined', 'withdrawn', true));
end;
$$;

-- (Replaced, story 4.11; copied from 20261014052239_duties_overlaps.sql.)
-- My duties (replaced): department-owned duties only until cell-owned parts get their member
-- view (entries 5 and 11); otherwise as in 4.1.
create or replace function app.duties_my_duties()
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
  perform app.duties_require_open_read();
  with ranked as (
    select a.assignment_id, o.starts_at,
           row_number() over (order by (o.starts_at <= now()),
                                       case when o.starts_at > now() then o.starts_at end,
                                       o.starts_at desc, a.assignment_id) as rn
      from app.duties_assignments a
      join app.duties_slots s on s.slot_id = a.slot_id
      join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
     where a.member_id = v_member and a.assignment_state = 'current'
       -- Story 4.11: cell programme parts are listed too.
       and o.occurrence_state = 'published'
       and o.starts_at > now() - interval '90 days')
  select jsonb_build_object(
           'member_id', v_member,
           'assignments', coalesce(jsonb_agg(app.duties_my_assignment_json(r.assignment_id)
                                             order by r.rn) filter (where r.rn <= 200), '[]'::jsonb),
           'truncated', count(*) > 200)
    into v_result
    from ranked r;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

-- (Replaced, story 4.11; copied from 20261013220239_duties_department_tracer.sql.)
-- Reminder check (3.2): exactly {current, revision, actionable, recipient_eligible}.
--   actionable          the response is still pending and the duty has not started;
--   recipient_eligible  the recipient is the assignee and still serves in the department.
create or replace function app.duties_assignment_reminder_check(p_key jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_assignment app.duties_assignments;
  v_occurrence app.duties_occurrences;
begin
  select a.* into v_assignment from app.duties_assignments a
   where a.assignment_id::text = p_key ->> 'source_id';
  if not found then
    return '{"current": false, "revision": null, "actionable": false, "recipient_eligible": false}'::jsonb;
  end if;
  select o.* into v_occurrence
    from app.duties_slots s join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where s.slot_id = v_assignment.slot_id;
  return jsonb_build_object(
    'current', v_assignment.assignment_state = 'current'
               and v_occurrence.occurrence_state = 'published'
               and v_assignment.revision = (p_key ->> 'source_revision')::numeric::bigint,
    'revision', v_assignment.revision,
    'actionable', v_assignment.assignment_state = 'current' and v_assignment.response = 'pending'
                  and app.duties_occurrence_start(v_occurrence) > now(),
    'recipient_eligible', v_assignment.member_id::text = p_key ->> 'recipient_member_id'
                          and case when v_occurrence.cell_id is not null
                                   -- Story 4.11: a cell part's member, while an active member
                                   -- (Cells ends the parts of a member who leaves the cell).
                                   then app.duties_member_active(v_assignment.member_id)
                                   else exists (select 1 from app.duties_department_members dm
                                                 where dm.department_id = v_occurrence.department_id
                                                   and dm.member_id = v_assignment.member_id
                                                   and dm.ended_at is null) end);
end;
$$;

-- (Replaced, story 4.11; copied from 20261014001142_duties_revisions.sql.)
-- duty_updated (notes-only change): current while the assignment is current at that revision;
-- actionable while the duty has not started and the member has not declined.
create or replace function app.duties_update_reminder_check(p_key jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_assignment app.duties_assignments;
  v_occurrence app.duties_occurrences;
begin
  select a.* into v_assignment from app.duties_assignments a
   where a.assignment_id::text = p_key ->> 'source_id';
  if not found then
    return '{"current": false, "revision": null, "actionable": false, "recipient_eligible": false}'::jsonb;
  end if;
  select o.* into v_occurrence
    from app.duties_slots s join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where s.slot_id = v_assignment.slot_id;
  return jsonb_build_object(
    'current', v_assignment.assignment_state = 'current'
               and v_occurrence.occurrence_state = 'published'
               and v_assignment.revision = (p_key ->> 'source_revision')::numeric::bigint,
    'revision', v_assignment.revision,
    'actionable', v_assignment.assignment_state = 'current' and v_assignment.response <> 'declined'
                  and app.duties_occurrence_start(v_occurrence) > now(),
    'recipient_eligible', v_assignment.member_id::text = p_key ->> 'recipient_member_id'
                          and case when v_occurrence.cell_id is not null
                                   -- Story 4.11: a cell part's member, while an active member.
                                   then app.duties_member_active(v_assignment.member_id)
                                   else exists (select 1 from app.duties_department_members dm
                                                 where dm.department_id = v_occurrence.department_id
                                                   and dm.member_id = v_assignment.member_id
                                                   and dm.ended_at is null) end);
end;
$$;

-- (Replaced, story 4.11; copied from 20261015002121_duties_outcomes.sql, the 4.10 review S1 lock
-- order kept.) Story 4.11: the actors of part links and owner-review flags are anonymised.
create or replace function app.duties_erase_member(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_input ->> 'member_id')::uuid;
  v_account uuid := nullif(p_input ->> 'account_id', '')::uuid;
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
  v_assignments uuid[];
begin
  if p_input ->> 'phase' = 'erase' then
    -- Review S1 (story 4.10): lock first, in the commands' AD-2 order (departments, series,
    -- occurrences, then assignments, FOR UPDATE), so an outcome or contact attempt in flight
    -- either commits before the text below is cleared or waits and then sees the member erased.
    perform 1 from app.duties_departments d where d.created_by_member = v_member
     order by d.department_id for update;
    perform 1 from app.duties_series r where r.created_by_member = v_member
     order by r.series_id for update;
    perform 1 from app.duties_occurrences o
     where o.created_by_member = v_member
        or o.occurrence_id in (select s.occurrence_id from app.duties_assignments a
                                 join app.duties_slots s on s.slot_id = a.slot_id
                                where a.member_id = v_member)
     order by o.series_id nulls last, o.series_date nulls last, o.starts_at, o.occurrence_id
       for update;
    select coalesce(array_agg(x.assignment_id), '{}') into v_assignments
      from (select a.assignment_id from app.duties_assignments a
             where a.member_id = v_member order by a.assignment_id for update) x;
    perform app.duties_deletion_purge_rows(v_member);
    update app.duties_department_members dm set added_by_member = v_nil
     where dm.added_by_member = v_member;
    -- Story 4.9: the leaders' practical notes about the erased assignee go with them (before the
    -- assignee is anonymised below).
    update app.duties_contact_attempts t set note = null
     where t.note is not null and t.assignment_id = any (v_assignments);
    -- Story 4.10: the outcome notes and correction reasons about the erased assignee go with them
    -- (the outcome values stay, attached to the anonymised assignment).
    update app.duties_outcomes x set note = null, correction_reason = null
     where (x.note is not null or x.correction_reason is not null)
       and x.assignment_id = any (v_assignments);
    -- The leader's words about the erased assignee go with them (stories 4.4, 4.9).
    update app.duties_assignments a set member_id = v_nil, response_note = null, override_reason = null,
                                        confirmed_reason = null
     where a.member_id = v_member;
    update app.duties_assignments a set responded_by_member = v_nil
     where a.responded_by_member = v_member;
    update app.duties_assignments a set assigned_by_member = v_nil
     where a.assigned_by_member = v_member;
    update app.duties_assignments a set override_by_member = v_nil
     where a.override_by_member = v_member;
    update app.duties_occurrences o set created_by_member = v_nil where o.created_by_member = v_member;
    update app.duties_departments d set created_by_member = v_nil where d.created_by_member = v_member;
    update app.duties_series r set created_by_member = v_nil where r.created_by_member = v_member;
    -- A planned (draft) position of the member becomes unassigned, with its planned reason.
    update app.duties_slots s
       set draft_member_id = null, draft_override_reason = null, draft_override_by_member = null,
           draft_override_by_account = null, draft_override_at = null
     where s.draft_member_id = v_member;
    update app.duties_slots s set draft_override_by_member = v_nil
     where s.draft_override_by_member = v_member;
    update app.duties_slots s set cancelled_by_member = v_nil where s.cancelled_by_member = v_member;
    update app.duties_slot_revisions r set member_id = v_nil where r.member_id = v_member;
    update app.duties_slot_revisions r set created_by_member = v_nil
     where r.created_by_member = v_member;
    update app.duties_audit au set actor_member_id = v_nil where au.actor_member_id = v_member;
    update app.duties_audit au set member_id = v_nil where au.member_id = v_member;
    update app.duties_coverage_cases c set opened_by_member = v_nil where c.opened_by_member = v_member;
    update app.duties_contact_attempts t set recorded_by_member = v_nil
     where t.recorded_by_member = v_member;
    update app.duties_outcomes x set recorded_by_member = v_nil where x.recorded_by_member = v_member;
    -- Story 4.11: who linked or unlinked a part position, and who raised or cleared a review.
    update app.duties_part_links l set linked_by_member = v_nil where l.linked_by_member = v_member;
    update app.duties_part_links l set ended_by_member = v_nil where l.ended_by_member = v_member;
    update app.duties_review_flags f set flagged_by_member = v_nil where f.flagged_by_member = v_member;
    update app.duties_review_flags f set cleared_by_member = v_nil where f.cleared_by_member = v_member;
    if v_account is not null then
      update app.duties_department_members dm set added_by_account = v_nil
       where dm.added_by_account = v_account;
      update app.duties_assignments a set responded_by_account = v_nil
       where a.responded_by_account = v_account;
      update app.duties_assignments a set assigned_by_account = v_nil
       where a.assigned_by_account = v_account;
      update app.duties_assignments a set override_by_account = v_nil
       where a.override_by_account = v_account;
      update app.duties_occurrences o set created_by_account = v_nil
       where o.created_by_account = v_account;
      update app.duties_departments d set created_by_account = v_nil
       where d.created_by_account = v_account;
      update app.duties_series r set created_by_account = v_nil
       where r.created_by_account = v_account;
      update app.duties_slots s set draft_override_by_account = v_nil
       where s.draft_override_by_account = v_account;
      update app.duties_slots s set cancelled_by_account = v_nil
       where s.cancelled_by_account = v_account;
      update app.duties_slot_revisions r set created_by_account = v_nil
       where r.created_by_account = v_account;
      update app.duties_audit au set actor_account_id = v_nil where au.actor_account_id = v_account;
      update app.duties_coverage_cases c set opened_by_account = v_nil
       where c.opened_by_account = v_account;
      update app.duties_contact_attempts t set recorded_by_account = v_nil
       where t.recorded_by_account = v_account;
      update app.duties_outcomes x set recorded_by_account = v_nil
       where x.recorded_by_account = v_account;
      -- Story 4.11.
      update app.duties_part_links l set linked_by_account = v_nil
       where l.linked_by_account = v_account;
      update app.duties_part_links l set ended_by_account = v_nil
       where l.ended_by_account = v_account;
      update app.duties_review_flags f set flagged_by_account = v_nil
       where f.flagged_by_account = v_account;
      update app.duties_review_flags f set cleared_by_account = v_nil
       where f.cleared_by_account = v_account;
    end if;
  end if;
  return jsonb_build_object('remaining', app.duties_deletion_remaining(v_member, v_account));
end;
$$;

comment on function app.duties_erase_member(jsonb) is
  'Duties deletion hook (stories 4.1-4.11): erase or check the member''s Duties personal data.';


-- ---------------------------------------------------------------------------------------------
-- The SYNTHETIC Cells-like caller (module fixture; tests and the local E2E register it)
-- ---------------------------------------------------------------------------------------------

create table app.fixture_programme_parts (
  part_id uuid primary key default gen_random_uuid(),
  cell_id uuid not null,
  label text not null check (length(label) between 1 and 80),
  part_state text not null default 'published' check (part_state in ('published', 'cancelled')),
  revision bigint not null default 1 check (revision >= 1),
  created_at timestamptz not null default now()
);

comment on table app.fixture_programme_parts is
  'Story 4.11: SYNTHETIC programme parts of the fixture caller that stands in for Cells (epic 5) '
  'to prove the Duties owner operations. Never real data.';

alter table app.fixture_programme_parts enable row level security;
revoke all on table app.fixture_programme_parts from public, anon, authenticated, service_role;

create table app.fixture_events (
  event_id uuid primary key default gen_random_uuid(),
  title text not null check (length(title) between 1 and 80),
  revision bigint not null default 1 check (revision >= 1),
  created_at timestamptz not null default now()
);

comment on table app.fixture_events is
  'Story 4.11: SYNTHETIC events of the fixture caller that stands in for Content (epic 6). Never '
  'real data.';

alter table app.fixture_events enable row level security;
revoke all on table app.fixture_events from public, anon, authenticated, service_role;

-- Source checks (1.5): {current, revision}.
create function app.fixture_programme_part_check(p_source jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select jsonb_build_object('current', p.revision = (p_source ->> 'source_revision')::numeric::bigint,
                              'revision', p.revision)
      from app.fixture_programme_parts p where p.part_id::text = p_source ->> 'source_id'),
    '{"current": false, "revision": null}'::jsonb);
$$;

create function app.fixture_event_check(p_source jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select jsonb_build_object('current', e.revision = (p_source ->> 'source_revision')::numeric::bigint,
                              'revision', e.revision)
      from app.fixture_events e where e.event_id::text = p_source ->> 'source_id'),
    '{"current": false, "revision": null}'::jsonb);
$$;

-- The caller's first locks (AD-2, as Cells' own authorizer and command take them): the session
-- member's grant rows FOR SHARE (Identity first), then its own part row FOR UPDATE with a new
-- revision. Duties, Follow-ups and Notifications come after, inside the same transaction.
create function app.fixture_programme_begin(p_part_id uuid, p_cell_id uuid, p_label text,
                                            p_state text)
returns app.fixture_programme_parts
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_part app.fixture_programme_parts;
begin
  select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
   where e.outcome = 'granted';
  if v_member is null then
    perform app.cmd_fail('forbidden');
  end if;
  perform 1 from app.identity_grants g where g.member_id = v_member and g.revoked_at is null
   order by g.grant_id for share;
  if p_part_id is null then
    insert into app.fixture_programme_parts (cell_id, label, part_state)
    values (p_cell_id, coalesce(p_label, 'SYNTHETIC part'), coalesce(p_state, 'published'))
    returning * into v_part;
    return v_part;
  end if;
  select p.* into v_part from app.fixture_programme_parts p where p.part_id = p_part_id for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  update app.fixture_programme_parts p
     set revision = p.revision + 1, label = coalesce(p_label, p.label),
         part_state = coalesce(p_state, p.part_state)
   where p.part_id = p_part_id
  returning * into v_part;
  return v_part;
end;
$$;

-- Publish (create or revise) a SYNTHETIC part: {part_id? | cell_id, duty_name, ... put_part
-- fields}. When no position is left unfilled, the part's fill_part follow-up is resolved.
create function app.fixture_programme_publish(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_part app.fixture_programme_parts;
  v_result jsonb;
  v_followups jsonb;
begin
  v_part := app.fixture_programme_begin((p_input ->> 'part_id')::uuid, (p_input ->> 'cell_id')::uuid,
                                        p_input ->> 'duty_name', 'published');
  v_result := app.duties_owner_put_part((p_input - 'part_id' - 'cell_id') || jsonb_build_object(
    'source_type', 'fixture_programme_part', 'source_id', v_part.part_id,
    'source_revision', v_part.revision, 'cell_id', v_part.cell_id));
  if not exists (select 1 from jsonb_array_elements(v_result -> 'positions') x
                  where not (x ->> 'cancelled')::boolean
                    and coalesce(jsonb_typeof(x -> 'assignment_id'), 'null') = 'null') then
    v_followups := app.followups_source_event(jsonb_build_object(
      'source_type', 'fixture_programme_part', 'source_id', v_part.part_id, 'event', 'resolved'));
  end if;
  return v_result || jsonb_build_object('part_id', v_part.part_id, 'part_revision', v_part.revision,
                                        'followups', v_followups);
end;
$$;

-- Cancel a SYNTHETIC part: {part_id, expected_revision}. Its follow-ups end with it.
create function app.fixture_programme_cancel(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_part app.fixture_programme_parts;
  v_result jsonb;
begin
  v_part := app.fixture_programme_begin((p_input ->> 'part_id')::uuid, null, null, 'cancelled');
  v_result := app.duties_owner_cancel_part(jsonb_build_object(
    'source_type', 'fixture_programme_part', 'source_id', v_part.part_id,
    'source_revision', v_part.revision, 'cell_id', v_part.cell_id,
    'expected_revision', p_input -> 'expected_revision'));
  return v_result || jsonb_build_object(
    'part_id', v_part.part_id, 'part_revision', v_part.revision,
    'followups', app.followups_source_event(jsonb_build_object(
                   'source_type', 'fixture_programme_part', 'source_id', v_part.part_id,
                   'event', 'cancelled')));
end;
$$;

-- Link a part position to a department duty: {part_id, position_key, slot_id}.
create function app.fixture_programme_link(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_part app.fixture_programme_parts;
begin
  v_part := app.fixture_programme_begin((p_input ->> 'part_id')::uuid, null, null, null);
  return app.duties_owner_link_duty(jsonb_build_object(
    'source_type', 'fixture_programme_part', 'source_id', v_part.part_id,
    'source_revision', v_part.revision, 'cell_id', v_part.cell_id,
    'position_key', p_input -> 'position_key', 'slot_id', p_input -> 'slot_id'));
end;
$$;

-- End a display link: {part_id, position_key}.
create function app.fixture_programme_unlink(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_part app.fixture_programme_parts;
begin
  v_part := app.fixture_programme_begin((p_input ->> 'part_id')::uuid, null, null, null);
  return app.duties_owner_unlink(jsonb_build_object(
    'source_type', 'fixture_programme_part', 'source_id', v_part.part_id,
    'source_revision', v_part.revision, 'cell_id', v_part.cell_id,
    'position_key', p_input -> 'position_key'));
end;
$$;

-- The meeting behind a part changed: {part_id, changed: [codes]} flags its linked department
-- duties for their department's review.
create function app.fixture_programme_changed(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_part app.fixture_programme_parts;
begin
  v_part := app.fixture_programme_begin((p_input ->> 'part_id')::uuid, null, null, null);
  return app.duties_owner_flag_review(jsonb_build_object(
    'source_type', 'fixture_programme_part', 'source_id', v_part.part_id,
    'source_revision', v_part.revision, 'cell_id', v_part.cell_id,
    'changed', p_input -> 'changed'));
end;
$$;

-- Open the part's fill_part follow-up (Follow-ups source operation): {part_id, owner_member_id,
-- supervisor_member_id, next_action, due_at}.
create function app.fixture_programme_open_followup(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_part app.fixture_programme_parts;
  v_member uuid;
  v_account uuid;
begin
  v_part := app.fixture_programme_begin((p_input ->> 'part_id')::uuid, null, null, null);
  select e.member_id, l.auth_user_id into v_member, v_account
    from app.identity_evaluate_grant(null, null, null) e
    join app.identity_account_links l on l.link_id = e.link_id
   where e.outcome = 'granted';
  return app.followups_open_task(jsonb_build_object(
    'source_type', 'fixture_programme_part', 'source_id', v_part.part_id,
    'source_revision', v_part.revision, 'purpose', 'fill_part',
    'owner_member_id', p_input -> 'owner_member_id',
    'supervisor_member_id', p_input -> 'supervisor_member_id',
    'scope_kind', 'cell_leader', 'scope_id', v_part.cell_id,
    'next_action', p_input -> 'next_action', 'due_at', p_input -> 'due_at',
    'actor_member_id', v_member, 'actor_account_id', v_account));
end;
$$;

-- A SYNTHETIC event changed: {event_id, changed: [codes]} flags the department duties that name
-- it (event_ref) for their department's review.
create function app.fixture_event_changed(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_event app.fixture_events;
begin
  select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
   where e.outcome = 'granted';
  if v_member is null then
    perform app.cmd_fail('forbidden');
  end if;
  perform 1 from app.identity_grants g where g.member_id = v_member and g.revoked_at is null
   order by g.grant_id for share;
  update app.fixture_events e set revision = e.revision + 1
   where e.event_id = (p_input ->> 'event_id')::uuid
  returning * into v_event;
  if v_event.event_id is null then
    perform app.cmd_fail('not_found');
  end if;
  return app.duties_owner_flag_review(jsonb_build_object(
    'source_type', 'fixture_event', 'source_id', v_event.event_id,
    'source_revision', v_event.revision, 'changed', p_input -> 'changed'));
end;
$$;

comment on function app.fixture_programme_publish(jsonb) is
  'Story 4.11: SYNTHETIC Cells-like caller (tests and the local E2E). Never client-executable.';


-- ---------------------------------------------------------------------------------------------
-- Privileges (new functions; replaced functions keep theirs). No client grant: owner operations
-- and the SYNTHETIC caller are server-only; duties.clear_review goes through api.duties_command.
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.duties_review_fields_ok(text[]),
  app.duties_part_link_guard(),
  app.duties_register_link_source(text, text, text),
  app.duties_owner_ref_errors(jsonb, boolean),
  app.duties_position_key_error(jsonb),
  app.duties_owner_session(uuid),
  app.duties_owner_source(jsonb, text),
  app.duties_owner_positions(jsonb),
  app.duties_owner_cancel_slot(app.duties_occurrences, uuid, uuid, uuid, text, text),
  app.duties_owner_positions_json(text, uuid),
  app.duties_owner_part_answer(text, uuid, uuid),
  app.duties_owner_put_part(jsonb),
  app.duties_owner_cancel_part(jsonb),
  app.duties_owner_link_duty(jsonb),
  app.duties_owner_unlink(jsonb),
  app.duties_owner_flag_review(jsonb),
  app.duties_owner_part(jsonb),
  app.duties_owner_conflicts(jsonb),
  app.duties_owner_event_links(jsonb),
  app.duties_owner_topic(jsonb),
  app.duties_clear_review(uuid, bigint, jsonb),
  app.duties_review_json(uuid),
  app.duties_linked_parts(uuid),
  app.fixture_programme_part_check(jsonb),
  app.fixture_event_check(jsonb),
  app.fixture_programme_begin(uuid, uuid, text, text),
  app.fixture_programme_publish(jsonb),
  app.fixture_programme_cancel(jsonb),
  app.fixture_programme_link(jsonb),
  app.fixture_programme_unlink(jsonb),
  app.fixture_programme_changed(jsonb),
  app.fixture_programme_open_followup(jsonb),
  app.fixture_event_changed(jsonb)
  from public, anon, authenticated, service_role;
