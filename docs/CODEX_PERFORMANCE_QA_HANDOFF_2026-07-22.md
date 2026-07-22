# Codex Xcode / Simulator / Device Handoff — NOOP Performance PR #7

## Role

Codex is the Apple-runtime evidence collector for this pass. ChatGPT Pro owns the engineering analysis and implementation decisions. Do not redesign the code or begin an unrelated refactor.

Your job is to compile the exact branch, exercise the exact runtime pathways below, collect trustworthy Xcode/Simulator/device evidence, fix only concrete compile/runtime defects introduced by this branch, and commit the evidence so ChatGPT Pro can read it back from GitHub.

## Source

- Repository: `eastonplace-ai/noop`
- Base implementation branch: `perf/freeze-paths-2026-07-21`
- Pull request: #7
- Create a child QA branch from the current PR head: `codex/perf-pr7-xcode-qa`
- Never merge.
- Never force-push the implementation branch.
- Never uninstall the production app, erase the simulator/device database used for comparison, reset App Group data, or replace the user's on-device database.

Read first:

1. `docs/PERFORMANCE_STATE_AND_NEXT_STEPS_2026-07-22.md`
2. `docs/PERFORMANCE_CODE_REVIEW_QA_2026-07-22.md`
3. the complete PR #7 diff

## Behavioral contract

Treat these as release blockers:

- active workout in-app BPM receives every accepted HR sample;
- in-app zone changes remain visibly real-time;
- Lock Screen / Dynamic Island BPM remains approximately two-second cadence;
- workout Start and Finish mode transitions are immediate;
- expensive Live Activity calories/zones/trace projection remains bounded near ten seconds;
- widget live publication remains near one per minute plus urgent edges;
- no stale ActivityKit update lands after Finish;
- a pending durability write cannot resurrect a finished workout;
- final saved calories, zones, Strain, duration, and sample count match the canonical base behavior;
- no user-data reset or destructive migration occurs.

## Phase 1 — repository and environment capture

Record exact output in `outputs/2026-07-22/qa/perf-pr7/environment.txt`:

```bash
pwd
git status --short --branch
git rev-parse HEAD
git rev-parse origin/main
sw_vers
xcode-select -p
xcodebuild -version
xcrun simctl list runtimes
xcrun simctl list devices available
xcodegen --version || true
```

Confirm that the current branch starts from the latest PR #7 head. Stop only if the source cannot be obtained.

## Phase 2 — generate and compile

Run with `set -o pipefail`. Preserve every log under `outputs/2026-07-22/qa/perf-pr7/logs/`.

```bash
mkdir -p outputs/2026-07-22/qa/perf-pr7/{logs,xcresults,screenshots,metrics}

xcodegen generate 2>&1 | tee outputs/2026-07-22/qa/perf-pr7/logs/xcodegen.log

xcodebuild \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/noop-perf-pr7-ios-derived \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tee outputs/2026-07-22/qa/perf-pr7/logs/ios-build.log

xcodebuild \
  -scheme Strand \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/noop-perf-pr7-mac-derived \
  'ARCHS=x86_64 arm64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tee outputs/2026-07-22/qa/perf-pr7/logs/macos-build.log
```

Also explicitly build the widget / Live Activity extension if XcodeGen exposes a separate scheme. Record scheme discovery with:

```bash
xcodebuild -list -json | tee outputs/2026-07-22/qa/perf-pr7/logs/schemes.json
```

Do not claim a platform build passed if only a Swift package compiled.

## Phase 3 — unit and policy tests

Run the relevant test target with a real available simulator selected dynamically. Do not hard-code a device that is not installed.

At minimum execute:

- `LiveUpdatePoliciesTests`
- `ActiveWorkoutPersistenceTests`
- existing active-workout finish/read-back tests
- widget snapshot compatibility tests
- any ActivityKit state/projection tests
- touched package suites

Prefer `build-for-testing` followed by `test-without-building`, with a result bundle:

```bash
xcodebuild \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -derivedDataPath /tmp/noop-perf-pr7-test-derived \
  -resultBundlePath outputs/2026-07-22/qa/perf-pr7/xcresults/noop-ios-tests.xcresult \
  build-for-testing 2>&1 | tee outputs/2026-07-22/qa/perf-pr7/logs/build-for-testing.log

xcodebuild \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -derivedDataPath /tmp/noop-perf-pr7-test-derived \
  -resultBundlePath outputs/2026-07-22/qa/perf-pr7/xcresults/noop-ios-test-run.xcresult \
  test-without-building 2>&1 | tee outputs/2026-07-22/qa/perf-pr7/logs/tests.log
```

If the repository uses a different test scheme or plan, discover and use it; document the exact command.

Run focused tests repeatedly where supported:

- 25 repetitions of the deterministic publication-policy suite;
- 25 repetitions of active-workout persistence latest-wins/clear tests;
- random test ordering if available.

## Phase 4 — simulator lifecycle QA

Boot one current iPhone simulator and use XcodeBuildMCP or `simctl` plus UI automation.

For every scenario, capture before/after screenshots and console logs.

### A. Generic Live HR to workout

1. Launch with deterministic/demo live HR if the repository supports it.
2. Confirm generic Live HR Activity presentation.
3. Start a workout.
4. Confirm the in-app workout screen appears immediately.
5. Confirm the Lock Screen / Dynamic Island changes to the workout title without waiting ten seconds.
6. Capture screenshots and timestamps.

### B. Sustained workout

1. Feed a deterministic 1 Hz HR sequence for at least ten virtual minutes, or use the existing replay/test harness.
2. Verify the in-app BPM and zone react to every sample.
3. Capture counters for:
   - received HR samples;
   - active UI publications;
   - widget App Group writes;
   - WidgetKit reload requests;
   - ActivityKit pushes;
   - expensive workout projection builds;
   - active durability encodes/writes;
   - maximum pending publication count.
4. Confirm no task or write backlog grows with time.

### C. Finish race

Exercise this order deliberately:

```text
slow ActivityKit update begins
new HR states arrive
workout Finish is tapped
final persistence/save runs
older update completes
new generic Live HR state arrives
```

Pass criteria:

- workout screen exits immediately;
- no workout-mode Activity remains after Finish;
- no older update revives workout content;
- final workout saves once;
- no active-workout recovery snapshot reappears after clear.

### D. Start–finish–start generation isolation

Start workout A, finish it while updates are pending, then immediately start workout B. Verify no A state, trace, persistence snapshot, or ActivityKit update appears in B.

### E. Disconnect / reconnect

Rapidly disconnect and reconnect the simulated/live source. Verify:

- one Activity at most;
- disconnect ends it;
- reconnect starts one clean generic or workout Activity as appropriate;
- no duplicate widget/workout state;
- no crash or stuck pending task.

## Phase 5 — visual evidence

Save labeled PNGs under:

`outputs/2026-07-22/qa/perf-pr7/screenshots/`

Required:

- generic Live HR in app;
- active workout immediately after Start;
- Lock Screen immediately after Start;
- Dynamic Island expanded/compact where available;
- active workout after sustained replay;
- app immediately after Finish;
- Lock Screen immediately after Finish;
- restart of a second workout;
- widget before, during, and after workout.

Create a contact sheet and a short `visual-audit.md` with exact simulator model, iOS runtime, commit SHA, and scenario names.

## Phase 6 — Instruments / performance capture

Use the strongest available tools. One focused flow per trace.

Capture at least:

1. launch to workout Start;
2. five-minute sustained synthetic workout;
3. workout Finish and save;
4. rapid disconnect/reconnect.

Preferred evidence:

- Time Profiler or ETTrace with symbols;
- SwiftUI/body update evidence;
- hangs/main-thread stalls;
- allocations and memory graph;
- file writes / `UserDefaults` activity where visible;
- signpost/counter export if the branch has instrumentation.

Do not claim a leak fix from total-memory decline alone. Preserve trace files outside Git history when too large; commit a summary and artifact manifest.

## Phase 7 — physical Release verification

Only when a paired iPhone and signing identity are available.

- Build Release.
- Install in place without uninstalling or resetting data.
- Confirm database identity before and after.
- Use the same phone, strap, database, and workout flow for comparison.
- Run a real 30-minute workout.
- Capture screen-on and background portions.

Record:

| Metric | Baseline | PR #7 | Delta |
|---|---:|---:|---:|
| Main-thread hangs >100 ms | | | |
| Widget writes/min | | | |
| Widget reloads/min | | | |
| ActivityKit pushes/min | | | |
| Expensive projection builds/min | | | |
| Durability writes/min | | | |
| CPU mean/peak | | | |
| Memory start/peak/end | | | |
| Finish-to-dismiss latency | | | |
| Finish-to-read-back latency | | | |
| Final calories | | | |
| Final zone seconds | | | |
| Final Strain | | | |
| Final HR sample count | | | |

Final values must match base within the existing canonical semantics; unexplained parity drift is a blocker.

## Fix policy

A compile or runtime defect introduced by PR #7 may be fixed on the child branch, but:

- make the smallest root-cause patch;
- add a failing regression test first when practical;
- keep each fix in a separate commit;
- do not redesign UI or calculations;
- do not merge;
- do not silently alter throttles or calculation constants;
- do not suppress a failing test to get green.

## Deliverables committed to GitHub

Commit these text/small-image artifacts to the child QA branch:

- `outputs/2026-07-22/qa/perf-pr7/environment.txt`
- logs for every build/test command;
- `summary.md`
- `metrics/before-after.json` or `.csv`
- screenshot contact sheet and labeled screenshots;
- `artifact-manifest.md` listing any large external `.xcresult`, trace, or memgraph files;
- minimal compile/runtime fix commits, if required.

Do not commit DerivedData, app bundles, full simulator data, secrets, provisioning profiles, private health data, or giant trace bundles.

## Final report format

`summary.md` must state:

1. exact head SHA tested;
2. Xcode/macOS/iOS/simulator versions;
3. every build and test command with pass/fail;
4. exact failing test/log line for any failure;
5. runtime scenarios completed;
6. before/after counters;
7. screenshots and trace artifact locations;
8. physical-device work completed or still blocked;
9. verdict: PASS, CONDITIONAL PASS, FAIL, or BLOCKED;
10. whether PR #7 can leave Draft.

Do not label iOS behavior verified from package tests alone.
