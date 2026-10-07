-- Delete a member fully through a resumable workflow (story 2.11; I10, AD-14, AD-19, AC-22).
-- Builds on the 2.10 deactivation (grants, recovery grants, handover obligations, lifecycle
-- dispatch), 2.8 session revocation, the 1.4 command envelope with the registered `identity`
-- authorizer, the 2.9 system-command registry and the 1.10 independent recovery journal.
--
--   * Requests (one transaction each; access is denied for good from this step):
--       identity.request_my_deletion {confirm: "delete_my_account"}      the member, in the app
--       identity.request_member_deletion {member_id, identity_check}      an Admin, for a member
--                                                                         who cannot use the app
--     An approved member is deactivated first (the 2.10 effects, reason `member_request`;
--     handover obligations are recorded but never refuse a deletion). Then the live account
--     link ends, every Auth session is revoked, the Auth user is banned (password sign-in fails
--     at Auth from now on), and the access-denied tombstone app.identity_deletions with its
--     ordered steps is recorded. Refused for the last usable Admin and when a deletion exists.
--   * The worker (tools/identity-deletion/worker.mjs, a server-side process with a credential
--     of the new system purpose `identity_deletion`) drives the steps through api.system_command:
--       journal_access_revoked, journal_manifest_member, journal_manifest_account*,
--       auth_account* (Edge Function identity-deletion, Auth Admin), erase_identity,
--       erase_owners (registered owner deletion hooks, Cells included), anonymise, verify,
--       journal_completed_member, journal_completed_account*, complete   (* with a login)
--     Every step records its state, attempts and outcome code and is idempotent; the worker can
--     be stopped anywhere and resumed. Every account the member ever linked is recorded, journaled
--     and deleted. A journal acknowledgement must continue this database's acknowledged chain
--     (seq = head + 1, prev_hash = the head's hash, canonical hash); entries other writers
--     appended are acknowledged first (identity.deletion_journal_catch_up). Journal entries hold opaque UUIDs only and are written to
--     the independent 1.10 journal BEFORE any destructive step; the database acknowledges each
--     one after checking it is exactly the expected entry. Erasure waits while a handover is
--     pending, and every destructive step waits while the Q4 retention gate
--     `identity_deletion_retention` is closed (a labelled fixture opens it in local/staging only).
--     `verify` checks every store and reopens the step that left something behind; `complete`
--     runs only after it and the completion entries.
--   * Erasure keeps the identity_members row as the tombstone (`Deleted member`, deactivated):
--     other members' records name it as an actor. Retained facts keep only the tombstone id; the
--     deleted account id is replaced by the nil UUID per the labelled FIXTURE rule table
--     app.identity_deletion_retention_rules (Q4 unapproved).
--   * Restore replay: app.rcv_apply_journal_entry now delegates to app.rcv_apply_journal_entry_as
--     (also used by the worker's acknowledgement, without an operator) and calls registered
--     replay hooks. Identity's hook acts only while a restore is held: it denies access again,
--     re-creates the workflow, and on a `deletion_completed` entry erases and verifies inline
--     (raising, so the restore stays held, if anything remains).
--   * Row deletions live ONLY in 20261007171600_member_deletion_rows.sql (applied by hand on
--     hosted projects). Until then the three row-deleting functions below are stubs that answer
--     `unavailable`, so erasure fails closed; the request and every denial work without it.
--
-- Contract: `deletion_requested` (already in v1) is now dispatched; `member_deleted` is added
-- under the additive server-only rule. Everything is ASCII; no destructive schema statement.

-- ---------------------------------------------------------------------------------------------
-- Contract event, retention gate (Q4 fixture) and system purpose
-- ---------------------------------------------------------------------------------------------

insert into app.contract_lifecycle_events (event, description) values
  ('member_deleted',
   'Full deletion completed: every store checked; only the access-denied tombstone remains');

insert into app.policy_gates (gate, decision_ref, description, fixture_value) values
  ('identity_deletion_retention', 'Q4',
   'What a full member deletion erases or anonymises and how long journal and backups keep it; '
   'gates the destructive deletion steps',
   '{"fixture_label": "TEST FIXTURE - Q4 retention and backup periods unapproved", '
   '"retained_facts": "anonymise_account_ids"}');

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

-- The access-denied tombstone and its workflow. The account id is kept only while the workflow
-- needs it (it is cleared at completion).
create table app.identity_deletions (
  deletion_id uuid primary key default gen_random_uuid(),
  member_id uuid not null unique references app.identity_members (member_id),
  had_account boolean not null,
  origin text not null check (origin in ('member_request', 'staff_request', 'journal_replay')),
  deletion_state text not null default 'requested'
    check (deletion_state in ('requested', 'completed')),
  requested_at timestamptz not null default clock_timestamp(),
  requested_by_member uuid,
  identity_check text check (identity_check in ('established_relationship', 'in_person')),
  completed_at timestamptz,
  revision bigint not null default 1 check (revision >= 1),
  is_synthetic boolean not null,
  check ((deletion_state = 'completed') = (completed_at is not null)),
  check ((origin = 'staff_request') = (identity_check is not null))
);

comment on table app.identity_deletions is
  'owner: identity. Access-denied tombstones of full member deletions (AD-14): ids, codes and '
  'times only.';

-- Every Auth account the member ever linked (live or ended links, and the accounts of the
-- member's applications), with its journal entries and the Auth step. The account ids are
-- cleared at completion; the journal keeps them as opaque ids.
create table app.identity_deletion_accounts (
  deletion_id uuid not null references app.identity_deletions (deletion_id),
  account_no smallint not null check (account_no >= 1),
  auth_user_id uuid,
  manifest_seq bigint,
  manifest_hash text check (manifest_hash is null or manifest_hash ~ '^[0-9a-f]{64}$'),
  auth_done boolean not null default false,
  auth_outcome text check (auth_outcome is null or auth_outcome ~ '^[a-z][a-z0-9_]{0,62}$'),
  auth_attempts integer not null default 0 check (auth_attempts >= 0),
  completed_seq bigint,
  completed_hash text check (completed_hash is null or completed_hash ~ '^[0-9a-f]{64}$'),
  primary key (deletion_id, account_no),
  unique (deletion_id, auth_user_id)
);

comment on table app.identity_deletion_accounts is
  'owner: identity. The Auth accounts a deletion removes (opaque ids, cleared at completion).';

-- The opaque ids of the member's erased records (applications, credential changes, proposals,
-- recovery requests/cases/grants, reclaims, links), recorded before erasure so verification and
-- the receipt purge can still find what referred to them.
create table app.identity_deletion_aggregates (
  deletion_id uuid not null references app.identity_deletions (deletion_id),
  kind text not null check (kind in ('application', 'credential_change', 'recovery_email_proposal',
    'recovery_case', 'recovery_grant', 'recovery_request', 'phone_reclaim', 'link')),
  aggregate_id uuid not null,
  primary key (deletion_id, aggregate_id)
);

comment on table app.identity_deletion_aggregates is
  'owner: identity. Opaque ids of a deleted member''s erased records (verification only).';

create table app.identity_deletion_steps (
  deletion_id uuid not null references app.identity_deletions (deletion_id),
  step text not null check (step in (
    'journal_access_revoked', 'journal_manifest_member', 'journal_manifest_account',
    'auth_account', 'erase_identity', 'erase_owners', 'anonymise', 'verify',
    'journal_completed_member', 'journal_completed_account', 'complete')),
  ordinal smallint not null,
  step_state text not null default 'pending'
    check (step_state in ('pending', 'waiting', 'failed', 'done')),
  attempts integer not null default 0 check (attempts >= 0),
  outcome text check (outcome is null or outcome ~ '^[a-z][a-z0-9_]{0,62}$'),
  journal_seq bigint check (journal_seq is null or journal_seq >= 1),
  journal_hash text check (journal_hash is null or journal_hash ~ '^[0-9a-f]{64}$'),
  updated_at timestamptz not null default clock_timestamp(),
  primary key (deletion_id, step),
  unique (deletion_id, ordinal)
);

comment on table app.identity_deletion_steps is
  'owner: identity. Ordered, idempotent deletion steps with state, attempts, outcome code and '
  'the acknowledged journal entry (seq and hash) of journal steps.';

-- Content-free: ids and codes only.
create table app.identity_deletion_audit (
  event_id bigint generated always as identity primary key,
  occurred_at timestamptz not null default clock_timestamp(),
  environment text not null default app.platform_current_environment(),
  action text not null check (action in (
    'deletion_requested', 'step_done', 'step_waiting', 'step_failed', 'deletion_completed',
    'deletion_replayed')),
  actor_kind text not null check (actor_kind in ('member', 'system', 'recovery')),
  actor_member_id uuid,
  system_principal_id uuid,
  request_id uuid,
  deletion_id uuid not null,
  step text,
  code text check (code is null or code ~ '^[a-z][a-z0-9_]{0,62}$')
);

comment on table app.identity_deletion_audit is
  'owner: identity. Deletion requests, step outcomes and completion (AD-14, AD-19): ids and codes.';

create index identity_deletion_audit_deletion on app.identity_deletion_audit (deletion_id, event_id);

-- Owner deletion hooks: one per owning module.
create table app.identity_deletion_hooks (
  module text primary key references app.contract_modules (module),
  handler text not null,
  registered_at timestamptz not null default now()
);

comment on table app.identity_deletion_hooks is
  'owner: identity. Registered owner deletion hooks (AD-14): (jsonb {member_id, account_id, '
  'deletion_id, phase}) -> jsonb {remaining}.';

-- Q4 is unapproved: which retained-fact columns hold an account id that a deletion replaces with
-- the nil UUID. Labelled fixture rules, not church policy.
create table app.identity_deletion_retention_rules (
  table_name text not null check (table_name ~ '^identity_[a-z0-9_]+$'),
  column_name text not null check (column_name ~ '^[a-z][a-z0-9_]{0,62}$'),
  rule text not null check (rule = 'anonymise_account'),
  label text not null check (label like 'FIXTURE%'),
  primary key (table_name, column_name)
);

comment on table app.identity_deletion_retention_rules is
  'owner: identity. FIXTURE retention rules (Q4 unapproved): retained-fact columns whose deleted '
  'account id is replaced by the nil UUID.';

insert into app.identity_deletion_retention_rules (table_name, column_name, rule, label)
select r.t, r.c, 'anonymise_account', 'FIXTURE - Q4 retention unapproved'
  from (values
    ('identity_access_audit', 'actor_account_id'),
    ('identity_credential_audit', 'actor_account_id'),
    ('identity_credential_review_audit', 'actor_account_id'),
    ('identity_membership_audit', 'actor_account_id'),
    ('identity_membership_audit', 'target_account_id'),
    ('identity_membership_lifecycle', 'actor_account_id'),
    ('identity_recovery_audit', 'actor_account_id'),
    ('identity_grants', 'granted_by_account'),
    ('identity_grants', 'revoked_by_account'),
    ('identity_holds', 'placed_by_account'),
    ('identity_holds', 'released_by_account'),
    ('identity_recovery_cases', 'opened_by_account'),
    ('identity_recovery_cases', 'closed_by_account'),
    ('identity_recovery_grants', 'issued_by_account'),
    ('identity_recovery_operations', 'reconciled_by_account'),
    ('identity_credential_changes', 'decided_by_account'),
    ('identity_recovery_email_proposals', 'decided_by_account'),
    ('identity_member_provenance', 'recorded_by_account'),
    ('identity_contact_routes', 'created_by_account'),
    ('identity_phone_reclaims', 'actor_account_id'),
    ('identity_application_events', 'actor_auth_user_id')) as r (t, c);

alter table app.identity_deletions enable row level security;
alter table app.identity_deletion_steps enable row level security;
alter table app.identity_deletion_audit enable row level security;
alter table app.identity_deletion_hooks enable row level security;
alter table app.identity_deletion_retention_rules enable row level security;
alter table app.identity_deletion_accounts enable row level security;
alter table app.identity_deletion_aggregates enable row level security;
revoke all on table app.identity_deletion_accounts, app.identity_deletion_aggregates
  from public, anon, authenticated, service_role;
revoke all on table app.identity_deletions, app.identity_deletion_steps,
                    app.identity_deletion_audit, app.identity_deletion_hooks,
                    app.identity_deletion_retention_rules
  from public, anon, authenticated, service_role;
revoke all on sequence app.identity_deletion_audit_event_id_seq
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- The row-deleting functions: fail-closed stubs, replaced by 20261007171600 (applied by hand)
-- ---------------------------------------------------------------------------------------------

-- Identity personal rows of the deletion's member and accounts (only rows tied to them), the
-- receipts of the member's accounts and of the member's records, and the accounts' Auth
-- audit-log entries. Returns the number of rows removed.
create function app.identity_deletion_purge_rows(p_deletion_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
begin
  perform app.cmd_fail('unavailable', '{"deletion": "rows_migration_missing"}');
  return null;
end;
$$;

-- Restore replay only: the Auth user row of a restored snapshot (Auth Admin is not reachable on
-- an isolated restore target). Returns the number of rows removed.
create function app.identity_deletion_purge_auth_user(p_auth_user_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
begin
  perform app.cmd_fail('unavailable', '{"deletion": "rows_migration_missing"}');
  return null;
end;
$$;

-- Cells personal rows of the member (memberships, requests, member state).
create function app.cells_deletion_purge_rows(p_member_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
begin
  perform app.cmd_fail('unavailable', '{"deletion": "rows_migration_missing"}');
  return null;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Owner deletion hooks
-- ---------------------------------------------------------------------------------------------

create function app.identity_register_deletion_hook(p_module text, p_handler regprocedure)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_handler text;
begin
  if p_module = 'identity' then
    perform app.contract_registration_fail('identity erases its own data; it does not hook itself');
  end if;
  v_handler := app.contract_validate_handler(p_module, p_handler, 'jsonb'::regtype);
  insert into app.identity_deletion_hooks (module, handler) values (p_module, v_handler);
end;
$$;

-- Calls every registered deletion hook in lock order; returns [{module, remaining}]. Fail
-- closed: a missing handler or an answer of another shape raises.
create function app.identity_call_deletion_hooks(
  p_member_id uuid,
  p_auth_user_id uuid,
  p_deletion_id uuid,
  p_phase text
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_hook record;
  v_proc regprocedure;
  v_answer jsonb;
  v_out jsonb := '[]'::jsonb;
begin
  if p_phase not in ('erase', 'check') then
    raise exception using errcode = '22023', message = 'unknown deletion hook phase';
  end if;
  for v_hook in
    select h.module, h.handler
      from app.identity_deletion_hooks h
      join app.contract_modules m on m.module = h.module
     order by m.lock_rank, h.module
  loop
    v_proc := pg_catalog.to_regprocedure(v_hook.handler);
    if v_proc is null then
      raise exception using errcode = 'PCTR1',
        message = format('registered deletion hook %s is missing', v_hook.handler);
    end if;
    execute format('select %s($1)', v_proc::regproc) into v_answer
      using jsonb_build_object('member_id', p_member_id, 'account_id', p_auth_user_id,
                               'deletion_id', p_deletion_id, 'phase', p_phase);
    if jsonb_typeof(v_answer) is distinct from 'object'
       or app.contract_unknown_keys(v_answer, array['remaining']) <> '{}'::jsonb
       or jsonb_typeof(v_answer -> 'remaining') is distinct from 'number'
       or (v_answer ->> 'remaining') !~ '^[0-9]{1,9}$' then
      raise exception using errcode = 'PCTR1',
        message = format('deletion hook %s answered an unexpected shape', v_hook.handler);
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'module', v_hook.module, 'remaining', (v_answer ->> 'remaining')::integer));
  end loop;
  return v_out;
end;
$$;

-- Cells' own deletion hook: erase removes the member's memberships, requests and member state
-- and anonymises the account in Cells' retained facts; check counts what is left.
create function app.cells_erase_member(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_input ->> 'member_id')::uuid;
  v_account uuid := nullif(p_input ->> 'account_id', '')::uuid;
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
  v_left integer;
begin
  if p_input ->> 'phase' = 'erase' then
    perform app.cells_deletion_purge_rows(v_member);
    if v_account is not null then
      update app.cells_membership_audit a set actor_account_id = v_nil
       where a.actor_account_id = v_account;
      update app.cells_memberships m set confirmed_by_account = v_nil
       where m.confirmed_by_account = v_account;
      update app.cells_membership_requests r set requested_by_account = v_nil
       where r.requested_by_account = v_account;
      update app.cells_membership_requests r set decided_by_account = v_nil
       where r.decided_by_account = v_account;
    end if;
  end if;
  select (select count(*) from app.cells_memberships m where m.member_id = v_member)
       + (select count(*) from app.cells_membership_requests r where r.member_id = v_member)
       + (select count(*) from app.cells_member_states s where s.member_id = v_member)
       + case when v_account is null then 0 else
           (select count(*) from app.cells_membership_audit a where a.actor_account_id = v_account)
         + (select count(*) from app.cells_memberships m where m.confirmed_by_account = v_account)
         + (select count(*) from app.cells_membership_requests r
             where r.requested_by_account = v_account or r.decided_by_account = v_account)
         end
    into v_left;
  return jsonb_build_object('remaining', v_left);
end;
$$;

comment on function app.cells_erase_member(jsonb) is
  'Cells deletion hook (story 2.11): erase or check the member''s Cells personal data.';

select app.identity_register_deletion_hook('cells', 'app.cells_erase_member(jsonb)'::regprocedure);

-- SYNTHETIC deletion hook of the fixture owner (registered only by tests and the E2E): the
-- member's fixture duties are kept as anonymous facts (member id replaced by the nil UUID).
create function app.fixture_erase_member(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_input ->> 'member_id')::uuid;
begin
  if p_input ->> 'phase' = 'erase' then
    update app.fixture_duties d set member_id = '00000000-0000-0000-0000-000000000000'
     where d.member_id = v_member;
  end if;
  return jsonb_build_object('remaining',
    (select count(*) from app.fixture_duties d where d.member_id = v_member));
end;
$$;

comment on function app.fixture_erase_member(jsonb) is
  'SYNTHETIC deletion hook over app.fixture_duties. Register only in tests and the local E2E.';

-- ---------------------------------------------------------------------------------------------
-- Recovery journal: an operator-free apply for the worker, and replay hooks (platform, 1.10)
-- ---------------------------------------------------------------------------------------------

create table app.rcv_replay_hooks (
  module text primary key references app.contract_modules (module),
  handler text not null,
  registered_at timestamptz not null default now()
);

comment on table app.rcv_replay_hooks is
  'Owners that re-apply their journal entries (AD-14): (jsonb {entry, restoring}) -> jsonb.';

alter table app.rcv_replay_hooks enable row level security;
revoke all on table app.rcv_replay_hooks from public, anon, authenticated, service_role;

create function app.rcv_register_replay_hook(p_module text, p_handler regprocedure)
returns void
language plpgsql
set search_path = ''
as $$
begin
  insert into app.rcv_replay_hooks (module, handler)
  values (p_module, app.contract_validate_handler(p_module, p_handler, 'jsonb'::regtype));
end;
$$;

-- The 1.10 body of app.rcv_apply_journal_entry without the operator check (the caller attests
-- who applies it), followed by the registered replay hooks in lock order. `restoring` is true
-- while a restore is held: only then do hooks re-apply effects.
create function app.rcv_apply_journal_entry_as(p_entry jsonb, p_applied_by text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_seq bigint;
  v_kind text := p_entry ->> 'kind';
  v_hash text := p_entry ->> 'hash';
  v_subject uuid;
  v_object uuid;
  v_bucket text;
  v_at timestamptz;
  v_existing app.rcv_journal_acks;
  v_restore uuid := (select s.restore_id from app.rcv_recovery_state s where s.state = 'restored_held');
  v_allowed text[] := array['v', 'journal', 'seq', 'kind', 'at', 'prev_hash', 'hash'];
  v_hook record;
  v_proc regprocedure;
  v_ignored jsonb;
begin
  if p_applied_by is null or p_applied_by !~ '^[a-z][a-z0-9_:-]{1,80}$' then
    raise exception using errcode = '22023', message = 'applied_by is required';
  end if;
  if p_entry is null or jsonb_typeof(p_entry) <> 'object'
     or (p_entry ->> 'v') is distinct from '1'
     or jsonb_typeof(p_entry -> 'seq') <> 'number' or (p_entry ->> 'seq') !~ '^[1-9][0-9]{0,15}$'
     or v_hash is null or v_hash !~ '^[0-9a-f]{64}$'
     or (p_entry ->> 'prev_hash') is null or (p_entry ->> 'prev_hash') !~ '^[0-9a-f]{64}$'
     or v_kind is null
     or v_kind not in ('checkpoint', 'access_revoked', 'deletion_manifest', 'deletion_completed', 'seal') then
    raise exception using errcode = '22023', message = 'malformed journal entry';
  end if;
  v_seq := (p_entry ->> 'seq')::bigint;
  if jsonb_typeof(p_entry -> 'at') is distinct from 'string'
     or (p_entry ->> 'at') !~ '^\d{4}-\d{2}-\d{2}T' then
    raise exception using errcode = '22023', message = 'journal entry needs a valid at';
  end if;
  begin
    v_at := (p_entry ->> 'at')::timestamptz;
  exception when others then
    raise exception using errcode = '22023', message = 'journal entry needs a valid at';
  end;
  if v_kind = 'seal' then
    if jsonb_typeof(p_entry -> 'head_seq') is distinct from 'number'
       or (p_entry ->> 'head_seq') !~ '^[0-9]{1,16}$'
       or (p_entry ->> 'head_seq')::bigint <> v_seq - 1
       or jsonb_typeof(p_entry -> 'cutoff') is distinct from 'string'
       or (p_entry ->> 'cutoff') !~ '^\d{4}-\d{2}-\d{2}T' then
      raise exception using errcode = '22023', message = 'seal needs head_seq = seq - 1 and a cutoff';
    end if;
    begin
      if (p_entry ->> 'cutoff')::timestamptz > v_at then
        raise exception using errcode = '22023', message = 'seal cutoff is after the seal';
      end if;
    exception when invalid_datetime_format or datetime_field_overflow then
      raise exception using errcode = '22023', message = 'seal needs head_seq = seq - 1 and a cutoff';
    end;
  end if;
  if v_kind in ('access_revoked', 'deletion_manifest') then
    v_allowed := v_allowed || array['subject'];
  end if;
  if v_kind in ('deletion_manifest', 'deletion_completed') then
    v_allowed := v_allowed || array['object'];
  end if;
  if v_kind = 'seal' then
    v_allowed := v_allowed || array['head_seq', 'cutoff'];
  end if;
  if exists (select 1 from jsonb_object_keys(p_entry) k where k <> all (v_allowed)) then
    raise exception using errcode = '22023', message = 'journal entry carries a field outside its kind';
  end if;
  if v_kind in ('access_revoked', 'deletion_manifest') then
    v_subject := (p_entry ->> 'subject')::uuid;
    if v_subject is null then
      raise exception using errcode = '22023', message = 'journal entry needs a subject';
    end if;
  end if;
  if v_kind in ('deletion_manifest', 'deletion_completed') then
    if jsonb_typeof(p_entry -> 'object') <> 'object'
       or exists (select 1 from jsonb_object_keys(p_entry -> 'object') k
                   where k not in ('bucket', 'object_id')) then
      raise exception using errcode = '22023', message = 'journal object must be {bucket, object_id}';
    end if;
    v_object := (p_entry -> 'object' ->> 'object_id')::uuid;
    v_bucket := p_entry -> 'object' ->> 'bucket';
    if v_object is null or v_bucket is null or v_bucket !~ '^[a-z0-9][a-z0-9-]{2,62}$' then
      raise exception using errcode = '22023', message = 'journal object must be {bucket, object_id}';
    end if;
  end if;

  select * into v_existing from app.rcv_journal_acks a where a.seq = v_seq for update;
  if found then
    if v_existing.entry_hash <> v_hash or v_existing.kind <> v_kind then
      raise exception using errcode = '22023', message = 'journal_mismatch';
    end if;
    insert into app.rcv_events (environment, operator, action, restore_id, journal_seq)
    values (app.platform_current_environment(), p_applied_by, 'entry_already_applied', v_restore, v_seq);
  else
    insert into app.rcv_journal_acks (seq, kind, entry_hash, subject_id, object_id, applied_by, replayed_restore_id)
    values (v_seq, v_kind, v_hash, v_subject, v_object, p_applied_by, v_restore);
    insert into app.rcv_events (environment, operator, action, restore_id, journal_seq)
    values (app.platform_current_environment(), p_applied_by, 'entry_applied', v_restore, v_seq);
  end if;

  if v_kind in ('access_revoked', 'deletion_manifest') then
    update app.rcv_synthetic_subjects s
       set access_revoked_at = coalesce(s.access_revoked_at, v_at)
     where s.subject_id = v_subject;
  end if;
  if v_kind = 'deletion_manifest' then
    update app.rcv_synthetic_objects o
       set deletion_pending_at = coalesce(o.deletion_pending_at, v_at)
     where o.object_id = v_object;
  end if;
  if v_kind = 'deletion_completed' then
    update app.rcv_synthetic_objects o
       set deletion_pending_at = coalesce(o.deletion_pending_at, v_at),
           deleted_at = coalesce(o.deleted_at, v_at)
     where o.object_id = v_object;
  end if;

  -- Registered owners re-apply their own effects (deny-only). A failing hook fails the apply,
  -- so a restore stays held.
  for v_hook in
    select h.module, h.handler
      from app.rcv_replay_hooks h
      join app.contract_modules m on m.module = h.module
     order by m.lock_rank, h.module
  loop
    v_proc := pg_catalog.to_regprocedure(v_hook.handler);
    if v_proc is null then
      raise exception using errcode = 'PCTR1',
        message = format('registered replay hook %s is missing', v_hook.handler);
    end if;
    execute format('select %s($1)', v_proc::regproc) into v_ignored
      using jsonb_build_object('entry', p_entry, 'restoring', v_restore is not null);
  end loop;

  return jsonb_build_object(
    'seq', v_seq, 'kind', v_kind, 'applied', not (v_existing.seq is not null),
    'delete_object', case when v_object is null then null
                          else jsonb_build_object('bucket', v_bucket, 'object_id', v_object) end);
end;
$$;

-- Canonical JSON exactly as tools/recovery/journal.mjs builds it (object keys sorted, no
-- whitespace) and the entry hash sha256(canonical(entry without hash)).
create function app.rcv_canonical(p_value jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case jsonb_typeof(p_value)
    when 'object' then '{' || coalesce((
      select string_agg(to_jsonb(k.key)::text || ':' || app.rcv_canonical(p_value -> k.key), ','
                        order by k.key collate "C")
        from jsonb_object_keys(p_value) as k (key)), '') || '}'
    when 'array' then '[' || coalesce((
      select string_agg(app.rcv_canonical(e.value), ',' order by e.ord)
        from jsonb_array_elements(p_value) with ordinality as e (value, ord)), '') || ']'
    else p_value::text end;
$$;

create function app.rcv_entry_hash(p_entry jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(sha256(convert_to(app.rcv_canonical(p_entry - 'hash'), 'UTF8')), 'hex');
$$;

-- The 1.10 operator procedure: same signature and privileges; now delegates.
create or replace function app.rcv_apply_journal_entry(p_entry jsonb, p_operator text)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform app.rcv_require_operator(p_operator);
  return app.rcv_apply_journal_entry_as(p_entry, p_operator);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------

create function app.identity_deletion_placeholder() returns text
language sql immutable set search_path = '' as $$ select 'Deleted member'::text $$;

-- The ordered steps of a deletion; the account steps only when there is a login.
create function app.identity_deletion_step_plan(p_has_account boolean)
returns table (step text, ordinal smallint)
language sql
immutable
set search_path = ''
as $$
  select s.step, s.ordinal::smallint
    from (values
      ('journal_access_revoked', 10, false), ('journal_manifest_member', 20, false),
      ('journal_manifest_account', 30, true), ('auth_account', 40, true),
      ('erase_identity', 50, false), ('erase_owners', 60, false), ('anonymise', 70, false),
      ('verify', 80, false), ('journal_completed_member', 90, false),
      ('journal_completed_account', 100, true), ('complete', 110, false)) as s (step, ordinal, account)
   where p_has_account or not s.account;
$$;

create function app.identity_deletion_audit_add(
  p_action text, p_actor_kind text, p_actor_member uuid, p_principal uuid, p_request uuid,
  p_deletion_id uuid, p_step text, p_code text
) returns void
language sql
set search_path = ''
as $$
  insert into app.identity_deletion_audit (action, actor_kind, actor_member_id,
                                           system_principal_id, request_id, deletion_id, step, code)
  values (p_action, p_actor_kind, p_actor_member, p_principal, p_request, p_deletion_id, p_step,
          p_code);
$$;

-- The first step that is not done (null when all are).
create function app.identity_deletion_next_step(p_deletion_id uuid)
returns app.identity_deletion_steps
language sql
stable
set search_path = ''
as $$
  select s.* from app.identity_deletion_steps s
   where s.deletion_id = p_deletion_id and s.step_state <> 'done'
   order by s.ordinal
   limit 1;
$$;

create function app.identity_deletion_expected_entry(p_deletion app.identity_deletions, p_step text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select case p_step
    when 'journal_access_revoked' then jsonb_build_object(
      'kind', 'access_revoked', 'subject', p_deletion.member_id)
    when 'journal_manifest_member' then jsonb_build_object(
      'kind', 'deletion_manifest', 'subject', p_deletion.member_id,
      'object', jsonb_build_object('bucket', 'identity-member', 'object_id', p_deletion.member_id))
    when 'journal_manifest_account' then (
      select jsonb_build_object(
               'kind', 'deletion_manifest', 'subject', p_deletion.member_id,
               'object', jsonb_build_object('bucket', 'auth-user', 'object_id', a.auth_user_id))
        from app.identity_deletion_accounts a
       where a.deletion_id = p_deletion.deletion_id and a.manifest_seq is null
       order by a.account_no limit 1)
    when 'journal_completed_member' then jsonb_build_object(
      'kind', 'deletion_completed',
      'object', jsonb_build_object('bucket', 'identity-member', 'object_id', p_deletion.member_id))
    when 'journal_completed_account' then (
      select jsonb_build_object(
               'kind', 'deletion_completed',
               'object', jsonb_build_object('bucket', 'auth-user', 'object_id', a.auth_user_id))
        from app.identity_deletion_accounts a
       where a.deletion_id = p_deletion.deletion_id and a.completed_seq is null
       order by a.account_no limit 1)
  end;
$$;

-- Why a step cannot run now (null when it can).
create function app.identity_deletion_blocker(p_deletion app.identity_deletions, p_step text)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when app.rcv_serving_hold() then 'restore_held'
    when p_step in ('auth_account', 'erase_identity', 'erase_owners', 'anonymise')
         and not app.policy_is_open('identity_deletion_retention') then 'policy_gate_closed'
    when p_step in ('erase_identity', 'erase_owners', 'anonymise')
         and exists (select 1 from app.identity_handover_obligations o
                      where o.member_id = p_deletion.member_id and o.obligation_state = 'pending')
      then 'handover_pending'
  end;
$$;

create function app.identity_deletion_describe(p_deletion_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_del app.identity_deletions;
  v_step app.identity_deletion_steps;
  v_block text;
  v_next jsonb;
begin
  select d.* into v_del from app.identity_deletions d where d.deletion_id = p_deletion_id;
  if not found then
    return jsonb_build_object('found', false);
  end if;
  v_step := app.identity_deletion_next_step(v_del.deletion_id);
  if v_step.step is null then
    v_next := jsonb_build_object('action', 'done');
  else
    v_block := app.identity_deletion_blocker(v_del, v_step.step);
    v_next := jsonb_build_object('step', v_step.step, 'attempts', v_step.attempts,
      'action', case
        when v_block is not null then 'wait'
        when v_step.step like 'journal\_%' then 'journal'
        when v_step.step = 'auth_account' then 'auth'
        else 'advance' end);
    if v_block is not null then
      v_next := v_next || jsonb_build_object('reason', v_block);
    elsif v_step.step like 'journal\_%' then
      -- The entry to journal, and the head this database acknowledged: the worker first
      -- acknowledges any journal entries after it (identity.deletion_journal_catch_up).
      v_next := v_next || jsonb_build_object(
        'entry', app.identity_deletion_expected_entry(v_del, v_step.step),
        'journal_head', app.identity_deletion_journal_head());
    end if;
  end if;
  return jsonb_build_object('found', true, 'deletion_id', v_del.deletion_id,
                            'deletion_state', v_del.deletion_state, 'next', v_next);
end;
$$;

create function app.identity_deletion_mark(
  p_deletion_id uuid, p_step text, p_state text, p_outcome text,
  p_count_attempt boolean default false
) returns void
language sql
set search_path = ''
as $$
  update app.identity_deletion_steps s
     set step_state = p_state, outcome = p_outcome, updated_at = clock_timestamp(),
         attempts = s.attempts + case when p_count_attempt then 1 else 0 end
   where s.deletion_id = p_deletion_id and s.step = p_step;
$$;

-- Ban the Auth user (sign-in fails at Auth). The column or table may be missing on an isolated
-- restore target: then there is nothing to sign in to.
create function app.identity_deletion_ban(p_auth_user_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_auth_user_id is null or pg_catalog.to_regclass('auth.users') is null then
    return;
  end if;
  begin
    update auth.users u
       set banned_until = clock_timestamp() + interval '100 years'
     where u.id = p_auth_user_id
       and (u.banned_until is null or u.banned_until < clock_timestamp() + interval '99 years');
  exception when undefined_column or undefined_table then
    null;
  end;
end;
$$;

-- Rows of one Auth account in every Auth table that holds them (sessions, refresh tokens,
-- one-time tokens, factors and identities cascade with the user in GoTrue; each is checked).
create function app.identity_deletion_auth_present(p_auth_user_id uuid)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare
  v_present boolean := false;
  v_check record;
begin
  if p_auth_user_id is null then
    return false;
  end if;
  for v_check in
    select x.tbl, x.sql from (values
      ('auth.users', 'select exists (select 1 from auth.users t where t.id = $1)'),
      ('auth.identities', 'select exists (select 1 from auth.identities t where t.user_id = $1)'),
      ('auth.sessions', 'select exists (select 1 from auth.sessions t where t.user_id = $1)'),
      ('auth.refresh_tokens', 'select exists (select 1 from auth.refresh_tokens t where t.user_id = $1::text)'),
      ('auth.one_time_tokens', 'select exists (select 1 from auth.one_time_tokens t where t.user_id = $1)'),
      ('auth.mfa_factors', 'select exists (select 1 from auth.mfa_factors t where t.user_id = $1)'))
      as x (tbl, sql)
  loop
    if pg_catalog.to_regclass(v_check.tbl) is not null then
      begin
        execute v_check.sql into v_present using p_auth_user_id;
      exception when undefined_column or undefined_table then
        v_present := false;
      end;
      if v_present then
        return true;
      end if;
    end if;
  end loop;
  return false;
end;
$$;

-- The account's Auth audit-log entries (as actor, or as the subject of an admin action).
create function app.identity_deletion_auth_audit_present(p_auth_user_id uuid)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare
  v_present boolean := false;
begin
  if p_auth_user_id is null or pg_catalog.to_regclass('auth.audit_log_entries') is null then
    return false;
  end if;
  execute 'select exists (select 1 from auth.audit_log_entries e
                           where e.payload ->> ''actor_id'' = $1
                              or e.payload -> ''traits'' ->> ''user_id'' = $1)'
    into v_present using p_auth_user_id::text;
  return v_present;
end;
$$;

-- The deletion's recorded accounts (in order; empty after completion).
create function app.identity_deletion_account_ids(p_deletion_id uuid)
returns uuid[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(a.auth_user_id order by a.account_no), '{}'::uuid[])
    from app.identity_deletion_accounts a
   where a.deletion_id = p_deletion_id and a.auth_user_id is not null;
$$;

-- The head of this database's journal acknowledgements: {seq, hash} (0 and the genesis hash).
create function app.identity_deletion_journal_head()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce((select jsonb_build_object('seq', a.seq, 'hash', a.entry_hash)
                     from app.rcv_journal_acks a order by a.seq desc limit 1),
                  jsonb_build_object('seq', 0, 'hash', repeat('0', 64)));
$$;

-- Why a journal entry cannot be acknowledged next (null when it can): the chain must continue
-- this database's acknowledgements exactly (seq = head + 1, prev_hash = the head's hash) and the
-- entry's hash must be the canonical hash of its fields. The caller holds the chain lock.
create function app.identity_deletion_chain_problem(p_entry jsonb)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_head jsonb := app.identity_deletion_journal_head();
begin
  if jsonb_typeof(p_entry -> 'seq') is distinct from 'number'
     or (p_entry ->> 'seq') !~ '^[1-9][0-9]{0,15}$'
     or (p_entry ->> 'seq')::bigint <> (v_head ->> 'seq')::bigint + 1 then
    return 'journal_gap';
  end if;
  if (p_entry ->> 'prev_hash') is distinct from (v_head ->> 'hash') then
    return 'journal_chain_broken';
  end if;
  if (p_entry ->> 'hash') is distinct from app.rcv_entry_hash(p_entry) then
    return 'entry_invalid';
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- The deletion steps (shared by the worker and restore replay)
-- ---------------------------------------------------------------------------------------------

-- erase_identity: record the opaque ids of the member's records, then the personal rows
-- (row-deletion file), the receipt redaction and the tombstone.
create function app.identity_deletion_erase_identity(p_deletion app.identity_deletions)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_accounts uuid[] := app.identity_deletion_account_ids(p_deletion.deletion_id);
  v_links uuid[];
  v_apps uuid[];
begin
  v_links := array(select l.link_id from app.identity_account_links l
                    where l.member_id = p_deletion.member_id or l.auth_user_id = any (v_accounts));
  v_apps := array(select a.application_id from app.identity_membership_applications a
                   where a.member_id = p_deletion.member_id or a.auth_user_id = any (v_accounts));
  insert into app.identity_deletion_aggregates (deletion_id, kind, aggregate_id)
  select p_deletion.deletion_id, x.kind, x.id
    from (
      select 'link'::text as kind, unnest(v_links) as id
      union all select 'application', unnest(v_apps)
      union all select 'credential_change', c.change_id from app.identity_credential_changes c
                 where c.member_id = p_deletion.member_id or c.link_id = any (v_links)
      union all select 'recovery_email_proposal', p.proposal_id
                  from app.identity_recovery_email_proposals p
                 where p.member_id = p_deletion.member_id or p.link_id = any (v_links)
      union all select 'recovery_case', c.case_id from app.identity_recovery_cases c
                 where c.member_id = p_deletion.member_id or c.link_id = any (v_links)
      union all select 'recovery_grant', g.grant_id from app.identity_recovery_grants g
                 where g.member_id = p_deletion.member_id or g.link_id = any (v_links)
      union all select 'recovery_request', g.recovery_request_id from app.identity_recovery_grants g
                 where g.member_id = p_deletion.member_id or g.link_id = any (v_links)
      union all select 'phone_reclaim', r.reclaim_id from app.identity_phone_reclaims r
                 where r.released_account_id = any (v_accounts)
                    or r.withdrawn_application_id = any (v_apps)) x
   where x.id is not null
  on conflict do nothing;
  perform app.identity_deletion_purge_rows(p_deletion.deletion_id);
  perform app.identity_deletion_redact_receipts(p_deletion);
  update app.identity_members m
     set display_name = app.identity_deletion_placeholder(), membership_state = 'deactivated',
         revision = m.revision + 1, updated_at = now()
   where m.member_id = p_deletion.member_id
     and (m.display_name <> app.identity_deletion_placeholder()
          or m.membership_state <> 'deactivated');
end;
$$;

-- Other actors' receipts that mention the member or one of its accounts keep working for
-- idempotent replay, with those ids replaced by the nil UUID (the member's own receipts and the
-- receipts of the member's records are deleted by the row-deletion file).
create function app.identity_deletion_redact_receipts(p_deletion app.identity_deletions)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
  v_n integer;
  v_count integer := 0;
  v_nil constant text := '00000000-0000-0000-0000-000000000000';
begin
  for v_id in
    select x from unnest(array[p_deletion.member_id]
                         || app.identity_deletion_account_ids(p_deletion.deletion_id)) x
  loop
    update app.cmd_receipts r set result = replace(r.result::text, v_id::text, v_nil)::jsonb
     where strpos(r.result::text, v_id::text) > 0;
    get diagnostics v_n = row_count;
    v_count := v_count + v_n;
    update app.sys_receipts r set result = replace(r.result::text, v_id::text, v_nil)::jsonb
     where strpos(r.result::text, v_id::text) > 0;
    get diagnostics v_n = row_count;
    v_count := v_count + v_n;
  end loop;
  return v_count;
end;
$$;

-- anonymise: every deleted account id in Identity's retained facts (FIXTURE rules, Q4).
create function app.identity_deletion_anonymise(p_deletion app.identity_deletions)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_rule app.identity_deletion_retention_rules;
  v_account uuid;
  v_count integer := 0;
  v_n integer;
begin
  foreach v_account in array app.identity_deletion_account_ids(p_deletion.deletion_id) loop
    for v_rule in select x.* from app.identity_deletion_retention_rules x
                   order by x.table_name, x.column_name loop
      execute format('update app.%I set %I = %L::uuid where %I = $1', v_rule.table_name,
                     v_rule.column_name, '00000000-0000-0000-0000-000000000000',
                     v_rule.column_name)
        using v_account;
      get diagnostics v_n = row_count;
      v_count := v_count + v_n;
    end loop;
  end loop;
  return v_count;
end;
$$;

-- Every store, checked; returns the codes of the stores that still hold something:
-- auth_account (an Auth row of any recorded account), identity (any Identity personal row, the
-- tombstone, Auth audit entries or receipts), owner_<module>, retained_facts.
create function app.identity_deletion_remaining(p_deletion app.identity_deletions, p_with_auth boolean)
returns text[]
language plpgsql
set search_path = ''
as $$
declare
  m uuid := p_deletion.member_id;
  v_accounts uuid[] := app.identity_deletion_account_ids(p_deletion.deletion_id);
  v_aggs uuid[];
  v_links uuid[];
  v_left text[] := '{}';
  v_rule record;
  v_account uuid;
  v_id uuid;
  v_n bigint;
  v_owner jsonb;
  v_identity boolean := false;
begin
  v_aggs := array(select g.aggregate_id from app.identity_deletion_aggregates g
                   where g.deletion_id = p_deletion.deletion_id);
  v_links := array(select g.aggregate_id from app.identity_deletion_aggregates g
                    where g.deletion_id = p_deletion.deletion_id and g.kind = 'link');
  if p_with_auth then
    foreach v_account in array v_accounts loop
      if app.identity_deletion_auth_present(v_account) then
        v_left := v_left || 'auth_account'::text;
        exit;
      end if;
    end loop;
  end if;
  foreach v_account in array v_accounts loop
    if app.identity_deletion_auth_audit_present(v_account) then
      v_identity := true;
    end if;
  end loop;
  if v_identity
     or exists (select 1 from app.identity_account_links l
                 where l.member_id = m or l.auth_user_id = any (v_accounts) or l.link_id = any (v_links))
     or exists (select 1 from app.identity_binding_history h where h.link_id = any (v_links))
     or exists (select 1 from app.identity_credential_events e where e.link_id = any (v_links))
     or exists (select 1 from app.identity_holds h where h.member_id = m)
     or exists (select 1 from app.identity_contact_routes c where c.member_id = m)
     or exists (select 1 from app.identity_member_provenance p where p.member_id = m)
     or exists (select 1 from app.identity_membership_applications x
                 where x.member_id = m or x.auth_user_id = any (v_accounts)
                    or x.application_id = any (v_aggs))
     or exists (select 1 from app.identity_application_events e where e.application_id = any (v_aggs))
     or exists (select 1 from app.identity_recovery_cases c
                 where c.member_id = m or c.case_id = any (v_aggs))
     or exists (select 1 from app.identity_recovery_grants g
                 where g.member_id = m or g.grant_id = any (v_aggs))
     or exists (select 1 from app.identity_recovery_operations o where o.member_id = m)
     or exists (select 1 from app.identity_recovery_requests r
                 where r.recovery_request_id = any (v_aggs))
     or exists (select 1 from app.identity_credential_changes c
                 where c.member_id = m or c.change_id = any (v_aggs))
     or exists (select 1 from app.identity_recovery_email_proposals p
                 where p.member_id = m or p.proposal_id = any (v_aggs))
     or exists (select 1 from app.identity_phone_reclaims r
                 where r.released_account_id = any (v_accounts) or r.reclaim_id = any (v_aggs))
     or exists (select 1 from app.cmd_receipts r
                 where r.actor_id = any (v_accounts)
                    or r.aggregate_id = any (v_aggs || array[m, p_deletion.deletion_id]))
     or not exists (select 1 from app.identity_members x
                     where x.member_id = m and x.display_name = app.identity_deletion_placeholder()
                       and x.membership_state = 'deactivated') then
    v_identity := true;
  end if;
  if not v_identity then
    foreach v_id in array (array[m] || v_accounts) loop
      if exists (select 1 from app.cmd_receipts r where strpos(r.result::text, v_id::text) > 0)
         or exists (select 1 from app.sys_receipts r where strpos(r.result::text, v_id::text) > 0) then
        v_identity := true;
        exit;
      end if;
    end loop;
  end if;
  if v_identity then
    v_left := v_left || 'identity'::text;
  end if;
  foreach v_account in array coalesce(nullif(v_accounts, '{}'::uuid[]), array[null::uuid]) loop
    for v_owner in
      select x.value from jsonb_array_elements(app.identity_call_deletion_hooks(
        m, v_account, p_deletion.deletion_id, 'check')) x
    loop
      if (v_owner ->> 'remaining')::integer > 0
         and not (('owner_' || (v_owner ->> 'module')) = any (v_left)) then
        v_left := v_left || ('owner_' || (v_owner ->> 'module'))::text;
      end if;
    end loop;
  end loop;
  <<rules>>
  foreach v_account in array v_accounts loop
    for v_rule in select x.* from app.identity_deletion_retention_rules x loop
      execute format('select count(*) from app.%I where %I = $1', v_rule.table_name,
                     v_rule.column_name)
        into v_n using v_account;
      if v_n > 0 then
        v_left := v_left || 'retained_facts'::text;
        exit rules;
      end if;
    end loop;
  end loop;
  return v_left;
end;
$$;

-- Completes the deletion once every other step is done.
create function app.identity_deletion_finish(
  p_deletion app.identity_deletions, p_actor_kind text, p_principal uuid, p_request uuid
) returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_revision bigint;
begin
  if p_deletion.deletion_state = 'completed' then
    return true;  -- already completed (a replay of its entries changes nothing more)
  end if;
  if exists (select 1 from app.identity_deletion_steps s
              where s.deletion_id = p_deletion.deletion_id and s.step <> 'complete'
                and s.step_state <> 'done') then
    return false;
  end if;
  -- Final sweep (idempotent): receipts written while the last steps ran, and every Auth
  -- audit-log entry of the accounts (including the `user_deleted` entry of the Auth step).
  perform app.identity_deletion_purge_rows(p_deletion.deletion_id);
  perform app.identity_deletion_redact_receipts(p_deletion);
  update app.identity_deletion_accounts a set auth_user_id = null
   where a.deletion_id = p_deletion.deletion_id;
  update app.identity_deletions d
     set deletion_state = 'completed', completed_at = clock_timestamp(), revision = d.revision + 1
   where d.deletion_id = p_deletion.deletion_id and d.deletion_state <> 'completed';
  perform app.identity_deletion_mark(p_deletion.deletion_id, 'complete', 'done', 'completed', true);
  perform app.identity_deletion_audit_add('deletion_completed', p_actor_kind, null, p_principal,
    p_request, p_deletion.deletion_id, 'complete', null);
  select m.revision into v_revision from app.identity_members m
   where m.member_id = p_deletion.member_id;
  perform app.identity_dispatch_lifecycle('member_deleted', p_deletion.member_id, v_revision);
  return true;
end;
$$;

-- Runs one database-local step (erase_identity, erase_owners, anonymise, verify, complete).
-- Returns {step, outcome, stores?}. The caller holds the deletion and member locks.
create function app.identity_deletion_run_local(
  p_deletion app.identity_deletions, p_step text, p_actor_kind text, p_principal uuid,
  p_request uuid
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_owners jsonb;
  v_left text[];
  v_account uuid;
  v_bad boolean := false;
begin
  if p_step = 'erase_identity' then
    perform app.identity_deletion_erase_identity(p_deletion);
  elsif p_step = 'erase_owners' then
    -- Each owner hook erases for the member and for every recorded account.
    foreach v_account in array coalesce(nullif(app.identity_deletion_account_ids(p_deletion.deletion_id),
                                               '{}'::uuid[]), array[null::uuid]) loop
      v_owners := app.identity_call_deletion_hooks(p_deletion.member_id, v_account,
                                                   p_deletion.deletion_id, 'erase');
      if exists (select 1 from jsonb_array_elements(v_owners) x
                  where (x.value ->> 'remaining')::integer > 0) then
        v_bad := true;
      end if;
    end loop;
    if v_bad then
      perform app.identity_deletion_mark(p_deletion.deletion_id, p_step, 'failed',
                                         'owner_incomplete', true);
      perform app.identity_deletion_audit_add('step_failed', p_actor_kind, null, p_principal,
        p_request, p_deletion.deletion_id, p_step, 'owner_incomplete');
      return jsonb_build_object('step', p_step, 'outcome', 'retry');
    end if;
  elsif p_step = 'anonymise' then
    perform app.identity_deletion_anonymise(p_deletion);
  elsif p_step = 'verify' then
    v_left := app.identity_deletion_remaining(p_deletion, true);
    if cardinality(v_left) > 0 then
      perform app.identity_deletion_mark(p_deletion.deletion_id, p_step, 'failed',
                                         'incomplete', true);
      -- Reopen the step that left something behind; it runs again next.
      if 'auth_account' = any (v_left) then
        update app.identity_deletion_accounts a set auth_done = false
         where a.deletion_id = p_deletion.deletion_id
           and app.identity_deletion_auth_present(a.auth_user_id);
        perform app.identity_deletion_mark(p_deletion.deletion_id, 'auth_account', 'pending',
                                           'reopened');
      end if;
      if 'identity' = any (v_left) then
        perform app.identity_deletion_mark(p_deletion.deletion_id, 'erase_identity', 'pending',
                                           'reopened');
      end if;
      if exists (select 1 from unnest(v_left) x where x like 'owner\_%') then
        perform app.identity_deletion_mark(p_deletion.deletion_id, 'erase_owners', 'pending',
                                           'reopened');
      end if;
      if 'retained_facts' = any (v_left) then
        perform app.identity_deletion_mark(p_deletion.deletion_id, 'anonymise', 'pending',
                                           'reopened');
      end if;
      perform app.identity_deletion_audit_add('step_failed', p_actor_kind, null, p_principal,
        p_request, p_deletion.deletion_id, p_step, 'incomplete');
      return jsonb_build_object('step', p_step, 'outcome', 'incomplete',
                                'stores', to_jsonb(v_left));
    end if;
  elsif p_step = 'complete' then
    if not app.identity_deletion_finish(p_deletion, p_actor_kind, p_principal, p_request) then
      return jsonb_build_object('step', p_step, 'outcome', 'not_ready');
    end if;
    return jsonb_build_object('step', p_step, 'outcome', 'completed');
  else
    raise exception using errcode = '22023', message = 'not a database-local deletion step';
  end if;
  perform app.identity_deletion_mark(p_deletion.deletion_id, p_step, 'done',
    case p_step when 'verify' then 'verified' else 'done' end, true);
  perform app.identity_deletion_audit_add('step_done', p_actor_kind, null, p_principal, p_request,
    p_deletion.deletion_id, p_step, null);
  return jsonb_build_object('step', p_step, 'outcome', 'done');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- The request (both routes)
-- ---------------------------------------------------------------------------------------------

-- Records the access-denied tombstone. The caller has locked the Admin role row, the live link
-- and the member, and checked the actor; this checks the deletion-specific refusals.
create function app.identity_deletion_open(
  p_member app.identity_members,
  p_actor_member uuid,
  p_actor_account uuid,
  p_command text,
  p_origin text,
  p_identity_check text
) returns app.identity_deletions
language plpgsql
set search_path = ''
as $$
declare
  v_request uuid := app.cmd_current_request_id(p_actor_account, p_command);
  v_link app.identity_account_links;
  v_grant app.identity_grants;
  v_op app.identity_recovery_operations;
  v_del app.identity_deletions;
  v_accounts uuid[];
  v_account uuid;
  v_event jsonb;
  v_obligations jsonb;
  v_was_approved boolean := p_member.membership_state = 'approved';
  v_sessions integer;
  v_n integer;
  v_grants integer := 0;
  v_recovery_grants integer := 0;
  v_operations integer := 0;
  v_recorded integer := 0;
  v_lifecycle bigint;
  v_revision bigint;
begin
  -- Serialises every last-Admin decision (the 2.3 Admin branch takes the same lock first).
  perform 1 from app.identity_roles ro where ro.role = 'admin' for update;
  if exists (select 1 from app.identity_deletions d where d.member_id = p_member.member_id) then
    perform app.cmd_fail('conflict', '{"member_id": "deletion_requested"}', p_member.revision);
  end if;
  if app.identity_is_last_admin(p_member.member_id) then
    perform app.cmd_fail('forbidden', '{"member_id": "last_admin"}');
  end if;

  if v_was_approved then
    -- Owners report what must be handed over; a deletion records it (erasure waits for it) and is
    -- never refused for it: security denial comes first (AD-14).
    v_event := jsonb_build_object('event', 'membership_deactivated',
                                  'member_id', p_member.member_id,
                                  'occurred_at', app.cmd_utc(now()),
                                  'identity_revision', p_member.revision + 1);
    v_obligations := app.identity_collect_handover(v_event);
  end if;

  for v_grant in
    select g.* from app.identity_grants g
     where g.member_id = p_member.member_id and g.revoked_at is null
     order by g.granted_at, g.grant_id
       for update
  loop
    perform app.identity_end_grant(p_actor_account, p_actor_member, p_command, v_grant);
    v_grants := v_grants + 1;
  end loop;

  -- Every Auth account the member ever linked (live or ended links) or applied with.
  v_accounts := array(
    select x.auth_user_id from (
      select l.auth_user_id, l.created_at from app.identity_account_links l
       where l.member_id = p_member.member_id
      union all
      select a.auth_user_id, a.submitted_at from app.identity_membership_applications a
       where a.member_id = p_member.member_id) x
     group by x.auth_user_id
     order by min(x.created_at), x.auth_user_id);

  select l.* into v_link from app.identity_account_links l
   where l.member_id = p_member.member_id and l.link_state <> 'ended'
     for update;
  foreach v_account in array v_accounts loop
    v_recovery_grants := v_recovery_grants + app.identity_recovery_end_grants(v_account,
      'cancelled', 'stale', p_actor_member, p_actor_account, null, v_request);
  end loop;
  for v_op in
    update app.identity_recovery_operations o
       set op_state = 'obsolete', completed_at = clock_timestamp()
     where o.member_id = p_member.member_id and o.op_state = 'pending'
    returning o.*
  loop
    v_operations := v_operations + 1;
    perform app.identity_recovery_audit_add('operation_obsolete', p_actor_member, p_actor_account,
      null, v_request, p_member.member_id, v_op.case_id, v_op.grant_id, v_op.operation_id,
      'member_deleted');
  end loop;

  -- Access ends for good: the live link ends (trust epoch moves), every session of every account
  -- goes, and every account is banned so a password sign-in fails at Auth from this step on.
  if v_link.link_id is not null then
    update app.identity_account_links l
       set link_state = 'ended', ended_at = clock_timestamp(), updated_at = now()
     where l.link_id = v_link.link_id;
  end if;
  foreach v_account in array v_accounts loop
    v_n := app.identity_revoke_auth_sessions(v_account);
    if v_account = v_link.auth_user_id then
      v_sessions := v_n;
    end if;
    perform app.identity_deletion_ban(v_account);
  end loop;

  update app.identity_members m
     set membership_state = 'deactivated', revision = m.revision + 1, updated_at = now()
   where m.member_id = p_member.member_id
  returning m.revision into v_revision;

  if v_was_approved then
    insert into app.identity_membership_lifecycle (
      action, actor_member_id, actor_account_id, request_id, member_id, link_id, reason_code,
      revision_after, sessions_revoked, grants_ended, recovery_grants_ended,
      recovery_operations_obsoleted)
    values ('membership_deactivated', p_actor_member, p_actor_account, v_request,
            p_member.member_id, v_link.link_id, 'member_request', v_revision, v_sessions,
            v_grants, v_recovery_grants, v_operations)
    returning event_id into v_lifecycle;
    insert into app.identity_handover_obligations (member_id, lifecycle_event_id, owner_module,
                                                   obligation_kind, subject_id)
    select p_member.member_id, v_lifecycle, x.value ->> 'module', x.value ->> 'kind',
           (x.value ->> 'subject_id')::uuid
      from jsonb_array_elements(v_obligations) x
    on conflict (member_id, owner_module, obligation_kind, subject_id)
       where obligation_state = 'pending' do nothing;
    get diagnostics v_recorded = row_count;
    update app.identity_membership_lifecycle e set obligations_recorded = v_recorded
     where e.event_id = v_lifecycle;
  end if;

  insert into app.identity_deletions (member_id, had_account, origin, requested_by_member,
                                      identity_check, is_synthetic)
  values (p_member.member_id, cardinality(v_accounts) > 0, p_origin, p_actor_member,
          p_identity_check, p_member.is_synthetic)
  returning * into v_del;
  insert into app.identity_deletion_accounts (deletion_id, account_no, auth_user_id)
  select v_del.deletion_id, x.n::smallint, x.id
    from unnest(v_accounts) with ordinality as x (id, n);
  insert into app.identity_deletion_steps (deletion_id, step, ordinal)
  select v_del.deletion_id, s.step, s.ordinal
    from app.identity_deletion_step_plan(v_del.had_account) s;
  perform app.identity_deletion_audit_add('deletion_requested', 'member', p_actor_member, null,
    v_request, v_del.deletion_id, null, p_origin);

  -- Registered owner hooks act in this transaction.
  if v_was_approved then
    perform app.identity_dispatch_lifecycle('membership_deactivated', p_member.member_id, v_revision);
  end if;
  perform app.identity_dispatch_lifecycle('deletion_requested', p_member.member_id, v_revision);
  if v_sessions is not null then
    perform app.identity_dispatch_lifecycle('sessions_revoked', p_member.member_id, v_revision);
  end if;
  return v_del;
end;
$$;

create function app.identity_deletion_json(p_deletion_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'deletion_id', d.deletion_id,
    'member_id', d.member_id,
    'display_name', m.display_name,
    'origin', d.origin,
    'deletion_state', d.deletion_state,
    'had_account', d.had_account,
    'requested_at', d.requested_at,
    'completed_at', d.completed_at,
    'revision', d.revision,
    'is_synthetic', d.is_synthetic,
    'pending_obligations', (select count(*)::int from app.identity_handover_obligations o
                             where o.member_id = d.member_id and o.obligation_state = 'pending'),
    'steps', coalesce((select jsonb_agg(jsonb_build_object(
                                 'step', s.step, 'state', s.step_state, 'attempts', s.attempts,
                                 'outcome', s.outcome) order by s.ordinal)
                         from app.identity_deletion_steps s
                        where s.deletion_id = d.deletion_id), '[]'::jsonb),
    'next', app.identity_deletion_describe(d.deletion_id) -> 'next')
    from app.identity_deletions d
    join app.identity_members m on m.member_id = d.member_id
   where d.deletion_id = p_deletion_id;
$$;

create function app.identity_deletion_outcome(p_deletion_id uuid, p_full boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'identity_deletion',
    'aggregate_id', d.deletion_id,
    'revision', d.revision,
    'data', case when p_full then app.identity_deletion_json(d.deletion_id)
                 -- The member's own answer: no name, no steps; the account is now signed out.
                 else jsonb_build_object('deletion_id', d.deletion_id,
                                         'deletion_state', d.deletion_state,
                                         'signed_out', true) end)
    from app.identity_deletions d
   where d.deletion_id = p_deletion_id;
$$;

create function app.identity_request_my_deletion(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  r record;
  v_errors jsonb;
  v_member app.identity_members;
  v_del app.identity_deletions;
begin
  -- Lock order of every Admin decision: the Admin role row first (last-Admin rule), then the
  -- live link, then the member.
  perform 1 from app.identity_roles ro where ro.role = 'admin' for update;
  select e.* into r from app.identity_access_evaluate() e;
  if r.outcome <> 'granted' or r.link_id is null then
    perform app.cmd_fail('forbidden');
  end if;
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, array['confirm']);
  if coalesce(jsonb_typeof(p_payload -> 'confirm'), 'null') = 'null' then
    v_errors := v_errors || '{"confirm": "required"}';
  elsif p_payload -> 'confirm' is distinct from '"delete_my_account"'::jsonb then
    v_errors := v_errors || '{"confirm": "invalid"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  -- A destructive request: the member confirms the password first (a recent password sign-in).
  if not app.identity_session_recent_password() then
    perform app.cmd_fail('forbidden', '{"session": "reauthenticate"}');
  end if;
  perform 1 from app.identity_account_links l where l.link_id = r.link_id for update;
  select m.* into v_member from app.identity_members m where m.member_id = r.member_id for update;
  v_del := app.identity_deletion_open(v_member, v_member.member_id, p_actor,
                                      'identity.request_my_deletion', 'member_request', null);
  return app.identity_deletion_outcome(v_del.deletion_id, false);
end;
$$;

-- Two-person rule (Decision, story 2.11): for a member who has an account link, the hold or the
-- deactivation that makes the app unusable must come from someone other than the requesting
-- Admin (another Admin, the member's own Auth change in review, or the system).
create function app.identity_request_member_deletion(
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
  v_del app.identity_deletions;
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  perform app.identity_lock_payload_member_link(p_payload);
  v_member := app.identity_lock_lifecycle_member(p_payload, 'identity_check');
  if app.identity_is_last_admin(v_member.member_id) then
    perform app.cmd_fail('forbidden', '{"member_id": "last_admin"}');
  end if;
  if v_member.member_id = v_actor.member_id then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  if v_member.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_member.revision);
  end if;
  if exists (select 1 from app.identity_deletions d where d.member_id = v_member.member_id) then
    perform app.cmd_fail('conflict', '{"member_id": "deletion_requested"}', v_member.revision);
  end if;
  if v_member.membership_state = 'approved'
     and app.identity_member_account_label(v_member.member_id) = 'app_account' then
    perform app.cmd_fail('conflict', '{"member_id": "member_can_use_app"}', v_member.revision);
  end if;
  select l.* into v_link from app.identity_account_links l
   where l.member_id = v_member.member_id and l.link_state <> 'ended';
  if v_link.link_id is not null
     and not (
       (v_member.membership_state = 'deactivated'
        and coalesce((select e.actor_member_id from app.identity_membership_lifecycle e
                       where e.member_id = v_member.member_id and e.action = 'membership_deactivated'
                       order by e.event_id desc limit 1), v_nil) <> v_actor.member_id)
       or exists (select 1 from app.identity_holds h
                   where h.member_id = v_member.member_id and h.released_at is null
                     and coalesce(h.placed_by_member, v_nil) <> v_actor.member_id)
       or v_link.link_state = 'review_required' or v_link.binding_review_required) then
    perform app.cmd_fail('conflict', '{"member_id": "second_admin_required"}', v_member.revision);
  end if;
  v_del := app.identity_deletion_open(v_member, v_actor.member_id, v_actor.account_id,
                                      'identity.request_member_deletion', 'staff_request',
                                      p_payload ->> 'identity_check');
  return app.identity_deletion_outcome(v_del.deletion_id, true);
end;
$$;

create function app.identity_deletion_in_scope(p_actor uuid, p_aggregate_type text,
                                               p_aggregate_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_aggregate_id is not null and p_aggregate_type = 'identity_deletion'
     and exists (select 1 from app.identity_deletions d where d.deletion_id = p_aggregate_id);
$$;

create function app.identity_deletion_command(p_envelope jsonb)
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
      when 'identity.request_my_deletion'
        then 'app.identity_request_my_deletion(uuid, bigint, jsonb)'::regprocedure
      when 'identity.request_member_deletion'
        then 'app.identity_request_member_deletion(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.identity_deletion_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'identity.request_my_deletion'
  );
end;
$$;

-- POST /rest/v1/rpc/identity_deletion_command, Content-Profile: api,
-- body {version, command, request_id, expected_revision, payload}.
create function api.identity_deletion_command(jsonb)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.identity_deletion_command($1);
$$;

comment on function api.identity_deletion_command(jsonb) is
  'Story 2.11: a member requests deletion in the app; an Admin requests it for a member who '
  'cannot use the app (1.4 envelope).';

-- A link of a member with a deletion never becomes live again (every path).
create function app.identity_on_link_deletion_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.link_state <> 'ended'
     and exists (select 1 from app.identity_deletions d where d.member_id = new.member_id) then
    perform app.cmd_fail('conflict', '{"member_id": "deletion_requested"}');
  end if;
  return new;
end;
$$;

create trigger identity_link_deletion_guard
  before insert or update of link_state on app.identity_account_links
  for each row
  execute function app.identity_on_link_deletion_guard();

-- ---------------------------------------------------------------------------------------------
-- 2.10 functions replaced in place (latest bodies, same signatures and privileges)
-- ---------------------------------------------------------------------------------------------

-- identity.restore_membership: the 2.10 body; a member with a deletion is never restored.
create or replace function app.identity_restore_membership(
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
  perform app.identity_lock_payload_member_link(p_payload);
  v_member := app.identity_lock_lifecycle_member(p_payload, 'identity_check');
  if v_member.member_id = v_actor.member_id then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  if v_member.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_member.revision);
  end if;
  if exists (select 1 from app.identity_deletions d where d.member_id = v_member.member_id) then
    perform app.cmd_fail('conflict', '{"member_id": "deletion_requested"}', v_member.revision);
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

-- Admin: the 2.10 body; members with a deletion are listed by the deletion read instead of
-- among the deactivated memberships (their handovers stay listed).
create or replace function app.identity_admin_membership_lifecycle()
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
                 and not exists (select 1 from app.identity_deletions d
                                  where d.member_id = m.member_id)
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

-- The registered `identity` authorizer: the 2.10 body plus the two deletion commands (the
-- member's request needs a granted session; the Admin route shares the Admin branch).
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
                                                'identity.request_credential_change',
                                                'identity.request_my_deletion') then
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
       'identity.deactivate_membership', 'identity.restore_membership',
       'identity.request_member_deletion') then
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
-- System commands (purpose identity_deletion), run by the worker and the Edge Function
-- ---------------------------------------------------------------------------------------------

create function app.identity_deletion_payload_check(p_command text, p_payload jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_keys text[];
  v_errors jsonb;
  v_err text;
begin
  v_keys := case p_command
    when 'identity.deletion_queue' then array['limit']
    when 'identity.deletion_journal_ack' then array['deletion_id', 'step', 'entry']
    when 'identity.deletion_journal_catch_up' then array['entry']
    when 'identity.deletion_auth_complete' then array['deletion_id', 'auth_result']
    else array['deletion_id'] end;
  v_errors := app.contract_unknown_keys(p_payload, v_keys);
  if 'deletion_id' = any (v_keys) then
    v_err := app.contract_uuid_error(p_payload -> 'deletion_id');
    if v_err is not null then
      v_errors := v_errors || jsonb_build_object('deletion_id', v_err);
    end if;
  end if;
  if 'limit' = any (v_keys) and p_payload ? 'limit'
     and not app.contract_integer_in(p_payload -> 'limit', 1, 100) then
    v_errors := v_errors || '{"limit": "invalid"}';
  end if;
  if 'step' = any (v_keys) then
    if coalesce(jsonb_typeof(p_payload -> 'step'), 'null') = 'null' then
      v_errors := v_errors || '{"step": "required"}';
    elsif jsonb_typeof(p_payload -> 'step') <> 'string'
          or p_payload ->> 'step' not in ('journal_access_revoked', 'journal_manifest_member',
               'journal_manifest_account', 'journal_completed_member',
               'journal_completed_account') then
      v_errors := v_errors || '{"step": "invalid"}';
    end if;
  end if;
  if 'entry' = any (v_keys) and jsonb_typeof(p_payload -> 'entry') is distinct from 'object' then
    v_errors := v_errors || jsonb_build_object('entry',
      case when p_payload ? 'entry' then 'must_be_object' else 'required' end);
  end if;
  if 'auth_result' = any (v_keys) then
    if coalesce(jsonb_typeof(p_payload -> 'auth_result'), 'null') = 'null' then
      v_errors := v_errors || '{"auth_result": "required"}';
    elsif jsonb_typeof(p_payload -> 'auth_result') <> 'string'
          or p_payload ->> 'auth_result' not in ('deleted', 'absent', 'rejected', 'unknown') then
      v_errors := v_errors || '{"auth_result": "invalid"}';
    end if;
  end if;
  return v_errors;
end;
$$;

create function app.identity_deletion_check_journal_catch_up(p_payload jsonb) returns jsonb
language sql stable set search_path = '' as $$
  select app.identity_deletion_payload_check('identity.deletion_journal_catch_up', p_payload) $$;

create function app.identity_deletion_check_queue(p_payload jsonb) returns jsonb
language sql stable set search_path = '' as $$
  select app.identity_deletion_payload_check('identity.deletion_queue', p_payload) $$;
create function app.identity_deletion_check_next(p_payload jsonb) returns jsonb
language sql stable set search_path = '' as $$
  select app.identity_deletion_payload_check('identity.deletion_next', p_payload) $$;
create function app.identity_deletion_check_journal_ack(p_payload jsonb) returns jsonb
language sql stable set search_path = '' as $$
  select app.identity_deletion_payload_check('identity.deletion_journal_ack', p_payload) $$;
create function app.identity_deletion_check_auth_begin(p_payload jsonb) returns jsonb
language sql stable set search_path = '' as $$
  select app.identity_deletion_payload_check('identity.deletion_auth_begin', p_payload) $$;
create function app.identity_deletion_check_auth_complete(p_payload jsonb) returns jsonb
language sql stable set search_path = '' as $$
  select app.identity_deletion_payload_check('identity.deletion_auth_complete', p_payload) $$;
create function app.identity_deletion_check_advance(p_payload jsonb) returns jsonb
language sql stable set search_path = '' as $$
  select app.identity_deletion_payload_check('identity.deletion_advance', p_payload) $$;

-- Locks a deletion for a worker step in the lock order link -> deletion -> member. Returns null
-- when there is no such deletion.
create function app.identity_deletion_lock(p_deletion_id uuid)
returns app.identity_deletions
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_del app.identity_deletions;
begin
  select d.member_id into v_member from app.identity_deletions d where d.deletion_id = p_deletion_id;
  if v_member is null then
    return null;
  end if;
  perform 1 from app.identity_account_links l where l.member_id = v_member for update;
  select d.* into v_del from app.identity_deletions d where d.deletion_id = p_deletion_id for update;
  perform 1 from app.identity_members m where m.member_id = v_member for update;
  return v_del;
end;
$$;

-- identity.deletion_queue {limit?}: the open deletions, oldest first, with their next action.
create function app.identity_sys_deletion_queue(p_principal uuid, p_request uuid, p_payload jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('data', jsonb_build_object('deletions', coalesce(jsonb_agg(
           jsonb_build_object('deletion_id', x.deletion_id)
           || jsonb_build_object('next', app.identity_deletion_describe(x.deletion_id) -> 'next')
           order by x.requested_at, x.deletion_id), '[]'::jsonb)))
    from (select d.deletion_id, d.requested_at from app.identity_deletions d
           where d.deletion_state = 'requested'
           order by d.requested_at, d.deletion_id
           limit coalesce((p_payload ->> 'limit')::integer, 20)) x;
$$;

-- identity.deletion_next {deletion_id}: what to do next (with the exact journal entry fields).
create function app.identity_sys_deletion_next(p_principal uuid, p_request uuid, p_payload jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('data',
    app.identity_deletion_describe((p_payload ->> 'deletion_id')::uuid));
$$;

-- identity.deletion_journal_ack {deletion_id, step, entry}: the worker appended `entry` to the
-- independent journal for `step`. The database acknowledges it only when it is exactly the
-- expected entry AND it continues this database's acknowledged chain (seq = head + 1, prev_hash =
-- the head's hash) with its canonical hash. Idempotent for the same entry.
create function app.identity_sys_deletion_journal_ack(p_principal uuid, p_request uuid,
                                                      p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_del app.identity_deletions;
  v_step app.identity_deletion_steps;
  v_next app.identity_deletion_steps;
  v_entry jsonb := p_payload -> 'entry';
  v_expected jsonb;
  v_reason text;
  v_account_step boolean;
  v_account smallint;
begin
  v_del := app.identity_deletion_lock((p_payload ->> 'deletion_id')::uuid);
  if v_del.deletion_id is null then
    return jsonb_build_object('data', jsonb_build_object('acked', false, 'reason', 'not_found'));
  end if;
  perform pg_advisory_xact_lock(hashtext('app.rcv_journal_acks chain'));
  select s.* into v_step from app.identity_deletion_steps s
   where s.deletion_id = v_del.deletion_id and s.step = p_payload ->> 'step';
  if v_step.step is null then
    return jsonb_build_object('data', jsonb_build_object('acked', false, 'reason', 'no_such_step'));
  end if;
  v_account_step := v_step.step in ('journal_manifest_account', 'journal_completed_account');
  -- The same entry again: an idempotent no-op.
  if exists (select 1 from app.rcv_journal_acks a
              where a.seq = (v_entry ->> 'seq')::numeric and a.entry_hash = v_entry ->> 'hash')
     and (v_step.journal_hash = v_entry ->> 'hash'
          or exists (select 1 from app.identity_deletion_accounts a
                      where a.deletion_id = v_del.deletion_id
                        and v_entry ->> 'hash' in (a.manifest_hash, a.completed_hash))) then
    return jsonb_build_object('data', jsonb_build_object('acked', true, 'reason', 'already_done'));
  end if;
  if v_step.step_state = 'done' then
    return jsonb_build_object('data', jsonb_build_object('acked', false, 'reason', 'already_done'));
  end if;
  v_next := app.identity_deletion_next_step(v_del.deletion_id);
  if v_next.step is distinct from v_step.step then
    return jsonb_build_object('data', jsonb_build_object('acked', false, 'reason', 'not_next'));
  end if;
  v_expected := app.identity_deletion_expected_entry(v_del, v_step.step);
  if v_expected is null
     or v_entry ->> 'kind' is distinct from v_expected ->> 'kind'
     or (v_entry -> 'subject') is distinct from (v_expected -> 'subject')
     or (v_entry -> 'object') is distinct from (v_expected -> 'object') then
    v_reason := 'entry_mismatch';
  else
    v_reason := app.identity_deletion_chain_problem(v_entry);
  end if;
  if v_reason is null then
    begin
      perform app.rcv_apply_journal_entry_as(v_entry, 'system:' || p_principal::text);
    exception when sqlstate '22023' then
      v_reason := case when sqlerrm = 'journal_mismatch' then 'journal_mismatch'
                       else 'entry_invalid' end;
    end;
  end if;
  if v_reason is not null then
    perform app.identity_deletion_mark(v_del.deletion_id, v_step.step, 'failed', v_reason, true);
    perform app.identity_deletion_audit_add('step_failed', 'system', null, p_principal, p_request,
      v_del.deletion_id, v_step.step, v_reason);
    return jsonb_build_object('data', jsonb_build_object('acked', false, 'reason', v_reason));
  end if;
  if v_account_step then
    select a.account_no into v_account from app.identity_deletion_accounts a
     where a.deletion_id = v_del.deletion_id
       and a.auth_user_id = (v_entry -> 'object' ->> 'object_id')::uuid;
    if v_step.step = 'journal_manifest_account' then
      update app.identity_deletion_accounts a
         set manifest_seq = (v_entry ->> 'seq')::bigint, manifest_hash = v_entry ->> 'hash'
       where a.deletion_id = v_del.deletion_id and a.account_no = v_account;
    else
      update app.identity_deletion_accounts a
         set completed_seq = (v_entry ->> 'seq')::bigint, completed_hash = v_entry ->> 'hash'
       where a.deletion_id = v_del.deletion_id and a.account_no = v_account;
    end if;
  end if;
  if v_account_step and app.identity_deletion_expected_entry(v_del, v_step.step) is not null then
    -- More accounts to journal for this step.
    update app.identity_deletion_steps s
       set step_state = 'pending', outcome = 'journaled', attempts = s.attempts + 1,
           journal_seq = (v_entry ->> 'seq')::bigint, journal_hash = v_entry ->> 'hash',
           updated_at = clock_timestamp()
     where s.deletion_id = v_del.deletion_id and s.step = v_step.step;
  else
    update app.identity_deletion_steps s
       set step_state = 'done', outcome = 'journaled', attempts = s.attempts + 1,
           journal_seq = (v_entry ->> 'seq')::bigint, journal_hash = v_entry ->> 'hash',
           updated_at = clock_timestamp()
     where s.deletion_id = v_del.deletion_id and s.step = v_step.step;
  end if;
  perform app.identity_deletion_audit_add('step_done', 'system', null, p_principal, p_request,
    v_del.deletion_id, v_step.step, 'journaled');
  return jsonb_build_object('data', jsonb_build_object('acked', true,
    'seq', (v_entry ->> 'seq')::bigint));
end;
$$;

-- identity.deletion_journal_catch_up {entry}: acknowledges one journal entry that other writers
-- appended after this database's head (for example a seal or another deletion), under the same
-- chain rules, so the worker's own entries can continue the chain. Deny-only entries; the
-- registered replay hooks do nothing outside a held restore.
create function app.identity_sys_deletion_journal_catch_up(p_principal uuid, p_request uuid,
                                                           p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_entry jsonb := p_payload -> 'entry';
  v_reason text;
begin
  perform pg_advisory_xact_lock(hashtext('app.rcv_journal_acks chain'));
  if jsonb_typeof(v_entry -> 'seq') = 'number' and (v_entry ->> 'seq') ~ '^[1-9][0-9]{0,15}$'
     and (v_entry ->> 'seq')::bigint <= ((app.identity_deletion_journal_head()) ->> 'seq')::bigint then
    return jsonb_build_object('data', jsonb_build_object(
      'acked', exists (select 1 from app.rcv_journal_acks a
                        where a.seq = (v_entry ->> 'seq')::bigint
                          and a.entry_hash = v_entry ->> 'hash'),
      'reason', 'already_applied'));
  end if;
  v_reason := app.identity_deletion_chain_problem(v_entry);
  if v_reason is null then
    begin
      perform app.rcv_apply_journal_entry_as(v_entry, 'system:' || p_principal::text);
    exception when sqlstate '22023' then
      v_reason := 'entry_invalid';
    end;
  end if;
  if v_reason is not null then
    return jsonb_build_object('data', jsonb_build_object('acked', false, 'reason', v_reason));
  end if;
  return jsonb_build_object('data', jsonb_build_object('acked', true,
    'seq', (v_entry ->> 'seq')::bigint));
end;
$$;

-- identity.deletion_auth_begin {deletion_id}: the fence before one Auth Admin call. Only when the
-- account step is next and nothing blocks it does the Edge Function get an account id: the first
-- recorded account not yet done.
create function app.identity_sys_deletion_auth_begin(p_principal uuid, p_request uuid,
                                                     p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_del app.identity_deletions;
  v_next app.identity_deletion_steps;
  v_block text;
  v_account app.identity_deletion_accounts;
begin
  v_del := app.identity_deletion_lock((p_payload ->> 'deletion_id')::uuid);
  if v_del.deletion_id is null then
    return jsonb_build_object('data', jsonb_build_object('proceed', false, 'reason', 'not_found'));
  end if;
  v_next := app.identity_deletion_next_step(v_del.deletion_id);
  if v_next.step is distinct from 'auth_account' then
    return jsonb_build_object('data', jsonb_build_object('proceed', false, 'reason', 'not_next'));
  end if;
  v_block := app.identity_deletion_blocker(v_del, 'auth_account');
  if v_block is not null then
    if v_next.step_state <> 'waiting' or v_next.outcome is distinct from v_block then
      perform app.identity_deletion_mark(v_del.deletion_id, 'auth_account', 'waiting', v_block);
      perform app.identity_deletion_audit_add('step_waiting', 'system', null, p_principal,
        p_request, v_del.deletion_id, 'auth_account', v_block);
    end if;
    return jsonb_build_object('data', jsonb_build_object('proceed', false, 'reason', v_block));
  end if;
  select a.* into v_account from app.identity_deletion_accounts a
   where a.deletion_id = v_del.deletion_id and not a.auth_done
   order by a.account_no limit 1 for update;
  if v_account.auth_user_id is null then
    perform app.identity_deletion_mark(v_del.deletion_id, 'auth_account', 'done', 'deleted');
    return jsonb_build_object('data', jsonb_build_object('proceed', false, 'reason', 'not_next'));
  end if;
  update app.identity_deletion_accounts a
     set auth_attempts = a.auth_attempts + 1, auth_outcome = 'dispatched'
   where a.deletion_id = v_del.deletion_id and a.account_no = v_account.account_no;
  perform app.identity_deletion_mark(v_del.deletion_id, 'auth_account', 'pending', 'dispatched',
                                     true);
  -- The account must not be usable meanwhile (idempotent).
  perform app.identity_deletion_ban(v_account.auth_user_id);
  return jsonb_build_object('data', jsonb_build_object('proceed', true,
                                                       'auth_user_id', v_account.auth_user_id));
end;
$$;

-- identity.deletion_auth_complete {deletion_id, auth_result}: the account of the last fence is
-- done only when none of its Auth rows remain, whatever the function claims; otherwise the
-- attempt is recorded and the step is retried. The step is done when every account is.
create function app.identity_sys_deletion_auth_complete(p_principal uuid, p_request uuid,
                                                        p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_del app.identity_deletions;
  v_next app.identity_deletion_steps;
  v_account app.identity_deletion_accounts;
  v_result text := p_payload ->> 'auth_result';
  v_outcome text;
begin
  v_del := app.identity_deletion_lock((p_payload ->> 'deletion_id')::uuid);
  if v_del.deletion_id is null then
    return jsonb_build_object('data', jsonb_build_object('outcome', 'not_found'));
  end if;
  v_next := app.identity_deletion_next_step(v_del.deletion_id);
  if v_next.step is distinct from 'auth_account' then
    return jsonb_build_object('data', jsonb_build_object('outcome',
      case when exists (select 1 from app.identity_deletion_steps s
                         where s.deletion_id = v_del.deletion_id and s.step = 'auth_account'
                           and s.step_state = 'done') then 'done' else 'not_next' end));
  end if;
  select a.* into v_account from app.identity_deletion_accounts a
   where a.deletion_id = v_del.deletion_id and not a.auth_done
   order by a.account_no limit 1 for update;
  if app.identity_deletion_auth_present(v_account.auth_user_id) then
    update app.identity_deletion_accounts a set auth_outcome = 'auth_' || v_result
     where a.deletion_id = v_del.deletion_id and a.account_no = v_account.account_no;
    perform app.identity_deletion_mark(v_del.deletion_id, 'auth_account', 'failed',
                                       'auth_' || v_result);
    perform app.identity_deletion_audit_add('step_failed', 'system', null, p_principal, p_request,
      v_del.deletion_id, 'auth_account', 'auth_' || v_result);
    return jsonb_build_object('data', jsonb_build_object('outcome', 'retry'));
  end if;
  v_outcome := case when v_result = 'deleted' then 'deleted' else 'absent' end;
  update app.identity_deletion_accounts a set auth_done = true, auth_outcome = v_outcome
   where a.deletion_id = v_del.deletion_id and a.account_no = v_account.account_no;
  if exists (select 1 from app.identity_deletion_accounts a
              where a.deletion_id = v_del.deletion_id and not a.auth_done) then
    perform app.identity_deletion_mark(v_del.deletion_id, 'auth_account', 'pending', v_outcome);
  else
    perform app.identity_deletion_mark(v_del.deletion_id, 'auth_account', 'done', v_outcome);
  end if;
  perform app.identity_deletion_audit_add('step_done', 'system', null, p_principal, p_request,
    v_del.deletion_id, 'auth_account', v_outcome);
  return jsonb_build_object('data', jsonb_build_object('outcome', 'done'));
end;
$$;

-- identity.deletion_advance {deletion_id}: runs the next database-local step.
create function app.identity_sys_deletion_advance(p_principal uuid, p_request uuid,
                                                  p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_del app.identity_deletions;
  v_next app.identity_deletion_steps;
  v_block text;
begin
  v_del := app.identity_deletion_lock((p_payload ->> 'deletion_id')::uuid);
  if v_del.deletion_id is null then
    return jsonb_build_object('data', jsonb_build_object('outcome', 'not_found'));
  end if;
  v_next := app.identity_deletion_next_step(v_del.deletion_id);
  if v_next.step is null then
    return jsonb_build_object('data', jsonb_build_object('outcome', 'done'));
  end if;
  if v_next.step not in ('erase_identity', 'erase_owners', 'anonymise', 'verify', 'complete') then
    return jsonb_build_object('data', jsonb_build_object('outcome', 'not_next',
                                                         'step', v_next.step));
  end if;
  v_block := app.identity_deletion_blocker(v_del, v_next.step);
  if v_block is not null then
    if v_next.step_state <> 'waiting' or v_next.outcome is distinct from v_block then
      perform app.identity_deletion_mark(v_del.deletion_id, v_next.step, 'waiting', v_block);
      perform app.identity_deletion_audit_add('step_waiting', 'system', null, p_principal,
        p_request, v_del.deletion_id, v_next.step, v_block);
    end if;
    return jsonb_build_object('data', jsonb_build_object('outcome', 'waiting', 'step', v_next.step,
                                                         'reason', v_block));
  end if;
  return jsonb_build_object('data', app.identity_deletion_run_local(v_del, v_next.step, 'system',
                                                                    p_principal, p_request));
end;
$$;

insert into app.sys_command_kinds (command, purpose, description, payload_check, handler) values
  ('identity.deletion_queue', 'identity_deletion',
   'Story 2.11: the open member deletions and their next action',
   'app.identity_deletion_check_queue(jsonb)',
   'app.identity_sys_deletion_queue(uuid, uuid, jsonb)'),
  ('identity.deletion_next', 'identity_deletion',
   'Story 2.11: the next step of one deletion (with the exact journal entry fields)',
   'app.identity_deletion_check_next(jsonb)',
   'app.identity_sys_deletion_next(uuid, uuid, jsonb)'),
  ('identity.deletion_journal_ack', 'identity_deletion',
   'Story 2.11: acknowledge a journal entry the worker appended to the recovery journal',
   'app.identity_deletion_check_journal_ack(jsonb)',
   'app.identity_sys_deletion_journal_ack(uuid, uuid, jsonb)'),
  ('identity.deletion_journal_catch_up', 'identity_deletion',
   'Story 2.11: acknowledge a journal entry another writer appended after this database''s head',
   'app.identity_deletion_check_journal_catch_up(jsonb)',
   'app.identity_sys_deletion_journal_catch_up(uuid, uuid, jsonb)'),
  ('identity.deletion_auth_begin', 'identity_deletion',
   'Story 2.11: fence before the Auth Admin account deletion',
   'app.identity_deletion_check_auth_begin(jsonb)',
   'app.identity_sys_deletion_auth_begin(uuid, uuid, jsonb)'),
  ('identity.deletion_auth_complete', 'identity_deletion',
   'Story 2.11: record the account deletion once the Auth user is absent',
   'app.identity_deletion_check_auth_complete(jsonb)',
   'app.identity_sys_deletion_auth_complete(uuid, uuid, jsonb)'),
  ('identity.deletion_advance', 'identity_deletion',
   'Story 2.11: run the next database-local deletion step',
   'app.identity_deletion_check_advance(jsonb)',
   'app.identity_sys_deletion_advance(uuid, uuid, jsonb)');

-- ---------------------------------------------------------------------------------------------
-- Restore replay (Identity's replay hook)
-- ---------------------------------------------------------------------------------------------

-- Denies access again on a restored snapshot (sessions were wiped by the restore hold): every
-- live link ends, grants end, the membership is deactivated and every account of the member (all
-- links, recorded accounts) is banned.
create function app.identity_deletion_deny_restored(p_member_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_account uuid;
begin
  update app.identity_account_links l
     set link_state = 'ended', ended_at = coalesce(l.ended_at, clock_timestamp()), updated_at = now()
   where l.member_id = p_member_id and l.link_state <> 'ended';
  update app.identity_grants g set revoked_at = now()
   where g.member_id = p_member_id and g.revoked_at is null;
  update app.identity_members m
     set membership_state = 'deactivated', revision = m.revision + 1, updated_at = now()
   where m.member_id = p_member_id and m.membership_state <> 'deactivated';
  for v_account in
    select l.auth_user_id from app.identity_account_links l where l.member_id = p_member_id
    union
    select a.auth_user_id from app.identity_deletion_accounts a
      join app.identity_deletions d on d.deletion_id = a.deletion_id
     where d.member_id = p_member_id and a.auth_user_id is not null
  loop
    perform app.identity_deletion_ban(v_account);
  end loop;
end;
$$;

-- The deletion of a member on a restored snapshot: the snapshot's own, or one re-created from
-- the journal (the snapshot predates the request) with every account the member ever linked.
create function app.identity_deletion_ensure_replayed(p_member_id uuid)
returns app.identity_deletions
language plpgsql
set search_path = ''
as $$
declare
  v_del app.identity_deletions;
  v_member app.identity_members;
  v_accounts uuid[];
begin
  select d.* into v_del from app.identity_deletions d where d.member_id = p_member_id for update;
  if found then
    perform app.identity_deletion_deny_restored(p_member_id);
    return v_del;
  end if;
  select m.* into v_member from app.identity_members m where m.member_id = p_member_id for update;
  if not found then
    return null;
  end if;
  v_accounts := array(
    select x.auth_user_id from (
      select l.auth_user_id, l.created_at from app.identity_account_links l
       where l.member_id = p_member_id
      union all
      select a.auth_user_id, a.submitted_at from app.identity_membership_applications a
       where a.member_id = p_member_id) x
     group by x.auth_user_id
     order by min(x.created_at), x.auth_user_id);
  perform app.identity_deletion_deny_restored(p_member_id);
  insert into app.identity_deletions (member_id, had_account, origin, is_synthetic)
  values (p_member_id, cardinality(v_accounts) > 0, 'journal_replay', v_member.is_synthetic)
  returning * into v_del;
  insert into app.identity_deletion_accounts (deletion_id, account_no, auth_user_id)
  select v_del.deletion_id, x.n::smallint, x.id from unnest(v_accounts) with ordinality as x (id, n);
  insert into app.identity_deletion_steps (deletion_id, step, ordinal)
  select v_del.deletion_id, s.step, s.ordinal
    from app.identity_deletion_step_plan(v_del.had_account) s;
  perform app.identity_deletion_audit_add('deletion_replayed', 'recovery', null, null, null,
    v_del.deletion_id, null, 'journal_replay');
  return v_del;
end;
$$;

create function app.identity_deletion_mark_journaled(
  p_deletion app.identity_deletions, p_step text, p_entry jsonb
) returns void
language sql
set search_path = ''
as $$
  update app.identity_deletion_steps s
     set step_state = 'done', outcome = 'replayed', journal_seq = (p_entry ->> 'seq')::bigint,
         journal_hash = p_entry ->> 'hash', updated_at = clock_timestamp()
   where s.deletion_id = p_deletion.deletion_id and s.step = p_step and s.step_state <> 'done';
$$;

-- Replay hook (registered with the 1.10 journal): acts only while a restore is held.
--   access_revoked{subject}: a member with a deletion is denied again; any other member gets a
--     security hold for revalidation.
--   deletion_manifest identity-member / auth-user: the workflow (and the account) exists again
--     and access is denied.
--   deletion_completed identity-member: erase, owners, anonymise and verify inline.
--   deletion_completed auth-user: the restored Auth user row is removed and verified absent.
-- Anything left behind raises, so the restore stays held.
create function app.identity_rcv_replay(p_input jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_entry jsonb := p_input -> 'entry';
  v_kind text := p_input -> 'entry' ->> 'kind';
  v_bucket text := p_input -> 'entry' -> 'object' ->> 'bucket';
  v_object uuid := (p_input -> 'entry' -> 'object' ->> 'object_id')::uuid;
  v_subject uuid := (p_input -> 'entry' ->> 'subject')::uuid;
  v_del app.identity_deletions;
  v_left text[];
  v_step text;
  v_no smallint;
  v_account uuid;
begin
  if coalesce((p_input ->> 'restoring')::boolean, false) is not true then
    return '{}'::jsonb;
  end if;
  if v_kind = 'access_revoked' then
    if not exists (select 1 from app.identity_members m where m.member_id = v_subject) then
      return '{}'::jsonb;
    end if;
    if exists (select 1 from app.identity_deletions d where d.member_id = v_subject) then
      v_del := app.identity_deletion_ensure_replayed(v_subject);
      perform app.identity_deletion_mark_journaled(v_del, 'journal_access_revoked', v_entry);
    elsif not exists (select 1 from app.identity_holds h
                       where h.member_id = v_subject and h.released_at is null
                         and h.reason = 'restore_revalidation') then
      insert into app.identity_holds (member_id, hold_kind, reason, placed_by, reason_code)
      values (v_subject, 'security', 'restore_revalidation', 'recovery:journal_replay',
              'security_concern');
    end if;
    return '{}'::jsonb;
  end if;
  if v_kind not in ('deletion_manifest', 'deletion_completed')
     or v_bucket not in ('identity-member', 'auth-user') then
    return '{}'::jsonb;
  end if;

  if v_bucket = 'identity-member' then
    v_del := app.identity_deletion_ensure_replayed(v_object);
    if v_del.deletion_id is null then
      return '{}'::jsonb;  -- the snapshot predates the member: nothing to resurrect
    end if;
    if v_kind = 'deletion_manifest' then
      perform app.identity_deletion_mark_journaled(v_del, 'journal_manifest_member', v_entry);
    else
      perform app.identity_deletion_erase_identity(v_del);
      foreach v_account in array coalesce(nullif(app.identity_deletion_account_ids(v_del.deletion_id),
                                                 '{}'::uuid[]), array[null::uuid]) loop
        if exists (select 1 from jsonb_array_elements(app.identity_call_deletion_hooks(
                     v_del.member_id, v_account, v_del.deletion_id, 'erase')) x
                    where (x.value ->> 'remaining')::integer > 0) then
          raise exception using errcode = '22023', message = 'replay left owner data behind';
        end if;
      end loop;
      perform app.identity_deletion_anonymise(v_del);
      v_left := app.identity_deletion_remaining(v_del, false);
      if cardinality(v_left) > 0 then
        raise exception using errcode = '22023',
          message = 'replay left data behind: ' || array_to_string(v_left, ',');
      end if;
      foreach v_step in array array['erase_identity', 'erase_owners', 'anonymise', 'verify'] loop
        perform app.identity_deletion_mark(v_del.deletion_id, v_step, 'done', 'replayed');
      end loop;
      perform app.identity_deletion_mark_journaled(v_del, 'journal_completed_member', v_entry);
    end if;
  else
    -- auth-user: the deletion that recorded this account, or the subject's deletion (manifest).
    select d.* into v_del from app.identity_deletions d
      join app.identity_deletion_accounts a on a.deletion_id = d.deletion_id
     where a.auth_user_id = v_object
     limit 1;
    if v_del.deletion_id is null and v_subject is not null then
      select d.* into v_del from app.identity_deletions d where d.member_id = v_subject;
    end if;
    if v_del.deletion_id is not null and v_del.deletion_state <> 'completed'
       and not exists (select 1 from app.identity_deletion_accounts a
                        where a.deletion_id = v_del.deletion_id and a.auth_user_id = v_object) then
      insert into app.identity_deletion_accounts (deletion_id, account_no, auth_user_id)
      select v_del.deletion_id, coalesce(max(a.account_no), 0) + 1, v_object
        from app.identity_deletion_accounts a where a.deletion_id = v_del.deletion_id;
      if not v_del.had_account then
        update app.identity_deletions d set had_account = true
         where d.deletion_id = v_del.deletion_id returning * into v_del;
        insert into app.identity_deletion_steps (deletion_id, step, ordinal)
        select v_del.deletion_id, s.step, s.ordinal from app.identity_deletion_step_plan(true) s
        on conflict do nothing;
      end if;
    end if;
    perform app.identity_deletion_ban(v_object);
    select a.account_no into v_no from app.identity_deletion_accounts a
     where a.deletion_id = v_del.deletion_id and a.auth_user_id = v_object;
    if v_kind = 'deletion_manifest' then
      if v_no is not null then
        update app.identity_deletion_accounts a
           set manifest_seq = (v_entry ->> 'seq')::bigint, manifest_hash = v_entry ->> 'hash'
         where a.deletion_id = v_del.deletion_id and a.account_no = v_no;
        if not exists (select 1 from app.identity_deletion_accounts a
                        where a.deletion_id = v_del.deletion_id and a.manifest_seq is null) then
          perform app.identity_deletion_mark_journaled(v_del, 'journal_manifest_account', v_entry);
        end if;
      end if;
      return '{}'::jsonb;
    end if;
    perform app.identity_deletion_purge_auth_user(v_object);
    if app.identity_deletion_auth_present(v_object) then
      raise exception using errcode = '22023', message = 'replay left the Auth user behind';
    end if;
    if v_no is not null then
      update app.identity_deletion_accounts a
         set auth_done = true, auth_outcome = 'replayed',
             completed_seq = (v_entry ->> 'seq')::bigint, completed_hash = v_entry ->> 'hash'
       where a.deletion_id = v_del.deletion_id and a.account_no = v_no;
      if not exists (select 1 from app.identity_deletion_accounts a
                      where a.deletion_id = v_del.deletion_id and not a.auth_done) then
        perform app.identity_deletion_mark(v_del.deletion_id, 'auth_account', 'done', 'replayed');
      end if;
      if not exists (select 1 from app.identity_deletion_accounts a
                      where a.deletion_id = v_del.deletion_id and a.completed_seq is null) then
        perform app.identity_deletion_mark_journaled(v_del, 'journal_completed_account', v_entry);
      end if;
    end if;
  end if;
  if v_del.deletion_id is not null then
    -- Journal steps acknowledged in the snapshot before the restore count as done.
    update app.identity_deletion_steps s
       set step_state = 'done', outcome = 'replayed', updated_at = clock_timestamp()
     where s.deletion_id = v_del.deletion_id and s.step_state <> 'done'
       and ((s.step = 'journal_access_revoked'
             and exists (select 1 from app.rcv_journal_acks a
                          where a.kind = 'access_revoked' and a.subject_id = v_del.member_id))
         or (s.step = 'journal_manifest_member'
             and exists (select 1 from app.rcv_journal_acks a
                          where a.kind = 'deletion_manifest' and a.object_id = v_del.member_id)));
    select d.* into v_del from app.identity_deletions d where d.deletion_id = v_del.deletion_id;
    perform app.identity_deletion_finish(v_del, 'recovery', null, null);
  end if;
  return '{}'::jsonb;
end;
$$;

select app.rcv_register_replay_hook('identity', 'app.identity_rcv_replay(jsonb)'::regprocedure);

-- ---------------------------------------------------------------------------------------------
-- Admin read
-- ---------------------------------------------------------------------------------------------

-- Admin: deletions (newest first) with their steps, and deactivated members who could be
-- deleted on the staff route. No contact, care or finance fields.
create function app.identity_admin_deletions()
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
    'deletions', coalesce((
      select jsonb_agg(app.identity_deletion_json(x.deletion_id)
                       order by x.requested_at desc, x.deletion_id)
        from (select d.deletion_id, d.requested_at from app.identity_deletions d
               order by d.requested_at desc, d.deletion_id limit 200) x), '[]'::jsonb),
    'deactivated', coalesce((
      select jsonb_agg(jsonb_build_object(
                         'member_id', m.member_id,
                         'display_name', m.display_name,
                         'revision', m.revision,
                         'account', app.identity_member_account_label(m.member_id),
                         'own_member', m.member_id = v_actor_member,
                         'is_synthetic', m.is_synthetic)
                       order by m.display_name, m.member_id)
        from (select m.* from app.identity_members m
               where m.membership_state = 'deactivated'
                 and not exists (select 1 from app.identity_deletions d
                                  where d.member_id = m.member_id)
               order by m.display_name, m.member_id limit 200) m), '[]'::jsonb),
    'accepting', app.policy_is_open('identity_deletion_retention'))
    into v_result;
  perform app.identity_record_activity(v_link_id);
  return v_result;
end;
$$;

create function api.identity_admin_deletions()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.identity_admin_deletions();
$$;

comment on function api.identity_admin_deletions() is
  'Story 2.11: Admin-only member deletions with their steps, and deactivated members.';

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.identity_deletion_purge_rows(uuid),
  app.rcv_canonical(jsonb),
  app.rcv_entry_hash(jsonb),
  app.identity_deletion_auth_audit_present(uuid),
  app.identity_deletion_account_ids(uuid),
  app.identity_deletion_journal_head(),
  app.identity_deletion_chain_problem(jsonb),
  app.identity_deletion_redact_receipts(app.identity_deletions),
  app.identity_deletion_check_journal_catch_up(jsonb),
  app.identity_sys_deletion_journal_catch_up(uuid, uuid, jsonb),
  app.identity_deletion_purge_auth_user(uuid),
  app.cells_deletion_purge_rows(uuid),
  app.identity_register_deletion_hook(text, regprocedure),
  app.identity_call_deletion_hooks(uuid, uuid, uuid, text),
  app.cells_erase_member(jsonb),
  app.fixture_erase_member(jsonb),
  app.rcv_register_replay_hook(text, regprocedure),
  app.rcv_apply_journal_entry_as(jsonb, text),
  app.rcv_apply_journal_entry(jsonb, text),
  app.identity_deletion_placeholder(),
  app.identity_deletion_step_plan(boolean),
  app.identity_deletion_audit_add(text, text, uuid, uuid, uuid, uuid, text, text),
  app.identity_deletion_next_step(uuid),
  app.identity_deletion_expected_entry(app.identity_deletions, text),
  app.identity_deletion_blocker(app.identity_deletions, text),
  app.identity_deletion_describe(uuid),
  app.identity_deletion_mark(uuid, text, text, text, boolean),
  app.identity_deletion_ban(uuid),
  app.identity_deletion_auth_present(uuid),
  app.identity_deletion_erase_identity(app.identity_deletions),
  app.identity_deletion_anonymise(app.identity_deletions),
  app.identity_deletion_remaining(app.identity_deletions, boolean),
  app.identity_deletion_finish(app.identity_deletions, text, uuid, uuid),
  app.identity_deletion_run_local(app.identity_deletions, text, text, uuid, uuid),
  app.identity_deletion_open(app.identity_members, uuid, uuid, text, text, text),
  app.identity_deletion_json(uuid),
  app.identity_deletion_outcome(uuid, boolean),
  app.identity_request_my_deletion(uuid, bigint, jsonb),
  app.identity_request_member_deletion(uuid, bigint, jsonb),
  app.identity_deletion_in_scope(uuid, text, uuid),
  app.identity_deletion_command(jsonb),
  api.identity_deletion_command(jsonb),
  app.identity_on_link_deletion_guard(),
  app.identity_restore_membership(uuid, bigint, jsonb),
  app.identity_admin_membership_lifecycle(),
  app.identity_authorize_command(jsonb),
  app.identity_deletion_payload_check(text, jsonb),
  app.identity_deletion_check_queue(jsonb),
  app.identity_deletion_check_next(jsonb),
  app.identity_deletion_check_journal_ack(jsonb),
  app.identity_deletion_check_auth_begin(jsonb),
  app.identity_deletion_check_auth_complete(jsonb),
  app.identity_deletion_check_advance(jsonb),
  app.identity_deletion_lock(uuid),
  app.identity_sys_deletion_queue(uuid, uuid, jsonb),
  app.identity_sys_deletion_next(uuid, uuid, jsonb),
  app.identity_sys_deletion_journal_ack(uuid, uuid, jsonb),
  app.identity_sys_deletion_auth_begin(uuid, uuid, jsonb),
  app.identity_sys_deletion_auth_complete(uuid, uuid, jsonb),
  app.identity_sys_deletion_advance(uuid, uuid, jsonb),
  app.identity_deletion_deny_restored(uuid),
  app.identity_deletion_ensure_replayed(uuid),
  app.identity_deletion_mark_journaled(app.identity_deletions, text, jsonb),
  app.identity_rcv_replay(jsonb),
  app.identity_admin_deletions(),
  api.identity_admin_deletions()
  from public, anon, authenticated, service_role;

-- Re-granted: the revoke list above touches 2.10's definer read entry point.
grant execute on function app.identity_admin_membership_lifecycle() to authenticated;
grant execute on function app.identity_deletion_command(jsonb) to authenticated;
grant execute on function api.identity_deletion_command(jsonb) to authenticated;
grant execute on function app.identity_admin_deletions() to authenticated;
grant execute on function api.identity_admin_deletions() to authenticated;

notify pgrst, 'reload schema';
