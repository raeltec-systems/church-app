-- Story 4.16: apply the owner's epic 4 decisions (owner-decisions-milestone-2.md, "Duties and
-- Follow-ups decisions (2026-10-15)" items 7, 8 and 10, and "Membership (Q1) production settings"
-- G3). AD-1, AD-2, AD-6, AD-7, AD-14, AD-19. A forward migration: no merged migration is edited.
--
-- What this adds:
--   * Item 7, mismatch notice: when a linked meeting or event change flags department duties for
--     review (4.11 app.duties_owner_flag_review), each reachable, active leader and deputy of each
--     flagged department (app.duties_alert_recipients: held or in-review leaders are left out)
--     other than the person making the change gets one `duties_review` / `duty_review_flagged`
--     notice per department and change ("Duty needs review", link /duties/leader/reviews). Keyed
--     by the department's soonest flagged duty at its flag revision (fresh keys per change, as the
--     4.12 `duty_vacated`). Current while the keyed flag is at that revision or another flag of the
--     same source in the department is still open (reviewing the soonest duty alone does not end
--     it); delivered while any of those open flags is on a published duty that has not started.
--     With the Q2 policy unavailable the flags are kept and the notice is skipped and audited
--     (`reminders_skipped`, `policy_unavailable`). The leader board also lists every duty with an
--     open review beyond its first 200 (review N5).
--   * Item 8, vacancy reason (supersedes the 4.12 "no reason" decision because the owner decided
--     so): app.duties_assignments.vacancy_reason in (removed_from_department, member_inactive,
--     member_deleted), set only with end reason `vacated`. Shown as `vacancy_reason` on the
--     board's history entry and `vacated.reason` in the coverage queue only to the department's
--     leaders and deputies; null for the Admin role alone, Pastor, other leaders and members. No
--     free text, no hold category (a hold never vacates). Erasure keeps the code (a category).
--   * Item 10, last-leader protection on scope revocation (a cross-epic Identity change, reviewed
--     and minimal): identity.revoke_scope now ends the grant without dispatching, calls the
--     registered handover hooks with a `scope_revoked` event (the revoked grant is readable
--     through app.identity_revoked_scope() while they run), refuses `conflict {"member_id":
--     "handover_required"}` when any hook reports a last responsible person (the command's
--     savepoint rolls the grant end back), records the other obligations against the revoked
--     grant (identity_handover_obligations.revoked_grant_id; lifecycle_event_id becomes nullable,
--     exactly one of the two is set), then dispatches scope_revoked as before.
--     app.identity_end_grant keeps its behaviour (its record step is now
--     app.identity_end_grant_record). identity.unlink_account (review S1) runs the same collection
--     for each scope grant it ends but is never refused (a security action): every reported
--     obligation, a Duties `department_leader` included, is recorded pending against the grant. Duties reports a revoked leader or deputy scope of an active
--     department left without any current, active, reachable leader or deputy; Follow-ups reports
--     what the member may no longer hold, never last responsible; the SYNTHETIC fixture reports
--     nothing for a revocation. Deactivation, deletion, unlink and role revocation are unchanged.
--   * G3: app.identity_approve_setting(setting, value, approver, note), restricted operator only
--     (no client grant), inserts the next `approved` version of an Identity setting
--     (`dormancy_days`); the labelled fixture row is untouched. No value is approved here: the
--     production value (180 days) is applied by the operator at promotion
--     (docs/runbooks/production-promotion-identity.md, gate G3).
--
-- Replaced bodies (each copied from its latest version, keeping every earlier review fix; changes
-- are marked "Story 4.16"):
--   from 20261015110202 (4.12): duties_vacate_member, duties_coverage, duties_report_handover,
--     followups_report_handover.
--   from 20261015035112 (4.11): duties_occurrence_json (3-argument), duties_owner_flag_review.
--   from 20261014171038 (4.8): duties_leader_board.
--   from 20261006234820 (2.3): identity_end_grant, identity_revoke_scope.
--   from 20261007063340 (2.5): identity_unlink_account.
--   from 20261007151523 (2.10): fixture_report_handover.
--
-- Lock order (AD-2): Identity rows (the grant set and grant, locked by the revocation; hooks only
-- read) -> Duties departments -> occurrences -> flags -> Follow-ups -> Notifications last.
--
-- ASCII only, no backslashes, no TRUNCATE, no row deletions, no object drops (the one
-- `drop not null` relaxes a constraint, as 20261014052239 did). No new client grant.

-- ---------------------------------------------------------------------------------------------
-- Item 8: the vacancy reason, a code next to the 4.12 vacated state
-- ---------------------------------------------------------------------------------------------

alter table app.duties_assignments
  add column vacancy_reason text,
  add constraint duties_assignments_vacancy_reason
    check (vacancy_reason is null
           or (end_reason = 'vacated'
               and vacancy_reason in ('removed_from_department', 'member_inactive', 'member_deleted')));

comment on column app.duties_assignments.vacancy_reason is
  'Story 4.16: why a vacated position was left (removed_from_department, member_inactive, '
  'member_deleted); shown to the department''s leaders and deputies only. Never free text.';

-- (Replaced, story 4.16; copied from 20261015110202_duties_lifecycle.sql.) Story 4.16: each
-- ended assignment records its coarse vacancy reason (`removed_from_department` for a removal;
-- `member_deleted` when the member's deletion has begun; else `member_inactive`). Everything else
-- (review S1 set-based work, review N5 lock order, one notice per department) is unchanged.
create or replace function app.duties_vacate_member(p_member uuid, p_department uuid, p_code text,
                                         p_release boolean, p_actor_member uuid,
                                         p_actor_account uuid, p_capacity text, p_command text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_occ uuid[];
  v_draft uuid[];
  v_all uuid[];
  v_more uuid[];
  v_ids uuid[];
  v_ended jsonb;
  v_jobs uuid[];
  v_cancels jsonb := '[]'::jsonb;
  v_enqueues jsonb := '[]'::jsonb;
  v_first record;
  v_leader uuid;
  v_alerts integer := 0;
  v_released integer := 0;
  v_drafts integer := 0;
  v_membership uuid;
  v_request uuid := case when p_command is not null
                         then app.cmd_current_request_id(p_actor_account, p_command) end;
  v_notified jsonb;
  -- Story 4.16 (owner item 8): the coarse category leaders and deputies of the department see.
  v_reason text := case when p_code = 'removed' then 'removed_from_department'
                        when exists (select 1 from app.identity_deletions d where d.member_id = p_member)
                          then 'member_deleted'
                        else 'member_inactive' end;
begin
  select coalesce(array_agg(distinct o.occurrence_id), '{}') into v_occ
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where a.member_id = p_member and a.assignment_state = 'current'
     and o.occurrence_state = 'published' and app.duties_occurrence_start(o) > now()
     and (p_department is null or o.department_id = p_department);
  select coalesce(array_agg(distinct o.occurrence_id), '{}') into v_draft
    from app.duties_slots s
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where s.draft_member_id = p_member and o.occurrence_state = 'draft'
     and app.duties_occurrence_start(o) > now()
     and (p_department is null or o.department_id = p_department);
  v_all := v_occ || v_draft;

  -- Lock first, in the commands' AD-2 order (as the 4.10 S1 erase).
  perform 1 from app.duties_departments d
   where d.department_id in (select o.department_id from app.duties_occurrences o
                              where o.occurrence_id = any (v_all))
   order by d.department_id for share;
  perform 1 from app.duties_series r
   where r.series_id in (select o.series_id from app.duties_occurrences o
                          where o.occurrence_id = any (v_all))
   order by r.series_id for share;
  perform 1 from app.duties_occurrences o where o.occurrence_id = any (v_all)
   order by o.series_id nulls last, o.series_date nulls last, o.starts_at, o.occurrence_id
     for update;
  perform 1 from app.duties_slots s where s.occurrence_id = any (v_all)
   order by s.occurrence_id, s.position_no for update;
  perform app.duties_lock_members(array[p_member]);
  -- Review N5: an assignment committed while we waited (a removal; a lifecycle change holds the
  -- member row, so none can appear) has its occurrence and slots locked before any assignment.
  select coalesce(array_agg(distinct s.occurrence_id), '{}') into v_more
    from app.duties_assignments a
    join app.duties_slots s on s.slot_id = a.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
   where a.member_id = p_member and a.assignment_state = 'current'
     and o.occurrence_state = 'published' and app.duties_occurrence_start(o) > now()
     and (p_department is null or o.department_id = p_department)
     and not (s.occurrence_id = any (v_all));
  if cardinality(v_more) > 0 then
    perform 1 from app.duties_occurrences o where o.occurrence_id = any (v_more)
     order by o.series_id nulls last, o.series_date nulls last, o.starts_at, o.occurrence_id
       for update;
    perform 1 from app.duties_slots s where s.occurrence_id = any (v_more)
     order by s.occurrence_id, s.position_no for update;
    v_all := v_all || v_more;
  end if;
  if p_department is not null then
    select dm.membership_id into v_membership from app.duties_department_members dm
     where dm.department_id = p_department and dm.member_id = p_member and dm.ended_at is null
       for update;
    if v_membership is null then
      perform app.cmd_fail('validation_failed', '{"member_id": "not_in_department"}');
    end if;
    update app.duties_department_members dm
       set ended_at = now(), ended_by_member = p_actor_member, ended_by_account = p_actor_account
     where dm.membership_id = v_membership;
  end if;
  select coalesce(array_agg(x.assignment_id order by x.assignment_id), '{}') into v_ids
    from (select a.assignment_id
            from app.duties_assignments a
            join app.duties_slots s on s.slot_id = a.slot_id
            join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
           where a.member_id = p_member and a.assignment_state = 'current'
             and o.occurrence_state = 'published' and app.duties_occurrence_start(o) > now()
             and (p_department is null or o.department_id = p_department)
           order by a.assignment_id
             for update of a) x;

  -- One statement per table.
  with e as (
    update app.duties_assignments a
       set assignment_state = 'superseded', ended_at = now(), end_reason = 'vacated',
           vacancy_reason = v_reason, revision = a.revision + 1
     where a.assignment_id = any (v_ids)
    returning a.assignment_id, a.slot_id, a.revision, a.response)
  select coalesce(jsonb_agg(jsonb_build_object(
           'assignment_id', e.assignment_id, 'slot_id', e.slot_id, 'revision', e.revision,
           'response', e.response, 'occurrence_id', s.occurrence_id, 'department_id', o.department_id,
           'series_id', o.series_id, 'starts_at', o.starts_at) order by e.assignment_id), '[]'::jsonb)
    into v_ended
    from e
    join app.duties_slots s on s.slot_id = e.slot_id
    join app.duties_occurrences o on o.occurrence_id = s.occurrence_id;
  update app.duties_occurrences o set revision = o.revision + 1
   where o.occurrence_id in (select (x ->> 'occurrence_id')::uuid from jsonb_array_elements(v_ended) x)
      or o.occurrence_id in (select s.occurrence_id from app.duties_slots s
                              where s.draft_member_id = p_member and s.occurrence_id = any (v_draft));
  with sr as (
    update app.duties_slots s set revision = s.revision + 1
     where s.slot_id in (select (x ->> 'slot_id')::uuid from jsonb_array_elements(v_ended) x)
    returning s.slot_id, s.revision, s.occurrence_id)
  insert into app.duties_slot_revisions (slot_id, slot_revision, occurrence_id, occurrence_revision,
                                         change_class, changed_fields, duty_name, starts_at, ends_at,
                                         reporting_at, location, instructions, topic, scripture,
                                         event_ref, member_id, assignment_id, response_deadline,
                                         created_by_member, created_by_account, command_request_id)
  select sr.slot_id, sr.revision, o.occurrence_id, o.revision, 'vacated', array['member_id'],
         o.duty_name, o.starts_at, o.ends_at, o.reporting_at, o.location, o.instructions, o.topic,
         o.scripture, o.event_ref, null, null, null, p_actor_member, p_actor_account, v_request
    from sr join app.duties_occurrences o on o.occurrence_id = sr.occurrence_id;
  insert into app.duties_audit (action, actor_member_id, actor_account_id, actor_capacity,
                                command_request_id, department_id, series_id, occurrence_id,
                                assignment_id, member_id, code, revision_after)
  select 'assignment_vacated', p_actor_member, p_actor_account, p_capacity, v_request,
         (x ->> 'department_id')::uuid, (x ->> 'series_id')::uuid, (x ->> 'occurrence_id')::uuid,
         (x ->> 'assignment_id')::uuid, p_member, p_code, (x ->> 'revision')::bigint
    from jsonb_array_elements(v_ended) x;
  -- The member's planned (draft) positions become unplanned, with their planned reason.
  with d as (
    update app.duties_slots s
       set draft_member_id = null, draft_override_reason = null, draft_override_by_member = null,
           draft_override_by_account = null, draft_override_at = null
     where s.draft_member_id = p_member and s.occurrence_id = any (v_draft)
    returning s.occurrence_id)
  insert into app.duties_audit (action, actor_member_id, actor_account_id, actor_capacity,
                                command_request_id, department_id, series_id, occurrence_id,
                                member_id, code)
  select 'draft_cleared', p_actor_member, p_actor_account, p_capacity, v_request, o.department_id,
         o.series_id, o.occurrence_id, p_member, p_code
    from d join app.duties_occurrences o on o.occurrence_id = d.occurrence_id;
  get diagnostics v_drafts = row_count;

  -- Follow-ups: the open coverage cases close `superseded` (their tasks resolved).
  perform pg_catalog.set_config('app.duties_actor', jsonb_build_object(
    'member', p_actor_member, 'account', p_actor_account, 'capacity', p_capacity,
    'command', p_command)::text, true);
  perform app.duties_close_cases(v_ids, 'superseded', p_actor_member, p_actor_account, p_capacity,
                                 p_command);
  -- Notifications last: cancellations only where something is pending.
  select coalesce(array_agg(distinct y.id order by y.id), '{}') into v_jobs
    from (select j.source_id as id from app.notifications_jobs j
           where j.source_type in ('duties_assignment', 'duties_coverage')
             and j.source_id = any (v_ids) and j.job_state = 'pending'
          union
          select sc.source_id from app.notifications_schedules sc
           where sc.source_type = 'duties_assignment' and sc.source_id = any (v_ids)
             and sc.schedule_state = 'active') y;
  select coalesce(jsonb_agg(jsonb_build_object('op', 'cancel', 'source_id', x, 'reason', 'source_revised')
                            order by x), '[]'::jsonb)
    into v_cancels from unnest(v_jobs) x;
  if p_release and app.duties_notice_recipient(p_member) then
    select coalesce(jsonb_agg(jsonb_build_object('op', 'enqueue', 'counts', true,
             'key', jsonb_build_object(
               'source_type', 'duties_assignment', 'source_id', x ->> 'assignment_id',
               'source_revision', (x ->> 'revision')::bigint, 'recipient_member_id', p_member,
               'reminder_kind', 'duty_released', 'scheduled_at', app.cmd_utc(now())))), '[]'::jsonb),
           count(*)
      into v_enqueues, v_released
      from jsonb_array_elements(v_ended) x
     where x ->> 'response' in ('pending', 'accepted');
  end if;
  -- One leaders' notice per department and change, keyed by the soonest ended position the
  -- member had not declined (cell parts get no leader alert: a later contract change).
  for v_first in
    select distinct on (x ->> 'department_id') (x ->> 'department_id')::uuid as department_id,
           x ->> 'assignment_id' as assignment_id, (x ->> 'revision')::bigint as revision
      from jsonb_array_elements(v_ended) x
     where x ->> 'department_id' is not null and x ->> 'response' <> 'declined'
     order by x ->> 'department_id', (x ->> 'starts_at')::timestamptz, x ->> 'assignment_id'
  loop
    foreach v_leader in array app.duties_alert_recipients(v_first.department_id, p_member) loop
      v_enqueues := v_enqueues || jsonb_build_array(jsonb_build_object('op', 'enqueue', 'counts', false,
        'key', jsonb_build_object(
          'source_type', 'duties_coverage', 'source_id', v_first.assignment_id,
          'source_revision', v_first.revision, 'recipient_member_id', v_leader,
          'reminder_kind', 'duty_vacated', 'scheduled_at', app.cmd_utc(now()))));
      v_alerts := v_alerts + 1;
    end loop;
  end loop;
  v_notified := app.duties_lifecycle_notify(v_cancels, v_enqueues, p_actor_member, p_actor_account,
                                            p_capacity, p_command, p_department, p_member);
  return jsonb_build_object('vacated', jsonb_array_length(v_ended), 'drafts_cleared', v_drafts,
                            'leader_alerts', v_alerts, 'released', v_released,
                            'notices_skipped', (v_notified ->> 'skipped')::boolean);
end;
$$;

-- The coarse vacancy reason of an unfilled position (the code of its latest assignment when that
-- ended `vacated` and nobody holds the position now), as app.duties_vacated_since; null otherwise
-- (also for a vacancy recorded before story 4.16). Callers decide who may see it.
create function app.duties_vacancy_reason(p_slot_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select x.vacancy_reason
    from (select a.end_reason, a.vacancy_reason
            from app.duties_assignments a
           where a.slot_id = p_slot_id and a.assignment_state <> 'current'
           order by a.ended_at desc nulls last, a.assignment_id desc
           limit 1) x
   where x.end_reason = 'vacated'
     and not exists (select 1 from app.duties_assignments c
                      where c.slot_id = p_slot_id and c.assignment_state = 'current');
$$;

-- (Replaced, story 4.16; copied from 20261015035112_duties_owner_operations.sql.) Story 4.16: a
-- vacated history entry carries `vacancy_reason` (the code for a viewer, app.duties_viewer, who
-- leads or deputises the duty's department; null for everyone else); other entries are unchanged.
-- The review B1 reason gating is unchanged.
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
                                  'slot_revision', a.slot_revision)
                                -- Story 4.16 (owner item 8): a vacated entry carries the coarse
                                -- vacancy reason, for the department's leaders and deputies only
                                -- (null for the Admin role alone, Pastor, another leader or a
                                -- member); other entries are unchanged.
                                || case when a.end_reason = 'vacated' then jsonb_build_object(
                                     'vacancy_reason',
                                     case when app.duties_manage_capacity(
                                                 nullif(pg_catalog.current_setting('app.duties_viewer', true), '')::uuid,
                                                 o.department_id)
                                               in ('department_leader', 'department_deputy')
                                          then a.vacancy_reason end)
                                   else '{}'::jsonb end as obj
                           from app.duties_assignments a
                          where a.slot_id = s.slot_id and a.assignment_state <> 'current'
                          order by a.ended_at desc, a.assignment_id
                          limit 20) h), '[]'::jsonb))
             order by s.position_no)
        from app.duties_slots s where s.occurrence_id = o.occurrence_id), '[]'::jsonb))
    from app.duties_occurrences o
   where o.occurrence_id = p_occurrence_id;
$$;

-- (Replaced, story 4.16; copied from 20261015110202_duties_lifecycle.sql.) Story 4.16: `vacated`
-- carries `reason` (the coarse category) for the department's leaders and deputies (`full` view);
-- null in the operational view of the Admin role alone and Pastor. Everything else is unchanged.
create or replace function app.duties_coverage(p_from date, p_to date, p_department_id uuid, p_duty text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_admin boolean;
  v_pastor boolean;
  v_zone text;
  v_today date;
  v_from date;
  v_to date;
  v_lo timestamptz;
  v_hi timestamptz;
  v_duty text := nullif(btrim(coalesce(p_duty, '')), '');
  v_departments uuid[];
  v_counts jsonb;
  v_result jsonb;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  v_admin := app.identity_member_has_role(v_member, 'admin');
  v_pastor := app.identity_member_has_role(v_member, 'pastor');
  if not v_admin and not v_pastor
     and not exists (select 1 from app.identity_grants g
                      where g.member_id = v_member and g.revoked_at is null
                        and g.scope_kind in ('department_leader', 'department_deputy')) then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  perform app.duties_require_open_read();
  begin
    v_zone := app.policy_effective('q2_church_time') -> 'value' ->> 'zone';
  exception when sqlstate 'PCMD1' then
    v_zone := null;
  end;
  if v_zone is null or not app.notifications_zone_known(v_zone) then
    -- Church time is Africa/Lusaka (owner decision Q2) when no valid policy zone is in force.
    v_zone := 'Africa/Lusaka';
  end if;
  v_today := (now() at time zone v_zone)::date;
  v_from := coalesce(p_from, v_today);
  v_to := coalesce(p_to, v_from + 6);
  if v_to < v_from or v_to - v_from > 30 or v_from < v_today - 1 or v_from > v_today + 731 then
    raise exception using errcode = 'PT400', message = 'validation_failed', detail = 'window';
  end if;
  if v_duty is not null and (length(v_duty) > 80 or v_duty ~ '[[:cntrl:]]') then
    raise exception using errcode = 'PT400', message = 'validation_failed', detail = 'duty';
  end if;
  v_lo := v_from::timestamp at time zone v_zone;
  v_hi := (v_to + 1)::timestamp at time zone v_zone;
  -- The departments the caller may see: those they lead or deputise, every department for an
  -- Admin (who may manage) and for Pastor oversight. Synthetic departments only in local/staging.
  select coalesce(array_agg(d.department_id), '{}') into v_departments
    from app.duties_departments d
   where (p_department_id is null or d.department_id = p_department_id)
     and (not d.is_synthetic or app.platform_current_environment() in ('local', 'staging'))
     and (v_pastor or app.duties_manage_capacity(v_member, d.department_id) is not null);
  if p_department_id is not null and cardinality(v_departments) = 0 then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  -- The window's overlap counts, computed once (set-based, 4.4).
  v_counts := app.duties_overlap_counts(array(
    select o.occurrence_id from app.duties_occurrences o
     where o.department_id = any (v_departments) and o.occurrence_state = 'published'
       and o.starts_at >= v_lo and o.starts_at < v_hi and app.duties_occurrence_start(o) > now()));

  with cd as (
    -- How the caller sees each department: `full` for its leaders and deputies (scope_kind set),
    -- `operational` for Admin (role alone) and Pastor.
    select d.department_id, d.name,
           case when app.identity_member_has_scope(v_member, 'department_leader', d.department_id)
                  then 'department_leader'
                when app.identity_member_has_scope(v_member, 'department_deputy', d.department_id)
                  then 'department_deputy' end as scope_kind,
           app.duties_manage_capacity(v_member, d.department_id) is not null as can_manage
      from app.duties_departments d
     where d.department_id = any (v_departments)
  ), base as (
    -- Review N5: every position's state (for the counts); the JSON is built below only for the
    -- positions listed (rn <= 1000).
    select o.department_id, o.occurrence_id, o.starts_at, s.slot_id, s.position_no,
           a.assignment_id, a.member_id, c.case_id, l.attempt_id, cd.scope_kind, x.status,
           x.needs_contact, coalesce((v_counts ->> s.slot_id::text)::integer, 0) as overlaps,
           c.case_id is not null and l.next_follow_up_at <= now() as follow_up_overdue,
           -- Story 4.12: when the member who held the position could no longer serve.
           x.vacated_since,
           -- Story 4.16: why, for the department's leaders and deputies only.
           x.vacancy_reason,
           row_number() over (order by o.starts_at, o.occurrence_id, s.position_no) as rn
      from cd
      join app.duties_occurrences o on o.department_id = cd.department_id
      join app.duties_slots s on s.occurrence_id = o.occurrence_id and s.cancelled_at is null
      left join app.duties_assignments a on a.slot_id = s.slot_id and a.assignment_state = 'current'
      left join app.duties_assignments p on p.assignment_id = a.supersedes_assignment_id
      left join app.duties_coverage_cases c on c.assignment_id = a.assignment_id and c.closed_at is null
      left join lateral (select t.* from app.duties_contact_attempts t where t.case_id = c.case_id
                          order by t.recorded_at desc, t.attempt_id limit 1) l on true
      cross join lateral (select
          case when a.assignment_id is null then 'unfilled'
               when a.response = 'accepted' then 'confirmed'
               when a.response = 'declined' then 'declined'
               when a.response_deadline <= now() then 'overdue'
               when p.member_id = a.member_id then 'changed'
               else 'awaiting' end as status,
          case when a.assignment_id is not null then app.duties_needs_contact(a, o) end as needs_contact,
          case when a.assignment_id is null then app.duties_vacated_since(s.slot_id) end as vacated_since,
          case when a.assignment_id is null and cd.scope_kind is not null
               then app.duties_vacancy_reason(s.slot_id) end as vacancy_reason) x
     where o.occurrence_state = 'published' and o.starts_at >= v_lo and o.starts_at < v_hi
       and app.duties_occurrence_start(o) > now()
       and (v_duty is null or position(lower(v_duty) in lower(o.duty_name)) > 0)
  ), pos as (
    select b.department_id, b.member_id, b.status, b.rn,
           jsonb_build_object(
             'slot_id', s.slot_id,
             'position_no', s.position_no,
             'position_name', s.position_name,
             'occurrence_id', o.occurrence_id,
             'occurrence_revision', o.revision,
             'series_id', o.series_id,
             'duty_name', o.duty_name,
             'starts_at', app.cmd_utc(o.starts_at),
             'ends_at', case when o.ends_at is not null then app.cmd_utc(o.ends_at) end,
             'reporting_at', case when o.reporting_at is not null then app.cmd_utc(o.reporting_at) end,
             'location', o.location,
             'positions_left', (select count(*) from app.duties_slots s2
                                 where s2.occurrence_id = o.occurrence_id and s2.cancelled_at is null),
             'status', b.status,
             'needs_contact', b.needs_contact,
             -- Story 4.12.
             'vacated', case when b.vacated_since is not null
                             then jsonb_build_object('since', app.cmd_utc(b.vacated_since),
                                                     -- Story 4.16: null unless the caller leads or
                                                     -- deputises the department.
                                                     'reason', b.vacancy_reason) end,
             'overlaps', coalesce((v_counts ->> s.slot_id::text)::integer, 0),
             'assignment', case when a.assignment_id is not null then jsonb_build_object(
               'assignment_id', a.assignment_id,
               'revision', a.revision,
               'member_id', a.member_id,
               'display_name', app.duties_display_name(a.member_id),
               'account', case when app.identity_member_account_label(a.member_id) = 'no_login'
                               then 'no_login' else 'app_account' end,
               'response', a.response,
               'response_provenance', a.response_provenance,
               'response_deadline', app.cmd_utc(a.response_deadline),
               'deadline_source', a.deadline_source,
               'short_notice', a.short_notice,
               'responded_at', case when a.responded_at is not null then app.cmd_utc(a.responded_at) end,
               'prior_accepted_at', case when a.prior_accepted_at is not null
                                         then app.cmd_utc(a.prior_accepted_at) end,
               'note', case when b.scope_kind is not null then a.response_note end,
               'confirmation', case when a.response_provenance = 'leader' then jsonb_build_object(
                                 'by', app.duties_display_name(a.responded_by_member),
                                 'at', app.cmd_utc(a.responded_at),
                                 'channel', a.confirmed_channel,
                                 'reason', case when b.scope_kind is not null then a.confirmed_reason end) end,
               'changes', case when b.status = 'changed'
                               then to_jsonb(app.duties_changes_since(s.slot_id, a.slot_revision - 1,
                                                                       a.slot_revision)) end) end,
             'follow_up', case when c.case_id is not null then jsonb_build_object(
               'case_id', c.case_id,
               'task_id', case when b.scope_kind is not null then c.task_id end,
               'opened_at', app.cmd_utc(c.opened_at),
               'attempts', (select count(*) from app.duties_contact_attempts t where t.case_id = c.case_id),
               'next_follow_up_at', app.cmd_utc(l.next_follow_up_at),
               'overdue', l.next_follow_up_at <= now(),
               'last_attempt', jsonb_build_object(
                 'at', app.cmd_utc(l.recorded_at),
                 'by', app.duties_display_name(l.recorded_by_member),
                 'channel', l.channel,
                 'outcome', l.outcome,
                 'note', case when b.scope_kind is not null then l.note end)) end) as obj
      from base b
      join app.duties_occurrences o on o.occurrence_id = b.occurrence_id
      join app.duties_slots s on s.slot_id = b.slot_id
      left join app.duties_assignments a on a.assignment_id = b.assignment_id
      left join app.duties_coverage_cases c on c.case_id = b.case_id
      left join app.duties_contact_attempts l on l.attempt_id = b.attempt_id
     where b.rn <= 1000
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from', to_char(v_from, 'YYYY-MM-DD'), 'to', to_char(v_to, 'YYYY-MM-DD'),
                                 'zone', v_zone),
    'duty', v_duty,
    -- At most 1000 positions are listed (soonest first); the counts always cover every one.
    'truncated', (select count(*) > 1000 from base),
    'departments', coalesce((
      select jsonb_agg(jsonb_build_object(
          'department_id', cd.department_id,
          'name', cd.name,
          'view', case when cd.scope_kind is not null then 'full' else 'operational' end,
          'can_manage', cd.can_manage,
          'can_contact', cd.scope_kind is not null,
          'members', case when cd.can_manage then app.duties_roster(cd.department_id, false)
                          else '[]'::jsonb end,
          'counts', (select jsonb_build_object(
                       'required', count(*),
                       'confirmed', count(*) filter (where r.status = 'confirmed'),
                       'unfilled', count(*) filter (where r.status = 'unfilled'),
                       -- Review N8: `changed` counts once, under declined or changed.
                       'awaiting', count(*) filter (where r.status = 'awaiting'),
                       'overdue', count(*) filter (where r.status = 'overdue'),
                       'declined', count(*) filter (where r.status in ('declined', 'changed')),
                       'needs_contact', count(*) filter (where r.needs_contact is not null),
                       'conflicts', count(*) filter (where r.overlaps > 0 and r.status <> 'unfilled'),
                       'overdue_follow_ups', count(*) filter (where r.follow_up_overdue),
                       -- Story 4.12: unfilled positions left by a member who could no longer serve.
                       'vacated', count(*) filter (where r.vacated_since is not null))
                       from base r where r.department_id = cd.department_id),
          -- Contact routes through the scoped Identity read: the department's leaders and
          -- deputies only, for members whose position is not yet confirmed.
          'contact_routes', case when cd.scope_kind is not null then
              app.identity_scoped_contact_routes(v_member, cd.scope_kind, cd.department_id, array(
                select distinct r.member_id from base r
                 where r.department_id = cd.department_id and r.member_id is not null
                   and r.status <> 'confirmed' and r.rn <= 1000))
            else '{}'::jsonb end,
          'positions', coalesce((
            select jsonb_agg(r.obj order by r.rn) from pos r
             where r.department_id = cd.department_id and r.rn <= 1000), '[]'::jsonb))
        order by cd.name, cd.department_id)
        from cd), '[]'::jsonb))
    into v_result;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Item 7: the leaders' review notice (3.2 contract on a new source type `duties_review`)
-- ---------------------------------------------------------------------------------------------

-- Is anything of a review notice's change still open? The key's flag is at that revision, or
-- (review S2) another open flag of the same source in the same department remains on a published
-- duty that has not started. Reviewing the soonest duty alone does not end the department's
-- notice.
create function app.duties_review_key_open(p_flag app.duties_review_flags, p_revision bigint)
returns boolean
language sql
stable
set search_path = ''
as $$
  select (p_flag.revision = p_revision and p_flag.cleared_at is null)
      or exists (select 1
                   from app.duties_review_flags g
                   join app.duties_occurrences o on o.occurrence_id = g.occurrence_id
                  where g.source_type = p_flag.source_type and g.source_id = p_flag.source_id
                    and g.cleared_at is null and g.flag_id <> p_flag.flag_id
                    and o.department_id = (select o2.department_id from app.duties_occurrences o2
                                            where o2.occurrence_id = p_flag.occurrence_id)
                    and o.occurrence_state = 'published'
                    and app.duties_occurrence_start(o) > now());
$$;

-- Source check: current while the change is still open (above). The 3.2 contract requires a
-- current answer to carry the key's revision, so `revision` is the key's while current and the
-- flag's own otherwise.
create function app.duties_review_source_check(p_source jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_flag app.duties_review_flags;
  v_revision bigint := (p_source ->> 'source_revision')::numeric::bigint;
begin
  select f.* into v_flag from app.duties_review_flags f where f.flag_id::text = p_source ->> 'source_id';
  if not found then
    return '{"current": false, "revision": null}'::jsonb;
  end if;
  if app.duties_review_key_open(v_flag, v_revision) then
    return jsonb_build_object('current', true, 'revision', v_revision);
  end if;
  return jsonb_build_object('current', false, 'revision', v_flag.revision);
end;
$$;

-- duty_review_flagged (one per department and change, keyed by the department's soonest flagged
-- duty): current while the change is still open (app.duties_review_key_open: the key's flag at
-- that revision, or another open flag of the source in the department; review S2); actionable
-- while any open flag of the source in that department is on a published duty that has not
-- started; the recipient leads or deputises the department now, is an active member and is
-- reachable in the app.
create function app.duties_review_alert_check(p_key jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_flag app.duties_review_flags;
  v_department uuid;
  v_current boolean;
  v_recipient uuid;
begin
  select f.* into v_flag from app.duties_review_flags f where f.flag_id::text = p_key ->> 'source_id';
  if not found then
    return '{"current": false, "revision": null, "actionable": false, "recipient_eligible": false}'::jsonb;
  end if;
  select o.department_id into v_department from app.duties_occurrences o
   where o.occurrence_id = v_flag.occurrence_id;
  v_current := app.duties_review_key_open(v_flag, (p_key ->> 'source_revision')::numeric::bigint);
  v_recipient := (p_key ->> 'recipient_member_id')::uuid;
  return jsonb_build_object(
    'current', v_current,
    -- The 3.2 contract: a current answer carries the key's revision.
    'revision', case when v_current then (p_key ->> 'source_revision')::numeric::bigint
                     else v_flag.revision end,
    'actionable', v_current and exists (
      select 1
        from app.duties_review_flags g
        join app.duties_occurrences o on o.occurrence_id = g.occurrence_id
       where g.source_type = v_flag.source_type and g.source_id = v_flag.source_id
         and g.cleared_at is null
         and o.department_id = v_department
         and o.occurrence_state = 'published'
         and app.duties_occurrence_start(o) > now()),
    'recipient_eligible', v_department is not null
                          and (app.identity_member_has_scope(v_recipient, 'department_leader', v_department)
                               or app.identity_member_has_scope(v_recipient, 'department_deputy', v_department))
                          and app.duties_member_active(v_recipient)
                          and app.duties_leader_reachable(v_recipient));
end;
$$;

select app.contract_register_source_type(
  'duties', 'duties_review', 'app.duties_review_source_check(jsonb)'::regprocedure);
select app.contract_register_reminder_kind('duties', 'duties_review', 'duty_review_flagged');
select app.contract_register_reminder_contract(
  'duties', 'duties_review', 'duty_review_flagged',
  'app.duties_review_alert_check(jsonb)'::regprocedure,
  '{"title": "Duty needs review",
    "body": "Something a duty in your department is linked to has changed. Open the Duties board to review it.",
    "link": "/duties/leader/reviews"}'::jsonb);

-- (Replaced, story 4.16; copied from 20261015035112_duties_owner_operations.sql.) Story 4.16:
-- after the flags are written, the leaders' notice `duty_review_flagged` (one per department and
-- change). The flags, their merge and their audit are unchanged.
create or replace function app.duties_owner_flag_review(p_input jsonb)
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
  -- Story 4.16: the flags this change wrote, for the leaders' notice.
  v_flagged jsonb := '[]'::jsonb;
  v_first record;
  v_leader uuid;
  v_enqueues jsonb;
  v_capacity text;
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
    v_flagged := v_flagged || jsonb_build_array(jsonb_build_object(
      'flag_id', v_flag.flag_id, 'revision', v_flag.revision,
      'department_id', (select o.department_id from app.duties_occurrences o where o.occurrence_id = v_occ),
      'starts_at', (select app.duties_occurrence_start(o) from app.duties_occurrences o
                     where o.occurrence_id = v_occ)));
    perform app.duties_audit_series_event('review_flagged', v_actor.member_id, v_actor.account_id,
                                          case when v_role = 'cell_part' then v_actor.capacity
                                               else 'member' end,
                                          v_cmd,
                                          (select o.department_id from app.duties_occurrences o
                                            where o.occurrence_id = v_occ),
                                          null, v_occ, null, null, null, v_flag.revision);
  end loop;
  -- Story 4.16 (owner item 7): one notice per department and change to each reachable leader and
  -- deputy other than the actor (held or in-review leaders are left out, 4.8), keyed by the department's soonest
  -- flagged duty at its flag revision (fresh keys), Notifications last. With the Q2 policy
  -- unavailable the flags stay and the notice is skipped and audited (`reminders_skipped`).
  v_capacity := case when v_role = 'cell_part' then v_actor.capacity else 'member' end;
  for v_first in
    select distinct on (x ->> 'department_id') (x ->> 'department_id')::uuid as department_id,
           x ->> 'flag_id' as flag_id, (x ->> 'revision')::bigint as revision
      from jsonb_array_elements(v_flagged) x
     where x ->> 'department_id' is not null
     order by x ->> 'department_id', (x ->> 'starts_at')::timestamptz, x ->> 'flag_id'
  loop
    v_enqueues := '[]'::jsonb;
    -- Review N4: never the person whose change it is.
    foreach v_leader in array app.duties_alert_recipients(v_first.department_id, v_actor.member_id) loop
      v_enqueues := v_enqueues || jsonb_build_array(jsonb_build_object('op', 'enqueue', 'counts', false,
        'key', jsonb_build_object(
          'source_type', 'duties_review', 'source_id', v_first.flag_id,
          'source_revision', v_first.revision, 'recipient_member_id', v_leader,
          'reminder_kind', 'duty_review_flagged', 'scheduled_at', app.cmd_utc(now()))));
    end loop;
    perform app.duties_lifecycle_notify(null, v_enqueues, v_actor.member_id, v_actor.account_id,
                                        v_capacity, v_cmd, v_first.department_id, null);
  end loop;
  return jsonb_build_object('flagged', v_flags);
end;
$$;

-- (Replaced, story 4.16; copied from 20261014171038_duties_reminders.sql.) Review N5: the board
-- also lists every duty with an open owner review beyond the first 200 (the reviews view opened by
-- the review notice is complete). Everything else, the viewer setting and `duties_truncated`, is
-- unchanged.
create or replace function app.duties_leader_board()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_admin boolean;
  v_pastor boolean;
  v_result jsonb;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  v_admin := app.identity_member_has_role(v_member, 'admin');
  v_pastor := app.identity_member_has_role(v_member, 'pastor');
  if not v_admin and not v_pastor
     and not exists (select 1 from app.identity_grants g
                      where g.member_id = v_member and g.revoked_at is null
                        and g.scope_kind in ('department_leader', 'department_deputy')) then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  perform app.duties_require_open_read();
  -- Story 4.4: an override about the viewer's own assignment hides its reason.
  perform pg_catalog.set_config('app.duties_viewer', v_member::text, true);
  select jsonb_build_object('departments', coalesce(jsonb_agg(x.obj order by x.name, x.department_id),
                                                    '[]'::jsonb))
    into v_result
    from (
      select d.department_id, d.name, c.capacity, jsonb_build_object(
               'department_id', d.department_id,
               'name', d.name,
               'capacity', coalesce(c.capacity, 'pastor'),
               'can_publish', c.capacity is not null,
               'members', app.duties_roster(d.department_id, false),
               -- Story 4.8 review fix 3: notices still to pass on in person (managers only).
               'contact_notices', case when c.capacity is not null
                                       then app.duties_contact_notices(d.department_id)
                                       else '[]'::jsonb end,
               -- Story 4.16 (review N5): the first 200 duties as before, plus every duty with an
               -- open owner review that has not started (the review notice's list is complete);
               -- the overlap counts are computed once over the duties listed.
               'duties', coalesce((
                 select jsonb_agg(app.duties_occurrence_json(o.occurrence_id, c.capacity is not null,
                                                             sel.counts)
                                  order by o.starts_at, o.occurrence_id)
                   from app.duties_occurrences o
                  where o.occurrence_id = any (sel.ids)), '[]'::jsonb),
               'duties_truncated', (select count(*) > 200 from app.duties_occurrences o3
                                     where o3.department_id = d.department_id
                                       and o3.occurrence_state = 'published'
                                       and o3.starts_at > now() - interval '30 days')) as obj
        from app.duties_departments d
        cross join lateral (select app.duties_manage_capacity(v_member, d.department_id) as capacity) c
        cross join lateral (
          select s.ids, app.duties_overlap_counts(s.ids) as counts
            from (select array(
                    select x.occurrence_id from (
                      (select o2.occurrence_id from app.duties_occurrences o2
                        where o2.department_id = d.department_id
                          and o2.occurrence_state = 'published'
                          and o2.starts_at > now() - interval '30 days'
                        order by o2.starts_at limit 200)
                      union
                      select o5.occurrence_id from app.duties_occurrences o5
                       where o5.department_id = d.department_id
                         and o5.occurrence_state = 'published'
                         and app.duties_occurrence_start(o5) > now()
                         and exists (select 1 from app.duties_review_flags f
                                      where f.occurrence_id = o5.occurrence_id
                                        and f.cleared_at is null)) x) as ids) s
           -- A fence: the counts are computed once per department, never per listed duty.
           offset 0) sel
       where (c.capacity is not null or v_pastor)
         and (not d.is_synthetic or app.platform_current_environment() in ('local', 'staging'))
    ) x;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Item 10: handover obligations a scope revocation records (Identity, cross-epic)
-- ---------------------------------------------------------------------------------------------

-- An obligation comes from a membership lifecycle event (2.10, 2.11) or, from story 4.16, from a
-- revoked scope grant: exactly one of the two is set. Every reader keys on member, owner, kind
-- and subject only, so existing reads are unchanged.
alter table app.identity_handover_obligations
  alter column lifecycle_event_id drop not null,
  add column revoked_grant_id uuid references app.identity_grants (grant_id),
  add constraint identity_handover_obligations_origin
    check ((lifecycle_event_id is null) <> (revoked_grant_id is null));

comment on column app.identity_handover_obligations.revoked_grant_id is
  'Story 4.16: the revoked scope grant whose revocation recorded this obligation (else the '
  'lifecycle event did).';

create index identity_handover_obligations_grant
  on app.identity_handover_obligations (revoked_grant_id) where revoked_grant_id is not null;

-- The scope grant identity.revoke_scope is revoking while it calls the handover hooks (a
-- transaction-local setting, cleared after the call): {scope_kind, scope_id}, or no row.
create function app.identity_revoked_scope()
returns table (scope_kind text, scope_id uuid)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_text text := nullif(pg_catalog.current_setting('identity.revoked_grant', true), '');
begin
  if v_text is null
     or v_text !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return;
  end if;
  return query
    select g.scope_kind, g.scope_id from app.identity_grants g
     where g.grant_id = v_text::uuid and g.scope_kind is not null;
end;
$$;

comment on function app.identity_revoked_scope() is
  'Story 4.16: the scope being revoked, readable by handover hooks during identity.revoke_scope.';

-- Story 4.16: the record step of app.identity_end_grant (copied from 20261006234820, unchanged):
-- attribution, revision and audit. Returns the new grant-set revision. The revocation command
-- calls it before the handover hooks and dispatches scope_revoked itself.
create function app.identity_end_grant_record(
  p_actor uuid,
  p_actor_member uuid,
  p_command text,
  p_grant app.identity_grants
) returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_revision bigint;
begin
  update app.identity_grants g
     set revoked_at = now(), revoked_by_member = p_actor_member, revoked_by_account = p_actor
   where g.grant_id = p_grant.grant_id;
  v_revision := app.identity_bump_grant_set(p_grant.member_id);
  insert into app.identity_access_audit (action, actor_kind, actor_member_id, actor_account_id,
                                         request_id, target_member_id, grant_id, role,
                                         scope_kind, scope_id, revision_after)
  values (case when p_grant.role is not null then 'role_revoked' else 'scope_revoked' end,
          'member', p_actor_member, p_actor, app.cmd_current_request_id(p_actor, p_command),
          p_grant.member_id, p_grant.grant_id, p_grant.role, p_grant.scope_kind,
          p_grant.scope_id, v_revision);
  return v_revision;
end;
$$;

-- (Replaced, story 4.16; copied from 20261006234820_identity_grants.sql.) Same behaviour: the
-- record step moved to app.identity_end_grant_record, then the scope_revoked dispatch.
create or replace function app.identity_end_grant(
  p_actor uuid,
  p_actor_member uuid,
  p_command text,
  p_grant app.identity_grants
) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_revision bigint;
begin
  v_revision := app.identity_end_grant_record(p_actor, p_actor_member, p_command, p_grant);
  -- Owners registered for scope_revoked run inside this transaction (AD-14 hook seam).
  perform app.contract_dispatch_lifecycle(jsonb_build_object(
    'event', 'scope_revoked',
    'member_id', p_grant.member_id,
    'occurred_at', app.cmd_utc(now()),
    'identity_revision', v_revision));
end;
$$;

-- Story 4.16: the scope_revoked lifecycle event of a member at a grant-set revision.
create function app.identity_scope_revoked_event(p_member_id uuid, p_revision bigint)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('event', 'scope_revoked', 'member_id', p_member_id,
                            'occurred_at', app.cmd_utc(now()), 'identity_revision', p_revision);
$$;

-- Story 4.16: asks every registered handover hook what an ENDED scope grant leaves (the grant was
-- recorded as ended, not yet dispatched), with the grant readable through
-- app.identity_revoked_scope() during the call. Returns the obligations (the 2.10 shape).
create function app.identity_collect_revocation_handover(p_grant app.identity_grants,
                                                         p_revision bigint)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_obligations jsonb;
begin
  perform pg_catalog.set_config('identity.revoked_grant', p_grant.grant_id::text, true);
  v_obligations := app.identity_collect_handover(
    app.identity_scope_revoked_event(p_grant.member_id, p_revision));
  perform pg_catalog.set_config('identity.revoked_grant', '', true);
  return v_obligations;
end;
$$;

-- Story 4.16: records reported obligations pending against the revoked grant (one pending
-- obligation per member, owner, kind and subject). Returns how many were recorded.
create function app.identity_record_revocation_obligations(p_grant app.identity_grants,
                                                           p_obligations jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_count integer;
begin
  insert into app.identity_handover_obligations (member_id, revoked_grant_id, owner_module,
                                                 obligation_kind, subject_id)
  select p_grant.member_id, p_grant.grant_id, x.value ->> 'module', x.value ->> 'kind',
         (x.value ->> 'subject_id')::uuid
    from jsonb_array_elements(coalesce(p_obligations, '[]'::jsonb)) x
  on conflict (member_id, owner_module, obligation_kind, subject_id)
     where obligation_state = 'pending' do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- (Replaced, story 4.16; copied from 20261006234820_identity_grants.sql.) Story 4.16: the
-- revocation collects the registered handover hooks (owner item 10). The lock order, the
-- conflict on a missing grant and the outcome are unchanged.
create or replace function app.identity_revoke_scope(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_set app.identity_grant_sets;
  v_scope record;
  v_grant app.identity_grants;
  v_revision bigint;
  v_obligations jsonb;
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_set := app.identity_lock_grant_set(p_payload, array['member_id', 'scope_kind', 'scope_id'],
                                       p_expected_revision);
  select sp.* into v_scope from app.identity_scope_payload(p_payload) sp;
  select g.* into v_grant from app.identity_grants g
   where g.member_id = v_set.member_id and g.scope_kind = v_scope.scope_kind
     and g.scope_id = v_scope.scope_id and g.revoked_at is null
     for update;
  if not found then
    perform app.cmd_fail('conflict', null, v_set.revision);
  end if;
  -- Story 4.16 (owner item 10): the grant ends first (not yet dispatched), so owners report what
  -- the member is responsible for WITHOUT this scope; a last responsible person refuses the
  -- revocation (`handover_required`; the command's savepoint rolls the end back, nothing is
  -- written), the other obligations are recorded against the grant, then scope_revoked is
  -- dispatched (AD-14), as identity_end_grant does.
  v_revision := app.identity_end_grant_record(p_actor, v_actor.member_id, 'identity.revoke_scope',
                                              v_grant);
  v_obligations := app.identity_collect_revocation_handover(v_grant, v_revision);
  if exists (select 1 from jsonb_array_elements(v_obligations) x
              where (x.value ->> 'last_responsible')::boolean) then
    perform app.cmd_fail('conflict', '{"member_id": "handover_required"}', v_set.revision);
  end if;
  perform app.identity_record_revocation_obligations(v_grant, v_obligations);
  perform app.contract_dispatch_lifecycle(app.identity_scope_revoked_event(v_grant.member_id, v_revision));
  return app.identity_grant_outcome(v_set.member_id);
end;
$$;

-- (Replaced, story 4.16; copied from 20261007151523_membership_lifecycle.sql.) Story 4.16: the
-- SYNTHETIC fixture reports nothing for a scope revocation (its duties are not scope-bound), so a
-- test that registers it is unchanged by the new revocation hook call.
create or replace function app.fixture_report_handover(p_event jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('obligations', coalesce(jsonb_agg(
           jsonb_build_object('kind', d.duty_kind, 'subject_id', d.duty_id,
                              'last_responsible', d.sole_responsible)
           order by d.created_at, d.duty_id), '[]'::jsonb))
    from app.fixture_duties d
   where d.member_id = (p_event ->> 'member_id')::uuid
     -- Story 4.16: the fixture's duties do not depend on a scope.
     and p_event ->> 'event' is distinct from 'scope_revoked';
$$;

-- (Replaced, story 4.16; copied from 20261015110202_duties_lifecycle.sql.) Read only. For a
-- lifecycle change (unchanged): the active departments the member leads or deputises where nobody
-- else approved and reachable in the app holds the leader or deputy scope. Story 4.16 (owner item
-- 10): for a revoked scope (identity.revoke_scope; the grant has already ended), the revoked
-- leader or deputy scope's active department when no current, active, reachable leader or deputy
-- remains (the member's own remaining grant counts). Always last responsible.
create or replace function app.duties_report_handover(p_event jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('obligations', coalesce(jsonb_agg(jsonb_build_object(
           'kind', 'department_leader', 'subject_id', x.department_id, 'last_responsible', true)
           order by x.department_id), '[]'::jsonb))
    from (
      select d.department_id
        from app.duties_departments d
       where d.department_state = 'active'
         and p_event ->> 'event' is distinct from 'scope_revoked'
         and exists (select 1 from app.identity_grants g
                      where g.member_id = (p_event ->> 'member_id')::uuid and g.revoked_at is null
                        and g.scope_id = d.department_id
                        and g.scope_kind in ('department_leader', 'department_deputy'))
         and not exists (select 1 from app.identity_grants g
                          where g.member_id <> (p_event ->> 'member_id')::uuid and g.revoked_at is null
                            and g.scope_id = d.department_id
                            and g.scope_kind in ('department_leader', 'department_deputy')
                            and app.duties_member_active(g.member_id)
                            and app.duties_leader_reachable(g.member_id))
      union
      select d.department_id
        from app.identity_revoked_scope() r
        join app.duties_departments d on d.department_id = r.scope_id
       where p_event ->> 'event' = 'scope_revoked'
         and r.scope_kind in ('department_leader', 'department_deputy')
         and d.department_state = 'active'
         and not app.duties_has_reachable_leader(d.department_id)) x;
$$;

-- (Replaced, story 4.16; copied from 20261015110202_duties_lifecycle.sql.) Story 4.16: for a
-- revoked scope (the grant has already ended) the plan is the active member's (what they may no
-- longer own or supervise, review R1 keeping roster), and a task is never last responsible: a
-- revocation narrows access, and a task nobody can take stays listed for the Admin as in 4.12.
create or replace function app.followups_report_handover(p_event jsonb)
returns jsonb
language sql
set search_path = ''
as $$
  with p as (select * from app.followups_handover_plan((p_event ->> 'member_id')::uuid,
                                                     p_event ->> 'event' is distinct from 'scope_revoked'))
  select jsonb_build_object('obligations', coalesce(jsonb_agg(x.o order by x.kind, x.task_id), '[]'::jsonb))
    from (
      select 1 as kind, p.task_id,
             jsonb_build_object('kind', 'followup_task', 'subject_id', p.task_id,
                                'last_responsible', p.owner_to is null
                                                    and p_event ->> 'event' is distinct from 'scope_revoked') as o
        from p where p.owner_due
      union all
      select 2, p.task_id,
             jsonb_build_object('kind', 'followup_supervision', 'subject_id', p.task_id,
                                'last_responsible', false)
        from p
       where p.supervisor_due and p.supervisor_from = (p_event ->> 'member_id')::uuid
         and p.supervisor_to is null) x;
$$;

-- (Replaced, story 4.16; copied from 20261007063340_membership_review.sql.) Review S1: each
-- ended scope grant records what it leaves through the handover hooks (never refused); roles end
-- as before. Everything else (validation, the last-Admin rule, link end, audit, dispatch) is
-- unchanged.
create or replace function app.identity_unlink_account(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_err text;
  v_member app.identity_members;
  v_link app.identity_account_links;
  v_grant app.identity_grants;
  v_revision bigint;
  v_grant_revision bigint;
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, array['member_id', 'reason']);
  v_err := app.contract_uuid_error(p_payload -> 'member_id');
  if v_err is not null then
    v_errors := v_errors || jsonb_build_object('member_id', v_err);
  end if;
  if coalesce(jsonb_typeof(p_payload -> 'reason'), 'null') = 'null' then
    v_errors := v_errors || '{"reason": "required"}';
  elsif jsonb_typeof(p_payload -> 'reason') <> 'string'
        or p_payload ->> 'reason' not in ('account_lost', 'ownership_dispute', 'member_request',
                                          'phone_reclaim') then
    v_errors := v_errors || '{"reason": "invalid"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  if (p_payload ->> 'member_id')::uuid = v_actor.member_id then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  select m.* into v_member from app.identity_members m
   where m.member_id = (p_payload ->> 'member_id')::uuid
     for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_member.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_member.revision);
  end if;
  select l.* into v_link from app.identity_account_links l
   where l.member_id = v_member.member_id and l.link_state <> 'ended'
     for update;
  if not found then
    perform app.cmd_fail('conflict', '{"member_id": "not_linked"}', v_member.revision);
  end if;
  -- The church is never left without a usable Admin (bootstrap is the recovery route).
  if exists (select 1 from app.identity_grants g
              where g.member_id = v_member.member_id and g.role = 'admin' and g.revoked_at is null)
     and app.identity_usable_admin_count(v_member.member_id) = 0 then
    perform app.cmd_fail('forbidden', '{"member_id": "last_admin"}');
  end if;
  -- Grants never travel with a link: every active grant ends through the 2.3 path (role_revoked
  -- / scope_revoked audit with this Admin, scope_revoked dispatched).
  for v_grant in
    select g.* from app.identity_grants g
     where g.member_id = v_member.member_id and g.revoked_at is null
     order by g.granted_at, g.grant_id
       for update
  loop
    if v_grant.scope_kind is null then
      perform app.identity_end_grant(p_actor, v_actor.member_id, 'identity.unlink_account', v_grant);
    else
      -- Story 4.16 (review S1): an unlink is a security action and is never refused, but what an
      -- ended scope leaves (a department with no reachable leader or deputy, tasks the member may
      -- no longer hold) is recorded as pending obligations against the grant, as a deletion
      -- records them, so the Admin sees the department needs a leader (Membership status,
      -- Departments). Then scope_revoked is dispatched as before.
      v_grant_revision := app.identity_end_grant_record(p_actor, v_actor.member_id,
                                                        'identity.unlink_account', v_grant);
      perform app.identity_record_revocation_obligations(
        v_grant, app.identity_collect_revocation_handover(v_grant, v_grant_revision));
      perform app.contract_dispatch_lifecycle(
        app.identity_scope_revoked_event(v_grant.member_id, v_grant_revision));
    end if;
  end loop;
  update app.identity_account_links l
     set link_state = 'ended', ended_at = now(), updated_at = now()
   where l.link_id = v_link.link_id;
  update app.identity_members m
     set revision = m.revision + 1, updated_at = now()
   where m.member_id = v_member.member_id
  returning m.revision into v_revision;
  insert into app.identity_membership_audit (action, actor_member_id, actor_account_id, request_id,
                                             member_id, link_id, target_account_id, reason_code,
                                             revision_after)
  values ('account_unlinked', v_actor.member_id, v_actor.account_id,
          app.cmd_current_request_id(p_actor, 'identity.unlink_account'), v_member.member_id,
          v_link.link_id, v_link.auth_user_id, p_payload ->> 'reason', v_revision);
  perform app.contract_dispatch_lifecycle(jsonb_build_object(
    'event', 'account_deactivated',
    'member_id', v_member.member_id,
    'occurred_at', app.cmd_utc(now()),
    'identity_revision', v_revision));
  return app.identity_member_outcome(v_member.member_id);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- G3: the operator path to approve an Identity setting (dormancy_days)
-- ---------------------------------------------------------------------------------------------

-- Restricted operator only (no client grant, as app.policy_approve and
-- app.identity_approve_church_setting): records the owner's approved value as the next version
-- with `source = 'approved'`. The labelled TEST FIXTURE row is left as it is (an approved row wins
-- over it in app.identity_setting; production never honours a fixture). Refusals: 42501 (not an
-- active restricted operator), 22023 (unknown setting, missing or fixture-labelled decision note,
-- a value that is not a plain object or out of range). Audited `church_setting_approved` with the
-- setting name in app.identity_access_audit and in the operator journal.
create function app.identity_approve_setting(
  p_setting text,
  p_value jsonb,
  p_approver text,
  p_note text
) returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_version integer;
begin
  perform app.ops_require_operator(p_approver);
  if p_setting is null or p_setting not in ('dormancy_days') then
    raise exception using errcode = '22023', message = 'unknown identity setting';
  end if;
  if length(btrim(coalesce(p_note, ''))) = 0 or btrim(p_note) like 'TEST FIXTURE%' then
    raise exception using errcode = '22023', message = 'an owner decision note is required';
  end if;
  if p_value is null or jsonb_typeof(p_value) <> 'object' or p_value ? 'fixture_label' then
    raise exception using errcode = '22023', message = 'approved value must be a plain object';
  end if;
  if p_setting = 'dormancy_days' and not (
       app.contract_unknown_keys(p_value, array['days']) = '{}'::jsonb
       and jsonb_typeof(p_value -> 'days') = 'number'
       and (p_value ->> 'days') ~ '^[0-9]+$'
       and (p_value ->> 'days')::numeric between 1 and 3650) then
    raise exception using errcode = '22023', message = 'dormancy_days needs {"days": 1..3650}';
  end if;
  -- One version at a time per setting.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('identity_settings:' || p_setting));
  select coalesce(max(s.version), 0) + 1 into v_version
    from app.identity_settings s where s.setting = p_setting;
  insert into app.identity_settings (setting, version, value, source, label, set_by)
  values (p_setting, v_version, p_value, 'approved', btrim(p_note), p_approver);
  insert into app.identity_access_audit (action, actor_kind, operator, setting, revision_after)
  values ('church_setting_approved', 'operator', p_approver, p_setting, v_version);
  perform app.ops_record_action(p_approver, 'church_setting_approved', null);
  return v_version;
end;
$$;

comment on function app.identity_approve_setting(text, jsonb, text, text) is
  'Story 4.16 (G3): restricted operator approval of an Identity setting (dormancy_days) as a new '
  'approved version. Never called by a migration.';

-- ---------------------------------------------------------------------------------------------
-- Privileges: nothing new is client-executable (replaced functions keep theirs)
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.duties_vacancy_reason(uuid),
  app.duties_review_key_open(app.duties_review_flags, bigint),
  app.identity_scope_revoked_event(uuid, bigint),
  app.identity_collect_revocation_handover(app.identity_grants, bigint),
  app.identity_record_revocation_obligations(app.identity_grants, jsonb),
  app.duties_review_source_check(jsonb),
  app.duties_review_alert_check(jsonb),
  app.identity_revoked_scope(),
  app.identity_end_grant_record(uuid, uuid, text, app.identity_grants),
  app.identity_approve_setting(text, jsonb, text, text)
  from public, anon, authenticated, service_role;
