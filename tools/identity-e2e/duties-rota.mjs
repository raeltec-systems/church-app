#!/usr/bin/env node
// Story 4.3 end-to-end on the LOCAL stack: recurring multi-position rotas with drafts and series
// edits, through real GoTrue phone sign-in (no SMS), the real Data API (PostgREST), the 1.9
// system route and the real worker script (tools/notifications/worker.mjs), proving the ticket's
// verify at the API level:
//   * a leader generates a quarterly Sunday series with three positions as drafts (church time);
//     a member sees no draft and cannot read the rota; planning drafts notifies nobody;
//   * two leaders planning or publishing from the same revision at once: one success, one
//     conflict; Publish N draft slots publishes with one new-duty notice per assignment;
//   * 2 of 3 confirmed is derived from the current positions;
//   * one occurrence is edited (this date), then this and later dates: earlier and started
//     occurrences are unchanged and each occurrence keeps its own responses;
//   * a member's answer racing a series edit ends consistent;
//   * one occurrence is cancelled: its jobs are cancelled and a generic cancellation notice is
//     delivered; a late answer is refused;
//   * replays return the original result, a revoked leader's replay is refused, receipts hold no
//     names or text, direct table queries are refused.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards. Needs a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900740-900749. Evidence is redacted JSONL:
// statuses, codes, counts; never tokens, passwords, numbers or the credential. Everything it
// created is removed; the run's credential is revoked and its principal disabled.
//
// Usage: node tools/identity-e2e/duties-rota.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { churchClock, churchInstant, churchSunday, notificationsWorker, oneWinner } from './duties-shared.mjs';

export { churchSunday, churchInstant, churchClock, oneWinner } from './duties-shared.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 4.3 E2E';
export const DEPARTMENT = 'SYNTHETIC Preaching Rota 4.3';

/** The reserved fictional numbers this run uses (+44 7700 900740-900749). */
export function isFictionalRotaPhone(phone) {
  return /^\+44770090074[0-9]$/.test(phone);
}

/** The occurrences of a series in a rota read, in date order. */
export function seriesOccurrences(rota, seriesId) {
  for (const d of rota?.departments ?? []) {
    for (const s of d.series ?? []) if (s.series_id === seriesId) return s.occurrences ?? [];
  }
  return [];
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

  const people = {
    admin: { phone: '+447700900740', name: `${NAME_PREFIX} Admin` },
    leader: { phone: '+447700900741', name: `${NAME_PREFIX} Leader` },
    deputy: { phone: '+447700900742', name: `${NAME_PREFIX} Deputy` },
    member: { phone: '+447700900743', name: `${NAME_PREFIX} Member M` },
    other: { phone: '+447700900744', name: `${NAME_PREFIX} Member O` },
  };
  for (const p of Object.values(people)) if (!isFictionalRotaPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
    -- Story 4.8: duties schedule reminders (member and leader schedules) and record Needs contact.
    delete from app.notifications_schedules s where s.recipient_member_id in (select member_id from gone_members)
       or s.source_id in (select assignment_id from gone_assignments);
    delete from app.duties_contact_needs n where n.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_audit a where a.department_id in (select department_id from gone_departments)
       or a.actor_member_id in (select member_id from gone_members);
    delete from app.duties_slot_revisions r using app.duties_occurrences o
     where r.occurrence_id = o.occurrence_id and o.department_id in (select department_id from gone_departments);
    delete from app.duties_assignments a where a.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_slots s using app.duties_occurrences o
     where s.occurrence_id = o.occurrence_id and o.department_id in (select department_id from gone_departments);
    delete from app.duties_occurrences o where o.department_id in (select department_id from gone_departments);
    delete from app.duties_series r where r.department_id in (select department_id from gone_departments);
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
    psql(`select app.platform_set_environment('local', 'duties-rota-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('O00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  const run = randomUUID().slice(0, 8);
  const { principal, credentialId, worker } = notificationsWorker({ origin, key, operator: OPERATOR,
    principalName: `notifications-worker-rota-${run}`, label: `duties rota e2e ${run}` });
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
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'duties-rota-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    // A member without a login (an approved member record only).
    const accountless = psql(`insert into app.identity_members (display_name, membership_state, is_synthetic)
      values ('${NAME_PREFIX} Accountless X', 'approved', true) returning member_id`);
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    check('O01-members-signed-in-by-phone', Object.values(people).every((p) => amrMethods(p.token).includes('password')),
      { amr: amrMethods(admin.token) });

    // -------------------------------------------------------------- setup: department and roles
    const created = await duties(admin.token, 'duties.create_department', null, { name: DEPARTMENT });
    const departmentId = created.data?.department_id;
    const overview = (await read('duties_admin_overview', admin.token)).json;
    const grantsRev = (p) => overview?.members?.find((m) => m.member_id === p.member)?.grants_revision;
    const g1 = await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantsRev(leader),
      { member_id: leader.member, scope_kind: 'department_leader', scope_id: departmentId });
    const g2 = await envelope('identity_grant_command', admin.token, 'identity.grant_scope', grantsRev(deputy),
      { member_id: deputy.member, scope_kind: 'department_deputy', scope_id: departmentId });
    let rev = 1;
    const added = [];
    for (const m of [member.member, other.member, accountless]) {
      added.push(await duties(admin.token, 'duties.add_member', rev, { department_id: departmentId, member_id: m }));
      rev += 1;
    }
    check('O02-department-roles-and-members', created.status === 200 && g1.status === 200 && g2.status === 200
      && added.every((a) => a.status === 200 && !a.code), { added: added.map((a) => a.revision) });

    // -------------------------------------------------------------- generate a quarterly series
    const now = Date.now();
    const first = churchSunday(now, 0);
    const last = churchSunday(now, 12);
    const seriesRequest = randomUUID();
    const seriesPayload = {
      department_id: departmentId, duty_name: 'Sunday service', every: 'week', from_date: first, until_date: last,
      start_time: '10:00', location: 'SYNTHETIC Main hall', instructions: 'SYNTHETIC: arrive early.',
      positions: ['Preacher', 'Reader', 'Usher'],
    };
    const gen = await duties(leader.token, 'duties.create_series', null, seriesPayload, seriesRequest);
    const seriesId = gen.data?.series_id;
    const rotaRead = async (token = leader.token) => (await read('duties_rota', token)).json;
    let occ = seriesOccurrences(await rotaRead(), seriesId);
    check('O10-quarterly-sunday-series-generated-as-drafts', gen.status === 200 && gen.data?.occurrences === 13
      && gen.data?.draft_slots === 39 && occ.length === 13 && occ.every((o) => o.state === 'draft')
      && occ[0].series_date === first && occ.every((o) => churchClock(o.starts_at) === '10:00')
      && occ.every((o) => new Date(`${o.series_date}T00:00:00Z`).getUTCDay() === 0)
      && occ.every((o) => o.positions.length === 3),
      { status: gen.status, occurrences: gen.data?.occurrences, draft_slots: gen.data?.draft_slots,
        all_sundays_at_10_church_time: occ.every((o) => churchClock(o.starts_at) === '10:00') });

    const replayGen = await duties(leader.token, 'duties.create_series', null, seriesPayload, seriesRequest);
    const seriesCount = Number(psql(`select count(*) from app.duties_series where department_id = '${departmentId}'`));
    check('O11-generation-replay-is-idempotent', JSON.stringify(replayGen.data) === JSON.stringify(gen.data) && seriesCount === 1,
      { same: JSON.stringify(replayGen.data) === JSON.stringify(gen.data), series: seriesCount });

    const memberDuties = (await read('duties_my_duties', member.token)).json?.assignments ?? [];
    const memberRota = await read('duties_rota', member.token);
    const tables = [];
    for (const t of ['duties_series', 'duties_occurrences', 'duties_slots']) {
      for (const profile of ['app', 'api']) {
        const r = await http('GET', `/rest/v1/${t}?select=*`, { token: member.token, profile });
        tables.push({ t, profile, status: r.status, refused: r.status >= 400 && !Array.isArray(r.json) });
      }
    }
    check('O12-member-cannot-see-drafts', memberDuties.length === 0 && memberRota.status === 403
      && tables.every((x) => x.refused),
      { my_duties: memberDuties.length, rota: memberRota.status, statuses: tables.map((x) => `${x.profile}.${x.t}:${x.status}`) });

    // -------------------------------------------------------------- plan positions (drafts)
    const slot = (o, n) => o.positions[n - 1].slot_id;
    const assign = (token, o, n, memberId, expected, extra = {}) =>
      duties(token, 'duties.assign_slot', expected, { slot_id: slot(o, n), member_id: memberId, ...extra });
    const race = await Promise.all([
      assign(leader.token, occ[0], 1, member.member, 1),
      assign(deputy.token, occ[0], 1, other.member, 1),
    ]);
    const plannedMember = psql(`select draft_member_id from app.duties_slots where slot_id = '${slot(occ[0], 1)}'`);
    check('O13-two-leaders-planning-at-once-one-wins', oneWinner(race),
      { answers: race.map((r) => r.code ?? r.status), planned: plannedMember === member.member ? 'leader' : 'deputy' });
    if (plannedMember !== member.member) await assign(leader.token, occ[0], 1, member.member, 2);
    occ = seriesOccurrences(await rotaRead(), seriesId);
    await assign(leader.token, occ[0], 2, other.member, occ[0].revision);
    occ = seriesOccurrences(await rotaRead(), seriesId);
    await assign(leader.token, occ[0], 3, accountless, occ[0].revision);
    await assign(leader.token, occ[1], 1, member.member, occ[1].revision);
    await assign(leader.token, occ[2], 1, member.member, occ[2].revision);
    occ = seriesOccurrences(await rotaRead(), seriesId);
    const draftJobs = Number(psql(`select count(*) from app.notifications_jobs
      where recipient_member_id in ('${member.member}', '${other.member}', '${accountless}')`));
    const noLogin = (await rotaRead()).departments?.[0]?.members?.find((m) => m.member_id === accountless)?.account;
    check('O14-drafts-planned-without-notices', draftJobs === 0 && occ[0].positions[2].draft?.member_id === accountless
      && noLogin === 'no_login' && (await read('duties_my_duties', member.token)).json?.assignments?.length === 0,
      { jobs: draftJobs, accountless_label: noLogin });

    // -------------------------------------------------------------- Publish N draft slots
    const publishRequest = randomUUID();
    const publishPayload = { series_id: seriesId, slot_count: 39, deadline_before: '1 day' };
    const pubs = await Promise.all([
      duties(leader.token, 'duties.publish_drafts', 1, publishPayload, publishRequest),
      duties(deputy.token, 'duties.publish_drafts', 1, publishPayload),
    ]);
    const published = pubs[0].code ? pubs[1] : pubs[0];
    occ = seriesOccurrences(await rotaRead(), seriesId);
    const delivered = await worker();
    const inboxM = ((await read('notifications_my_inbox', member.token)).json?.items ?? [])
      .filter((i) => i.reminder_kind === 'duty_assigned');
    const xJob = jobs(occ[0].positions[2].assignment?.assignment_id);
    check('O20-publish-n-draft-slots-once', oneWinner(pubs) && published.data?.slots === 39
      && published.data?.assignments === 5 && published.data?.notices_queued === 5
      && occ.every((o) => o.state === 'published') && inboxM.length === 3 && delivered.exit === 0
      && occ[3].positions.every((p) => p.assignment === null),
      { answers: pubs.map((r) => r.code ?? r.status), data: published.data, member_items: inboxM.length,
        accountless_job: xJob, unfilled_example: occ[3].positions.every((p) => p.assignment === null) });
    const pubReplay = await duties(leader.token, 'duties.publish_drafts', 1, publishPayload, publishRequest);
    check('O21-publish-replay-returns-the-original-result', pubs[0].code
      ? pubReplay.code === 'conflict' : JSON.stringify(pubReplay.data) === JSON.stringify(pubs[0].data),
      { replay: pubReplay.code ?? 'same' });

    // -------------------------------------------------------------- answers and coverage
    const a1 = occ[0].positions[0].assignment.assignment_id;
    const a2 = occ[0].positions[1].assignment.assignment_id;
    const r1 = await duties(member.token, 'duties.respond', 1, { assignment_id: a1, response: 'accepted', note: 'SYNTHETIC note.' });
    const r2 = await duties(other.token, 'duties.respond', 1, { assignment_id: a2, response: 'accepted' });
    occ = seriesOccurrences(await rotaRead(), seriesId);
    const board = (await read('duties_leader_board', leader.token)).json?.departments?.[0]?.duties ?? [];
    check('O30-two-of-three-confirmed-from-current-positions', r1.data?.response === 'accepted' && r2.data?.response === 'accepted'
      && occ[0].confirmed === 2 && occ[0].required === 3 && occ[0].positions[2].assignment?.response === 'pending'
      && board.length === 13,
      { coverage: `${occ[0].confirmed} of ${occ[0].required}`, board_duties: board.length });

    // -------------------------------------------------------------- edit this date
    const before0 = JSON.stringify(occ[0]);
    const thisEdit = await duties(leader.token, 'duties.revise_duty', occ[1].revision, {
      occurrence_id: occ[1].occurrence_id, starts_at: churchInstant(occ[1].series_date, '09:00'),
      response_deadline: churchInstant(occ[1].series_date, '08:00'),
    });
    occ = seriesOccurrences(await rotaRead(), seriesId);
    check('O40-edit-this-date-only', thisEdit.data?.change === 'material' && churchClock(occ[1].starts_at) === '09:00'
      && occ[1].positions[0].assignment?.response === 'pending' && JSON.stringify(occ[0]) === before0,
      { change: thisEdit.data?.change ?? thisEdit.code, first_unchanged: JSON.stringify(occ[0]) === before0 });

    // -------------------------------------------------------------- this and later dates
    // Occurrence 5 has started (its time came while the rota was being edited).
    psql(`update app.duties_occurrences set starts_at = now() - interval '1 minute' where occurrence_id = '${occ[4].occurrence_id}'`);
    occ = seriesOccurrences(await rotaRead(), seriesId);
    const started5 = JSON.stringify(occ[4]);
    const keep0 = JSON.stringify(occ[0]);
    const keep1 = JSON.stringify(occ[1]);
    const series1 = (await rotaRead()).departments[0].series.find((s) => s.series_id === seriesId);
    const future = await duties(leader.token, 'duties.revise_series', series1.revision, {
      series_id: seriesId, from_occurrence_id: occ[2].occurrence_id, start_time: '11:00', deadline_before: '2 days' });
    occ = seriesOccurrences(await rotaRead(), seriesId);
    const later = occ.slice(2).filter((_, i) => i !== 2);
    check('O41-this-and-later-dates-keep-the-past', future.status === 200 && future.data?.occurrences === 10
      && later.every((o) => churchClock(o.starts_at) === '11:00') && JSON.stringify(occ[0]) === keep0
      && JSON.stringify(occ[1]) === keep1 && JSON.stringify(occ[4]) === started5,
      { data: future.data, earlier_unchanged: JSON.stringify(occ[0]) === keep0 && JSON.stringify(occ[1]) === keep1,
        started_unchanged: JSON.stringify(occ[4]) === started5 });
    const ownIds = new Set(occ.flatMap((o) => o.positions.map((p) => p.assignment?.assignment_id)).filter(Boolean));
    const totalAssigned = occ.flatMap((o) => o.positions.filter((p) => p.assignment)).length;
    check('O42-each-occurrence-keeps-its-own-responses', ownIds.size === totalAssigned && occ[0].confirmed === 2,
      { distinct_assignments: ownIds.size, positions_assigned: totalAssigned, first_coverage: occ[0].confirmed });

    // -------------------------------------------------------------- answer racing a series edit
    const raceAssignment = occ[2].positions[0].assignment;
    const series2 = (await rotaRead()).departments[0].series.find((s) => s.series_id === seriesId);
    const [raceEdit, raceAnswer] = await Promise.all([
      duties(deputy.token, 'duties.revise_series', series2.revision, {
        series_id: seriesId, from_occurrence_id: occ[2].occurrence_id, location: 'SYNTHETIC Side hall', deadline_before: '2 days' }),
      duties(member.token, 'duties.respond', raceAssignment.revision, { assignment_id: raceAssignment.assignment_id, response: 'accepted' }),
    ]);
    const kept = psql(`select response from app.duties_assignments where assignment_id = '${raceAssignment.assignment_id}'`);
    const answeredFirst = raceAnswer.status === 200 && !raceAnswer.code;
    check('O43-answer-racing-a-series-edit-is-consistent', raceEdit.status === 200 && !raceEdit.code
      && (answeredFirst ? kept === 'accepted'
        : raceAnswer.code === 'conflict' && raceAnswer.field_errors?.assignment_id === 'superseded' && kept === 'pending'),
      { order: answeredFirst ? 'answer_first' : 'edit_first', answer: raceAnswer.code ?? raceAnswer.data?.response, kept });

    // -------------------------------------------------------------- cancel one date
    occ = seriesOccurrences(await rotaRead(), seriesId);
    const cancelTarget = occ[1];
    const cancelled = cancelTarget.positions[0].assignment.assignment_id;
    const cancel = await duties(leader.token, 'duties.cancel_occurrence', cancelTarget.revision,
      { occurrence_id: cancelTarget.occurrence_id });
    const cancelJobs = jobs(cancelled);
    const delivered2 = await worker();
    const cancelItem = ((await read('notifications_my_inbox', member.token)).json?.items ?? [])
      .find((i) => i.title === 'Duty cancelled');
    const lateAnswer = await duties(member.token, 'duties.respond', 2, { assignment_id: cancelled, response: 'accepted' });
    occ = seriesOccurrences(await rotaRead(), seriesId);
    const mine = (await read('duties_my_duties', member.token)).json?.assignments ?? [];
    check('O50-cancel-one-date-cancels-its-jobs', cancel.data?.state === 'cancelled' && cancel.data?.assignments_cancelled === 1
      && /source_cancelled/.test(cancelJobs) && /duty_cancelled:/.test(cancelJobs) && Boolean(cancelItem)
      && lateAnswer.code === 'conflict' && lateAnswer.field_errors?.assignment_id === 'cancelled'
      && occ[1].state === 'cancelled' && occ[0].state === 'published'
      && !mine.some((m) => m.occurrence_id === cancelTarget.occurrence_id) && delivered2.exit === 0,
      { jobs: cancelJobs, notice: cancelItem?.title ?? null, late: lateAnswer.field_errors?.assignment_id ?? lateAnswer.code });

    // -------------------------------------------------------------- refusals and replay
    const byMember = await duties(other.token, 'duties.create_series', null, seriesPayload);
    const series3 = (await rotaRead()).departments[0].series.find((s) => s.series_id === seriesId);
    const byOther = await duties(other.token, 'duties.cancel_series', series3.revision,
      { series_id: seriesId, from_occurrence_id: occ[5].occurrence_id });
    const revoke = await envelope('identity_grant_command', admin.token, 'identity.revoke_scope',
      Number(psql(`select revision from app.identity_grant_sets where member_id = '${leader.member}'`)),
      { member_id: leader.member, scope_kind: 'department_leader', scope_id: departmentId });
    const revokedReplay = await duties(leader.token, 'duties.create_series', null, seriesPayload, seriesRequest);
    const revokedRota = await read('duties_rota', leader.token);
    check('O60-non-managers-and-revoked-replay-refused', byMember.code === 'forbidden' && byOther.code === 'forbidden'
      && revoke.status === 200 && revokedReplay.code === 'forbidden' && revokedRota.status === 403,
      { member: byMember.code, other: byOther.code, revoked_replay: revokedReplay.code, revoked_read: revokedRota.status });

    const receiptText = Number(psql(`select count(*) from app.cmd_receipts where command like 'duties.%'
      and (result::text like '%${NAME_PREFIX}%' or result::text like '%SYNTHETIC%' or result::text like '%Preacher%')`));
    check('O70-receipts-content-free', receiptText === 0, { receipts_with_text: receiptText });
  } finally {
    const left = cleanup();
    psql(`select app.sys_revoke_credential('${credentialId}', '${OPERATOR}'); select app.sys_disable_principal('${principal}', '${OPERATOR}');`);
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'duties-rota-e2e';
            delete from app.platform_environment_history where set_by = 'duties-rota-e2e';`);
    }
    log('O99-cleanup', { users_left: Number(left), credential_revoked: true, principal_disabled: true, unmarked: marked,
      departments_left: Number(psql(`select count(*) from app.duties_departments where name = '${DEPARTMENT}'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
