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
    @StateObject private var log = JournalQuickLogModel()
    @State private var entry: JournalEntryPresentation?
    @State private var visible = false
    /// Days with an answer in the last two months, for the streak under a finished day.
    @State private var loggedDays: Set<String> = []
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
                    if let snapshot = session.snapshot, canWrite(snapshot) {
                        JournalQuickLogProgress(model: log) {
                            CoachJournalDayPicker(day: session.day, onSelect: session.select)
                        }
                        JournalQuickLogSection(model: log, dayKey: session.day,
                                               words: JournalBehaviorDay.words(forStorageKey: session.day),
                                               streak: streak)
                        dayDetails(snapshot.details)
                        VStack(alignment: .leading, spacing: 0) {
                            NavigationLink { CoachingBehaviorSettingsView() } label: {
                                JournalLinkRow(title: "Edit questions",
                                               subtitle: "Turn questions on or off, rename them, add your own",
                                               icon: "slider.horizontal.3")
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("coach.journal.sheet.editQuestions")
                            FlatRowSeparator()
                            CoachTextButton("Ask Coach about patterns", symbol: "chevron.right") {
                                onAskCoach(CoachEvidencePolicy.journalPatternsPrompt)
                                dismiss()
                            }
                            .accessibilityIdentifier("coach.journal.sheet.insights")
                            Text("Coach needs your permission to read your records.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                    } else if session.isLoading {
                        CoachJournalDayPicker(day: session.day, onSelect: session.select)
                        ProgressView("Loading Journal…").frame(maxWidth: .infinity, minHeight: 100)
                    } else {
                        CoachJournalDayPicker(day: session.day, onSelect: session.select)
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
        .task(id: session.snapshot) { await seedLog() }
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

    /// A tap may store an answer only while the loaded day belongs to this source and manual capture is allowed.
    private func canWrite(_ snapshot: CoachJournalSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.sourceContext == repository.journalEntrySourceContext && session.access.canUseManualJournal
    }

    private var streak: Int {
        let live = JournalQuickLog.loggedDays(loggedDays, day: session.day,
                                              values: log.dayKey == session.day ? log.effective : nil)
        return JournalBehaviorDay.streak(logged: live, endingAt: session.day)
    }

    /// Hands the loaded day to the grid. The chosen questions and the earlier day's answers come from the same
    /// store the Journal page reads, so both show the same grid.
    @MainActor private func seedLog() async {
        guard let snapshot = session.snapshot, canWrite(snapshot) else {
            log.reset()
            return
        }
        let epoch = log.changeEpoch
        let items = catalog.resolvedItems(imported: snapshot.importedQuestions)
        let active = await repository.activeCoachingQuestions(for: items)
        let earlierDay = JournalBehaviorDay.shifted(snapshot.day, by: -1) ?? snapshot.day
        let earlier = await repository.journalDayValues(day: earlierDay)
        let recent = await repository.journalEntries(days: 60)
        guard !Task.isCancelled, session.snapshot == snapshot else { return }
        loggedDays = Set(recent.map(\.day))
        log.writer = writer
        log.seed(day: snapshot.day, tiles: JournalQuickLogTile.tiles(from: items, active: active),
                 native: .init(answers: snapshot.answers, numeric: snapshot.numericAnswers),
                 imported: .init(answers: snapshot.importedAnswers, numeric: snapshot.importedNumeric),
                 earlier: JournalQuickLog.merged(native: earlier.native, imported: earlier.imported),
                 epoch: epoch)
    }

    /// Writes honour consent and the source check at the moment of the tap and again as each answer is stored, then
    /// refresh Coach's own copy of the day.
    private var writer: JournalQuickLogModel.Writer {
        let repository = repository
        let session = session
        let allowed: @MainActor () -> Bool = {
            session.snapshot?.sourceContext == repository.journalEntrySourceContext
                && session.access.canUseManualJournal
        }
        return .init(
            save: { day, write in
                guard allowed() else { return }
                switch write {
                case .answer(let question, let yes):
                    await repository.saveJournalAnswer(day: day, question: question, answeredYes: yes)
                case .amount(let question, let value):
                    await repository.saveJournalNumeric(day: day, question: question, value: value)
                }
            },
            clear: { day, question in
                guard allowed() else { return }
                await repository.clearJournalAnswer(day: day, question: question)
            },
            canWrite: allowed,
            didWrite: { changed() })
    }

    private func configureSession() {
        session.configure(coachEnabled: false, usesPersonalData: false, isPreview: false,
                          active: visible && scenePhase == .active)
    }

    private func changed() {
        // Runs after a run of taps has been stored.
        session.refresh()
        catalog.reloadFromDefaults()
        onChanged()
    }
}

/// A civil wake-day selection is explicit. Neither typed prose nor a later midnight changes this key.
/// "Day · Yesterday ⌄": a plain row that opens the month calendar, with the day named the way people say it. The key
/// is the morning the answers affect, so it reads as the day before (`JournalBehaviorDay`).
struct CoachJournalDayPicker: View {
    let day: String
    let onSelect: (String) -> Void
    @State private var choosing = false

    var body: some View {
        Button { choosing = true } label: {
            HStack(spacing: NoopMetrics.space2) {
                Text("Day").foregroundStyle(StrandPalette.textSecondary)
                Text(verbatim: "·").foregroundStyle(StrandPalette.textTertiary)
                Text(verbatim: JournalBehaviorDay.label(forStorageKey: day)).foregroundStyle(StrandPalette.textPrimary)
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
        .accessibilityValue(JournalBehaviorDay.label(forStorageKey: day))
        .accessibilityHint("Choose a different day to log")
        .accessibilityIdentifier("coach.journal.wakeDayPicker")
        .sheet(isPresented: $choosing) {
            DayCalendarSheet(selected: JournalBehaviorDay.behaviorDate(forStorageKey: day) ?? Date(), today: Date(),
                             daysWithData: []) { onSelect(JournalBehaviorDay.storageKey(forBehaviorDate: $0)) }
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
