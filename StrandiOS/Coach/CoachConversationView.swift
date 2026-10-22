#if os(iOS)
import SwiftUI
import StrandDesign
import MarkdownUI
import CoachPresentation

/// A value-fed transcript. Live sensor publications do not enter this subtree.
///
/// An empty thread is the new-chat page (`CoachWelcomeView`). Once there are turns the transcript reads as the v2
/// mockup draws it: the person's words in a right-aligned bubble, Coach's answer as plain body text, record cards as
/// flat widgets, and the suggested questions as a row of capsules above the composer with a fade the transcript
/// scrolls under.
struct CoachConversationView: View {
    let messages: [LocalCoachMessage]
    let activeMessageID: UUID?
    let progress: CoachResponseStage
    let isPreview: Bool
    let snapshot: LocalCoachSnapshot
    let hasConsent: Bool
    let availability: LocalCoachAvailability
    /// False while the person is typing, so the keyboard keeps the room for the transcript.
    var showsFollowUps = true
    let onAsk: (String) -> Void
    let onEdit: (String) -> Void
    let onRetry: () -> Void
    let onSpeak: (LocalCoachMessage) -> Void
    let onStop: () -> Void
    let onSettings: () -> Void
    let onWorkouts: () -> Void
    let onPlan: () -> Void
    /// Only the empty welcome shows the check-in. Active threads use the parent's compact Journal access.
    var journalWidget: CoachJournalWidget? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var follow = CoachScrollPolicy()
    /// When the person last moved the transcript by hand. A recent value means "dragging"; a stored flag could stay set
    /// when the scroll view takes the gesture over and `onEnded` never arrives, which would end auto-follow mid-reply.
    @State private var lastDrag = Date.distantPast
    @State private var distanceFromBottom = 0.0

    private var userIsDragging: Bool { Date().timeIntervalSince(lastDrag) < 0.35 }

    /// Two next questions under the newest finished answer. None while it is being written, after a stop or a failure.
    private var followUps: [CoachFollowUp] {
        guard showsFollowUps, let last = messages.last, last.role == .assistant, !last.isInterrupted else { return [] }
        if last.id == activeMessageID, progress.isActive { return [] }
        return CoachFollowUps.suggestions(for: last)
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { scroll in
                ScrollView {
                    if messages.isEmpty {
                        welcome(height: viewport.size.height)
                    } else {
                        LazyVStack(alignment: .leading, spacing: NoopMetrics.space6) {
                            if isPreview { LocalCoachFixtureLabel() }
                            ForEach(messages) { message in
                                CoachTurnView(
                                    message: message,
                                    progress: message.id == activeMessageID ? progress : nil,
                                    isLatest: message.id == messages.last?.id,
                                    onEdit: onEdit, onRetry: onRetry,
                                    onSpeak: { onSpeak(message) }, onStop: onStop,
                                    onWorkouts: onWorkouts, onAsk: onAsk)
                                    .id(message.id)
                            }
                            Color.clear.frame(height: 1)
                                .id("coach.bottom")
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: CoachBottomPositionKey.self,
                                        value: Optional(geometry.frame(in: .named("coach.transcript")).maxY))
                                })
                        }
                        .padding(.horizontal, NoopMetrics.space5)
                        .padding(.top, NoopMetrics.space3)
                        .padding(.bottom, NoopMetrics.space4)
                    }
                }
                // The transcript runs under the follow-ups and the fade above the composer; this margin only keeps the
                // last line clear of them at rest.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !messages.isEmpty { bottomBar(scroll) }
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
                .accessibilityIdentifier("coach.conversation")
            }
        }
    }

    // MARK: Pieces

    private func welcome(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if isPreview {
                LocalCoachFixtureLabel().padding(.horizontal, 24).padding(.top, NoopMetrics.space2)
            }
            CoachWelcomeView(availability: availability, hasConsent: hasConsent, snapshot: snapshot,
                             onAsk: onAsk, onSettings: onSettings, onPlan: onPlan, journalWidget: journalWidget)
                .frame(maxHeight: .infinity)
        }
        .frame(minHeight: height)
    }

    /// The row under the transcript: the suggested questions (or just a little air), on the canvas, with a fade above
    /// that the transcript scrolls under. The jump button rides above it while the person has scrolled away.
    private func bottomBar(_ scroll: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            if followUps.isEmpty {
                Color.clear.frame(height: NoopMetrics.space2)
            } else {
                CoachFollowUpRow(items: followUps, onAsk: onAsk)
                    .padding(.bottom, NoopMetrics.space1)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .background(StrandPalette.appCanvas)
        .overlay(alignment: .top) {
            LinearGradient(colors: [StrandPalette.appCanvas.opacity(0), StrandPalette.appCanvas],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 40).offset(y: -40)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .overlay(alignment: .top) {
            if !follow.followsLatest {
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
                .offset(y: -52)
                .accessibilityIdentifier("coach.jumpToLatest")
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: followUps)
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
    let onEdit: (String) -> Void
    let onRetry: () -> Void
    let onSpeak: () -> Void
    let onStop: () -> Void
    let onWorkouts: () -> Void
    let onAsk: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 16.5
    @State private var showEvidence = false
    #if DEBUG
    /// The cards QA capture opens every record so each widget can be seen without a tap.
    @State private var showAllCards = CommandLine.arguments.contains("--noop-coach-cards-qa")
    #else
    @State private var showAllCards = false
    #endif
    @State private var copied = false

    private var cards: [LocalCoachCard] { message.cards ?? [] }
    private var working: Bool { progress?.isActive == true }

    var body: some View {
        Group {
            if message.role == .user { userTurn } else { assistantTurn }
        }
        .sheet(isPresented: $showEvidence) {
            LocalCoachSourcesView(evidence: message.evidence, title: "Sources for this answer")
                .noopSheetPresentation(largeFirst: true)
        }
    }

    /// The person's own message: a right-aligned bubble on the raised surface, 22pt corners and a 6pt tail at the
    /// bottom-right. No label and no time: alignment says who spoke.
    private var userTurn: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22,
                                           bottomTrailingRadius: 6, topTrailingRadius: 22, style: .continuous)
        return Text(message.text)
            .font(StrandFont.sized(textSize, weight: .regular))
            .lineSpacing(textSize * 0.2)
            .foregroundStyle(StrandPalette.textPrimary)
            .multilineTextAlignment(.leading).textSelection(.enabled)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(shape.fill(StrandPalette.inset))
            .overlay(shape.fill(StrandPalette.chipFill))
            .padding(.leading, NoopMetrics.space10)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contextMenu {
                Button("Edit as a new question", systemImage: "pencil") { onEdit(message.text) }
                Button("Copy question", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("You. \(message.text)"))
            .accessibilityAction(named: Text("Edit as a new question")) { onEdit(message.text) }
    }

    /// Coach's answer is plain body text with no label, avatar or box; records sit below it as flat widgets.
    private var assistantTurn: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            if !message.text.isEmpty {
                Markdown(message.text).markdownTheme(.coachAnswer(size: textSize)).textSelection(.enabled)
                    .accessibilityIdentifier("coach.answer.explanation")
            }
            // Swift record tools build cards before generation. Their values are never parsed from prose.
            if !cards.isEmpty {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    ForEach(showAllCards ? cards : Array(cards.prefix(2))) { card in
                        LocalCoachCardView(card: card, onAskCoach: onAsk)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    }
                    if cards.count > 2 {
                        Button {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { showAllCards.toggle() }
                        } label: {
                            CoachHairlineChip(title: showAllCards ? Text("Show fewer records")
                                                  : Text("\(cards.count - 2) more records"),
                                              trailingSystemImage: showAllCards ? "chevron.up" : "chevron.down")
                                .coachChipHitTarget()
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("coach.moreCards")
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: cards.map(\.id))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("coach.answer.cards")
            }
            if let progress, progress.isActive {
                CoachProgressView(stage: progress, onStop: onStop)
                    .transition(.opacity)
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
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: working)
        .frame(maxWidth: 680, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One row under the answer: copy, read aloud and share as plain tertiary icons, and what it was built from as a
    /// hairline chip on the trailing side. Two rows only when one would not fit.
    private var answerFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NoopMetrics.space2) {
                if hasAnswer { answerActions }
                Spacer(minLength: NoopMetrics.space2)
                footerLinks
            }
            VStack(alignment: .leading, spacing: 0) {
                if hasAnswer { answerActions }
                HStack(spacing: NoopMetrics.space2) { footerLinks }
            }
            VStack(alignment: .leading, spacing: 0) {
                if hasAnswer { answerActions }
                footerLinks
            }
        }
        // The icons' tap areas reach 44pt, so the row pulls up under the answer by the room they add.
        .padding(.top, -NoopMetrics.space2)
    }

    private var hasAnswer: Bool { !message.text.isEmpty || !cards.isEmpty }

    @ViewBuilder private var footerLinks: some View {
        if cards.contains(where: { $0.kind == "workouts" }) {
            Button(action: onWorkouts) {
                CoachHairlineChip(title: Text("Workouts"), systemImage: "figure.run")
                    .coachChipHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("View workout history"))
        }
        if !message.evidence.isEmpty {
            Button { showEvidence = true } label: {
                CoachHairlineChip(title: message.evidence.count == 1 ? Text("1 source") : Text("\(message.evidence.count) sources"),
                                  systemImage: "doc.text.magnifyingglass")
                    .coachChipHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(message.evidence.count) source records"))
            .accessibilityIdentifier("coach.answer.sources")
        }
    }

    private var answerActions: some View {
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
        // The first icon's 44pt tap area starts 13pt left of the glyph; pull it back so the glyph sits on the text edge.
        .padding(.leading, -13)
    }

    private func actionIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(StrandPalette.textTertiary)
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
