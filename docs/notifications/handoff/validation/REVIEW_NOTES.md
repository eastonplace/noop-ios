# Review scope and limits

## Research and product review

The handoff uses read-only source inspection of the pinned Noop iOS and Ryan BR upstream repositories, plus official WHOOP and Apple documentation. Source URLs and research-access limitations are in `docs/REPO_AND_WHOOP_EVIDENCE.md`.

The catalog was authored in three topic groups and cross-reviewed against the other groups and the target app. Review focused on whether each message supports a useful action, whether its input exists, whether variants overlap, and whether inherited silence rules contradict a positive case. Proposed product thresholds remain proposals even when the underlying measurement exists.

Specific corrections made during review include:

- Shared event claims across notification families, so separately arriving morning or battery facts cannot produce duplicate alerts after a restart.
- Stable event identity independent of a database generation or scoring revision.
- Conservative treatment of unknown submission outcomes, including a notice that may already have been dismissed.
- The distinction between app-side expiry and actual OS presentation time.
- Separate reminder and proactive lanes, with a scoped exception for a reminder time the person selected.
- A soft pending-request target that cannot silently discard a selected schedule.
- Explicit one-shot clock-change semantics and separate device validation of recurring OS triggers.
- Workout-summary expiry measured from the workout's end, even if final scoring arrives later.
- Current recovery-repair dependencies, truthful source provenance, and existing-versus-proposed inputs.
- Target-app sleep need, sleep debt, readiness signal, alarm schedule, and sleep-edit behavior.
- Correction and completion messages that remain eligible when a generic inherited suppression would otherwise reject them.

## Executed catalog checks

`VALIDATION_REPORT.json` records the final structural results. `validate_catalog.py` checks the 540 positive cases, 54 families, ten cases per family, contiguous unique IDs, required fields, enum values, copy limits, placeholder rendering, route vocabulary, exact duplicate triggers, and 96 separate failure/platform cases. Source links are checked for valid URL syntax. That is not a claim that every linked page was automatically fetched by the validator.

Human cross-review complements the structural checks. The validator cannot prove that two natural-language situations are meaningfully different, that an inferred user benefit is correct, or that all future Swift implementations will preserve the design.

## Artifact checks

The workbook's Overview and family counts were recalculated and reconciled with the JSON catalog. All 54 family count formulas resolve to ten. Workbook archive integrity and cached formula errors were checked. The three sheets were rendered and visually reviewed.

The six-page PDF was rendered and visually reviewed for clipped text, table overflow, source readability, and page order. The final ZIP was checked for archive integrity. A file manifest records the packaged file sizes and hashes.

## Work not executed

No production Swift compilation, package test suite, simulator run, physical-iPhone test, strap test, or actual notification delivery test was executed in this research task. No app source was modified and no GitHub PR was created or merged. The implementation plan defines those future checks. The 96 failure cases and 540 positive acceptance cases are specifications, not passing app tests.
