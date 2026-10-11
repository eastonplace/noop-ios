import Charts
import StrandDesign
import SwiftUI

struct ExerciseProgressView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: LiftStore

  let exerciseID: UUID
  /// True when this view is the root of its own modal (a sheet), so the header closes it instead of popping.
  private let closesModal: Bool
  @State private var selectedMode: LiftExerciseProgressMode = .strength
  @State private var referenceNow = Date()
  @State private var selectedRange: LiftProgressRange = .twelveWeeks
  @State private var selectedDate: Date?
  @State private var showsInformation = false

  init(exerciseID: UUID, showsInformation: Bool = false, closesModal: Bool = false) {
    self.exerciseID = exerciseID
    self.closesModal = closesModal
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
    LiftScreen(
      title: LocalizedStringKey(exercise?.name.liftDisplayName ?? "Exercise not found"),
      subtitle: exercise.map { LocalizedStringKey("\($0.muscleGroup) · \($0.equipment)".liftDisplayName) },
      backAction: closesModal ? nil : { dismiss() },
      lazy: true,
      bottomPadding: 40,
      trailing: {
        if closesModal {
          NoopIconButton("xmark", accessibilityLabel: "Close") { dismiss() }
        }
      }
    ) {
      if let exercise {
        exerciseHeader(exercise, snapshot: snapshot)
        DisclosureGroup(isExpanded: $showsInformation) {
          ExerciseInformationView(exercise: exercise).padding(.vertical, 12)
        } label: {
          Text("Exercise photo, muscles & instructions")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textPrimary)
        }
        .tint(LiftTheme.accent)
        SegmentedPillControl(
          LiftProgressRange.allCases,
          selection: $selectedRange
        ) { $0.title }
        .frame(maxWidth: .infinity, alignment: .leading)
        modeBar
        progressChart(points: snapshot.points)
        LiftSection(title: "Recent sets") {
          if snapshot.recentSets.isEmpty {
            LiftEmptyNote(text: "No working sets yet.")
          } else {
            ForEach(snapshot.recentSets) { row in
              recentSetRow(
                row,
                exercise: exercise,
                personalRecords: snapshot.historicalPersonalRecords
              )
            }
          }
        }
      } else {
        missingExercise
      }
    }
    .onAppear { referenceNow = Date() }
    .liftQAScene("exercise-info") { showsInformation = true }
    .onChange(of: selectedRange) { selectedDate = nil }
    .onChange(of: selectedMode) { selectedDate = nil }
  }

  private func exerciseHeader(
    _ exercise: LiftExercise,
    snapshot: LiftExerciseProgressSnapshot
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 14) {
        Button { showsInformation.toggle() } label: {
          LiftExerciseThumb(exercise: exercise, size: 84)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(exercise.name) photo and muscles")
        VStack(alignment: .leading, spacing: 4) {
          Text("Est. 1RM").strandOverline()
          Text(estimatedOneRepMaxLabel(bestSet: snapshot.bestSet))
            .font(StrandFont.number(36, weight: .bold))
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
          Text("Best set · \(bestSetLabel(exercise, bestSet: snapshot.bestSet))")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
      }
      if LiftStore.prDetectionEnabled, let latestPersonalRecord = snapshot.latestPersonalRecord {
        LiftPRPayoffView(record: latestPersonalRecord)
      }
    }
  }

  private var modeBar: some View {
    SegmentedPillControl(
      LiftExerciseProgressMode.allCases,
      selection: modeSelection
    ) { $0.title.capitalized }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var modeSelection: Binding<LiftExerciseProgressMode> {
    Binding(
      get: { selectedMode },
      set: { mode in
        withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.compose) {
          selectedMode = mode
        }
      }
    )
  }

  private func progressChart(points: [VolumePoint]) -> some View {
    let visiblePoints = visiblePoints(in: points)
    return LiftSection(title: LocalizedStringKey(chartTitle)) {
      VStack(alignment: .leading, spacing: 10) {
        Text("Completed workouts only. Volume includes warm-ups; strength and reps use working sets. Estimated 1RM uses weight × (1 + reps / 30).")
          .font(StrandFont.caption)
          .foregroundStyle(StrandPalette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        if visiblePoints.isEmpty {
          LiftStateMessage(
            symbol: "chart.xyaxis.line",
            title: "No \(selectedMode.title.lowercased()) data yet",
            message: "Log working sets to see this chart."
          )
          .frame(minHeight: 180)
        } else {
          VStack(alignment: .leading, spacing: 12) {
            let selectedPoint = selectedDate.flatMap { date in
              visiblePoints.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
            } ?? visiblePoints.last
            if let point = selectedPoint {
              VStack(alignment: .leading, spacing: 6) {
                Text(point.date.formatted(date: .abbreviated, time: .omitted))
                  .font(StrandFont.subhead.weight(.semibold))
                  .foregroundStyle(StrandPalette.textPrimary)
                Text(formattedChartValue(point))
                  .font(StrandFont.number(26, weight: .bold))
                  .foregroundStyle(StrandPalette.textPrimary)
                Text("Estimated 1RM: \(liftMeasuredWeight(point.bestEstimatedOneRepMax)) · Volume: \(liftVolume(point.volume)) · Best reps: \(point.bestReps)")
                  .font(StrandFont.caption)
                  .foregroundStyle(StrandPalette.textSecondary)
              }
              .accessibilityElement(children: .combine)
            }
            Text("Touch the chart to inspect a training day.")
              .font(StrandFont.caption)
              .foregroundStyle(StrandPalette.textTertiary)
            Chart {
              ForEach(visiblePoints) { point in
                if selectedMode == .volume {
                  BarMark(
                    x: .value("Date", point.date, unit: .day),
                    y: .value(chartValueLabel, chartValue(point))
                  )
                  .foregroundStyle(LiftTheme.accent)
                  .accessibilityLabel(point.date.formatted(.dateTime.month(.abbreviated).day().year()))
                  .accessibilityValue(formattedChartValue(point))
                } else {
                  LineMark(
                    x: .value("Date", point.date, unit: .day),
                    y: .value(chartValueLabel, chartValue(point))
                  )
                  .foregroundStyle(LiftTheme.accent)
                  .lineStyle(StrokeStyle(lineWidth: 2))
                  PointMark(
                    x: .value("Date", point.date, unit: .day),
                    y: .value(chartValueLabel, chartValue(point))
                  )
                  .foregroundStyle(LiftTheme.accent)
                  .accessibilityLabel(point.date.formatted(.dateTime.month(.abbreviated).day().year()))
                  .accessibilityValue(formattedChartValue(point))
                }
              }
              if let point = selectedPoint {
                RuleMark(x: .value("Selected day", point.date, unit: .day))
                  .foregroundStyle(StrandPalette.textSecondary)
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
            .frame(height: 260)
            .id(selectedMode)
            .transition(.opacity)
            .accessibilityLabel(chartTitle.capitalized)
            .accessibilityValue(chartSummary(for: visiblePoints))
          }
        }
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
    let load = "\(liftLoad(row.set.weight, for: exercise)) × \(row.set.reps)"
    let date = row.set.completedAt.formatted(.dateTime.month(.abbreviated).day().year())
    var detail = "Set \(row.set.setNumber) · RPE \(String(format: "%.1f", row.set.rpe)) · Volume \(liftVolume(row.set.volume)) · Est. 1RM \(liftMeasuredWeight(row.set.estimatedOneRepMax))"
    if !row.set.notes.isEmpty { detail += "\n\(row.set.notes)" }
    return NavigationLink {
      CompletedReceiptView(session: row.session, presentation: .settled)
    } label: {
      LiftRow(
        title: date,
        detail: detail,
        value: load,
        showsChevron: true,
        leading: { EmptyView() },
        trailing: {
          if let personalRecord {
            LiftPRBadge(record: personalRecord)
          }
        }
      )
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(row.set.completedAt.formatted(date: .abbreviated, time: .omitted)), \(liftLoad(row.set.weight, for: exercise)) by \(row.set.reps) reps\(personalRecord == nil ? "" : ", personal record")"
    )
    .accessibilityHint("Opens the parent workout receipt")
  }

  private var missingExercise: some View {
    LiftStateMessage(
      symbol: "questionmark.circle",
      title: "Exercise not found",
      message: "This local exercise is no longer available. Return to history and choose another exercise."
    )
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
    return "\(liftLoad(bestSet.weight, for: exercise)) × \(bestSet.reps)"
  }

  private func estimatedOneRepMaxLabel(bestSet: LiftSet?) -> String {
    guard let bestSet, bestSet.weight > 0 else { return "—" }
    return liftMeasuredWeight(bestSet.estimatedOneRepMax)
  }
}
