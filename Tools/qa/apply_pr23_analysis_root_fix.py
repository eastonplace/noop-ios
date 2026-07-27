#!/usr/bin/env python3
"""Apply the PR #23 post-backfill analysis root fix to the live release branch.

This script is intentionally exact and idempotent. It exists only as a transport shim for the
GitHub-hosted checkout because the review environment cannot clone the private repository. The
workflow that invokes it deletes both itself and this script in the same source-fix commit.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def replace_once(relative: str, old: str, new: str) -> None:
    path = ROOT / relative
    text = path.read_text(encoding="utf-8")
    if new in text:
        return
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{relative}: expected one source block, found {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def write(relative: str, content: str) -> None:
    path = ROOT / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


REQUEST_SOURCE = '''import Foundation

/// One serialized request for `IntelligenceEngine.analyzeRecent`.
///
/// Forced update paths may arrive while a long history pass is already running. The request keeps the
/// caller's exact day window and publication policy so admission can merge overlapping work without
/// silently substituting the in-flight pass's unrelated window. The 10,000-day ceiling is above every
/// production caller (full-history migration is 4,000 days) and keeps hostile/overflowing inputs bounded.
struct IntelligenceAnalysisRequest: Equatable, Sendable {
    static let maximumWindowDays = 10_000

    let maxDays: Int
    let startOffset: Int
    let force: Bool
    let refreshRepository: Bool

    init(maxDays: Int, startOffset: Int, force: Bool, refreshRepository: Bool) {
        let boundedStart = min(max(0, startOffset), Self.maximumWindowDays - 1)
        let remaining = max(1, Self.maximumWindowDays - boundedStart)
        self.startOffset = boundedStart
        self.maxDays = min(max(1, maxDays), remaining)
        self.force = force
        self.refreshRepository = refreshRepository
    }

    var endOffsetExclusive: Int { startOffset + maxDays }

    /// Union two windows and preserve the strongest requested semantics. A queued batch runs once over the
    /// complete requested span; no caller's recent-day window or requested repository publication is lost.
    func merged(with other: Self) -> Self {
        let lower = min(startOffset, other.startOffset)
        let upper = max(endOffsetExclusive, other.endOffsetExclusive)
        return Self(
            maxDays: upper - lower,
            startOffset: lower,
            force: force || other.force,
            refreshRepository: refreshRepository || other.refreshRepository)
    }
}
'''

GATE_SOURCE = '''import Foundation

/// Pure state machine for one post-backfill finalizer.
///
/// A finalizer waits while another history burst is writing, stops when superseded/cancelled, and proceeds
/// only for the current generation after the store is quiescent. Keeping this decision pure makes the race
/// contract testable without CoreBluetooth or a live database.
enum BackfillFinalizationGate {
    enum Decision: Equatable {
        case proceed
        case waitForQuiescence
        case stop
    }

    static func decision(
        requestGeneration: UInt64,
        currentGeneration: UInt64,
        backfilling: Bool,
        cancelled: Bool
    ) -> Decision {
        guard !cancelled, requestGeneration == currentGeneration else { return .stop }
        return backfilling ? .waitForQuiescence : .proceed
    }
}
'''

REQUEST_TESTS = '''import XCTest
@testable import NOOP

final class IntelligenceAnalysisRequestTests: XCTestCase {
    func testDisjointRequestsMergeIntoOneCompleteWindow() {
        let history = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 120, force: true, refreshRepository: true)
        let today = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: true, refreshRepository: false)

        let merged = history.merged(with: today)

        XCTAssertEqual(merged.startOffset, 0)
        XCTAssertEqual(merged.maxDays, 150)
        XCTAssertTrue(merged.force)
        XCTAssertTrue(merged.refreshRepository)
    }

    func testOverlappingRequestsDoNotDoubleCountDays() {
        let first = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 20, force: true, refreshRepository: false)
        let second = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 35, force: false, refreshRepository: true)

        let merged = first.merged(with: second)

        XCTAssertEqual(merged.startOffset, 20)
        XCTAssertEqual(merged.maxDays, 45)
        XCTAssertTrue(merged.force)
        XCTAssertTrue(merged.refreshRepository)
    }

    func testInvalidAndOverflowingInputsAreBounded() {
        let request = IntelligenceAnalysisRequest(
            maxDays: Int.max, startOffset: Int.min,
            force: true, refreshRepository: false)

        XCTAssertEqual(request.startOffset, 0)
        XCTAssertEqual(request.maxDays, IntelligenceAnalysisRequest.maximumWindowDays)
        XCTAssertEqual(request.endOffsetExclusive, IntelligenceAnalysisRequest.maximumWindowDays)
    }
}
'''

GATE_TESTS = '''import XCTest
@testable import NOOP

final class BackfillFinalizationGateTests: XCTestCase {
    func testCurrentQuiescentGenerationProceeds() {
        XCTAssertEqual(
            BackfillFinalizationGate.decision(
                requestGeneration: 4, currentGeneration: 4,
                backfilling: false, cancelled: false),
            .proceed)
    }

    func testCurrentGenerationWaitsWhileAnotherBurstWrites() {
        XCTAssertEqual(
            BackfillFinalizationGate.decision(
                requestGeneration: 4, currentGeneration: 4,
                backfilling: true, cancelled: false),
            .waitForQuiescence)
    }

    func testSupersededOrCancelledGenerationStops() {
        XCTAssertEqual(
            BackfillFinalizationGate.decision(
                requestGeneration: 3, currentGeneration: 4,
                backfilling: false, cancelled: false),
            .stop)
        XCTAssertEqual(
            BackfillFinalizationGate.decision(
                requestGeneration: 4, currentGeneration: 4,
                backfilling: false, cancelled: true),
            .stop)
    }
}
'''

write("Strand/Data/IntelligenceAnalysisRequest.swift", REQUEST_SOURCE)
write("Strand/App/BackfillFinalizationGate.swift", GATE_SOURCE)
write("StrandiOSTests/IntelligenceAnalysisRequestTests.swift", REQUEST_TESTS)
write("StrandiOSTests/BackfillFinalizationGateTests.swift", GATE_TESTS)

replace_once(
    "Strand/Data/IntelligenceEngine.swift",
    '''    /// #899-A re-arm: a `force: true` recompute (a post-backfill rescore AppModel kicks off after a sync)
    /// that arrives while an idle-tick pass already holds the `computing` lock would otherwise be SILENTLY
    /// dropped, so a freshly-synced night intermittently never gets re-scored until the next cycle and Today
    /// falls back to the last scored day. Instead the dropped force sets this flag; the in-flight pass's
    /// `defer` re-invokes `analyzeRecent(force: true)` ONCE when it clears. A single re-arm (the flag is
    /// cleared BEFORE the re-invoke) bounds it to one extra pass , no recompute storm.
    private var pendingForcedRescore = false
    private var analysisCompletionSerial = 0
''',
    '''    /// Forced analysis admission is serialized. A request arriving while another pass owns the engine is
    /// merged by day window and waits for that merged pass to finish. This preserves the requesting caller's
    /// recent-day window and publication policy instead of returning early and replaying whatever historical
    /// window happened to be active.
    private var pendingAnalysisRequest: IntelligenceAnalysisRequest?
    private var pendingAnalysisWaiters: [CheckedContinuation<Void, Never>] = []
    private var analysisCompletionSerial = 0
''')

replace_once(
    "Strand/Data/IntelligenceEngine.swift",
    '''        // #899-A: a concurrent pass already holds the lock. A NON-forced idle tick is safe to drop (the
        // in-flight pass already covers the same window). But a FORCED call is a real update path (a
        // post-backfill rescore after a sync) , dropping it would leave a freshly-synced night unscored
        // until the next cycle. Re-arm instead: flag it so the running pass's `defer` re-invokes once.
        guard !computing else { if force { pendingForcedRescore = true }; return }
''',
    '''        let request = IntelligenceAnalysisRequest(
            maxDays: maxDays,
            startOffset: startOffset,
            force: force,
            refreshRepository: refreshRepository)
        // A non-forced idle tick is expendable while another pass owns the engine. A forced update is not:
        // merge its exact window into the pending batch and suspend this caller until that batch completes.
        // Returning here before the requested recent window ran was the post-backfill blank-Recovery race.
        if computing {
            guard request.force else { return }
            pendingAnalysisRequest = pendingAnalysisRequest.map { $0.merged(with: request) } ?? request
            await withCheckedContinuation { continuation in
                pendingAnalysisWaiters.append(continuation)
            }
            return
        }
''')

replace_once(
    "Strand/Data/IntelligenceEngine.swift",
    '''        computing = true
        // #899-A re-arm: clear the lock, then if a forced rescore was dropped while this pass held it,
        // run it ONCE. The flag is cleared BEFORE the re-invoke (a single re-arm), so a forced call landing
        // DURING the re-invoke re-arms it again but a quiet one does not , this can never recurse unbounded.
        // The re-invoke is launched on a fresh `Task` because `defer` is synchronous; by the time it runs
        // `computing` is already false, so its own `guard !computing` passes and it rescores the new data.
        defer {
            computing = false
            if pendingForcedRescore {
                pendingForcedRescore = false
                // Carry THIS pass's window into the re-pass: a heal firing during a wide one-shot pass
                // must re-score the same width, not the default 21 days (Kotlin re-passes with the same
                // maxDays; keep the platforms in lockstep).
                Task { await self.analyzeRecent(maxDays: maxDays, startOffset: startOffset, force: true) }
            }
        }
''',
    '''        computing = true
        // Clear admission, then run one merged pending request. Every forced caller queued into that request
        // resumes only after its requested window has actually completed; a later request arriving during the
        // queued pass forms the next bounded batch rather than being lost or causing unbounded recursion.
        defer {
            computing = false
            if let queued = pendingAnalysisRequest {
                let waiters = pendingAnalysisWaiters
                pendingAnalysisRequest = nil
                pendingAnalysisWaiters.removeAll(keepingCapacity: true)
                Task { @MainActor [weak self] in
                    guard let self else {
                        waiters.forEach { $0.resume() }
                        return
                    }
                    await self.analyzeRecent(
                        maxDays: queued.maxDays,
                        startOffset: queued.startOffset,
                        force: queued.force,
                        refreshRepository: queued.refreshRepository)
                    waiters.forEach { $0.resume() }
                }
            }
        }
''')

replace_once(
    "Strand/Data/IntelligenceEngine.swift",
    '''            if !healRearmedThisCycle {
                healRearmedThisCycle = true
                pendingForcedRescore = true
            }
''',
    '''            if !healRearmedThisCycle {
                healRearmedThisCycle = true
                let healRequest = IntelligenceAnalysisRequest(
                    maxDays: maxDays,
                    startOffset: startOffset,
                    force: true,
                    refreshRepository: refreshRepository)
                pendingAnalysisRequest = pendingAnalysisRequest.map {
                    $0.merged(with: healRequest)
                } ?? healRequest
            }
''')

replace_once(
    "Strand/App/AppModel.swift",
    '''    private var latestWorkoutSnapshotAttempt: UInt64 = 0
    private var applicationIsActive = true
''',
    '''    private var latestWorkoutSnapshotAttempt: UInt64 = 0
    private var applicationIsActive = true
    /// One owner for the delayed post-history finalizer. A new durable-data edge supersedes and cancels the
    /// prior generation; the task itself waits through a newly-started burst instead of racing its writes.
    private var backfillFinalizeGeneration: UInt64 = 0
    private var backfillFinalizeTask: Task<Void, Never>?
''')

replace_once(
    "Strand/App/AppModel.swift",
    '''        live.$backfillDataAvailableAt
            .dropFirst()
            .compactMap { $0 }
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { [weak self] in await self?.refreshAfterBackfillBurst() }
            }
            .store(in: &hrCancellables)
''',
    '''        live.$backfillDataAvailableAt
            .dropFirst()
            .compactMap { $0 }
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                backfillFinalizeGeneration &+= 1
                let generation = backfillFinalizeGeneration
                backfillFinalizeTask?.cancel()
                backfillFinalizeTask = Task { [weak self] in
                    await self?.refreshAfterBackfillBurst(generation: generation)
                }
            }
            .store(in: &hrCancellables)
''')

replace_once(
    "Strand/App/AppModel.swift",
    '''    private func refreshAfterBackfillBurst() async {
        let trace = PerformanceTrace.begin("backfill_finalize")
        defer { PerformanceTrace.end(trace) }
        live.append(log: "Backfill: refreshing dashboard cache from completed sync")
        // Score the freshly-offloaded raw data RIGHT NOW rather than waiting for the next 15-minute
        // analyzeRecent tick , otherwise a just-synced night's Charge / Effort / Rest can take up to
        // 15 minutes to appear on a strap-only (no-import) dashboard. analyzeRecent no-ops if a tick is
        // already running and refreshes the dashboard itself once the new scores persist. (PR #218)
        await intelligence.analyzeRecent(refreshRepository: false)
        // One post-analysis refresh publishes both the newly offloaded raw history and any computed
        // mutations. Refreshing before analysis made the same cache tree rebuild twice per backfill.
        _ = await repo.refresh(.postBackfill)
        await refreshV5Signals()
        #if os(iOS)
        // #980: a strap backfill routinely completes while the app is BACKGROUNDED (it runs as a
        // bluetooth-central, so it stays alive to receive the offload). The only other widget-publish
        // sites are gated on scenePhase == .active, so a background sync would rescore today's data but
        // never rewrite the shared App-Group snapshot or call WidgetCenter.reloadAllTimelines — the
        // widget kept showing yesterday's numbers. Publishing here, on the real "new data landed"
        // signal, pushes the fresh snapshot to the home-screen widget without needing a foreground.
        await WidgetSnapshot.publish(from: self)
        #endif
    }
''',
    '''    private func waitForBackfillQuiescence(generation: UInt64) async -> Bool {
        while true {
            switch BackfillFinalizationGate.decision(
                requestGeneration: generation,
                currentGeneration: backfillFinalizeGeneration,
                backfilling: live.backfilling,
                cancelled: Task.isCancelled) {
            case .proceed:
                return true
            case .stop:
                return false
            case .waitForQuiescence:
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return false
                }
            }
        }
    }

    private func refreshAfterBackfillBurst(generation: UInt64) async {
        let trace = PerformanceTrace.begin("backfill_finalize")
        defer {
            PerformanceTrace.end(trace)
            if generation == backfillFinalizeGeneration { backfillFinalizeTask = nil }
        }
        // A periodic/reconnect burst can begin during the debounce. Wait for its writes to quiesce; if it
        // produces a newer durable-data edge, that generation cancels this task and owns final publication.
        guard await waitForBackfillQuiescence(generation: generation) else { return }
        live.append(log: "Backfill: refreshing dashboard cache from completed sync")
        // The analysis admission contract now suspends until THIS recent-day request has actually run, even
        // when a history migration already owns the engine. That closes the stale publish / blank Recovery race.
        await intelligence.analyzeRecent(refreshRepository: false)
        guard await waitForBackfillQuiescence(generation: generation) else { return }
        // Exactly one final cache publication for this generation, after both raw persistence and derived
        // scores are settled. Repository's diff guard suppresses a byte-identical publication.
        _ = await repo.refresh(.postBackfill)
        guard await waitForBackfillQuiescence(generation: generation) else { return }
        await refreshV5Signals()
        guard await waitForBackfillQuiescence(generation: generation) else { return }
        #if os(iOS)
        // #980: a strap backfill routinely completes while the app is BACKGROUNDED (it runs as a
        // bluetooth-central, so it stays alive to receive the offload). The only other widget-publish
        // sites are gated on scenePhase == .active, so a background sync would rescore today's data but
        // never rewrite the shared App-Group snapshot or call WidgetCenter.reloadAllTimelines — the
        // widget kept showing yesterday's numbers. Publishing here, on the real "new data landed"
        // signal, pushes the fresh snapshot to the home-screen widget without needing a foreground.
        await WidgetSnapshot.publish(from: self)
        #endif
    }
''')

# Final source contracts: stale lossy admission must be gone, and all new files must be present.
engine = (ROOT / "Strand/Data/IntelligenceEngine.swift").read_text(encoding="utf-8")
app = (ROOT / "Strand/App/AppModel.swift").read_text(encoding="utf-8")
if "pendingForcedRescore" in engine:
    raise RuntimeError("lossy pendingForcedRescore admission still present")
if "await withCheckedContinuation" not in engine:
    raise RuntimeError("forced callers are not waiting for queued analysis")
if "refreshAfterBackfillBurst(generation:" not in app:
    raise RuntimeError("generation-owned backfill finalizer was not installed")
