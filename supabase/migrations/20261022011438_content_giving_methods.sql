-- Publish verified giving methods and show How to give to guests (story 6.3; K1, K15, K16; AD-2,
-- AD-15).
--
-- The second Content kind, `giving_method`, on the story 6.1 publication lifecycle. Everything is
-- added through 6.1's registries (kinds, commands, erase parts); no shared Content function is
-- replaced.
--
--   * Instruction-only giving methods, edited by Admin only (app.content_kinds row). A method has a
--     fixed type (mobile_money, bank, other) and, per revision, its name, purpose, currency, the
--     type's destination fields, an optional starting USSD code (mobile money), 1-12 numbered
--     steps, an optional note and the church contact. There is no amount, payer, sender, donor,
--     proof, receipt, gift or transaction field anywhere, and a payload carrying one is refused
--     (unknown_field).
--   * Verification (owner decision 2026-10-21: a destination added or changed by one Admin is
--     verified by a different Admin before members see it). Every saved revision needs its own
--     recorded church verification (who, when, the date the details were tested and how); any save
--     clears it, and a save that changes nothing is refused. The verifier must not be any Admin
--     (member or account) who saved that revision, and the test date is not before the day it was
--     last saved. The database holds the rule too: a published revision must be verified (check);
--     a verification by one of the revision's savers, or recorded together with a change, is
--     refused, and a verified revision cannot change without losing its verification (trigger).
--     Discarding a draft (a method with a live revision) lets the next save start afresh.
--   * The q3_giving policy gate (Q3): publication is refused in production until Israel approves
--     it (unavailable {policy: gate_closed}); its local/staging fixture allows SAMPLE methods only.
--   * Order outside revisions: content.move_giving_method applies at once (order redirects nothing)
--     and is audited. Hide is the lifecycle's withdraw.
--   * Commands (api.content_command, 1.4 envelope): content.create_giving_method,
--     save_giving_method, verify_giving_method, publish_giving_method, hide_giving_method,
--     archive_giving_method, move_giving_method, discard_giving_draft.
--   * Public reads (anon and authenticated): api.content_public_giving_methods() and
--     api.content_public_giving_method(method_id): the live revision's giver-facing fields and the
--     date the details were verified, never the verifier, the test notes, editor identity or a
--     draft. `sample` is true off production (the app's sample banner).
--   * The Admins' read api.content_staff_giving_methods().
--   * Giving-only audit actions (saved with the changed field names, verified, reordered,
--     draft_discarded) in app.content_giving_audit; the shared ones (created, draft_saved,
--     published, withdrawn, archived) stay in app.content_audit.
--   * The giving erase part of Content's deletion hook (attribution becomes the nil UUID; no row
--     deletion, so no _rows file).
--
-- Lock order (AD-2): the actor's Identity role grants FOR SHARE (authorizer) -> command receipt ->
-- the giving_method kind row (create and move only, serialising the order) -> content item FOR
-- UPDATE -> the method's rows.
--
-- No destructive statements and no row deletions. ASCII only, no backslashes.

-- ---------------------------------------------------------------------------------------------
-- Kind, gate and vocabularies
-- ---------------------------------------------------------------------------------------------

insert into app.content_kinds (kind, editor_roles, description) values
  ('giving_method', array['admin'], 'Instruction-only giving methods on the public Give tab (story 6.3)');

insert into app.policy_gates (gate, decision_ref, description, fixture_value) values
  ('q3_giving', 'Q3',
   'The church''s verified giving methods, destinations, purposes, currency and support contact; '
   'gates the publication of giving methods',
   '{"fixture_label": "TEST FIXTURE - SAMPLE giving methods only", "sample_only": true}');

create function app.content_giving_vocab(p_kind text, p_value text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_value is not null and case p_kind
    when 'method_type' then p_value in ('mobile_money', 'bank', 'other')
    when 'identifier_kind' then p_value in ('merchant', 'till', 'phone')
    when 'audit_action' then p_value in ('saved', 'verified', 'reordered', 'draft_discarded')
    else false end;
$$;

comment on function app.content_giving_vocab(text, text) is
  'Giving method vocabularies (story 6.3): method types, identifier kinds, giving audit actions.';

-- A stored single-line text value: 1..p_max characters with something other than whitespace.
create function app.content_giving_text_ok(p_value text, p_max integer)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_value is null
      or (length(p_value) between 1 and p_max and p_value ~ '[^[:space:]]'
          and p_value !~ '[[:cntrl:]]');
$$;

-- Stored steps: 1..12 items, each 1..200 characters of single-line text.
create function app.content_giving_steps_ok(p_steps text[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_steps is not null and cardinality(p_steps) between 1 and 12
     and array_position(p_steps, null) is null
     and (select bool_and(app.content_giving_text_ok(s, 200)) from unnest(p_steps) s);
$$;

-- Whether p_new is p_old with some ids replaced by the nil UUID (erasure) and nothing else.
create function app.content_giving_only_anonymised(p_old uuid[], p_new uuid[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select cardinality(p_old) = cardinality(p_new)
     and coalesce((select bool_and(n.id = o.id or n.id = '00000000-0000-0000-0000-000000000000'::uuid)
                     from unnest(p_old) with ordinality as o (id, i)
                     join unnest(p_new) with ordinality as n (id, i) on n.i = o.i), true);
$$;

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

-- A giving method: its fixed type and its place in the public order.
create table app.content_giving_methods (
  item_id uuid primary key references app.content_items (item_id),
  method_type text not null check (app.content_giving_vocab('method_type', method_type)),
  sort_order integer not null check (sort_order >= 1)
);

comment on table app.content_giving_methods is
  'owner: content. A giving method: its fixed type and its position in the public order (story 6.3).';

-- A giving method revision: the open draft is editable and loses its verification on every save;
-- a published revision is immutable (only its attribution can be anonymised).
create table app.content_giving_revisions (
  item_id uuid not null references app.content_giving_methods (item_id),
  revision_no integer not null check (revision_no >= 1),
  method_type text not null check (app.content_giving_vocab('method_type', method_type)),
  name text not null check (app.content_giving_text_ok(name, 60)),
  purpose text check (app.content_giving_text_ok(purpose, 60)),
  currency text check (currency is null or currency ~ '^[A-Z]{3}$'),
  beneficiary text check (app.content_giving_text_ok(beneficiary, 120)),
  identifier_kind text
    check (identifier_kind is null or app.content_giving_vocab('identifier_kind', identifier_kind)),
  identifier text
    check (identifier is null
           or (length(identifier) <= 40
               and identifier ~ '^[+]?[0-9A-Za-z]([0-9A-Za-z -]*[0-9A-Za-z])?$')),
  bank_name text check (app.content_giving_text_ok(bank_name, 80)),
  account_number text
    check (account_number is null
           or (length(account_number) between 4 and 34
               and account_number ~ '^[0-9A-Za-z]([0-9A-Za-z -]*[0-9A-Za-z])?$')),
  branch text check (app.content_giving_text_ok(branch, 80)),
  branch_code text
    check (branch_code is null
           or (length(branch_code) <= 20 and branch_code ~ '^[0-9A-Za-z]([0-9A-Za-z -]*[0-9A-Za-z])?$')),
  swift_code text check (swift_code is null or swift_code ~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$'),
  reference text check (app.content_giving_text_ok(reference, 120)),
  ussd_code text check (ussd_code is null or ussd_code ~ '^[*][0-9*]{1,20}#$'),
  steps text[] not null check (app.content_giving_steps_ok(steps)),
  note text check (app.content_giving_text_ok(note, 200)),
  contact text not null check (app.content_giving_text_ok(contact, 160)),
  -- The last saver, and every member and account that saved this revision: none of them may
  -- verify it.
  saved_by_member uuid not null,
  saved_by_account uuid not null,
  saved_by_members uuid[] not null
    check (cardinality(saved_by_members) between 1 and 50
           and array_position(saved_by_members, null) is null),
  saved_by_accounts uuid[] not null
    check (cardinality(saved_by_accounts) between 1 and 50
           and array_position(saved_by_accounts, null) is null),
  saved_at timestamptz not null default now(),
  verified_at timestamptz,
  verified_by_member uuid,
  verified_by_account uuid,
  tested_on date,
  test_method text
    check (test_method is null
           or (length(test_method) between 1 and 500 and test_method ~ '[^[:space:]]')),
  published_at timestamptz,
  published_by_member uuid,
  published_by_account uuid,
  primary key (item_id, revision_no),
  -- Each type has exactly its own fields.
  check (case method_type
    when 'mobile_money' then
      beneficiary is not null and identifier_kind is not null and identifier is not null
      and bank_name is null and account_number is null and branch is null and branch_code is null
      and swift_code is null and reference is null
    when 'bank' then
      bank_name is not null and beneficiary is not null and account_number is not null
      and identifier_kind is null and identifier is null and ussd_code is null
    when 'other' then
      beneficiary is null and identifier_kind is null and identifier is null and bank_name is null
      and account_number is null and branch is null and branch_code is null and swift_code is null
      and reference is null and ussd_code is null
    else false end),
  -- A verification is whole: who, when, the tested date and how.
  check ((verified_at is null) = (verified_by_member is null)
         and (verified_by_member is null) = (verified_by_account is null)
         and (verified_by_account is null) = (tested_on is null)
         and (tested_on is null) = (test_method is null)),
  check ((published_at is null) = (published_by_member is null)
         and (published_by_member is null) = (published_by_account is null)),
  check (saved_by_member = any (saved_by_members) and saved_by_account = any (saved_by_accounts)),
  -- Nothing reaches members unverified.
  check (published_at is null or verified_at is not null)
);

comment on table app.content_giving_revisions is
  'owner: content. Giving method revisions with their church verification: the open draft is '
  'editable and every save clears its verification; a published revision is immutable (story 6.3).';

-- Content-free audit of the giving-only actions: ids, codes, positions and revisions.
create table app.content_giving_audit (
  event_id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  environment text not null default app.platform_current_environment(),
  action text not null check (app.content_giving_vocab('audit_action', action)),
  actor_member_id uuid not null,
  actor_account_id uuid not null,
  command_request_id uuid,
  item_id uuid not null,
  revision_no integer,
  position integer,
  changed_fields text[]
    check (changed_fields is null or changed_fields <@ array['name', 'purpose', 'currency', 'steps',
             'note', 'contact', 'beneficiary', 'identifier_kind', 'identifier', 'ussd_code',
             'bank_name', 'account_number', 'branch', 'branch_code', 'swift_code', 'reference']::text[]),
  revision_after bigint
);

create index content_giving_audit_item on app.content_giving_audit (item_id, event_id);
create index content_giving_audit_actor on app.content_giving_audit (actor_member_id);

comment on table app.content_giving_audit is
  'owner: content. Giving method verifications and moves: ids, codes, positions and revisions only.';

alter table app.content_giving_methods enable row level security;
alter table app.content_giving_revisions enable row level security;
alter table app.content_giving_audit enable row level security;
revoke all on table app.content_giving_methods, app.content_giving_revisions, app.content_giving_audit
  from public, anon, authenticated, service_role;
revoke all on sequence app.content_giving_audit_event_id_seq
  from public, anon, authenticated, service_role;

-- The revision guard. A published revision never changes (its attribution may be anonymised). A
-- verified draft changes only by its publication or by anonymisation; a save must clear the
-- verification. A verification is recorded only on an unchanged revision and never by a member or
-- account that saved it.
create function app.content_giving_revision_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_nil constant uuid := '00000000-0000-0000-0000-000000000000';
  v_content_changed boolean;
  v_savers_kept boolean;
  v_attribution_changed boolean;
  v_new_verification boolean;
begin
  if tg_op = 'UPDATE' then
    v_content_changed :=
      (new.item_id, new.revision_no, new.method_type, new.name, new.purpose, new.currency,
       new.beneficiary, new.identifier_kind, new.identifier, new.bank_name, new.account_number,
       new.branch, new.branch_code, new.swift_code, new.reference, new.ussd_code, new.steps,
       new.note, new.contact, new.saved_at)
      is distinct from
      (old.item_id, old.revision_no, old.method_type, old.name, old.purpose, old.currency,
       old.beneficiary, old.identifier_kind, old.identifier, old.bank_name, old.account_number,
       old.branch, old.branch_code, old.swift_code, old.reference, old.ussd_code, old.steps,
       old.note, old.contact, old.saved_at);
    -- The savers are unchanged, or only anonymised (erasure).
    v_savers_kept :=
      (new.saved_by_member = old.saved_by_member or new.saved_by_member = v_nil)
      and (new.saved_by_account = old.saved_by_account or new.saved_by_account = v_nil)
      and app.content_giving_only_anonymised(old.saved_by_members, new.saved_by_members)
      and app.content_giving_only_anonymised(old.saved_by_accounts, new.saved_by_accounts);
    -- Other attribution may change only to the nil UUID (erasure).
    v_attribution_changed :=
      not v_savers_kept
      or (new.verified_by_member is distinct from old.verified_by_member
          and new.verified_by_member is distinct from v_nil and old.verified_at is not null
          and new.verified_at is not null)
      or (new.verified_by_account is distinct from old.verified_by_account
          and new.verified_by_account is distinct from v_nil and old.verified_at is not null
          and new.verified_at is not null);
    if old.published_at is not null then
      if v_content_changed
         or (new.verified_at, new.tested_on, new.test_method, new.published_at)
            is distinct from (old.verified_at, old.tested_on, old.test_method, old.published_at)
         or v_attribution_changed
         or (new.published_by_member is distinct from old.published_by_member
             and new.published_by_member <> v_nil)
         or (new.published_by_account is distinct from old.published_by_account
             and new.published_by_account <> v_nil) then
        raise exception using errcode = 'PCNT1', message = 'a published content revision is immutable';
      end if;
    elsif old.verified_at is not null and new.verified_at is not null then
      if v_content_changed
         or (new.verified_at, new.tested_on, new.test_method)
            is distinct from (old.verified_at, old.tested_on, old.test_method)
         or v_attribution_changed then
        raise exception using errcode = 'PCNT1',
          message = 'a verified giving revision changes only by a save that clears its verification';
      end if;
    end if;
  end if;
  if new.verified_at is not null then
    if tg_op = 'INSERT' then
      v_new_verification := true;
    else
      v_new_verification := old.verified_at is null;
      -- A verification is recorded on the revision as it was saved, by itself.
      if v_new_verification
         and (v_content_changed
              or (new.saved_by_member, new.saved_by_account, new.saved_by_members, new.saved_by_accounts)
                 is distinct from
                 (old.saved_by_member, old.saved_by_account, old.saved_by_members, old.saved_by_accounts)) then
        raise exception using errcode = 'PCNT1',
          message = 'a giving revision is verified as it was saved, in an update of its own';
      end if;
    end if;
    if v_new_verification
       and (new.verified_by_member = any (new.saved_by_members)
            or new.verified_by_account = any (new.saved_by_accounts)) then
      raise exception using errcode = 'PCNT1',
        message = 'an Admin who saved a giving revision cannot verify it';
    end if;
  end if;
  return new;
end;
$$;

create trigger content_giving_revisions_guard
  before insert or update on app.content_giving_revisions
  for each row execute function app.content_giving_revision_guard();

-- ---------------------------------------------------------------------------------------------
-- Payload validation
-- ---------------------------------------------------------------------------------------------

-- The payload keys a method type carries (besides method_type or method_id).
create function app.content_giving_keys(p_type text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['name', 'purpose', 'currency', 'steps', 'note', 'contact']::text[]
         || case p_type
              when 'mobile_money' then array['beneficiary', 'identifier_kind', 'identifier', 'ussd_code']
              when 'bank' then array['bank_name', 'beneficiary', 'account_number', 'branch',
                                     'branch_code', 'swift_code', 'reference']
              else array[]::text[] end;
$$;

-- One single-line text field: its value (null when absent or blank) and error code
-- (required when p_required and absent).
create function app.content_giving_text(p_payload jsonb, p_key text, p_max integer,
                                        p_required boolean, out error text, out value text)
language plpgsql
immutable
set search_path = ''
as $$
begin
  select t.error, t.value into error, value
    from app.content_free_text(p_payload -> p_key, p_max, false) t;
  if error is null and value is null and p_required then
    error := 'required';
  end if;
end;
$$;

-- One coded field: text matching p_pattern (after p_upper upper-casing), at most p_max long.
create function app.content_giving_code(p_payload jsonb, p_key text, p_max integer,
                                        p_pattern text, p_upper boolean, p_required boolean,
                                        out error text, out value text)
language plpgsql
immutable
set search_path = ''
as $$
begin
  select t.error, t.value into error, value
    from app.content_giving_text(p_payload, p_key, 200, p_required) t;
  if error is not null or value is null then
    value := null;
    return;
  end if;
  if p_upper then
    value := upper(value);
  end if;
  if length(value) > p_max then
    error := 'too_long';
  elsif value !~ p_pattern then
    error := 'invalid';
  end if;
  if error is not null then
    value := null;
  end if;
end;
$$;

-- The fields of a method type from a payload, normalised, with their field errors. Absent
-- optional fields are null. `fields` keys: every key of app.content_giving_keys(p_type); steps is
-- a JSON array of strings.
create function app.content_giving_fields(p_type text, p_payload jsonb,
                                          out errors jsonb, out fields jsonb)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_error text;
  v_value text;
  v_steps jsonb := '[]'::jsonb;
  v_item jsonb;
  v_raw jsonb := p_payload -> 'steps';
begin
  errors := '{}'::jsonb;
  fields := '{}'::jsonb;

  select t.error, t.value into v_error, v_value from app.content_giving_text(p_payload, 'name', 60, true) t;
  errors := errors || jsonb_build_object('name', v_error);
  fields := fields || jsonb_build_object('name', v_value);
  select t.error, t.value into v_error, v_value from app.content_giving_text(p_payload, 'purpose', 60, false) t;
  errors := errors || jsonb_build_object('purpose', v_error);
  fields := fields || jsonb_build_object('purpose', v_value);
  select t.error, t.value into v_error, v_value
    from app.content_giving_code(p_payload, 'currency', 3, '^[A-Z]{3}$', true, false) t;
  errors := errors || jsonb_build_object('currency', v_error);
  fields := fields || jsonb_build_object('currency', v_value);
  select t.error, t.value into v_error, v_value from app.content_giving_text(p_payload, 'note', 200, false) t;
  errors := errors || jsonb_build_object('note', v_error);
  fields := fields || jsonb_build_object('note', v_value);
  select t.error, t.value into v_error, v_value from app.content_giving_text(p_payload, 'contact', 160, true) t;
  errors := errors || jsonb_build_object('contact', v_error);
  fields := fields || jsonb_build_object('contact', v_value);

  -- Steps: 1..12 single-line items of at most 200 characters.
  v_error := null;
  if v_raw is null or jsonb_typeof(v_raw) = 'null' then
    v_error := 'required';
  elsif jsonb_typeof(v_raw) <> 'array' then
    v_error := 'invalid';
  elsif jsonb_array_length(v_raw) = 0 then
    v_error := 'required';
  elsif jsonb_array_length(v_raw) > 12 then
    v_error := 'too_many';
  else
    for v_item in select e from jsonb_array_elements(v_raw) e loop
      select f.error, f.value into v_error, v_value from app.content_free_text(v_item, 200, false) f;
      if v_error is not null then
        exit;
      end if;
      if v_value is null then
        v_error := 'invalid';
        exit;
      end if;
      v_steps := v_steps || to_jsonb(v_value);
    end loop;
  end if;
  if v_error is not null then
    errors := errors || jsonb_build_object('steps', v_error);
    v_steps := null;
  end if;
  fields := fields || jsonb_build_object('steps', v_steps);

  if p_type in ('mobile_money', 'bank') then
    select t.error, t.value into v_error, v_value
      from app.content_giving_text(p_payload, 'beneficiary', 120, true) t;
    errors := errors || jsonb_build_object('beneficiary', v_error);
    fields := fields || jsonb_build_object('beneficiary', v_value);
  end if;

  if p_type = 'mobile_money' then
    v_raw := p_payload -> 'identifier_kind';
    v_error := null;
    v_value := null;
    if v_raw is null or jsonb_typeof(v_raw) = 'null' then
      v_error := 'required';
    elsif jsonb_typeof(v_raw) <> 'string'
          or not app.content_giving_vocab('identifier_kind', v_raw #>> '{}') then
      v_error := 'invalid';
    else
      v_value := v_raw #>> '{}';
    end if;
    errors := errors || jsonb_build_object('identifier_kind', v_error);
    fields := fields || jsonb_build_object('identifier_kind', v_value);
    select t.error, t.value into v_error, v_value
      from app.content_giving_code(p_payload, 'identifier', 40,
                                   '^[+]?[0-9A-Za-z]([0-9A-Za-z -]*[0-9A-Za-z])?$', false, true) t;
    errors := errors || jsonb_build_object('identifier', v_error);
    fields := fields || jsonb_build_object('identifier', v_value);
    select t.error, t.value into v_error, v_value
      from app.content_giving_code(p_payload, 'ussd_code', 22, '^[*][0-9*]{1,20}#$', false, false) t;
    errors := errors || jsonb_build_object('ussd_code', v_error);
    fields := fields || jsonb_build_object('ussd_code', v_value);
  elsif p_type = 'bank' then
    select t.error, t.value into v_error, v_value
      from app.content_giving_text(p_payload, 'bank_name', 80, true) t;
    errors := errors || jsonb_build_object('bank_name', v_error);
    fields := fields || jsonb_build_object('bank_name', v_value);
    select t.error, t.value into v_error, v_value
      from app.content_giving_code(p_payload, 'account_number', 34,
                                   '^[0-9A-Za-z]([0-9A-Za-z -]*[0-9A-Za-z])?$', false, true) t;
    if v_error is null and length(v_value) < 4 then
      v_error := 'invalid';
      v_value := null;
    end if;
    errors := errors || jsonb_build_object('account_number', v_error);
    fields := fields || jsonb_build_object('account_number', v_value);
    select t.error, t.value into v_error, v_value
      from app.content_giving_text(p_payload, 'branch', 80, false) t;
    errors := errors || jsonb_build_object('branch', v_error);
    fields := fields || jsonb_build_object('branch', v_value);
    select t.error, t.value into v_error, v_value
      from app.content_giving_code(p_payload, 'branch_code', 20,
                                   '^[0-9A-Za-z]([0-9A-Za-z -]*[0-9A-Za-z])?$', false, false) t;
    errors := errors || jsonb_build_object('branch_code', v_error);
    fields := fields || jsonb_build_object('branch_code', v_value);
    select t.error, t.value into v_error, v_value
      from app.content_giving_code(p_payload, 'swift_code', 11,
                                   '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$', true, false) t;
    errors := errors || jsonb_build_object('swift_code', v_error);
    fields := fields || jsonb_build_object('swift_code', v_value);
    select t.error, t.value into v_error, v_value
      from app.content_giving_text(p_payload, 'reference', 120, false) t;
    errors := errors || jsonb_build_object('reference', v_error);
    fields := fields || jsonb_build_object('reference', v_value);
  end if;
  errors := jsonb_strip_nulls(errors);
end;
$$;

-- A method_id field of a payload.
create function app.content_giving_id(p_payload jsonb, out error text, out value uuid)
language plpgsql
immutable
set search_path = ''
as $$
begin
  error := app.contract_uuid_error(p_payload -> 'method_id');
  if error is null then
    value := (p_payload ->> 'method_id')::uuid;
  end if;
end;
$$;

-- The church's date today (Africa/Lusaka, owner decision 2026-10-15).
create function app.content_church_today()
returns date
language sql
stable
set search_path = ''
as $$
  select (now() at time zone 'Africa/Lusaka')::date;
$$;

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------

create function app.content_giving_audit_event(p_action text, p_member uuid, p_account uuid,
                                               p_command text, p_item uuid, p_revision_no integer,
                                               p_position integer, p_changed_fields text[],
                                               p_revision_after bigint)
returns void
language sql
set search_path = ''
as $$
  insert into app.content_giving_audit (action, actor_member_id, actor_account_id,
                                        command_request_id, item_id, revision_no, position,
                                        changed_fields, revision_after)
  values (p_action, p_member, p_account, app.cmd_current_request_id(p_account, p_command), p_item,
          p_revision_no, p_position, p_changed_fields, p_revision_after);
$$;

-- Serialises changes of the public order (create and move): the giving_method kind row.
create function app.content_giving_lock_order()
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform 1 from app.content_kinds k where k.kind = 'giving_method' for no key update;
end;
$$;

-- A revision's fields in the shape app.content_giving_fields answers (to compare a save with it).
create function app.content_giving_revision_fields(p app.content_giving_revisions)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('name', p.name, 'purpose', p.purpose, 'currency', p.currency,
                            'note', p.note, 'contact', p.contact, 'steps', to_jsonb(p.steps))
         || case p.method_type
              when 'mobile_money' then jsonb_build_object(
                'beneficiary', p.beneficiary, 'identifier_kind', p.identifier_kind,
                'identifier', p.identifier, 'ussd_code', p.ussd_code)
              when 'bank' then jsonb_build_object(
                'beneficiary', p.beneficiary, 'bank_name', p.bank_name,
                'account_number', p.account_number, 'branch', p.branch,
                'branch_code', p.branch_code, 'swift_code', p.swift_code, 'reference', p.reference)
              else '{}'::jsonb end;
$$;

-- The names of the fields whose values differ between two field sets (sorted; null when none).
create function app.content_giving_changed_fields(p_old jsonb, p_new jsonb)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array_agg(n.key order by n.key)
    from jsonb_each(p_new) n
   where n.value is distinct from coalesce(p_old -> n.key, 'null'::jsonb);
$$;

-- Writes a method's revision p_no from validated fields: a new draft, or the open draft
-- overwritten. Every save records its saver (last saver and every saver) and clears the
-- revision's verification.
create function app.content_giving_write_revision(p_item uuid, p_no integer, p_type text,
                                                  p_fields jsonb, p_member uuid, p_account uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_steps text[] := array(select jsonb_array_elements_text(p_fields -> 'steps'));
begin
  insert into app.content_giving_revisions as r (
    item_id, revision_no, method_type, name, purpose, currency, beneficiary, identifier_kind,
    identifier, bank_name, account_number, branch, branch_code, swift_code, reference, ussd_code,
    steps, note, contact, saved_by_member, saved_by_account, saved_by_members, saved_by_accounts)
  values (
    p_item, p_no, p_type, p_fields ->> 'name', p_fields ->> 'purpose', p_fields ->> 'currency',
    p_fields ->> 'beneficiary', p_fields ->> 'identifier_kind', p_fields ->> 'identifier',
    p_fields ->> 'bank_name', p_fields ->> 'account_number', p_fields ->> 'branch',
    p_fields ->> 'branch_code', p_fields ->> 'swift_code', p_fields ->> 'reference',
    p_fields ->> 'ussd_code', v_steps, p_fields ->> 'note', p_fields ->> 'contact', p_member,
    p_account, array[p_member], array[p_account])
  on conflict (item_id, revision_no) do update
     set name = excluded.name,
         purpose = excluded.purpose,
         currency = excluded.currency,
         beneficiary = excluded.beneficiary,
         identifier_kind = excluded.identifier_kind,
         identifier = excluded.identifier,
         bank_name = excluded.bank_name,
         account_number = excluded.account_number,
         branch = excluded.branch,
         branch_code = excluded.branch_code,
         swift_code = excluded.swift_code,
         reference = excluded.reference,
         ussd_code = excluded.ussd_code,
         steps = excluded.steps,
         note = excluded.note,
         contact = excluded.contact,
         saved_by_member = excluded.saved_by_member,
         saved_by_account = excluded.saved_by_account,
         saved_by_members = case when excluded.saved_by_member = any (r.saved_by_members)
                                 then r.saved_by_members
                                 else r.saved_by_members || excluded.saved_by_member end,
         saved_by_accounts = case when excluded.saved_by_account = any (r.saved_by_accounts)
                                  then r.saved_by_accounts
                                  else r.saved_by_accounts || excluded.saved_by_account end,
         saved_at = now(),
         verified_at = null,
         verified_by_member = null,
         verified_by_account = null,
         tested_on = null,
         test_method = null
   where r.published_at is null;
end;
$$;

-- Bumps an item's aggregate revision for a giving-only change (verify, move). Returns it.
create function app.content_giving_touch(p_item uuid)
returns bigint
language sql
set search_path = ''
as $$
  update app.content_items i set revision = i.revision + 1, updated_at = now()
   where i.item_id = p_item
  returning i.revision;
$$;

-- ---------------------------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------------------------

-- content.create_giving_method {method_type, ...the type's fields}; expected null. A new private
-- draft (revision 1, unverified), last in the order. Admin only.
create function app.content_giving_create(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_type text;
  v_errors jsonb := '{}'::jsonb;
  v_fields record;
  v_item uuid;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'giving_method') a;
  if jsonb_typeof(p_payload -> 'method_type') = 'string'
     and app.content_giving_vocab('method_type', p_payload ->> 'method_type') then
    v_type := p_payload ->> 'method_type';
    v_errors := app.contract_unknown_keys(p_payload, array['method_type'] || app.content_giving_keys(v_type));
    select f.* into v_fields from app.content_giving_fields(v_type, p_payload) f;
    v_errors := v_errors || v_fields.errors;
  else
    v_errors := jsonb_build_object('method_type',
                  case when p_payload -> 'method_type' is null
                         or jsonb_typeof(p_payload -> 'method_type') = 'null'
                       then 'required' else 'invalid' end)
                || app.contract_unknown_keys(p_payload,
                     array['method_type'] || app.content_giving_keys('mobile_money')
                     || app.content_giving_keys('bank'));
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.content_giving_lock_order();
  v_item := app.content_item_open('giving_method', v_actor.member_id, v_actor.account_id,
                                  v_actor.capacity, 'content.create_giving_method');
  insert into app.content_giving_methods (item_id, method_type, sort_order)
  values (v_item, v_type,
          coalesce((select max(g.sort_order) from app.content_giving_methods g
                     join app.content_items i on i.item_id = g.item_id
                    where i.lifecycle_state <> 'archived'), 0) + 1);
  perform app.content_giving_write_revision(v_item, 1, v_type, v_fields.fields, v_actor.member_id,
                                            v_actor.account_id);
  perform app.content_giving_audit_event('saved', v_actor.member_id, v_actor.account_id,
                                         'content.create_giving_method', v_item, 1, null,
                                         app.content_giving_changed_fields('{}'::jsonb,
                                                                           v_fields.fields),
                                         1);
  return app.content_item_outcome(v_item, 'method_id');
end;
$$;

-- content.save_giving_method {method_id, ...the type's fields}; expected = the method's revision.
-- Writes the open draft (or opens the next revision of a published or hidden method), records the
-- saver and clears the draft's verification. The live revision stays public.
create function app.content_giving_save(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_error text;
  v_id uuid;
  v_type text;
  v_errors jsonb;
  v_fields record;
  v_item app.content_items;
  v_no integer;
  v_base jsonb;
  v_changed text[];
  v_revision bigint;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'giving_method') a;
  select t.error, t.value into v_error, v_id from app.content_giving_id(p_payload) t;
  if v_error is not null then
    perform app.cmd_fail('validation_failed', jsonb_build_object('method_id', v_error));
  end if;
  select g.method_type into v_type from app.content_giving_methods g where g.item_id = v_id;
  if v_type is null then
    perform app.cmd_fail('not_found');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, array['method_id'] || app.content_giving_keys(v_type));
  select f.* into v_fields from app.content_giving_fields(v_type, p_payload) f;
  v_errors := v_errors || v_fields.errors;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_lock(v_id, 'giving_method', p_expected_revision, 'method_id');
  -- What the save changes: against the open draft, else the live revision. A save that changes
  -- nothing is refused (it would only make its Admin a saver of the draft).
  select app.content_giving_revision_fields(r) into v_base
    from app.content_giving_revisions r
   where r.item_id = v_id and r.revision_no = coalesce(v_item.draft_revision_no, v_item.live_revision_no);
  v_changed := app.content_giving_changed_fields(v_base, v_fields.fields);
  if v_changed is null then
    perform app.cmd_fail('validation_failed', '{"method_id": "unchanged"}');
  end if;
  v_no := app.content_item_draft_no(v_item);
  perform app.content_giving_write_revision(v_id, v_no, v_type, v_fields.fields, v_actor.member_id,
                                            v_actor.account_id);
  v_revision := app.content_item_saved(v_item, v_no, v_actor.member_id, v_actor.account_id,
                                       v_actor.capacity, 'content.save_giving_method');
  perform app.content_giving_audit_event('saved', v_actor.member_id, v_actor.account_id,
                                         'content.save_giving_method', v_id, v_no, null, v_changed,
                                         v_revision);
  return app.content_item_outcome(v_id, 'method_id');
end;
$$;

-- content.verify_giving_method {method_id, tested_on, test_method}; expected = the method's
-- revision. Records the church verification of the open draft: by an Admin who did not last save
-- it, with the church date the details were tested (today or up to 90 days back) and how.
create function app.content_giving_verify(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_error text;
  v_id uuid;
  v_errors jsonb;
  v_raw jsonb := p_payload -> 'tested_on';
  v_tested date;
  v_how text;
  v_item app.content_items;
  v_draft app.content_giving_revisions;
  v_revision bigint;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'giving_method') a;
  v_errors := app.contract_unknown_keys(p_payload, array['method_id', 'tested_on', 'test_method']);
  select t.error, t.value into v_error, v_id from app.content_giving_id(p_payload) t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('method_id', v_error);
  end if;
  v_error := null;
  if v_raw is null or jsonb_typeof(v_raw) = 'null' then
    v_error := 'required';
  elsif jsonb_typeof(v_raw) <> 'string' or (v_raw #>> '{}') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    v_error := 'invalid';
  else
    begin
      v_tested := (v_raw #>> '{}')::date;
    exception when others then
      v_error := 'invalid';
    end;
    if v_error is null
       and (v_tested > app.content_church_today()
            or v_tested < app.content_church_today() - 90) then
      v_error := 'out_of_range';
    end if;
  end if;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('tested_on', v_error);
  end if;
  select t.error, t.value into v_error, v_how from app.content_free_text(p_payload -> 'test_method', 500, true) t;
  if v_error is null and v_how is null then
    v_error := 'required';
  end if;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('test_method', v_error);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_lock(v_id, 'giving_method', p_expected_revision, 'method_id');
  if v_item.draft_revision_no is null then
    perform app.cmd_fail('validation_failed', '{"method_id": "nothing_to_verify"}');
  end if;
  select r.* into v_draft from app.content_giving_revisions r
   where r.item_id = v_id and r.revision_no = v_item.draft_revision_no
     for update;
  if v_draft.verified_at is not null then
    perform app.cmd_fail('validation_failed', '{"method_id": "already_verified"}');
  end if;
  if v_actor.member_id = any (v_draft.saved_by_members)
     or v_actor.account_id = any (v_draft.saved_by_accounts) then
    perform app.cmd_fail('validation_failed', '{"method_id": "saved_by_you"}');
  end if;
  -- The test vouches for these details, so it happened on or after the day they were saved.
  if v_tested < (v_draft.saved_at at time zone 'Africa/Lusaka')::date then
    perform app.cmd_fail('validation_failed', '{"tested_on": "before_saved"}');
  end if;
  update app.content_giving_revisions r
     set verified_at = now(),
         verified_by_member = v_actor.member_id,
         verified_by_account = v_actor.account_id,
         tested_on = v_tested,
         test_method = v_how
   where r.item_id = v_id and r.revision_no = v_item.draft_revision_no;
  v_revision := app.content_giving_touch(v_id);
  perform app.content_giving_audit_event('verified', v_actor.member_id, v_actor.account_id,
                                         'content.verify_giving_method', v_id,
                                         v_item.draft_revision_no, null, null, v_revision);
  return app.content_item_outcome(v_id, 'method_id');
end;
$$;

-- content.publish_giving_method {method_id}; expected = the method's revision. The verified open
-- draft goes live (or a hidden method's live revision comes back). The q3_giving gate must be
-- open; under a sample_only value the method's name starts with "SAMPLE ".
create function app.content_giving_publish(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  v_gate jsonb;
  v_no integer;
  v_rev app.content_giving_revisions;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'giving_method') a;
  v_errors := app.contract_unknown_keys(p_payload, array['method_id']);
  select t.error, t.value into v_error, v_id from app.content_giving_id(p_payload) t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('method_id', v_error);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_lock(v_id, 'giving_method', p_expected_revision, 'method_id');
  -- Q3: closed in production until Israel approves it (unavailable {policy: gate_closed}).
  v_gate := app.policy_effective('q3_giving');
  v_no := coalesce(v_item.draft_revision_no,
                   case when v_item.lifecycle_state = 'withdrawn' then v_item.live_revision_no end);
  if v_no is not null then
    select r.* into v_rev from app.content_giving_revisions r
     where r.item_id = v_id and r.revision_no = v_no;
    if v_rev.verified_at is null then
      perform app.cmd_fail('validation_failed', '{"method_id": "not_verified"}');
    end if;
    if (v_gate -> 'value' ->> 'sample_only') = 'true' and v_rev.name not like 'SAMPLE %' then
      perform app.cmd_fail('validation_failed', '{"name": "sample_only"}');
    end if;
  end if;
  v_no := app.content_item_publish(v_item, v_actor.member_id, v_actor.account_id, v_actor.capacity,
                                   'content.publish_giving_method', 'method_id');
  -- A revision published again after hiding keeps its first publication.
  update app.content_giving_revisions r
     set published_at = now(),
         published_by_member = v_actor.member_id,
         published_by_account = v_actor.account_id
   where r.item_id = v_id and r.revision_no = v_no and r.published_at is null;
  return app.content_item_outcome(v_id, 'method_id');
end;
$$;

-- content.hide_giving_method {method_id}; expected = the method's revision. A published method
-- leaves every public read (it stays republishable).
create function app.content_giving_hide(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  select a.* into v_actor from app.content_command_actor(p_actor, 'giving_method') a;
  v_errors := app.contract_unknown_keys(p_payload, array['method_id']);
  select t.error, t.value into v_error, v_id from app.content_giving_id(p_payload) t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('method_id', v_error);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_lock(v_id, 'giving_method', p_expected_revision, 'method_id');
  perform app.content_item_withdraw(v_item, v_actor.member_id, v_actor.account_id,
                                    v_actor.capacity, 'content.hide_giving_method', 'method_id');
  return app.content_item_outcome(v_id, 'method_id');
end;
$$;

-- content.archive_giving_method {method_id}; expected = the method's revision. Retires it from
-- any state; it leaves the order and refuses every later command.
create function app.content_giving_archive(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  select a.* into v_actor from app.content_command_actor(p_actor, 'giving_method') a;
  v_errors := app.contract_unknown_keys(p_payload, array['method_id']);
  select t.error, t.value into v_error, v_id from app.content_giving_id(p_payload) t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('method_id', v_error);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_lock(v_id, 'giving_method', p_expected_revision, 'method_id');
  perform app.content_item_archive(v_item, v_actor.member_id, v_actor.account_id,
                                   v_actor.capacity, 'content.archive_giving_method');
  return app.content_item_outcome(v_id, 'method_id');
end;
$$;

-- content.move_giving_method {method_id, position}; expected = the method's revision. Moves a
-- method to a 1-based position among the methods that are not archived; the public order follows
-- at once. Moving to its own position changes nothing.
create function app.content_giving_move(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_error text;
  v_id uuid;
  v_raw jsonb := p_payload -> 'position';
  v_position integer;
  v_item app.content_items;
  v_order uuid[];
  v_current integer;
  v_revision bigint;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'giving_method') a;
  v_errors := app.contract_unknown_keys(p_payload, array['method_id', 'position']);
  select t.error, t.value into v_error, v_id from app.content_giving_id(p_payload) t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('method_id', v_error);
  end if;
  if v_raw is null or jsonb_typeof(v_raw) = 'null' then
    v_errors := v_errors || '{"position": "required"}'::jsonb;
  elsif jsonb_typeof(v_raw) <> 'number' or (v_raw #>> '{}') !~ '^[0-9]{1,4}$' then
    v_errors := v_errors || '{"position": "invalid"}'::jsonb;
  else
    v_position := (v_raw #>> '{}')::integer;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  perform app.content_giving_lock_order();
  v_item := app.content_item_lock(v_id, 'giving_method', p_expected_revision, 'method_id');
  select array_agg(g.item_id order by g.sort_order, i.created_at, g.item_id) into v_order
    from app.content_giving_methods g
    join app.content_items i on i.item_id = g.item_id
   where i.lifecycle_state <> 'archived';
  if v_position < 1 or v_position > cardinality(v_order) then
    perform app.cmd_fail('validation_failed', '{"position": "out_of_range"}');
  end if;
  v_current := array_position(v_order, v_id);
  if v_current = v_position then
    return app.content_item_outcome(v_id, 'method_id');
  end if;
  v_order := array_remove(v_order, v_id);
  v_order := v_order[1:v_position - 1] || v_id || v_order[v_position:];
  update app.content_giving_methods g
     set sort_order = o.n
    from unnest(v_order) with ordinality as o (item_id, n)
   where g.item_id = o.item_id and g.sort_order is distinct from o.n::integer;
  v_revision := app.content_giving_touch(v_id);
  perform app.content_giving_audit_event('reordered', v_actor.member_id, v_actor.account_id,
                                         'content.move_giving_method', v_id, null, v_position,
                                         null, v_revision);
  return app.content_item_outcome(v_id, 'method_id');
end;
$$;

-- content.discard_giving_draft {method_id}; expected = the method's revision. Drops the open
-- draft of a method that has a live revision (published or hidden): givers keep the live
-- details, and the next save opens a new revision whose savers start afresh. The discarded
-- revision row is kept (never public, never deleted). A never-published method is archived
-- instead.
create function app.content_giving_discard(p_actor uuid, p_expected_revision bigint, p_payload jsonb)
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
  v_revision bigint;
begin
  select a.* into v_actor from app.content_command_actor(p_actor, 'giving_method') a;
  v_errors := app.contract_unknown_keys(p_payload, array['method_id']);
  select t.error, t.value into v_error, v_id from app.content_giving_id(p_payload) t;
  if v_error is not null then
    v_errors := v_errors || jsonb_build_object('method_id', v_error);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_item := app.content_item_lock(v_id, 'giving_method', p_expected_revision, 'method_id');
  if v_item.draft_revision_no is null then
    perform app.cmd_fail('validation_failed', '{"method_id": "nothing_to_discard"}');
  end if;
  if v_item.live_revision_no is null then
    perform app.cmd_fail('validation_failed', '{"method_id": "never_published"}');
  end if;
  update app.content_items i
     set draft_revision_no = null,
         revision = i.revision + 1,
         updated_at = now()
   where i.item_id = v_id
  returning i.revision into v_revision;
  perform app.content_giving_audit_event('draft_discarded', v_actor.member_id, v_actor.account_id,
                                         'content.discard_giving_draft', v_id,
                                         v_item.draft_revision_no, null, null, v_revision);
  return app.content_item_outcome(v_id, 'method_id');
end;
$$;

select app.content_register_command('content.create_giving_method', 'giving_method',
  'app.content_giving_create(uuid, bigint, jsonb)'::regprocedure, true);
select app.content_register_command('content.save_giving_method', 'giving_method',
  'app.content_giving_save(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.verify_giving_method', 'giving_method',
  'app.content_giving_verify(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.publish_giving_method', 'giving_method',
  'app.content_giving_publish(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.hide_giving_method', 'giving_method',
  'app.content_giving_hide(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.archive_giving_method', 'giving_method',
  'app.content_giving_archive(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.move_giving_method', 'giving_method',
  'app.content_giving_move(uuid, bigint, jsonb)'::regprocedure, false);
select app.content_register_command('content.discard_giving_draft', 'giving_method',
  'app.content_giving_discard(uuid, bigint, jsonb)'::regprocedure, false);

-- ---------------------------------------------------------------------------------------------
-- The public read contract (anonymous): the live revisions' giver-facing fields only
-- ---------------------------------------------------------------------------------------------

-- The copyable destination values of a revision, in display order (present ones only).
create function app.content_giving_details(p app.content_giving_revisions)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', d.key, 'value', d.value) order by d.ord),
                  '[]'::jsonb)
    from (values
      (1, 'bank_name', p.bank_name),
      (2, 'beneficiary', p.beneficiary),
      (3, case p.identifier_kind when 'merchant' then 'merchant_id' when 'till' then 'till_number'
                                 when 'phone' then 'phone_number' end, p.identifier),
      (4, 'account_number', p.account_number),
      (5, 'branch', p.branch),
      (6, 'branch_code', p.branch_code),
      (7, 'swift_code', p.swift_code),
      (8, 'reference', p.reference)) d (ord, key, value)
   where d.value is not null;
$$;

-- One published method as anyone may read it: no draft, verifier, test note, editor identity or
-- audit field. Null for anything else (unknown, draft only, hidden or archived).
create function app.content_giving_public_json(p_item_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'method_id', i.item_id,
    'method_type', g.method_type,
    'name', r.name,
    'purpose', r.purpose,
    'currency', r.currency,
    'details', app.content_giving_details(r),
    'ussd_code', r.ussd_code,
    'steps', to_jsonb(r.steps),
    'note', r.note,
    'contact', r.contact,
    'verified_on', to_char(r.tested_on, 'YYYY-MM-DD'),
    'publication_revision', r.revision_no,
    'published_at', app.cmd_utc(i.published_at))
    from app.content_items i
    join app.content_giving_methods g on g.item_id = i.item_id
    join app.content_giving_revisions r on r.item_id = i.item_id and r.revision_no = i.live_revision_no
   where i.item_id = p_item_id and i.kind = 'giving_method' and i.lifecycle_state = 'published'
     and r.verified_at is not null;
$$;

-- Off production every method is a SAMPLE (the app shows the sample banner).
create function app.content_giving_sample()
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.platform_current_environment() is distinct from 'production';
$$;

-- The published methods in the church's order; at most 50 (`truncated` says more exist).
create function app.content_public_giving_methods()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with live as (
    select i.item_id, row_number() over (order by g.sort_order, i.created_at, i.item_id) as rn
      from app.content_items i
      join app.content_giving_methods g on g.item_id = i.item_id
     where i.kind = 'giving_method' and i.lifecycle_state = 'published')
  select jsonb_build_object(
           'sample', app.content_giving_sample(),
           'methods', coalesce(jsonb_agg(app.content_giving_public_json(l.item_id) order by l.rn)
                                 filter (where l.rn <= 50), '[]'::jsonb),
           'truncated', count(*) > 50)
    from live l;
$$;

-- One published method, or {"method": null} for an unknown, draft-only, hidden or archived id.
create function app.content_public_giving_method(p_method_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('sample', app.content_giving_sample(),
                            'method', app.content_giving_public_json(p_method_id));
$$;

create function api.content_public_giving_methods()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select app.content_public_giving_methods();
$$;

comment on function api.content_public_giving_methods() is
  'Story 6.3, public (anon and authenticated): the published giving methods in the church''s order.';

create function api.content_public_giving_method(method_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select app.content_public_giving_method($1);
$$;

comment on function api.content_public_giving_method(uuid) is
  'Story 6.3, public (anon and authenticated): one published giving method, or null.';

-- ---------------------------------------------------------------------------------------------
-- The Admins' read
-- ---------------------------------------------------------------------------------------------

create function app.content_giving_revision_json(p_item_id uuid, p_revision_no integer,
                                                 p_member uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
           'revision_no', r.revision_no,
           'name', r.name,
           'purpose', r.purpose,
           'currency', r.currency,
           'steps', to_jsonb(r.steps),
           'note', r.note,
           'contact', r.contact,
           'saved_at', app.cmd_utc(r.saved_at),
           'saved_by', app.content_editor_name(r.saved_by_member),
           'saved_by_you', p_member = any (r.saved_by_members),
           'published_at', app.cmd_utc(r.published_at),
           'published_by', case when r.published_by_member is not null
                                then app.content_editor_name(r.published_by_member) end,
           'verification', case when r.verified_at is not null then jsonb_build_object(
             'verified_at', app.cmd_utc(r.verified_at),
             'verified_by', app.content_editor_name(r.verified_by_member),
             'verified_by_you', r.verified_by_member = p_member,
             'tested_on', to_char(r.tested_on, 'YYYY-MM-DD'),
             'test_method', r.test_method) end)
         || case r.method_type
              when 'mobile_money' then jsonb_build_object(
                'beneficiary', r.beneficiary, 'identifier_kind', r.identifier_kind,
                'identifier', r.identifier, 'ussd_code', r.ussd_code)
              when 'bank' then jsonb_build_object(
                'bank_name', r.bank_name, 'beneficiary', r.beneficiary,
                'account_number', r.account_number, 'branch', r.branch,
                'branch_code', r.branch_code, 'swift_code', r.swift_code,
                'reference', r.reference)
              else '{}'::jsonb end
    from app.content_giving_revisions r
   where r.item_id = p_item_id and r.revision_no = p_revision_no;
$$;

create function app.content_staff_giving_json(p_item_id uuid, p_position bigint, p_member uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'method_id', i.item_id,
    'method_type', g.method_type,
    'position', p_position,
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
                 then app.content_giving_revision_json(i.item_id, i.live_revision_no, p_member) end,
    'draft', case when i.draft_revision_no is not null
                  then app.content_giving_revision_json(i.item_id, i.draft_revision_no, p_member) end)
    from app.content_items i
    join app.content_giving_methods g on g.item_id = i.item_id
   where i.item_id = p_item_id;
$$;

-- Every giving method with its live and draft revisions, verification and attribution, for
-- Admins only: the methods in the public order, then the archived ones (latest first); at most 200.
create function app.content_staff_giving_methods()
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
  v_capacity := app.content_editor_capacity(v_member, 'giving_method');
  if v_capacity is null then
    raise exception using errcode = 'PT403', message = 'forbidden', detail = 'not_granted';
  end if;
  with ranked as (
    select i.item_id,
           case when i.lifecycle_state <> 'archived' then
             row_number() over (partition by (i.lifecycle_state = 'archived')
                                order by g.sort_order, i.created_at, i.item_id) end as position,
           row_number() over (order by (i.lifecycle_state = 'archived'),
                                       case when i.lifecycle_state <> 'archived' then g.sort_order end,
                                       i.archived_at desc, i.created_at, i.item_id) as rn
      from app.content_items i
      join app.content_giving_methods g on g.item_id = i.item_id
     where i.kind = 'giving_method')
  select jsonb_build_object(
           'capacity', v_capacity,
           'methods', coalesce(jsonb_agg(app.content_staff_giving_json(k.item_id, k.position, v_member)
                                         order by k.rn) filter (where k.rn <= 200), '[]'::jsonb),
           'truncated', count(*) > 200)
    into v_result
    from ranked k;
  perform app.identity_record_activity(v_link);
  return v_result;
end;
$$;

create function api.content_staff_giving_methods()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.content_staff_giving_methods();
$$;

comment on function api.content_staff_giving_methods() is
  'Story 6.3: every giving method with its live and draft revisions and verification, for Admins.';

-- ---------------------------------------------------------------------------------------------
-- The giving erase part of Content's deletion hook (story 2.11 contract, story 6.1 registry)
-- ---------------------------------------------------------------------------------------------

-- Saved, verified and published attribution and the giving audit actors become the nil UUID
-- (published revisions keep their content; the guard allows attribution changes only).
create function app.content_giving_erase_part(p_input jsonb)
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
    -- One statement per row, so the last saver and the savers list change together.
    update app.content_giving_revisions r
       set saved_by_member = case when r.saved_by_member = v_member then v_nil else r.saved_by_member end,
           saved_by_members = array_replace(r.saved_by_members, v_member, v_nil),
           verified_by_member = case when r.verified_by_member = v_member then v_nil
                                     else r.verified_by_member end,
           published_by_member = case when r.published_by_member = v_member then v_nil
                                      else r.published_by_member end
     where v_member = any (r.saved_by_members) or r.verified_by_member = v_member
        or r.published_by_member = v_member;
    update app.content_giving_audit a set actor_member_id = v_nil where a.actor_member_id = v_member;
    if v_account is not null then
      update app.content_giving_revisions r
         set saved_by_account = case when r.saved_by_account = v_account then v_nil
                                     else r.saved_by_account end,
             saved_by_accounts = array_replace(r.saved_by_accounts, v_account, v_nil),
             verified_by_account = case when r.verified_by_account = v_account then v_nil
                                        else r.verified_by_account end,
             published_by_account = case when r.published_by_account = v_account then v_nil
                                         else r.published_by_account end
       where v_account = any (r.saved_by_accounts) or r.verified_by_account = v_account
          or r.published_by_account = v_account;
      update app.content_giving_audit a set actor_account_id = v_nil
       where a.actor_account_id = v_account;
    end if;
  end if;
  return ((select count(*) from app.content_giving_revisions r
            where v_member = any (r.saved_by_members) or r.saved_by_member = v_member
               or r.verified_by_member = v_member or r.published_by_member = v_member
               or v_account = any (r.saved_by_accounts) or r.saved_by_account = v_account
               or r.verified_by_account = v_account or r.published_by_account = v_account)
        + (select count(*) from app.content_giving_audit a
            where a.actor_member_id = v_member or a.actor_account_id = v_account))::integer;
end;
$$;

select app.content_register_erase_part('giving_methods',
  'app.content_giving_erase_part(jsonb)'::regprocedure);

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.content_giving_vocab(text, text),
  app.content_giving_text_ok(text, integer),
  app.content_giving_steps_ok(text[]),
  app.content_giving_only_anonymised(uuid[], uuid[]),
  app.content_giving_revision_guard(),
  app.content_giving_keys(text),
  app.content_giving_text(jsonb, text, integer, boolean),
  app.content_giving_code(jsonb, text, integer, text, boolean, boolean),
  app.content_giving_fields(text, jsonb),
  app.content_giving_id(jsonb),
  app.content_church_today(),
  app.content_giving_audit_event(text, uuid, uuid, text, uuid, integer, integer, text[], bigint),
  app.content_giving_lock_order(),
  app.content_giving_revision_fields(app.content_giving_revisions),
  app.content_giving_changed_fields(jsonb, jsonb),
  app.content_giving_write_revision(uuid, integer, text, jsonb, uuid, uuid),
  app.content_giving_touch(uuid),
  app.content_giving_create(uuid, bigint, jsonb),
  app.content_giving_save(uuid, bigint, jsonb),
  app.content_giving_verify(uuid, bigint, jsonb),
  app.content_giving_publish(uuid, bigint, jsonb),
  app.content_giving_hide(uuid, bigint, jsonb),
  app.content_giving_archive(uuid, bigint, jsonb),
  app.content_giving_move(uuid, bigint, jsonb),
  app.content_giving_discard(uuid, bigint, jsonb),
  app.content_giving_details(app.content_giving_revisions),
  app.content_giving_public_json(uuid),
  app.content_giving_sample(),
  app.content_public_giving_methods(),
  app.content_public_giving_method(uuid),
  api.content_public_giving_methods(),
  api.content_public_giving_method(uuid),
  app.content_giving_revision_json(uuid, integer, uuid),
  app.content_staff_giving_json(uuid, bigint, uuid),
  app.content_staff_giving_methods(),
  api.content_staff_giving_methods(),
  app.content_giving_erase_part(jsonb)
  from public, anon, authenticated, service_role;

grant execute on function app.content_public_giving_methods() to anon, authenticated;
grant execute on function api.content_public_giving_methods() to anon, authenticated;
grant execute on function app.content_public_giving_method(uuid) to anon, authenticated;
grant execute on function api.content_public_giving_method(uuid) to anon, authenticated;
grant execute on function app.content_staff_giving_methods() to authenticated;
grant execute on function api.content_staff_giving_methods() to authenticated;

notify pgrst, 'reload schema';
