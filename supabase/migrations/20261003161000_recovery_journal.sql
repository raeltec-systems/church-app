-- Independent recovery journal and isolated restore hold (story 1.10, AD-14, AD-17, P9).
--
-- The recovery journal itself lives OUTSIDE this database and its rollback lifecycle
-- (tools/recovery/journal.mjs: append-only, hash-chained segments behind an adapter; the owner's
-- restricted Google Drive folder for milestone 1). This migration adds the database side:
--   * app.rcv_recovery_state: `live`, `restored_held` or `reconciled`. A restore lands in
--     `restored_held` (the backup artifact itself calls app.rcv_hold_after_restore, so even a plain
--     `psql -f` of the artifact is held) and restored Auth sessions are deleted. The hold runs only
--     inside a restore session (setting app.restore_in_progress = 'on', set by the artifact and the
--     tool), so a mistaken call on a live database cannot sign everyone out; it does not depend on
--     operator rows in the restored snapshot.
--   * While held, the existing release gates `private_access` and `outbound_sending` read as closed
--     through app.policy_effective / app.policy_is_open (redefined here with the same body plus
--     the hold check), whatever the restored snapshot says they were. Missing state = held.
--   * app.rcv_journal_acks: which journal entries this database has applied (its watermark). A
--     restored snapshot knows only the entries acknowledged before the snapshot; newer entries are
--     replayed by app.rcv_apply_journal_entry. Entries are deny-only (revocation, deletion
--     manifest, deletion checkpoint), so replaying an entry whose original transaction rolled back
--     only denies more. Each entry carries opaque UUIDs, a bucket, kind, seq, times and hashes.
--   * app.rcv_complete_reconciliation clears the hold only when every entry 1..head is applied
--     with matching hashes and every object the journal deleted was verified absent from the
--     restored object store. Absent or incomplete journals are refused by the tool and recorded
--     with app.rcv_record_refusal; the hold stays.
--   * SYNTHETIC rehearsal subject/object tables (rcv_synthetic_*): one subject's access and one
--     stored object, so the rehearsal can prove revocation and deletion replay.
-- Q4 (journal/backup retention) and Q12 (RPO/RTO, backup schedule) stay unresolved gates; no
-- value is set here. Everything is operator-only: no client role can execute or read it.
--
-- Additive only: no DROP/TRUNCATE of schema objects.

insert into app.contract_module_prefixes (prefix, module) values ('rcv_', 'platform');

-- ---------------------------------------------------------------------------------------------
-- Recovery state (singleton) and journal acknowledgements
-- ---------------------------------------------------------------------------------------------
create table app.rcv_recovery_state (
  singleton boolean primary key default true check (singleton),
  state text not null check (state in ('live', 'restored_held', 'reconciled')),
  restore_id uuid,
  backup_id text check (backup_id is null or backup_id ~ '^[A-Za-z0-9._:-]{1,80}$'),
  restored_from_environment text,
  journal_head_seq bigint,
  journal_head_hash text check (journal_head_hash is null or journal_head_hash ~ '^[0-9a-f]{64}$'),
  last_refusal text check (last_refusal is null or last_refusal ~ '^[a-z_]{1,63}$'),
  updated_by text not null,
  updated_at timestamptz not null default now(),
  check ((state = 'live') = (restore_id is null))
);

comment on table app.rcv_recovery_state is
  'AD-14 restore hold. restored_held keeps private_access/outbound_sending closed until journal reconciliation.';

insert into app.rcv_recovery_state (state, updated_by) values ('live', 'migration');

create table app.rcv_journal_acks (
  seq bigint primary key check (seq >= 1),
  kind text not null check (kind in (
    'checkpoint', 'access_revoked', 'deletion_manifest', 'deletion_completed', 'seal')),
  entry_hash text not null check (entry_hash ~ '^[0-9a-f]{64}$'),
  subject_id uuid,
  object_id uuid,
  applied_by text not null,
  applied_at timestamptz not null default now(),
  replayed_restore_id uuid
);

comment on table app.rcv_journal_acks is
  'Journal entries this database has applied; max(seq) is the watermark a restored snapshot carries.';

-- Content-free operator/recovery events.
create table app.rcv_events (
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  environment text not null,
  operator text not null,
  action text not null check (action in (
    'synthetic_created', 'entry_applied', 'entry_already_applied', 'hold_applied',
    'reconciliation_refused', 'reconciliation_completed')),
  restore_id uuid,
  journal_seq bigint,
  reason text check (reason is null or reason ~ '^[a-z_]{1,63}$')
);

-- ---------------------------------------------------------------------------------------------
-- SYNTHETIC rehearsal subject and object (no real data; label enforced)
-- ---------------------------------------------------------------------------------------------
create table app.rcv_synthetic_subjects (
  subject_id uuid primary key,
  label text not null check (label = 'SYNTHETIC'),
  access_revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create table app.rcv_synthetic_objects (
  object_id uuid primary key,
  subject_id uuid not null references app.rcv_synthetic_subjects (subject_id),
  bucket text not null check (bucket ~ '^[a-z0-9][a-z0-9-]{2,62}$'),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  deletion_pending_at timestamptz,
  deleted_at timestamptz,
  verified_absent_restore_id uuid,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------------------------
-- Functions (operator-only)
-- ---------------------------------------------------------------------------------------------
create function app.rcv_require_operator(p_operator text)
returns text
language plpgsql
stable
set search_path = ''
as $$
begin
  if not exists (select 1 from app.ops_operators o where o.operator = p_operator and o.active) then
    raise exception using errcode = '42501', message = 'not an active restricted operator';
  end if;
  return p_operator;
end;
$$;

-- True while a restore is unreconciled (or the state row is missing: fail closed).
create function app.rcv_serving_hold()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((select s.state = 'restored_held' from app.rcv_recovery_state s), true);
$$;

create function app.rcv_recovery_status()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'environment', app.platform_current_environment(),
    'state', coalesce(s.state, 'missing'),
    'serving_hold', app.rcv_serving_hold(),
    'restore_id', s.restore_id,
    'backup_id', s.backup_id,
    'journal_watermark', (select coalesce(max(a.seq), 0) from app.rcv_journal_acks a),
    'journal_head_seq', s.journal_head_seq,
    'last_refusal', s.last_refusal,
    'private_access_open', app.policy_is_open('private_access'),
    'outbound_sending_open', app.policy_is_open('outbound_sending'))
  from (select 1) one
  left join app.rcv_recovery_state s on true;
$$;

create function app.rcv_create_synthetic(
  p_subject_id uuid, p_object_id uuid, p_bucket text, p_sha256 text, p_operator text
) returns void
language plpgsql
set search_path = ''
as $$
begin
  perform app.rcv_require_operator(p_operator);
  if app.platform_current_environment() not in ('local', 'staging') then
    raise exception using errcode = '42501', message = 'synthetic rehearsal data is local/staging only';
  end if;
  insert into app.rcv_synthetic_subjects (subject_id, label) values (p_subject_id, 'SYNTHETIC');
  insert into app.rcv_synthetic_objects (object_id, subject_id, bucket, sha256)
  values (p_object_id, p_subject_id, p_bucket, p_sha256);
  insert into app.rcv_events (environment, operator, action)
  values (app.platform_current_environment(), p_operator, 'synthetic_created');
end;
$$;

-- Applies one journal entry (live path after the journal append, or replay after a restore).
-- Idempotent for the same seq and hash; a different hash for an applied seq is refused.
-- Returns {seq, kind, applied, delete_object: {bucket, object_id} | null}.
create function app.rcv_apply_journal_entry(p_entry jsonb, p_operator text)
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
begin
  perform app.rcv_require_operator(p_operator);
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
    values (app.platform_current_environment(), p_operator, 'entry_already_applied', v_restore, v_seq);
  else
    insert into app.rcv_journal_acks (seq, kind, entry_hash, subject_id, object_id, applied_by, replayed_restore_id)
    values (v_seq, v_kind, v_hash, v_subject, v_object, p_operator, v_restore);
    insert into app.rcv_events (environment, operator, action, restore_id, journal_seq)
    values (app.platform_current_environment(), p_operator, 'entry_applied', v_restore, v_seq);
  end if;

  -- Effects are re-applied every time (deny-only, idempotent): a restored older row is fixed
  -- even when its acknowledgement survived in the snapshot.
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

  return jsonb_build_object(
    'seq', v_seq, 'kind', v_kind, 'applied', not (v_existing.seq is not null),
    'delete_object', case when v_object is null then null
                          else jsonb_build_object('bucket', v_bucket, 'object_id', v_object) end);
end;
$$;

-- Called by the restore artifact itself and by the restore tool, right after the data load.
-- Deletes restored Auth sessions/refresh tokens when the Auth schema is present.
create function app.rcv_hold_after_restore(p_backup_id text, p_operator text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_restore uuid := gen_random_uuid();
begin
  -- Only inside a restore session: the artifact/tool sets app.restore_in_progress = 'on'. The
  -- operator name is attribution only, so a snapshot without operator rows still lands held.
  if coalesce(current_setting('app.restore_in_progress', true), '') <> 'on' then
    raise exception using errcode = '42501',
      message = 'rcv_hold_after_restore runs only in a restore session (app.restore_in_progress)';
  end if;
  if p_operator is null or p_operator !~ '^[a-z][a-z0-9_-]{1,31}$' then
    raise exception using errcode = '22023', message = 'operator name is required';
  end if;
  if p_backup_id is null or p_backup_id !~ '^[A-Za-z0-9._:-]{1,80}$' then
    raise exception using errcode = '22023', message = 'backup id is required';
  end if;
  insert into app.rcv_recovery_state as s (singleton, state, restore_id, backup_id,
                                           restored_from_environment, updated_by)
  values (true, 'restored_held', v_restore, p_backup_id, app.platform_current_environment(), p_operator)
  on conflict (singleton) do update
    set state = 'restored_held', restore_id = v_restore, backup_id = excluded.backup_id,
        restored_from_environment = excluded.restored_from_environment,
        journal_head_seq = null, journal_head_hash = null, last_refusal = null,
        updated_by = excluded.updated_by, updated_at = now();
  if to_regclass('auth.refresh_tokens') is not null then
    execute 'delete from auth.refresh_tokens';
  end if;
  if to_regclass('auth.sessions') is not null then
    execute 'delete from auth.sessions';
  end if;
  insert into app.rcv_events (environment, operator, action, restore_id)
  values (app.platform_current_environment(), p_operator, 'hold_applied', v_restore);
  return v_restore;
end;
$$;

create function app.rcv_record_refusal(p_restore_id uuid, p_reason text, p_operator text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform app.rcv_require_operator(p_operator);
  if p_reason is null or p_reason !~ '^[a-z_]{1,63}$' then
    raise exception using errcode = '22023', message = 'reason must be a code';
  end if;
  update app.rcv_recovery_state s
     set last_refusal = p_reason, updated_by = p_operator, updated_at = now()
   where s.state = 'restored_held' and s.restore_id = p_restore_id;
  if not found then
    raise exception using errcode = '22023', message = 'no held restore with that id';
  end if;
  insert into app.rcv_events (environment, operator, action, restore_id, reason)
  values (app.platform_current_environment(), p_operator, 'reconciliation_refused', p_restore_id, p_reason);
end;
$$;

-- Clears the hold only when entries 1..head are applied with the journal's hashes, the head is
-- the seal, and every object the journal deleted was verified absent in the restored store.
create function app.rcv_complete_reconciliation(
  p_restore_id uuid, p_head_seq bigint, p_head_hash text, p_verified_absent uuid[], p_operator text
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_state app.rcv_recovery_state;
  v_missing uuid[];
begin
  perform app.rcv_require_operator(p_operator);
  select * into v_state from app.rcv_recovery_state s for update;
  if not found or v_state.state <> 'restored_held' or v_state.restore_id is distinct from p_restore_id then
    raise exception using errcode = '22023', message = 'no held restore with that id';
  end if;
  if p_head_seq is null or p_head_seq < 1
     or (select count(*) from app.rcv_journal_acks a where a.seq between 1 and p_head_seq) <> p_head_seq
     or exists (select 1 from app.rcv_journal_acks a where a.seq > p_head_seq) then
    raise exception using errcode = '22023', message = 'journal entries 1..head are not all applied';
  end if;
  if not exists (select 1 from app.rcv_journal_acks a
                  where a.seq = p_head_seq and a.kind = 'seal' and a.entry_hash = p_head_hash) then
    raise exception using errcode = '22023', message = 'head is not the applied seal';
  end if;
  select array_agg(distinct a.object_id) into v_missing
    from app.rcv_journal_acks a
   where a.object_id is not null
     and a.object_id <> all (coalesce(p_verified_absent, '{}'));
  if v_missing is not null then
    raise exception using errcode = '22023', message = 'deleted objects not verified absent';
  end if;
  update app.rcv_synthetic_objects o
     set deleted_at = coalesce(o.deleted_at, now()), verified_absent_restore_id = p_restore_id
   where o.object_id = any (coalesce(p_verified_absent, '{}'));
  update app.rcv_recovery_state s
     set state = 'reconciled', journal_head_seq = p_head_seq, journal_head_hash = p_head_hash,
         last_refusal = null, updated_by = p_operator, updated_at = now();
  insert into app.rcv_events (environment, operator, action, restore_id, journal_seq)
  values (app.platform_current_environment(), p_operator, 'reconciliation_completed', p_restore_id, p_head_seq);
  return app.rcv_recovery_status();
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Release gates honour the restore hold (same body as story 1.5, plus the hold check)
-- ---------------------------------------------------------------------------------------------
create or replace function app.policy_effective(p_gate text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_gate app.policy_gates;
begin
  select * into v_gate from app.policy_gates g where g.gate = p_gate;
  if not found then
    raise exception using errcode = '22023', message = 'unknown policy gate';
  end if;
  -- Story 1.10 (AD-14): an unreconciled restore keeps private serving and sending closed,
  -- whatever approval the restored snapshot carries.
  if p_gate in ('private_access', 'outbound_sending') and app.rcv_serving_hold() then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
    return null;
  end if;
  if v_gate.state = 'approved' then
    return jsonb_build_object('gate', p_gate, 'source', 'approved', 'value', v_gate.approved_value);
  end if;
  if v_gate.fixture_value is not null
     and app.platform_current_environment() in ('local', 'staging') then
    return jsonb_build_object('gate', p_gate, 'source', 'fixture', 'value', v_gate.fixture_value);
  end if;
  perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  return null;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges: nothing here is reachable by client roles
-- ---------------------------------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as fn
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and (p.proname ~ '^rcv_' or p.proname = 'policy_effective')
  loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', r.fn);
  end loop;
  for r in
    select c.oid::regclass as tbl
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'app' and c.relkind = 'r' and c.relname ~ '^rcv_'
  loop
    execute format('alter table %s enable row level security', r.tbl);
    execute format('revoke all on table %s from public, anon, authenticated, service_role', r.tbl);
  end loop;
  for r in
    select c.oid::regclass as seq
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'app' and c.relkind = 'S' and c.relname ~ '^rcv_'
  loop
    execute format('revoke all on sequence %s from public, anon, authenticated, service_role', r.seq);
  end loop;
end;
$$;
