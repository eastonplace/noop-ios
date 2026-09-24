import Charts
import SwiftUI

struct HistoryView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @EnvironmentObject private var store: LiftStore

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
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ReceiptHeader(title: progressOnly ? "Progress" : "History", subtitle: "Receipts and training progress")
          .padding(.horizontal, 16)
          .padding(.top, 12)

        if !progressOnly {
          historySegmentBar
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }

        ReceiptRule()
          .padding(.horizontal, 16)

        if activeSegment == .receipts {
          receiptRows
        } else {
          progressOverview
        }
      }
      .padding(.bottom, 24)
    }
    .scrollIndicators(.hidden)
    .background(LiftTheme.paper.ignoresSafeArea())
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

  private var historySegmentBar: some View {
    HStack(spacing: 0) {
      ForEach(LiftHistorySegment.allCases) { segment in
        segmentButton(segment)
      }
    }
    .overlay(Rectangle().stroke(LiftTheme.ink, lineWidth: 1))
  }

  private func segmentButton(_ segment: LiftHistorySegment) -> some View {
    let selected = activeSegment == segment
    return Button {
      setSegment(segment)
    } label: {
      Text(segment.title)
        .font(.receipt(10, weight: .black))
        .foregroundStyle(selected ? LiftTheme.paper : LiftTheme.ink)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(selected ? LiftTheme.ink : LiftTheme.paper)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(segment.title.capitalized)
    .accessibilityValue(selected ? "Selected" : "Not selected")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  @ViewBuilder
  private var receiptRows: some View {
    if completedSessions.isEmpty {
      Text("NO SAVED RECEIPTS YET.")
        .font(.receipt(11, weight: .bold))
        .foregroundStyle(LiftTheme.inkSecondary)
        .padding(16)
    } else {
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

  private func receiptRow(_ session: LiftSession) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(receiptDate(session.startedAt))
        .font(.receipt(9, weight: .bold))
        .foregroundStyle(LiftTheme.inkSecondary)

      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(session.title.uppercased())
          .font(.receipt(13, weight: .black))
          .foregroundStyle(LiftTheme.ink)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 8)
        Text(liftVolume(session.totalVolume).uppercased())
          .font(.receipt(11, weight: .black))
          .foregroundStyle(LiftTheme.ink)
        Text("→")
          .font(.receipt(13, weight: .black))
          .accessibilityHidden(true)
      }

      ReceiptDashedRule()
    }
    .padding(.horizontal, 16)
    .padding(.top, 13)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(receiptDate(session.startedAt)), \(session.title), \(liftVolume(session.totalVolume))"
    )
    .accessibilityHint("Opens completed workout receipt")
  }

  private var progressOverview: some View {
    let snapshot = progressSnapshot
    return VStack(alignment: .leading, spacing: 18) {
      rangeBar

      ReceiptSectionLabel(title: "Weekly Volume (LB)")
      weeklyVolumeChart(snapshot)

      metricsGrid(snapshot.metrics)

      ReceiptSectionLabel(title: "Top Exercises (Volume)")
      if snapshot.topExercises.isEmpty {
        Text("NO VOLUME IN THIS RANGE.")
          .font(.receipt(10, weight: .bold))
          .foregroundStyle(LiftTheme.inkSecondary)
      } else {
        ForEach(Array(snapshot.topExercises.enumerated()), id: \.element.id) { index, exercise in
          NavigationLink {
            ExerciseProgressView(exerciseID: exercise.exerciseID)
              .environmentObject(store)
          } label: {
            ReceiptLine(
              index: index + 1,
              title: exercise.name,
              detail: "TOTAL TRAINING VOLUME",
              value: "\(liftVolume(exercise.volume)) →"
            )
          }
          .buttonStyle(.plain)
          .accessibilityHint("Opens exercise progress")
        }
      }

      Button {
        showingExercisePicker = true
      } label: {
        Text("FIND AN EXERCISE →")
          .font(.receipt(10, weight: .black))
          .foregroundStyle(LiftTheme.paper)
          .frame(maxWidth: .infinity, minHeight: 44)
          .background(LiftTheme.ink)
      }
      .buttonStyle(.plain)
      .accessibilityHint("Searches the exercise library")
    }
    .id(selectedRange)
    .transition(.opacity)
    .padding(16)
  }

  private var rangeBar: some View {
    HStack(spacing: 0) {
      ForEach(LiftProgressRange.allCases) { range in
        let selected = selectedRange == range
        Button {
          referenceNow = Date()
          withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.compose) {
            selectedRange = range
          }
        } label: {
          Text(range.title)
            .font(.receipt(10, weight: .black))
            .foregroundStyle(selected ? LiftTheme.paper : LiftTheme.ink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(selected ? LiftTheme.ink : LiftTheme.paper)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(range.title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .overlay(Rectangle().stroke(LiftTheme.ink, lineWidth: 1))
  }

  private func weeklyVolumeChart(_ snapshot: LiftProgressSnapshot) -> some View {
    let plotWidth = max(380, CGFloat(snapshot.weeklyVolume.count) * 30)
    return ScrollView(.horizontal) {
      Chart(snapshot.weeklyVolume) { week in
        BarMark(
          x: .value("Week starting", week.weekStart, unit: .weekOfYear),
          y: .value("Weekly volume in pounds", week.volume)
        )
        .foregroundStyle(LiftTheme.ink)
        .accessibilityLabel(week.weekStart.formatted(.dateTime.month(.abbreviated).day()))
        .accessibilityValue(liftVolume(week.volume))
      }
      .chartXScale(domain: snapshot.window.startInclusive...snapshot.window.displayEndExclusive)
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 5)) {
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
            .foregroundStyle(LiftTheme.rule)
          AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            .font(.receipt(8, weight: .bold))
        }
      }
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
            .foregroundStyle(LiftTheme.rule)
          AxisValueLabel()
            .font(.receipt(8, weight: .bold))
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
      ReceiptMetric(title: "Work Done", value: liftVolume(metrics.workDone))
      ReceiptMetric(title: "Workouts", value: "\(metrics.workouts)")
      ReceiptMetric(title: "Sets", value: "\(metrics.workingSets)")
      ReceiptMetric(title: "Avg Duration", value: liftDuration(metrics.averageDuration))
      ReceiptMetric(title: "Consistency", value: "\(Int(metrics.consistencyPercent.rounded()))%")
      ReceiptMetric(title: "Exercises", value: "\(metrics.exerciseCount)")
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
    let day = date.formatted(.dateTime.month(.abbreviated).day().year()).uppercased()
    let time = date.formatted(.dateTime.hour().minute()).uppercased()
    return "\(day) · \(time)"
  }
}
