#if os(iOS)
import SwiftUI
import StrandDesign

/// A dedicated manual destination: no Coach model, nested CoachingRootView, or automatic insight
/// side effects. Its existing journal controls and reviewed-entry sheet keep their original owners.
struct CoachJournalSheet: View {
    @ObservedObject private var repository: Repository
    @ObservedObject private var catalog: JournalCatalogStore
    @StateObject private var session: CoachJournalSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var entry: JournalEntryPresentation?
    @State private var visible = false
    let onDaySelected: (String) -> Void
    let onChanged: () -> Void
    let onAskCoach: (String) -> Void

    init(repository: Repository, catalog: JournalCatalogStore, day: String,
         onDaySelected: @escaping (String) -> Void, onChanged: @escaping () -> Void,
         onAskCoach: @escaping (String) -> Void) {
        self.repository = repository
        self.catalog = catalog
        self._session = StateObject(wrappedValue: CoachJournalSession(repository: repository, day: day, manualReads: true))
        self.onDaySelected = onDaySelected
        self.onChanged = onChanged
        self.onAskCoach = onAskCoach
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space5) {
                    CoachJournalDayPicker(day: session.day, onSelect: session.select)
                    if let snapshot = session.snapshot,
                       snapshot.sourceContext == repository.journalEntrySourceContext,
                       session.access.canUseManualJournal {
                        dayDetails(snapshot.details)
                        JournalLogCard(importedQuestions: snapshot.importedQuestions,
                                       answers: snapshot.answers, numericAnswers: snapshot.numericAnswers,
                                       dayOffset: dayOffset,
                                       selectedDayKey: Binding<String?>(get: { session.day }, set: { value in
                                           if let value { session.select(day: value) }
                                       }),
                                       onChanged: changed)
                            .disabled(session.isLoading)
                        Button {
                            onAskCoach("What associations do my journal entries have with recovery over the last 90 days?")
                            dismiss()
                        } label: { Label("Ask Coach about my journal", systemImage: "sparkles") }
                        .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                        .accessibilityIdentifier("coach.journal.sheet.insights")
                        Text("Coach needs permission to read your records for insights. Journal patterns describe associations, not causes.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    } else if session.isLoading {
                        ProgressView("Loading Journal…").frame(maxWidth: .infinity, minHeight: 100)
                    } else {
                        Text(repository.verifiedExternalSurfaceFenced
                             ? "Your records are updating. Open Journal again after the update finishes."
                             : "Your journal is not available right now. You can try loading it again.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        Button("Try again", action: session.refresh)
                            .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                    }
                    if let status = session.status {
                        Text(verbatim: status).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.appCanvas.ignoresSafeArea())
            .navigationTitle("Journal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(StrandPalette.journalAccent)
        .environmentObject(repository)
        .coachSettingsSheetEnvironment()
        .sheet(item: $entry, onDismiss: session.reloadCatalog) { presentation in
            JournalEntryComposer(catalog: catalog, presentation: presentation,
                                 importedQuestions: session.snapshot?.importedQuestions ?? [],
                                 currentDay: session.day, onSaved: changed)
                .environmentObject(repository)
        }
        .task {
            visible = true
            configureSession()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { configureSession() } else { session.pause() }
        }
        .onChange(of: session.day) { _, day in onDaySelected(day) }
        .onDisappear { visible = false; session.pause() }
        .accessibilityIdentifier("coach.journal.sheet")
    }

    private func dayDetails(_ details: JournalEntryDayDetails) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Day note and mood").font(StrandFont.headline)
            if let mood = details.mood {
                Text("\(MoodStore.face(for: mood)) \(MoodStore.label(for: mood))")
                    .font(StrandFont.subhead)
            }
            if !details.note.isEmpty {
                Text(verbatim: details.note).font(StrandFont.subhead).lineLimit(5)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Button {
                guard session.access.canUseManualJournal else { return }
                entry = JournalEntryPresentation(day: session.day, sourceIdentity: repository.journalEntrySourceIdentity)
            } label: { Label("Review note and mood", systemImage: "square.and.pencil") }
            .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
            .accessibilityIdentifier("coach.journal.sheet.dayDetails")
            Text("Open review, choose Update note and mood, then Save when you are ready.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var dayOffset: Binding<Int> {
        Binding(get: { CoachJournalDaySelection.offset(for: session.day) ?? 0 },
                set: { session.select(day: CoachJournalDaySelection.key(dayOffset: $0)) })
    }

    private func configureSession() {
        session.configure(coachEnabled: false, usesPersonalData: false, isPreview: false,
                          active: visible && scenePhase == .active)
    }

    private func changed() {
        // JournalLogCard also invokes this callback on date selection and catalog edits.
        session.refresh()
        catalog.reloadFromDefaults()
        onChanged()
    }
}

/// A civil wake-day selection is explicit. Neither typed prose nor a later midnight changes this key.
struct CoachJournalDayPicker: View {
    let day: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            DatePicker("Wake day", selection: Binding(
                get: { CoachJournalDaySelection.date(for: day) ?? Date() },
                set: { onSelect(Repository.localDayKey($0)) }), displayedComponents: .date)
                .datePickerStyle(.compact)
                .font(StrandFont.subhead)
                .accessibilityIdentifier("coach.journal.wakeDayPicker")
            Text("The night and day leading into this morning. The selected date, not dates mentioned in your entry, controls where it is saved.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
