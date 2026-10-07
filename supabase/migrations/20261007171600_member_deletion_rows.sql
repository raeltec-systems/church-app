-- Story 2.11 follow-up: the ROW deletions of a full member deletion.
--
-- Replaces the three fail-closed stubs of 20261007171500_member_deletion.sql with their bodies.
-- Kept in its own small file because the hosted connector cannot get approval for a migration
-- containing row deletions; the owner applies this file by hand after 20261007171500. Until it
-- is applied the erase steps (and restore replay of a completed deletion) answer `unavailable`
-- and nothing is erased (fail closed); requests and every access denial work without it.
-- It changes no schema object. Same signatures and privileges (re-revoked below).

-- One member's Identity personal rows (and those of the member's account), the receipts that
-- mention the member or the account, and the account's Auth audit-log entries.
create or replace function app.identity_deletion_purge_rows(p_member_id uuid, p_auth_user_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_links uuid[];
  v_apps uuid[];
  v_phones text[];
  v_requests uuid[];
  v_total integer := 0;
  v_n integer;
begin
  v_links := array(select l.link_id from app.identity_account_links l
                    where l.member_id = p_member_id or l.auth_user_id = p_auth_user_id);
  v_apps := array(select a.application_id from app.identity_membership_applications a
                   where a.member_id = p_member_id or a.auth_user_id = p_auth_user_id);
  v_phones := array(
    select l.approved_phone from app.identity_account_links l where l.link_id = any (v_links)
    union select h.approved_phone from app.identity_binding_history h where h.link_id = any (v_links)
    union select a.phone_username from app.identity_membership_applications a
           where a.application_id = any (v_apps)
    union select c.new_phone from app.identity_credential_changes c
           where (c.member_id = p_member_id or c.link_id = any (v_links)) and c.new_phone is not null);
  v_requests := array(select g.recovery_request_id from app.identity_recovery_grants g
                       where g.member_id = p_member_id or g.link_id = any (v_links));

  delete from app.identity_recovery_operations o
   where o.member_id = p_member_id or o.link_id = any (v_links);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_recovery_grants g
   where g.member_id = p_member_id or g.link_id = any (v_links);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_recovery_requests r
   where (r.recovery_request_id = any (v_requests) or r.claimed_phone = any (v_phones))
     and not exists (select 1 from app.identity_recovery_grants g
                      where g.recovery_request_id = r.recovery_request_id);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_recovery_cases c
   where c.member_id = p_member_id or c.link_id = any (v_links);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_credential_changes c
   where c.member_id = p_member_id or c.link_id = any (v_links);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_recovery_email_proposals p
   where p.member_id = p_member_id or p.link_id = any (v_links);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_credential_events e where e.link_id = any (v_links);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_binding_history h where h.link_id = any (v_links);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_account_links l where l.link_id = any (v_links);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_holds h where h.member_id = p_member_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_contact_routes c where c.member_id = p_member_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_member_provenance p
   where p.member_id = p_member_id or p.application_id = any (v_apps);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_phone_reclaims r
   where r.released_account_id = p_auth_user_id or r.withdrawn_application_id = any (v_apps)
      or r.phone_username = any (v_phones);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_application_events e where e.application_id = any (v_apps);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_membership_applications a where a.application_id = any (v_apps);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.cmd_receipts r
   where r.actor_id = p_auth_user_id
      or strpos(r.result::text, p_member_id::text) > 0
      or (p_auth_user_id is not null and strpos(r.result::text, p_auth_user_id::text) > 0);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.sys_receipts r
   where strpos(r.result::text, p_member_id::text) > 0
      or (p_auth_user_id is not null and strpos(r.result::text, p_auth_user_id::text) > 0);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  if p_auth_user_id is not null and pg_catalog.to_regclass('auth.audit_log_entries') is not null then
    execute 'delete from auth.audit_log_entries e where e.payload ->> ''actor_id'' = $1'
      using p_auth_user_id::text;
    get diagnostics v_n = row_count; v_total := v_total + v_n;
  end if;
  return v_total;
end;
$$;

-- Restore replay only: the restored Auth user row (identities, sessions and factors cascade).
create or replace function app.identity_deletion_purge_auth_user(p_auth_user_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_n integer := 0;
begin
  if p_auth_user_id is null or not app.rcv_serving_hold() then
    return 0;  -- live databases delete Auth users only through Auth Admin
  end if;
  if pg_catalog.to_regclass('auth.identities') is not null then
    execute 'delete from auth.identities i where i.user_id = $1' using p_auth_user_id;
  end if;
  if pg_catalog.to_regclass('auth.users') is not null then
    execute 'delete from auth.users u where u.id = $1' using p_auth_user_id;
    get diagnostics v_n = row_count;
  end if;
  return v_n;
end;
$$;

-- Cells personal rows of one member (memberships and requests reference each other: one
-- statement).
create or replace function app.cells_deletion_purge_rows(p_member_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_total integer := 0;
  v_n integer;
begin
  with gone as (
    delete from app.cells_memberships m where m.member_id = p_member_id returning 1)
  delete from app.cells_membership_requests r where r.member_id = p_member_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.cells_memberships m where m.member_id = p_member_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.cells_member_states s where s.member_id = p_member_id;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  return v_total;
end;
$$;

revoke all on function
  app.identity_deletion_purge_rows(uuid, uuid),
  app.identity_deletion_purge_auth_user(uuid),
  app.cells_deletion_purge_rows(uuid)
  from public, anon, authenticated, service_role;
