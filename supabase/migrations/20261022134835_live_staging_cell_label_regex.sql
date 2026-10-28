-- Normalize cell validator regexes using ASCII-only SQL source.

create or replace function app.cells_text(p_payload jsonb, p_key text, p_required boolean,
                                          inout errors jsonb, out value text)
language plpgsql
set search_path = ''
as $$
declare
  v jsonb := p_payload -> p_key;
begin
  if v is null or jsonb_typeof(v) = 'null' then
    if p_required then
      errors := errors || jsonb_build_object(p_key, 'required');
    end if;
    return;
  end if;
  if jsonb_typeof(v) <> 'string' then
    errors := errors || jsonb_build_object(p_key, 'invalid');
    return;
  end if;
  value := btrim(regexp_replace(v #>> '{}', '[[:space:]]+', ' ', 'g'));
  if value = '' then
    errors := errors || jsonb_build_object(p_key, 'required');
    value := null;
  elsif length(value) > 80 or value ~ '[[:cntrl:]]'
        or value ~ ('[' || chr(173) || chr(8203) || '-' || chr(8207) || chr(8234) || '-' || chr(8238)
                     || chr(8288) || '-' || chr(8292) || chr(8294) || '-' || chr(8303) || chr(65279) || ']')
        or (app.platform_current_environment() not in ('local', 'staging')
            and not app.policy_is_open('q4_personal_data') and value !~ '^SYNTHETIC ') then
    errors := errors || jsonb_build_object(p_key, 'invalid');
    value := null;
  end if;
end;
$$;

comment on function app.cells_text(jsonb, text, boolean, jsonb) is
  'Cells staff text; local/staging accept interactive labels, production keeps the Q4 synthetic gate.';

create or replace function app.cells_venue(p_payload jsonb, p_key text, p_required boolean,
                                           inout errors jsonb, out value text)
language plpgsql
set search_path = ''
as $$
declare
  v jsonb := p_payload -> p_key;
begin
  if v is null or jsonb_typeof(v) = 'null' then
    if p_required then
      errors := errors || jsonb_build_object(p_key, 'required');
    end if;
    return;
  end if;
  if jsonb_typeof(v) <> 'string' then
    errors := errors || jsonb_build_object(p_key, 'invalid');
    return;
  end if;
  value := btrim(regexp_replace(v #>> '{}', '[[:space:]]+', ' ', 'g'));
  if value = '' then
    errors := errors || jsonb_build_object(p_key, 'required');
    value := null;
  elsif length(value) > 120 or value ~ '[[:cntrl:]]'
        or value ~ ('[' || chr(173) || chr(8203) || '-' || chr(8207) || chr(8234) || '-' || chr(8238)
                     || chr(8288) || '-' || chr(8292) || chr(8294) || '-' || chr(8303) || chr(65279) || ']')
        or (app.platform_current_environment() not in ('local', 'staging')
            and not app.policy_is_open('q4_personal_data') and value !~ '^SYNTHETIC ') then
    errors := errors || jsonb_build_object(p_key, 'invalid');
    value := null;
  end if;
end;
$$;

comment on function app.cells_venue(jsonb, text, boolean, jsonb) is
  'Cell meeting venue; local/staging accept interactive test values, production keeps the Q4 gate.';
