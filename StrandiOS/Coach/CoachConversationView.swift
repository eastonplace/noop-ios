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
    @State private var dragging = false
    @State private var distanceFromBottom = 0.0

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: NoopMetrics.space6) {
                        if isPreview { LocalCoachFixtureLabel() }
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
                        dragging = true
                        if value.translation.height > 8 { follow.pauseFollowing() }
                        else { follow.observe(distanceFromBottom: distanceFromBottom, userIsDragging: true) }
                    }
                    .onEnded { _ in dragging = false })
                .onPreferenceChange(CoachBottomPositionKey.self) { bottom in
                    guard let bottom, bottom.isFinite else { return }
                    distanceFromBottom = Double(bottom - viewport.size.height)
                    follow.observe(distanceFromBottom: distanceFromBottom, userIsDragging: dragging)
                }
                .onChange(of: messages.last?.text) { _, _ in
                    if follow.followsLatest { scroll.scrollTo("coach.bottom", anchor: .bottom) }
                }
                .onChange(of: messages.last?.cards?.count) { _, _ in
                    if follow.followsLatest { scroll.scrollTo("coach.bottom", anchor: .bottom) }
                }
                .onChange(of: messages.last(where: { $0.role == .user })?.id) { _, _ in
                    follow.jumpToLatest()
                    scroll.scrollTo("coach.bottom", anchor: .bottom)
                }
                .onChange(of: messages.count) { old, count in
                    if count < old { follow.jumpToLatest() }
                    if follow.followsLatest { scroll.scrollTo("coach.bottom", anchor: .bottom) }
                }
                .onChange(of: viewport.size.height) { _, _ in
                    if follow.followsLatest { scroll.scrollTo("coach.bottom", anchor: .bottom) }
                }
                .onChange(of: progress) { old, next in
                    guard !isPreview, scenePhase == .active, old != next,
                          UIAccessibility.isVoiceOverRunning, !next.title.isEmpty else { return }
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

    private var welcome: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space6) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
                Text("What would you like to work on?")
                    .font(StrandFont.title1).fixedSize(horizontal: false, vertical: true)
                Text("Start with a question. Coach can bring your available records into the conversation.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary).lineSpacing(3)
            }
            if availability != .available {
                CoachNotice(text: Text(availability.title + ". Check Coach settings to continue."), tone: .info)
                Button("Open Coach settings", action: onSettings).buttonStyle(SecondaryPillButtonStyle())
            } else if !hasConsent {
                Button(action: onSettings) {
                    CoachRow(systemImage: "lock.shield", title: Text("Choose what Coach can read"),
                             subtitle: Text("General questions work without personal records."))
                }.buttonStyle(PaperPressStyle())
            } else if let day = snapshot.latestDay {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass").accessibilityHidden(true)
                    Text("Latest daily record: " + LocalCoachCardFormat.dayLabel(day))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
            VStack(spacing: 0) {
                starter("Plan my day", detail: "Start with my latest recovery and sleep", topic: .today)
                Divider().overlay(StrandPalette.hairline)
                starter("Review my training", detail: "Look at recent sessions and load", topic: .training)
                Divider().overlay(StrandPalette.hairline)
                starter("Understand my sleep", detail: "Compare the nights I have recorded", topic: .sleep)
            }
            Button(action: onPlan) {
                CoachRow(systemImage: "figure.strengthtraining.traditional", title: Text("Build a workout plan"),
                         subtitle: Text("Review it before saving."))
            }.buttonStyle(PaperPressStyle())
        }
        .accessibilityIdentifier("coach.welcome")
    }

    private func starter(_ title: String, detail: String, topic: LocalCoachTopic) -> some View {
        Button { onAsk(topic.prompt) } label: {
            CoachRow(systemImage: topic.symbol, title: Text(LocalizedStringKey(title)), subtitle: Text(LocalizedStringKey(detail)))
                .padding(.vertical, NoopMetrics.space3)
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

    private var userTurn: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(message.text).font(StrandFont.subhead).lineSpacing(3).textSelection(.enabled)
                .padding(.horizontal, 15).padding(.vertical, 12)
                .background(StrandPalette.inset, in: UnevenRoundedRectangle(
                    topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 5, topTrailingRadius: 18))
            Text(AppClock.hourMinute(message.createdAt)).font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.leading, NoopMetrics.space8)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contextMenu {
            Button("Edit as a new question", systemImage: "pencil") { onEdit(message.text) }
            Button("Copy question", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("Edit as a new question")) { onEdit(message.text) }
    }

    private var assistantTurn: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            SectionEyebrow("NOOP Coach", systemImage: "sparkle", tint: .accent,
                           trailing: .text(AppClock.hourMinute(message.createdAt)))
            if let progress, progress.isActive {
                CoachProgressView(stage: progress, onStop: onStop)
            }
            // Swift record tools build cards before generation. Their values are never parsed from prose.
            if !cards.isEmpty {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    ForEach(showAllCards ? cards : Array(cards.prefix(2))) { card in
                        LocalCoachCardView(card: card)
                            .transition(.opacity)
                    }
                    if cards.count > 2 {
                        Button(showAllCards ? "Show fewer records" : "More records (\(cards.count - 2))",
                               systemImage: showAllCards ? "chevron.up" : "chevron.down") {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { showAllCards.toggle() }
                        }
                        .font(StrandFont.footnote).frame(minHeight: 44)
                        .accessibilityIdentifier("coach.moreCards")
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: cards.map(\.id))
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
            if !message.evidence.isEmpty || !cards.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    if !message.evidence.isEmpty {
                        Button { showEvidence = true } label: {
                            Label("\(message.evidence.count) source records", systemImage: "doc.text.magnifyingglass")
                                .font(StrandFont.footnote).frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("coach.answer.sources")
                    }
                    if cards.contains(where: { $0.kind == "workouts" }) {
                        Button("View workout history", systemImage: "arrow.up.right", action: onWorkouts)
                            .font(StrandFont.footnote).frame(minHeight: 44)
                    }
                }
            }
            if !working && (!message.text.isEmpty || !cards.isEmpty) { answerActions }
            if isLatest && !working && !message.isInterrupted && !followUps.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(followUps, id: \.0) { item in
                        Button { onAsk(item.1) } label: {
                            HStack {
                                Text(LocalizedStringKey(item.0)).font(StrandFont.footnote)
                                Spacer()
                                Image(systemName: "arrow.up.left").font(StrandFont.micro).accessibilityHidden(true)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }
                    }
                }
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityIdentifier("coach.followUps")
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 680, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var answerActions: some View {
        HStack(spacing: 2) {
            Button {
                UIPasteboard.general.string = CoachAnswerExport.text(for: message)
                copied = true
            } label: { actionIcon(copied ? "checkmark" : "doc.on.doc") }
            .accessibilityLabel(copied ? "Answer copied" : "Copy answer and records")
            Button(action: onSpeak) { actionIcon("speaker.wave.2") }.accessibilityLabel("Read aloud")
            ShareLink(item: CoachAnswerExport.text(for: message)) { actionIcon("square.and.arrow.up") }
                .accessibilityLabel("Share answer and records")
            Spacer()
        }
        .foregroundStyle(StrandPalette.textTertiary)
    }

    private func actionIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 14, weight: .regular))
            .frame(width: 44, height: 44).contentShape(Rectangle())
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
}
#endif
