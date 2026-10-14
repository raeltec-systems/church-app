-- Field error codes are an open, documented vocabulary in wire contract v1 (fix after story 2.8).
--
-- Since story 2.1 the Identity and Cells commands have returned specific field error codes
-- (member_id: last_admin, session: reauthenticate, hold_id: password_reset_required, ...) that
-- were never in the closed list app.contract_field_error_codes(). The clients validated against
-- that list, so they read a well-formed refusal as an unusable answer ("unknown outcome").
--
-- Decision: _bmad-output/initiative-church-app/epic-identity-and-scoped-access/
-- fix-field-error-vocabulary.md. Any lower_snake_case token (^[a-z][a-z0-9_]{0,62}$, the rule of
-- app.contract_token_error) is a valid field error code. The server's output does not change, so
-- this stays contract v1. app.contract_field_error_codes() keeps the core shape-check codes as
-- documentation; clients map codes they do not know to a generic field notice.
--
-- Only the field_errors clause of app.contract_check changes; the rest is the story 1.5 body.

create or replace function app.contract_check(p_kind text, p_value jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v jsonb := coalesce(p_value, 'null'::jsonb);
  e jsonb := '{}'::jsonb;
begin
  if p_kind is null
     or p_kind not in ('member_ref', 'account_ref', 'actor', 'source_ref', 'task_source',
                       'notification_key', 'lifecycle_event', 'instant', 'zoned_local', 'money',
                       'command_request', 'command_response') then
    raise exception using errcode = '22023', message = 'unknown contract kind';
  end if;

  if p_kind = 'instant' then
    e := jsonb_strip_nulls(jsonb_build_object('$', app.contract_instant_error(v)));
    return jsonb_build_object('valid', e = '{}'::jsonb, 'field_errors', e);
  end if;

  if jsonb_typeof(v) <> 'object' then
    e := jsonb_build_object(case when p_kind = 'command_request' then 'envelope' else '$' end,
                            'must_be_object');
    return jsonb_build_object('valid', false, 'field_errors', e);
  end if;

  case p_kind
  when 'member_ref' then
    e := jsonb_build_object('member_id', app.contract_uuid_error(v -> 'member_id'))
         || app.contract_unknown_keys(v, array['member_id']);

  when 'account_ref' then
    e := jsonb_build_object('auth_user_id', app.contract_uuid_error(v -> 'auth_user_id'))
         || app.contract_unknown_keys(v, array['auth_user_id']);

  when 'actor' then
    if coalesce(jsonb_typeof(v -> 'kind'), 'null') = 'null' then
      e := '{"kind": "required"}';
    elsif (v -> 'kind') = '"member"'::jsonb then
      e := jsonb_build_object(
             'member_id', app.contract_uuid_error(v -> 'member_id'),
             'auth_user_id', app.contract_uuid_error(v -> 'auth_user_id'))
           || app.contract_unknown_keys(v, array['kind', 'member_id', 'auth_user_id']);
    elsif (v -> 'kind') = '"system"'::jsonb then
      e := jsonb_build_object(
             'system_principal_id', app.contract_uuid_error(v -> 'system_principal_id'),
             'job_id', app.contract_uuid_error(v -> 'job_id'),
             'initiating_member_id', app.contract_uuid_error(v -> 'initiating_member_id', true))
           || app.contract_unknown_keys(
                v, array['kind', 'system_principal_id', 'job_id', 'initiating_member_id']);
    else
      e := '{"kind": "invalid"}';
    end if;

  when 'source_ref' then
    e := jsonb_build_object(
           'source_type', app.contract_token_error(v -> 'source_type'),
           'source_id', app.contract_uuid_error(v -> 'source_id'),
           'source_revision', app.contract_revision_error(v -> 'source_revision'))
         || app.contract_unknown_keys(v, array['source_type', 'source_id', 'source_revision']);

  when 'task_source' then
    e := jsonb_build_object(
           'source_type', app.contract_token_error(v -> 'source_type'),
           'source_id', app.contract_uuid_error(v -> 'source_id'),
           'purpose', app.contract_token_error(v -> 'purpose'))
         || app.contract_unknown_keys(v, array['source_type', 'source_id', 'purpose']);

  when 'notification_key' then
    e := jsonb_build_object(
           'source_type', app.contract_token_error(v -> 'source_type'),
           'source_id', app.contract_uuid_error(v -> 'source_id'),
           'source_revision', app.contract_revision_error(v -> 'source_revision'),
           'recipient_member_id', app.contract_uuid_error(v -> 'recipient_member_id'),
           'reminder_kind', app.contract_token_error(v -> 'reminder_kind'),
           'scheduled_at', app.contract_instant_error(v -> 'scheduled_at'))
         || app.contract_unknown_keys(v, array['source_type', 'source_id', 'source_revision',
                                               'recipient_member_id', 'reminder_kind',
                                               'scheduled_at']);

  when 'lifecycle_event' then
    e := jsonb_build_object(
           'event', case
                      when coalesce(jsonb_typeof(v -> 'event'), 'null') = 'null' then 'required'
                      when jsonb_typeof(v -> 'event') = 'string'
                           and exists (select 1 from app.contract_lifecycle_events le
                                        where le.event = v ->> 'event') then null
                      else 'invalid'
                    end,
           'member_id', app.contract_uuid_error(v -> 'member_id'),
           'occurred_at', app.contract_instant_error(v -> 'occurred_at'),
           'identity_revision', app.contract_revision_error(v -> 'identity_revision'))
         || app.contract_unknown_keys(v, array['event', 'member_id', 'occurred_at',
                                               'identity_revision']);

  when 'zoned_local' then
    e := jsonb_build_object(
           'local', app.contract_local_error(v -> 'local'),
           'zone', app.contract_zone_error(v -> 'zone'))
         || app.contract_unknown_keys(v, array['local', 'zone']);

  when 'money' then
    e := jsonb_build_object(
           'amount', app.contract_amount_error(v -> 'amount'),
           'currency', app.contract_currency_error(v -> 'currency'))
         || app.contract_unknown_keys(v, array['amount', 'currency']);

  when 'command_request' then
    -- Authoritative envelope shape; app.cmd_execute calls this and adds only the per-command
    -- checks (allowlisted command -> unsupported, expected_revision required/must_be_null).
    e := jsonb_build_object(
           'version', case
                        when coalesce(jsonb_typeof(v -> 'version'), 'null') = 'null' then 'required'
                        when app.contract_integer_in(v -> 'version', 1, 1) then null
                        else 'unsupported'
                      end,
           'command', case
                        when coalesce(jsonb_typeof(v -> 'command'), 'null') = 'null' then 'required'
                        when jsonb_typeof(v -> 'command') = 'string'
                             and length(v ->> 'command') <= 127
                             and (v ->> 'command') ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$' then null
                        else 'invalid'
                      end,
           'request_id', app.contract_uuid_error(v -> 'request_id'),
           'expected_revision', app.contract_revision_error(v -> 'expected_revision', true),
           'payload', case when jsonb_typeof(v -> 'payload') = 'object' then null
                           else 'must_be_object' end)
         || app.contract_unknown_keys(
              v, array['version', 'command', 'request_id', 'expected_revision', 'payload']);

  when 'command_response' then
    if v ? 'code' then
      e := jsonb_build_object(
             'request_id', case when v ? 'request_id'
                                then app.contract_uuid_error(v -> 'request_id', true)
                                else 'required' end,
             'code', case
                       when coalesce(jsonb_typeof(v -> 'code'), 'null') = 'null' then 'required'
                       when jsonb_typeof(v -> 'code') = 'string'
                            and (v ->> 'code') = any (app.contract_error_codes()) then null
                       else 'invalid'
                     end,
             'message', case
                          when coalesce(jsonb_typeof(v -> 'message'), 'null') = 'null' then 'required'
                          when jsonb_typeof(v -> 'message') = 'string' then null
                          else 'invalid'
                        end,
             'field_errors', case
                               when coalesce(jsonb_typeof(v -> 'field_errors'), 'null') = 'null'
                                 then 'required'
                               when jsonb_typeof(v -> 'field_errors') = 'object'
                                    and not exists (
                                      select 1 from jsonb_each(v -> 'field_errors') f
                                       where jsonb_typeof(f.value) <> 'string'
                                          or app.contract_token_error(f.value) is not null)
                                 then null
                               else 'invalid'
                             end,
             'current_revision', app.contract_revision_error(v -> 'current_revision', true))
           || app.contract_unknown_keys(
                v, array['request_id', 'code', 'message', 'field_errors', 'current_revision']);
    else
      e := jsonb_build_object(
             'request_id', app.contract_uuid_error(v -> 'request_id'),
             'data', case when v ? 'data' then null else 'required' end,
             'revision', app.contract_revision_error(v -> 'revision'))
           || app.contract_unknown_keys(v, array['request_id', 'data', 'revision']);
    end if;
  end case;

  e := jsonb_strip_nulls(e);
  return jsonb_build_object('valid', e = '{}'::jsonb, 'field_errors', e);
end;
$$;

comment on function app.contract_check(text, jsonb) is
  'Wire contract v1 shape authority; packages/contracts/fixtures/v1 is its shared test set.';


comment on function app.contract_field_error_codes() is
  'Core field error codes of the v1 shape checks. Not exhaustive: v1 field error codes are an '
  'open lower_snake_case vocabulary (app.contract_token_error); commands add specific codes.';
