import Foundation
import WhoopStore

/// Source-to-store completion receipt for a finished Intelligence pass. `IntelligenceEngine.analyzeRecent`
/// currently treats several best-effort auxiliary writes as non-fatal and historically used `try?` at those
/// seams. A publication-sensitive caller must therefore verify the one field this pipeline promises before it
/// clears a durable source journal: every non-nil Recovery the engine says it calculated must exist in the
/// namespace that Home will read.
///
/// This is deliberately a postcondition, not a second scorer:
/// - It never invents or recalculates Recovery.
/// - Nil Recovery remains legitimate for missing inputs or a calibrating baseline.
/// - A WHOOP-import-owned day is excluded: the authoritative imported row already owns Home, and its value need
///   not equal NOOP's shadow calculation.
/// - Apple Watch results must match the persisted `apple-health` row exactly.
/// - NOOP-computed results must match the engine's stable canonical `my-whoop-noop` row, unless a durable user
///   Recovery override owns that day; in that case the same canonical row must match the override instead.
///
/// Any read failure or missing/mismatched durable result returns false. The HealthKit scoring journal and
/// Repository publication fence then remain in place for an idempotent retry rather than exposing stale Home.
struct IntelligenceRecoveryPersistenceReceipt: Equatable, Sendable {
    let expectedRecoveries: Int
    let verifiedRecoveries: Int
    let storeAvailable: Bool

    var complete: Bool {
        storeAvailable && verifiedRecoveries == expectedRecoveries
    }

    @MainActor
    static func verify(
        results: [IntelligenceEngine.Computed],
        repository: Repository
    ) async -> Self {
        let expected = results.filter {
            $0.recovery != nil && $0.source != .whoopImport
        }
        guard !expected.isEmpty else {
            return Self(expectedRecoveries: 0, verifiedRecoveries: 0, storeAvailable: true)
        }
        guard let store = await repository.storeHandle(),
              let firstDay = expected.map(\.day).min(),
              let lastDay = expected.map(\.day).max() else {
            return Self(expectedRecoveries: expected.count, verifiedRecoveries: 0, storeAvailable: false)
        }

        do {
            let appleRows = try await store.dailyMetrics(
                deviceId: Repository.appleHealthSource,
                from: firstDay,
                to: lastDay)
            let appleByDay = Dictionary(
                appleRows.map { ($0.day, $0) },
                uniquingKeysWith: { _, newest in newest })

            // AppModel.deviceId is intentionally stable `my-whoop`; IntelligenceEngine always writes its
            // computed results to that id's `-noop` sibling even after the Repository follows a re-paired strap.
            let computedSource = Repository.whoopSource + "-noop"
            let computedRows = try await store.dailyMetrics(
                deviceId: computedSource,
                from: firstDay,
                to: lastDay)
            let computedByDay = Dictionary(
                computedRows.map { ($0.day, $0) },
                uniquingKeysWith: { _, newest in newest })
            let overrides = try await store.sleepRecoveryDailyOverrides(
                deviceId: computedSource,
                from: firstDay,
                to: lastDay)
            let overrideByDay = Dictionary(
                overrides.map { ($0.day, $0) },
                uniquingKeysWith: { _, newest in newest })

            var verified = 0
            for result in expected {
                guard let automatic = result.recovery else { continue }
                switch result.source {
                case .appleHealth:
                    if approximatelyEqual(appleByDay[result.day]?.recovery, automatic) {
                        verified += 1
                    }

                case .computed:
                    guard let persisted = computedByDay[result.day] else { continue }
                    if let override = overrideByDay[result.day] {
                        // A durable manual recovery intentionally owns the visible field, including nil.
                        if sameOptional(persisted.recovery, override.recovery) {
                            verified += 1
                        }
                    } else if approximatelyEqual(persisted.recovery, automatic) {
                        verified += 1
                    }

                case .whoopImport:
                    // Filtered above; keep the switch exhaustive if DaySource grows compiler checking.
                    break
                }
            }

            return Self(
                expectedRecoveries: expected.count,
                verifiedRecoveries: verified,
                storeAvailable: true)
        } catch {
            return Self(
                expectedRecoveries: expected.count,
                verifiedRecoveries: 0,
                storeAvailable: false)
        }
    }

    private static func approximatelyEqual(_ lhs: Double?, _ rhs: Double) -> Bool {
        guard let lhs, lhs.isFinite, rhs.isFinite else { return false }
        return abs(lhs - rhs) <= 1e-8
    }

    private static func sameOptional(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return left.isFinite && right.isFinite && abs(left - right) <= 1e-8
        default:
            return false
        }
    }
}
