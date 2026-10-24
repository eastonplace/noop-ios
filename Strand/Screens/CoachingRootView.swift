import SwiftUI
import StrandDesign
import WhoopStore

/// The Journal: one flat page that is the whole daily check-in. It opens on Yesterday ("How was yesterday?"), the day
/// people look back on, and every day of the last two weeks is a tap away. Mood, then one grid of what happened that
/// saves the moment it is touched, then a saved note, the last two weeks and the links. There is no separate check-in
/// screen or Save button to forget.
///
/// It owns no persistence of its own: every answer is written through Repository's journal API under the immutable
/// catalog canonicals (the native "noop-journal" source), so What Moves You and Heads-Up read exactly what was
/// tapped. An answer an import already brought for the day counts and shows; a tap replaces it. Typed or dictated
/// notes keep their explicit reviewed save in the composer sheet.
struct CoachingRootView: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var catalog = JournalCatalogStore()
    @StateObject private var log = JournalQuickLogModel()

    @State private var importedQuestions: [String] = []
    @State private var catalogRevision = 0
    /// The day the page is on, as the journal stores it: the morning the answers affect. The page opens on Yesterday,
    /// which is this morning's key.
    @State private var dayKey = JournalBehaviorDay.yesterdayStorageKey()
    @State private var todayKey = Repository.localDayKey(Date())
    @State private var mood: Int?
    @State private var note = ""
    /// The day the mood and note above were read for. Taps wait until it matches `dayKey`, so a quick switch of
    /// day never writes one day's answers into another.
    @State private var loadedDay: String?
    @State private var loadedSourceContext: String?
    /// Days with at least one answer (imported or tapped), for the dots and the streak.
    @State private var loggedDays: Set<String> = []
    @State private var stacks: [CoachingStack] = []
    @State private var stackSubtitle: String?
    @State private var loaded = false
    /// A typed or dictated note. It stays transient until its sheet's reviewed Save.
    @State private var composingEntry: JournalEntryPresentation?
    #if DEBUG && os(iOS)
    @State private var qaComposeOpened = false
    #endif

    /// `day` is a storage key (see `JournalBehaviorDay`): `todayStorageKey()` opens on Today, the evening's
    /// behaviours. Nothing, or a day that cannot be picked, opens on Yesterday.
    init(day: String? = nil) {
        let open = day.flatMap { JournalBehaviorDay.isSelectable($0) ? $0 : nil }
        _dayKey = State(initialValue: open ?? JournalBehaviorDay.yesterdayStorageKey())
    }

    private var isCurrentSourceLoaded: Bool {
        !repo.verifiedExternalSurfaceFenced && loadedSourceContext == repo.journalEntrySourceContext
    }
    private var isCurrentDayLoaded: Bool { loadedDay == dayKey && isCurrentSourceLoaded }
    private var words: JournalBehaviorDay.Words { JournalBehaviorDay.words(forStorageKey: dayKey, today: todayKey) }
    private var loadKey: String {
        "\(repo.refreshSeq)|\(repo.journalRevision)|\(repo.journalEntrySourceContext)|\(repo.verifiedExternalSurfaceFenced)|\(dayKey)|\(catalogRevision)"
    }

    var body: some View {
        NavigationStack {
            ScreenScaffold(title: "Journal") {
                if loaded && isCurrentSourceLoaded {
                    VStack(alignment: .leading, spacing: 0) {
                        JournalQuickLogProgress(model: log) {
                            CoachJournalDayPicker(day: dayKey, onSelect: select(day:))
                        }
                        FlatSectionSeparator(above: NoopMetrics.space2)
                        dictationRow
                        FlatSectionSeparator(above: NoopMetrics.space1)
                        JournalMoodRow(mood: moodBinding, title: words.moodTitle)
                            .disabled(!isCurrentDayLoaded)
                        FlatSectionSeparator()
                        JournalQuickLogSection(model: log, dayKey: dayKey, words: words)
                        if !note.isEmpty {
                            FlatSectionSeparator()
                            noteSection
                        }
                        FlatSectionSeparator()
                        historySection
                        FlatSectionSeparator(below: NoopMetrics.space1)
                        linksSection
                        privacyLine
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("journal.home")
                } else {
                    ComingSoon(what: "Loading your check-in…", symbol: "checkmark.circle")
                }
            }
            .task(id: loadKey) { await load() }
            #if os(iOS)
            // The scaffold header is this screen's only chrome; the stack's own bar would stack a second
            // one above it.
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .tint(StrandPalette.journalAccent)
        .onReceive(NotificationCenter.default.publisher(for: .init("noop.notificationJournalDidChange"))) { _ in
            catalogRevision &+= 1
        }
        .sheet(item: $composingEntry) { entry in
            JournalEntryComposer(catalog: catalog, presentation: entry,
                                 importedQuestions: importedQuestions, currentDay: entry.day,
                                 onSaved: { Task { await load() } })
                .environmentObject(repo)
        }
        #if DEBUG && os(iOS)
        // `--noop-qa-route journal-compose`: open the composer over this screen once it has loaded.
        .onChange(of: loaded) { _, isLoaded in
            guard isLoaded, QARoute.requested == .journalCompose, !qaComposeOpened else { return }
            qaComposeOpened = true
            composingEntry = JournalEntryPresentation(day: dayKey, sourceIdentity: repo.journalEntrySourceIdentity)
        }
        #endif
    }

    // MARK: Day

    /// Clears the old day before the new one loads, so nothing from one day shows (or saves) as the other.
    private func select(day: String) {
        guard day != dayKey, JournalBehaviorDay.isSelectable(day, today: Repository.localDayKey(Date())) else { return }
        loadedDay = nil
        mood = nil
        note = ""
        log.reset()
        dayKey = day
    }

    // MARK: Note

    private var dictationRow: some View {
        Button { compose() } label: {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: "mic")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.journalAccent)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: words.dictationTitle)
                        .font(StrandFont.body.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("“Two coffees, felt stressed, slept badly”")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: NoopMetrics.space2)
                Image(systemName: "chevron.right")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(FlatRowPressStyle())
        .disabled(!isCurrentDayLoaded)
        .accessibilityHint("Opens a note you can type or dictate")
        .accessibilityIdentifier("journal-compose-entry")
    }

    private func compose() {
        guard isCurrentDayLoaded else { return }
        composingEntry = JournalEntryPresentation(day: dayKey, sourceIdentity: repo.journalEntrySourceIdentity)
    }

    /// Only a saved note appears here; writing one starts from the row at the top.
    private var noteSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            SectionEyebrow("Note", tint: .journal)
            Text(verbatim: note)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("journal.note")
            Button { compose() } label: {
                Text("Edit note")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.journalAccent)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FlatRowPressStyle())
            .accessibilityIdentifier("journal.editNote")
        }
    }

    // MARK: Mood

    private var moodBinding: Binding<Int?> {
        Binding(
            get: { mood },
            set: { next in
                guard isCurrentDayLoaded else { return }
                let day = dayKey
                mood = next
                guard let next else { return }
                Task { await repo.saveMood(day: day, value: next) }
            }
        )
    }

    // MARK: The last two weeks

    /// The selected day counts as logged as soon as it has an answer, before anything reloads.
    private var loggedNow: Set<String> {
        JournalQuickLog.loggedDays(loggedDays, day: dayKey,
                                   values: log.dayKey == dayKey && log.sourceContext == repo.journalEntrySourceContext
                                       ? log.effective : nil)
    }

    private var historySection: some View {
        let logged = loggedNow
        let todayStorage = JournalBehaviorDay.todayStorageKey(today: todayKey)
        let keys = JournalBehaviorDay.window(today: todayKey,
                                             includesToday: logged.contains(todayStorage) || dayKey == todayStorage)
        let streak = JournalBehaviorDay.currentStreak(logged: logged, today: todayKey)
        let dots = keys.map { key in
            JournalDayDots.Dot(
                id: key, isLogged: logged.contains(key),
                accessibilityLabel: JournalBehaviorDay.label(forStorageKey: key, today: todayKey)
                    + ", " + (logged.contains(key) ? String(localized: "logged") : String(localized: "not logged")))
        }
        return VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            SectionEyebrow("Last 2 weeks", tint: .journal, trailing: streakTrailing(streak))
            JournalDayDots(
                dots: dots, selected: dayKey,
                startLabel: keys.first.map { JournalBehaviorDay.shortDate(forStorageKey: $0) } ?? "",
                endLabel: keys.last.map { JournalBehaviorDay.label(forStorageKey: $0, today: todayKey) } ?? "",
                hint: String(localized: "Tap a day to fill it in"),
                onSelect: select(day:))
        }
    }

    private func streakTrailing(_ streak: Int) -> EyebrowTrailing {
        guard streak > 1 else { return .none }
        return .custom(AnyView(
            Text("\(streak)-day streak")
                .font(StrandFont.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.journalAccent)
        ))
    }

    // MARK: Links

    private var linksSection: some View {
        VStack(spacing: 0) {
            NavigationLink { CoachingBehaviorSettingsView() } label: {
                JournalLinkRow(title: "Edit questions",
                               subtitle: "Turn questions on or off, rename them, add your own",
                               icon: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("journal.editQuestions")
            if let stack = stacks.first {
                FlatRowSeparator(leadingInset: 36)
                NavigationLink { CoachingStackDetailView(stack: stack, day: dayKey) { Task { await load() } } } label: {
                    JournalLinkRow(verbatimTitle: stack.name, verbatimSubtitle: stackSubtitle, icon: "square.stack.3d.up")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("journal.stack")
            }
        }
    }

    private var privacyLine: some View {
        Label {
            Text("Stays on this iPhone. Heads-Up and Coach use it to spot patterns.")
        } icon: {
            Image(systemName: "lock.fill")
        }
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textTertiary)
        .padding(.top, NoopMetrics.space4)
        .padding(.bottom, NoopMetrics.space6)
    }

    // MARK: Load

    @MainActor private func load() async {
        catalog.reloadFromDefaults()
        let catalogItems = catalog.items
        let sourceIdentity = repo.journalEntrySourceIdentity
        guard let sourceContext = try? await repo.journalEntryContext() else { return }
        let day = dayKey
        let epoch = log.changeEpoch
        let earlierDay = JournalBehaviorDay.shifted(day, by: -1) ?? day
        let imported = await repo.importedJournalEntries()
        let all = await repo.journalEntries()
        let questions = Array(Set(imported.map(\.question))).sorted()
        let resolved = catalog.resolvedItems(imported: questions)
        let active = await repo.activeCoachingQuestions(for: resolved)
        var loadedStacks: [CoachingStack] = []
        var subtitle: String?
        if let store = await repo.storeHandle() {
            let magnesium = resolved.first { JournalCatalogStore.norm($0.canonical).contains("magnesium") }
            let sauna = resolved.first { JournalCatalogStore.norm($0.canonical).contains("sauna") }
            let preset = CoachingStack(id: "evening-recovery", name: "Evening recovery",
                                       description: "A simple wind-down routine for the behaviors you already track.",
                                       scheduleLabel: "Daily", isActive: true, notes: nil, sortIndex: 0)
            let presetItems = [
                magnesium.map { CoachingStackItem(stackId: preset.id, canonicalQuestion: $0.canonical,
                                                  dose: 1, unit: "dose", sortIndex: 0) },
                sauna.map { CoachingStackItem(stackId: preset.id, canonicalQuestion: $0.canonical,
                                              dose: 10, unit: "min", sortIndex: 1) },
            ].compactMap { $0 }
            if !presetItems.isEmpty {
                _ = try? await store.ensureDefaultCoachingStack(preset, items: presetItems)
            }
            loadedStacks = (try? await store.coachingStacks()) ?? []
            if let first = loadedStacks.first {
                let items = (try? await store.coachingStackItems(stackId: first.id)) ?? []
                let names = items.map { item in
                    resolved.first { $0.canonical == item.canonicalQuestion }.map(coachingShortDisplayName(for:))
                        ?? item.canonicalQuestion
                }
                subtitle = JournalQuickLog.stackSubtitle(names: names)
            }
        }
        let dayValues = await repo.journalDayValues(day: day)
        let earlierValues = await repo.journalDayValues(day: earlierDay)
        var details = JournalEntryDayDetails(note: "", mood: nil)
        if let read = try? await repo.journalDayDetails(day: day, sourceContext: sourceContext) {
            details = read
        } else {
            details.mood = await repo.mood(day: day)
        }
        // The person may have switched day while this was reading; the newer load owns the page.
        guard !Task.isCancelled, day == dayKey, catalog.items == catalogItems,
              !repo.verifiedExternalSurfaceFenced, sourceIdentity == repo.journalEntrySourceIdentity,
              sourceContext == repo.journalEntrySourceContext else { return }
        todayKey = Repository.localDayKey(Date())
        importedQuestions = questions
        stacks = loadedStacks
        stackSubtitle = subtitle
        loggedDays = Set(all.map(\.day))
        note = details.note.trimmingCharacters(in: .whitespacesAndNewlines)
        mood = details.mood
        log.seed(day: day, sourceContext: sourceContext,
                 tiles: JournalQuickLogTile.tiles(from: resolved, active: active),
                 native: dayValues.native, imported: dayValues.imported,
                 earlier: JournalQuickLog.merged(native: earlierValues.native, imported: earlierValues.imported),
                 epoch: epoch)
        log.writer = writer
        loadedDay = day
        loadedSourceContext = sourceContext
        loaded = true
    }

    /// Every tap uses the immutable day and source captured when its answers loaded. Durable revisions reconcile
    /// revisited days; the model keeps those reads from replacing answers still being saved.
    private var writer: JournalQuickLogModel.Writer {
        let repo = repo
        let sourceContext = repo.journalEntrySourceContext
        let allowed: @MainActor () -> Bool = {
            !repo.verifiedExternalSurfaceFenced && sourceContext == repo.journalEntrySourceContext
        }
        return .init(
            save: { day, write in
                guard allowed() else { return }
                switch write {
                case .answer(let question, let yes):
                    await repo.saveJournalAnswer(day: day, question: question, answeredYes: yes,
                                                 expectedSourceContext: sourceContext)
                case .amount(let question, let value):
                    await repo.saveJournalNumeric(day: day, question: question, value: value,
                                                  expectedSourceContext: sourceContext)
                }
            },
            clear: { day, question in
                guard allowed() else { return }
                await repo.clearJournalAnswer(day: day, question: question, expectedSourceContext: sourceContext)
            },
            canWrite: allowed,
            didWrite: {})
    }
}

/// A plain row that opens another screen: a bare symbol, a title over one quiet line, a chevron.
struct JournalLinkRow: View {
    private let title: Text
    private let subtitle: Text?
    private let icon: String

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, icon: String) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.icon = icon
    }

    /// A title and subtitle that are data (a stack's own name, a line built from its items).
    init(verbatimTitle: String, verbatimSubtitle: String?, icon: String) {
        self.title = Text(verbatim: verbatimTitle)
        self.subtitle = verbatimSubtitle.map { Text(verbatim: $0) }
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: icon)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.journalAccent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title.font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                if let subtitle {
                    subtitle.font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: NoopMetrics.space2)
            Image(systemName: "chevron.right")
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}
