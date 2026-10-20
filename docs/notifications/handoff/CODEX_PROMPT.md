# Paste this into Codex with this folder attached

Implement the first release of a useful notification system in `eastonplace/noop-ios` using this handoff. Read the repository's current instructions first. Inspect current main and open work before editing. The research snapshot was main `00eadc67c23fee97fd064f1aeb6d79b7a7f2e537`, upstream `ryanbr/noop` at `8e4b0c16e7640607600fa6bde5424095eba6034e`, and draft PRs #62 and #63 as documented in the evidence report. Reconcile current changes safely. Keep unrelated work intact.

## Read these files first

1. `docs/PRODUCT_SPEC.md` for product behavior, delivery lanes, defaults, and architecture.
2. `docs/REPO_AND_WHOOP_EVIDENCE.md` for observed source code, upstream opportunities, and WHOOP channel distinctions.
3. `docs/IMPLEMENTATION_PLAN.md` for the five implementation tasks and required checks.
4. `docs/CATALOG_GUIDE.md` and `catalog/FAMILY_INDEX.md` for the catalog structure and first-release mapping.
5. `notification_policy.json` for proposed global settings and silence reasons.

Query the JSON catalog by family or ID as you work. Do not dump the entire file into one context window. `catalog/notification_catalog.json` contains 540 explicitly authored positive scenarios in 54 families. Each scenario has a trigger, context, copy, destination, timing, suppressions, and a Given/When/Then acceptance case. Values in examples are fictional. `validation/failure_matrix.json` has 96 separate failure and platform cases.

## Required first-release outcome

Create a shared deterministic policy, durable event claims, a notification coordinator, typed tap routes, preferences, private previews, and reliable schedule reconciliation. Migrate existing notification producers through this common policy. Add selectable first-release groups for:

- Morning summary after complete current data.
- Wind-down using Noop's current sleep plan.
- Explicitly scheduled workouts.
- Settled workout summaries.
- Canonical daily strain target, after its recovery dependency is satisfied.
- One useful charging alert before a planned recording period.
- A selected weekly review.
- A selected journal check-in.

Implement the subset of scenarios that defines these groups on the current data model. Record implemented, partially implemented, and deferred scenario IDs in a checked-in mapping. Treat the rest of the catalog as the expansion backlog. One family can contain competing variants; select the most specific valid result. A matching row does not authorize an additional alert.

## Constraints

- Preserve current user choices. New push groups start off for existing installations until the person selects them. Breathe and Hydrate remain optional and off by default.
- The proposed proactive budget is two notices per local day, ten per rolling seven days, and at least three hours apart. Quiet hours default to 21:00–08:00 local. Selected reminders keep their own schedule. Proactive messages yield within 30 minutes of those reminders. Existing alarm/session behavior has its own lane.
- Noop must use canonical, source-aware data with metric dates, coverage, finality, and algorithm versions. Yesterday's carried score cannot generate a new current-day claim. Missing data stays unknown.
- PR #62 is a draft recovery-data repair. Recheck its status. Keep dependent new alerts gated until a reviewed repair is integrated and current repaired data is available. Do not merge that PR as an incidental part of this task.
- Coordinate routing and settings work with draft #63. Preserve the current Training Load and Journal screens. Do not redesign unrelated UI.
- Preserve the separate 7/42 Training Load and 7/28 Readiness calculations. Stored strain and displayed strain use different scales. Reuse existing conversions and canonical aggregation.
- Keep future aerobic/anaerobic load, forecasts, and unsupported commitment features Deferred until their named measurement and storage contracts exist. A workout label is not evidence of an aerobic/anaerobic split.
- Use local notifications and existing lifecycle opportunities. Do not add APNs, continuous background polling, or a model that decides when to notify. iOS background execution and presentation are not guaranteed.
- Protect lock-screen privacy. Keep sensitive journal details out of public notification text. Generic public previews and detailed in-app copy are separate fields in the catalog.
- Group related facts into one useful message. Deduplicate by stable event identity across restarts and recomputations. A scoring revision is not a new event. Unknown submission outcomes require reconciliation and must not cause a blind retry.
- Notification taps open the correct day, session, plan, or device. They must not start a workout or change a plan. Keep active-session navigation guards.
- Do not introduce diagnostic, emergency, injury-risk, food-restriction, or exact recovery-prediction claims. Do not copy WHOOP's regulated rhythm feature.

## Validation and delivery

Use a fake clock, a fake notification-center adapter, and existing package test targets to test eligibility, collisions, cancellation, restart behavior, source changes, permissions, clock changes, and stale evidence. Follow the implementation plan. Confirm the current Xcode scheme and installed simulator before running app commands.

Run `python3 validation/validate_catalog.py` to validate the supplied design inventory separately from app behavior. That script cannot establish that Swift code works or that a phone received a message.

Use an isolated branch and review the complete diff. Open a draft PR with the product reason, changed behavior, screenshots, executed commands and results, remaining device checks, scenario mapping, and rollback controls. Leave merge and installation for review. Do not send external messages.

Continue through implementation and verification. If an external capability is unavailable, complete the unaffected work and state the exact remaining gate. Do not invent a passing build or device result.
