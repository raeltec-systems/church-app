#!/usr/bin/env node
// Story 4.1 end-to-end on the LOCAL stack: publish a one-position department duty and accept it,
// through real GoTrue phone sign-in (no SMS), the real Data API (PostgREST), the 1.9 system route
// and the real worker script (tools/notifications/worker.mjs), proving the ticket's verify at the
// API level:
//   * an Admin creates `SYNTHETIC Preaching Rota`, makes a leader with identity.grant_scope
//     (Duties-registered `department_leader`) and adds two members; a plain member cannot create;
//   * a non-leader cannot publish; the leader publishes one duty to member M with a response
//     deadline; a replay returns the stored result;
//   * one worker run delivers M's new-duty inbox item, whose open target is the duty's deep link
//     /duties/assignments/<id>; the other member has no item;
//   * the other member and the non-leader cannot answer M's duty, nor see a leader board; M
//     accepts with a note; the leader board shows Accepted at once; a second answer is refused;
//   * direct table queries on the Duties tables are refused for a signed-in member.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900960-900969. Evidence is redacted JSONL:
// statuses, codes, counts; never tokens, passwords, numbers or the credential. Every user,
// member, link, grant, department, duty, job, item and receipt it created is removed; the run's
// credential is revoked and its principal disabled (content-free sys_audit and append-only
// operator-journal rows stay).
//
// Usage: node tools/identity-e2e/duties.mjs [--evidence <file.jsonl>]
import { execFile } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 4.1 E2E';
export const DEPARTMENT = 'SYNTHETIC Preaching Rota';

/** The reserved fictional numbers this run uses (+44 7700 900960-900969). */
export function isFictionalDutiesPhone(phone) {
  return /^\+44770090096[0-9]$/.test(phone);
}

/** The deep link a duties_assignment reminder opens. */
export function dutyLink(assignmentId) {
  return `/duties/assignments/${assignmentId}`;
}

/** The first position's assignment of a duty (leader board or publish answer). */
export function firstAssignment(duty) {
  return duty?.positions?.[0]?.assignment ?? null;
}

/** A refused direct table query: an error status and no rows in the body. */
export function refusedTableQuery(r) {
  return r.status >= 400 && !Array.isArray(r.json);
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
    return { status: r.status, json: r.json, detail: r.json?.details ?? null };
  };
  const at = (ms) => new Date(Date.now() + ms).toISOString();
  const DAY = 86_400_000;

  const people = {
    admin: { phone: '+447700900960', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900961', name: `${NAME_PREFIX} Leader` },
    member: { phone: '+447700900962', name: `${NAME_PREFIX} Member M` },
    other: { phone: '+447700900963', name: `${NAME_PREFIX} Member O` },
    plain: { phone: '+447700900964', name: `${NAME_PREFIX} Non-leader` },
  };
  for (const p of Object.values(people)) if (!isFictionalDutiesPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
    psql(`select app.platform_set_environment('local', 'duties-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('D00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  // The run's worker principal and credential (only the digest is registered).
  const run = randomUUID().slice(0, 8);
  const credential = `sysc_local_${randomBytes(32).toString('base64url')}`;
  const principal = psql(`select app.sys_create_principal('notifications-worker-duties-${run}', 'notifications_worker', '${OPERATOR}')`);
  const credentialId = JSON.parse(psql(`select app.sys_register_credential('${principal}',
    '${createHash('sha256').update(credential).digest('hex')}', 'duties e2e ${run}', interval '2 hours', '${OPERATOR}')`)).credential_id;
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

  try {
    const { admin, leader, member, other, plain } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'duties-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    check('D01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(admin.token) });

    // ------------------------------------------------------------------ Admin department setup
    const notAdmin = await duties(plain.token, 'duties.create_department', null, { name: DEPARTMENT });
    const created = await duties(admin.token, 'duties.create_department', null, { name: DEPARTMENT });
    const departmentId = created.data?.department_id;
    const overview = await read('duties_admin_overview', admin.token);
    const listed = overview.json?.departments?.find((d) => d.department_id === departmentId);
    check('D10-admin-creates-the-department', notAdmin.code === 'forbidden' && created.status === 200
      && created.revision === 1 && listed?.name === DEPARTMENT && listed?.is_synthetic === true
      && Object.keys(created.data ?? {}).sort().join(',') === 'department_id,revision',
      { non_admin: notAdmin.code, status: created.status, revision: created.revision, answer_keys: Object.keys(created.data ?? {}).sort() });
    const grantsRev = (p) => overview.json?.members?.find((m) => m.member_id === p.member)?.grants_revision;
    const grant = await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantsRev(leader),
      { member_id: leader.member, scope_kind: 'department_leader', scope_id: departmentId });
    check('D11-admin-grants-the-leader-scope', grant.status === 200
      && grant.data?.scopes?.some((s) => s.scope_kind === 'department_leader' && s.scope_id === departmentId),
      { status: grant.status, code: grant.code ?? null });
    const addM = await duties(admin.token, 'duties.add_member', 1, { department_id: departmentId, member_id: member.member });
    const addO = await duties(admin.token, 'duties.add_member', 2, { department_id: departmentId, member_id: other.member });
    const afterAdd = (await read('duties_admin_overview', admin.token)).json?.departments
      ?.find((d) => d.department_id === departmentId);
    check('D12-admin-adds-two-members', addM.revision === 2 && addO.revision === 3 && afterAdd?.members?.length === 2
      && afterAdd?.leaders?.[0]?.member_id === leader.member,
      { revisions: [addM.revision, addO.revision], members: afterAdd?.members?.length });

    // ------------------------------------------------------------------------------ publishing
    const draft = {
      department_id: departmentId, duty_name: 'Sunday preaching', starts_at: at(10 * DAY),
      ends_at: at(10 * DAY + 7_200_000), location: 'SYNTHETIC Main hall', instructions: 'SYNTHETIC: arrive early.',
      member_id: member.member, response_deadline: at(7 * DAY),
    };
    const byPlain = await duties(plain.token, 'duties.publish_duty', null, draft);
    const byOther = await duties(other.token, 'duties.publish_duty', null, draft);
    check('D20-non-leaders-cannot-publish', byPlain.code === 'forbidden' && byOther.code === 'forbidden',
      { non_leader: byPlain.code, member: byOther.code });
    const late = await duties(leader.token, 'duties.publish_duty', null, { ...draft, response_deadline: at(11 * DAY) });
    check('D21-deadline-never-after-the-start', late.code === 'validation_failed'
      && late.field_errors?.response_deadline === 'after_start', { code: late.code, field_errors: late.field_errors });
    const publishRequest = randomUUID();
    const published = await duties(leader.token, 'duties.publish_duty', null, draft, publishRequest);
    const replay = await duties(leader.token, 'duties.publish_duty', null, draft, publishRequest);
    const assignmentId = published.data?.assignment_id;
    const assignment = firstAssignment((await read('duties_leader_board', leader.token)).json?.departments?.[0]?.duties?.[0]);
    const occurrences = Number(psql(`select count(*) from app.duties_occurrences where department_id = '${departmentId}'`));
    check('D22-leader-publishes-one-position', published.status === 200 && assignment?.response === 'pending'
      && assignment?.member_id === member.member && published.data?.notice_queued === true
      && JSON.stringify(replay.data) === JSON.stringify(published.data) && occurrences === 1,
      { status: published.status, response: assignment?.response, replay_same: JSON.stringify(replay.data) === JSON.stringify(published.data), occurrences });

    // ------------------------------------------------------------------------------- inbox
    const delivered = await worker();
    const inboxM = (await read('notifications_my_inbox', member.token)).json?.items ?? [];
    const inboxO = (await read('notifications_my_inbox', other.token)).json?.items ?? [];
    const item = inboxM.find((i) => i.reminder_kind === 'duty_assigned');
    const opened = item ? (await rpc('notifications_open_item', member.token, { item_id: item.item_id })).json : null;
    check('D30-member-sees-the-duty-in-the-inbox', delivered.exit === 0 && delivered.delivered >= 1 && Boolean(item)
      && opened?.state === 'current' && opened?.target === dutyLink(assignmentId) && opened?.title === 'New duty assigned'
      && inboxO.length === 0,
      { worker: { exit: delivered.exit, delivered: delivered.delivered }, item: Boolean(item), state: opened?.state,
        target_is_duty_link: opened?.target === dutyLink(assignmentId), other_items: inboxO.length });

    // ------------------------------------------------------------------------------ refusals
    const byOtherAnswer = await duties(other.token, 'duties.respond', 1, { assignment_id: assignmentId, response: 'accepted' });
    const byPlainAnswer = await duties(plain.token, 'duties.respond', 1, { assignment_id: assignmentId, response: 'accepted' });
    const minesO = (await read('duties_my_duties', other.token)).json?.assignments ?? [];
    const boardPlain = await read('duties_leader_board', plain.token);
    const boardOther = await read('duties_leader_board', other.token);
    const signedOut = await http('POST', '/rest/v1/rpc/duties_my_duties', { body: {}, profile: 'api' });
    check('D31-others-are-refused', byOtherAnswer.code === 'not_found' && byPlainAnswer.code === 'not_found'
      && minesO.length === 0 && boardPlain.status === 403 && boardPlain.detail === 'not_granted'
      && boardOther.status === 403 && [401, 403].includes(signedOut.status),
      { other_answer: byOtherAnswer.code, non_leader_answer: byPlainAnswer.code, other_duties: minesO.length,
        boards: [boardPlain.status, boardOther.status], signed_out: signedOut.status });
    const tables = [];
    for (const t of ['duties_assignments', 'duties_departments', 'duties_department_members', 'duties_audit']) {
      for (const profile of ['app', 'api']) {
        const r = await http('GET', `/rest/v1/${t}?select=*`, { token: member.token, profile });
        tables.push({ t, profile, status: r.status, refused: refusedTableQuery(r) });
      }
    }
    const rpcTable = await http('POST', '/rest/v1/rpc/duties_respond', { token: member.token, profile: 'app', body: {} });
    check('D32-direct-table-queries-refused', tables.every((x) => x.refused) && rpcTable.status >= 400,
      { statuses: tables.map((x) => `${x.profile}.${x.t}:${x.status}`), app_rpc: rpcTable.status });

    // ------------------------------------------------------------------------------ accepting
    const mine = (await read('duties_my_duties', member.token)).json?.assignments ?? [];
    const accepted = await duties(member.token, 'duties.respond', mine[0]?.revision,
      { assignment_id: assignmentId, response: 'accepted', note: 'SYNTHETIC note: happy to serve.' });
    const board = (await read('duties_leader_board', leader.token)).json;
    const onBoard = firstAssignment(board?.departments?.[0]?.duties?.[0]);
    const again = await duties(member.token, 'duties.respond', accepted.revision, { assignment_id: assignmentId, response: 'declined' });
    const reopened = item ? (await rpc('notifications_open_item', member.token, { item_id: item.item_id })).json : null;
    check('D40-member-accepts-and-leader-sees-accepted', mine.length === 1 && mine[0]?.response === 'pending'
      && accepted.status === 200 && accepted.data?.response === 'accepted' && accepted.revision === 2
      && onBoard?.response === 'accepted' && onBoard?.note === 'SYNTHETIC note: happy to serve.'
      && again.code === 'conflict' && again.field_errors?.assignment_id === 'responded'
      && reopened?.state === 'superseded',
      { before: mine[0]?.response, after: accepted.data?.response, revision: accepted.revision, board: onBoard?.response,
        second_answer: again.code, item_after: reopened?.state });
    const audit = psql(`select string_agg(action || ':' || actor_capacity, ',' order by event_id) from app.duties_audit
      where department_id = '${departmentId}'`);
    const receiptNames = Number(psql(`select count(*) from app.cmd_receipts where command like 'duties.%'
      and (result::text like '%${NAME_PREFIX}%' or result::text like '%SYNTHETIC note%')`));
    check('D42-receipts-hold-no-names-or-notes', receiptNames === 0, { receipts_with_names: receiptNames });
    check('D41-audit-is-content-free', audit === 'department_created:admin,member_added:admin,member_added:admin,duty_published:department_leader,response_recorded:member',
      { audit });
  } finally {
    const left = cleanup();
    psql(`select app.sys_revoke_credential('${credentialId}', '${OPERATOR}'); select app.sys_disable_principal('${principal}', '${OPERATOR}');`);
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'duties-e2e';
            delete from app.platform_environment_history where set_by = 'duties-e2e';`);
    }
    log('D99-cleanup', { users_left: Number(left), credential_revoked: true, principal_disabled: true, unmarked: marked,
      departments_left: Number(psql(`select count(*) from app.duties_departments where name = '${DEPARTMENT}'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
