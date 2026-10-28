-- Live, interactive staging tests may use the church's real cell labels and venues.
-- Automated fixtures continue to use SYNTHETIC values. Production remains behind Q4.

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

create or replace function app.cells_create_cell(p_actor uuid, p_expected_revision bigint,
                                                 p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_name text;
  v_label text;
  v_area text;
  v_cell uuid;
  v_synthetic boolean;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  if not v_actor.is_admin then
    perform app.cmd_fail('forbidden');
  end if;
  v_errors := app.contract_unknown_keys(p_payload,
                array['name', 'signup_label', 'broad_area', 'listed', 'sort_order']);
  select t.errors, t.value into v_errors, v_name
    from app.cells_text(p_payload, 'name', true, v_errors) t;
  select t.errors, t.value into v_errors, v_label
    from app.cells_text(p_payload, 'signup_label', true, v_errors) t;
  select t.errors, t.value into v_errors, v_area
    from app.cells_text(p_payload, 'broad_area', true, v_errors) t;
  if coalesce(jsonb_typeof(p_payload -> 'listed'), 'boolean') <> 'boolean' then
    v_errors := v_errors || '{"listed": "invalid"}';
  end if;
  if p_payload ? 'sort_order' and not app.contract_integer_in(p_payload -> 'sort_order', 0, 10000) then
    v_errors := v_errors || '{"sort_order": "out_of_range"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  v_synthetic := app.platform_current_environment() in ('local', 'staging')
                 and v_name like 'SYNTHETIC %'
                 and v_label like 'SYNTHETIC %'
                 and v_area like 'SYNTHETIC %';
  insert into app.cells_cells (name, broad_area, is_synthetic, created_by)
  values (v_name, v_area, v_synthetic, 'admin:' || v_actor.member_id::text)
  returning cell_id into v_cell;
  insert into app.cells_signup_options (cell_id, label, broad_area, sort_order, listed, is_synthetic)
  values (v_cell, v_label, v_area, coalesce((p_payload ->> 'sort_order')::numeric::int, 0),
          coalesce((p_payload ->> 'listed')::boolean, true), v_synthetic);
  perform app.cells_audit('cell_created', v_actor.member_id, v_actor.account_id, 'admin',
                          'cells.create_cell', null, v_cell, null, null, null, null, 1);
  return app.cells_cell_outcome(v_cell);
end;
$$;

create or replace function app.cells_update_cell(p_actor uuid, p_expected_revision bigint,
                                                 p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_cell app.cells_cells;
  v_name text;
  v_label text;
  v_area text;
  v_current_label text;
  v_is_synthetic boolean;
  v_revision bigint;
begin
  select a.* into v_actor from app.cells_command_actor(p_actor) a;
  if not v_actor.is_admin then
    perform app.cmd_fail('forbidden');
  end if;
  v_errors := app.contract_unknown_keys(p_payload,
                array['cell_id', 'name', 'signup_label', 'broad_area', 'listed']);
  if app.contract_uuid_error(p_payload -> 'cell_id') is not null then
    v_errors := v_errors || jsonb_build_object('cell_id', app.contract_uuid_error(p_payload -> 'cell_id'));
  end if;
  select t.errors, t.value into v_errors, v_name
    from app.cells_text(p_payload, 'name', false, v_errors) t;
  select t.errors, t.value into v_errors, v_label
    from app.cells_text(p_payload, 'signup_label', false, v_errors) t;
  select t.errors, t.value into v_errors, v_area
    from app.cells_text(p_payload, 'broad_area', false, v_errors) t;
  if coalesce(jsonb_typeof(p_payload -> 'listed'), 'boolean') <> 'boolean' then
    v_errors := v_errors || '{"listed": "invalid"}';
  end if;
  if v_errors = '{}'::jsonb and v_name is null and v_label is null and v_area is null
     and not (p_payload ? 'listed') then
    v_errors := '{"payload": "required"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.cells_require_open();
  select c.* into v_cell from app.cells_cells c
   where c.cell_id = (p_payload ->> 'cell_id')::uuid for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_cell.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_cell.revision);
  end if;
  select o.label into v_current_label from app.cells_signup_options o
   where o.cell_id = v_cell.cell_id for update;
  v_current_label := coalesce(v_current_label, v_cell.name);
  v_is_synthetic := app.platform_current_environment() in ('local', 'staging')
                    and coalesce(v_name, v_cell.name) like 'SYNTHETIC %'
                    and coalesce(v_label, v_current_label) like 'SYNTHETIC %'
                    and coalesce(v_area, v_cell.broad_area) like 'SYNTHETIC %';
  update app.cells_cells c
     set name = coalesce(v_name, c.name), broad_area = coalesce(v_area, c.broad_area),
         is_synthetic = v_is_synthetic, revision = c.revision + 1, updated_at = now()
   where c.cell_id = v_cell.cell_id
  returning c.revision into v_revision;
  if v_name is not null or v_label is not null or v_area is not null or p_payload ? 'listed' then
    insert into app.cells_signup_options (cell_id, label, broad_area, listed, is_synthetic)
    values (v_cell.cell_id, coalesce(v_label, v_current_label),
            coalesce(v_area, v_cell.broad_area),
            coalesce((p_payload ->> 'listed')::boolean, true), v_is_synthetic)
    on conflict (cell_id) do update
      set label = coalesce(v_label, app.cells_signup_options.label),
          broad_area = coalesce(v_area, app.cells_signup_options.broad_area),
          listed = coalesce((p_payload ->> 'listed')::boolean, app.cells_signup_options.listed),
          is_synthetic = v_is_synthetic,
          revision = app.cells_signup_options.revision + 1, updated_at = now();
  end if;
  perform app.cells_audit('cell_updated', v_actor.member_id, v_actor.account_id, 'admin',
                          'cells.update_cell', null, v_cell.cell_id, null, null, null, null, v_revision);
  return app.cells_cell_outcome(v_cell.cell_id);
end;
$$;

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
