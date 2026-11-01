#!/usr/bin/env node
// Story 6.18 end-to-end on the LOCAL stack: a preaching duty's topic and scripture sent to Media as
// a sermon draft, through real GoTrue phone sign-in (no SMS) and the real Data API (PostgREST). It
// proves the ticket's verify at the API level:
//   * the assignee of a `SYNTHETIC Preaching Rota` duty with a topic sends it to Media
//     (content.draft_sermon_from_duty), and a second send returns the same draft; the department
//     leader gets the same draft too;
//   * a member without the duty, a leader of another department and Media itself are refused,
//     for the send and for the status read; a duty with no topic or scripture is refused;
//   * the draft is invisible to anonymous callers and members, Media sees it marked as from a duty
//     (never who sent it), an unfinished draft cannot be published, and it is public only after a
//     Media member completes and publishes it;
//   * no client role reads the link table.
// No notification is delivered (the worker is not run): queued duty notices are removed.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards, and a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900116-900121. Evidence is redacted JSONL:
// statuses, codes, counts and booleans; never tokens, passwords, numbers or names. Everything it
// created is removed.
//
// Usage: node tools/identity-e2e/content-sermon-duty-drafts.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { churchDayAt } from './content-events.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 6.18 E2E';
export const DEPARTMENT = 'SYNTHETIC Preaching Rota';
export const OTHER_DEPARTMENT = 'SYNTHETIC 6.18 E2E Ushers';
export const TOPIC = 'SYNTHETIC Walking in the light (6.18 E2E)';
export const SCRIPTURE = 'SYNTHETIC 1 John 1:5-10';
/** The status read: exactly these keys; the draft only says when it was sent and if published. */
export const STATUS_KEYS = ['can_send', 'draft', 'occurrence_id'];
export const FROM_DUTY_KEYS = ['duty_name', 'duty_starts_at', 'sent_at'];

/** The reserved fictional numbers this run uses (+44 7700 900116-900121). */
export function isFictionalDraftsPhone(phone) {
  return /^\+4477009001(1[6-9]|2[01])$/.test(phone);
}

/** A command answer that went through (no refusal code). */
export function done(r) {
  return r?.status === 200 && !r.code;
}

/** A refusal with this code and, when given, this field error. */
export function refused(r, code, field, value) {
  return r?.code === code && (!field || r.field_errors?.[field] === value);
}

/** Does any key or string of a JSON value (at any depth) name who sent a draft? */
export function namesSender(value) {
  if (Array.isArray(value)) return value.some(namesSender);
  if (value && typeof value === 'object') {
    return Object.entries(value).some(([k, v]) => /sent_by|sender|member|account/i.test(k) || namesSender(v));
  }
  return false;
}

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const envelope = (fn, token, cmd, expected, payload) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: randomUUID(), expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const duty = (token, cmd, expected, payload) => envelope('duties_command', token, cmd, expected, payload);
  const content = (token, cmd, expected, payload) => envelope('content_command', token, cmd, expected, payload);

  const people = {
    admin: { phone: '+447700900116', name: `${NAME_PREFIX} Admin` },
    media: { phone: '+447700900117', name: `${NAME_PREFIX} Media` },
    leader: { phone: '+447700900118', name: `${NAME_PREFIX} Leader L` },
    member: { phone: '+447700900119', name: `${NAME_PREFIX} Member M` },
    other: { phone: '+447700900120', name: `${NAME_PREFIX} Member O` },
    usherLead: { phone: '+447700900121', name: `${NAME_PREFIX} Leader K` },
  };
  for (const p of Object.values(people)) if (!isFictionalDraftsPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
  const users = new Set();
  const digits = Object.values(people).map((p) => `'${p.phone.slice(1)}'`).join(',');
  const cleanup = () => {
    const ids = [...users].filter(Boolean).map((u) => `'${u}'`);
    const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
    return psql(`
    begin;
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${NAME_PREFIX}%';
    create temp table gone_departments as
      select d.department_id from app.duties_departments d where d.name in ('${DEPARTMENT}', '${OTHER_DEPARTMENT}');
    create temp table gone_occurrences as
      select o.occurrence_id from app.duties_occurrences o where o.department_id in (select department_id from gone_departments);
    create temp table gone_items as
      select d.sermon_id as item_id from app.content_sermon_duty_drafts d
       where d.occurrence_id in (select occurrence_id from gone_occurrences)
      union select r.item_id from app.content_sermon_revisions r where r.title like '%(6.18 E2E)%';
    create temp table gone_assignments as
      select a.assignment_id from app.duties_assignments a join app.duties_slots s on s.slot_id = a.slot_id
       where s.occurrence_id in (select occurrence_id from gone_occurrences);
    create temp table gone_jobs as
      select j.job_id from app.notifications_jobs j
       where j.recipient_member_id in (select member_id from gone_members)
          or j.source_id in (select assignment_id from gone_assignments);
    delete from app.notifications_push_jobs p where p.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_attempts a where a.job_id in (select job_id from gone_jobs);
    delete from app.notifications_direct_contact_needs n where n.job_id in (select job_id from gone_jobs);
    update app.notifications_jobs j set snoozed_from_item_id = null where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_inbox_items i where i.job_id in (select job_id from gone_jobs)
       or i.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_jobs j where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_schedules s where s.source_id in (select assignment_id from gone_assignments)
       or s.recipient_member_id in (select member_id from gone_members);
    delete from app.content_sermon_duty_drafts d where d.sermon_id in (select item_id from gone_items);
    delete from app.content_audit a where a.item_id in (select item_id from gone_items);
    delete from app.content_sermon_revisions r where r.item_id in (select item_id from gone_items);
    delete from app.content_items i where i.item_id in (select item_id from gone_items);
    delete from app.duties_contact_attempts t where t.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_coverage_cases c where c.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_contact_needs n where n.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_audit a where a.department_id in (select department_id from gone_departments)
       or a.occurrence_id in (select occurrence_id from gone_occurrences)
       or a.actor_member_id in (select member_id from gone_members) or a.member_id in (select member_id from gone_members);
    delete from app.duties_slot_revisions r where r.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_assignments a where a.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_slots s where s.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_occurrences o where o.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_department_members dm where dm.department_id in (select department_id from gone_departments);
    delete from app.identity_handover_obligations o where o.member_id in (select member_id from gone_members);
    delete from app.identity_access_audit a
     where a.target_member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_grants g where g.member_id in (select member_id from gone_members)
       or g.scope_id in (select department_id from gone_departments);
    delete from app.duties_departments d where d.department_id in (select department_id from gone_departments);
    delete from app.identity_contact_routes r where r.member_id in (select member_id from gone_members);
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
    commit;
    select count(*) from auth.users u where ${byUser} u.phone in (${digits});`);
  };

  const settings = await http('GET', '/auth/v1/settings');
  if (settings.json?.external?.phone !== true) {
    throw new Error('the local phone provider is off: run `node tools/auth-harness/local-phone-auth.mjs on` first');
  }
  const marker = psql(`select coalesce((select environment from app.platform_environment), '')`);
  let marked = false;
  if (marker === '') {
    psql(`select app.platform_set_environment('local', 'content-sermon-duty-drafts-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('D00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  const grantRevision = (m) => Number(psql(`select revision from app.identity_grant_sets where member_id = '${m}'`));
  const departmentRevision = (d) => Number(psql(`select revision from app.duties_departments where department_id = '${d}'`));
  const occRevision = (o) => Number(psql(`select revision from app.duties_occurrences where occurrence_id = '${o}'`));
  const itemRevision = (i) => Number(psql(`select revision from app.content_items where item_id = '${i}'`));

  try {
    const { admin, media, leader, member, other, usherLead } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'content-sermon-duty-drafts-e2e')`);
      p.token = (await signIn(p.phone, p.password)).json?.access_token;
    }
    psql(`select app.identity_bootstrap_admin('${admin.member}', '${OPERATOR}')`);
    const setup = [];
    const grant = async (cmd, p, payload) => (await envelope('identity_grant_command', admin.token, cmd,
      grantRevision(p.member), { member_id: p.member, ...payload })).code ?? 'done';
    setup.push(await grant('identity.grant_role', media, { role: 'media' }));
    const dept = await duty(admin.token, 'duties.create_department', null, { name: DEPARTMENT });
    const dept2 = await duty(admin.token, 'duties.create_department', null, { name: OTHER_DEPARTMENT });
    const d = dept.data?.department_id;
    const e = dept2.data?.department_id;
    for (const [p, scope] of [[leader, d], [usherLead, e]]) {
      setup.push(await grant('identity.grant_scope', p, { scope_kind: 'department_leader', scope_id: scope }));
    }
    for (const [m, dep] of [[leader.member, d], [member.member, d], [other.member, d], [usherLead.member, e]]) {
      setup.push((await duty(admin.token, 'duties.add_member', departmentRevision(dep), { department_id: dep, member_id: m })).code ?? 'done');
    }
    for (const p of [media, leader, usherLead]) p.token = (await signIn(p.phone, p.password)).json?.access_token;
    check('D01-signed-in-by-phone-with-media-and-two-departments', Object.values(people).every((p) => amrMethods(p.token).includes('password'))
      && done(dept) && done(dept2) && setup.every((s) => s === 'done'), { setup });

    // ------------------------------------------------------- the preaching duties
    const now = Date.now();
    const publish = (days, name) => duty(leader.token, 'duties.publish_duty', null, { department_id: d, member_id: member.member,
      duty_name: name, location: 'SYNTHETIC hall', starts_at: churchDayAt(now, days, '09:00') });
    const X = await publish(10, 'SYNTHETIC Sunday preaching');
    const Z = await publish(11, 'SYNTHETIC Sunday reading');
    const occ = { X: X.data?.occurrence_id, Z: Z.data?.occurrence_id };
    const topic = await duty(leader.token, 'duties.revise_duty', occRevision(occ.X),
      { occurrence_id: occ.X, topic: TOPIC, scripture: SCRIPTURE });
    check('D02-the-leader-publishes-a-preaching-duty-with-a-topic', done(X) && done(Z) && done(topic),
      { published: [X.code ?? 'done', Z.code ?? 'done'], topic: topic.code ?? 'done' });

    // ------------------------------------------------------- who may read and send
    const status = (token, o) => rpc('content_duty_sermon_draft', token, { occurrence_id: o });
    const ms = await status(member.token, occ.X);
    const refusedReads = [await status(other.token, occ.X), await status(usherLead.token, occ.X), await status(media.token, occ.X)];
    const anonRead = await status(undefined, occ.X);
    check('D10-only-the-assignee-and-managers-read-whether-it-was-sent', ms.status === 200 && ms.json?.can_send === true
      && ms.json?.draft === null && JSON.stringify(Object.keys(ms.json ?? {}).sort()) === JSON.stringify(STATUS_KEYS)
      && refusedReads.every((r) => r.status === 403) && anonRead.status >= 400,
      { member: [ms.status, ms.json?.can_send ?? null], refused: refusedReads.map((r) => r.status), guest: anonRead.status });
    const send = (token, o) => content(token, 'content.draft_sermon_from_duty', null, { occurrence_id: o });
    const refusedSends = [await send(other.token, occ.X), await send(usherLead.token, occ.X), await send(media.token, occ.X)];
    const noTopic = await send(leader.token, occ.Z);
    check('D11-a-member-without-the-duty-another-leader-and-media-are-refused', refusedSends.every((r) => refused(r, 'not_found'))
      && refused(noTopic, 'validation_failed', 'occurrence_id', 'no_topic')
      && Number(psql(`select count(*) from app.content_sermon_duty_drafts where occurrence_id in ('${occ.X}', '${occ.Z}')`)) === 0,
      { sends: refusedSends.map((r) => r.code ?? 'done'), no_topic: noTopic.field_errors?.occurrence_id ?? noTopic.code ?? 'done' });

    // ------------------------------------------------------- the assignee sends; again returns the same
    const first = await send(member.token, occ.X);
    const second = await send(member.token, occ.X);
    const byLeader = await send(leader.token, occ.X);
    const sermonId = first.data?.sermon_id;
    check('D20-the-assignee-sends-and-a-second-send-returns-the-same-draft', done(first) && first.data?.created === true
      && done(second) && second.data?.created === false && second.data?.sermon_id === sermonId
      && done(byLeader) && byLeader.data?.sermon_id === sermonId
      && Number(psql(`select count(*) from app.content_sermon_duty_drafts where occurrence_id = '${occ.X}'`)) === 1,
      { first: [first.code ?? 'done', first.data?.created ?? null], second: [second.code ?? 'done', second.data?.created ?? null],
        same_draft: second.data?.sermon_id === sermonId && byLeader.data?.sermon_id === sermonId });
    const row = psql(`select coalesce(speaker, '-') || '|' || (title = '${TOPIC}') || '|' || (scripture_reference = '${SCRIPTURE}')
      || '|' || i.lifecycle_state from app.content_sermon_revisions r join app.content_items i on i.item_id = r.item_id
      where r.item_id = '${sermonId}'`);
    const after = (await status(member.token, occ.X)).json;
    check('D21-a-private-draft-with-the-topic-and-scripture-and-no-speaker', row === '-|true|true|draft'
      && Boolean(after?.draft?.sent_at) && after?.draft?.published === false, { draft: row, sent: Boolean(after?.draft?.sent_at) });

    // ------------------------------------------------------- invisible until Media publishes
    const anonOne = (await rpc('content_public_sermon', undefined, { sermon_id: sermonId })).json;
    const memberList = (await rpc('content_public_sermons', member.token)).json;
    const memberStaff = await rpc('content_staff_sermons', member.token);
    const staff = (await rpc('content_staff_sermons', media.token)).json;
    const mine = (staff?.sermons ?? []).find((s) => s.sermon_id === sermonId);
    check('D30-the-draft-is-invisible-to-guests-and-members-and-marked-for-media', anonOne?.sermon === null
      && !JSON.stringify(memberList ?? {}).includes(TOPIC) && memberStaff.status === 403 && mine?.state === 'draft'
      && JSON.stringify(Object.keys(mine?.from_duty ?? {}).sort()) === JSON.stringify(FROM_DUTY_KEYS) && !namesSender(mine?.from_duty),
      { guest_sees: anonOne?.sermon !== null, member_catalog_has_it: JSON.stringify(memberList ?? {}).includes(TOPIC),
        member_staff: memberStaff.status, media_state: mine?.state ?? null, from_duty_keys: Object.keys(mine?.from_duty ?? {}).sort() });
    const early = await content(media.token, 'content.publish_sermon', itemRevision(sermonId), { sermon_id: sermonId });
    const saved = await content(media.token, 'content.save_sermon', itemRevision(sermonId), { sermon_id: sermonId,
      title: TOPIC, speaker: 'SYNTHETIC Preacher', sermon_date: mine?.draft?.sermon_date, scripture_reference: SCRIPTURE,
      notes: 'SYNTHETIC notes for testing.' });
    const stillPrivate = (await rpc('content_public_sermon', undefined, { sermon_id: sermonId })).json;
    const published = await content(media.token, 'content.publish_sermon', itemRevision(sermonId), { sermon_id: sermonId });
    const nowPublic = (await rpc('content_public_sermon', undefined, { sermon_id: sermonId })).json;
    check('D31-nothing-is-public-until-media-completes-and-publishes-it', refused(early, 'validation_failed', 'speaker', 'required')
      && done(saved) && stillPrivate?.sermon === null && done(published) && nowPublic?.sermon?.title === TOPIC
      && (await status(member.token, occ.X)).json?.draft?.published === true,
      { early: early.field_errors?.speaker ?? early.code ?? 'done', saved: saved.code ?? 'done',
        private_before_publish: stillPrivate?.sermon === null, published: published.code ?? 'done', public_after: nowPublic?.sermon?.title === TOPIC });

    // ------------------------------------------------------- tables refused
    const tables = [];
    for (const t of ['content_sermon_duty_drafts', 'content_sermon_revisions', 'duties_occurrences']) {
      for (const token of [undefined, member.token, media.token]) {
        tables.push((await http('GET', `/rest/v1/${t}?select=*`, { token, profile: 'app' })).status);
      }
    }
    check('D90-no-client-role-reads-the-link-or-the-duty-tables', tables.every((s) => s >= 400), { statuses: tables });
    if (process.argv.includes('--contention')) {
      const { runContention } = await import('./content-sermon-duty-lock.mjs');
      await runContention({ check, log, psql, people, duty, send, grant, department: d, occRevision, publish });
    }
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'content-sermon-duty-drafts-e2e';
            delete from app.platform_environment_history where set_by = 'content-sermon-duty-drafts-e2e';`);
    }
    log('D99-cleanup', { users_left: Number(left), unmarked: marked,
      departments_left: Number(psql(`select count(*) from app.duties_departments where name in ('${DEPARTMENT}', '${OTHER_DEPARTMENT}')`)),
      members_left: Number(psql(`select count(*) from app.identity_members where display_name like '${NAME_PREFIX}%'`)),
      sermons_left: Number(psql(`select count(*) from app.content_sermon_revisions where title like '%(6.18 E2E)%'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
