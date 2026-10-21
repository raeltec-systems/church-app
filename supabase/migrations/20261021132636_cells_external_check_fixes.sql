-- Story 5.12 external check fixes (epic 5, C9 and C8). Builds on
-- 20261021122802_cells_transfer_effects.sql.
--
--   * Finding 1 (old-cell access): leading or assisting a cell is a grant, separate from
--     membership, so moving a member who leads or assists their current cell left them full private
--     access to it (programme, notices, venue) and its editing. A transfer of such a member is now
--     refused `conflict {"member_id": "leads_current_cell"}` until an Admin removes that role (which
--     runs the 5.9 handover check). Nothing is revoked silently.
--   * Finding 2 (actual leaders): the person recorded as having led a part must have been a member
--     of the cell when the meeting started (not necessarily now), so a member who led and then moved
--     is credited correctly. Someone who was never a member is still named as a guest.
--
-- No destructive statements and no row deletions. No anon grant. ASCII only.


-- cells.confirm_request (replaced from 5.9).
create or replace function app.cells_confirm_request(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_request app.cells_membership_requests;
  v_capacity text;
  v_cell uuid;
  v_old record;
  v_membership uuid;
  v_revision bigint;
  v_sync uuid;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  if app.contract_uuid_error(p_payload -> 'cell_id', true) is not null then
    perform app.cmd_fail('validation_failed',
      jsonb_build_object('cell_id', app.contract_uuid_error(p_payload -> 'cell_id', true)));
  end if;
  -- Story 5.9 review fix 5 (AD-2): the member the transfer may end work of, Identity first.
  if app.contract_uuid_error(p_payload -> 'request_id') is null then
    perform 1 from app.identity_members im
     where im.member_id = (select r.member_id from app.cells_membership_requests r
                            where r.request_id = (p_payload ->> 'request_id')::uuid)
       for key share;
  end if;
  v_request := app.cells_lock_open_request(p_payload, array['request_id', 'cell_id'],
                                           p_expected_revision);
  v_capacity := app.cells_decider(v_actor.member_id, v_actor.is_admin, v_request);
  if v_capacity is null then
    perform app.cmd_fail('forbidden');
  end if;
  -- Separation of duty: nobody confirms their own cell membership.
  if v_request.member_id = v_actor.member_id then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  v_cell := coalesce((p_payload ->> 'cell_id')::uuid, v_request.requested_cell_id);
  if v_cell is null then
    perform app.cmd_fail('validation_failed', '{"cell_id": "required"}');
  end if;
  if v_capacity = 'cell_leader' and v_cell <> v_request.requested_cell_id then
    perform app.cmd_fail('forbidden', '{"cell_id": "unsupported"}');
  end if;
  perform 1 from app.cells_cells c where c.cell_id = v_cell and c.cell_state = 'active' for share;
  if not found then
    perform app.cmd_fail('validation_failed', '{"cell_id": "invalid"}');
  end if;
  select m.membership_id, m.cell_id into v_old
    from app.cells_memberships m
   where m.member_id = v_request.member_id and m.ended_at is null
     for update;
  if v_old.cell_id = v_cell then
    perform app.cmd_fail('validation_failed', '{"cell_id": "current"}');
  end if;
  -- Story 5.12 finding 1: a member who leads or assists their current cell keeps that role (a
  -- grant) after a move, and with it the old cell's private programme, notices and venue. Refuse
  -- until an Admin removes the role (Identity's revocation runs the cells handover check).
  if v_old.membership_id is not null
     and exists (select 1 from app.identity_grants g
                  where g.member_id = v_request.member_id and g.revoked_at is null
                    and g.scope_id = v_old.cell_id and g.scope_kind in ('cell_leader', 'cell_assistant')) then
    perform app.cmd_fail('conflict', '{"member_id": "leads_current_cell"}');
  end if;
  -- End the old primary membership first (one current primary per member).
  if v_old.membership_id is not null then
    update app.cells_memberships m
       set ended_at = now(), end_reason = 'transferred', ended_by_request = v_request.request_id
     where m.membership_id = v_old.membership_id;
  end if;
  insert into app.cells_memberships (member_id, cell_id, request_id, confirmed_by_member,
                                     confirmed_by_account, confirmed_as)
  values (v_request.member_id, v_cell, v_request.request_id, v_actor.member_id, v_actor.account_id,
          v_capacity)
  returning membership_id into v_membership;
  update app.cells_membership_requests r
     set request_state = 'confirmed', decided_at = now(), updated_at = now(),
         decided_by_member = v_actor.member_id, decided_by_account = v_actor.account_id,
         decided_as = v_capacity, resulting_membership_id = v_membership
   where r.request_id = v_request.request_id;
  v_revision := app.cells_bump_member(v_request.member_id);
  perform app.cells_audit('request_confirmed', v_actor.member_id, v_actor.account_id, v_capacity, 'cells.confirm_request',
                          v_request.member_id, v_cell, v_old.cell_id, v_request.request_id,
                          v_membership, null, v_revision);
  perform app.cells_audit(case when v_old.membership_id is null then 'membership_started'
                               else 'membership_transferred' end, v_actor.member_id, v_actor.account_id, v_capacity, 'cells.confirm_request', v_request.member_id,
                          v_cell, v_old.cell_id, v_request.request_id, v_membership, null,
                          v_revision);
  -- Story 5.9: the member's old-cell programme parts, cell duties and notices end now, and the old
  -- cell's leaders are told (Cells and Duties rows, then Notifications).
  if v_old.membership_id is not null then
    perform app.cells_transfer_effects(v_request.member_id, v_old.cell_id, v_actor.member_id,
                                       v_actor.account_id);
  end if;
  if v_old.membership_id is not null then
    -- AD-14: registered owners (duties, chat, follow-ups, programmes ...) move or end their
    -- old-cell obligations inside this transaction; one failing hook rolls the transfer back.
    perform app.contract_dispatch_lifecycle(jsonb_build_object(
      'event', 'cell_transferred',
      'member_id', v_request.member_id,
      'occurred_at', app.cmd_utc(now()),
      'identity_revision', v_revision));
  end if;
  -- Story 5.2 review fix 4, 5.3 review fix 5: meeting reminders follow the membership now
  -- (Notifications last), in cell-id order, and never block the confirmation.
  if app.cells_reminders_available() then
    begin
      for v_sync in
        select c from unnest(array[v_cell, v_old.cell_id]) c where c is not null order by c
      loop
        perform app.cells_sync_meeting_reminders(v_sync);
      end loop;
    exception when sqlstate 'PCMD1' then
      raise log 'cells meeting reminders not planned on a confirmation (sqlstate PCMD1)';
    end;
  end if;
  return app.cells_member_outcome(v_request.member_id);
end;
$$;

-- cells.record_actual_leaders (replaced from 5.8).
create or replace function app.cells_record_actual_leaders(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_meeting app.cells_meetings;
  v_record app.cells_meeting_records;
  v_programme app.cells_programmes;
  v_part app.cells_programme_parts;
  v_current app.cells_actual_leaders;
  v_new app.cells_actual_leaders;
  v_entry jsonb;
  v_leader jsonb;
  v_text record;
  v_kind text;
  v_member uuid;
  v_guest text;
  v_reason text;
  v_seen uuid[] := array[]::uuid[];
  v_changed integer := 0;
  v_request uuid;
  i integer;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['meeting_id', 'parts']);
  if app.contract_uuid_error(p_payload -> 'meeting_id') is not null then
    v_errors := v_errors || jsonb_build_object('meeting_id', app.contract_uuid_error(p_payload -> 'meeting_id'));
  end if;
  if jsonb_typeof(p_payload -> 'parts') is distinct from 'array' then
    v_errors := v_errors || '{"parts": "required"}'::jsonb;
  elsif jsonb_array_length(p_payload -> 'parts') not between 1 and 20 then
    v_errors := v_errors || '{"parts": "count"}'::jsonb;
  else
    for i in 0 .. jsonb_array_length(p_payload -> 'parts') - 1 loop
      v_entry := p_payload -> 'parts' -> i;
      if jsonb_typeof(v_entry) is distinct from 'object' then
        v_errors := v_errors || jsonb_build_object('parts.' || i, 'invalid');
        continue;
      end if;
      v_errors := v_errors || coalesce((
        select jsonb_object_agg('parts.' || i || '.' || k, 'unknown_field')
          from jsonb_object_keys(v_entry) k where k <> all (array['part_id', 'leader', 'reason'])), '{}'::jsonb);
      if app.contract_uuid_error(v_entry -> 'part_id') is not null then
        v_errors := v_errors || jsonb_build_object('parts.' || i || '.part_id',
                                                   app.contract_uuid_error(v_entry -> 'part_id'));
      elsif (v_entry ->> 'part_id')::uuid = any (v_seen) then
        v_errors := v_errors || jsonb_build_object('parts.' || i || '.part_id', 'duplicate');
      else
        v_seen := v_seen || (v_entry ->> 'part_id')::uuid;
      end if;
      if not (v_entry ? 'leader') then
        v_errors := v_errors || jsonb_build_object('parts.' || i || '.leader', 'required');
      else
        v_leader := v_entry -> 'leader';
        if jsonb_typeof(v_leader) = 'null' then
          null;
        elsif jsonb_typeof(v_leader) is distinct from 'object'
              or (select count(*) from jsonb_object_keys(v_leader)) <> 1
              or not (v_leader ? 'member_id' or v_leader ? 'name') then
          v_errors := v_errors || jsonb_build_object('parts.' || i || '.leader', 'invalid');
        elsif v_leader ? 'member_id' and app.contract_uuid_error(v_leader -> 'member_id') is not null then
          v_errors := v_errors || jsonb_build_object('parts.' || i || '.member_id',
                                                     app.contract_uuid_error(v_leader -> 'member_id'));
        elsif v_leader ? 'name' then
          select * into v_text from app.cells_free_text(v_leader -> 'name', 80, false);
          if v_text.error is not null or v_text.value is null then
            v_errors := v_errors || jsonb_build_object('parts.' || i || '.name', coalesce(v_text.error, 'required'));
          end if;
        end if;
      end if;
      select * into v_text from app.cells_free_text(v_entry -> 'reason', 280, false);
      if v_text.error is not null then
        v_errors := v_errors || jsonb_build_object('parts.' || i || '.reason', v_text.error);
      end if;
    end loop;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  -- Meeting, then the record, then the programme (AD-2 order within Cells).
  v_meeting := app.cells_record_meeting(p_payload, v_actor.member_id);
  v_record := app.cells_lock_record(v_meeting.meeting_id, p_expected_revision);
  if not v_record.held then
    perform app.cmd_fail('validation_failed', '{"held": "not_held"}');
  end if;
  select p.* into v_programme from app.cells_programmes p where p.meeting_id = v_meeting.meeting_id for share;
  if v_programme.programme_id is null or v_programme.programme_state = 'cancelled' then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "no_programme"}');
  end if;
  v_request := app.cmd_current_request_id(v_actor.account_id, 'cells.record_actual_leaders');
  for i in 0 .. jsonb_array_length(p_payload -> 'parts') - 1 loop
    v_entry := p_payload -> 'parts' -> i;
    select pt.* into v_part from app.cells_programme_parts pt
     where pt.part_id = (v_entry ->> 'part_id')::uuid and pt.programme_id = v_programme.programme_id
       and pt.removed_at is null;
    if v_part.part_id is null then
      v_errors := v_errors || jsonb_build_object('parts.' || i || '.part_id', 'not_found');
      continue;
    end if;
    v_leader := v_entry -> 'leader';
    v_member := null;
    v_guest := null;
    if jsonb_typeof(v_leader) = 'null' then
      v_kind := 'nobody';
    elsif v_leader ? 'member_id' then
      v_kind := 'member';
      v_member := (v_leader ->> 'member_id')::uuid;
      -- Story 5.12 finding 2: a member of the cell when the meeting started (they may have moved
      -- since); the membership row is held while the record is written.
      perform 1 from app.cells_memberships cm
       where cm.cell_id = v_meeting.cell_id and cm.member_id = v_member
         and cm.started_at <= v_meeting.starts_at
         and (cm.ended_at is null or cm.ended_at > v_meeting.starts_at)
         for key share;
      if not found then
        v_errors := v_errors || jsonb_build_object('parts.' || i || '.member_id', 'not_in_cell');
        continue;
      end if;
    else
      v_kind := 'guest';
      select t.value into v_guest from app.cells_free_text(v_leader -> 'name', 80, false) t;
    end if;
    select t.value into v_reason from app.cells_free_text(v_entry -> 'reason', 280, false) t;
    select a.* into v_current from app.cells_actual_leaders a
     where a.part_id = v_part.part_id and a.superseded_at is null for update;
    if v_current.actual_id is not null
       and v_current.leader_kind = v_kind and v_current.member_id is not distinct from v_member
       and v_current.guest_name is not distinct from v_guest then
      continue;
    end if;
    if v_current.actual_id is not null and v_reason is null then
      v_errors := v_errors || jsonb_build_object('parts.' || i || '.reason', 'required');
      continue;
    end if;
    if v_errors <> '{}'::jsonb then
      continue;
    end if;
    v_new := null;
    if v_current.actual_id is not null then
      update app.cells_actual_leaders a set superseded_at = now(), superseded_by = gen_random_uuid()
       where a.actual_id = v_current.actual_id
      returning a.superseded_by into v_new.actual_id;
    end if;
    insert into app.cells_actual_leaders (actual_id, meeting_id, cell_id, part_id, leader_kind, member_id,
                                          guest_name, planned_member_id, reason, recorded_by_member,
                                          recorded_by_account, command_request_id)
    values (coalesce(v_new.actual_id, gen_random_uuid()), v_meeting.meeting_id, v_meeting.cell_id,
            v_part.part_id, v_kind, v_member, v_guest, v_part.assignee_member_id,
            case when v_current.actual_id is not null then v_reason end,
            v_actor.member_id, v_actor.account_id, v_request);
    v_changed := v_changed + 1;
  end loop;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  if v_changed > 0 then
    update app.cells_meeting_records r
       set revision = r.revision + 1, updated_by_member = v_actor.member_id,
           updated_by_account = v_actor.account_id, updated_at = now()
     where r.meeting_id = v_record.meeting_id;
  end if;
  return jsonb_set(app.cells_record_outcome(v_record.meeting_id), '{data,changed}', to_jsonb(v_changed));
end;
$$;

notify pgrst, 'reload schema';
