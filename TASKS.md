# Active work

- [x] #36 Make WHOOP history ingestion lossless and UI-responsive.
  - Branch: `perf/history-ingestion-background-sync`
  - Base: `main` at `eaf175db883de8ac37da283e1d9b2e7a72c8c6e3`
  - Preserve the PR #29 shared database pool and save-before-ACK contract.
  - Keep Recovery, Sleep, Strain, SpO2, phone data, and bundle identity unchanged.
  - Required proof: per-frame single-pass classification, durable mapped-raw retention,
    p50/p95/max fixture timing, full package/iOS tests, and separate physical-device gates.
  - Implemented: lossless V20/V21 classification, protected packed retention, CPU work outside the
    shared SQLite writer, decode/commit/ACK signposts, and 24 progress-gated continuation passes.
  - Remaining external gates: hosted CI and physical-device Release/background trace.
