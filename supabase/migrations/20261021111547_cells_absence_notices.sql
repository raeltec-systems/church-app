-- Story 5.7: send Cannot attend notices separately from duty responses (epic 5, C7).
-- Builds on 20261021104522_cells_programme_revisions.sql.
--
--   * A confirmed member tells the cell they cannot attend one meeting (an absence notice), with an
--     optional practical note; they may change the note or withdraw it. Actor and time are kept.
--   * The cell's leader and assistant are told through the inbox (generic text, no name: the page
--     shows who); the staff programme read lists the notices and marks a part whose person sent one
--     (a coverage warning).
--   * A notice never sets a duty response, Excused or any actual attendance: a member with a part is
--     asked to answer it separately in My duties (the clients link it). No attendance table exists
--     (attendance registers are epic 7).
--
-- No destructive statements and no row deletions. No anon grant. ASCII only.

create table app.cells_absence_notices (
  notice_id uuid primary key default gen_random_uuid(),
  meeting_id uuid not null references app.cells_meetings (meeting_id),
  cell_id uuid not null references app.cells_cells (cell_id),
  member_id uuid not null,
  note text check (note is null or length(note) between 1 and 280),
  notice_state text not null default 'open' check (notice_state in ('open', 'withdrawn')),
  revision bigint not null default 1 check (revision >= 1),
  sent_by_account uuid not null,
  sent_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  withdrawn_at timestamptz
);

create unique index cells_absence_notices_open on app.cells_absence_notices (meeting_id, member_id)
  where notice_state = 'open';
create index cells_absence_notices_member on app.cells_absence_notices (member_id);

comment on table app.cells_absence_notices is
  'owner: cells. A member''s Cannot attend notice for one meeting (story 5.7): an intention, never '
  'a duty response or an attendance record. The note is private to the member and the cell''s '
  'leader and assistant.';

create table app.cells_absence_audit (
  event_id bigint generated always as identity primary key,
  action text not null check (action in ('notice_sent', 'notice_changed', 'notice_withdrawn')),
  notice_id uuid not null,
  meeting_id uuid not null,
  cell_id uuid not null,
  actor_member_id uuid not null,
  actor_account_id uuid not null,
  command_request_id uuid,
  revision_after bigint not null check (revision_after >= 1),
  created_at timestamptz not null default now()
);

create index cells_absence_audit_notice on app.cells_absence_audit (notice_id, event_id);

comment on table app.cells_absence_audit is
  'owner: cells. Content-free audit of Cannot attend notices (story 5.7): ids, codes and revisions; '
  'never the note.';

alter table app.cells_absence_notices enable row level security;
alter table app.cells_absence_audit enable row level security;
revoke all on table app.cells_absence_notices, app.cells_absence_audit
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Notifications (3.2 contracts): the leader and assistant are told
-- ---------------------------------------------------------------------------------------------

create function app.cells_absence_source_check(p_source jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select jsonb_build_object('current', n.revision = (p_source ->> 'source_revision')::numeric::bigint,
                              'revision', n.revision)
      from app.cells_absence_notices n where n.notice_id::text = p_source ->> 'source_id'),
    '{"current": false, "revision": null}'::jsonb);
$$;

-- Current: the notice is at the job's revision. Actionable: a sent notice while it is open, a
-- withdrawal while it is withdrawn, and the meeting still ahead. Eligible: the recipient still leads
-- or assists the cell.
create function app.cells_absence_reminder_check(p_key jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_notice app.cells_absence_notices;
  v_current boolean;
begin
  select n.* into v_notice from app.cells_absence_notices n where n.notice_id::text = p_key ->> 'source_id';
  if not found then
    return '{"current": false, "revision": null, "actionable": false, "recipient_eligible": false}'::jsonb;
  end if;
  v_current := v_notice.revision = (p_key ->> 'source_revision')::numeric::bigint;
  return jsonb_build_object(
    'current', v_current,
    'revision', v_notice.revision,
    'actionable', v_current
                  and v_notice.notice_state = case when p_key ->> 'reminder_kind' = 'cells_absence_withdrawn'
                                                   then 'withdrawn' else 'open' end
                  and exists (select 1 from app.cells_meetings m
                               where m.meeting_id = v_notice.meeting_id and m.starts_at > now()
                                 and m.meeting_state in ('scheduled', 'moved')),
    'recipient_eligible', app.cells_programme_capacity((p_key ->> 'recipient_member_id')::uuid,
                                                       v_notice.cell_id) is not null);
end;
$$;

select app.contract_register_source_type(
  'cells', 'cells_absence_notice', 'app.cells_absence_source_check(jsonb)'::regprocedure);
select app.contract_register_reminder_kind('cells', 'cells_absence_notice', 'cells_absence_sent');
select app.contract_register_reminder_contract(
  'cells', 'cells_absence_notice', 'cells_absence_sent',
  'app.cells_absence_reminder_check(jsonb)'::regprocedure,
  '{"title": "Someone can''t attend",
    "body": "A member of your cell can''t come to a meeting. Open Cell meetings to see who and plan for it.",
    "link": "/cells/meetings"}'::jsonb);
select app.contract_register_reminder_kind('cells', 'cells_absence_notice', 'cells_absence_withdrawn');
select app.contract_register_reminder_contract(
  'cells', 'cells_absence_notice', 'cells_absence_withdrawn',
  'app.cells_absence_reminder_check(jsonb)'::regprocedure,
  '{"title": "Can come after all",
    "body": "A member who said they can''t come to a meeting now can. Open Cell meetings to see who.",
    "link": "/cells/meetings"}'::jsonb);

-- The notice to the cell's current leaders and assistants (Notifications last, AD-2).
create function app.cells_absence_notify(p_notice app.cells_absence_notices, p_kind text)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_count integer := 0;
begin
  -- A withdrawal the leaders never heard about the first time is not announced (5.7 review fix 5).
  if p_kind = 'cells_absence_withdrawn'
     and not exists (select 1 from app.notifications_jobs j
                      where j.source_type = 'cells_absence_notice' and j.source_id = p_notice.notice_id
                        and j.reminder_kind = 'cells_absence_sent'
                        and j.job_state not in ('pending', 'cancelled')) then
    perform app.notifications_cancel(jsonb_build_object(
      'source_type', 'cells_absence_notice', 'source_id', p_notice.notice_id, 'reason', 'source_revised'));
    return 0;
  end if;
  -- A change replaces any notice still waiting for the leaders.
  perform app.notifications_cancel(jsonb_build_object(
    'source_type', 'cells_absence_notice', 'source_id', p_notice.notice_id, 'reason', 'source_revised'));
  for v_member in
    select distinct g.member_id from app.identity_grants g
     where g.revoked_at is null and g.scope_kind in ('cell_leader', 'cell_assistant')
       and g.scope_id = p_notice.cell_id and g.member_id <> p_notice.member_id
     order by g.member_id
  loop
    perform app.notifications_enqueue(jsonb_build_object(
      'source_type', 'cells_absence_notice', 'source_id', p_notice.notice_id,
      'source_revision', p_notice.revision, 'recipient_member_id', v_member,
      'reminder_kind', p_kind, 'scheduled_at', app.cmd_utc(now())));
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

create function app.cells_absence_json(p_notice_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('notice_id', n.notice_id, 'meeting_id', n.meeting_id, 'state', n.notice_state,
                            'revision', n.revision, 'note', n.note, 'sent_at', app.cmd_utc(n.sent_at),
                            'updated_at', app.cmd_utc(n.updated_at))
    from app.cells_absence_notices n where n.notice_id = p_notice_id;
$$;

create function app.cells_absence_outcome(p_notice_id uuid, p_notified integer)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('aggregate_type', 'cells_absence_notice', 'aggregate_id', n.notice_id,
                            'revision', n.revision,
                            'data', app.cells_absence_json(n.notice_id) || jsonb_build_object('notified', p_notified))
    from app.cells_absence_notices n where n.notice_id = p_notice_id;
$$;

-- ---------------------------------------------------------------------------------------------
-- Commands (the member themself)
-- ---------------------------------------------------------------------------------------------

-- Locks the actor's own open-or-withdrawn notice for a change or a withdrawal: the meeting first,
-- then the notice. The sender must still be a confirmed member of the meeting's cell and the meeting
-- on and ahead (5.7 review fixes 2 and 3).
create function app.cells_lock_absence(p_payload jsonb, p_member_id uuid)
returns app.cells_absence_notices
language plpgsql
set search_path = ''
as $$
declare
  v_notice app.cells_absence_notices;
  v_meeting app.cells_meetings;
begin
  select n.* into v_notice from app.cells_absence_notices n
   where n.notice_id = (p_payload ->> 'notice_id')::uuid;
  if v_notice.notice_id is null or v_notice.member_id <> p_member_id then
    perform app.cmd_fail('not_found');
  end if;
  select m.* into v_meeting from app.cells_meetings m where m.meeting_id = v_notice.meeting_id for share;
  perform 1 from app.cells_memberships cm
   where cm.cell_id = v_meeting.cell_id and cm.ended_at is null and cm.member_id = p_member_id
     for key share;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  select n.* into v_notice from app.cells_absence_notices n where n.notice_id = v_notice.notice_id for update;
  if v_notice.notice_state = 'withdrawn' then
    perform app.cmd_fail('conflict', '{"notice_id": "withdrawn"}', v_notice.revision);
  end if;
  if v_meeting.meeting_state in ('cancelled', 'withdrawn') then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "cancelled"}');
  end if;
  if v_meeting.starts_at <= now() then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "started"}');
  end if;
  return v_notice;
end;
$$;

-- cells.send_cannot_attend {meeting_id, note?}: a current confirmed member of the meeting's cell,
-- for a meeting on and ahead; expected = null. A second notice while one is open:
-- conflict {"meeting_id": "exists"} (change it with cells.change_cannot_attend).
create function app.cells_send_cannot_attend(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_note record;
  v_meeting app.cells_meetings;
  v_notice app.cells_absence_notices;
  v_notified integer;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['meeting_id', 'note']);
  if app.contract_uuid_error(p_payload -> 'meeting_id') is not null then
    v_errors := v_errors || jsonb_build_object('meeting_id', app.contract_uuid_error(p_payload -> 'meeting_id'));
  end if;
  select * into v_note from app.cells_free_text(p_payload -> 'note', 280, false);
  if v_note.error is not null then
    v_errors := v_errors || jsonb_build_object('note', v_note.error);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  select m.* into v_meeting from app.cells_meetings m
   where m.meeting_id = (p_payload ->> 'meeting_id')::uuid for share;
  if v_meeting.meeting_id is null or v_meeting.meeting_state = 'withdrawn' then
    perform app.cmd_fail('not_found');
  end if;
  -- The membership is held while the notice is written (5.7 review fix 6).
  perform 1 from app.cells_memberships cm
   where cm.cell_id = v_meeting.cell_id and cm.ended_at is null and cm.member_id = v_actor.member_id
     for key share;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_meeting.meeting_state = 'cancelled' then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "cancelled"}');
  end if;
  if v_meeting.starts_at <= now() then
    perform app.cmd_fail('validation_failed', '{"meeting_id": "started"}');
  end if;
  if exists (select 1 from app.cells_absence_notices n
              where n.meeting_id = v_meeting.meeting_id and n.member_id = v_actor.member_id
                and n.notice_state = 'open') then
    perform app.cmd_fail('conflict', '{"meeting_id": "exists"}');
  end if;
  begin
    insert into app.cells_absence_notices (meeting_id, cell_id, member_id, note, sent_by_account)
    values (v_meeting.meeting_id, v_meeting.cell_id, v_actor.member_id, v_note.value, v_actor.account_id)
    returning * into v_notice;
  exception when unique_violation then
    perform app.cmd_fail('conflict', '{"meeting_id": "exists"}');
  end;
  insert into app.cells_absence_audit (action, notice_id, meeting_id, cell_id, actor_member_id,
                                       actor_account_id, command_request_id, revision_after)
  values ('notice_sent', v_notice.notice_id, v_notice.meeting_id, v_notice.cell_id, v_actor.member_id,
          v_actor.account_id, app.cmd_current_request_id(v_actor.account_id, 'cells.send_cannot_attend'), 1);
  v_notified := app.cells_absence_notify(v_notice, 'cells_absence_sent');
  return app.cells_absence_outcome(v_notice.notice_id, v_notified);
end;
$$;

-- cells.change_cannot_attend {notice_id, note?}; the member themself; expected = the notice
-- revision; the meeting still on and ahead. The leaders are told again.
create function app.cells_change_cannot_attend(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_note record;
  v_notice app.cells_absence_notices;
  v_notified integer;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['notice_id', 'note']);
  if app.contract_uuid_error(p_payload -> 'notice_id') is not null then
    v_errors := v_errors || jsonb_build_object('notice_id', app.contract_uuid_error(p_payload -> 'notice_id'));
  end if;
  select * into v_note from app.cells_free_text(p_payload -> 'note', 280, false);
  if v_note.error is not null then
    v_errors := v_errors || jsonb_build_object('note', v_note.error);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  v_notice := app.cells_lock_absence(p_payload, v_actor.member_id);
  if v_notice.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_notice.revision);
  end if;
  update app.cells_absence_notices n
     set note = v_note.value, revision = n.revision + 1, updated_at = now()
   where n.notice_id = v_notice.notice_id
  returning * into v_notice;
  insert into app.cells_absence_audit (action, notice_id, meeting_id, cell_id, actor_member_id,
                                       actor_account_id, command_request_id, revision_after)
  values ('notice_changed', v_notice.notice_id, v_notice.meeting_id, v_notice.cell_id, v_actor.member_id,
          v_actor.account_id, app.cmd_current_request_id(v_actor.account_id, 'cells.change_cannot_attend'),
          v_notice.revision);
  v_notified := app.cells_absence_notify(v_notice, 'cells_absence_sent');
  return app.cells_absence_outcome(v_notice.notice_id, v_notified);
end;
$$;

-- cells.withdraw_cannot_attend {notice_id}; the member themself; expected = the notice revision.
create function app.cells_withdraw_cannot_attend(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_notice app.cells_absence_notices;
  v_notified integer;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['notice_id']);
  if app.contract_uuid_error(p_payload -> 'notice_id') is not null then
    v_errors := v_errors || jsonb_build_object('notice_id', app.contract_uuid_error(p_payload -> 'notice_id'));
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  v_notice := app.cells_lock_absence(p_payload, v_actor.member_id);
  if v_notice.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_notice.revision);
  end if;
  update app.cells_absence_notices n
     set notice_state = 'withdrawn', withdrawn_at = now(), revision = n.revision + 1, updated_at = now()
   where n.notice_id = v_notice.notice_id
  returning * into v_notice;
  insert into app.cells_absence_audit (action, notice_id, meeting_id, cell_id, actor_member_id,
                                       actor_account_id, command_request_id, revision_after)
  values ('notice_withdrawn', v_notice.notice_id, v_notice.meeting_id, v_notice.cell_id, v_actor.member_id,
          v_actor.account_id, app.cmd_current_request_id(v_actor.account_id, 'cells.withdraw_cannot_attend'),
          v_notice.revision);
  v_notified := app.cells_absence_notify(v_notice, 'cells_absence_withdrawn');
  return app.cells_absence_outcome(v_notice.notice_id, v_notified);
end;
$$;


-- Entry point, authorizer and replay scope (replaced from 5.4 and 5.3).
create or replace function app.cells_authorize_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  if coalesce(p_request ->> 'command', '') not in (
       'cells.create_cell', 'cells.update_cell', 'cells.request_change', 'cells.confirm_request',
       'cells.decline_request', 'cells.cancel_request', 'cells.set_schedule', 'cells.move_meeting',
       'cells.cancel_meeting', 'cells.reinstate_meeting', 'cells.set_meeting_reminders',
       'cells.create_programme', 'cells.save_programme', 'cells.cancel_programme',
       'cells.publish_programme', 'cells.send_cannot_attend', 'cells.change_cannot_attend',
       'cells.withdraw_cannot_attend') then
    return false;
  end if;
  select e.* into r from app.identity_evaluate_grant(null, null, null) e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  if r.outcome <> 'granted' then
    return false;
  end if;
  -- 5.4 review fix 4 (AD-2, as Identity locks): the actor's member row, then its grants. Publish
  -- and cancel later share-lock people through Duties; a lifecycle change holding the member row
  -- then waits here instead of deadlocking.
  perform 1 from app.identity_members m where m.member_id = r.member_id for key share;
  perform 1 from app.identity_grants g
   where g.member_id = r.member_id and g.revoked_at is null
     and (g.role = 'admin' or g.scope_kind in ('cell_leader', 'cell_assistant'))
     for share;
  return true;
end;
$$;

create or replace function app.cells_command(p_envelope jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_command text;
  v_result jsonb;
begin
  if jsonb_typeof(p_envelope) = 'object' and jsonb_typeof(p_envelope -> 'command') = 'string' then
    v_command := p_envelope ->> 'command';
  end if;
  -- The running command, for app.cells_meeting_guard (transaction-local, cleared after).
  perform set_config('cells.command', coalesce(v_command, ''), true);
  v_result := app.cmd_execute(
    p_envelope,
    case v_command
      when 'cells.create_cell' then 'app.cells_create_cell(uuid, bigint, jsonb)'::regprocedure
      when 'cells.update_cell' then 'app.cells_update_cell(uuid, bigint, jsonb)'::regprocedure
      when 'cells.request_change' then 'app.cells_request_change(uuid, bigint, jsonb)'::regprocedure
      when 'cells.confirm_request' then 'app.cells_confirm_request(uuid, bigint, jsonb)'::regprocedure
      when 'cells.decline_request' then 'app.cells_decline_request(uuid, bigint, jsonb)'::regprocedure
      when 'cells.cancel_request' then 'app.cells_cancel_request(uuid, bigint, jsonb)'::regprocedure
      when 'cells.set_schedule' then 'app.cells_set_schedule(uuid, bigint, jsonb)'::regprocedure
      when 'cells.move_meeting' then 'app.cells_move_meeting(uuid, bigint, jsonb)'::regprocedure
      when 'cells.cancel_meeting' then 'app.cells_cancel_meeting(uuid, bigint, jsonb)'::regprocedure
      when 'cells.reinstate_meeting' then 'app.cells_reinstate_meeting(uuid, bigint, jsonb)'::regprocedure
      when 'cells.set_meeting_reminders' then 'app.cells_set_meeting_reminders(uuid, bigint, jsonb)'::regprocedure
      when 'cells.create_programme' then 'app.cells_create_programme(uuid, bigint, jsonb)'::regprocedure
      when 'cells.save_programme' then 'app.cells_save_programme(uuid, bigint, jsonb)'::regprocedure
      when 'cells.cancel_programme' then 'app.cells_cancel_programme(uuid, bigint, jsonb)'::regprocedure
      when 'cells.publish_programme' then 'app.cells_publish_programme(uuid, bigint, jsonb)'::regprocedure
      when 'cells.send_cannot_attend' then 'app.cells_send_cannot_attend(uuid, bigint, jsonb)'::regprocedure
      when 'cells.change_cannot_attend' then 'app.cells_change_cannot_attend(uuid, bigint, jsonb)'::regprocedure
      when 'cells.withdraw_cannot_attend' then 'app.cells_withdraw_cannot_attend(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.cells_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'cells.create_cell' and v_command is distinct from 'cells.create_programme'
      and v_command is distinct from 'cells.send_cannot_attend'
  );
  perform set_config('cells.command', '', true);
  return v_result;
end;
$$;

create or replace function app.cells_in_scope(p_actor uuid, p_aggregate_type text, p_aggregate_id uuid)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_cell uuid;
begin
  if p_aggregate_id is null then
    return false;
  end if;
  if p_aggregate_type = 'cells_cell' then
    return exists (select 1 from app.cells_cells c where c.cell_id = p_aggregate_id);
  elsif p_aggregate_type = 'cells_member_cell' then
    return exists (select 1 from app.cells_member_states s where s.member_id = p_aggregate_id);
  elsif p_aggregate_type = 'cells_absence_notice' then
    -- Story 5.7: a notice's replay is for the member who sent it.
    return exists (select 1 from app.cells_absence_notices n
                     join app.identity_evaluate_grant(null, null, null) e on e.outcome = 'granted'
                    where n.notice_id = p_aggregate_id and n.member_id = e.member_id);
  elsif p_aggregate_type in ('cells_meeting', 'cells_meeting_reminders', 'cells_programme') then
    select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
     where e.outcome = 'granted';
    if p_aggregate_type = 'cells_meeting' then
      select m.cell_id into v_cell from app.cells_meetings m where m.meeting_id = p_aggregate_id;
    elsif p_aggregate_type = 'cells_meeting_reminders' then
      select s.cell_id into v_cell from app.cells_meeting_schedules s where s.cell_id = p_aggregate_id;
    else
      -- Story 5.3: a programme replay needs a current leader or assistant of its cell.
      select p.cell_id into v_cell from app.cells_programmes p where p.programme_id = p_aggregate_id;
      return v_member is not null and v_cell is not null
         and app.cells_programme_capacity(v_member, v_cell) is not null;
    end if;
    return v_member is not null and v_cell is not null
       and app.cells_meeting_capacity(v_member, v_cell) is not null;
  end if;
  return false;
end;
$$;

comment on function api.cells_command(jsonb) is
  'Stories 2.6 and 5.1-5.7: cell setup and membership, meeting schedules and exceptions with '
  'their notices, meeting reminders, programmes (create, save, publish and cancel) and Cannot '
  'attend notices (send, change, withdraw) through the 1.4 command envelope.';


-- api.cells_programme (replaced from 5.4): adds `absences` for the cell's leader and assistant.
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
      else '[]'::jsonb end);
end;
$$;

-- api.cells_meeting_programme (replaced from 5.6): adds the reader's own notice (`my_absence`).
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
                     'published_at', app.cmd_utc(v_projection.published_at),
                     -- Story 5.6: the meeting moved since this was published (the leader
                     -- publishes the revision).
                     'meeting_changed', exists (
                       select 1 from app.cells_programmes p
                         left join app.cells_meeting_schedules s on s.cell_id = v_meeting.cell_id
                        where p.programme_id = v_projection.programme_id
                          and (p.published_starts_at, p.published_ends_at, p.published_venue)
                              is distinct from (v_meeting.starts_at, v_meeting.ends_at,
                                                coalesce(v_meeting.moved_venue, s.venue)))) end,
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
      else '[]'::jsonb end,
    -- Story 5.7: the reader's own open Cannot attend notice for this meeting.
    'my_absence', (select app.cells_absence_json(n.notice_id) from app.cells_absence_notices n
                    where n.meeting_id = v_meeting.meeting_id and n.member_id = v_member
                      and n.notice_state = 'open'));
end;
$$;

-- Deletion hook (replaced from 5.4): notices anonymised (no person, no note).
create or replace function app.cells_erase_member(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_input ->> 'member_id')::uuid;
  v_account uuid := nullif(p_input ->> 'account_id', '')::uuid;
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
  v_parts uuid[];
  v_left integer;
begin
  if p_input ->> 'phase' = 'erase' then
    perform app.cells_deletion_purge_rows(v_member);
    if v_account is not null then
      update app.cells_membership_audit a set actor_account_id = v_nil
       where a.actor_account_id = v_account;
      update app.cells_memberships m set confirmed_by_account = v_nil
       where m.confirmed_by_account = v_account;
      update app.cells_membership_requests r set requested_by_account = v_nil
       where r.requested_by_account = v_account;
      update app.cells_membership_requests r set decided_by_account = v_nil
       where r.decided_by_account = v_account;
      update app.cells_meeting_audit a set actor_account_id = v_nil
       where a.actor_account_id = v_account;
      update app.cells_meetings m set changed_by_account = v_nil
       where m.changed_by_account = v_account;
      update app.cells_meeting_schedules s set set_by_account = v_nil
       where s.set_by_account = v_account;
      update app.cells_reminders_audit a set actor_account_id = v_nil
       where a.actor_account_id = v_account;
      update app.cells_programmes p set created_by_account = v_nil where p.created_by_account = v_account;
      update app.cells_programmes p set updated_by_account = v_nil where p.updated_by_account = v_account;
      update app.cells_programmes p set published_by_account = v_nil where p.published_by_account = v_account;
      update app.cells_programme_audit a set actor_account_id = v_nil where a.actor_account_id = v_account;
      update app.cells_absence_notices n set sent_by_account = v_nil where n.sent_by_account = v_account;
      update app.cells_absence_audit a set actor_account_id = v_nil where a.actor_account_id = v_account;
    end if;
    -- Story 5.1: meeting actors are attributed facts; the person is anonymised.
    update app.cells_meeting_audit a set actor_member_id = v_nil where a.actor_member_id = v_member;
    update app.cells_meetings m set changed_by_member = v_nil where m.changed_by_member = v_member;
    update app.cells_meeting_schedules s set set_by_member = v_nil where s.set_by_member = v_member;
    update app.cells_reminders_audit a set actor_member_id = v_nil where a.actor_member_id = v_member;
    -- Story 5.2: a contact need is kept as an anonymous fact.
    update app.cells_meeting_contact_needs n set member_id = v_nil where n.member_id = v_member;
    -- Story 5.7: the member's notices keep no person and no note.
    update app.cells_absence_notices n
       set member_id = v_nil, note = null, notice_state = 'withdrawn',
           withdrawn_at = coalesce(n.withdrawn_at, now())
     where n.member_id = v_member;
    update app.cells_absence_audit a set actor_member_id = v_nil where a.actor_member_id = v_member;
    -- Story 5.4: the member's name leaves every published projection (their parts read as open).
    v_parts := array(select pt.part_id from app.cells_programme_parts pt
                      where pt.assignee_member_id = v_member);
    update app.cells_programme_projections pr
       set body = jsonb_set(pr.body, '{parts}', coalesce((
             select jsonb_agg(case when (t.e ->> 'part_id')::uuid = any (v_parts)
                                   then t.e || '{"leader": null}'::jsonb else t.e end order by t.o)
               from jsonb_array_elements(pr.body -> 'parts') with ordinality t(e, o)), '[]'::jsonb))
     where pr.programme_id in (select pt.programme_id from app.cells_programme_parts pt
                                where pt.part_id = any (v_parts));
    -- Story 5.3: a part the member was planned for becomes a gap; programme actors anonymised.
    update app.cells_programme_parts pt set assignee_member_id = null, updated_at = now()
     where pt.assignee_member_id = v_member;
    update app.cells_programmes p set created_by_member = v_nil where p.created_by_member = v_member;
    update app.cells_programmes p set updated_by_member = v_nil where p.updated_by_member = v_member;
    update app.cells_programmes p set published_by_member = v_nil where p.published_by_member = v_member;
    update app.cells_programme_audit a set actor_member_id = v_nil where a.actor_member_id = v_member;
  end if;
  select (select count(*) from app.cells_memberships m where m.member_id = v_member)
       + (select count(*) from app.cells_membership_requests r where r.member_id = v_member)
       + (select count(*) from app.cells_member_states s where s.member_id = v_member)
       + (select count(*) from app.cells_meeting_audit a where a.actor_member_id = v_member)
       + (select count(*) from app.cells_meetings m where m.changed_by_member = v_member)
       + (select count(*) from app.cells_meeting_schedules s where s.set_by_member = v_member)
       + (select count(*) from app.cells_meeting_contact_needs n where n.member_id = v_member)
       + (select count(*) from app.cells_reminders_audit a where a.actor_member_id = v_member)
       + (select count(*) from app.cells_programme_parts pt where pt.assignee_member_id = v_member)
       + (select count(*) from app.cells_programmes p
           where p.created_by_member = v_member or p.updated_by_member = v_member
              or p.published_by_member = v_member)
       + (select count(*) from app.cells_programme_audit a where a.actor_member_id = v_member)
       + (select count(*) from app.cells_absence_notices n where n.member_id = v_member)
       + (select count(*) from app.cells_absence_audit a where a.actor_member_id = v_member)
       + case when v_account is null then 0 else
           (select count(*) from app.cells_membership_audit a where a.actor_account_id = v_account)
         + (select count(*) from app.cells_memberships m where m.confirmed_by_account = v_account)
         + (select count(*) from app.cells_membership_requests r
             where r.requested_by_account = v_account or r.decided_by_account = v_account)
         + (select count(*) from app.cells_meeting_audit a where a.actor_account_id = v_account)
         + (select count(*) from app.cells_meetings m where m.changed_by_account = v_account)
         + (select count(*) from app.cells_meeting_schedules s where s.set_by_account = v_account)
         + (select count(*) from app.cells_reminders_audit a where a.actor_account_id = v_account)
         + (select count(*) from app.cells_programmes p
             where p.created_by_account = v_account or p.updated_by_account = v_account
                or p.published_by_account = v_account)
         + (select count(*) from app.cells_programme_audit a where a.actor_account_id = v_account)
         + (select count(*) from app.cells_absence_notices n where n.sent_by_account = v_account)
         + (select count(*) from app.cells_absence_audit a where a.actor_account_id = v_account)
         end
    into v_left;
  return jsonb_build_object('remaining', v_left);
end;
$$;

revoke all on function
  app.cells_absence_source_check(jsonb),
  app.cells_absence_reminder_check(jsonb),
  app.cells_absence_notify(app.cells_absence_notices, text),
  app.cells_absence_json(uuid),
  app.cells_lock_absence(jsonb, uuid),
  app.cells_absence_outcome(uuid, integer),
  app.cells_send_cannot_attend(uuid, bigint, jsonb),
  app.cells_change_cannot_attend(uuid, bigint, jsonb),
  app.cells_withdraw_cannot_attend(uuid, bigint, jsonb)
  from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
