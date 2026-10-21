-- My duty history holds every duty the member was given (owner decision 2026-10-21): department
-- duties and cell programme parts, with a filter by kind. Replaces app.duties_member_history and
-- api.duties_member_history (story 4.10, 20261015002121) with a `kind` argument.
--
--   * The member's own history lists both kinds. A department leader or deputy reading a member's
--     history still sees only their departments' duties (never the member's cell parts).
--   * `kind`: null (every kind), 'department' or 'cell'. It filters the entries, the summary and
--     the upcoming count; `kinds` counts the positions of each kind visible to the reader, so a
--     client offers the filter only when there is something to filter.
--   * A cell part carries no completion outcome: the 5.8 meeting record is never a duty outcome.
--     Its outcome_state is 'not_tracked' once it has started, and the outcome figures of the
--     summary (completed, excused, no-show, unrecorded) count department duties only.
--   * Each entry names its owner: owner_kind, and department_id/department_name or cell_id (the
--     other is null). The cell's name is the Cells module's (Duties may not read it); a client
--     labels a cell part as the cell programme, as My duties does.
-- owner-approved-cleanup: owner decision 2026-10-21 (My duty history lists every duty kind with a filter): the two history functions are dropped and recreated with a fourth argument, kind, in the same migration; no data is removed.

drop function api.duties_member_history(uuid, timestamptz, uuid);
drop function app.duties_member_history(uuid, timestamptz, uuid);

-- `api.duties_member_history(member_id, before_at, before_id, kind)`: the caller's own history (no
-- member_id, or their own; departments and cells) or, for a current leader or deputy, the history
-- of a member who is or was in a department they lead or deputise (that department's assignments
-- only). Anything else: 403 not_granted, the same answer (no disclosure). One row per position
-- held (the latest revision of that person on it), newest first, 100 per page. The summary covers
-- past duties of the last 365 days of the chosen kind. Errors: 400 validation_failed (cursor,
-- kind), 403 unavailable.
create function app.duties_member_history(p_member_id uuid, p_before_at timestamptz,
                                          p_before_id uuid, p_kind text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_target uuid;
  v_self boolean;
  v_departments uuid[];
  v_result jsonb;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  v_target := coalesce(p_member_id, v_member);
  v_self := v_target = v_member;
  perform app.duties_require_open_read();
  if (p_before_at is null) <> (p_before_id is null) then
    raise exception using errcode = 'PT400', message = 'validation_failed', detail = 'cursor';
  end if;
  if p_kind is not null and p_kind not in ('department', 'cell') then
    raise exception using errcode = 'PT400', message = 'validation_failed', detail = 'kind';
  end if;
  if not v_self then
    -- The departments the caller leads or deputises now in which the member serves or served.
    select coalesce(array_agg(d.department_id), '{}') into v_departments
      from app.duties_departments d
     where (not d.is_synthetic or app.platform_current_environment() in ('local', 'staging'))
       and (app.identity_member_has_scope(v_member, 'department_leader', d.department_id)
            or app.identity_member_has_scope(v_member, 'department_deputy', d.department_id))
       and exists (select 1 from app.duties_department_members dm
                    where dm.department_id = d.department_id and dm.member_id = v_target);
    if cardinality(v_departments) = 0 then
      raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
    end if;
  end if;

  with held as (
    -- The member's assignments the reader may see, one row per position held: the latest
    -- revision of this person on the slot. Another reader sees department duties only.
    select a.assignment_id, a.assignment_state, a.response, a.response_provenance, o.occurrence_id,
           o.department_id, o.cell_id,
           case when o.department_id is not null then 'department' else 'cell' end as owner_kind,
           o.starts_at, o.occurrence_state,
           app.duties_occurrence_start(o) <= now() as started,
           x.outcome
      from app.duties_assignments a
      join app.duties_slots s on s.slot_id = a.slot_id
      join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
      left join lateral (select y.outcome from app.duties_outcomes y
                          where y.assignment_id = a.assignment_id
                          order by y.revision desc limit 1) x on true
     where a.member_id = v_target
       and o.occurrence_state <> 'draft'
       and (v_self or o.department_id = any (v_departments))
       and not exists (select 1 from app.duties_assignments n
                        where n.supersedes_assignment_id = a.assignment_id and n.member_id = a.member_id)
  ), shown as (
    select h.* from held h where p_kind is null or h.owner_kind = p_kind
  ), page as (
    select h.* from shown h
     where p_before_at is null or (h.starts_at, h.assignment_id) < (p_before_at, p_before_id)
     order by h.starts_at desc, h.assignment_id desc
     limit 101
  ), live as (
    -- A position counts as held when its assignment is current on a published duty.
    select h.*, h.assignment_state = 'current' and h.occurrence_state = 'published' as is_live
      from shown h
  )
  select jsonb_build_object(
    'member', jsonb_build_object('member_id', v_target,
                                 'display_name', app.duties_display_name(v_target)),
    'self', v_self,
    'kind', p_kind,
    'kinds', (select jsonb_build_object(
                'department', count(*) filter (where h.owner_kind = 'department'),
                'cell', count(*) filter (where h.owner_kind = 'cell'))
                from held h),
    'departments', coalesce((select jsonb_agg(jsonb_build_object('department_id', d.department_id,
                                                                  'name', d.name)
                                              order by d.name, d.department_id)
                               from app.duties_departments d
                              where d.department_id in (select h.department_id from held h)), '[]'::jsonb),
    -- One member's own figures (never compared with anyone else). Outcomes are kept for
    -- department duties only.
    'summary', (select jsonb_build_object(
                  'since', app.cmd_utc(now() - interval '365 days'),
                  'held', count(*) filter (where l.is_live and l.started),
                  'accepted', count(*) filter (where l.is_live and l.started and l.response = 'accepted'
                                               and l.response_provenance = 'member'),
                  'confirmed_by_leader', count(*) filter (where l.is_live and l.started
                                                          and l.response_provenance = 'leader'),
                  'declined', count(*) filter (where l.is_live and l.started and l.response = 'declined'),
                  'unanswered', count(*) filter (where l.is_live and l.started and l.response = 'pending'),
                  'completed', count(*) filter (where l.is_live and l.started and l.owner_kind = 'department'
                                                and l.outcome = 'completed'),
                  'excused', count(*) filter (where l.is_live and l.started and l.owner_kind = 'department'
                                              and l.outcome = 'excused'),
                  'no_show', count(*) filter (where l.is_live and l.started and l.owner_kind = 'department'
                                              and l.outcome = 'no_show'),
                  'unrecorded', count(*) filter (where l.is_live and l.started and l.owner_kind = 'department'
                                                 and l.outcome is null),
                  'ended', count(*) filter (where not l.is_live))
                  from live l
                 where l.starts_at >= now() - interval '365 days' and (l.started or not l.is_live)),
    'upcoming', (select count(*) from live l where l.is_live and not l.started),
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
               'assignment_id', p.assignment_id,
               'occurrence_id', p.occurrence_id,
               'owner_kind', p.owner_kind,
               'department_id', p.department_id,
               'department_name', d.name,
               'cell_id', p.cell_id,
               'duty_name', o.duty_name,
               'position_name', s.position_name,
               'starts_at', app.cmd_utc(o.starts_at),
               'reporting_at', case when o.reporting_at is not null then app.cmd_utc(o.reporting_at) end,
               'started', p.started,
               -- current, reassigned (another person holds the position now) or cancelled.
               'state', case when p.assignment_state = 'current' and p.occurrence_state = 'published'
                               then 'current'
                             when p.assignment_state = 'superseded' then 'reassigned'
                             else 'cancelled' end,
               'response', a.response,
               'response_provenance', a.response_provenance,
               'responded_at', case when a.responded_at is not null then app.cmd_utc(a.responded_at) end,
               'outcome_state', case
                 when not (p.assignment_state = 'current' and p.occurrence_state = 'published') then 'none'
                 when not p.started then 'upcoming'
                 when p.owner_kind = 'cell' then 'not_tracked'
                 else coalesce(p.outcome, 'unrecorded') end,
               'outcome', case when p.owner_kind = 'department' and p.assignment_state = 'current'
                                    and p.occurrence_state = 'published'
                               then app.duties_outcome_json(p.assignment_id, 20) end)
             order by p.starts_at desc, p.assignment_id desc)
        from (select * from page order by starts_at desc, assignment_id desc limit 100) p
        join app.duties_assignments a on a.assignment_id = p.assignment_id
        join app.duties_slots s on s.slot_id = a.slot_id
        join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
        left join app.duties_departments d on d.department_id = p.department_id), '[]'::jsonb),
    'has_more', (select count(*) > 100 from page))
    into v_result;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

create function api.duties_member_history(member_id uuid default null,
                                          before_at timestamptz default null,
                                          before_id uuid default null,
                                          kind text default null)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.duties_member_history($1, $2, $3, $4);
$$;

comment on function app.duties_member_history(uuid, timestamptz, uuid, text) is
  'owner: duties. One member''s assignment history: department duties and cell programme parts for '
  'the member, department duties only for their leaders and deputies; filter by kind.';
comment on function api.duties_member_history(uuid, timestamptz, uuid, text) is
  'Story 4.10, extended 2026-10-21: one member''s assignment history (responses, completion '
  'outcomes, corrections) and their own 12-month summary, every duty kind for the member, '
  'department duties for their department''s leaders and deputies; filter by kind.';

revoke all on function
  app.duties_member_history(uuid, timestamptz, uuid, text),
  api.duties_member_history(uuid, timestamptz, uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function app.duties_member_history(uuid, timestamptz, uuid, text) to authenticated;
grant execute on function api.duties_member_history(uuid, timestamptz, uuid, text) to authenticated;

notify pgrst, 'reload schema';
