-- Send a preaching duty's topic and scripture to Media as a sermon draft (story 6.18; K11;
-- AD-1, AD-2, AD-6). A forward migration: no merged migration is edited.
--
-- Who sends: the duty's current assignee (pending or accepted; mobile duty detail) or its
-- managers (the department's leader, deputy or an Admin; staff web rota). Content never reads a
-- Duties table: the topic, scripture, date and who may send come from the 4.11 owner read
-- app.duties_owner_topic, called inside the Content command (and the status read), which
-- answers only the assignee or the duty's managers (not_found otherwise).
--
--   * content.draft_sermon_from_duty {occurrence_id}; expected null. A member command
--     (app.content_member_commands): the handler's call to duties_owner_topic is the authority.
--     It creates ONE private sermon draft per duty occurrence: title from the topic (the
--     scripture when there is no topic), scripture_reference from the scripture, sermon_date
--     the duty's start date in church time (Africa/Lusaka); no speaker, notes, series or video.
--     A second send (by anyone allowed) answers the same draft and changes nothing
--     (created: false). Refusals: validation_failed {"occurrence_id": "no_topic"} (neither topic
--     nor scripture), {"occurrence_id": "cell_part"} (a cell programme part is not a church
--     sermon), not_found (not the assignee or a manager, unknown or unpublished), unavailable
--     (the Q4 personal-data gate is closed).
--   * app.content_sermon_duty_drafts links the occurrence to its draft, with the duty's name and
--     start as they were sent (shown to editors as "From a duty") and who sent it. The draft is
--     an ordinary sermon of story 6.9: only Media, Pastor and Admin read it
--     (api.content_staff_sermons, now with `from_duty`), complete it and publish it through
--     content.save_sermon and content.publish_sermon, whose required speaker keeps an unfinished
--     draft from publishing. Nothing publishes automatically and no notice is sent.
--   * api.content_duty_sermon_draft(occurrence_id): for the assignee or a manager, whether the
--     duty can be sent and whether it was (sent_at, published); anyone else PT403 not_granted.
--   * Replay recheck: aggregate content_sermon_duty_draft (the occurrence id) is in scope while
--     the actor still passes duties_owner_topic for it.
--   * Audit: the draft's creation is attributed with the new capacities duty_assignee and
--     duty_manager (app.content_state_ok widened, as its comment provides).
--   * Deletion: erase part sermon_duty_drafts anonymises the sender (nil UUID).
--
-- Replaced bodies (each copied from its latest version; changes marked "Story 6.18"):
--   from 20261021233523 (6.1): content_state_ok.
--   from 20261027083618 (6.9): content_staff_sermon_json.
--
-- Lock order (AD-2): the actor's member row FOR KEY SHARE (authorizer) -> receipt -> the
-- occurrence's transaction advisory lock (one draft per occurrence, race-safe) -> the new item
-- and revision rows. duties_owner_topic takes no locks.
--
-- No destructive statements, no row deletions (no _rows file). ASCII only, no backslashes.

-- ---------------------------------------------------------------------------------------------
-- Vocabulary: the two sender capacities
-- ---------------------------------------------------------------------------------------------

-- (Replaced; copied from 20261021233523_content_events_tracer.sql.) Story 6.18: capacity adds
-- duty_assignee and duty_manager (who sent a duty's topic to Media).
create or replace function app.content_state_ok(p_kind text, p_value text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_value is not null and case p_kind
    when 'lifecycle_state' then p_value in ('draft', 'published', 'withdrawn', 'archived')
    when 'capacity' then p_value in ('admin', 'pastor', 'media', 'duty_assignee', 'duty_manager')
    when 'audit_action' then p_value in ('created', 'draft_saved', 'published', 'withdrawn',
                                         'archived')
    else false end;
$$;

comment on function app.content_state_ok(text, text) is
  'Content state vocabularies (story 6.1; 6.18 sender capacities). Later stories widen them by '
  'replacing this function.';

-- ---------------------------------------------------------------------------------------------
-- The link from a duty occurrence to its sermon draft
-- ---------------------------------------------------------------------------------------------

create table app.content_sermon_duty_drafts (
  occurrence_id uuid primary key,
  sermon_id uuid not null unique references app.content_items (item_id),
  duty_name text not null check (length(duty_name) between 1 and 200),
  duty_starts_at timestamptz not null,
  duty_revision bigint not null check (duty_revision >= 1),
  sent_by_member uuid not null,
  sent_by_account uuid not null,
  sent_capacity text not null check (sent_capacity in ('duty_assignee', 'duty_manager')),
  sent_at timestamptz not null default now()
);

comment on table app.content_sermon_duty_drafts is
  'owner: content. One sermon draft per duty occurrence sent to Media (story 6.18): the duty''s '
  'name and start as sent, and who sent it. The occurrence id is an opaque Duties reference.';

alter table app.content_sermon_duty_drafts enable row level security;
revoke all on table app.content_sermon_duty_drafts from public, anon, authenticated, service_role;

-- The command's outcome: ids and the sent time only (receipts keep it; no names or topic).
create function app.content_sermon_duty_draft_outcome(p_occurrence_id uuid, p_created boolean)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'content_sermon_duty_draft',
    'aggregate_id', d.occurrence_id,
    'revision', 1,
    'data', jsonb_build_object('occurrence_id', d.occurrence_id, 'sermon_id', d.sermon_id,
                               'created', p_created, 'sent_at', app.cmd_utc(d.sent_at)))
    from app.content_sermon_duty_drafts d
   where d.occurrence_id = p_occurrence_id;
$$;

-- content.draft_sermon_from_duty {occurrence_id}; expected null (see the header).
create function app.content_sermon_from_duty(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_error text;
  v_occ uuid;
  v_duty jsonb;
  v_topic text;
  v_scripture text;
  v_capacity text;
  v_id uuid;
begin
  select a.* into v_actor from app.content_member_actor(p_actor) a;
  v_errors := app.contract_unknown_keys(p_payload, array['occurrence_id']);
  select t.error, t.value into v_error, v_occ from app.content_payload_uuid(p_payload, 'occurrence_id') t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('occurrence_id', v_error);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  -- The Duties owner read is the authority: the assignee or a manager, else not_found.
  v_duty := app.duties_owner_topic(jsonb_build_object('occurrence_id', v_occ));
  if v_duty ->> 'cell_id' is not null then
    perform app.cmd_fail('validation_failed', '{"occurrence_id": "cell_part"}');
  end if;
  v_topic := nullif(btrim(coalesce(v_duty ->> 'topic', '')), '');
  v_scripture := nullif(btrim(coalesce(v_duty ->> 'scripture', '')), '');
  if v_topic is null and v_scripture is null then
    perform app.cmd_fail('validation_failed', '{"occurrence_id": "no_topic"}');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('content_sermon_duty_draft:' || v_occ::text, 0));
  if exists (select 1 from app.content_sermon_duty_drafts d where d.occurrence_id = v_occ) then
    return app.content_sermon_duty_draft_outcome(v_occ, false);
  end if;
  v_capacity := case when coalesce((v_duty ->> 'assigned')::boolean, false)
                     then 'duty_assignee' else 'duty_manager' end;
  v_id := app.content_item_open('sermon', v_actor.member_id, v_actor.account_id, v_capacity,
                                'content.draft_sermon_from_duty');
  insert into app.content_sermon_revisions (item_id, revision_no, title, speaker, sermon_date,
    scripture_reference, notes, saved_by_member, saved_by_account)
  values (v_id, 1, left(coalesce(v_topic, v_scripture), 160), null,
    ((v_duty ->> 'starts_at')::timestamptz at time zone 'Africa/Lusaka')::date,
    left(v_scripture, 250), '', v_actor.member_id, v_actor.account_id);
  insert into app.content_sermon_duty_drafts (occurrence_id, sermon_id, duty_name, duty_starts_at,
    duty_revision, sent_by_member, sent_by_account, sent_capacity)
  values (v_occ, v_id, left(v_duty ->> 'duty_name', 200), (v_duty ->> 'starts_at')::timestamptz,
    (v_duty ->> 'revision')::bigint, v_actor.member_id, v_actor.account_id, v_capacity);
  return app.content_sermon_duty_draft_outcome(v_occ, true);
end;
$$;

select app.content_register_command('content.draft_sermon_from_duty', 'sermon',
  'app.content_sermon_from_duty(uuid, bigint, jsonb)'::regprocedure, true);
select app.content_register_member_command('content.draft_sermon_from_duty');

-- Replay recheck: the actor still has live member access and still passes the Duties owner read
-- for the occurrence (its assignee or a manager).
create function app.content_sermon_duty_draft_in_scope(p_input jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_member uuid;
begin
  select e.member_id into v_member from app.identity_evaluate_grant(null, null, null) e
   where e.outcome = 'granted';
  if v_member is null then
    return false;
  end if;
  begin
    perform app.duties_owner_topic(jsonb_build_object('occurrence_id', p_input ->> 'aggregate_id'));
  exception when sqlstate 'PCMD1' then
    return false;
  end;
  return true;
end;
$$;

select app.content_register_replay_scope('content_sermon_duty_draft',
  'app.content_sermon_duty_draft_in_scope(jsonb)'::regprocedure);

-- ---------------------------------------------------------------------------------------------
-- The sender's status read
-- ---------------------------------------------------------------------------------------------

-- {occurrence_id, can_send, draft: null | {sent_at, published}} for the duty's assignee or a
-- manager (through duties_owner_topic); anyone else PT403 not_granted, the Q4 gate closed PT403
-- unavailable. Never the draft's text, editors or who sent it.
create function app.content_duty_sermon_draft(p_occurrence_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_access record;
  v_duty jsonb;
begin
  select a.member_id, a.link_id into v_access from app.identity_require_access() a;
  begin
    v_duty := app.duties_owner_topic(jsonb_build_object('occurrence_id', p_occurrence_id));
  exception when sqlstate 'PCMD1' then
    if sqlerrm = 'unavailable' then
      raise exception using errcode = 'PT403', message = 'unavailable', detail = 'unavailable';
    end if;
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end;
  perform app.identity_record_activity(v_access.link_id);
  return jsonb_build_object(
    'occurrence_id', p_occurrence_id,
    'can_send', v_duty ->> 'cell_id' is null
      and (nullif(btrim(coalesce(v_duty ->> 'topic', '')), '') is not null
           or nullif(btrim(coalesce(v_duty ->> 'scripture', '')), '') is not null),
    'draft', (select jsonb_build_object('sent_at', app.cmd_utc(d.sent_at),
                                        'published', i.lifecycle_state = 'published')
                from app.content_sermon_duty_drafts d
                join app.content_items i on i.item_id = d.sermon_id
               where d.occurrence_id = p_occurrence_id));
end;
$$;

create function api.content_duty_sermon_draft(occurrence_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.content_duty_sermon_draft($1);
$$;

comment on function api.content_duty_sermon_draft(uuid) is
  'Story 6.18: whether a duty''s topic can be or was sent to Media, for its assignee or managers.';

-- ---------------------------------------------------------------------------------------------
-- Editors see where a draft came from
-- ---------------------------------------------------------------------------------------------

-- (Replaced; copied from 20261027083618_content_sermons.sql.) Story 6.18: from_duty names the
-- duty and when it was sent (null for a sermon an editor created); never who sent it.
create or replace function app.content_staff_sermon_json(p_item_id uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('sermon_id', i.item_id, 'revision', i.revision, 'state', i.lifecycle_state,
    'created_at', app.cmd_utc(i.created_at), 'created_by', app.content_editor_name(i.created_by_member),
    'updated_at', app.cmd_utc(i.updated_at), 'published_at', app.cmd_utc(i.published_at),
    'published_by', case when i.published_by_member is not null then app.content_editor_name(i.published_by_member) end,
    'withdrawn_at', app.cmd_utc(i.withdrawn_at), 'archived_at', app.cmd_utc(i.archived_at),
    'live', app.content_sermon_revision_json(i.item_id, i.live_revision_no),
    'draft', app.content_sermon_revision_json(i.item_id, i.draft_revision_no),
    'from_duty', (select jsonb_build_object('duty_name', d.duty_name,
                                            'duty_starts_at', app.cmd_utc(d.duty_starts_at),
                                            'sent_at', app.cmd_utc(d.sent_at))
                    from app.content_sermon_duty_drafts d where d.sermon_id = i.item_id))
  from app.content_items i where i.item_id = p_item_id and i.kind = 'sermon';
$$;

-- ---------------------------------------------------------------------------------------------
-- Deletion: the sender is anonymised
-- ---------------------------------------------------------------------------------------------

create function app.content_sermon_duty_draft_erase_part(p_input jsonb)
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
    update app.content_sermon_duty_drafts d set sent_by_member = v_nil
     where d.sent_by_member = v_member;
    if v_account is not null then
      update app.content_sermon_duty_drafts d set sent_by_account = v_nil
       where d.sent_by_account = v_account;
    end if;
  end if;
  return (select count(*) from app.content_sermon_duty_drafts d
           where d.sent_by_member = v_member or d.sent_by_account = v_account)::integer;
end;
$$;

select app.content_register_erase_part('sermon_duty_drafts',
  'app.content_sermon_duty_draft_erase_part(jsonb)'::regprocedure);

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.content_sermon_duty_draft_outcome(uuid, boolean),
  app.content_sermon_from_duty(uuid, bigint, jsonb),
  app.content_sermon_duty_draft_in_scope(jsonb),
  app.content_duty_sermon_draft(uuid),
  api.content_duty_sermon_draft(uuid),
  app.content_sermon_duty_draft_erase_part(jsonb)
  from public, anon, authenticated, service_role;

grant execute on function app.content_duty_sermon_draft(uuid) to authenticated;
grant execute on function api.content_duty_sermon_draft(uuid) to authenticated;

notify pgrst, 'reload schema';
