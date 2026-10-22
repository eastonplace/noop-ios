import SwiftUI
import StrandDesign

/// Re-homes the former More analysis destinations under Trends, where history,
/// comparison, interpretation, and records share one predictable owner.
///
/// A page of flat sections: each destination is a row of a glyph on its domain disc, the name, one line on what is
/// behind it and a chevron. The rows push with closure-based NavigationLinks (the destinations are built on tap).
struct TrendsExploreHubView: View {
    @EnvironmentObject private var repo: Repository

    var body: some View {
        ScreenScaffold(title: "Explore", topBackground: nil) {
            VStack(alignment: .leading, spacing: 0) {
                FlatSection("Insights", systemImage: "sparkles", contentSpacing: 0) {
                    NavigationLink { InsightsHubView() } label: {
                        ExploreFlatRow(
                            symbol: "sparkles", tint: .journal,
                            title: Text("What Moves You"),
                            subtitle: Text("Personal patterns ranked by effect size"))
                    }
                    .exploreRowPress()
                    ExploreRowSeparator()
                    NavigationLink { IntelligenceView() } label: {
                        ExploreFlatRow(
                            symbol: "brain.head.profile", tint: .accent,
                            title: Text("Intelligence"),
                            subtitle: Text("Your scored days and tomorrow's Recovery"))
                    }
                    .exploreRowPress()
                    ExploreRowSeparator()
                    NavigationLink {
                        #if os(iOS)
                        LocalCoachView(journalRepository: repo)
                        #else
                        CoachView()
                        #endif
                    } label: {
                        ExploreFlatRow(
                            symbol: "bubble.left.and.text.bubble.right", tint: .accent,
                            title: Text("Coach"),
                            subtitle: Text("Ask questions grounded in your metrics"))
                    }
                    .exploreRowPress()
                }
                FlatSectionSeparator.afterExploreRows
                FlatSection("Metrics", systemImage: "waveform.path.ecg", contentSpacing: 0) {
                    NavigationLink { MetricExplorerView() } label: {
                        ExploreFlatRow(
                            symbol: "waveform.path.ecg", tint: .heart,
                            title: Text("All metrics"),
                            subtitle: Text("Open every signal and its history"))
                    }
                    .exploreRowPress()
                    ExploreRowSeparator()
                    NavigationLink { CompareView() } label: {
                        ExploreFlatRow(
                            symbol: "chart.line.uptrend.xyaxis", tint: .strain,
                            title: Text("Compare"),
                            subtitle: Text("Overlay signals and inspect relationships"))
                    }
                    .exploreRowPress()
                }
                FlatSectionSeparator.afterExploreRows
                FlatSection("Records", systemImage: "flask", contentSpacing: 0) {
                    NavigationLink { LabBookView() } label: {
                        ExploreFlatRow(
                            symbol: "flask", tint: .stress,
                            title: Text("Lab Book"),
                            subtitle: Text("Your bloods, blood pressure and body numbers"))
                    }
                    .exploreRowPress()
                }
            }
        }
    }
}
