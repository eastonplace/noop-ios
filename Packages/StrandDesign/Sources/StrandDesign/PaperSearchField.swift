import SwiftUI

/// Input behavior for `PaperSearchField`. The default deliberately leaves the platform's text-input
/// behavior untouched so existing call sites keep their current capitalization and correction rules.
public struct PaperSearchInputConfiguration: Equatable, Sendable {
    public enum Capitalization: Equatable, Sendable {
        case platformDefault
        case never
        case words
        case sentences
        case characters
    }

    public enum Autocorrection: Equatable, Sendable {
        case platformDefault
        case enabled
        case disabled
    }

    public let capitalization: Capitalization
    public let autocorrection: Autocorrection

    public init(
        capitalization: Capitalization = .platformDefault,
        autocorrection: Autocorrection = .platformDefault
    ) {
        self.capitalization = capitalization
        self.autocorrection = autocorrection
    }

    public static let platformDefault = PaperSearchInputConfiguration()

    /// Search queries are literal filters rather than prose: do not rewrite or capitalize them.
    public static let searchQuery = PaperSearchInputConfiguration(
        capitalization: .never,
        autocorrection: .disabled
    )
}

/// The single presentation-only search field promoted from the NOOP design lab.
public struct PaperSearchField: View {
    private let placeholder: LocalizedStringKey
    @Binding private var text: String
    private let height: CGFloat
    private let cornerRadius: CGFloat
    private let inputConfiguration: PaperSearchInputConfiguration

    public init(
        _ placeholder: LocalizedStringKey,
        text: Binding<String>,
        height: CGFloat = 48,
        cornerRadius: CGFloat = 15,
        inputConfiguration: PaperSearchInputConfiguration = .platformDefault
    ) {
        self.placeholder = placeholder
        self._text = text
        self.height = height
        self.cornerRadius = cornerRadius
        self.inputConfiguration = inputConfiguration
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                #if !os(macOS)
                .textInputAutocapitalization(inputConfiguration.capitalization.textInputValue)
                #endif
                .disableAutocorrection(inputConfiguration.autocorrection.disabledValue)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: height)
        .background(
            StrandPalette.surfaceInset,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1)
        )
    }
}

#if !os(macOS)
private extension PaperSearchInputConfiguration.Capitalization {
    var textInputValue: TextInputAutocapitalization? {
        switch self {
        case .platformDefault: nil
        case .never: .never
        case .words: .words
        case .sentences: .sentences
        case .characters: .characters
        }
    }
}
#endif

private extension PaperSearchInputConfiguration.Autocorrection {
    var disabledValue: Bool? {
        switch self {
        case .platformDefault: nil
        case .enabled: false
        case .disabled: true
        }
    }
}

#if DEBUG
private struct PaperSearchFieldPreview: View {
    @State private var text = "Running"
    var body: some View {
        PaperSearchField("Search activities", text: $text)
            .padding()
            .background(StrandPalette.canvas)
    }
}

#Preview("PaperSearchField") { PaperSearchFieldPreview() }
#endif
