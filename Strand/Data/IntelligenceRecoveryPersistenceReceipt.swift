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
/// - Apple Watch results must match the persisted `apple-health` row exactly.
/// - Strap/import-derived results must match a computed row, unless a durable user Recovery override owns that
///   day; in that case the visible row must match the override instead of the automatic result.
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
        let expected = results.filter { $0.recovery != nil }
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

            var computedByDay: [String: [DailyMetric]] = [:]
            var overrideByDay: [String: [SleepRecoveryDailyOverride]] = [:]
            for source in repository.computedReadIds {
                let rows = try await store.dailyMetrics(
                    deviceId: source,
                    from: firstDay,
                    to: lastDay)
                for row in rows { computedByDay[row.day, default: []].append(row) }

                let overrides = try await store.sleepRecoveryDailyOverrides(
                    deviceId: source,
                    from: firstDay,
                    to: lastDay)
                for override in overrides {
                    overrideByDay[override.day, default: []].append(override)
                }
            }

            var verified = 0
            for result in expected {
                guard let automatic = result.recovery else { continue }
                switch result.source {
                case .appleHealth:
                    if approximatelyEqual(appleByDay[result.day]?.recovery, automatic) {
                        verified += 1
                    }

                case .computed, .whoopImport:
                    let rows = computedByDay[result.day] ?? []
                    let overrides = overrideByDay[result.day] ?? []
                    if !overrides.isEmpty {
                        // A durable manual recovery intentionally owns the visible field. Accept only when a
                        // persisted computed row reflects one of those exact override values, including nil.
                        if overrides.contains(where: { override in
                            rows.contains(where: { sameOptional($0.recovery, override.recovery) })
                        }) {
                            verified += 1
                        }
                    } else if rows.contains(where: { approximatelyEqual($0.recovery, automatic) }) {
                        verified += 1
                    }
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
