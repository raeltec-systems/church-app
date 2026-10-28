-- Sermon draft from a duty: the authority is decided after the occurrence lock (review
-- 2026-10-28, section 7, "sermon duty authorization race candidate"). A forward migration: no
-- merged migration is edited.
--
-- The 6.18 handler read the Duties owner read app.duties_owner_topic (who may send, and the
-- duty's topic, scripture, date and revision) and only then took the occurrence's transaction
-- advisory lock. A send that waited on that lock could act on a stale answer: a scope revoked, an
-- assignee reassigned or a slot cancelled while it waited would still create the draft.
--
-- The linearization point is now the lock: after taking it the handler reads
-- app.duties_owner_topic again, in a new statement (so under READ COMMITTED it sees everything
-- committed before the lock was granted), and every check and every value written comes from
-- that second read. The first read stays as an early refusal so a caller with no authority never
-- queues on the lock. Refusals and outcomes are unchanged (not_found, validation_failed
-- cell_part / no_topic, the same draft for a second send).
--
-- Replaced body (copied from its latest version; changes marked "Review 2026-10-28"):
--   from 20261028071717 (6.18): content_sermon_from_duty.
--
-- Lock order (AD-2) unchanged: the actor's member row FOR KEY SHARE (authorizer) -> receipt ->
-- the occurrence's transaction advisory lock -> the new item and revision rows.
-- duties_owner_topic takes no locks.
--
-- No destructive statements, no row deletions (no _rows file). ASCII only, no backslashes.

-- (Replaced; copied from 20261028071717_content_sermon_drafts_from_duties.sql.)
create or replace function app.content_sermon_from_duty(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  -- Review 2026-10-28: this first read is only an early refusal before queueing on the lock.
  perform app.duties_owner_topic(jsonb_build_object('occurrence_id', v_occ));
  perform pg_advisory_xact_lock(hashtextextended('content_sermon_duty_draft:' || v_occ::text, 0));
  -- Review 2026-10-28: the lock is the linearization point. Read the authority and the duty again
  -- now, so a revocation, reassignment or cancellation committed while this send waited refuses
  -- it; everything below uses only this read.
  v_duty := app.duties_owner_topic(jsonb_build_object('occurrence_id', v_occ));
  if v_duty ->> 'cell_id' is not null then
    perform app.cmd_fail('validation_failed', '{"occurrence_id": "cell_part"}');
  end if;
  v_topic := nullif(btrim(coalesce(v_duty ->> 'topic', '')), '');
  v_scripture := nullif(btrim(coalesce(v_duty ->> 'scripture', '')), '');
  if v_topic is null and v_scripture is null then
    perform app.cmd_fail('validation_failed', '{"occurrence_id": "no_topic"}');
  end if;
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
