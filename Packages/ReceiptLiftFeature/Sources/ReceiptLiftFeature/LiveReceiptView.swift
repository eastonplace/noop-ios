import StrandDesign
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
    guard !isWarmup else { return "\(statusLabel)  /  \(loadLabel)" }
    let setNoun = (statusLabel == "1" || statusLabel.hasPrefix("1/") ? String(localized: "set") : String(localized: "sets")).uppercased()
    return "\(loadLabel)  /  \(statusLabel) \(setNoun)"
  }

  var accessibilityLabel: String {
    let setKind = isWarmup ? String(localized: "warm-up set") : String(localized: "working set \(statusLabel)")
    return LiftFormat.spoken([exerciseName, setKind, loadLabel, String(localized: "volume \(volumeLabel)")])
  }
}

struct LiftReceiptSnapshot: Equatable, Sendable {
  let sessionID: UUID
  let lines: [LiftReceiptLineSnapshot]
  let workingSetCount: Int
  let totalVolume: Double
  let duration: TimeInterval

  /// The receipt's lines and totals. `format` decides the unit and language the loads are printed in; the default is
  /// pounds in English, which is what the logic tests read.
  nonisolated static func make(
    session: LiftSession,
    exercisesByID: [UUID: LiftExercise],
    targetSetsByExerciseID: [UUID: Int],
    now: Date = Date(),
    format: LiftFormat = LiftFormat(unit: .pounds, locale: Locale(identifier: "en_US"))
  ) -> Self {
    var workingOrdinals: [UUID: Int] = [:]

    let lines = session.sets.enumerated().map { index, set in
      let exercise = exercisesByID[set.exerciseID]
      let statusLabel: String
      if set.isWarmup {
        statusLabel = String(localized: "warm-up").uppercased()
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
      let load = format.load(pounds: set.weight, for: exercise).uppercased()
      return LiftReceiptLineSnapshot(
        id: set.id,
        ordinal: index + 1,
        exerciseID: set.exerciseID,
        exerciseName: (exercise?.name ?? String(localized: "Exercise unavailable")).uppercased(),
        loadLabel: "\(load) × \(set.reps)",
        statusLabel: statusLabel,
        volumeLabel: usesBodyweight ? LiftFormat.missing : format.volume(pounds: set.volume).uppercased(),
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
  @Environment(\.liftFormat) private var format

  let session: LiftSession

  var body: some View {
    let snapshot = snapshot
    ScrollView {
      VStack(spacing: 0) {
        ReceiptEdge(flipped: true)
        ReceiptSheet {
          ReceiptHeader(
            title: String(localized: "Live Receipt"),
            subtitle: currentSession.title,
            trailing: receiptNumber
          )
          ReceiptDashedRule()
          ReceiptColumns(
            title: String(localized: "Exercise"), value: String(localized: "Volume (\(format.unitSymbol))"))
          ReceiptDashedRule()
          LiveReceiptRows(snapshot: snapshot)
          LiveReceiptTotals(
            session: currentSession,
            workingSetCount: snapshot.workingSetCount,
            totalVolume: snapshot.totalVolume
          )
        }
        ReceiptEdge()
      }
      .padding(.horizontal, LiftChromeMetrics.gutter)
      .padding(.vertical, 18)
      .frame(maxWidth: LiftChromeMetrics.maxColumnWidth)
      .frame(maxWidth: .infinity)
    }
    .scrollIndicators(.hidden)
    .background(StrandPalette.appCanvas.ignoresSafeArea())
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
      targetSetsByExerciseID: targets,
      format: format
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
      Text("Sets print here as you log them.")
        .textCase(.uppercase)
        .font(.receiptArtifact(11, weight: .bold))
        .foregroundStyle(LiftTheme.Receipt.inkSecondary)
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
  @Environment(\.liftFormat) private var format
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
        (String(localized: "Sets"), displayedWorkingSetCount.formatted(.number.locale(format.locale))),
        (String(localized: "Total volume"), format.volume(pounds: displayedTotalVolume)),
        (String(localized: "Duration"), LiftFormat.clockDuration(duration(at: context.date))),
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
