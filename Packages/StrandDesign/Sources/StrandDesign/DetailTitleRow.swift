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

extension View {
    /// The expanded screen title (`StrandFont.title1`: `.title`, bold) that scales down to fit a long word instead of
    /// hyphenating it, for the same reason as `headerTitleFit`. It wraps between words, three lines at most.
    func expandedTitleFit() -> some View {
        modifier(ExpandedTitleFit())
    }
}

private struct ExpandedTitleFit: ViewModifier {
    /// `.title` at the default size, scaled like `.title`.
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 28
    @Environment(\.dynamicTypeSize) private var typeSize

    /// `StrandFont.title1` itself short of the accessibility sizes, exactly as it was.
    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content
                .font(.system(size: size, weight: .bold))
                .lineLimit(3)
                .minimumScaleFactor(0.5)
        } else {
            content
                .font(StrandFont.title1)
        }
    }
}

/// The longest word of a header title, set by a screen whose title is data (a metric name the person's language
/// can make 24 letters long). While it is set, `NoopDetailTitleRow` measures that word and scales its title type down
/// until the word fits on one line, so SwiftUI never has to break it mid-word. Unset, which is every other screen,
/// the title is laid out exactly as before.
private struct HeaderTitleLongestWordKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var headerTitleLongestWord: String? {
        get { self[HeaderTitleLongestWordKey.self] }
        set { self[HeaderTitleLongestWordKey.self] = newValue }
    }
}

enum HeaderTitleWords {
    /// The longest unbreakable word of `title`: the pieces between spaces, hyphens and slashes, the way text wraps.
    static func longest(in title: String) -> String? {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-\u{2010}\u{2011}\u{2013}\u{2014}/"))
        return title.components(separatedBy: separators).filter { !$0.isEmpty }.max { $0.count < $1.count }
    }
}

public extension View {
    /// Keeps every word of this screen's header title whole. Pass the title the header shows (a data title, so a
    /// metric name or a marker name); when its longest word is wider than the row, the title's type scales down to fit
    /// the word instead of the word breaking across two lines.
    func headerTitleKeepsWordsWhole(of title: String) -> some View {
        environment(\.headerTitleLongestWord, HeaderTitleWords.longest(in: title))
    }
}

private struct HeaderTitleAvailableWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct HeaderTitleWordWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct HeaderTitleFit: ViewModifier {
    let lines: Int
    /// `.caption2` at the default size, scaled like `.caption2`.
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 11
    @Environment(\.headerTitleLongestWord) private var longestWord
    @State private var availableWidth: CGFloat = 0
    @State private var wordWidth: CGFloat = 0

    /// How far the title type shrinks so its longest word fits the row: 1 when it already does (or nothing is
    /// measured yet), never below 0.3.
    private var fitScale: CGFloat {
        guard availableWidth > 0, wordWidth > availableWidth else { return 1 }
        return max(0.3, availableWidth * 0.98 / wordWidth)
    }

    func body(content: Content) -> some View {
        if let longestWord {
            content
                .font(.system(size: size * fitScale, weight: .bold))
                .lineLimit(lines)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: HeaderTitleAvailableWidthKey.self, value: proxy.size.width)
                    }
                }
                .background(alignment: .leading) {
                    // The longest word at the unscaled size, measured and never shown.
                    Text(longestWord)
                        .tracking(StrandFont.screenOverlineTracking)
                        .textCase(.uppercase)
                        .font(.system(size: size, weight: .bold))
                        .lineLimit(1)
                        .fixedSize()
                        .hidden()
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: HeaderTitleWordWidthKey.self, value: proxy.size.width)
                            }
                        }
                        .accessibilityHidden(true)
                }
                .onPreferenceChange(HeaderTitleAvailableWidthKey.self) { availableWidth = $0 }
                .onPreferenceChange(HeaderTitleWordWidthKey.self) { wordWidth = $0 }
        } else {
            content
                .font(.system(size: size, weight: .bold))
                .lineLimit(lines)
                .minimumScaleFactor(0.5)
        }
    }
}
