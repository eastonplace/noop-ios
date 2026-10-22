# NOOP Change-Aware CI Implementation Plan

> For agentic workers: use bounded parallel implementation and independent review. Maximum four active agents including root. Easton explicitly authorized implementation, testing, review and merge of PR76.

**Goal:** Cut routine PR testing substantially while retaining complete checks for core health/data/radio/background changes and full nightly/release coverage.

**Architecture:** Keep the two existing PR workflows and their ten required context names during rollout. Both consume a deterministic plan from protected-base policy, falling back to full/high-risk validation for bootstrap, bad input or unknown changes. Run package tests once. Add a shadow aggregate gate, a full-validation workflow, and measured timing reports. Do not change app behavior or test assertions.

**Tech Stack:** Python3 standard library, Bash, GitHub Actions, Xcode/xcodebuild, SwiftPM.

**Spec:** docs/superpowers/specs/2026-10-22-change-aware-ci-design.md, corrected for package validation lanes and protected policy source.

## Global constraints

- Existing required contexts remain: source-audits, build-and-test, and test(Package) for the eight existing host-test packages. Preserve exact existing check names; do not change branch protection during initial implementation.
- Docs run policy/classifier/gate checks; normal approved presentation paths run app/extensions, focused native safety and affected UI; core/runtime/data/build/CI/unknown paths run full native and applicable UI/packages. Full mode runs every native/UI case and all package validation lanes.
- No changed assertion, deleted test, increased timeout, speculative app refactor, new secrets, paid runner, phone install or app version bump.
- Every PR triggers required workflows. Read-only build/test permissions. PR outputs cannot authorize their own reduced coverage; load policy from exact protected base where present, otherwise bootstrap conservatively. Independent full-coverage review is required for CI policy changes before activation.
- Discover all package manifests but host-test only compatible test-bearing packages. iOS-only/testless packages compile through app/extensions and mapped native/UI coverage. Handle deleted packages using base and head dependency graphs.
- Keep one package test pass. Full coverage must include all current UI target methods, beyond the historical37-method manual allowlist.
- Batch fixes locally and publish one reviewed implementation update. Run affected Python/shell/workflow checks while editing; one final hosted qualification run. Root owns all Git commits/pushes/PR changes/merge.

## Shared plan interface (schema_version1)

CLI: `python3 Tools/ci/classify_pr.py --repo . --base BASE --head HEAD --event EVENT --output PATH --github-output PATH`, plus `--full` and conservative bootstrap support. Implementers may add backward-compatible optional flags, coordinating with workflow owner.

JSON fields: `schema_version`, `base_sha`, `head_sha`, `tested_sha`, `policy_sha`, `mode` (docs/ui/high/full), `reasons`, `run_app` (boolean), `native_level` (none/smoke/full), `native_tests` (selector array), `ui_tests` (selector array), `host_packages` (selected names), `host_matrix` (all legacy contexts plus any discovered host-test packages, each `{package,run,runner}`), `package_validation` (all discovered packages and lane), `plan_hash`. GitHub outputs expose scalar fields and JSON arrays. Unknown/invalid input selects conservative full coverage or fails the plan job, never docs/skip.

## Review focus

- Renames/deletions and base-only dependencies must not hide affected consumers.
- CI/policy/test-selector edits cannot classify themselves as low-risk.
- Missing, cancelled, unexpectedly skipped or wrong-SHA work cannot satisfy the gate.
- Unselected legacy package contexts must remain present without consuming macOS test runners.
- Full UI and package inventory must include new and iOS-only/testless targets without invalid host commands.

## Task plan

1. [x] Review design and current repo; preserve main1ef156e4 in local PR76 integration807b73c. Identify two design corrections and full UI inventory gap.
2. [x] Classifier owner: create `Tools/ci/classify_pr.py` and `Tools/qa/test_ci_change_classifier.py`. Test actual temporary Git histories, renamed/deleted paths, protected policy/bootstrap, valid version-only edits, unknowns, local reverse dependencies and lane inventory. Verify red/green and conservative fallbacks.
3. [x] App workflow owner: update `.github/workflows/app-build.yml`; add `.github/workflows/noop-full-validation.yml` and scoped workflow contract tests. Retain context names, remove top-level PR path filtering and duplicate package loop, reuse build products where useful, select focused tests, expose real stage outcomes, publish concise evidence, run full native for CI/core changes. Normal baseline reduction must cite test timing/detection coverage; full mode includes all UI target cases.
4. [x] Package/gate owner: update `.github/workflows/swift-packages.yml`; create `Tools/ci/validate_gate.py`, package-result aggregation and tests. Preserve legacy status names with cheap planned-inapplicable jobs, run applicable host packages once and full lane coverage in full mode. Implement shadow `NOOP CI Gate` integration with exact run/SHA checks and negative controls for failure/cancellation/missing/skips.
5. [x] Root: correct spec, update AGENTS.md focused iteration/release policy, record rollout/rollback and timing tooling. Review all task reports/diffs once, fix confirmed issues in one combined wave, validate workflow syntax and real extracted Bash/selection, replay representative historical PR diffs. Keep branch-rule activation behind documented real-run evidence.
6. [~] Publish exact final source, retarget PR76 to main and mark ready; qualify current-head CI once, resolve concrete failures only, then merge and verify actual main tree. CI-only changes retain1.8.1/build241 and need no app release.

## Measurement and rollout

Record existing run timings and exact UI identities; compare planned normal/high/full coverage on at least five representative historical PR diffs. Do not claim runtime speed gains from static replay. New aggregate gate stays shadow until five representative real runs qualify its behavior; old required context names remain. Ten-run median/p90 reporting and rollback instructions remain available for the subsequent observation window. No billing or runner changes.

## Pre-publication evidence

Frozen combined implementation passed 75 CI-policy tests, all 15 existing source/policy audits, actionlint1.7.12 for the three workflows, and whitespace checks. Fresh independent combined review found no blocking issue. Classifier evidence covers actual Git histories, bootstrap10/full42 UI selection, all eleven package lanes and conservative historical replay. These checks do not establish hosted execution or measured speed gains. Final-head CI and main merge readback remain task6.

## First hosted qualification and bounded repair

Headffb4bd73 passed source audits, safety harnesses, app/test-product builds and all eight package suites. Native execution failed because the later UI scheme build had replaced the native host with a different package linkage graph. Duplicate package classes and GRDB queue-key failures followed; UI was skipped and the real aggregate gate correctly failed. Link commands confirmed the overwrite. Repair only workflow sequencing: native build, native execution, UI build, UI execution. Keep one build per scheme and all assertions. Add an extracted-command order regression and independently review the repair before the next exact-head qualification. Do not treat the failed run as merge-ready timing evidence.
