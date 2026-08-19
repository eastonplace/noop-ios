import SwiftUI
import StrandDesign

/// Re-homes the former More analysis destinations under Trends, where history,
/// comparison, interpretation, and experiments share one predictable owner.
struct TrendsExploreHubView: View {
    var body: some View {
        ScreenScaffold(
            title: "Explore",
            subtitle: "Insights, comparisons, and experiments.",
            topBackground: nil
        ) {
            SettingsScreenTemplate(sections: sections)
        }
    }

    private var sections: [SettingsSectionModel] {
        [
            SettingsSectionModel(
                id: "insights",
                header: "Insights",
                rows: [
                    .navDetail(
                        id: "what-moves-you",
                        icon: "sparkles",
                        tint: StrandPalette.recoveryData,
                        title: "What Moves You",
                        subtitle: "Personal patterns ranked by effect size"
                    ) {
                        InsightsHubView()
                    },
                    .navDetail(
                        id: "intelligence",
                        icon: "brain.head.profile",
                        tint: StrandPalette.accent,
                        title: "Intelligence",
                        subtitle: "Long-range patterns across your history"
                    ) {
                        IntelligenceView()
                    },
                    .navDetail(
                        id: "coach",
                        icon: "bubble.left.and.text.bubble.right",
                        tint: StrandPalette.journalAccent,
                        title: "Coach",
                        subtitle: "Ask questions grounded in your metrics"
                    ) {
                        CoachView()
                    },
                ]
            ),
            SettingsSectionModel(
                id: "explore",
                header: "Explore",
                rows: [
                    .navDetail(
                        id: "metrics",
                        icon: "waveform.path.ecg",
                        tint: StrandPalette.strainAccent,
                        title: "Explore metrics",
                        subtitle: "Open every signal and its history"
                    ) {
                        MetricExplorerView()
                    },
                    .navDetail(
                        id: "compare",
                        icon: "chart.line.uptrend.xyaxis",
                        tint: StrandPalette.recoveryData,
                        title: "Compare",
                        subtitle: "Overlay signals and inspect relationships"
                    ) {
                        CompareView()
                    },
                    .navDetail(
                        id: "lab-book",
                        icon: "flask",
                        tint: StrandPalette.journalAccent,
                        title: "Lab Book",
                        subtitle: "Run and review personal experiments"
                    ) {
                        LabBookView()
                    },
                ]
            ),
        ]
    }
}
