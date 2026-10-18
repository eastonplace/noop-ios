#if os(iOS)
import SwiftUI
import StrandDesign
import MarkdownUI
import CoachPresentation

/// A value-fed transcript. Live sensor publications do not enter this subtree.
struct CoachConversationView: View {
    let messages: [LocalCoachMessage]
    let activeMessageID: UUID?
    let progress: CoachResponseStage
    let isPreview: Bool
    let snapshot: LocalCoachSnapshot
    let hasConsent: Bool
    let availability: LocalCoachAvailability
    let onAsk: (String) -> Void
    let onEdit: (String) -> Void
    let onRetry: () -> Void
    let onSpeak: (LocalCoachMessage) -> Void
    let onStop: () -> Void
    let onSettings: () -> Void
    let onWorkouts: () -> Void
    let onPlan: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var follow = CoachScrollPolicy()
    /// When the person last moved the transcript by hand. A recent value means "dragging"; a stored flag could stay set
    /// when the scroll view takes the gesture over and `onEnded` never arrives, which would end auto-follow mid-reply.
    @State private var lastDrag = Date.distantPast
    @State private var distanceFromBottom = 0.0

    private var userIsDragging: Bool { Date().timeIntervalSince(lastDrag) < 0.35 }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: NoopMetrics.space6) {
                        if messages.isEmpty { welcome }
                        ForEach(messages) { message in
                            CoachTurnView(
                                message: message,
                                progress: message.id == activeMessageID ? progress : nil,
                                isLatest: message.id == messages.last?.id,
                                onAsk: onAsk, onEdit: onEdit, onRetry: onRetry,
                                onSpeak: { onSpeak(message) }, onStop: onStop,
                                onWorkouts: onWorkouts)
                                .id(message.id)
                        }
                        Color.clear.frame(height: 1)
                            .id("coach.bottom")
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: CoachBottomPositionKey.self,
                                    value: Optional(geometry.frame(in: .named("coach.transcript")).maxY))
                            })
                    }
                    .padding(.horizontal, NoopMetrics.space4)
                    .padding(.top, NoopMetrics.space5)
                    .padding(.bottom, NoopMetrics.space4)
                }
                .coordinateSpace(name: "coach.transcript")
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        lastDrag = Date()
                        if value.translation.height > 8 { follow.pauseFollowing() }
                        else { follow.observe(distanceFromBottom: distanceFromBottom, userIsDragging: true) }
                    })
                .onPreferenceChange(CoachBottomPositionKey.self) { bottom in
                    guard let bottom, bottom.isFinite else { return }
                    distanceFromBottom = Double(bottom - viewport.size.height)
                    follow.observe(distanceFromBottom: distanceFromBottom, userIsDragging: userIsDragging)
                }
                .onChange(of: messages.last?.text) { _, _ in followLatest(scroll) }
                .onChange(of: messages.last?.cards?.count) { _, _ in followLatest(scroll) }
                .onChange(of: messages.last(where: { $0.role == .user })?.id) { _, _ in
                    follow.jumpToLatest()
                    followLatest(scroll)
                }
                .onChange(of: messages.count) { old, count in
                    if count < old { follow.jumpToLatest() }
                    followLatest(scroll)
                }
                // Keyboard and composer growth keep the latest answer in view. An empty thread is read from the top: its
                // welcome is not a reply to keep in view, so it never jumps to the bottom and hides its own title.
                .onChange(of: viewport.size.height) { _, _ in followLatest(scroll) }
                .onChange(of: progress) { old, next in
                    guard !isPreview, scenePhase == .active, old != next,
                          UIAccessibility.isVoiceOverRunning, Self.announces(next) else { return }
                    UIAccessibility.post(notification: .announcement, argument: next.title)
                }
                .onAppear { if !messages.isEmpty { scroll.scrollTo("coach.bottom", anchor: .bottom) } }
                .overlay(alignment: .bottom) {
                    if !follow.followsLatest && !messages.isEmpty {
                        Button {
                            follow.jumpToLatest()
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                scroll.scrollTo("coach.bottom", anchor: .bottom)
                            }
                        } label: {
                            Label("Latest answer", systemImage: "arrow.down")
                                .font(StrandFont.caption.weight(.semibold))
                                .padding(.horizontal, 16).frame(minHeight: 44)
                                .background(StrandPalette.card, in: Capsule())
                                .overlay(Capsule().strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, NoopMetrics.space2)
                        .accessibilityIdentifier("coach.jumpToLatest")
                    }
                }
                .accessibilityIdentifier("coach.conversation")
            }
        }
    }

    /// VoiceOver hears the steps that change what the person is waiting for (a record read, writing, the outcome), not
    /// every bookkeeping stage, which would queue five announcements in a second.
    private static func announces(_ stage: CoachResponseStage) -> Bool {
        switch stage {
        case .reading, .writing, .complete, .stopped, .failed: true
        case .idle, .preparing, .checkingAccess, .evidenceReady: false
        }
    }

    private func followLatest(_ scroll: ScrollViewProxy) {
        guard follow.followsLatest, !messages.isEmpty else { return }
        scroll.scrollTo("coach.bottom", anchor: .bottom)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                SectionEyebrow("NOOP Coach", systemImage: "sparkle", tint: .accent)
                Text("What would you like to work on?")
                    .font(StrandFont.title1).fixedSize(horizontal: false, vertical: true)
                Text("Ask anything. With your permission, Coach reads your records on this iPhone before it answers.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlatSectionSeparator.coach
            welcomeStatus
            VStack(spacing: 0) {
                starter("Plan my day", detail: "Start with my latest recovery and sleep", topic: .today, tint: .neutral)
                CoachHairline()
                starter("Review my training", detail: "Look at recent sessions and load", topic: .training, tint: .workout)
                CoachHairline()
                starter("Understand my sleep", detail: "Compare the nights I have recorded", topic: .sleep, tint: .sleep)
                CoachHairline()
                Button(action: onPlan) {
                    CoachRow(systemImage: "figure.strengthtraining.traditional", tint: .workout,
                             title: Text("Build a workout plan"), subtitle: Text("Review it before saving."))
                        .padding(.vertical, NoopMetrics.space2)
                }
                .buttonStyle(PaperPressStyle())
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach.welcome")
    }

    /// What stands between the person and an answer, above the starters: the access notice while Coach is available,
    /// otherwise the state itself. Never a starter.
    @ViewBuilder private var welcomeStatus: some View {
        switch availability {
        case .available:
            if !hasConsent || snapshot.latestDay != nil {
                accessNotice
                CoachHairline().padding(.top, NoopMetrics.space3)
            }
        case .checking:
            HStack(spacing: NoopMetrics.space2) {
                ProgressView().controlSize(.small)
                Text("Checking Apple Intelligence on this iPhone").font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .frame(minHeight: 24)
            CoachHairline().padding(.top, NoopMetrics.space3)
        case .disabled:
            CoachNotice(text: Text("Coach is paused. Resume it in Coach settings."), tone: .info)
            Button("Open Coach settings", action: onSettings).buttonStyle(SecondaryPillButtonStyle())
                .padding(.top, NoopMetrics.space2)
            CoachHairline().padding(.top, NoopMetrics.space3)
        case .notReady:
            CoachNotice(text: Text("Apple Intelligence is still getting ready on this iPhone. Coach can answer once it finishes."),
                        tone: .info)
            CoachHairline().padding(.top, NoopMetrics.space3)
        case .unsupported:
            CoachNotice(text: Text("Coach needs Apple Intelligence, which this iPhone does not support."), tone: .warning)
            CoachHairline().padding(.top, NoopMetrics.space3)
        case .unavailable(let message):
            CoachNotice(text: Text(message), tone: .warning)
            CoachHairline().padding(.top, NoopMetrics.space3)
        }
    }

    /// Whether Coach may read the person's records, as a compact notice: an ACCESS eyebrow with an Off or On pill, one
    /// line of copy and a Choose chip that opens Coach settings.
    private var accessNotice: some View {
        FlatSection("Access", systemImage: "lock.shield", tint: .neutral,
                    trailing: .pill(hasConsent ? "On" : "Off", tone: hasConsent ? .positive : .neutral),
                    contentSpacing: NoopMetrics.space1) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: NoopMetrics.space3) {
                    accessCopy.fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: NoopMetrics.space2)
                    chooseChip
                }
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    accessCopy.fixedSize(horizontal: false, vertical: true)
                    chooseChip
                }
            }
        }
        .accessibilityIdentifier("coach.access")
    }

    @ViewBuilder private var accessCopy: some View {
        if !hasConsent {
            Text("General questions work without personal records.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        } else if let day = snapshot.latestDay {
            Text("Latest daily record: " + LocalCoachCardFormat.dayLabel(day))
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var chooseChip: some View {
        Button(action: onSettings) {
            WidgetChip(appTitle: "Choose", showsChevron: false, overhangs: false).chipHitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Choose what Coach can read"))
        .accessibilityIdentifier("coach.chooseAccess")
    }

    private func starter(_ title: String, detail: String, topic: LocalCoachTopic, tint: DomainTint) -> some View {
        Button { onAsk(topic.prompt) } label: {
            CoachRow(systemImage: topic.symbol, tint: tint, title: Text(LocalizedStringKey(title)),
                     subtitle: Text(LocalizedStringKey(detail)))
                .padding(.vertical, NoopMetrics.space2)
        }
        .buttonStyle(PaperPressStyle())
        .accessibilityIdentifier("coach.starter.\(topic.rawValue)")
    }
}

private struct CoachBottomPositionKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

/// Each answer owns its disclosures. Updating another answer never resets this one.
private struct CoachTurnView: View {
    let message: LocalCoachMessage
    let progress: CoachResponseStage?
    let isLatest: Bool
    let onAsk: (String) -> Void
    let onEdit: (String) -> Void
    let onRetry: () -> Void
    let onSpeak: () -> Void
    let onStop: () -> Void
    let onWorkouts: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showEvidence = false
    @State private var showAllCards = false
    @State private var copied = false

    private var cards: [LocalCoachCard] { message.cards ?? [] }
    private var working: Bool { progress?.isActive == true }
    private var followUps: [(String, String)] {
        if cards.contains(where: { $0.kind == "sleep" }) {
            return [("Compare nights", "Compare my recorded sleep over the last seven days."),
                    ("Plan tonight", "Help me plan tonight using my recent sleep records.")]
        }
        if cards.contains(where: { $0.kind == "workouts" || $0.kind == "effort" }) {
            return [("Review recovery", "Review my recorded recovery after recent training."),
                    ("Compare this week", "Compare my recent training with last week.")]
        }
        if !cards.isEmpty {
            return [("Explain the change", "Explain changes in my recovery over the last seven days."),
                    ("Check my sleep", "Review my recent sleep records.")]
        }
        return []
    }

    var body: some View {
        Group {
            if message.role == .user { userTurn } else { assistantTurn }
        }
        .sheet(isPresented: $showEvidence) {
            LocalCoachSourcesView(evidence: message.evidence, title: "Sources for this answer")
                .noopSheetPresentation(largeFirst: true)
        }
    }

    /// The person's own message, as #55 draws it: a calm inset bubble with a hairline, its sender corner tighter, the
    /// time small underneath. No eyebrow: alignment says who spoke.
    private var userTurn: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                           bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous)
        return VStack(alignment: .trailing, spacing: NoopMetrics.space1) {
            Text(message.text).font(StrandFont.subhead).lineSpacing(2)
                .foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.leading).textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(shape.fill(StrandPalette.inset))
                .overlay(shape.stroke(StrandPalette.hairline, lineWidth: 1))
            Text(AppClock.hourMinute(message.createdAt)).font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.trailing, NoopMetrics.space1)
        }
        .padding(.leading, NoopMetrics.space8)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contextMenu {
            Button("Edit as a new question", systemImage: "pencil") { onEdit(message.text) }
            Button("Copy question", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("You. \(message.text)"))
        .accessibilityAction(named: Text("Edit as a new question")) { onEdit(message.text) }
    }

    private var assistantTurn: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionEyebrow("NOOP Coach", systemImage: "sparkle", tint: .accent,
                           trailing: .text(AppClock.hourMinute(message.createdAt)))
            if let progress, progress.isActive {
                CoachProgressView(stage: progress, onStop: onStop)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            // Swift record tools build cards before generation. Their values are never parsed from prose. Each card is a
            // flat block between hairlines, in the same language as Today's sections.
            if !cards.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(showAllCards ? cards : Array(cards.prefix(2))) { card in
                        CoachHairline()
                        LocalCoachCardView(card: card)
                            .padding(.vertical, NoopMetrics.space3)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    }
                    CoachHairline()
                    if cards.count > 2 {
                        Button {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { showAllCards.toggle() }
                        } label: {
                            WidgetChip(appTitle: showAllCards ? "Show fewer records" : "\(cards.count - 2) more records",
                                       systemImage: showAllCards ? "chevron.up" : "chevron.down",
                                       showsChevron: false, overhangs: false)
                                .chipHitTarget()
                        }
                        .buttonStyle(.plain)
                        .padding(.top, NoopMetrics.space3)
                        .accessibilityIdentifier("coach.moreCards")
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: cards.map(\.id))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("coach.answer.cards")
            }
            if !message.text.isEmpty {
                Markdown(message.text).markdownTheme(.strand).textSelection(.enabled)
                    .accessibilityIdentifier("coach.answer.explanation")
            }
            if message.isInterrupted && !working {
                CoachNotice(text: Text("This answer stopped before it finished. Available records and text are kept."), tone: .info)
                if isLatest {
                    Button("Try again", systemImage: "arrow.clockwise", action: onRetry)
                        .buttonStyle(SecondaryPillButtonStyle())
                        .accessibilityIdentifier("coach.retry")
                }
            }
            if !working && (!message.text.isEmpty || !cards.isEmpty || !message.evidence.isEmpty) { answerFooter }
            if isLatest && !working && !message.isInterrupted && !followUps.isEmpty {
                CoachChipRow(bleed: NoopMetrics.space4) {
                    ForEach(followUps, id: \.0) { item in
                        Button { onAsk(item.1) } label: {
                            WidgetChip(appTitle: LocalizedStringKey(item.0), showsChevron: false, overhangs: false)
                                .chipHitTarget()
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Asks Coach: \(item.1)"))
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Suggested questions"))
                .accessibilityIdentifier("coach.followUps")
            }
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: working)
        .frame(maxWidth: 680, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One left-aligned row under the answer: the quiet icon buttons (copy, read aloud, share), then the chips for what
    /// it was built from. The chips drop under the buttons when one row would not fit.
    private var answerFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NoopMetrics.space2) {
                if hasAnswer { answerActions }
                footerLinks
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                if hasAnswer { answerActions }
                HStack(spacing: NoopMetrics.space2) { footerLinks }
            }
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                if hasAnswer { answerActions }
                footerLinks
            }
        }
    }

    private var hasAnswer: Bool { !message.text.isEmpty || !cards.isEmpty }

    @ViewBuilder private var footerLinks: some View {
        if !message.evidence.isEmpty {
            Button { showEvidence = true } label: {
                WidgetChip(appTitle: "Sources", systemImage: "doc.text.magnifyingglass",
                           showsChevron: false, overhangs: false)
                    .chipHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Sources"))
            .accessibilityValue(Text("\(message.evidence.count) source records"))
            .accessibilityIdentifier("coach.answer.sources")
        }
        if cards.contains(where: { $0.kind == "workouts" }) {
            Button(action: onWorkouts) {
                WidgetChip(appTitle: "Workouts", systemImage: "figure.run", overhangs: false)
                    .chipHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("View workout history"))
        }
    }

    private var answerActions: some View {
        // Quiet glyphs with a full 44pt tap area each. The row's first glyph sits at the text's left edge.
        HStack(spacing: 0) {
            Button {
                UIPasteboard.general.string = CoachAnswerExport.text(for: message)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    copied = false
                }
            } label: { actionIcon(copied ? "checkmark" : "doc.on.doc") }
            .accessibilityLabel(copied ? "Answer copied" : "Copy answer and records")
            Button(action: onSpeak) { actionIcon("speaker.wave.2") }.accessibilityLabel("Read aloud")
            ShareLink(item: CoachAnswerExport.text(for: message)) { actionIcon("square.and.arrow.up") }
                .accessibilityLabel("Share answer and records")
        }
        .buttonStyle(.plain)
        .padding(.leading, -NoopMetrics.space3)
    }

    private func actionIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(StrandPalette.textSecondary)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

/// The same export powers copy, sharing and read-aloud so a card-first reply never exports an empty answer.
enum CoachAnswerExport {
    static func text(for message: LocalCoachMessage) -> String {
        var sections = (message.cards ?? []).map(LocalCoachCardFormat.exportLine)
        if !message.text.isEmpty { sections.append(message.text) }
        if !message.evidence.isEmpty {
            sections.append("Sources:\n" + message.evidence.map {
                "• " + $0.title + ": " + $0.detail + " (" + $0.source + ")"
            }.joined(separator: "\n"))
        }
        if message.isInterrupted { sections.append("[Interrupted response]") }
        return sections.joined(separator: "\n\n")
    }

    /// Read aloud speaks the answer as a person would read it: the explanation, or the card facts when an answer has
    /// only cards. Source lists and export markers belong to copy and share, not to listening.
    static func spokenText(for message: LocalCoachMessage) -> String {
        if !message.text.isEmpty { return message.text }
        return (message.cards ?? []).map(LocalCoachCardFormat.exportLine).joined(separator: ". ")
    }
}
#endif
