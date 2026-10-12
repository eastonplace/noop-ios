import SwiftUI

// MARK: - Glance pages
//
// What the live workout screen adds around its figures once it has more than one page: the dots that say which page it is on.

// MARK: Page dots

/// The row of dots under a paged screen. A swipe turns the page, so the dots only say where the wearer is; for VoiceOver and
/// Switch Control they are one adjustable element ("Page 2 of 3, Heart") whose increment and decrement turn the page.
public struct PageDots: View {
    private let titles: [String]
    @Binding private var selection: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - titles: One name per page, in order; VoiceOver says the selected one.
    ///   - selection: The index of the page showing.
    public init(titles: [String], selection: Binding<Int>) {
        self.titles = titles
        self._selection = selection
    }

    /// The page after moving `step` pages from `selection`, which stops at the first and the last page instead of wrapping.
    public static func moved(_ selection: Int, by step: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(selection + step, 0), count - 1)
    }

    /// What VoiceOver says for the selected page.
    public static func spoken(page: Int, count: Int, title: String) -> String {
        String(localized: "Page \(page + 1) of \(count), \(title)", bundle: .module)
    }

    private var current: Int { min(max(selection, 0), max(titles.count - 1, 0)) }

    public var body: some View {
        HStack(spacing: 9) {
            ForEach(titles.indices, id: \.self) { index in
                Circle()
                    .fill(StrandPalette.textPrimary.opacity(index == current ? 1 : 0.28))
                    .frame(width: 7, height: 7)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: current)
        .frame(maxWidth: .infinity, minHeight: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Pages", bundle: .module))
        .accessibilityValue(Text(verbatim: titles.isEmpty ? "" : Self.spoken(page: current, count: titles.count, title: titles[current])))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: selection = Self.moved(current, by: 1, count: titles.count)
            case .decrement: selection = Self.moved(current, by: -1, count: titles.count)
            @unknown default: break
            }
        }
    }
}
