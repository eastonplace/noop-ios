#if os(iOS)
import SwiftUI
import StrandDesign
import PhotosUI

enum LocalCoachScreen: String, CaseIterable, Identifiable {
    case home, chat, plan, memory
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Daily overview"
        case .chat: "Conversation"
        case .plan: "Your plan"
        case .memory: "About you"
        }
    }
}

/// Chat is the front door. Plans, personal context and native utility sheets remain available in the header menu.
struct LocalCoachView: View {
    @EnvironmentObject private var coach: LocalCoachEngine
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.screenScaffoldNavigationRole) private var navigationRole
    @Environment(\.screenScaffoldPresentation) private var scaffoldPresentation
    @Environment(\.appHeaderChromeVisibility) private var chromeVisibility
    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice = LocalCoachVoice()
    @State private var screen: LocalCoachScreen
    @State private var composer = ""
    @State private var voicePrefix = ""
    @State private var dictating = false
    @State private var visible = false
    @State private var voiceTask: Task<Void, Never>?
    @State private var showLibrary = false
    @State private var showSettings = false
    @State private var showSources = false
    @State private var showPlanBuilder = false
    @State private var showDiagnostics = false
    @State private var showWorkouts = false
    @State private var showPhotos = false
    @State private var photo: PhotosPickerItem?
    @State private var showAttachment = false
    @State private var attachmentText = ""
    @State private var attachmentTask: Task<Void, Never>?
    @State private var attachmentID: UUID?
    @State private var inputError: String?
    @FocusState private var composerFocused: Bool

    init(screen: LocalCoachScreen = .chat) {
        // The old shell and capture routes use .home as the default. They now enter the conversation.
        _screen = State(initialValue: screen == .home ? .chat : screen)
    }

    var body: some View {
        VStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            statusNote
            if screen == .chat || screen == .home { composerView }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .background(StrandPalette.appCanvas.ignoresSafeArea())
        .foregroundStyle(StrandPalette.textPrimary)
        .tint(StrandPalette.accent)
        .segmentedPillSelectionStyle(.quiet)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showLibrary) {
            LocalCoachLibraryView { screen = .chat }.noopSheetPresentation(largeFirst: true)
        }
        .sheet(isPresented: $showSettings) {
            LocalCoachSettingsView().noopSheetPresentation(largeFirst: true)
        }
        .sheet(isPresented: $showSources) {
            LocalCoachSourcesView(evidence: coach.snapshot.evidence, title: "Your context")
                .noopSheetPresentation(largeFirst: true)
        }
        .sheet(isPresented: $showPlanBuilder) {
            LocalCoachPlanBuilder { screen = .plan }.noopSheetPresentation(largeFirst: true)
        }
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack {
                LocalCoachDiagnosticsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDiagnostics = false } } }
            }
            .coachSettingsSheetEnvironment()
            .noopSheetPresentation(largeFirst: true)
        }
        .sheet(isPresented: $showWorkouts) {
            NavigationStack {
                WorkoutsView().sheetScreenScaffoldEnvironment(onClose: { showWorkouts = false })
            }
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
        .onChange(of: voice.transcript) { _, text in if dictating { composer = voicePrefix + text } }
        .onChange(of: coach.isResponding) { old, current in
            guard old && !current && visible else { return }
            if coach.preferences.enabled && coach.preferences.speakReplies && !coach.isPreview,
               coach.responseSeconds != nil, let reply = coach.messages.last,
               reply.role == .assistant, !reply.isInterrupted {
                voice.speak(CoachAnswerExport.text(for: reply))
            }
            consumeSiriDraft()
        }
        .onChange(of: coach.preferences.usePersonalData) { _, _ in Task { await coach.refresh() } }
        .onChange(of: coach.selectedConversationID) { old, new in
            #if DEBUG
            if QACoachPage.requested != nil { return }
            #endif
            if old != new, !coach.messages.isEmpty { screen = .chat }
        }
        .accessibilityIdentifier("coach.studio")
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case .chat:
            CoachConversationView(
                messages: coach.messages, activeMessageID: coach.currentResponseMessageID,
                progress: coach.responseProgress.stage, isPreview: coach.isPreview,
                snapshot: coach.snapshot, hasConsent: coach.preferences.usePersonalData,
                availability: availability, onAsk: submit,
                onEdit: { composer = $0; composerFocused = true },
                onRetry: { Task { await coach.retryLatestAnswer() } },
                onSpeak: { message in
                    guard coach.preferences.enabled, !coach.isPreview else { return }
                    voice.isSpeaking ? voice.stopSpeaking() : voice.speak(CoachAnswerExport.text(for: message))
                },
                onStop: coach.cancel, onSettings: { showSettings = true },
                onWorkouts: { showWorkouts = true }, onPlan: { showPlanBuilder = true })
        case .home:
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space6) {
                    if coach.isPreview { LocalCoachFixtureLabel() }
                    FlatSection("Latest context", systemImage: "sun.horizon", tint: .accent,
                                trailing: CoachRecordDate.trailing(day: coach.snapshot.latestDay)) {
                        Text(coach.snapshot.summary).font(StrandFont.subhead).lineSpacing(3)
                            .foregroundStyle(StrandPalette.textSecondary)
                        if !coach.snapshot.metrics.isEmpty { CoachMetricStrip(metrics: Array(coach.snapshot.metrics.prefix(3))) }
                    }
                    Button { submit(LocalCoachTopic.today.prompt) } label: {
                        CoachRow(systemImage: "bubble.left.and.text.bubble.right", title: Text("Ask about today"),
                                 subtitle: Text("Read the available records before making a plan."))
                    }.buttonStyle(PaperPressStyle())
                    Button { showSources = true } label: {
                        CoachRow(systemImage: "doc.text.magnifyingglass", title: Text("Your source records"))
                    }.buttonStyle(PaperPressStyle())
                }
                .padding(NoopMetrics.space4)
            }
        case .plan: LocalCoachPlanView(onBuild: { showPlanBuilder = true })
        case .memory: LocalCoachMemoryView()
        }
    }

    private var availability: LocalCoachAvailability {
        #if DEBUG
        QACoachAvailability.requested ?? coach.availability
        #else
        coach.availability
        #endif
    }

    private var showsAppChrome: Bool {
        scaffoldPresentation == .standard && chromeVisibility == .visible && navigationRole == .root
    }

    private var header: some View {
        VStack(spacing: 0) {
            if showsAppChrome { AppHeaderChrome() }
            VStack(alignment: .leading, spacing: 0) {
                if showsAppChrome {
                    NoopTabTitleRow("Coach") { headerActions }
                } else {
                    NoopScreenHeader(title: "Coach", backAction: navigationRole == .detail ? { dismiss() } : nil,
                                     style: .compact) { headerActions }
                }
                HStack(spacing: 6) {
                    Circle().fill(availability == .available ? StrandPalette.accent : StrandPalette.textTertiary)
                        .frame(width: 5, height: 5).accessibilityHidden(true)
                    Text(coach.isPreview ? "Synthetic preview" : availability.title)
                        .font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 4)
                    if screen != .chat {
                        Button("Back to chat", systemImage: "arrow.uturn.backward") { screen = .chat; composerFocused = false }
                            .font(StrandFont.caption).frame(minHeight: 44)
                            .accessibilityIdentifier("coach.tab.chat")
                    }
                }
                .padding(.bottom, NoopMetrics.space3)
            }
            .padding(.horizontal, NoopMetrics.space4)
            Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
        }
        .background(StrandPalette.appCanvas)
    }

    private var headerActions: some View {
        HStack(spacing: 0) {
            Button { showLibrary = true } label: { headerIcon("clock.arrow.circlepath") }
                .accessibilityLabel("Conversation history").accessibilityIdentifier("coach.history")
            Button(action: newConversation) { headerIcon("square.and.pencil") }
                .accessibilityLabel("New conversation").accessibilityIdentifier("coach.newConversation")
            Menu {
                Button("Daily overview", systemImage: "sun.horizon") { screen = .home; composerFocused = false }
                Button("Your plan", systemImage: "figure.strengthtraining.traditional") { screen = .plan; composerFocused = false }
                Button("About you", systemImage: "person.crop.circle") { screen = .memory; composerFocused = false }
                Divider()
                Button("Your context", systemImage: "doc.text.magnifyingglass") { showSources = true }
                Button("Coach settings", systemImage: "slider.horizontal.3") { showSettings = true }
            } label: { headerIcon("ellipsis") }
            .accessibilityLabel("More Coach options").accessibilityIdentifier("coach.more")
        }
        .buttonStyle(.plain)
    }

    private func headerIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .medium))
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(width: 44, height: 44).contentShape(Rectangle())
    }

    @ViewBuilder private var statusNote: some View {
        if let error = inputError ?? voice.errorText ?? coach.errorText ?? LocalCoachIntentBridge.errorText {
            CoachNotice(error: error)
                .padding(.horizontal, NoopMetrics.space4).padding(.vertical, NoopMetrics.space2)
                .accessibilityIdentifier("coach.error")
        } else if coach.recordsUpdating && (screen == .home || screen == .chat) {
            CoachNotice(text: Text("Your records are updating. General chat is available."), tone: .info)
                .padding(.horizontal, NoopMetrics.space4).padding(.vertical, NoopMetrics.space2)
                .accessibilityIdentifier("coach.recordsUpdating")
        }
    }

    private var composerView: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if voice.isRecording || voice.isStarting {
                Label(voice.isStarting ? "Preparing on-device dictation" : "Listening on this iPhone", systemImage: "waveform")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
            }
            if attachmentTask != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading workout text on this iPhone").font(StrandFont.caption)
                }.foregroundStyle(StrandPalette.textSecondary)
            }
            if visible && LocalCoachIntentBridge.hasPendingRequest {
                Button("Load next Siri question", systemImage: "waveform", action: consumeSiriDraft)
                    .font(StrandFont.caption).frame(minHeight: 44)
                    .disabled(!composer.isEmpty || coach.isResponding)
            }
            HStack(alignment: .bottom, spacing: 0) {
                attachmentMenu
                TextField("Ask about your training…", text: $composer, axis: .vertical)
                    .font(StrandFont.body).lineLimit(1...6)
                    .padding(.vertical, 13).padding(.leading, 2)
                    .focused($composerFocused).submitLabel(.send)
                    .onSubmit { if !coach.isResponding { submit(composer) } }
                    .disabled(voice.isRecording || voice.isStarting)
                    .accessibilityIdentifier("coach.composer")
                Button(action: toggleDictation) {
                    Image(systemName: voice.isRecording ? "waveform" : "mic")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(voice.isRecording ? StrandPalette.accent : StrandPalette.textSecondary)
                        .frame(width: 44, height: 48).contentShape(Rectangle())
                }
                .disabled(!coach.preferences.enabled || coach.isResponding)
                .accessibilityLabel(voice.isRecording ? "Stop dictation" : "Dictate a question")
                .accessibilityIdentifier("coach.microphone")
                Button {
                    if coach.isResponding { coach.cancel() } else { submit(composer) }
                } label: {
                    Image(systemName: coach.isResponding ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canSend ? StrandPalette.onInk : StrandPalette.textTertiary)
                        .frame(width: 34, height: 34)
                        .background(canSend ? StrandPalette.ink : StrandPalette.inset, in: Circle())
                        .frame(width: 46, height: 48).contentShape(Rectangle())
                }
                .disabled(!canSend)
                .accessibilityLabel(coach.isResponding ? "Stop response" : "Send message")
                .accessibilityIdentifier("coach.send")
            }
            .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: NoopMetrics.radius5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: NoopMetrics.radius5, style: .continuous)
                .strokeBorder(composerFocused ? StrandPalette.hairlineStrong : StrandPalette.hairline, lineWidth: 1))
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 9)).accessibilityHidden(true)
                Text("On this iPhone · You control what Coach can read")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.top, NoopMetrics.space3).padding(.bottom, NoopMetrics.space2)
        .background(StrandPalette.appCanvas)
    }

    private var canSend: Bool { coach.isResponding || !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var attachmentMenu: some View {
        Menu {
            Button("New conversation", systemImage: "square.and.pencil", action: newConversation)
            Button("Build a workout", systemImage: "figure.strengthtraining.traditional") { showPlanBuilder = true }
            Button("Review my latest activity", systemImage: "figure.run") {
                screen = .chat; Task { await coach.generateBrief(kind: .activity) }
            }
            Divider()
            Button("Read workout photo", systemImage: "photo") { showPhotos = true }
            Button("Paste workout text", systemImage: "doc.text") { attachmentText = ""; showAttachment = true }
            Button("Your context", systemImage: "doc.text.magnifyingglass") { showSources = true }
            Button("Testing & bug reports", systemImage: "ladybug") { showDiagnostics = true }
            if voice.isSpeaking { Button("Stop reading aloud", systemImage: "speaker.slash") { voice.stopSpeaking() } }
        } label: {
            Image(systemName: "plus").font(.system(size: 19, weight: .regular))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 44, height: 48).contentShape(Rectangle())
        }
        .accessibilityLabel("Coach actions")
    }

    private func newConversation() {
        stopInputs()
        coach.newConversation()
        inputError = nil
        screen = .chat
        // Keep a question being composed; the previous thread remains in History.
    }

    private func toggleDictation() {
        if voice.isRecording || voice.isStarting {
            dictating = false; voiceTask?.cancel(); voice.stop()
        } else {
            inputError = nil
            voicePrefix = composer.isEmpty ? "" : composer + " "
            dictating = true
            voiceTask = Task { await voice.start() }
        }
    }

    private func submit(_ value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !coach.isResponding else { return }
        guard !coach.isPreview else { inputError = "This preview uses sample data. Model calls are disabled."; return }
        guard coach.preferences.enabled, coach.availability == .available else { inputError = coach.availability.title; return }
        guard text.utf8.count <= 8_000 else { inputError = "This question is too long. Split it into smaller questions before sending."; return }
        inputError = nil
        dictating = false; voiceTask?.cancel(); voice.cancel()
        let wasDraft = text == composer.trimmingCharacters(in: .whitespacesAndNewlines)
        if wasDraft { composer = "" }
        composerFocused = false
        screen = .chat
        let originalIDs = Set(coach.messages.map(\.id))
        let originalContext = coach.recordContextID
        let originalPreferences = coach.preferences
        Task {
            await coach.send(text)
            // A rejection before appending a user turn must not lose an unsent draft or overwrite a newer one.
            if wasDraft, composer.isEmpty, originalContext == coach.recordContextID,
               originalPreferences == coach.preferences,
               !coach.messages.contains(where: { !originalIDs.contains($0.id) && $0.role == .user && $0.text == text }) {
                composer = text
            }
        }
    }

    private func consumeSiriDraft() {
        guard visible, !coach.isPreview, !coach.isResponding, composer.isEmpty,
              !voice.isRecording, LocalCoachIntentBridge.hasPendingRequest,
              let question = LocalCoachIntentBridge.consume() else { return }
        screen = .chat; composer = question
    }

    private func stopInputs() {
        dictating = false; voiceTask?.cancel(); voiceTask = nil; voice.cancel()
        attachmentID = nil; attachmentTask?.cancel(); attachmentTask = nil; photo = nil
    }

    private func readPhoto(_ item: PhotosPickerItem) {
        attachmentTask?.cancel()
        let token = UUID()
        attachmentID = token; inputError = nil
        attachmentTask = Task {
            do {
                guard let bytes = try await item.loadTransferable(type: Data.self) else { throw LocalCoachAttachmentError.invalidImage }
                let text = try await LocalCoachAttachment.extractWorkoutText(from: bytes)
                guard attachmentID == token, !Task.isCancelled, visible else { return }
                attachmentText = text; showAttachment = true
            } catch {
                guard attachmentID == token, !(error is CancellationError) else { return }
                inputError = (error as? LocalCoachAttachmentError)?.localizedDescription
                    ?? "This photo could not be read. Try a smaller workout screenshot."
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
                        screen = .chat; showAttachment = false
                    }
                    .disabled(attachmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || attachmentText.utf8.count > LocalCoachAttachment.maximumTextBytes)
                } footer: { Text("Send the question when you are ready. Saving a workout requires a separate plan review.") }
            }
            .navigationTitle("Workout text").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showAttachment = false } } }
        }
        .coachSettingsSheetEnvironment()
    }
}

extension View {
    func coachSettingsSheetEnvironment() -> some View {
        environment(\.screenScaffoldPresentation, .settingsDetail)
            .environment(\.appHeaderChromeVisibility, .hidden)
            .tint(StrandPalette.accent)
    }
}

struct LocalCoachFixtureLabel: View {
    var body: some View {
        StatePill("Preview with synthetic data", tone: .warning).accessibilityIdentifier("coach.syntheticPreview")
    }
}

#if DEBUG
struct LocalCoachPreviewHost: View {
    @StateObject private var coach: LocalCoachEngine
    private let screen: String
    init(screen: String) {
        self.screen = screen
        _coach = StateObject(wrappedValue: LocalCoachEngine.preview(screen: screen))
    }
    var body: some View {
        NavigationStack {
            if screen == "devicecheck" { LocalCoachDeviceCheckView().coachSettingsSheetEnvironment() }
            else if screen == "diagnostics" { LocalCoachDiagnosticsView().coachSettingsSheetEnvironment() }
            else if screen == "progress" { CoachProgressGallery() }
            else { LocalCoachView(screen: LocalCoachScreen(rawValue: screen) ?? .chat) }
        }
        .environmentObject(coach)
        .task { await QAScrollDriver.run() }
    }
}
#endif
#endif
