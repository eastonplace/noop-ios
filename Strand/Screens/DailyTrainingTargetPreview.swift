import SwiftUI
import StrandAnalytics
import StrandDesign

struct DailyTrainingTargetPreview: View {
    @ObservedObject var model: DailyTrainingTargetViewModel
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var plannedStrain = 10.0
    @State private var plannedSleep = 8.0
    @State private var planOwner: String?

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                ScreenScaffold(title: "Training preview", lazy: true) {
                    if let data = model.data,
                       let result = repo.dailyTrainingTargetEvaluation(data, now: timeline.date),
                       let target = result.target {
                        content(result, target: target)
                            .task(id: data.key) { initializePlan(result, data: data) }
                    } else {
                        Text("Current records are being updated. Close this preview and reopen it after the sync finishes.")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
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
                        .font(.largeTitle.weight(.bold)).monospacedDigit()
                    DailyTrainingTargetRangeBar(target: target, current: result.currentStrainStored)
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
            } else {
                Text("Sync recent Strain to try a plan. The preview starts at your recorded daily total.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
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
                Text("This includes activity already recorded today. Workout Strain does not add directly to daily Strain.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                LabeledContent("Sleep tonight", value: String(localized: "\(plannedSleep.formatted(.number.precision(.fractionLength(2)))) h"))
                    .font(StrandFont.bodyNumber)
                Slider(value: $plannedSleep, in: 3...12, step: 0.25)
                    .tint(DomainTint.sleep.accent)
                    .accessibilityLabel("Planned sleep hours")
                    .accessibilityValue(plannedSleep.formatted(.number.precision(.fractionLength(2))))
                    .accessibilityIdentifier("trainingTarget.sleepSlider")
                if let need = result.sleepNeedHours {
                    Text("Sleep Need: \(need.formatted(.number.precision(.fractionLength(1)))) h")
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
                    Text("Based on \(recovery.nights) recorded recoveries. Your next sleep measurements will determine the actual score.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("A Recovery preview needs at least 5 recent scores from the current Recovery source.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                if let ratio = preview.loadRatio {
                    LabeledContent("Recent load / base after today",
                                   value: "\(ratio.formatted(.number.precision(.fractionLength(2))))×")
                        .font(StrandFont.bodyNumber)
                } else {
                    Text("The load preview needs 14 usable daily Strain records and a nonzero base.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Text("Changing this preview leaves your recorded metrics unchanged.")
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
                Text("Usual daily Strain: \(StrainScale.formatted(target.usualStrainStored)), from \(target.observedDays) recorded days in the past 14 days.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                if let needDay = result.sleepNeedDay, needDay != result.day {
                    Text("Sleep Need last calculated: \(needDay)")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                DisclosureGroup("How this is calculated") {
                    Text("This planning estimate starts from the median of your recent daily Strain. Low, moderate, and high Recovery apply factors of 0.60, 0.85, and 1.05. Short sleep can lower that result by up to 30%. Recent load above 1.2 times your base can lower it by up to another 30%. The range spans 85% to 110% of that adjusted value. Missing days stay missing.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.top, 6)
                }
                .font(StrandFont.footnote)
            }
        }
    }
}
