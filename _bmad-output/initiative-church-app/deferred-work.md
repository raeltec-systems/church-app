
- source_plan: `_bmad-output/initiative-church-app/epic-platform-baseline/story-make-environments-and-promotion-reproducible-in-ci-plan.md`
  summary: verify-hosted.sql fails promotion whenever a release gate is open and the env validator forbids features.* true, so a release epic that opens a gate must change both together.
  evidence: 1.8 quick review; milestone 1 keeps both gates closed by design.

- source_plan: `_bmad-output/initiative-church-app/epic-platform-baseline/story-provide-bounded-system-access-and-restricted-operations-plan.md`
  summary: Unauthenticated calls to system_command each insert a sys_audit row with no rate limit or retention.
  evidence: 1.9 quick review; app.sys_execute steps 1–2 audit every rejected credential; rate/retention wait for Q12 thresholds.
