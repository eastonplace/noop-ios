import SwiftUI
import StrandDesign

/// Recently used sports as one-tap chips, shared by the start sheet and the manual log. Three short chips share a row;
/// at larger text they stack, so a name is never truncated.
struct WorkoutRecentSportChips: View {
    /// Sport names exactly as stored (catalogue names are data and are never translated).
    let sports: [String]
    /// The sport currently chosen, marked on its chip. Compared without regard to case.
    let selected: String?
    let onSelect: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NoopMetrics.space2) { chips }
            VStack(alignment: .leading, spacing: NoopMetrics.space2) { chips }
        }
    }

    @ViewBuilder private var chips: some View {
        ForEach(sports, id: \.self) { name in chip(name) }
    }

    private func chip(_ name: String) -> some View {
        let isSelected = selected.map { name.caseInsensitiveCompare($0.trimmingCharacters(in: .whitespaces)) == .orderedSame } ?? false
        return Button { onSelect(name) } label: {
            HStack(spacing: 6) {
                Image(systemName: sportSymbol(name))
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
                Text(verbatim: name)
                    .font(StrandFont.subhead.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? StrandPalette.onInk : StrandPalette.textPrimary)
            .padding(.horizontal, NoopMetrics.space3)
            .frame(minHeight: 44)
            .background(Capsule(style: .continuous).fill(isSelected ? StrandPalette.ink : StrandPalette.chipFill))
            .overlay(Capsule(style: .continuous).stroke(isSelected ? Color.clear : StrandPalette.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
