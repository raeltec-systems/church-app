-- Canonicalize the shared name validator source while preserving the staging-only live-name rule.
-- Building Unicode regex members with chr() keeps the function definition identical on local and staging.
create or replace function app.identity_application_name(
  p_value jsonb,
  inout errors jsonb,
  out full_name text
)
language plpgsql
set search_path = ''
as $function$
declare
  c_space constant text := '[' || chr(9) || '-' || chr(13) || chr(32) || chr(133) || chr(160)
    || chr(5760) || chr(8192) || '-' || chr(8202) || chr(8232) || chr(8233) || chr(8239)
    || chr(8287) || chr(12288) || ']+';
  c_format constant text := '[' || chr(1) || '-' || chr(31) || chr(127) || '-' || chr(159)
    || chr(173) || chr(1536) || '-' || chr(1541) || chr(1564) || chr(1757) || chr(1807)
    || chr(2192) || chr(2193) || chr(2274) || chr(6158) || chr(8203) || '-' || chr(8207)
    || chr(8234) || '-' || chr(8238) || chr(8288) || '-' || chr(8292) || chr(8294) || '-'
    || chr(8303) || chr(65279) || chr(65529) || '-' || chr(65531) || chr(69821) || chr(69837)
    || chr(78896) || '-' || chr(78911) || chr(113824) || '-' || chr(113827) || chr(119155)
    || '-' || chr(119162) || chr(917505) || chr(917536) || '-' || chr(917631) || ']';
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    errors := errors || '{"full_name": "required"}';
    return;
  end if;
  if jsonb_typeof(p_value) <> 'string' then
    errors := errors || '{"full_name": "invalid"}';
    return;
  end if;
  full_name := regexp_replace(regexp_replace(p_value #>> '{}', c_space, ' ', 'g'),
                              '^ | $', '', 'g');
  if full_name = '' then
    errors := errors || '{"full_name": "required"}';
    full_name := null;
  elsif length(full_name) > 120 or full_name ~ c_format or full_name ~ '[[:cntrl:]]'
        or (not app.policy_is_open('q4_personal_data')
            and app.platform_current_environment() <> 'staging'
            and full_name !~ '^SYNTHETIC ') then
    errors := errors || '{"full_name": "invalid"}';
    full_name := null;
  end if;
end;
$function$;
