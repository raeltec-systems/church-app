-- Story 4.1 follow-up: the ROW deletions of a full member deletion for Duties.
--
-- Replaces the fail-closed stub of 20261013200000_duties_department_tracer.sql with its body.
-- Kept in its own small file because the hosted connector cannot get approval for a migration
-- containing row deletions; the owner applies this file by hand after 20261013200000. Until it
-- is applied the `erase_owners` deletion step answers `unavailable` and nothing is erased (fail
-- closed). It changes no schema object. Same signature and privileges (re-revoked below).

-- One member's department memberships (current and ended). Returns the number of rows removed.
create or replace function app.duties_deletion_purge_rows(p_member_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_n integer;
begin
  delete from app.duties_department_members dm where dm.member_id = p_member_id;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function app.duties_deletion_purge_rows(uuid)
  from public, anon, authenticated, service_role;
