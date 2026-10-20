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
        lastCompletedAt: store.activeSession?.sets.map(\.completedAt).max(),
        defaultRestSeconds: store.defaultRestSeconds,
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
  let lastCompletedAt: Date?
  let defaultRestSeconds: TimeInterval
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
            display: LiftRestDisplay.make(
              restTimerEndDate: endDate, lastCompletedAt: lastCompletedAt,
              defaultRestSeconds: defaultRestSeconds, now: context.date),
            onPresentOptions: onPresentOptions,
            onSkip: skip,
            onAdd: { onAdjust(30) }
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

/// The REST card: the countdown over the rest it was meant to be ("1:24 / 2:00", a tap opens the presets), "+30s" and
/// Skip as compact 30pt chips (their tap areas reach 44pt), and a bar that fills as the rest runs out. From the
/// accessibility text sizes up the controls take a row of their own so the countdown keeps its whole width.
private struct MiniRestBarContent: View {
  let endDate: Date
  let now: Date
  let display: LiftRestDisplay?
  let onPresentOptions: () -> Void
  let onSkip: () -> Void
  let onAdd: () -> Void

  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.liftFormat) private var format
  @ScaledMetric(relativeTo: .title) private var timerSize: CGFloat = 20
  @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 12
  @ScaledMetric(relativeTo: .footnote) private var totalSize: CGFloat = 13.5

  var body: some View {
    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
      if typeSize.isAccessibilitySize {
        identity
        controls
      } else {
        HStack(alignment: .center, spacing: NoopMetrics.space2) {
          identity
          Spacer(minLength: NoopMetrics.space2)
          controls
        }
      }
      bar
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
    .accessibilityElement(children: .contain)
  }

  private var identity: some View {
    Button(action: onPresentOptions) {
      HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space5) {
        Text("Rest")
          .textCase(.uppercase)
          .tracking(1.6)
          .font(StrandFont.sized(labelSize, weight: .bold))
          .foregroundStyle(StrandPalette.textTertiary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
        // The countdown and the rest it was meant to be read as one figure, "1:24 / 2:00", one space apart.
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(timerInterval: now...max(endDate, now), countsDown: true, showsHours: false)
            .font(StrandFont.sized(timerSize, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
          if let display {
            Text(verbatim: "/ " + LiftFormat.duration(TimeInterval(display.totalSeconds)))
              .font(StrandFont.sized(totalSize, weight: .regular))
              .monospacedDigit()
              .foregroundStyle(StrandPalette.textSecondary)
              .lineLimit(1)
          }
        }
      }
      // Drawn as tall as the 30pt chips beside it; the tap area reaches 44pt.
      .frame(minHeight: 30, alignment: .leading)
      .contentShape(Rectangle().inset(by: -7))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Rest timer")
    .accessibilityValue(format.spokenDuration(max(endDate.timeIntervalSince(now), 0)))
    .accessibilityHint("Opens rest options")
  }

  private var controls: some View {
    HStack(spacing: 6) {
      RestChip(title: "+30s", accessibilityLabel: Text("Add 30 seconds"), action: onAdd)
      RestChip(title: String(localized: "Skip"), accessibilityLabel: Text("Skip rest"), action: onSkip)
    }
  }

  private var bar: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule(style: .continuous).fill(StrandPalette.surfaceInset)
        Capsule(style: .continuous).fill(StrandPalette.solidFill)
          .frame(width: proxy.size.width * CGFloat(display?.fraction ?? 0))
      }
    }
    .frame(height: 5)
    .accessibilityHidden(true)
  }
}

/// A compact chip of the REST card (the approved design's 30pt chip: 13pt semibold, 11pt side padding, a 1pt hairline).
/// Its tap area reaches 44pt without the card growing. `title` is already in the person's language.
private struct RestChip: View {
  let title: String
  let accessibilityLabel: Text
  let action: () -> Void

  @ScaledMetric(relativeTo: .footnote) private var textSize: CGFloat = 13

  var body: some View {
    Button(action: action) {
      Text(verbatim: title)
        .font(StrandFont.sized(textSize, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(StrandPalette.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 11)
        .frame(minHeight: 30)
        .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1))
        .contentShape(Rectangle().inset(by: -7))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
  }
}

private struct MiniRestPresetButton: View {
  @Environment(\.liftFormat) private var format
  let seconds: TimeInterval
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    LiftTimerPill(
      title: LiftFormat.duration(seconds), isSelected: isSelected, fillsWidth: true,
      accessibilityLabel: Text("Set next rest to \(format.spokenDuration(seconds))"), action: action
    )
  }
}
