-- Content-free reminder health for live Admins and explicitly mapped operators.
-- The mapping only authorizes this projection; operator procedures stay private.

-- Worker claim rows describe job processing, not scheduler delivery. Track the last
-- scheduler tick that successfully handed work to the Edge Function separately.
alter table app.notifications_scheduler_state
  add column last_success_at timestamptz;

update app.notifications_scheduler_state
   set last_success_at = last_tick_at
 where singleton and last_tick_outcome = 'sent' and last_tick_at is not null;

create or replace function app.notifications_scheduler_note(p_outcome text)
returns jsonb
language sql
set search_path = ''
as $$
  update app.notifications_scheduler_state s
     set last_tick_at = clock_timestamp(),
         last_tick_outcome = p_outcome,
         last_success_at = case when p_outcome = 'sent' then clock_timestamp()
                                else s.last_success_at end,
         ticks = s.ticks + 1
   where s.singleton;
  select jsonb_build_object('tick', p_outcome);
$$;

-- No foreign key to auth.users: an app-schema backup must restore into an isolated database
-- that has no auth schema (story 2.11 / 1.10 restore drill). The health read instead requires
-- the mapped Auth user to exist and pass the identity session and standing checks, and the
-- triggers below clear the mapping when that Auth user is deleted or soft-deleted.
alter table app.ops_operators
  add column auth_user_id uuid unique;

comment on column app.ops_operators.auth_user_id is
  'Optional Auth account explicitly mapped by the owner for reminder-health reads only. '
  'Not a foreign key (restorable without the auth schema); cleared when the Auth user is deleted.';

create function app.ops_operators_clear_auth_mapping()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update app.ops_operators o set auth_user_id = null where o.auth_user_id = old.id;
  return null;
end;
$$;

comment on function app.ops_operators_clear_auth_mapping() is
  'Clears a reminder-health operator mapping when its Auth user is deleted or soft-deleted.';

revoke all on function app.ops_operators_clear_auth_mapping()
  from public, anon, authenticated, service_role;

create trigger ops_operators_auth_mapping_delete
  after delete on auth.users
  for each row
  execute function app.ops_operators_clear_auth_mapping();

create trigger ops_operators_auth_mapping_soft_delete
  after update of deleted_at on auth.users
  for each row
  when (old.deleted_at is null and new.deleted_at is not null)
  execute function app.ops_operators_clear_auth_mapping();

create function app.notifications_health()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_scheduler jsonb;
  v_last_tick timestamptz;
  v_last_success timestamptz;
  v_tick_outcome text;
  v_access text;
  v_admin boolean := false;
  v_operator boolean := false;
  v_push_attempts jsonb;
begin
  -- One evaluation of the live-access predicate for both paths. An unauthenticated or untrusted
  -- session (no live password session, or an Auth user that is deleted, banned or anonymous) is
  -- refused explicitly before either the Admin or the mapped-operator path is considered.
  select e.outcome into v_access from app.identity_evaluate_grant('admin', null, null) e;
  if auth.uid() is null or v_access is null or v_access in ('unauthenticated', 'untrusted_session') then
    raise exception using errcode = 'PT401', message = 'unauthenticated',
      detail = coalesce(v_access, 'unauthenticated');
  end if;
  v_admin := v_access = 'granted';
  if not v_admin then
    -- Mapped operator: an active operator mapped to this live Auth user. A member account in
    -- review, on hold or dormant (review_required) is refused; an operator account without a
    -- member link (not_linked) or without the Admin role (not_granted) may read.
    select exists (select 1 from app.ops_operators o
                     join auth.users u on u.id = o.auth_user_id
                    where o.active and o.auth_user_id = auth.uid()
                      and u.deleted_at is null and not coalesce(u.is_anonymous, false)
                      and (u.banned_until is null or u.banned_until <= now()))
       and v_access in ('not_linked', 'not_granted', 'unavailable')
      into v_operator;
  end if;
  if not v_admin and not v_operator then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = v_access;
  end if;

  v_scheduler := app.notifications_scheduler_status();
  v_last_tick := nullif(v_scheduler ->> 'last_tick_at', '')::timestamptz;
  v_tick_outcome := v_scheduler ->> 'last_tick_outcome';
  return jsonb_build_object(
    'captured_at', app.cmd_utc(clock_timestamp()),
    'scheduler', jsonb_build_object(
      'last_tick_at', case when v_last_tick is not null then app.cmd_utc(v_last_tick) end,
      'last_tick_outcome', v_tick_outcome,
      'last_success_at', (select app.cmd_utc(s.last_success_at)
                            from app.notifications_scheduler_state s where s.singleton),
      'jobs', coalesce((v_scheduler ->> 'scheduler_jobs')::integer, 0),
      'cron_runs_24h', coalesce(v_scheduler -> 'cron_runs_24h', '{}'::jsonb),
      'stale', v_last_tick is null or v_last_tick < now() - interval '5 minutes'),
    'jobs', jsonb_build_object(
      'due_pending', (select count(*) from app.notifications_jobs j
                       where j.job_state = 'pending' and j.scheduled_at <= now()),
      'oldest_due_at', (select app.cmd_utc(min(j.scheduled_at)) from app.notifications_jobs j
                         where j.job_state = 'pending' and j.scheduled_at <= now()),
      'leased', (select count(*) from app.notifications_jobs j
                  where j.job_state = 'pending' and j.lease_expires_at > now()),
      'failed_attempts_24h', (select count(*) from app.notifications_attempts a
                               where a.channel = 'inbox' and a.outcome in ('failed', 'exhausted')
                                 and a.attempted_at >= now() - interval '24 hours'),
      'lapsed_leases_24h', (select count(*) from app.notifications_attempts a
                             where a.channel = 'inbox' and a.outcome = 'lapsed'
                               and a.attempted_at >= now() - interval '24 hours')),
    'push', jsonb_build_object(
      'enabled', coalesce((v_scheduler -> 'push' ->> 'enabled')::boolean, false),
      'outbound_open', app.policy_is_open('outbound_sending'),
      'pending', coalesce((v_scheduler -> 'push' ->> 'pending')::integer, 0),
      'leased', coalesce((v_scheduler -> 'push' ->> 'leased')::integer, 0),
      'failed_attempts_24h',
        coalesce((v_scheduler -> 'push' -> 'attempts_24h' ->> 'transient')::integer, 0)
        + coalesce((v_scheduler -> 'push' -> 'attempts_24h' ->> 'rejected')::integer, 0)
        + coalesce((v_scheduler -> 'push' -> 'attempts_24h' ->> 'exhausted')::integer, 0)),
    'tokens', jsonb_build_object(
      'retired', (select count(*) from app.notifications_device_tokens t where t.retired_at is not null),
      'retired_24h', (select count(*) from app.notifications_device_tokens t
                       where t.retired_at >= now() - interval '24 hours'),
      'last_retired_at', (select app.cmd_utc(max(t.retired_at))
                            from app.notifications_device_tokens t where t.retired_at is not null)),
    'direct_contact', jsonb_build_object(
      'backlog', (select count(*) from app.notifications_direct_contact_needs),
      'oldest_due_at', (select app.cmd_utc(min(n.due_at)) from app.notifications_direct_contact_needs n)));
end;
$$;

create function api.notifications_health()
returns jsonb
language sql
security definer
set search_path = ''
as $$ select app.notifications_health(); $$;

comment on function api.notifications_health() is
  'Content-free reminder health projection for live Admins and explicitly mapped operators.';

revoke all on function app.notifications_health(), api.notifications_health()
  from public, anon, authenticated, service_role;
grant execute on function api.notifications_health() to authenticated;

create or replace function app.notifications_push_claim(p_principal uuid, p_request uuid, p_limit integer)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_settings app.notifications_worker_settings := app.notifications_worker_config();
  v_push app.notifications_push_jobs;
  v_token bigint;
  v_exhausted boolean;
  v_jobs jsonb := '[]'::jsonb;
  v_claimed integer := 0;
  v_reclaimed integer := 0;
  v_expired integer := 0;
begin
  for v_push in
    select p.* from app.notifications_push_jobs p
     where p.push_state = 'pending' and p.lease_token is not null and p.lease_expires_at <= now()
       and not exists (select 1 from app.notifications_attempts a
                        where a.push_job_id = p.push_job_id and a.lease_token = p.lease_token
                          and a.principal_id = p.lease_principal and a.outcome <> 'fenced')
     order by p.lease_expires_at, p.push_job_id
     limit 500
     for update skip locked
  loop
    v_exhausted := v_push.failed_attempts + v_push.lapsed_attempts + 1 >= v_settings.max_attempts;
    perform app.notifications_push_attempt_row(v_push, v_push.lease_token, v_push.lease_principal,
      v_push.lease_request, case when v_exhausted then 'exhausted' else 'lapsed' end,
      case when v_exhausted then 'attempts_exhausted' end, null);
    update app.notifications_push_jobs p
       set lapsed_attempts = p.lapsed_attempts + 1, lease_token = null, lease_principal = null,
           lease_request = null, lease_expires_at = null
     where p.push_job_id = v_push.push_job_id;
    if v_exhausted then
      perform app.notifications_push_exhaust(v_push.push_job_id);
    end if;
    v_reclaimed := v_reclaimed + 1;
  end loop;

  for v_push in
    select p.* from app.notifications_push_jobs p
     where p.push_state = 'pending' and p.expires_at <= now()
       and (p.lease_expires_at is null or p.lease_expires_at <= now())
     order by p.expires_at, p.push_job_id
     limit 500
     for update skip locked
  loop
    perform app.notifications_push_finish(v_push.push_job_id, 'obsolete', 'expired');
    v_expired := v_expired + 1;
  end loop;

  if v_settings.push_enabled and app.policy_is_open('outbound_sending') then
    for v_push in
      select p.* from app.notifications_push_jobs p
       where p.push_state = 'pending' and p.expires_at > now()
         and (p.lease_expires_at is null or p.lease_expires_at <= now())
         and (p.last_failed_at is null
              or p.last_failed_at <= now() - make_interval(
                   secs => app.notifications_backoff_seconds(p.failed_attempts, v_settings)))
       order by p.failed_attempts, p.created_at, p.push_job_id
       limit greatest(p_limit, 0)
       for update skip locked
    loop
      v_token := nextval('app.notifications_lease_token_seq');
      update app.notifications_push_jobs p
         set lease_token = v_token, lease_principal = p_principal, lease_request = p_request,
             lease_expires_at = now() + make_interval(secs => v_settings.lease_seconds)
       where p.push_job_id = v_push.push_job_id;
      v_jobs := v_jobs || jsonb_build_object('push_job_id', v_push.push_job_id, 'lease_token', v_token);
      v_claimed := v_claimed + 1;
    end loop;
  end if;

  return jsonb_build_object('jobs', v_jobs, 'claimed', v_claimed, 'reclaimed', v_reclaimed,
                            'expired', v_expired, 'lease_seconds', v_settings.lease_seconds,
                            'push_enabled', v_settings.push_enabled);
end;
$$;

create or replace function app.notifications_push_prepare(p_principal uuid, p_request uuid, p_push_job_id uuid,
                                               p_token bigint)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_settings app.notifications_worker_settings := app.notifications_worker_config();
  v_push app.notifications_push_jobs;
  v_job app.notifications_jobs;
  v_contract app.contract_reminder_contracts;
  v_state jsonb;
  v_schedule app.notifications_schedules;
  v_route record;
  v_recipient uuid;
  v_targets jsonb;
  v_ttl bigint;
  v_outcome text;
  v_reason text;
  v_sqlstate text;
begin
  -- AD-2 lock order: Identity (the member row) before any Notifications lock.
  select p.recipient_member_id into v_recipient from app.notifications_push_jobs p
   where p.push_job_id = p_push_job_id;
  if v_recipient is not null then
    perform 1 from app.identity_members m where m.member_id = v_recipient for key share;
  end if;
  select p.* into v_push from app.notifications_push_jobs p where p.push_job_id = p_push_job_id for update;
  if not found then
    return '{"outcome": "not_found"}'::jsonb;
  end if;

  if v_push.lease_token is distinct from p_token or v_push.lease_principal is distinct from p_principal then
    v_outcome := 'fenced';
  elsif v_push.push_state <> 'pending' then
    v_outcome := case when v_push.push_state = 'cancelled' then 'cancelled' else 'finished' end;
    v_reason := v_push.finish_reason;
  elsif v_push.lease_expires_at <= now() then
    v_outcome := 'fenced';
  elsif v_push.expires_at <= now() + interval '1 second' then
    v_outcome := 'expired';
    v_reason := 'expired';
    perform app.notifications_push_finish(v_push.push_job_id, 'obsolete', v_reason);
  elsif not app.policy_is_open('outbound_sending') then
    update app.notifications_push_jobs p
       set lease_token = null, lease_principal = null, lease_request = null, lease_expires_at = null
     where p.push_job_id = v_push.push_job_id and p.lease_token = p_token
       and p.lease_principal = p_principal;
    return jsonb_build_object('outcome', 'gate_closed');
  else
    begin
      select j.* into v_job from app.notifications_jobs j where j.job_id = v_push.job_id;
      select c.* into v_contract from app.contract_reminder_contracts c
       where c.source_type = v_job.source_type and c.reminder_kind = v_job.reminder_kind;
      if not found then
        v_reason := 'no_contract';
      else
        v_state := app.contract_check_reminder(app.notifications_job_key(v_job));
        if not (v_state ->> 'current')::boolean then
          v_reason := 'source_changed';
        elsif not (v_state ->> 'actionable')::boolean then
          v_reason := 'not_actionable';
        elsif not (v_state ->> 'recipient_eligible')::boolean then
          v_reason := 'recipient_ineligible';
        end if;
      end if;
      if v_reason is null and v_job.schedule_id is not null then
        select s.* into v_schedule from app.notifications_schedules s
         where s.schedule_id = v_job.schedule_id;
        if v_schedule.schedule_state is distinct from 'active'
           or v_schedule.source_revision <> v_job.source_revision
           or v_job.reminder_kind = any (v_schedule.cancelled_kinds)
           or (coalesce((v_schedule.intent ->> 'responded')::boolean, false)
               and v_job.reminder_kind = any (app.notifications_response_kinds(v_schedule.kinds))) then
          v_reason := 'schedule_changed';
        end if;
      end if;
      if v_reason is null and exists (select 1 from app.notifications_jobs s
                                       where s.snoozed_from_item_id = v_push.item_id) then
        v_reason := 'snoozed';
      end if;
      if v_reason is null then
        select r.* into v_route from app.notifications_recipient_route(v_push.recipient_member_id) r;
        if v_route.route is distinct from 'member' or v_route.account_id is distinct from v_push.account_id then
          v_reason := 'recipient_changed';
        end if;
      end if;
      if v_reason is null and exists (
           select 1 from app.notifications_push_settings s
            where s.account_id = v_push.account_id and s.member_id = v_push.recipient_member_id
              and s.source_type = v_job.source_type and s.reminder_kind = v_job.reminder_kind
              and not s.push_enabled) then
        v_reason := 'push_disabled';
      end if;
      if v_reason is not null then
        v_outcome := 'obsolete';
        perform app.notifications_push_finish(v_push.push_job_id, 'obsolete', v_reason);
      else
        select coalesce(jsonb_agg(jsonb_build_object('device_id', t.device_id, 'platform', t.platform,
                                                     'token', t.token)), '[]'::jsonb)
          into v_targets
          from app.notifications_push_owed(v_push) t;
        if v_targets = '[]'::jsonb then
          if app.notifications_push_accepted_any(v_push.push_job_id) then
            v_outcome := 'accepted';
            v_reason := 'accepted';
            perform app.notifications_push_finish(v_push.push_job_id, 'accepted', v_reason);
          else
            v_outcome := 'obsolete';
            v_reason := 'no_live_token';
            perform app.notifications_push_finish(v_push.push_job_id, 'obsolete', v_reason);
          end if;
        else
          v_ttl := least(floor(extract(epoch from (v_push.expires_at - now()))), 2419200)::bigint;
          return jsonb_build_object(
            'outcome', 'send',
            'message', jsonb_build_object(
              'notification_id', v_push.item_id, 'item_id', v_push.item_id,
              'title', v_contract.title, 'body', v_contract.body,
              'ttl_seconds', v_ttl,
              'expires_at_epoch', floor(extract(epoch from v_push.expires_at))::bigint),
            'targets', v_targets);
        end if;
      end if;
    exception
      when query_canceled then
        v_sqlstate := sqlstate;
      when others then
        v_sqlstate := sqlstate;
    end;
    if v_sqlstate is not null then
      raise log 'notifications.push_prepare recheck failed: sqlstate %', v_sqlstate;
      v_reason := null;
      v_outcome := app.notifications_push_fail(v_push, v_settings);
      if v_outcome = 'exhausted' then
        v_reason := 'attempts_exhausted';
      end if;
    end if;
  end if;

  perform app.notifications_push_attempt_row(v_push, p_token, p_principal, p_request, v_outcome,
    case when v_outcome in ('fenced', 'failed') then null else v_reason end, v_sqlstate);
  return jsonb_strip_nulls(jsonb_build_object('outcome', v_outcome, 'finish_reason',
    case when v_outcome in ('fenced', 'failed') then null else v_reason end));
end;
$$;

-- Enforce the owner-controlled outbound gate at the worker command boundary. Inbox delivery is
-- unchanged; when closed, push claims and preparations return no work or device tokens.
create or replace function app.notifications_sys_push_claim(p_principal uuid, p_request uuid,
                                                              p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_settings app.notifications_worker_settings := app.notifications_worker_config();
begin
  if not app.policy_is_open('outbound_sending') then
    return jsonb_build_object('data', jsonb_build_object(
      'jobs', '[]'::jsonb, 'claimed', 0, 'reclaimed', 0, 'expired', 0,
      'lease_seconds', v_settings.lease_seconds,
      'push_enabled', false, 'gate_closed', true));
  end if;
  if coalesce((p_payload ->> 'expire_only')::boolean, false) then
    return jsonb_build_object('data', app.notifications_push_claim(p_principal, p_request, 0));
  end if;
  return jsonb_build_object('data', app.notifications_push_claim(
    p_principal, p_request, least(coalesce((p_payload ->> 'limit')::numeric::integer,
      v_settings.batch_max), v_settings.batch_max)));
end;
$$;

create or replace function app.notifications_sys_push_prepare(p_principal uuid, p_request uuid,
                                                                p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  return jsonb_build_object('data', app.notifications_push_prepare(
    p_principal, p_request, (p_payload ->> 'push_job_id')::uuid,
    (p_payload ->> 'lease_token')::bigint));
end;
$$;

revoke all on function app.notifications_health(),
  app.notifications_sys_push_claim(uuid, uuid, jsonb),
  app.notifications_sys_push_prepare(uuid, uuid, jsonb)
  from public, anon, authenticated, service_role;
