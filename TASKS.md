# Active work

- [~] Start a brand-new draft PR for the correctness, simplification, Settings, and WHOOP-only audit.
  - Base: `b72ff860660915f5e709d106649820b8a4d284f3`.
  - Branch: `codex/noop-audit-p0-settings-whoop-20260816`.
  - Isolated worktree: `/private/tmp/noop-audit-p0-settings-whoop-20260816`.
  - Preserve the installed app, bundle identity, App Group, keychain, database, and phone data.
  - [x] Read the handoff package and required audit documents in the requested order.
  - [x] Run four bounded read-only `gpt-5.6-luna` / max-reasoning audit lanes; no other subagent model was used.
  - [x] Implement and test Stress presentation modes and dated Home skin-temperature selection.
  - [x] Add the verified-sink bootstrap decision seam and tests without integrating an unproven phone repair.
  - [x] Add searchable Settings and More filtering with stable catalog IDs and preserved closures/actions.
  - [x] Run XcodeGen, the NOOPiOS simulator build, simulator tests, all eight package suites, and source audits.
  - [x] Complete the coverage inventory, root-cause report, migration boundaries, performance evidence, and audit-of-audit.
  - [x] Package reports and copied simulator logs under `docs/audit/2026-08-16/`.
  - [ ] Confirm the installed App Group verified-sink token and current phone trace before changing launch bootstrap.
  - [ ] Identify the first failed skin-temperature pipeline stage from a current database copy and device logs.
  - [ ] Run physical WHOOP, energy, background, radio, thermal, and migration gates.
  - [ ] Commit evidence by scope, push, and create one draft PR; do not merge.
  - [~] Integrate the 2026-08-18 PR #45 Settings/RyanBR handoff from exact source SHA
    `25f64b1cc91d587e784cfc20c1fdc779f7aff806` on local branch
    `integrate/pr45-settings-ryanbr`; preserve local `main` and untracked `outputs/`, run local
    validation only, and keep hosted workflows disabled until user approval.
    - [~] Modernize the integrated Settings, Test Centre, Trends Explore, Quick Actions, About NOOP,
      Sleep/Rhythm, and Stress surfaces with StrandDesign components and Apple HIG behavior; rerun
      local automated and simulator visual gates before any commit or push.
      - [x] Merge the Devices summary and Command Centre into one command-centre-styled route while
        preserving pairing, device management, diagnostics, Test Centre, and protected actions.
      - [x] Derive a live battery-runway estimate from timestamped battery drain observations, with
        bounded confidence and truthful fallback states when the sample is insufficient or charging.
      - [x] Rework the complete Settings route hierarchy into searchable native grouped lists/forms,
        remove decorative row icons, and preserve every existing control and destination through deep routes.
      - [x] Re-run zero-warning audits, warnings-as-errors package/app gates, full simulator tests, and
        visual QA of Devices, Command Centre, Settings search, and representative deep Settings routes.

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
