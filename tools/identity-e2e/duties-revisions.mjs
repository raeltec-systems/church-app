#!/usr/bin/env node
// Story 4.2 end-to-end on the LOCAL stack: revise assignments on material change and refuse stale
// responses, through real GoTrue phone sign-in (no SMS), the real Data API (PostgREST), the 1.9
// system route and the real worker script (tools/notifications/worker.mjs), proving the ticket's
// verify at the API level:
//   * a member accepts a duty; the leader changes its time (material): a new pending revision
//     with a new deadline, the old acceptance kept in history with its provenance, the old
//     revision's pending reminder cancelled (`source_revised`) and one generic change notice;
//   * a late accept of the old revision is refused with what changed; the old inbox item opens
//     out of date, the change notice opens the new revision;
//   * a notes-only edit by the deputy keeps Accepted and sends a generic update;
//   * the leader and the deputy edit the same revision at once: one success, one conflict;
//   * a replayed request returns the original result; non-managers are refused; receipts and
//     audit hold no names or notes.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900980-900989. Evidence is redacted JSONL:
// statuses, codes, counts; never tokens, passwords, numbers or the credential. Everything it
// created is removed; the run's credential is revoked and its principal disabled.
//
// Usage: node tools/identity-e2e/duties-revisions.mjs [--evidence <file.jsonl>]
import { execFile } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 4.2 E2E';
export const DEPARTMENT = 'SYNTHETIC Preaching Rota 4.2';

/** The reserved fictional numbers this run uses (+44 7700 900980-900989). */
export function isFictionalRevisionPhone(phone) {
  return /^\+44770090098[0-9]$/.test(phone);
}

/** The changed fields of a stale-response refusal, in order of the field_errors. */
export function changedFields(fieldErrors) {
  return Object.entries(fieldErrors ?? {}).filter(([, v]) => v === 'changed').map(([k]) => k).sort();
}

/** Exactly one success and one conflict among concurrent answers. */
export function oneWinner(answers) {
  const ok = answers.filter((a) => a.status === 200 && !a.code).length;
  const conflicts = answers.filter((a) => a.code === 'conflict').length;
  return ok === 1 && conflicts === answers.length - 1;
}

/** The first position of a duty on the leader board. */
export function firstPosition(duty) {
  return duty?.positions?.[0] ?? null;
}

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const { origin, key } = keys;
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const envelope = (fn, token, cmd, expected, payload, requestId = randomUUID()) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: requestId, expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const duties = (token, cmd, expected, payload, requestId) => envelope('duties_command', token, cmd, expected, payload, requestId);
  const read = async (fn, token) => {
    const r = await rpc(fn, token);
    return { status: r.status, json: r.json };
  };
  const now = Date.now();
  const at = (ms) => new Date(now + ms).toISOString();
  const DAY = 86_400_000;

  const people = {
    admin: { phone: '+447700900980', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900981', name: `${NAME_PREFIX} Leader` },
    deputy: { phone: '+447700900982', name: `${NAME_PREFIX} Deputy` },
    member: { phone: '+447700900983', name: `${NAME_PREFIX} Member M` },
    other: { phone: '+447700900984', name: `${NAME_PREFIX} Member O` },
  };
  for (const p of Object.values(people)) if (!isFictionalRevisionPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const cleanup = () => {
    const ids = [...users].map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    create temp table gone_departments as
      select d.department_id from app.duties_departments d where d.name = '${DEPARTMENT}';
    create temp table gone_assignments as
      select a.assignment_id from app.duties_assignments a
        join app.duties_slots s on s.slot_id = a.slot_id
        join app.duties_occurrences o on o.occurrence_id = s.occurrence_id
       where o.department_id in (select department_id from gone_departments);
    delete from app.notifications_inbox_items i where i.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_attempts a using app.notifications_jobs j
     where a.job_id = j.job_id and (j.recipient_member_id in (select member_id from gone_members)
                                    or j.source_id in (select assignment_id from gone_assignments));
    delete from app.notifications_push_jobs p where p.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_direct_contact_needs n where n.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_jobs j where j.recipient_member_id in (select member_id from gone_members)
       or j.source_id in (select assignment_id from gone_assignments);
    delete from app.duties_audit a where a.department_id in (select department_id from gone_departments)
       or a.actor_member_id in (select member_id from gone_members);
    delete from app.duties_slot_revisions r using app.duties_occurrences o
     where r.occurrence_id = o.occurrence_id and o.department_id in (select department_id from gone_departments);
    delete from app.duties_assignments a where a.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_slots s using app.duties_occurrences o
     where s.occurrence_id = o.occurrence_id and o.department_id in (select department_id from gone_departments);
    delete from app.duties_occurrences o where o.department_id in (select department_id from gone_departments);
    delete from app.duties_department_members dm where dm.department_id in (select department_id from gone_departments);
    delete from app.identity_access_audit a
     where a.target_member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_grants g where g.member_id in (select member_id from gone_members)
       or g.scope_id in (select department_id from gone_departments);
    delete from app.duties_departments d where d.department_id in (select department_id from gone_departments);
    delete from app.identity_grant_sets s where s.member_id in (select member_id from gone_members);
    delete from app.identity_holds h where h.member_id in (select member_id from gone_members);
    delete from app.identity_binding_history h using app.identity_account_links l
     where h.link_id = l.link_id and (l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users));
    delete from app.identity_credential_events e using app.identity_account_links l
     where e.link_id = l.link_id and (l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users));
    delete from app.identity_account_links l
     where l.member_id in (select member_id from gone_members) or l.auth_user_id in (select id from gone_users);
    delete from app.identity_members m where m.member_id in (select member_id from gone_members);
    delete from app.cmd_receipts r where r.actor_id in (select id from gone_users);
    delete from auth.users u where u.id in (select id from gone_users);
    select count(*) from auth.users u where ${byUser} u.phone in (${digits});`);
  };

  const settings = await http('GET', '/auth/v1/settings');
  if (settings.json?.external?.phone !== true) {
    throw new Error('the local phone provider is off: run `node tools/auth-harness/local-phone-auth.mjs on` first');
  }
  const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
  let marked = false;
  if (marker === '') {
    psql(`select app.platform_set_environment('local', 'duties-revisions-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('R00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  const run = randomUUID().slice(0, 8);
  const credential = `sysc_local_${randomBytes(32).toString('base64url')}`;
  const principal = psql(`select app.sys_create_principal('notifications-worker-revisions-${run}', 'notifications_worker', '${OPERATOR}')`);
  const credentialId = JSON.parse(psql(`select app.sys_register_credential('${principal}',
    '${createHash('sha256').update(credential).digest('hex')}', 'duties revisions e2e ${run}', interval '2 hours', '${OPERATOR}')`)).credential_id;
  const worker = async () => {
    try {
      const { stdout } = await promisify(execFile)('node', [join(ROOT, 'tools/notifications/worker.mjs'), 'run-once'], {
        encoding: 'utf8',
        env: { PATH: process.env.PATH, SUPABASE_URL: origin, SUPABASE_PUBLISHABLE_KEY: key, NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL: credential } });
      const line = stdout.split('\n').find((l) => l.startsWith('{'));
      return { exit: 0, ...(line ? JSON.parse(line) : {}) };
    } catch (e) {
      return { exit: e.code ?? 1, error: String(e.stderr ?? '').trim().slice(-160) };
    }
  };
  const jobs = (assignmentId) => psql(`select coalesce(string_agg(reminder_kind || ':' || job_state || ':'
      || coalesce(cancel_reason, finish_reason, '-'), ',' order by enqueued_at, reminder_kind, job_state), '')
    from app.notifications_jobs where source_type = 'duties_assignment' and source_id = '${assignmentId}'`);

  try {
    const { admin, leader, deputy, member, other } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'duties-revisions-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    check('R01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(admin.token) });

    // -------------------------------------------------------------- setup: department, publish, accept
    const created = await duties(admin.token, 'duties.create_department', null, { name: DEPARTMENT });
    const departmentId = created.data?.department_id;
    const overview = (await read('duties_admin_overview', admin.token)).json;
    const grantsRev = (p) => overview?.members?.find((m) => m.member_id === p.member)?.grants_revision;
    const g1 = await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantsRev(leader),
      { member_id: leader.member, scope_kind: 'department_leader', scope_id: departmentId });
    const g2 = await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantsRev(deputy),
      { member_id: deputy.member, scope_kind: 'department_deputy', scope_id: departmentId });
    const addM = await duties(admin.token, 'duties.add_member', 1, { department_id: departmentId, member_id: member.member });
    const addO = await duties(admin.token, 'duties.add_member', 2, { department_id: departmentId, member_id: other.member });
    const published = await duties(leader.token, 'duties.publish_duty', null, {
      department_id: departmentId, duty_name: 'Sunday preaching', starts_at: at(10 * DAY), ends_at: at(10 * DAY + 7_200_000),
      location: 'SYNTHETIC Main hall', instructions: 'SYNTHETIC: arrive early.', member_id: member.member,
      response_deadline: at(7 * DAY),
    });
    const occurrenceId = published.data?.occurrence_id;
    const firstId = published.data?.assignment_id;
    const delivered1 = await worker();
    const item1 = ((await read('notifications_my_inbox', member.token)).json?.items ?? [])
      .find((i) => i.reminder_kind === 'duty_assigned');
    const accepted = await duties(member.token, 'duties.respond', 1,
      { assignment_id: firstId, response: 'accepted', note: 'SYNTHETIC note: happy to serve.' });
    check('R02-member-accepts-the-duty', created.status === 200 && g1.status === 200 && g2.status === 200
      && addM.revision === 2 && addO.revision === 3 && published.status === 200 && delivered1.delivered >= 1
      && Boolean(item1) && accepted.data?.response === 'accepted',
      { publish: published.status, worker: delivered1.delivered, item: Boolean(item1), answer: accepted.data?.response });

    // ---------------------------------------------------------- material change: the time moves
    // A pending future job on the accepted assignment stands in for its later reminders (entry 8).
    psql(`select app.notifications_enqueue(jsonb_build_object('source_type', 'duties_assignment',
      'source_id', '${firstId}', 'source_revision', 2, 'recipient_member_id', '${member.member}',
      'reminder_kind', 'duty_updated', 'scheduled_at', '${at(DAY)}'))`);
    const reviseRequest = randomUUID();
    const revisePayload = { occurrence_id: occurrenceId, starts_at: at(11 * DAY), ends_at: at(11 * DAY + 7_200_000),
      response_deadline: at(8 * DAY) };
    const revised = await duties(leader.token, 'duties.revise_duty', 1, revisePayload, reviseRequest);
    const secondId = revised.data?.assignment_id;
    const board = (await read('duties_leader_board', leader.token)).json;
    const position = firstPosition(board?.departments?.[0]?.duties?.[0]);
    const history = position?.history?.[0];
    check('R10-time-change-creates-a-new-pending-revision', revised.status === 200 && revised.data?.change === 'material'
      && secondId && secondId !== firstId && revised.data?.superseded_assignment_id === firstId
      && position?.assignment?.assignment_id === secondId && position?.assignment?.response === 'pending'
      && JSON.stringify(position?.assignment?.changes) === '["starts_at","ends_at"]' && position?.slot_revision === 2,
      { status: revised.status, change: revised.data?.change, new_revision: secondId !== firstId,
        board_response: position?.assignment?.response, changes: position?.assignment?.changes, slot_revision: position?.slot_revision });
    check('R11-old-acceptance-kept-in-history', history?.assignment_id === firstId && history?.state === 'superseded'
      && history?.response === 'accepted' && history?.response_provenance === 'member' && Boolean(history?.responded_at)
      && history?.note === 'SYNTHETIC note: happy to serve.',
      { state: history?.state, response: history?.response, provenance: history?.response_provenance });
    const oldJobs = jobs(firstId);
    const newJobs = jobs(secondId);
    check('R12-old-reminders-cancelled-and-one-change-notice', oldJobs === 'duty_assigned:delivered:delivered,duty_updated:cancelled:source_revised'
      && newJobs === 'duty_changed:pending:-', { old_jobs: oldJobs, new_jobs: newJobs });

    const delivered2 = await worker();
    const items = (await read('notifications_my_inbox', member.token)).json?.items ?? [];
    const changeItem = items.find((i) => i.reminder_kind === 'duty_changed');
    const openedChange = changeItem ? (await rpc('notifications_open_item', member.token, { item_id: changeItem.item_id })).json : null;
    const openedOld = item1 ? (await rpc('notifications_open_item', member.token, { item_id: item1.item_id })).json : null;
    check('R13-generic-change-notice-opens-the-new-revision', delivered2.delivered === 1 && openedChange?.state === 'current'
      && openedChange?.title === 'Duty changed' && openedChange?.target === `/duties/assignments/${secondId}`
      && openedOld?.state === 'superseded',
      { worker: delivered2.delivered, title: openedChange?.title, opens_new: openedChange?.target === `/duties/assignments/${secondId}`,
        old_item: openedOld?.state });

    // ------------------------------------------------------------------- stale response refused
    const late = await duties(member.token, 'duties.respond', 3, { assignment_id: firstId, response: 'accepted' });
    const mine = (await read('duties_my_duties', member.token)).json?.assignments ?? [];
    check('R20-late-accept-of-the-old-revision-refused', late.code === 'conflict'
      && late.field_errors?.assignment_id === 'superseded'
      && JSON.stringify(changedFields(late.field_errors)) === '["ends_at","starts_at"]'
      && mine.length === 1 && mine[0]?.assignment_id === secondId && mine[0]?.response === 'pending'
      && mine[0]?.previous_response === 'accepted' && mine[0]?.previous_assignment_ids?.[0] === firstId,
      { code: late.code, field_errors: late.field_errors, listed: mine.length, previous: mine[0]?.previous_response });

    // ---------------------------------------------------------- notes-only change keeps Accepted
    const accepted2 = await duties(member.token, 'duties.respond', 1, { assignment_id: secondId, response: 'accepted' });
    const notes = await duties(deputy.token, 'duties.revise_duty', 2,
      { occurrence_id: occurrenceId, instructions: 'SYNTHETIC: bring a Bible.' });
    const mineAfter = (await read('duties_my_duties', member.token)).json?.assignments ?? [];
    const boardAfter = firstPosition((await read('duties_leader_board', leader.token)).json?.departments?.[0]?.duties?.[0]);
    const delivered3 = await worker();
    const updateItem = ((await read('notifications_my_inbox', member.token)).json?.items ?? [])
      .find((i) => i.reminder_kind === 'duty_updated');
    check('R30-notes-only-edit-keeps-accepted', accepted2.data?.response === 'accepted' && notes.status === 200
      && notes.data?.change === 'notes' && notes.data?.assignment_id === secondId && notes.data?.response === 'accepted'
      && mineAfter[0]?.response === 'accepted' && mineAfter[0]?.instructions === 'SYNTHETIC: bring a Bible.'
      && Boolean(mineAfter[0]?.notes_updated_at) && boardAfter?.assignment?.response === 'accepted'
      && delivered3.delivered === 1 && updateItem?.title === 'Duty details updated',
      { change: notes.data?.change, member_sees: mineAfter[0]?.response, leader_sees: boardAfter?.assignment?.response,
        update_notice: updateItem?.title ?? null });

    // ---------------------------------------------------------- concurrent edits: one wins
    const race = await Promise.all([
      duties(leader.token, 'duties.revise_duty', 3, { occurrence_id: occurrenceId, instructions: 'SYNTHETIC: leader text.' }),
      duties(deputy.token, 'duties.revise_duty', 3, { occurrence_id: occurrenceId, instructions: 'SYNTHETIC: deputy text.' }),
    ]);
    const loser = race.find((r) => r.code === 'conflict');
    check('R40-two-leaders-at-once-one-success-one-conflict', oneWinner(race) && loser?.current_revision === 4,
      { answers: race.map((r) => r.code ?? r.status), current_revision: loser?.current_revision ?? null });

    // ---------------------------------------------------------------------------------- replay
    const replay = await duties(leader.token, 'duties.revise_duty', 1, revisePayload, reviseRequest);
    const count = Number(psql(`select count(*) from app.duties_assignments a join app.duties_slots s using (slot_id)
      where s.occurrence_id = '${occurrenceId}'`));
    check('R41-replay-returns-the-original-result', JSON.stringify(replay.data) === JSON.stringify(revised.data)
      && replay.revision === revised.revision && count === 2, { same: JSON.stringify(replay.data) === JSON.stringify(revised.data), assignments: count });

    // -------------------------------------------------------------------------------- refusals
    const byMember = await duties(other.token, 'duties.revise_duty', 4, { occurrence_id: occurrenceId, instructions: 'x' });
    const tables = [];
    for (const t of ['duties_slot_revisions', 'duties_assignments']) {
      for (const profile of ['app', 'api']) {
        const r = await http('GET', `/rest/v1/${t}?select=*`, { token: member.token, profile });
        tables.push({ t, profile, status: r.status, refused: r.status >= 400 && !Array.isArray(r.json) });
      }
    }
    check('R50-non-managers-and-direct-tables-refused', byMember.code === 'forbidden' && tables.every((x) => x.refused),
      { member_revise: byMember.code, statuses: tables.map((x) => `${x.profile}.${x.t}:${x.status}`) });

    const receiptNames = Number(psql(`select count(*) from app.cmd_receipts where command like 'duties.%'
      and (result::text like '%${NAME_PREFIX}%' or result::text like '%SYNTHETIC note%' or result::text like '%SYNTHETIC:%')`));
    const audit = psql(`select string_agg(action || ':' || coalesce(code, '-'), ',' order by event_id) from app.duties_audit
      where department_id = '${departmentId}' and action in ('duty_revised', 'response_recorded')`);
    check('R60-receipts-and-audit-content-free', receiptNames === 0
      && audit === 'response_recorded:accepted,duty_revised:material,response_recorded:accepted,duty_revised:notes,duty_revised:notes',
      { receipts_with_text: receiptNames, audit });
  } finally {
    const left = cleanup();
    psql(`select app.sys_revoke_credential('${credentialId}', '${OPERATOR}'); select app.sys_disable_principal('${principal}', '${OPERATOR}');`);
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'duties-revisions-e2e';
            delete from app.platform_environment_history where set_by = 'duties-revisions-e2e';`);
    }
    log('R99-cleanup', { users_left: Number(left), credential_revoked: true, principal_disabled: true, unmarked: marked,
      departments_left: Number(psql(`select count(*) from app.duties_departments where name = '${DEPARTMENT}'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
