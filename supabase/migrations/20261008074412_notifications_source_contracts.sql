-- Story 3.2: source contracts with generic payloads and authorised deep links (AD-5, AD-8,
-- AD-13; epic 3 requirements N1, N2). Builds on 20261008073631_notifications_inbox.sql.
--
--   * Platform registry `app.contract_reminder_contracts`, one row per (source_type,
--     reminder_kind). The source owner registers it in its own migration with
--       app.contract_register_reminder_contract(module, source_type, reminder_kind,
--                                               check regprocedure, text jsonb)
--     - check: `app.<prefix>_...(jsonb) returns jsonb`. It receives the job's contract v1
--       `notification_key` and answers exactly {current, revision, actionable,
--       recipient_eligible}; any other key or type is refused at call time (PCTR1), so an owner
--       cannot pass source content through Notifications.
--     - text: exactly {title, body, link}. Title and body are fixed generic text (no
--       placeholders, no addresses, links or long digit runs); link is a relative client route
--       with at most one whole `{source_id}` segment.
--   * `app.contract_check_reminder(notification_key)` calls the registered check.
--   * Enqueue refuses an unregistered source type, or a kind without a reminder contract.
--   * The worker rechecks through the reminder contract: not current or not actionable ends the
--     job `obsolete`, a recipient the source no longer admits ends it `ineligible`.
--   * The inbox read adds the registered generic `title` and `body`.
--   * `api.notifications_open_item(item_id)`: re-reads the source through the contract. It
--     answers `current` with the authorised `target`, or the generic `superseded` state with no
--     target, or `{"state": "not_found"}` for an id that is not the caller's.
--   * SYNTHETIC adapters on `fixture_reminder`: `fixture.reminder_change {source_id, change:
--     revise|revoke|expire}` next to the existing cancel, and an optional `reminder_kind` on
--     `fixture.reminder_create`.
--
-- Wire contract v1 is unchanged: registration is server-side, the check's input is the v1
-- `notification_key`, and the open answer is a Notifications read projection.
-- No destructive statements and no row deletions. No anon grant. ASCII only.

-- ---------------------------------------------------------------------------------------------
-- Registry (owner: platform)
-- ---------------------------------------------------------------------------------------------

create table app.contract_reminder_contracts (
  source_type text not null,
  reminder_kind text not null,
  module text not null references app.contract_modules (module),
  check_hook text not null,
  title text not null,
  body text not null,
  link text not null,
  registered_at timestamptz not null default now(),
  primary key (source_type, reminder_kind),
  foreign key (source_type, reminder_kind)
    references app.contract_reminder_kinds (source_type, reminder_kind)
);

comment on table app.contract_reminder_contracts is
  'Story 3.2: per reminder kind, the source owner''s recipient-aware check hook, fixed generic '
  'notification text and deep-link route template. Registered only through '
  'app.contract_register_reminder_contract in the owner''s migration.';

-- Field errors of the text object of a reminder contract (empty object = acceptable).
create function app.contract_reminder_text_errors(p_text jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_errors jsonb := '{}'::jsonb;
  v_key text;
  v_value text;
  v_max integer;
begin
  if jsonb_typeof(p_text) is distinct from 'object' then
    return '{"text": "must_be_object"}'::jsonb;
  end if;
  v_errors := app.contract_unknown_keys(p_text, array['title', 'body', 'link']);
  foreach v_key in array array['title', 'body'] loop
    if jsonb_typeof(p_text -> v_key) is distinct from 'string' then
      v_errors := v_errors || jsonb_build_object(v_key, 'required');
      continue;
    end if;
    v_value := p_text ->> v_key;
    v_max := (case v_key when 'title' then 60 else 160 end);
    if v_value <> btrim(v_value) or length(v_value) = 0 or length(v_value) > v_max then
      v_errors := v_errors || jsonb_build_object(v_key, 'out_of_range');
    elsif v_value !~ '^[ -~]+$' or v_value ~ '[{}<>@]' or position(chr(92) in v_value) > 0
          or v_value ~* '(https?:|www[.])' or v_value ~* '[a-z0-9][.][a-z]{2,}'
          or v_value ~ '([0-9][^A-Za-z0-9]{0,3}){7,}' then
      -- Generic text only: printable ASCII, no placeholders, markup, addresses, links, domain
      -- shapes or phone-like numbers (digits split by any short run of other characters).
      v_errors := v_errors || jsonb_build_object(v_key, 'not_generic');
    end if;
  end loop;
  if jsonb_typeof(p_text -> 'link') is distinct from 'string' then
    v_errors := v_errors || '{"link": "required"}'::jsonb;
  elsif length(p_text ->> 'link') > 200
        or (p_text ->> 'link') !~ '^(/[a-z][a-z0-9_-]{0,62})+(/\{source_id\})?(/[a-z][a-z0-9_-]{0,62})*$' then
    v_errors := v_errors || '{"link": "invalid"}'::jsonb;
  end if;
  return jsonb_strip_nulls(v_errors);
end;
$$;

-- Registers (or replaces) the reminder contract of one registered reminder kind. Only the
-- module that owns the source type may register; refusals are PCTR1 like every registration.
create function app.contract_register_reminder_contract(
  p_module text,
  p_source_type text,
  p_reminder_kind text,
  p_check regprocedure,
  p_text jsonb
) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_hook text;
  v_errors jsonb;
begin
  perform app.contract_require_source_owner(p_module, p_source_type);
  if not exists (select 1 from app.contract_reminder_kinds r
                  where r.source_type = p_source_type and r.reminder_kind = p_reminder_kind) then
    perform app.contract_registration_fail(
      format('reminder kind %s is not registered on source type %s', p_reminder_kind, p_source_type));
  end if;
  v_hook := app.contract_validate_handler(p_module, p_check, 'jsonb'::regtype);
  v_errors := app.contract_reminder_text_errors(p_text);
  if v_errors <> '{}'::jsonb then
    perform app.contract_registration_fail('reminder contract text refused: ' || v_errors::text);
  end if;
  insert into app.contract_reminder_contracts (source_type, reminder_kind, module, check_hook,
                                               title, body, link)
  values (p_source_type, p_reminder_kind, p_module, v_hook,
          p_text ->> 'title', p_text ->> 'body', p_text ->> 'link')
  on conflict (source_type, reminder_kind) do update
     set check_hook = excluded.check_hook, title = excluded.title, body = excluded.body,
         link = excluded.link, registered_at = now();
end;
$$;

-- Calls the registered reminder check with a v1 notification_key and returns its strict answer
-- {current, revision, actionable, recipient_eligible}. A missing contract is validation_failed
-- {"reminder_kind": "unregistered"}; a missing or misbehaving hook raises PCTR1.
create function app.contract_check_reminder(p_key jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_hook text;
  v_proc regprocedure;
  v_result jsonb;
begin
  perform app.contract_require('notification_key', p_key);
  select c.check_hook into v_hook
    from app.contract_reminder_contracts c
   where c.source_type = p_key ->> 'source_type' and c.reminder_kind = p_key ->> 'reminder_kind';
  if not found then
    perform app.cmd_fail('validation_failed', '{"reminder_kind": "unregistered"}');
  end if;
  v_proc := pg_catalog.to_regprocedure(v_hook);
  if v_proc is null then
    raise log 'registered reminder check % is missing', v_hook;
    raise exception using errcode = 'PCTR1', message = 'registered reminder check is missing';
  end if;
  execute format('select %s($1)', v_proc::regproc) into v_result using p_key;
  if jsonb_typeof(v_result) is distinct from 'object'
     or app.contract_unknown_keys(v_result, array['current', 'revision', 'actionable',
                                                  'recipient_eligible']) <> '{}'::jsonb
     or jsonb_typeof(v_result -> 'current') is distinct from 'boolean'
     or jsonb_typeof(v_result -> 'actionable') is distinct from 'boolean'
     or jsonb_typeof(v_result -> 'recipient_eligible') is distinct from 'boolean'
     or not (v_result ? 'revision')
     or app.contract_revision_error(v_result -> 'revision', true) is not null
     or ((v_result -> 'current') = 'true'::jsonb
         and (v_result ->> 'revision')::numeric is distinct from (p_key ->> 'source_revision')::numeric) then
    raise log 'reminder check % returned a malformed result', v_hook;
    raise exception using errcode = 'PCTR1', message = 'reminder check returned a malformed result';
  end if;
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Notifications: enqueue, worker and inbox read use the reminder contract
-- ---------------------------------------------------------------------------------------------

-- As in 3.1, plus: the key is strict (a private field is `unknown_field`), the source type must
-- be registered and the kind must have a reminder contract before anything is written.
create or replace function app.notifications_enqueue(p_key jsonb)
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

-- The job's contract v1 notification_key.
create function app.notifications_job_key(p_job app.notifications_jobs)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'source_type', p_job.source_type, 'source_id', p_job.source_id,
    'source_revision', p_job.source_revision, 'recipient_member_id', p_job.recipient_member_id,
    'reminder_kind', p_job.reminder_kind, 'scheduled_at', app.cmd_utc(p_job.scheduled_at));
$$;

-- As in 3.1, but the recheck goes through the registered reminder contract: not current or no
-- longer actionable -> obsolete; the source no longer admits the recipient -> ineligible.
create or replace function app.notifications_sys_deliver_due(p_principal uuid, p_request uuid, p_payload jsonb)
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
      -- A kind without a reminder contract can never be rechecked: end it, never retry it.
      if not exists (select 1 from app.contract_reminder_contracts c
                      where c.source_type = v_job.source_type
                        and c.reminder_kind = v_job.reminder_kind) then
        v_state := '{"current": false, "actionable": false}'::jsonb;
      else
        v_state := app.contract_check_reminder(app.notifications_job_key(v_job));
      end if;
      if not ((v_state ->> 'current')::boolean and (v_state ->> 'actionable')::boolean) then
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
      if not (v_state ->> 'recipient_eligible')::boolean
         or v_member_state is distinct from 'approved' then
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

-- As in 3.1, plus the registered generic title and body of each item's kind.
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
           'delivered_at', app.cmd_utc(x.delivered_at))
           order by x.delivered_at desc, x.item_id desc), '[]'::jsonb)
    into v_rows
    from (select i.item_id, i.reminder_kind, i.due_at, i.delivered_at,
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

-- ---------------------------------------------------------------------------------------------
-- Open one item: re-read the source through its reminder contract
-- ---------------------------------------------------------------------------------------------

-- The caller's own item, rechecked now. `current` (source current at the item's revision, still
-- actionable, recipient still admitted) carries the resolved deep-link `target`; anything else
-- is the generic `superseded` state with no target and no reason. Another member's or an
-- unknown id answers {"state": "not_found"}. Behind the live-access predicate (401/403).
create function app.notifications_open_item(p_item_id uuid)
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
    -- The owner's check runs in a subtransaction: whatever it raises stays in the server log
    -- (SQLSTATE only) and the member gets one fixed, content-free 503.
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
  perform app.identity_record_activity(v_link);
  return jsonb_build_object(
    'item_id', v_item.item_id,
    'reminder_kind', v_item.reminder_kind,
    'title', coalesce(v_contract.title, 'Reminder'),
    'body', coalesce(v_contract.body, 'Something needs your attention.'),
    'due_at', app.cmd_utc(v_item.due_at),
    'delivered_at', app.cmd_utc(v_item.delivered_at),
    'state', case when v_current then 'current' else 'superseded' end,
    'target', case when v_current
                   then replace(v_contract.link, '{source_id}', v_job.source_id::text) end);
end;
$$;

create function api.notifications_open_item(item_id uuid)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.notifications_open_item(item_id);
$$;

comment on function api.notifications_open_item(uuid) is
  'Story 3.2: open one of the signed-in member''s inbox items. Re-reads the source through its '
  'registered reminder contract: {state: current, target} or the generic superseded state. '
  'POST /rest/v1/rpc/notifications_open_item {item_id} with Content-Profile: api.';

-- ---------------------------------------------------------------------------------------------
-- SYNTHETIC adapters on fixture_reminder (owner: fixture)
-- ---------------------------------------------------------------------------------------------

alter table app.fixture_reminder_sources
  add column reminder_kind text not null default 'fixture_due'
    check (reminder_kind ~ '^[a-z][a-z0-9_]{0,62}$'),
  add column expires_at timestamptz,
  add column recipient_revoked boolean not null default false;

-- Reminder check: current while active at exactly the key's revision; actionable while active
-- and not past expires_at; the recipient is admitted while it is the source's member and the
-- SYNTHETIC scope has not been revoked.
create function app.fixture_reminder_open_check(p_key jsonb)
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
  return jsonb_build_object(
    'current', v_row.source_state = 'active'
               and v_row.revision = (p_key ->> 'source_revision')::numeric::bigint,
    'revision', v_row.revision,
    'actionable', v_row.source_state = 'active'
                  and (v_row.expires_at is null or v_row.expires_at > now()),
    'recipient_eligible', v_row.member_id = (p_key ->> 'recipient_member_id')::uuid
                          and not v_row.recipient_revoked);
end;
$$;

select app.contract_register_reminder_contract(
  'fixture', 'fixture_reminder', 'fixture_due',
  'app.fixture_reminder_open_check(jsonb)'::regprocedure,
  '{"title": "SYNTHETIC test reminder",
    "body": "A test reminder is waiting for you.",
    "link": "/fixture/reminders/{source_id}"}'::jsonb);

create or replace function app.fixture_reminder_json(p_row app.fixture_reminder_sources)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('source_id', p_row.source_id, 'revision', p_row.revision,
                            'state', p_row.source_state, 'due_at', app.cmd_utc(p_row.due_at),
                            'reminder_kind', p_row.reminder_kind,
                            'expires_at', case when p_row.expires_at is not null
                                               then app.cmd_utc(p_row.expires_at) end,
                            'recipient_revoked', p_row.recipient_revoked);
$$;

-- fixture.reminder_create {due_at, reminder_kind?}: as in 3.1; an optional kind (default
-- fixture_due) lets the API show that an unregistered kind is refused.
create or replace function app.fixture_reminder_create(p_actor uuid, p_expected bigint, p_payload jsonb)
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
      'due_at', app.contract_instant_error(p_payload -> 'due_at'),
      'reminder_kind', case when coalesce(jsonb_typeof(p_payload -> 'reminder_kind'), 'null') = 'null'
                            then null else app.contract_token_error(p_payload -> 'reminder_kind') end))
    || coalesce((select jsonb_object_agg(k, 'unknown_field') from jsonb_object_keys(p_payload) k
                  where k not in ('due_at', 'reminder_kind')), '{}'::jsonb);
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_member := app.fixture_reminder_actor();
  insert into app.fixture_reminder_sources (member_id, due_at, created_by_account, reminder_kind)
  values (v_member, (p_payload ->> 'due_at')::timestamptz, p_actor,
          coalesce(p_payload ->> 'reminder_kind', 'fixture_due'))
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

-- fixture.reminder_change {source_id, change} at the expected revision, on an active source:
--   revise  revision + 1, older pending jobs cancelled (source_revised) and a job enqueued at
--           the new revision, so earlier items open as superseded (stale revision);
--   revoke  the recipient's SYNTHETIC scope is revoked (revision kept), pending jobs cancelled;
--   expire  the source expires now (revision kept), pending jobs cancelled.
create function app.fixture_reminder_change(p_actor uuid, p_expected bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_errors jsonb;
  v_row app.fixture_reminder_sources;
  v_change text;
  v_cancel jsonb;
  v_job jsonb;
begin
  v_errors := jsonb_strip_nulls(jsonb_build_object(
      'source_id', app.contract_uuid_error(p_payload -> 'source_id'),
      'change', case when jsonb_typeof(p_payload -> 'change') is distinct from 'string' then 'required'
                     when (p_payload ->> 'change') in ('revise', 'revoke', 'expire') then null
                     else 'invalid' end))
    || coalesce((select jsonb_object_agg(k, 'unknown_field') from jsonb_object_keys(p_payload) k
                  where k not in ('source_id', 'change')), '{}'::jsonb);
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_change := p_payload ->> 'change';
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
  if v_change = 'revise' then
    update app.fixture_reminder_sources s set revision = s.revision + 1
     where s.source_id = v_row.source_id returning * into v_row;
    v_cancel := app.notifications_cancel(jsonb_build_object(
      'source_type', 'fixture_reminder', 'source_id', v_row.source_id, 'reason', 'source_revised'));
    v_job := app.notifications_enqueue(jsonb_build_object(
      'source_type', 'fixture_reminder', 'source_id', v_row.source_id,
      'source_revision', v_row.revision, 'recipient_member_id', v_row.member_id,
      'reminder_kind', v_row.reminder_kind, 'scheduled_at', app.cmd_utc(v_row.due_at)));
  elsif v_change = 'revoke' then
    update app.fixture_reminder_sources s set recipient_revoked = true
     where s.source_id = v_row.source_id returning * into v_row;
    v_cancel := app.notifications_cancel(jsonb_build_object(
      'source_type', 'fixture_reminder', 'source_id', v_row.source_id, 'reason', 'scope_revoked'));
  else
    update app.fixture_reminder_sources s set expires_at = now()
     where s.source_id = v_row.source_id returning * into v_row;
    v_cancel := app.notifications_cancel(jsonb_build_object(
      'source_type', 'fixture_reminder', 'source_id', v_row.source_id, 'reason', 'source_expired'));
  end if;
  return jsonb_build_object(
    'aggregate_type', 'fixture_reminder', 'aggregate_id', v_row.source_id,
    'revision', v_row.revision,
    'data', app.fixture_reminder_json(v_row)
            || jsonb_build_object('cancelled_jobs', (v_cancel ->> 'cancelled')::integer)
            || case when v_job is null then '{}'::jsonb
                    else jsonb_build_object('job_state', v_job ->> 'job_state',
                                            'job_created', (v_job ->> 'created')::boolean) end);
end;
$$;

-- As in 3.1, with fixture.reminder_change among the live-session reminder commands.
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
                                                   'fixture.reminder_change') then
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
    end,
    'app.fixture_reminder_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'fixture.reminder_create');
end;
$$;

comment on function api.fixture_reminder_command(jsonb) is
  'SYNTHETIC (stories 3.1, 3.2): a self-only reminder source (fixture.reminder_create '
  '{due_at, reminder_kind?}, fixture.reminder_cancel {source_id}, fixture.reminder_change '
  '{source_id, change: revise|revoke|expire}) through the 1.4 command envelope; local/staging only.';

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

alter table app.contract_reminder_contracts enable row level security;
revoke all on table app.contract_reminder_contracts from public, anon, authenticated, service_role;

revoke all on function
  app.contract_reminder_text_errors(jsonb),
  app.contract_register_reminder_contract(text, text, text, regprocedure, jsonb),
  app.contract_check_reminder(jsonb),
  app.notifications_job_key(app.notifications_jobs),
  app.notifications_open_item(uuid),
  api.notifications_open_item(uuid),
  app.fixture_reminder_open_check(jsonb),
  app.fixture_reminder_change(uuid, bigint, jsonb)
  from public, anon, authenticated, service_role;

grant execute on function app.notifications_open_item(uuid) to authenticated;
grant execute on function api.notifications_open_item(uuid) to authenticated;

notify pgrst, 'reload schema';
