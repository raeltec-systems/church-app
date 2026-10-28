-- Story 6.6 review correction: tie WEB publication and reads to a verified eBible.org
-- public-domain rights revision. The staff candidate filter is only a usability aid; this
-- server-side check is the authority for publication, public reads and offline access.

create or replace function app.content_bible_rights_clear(
  p_rights_id uuid,
  p_translation_code text,
  p_use text
)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_reason text;
begin
  v_reason := app.content_rights_clear(p_rights_id, p_use);
  if v_reason is not null then
    return v_reason;
  end if;
  if p_translation_code is distinct from 'WEB' then
    return null;
  end if;

  if not exists (
    select 1
      from app.content_items i
      join app.content_rights_revisions r
        on r.item_id = i.item_id and r.revision_no = i.live_revision_no
     where i.item_id = p_rights_id
       and i.kind = 'rights'
       and i.lifecycle_state = 'published'
       and r.basis = 'public_domain'
       and r.evidence ~* 'ebible[.]org'
       and concat_ws(' ', r.label, r.source_key, r.evidence)
           ~* '(world[[:space:]]+english[[:space:]]+bible|(^|[^a-z0-9])web([^a-z0-9]|$)|engwebp)'
  ) then
    return 'source_mismatch';
  end if;
  return null;
end;
$$;

comment on function app.content_bible_rights_clear(uuid, text, text) is
  'Story 6.6: checks normal per-use rights and, for WEB only, requires a verified public-domain '
  'record that identifies the World English Bible and cites eBible.org.';

create or replace function app.content_bible_publish(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
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
  v_item app.content_items;
  v_rev app.content_bible_revisions;
  v_no integer;
  v_reason text;
begin
  select a.* into v_actor
    from app.content_command_actor(p_actor, 'bible_translation') a;
  v_errors := app.contract_unknown_keys(p_payload, array['translation_id']);
  v_error := app.contract_uuid_error(p_payload -> 'translation_id');
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('translation_id', v_error);
  else
    v_id := (p_payload ->> 'translation_id')::uuid;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;

  v_item := app.content_item_lock(
    v_id, 'bible_translation', p_expected_revision, 'translation_id'
  );
  v_no := coalesce(v_item.draft_revision_no,
    case when v_item.lifecycle_state = 'withdrawn' then v_item.live_revision_no end);
  select r.* into v_rev
    from app.content_bible_revisions r
   where r.item_id = v_id and r.revision_no = v_no
   for share;
  if not found or v_rev.complete_at is null then
    perform app.cmd_fail('validation_failed', jsonb_build_object('translation_id', 'incomplete'));
  end if;

  v_reason := app.content_bible_rights_clear(
    v_rev.rights_id, v_rev.translation_code, 'display'
  );
  if v_reason is not null then
    perform app.cmd_fail('validation_failed', jsonb_build_object('translation_id', v_reason));
  end if;

  v_no := app.content_item_publish(
    v_item, v_actor.member_id, v_actor.account_id, v_actor.capacity,
    'content.publish_bible_translation', 'translation_id'
  );
  update app.content_bible_revisions
     set published_at = coalesce(published_at, now()),
         published_by_member = coalesce(published_by_member, v_actor.member_id),
         published_by_account = coalesce(published_by_account, v_actor.account_id)
   where item_id = v_id and revision_no = v_no;
  return app.content_item_outcome(v_id, 'translation_id');
end;
$$;

create or replace function app.content_public_bible_translation_json(p_item_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'translation_id', i.item_id,
    'translation_code', r.translation_code,
    'name', r.name,
    'offline_allowed', app.content_bible_rights_clear(
      r.rights_id, r.translation_code, 'offline'
    ) is null,
    'chapters', coalesce((
      select jsonb_agg(jsonb_build_object('book_id', v.book_id, 'chapter', v.chapter)
                       order by b.canonical_order, v.chapter)
        from (select distinct book_id, chapter
                from app.content_bible_verses
               where item_id = i.item_id and revision_no = r.revision_no) v
        join app.content_bible_books b on b.book_id = v.book_id
    ), '[]'::jsonb)
  )
    from app.content_items i
    join app.content_bible_revisions r
      on r.item_id = i.item_id and r.revision_no = i.live_revision_no
   where i.item_id = p_item_id
     and i.kind = 'bible_translation'
     and i.lifecycle_state = 'published'
     and r.complete_at is not null
     and app.content_bible_rights_clear(r.rights_id, r.translation_code, 'display') is null;
$$;

create or replace function app.content_public_bible_translations()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'translations', coalesce(jsonb_agg(t.translation order by t.translation_code), '[]'::jsonb)
  )
    from (
      select r.translation_code,
             app.content_public_bible_translation_json(i.item_id) as translation
        from app.content_items i
        join app.content_bible_translation_keys k on k.item_id = i.item_id
        join app.content_bible_revisions r
          on r.item_id = i.item_id and r.revision_no = i.live_revision_no
       where i.kind = 'bible_translation'
         and i.lifecycle_state = 'published'
         and app.content_bible_rights_clear(r.rights_id, r.translation_code, 'display') is null
    ) t;
$$;

create or replace function app.content_public_bible_chapter(
  p_translation_id uuid,
  p_book_id text,
  p_chapter integer
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
      'verses', (
        select jsonb_agg(jsonb_build_object('verse', v.verse, 'text', v.text) order by v.verse)
          from app.content_bible_verses v
         where v.item_id = i.item_id
           and v.revision_no = r.revision_no
           and v.book_id = p_book_id
           and v.chapter = p_chapter
           and v.text <> ''
      ),
      'publication_revision', r.revision_no,
      'published_at', app.cmd_utc(i.published_at),
      'offline_allowed', app.content_bible_rights_clear(
        r.rights_id, r.translation_code, 'offline'
      ) is null
    )
      from app.content_items i
      join app.content_bible_revisions r
        on r.item_id = i.item_id and r.revision_no = i.live_revision_no
     where i.item_id = p_translation_id
       and i.kind = 'bible_translation'
       and i.lifecycle_state = 'published'
       and r.complete_at is not null
       and app.content_bible_rights_clear(r.rights_id, r.translation_code, 'display') is null
       and exists (
         select 1
           from app.content_bible_verses v
          where v.item_id = i.item_id
            and v.revision_no = r.revision_no
            and v.book_id = p_book_id
            and v.chapter = p_chapter
       )
  ));
$$;

create or replace function app.content_staff_bible_json(p_item_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'translation_id', i.item_id,
    'revision', i.revision,
    'state', i.lifecycle_state,
    'last_revision_no', i.last_revision_no,
    'draft_revision_no', i.draft_revision_no,
    'live_revision_no', i.live_revision_no,
    'code', coalesce(d.translation_code, l.translation_code, k.translation_code),
    'translation_code', coalesce(d.translation_code, l.translation_code, k.translation_code),
    'name', coalesce(d.name, l.name),
    'draft_complete', d.complete_at is not null,
    'draft_verse_count', coalesce((
      select count(*)
        from app.content_bible_verses v
       where v.item_id = i.item_id and v.revision_no = d.revision_no
    ), 0),
    'display_rights_error', case when d.revision_no is not null then
      app.content_bible_rights_clear(d.rights_id, d.translation_code, 'display') end,
    'offline_allowed', case when l.revision_no is not null then
      app.content_bible_rights_clear(l.rights_id, l.translation_code, 'offline') is null
      else false end
  )
    from app.content_items i
    join app.content_bible_translation_keys k on k.item_id = i.item_id
    left join app.content_bible_revisions d
      on d.item_id = i.item_id and d.revision_no = i.draft_revision_no
    left join app.content_bible_revisions l
      on l.item_id = i.item_id and l.revision_no = i.live_revision_no
   where i.item_id = p_item_id and i.kind = 'bible_translation';
$$;

revoke all on function app.content_bible_rights_clear(uuid, text, text)
  from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
