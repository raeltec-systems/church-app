-- Story 4.14 (refactor sweep, finding S1): refresh four function comments that later stories left
-- stale. Comments only: no function body, signature, grant, table, row or lock order changes, and
-- no `_rows` file (so no owner SQL paste). Every function keeps the body of its latest version:
--   * api.duties_command(jsonb)       body from 20261015110202_duties_lifecycle.sql (4.12); its
--     comment (from 20261015002121_duties_outcomes.sql) listed the commands up to 4.10 only;
--   * app.duties_state_ok(text, text) body from 20261015110202_duties_lifecycle.sql (4.12); its
--     comment (from 20261013220239_duties_department_tracer.sql) named story 4.1 only;
--   * api.followups_command(jsonb)    body from 20261015110202_duties_lifecycle.sql (4.12); its
--     comment (from 20261014110258_followups_registry.sql) did not name complete_handover;
--   * app.followups_state_ok(text, text) body from 20261015110202_duties_lifecycle.sql (4.12); its
--     comment (from 20261014110258_followups_registry.sql) named story 4.6 only.
-- Hosted: apply after 20261015110202; compare per-function md5 with the local database (they must
-- be unchanged by this file) and the four comments.

comment on function api.duties_command(jsonb) is
  'Stories 4.1-4.12: departments (create_department, add_member, remove_member, '
  'resolve_handover), publishing and revising duties (publish_duty, revise_duty), the assignee''s '
  'answer (respond, withdraw_acceptance, accept_many), rota series (create_series, assign_slot, '
  'publish_drafts, revise_series, cancel_occurrence, cancel_series), reminders (set_reminders), '
  'coverage (record_contact_attempt, confirm_by_leader, cancel_position), completion '
  '(record_outcome, correct_outcome) and owner reviews (clear_review) through the 1.4 envelope.';

comment on function app.duties_state_ok(text, text) is
  'Duties state vocabularies (stories 4.1-4.12). Later stories widen them by replacing this '
  'function.';

comment on function api.followups_command(jsonb) is
  'Stories 4.6 and 4.12: follow-up tasks (followups.create_task for manual purposes, update_task, '
  'reassign) and an Admin''s complete_handover (the next 100 open tasks of a member who left) '
  'through the 1.4 envelope.';

comment on function app.followups_state_ok(text, text) is
  'Follow-ups state vocabularies (stories 4.6, 4.7 and 4.12). Later stories widen them by replacing '
  'this function.';
