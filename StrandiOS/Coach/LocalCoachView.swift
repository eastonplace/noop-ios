#if os(iOS)
import SwiftUI
import StrandDesign
import MarkdownUI
import CoachPresentation
import PhotosUI

enum LocalCoachScreen: String, CaseIterable, Identifiable {
    case home, chat, plan, memory
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Overview"
        case .chat: "Conversation"
        case .plan: "Your plan"
        case .memory: "About you"
        }
    }
}

/// All rendered values come from the engine. The separate DEBUG host labels fixture data explicitly.
struct LocalCoachView: View {
    @EnvironmentObject private var coach: LocalCoachEngine
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var voice = LocalCoachVoice()
    @State private var voicePrefix = ""
    @State private var dictating = false
    @State private var visible = false
    @State private var voiceTask: Task<Void, Never>?
    @State private var photo: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var attachmentText = ""
    @State private var showAttachment = false
    @State private var attachmentTask: Task<Void, Never>?
    @State private var attachmentID: UUID?
    @State private var inputError: String?
    @State private var showDiagnostics = false
    @State private var screen: LocalCoachScreen
    @State private var composer = ""
    @State private var showLibrary = false
    @State private var showSettings = false
    @State private var showSources = false
    @State private var showPlanBuilder = false
    @State private var selectedTopic = LocalCoachTopic.today
    @FocusState private var composerFocused: Bool
    // The same chrome inputs ScreenScaffold reads, so the pinned header below behaves like every other tab
    // root: app chrome only in the standard presentation and only at a root (a detail owns a back chevron instead).
    @Environment(\.screenScaffoldNavigationRole) private var navigationRole
    @Environment(\.screenScaffoldPresentation) private var scaffoldPresentation
    @Environment(\.appHeaderChromeVisibility) private var chromeVisibility
    @Environment(\.dismiss) private var dismiss

    init(screen: LocalCoachScreen = .home) { _screen = State(initialValue: screen) }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch screen {
                case .home: overview
                case .chat: conversation
                case .plan: LocalCoachPlanView(onBuild: { showPlanBuilder = true })
                case .memory: LocalCoachMemoryView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            statusNote
            if screen == .home || screen == .chat { composerView }
        }
        // The header is pinned (not part of any scroll) so the conversation keeps its own scroll view,
        // scroll-to-bottom and keyboard-avoiding composer exactly as before.
        .safeAreaInset(edge: .top, spacing: 0) { pinnedHeader }
        .background(StrandPalette.appCanvas.ignoresSafeArea())
        .foregroundStyle(StrandPalette.textPrimary)
        .tint(StrandPalette.accent)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showLibrary) {
            LocalCoachLibraryView { screen = .chat }
                .noopSheetPresentation(largeFirst: true)
        }
        .sheet(isPresented: $showSettings) {
            LocalCoachSettingsView().noopSheetPresentation(largeFirst: true)
        }
        .sheet(isPresented: $showSources) {
            LocalCoachSourcesView(evidence: coach.snapshot.evidence, title: "Your context")
                .noopSheetPresentation(largeFirst: true)
        }
        .sheet(isPresented: $showPlanBuilder) {
            LocalCoachPlanBuilder {
                screen = .plan
            }
            .noopSheetPresentation(largeFirst: true)
        }
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack {
                LocalCoachDiagnosticsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDiagnostics = false } } }
            }
            .coachSettingsSheetEnvironment()
            .noopSheetPresentation(largeFirst: true)
        }
        .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
        .sheet(isPresented: $showAttachment) { attachmentReview.noopSheetPresentation(largeFirst: true) }
        .task { visible = true; consumeSiriDraft() }
        .task(id: coach.recordContextID) { await coach.refresh() }
        .onDisappear { visible = false; stopInputs() }
        .onReceive(NotificationCenter.default.publisher(for: LocalCoachIntentBridge.notification)) { _ in consumeSiriDraft() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { consumeSiriDraft() } else { stopInputs() }
        }
        .onChange(of: coach.preferences) { _, _ in stopInputs() }
        .onChange(of: coach.snapshot.sourceID) { _, _ in stopInputs() }
        .onChange(of: photo) { _, item in if let item { readPhoto(item) } }
        .onChange(of: voice.transcript) { _, text in
            guard dictating else { return }
            composer = voicePrefix + text
        }
        .onChange(of: coach.isResponding) { old, current in
            if old && !current && visible {
                if coach.preferences.enabled && coach.preferences.speakReplies && !coach.isPreview && coach.responseSeconds != nil,
                   let reply = coach.messages.last, reply.role == .assistant, !reply.isInterrupted {
                    voice.speak(reply.text)
                }
                consumeSiriDraft()
            }
        }
        .onChange(of: coach.preferences.usePersonalData) { _, _ in
            Task { await coach.refresh() }
        }
        .onChange(of: coach.selectedConversationID) { old, new in
            #if DEBUG
            // A capture that asked for a page (`--noop-coach-page`) stays on it when the saved thread loads.
            if QACoachPage.requested != nil { return }
            #endif
            if old != new, !coach.messages.isEmpty { screen = .chat }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach.studio")
    }

    // MARK: Pinned header

    /// Canonical tab-root chrome, pinned: the app header chrome (strap / sync / profile) once, one title
    /// row, and the section switcher. Compact on purpose: the conversation needs the vertical room, and an
    /// expanded title would otherwise sit above the keyboard-avoiding composer.
    private var pinnedHeader: some View {
        VStack(spacing: 0) {
            if showsAppChrome { AppHeaderChrome() }
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                titleHeader
                    .padding(.horizontal, NoopMetrics.space4)
                sectionPicker
            }
            // No top padding: the title row sits where Today's and Trends' do, directly under the chrome.
            .padding(.bottom, 6)
            .background(StrandPalette.appCanvas)
            .overlay(alignment: .bottom) {
                Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
            }
        }
    }

    /// App chrome belongs to a tab root only; a pushed or modal Coach owns its own header instead.
    private var showsAppChrome: Bool {
        scaffoldPresentation == .standard && chromeVisibility == .visible && navigationRole == .root
    }

    /// At the tab root the chrome row already carries the wordmark, so the title is the shared compact title row
    /// (like Today's and Trends') with the history and settings buttons trailing. Anywhere the chrome is absent
    /// the canonical compact header supplies the one wordmark and the back chevron.
    @ViewBuilder private var titleHeader: some View {
        if showsAppChrome {
            NoopTabTitleRow("Coach") { coachActions }
        } else {
            NoopScreenHeader(
                title: "Coach",
                backAction: backAction,
                style: .compact
            ) { coachActions }
        }
    }

    /// History and settings as compact chip-family icon buttons, the same capsule as Trends' share button.
    private var coachActions: some View {
        HStack(spacing: NoopMetrics.space2) {
            Button { showLibrary = true } label: {
                WidgetChip(systemImage: "clock.arrow.circlepath", showsChevron: false, overhangs: false)
                    .chipHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Conversation history")
            Button { showSettings = true } label: {
                WidgetChip(systemImage: "slider.horizontal.3", showsChevron: false, overhangs: false)
                    .chipHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Coach settings")
        }
    }

    private var backAction: (() -> Void)? {
        guard navigationRole == .detail else { return nil }
        return { dismiss() }
    }

    /// The canonical segmented control. If the four titles ever outgrow the width (small phones, large
    /// Dynamic Type) the control scrolls horizontally instead of truncating.
    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            SegmentedPillControl(
                LocalCoachScreen.allCases,
                selection: Binding(
                    get: { screen },
                    set: { item in
                        composerFocused = false
                        screen = item
                    }
                ),
                identifier: { "coach.tab.\($0.rawValue)" },
                label: { $0.title }
            )
            .padding(.horizontal, NoopMetrics.space4)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    /// The model's state as the screen draws it (a DEBUG launch argument can stand in for it in captures).
    private var availability: LocalCoachAvailability {
        #if DEBUG
        QACoachAvailability.requested ?? coach.availability
        #else
        coach.availability
        #endif
    }

    @ViewBuilder private var statusNote: some View {
        if let error = inputError ?? voice.errorText ?? coach.errorText ?? LocalCoachIntentBridge.errorText {
            statusStrip { CoachNotice(error: error) }
                .accessibilityIdentifier("coach.error")
        } else if coach.recordsUpdating && (screen == .home || screen == .chat) {
            statusStrip {
                CoachNotice(text: Text("Your records are updating. General chat is available."), tone: .info)
            }
            .accessibilityIdentifier("coach.recordsUpdating")
        }
    }

    /// A flat status line over the page foot: canvas ground, one hairline above, no box.
    private func statusStrip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, NoopMetrics.space4).padding(.vertical, NoopMetrics.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StrandPalette.appCanvas)
            .overlay(alignment: .top) {
                Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
            }
    }

    // MARK: Overview

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if coach.isPreview { LocalCoachFixtureLabel().padding(.bottom, NoopMetrics.space3) }
                outlook
                if !coach.snapshot.metrics.isEmpty {
                    CoachSectionSeparator()
                    CoachMetricStrip(metrics: Array(coach.snapshot.metrics.prefix(3)))
                }
                if !coach.preferences.usePersonalData {
                    CoachSectionSeparator()
                    consentSection
                }
                CoachSectionSeparator()
                topicSection
                CoachSectionSeparator()
                planEntry
                CoachSectionSeparator()
                briefSection
                CoachSectionSeparator()
                sourcesEntry
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.top, CoachRhythm.pageTop)
            .padding(.bottom, CoachRhythm.pageBottom)
        }
        .refreshable { await coach.refresh() }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("coach.overview")
    }

    /// The daily outlook: headline, the brief under it, and the model's state as a pill. The record's real date
    /// sits at the eyebrow's trailing edge, as it does on the Coach cards.
    private var outlook: some View {
        CoachSection("Your daily outlook", systemImage: "sun.horizon", tint: .accent,
                     trailing: CoachRecordDate.trailing(day: coach.snapshot.latestDay)) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text(coach.preferences.usePersonalData ? "Your day, in focus." : "Start with your goals.")
                    .font(StrandFont.title1)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(coach.dailyBrief.hasPrefix("Allow local") ? coach.snapshot.summary : coach.dailyBrief)
                    .font(StrandFont.subhead).lineSpacing(3)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(5)
            }
            availabilityPill
        }
    }

    private var availabilityPill: some View {
        let title = coach.isPreview ? "Sample records, no model inference" : availability.title
        let tone: StrandTone = switch availability {
        case .available: .accent
        case .checking: .neutral
        default: .warning
        }
        return StatePill(LocalizedStringKey(title), tone: tone, pulsing: availability == .checking)
    }

    private var consentSection: some View {
        CoachSection("Make it personal", systemImage: "lock.shield", tint: .accent) {
            Text("Allow Coach to read your selected NOOP records on this iPhone. Your local coach does not send them to a cloud model.")
                .font(StrandFont.subhead).lineSpacing(3)
                .foregroundStyle(StrandPalette.textSecondary)
            Button {
                coach.preferences.usePersonalData = true
            } label: {
                Text("Use my local records")
            }
            .buttonStyle(CoachPrimaryPillStyle())
            .accessibilityIdentifier("coach.allowRecords")
        }
    }

    private var topicSection: some View {
        CoachSection("Explore with Coach", systemImage: "bubble.left.and.text.bubble.right", tint: .accent) {
            CoachChipRow(bleed: NoopMetrics.space4) {
                ForEach(LocalCoachTopic.allCases) { topic in
                    let selected = selectedTopic == topic
                    Button { selectedTopic = topic } label: {
                        WidgetChip(appTitle: LocalizedStringKey(topic.title), systemImage: topic.symbol,
                                   showsChevron: false, overhangs: false, isSelected: selected)
                            .chipHitTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Button { submit(selectedTopic.prompt) } label: {
                HStack(alignment: .top, spacing: NoopMetrics.space3) {
                    Text(selectedTopic.prompt).font(StrandFont.subhead).lineSpacing(3)
                        .foregroundStyle(StrandPalette.textSecondary).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    WidgetChip(appTitle: "Ask", systemImage: "arrow.up", showsChevron: false, overhangs: false)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, -2)
        }
    }

    private var planEntry: some View {
        Button { screen = .plan; if coach.plan == nil { showPlanBuilder = true } } label: {
            CoachRow(
                systemImage: "figure.strengthtraining.traditional", tint: .workout,
                title: Text(LocalizedStringKey(coach.plan?.title ?? "Turn intention into a plan")),
                subtitle: Text(LocalizedStringKey(planEntrySubtitle))
            )
        }
        .buttonStyle(.plain)
    }

    private var planEntrySubtitle: String {
        guard let plan = coach.plan else { return "Build, review and save your next workout." }
        return plan.saved ? "\(plan.days.count) sessions · Saved to your workouts"
            : "\(plan.days.count) sessions · Ready for your review"
    }

    private var briefSection: some View {
        CoachSection("Your rhythm", systemImage: "calendar.badge.clock", tint: .accent) {
            Text("A moment to check in")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            CoachChipRow(bleed: NoopMetrics.space4) {
                briefButton("Morning", symbol: "sun.max", kind: .morning)
                briefButton("Evening", symbol: "moon", kind: .evening)
                briefButton("This week", symbol: "calendar", kind: .weekly)
            }
        }
    }

    private func briefButton(_ title: LocalizedStringKey, symbol: String, kind: LocalCoachBriefKind) -> some View {
        Button {
            screen = .chat
            Task { await coach.generateBrief(kind: kind) }
        } label: {
            WidgetChip(appTitle: title, systemImage: symbol, showsChevron: false, overhangs: false)
                .chipHitTarget()
        }
        .buttonStyle(.plain)
    }

    private var sourcesEntry: some View {
        Button { showSources = true } label: {
            CoachRow(systemImage: "checkmark.shield", tint: .accent,
                     title: Text("See the records behind your coach"))
        }
        .buttonStyle(.plain)
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NoopMetrics.space5) {
                    if coach.isPreview { LocalCoachFixtureLabel() }
                    if coach.messages.isEmpty { emptyConversation }
                    ForEach(coach.messages) { message in
                        LocalCoachMessageView(message: message, streaming: coach.isResponding && message.id == coach.messages.last?.id,
                                              onSpeak: {
                            guard coach.preferences.enabled, !coach.isPreview else { return }
                            voice.isSpeaking ? voice.stopSpeaking() : voice.speak(message.text)
                        })
                            .id(message.id)
                    }
                    if !coach.activeTools.isEmpty {
                        HStack(spacing: NoopMetrics.space2) {
                            ProgressView().controlSize(.small)
                            Text("Reading " + coach.activeTools.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", "))
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }.accessibilityIdentifier("coach.toolActivity")
                    }
                    Color.clear.frame(height: 1).id("coach.bottom")
                }
                .padding(.horizontal, NoopMetrics.space4)
                .padding(.top, CoachRhythm.pageTop)
                .padding(.bottom, NoopMetrics.space4)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: coach.messages.last?.text) { _, _ in proxy.scrollTo("coach.bottom", anchor: .bottom) }
            .onChange(of: coach.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("coach.bottom", anchor: .bottom) }
            }
            .onChange(of: coach.messages.last?.cards?.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("coach.bottom", anchor: .bottom) }
            }
            .onAppear { if !coach.messages.isEmpty { proxy.scrollTo("coach.bottom", anchor: .bottom) } }
        }.accessibilityIdentifier("coach.conversation")
    }

    /// The first thing in a new conversation: a warm lead, the model's state when it cannot answer, and a few
    /// questions worth asking, each one tap.
    private var emptyConversation: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                CoachMedallion(systemImage: "bubble.left.and.text.bubble.right")
                Text("Let’s connect the dots.").font(StrandFont.title1)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Ask about your sleep, training, recovery or goals. Coach can look at the local records you allow and show its sources.")
                    .font(StrandFont.subhead).lineSpacing(3)
                    .foregroundStyle(StrandPalette.textSecondary)
                if !coach.isPreview && availability != .available { unavailableNotice }
            }
            CoachSectionSeparator()
            CoachSection("Try asking", systemImage: "text.bubble", tint: .accent) {
                VStack(spacing: 0) {
                    ForEach(Array(Self.starterTopics.enumerated()), id: \.element) { index, topic in
                        if index > 0 {
                            Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
                        }
                        Button { submit(topic.prompt) } label: { starterRow(topic) }
                            .buttonStyle(.plain)
                    }
                }
                // The rows carry their own air; pull them in so the gap under the eyebrow matches the rest.
                .padding(.vertical, -NoopMetrics.space2)
            }
        }
    }

    private static let starterTopics: [LocalCoachTopic] = [.today, .sleep, .training]

    private func starterRow(_ topic: LocalCoachTopic) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: topic.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(topicTint(topic).accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(topicTint(topic).accent.opacity(0.14)))
                .accessibilityHidden(true)
            Text(topic.prompt).font(StrandFont.subhead).lineSpacing(2)
                .foregroundStyle(StrandPalette.textSecondary).multilineTextAlignment(.leading)
            Spacer(minLength: NoopMetrics.space1)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, NoopMetrics.space3)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func topicTint(_ topic: LocalCoachTopic) -> DomainTint {
        switch topic {
        case .today, .goals: .accent
        case .training: .workout
        case .sleep: .sleep
        case .recovery: .custom(StrandPalette.recoveryHigh)
        case .stress: .stress
        case .nutrition: .custom(StrandPalette.statusPositive)
        case .habits: .journal
        }
    }

    /// Why Coach cannot answer right now: the model's state as a pill and one plain line about what to do.
    @ViewBuilder private var unavailableNotice: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            StatePill(LocalizedStringKey(availability.title),
                      tone: availability == .checking ? .neutral : .warning,
                      pulsing: availability == .checking)
            switch availability {
            case .checking:
                EmptyView()
            case .disabled:
                Text("Turn Coach back on in Coach settings to ask a question.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            default:
                Text("Local Coach uses Apple’s on-device model. No API key is needed. It never falls back to a cloud model. Apple Intelligence must be enabled and its model downloaded on a supported device.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("coach.unavailable")
    }

    // MARK: Composer

    private var composerRadius: CGFloat { NoopMetrics.radius5 }
    private var canSend: Bool {
        coach.isResponding || !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composerView: some View {
        VStack(spacing: NoopMetrics.space2) {
            if voice.isRecording || voice.isStarting {
                Label(voice.isStarting ? "Preparing on-device dictation" : "Listening on this iPhone", systemImage: "waveform")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
            }
            if attachmentTask != nil {
                HStack(spacing: NoopMetrics.space2) {
                    ProgressView().controlSize(.small)
                    Text("Reading workout text on this iPhone")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            if visible && LocalCoachIntentBridge.hasPendingRequest {
                let blocked = !composer.isEmpty || coach.isResponding
                Button { consumeSiriDraft() } label: {
                    WidgetChip(appTitle: "Load next Siri question", systemImage: "waveform", showsChevron: false,
                               overhangs: false)
                        .chipHitTarget()
                }
                .buttonStyle(.plain)
                .disabled(blocked)
                .opacity(blocked ? 0.45 : 1)
            }
            HStack(alignment: .bottom, spacing: NoopMetrics.space1) {
                // The 36pt circle sits inside a 44pt tap area; pull it back so its edge meets the page gutter.
                attachmentMenu.padding(.leading, -NoopMetrics.space1)
                composerField
            }
            HStack(spacing: 4) {
                Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).accessibilityHidden(true)
                Text("On this iPhone · private by design")
            }
            .font(StrandFont.micro)
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, NoopMetrics.space4).padding(.top, NoopMetrics.space3).padding(.bottom, NoopMetrics.space2)
        .background(StrandPalette.appCanvas)
        .overlay(alignment: .top) {
            Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
        }
    }

    /// The attachment and actions menu as a chip-family circle, same capsule fill and hairline as the other chips.
    private var attachmentMenu: some View {
        Menu {
            Button("New conversation", systemImage: "square.and.pencil") { coach.newConversation(); screen = .chat }
            Button("Build a workout", systemImage: "figure.strengthtraining.traditional") { showPlanBuilder = true }
            Button("Review my latest activity", systemImage: "figure.run") {
                screen = .chat
                Task { await coach.generateBrief(kind: .activity) }
            }
            Button("Your context", systemImage: "doc.text.magnifyingglass") { showSources = true }
            Button("Read workout photo", systemImage: "photo") { showPhotos = true }
            Button("Paste workout text", systemImage: "doc.text") { attachmentText = ""; showAttachment = true }
            Button("Testing & bug reports", systemImage: "ladybug") { showDiagnostics = true }
            if voice.isSpeaking { Button("Stop reading aloud", systemImage: "speaker.slash") { voice.stopSpeaking() } }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(StrandPalette.chipFill))
                .overlay(Circle().stroke(StrandPalette.hairline, lineWidth: 1))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Coach actions")
    }

    /// The text field with dictation and send inside one rounded surface (the chip fill and hairline, a larger
    /// radius), so the whole composer reads as one control.
    private var composerField: some View {
        HStack(alignment: .bottom, spacing: 0) {
            TextField("Ask your coach…", text: $composer, axis: .vertical)
                .font(StrandFont.body).lineLimit(1...5)
                .padding(.leading, NoopMetrics.space4).padding(.vertical, 11)
                .focused($composerFocused)
                .submitLabel(.send).onSubmit { submit(composer) }
                .disabled(voice.isRecording || voice.isStarting)
                .accessibilityIdentifier("coach.composer")
            Button {
                if voice.isRecording || voice.isStarting {
                    dictating = false
                    voiceTask?.cancel()
                    voice.stop()
                } else {
                    inputError = nil
                    voicePrefix = composer.isEmpty ? "" : composer + " "
                    dictating = true
                    voiceTask = Task { await voice.start() }
                }
            } label: {
                Image(systemName: voice.isRecording ? "waveform" : "mic")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(voice.isRecording ? StrandPalette.accent : StrandPalette.textSecondary)
                    .frame(width: 38, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!coach.preferences.enabled || coach.isResponding)
            .accessibilityLabel(voice.isRecording ? "Stop dictation" : "Dictate a question")
            .accessibilityIdentifier("coach.microphone")
            Button {
                if coach.isResponding { coach.cancel() } else { submit(composer) }
            } label: {
                Image(systemName: coach.isResponding ? "stop.fill" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(canSend ? StrandPalette.onInk : StrandPalette.textTertiary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(canSend ? StrandPalette.ink : StrandPalette.chipFill))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!canSend)
            .accessibilityLabel(coach.isResponding ? "Stop response" : "Send message")
            .accessibilityIdentifier("coach.send")
        }
        .background(RoundedRectangle(cornerRadius: composerRadius, style: .continuous).fill(StrandPalette.chipFill))
        .overlay(RoundedRectangle(cornerRadius: composerRadius, style: .continuous)
            .stroke(StrandPalette.hairline, lineWidth: 1))
    }

    private func submit(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !coach.isPreview else { inputError = "This preview uses sample data. Model calls are disabled."; return }
        guard coach.preferences.enabled, coach.availability == .available else {
            inputError = coach.availability.title
            return
        }
        guard text.utf8.count <= 8_000 else {
            inputError = "This question is too long. Split it into smaller questions before sending."
            return
        }
        inputError = nil
        dictating = false
        voiceTask?.cancel()
        voice.cancel()
        composer = ""
        composerFocused = false
        screen = .chat
        Task { await coach.send(text) }
    }

    private func consumeSiriDraft() {
        guard visible, !coach.isPreview, !coach.isResponding, composer.isEmpty,
              !voice.isRecording, LocalCoachIntentBridge.hasPendingRequest,
              let question = LocalCoachIntentBridge.consume() else { return }
        screen = .chat
        composer = question
    }

    private func stopInputs() {
        dictating = false
        voiceTask?.cancel()
        voiceTask = nil
        voice.cancel()
        attachmentID = nil
        attachmentTask?.cancel()
        attachmentTask = nil
        photo = nil
    }

    private func readPhoto(_ item: PhotosPickerItem) {
        attachmentTask?.cancel()
        let token = UUID()
        attachmentID = token
        inputError = nil
        attachmentTask = Task {
            do {
                guard let bytes = try await item.loadTransferable(type: Data.self) else {
                    throw LocalCoachAttachmentError.invalidImage
                }
                let text = try await LocalCoachAttachment.extractWorkoutText(from: bytes)
                guard attachmentID == token, !Task.isCancelled, visible else { return }
                attachmentText = text
                showAttachment = true
            } catch {
                guard attachmentID == token, !(error is CancellationError) else { return }
                inputError = (error as? LocalCoachAttachmentError)?.localizedDescription ?? "This photo could not be read. Try a smaller workout screenshot."
            }
            if attachmentID == token { attachmentTask = nil; attachmentID = nil; photo = nil }
        }
    }

    private var attachmentReview: some View {
        NavigationStack {
            NativeSettingsList {
                Section {
                    Text("Check exercise names and numbers before using this text. Photos are read locally and are not attached to the model request.")
                        .font(StrandFont.footnote).foregroundStyle(.secondary)
                    TextEditor(text: $attachmentText).frame(minHeight: 250)
                } header: { Text("Review workout text") }
                Section {
                    Button("Add reviewed text to my question") {
                        let reviewed = "Help me review this workout text:\n\n" + attachmentText
                        composer = composer.isEmpty ? reviewed : composer + "\n\n" + reviewed
                        screen = .chat
                        showAttachment = false
                    }.disabled(attachmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                               || attachmentText.utf8.count > LocalCoachAttachment.maximumTextBytes)
                } footer: { Text("Send the question when you are ready. Saving a workout requires a separate plan review.") }
            }
            .navigationTitle("Workout text").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showAttachment = false } } }
        }
        .coachSettingsSheetEnvironment()
    }
}

private struct LocalCoachMessageView: View {
    let message: LocalCoachMessage
    let streaming: Bool
    let onSpeak: () -> Void
    @State private var showEvidence = false

    /// A readable measure on wide screens; on a phone the thread is narrower than this.
    private static let measure: CGFloat = 640

    var body: some View {
        Group {
            if message.role == .user { userTurn } else { assistantTurn }
        }
        .sheet(isPresented: $showEvidence) {
            LocalCoachSourcesView(evidence: message.evidence, title: "Sources for this answer")
                .noopSheetPresentation(largeFirst: true)
        }
    }

    private var timeLabel: String { message.createdAt.formatted(date: .omitted, time: .shortened) }

    // MARK: You

    /// The person's own message: a calm bubble on the trailing side, its sender corner a little tighter, the time
    /// small underneath. No eyebrow: alignment says who spoke.
    private var userTurn: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                           bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous)
        return VStack(alignment: .trailing, spacing: 4) {
            Text(message.text)
                .font(StrandFont.subhead).lineSpacing(2)
                .foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(shape.fill(StrandPalette.inset))
                .overlay(shape.stroke(StrandPalette.hairline, lineWidth: 1))
            Text(timeLabel).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                .padding(.trailing, 4)
        }
        .padding(.leading, NoopMetrics.space8)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: String(localized: "You") + ". " + message.text))
    }

    // MARK: Coach

    private var assistantTurn: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionEyebrow("NOOP Coach", systemImage: "sparkle", tint: .accent, trailing: eyebrowTrailing)
            if message.text.isEmpty && streaming {
                HStack(spacing: NoopMetrics.space2) {
                    CoachTypingDots()
                    Text("Looking into it…").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                }
            } else {
                Markdown(message.text)
                    .markdownTheme(.strand)
                    .textSelection(.enabled)
            }
            if let cards = message.cards, !cards.isEmpty {
                VStack(spacing: 12) {
                    ForEach(cards) { card in
                        LocalCoachCardView(card: card)
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    }
                }
                .animation(.easeOut(duration: 0.25), value: cards.map(\.id))
            }
            if !message.toolNames.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 9, weight: .semibold)).accessibilityHidden(true)
                    Text(message.toolNames.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }.joined(separator: " · "))
                }
                .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            }
            if message.isInterrupted {
                StatePill("Response stopped", tone: .neutral, showsDot: false)
            }
            footer
        }
        .frame(maxWidth: Self.measure, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourcesTitle: LocalizedStringKey {
        message.evidence.count == 1 ? "1 source record" : "\(message.evidence.count) source records"
    }

    private var eyebrowTrailing: EyebrowTrailing {
        guard streaming else { return .text(timeLabel) }
        let title: LocalizedStringKey = message.text.isEmpty ? "Thinking" : "Writing"
        return .custom(AnyView(StatePill(title, tone: .accent, pulsing: true)))
    }

    /// Sources on the leading side; read-aloud and share as the same icon chips the Coach header uses.
    @ViewBuilder private var footer: some View {
        let showsActions = message.role == .assistant && !streaming && !message.text.isEmpty
        if !message.evidence.isEmpty || showsActions {
            HStack(spacing: NoopMetrics.space2) {
                if !message.evidence.isEmpty {
                    Button { showEvidence = true } label: {
                        WidgetChip(appTitle: sourcesTitle, systemImage: "doc.text.magnifyingglass", overhangs: false)
                            .chipHitTarget()
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if showsActions {
                    Button(action: onSpeak) {
                        WidgetChip(systemImage: "speaker.wave.2", showsChevron: false, overhangs: false)
                            .chipHitTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Read aloud")
                    ShareLink(item: message.text) {
                        WidgetChip(systemImage: "square.and.arrow.up", showsChevron: false, overhangs: false)
                            .chipHitTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share")
                }
            }
        }
    }
}

/// Chrome for Coach's preference-style sheets (settings, sources, history, editors, diagnostics).
///
/// These intentionally use the same native grouped-list vocabulary as the Settings tab: the pushed
/// destinations they reach (Siri & Shortcuts, Test Centre, cloud coach) render with the settings-detail
/// scaffold presentation and no pinned app chrome, exactly as they do under Settings. The appearance is
/// not forced here: the app root fixes the whole app dark and sheets inherit it.
extension View {
    func coachSettingsSheetEnvironment() -> some View {
        environment(\.screenScaffoldPresentation, .settingsDetail)
            .environment(\.appHeaderChromeVisibility, .hidden)
            .tint(StrandPalette.accent)
    }
}

struct LocalCoachFixtureLabel: View {
    var body: some View {
        StatePill("Preview with synthetic data", tone: .warning)
            .accessibilityIdentifier("coach.syntheticPreview")
    }
}

#if DEBUG
struct LocalCoachPreviewHost: View {
    @StateObject private var coach: LocalCoachEngine
    private let screen: LocalCoachScreen
    private let diagnostics: Bool
    private let deviceCheck: Bool
    init(screen: String) {
        self.screen = LocalCoachScreen(rawValue: screen) ?? .home
        self.diagnostics = screen == "diagnostics"
        self.deviceCheck = screen == "devicecheck"
        _coach = StateObject(wrappedValue: LocalCoachEngine.preview(screen: screen))
    }
    var body: some View {
        NavigationStack {
            if deviceCheck { LocalCoachDeviceCheckView().coachSettingsSheetEnvironment() }
            else if diagnostics { LocalCoachDiagnosticsView().coachSettingsSheetEnvironment() }
            else { LocalCoachView(screen: screen) }
        }
            .environmentObject(coach)
            // Capture scripts scroll the page through the same driver the app shell runs.
            .task { await QAScrollDriver.run() }
    }
}
#endif
#endif
