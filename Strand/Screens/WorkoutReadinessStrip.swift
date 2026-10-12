#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Ready
//
// What the setup page checks before Start, one row each: the strap, the GPS (for a sport that records a route), what today's
// strain target is, whether the screen stays on, and whether a countdown comes first. Each row says its state in words, never
// in colour alone, and each row that can be fixed from here has the button that fixes it.

struct WorkoutReadinessStrip: View {
    /// A sport that records a route shows the GPS row; a treadmill run or a strength session does not.
    let showsGps: Bool
    @ObservedObject var probe: GpsReadinessProbe
    let live: LiveState
    let today: WorkoutReadinessToday?
    @Binding var keepScreenOn: Bool
    @Binding var countdownOn: Bool
    /// Low Power Mode is on: the screen cannot be held awake, whatever the switch says.
    let lowPowerMode: Bool
    let onConnect: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        FlatSection("Ready", systemImage: "checkmark.circle", tint: .workout) {
            VStack(alignment: .leading, spacing: 0) {
                StrapReadinessRow(live: live, onConnect: onConnect)
                if showsGps { gpsRow }
                if let today { todayRow(today) }
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
                Button("Allow location") { probe.requestAuthorization() }
                    .buttonStyle(SecondaryPillButtonStyle())
            case .locating:
                StatePill("Locating…", tone: .neutral)
            case .locked(let metres):
                StatePill("Locked ±\(metres) m", tone: .positive)
            case .off:
                StatePill("Location is off", tone: .warning)
                Button("Open Settings") { openSettings() }
                    .buttonStyle(SecondaryPillButtonStyle())
            case .restricted:
                StatePill("Restricted by Screen Time", tone: .warning)
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
                    .foregroundStyle(today.isWarning ? StrandPalette.statusWarning : StrandPalette.textSecondary)
                    .captionLabelFit(lines: 3, weight: .regular, standardLines: 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44, alignment: .leading)
        .padding(.vertical, NoopMetrics.space1)
        .accessibilityElement(children: .combine)
    }

    // MARK: Switches

    private var screenRow: some View {
        Toggle(isOn: lowPowerMode ? .constant(false) : $keepScreenOn) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
                ReadinessIcon(systemImage: "sun.max")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen stays on").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                    if lowPowerMode {
                        Text("Off in Low Power Mode").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .tint(StrandPalette.ink)
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
        .tint(StrandPalette.ink)
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
                    StatePill("Connected · \(bpm) bpm", tone: .positive)
                } else {
                    StatePill("Connected", tone: .positive)
                }
            } else {
                StatePill("Not connected", tone: .neutral)
                Button("Connect", action: onConnect)
                    .buttonStyle(SecondaryPillButtonStyle())
            }
        }
    }
}

/// A row's glyph, in a column of its own so the words line up.
private struct ReadinessIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(StrandPalette.textSecondary)
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
