import Charts
import SwiftUI

struct ExerciseProgressView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @EnvironmentObject private var store: LiftStore

  let exerciseID: UUID
  @State private var selectedMode: LiftExerciseProgressMode = .strength
  @State private var referenceNow = Date()

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
    .onAppear { referenceNow = Date() }
  }

  private func exerciseHeader(
    _ exercise: LiftExercise,
    snapshot: LiftExerciseProgressSnapshot
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 14) {
        LiftExerciseThumb(exercise: exercise, size: 84)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(exercise.name.uppercased())
            .font(.receiptCondensed(32, weight: .black))
            .foregroundStyle(LiftTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
          Text("\(exercise.muscleGroup) / \(exercise.equipment)".uppercased())
            .font(.receipt(9, weight: .bold))
            .foregroundStyle(LiftTheme.inkSecondary)
        }
      }
      .accessibilityElement(children: .combine)

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
      if visiblePoints.isEmpty {
        Text("NO \(selectedMode.title) DATA YET.")
          .font(.receipt(10, weight: .bold))
          .foregroundStyle(LiftTheme.inkSecondary)
          .frame(maxWidth: .infinity, minHeight: 180)
      } else {
        ScrollView(.horizontal) {
          Chart(visiblePoints) { point in
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
          .frame(width: max(380, CGFloat(visiblePoints.count) * 44), height: 230)
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
    points.filter { point in
      switch selectedMode {
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
