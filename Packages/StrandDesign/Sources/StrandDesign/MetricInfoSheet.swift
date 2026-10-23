import SwiftUI

/// One headed part of a `MetricInfoSheet`: a short heading and the paragraphs under it.
public struct MetricInfoSection: Identifiable, Hashable, Sendable {
    public let heading: String
    public let paragraphs: [String]
    public var id: String { heading }

    public init(heading: String, paragraphs: [String]) {
        self.heading = heading
        self.paragraphs = paragraphs
    }

    public init(heading: String, body: String) {
        self.init(heading: heading, paragraphs: [body])
    }
}

/// The shared "what this means" sheet behind a section's ⓘ: a title and ordered, headed sections in a scrolling
/// sheet with a Done button. Present it with `.sheet`; it brings its own detents. Text follows Dynamic Type and every
/// heading is a VoiceOver heading.
public struct MetricInfoSheet: View {
    private let title: String
    private let sections: [MetricInfoSection]
    @Environment(\.dismiss) private var dismiss

    public init(title: String, sections: [MetricInfoSection]) {
        self.title = title
        self.sections = sections
    }

    public var body: some View {
        // A custom header instead of a NavigationStack toolbar: on iOS 26 a toolbar button is wrapped in Liquid Glass
        // automatically, which put an oval behind "Done".
        VStack(spacing: 0) {
            ZStack {
                Text(verbatim: title)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 72)
                    .accessibilityAddTraits(.isHeader)
                HStack {
                    Spacer(minLength: 0)
                    Button { dismiss() } label: {
                        Text("Done")
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.accent)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, NoopMetrics.space3)
            .padding(.top, NoopMetrics.space2)
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                            Text(verbatim: section.heading)
                                .font(StrandFont.subhead.weight(.semibold))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                Text(verbatim: paragraph)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(NoopMetrics.cardInnerPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(StrandPalette.surfaceOverlay.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
