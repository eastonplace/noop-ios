# Active work

- [~] #37 Apply the packaged simplifications and high-confidence open-issue root slices at exact
  SHA `439ac11321650920908ee611ad044ecd95a9cc63`.
  - Keep PR #37 draft, open, and unmerged.
  - Preserve the installed app, bundle identity, database, App Group, phone data, schema, scoring,
    BLE commands, and save-before-ACK ordering.
  - [x] Verified both guarded package results byte-for-byte against the exact-source synthetic tree;
    the task changes were already present, so neither package was reapplied.
  - [x] Run the eight Swift package suites, repository source audits, XcodeGen, and NOOPiOS tests:
    2,468 package tests and 472 NOOPiOS tests passed, with one expected skip in each layer.
  - [~] Issue-specific automated and read-only data gates pass. The rejected-history copy contains
    1,513 records, not the expected 154, so no duplicate issue was closed. Hosted CI, signed physical
    WHOOP 5/MG proof, and the small/large-iPhone lifecycle and route visual gates remain required.
  - [~] Physical WHOOP 5/MG QA on Easton's iPhone reproduced a secure-session regression at
    `16eae200`: an owned, CRC-valid GET_HELLO response returned command-specific byte `2`, while
    `Whoop5SecureSession` incorrectly required generic success value `1` and paused recovery after six
    failures. The bounded fix preserves current-session, command, sequence, ATT, notification, and CRC
    gates while treating only GET_HELLO's byte as non-authoritative. No BLE command, notification order,
    ACK order, schema, or phone data changed. NoopPhase34Core passed 120 tests, WhoopProtocol passed 328,
    and NOOPiOS passed 471 with one expected skip. The signed in-place build reached `Active · Full Bond`
    on Easton's WHOOP 5.0/MG, resumed history with received chunks, reported a healthy current packet,
    and executed a user-confirmed protected vibration command. The app container and phone data remained intact.

- [x] #37 Repair WHOOP 5/MG secure-session ownership from exact SHA `93d563d` and close the
  exact-head QA findings reported against `8a833cfa`, `96f4d10a`, and `19353da`.
  - Keep PR #37 draft, open, and unmerged.
  - Preserve bundle identity, phone data, in-place install behavior, and the existing BLE/history pipeline.
  - Require current peripheral, connection generation, secure-attempt epoch, confirmed-write ownership,
    CRC-valid protocol proof, and secure-session history ownership before proprietary work or progress.
  - [x] Close order-independent GET_HELLO proof,
    bounded secure lifecycle, restored-notify rearm, frozen fd4b instances, issued-only callback owners,
    fail-closed WHOOP 5 history admission, truthful pre-proof UI, and exact response-ledger cleanup.
  - [x] Run all eight Swift packages plus the complete iOS suite: 2,368 XCTest cases and 93 Swift
    Testing cases across the packages, plus 457 NOOPiOS tests with one expected skip and zero failures.
    Migration/SQL, query-plan/store, lifecycle, source-contract, and focused audit gates pass.
  - [x] Pass the unsigned generic-iPhone Simulator Release build under Swift 6 warnings-as-errors.
  - [x] Preserve the bundle/project identity and V54/V55/V56 migration sources; add no migration or
    background pipeline.
  - [x] Commit, push, and verify the exact remote PR head without merging or removing draft status.
  - [x] Close the exact-head QA findings reported against `96f4d10a`: connection-bound discovery
    deadline, bounded cross-connection secure recovery, pre-proof protected-frame quarantine,
    result-before-next-write ordering with authentication revocation, and stale standard-HR UI teardown.
  - [x] Close the exact-head QA findings reported against `19353da`: count direct pre-proof disconnects,
    bind restored discovery to one request owner and absolute deadline, classify every documented
    transport-authorization loss, give WHOOP 5 retry timing one owner, and make terminal standard-only
    fallback subscription and status state truthful.
  - [ ] Remaining external gates: restore hosted Actions after the account billing/spend restriction,
    restore signing for team `479HYY24G2`, then run the signed physical-device secure-session and
    Release/background/restoration/radio/energy/memory/thermal qualification on the final SHA.

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
