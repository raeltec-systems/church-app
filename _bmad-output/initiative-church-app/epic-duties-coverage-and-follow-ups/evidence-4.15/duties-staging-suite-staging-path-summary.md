# Duties closing suite summary (tools/identity-e2e/duties-staging-suite.mjs, target local --staging-path)

Scenario checks: 22/22 passed. Matrix cells: 253/253 as expected (22/22 matrix checks).

| Check | Verdict |
|---|---|
| S01-people-signed-in-and-principals-as-the-matrix-says | pass |
| S02-departments-scopes-and-members | pass |
| S10-a-rota-is-drafted-hidden-then-published | pass |
| S20-material-change-re-asks-and-the-late-answer-is-refused | pass |
| S30-accept-decline-later-decline-and-bulk-acceptance | pass |
| S40-overlap-warns-without-details-and-needs-a-reason | pass |
| S50-creator-deadline-default-reminders-and-short-notice | pass |
| S60-the-queue-shows-every-state-and-the-labelled-route | pass |
| S61-contact-attempt-opens-a-follow-up-and-confirmed-by-leader-closes-it | pass |
| S62-reassign-a-decline-cancel-a-position-and-oversight-without-private-data | pass |
| S80-follow-ups-owner-states-reassignment-and-routing | pass |
| S70-completion-outcomes-corrections-and-time-never-a-no-show | pass |
| S90-a-login-hold-keeps-the-duty-with-needs-contact | pass |
| S91-removal-vacates-with-the-reason-for-leaders-and-deputies-only | pass |
| S92-deactivation-vacates-with-member-inactive-and-restore | pass |
| S93-scope-loss-closes-reads-and-commands-at-once | pass |
| S94-revoking-the-last-reachable-leader-is-refused-handover-required | pass |
| S95-unlink-is-never-refused-records-the-handover-and-relinks-the-same-member | pass |
| S96-owner-operations-are-not-reachable-by-clients | pass |
| S99-nothing-private-reaches-a-member-and-every-item-is-generic | pass |
| S98-api-cleanup-cancels-closes-and-restores | pass |
| S99-staging-cleanup-sql-removes-the-run | pass |

## Reads (rows: surface; columns: principal)

| Read | anon | guest | held | deact | m1 | cellL | pastor | admin | leadA | depA | leadB |
|---|---|---|---|---|---|---|---|---|---|---|---|
| duties_admin_overview | 401 | 403 nl | 403 rr | 403 nl | 403 ng | 403 ng | 403 ng | 200 | 403 ng | 403 ng | 403 ng |
| duties_rota | 401 | 403 nl | 403 rr | 403 nl | 403 ng | 403 ng | 200 | 200 | 200 | 200 | 200 |
| duties_leader_board | 401 | 403 nl | 403 rr | 403 nl | 403 ng | 403 ng | 200 | 200 | 200 | 200 | 200 |
| duties_coverage | 401 | 403 nl | 403 rr | 403 nl | 403 ng | 403 ng | 200 | 200 | 200 | 200 | 403 ng |
| duties_candidates | 401 | 403 nl | 403 rr | 403 nl | 403 ng | 403 ng | 403 ng | 200 | 200 | 200 | 403 ng |
| duties_member_history | 401 | 403 nl | 403 rr | 403 nl | 200 | 403 ng | 403 ng | 403 ng | 200 | 200 | 200 |
| duties_my_duties | 401 | 403 nl | 403 rr | 403 nl | 200 | 200 | 200 | 200 | 200 | 200 | 200 |
| duties_outcomes | 401 | 403 nl | 403 rr | 403 nl | 403 ng | 403 ng | 403 ng | 403 ng | 200 | 200 | 200 |
| followups_admin_routing | 401 | 403 nl | 403 rr | 403 nl | 403 ng | 403 ng | 403 ng | 200 | 403 ng | 403 ng | 403 ng |
| followups_my_tasks | 401 | 403 nl | 403 rr | 403 nl | 200 | 200 | 200 | 200 | 200 | 200 | 200 |
| followups_supervision | 401 | 403 nl | 403 rr | 403 nl | 403 ng | 200 | 403 ng | 403 ng | 200 | 200 | 200 |
| followups_task | 401 | 403 nl | 403 rr | 403 nl | 200 | 403 ng | 403 ng | 200 | 200 | 200 | 403 ng |

## Command probes (rows: surface; columns: principal)

| Command | anon | guest | held | deact | m1 | cellL | pastor | admin | leadA | depA | leadB |
|---|---|---|---|---|---|---|---|---|---|---|---|
| duties.revise_duty | 401 | fb | fb | fb | fb | fb | fb | cf | cf | cf | fb |
| duties.set_reminders | 401 | fb | fb | fb | fb | fb | fb | cf | cf | cf | fb |
| duties.cancel_position | 401 | fb | fb | fb | fb | fb | fb | cf | cf | cf | fb |
| duties.confirm_by_leader | 401 | fb | fb | fb | nf | nf | nf | fb | cf | cf | nf |
| duties.record_contact_attempt | 401 | fb | fb | fb | nf | nf | nf | fb | cf | cf | nf |
| duties.respond | 401 | fb | fb | fb | cf | nf | nf | nf | nf | nf | nf |
| duties.withdraw_acceptance | 401 | fb | fb | fb | cf | nf | nf | nf | nf | nf | nf |
| duties.add_member | 401 | fb | fb | fb | fb | fb | fb | cf | fb | fb | fb |
| duties.remove_member | 401 | fb | fb | fb | fb | fb | fb | cf | fb | fb | fb |
| followups.update_task | 401 | fb | fb | fb | cf | nf | nf | fb | cf | cf | nf |
| followups.reassign | 401 | fb | fb | fb | fb | nf | nf | cf | cf | cf | nf |

Legend: reads 200 / 401 / 403 with detail (ng not_granted, nl not_linked, rr review_required); command envelope codes cf conflict (authorised, stale revision: nothing changed), fb forbidden, nf not_found (nothing disclosed), 401 signed out. A cell marked ≠ differs from the expectation. Principals: m1 an app member of A and B (owner of the probed task and assignment), cellL a cell leader with no department authority, admin the Admin role alone, leadA/depA department A's leader and deputy, leadB another department's leader; deact is deactivated. Scope loss and the accountless member are scenario checks (S90-scope-loss, S60).

## Not run on this target

- S97 linked-event mismatch flag: owner operations are SQL-only (no client route); proven locally (S97 and duties-decisions D10-D13). For the owner demonstration the parent session raises one flag as owner-demonstration.md B1 describes.
- Deletion (erase or anonymise Duties and Follow-ups data): needs the deletion worker; proven locally by duties-lifecycle L60.
- Two-connection races (stale answer vs edit, bulk vs edit, deactivation vs publish): proven locally by duties-revisions R70, duties-responses V30, duties-lifecycle L23-L25.
