// Shared cleanup for the cells E2E runs (story 5.11 refactor): the SQL that removes everything a
// run created, by its SYNTHETIC name prefix, its cells and department names, and its users (ids and
// fictional phone numbers). It covers every Cells table through story 5.9 (cells, memberships,
// schedules, meetings, programmes, projections, notices, meeting records and actual leaders,
// handover obligations), the run's Duties occurrences and assignments, and their Notifications rows.
// The final statement counts the run's users left (0 after a clean run). LOCAL runs only: callers
// pass it to `psql` from harness.mjs.

/** SQL quoting for a name the run chose (SYNTHETIC text only). */
function lit(text) {
  if (typeof text !== 'string' || !/^SYNTHETIC [ -~]*$/.test(text) || text.includes("'")) {
    throw new Error('cells cleanup takes SYNTHETIC names only');
  }
  return text;
}

/**
 * @param {{namePrefix: string, shikoswe: string, estates: string, department: string,
 *          userIds: Iterable<string>, phones: string[]}} run
 */
export function cellsCleanupSql({ namePrefix, shikoswe, estates, department, userIds, phones }) {
  lit(namePrefix); lit(shikoswe); lit(estates); lit(department);
  const ids = [...userIds].map((u) => {
    if (!/^[0-9a-f-]{36}$/.test(u ?? '')) throw new Error('bad user id');
    return `'${u}'`;
  });
  const digits = phones.map((p) => {
    if (!/^\+[0-9]{8,15}$/.test(p)) throw new Error('bad phone');
    return `'${p.slice(1)}'`;
  }).join(',');
  const byUser = ids.length ? `u.id in (${ids.join(',')}) or ` : '';
  return `
    create temp table gone_users as select u.id from auth.users u where ${byUser} u.phone in (${digits});
    create temp table gone_members as
      select m.member_id from app.identity_members m where m.display_name like '${namePrefix}%';
    create temp table gone_departments as
      select d.department_id from app.duties_departments d where d.name = '${department}';
    create temp table gone_cells as
      select c.cell_id from app.cells_cells c where c.name in ('${shikoswe}', '${estates}');
    create temp table gone_meetings as
      select m.meeting_id from app.cells_meetings m where m.cell_id in (select cell_id from gone_cells);
    create temp table gone_occurrences as
      select o.occurrence_id from app.duties_occurrences o
       where o.department_id in (select department_id from gone_departments)
          or o.cell_id in (select cell_id from gone_cells);
    create temp table gone_assignments as
      select a.assignment_id from app.duties_assignments a join app.duties_slots s on s.slot_id = a.slot_id
       where s.occurrence_id in (select occurrence_id from gone_occurrences);
    create temp table gone_jobs as
      select j.job_id from app.notifications_jobs j
       where j.recipient_member_id in (select member_id from gone_members)
          or j.source_id in (select assignment_id from gone_assignments)
          or j.source_id in (select meeting_id from gone_meetings)
          or j.source_id in (select n.notice_id from app.cells_absence_notices n
                              where n.cell_id in (select cell_id from gone_cells))
          or j.source_id in (select p.programme_id from app.cells_programmes p
                              where p.cell_id in (select cell_id from gone_cells));
    delete from app.notifications_push_jobs p where p.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_attempts a where a.job_id in (select job_id from gone_jobs);
    delete from app.notifications_direct_contact_needs n where n.job_id in (select job_id from gone_jobs);
    update app.notifications_jobs j set snoozed_from_item_id = null where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_inbox_items i where i.job_id in (select job_id from gone_jobs)
       or i.recipient_member_id in (select member_id from gone_members);
    delete from app.notifications_jobs j where j.job_id in (select job_id from gone_jobs);
    delete from app.notifications_schedules s where s.source_id in (select assignment_id from gone_assignments)
       or s.source_id in (select meeting_id from gone_meetings)
       or s.recipient_member_id in (select member_id from gone_members);
    delete from app.duties_contact_attempts t where t.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_coverage_cases c where c.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_contact_needs n where n.assignment_id in (select assignment_id from gone_assignments);
    delete from app.duties_audit a where a.department_id in (select department_id from gone_departments)
       or a.occurrence_id in (select occurrence_id from gone_occurrences)
       or a.actor_member_id in (select member_id from gone_members);
    delete from app.duties_slot_revisions r where r.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_assignments a where a.assignment_id in (select assignment_id from gone_assignments);
    -- Part links and review flags go with their slots and occurrences (the only way they are removed).
    delete from app.duties_slots s where s.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_occurrences o where o.occurrence_id in (select occurrence_id from gone_occurrences);
    delete from app.duties_series r where r.department_id in (select department_id from gone_departments);
    delete from app.duties_department_members dm where dm.department_id in (select department_id from gone_departments);
    delete from app.identity_handover_obligations o where o.member_id in (select member_id from gone_members)
       or o.subject_id in (select cell_id from gone_cells);
    delete from app.cells_actual_leaders a where a.cell_id in (select cell_id from gone_cells);
    delete from app.cells_meeting_record_history h where h.cell_id in (select cell_id from gone_cells);
    delete from app.cells_meeting_records r where r.cell_id in (select cell_id from gone_cells);
    delete from app.cells_absence_audit a where a.cell_id in (select cell_id from gone_cells)
       or a.actor_member_id in (select member_id from gone_members);
    delete from app.cells_absence_notices n where n.cell_id in (select cell_id from gone_cells);
    delete from app.notifications_jobs j where j.source_type = 'cells_absence_notice'
       and j.job_id not in (select a.job_id from app.notifications_attempts a)
       and j.source_id not in (select n.notice_id from app.cells_absence_notices n);
    delete from app.cells_programme_projections pr where pr.cell_id in (select cell_id from gone_cells);
    delete from app.cells_programme_audit a where a.cell_id in (select cell_id from gone_cells)
       or a.actor_member_id in (select member_id from gone_members);
    delete from app.cells_programme_parts pt
     where pt.programme_id in (select p.programme_id from app.cells_programmes p where p.cell_id in (select cell_id from gone_cells));
    delete from app.cells_programmes p where p.cell_id in (select cell_id from gone_cells);
    delete from app.cells_meeting_contact_needs n where n.meeting_id in (select meeting_id from gone_meetings);
    delete from app.cells_reminders_audit a where a.cell_id in (select cell_id from gone_cells)
       or a.actor_member_id in (select member_id from gone_members);
    delete from app.cells_meeting_audit a where a.cell_id in (select cell_id from gone_cells)
       or a.actor_member_id in (select member_id from gone_members);
    delete from app.cells_meetings m where m.cell_id in (select cell_id from gone_cells);
    delete from app.cells_meeting_schedules s where s.cell_id in (select cell_id from gone_cells);
    delete from app.cells_membership_audit a
     where a.member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members)
        or a.cell_id in (select cell_id from gone_cells);
    -- Memberships and requests reference each other: one statement deletes both.
    with gone_memberships as (
      delete from app.cells_memberships m
       where m.member_id in (select member_id from gone_members) or m.cell_id in (select cell_id from gone_cells)
      returning m.membership_id)
    delete from app.cells_membership_requests r
     where r.member_id in (select member_id from gone_members) or r.requested_cell_id in (select cell_id from gone_cells);
    delete from app.cells_member_states s where s.member_id in (select member_id from gone_members);
    delete from app.cells_signup_options o where o.cell_id in (select cell_id from gone_cells);
    delete from app.identity_access_audit a
     where a.target_member_id in (select member_id from gone_members) or a.actor_member_id in (select member_id from gone_members);
    delete from app.identity_grants g where g.member_id in (select member_id from gone_members)
       or g.scope_id in (select department_id from gone_departments) or g.scope_id in (select cell_id from gone_cells);
    delete from app.duties_departments d where d.department_id in (select department_id from gone_departments);
    delete from app.cells_cells c where c.cell_id in (select cell_id from gone_cells);
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
    select count(*) from auth.users u where ${byUser} u.phone in (${digits});`;
}
