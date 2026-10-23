import SwiftUI
import StrandDesign

/// The foot of Trends, after the weekly readout: the strongest two or three insights from the
/// user's own data and Journal, then a row that opens the full Insights page. With too little
/// history it says so plainly instead of showing numbers.
struct TrendsInsightsSection: View {
    @EnvironmentObject private var repo: Repository
    @State private var report: InsightsReport?

    /// How many insights Trends shows before "See all".
    static let shownCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow(
                title: String(localized: "Insights"),
                systemImage: "sparkles",
                tint: .accent
            )
            .padding(.bottom, NoopMetrics.space1)

            content

            FlatRowSeparator()
            NavigationLink { InsightsHubView() } label: {
                InsightsLinkRow(symbol: "sparkles",
                                title: hasRows ? String(localized: "See all insights")
                                               : String(localized: "How insights work"))
            }
            .exploreRowPress()
            .accessibilityIdentifier("trends.insights.seeAll")
        }
        .task(id: repo.refreshSeq) {
            report = await InsightsLoader.load(repo: repo)
        }
        .accessibilityIdentifier("trends.insights")
    }

    private var hasRows: Bool { !(report?.significant.isEmpty ?? true) }

    @ViewBuilder private var content: some View {
        if let report {
            if !report.hasEnoughData {
                note(String(localized: "Insights appear after about 2 weeks of wear. NOOP compares your nights with each other, so it needs enough of them first."))
            } else if report.significant.isEmpty {
                note(String(localized: "No clear patterns yet. NOOP checks again as more nights come in."))
            } else {
                let rows = Array(report.significant.prefix(Self.shownCount))
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { FlatRowSeparator() }
                    InsightRowView(row: row, showsComparison: false)
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
            .padding(.vertical, NoopMetrics.space3)
    }
}
