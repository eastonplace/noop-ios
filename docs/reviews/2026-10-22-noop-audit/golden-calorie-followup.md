# Golden calorie fixture follow-up

## Cause and correction

The audit intentionally makes `ManualWorkoutRescore` exclude implausible HR before calculating every workout metric. The existing strain golden also freezes manual-workout calories for a malformed input fixture, so one expected value needed a documented update after that correction. No calorie coefficients, strain calculations, production code, or assertion tolerances changed in this follow-up.

The [original hosted StrandAnalytics job](https://github.com/eastonplace/noop-ios/actions/runs/39718404101/job/119625944488) completed 1,519 XCTest tests with two failed assertions in **one test**, `StrainGoldenBitsTests.testScorerBitsMatchTheGoldenFileGeneratedAtTheBase`, before the workflow was cancelled by a subsequent documentation update. One assertion identified golden index 35; the complete-array assertion reported the same difference again. Both arrays contained 1,124 entries, with exactly one mismatch. All 1,123 other entries, including every strain value, matched bit for bit. The job ran on macOS 26.6.2, image `macos-26-arm64` version `20261013.0424.1`.

`StrainDayFixtures.messySamples` has **1,565 raw readings, of which 1,560 satisfy the existing inclusive 30–240 bpm range**. Its five rejected values are **0, 29, 241, 400, and −7 bpm**. Exact-source base/head experiments produced:

| Calorie input | kcal | Double bits |
| --- | --- | --- |
| All 1,565 rows, the previous rescore behavior | 675.6279982345424 | `40851d0623f03a71` |
| The 1,560 valid rows, the corrected rescore behavior | 674.8726775993182 | `408516fb3e64a830` |

The cause of the approximately **0.755320635224 kcal** difference is directly explainable. Each malformed row shares a timestamp with another row. The unchanged bout integrator assigns a representative second to a nonpositive gap: three malformed low-HR rows receive a resting-rate second, and the two high-HR rows receive an active-rate second clamped to the fixture's 190 bpm maximum. Three resting seconds plus two active seconds equal 0.7553206352241342 kcal, matching the observed difference within accumulated floating-point rounding. Excluding those rows removes that extra energy.

Only this literal changes:

```diff
- "rescore.kcal|messy day=40851d0623f03a71",
+ "rescore.kcal|messy day=408516fb3e64a830",
```

The fixture and test headers now document this reviewed exception to the original base snapshot. All 1,123 other literals, all per-entry comparisons, and the complete-array equality assertion remain unchanged. The malformed fixture remains intact.

A second full macOS run at `dc948c99b64ca0bff274637521dc5752a20d2cf9` independently reproduced the same result: [job 119627326321](https://github.com/eastonplace/noop-ios/actions/runs/39718743671/job/119627326321) built successfully and completed 1,519 tests with exactly this one failing golden case (two assertions), exiting 1. Both 1,124-entry arrays again differed only at index 35. This later job failed normally, not through workflow cancellation.

## Verification and reproduction

Two isolated Linux packages were populated from actual Git blobs, including 19 analytics production files, the real WhoopProtocol package, and the original golden test/support files. There are no mocked numerical kernels. Swift 6.4.1 on x86_64 Linux produced:

| Exact source revision / check | Result |
| --- | --- |
| Base `6f49d855d6f747103f4dc2a60949cb933445c3c0`, original golden | Exit 0; all 1,124 entries match |
| Head `dc948c99b64ca0bff274637521dc5752a20d2cf9`, original golden | Exit 1; the same single entry/two assertions as native CI |
| Both revisions, direct raw and valid-only calorie kernel diagnostics | Identical raw/valid bit patterns shown above; calorie kernel unchanged |
| Base, public rescore equals valid-only rescore | Fails: peak HR is 400 rather than 175 and calories include invalid rows |
| Head, public rescore equals valid-only rescore | Passes for every metric; average 138, peak 175, strain 28.652806669850904, calories 674.8726775993182 |
| Corrected fixture, original golden plus existing `ManualWorkoutRescoreTests` | **10 tests, zero failures, exit 0**; nine workout tests plus one golden test, 0.639 seconds |

A programmatic diff check also confirmed exactly one changed literal among 1,124 and identical executable golden-test code after stripping documentation comments. `git diff --check` passed for the two test files.

The independent final reviewer checked the base/head source snapshots against Git, the unchanged numerical kernels, the two-file diff, and the passing focused log. The reviewer also independently derived the five malformed rows' extra energy and found no hidden production change, weakened assertion, or remaining blocker in this narrow correction. A new hosted integration run remains required.

On macOS, run the full package's focused suites with:

```sh
swift test --package-path Packages/StrandAnalytics \
  --filter 'StrainGoldenBitsTests|ManualWorkoutRescoreTests'
```

For base/head comparison, run the original golden test at each revision in separate checkouts using `--filter StrainGoldenBitsTests`. The Linux production-source harness and toolchain invocation are described in [metrics-report.md](metrics-report.md). The focused final run uses that same harness with the three golden test/support files linked to the actual checkout and the filter above. The isolated source snapshots are in the review workspace's `golden-proof/{base,head}`, with the exact source manifest in `golden-proof/manifest.txt`.

Retained execution evidence:

- [Hosted failure excerpt](evidence/pr71-strandanalytics-previous-failure-excerpt.txt).
- [Base golden proof](evidence/golden-base-proof.txt) / [head golden reproduction](evidence/golden-head-proof.txt) against the original expectation.
- [Base boundary diagnostic](evidence/golden-base-boundary.txt) / [head boundary diagnostic](evidence/golden-head-boundary.txt), including raw/valid counts, kernel bit patterns, and complete rescore equality diagnostics.
- [Corrected golden and workout suite passing](evidence/golden-correction-focused-green.txt).

Temporary paths in these logs identify the original execution environment. The normal repository tests and macOS commands above are the durable reproduction path.

The passing Linux result verifies this narrow fixture correction and workout boundary. A new full native CI run on the corrected commit remains the integration gate; this document does not claim that run has completed.
