-- Story 5.5: show You're on and respond to programme parts on My cell and Home (epic 5, C6).
-- Builds on 20261021094249_cells_programme_publish.sql and 20261021101314_duties_cell_confirmation.sql.
--
--   * api.cells_meeting_programme adds `yours`: the reader's own published parts, each with its
--     Duties occurrence, so the member's app shows that part's actual answer, reporting time and
--     instructions from My duties (the member's own Duties read) and answers through the Duties
--     response commands. Other members' answers are never part of this read.
--   * Leader confirmation for a member without a login is the Duties contract change in
--     20261021101314_duties_cell_confirmation.sql (duties.confirm_by_leader under the cell scope).
--
-- No destructive statements and no row deletions. No anon grant. ASCII only.

create or replace function app.cells_meeting_programme(p_meeting_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_meeting app.cells_meetings;
  v_projection app.cells_programme_projections;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  perform app.cells_require_open_read();
  select m.* into v_meeting from app.cells_meetings m
   where m.meeting_id = p_meeting_id and m.meeting_state <> 'withdrawn';
  if v_meeting.meeting_id is null
     or not exists (select 1 from app.cells_memberships cm
                     where cm.cell_id = v_meeting.cell_id and cm.ended_at is null
                       and cm.member_id = v_member) then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  select pr.* into v_projection from app.cells_programme_projections pr
   where pr.meeting_id = v_meeting.meeting_id and pr.withdrawn_at is null;
  perform app.identity_record_activity(v_link);
  return jsonb_build_object(
    'meeting', app.cells_meeting_json(v_meeting.meeting_id, true),
    'programme', case when v_projection.programme_id is not null then
                   v_projection.body || jsonb_build_object(
                     'revision', v_projection.revision,
                     'published_at', app.cmd_utc(v_projection.published_at)) end,
    -- Story 5.5: the reader's own parts of what is published (named in the projection), with
    -- their Duties occurrence.
    'yours', case when v_projection.programme_id is not null then coalesce((
      select jsonb_agg(jsonb_build_object('part_id', pt.part_id,
                                          'occurrence_id', pt.duty_occurrence_id)
                       order by pt.position)
        from app.cells_programme_parts pt
       where pt.programme_id = v_projection.programme_id and pt.removed_at is null
         and pt.assignee_member_id = v_member and pt.duty_occurrence_id is not null
         and exists (select 1 from jsonb_array_elements(v_projection.body -> 'parts') e
                      where (e ->> 'part_id')::uuid = pt.part_id)), '[]'::jsonb)
      else '[]'::jsonb end);
end;
$$;

comment on function api.cells_meeting_programme(uuid) is
  'Stories 5.4 and 5.5: a meeting''s published programme (member-safe projection) for the current '
  'confirmed members of its cell, with the private venue and the reader''s own parts (`yours`). '
  'No study notes, responses, notes or history.';

notify pgrst, 'reload schema';
