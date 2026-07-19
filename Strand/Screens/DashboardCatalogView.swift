import SwiftUI
import StrandDesign

struct DashboardCatalogItem: Identifiable {
    let card: DashboardCard
    let value: String
    let spark: [Double]
    let tint: Color
    var id: String { card.id }
}

/// The former Your Cards library, promoted to the complete metric catalog behind Health Monitor's
/// Show All action. Selection only controls the nine Today tiles; this list remains complete.
struct DashboardCatalogView: View {
    let items: [DashboardCatalogItem]
    @Binding var selectionRaw: String
    let hydrationEnabled: Bool

    @State private var showingEditor = false

    var body: some View {
        ScreenScaffold(title: "Your Cards", subtitle: "Every metric, one place", lazy: true,
                       trailing: {
                           Button("Customize") { showingEditor = true }
                               .font(StrandFont.caption.weight(.semibold))
                               .foregroundStyle(StrandPalette.link)
                       }) {
            ForEach(items) { item in
                NavigationLink {
                    DashboardCardDestination(card: item.card)
                        .environment(\.screenScaffoldNavigationRole, .detail)
                } label: {
                    MetricCatalogRow(model: MetricCatalogRowModel(
                        id: item.id, icon: item.card.icon, title: item.card.title,
                        subtitle: item.card.subtitle, value: item.value,
                        spark: item.spark, accent: item.tint
                    ))
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showingEditor) {
            DashboardCardsEditorSheet(selectionRaw: $selectionRaw, hydrationEnabled: hydrationEnabled)
                .environment(\.appHeaderChromeVisibility, .hidden)
        }
    }
}

struct DashboardCardDestination: View {
    let card: DashboardCard

    @ViewBuilder var body: some View {
        switch card {
        case .stress: StressView()
        case .sleep: SleepView()
        case .hydration: HydrationView()
        case .coupled: CoupledView()
        case .fitnessAge: FitnessAgeDetailView()
        case .hrv, .restingHr, .respiratory, .steps, .vitality,
             .bloodOxygen, .skinTemp, .calories:
            HealthView()
        }
    }
}
