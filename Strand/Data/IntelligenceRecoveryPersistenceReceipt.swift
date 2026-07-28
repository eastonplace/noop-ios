import Foundation
import WhoopStore

/// Fail-closed proof that one admitted Intelligence pass produced the exact durable Recovery projection Home
/// will read. UI provenance is not persistence ownership: a strap-scored day can also have an Apple/WHOOP row.
/// The receipt therefore verifies field-level WHOOP authority first, then each result's explicit writer.
struct IntelligenceRecoveryPersistenceReceipt: Equatable, Sendable {
    let expectedResults: Int
    let verifiedResults: Int
    let storeAvailable: Bool
    let reconciledComputedRange: Bool

    var complete: Bool {
        storeAvailable && reconciledComputedRange && verifiedResults == expectedResults
    }

    @MainActor
    static func verify(
        results: [IntelligenceEngine.Computed],
        reconciledDays: ClosedRange<String>,
        repository: Repository
    ) async -> Self {
        guard let store = await repository.storeHandle() else {
            return failure(expected: results.count)
        }

        do {
            // Imported WHOOP is authoritative per FIELD, not merely because a day row exists. Preserve the
            // same active-then-canonical precedence Repository uses and only claim Recovery when it is nonnil.
            var importedRecoveryByDay: [String: Double] = [:]
            for source in repository.importedReadIds {
                let rows = try await store.dailyMetrics(
                    deviceId: source, from: reconciledDays.lowerBound, to: reconciledDays.upperBound)
                for row in rows where importedRecoveryByDay[row.day] == nil {
                    if let recovery = row.recovery { importedRecoveryByDay[row.day] = recovery }
                }
            }

            let computedSource = Repository.whoopSource + "-noop"
            let computedRows = try await store.dailyMetrics(
                deviceId: computedSource,
                from: reconciledDays.lowerBound,
                to: reconciledDays.upperBound)
            let computedByDay = Dictionary(
                computedRows.map { ($0.day, $0) }, uniquingKeysWith: { _, newest in newest })
            let appleRows = try await store.dailyMetrics(
                deviceId: Repository.appleHealthSource,
                from: reconciledDays.lowerBound,
                to: reconciledDays.upperBound)
            let appleByDay = Dictionary(
                appleRows.map { ($0.day, $0) }, uniquingKeysWith: { _, newest in newest })
            let overrides = try await store.sleepRecoveryDailyOverrides(
                deviceId: computedSource,
                from: reconciledDays.lowerBound,
                to: reconciledDays.upperBound)
            let overrideByDay = Dictionary(
                overrides.map { ($0.day, $0) }, uniquingKeysWith: { _, newest in newest })

            var verified = 0
            // Manual-Recovery rows are deliberately restored by SQLite after range deletion, even when
            // this automatic pass produced no result for that day. They are protected state, not stale rows.
            var expectedCanonicalDays = Set(overrideByDay.keys)
            for result in results {
                if result.recoveryPersistenceOwner == .canonicalComputed {
                    // The engine still persists a diagnostic/fallback shadow on WHOOP-import-owned days.
                    // Imported Recovery wins Home, but the canonical row is expected to survive range
                    // reconciliation and must not be mistaken for a stale extra day.
                    expectedCanonicalDays.insert(result.day)
                }
                if importedRecoveryByDay[result.day] != nil {
                    // The imported value intentionally wins Home and need not equal NOOP's shadow score.
                    verified += 1
                    continue
                }

                switch result.recoveryPersistenceOwner {
                case .appleHealth:
                    guard let persisted = appleByDay[result.day] else { continue }
                    if sameOptional(persisted.recovery, result.recovery) { verified += 1 }

                case .canonicalComputed:
                    guard let persisted = computedByDay[result.day] else { continue }
                    if let override = overrideByDay[result.day] {
                        if sameOptional(persisted.recovery, override.recovery) { verified += 1 }
                    } else if sameOptional(persisted.recovery, result.recovery) {
                        verified += 1
                    }
                }
            }

            // The engine reconciles its complete requested window. An extra canonical row means a failed
            // stale-day deletion and can otherwise leave yesterday's numerical Recovery visible.
            let reconciled = Set(computedRows.map(\.day)).isSubset(of: expectedCanonicalDays)
            return Self(
                expectedResults: results.count,
                verifiedResults: verified,
                storeAvailable: true,
                reconciledComputedRange: reconciled)
        } catch {
            return failure(expected: results.count)
        }
    }

    private static func failure(expected: Int) -> Self {
        Self(
            expectedResults: expected,
            verifiedResults: 0,
            storeAvailable: false,
            reconciledComputedRange: false)
    }

    private static func sameOptional(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (left?, right?):
            return left.isFinite && right.isFinite && abs(left - right) <= 1e-8
        default: return false
        }
    }
}
