# T126 external-review gate

Status: **READY FOR EXTERNAL REVIEW — no PR opened.** T126 remains unchecked until that review approves the batch.

## Shipped task commits

- `54ebce94` — T120 data type and ring scale
- `9257c17e` — T121 scheme-invariant WHOOP graphics palette
- `19d54c57` — T122 no-color-text sweep
- `45819643` — T123 chart weight, underfills, points, and seeded variance
- `1c929c41` / `45bd0821` / `c41fec87` — T124a/b/c small-item commits
- `930d4bf1` — T125 healthy-day capture set and comparison stack
- Final gate commit — T126 audit fixes and refreshed affected evidence

## Build and test proof

- All seven Swift package suites passed from the non-iCloud clone: NoopLocalAccess, OuraProtocol, StrandAnalytics, StrandDesign, StrandImport, WhoopProtocol, and WhoopStore.
- The affected StrandDesign suite was rerun after the final F4 fixes: **43 tests, 0 failures**.
- `xcodebuild build` passed for `NOOPiOS` on iPhone 17 Pro Max (`602CD04D-E0CD-4A41-986C-74427759C06A`).
- `xcodebuild test` passed for the same scheme/destination after the final source edits.
- Builds used `/tmp/noop-derived`; no build ran from the iCloud workspace.
- The standalone `no-mistakes` executable is not installed in this environment, so its required checks were performed directly: focused diff inspection, `git diff --check`, semantic-text search, build/test reruns, and exact artifact inspection.

## Final F4 audit

The gate audit found and fixed residual semantic-colored text that remained outside the initial sweep: zone percentages, Recovery and Workouts status words, live HR/HRV values, VO2max, timer/alarm/live-workout values, correlation/stat helpers, status pills, and warning copy. Color now lives in adjacent rings, bars, chart marks, icons, chips, borders, or fills.

The multiline Swift search for `Text` followed by semantic metric/status/tint foreground styles returns **zero matches** across `Strand`, `StrandiOS`, and `Packages/StrandDesign/Sources`. Link text and the explicitly exempt colored pillar-name labels remain unchanged.

## Evidence

- `qa/t125/data-prominence-stack.jpg` — 8 labeled reference/current light-mode pairs.
- `qa/t125/dark-strip.jpg` — the same 8 surfaces in true dark mode.
- `qa/t125/light/` and `qa/t125/dark/` — 8 PNGs each.
- Recovery and Workouts were re-shot in both modes after the final F4 findings; the stack and dark strip were regenerated from those replacements.
