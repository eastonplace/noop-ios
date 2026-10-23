import SwiftUI
import StrandAnalytics
import StrandDesign

struct DailyTrainingTargetPreview: View {
    @ObservedObject var model: DailyTrainingTargetViewModel
    @EnvironmentObject private var repo: Repository
    @ScaledMetric(relativeTo: .title) private var valueSize: CGFloat = 36
    @State private var plannedStrain = 10.0
    @State private var plannedSleep = 8.0
    @State private var planOwner: String?

    var body: some View {
        // The scaffold's own header carries the title and the sheet's one close button, so there is no
        // navigation bar (and no second header) above it.
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            ScreenScaffold(title: "Training preview", lazy: true) {
                if let data = model.data,
                   let result = repo.dailyTrainingTargetEvaluation(data, now: timeline.date),
                   let target = result.target {
                    content(result, target: target)
                        .task(id: data.key) { initializePlan(result, data: data) }
                } else {
                    Text("Your data is updating. Close this and reopen it after the sync.")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("trainingTarget.preview")
    }

    private func initializePlan(_ result: DailyTrainingTargetEngine.Result, data: DailyTrainingTargetData) {
        let owner = "\(data.key.sourceContext)|\(data.key.invalidationEpoch)|\(data.key.day)"
        guard planOwner != owner, let target = result.target else { return }
        planOwner = owner
        plannedStrain = StrainScale.displayValue(fromStored: max(result.currentStrainStored ?? 0,
                                                                (target.lowerStored + target.upperStored) / 2))
        plannedSleep = min(12, max(3, result.sleepNeedHours ?? 8))
    }

    private func content(_ result: DailyTrainingTargetEngine.Result,
                         target: DailyTrainingTargetEngine.Target) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            PaperCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Suggested daily total")
                        .font(StrandFont.headline)
                    Text(verbatim: DailyTrainingTargetCopy.range(target))
                        .font(StrandFont.number(valueSize, weight: .bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    DailyTrainingTargetRangeBar(target: target, current: result.currentStrainStored, surface: StrandPalette.card)
                    Text(verbatim: DailyTrainingTargetCopy.progress(target, current: result.currentStrainStored))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            if let current = result.currentStrainStored {
                controls(result, current: current)
                let plannedStored = max(current, StrainScale.storedValue(fromDisplay: plannedStrain))
                if let preview = DailyTrainingTargetEngine.preview(result, plannedTotalStored: plannedStored,
                                                                    plannedSleepHours: plannedSleep) {
                    forecast(preview)
                }
            }
            evidence(result, target: target)
        }
        .foregroundStyle(StrandPalette.textPrimary)
    }

    private func controls(_ result: DailyTrainingTargetEngine.Result, current: Double) -> some View {
        let floor = StrainScale.displayValue(fromStored: current)
        let total = max(floor, plannedStrain)
        return PaperCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Try a plan").font(StrandFont.headline)
                LabeledContent("Daily total Strain", value: total.formatted(.number.precision(.fractionLength(1))))
                    .font(StrandFont.bodyNumber)
                if floor < 21 {
                    Slider(value: Binding(get: { max(floor, plannedStrain) }, set: { plannedStrain = $0 }),
                           in: floor...21, step: 0.1)
                        .tint(DomainTint.strain.accent)
                        .accessibilityLabel("Planned daily total Strain")
                        .accessibilityValue(total.formatted(.number.precision(.fractionLength(1))))
                        .accessibilityIdentifier("trainingTarget.strainSlider")
                }
                Text("Includes what you’ve already recorded today.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                LabeledContent("Sleep tonight", value: SleepStageRowPresentation.durationText(plannedSleep * 60))
                    .font(StrandFont.bodyNumber)
                Slider(value: $plannedSleep, in: 3...12, step: 0.25)
                    .tint(DomainTint.sleep.accent)
                    .accessibilityLabel("Planned sleep hours")
                    .accessibilityValue(SleepSpokenDuration.text(minutes: plannedSleep * 60))
                    .accessibilityIdentifier("trainingTarget.sleepSlider")
                if let need = result.sleepNeedHours {
                    Text("Sleep need: \(SleepStageRowPresentation.durationText(need * 60))")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private func forecast(_ preview: DailyTrainingTargetEngine.Preview) -> some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Estimated result").font(StrandFont.headline)
                if let recovery = preview.recovery {
                    LabeledContent("Tomorrow's Recovery", value: "\(Int(recovery.low.rounded()))–\(Int(recovery.high.rounded()))%")
                        .font(StrandFont.bodyNumber)
                    Text("An estimate. Your next sleep sets the real score.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("A Recovery estimate needs a few more days of scores.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                if let ratio = preview.loadRatio {
                    LabeledContent("Training load after today",
                                   value: String(localized: "\(ratio.formatted(.number.precision(.fractionLength(2))))× your usual"))
                        .font(StrandFont.bodyNumber)
                } else {
                    Text("The load preview needs about two weeks of Strain history.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Text("Just a preview. Nothing is saved.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func evidence(_ result: DailyTrainingTargetEngine.Result,
                          target: DailyTrainingTargetEngine.Target) -> some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Why this range").font(StrandFont.headline)
                ForEach(Array(target.drivers.enumerated()), id: \.offset) { _, driver in
                    Text(verbatim: DailyTrainingTargetCopy.driver(driver))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Text("Your usual day is Strain \(StrainScale.formatted(target.usualStrainStored)).")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                if let needDay = result.sleepNeedDay, needDay != result.day {
                    Text("Sleep Need last updated: \(FriendlyDayLabel.label(forDayKey: needDay, today: result.day))")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                DisclosureGroup("How this is calculated") {
                    Text("Your target starts from your usual Strain on recent days, then adjusts for today’s Recovery, last night’s sleep, and how hard you’ve trained lately. It’s an estimate to help you plan.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.top, 6)
                }
                .font(StrandFont.footnote)
            }
        }
    }
}
