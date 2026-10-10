import SwiftUI

/// The one header row of a pushed screen: the back chip, then the screen's caps overline title in the same
/// type as a tab root's row (Today's "TODAY"), then, quiet and to the right, an optional tertiary context such
/// as the date being viewed ("Fri, Oct 9") and any trailing control.
///
/// A pushed screen is reached from a tab, so it carries no wordmark of its own and no large title with a
/// subtitle under it: this row is all of its header, and it is also what pins to the top once it scrolls away.
/// At accessibility text sizes the context drops under the title instead of squeezing it, and the title wraps only
/// between words (a word wider than the row is scaled down, never split).
public struct NoopDetailTitleRow<Trailing: View>: View {
    private let title: LocalizedStringKey
    private let context: String?
    private let backAction: () -> Void
    @ViewBuilder private let trailing: () -> Trailing

    private static var chipSize: CGFloat { 32 }

    public init(
        _ title: LocalizedStringKey,
        context: String? = nil,
        backAction: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.context = context
        self.backAction = backAction
        self.trailing = trailing
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NoopMetrics.space2) {
                backChip
                titleText(lines: 1)
                Spacer(minLength: NoopMetrics.space2)
                contextText
                trailing()
            }
            HStack(spacing: NoopMetrics.space2) {
                backChip
                VStack(alignment: .leading, spacing: 2) {
                    titleText(lines: 2)
                    contextText
                }
                Spacer(minLength: NoopMetrics.space2)
                trailing()
            }
        }
        .frame(minHeight: Self.chipSize)
    }

    private var backChip: some View {
        Button(action: backAction) {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: Self.chipSize, height: Self.chipSize)
                .background(Circle().fill(StrandPalette.textPrimary.opacity(0.07)))
                // The chip is small and quiet; the tap area still reaches the 44pt minimum.
                .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }

    private func titleText(lines: Int) -> some View {
        Text(title)
            .tracking(StrandFont.screenOverlineTracking)
            .textCase(.uppercase)
            .foregroundStyle(StrandPalette.textPrimary)
            .headerTitleFit(lines: lines)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var contextText: some View {
        if let context {
            Text(verbatim: context)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
        }
    }
}

public extension NoopDetailTitleRow where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, context: String? = nil, backAction: @escaping () -> Void) {
        self.init(title, context: context, backAction: backAction) { EmptyView() }
    }
}

extension View {
    /// A header title in the screen overline type that never breaks inside a word. It wraps between words (`lines` at
    /// most); when one word is wider than the line, the type is scaled down to fit it instead of being hyphenated.
    ///
    /// SwiftUI hyphenates a word that does not fit, and does so before it scales, when the type is a Dynamic Type text
    /// style (`StrandFont.screenOverline` is `.caption2`, bold). A fixed point size scales first, so the modifier sets
    /// the same size and weight as that style through `ScaledMetric` and scales it with Dynamic Type itself. Apply
    /// `.tracking` to the `Text` before this.
    func headerTitleFit(lines: Int = 2) -> some View {
        modifier(HeaderTitleFit(lines: lines))
    }
}

private struct HeaderTitleFit: ViewModifier {
    let lines: Int
    /// `.caption2` at the default size, scaled like `.caption2`.
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 11

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: .bold))
            .lineLimit(lines)
            .minimumScaleFactor(0.5)
    }
}
