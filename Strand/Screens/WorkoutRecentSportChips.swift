import SwiftUI
import StrandDesign

/// Recently used sports as one-tap chips, shared by the start sheet and the manual log. Short names share a row; when they
/// do not fit, the chips stack, and a name that is longer than the screen wraps onto more lines, so it is never cut off.
struct WorkoutRecentSportChips: View {
    /// Sport names exactly as stored (catalogue names are data and are never translated).
    let sports: [String]
    /// The sport currently chosen, marked on its chip. Compared without regard to case.
    let selected: String?
    let onSelect: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Side by side every chip keeps its one-line width, which is what lets this row measure itself.
            HStack(spacing: NoopMetrics.space2) { chips(wrapping: false) }
            VStack(alignment: .leading, spacing: NoopMetrics.space2) { chips(wrapping: true) }
        }
    }

    @ViewBuilder private func chips(wrapping: Bool) -> some View {
        ForEach(sports, id: \.self) { name in chip(name, wrapping: wrapping) }
    }

    private func chip(_ name: String, wrapping: Bool) -> some View {
        let isSelected = selected.map { name.caseInsensitiveCompare($0.trimmingCharacters(in: .whitespaces)) == .orderedSame } ?? false
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return Button { onSelect(name) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: sportSymbol(name))
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
                Text(verbatim: name)
                    .font(StrandFont.subhead.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(wrapping ? nil : 1)
                    // Wrapping, the name takes the width the screen allows and as many lines as it needs.
                    .fixedSize(horizontal: !wrapping, vertical: true)
            }
            .foregroundStyle(isSelected ? StrandPalette.onInk : StrandPalette.textPrimary)
            .padding(.horizontal, NoopMetrics.space3)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            // A rounded rectangle with a 22pt radius is the capsule at one line, and stays tidy when the name wraps.
            .background(shape.fill(isSelected ? StrandPalette.ink : StrandPalette.chipFill))
            .overlay(shape.stroke(isSelected ? Color.clear : StrandPalette.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
