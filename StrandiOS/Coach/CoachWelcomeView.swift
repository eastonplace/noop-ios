#if os(iOS)
import SwiftUI
import StrandDesign

/// A new conversation: a greeting, one line about today, the live readings Coach already holds, a private note, then
/// the starters as a 2x2 grid just above the composer. Every availability state uses the same calm layout; the state
/// is explained in the greeting area. Values come from the snapshot the engine already built; nothing is read here.
struct CoachWelcomeView: View {
    let availability: LocalCoachAvailability
    let hasConsent: Bool
    let snapshot: LocalCoachSnapshot
    let onAsk: (String) -> Void
    let onSettings: () -> Void
    let onPlan: () -> Void
    var journalWidget: CoachJournalWidget? = nil

    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 31
    @ScaledMetric(relativeTo: .body) private var pillHeight: CGFloat = 30

    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The greeting floats between the header and the starters, as the mockup sets it.
            Spacer(minLength: 24)
            greetingBlock
                .padding(.horizontal, 24)
            if let journalWidget {
                journalWidget.padding(.horizontal, 16).padding(.top, NoopMetrics.space5)
            }
            Spacer(minLength: 28)
            VStack(spacing: 10) {
                if availability == .available && !hasConsent { accessRow }
                starterGrid
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach.welcome")
    }

    // MARK: Greeting

    private var greetingBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "sparkle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .accessibilityHidden(true)
            Text(greetingTitle)
                .font(StrandFont.sized(titleSize, weight: .semibold))
                .tracking(-titleSize * 0.02)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(3).minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            state
                .padding(.top, 12)
            if !pills.isEmpty { pillRow.padding(.top, 18) }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "lock").font(.system(size: 12, weight: .regular)).accessibilityHidden(true)
                Text("Private. Coach runs on this iPhone.").coachFont(12.5, .regular, relativeTo: .footnote)
            }
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.top, 18)
        }
    }

    private var greetingTitle: LocalizedStringKey {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning."
        case 12..<17: "Good afternoon."
        default: "Good evening."
        }
    }

    /// The line under the title: today's recovery when it is known, otherwise what stands between the person and an
    /// answer.
    @ViewBuilder private var state: some View {
        switch availability {
        case .available:
            line { availableText }
        case .checking:
            HStack(spacing: NoopMetrics.space2) {
                ProgressView().controlSize(.small)
                line { Text("Checking Apple Intelligence on this iPhone") }
            }
        case .disabled:
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                line { Text("Coach is paused. Resume it in Coach settings.") }
                Button("Open Coach settings", action: onSettings).buttonStyle(SecondaryPillButtonStyle())
            }
        case .notReady:
            line { Text("Apple Intelligence is still getting ready on this iPhone. Coach can answer once it finishes.") }
        case .unsupported:
            line { Text("Coach needs Apple Intelligence, which this iPhone does not support.") }
        case .unavailable(let message):
            line { Text(verbatim: message) }
        }
    }

    private func line(@ViewBuilder _ text: () -> Text) -> some View {
        text().coachFont(17, .regular)
            .foregroundStyle(StrandPalette.textSecondary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var availableText: Text {
        guard let score = reading("recovery"), let day = snapshot.latestDay.flatMap(LocalCoachWindow.date) else {
            return hasConsent ? Text("What would you like to work on?")
                : Text("Ask anything. With your permission, Coach reads your records on this iPhone before it answers.")
        }
        let word = Text(verbatim: RecoveryBands.word(for: score).lowercased())
            .fontWeight(.semibold)
            .foregroundStyle(RecoveryBands.color(for: score))
        let calendar = LocalCoachWindow.calendar
        let age = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: Date())).day ?? 0
        if age <= 0 { return Text("Recovery is \(word) today. What do you want to work on?") }
        if age == 1 { return Text("Recovery was \(word) yesterday. What do you want to work on?") }
        return Text("Recovery was \(word) on \(LocalCoachCardFormat.humanDay(day)). What do you want to work on?")
    }

    // MARK: Readings

    private func reading(_ id: String) -> Double? {
        guard hasConsent, let metric = snapshot.metrics.first(where: { $0.id == id }),
              let value = Double(metric.value), value.isFinite else { return nil }
        return value
    }

    private struct Reading: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let text: String
        let label: LocalizedStringKey
    }

    /// Recovery, sleep and strain, only the ones Coach already holds a value for.
    private var pills: [Reading] {
        var readings: [Reading] = []
        if let score = reading("recovery") {
            let text = LocalCoachCardFormat.whole(score, unit: "%")
            readings.append(Reading(id: "recovery", symbol: "heart.fill", tint: RecoveryBands.color(for: score),
                                    text: text, label: "Recovery \(text)"))
        }
        if let hours = reading("sleep"), hours >= 0 {
            let text = LocalCoachCardFormat.duration(minutes: hours * 60)
            readings.append(Reading(id: "sleep", symbol: "moon.fill", tint: StrandPalette.sleepAccent,
                                    text: text, label: "Sleep \(text)"))
        }
        if let stored = reading("strain") {
            let text = UnitFormatter.effortDisplay(stored, scale: effortScale)
            readings.append(Reading(id: "strain", symbol: "flame.fill", tint: StrandPalette.strainAccent,
                                    text: text, label: "Strain \(text)"))
        }
        return readings
    }

    private var pillRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { ForEach(pills) { pill($0) } }
            VStack(alignment: .leading, spacing: 8) { ForEach(pills) { pill($0) } }
        }
    }

    private func pill(_ reading: Reading) -> some View {
        HStack(spacing: 6) {
            Image(systemName: reading.symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(reading.tint).accessibilityHidden(true)
            Text(verbatim: reading.text).coachFont(13.5, .semibold, relativeTo: .footnote, digits: true)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .neutralPillChrome()
        .frame(minHeight: pillHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(reading.label))
    }

    // MARK: Access

    /// The consent notice: a compact quiet row above the grid while records are off. It is not a starter.
    private var accessRow: some View {
        Button(action: onSettings) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
                Text("Choose what Coach can read").coachFont(14, .medium, relativeTo: .subheadline)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minHeight: 44)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("General questions work without personal records."))
        .accessibilityIdentifier("coach.chooseAccess")
    }

    // MARK: Starters

    private struct Starter: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let subtitle: LocalizedStringKey
        let asksModel: Bool
        let action: () -> Void
    }

    private var starters: [Starter] {
        let recovery = reading("recovery")
        return [
            Starter(id: LocalCoachTopic.today.rawValue, title: "Plan my day",
                    subtitle: recovery.map { LocalizedStringKey("From \(LocalCoachCardFormat.whole($0))% recovery") }
                        ?? "Recovery and sleep",
                    asksModel: true) { onAsk(LocalCoachTopic.today.prompt) },
            Starter(id: LocalCoachTopic.training.rawValue, title: "Review my training",
                    subtitle: "Sessions and load", asksModel: true) { onAsk(LocalCoachTopic.training.prompt) },
            Starter(id: LocalCoachTopic.sleep.rawValue, title: "Understand my sleep",
                    subtitle: "Compare recent nights", asksModel: true) { onAsk(LocalCoachTopic.sleep.prompt) },
            Starter(id: "plan", title: "Build a workout", subtitle: "Review before saving",
                    asksModel: false, action: onPlan)
        ]
    }

    @ViewBuilder private var starterGrid: some View {
        let items = starters
        // Each card is as tall as the taller of its row, never taller: the grid keeps its natural height.
        if typeSize.isAccessibilitySize {
            VStack(spacing: 10) { ForEach(items) { card($0) } }
        } else {
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow { card(items[0]); card(items[1]) }
                GridRow { card(items[2]); card(items[3]) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card(_ starter: Starter) -> some View {
        Button(action: starter.action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(starter.title).coachFont(15, .semibold, relativeTo: .subheadline)
                    .tracking(-0.2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(starter.subtitle).coachFont(13, .regular, relativeTo: .footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(EdgeInsets(top: 13, leading: 14, bottom: 14, trailing: 14))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(StrandPalette.card))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .opacity(starter.asksModel && availability != .available ? 0.55 : 1)
        }
        .buttonStyle(CoachCardPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("coach.starter.\(starter.id)")
    }
}

/// A card that dims a little while pressed; no movement, so Reduce Motion needs no second treatment.
private struct CoachCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
#endif
