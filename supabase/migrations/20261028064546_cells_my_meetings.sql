-- Epic 6 entry 19 (K12, K5): the member's own cell meetings for the Calendar's My cell overlay.
-- A Cells contract change (recorded in docs/runbooks/cells-meetings.md): one new bounded read,
-- api.cells_my_meetings(), next to api.cells_my_cell(), which is left unchanged (it still answers
-- only the next meeting and the cancelled ones before it).
--
--   * Who: a member with live access (app.identity_require_access) whose current confirmed cell
--     gives them its private access; the Cells read gate (app.cells_require_open_read) applies as on My cell. A guest has no
--     EXECUTE; an account without member access (a Pending applicant) is refused by Identity.
--   * What: only the caller's own confirmed cell, only its meetings that have not ended and start
--     within the next 31 days (the overlay's month), soonest first, at most 62 rows: the meeting
--     id, the nominal church date, the state (scheduled, moved or cancelled; withdrawn dates are
--     left out) and the effective start and end. No venue, map pin, programme, names or counts.
--   * No cell, no confirmed cell or no schedule: `cell_id` null and no meetings.
--   * Generation runs first (as on My cell), so the window is always filled.
--
-- Content (the Calendar) reads nothing of Cells or Duties: the client composes this read and the
-- 4.5 My duties read. No table, no destructive statement, no row deletion. ASCII only.

create function app.cells_my_meetings()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_cell uuid;
  v_from timestamptz := now();
  v_until timestamptz := now() + interval '31 days';
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  perform app.cells_require_open_read();
  select m.cell_id into v_cell from app.cells_memberships m
   where m.member_id = v_member and m.ended_at is null
   order by m.cell_id
   limit 1;
  if v_cell is not null
     and (not app.cells_member_has_private_access(v_member, v_cell)
          or not exists (select 1 from app.cells_meeting_schedules s where s.cell_id = v_cell)) then
    v_cell := null;
  end if;
  if v_cell is not null then
    perform app.cells_generate_meetings(v_cell);
  end if;
  perform app.identity_record_activity(v_link);
  return jsonb_build_object(
    'cell_id', v_cell,
    'from', app.cmd_utc(v_from),
    'until', app.cmd_utc(v_until),
    'meetings', coalesce((
      select jsonb_agg(jsonb_build_object(
                         'meeting_id', x.meeting_id,
                         'occurrence_date', to_char(x.occurrence_date, 'YYYY-MM-DD'),
                         'state', x.meeting_state,
                         'starts_at', app.cmd_utc(x.starts_at),
                         'ends_at', app.cmd_utc(x.ends_at))
                       order by x.starts_at, x.meeting_id)
        from (select m.meeting_id, m.occurrence_date, m.meeting_state, m.starts_at, m.ends_at
                from app.cells_meetings m
               where v_cell is not null
                 and m.cell_id = v_cell
                 and m.meeting_state in ('scheduled', 'moved', 'cancelled')
                 and m.ends_at > v_from
                 and m.starts_at < v_until
               order by m.starts_at, m.meeting_id
               limit 62) x), '[]'::jsonb));
end;
$$;

comment on function app.cells_my_meetings() is
  'Epic 6 entry 19 (Cells contract change): the caller''s own confirmed cell''s meetings that '
  'have not ended and start within 31 days (id, date, state, start, end; no venue) for the '
  'Calendar''s My cell overlay. api.cells_my_cell() is unchanged.';

create function api.cells_my_meetings()
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.cells_my_meetings();
$$;

comment on function api.cells_my_meetings() is
  'Epic 6 entry 19: the signed-in member''s own cell meetings for the next 31 days (dates, '
  'times and cancelled state, no venue) for the Calendar''s My cell overlay.';

revoke all on function app.cells_my_meetings(), api.cells_my_meetings()
  from public, anon, authenticated, service_role;
grant execute on function app.cells_my_meetings() to authenticated;
grant execute on function api.cells_my_meetings() to authenticated;

notify pgrst, 'reload schema';
