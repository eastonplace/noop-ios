import SwiftUI
import StrandDesign
import StrandAnalytics

/// An opt-in suggestion. The user confirms the activity type before a manual workout is saved.
struct AutoWorkoutCard: View {
    @EnvironmentObject var repo: Repository
    @AppStorage(PuffinExperiment.autoDetectWorkoutsKey) private var autoDetectEnabled = false
    @State private var state = AutoWorkoutCardState()

    #if DEBUG
    /// Screenshot/audit fixture only. Production suggestions always come from the repository.
    private let demoCandidate: DetectedWorkout?

    init(demoCandidate: DetectedWorkout? = nil) {
        self.demoCandidate = demoCandidate
        var initial = AutoWorkoutCardState()
        if let demoCandidate {
            let load = initial.beginLoad()
            initial.receive(AutoWorkoutSuggestion(
                window: demoCandidate,
                prediction: .init(sport: "Walking", confidence: .likely,
                                  evidence: [.walkingMovement, .similarConfirmedWorkouts(count: 4)]),
                sourceId: "demo",
                context: .init(sourceContext: "demo", sourceLineage: "demo", invalidationEpoch: 0),
                databaseInstanceId: "demo", sourceOwner: .init(deviceId: "demo", lineage: "demo")), for: load)
        }
        _state = State(initialValue: initial)
    }
    #endif

    var body: some View {
        Group {
            if let suggestion = state.candidate,
               isDemo || (autoDetectEnabled && !repo.verifiedExternalSurfaceFenced
                          && suggestion.context == repo.workoutSuggestionContext) {
                card(for: suggestion)
            }
        }
        .task(id: AutoWorkoutLoadKey(seq: repo.refreshSeq, enabled: autoDetectEnabled,
                                    context: repo.workoutSuggestionContext,
                                    fenced: repo.verifiedExternalSurfaceFenced)) {
            guard !isDemo else { return }
            await reload()
        }
    }

    private var isDemo: Bool {
        #if DEBUG
        demoCandidate != nil
        #else
        false
        #endif
    }

    /// A flat Today section like its neighbours: a hairline, an eyebrow, a title, one detail line, and plain-text actions.
    private func card(for suggestion: AutoWorkoutSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TodaySectionSeparator(above: 12, below: 13.3)
            VStack(alignment: .leading, spacing: 6) {
                SectionEyebrow("Workout suggestion", systemImage: symbol(for: state.selectedType), tint: .strain)
                    .padding(.bottom, 4)
                Text(verbatim: titleText(suggestion.window))
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: detailText(suggestion))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = suggestion.prediction.evidence.first {
                    Text(verbatim: evidenceText(reason))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if state.saveResult == .failed {
                    Text("Couldn’t save this workout. Your choice is still here. Try saving again.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("autoWorkout.saveError")
                }

                // Side by side when they fit, stacked when large text would squeeze them.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: NoopMetrics.space5) {
                        saveButton(suggestion)
                        changeTypeMenu(suggestion)
                        Spacer(minLength: NoopMetrics.space3)
                        dismissButton(suggestion)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        saveButton(suggestion)
                        changeTypeMenu(suggestion)
                        dismissButton(suggestion)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("autoWorkout.card")
    }

    private func saveButton(_ suggestion: AutoWorkoutSuggestion) -> some View {
        Button { save(suggestion) } label: {
            if state.saving {
                HStack(spacing: NoopMetrics.space2) { ProgressView(); Text("Saving…") }
            } else {
                Text("Save")
            }
        }
        .font(StrandFont.subhead.weight(.semibold))
        .foregroundStyle(StrandPalette.accent)
        .frame(minHeight: 44, alignment: .leading)
        .buttonStyle(.plain)
        .disabled(state.saving)
        .accessibilityIdentifier("autoWorkout.save")
    }

    private func changeTypeMenu(_ suggestion: AutoWorkoutSuggestion) -> some View {
        Menu {
            typeChoice("Workout")
            ForEach(WorkoutCatalog.all) { sport in typeChoice(sport.name) }
            if suggestion.prediction.sport != "Workout",
               WorkoutCatalog.sport(named: suggestion.prediction.sport) == nil {
                typeChoice(suggestion.prediction.sport)
            }
        } label: {
            Text("Change type")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(state.saving)
        .accessibilityIdentifier("autoWorkout.changeType")
    }

    private func dismissButton(_ suggestion: AutoWorkoutSuggestion) -> some View {
        Button { dismiss(suggestion) } label: {
            Text("Dismiss")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(state.saving)
        .accessibilityLabel("Dismiss this workout suggestion")
        .accessibilityIdentifier("autoWorkout.dismiss")
    }

    private func typeChoice(_ name: String) -> some View {
        Button {
            state.selectedType = name
        } label: {
            if state.selectedType == name {
                Label(WorkoutSource.displaySport(name), systemImage: "checkmark")
            } else {
                Text(WorkoutSource.displaySport(name))
            }
        }
    }

    private func confidenceText(_ suggestion: AutoWorkoutSuggestion) -> String {
        guard state.selectedType == suggestion.prediction.sport else { return String(localized: "Your choice") }
        switch suggestion.prediction.confidence {
        case .likely: return String(localized: "Likely")
        case .possible: return String(localized: "Possible")
        case .unclassified: return String(localized: "Type uncertain")
        }
    }

    private func evidenceText(_ evidence: WorkoutTypeSuggestion.Evidence) -> String {
        switch evidence {
        case .walkingMovement:
            return String(localized: "Your steady movement looks like walking.")
        case .runningMovement:
            return String(localized: "Your steady movement looks like running.")
        case let .similarConfirmedWorkouts(count):
            return String(localized: "You’ve saved \(count) similar workouts around this time of day.")
        case .insufficientTypeEvidence:
            return String(localized: "Your heart rate shows activity, but not enough to tell what kind.")
        }
    }

    private func symbol(for type: String) -> String {
        switch type.lowercased() {
        case "walking", "hiking", "treadmill walk": return "figure.walk"
        case "running", "treadmill run": return "figure.run"
        case "cycling", "indoor cycle": return "bicycle"
        case "strength", "bodybuilding", "weightlifting": return "dumbbell"
        default: return "figure.mixed.cardio"
        }
    }

    /// "Walking · 10:50–11:25 AM". Yesterday and older windows say which day first.
    private func titleText(_ window: DetectedWorkout) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(window.startSec))
        let end = Date(timeIntervalSince1970: TimeInterval(window.endSec))
        let range = Self.rangeFmt.string(from: start, to: end)
        let sport = WorkoutSource.displaySport(state.selectedType)
        if Calendar.current.isDateInToday(start) { return "\(sport) · \(range)" }
        if Calendar.current.isDateInYesterday(start) {
            return String(localized: "\(sport) · Yesterday, \(range)")
        }
        return "\(sport) · \(Self.dateFmt.string(from: start)), \(range)"
    }

    /// "35 min · avg HR 112 · Likely".
    private func detailText(_ suggestion: AutoWorkoutSuggestion) -> String {
        let window = suggestion.window
        return String(localized: "\(window.durationMin) min · avg HR \(window.avgBpm) · \(confidenceText(suggestion))")
    }

    private func reload() async {
        guard autoDetectEnabled, !repo.verifiedExternalSurfaceFenced else { state.clear(); return }
        let context = repo.workoutSuggestionContext
        if let current = state.candidate, current.context != context { state.clear() }
        let load = state.beginLoad()
        let next = await repo.autoDetectedWorkoutSuggestion()
        guard !Task.isCancelled, autoDetectEnabled, !repo.verifiedExternalSurfaceFenced,
              repo.workoutSuggestionContext == context else { return }
        state.receive(next, for: load)
    }

    private func save(_ suggestion: AutoWorkoutSuggestion) {
        // The demo fixture has no strap behind it: saving just closes the card, so every control stays live.
        if isDemo { state.clear(); return }
        guard let save = state.beginSave() else { return }
        let type = state.selectedType
        Task {
            let result = await repo.saveWorkoutSuggestion(suggestion, type: type)
            guard state.completeSave(result, for: save) else { return }
            switch result {
            case .saved, .alreadySaved: _ = await repo.refresh(.currentDay)
            case .stale: await reload()
            case .failed: break
            }
        }
    }

    private func dismiss(_ suggestion: AutoWorkoutSuggestion) {
        if isDemo { state.clear(); return }
        if repo.dismissWorkoutSuggestion(suggestion) { state.clear() }
        else { Task { await reload() } }
    }

    private static let rangeFmt: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.locale = .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let dateFmt: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private struct AutoWorkoutLoadKey: Equatable {
    let seq: Int
    let enabled: Bool
    let context: WorkoutSuggestionContext
    let fenced: Bool
}
