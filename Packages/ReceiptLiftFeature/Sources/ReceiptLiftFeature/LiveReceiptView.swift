import SwiftUI

struct LiftReceiptLineSnapshot: Identifiable, Equatable, Sendable {
  let id: UUID
  let ordinal: Int
  let exerciseID: UUID
  let exerciseName: String
  let loadLabel: String
  let statusLabel: String
  let volumeLabel: String
  let isWarmup: Bool

  var detailLabel: String {
    guard !isWarmup else { return "WARM-UP  /  \(loadLabel)" }
    let setNoun = statusLabel == "1" || statusLabel.hasPrefix("1/") ? "SET" : "SETS"
    return "\(loadLabel)  /  \(statusLabel) \(setNoun)"
  }

  var accessibilityLabel: String {
    let setKind = isWarmup ? "warm-up set" : "working set \(statusLabel)"
    return "\(exerciseName), \(setKind), \(loadLabel), volume \(volumeLabel)"
  }
}

struct LiftReceiptSnapshot: Equatable, Sendable {
  let sessionID: UUID
  let lines: [LiftReceiptLineSnapshot]
  let workingSetCount: Int
  let totalVolume: Double
  let duration: TimeInterval

  nonisolated static func make(
    session: LiftSession,
    exercisesByID: [UUID: LiftExercise],
    targetSetsByExerciseID: [UUID: Int],
    now: Date = Date()
  ) -> Self {
    var workingOrdinals: [UUID: Int] = [:]

    let lines = session.sets.enumerated().map { index, set in
      let exercise = exercisesByID[set.exerciseID]
      let statusLabel: String
      if set.isWarmup {
        statusLabel = "WARM-UP"
      } else {
        workingOrdinals[set.exerciseID, default: 0] += 1
        let completed = workingOrdinals[set.exerciseID, default: 0]
        if let target = targetSetsByExerciseID[set.exerciseID] {
          statusLabel = "\(completed)/\(max(target, completed, 1))"
        } else {
          statusLabel = "\(completed)"
        }
      }

      let usesBodyweight = exercise.map(liftUsesBodyweightLoad) ?? false
      let load = liftLoad(set.weight, for: exercise).uppercased()
      return LiftReceiptLineSnapshot(
        id: set.id,
        ordinal: index + 1,
        exerciseID: set.exerciseID,
        exerciseName: (exercise?.name ?? "Exercise unavailable").uppercased(),
        loadLabel: "\(load) × \(set.reps)",
        statusLabel: statusLabel,
        volumeLabel: usesBodyweight ? "—" : liftVolume(set.volume).uppercased(),
        isWarmup: set.isWarmup
      )
    }

    return Self(
      sessionID: session.id,
      lines: lines,
      workingSetCount: session.workingSets.count,
      totalVolume: session.totalVolume,
      duration: max((session.endedAt ?? now).timeIntervalSince(session.startedAt), 0)
    )
  }
}

struct LiveReceiptView: View {
  @EnvironmentObject private var store: LiftStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let session: LiftSession

  var body: some View {
    ScrollView {
      ReceiptSheet {
        ReceiptHeader(
          title: "Live Receipt",
          subtitle: currentSession.title,
          trailing: receiptNumber
        )
        ReceiptDashedRule()
        ReceiptColumns([
          ("#", .leading),
          ("Exercise", .leading),
          ("Sets", .trailing),
          ("Volume (lb)", .trailing),
        ])
        ReceiptDashedRule()
        LiveReceiptRows(snapshot: snapshot)
        LiveReceiptTotals(
          session: currentSession,
          workingSetCount: snapshot.workingSetCount,
          totalVolume: snapshot.totalVolume
        )
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 18)
    }
    .scrollIndicators(.hidden)
    .liftScreenBackground()
    .animation(
      reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.printLine,
      value: snapshot.lines.map(\.id)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Live workout receipt")
  }

  private var currentSession: LiftSession {
    guard let activeSession = store.activeSession, activeSession.id == session.id else {
      return session
    }
    return activeSession
  }

  private var snapshot: LiftReceiptSnapshot {
    let exercisesByID = Dictionary(uniqueKeysWithValues: store.exercises.map { ($0.id, $0) })
    let targets = store.activeExercises.reduce(into: [UUID: Int]()) { result, exercise in
      if let target = store.setProgress(for: exercise.id).target {
        result[exercise.id] = target
      }
    }
    return LiftReceiptSnapshot.make(
      session: currentSession,
      exercisesByID: exercisesByID,
      targetSetsByExerciseID: targets
    )
  }

  private var receiptNumber: String {
    LiftMedia.receiptNumber(for: currentSession, in: store.sessions)
  }
}

private struct LiveReceiptRows: View {
  let snapshot: LiftReceiptSnapshot

  var body: some View {
    if snapshot.lines.isEmpty {
      Text("SETS PRINT HERE AS YOU LOG THEM.")
        .font(.receipt(11, weight: .bold))
        .foregroundStyle(LiftTheme.inkSecondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
        .accessibilityLabel("No sets logged yet")
    } else {
      ForEach(snapshot.lines) { line in
        PrintedSetLine(
          index: line.ordinal,
          title: line.exerciseName,
          detail: line.detailLabel,
          value: line.volumeLabel
        )
        .transition(
          .asymmetric(
            insertion: .offset(y: LiftDesignMetrics.Receipt.lineInsertionOffset)
              .combined(with: .opacity),
            removal: .opacity
          )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityLabel)
      }
    }
  }
}

private struct LiveReceiptTotals: View {
  let session: LiftSession
  let workingSetCount: Int
  let totalVolume: Double

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var displayedWorkingSetCount: Int
  @State private var displayedTotalVolume: Double
  @State private var totalsTask: Task<Void, Never>?

  init(
    session: LiftSession,
    workingSetCount: Int,
    totalVolume: Double
  ) {
    self.session = session
    self.workingSetCount = workingSetCount
    self.totalVolume = totalVolume
    _displayedWorkingSetCount = State(initialValue: workingSetCount)
    _displayedTotalVolume = State(initialValue: totalVolume)
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      ReceiptTotals(rows: [
        ("Sets", "\(displayedWorkingSetCount)"),
        ("Total volume", liftVolume(displayedTotalVolume)),
        ("Duration", liftClockDuration(duration(at: context.date))),
      ])
      .contentTransition(.numericText())
    }
    .accessibilityElement(children: .combine)
    .onChange(of: totalsTarget) { _, target in
      updateTotals(afterLineInsertionTo: target)
    }
    .onDisappear {
      totalsTask?.cancel()
      totalsTask = nil
    }
  }

  private var totalsTarget: LiftLiveReceiptTotalsTarget {
    LiftLiveReceiptTotalsTarget(
      workingSetCount: workingSetCount,
      totalVolume: totalVolume
    )
  }

  private func updateTotals(afterLineInsertionTo target: LiftLiveReceiptTotalsTarget) {
    totalsTask?.cancel()
    guard !reduceMotion else {
      displayedWorkingSetCount = target.workingSetCount
      displayedTotalVolume = target.totalVolume
      return
    }

    totalsTask = Task { @MainActor in
      let settleMilliseconds = Int64(
        LiftMotion.Parameters.printLineResponse * 1_000
      )
      try? await Task.sleep(for: .milliseconds(settleMilliseconds))
      guard !Task.isCancelled else { return }
      withAnimation(LiftMotion.printLine) {
        displayedWorkingSetCount = target.workingSetCount
        displayedTotalVolume = target.totalVolume
      }
      totalsTask = nil
    }
  }

  private func duration(at date: Date) -> TimeInterval {
    max((session.endedAt ?? date).timeIntervalSince(session.startedAt), 0)
  }
}

private struct LiftLiveReceiptTotalsTarget: Equatable, Sendable {
  let workingSetCount: Int
  let totalVolume: Double
}
