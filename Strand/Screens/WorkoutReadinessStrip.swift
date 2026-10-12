#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Ready
//
// What the setup page checks before Start, one row each: the strap, the GPS (for a sport that records a route), what today's
// strain target is, which number the live screen leads with, whether the screen stays on, and whether a countdown comes first.
// Quiet rows on black: each says its state in words (coloured, never in colour alone), and each row that can be fixed from here
// has a mint text button that fixes it.

/// The number the live screen leads with ("Big number"): what is chosen, what can be chosen, and what choosing does.
struct WorkoutBigNumberChoice {
    let current: LiveWorkoutGlance.Metric
    let choices: [LiveWorkoutGlance.Metric]
    let onChoose: (LiveWorkoutGlance.Metric) -> Void
}

struct WorkoutReadinessStrip: View {
    /// A sport that records a route shows the GPS row; a treadmill run or a strength session does not.
    let showsGps: Bool
    @ObservedObject var probe: GpsReadinessProbe
    let live: LiveState
    let today: WorkoutReadinessToday?
    let bigNumber: WorkoutBigNumberChoice
    @Binding var keepScreenOn: Bool
    @Binding var countdownOn: Bool
    /// Low Power Mode is on: the screen cannot be held awake, whatever the switch says.
    let lowPowerMode: Bool
    /// The GPS accuracy is told in the person's unit.
    var imperial = false
    let onConnect: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Ready")
                .foregroundStyle(LivePalette.secondaryText)
                .liveText(15, weight: .semibold, maxSize: 22, lines: 2)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                StrapReadinessRow(live: live, onConnect: onConnect)
                if showsGps { gpsRow }
                if let today { todayRow(today) }
                bigNumberRow
                screenRow
                countdownRow
            }
        }
    }

    // MARK: GPS

    private var gpsRow: some View {
        ReadinessRow(systemImage: "location", title: "GPS") {
            switch probe.readiness {
            case .allowNeeded:
                ReadinessAction("Allow location") { probe.requestAuthorization() }
            case .locating:
                ReadinessStatus("Locating…", tone: .neutral)
            case .locked(let metres):
                ReadinessStatus(verbatim: String(localized: "Locked \(GpsReadiness.accuracyText(meters: metres, imperial: imperial))"),
                                tone: .positive)
            case .approximate:
                // Precise Location is off for NOOP: fixes are kilometres wide and never get better, so say so instead of
                // "Locating…" for ever.
                ReadinessStatus("Precise Location is off", tone: .warning)
                ReadinessAction("Open Settings") { openSettings() }
            case .off:
                ReadinessStatus("Location is off", tone: .warning)
                ReadinessAction("Open Settings") { openSettings() }
            case .restricted:
                ReadinessStatus("Restricted by Screen Time", tone: .warning)
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    // MARK: Today

    private func todayRow(_ today: WorkoutReadinessToday) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
            ReadinessIcon(systemImage: "target")
            VStack(alignment: .leading, spacing: 2) {
                Text("Today").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: today.text())
                    .foregroundStyle(today.isWarning ? LivePalette.amber : LivePalette.secondaryText)
                    .captionLabelFit(lines: 3, weight: .regular, standardLines: 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44, alignment: .leading)
        .padding(.vertical, NoopMetrics.space1)
        .accessibilityElement(children: .combine)
    }

    // MARK: Big number

    /// "Big number: Time" with the chevrons of a menu: which figure the live screen leads with, for this kind of sport.
    private var bigNumberRow: some View {
        ReadinessRow(systemImage: "textformat.123", title: "Big number") {
            Menu {
                ForEach(bigNumber.choices, id: \.self) { metric in
                    Button { bigNumber.onChoose(metric) } label: {
                        if metric == bigNumber.current {
                            Label(LiveWorkoutGlance.name(of: metric), systemImage: "checkmark")
                        } else {
                            Text(verbatim: LiveWorkoutGlance.name(of: metric))
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(verbatim: LiveWorkoutGlance.name(of: bigNumber.current))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .liveText(15, weight: .medium, maxSize: 21, lines: 2)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LivePalette.secondaryText)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Big number"))
            .accessibilityValue(Text(verbatim: LiveWorkoutGlance.name(of: bigNumber.current)))
        }
    }

    // MARK: Switches

    private var screenRow: some View {
        Toggle(isOn: lowPowerMode ? .constant(false) : $keepScreenOn) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
                ReadinessIcon(systemImage: "sun.max")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen stays on").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                    if lowPowerMode {
                        Text("Off in Low Power Mode").font(StrandFont.footnote).foregroundStyle(LivePalette.secondaryText)
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .tint(LivePalette.mint)
        .disabled(lowPowerMode)
        .frame(minHeight: 44)
        .accessibilityHint("Stops the screen dimming while a workout is recording")
    }

    private var countdownRow: some View {
        Toggle(isOn: $countdownOn) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
                ReadinessIcon(systemImage: "timer")
                Text("Countdown").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            }
        }
        .toggleStyle(.switch)
        .tint(LivePalette.mint)
        .frame(minHeight: 44)
    }
}

/// The strap's row reads the live link in a leaf of its own, so the page does not redraw for every heartbeat.
private struct StrapReadinessRow: View {
    @ObservedObject var live: LiveState
    let onConnect: () -> Void

    var body: some View {
        ReadinessRow(systemImage: "heart", title: "Strap") {
            if live.connected {
                if let bpm = live.heartRate, bpm > 0 {
                    ReadinessStatus("Connected · \(bpm) bpm", tone: .positive)
                } else {
                    ReadinessStatus("Connected", tone: .positive)
                }
            } else {
                ReadinessStatus("Not connected", tone: .neutral)
                ReadinessAction("Connect", action: onConnect)
            }
        }
    }
}

/// A row's state in words, coloured by what it means: mint when ready, grey when waiting, amber when it needs a look.
private struct ReadinessStatus: View {
    enum Tone { case positive, neutral, warning }

    private let text: Text
    private let tone: Tone

    init(_ key: LocalizedStringKey, tone: Tone) {
        text = Text(key)
        self.tone = tone
    }

    init(verbatim: String, tone: Tone) {
        text = Text(verbatim: verbatim)
        self.tone = tone
    }

    var body: some View {
        text
            .foregroundStyle(color)
            .liveText(15, weight: .medium, maxSize: 21, lines: 3)
            .multilineTextAlignment(.trailing)
    }

    private var color: Color {
        switch tone {
        case .positive: LivePalette.mint
        case .neutral: LivePalette.secondaryText
        case .warning: LivePalette.amber
        }
    }
}

/// What fixes a row, as mint words with a 44 pt target: no pill.
private struct ReadinessAction: View {
    private let title: LocalizedStringKey
    private let action: () -> Void

    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(LivePalette.mint)
                .liveText(15, weight: .semibold, maxSize: 21, lines: 2)
                .padding(.horizontal, 4)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A row's glyph, in a column of its own so the words line up.
private struct ReadinessIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(LivePalette.secondaryText)
            .frame(width: 24)
            .accessibilityHidden(true)
    }
}

/// A readiness row: glyph and title on the left and what it says (a pill, a button, or both) on the right. At the
/// accessibility sizes the title takes its line and the state goes under it, full width.
private struct ReadinessRow<Trailing: View>: View {
    let systemImage: String
    let title: LocalizedStringKey
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    HStack(spacing: NoopMetrics.space3) {
                        ReadinessIcon(systemImage: systemImage)
                        Text(title).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                    }
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) { trailing() }
                }
            } else {
                HStack(alignment: .center, spacing: NoopMetrics.space3) {
                    ReadinessIcon(systemImage: systemImage)
                    Text(title).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: NoopMetrics.space2)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: NoopMetrics.space2) { trailing() }
                        VStack(alignment: .trailing, spacing: NoopMetrics.space2) { trailing() }
                    }
                }
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .padding(.vertical, NoopMetrics.space1)
        .accessibilityElement(children: .contain)
    }
}
#endif
