import StrandDesign
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
    LiftScreen(
      title: "Rest options",
      subtitle: LocalizedStringKey(
        store.workoutRestOverrideSeconds.map { "Next rest \(liftDuration($0))" } ?? "Using the routine plan"
      ),
      trailing: {
        NoopIconButton("xmark", accessibilityLabel: "Close rest options") { dismiss() }
      }
    ) {
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
        spacing: 8
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

      NoopButton("Use routine plan", systemImage: "arrow.uturn.left", kind: .secondary, fullWidth: true) {
        store.setWorkoutRestOverride(seconds: nil)
      }
      .accessibilityHint("Clears the workout rest override")
    }
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
      StrandPalette.surfaceInset,
      in: RoundedRectangle(
        cornerRadius: LiftDesignMetrics.RestBar.cornerRadius,
        style: .continuous
      )
    )
    .overlay(
      RoundedRectangle(
        cornerRadius: LiftDesignMetrics.RestBar.cornerRadius,
        style: .continuous
      )
      .strokeBorder(StrandPalette.hairline, lineWidth: 1)
    )
  }

  private var restIdentity: some View {
    HStack(spacing: 6) {
      Text("Rest")
        .strandOverline()
      Button(action: onPresentOptions) {
        Text(timerInterval: now...endDate, countsDown: true, showsHours: false)
          .font(StrandFont.number(LiftDesignMetrics.RestBar.timerFontSize, weight: .bold))
          .foregroundStyle(StrandPalette.textPrimary)
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
    HStack(spacing: 0) {
      miniButton("−15", accessibilityLabel: "Subtract 15 seconds", action: onSubtract)
      miniButton("Skip", accessibilityLabel: "Skip rest", action: onSkip)
      miniButton("+15", accessibilityLabel: "Add 15 seconds", action: onAdd)
    }
  }

  private func miniButton(
    _ title: String,
    accessibilityLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(title, action: action)
      .font(StrandFont.caption.weight(.semibold))
      .foregroundStyle(StrandPalette.link)
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
    }
    .buttonStyle(NoopButtonStyle(isSelected ? .primary : .secondary, fullWidth: true))
    .accessibilityLabel("Set next rest to \(liftDuration(seconds))")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
