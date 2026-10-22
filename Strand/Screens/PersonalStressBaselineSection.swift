import SwiftUI
import StrandAnalytics
import StrandDesign

struct PersonalStressBaselineSection: View {
    @Binding var enabled: Bool
    let resolution: PersonalStressBaseline.Resolution?

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(title: String(localized: "Your normal"),
                           systemImage: "person.crop.circle", tint: .stress)
            Toggle(isOn: $enabled) {
                Text("Compare to my normal")
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
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("stress.personalBaseline.status")
                    if let detail = copy.detail {
                        Text(detail)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .accessibilityLabel(Text("Reading your daytime history"))
                        Text("Reading your daytime history…")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            Text("Only changes the hourly bars. Your daily stress score stays the same.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One status line and, while the normal is still building, one line of explanation.
struct PersonalStressBaselineCopy: Equatable {
    let title: String
    let detail: String?

    init(_ resolution: PersonalStressBaseline.Resolution) {
        switch resolution {
        case .disabled:
            title = String(localized: "Each hour is compared with the rest of today.")
            detail = nil
        case .unavailable:
            title = String(localized: "Couldn’t read your history, so today is compared with itself.")
            detail = nil
        case .history(let baseline):
            switch baseline.status {
            case .calibrating:
                title = String(localized: "Learning your normal · \(baseline.nValid) of \(Baselines.minNightsSeed) days")
                detail = String(localized: "Uses your last 30 days of daytime heart rate. Until then, today is compared with itself.")
            case .stale:
                title = String(localized: "Your normal is out of date. Wear your strap for a few days to refresh it.")
                detail = nil
            case .provisional, .trusted:
                title = String(localized: "Compared with your normal from the last 30 days.")
                detail = nil
            }
        }
    }
}
