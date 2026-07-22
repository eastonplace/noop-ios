import SwiftUI
import StrandDesign

/// iPhone-only explanation of using Apple Health as an optional data source. No watchOS companion app or
/// WatchConnectivity session is required; NOOP simply reads data the user has already allowed in HealthKit.
struct AppleWatchSetupView: View {
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    Text("Apple Health")
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("NOOP can read supported health data from Apple Health on this iPhone. A separate Apple Watch app is not installed or required.")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PaperCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("What can be imported", systemImage: "heart.text.square")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Heart rate, HRV, resting heart rate, sleep, steps, workouts, and other values appear only when Apple Health contains them and you grant access.")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    PaperCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Privacy", systemImage: "lock.shield")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Health data is processed locally. Missing or declined permissions remain missing; NOOP does not invent substitute readings.")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                .screenPadding()
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }
}

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
