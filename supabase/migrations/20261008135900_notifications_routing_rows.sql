-- Story 3.5 follow-up: the ROW deletions of a full member deletion for Notifications and the
-- SYNTHETIC fixture reminder source.
--
-- Replaces the two fail-closed stubs of 20261008135811_notifications_routing.sql with their
-- bodies. Kept in its own small file because the hosted connector cannot get approval for a
-- migration containing row deletions; the owner applies this file by hand after 20261008135811.
-- Until it is applied the `erase_owners` deletion step answers `unavailable` and nothing is
-- erased (fail closed). It changes no schema object. Same signatures and privileges (re-revoked
-- below).

-- One member's notification rows, and every notification row of one of the member's accounts.
-- Order follows the foreign keys: attempts, push jobs and needs, then inbox items (snooze links
-- were cleared by the caller), jobs, schedules, tokens and settings.
create or replace function app.notifications_deletion_purge_rows(p_member_id uuid, p_account_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_total integer := 0;
  v_n integer;
begin
  delete from app.notifications_attempts a
   using app.notifications_jobs j
   where a.job_id = j.job_id and j.recipient_member_id = p_member_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.notifications_push_jobs p
   where p.recipient_member_id = p_member_id or p.account_id = p_account_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.notifications_direct_contact_needs n where n.recipient_member_id = p_member_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.notifications_inbox_items i where i.recipient_member_id = p_member_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.notifications_jobs j where j.recipient_member_id = p_member_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.notifications_schedules s where s.recipient_member_id = p_member_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.notifications_device_tokens t
   where t.member_id = p_member_id or t.account_id = p_account_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.notifications_push_settings s
   where s.member_id = p_member_id or s.account_id = p_account_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  return v_total;
end;
$$;

-- One member's SYNTHETIC fixture reminder sources and contact needs.
create or replace function app.fixture_deletion_purge_rows(p_member_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_total integer := 0;
  v_n integer;
begin
  delete from app.fixture_reminder_contact_needs n where n.member_id = p_member_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.fixture_reminder_sources s where s.member_id = p_member_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  return v_total;
end;
$$;

revoke all on function
  app.notifications_deletion_purge_rows(uuid, uuid),
  app.fixture_deletion_purge_rows(uuid)
  from public, anon, authenticated, service_role;
