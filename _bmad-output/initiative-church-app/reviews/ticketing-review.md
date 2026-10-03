# Ticket breakdown review — 2026-10-03

**PASS — 16 epic envelopes and the 12-story opening platform plan are prepared.** The user confirmed separate Platform and Identity/access epics within milestone 1. This is a ticket plan, not implementation or production evidence.

## Scope and ownership

All CAP-1–CAP-17 have accountable owners, all six required additions remain in v1, and all seven source milestones remain intact. Chat alone is conditional. Later epics retain complete envelopes and are incepted when selected; no leaf is placed directly under the initiative.

| Epic | Milestone | Outcome |
| --- | --- | --- |
| 1 | 1 — platform foundation; identity/access completes milestone 1 | A runnable, testable platform with proven authentication mechanisms |
| 2 | 1 | Membership, recovery and scoped access |
| 3 | 2 | Durable inbox and reliable reminders |
| 4 | 2 | Assigned duties, coverage and accountable follow-up |
| 5 | 2 | Cell meetings and revisioned programmes |
| 6 | 3 | Public church content and giving instructions |
| 7 | 4 | Cell attendance, consented visitors and private reports |
| 8 | 4 | Separately published member-safe recaps |
| 9 | 4 | Agreed pastoral visits and continuing care |
| 10 | 4 | Private prayer requests and pastoral replies |
| 11 | 4 | Opt-in member directory and safe contact fields |
| 12 | 5 | Scoped service counts and honest participation trends |
| 13 | 5 | Aggregate cell-offering custody and safe export |
| 14 | 6 | Staff portal completion and mobile continuity |
| 15 | 6 | Conditional moderated group chat |
| 16 | 7 | Full-v1 release and operational acceptance |

## Opening platform stories

1. Run the mobile and trial-web tracer through Supabase
2. Prove password-session trust and no-SMS provider behavior
3. Prove fenced staff recovery across the Auth boundary
4. Install the transactional API command foundation
5. Publish the cross-epic contracts and owner seams
6. Select staff web through the accessible grid and list trial
7. Establish the selected client shells and safe request states
8. Make environments and promotion reproducible in CI
9. Provide bounded system access and restricted operations
10. Rehearse isolated recovery with an independent journal
11. Refactor sweep
12. Verify the platform from checkout through isolated recovery

## Validation

- [Platform set review](ticket-review-platform.md): PASS after clarifying the full alternative-framework trial, project-root references and private-data denial for non-password sessions rather than disabling legitimate recovery endpoints.
- [Initiative tree review](ticket-review-tree.md): PASS for source coverage, shared ownership, handoffs, dependencies, production outcomes and activation gates.
- Mechanical checks: 16 unique ordered epic IDs; all 17 capabilities assigned; every P1–P10 platform requirement covered by entries; 12 stories planned; no cycle, dependency drift, unpinned prerequisite, undeclared prerequisite or order conflict.
- All 145 full source-document references in the ticket tree resolve, as do the 26 story reference targets and heading anchors. Whitespace checks pass.
- Store query and ticket resolution work against the configured repository store. No setup-test ticket or remote tracker item was created.

## Decisions and dependency corrections

- Platform provides shared contracts, runnable provider experiments and deployment/recovery foundations. Identity/access completes the production membership and recovery flows required by milestone 1.
- Notifications owns jobs/inbox runtime; Duties owns assignments and the shared Follow-ups runtime. Synthetic adapters make Notifications buildable before the consuming source workflows.
- Programmes delivers Cells-owned canonical meeting records before attendance/reports; Duties and Offerings consume those IDs rather than creating competing calendars.
- Services owns counting definitions and metrics; staff completion composes the pastoral overview with independently authorized care and finance projections, avoiding a dependency on a later finance implementation inside the earlier counts epic.
- Every feature owns its required mobile and staff actions and source-specific lifecycle effects. Final staff completion integrates them rather than postponing their screens.
- Core/release work has no unconditional Chat dependency; enabling Chat adds its own complete evidence to release acceptance.

## Next build

`tickets.py next` identifies **1.1 — Run the mobile and trial-web tracer through Supabase** as the first dependency-ready candidate. Use `bmad-build` with `1.1`; its builder writes the implementation plan and acceptance criteria. Owner-provided or already authorized isolated Supabase access and native test access are its human setup needs. No story is marked started or done.

The repo store is configured at `_bmad/custom/ticketing-store-config.toml`. At ticketing completion, files were local and uncommitted; publication and application implementation were not part of that run. Q1–Q12 remain explicit affected-work gates, and no live provider, private church data, paid infrastructure or policy value was selected by ticketing.
