import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Combine

#if os(iOS)
/// The live workout, built to be read in under a second, in the language of a watch face: pure black, a header (Minimize, the
/// sport with its state under it, the strap and GPS glyphs), one page of figures with the dots under it, and a dock of calm
/// circles (Pause; or Hold to End and Resume). A notice drops in under the header and takes no room from the figures.
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
    /// Where the workout's last page is kept, so a return finds the wearer on it. nil keeps none.
    var pageMemory: WorkoutPageMemory?

    var body: some View {
        LiveWorkoutScreen(model: model, workout: model.activeWorkout, pageMemory: pageMemory, onMinimize: onClose)
            .equatable()
            .tracksWorkoutSurface()
    }
}

struct LiveWorkoutScreen: View, @preconcurrency Equatable {
    let model: AppModel
    let workout: AppModel.ActiveWorkout?
    let pageMemory: WorkoutPageMemory?
    /// Not part of equality: it only flips presentation state in the host, so a fresh closure from a host re-render must not
    /// rebuild the content.
    let onMinimize: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.workout === rhs.workout
    }

    var body: some View {
        if let workout {
            LiveWorkoutLayout(model: model, workout: workout, pageMemory: pageMemory, onMinimize: onMinimize)
        } else {
            LivePalette.canvas.ignoresSafeArea()
        }
    }
}

private struct LiveWorkoutLayout: View {
    let model: AppModel
    @ObservedObject var workout: AppModel.ActiveWorkout
    let pageMemory: WorkoutPageMemory?
    let onMinimize: () -> Void
    @State private var showsDevices = false

    var body: some View {
        // Four regions, top to bottom: the header (as tall as it is), the dock (as tall as its circles, never more than a
        // share of the screen) and, between them, the pager, which gets the rest. The notice hangs under the header over the
        // top of the page and takes no height from it. `LiveWorkoutRegions` does the arithmetic.
        LiveWorkoutRegions {
            LiveWorkoutHeader(model: model, workout: workout, recorder: model.gpsRecorder, onMinimize: onMinimize)
                .screenPadding()
                .zIndex(1)
            // Above the page: the notice and its expanded explanation have to be readable and tappable.
            LiveNoticeSlot(model: model, workout: workout, recorder: model.gpsRecorder,
                           onManageDevices: { showsDevices = true })
                .screenPadding()
                .zIndex(2)
            LiveWorkoutPager(model: model, workout: workout, recorder: model.gpsRecorder, pageMemory: pageMemory,
                             onManageDevices: { showsDevices = true })
            WorkoutLiveDock(model: model, workout: workout, recorder: model.gpsRecorder)
                .screenPadding()
                .padding(.top, NoopMetrics.space2)
                .padding(.bottom, NoopMetrics.space2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LivePalette.canvas.ignoresSafeArea())
        // VoiceOver's two-finger scrub minimizes, as it dismisses a sheet: from wherever focus is on the screen, not only the
        // header. Unavailable while a save runs, like the Minimize button.
        .accessibilityAction(.escape) { if model.workoutFinishState != .saving { onMinimize() } }
        .onAppear { model.startRealtimeHR() }
        .onDisappear { model.stopRealtimeHR() }
        // Manage devices, from the heart page: a sheet inside the cover, not a second full-screen surface.
        .sheet(isPresented: $showsDevices) { WorkoutDevicesSheet(onClose: { showsDevices = false }) }
    }
}

/// Lays the live screen out: header, notice, page, dock.
///
/// The header and the dock are given the height they ask for, so a dock that holds one circle is one circle tall and the header
/// is never squeezed. What the dock may take has a ceiling: the page keeps `minimumPage`, enough for the smallest figures and
/// the notice band. A taller dock (accessibility sizes, a long translation) is proposed the height that is left and scrolls
/// its own text. The page takes everything the dock does not. The notice is placed under the header, over the page's top,
/// at the height it needs (nothing when there is no notice): it never moves the page.
private struct LiveWorkoutRegions: Layout {
    /// The page's least height: the notice band, the smallest figures and the air round them.
    static let minimumPage: CGFloat = 270
    /// The dock always keeps at least this share of the height, so a very short screen still shows its controls.
    static let minimumDockShare: CGFloat = 0.35

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        let width = bounds.width
        let header = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let dockWanted = subviews[3].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let dockCeiling = max(bounds.height - header - Self.minimumPage, bounds.height * Self.minimumDockShare)
        let dock = min(dockWanted, dockCeiling)
        let page = max(0, bounds.height - header - dock)
        let notice = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: page)).height
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: header))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + header), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: notice))
        subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.minY + header), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: page))
        subviews[3].place(at: CGPoint(x: bounds.minX, y: bounds.maxY - dock), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: dock))
    }
}

// MARK: - Header

/// Minimize on the left, the sport in the middle with what it is doing under it (the state line), the strap and GPS glyphs
/// in a capsule on the right. Minimize is never "Close": the recording keeps going. It is unavailable only while a save runs.
private struct LiveWorkoutHeader: View {
    let model: AppModel
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    let onMinimize: () -> Void
    @StateObject private var finish: FinishStateWatcher
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The two ends are the same width so the title stays centred between them.
    private static let sideWidth: CGFloat = 84

    init(model: AppModel, workout: AppModel.ActiveWorkout, recorder: GpsWorkoutRecorder, onMinimize: @escaping () -> Void) {
        self.model = model
        self.workout = workout
        self.recorder = recorder
        self.onMinimize = onMinimize
        _finish = StateObject(wrappedValue: FinishStateWatcher(model: model))
    }

    var body: some View {
        let saving = finish.isSaving
        HStack(alignment: .center, spacing: NoopMetrics.space2) {
            Button(action: onMinimize) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(LivePalette.fill))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(saving)
            .opacity(saving ? 0.4 : 1)
            .frame(width: Self.sideWidth, alignment: .leading)
            .accessibilityLabel("Minimize")
            .accessibilityHint("The workout keeps recording.")
            titleColumn.frame(maxWidth: .infinity)
            LiveSignalGlyphs(model: model, workout: workout, recorder: recorder)
                .frame(width: Self.sideWidth, alignment: .trailing)
        }
        .frame(minHeight: 44)
        .padding(.top, 2)
    }

    private var titleColumn: some View {
        VStack(spacing: 3) {
            Text(verbatim: WorkoutSportTitle.name(for: workout.sport))
                .foregroundStyle(StrandPalette.textPrimary)
                .liveText(17, weight: .semibold, maxSize: 24, lines: 2)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            stateLine
        }
    }

    /// What is happening, the same word for every sport (the title above it says which): "● Recording" in mint with the pulse every surface shares; "Paused · 0:42" in amber with the pause
    /// counting up, so a pocketed phone says how long it has been stopped (at the accessibility sizes it breaks as "Paused"
    /// over "0:42", never leaving a "·" alone); "Ending" once End was held.
    @ViewBuilder private var stateLine: some View {
        if workout.isEnding {
            Text("Ending")
                .foregroundStyle(LivePalette.secondaryText)
                .liveText(13, weight: .medium, maxSize: 19, lines: 1)
        } else if workout.isPaused {
            if let since = workout.pauseLedger.openSince {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince1970 - since))
                    pausedLine(clock: LiveWorkoutTiles.elapsedText(TimeInterval(seconds)))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Paused for \(LiveWorkoutTiles.spokenElapsed(TimeInterval(seconds)))"))
                }
            } else {
                pausedLine(clock: nil)
            }
        } else {
            HStack(spacing: 6) {
                LiveStateDot(color: LivePalette.mint,
                             pulses: NOOPLiveWorkoutPulse.isActive(isPaused: false, isEnding: false))
                Text("Recording")
                    .foregroundStyle(LivePalette.mint)
                    .liveText(13, weight: .medium, maxSize: 19, lines: 1)
            }
        }
    }

    private func pausedLine(clock: String?) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 0))
            : AnyLayout(HStackLayout(spacing: 5))
        return layout {
            HStack(spacing: 5) {
                Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold))
                Text("Paused").liveText(13, weight: .medium, maxSize: 19, lines: 1)
            }
            if let clock {
                if !typeSize.isAccessibilitySize { Text(verbatim: "·").liveText(13, weight: .medium, maxSize: 19, lines: 1) }
                Text(verbatim: clock).monospacedDigit().liveText(13, weight: .medium, maxSize: 19, lines: 1)
            }
        }
        .foregroundStyle(LivePalette.amber)
    }
}

/// The small dot before "Recording": mint, with a ghost that swells and fades while the workout records (off under Reduce
/// Motion).
struct LiveStateDot: View {
    let color: Color
    let pulses: Bool
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if pulses && !reduceMotion {
                Circle().fill(color.opacity(0.5))
                    .frame(width: 7, height: 7)
                    .scaleEffect(breathing ? 2.4 : 1)
                    .opacity(breathing ? 0 : 0.8)
            }
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 9, height: 9)
        .onAppear {
            guard pulses, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { breathing = true }
        }
        .accessibilityHidden(true)
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
