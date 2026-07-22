import SwiftUI
import StrandDesign

/// Compact information surface used by the device manager for the iPhone-side Apple Health source.
struct AppleWatchAboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                Text("Apple Health data")
                    .font(StrandFont.title1)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("This source represents health records available to the iPhone through HealthKit. It is not a separate watchOS client and does not create a second live Bluetooth connection.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                PaperCard {
                    Text("Capabilities are shown only after corresponding data has actually arrived. Apple Health remains secondary to the active live strap when both cover the same period.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .screenPadding()
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle("Apple Health")
    }
}
