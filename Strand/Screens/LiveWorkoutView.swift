import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Combine

#if os(iOS)
/// The live workout, built to be read in under a second: a header (Minimize, what is recording, two signal glyphs), a notice
/// slot that is always there, one page with the session's big number, and a dock with Pause (or Resume and Hold to end).
///
/// It is the root of the workout journey's cover, not a sheet, so there is nothing to swipe away: the top-left control
/// minimizes, and the recording goes on.
///
/// The environment wrapper receives AppModel's high-frequency notifications, but its expensive/static content is
/// Equatable and identity-stable. Only the dedicated leaves (the page, the dock, the notice slot, the glyphs) observe the
/// workout and continue updating for every available HR sample.
struct LiveWorkoutView: View {
    @EnvironmentObject private var model: AppModel
    /// Minimizes: hides the workout screen while the recording keeps running.
    let onClose: () -> Void

    var body: some View {
        LiveWorkoutScreen(model: model, workout: model.activeWorkout, onMinimize: onClose)
            .equatable()
            .tracksWorkoutSurface()
    }
}

struct LiveWorkoutScreen: View, @preconcurrency Equatable {
    let model: AppModel
    let workout: AppModel.ActiveWorkout?
    /// Not part of equality: it only flips presentation state in the host, so a fresh closure from a host re-render must not
    /// rebuild the content.
    let onMinimize: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.workout === rhs.workout
    }

    var body: some View {
        if let workout {
            LiveWorkoutLayout(model: model, workout: workout, onMinimize: onMinimize)
        } else {
            StrandPalette.appCanvas.ignoresSafeArea()
        }
    }
}

private struct LiveWorkoutLayout: View {
    let model: AppModel
    @ObservedObject var workout: AppModel.ActiveWorkout
    let onMinimize: () -> Void

    var body: some View {
        // Three regions, top to bottom: the header and notice (as tall as they are), the dock (as tall as its buttons, never
        // more than a share of the screen) and, between them, the page, which gets the rest and scrolls only when it does
        // not fit. `LiveWorkoutRegions` does the arithmetic, so the dock hugs its content at every size.
        LiveWorkoutRegions {
            VStack(spacing: 0) {
                LiveWorkoutHeader(model: model, workout: workout, recorder: model.gpsRecorder, onMinimize: onMinimize)
                    .screenPadding()
                LiveNoticeSlot(model: model, workout: workout, recorder: model.gpsRecorder)
                    .screenPadding()
            }
            ScrollView {
                LiveFocusPage(workout: workout, recorder: model.gpsRecorder, profile: model.profile, live: model.live)
                    .screenPadding()
                    .padding(.vertical, NoopMetrics.space2)
            }
            .scrollBounceBehavior(.basedOnSize)
            WorkoutLiveDock(model: model, workout: workout, recorder: model.gpsRecorder)
                .screenPadding()
                .padding(.top, NoopMetrics.space3)
                .padding(.bottom, NoopMetrics.space2)
                .background(StrandPalette.appCanvas.ignoresSafeArea(edges: .bottom))
                .overlay(alignment: .top) {
                    Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.appCanvas.ignoresSafeArea())
        .onAppear { model.startRealtimeHR() }
        .onDisappear { model.stopRealtimeHR() }
    }
}

/// Lays the live screen out in three stacked regions: chrome, page, dock.
///
/// The chrome and the dock are given the height they ask for, so a dock that holds one button is one button tall and the
/// header is never squeezed. What the dock may take has a ceiling: the page keeps `minimumPage`, enough for the focus numeral
/// (a fixed 132 pt, whatever the text size) and its eyebrow. A taller dock (accessibility sizes, a long translation) is
/// proposed the height that is left and scrolls its own text or buttons. The page takes everything the dock does not.
private struct LiveWorkoutRegions: Layout {
    /// The page's least height: the focus eyebrow, the numeral and the air round them.
    static let minimumPage: CGFloat = 220
    /// The dock always keeps at least this share of the height, so a very short screen still shows its buttons.
    static let minimumDockShare: CGFloat = 0.35

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let width = bounds.width
        let chrome = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let dockWanted = subviews[2].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let dockCeiling = max(bounds.height - chrome - Self.minimumPage, bounds.height * Self.minimumDockShare)
        let dock = min(dockWanted, dockCeiling)
        let page = max(0, bounds.height - chrome - dock)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: chrome))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + chrome), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: page))
        subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.maxY - dock), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: dock))
    }
}

// MARK: - Header

/// Minimize on the left, what is recording in the middle (with its pulse), the signal glyphs on the right. Minimize is
/// never "Close": the recording keeps going. It is unavailable only while a save is running.
private struct LiveWorkoutHeader: View {
    let model: AppModel
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    let onMinimize: () -> Void
    @StateObject private var finish: FinishStateWatcher
    @Environment(\.dynamicTypeSize) private var typeSize

    init(model: AppModel, workout: AppModel.ActiveWorkout, recorder: GpsWorkoutRecorder, onMinimize: @escaping () -> Void) {
        self.model = model
        self.workout = workout
        self.recorder = recorder
        self.onMinimize = onMinimize
        _finish = StateObject(wrappedValue: FinishStateWatcher(model: model))
    }

    var body: some View {
        let saving = finish.isSaving
        HStack(spacing: NoopMetrics.space2) {
            Button(action: onMinimize) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(StrandPalette.surfaceRaised,
                                in: RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
                        .strokeBorder(StrandPalette.cardBorder, lineWidth: 1))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(saving)
            .opacity(saving ? 0.4 : 1)
            .accessibilityLabel("Minimize")
            .accessibilityHint("The workout keeps recording.")
            Spacer(minLength: NoopMetrics.space2)
            overline
            Spacer(minLength: NoopMetrics.space2)
            LiveSignalGlyphs(model: model, workout: workout, recorder: recorder)
        }
        .frame(minHeight: 44)
        // VoiceOver's two-finger scrub minimizes, as it dismisses a sheet.
        .accessibilityAction(.escape) { if !saving { onMinimize() } }
    }

    /// What is happening: the sport while it records; "Paused · 0:42" with the pause counting up, so a pocketed phone says how
    /// long it has been stopped; "Ending" once End was held. The pulse is the one rule every surface shares.
    @ViewBuilder private var overline: some View {
        let paused = workout.isPaused
        let ending = workout.isEnding
        HStack(spacing: NoopMetrics.space2) {
            EyebrowPulseIcon(systemName: paused ? "pause.fill" : "waveform.path.ecg",
                             color: paused ? StrandPalette.statusWarning : StrandPalette.liveRed,
                             pulses: NOOPLiveWorkoutPulse.isActive(isPaused: paused, isEnding: ending))
            if ending {
                Text("Ending").strandOverlineFitted().lineLimit(2)
            } else if paused, let since = workout.pauseLedger.openSince {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince1970 - since))
                    Text("Paused · \(LiveWorkoutTiles.elapsedText(TimeInterval(seconds)))")
                        .strandOverlineFitted().lineLimit(2)
                        .accessibilityLabel(Text("Paused for \(LiveWorkoutTiles.spokenElapsed(TimeInterval(seconds)))"))
                }
            } else if paused {
                Text("Paused").strandOverlineFitted().lineLimit(2)
            } else {
                Text(verbatim: WorkoutSource.displaySport(workout.sport)).strandOverlineFitted().lineLimit(2)
            }
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Publishes only whether a save is running, so the header does not redraw for every other thing the model announces.
@MainActor
private final class FinishStateWatcher: ObservableObject {
    @Published private(set) var isSaving = false
    private var token: Any?

    init(model: AppModel) {
        isSaving = model.workoutFinishState == .saving
        token = model.$workoutFinishState
            .map { $0 == .saving }
            .removeDuplicates()
            .sink { [weak self] saving in self?.isSaving = saving }
    }
}
#endif
