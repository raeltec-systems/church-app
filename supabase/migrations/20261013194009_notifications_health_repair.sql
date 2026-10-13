-- owner-approved-cleanup: owner decision 2026-10-13 (review-3.8-3.10 finding 2): drop the auth.users foreign key that breaks app-only backup restore; 3.8 not yet applied to any hosted project
--
-- Repair of 20261013193932_notifications_health.sql after review-3.8-3.10 (findings 2, 6, 8-10,
-- 12, 16, 17). That migration stays as merged; this one, applied right after it:
--   * drops the app.ops_operators.auth_user_id foreign key into auth.users (an app-schema backup
--     must restore into an isolated database without the auth schema). The column stays
--     `uuid unique`; triggers on auth.users clear the mapping when the Auth user is deleted or
--     soft-deleted, and the health read requires a live trusted session of an existing Auth user;
--   * replaces app.notifications_health(): explicit 401 for unauthenticated or untrusted sessions,
--     operator path checks, identity-shaped refusals, stale from last_success_at, windowed
--     direct-contact backlog, every failed push outcome;
--   * replaces app.notifications_sys_push_claim (a closed outbound gate still expires push jobs
--     and counts lapsed leases, and says gate_closed) and app.notifications_sys_push_prepare
--     (lease token cast through numeric).
-- No row deletions; no hand-pasted function is touched; nothing is granted to anon.

-- Default name of the inline foreign key added by 20261013193932.
alter table app.ops_operators drop constraint ops_operators_auth_user_id_fkey;

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

create or replace function app.notifications_health()
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
    -- Same wire shape as app.identity_require_grant, so clients map each reason.
    if v_access = 'unavailable' then
      raise exception using errcode = 'PT403', message = 'unavailable', detail = v_access;
    end if;
    raise exception using errcode = 'PT403', message = 'forbidden', detail = v_access;
  end if;

  v_scheduler := app.notifications_scheduler_status();
  v_last_tick := nullif(v_scheduler ->> 'last_tick_at', '')::timestamptz;
  select s.last_success_at into v_last_success
    from app.notifications_scheduler_state s where s.singleton;
  select coalesce(jsonb_object_agg(a.outcome, a.n), '{}'::jsonb) into v_push_attempts
    from (select t.outcome, count(*) as n from app.notifications_attempts t
           where t.channel = 'push' and t.attempted_at >= now() - interval '24 hours'
           group by t.outcome) a;
  v_tick_outcome := v_scheduler ->> 'last_tick_outcome';
  return jsonb_build_object(
    'captured_at', app.cmd_utc(clock_timestamp()),
    'scheduler', jsonb_build_object(
      'last_tick_at', case when v_last_tick is not null then app.cmd_utc(v_last_tick) end,
      'last_tick_outcome', v_tick_outcome,
      'last_success_at', case when v_last_success is not null then app.cmd_utc(v_last_success) end,
      'jobs', coalesce((v_scheduler ->> 'scheduler_jobs')::integer, 0),
      'cron_runs_24h', coalesce(v_scheduler -> 'cron_runs_24h', '{}'::jsonb),
      -- Stale = no successful hand-off to the worker in five minutes. A tick that only notes
      -- not_configured or gate_closed still moves last_tick_at, so it must not count as fresh.
      'stale', v_last_success is null or v_last_success < now() - interval '5 minutes'),
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
      -- Every unsuccessful push attempt outcome: provider transient/rejected answers, recheck
      -- failures, lapsed leases and exhaustion.
      'failed_attempts_24h', (select coalesce(sum(e.value::integer), 0)::integer
                                from jsonb_each_text(v_push_attempts) e
                               where e.key in ('transient', 'rejected', 'failed', 'lapsed', 'exhausted'))),
    'tokens', jsonb_build_object(
      'retired', (select count(*) from app.notifications_device_tokens t where t.retired_at is not null),
      'retired_24h', (select count(*) from app.notifications_device_tokens t
                       where t.retired_at >= now() - interval '24 hours'),
      'last_retired_at', (select app.cmd_utc(max(t.retired_at))
                            from app.notifications_device_tokens t where t.retired_at is not null)),
    -- The direct-contact table is append-only (one row per need, never closed), so the backlog
    -- is a rolling window: needs with no registered route recorded in the last 24 hours. The
    -- cumulative totals are reported separately.
    'direct_contact', jsonb_build_object(
      'backlog', (select count(*) from app.notifications_direct_contact_needs n
                   where n.route_state = 'unrouted' and n.routed_at >= now() - interval '24 hours'),
      'oldest_due_at', (select app.cmd_utc(min(n.due_at)) from app.notifications_direct_contact_needs n
                         where n.route_state = 'unrouted' and n.routed_at >= now() - interval '24 hours'),
      'routed_24h', (select count(*) from app.notifications_direct_contact_needs n
                      where n.route_state = 'routed' and n.routed_at >= now() - interval '24 hours'),
      'total_unrouted', (select count(*) from app.notifications_direct_contact_needs n
                          where n.route_state = 'unrouted'),
      'total', (select count(*) from app.notifications_direct_contact_needs)));
end;
$$;

-- The owner-controlled outbound gate at the worker command boundary. Inbox delivery is
-- unchanged. While the gate is closed a claim still expires due push jobs and counts lapsed
-- leases (as in 3.6), but app.notifications_push_claim leases nothing and the answer carries
-- `gate_closed: true`; prepare answers `gate_closed` and returns no device tokens.
create or replace function app.notifications_sys_push_claim(p_principal uuid, p_request uuid,
                                                              p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_settings app.notifications_worker_settings := app.notifications_worker_config();
  v_data jsonb;
  -- Read the gate once: the limit and the gate_closed flag come from the same answer, so a gate
  -- closing mid-call can never yield leased jobs together with gate_closed.
  v_open boolean := app.policy_is_open('outbound_sending');
begin
  if not v_open or coalesce((p_payload ->> 'expire_only')::boolean, false) then
    -- Expiry and lapse counting only; nothing is leased.
    v_data := app.notifications_push_claim(p_principal, p_request, 0);
  else
    v_data := app.notifications_push_claim(
      p_principal, p_request, least(coalesce((p_payload ->> 'limit')::numeric::integer,
        v_settings.batch_max), v_settings.batch_max));
  end if;
  if not v_open then
    v_data := v_data || '{"gate_closed": true}'::jsonb;
  end if;
  return jsonb_build_object('data', v_data);
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
    (p_payload ->> 'lease_token')::numeric::bigint));
end;
$$;

revoke all on function app.notifications_health(),
  app.notifications_sys_push_claim(uuid, uuid, jsonb),
  app.notifications_sys_push_prepare(uuid, uuid, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function api.notifications_health() from public, anon, service_role;
grant execute on function api.notifications_health() to authenticated;
