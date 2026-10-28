#!/usr/bin/env node
// Story 6.12 end-to-end on the LOCAL stack: department duties linked to published events, through
// real GoTrue phone sign-in (no SMS) and the real Data API (PostgREST). It proves the ticket's
// verify at the API level:
//   * leaders link `SYNTHETIC Preaching Rota` and Ushers duties to a published SYNTHETIC event;
//     a draft event and an unknown id are refused as a link (`event_ref: not_published`);
//   * the member's duty detail carries the linked event, and the signed-out public event read
//     names no duty, rota or department;
//   * the editor reads how many duties are linked before saving (counts only), while a leader who
//     edits no events and a guest are refused;
//   * changing the event's time flags each linked department's duty once and queues one review
//     notice per reachable leader or deputy (not the editor, the Admin or the members); no duty is
//     republished and no answer is reset; withdrawing another linked event flags its duty as
//     cancelled; a withdrawn event cannot be newly linked; the leader clears the review;
//   * no client role reads the flags or the Content tables.
// No notification is delivered (the worker is not run): the notices stay queued and are removed.
//
// Needs the local phone switch: `node tools/auth-harness/local-phone-auth.mjs on`, then `off`
// afterwards, and a database with no usable Admin (`npx supabase db reset` first). LOCAL only
// (exact origin), SYNTHETIC fictional numbers +44 7700 900291-900299. Evidence is redacted JSONL:
// statuses, codes, counts and booleans; never tokens, passwords, numbers or names. Everything it
// created is removed.
//
// Usage: node tools/identity-e2e/content-event-duty-links.mjs [--evidence <file.jsonl>]
import { randomUUID } from 'node:crypto';

import { amrMethods, localHttp, localKey, password, psql, runMain, startRun } from './harness.mjs';
import { churchDayAt } from './content-events.mjs';

const OPERATOR = 'israel';
const NAME_PREFIX = 'SYNTHETIC 6.12 E2E';
const TAG = '(6.12 E2E)';
export const DEPARTMENT = 'SYNTHETIC Preaching Rota';
export const OTHER_DEPARTMENT = 'SYNTHETIC 6.12 E2E Ushers';
export const SUNDAY = `SYNTHETIC Sunday service ${TAG}`;
export const YOUTH = `SYNTHETIC Youth evening ${TAG}`;
export const RETREAT = `SYNTHETIC Draft retreat ${TAG}`;
/** The editors' count read: exactly these keys, counts only. */
export const COUNT_KEYS = ['event_id', 'linked_duties', 'reviews_open', 'truncated'];

/** The reserved fictional numbers this run uses (+44 7700 900291-900299). */
export function isFictionalLinksPhone(phone) {
  return /^\+44770090029[1-9]$/.test(phone);
}

/** A command answer that went through (no refusal code). */
export function done(r) {
  return r?.status === 200 && !r.code;
}

/** A refusal with this code and, when given, this field error. */
export function refused(r, code, field, value) {
  return r?.code === code && (!field || r.field_errors?.[field] === value);
}

/** One duty of the leader board by occurrence id. */
export function boardDuty(board, occurrenceId) {
  for (const d of board?.departments ?? []) {
    for (const o of d.duties ?? []) if (o.occurrence_id === occurrenceId) return o;
  }
  return null;
}

/** Does any key of a JSON value (at any depth) look like a duty, rota, department or review? */
export function namesDuties(value) {
  if (Array.isArray(value)) return value.some(namesDuties);
  if (value && typeof value === 'object') {
    return Object.entries(value).some(([k, v]) => /dut|rota|depart|review|flag/i.test(k) || namesDuties(v));
  }
  return false;
}

async function main() {
  const { log, check, finish } = startRun();
  const keys = localKey();
  const http = localHttp(keys);
  const signIn = (phone, pw) => http('POST', '/auth/v1/token?grant_type=password', { body: { phone, password: pw } });
  const rpc = (fn, token, body = {}) => http('POST', `/rest/v1/rpc/${fn}`, { token, body, profile: 'api' });
  const read = async (fn, token, body = {}) => (await rpc(fn, token, body)).json;
  const envelope = (fn, token, cmd, expected, payload) =>
    rpc(fn, token, { version: 1, command: cmd, request_id: randomUUID(), expected_revision: expected, payload })
      .then((r) => ({ status: r.status, ...r.json }));
  const duty = (token, cmd, expected, payload) => envelope('duties_command', token, cmd, expected, payload);
  const content = (token, cmd, expected, payload) => envelope('content_command', token, cmd, expected, payload);

  const people = {
    admin: { phone: '+447700900291', name: `${NAME_PREFIX} Admin` },
    media: { phone: '+447700900292', name: `${NAME_PREFIX} Media` },
    leader: { phone: '+447700900293', name: `${NAME_PREFIX} Leader L` },
    deputy: { phone: '+447700900294', name: `${NAME_PREFIX} Deputy P` },
    member: { phone: '+447700900295', name: `${NAME_PREFIX} Member M` },
    usherLead: { phone: '+447700900296', name: `${NAME_PREFIX} Leader K` },
    usher: { phone: '+447700900297', name: `${NAME_PREFIX} Member N` },
  };
  for (const p of Object.values(people)) if (!isFictionalLinksPhone(p.phone)) throw new Error(`not fictional: ${p.phone}`);
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
    create temp table gone_items as
      select distinct r.item_id from app.content_event_revisions r where r.title like 'SYNTHETIC % ${TAG}';
    create temp table gone_departments as
      select d.department_id from app.duties_departments d where d.name in ('${DEPARTMENT}', '${OTHER_DEPARTMENT}');
    create temp table gone_occurrences as
      select o.occurrence_id from app.duties_occurrences o where o.department_id in (select department_id from gone_departments);
    create temp table gone_assignments as
      select a.assignment_id from app.duties_assignments a join app.duties_slots s on s.slot_id = a.slot_id
       where s.occurrence_id in (select occurrence_id from gone_occurrences);
    create temp table gone_flags as
      select f.flag_id from app.duties_review_flags f where f.occurrence_id in (select occurrence_id from gone_occurrences);
    create temp table gone_jobs as
      select j.job_id from app.notifications_jobs j
       where j.recipient_member_id in (select member_id from gone_members)
          or j.source_id in (select assignment_id from gone_assignments)
          or j.source_id in (select flag_id from gone_flags);
    delete from app.notifications_push_jobs p where p.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_attempts a where a.job_id in (select job_id from gone_jobs);
    delete from app.notifications_direct_contact_needs n where n.job_id in (select job_id from gone_jobs);
    update app.notifications_jobs j set snoozed_from_item_id = null where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_inbox_items i where i.job_id in (select job_id from gone_jobs)
       or i.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_jobs j where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_schedules s where s.source_id in (select assignment_id from gone_assignments)
       or s.recipient_member_id in (select member_id from gone_members);
    delete from app.duties_contact_attempts t where t.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_coverage_cases c where c.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_contact_needs n where n.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_audit a where a.department_id in (select department_id from gone_departments)
       or a.occurrence_id in (select occurrence_id from gone_occurrences)
       or a.actor_member_id in (select member_id from gone_members) or a.member_id in (select member_id from gone_members);
    delete from app.duties_slot_revisions r where r.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_assignments a where a.assignment_id in (select assignment_id from gone_assignments);
    -- Review flags go with their occurrences (the only way they are removed).
    delete from app.duties_slots s where s.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_occurrences o where o.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_department_members dm where dm.department_id in (select department_id from gone_departments);
    delete from app.content_event_rsvps v where v.item_id in (select item_id from gone_items);
    delete from app.content_event_organisers o
     where o.item_id in (select item_id from gone_items) or o.member_id in (select member_id from gone_members);
    alter table app.content_revision_files disable trigger content_revision_files_draft_only;
    delete from app.content_revision_files f where f.item_id in (select item_id from gone_items);
    alter table app.content_revision_files enable trigger content_revision_files_draft_only;
    delete from app.content_audit a where a.item_id in (select item_id from gone_items);
    delete from app.content_event_revisions r where r.item_id in (select item_id from gone_items);
    delete from app.content_items i where i.item_id in (select item_id from gone_items);
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
    psql(`select app.platform_set_environment('local', 'content-event-duty-links-e2e')`);
    marked = true;
  } else if (marker !== 'local') {
    throw new Error(`local database is marked ${marker}`);
  }
  log('L00-precondition', {
    settings: { phone: settings.json?.external?.phone, sms_provider: settings.json?.sms_provider ?? null },
    leftover_users_removed: cleanup(),
  });

  const grantRevision = (m) => Number(psql(`select revision from app.identity_grant_sets where member_id = '${m}'`));
  const departmentRevision = (d) => Number(psql(`select revision from app.duties_departments where department_id = '${d}'`));
  const occRevision = (o) => Number(psql(`select revision from app.duties_occurrences where occurrence_id = '${o}'`));
  const eventRevision = (e) => Number(psql(`select revision from app.content_items where item_id = '${e}'`));
  const notices = (m) => Number(psql(`select count(*) from app.notifications_jobs where recipient_member_id = '${m}'
    and source_type = 'duties_review' and reminder_kind = 'duty_review_flagged'`));
  const flagsOf = (o) => psql(`select coalesce(string_agg(array_to_string(changed, '+'), ','), 'none')
    from app.duties_review_flags where occurrence_id = '${o}' and cleared_at is null`);
  const answerOf = (a) => psql(`select response || '|' || revision from app.duties_assignments where assignment_id = '${a}'`);

  try {
    const { admin, media, leader, deputy, member, usherLead, usher } = people;
    for (const p of Object.values(people)) {
      p.password = password();
      const created = await http('POST', '/auth/v1/admin/users', { admin: true, body: { phone: p.phone, phone_confirm: true, password: p.password } });
      p.user = created.json?.id;
      users.add(p.user);
      p.member = psql(`select app.identity_seed_synthetic_link('${p.user}', '${p.name}', 'content-event-duty-links-e2e')`);
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
    for (const [p, kind, scope] of [[leader, 'department_leader', d], [deputy, 'department_deputy', d], [usherLead, 'department_leader', e]]) {
      setup.push(await grant('identity.grant_scope', p, { scope_kind: kind, scope_id: scope }));
    }
    for (const [m, dep] of [[leader.member, d], [member.member, d], [usherLead.member, e], [usher.member, e]]) {
      setup.push((await duty(admin.token, 'duties.add_member', departmentRevision(dep), { department_id: dep, member_id: m })).code ?? 'done');
    }
    for (const p of [media, leader, deputy, usherLead]) p.token = (await signIn(p.phone, p.password)).json?.access_token;
    check('L01-signed-in-by-phone-with-a-media-editor-and-two-departments', Object.values(people).every((p) => amrMethods(p.token).includes('password'))
      && done(dept) && done(dept2) && setup.every((s) => s === 'done'), { setup });

    // ------------------------------------------------------- events and duties
    const now = Date.now();
    const event = (title, days, hhmm, location = 'SYNTHETIC Main hall') => ({ title, description: 'SYNTHETIC service for testing.',
      starts_at: churchDayAt(now, days, hhmm), ends_at: churchDayAt(now, days, '12:30'), location });
    const ids = {};
    for (const [k, title, days] of [['sunday', SUNDAY, 20], ['youth', YOUTH, 21], ['retreat', RETREAT, 22]]) {
      ids[k] = (await content(media.token, 'content.create_event', null, event(title, days, '09:00'))).data?.event_id;
    }
    const pubs = [];
    for (const k of ['sunday', 'youth']) pubs.push(await content(media.token, 'content.publish_event', eventRevision(ids[k]), { event_id: ids[k] }));
    const publish = (by, dep, who, days) => duty(by.token, 'duties.publish_duty', null, { department_id: dep, member_id: who,
      duty_name: `SYNTHETIC Duty ${days}`, location: 'SYNTHETIC hall', starts_at: churchDayAt(now, days, '09:00') });
    const X = await publish(leader, d, member.member, 20);
    const Z = await publish(leader, d, member.member, 21);
    const Y = await publish(usherLead, e, usher.member, 20);
    const occ = { X: X.data?.occurrence_id, Y: Y.data?.occurrence_id, Z: Z.data?.occurrence_id };
    const link = (by, k, eventRef) => duty(by.token, 'duties.revise_duty', occRevision(occ[k]), { occurrence_id: occ[k], event_ref: eventRef });
    const draftLink = await link(leader, 'X', ids.retreat);
    const unknownLink = await link(leader, 'X', randomUUID());
    check('L10-only-a-published-event-can-be-linked', pubs.every(done) && [X, Y, Z].every(done)
      && refused(draftLink, 'validation_failed', 'event_ref', 'not_published')
      && refused(unknownLink, 'validation_failed', 'event_ref', 'not_published'),
      { published: pubs.map((r) => r.code ?? 'done'), draft: draftLink.field_errors?.event_ref ?? draftLink.code ?? 'done',
        unknown: unknownLink.field_errors?.event_ref ?? unknownLink.code ?? 'done' });
    const before = answerOf(X.data?.assignment_id);
    const links = [await link(leader, 'X', ids.sunday), await link(usherLead, 'Y', ids.sunday), await link(leader, 'Z', ids.youth)];
    check('L11-leaders-link-their-duties-to-published-events', links.every((r) => done(r) && r.data?.change === 'reference'),
      { changes: links.map((r) => r.data?.change ?? r.code) });

    const mine = ((await read('duties_my_duties', member.token))?.assignments ?? []).find((a) => a.assignment_id === X.data?.assignment_id);
    const pub = await read('content_public_event', member.token, { event_id: mine?.event_ref });
    const anonList = await read('content_public_events', undefined);
    const anonOne = await read('content_public_event', undefined, { event_id: ids.sunday });
    check('L12-the-duty-detail-names-the-event-and-the-public-read-names-no-duty', mine?.event_ref === ids.sunday
      && pub?.event?.title === SUNDAY && Array.isArray(anonList?.events) && !namesDuties(anonList) && !namesDuties(anonOne)
      && anonOne?.event?.event_id === ids.sunday,
      { event_ref_matches: mine?.event_ref === ids.sunday, public_title_matches: pub?.event?.title === SUNDAY,
        public_list_names_duties: namesDuties(anonList), public_event_names_duties: namesDuties(anonOne) });

    // ------------------------------------------------------- the editor's count, before saving
    const count = (token, id) => rpc('content_staff_event_duty_links', token, { event_id: id });
    const mc = await count(media.token, ids.sunday);
    const lc = await count(leader.token, ids.sunday);
    const ac = await count(undefined, ids.sunday);
    check('L20-the-editor-sees-how-many-duties-are-linked-counts-only', mc.status === 200 && mc.json?.linked_duties === 2
      && mc.json?.reviews_open === 0 && JSON.stringify(Object.keys(mc.json ?? {}).sort()) === JSON.stringify(COUNT_KEYS)
      && lc.status === 403 && ac.status >= 400,
      { media: [mc.status, mc.json?.linked_duties ?? null, mc.json?.reviews_open ?? null], leader: lc.status, guest: ac.status,
        keys: Object.keys(mc.json ?? {}).sort() });

    // ------------------------------------------------------- a time change
    const saved = await content(media.token, 'content.save_event', eventRevision(ids.sunday),
      { event_id: ids.sunday, ...event(SUNDAY, 20, '10:00') });
    const flaggedBeforePublish = flagsOf(occ.X);
    const moved = await content(media.token, 'content.publish_event', eventRevision(ids.sunday), { event_id: ids.sunday });
    const n1 = [leader, deputy, usherLead, media, admin, member, usher].map((p) => notices(p.member));
    const after = answerOf(X.data?.assignment_id);
    check('L30-a-time-change-flags-each-department-once-with-one-notice-per-leader', done(saved) && done(moved)
      && flaggedBeforePublish === 'none' && flagsOf(occ.X) === 'time' && flagsOf(occ.Y) === 'time' && flagsOf(occ.Z) === 'none'
      && JSON.stringify(n1) === JSON.stringify([1, 1, 1, 0, 0, 0, 0]) && after === before,
      { flags: { X: flagsOf(occ.X), Y: flagsOf(occ.Y), Z: flagsOf(occ.Z) }, flagged_on_save: flaggedBeforePublish !== 'none',
        notices: { leader: n1[0], deputy: n1[1], other_leader: n1[2], editor: n1[3], admin: n1[4], member: n1[5], other_member: n1[6] },
        answer_unchanged: after === before });
    const board = await read('duties_leader_board', deputy.token);
    const xReview = boardDuty(board, occ.X)?.reviews?.[0];
    check('L31-the-department-sees-the-review-on-its-board', Boolean(xReview?.flag_id) && (xReview?.changed ?? []).join(',') === 'time',
      { review: Boolean(xReview?.flag_id), changed: xReview?.changed ?? null });

    // ------------------------------------------------------- cancellation
    const withdrawn = await content(media.token, 'content.withdraw_event', eventRevision(ids.youth), { event_id: ids.youth });
    const n2 = [leader, deputy, usherLead].map((p) => notices(p.member));
    const relink = await link(leader, 'X', ids.youth);
    check('L40-withdrawing-a-linked-event-flags-its-duty-cancelled', done(withdrawn) && flagsOf(occ.Z) === 'cancelled'
      && JSON.stringify(n2) === JSON.stringify([2, 2, 1]) && refused(relink, 'validation_failed', 'event_ref', 'not_published')
      && psql(`select event_ref from app.duties_occurrences where occurrence_id = '${occ.Z}'`) === ids.youth,
      { withdrawn: withdrawn.code ?? 'done', Z: flagsOf(occ.Z), notices: n2, relink: relink.field_errors?.event_ref ?? relink.code ?? 'done' });
    const mc2 = await count(media.token, ids.sunday);
    const cleared = await duty(leader.token, 'duties.clear_review', xReview?.revision, { flag_id: xReview?.flag_id });
    check('L41-the-leader-clears-the-review-and-the-editor-count-follows', mc2.json?.reviews_open === 2 && done(cleared)
      && flagsOf(occ.X) === 'none' && (await count(media.token, ids.sunday)).json?.reviews_open === 1,
      { reviews_open_before: mc2.json?.reviews_open ?? null, cleared: cleared.code ?? 'done' });

    // ------------------------------------------------------- tables refused
    const tables = [];
    for (const t of ['duties_review_flags', 'duties_link_sources', 'content_items', 'content_event_revisions']) {
      for (const token of [undefined, media.token, leader.token]) {
        tables.push((await http('GET', `/rest/v1/${t}?select=*`, { token, profile: 'app' })).status);
      }
    }
    check('L90-no-client-role-reads-the-flags-or-the-content-tables', tables.every((s) => s >= 400), { statuses: tables });
  } finally {
    const left = cleanup();
    if (marked) {
      psql(`delete from app.platform_environment where set_by = 'content-event-duty-links-e2e';
            delete from app.platform_environment_history where set_by = 'content-event-duty-links-e2e';`);
    }
    log('L99-cleanup', { users_left: Number(left), unmarked: marked,
      departments_left: Number(psql(`select count(*) from app.duties_departments where name in ('${DEPARTMENT}', '${OTHER_DEPARTMENT}')`)),
      members_left: Number(psql(`select count(*) from app.identity_members where display_name like '${NAME_PREFIX}%'`)),
      events_left: Number(psql(`select count(*) from app.content_event_revisions where title like 'SYNTHETIC % ${TAG}'`)) });
  }
  finish();
}

runMain(import.meta.url, main);
