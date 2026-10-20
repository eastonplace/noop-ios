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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(screen: LocalCoachScreen = .chat) {
        _screen = State(initialValue: screen)
    }

    var body: some View {
        VStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            statusNote
            if screen == .chat || screen == .home { composerView }
        }
        .safeAreaInset(edge: .top, spacing: 0) { pageHeader }
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
                // As the plan page presents the same hub: its own header and close button on the app canvas.
                WorkoutsView()
                    .sheetScreenScaffoldEnvironment(onClose: { showWorkouts = false })
                    .background(StrandPalette.appCanvas.ignoresSafeArea())
            }
            .tint(StrandPalette.accent)
            .noopSheetPresentation(largeFirst: true)
        }
        // A workout request (Quick Actions, the Live Activity, a deep link, Start in this hub) closes the sheet so the
        // workout journey's cover can open at the root.
        .collapsesForWorkoutJourney($showWorkouts)
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
                voice.speak(CoachAnswerExport.spokenText(for: reply))
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach.studio")
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case .chat:
            CoachConversationView(
                messages: coach.messages, activeMessageID: coach.currentResponseMessageID,
                progress: coach.responseProgress.stage, isPreview: coach.isPreview,
                snapshot: coach.snapshot, hasConsent: coach.preferences.usePersonalData,
                availability: availability, showsFollowUps: !composerFocused, onAsk: submit,
                onEdit: { composer = $0; composerFocused = true },
                onRetry: { Task { await coach.retryLatestAnswer() } },
                onSpeak: { message in
                    guard coach.preferences.enabled, !coach.isPreview else { return }
                    voice.isSpeaking ? voice.stopSpeaking() : voice.speak(CoachAnswerExport.spokenText(for: message))
                },
                onStop: coach.cancel, onSettings: { showSettings = true },
                onWorkouts: { showWorkouts = true }, onPlan: { showPlanBuilder = true })
        case .home: overviewPage
        case .plan: LocalCoachPlanView(onBuild: { showPlanBuilder = true })
        case .memory: LocalCoachMemoryView()
        }
    }

    // MARK: Daily overview (header menu)

    /// The page #55 opened on, kept behind the header menu now that chat is the front door: the daily outlook, the
    /// latest metrics, consent, the morning, evening and weekly briefs, the plan and the records behind the coach.
    private var overviewPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                FlatSection("Your daily outlook", systemImage: "sun.horizon", tint: .accent,
                            trailing: CoachRecordDate.trailing(day: coach.snapshot.latestDay)) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text(coach.preferences.usePersonalData ? "Your day, in focus." : "Start with your goals.")
                            .font(StrandFont.title1).fixedSize(horizontal: false, vertical: true)
                        Text(coach.dailyBrief.hasPrefix("Allow local") ? coach.snapshot.summary : coach.dailyBrief)
                            .font(StrandFont.subhead).lineSpacing(3)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(5)
                    }
                    // The ready state is not announced; a pill appears only when something stands in the way.
                    if coach.isPreview || availability != .available {
                        StatePill(LocalizedStringKey(coach.isPreview ? "Sample records, no model inference" : availability.title),
                                  tone: availabilityTone, pulsing: availability == .checking)
                    }
                }
                if !coach.snapshot.metrics.isEmpty {
                    FlatSectionSeparator.coach
                    CoachMetricStrip(metrics: Array(coach.snapshot.metrics.prefix(3)))
                }
                if !coach.preferences.usePersonalData {
                    FlatSectionSeparator.coach
                    FlatSection("Make it personal", systemImage: "lock.shield", tint: .accent) {
                        Text("Allow Coach to read your selected NOOP records on this iPhone. Your local coach does not send them to a cloud model.")
                            .font(StrandFont.subhead).lineSpacing(3)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Button("Use my local records") { coach.preferences.usePersonalData = true }
                            .buttonStyle(PrimaryPillButtonStyle())
                            .accessibilityIdentifier("coach.allowRecords")
                    }
                }
                FlatSectionSeparator.coach
                FlatSection("Your rhythm", systemImage: "calendar.badge.clock", tint: .accent) {
                    Text("A moment to check in")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    CoachChipRow(bleed: NoopMetrics.space4) {
                        briefChip("Morning", symbol: "sun.max", kind: .morning)
                        briefChip("Evening", symbol: "moon", kind: .evening)
                        briefChip("This week", symbol: "calendar", kind: .weekly)
                        briefChip("Latest activity", symbol: "figure.run", kind: .activity)
                    }
                }
                FlatSectionSeparator.coach
                Button { screen = .plan; if coach.plan == nil { showPlanBuilder = true } } label: {
                    CoachRow(systemImage: "figure.strengthtraining.traditional", tint: .workout,
                             title: Text(LocalizedStringKey(coach.plan?.title ?? "Turn intention into a plan")),
                             subtitle: Text(CoachPlanText.entrySubtitle(sessions: coach.plan?.days.count,
                                                                        saved: coach.plan?.saved ?? false)))
                }
                .buttonStyle(.plain)
                FlatSectionSeparator.coach
                Button { showSources = true } label: {
                    CoachRow(systemImage: "checkmark.shield", tint: .accent, title: Text("See the records behind your coach"))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.top, CoachRhythm.pageTop)
            .padding(.bottom, CoachRhythm.pageBottom)
        }
        .refreshable { await coach.refresh() }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("coach.overview")
    }

    private var availabilityTone: StrandTone {
        switch availability {
        case .available: .accent
        case .checking: .neutral
        default: .warning
        }
    }

    private func briefChip(_ title: LocalizedStringKey, symbol: String, kind: LocalCoachBriefKind) -> some View {
        Button {
            screen = .chat
            Task { await coach.generateBrief(kind: kind) }
        } label: {
            WidgetChip(appTitle: title, systemImage: symbol, showsChevron: false, overhangs: false)
                .chipHitTarget()
        }
        .buttonStyle(.plain)
        .disabled(coach.isResponding || availability != .available)
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

    /// Your plan is a drill-in with its own header (back, title, state); every other page wears the Coach header.
    @ViewBuilder private var pageHeader: some View {
        if screen == .plan {
            LocalCoachPlanHeader { show(.chat) }
        } else {
            header
        }
    }

    /// The shared page header owns the Coach title. History, new chat and the menu
    /// remain in their own quiet action row, with a back control on Coach drill-ins.
    private var header: some View {
        VStack(spacing: 0) {
            if showsAppChrome { AppHeaderChrome(title: "Coach") }
            Group {
                if showsAppChrome {
                    HStack(spacing: 0) {
                        if screen != .chat { backToChat }
                        Spacer(minLength: 0)
                        headerActions
                    }
                } else {
                    NoopScreenHeader(title: "Coach",
                                     backAction: screen != .chat ? { show(.chat) } : (navigationRole == .detail ? { dismiss() } : nil),
                                     style: .compact) { headerActions }
                }
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.bottom, NoopMetrics.space1)
        }
        .background(StrandPalette.appCanvas)
    }

    private var backToChat: some View {
        Button { show(.chat) } label: {
            headerIcon("chevron.left")
        }
        .buttonStyle(.plain)
        .padding(.leading, -13)
        .accessibilityLabel(Text("Back to chat"))
        .accessibilityIdentifier("coach.tab.chat")
    }

    /// History, a new thread and the menu as plain icons: no chip behind them, a 44pt tap area each.
    private var headerActions: some View {
        HStack(spacing: 0) {
            Button { showLibrary = true } label: { headerIcon("clock.arrow.circlepath") }
                .accessibilityLabel("Conversation history").accessibilityIdentifier("coach.history")
            Button(action: newConversation) { headerIcon("square.and.pencil") }
                .accessibilityLabel("New conversation").accessibilityIdentifier("coach.newConversation")
            Menu {
                Button("Daily overview", systemImage: "sun.horizon") { show(.home) }
                Button("Your plan", systemImage: "figure.strengthtraining.traditional") { show(.plan) }
                Button("About you", systemImage: "person.crop.circle") { show(.memory) }
                Divider()
                Button("Your context", systemImage: "doc.text.magnifyingglass") { showSources = true }
                Button("Coach settings", systemImage: "slider.horizontal.3") { showSettings = true }
            } label: { headerIcon("ellipsis") }
            .accessibilityLabel("More Coach options").accessibilityIdentifier("coach.more")
        }
        .buttonStyle(.plain)
        // The last icon's tap area reaches past its glyph; pull it back so the glyph sits on the content edge.
        .padding(.trailing, -13)
    }

    /// Page changes cross-fade (no slide: the header and composer stay put), and are instant under Reduce Motion.
    private func show(_ next: LocalCoachScreen) {
        composerFocused = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { screen = next }
    }

    private func headerIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    @ViewBuilder private var statusNote: some View {
        if let error = inputError ?? voice.errorText ?? coach.errorText ?? LocalCoachIntentBridge.errorText {
            CoachNotice(error: error)
                .padding(.horizontal, NoopMetrics.space5).padding(.vertical, NoopMetrics.space2)
                .accessibilityIdentifier("coach.error")
        } else if coach.recordsUpdating && (screen == .home || screen == .chat) {
            CoachNotice(text: Text("Your records are updating. General chat is available."), tone: .info)
                .padding(.horizontal, NoopMetrics.space5).padding(.vertical, NoopMetrics.space2)
                .accessibilityIdentifier("coach.recordsUpdating")
        } else if screen == .chat, !coach.messages.isEmpty, availability != .available {
            // The new-chat page explains the state in its greeting; a thread that already has turns says it here.
            CoachNotice(text: Text(LocalizedStringKey(availability.title)),
                        tone: availability == .checking ? .info : .warning)
                .padding(.horizontal, NoopMetrics.space5).padding(.vertical, NoopMetrics.space2)
                .accessibilityIdentifier("coach.availabilityNote")
        }
    }

    /// The floating composer: a pill on the raised surface with a hairline (54pt at rest, one row tall), the actions
    /// menu as a "+" circle on the left, dictation and send on the right. Send is white with a dark arrow once there
    /// is something to send. The field and the three controls share one row height (see `CoachComposerRow`), so the
    /// text and the controls sit on one centre line at every Dynamic Type size.
    private var composerView: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if voice.isRecording || voice.isStarting {
                Label(voice.isStarting ? "Preparing on-device dictation" : "Listening on this iPhone", systemImage: "waveform")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
                    .padding(.horizontal, NoopMetrics.space2)
            }
            if attachmentTask != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading workout text on this iPhone").font(StrandFont.caption)
                }
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.horizontal, NoopMetrics.space2)
            }
            if visible && LocalCoachIntentBridge.hasPendingRequest {
                Button("Load next Siri question", systemImage: "waveform", action: consumeSiriDraft)
                    .font(StrandFont.caption).frame(minHeight: 44)
                    .padding(.horizontal, NoopMetrics.space2)
                    .disabled(!composer.isEmpty || coach.isResponding)
            }
            HStack(alignment: .bottom, spacing: 0) {
                attachmentMenu
                TextField(coach.messages.isEmpty ? "Ask Coach" : "Ask a follow-up", text: $composer, axis: .vertical)
                    .coachFont(17, .regular, relativeTo: .body).lineLimit(1...6)
                    .padding(.vertical, CoachComposerRow.fieldPadding).padding(.horizontal, 4)
                    .frame(minHeight: CoachComposerRow.minHeight)
                    .focused($composerFocused).submitLabel(.send)
                    .onSubmit { if !coach.isResponding { submit(composer) } }
                    .disabled(voice.isRecording || voice.isStarting)
                    .accessibilityIdentifier("coach.composer")
                Button(action: toggleDictation) {
                    CoachComposerSlot {
                        Image(systemName: voice.isRecording ? "waveform" : "mic")
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(voice.isRecording ? StrandPalette.accent : StrandPalette.textSecondary)
                    }
                }
                .disabled(!coach.preferences.enabled || coach.isResponding)
                .accessibilityLabel(voice.isRecording ? "Stop dictation" : "Dictate a question")
                .accessibilityIdentifier("coach.microphone")
                Button {
                    if coach.isResponding { coach.cancel() } else { submit(composer) }
                } label: {
                    CoachComposerSlot {
                        Image(systemName: coach.isResponding ? "stop.fill" : "arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(canSend ? StrandPalette.onInk : StrandPalette.textTertiary)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(canSend ? StrandPalette.textPrimary : StrandPalette.inset))
                            .overlay(Circle().fill(canSend ? Color.clear : StrandPalette.chipFill))
                    }
                }
                .disabled(!canSend)
                .accessibilityLabel(coach.isResponding ? "Stop response" : "Send message")
                .accessibilityIdentifier("coach.send")
            }
            .padding(.horizontal, 5)
            .background(RoundedRectangle(cornerRadius: 27, style: .continuous).fill(StrandPalette.inset))
            .overlay(RoundedRectangle(cornerRadius: 27, style: .continuous)
                .strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1))
            .shadow(color: StrandPalette.appCanvas.opacity(0.9), radius: 15, x: 0, y: -5)
            .animation(.easeOut(duration: 0.16), value: composerFocused)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, NoopMetrics.space2).padding(.bottom, NoopMetrics.space2)
        .background(StrandPalette.appCanvas)
    }

    private var canSend: Bool { coach.isResponding || !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var attachmentMenu: some View {
        Menu {
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
            CoachComposerSlot {
                Image(systemName: "plus").font(.system(size: 19, weight: .regular))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(StrandPalette.inset))
                    .overlay(Circle().fill(StrandPalette.chipFill))
            }
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
        let originalContext = coach.recordContextID
        let originalPreferences = coach.preferences
        Task {
            let accepted = await coach.send(text)
            // A refusal before the question became a user turn must not lose an unsent draft or overwrite a newer one.
            // `send` also returns when New conversation or History stops a reply; that question was sent, so it stays
            // sent, whichever thread is selected now.
            if !accepted, wasDraft, composer.isEmpty, originalContext == coach.recordContextID,
               originalPreferences == coach.preferences {
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

/// The composer's row. The pill is one row tall at rest: one line of the field's own text with 15pt above and below,
/// and never under 54pt. The field and the three controls all use that row height, so at every Dynamic Type size the
/// placeholder, the text and the controls sit on one centre line. When the text wraps, the pill grows and the controls
/// ride the bottom row.
private enum CoachComposerRow {
    static let minHeight: CGFloat = 54
    static let fieldPadding: CGFloat = 15
}

/// A 44pt-wide control slot exactly one composer row tall, with its content centred. The row is measured from a hidden
/// line set in the field's own font, so the slot follows Dynamic Type exactly; the whole slot is the tap target.
private struct CoachComposerSlot<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Text(verbatim: "Ag")
            .coachFont(17, .regular, relativeTo: .body)
            .fixedSize()
            .padding(.vertical, CoachComposerRow.fieldPadding)
            .frame(width: 44)
            .frame(minHeight: CoachComposerRow.minHeight)
            .hidden()
            .overlay { content() }
            .contentShape(Rectangle())
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
/// An answer being written, in its real place in the transcript: the question, then the one shimmering line. Fixture
/// messages only; the engine, the model and the records are not involved.
private struct CoachProgressChatFixture: View {
    private let question = LocalCoachMessage(role: .user, text: "How did I sleep this week?")
    private let reply = LocalCoachMessage(role: .assistant, text: "")

    var body: some View {
        CoachConversationView(
            messages: [question, reply], activeMessageID: reply.id,
            progress: .reading(tool: "sleep_history", days: 7), isPreview: true,
            snapshot: .empty, hasConsent: true, availability: .available,
            onAsk: { _ in }, onEdit: { _ in }, onRetry: {}, onSpeak: { _ in }, onStop: {},
            onSettings: {}, onWorkouts: {}, onPlan: {})
            .background(StrandPalette.appCanvas.ignoresSafeArea())
    }
}

struct LocalCoachPreviewHost: View {
    @StateObject private var coach: LocalCoachEngine
    private let screen: String
    init(screen: String) {
        self.screen = screen
        let engine = LocalCoachEngine.preview(screen: screen)
        // `welcome` is the new-chat page with the sample record values behind its pills: the same fixture with the
        // sample thread cleared.
        if screen == "welcome" || screen == "welcome-access" { engine.newConversation() }
        // `welcome-access` is the same page with record access off: the quiet "Choose what Coach can read" row.
        if screen == "welcome-access" { engine.preferences.usePersonalData = false }
        _coach = StateObject(wrappedValue: engine)
    }
    var body: some View {
        NavigationStack {
            if screen == "devicecheck" { LocalCoachDeviceCheckView().coachSettingsSheetEnvironment() }
            else if screen == "diagnostics" { LocalCoachDiagnosticsView().coachSettingsSheetEnvironment() }
            else if screen == "progress" { CoachProgressGallery() }
            else if screen == "chat-progress" { CoachProgressChatFixture() }
            else { LocalCoachView(screen: LocalCoachScreen(rawValue: screen) ?? .chat) }
        }
        .environmentObject(coach)
        .task { await QAScrollDriver.run() }
    }
}
#endif
#endif
