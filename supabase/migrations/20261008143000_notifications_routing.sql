-- Story 3.5: route recipients by current access and retire their work on lifecycle events
-- (AD-3, AD-8, AD-14; epic 3 requirement N5).
--
--   * Routing. Before a due job becomes an inbox item the worker resolves its recipient through
--     CURRENT Identity state (no locks; AD-2 orders Identity first):
--       - an approved member whose live account link has standing `ok` (active link, approved
--         binding, no open hold, no review) gets the one inbox item and, when push is allowed for
--         that account and category and the account has a live device token, ONE pending
--         member-push job (entry 6 sends it);
--       - an approved member who is held, in review or has no live link (accountless), and a
--         deactivated member, get no item and no push job: a direct-contact need is recorded in
--         Notifications and handed to the direct-contact route the source owner registered with
--         its reminder contract (`app.contract_register_direct_contact_route`). The job ends
--         `ineligible` with finish reason `direct_contact` (or `no_direct_contact_route` when the
--         source registered none; the need is then recorded `unrouted`);
--       - a deleted member (deletion tombstone), or one who was never approved, ends `ineligible`
--         (`member_deleted` / `membership_inactive`) with nothing recorded.
--     A need carries the notification key and a need id only: never a contact route, so a
--     relative's or household number never becomes a destination.
--   * Per-account device tokens and push settings by category (a category is a reminder kind
--     with a registered reminder contract), through the 1.4 envelope `api.notifications_command`
--     (`notifications.register_device`, `notifications.retire_device`,
--     `notifications.set_push_category`) and the read `api.notifications_my_push_settings()`.
--     Tokens are never returned.
--   * Lifecycle hooks (`sessions_revoked`, `access_hold_applied`, `membership_deactivated`,
--     `account_deactivated`, `deletion_requested`) retire the member's tokens and cancel their
--     pending member-push jobs in Identity's transaction; `deletion_requested` also cancels the
--     member's pending jobs and ends their schedules.
--   * Deletion hook `app.notifications_erase_member` (jobs, attempts, inbox items, schedules,
--     needs, push jobs, tokens, settings). The SYNTHETIC fixture's deletion hook now also covers
--     `fixture_reminder_sources` and the fixture's direct-contact needs and is registered here.
--     The row deletions are fail-closed stubs here (`unavailable`), replaced by the small
--     follow-up `20261008143100_notifications_routing_rows.sql` (applied by hand on hosted
--     projects, as 2.11's rows file).
--   * Enqueue refuses a recipient with a deletion tombstone, so nothing recreates their data.
--   * SYNTHETIC: `fixture.reminder_create_for {member_id, due_at}` (an Admin, SYNTHETIC members,
--     local/staging) and the fixture's direct-contact route into `fixture_reminder_contact_needs`.
--
-- No destructive statements and no row deletions. No anon grant.

-- ---------------------------------------------------------------------------------------------
-- Direct-contact routes (platform registry, beside the reminder contracts)
-- ---------------------------------------------------------------------------------------------

create table app.contract_direct_contact_routes (
  source_type text not null,
  reminder_kind text not null,
  module text not null references app.contract_modules (module),
  handler text not null,
  registered_at timestamptz not null default now(),
  primary key (source_type, reminder_kind),
  foreign key (source_type, reminder_kind)
    references app.contract_reminder_contracts (source_type, reminder_kind)
);

comment on table app.contract_direct_contact_routes is
  'Registered direct-contact routes (AD-8, N5): per reminder contract, the source owner''s '
  '(jsonb need) -> void handler that puts a reminder need on its leader''s Needs direct contact list.';

-- Registered by the module that owns the source type, for a kind with a reminder contract. The
-- handler is (jsonb) returns void with search_path = ''. Registering again replaces it.
create function app.contract_register_direct_contact_route(
  p_module text,
  p_source_type text,
  p_reminder_kind text,
  p_handler regprocedure
) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_handler text;
begin
  perform app.contract_require_source_owner(p_module, p_source_type);
  if not exists (select 1 from app.contract_reminder_contracts c
                  where c.source_type = p_source_type and c.reminder_kind = p_reminder_kind) then
    perform app.contract_registration_fail(
      format('reminder kind %s of source type %s has no reminder contract', p_reminder_kind,
             p_source_type));
  end if;
  v_handler := app.contract_validate_handler(p_module, p_handler, 'void'::regtype);
  insert into app.contract_direct_contact_routes (source_type, reminder_kind, module, handler)
  values (p_source_type, p_reminder_kind, p_module, v_handler)
  on conflict (source_type, reminder_kind) do update
     set module = excluded.module, handler = excluded.handler, registered_at = now();
end;
$$;

-- Hands one need {need_id, source_type, source_id, source_revision, recipient_member_id,
-- reminder_kind, scheduled_at} to the registered route. Returns false when none is registered;
-- a missing handler raises PCTR1 (the caller retries).
create function app.contract_route_direct_contact(p_need jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_handler text;
  v_proc regprocedure;
begin
  select r.handler into v_handler from app.contract_direct_contact_routes r
   where r.source_type = p_need ->> 'source_type' and r.reminder_kind = p_need ->> 'reminder_kind';
  if not found then
    return false;
  end if;
  v_proc := pg_catalog.to_regprocedure(v_handler);
  if v_proc is null then
    raise log 'registered direct-contact route % is missing', v_handler;
    raise exception using errcode = 'PCTR1', message = 'registered direct-contact route is missing';
  end if;
  execute format('select %s($1)', v_proc::regproc) using p_need;
  return true;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Tables (owner: notifications)
-- ---------------------------------------------------------------------------------------------

create table app.notifications_direct_contact_needs (
  need_id uuid primary key default gen_random_uuid(),
  job_id uuid not null references app.notifications_jobs (job_id),
  source_type text not null,
  source_id uuid not null,
  source_revision bigint not null,
  recipient_member_id uuid not null references app.identity_members (member_id),
  reminder_kind text not null,
  due_at timestamptz not null,
  route_state text not null check (route_state in ('routed', 'unrouted')),
  routed_at timestamptz not null default clock_timestamp(),
  routed_by_principal uuid not null
);

create unique index notifications_direct_contact_needs_job
  on app.notifications_direct_contact_needs (job_id);
create index notifications_direct_contact_needs_recipient
  on app.notifications_direct_contact_needs (recipient_member_id);

comment on table app.notifications_direct_contact_needs is
  'owner: notifications. One row per due job whose recipient cannot get member delivery (held, '
  'in review, deactivated or accountless): the need went to the source''s direct-contact route '
  '(`routed`) or no route is registered (`unrouted`). Key and times only, no contact data.';

create table app.notifications_device_tokens (
  device_id uuid primary key default gen_random_uuid(),
  account_id uuid not null,
  member_id uuid not null references app.identity_members (member_id),
  platform text not null check (platform in ('android', 'ios')),
  token text not null check (token ~ '^[A-Za-z0-9_:.-]+$' and length(token) between 20 and 4096),
  revision bigint not null default 1 check (revision >= 1),
  registered_at timestamptz not null default clock_timestamp(),
  refreshed_at timestamptz not null default clock_timestamp(),
  retired_at timestamptz,
  retire_reason text check (retire_reason ~ '^[a-z][a-z0-9_]{0,62}$'),
  check ((retired_at is null) = (retire_reason is null))
);

create unique index notifications_device_tokens_live_token
  on app.notifications_device_tokens (token) where retired_at is null;
create index notifications_device_tokens_member on app.notifications_device_tokens (member_id);
create index notifications_device_tokens_account on app.notifications_device_tokens (account_id);

comment on table app.notifications_device_tokens is
  'owner: notifications. Push registrations per account (AD-8). A token belongs to one account; '
  'it is retired by lifecycle events, by the member, or when another account registers it. '
  'The token is never returned by a read or an answer.';

create table app.notifications_push_settings (
  setting_id uuid primary key default gen_random_uuid(),
  account_id uuid not null,
  member_id uuid not null references app.identity_members (member_id),
  source_type text not null,
  reminder_kind text not null,
  push_enabled boolean not null,
  revision bigint not null default 1 check (revision >= 1),
  updated_at timestamptz not null default clock_timestamp(),
  foreign key (source_type, reminder_kind)
    references app.contract_reminder_contracts (source_type, reminder_kind)
);

create unique index notifications_push_settings_category
  on app.notifications_push_settings (account_id, source_type, reminder_kind);
create index notifications_push_settings_member on app.notifications_push_settings (member_id);

comment on table app.notifications_push_settings is
  'owner: notifications. Push on/off per account and category (reminder kind with a contract). '
  'No row means push on. Turning push off never removes in-app items.';

create table app.notifications_push_jobs (
  push_job_id uuid primary key default gen_random_uuid(),
  item_id uuid not null references app.notifications_inbox_items (item_id),
  job_id uuid not null references app.notifications_jobs (job_id),
  recipient_member_id uuid not null references app.identity_members (member_id),
  account_id uuid not null,
  push_state text not null default 'pending'
    check (push_state in ('pending', 'cancelled', 'accepted', 'failed', 'obsolete')),
  expires_at timestamptz not null,
  created_at timestamptz not null default clock_timestamp(),
  finished_at timestamptz,
  finish_reason text check (finish_reason ~ '^[a-z][a-z0-9_]{0,62}$'),
  check ((push_state = 'pending') = (finished_at is null))
);

create unique index notifications_push_jobs_item on app.notifications_push_jobs (item_id);
create index notifications_push_jobs_pending on app.notifications_push_jobs (recipient_member_id)
  where push_state = 'pending';
create index notifications_push_jobs_account on app.notifications_push_jobs (account_id);

comment on table app.notifications_push_jobs is
  'owner: notifications. One member-push job per inbox item of an active linked account that '
  'allows push for the category and has a live token. Entry 6 sends pending jobs (provider '
  'acceptance only, never delivery); lifecycle events cancel them.';

-- ---------------------------------------------------------------------------------------------
-- Routing
-- ---------------------------------------------------------------------------------------------

-- The recipient's route from current Identity state (no locks):
--   member          approved, live link with standing `ok` (account_id is that link's account)
--   direct_contact  approved but held, in review or without a live link; or deactivated
--   none            deleted (`member_deleted`) or never approved (`membership_inactive`)
create function app.notifications_recipient_route(p_member_id uuid)
returns table (route text, reason text, account_id uuid)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_state text;
  v_link app.identity_account_links;
  v_standing text;
begin
  select m.membership_state into v_state from app.identity_members m where m.member_id = p_member_id;
  if v_state is null or exists (select 1 from app.identity_deletions d where d.member_id = p_member_id) then
    return query select 'none'::text, 'member_deleted'::text, null::uuid;
    return;
  end if;
  if v_state = 'deactivated' then
    return query select 'direct_contact'::text, null::text, null::uuid;
    return;
  end if;
  if v_state <> 'approved' then
    return query select 'none'::text, 'membership_inactive'::text, null::uuid;
    return;
  end if;
  select l.* into v_link from app.identity_account_links l
   where l.member_id = p_member_id and l.link_state <> 'ended';
  if not found then
    return query select 'direct_contact'::text, null::text, null::uuid;
    return;
  end if;
  select s.outcome into v_standing from app.identity_account_standing(v_link.auth_user_id) s
   where s.member_id = p_member_id;
  if v_standing is distinct from 'ok' then
    return query select 'direct_contact'::text, null::text, null::uuid;
    return;
  end if;
  return query select 'member'::text, null::text, v_link.auth_user_id;
end;
$$;

-- Records the job's direct-contact need (once per job) and hands it to the source's route.
-- Returns {need_id, routed}.
create function app.notifications_route_need(p_job app.notifications_jobs, p_principal uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_need app.notifications_direct_contact_needs;
  v_routed boolean;
begin
  select n.* into v_need from app.notifications_direct_contact_needs n where n.job_id = p_job.job_id;
  if found then
    return jsonb_build_object('need_id', v_need.need_id, 'routed', v_need.route_state = 'routed');
  end if;
  v_need.need_id := gen_random_uuid();
  v_routed := app.contract_route_direct_contact(
    app.notifications_job_key(p_job) || jsonb_build_object('need_id', v_need.need_id));
  insert into app.notifications_direct_contact_needs (need_id, job_id, source_type, source_id,
                                                      source_revision, recipient_member_id,
                                                      reminder_kind, due_at, route_state,
                                                      routed_by_principal)
  values (v_need.need_id, p_job.job_id, p_job.source_type, p_job.source_id, p_job.source_revision,
          p_job.recipient_member_id, p_job.reminder_kind, p_job.scheduled_at,
          case when v_routed then 'routed' else 'unrouted' end, p_principal);
  return jsonb_build_object('need_id', v_need.need_id, 'routed', v_routed);
end;
$$;

-- One pending member-push job for a new inbox item, when the account allows push for the
-- category (no setting = on) and has a live token for this member. Returns true when created.
create function app.notifications_queue_push(p_item_id uuid, p_job app.notifications_jobs,
                                             p_account uuid)
returns boolean
language plpgsql
set search_path = ''
as $$
begin
  if exists (select 1 from app.notifications_push_settings s
              where s.account_id = p_account and s.member_id = p_job.recipient_member_id
                and s.source_type = p_job.source_type and s.reminder_kind = p_job.reminder_kind
                and not s.push_enabled)
     or not exists (select 1 from app.notifications_device_tokens t
                     where t.account_id = p_account and t.member_id = p_job.recipient_member_id
                       and t.retired_at is null) then
    return false;
  end if;
  insert into app.notifications_push_jobs (item_id, job_id, recipient_member_id, account_id, expires_at)
  values (p_item_id, p_job.job_id, p_job.recipient_member_id, p_account,
          app.notifications_job_expiry(p_job, app.notifications_worker_config()))
  on conflict (item_id) do nothing;
  return found;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Attempt (story 3.4, replaced in place: same signature, outcomes and answer)
-- ---------------------------------------------------------------------------------------------

-- As in story 3.4. The recipient step now routes through current Identity state: the source's
-- `recipient_eligible` false ends the job `ineligible` (`recipient_ineligible`) as before; then
-- a recipient without member delivery ends `ineligible` with `direct_contact` (need routed),
-- `no_direct_contact_route` (need recorded `unrouted`), `member_deleted` or
-- `membership_inactive`; an active linked account gets the item and, if allowed, one pending
-- member-push job. A raising direct-contact route is transient like a raising check.
create or replace function app.notifications_attempt(p_principal uuid, p_request uuid, p_job_id uuid,
                                                     p_token bigint)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_settings app.notifications_worker_settings := app.notifications_worker_config();
  v_job app.notifications_jobs;
  v_state jsonb;
  v_schedule app.notifications_schedules;
  v_route record;
  v_need jsonb;
  v_item_id uuid;
  v_outcome text;
  v_reason text;
  v_sqlstate text;
begin
  select j.* into v_job from app.notifications_jobs j where j.job_id = p_job_id for update;
  if not found then
    return '{"outcome": "not_found"}'::jsonb;
  end if;

  if v_job.lease_token is distinct from p_token or v_job.lease_principal is distinct from p_principal then
    v_outcome := 'fenced';
  elsif v_job.job_state <> 'pending' then
    v_outcome := case when v_job.job_state = 'cancelled' then 'cancelled' else 'finished' end;
    v_reason := coalesce(v_job.finish_reason, v_job.cancel_reason);
  elsif v_job.lease_expires_at <= now() then
    v_outcome := 'fenced';
  elsif app.notifications_job_expiry(v_job, v_settings) <= now() then
    v_outcome := 'expired';
    v_reason := 'expired';
    perform app.notifications_finish_job(v_job.job_id, 'obsolete', v_reason, p_principal, p_request);
  else
    begin
      if not exists (select 1 from app.contract_reminder_contracts c
                      where c.source_type = v_job.source_type
                        and c.reminder_kind = v_job.reminder_kind) then
        v_outcome := 'obsolete';
        v_reason := 'no_contract';
      else
        v_state := app.contract_check_reminder(app.notifications_job_key(v_job));
        if not (v_state ->> 'current')::boolean then
          v_outcome := 'obsolete';
          v_reason := 'source_changed';
        elsif not (v_state ->> 'actionable')::boolean then
          v_outcome := 'obsolete';
          v_reason := 'not_actionable';
        end if;
      end if;
      if v_outcome is null and v_job.schedule_id is not null then
        select s.* into v_schedule from app.notifications_schedules s
         where s.schedule_id = v_job.schedule_id;
        if v_schedule.schedule_state is distinct from 'active'
           or v_schedule.source_revision <> v_job.source_revision
           or v_job.reminder_kind = any (v_schedule.cancelled_kinds)
           or (coalesce((v_schedule.intent ->> 'responded')::boolean, false)
               and v_job.reminder_kind = any (app.notifications_response_kinds(v_schedule.kinds))) then
          v_outcome := 'obsolete';
          v_reason := 'schedule_changed';
        end if;
      end if;
      if v_outcome is null then
        if not (v_state ->> 'recipient_eligible')::boolean then
          v_outcome := 'ineligible';
          v_reason := 'recipient_ineligible';
        else
          -- Read only (no lock): AD-2 orders Identity before Notifications.
          select r.* into v_route from app.notifications_recipient_route(v_job.recipient_member_id) r;
          if v_route.route = 'none' then
            v_outcome := 'ineligible';
            v_reason := v_route.reason;
          elsif v_route.route = 'direct_contact' then
            v_need := app.notifications_route_need(v_job, p_principal);
            v_outcome := 'ineligible';
            v_reason := case when (v_need ->> 'routed')::boolean then 'direct_contact'
                             else 'no_direct_contact_route' end;
          end if;
        end if;
      end if;
      if v_outcome is null then
        insert into app.notifications_inbox_items (job_id, recipient_member_id, reminder_kind,
                                                   due_at, delivered_by_principal)
        values (v_job.job_id, v_job.recipient_member_id, v_job.reminder_kind, v_job.scheduled_at,
                p_principal)
        on conflict (job_id) do nothing
        returning item_id into v_item_id;
        if v_item_id is not null then
          perform app.notifications_queue_push(v_item_id, v_job, v_route.account_id);
        end if;
        v_outcome := 'delivered';
        v_reason := 'delivered';
        perform app.notifications_finish_job(v_job.job_id, 'delivered', v_reason, p_principal, p_request);
      else
        perform app.notifications_finish_job(v_job.job_id,
          case when v_outcome = 'ineligible' then 'ineligible' else 'obsolete' end,
          v_reason, p_principal, p_request);
      end if;
    exception
      -- A slow owner check cancelled by the role's statement_timeout must be counted too
      -- (OTHERS does not match it). The rest of this call is short and bounded.
      when query_canceled then
        v_sqlstate := sqlstate;
      when others then
        v_sqlstate := sqlstate;
    end;
    if v_sqlstate is not null then
      -- Content-free diagnostics (no ids), like the command kernel.
      raise log 'notifications.attempt recheck failed: sqlstate %', v_sqlstate;
      v_outcome := null;
      v_reason := null;
      update app.notifications_jobs j
         set failed_attempts = j.failed_attempts + 1, last_failed_at = clock_timestamp(),
             lease_expires_at = least(j.lease_expires_at, now())
       where j.job_id = v_job.job_id;
      if v_job.failed_attempts + 1 + v_job.lapsed_attempts >= v_settings.max_attempts then
        v_outcome := 'exhausted';
        v_reason := 'attempts_exhausted';
        perform app.notifications_finish_job(v_job.job_id, 'obsolete', v_reason, p_principal, p_request);
      else
        v_outcome := 'failed';
      end if;
    end if;
  end if;

  insert into app.notifications_attempts (job_id, lease_token, principal_id, request_id, outcome,
                                          finish_reason, error_sqlstate)
  values (v_job.job_id, p_token, p_principal, p_request, v_outcome,
          case when v_outcome in ('fenced', 'failed') then null else v_reason end, v_sqlstate);
  return jsonb_strip_nulls(jsonb_build_object('outcome', v_outcome, 'finish_reason',
    case when v_outcome in ('fenced', 'failed') then null else v_reason end,
    'sqlstate', v_sqlstate));
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Enqueue (story 3.3, replaced in place): a deleted member is never a recipient again
-- ---------------------------------------------------------------------------------------------

create or replace function app.notifications_enqueue_job(p_key jsonb, p_expires_at timestamptz,
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
  -- Story 3.5: after a deletion request nothing may recreate the member's notification data.
  if exists (select 1 from app.identity_deletions d
              where d.member_id = (v_key ->> 'recipient_member_id')::uuid) then
    perform app.cmd_fail('validation_failed', '{"recipient_member_id": "deleted"}');
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

-- ---------------------------------------------------------------------------------------------
-- Lifecycle hooks (run inside Identity's transaction; never raise on missing rows)
-- ---------------------------------------------------------------------------------------------

-- Every event: the member's live tokens are retired and their pending member-push jobs
-- cancelled, with the event name as the reason. `deletion_requested` also cancels the member's
-- pending jobs and ends their active schedules (`member_deleted`), so no reminder is planned or
-- delivered for them again.
create function app.notifications_on_member_lifecycle(p_event jsonb)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_event ->> 'member_id')::uuid;
  v_event text := p_event ->> 'event';
begin
  update app.notifications_device_tokens t
     set retired_at = clock_timestamp(), retire_reason = v_event
   where t.member_id = v_member and t.retired_at is null;
  update app.notifications_push_jobs p
     set push_state = 'cancelled', finished_at = clock_timestamp(), finish_reason = v_event
   where p.recipient_member_id = v_member and p.push_state = 'pending';
  if v_event = 'deletion_requested' then
    update app.notifications_schedules s
       set schedule_state = 'ended', end_reason = 'member_deleted', updated_at = clock_timestamp()
     where s.recipient_member_id = v_member and s.schedule_state = 'active';
    update app.notifications_jobs j
       set job_state = 'cancelled', finished_at = clock_timestamp(), cancel_reason = 'member_deleted'
     where j.recipient_member_id = v_member and j.job_state = 'pending';
  end if;
end;
$$;

comment on function app.notifications_on_member_lifecycle(jsonb) is
  'Notifications lifecycle hook (story 3.5): retire tokens and cancel member-push jobs; on a '
  'deletion request also cancel pending jobs and end schedules.';

select app.contract_register_lifecycle_hook('notifications', e,
         'app.notifications_on_member_lifecycle(jsonb)'::regprocedure)
  from unnest(array['sessions_revoked', 'access_hold_applied', 'membership_deactivated',
                    'account_deactivated', 'deletion_requested']) e;

-- ---------------------------------------------------------------------------------------------
-- Deletion hook (story 2.11 contract) and its fail-closed row stub
-- ---------------------------------------------------------------------------------------------

-- The member's notification rows (and every row of the account): replaced by
-- 20261008143100_notifications_routing_rows.sql. Returns the number of rows removed.
create function app.notifications_deletion_purge_rows(p_member_id uuid, p_account_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
begin
  perform app.cmd_fail('unavailable', '{"deletion": "rows_migration_missing"}');
  return null;
end;
$$;

-- The member's remaining notification rows (jobs and their attempts, inbox items, schedules,
-- needs, push jobs) and the account's tokens, settings and push jobs.
create function app.notifications_deletion_remaining(p_member_id uuid, p_account_id uuid)
returns integer
language sql
stable
set search_path = ''
as $$
  select ((select count(*) from app.notifications_jobs j where j.recipient_member_id = p_member_id)
        + (select count(*) from app.notifications_attempts a
             join app.notifications_jobs j on j.job_id = a.job_id
            where j.recipient_member_id = p_member_id)
        + (select count(*) from app.notifications_inbox_items i where i.recipient_member_id = p_member_id)
        + (select count(*) from app.notifications_schedules s where s.recipient_member_id = p_member_id)
        + (select count(*) from app.notifications_direct_contact_needs n
            where n.recipient_member_id = p_member_id)
        + (select count(*) from app.notifications_push_jobs p
            where p.recipient_member_id = p_member_id or p.account_id = p_account_id)
        + (select count(*) from app.notifications_device_tokens t
            where t.member_id = p_member_id or t.account_id = p_account_id)
        + (select count(*) from app.notifications_push_settings s
            where s.member_id = p_member_id or s.account_id = p_account_id))::integer;
$$;

-- Notifications' deletion hook: erase removes every notification row of the member and of the
-- account (idempotent); check counts what is left.
create function app.notifications_erase_member(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_input ->> 'member_id')::uuid;
  v_account uuid := nullif(p_input ->> 'account_id', '')::uuid;
begin
  if p_input ->> 'phase' = 'erase' then
    -- A snooze job points at the member's own earlier item: unlink first so items can go.
    update app.notifications_jobs j set snoozed_from_item_id = null
     where j.recipient_member_id = v_member and j.snoozed_from_item_id is not null;
    perform app.notifications_deletion_purge_rows(v_member, v_account);
  end if;
  return jsonb_build_object('remaining', app.notifications_deletion_remaining(v_member, v_account));
end;
$$;

comment on function app.notifications_erase_member(jsonb) is
  'Notifications deletion hook (story 3.5): erase or check the member''s notification data.';

select app.identity_register_deletion_hook('notifications',
         'app.notifications_erase_member(jsonb)'::regprocedure);

-- ---------------------------------------------------------------------------------------------
-- Device tokens and push settings: commands (1.4 envelope) and read
-- ---------------------------------------------------------------------------------------------

-- The caller's member (the authorizer already required a granted session).
create function app.notifications_command_member()
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
begin
  select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
   where e.outcome = 'granted';
  if v_member is null then
    perform app.cmd_fail('forbidden');
  end if;
  return v_member;
end;
$$;

create function app.notifications_device_json(p_row app.notifications_device_tokens)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('device_id', p_row.device_id, 'platform', p_row.platform,
                            'revision', p_row.revision,
                            'registered_at', app.cmd_utc(p_row.registered_at),
                            'refreshed_at', app.cmd_utc(p_row.refreshed_at),
                            'retired', p_row.retired_at is not null);
$$;

-- notifications.register_device {token, platform} (expected_revision null). The same token on
-- the same account refreshes its row; a token live on another account is retired there
-- (`reassigned`); an account keeps at most 10 live tokens (the least recently refreshed is
-- retired, `replaced`).
create function app.notifications_device_register(p_actor uuid, p_expected bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_errors jsonb;
  v_row app.notifications_device_tokens;
begin
  v_errors := jsonb_strip_nulls(jsonb_build_object(
      'token', case when jsonb_typeof(p_payload -> 'token') is distinct from 'string' then 'required'
                    when (p_payload ->> 'token') ~ '^[A-Za-z0-9_:.-]+$'
                         and length(p_payload ->> 'token') between 20 and 4096 then null
                    else 'invalid' end,
      'platform', case when jsonb_typeof(p_payload -> 'platform') is distinct from 'string' then 'required'
                       when (p_payload ->> 'platform') in ('android', 'ios') then null
                       else 'invalid' end))
    || coalesce((select jsonb_object_agg(k, 'unknown_field') from jsonb_object_keys(p_payload) k
                  where k not in ('token', 'platform')), '{}'::jsonb);
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_member := app.notifications_command_member();
  -- Serialise registrations of one token and of one account.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('notifications_device_token:' || (p_payload ->> 'token'), 0));
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('notifications_device_account:' || p_actor::text, 0));
  select t.* into v_row from app.notifications_device_tokens t
   where t.token = p_payload ->> 'token' and t.retired_at is null
   for update;
  if found and v_row.account_id = p_actor and v_row.member_id = v_member then
    update app.notifications_device_tokens t
       set platform = p_payload ->> 'platform', refreshed_at = clock_timestamp(),
           revision = t.revision + 1
     where t.device_id = v_row.device_id
    returning * into v_row;
  else
    if found then
      update app.notifications_device_tokens t
         set retired_at = clock_timestamp(), retire_reason = 'reassigned', revision = t.revision + 1
       where t.device_id = v_row.device_id;
    end if;
    update app.notifications_device_tokens t
       set retired_at = clock_timestamp(), retire_reason = 'replaced', revision = t.revision + 1
     where t.device_id in (select x.device_id from app.notifications_device_tokens x
                            where x.account_id = p_actor and x.retired_at is null
                            order by x.refreshed_at desc, x.device_id desc
                            offset 9);
    insert into app.notifications_device_tokens (account_id, member_id, platform, token)
    values (p_actor, v_member, p_payload ->> 'platform', p_payload ->> 'token')
    returning * into v_row;
  end if;
  return jsonb_build_object('aggregate_type', 'notifications_device', 'aggregate_id', v_row.device_id,
                            'revision', v_row.revision, 'data', app.notifications_device_json(v_row));
end;
$$;

-- notifications.retire_device {device_id} at the device revision: the caller's own live device.
create function app.notifications_device_retire(p_actor uuid, p_expected bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_row app.notifications_device_tokens;
begin
  v_errors := jsonb_strip_nulls(jsonb_build_object(
      'device_id', app.contract_uuid_error(p_payload -> 'device_id')))
    || coalesce((select jsonb_object_agg(k, 'unknown_field') from jsonb_object_keys(p_payload) k
                  where k <> 'device_id'), '{}'::jsonb);
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.notifications_command_member();
  select t.* into v_row from app.notifications_device_tokens t
   where t.device_id = (p_payload ->> 'device_id')::uuid and t.account_id = p_actor
   for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if p_expected is distinct from v_row.revision then
    perform app.cmd_fail('conflict', null, v_row.revision);
  end if;
  if v_row.retired_at is not null then
    perform app.cmd_fail('conflict', '{"device_id": "retired"}', v_row.revision);
  end if;
  update app.notifications_device_tokens t
     set retired_at = clock_timestamp(), retire_reason = 'member_retired', revision = t.revision + 1
   where t.device_id = v_row.device_id
  returning * into v_row;
  return jsonb_build_object('aggregate_type', 'notifications_device', 'aggregate_id', v_row.device_id,
                            'revision', v_row.revision, 'data', app.notifications_device_json(v_row));
end;
$$;

-- notifications.set_push_category {source_type, reminder_kind, push_enabled}: expected_revision
-- null creates the account's setting for that category, the setting's revision updates it.
create function app.notifications_push_category_set(p_actor uuid, p_expected bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_errors jsonb;
  v_row app.notifications_push_settings;
begin
  v_errors := jsonb_strip_nulls(jsonb_build_object(
      'source_type', app.contract_token_error(p_payload -> 'source_type'),
      'reminder_kind', app.contract_token_error(p_payload -> 'reminder_kind'),
      'push_enabled', case when jsonb_typeof(p_payload -> 'push_enabled') is distinct from 'boolean'
                           then 'required' end))
    || coalesce((select jsonb_object_agg(k, 'unknown_field') from jsonb_object_keys(p_payload) k
                  where k not in ('source_type', 'reminder_kind', 'push_enabled')), '{}'::jsonb);
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  if not exists (select 1 from app.contract_reminder_contracts c
                  where c.source_type = p_payload ->> 'source_type'
                    and c.reminder_kind = p_payload ->> 'reminder_kind') then
    perform app.cmd_fail('validation_failed', '{"reminder_kind": "unregistered"}');
  end if;
  v_member := app.notifications_command_member();
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('notifications_push_settings:' || p_actor::text, 0));
  select s.* into v_row from app.notifications_push_settings s
   where s.account_id = p_actor and s.source_type = p_payload ->> 'source_type'
     and s.reminder_kind = p_payload ->> 'reminder_kind'
   for update;
  if not found then
    if p_expected is not null then
      perform app.cmd_fail('conflict');
    end if;
    insert into app.notifications_push_settings (account_id, member_id, source_type, reminder_kind,
                                                 push_enabled)
    values (p_actor, v_member, p_payload ->> 'source_type', p_payload ->> 'reminder_kind',
            (p_payload ->> 'push_enabled')::boolean)
    returning * into v_row;
  else
    if p_expected is distinct from v_row.revision then
      perform app.cmd_fail('conflict', null, v_row.revision);
    end if;
    update app.notifications_push_settings s
       set push_enabled = (p_payload ->> 'push_enabled')::boolean, member_id = v_member,
           revision = s.revision + 1, updated_at = clock_timestamp()
     where s.setting_id = v_row.setting_id
    returning * into v_row;
  end if;
  return jsonb_build_object('aggregate_type', 'notifications_push_setting',
                            'aggregate_id', v_row.setting_id, 'revision', v_row.revision,
                            'data', jsonb_build_object('source_type', v_row.source_type,
                                                       'reminder_kind', v_row.reminder_kind,
                                                       'push_enabled', v_row.push_enabled,
                                                       'revision', v_row.revision));
end;
$$;

-- `notifications.*` member commands need a live member session (the predicate).
create function app.notifications_authorize_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  if coalesce(p_request ->> 'command', '') not in ('notifications.register_device',
                                                   'notifications.retire_device',
                                                   'notifications.set_push_category') then
    return false;
  end if;
  select e.* into r from app.identity_evaluate_grant(null, null, null) e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  return r.outcome = 'granted';
end;
$$;

select app.cmd_register_authorizer('notifications',
         'app.notifications_authorize_command(jsonb)'::regprocedure);

-- Replay scope: the stored device or setting still belongs to the caller's account.
create function app.notifications_command_in_scope(p_actor uuid, p_aggregate_type text,
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
    else false end;
$$;

create function app.notifications_command(p_envelope jsonb)
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
    end,
    'app.notifications_command_in_scope(uuid, text, uuid)'::regprocedure,
    case v_command
      when 'notifications.retire_device' then true
      -- Create (null) or update (the setting's revision): the handler checks which.
      when 'notifications.set_push_category'
        then coalesce(jsonb_typeof(p_envelope -> 'expected_revision'), 'null') <> 'null'
      else false end);
end;
$$;

-- POST /rest/v1/rpc/notifications_command, Content-Profile: api,
-- body {version, command, request_id, expected_revision, payload}.
create function api.notifications_command(jsonb)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.notifications_command($1);
$$;

comment on function api.notifications_command(jsonb) is
  'Story 3.5: the signed-in member''s device tokens and push settings by category '
  '(notifications.register_device {token, platform}, notifications.retire_device {device_id}, '
  'notifications.set_push_category {source_type, reminder_kind, push_enabled}).';

-- The caller's push categories (every reminder kind with a contract; no setting = on) and live
-- devices (never the token). Behind the live-access predicate.
create function app.notifications_my_push_settings()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_account uuid;
  v_categories jsonb;
  v_devices jsonb;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  select l.auth_user_id into v_account from app.identity_account_links l where l.link_id = v_link;
  select coalesce(jsonb_agg(jsonb_build_object(
           'source_type', c.source_type, 'reminder_kind', c.reminder_kind, 'title', c.title,
           'push_enabled', coalesce(s.push_enabled, true), 'revision', s.revision)
           order by c.source_type, c.reminder_kind), '[]'::jsonb)
    into v_categories
    from app.contract_reminder_contracts c
    left join app.notifications_push_settings s
      on s.account_id = v_account and s.member_id = v_member
     and s.source_type = c.source_type and s.reminder_kind = c.reminder_kind;
  select coalesce(jsonb_agg(app.notifications_device_json(t)
           order by t.refreshed_at desc, t.device_id), '[]'::jsonb)
    into v_devices
    from app.notifications_device_tokens t
   where t.account_id = v_account and t.member_id = v_member and t.retired_at is null;
  perform app.identity_record_activity(v_link);
  return jsonb_build_object('categories', v_categories, 'devices', v_devices);
end;
$$;

create function api.notifications_my_push_settings()
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.notifications_my_push_settings();
$$;

comment on function api.notifications_my_push_settings() is
  'Story 3.5: the signed-in member''s push categories and live devices (no tokens).';

-- ---------------------------------------------------------------------------------------------
-- SYNTHETIC fixture: direct-contact route, Admin enqueue for another member, deletion hook
-- ---------------------------------------------------------------------------------------------

create table app.fixture_reminder_contact_needs (
  need_id uuid primary key,
  source_id uuid not null,
  member_id uuid not null references app.identity_members (member_id),
  reminder_kind text not null,
  recorded_at timestamptz not null default clock_timestamp()
);

create index fixture_reminder_contact_needs_member on app.fixture_reminder_contact_needs (member_id);

comment on table app.fixture_reminder_contact_needs is
  'owner: fixture. SYNTHETIC "Needs direct contact" list of the fixture reminder source (story 3.5).';

-- The fixture's direct-contact route: records the need once (idempotent on need_id). It locks
-- no source row, so it cannot deadlock with a fixture command cancelling the source's jobs.
create function app.fixture_reminder_direct_contact(p_need jsonb)
returns void
language sql
set search_path = ''
as $$
  insert into app.fixture_reminder_contact_needs (need_id, source_id, member_id, reminder_kind)
  values ((p_need ->> 'need_id')::uuid, (p_need ->> 'source_id')::uuid,
          (p_need ->> 'recipient_member_id')::uuid, p_need ->> 'reminder_kind')
  on conflict (need_id) do nothing;
$$;

select app.contract_register_direct_contact_route('fixture', 'fixture_reminder', 'fixture_due',
         'app.fixture_reminder_direct_contact(jsonb)'::regprocedure);

-- fixture.reminder_create_for {member_id, due_at}: an Admin creates a reminder for another
-- SYNTHETIC member (any membership state, with or without an account), local/staging only.
create function app.fixture_reminder_create_for(p_actor uuid, p_expected bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_member uuid;
  v_row app.fixture_reminder_sources;
  v_job jsonb;
begin
  v_errors := jsonb_strip_nulls(jsonb_build_object(
      'member_id', app.contract_uuid_error(p_payload -> 'member_id'),
      'due_at', app.contract_instant_error(p_payload -> 'due_at')))
    || coalesce((select jsonb_object_agg(k, 'unknown_field') from jsonb_object_keys(p_payload) k
                  where k not in ('member_id', 'due_at')), '{}'::jsonb);
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  if app.platform_current_environment() not in ('local', 'staging') then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  if not exists (select 1 from app.identity_evaluate_grant('admin', null, null) e
                  where e.outcome = 'granted') then
    perform app.cmd_fail('forbidden');
  end if;
  select m.member_id into v_member from app.identity_members m
   where m.member_id = (p_payload ->> 'member_id')::uuid;
  if v_member is null then
    perform app.cmd_fail('not_found');
  end if;
  if not exists (select 1 from app.identity_members m where m.member_id = v_member and m.is_synthetic) then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  insert into app.fixture_reminder_sources (member_id, due_at, created_by_account)
  values (v_member, (p_payload ->> 'due_at')::timestamptz, p_actor)
  returning * into v_row;
  v_job := app.notifications_enqueue(jsonb_build_object(
    'source_type', 'fixture_reminder', 'source_id', v_row.source_id,
    'source_revision', v_row.revision, 'recipient_member_id', v_member,
    'reminder_kind', v_row.reminder_kind, 'scheduled_at', app.cmd_utc(v_row.due_at)));
  return jsonb_build_object(
    'aggregate_type', 'fixture_reminder', 'aggregate_id', v_row.source_id,
    'revision', v_row.revision,
    'data', app.fixture_reminder_json(v_row)
            || jsonb_build_object('job_state', v_job ->> 'job_state',
                                  'job_created', (v_job ->> 'created')::boolean));
end;
$$;

-- As in 3.2, plus fixture.reminder_create_for, which needs the Admin role.
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
                                                   'fixture.reminder_create_for') then
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

-- Replay scope: the caller's own reminder, or one the caller created for another member.
create or replace function app.fixture_reminder_in_scope(p_actor uuid, p_aggregate_type text,
                                                        p_aggregate_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_aggregate_type = 'fixture_reminder' and exists (
    select 1 from app.fixture_reminder_sources s
     where s.source_id = p_aggregate_id
       and (s.member_id = app.identity_current_member_id() or s.created_by_account = p_actor));
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
    end,
    'app.fixture_reminder_in_scope(uuid, text, uuid)'::regprocedure,
    v_command not in ('fixture.reminder_create', 'fixture.reminder_create_for'));
end;
$$;

comment on function api.fixture_reminder_command(jsonb) is
  'SYNTHETIC (stories 3.1, 3.2, 3.5): a reminder source (fixture.reminder_create '
  '{due_at, reminder_kind?}, fixture.reminder_cancel {source_id}, fixture.reminder_change '
  '{source_id, change: revise|revoke|expire}, and for an Admin fixture.reminder_create_for '
  '{member_id, due_at}) through the 1.4 command envelope; local/staging only.';

-- The fixture's reminder rows of the member (sources and contact needs): replaced by
-- 20261008143100_notifications_routing_rows.sql. Returns the number of rows removed.
create function app.fixture_deletion_purge_rows(p_member_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
begin
  perform app.cmd_fail('unavailable', '{"deletion": "rows_migration_missing"}');
  return null;
end;
$$;

-- As in 2.11 (fixture duties kept as anonymous facts), plus the fixture reminder sources and
-- contact needs of the member; the account in sources created for other members becomes the
-- nil UUID.
create or replace function app.fixture_erase_member(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_input ->> 'member_id')::uuid;
  v_account uuid := nullif(p_input ->> 'account_id', '')::uuid;
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
begin
  if p_input ->> 'phase' = 'erase' then
    update app.fixture_duties d set member_id = v_nil where d.member_id = v_member;
    if v_account is not null then
      update app.fixture_reminder_sources s set created_by_account = v_nil
       where s.created_by_account = v_account and s.member_id <> v_member;
    end if;
    perform app.fixture_deletion_purge_rows(v_member);
  end if;
  return jsonb_build_object('remaining',
    (select count(*) from app.fixture_duties d where d.member_id = v_member)
    + (select count(*) from app.fixture_reminder_sources s
        where s.member_id = v_member or s.created_by_account = v_account)
    + (select count(*) from app.fixture_reminder_contact_needs n where n.member_id = v_member));
end;
$$;

comment on function app.fixture_erase_member(jsonb) is
  'SYNTHETIC deletion hook over app.fixture_duties (anonymised), and since story 3.5 the '
  'fixture reminder sources and contact needs (erased). Registered by migration 3.5.';

select app.identity_register_deletion_hook('fixture', 'app.fixture_erase_member(jsonb)'::regprocedure)
 where not exists (select 1 from app.identity_deletion_hooks h where h.module = 'fixture');

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

alter table app.contract_direct_contact_routes enable row level security;
alter table app.notifications_direct_contact_needs enable row level security;
alter table app.notifications_device_tokens enable row level security;
alter table app.notifications_push_settings enable row level security;
alter table app.notifications_push_jobs enable row level security;
alter table app.fixture_reminder_contact_needs enable row level security;
revoke all on table app.contract_direct_contact_routes, app.notifications_direct_contact_needs,
                    app.notifications_device_tokens, app.notifications_push_settings,
                    app.notifications_push_jobs, app.fixture_reminder_contact_needs
  from public, anon, authenticated, service_role;

revoke all on function
  app.contract_register_direct_contact_route(text, text, text, regprocedure),
  app.contract_route_direct_contact(jsonb),
  app.notifications_recipient_route(uuid),
  app.notifications_route_need(app.notifications_jobs, uuid),
  app.notifications_queue_push(uuid, app.notifications_jobs, uuid),
  app.notifications_attempt(uuid, uuid, uuid, bigint),
  app.notifications_enqueue_job(jsonb, timestamptz, uuid, uuid),
  app.notifications_on_member_lifecycle(jsonb),
  app.notifications_deletion_purge_rows(uuid, uuid),
  app.notifications_deletion_remaining(uuid, uuid),
  app.notifications_erase_member(jsonb),
  app.notifications_command_member(),
  app.notifications_device_json(app.notifications_device_tokens),
  app.notifications_device_register(uuid, bigint, jsonb),
  app.notifications_device_retire(uuid, bigint, jsonb),
  app.notifications_push_category_set(uuid, bigint, jsonb),
  app.notifications_authorize_command(jsonb),
  app.notifications_command_in_scope(uuid, text, uuid),
  app.notifications_command(jsonb),
  api.notifications_command(jsonb),
  app.notifications_my_push_settings(),
  api.notifications_my_push_settings(),
  app.fixture_reminder_direct_contact(jsonb),
  app.fixture_reminder_create_for(uuid, bigint, jsonb),
  app.fixture_authorize_command(jsonb),
  app.fixture_reminder_in_scope(uuid, text, uuid),
  app.fixture_reminder_command(jsonb),
  app.fixture_deletion_purge_rows(uuid),
  app.fixture_erase_member(jsonb)
  from public, anon, authenticated, service_role;

grant execute on function app.notifications_command(jsonb) to authenticated;
grant execute on function api.notifications_command(jsonb) to authenticated;
grant execute on function app.notifications_my_push_settings() to authenticated;
grant execute on function api.notifications_my_push_settings() to authenticated;
grant execute on function app.fixture_reminder_command(jsonb) to authenticated;

notify pgrst, 'reload schema';
