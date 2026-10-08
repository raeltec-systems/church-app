-- Story 3.7: the inbox, notification settings and snooze on mobile and staff web (AD-5, AD-8,
-- AD-13; epic 3 requirements N6, N3).
--
--   * Inbox items record `opened_at` (the member opened the item in the app; set once, by
--     `api.notifications_open_item`) and a `snooze_revision` (bumped by each snooze). Neither says
--     anything about push delivery or reading.
--   * `api.notifications_my_inbox` items gain `opened` and `snoozed_until` (the member's pending
--     snooze of that item, or null). `api.notifications_open_item` marks the item opened and, for
--     a current item only, adds `snooze_choices` (from the Q2 policy) and `snoozed_until`. The
--     superseded and not-found answers are unchanged.
--   * `notifications.snooze_item {item_id, choice}` (1.4 envelope, expected_revision null) on
--     `api.notifications_command` wraps the 3.3 owner operation `app.notifications_snooze_item`
--     for the signed-in member: only that member's copy moves, clamped to the source expiry.
--   * Per-account generic refresh signal (AD-5): after an inbox item is added, opened or snoozed,
--     or a snooze starts or ends, Notifications publishes ONE Realtime Broadcast message per
--     account per transaction: topic `account:<auth user id>`, event `inbox_changed`, payload
--     `{}` (no ids, no text, no source type), private. Only a recipient whose current route is
--     `member` (approved, live link, standing ok) is signalled. Delivery is after commit; a
--     rolled back change sends nothing. When Realtime is absent the publisher does nothing and
--     never fails the caller. One receive-only RLS policy on `realtime.messages` lets an
--     authenticated session read its own `account:<uid>` broadcast topic; there is no insert
--     policy, so clients cannot send.
--   * SYNTHETIC fixture (local/staging only): kind `fixture_reply` with a reminder contract and
--     direct-contact route, `fixture.reminder_schedule {starts_at}` (a response schedule over the
--     3.3 path) and `fixture.reminder_respond {source_id}` (the member answers: pending snoozes
--     of the response reminder are cancelled `responded` and the reminder stops being
--     actionable).
--
-- No destructive statements and no row deletions. No anon grant. No new client-executable
-- function. ASCII only.

-- ---------------------------------------------------------------------------------------------
-- Inbox item markers
-- ---------------------------------------------------------------------------------------------

alter table app.notifications_inbox_items
  add column opened_at timestamptz,
  add column snooze_revision bigint not null default 1
    check (snooze_revision between 1 and 9007199254740991);

comment on column app.notifications_inbox_items.opened_at is
  'Story 3.7: when the member first opened the item in the app. Never push delivery or reading.';
comment on column app.notifications_inbox_items.snooze_revision is
  'Story 3.7: bumped by each member snooze of the item (command envelope revision).';

-- The member's pending snooze of an item (the earliest, there is at most one), or null.
create function app.notifications_item_snoozed_until(p_item_id uuid)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select min(j.scheduled_at) from app.notifications_jobs j
   where j.snoozed_from_item_id = p_item_id and j.job_state = 'pending';
$$;

-- As in 3.2, plus `opened` and `snoozed_until` per item.
create or replace function app.notifications_my_inbox(p_after_delivered_at timestamptz, p_after_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_rows jsonb;
  v_next jsonb;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  if (p_after_delivered_at is null) <> (p_after_item_id is null) then
    raise exception using errcode = '22023', message = 'validation_failed',
      detail = 'after_delivered_at and after_item_id go together';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'item_id', x.item_id,
           'reminder_kind', x.reminder_kind,
           'title', x.title,
           'body', x.body,
           'due_at', app.cmd_utc(x.due_at),
           'delivered_at', app.cmd_utc(x.delivered_at),
           'opened', x.opened_at is not null,
           'snoozed_until', case when x.snoozed_until is not null
                                 then app.cmd_utc(x.snoozed_until) end)
           order by x.delivered_at desc, x.item_id desc), '[]'::jsonb)
    into v_rows
    from (select i.item_id, i.reminder_kind, i.due_at, i.delivered_at, i.opened_at,
                 app.notifications_item_snoozed_until(i.item_id) as snoozed_until,
                 coalesce(c.title, 'Reminder') as title,
                 coalesce(c.body, 'Something needs your attention.') as body
            from app.notifications_inbox_items i
            join app.notifications_jobs j on j.job_id = i.job_id
            left join app.contract_reminder_contracts c
              on c.source_type = j.source_type and c.reminder_kind = j.reminder_kind
           where i.recipient_member_id = v_member
             and (p_after_delivered_at is null
                  or (i.delivered_at, i.item_id) < (p_after_delivered_at, p_after_item_id))
           order by i.delivered_at desc, i.item_id desc
           limit 51) x;
  if jsonb_array_length(v_rows) > 50 then
    v_rows := v_rows - 50;
    v_next := jsonb_build_object('after_delivered_at', v_rows -> 49 -> 'delivered_at',
                                 'after_item_id', v_rows -> 49 -> 'item_id');
  end if;
  perform app.identity_record_activity(v_link);
  return jsonb_build_object('items', v_rows, 'next', v_next);
end;
$$;

-- The snooze choices the policy offers now ([] when the policy is unavailable, for example the
-- production gate is closed: no snooze is offered then).
create function app.notifications_snooze_choices()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  return coalesce(app.notifications_policy() -> 'value' -> 'snooze_choices', '[]'::jsonb);
exception when others then
  return '[]'::jsonb;
end;
$$;

-- As in 3.2. Story 3.7: the first open marks the item opened; a current item also carries the
-- policy's `snooze_choices` and the member's `snoozed_until`. Superseded and not-found answers
-- are unchanged.
create or replace function app.notifications_open_item(p_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_item app.notifications_inbox_items;
  v_job app.notifications_jobs;
  v_contract app.contract_reminder_contracts;
  v_check jsonb;
  v_current boolean;
  v_answer jsonb;
  v_snoozed timestamptz;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  if p_item_id is null then
    raise exception using errcode = '22023', message = 'validation_failed',
      detail = 'item_id is required';
  end if;
  select i.* into v_item from app.notifications_inbox_items i
   where i.item_id = p_item_id and i.recipient_member_id = v_member;
  if not found then
    perform app.identity_record_activity(v_link);
    return '{"state": "not_found"}'::jsonb;
  end if;
  select j.* into v_job from app.notifications_jobs j where j.job_id = v_item.job_id;
  select c.* into v_contract from app.contract_reminder_contracts c
   where c.source_type = v_job.source_type and c.reminder_kind = v_job.reminder_kind;
  if found then
    begin
      v_check := app.contract_check_reminder(app.notifications_job_key(v_job));
    exception when others then
      raise log 'notifications.open_item reminder check failed: sqlstate %', sqlstate;
      raise exception using errcode = 'PT503', message = 'source_check_failed';
    end;
    v_current := (v_check ->> 'current')::boolean and (v_check ->> 'actionable')::boolean
                 and (v_check ->> 'recipient_eligible')::boolean;
  else
    v_current := false;
  end if;
  -- Opened in the app (first time only, so a repeat open changes nothing and signals nothing).
  update app.notifications_inbox_items i set opened_at = clock_timestamp()
   where i.item_id = v_item.item_id and i.opened_at is null;
  perform app.identity_record_activity(v_link);
  v_answer := jsonb_build_object(
    'item_id', v_item.item_id,
    'reminder_kind', v_item.reminder_kind,
    'title', coalesce(v_contract.title, 'Reminder'),
    'body', coalesce(v_contract.body, 'Something needs your attention.'),
    'due_at', app.cmd_utc(v_item.due_at),
    'delivered_at', app.cmd_utc(v_item.delivered_at),
    'state', case when v_current then 'current' else 'superseded' end,
    'target', case when v_current
                   then replace(v_contract.link, '{source_id}', v_job.source_id::text) end);
  if v_current then
    v_snoozed := app.notifications_item_snoozed_until(v_item.item_id);
    v_answer := v_answer || jsonb_build_object(
      'snooze_choices', app.notifications_snooze_choices(),
      'snoozed_until', case when v_snoozed is not null then app.cmd_utc(v_snoozed) end);
  end if;
  return v_answer;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- notifications.snooze_item (member command)
-- ---------------------------------------------------------------------------------------------

-- notifications.snooze_item {item_id, choice} (expected_revision null): the signed-in member
-- snoozes one of their items (story 3.3 rules: current source only, a choice from the policy,
-- clamped to the expiry, replaces an earlier pending snooze of the item). Answers
-- {item_id, scheduled_at, clamped, expires_at} at the item's new revision.
create function app.notifications_item_snooze(p_actor uuid, p_expected bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_errors jsonb;
  v_item app.notifications_inbox_items;
  v_at jsonb;
begin
  v_errors := jsonb_strip_nulls(jsonb_build_object(
      'item_id', app.contract_uuid_error(p_payload -> 'item_id'),
      'choice', case when jsonb_typeof(p_payload -> 'choice') is distinct from 'string'
                     then 'required' end))
    || coalesce((select jsonb_object_agg(k, 'unknown_field') from jsonb_object_keys(p_payload) k
                  where k not in ('item_id', 'choice')), '{}'::jsonb);
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_member := app.notifications_command_member();
  select i.* into v_item from app.notifications_inbox_items i
   where i.item_id = (p_payload ->> 'item_id')::uuid and i.recipient_member_id = v_member
   for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  v_at := app.notifications_snooze_item(v_member, v_item.item_id, p_payload ->> 'choice');
  update app.notifications_inbox_items i set snooze_revision = i.snooze_revision + 1
   where i.item_id = v_item.item_id
  returning * into v_item;
  return jsonb_build_object('aggregate_type', 'notifications_inbox_item',
                            'aggregate_id', v_item.item_id, 'revision', v_item.snooze_revision,
                            'data', jsonb_build_object('item_id', v_item.item_id) || v_at);
end;
$$;

-- As in 3.5, plus notifications.snooze_item.
create or replace function app.notifications_authorize_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  if coalesce(p_request ->> 'command', '') not in ('notifications.register_device',
                                                   'notifications.retire_device',
                                                   'notifications.set_push_category',
                                                   'notifications.snooze_item') then
    return false;
  end if;
  select e.* into r from app.identity_evaluate_grant(null, null, null) e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  return r.outcome = 'granted';
end;
$$;

-- As in 3.5, plus the caller's own inbox item.
create or replace function app.notifications_command_in_scope(p_actor uuid, p_aggregate_type text,
                                                              p_aggregate_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select case p_aggregate_type
    when 'notifications_device' then exists (
      select 1 from app.notifications_device_tokens t
       where t.device_id = p_aggregate_id and t.account_id = p_actor)
    when 'notifications_push_setting' then exists (
      select 1 from app.notifications_push_settings s
       where s.setting_id = p_aggregate_id and s.account_id = p_actor)
    when 'notifications_inbox_item' then exists (
      select 1 from app.notifications_inbox_items i
       where i.item_id = p_aggregate_id
         and i.recipient_member_id = app.identity_current_member_id())
    else false end;
$$;

create or replace function app.notifications_command(p_envelope jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_command text;
begin
  if jsonb_typeof(p_envelope) = 'object' and jsonb_typeof(p_envelope -> 'command') = 'string' then
    v_command := p_envelope ->> 'command';
  end if;
  return app.cmd_execute(
    p_envelope,
    case v_command
      when 'notifications.register_device'
        then 'app.notifications_device_register(uuid, bigint, jsonb)'::regprocedure
      when 'notifications.retire_device'
        then 'app.notifications_device_retire(uuid, bigint, jsonb)'::regprocedure
      when 'notifications.set_push_category'
        then 'app.notifications_push_category_set(uuid, bigint, jsonb)'::regprocedure
      when 'notifications.snooze_item'
        then 'app.notifications_item_snooze(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.notifications_command_in_scope(uuid, text, uuid)'::regprocedure,
    case v_command
      when 'notifications.retire_device' then true
      when 'notifications.set_push_category'
        then coalesce(jsonb_typeof(p_envelope -> 'expected_revision'), 'null') <> 'null'
      else false end);
end;
$$;

comment on function api.notifications_command(jsonb) is
  'Stories 3.5 and 3.7: the signed-in member''s device tokens, push settings by category and '
  'snooze (notifications.register_device {token, platform}, notifications.retire_device '
  '{device_id}, notifications.set_push_category {source_type, reminder_kind, push_enabled}, '
  'notifications.snooze_item {item_id, choice}).';

-- ---------------------------------------------------------------------------------------------
-- Per-account generic refresh signal (AD-5)
-- ---------------------------------------------------------------------------------------------

-- Publishes `inbox_changed` with an empty payload on the private topic `account:<auth uid>` of
-- the member's CURRENT account, once per account per transaction, only while the member's route
-- is `member`. Never raises: without Realtime (or a message partition) nothing is sent and the
-- caller's change still commits; clients re-read on open, resume, reconnect and by polling.
create function app.notifications_publish_refresh(p_member_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid;
  v_sent text;
begin
  if p_member_id is null then
    return;
  end if;
  select r.account_id into v_account from app.notifications_recipient_route(p_member_id) r
   where r.route = 'member';
  if v_account is null then
    return;
  end if;
  v_sent := coalesce(current_setting('app.notifications_refreshed', true), '');
  if position(v_account::text in v_sent) > 0 then
    return;
  end if;
  perform set_config('app.notifications_refreshed', v_sent || v_account::text || ',', true);
  if pg_catalog.to_regclass('realtime.messages') is null then
    return;
  end if;
  begin
    execute 'insert into realtime.messages (topic, extension, payload, event, private) '
            'values ($1, ''broadcast'', ''{}''::jsonb, ''inbox_changed'', true)'
      using 'account:' || v_account::text;
  exception when others then
    raise log 'notifications refresh signal not published: sqlstate %', sqlstate;
  end;
end;
$$;

comment on function app.notifications_publish_refresh(uuid) is
  'Story 3.7 (AD-5): one content-free Realtime broadcast (topic account:<uid>, event '
  'inbox_changed, payload {}) per account per transaction, to a currently routable member only.';

create function app.notifications_inbox_item_signal()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform app.notifications_publish_refresh(new.recipient_member_id);
  return null;
end;
$$;

create trigger notifications_inbox_items_signal_insert
  after insert on app.notifications_inbox_items
  for each row execute function app.notifications_inbox_item_signal();

create trigger notifications_inbox_items_signal_update
  after update of opened_at, snooze_revision on app.notifications_inbox_items
  for each row
  when (old.opened_at is distinct from new.opened_at
        or old.snooze_revision is distinct from new.snooze_revision)
  execute function app.notifications_inbox_item_signal();

-- A snooze job starting or ending changes what the inbox shows (snoozed until).
create trigger notifications_jobs_snooze_signal_insert
  after insert on app.notifications_jobs
  for each row when (new.snoozed_from_item_id is not null)
  execute function app.notifications_inbox_item_signal();

create trigger notifications_jobs_snooze_signal_update
  after update of job_state on app.notifications_jobs
  for each row
  when (new.snoozed_from_item_id is not null and old.job_state is distinct from new.job_state)
  execute function app.notifications_inbox_item_signal();

-- Receive-only channel authorisation: an authenticated session may read broadcasts on its own
-- `account:<uid>` topic. Created only where Realtime's table exists; no insert policy.
do $$
begin
  if pg_catalog.to_regclass('realtime.messages') is not null
     and not exists (select 1 from pg_catalog.pg_policy p
                      where p.polrelid = 'realtime.messages'::regclass
                        and p.polname = 'notifications_account_refresh_receive') then
    execute 'create policy notifications_account_refresh_receive on realtime.messages '
            'for select to authenticated '
            'using (realtime.messages.extension = ''broadcast'' '
            'and (select realtime.topic()) = ''account:'' || (select auth.uid())::text)';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- SYNTHETIC fixture: a response reminder over the 3.3 schedule path (local/staging only)
-- ---------------------------------------------------------------------------------------------

alter table app.fixture_reminder_sources
  add column responded_at timestamptz;

select app.contract_register_reminder_kind('fixture', 'fixture_reminder', 'fixture_reply');

-- As in 3.4 (including the SYNTHETIC check fault); a source the member has answered is no
-- longer actionable.
create or replace function app.fixture_reminder_open_check(p_key jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_row app.fixture_reminder_sources;
begin
  select s.* into v_row from app.fixture_reminder_sources s
   where s.source_id = (p_key ->> 'source_id')::uuid;
  if not found then
    return '{"current": false, "revision": null, "actionable": false, "recipient_eligible": false}'::jsonb;
  end if;
  if v_row.check_fault_until is not null and v_row.check_fault_until > now() then
    raise exception using errcode = 'P0001', message = 'SYNTHETIC transient check fault';
  end if;
  return jsonb_build_object(
    'current', v_row.source_state = 'active'
               and v_row.revision = (p_key ->> 'source_revision')::numeric::bigint,
    'revision', v_row.revision,
    'actionable', v_row.source_state = 'active'
                  and (v_row.expires_at is null or v_row.expires_at > now())
                  and v_row.responded_at is null,
    'recipient_eligible', v_row.member_id = (p_key ->> 'recipient_member_id')::uuid
                          and not v_row.recipient_revoked);
end;
$$;

select app.contract_register_reminder_contract(
  'fixture', 'fixture_reminder', 'fixture_reply',
  'app.fixture_reminder_open_check(jsonb)'::regprocedure,
  '{"title": "SYNTHETIC reply reminder",
    "body": "A test request is waiting for your answer.",
    "link": "/fixture/reminders/{source_id}"}'::jsonb);

select app.contract_register_direct_contact_route('fixture', 'fixture_reminder', 'fixture_reply',
         'app.fixture_reminder_direct_contact(jsonb)'::regprocedure);

-- The response schedule of a fixture reply source (assigned when created, starting at due_at).
create function app.fixture_reminder_reply_schedule(p_row app.fixture_reminder_sources,
                                                    p_fresh boolean)
returns jsonb
language sql
set search_path = ''
as $$
  select app.notifications_set_schedule(jsonb_build_object(
    'source_type', 'fixture_reminder', 'source_id', p_row.source_id,
    'source_revision', p_row.revision, 'recipient_member_id', p_row.member_id,
    'schedule_type', 'response',
    'intent', jsonb_build_object('assigned_at', app.cmd_utc(p_row.created_at),
                                 'starts_at', app.cmd_utc(p_row.due_at),
                                 'responded', p_row.responded_at is not null),
    'kinds', '{"response_deadline": "fixture_reply", "respond_now": "fixture_reply"}'::jsonb,
    'fresh', p_fresh));
$$;

-- fixture.reminder_schedule {starts_at} (expected_revision null): a SYNTHETIC request for the
-- caller's own member that starts (and expires) at starts_at, with a response schedule planned
-- by the 3.3 calculation (short notice: one `respond_now` reminder due now).
create function app.fixture_reminder_schedule(p_actor uuid, p_expected bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_errors jsonb;
  v_row app.fixture_reminder_sources;
  v_schedule jsonb;
begin
  v_errors := jsonb_strip_nulls(jsonb_build_object(
      'starts_at', app.contract_instant_error(p_payload -> 'starts_at')))
    || coalesce((select jsonb_object_agg(k, 'unknown_field') from jsonb_object_keys(p_payload) k
                  where k not in ('starts_at')), '{}'::jsonb);
  if v_errors = '{}'::jsonb and (p_payload ->> 'starts_at')::timestamptz <= now() then
    v_errors := '{"starts_at": "invalid"}'::jsonb;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_member := app.fixture_reminder_actor();
  insert into app.fixture_reminder_sources (member_id, due_at, created_by_account, reminder_kind,
                                            expires_at)
  values (v_member, (p_payload ->> 'starts_at')::timestamptz, p_actor, 'fixture_reply',
          (p_payload ->> 'starts_at')::timestamptz)
  returning * into v_row;
  v_schedule := app.fixture_reminder_reply_schedule(v_row, true);
  return jsonb_build_object(
    'aggregate_type', 'fixture_reminder', 'aggregate_id', v_row.source_id,
    'revision', v_row.revision,
    'data', app.fixture_reminder_json(v_row)
            || jsonb_build_object('enqueued', (v_schedule ->> 'enqueued')::integer,
                                  'response_deadline', v_schedule -> 'plan' -> 'response_deadline'));
end;
$$;

-- fixture.reminder_respond {source_id} at the source revision: the member answers the request.
-- The revision is kept; the schedule records `responded`, which cancels pending snoozes of the
-- reply reminder (`responded`), and the reminder stops being actionable.
create function app.fixture_reminder_respond(p_actor uuid, p_expected bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_errors jsonb;
  v_row app.fixture_reminder_sources;
  v_schedule jsonb;
begin
  v_errors := jsonb_strip_nulls(jsonb_build_object(
      'source_id', app.contract_uuid_error(p_payload -> 'source_id')))
    || coalesce((select jsonb_object_agg(k, 'unknown_field') from jsonb_object_keys(p_payload) k
                  where k not in ('source_id')), '{}'::jsonb);
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_member := app.fixture_reminder_actor();
  select s.* into v_row from app.fixture_reminder_sources s
   where s.source_id = (p_payload ->> 'source_id')::uuid and s.member_id = v_member
   for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if p_expected is distinct from v_row.revision then
    perform app.cmd_fail('conflict', null, v_row.revision);
  end if;
  if v_row.source_state <> 'active' then
    perform app.cmd_fail('conflict', '{"source_id": "cancelled"}', v_row.revision);
  end if;
  if v_row.reminder_kind <> 'fixture_reply' then
    perform app.cmd_fail('validation_failed', '{"source_id": "invalid"}');
  end if;
  if v_row.responded_at is not null then
    perform app.cmd_fail('conflict', '{"source_id": "responded"}', v_row.revision);
  end if;
  update app.fixture_reminder_sources s set responded_at = clock_timestamp()
   where s.source_id = v_row.source_id returning * into v_row;
  v_schedule := app.fixture_reminder_reply_schedule(v_row, false);
  return jsonb_build_object(
    'aggregate_type', 'fixture_reminder', 'aggregate_id', v_row.source_id,
    'revision', v_row.revision,
    'data', app.fixture_reminder_json(v_row)
            || jsonb_build_object('responded', true,
                                  'cancelled_jobs', (v_schedule ->> 'cancelled')::integer));
end;
$$;

-- As in 3.5, plus fixture.reminder_schedule and fixture.reminder_respond (live member session).
create or replace function app.fixture_authorize_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  if coalesce(p_request ->> 'command', '') not in ('fixture.reminder_create',
                                                   'fixture.reminder_cancel',
                                                   'fixture.reminder_change',
                                                   'fixture.reminder_create_for',
                                                   'fixture.reminder_schedule',
                                                   'fixture.reminder_respond') then
    perform 1 from app.fixture_command_grants g
     where g.actor_id = (p_request ->> 'actor')::uuid
       and g.command = p_request ->> 'command'
       and g.revoked_at is null
       for share;
    return found;
  end if;
  select e.* into r from app.identity_evaluate_grant(
    case when p_request ->> 'command' = 'fixture.reminder_create_for' then 'admin' end, null, null) e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  return r.outcome = 'granted';
end;
$$;

create or replace function app.fixture_reminder_command(p_envelope jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_command text;
begin
  if jsonb_typeof(p_envelope) = 'object' and jsonb_typeof(p_envelope -> 'command') = 'string' then
    v_command := p_envelope ->> 'command';
  end if;
  return app.cmd_execute(
    p_envelope,
    case v_command
      when 'fixture.reminder_create' then 'app.fixture_reminder_create(uuid, bigint, jsonb)'::regprocedure
      when 'fixture.reminder_cancel' then 'app.fixture_reminder_cancel(uuid, bigint, jsonb)'::regprocedure
      when 'fixture.reminder_change' then 'app.fixture_reminder_change(uuid, bigint, jsonb)'::regprocedure
      when 'fixture.reminder_create_for' then 'app.fixture_reminder_create_for(uuid, bigint, jsonb)'::regprocedure
      when 'fixture.reminder_schedule' then 'app.fixture_reminder_schedule(uuid, bigint, jsonb)'::regprocedure
      when 'fixture.reminder_respond' then 'app.fixture_reminder_respond(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.fixture_reminder_in_scope(uuid, text, uuid)'::regprocedure,
    v_command not in ('fixture.reminder_create', 'fixture.reminder_create_for',
                      'fixture.reminder_schedule'));
end;
$$;

comment on function api.fixture_reminder_command(jsonb) is
  'SYNTHETIC (stories 3.1, 3.2, 3.5, 3.7): a reminder source (fixture.reminder_create '
  '{due_at, reminder_kind?}, fixture.reminder_cancel {source_id}, fixture.reminder_change '
  '{source_id, change: revise|revoke|expire}, fixture.reminder_schedule {starts_at}, '
  'fixture.reminder_respond {source_id}, and for an Admin fixture.reminder_create_for '
  '{member_id, due_at}) through the 1.4 command envelope; local/staging only.';

-- ---------------------------------------------------------------------------------------------
-- Privileges: nothing new is client-executable (EXECUTE on the replaced entry points is kept)
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.notifications_item_snoozed_until(uuid),
  app.notifications_snooze_choices(),
  app.notifications_item_snooze(uuid, bigint, jsonb),
  app.notifications_publish_refresh(uuid),
  app.notifications_inbox_item_signal(),
  app.fixture_reminder_reply_schedule(app.fixture_reminder_sources, boolean),
  app.fixture_reminder_schedule(uuid, bigint, jsonb),
  app.fixture_reminder_respond(uuid, bigint, jsonb)
  from public, anon, authenticated, service_role;
