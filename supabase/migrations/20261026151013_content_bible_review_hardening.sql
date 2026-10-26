-- Story 6.6: retain the null response for unknown or incomplete manifests while
-- exposing source-declared verse omissions for registered complete editions.
create or replace function app.content_bible_manifest_json(p_code text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with selected as (
    select app.content_bible_latest_manifest(p_code) as manifest_version
  )
  select case when selected.manifest_version is null then null else
    jsonb_build_object(
      'translation_code', p_code,
      'manifest_version', selected.manifest_version,
      'chapters', coalesce((
        select jsonb_agg(jsonb_build_object(
          'book_id', m.book_id,
          'chapter', c.chapter,
          'verse_count', m.chapter_counts[c.chapter],
          'omitted_verses', to_jsonb(app.content_bible_manifest_omissions(
            m.manifest_version, m.translation_code, m.book_id, c.chapter
          ))
        ) order by b.canonical_order, c.chapter)
          from app.content_bible_manifest m
          join app.content_bible_books b on b.book_id = m.book_id
          cross join lateral generate_subscripts(m.chapter_counts, 1) c(chapter)
         where m.translation_code = p_code
           and m.manifest_version = selected.manifest_version
      ), '[]'::jsonb)
    )
  end
  from selected;
$$;

revoke all on function app.content_bible_manifest_json(text)
  from public, anon, authenticated, service_role;
grant execute on function app.content_bible_manifest_json(text) to anon, authenticated;

-- Publication attribution must participate in the same erase/check contract as
-- draft attribution. No rows or published content are deleted.
create or replace function app.content_bible_erase_part(p_input jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_input ->> 'member_id')::uuid;
  v_account uuid := nullif(p_input ->> 'account_id', '')::uuid;
  v_nil uuid := '00000000-0000-0000-0000-000000000000'::uuid;
begin
  if p_input ->> 'phase' = 'erase' then
    update app.content_bible_revisions r set saved_by_member = v_nil
     where r.saved_by_member = v_member;
    update app.content_bible_revisions r set published_by_member = v_nil
     where r.published_by_member = v_member;
    if v_account is not null then
      update app.content_bible_revisions r set saved_by_account = v_nil
       where r.saved_by_account = v_account;
      update app.content_bible_revisions r set published_by_account = v_nil
       where r.published_by_account = v_account;
    end if;
  end if;
  return (select count(*) from app.content_bible_revisions r
    where r.saved_by_member = v_member or r.published_by_member = v_member
       or r.saved_by_account = v_account or r.published_by_account = v_account)::integer;
end;
$$;

revoke all on function app.content_bible_erase_part(jsonb)
  from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
