import SwiftUI
import StrandAnalytics
import StrandDesign

struct PersonalStressBaselineSection: View {
    @Binding var enabled: Bool
    let resolution: PersonalStressBaseline.Resolution?

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(title: String(localized: "Personal baseline"),
                           systemImage: "person.crop.circle", tint: .stress)
            Toggle(isOn: $enabled) {
                Text("Use my previous 30 days")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(StrandPalette.ink)
            .accessibilityIdentifier("stress.personalBaseline.toggle")

            if enabled {
                if let resolution {
                    let copy = PersonalStressBaselineCopy(resolution)
                    Text(copy.title)
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .accessibilityIdentifier("stress.personalBaseline.status")
                    Text(copy.detail)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Reading your daytime history…")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            } else {
                Text("The hourly ribbon currently compares each hour with today's quiet hours. Turn this on to compare with your own recent daytime heart rate.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("This changes the hourly ribbon on Stress and Today. Your daily stress score stays the same.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PersonalStressBaselineCopy: Equatable {
    let title: String
    let detail: String

    init(_ resolution: PersonalStressBaseline.Resolution) {
        switch resolution {
        case .disabled:
            title = String(localized: "Day-relative hourly ribbon")
            detail = String(localized: "Each hour is compared with today's quiet hours.")
        case .unavailable:
            title = String(localized: "Personal history could not refresh")
            detail = String(localized: "Showing the day-relative hourly ribbon. Pull to refresh to try reading your previous 30 days again.")
        case .history(let baseline):
            switch baseline.status {
            case .calibrating:
                title = String(localized: "Building · \(baseline.nValid) of \(Baselines.minNightsSeed) days")
                detail = String(localized: "The personal lens needs at least \(Baselines.minNightsSeed) days with a covered waking hour in the previous 30 days. Each covered hour needs at least five minutes of recorded heart rate. Showing the day-relative ribbon while this builds.")
            case .stale:
                title = String(localized: "Personal baseline needs fresh data")
                detail = String(localized: "There have been \(baseline.nightsSinceUpdate) days without a usable daytime reading. Showing the day-relative ribbon until recent daytime data updates your baseline.")
            case .provisional, .trusted:
                let bpm = Int(baseline.baseline.rounded())
                title = baseline.status == .provisional
                    ? String(localized: "Early personal baseline · \(bpm) bpm")
                    : String(localized: "Personal baseline · \(bpm) bpm")
                detail = String(localized: "The hourly ribbon uses a quiet daytime HR reference from \(baseline.nValid) days in the previous 30 days, excluding today. It uses heart rate only; movement can also raise it. The reference is shared across waking hours, 06:00–22:00.")
            }
        }
    }
}
