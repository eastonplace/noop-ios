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
            .padding(.vertical, 6)
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

    /// At the tab root the chrome row already carries the wordmark, so the title is a single overline row
    /// (like Today's) with the history and settings buttons trailing. Anywhere the chrome is absent the
    /// canonical compact header supplies the one wordmark and the back chevron.
    @ViewBuilder private var titleHeader: some View {
        if showsAppChrome {
            HStack(spacing: NoopMetrics.space2) {
                Text("Coach")
                    .font(StrandFont.screenOverline)
                    .tracking(StrandFont.screenOverlineTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: NoopMetrics.space2)
                coachActions
            }
            .frame(minHeight: 40)
        } else {
            NoopScreenHeader(
                title: "Coach",
                subtitle: "Personal intelligence",
                backAction: backAction,
                style: .compact
            ) { coachActions }
        }
    }

    private var coachActions: some View {
        HStack(spacing: NoopMetrics.space2) {
            NoopIconButton("clock.arrow.circlepath", accessibilityLabel: "Conversation history") {
                showLibrary = true
            }
            NoopIconButton("slider.horizontal.3", accessibilityLabel: "Coach settings") {
                showSettings = true
            }
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

    @ViewBuilder private var statusNote: some View {
        if let error = inputError ?? voice.errorText ?? coach.errorText ?? LocalCoachIntentBridge.errorText {
            NoteCard(LocalizedStringKey(error), style: .warning)
                .accessibilityElement(children: .combine)
                .padding(.horizontal, NoopMetrics.space4).padding(.vertical, NoopMetrics.space2)
                .accessibilityIdentifier("coach.error")
        } else if coach.recordsUpdating && (screen == .home || screen == .chat) {
            NoteCard("Your records are updating. General chat is available.", style: .info)
                .accessibilityElement(children: .combine)
                .padding(.horizontal, NoopMetrics.space4).padding(.vertical, NoopMetrics.space2)
                .accessibilityIdentifier("coach.recordsUpdating")
        }
    }

    // MARK: Overview

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                if coach.isPreview { LocalCoachFixtureLabel() }
                outlook
                if !coach.snapshot.metrics.isEmpty { metricStrip }
                if !coach.preferences.usePersonalData { consentSection }
                topicSection
                planEntry
                briefSection
                Button { showSources = true } label: {
                    StrandCard(padding: 0) {
                        SettingsRow(icon: "checkmark.shield", title: "See the records behind your coach", showsChevron: true)
                    }
                }
                .buttonStyle(PaperPressStyle())
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.top, NoopMetrics.space2)
            .padding(.bottom, NoopMetrics.space6)
        }
        .refreshable { await coach.refresh() }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("coach.overview")
    }

    private var outlook: some View {
        ContentSection {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: "sun.horizon").font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
                    Text("Your daily outlook").strandOverline()
                    Spacer(minLength: 0)
                    Image(systemName: "sparkle").font(StrandFont.subhead).foregroundStyle(StrandPalette.accent)
                }
                .accessibilityElement(children: .combine)
                Text(coach.preferences.usePersonalData ? "Your day, in focus." : "Start with your goals.")
                    .font(StrandFont.title2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(coach.dailyBrief.hasPrefix("Allow local") ? coach.snapshot.summary : coach.dailyBrief)
                    .font(StrandFont.subhead).lineSpacing(3)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(5)
                HStack(spacing: 6) {
                    Circle().fill(coach.availability == .available ? StrandPalette.accent : StrandPalette.textTertiary)
                        .frame(width: 6, height: 6)
                    Text(coach.isPreview ? "Sample records, no model inference" : coach.availability.title)
                        .font(StrandFont.micro)
                    Spacer(minLength: 6)
                    if let day = coach.snapshot.latestDay {
                        Text(day).font(StrandFont.mono(11))
                    }
                }.foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var metricStrip: some View {
        ContentSection {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                ForEach(Array(coach.snapshot.metrics.prefix(3))) { metric in
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text(metric.title).strandOverline().lineLimit(1).minimumScaleFactor(0.7)
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(metric.value).font(StrandFont.metricValue).minimumScaleFactor(0.7)
                            Text(metric.unit).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                        }.lineLimit(1)
                        metricSparkline(metric)
                        Text(metric.detail).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// The canonical StrandDesign `Sparkline` over the same finite samples the metric always drew.
    @ViewBuilder private func metricSparkline(_ metric: LocalCoachMetric) -> some View {
        let values = metric.samples.filter(\.isFinite)
        let tint = metricTint(metric.id)
        if values.count > 1 {
            Sparkline(values: values, gradient: Gradient(colors: [tint.opacity(0.5), tint]),
                      lineWidth: 2, showsHover: false)
                .frame(height: 24)
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(height: 24).accessibilityHidden(true)
        }
    }

    private func metricTint(_ id: String) -> Color {
        if id.localizedCaseInsensitiveContains("sleep") { return StrandPalette.sleepAccent }
        if id.localizedCaseInsensitiveContains("strain") { return StrandPalette.strainAccent }
        return StrandPalette.accent
    }

    private var consentSection: some View {
        ContentSection {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Label("Make it personal", systemImage: "lock.shield").font(StrandFont.headline)
                Text("Allow Coach to read your selected NOOP records on this iPhone. Your local coach does not send them to a cloud model.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Button("Use my local records") {
                    coach.preferences.usePersonalData = true
                }
                .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                .accessibilityIdentifier("coach.allowRecords")
            }
        }
    }

    private var topicSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader("What’s on your mind?", overline: "Explore with Coach")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NoopMetrics.space2) {
                    ForEach(LocalCoachTopic.allCases) { topic in
                        let selected = selectedTopic == topic
                        Button { selectedTopic = topic } label: {
                            Label(topic.title, systemImage: topic.symbol)
                                .font(StrandFont.caption)
                                .padding(.horizontal, NoopMetrics.space3)
                                .frame(height: 32)
                                .foregroundStyle(selected ? StrandPalette.onInk : StrandPalette.textSecondary)
                                .background(selected ? StrandPalette.ink : StrandPalette.inset, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            Button { submit(selectedTopic.prompt) } label: {
                HStack(alignment: .top, spacing: NoopMetrics.space4) {
                    Text(selectedTopic.prompt).font(StrandFont.subhead).lineSpacing(3)
                        .foregroundStyle(StrandPalette.textSecondary).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").foregroundStyle(StrandPalette.accent)
                }
                .contentRowSurface()
            }.buttonStyle(.plain)
        }
    }

    private var planEntry: some View {
        Button { screen = .plan; if coach.plan == nil { showPlanBuilder = true } } label: {
            StrandCard(padding: 0) {
                SettingsRow(
                    icon: "figure.strengthtraining.traditional",
                    title: LocalizedStringKey(coach.plan?.title ?? "Turn intention into a plan"),
                    subtitle: LocalizedStringKey(coach.plan == nil
                        ? "Build, review and save your next workout."
                        : "\(coach.plan?.days.count ?? 0) sessions · Ready for your review"),
                    showsChevron: true
                )
            }
        }
        .buttonStyle(PaperPressStyle())
    }

    private var briefSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader("A moment to check in", overline: "Your rhythm")
            HStack(spacing: NoopMetrics.space2) {
                briefButton("Morning", symbol: "sun.max", kind: .morning)
                briefButton("Evening", symbol: "moon", kind: .evening)
                briefButton("This week", symbol: "calendar", kind: .weekly)
                Spacer(minLength: 0)
            }
        }
    }

    private func briefButton(_ title: LocalizedStringKey, symbol: String, kind: LocalCoachBriefKind) -> some View {
        Button {
            screen = .chat
            Task { await coach.generateBrief(kind: kind) }
        } label: {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(ChipButtonStyle())
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NoopMetrics.space6) {
                    if coach.isPreview { LocalCoachFixtureLabel() }
                    if coach.messages.isEmpty {
                        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                                .font(.system(size: 38, weight: .ultraLight)).foregroundStyle(StrandPalette.accent)
                            Text("Let’s connect the dots.").font(StrandFont.title1)
                            Text("Ask about your sleep, training, recovery or goals. Coach can look at the local records you allow and show its sources.")
                                .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                        }.padding(.vertical, NoopMetrics.space8)
                    }
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
                }.padding(NoopMetrics.space4)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: coach.messages.last?.text) { _, _ in proxy.scrollTo("coach.bottom", anchor: .bottom) }
            .onChange(of: coach.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("coach.bottom", anchor: .bottom) }
            }
            .onChange(of: coach.messages.last?.cards?.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("coach.bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("coach.bottom", anchor: .bottom) }
        }.accessibilityIdentifier("coach.conversation")
    }

    // MARK: Composer

    private var composerView: some View {
        VStack(spacing: 7) {
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
                Button("Load next Siri question") { consumeSiriDraft() }
                    .buttonStyle(ChipButtonStyle())
                    .disabled(!composer.isEmpty || coach.isResponding)
            }
            HStack(alignment: .bottom, spacing: 10) {
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
                    Image(systemName: "plus").font(.system(size: 18)).frame(width: 32, height: 40)
                }.accessibilityLabel("Coach actions")
                TextField("Ask your coach…", text: $composer, axis: .vertical)
                    .font(StrandFont.body).lineLimit(1...5)
                    .padding(.vertical, 10).focused($composerFocused)
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
                        .font(.system(size: 17)).frame(width: 30, height: 40)
                }.disabled(!coach.preferences.enabled || coach.isResponding)
                    .accessibilityLabel(voice.isRecording ? "Stop dictation" : "Dictate a question")
                    .accessibilityIdentifier("coach.microphone")
                Button {
                    if coach.isResponding { coach.cancel() } else { submit(composer) }
                } label: {
                    Image(systemName: coach.isResponding ? "stop.fill" : "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.onInk)
                        .frame(width: 38, height: 38).background(StrandPalette.ink, in: Circle())
                }
                .disabled(!coach.isResponding && composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(coach.isResponding || !composer.isEmpty ? 1 : 0.45)
                .accessibilityLabel(coach.isResponding ? "Stop response" : "Send message")
                .accessibilityIdentifier("coach.send")
            }
            .padding(.horizontal, NoopMetrics.space3).padding(.vertical, NoopMetrics.space2)
            .background(StrandPalette.inset, in: .rect(cornerRadius: NoopMetrics.radius5))
            .overlay { RoundedRectangle(cornerRadius: NoopMetrics.radius5).strokeBorder(StrandPalette.cardBorder, lineWidth: 1) }
            Text("On this iPhone · private by design")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, NoopMetrics.space4).padding(.top, 10).padding(.bottom, NoopMetrics.space2)
        .background(StrandPalette.appCanvas)
        .overlay(alignment: .top) {
            Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(spacing: 7) {
                Image(systemName: message.role == .user ? "person.crop.circle" : "sparkle")
                    .foregroundStyle(message.role == .user ? StrandPalette.textTertiary : StrandPalette.accent)
                Text(message.role == .user ? "You" : "NOOP Coach").strandOverline()
                Spacer()
                if streaming { ProgressView().controlSize(.mini) }
            }
            if message.text.isEmpty && streaming {
                Text("Looking into it…").foregroundStyle(StrandPalette.textTertiary).font(StrandFont.body)
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
                Text(message.toolNames.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }.joined(separator: " · "))
                    .font(StrandFont.micro).foregroundStyle(StrandPalette.accent)
            }
            if !message.evidence.isEmpty {
                Button { showEvidence = true } label: {
                    Label("\(message.evidence.count) source records", systemImage: "doc.text.magnifyingglass")
                }.buttonStyle(ChipButtonStyle())
            }
            if message.isInterrupted {
                Label("Response stopped", systemImage: "pause.circle").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            if message.role == .assistant && !streaming && !message.text.isEmpty {
                HStack(spacing: NoopMetrics.space4) {
                    Button(action: onSpeak) { Label("Read aloud", systemImage: "speaker.wave.2").font(StrandFont.micro) }
                        .foregroundStyle(StrandPalette.textTertiary)
                    ShareLink(item: message.text) {
                        Label("Share", systemImage: "square.and.arrow.up").font(StrandFont.micro)
                    }.foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .padding(message.role == .user ? NoopMetrics.space4 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? StrandPalette.card : .clear, in: .rect(cornerRadius: NoopMetrics.radius3))
        .sheet(isPresented: $showEvidence) {
            LocalCoachSourcesView(evidence: message.evidence, title: "Sources for this answer")
                .noopSheetPresentation(largeFirst: true)
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
    }
}
#endif
#endif
