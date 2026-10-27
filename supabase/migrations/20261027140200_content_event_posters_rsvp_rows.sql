-- Story 6.11 follow-up: the ROW deletions of a full member deletion for event RSVPs and organisers.
--
-- Replaces the fail-closed stub app.content_rsvp_purge_rows of
-- 20261027140149_content_event_posters_rsvp.sql with its body. Kept in its own small file because
-- the hosted connector cannot get approval for a migration containing row deletions; the owner
-- applies this file by hand right after that migration. Until it is applied, Content's erase
-- step answers `unavailable` for every member deletion and nothing is erased (fail closed). It
-- changes no schema object. Same signature and privileges (re-revoked below).

-- One member's RSVPs (going, cancelled or released) and organiser rows. Returns the number of rows
-- removed.
create or replace function app.content_rsvp_purge_rows(p_member_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_rsvps integer;
  v_organisers integer;
begin
  delete from app.content_event_rsvps v where v.member_id = p_member_id;
  get diagnostics v_rsvps = row_count;
  delete from app.content_event_organisers o where o.member_id = p_member_id;
  get diagnostics v_organisers = row_count;
  return v_rsvps + v_organisers;
end;
$$;

revoke all on function app.content_rsvp_purge_rows(uuid)
  from public, anon, authenticated, service_role;
