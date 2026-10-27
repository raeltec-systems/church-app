-- Story 6.8 follow-up: the ROW deletions of a full member deletion for hymn favourites.
--
-- Replaces the fail-closed stub app.content_hymn_favourite_purge_rows of
-- 20261027131500_content_hymn_lists.sql with its body. Kept in its own small file because the
-- hosted connector cannot get approval for a migration containing row deletions; the owner applies
-- this file by hand right after that migration. Until it is applied, Content's erase step answers
-- `unavailable` for every member deletion and nothing is erased (fail closed). It changes no schema
-- object. Same signature and privileges (re-revoked below).

-- One member's favourite hymns (saved and removed). Returns the number of rows removed.
create or replace function app.content_hymn_favourite_purge_rows(p_member_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_n integer;
begin
  delete from app.content_hymn_favourites f where f.member_id = p_member_id;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function app.content_hymn_favourite_purge_rows(uuid)
  from public, anon, authenticated, service_role;
