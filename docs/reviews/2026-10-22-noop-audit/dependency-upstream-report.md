# Focused upstream and dependency audit

## Scope and result

Compared the current audit worktree rooted at `eastonplace/noop-ios` main `6f49d855d6f747103f4dc2a60949cb933445c3c0` with the five specifically requested upstream changes, using fetched `ryanbr/noop` main `8e4b0c16e7640607600fa6bde5424095eba6034e`. Reviewed actual connection admission, acknowledgement/protocol-proof, stress input, package manifest, resolved-pin, and production-import paths. This is a focused pass, not an assertion that the entire upstream history or every advisory database was exhaustively mapped.

**One applicable upstream optimization was ported:** HRV local-neighbour buffer reuse. The fork already addresses the upstream bond re-entry failures through a stronger connection-generation reset and protocol-proof design. No package upgrade or deletion was justified by this pass. A separate confirmed widget stress truncation defect was corrected and verified; see `widget-stress-report.md` for its independent evidence and limits.

## Upstream changes: applicability and execution paths

| Upstream commit | Disposition in this fork | Evidence |
| --- | --- | --- |
| [0b05b84e — WHOOP 4 bond re-entry](https://github.com/ryanbr/noop/commit/0b05b84eeb446327965dc7ba945bd7d78f9c64b2) | Covered by different architecture; do not cherry-pick | `BLEManager.didConnect` calls `admitConnectionGeneration` before publishing the new connected UUID. Admission clears both `didBond` and `encryptedBond`, so the upstream `didBond == true && encryptedBond == false` acknowledgement trap cannot survive accepted re-entry. The owned WHOOP 4 handshake ACK takes the existing first-bond path. |
| [9b278013 — WHOOP 5/MG bond re-entry](https://github.com/ryanbr/noop/commit/9b278013c943a9ad011ec5d8cf39291efbba33e6) | Covered; copying upstream ACK-only authorization would weaken this fork | Admission accepts a new secure session scoped to peripheral ID and connection generation. CLIENT_HELLO ATT completion confirms only that stage; protected notification confirmation and a matching, integrity-checked GET_HELLO response must precede `completeWhoop5SecureReady`, which sets `didBond`, `bonded`, and `encryptedBond`. |
| [35d052d6 — same-peripheral re-proof](https://github.com/ryanbr/noop/commit/35d052d662534941469a6e0be80085be231338a8) | Covered by unconditional admission revocation | A replacement peripheral receives a new admission and clears all authorization-bearing flags before observers see the replacement UUID. It cannot inherit the earlier peripheral's `didBond`. The fork does not contain the upstream `ClientHelloOutcome`/`Whoop4BondAck` classifiers, because it owns this boundary differently. |
| [4d40dda7 — stress union witness](https://github.com/ryanbr/noop/commit/4d40dda7f7bcabaf9c437c008d0b4bb9dbe2c12b) | Upstream gate is absent; no direct port | There is no `StressDayCurve` or summed `hrFingerprint` gate in the fork. Widget enrichment reads the bundle's verified source IDs through `verifiedStressInput`, then `DaytimeStress` fingerprints actual HR/RR values. `StressView` loads on repository revision and checks request/source ownership. This eliminates the specific upstream count/max collision gate, but does not establish correctness of every stress read; the independent 20,000-row truncation defect was found here. |
| [54196f03 — HRV buffer reuse](https://github.com/ryanbr/noop/commit/54196f0308761d39986ecf89a9743bcbd938d07d) | Confirmed missing; minimally ported | `rejectEctopic` and `cleanRRGapAware` allocated a neighbour array for each beat. Both function bodies were byte-identical to upstream's pre-patch bodies; both are now byte-identical to the corresponding post-patch bodies. No other upstream HRV changes were copied. |

Relevant local paths are `Strand/BLE/BLEManager.swift` (`admitConnectionGeneration`, `didConnect`, the owned handshake completion, and `completeWhoop5SecureReady`), `StrandiOS/Widgets/WidgetPublish.swift`, `Strand/Screens/StressView.swift`, and `Packages/StrandAnalytics/Sources/StrandAnalytics/DaytimeStress.swift`.

## HRV optimization and proof

Changed only `Packages/StrandAnalytics/Sources/StrandAnalytics/HRVAnalyzer.swift` for this optimization. Each cleaner now reserves a maximum-size local neighbour buffer once, then calls `removeAll(keepingCapacity: true)` before filling each window. Clearing happens before every continuation/early branch. `median` takes the array by value and sorts into its own local value; it does not retain mutable storage. Invocation-local buffers introduce no shared state or concurrency ownership change.

Thresholds, range filters, neighbour order, median arithmetic, beat eligibility, retained beat order, gap flags, and metric definitions are unchanged. Neither sensor sampling nor Bluetooth behavior is touched.

Fresh verification:

- The existing exact-source metrics harness executed **192 XCTest tests, zero failures, exit 0** after the patch, including the repository's HRV and gap-aware tests. See `logs/metrics-hrv-buffer-green.log` and the existing `metrics-harness-manifest.txt`.
- An optimized executable compiled the preserved original analyzer and the current analyzer alongside the real local `WhoopProtocol` package. **37,555 fixtures produced zero mismatches** in exact Double bit patterns, every gap flag, input/clean counts, RMSSD, SDNN, mean NN, and pNN50. Fixtures include every length-0-through-5 sequence over eight boundary/artifact values, NaN/infinities, short/end windows, mixed gaps, an eight-hour synthetic night, and 96 shorter windows.
- `logs/hrv-kernel-proof.txt` records pre/post exact function-body equality with upstream and SHA-256 hashes. `git diff --check` passed for the modified analyzer.

The optimized synthetic night has 28,799 observed beats over 28,800.443 seconds, with 28,316 retained beats. Nine alternating measurement rounds each ran twenty iterations per implementation and path:

| Path | Original median per pass | Patched median per pass | Observed reduction |
| --- | ---: | ---: | ---: |
| `cleanRR` | 2.947550 ms | 2.647658 ms | 10.17% |
| `cleanRRGapAware` | 2.990384 ms | 2.565111 ms | 14.22% |
| `analyze(rawRR:)` | 3.053613 ms | 2.743948 ms | 10.14% |

These are microbenchmarks on the available Linux x86_64 host, with visible run-to-run timing variation. The absolute saving is approximately **0.3–0.43 milliseconds per full-night pass**. This does not measure total app runtime, iPhone energy, strap energy, or battery-life improvement. It supports a modest allocation/CPU optimization only.

Reproducible sources are in `hrv-benchmark/`; output is in `logs/hrv-buffer-benchmark.log`. The original type is mechanically renamed `OldHRVAnalyzer`; its numerical implementation is preserved. No additional native test file was necessary for this two-loop optimization. The executed benchmark command was:

```sh
LD_LIBRARY_PATH=/tmp/noop-swift-toolchain/compat/usr/lib/x86_64-linux-gnu \
CLANG_MODULE_CACHE_PATH=/tmp/noop-hrv-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/noop-hrv-module-cache \
/tmp/noop-swift-toolchain/usr/bin/swift run --build-system native -c release \
  --package-path /tmp/noop-hrv-benchmark \
  --scratch-path /tmp/noop-hrv-benchmark-build \
  --cache-path /tmp/noop-swift-cache --config-path /tmp/noop-swift-config \
  --security-path /tmp/noop-swift-security HRVBenchmark
```

For the copied reproduction package, replace `--package-path` with `review-work/hrv-benchmark`; it contains a relative path to the local WhoopProtocol checkout.

## Exact dependency graph and removal classification

All six checked-in resolved files agree wherever their dependencies overlap: the Xcode app lockfile, WhoopStore, StrandAnalytics, StrandImport, NoopLocalAccess, and Tools/Backfill. Direct versions are exact constraints in `project.yml` and the relevant local package manifests. The app's five resolved remote packages are:

| Package | Exact resolved version / revision | Production usage and decision |
| --- | --- | --- |
| GRDB | 6.29.3 / `2cf6c756e1e5ef6901ebae16576a7e4e4b834622` | WhoopStore persistence, numerous store modules, app data paths, and foreign SQLite import. Retain. |
| ZIPFoundation | 0.9.20 / `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` | Import/export, backups, Apple Health archives, and wearable archives. Retain. |
| MarkdownUI | 2.4.1 / `5f613358148239d0292c0cef674a3c2314737f9e` | Coach views and `CoachPresentation/CoachMarkdownTheme.swift`. Retain. |
| NetworkImage | 6.0.1 / `2849f5323265386e200484b0d0f896e73c3411b9` | Production product dependency of MarkdownUI. Absence of direct app imports is not evidence it is unused. Retain. |
| swift-cmark | 0.9.0 / `08ddb528923cc1a6527e02b7a1aee9e516ca749a` | MarkdownUI requires both `cmark-gfm` and `cmark-gfm-extensions`. Retain. |

The exact [MarkdownUI manifest](https://github.com/gonzalezreal/swift-markdown-ui/blob/5f613358148239d0292c0cef674a3c2314737f9e/Package.swift), [NetworkImage manifest](https://github.com/gonzalezreal/NetworkImage/blob/2849f5323265386e200484b0d0f896e73c3411b9/Package.swift), and [swift-cmark manifest](https://github.com/swiftlang/swift-cmark/blob/08ddb528923cc1a6527e02b7a1aee9e516ca749a/Package.swift) were fetched at their pinned revisions. MarkdownUI's `swift-snapshot-testing` declaration is used by its own test target, not its production product; it is absent from the app's resolved set. No pruning action is needed.

`OuraProtocol` is also **not dead code**: `project.yml` links it to the app, WhoopStore depends on it for `OuraStreamMapping`, and `SourceCoordinator`, `OuraLiveSource`, the device wizard, and device view import/use it. The live source maps decoded Oura events into durable streams. Removing it requires an intentional feature retirement rather than dependency cleanup.

`NoopLocalAccess` is a macOS library/CLI package, not linked into the iOS application's project graph. Both package CI and app-build package checks include it. It is a repository tool, not an unused iOS runtime dependency; removing it cannot be justified as an iPhone battery optimization.

## Advisory evidence and remaining limits

The directly retrieved [GitHub reviewed advisory GHSA-c2cc-3569-6jh2 / CVE-2023-39138](https://github.com/advisories/GHSA-c2cc-3569-6jh2) marks ZIPFoundation **<=0.9.17** affected and **0.9.18** patched. The pinned **0.9.20 is outside that advisory's affected range**. Maintainer [0.9.18 release notes](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.18), retrieved through GitHub's release API, also report the path escape fix. This is evidence about that specific advisory, not a claim that ZIPFoundation has no vulnerabilities.

Direct web retrieval of repository security-advisory indexes failed in this subtask for ZIPFoundation, NetworkImage, swift-cmark, GRDB, and MarkdownUI. The parent review separately inspected GRDB/MarkdownUI pages; this report does not convert either an empty index or a fetch failure into a global CVE-free claim. Search results referencing advisories for other `cmark`/`cmark-gfm` products were not assumed to establish affectedness of the exact Swift fork revision. Complete mapping of that C fork remains unverified.

No confirmed advisory requiring a package upgrade was established in this pass. Keep the current pins unless a specific affected revision and applicable fix are demonstrated; update the manifests and all relevant resolved files together if that evidence appears. Do not delete production transitives or active device support merely because their imports are indirect.

No commits, pushes, PR edits, or package-resolution mutations were performed by this subtask. Linux results do not establish full Xcode app build or real-device success.
