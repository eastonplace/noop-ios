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
    @State private var loaded = false

    var body: some View {
        Group {
            if let result {
                PaperCard {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("HEART-RATE RECOVERY").strandOverline()
                            Text("Drop from your highest heart rate in the final 30 seconds")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        recoveryTokens(result)
                        Text("Calculated on-device from recorded post-workout heart rate. A missing value means the strap did not record enough nearby samples; NOOP does not interpolate it.")
                            .font(StrandFont.micro)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilitySummary(result))
            } else if loaded {
                EmptyView()
            } else {
                PaperCard {
                    ProgressView("Checking heart-rate recovery…")
                        .frame(maxWidth: .infinity, minHeight: 72)
                }
            }
        }
        .task(id: taskKey) {
            await loadAsCoverageArrives()
        }
    }

    /// Query immediately, then once after each still-pending recovery window. A detail screen opened right
    /// after Finish must not permanently cache “no data” before the 1/2/5-minute samples have had time to land.
    /// The task is identity-cancelled by SwiftUI when the workout/source/HRmax changes or the card disappears.
    private func loadAsCoverageArrives() async {
        result = nil
        loaded = false

        let tolerance = HeartRateRecovery.measurementToleranceSeconds
        let deadlines = [
            workout.endTs,
            workout.endTs + 60 + tolerance,
            workout.endTs + 2 * 60 + tolerance,
            workout.endTs + 5 * 60 + tolerance,
        ]

        for deadline in deadlines {
            let now = Int(Date().timeIntervalSince1970)
            if deadline > now {
                let nanoseconds = UInt64(deadline - now) * 1_000_000_000
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
            loaded = true
        }
    }

    @ViewBuilder
    private func recoveryTokens(_ result: HeartRateRecovery.Result) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                recoveryToken("1 MIN", result.after1Minute)
                recoveryToken("2 MIN", result.after2Minutes)
                recoveryToken("5 MIN", result.after5Minutes)
            }
            VStack(spacing: 8) {
                recoveryToken("1 MIN", result.after1Minute)
                recoveryToken("2 MIN", result.after2Minutes)
                recoveryToken("5 MIN", result.after5Minutes)
            }
        }
    }

    private var taskKey: String {
        "\(workout.startTs):\(workout.endTs):\(workout.sport):\(workout.source):\(maxHR.bitPattern)"
    }

    private func recoveryToken(_ label: LocalizedStringKey, _ value: Int?) -> some View {
        ValueToken(
            label,
            value: value.map(formatRecovery) ?? "—",
            tint: value.map(tint) ?? StrandPalette.textTertiary
        )
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }

    private func formatRecovery(_ value: Int) -> String {
        value >= 0 ? "↓ \(value) bpm" : "↑ \(-value) bpm"
    }

    private func tint(_ value: Int) -> Color {
        value > 0 ? StrandPalette.statusPositive : StrandPalette.statusWarning
    }

    private func accessibilitySummary(_ result: HeartRateRecovery.Result) -> String {
        let pieces = [
            result.after1Minute.map { "one minute \(formatRecovery($0))" },
            result.after2Minutes.map { "two minutes \(formatRecovery($0))" },
            result.after5Minutes.map { "five minutes \(formatRecovery($0))" },
        ].compactMap { $0 }
        return "Heart-rate recovery. " + pieces.joined(separator: ", ")
    }
}
