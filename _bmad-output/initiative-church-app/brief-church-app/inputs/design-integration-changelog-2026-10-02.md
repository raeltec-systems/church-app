# Church App v1 design integration changelog

2 October 2026

The existing Church App v1 specification has been updated to include the six approved design additions in the first release. The milestones sequence delivery; they do not defer these features.

## Added to v1

1. **Cell meeting programmes:** ordered parts, topic/scripture, named leaders and member preview, using the same duty acceptance, conflict, reminder, replacement and reconfirmation rules. A Cannot attend notice stays separate from actual attendance and duty responses.
2. **Member-visible recaps:** draft, preview, publish, correct and withdraw, with summary/key points and a separate safe member view. Submitting a private report never automatically publishes a recap or testimony.
3. **Pastoral visits:** member requests, assigned care ownership, proposed dates/visitors/venues, acceptance, alternatives, decline/cancellation and outcomes. Included web board/list actions require real consent for the current proposal; dragging a card cannot manufacture confirmation.
4. **Service attendance:** scoped count entry and correction history, missing-versus-zero/cancelled states and clearly defined trends. Counts measure attendances, not unique people.
5. **Staff web portal:** shared accounts, backend permissions and workflow records, responsive staff views and accessible alternatives to grids/dragging. Essential mobile staff actions remain. Flutter Web is a proposed implementation approach to validate, not a framework decision attributed to the church.
6. **Cell offering register:** aggregate counts, two counter attestations, accountable handover, separate independent Treasurer receipt, discrepancies/corrections, scoped summaries and CSV export. It is a limited collection-custody register rather than a full accounting system.

## Cross-cutting changes

- Added scoped Treasurer, counter, service-recorder and care-visitor permissions. Admin does not automatically gain private care or financial content.
- Extended logical data entities, server-side transitions, notification cancellation, audit, staff handover, privacy, edge cases and launch acceptance tests across mobile and web.
- Made My follow-ups available to every task owner, including ordinary members.
- Preserved safe programme fields while protecting other members' private responses/notes. Cell changes remove old-cell access and resolve future old-cell assignments.
- Removed obsolete statements that web admin and all cell financial records are outside v1. Defined realistic handling of offline screens rather than promising remote erasure.

## Important boundaries retained

- Phone-first signup, optional email, separate member records/account links, separate church/cell approval, assisted no-login participation and existing recovery/security requirements
- Public Give is instruction-only. No app payment processing, individual donor ledger, gift claim, personal giving history, provider transaction verification or donor receipt
- No general ledger, bank reconciliation, expense/payroll system, automatic messaging or fabricated confirmation/delivery states
- The existing decision about whether chat launches immediately remains separate; the approved core works without it

## Still to confirm before launch

Church staff/permission assignments, safeguarding and testimony consent, retention, SMS provider/budget and security decisions, actual giving destinations, counting definitions, currency/custody procedure and deadlines, reminder defaults, and web hosting/domain. These are explicitly identified as operational decisions or proposed implementation defaults; none are silently taken from placeholder design data.

## Review

Checked against the 32 supplied design screenshots, both prototype sources and the previous specification. Cross-section consistency review covered roles, scope, workflows, data, privacy, reminders, milestones and acceptance tests. This is a specification update; no application code, infrastructure or live church data was changed.
