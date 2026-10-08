-- Story 3.1: the Notifications owner module and its first durable path (AD-1, AD-2, AD-8, AD-19;
-- epic 3 requirements N1, N4, N6). A synthetic due reminder reaches the durable inbox.
--
--   * Notifications owns `app.notifications_jobs` (one row per AD-8 logical key: source_type,
--     source_id, source_revision, recipient_member_id, reminder_kind, scheduled_at) and
--     `app.notifications_inbox_items` (one row per job). A job records the source revision and the
--     applied Q2 scheduling policy (its source and the sha256 digest of the effective value; entry
--     3 introduces numbered policy versions).
--   * Owner operations, run INSIDE the calling source command's transaction (no client grants):
--       app.notifications_enqueue(key jsonb)   validates the key through app.contract_reminder_key
--                                               (registered kind, the source's current revision
--                                               through its owner hook, the Q2 gate: fixture in
--                                               local/staging, closed in production) and inserts
--                                               the job once; a repeated key changes nothing.
--       app.notifications_cancel(selector jsonb) cancels the source's pending jobs.
--   * Worker step `notifications.deliver_due {limit?}` on the 1.9 system route, purpose
--     `notifications_worker` (its own principal and credential, AD-19). It claims due pending jobs
--     (`for update skip locked`), rechecks the source through its owner hook and the recipient's
--     approved membership, and writes exactly one inbox item per job (unique job_id). A stale
--     source ends the job `obsolete`, a recipient who is no longer an approved member ends it
--     `ineligible` (entry 5 adds the real routing), and a cancelled or future job is never
--     touched. No leases, attempts, retries or expiry yet (entry 4).
--   * Read `api.notifications_my_inbox(after_delivered_at?, after_item_id?)` behind the
--     live-access predicate (2.1): the caller's own items only, newest first in pages of 50 with a
--     keyset cursor, with no source id, revision or text.
--   * A job whose recheck raises stays pending, records failed_attempts/last_failed_at (and a
--     content-free `raise log`) and backs off min(2^(failures-1), 60) minutes, so it never blocks
--     later due jobs; entry 4 replaces this with attempts, leases and the central retry policy.
--   * SYNTHETIC source `fixture_reminder` (owner: fixture) with self-only 1.4-envelope commands
--     `fixture.reminder_create {due_at}` and `fixture.reminder_cancel {source_id}` through
--     `api.fixture_reminder_command`; local/staging and SYNTHETIC members only. The fixture module
--     gains the dependency edge fixture -> notifications (as 2.3 added fixture -> identity).
--
-- No destructive statements and no row deletions. No anon grant.

-- ---------------------------------------------------------------------------------------------
-- Tables (owner: notifications)
-- ---------------------------------------------------------------------------------------------

create table app.notifications_jobs (
  job_id uuid primary key default gen_random_uuid(),
  source_type text not null,
  source_id uuid not null,
  source_revision bigint not null check (source_revision between 1 and 9007199254740991),
  recipient_member_id uuid not null references app.identity_members (member_id),
  reminder_kind text not null,
  scheduled_at timestamptz not null,
  policy_gate text not null default 'q2_church_time' check (policy_gate = 'q2_church_time'),
  policy_source text not null check (policy_source in ('approved', 'fixture')),
  policy_digest text not null check (policy_digest ~ '^[0-9a-f]{64}$'),
  job_state text not null default 'pending'
    check (job_state in ('pending', 'delivered', 'cancelled', 'obsolete', 'ineligible')),
  enqueued_at timestamptz not null default clock_timestamp(),
  finished_at timestamptz,
  cancel_reason text check (cancel_reason ~ '^[a-z][a-z0-9_]{0,62}$'),
  processed_by_principal uuid,
  processed_request_id uuid,
  -- Minimal failure bookkeeping (entry 4 adds attempts, leases and the retry policy): a job whose
  -- recheck raised is skipped for min(2^(failures-1), 60) minutes so it cannot block later jobs.
  failed_attempts integer not null default 0 check (failed_attempts >= 0),
  last_failed_at timestamptz,
  check ((failed_attempts = 0) = (last_failed_at is null)),
  foreign key (source_type, reminder_kind)
    references app.contract_reminder_kinds (source_type, reminder_kind),
  check ((job_state = 'pending') = (finished_at is null)),
  check ((job_state = 'cancelled') = (cancel_reason is not null)),
  check (job_state in ('pending', 'cancelled') or processed_by_principal is not null)
);

create unique index notifications_jobs_logical_key on app.notifications_jobs
  (source_type, source_id, source_revision, recipient_member_id, reminder_kind, scheduled_at);
create index notifications_jobs_due on app.notifications_jobs (scheduled_at, job_id)
  where job_state = 'pending';
create index notifications_jobs_source on app.notifications_jobs (source_type, source_id)
  where job_state = 'pending';
create index notifications_jobs_recipient on app.notifications_jobs (recipient_member_id);

comment on table app.notifications_jobs is
  'owner: notifications. Durable reminder work (AD-8), one row per logical key. Created and '
  'cancelled only through the owner operations inside the source command''s transaction.';

create table app.notifications_inbox_items (
  item_id uuid primary key default gen_random_uuid(),
  job_id uuid not null references app.notifications_jobs (job_id),
  recipient_member_id uuid not null references app.identity_members (member_id),
  reminder_kind text not null,
  due_at timestamptz not null,
  delivered_at timestamptz not null default clock_timestamp(),
  delivered_by_principal uuid not null
);

create unique index notifications_inbox_items_job on app.notifications_inbox_items (job_id);
create index notifications_inbox_items_recipient
  on app.notifications_inbox_items (recipient_member_id, delivered_at desc, item_id desc);

comment on table app.notifications_inbox_items is
  'owner: notifications. The durable inbox: exactly one item per delivered job, whether or not '
  'push is allowed. Carries no source id, revision or text.';

-- ---------------------------------------------------------------------------------------------
-- Owner operations (called by source owners inside their command transaction)
-- ---------------------------------------------------------------------------------------------

-- Enqueue one reminder job. p_key is a contract v1 `notification_key`. Raises the kernel's
-- validation_failed / conflict (stale source) / unavailable (Q2 gate closed) through
-- app.contract_reminder_key, so the caller's command rolls back with it. Returns
-- {job_id, job_state, created}; a key that already has a job (in any state) changes nothing, so
-- a cancelled job is never revived.
create function app.notifications_enqueue(p_key jsonb)
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
  v_key := app.contract_reminder_key(p_key) -> 'key';
  v_policy := app.policy_effective('q2_church_time');
  if not exists (select 1 from app.identity_members m
                  where m.member_id = (v_key ->> 'recipient_member_id')::uuid) then
    perform app.cmd_fail('validation_failed', '{"recipient_member_id": "unknown"}');
  end if;
  insert into app.notifications_jobs (source_type, source_id, source_revision, recipient_member_id,
                                      reminder_kind, scheduled_at, policy_source, policy_digest)
  values (v_key ->> 'source_type', (v_key ->> 'source_id')::uuid,
          (v_key ->> 'source_revision')::bigint, (v_key ->> 'recipient_member_id')::uuid,
          v_key ->> 'reminder_kind', (v_key ->> 'scheduled_at')::timestamptz,
          v_policy ->> 'source',
          encode(sha256(convert_to((v_policy -> 'value')::text, 'UTF8')), 'hex'))
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
                            'created', v_created);
end;
$$;

comment on function app.notifications_enqueue(jsonb) is
  'Notifications owner operation (AD-8): enqueue one job per logical key inside the calling '
  'source command''s transaction. Not client-executable.';

-- Cancel a source's pending jobs: {source_type, source_id, reason, recipient_member_id?,
-- reminder_kind?}. Delivered items stay (opening re-reads the source: entry 2). Returns
-- {cancelled}. Raises validation_failed on a malformed selector.
create function app.notifications_cancel(p_selector jsonb)
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

comment on function app.notifications_cancel(jsonb) is
  'Notifications owner operation (AD-8): cancel a source''s pending jobs inside the calling '
  'source command''s transaction. Not client-executable.';

-- ---------------------------------------------------------------------------------------------
-- Worker step (system route, purpose notifications_worker)
-- ---------------------------------------------------------------------------------------------

-- Payload of notifications.deliver_due: {limit?: integer 1..100}.
create function app.notifications_check_deliver_due(p_payload jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce((select jsonb_object_agg(k, 'unknown_field') from jsonb_object_keys(p_payload) k
                    where k <> 'limit'), '{}'::jsonb)
      || case when p_payload ? 'limit'
                   and not app.contract_integer_in(p_payload -> 'limit', 1, 100)
              then '{"limit": "out_of_range"}'::jsonb else '{}'::jsonb end;
$$;

-- Claims due pending jobs (fewest failures first, then oldest, skipping rows another worker
-- holds and jobs still backing off after a failure) and turns each into exactly one inbox item
-- after rechecking the source (owner hook) and the recipient. A job whose recheck raises stays
-- pending, is counted `failed` (its subtransaction is rolled back) and backs off
-- min(2^(failures-1), 60) minutes, so a poison job never blocks later due jobs.
-- Answers counts only: no member, source or job ids.
create function app.notifications_sys_deliver_due(p_principal uuid, p_request uuid, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_limit integer := coalesce((p_payload ->> 'limit')::numeric::integer, 50);
  v_job app.notifications_jobs;
  v_state jsonb;
  v_member_state text;
  v_claimed integer := 0;
  v_delivered integer := 0;
  v_obsolete integer := 0;
  v_ineligible integer := 0;
  v_failed integer := 0;
begin
  for v_job in
    select j.* from app.notifications_jobs j
     where j.job_state = 'pending' and j.scheduled_at <= now()
       and (j.last_failed_at is null
            or j.last_failed_at <= now() - interval '1 minute'
                                          * least(power(2, j.failed_attempts - 1), 60))
     order by j.failed_attempts, j.scheduled_at, j.job_id
     limit v_limit
     for update skip locked
  loop
    v_claimed := v_claimed + 1;
    begin
      v_state := app.contract_check_source(jsonb_build_object(
        'source_type', v_job.source_type, 'source_id', v_job.source_id,
        'source_revision', v_job.source_revision));
      if not (v_state ->> 'current')::boolean then
        update app.notifications_jobs j
           set job_state = 'obsolete', finished_at = clock_timestamp(),
               processed_by_principal = p_principal, processed_request_id = p_request
         where j.job_id = v_job.job_id;
        v_obsolete := v_obsolete + 1;
        continue;
      end if;
      -- Read only (no lock): AD-2 orders Identity before Notifications, and this step already
      -- holds the job. Entry 5 replaces this with routing through current Identity state.
      select m.membership_state into v_member_state
        from app.identity_members m where m.member_id = v_job.recipient_member_id;
      if v_member_state is distinct from 'approved' then
        update app.notifications_jobs j
           set job_state = 'ineligible', finished_at = clock_timestamp(),
               processed_by_principal = p_principal, processed_request_id = p_request
         where j.job_id = v_job.job_id;
        v_ineligible := v_ineligible + 1;
        continue;
      end if;
      insert into app.notifications_inbox_items (job_id, recipient_member_id, reminder_kind, due_at,
                                                 delivered_by_principal)
      values (v_job.job_id, v_job.recipient_member_id, v_job.reminder_kind, v_job.scheduled_at,
              p_principal)
      on conflict (job_id) do nothing;
      update app.notifications_jobs j
         set job_state = 'delivered', finished_at = clock_timestamp(),
             processed_by_principal = p_principal, processed_request_id = p_request
       where j.job_id = v_job.job_id;
      v_delivered := v_delivered + 1;
    exception when others then
      -- Content-free diagnostics (no ids), like the command kernel.
      raise log 'notifications.deliver_due job recheck failed: sqlstate %', sqlstate;
      update app.notifications_jobs j
         set failed_attempts = j.failed_attempts + 1, last_failed_at = clock_timestamp()
       where j.job_id = v_job.job_id;
      v_failed := v_failed + 1;
    end;
  end loop;
  return jsonb_build_object('data', jsonb_build_object(
    'claimed', v_claimed, 'delivered', v_delivered, 'obsolete', v_obsolete,
    'ineligible', v_ineligible, 'failed', v_failed));
end;
$$;

insert into app.sys_command_kinds (command, purpose, description, payload_check, handler) values
  ('notifications.deliver_due', 'notifications_worker',
   'Story 3.1: turn due pending reminder jobs into durable inbox items (one per job)',
   'app.notifications_check_deliver_due(jsonb)',
   'app.notifications_sys_deliver_due(uuid, uuid, jsonb)');

-- ---------------------------------------------------------------------------------------------
-- Read: the signed-in member's own inbox
-- ---------------------------------------------------------------------------------------------

-- Newest first, pages of 50 with a keyset cursor (delivered_at, item_id): pass both `after_*`
-- values from the previous page's `next`, or neither. Behind the live-access predicate (401/403
-- like the 2.1 read); a half cursor is 400.
create function app.notifications_my_inbox(p_after_delivered_at timestamptz, p_after_item_id uuid)
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
           'due_at', app.cmd_utc(x.due_at),
           'delivered_at', app.cmd_utc(x.delivered_at))
           order by x.delivered_at desc, x.item_id desc), '[]'::jsonb)
    into v_rows
    from (select i.item_id, i.reminder_kind, i.due_at, i.delivered_at
            from app.notifications_inbox_items i
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

create function api.notifications_my_inbox(after_delivered_at timestamptz default null,
                                           after_item_id uuid default null)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.notifications_my_inbox(after_delivered_at, after_item_id);
$$;

comment on function api.notifications_my_inbox(timestamptz, uuid) is
  'Story 3.1: the signed-in member''s durable inbox, newest first in pages of 50 (keyset cursor '
  '`next`), behind the live-access predicate. POST /rest/v1/rpc/notifications_my_inbox with '
  'Content-Profile: api.';

-- ---------------------------------------------------------------------------------------------
-- SYNTHETIC source: fixture_reminder (owner: fixture)
-- ---------------------------------------------------------------------------------------------

insert into app.contract_module_dependencies (from_module, to_module) values ('fixture', 'notifications');

create table app.fixture_reminder_sources (
  source_id uuid primary key default gen_random_uuid(),
  member_id uuid not null references app.identity_members (member_id),
  revision bigint not null default 1 check (revision >= 1),
  source_state text not null default 'active' check (source_state in ('active', 'cancelled')),
  due_at timestamptz not null,
  created_by_account uuid not null,
  created_at timestamptz not null default clock_timestamp(),
  is_synthetic boolean not null default true check (is_synthetic)
);

create index fixture_reminder_sources_member on app.fixture_reminder_sources (member_id);

comment on table app.fixture_reminder_sources is
  'owner: fixture. SYNTHETIC reminder source for the story 3.1 inbox tracer (self-only, '
  'local/staging only).';

-- Source check hook: current while active at exactly the given revision.
create function app.fixture_reminder_check(p_source jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_row app.fixture_reminder_sources;
begin
  select s.* into v_row from app.fixture_reminder_sources s
   where s.source_id = (p_source ->> 'source_id')::uuid;
  if not found then
    return '{"current": false}'::jsonb;
  end if;
  return jsonb_build_object(
    'current', v_row.source_state = 'active'
               and v_row.revision = (p_source ->> 'source_revision')::numeric::bigint,
    'revision', v_row.revision);
end;
$$;

select app.contract_register_source_type(
  'fixture', 'fixture_reminder', 'app.fixture_reminder_check(jsonb)'::regprocedure);
select app.contract_register_reminder_kind('fixture', 'fixture_reminder', 'fixture_due');

-- The caller's member for a fixture command (authorised in this transaction), local/staging
-- and SYNTHETIC members only.
create function app.fixture_reminder_actor()
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
begin
  if app.platform_current_environment() not in ('local', 'staging') then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
   where e.outcome = 'granted';
  if v_member is null then
    perform app.cmd_fail('forbidden');
  end if;
  if not exists (select 1 from app.identity_members m
                  where m.member_id = v_member and m.is_synthetic) then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  return v_member;
end;
$$;

create function app.fixture_reminder_json(p_row app.fixture_reminder_sources)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('source_id', p_row.source_id, 'revision', p_row.revision,
                            'state', p_row.source_state, 'due_at', app.cmd_utc(p_row.due_at));
$$;

-- fixture.reminder_create {due_at}: a reminder for the caller, due at due_at, and its job.
create function app.fixture_reminder_create(p_actor uuid, p_expected bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_errors jsonb;
  v_row app.fixture_reminder_sources;
  v_job jsonb;
begin
  v_errors := jsonb_strip_nulls(jsonb_build_object(
      'due_at', app.contract_instant_error(p_payload -> 'due_at')))
    || coalesce((select jsonb_object_agg(k, 'unknown_field') from jsonb_object_keys(p_payload) k
                  where k <> 'due_at'), '{}'::jsonb);
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_member := app.fixture_reminder_actor();
  insert into app.fixture_reminder_sources (member_id, due_at, created_by_account)
  values (v_member, (p_payload ->> 'due_at')::timestamptz, p_actor)
  returning * into v_row;
  v_job := app.notifications_enqueue(jsonb_build_object(
    'source_type', 'fixture_reminder', 'source_id', v_row.source_id,
    'source_revision', v_row.revision, 'recipient_member_id', v_member,
    'reminder_kind', 'fixture_due', 'scheduled_at', app.cmd_utc(v_row.due_at)));
  return jsonb_build_object(
    'aggregate_type', 'fixture_reminder', 'aggregate_id', v_row.source_id,
    'revision', v_row.revision,
    'data', app.fixture_reminder_json(v_row)
            || jsonb_build_object('job_state', v_job ->> 'job_state',
                                  'job_created', (v_job ->> 'created')::boolean));
end;
$$;

-- fixture.reminder_cancel {source_id} at the expected revision: the source and its pending jobs
-- are cancelled in one transaction.
create function app.fixture_reminder_cancel(p_actor uuid, p_expected bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_errors jsonb;
  v_row app.fixture_reminder_sources;
  v_cancel jsonb;
begin
  v_errors := jsonb_strip_nulls(jsonb_build_object(
      'source_id', app.contract_uuid_error(p_payload -> 'source_id')))
    || coalesce((select jsonb_object_agg(k, 'unknown_field') from jsonb_object_keys(p_payload) k
                  where k <> 'source_id'), '{}'::jsonb);
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
  update app.fixture_reminder_sources s
     set source_state = 'cancelled', revision = s.revision + 1
   where s.source_id = v_row.source_id
  returning * into v_row;
  v_cancel := app.notifications_cancel(jsonb_build_object(
    'source_type', 'fixture_reminder', 'source_id', v_row.source_id,
    'reason', 'source_cancelled'));
  return jsonb_build_object(
    'aggregate_type', 'fixture_reminder', 'aggregate_id', v_row.source_id,
    'revision', v_row.revision,
    'data', app.fixture_reminder_json(v_row)
            || jsonb_build_object('cancelled_jobs', (v_cancel ->> 'cancelled')::integer));
end;
$$;

-- `fixture.*` commands. The two reminder commands need a live member session (the handlers add
-- the environment and SYNTHETIC checks). Any other `fixture.*` command keeps the story 1.4
-- SYNTHETIC per-actor grants (app.fixture_command_grants), exactly as before this authorizer.
create function app.fixture_authorize_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  if coalesce(p_request ->> 'command', '') not in ('fixture.reminder_create',
                                                   'fixture.reminder_cancel') then
    perform 1 from app.fixture_command_grants g
     where g.actor_id = (p_request ->> 'actor')::uuid
       and g.command = p_request ->> 'command'
       and g.revoked_at is null
       for share;
    return found;
  end if;
  select e.* into r from app.identity_evaluate_grant(null, null, null) e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  return r.outcome = 'granted';
end;
$$;

select app.cmd_register_authorizer('fixture', 'app.fixture_authorize_command(jsonb)'::regprocedure);

-- Replay scope: the stored reminder still belongs to the caller's current member.
create function app.fixture_reminder_in_scope(p_actor uuid, p_aggregate_type text, p_aggregate_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_aggregate_type = 'fixture_reminder' and exists (
    select 1 from app.fixture_reminder_sources s
     where s.source_id = p_aggregate_id
       and s.member_id = app.identity_current_member_id());
$$;

create function app.fixture_reminder_command(p_envelope jsonb)
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
    end,
    'app.fixture_reminder_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'fixture.reminder_create');
end;
$$;

-- POST /rest/v1/rpc/fixture_reminder_command, Content-Profile: api,
-- body {version, command, request_id, expected_revision, payload}.
create function api.fixture_reminder_command(jsonb)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.fixture_reminder_command($1);
$$;

comment on function api.fixture_reminder_command(jsonb) is
  'SYNTHETIC (story 3.1): a self-only due reminder (fixture.reminder_create {due_at}, '
  'fixture.reminder_cancel {source_id}) through the 1.4 command envelope; local/staging only.';

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

alter table app.notifications_jobs enable row level security;
alter table app.notifications_inbox_items enable row level security;
alter table app.fixture_reminder_sources enable row level security;
revoke all on table app.notifications_jobs, app.notifications_inbox_items,
                    app.fixture_reminder_sources
  from public, anon, authenticated, service_role;

revoke all on function
  app.notifications_enqueue(jsonb),
  app.notifications_cancel(jsonb),
  app.notifications_check_deliver_due(jsonb),
  app.notifications_sys_deliver_due(uuid, uuid, jsonb),
  app.notifications_my_inbox(timestamptz, uuid),
  api.notifications_my_inbox(timestamptz, uuid),
  app.fixture_reminder_check(jsonb),
  app.fixture_reminder_actor(),
  app.fixture_reminder_json(app.fixture_reminder_sources),
  app.fixture_reminder_create(uuid, bigint, jsonb),
  app.fixture_reminder_cancel(uuid, bigint, jsonb),
  app.fixture_authorize_command(jsonb),
  app.fixture_reminder_in_scope(uuid, text, uuid),
  app.fixture_reminder_command(jsonb),
  api.fixture_reminder_command(jsonb)
  from public, anon, authenticated, service_role;

grant execute on function app.notifications_my_inbox(timestamptz, uuid) to authenticated;
grant execute on function api.notifications_my_inbox(timestamptz, uuid) to authenticated;
grant execute on function app.fixture_reminder_command(jsonb) to authenticated;
grant execute on function api.fixture_reminder_command(jsonb) to authenticated;

notify pgrst, 'reload schema';
