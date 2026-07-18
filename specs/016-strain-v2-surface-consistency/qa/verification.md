# Verification Ledger

## Baseline

- Attached static review: PR #4 at `65e58ada61e7e79410e46b1fd7c5a8b1dcf444b7`.
- Implementation branch: `codex/strain-v2-surface-consistency`, created from current local PR #4 continuation `3e3c5bee` so dashboard/chrome work remains present.
- Merge state: child branch and PR #4 remain unmerged.
- Data rule: same bundle ID only; no uninstall, reset, seed, or production database replacement.

## Automated evidence

- `swift test --package-path Packages/WhoopStore`: 274 tests passed, 0 failures, including five resolver/provenance cases.
- `swift test --package-path Packages/StrandAnalytics --filter StrainScorerV2`: 9 tests passed, 0 failures, including batch/incremental parity.
- `scripts/audit-strain-surfaces.sh`: passed; remaining direct reads are classified helper inputs, V2 engine results, enum cases, or edit-preservation checks.
- `git diff --check`: passed.
- Unsigned generic iPhone Debug build: `NOOPiOS` succeeded after the final source audit.
- Signed physical-device Release build from implementation commit `21d7585a`: succeeded with team `QDJ575GGH4`; app artifact is `/tmp/noop-strain-v2-release/Build/Products/Release-iphoneos/NOOP.app`.
- Focused `StrandTests` compilation advanced through the touched workout/provenance tests, then the target failed on pre-existing stale Sleep test APIs in `SleepOnsetDecodeTests` and `SleepOnsetStubTests` (`decodedAsleepMinutes`, `preOnsetStubMinorAsleepFloorMin`, and `refAsleepMin`). This is recorded as a suite-infrastructure blocker, not a passing test claim.

## Physical evidence

- Both paired iPhones were discovered on iOS 26.5.2, including Easton's expected UDID `2085999E-2F35-56BD-91BD-34E9F564B6F4`, but Xcode marked both unavailable.
- In-place install was attempted with the same `com.eastonplace.noop` bundle and failed before mutation with CoreDevice error 1011: no live device matching the requested identifier.
- The final rebuilt artifact was retried after commit and returned the same pre-install CoreDevice 1011 result.
- No uninstall, app-container deletion, database replacement, or demo seeding occurred.

## Known limits

- Do not claim install, launch, database preservation, the 5-minute mounted Home test, 12-minute workout, Watch/widget/Live Activity equality, or Mirroring visual QA until the physical phone is available and those steps are observed.
- The signed Release artifact must be rebuilt after any subsequent source change before an install is claimed.
- `no-mistakes axi` was attempted after commit but the CLI is not installed in this runtime. Manual fallback checks (`git diff --check`, clean commit review, source audit, compile/build review) passed; the unavailable CLI is not represented as a green automated gate.
- Implementation commit `7020e3e7` was pushed to `codex/strain-v2-surface-consistency`; draft child PR #5 targets `codex/noop-v2-trends-performance`. Parent PR #4 and child PR #5 remain unmerged.
