import SwiftUI
import StrandAnalytics
import StrandDesign

@MainActor
final class DailyTrainingTargetViewModel: ObservableObject {
    @Published private(set) var data: DailyTrainingTargetData?
    @Published private(set) var failure: String?
    @Published private(set) var isLoading = false
    private var token = UUID()

    func load(repository: Repository, now: Date, force: Bool = false) async {
        let key = repository.dailyTrainingTargetReadKey(now: now)
        guard force || data?.key != key else { return }
        let request = UUID()
        token = request
        data = nil; failure = nil; isLoading = true
        do {
            let next = try await repository.loadDailyTrainingTarget(now: now)
            guard !Task.isCancelled, token == request,
                  next.key == repository.dailyTrainingTargetReadKey(now: now) else { return }
            data = next
            isLoading = false
        } catch {
            guard !Task.isCancelled, token == request else { return }
            isLoading = false
            if error as? DailyTrainingTargetReadError == .snapshotUnavailable {
                failure = String(localized: "Sync your current daily metrics to build a training target.")
            } else if error as? DailyTrainingTargetReadError == .sourceChanged {
                failure = String(localized: "Your data source changed. Load the current records to continue.")
            } else {
                failure = String(localized: "Training records could not be read. Try again.")
            }
        }
    }
}

/// A value-sized leaf of Today. Live progress never requests another database read or strap sample.
struct DailyTrainingTargetSection: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = DailyTrainingTargetViewModel()
    @State private var showingPreview = false
    @State private var retry = UUID()
    @ScaledMetric(relativeTo: .title) private var valueSize: CGFloat = 30

    private struct Trigger: Hashable {
        let key: DailyTrainingTargetReadKey
        let retry: UUID
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            content(now: timeline.date)
                .task(id: Trigger(key: repo.dailyTrainingTargetReadKey(now: timeline.date), retry: retry)) {
                    await model.load(repository: repo, now: timeline.date)
                }
        }
        .sheet(isPresented: $showingPreview) {
            DailyTrainingTargetPreview(model: model)
                .sheetScreenScaffoldEnvironment()
        }
        .accessibilityIdentifier("today.trainingTarget")
    }

    private func content(now: Date) -> some View {
        let result = model.data.flatMap { repo.dailyTrainingTargetEvaluation($0, now: now) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Training target")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if result?.target != nil {
                    Button { showingPreview = true } label: {
                        Label("Preview", systemImage: "slider.horizontal.3")
                            .font(StrandFont.caption)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityLabel("Preview training and sleep")
                    .accessibilityIdentifier("today.trainingTarget.preview")
                }
            }
            if let result, let target = result.target {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: DailyTrainingTargetCopy.range(target))
                        .font(StrandFont.number(valueSize, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Estimated daily Strain range")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                DailyTrainingTargetRangeBar(target: target, current: result.currentStrainStored)
                Text(verbatim: DailyTrainingTargetCopy.progress(target, current: result.currentStrainStored))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: DailyTrainingTargetCopy.driver(target.drivers.first ?? .loadBuilding))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let result {
                Text(verbatim: DailyTrainingTargetCopy.unavailable(result))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let failure = model.failure {
                Text(verbatim: failure)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                Button("Try again") { retry = UUID() }
                    .buttonStyle(NoopButtonStyle(.secondary))
            } else {
                ProgressView("Reading training history")
                    .font(StrandFont.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DailyTrainingTargetRangeBar: View {
    let target: DailyTrainingTargetEngine.Target
    let current: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.hairline).frame(height: 6)
                Capsule().fill(DomainTint.strain.accent)
                    .frame(width: min(width, max(2, width * (target.upperStored - target.lowerStored) / 100)), height: 6)
                    .offset(x: min(max(0, width - 2), width * target.lowerStored / 100))
                if let current {
                    Circle().fill(StrandPalette.textPrimary)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(StrandPalette.appCanvas, lineWidth: 2))
                        .offset(x: max(0, min(width - 10, width * current / 100 - 5)))
                }
            }
            .frame(height: 18)
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: DailyTrainingTargetCopy.progress(target, current: current)))
    }
}

enum DailyTrainingTargetCopy {
    static func range(_ target: DailyTrainingTargetEngine.Target) -> String {
        "\(StrainScale.formatted(target.lowerStored))–\(StrainScale.formatted(target.upperStored))"
    }

    static func progress(_ target: DailyTrainingTargetEngine.Target, current: Double?) -> String {
        guard let current else { return String(localized: "Current Strain needs a recent sync. Your target uses completed days.") }
        let value = StrainScale.formatted(current)
        switch target.progress {
        case .unknown: return String(localized: "Current Strain is unavailable.")
        case .below: return String(localized: "Today: \(value). The range applies to your total day.")
        case .within: return String(localized: "Today: \(value). You are within the suggested range.")
        case .above: return String(localized: "Today: \(value). You have passed the suggested range. Keep the rest of the day easy.")
        }
    }

    static func driver(_ driver: DailyTrainingTargetEngine.Driver) -> String {
        switch driver {
        case .recoveryLow: return String(localized: "Low Recovery lowers today's range.")
        case .recoveryModerate: return String(localized: "Moderate Recovery keeps the range below your usual day.")
        case .recoveryHigh: return String(localized: "High Recovery allows a small increase from your usual day.")
        case .sleepShort: return String(localized: "Recorded sleep was below 90% of your sleep need.")
        case .sleepMet: return String(localized: "Recorded sleep was close to or above your sleep need.")
        case .recentLoadHigh: return String(localized: "Recent load is above your longer-term base, which lowers the target.")
        case .loadBuilding: return String(localized: "Load history is still building. The range uses recent recorded days.")
        }
    }

    static func unavailable(_ result: DailyTrainingTargetEngine.Result) -> String {
        switch result.unavailableReason {
        case .needsRecovery: return String(localized: "Today's Recovery is not ready. Sync after your main sleep to build a target.")
        case .needsSleep: return String(localized: "Today's sleep duration is not ready. Review your latest sleep before planning.")
        case .needsSleepNeed: return String(localized: "A recent Sleep Need is required. Sync your sleep records to continue.")
        case .needsRecentHistory:
            return String(localized: "A target needs 7 recorded Strain days in the past 14 days, including yesterday. Available: \(result.observedDays).")
        case .invalidHistory, .invalidDay, nil: return String(localized: "The current records cannot produce a valid target. Review your data in Trends.")
        }
    }
}
