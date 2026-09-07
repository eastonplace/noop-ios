import SwiftUI
import StrandDesign

/// A task has one native navigation owner. The dashboard status row stays on dashboard screens.
extension View {
    @ViewBuilder
    func noopFocusedTask() -> some View {
        #if os(iOS)
        self
            .environment(\.screenScaffoldPresentation, .settingsDetail)
            .environment(\.appHeaderChromeVisibility, .hidden)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(StrandPalette.appCanvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

struct ExperienceScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20, content: content)
                .padding(16)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
        }
        .background(StrandPalette.appCanvas.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
    }
}

struct ExperienceMetricTile: View {
    let label: String
    let value: String
    var unit: String = ""
    var tint: Color = StrandPalette.textPrimary
    var symbol: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
                Text(LocalizedStringKey(label))
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 5) { number; unitLabel }
                VStack(alignment: .leading, spacing: 2) { number; unitLabel }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        .padding(16)
        .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(StrandPalette.cardBorder, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalizedStringKey(label))
        .accessibilityValue("\(value) \(unit)")
    }
    private var number: some View {
        Text(value).font(StrandFont.metricValue).monospacedDigit().foregroundStyle(tint)
            .lineLimit(1).minimumScaleFactor(0.75)
    }
    private var unitLabel: some View {
        Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
    }
}

struct ExperienceSectionHeading: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title)).font(StrandFont.cardTitle).foregroundStyle(StrandPalette.textPrimary)
            if let detail {
                Text(LocalizedStringKey(detail)).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

struct ExperienceMessage: View {
    let title: String
    let message: String
    var symbol = "info.circle"
    var tint: Color = StrandPalette.textSecondary
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(StrandFont.title2).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(LocalizedStringKey(title)).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text(LocalizedStringKey(message)).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(StrandPalette.cardBorder, lineWidth: 1))
    }
}

struct ExperienceProgress: View {
    let completed: Int
    let total: Int
    var tint: Color = StrandPalette.journalAccent
    var body: some View {
        ZStack {
            Circle().stroke(StrandPalette.inset, lineWidth: 7)
            Circle().trim(from: 0, to: total > 0 ? min(1, Double(completed) / Double(total)) : 0)
                .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text("\(completed)").font(StrandFont.title2).monospacedDigit()
                Text("of \(total)").font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary)
            }
            .foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(width: 76, height: 76)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(completed) of \(total) answered")
    }
}
