-- Story 6.5: clear the Content file-slot row when an existing giving draft removes its logo.
-- owner-approved-cleanup: Epic 6.5 approved clearing the optional provider logo from an open draft.
do $$
declare
  v_definition text;
  v_search constant text := $needle$  if v_new_asset is not null then
    perform app.content_file_attach(v_id, v_no, 'logo', 'giving_logo', v_new_asset, v_new_rights);
  end if;$needle$;
  v_replace constant text := $replacement$  if v_new_asset is not null then
    perform app.content_file_attach(v_id, v_no, 'logo', 'giving_logo', v_new_asset, v_new_rights);
  elsif p_payload ? 'logo_asset_id' or p_payload ? 'logo_rights_id' then
    delete from app.content_revision_files f
     where f.item_id = v_id and f.revision_no = v_no and f.slot = 'logo';
  end if;$replacement$;
begin
  v_definition := pg_get_functiondef('app.content_giving_save(uuid, bigint, jsonb)'::regprocedure);
  if length(v_definition) - length(replace(v_definition, v_search, '')) <> length(v_search) then
    raise exception 'content_giving_save source changed; refusing an unexpected rewrite';
  end if;
  execute replace(v_definition, v_search, v_replace);
end;
$$;
