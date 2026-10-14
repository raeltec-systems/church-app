-- Review applications and link existing or accountless members (story 2.5; AD-1, AD-2, AD-3,
-- AD-4, AD-14, AD-19, AD-20).
--
-- Builds on the live-access predicate app.identity_access_evaluate() (2.1/2.2/2.3), the grant
-- helpers (2.3) and the membership applications (2.4); nothing here forks them.
--
--   * Admin review commands, 1.4 envelope, through api.identity_review_command. The registered
--     `identity` authorizer (replaced below, grant and application branches unchanged) admits
--     them only for a live Admin (identity_evaluate_grant('admin')), serialised on the admin
--     catalogue row like the grant commands:
--       identity.approve_application        expected = application revision
--         {application_id, identity_check}            -> a NEW approved member linked to the
--                                                        applicant's account
--       identity.link_application           expected = application revision
--         {application_id, member_id, identity_check} -> the applicant's account linked to an
--                                                        EXISTING member (id and history kept)
--       identity.request_application_details expected = application revision
--         {application_id, requested[], identity_check?}
--       identity.reject_application         expected = application revision
--         {application_id, reason?, identity_check?}
--       identity.create_member              expected null
--         {full_name, consent_basis, assisted_by_member_id?, contact_route?{phone, belongs_to,
--          holder_label?}}                            -> an approved member WITHOUT a login
--       identity.unlink_account             expected = member revision
--         {member_id, reason}                         -> ends the member's live account link
--       identity.reclaim_phone_username     expected null
--         {phone_username, identity_check, reason?}   -> releases a phone username held by an
--                                                        UNLINKED Auth account (F1)
--   * Linking (approve or link) writes the approved binding: the applicant account's CURRENT Auth
--     phone, which must still equal the phone username it applied with, and its current email.
--     An UNCONFIRMED Auth email refuses the link (`validation_failed {"recovery_email":
--     "unverified"}`); the Admin then asks for details with the applicant-visible code
--     `recovery_email` ("confirm your email or remove it"). Binding history revision 1; a
--     session trust epoch at
--     the link (sessions_valid_after), so no session opened before the approval passes the
--     predicate (sign in again). The 2.1 unique indexes keep one live link per member, per
--     account and per phone username; a violation is `conflict`. An account that was ever
--     linked to a member with an open hold is refused (`forbidden {"application_id":
--     "not_applicant"}`, the 2.4 identity_applicant_outcome rule).
--   * Grants never travel with an account link: unlinking ends every active grant of the
--     member through the 2.3 end-grant path (role_revoked / scope_revoked audit rows with the
--     acting Admin, scope_revoked dispatched), still refusing to remove the last usable Admin;
--     link-existing refuses a member that holds any active grant. A relinked member starts with
--     no grants; roles come back only through the audited 2.3 commands (lead_pastor only by the
--     operator).
--   * Separation of duty: an Admin cannot decide an application from their own account, link
--     to or unlink their own member, or reclaim their own account's username. Unlinking the
--     last usable Admin is refused.
--   * Admin reads: api.identity_admin_application_queue (open applications with STAFF-ONLY
--     duplicate candidates: same or similar name, a contact route or a live link with the same
--     phone) and api.identity_admin_member_search. Applicants never see candidates.
--   * Content-free audit app.identity_membership_audit: ids, codes and revisions only.
--   * Applicant's decided status: identity_application_json gains decision_reason (code),
--     details_requested (field codes) and reapply_from. Re-applying after a rejection is a NEW
--     application, allowed 7 days after the decision (app.identity_reapply_cooldown()); earlier
--     is `rate_limited`. The guard is a BEFORE INSERT trigger, so it covers every insert path
--     into app.identity_membership_applications, not only identity.submit_application. The
--     queue's prior_not_approved counts the account's rejected and withdrawn requests.
--   * Accountless members: provenance (who recorded them, consent basis, assisting member) and
--     optional labelled contact routes. A contact route is NEVER an account lookup: no access
--     path reads it, and it only feeds the Admin duplicate aid.
--   * Reclaim (F1, owner decision 2026-10-06): behind the personal-data gate; while Q4 is
--     unapproved the number must be fictional. The Auth account holding the username (stored
--     with or without '+') must have no live link (otherwise `conflict`: the Admin unlinks it
--     first, explicitly). Identity then, in the same transaction, clears that account's phone,
--     bans it (100 years, GoTrue's own ban form) and withdraws its open application. Revoking
--     the holder's Auth sessions and refresh tokens is added by the follow-up migration
--     20261007131600_membership_review_reclaim_sessions.sql (kept separate so this file holds
--     no row-deleting statement for the hosted connector). Nothing is merged or linked; the
--     case is recorded. The restricted operator can undo a reclaim with
--     app.identity_undo_phone_reclaim(reclaim_id, operator) while the number is still free.
--
-- Personal data stays behind the 2.4 gate app.identity_applications_open(); while Q4 is
-- unapproved, names must start with `SYNTHETIC ` and phone numbers must be fictional.
--
-- No destructive statements. No client table privileges.

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

create table app.identity_member_provenance (
  member_id uuid primary key references app.identity_members (member_id),
  origin text not null check (origin in ('application', 'admin_record')),
  application_id uuid references app.identity_membership_applications (application_id),
  consent_basis text check (consent_basis in ('in_person', 'leader_assisted')),
  assisted_by_member uuid references app.identity_members (member_id),
  identity_check text check (identity_check in ('established_relationship', 'in_person')),
  recorded_by_member uuid not null references app.identity_members (member_id),
  recorded_by_account uuid not null,
  request_id uuid,
  recorded_at timestamptz not null default now(),
  check ((origin = 'application') = (application_id is not null)),
  check ((origin = 'admin_record') = (consent_basis is not null)),
  check (assisted_by_member is null or consent_basis = 'leader_assisted'),
  check (origin <> 'application' or identity_check is not null)
);

comment on table app.identity_member_provenance is
  'owner: identity. Who recorded a member and on what basis (application approval, or an Admin '
  'record made with the person''s consent). Members seeded by the operator have no row.';

create table app.identity_contact_routes (
  route_id uuid primary key default gen_random_uuid(),
  member_id uuid not null references app.identity_members (member_id),
  kind text not null default 'phone' check (kind = 'phone'),
  value text not null check (value ~ '^\+[1-9][0-9]{7,14}$'),
  -- Whose number it is: a relative's or household number is labelled as such (FR "Members
  -- without a usable personal account").
  belongs_to text not null check (belongs_to in ('member', 'relative', 'household', 'other')),
  holder_label text check (holder_label is null or (holder_label = btrim(holder_label)
                           and length(holder_label) between 1 and 60
                           and holder_label !~ '[[:cntrl:]]')),
  is_synthetic boolean not null,
  created_by_member uuid not null references app.identity_members (member_id),
  created_by_account uuid not null,
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  check (belongs_to = 'member' or holder_label is not null)
);

comment on table app.identity_contact_routes is
  'owner: identity. Agreed contact routes of a member. NEVER an account lookup, credential or '
  'ownership rule; a shared number may appear on several members. Staff duplicate aid only.';

create index identity_contact_routes_member on app.identity_contact_routes (member_id)
  where ended_at is null;
create index identity_contact_routes_value on app.identity_contact_routes (value)
  where ended_at is null;

create table app.identity_phone_reclaims (
  reclaim_id uuid primary key default gen_random_uuid(),
  phone_username text not null check (phone_username ~ '^\+[1-9][0-9]{7,14}$'),
  released_account_id uuid not null,
  identity_check text not null check (identity_check in ('established_relationship', 'in_person')),
  reason text check (reason in ('registered_by_someone_else', 'number_reassigned')),
  withdrawn_application_id uuid references app.identity_membership_applications (application_id),
  actor_member_id uuid not null references app.identity_members (member_id),
  actor_account_id uuid not null,
  request_id uuid,
  created_at timestamptz not null default now(),
  -- Restricted-operator undo (app.identity_undo_phone_reclaim).
  undone_at timestamptz,
  undone_by text,
  check ((undone_at is null) = (undone_by is null))
);

comment on table app.identity_phone_reclaims is
  'owner: identity. Reclaim cases (F1): a phone username released from an unlinked Auth account '
  'after an identity check. The released account is banned, never merged or deleted.';

-- Content-free: ids, codes and revisions only. Never names, phones, emails or free text.
create table app.identity_membership_audit (
  event_id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  environment text not null default app.platform_current_environment(),
  action text not null check (action in (
    'application_approved', 'application_linked', 'application_details_requested',
    'application_rejected', 'application_withdrawn', 'member_created', 'account_unlinked',
    'phone_username_reclaimed', 'phone_reclaim_undone')),
  -- An Admin (member + account) or the restricted operator (undo only).
  actor_member_id uuid,
  actor_account_id uuid,
  operator text,
  request_id uuid,
  application_id uuid,
  member_id uuid,
  link_id uuid,
  target_account_id uuid,
  reclaim_id uuid,
  identity_check text check (identity_check in ('established_relationship', 'in_person')),
  reason_code text check (reason_code ~ '^[a-z][a-z0-9_]{0,62}$'),
  requested_fields text[]
    check (requested_fields <@ array['full_name', 'cell_choice', 'visit_church_office',
                                     'recovery_email']),
  revision_after bigint,
  check ((operator is null and actor_member_id is not null and actor_account_id is not null)
         or (operator is not null and actor_member_id is null and actor_account_id is null
             and action = 'phone_reclaim_undone'))
);

comment on table app.identity_membership_audit is
  'owner: identity. Attributed membership decisions, links, unlinks and reclaims (AD-4, AD-19): '
  'ids, codes and revisions only.';

create index identity_membership_audit_application
  on app.identity_membership_audit (application_id, event_id);
create index identity_membership_audit_member on app.identity_membership_audit (member_id, event_id);

-- Applications: what the decision told the applicant (codes only) and the member it produced.
alter table app.identity_membership_applications
  add column member_id uuid references app.identity_members (member_id),
  add column decision_reason text
    check (decision_reason in ('identity_not_confirmed', 'not_known_to_church',
                               'contact_church_office')),
  add column details_requested text[]
    check (details_requested is null or (cardinality(details_requested) between 1 and 4
           and details_requested <@ array['full_name', 'cell_choice', 'visit_church_office',
                                          'recovery_email']));

alter table app.identity_membership_applications
  -- Only an approved application names a member (the review commands always set both).
  add constraint identity_membership_applications_member_when_approved
    check (member_id is null or application_state = 'approved'),
  add constraint identity_membership_applications_reason_when_rejected
    check (decision_reason is null or application_state = 'rejected'),
  add constraint identity_membership_applications_details_when_needed
    check (details_requested is null or application_state = 'needs_details');

alter table app.identity_member_provenance enable row level security;
alter table app.identity_contact_routes enable row level security;
alter table app.identity_phone_reclaims enable row level security;
alter table app.identity_membership_audit enable row level security;
revoke all on table app.identity_member_provenance, app.identity_contact_routes,
  app.identity_phone_reclaims, app.identity_membership_audit
  from public, anon, authenticated, service_role;
revoke all on sequence app.identity_membership_audit_event_id_seq
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Applicant-visible decision and re-applying after a rejection
-- ---------------------------------------------------------------------------------------------

-- REAPPLY_COOLDOWN: a rejected account may send a new request this long after the decision.
create function app.identity_reapply_cooldown()
returns interval
language sql
immutable
set search_path = ''
as $$ select interval '7 days' $$;

-- A correction (2.4) answers a request for details: leaving needs_details drops the request.
create function app.identity_on_application_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.application_state <> 'needs_details' then
    new.details_requested := null;
  end if;
  return new;
end;
$$;

create trigger identity_application_details_clear
  before update on app.identity_membership_applications
  for each row
  execute function app.identity_on_application_update();

-- Re-applying: a new application from an account whose request was rejected less than the
-- cooldown ago is refused as `rate_limited` (raised through the 1.4 seam inside the submit).
create function app.identity_on_application_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (select 1 from app.identity_membership_applications a
              where a.auth_user_id = new.auth_user_id and a.application_state = 'rejected'
                and a.decided_at > now() - app.identity_reapply_cooldown()) then
    perform app.cmd_fail('rate_limited');
  end if;
  return new;
end;
$$;

create trigger identity_application_reapply_guard
  before insert on app.identity_membership_applications
  for each row
  execute function app.identity_on_application_insert();

-- The applicant's wire form (2.4 keys unchanged) plus the decision codes. Never a member id,
-- candidate or reviewer.
create or replace function app.identity_application_json(p_row app.identity_membership_applications)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'application_id', p_row.application_id,
    'revision', p_row.revision,
    'application_state', p_row.application_state,
    'church_status', case p_row.application_state
                       when 'submitted' then 'awaiting_approval'
                       when 'needs_details' then 'details_requested'
                       when 'approved' then 'approved'
                       when 'rejected' then 'not_approved'
                       else 'withdrawn' end,
    'full_name', p_row.full_name,
    'phone_username', p_row.phone_username,
    'cell_choice', jsonb_build_object('choice', p_row.cell_choice, 'cell_id', p_row.cell_id,
                                      'cell_revision', p_row.cell_option_revision),
    -- Cell confirmation is separate from church approval and belongs to entry 6.
    'cell_status', case when p_row.cell_choice = 'cell' then 'requested' else 'follow_up' end,
    'privacy_notice_version', p_row.privacy_notice_version,
    'is_synthetic', p_row.is_synthetic,
    'submitted_at', app.cmd_utc(p_row.submitted_at),
    'updated_at', app.cmd_utc(p_row.updated_at))
  -- Story 2.5: the decision, as codes only; each key is present only when it applies.
  || jsonb_strip_nulls(jsonb_build_object(
    'decision_reason', p_row.decision_reason,
    'details_requested', to_jsonb(p_row.details_requested),
    'reapply_from', case when p_row.application_state = 'rejected'
                         then app.cmd_utc(p_row.decided_at + app.identity_reapply_cooldown()) end));
$$;

-- identity.correct_application (2.4), replaced with the same behaviour. Fix found by story 2.5:
-- a correction that sent only one of full_name / cell_choice read the other field's unassigned
-- record inside an AND (PL/pgSQL does not short-circuit it) and failed as `unavailable`
-- (sqlstate 55000). Answering a request for details often changes one field only.
create or replace function app.identity_correct_application(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_err text;
  v_name record;
  v_cell record;
  v_row app.identity_membership_applications;
  v_changed text[] := '{}';
begin
  if not app.identity_applications_open() then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, array['application_id', 'full_name', 'cell_choice']);
  v_err := app.contract_uuid_error(p_payload -> 'application_id');
  if v_err is not null then
    v_errors := v_errors || jsonb_build_object('application_id', v_err);
  end if;
  if not (p_payload ? 'full_name' or p_payload ? 'cell_choice') then
    v_errors := v_errors || '{"payload": "required"}';
  end if;
  if p_payload ? 'full_name' then
    select n.* into v_name from app.identity_application_name(p_payload -> 'full_name', '{}') n;
    v_errors := v_errors || v_name.errors;
  end if;
  if p_payload ? 'cell_choice' then
    select c.* into v_cell from app.identity_application_cell_choice(p_payload -> 'cell_choice', '{}') c;
    v_errors := v_errors || v_cell.errors;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;

  -- Only the caller's own application exists for them; anything else is not found.
  select a.* into v_row from app.identity_membership_applications a
   where a.application_id = (p_payload ->> 'application_id')::uuid and a.auth_user_id = p_actor
     for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_row.revision <> p_expected_revision
     or v_row.application_state not in ('submitted', 'needs_details') then
    perform app.cmd_fail('conflict', null, v_row.revision);
  end if;

  if p_payload ? 'full_name' then
    if v_name.full_name <> v_row.full_name then
      v_changed := v_changed || 'full_name'::text;
      v_row.full_name := v_name.full_name;
    end if;
  end if;
  if p_payload ? 'cell_choice' then
    if v_cell.choice <> v_row.cell_choice or v_cell.cell_id is distinct from v_row.cell_id
       or v_cell.cell_revision is distinct from v_row.cell_option_revision then
      v_changed := v_changed || 'cell_choice'::text;
      v_row.cell_choice := v_cell.choice;
      v_row.cell_id := v_cell.cell_id;
      v_row.cell_option_revision := v_cell.cell_revision;
    end if;
  end if;
  if v_changed = '{}'::text[] then
    -- Nothing to correct: the current state is the answer (no new revision).
    return app.identity_application_outcome(v_row);
  end if;
  if (select count(*) from app.identity_application_events e
       where e.application_id = v_row.application_id and e.event = 'corrected'
         and e.at > now() - interval '24 hours')
     >= app.identity_application_correction_limit() then
    perform app.cmd_fail('rate_limited');
  end if;

  update app.identity_membership_applications a
     set full_name = v_row.full_name,
         cell_choice = v_row.cell_choice,
         cell_id = v_row.cell_id,
         cell_option_revision = v_row.cell_option_revision,
         -- A correction answers a request for details: back to the review queue.
         application_state = 'submitted',
         revision = a.revision + 1,
         updated_at = now()
   where a.application_id = v_row.application_id
  returning * into v_row;
  insert into app.identity_application_events (application_id, revision, event,
                                               actor_auth_user_id, request_id, changed_fields)
  values (v_row.application_id, v_row.revision, 'corrected', p_actor,
          app.cmd_current_request_id(p_actor, 'identity.correct_application'), v_changed);
  return app.identity_application_outcome(v_row);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------------------------

-- How a member's account stands (the 2.3 roster vocabulary).
create function app.identity_member_account_label(p_member_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when l.link_id is null then 'no_login'
    when l.link_state = 'active' and not l.binding_review_required
         and not exists (select 1 from app.identity_holds h
                          where h.member_id = p_member_id and h.released_at is null)
      then 'app_account'
    else 'access_review' end
    from (select 1) one
    left join app.identity_account_links l
      on l.member_id = p_member_id and l.link_state <> 'ended';
$$;

-- An approved member with no live link, no open hold and no active grant may receive an
-- account link (grants never travel with a link).
create function app.identity_member_link_eligible(p_member_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from app.identity_members m
                  where m.member_id = p_member_id and m.membership_state = 'approved')
     and not exists (select 1 from app.identity_account_links l
                      where l.member_id = p_member_id and l.link_state <> 'ended')
     and not exists (select 1 from app.identity_holds h
                      where h.member_id = p_member_id and h.released_at is null)
     and not exists (select 1 from app.identity_grants g
                      where g.member_id = p_member_id and g.revoked_at is null);
$$;

-- Name tokens for the staff duplicate aid: lower case, split on anything that is not a letter
-- or digit, without the SYNTHETIC test label.
create function app.identity_name_tokens(p_name text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(array_agg(distinct t order by t), '{}')
    from regexp_split_to_table(lower(coalesce(p_name, '')), '[^[:alnum:]]+') t
   where t <> '' and t <> 'synthetic';
$$;

create function app.identity_check_value(p_value jsonb, p_required boolean)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when coalesce(jsonb_typeof(p_value), 'null') = 'null'
      then case when p_required then 'required' end
    when jsonb_typeof(p_value) <> 'string'
         or p_value #>> '{}' not in ('established_relationship', 'in_person') then 'invalid'
  end;
$$;

-- Validates the payload's own keys and the shared fields, then raises every field error at once.
create function app.identity_review_errors(
  p_payload jsonb,
  p_allowed text[],
  p_identity_check_required boolean
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_errors jsonb;
  v_err text;
begin
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, p_allowed);
  if 'application_id' = any (p_allowed) then
    v_err := app.contract_uuid_error(p_payload -> 'application_id');
    if v_err is not null then
      v_errors := v_errors || jsonb_build_object('application_id', v_err);
    end if;
  end if;
  if 'identity_check' = any (p_allowed) then
    v_err := app.identity_check_value(p_payload -> 'identity_check', p_identity_check_required);
    if v_err is not null then
      v_errors := v_errors || jsonb_build_object('identity_check', v_err);
    end if;
  end if;
  return v_errors;
end;
$$;

-- Locks an open application for a decision: not found, the Admin's own account (separation of
-- duty), a decided request or a stale revision are refused.
create function app.identity_lock_open_application(
  p_application_id uuid,
  p_expected_revision bigint,
  p_actor_account uuid
) returns app.identity_membership_applications
language plpgsql
set search_path = ''
as $$
declare
  v_row app.identity_membership_applications;
begin
  select a.* into v_row from app.identity_membership_applications a
   where a.application_id = p_application_id
     for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_row.auth_user_id = p_actor_account then
    perform app.cmd_fail('forbidden', '{"application_id": "unsupported"}');
  end if;
  if v_row.application_state not in ('submitted', 'needs_details')
     or v_row.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_row.revision);
  end if;
  return v_row;
end;
$$;

-- The application's next revision with a decision, its history event and the audit row.
create function app.identity_decide_application(
  p_row app.identity_membership_applications,
  p_state text,
  p_event text,
  p_member_id uuid,
  p_reason text,
  p_requested text[],
  p_actor_member uuid,
  p_actor_account uuid,
  p_command text,
  p_action text,
  p_identity_check text,
  p_link_id uuid
) returns app.identity_membership_applications
language plpgsql
set search_path = ''
as $$
declare
  v_row app.identity_membership_applications;
  v_request uuid := app.cmd_current_request_id(p_actor_account, p_command);
begin
  update app.identity_membership_applications a
     set application_state = p_state,
         member_id = p_member_id,
         decision_reason = p_reason,
         details_requested = p_requested,
         decided_at = case when p_state in ('approved', 'rejected', 'withdrawn') then now() end,
         revision = a.revision + 1,
         updated_at = now()
   where a.application_id = p_row.application_id
  returning * into v_row;
  insert into app.identity_application_events (application_id, revision, event,
                                               actor_auth_user_id, request_id, changed_fields)
  values (v_row.application_id, v_row.revision, p_event, p_actor_account, v_request, '{}');
  insert into app.identity_membership_audit (action, actor_member_id, actor_account_id, request_id,
                                             application_id, member_id, link_id, target_account_id,
                                             identity_check, reason_code, requested_fields,
                                             revision_after)
  values (p_action, p_actor_member, p_actor_account, v_request, v_row.application_id, p_member_id,
          p_link_id, v_row.auth_user_id, p_identity_check, p_reason, p_requested, v_row.revision);
  return v_row;
end;
$$;

-- Links the applicant's account to p_member_id with the approved binding (current Auth phone,
-- which must equal the applied phone username; the current email, refused while unconfirmed),
-- binding history revision 1 and a trust epoch now: only sessions created after this approval
-- pass. An account ever linked to a member with an open hold is refused (2.4 applicant rule).
create function app.identity_link_application_account(
  p_row app.identity_membership_applications,
  p_member_id uuid,
  p_actor_member uuid,
  p_reason text
) returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_phone text;
  v_email text;
  v_confirmed boolean;
  v_link uuid;
  v_constraint text;
  v_by text := 'admin:' || p_actor_member::text;
begin
  select '+' || ltrim(nullif(btrim(u.phone), ''), '+'), lower(nullif(btrim(u.email), '')),
         u.email_confirmed_at is not null
    into v_phone, v_email, v_confirmed
    from auth.users u
   where u.id = p_row.auth_user_id
     and u.deleted_at is null
     and not coalesce(u.is_anonymous, false)
     and (u.banned_until is null or u.banned_until <= now());
  if not found then
    perform app.cmd_fail('validation_failed', '{"application_id": "account_unavailable"}');
  end if;
  if exists (select 1 from app.identity_account_links l
               join app.identity_holds h on h.member_id = l.member_id
              where l.auth_user_id = p_row.auth_user_id and h.released_at is null) then
    perform app.cmd_fail('forbidden', '{"application_id": "not_applicant"}');
  end if;
  if v_phone is distinct from p_row.phone_username then
    perform app.cmd_fail('validation_failed', '{"phone_username": "changed"}');
  end if;
  if v_email is not null and not v_confirmed then
    perform app.cmd_fail('validation_failed', '{"recovery_email": "unverified"}');
  end if;
  if exists (select 1 from app.identity_account_links l
              where l.auth_user_id = p_row.auth_user_id and l.link_state <> 'ended') then
    perform app.cmd_fail('conflict', '{"application_id": "linked"}', p_row.revision);
  end if;
  if exists (select 1 from app.identity_account_links l
              where l.approved_phone = v_phone and l.link_state <> 'ended') then
    -- Another member's live link still holds this phone username: unlink it explicitly first.
    perform app.cmd_fail('conflict', '{"phone_username": "linked"}', p_row.revision);
  end if;
  begin
    insert into app.identity_account_links (member_id, auth_user_id, approved_phone,
                                            approved_recovery_email, approved_by,
                                            sessions_valid_after)
    values (p_member_id, p_row.auth_user_id, v_phone, v_email, v_by, clock_timestamp())
    returning link_id into v_link;
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    perform app.cmd_fail('conflict', jsonb_build_object(
      case v_constraint
        when 'identity_account_links_one_live_per_member' then 'member_id'
        when 'identity_account_links_one_live_per_phone' then 'phone_username'
        else 'application_id' end, 'linked'), p_row.revision);
  end;
  insert into app.identity_binding_history (link_id, binding_revision, approved_phone,
                                            approved_recovery_email, approved_by, reason)
  values (v_link, 1, v_phone, v_email, v_by, p_reason);
  update app.identity_members m
     set revision = m.revision + 1, updated_at = now()
   where m.member_id = p_member_id;
  return v_link;
end;
$$;

-- Admin view of an application (adds the member it produced).
create function app.identity_review_application_outcome(p_row app.identity_membership_applications)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'identity_membership_application',
    'aggregate_id', p_row.application_id,
    'revision', p_row.revision,
    'data', app.identity_application_json(p_row) || jsonb_build_object('member_id', p_row.member_id));
$$;

-- Admin view of one member record.
create function app.identity_admin_member_json(p_member_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'member_id', m.member_id,
    'display_name', m.display_name,
    'membership_state', m.membership_state,
    'revision', m.revision,
    'is_synthetic', m.is_synthetic,
    'account', app.identity_member_account_label(m.member_id),
    'link_eligible', app.identity_member_link_eligible(m.member_id),
    'origin', coalesce((select p.origin from app.identity_member_provenance p
                         where p.member_id = m.member_id), 'other'),
    'contact_routes', coalesce((
      select jsonb_agg(jsonb_build_object('route_id', r.route_id, 'phone', r.value,
                                          'belongs_to', r.belongs_to,
                                          'holder_label', r.holder_label)
                       order by r.created_at, r.route_id)
        from app.identity_contact_routes r
       where r.member_id = m.member_id and r.ended_at is null), '[]'::jsonb))
    from app.identity_members m
   where m.member_id = p_member_id;
$$;

create function app.identity_member_outcome(p_member_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'aggregate_type', 'identity_member',
    'aggregate_id', p_member_id,
    'revision', (select m.revision from app.identity_members m where m.member_id = p_member_id),
    'data', app.identity_admin_member_json(p_member_id));
$$;

-- ---------------------------------------------------------------------------------------------
-- Review commands
-- ---------------------------------------------------------------------------------------------

-- identity.approve_application {application_id, identity_check}: a new approved member.
create function app.identity_approve_application(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_row app.identity_membership_applications;
  v_member uuid;
  v_link uuid;
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_errors := app.identity_review_errors(p_payload, array['application_id', 'identity_check'], true);
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  if not app.identity_applications_open() then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  v_row := app.identity_lock_open_application((p_payload ->> 'application_id')::uuid,
                                              p_expected_revision, v_actor.account_id);
  insert into app.identity_members (display_name, membership_state, is_synthetic)
  values (v_row.full_name, 'approved', v_row.is_synthetic)
  returning member_id into v_member;
  insert into app.identity_member_provenance (member_id, origin, application_id, identity_check,
                                              recorded_by_member, recorded_by_account, request_id)
  values (v_member, 'application', v_row.application_id, p_payload ->> 'identity_check',
          v_actor.member_id, v_actor.account_id,
          app.cmd_current_request_id(p_actor, 'identity.approve_application'));
  v_link := app.identity_link_application_account(v_row, v_member, v_actor.member_id,
                                                  'application_approved');
  v_row := app.identity_decide_application(v_row, 'approved', 'approved', v_member, null, null,
    v_actor.member_id, v_actor.account_id, 'identity.approve_application', 'application_approved',
    p_payload ->> 'identity_check', v_link);
  return app.identity_review_application_outcome(v_row);
end;
$$;

-- identity.link_application {application_id, member_id, identity_check}: the applicant's
-- account joins an EXISTING approved member that has no live link (accountless, or unlinked).
create function app.identity_link_application(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_err text;
  v_row app.identity_membership_applications;
  v_member uuid;
  v_link uuid;
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_errors := app.identity_review_errors(
    p_payload, array['application_id', 'member_id', 'identity_check'], true);
  v_err := app.contract_uuid_error(p_payload -> 'member_id');
  if v_err is not null then
    v_errors := v_errors || jsonb_build_object('member_id', v_err);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  if not app.identity_applications_open() then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  v_member := (p_payload ->> 'member_id')::uuid;
  -- Separation of duty: an Admin never links an account to their own member record.
  if v_member = v_actor.member_id then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  v_row := app.identity_lock_open_application((p_payload ->> 'application_id')::uuid,
                                              p_expected_revision, v_actor.account_id);
  perform 1 from app.identity_members m where m.member_id = v_member for update;
  if not exists (select 1 from app.identity_members m
                  where m.member_id = v_member and m.membership_state = 'approved') then
    perform app.cmd_fail('validation_failed', '{"member_id": "invalid"}');
  end if;
  if exists (select 1 from app.identity_account_links l
              where l.member_id = v_member and l.link_state <> 'ended') then
    perform app.cmd_fail('conflict', '{"member_id": "linked"}', v_row.revision);
  end if;
  if exists (select 1 from app.identity_holds h
              where h.member_id = v_member and h.released_at is null) then
    perform app.cmd_fail('validation_failed', '{"member_id": "held"}');
  end if;
  -- Grants never travel with a link: a member still holding any grant is refused (unlinking
  -- ends them; re-grant through the audited 2.3 commands after linking).
  if exists (select 1 from app.identity_grants g
              where g.member_id = v_member and g.revoked_at is null) then
    perform app.cmd_fail('validation_failed', '{"member_id": "has_grants"}');
  end if;
  v_link := app.identity_link_application_account(v_row, v_member, v_actor.member_id,
                                                  'application_linked');
  v_row := app.identity_decide_application(v_row, 'approved', 'approved', v_member, null, null,
    v_actor.member_id, v_actor.account_id, 'identity.link_application', 'application_linked',
    p_payload ->> 'identity_check', v_link);
  return app.identity_review_application_outcome(v_row);
end;
$$;

-- identity.request_application_details {application_id, requested[], identity_check?}
create function app.identity_request_application_details(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_requested text[];
  v_row app.identity_membership_applications;
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_errors := app.identity_review_errors(
    p_payload, array['application_id', 'requested', 'identity_check'], false);
  if coalesce(jsonb_typeof(p_payload -> 'requested'), 'null') = 'null' then
    v_errors := v_errors || '{"requested": "required"}';
  elsif jsonb_typeof(p_payload -> 'requested') <> 'array' then
    v_errors := v_errors || '{"requested": "invalid"}';
  elsif jsonb_array_length(p_payload -> 'requested') not between 1 and 4
        or exists (select 1 from jsonb_array_elements(p_payload -> 'requested') e(v)
                    where jsonb_typeof(e.v) <> 'string'
                       or e.v #>> '{}' not in ('full_name', 'cell_choice', 'visit_church_office',
                                               'recovery_email')) then
    v_errors := v_errors || '{"requested": "invalid"}';
  else
    select array_agg(distinct e.v order by e.v) into v_requested
      from jsonb_array_elements_text(p_payload -> 'requested') e(v);
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_row := app.identity_lock_open_application((p_payload ->> 'application_id')::uuid,
                                              p_expected_revision, v_actor.account_id);
  v_row := app.identity_decide_application(v_row, 'needs_details', 'details_requested', null, null,
    v_requested, v_actor.member_id, v_actor.account_id, 'identity.request_application_details',
    'application_details_requested', p_payload ->> 'identity_check', null);
  return app.identity_review_application_outcome(v_row);
end;
$$;

-- identity.reject_application {application_id, reason?, identity_check?}
create function app.identity_reject_application(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_reason text;
  v_row app.identity_membership_applications;
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_errors := app.identity_review_errors(
    p_payload, array['application_id', 'reason', 'identity_check'], false);
  if coalesce(jsonb_typeof(p_payload -> 'reason'), 'null') <> 'null' then
    if jsonb_typeof(p_payload -> 'reason') <> 'string'
       or p_payload ->> 'reason' not in ('identity_not_confirmed', 'not_known_to_church',
                                         'contact_church_office') then
      v_errors := v_errors || '{"reason": "invalid"}';
    else
      v_reason := p_payload ->> 'reason';
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  v_row := app.identity_lock_open_application((p_payload ->> 'application_id')::uuid,
                                              p_expected_revision, v_actor.account_id);
  v_row := app.identity_decide_application(v_row, 'rejected', 'rejected', null, v_reason, null,
    v_actor.member_id, v_actor.account_id, 'identity.reject_application', 'application_rejected',
    p_payload ->> 'identity_check', null);
  return app.identity_review_application_outcome(v_row);
end;
$$;

-- identity.create_member {full_name, consent_basis, assisted_by_member_id?, contact_route?}:
-- an approved member WITHOUT a login, recorded with the person's consent.
create function app.identity_create_member(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_name record;
  v_err text;
  v_assisted uuid;
  v_route jsonb;
  v_phone text;
  v_label text;
  v_member uuid;
  v_synthetic boolean := app.platform_current_environment() in ('local', 'staging');
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  if not app.identity_applications_open() then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(
    p_payload, array['full_name', 'consent_basis', 'assisted_by_member_id', 'contact_route']);
  select n.* into v_name from app.identity_application_name(p_payload -> 'full_name', '{}') n;
  v_errors := v_errors || v_name.errors;
  if coalesce(jsonb_typeof(p_payload -> 'consent_basis'), 'null') = 'null' then
    v_errors := v_errors || '{"consent_basis": "required"}';
  elsif jsonb_typeof(p_payload -> 'consent_basis') <> 'string'
        or p_payload ->> 'consent_basis' not in ('in_person', 'leader_assisted') then
    v_errors := v_errors || '{"consent_basis": "invalid"}';
  end if;
  if coalesce(jsonb_typeof(p_payload -> 'assisted_by_member_id'), 'null') <> 'null' then
    v_err := app.contract_uuid_error(p_payload -> 'assisted_by_member_id');
    if v_err is not null then
      v_errors := v_errors || jsonb_build_object('assisted_by_member_id', v_err);
    elsif p_payload ->> 'consent_basis' is distinct from 'leader_assisted' then
      v_errors := v_errors || '{"assisted_by_member_id": "must_be_null"}';
    elsif not exists (select 1 from app.identity_members m
                       where m.member_id = (p_payload ->> 'assisted_by_member_id')::uuid
                         and m.membership_state = 'approved') then
      v_errors := v_errors || '{"assisted_by_member_id": "invalid"}';
    else
      v_assisted := (p_payload ->> 'assisted_by_member_id')::uuid;
    end if;
  end if;
  v_route := p_payload -> 'contact_route';
  if coalesce(jsonb_typeof(v_route), 'null') <> 'null' then
    if jsonb_typeof(v_route) <> 'object' then
      v_errors := v_errors || '{"contact_route": "must_be_object"}';
    else
      v_errors := v_errors || coalesce((
        select jsonb_object_agg('contact_route.' || k, 'unknown_field')
          from jsonb_object_keys(v_route) k
         where k not in ('phone', 'belongs_to', 'holder_label')), '{}'::jsonb);
      if jsonb_typeof(v_route -> 'phone') is distinct from 'string'
         or v_route ->> 'phone' !~ '^\+[1-9][0-9]{7,14}$' then
        v_errors := v_errors || '{"contact_route.phone": "invalid"}';
      elsif not app.policy_is_open('q4_personal_data')
            and v_route ->> 'phone' !~ '^\+120255501[0-9]{2}$'
            and v_route ->> 'phone' !~ '^\+447700900[0-9]{3}$' then
        v_errors := v_errors || '{"contact_route.phone": "out_of_range"}';
      else
        v_phone := v_route ->> 'phone';
      end if;
      if jsonb_typeof(v_route -> 'belongs_to') is distinct from 'string'
         or v_route ->> 'belongs_to' not in ('member', 'relative', 'household', 'other') then
        v_errors := v_errors || '{"contact_route.belongs_to": "invalid"}';
      end if;
      if coalesce(jsonb_typeof(v_route -> 'holder_label'), 'null') <> 'null' then
        if jsonb_typeof(v_route -> 'holder_label') <> 'string' then
          v_errors := v_errors || '{"contact_route.holder_label": "invalid"}';
        else
          v_label := regexp_replace(btrim(v_route ->> 'holder_label'), '\s+', ' ', 'g');
          if v_label = '' or length(v_label) > 60 or v_label ~ '[[:cntrl:]]'
             or v_label ~ '[​-‏‪-‮⁦-⁩﻿]' then
            v_errors := v_errors || '{"contact_route.holder_label": "invalid"}';
            v_label := null;
          end if;
        end if;
      end if;
      if v_route ->> 'belongs_to' in ('relative', 'household', 'other') and v_label is null
         and not (v_errors ? 'contact_route.holder_label') then
        -- Whose number it is must be labelled.
        v_errors := v_errors || '{"contact_route.holder_label": "required"}';
      end if;
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;

  insert into app.identity_members (display_name, membership_state, is_synthetic)
  values (v_name.full_name, 'approved', v_synthetic)
  returning member_id into v_member;
  insert into app.identity_member_provenance (member_id, origin, consent_basis, assisted_by_member,
                                              recorded_by_member, recorded_by_account, request_id)
  values (v_member, 'admin_record', p_payload ->> 'consent_basis', v_assisted, v_actor.member_id,
          v_actor.account_id, app.cmd_current_request_id(p_actor, 'identity.create_member'));
  if v_phone is not null then
    insert into app.identity_contact_routes (member_id, value, belongs_to, holder_label,
                                             is_synthetic, created_by_member, created_by_account)
    values (v_member, v_phone, v_route ->> 'belongs_to', v_label, v_synthetic, v_actor.member_id,
            v_actor.account_id);
  end if;
  insert into app.identity_membership_audit (action, actor_member_id, actor_account_id, request_id,
                                             member_id, reason_code, revision_after)
  values ('member_created', v_actor.member_id, v_actor.account_id,
          app.cmd_current_request_id(p_actor, 'identity.create_member'), v_member,
          p_payload ->> 'consent_basis', 1);
  return app.identity_member_outcome(v_member);
end;
$$;

-- identity.unlink_account {member_id, reason}; expected = the member's revision. Ends the live
-- link (the 2.2 trigger moves the epoch: every session of that account is denied), keeps the
-- member, its history and grants, and dispatches account_deactivated to owner hooks.
create function app.identity_unlink_account(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_err text;
  v_member app.identity_members;
  v_link app.identity_account_links;
  v_grant app.identity_grants;
  v_revision bigint;
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  if jsonb_typeof(p_payload) is distinct from 'object' then
    perform app.cmd_fail('validation_failed', '{"payload": "must_be_object"}');
  end if;
  v_errors := app.contract_unknown_keys(p_payload, array['member_id', 'reason']);
  v_err := app.contract_uuid_error(p_payload -> 'member_id');
  if v_err is not null then
    v_errors := v_errors || jsonb_build_object('member_id', v_err);
  end if;
  if coalesce(jsonb_typeof(p_payload -> 'reason'), 'null') = 'null' then
    v_errors := v_errors || '{"reason": "required"}';
  elsif jsonb_typeof(p_payload -> 'reason') <> 'string'
        or p_payload ->> 'reason' not in ('account_lost', 'ownership_dispute', 'member_request',
                                          'phone_reclaim') then
    v_errors := v_errors || '{"reason": "invalid"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  if (p_payload ->> 'member_id')::uuid = v_actor.member_id then
    perform app.cmd_fail('forbidden', '{"member_id": "unsupported"}');
  end if;
  select m.* into v_member from app.identity_members m
   where m.member_id = (p_payload ->> 'member_id')::uuid
     for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_member.revision <> p_expected_revision then
    perform app.cmd_fail('conflict', null, v_member.revision);
  end if;
  select l.* into v_link from app.identity_account_links l
   where l.member_id = v_member.member_id and l.link_state <> 'ended'
     for update;
  if not found then
    perform app.cmd_fail('conflict', '{"member_id": "not_linked"}', v_member.revision);
  end if;
  -- The church is never left without a usable Admin (bootstrap is the recovery route).
  if exists (select 1 from app.identity_grants g
              where g.member_id = v_member.member_id and g.role = 'admin' and g.revoked_at is null)
     and app.identity_usable_admin_count(v_member.member_id) = 0 then
    perform app.cmd_fail('forbidden', '{"member_id": "last_admin"}');
  end if;
  -- Grants never travel with a link: every active grant ends through the 2.3 path (role_revoked
  -- / scope_revoked audit with this Admin, scope_revoked dispatched).
  for v_grant in
    select g.* from app.identity_grants g
     where g.member_id = v_member.member_id and g.revoked_at is null
     order by g.granted_at, g.grant_id
       for update
  loop
    perform app.identity_end_grant(p_actor, v_actor.member_id, 'identity.unlink_account', v_grant);
  end loop;
  update app.identity_account_links l
     set link_state = 'ended', ended_at = now(), updated_at = now()
   where l.link_id = v_link.link_id;
  update app.identity_members m
     set revision = m.revision + 1, updated_at = now()
   where m.member_id = v_member.member_id
  returning m.revision into v_revision;
  insert into app.identity_membership_audit (action, actor_member_id, actor_account_id, request_id,
                                             member_id, link_id, target_account_id, reason_code,
                                             revision_after)
  values ('account_unlinked', v_actor.member_id, v_actor.account_id,
          app.cmd_current_request_id(p_actor, 'identity.unlink_account'), v_member.member_id,
          v_link.link_id, v_link.auth_user_id, p_payload ->> 'reason', v_revision);
  perform app.contract_dispatch_lifecycle(jsonb_build_object(
    'event', 'account_deactivated',
    'member_id', v_member.member_id,
    'occurred_at', app.cmd_utc(now()),
    'identity_revision', v_revision));
  return app.identity_member_outcome(v_member.member_id);
end;
$$;

-- identity.reclaim_phone_username {phone_username, identity_check, reason?}: releases a phone
-- username held by an UNLINKED Auth account after the Admin checked the claimant's identity.
create function app.identity_reclaim_phone_username(
  p_actor uuid,
  p_expected_revision bigint,
  p_payload jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_actor record;
  v_errors jsonb;
  v_phone text;
  v_holder uuid;
  v_open app.identity_membership_applications;
  v_reclaim uuid;
  v_request uuid;
begin
  select a.* into v_actor from app.identity_command_actor(p_actor) a;
  v_errors := app.identity_review_errors(
    p_payload, array['phone_username', 'identity_check', 'reason'], true);
  if jsonb_typeof(p_payload -> 'phone_username') is distinct from 'string'
     or p_payload ->> 'phone_username' !~ '^\+[1-9][0-9]{7,14}$' then
    v_errors := v_errors || '{"phone_username": "invalid"}';
  else
    v_phone := p_payload ->> 'phone_username';
  end if;
  if coalesce(jsonb_typeof(p_payload -> 'reason'), 'null') <> 'null'
     and (jsonb_typeof(p_payload -> 'reason') <> 'string'
          or p_payload ->> 'reason' not in ('registered_by_someone_else', 'number_reassigned')) then
    v_errors := v_errors || '{"reason": "invalid"}';
  end if;
  if v_phone is not null and not app.policy_is_open('q4_personal_data')
     and v_phone !~ '^\+120255501[0-9]{2}$' and v_phone !~ '^\+447700900[0-9]{3}$' then
    v_errors := v_errors || '{"phone_username": "out_of_range"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.cmd_fail('validation_failed', v_errors);
  end if;
  if not app.identity_applications_open() then
    perform app.cmd_fail('unavailable', '{"policy": "gate_closed"}');
  end if;
  -- Auth normally stores the phone as digits without '+'; accept either form.
  if (select count(*) from auth.users u
       where u.phone in (ltrim(v_phone, '+'), v_phone)) > 1 then
    perform app.cmd_fail('conflict', '{"phone_username": "ambiguous"}');
  end if;
  select u.id into v_holder from auth.users u
   where u.phone in (ltrim(v_phone, '+'), v_phone)
     for update;
  if not found then
    perform app.cmd_fail('not_found');
  end if;
  if v_holder = v_actor.account_id then
    perform app.cmd_fail('forbidden', '{"phone_username": "unsupported"}');
  end if;
  -- A linked account is a dispute about a member: unlink it explicitly first.
  if exists (select 1 from app.identity_account_links l
              where l.auth_user_id = v_holder and l.link_state <> 'ended') then
    perform app.cmd_fail('conflict', '{"phone_username": "linked"}');
  end if;
  v_request := app.cmd_current_request_id(p_actor, 'identity.reclaim_phone_username');
  insert into app.identity_phone_reclaims (phone_username, released_account_id, identity_check,
                                           reason, actor_member_id, actor_account_id, request_id)
  values (v_phone, v_holder, p_payload ->> 'identity_check', p_payload ->> 'reason',
          v_actor.member_id, v_actor.account_id, v_request)
  returning reclaim_id into v_reclaim;

  select a.* into v_open from app.identity_membership_applications a
   where a.auth_user_id = v_holder and a.application_state in ('submitted', 'needs_details')
     for update;
  if found then
    perform app.identity_decide_application(v_open, 'withdrawn', 'withdrawn', null, null, null,
      v_actor.member_id, v_actor.account_id, 'identity.reclaim_phone_username',
      'application_withdrawn', p_payload ->> 'identity_check', null);
    update app.identity_phone_reclaims r set withdrawn_application_id = v_open.application_id
     where r.reclaim_id = v_reclaim;
  end if;

  -- Release the username: the holder keeps its Auth row (never merged or deleted) but loses the
  -- phone and is banned, which ends every session it holds for private access and refresh.
  update auth.users u
     set phone = null, phone_confirmed_at = null,
         banned_until = now() + interval '100 years', updated_at = now()
   where u.id = v_holder;

  insert into app.identity_membership_audit (action, actor_member_id, actor_account_id, request_id,
                                             target_account_id, reclaim_id, identity_check,
                                             reason_code, application_id)
  values ('phone_username_reclaimed', v_actor.member_id, v_actor.account_id, v_request, v_holder,
          v_reclaim, p_payload ->> 'identity_check', p_payload ->> 'reason',
          v_open.application_id);
  return jsonb_build_object(
    'aggregate_type', 'identity_phone_reclaim',
    'aggregate_id', v_reclaim,
    'revision', 1,
    'data', jsonb_build_object('reclaim_id', v_reclaim, 'released', true,
                               'application_withdrawn', v_open.application_id is not null));
end;
$$;

-- Restricted operator only (no grants): undoes a mistaken reclaim while the number is still
-- free: unbans the released account and gives it the phone username back. The withdrawn
-- application stays withdrawn (the person applies again). Recorded in Identity's audit as
-- `phone_reclaim_undone` with the operator. Not journalled in app.ops_operator_actions: its
-- action CHECK has no fitting value and widening it would need a destructive statement (the 2.3
-- retire-and-recreate is reserved for a later owner-approved cleanup).
create function app.identity_undo_phone_reclaim(p_reclaim_id uuid, p_operator text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_case app.identity_phone_reclaims;
begin
  perform app.ops_require_operator(p_operator);
  select r.* into v_case from app.identity_phone_reclaims r
   where r.reclaim_id = p_reclaim_id
     for update;
  if not found then
    raise exception using errcode = '22023', message = 'unknown reclaim case';
  end if;
  if v_case.undone_at is not null then
    raise exception using errcode = '22023', message = 'the reclaim was already undone';
  end if;
  if exists (select 1 from auth.users u
              where u.phone in (ltrim(v_case.phone_username, '+'), v_case.phone_username)) then
    raise exception using errcode = '22023',
      message = 'the phone username is in use again; it cannot be given back';
  end if;
  update auth.users u
     set phone = ltrim(v_case.phone_username, '+'), phone_confirmed_at = now(),
         banned_until = null, updated_at = now()
   where u.id = v_case.released_account_id and u.deleted_at is null;
  if not found then
    raise exception using errcode = '22023', message = 'the released account no longer exists';
  end if;
  update app.identity_phone_reclaims r
     set undone_at = now(), undone_by = p_operator
   where r.reclaim_id = p_reclaim_id;
  insert into app.identity_membership_audit (action, operator, target_account_id, reclaim_id)
  values ('phone_reclaim_undone', p_operator, v_case.released_account_id, p_reclaim_id);
end;
$$;

comment on function app.identity_undo_phone_reclaim(uuid, text) is
  'Restricted operator only (no grants): undoes a phone-username reclaim while the number is free.';

-- Replay seam: authority was already rechecked by the authorizer; the receipt must name a
-- review aggregate that exists.
create function app.identity_review_in_scope(p_actor uuid, p_aggregate_type text, p_aggregate_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_aggregate_id is not null and case p_aggregate_type
    when 'identity_membership_application' then exists (
      select 1 from app.identity_membership_applications a where a.application_id = p_aggregate_id)
    when 'identity_member' then exists (
      select 1 from app.identity_members m where m.member_id = p_aggregate_id)
    when 'identity_phone_reclaim' then exists (
      select 1 from app.identity_phone_reclaims r where r.reclaim_id = p_aggregate_id)
    else false end;
$$;

create function app.identity_review_command(p_envelope jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_command text;
begin
  if jsonb_typeof(p_envelope) = 'object' and jsonb_typeof(p_envelope -> 'command') = 'string' then
    v_command := p_envelope ->> 'command';
  end if;
  return app.cmd_execute(
    p_envelope,
    case v_command
      when 'identity.approve_application'
        then 'app.identity_approve_application(uuid, bigint, jsonb)'::regprocedure
      when 'identity.link_application'
        then 'app.identity_link_application(uuid, bigint, jsonb)'::regprocedure
      when 'identity.request_application_details'
        then 'app.identity_request_application_details(uuid, bigint, jsonb)'::regprocedure
      when 'identity.reject_application'
        then 'app.identity_reject_application(uuid, bigint, jsonb)'::regprocedure
      when 'identity.create_member'
        then 'app.identity_create_member(uuid, bigint, jsonb)'::regprocedure
      when 'identity.unlink_account'
        then 'app.identity_unlink_account(uuid, bigint, jsonb)'::regprocedure
      when 'identity.reclaim_phone_username'
        then 'app.identity_reclaim_phone_username(uuid, bigint, jsonb)'::regprocedure
    end,
    'app.identity_review_in_scope(uuid, text, uuid)'::regprocedure,
    v_command is distinct from 'identity.create_member'
      and v_command is distinct from 'identity.reclaim_phone_username'
  );
end;
$$;

-- POST /rest/v1/rpc/identity_review_command, Content-Profile: api,
-- body {version, command, request_id, expected_revision, payload}.
create function api.identity_review_command(jsonb)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app.identity_review_command($1);
$$;

comment on function api.identity_review_command(jsonb) is
  'Story 2.5: Admin membership review (approve, link existing, ask details, reject), accountless '
  'member records, unlinking and phone-username reclaim through the 1.4 command envelope.';

-- The registered `identity` authorizer (2.3, dispatching since 2.4). Application commands keep
-- the 2.4 applicant check; grant commands and the story 2.5 review commands share the 2.3 Admin
-- branch unchanged: live Admin, serialised on the admin catalogue row, the actor's Admin grant
-- share-locked.
create or replace function app.identity_authorize_command(p_request jsonb)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  if coalesce(p_request ->> 'command', '') in ('identity.submit_application',
                                                'identity.correct_application') then
    return app.identity_authorize_application_command(p_request);
  end if;
  if coalesce(p_request ->> 'command', '') not in (
       'identity.grant_role', 'identity.revoke_role', 'identity.grant_scope',
       'identity.revoke_scope',
       'identity.approve_application', 'identity.link_application',
       'identity.request_application_details', 'identity.reject_application',
       'identity.create_member', 'identity.unlink_account', 'identity.reclaim_phone_username') then
    return false;
  end if;
  select e.* into r from app.identity_evaluate_grant('admin', null, null) e;
  if r.outcome in ('unauthenticated', 'untrusted_session') then
    perform app.cmd_fail('unauthenticated');
  end if;
  if r.outcome <> 'granted' then
    return false;
  end if;
  perform 1 from app.identity_roles ro where ro.role = 'admin' for update;
  perform 1 from app.identity_grants g
   where g.member_id = r.member_id and g.role = 'admin' and g.revoked_at is null
     for share;
  return found;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Admin reads
-- ---------------------------------------------------------------------------------------------

-- Staff-only duplicate candidates for one application: approved members whose name tokens equal
-- or largely overlap the applicant's, whose contact route or live link holds the applicant's
-- phone username. A staff aid only: nothing is linked, merged or shown to the applicant.
create function app.identity_duplicate_candidates(p_row app.identity_membership_applications)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with mine as (select app.identity_name_tokens(p_row.full_name) as tokens),
  scored as (
    select m.member_id, m.display_name,
           array_remove(array[
             case when (select tokens from mine) <> '{}'
                       and app.identity_name_tokens(m.display_name) = (select tokens from mine)
                  then 'same_name' end,
             case when app.identity_name_tokens(m.display_name) <> (select tokens from mine)
                       and cardinality(array(
                             select unnest(app.identity_name_tokens(m.display_name))
                             intersect
                             select t from unnest((select tokens from mine)) t
                              where length(t) >= 2)) >= 2
                  then 'similar_name' end,
             case when exists (select 1 from app.identity_contact_routes r
                                where r.member_id = m.member_id and r.ended_at is null
                                  and r.value = p_row.phone_username)
                  then 'contact_route_phone' end,
             case when exists (select 1 from app.identity_account_links l
                                where l.member_id = m.member_id and l.link_state <> 'ended'
                                  and l.approved_phone = p_row.phone_username)
                  then 'linked_phone_username' end], null) as signals
      from app.identity_members m
     where m.membership_state = 'approved'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'member_id', s.member_id,
           'display_name', s.display_name,
           'account', app.identity_member_account_label(s.member_id),
           'link_eligible', app.identity_member_link_eligible(s.member_id),
           'signals', to_jsonb(s.signals))
         order by cardinality(s.signals) desc, s.display_name collate "C", s.member_id), '[]'::jsonb)
    from (select * from scored where cardinality(signals) > 0
           order by cardinality(signals) desc, display_name collate "C", member_id
           limit 10) s;
$$;

-- Admin only: open applications (submitted, needs details), oldest first, pages of 25, each
-- with staff-only duplicate candidates and how many earlier requests from the same account were
-- not approved.
create function app.identity_admin_application_queue(
  p_after_submitted_at timestamptz,
  p_after_application_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link_id uuid;
  v_rows jsonb;
  v_count integer;
begin
  select g.link_id into v_link_id from app.identity_require_grant('admin', null, null) g;
  if (p_after_submitted_at is null) <> (p_after_application_id is null) then
    raise exception using errcode = '22023', message = 'cursor needs both parts';
  end if;
  select coalesce(jsonb_agg(x.obj order by x.rn) filter (where x.rn <= 25), '[]'::jsonb),
         count(*)
    into v_rows, v_count
    from (
      select row_number() over (order by a.submitted_at, a.application_id) as rn,
             app.identity_application_json(a) || jsonb_build_object(
               'submitted_at_cursor', a.submitted_at,
               'prior_not_approved', (select count(*) from app.identity_membership_applications p
                                       where p.auth_user_id = a.auth_user_id
                                         and p.application_state in ('rejected', 'withdrawn')),
               'own_account', a.auth_user_id = (app.identity_request_claims() ->> 'sub')::uuid,
               'candidates', app.identity_duplicate_candidates(a)) as obj
        from app.identity_membership_applications a
       where a.application_state in ('submitted', 'needs_details')
         and (p_after_submitted_at is null
              or (a.submitted_at, a.application_id) > (p_after_submitted_at, p_after_application_id))
       order by a.submitted_at, a.application_id
       limit 26
    ) x;
  perform app.identity_record_activity(v_link_id);
  return jsonb_build_object(
    'applications', v_rows,
    'next', case when v_count > 25
                 then jsonb_build_object(
                        'after_submitted_at', v_rows -> 24 ->> 'submitted_at_cursor',
                        'after_application_id', v_rows -> 24 ->> 'application_id')
                 end);
end;
$$;

create function api.identity_admin_application_queue(
  after_submitted_at timestamptz default null,
  after_application_id uuid default null
) returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.identity_admin_application_queue(after_submitted_at, after_application_id);
$$;

comment on function api.identity_admin_application_queue(timestamptz, uuid) is
  'Story 2.5: Admin-only queue of open membership applications with staff-only duplicate '
  'candidates. POST /rest/v1/rpc/identity_admin_application_queue with Content-Profile: api.';

-- Admin only: approved members by name (or contact phone) substring, pages of 25 ordered by
-- (display_name, member_id), with account state, link eligibility, origin and contact routes.
create function app.identity_admin_member_search(
  p_query text,
  p_after_display_name text,
  p_after_member_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link_id uuid;
  v_pattern text;
  v_rows jsonb;
  v_count integer;
begin
  select g.link_id into v_link_id from app.identity_require_grant('admin', null, null) g;
  if (p_after_display_name is null) <> (p_after_member_id is null) then
    raise exception using errcode = '22023', message = 'cursor needs both parts';
  end if;
  if length(coalesce(p_query, '')) > 120 then
    raise exception using errcode = '22023', message = 'query too long';
  end if;
  if nullif(btrim(coalesce(p_query, '')), '') is not null then
    v_pattern := '%' || replace(replace(replace(btrim(p_query), '\', '\\'), '%', '\%'), '_', '\_')
                 || '%';
  end if;
  select coalesce(jsonb_agg(x.obj order by x.rn) filter (where x.rn <= 25), '[]'::jsonb),
         count(*)
    into v_rows, v_count
    from (
      select row_number() over (order by m.display_name collate "C", m.member_id) as rn,
             app.identity_admin_member_json(m.member_id) as obj
        from app.identity_members m
       where m.membership_state = 'approved'
         and (v_pattern is null
              or m.display_name ilike v_pattern
              or exists (select 1 from app.identity_contact_routes r
                          where r.member_id = m.member_id and r.ended_at is null
                            and r.value like v_pattern))
         and (p_after_display_name is null
              or (m.display_name collate "C", m.member_id)
                 > (p_after_display_name collate "C", p_after_member_id))
       order by m.display_name collate "C", m.member_id
       limit 26
    ) x;
  perform app.identity_record_activity(v_link_id);
  return jsonb_build_object(
    'members', v_rows,
    'next', case when v_count > 25
                 then jsonb_build_object('after_display_name', v_rows -> 24 ->> 'display_name',
                                         'after_member_id', v_rows -> 24 ->> 'member_id')
                 end);
end;
$$;

create function api.identity_admin_member_search(
  query text default null,
  after_display_name text default null,
  after_member_id uuid default null
) returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.identity_admin_member_search(query, after_display_name, after_member_id);
$$;

comment on function api.identity_admin_member_search(text, text, uuid) is
  'Story 2.5: Admin-only search of approved members (accountless included) with account state, '
  'link eligibility, origin and labelled contact routes.';

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------

revoke all on function
  app.identity_reapply_cooldown(),
  app.identity_on_application_update(),
  app.identity_on_application_insert(),
  app.identity_application_json(app.identity_membership_applications),
  app.identity_correct_application(uuid, bigint, jsonb),
  app.identity_member_account_label(uuid),
  app.identity_member_link_eligible(uuid),
  app.identity_name_tokens(text),
  app.identity_check_value(jsonb, boolean),
  app.identity_review_errors(jsonb, text[], boolean),
  app.identity_lock_open_application(uuid, bigint, uuid),
  app.identity_decide_application(app.identity_membership_applications, text, text, uuid, text,
                                  text[], uuid, uuid, text, text, text, uuid),
  app.identity_link_application_account(app.identity_membership_applications, uuid, uuid, text),
  app.identity_review_application_outcome(app.identity_membership_applications),
  app.identity_admin_member_json(uuid),
  app.identity_member_outcome(uuid),
  app.identity_approve_application(uuid, bigint, jsonb),
  app.identity_link_application(uuid, bigint, jsonb),
  app.identity_request_application_details(uuid, bigint, jsonb),
  app.identity_reject_application(uuid, bigint, jsonb),
  app.identity_create_member(uuid, bigint, jsonb),
  app.identity_unlink_account(uuid, bigint, jsonb),
  app.identity_reclaim_phone_username(uuid, bigint, jsonb),
  app.identity_undo_phone_reclaim(uuid, text),
  app.identity_review_in_scope(uuid, text, uuid),
  app.identity_review_command(jsonb),
  api.identity_review_command(jsonb),
  app.identity_authorize_command(jsonb),
  app.identity_duplicate_candidates(app.identity_membership_applications),
  app.identity_admin_application_queue(timestamptz, uuid),
  api.identity_admin_application_queue(timestamptz, uuid),
  app.identity_admin_member_search(text, text, uuid),
  api.identity_admin_member_search(text, text, uuid)
  from public, anon, authenticated, service_role;

grant execute on function app.identity_review_command(jsonb) to authenticated;
grant execute on function api.identity_review_command(jsonb) to authenticated;
grant execute on function app.identity_admin_application_queue(timestamptz, uuid) to authenticated;
grant execute on function api.identity_admin_application_queue(timestamptz, uuid) to authenticated;
grant execute on function app.identity_admin_member_search(text, text, uuid) to authenticated;
grant execute on function api.identity_admin_member_search(text, text, uuid) to authenticated;

notify pgrst, 'reload schema';
