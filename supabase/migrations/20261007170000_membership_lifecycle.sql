-- Hold, deactivate and restore membership with handover obligations (story 2.10; I10, AD-14,
-- AC-22). Builds on the live-access predicate, the 2.8 holds and session revocation, the 2.3
-- grant path and last-usable-Admin rule, the 2.9 recovery grants and operations, the 1.4
-- command envelope with the registered `identity` authorizer and the 1.5 lifecycle dispatch.
--
--   * Login hold (a 2.8 hold, machinery reused): identity.place_hold gains the reason code
--     `login_disabled` -> hold kind `login`. Every Auth session of the account is revoked and the
--     account stays held (generic help screen) until identity.release_hold. Membership, account
--     link, grants, cell membership and every owner's facts are untouched. The 2.8 reason_code
--     CHECK cannot be widened without a DROP, so a login hold stores `reason = 'login_disabled'`
--     with reason_code null; reads report it as reason code `login_disabled`. A login hold on the
--     last usable Admin is refused (`forbidden {"member_id": "last_admin"}`).
--   * Church deactivation (Admin, expected = member revision):
--       identity.deactivate_membership {member_id, reason_code}
--         reason_code: member_request, moved_away, church_decision
--     Refused for the last usable Admin (checked before the self check), for the Admin's own
--     record, for a member who is not approved, and when a registered owner handover hook reports
--     that the member is the last responsible person for something (`conflict {"member_id":
--     "handover_required"}`; nothing is written). Otherwise, in ONE transaction: every active
--     grant ends (2.3 path, scope_revoked), the live link is suspended (trust epoch moves), every
--     Auth session is revoked, issued recovery grants end and pending recovery operations become
--     obsolete (a dispatched or uncertain one keeps its hold: 2.9), the member becomes
--     `deactivated`, the reported obligations are recorded `pending`, and the contract v1 events
--     membership_deactivated (and sessions_revoked) are dispatched to owner lifecycle hooks.
--   * Reviewed restoration (Admin, expected = member revision):
--       identity.restore_membership {member_id, identity_check}
--     The member is approved again; a suspended link returns to `active` (or `review_required`
--     while a binding review is pending), which moves the trust epoch, so only a fresh sign-in
--     works. Grants are NOT restored, holds stay, obligations stay pending until their owner
--     resolves them. membership_restored is dispatched.
--   * Owner handover hooks: app.identity_register_handover_hook(module, handler), handler
--     (jsonb lifecycle event) -> jsonb {"obligations": [{"kind", "subject_id",
--     "last_responsible"}]}. Called in lock order before anything is written; a missing handler
--     or a malformed answer raises (fail closed). Owners resolve an obligation with
--     app.identity_resolve_handover_obligation(module, obligation_id, resolution).
--     Only the SYNTHETIC fixture hook app.fixture_report_handover (over app.fixture_duties)
--     exists; tests and the local E2E register it and remove it again.
--   * Reads: api.identity_admin_membership_lifecycle() (Admin: deactivated members, open login
--     holds, pending handovers) and api.identity_my_membership_status() (a trusted own session:
--     whether the linked membership is deactivated, and the church contact).
--
-- No destructive statements and no row deletions; Auth sessions are revoked through
-- app.identity_revoke_auth_sessions (20261007160100). No client table privileges.

-- ---------------------------------------------------------------------------------------------
-- Contract v1 lifecycle events (SQL list, shared fixture, Dart and TypeScript mappings)
-- ---------------------------------------------------------------------------------------------

insert into app.contract_lifecycle_events (event, description) values
  ('membership_deactivated',
   'Church membership was deactivated: access denied, sessions revoked, handovers recorded'),
  ('membership_restored',
   'Church membership was restored after review; grants are not restored');

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

-- Content-free: ids, codes, counts and revisions only.
create table app.identity_membership_lifecycle (
  event_id bigint generated always as identity primary key,
  occurred_at timestamptz not null default clock_timestamp(),
  environment text not null default app.platform_current_environment(),
  action text not null check (action in ('membership_deactivated', 'membership_restored')),
  actor_member_id uuid not null,
  actor_account_id uuid not null,
  request_id uuid,
  member_id uuid not null references app.identity_members (member_id),
  link_id uuid,
  reason_code text check (reason_code in ('member_request', 'moved_away', 'church_decision')),
  identity_check text check (identity_check in ('established_relationship', 'in_person')),
  revision_after bigint not null,
  sessions_revoked integer,
  grants_ended integer not null default 0,
  recovery_grants_ended integer not null default 0,
  recovery_operations_obsoleted integer not null default 0,
  obligations_recorded integer not null default 0,
  check ((action = 'membership_deactivated') = (reason_code is not null)),
  check ((action = 'membership_restored') = (identity_check is not null))
);

comment on table app.identity_membership_lifecycle is
  'owner: identity. Attributed church deactivations and reviewed restorations (AD-14, AD-19): '
  'ids, codes, counts and revisions only.';

create index identity_membership_lifecycle_member
  on app.identity_membership_lifecycle (member_id, event_id);

-- Owner handover hooks: one per owning module.
create table app.identity_handover_hooks (
  module text primary key references app.contract_modules (module),
  handler text not null,
  registered_at timestamptz not null default now()
);

comment on table app.identity_handover_hooks is
  'owner: identity. Registered owner handover hooks (AD-14): (jsonb event) -> jsonb obligations.';

-- A pending handover an owner reported at deactivation; the owner resolves it.
create table app.identity_handover_obligations (
  obligation_id uuid primary key default gen_random_uuid(),
  member_id uuid not null references app.identity_members (member_id),
  lifecycle_event_id bigint not null references app.identity_membership_lifecycle (event_id),
  owner_module text not null references app.contract_modules (module),
  obligation_kind text not null check (obligation_kind ~ '^[a-z][a-z0-9_]{0,62}$'),
  subject_id uuid not null,
  obligation_state text not null default 'pending'
    check (obligation_state in ('pending', 'resolved')),
  recorded_at timestamptz not null default clock_timestamp(),
  resolved_at timestamptz,
  resolution text check (resolution in ('handed_over', 'no_longer_needed')),
  check ((obligation_state = 'resolved') = (resolved_at is not null)),
  check ((obligation_state = 'resolved') = (resolution is not null))
);

comment on table app.identity_handover_obligations is
  'owner: identity. Pending handover obligations recorded through owner hooks (AD-14): owner, '
  'kind and an opaque subject id only.';

create unique index identity_handover_obligations_one_pending
  on app.identity_handover_obligations (member_id, owner_module, obligation_kind, subject_id)
  where obligation_state = 'pending';
create index identity_handover_obligations_state
  on app.identity_handover_obligations (obligation_state, recorded_at);

-- SYNTHETIC duties of the fixture owner (stand-in for the Duties epic; no real duty exists).
create table app.fixture_duties (
  duty_id uuid primary key default gen_random_uuid(),
  member_id uuid not null,
  duty_kind text not null default 'fixture_duty' check (duty_kind ~ '^[a-z][a-z0-9_]{0,62}$'),
  sole_responsible boolean not null default false,
  created_at timestamptz not null default clock_timestamp()
);

comment on table app.fixture_duties is
  'owner: fixture. SYNTHETIC duty facts proving handover hooks (registered only by tests/E2E).';

alter table app.identity_membership_lifecycle enable row level security;
alter table app.identity_handover_hooks enable row level security;
alter table app.identity_handover_obligations enable row level security;
alter table app.fixture_duties enable row level security;
revoke all on table app.identity_membership_lifecycle, app.identity_handover_hooks,
                    app.identity_handover_obligations, app.fixture_duties
  from public, anon, authenticated, service_role;
revoke all on sequence app.identity_membership_lifecycle_event_id_seq
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Owner handover hooks
-- ---------------------------------------------------------------------------------------------

-- Migration-time registration by an owner (SQLSTATE PCTR1 on a programming error).
create function app.identity_register_handover_hook(p_module text, p_handler regprocedure)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_handler text;
begin
  if p_module = 'identity' then
    perform app.contract_registration_fail('identity collects handovers; it does not report them');
  end if;
  v_handler := app.contract_validate_handler(p_module, p_handler, 'jsonb'::regtype);
  insert into app.identity_handover_hooks (module, handler) values (p_module, v_handler);
end;
$$;

-- Calls every registered handover hook in AD-2 lock order with the lifecycle event and returns
-- the reported obligations as [{module, kind, subject_id, last_responsible}]. Fail closed: a
-- missing handler or an answer of another shape raises, so the lifecycle change rolls back.
create function app.identity_collect_handover(p_event jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_hook record;
  v_proc regprocedure;
  v_answer jsonb;
  v_item jsonb;
  v_out jsonb := '[]'::jsonb;
begin
  perform app.contract_require('lifecycle_event', p_event);
  for v_hook in
    select h.module, h.handler
      from app.identity_handover_hooks h
      join app.contract_modules m on m.module = h.module
     order by m.lock_rank, h.module
  loop
    v_proc := pg_catalog.to_regprocedure(v_hook.handler);
    if v_proc is null then
      raise exception using errcode = 'PCTR1',
        message = format('registered handover hook %s is missing', v_hook.handler);
    end if;
    execute format('select %s($1)', v_proc::regproc) into v_answer using p_event;
    if jsonb_typeof(v_answer) is distinct from 'object'
       or jsonb_typeof(v_answer -> 'obligations') is distinct from 'array'
       or app.contract_unknown_keys(v_answer, array['obligations']) <> '{}'::jsonb then
      raise exception using errcode = 'PCTR1',
        message = format('handover hook %s answered an unexpected shape', v_hook.handler);
    end if;
    for v_item in select x.value from jsonb_array_elements(v_answer -> 'obligations') x loop
      if jsonb_typeof(v_item) is distinct from 'object'
         or app.contract_unknown_keys(v_item, array['kind', 'subject_id', 'last_responsible'])
              <> '{}'::jsonb
         or jsonb_typeof(v_item -> 'kind') is distinct from 'string'
         or (v_item ->> 'kind') !~ '^[a-z][a-z0-9_]{0,62}$'
         or app.contract_uuid_error(v_item -> 'subject_id') is not null
         or jsonb_typeof(v_item -> 'last_responsible') is distinct from 'boolean' then
        raise exception using errcode = 'PCTR1',
          message = format('handover hook %s reported a malformed obligation', v_hook.handler);
      end if;
      v_out := v_out || jsonb_build_array(jsonb_build_object('module', v_hook.module) || v_item);
    end loop;
  end loop;
  return v_out;
end;
$$;

-- An owner resolves its own pending obligation once the work was handed over (or is no longer
-- needed). Returns false when there is no such pending obligation of that owner.
create function app.identity_resolve_handover_obligation(
  p_module text,
  p_obligation_id uuid,
  p_resolution text
) returns boolean
language plpgsql
set search_path = ''
as $$
begin
  if p_resolution is null or p_resolution not in ('handed_over', 'no_longer_needed') then
    raise exception using errcode = '22023', message = 'unknown handover resolution';
  end if;
  update app.identity_handover_obligations o
     set obligation_state = 'resolved', resolved_at = clock_timestamp(), resolution = p_resolution
   where o.obligation_id = p_obligation_id and o.owner_module = p_module
     and o.obligation_state = 'pending';
  return found;
end;
$$;

-- SYNTHETIC handover hook of the fixture owner: one obligation per fixture duty of the member;
-- `sole_responsible` marks the last responsible person. Registered only by tests and the E2E.
create function app.fixture_report_handover(p_event jsonb)
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
   where d.member_id = (p_event ->> 'member_id')::uuid;
$$;

comment on function app.fixture_report_handover(jsonb) is
  'SYNTHETIC handover hook over app.fixture_duties. Register only in tests and the local E2E.';

-- ---------------------------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------------------------

-- The target holds an active Admin grant and no OTHER usable Admin would remain.
create function app.identity_is_last_admin(p_member_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from app.identity_grants g
                  where g.member_id = p_member_id and g.role = 'admin' and g.revoked_at is null)
     and app.identity_usable_admin_count(p_member_id) = 0;
$$;

-- The reason code a hold is shown with (a login hold keeps it in `reason`, see the header).
create function app.identity_hold_reason_code(p_hold app.identity_holds)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(p_hold.reason_code,
                  case when p_hold.hold_kind = 'login' then 'login_disabled' end);
$$;

create function app.identity_lifecycle_member_json(p_member_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'member_id', m.member_id,
    'display_name', m.display_name,
    'membership_state', m.membership_state,
    'revision', m.revision,
    'account', app.identity_member_account_label(m.member_id),
    'is_synthetic', m.is_synthetic,
    'pending_obligations', (select count(*)::int from app.identity_handover_obligations o
                             where o.member_id = m.member_id and o.obligation_state = 'pending'))
    from app.identity_members m
   where m.member_id = p_member_id;
$$;

create function app.identity_lifecycle_outcome(p_member_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'identity_member',
    'aggregate_id', p_member_id,
    'revision', (select m.revision from app.identity_members m where m.member_id = p_member_id),
    'data', app.identity_lifecycle_member_json(p_member_id));
$$;

-- Validates {member_id, <p_field>} and locks the member (not_found otherwise). The revision and
-- the self check are the caller's, so the last-Admin answer can come first.
create function app.identity_lock_lifecycle_member(
  p_payload jsonb,
  p_field text
) returns app.identity_members
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_err text;
  v_member app.identity_members;
begin
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, array['member_id', p_field]);
  v_err := app.contract_uuid_error(p_payload -> 'member_id');
  if v_err is not null then
    v_errors := v_errors || jsonb_build_object('member_id', v_err);
  end if;
  if p_field = 'identity_check' then
    v_err := app.identity_check_value(p_payload -> 'identity_check', true);
    if v_err is not null then
      v_errors := v_errors || jsonb_build_object('identity_check', v_err);
    end if;
  else
    if coalesce(jsonb_typeof(p_payload -> p_field), 'null') = 'null' then
      v_errors := v_errors || jsonb_build_object(p_field, 'required');
    elsif jsonb_typeof(p_payload -> p_field) <> 'string'
          or p_payload ->> p_field not in ('member_request', 'moved_away', 'church_decision') then
      v_errors := v_errors || jsonb_build_object(p_field, 'invalid');
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  select m.* into v_member from app.identity_members m
   where m.member_id = (p_payload ->> 'member_id')::uuid
     for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  return v_member;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Login hold: the 2.8 hold functions replaced in place (same signatures and privileges)
-- ---------------------------------------------------------------------------------------------

-- 2.8 body, with `login_disabled` accepted as a reason code.
create or replace function app.identity_lock_reviewed_member(
  p_payload jsonb,
  p_allowed text[],
  p_identity_check_required boolean,
  p_expected_revision bigint,
  p_actor_member uuid
) returns app.identity_members
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_err text;
  v_member app.identity_members;
begin
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, p_allowed);
  v_err := app.contract_uuid_error(p_payload -> 'member_id');
  if v_err is not null then
    v_errors := v_errors || jsonb_build_object('member_id', v_err);
  end if;
  if 'identity_check' = any (p_allowed) then
    v_err := app.identity_check_value(p_payload -> 'identity_check', p_identity_check_required);
    if v_err is not null then
      v_errors := v_errors || jsonb_build_object('identity_check', v_err);
    end if;
  end if;
  if 'hold_id' = any (p_allowed) then
    v_err := app.contract_uuid_error(p_payload -> 'hold_id');
    if v_err is not null then
      v_errors := v_errors || jsonb_build_object('hold_id', v_err);
    end if;
  end if;
  if 'reason_code' = any (p_allowed) then
    if coalesce(jsonb_typeof(p_payload -> 'reason_code'), 'null') = 'null' then
      v_errors := v_errors || '{"reason_code": "required"}';
    elsif jsonb_typeof(p_payload -> 'reason_code') <> 'string'
          or p_payload ->> 'reason_code' not in ('ownership_dispute', 'security_concern',
                                                 'lost_device', 'login_disabled') then
      v_errors := v_errors || '{"reason_code": "invalid"}';
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  if (p_payload ->> 'member_id')::uuid = p_actor_member then
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
  return v_member;
end;
$$;

-- identity.place_hold {member_id, reason_code}: the 2.8 body plus the login hold
-- (`login_disabled` -> kind `login`, every session revoked, not on the last usable Admin).
create or replace function app.identity_place_hold(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_member app.identity_members;
  v_link app.identity_account_links;
  v_hold app.identity_holds;
  v_reason text;
  v_login boolean;
  v_sessions integer;
  v_revision bigint;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.place_hold');
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_member := app.identity_lock_reviewed_member(p_payload, array['member_id', 'reason_code'],
    false, p_expected_revision, v_actor.member_id);
  v_reason := p_payload ->> 'reason_code';
  v_login := v_reason = 'login_disabled';
  if v_member.membership_state <> 'approved' then
    perform app.cmd_fail('conflict', '{"member_id": "not_approved"}', v_member.revision);
  end if;
  if exists (select 1 from app.identity_holds h
              where h.member_id = v_member.member_id and h.released_at is null
                and app.identity_hold_reason_code(h) = v_reason) then
    perform app.cmd_fail('conflict', '{"reason_code": "already_held"}', v_member.revision);
  end if;
  -- An administrative login hold never locks the church out (a security hold still may: the
  -- operator bootstrap is the way back, 2.3).
  if v_login and app.identity_is_last_admin(v_member.member_id) then
    perform app.cmd_fail('forbidden', '{"member_id": "last_admin"}');
  end if;
  select l.* into v_link from app.identity_account_links l
   where l.member_id = v_member.member_id and l.link_state <> 'ended'
     for update;
  -- The 2.2 hold trigger moves the trust epoch of the live link.
  insert into app.identity_holds (member_id, hold_kind, reason, placed_by, reason_code,
                                  placed_by_member, placed_by_account,
                                  password_reset_required_since)
  values (v_member.member_id,
          case when v_reason = 'ownership_dispute' then 'access_review'
               when v_login then 'login'
               else 'security' end,
          v_reason, 'admin:' || v_actor.member_id::text,
          case when v_login then null else v_reason end,
          v_actor.member_id, v_actor.account_id,
          -- Whoever has the device may know the password: the member resets it before release.
          case when v_reason = 'lost_device' then clock_timestamp() end)
  returning * into v_hold;
  if v_reason in ('lost_device', 'login_disabled') and v_link.link_id is not null then
    -- Lost device or login hold: every Auth session of the account ends now.
    v_sessions := app.identity_revoke_auth_sessions(v_link.auth_user_id);
    update app.identity_holds h set sessions_revoked = v_sessions where h.hold_id = v_hold.hold_id
    returning * into v_hold;
  end if;
  v_revision := app.identity_bump_member(v_member.member_id);
  perform app.identity_review_audit_add('hold_placed', v_actor.member_id, v_actor.account_id,
    v_request, v_member.member_id, v_link.link_id, null, v_hold, v_reason, null, null,
    v_revision, v_sessions);
  -- Registered owner hooks (for example device registrations) run in this transaction.
  perform app.identity_dispatch_lifecycle('access_hold_applied', v_member.member_id, v_revision);
  if v_sessions is not null then
    perform app.identity_dispatch_lifecycle('sessions_revoked', v_member.member_id, v_revision);
  end if;
  return app.identity_member_holds_outcome(v_member.member_id);
end;
$$;

-- 2.8 view of a member's open holds, with the login hold's reason code.
create or replace function app.identity_member_holds_json(p_member_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'member_id', m.member_id,
    'revision', m.revision,
    'account', app.identity_member_account_label(m.member_id),
    'holds', coalesce((
      select jsonb_agg(jsonb_build_object('hold_id', h.hold_id, 'hold_kind', h.hold_kind,
                                          'reason_code', app.identity_hold_reason_code(h),
                                          'placed_at', h.placed_at)
                       order by h.placed_at, h.hold_id)
        from app.identity_holds h
       where h.member_id = m.member_id and h.released_at is null), '[]'::jsonb))
    from app.identity_members m
   where m.member_id = p_member_id;
$$;

-- ---------------------------------------------------------------------------------------------
-- Church deactivation and reviewed restoration
-- ---------------------------------------------------------------------------------------------

-- identity.deactivate_membership {member_id, reason_code}; expected = member revision.
create function app.identity_deactivate_membership(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_member app.identity_members;
  v_link app.identity_account_links;
  v_grant app.identity_grants;
  v_op app.identity_recovery_operations;
  v_account uuid;
  v_event jsonb;
  v_obligations jsonb;
  v_sessions integer;
  v_grants integer := 0;
  v_recovery_grants integer := 0;
  v_operations integer := 0;
  v_recorded integer := 0;
  v_revision bigint;
  v_lifecycle bigint;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.deactivate_membership');
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_member := app.identity_lock_lifecycle_member(p_payload, 'reason_code');
  -- The church is never left without a usable Admin (first, so a sole Admin learns why).
  if app.identity_is_last_admin(v_member.member_id) then
    perform app.cmd_fail('forbidden', '{"member_id": "last_admin"}');
  end if;
  if v_member.member_id = v_actor.member_id then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  if v_member.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_member.revision);
  end if;
  if v_member.membership_state <> 'approved' then
    perform app.cmd_fail('conflict', '{"member_id": "not_approved"}', v_member.revision);
  end if;

  -- Owners report what this member is responsible for BEFORE anything changes: the last
  -- responsible person for something cannot be removed until it is handed over.
  v_event := jsonb_build_object('event', 'membership_deactivated',
                                'member_id', v_member.member_id,
                                'occurred_at', app.cmd_utc(now()),
                                'identity_revision', v_member.revision + 1);
  v_obligations := app.identity_collect_handover(v_event);
  if exists (select 1 from jsonb_array_elements(v_obligations) x
              where (x.value ->> 'last_responsible')::boolean) then
    perform app.cmd_fail('conflict', '{"member_id": "handover_required"}', v_member.revision);
  end if;

  -- Grants end through the 2.3 path (audited with this Admin, scope_revoked dispatched).
  for v_grant in
    select g.* from app.identity_grants g
     where g.member_id = v_member.member_id and g.revoked_at is null
     order by g.granted_at, g.grant_id
       for update
  loop
    perform app.identity_end_grant(p_actor, v_actor.member_id, 'identity.deactivate_membership',
                                   v_grant);
    v_grants := v_grants + 1;
  end loop;

  -- Access is denied at once: the link is suspended (trust epoch moves) and every Auth session
  -- of the account ends.
  select l.* into v_link from app.identity_account_links l
   where l.member_id = v_member.member_id and l.link_state <> 'ended'
     for update;
  if v_link.link_id is not null then
    if v_link.link_state <> 'suspended' then
      update app.identity_account_links l set link_state = 'suspended', updated_at = now()
       where l.link_id = v_link.link_id;
    end if;
    v_sessions := app.identity_revoke_auth_sessions(v_link.auth_user_id);
  end if;

  -- Recovery (2.9 rules): issued grants end; a pending operation (grant consumed, nothing
  -- external yet) becomes obsolete; a dispatched or uncertain one keeps its hold.
  for v_account in
    select distinct g.auth_user_id from app.identity_recovery_grants g
     where g.member_id = v_member.member_id and g.grant_state = 'issued'
  loop
    v_recovery_grants := v_recovery_grants + app.identity_recovery_end_grants(
      v_account, 'cancelled', 'stale', v_actor.member_id, v_actor.account_id, null, v_request);
  end loop;
  for v_op in
    update app.identity_recovery_operations o
       set op_state = 'obsolete', completed_at = clock_timestamp()
     where o.member_id = v_member.member_id and o.op_state = 'pending'
    returning o.*
  loop
    v_operations := v_operations + 1;
    perform app.identity_recovery_audit_add('operation_obsolete', v_actor.member_id,
      v_actor.account_id, null, v_request, v_member.member_id, v_op.case_id, v_op.grant_id,
      v_op.operation_id, 'member_deactivated');
  end loop;

  update app.identity_members m
     set membership_state = 'deactivated', revision = m.revision + 1, updated_at = now()
   where m.member_id = v_member.member_id
  returning m.revision into v_revision;

  insert into app.identity_membership_lifecycle (
    action, actor_member_id, actor_account_id, request_id, member_id, link_id, reason_code,
    revision_after, sessions_revoked, grants_ended, recovery_grants_ended,
    recovery_operations_obsoleted)
  values ('membership_deactivated', v_actor.member_id, v_actor.account_id, v_request,
          v_member.member_id, v_link.link_id, p_payload ->> 'reason_code', v_revision, v_sessions,
          v_grants, v_recovery_grants, v_operations)
  returning event_id into v_lifecycle;

  insert into app.identity_handover_obligations (member_id, lifecycle_event_id, owner_module,
                                                 obligation_kind, subject_id)
  select v_member.member_id, v_lifecycle, x.value ->> 'module', x.value ->> 'kind',
         (x.value ->> 'subject_id')::uuid
    from jsonb_array_elements(v_obligations) x
  on conflict (member_id, owner_module, obligation_kind, subject_id)
     where obligation_state = 'pending' do nothing;
  get diagnostics v_recorded = row_count;
  update app.identity_membership_lifecycle e set obligations_recorded = v_recorded
   where e.event_id = v_lifecycle;

  -- Registered owner hooks flag, cancel or reroute their work in this transaction.
  perform app.identity_dispatch_lifecycle('membership_deactivated', v_member.member_id, v_revision);
  if v_sessions is not null then
    perform app.identity_dispatch_lifecycle('sessions_revoked', v_member.member_id, v_revision);
  end if;
  return app.identity_lifecycle_outcome(v_member.member_id);
end;
$$;

-- identity.restore_membership {member_id, identity_check}; expected = member revision.
create function app.identity_restore_membership(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_member app.identity_members;
  v_link app.identity_account_links;
  v_revision bigint;
  v_request uuid := app.cmd_current_request_id(p_actor, 'identity.restore_membership');
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_member := app.identity_lock_lifecycle_member(p_payload, 'identity_check');
  if v_member.member_id = v_actor.member_id then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  if v_member.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_member.revision);
  end if;
  if v_member.membership_state <> 'deactivated' then
    perform app.cmd_fail('conflict', '{"member_id": "not_deactivated"}', v_member.revision);
  end if;
  select l.* into v_link from app.identity_account_links l
   where l.member_id = v_member.member_id and l.link_state <> 'ended'
     for update;
  -- Back to the state the binding allows; the state change moves the trust epoch, so every
  -- session from before (and during) the deactivation must sign in again.
  if v_link.link_id is not null and v_link.link_state = 'suspended' then
    update app.identity_account_links l
       set link_state = case when l.binding_review_required then 'review_required' else 'active' end,
           updated_at = now()
     where l.link_id = v_link.link_id;
  end if;
  update app.identity_members m
     set membership_state = 'approved', revision = m.revision + 1, updated_at = now()
   where m.member_id = v_member.member_id
  returning m.revision into v_revision;
  insert into app.identity_membership_lifecycle (
    action, actor_member_id, actor_account_id, request_id, member_id, link_id, identity_check,
    revision_after)
  values ('membership_restored', v_actor.member_id, v_actor.account_id, v_request,
          v_member.member_id, v_link.link_id, p_payload ->> 'identity_check', v_revision);
  perform app.identity_dispatch_lifecycle('membership_restored', v_member.member_id, v_revision);
  return app.identity_lifecycle_outcome(v_member.member_id);
end;
$$;

create function app.identity_lifecycle_in_scope(p_actor uuid, p_aggregate_type text,
                                                p_aggregate_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_aggregate_id is not null and p_aggregate_type = 'identity_member'
     and exists (select 1 from app.identity_members m where m.member_id = p_aggregate_id);
$$;

create function app.identity_lifecycle_command(p_envelope jsonb)
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
      when 'identity.deactivate_membership'
        then 'app.identity_deactivate_membership(uuid, bigint, jsonb)'::regprocedure
      when 'identity.restore_membership'
        then 'app.identity_restore_membership(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.identity_lifecycle_in_scope(uuid, text, uuid)'::regprocedure,
    true
  );
end;
$$;

-- POST /rest/v1/rpc/identity_lifecycle_command, Content-Profile: api,
-- body {version, command, request_id, expected_revision, payload}.
create function api.identity_lifecycle_command(jsonb)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.identity_lifecycle_command($1);
$$;

comment on function api.identity_lifecycle_command(jsonb) is
  'Story 2.10: church deactivation and reviewed restoration of a membership (1.4 envelope).';

-- The registered `identity` authorizer: the 2.9 body with the two lifecycle commands added to
-- the Admin branch (every earlier command kept).
create or replace function app.identity_authorize_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  if coalesce(p_request ->> 'command', '') in ('identity.submit_application',
                                                'identity.correct_application') then
    return app.identity_authorize_application_command(p_request);
  end if;
  if coalesce(p_request ->> 'command', '') in ('identity.propose_recovery_email',
                                                'identity.request_credential_change') then
    return app.identity_authorize_member_credential_command(p_request);
  end if;
  if coalesce(p_request ->> 'command', '') in ('identity.withdraw_recovery_email',
                                                'identity.withdraw_credential_change') then
    return app.identity_authorize_member_withdraw_command(p_request);
  end if;
  if coalesce(p_request ->> 'command', '') not in (
       'identity.grant_role', 'identity.revoke_role', 'identity.grant_scope',
       'identity.revoke_scope',
       'identity.approve_application', 'identity.link_application',
       'identity.request_application_details', 'identity.reject_application',
       'identity.create_member', 'identity.unlink_account', 'identity.reclaim_phone_username',
       'identity.approve_recovery_email', 'identity.reject_recovery_email',
       'identity.approve_credential_change', 'identity.reject_credential_change',
       'identity.place_hold', 'identity.release_hold', 'identity.restore_credentials',
       'identity.accept_credentials',
       'identity.open_recovery_case', 'identity.issue_recovery_grant',
       'identity.cancel_recovery_case', 'identity.reconcile_recovery_operation',
       'identity.deactivate_membership', 'identity.restore_membership') then
    return false;
  end if;
  select e.* into r from app.identity_evaluate_grant('admin', null, null) e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  if r.outcome <> 'granted' then
    return false;
  end if;
  perform 1 from app.identity_roles ro where ro.role = 'admin' for update;
  perform 1 from app.identity_grants g
   where g.member_id = r.member_id and g.role = 'admin' and g.revoked_at is null
     for share;
  return found;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------------------------

-- Admin: deactivated members, open login holds and pending handovers. No care, finance or
-- contact fields; obligations carry owner, kind and an opaque subject id only.
create function app.identity_admin_membership_lifecycle()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_member uuid;
  v_link_id uuid;
  v_result jsonb;
begin
  select g.member_id, g.link_id into v_actor_member, v_link_id
    from app.identity_require_grant('admin', null, null) g;
  select jsonb_build_object(
    'deactivated', coalesce((
      select jsonb_agg(app.identity_lifecycle_member_json(x.member_id)
                       || jsonb_build_object(
                            'deactivated_at', x.occurred_at,
                            'reason_code', x.reason_code,
                            'own_member', x.member_id = v_actor_member)
                       order by x.occurred_at desc, x.member_id)
        from (select m.member_id, e.occurred_at, e.reason_code
                from app.identity_members m
                left join lateral (
                  select e.occurred_at, e.reason_code from app.identity_membership_lifecycle e
                   where e.member_id = m.member_id and e.action = 'membership_deactivated'
                   order by e.event_id desc limit 1) e on true
               where m.membership_state = 'deactivated'
               order by e.occurred_at desc nulls last, m.member_id
               limit 200) x), '[]'::jsonb),
    'login_holds', coalesce((
      select jsonb_agg(jsonb_build_object(
                         'hold_id', h.hold_id,
                         'member_id', m.member_id,
                         'display_name', m.display_name,
                         'member_revision', m.revision,
                         'placed_at', h.placed_at,
                         'own_member', m.member_id = v_actor_member,
                         'is_synthetic', m.is_synthetic)
                       order by h.placed_at, h.hold_id)
        from app.identity_holds h
        join app.identity_members m on m.member_id = h.member_id
       where h.released_at is null and h.hold_kind = 'login'), '[]'::jsonb),
    'handovers', coalesce((
      select jsonb_agg(jsonb_build_object(
                         'obligation_id', o.obligation_id,
                         'member_id', m.member_id,
                         'display_name', m.display_name,
                         'membership_state', m.membership_state,
                         'owner_module', o.owner_module,
                         'obligation_kind', o.obligation_kind,
                         'recorded_at', o.recorded_at)
                       order by o.recorded_at, o.obligation_id)
        from (select o.* from app.identity_handover_obligations o
               where o.obligation_state = 'pending'
               order by o.recorded_at, o.obligation_id limit 500) o
        join app.identity_members m on m.member_id = o.member_id), '[]'::jsonb))
    into v_result;
  perform app.identity_record_activity(v_link_id);
  return v_result;
end;
$$;

create function api.identity_admin_membership_lifecycle()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.identity_admin_membership_lifecycle();
$$;

comment on function api.identity_admin_membership_lifecycle() is
  'Story 2.10: Admin-only deactivated members, open login holds and pending handovers.';

-- A trusted own session: is the account's live link to a deactivated membership? Only the
-- account's own state and the church contact; never a reason, an actor or an obligation.
create function app.identity_my_membership_status()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_sub uuid;
begin
  select e.* into r from app.identity_access_evaluate() e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    raise exception using errcode = 'PT401', message = 'unauthenticated', detail = r.outcome;
  end if;
  -- The predicate verified this subject's session before answering anything else.
  v_sub := (app.identity_request_claims() ->> 'sub')::uuid;
  return jsonb_build_object(
    'deactivated', exists (
      select 1 from app.identity_account_links l
        join app.identity_members m on m.member_id = l.member_id
       where l.auth_user_id = v_sub and l.link_state <> 'ended'
         and m.membership_state = 'deactivated'),
    'church_contact', app.identity_church_setting('operational_contact') ->> 'route');
end;
$$;

create function api.identity_my_membership_status()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.identity_my_membership_status();
$$;

comment on function api.identity_my_membership_status() is
  'Story 2.10: whether the signed-in account''s church membership is deactivated, and the '
  'church contact. POST /rest/v1/rpc/identity_my_membership_status with Content-Profile: api.';

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.identity_register_handover_hook(text, regprocedure),
  app.identity_collect_handover(jsonb),
  app.identity_resolve_handover_obligation(text, uuid, text),
  app.fixture_report_handover(jsonb),
  app.identity_is_last_admin(uuid),
  app.identity_hold_reason_code(app.identity_holds),
  app.identity_lifecycle_member_json(uuid),
  app.identity_lifecycle_outcome(uuid),
  app.identity_lock_lifecycle_member(jsonb, text),
  app.identity_lock_reviewed_member(jsonb, text[], boolean, bigint, uuid),
  app.identity_place_hold(uuid, bigint, jsonb),
  app.identity_member_holds_json(uuid),
  app.identity_deactivate_membership(uuid, bigint, jsonb),
  app.identity_restore_membership(uuid, bigint, jsonb),
  app.identity_lifecycle_in_scope(uuid, text, uuid),
  app.identity_lifecycle_command(jsonb),
  api.identity_lifecycle_command(jsonb),
  app.identity_authorize_command(jsonb),
  app.identity_admin_membership_lifecycle(),
  api.identity_admin_membership_lifecycle(),
  app.identity_my_membership_status(),
  api.identity_my_membership_status()
  from public, anon, authenticated, service_role;

grant execute on function app.identity_lifecycle_command(jsonb) to authenticated;
grant execute on function api.identity_lifecycle_command(jsonb) to authenticated;
grant execute on function app.identity_admin_membership_lifecycle() to authenticated;
grant execute on function api.identity_admin_membership_lifecycle() to authenticated;
grant execute on function app.identity_my_membership_status() to authenticated;
grant execute on function api.identity_my_membership_status() to authenticated;

notify pgrst, 'reload schema';
