-- Story 2.5 follow-up: the phone-username reclaim also REVOKES the holder's Auth sessions.
--
-- Replaces app.identity_reclaim_phone_username (20261007131500_membership_review.sql) with the
-- same body plus two row deletions: the holder's auth.refresh_tokens and auth.sessions (refresh
-- tokens and AMR claims of a session cascade with it). Kept in its own small file because the
-- hosted connector cannot get approval for a migration containing row deletions; the owner
-- applies this file by hand after 20261007131500. It deletes Auth session ROWS of one account
-- only, inside the Admin command; it changes no schema object.
--
-- Same signature and privileges (re-revoked below); nothing becomes client-executable.

create or replace function app.identity_reclaim_phone_username(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_phone text;
  v_holder uuid;
  v_open app.identity_membership_applications;
  v_reclaim uuid;
  v_request uuid;
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_errors := app.identity_review_errors(
    p_payload, array['phone_username', 'identity_check', 'reason'], true);
  if jsonb_typeof(p_payload -> 'phone_username') is distinct from 'string'
     or p_payload ->> 'phone_username' !~ '^\+[1-9][0-9]{7,14}$' then
    v_errors := v_errors || '{"phone_username": "invalid"}';
  else
    v_phone := p_payload ->> 'phone_username';
  end if;
  if coalesce(jsonb_typeof(p_payload -> 'reason'), 'null') <> 'null'
     and (jsonb_typeof(p_payload -> 'reason') <> 'string'
          or p_payload ->> 'reason' not in ('registered_by_someone_else', 'number_reassigned')) then
    v_errors := v_errors || '{"reason": "invalid"}';
  end if;
  if v_phone is not null and not app.policy_is_open('q4_personal_data')
     and v_phone !~ '^\+120255501[0-9]{2}$' and v_phone !~ '^\+447700900[0-9]{3}$' then
    v_errors := v_errors || '{"phone_username": "out_of_range"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  if not app.identity_applications_open() then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  -- Auth normally stores the phone as digits without '+'; accept either form.
  if (select count(*) from auth.users u
       where u.phone in (ltrim(v_phone, '+'), v_phone)) > 1 then
    perform app.cmd_fail('conflict', '{"phone_username": "ambiguous"}');
  end if;
  select u.id into v_holder from auth.users u
   where u.phone in (ltrim(v_phone, '+'), v_phone)
     for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_holder = v_actor.account_id then
    perform app.cmd_fail('forbidden', '{"phone_username": "unsupported"}');
  end if;
  -- A linked account is a dispute about a member: unlink it explicitly first.
  if exists (select 1 from app.identity_account_links l
              where l.auth_user_id = v_holder and l.link_state <> 'ended') then
    perform app.cmd_fail('conflict', '{"phone_username": "linked"}');
  end if;
  v_request := app.cmd_current_request_id(p_actor, 'identity.reclaim_phone_username');
  insert into app.identity_phone_reclaims (phone_username, released_account_id, identity_check,
                                           reason, actor_member_id, actor_account_id, request_id)
  values (v_phone, v_holder, p_payload ->> 'identity_check', p_payload ->> 'reason',
          v_actor.member_id, v_actor.account_id, v_request)
  returning reclaim_id into v_reclaim;

  select a.* into v_open from app.identity_membership_applications a
   where a.auth_user_id = v_holder and a.application_state in ('submitted', 'needs_details')
     for update;
  if found then
    perform app.identity_decide_application(v_open, 'withdrawn', 'withdrawn', null, null, null,
      v_actor.member_id, v_actor.account_id, 'identity.reclaim_phone_username',
      'application_withdrawn', p_payload ->> 'identity_check', null);
    update app.identity_phone_reclaims r set withdrawn_application_id = v_open.application_id
     where r.reclaim_id = v_reclaim;
  end if;

  -- Release the username: the holder keeps its Auth row (never merged or deleted), loses the
  -- phone, is banned and has every session revoked.
  update auth.users u
     set phone = null, phone_confirmed_at = null,
         banned_until = now() + interval '100 years', updated_at = now()
   where u.id = v_holder;
  -- Revoke every Auth session of the holder now (refresh tokens and AMR claims of a session
  -- cascade with it; refresh tokens are also removed by user, as GoTrue's logout does).
  delete from auth.refresh_tokens t where t.user_id = v_holder::text;
  delete from auth.sessions s where s.user_id = v_holder;

  insert into app.identity_membership_audit (action, actor_member_id, actor_account_id, request_id,
                                             target_account_id, reclaim_id, identity_check,
                                             reason_code, application_id)
  values ('phone_username_reclaimed', v_actor.member_id, v_actor.account_id, v_request, v_holder,
          v_reclaim, p_payload ->> 'identity_check', p_payload ->> 'reason',
          v_open.application_id);
  return jsonb_build_object(
    'aggregate_type', 'identity_phone_reclaim',
    'aggregate_id', v_reclaim,
    'revision', 1,
    'data', jsonb_build_object('reclaim_id', v_reclaim, 'released', true,
                               'application_withdrawn', v_open.application_id is not null));
end;
$$;

revoke all on function app.identity_reclaim_phone_username(uuid, bigint, jsonb)
  from public, anon, authenticated, service_role;
