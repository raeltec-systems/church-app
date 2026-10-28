-- Publish pinned announcements with an optional generic push (story 6.13; K14; AD-2, AD-5, AD-8).
-- Builds on 20261021233523_content_events_tracer.sql and only registers into its registries: the
-- shared lifecycle, its helpers, the dispatch, the authorizer, the replay recheck and the deletion
-- hook are used as they are, never replaced.
--
--   * A second content kind, `announcement` (Admin, Pastor, Media): short posts with a title, a
--     body and a pinned flag. The flag belongs to the revision, so changing it is a save and a
--     publish; the published revision stays live until a replacement is published.
--   * Commands content.create_announcement, save_announcement, publish_announcement,
--     withdraw_announcement and archive_announcement through api.content_command.
--   * The anonymous reads api.content_public_announcements() (pinned first, then the newest) and
--     api.content_public_announcement(announcement_id), and the editors' read
--     api.content_staff_announcements().
--   * An optional notice on publication through the 3.2 source contract: source type
--     `content_announcement`, kind `announcement_published`, fixed generic text, the deep link
--     /announcements/{source_id}; members switch the category off in the 3.7 settings and keep
--     the inbox item. Notifications enqueues one recipient per logical key and has no
--     church-wide fan-out, so publish_announcement {notify: true} enqueues one job per member
--     whose current access allows it (approved, 3.5 route `member`), at most
--     app.content_announcement_audience_limit() of them, in the publish transaction, falling due
--     at app.content_announcement_pace() a minute so other reminders are not held back. The same
--     route decides `recipient_eligible` at every recheck, so held, in-review, accountless,
--     deactivated and deleted members get no job, item, push job or direct-contact need. Each
--     published revision is notified at most once. A newer published revision, a withdrawal or
--     an archive cancels the pending jobs.
--   * Erase part `announcement_revisions` (revision attribution, including who notified).
--
-- Lock order (AD-2): the actor's role grants (authorizer) -> command receipt -> content item FOR
-- UPDATE -> announcement revisions -> Notifications jobs (last). Identity state is read without
-- locks.
--
-- No destructive statements and no row deletions. ASCII only, no backslashes.

-- ---------------------------------------------------------------------------------------------
-- The kind and its revisions
-- ---------------------------------------------------------------------------------------------

insert into app.content_kinds (kind, editor_roles, description) values
  ('announcement', array['admin', 'pastor', 'media'],
   'Church announcements: short posts, pinned or not, with an optional notice (story 6.13)');

create table app.content_announcement_revisions (
  item_id uuid not null references app.content_items (item_id),
  revision_no integer not null check (revision_no >= 1),
  title text not null check (length(title) between 1 and 100 and title ~ '[^[:space:]]'),
  body text not null check (length(body) between 1 and 1500 and body ~ '[^[:space:]]'),
  pinned boolean not null,
  saved_by_member uuid not null,
  saved_by_account uuid not null,
  saved_at timestamptz not null default now(),
  published_at timestamptz,
  published_by_member uuid,
  published_by_account uuid,
  notified_at timestamptz,
  notified_by_member uuid,
  notified_by_account uuid,
  notified_count integer check (notified_count >= 0),
  primary key (item_id, revision_no),
  check ((published_at is null) = (published_by_member is null)
         and (published_by_member is null) = (published_by_account is null)),
  check ((notified_at is null) = (notified_by_member is null)
         and (notified_by_member is null) = (notified_by_account is null)
         and (notified_at is null) = (notified_count is null)),
  check (notified_at is null or published_at is not null)
);

comment on table app.content_announcement_revisions is
  'owner: content. Announcement revisions (story 6.13): the open draft is editable; a published '
  'revision is immutable and notified at most once (only its attribution can be anonymised).';

alter table app.content_announcement_revisions enable row level security;
revoke all on table app.content_announcement_revisions from public, anon, authenticated, service_role;

-- A published revision's content never changes, and a notice is recorded once; attribution may be
-- anonymised.
create function app.content_announcement_revision_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.published_at is not null
     and (new.item_id, new.revision_no, new.title, new.body, new.pinned, new.published_at)
         is distinct from
         (old.item_id, old.revision_no, old.title, old.body, old.pinned, old.published_at) then
    raise exception using errcode = 'PCNT1', message = 'a published content revision is immutable';
  end if;
  if old.notified_at is not null
     and (new.notified_at, new.notified_count) is distinct from (old.notified_at, old.notified_count) then
    raise exception using errcode = 'PCNT1', message = 'a revision is notified at most once';
  end if;
  return new;
end;
$$;

create trigger content_announcement_revisions_immutable
  before update on app.content_announcement_revisions
  for each row execute function app.content_announcement_revision_guard();

-- ---------------------------------------------------------------------------------------------
-- Who a notice reaches
-- ---------------------------------------------------------------------------------------------

-- The most recipients one publication may enqueue in its own transaction. Notifications has no
-- church-wide fan-out (one recipient per logical key); a larger church needs a Notifications owner
-- operation (recorded in docs/runbooks/notifications.md, story 6.13).
create function app.content_announcement_audience_limit()
returns integer
language sql
immutable
set search_path = ''
as $$
  select 1000;
$$;

-- How many of one publication's jobs fall due per minute. The worker claims due jobs oldest first,
-- at most batch_max (default 25) per run, about one run a minute; a notice spread at 20 a minute
-- leaves room in every run for other reminders falling due meanwhile, so a large notice never
-- holds them back by more than about a minute. Its last members are reached after
-- audience / 20 minutes (1000 members: 50 minutes).
create function app.content_announcement_pace()
returns integer
language sql
immutable
set search_path = ''
as $$
  select 20;
$$;

-- A member the app can notify now: the 3.5 route is `member` (approved, a live link in good
-- standing, no hold, no review).
create function app.content_announcement_reachable(p_member_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((select r.route = 'member' from app.notifications_recipient_route(p_member_id) r), false);
$$;

-- Every member a notice would reach now, in a stable order.
create function app.content_announcement_audience()
returns setof uuid
language sql
stable
set search_path = ''
as $$
  select m.member_id
    from app.identity_members m
   where m.membership_state = 'approved' and app.content_announcement_reachable(m.member_id)
   order by m.member_id;
$$;

-- ---------------------------------------------------------------------------------------------
-- Notifications source (1.5) and reminder contract (3.2)
-- ---------------------------------------------------------------------------------------------

-- Current while the announcement is published at the job's revision (its published revision
-- number); the revision is null while it is not public.
create function app.content_announcement_source_check(p_source jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select jsonb_build_object(
             'current', i.lifecycle_state = 'published'
                        and i.live_revision_no::numeric = (p_source ->> 'source_revision')::numeric,
             'revision', case when i.lifecycle_state = 'published' then i.live_revision_no end)
      from app.content_items i
     where i.item_id::text = lower(p_source ->> 'source_id') and i.kind = 'announcement'),
    '{"current": false, "revision": null}'::jsonb);
$$;

-- Current and actionable while that revision is the published one; eligible while the app can
-- notify the recipient now. Never any announcement text (the contract carries generic text).
create function app.content_announcement_reminder_check(p_key jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_item app.content_items;
  v_current boolean;
begin
  select i.* into v_item from app.content_items i
   where i.item_id::text = lower(p_key ->> 'source_id') and i.kind = 'announcement';
  if not found or v_item.lifecycle_state <> 'published' then
    return '{"current": false, "revision": null, "actionable": false, "recipient_eligible": false}'::jsonb;
  end if;
  v_current := v_item.live_revision_no::numeric = (p_key ->> 'source_revision')::numeric;
  return jsonb_build_object(
    'current', v_current,
    'revision', v_item.live_revision_no,
    'actionable', v_current,
    'recipient_eligible', app.content_announcement_reachable((p_key ->> 'recipient_member_id')::uuid));
end;
$$;

select app.contract_register_source_type(
  'content', 'content_announcement', 'app.content_announcement_source_check(jsonb)'::regprocedure);
select app.contract_register_reminder_kind('content', 'content_announcement', 'announcement_published');
select app.contract_register_reminder_contract(
  'content', 'content_announcement', 'announcement_published',
  'app.content_announcement_reminder_check(jsonb)'::regprocedure,
  '{"title": "Church announcement",
    "body": "The church has posted an announcement. Open the app to read it.",
    "link": "/announcements/{source_id}"}'::jsonb);

-- ---------------------------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------------------------

-- The three announcement fields of a payload with their field errors: title (100) and body (1500,
-- multiline) required; pinned a required boolean.
create function app.content_announcement_fields(
  p_payload jsonb,
  out errors jsonb,
  out title text,
  out body text,
  out pinned boolean
)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_error text;
begin
  errors := '{}'::jsonb;
  select t.error, t.value into v_error, title from app.content_free_text(p_payload -> 'title', 100, false) t;
  if v_error is null and title is null then
    v_error := 'required';
  end if;
  if v_error is not null then
    errors := errors || jsonb_build_object('title', v_error);
  end if;
  select t.error, t.value into v_error, body from app.content_free_text(p_payload -> 'body', 1500, true) t;
  if v_error is null and body is null then
    v_error := 'required';
  end if;
  if v_error is not null then
    errors := errors || jsonb_build_object('body', v_error);
  end if;
  if coalesce(jsonb_typeof(p_payload -> 'pinned'), 'null') = 'null' then
    errors := errors || '{"pinned": "required"}'::jsonb;
  elsif jsonb_typeof(p_payload -> 'pinned') <> 'boolean' then
    errors := errors || '{"pinned": "invalid"}'::jsonb;
  else
    pinned := (p_payload -> 'pinned')::text::boolean;
  end if;
end;
$$;

-- An announcement_id field of a payload.
create function app.content_announcement_id(p_payload jsonb, out error text, out value uuid)
language plpgsql
immutable
set search_path = ''
as $$
begin
  error := app.contract_uuid_error(p_payload -> 'announcement_id');
  if error is null then
    value := (p_payload ->> 'announcement_id')::uuid;
  end if;
end;
$$;

-- An announcement command's outcome: ids, state, revisions and, on a publish, how many members a
-- notice was enqueued for (no names, no text).
create function app.content_announcement_outcome(p_item_id uuid, p_notified integer)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select case when p_notified is null then o
              else jsonb_set(o, '{data,notified}', to_jsonb(p_notified)) end
    from (select app.content_item_outcome(p_item_id, 'announcement_id') as o) x;
$$;

-- Pending notices of this announcement are pointless now (a newer revision went live, or it left
-- the public reads). Notifications last.
create function app.content_announcement_cancel_notices(p_item_id uuid, p_reason text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform app.notifications_cancel(jsonb_build_object(
    'source_type', 'content_announcement', 'source_id', p_item_id, 'reason', p_reason));
end;
$$;

-- content.create_announcement {title, body, pinned}; expected null. A new private draft.
create function app.content_announcement_create(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_fields record;
  v_errors jsonb;
  v_item uuid;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'announcement') a;
  v_errors := app.contract_unknown_keys(p_payload, array['title', 'body', 'pinned']);
  select f.* into v_fields from app.content_announcement_fields(p_payload) f;
  v_errors := v_errors || v_fields.errors;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_open('announcement', v_actor.member_id, v_actor.account_id,
                                  v_actor.capacity, 'content.create_announcement');
  insert into app.content_announcement_revisions (item_id, revision_no, title, body, pinned,
                                                  saved_by_member, saved_by_account)
  values (v_item, 1, v_fields.title, v_fields.body, v_fields.pinned, v_actor.member_id,
          v_actor.account_id);
  return app.content_announcement_outcome(v_item, null);
end;
$$;

-- content.save_announcement {announcement_id, title, body, pinned}; expected = the item's
-- revision. Writes the open draft, or opens the next draft revision; the live revision stays
-- public until a publish replaces it.
create function app.content_announcement_save(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_fields record;
  v_errors jsonb;
  v_error text;
  v_id uuid;
  v_item app.content_items;
  v_no integer;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'announcement') a;
  v_errors := app.contract_unknown_keys(p_payload, array['announcement_id', 'title', 'body', 'pinned']);
  select t.error, t.value into v_error, v_id from app.content_announcement_id(p_payload) t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('announcement_id', v_error);
  end if;
  select f.* into v_fields from app.content_announcement_fields(p_payload) f;
  v_errors := v_errors || v_fields.errors;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_lock(v_id, 'announcement', p_expected_revision, 'announcement_id');
  v_no := app.content_item_draft_no(v_item);
  insert into app.content_announcement_revisions as r (item_id, revision_no, title, body, pinned,
                                                       saved_by_member, saved_by_account)
  values (v_id, v_no, v_fields.title, v_fields.body, v_fields.pinned, v_actor.member_id,
          v_actor.account_id)
  on conflict (item_id, revision_no) do update
     set title = excluded.title,
         body = excluded.body,
         pinned = excluded.pinned,
         saved_by_member = excluded.saved_by_member,
         saved_by_account = excluded.saved_by_account,
         saved_at = now()
   where r.published_at is null;
  perform app.content_item_saved(v_item, v_no, v_actor.member_id, v_actor.account_id,
                                 v_actor.capacity, 'content.save_announcement');
  return app.content_announcement_outcome(v_id, null);
end;
$$;

-- content.publish_announcement {announcement_id, notify}; expected = the item's revision. The
-- open draft goes live (or a withdrawn announcement's live revision comes back); pending notices
-- of an earlier revision are cancelled. With notify: one job per member the app can notify now
-- (Q2 closed: unavailable, nothing published; more than the limit: {notify:
-- too_many_recipients}; this revision already notified: {notify: already_notified}).
create function app.content_announcement_publish(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_error text;
  v_id uuid;
  v_notify boolean;
  v_item app.content_items;
  v_no integer;
  v_audience uuid[];
  v_member uuid;
  v_pace integer := app.content_announcement_pace();
  v_i integer := 0;
  v_count integer := 0;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'announcement') a;
  v_errors := app.contract_unknown_keys(p_payload, array['announcement_id', 'notify']);
  select t.error, t.value into v_error, v_id from app.content_announcement_id(p_payload) t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('announcement_id', v_error);
  end if;
  if coalesce(jsonb_typeof(p_payload -> 'notify'), 'null') = 'null' then
    v_errors := v_errors || '{"notify": "required"}'::jsonb;
  elsif jsonb_typeof(p_payload -> 'notify') <> 'boolean' then
    v_errors := v_errors || '{"notify": "invalid"}'::jsonb;
  else
    v_notify := (p_payload -> 'notify')::text::boolean;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_lock(v_id, 'announcement', p_expected_revision, 'announcement_id');
  v_no := app.content_item_publish(v_item, v_actor.member_id, v_actor.account_id, v_actor.capacity,
                                   'content.publish_announcement', 'announcement_id');
  -- A revision published again after a withdrawal keeps its first publication.
  update app.content_announcement_revisions r
     set published_at = now(),
         published_by_member = v_actor.member_id,
         published_by_account = v_actor.account_id
   where r.item_id = v_id and r.revision_no = v_no and r.published_at is null;
  -- The revision row is locked before any Notifications row (AD-2: Notifications last), also when
  -- a withdrawn revision is published again and the update above matched nothing.
  perform 1 from app.content_announcement_revisions r
   where r.item_id = v_id and r.revision_no = v_no for update;
  perform app.content_announcement_cancel_notices(v_id, 'source_revised');
  if v_notify then
    if exists (select 1 from app.content_announcement_revisions r
                where r.item_id = v_id and r.revision_no = v_no and r.notified_at is not null) then
      perform app.cmd_fail('validation_failed', '{"notify": "already_notified"}'::jsonb);
    end if;
    -- The Q2 scheduling gate, checked once even when nobody is reachable (enqueue checks it too).
    perform app.notifications_policy();
    v_audience := array(select app.content_announcement_audience());
    if cardinality(v_audience) > app.content_announcement_audience_limit() then
      perform app.cmd_fail('validation_failed', '{"notify": "too_many_recipients"}'::jsonb);
    end if;
    -- Spread at the pace: the first `pace` members are due now, the next a minute later, and so on.
    foreach v_member in array v_audience loop
      if coalesce((app.notifications_enqueue(jsonb_build_object(
             'source_type', 'content_announcement', 'source_id', v_id, 'source_revision', v_no,
             'recipient_member_id', v_member, 'reminder_kind', 'announcement_published',
             'scheduled_at', app.cmd_utc(now() + make_interval(mins => v_i / v_pace)))) ->> 'created')::boolean,
                  false) then
        v_count := v_count + 1;
      end if;
      v_i := v_i + 1;
    end loop;
    update app.content_announcement_revisions r
       set notified_at = now(),
           notified_by_member = v_actor.member_id,
           notified_by_account = v_actor.account_id,
           notified_count = v_count
     where r.item_id = v_id and r.revision_no = v_no;
  end if;
  return app.content_announcement_outcome(v_id, v_count);
end;
$$;

-- content.withdraw_announcement {announcement_id}; expected = the item's revision. Published
-- announcements only; their pending notices are cancelled.
create function app.content_announcement_withdraw(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  select a.* into v_actor from app.content_command_actor(p_actor, 'announcement') a;
  v_errors := app.contract_unknown_keys(p_payload, array['announcement_id']);
  select t.error, t.value into v_error, v_id from app.content_announcement_id(p_payload) t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('announcement_id', v_error);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_lock(v_id, 'announcement', p_expected_revision, 'announcement_id');
  perform app.content_item_withdraw(v_item, v_actor.member_id, v_actor.account_id,
                                    v_actor.capacity, 'content.withdraw_announcement', 'announcement_id');
  perform app.content_announcement_cancel_notices(v_id, 'source_cancelled');
  return app.content_announcement_outcome(v_id, null);
end;
$$;

-- content.archive_announcement {announcement_id}; expected = the item's revision. Retires it from
-- any state; its pending notices are cancelled.
create function app.content_announcement_archive(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  select a.* into v_actor from app.content_command_actor(p_actor, 'announcement') a;
  v_errors := app.contract_unknown_keys(p_payload, array['announcement_id']);
  select t.error, t.value into v_error, v_id from app.content_announcement_id(p_payload) t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('announcement_id', v_error);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_lock(v_id, 'announcement', p_expected_revision, 'announcement_id');
  perform app.content_item_archive(v_item, v_actor.member_id, v_actor.account_id,
                                   v_actor.capacity, 'content.archive_announcement');
  perform app.content_announcement_cancel_notices(v_id, 'source_cancelled');
  return app.content_announcement_outcome(v_id, null);
end;
$$;

select app.content_register_command('content.create_announcement', 'announcement',
  'app.content_announcement_create(uuid, bigint, jsonb)'::regprocedure, true);
select app.content_register_command('content.save_announcement', 'announcement',
  'app.content_announcement_save(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.publish_announcement', 'announcement',
  'app.content_announcement_publish(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.withdraw_announcement', 'announcement',
  'app.content_announcement_withdraw(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.archive_announcement', 'announcement',
  'app.content_announcement_archive(uuid, bigint, jsonb)'::regprocedure, false);

-- ---------------------------------------------------------------------------------------------
-- The public read contract (anonymous): the current published projection only
-- ---------------------------------------------------------------------------------------------

-- One published announcement as anyone may read it: no draft, editor identity, notice record or
-- audit field. Null for anything else (unknown, draft only, withdrawn or archived).
create function app.content_public_announcement_json(p_item_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'announcement_id', i.item_id,
    'title', r.title,
    'body', r.body,
    'pinned', r.pinned,
    'publication_revision', r.revision_no,
    'published_at', app.cmd_utc(i.published_at))
    from app.content_items i
    join app.content_announcement_revisions r
      on r.item_id = i.item_id and r.revision_no = i.live_revision_no
   where i.item_id = p_item_id and i.kind = 'announcement' and i.lifecycle_state = 'published';
$$;

-- The published announcements, pinned first, then the most recently published; at most 100
-- (`truncated` says more exist).
create function app.content_public_announcements()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with live as (
    select i.item_id,
           row_number() over (order by r.pinned desc, i.published_at desc, i.item_id) as rn
      from app.content_items i
      join app.content_announcement_revisions r
        on r.item_id = i.item_id and r.revision_no = i.live_revision_no
     where i.kind = 'announcement' and i.lifecycle_state = 'published')
  select jsonb_build_object(
           'announcements', coalesce(jsonb_agg(app.content_public_announcement_json(l.item_id) order by l.rn)
                                       filter (where l.rn <= 100), '[]'::jsonb),
           'truncated', count(*) > 100)
    from live l;
$$;

-- One published announcement, or {"announcement": null}.
create function app.content_public_announcement(p_announcement_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('announcement', app.content_public_announcement_json(p_announcement_id));
$$;

create function api.content_public_announcements()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select app.content_public_announcements();
$$;

comment on function api.content_public_announcements() is
  'Story 6.13, public (anon and authenticated): the published announcements, pinned first.';

create function api.content_public_announcement(announcement_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select app.content_public_announcement($1);
$$;

comment on function api.content_public_announcement(uuid) is
  'Story 6.13, public (anon and authenticated): one published announcement, or null.';

-- ---------------------------------------------------------------------------------------------
-- The editors' read
-- ---------------------------------------------------------------------------------------------

create function app.content_announcement_revision_json(p_item_id uuid, p_revision_no integer)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'revision_no', r.revision_no,
    'title', r.title,
    'body', r.body,
    'pinned', r.pinned,
    'saved_at', app.cmd_utc(r.saved_at),
    'saved_by', app.content_editor_name(r.saved_by_member),
    'notified_at', app.cmd_utc(r.notified_at),
    'notified_by', case when r.notified_by_member is not null
                        then app.content_editor_name(r.notified_by_member) end,
    'notified_count', r.notified_count)
    from app.content_announcement_revisions r
   where r.item_id = p_item_id and r.revision_no = p_revision_no;
$$;

create function app.content_staff_announcement_json(p_item_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'announcement_id', i.item_id,
    'revision', i.revision,
    'state', i.lifecycle_state,
    'created_at', app.cmd_utc(i.created_at),
    'created_by', app.content_editor_name(i.created_by_member),
    'updated_at', app.cmd_utc(i.updated_at),
    'published_at', app.cmd_utc(i.published_at),
    'published_by', case when i.published_by_member is not null
                         then app.content_editor_name(i.published_by_member) end,
    'withdrawn_at', app.cmd_utc(i.withdrawn_at),
    'archived_at', app.cmd_utc(i.archived_at),
    'live', case when i.live_revision_no is not null
                 then app.content_announcement_revision_json(i.item_id, i.live_revision_no) end,
    'draft', case when i.draft_revision_no is not null
                  then app.content_announcement_revision_json(i.item_id, i.draft_revision_no) end)
    from app.content_items i
   where i.item_id = p_item_id;
$$;

-- Every announcement with its live and draft revisions, attribution and notice record, for its
-- editors (Media, Pastor, Admin): archived last, the others most recently changed first; at most
-- 500. `audience` is how many members a notice would reach now, the limit of one notice and how
-- many fall due per minute; `notice` is the registered generic text phones show (never the
-- announcement's own).
create function app.content_staff_announcements()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_link uuid;
  v_capacity text;
  v_result jsonb;
begin
  select a.member_id, a.link_id into v_member, v_link from app.identity_require_access() a;
  v_capacity := app.content_editor_capacity(v_member, 'announcement');
  if v_capacity is null then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  with ranked as (
    select i.item_id,
           row_number() over (order by (i.lifecycle_state = 'archived'), i.updated_at desc,
                                       i.item_id) as rn
      from app.content_items i
     where i.kind = 'announcement')
  select jsonb_build_object(
           'capacity', v_capacity,
           'audience', jsonb_build_object(
             'members', (select count(*)::integer from app.content_announcement_audience()),
             'limit', app.content_announcement_audience_limit(),
             'per_minute', app.content_announcement_pace()),
           'notice', (select jsonb_build_object('title', c.title, 'body', c.body)
                        from app.contract_reminder_contracts c
                       where c.source_type = 'content_announcement'
                         and c.reminder_kind = 'announcement_published'),
           'announcements', coalesce(jsonb_agg(app.content_staff_announcement_json(k.item_id)
                                               order by k.rn) filter (where k.rn <= 500), '[]'::jsonb),
           'truncated', count(*) > 500)
    into v_result
    from ranked k;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

create function api.content_staff_announcements()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.content_staff_announcements();
$$;

comment on function api.content_staff_announcements() is
  'Story 6.13: every announcement with its live and draft revisions, for Media, Pastors and Admins.';

-- ---------------------------------------------------------------------------------------------
-- Deletion: the announcements erase part of Content's one hook
-- ---------------------------------------------------------------------------------------------

-- Revision attribution (saved, published, notified) becomes the nil UUID; published revisions
-- keep their content (the guard trigger allows attribution changes only).
create function app.content_announcement_erase_part(p_input jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid := (p_input ->> 'member_id')::uuid;
  v_account uuid := nullif(p_input ->> 'account_id', '')::uuid;
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
begin
  if p_input ->> 'phase' = 'erase' then
    update app.content_announcement_revisions r set saved_by_member = v_nil
     where r.saved_by_member = v_member;
    update app.content_announcement_revisions r set published_by_member = v_nil
     where r.published_by_member = v_member;
    update app.content_announcement_revisions r set notified_by_member = v_nil
     where r.notified_by_member = v_member;
    if v_account is not null then
      update app.content_announcement_revisions r set saved_by_account = v_nil
       where r.saved_by_account = v_account;
      update app.content_announcement_revisions r set published_by_account = v_nil
       where r.published_by_account = v_account;
      update app.content_announcement_revisions r set notified_by_account = v_nil
       where r.notified_by_account = v_account;
    end if;
  end if;
  return (select count(*) from app.content_announcement_revisions r
           where r.saved_by_member = v_member or r.published_by_member = v_member
              or r.notified_by_member = v_member
              or r.saved_by_account = v_account or r.published_by_account = v_account
              or r.notified_by_account = v_account)::integer;
end;
$$;

select app.content_register_erase_part('announcement_revisions',
  'app.content_announcement_erase_part(jsonb)'::regprocedure);

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.content_announcement_revision_guard(),
  app.content_announcement_audience_limit(),
  app.content_announcement_pace(),
  app.content_announcement_reachable(uuid),
  app.content_announcement_audience(),
  app.content_announcement_source_check(jsonb),
  app.content_announcement_reminder_check(jsonb),
  app.content_announcement_fields(jsonb),
  app.content_announcement_id(jsonb),
  app.content_announcement_outcome(uuid, integer),
  app.content_announcement_cancel_notices(uuid, text),
  app.content_announcement_create(uuid, bigint, jsonb),
  app.content_announcement_save(uuid, bigint, jsonb),
  app.content_announcement_publish(uuid, bigint, jsonb),
  app.content_announcement_withdraw(uuid, bigint, jsonb),
  app.content_announcement_archive(uuid, bigint, jsonb),
  app.content_public_announcement_json(uuid),
  app.content_public_announcements(),
  app.content_public_announcement(uuid),
  api.content_public_announcements(),
  api.content_public_announcement(uuid),
  app.content_announcement_revision_json(uuid, integer),
  app.content_staff_announcement_json(uuid),
  app.content_staff_announcements(),
  api.content_staff_announcements(),
  app.content_announcement_erase_part(jsonb)
  from public, anon, authenticated, service_role;

grant execute on function app.content_public_announcements() to anon, authenticated;
grant execute on function api.content_public_announcements() to anon, authenticated;
grant execute on function app.content_public_announcement(uuid) to anon, authenticated;
grant execute on function api.content_public_announcement(uuid) to anon, authenticated;
grant execute on function app.content_staff_announcements() to authenticated;
grant execute on function api.content_staff_announcements() to authenticated;

notify pgrst, 'reload schema';
