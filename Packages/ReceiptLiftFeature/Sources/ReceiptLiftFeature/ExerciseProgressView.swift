import StrandDesign
import SwiftUI

/// One exercise: its best set, how to do it, its progress over time and the sets behind it.
struct ExerciseProgressView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.liftScreenRole) private var inheritedRole
  @Environment(\.liftFormat) private var format
  @Environment(\.dynamicTypeSize) private var typeSize
  @EnvironmentObject private var store: LiftStore

  let exerciseID: UUID
  /// True when this view is the root of its own modal (a sheet), so the header closes it instead of popping.
  private let closesModal: Bool
  @State private var selectedMode: LiftExerciseProgressMode = .strength
  @State private var referenceNow = Date()
  @State private var selectedRange: LiftProgressRange = .twelveWeeks
  @State private var showsInformation = false
  @State private var snapshot: LiftExerciseProgressSnapshot?

  init(exerciseID: UUID, showsInformation: Bool = false, closesModal: Bool = false) {
    self.exerciseID = exerciseID
    self.closesModal = closesModal
    _showsInformation = State(initialValue: showsInformation)
  }

  private var exercise: LiftExercise? {
    store.exercise(for: exerciseID)
  }

  var body: some View {
    LiftPage(
      title: LocalizedStringKey(exercise?.name.liftDisplayName ?? String(localized: "Exercise not found")),
      // The title row has one line for this; at the largest sizes the facts move into the page, where they can wrap.
      context: typeSize.isAccessibilitySize ? nil : exercise.map(Self.facts),
      lazy: true,
      bottomPadding: NoopMetrics.space6
    ) {
      if let exercise {
        header(exercise)
        FlatSectionSeparator()
        informationSection(exercise)
        FlatSectionSeparator()
        ExerciseProgressChartSection(
          exercise: exercise,
          points: snapshot?.points ?? [],
          range: $selectedRange,
          mode: $selectedMode,
          referenceNow: referenceNow
        )
        FlatSectionSeparator()
        recentSetsSection(exercise)
      } else {
        LiftMessage(
          symbol: "questionmark.circle",
          title: "Exercise not found",
          message: "This local exercise is no longer available. Return to history and choose another exercise."
        )
      }
    }
    .environment(\.liftScreenRole, closesModal ? .sheet : inheritedRole)
    .onAppear {
      referenceNow = Date()
      refresh()
    }
    .onChange(of: store.sessions) { refresh() }
    .liftQAScene("exercise-info") { showsInformation = true }
  }

  private func refresh() {
    snapshot = LiftProgressMath.exerciseProgressSnapshot(
      sessions: store.sessions,
      exerciseID: exerciseID,
      now: referenceNow,
      calendar: .current
    )
  }

  // MARK: Header

  private static func facts(_ exercise: LiftExercise) -> String {
    LiftFormat.facts([exercise.muscleGroup, exercise.equipment]).liftDisplayName
  }

  private func header(_ exercise: LiftExercise) -> some View {
    let best = snapshot?.bestSet
    let oneRepMax = best.flatMap { $0.weight > 0 ? $0.estimatedOneRepMax : nil }
    let parts = oneRepMax.map { format.parts(pounds: $0) }
    return LiftFlatSection("Est. 1RM", systemImage: "scalemass.fill") {
      VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
        HStack(alignment: .center, spacing: NoopMetrics.space4) {
          Button { toggleInformation() } label: {
            LiftExerciseThumb(exercise: exercise, size: 84)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Show \(exercise.name) photo and muscles")
          HeroValue(
            value: parts?.number ?? LiftFormat.missing,
            unit: parts?.unit,
            caption: best.map { String(localized: "Best set · \(setLabel($0, exercise: exercise))") },
            captionPlacement: .below
          )
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Estimated one-rep max")
          .accessibilityValue(
            oneRepMax.map { format.spokenWeight(pounds: $0) } ?? String(localized: "No data"))
        }
        if typeSize.isAccessibilitySize {
          Text(verbatim: Self.facts(exercise))
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if LiftStore.prDetectionEnabled, let record = snapshot?.latestPersonalRecord,
           !Self.repeats(record, oneRepMax: oneRepMax) {
          LiftPRPayoffView(record: record)
        }
      }
    }
  }

  /// An estimated-1RM record that is the very figure the header already leads with says nothing new.
  private static func repeats(_ record: LiftPersonalRecord, oneRepMax: Double?) -> Bool {
    guard record.kind == .estimatedOneRepMax, let oneRepMax else { return false }
    return abs(record.value - oneRepMax) < 0.05
  }

  private func setLabel(_ set: LiftSet, exercise: LiftExercise) -> String {
    String(localized: "\(format.load(pounds: set.weight, for: exercise)) × \(set.reps)")
  }

  // MARK: Information

  private func informationSection(_ exercise: LiftExercise) -> some View {
    LiftFlatSection("Exercise", systemImage: "info.circle", contentSpacing: 0) {
      Button { toggleInformation() } label: {
        HStack(spacing: NoopMetrics.space3) {
          Text("Photo, muscles & instructions")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: NoopMetrics.space2)
          Image(systemName: "chevron.down")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(StrandPalette.textTertiary)
            .rotationEffect(.degrees(showsInformation ? 180 : 0))
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(FlatRowPressStyle())
      .accessibilityValue(showsInformation ? Text("Expanded") : Text("Collapsed"))
      .accessibilityHint("Shows the exercise photo, muscles and instructions")
      if showsInformation {
        ExerciseInformationView(exercise: exercise)
          .padding(.top, NoopMetrics.space2)
          .transition(.opacity)
      }
    }
  }

  private func toggleInformation() {
    withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.surface) { showsInformation.toggle() }
  }

  // MARK: Recent sets

  private func recentSetsSection(_ exercise: LiftExercise) -> some View {
    let rows = snapshot?.recentSets ?? []
    return LiftFlatSection("Recent sets", systemImage: "list.bullet", contentSpacing: 0) {
      if rows.isEmpty {
        LiftNote(text: "No working sets yet.").padding(.vertical, NoopMetrics.space2)
      } else {
        LiftRowList(items: rows) { row, _ in
          recentSetRow(row, exercise: exercise, personalRecords: snapshot?.historicalPersonalRecords)
        }
      }
    }
  }

  private func recentSetRow(
    _ row: LiftRecentSetRow,
    exercise: LiftExercise,
    personalRecords: LiftHistoricalPRLedger?
  ) -> some View {
    let personalRecord = LiftStore.prDetectionEnabled ? personalRecords?[row.set.id] : nil
    let set = row.set
    let load = String(localized: "\(format.load(pounds: set.weight, for: exercise)) × \(set.reps)")
    let rpe = set.rpe.formatted(.number.precision(.fractionLength(1)).locale(format.locale))
    var details = [
      LiftFormat.facts([String(localized: "Set \(set.setNumber)"), String(localized: "RPE \(rpe)")]),
      LiftFormat.facts([
        String(localized: "Volume \(format.volume(pounds: set.volume))"),
        String(localized: "Est. 1RM \(format.measured(pounds: set.estimatedOneRepMax))"),
      ]),
    ]
    if !set.notes.isEmpty { details.append(set.notes) }
    return NavigationLink {
      CompletedReceiptView(session: row.session, presentation: .settled)
    } label: {
      LiftListRow(
        title: format.dayYear(set.completedAt),
        details: details,
        value: load,
        showsChevron: true,
        leading: { EmptyView() },
        accessory: { if let personalRecord { LiftPRBadge(record: personalRecord) } }
      )
    }
    .buttonStyle(FlatRowPressStyle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      LiftFormat.facts([
        format.dayYear(set.completedAt),
        String(localized: "\(format.spokenLoad(pounds: set.weight, for: exercise)) by \(LiftFormat.repCount(set.reps))"),
        personalRecord == nil ? "" : String(localized: "personal record"),
      ])
    )
    .accessibilityHint("Opens the parent workout receipt")
  }
}

// MARK: - Chart

/// The mode and range controls, the reading under the finger and the chart. The reading lives here, so a scrub redraws
/// this section and nothing else on the page.
private struct ExerciseProgressChartSection: View {
  let exercise: LiftExercise
  let points: [VolumePoint]
  @Binding var range: LiftProgressRange
  @Binding var mode: LiftExerciseProgressMode
  let referenceNow: Date

  @EnvironmentObject private var store: LiftStore
  @Environment(\.liftFormat) private var format
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var selection: Int?

  var body: some View {
    let window = LiftProgressMath.window(for: range, sessions: store.sessions, now: referenceNow, calendar: .current)
    let visible = visiblePoints(window: window)
    return LiftFlatSection("Progress", systemImage: "chart.xyaxis.line") {
      VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
        controls
        if visible.isEmpty {
          emptyState
        } else {
          reading(of: shownPoint(in: visible))
          ScrubChart(
            points: visible.map { ScrubChartPoint(date: $0.date, value: chartValue($0)) },
            domain: window.startInclusive...max(window.endInclusive, window.startInclusive.addingTimeInterval(86_400)),
            style: mode == .volume ? .bars : .line,
            tint: .workout,
            selection: $selection,
            calendar: .current,
            locale: format.locale,
            summary: summary(of: visible),
            spokenValue: { point in
              guard let match = visible.first(where: { $0.date == point.date }) else { return "" }
              return LiftFormat.facts([format.dayYear(match.date), spokenValue(match)])
            }
          )
          .id(mode)
          Text("Completed workouts only. Volume includes warm-ups; strength and reps use working sets. Estimated 1RM uses weight × (1 + reps / 30).")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .onChange(of: mode) { selection = nil }
    .onChange(of: range) { selection = nil }
  }

  // MARK: Controls

  private var controls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: NoopMetrics.space3) {
        modeMenu
        rangeControl.fixedSize(horizontal: true, vertical: false)
      }
      VStack(alignment: .leading, spacing: NoopMetrics.space3) {
        modeMenu
        rangeControl
      }
    }
  }

  private var modeMenu: some View {
    Menu {
      Picker("Metric", selection: modeBinding) {
        ForEach(LiftExerciseProgressMode.allCases) { Text(verbatim: $0.label).tag($0) }
      }
    } label: {
      TrendsMenuChipLabel(title: mode.label, systemImage: "figure.strengthtraining.traditional", tint: DomainTint.workout.accent)
        .frame(minHeight: 44)
    }
    .accessibilityLabel("Metric")
    .accessibilityValue(Text(verbatim: mode.label))
  }

  private var rangeControl: some View {
    SegmentedPillControl(LiftProgressRange.allCases, selection: $range) { $0.label }
  }

  private var modeBinding: Binding<LiftExerciseProgressMode> {
    Binding(
      get: { mode },
      set: { newMode in
        withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.compose) { mode = newMode }
      }
    )
  }

  // MARK: Reading

  private func shownPoint(in visible: [VolumePoint]) -> VolumePoint? {
    selection.flatMap { visible.indices.contains($0) ? visible[$0] : nil } ?? visible.last
  }

  @ViewBuilder
  private func reading(of point: VolumePoint?) -> some View {
    if let point {
      let parts = valueParts(point)
      VStack(alignment: .leading, spacing: 4) {
        HeroValue(
          value: parts.number, unit: parts.unit, caption: format.dayYear(point.date), captionPlacement: .below
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: mode.label))
        .accessibilityValue(LiftFormat.facts([format.dayYear(point.date), spokenValue(point)]))
        Text(
          verbatim: LiftFormat.facts([
            String(localized: "Est. 1RM \(format.measured(pounds: point.bestEstimatedOneRepMax))"),
            String(localized: "Volume \(format.volume(pounds: point.volume))"),
            String(localized: "Best reps \(point.bestReps)"),
          ])
        )
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
      }
    }
  }

  private var emptyState: some View {
    LiftMessage(
      symbol: "chart.xyaxis.line",
      title: LocalizedStringKey(emptyTitle),
      message: "Log working sets to see this chart."
    )
    .frame(minHeight: 140, alignment: .topLeading)
  }

  private var emptyTitle: String {
    switch mode {
    case .strength: String(localized: "No strength data yet")
    case .volume: String(localized: "No volume data yet")
    case .reps: String(localized: "No reps data yet")
    }
  }

  // MARK: Values

  private func valueParts(_ point: VolumePoint) -> (number: String, unit: String?) {
    switch mode {
    case .strength:
      point.bestEstimatedOneRepMax > 0
        ? { let parts = format.parts(pounds: point.bestEstimatedOneRepMax); return (parts.number, parts.unit) }()
        : (LiftFormat.missing, nil)
    case .volume:
      point.volume > 0
        ? { let parts = format.volumeParts(pounds: point.volume); return (parts.number, parts.unit) }()
        : (LiftFormat.missing, nil)
    case .reps:
      (point.bestReps.formatted(.number.locale(format.locale)), String(localized: "reps"))
    }
  }

  private func spokenValue(_ point: VolumePoint) -> String {
    switch mode {
    case .strength: format.spokenWeight(pounds: point.bestEstimatedOneRepMax)
    case .volume: format.spokenWeight(pounds: point.volume)
    case .reps: String(localized: "\(point.bestReps) reps")
    }
  }

  private func chartValue(_ point: VolumePoint) -> Double {
    switch mode {
    case .strength: point.bestEstimatedOneRepMax
    case .volume: point.volume
    case .reps: Double(point.bestReps)
    }
  }

  private func summary(of visible: [VolumePoint]) -> String {
    guard let first = visible.first, let last = visible.last else { return String(localized: "No data") }
    return String(
      localized: "\(mode.label) chart from \(format.dayYear(first.date)) to \(format.dayYear(last.date))")
  }

  private func visiblePoints(window: LiftProgressWindow) -> [VolumePoint] {
    points.filter { point in
      guard point.date >= window.startInclusive, point.date <= window.endInclusive else { return false }
      return switch mode {
      case .strength: point.bestEstimatedOneRepMax > 0
      case .volume: point.volume > 0
      case .reps: point.bestReps > 0
      }
    }
  }
}
