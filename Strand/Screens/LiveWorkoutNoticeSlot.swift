#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - The notice and the signal glyphs
//
// Nothing on the live screen moves when a signal changes. A problem shows in two places: a glyph in the header's capsule, and a
// pill that drops in under the header over the page's reserved band, so the numbers below never shift. The longer message a
// pill opens is a card over the page, not part of it.

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
    /// How long "GPS gap while closed" is said once the wearer has the workout in front of them. The header glyph and the
    /// page carry on without it.
    static let gpsGapNoticeSeconds: TimeInterval = 30

    /// Whether the restored-gap notice is still due. The window starts when the screen first shows the workout in the foreground
    /// (`AppModel.gpsGapNoticeShownAt`: once for the workout, however often the screen is reopened) and again when the app comes
    /// back from the background, not when the app launched: a workout restored in the background was not in front of anyone
    /// for those seconds.
    static func gapWindowIsOpen(openedAt: Date?, now: Date, seconds: TimeInterval = gpsGapNoticeSeconds) -> Bool {
        guard let openedAt else { return false }
        return now.timeIntervalSince(openedAt) < seconds
    }

    /// The notices that apply now, in the order the slot shows them: the durability warning, the signals that went quiet, a
    /// strap that never connected, and a location that is off. The slot is for warnings only: that the workout is paused is
    /// the header's to say ("Paused · 3:11"), not a pill's. A strap that never connected replaces "No
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

    /// Every notice has a longer message: the model's own for the two it keeps (`workoutDurabilityWarning`), the rest below.
    var hasLongExplanation: Bool { true }

    /// What a tap on the pill can offer to do about it.
    enum Action: Equatable, Sendable {
        case manageDevices
        case openSettings
    }

    /// The longer message, for the notices whose text does not come from the model. nil for the two that do.
    var explanation: String? {
        switch self {
        case .durability, .gpsGap: nil
        case .heartRate:
            String(localized: "The strap has stopped sending heart rate. Check that it is worn snugly and within range. NOOP keeps recording.")
        case .gpsLost:
            String(localized: "GPS has had no fix for a while. NOOP keeps recording, and where there was no fix the route has a gap.")
        case .gpsWeak:
            String(localized: "The GPS fix is weak, so distance and pace may be less exact until it improves.")
        case .gpsSearching:
            String(localized: "NOOP is still looking for a GPS fix. The route starts as soon as it finds one.")
        case .noStrap:
            String(localized: "No strap has connected to this workout. Without heart rate, NOOP may have nothing to save for this sport.")
        case .locationOff:
            String(localized: "Location is off for NOOP, so this workout records no route and no distance. Turn it on in Settings to record one next time.")
        }
    }

    /// The one thing worth offering with the explanation.
    var action: Action? {
        switch self {
        case .heartRate, .noStrap: .manageDevices
        case .locationOff: .openSettings
        case .durability, .gpsLost, .gpsWeak, .gpsSearching, .gpsGap: nil
        }
    }

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

/// The pill that drops in under the header: one notice, a "+n" chip when more are waiting. Tapping the pill opens its longer
/// explanation as a card over the page for a few seconds (and for as long as it is wanted under VoiceOver or Switch Control).
/// With nothing to say it has no height, so it never takes room from the page.
struct LiveNoticeSlot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    /// Opens the device manager (a sheet in the journey's cover) for the notices that offer it.
    var onManageDevices: () -> Void = {}
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlOn
    @State private var expanded: LiveWorkoutSlotNotice?
    @State private var collapseTask: Task<Void, Never>?
    /// The app went to the background since the screen last drew: coming back opens the restored-gap window again. (The phase
    /// reports a return as background, inactive, active, so a pair of old and new values would never see "background".)
    @State private var wentToBackground = false

    var body: some View {
        LiveWorkoutSignalReader(workout: workout, recorder: recorder, live: model.live) { signals in
            let pending = LiveWorkoutSlotNotice.pending(inputs(signals))
            VStack(spacing: NoopMetrics.space2) {
                pill(pending)
                // The card is there only while what it explains is: when the notice goes, so does it.
                if let notice = expanded, pending.first == notice {
                    explanation(notice).transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            // An open card belongs to the notice it explains: when that notice leaves the pill (or another takes its place) the
            // card is closed for good, so it does not come back open when the notice does (under VoiceOver or Switch Control
            // nothing else closes it).
            .onChange(of: pending.first) { _, first in
                if let open = expanded, first != open { collapse() }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: expanded)
        .onAppear { if scenePhase == .active { model.noteGpsGapNoticeOnScreen() } }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                wentToBackground = true
            case .active:
                // A real return to the foreground opens the window again; an .inactive blip does not.
                if wentToBackground { wentToBackground = false; model.reopenGpsGapNoticeWindow() }
                model.noteGpsGapNoticeOnScreen()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onDisappear { collapseTask?.cancel() }
    }

    private func inputs(_ signals: LiveWorkoutSignals.Snapshot) -> LiveWorkoutSlotNotice.Inputs {
        let now = Date()
        return LiveWorkoutSlotNotice.Inputs(
            hasDurabilityWarning: model.workoutDurabilityIssue == .notRecoverable,
            gpsGapIsRecent: model.workoutDurabilityIssue == .gpsGapRestored
                && LiveWorkoutSlotNotice.gapWindowIsOpen(openedAt: model.gpsGapNoticeShownAt, now: now),
            heartRateIsStale: signals.heartRateIsStale,
            strapNeverConnected: signals.strapNeverConnected,
            gps: signals.gps,
            locationIsOff: signals.locationIsOff,
            isJustStarted: now.timeIntervalSince(workout.start) < LiveWorkoutSlotNotice.locationNoticeSeconds)
    }

    /// A warning notice is the neutral pill with an amber dot (colour lives in the dot); a plain notice keeps the grey fill.
    @ViewBuilder private func noticeLabel(_ notice: LiveWorkoutSlotNotice) -> some View {
        let text = Text(notice.title)
            .liveText(14, weight: .semibold, maxSize: 20, lines: 3)
            .multilineTextAlignment(.center)
        if notice.tone == .neutral {
            text
                .foregroundStyle(LivePalette.quietAction)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule(style: .continuous).fill(LivePalette.fill))
        } else {
            text
                .foregroundStyle(StrandPalette.textPrimary)
                .statePillChrome(tint: LivePalette.amber)
        }
    }

    @ViewBuilder private func pill(_ pending: [LiveWorkoutSlotNotice]) -> some View {
        if let first = pending.first {
            HStack(spacing: NoopMetrics.space2) {
                // The pill is about 34 pt tall; the tap area reaches the 44 pt a moving thumb needs.
                Button { toggle(first) } label: {
                    noticeLabel(first)
                        .chipHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the full message")
                if pending.count > 1 {
                    Text(verbatim: "+\(pending.count - 1)")
                        .foregroundStyle(LivePalette.secondaryText)
                        .liveText(13, weight: .semibold, maxSize: 18, lines: 1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule(style: .continuous).fill(LivePalette.fill))
                        .accessibilityLabel(Text("More notices: \(pending.count - 1)"))
                }
            }
            .padding(.top, 6)
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .onChange(of: first, initial: true) { _, notice in announce(notice) }
        }
    }

    /// A notice is read once, as it appears.
    private func announce(_ notice: LiveWorkoutSlotNotice) {
        AccessibilityNotification.Announcement(notice.spoken).post()
    }

    /// Whether an open card closes by itself. Not under VoiceOver or Switch Control: reading or reaching a long message can
    /// take longer than six seconds, and it is closed with the pill again (or its own tap).
    static func closesByItself(voiceOver: Bool, switchControl: Bool) -> Bool { !voiceOver && !switchControl }

    private func toggle(_ notice: LiveWorkoutSlotNotice) {
        collapseTask?.cancel()
        guard expanded != notice else {
            expanded = nil
            return
        }
        expanded = notice
        guard Self.closesByItself(voiceOver: voiceOverOn, switchControl: switchControlOn) else { return }
        collapseTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            expanded = nil
        }
    }

    private func collapse() {
        collapseTask?.cancel()
        expanded = nil
    }

    /// The text of the open notice: its own, or the model's for the two it keeps.
    private func text(of notice: LiveWorkoutSlotNotice) -> String? {
        notice.explanation ?? model.workoutDurabilityWarning
    }

    @ViewBuilder private func explanation(_ notice: LiveWorkoutSlotNotice) -> some View {
        if let text = text(of: notice) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                // Long messages (a long translation, a large text size) scroll inside the card rather than run off the screen.
                ViewThatFits(in: .vertical) {
                    message(text)
                    ScrollView { message(text) }.scrollBounceBehavior(.basedOnSize)
                }
                .frame(maxHeight: 300)
                if let action = notice.action {
                    LiveCapsuleButton(actionTitle(action)) { perform(action) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(white: 0.13)))
            .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
            // Tapping the card itself closes it; the action keeps its own tap.
            .onTapGesture { collapse() }
        }
    }

    private func message(_ text: String) -> some View {
        Text(verbatim: text)
            .foregroundStyle(StrandPalette.textPrimary)
            .liveText(15, weight: .regular, maxSize: 21, lines: 20)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionTitle(_ action: LiveWorkoutSlotNotice.Action) -> String {
        switch action {
        case .manageDevices: String(localized: "Manage devices")
        case .openSettings: String(localized: "Open Settings")
        }
    }

    private func perform(_ action: LiveWorkoutSlotNotice.Action) {
        collapse()
        switch action {
        case .manageDevices: onManageDevices()
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
    }
}

/// The header's capsule of two small status glyphs: the heart-rate link and, for a route sport, the GPS fix. Grey when fine;
/// amber when something needs a look; struck through when there is nothing to wait for.
struct LiveSignalGlyphs: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder

    var body: some View {
        LiveWorkoutSignalReader(workout: workout, recorder: recorder, live: model.live) { signals in
            HStack(spacing: 14) {
                heart(signals)
                if recorder.isRecording { location(signals) }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(Capsule(style: .continuous).fill(LivePalette.fill))
            .accessibilityElement(children: .contain)
        }
    }

    private func heart(_ signals: LiveWorkoutSignals.Snapshot) -> some View {
        let missing = signals.strapNeverConnected
        let warn = signals.heartRateIsStale || missing
        return glyph(missing ? "heart.slash.fill" : "heart.fill", warn: warn,
                     label: missing ? "No strap connected" : (signals.heartRateIsStale ? "No heart-rate signal" : nil))
    }

    private func location(_ signals: LiveWorkoutSignals.Snapshot) -> some View {
        let off = signals.locationIsOff
        let lost = signals.gps == .lost
        let weak = signals.gps == .weak || signals.gps == .searching
        let label: LocalizedStringKey? = off ? "Location is off · no route"
            : lost ? "GPS signal lost" : (signals.gps == .weak ? "Weak GPS signal" : (weak ? "Searching for GPS" : nil))
        return glyph(off || lost ? "location.slash.fill" : "location.fill", warn: off || lost || weak, label: label)
    }

    private func glyph(_ symbol: String, warn: Bool, label: LocalizedStringKey?) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(warn ? LivePalette.amber : LivePalette.secondaryText)
            .accessibilityHidden(label == nil)
            .accessibilityLabel(label.map { Text($0) } ?? Text(verbatim: ""))
    }
}
#endif
