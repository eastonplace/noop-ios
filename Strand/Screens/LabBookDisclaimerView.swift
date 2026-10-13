import SwiftUI
import StrandDesign

// MARK: - First-use / linked disclaimer
//
// What Lab Book is and is not, in five plain points on the flat canvas: a glyph on its quiet disc beside each sentence, a
// hairline between them, and one pill to say it was read. The sheet's own close button sits in the header.

struct LabBookDisclaimerView: View {
    let onClose: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var points: [(symbol: String, text: String)] {
        [
            ("pencil.and.list.clipboard",
             String(localized: "NOOP stores and lines up the numbers you enter yourself. It does not test you, read your results, give medical advice, or diagnose anything.")),
            ("link",
             String(localized: "Anything you see here (including any side-by-side trend) is your own information shown back to you. It's an association, never a cause, and never a medical finding.")),
            ("text.badge.xmark",
             String(localized: "NOOP never decides whether a value is \"normal,\" \"high,\" or \"low.\" Any reference range shown is exactly what you typed from your own report.")),
            ("lock.shield",
             String(localized: "Your records never leave \(Platform.deviceNounPhrase). There's no account, no cloud, no NOOP server. Because NOOP is an independent app you run yourself (not a healthcare provider), it isn't \"HIPAA-covered,\" and that protection doesn't apply here; the safety comes from the data being local-only and yours.")),
            ("stethoscope",
             String(localized: "Always rely on your doctor, pharmacist, or a qualified professional to interpret results and make decisions. If a number worries you, talk to them, not to an app.")),
        ]
    }

    var body: some View {
        ScreenScaffold(title: "About Lab Book", subtitle: "A private notebook, not a medical service.") {
            VStack(alignment: .leading, spacing: 0) {
                let rows = points
                ForEach(Array(rows.enumerated()), id: \.offset) { index, point in
                    if index > 0 { ExploreRowSeparator() }
                    pointRow(point.symbol, point.text)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: onClose) {
                Text("Got it").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .keyboardShortcut(.defaultAction)
            .sheetFooterBar()
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 480, height: 560)
        #endif
        .background(StrandPalette.surfaceBase)
    }

    /// A glyph beside one sentence; from the largest standard text size up the glyph sits over it instead.
    @ViewBuilder
    private func pointRow(_ symbol: String, _ text: String) -> some View {
        let sentence = Text(verbatim: text)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
        Group {
            if ExploreRowLayout.stacks(typeSize) {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    GlyphDisc(symbol, tint: .custom(StrandPalette.metricCyan))
                    sentence.fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(alignment: .top, spacing: NoopMetrics.space3) {
                    GlyphDisc(symbol, tint: .custom(StrandPalette.metricCyan))
                    sentence.fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
