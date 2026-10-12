import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Name a merged session
//
// The named-sport picker for a merged session whose sessions had no sport (they were bare detected bouts). Starting a live
// workout is the journey's setup page (`WorkoutSetupPage`); this sheet is only the short picker that names a merge.

struct StartWorkoutSheet: View {
    /// Called with the chosen sport name once the user confirms. The host wires this to the merge it is naming.
    let onStart: (_ sport: String) -> Void

    /// A merged session opens on "Other", the honest label for sessions that had none.
    init(onStart: @escaping (_ sport: String) -> Void) {
        self.onStart = onStart
        _selected = State(initialValue: WorkoutCatalog.defaultSportName)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: String

    private var inputShape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }
    private var filtered: [WorkoutCatalog.Sport] { WorkoutCatalog.matching(query) }

    /// Remembers the choice, hands it to the host and closes.
    private func confirm() {
        RecentSportsPrefs.recordSelection(selected)
        onStart(selected)
        dismiss()
    }

    /// The short sheet that names a merged session's sport: a heading, the activity list and one button.
    private var mergePicker: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                WorkoutSportGlyph(symbol: "figure.run")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Name the merged session")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("These sessions have no sport label yet. Pick one for the merged session.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            PaperSearchField("Search sport", text: $query, height: 44, cornerRadius: 10)
                .accessibilityLabel("Search sport")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { sport in
                        Button { selected = sport.name } label: {
                            HStack(spacing: 6) {
                                Text(verbatim: sport.name)
                                    .font(StrandFont.body)
                                    .foregroundStyle(sport.name == selected ? StrandPalette.link : StrandPalette.textPrimary)
                                Spacer()
                                if sport.name == selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(StrandPalette.success)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                            .padding(.horizontal, 12)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(sport.name == selected ? .isSelected : [])
                    }
                }
            }
            .frame(maxHeight: 240)
            .background(StrandPalette.surfaceInset, in: inputShape)
            .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))

            HStack(spacing: NoopMetrics.space3) {
                WorkoutCancelButton()
                Spacer()
                Button(action: confirm) {
                    Label("Merge as \(selected)", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(PrimaryPillButtonStyle())
            }
        }
        .padding(NoopMetrics.space6)
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: .infinity)
        .noopSheetPresentation(largeFirst: false)
        #endif
        .background(StrandPalette.surfaceOverlay)
    }

    var body: some View { mergePicker }
}

#if DEBUG
#Preview("Name a merged session") {
    StartWorkoutSheet { _ in }
        .preferredColorScheme(.dark)
}
#endif
