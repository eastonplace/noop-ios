import SwiftUI
import StrandDesign

/// The foot of Trends, after the weekly readout, built like the Heads-Up card on Today: a tappable
/// "Insights ›" title with how much data it rests on, then the strongest three findings as compact
/// rows. The whole block opens the Insights page. With too little data it says so in one line.
struct TrendsInsightsSection: View {
    @EnvironmentObject private var repo: Repository
    @State private var report: InsightsReport?
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 16

    /// How many insights Trends shows.
    static let shownCount = 3

    var body: some View {
        NavigationLink { InsightsHubView() } label: {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                header
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("trends.insights")
        .task(id: InsightsLoadIdentity(repo: repo)) { await loadReport() }
    }

    private func loadReport() async {
        let identity = InsightsLoadIdentity(repo: repo)
        let loaded = await InsightsLoader.load(repo: repo)
        guard !Task.isCancelled, identity == InsightsLoadIdentity(repo: repo) else { return }
        report = loaded
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Insights")
                .font(StrandFont.sized(titleSize, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Spacer(minLength: NoopMetrics.space2)
            if let report, report.hasEnoughData {
                Text("From \(report.daysOfData) days")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let report {
            if !report.hasEnoughData {
                note(String(localized: "Insights appear after about 2 weeks of wear."))
            } else if report.significant.isEmpty {
                note(String(localized: "No clear patterns yet. NOOP checks again as more nights come in."))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(report.significant.prefix(Self.shownCount))) { row in
                        InsightCompactRow(row: row)
                    }
                }
            }
        } else {
            note(String(localized: "Reading your patterns…"))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
