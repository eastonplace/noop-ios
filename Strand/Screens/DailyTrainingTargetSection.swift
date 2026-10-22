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
    @ScaledMetric(relativeTo: .title2) private var valueSize: CGFloat = 26

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

    /// A plain text action: no capsule or glass. The hit area grows to 44pt without growing the eyebrow row.
    private var previewButton: some View {
        Button { showingPreview = true } label: {
            HStack(spacing: 3) {
                Text("Preview")
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .contentShape(Rectangle().inset(by: -14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preview training and sleep")
        .accessibilityIdentifier("today.trainingTarget.preview")
    }

    private func statusLabel(_ status: DailyTrainingTargetCopy.Status) -> some View {
        Text(verbatim: status.text)
            .font(StrandFont.subhead)
            .foregroundStyle(status.color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// The range with its unit on one baseline, and today's status beside it. When the status will not fit beside
    /// the value (a large text size) it drops below.
    private func valueRow(_ target: DailyTrainingTargetEngine.Target, status: DailyTrainingTargetCopy.Status?) -> some View {
        let value = HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(verbatim: DailyTrainingTargetCopy.range(target))
                .font(StrandFont.number(valueSize, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("Strain")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                value
                Spacer(minLength: NoopMetrics.space2)
                if let status { statusLabel(status) }
            }
            VStack(alignment: .leading, spacing: 2) {
                value
                if let status { statusLabel(status).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    private func content(now: Date) -> some View {
        let result = model.data.flatMap { repo.dailyTrainingTargetEvaluation($0, now: now) }
        return VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow("Training target", systemImage: "flame.fill", tint: .strain,
                           trailing: result?.target == nil ? .none : .custom(AnyView(previewButton)))
            if let result, let target = result.target {
                let status = DailyTrainingTargetCopy.status(target, current: result.currentStrainStored)
                VStack(alignment: .leading, spacing: 10) {
                    valueRow(target, status: status)
                    DailyTrainingTargetRangeBar(target: target, current: result.currentStrainStored)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: DailyTrainingTargetCopy.summary(target, current: result.currentStrainStored)))
                Text(verbatim: DailyTrainingTargetCopy.reason(target))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(2)
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

/// A thin track on the full 0–21 Strain scale, the target band in the Strain blue, and today's marker on top of it.
struct DailyTrainingTargetRangeBar: View {
    let target: DailyTrainingTargetEngine.Target
    let current: Double?
    /// The surface the bar sits on. The marker's ring is this colour, so it reads on top of the band.
    var surface: Color = StrandPalette.appCanvas

    private let trackHeight: CGFloat = 6
    private let dot: CGFloat = 8
    private let ring: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width)
            let marker = dot + ring * 2
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.hairline).frame(height: trackHeight)
                Capsule().fill(DomainTint.strain.accent)
                    .frame(width: min(width, max(2, width * (target.upperStored - target.lowerStored) / 100)), height: trackHeight)
                    .offset(x: min(max(0, width - 2), width * target.lowerStored / 100))
                if let current {
                    Circle().fill(StrandPalette.textPrimary)
                        .frame(width: dot, height: dot)
                        .padding(ring)
                        .background(Circle().fill(surface))
                        .offset(x: max(0, min(width - marker, width * current / 100 - marker / 2)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: dot + ring * 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: DailyTrainingTargetCopy.progress(target, current: current)))
    }
}

enum DailyTrainingTargetCopy {
    static func range(_ target: DailyTrainingTargetEngine.Target) -> String {
        "\(StrainScale.formatted(target.lowerStored))–\(StrainScale.formatted(target.upperStored))"
    }

    /// Today's Strain against the range, in plain words. Nil when today's Strain is unknown.
    enum Status: Equatable {
        case toGo(String)
        case inRange
        case above

        var text: String {
            switch self {
            case .toGo(let amount): return String(localized: "\(amount) to go")
            case .inRange: return String(localized: "In range")
            case .above: return String(localized: "Above target")
            }
        }

        var color: Color {
            switch self {
            case .toGo: return StrandPalette.textSecondary
            case .inRange: return StrandPalette.recoveryHigh
            case .above: return StrandPalette.statusWarning
            }
        }
    }

    static func status(_ target: DailyTrainingTargetEngine.Target, current: Double?) -> Status? {
        guard let current else { return nil }
        switch target.progress {
        case .unknown: return nil
        case .within: return .inRange
        case .above: return .above
        case .below: return .toGo(StrainScale.formattedDelta(target.lowerStored - current))
        }
    }

    /// One spoken line for the value row and the bar together.
    static func summary(_ target: DailyTrainingTargetEngine.Target, current: Double?) -> String {
        let low = StrainScale.formatted(target.lowerStored)
        let high = StrainScale.formatted(target.upperStored)
        guard let current, let status = status(target, current: current) else {
            return String(localized: "Training target \(low) to \(high) Strain.")
        }
        let today = StrainScale.formatted(current)
        switch status {
        case .toGo(let amount): return String(localized: "Training target \(low) to \(high) Strain. Today \(today), \(amount) to go.")
        case .inRange: return String(localized: "Training target \(low) to \(high) Strain. Today \(today), in range.")
        case .above: return String(localized: "Training target \(low) to \(high) Strain. Today \(today), above target.")
        }
    }

    /// The main reason, short enough for one line: what leads the target, then where it sits against the usual day.
    static func reason(_ target: DailyTrainingTargetEngine.Target) -> String {
        let drivers = target.drivers
        let lead: String
        if drivers.contains(.recoveryLow) { lead = String(localized: "Low recovery") }
        else if drivers.contains(.recentLoadHigh) { lead = String(localized: "Heavy recent training") }
        else if drivers.contains(.sleepShort) { lead = String(localized: "Short on sleep") }
        else if drivers.contains(.recoveryModerate) { lead = String(localized: "Moderate recovery") }
        else if drivers.contains(.recoveryHigh) { lead = String(localized: "High recovery") }
        else { return driver(drivers.first ?? .loadBuilding) }
        let middle = (target.lowerStored + target.upperStored) / 2
        let ratio = target.usualStrainStored > 0 ? middle / target.usualStrainStored : 1
        let direction: String
        switch ratio {
        case 1.02...: direction = String(localized: "a bit above your usual day")
        case 0.9..<1.02: direction = String(localized: "close to your usual day")
        case 0.75..<0.9: direction = String(localized: "a bit below your usual day")
        default: direction = String(localized: "well below your usual day")
        }
        return String(localized: "\(lead) · \(direction)")
    }

    static func progress(_ target: DailyTrainingTargetEngine.Target, current: Double?) -> String {
        guard let current else { return String(localized: "Sync your strap to see where today's Strain sits in this range.") }
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
