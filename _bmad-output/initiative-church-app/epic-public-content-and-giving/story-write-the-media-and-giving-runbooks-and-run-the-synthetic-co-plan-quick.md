# Independent quick review: Epic 6 acceptance continuation

Read C:/Users/Administrator/church-app-acceptance/_bmad-output/initiative-church-app/epic-public-content-and-giving/story-write-the-media-and-giving-runbooks-and-run-the-synthetic-co-plan.md, the plan holding the acceptance intent, and the files its frontmatter context lists. Read applicable AGENTS.md, CLAUDE.md or equivalent instructions at the repository root and in directories the diff touches. Read the unified diff at C:/Users/ADMINI~1/AppData/Local/Temp/2/church-content-review-1b19a8567ec3489c9b0c676dc3550ffe/changes.diff.

The diff covers the acceptance branch from baseline c96cd562b2650c37f5d3d879cb12891419700139, including the closeout evidence. The latest engineering/test-source checkpoint is 53b3176b6aefa6c1f4c56986679f24130dfdec04; later edits are evidence and the review handoff. Repository root: C:/Users/Administrator/church-app-acceptance.

Check surrounding code and callers. Report unmet acceptance criteria, broken rules and bugs. In particular verify that isolated-local SQL, HTTP and cleanup cannot select a different running Supabase project; actual lock tests observe waiters and recheck current authority; Windows launcher failures cannot count as successful negative security tests; and failed attempts, device gaps, hosted parity and promotion decisions are not presented as passed acceptance.

Read C:/Users/Administrator/church-app-acceptance/_bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-acceptance-continuation-2026-10-31/resumed-validation.md and its underlying evidence. Do not infer signed-in UI, physical Android/iOS, push, source-book verification, production deployment or owner acceptance from API/unit/widget test counts. Do not mutate a hosted environment, send notifications, merge or deploy to review.

Each finding must name its location, what goes wrong and the evidence checked against surrounding code. Return a Markdown list of findings only, without severity, priority or ranking. State explicitly if no findings are established. Do not invoke a skill or spawn further subagents. Return findings as text.

This prompt is authored, not executed. Run it in a separate reviewer session with access to the checkout and diff, then return findings before closing this review checkpoint. On another workstation reconstruct the diff from the same baseline and reviewed candidate and substitute these local paths.
