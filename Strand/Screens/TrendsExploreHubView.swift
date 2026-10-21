import SwiftUI
import StrandDesign

/// The six analysis destinations that used to hang off Trends' header. One list feeds both the Explore page (grouped,
/// with a line on what is behind each) and the quiet "Explore more" list at the bottom of Trends.
enum TrendsExploreDestination: CaseIterable, Identifiable {
    case whatMovesYou, intelligence, coach, allMetrics, compare, labBook

    var id: Self { self }

    var symbol: String {
        switch self {
        case .whatMovesYou: "sparkles"
        case .intelligence: "brain.head.profile"
        case .coach: "bubble.left.and.text.bubble.right"
        case .allMetrics: "waveform.path.ecg"
        case .compare: "chart.line.uptrend.xyaxis"
        case .labBook: "flask"
        }
    }

    var tint: DomainTint {
        switch self {
        case .whatMovesYou: .journal
        case .intelligence, .coach: .accent
        case .allMetrics: .heart
        case .compare: .strain
        case .labBook: .stress
        }
    }

    var title: Text {
        switch self {
        case .whatMovesYou: Text("What Moves You")
        case .intelligence: Text("Intelligence")
        case .coach: Text("Coach")
        case .allMetrics: Text("All metrics")
        case .compare: Text("Compare")
        case .labBook: Text("Lab Book")
        }
    }

    var subtitle: Text {
        switch self {
        case .whatMovesYou: Text("Personal patterns ranked by effect size")
        case .intelligence: Text("Your scored days and tomorrow's Recovery")
        case .coach: Text("Ask questions grounded in your metrics")
        case .allMetrics: Text("Open every signal and its history")
        case .compare: Text("Overlay signals and inspect relationships")
        case .labBook: Text("Your bloods, blood pressure and body numbers")
        }
    }

    @MainActor @ViewBuilder var destination: some View {
        switch self {
        case .whatMovesYou: InsightsHubView()
        case .intelligence: IntelligenceView()
        case .coach:
            #if os(iOS)
            LocalCoachView()
            #else
            CoachView()
            #endif
        case .allMetrics: MetricExplorerView()
        case .compare: CompareView()
        case .labBook: LabBookView()
        }
    }
}

/// Re-homes the former More analysis destinations under Trends, where history,
/// comparison, interpretation, and records share one predictable owner.
///
/// A page of flat sections: each destination is a row of a glyph on its domain disc, the name, one line on what is
/// behind it and a chevron. The rows push with closure-based NavigationLinks (the destinations are built on tap).
struct TrendsExploreHubView: View {
    var body: some View {
        ScreenScaffold(title: "Explore", topBackground: nil) {
            VStack(alignment: .leading, spacing: 0) {
                FlatSection("Insights", systemImage: "sparkles", contentSpacing: 0) {
                    row(.whatMovesYou)
                    ExploreRowSeparator()
                    row(.intelligence)
                    ExploreRowSeparator()
                    row(.coach)
                }
                FlatSectionSeparator.afterExploreRows
                FlatSection("Metrics", systemImage: "waveform.path.ecg", contentSpacing: 0) {
                    row(.allMetrics)
                    ExploreRowSeparator()
                    row(.compare)
                }
                FlatSectionSeparator.afterExploreRows
                FlatSection("Records", systemImage: "flask", contentSpacing: 0) {
                    row(.labBook)
                }
            }
        }
    }

    private func row(_ d: TrendsExploreDestination) -> some View {
        NavigationLink { d.destination } label: {
            ExploreFlatRow(symbol: d.symbol, tint: d.tint, title: d.title, subtitle: d.subtitle)
        }
        .exploreRowPress()
    }
}

/// The quiet list at the foot of Trends: icon, name and chevron per row, no card or disc behind them.
struct TrendsExploreMoreList: View {
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.38, bounce: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 0) {
                    SectionEyebrow(title: String(localized: "Explore more"), systemImage: "square.grid.2x2", tint: .accent)
                    Spacer(minLength: NoopMetrics.space2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Explore more")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("trends.exploreMore")
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(TrendsExploreDestination.allCases.enumerated()), id: \.element) { index, d in
                        if index > 0 { FlatRowSeparator(leadingInset: 32) }
                        NavigationLink { d.destination } label: {
                            HStack(spacing: NoopMetrics.space3) {
                                Image(systemName: d.symbol)
                                    .font(.system(size: 16, weight: .regular))
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .frame(width: 20)
                                    .accessibilityHidden(true)
                                d.title
                                    .font(.body)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer(minLength: NoopMetrics.space2)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.vertical, NoopMetrics.space3)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .exploreRowPress()
                        .accessibilityIdentifier("trends.explore.\(index)")
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }
}
