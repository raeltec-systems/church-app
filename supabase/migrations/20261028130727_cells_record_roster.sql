-- Review finding F6 (2026-10-28): the historical leader picker must offer a member who was in the
-- cell when the meeting started, though they have since moved to another cell or left.
--
--   * app.cells_programme (replaced from 5.8, 20261021115855) gains one field, `record_roster`:
--     the members whose confirmed membership of the meeting's cell covered the meeting's start
--     (started_at at or before it, and not ended by then), with their display names and whether
--     they are still in the cell. This is the rule the record_actual_leaders write already
--     applies (5.12 finding 2), so the read offers exactly what the write accepts.
--   * Scope: only for the cell's leader and assistant (the readers who may record), only once the
--     meeting has started and was not cancelled (as can_record); otherwise an empty list. The
--     current `roster` (planning, absences and access) is unchanged and no cell access is widened:
--     a former member gains nothing, and these readers already see that member on the record.
--
-- No table, no destructive statement, no row deletion. ASCII only.

-- api.cells_programme (replaced from 5.8): adds record_roster (review finding F6).
create or replace function app.cells_programme(p_meeting_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_meeting app.cells_meetings;
  v_capacity text;
  v_full boolean;
  v_programme app.cells_programmes;
  v_duties jsonb := '[]'::jsonb;
  v_part app.cells_programme_parts;
  v_linkable jsonb;
  v_owner jsonb;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  perform app.cells_require_open_read();
  select m.* into v_meeting from app.cells_meetings m
   where m.meeting_id = p_meeting_id and m.meeting_state <> 'withdrawn';
  v_capacity := app.cells_programme_capacity(v_member, v_meeting.cell_id);
  v_full := v_capacity is not null or app.identity_member_has_role(v_member, 'pastor');
  if v_meeting.meeting_id is null
     or not (v_full or app.identity_member_has_role(v_member, 'admin')) then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  select p.* into v_programme from app.cells_programmes p where p.meeting_id = p_meeting_id;
  if v_capacity is not null then
    if v_programme.programme_state = 'published' then
      for v_part in
        select pt.* from app.cells_programme_parts pt
         where pt.programme_id = v_programme.programme_id and pt.removed_at is null
         order by pt.position
      loop
        v_owner := app.duties_owner_part(jsonb_build_object(
          'source_type', 'cells_programme_part', 'source_id', v_part.part_id,
          'cell_id', v_programme.cell_id));
        v_duties := v_duties || jsonb_build_array(jsonb_build_object(
          'part_id', v_part.part_id,
          'occurrence_state', v_owner #> '{occurrence,state}',
          'positions', v_owner -> 'positions'));
      end loop;
    end if;
    if (v_programme.programme_id is null or v_programme.programme_state = 'draft')
       and v_meeting.meeting_state in ('scheduled', 'moved') and v_meeting.starts_at > now() then
      v_linkable := app.cells_linkable(v_meeting);
    end if;
  end if;
  perform app.identity_record_activity(v_link);
  return jsonb_build_object(
    'meeting', app.cells_meeting_json(v_meeting.meeting_id, v_capacity is not null),
    'cell_name', (select c.name from app.cells_cells c where c.cell_id = v_meeting.cell_id),
    'view', case when v_full then 'full' else 'metadata' end,
    'can_edit', v_capacity is not null,
    'programme', case when v_programme.programme_id is not null
                      then app.cells_programme_json(v_programme.programme_id, v_full) end,
    'preview', case when v_full and v_programme.programme_id is not null
                    then app.cells_programme_projection(v_programme.programme_id) end,
    'published', case when v_full then (
                   select pr.body || jsonb_build_object('revision', pr.revision,
                                                        'published_at', app.cmd_utc(pr.published_at))
                     from app.cells_programme_projections pr
                    where pr.programme_id = v_programme.programme_id and pr.withdrawn_at is null) end,
    'duties', case when v_capacity is not null then v_duties else '[]'::jsonb end,
    'linkable', coalesce(v_linkable, '[]'::jsonb),
    -- Story 5.8: whether the meeting was held and who actually led each part (leader, assistant
    -- and Pastor oversight read; the leader and assistant record once the meeting has started).
    'status', app.cells_meeting_status(v_meeting),
    'record', case when v_full then app.cells_meeting_record_json(v_meeting.meeting_id) end,
    'can_record', v_capacity is not null and v_meeting.meeting_state in ('scheduled', 'moved')
                  and v_meeting.starts_at <= now(),
    -- Story 5.7: open Cannot attend notices, for the cell's leader and assistant only, with the
    -- parts their senders hold (a coverage warning).
    'absences', case when v_capacity is not null then coalesce((
      select jsonb_agg(jsonb_build_object(
               'notice_id', n.notice_id, 'member_id', n.member_id, 'display_name', im.display_name,
               'note', n.note, 'sent_at', app.cmd_utc(n.sent_at), 'updated_at', app.cmd_utc(n.updated_at),
               'part_ids', coalesce((select jsonb_agg(pt.part_id order by pt.position)
                                       from app.cells_programme_parts pt
                                      where pt.programme_id = v_programme.programme_id
                                        and pt.removed_at is null and pt.assignee_member_id = n.member_id),
                                    '[]'::jsonb))
             order by n.sent_at, n.notice_id)
        from app.cells_absence_notices n
        left join app.identity_members im on im.member_id = n.member_id
       where n.meeting_id = v_meeting.meeting_id and n.notice_state = 'open'
         and exists (select 1 from app.cells_memberships cm
                      where cm.cell_id = v_meeting.cell_id and cm.ended_at is null
                        and cm.member_id = n.member_id)), '[]'::jsonb)
      else '[]'::jsonb end,
    'roster', case when v_full then coalesce((
      select jsonb_agg(jsonb_build_object('member_id', cm.member_id, 'display_name', im.display_name,
                                          'account', app.identity_member_account_label(cm.member_id))
                       order by im.display_name collate "C", cm.member_id)
        from app.cells_memberships cm
        join app.identity_members im on im.member_id = cm.member_id
       where cm.cell_id = v_meeting.cell_id and cm.ended_at is null), '[]'::jsonb)
      else '[]'::jsonb end,
    -- Review finding F6: who the recording picker offers, the cell's members when the meeting
    -- started (as record_actual_leaders accepts), for the readers who may record it.
    'record_roster', case when v_capacity is not null and v_meeting.meeting_state in ('scheduled', 'moved')
                               and v_meeting.starts_at <= now() then coalesce((
      select jsonb_agg(jsonb_build_object('member_id', x.member_id, 'display_name', x.display_name,
                                          'account', app.identity_member_account_label(x.member_id),
                                          'in_cell', x.in_cell)
                       order by x.display_name collate "C", x.member_id)
        from (select distinct on (cm.member_id) cm.member_id, im.display_name,
                     exists (select 1 from app.cells_memberships cur
                              where cur.cell_id = v_meeting.cell_id and cur.member_id = cm.member_id
                                and cur.ended_at is null) as in_cell
                from app.cells_memberships cm
                join app.identity_members im on im.member_id = cm.member_id
               where cm.cell_id = v_meeting.cell_id
                 and cm.started_at <= v_meeting.starts_at
                 and (cm.ended_at is null or cm.ended_at > v_meeting.starts_at)
               order by cm.member_id) x), '[]'::jsonb)
      else '[]'::jsonb end);
end;
$$;
