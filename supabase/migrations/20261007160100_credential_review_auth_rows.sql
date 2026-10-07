-- Story 2.8 follow-up: the Auth ROW deletions of the credential review.
--
-- Replaces the two fail-closed stubs of 20261007111436_credential_review.sql with their bodies:
--   * app.identity_revoke_auth_sessions(account): the account's auth.refresh_tokens and
--     auth.sessions (refresh tokens and AMR claims of a session cascade with it), as GoTrue's
--     global logout does. Used by an approved credential change, a lost-device hold, and the
--     restore/accept credential review.
--   * app.identity_remove_auth_extras(account, keep_email): the account's MFA factors, its
--     identities of providers other than phone/email, and email identities of any address other
--     than the approved one. Used by the restore credential review only.
-- Kept in its own small file because the hosted connector cannot get approval for a migration
-- containing row deletions; the owner applies this file by hand after 20261007111436. Until it
-- is applied every command that needs these helpers answers `unavailable` (fail closed). It
-- deletes Auth rows of ONE account only, inside an Admin command; it changes no schema object.
--
-- Same signatures and privileges (re-revoked below); nothing becomes client-executable.

create or replace function app.identity_revoke_auth_sessions(p_auth_user_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_count integer;
begin
  delete from auth.refresh_tokens t where t.user_id = p_auth_user_id::text;
  delete from auth.sessions s where s.user_id = p_auth_user_id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function app.identity_remove_auth_extras(p_auth_user_id uuid, p_keep_email text)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_factors integer;
  v_identities integer;
begin
  delete from auth.mfa_factors f where f.user_id = p_auth_user_id;
  get diagnostics v_factors = row_count;
  delete from auth.identities i
   where i.user_id = p_auth_user_id
     and (i.provider not in ('phone', 'email')
          or (i.provider = 'email'
              and lower(coalesce(i.identity_data ->> 'email', ''))
                  is distinct from coalesce(p_keep_email, '')));
  get diagnostics v_identities = row_count;
  return v_factors + v_identities;
end;
$$;

revoke all on function
  app.identity_revoke_auth_sessions(uuid),
  app.identity_remove_auth_extras(uuid, text)
  from public, anon, authenticated, service_role;
