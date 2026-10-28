-- Require an Admin to have held an active Admin grant for 14 elapsed days before verifying a
-- giving method (story F1). The caller's own grant context is returned by Identity; Content does
-- not read Identity tables. Lusaka dates are display only. ASCII only, no backslashes.

create or replace function app.identity_my_access()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member_id uuid;
  v_link_id uuid;
  v_result jsonb;
  v_admin_tenure jsonb;
begin
  select a.member_id, a.link_id into v_member_id, v_link_id from app.identity_require_access() a;
  v_result := app.identity_member_grants_json(v_member_id);
  select jsonb_build_object(
           'granted_at', app.cmd_utc(g.granted_at),
           'admin_since', to_char(g.granted_at at time zone 'Africa/Lusaka', 'YYYY-MM-DD'),
           'granted_by', coalesce(m.display_name, 'Church office'))
    into v_admin_tenure
    from app.identity_grants g
    left join app.identity_members m on m.member_id = g.granted_by_member
   where g.member_id = v_member_id and g.role = 'admin' and g.revoked_at is null;
  v_result := v_result || jsonb_build_object('admin_tenure', v_admin_tenure);
  perform app.identity_record_activity(v_link_id);
  return v_result;
end;
$$;

comment on function app.identity_my_access() is
  'The signed-in member''s current grants plus only their own active Admin grant context, for the '
  'giving verification tenure notice. admin_tenure includes the UTC grant timestamp, Lusaka '
  'display date, and grantor display name; it is presentation only.';

comment on function api.identity_my_access() is
  'Story 2.3 and F1: the signed-in member''s current roles and scopes and only their own active '
  'Admin grant context, behind the live-access predicate. POST /rest/v1/rpc/identity_my_access '
  'with Content-Profile: api.';

-- A missing or malformed self-read context fails closed. The threshold is 14 full 24-hour days;
-- the Lusaka date is deliberately not used for authorization.
create function app.content_giving_admin_tenure_eligible(p_tenure jsonb)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare
  v_granted_at timestamptz;
  v_admin_since date;
begin
  if jsonb_typeof(p_tenure) is distinct from 'object'
     or jsonb_typeof(p_tenure -> 'granted_at') is distinct from 'string'
     or jsonb_typeof(p_tenure -> 'admin_since') is distinct from 'string'
     or jsonb_typeof(p_tenure -> 'granted_by') is distinct from 'string'
     or nullif(btrim(p_tenure ->> 'granted_at'), '') is null
     or nullif(btrim(p_tenure ->> 'admin_since'), '') is null
     or nullif(btrim(p_tenure ->> 'granted_by'), '') is null
     or (p_tenure ->> 'admin_since') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    return false;
  end if;
  begin
    v_granted_at := (p_tenure ->> 'granted_at')::timestamptz;
    v_admin_since := (p_tenure ->> 'admin_since')::date;
  exception when others then
    return false;
  end;
  return to_char(v_admin_since, 'YYYY-MM-DD') = p_tenure ->> 'admin_since'
     and v_admin_since = (v_granted_at at time zone 'Africa/Lusaka')::date
     and v_granted_at <= now() - interval '14 days';
end;
$$;

comment on function app.content_giving_admin_tenure_eligible(jsonb) is
  'Content F1: fail-closed 14 elapsed-day check for Identity self-read Admin grant context.';

-- Keep the existing verification checks and audit contract. The new check consults the
-- caller-scoped Identity API and refuses before recording verification when context is absent or
-- the active Admin grant is younger than 14 full days.
create or replace function app.content_giving_verify(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_error text;
  v_id uuid;
  v_errors jsonb;
  v_raw jsonb := p_payload -> 'tested_on';
  v_tested date;
  v_how text;
  v_item app.content_items;
  v_draft app.content_giving_revisions;
  v_revision bigint;
  v_admin_tenure jsonb;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'giving_method') a;
  v_errors := app.contract_unknown_keys(p_payload, array['method_id', 'tested_on', 'test_method']);
  select t.error, t.value into v_error, v_id from app.content_giving_id(p_payload) t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('method_id', v_error);
  end if;
  v_error := null;
  if v_raw is null or jsonb_typeof(v_raw) = 'null' then
    v_error := 'required';
  elsif jsonb_typeof(v_raw) <> 'string' or (v_raw #>> '{}') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    v_error := 'invalid';
  else
    begin
      v_tested := (v_raw #>> '{}')::date;
    exception when others then
      v_error := 'invalid';
    end;
    if v_error is null
       and (v_tested > app.content_church_today()
            or v_tested < app.content_church_today() - 90) then
      v_error := 'out_of_range';
    end if;
  end if;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('tested_on', v_error);
  end if;
  select t.error, t.value into v_error, v_how from app.content_free_text(p_payload -> 'test_method', 500, true) t;
  if v_error is null and v_how is null then
    v_error := 'required';
  end if;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('test_method', v_error);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_lock(v_id, 'giving_method', p_expected_revision, 'method_id');
  if v_item.draft_revision_no is null then
    perform app.cmd_fail('validation_failed', '{"method_id": "nothing_to_verify"}');
  end if;
  select r.* into v_draft from app.content_giving_revisions r
   where r.item_id = v_id and r.revision_no = v_item.draft_revision_no
     for update;
  if v_draft.verified_at is not null then
    perform app.cmd_fail('validation_failed', '{"method_id": "already_verified"}');
  end if;
  if v_actor.member_id = any (v_draft.saved_by_members)
     or v_actor.account_id = any (v_draft.saved_by_accounts) then
    perform app.cmd_fail('validation_failed', '{"method_id": "saved_by_you"}');
  end if;
  v_admin_tenure := api.identity_my_access() -> 'admin_tenure';
  if not app.content_giving_admin_tenure_eligible(v_admin_tenure) then
    perform app.cmd_fail('validation_failed', '{"admin_tenure": "not_eligible"}');
  end if;
  -- The test vouches for these details, so it happened on or after the day they were saved.
  if v_tested < (v_draft.saved_at at time zone 'Africa/Lusaka')::date then
    perform app.cmd_fail('validation_failed', '{"tested_on": "before_saved"}');
  end if;
  update app.content_giving_revisions r
     set verified_at = now(),
         verified_by_member = v_actor.member_id,
         verified_by_account = v_actor.account_id,
         tested_on = v_tested,
         test_method = v_how
   where r.item_id = v_id and r.revision_no = v_item.draft_revision_no;
  v_revision := app.content_giving_touch(v_id);
  perform app.content_giving_audit_event('verified', v_actor.member_id, v_actor.account_id,
                                         'content.verify_giving_method', v_id,
                                         v_item.draft_revision_no, null, null, v_revision);
  return app.content_item_outcome(v_id, 'method_id');
end;
$$;

revoke all on function app.content_giving_admin_tenure_eligible(jsonb)
  from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
