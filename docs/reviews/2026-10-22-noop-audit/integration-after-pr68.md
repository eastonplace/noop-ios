# PR71 integration after PR68

Integration date: 2026-10-22. The user authorized completion and merge of PR68, then PR71. Earlier draft-only instructions and Linux-era validation in the audit reports describe the original review; this note records the integration. Hardware behavior and battery savings remain separate from source and CI qualification.

## Source and version

- First parent: PR68 `f0980950e1be6cbe6f5f18e01cdab8507af008dd`.
- Second parent: original PR71 `a4454a42762c998992171fdd26d80c810ef6d1b3`.
- Original PR71 checkpoint: `checkpoint/noop71-before-integration-20261022`.
- Version: **1.8.1**, build **241**. Seven concise What's New rows and the fallback/changelog agree.
- The original **20 fix groups** and **67 native regression inventory methods** are retained. The inventory names all exist in the integrated source.

## Conflict decisions

Nine files required manual resolution. PR68's typed heart-rate receipts, physical source/generation ownership, callback observation times, same-second admission bound, provider ownership and timer silence behavior remain. PR71's raw arrival subject is represented by that stricter receipt channel; its native freshness tests exercise the actual parser and receipt delivery, including equal values across distinct seconds, one display publication and source-free preview rejection. The internal parser test seam defaults to wall-clock admission time for production calls.

PR71's intentional stop, active-row removal and system reconnect policies are preserved. Its failed-connect guard also rejects delayed failure while a newer attempt is connecting. The existing exact-method regression now compiles the production connection policy and includes that additional scenario. Reboot diagnostics keep PR68's raw family-specific result without claiming physical success, and PR71's native assertions match it.

HealthKit retains PR68's complete sleep-episode reducer, overlap queries, source/timezone identity and real-zero handling. PR71 cancellation checks run before queries, after awaited chunks and before final reducer completion. PR71's exact deletion UUID journal, coalesced cancellation, whole-day widget reads, raw pruning and metric corrections are retained. PR68's alarm generation/backup ownership, conservative cache witness, import/storage protection, WHOOP enrollment scope and 25-case PR UI workflow are unchanged.

## Local verification and remaining gates

- All 15 configured source-audit scripts passed on the integrated working source.
- Swift 6 syntax parsing passed for all 37 changed Swift files. This does not establish Apple SDK type checking.
- The exact production connection-result harness passed 11 scenarios with zero failed assertions.
- The retained foreground-action, widget-assignment and alarm-backup exact-source harnesses passed 7, 8 and 19 checks respectively.
- Production/test/tool source whitespace checks passed. Original PR71 evidence logs are preserved, including their existing terminal whitespace.
- The PR71 inventory check found all 67 named test methods.

Full native build, unit/package/UI CI and physical WHOOP checks are not established by these local checks. The release owner verifies exact published-head CI before GitHub merge. No device install or battery measurement is part of this integration.
