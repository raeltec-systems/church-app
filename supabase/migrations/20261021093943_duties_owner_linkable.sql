-- Story 5.4 (epic 5): a Duties contract change for the first real owner (Cells programmes).
-- The 4.11 consumer guide lists "a discovery read of linkable duties" as a change Duties makes,
-- never a Cells-side workaround. This adds that read; nothing else of Duties changes.
--
--   * app.duties_owner_linkable({cell_id, starts_at, ends_at}): the published, not started,
--     not cancelled department positions whose duty overlaps the window (at most 50, by start),
--     as a cell's leader or assistant may display-link them through app.duties_owner_link_duty.
--     Department, duty and position names, times and whether the position is filled; never a
--     person, note or reason (as the 4.11 display link shows).
--
-- Not client-executable. No destructive statements and no row deletions. ASCII only.

create function app.duties_owner_linkable(p_input jsonb)
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
begin
  if jsonb_typeof(p_input) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"input": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_input, array['cell_id', 'starts_at', 'ends_at']);
  select t.errors, t.value into v_errors, v_cell from app.duties_uuid(p_input, 'cell_id', v_errors) t;
  if app.contract_instant_error(p_input -> 'starts_at') is not null then
    v_errors := v_errors || jsonb_build_object('starts_at', app.contract_instant_error(p_input -> 'starts_at'));
  end if;
  if app.contract_instant_error(p_input -> 'ends_at') is not null then
    v_errors := v_errors || jsonb_build_object('ends_at', app.contract_instant_error(p_input -> 'ends_at'));
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_starts := (p_input ->> 'starts_at')::timestamptz;
  v_ends := (p_input ->> 'ends_at')::timestamptz;
  if v_ends <= v_starts or v_ends - v_starts > interval '1 day' then
    perform app.cmd_fail('validation_failed', '{"ends_at": "out_of_range"}');
  end if;
  perform app.duties_require_open();
  -- The live session must lead or assist the cell (as every cell owner operation requires). A
  -- read takes no lock.
  select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
   where e.outcome = 'granted';
  if v_member is null then
    perform app.cmd_fail('unauthenticated');
  end if;
  if not (app.identity_member_has_scope(v_member, 'cell_leader', v_cell)
          or app.identity_member_has_scope(v_member, 'cell_assistant', v_cell)) then
    perform app.cmd_fail('forbidden');
  end if;
  return coalesce((
    select jsonb_agg(x.obj order by x.starts_at, x.slot_id)
      from (
        select o.starts_at, s.slot_id, jsonb_build_object(
                 'slot_id', s.slot_id,
                 'occurrence_id', o.occurrence_id,
                 'department_id', o.department_id,
                 'department_name', case when not d.is_synthetic
                                           or app.platform_current_environment() in ('local', 'staging')
                                         then d.name end,
                 'duty_name', o.duty_name,
                 'position_name', s.position_name,
                 'starts_at', app.cmd_utc(o.starts_at),
                 'ends_at', case when o.ends_at is not null then app.cmd_utc(o.ends_at) end,
                 'filled', exists (select 1 from app.duties_assignments a
                                    where a.slot_id = s.slot_id and a.assignment_state = 'current'
                                      and a.response <> 'declined')) as obj
          from app.duties_occurrences o
          join app.duties_departments d on d.department_id = o.department_id
          join app.duties_slots s on s.occurrence_id = o.occurrence_id
         where o.department_id is not null
           and d.department_state = 'active'
           and o.occurrence_state = 'published'
           and s.cancelled_at is null
           and app.duties_occurrence_start(o) > now()
           and o.starts_at < v_ends
           and coalesce(o.ends_at, o.starts_at) >= v_starts
         order by o.starts_at, s.slot_id
         limit 50) x), '[]'::jsonb);
end;
$$;

comment on function app.duties_owner_linkable(jsonb) is
  'Story 5.4 contract change (not client-executable): the department positions a cell''s leader '
  'or assistant may display-link for a time window; names, times and filled only, never people.';

revoke all on function app.duties_owner_linkable(jsonb) from public, anon, authenticated, service_role;
