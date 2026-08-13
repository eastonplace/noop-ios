# Active work

- [~] #36 Make WHOOP history ingestion durable and UI-responsive.
  - PR branch: `perf/history-ingestion-background-sync` at `6bee9b5e4794a2a2815675790d1c28cdf256f93d`
  - Local continuation: `fix/pr37-qa-root-fixes-v2` in `/private/tmp/noop-pr37-filtered`
  - Base: `main` at `eaf175db883de8ac37da283e1d9b2e7a72c8c6e3`
  - Preserve the PR #29 shared database pool and save-before-ACK contract.
  - Keep Recovery, Sleep, Strain, SpO2, phone data, and bundle identity unchanged.
  - Required proof: per-frame single-pass classification, durable mapped-raw retention,
    p50/p95/max fixture timing, full package/iOS tests, and separate physical-device gates.
  - Implemented: V20/V21 mapped-raw classification, selective packed retention, V54 materialization jobs,
    a 64 MiB protected-byte ceiling, CPU work outside the shared SQLite writer, decode/commit/ACK signposts,
    and six progress/radio-bounded continuation passes.
  - Local QA blockers closed: complete envelope integrity, replay-safe progress, bounded mapped-raw
    materialization, durable raw-only progress, and radio/backoff safety.
  - Remaining external gates: commit/push to update PR #37, hosted CI, and physical-device
    Release/background trace. The live PR still points to the pre-fix SHA above.
