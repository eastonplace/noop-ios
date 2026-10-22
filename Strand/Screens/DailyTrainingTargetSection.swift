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
                failure = String(localized: "Sync your latest data to see today’s target.")
            } else if error as? DailyTrainingTargetReadError == .sourceChanged {
                failure = String(localized: "Your data source changed. Try again to load today’s target.")
            } else {
                failure = String(localized: "Couldn’t read your training records.")
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
                .sheetScreenScaffoldEnvironment(onClose: { showingPreview = false })
        }
        .accessibilityIdentifier("today.trainingTarget")
    }

    private var previewButton: some View {
        Button { showingPreview = true } label: {
            Label("Preview", systemImage: "slider.horizontal.3")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preview training and sleep")
        .accessibilityIdentifier("today.trainingTarget.preview")
    }

    private func content(now: Date) -> some View {
        let result = model.data.flatMap { repo.dailyTrainingTargetEvaluation($0, now: now) }
        return VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow("Training target", systemImage: "flame.fill", tint: .strain,
                           trailing: result?.target == nil ? .none : .custom(AnyView(previewButton)))
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
                Button { retry = UUID() } label: {
                    Text("Try again")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.accent)
                        .frame(minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("today.trainingTarget.retry")
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
        case .recoveryModerate: return String(localized: "Moderate Recovery keeps the range a bit below your usual day.")
        case .recoveryHigh: return String(localized: "High Recovery allows a small increase from your usual day.")
        case .sleepShort: return String(localized: "You slept less than you need, which lowers the target.")
        case .sleepMet: return String(localized: "You got about the sleep you need.")
        case .recentLoadHigh: return String(localized: "Your recent training is heavier than usual, which lowers the target.")
        case .loadBuilding: return String(localized: "Your training history is still building, so the range uses your recent days.")
        }
    }

    static func unavailable(_ result: DailyTrainingTargetEngine.Result) -> String {
        switch result.unavailableReason {
        case .needsRecovery: return String(localized: "Your target appears once today’s Recovery is ready.")
        case .needsSleep: return String(localized: "Your target appears once last night’s sleep is in.")
        case .needsSleepNeed: return String(localized: "Your target appears once today’s sleep need is calculated.")
        case .needsRecentHistory: return String(localized: "Your target needs about a week of recent Strain days.")
        case .invalidHistory, .invalidDay, nil: return String(localized: "Today’s target is paused because some records look off.")
        }
    }
}
