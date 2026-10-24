# AGENTS.md

Rules for anyone (human or agent) changing this repository. This app is Easton Place's iPhone fork of the
open-source NOOP, forked at upstream 9.0.1 in July 2026. Its own version history restarts at 1.0.0.

## Versions and releases

**Next release: 2.0.2, requested by Easton on 2026-10-24.** Easton approved the installed
2.0.0 build 252 and requested a new PR for larger Sleep figures and chart, multiple alarms,
and confirmed bug fixes. Use `2.0.2` for PR81 despite the general minor-version rule below.
Add a new What's New entry and preserve the cumulative 2.0.0 history. This request authorizes
reviewing and merging useful PR79 fixes first, then merging PR81 with the requested changes
after validation. It does not authorize another phone install, tag or release publication.

The shared 2.0 staging batch is closed in `docs/releases/2.0-batch.json`. Its approved installed
candidate is `5235f823c719419d9006fab89b750484c20d246e` (build 252, PR81). It includes merged work
from PR68 through PR80 plus the PR81 release copy; open PR79 is excluded. PR81 remains a branch
dependency until merged. Publication remains held. The old same-version staging exception no
longer applies to new app changes.

Every PR that changes what a user sees or how the app behaves ships a version bump and a What's New entry.

1. **Pick the version** (semver on `MARKETING_VERSION` in `project.yml`):
   - **Minor** (`1.7.0` → `1.8.0`): any user-visible feature, redesign, or behaviour change.
   - **Patch** (`1.7.0` → `1.7.1`): fixes only, nothing new to learn.
   - **Major**: a deliberate reset of the product, only on Easton's say-so.
   - One version per merged PR. If two PRs are open at once, the second to merge rebases and takes the next number.
2. **Bump the build**: raise `CURRENT_PROJECT_VERSION` in `project.yml` by one on every bump.
3. **Write the What's New entry**: add a `.fork("<version>", "<short title>", "<Month Year>", [...])` at the top
   of `AppChangelog.releases` (`Strand/System/AppChangelog.swift`) with 3–9 `Feature(symbol, tint, title, detail)`
   rows. This is a showcase, not a changelog: titles are 2–4 words, details are one short line (under ~60
   characters) on what changed for the person. An SF Symbol and a tint per row. No PR numbers, file names or
   jargon. Look at the 1.7.0 entry and match it.
4. **Update the fallback**: the literal in `AppChangelog.currentVersion` matches the new version.
5. **Mirror it** in `CHANGELOG.md` under a `## <version>` heading.
6. **Tag the release** after merge: `gh release create v<version> --repo eastonplace/noop-ios --generate-notes`.
   Settings → About → Check for updates reads the latest release from this repository.

The What's New screen opens by itself the first time the app runs a new version (the stored last-seen
version differs from the running one), so a version bump is what shows it. It is always reachable from
Settings → About → What's new.

**Enforced in CI.** `Tools/qa/whats_new_release_audit.py` runs in the `source-audits` job and fails a PR when the
newest What's New entry doesn't match `MARKETING_VERSION`, the fallback literal is stale, or app source changed
without the required version/build update. The shared 2.0 exception requires the held staging policy on both
the exact base and head, a higher build, and updated cumulative release notes. Outside that batch, both values
must rise above the exact PR base. The initial
upstream 9.x to fork 1.x marketing-version reset is allowed; build numbers still increase. CI checks use complete
history and fail if the PR comparison is unavailable.

## Credits

Settings → About credits Easton Place as the builder and owner of the design and direction. Keep the
"Background formulas built on" attributions (my-whoop, goose, NoopApp/noop) intact.

## Focused development and CI

Run tests for the changed behavior while editing. Use the exact failing test and its source to diagnose a failure. Broaden coverage when the failure or shared state warrants it. Do not restart complete native and UI suites after each small patch.

Before the final push, review the combined diff and run affected audits, classifier/gate checks and targeted tests. Batch related fixes, then qualify the final pushed commit once. A later fix requires affected checks again; do not repeat passing unrelated suites without a concrete reason. Never weaken an assertion or convert a failure, timeout, missing job or cancellation into a pass.

The protected CI policy selects the PR lane. Documentation changes run audits and policy checks. Approved presentation leaves run app/extension compilation, four native safety methods, affected native tests and Today plus affected UI cases. Core, data, BLE, HealthKit, background, alarm, build, CI and unknown changes run full native tests and applicable UI/packages. Packages have one authoritative pass with reverse-dependent selection. An unselected required package context must report an explicit planned skip.

Complete native, UI and package validation remains in nightly and manual full runs. Run and review full validation on the exact app release candidate before publishing its release. Release-triggered validation alone does not meet that requirement. CI/documentation-only changes do not change app behavior and do not require an app version bump or release.

Keep the ten existing required contexts during the initial CI rollout. The aggregate `NOOP CI Gate` stays shadow until five representative real runs verify plans, exact tested source, expected skips and failure controls. Record timing before changing coverage again. Do not change branch protection or runner billing as part of a routine fix. See [CI design](docs/superpowers/specs/2026-10-22-change-aware-ci-design.md) for activation and rollback.
