-- Staging-only interactive testing may use real sign-in phone numbers.
-- Production still requires Q4 approval before non-demo phone numbers are accepted.
create or replace function app.identity_applicant_phone(p_actor uuid)
returns text
language plpgsql
stable
set search_path = ''
as $function$
declare
  v_phone text;
begin
  select '+' || ltrim(nullif(btrim(u.phone), ''), '+') into v_phone
    from auth.users u where u.id = p_actor;
  if v_phone is null or v_phone !~ '^[+][1-9][0-9]{7,14}$' then
    perform app.cmd_fail('validation_failed', '{"phone_username": "required"}');
  end if;
  if not app.policy_is_open('q4_personal_data')
     and app.platform_current_environment() <> 'staging'
     and v_phone !~ '^[+]120255501[0-9]{2}$'
     and v_phone !~ '^[+]447700900[0-9]{3}$' then
    perform app.cmd_fail('validation_failed', '{"phone_username": "out_of_range"}');
  end if;
  return v_phone;
end;
$function$;
