-- Story 2.11 follow-up: the ROW deletions of a full member deletion.
--
-- Replaces the three fail-closed stubs of 20261007174952_member_deletion.sql with their bodies.
-- Kept in its own small file because the hosted connector cannot get approval for a migration
-- containing row deletions; the owner applies this file by hand after 20261007174952. Until it
-- is applied the erase steps (and restore replay of a completed deletion) answer `unavailable`
-- and nothing is erased (fail closed); requests and every access denial work without it.
-- It changes no schema object. Same signatures and privileges (re-revoked below).

-- One deletion's Identity personal rows: only rows tied to the member, its recorded accounts or
-- the recorded ids of its records (app.identity_deletion_aggregates, filled just before); never
-- a match on a phone number. Then the receipts of the member's accounts and of the member's
-- records, and the accounts' Auth audit-log entries.
create or replace function app.identity_deletion_purge_rows(p_deletion_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
  v_accounts uuid[];
  v_aggs uuid[];
  v_links uuid[];
  v_total integer := 0;
  v_n integer;
begin
  select d.member_id into v_member from app.identity_deletions d where d.deletion_id = p_deletion_id;
  if v_member is null then
    return 0;
  end if;
  v_accounts := app.identity_deletion_account_ids(p_deletion_id);
  v_aggs := array(select g.aggregate_id from app.identity_deletion_aggregates g
                   where g.deletion_id = p_deletion_id);
  v_links := array(select g.aggregate_id from app.identity_deletion_aggregates g
                    where g.deletion_id = p_deletion_id and g.kind = 'link');

  delete from app.identity_recovery_operations o
   where o.member_id = v_member or o.link_id = any (v_links) or o.grant_id = any (v_aggs);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_recovery_grants g
   where g.member_id = v_member or g.link_id = any (v_links) or g.grant_id = any (v_aggs);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_recovery_requests r
   where r.recovery_request_id = any (v_aggs)
     and not exists (select 1 from app.identity_recovery_grants g
                      where g.recovery_request_id = r.recovery_request_id);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_recovery_cases c
   where c.member_id = v_member or c.link_id = any (v_links) or c.case_id = any (v_aggs);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_credential_changes c
   where c.member_id = v_member or c.link_id = any (v_links) or c.change_id = any (v_aggs);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_recovery_email_proposals p
   where p.member_id = v_member or p.link_id = any (v_links) or p.proposal_id = any (v_aggs);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_credential_events e where e.link_id = any (v_links);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_binding_history h where h.link_id = any (v_links);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_account_links l where l.link_id = any (v_links);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_holds h where h.member_id = v_member;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_contact_routes c where c.member_id = v_member;
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_member_provenance p
   where p.member_id = v_member or p.application_id = any (v_aggs);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_phone_reclaims r
   where r.reclaim_id = any (v_aggs) or r.released_account_id = any (v_accounts);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_application_events e where e.application_id = any (v_aggs);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  delete from app.identity_membership_applications a where a.application_id = any (v_aggs);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  -- Receipts of the member's own accounts, and of the member's records (whoever acted): their
  -- stored outcomes carry names, numbers and addresses.
  delete from app.cmd_receipts r
   where r.actor_id = any (v_accounts)
      or r.aggregate_id = any (v_aggs || array[v_member, p_deletion_id]);
  get diagnostics v_n = row_count; v_total := v_total + v_n;
  if pg_catalog.to_regclass('auth.audit_log_entries') is not null and cardinality(v_accounts) > 0 then
    execute 'delete from auth.audit_log_entries e
              where e.payload ->> ''actor_id'' = any ($1)
                 or e.payload -> ''traits'' ->> ''user_id'' = any ($1)'
      using (select array_agg(x::text) from unnest(v_accounts) x);
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
  app.identity_deletion_purge_rows(uuid),
  app.identity_deletion_purge_auth_user(uuid),
  app.cells_deletion_purge_rows(uuid)
  from public, anon, authenticated, service_role;
