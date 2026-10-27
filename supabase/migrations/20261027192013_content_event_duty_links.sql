-- Link duties to published events and flag their review when an event changes (story 6.12; K13;
-- AD-1, AD-2, AD-6, AD-7). A forward migration: no merged migration is edited.
--
-- Duties contract change (recorded in the 4.11 consumer guide, as epic 5 did):
--   * A duty's `event_ref` (the linked-event reference of 4.3, an opaque uuid until now) must name
--     a published event of a registered `event` link source. Duties checks it through the 1.5
--     source registry only (app.contract_check_source), never by reading Content: the event
--     source's check hook reveals the event's current revision while it is published and null
--     otherwise. app.duties_event_ref_error answers null or `not_published`. Two triggers
--     (occurrences and series) apply it whenever a reference is set or changed, so every Duties
--     path (revise_duty, revise_series, create_series, owner put_part) refuses an unpublished,
--     withdrawn, archived, unknown or foreign id with validation_failed {"event_ref":
--     "not_published"}. Clearing a reference (null) is always allowed; a reference already stored
--     is never re-checked (a later withdrawal does not block other edits), and an occurrence a
--     series generates with the series' own reference is not checked again.
--   * My duties (app.duties_my_assignment_json) carries `event_ref`, so the duty detail can show
--     the linked event through Content's public event read. The rota and board already carry it.
--
-- Content (events kind):
--   * Source type `content_event` with its check hook app.content_event_source_check: current
--     while the event is published at the given revision number (its live revision number, as
--     announcements do); `revision` is the live revision number while published, else null.
--     Registered with Duties as the `event` link source (app.duties_register_link_source).
--   * content.publish_event: when a newly published revision changes the time (starts_at or
--     ends_at) or the place (location) of the previous live revision of a published or withdrawn
--     event, the linked department duties are flagged through app.duties_owner_flag_review
--     (`time`, `place`) inside the publish transaction, after the item is locked and published.
--     content.withdraw_event and content.archive_event of a published event flag `cancelled`
--     first, while the event is still published at its live revision (the same transaction, the
--     item row already locked). The 4.16 operation sends one notice per department to each
--     reachable leader and deputy other than the editor; no duty is republished and no answer
--     is reset. With the Q4 personal-data gate closed (no duty can exist) nothing is called.
--   * api.content_staff_event_duty_links(event_id): for an event editor, how many published
--     department duties that have not started name the event and how many reviews are open
--     (counts only, from app.duties_owner_event_links). The staff editor shows it before saving,
--     publishing, withdrawing or archiving.
--
-- Replaced bodies (each copied from its latest version; changes marked "Story 6.12"):
--   from 20261021211830 (special assignments): duties_my_assignment_json.
--   from 20261027140149 (6.11): content_event_publish.
--   from 20261021233523 (6.1): content_event_withdraw, content_event_archive.
--
-- Lock order (AD-2): the editor's role grants FOR SHARE (authorizer) -> receipt -> the event's
-- item row FOR UPDATE -> Duties departments and occurrences FOR SHARE -> flags -> Notifications.
--
-- The public event read is unchanged: it never names a duty, rota or department.
--
-- No destructive statements, no row deletions (no _rows file). ASCII only, no backslashes.

-- ---------------------------------------------------------------------------------------------
-- Duties: event_ref names a published event (contract change)
-- ---------------------------------------------------------------------------------------------

-- Null when the reference may be stored: no reference, or a published event of a registered
-- `event` link source (through its 1.5 check hook: a published event reports its revision, and
-- is current at that revision). Otherwise `not_published`.
create function app.duties_event_ref_error(p_event_ref uuid)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_type text;
  v_check jsonb;
begin
  if p_event_ref is null then
    return null;
  end if;
  for v_type in select s.source_type from app.duties_link_sources s
                 where s.role = 'event' order by s.source_type loop
    v_check := app.contract_check_source(jsonb_build_object(
      'source_type', v_type, 'source_id', p_event_ref, 'source_revision', 1));
    if jsonb_typeof(v_check -> 'revision') = 'number' then
      if (v_check -> 'revision')::numeric <> 1 then
        v_check := app.contract_check_source(jsonb_build_object(
          'source_type', v_type, 'source_id', p_event_ref, 'source_revision', v_check -> 'revision'));
      end if;
      if coalesce((v_check ->> 'current')::boolean, false) then
        return null;
      end if;
    end if;
  end loop;
  return 'not_published';
end;
$$;

comment on function app.duties_event_ref_error(uuid) is
  'Story 6.12 (Duties contract change): null when a duty may name this event (a published event '
  'of a registered event link source, checked through app.contract_check_source), else '
  'not_published.';

-- Occurrences: a reference set or changed is checked; one generated from its series with the
-- series' own reference was checked on the series.
create function app.duties_occurrence_event_ref_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_error text;
begin
  if new.event_ref is null
     or (tg_op = 'UPDATE' and new.event_ref is not distinct from old.event_ref) then
    return new;
  end if;
  if tg_op = 'INSERT' and new.series_id is not null
     and exists (select 1 from app.duties_series r
                  where r.series_id = new.series_id and r.event_ref = new.event_ref) then
    return new;
  end if;
  v_error := app.duties_event_ref_error(new.event_ref);
  if v_error is not null then
    perform app.cmd_fail('validation_failed', jsonb_build_object('event_ref', v_error));
  end if;
  return new;
end;
$$;

create trigger duties_occurrences_event_ref
  before insert or update of event_ref on app.duties_occurrences
  for each row execute function app.duties_occurrence_event_ref_guard();

-- Series: the template's reference, checked whenever it is set or changed.
create function app.duties_series_event_ref_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_error text;
begin
  if new.event_ref is null
     or (tg_op = 'UPDATE' and new.event_ref is not distinct from old.event_ref) then
    return new;
  end if;
  v_error := app.duties_event_ref_error(new.event_ref);
  if v_error is not null then
    perform app.cmd_fail('validation_failed', jsonb_build_object('event_ref', v_error));
  end if;
  return new;
end;
$$;

create trigger duties_series_event_ref
  before insert or update of event_ref on app.duties_series
  for each row execute function app.duties_series_event_ref_guard();

-- (Replaced; copied from 20261021211830_duties_special_assignments.sql.) Story 6.12: the linked
-- event's id (`event_ref`), so the duty detail can show the published event. Everything else is
-- unchanged.
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
    -- Special assignments: `special` (no department, no cell; the Pastors).
    'owner_kind', case when o.cell_id is not null then 'cell'
                       when o.special then 'special' else 'department' end,
    'department_id', d.department_id,
    'department_name', d.name,
    'cell_id', o.cell_id,
    'duty_name', o.duty_name,
    'position_name', s.position_name,
    'starts_at', app.cmd_utc(o.starts_at),
    'ends_at', case when o.ends_at is not null then app.cmd_utc(o.ends_at) end,
    'reporting_at', case when o.reporting_at is not null then app.cmd_utc(o.reporting_at) end,
    -- Special assignments: a "done by" date (starts_at is then its due moment).
    'due_on', o.due_on,
    'location', o.location,
    'instructions', o.instructions,
    'topic', o.topic,
    'scripture', o.scripture,
    -- Story 6.12: the linked published event (shown through Content's public event read).
    'event_ref', o.event_ref,
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
               'role', case when g.role = 'pastor' then 'pastor'
                            else case g.scope_kind when 'department_leader' then 'leader'
                                                   when 'cell_leader' then 'leader'
                                                   when 'cell_assistant' then 'assistant'
                                                   else 'deputy' end end)
             order by (g.scope_kind in ('department_deputy', 'cell_assistant')),
                      case when o.special then g.member_id is distinct from o.created_by_member end,
                      m.display_name collate "C", g.member_id)
        from app.identity_grants g
        join app.identity_members m on m.member_id = g.member_id
       where g.revoked_at is null
         and ((o.department_id is not null and g.scope_id = o.department_id
               and g.scope_kind in ('department_leader', 'department_deputy'))
              or (o.cell_id is not null and g.scope_id = o.cell_id
                  and g.scope_kind in ('cell_leader', 'cell_assistant'))
              or (o.special and g.role = 'pastor'))
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

-- ---------------------------------------------------------------------------------------------
-- Content: the event as a Duties link source
-- ---------------------------------------------------------------------------------------------

-- Current while the event is published at the reference's revision (its live revision number);
-- the revision is the live revision number while published and null otherwise (draft,
-- withdrawn, archived, unknown or not an event).
create function app.content_event_source_check(p_source jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select jsonb_build_object(
             'current', i.lifecycle_state = 'published'
                        and i.live_revision_no::numeric = (p_source ->> 'source_revision')::numeric,
             'revision', case when i.lifecycle_state = 'published' then i.live_revision_no end)
      from app.content_items i
     where i.item_id::text = lower(p_source ->> 'source_id') and i.kind = 'event'),
    '{"current": false, "revision": null}'::jsonb);
$$;

comment on function app.content_event_source_check(jsonb) is
  'Story 6.12: 1.5 source check of content_event: current while published at the live revision '
  'number; revision null while the event is not public.';

select app.contract_register_source_type(
  'content', 'content_event', 'app.content_event_source_check(jsonb)'::regprocedure);
select app.duties_register_link_source('content', 'content_event', 'event');

-- Flags the department duties linked to an event for their leaders' review (4.11 operation with
-- the 4.16 notice), inside the caller's command after the event's item row is locked. The event
-- must be published at p_revision_no. Answers how many duties were flagged. Nothing is called
-- when nothing changed or the personal-data gate is closed (no duty can exist then).
create function app.content_event_flag_duties(p_item_id uuid, p_revision_no integer,
                                              p_changed text[])
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if coalesce(cardinality(p_changed), 0) = 0 or not app.identity_applications_open() then
    return 0;
  end if;
  v_result := app.duties_owner_flag_review(jsonb_build_object(
    'source_type', 'content_event', 'source_id', p_item_id, 'source_revision', p_revision_no,
    'changed', to_jsonb(p_changed)));
  return coalesce((v_result ->> 'flagged')::integer, 0);
end;
$$;

-- The review codes between two revisions of an event: `time` (start or end) and `place`.
create function app.content_event_changes(p_item_id uuid, p_from_no integer, p_to_no integer)
returns text[]
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select array_remove(array[
             case when (a.starts_at, a.ends_at) is distinct from (b.starts_at, b.ends_at) then 'time' end,
             case when a.location is distinct from b.location then 'place' end], null)
      from app.content_event_revisions a
      join app.content_event_revisions b on b.item_id = a.item_id and b.revision_no = p_to_no
     where a.item_id = p_item_id and a.revision_no = p_from_no), '{}'::text[]);
$$;

-- (Replaced; copied from 20261027140149_content_event_posters_rsvp.sql.) Story 6.12: when the
-- revision that goes live changes the time or place of the previous live revision, the linked
-- duties are flagged (the event is locked and published first). Everything else is unchanged.
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
  -- Story 6.12: the live revision before this publication (published or withdrawn).
  v_previous integer;
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
  v_previous := case when v_item.lifecycle_state in ('published', 'withdrawn')
                     then v_item.live_revision_no end;
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
  -- Story 6.12: a changed time or place flags the linked duties for their leaders' review.
  if v_previous is not null and v_previous <> v_no then
    perform app.content_event_flag_duties(v_id, v_no, app.content_event_changes(v_id, v_previous, v_no));
  end if;
  return app.content_item_outcome(v_id, 'event_id');
end;
$$;

-- (Replaced; copied from 20261021233523_content_events_tracer.sql.) Story 6.12: withdrawing a
-- published event flags its linked duties `cancelled` first (still published, item locked).
create or replace function app.content_event_withdraw(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  if v_item.lifecycle_state = 'published' then
    perform app.content_event_flag_duties(v_id, v_item.live_revision_no, array['cancelled']);
  end if;
  perform app.content_item_withdraw(v_item, v_actor.member_id, v_actor.account_id,
                                    v_actor.capacity, 'content.withdraw_event', 'event_id');
  return app.content_item_outcome(v_id, 'event_id');
end;
$$;

-- (Replaced; copied from 20261021233523_content_events_tracer.sql.) Story 6.12: archiving a
-- published event flags its linked duties `cancelled` first (still published, item locked).
create or replace function app.content_event_archive(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  if v_item.lifecycle_state = 'published' then
    perform app.content_event_flag_duties(v_id, v_item.live_revision_no, array['cancelled']);
  end if;
  perform app.content_item_archive(v_item, v_actor.member_id, v_actor.account_id,
                                   v_actor.capacity, 'content.archive_event');
  return app.content_item_outcome(v_id, 'event_id');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Content: how many duties an event's change would flag (editors only, counts only)
-- ---------------------------------------------------------------------------------------------

-- {event_id, linked_duties, reviews_open, truncated} for an event editor: the published
-- department duties that have not started and name the event, and how many of all its linked
-- duties have an open review. Unknown or not an event: {"linked_duties": null}. No duty, rota,
-- department or person is named.
create function app.content_staff_event_duty_links(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_editor record;
  v_links jsonb;
begin
  select e.* into v_editor from app.content_require_editor('event') e;
  if not exists (select 1 from app.content_items i where i.item_id = p_event_id and i.kind = 'event') then
    return jsonb_build_object('event_id', p_event_id, 'linked_duties', null);
  end if;
  if not app.identity_applications_open() then
    return jsonb_build_object('event_id', p_event_id, 'linked_duties', 0, 'reviews_open', 0,
                              'truncated', false);
  end if;
  v_links := app.duties_owner_event_links(jsonb_build_object(
    'source_type', 'content_event', 'source_id', p_event_id));
  return jsonb_build_object(
    'event_id', p_event_id,
    'linked_duties', (select count(*) from jsonb_array_elements(v_links -> 'duties') d
                       where d ->> 'state' = 'published'
                         and (d ->> 'starts_at')::timestamptz > now()),
    'reviews_open', (select count(*) from jsonb_array_elements(v_links -> 'duties') d
                      where (d ->> 'review_open')::boolean),
    'truncated', coalesce((v_links ->> 'truncated')::boolean, false));
end;
$$;

create function api.content_staff_event_duty_links(event_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.content_staff_event_duty_links($1);
$$;

comment on function api.content_staff_event_duty_links(uuid) is
  'Story 6.12: how many duties name an event and how many reviews are open, for event editors '
  '(counts only).';

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.duties_event_ref_error(uuid),
  app.duties_occurrence_event_ref_guard(),
  app.duties_series_event_ref_guard(),
  app.content_event_source_check(jsonb),
  app.content_event_flag_duties(uuid, integer, text[]),
  app.content_event_changes(uuid, integer, integer),
  app.content_staff_event_duty_links(uuid),
  api.content_staff_event_duty_links(uuid)
  from public, anon, authenticated, service_role;

grant execute on function app.content_staff_event_duty_links(uuid) to authenticated;
grant execute on function api.content_staff_event_duty_links(uuid) to authenticated;

notify pgrst, 'reload schema';
