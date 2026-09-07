import SwiftUI
import StrandDesign
import WhoopStore

/// One navigation stack for the whole journal task, including editor and settings destinations.
struct JournalExperienceView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            JournalExperienceHome()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .noopFocusedTask()
        }
        .tint(StrandPalette.journalAccent)
    }
}

private struct JournalExperienceHome: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var catalog = JournalCatalogStore()
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var configuration: JournalExperienceConfiguration?
    @State private var rows: [JournalEntry] = []
    @State private var history: [JournalEntry] = []
    @State private var failure: String?
    @State private var loadedDay: String?
    @State private var revision = 0
    @State private var generation = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    private var day: String { JournalExperiencePolicy.dayKey(selectedDate) }
    private var items: [JournalCatalogItem] { configuration?.activeItems ?? [] }
    private var answers: [String: JournalAnswer] { JournalExperienceStore.answers(rows) }
    private var completed: Int { items.filter { answers[$0.canonical] != nil }.count }
    private var quickItems: [JournalCatalogItem] {
        let quick = Set(configuration?.memberships.filter { $0.isActive && $0.isQuickAdd }.map(\.canonicalQuestion) ?? [])
        return Array(items.filter { quick.contains($0.canonical) }.prefix(6))
    }

    var body: some View {
        ExperienceScroll {
            dateNavigator
            if let failure {
                ExperienceMessage(title: "Journal could not load", message: failure,
                                  symbol: "exclamationmark.triangle", tint: StrandPalette.statusWarning)
                NoopButton("Retry", kind: .secondary, fullWidth: true) { revision += 1 }
            }
            if configuration != nil, loadedDay == day {
                checkInHero
                JournalMoodCheckIn(date: selectedDate)
                historySection
                if !quickItems.isEmpty { quickSection }
                if let stacks = configuration?.stacks, !stacks.isEmpty { stackSection(stacks) }
                NavigationLink {
                    JournalBehaviorEditor(catalog: catalog) { revision += 1 }
                } label: {
                    ExperienceMessage(title: "Make this journal yours", message: "Choose questions and arrange your quick entries.",
                                      symbol: "slider.horizontal.3", tint: StrandPalette.journalAccent)
                }
                .buttonStyle(.plain)
                Text("Answers are stored on this device. Your export and backup settings still apply.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            } else if failure == nil {
                ProgressView("Loading check-in…").frame(maxWidth: .infinity).padding(32)
            }
        }
        .navigationTitle("Journal")
        .task(id: "\(day)|\(revision)") { await load() }
        .refreshable { configuration = nil; await load() }
        .onAppear { configuration = nil; revision += 1 }
    }

    private var dateNavigator: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Morning of").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: 12) {
                Button { moveDay(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel("Previous morning")
                DatePicker("Morning date", selection: $selectedDate, in: ...tomorrow, displayedComponents: .date)
                    .labelsHidden().frame(maxWidth: .infinity)
                Button { moveDay(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(Calendar.current.isDate(selectedDate, inSameDayAs: tomorrow))
                    .accessibilityLabel("Next morning")
            }
            .buttonStyle(.plain)
            .foregroundStyle(StrandPalette.textPrimary)
            Text("Describe the day and night before this morning.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var checkInHero: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { progressRing; checkInTitle }
                    VStack(alignment: .leading, spacing: 16) { progressRing; checkInTitle }
                }
                if items.isEmpty {
                    NavigationLink { JournalBehaviorEditor(catalog: catalog) { revision += 1 } } label: {
                        Text("Choose journal questions").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                } else {
                    NavigationLink {
                        JournalDayEditor(date: selectedDate, catalog: catalog) { revision += 1 }
                    } label: {
                        Label(completed == 0 ? "Start check-in" : "Review check-in", systemImage: "arrow.right")
                    }
                    .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                }
            }
        }
    }
    private var progressRing: some View { ExperienceProgress(completed: completed, total: items.count) }
    private var checkInTitle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(items.isEmpty ? "Your questions, your pace" : completed == items.count ? "Check-in complete" : "A moment for your day")
                .font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text(items.isEmpty ? "Choose the habits you want to track." : "\(completed) of \(items.count) answered")
                .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
            Label(rows.isEmpty ? "No answers saved for this morning" : "Saved answers", systemImage: "checkmark.circle")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.journalAccent)
        }
    }

    private var historySection: some View {
        let dates = (0..<14).reversed().map { JournalExperiencePolicy.day(offset: $0, from: selectedDate) }
        let activeKeys = Set(items.map(\.canonical))
        let counts = Dictionary(grouping: history, by: \.day).mapValues { entries in
            entries.filter { activeKeys.contains($0.question) }.count
        }
        return PaperCard {
            VStack(alignment: .leading, spacing: 14) {
                ExperienceSectionHeading(title: "Recent mornings", detail: "Tap a date to review its answers")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 68 : 44), spacing: 6)], spacing: 10) {
                    ForEach(dates, id: \.self) { date in
                        let key = JournalExperiencePolicy.dayKey(date)
                        let count = counts[key, default: 0]
                        Button { selectedDate = date } label: {
                            VStack(spacing: 7) {
                                Text(date.formatted(.dateTime.day())).font(StrandFont.caption).monospacedDigit()
                                Image(systemName: count > 0 ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(count > 0 ? StrandPalette.journalAccent : StrandPalette.textTertiary)
                            }
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(key == day ? StrandPalette.inset : StrandPalette.card, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(date.formatted(date: .complete, time: .omitted)), \(count) answers")
                        .accessibilityAddTraits(key == day ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var quickSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExperienceSectionHeading(title: "Quick entries", detail: "Open a question to record or change its answer")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 240 : 145), spacing: 12)], spacing: 12) {
                ForEach(quickItems) { item in
                    NavigationLink {
                        JournalDayEditor(date: selectedDate, catalog: catalog, initialSearch: item.display) { revision += 1 }
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: answers[item.canonical] == nil ? "plus.circle" : "checkmark.circle.fill")
                                .font(StrandFont.title2).foregroundStyle(StrandPalette.journalAccent)
                            Text(item.display).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(answerLabel(answers[item.canonical])).font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading).padding(16)
                        .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func stackSection(_ stacks: [CoachingStack]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ExperienceSectionHeading(title: "Your routines")
            ForEach(stacks) { stack in
                NavigationLink { CoachingStackDetailView(stack: stack) { revision += 1 } } label: {
                    ExperienceMessage(title: stack.name, message: stack.isActive ? "Review and log this routine" : "Paused routine",
                                      symbol: "square.stack.3d.up", tint: StrandPalette.journalAccent)
                }.buttonStyle(.plain)
            }
        }
    }
    private var tomorrow: Date { JournalExperiencePolicy.day(offset: -1, from: Calendar.current.startOfDay(for: Date())) }
    private func moveDay(_ amount: Int) {
        selectedDate = min(tomorrow, Calendar.current.date(byAdding: .day, value: amount, to: selectedDate) ?? selectedDate)
    }
    private func answerLabel(_ answer: JournalAnswer?) -> String {
        switch answer {
        case .boolean(let yes): yes ? "Yes" : "No"
        case .number(let value): JournalNumberInput.format(value)
        case nil: "Not answered"
        }
    }
    @MainActor private func load() async {
        generation += 1
        let request = generation
        let date = selectedDate
        let key = JournalExperiencePolicy.dayKey(date)
        failure = nil
        do {
            let config: JournalExperienceConfiguration
            if let configuration { config = configuration }
            else { config = try await JournalExperienceStore.configuration(repo: repo, catalog: catalog) }
            let lower = JournalExperiencePolicy.dayKey(JournalExperiencePolicy.day(offset: 13, from: date))
            let recent = try await JournalExperienceStore.read(repo: repo, from: lower, to: key)
            try Task.checkCancellation()
            guard request == generation, day == key else { return }
            configuration = config
            rows = recent.filter { $0.day == key }
            history = recent
            loadedDay = key
        } catch is CancellationError { return }
        catch {
            guard request == generation, day == key else { return }
            failure = error.localizedDescription
        }
    }
}
