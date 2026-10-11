import StrandDesign
import SwiftUI

/// Receipts (every completed lift, newest first, by month) and Progress (the range's volume, totals and top lifts).
struct HistoryView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.liftFormat) private var format
  @Environment(\.locale) private var locale
  @EnvironmentObject private var store: LiftStore

  private let selectedSegment: Binding<LiftHistorySegment>?
  @State private var localSegment: LiftHistorySegment = .receipts
  @State private var selectedRange: LiftProgressRange = .twelveWeeks
  @State private var referenceNow = Date()
  @State private var showingExercisePicker = false
  @State private var selectedExerciseID: UUID?
  @State private var months: [LiftReceiptMonth] = []
  private let progressOnly: Bool

  init(selectedSegment: Binding<LiftHistorySegment>? = nil, progressOnly: Bool = false) {
    self.selectedSegment = selectedSegment
    self.progressOnly = progressOnly
  }

  private var activeSegment: LiftHistorySegment {
    progressOnly ? .progress : (selectedSegment?.wrappedValue ?? localSegment)
  }

  var body: some View {
    LiftPage(title: progressOnly ? "Progress" : "History", lazy: true) {
      if !progressOnly {
        SegmentedPillControl(LiftHistorySegment.allCases, selection: segmentSelection) { $0.label }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, NoopMetrics.space2)
      }
      if activeSegment == .receipts {
        receipts
      } else {
        LiftProgressOverview(
          range: selectedRange,
          referenceNow: referenceNow,
          onSelectRange: selectRange,
          onFindExercise: { showingExercisePicker = true }
        )
      }
    }
    .sheet(isPresented: $showingExercisePicker) {
      NavigationStack {
        ExerciseLibraryView { exercise in
          showingExercisePicker = false
          selectedExerciseID = exercise.id
        }
        .environmentObject(store)
      }
    }
    .navigationDestination(isPresented: exerciseDestination) {
      if let selectedExerciseID {
        ExerciseProgressView(exerciseID: selectedExerciseID)
          .environmentObject(store)
      }
    }
    .liftQAScene("exercise", "exercise-info") {
      selectedExerciseID = store.progressSnapshot(for: selectedRange, now: referenceNow, calendar: .current)
        .topExercises.first?.exerciseID ?? store.preferredExerciseID
    }
    .onAppear(perform: refreshMonths)
    .onChange(of: store.sessions) {
      refreshMonths()
      guard activeSegment == .progress else { return }
      referenceNow = Date()
    }
    .onChange(of: scenePhase) {
      guard scenePhase == .active, activeSegment == .progress else { return }
      referenceNow = Date()
    }
    .onChange(of: activeSegment) { _, segment in
      guard segment == .progress else { return }
      referenceNow = Date()
    }
  }

  private var segmentSelection: Binding<LiftHistorySegment> {
    Binding(get: { activeSegment }, set: { setSegment($0) })
  }

  // MARK: Receipts

  @ViewBuilder
  private var receipts: some View {
    if months.isEmpty {
      LiftMessage(
        symbol: "list.bullet.rectangle",
        title: "No receipts yet",
        message: "Finish a workout and its receipt shows up here."
      )
    } else {
      ForEach(Array(months.enumerated()), id: \.element.id) { index, month in
        if index > 0 { FlatSectionSeparator() }
        LiftDataSection(
          title: month.title,
          trailing: .text(LiftFormat.workoutCount(month.sessions.count))
        ) {
          LiftRowList(items: month.sessions) { session, _ in
            NavigationLink {
              CompletedReceiptView(session: session, presentation: .settled)
            } label: {
              receiptRow(session)
            }
            .buttonStyle(FlatRowPressStyle())
          }
        }
      }
    }
  }

  private func receiptRow(_ session: LiftSession) -> some View {
    let seconds = (session.endedAt ?? session.startedAt).timeIntervalSince(session.startedAt)
    let sets = session.workingSets.count
    var facts: [String] = []
    if sets > 0 { facts.append(LiftFormat.setCount(sets)) }
    if seconds >= 60 { facts.append(format.shortDuration(seconds)) }
    let when = LiftFormat.facts([format.weekdayDay(session.startedAt), format.time(session.startedAt)])
    return LiftListRow(
      title: session.title,
      details: [when, LiftFormat.facts(facts)].filter { !$0.isEmpty },
      value: format.volume(pounds: session.totalVolume),
      showsChevron: true
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(format.dayTime(session.startedAt)), \(session.title), \(format.spokenWeight(pounds: session.totalVolume))"
    )
    .accessibilityHint("Opens completed workout receipt")
  }

  private func refreshMonths() {
    months = LiftReceiptMonth.group(store.sessions, calendar: .current, locale: locale)
  }

  // MARK: State

  private func selectRange(_ range: LiftProgressRange) {
    referenceNow = Date()
    withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.compose) {
      selectedRange = range
    }
  }

  private func setSegment(_ segment: LiftHistorySegment) {
    withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.compose) {
      if let selectedSegment {
        selectedSegment.wrappedValue = segment
      } else {
        localSegment = segment
      }
      if segment == .progress {
        referenceNow = Date()
      }
    }
  }

  private var exerciseDestination: Binding<Bool> {
    Binding(
      get: { selectedExerciseID != nil },
      set: { presented in
        if !presented { selectedExerciseID = nil }
      }
    )
  }
}

/// The completed lifts of one month, newest first.
struct LiftReceiptMonth: Identifiable, Equatable {
  let id: Date
  let title: String
  let sessions: [LiftSession]

  /// Completed sessions grouped by the month they started in, newest month and newest lift first.
  nonisolated static func group(_ sessions: [LiftSession], calendar: Calendar, locale: Locale) -> [LiftReceiptMonth] {
    let completed = sessions
      .filter { $0.endedAt != nil }
      .sorted { left, right in
        if left.startedAt != right.startedAt { return left.startedAt > right.startedAt }
        if left.endedAt != right.endedAt {
          return (left.endedAt ?? left.startedAt) > (right.endedAt ?? right.startedAt)
        }
        return left.id.uuidString > right.id.uuidString
      }
    var order: [Date] = []
    var buckets: [Date: [LiftSession]] = [:]
    for session in completed {
      let start = calendar.dateInterval(of: .month, for: session.startedAt)?.start ?? calendar.startOfDay(for: session.startedAt)
      if buckets[start] == nil { order.append(start) }
      buckets[start, default: []].append(session)
    }
    return order.map { start in
      LiftReceiptMonth(
        id: start,
        title: start.formatted(.dateTime.month(.wide).year().locale(locale)),
        sessions: buckets[start] ?? []
      )
    }
  }
}

// MARK: - Progress

/// The range's weekly volume (touch and hold the chart to read a week), its totals and its top lifts. The week under the
/// finger lives here, so a scrub redraws this section and nothing above it.
private struct LiftProgressOverview: View {
  let range: LiftProgressRange
  let referenceNow: Date
  let onSelectRange: (LiftProgressRange) -> Void
  let onFindExercise: () -> Void

  @EnvironmentObject private var store: LiftStore
  @Environment(\.liftFormat) private var format
  @State private var snapshot: LiftProgressSnapshot?
  @State private var selection: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SegmentedPillControl(LiftProgressRange.allCases, selection: rangeBinding) { $0.label }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, NoopMetrics.space2)
      if let snapshot {
        volumeSection(snapshot)
        FlatSectionSeparator()
        totalsSection(snapshot.metrics)
        FlatSectionSeparator()
        topSection(snapshot)
      }
    }
    .onAppear { refresh() }
    .onChange(of: range) { refresh() }
    .onChange(of: referenceNow) { refresh() }
    .onChange(of: store.sessions) { refresh() }
  }

  private var rangeBinding: Binding<LiftProgressRange> {
    Binding(get: { range }, set: { onSelectRange($0) })
  }

  private func refresh() {
    selection = nil
    snapshot = store.progressSnapshot(for: range, now: referenceNow, calendar: .current)
  }

  // MARK: Volume

  private func volumeSection(_ snapshot: LiftProgressSnapshot) -> some View {
    let weeks = snapshot.weeklyVolume
    let shown = selection.flatMap { weeks.indices.contains($0) ? weeks[$0] : nil }
    let pounds = shown?.volume ?? snapshot.metrics.workDone
    let parts = format.parts(pounds: pounds)
    let caption: String = {
      guard let shown else { return range.caption }
      return LiftFormat.facts([
        String(localized: "Week of \(format.day(shown.weekStart))"),
        LiftFormat.workoutCount(shown.workoutCount),
      ])
    }()
    return LiftFlatSection("Volume", systemImage: "chart.bar.fill") {
      VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
        HeroValue(
          value: pounds > 0 ? parts.number : LiftFormat.missing,
          unit: pounds > 0 ? parts.unit : nil,
          caption: caption,
          captionPlacement: .below
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shown == nil ? "Work done" : "Weekly volume")
        .accessibilityValue(
          LiftFormat.facts([format.spokenWeight(pounds: pounds), caption]))
        if weeks.isEmpty {
          LiftNote(text: "No volume in this range.")
        } else {
          ScrubChart(
            points: weeks.map { ScrubChartPoint(date: $0.weekStart, value: $0.volume) },
            domain: snapshot.window.startInclusive...snapshot.window.displayEndExclusive,
            style: .bars,
            tint: .workout,
            selection: $selection,
            calendar: .current,
            locale: format.locale,
            summary: String(localized: "Weekly training volume, \(weeks.count) weeks, \(format.spokenWeight(pounds: snapshot.metrics.workDone)) total"),
            spokenValue: { point in
              let week = weeks.first { $0.weekStart == point.date }
              return LiftFormat.facts([
                String(localized: "Week of \(format.day(point.date))"),
                format.spokenWeight(pounds: point.value),
                week.map { LiftFormat.workoutCount($0.workoutCount) } ?? "",
              ])
            }
          )
        }
      }
    }
  }

  // MARK: Totals

  private func totalsSection(_ metrics: LiftProgressMetrics) -> some View {
    LiftFlatSection("Totals", systemImage: "sum") {
      VStack(alignment: .leading, spacing: FlatSectionRhythm.rowAir) {
        FactStrip(facts: [
          .init("Workouts", value: metrics.workouts.formatted()),
          .init("Sets", value: metrics.workingSets.formatted()),
          .init("Exercises", value: metrics.exerciseCount.formatted()),
        ])
        FactStrip(facts: [
          .init(
            "Avg duration",
            value: metrics.workouts > 0 ? format.shortDuration(metrics.averageDuration) : LiftFormat.missing,
            spokenValue: metrics.workouts > 0 ? format.spokenDuration(metrics.averageDuration) : nil),
          .init(
            "Consistency",
            value: metrics.workouts > 0
              ? (metrics.consistencyPercent / 100).formatted(.percent.precision(.fractionLength(0)).locale(format.locale))
              : LiftFormat.missing),
        ])
      }
    }
  }

  // MARK: Top lifts

  private func topSection(_ snapshot: LiftProgressSnapshot) -> some View {
    LiftFlatSection("Top exercises", systemImage: "trophy", contentSpacing: 0) {
      if snapshot.topExercises.isEmpty {
        LiftNote(text: "No volume in this range.").padding(.vertical, NoopMetrics.space2)
      } else {
        LiftRowList(items: snapshot.topExercises, separatorInset: 28 + NoopMetrics.space3) { exercise, index in
          NavigationLink {
            ExerciseProgressView(exerciseID: exercise.exerciseID)
              .environmentObject(store)
          } label: {
            LiftListRow(
              title: exercise.name.liftDisplayName,
              details: [String(localized: "Total training volume")],
              value: format.volume(pounds: exercise.volume),
              showsChevron: true,
              leading: {
                Text((index + 1).formatted(.number.locale(format.locale)))
                  .font(StrandFont.number(15))
                  .foregroundStyle(StrandPalette.textTertiary)
                  .frame(width: 28, alignment: .leading)
              }
            )
          }
          .buttonStyle(FlatRowPressStyle())
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("\(exercise.name.liftDisplayName), \(format.spokenWeight(pounds: exercise.volume))")
          .accessibilityHint("Opens exercise progress")
        }
      }
      ChipRow {
        WidgetChipButton(
          title: "Find an exercise", systemImage: "magnifyingglass", accessibilityLabel: "Find an exercise",
          accessibilityHint: "Searches the exercise library", action: onFindExercise)
      }
      .padding(.top, NoopMetrics.space3)
    }
  }
}
