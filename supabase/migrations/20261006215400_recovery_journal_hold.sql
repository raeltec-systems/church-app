-- Story 1.10, part 2 of the recovery journal: the restore-only hold. Applied to hosted staging
-- by the owner in the SQL editor (2026-10-06) because the connector requires approval for any
-- statement text containing a session delete. Additive only.

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

revoke all on function app.rcv_hold_after_restore(text, text) from public, anon, authenticated, service_role;
