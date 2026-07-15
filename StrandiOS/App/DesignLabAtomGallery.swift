#if DEBUG
import SwiftUI
import StrandDesign

/// Test-only host for Phase 1 visual evidence. It contains presentation constants,
/// never repository or fixture data, and is excluded from Release builds.
struct DesignLabAtomGallery: View {
    private enum Range: String, CaseIterable { case day = "D", week = "W", month = "M" }

    @State private var query = "recovery"
    @State private var range: Range = .week
    @State private var step = 1
    @State private var showToast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("STRANDDESIGN · ADOPTION ATOMS").strandOverline()

                section("VALUE TOKENS") {
                    HStack(spacing: 8) {
                        ValueToken("Heart rate", value: "142 bpm", tint: StrandPalette.statusCritical)
                        ValueToken("HRV", value: "66 ms", tint: StrandPalette.link)
                    }
                }

                section("MICRO STATUS") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            MicroBadge("Live", systemImage: "waveform", tint: StrandPalette.statusPositive)
                            MicroBadge("Beta", tint: StrandPalette.textSecondary)
                            MicroStatusDot(color: StrandPalette.statusPositive, isActive: true)
                        }
                        HStack(spacing: 8) {
                            StatePill("Streaming", tone: .positive, pulsing: true)
                            StatusBadge("Live", style: .live, pulsing: true)
                            StatusBadge("Paused", style: .paused)
                        }
                    }
                }

                section("PROGRESS & ACTIONS") {
                    VStack(alignment: .leading, spacing: 12) {
                        ProgressDots(count: 4, current: step)
                        HStack(spacing: 10) {
                            MicroIconButton(systemImage: "heart.fill", label: "Favorite", isSelected: true) {}
                            MicroIconButton(systemImage: "slider.horizontal.3", label: "Filters") {}
                            Button("Advance step") { step = (step + 1) % 4 }
                                .buttonStyle(.bordered)
                        }
                    }
                }

                section("SEARCH") {
                    PaperSearchField("Search metrics", text: $query)
                }

                section("SEGMENTED THUMB") {
                    SegmentedPillControl(Range.allCases, selection: $range) { $0.rawValue }
                }

                section("TRANSIENT FEEDBACK") {
                    Button("Show paper toast") { showToast = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        // Extended only in this DEBUG gallery so screenshot tooling can observe it;
        // the promoted component default remains the contracted 2.4 seconds.
        .paperToast(isPresented: $showToast, dwell: 8) {
            PaperToast("Workout saved", actionTitle: "Undo") { showToast = false }
        }
    }

    private func section<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).strandOverline()
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview("Design Lab adoption atoms") {
    DesignLabAtomGallery()
}
#endif
