import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// Reusable presentation for the RyanBR v9.1 heart-rate-recovery metric. The card owns its narrow local
/// read and can be embedded by workout detail without changing the stored workout schema or score models.
struct WorkoutHeartRateRecoveryCard: View {
    let workout: WorkoutRow
    let maxHR: Double

    @EnvironmentObject private var repo: Repository
    @State private var result: HeartRateRecovery.Result?

    var body: some View {
        // Nothing while the first read is out: a section that appeared and then went away would shift the page. The
        // section brings its own separator, so a page with no recovery has no dangling one.
        Group {
            if let result {
                VStack(alignment: .leading, spacing: 0) {
                    FlatSectionSeparator()
                    FlatSection("Heart-rate recovery", systemImage: "heart.text.square", tint: .heart) {
                        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
                            Text("Drop from your highest heart rate in the final 30 seconds")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            FactStrip(facts: [
                                fact("After \(1) min", result.after1Minute),
                                fact("After \(2) min", result.after2Minutes),
                                fact("After \(5) min", result.after5Minutes),
                            ])
                            Text("Calculated on-device from recorded post-workout heart rate. A missing value means the strap did not record enough nearby samples; NOOP does not interpolate it.")
                                .font(StrandFont.micro)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilitySummary(result))
            }
        }
        .task(id: taskKey) {
            await loadAsCoverageArrives()
        }
    }

    /// Query immediately, then once after each still-pending recovery window. A detail screen opened right
    /// after Finish must not permanently cache “no data” before the 1/2/5-minute samples have had time to land.
    /// A mature workout performs exactly one read; corrupt timestamps cannot overflow deadline arithmetic or
    /// create an unbounded task sleep because only deadlines inside the six-minute observation horizon survive.
    private func loadAsCoverageArrives() async {
        result = nil

        let tolerance = HeartRateRecovery.measurementToleranceSeconds
        let now = Int(Date().timeIntervalSince1970)
        let maximumRefreshHorizon = 6 * 60

        func deadline(after seconds: Int) -> Int? {
            let (offset, offsetOverflow) = seconds.addingReportingOverflow(tolerance)
            guard !offsetOverflow else { return nil }
            let (value, overflow) = workout.endTs.addingReportingOverflow(offset)
            return overflow ? nil : value
        }

        let futureDeadlines = [
            deadline(after: 60),
            deadline(after: 2 * 60),
            deadline(after: 5 * 60),
        ].compactMap { $0 }.filter {
            let (delay, overflow) = $0.subtractingReportingOverflow(now)
            return !overflow && delay > 0 && delay <= maximumRefreshHorizon
        }
        let queryDeadlines = [now] + futureDeadlines

        for deadline in queryDeadlines {
            let current = Int(Date().timeIntervalSince1970)
            let (delay, overflow) = deadline.subtractingReportingOverflow(current)
            guard !overflow else { continue }
            if delay > 0 {
                // `delay` is bounded above before entering the loop, so this multiplication cannot overflow.
                let nanoseconds = UInt64(delay) * 1_000_000_000
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }

            let next = await repo.workoutHeartRateRecovery(for: workout, maxHR: maxHR)
            guard !Task.isCancelled else { return }
            result = next
        }
    }

    private var taskKey: String {
        "\(workout.startTs):\(workout.endTs):\(workout.sport):\(workout.source):\(maxHR.bitPattern)"
    }

    /// One window of the recovery as a fact: the drop with its arrow ("↓ 24"), or a dash when the strap did not record
    /// enough nearby samples.
    private func fact(_ label: LocalizedStringKey, _ value: Int?) -> FactStrip.Fact {
        guard let value else { return .init(label, value: WidgetMetrics.missingValue) }
        return .init(label, value: value >= 0 ? "↓ \(value)" : "↑ \(-value)", unit: "bpm")
    }

    private func spoken(_ minutes: Int, _ value: Int?) -> String {
        let reading: String
        if let value {
            reading = value >= 0 ? String(localized: "down \(value) bpm") : String(localized: "up \(-value) bpm")
        } else {
            reading = String(localized: "no reading")
        }
        return String(localized: "After \(minutes) min, \(reading)")
    }

    private func accessibilitySummary(_ result: HeartRateRecovery.Result) -> String {
        let pieces = [spoken(1, result.after1Minute), spoken(2, result.after2Minutes), spoken(5, result.after5Minutes)]
        return String(localized: "Heart-rate recovery. \(pieces.joined(separator: ". "))")
    }
}
