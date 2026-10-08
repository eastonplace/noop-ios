import Charts
import StrandDesign
import SwiftUI

struct HistoryView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @EnvironmentObject private var store: LiftStore
  @Environment(\.liftHostChrome) private var host

  private let selectedSegment: Binding<LiftHistorySegment>?
  @State private var localSegment: LiftHistorySegment = .receipts
  @State private var selectedRange: LiftProgressRange = .twelveWeeks
  @State private var referenceNow = Date()
  @State private var showingExercisePicker = false
  @State private var selectedExerciseID: UUID?
  private let progressOnly: Bool

  init(selectedSegment: Binding<LiftHistorySegment>? = nil, progressOnly: Bool = false) {
    self.selectedSegment = selectedSegment
    self.progressOnly = progressOnly
  }

  private var activeSegment: LiftHistorySegment {
    selectedSegment?.wrappedValue ?? localSegment
  }

  private var completedSessions: [LiftSession] {
    store.sessions
      .filter { $0.endedAt != nil }
      .sorted { left, right in
        if left.startedAt != right.startedAt { return left.startedAt > right.startedAt }
        if left.endedAt != right.endedAt {
          return (left.endedAt ?? left.startedAt) > (right.endedAt ?? right.startedAt)
        }
        return left.id.uuidString > right.id.uuidString
      }
  }

  private var progressSnapshot: LiftProgressSnapshot {
    store.progressSnapshot(for: selectedRange, now: referenceNow, calendar: .current)
  }

  var body: some View {
    LiftScreen(
      title: progressOnly ? "Progress" : "History",
      subtitle: "Receipts and training progress",
      backAction: host.onBack,
      lazy: true,
      trailing: { LiftHeaderTrailing() }
    ) {
      if !progressOnly {
        SegmentedPillControl(
          LiftHistorySegment.allCases,
          selection: segmentSelection
        ) { $0.title.capitalized }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      if activeSegment == .receipts {
        receiptRows
      } else {
        progressOverview
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
    .onChange(of: scenePhase) {
      guard scenePhase == .active, activeSegment == .progress else { return }
      referenceNow = Date()
    }
    .onChange(of: activeSegment) { _, segment in
      guard segment == .progress else { return }
      referenceNow = Date()
    }
    .onChange(of: store.sessions) {
      guard activeSegment == .progress else { return }
      referenceNow = Date()
    }
  }

  private var segmentSelection: Binding<LiftHistorySegment> {
    Binding(get: { activeSegment }, set: { setSegment($0) })
  }

  @ViewBuilder
  private var receiptRows: some View {
    if completedSessions.isEmpty {
      LiftStateMessage(
        symbol: "list.bullet.rectangle",
        title: "No receipts yet",
        message: "Finish a workout and its receipt shows up here."
      )
    } else {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(completedSessions) { session in
          NavigationLink {
            CompletedReceiptView(session: session, presentation: .settled)
          } label: {
            receiptRow(session)
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private func receiptRow(_ session: LiftSession) -> some View {
    LiftRow(
      title: session.title,
      detail: receiptDate(session.startedAt),
      value: liftVolume(session.totalVolume),
      showsChevron: true
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(receiptDate(session.startedAt)), \(session.title), \(liftVolume(session.totalVolume))"
    )
    .accessibilityHint("Opens completed workout receipt")
  }

  private var progressOverview: some View {
    let snapshot = progressSnapshot
    return VStack(alignment: .leading, spacing: 20) {
      SegmentedPillControl(
        LiftProgressRange.allCases,
        selection: rangeSelection
      ) { $0.title }
      .frame(maxWidth: .infinity, alignment: .leading)

      LiftSection(title: "Weekly volume (lb)") {
        weeklyVolumeChart(snapshot)
      }

      metricsGrid(snapshot.metrics)

      LiftSection(title: "Top exercises (volume)") {
        if snapshot.topExercises.isEmpty {
          LiftEmptyNote(text: "No volume in this range.")
        } else {
          ForEach(Array(snapshot.topExercises.enumerated()), id: \.element.id) { index, exercise in
            NavigationLink {
              ExerciseProgressView(exerciseID: exercise.exerciseID)
                .environmentObject(store)
            } label: {
              LiftRow(
                title: exercise.name.liftDisplayName,
                detail: "Total training volume",
                value: liftVolume(exercise.volume),
                showsChevron: true
              ) {
                LiftRowIndex(index: index + 1)
              }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens exercise progress")
          }
        }
      }

      NoopButton("Find an exercise", systemImage: "magnifyingglass", kind: .secondary, fullWidth: true) {
        showingExercisePicker = true
      }
      .accessibilityHint("Searches the exercise library")
    }
    .id(selectedRange)
    .transition(.opacity)
  }

  private var rangeSelection: Binding<LiftProgressRange> {
    Binding(
      get: { selectedRange },
      set: { range in
        referenceNow = Date()
        withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.compose) {
          selectedRange = range
        }
      }
    )
  }

  private func weeklyVolumeChart(_ snapshot: LiftProgressSnapshot) -> some View {
    let plotWidth = max(380, CGFloat(snapshot.weeklyVolume.count) * 30)
    return ScrollView(.horizontal) {
      Chart(snapshot.weeklyVolume) { week in
        BarMark(
          x: .value("Week starting", week.weekStart, unit: .weekOfYear),
          y: .value("Weekly volume in pounds", week.volume)
        )
        .foregroundStyle(LiftTheme.accent)
        .accessibilityLabel(week.weekStart.formatted(.dateTime.month(.abbreviated).day()))
        .accessibilityValue(liftVolume(week.volume))
      }
      .chartXScale(domain: snapshot.window.startInclusive...snapshot.window.displayEndExclusive)
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 5)) {
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
            .foregroundStyle(LiftTheme.rule)
          AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            .font(StrandFont.micro)
            .foregroundStyle(StrandPalette.textTertiary)
        }
      }
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
            .foregroundStyle(LiftTheme.rule)
          AxisValueLabel()
            .font(StrandFont.micro)
            .foregroundStyle(StrandPalette.textTertiary)
        }
      }
      .frame(width: plotWidth, height: 220)
      .accessibilityLabel("Weekly training volume")
      .accessibilityValue(
        "\(snapshot.weeklyVolume.count) weeks, \(liftVolume(snapshot.metrics.workDone)) total"
      )
    }
    .scrollIndicators(.hidden)
  }

  private func metricsGrid(_ metrics: LiftProgressMetrics) -> some View {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
      LiftMetric(title: "Work done", value: liftVolume(metrics.workDone))
      LiftMetric(title: "Workouts", value: "\(metrics.workouts)")
      LiftMetric(title: "Sets", value: "\(metrics.workingSets)")
      LiftMetric(title: "Avg duration", value: liftDuration(metrics.averageDuration))
      LiftMetric(title: "Consistency", value: "\(Int(metrics.consistencyPercent.rounded()))%")
      LiftMetric(title: "Exercises", value: "\(metrics.exerciseCount)")
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

  private func receiptDate(_ date: Date) -> String {
    let day = date.formatted(.dateTime.month(.abbreviated).day().year())
    let time = date.formatted(.dateTime.hour().minute())
    return "\(day) · \(time)"
  }
}
