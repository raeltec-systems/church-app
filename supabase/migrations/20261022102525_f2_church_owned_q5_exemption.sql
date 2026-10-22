-- Story F2: church-owned rights do not need Q5 source approval.
-- Keep lifecycle and per-use checks in the registered rights helper; Q5 remains
-- required for every other rights basis.
create or replace function app.content_rights_clear(p_rights_id uuid, p_use text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_item app.content_items;
  v_rev app.content_rights_revisions;
begin
  if p_rights_id is null then
    return 'required';
  end if;
  select i.* into v_item from app.content_items i where i.item_id = p_rights_id and i.kind = 'rights';
  if not found then
    return 'unknown';
  end if;
  if v_item.lifecycle_state <> 'published' then
    return 'not_in_force';
  end if;
  select r.* into v_rev from app.content_rights_revisions r
   where r.item_id = p_rights_id and r.revision_no = v_item.live_revision_no;
  if not coalesce(case p_use when 'display' then v_rev.clears_display
                             when 'offline' then v_rev.clears_offline
                             when 'audio' then v_rev.clears_audio end, false) then
    return 'use_not_cleared';
  end if;
  if v_rev.basis is distinct from 'church_owned'
     and not (p_use = any (app.content_q5_uses(v_rev.source_key))) then
    return 'source_not_cleared';
  end if;
  return null;
end;
$$;

comment on function app.content_rights_clear(uuid, text) is
  'Story F2 rights check: null when the record is in force and clears the requested use; '
  'church-owned records do not need Q5 source approval, while every other basis requires the '
  'source listed in the effective q5_content_rights value.';
