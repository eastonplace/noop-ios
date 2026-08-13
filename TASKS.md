# Active work

- [~] #36 Make WHOOP history ingestion durable and UI-responsive.
  - PR #37 remains draft and must not merge before every external gate passes.
  - Preserve the PR #29 shared database pool and save-before-ACK contract.
  - Keep Recovery, Sleep, Strain, SpO2, phone data, and bundle identity unchanged.
  - Required proof: per-frame single-pass classification, durable mapped-raw retention,
    p50/p95/max fixture timing, full package/iOS tests, and separate physical-device gates.
  - Implemented: strict protocol gates, source-scoped BLE progress, bounded V55 materialization lifecycle,
    transactional V54 upgrade, complete regression matrix, and six progress/radio-bounded continuation passes.
  - Local verification: WhoopProtocol 326/326, WhoopStore 436/436, and NOOPiOS 430 passed,
    0 failed, 1 expected skip. Migration success, mismatch rollback, and partial-conversion rollback pass.
  - Remaining external gates: push the final SHA, restore hosted CI after the account billing/spend
    restriction, and complete the physical-iPhone Release/background/restoration/radio/energy/memory/thermal trace.
