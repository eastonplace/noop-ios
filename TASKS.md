# Active work

- [~] #37 Repair WHOOP 5/MG secure-session ownership from exact SHA `93d563d`.
  - Keep PR #37 draft, open, and unmerged.
  - Preserve bundle identity, phone data, in-place install behavior, and the existing BLE/history pipeline.
  - Require current peripheral, connection generation, secure-attempt epoch, confirmed-write ownership,
    CRC-valid protocol proof, and secure-session history ownership before proprietary work or progress.
  - [x] Implement and run protocol, store, iOS, migration, query-plan, lifecycle, and secure-session tests.
  - [x] Commit, push, and verify the exact remote PR head without merging.

- [~] #36 Make WHOOP history ingestion durable and UI-responsive.
  - PR #37 remains draft and must not merge before every external gate passes.
  - Preserve the PR #29 shared database pool and save-before-ACK contract.
  - Keep Recovery, Sleep, Strain, SpO2, phone data, and bundle identity unchanged.
  - Required proof: per-frame single-pass classification, durable mapped-raw retention,
    p50/p95/max fixture timing, full package/iOS tests, and separate physical-device gates.
  - Implemented: strict protocol gates; source-scoped trusted progress; one-job queue draining with
    due-work/retry state; restore generation fences; receipt-time V56 repair; mapped-only protected
    capacity; quarantined-archive export/retry/explicit-delete recovery; and six radio-bounded passes.
  - Verified locally during the current repair: WhoopProtocol 326/326, WhoopStore 447/447, and NOOPiOS
    438 tests with one expected skip and zero failures; the unsigned Release compile passes; 47 focused
    queue/restore/radio/frontier/raw-capture tests pass; V54 and V55 source blobs remain unchanged.
  - [x] Local code, regression, Release-compile, recovery-UI visual, and diff gates pass.
  - [ ] Remaining external gates: restore hosted CI after the account billing/spend restriction; add a
    valid Xcode account and provisioning profiles for team 479HYY24G2; then complete the physical-iPhone
    Release/background/restoration/radio/energy/memory/thermal trace. Keep the PR draft and unmerged.
