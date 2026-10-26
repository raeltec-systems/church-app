-- Preserve the official WEB source's numbered omissions without inventing verse text.

alter table app.content_bible_manifest
  add column chapter_omissions jsonb not null default '{}'::jsonb
  check (jsonb_typeof(chapter_omissions) = 'object');

-- Manifest v1 remains immutable. Version 2 adds only the five omitted WEB slots.
insert into app.content_bible_manifest(
  manifest_version, translation_code, book_id, chapter_counts, chapter_omissions
)
select 2, 'WEB', m.book_id, m.chapter_counts,
  case m.book_id
    when 'LUK' then '{"17":[36]}'::jsonb
    when 'ACT' then '{"8":[37],"15":[34],"24":[7]}'::jsonb
    when 'ROM' then '{"16":[25]}'::jsonb
    else '{}'::jsonb
  end
from app.content_bible_manifest m
where m.manifest_version = 1 and m.translation_code = 'WEB';

create or replace function app.content_bible_manifest_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_chapters integer;
  v_row record;
  v_verse integer;
begin
  if tg_op = 'DELETE' then
    raise exception using errcode = 'PCNT1', message = 'Bible verse manifests are immutable';
  end if;
  select b.chapter_count into v_chapters
    from app.content_bible_books b where b.book_id = new.book_id;
  if v_chapters is null
     or array_length(new.chapter_counts, 1) is distinct from v_chapters
     or array_lower(new.chapter_counts, 1) is distinct from 1
     or exists(select 1 from unnest(new.chapter_counts) n
               where n is null or n < 1 or n > 200)
     or jsonb_typeof(new.chapter_omissions) is distinct from 'object' then
    raise exception using errcode = 'PCNT1', message = 'invalid Bible verse manifest';
  end if;
  for v_row in select key, value from jsonb_each(new.chapter_omissions) loop
    if v_row.key !~ '^[1-9][0-9]{0,2}$'
       or jsonb_typeof(v_row.value) is distinct from 'array' then
      raise exception using errcode = 'PCNT1', message = 'invalid Bible verse omissions';
    end if;
    v_chapters := v_row.key::integer;
    if v_chapters > array_length(new.chapter_counts, 1) then
      raise exception using errcode = 'PCNT1', message = 'invalid Bible verse omissions';
    end if;
    for v_verse in
      select value::integer from jsonb_array_elements_text(v_row.value)
    loop
      if v_verse < 1 or v_verse > new.chapter_counts[v_chapters]
         or (v_row.value @> jsonb_build_array(v_verse)
             and (select count(*) from jsonb_array_elements_text(v_row.value) x
                  where x.value::integer = v_verse) > 1) then
        raise exception using errcode = 'PCNT1', message = 'invalid Bible verse omissions';
      end if;
    end loop;
  end loop;
  if tg_op = 'UPDATE'
     and (old.manifest_version, old.translation_code, old.book_id,
          old.chapter_counts, old.chapter_omissions)
         is distinct from
         (new.manifest_version, new.translation_code, new.book_id,
          new.chapter_counts, new.chapter_omissions) then
    raise exception using errcode = 'PCNT1', message = 'Bible verse manifests are immutable';
  end if;
  return new;
end;
$$;

create function app.content_bible_manifest_omissions(
  p_version integer, p_code text, p_book text, p_chapter integer
)
returns smallint[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(v.value::smallint order by v.value::smallint), '{}'::smallint[])
    from app.content_bible_manifest m
    cross join lateral jsonb_array_elements_text(
      coalesce(m.chapter_omissions -> p_chapter::text, '[]'::jsonb)
    ) v(value)
   where m.manifest_version = p_version and m.translation_code = p_code
     and m.book_id = p_book;
$$;

create or replace function app.content_bible_manifest_complete(p_version integer, p_code text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select count(m.book_id) = 66
     and bool_and(array_lower(m.chapter_counts, 1) = 1
       and array_length(m.chapter_counts, 1) = b.chapter_count
       and not exists (select 1 from unnest(m.chapter_counts) n
                        where n is null or n < 1 or n > 200)
       and jsonb_typeof(m.chapter_omissions) = 'object')
    from app.content_bible_books b
    left join app.content_bible_manifest m on m.book_id = b.book_id
      and m.manifest_version = p_version and m.translation_code = p_code;
$$;

create or replace function app.content_bible_verse_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_item uuid;
  v_revision integer;
  v_manifest integer;
  v_code text;
  v_omitted boolean;
begin
  if tg_op = 'DELETE' then
    v_item := old.item_id;
    v_revision := old.revision_no;
  else
    v_item := new.item_id;
    v_revision := new.revision_no;
  end if;
  if exists(select 1 from app.content_bible_revisions r
             where r.item_id = v_item and r.revision_no = v_revision
               and r.published_at is not null) then
    raise exception using errcode = 'PCNT1', message = 'a published Bible revision is immutable';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  select r.manifest_version, r.translation_code
    into v_manifest, v_code
    from app.content_bible_revisions r
   where r.item_id = new.item_id and r.revision_no = new.revision_no;
  v_omitted := new.verse = any(app.content_bible_manifest_omissions(
    v_manifest, v_code, new.book_id, new.chapter
  ));
  if (new.text = '') is distinct from coalesce(v_omitted, false) then
    raise exception using errcode = 'PCNT1', message = 'blank text must match a trusted omitted verse';
  end if;
  return new;
end;
$$;

-- owner-approved-cleanup: 2026-10-23 owner selected WEB for staging; preserve its source-declared omitted slots.
alter table app.content_bible_verses
  drop constraint content_bible_verses_text_check;
alter table app.content_bible_verses
  add constraint content_bible_verses_text_check
  check (length(text) between 0 and 4000 and (text = '' or text ~ '[^[:space:]]'));

create or replace function app.content_bible_import_verses(
  p_actor uuid, p_expected_revision bigint, p_payload jsonb
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_error text;
  v_id uuid;
  v_revision integer;
  v_item app.content_items;
  v_rev app.content_bible_revisions;
  v_row jsonb;
  v_book text;
  v_chapter integer;
  v_verse integer;
  v_len integer;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'bible_translation') a;
  v_errors := app.contract_unknown_keys(p_payload, array['translation_id','revision_no','rows']);
  v_error := app.contract_uuid_error(p_payload -> 'translation_id');
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('translation_id', v_error);
  else
    v_id := (p_payload ->> 'translation_id')::uuid;
  end if;
  if coalesce(p_payload ->> 'revision_no', '') !~ '^[1-9][0-9]{0,8}$' then
    v_errors := v_errors || jsonb_build_object('revision_no', 'invalid');
  else
    v_revision := (p_payload ->> 'revision_no')::integer;
  end if;
  if jsonb_typeof(p_payload -> 'rows') is distinct from 'array' then
    v_errors := v_errors || jsonb_build_object('rows', 'required');
  else
    v_len := jsonb_array_length(p_payload -> 'rows');
    if v_len < 1 or v_len > 200 then
      v_errors := v_errors || jsonb_build_object('rows', 'batch_size');
    end if;
  end if;
  if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed', v_errors); end if;
  v_item := app.content_item_lock(v_id, 'bible_translation', p_expected_revision, 'translation_id');
  if v_item.draft_revision_no is distinct from v_revision then
    perform app.cmd_fail('conflict', null, v_item.revision);
  end if;
  select r.* into v_rev from app.content_bible_revisions r
   where r.item_id = v_id and r.revision_no = v_revision for update;
  if not found or v_rev.complete_at is not null then
    perform app.cmd_fail('validation_failed', jsonb_build_object('revision_no', 'not_open'));
  end if;
  for v_row in select value from jsonb_array_elements(p_payload -> 'rows') loop
    if jsonb_typeof(v_row) is distinct from 'object'
       or app.contract_unknown_keys(v_row, array['book_id','chapter','verse','text']) <> '{}'::jsonb
       or coalesce(v_row ->> 'book_id', '') !~ '^[A-Z0-9]{3}$'
       or coalesce(v_row ->> 'chapter', '') !~ '^[1-9][0-9]{0,2}$'
       or coalesce(v_row ->> 'verse', '') !~ '^[1-9][0-9]{0,2}$'
       or jsonb_typeof(v_row -> 'text') is distinct from 'string'
       or length(trim(coalesce(v_row ->> 'text', ''))) not between 0 and 4000 then
      perform app.cmd_fail('validation_failed', jsonb_build_object('rows', 'invalid_row'));
    end if;
  end loop;
  for v_row in select value from jsonb_array_elements(p_payload -> 'rows') loop
    v_book := v_row ->> 'book_id';
    v_chapter := (v_row ->> 'chapter')::integer;
    v_verse := (v_row ->> 'verse')::integer;
    if app.content_bible_manifest_count(v_rev.manifest_version, v_rev.translation_code,
                                         v_book, v_chapter) is null
       or v_verse > app.content_bible_manifest_count(v_rev.manifest_version,
         v_rev.translation_code, v_book, v_chapter) then
      perform app.cmd_fail('validation_failed', jsonb_build_object('rows', 'outside_manifest'));
    end if;
    if (trim(v_row ->> 'text') = '') is distinct from
       (v_verse = any(app.content_bible_manifest_omissions(
         v_rev.manifest_version, v_rev.translation_code, v_book, v_chapter
       ))) then
      perform app.cmd_fail('validation_failed', jsonb_build_object('rows', 'invalid_omitted_verse'));
    end if;
    if exists(select 1 from app.content_bible_verses x where x.item_id = v_id
      and x.revision_no = v_revision and x.book_id = v_book
      and x.chapter = v_chapter and x.verse = v_verse)
       or (select count(*) from jsonb_array_elements(p_payload -> 'rows') q
           where q.value ->> 'book_id' = v_book
             and (q.value ->> 'chapter')::integer = v_chapter
             and (q.value ->> 'verse')::integer = v_verse) > 1 then
      perform app.cmd_fail('validation_failed', jsonb_build_object('rows', 'duplicate_verse'));
    end if;
  end loop;
  insert into app.content_bible_verses(item_id, revision_no, book_id, chapter, verse, text)
  select v_id, v_revision, r.value ->> 'book_id', (r.value ->> 'chapter')::smallint,
         (r.value ->> 'verse')::smallint, trim(r.value ->> 'text')
    from jsonb_array_elements(p_payload -> 'rows') r;
  update app.content_bible_revisions set saved_by_member = v_actor.member_id,
    saved_by_account = v_actor.account_id, saved_at = now()
   where item_id = v_id and revision_no = v_revision;
  perform app.content_item_saved(v_item, v_revision, v_actor.member_id, v_actor.account_id,
    v_actor.capacity, 'content.import_bible_verses');
  return app.content_item_outcome(v_id, 'translation_id');
end;
$$;

create or replace function app.content_public_bible_chapter(
  p_translation_id uuid, p_book_id text, p_chapter integer
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('chapter', (
    select jsonb_build_object(
      'translation_id', i.item_id,
      'translation_code', r.translation_code,
      'translation_name', r.name,
      'book_id', p_book_id,
      'chapter', p_chapter,
      'verse_count', app.content_bible_manifest_count(
        r.manifest_version, r.translation_code, p_book_id, p_chapter
      ),
      'omitted_verses', to_jsonb(app.content_bible_manifest_omissions(
        r.manifest_version, r.translation_code, p_book_id, p_chapter
      )),
      'verses', (select jsonb_agg(jsonb_build_object('verse', v.verse, 'text', v.text)
                                   order by v.verse)
                   from app.content_bible_verses v
                  where v.item_id = i.item_id and v.revision_no = r.revision_no
                    and v.book_id = p_book_id and v.chapter = p_chapter and v.text <> ''),
      'publication_revision', r.revision_no,
      'published_at', app.cmd_utc(i.published_at),
      'offline_allowed', app.content_rights_clear(r.rights_id, 'offline') is null
    )
      from app.content_items i
      join app.content_bible_revisions r on r.item_id = i.item_id
        and r.revision_no = i.live_revision_no
     where i.item_id = p_translation_id and i.kind = 'bible_translation'
       and i.lifecycle_state = 'published' and r.complete_at is not null
       and app.content_rights_clear(r.rights_id, 'display') is null
       and exists(select 1 from app.content_bible_verses v where v.item_id = i.item_id
         and v.revision_no = r.revision_no and v.book_id = p_book_id
         and v.chapter = p_chapter)
  ));
$$;

create or replace function app.content_bible_manifest_json(p_code text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'translation_code', p_code,
    'manifest_version', app.content_bible_latest_manifest(p_code),
    'chapters', coalesce(jsonb_agg(jsonb_build_object(
      'book_id', m.book_id,
      'chapter', c.chapter,
      'verse_count', m.chapter_counts[c.chapter],
      'omitted_verses', to_jsonb(app.content_bible_manifest_omissions(
        m.manifest_version, m.translation_code, m.book_id, c.chapter
      ))
    ) order by b.canonical_order, c.chapter), '[]'::jsonb)
  )
    from app.content_bible_manifest m
    join app.content_bible_books b on b.book_id = m.book_id
    cross join lateral generate_subscripts(m.chapter_counts, 1) c(chapter)
   where m.translation_code = p_code
     and m.manifest_version = app.content_bible_latest_manifest(p_code);
$$;

revoke all on function
  app.content_bible_manifest_omissions(integer,text,text,integer),
  app.content_bible_manifest_complete(integer,text),
  app.content_bible_manifest_json(text),
  app.content_bible_import_verses(uuid,bigint,jsonb),
  app.content_public_bible_chapter(uuid,text,integer)
  from public, anon, authenticated, service_role;

grant execute on function app.content_public_bible_chapter(uuid,text,integer)
  to anon, authenticated;
grant execute on function app.content_bible_manifest_json(text)
  to anon, authenticated;

notify pgrst, 'reload schema';
