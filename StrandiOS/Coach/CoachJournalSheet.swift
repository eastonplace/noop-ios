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
            ScreenScaffold(title: "Journal") {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    CoachJournalDayPicker(day: session.day, onSelect: session.select)
                    if let snapshot = session.snapshot,
                       snapshot.sourceContext == repository.journalEntrySourceContext,
                       session.access.canUseManualJournal {
                        JournalLogCard(importedQuestions: snapshot.importedQuestions,
                                       answers: snapshot.answers, numericAnswers: snapshot.numericAnswers,
                                       dayOffset: dayOffset,
                                       selectedDayKey: Binding<String?>(get: { session.day }, set: { value in
                                           if let value { session.select(day: value) }
                                       }),
                                       chrome: .embedded,
                                       onChanged: changed)
                            .disabled(session.isLoading)
                        dayDetails(snapshot.details)
                        VStack(alignment: .leading, spacing: 0) {
                            CoachTextButton("Ask Coach about patterns", symbol: "chevron.right") {
                                onAskCoach(CoachEvidencePolicy.journalPatternsPrompt)
                                dismiss()
                            }
                            .accessibilityIdentifier("coach.journal.sheet.insights")
                            Text("Coach needs your permission to read your records.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                    } else if session.isLoading {
                        ProgressView("Loading Journal…").frame(maxWidth: .infinity, minHeight: 100)
                    } else {
                        Text(repository.verifiedExternalSurfaceFenced
                             ? "Your records are updating. Open Journal again after the update finishes."
                             : "Your journal is not available right now.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        CoachTextButton("Try again", action: session.refresh)
                    }
                    if let status = session.status {
                        Text(verbatim: status).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
            .background(StrandPalette.appCanvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheetScreenScaffoldEnvironment(onClose: { dismiss() })
        }
        .drillInDestinationEnvironment()
        .tint(StrandPalette.journalAccent)
        .environmentObject(repository)
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

    /// The saved mood and note for the day, as plain lines, and one text action to change them.
    private func dayDetails(_ details: JournalEntryDayDetails) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            if let mood = details.mood {
                Text("Mood · \(MoodStore.label(for: mood))")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityIdentifier("coach.journal.sheet.mood")
            }
            if !details.note.isEmpty {
                Text(verbatim: details.note)
                    .font(StrandFont.subhead).lineLimit(4)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            CoachTextButton(details.mood == nil && details.note.isEmpty ? "Add note and mood" : "Edit note and mood") {
                guard session.access.canUseManualJournal else { return }
                entry = JournalEntryPresentation(day: session.day, sourceIdentity: repository.journalEntrySourceIdentity)
            }
            .accessibilityIdentifier("coach.journal.sheet.dayDetails")
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
/// "Day · Today ⌄": a plain row that opens the month calendar, with the day named the way people say it.
struct CoachJournalDayPicker: View {
    let day: String
    let onSelect: (String) -> Void
    @State private var choosing = false

    var body: some View {
        Button { choosing = true } label: {
            HStack(spacing: NoopMetrics.space2) {
                Text("Day").foregroundStyle(StrandPalette.textSecondary)
                Text(verbatim: "·").foregroundStyle(StrandPalette.textTertiary)
                Text(verbatim: FriendlyDayLabel.label(forDayKey: day)).foregroundStyle(StrandPalette.textPrimary)
                Image(systemName: "chevron.down")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .font(StrandFont.body)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Day")
        .accessibilityValue(FriendlyDayLabel.label(forDayKey: day))
        .accessibilityHint("Choose a different day to log")
        .accessibilityIdentifier("coach.journal.wakeDayPicker")
        .sheet(isPresented: $choosing) {
            DayCalendarSheet(selected: CoachJournalDaySelection.date(for: day) ?? Date(), today: Date(),
                             daysWithData: []) { onSelect(Repository.localDayKey($0)) }
        }
    }
}

/// A secondary action in the house style: accent text, no capsule, border or glass, with a 44pt tap area.
struct CoachTextButton: View {
    let title: LocalizedStringKey
    var symbol: String?
    var tint: Color = StrandPalette.accent
    let action: () -> Void

    init(_ title: LocalizedStringKey, symbol: String? = nil, tint: Color = StrandPalette.accent,
         action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: NoopMetrics.space1) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                if let symbol {
                    Image(systemName: symbol).font(StrandFont.caption).accessibilityHidden(true)
                }
            }
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(tint)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
