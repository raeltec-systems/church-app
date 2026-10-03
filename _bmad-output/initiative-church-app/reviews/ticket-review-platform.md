# Platform epic draft validation

Reviewed 2026-10-03 against `platform-proposal.json`, the configured `workflow.checks.ticket`, `workflow.checks.set` and `workflow.checks.dependencies` arrays and their supporting workflow keys. Read the canonical spec kernel, functional requirements, design contract, delivery/decision register, acceptance map and adopted architecture spine. No application implementation or infrastructure test is claimed.

## Verdict

**Pass — no remaining draft blockers.** The whole 12-entry set covers the platform requirements and supports the owner-approved Platform / Identity split within milestone 1. The platform may complete only after its actual-provider proof, selected-framework trial, owner-approved private-disabled production baseline, restore rehearsal and closing suite pass. It does not complete milestone 1 or accept future production identity workflows.

## Findings and disposition

1. **Fixed — selected alternative framework lacked trial acceptance.** The reviewed original entry 6 could complete after a failed Flutter trial by recording an alternative decision. The epic required the selected framework to pass, but entry 7's checks did not repeat the full trial. The updated entry 6 now requires equivalent passing grid/list, focus, keyboard, screen-reader, text-scale and CSV evidence on the browser matrix before a React/Next.js alternative can be selected. This closes the P6 / Done-when gap without adding production feature work.
2. **Fixed — private-access denial versus disabling recovery.** Entry 2's original phrase “direct OTP/magic-link/recovery denial” and P2's “forbidden alternate Auth routes” could be read as disabling native recovery endpoints altogether. AD-3/AD-20 explicitly retain the approved verified-email flow and permit a native verified-email/password alias under the same current-account gate. Re-read the updated draft: P2 now names denial of private-data access without trusted password authentication, and entry 2 specifies “private-data denial for OTP/magic-link/recovery-only sessions.” The approved email verification/recovery behavior remains explicitly required by the same entry and its references. This precision fix preserves the approved authentication route.
3. **Fixed — reference convention.** The root normalized entry references to project-root-relative paths. A mechanical read checked every draft reference target and heading fragment; all resolve.

## Coverage

| Requirement | Implementing entries | Closing evidence |
| --- | --- | --- |
| P1 Actual clients/API/database tracer | 1, 7 | 12 |
| P2 Actual Auth/password/session/no-SMS proof | 2 | 12 |
| P3 Trusted change detection and fenced reset proof | 3 | 12 |
| P4 Transactional command, authority and receipt primitives | 4 | 12 |
| P5 Shared contracts and owner seams | 5, 7 | 12 |
| P6 Framework trial and accessible client primitives | 6, 7 | 12 |
| P7 Separated environments and promotion | 8 | 12 |
| P8 Bounded system principals and activation controls | 5, 9 | 12 |
| P9 Independent recovery journal and restore denial | 10 | 12 |
| P10 Cleanup and integrated closure | 11 | 12 |

The local P1–P10 identifiers are constraint-derived platform requirements. Empty epic `covers` avoids claiming completed parent capabilities; CAP-3/CAP-4/CAP-16 are supporting relationships. Production member/account persistence, role policy, real recovery flows and last-staff continuity remain explicitly owned by Identity. Feature schemas and full release restoration remain owned by their later epics. Neither omission is a coverage failure for this agreed platform scope.

## Dependencies, ownership and gates

- Entry 1 owns the scaffold, initial API/database path and smoke harness. Its native and disposable web clients make the tracer demonstrable.
- Entries 2→3 share the retained provider-evidence harness and dedicated isolated Auth project. They do not mutate the platform environment, migrations or client shell owned by other lanes.
- Entries 4→5 share the backend/contract lane. Entry 4 supplies its own synthetic actor/aggregate fixture and authorization seam; it does not depend on production Identity policy being implemented.
- Entry 6 owns the disposable web trial. Entries 5 and 6 are independent; entry 7 joins contracts and the passing framework choice before adapting the selected clients.
- Entry 8 follows entry 7 because promotion checks need both selected client artifacts. Entries 9 and 10 then consume the concrete environment, system and contract outputs. These are real prerequisites rather than chronology alone.
- Entries 2/3 may run beside entries 4–10 because both files and provider environments are isolated. The remaining independent pairs are backend/contract work versus the disposable trial; no shared-file/configuration ownership is required by their descriptions.
- The dependency graph has no missing IDs or cycles. Entry 11 names every prior implementation entry, and entry 12 follows the sweep, so every delivered lane reaches the closing suite.
- Setup/access, test inboxes and redirects, framework/browser choices, production hosting approval, journal/object-backup placement and operator selection are attached to the first affected entries. Unresolved production policy remains fail-closed. No guessed time zone, retention value, real member record or provider claim is accepted from the synthetic fixtures.
- Every high-risk entry names an outside check through its `external_check` and the epic Notes. The actual-provider security review is separate from the harness builder; production approval and restore witnessing are explicitly human gates.

## Session size and builder readiness

Each entry has one bounded implementation outcome, its known uncertainty and an independently runnable verification approach. The difficult Auth story is limited to one synthetic provider mechanism harness, the contract story to shared types/seams, and the restore story to one synthetic subject/object. They do not smuggle production membership, feature business state machines or full release operations into the platform set. Entry 6's possible alternative remains an equivalent bounded trial; it is not the staff portal implementation.

No story files or full Given/When/Then criteria are needed at this inception stage. The epic plus each entry and its cited source provide sufficient information for the builder to write its plan and acceptance checks. Tests accompany every implementation story; the only dedicated suite is the allowed closing integration entry. Cleanup scope is evidence-led and expressly cannot absorb unfinished source behavior.

## Remaining validation after render

Root must run the provided repository status command after `tickets.toml` is rendered:

```sh
UV_CACHE_DIR=/workspace/work/uv-cache uv run .agents/skills/bmad-ticket/scripts/tickets.py --project-root /workspace/church-app status _bmad-output/initiative-church-app/epic-platform-baseline
```

A clean result must contain no cycle, drift, unpinned/undeclared prerequisite or order conflict. Draft graph/reference checks above do not substitute for that parser validation.
