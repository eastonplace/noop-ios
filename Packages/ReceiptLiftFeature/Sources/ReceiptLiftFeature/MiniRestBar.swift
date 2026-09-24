import SwiftUI

struct LiftMiniRestSnapshot: Equatable, Sendable {
  let endDate: Date?
  let remainingSeconds: Int

  nonisolated init(endDate: Date?, remainingSeconds: Int) {
    self.endDate = endDate
    self.remainingSeconds = max(remainingSeconds, 0)
  }

  nonisolated init(endDate: Date?, now: Date) {
    self.endDate = endDate
    self.remainingSeconds = max(
      Int(ceil(endDate?.timeIntervalSince(now) ?? 0)),
      0
    )
  }

  nonisolated var isVisible: Bool {
    endDate != nil && remainingSeconds > 0
  }
}

nonisolated func liftMiniRestShouldDiscardExpired(endDate: Date?, now: Date) -> Bool {
  guard let endDate else { return false }
  return endDate <= now
}

nonisolated func liftMiniRestShouldEmitCompletion(
  endDate: Date?,
  previousRemainingSeconds: Int,
  remainingSeconds: Int,
  emittedEndDate: Date?
) -> Bool {
  guard let endDate else { return false }
  return previousRemainingSeconds > 0
    && remainingSeconds == 0
    && emittedEndDate != endDate
}

struct MiniRestBar: View {
  @Environment(\.scenePhase) private var scenePhase
  @EnvironmentObject private var store: LiftStore
  var compact = false
  let onPresentOptions: () -> Void

  var body: some View {
    if let endDate = store.restTimerEndDate {
      MiniRestTimeline(
        endDate: endDate,
        compact: compact,
        onPresentOptions: onPresentOptions,
        onAdjust: store.adjustRestTimer,
        onSkip: store.skipRestTimer,
        onComplete: completeRest
      )
      .task(id: endDate) {
        discardExpiredTimerIfNeeded(endDate: endDate)
      }
      .onChange(of: scenePhase) { _, phase in
        guard phase == .active else { return }
        discardExpiredTimerIfNeeded(endDate: endDate)
      }
    }
  }

  private func discardExpiredTimerIfNeeded(endDate: Date) {
    guard liftMiniRestShouldDiscardExpired(endDate: endDate, now: Date()) else { return }
    store.skipRestTimer()
  }

  private func completeRest() {
    LiftHaptics.setLogged(enabled: store.settings.hapticsEnabled)
    store.skipRestTimer()
  }
}

struct MiniRestOptionsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: LiftStore

  private let presets: [TimeInterval] = [30, 45, 60, 75, 90, 120, 150, 180]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text("REST OPTIONS")
            .font(.receipt(10, weight: .bold))
            .foregroundStyle(LiftTheme.inkSecondary)
          Text(store.workoutRestOverrideSeconds.map(liftDuration) ?? "USE PLAN")
            .font(.receipt(24, weight: .black))
            .foregroundStyle(LiftTheme.ink)
            .monospacedDigit()
        }
        Spacer(minLength: 8)
        Button("Close", systemImage: "xmark") {
          dismiss()
        }
        .labelStyle(.iconOnly)
        .frame(width: 44, height: 44)
        .buttonStyle(ReceiptIconButtonStyle())
        .accessibilityLabel("Close rest options")
      }

      ReceiptDashedRule()

      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
        spacing: 6
      ) {
        ForEach(presets, id: \.self) { seconds in
          MiniRestPresetButton(
            seconds: seconds,
            isSelected: store.workoutRestOverrideSeconds == seconds
          ) {
            store.setWorkoutRestOverride(seconds: seconds)
          }
        }
      }

      Button("USE ROUTINE PLAN", systemImage: "arrow.uturn.left") {
        store.setWorkoutRestOverride(seconds: nil)
      }
      .font(.receipt(10, weight: .black))
      .foregroundStyle(LiftTheme.ink)
      .frame(maxWidth: .infinity, minHeight: 44)
      .buttonStyle(.plain)
      .overlay {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .stroke(LiftTheme.ink.opacity(0.35), lineWidth: 1)
      }
      .accessibilityHint("Clears the workout rest override")
    }
    .padding(.horizontal, 16)
    .padding(.top, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(LiftTheme.paper.ignoresSafeArea())
  }
}

private struct MiniRestTimeline: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let endDate: Date
  let compact: Bool
  let onPresentOptions: () -> Void
  let onAdjust: (TimeInterval) -> Void
  let onSkip: () -> Void
  let onComplete: () -> Void
  @State private var emittedEndDate: Date?

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let snapshot = LiftMiniRestSnapshot(endDate: endDate, now: context.date)

      Group {
        if snapshot.isVisible {
          MiniRestBarContent(
            endDate: endDate,
            now: context.date,
            compact: compact,
            onPresentOptions: onPresentOptions,
            onSubtract: { onAdjust(-15) },
            onSkip: skip,
            onAdd: { onAdjust(15) }
          )
          .transition(
            reduceMotion
              ? .opacity
              : .move(edge: .bottom).combined(with: .opacity)
          )
        }
      }
      .animation(
        reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.surface,
        value: snapshot.isVisible
      )
      .onChange(of: snapshot.remainingSeconds) { previous, remaining in
        guard liftMiniRestShouldEmitCompletion(
          endDate: endDate,
          previousRemainingSeconds: previous,
          remainingSeconds: remaining,
          emittedEndDate: emittedEndDate
        ) else { return }
        emittedEndDate = endDate
        withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.surface) {
          onComplete()
        }
      }
    }
  }

  private func skip() {
    withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.surface) {
      onSkip()
    }
  }
}

private struct MiniRestBarContent: View {
  let endDate: Date
  let now: Date
  let compact: Bool
  let onPresentOptions: () -> Void
  let onSubtract: () -> Void
  let onSkip: () -> Void
  let onAdd: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      restIdentity
      Spacer(minLength: 4)
      controls
    }
    .padding(
      .horizontal,
      compact
        ? LiftDesignMetrics.RestBar.inlineHorizontalPadding
        : LiftDesignMetrics.RestBar.horizontalPadding
    )
    .frame(height: LiftDesignMetrics.RestBar.height)
    .background(
      LiftTheme.ink,
      in: RoundedRectangle(
        cornerRadius: LiftDesignMetrics.RestBar.cornerRadius,
        style: .continuous
      )
    )
  }

  private var restIdentity: some View {
    HStack(spacing: 6) {
      Text("REST")
        .font(.receipt(LiftDesignMetrics.RestBar.eyebrowFontSize, weight: .black))
        .foregroundStyle(LiftTheme.paper.opacity(0.66))
      Button(action: onPresentOptions) {
        Text(timerInterval: now...endDate, countsDown: true, showsHours: false)
          .font(.receipt(LiftDesignMetrics.RestBar.timerFontSize, weight: .black))
          .foregroundStyle(LiftTheme.paper)
          .monospacedDigit()
          .frame(minWidth: 54, minHeight: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Rest timer")
      .accessibilityValue(liftDuration(max(endDate.timeIntervalSince(now), 0)))
      .accessibilityHint("Opens rest options")
    }
  }

  private var controls: some View {
    HStack(spacing: 4) {
      miniButton("−15", accessibilityLabel: "Subtract 15 seconds", action: onSubtract)
      miniButton("SKIP", accessibilityLabel: "Skip rest", action: onSkip)
      miniButton("+15", accessibilityLabel: "Add 15 seconds", action: onAdd)
    }
  }

  private func miniButton(
    _ title: String,
    accessibilityLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(title, action: action)
      .font(.receipt(LiftDesignMetrics.RestBar.actionFontSize, weight: .black))
      .foregroundStyle(LiftTheme.paper)
      .frame(minWidth: 44, minHeight: 44)
      .contentShape(Rectangle())
      .buttonStyle(.plain)
      .accessibilityLabel(accessibilityLabel)
  }
}

private struct MiniRestPresetButton: View {
  let seconds: TimeInterval
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(liftDuration(seconds))
        .font(.receipt(10, weight: .black))
        .foregroundStyle(isSelected ? LiftTheme.paper : LiftTheme.ink)
        .monospacedDigit()
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(
          isSelected ? LiftTheme.ink : LiftTheme.ink.opacity(0.06),
          in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(LiftTheme.ink.opacity(isSelected ? 1 : 0.2), lineWidth: 1)
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Set next rest to \(liftDuration(seconds))")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
