import SwiftUI
import StrandDesign

// MARK: - Every activity
//
// The one searchable grid of catalogue activities the workout screens choose from, so a sport is spelled and drawn the
// same wherever it is picked: inline on the start sheet, and in its own sheet from the manual log.

struct WorkoutActivityGrid: View {
    /// The catalogue name currently chosen, marked on its tile.
    let selected: String
    /// True where choosing a route sport starts a recording (the start sheet); its tile then says so to VoiceOver.
    var hintsGps = false
    /// Offered when a search matches nothing: use the typed words as the sport's own name. nil offers nothing, so a
    /// screen that takes only named sports (a live start) is never asked for free text.
    var onCustom: ((String) -> Void)?
    let onSelect: (String) -> Void

    @State private var query = ""
    @ScaledMetric(relativeTo: .body) private var tileMinimumWidth: CGFloat = 104
    @ScaledMetric(relativeTo: .body) private var tileHeight: CGFloat = 72

    private var filtered: [WorkoutCatalog.Sport] { WorkoutCatalog.matching(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            PaperSearchField("Search sport", text: $query, height: 44, cornerRadius: 10)
                .accessibilityLabel("Search sport")
            if filtered.isEmpty {
                noMatch
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: tileMinimumWidth), spacing: NoopMetrics.space2)],
                          spacing: NoopMetrics.space2) {
                    ForEach(filtered) { sport in tile(sport) }
                }
            }
        }
    }

    @ViewBuilder private var noMatch: some View {
        let typed = query.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("No matching activity")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            if let onCustom, !typed.isEmpty {
                Button { onCustom(typed) } label: {
                    Text("Use “\(typed)” as the sport")
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, NoopMetrics.space2)
    }

    private func tile(_ sport: WorkoutCatalog.Sport) -> some View {
        let isSelected = sport.name == selected
        return Button {
            onSelect(sport.name)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: sportSymbol(sport.name))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? DomainTint.workout.accent : StrandPalette.textSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: sport.name)
                    .font(StrandFont.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, NoopMetrics.space2)
            .frame(maxWidth: .infinity, minHeight: tileHeight)
            .background(RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
                .fill(isSelected ? DomainTint.workout.accent.opacity(0.14) : StrandPalette.chipFill))
            .overlay(RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
                .stroke(isSelected ? DomainTint.workout.accent : StrandPalette.hairline,
                        lineWidth: isSelected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DomainTint.workout.accent)
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: sport.name))
        .accessibilityHint(hintsGps && sport.isDistanceSport ? Text("Records a GPS route") : Text(verbatim: ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - A sheet title with its close button

/// The title row of a workout sheet: the title, and a close button with a 44pt target.
struct WorkoutSheetHeader: View {
    let title: LocalizedStringKey
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            Text(title)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: NoopMetrics.space2)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(StrandPalette.chipFill, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.top, NoopMetrics.space3)
        .padding(.bottom, NoopMetrics.space1)
        .background(StrandPalette.surfaceBase)
    }
}

// MARK: - The quiet Cancel

/// Cancel beside a sheet's primary action. Its 44pt height and its tap shape belong to the label, so the whole of that area
/// answers, not only the word. `fillsWidth` is for the stacked footer at accessibility text sizes.
struct WorkoutCancelButton: View {
    var fillsWidth = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            Text("Cancel")
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The grid in a sheet of its own

/// "All activities" as a sheet, for a screen that has no room for the grid inline (the manual log). Choosing a tile
/// chooses and closes; a search that matches nothing offers the typed words as the sport's own name.
struct WorkoutActivityPickerSheet: View {
    let selected: String
    let onSelect: (String) -> Void
    let onCustom: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            WorkoutActivityGrid(
                selected: selected,
                onCustom: { name in onCustom(name); dismiss() },
                onSelect: { name in onSelect(name); dismiss() })
                .padding(.horizontal, NoopMetrics.space4)
                .padding(.bottom, NoopMetrics.space4)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) { WorkoutSheetHeader(title: "All activities") }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #endif
    }
}
