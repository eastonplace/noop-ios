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
  let onPresentOptions: () -> Void

  var body: some View {
    if let endDate = store.restTimerEndDate {
      MiniRestTimeline(
        endDate: endDate,
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

/// The rest presets and the routine-plan default: how long the next rest runs.
struct MiniRestOptionsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.liftFormat) private var format
  @EnvironmentObject private var store: LiftStore

  @Environment(\.dynamicTypeSize) private var typeSize
  private let presets: [TimeInterval] = [30, 45, 60, 75, 90, 120, 150, 180]

  var body: some View {
    LiftSheetPage(title: "Rest options", onClose: { dismiss() }) {
      LiftFlatSection("Next rest", systemImage: "timer") {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
          if let override = store.workoutRestOverrideSeconds {
            LiftNote(text: "Next rest \(LiftFormat.duration(override))")
          } else {
            LiftNote(text: "Using the routine plan")
          }
          LazyVGrid(
            columns: Array(
              repeating: GridItem(.flexible(), spacing: NoopMetrics.space2), count: typeSize.isAccessibilitySize ? 2 : 4),
            spacing: NoopMetrics.space2
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
          Button {
            store.setWorkoutRestOverride(seconds: nil)
          } label: {
            Label("Use routine plan", systemImage: "arrow.uturn.left")
          }
          .buttonStyle(PrimaryPillButtonStyle(looksUnavailable: store.workoutRestOverrideSeconds == nil))
          .accessibilityHint("Clears the workout rest override")
        }
      }
    }
  }
}

private struct MiniRestTimeline: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let endDate: Date
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

/// The running rest: the countdown (a tap opens the presets) and the three ways to change it. Side by side from regular
/// text up to the largest standard size; stacked beyond, so the countdown keeps its whole width.
private struct MiniRestBarContent: View {
  let endDate: Date
  let now: Date
  let onPresentOptions: () -> Void
  let onSubtract: () -> Void
  let onSkip: () -> Void
  let onAdd: () -> Void

  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.liftFormat) private var format
  @ScaledMetric(relativeTo: .title) private var timerSize: CGFloat = 34

  var body: some View {
    Group {
      if typeSize >= .xxxLarge {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
          identity
          controls
        }
      } else {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
          identity
          Spacer(minLength: NoopMetrics.space2)
          controls
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
  }

  private var identity: some View {
    Button(action: onPresentOptions) {
      VStack(alignment: .leading, spacing: 0) {
        Text("Rest timer").font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        Text(timerInterval: now...endDate, countsDown: true, showsHours: false)
          .font(StrandFont.number(timerSize, weight: .bold))
          .foregroundStyle(StrandPalette.textPrimary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
      .frame(minWidth: 72, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Rest timer")
    .accessibilityValue(format.spokenDuration(max(endDate.timeIntervalSince(now), 0)))
    .accessibilityHint("Opens rest options")
  }

  private var controls: some View {
    HStack(spacing: NoopMetrics.space2) {
      restChip("−15", accessibilityLabel: "Subtract 15 seconds", action: onSubtract)
      restChip(String(localized: "Skip"), accessibilityLabel: "Skip rest", action: onSkip)
      restChip("+15", accessibilityLabel: "Add 15 seconds", action: onAdd)
    }
  }

  private func restChip(_ title: String, accessibilityLabel: LocalizedStringKey, action: @escaping () -> Void) -> some View {
    LiftTimerPill(title: title, accessibilityLabel: Text(accessibilityLabel), action: action)
  }
}

private struct MiniRestPresetButton: View {
  @Environment(\.liftFormat) private var format
  let seconds: TimeInterval
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    LiftTimerPill(
      title: LiftFormat.duration(seconds), isSelected: isSelected,
      accessibilityLabel: Text("Set next rest to \(format.spokenDuration(seconds))"), action: action
    )
    .frame(maxWidth: .infinity)
  }
}
