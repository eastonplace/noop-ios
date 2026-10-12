#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - The notice slot and the signal glyphs
//
// Nothing on the live screen moves when a signal changes. A problem shows in two places that always exist: a glyph in
// the header, and a slot under it that is reserved even when it is empty, so the numbers below never shift.

/// One thing the slot can say, highest priority first.
enum LiveWorkoutSlotNotice: Equatable, Sendable, CaseIterable {
    case durability, heartRate, gpsLost, gpsWeak, gpsSearching, noStrap, locationOff, gpsGap

    struct Inputs: Equatable {
        /// Data that is not safely recoverable. A workout restored after the app was closed is `gpsGapRestoredAt`, not this.
        var hasDurabilityWarning = false
        var gpsGapIsRecent = false
        var heartRateIsStale = false
        var strapNeverConnected = false
        var gps: GpsWorkoutRecorder.SignalState?
        var locationIsOff = false
        /// The workout began a moment ago: "Location is off" is said then, and afterwards only by the header glyph.
        var isJustStarted = false
    }

    /// How long after the start "Location is off · no route" is spoken before it leaves the glyph to say it.
    static let locationNoticeSeconds: TimeInterval = 10
    /// How long after a restore "GPS gap while closed" is said. The header glyph and the page carry on without it.
    static let gpsGapNoticeSeconds: TimeInterval = 30

    /// The notices that apply now, in the order the slot shows them: the durability warning, the signals that went quiet, a
    /// strap that never connected, and a location that is off. The slot is for warnings only: that the workout is paused is
    /// the header's to say ("PAUSED · 3:11"), not a pill's. A strap that never connected replaces "No
    /// heart-rate signal": there is no strap to wait for, and the other says what to do.
    static func pending(_ inputs: Inputs) -> [LiveWorkoutSlotNotice] {
        var result: [LiveWorkoutSlotNotice] = []
        if inputs.hasDurabilityWarning { result.append(.durability) }
        if inputs.heartRateIsStale && !inputs.strapNeverConnected { result.append(.heartRate) }
        switch inputs.gps {
        case .lost: result.append(.gpsLost)
        case .weak: result.append(.gpsWeak)
        case .searching: result.append(.gpsSearching)
        case .ok, .paused, .notRecording, nil: break
        }
        if inputs.strapNeverConnected { result.append(.noStrap) }
        if inputs.locationIsOff && inputs.isJustStarted { result.append(.locationOff) }
        if inputs.gpsGapIsRecent { result.append(.gpsGap) }
        return result
    }

    var title: LocalizedStringKey {
        switch self {
        case .durability: "Not safely recoverable"
        case .heartRate: "No heart-rate signal"
        case .gpsLost: "GPS signal lost"
        case .gpsWeak: "Weak GPS signal"
        case .gpsSearching: "Searching for GPS"
        case .noStrap: "No strap connected"
        case .locationOff: "Location is off · no route"
        case .gpsGap: "GPS gap while closed"
        }
    }

    /// Everything here asks for a look except the restore, which is only to be known.
    var tone: StrandTone { self == .gpsGap ? .neutral : .warning }

    /// Tapping the pill opens the longer message the model keeps (`workoutDurabilityWarning`).
    var hasLongExplanation: Bool { self == .durability || self == .gpsGap }

    /// The same words as plain text, for the one announcement VoiceOver makes when the notice appears.
    var spoken: String {
        switch self {
        case .durability: String(localized: "Not safely recoverable")
        case .heartRate: String(localized: "No heart-rate signal")
        case .gpsLost: String(localized: "GPS signal lost")
        case .gpsWeak: String(localized: "Weak GPS signal")
        case .gpsSearching: String(localized: "Searching for GPS")
        case .noStrap: String(localized: "No strap connected")
        case .locationOff: String(localized: "Location is off · no route")
        case .gpsGap: String(localized: "GPS gap while closed")
        }
    }
}

/// The reserved slot under the header: one pill, a "+n" chip when more are waiting. Tapping a pill that has a longer
/// explanation (the durability warning's) opens it over the page for a few seconds.
struct LiveNoticeSlot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    @ScaledMetric(relativeTo: .caption) private var slotHeight: CGFloat = 28
    @State private var expanded = false
    @State private var collapseTask: Task<Void, Never>?

    var body: some View {
        LiveWorkoutSignalReader(workout: workout, recorder: recorder, live: model.live) { signals in
            let pending = LiveWorkoutSlotNotice.pending(inputs(signals))
            pill(pending)
        }
        .frame(minHeight: slotHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if expanded, let warning = model.workoutDurabilityWarning {
                explanation(warning)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: expanded)
        .onDisappear { collapseTask?.cancel() }
    }

    private func inputs(_ signals: LiveWorkoutSignals.Snapshot) -> LiveWorkoutSlotNotice.Inputs {
        LiveWorkoutSlotNotice.Inputs(
            hasDurabilityWarning: model.workoutDurabilityIssue == .notRecoverable,
            gpsGapIsRecent: model.workoutDurabilityIssue == .gpsGapRestored
                && model.gpsGapRestoredAt.map { Date().timeIntervalSince($0) < LiveWorkoutSlotNotice.gpsGapNoticeSeconds } == true,
            heartRateIsStale: signals.heartRateIsStale,
            strapNeverConnected: signals.strapNeverConnected,
            gps: signals.gps,
            locationIsOff: signals.locationIsOff,
            isJustStarted: Date().timeIntervalSince(workout.start) < LiveWorkoutSlotNotice.locationNoticeSeconds)
    }

    @ViewBuilder private func pill(_ pending: [LiveWorkoutSlotNotice]) -> some View {
        if let first = pending.first {
            HStack(spacing: NoopMetrics.space2) {
                if first.hasLongExplanation {
                    // The pill is about 23 pt tall; the tap area reaches the 44 pt a moving thumb needs.
                    Button { toggleExpanded() } label: { StatePill(first.title, tone: first.tone).chipHitTarget() }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows the full message")
                } else {
                    StatePill(first.title, tone: first.tone)
                }
                if pending.count > 1 {
                    WidgetChip(verbatimTitle: "+\(pending.count - 1)", showsChevron: false)
                        .accessibilityLabel(Text("More notices: \(pending.count - 1)"))
                }
                Spacer(minLength: 0)
            }
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .onChange(of: first, initial: true) { _, notice in announce(notice) }
        }
    }

    /// A notice is read once, as it appears.
    private func announce(_ notice: LiveWorkoutSlotNotice) {
        AccessibilityNotification.Announcement(notice.spoken).post()
    }

    private func toggleExpanded() {
        expanded.toggle()
        collapseTask?.cancel()
        guard expanded else { return }
        collapseTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            expanded = false
        }
    }

    private func explanation(_ text: String) -> some View {
        Button { toggleExpanded() } label: {
            Text(verbatim: text)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .widgetCardSurface(tint: .neutral, padding: NoopMetrics.space3)
        }
        .buttonStyle(.plain)
        .offset(y: slotHeight)
        .zIndex(1)
    }
}

/// The header's two small status glyphs: the heart-rate link and, for a route sport, the GPS fix. Quiet when fine; amber
/// when something needs a look; struck through when there is nothing to wait for.
struct LiveSignalGlyphs: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder

    var body: some View {
        LiveWorkoutSignalReader(workout: workout, recorder: recorder, live: model.live) { signals in
            HStack(spacing: 0) {
                heart(signals)
                if recorder.isRecording { location(signals) }
            }
        }
    }

    private func heart(_ signals: LiveWorkoutSignals.Snapshot) -> some View {
        let missing = signals.strapNeverConnected
        let warn = signals.heartRateIsStale || missing
        return glyph(missing ? "heart.slash" : "heart.fill", warn: warn,
                     label: missing ? "No strap connected" : (signals.heartRateIsStale ? "No heart-rate signal" : nil))
    }

    private func location(_ signals: LiveWorkoutSignals.Snapshot) -> some View {
        let off = signals.locationIsOff
        let lost = signals.gps == .lost
        let weak = signals.gps == .weak || signals.gps == .searching
        let label: LocalizedStringKey? = off ? "Location is off · no route"
            : lost ? "GPS signal lost" : (signals.gps == .weak ? "Weak GPS signal" : (weak ? "Searching for GPS" : nil))
        return glyph(off || lost ? "location.slash" : "location.fill", warn: off || lost || weak, label: label)
    }

    private func glyph(_ symbol: String, warn: Bool, label: LocalizedStringKey?) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(warn ? StrandPalette.statusWarning : StrandPalette.textTertiary)
            .frame(width: 44, height: 44)
            .accessibilityHidden(label == nil)
            .accessibilityLabel(label.map { Text($0) } ?? Text(verbatim: ""))
    }
}
#endif
