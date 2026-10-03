-- Recovery journal hold and replay (story 1.10, AD-14, AD-17): a restore lands held, the
-- private_access/outbound_sending release gates stay closed while held (even when the restored
-- snapshot approved them), restored Auth sessions are deleted, journal entries replay
-- idempotently and deny-only, and the hold clears only after entries 1..seal are applied and
-- deleted objects are verified absent. The isolated end-to-end rehearsal (container restore,
-- object store, journal adapters) is tools/recovery/rehearse.mjs. All data is SYNTHETIC.
begin;
select plan(44);

create function pg_temp.h(p_n int) returns text
language sql as $$ select lpad(to_hex(p_n), 64, '0') $$;

create function pg_temp.entry(p_seq int, p_kind text, p_extra jsonb default '{}') returns jsonb
language sql as $$
  select jsonb_build_object('v', 1, 'journal', 'bic-kafue-recovery-SYNTHETIC', 'seq', p_seq,
                            'kind', p_kind, 'at', '2026-10-03T12:00:00Z',
                            'prev_hash', pg_temp.h(p_seq - 1), 'hash', pg_temp.h(p_seq)) || p_extra
$$;

create function pg_temp.err(p_sql text) returns text
language plpgsql as $$
begin
  execute p_sql;
  return 'no error';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end;
$$;

-- Earlier rehearsals (npm run recovery:rehearse) leave synthetic rows; start clean (rolled back).
delete from app.rcv_synthetic_objects;
delete from app.rcv_synthetic_subjects;
delete from app.rcv_journal_acks;

-- Fresh database -----------------------------------------------------------------------------
select is((select state from app.rcv_recovery_state), 'live', 'a migrated database starts live');
select is(app.rcv_serving_hold(), false, 'live: no serving hold');

-- The rehearsal runs on a local database.
select app.platform_set_environment('local', 'recovery-journal-test')
 where app.platform_current_environment() <> 'local';

-- Owner approvals (in this rolled-back test only) make the gates open while live.
select app.policy_approve('private_access', '{"enabled": true}', 'israel', 'TEST ONLY, rolled back');
select app.policy_approve('outbound_sending', '{"enabled": true}', 'israel', 'TEST ONLY, rolled back');
select is(app.policy_is_open('private_access'), true, 'live + approved: private_access open');
select is(app.policy_is_open('outbound_sending'), true, 'live + approved: outbound_sending open');

-- Synthetic subject and object; the live path applies entries 1..2 --------------------------
select app.rcv_create_synthetic('00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-0000000000b1',
  'rcv-synthetic-rehearsal', pg_temp.h(99), 'israel');
select is(pg_temp.err($$select app.rcv_create_synthetic(gen_random_uuid(), gen_random_uuid(),
  'rcv-synthetic-rehearsal', 'x', 'mallory')$$), '42501: not an active restricted operator',
  'only a restricted operator writes recovery data');
select is((select applied from jsonb_to_record(app.rcv_apply_journal_entry(pg_temp.entry(1, 'checkpoint'), 'israel')) as x(applied boolean)),
  true, 'checkpoint applied');
select is(app.rcv_apply_journal_entry(pg_temp.entry(1, 'checkpoint'), 'israel') ->> 'applied', 'false',
  'the same entry again is idempotent');
select is(pg_temp.err($$select app.rcv_apply_journal_entry(pg_temp.entry(1, 'checkpoint') || jsonb_build_object('hash', pg_temp.h(500)), 'israel')$$),
  '22023: journal_mismatch', 'a different hash for an applied seq is refused');
select is(pg_temp.err($$select app.rcv_apply_journal_entry(pg_temp.entry(9, 'checkpoint', '{"name": "Jane"}'), 'israel')$$),
  '22023: journal entry carries a field outside its kind', 'content fields are refused');
select is(pg_temp.err($$select app.rcv_apply_journal_entry(pg_temp.entry(9, 'checkpoint', '{"subject": "00000000-0000-4000-8000-000000000001"}'), 'israel')$$),
  '22023: journal entry carries a field outside its kind', 'a checkpoint carries no subject');
select is(pg_temp.err($$select app.rcv_apply_journal_entry(pg_temp.entry(9, 'access_revoked'), 'israel')$$),
  '22023: journal entry needs a subject', 'a revocation needs its subject');
select is(pg_temp.err($$select app.rcv_apply_journal_entry(pg_temp.entry(9, 'deletion_completed', '{"object": {"bucket": "rcv-synthetic-rehearsal", "object_id": "00000000-0000-4000-8000-0000000000b1", "path": "a/b"}}'), 'israel')$$),
  '22023: journal object must be {bucket, object_id}', 'object references are opaque');
select is(pg_temp.err($$select app.rcv_apply_journal_entry(pg_temp.entry(9, 'erase_everything'), 'israel')$$),
  '22023: malformed journal entry', 'unknown kinds are refused');
select is(pg_temp.err($$select app.rcv_apply_journal_entry(pg_temp.entry(9, 'checkpoint') - 'hash', 'israel')$$),
  '22023: malformed journal entry', 'an entry without a hash is refused');
select is(pg_temp.err($$select app.rcv_apply_journal_entry(jsonb_set(pg_temp.entry(9, 'checkpoint'), '{seq}', '"9"'), 'israel')$$),
  '22023: malformed journal entry', 'seq must be a JSON number');

-- Snapshot point: watermark 1, subject has access, object present.
select is((app.rcv_recovery_status() ->> 'journal_watermark')::int, 1, 'watermark = 1 at the snapshot');

-- Restore: the artifact applies the hold -------------------------------------------------------
insert into auth.users (id) values ('00000000-0000-4000-8000-0000000000aa');
insert into auth.sessions (id, user_id) values ('00000000-0000-4000-8000-0000000000ab', '00000000-0000-4000-8000-0000000000aa');
insert into auth.refresh_tokens (token, user_id, session_id)
values ('SYNTHETIC-refresh', '00000000-0000-4000-8000-0000000000aa', '00000000-0000-4000-8000-0000000000ab');
create temp table t_restore as select app.rcv_hold_after_restore('t1-SYNTHETIC', 'israel') as id;
grant select on t_restore to public;

select is((select state from app.rcv_recovery_state), 'restored_held', 'restore lands held');
select is((select count(*)::int from auth.sessions), 0, 'restored sessions are deleted');
select is((select count(*)::int from auth.refresh_tokens), 0, 'restored refresh tokens are deleted');
select is(app.policy_is_open('private_access'), false, 'held: private_access closed although the snapshot approved it');
select is(app.policy_is_open('outbound_sending'), false, 'held: outbound_sending closed although the snapshot approved it');
select throws_ok($$select app.policy_effective('private_access')$$, 'PCMD1', 'unavailable',
  'held: policy_effective fails with the kernel''s unavailable');
select is(app.policy_is_open('q9_money'), true, 'the hold touches only the release gates (q9 fixture still served locally)');
select is(app.rcv_recovery_status() ->> 'serving_hold', 'true', 'status reports the hold');

-- Absent/incomplete journal: the tool records a refusal and the hold stays.
select app.rcv_record_refusal((select id from t_restore), 'journal_absent', 'israel');
select is(app.rcv_recovery_status() ->> 'last_refusal', 'journal_absent', 'refusal recorded');
select is(app.policy_is_open('private_access'), false, 'after a refusal: still closed');
select is(pg_temp.err($$select app.rcv_record_refusal((select id from t_restore), 'Journal absent!', 'israel')$$),
  '22023: reason must be a code', 'refusal reasons are codes, not text');

-- Completion before replay is refused.
select is(pg_temp.err($$select app.rcv_complete_reconciliation((select id from t_restore), 1, pg_temp.h(1), '{}', 'israel')$$),
  '22023: head is not the applied seal', 'cannot complete without a seal');

-- Replay newer entries 2..5 --------------------------------------------------------------------
select is(app.rcv_apply_journal_entry(pg_temp.entry(2, 'access_revoked', '{"subject": "00000000-0000-4000-8000-000000000001"}'), 'israel') ->> 'applied',
  'true', 'revocation replayed');
select isnt((select access_revoked_at from app.rcv_synthetic_subjects), null, 'the restored subject loses access');
select is(app.rcv_apply_journal_entry(pg_temp.entry(3, 'deletion_manifest',
    '{"subject": "00000000-0000-4000-8000-000000000001", "object": {"bucket": "rcv-synthetic-rehearsal", "object_id": "00000000-0000-4000-8000-0000000000b1"}}'), 'israel') -> 'delete_object',
  '{"bucket": "rcv-synthetic-rehearsal", "object_id": "00000000-0000-4000-8000-0000000000b1"}'::jsonb,
  'a deletion manifest names the object the tool must remove from the restored store');
select app.rcv_apply_journal_entry(pg_temp.entry(4, 'deletion_completed',
  '{"object": {"bucket": "rcv-synthetic-rehearsal", "object_id": "00000000-0000-4000-8000-0000000000b1"}}'), 'israel');
select is(pg_temp.err($$select app.rcv_complete_reconciliation((select id from t_restore), 4, pg_temp.h(4), '{00000000-0000-4000-8000-0000000000b1}', 'israel')$$),
  '22023: head is not the applied seal', 'head must be the seal');
select app.rcv_apply_journal_entry(pg_temp.entry(6, 'checkpoint'), 'israel');
select is(pg_temp.err($$select app.rcv_complete_reconciliation((select id from t_restore), 6, pg_temp.h(6), '{00000000-0000-4000-8000-0000000000b1}', 'israel')$$),
  '22023: journal entries 1..head are not all applied', 'a gap (5 missing) is refused');
delete from app.rcv_journal_acks where seq = 6;
select app.rcv_apply_journal_entry(pg_temp.entry(5, 'seal', '{"head_seq": 4, "cutoff": "2026-10-03T13:00:00Z"}'), 'israel');
select is(pg_temp.err($$select app.rcv_complete_reconciliation((select id from t_restore), 5, pg_temp.h(5), '{}', 'israel')$$),
  '22023: deleted objects not verified absent', 'the deleted object must be verified absent');
select is(pg_temp.err($$select app.rcv_complete_reconciliation(gen_random_uuid(), 5, pg_temp.h(5), '{00000000-0000-4000-8000-0000000000b1}', 'israel')$$),
  '22023: no held restore with that id', 'a different restore id is refused');
select is(pg_temp.err($$select app.rcv_complete_reconciliation((select id from t_restore), 5, pg_temp.h(77), '{00000000-0000-4000-8000-0000000000b1}', 'israel')$$),
  '22023: head is not the applied seal', 'the seal hash must match');
select is(app.policy_is_open('private_access'), false, 'still held before completion');

select is(app.rcv_complete_reconciliation((select id from t_restore), 5, pg_temp.h(5),
  '{00000000-0000-4000-8000-0000000000b1}', 'israel') ->> 'state', 'reconciled', 'reconciliation completes');
select isnt((select deleted_at from app.rcv_synthetic_objects), null, 'the object is recorded deleted');
select is(app.policy_is_open('private_access'), true, 'reconciled: the gate depends only on the owner approval again');

-- Missing state row fails closed.
delete from app.rcv_recovery_state;
select is(app.rcv_serving_hold(), true, 'no recovery state row = held');

-- Privileges -------------------------------------------------------------------------------------
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and (p.proname ~ '^rcv_' or p.proname = 'policy_effective')
      and (has_function_privilege('anon', p.oid, 'execute')
           or has_function_privilege('authenticated', p.oid, 'execute')
           or has_function_privilege('service_role', p.oid, 'execute'))),
  0, 'no client role executes recovery functions or policy_effective');
select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'app' and c.relname ~ '^rcv_' and c.relkind = 'r'
      and (not c.relrowsecurity
           or has_table_privilege('anon', c.oid, 'select')
           or has_table_privilege('authenticated', c.oid, 'select')
           or has_table_privilege('service_role', c.oid, 'select'))),
  0, 'recovery tables have RLS and no client privileges');
select is(
  (select array_agg(column_name::text order by ordinal_position) from information_schema.columns
    where table_schema = 'app' and table_name = 'rcv_events'),
  array['id', 'occurred_at', 'environment', 'operator', 'action', 'restore_id', 'journal_seq', 'reason'],
  'recovery events are content-free');

select * from finish();
rollback;
