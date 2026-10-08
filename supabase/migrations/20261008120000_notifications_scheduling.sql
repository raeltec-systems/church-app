-- Story 3.3: church-time reminder schedules from a versioned policy (AD-9; epic 3 requirement
-- N3). Builds on 20261008073631_notifications_inbox.sql and
-- 20261008090057_notifications_source_contracts.sql.
--
--   * The Q2 policy value is numbered (`policy_version`) and validated before use
--     (app.notifications_policy_errors). A closed gate, or a value that is not a valid scheduling
--     policy, fails closed: `unavailable {"policy": "gate_closed"}` and nothing is written. The
--     local/staging TEST FIXTURE moves from UTC to Africa/Lusaka with the owner's decided defaults
--     (owner-decisions-milestone-2.md, read as in the epic Notes). There are no quiet hours: the
--     value must carry `"quiet_hours": null`.
--   * One shared calculation, all tunables taken from the policy value:
--       app.notifications_response_deadline  creator deadline (refused after the start) or the
--                                            lead-time band default; short notice when passed;
--       app.notifications_plan               reminder entries from creator specs or the policy
--                                            defaults: passed offsets skipped, `respond_now` on a
--                                            fresh short-notice schedule, expiry, merging of
--                                            entries inside the merge window, Waiting review
--                                            dates for tasks;
--       app.notifications_occurrences        church-local recurrence with exception dates
--                                            (month ends clamp from the first local date);
--       app.notifications_snooze_at          a member's snooze choice, clamped to expiry.
--     Whole days are added on the church-local calendar; hours and minutes are absolute.
--   * `app.notifications_schedules`: a source's schedule intent per recipient (instants,
--     booleans, enums and reminder specs only; no text). Owner operations, run INSIDE the calling
--     source command's transaction (no client grants):
--       app.notifications_set_schedule(schedule jsonb)  stores the intent and reconciles that
--                                            source+recipient's future jobs: jobs no longer in
--                                            the plan are cancelled `rescheduled`, new entries
--                                            enqueued once; past-due work is never enqueued;
--       app.notifications_snooze_item(member, item, choice)  defers one delivered item for its
--                                            recipient only (entry 7 wraps it for clients).
--     Operator only: app.notifications_replan_all(reason) re-plans every active schedule under
--     the current policy in one transaction after a policy change (platform functions may not
--     call Notifications, so policy_approve cannot trigger it).
--   * Jobs record `policy_version`, `expires_at`, `schedule_id` and `snoozed_from_item_id`.
--     app.notifications_cancel also ends the matching schedules, so a re-plan never revives
--     cancelled reminders.
--
-- No destructive statements and no row deletions. No anon grant. ASCII only.

-- ---------------------------------------------------------------------------------------------
-- The Q2 TEST FIXTURE (local/staging only; production needs the owner's approval)
-- ---------------------------------------------------------------------------------------------

update app.policy_gates
   set fixture_value = '{
     "fixture_label": "TEST FIXTURE - agent reading of the owner Q2 decisions of 2026-10-08, not approved church policy",
     "policy_version": 1,
     "zone": "Africa/Lusaka",
     "quiet_hours": null,
     "deadline_bands": [
       {"min_lead": "30 days", "before_start": "14 days"},
       {"min_lead": "72 hours", "before_start": "48 hours"},
       {"min_lead": "0 minutes", "before_start": "24 hours"}
     ],
     "default_reminders": {
       "response": [
         {"anchor": "response_deadline", "before": "24 hours"},
         {"anchor": "response_deadline", "before": "0 minutes"}
       ],
       "task": [
         {"anchor": "deadline", "before": "0 minutes"}
       ]
     },
     "merge_window": "30 minutes",
     "snooze_choices": ["1 hour", "24 hours", "2 days"],
     "max_reminders": 6,
     "max_offset": "90 days"
   }'::jsonb
 where gate = 'q2_church_time';

-- ---------------------------------------------------------------------------------------------
-- Durations: "<n> minute(s)|hour(s)|day(s)", n in 0..9999
-- ---------------------------------------------------------------------------------------------

create function app.notifications_duration_error(p_value jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_value is null or jsonb_typeof(p_value) = 'null' then 'required'
    when jsonb_typeof(p_value) <> 'string' then 'invalid'
    when (p_value #>> '{}') ~ '^(0|[1-9][0-9]{0,3}) (minute|minutes|hour|hours|day|days)$' then null
    else 'invalid'
  end;
$$;

-- Approximate length in minutes (a day counts 1440), for ordering and limits only; null for
-- anything that is not a duration.
create function app.notifications_duration_minutes(p_duration text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case when p_duration ~ '^(0|[1-9][0-9]{0,3}) (minute|minutes|hour|hours|day|days)$' then
    split_part(p_duration, ' ', 1)::integer
    * case left(split_part(p_duration, ' ', 2), 3) when 'day' then 1440 when 'hou' then 60 else 1 end
  end;
$$;

-- p_at moved by a duration (p_sign +1 later, -1 earlier). Whole days move on the church-local
-- calendar of p_zone (the same local time on another date); hours and minutes are absolute.
create function app.notifications_shift(p_at timestamptz, p_duration text, p_sign integer, p_zone text)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select case left(split_part(p_duration, ' ', 2), 3)
    when 'day' then ((p_at at time zone p_zone)
                     + p_sign * split_part(p_duration, ' ', 1)::integer * interval '1 day')
                    at time zone p_zone
    when 'hou' then p_at + p_sign * split_part(p_duration, ' ', 1)::integer * interval '1 hour'
    else p_at + p_sign * split_part(p_duration, ' ', 1)::integer * interval '1 minute'
  end;
$$;

-- Church-local wall time of an instant: YYYY-MM-DDTHH:MM:SS (contract v1 `zoned_local.local`).
create function app.notifications_local(p_at timestamptz, p_zone text)
returns text
language sql
stable
set search_path = ''
as $$
  select to_char(p_at at time zone p_zone, 'YYYY-MM-DD"T"HH24:MI:SS');
$$;

-- Anchors a schedule type may use. `respond_now` is never configured; the plan adds it.
create function app.notifications_anchors(p_type text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'response' then array['response_deadline', 'starts_at']
    when 'task' then array['deadline']
  end;
$$;

-- Merge precedence of anchors (lower first): a merged entry takes the first anchor's kind.
create function app.notifications_anchor_rank(p_anchor text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select coalesce(array_position(array['respond_now', 'response_deadline', 'deadline', 'starts_at'],
                                 p_anchor), 99);
$$;

-- The reminder kinds that chase a response (the `response_deadline` and `respond_now` kinds),
-- unless the same kind also serves the `starts_at` reminders.
create function app.notifications_response_kinds(p_kinds jsonb)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(array_agg(distinct k), '{}')
    from unnest(array[p_kinds ->> 'response_deadline', p_kinds ->> 'respond_now']) k
   where k is not null and k is distinct from (p_kinds ->> 'starts_at');
$$;

-- Error code of a reminder spec list for a schedule type, or null when acceptable. Each spec is
-- {anchor, before} or {anchor, after}; at most p_max specs, each offset at most p_max_offset.
create function app.notifications_reminders_error(p_specs jsonb, p_type text, p_max integer,
                                                  p_max_offset text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_spec jsonb;
  v_offset jsonb;
begin
  if jsonb_typeof(p_specs) is distinct from 'array' then
    return 'invalid';
  end if;
  if jsonb_array_length(p_specs) > p_max then
    return 'out_of_range';
  end if;
  for v_spec in select e from jsonb_array_elements(p_specs) e loop
    if jsonb_typeof(v_spec) is distinct from 'object'
       or app.contract_unknown_keys(v_spec, array['anchor', 'before', 'after']) <> '{}'::jsonb
       or (v_spec ? 'before') = (v_spec ? 'after')
       or jsonb_typeof(v_spec -> 'anchor') is distinct from 'string'
       or not ((v_spec ->> 'anchor') = any (app.notifications_anchors(p_type))) then
      return 'invalid';
    end if;
    v_offset := coalesce(v_spec -> 'before', v_spec -> 'after');
    if app.notifications_duration_error(v_offset) is not null then
      return 'invalid';
    end if;
    if app.notifications_duration_minutes(v_offset #>> '{}')
       > app.notifications_duration_minutes(p_max_offset) then
      return 'out_of_range';
    end if;
  end loop;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- The scheduling policy value
-- ---------------------------------------------------------------------------------------------

-- Field errors of a q2_church_time value (empty object = a valid scheduling policy). The owner
-- can run this on a value before app.policy_approve; scheduling refuses any value that fails it.
create function app.notifications_policy_errors(p_value jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  e jsonb := '{}'::jsonb;
  v_band jsonb;
  v_prev integer;
  v_max integer;
  v_max_offset text;
  v_type text;
begin
  if jsonb_typeof(p_value) is distinct from 'object' then
    return '{"$": "must_be_object"}'::jsonb;
  end if;
  e := app.contract_unknown_keys(p_value, array['fixture_label', 'policy_version', 'zone',
         'quiet_hours', 'deadline_bands', 'default_reminders', 'merge_window', 'snooze_choices',
         'max_reminders', 'max_offset']);
  if not app.contract_integer_in(p_value -> 'policy_version', 1, 2147483647) then
    e := e || '{"policy_version": "invalid"}';
  end if;
  if app.contract_zone_error(p_value -> 'zone') is not null
     or not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = p_value ->> 'zone') then
    e := e || '{"zone": "invalid"}';
  end if;
  -- Owner decision 2026-10-08: no quiet hours. Any window is refused, not ignored.
  if not (p_value ? 'quiet_hours') or jsonb_typeof(p_value -> 'quiet_hours') <> 'null' then
    e := e || '{"quiet_hours": "unsupported"}';
  end if;
  if not app.contract_integer_in(p_value -> 'max_reminders', 1, 20) then
    e := e || '{"max_reminders": "invalid"}';
  end if;
  if app.notifications_duration_error(p_value -> 'max_offset') is not null then
    e := e || '{"max_offset": "invalid"}';
  end if;
  if app.notifications_duration_error(p_value -> 'merge_window') is not null
     or app.notifications_duration_minutes(p_value ->> 'merge_window') > 1440 then
    e := e || '{"merge_window": "invalid"}';
  end if;
  -- Bands: 1..10, strictly decreasing min_lead, the last one 0 so every lead has a band.
  if jsonb_typeof(p_value -> 'deadline_bands') is distinct from 'array'
     or jsonb_array_length(p_value -> 'deadline_bands') not between 1 and 10 then
    e := e || '{"deadline_bands": "invalid"}';
  else
    v_prev := null;
    for v_band in select b from jsonb_array_elements(p_value -> 'deadline_bands') b loop
      if jsonb_typeof(v_band) is distinct from 'object'
         or app.contract_unknown_keys(v_band, array['min_lead', 'before_start']) <> '{}'::jsonb
         or app.notifications_duration_error(v_band -> 'min_lead') is not null
         or app.notifications_duration_error(v_band -> 'before_start') is not null
         or app.notifications_duration_error(p_value -> 'max_offset') is not null
         or app.notifications_duration_minutes(v_band ->> 'before_start')
            > app.notifications_duration_minutes(p_value ->> 'max_offset')
         or (v_prev is not null
             and app.notifications_duration_minutes(v_band ->> 'min_lead') >= v_prev) then
        e := e || '{"deadline_bands": "invalid"}';
        exit;
      end if;
      v_prev := app.notifications_duration_minutes(v_band ->> 'min_lead');
    end loop;
    if not (e ? 'deadline_bands') and v_prev <> 0 then
      e := e || '{"deadline_bands": "invalid"}';
    end if;
  end if;
  if jsonb_typeof(p_value -> 'snooze_choices') is distinct from 'array'
     or jsonb_array_length(p_value -> 'snooze_choices') not between 1 and 10
     or exists (select 1 from jsonb_array_elements(p_value -> 'snooze_choices') c
                 where app.notifications_duration_error(c) is not null
                    or app.notifications_duration_minutes(c #>> '{}') = 0)
     or (select count(distinct c) from jsonb_array_elements(p_value -> 'snooze_choices') c)
        <> jsonb_array_length(p_value -> 'snooze_choices') then
    e := e || '{"snooze_choices": "invalid"}';
  end if;
  if jsonb_typeof(p_value -> 'default_reminders') is distinct from 'object'
     or app.contract_unknown_keys(p_value -> 'default_reminders', array['response', 'task']) <> '{}'::jsonb
     or (e ? 'max_reminders') or (e ? 'max_offset') then
    e := e || '{"default_reminders": "invalid"}';
  else
    v_max := (p_value ->> 'max_reminders')::integer;
    v_max_offset := p_value ->> 'max_offset';
    foreach v_type in array array['response', 'task'] loop
      if app.notifications_reminders_error(p_value -> 'default_reminders' -> v_type, v_type,
                                            v_max, v_max_offset) is not null then
        e := e || '{"default_reminders": "invalid"}';
      end if;
    end loop;
  end if;
  return e;
end;
$$;

-- The effective, valid scheduling policy: {version, source, digest, zone, value}. Fails closed
-- with the kernel's `unavailable {"policy": "gate_closed"}` when the gate is closed (production
-- until the owner approves) or the value is not a valid scheduling policy (content-free log).
create function app.notifications_policy()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_policy jsonb := app.policy_effective('q2_church_time');
  v_value jsonb := v_policy -> 'value';
begin
  if app.notifications_policy_errors(v_value) <> '{}'::jsonb then
    raise log 'q2_church_time is not a valid scheduling policy (source %)', v_policy ->> 'source';
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  return jsonb_build_object(
    'version', (v_value ->> 'policy_version')::integer,
    'source', v_policy ->> 'source',
    'digest', encode(sha256(convert_to(v_value::text, 'UTF8')), 'hex'),
    'zone', v_value ->> 'zone',
    'value', v_value);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- The calculation (pure: inputs and the policy in, instants out)
-- ---------------------------------------------------------------------------------------------

-- Response deadline of an assignment. A creator deadline is used as given and refused after the
-- start; otherwise the first band whose min_lead fits the lead (start - assignment) gives
-- start - before_start, never later than the start. A deadline at or before p_now is short
-- notice (respond now); the answer is never later than the start, even when it has passed.
-- notice: the effective deadline is p_now (respond now).
-- Returns {response_deadline, deadline_source: creator|default, band (1-based or null),
-- short_notice}.
create function app.notifications_response_deadline(p_policy jsonb, p_assigned_at timestamptz,
                                                    p_starts_at timestamptz,
                                                    p_creator_deadline timestamptz,
                                                    p_now timestamptz)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_zone text := p_policy ->> 'zone';
  v_band jsonb;
  v_index integer := 0;
  v_band_no integer;
  v_deadline timestamptz;
begin
  if p_creator_deadline is not null then
    if p_creator_deadline > p_starts_at then
      perform app.cmd_fail('validation_failed', '{"response_deadline": "after_start"}');
    end if;
    v_deadline := p_creator_deadline;
  else
    if p_assigned_at > p_starts_at then
      perform app.cmd_fail('validation_failed', '{"assigned_at": "after_start"}');
    end if;
    for v_band in select b from jsonb_array_elements(p_policy -> 'value' -> 'deadline_bands') b loop
      v_index := v_index + 1;
      if app.notifications_shift(p_assigned_at, v_band ->> 'min_lead', 1, v_zone) <= p_starts_at then
        v_band_no := v_index;
        v_deadline := least(app.notifications_shift(p_starts_at, v_band ->> 'before_start', -1, v_zone),
                            p_starts_at);
        exit;
      end if;
    end loop;
  end if;
  return jsonb_build_object(
    'response_deadline', app.cmd_utc(least(greatest(v_deadline, p_now), p_starts_at)),
    'deadline_source', case when p_creator_deadline is null then 'default' else 'creator' end,
    'band', v_band_no,
    'short_notice', v_deadline <= p_now);
end;
$$;

-- Field errors of a schedule intent for its type (empty object = acceptable).
--   response: {assigned_at, starts_at, response_deadline?, expires_at?, responded?, reminders?}
--   task:     {due_at, task_state: open|in_progress|waiting, review_at? (required iff waiting),
--              expires_at?, reminders?}
-- `reminders` null or absent = the policy default for the type; [] = no reminders.
create function app.notifications_intent_errors(p_type text, p_intent jsonb, p_policy jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  e jsonb;
  v_reminders text;
begin
  if p_type is null or p_type not in ('response', 'task') then
    return '{"schedule_type": "invalid"}'::jsonb;
  end if;
  if jsonb_typeof(p_intent) is distinct from 'object' then
    return '{"intent": "must_be_object"}'::jsonb;
  end if;
  if coalesce(jsonb_typeof(p_intent -> 'reminders'), 'null') <> 'null' then
    v_reminders := app.notifications_reminders_error(
      p_intent -> 'reminders', p_type, (p_policy -> 'value' ->> 'max_reminders')::integer,
      p_policy -> 'value' ->> 'max_offset');
  end if;
  if p_type = 'response' then
    e := app.contract_unknown_keys(p_intent, array['assigned_at', 'starts_at', 'response_deadline',
                                                   'expires_at', 'responded', 'reminders'])
         || jsonb_build_object(
              'assigned_at', app.contract_instant_error(p_intent -> 'assigned_at'),
              'starts_at', app.contract_instant_error(p_intent -> 'starts_at'),
              'response_deadline', case when coalesce(jsonb_typeof(p_intent -> 'response_deadline'), 'null') = 'null'
                                        then null else app.contract_instant_error(p_intent -> 'response_deadline') end,
              'expires_at', case when coalesce(jsonb_typeof(p_intent -> 'expires_at'), 'null') = 'null'
                                 then null else app.contract_instant_error(p_intent -> 'expires_at') end,
              'responded', case when coalesce(jsonb_typeof(p_intent -> 'responded'), 'boolean') = 'boolean'
                                then null else 'invalid' end,
              'reminders', v_reminders);
  else
    e := app.contract_unknown_keys(p_intent, array['due_at', 'task_state', 'review_at', 'expires_at',
                                                   'reminders'])
         || jsonb_build_object(
              'due_at', app.contract_instant_error(p_intent -> 'due_at'),
              'task_state', case when (p_intent ->> 'task_state') in ('open', 'in_progress', 'waiting')
                                      and jsonb_typeof(p_intent -> 'task_state') = 'string'
                                 then null
                                 when coalesce(jsonb_typeof(p_intent -> 'task_state'), 'null') = 'null'
                                 then 'required' else 'invalid' end,
              'review_at', case
                             when (p_intent ->> 'task_state') = 'waiting'
                               then app.contract_instant_error(p_intent -> 'review_at')
                             when coalesce(jsonb_typeof(p_intent -> 'review_at'), 'null') = 'null' then null
                             else 'must_be_null' end,
              'expires_at', case when coalesce(jsonb_typeof(p_intent -> 'expires_at'), 'null') = 'null'
                                 then null else app.contract_instant_error(p_intent -> 'expires_at') end,
              'reminders', v_reminders);
  end if;
  return jsonb_strip_nulls(e);
end;
$$;

-- The reminder plan of one recipient's schedule at p_now. Entries are computed from the creator
-- specs (or the policy default for the type), then: entries at or before p_now are skipped
-- (passed offsets); a fresh (p_fresh) response schedule on short notice gets one `respond_now`
-- entry at p_now; entries after expires_at are dropped; entries within the merge window of the
-- first entry of a group are merged into it (earliest instant, anchors in precedence order).
-- A responded assignment has no response-deadline reminders. No quiet hours.
-- Returns {policy_version, zone, schedule_type, expires_at, (response: response_deadline,
-- deadline_source, band, short_notice) | (task: deadline), entries: [{scheduled_at, local,
-- anchors}]}. Raises validation_failed on a bad intent.
create function app.notifications_plan(p_policy jsonb, p_type text, p_intent jsonb,
                                       p_now timestamptz, p_fresh boolean)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_zone text := p_policy ->> 'zone';
  v_errors jsonb;
  v_head jsonb;
  v_anchors jsonb;
  v_specs jsonb;
  v_expires timestamptz;
  v_window text := p_policy -> 'value' ->> 'merge_window';
  v_raw jsonb := '[]'::jsonb;
  v_spec jsonb;
  v_offset text;
  v_at timestamptz;
  r record;
  v_entries jsonb := '[]'::jsonb;
  v_group_at timestamptz;
  v_group_anchors text[];
begin
  v_errors := app.notifications_intent_errors(p_type, p_intent, p_policy);
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  if p_type = 'response' then
    v_head := app.notifications_response_deadline(
      p_policy, (p_intent ->> 'assigned_at')::timestamptz, (p_intent ->> 'starts_at')::timestamptz,
      (p_intent ->> 'response_deadline')::timestamptz, p_now);
    v_anchors := jsonb_build_object('starts_at', p_intent -> 'starts_at');
    if not coalesce((p_intent ->> 'responded')::boolean, false) then
      v_anchors := v_anchors || jsonb_build_object('response_deadline', v_head -> 'response_deadline');
    end if;
    v_expires := coalesce((p_intent ->> 'expires_at')::timestamptz, (p_intent ->> 'starts_at')::timestamptz);
  else
    v_head := jsonb_build_object('deadline',
      case when p_intent ->> 'task_state' = 'waiting' then p_intent -> 'review_at'
           else p_intent -> 'due_at' end);
    v_anchors := jsonb_build_object('deadline', v_head -> 'deadline');
    v_expires := (p_intent ->> 'expires_at')::timestamptz;
  end if;
  v_specs := case when coalesce(jsonb_typeof(p_intent -> 'reminders'), 'null') = 'null'
                  then p_policy -> 'value' -> 'default_reminders' -> p_type
                  else p_intent -> 'reminders' end;
  for v_spec in select s from jsonb_array_elements(v_specs) s loop
    continue when not (v_anchors ? (v_spec ->> 'anchor'));
    v_offset := coalesce(v_spec ->> 'before', v_spec ->> 'after');
    v_at := app.notifications_shift((v_anchors ->> (v_spec ->> 'anchor'))::timestamptz, v_offset,
                                    case when v_spec ? 'before' then -1 else 1 end, v_zone);
    continue when v_at <= p_now;
    v_raw := v_raw || jsonb_build_array(jsonb_build_object('at', v_at, 'anchor', v_spec ->> 'anchor'));
  end loop;
  if p_type = 'response' and p_fresh and (v_head ->> 'short_notice')::boolean
     and not coalesce((p_intent ->> 'responded')::boolean, false) then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object('at', p_now, 'anchor', 'respond_now'));
  end if;
  for r in
    select (x ->> 'at')::timestamptz as at, x ->> 'anchor' as anchor
      from jsonb_array_elements(v_raw) x
     where v_expires is null or (x ->> 'at')::timestamptz <= v_expires
     order by (x ->> 'at')::timestamptz, app.notifications_anchor_rank(x ->> 'anchor')
  loop
    if v_group_at is not null
       and r.at <= app.notifications_shift(v_group_at, v_window, 1, v_zone) then
      if not (r.anchor = any (v_group_anchors)) then
        v_group_anchors := v_group_anchors || r.anchor;
      end if;
      continue;
    end if;
    if v_group_at is not null then
      v_entries := v_entries || jsonb_build_array(jsonb_build_object(
        'scheduled_at', app.cmd_utc(v_group_at), 'local', app.notifications_local(v_group_at, v_zone),
        'anchors', (select jsonb_agg(a order by app.notifications_anchor_rank(a))
                      from unnest(v_group_anchors) a)));
    end if;
    v_group_at := r.at;
    v_group_anchors := array[r.anchor];
  end loop;
  if v_group_at is not null then
    v_entries := v_entries || jsonb_build_array(jsonb_build_object(
      'scheduled_at', app.cmd_utc(v_group_at), 'local', app.notifications_local(v_group_at, v_zone),
      'anchors', (select jsonb_agg(a order by app.notifications_anchor_rank(a))
                    from unnest(v_group_anchors) a)));
  end if;
  return jsonb_build_object(
      'policy_version', (p_policy ->> 'version')::integer, 'zone', v_zone, 'schedule_type', p_type,
      'expires_at', case when v_expires is not null then app.cmd_utc(v_expires) end)
    || v_head || jsonb_build_object('entries', v_entries);
end;
$$;

-- Occurrences of a church-local recurrence whose instant is in [p_from, p_until]:
--   {local_start: "YYYY-MM-DDTHH:MM:SS", every: day|week|month, interval?: 1..52,
--    exceptions?: ["YYYY-MM-DD", ...]}
-- The n-th occurrence is local_start + n * interval units on the local calendar (a month end
-- clamps from the first date: 31 Jan -> 28/29 Feb -> 31 Mar), converted with the policy zone.
-- Exception dates (local) are skipped. The walk starts just before p_from (however old the
-- rule is) and is capped at 1000 steps inside a window of at most 400 days; hitting the cap is
-- validation_failed {"window": "out_of_range"}, never a silent empty answer.
-- Returns [{starts_at, local}].
create function app.notifications_occurrences(p_policy jsonb, p_rule jsonb, p_from timestamptz,
                                              p_until timestamptz)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_zone text := p_policy ->> 'zone';
  e jsonb;
  v_base timestamp;
  v_step interval;
  v_every integer;
  v_local timestamp;
  v_at timestamptz;
  v_out jsonb := '[]'::jsonb;
  v_exceptions date[];
  v_from_local timestamp;
  v_first integer;
  n integer := 0;
begin
  if jsonb_typeof(p_rule) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"rule": "must_be_object"}');
  end if;
  e := jsonb_strip_nulls(
         app.contract_unknown_keys(p_rule, array['local_start', 'every', 'interval', 'exceptions'])
         || jsonb_build_object(
              'local_start', app.contract_local_error(p_rule -> 'local_start'),
              'every', case when jsonb_typeof(p_rule -> 'every') = 'string'
                                 and (p_rule ->> 'every') in ('day', 'week', 'month') then null
                            else 'invalid' end,
              'interval', case when not (p_rule ? 'interval')
                                    or app.contract_integer_in(p_rule -> 'interval', 1, 52) then null
                               else 'out_of_range' end,
              'exceptions', case
                              when not (p_rule ? 'exceptions') then null
                              when jsonb_typeof(p_rule -> 'exceptions') <> 'array'
                                   or jsonb_array_length(p_rule -> 'exceptions') > 366
                                   or exists (select 1 from jsonb_array_elements(p_rule -> 'exceptions') x
                                               where jsonb_typeof(x) <> 'string'
                                                  or app.contract_local_error(to_jsonb((x #>> '{}') || 'T00:00:00')) is not null)
                                then 'invalid'
                            end));
  if p_from is null or p_until is null or p_until < p_from or p_until > p_from + interval '400 days' then
    e := e || '{"window": "out_of_range"}';
  end if;
  if e <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', e);
  end if;
  v_base := (p_rule ->> 'local_start')::timestamp;
  v_every := coalesce((p_rule ->> 'interval')::integer, 1);
  v_step := case p_rule ->> 'every' when 'day' then interval '1 day' when 'week' then interval '7 days'
                                   else interval '1 month' end;
  select coalesce(array_agg((x #>> '{}')::date), '{}') into v_exceptions
    from jsonb_array_elements(coalesce(p_rule -> 'exceptions', '[]'::jsonb)) x;
  -- Start one step before the first occurrence that can reach p_from, however long ago
  -- local_start is (no silent empty answer for an old rule).
  v_from_local := p_from at time zone v_zone;
  if v_from_local > v_base then
    if p_rule ->> 'every' = 'month' then
      n := ((extract(year from v_from_local) - extract(year from v_base)) * 12
            + extract(month from v_from_local) - extract(month from v_base))::integer / v_every - 1;
    else
      n := floor(extract(epoch from (v_from_local - v_base))
                 / extract(epoch from v_step) / v_every)::integer - 1;
    end if;
    n := greatest(n, 0);
  end if;
  v_first := n;
  loop
    if n > v_first + 1000 then
      perform app.cmd_fail('validation_failed', '{"window": "out_of_range"}');
    end if;
    v_local := v_base + (n * v_every) * v_step;
    v_at := v_local at time zone v_zone;
    exit when v_at > p_until;
    if v_at >= p_from and not (v_local::date = any (v_exceptions)) then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'starts_at', app.cmd_utc(v_at), 'local', to_char(v_local, 'YYYY-MM-DD"T"HH24:MI:SS')));
    end if;
    n := n + 1;
  end loop;
  return v_out;
end;
$$;

-- When a snooze choice fires: p_now + choice (a choice listed in the policy), clamped to
-- p_expires_at. Refuses an unknown choice (validation_failed {"choice": "invalid"}) and an
-- expired reminder (conflict {"item_id": "expired"}). Returns {scheduled_at, clamped}.
create function app.notifications_snooze_at(p_policy jsonb, p_choice text, p_now timestamptz,
                                            p_expires_at timestamptz)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_at timestamptz;
begin
  if p_choice is null or not exists (
       select 1 from jsonb_array_elements_text(p_policy -> 'value' -> 'snooze_choices') c
        where c = p_choice) then
    perform app.cmd_fail('validation_failed', '{"choice": "invalid"}');
  end if;
  if p_expires_at is not null and p_expires_at <= p_now then
    perform app.cmd_fail('conflict', '{"item_id": "expired"}');
  end if;
  v_at := app.notifications_shift(p_now, p_choice, 1, p_policy ->> 'zone');
  return jsonb_build_object(
    'scheduled_at', app.cmd_utc(least(v_at, coalesce(p_expires_at, v_at))),
    'clamped', p_expires_at is not null and v_at > p_expires_at);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Schedules (owner: notifications) and job columns
-- ---------------------------------------------------------------------------------------------

create table app.notifications_schedules (
  schedule_id uuid primary key default gen_random_uuid(),
  source_type text not null references app.contract_source_types (source_type),
  source_id uuid not null,
  recipient_member_id uuid not null references app.identity_members (member_id),
  source_revision bigint not null check (source_revision between 1 and 9007199254740991),
  schedule_type text not null check (schedule_type in ('response', 'task')),
  intent jsonb not null check (jsonb_typeof(intent) = 'object'),
  kinds jsonb not null check (jsonb_typeof(kinds) = 'object'),
  plan jsonb not null check (jsonb_typeof(plan) = 'object'),
  policy_version integer not null check (policy_version >= 1),
  policy_source text not null check (policy_source in ('approved', 'fixture')),
  policy_digest text not null check (policy_digest ~ '^[0-9a-f]{64}$'),
  schedule_state text not null default 'active'
    check (schedule_state in ('active', 'ended', 'stale')),
  end_reason text check (end_reason ~ '^[a-z][a-z0-9_]{0,62}$'),
  -- The source revision whose fresh plan already asked for a response now (once per revision).
  respond_now_revision bigint,
  -- Reminder kinds the source cancelled at this revision (a kind-selective
  -- app.notifications_cancel); a re-plan never brings them back. Reset on a new revision.
  cancelled_kinds text[] not null default '{}',
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check ((schedule_state = 'active') = (end_reason is null))
);

create unique index notifications_schedules_source_recipient
  on app.notifications_schedules (source_type, source_id, recipient_member_id);
create index notifications_schedules_active on app.notifications_schedules (schedule_id)
  where schedule_state = 'active';
create index notifications_schedules_recipient on app.notifications_schedules (recipient_member_id);

comment on table app.notifications_schedules is
  'owner: notifications. A source''s reminder schedule intent per recipient (AD-9): instants, '
  'booleans, enums and reminder specs only, with the last computed plan and the policy version. '
  'Written only through app.notifications_set_schedule inside the source command''s transaction.';

alter table app.notifications_jobs
  add column policy_version integer check (policy_version >= 1),
  add column expires_at timestamptz,
  add column schedule_id uuid references app.notifications_schedules (schedule_id),
  add column snoozed_from_item_id uuid references app.notifications_inbox_items (item_id);

create index notifications_jobs_schedule on app.notifications_jobs (schedule_id)
  where job_state = 'pending';
create index notifications_jobs_snoozed_from on app.notifications_jobs (snoozed_from_item_id)
  where snoozed_from_item_id is not null;

-- ---------------------------------------------------------------------------------------------
-- Enqueue (records the policy version, expiry, schedule and snooze origin)
-- ---------------------------------------------------------------------------------------------

-- As app.notifications_enqueue (story 3.2), plus the job's expiry, schedule and snooze origin,
-- and the numbered policy version. Requires a valid scheduling policy (fails closed).
create function app.notifications_enqueue_job(p_key jsonb, p_expires_at timestamptz,
                                              p_schedule_id uuid, p_snoozed_from uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_key jsonb;
  v_policy jsonb;
  v_job app.notifications_jobs;
  v_created boolean := false;
begin
  perform app.contract_require('notification_key', p_key);
  if not exists (select 1 from app.contract_source_types s
                  where s.source_type = p_key ->> 'source_type') then
    perform app.cmd_fail('validation_failed', '{"source_type": "unregistered"}');
  end if;
  if not exists (select 1 from app.contract_reminder_contracts c
                  where c.source_type = p_key ->> 'source_type'
                    and c.reminder_kind = p_key ->> 'reminder_kind') then
    perform app.cmd_fail('validation_failed', '{"reminder_kind": "unregistered"}');
  end if;
  v_key := app.contract_reminder_key(p_key) -> 'key';
  v_policy := app.notifications_policy();
  if not exists (select 1 from app.identity_members m
                  where m.member_id = (v_key ->> 'recipient_member_id')::uuid) then
    perform app.cmd_fail('validation_failed', '{"recipient_member_id": "unknown"}');
  end if;
  insert into app.notifications_jobs (source_type, source_id, source_revision, recipient_member_id,
                                      reminder_kind, scheduled_at, policy_source, policy_digest,
                                      policy_version, expires_at, schedule_id, snoozed_from_item_id)
  values (v_key ->> 'source_type', (v_key ->> 'source_id')::uuid,
          (v_key ->> 'source_revision')::bigint, (v_key ->> 'recipient_member_id')::uuid,
          v_key ->> 'reminder_kind', (v_key ->> 'scheduled_at')::timestamptz,
          v_policy ->> 'source', v_policy ->> 'digest', (v_policy ->> 'version')::integer,
          p_expires_at, p_schedule_id, p_snoozed_from)
  on conflict (source_type, source_id, source_revision, recipient_member_id, reminder_kind,
               scheduled_at) do nothing
  returning * into v_job;
  if found then
    v_created := true;
  else
    select j.* into v_job from app.notifications_jobs j
     where j.source_type = v_key ->> 'source_type'
       and j.source_id = (v_key ->> 'source_id')::uuid
       and j.source_revision = (v_key ->> 'source_revision')::bigint
       and j.recipient_member_id = (v_key ->> 'recipient_member_id')::uuid
       and j.reminder_kind = v_key ->> 'reminder_kind'
       and j.scheduled_at = (v_key ->> 'scheduled_at')::timestamptz;
  end if;
  return jsonb_build_object('job_id', v_job.job_id, 'job_state', v_job.job_state,
                            'cancel_reason', v_job.cancel_reason, 'created', v_created);
end;
$$;

-- Unchanged contract for source owners: {job_id, job_state, created}.
create or replace function app.notifications_enqueue(p_key jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  return app.notifications_enqueue_job(p_key, null, null, null) - 'cancel_reason';
end;
$$;

-- As in story 3.1. Without a reminder_kind the matching active schedules end with the same
-- reason; with one they stay active and remember the cancelled kind for this revision. Either
-- way a later policy re-plan never brings the cancelled reminders back.
create or replace function app.notifications_cancel(p_selector jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_count integer;
begin
  if jsonb_typeof(p_selector) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"selector": "must_be_object"}');
  end if;
  v_errors := jsonb_strip_nulls(jsonb_build_object(
      'source_type', app.contract_token_error(p_selector -> 'source_type'),
      'source_id', app.contract_uuid_error(p_selector -> 'source_id'),
      'reason', app.contract_token_error(p_selector -> 'reason'),
      'recipient_member_id', app.contract_uuid_error(p_selector -> 'recipient_member_id', true),
      'reminder_kind', case when coalesce(jsonb_typeof(p_selector -> 'reminder_kind'), 'null') = 'null'
                            then null else app.contract_token_error(p_selector -> 'reminder_kind') end))
    || coalesce((select jsonb_object_agg(k, 'unknown_field') from jsonb_object_keys(p_selector) k
                  where k not in ('source_type', 'source_id', 'reason', 'recipient_member_id',
                                  'reminder_kind')), '{}'::jsonb);
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  if not exists (select 1 from app.contract_source_types s
                  where s.source_type = p_selector ->> 'source_type') then
    perform app.cmd_fail('validation_failed', '{"source_type": "unregistered"}');
  end if;
  -- Without a kind the schedules end; with a kind they stay active without that kind.
  update app.notifications_schedules s
     set schedule_state = case when coalesce(jsonb_typeof(p_selector -> 'reminder_kind'), 'null') = 'null'
                               then 'ended' else s.schedule_state end,
         end_reason = case when coalesce(jsonb_typeof(p_selector -> 'reminder_kind'), 'null') = 'null'
                           then p_selector ->> 'reason' else s.end_reason end,
         cancelled_kinds = case
           when coalesce(jsonb_typeof(p_selector -> 'reminder_kind'), 'null') = 'null'
                or (p_selector ->> 'reminder_kind') = any (s.cancelled_kinds) then s.cancelled_kinds
           else s.cancelled_kinds || (p_selector ->> 'reminder_kind') end,
         updated_at = clock_timestamp()
   where s.source_type = p_selector ->> 'source_type'
     and s.source_id = (p_selector ->> 'source_id')::uuid
     and s.schedule_state = 'active'
     and (coalesce(jsonb_typeof(p_selector -> 'recipient_member_id'), 'null') = 'null'
          or s.recipient_member_id = (p_selector ->> 'recipient_member_id')::uuid);
  update app.notifications_jobs j
     set job_state = 'cancelled', finished_at = clock_timestamp(),
         cancel_reason = p_selector ->> 'reason'
   where j.source_type = p_selector ->> 'source_type'
     and j.source_id = (p_selector ->> 'source_id')::uuid
     and j.job_state = 'pending'
     and (coalesce(jsonb_typeof(p_selector -> 'recipient_member_id'), 'null') = 'null'
          or j.recipient_member_id = (p_selector ->> 'recipient_member_id')::uuid)
     and (coalesce(jsonb_typeof(p_selector -> 'reminder_kind'), 'null') = 'null'
          or j.reminder_kind = p_selector ->> 'reminder_kind');
  get diagnostics v_count = row_count;
  return jsonb_build_object('cancelled', v_count);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Reconciliation (owner operations)
-- ---------------------------------------------------------------------------------------------

-- Re-plans one stored schedule at p_now (now() outside tests) under p_policy and reconciles its
-- jobs. Plan entries are dropped when their kind was cancelled at this revision
-- (app.notifications_cancel with a reminder_kind), or when an earlier job of this schedule at
-- this revision that is already due or delivered lies within the merge window before them (the
-- merge was already sent; it never resurfaces as a separate reminder). Pending jobs of the
-- schedule that are not in the new plan are cancelled `rescheduled` when they lie in the future
-- or belong to an older source revision (a due job at the current revision is left for the
-- worker). A member's pending snooze survives unless the source revision moved
-- (`source_revised`) or the member responded and it is a response reminder (`responded`). Each
-- plan entry is enqueued once (a pending job already in the plan takes the current policy
-- version and expiry); a future entry whose job was earlier cancelled `rescheduled` is
-- reinstated. Nothing at or before p_now is enqueued, except the one `respond_now` of a fresh
-- short-notice plan per source revision. Returns counts.
create function app.notifications_apply_schedule(p_schedule_id uuid, p_policy jsonb, p_fresh boolean,
                                                 p_now timestamptz default now())
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_row app.notifications_schedules;
  v_zone text := p_policy ->> 'zone';
  v_window text := p_policy -> 'value' ->> 'merge_window';
  v_fresh boolean;
  v_plan jsonb;
  v_entry jsonb;
  v_at timestamptz;
  v_kind text;
  v_anchor text;
  v_wanted jsonb := '[]'::jsonb;
  v_job jsonb;
  v_response_kinds text[];
  v_cancelled integer;
  v_cancelled_snooze integer;
  v_cancelled_responded integer := 0;
  v_covered integer := 0;
  v_enqueued integer := 0;
  v_reinstated integer := 0;
begin
  select s.* into v_row from app.notifications_schedules s
   where s.schedule_id = p_schedule_id for update;
  v_fresh := p_fresh and v_row.respond_now_revision is distinct from v_row.source_revision;
  v_plan := app.notifications_plan(p_policy, v_row.schedule_type, v_row.intent, p_now, v_fresh);
  for v_entry in select e from jsonb_array_elements(v_plan -> 'entries') e loop
    v_kind := null;
    for v_anchor in select a from jsonb_array_elements_text(v_entry -> 'anchors') a loop
      v_kind := coalesce(v_row.kinds ->> v_anchor,
                         case when v_anchor = 'respond_now' then v_row.kinds ->> 'response_deadline' end);
      exit when v_kind is not null;
    end loop;
    if v_kind is null then
      perform app.cmd_fail('validation_failed', '{"kinds": "required"}');
    end if;
    continue when v_kind = any (v_row.cancelled_kinds);
    v_at := (v_entry ->> 'scheduled_at')::timestamptz;
    if exists (select 1 from app.notifications_jobs j
                where j.schedule_id = v_row.schedule_id
                  and j.source_revision = v_row.source_revision
                  and j.snoozed_from_item_id is null
                  and j.job_state in ('pending', 'delivered')
                  and j.scheduled_at <= p_now
                  and j.scheduled_at < v_at
                  and v_at <= app.notifications_shift(j.scheduled_at, v_window, 1, v_zone)) then
      v_covered := v_covered + 1;
      continue;
    end if;
    v_wanted := v_wanted || jsonb_build_array(jsonb_build_object(
      'reminder_kind', v_kind, 'scheduled_at', v_entry ->> 'scheduled_at'));
  end loop;

  update app.notifications_jobs j
     set job_state = 'cancelled', finished_at = clock_timestamp(), cancel_reason = 'rescheduled'
   where j.schedule_id = v_row.schedule_id
     and j.snoozed_from_item_id is null
     and j.job_state = 'pending'
     and (j.scheduled_at > p_now or j.source_revision <> v_row.source_revision)
     and not exists (select 1 from jsonb_array_elements(v_wanted) w
                      where j.source_revision = v_row.source_revision
                        and w ->> 'reminder_kind' = j.reminder_kind
                        and (w ->> 'scheduled_at')::timestamptz = j.scheduled_at);
  get diagnostics v_cancelled = row_count;
  update app.notifications_jobs j
     set job_state = 'cancelled', finished_at = clock_timestamp(), cancel_reason = 'source_revised'
   where j.source_type = v_row.source_type and j.source_id = v_row.source_id
     and j.recipient_member_id = v_row.recipient_member_id
     and j.snoozed_from_item_id is not null
     and j.job_state = 'pending'
     and j.source_revision <> v_row.source_revision;
  get diagnostics v_cancelled_snooze = row_count;
  if coalesce((v_row.intent ->> 'responded')::boolean, false) then
    v_response_kinds := app.notifications_response_kinds(v_row.kinds);
    update app.notifications_jobs j
       set job_state = 'cancelled', finished_at = clock_timestamp(), cancel_reason = 'responded'
     where j.source_type = v_row.source_type and j.source_id = v_row.source_id
       and j.recipient_member_id = v_row.recipient_member_id
       and j.snoozed_from_item_id is not null
       and j.job_state = 'pending'
       and j.reminder_kind = any (v_response_kinds);
    get diagnostics v_cancelled_responded = row_count;
  end if;

  for v_entry in select e from jsonb_array_elements(v_wanted) e loop
    v_job := app.notifications_enqueue_job(jsonb_build_object(
        'source_type', v_row.source_type, 'source_id', v_row.source_id,
        'source_revision', v_row.source_revision, 'recipient_member_id', v_row.recipient_member_id,
        'reminder_kind', v_entry ->> 'reminder_kind', 'scheduled_at', v_entry ->> 'scheduled_at'),
      (v_plan ->> 'expires_at')::timestamptz, v_row.schedule_id, null);
    if (v_job ->> 'created')::boolean then
      v_enqueued := v_enqueued + 1;
    elsif v_job ->> 'job_state' = 'pending' then
      -- Still in the plan: it now applies this policy version and expiry.
      update app.notifications_jobs j
         set policy_version = (p_policy ->> 'version')::integer,
             policy_source = p_policy ->> 'source', policy_digest = p_policy ->> 'digest',
             expires_at = (v_plan ->> 'expires_at')::timestamptz, schedule_id = v_row.schedule_id
       where j.job_id = (v_job ->> 'job_id')::uuid;
    elsif v_job ->> 'job_state' = 'cancelled' and v_job ->> 'cancel_reason' = 'rescheduled'
          and (v_entry ->> 'scheduled_at')::timestamptz > p_now then
      update app.notifications_jobs j
         set job_state = 'pending', finished_at = null, cancel_reason = null,
             policy_version = (p_policy ->> 'version')::integer,
             policy_source = p_policy ->> 'source', policy_digest = p_policy ->> 'digest',
             expires_at = (v_plan ->> 'expires_at')::timestamptz, schedule_id = v_row.schedule_id
       where j.job_id = (v_job ->> 'job_id')::uuid;
      v_reinstated := v_reinstated + 1;
    end if;
  end loop;

  update app.notifications_schedules s
     set plan = v_plan, policy_version = (p_policy ->> 'version')::integer,
         policy_source = p_policy ->> 'source', policy_digest = p_policy ->> 'digest',
         respond_now_revision = case
           when exists (select 1 from jsonb_array_elements(v_plan -> 'entries') e
                         where e -> 'anchors' ? 'respond_now') then v_row.source_revision
           else s.respond_now_revision end,
         updated_at = clock_timestamp()
   where s.schedule_id = v_row.schedule_id;
  return jsonb_build_object('entries', jsonb_array_length(v_plan -> 'entries'),
                            'enqueued', v_enqueued, 'reinstated', v_reinstated,
                            'covered', v_covered,
                            'cancelled', v_cancelled + v_cancelled_snooze + v_cancelled_responded);
end;
$$;

-- Owner operation (AD-9), run INSIDE the calling source command's transaction:
--   {source_type, source_id, source_revision, recipient_member_id, schedule_type: response|task,
--    intent, kinds: {<anchor>: <reminder_kind>}, fresh?: boolean (default true)}
-- Stores the intent for that source and recipient (one schedule each) and reconciles its future
-- jobs (app.notifications_apply_schedule). `fresh` (a new assignment or a material change) lets a
-- short-notice plan ask for a response now, once per source revision. `respond_now` uses the
-- `response_deadline` kind unless `kinds` names one. Raises validation_failed (bad shape, intent
-- or kinds, unregistered kind), conflict (the source is not current at that revision) or
-- unavailable (Q2 closed or invalid); nothing is written then. Returns {schedule_id,
-- policy_version, plan, entries, enqueued, reinstated, cancelled}.
create function app.notifications_set_schedule(p_schedule jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_policy jsonb;
  v_state jsonb;
  v_id uuid;
  v_result jsonb;
begin
  if jsonb_typeof(p_schedule) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"schedule": "must_be_object"}');
  end if;
  v_errors := jsonb_strip_nulls(
    app.contract_unknown_keys(p_schedule, array['source_type', 'source_id', 'source_revision',
                                                'recipient_member_id', 'schedule_type', 'intent',
                                                'kinds', 'fresh'])
    || jsonb_build_object(
         'source_type', app.contract_token_error(p_schedule -> 'source_type'),
         'source_id', app.contract_uuid_error(p_schedule -> 'source_id'),
         'source_revision', app.contract_revision_error(p_schedule -> 'source_revision'),
         'recipient_member_id', app.contract_uuid_error(p_schedule -> 'recipient_member_id'),
         'schedule_type', case when jsonb_typeof(p_schedule -> 'schedule_type') = 'string'
                                    and (p_schedule ->> 'schedule_type') in ('response', 'task')
                               then null else 'invalid' end,
         'fresh', case when coalesce(jsonb_typeof(p_schedule -> 'fresh'), 'boolean') = 'boolean'
                       then null else 'invalid' end,
         'kinds', case
                    when jsonb_typeof(p_schedule -> 'kinds') is distinct from 'object'
                         or (p_schedule -> 'kinds') = '{}'::jsonb then 'invalid'
                    when exists (select 1 from jsonb_each(p_schedule -> 'kinds') k
                                  where not (k.key = any (coalesce(app.notifications_anchors(p_schedule ->> 'schedule_type'), '{}')
                                                          || array['respond_now']))
                                     or (k.key = 'respond_now' and p_schedule ->> 'schedule_type' <> 'response')
                                     or app.contract_token_error(k.value) is not null) then 'invalid'
                  end));
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_policy := app.notifications_policy();
  -- Validates the intent before anything is written (the plan is recomputed when applied).
  perform app.notifications_plan(v_policy, p_schedule ->> 'schedule_type', p_schedule -> 'intent',
                                 now(), false);
  if exists (select 1 from jsonb_each_text(p_schedule -> 'kinds') k
              where not exists (select 1 from app.contract_reminder_contracts c
                                 where c.source_type = p_schedule ->> 'source_type'
                                   and c.reminder_kind = k.value)) then
    perform app.cmd_fail('validation_failed', '{"kinds": "unregistered"}');
  end if;
  if not exists (select 1 from app.identity_members m
                  where m.member_id = (p_schedule ->> 'recipient_member_id')::uuid) then
    perform app.cmd_fail('validation_failed', '{"recipient_member_id": "unknown"}');
  end if;
  v_state := app.contract_check_source(jsonb_build_object(
    'source_type', p_schedule -> 'source_type', 'source_id', p_schedule -> 'source_id',
    'source_revision', p_schedule -> 'source_revision'));
  if not (v_state ->> 'current')::boolean then
    perform app.cmd_fail('conflict');
  end if;
  insert into app.notifications_schedules as s (
      source_type, source_id, recipient_member_id, source_revision, schedule_type, intent, kinds,
      plan, policy_version, policy_source, policy_digest)
  values (p_schedule ->> 'source_type', (p_schedule ->> 'source_id')::uuid,
          (p_schedule ->> 'recipient_member_id')::uuid,
          (p_schedule ->> 'source_revision')::numeric::bigint, p_schedule ->> 'schedule_type',
          p_schedule -> 'intent', p_schedule -> 'kinds', '{}'::jsonb,
          (v_policy ->> 'version')::integer, v_policy ->> 'source', v_policy ->> 'digest')
  on conflict (source_type, source_id, recipient_member_id) do update
     set source_revision = excluded.source_revision, schedule_type = excluded.schedule_type,
         intent = excluded.intent, kinds = excluded.kinds, schedule_state = 'active',
         end_reason = null,
         cancelled_kinds = case when s.source_revision = excluded.source_revision
                                then s.cancelled_kinds else '{}' end,
         updated_at = clock_timestamp()
  returning s.schedule_id into v_id;
  v_result := app.notifications_apply_schedule(v_id, v_policy,
                                               coalesce((p_schedule ->> 'fresh')::boolean, true));
  return jsonb_build_object('schedule_id', v_id, 'policy_version', (v_policy ->> 'version')::integer,
                            'plan', (select s.plan from app.notifications_schedules s
                                      where s.schedule_id = v_id))
         || v_result;
end;
$$;

comment on function app.notifications_set_schedule(jsonb) is
  'Notifications owner operation (AD-9): store a source''s reminder schedule intent for one '
  'recipient and reconcile its future jobs inside the calling source command''s transaction. '
  'Not client-executable.';

-- Operator only (no grants): after a policy change, re-plan every active schedule under the
-- current policy in this one transaction. A schedule whose source moved past its revision
-- becomes `stale` (its source re-plans it); a schedule whose recheck or plan raises keeps its
-- jobs and is counted `failed` (content-free log). Past-due work is never enqueued.
-- Returns counts only.
create function app.notifications_replan_all(p_reason text default 'policy_changed')
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_policy jsonb := app.notifications_policy();
  v_row record;
  v_state jsonb;
  v_result jsonb;
  v_replanned integer := 0;
  v_stale integer := 0;
  v_failed integer := 0;
  v_enqueued integer := 0;
  v_cancelled integer := 0;
begin
  if app.contract_token_error(to_jsonb(p_reason)) is not null then
    raise exception using errcode = '22023', message = 'reason must be a lower_snake_case token';
  end if;
  for v_row in
    select s.schedule_id, s.source_type, s.source_id, s.source_revision
      from app.notifications_schedules s
     where s.schedule_state = 'active'
     order by s.schedule_id
       for update
  loop
    begin
      v_state := app.contract_check_source(jsonb_build_object(
        'source_type', v_row.source_type, 'source_id', v_row.source_id,
        'source_revision', v_row.source_revision));
      if not (v_state ->> 'current')::boolean then
        update app.notifications_schedules s
           set schedule_state = 'stale', end_reason = 'source_revised', updated_at = clock_timestamp()
         where s.schedule_id = v_row.schedule_id;
        v_stale := v_stale + 1;
        continue;
      end if;
      v_result := app.notifications_apply_schedule(v_row.schedule_id, v_policy, false);
      v_replanned := v_replanned + 1;
      v_enqueued := v_enqueued + (v_result ->> 'enqueued')::integer + (v_result ->> 'reinstated')::integer;
      v_cancelled := v_cancelled + (v_result ->> 'cancelled')::integer;
    exception when others then
      raise log 'notifications.replan_all schedule failed: sqlstate %', sqlstate;
      v_failed := v_failed + 1;
    end;
  end loop;
  raise log 'notifications.replan_all (%): policy version %, replanned %, stale %, failed %',
    p_reason, v_policy ->> 'version', v_replanned, v_stale, v_failed;
  return jsonb_build_object('policy_version', (v_policy ->> 'version')::integer,
                            'replanned', v_replanned, 'stale', v_stale, 'failed', v_failed,
                            'enqueued', v_enqueued, 'cancelled', v_cancelled);
end;
$$;

-- Owner operation for the inbox (entry 7 wraps it for the signed-in member): snooze one of the
-- member's delivered items. The source must still be current, actionable and admit the member
-- (else conflict {"item_id": "superseded"}); the reminder fires again at now() + choice, clamped
-- to the job's expiry (conflict {"item_id": "expired"} once expired). Only this member's copy
-- moves: the source, its deadline and other recipients' reminders are untouched. A new snooze
-- replaces the item's earlier pending one; a source revision change or cancellation cancels it
-- with the source's other jobs. Returns {scheduled_at, clamped, expires_at}.
create function app.notifications_snooze_item(p_member uuid, p_item_id uuid, p_choice text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_policy jsonb := app.notifications_policy();
  v_item app.notifications_inbox_items;
  v_job app.notifications_jobs;
  v_schedule app.notifications_schedules;
  v_check jsonb;
  v_at jsonb;
begin
  select i.* into v_item from app.notifications_inbox_items i
   where i.item_id = p_item_id and i.recipient_member_id = p_member;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  select j.* into v_job from app.notifications_jobs j where j.job_id = v_item.job_id for update;
  v_check := app.contract_check_reminder(app.notifications_job_key(v_job));
  if not ((v_check ->> 'current')::boolean and (v_check ->> 'actionable')::boolean
          and (v_check ->> 'recipient_eligible')::boolean) then
    perform app.cmd_fail('conflict', '{"item_id": "superseded"}');
  end if;
  -- A scheduled reminder must still be wanted by its schedule: active, the kind not cancelled,
  -- and not a response reminder once the member has responded.
  if v_job.schedule_id is not null then
    select s.* into v_schedule from app.notifications_schedules s
     where s.schedule_id = v_job.schedule_id;
    if v_schedule.schedule_state <> 'active'
       or v_schedule.source_revision <> v_job.source_revision
       or v_job.reminder_kind = any (v_schedule.cancelled_kinds)
       or (coalesce((v_schedule.intent ->> 'responded')::boolean, false)
           and v_job.reminder_kind = any (app.notifications_response_kinds(v_schedule.kinds))) then
      perform app.cmd_fail('conflict', '{"item_id": "superseded"}');
    end if;
  end if;
  v_at := app.notifications_snooze_at(v_policy, p_choice, now(), v_job.expires_at);
  update app.notifications_jobs j
     set job_state = 'cancelled', finished_at = clock_timestamp(), cancel_reason = 'snooze_replaced'
   where j.snoozed_from_item_id = v_item.item_id and j.job_state = 'pending';
  perform app.notifications_enqueue_job(jsonb_build_object(
      'source_type', v_job.source_type, 'source_id', v_job.source_id,
      'source_revision', v_job.source_revision, 'recipient_member_id', v_job.recipient_member_id,
      'reminder_kind', v_job.reminder_kind, 'scheduled_at', v_at ->> 'scheduled_at'),
    v_job.expires_at, v_job.schedule_id, v_item.item_id);
  return v_at || jsonb_build_object('expires_at', case when v_job.expires_at is not null
                                                       then app.cmd_utc(v_job.expires_at) end);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges: nothing here is client-executable
-- ---------------------------------------------------------------------------------------------

alter table app.notifications_schedules enable row level security;
revoke all on table app.notifications_schedules from public, anon, authenticated, service_role;

revoke all on function
  app.notifications_duration_error(jsonb),
  app.notifications_duration_minutes(text),
  app.notifications_shift(timestamptz, text, integer, text),
  app.notifications_local(timestamptz, text),
  app.notifications_anchors(text),
  app.notifications_anchor_rank(text),
  app.notifications_reminders_error(jsonb, text, integer, text),
  app.notifications_policy_errors(jsonb),
  app.notifications_policy(),
  app.notifications_response_deadline(jsonb, timestamptz, timestamptz, timestamptz, timestamptz),
  app.notifications_intent_errors(text, jsonb, jsonb),
  app.notifications_plan(jsonb, text, jsonb, timestamptz, boolean),
  app.notifications_occurrences(jsonb, jsonb, timestamptz, timestamptz),
  app.notifications_snooze_at(jsonb, text, timestamptz, timestamptz),
  app.notifications_enqueue_job(jsonb, timestamptz, uuid, uuid),
  app.notifications_enqueue(jsonb),
  app.notifications_cancel(jsonb),
  app.notifications_apply_schedule(uuid, jsonb, boolean, timestamptz),
  app.notifications_response_kinds(jsonb),
  app.notifications_set_schedule(jsonb),
  app.notifications_replan_all(text),
  app.notifications_snooze_item(uuid, uuid, text)
  from public, anon, authenticated, service_role;
