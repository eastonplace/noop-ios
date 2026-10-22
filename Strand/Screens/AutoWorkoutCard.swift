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
                window: demoCandidate, prediction: .generic, sourceId: "demo",
                context: .init(sourceContext: "demo", sourceLineage: "demo", invalidationEpoch: 0),
                databaseInstanceId: "demo", sourceOwner: .init(deviceId: "demo", lineage: "demo")), for: load)
        }
        _state = State(initialValue: initial)
    }
    #endif

    var body: some View {
        Group {
            if autoDetectEnabled, !repo.verifiedExternalSurfaceFenced, let suggestion = state.candidate,
               isDemo || suggestion.context == repo.workoutSuggestionContext {
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

    private func card(for suggestion: AutoWorkoutSuggestion) -> some View {
        PaperCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Label("Workout suggestion", systemImage: symbol(for: state.selectedType))
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)

                HStack(alignment: .firstTextBaseline) {
                    Text(WorkoutSource.displaySport(state.selectedType))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text(confidenceText(suggestion))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }

                Text(promptText(suggestion.window))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    ForEach(Array(suggestion.prediction.evidence.enumerated()), id: \.offset) { item in
                        Text(evidenceText(item.element))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Menu {
                    typeChoice("Workout")
                    ForEach(WorkoutCatalog.all) { sport in typeChoice(sport.name) }
                    if suggestion.prediction.sport != "Workout",
                       WorkoutCatalog.sport(named: suggestion.prediction.sport) == nil {
                        typeChoice(suggestion.prediction.sport)
                    }
                } label: {
                    Label("Change Type", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                .disabled(state.saving)
                .accessibilityIdentifier("autoWorkout.changeType")

                if state.saveResult == .failed {
                    Text("Couldn’t save this workout. Your choice is still here. Try saving again.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("autoWorkout.saveError")
                }

                HStack(spacing: NoopMetrics.space3) {
                    Button { save(suggestion) } label: {
                        if state.saving {
                            Label("Saving…", systemImage: "hourglass")
                        } else {
                            Label("Save", systemImage: "checkmark")
                        }
                    }
                    .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                    .disabled(state.saving || isDemo)
                    .accessibilityIdentifier("autoWorkout.save")

                    Button("Dismiss") { dismiss(suggestion) }
                        .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                        .disabled(state.saving || isDemo)
                        .accessibilityLabel("Dismiss this workout suggestion")
                        .accessibilityIdentifier("autoWorkout.dismiss")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("autoWorkout.card")
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
            return String(localized: "Sustained movement matches the band’s walking signal.")
        case .runningMovement:
            return String(localized: "Sustained movement matches the band’s running signal.")
        case let .similarConfirmedWorkouts(count):
            return String(localized: "Based on \(count) workouts you confirmed at a similar time and duration. This is a context-based suggestion.")
        case .insufficientTypeEvidence:
            return String(localized: "Heart rate suggests activity, but there isn’t enough movement evidence to identify a type.")
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

    private func promptText(_ window: DetectedWorkout) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(window.startSec))
        let start = Self.timeFmt.string(from: date)
        let end = Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(window.endSec)))
        if Calendar.current.isDateInToday(date) {
            return String(localized: "Around \(start)-\(end), \(window.durationMin) min, average HR \(window.avgBpm).")
        }
        if Calendar.current.isDateInYesterday(date) {
            return String(localized: "Yesterday around \(start)-\(end), \(window.durationMin) min, average HR \(window.avgBpm).")
        }
        return String(localized: "On \(Self.dateFmt.string(from: date)), around \(start)-\(end), \(window.durationMin) min, average HR \(window.avgBpm).")
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
        guard !isDemo, let save = state.beginSave() else { return }
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
        guard !isDemo else { return }
        if repo.dismissWorkoutSuggestion(suggestion) { state.clear() }
        else { Task { await reload() } }
    }

    private static let timeFmt: DateFormatter = {
        let formatter = DateFormatter()
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
