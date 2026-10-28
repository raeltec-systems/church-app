-- Story 6.6: revisioned Bible translations with rights-aware public reads.
-- Verse counts are the trusted import boundary; the text remains private until publication.

insert into app.content_kinds (kind, editor_roles, description) values
  ('bible_translation', array['admin', 'pastor', 'media'],
   'Cleared Bible translations for the public reader (story 6.6)');

create table app.content_bible_books (
  book_id text primary key check (book_id ~ '^[A-Z0-9]{3}$'),
  canonical_order smallint not null unique check (canonical_order between 1 and 66),
  name text not null,
  chapter_count smallint not null check (chapter_count between 1 and 150)
);

insert into app.content_bible_books (book_id, canonical_order, name, chapter_count) values
  ('GEN',1,'Genesis',50),('EXO',2,'Exodus',40),('LEV',3,'Leviticus',27),
  ('NUM',4,'Numbers',36),('DEU',5,'Deuteronomy',34),('JOS',6,'Joshua',24),
  ('JDG',7,'Judges',21),('RUT',8,'Ruth',4),('1SA',9,'1 Samuel',31),
  ('2SA',10,'2 Samuel',24),('1KI',11,'1 Kings',22),('2KI',12,'2 Kings',25),
  ('1CH',13,'1 Chronicles',29),('2CH',14,'2 Chronicles',36),('EZR',15,'Ezra',10),
  ('NEH',16,'Nehemiah',13),('EST',17,'Esther',10),('JOB',18,'Job',42),
  ('PSA',19,'Psalms',150),('PRO',20,'Proverbs',31),('ECC',21,'Ecclesiastes',12),
  ('SNG',22,'Song of Solomon',8),('ISA',23,'Isaiah',66),('JER',24,'Jeremiah',52),
  ('LAM',25,'Lamentations',5),('EZK',26,'Ezekiel',48),('DAN',27,'Daniel',12),
  ('HOS',28,'Hosea',14),('JOL',29,'Joel',3),('AMO',30,'Amos',9),('OBA',31,'Obadiah',1),
  ('JON',32,'Jonah',4),('MIC',33,'Micah',7),('NAM',34,'Nahum',3),('HAB',35,'Habakkuk',3),
  ('ZEP',36,'Zephaniah',3),('HAG',37,'Haggai',2),('ZEC',38,'Zechariah',14),
  ('MAL',39,'Malachi',4),('MAT',40,'Matthew',28),('MRK',41,'Mark',16),
  ('LUK',42,'Luke',24),('JHN',43,'John',21),('ACT',44,'Acts',28),('ROM',45,'Romans',16),
  ('1CO',46,'1 Corinthians',16),('2CO',47,'2 Corinthians',13),('GAL',48,'Galatians',6),
  ('EPH',49,'Ephesians',6),('PHP',50,'Philippians',4),('COL',51,'Colossians',4),
  ('1TH',52,'1 Thessalonians',5),('2TH',53,'2 Thessalonians',3),('1TI',54,'1 Timothy',6),
  ('2TI',55,'2 Timothy',4),('TIT',56,'Titus',3),('PHM',57,'Philemon',1),
  ('HEB',58,'Hebrews',13),('JAS',59,'James',5),('1PE',60,'1 Peter',5),
  ('2PE',61,'2 Peter',3),('1JN',62,'1 John',5),('2JN',63,'2 John',1),
  ('3JN',64,'3 John',1),('JUD',65,'Jude',1),('REV',66,'Revelation',22);

-- Manifest version 1 is generated from public KJV and WEB verse-count sources.
-- The version is immutable once translations reference it; later corrections add a new version.
create table app.content_bible_manifest (
  manifest_version integer not null check (manifest_version > 0),
  translation_code text not null check (translation_code in ('KJV','WEB')),
  book_id text not null references app.content_bible_books(book_id),
  chapter_counts smallint[] not null,
  primary key (manifest_version, translation_code, book_id)
);

create table app.content_bible_translation_keys (
  item_id uuid primary key references app.content_items(item_id),
  translation_code text not null unique check (translation_code in ('KJV','WEB'))
);

create table app.content_bible_revisions (
  item_id uuid not null references app.content_bible_translation_keys(item_id),
  revision_no integer not null check (revision_no > 0),
  translation_code text not null check (translation_code in ('KJV','WEB')),
  name text not null check (length(name) between 1 and 100 and name ~ '[^[:space:]]'),
  rights_id uuid not null references app.content_items(item_id),
  manifest_version integer not null check (manifest_version > 0),
  complete_at timestamptz,
  saved_by_member uuid not null,
  saved_by_account uuid not null,
  saved_at timestamptz not null default now(),
  published_at timestamptz,
  published_by_member uuid,
  published_by_account uuid,
  primary key (item_id, revision_no),
  check ((published_at is null) = (published_by_member is null)
     and (published_by_member is null) = (published_by_account is null))
);

create table app.content_bible_verses (
  item_id uuid not null,
  revision_no integer not null,
  book_id text not null references app.content_bible_books(book_id),
  chapter smallint not null,
  verse smallint not null check (verse between 1 and 200),
  text text not null check (length(text) between 1 and 4000 and text ~ '[^[:space:]]'),
  primary key (item_id, revision_no, book_id, chapter, verse),
  foreign key (item_id, revision_no) references app.content_bible_revisions(item_id, revision_no),
  check (chapter between 1 and 150)
);

create index content_bible_verses_chapter on app.content_bible_verses
  (item_id, revision_no, book_id, chapter, verse);

create function app.content_bible_verse_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_item uuid;
  v_revision integer;
begin
  if tg_op = 'DELETE' then
    v_item := old.item_id;
    v_revision := old.revision_no;
  else
    v_item := new.item_id;
    v_revision := new.revision_no;
  end if;
  if exists (select 1 from app.content_bible_revisions r
              where r.item_id = v_item and r.revision_no = v_revision
                and r.published_at is not null) then
    raise exception using errcode = 'PCNT1', message = 'a published Bible revision is immutable';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger content_bible_verses_immutable
  before insert or update or delete on app.content_bible_verses
  for each row execute function app.content_bible_verse_guard();

alter table app.content_bible_books enable row level security;
alter table app.content_bible_manifest enable row level security;
alter table app.content_bible_translation_keys enable row level security;
alter table app.content_bible_revisions enable row level security;
alter table app.content_bible_verses enable row level security;
revoke all on table app.content_bible_books, app.content_bible_manifest,
  app.content_bible_translation_keys, app.content_bible_revisions, app.content_bible_verses
  from public, anon, authenticated, service_role;

create function app.content_bible_revision_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if old.published_at is not null then
      raise exception using errcode = 'PCNT1', message = 'a published Bible revision is immutable';
    end if;
    return old;
  end if;
  if old.published_at is not null
     and (new.item_id, new.revision_no, new.translation_code, new.name, new.rights_id,
          new.manifest_version, new.complete_at, new.published_at)
         is distinct from
         (old.item_id, old.revision_no, old.translation_code, old.name, old.rights_id,
          old.manifest_version, old.complete_at, old.published_at) then
    raise exception using errcode = 'PCNT1', message = 'a published Bible revision is immutable';
  end if;
  return new;
end;
$$;

create trigger content_bible_revision_immutable
  before update or delete on app.content_bible_revisions
  for each row execute function app.content_bible_revision_guard();

create function app.content_bible_manifest_count(p_version integer, p_code text,
                                                  p_book text, p_chapter integer)
returns integer
language sql
stable
set search_path = ''
as $$
  select m.chapter_counts[p_chapter]
    from app.content_bible_manifest m
    join app.content_bible_books b on b.book_id = m.book_id
   where m.manifest_version = p_version and m.translation_code = p_code
     and m.book_id = p_book and p_chapter between 1 and b.chapter_count;
$$;

create function app.content_bible_revision_manifest_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from app.content_bible_manifest m
                  where m.manifest_version = new.manifest_version
                    and m.translation_code = new.translation_code) then
    raise exception using errcode = 'PCNT1', message = 'Bible verse manifest is not registered';
  end if;
  return new;
end;
$$;

create trigger content_bible_revision_manifest
  before insert or update on app.content_bible_revisions
  for each row execute function app.content_bible_revision_manifest_guard();

create function app.content_bible_create(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_error text;
  v_code text;
  v_name text;
  v_rights uuid;
  v_manifest integer;
  v_item uuid;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'bible_translation') a;
  v_errors := app.contract_unknown_keys(p_payload,
    array['translation_code','name','rights_id','manifest_version']);
  v_code := p_payload ->> 'translation_code';
  if v_code is null or v_code not in ('KJV','WEB') then
    v_errors := v_errors || jsonb_build_object('translation_code','unsupported');
  end if;
  select t.error, t.value into v_error,v_name from app.content_free_text(p_payload -> 'name',100,false) t;
  if v_error is not null then v_errors := v_errors || jsonb_build_object('name',v_error); end if;
  if v_name is null then v_errors := v_errors || jsonb_build_object('name','required'); end if;
  if app.contract_uuid_error(p_payload -> 'rights_id') is not null then
    v_errors := v_errors || jsonb_build_object('rights_id','invalid');
  else
    v_rights := (p_payload ->> 'rights_id')::uuid;
  end if;
  if coalesce(p_payload ->> 'manifest_version','') !~ '^[1-9][0-9]{0,8}$' then
    v_errors := v_errors || jsonb_build_object('manifest_version','invalid');
  else
    v_manifest := (p_payload ->> 'manifest_version')::integer;
  end if;
  if v_code in ('KJV','WEB') and v_manifest is not null and not exists (
    select 1 from app.content_bible_manifest m
     where m.translation_code = v_code and m.manifest_version = v_manifest) then
    v_errors := v_errors || jsonb_build_object('manifest_version','not_registered');
  end if;
  if exists (select 1 from app.content_bible_translation_keys k where k.translation_code = v_code) then
    v_errors := v_errors || jsonb_build_object('translation_code','already_exists');
  end if;
  if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed',v_errors); end if;
  v_item := app.content_item_open('bible_translation',v_actor.member_id,v_actor.account_id,
                                  v_actor.capacity,'content.create_bible_translation');
  insert into app.content_bible_translation_keys(item_id,translation_code) values(v_item,v_code);
  insert into app.content_bible_revisions(item_id,revision_no,translation_code,name,rights_id,
    manifest_version,saved_by_member,saved_by_account)
  values(v_item,1,v_code,v_name,v_rights,v_manifest,v_actor.member_id,v_actor.account_id);
  return app.content_item_outcome(v_item,'translation_id');
end;
$$;

create function app.content_bible_begin_revision(p_actor uuid, p_expected_revision bigint,
                                                   p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_error text;
  v_id uuid;
  v_rights uuid;
  v_item app.content_items;
  v_prev app.content_bible_revisions;
  v_no integer;
begin
  select a.* into v_actor from app.content_command_actor(p_actor,'bible_translation') a;
  v_errors := app.contract_unknown_keys(p_payload,array['translation_id','rights_id']);
  v_error := app.contract_uuid_error(p_payload -> 'translation_id');
  if v_error is not null then v_errors := v_errors || jsonb_build_object('translation_id',v_error);
  else v_id := (p_payload ->> 'translation_id')::uuid; end if;
  v_error := app.contract_uuid_error(p_payload -> 'rights_id');
  if v_error is not null then v_errors := v_errors || jsonb_build_object('rights_id',v_error);
  else v_rights := (p_payload ->> 'rights_id')::uuid; end if;
  if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed',v_errors); end if;
  v_item := app.content_item_lock(v_id,'bible_translation',p_expected_revision,'translation_id');
  select r.* into v_prev from app.content_bible_revisions r
   where r.item_id = v_id and r.revision_no = coalesce(v_item.draft_revision_no,v_item.live_revision_no)
   for share;
  if not found then perform app.cmd_fail('not_found'); end if;
  v_no := v_item.last_revision_no + 1;
  insert into app.content_bible_revisions(item_id,revision_no,translation_code,name,rights_id,
    manifest_version,saved_by_member,saved_by_account)
  values(v_id,v_no,v_prev.translation_code,v_prev.name,v_rights,v_prev.manifest_version,
    v_actor.member_id,v_actor.account_id);
  perform app.content_item_saved(v_item,v_no,v_actor.member_id,v_actor.account_id,
    v_actor.capacity,'content.begin_bible_revision');
  return app.content_item_outcome(v_id,'translation_id');
end;
$$;

create function app.content_bible_import_verses(p_actor uuid, p_expected_revision bigint,
                                                 p_payload jsonb)
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
  select a.* into v_actor from app.content_command_actor(p_actor,'bible_translation') a;
  v_errors := app.contract_unknown_keys(p_payload,array['translation_id','revision_no','rows']);
  v_error := app.contract_uuid_error(p_payload -> 'translation_id');
  if v_error is not null then v_errors := v_errors || jsonb_build_object('translation_id',v_error);
  else v_id := (p_payload ->> 'translation_id')::uuid; end if;
  if coalesce(p_payload ->> 'revision_no','') !~ '^[1-9][0-9]{0,8}$' then
    v_errors := v_errors || jsonb_build_object('revision_no','invalid');
  else v_revision := (p_payload ->> 'revision_no')::integer; end if;
  if jsonb_typeof(p_payload -> 'rows') is distinct from 'array' then
    v_errors := v_errors || jsonb_build_object('rows','required');
  else
    v_len := jsonb_array_length(p_payload -> 'rows');
    if v_len < 1 or v_len > 200 then
      v_errors := v_errors || jsonb_build_object('rows','batch_size');
    end if;
  end if;
  if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed',v_errors); end if;
  v_item := app.content_item_lock(v_id,'bible_translation',p_expected_revision,'translation_id');
  if v_item.draft_revision_no is distinct from v_revision then
    perform app.cmd_fail('conflict',null,v_item.revision);
  end if;
  select r.* into v_rev from app.content_bible_revisions r
   where r.item_id = v_id and r.revision_no = v_revision for update;
  if not found or v_rev.complete_at is not null then
    perform app.cmd_fail('validation_failed',jsonb_build_object('revision_no','not_open'));
  end if;
  -- Validate every row's shape before any casts in duplicate checks. A malformed later row
  -- must not turn a prior valid batch into an uncaught database cast error.
  for v_row in select value from jsonb_array_elements(p_payload -> 'rows') loop
    if jsonb_typeof(v_row) is distinct from 'object' then
      perform app.cmd_fail('validation_failed',jsonb_build_object('rows','invalid_row'));
    end if;
    if app.contract_unknown_keys(v_row,array['book_id','chapter','verse','text']) <> '{}'::jsonb
       or coalesce(v_row ->> 'book_id','') !~ '^[A-Z0-9]{3}$'
       or coalesce(v_row ->> 'chapter','') !~ '^[1-9][0-9]{0,2}$'
       or coalesce(v_row ->> 'verse','') !~ '^[1-9][0-9]{0,2}$'
       or jsonb_typeof(v_row -> 'text') is distinct from 'string'
       or length(trim(coalesce(v_row ->> 'text',''))) not between 1 and 4000 then
      perform app.cmd_fail('validation_failed',jsonb_build_object('rows','invalid_row'));
    end if;
  end loop;
  for v_row in select value from jsonb_array_elements(p_payload -> 'rows') loop
    v_book := v_row ->> 'book_id';
    v_chapter := (v_row ->> 'chapter')::integer;
    v_verse := (v_row ->> 'verse')::integer;
    if app.content_bible_manifest_count(v_rev.manifest_version,v_rev.translation_code,
                                         v_book,v_chapter) is null
       or v_verse > app.content_bible_manifest_count(v_rev.manifest_version,
         v_rev.translation_code,v_book,v_chapter) then
      perform app.cmd_fail('validation_failed',jsonb_build_object('rows','outside_manifest'));
    end if;
    if exists (select 1 from app.content_bible_verses x where x.item_id = v_id
      and x.revision_no = v_revision and x.book_id = v_book
      and x.chapter = v_chapter and x.verse = v_verse)
       or (select count(*) from jsonb_array_elements(p_payload -> 'rows') q
          where q.value ->> 'book_id' = v_book and (q.value ->> 'chapter')::integer = v_chapter
            and (q.value ->> 'verse')::integer = v_verse) > 1 then
      perform app.cmd_fail('validation_failed',jsonb_build_object('rows','duplicate_verse'));
    end if;
  end loop;
  insert into app.content_bible_verses(item_id,revision_no,book_id,chapter,verse,text)
  select v_id,v_revision,r.value ->> 'book_id',(r.value ->> 'chapter')::smallint,
         (r.value ->> 'verse')::smallint,trim(r.value ->> 'text')
    from jsonb_array_elements(p_payload -> 'rows') r;
  update app.content_bible_revisions set saved_by_member = v_actor.member_id,
    saved_by_account = v_actor.account_id,saved_at = now()
   where item_id = v_id and revision_no = v_revision;
  perform app.content_item_saved(v_item,v_revision,v_actor.member_id,v_actor.account_id,
    v_actor.capacity,'content.import_bible_verses');
  return app.content_item_outcome(v_id,'translation_id');
end;
$$;

create function app.content_bible_finalize(p_actor uuid, p_expected_revision bigint,p_payload jsonb)
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
begin
  select a.* into v_actor from app.content_command_actor(p_actor,'bible_translation') a;
  v_errors := app.contract_unknown_keys(p_payload,array['translation_id','revision_no']);
  v_error := app.contract_uuid_error(p_payload -> 'translation_id');
  if v_error is not null then v_errors := v_errors || jsonb_build_object('translation_id',v_error);
  else v_id := (p_payload ->> 'translation_id')::uuid; end if;
  if coalesce(p_payload ->> 'revision_no','') !~ '^[1-9][0-9]{0,8}$' then
    v_errors := v_errors || jsonb_build_object('revision_no','invalid');
  else v_revision := (p_payload ->> 'revision_no')::integer; end if;
  if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed',v_errors); end if;
  v_item := app.content_item_lock(v_id,'bible_translation',p_expected_revision,'translation_id');
  if v_item.draft_revision_no is distinct from v_revision then
    perform app.cmd_fail('conflict',null,v_item.revision);
  end if;
  select r.* into v_rev from app.content_bible_revisions r
   where r.item_id = v_id and r.revision_no = v_revision for update;
  if not found then perform app.cmd_fail('not_found'); end if;
  if not exists(select 1 from app.content_bible_verses v where v.item_id=v_id
    and v.revision_no=v_revision) or exists (
    select 1 from app.content_bible_verses v
    where v.item_id=v_id and v.revision_no=v_revision
    group by v.book_id,v.chapter
    having count(*) <> app.content_bible_manifest_count(v_rev.manifest_version,
             v_rev.translation_code,v.book_id,v.chapter)
       or min(v.verse) <> 1
       or max(v.verse) <> app.content_bible_manifest_count(v_rev.manifest_version,
             v_rev.translation_code,v.book_id,v.chapter)) then
    perform app.cmd_fail('validation_failed',jsonb_build_object('revision_no','incomplete_chapter'));
  end if;
  update app.content_bible_revisions set complete_at = now(), saved_by_member=v_actor.member_id,
    saved_by_account=v_actor.account_id,saved_at=now()
   where item_id=v_id and revision_no=v_revision;
  perform app.content_item_saved(v_item,v_revision,v_actor.member_id,v_actor.account_id,
    v_actor.capacity,'content.finalize_bible_revision');
  return app.content_item_outcome(v_id,'translation_id');
end;
$$;

create function app.content_bible_publish(p_actor uuid,p_expected_revision bigint,p_payload jsonb)
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
  select a.* into v_actor from app.content_command_actor(p_actor,'bible_translation') a;
  v_errors := app.contract_unknown_keys(p_payload,array['translation_id']);
  v_error := app.contract_uuid_error(p_payload -> 'translation_id');
  if v_error is not null then v_errors := v_errors || jsonb_build_object('translation_id',v_error);
  else v_id := (p_payload ->> 'translation_id')::uuid; end if;
  if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed',v_errors); end if;
  v_item := app.content_item_lock(v_id,'bible_translation',p_expected_revision,'translation_id');
  v_no := coalesce(v_item.draft_revision_no,
    case when v_item.lifecycle_state='withdrawn' then v_item.live_revision_no end);
  select r.* into v_rev from app.content_bible_revisions r
   where r.item_id=v_id and r.revision_no=v_no for share;
  if not found or v_rev.complete_at is null then
    perform app.cmd_fail('validation_failed',jsonb_build_object('translation_id','incomplete'));
  end if;
  v_reason := app.content_rights_clear(v_rev.rights_id,'display');
  if v_reason is not null then
    perform app.cmd_fail('validation_failed',jsonb_build_object('translation_id',v_reason));
  end if;
  v_no := app.content_item_publish(v_item,v_actor.member_id,v_actor.account_id,v_actor.capacity,
    'content.publish_bible_translation','translation_id');
  update app.content_bible_revisions set published_at=coalesce(published_at,now()),
    published_by_member=coalesce(published_by_member,v_actor.member_id),
    published_by_account=coalesce(published_by_account,v_actor.account_id)
   where item_id=v_id and revision_no=v_no;
  return app.content_item_outcome(v_id,'translation_id');
end;
$$;

create function app.content_bible_withdraw(p_actor uuid,p_expected_revision bigint,p_payload jsonb)
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
begin
  select a.* into v_actor from app.content_command_actor(p_actor,'bible_translation') a;
  v_errors := app.contract_unknown_keys(p_payload,array['translation_id']);
  v_error := app.contract_uuid_error(p_payload -> 'translation_id');
  if v_error is not null then v_errors := v_errors || jsonb_build_object('translation_id',v_error);
  else v_id := (p_payload ->> 'translation_id')::uuid; end if;
  if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed',v_errors); end if;
  v_item := app.content_item_lock(v_id,'bible_translation',p_expected_revision,'translation_id');
  perform app.content_item_withdraw(v_item,v_actor.member_id,v_actor.account_id,v_actor.capacity,
    'content.withdraw_bible_translation','translation_id');
  return app.content_item_outcome(v_id,'translation_id');
end;
$$;

create function app.content_bible_archive(p_actor uuid,p_expected_revision bigint,p_payload jsonb)
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
begin
  select a.* into v_actor from app.content_command_actor(p_actor,'bible_translation') a;
  v_errors := app.contract_unknown_keys(p_payload,array['translation_id']);
  v_error := app.contract_uuid_error(p_payload -> 'translation_id');
  if v_error is not null then v_errors := v_errors || jsonb_build_object('translation_id',v_error);
  else v_id := (p_payload ->> 'translation_id')::uuid; end if;
  if v_errors <> '{}'::jsonb then perform app.cmd_fail('validation_failed',v_errors); end if;
  v_item := app.content_item_lock(v_id,'bible_translation',p_expected_revision,'translation_id');
  perform app.content_item_archive(v_item,v_actor.member_id,v_actor.account_id,v_actor.capacity,
    'content.archive_bible_translation');
  return app.content_item_outcome(v_id,'translation_id');
end;
$$;

select app.content_register_command('content.create_bible_translation','bible_translation',
  'app.content_bible_create(uuid,bigint,jsonb)'::regprocedure,true);
select app.content_register_command('content.begin_bible_revision','bible_translation',
  'app.content_bible_begin_revision(uuid,bigint,jsonb)'::regprocedure,false);
select app.content_register_command('content.import_bible_verses','bible_translation',
  'app.content_bible_import_verses(uuid,bigint,jsonb)'::regprocedure,false);
select app.content_register_command('content.finalize_bible_revision','bible_translation',
  'app.content_bible_finalize(uuid,bigint,jsonb)'::regprocedure,false);
select app.content_register_command('content.publish_bible_translation','bible_translation',
  'app.content_bible_publish(uuid,bigint,jsonb)'::regprocedure,false);
select app.content_register_command('content.withdraw_bible_translation','bible_translation',
  'app.content_bible_withdraw(uuid,bigint,jsonb)'::regprocedure,false);
select app.content_register_command('content.archive_bible_translation','bible_translation',
  'app.content_bible_archive(uuid,bigint,jsonb)'::regprocedure,false);

create function app.content_public_bible_translation_json(p_item_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'translation_id',i.item_id,'translation_code',r.translation_code,'name',r.name,
    'offline_allowed',app.content_rights_clear(r.rights_id,'offline') is null,
    'chapters',coalesce((select jsonb_agg(jsonb_build_object(
      'book_id',v.book_id,'chapter',v.chapter) order by b.canonical_order,v.chapter)
      from (select distinct book_id,chapter from app.content_bible_verses
             where item_id=i.item_id and revision_no=r.revision_no) v
      join app.content_bible_books b on b.book_id=v.book_id),'[]'::jsonb))
    from app.content_items i
    join app.content_bible_revisions r on r.item_id=i.item_id and r.revision_no=i.live_revision_no
   where i.item_id=p_item_id and i.kind='bible_translation' and i.lifecycle_state='published'
     and r.complete_at is not null and app.content_rights_clear(r.rights_id,'display') is null;
$$;

create function app.content_public_bible_translations()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('translations',coalesce(jsonb_agg(t.translation
           order by t.translation_code),'[]'::jsonb))
    from (select r.translation_code,app.content_public_bible_translation_json(i.item_id) as translation
            from app.content_items i
            join app.content_bible_translation_keys k on k.item_id=i.item_id
            join app.content_bible_revisions r on r.item_id=i.item_id and r.revision_no=i.live_revision_no
           where i.kind='bible_translation' and i.lifecycle_state='published'
             and app.content_rights_clear(r.rights_id,'display') is null) t;
$$;

create function app.content_public_bible_chapter(p_translation_id uuid,p_book_id text,p_chapter integer)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('chapter',(
    select jsonb_build_object(
      'translation_id',i.item_id,'translation_code',r.translation_code,'translation_name',r.name,
      'book_id',p_book_id,'chapter',p_chapter,
      'verses',(select jsonb_agg(jsonb_build_object('verse',v.verse,'text',v.text) order by v.verse)
                  from app.content_bible_verses v where v.item_id=i.item_id
                    and v.revision_no=r.revision_no and v.book_id=p_book_id and v.chapter=p_chapter),
      'publication_revision',r.revision_no,'published_at',app.cmd_utc(i.published_at),
      'offline_allowed',app.content_rights_clear(r.rights_id,'offline') is null)
      from app.content_items i
      join app.content_bible_revisions r on r.item_id=i.item_id and r.revision_no=i.live_revision_no
     where i.item_id=p_translation_id and i.kind='bible_translation'
       and i.lifecycle_state='published' and r.complete_at is not null
       and app.content_rights_clear(r.rights_id,'display') is null
       and exists(select 1 from app.content_bible_verses v where v.item_id=i.item_id
         and v.revision_no=r.revision_no and v.book_id=p_book_id and v.chapter=p_chapter)));
$$;

create function api.content_public_bible_translations()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select app.content_public_bible_translations(); $$;

create function api.content_public_bible_chapter(translation_id uuid,book_id text,chapter integer)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select app.content_public_bible_chapter($1,$2,$3); $$;

create function app.content_bible_manifest_json(p_code text)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object('translation_code',p_code,'manifest_version',1,
    'chapters',coalesce(jsonb_agg(jsonb_build_object('book_id',m.book_id,
      'chapter',c.chapter,'verse_count',m.chapter_counts[c.chapter])
      order by b.canonical_order,c.chapter),'[]'::jsonb))
    from app.content_bible_manifest m
    join app.content_bible_books b on b.book_id=m.book_id
    cross join lateral generate_subscripts(m.chapter_counts,1) c(chapter)
   where m.translation_code=p_code and m.manifest_version=1;
$$;

create function api.content_bible_manifest(translation_code text)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select app.content_bible_manifest_json($1); $$;

create function app.content_staff_bible_json(p_item_id uuid)
returns jsonb language sql stable set search_path = ''
as $$
  select jsonb_build_object('translation_id',i.item_id,'revision',i.revision,
    'state',i.lifecycle_state,'last_revision_no',i.last_revision_no,
    'draft_revision_no',i.draft_revision_no,'live_revision_no',i.live_revision_no,
    'code',coalesce(d.translation_code,l.translation_code,k.translation_code),
    'translation_code',coalesce(d.translation_code,l.translation_code,k.translation_code),
    'name',coalesce(d.name,l.name),'draft_complete',d.complete_at is not null,
    'draft_verse_count',coalesce((select count(*) from app.content_bible_verses v
      where v.item_id=i.item_id and v.revision_no=d.revision_no),0),
    'display_rights_error',case when d.revision_no is not null
       then app.content_rights_clear(d.rights_id,'display') end,
    'offline_allowed',case when l.revision_no is not null
       then app.content_rights_clear(l.rights_id,'offline') is null else false end)
    from app.content_items i
    join app.content_bible_translation_keys k on k.item_id=i.item_id
    left join app.content_bible_revisions d on d.item_id=i.item_id and d.revision_no=i.draft_revision_no
    left join app.content_bible_revisions l on l.item_id=i.item_id and l.revision_no=i.live_revision_no
   where i.item_id=p_item_id and i.kind='bible_translation';
$$;

create function app.content_staff_bibles()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor record;
begin
  select a.* into v_actor from app.content_require_editor('bible_translation') a;
  return jsonb_build_object('capacity',v_actor.capacity,'translations',coalesce((
    select jsonb_agg(app.content_staff_bible_json(i.item_id) order by k.translation_code)
      from app.content_items i join app.content_bible_translation_keys k on k.item_id=i.item_id
     where i.kind='bible_translation'),'[]'::jsonb));
end;
$$;

create function api.content_staff_bibles()
returns jsonb language sql security invoker set search_path = ''
as $$ select app.content_staff_bibles(); $$;

create function app.content_bible_erase_part(p_input jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_input ->> 'member_id')::uuid;
  v_account uuid := nullif(p_input ->> 'account_id','')::uuid;
  v_nil uuid := '00000000-0000-0000-0000-000000000000'::uuid;
begin
  if p_input ->> 'phase'='erase' then
    update app.content_bible_revisions r set saved_by_member=v_nil
     where r.saved_by_member=v_member;
    if v_account is not null then
      update app.content_bible_revisions r set saved_by_account=v_nil
       where r.saved_by_account=v_account;
    end if;
  end if;
  return (select count(*) from app.content_bible_revisions r
    where r.saved_by_member=v_member or r.saved_by_account=v_account)::integer;
end;
$$;

select app.content_register_erase_part('bible_revisions',
  'app.content_bible_erase_part(jsonb)'::regprocedure);

-- Count arrays are immutable metadata once shipped; future corrections are versioned additions.
create function app.content_bible_manifest_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_chapters integer;
begin
  if tg_op='DELETE' then
    raise exception using errcode='PCNT1',message='Bible verse manifests are immutable';
  end if;
  select b.chapter_count into v_chapters from app.content_bible_books b where b.book_id=new.book_id;
  if v_chapters is null or array_length(new.chapter_counts,1) is distinct from v_chapters
     or array_lower(new.chapter_counts,1) is distinct from 1
     or exists(select 1 from unnest(new.chapter_counts) n where n is null or n < 1 or n > 200) then
    raise exception using errcode='PCNT1',message='invalid Bible verse manifest';
  end if;
  if tg_op='UPDATE' and (old.manifest_version,old.translation_code,old.book_id,old.chapter_counts)
    is distinct from (new.manifest_version,new.translation_code,new.book_id,new.chapter_counts) then
    raise exception using errcode='PCNT1',message='Bible verse manifests are immutable';
  end if;
  return new;
end;
$$;

create trigger content_bible_manifest_immutable
  before insert or update or delete on app.content_bible_manifest
  for each row execute function app.content_bible_manifest_guard();


-- Manifest data version 1: KJV counts from bible-metadata (KJV); WEB counts from
-- world-english-bible verse-counts.ts. Counts are structural metadata, not Bible text.
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','GEN',array[31,25,24,26,32,22,24,22,29,32,32,20,18,24,21,16,27,33,38,18,34,24,20,67,34,35,46,22,35,43,55,32,20,31,29,43,36,30,23,23,57,38,34,34,28,34,31,22,33,26]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','EXO',array[22,25,22,31,23,30,25,32,35,29,10,51,22,31,27,36,16,27,25,26,36,31,33,18,40,37,21,43,46,38,18,35,23,35,35,38,29,31,43,38]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','LEV',array[17,16,17,35,19,30,38,36,24,20,47,8,59,57,33,34,16,30,37,27,24,33,44,23,55,46,34]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','NUM',array[54,34,51,49,31,27,89,26,23,36,35,16,33,45,41,50,13,32,22,29,35,41,30,25,18,65,23,31,40,16,54,42,56,29,34,13]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','DEU',array[46,37,29,49,33,25,26,20,29,22,32,32,18,29,23,22,20,22,21,20,23,30,25,22,19,19,26,68,29,20,30,52,29,12]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','JOS',array[18,24,17,24,15,27,26,35,27,43,23,24,33,15,63,10,18,28,51,9,45,34,16,33]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','JDG',array[36,23,31,24,31,40,25,35,57,18,40,15,25,20,20,31,13,31,30,48,25]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','RUT',array[22,23,18,22]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','1SA',array[28,36,21,22,12,21,17,22,27,27,15,25,23,52,35,23,58,30,24,42,15,23,29,22,44,25,12,25,11,31,13]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','2SA',array[27,32,39,12,25,23,29,18,13,19,27,31,39,33,37,23,29,33,43,26,22,51,39,25]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','1KI',array[53,46,28,34,18,38,51,66,28,29,43,33,34,31,34,34,24,46,21,43,29,53]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','2KI',array[18,25,27,44,27,33,20,29,37,36,21,21,25,29,38,20,41,37,37,21,26,20,37,20,30]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','1CH',array[54,55,24,43,26,81,40,40,44,14,47,40,14,17,29,43,27,17,19,8,30,19,32,31,31,32,34,21,30]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','2CH',array[17,18,17,22,14,42,22,18,31,19,23,16,22,15,19,14,19,34,11,37,20,12,21,27,28,23,9,27,36,27,21,33,25,33,27,23]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','EZR',array[11,70,13,24,17,22,28,36,15,44]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','NEH',array[11,20,32,23,19,19,73,18,38,39,36,47,31]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','EST',array[22,23,15,17,14,14,10,17,32,3]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','JOB',array[22,13,26,21,27,30,21,22,35,22,20,25,28,22,35,22,16,21,29,29,34,30,17,25,6,14,23,28,25,31,40,22,33,37,16,33,24,41,30,24,34,17]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','PSA',array[6,12,8,8,12,10,17,9,20,18,7,8,6,7,5,11,15,50,14,9,13,31,6,10,22,12,14,9,11,12,24,11,22,22,28,12,40,22,13,17,13,11,5,26,17,11,9,14,20,23,19,9,6,7,23,13,11,11,17,12,8,12,11,10,13,20,7,35,36,5,24,20,28,23,10,12,20,72,13,19,16,8,18,12,13,17,7,18,52,17,16,15,5,23,11,13,12,9,9,5,8,28,22,35,45,48,43,13,31,7,10,10,9,8,18,19,2,29,176,7,8,9,4,8,5,6,5,6,8,8,3,18,3,3,21,26,9,8,24,13,10,7,12,15,21,10,20,14,9,6]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','PRO',array[33,22,35,27,23,35,27,36,18,32,31,28,25,35,33,33,28,24,29,30,31,29,35,34,28,28,27,28,27,33,31]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','ECC',array[18,26,22,16,20,12,29,17,18,20,10,14]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','SNG',array[17,17,11,16,16,13,13,14]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','ISA',array[31,22,26,6,30,13,25,22,21,34,16,6,22,32,9,14,14,7,25,6,17,25,18,23,12,21,13,29,24,33,9,20,24,17,10,22,38,22,8,31,29,25,28,28,25,13,15,22,26,11,23,15,12,17,13,12,21,14,21,22,11,12,19,12,25,24]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','JER',array[19,37,25,31,31,30,34,22,26,25,23,17,27,22,21,21,27,23,15,18,14,30,40,10,38,24,22,17,32,24,40,44,26,22,19,32,21,28,18,16,18,22,13,30,5,28,7,47,39,46,64,34]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','LAM',array[22,22,66,22,22]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','EZK',array[28,10,27,17,17,14,27,18,11,22,25,28,23,23,8,63,24,32,14,49,32,31,49,27,17,21,36,26,21,26,18,32,33,31,15,38,28,23,29,49,26,20,27,31,25,24,23,35]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','DAN',array[21,49,30,37,31,28,28,27,27,21,45,13]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','HOS',array[11,23,5,19,15,11,16,14,17,15,12,14,16,9]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','JOL',array[20,32,21]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','AMO',array[15,16,15,13,27,14,17,14,15]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','OBA',array[21]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','JON',array[17,10,10,11]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','MIC',array[16,13,12,13,15,16,20]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','NAM',array[15,13,19]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','HAB',array[17,20,19]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','ZEP',array[18,15,20]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','HAG',array[15,23]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','ZEC',array[21,13,10,14,11,15,14,23,17,12,17,14,9,21]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','MAL',array[14,17,18,6]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','MAT',array[25,23,17,25,48,34,29,34,38,42,30,50,58,36,39,28,27,35,30,34,46,46,39,51,46,75,66,20]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','MRK',array[45,28,35,41,43,56,37,38,50,52,33,44,37,72,47,20]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','LUK',array[80,52,38,44,39,49,50,56,62,42,54,59,35,35,32,31,37,43,48,47,38,71,56,53]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','JHN',array[51,25,36,54,47,71,53,59,41,42,57,50,38,31,27,33,26,40,42,31,25]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','ACT',array[26,47,26,37,42,15,60,40,43,48,30,25,52,28,41,40,34,28,41,38,40,30,35,27,27,32,44,31]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','ROM',array[32,29,31,25,21,23,25,39,33,21,36,21,14,23,33,27]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','1CO',array[31,16,23,21,13,20,40,13,27,33,34,31,13,40,58,24]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','2CO',array[24,17,18,18,21,18,16,24,15,18,33,21,14]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','GAL',array[24,21,29,31,26,18]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','EPH',array[23,22,21,32,33,24]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','PHP',array[30,30,21,23]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','COL',array[29,23,25,18]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','1TH',array[10,20,13,18,28]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','2TH',array[12,17,18]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','1TI',array[20,15,16,16,25,21]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','2TI',array[18,26,17,22]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','TIT',array[16,15,15]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','PHM',array[25]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','HEB',array[14,18,19,16,14,20,28,13,28,39,40,29,25]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','JAS',array[27,26,18,17,20]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','1PE',array[25,25,22,19,14]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','2PE',array[21,22,18]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','1JN',array[10,29,24,21,21]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','2JN',array[13]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','3JN',array[14]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','JUD',array[25]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'KJV','REV',array[20,29,22,11,14,17,17,13,21,11,19,17,18,20,8,21,18,24,21,15,27,21]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','GEN',array[31,25,24,26,32,22,24,22,29,32,32,20,18,24,21,16,27,33,38,18,34,24,20,67,34,35,46,22,35,43,55,32,20,31,29,43,36,30,23,23,57,38,34,34,28,34,31,22,33,26]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','EXO',array[22,25,22,31,23,30,25,32,35,29,10,51,22,31,27,36,16,27,25,26,36,31,33,18,40,37,21,43,46,38,18,35,23,35,35,38,29,31,43,38]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','LEV',array[17,16,17,35,19,30,38,36,24,20,47,8,59,57,33,34,16,30,37,27,24,33,44,23,55,46,34]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','NUM',array[54,34,51,49,31,27,89,26,23,36,35,16,33,45,41,50,13,32,22,29,35,41,30,25,18,65,23,31,40,16,54,42,56,29,34,13]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','DEU',array[46,37,29,49,33,25,26,20,29,22,32,32,18,29,23,22,20,22,21,20,23,30,25,22,19,19,26,68,29,20,30,52,29,12]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','JOS',array[18,24,17,24,15,27,26,35,27,43,23,24,33,15,63,10,18,28,51,9,45,34,16,33]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','JDG',array[36,23,31,24,31,40,25,35,57,18,40,15,25,20,20,31,13,31,30,48,25]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','RUT',array[22,23,18,22]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','1SA',array[28,36,21,22,12,21,17,22,27,27,15,25,23,52,35,23,58,30,24,42,15,23,29,22,44,25,12,25,11,31,13]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','2SA',array[27,32,39,12,25,23,29,18,13,19,27,31,39,33,37,23,29,33,43,26,22,51,39,25]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','1KI',array[53,46,28,34,18,38,51,66,28,29,43,33,34,31,34,34,24,46,21,43,29,53]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','2KI',array[18,25,27,44,27,33,20,29,37,36,21,21,25,29,38,20,41,37,37,21,26,20,37,20,30]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','1CH',array[54,55,24,43,26,81,40,40,44,14,47,40,14,17,29,43,27,17,19,8,30,19,32,31,31,32,34,21,30]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','2CH',array[17,18,17,22,14,42,22,18,31,19,23,16,22,15,19,14,19,34,11,37,20,12,21,27,28,23,9,27,36,27,21,33,25,33,27,23]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','EZR',array[11,70,13,24,17,22,28,36,15,44]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','NEH',array[11,20,32,23,19,19,73,18,38,39,36,47,31]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','EST',array[22,23,15,17,14,14,10,17,32,3]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','JOB',array[22,13,26,21,27,30,21,22,35,22,20,25,28,22,35,22,16,21,29,29,34,30,17,25,6,14,23,28,25,31,40,22,33,37,16,33,24,41,30,24,34,17]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','PSA',array[6,12,8,8,12,10,17,9,20,18,7,8,6,7,5,11,15,50,14,9,13,31,6,10,22,12,14,9,11,12,24,11,22,22,28,12,40,22,13,17,13,11,5,26,17,11,9,14,20,23,19,9,6,7,23,13,11,11,17,12,8,12,11,10,13,20,7,35,36,5,24,20,28,23,10,12,20,72,13,19,16,8,18,12,13,17,7,18,52,17,16,15,5,23,11,13,12,9,9,5,8,28,22,35,45,48,43,13,31,7,10,10,9,8,18,19,2,29,176,7,8,9,4,8,5,6,5,6,8,8,3,18,3,3,21,26,9,8,24,13,10,7,12,15,21,10,20,14,9,6]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','PRO',array[33,22,35,27,23,35,27,36,18,32,31,28,25,35,33,33,28,24,29,30,31,29,35,34,28,28,27,28,27,33,31]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','ECC',array[18,26,22,16,20,12,29,17,18,20,10,14]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','SNG',array[17,17,11,16,16,13,13,14]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','ISA',array[31,22,26,6,30,13,25,22,21,34,16,6,22,32,9,14,14,7,25,6,17,25,18,23,12,21,13,29,24,33,9,20,24,17,10,22,38,22,8,31,29,25,28,28,25,13,15,22,26,11,23,15,12,17,13,12,21,14,21,22,11,12,19,12,25,24]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','JER',array[19,37,25,31,31,30,34,22,26,25,23,17,27,22,21,21,27,23,15,18,14,30,40,10,38,24,22,17,32,24,40,44,26,22,19,32,21,28,18,16,18,22,13,30,5,28,7,47,39,46,64,34]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','LAM',array[22,22,66,22,22]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','EZK',array[28,10,27,17,17,14,27,18,11,22,25,28,23,23,8,63,24,32,14,49,32,31,49,27,17,21,36,26,21,26,18,32,33,31,15,38,28,23,29,49,26,20,27,31,25,24,23,35]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','DAN',array[21,49,30,37,31,28,28,27,27,21,45,13]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','HOS',array[11,23,5,19,15,11,16,14,17,15,12,14,16,9]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','JOL',array[20,32,21]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','AMO',array[15,16,15,13,27,14,17,14,15]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','OBA',array[21]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','JON',array[17,10,10,11]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','MIC',array[16,13,12,13,15,16,20]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','NAM',array[15,13,19]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','HAB',array[17,20,19]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','ZEP',array[18,15,20]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','HAG',array[15,23]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','ZEC',array[21,13,10,14,11,15,14,23,17,12,17,14,9,21]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','MAL',array[14,17,18,6]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','MAT',array[25,23,17,25,48,34,29,34,38,42,30,50,58,36,39,28,27,35,30,34,46,46,39,51,46,75,66,20]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','MRK',array[45,28,35,41,43,56,37,38,50,52,33,44,37,72,47,20]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','LUK',array[80,52,38,44,39,49,50,56,62,42,54,59,35,35,32,31,37,43,48,47,38,71,56,53]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','JHN',array[51,25,36,54,47,71,53,59,41,42,57,50,38,31,27,33,26,40,42,31,25]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','ACT',array[26,47,26,37,42,15,60,40,43,48,30,25,52,28,41,40,34,28,41,38,40,30,35,27,27,32,44,31]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','ROM',array[32,29,31,25,21,23,25,39,33,21,36,21,14,26,33,25]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','1CO',array[31,16,23,21,13,20,40,13,27,33,34,31,13,40,58,24]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','2CO',array[24,17,18,18,21,18,16,24,15,18,33,21,14]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','GAL',array[24,21,29,31,26,18]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','EPH',array[23,22,21,32,33,24]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','PHP',array[30,30,21,23]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','COL',array[29,23,25,18]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','1TH',array[10,20,13,18,28]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','2TH',array[12,17,18]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','1TI',array[20,15,16,16,25,21]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','2TI',array[18,26,17,22]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','TIT',array[16,15,15]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','PHM',array[25]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','HEB',array[14,18,19,16,14,20,28,13,28,39,40,29,25]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','JAS',array[27,26,18,17,20]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','1PE',array[25,25,22,19,14]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','2PE',array[21,22,18]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','1JN',array[10,29,24,21,21]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','2JN',array[13]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','3JN',array[14]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','JUD',array[25]::smallint[]);
insert into app.content_bible_manifest(manifest_version,translation_code,book_id,chapter_counts) values(1,'WEB','REV',array[20,29,22,11,14,17,17,13,21,11,19,17,18,20,8,21,18,24,21,15,27,21]::smallint[]);
-- No direct table access or helper execution from client roles. Every public projection is an
-- explicit, narrowly shaped API function; every editor read checks the live Content role.
revoke all on function
  app.content_bible_revision_guard(), app.content_bible_revision_manifest_guard(),
  app.content_bible_verse_guard(),
  app.content_bible_manifest_guard(), app.content_bible_manifest_count(integer,text,text,integer),
  app.content_bible_create(uuid,bigint,jsonb),
  app.content_bible_begin_revision(uuid,bigint,jsonb),
  app.content_bible_import_verses(uuid,bigint,jsonb),
  app.content_bible_finalize(uuid,bigint,jsonb),
  app.content_bible_publish(uuid,bigint,jsonb),
  app.content_bible_withdraw(uuid,bigint,jsonb),
  app.content_bible_archive(uuid,bigint,jsonb),
  app.content_public_bible_translation_json(uuid),
  app.content_public_bible_translations(),
  app.content_public_bible_chapter(uuid,text,integer),
  app.content_bible_manifest_json(text),
  app.content_staff_bible_json(uuid),
  app.content_staff_bibles(),
  app.content_bible_erase_part(jsonb),
  api.content_public_bible_translations(),
  api.content_public_bible_chapter(uuid,text,integer),
  api.content_bible_manifest(text),
  api.content_staff_bibles()
  from public,anon,authenticated,service_role;

grant execute on function api.content_public_bible_translations() to anon,authenticated;
grant execute on function api.content_public_bible_chapter(uuid,text,integer) to anon,authenticated;
grant execute on function api.content_bible_manifest(text) to anon,authenticated;
grant execute on function api.content_staff_bibles() to authenticated;
grant execute on function app.content_public_bible_translations() to anon,authenticated;
grant execute on function app.content_public_bible_chapter(uuid,text,integer) to anon,authenticated;
grant execute on function app.content_bible_manifest_json(text) to anon,authenticated;
grant execute on function app.content_staff_bibles() to authenticated;

notify pgrst, 'reload schema';



