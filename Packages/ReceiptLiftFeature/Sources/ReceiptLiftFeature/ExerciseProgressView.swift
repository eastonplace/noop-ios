import Charts
import SwiftUI

struct ExerciseProgressView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @EnvironmentObject private var store: LiftStore

  let exerciseID: UUID
  @State private var selectedMode: LiftExerciseProgressMode = .strength
  @State private var referenceNow = Date()
  @State private var selectedRange: LiftProgressRange = .twelveWeeks
  @State private var selectedDate: Date?
  @State private var showsInformation = false

  init(exerciseID: UUID, showsInformation: Bool = false) {
    self.exerciseID = exerciseID
    _showsInformation = State(initialValue: showsInformation)
  }

  private var exercise: LiftExercise? {
    store.exercise(for: exerciseID)
  }

  var body: some View {
    let snapshot = LiftProgressMath.exerciseProgressSnapshot(
      sessions: store.sessions,
      exerciseID: exerciseID,
      now: referenceNow,
      calendar: .current
    )
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        if let exercise {
          exerciseHeader(exercise, snapshot: snapshot)
          DisclosureGroup("Exercise photo, muscles & instructions", isExpanded: $showsInformation) {
            ExerciseInformationView(exercise: exercise).padding(.vertical, 12)
          }
          .tint(LiftTheme.accent)
          Picker("Date range", selection: $selectedRange) {
            ForEach(LiftProgressRange.allCases) { range in Text(range.title).tag(range) }
          }
          .pickerStyle(.segmented)
          modeBar
          progressChart(points: snapshot.points)
          ReceiptSectionLabel(title: "Recent Sets")
          if snapshot.recentSets.isEmpty {
            Text("NO WORKING SETS YET.")
              .font(.receipt(10, weight: .bold))
              .foregroundStyle(LiftTheme.inkSecondary)
              .padding(.vertical, 16)
          } else {
            ForEach(snapshot.recentSets) { row in
              recentSetRow(
                row,
                exercise: exercise,
                personalRecords: snapshot.historicalPersonalRecords
              )
            }
          }
        } else {
          missingExercise
        }
      }
      .padding(16)
      .padding(.bottom, 40)
    }
    .scrollIndicators(.hidden)
    .background(LiftTheme.paper.ignoresSafeArea())
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .navigationTitle("Exercise details")
    .onAppear { referenceNow = Date() }
    .onChange(of: selectedRange) { selectedDate = nil }
    .onChange(of: selectedMode) { selectedDate = nil }
  }

  private func exerciseHeader(
    _ exercise: LiftExercise,
    snapshot: LiftExerciseProgressSnapshot
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 14) {
        Button { showsInformation.toggle() } label: {
          LiftExerciseThumb(exercise: exercise, size: 84)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(exercise.name) photo and muscles")
        VStack(alignment: .leading, spacing: 4) {
          Text(exercise.name.capitalized)
            .font(.title2.weight(.bold))
            .foregroundStyle(LiftTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
          Text("\(exercise.muscleGroup) / \(exercise.equipment)".uppercased())
            .font(.receipt(9, weight: .bold))
            .foregroundStyle(LiftTheme.inkSecondary)
        }
      }
      ReceiptDashedRule()

      VStack(alignment: .leading, spacing: 7) {
        Text("EST. 1RM")
          .font(.receipt(9, weight: .black))
          .tracking(0.8)
          .foregroundStyle(LiftTheme.inkSecondary)
        Text(estimatedOneRepMaxLabel(bestSet: snapshot.bestSet).uppercased())
          .font(.receipt(42, weight: .black))
          .monospacedDigit()
          .foregroundStyle(LiftTheme.ink)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
        Text("BEST SET / \(bestSetLabel(exercise, bestSet: snapshot.bestSet))")
          .font(.receipt(10, weight: .bold))
          .foregroundStyle(LiftTheme.inkSecondary)
        if LiftStore.prDetectionEnabled, let latestPersonalRecord = snapshot.latestPersonalRecord {
          LiftPRPayoffView(record: latestPersonalRecord)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
    }
  }

  private var modeBar: some View {
    HStack(spacing: 0) {
      ForEach(LiftExerciseProgressMode.allCases) { mode in
        let selected = selectedMode == mode
        Button {
          withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.compose) {
            selectedMode = mode
          }
        } label: {
          Text(mode.title)
            .font(.receipt(9, weight: .black))
            .foregroundStyle(selected ? LiftTheme.paper : LiftTheme.ink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(selected ? LiftTheme.ink : LiftTheme.paper)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title.capitalized)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .overlay(Rectangle().stroke(LiftTheme.ink, lineWidth: 1))
  }

  private func progressChart(points: [VolumePoint]) -> some View {
    let visiblePoints = visiblePoints(in: points)
    return VStack(alignment: .leading, spacing: 10) {
      ReceiptSectionLabel(title: chartTitle)
      Text("Completed workouts only. Volume includes warm-ups; strength and reps use working sets. Estimated 1RM uses weight × (1 + reps / 30).")
        .font(.system(size: 12)).foregroundStyle(LiftTheme.inkSecondary)
      if visiblePoints.isEmpty {
        Text("NO \(selectedMode.title) DATA YET.")
          .font(.receipt(10, weight: .bold))
          .foregroundStyle(LiftTheme.inkSecondary)
          .frame(maxWidth: .infinity, minHeight: 180)
      } else {
        VStack(alignment: .leading, spacing: 12) {
          let selectedPoint = selectedDate.flatMap { date in
            visiblePoints.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
          } ?? visiblePoints.last
          if let point = selectedPoint {
            VStack(alignment: .leading, spacing: 6) {
              Text(point.date.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 13, weight: .semibold))
              Text(formattedChartValue(point))
                .font(.system(size: 26, weight: .bold)).monospacedDigit()
              Text("Estimated 1RM: \(liftMeasuredWeight(point.bestEstimatedOneRepMax)) · Volume: \(liftVolume(point.volume)) · Best reps: \(point.bestReps)")
                .font(.system(size: 12)).foregroundStyle(LiftTheme.inkSecondary)
            }
            .accessibilityElement(children: .combine)
          }
          Text("Touch the chart to inspect a training day.")
            .font(.system(size: 12)).foregroundStyle(LiftTheme.inkSecondary)
          Chart {
            ForEach(visiblePoints) { point in
            if selectedMode == .volume {
              BarMark(
                x: .value("Date", point.date, unit: .day),
                y: .value(chartValueLabel, chartValue(point))
              )
              .foregroundStyle(LiftTheme.ink)
              .accessibilityLabel(point.date.formatted(.dateTime.month(.abbreviated).day().year()))
              .accessibilityValue(formattedChartValue(point))
            } else {
              LineMark(
                x: .value("Date", point.date, unit: .day),
                y: .value(chartValueLabel, chartValue(point))
              )
              .foregroundStyle(LiftTheme.ink)
              .lineStyle(StrokeStyle(lineWidth: 2))
              PointMark(
                x: .value("Date", point.date, unit: .day),
                y: .value(chartValueLabel, chartValue(point))
              )
              .foregroundStyle(LiftTheme.ink)
              .accessibilityLabel(point.date.formatted(.dateTime.month(.abbreviated).day().year()))
              .accessibilityValue(formattedChartValue(point))
            }
          }
            if let point = selectedPoint {
              RuleMark(x: .value("Selected day", point.date, unit: .day))
                .foregroundStyle(LiftTheme.accent)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
          }
          .chartXSelection(value: $selectedDate)
          .chartXScale(domain: chartDomain(for: visiblePoints))
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
          .frame(height: 260)
          .id(selectedMode)
          .transition(.opacity)
          .accessibilityLabel(chartTitle.capitalized)
          .accessibilityValue(chartSummary(for: visiblePoints))
        }
        .scrollIndicators(.hidden)
      }
    }
  }

  private func recentSetRow(
    _ row: LiftRecentSetRow,
    exercise: LiftExercise,
    personalRecords: LiftHistoricalPRLedger
  ) -> some View {
    let personalRecord = LiftStore.prDetectionEnabled
      ? personalRecords[row.set.id]
      : nil
    return VStack(alignment: .leading, spacing: 0) {
      NavigationLink {
        CompletedReceiptView(session: row.session, presentation: .settled)
      } label: {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(row.set.completedAt.formatted(.dateTime.month(.abbreviated).day().year()).uppercased())
            .font(.receipt(9, weight: .bold))
            .foregroundStyle(LiftTheme.inkSecondary)
          Spacer(minLength: 8)
          Text("\(liftLoad(row.set.weight, for: exercise)) × \(row.set.reps)".uppercased())
            .font(.receipt(11, weight: .black))
            .foregroundStyle(LiftTheme.ink)
          if let personalRecord {
            LiftPRBadge(record: personalRecord)
          }
          Text("→")
            .font(.receipt(12, weight: .black))
            .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "\(row.set.completedAt.formatted(date: .abbreviated, time: .omitted)), \(liftLoad(row.set.weight, for: exercise)) by \(row.set.reps) reps\(personalRecord == nil ? "" : ", personal record")"
      )
      .accessibilityHint("Opens the parent workout receipt")
      Text("Set \(row.set.setNumber) · RPE \(row.set.rpe, specifier: "%.1f") · Volume \(liftVolume(row.set.volume)) · Est. 1RM \(liftMeasuredWeight(row.set.estimatedOneRepMax))")
        .font(.system(size: 12)).foregroundStyle(LiftTheme.inkSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
      if !row.set.notes.isEmpty {
        Text(row.set.notes).font(.system(size: 13)).padding(.bottom, 8)
      }
      ReceiptDashedRule()
    }
  }

  private var missingExercise: some View {
    VStack(alignment: .leading, spacing: 12) {
      ReceiptHeader(title: "Exercise Not Found", subtitle: "This local exercise is no longer available")
      ReceiptDashedRule()
      Text("RETURN TO HISTORY AND CHOOSE ANOTHER EXERCISE.")
        .font(.receipt(10, weight: .bold))
        .foregroundStyle(LiftTheme.inkSecondary)
    }
  }

  private func visiblePoints(in points: [VolumePoint]) -> [VolumePoint] {
    let window = LiftProgressMath.window(for: selectedRange, sessions: store.sessions, now: referenceNow, calendar: .current)
    return points.filter { point in
      guard point.date >= window.startInclusive, point.date <= window.endInclusive else { return false }
      return switch selectedMode {
      case .strength: point.bestEstimatedOneRepMax > 0
      case .volume: point.volume > 0
      case .reps: point.bestReps > 0
      }
    }
  }

  private func chartDomain(for visiblePoints: [VolumePoint]) -> ClosedRange<Date> {
    guard let first = visiblePoints.first?.date, let last = visiblePoints.last?.date else {
      return referenceNow...referenceNow.addingTimeInterval(86_400)
    }
    if first == last {
      return first...first.addingTimeInterval(86_400)
    }
    return first...last
  }

  private var chartTitle: String {
    switch selectedMode {
    case .strength: "Strength (Estimated 1RM)"
    case .volume: "Daily Volume (LB)"
    case .reps: "Best Reps"
    }
  }

  private var chartValueLabel: String {
    switch selectedMode {
    case .strength: "Best estimated one rep max"
    case .volume: "Daily volume in pounds"
    case .reps: "Best working-set reps"
    }
  }

  private func chartValue(_ point: VolumePoint) -> Double {
    switch selectedMode {
    case .strength: point.bestEstimatedOneRepMax
    case .volume: point.volume
    case .reps: Double(point.bestReps)
    }
  }

  private func formattedChartValue(_ point: VolumePoint) -> String {
    switch selectedMode {
    case .strength: liftMeasuredWeight(point.bestEstimatedOneRepMax)
    case .volume: liftVolume(point.volume)
    case .reps: "\(point.bestReps) reps"
    }
  }

  private func chartSummary(for visiblePoints: [VolumePoint]) -> String {
    guard let first = visiblePoints.first, let last = visiblePoints.last else { return "No data" }
    return "\(visiblePoints.count) daily points from \(first.date.formatted(date: .abbreviated, time: .omitted)) to \(last.date.formatted(date: .abbreviated, time: .omitted))"
  }

  private func bestSetLabel(_ exercise: LiftExercise, bestSet: LiftSet?) -> String {
    guard let bestSet else { return "—" }
    return "\(liftLoad(bestSet.weight, for: exercise)) × \(bestSet.reps)".uppercased()
  }

  private func estimatedOneRepMaxLabel(bestSet: LiftSet?) -> String {
    guard let bestSet, bestSet.weight > 0 else { return "—" }
    return liftMeasuredWeight(bestSet.estimatedOneRepMax)
  }
}
