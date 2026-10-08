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

    init(screen: LocalCoachScreen = .home) { _screen = State(initialValue: screen) }

    var body: some View {
        VStack(spacing: 0) {
            header
            sectionPicker
            Group {
                switch screen {
                case .home: overview
                case .chat: conversation
                case .plan: LocalCoachPlanView(onBuild: { showPlanBuilder = true })
                case .memory: LocalCoachMemoryView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = inputError ?? voice.errorText ?? coach.errorText ?? LocalCoachIntentBridge.errorText {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(StrandPalette.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .accessibilityIdentifier("coach.error")
            } else if coach.recordsUpdating && (screen == .home || screen == .chat) {
                Text("Your records are updating. General chat is available.")
                    .font(.caption).foregroundStyle(StrandPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .accessibilityIdentifier("coach.recordsUpdating")
            }
            if screen == .home || screen == .chat { composerView }
        }
        .background(StrandPalette.appCanvas)
        .foregroundStyle(StrandPalette.textPrimary)
        .tint(StrandPalette.accent)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showLibrary) {
            LocalCoachLibraryView { screen = .chat }
        }
        .sheet(isPresented: $showSettings) { LocalCoachSettingsView() }
        .sheet(isPresented: $showSources) {
            LocalCoachSourcesView(evidence: coach.snapshot.evidence, title: "Your context")
        }
        .sheet(isPresented: $showPlanBuilder) {
            LocalCoachPlanBuilder {
                screen = .plan
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack {
                LocalCoachDiagnosticsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDiagnostics = false } } }
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
        .sheet(isPresented: $showAttachment) { attachmentReview }
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

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("NOOP / PERSONAL INTELLIGENCE")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.8).foregroundStyle(StrandPalette.textTertiary)
                Text("Coach").font(.system(size: 34, weight: .semibold, design: .rounded))
            }
            Spacer(minLength: 0)
            headerButton("Conversation history", symbol: "clock.arrow.circlepath") { showLibrary = true }
            headerButton("Coach settings", symbol: "slider.horizontal.3") { showSettings = true }
        }
        .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 18)
    }

    private func headerButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17))
                .frame(width: 44, height: 44)
                .background(StrandPalette.inset, in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(LocalCoachScreen.allCases) { item in
                    Button {
                        composerFocused = false
                        withAnimation(.easeInOut(duration: 0.2)) { screen = item }
                    } label: {
                        VStack(spacing: 12) {
                            Text(item.title).font(.system(size: 13, weight: screen == item ? .semibold : .medium))
                                .foregroundStyle(screen == item ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                            Capsule().fill(screen == item ? StrandPalette.accent : .clear).frame(height: 2)
                        }
                        .padding(.top, 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(screen == item ? .isSelected : [])
                    .accessibilityIdentifier("coach.tab.\(item.rawValue)")
                }
            }.padding(.horizontal, 22)
        }
        .background(alignment: .bottom) { StrandPalette.hairline.frame(height: 1) }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                if coach.isPreview { LocalCoachFixtureLabel() }
                outlook
                if !coach.snapshot.metrics.isEmpty { metricStrip }
                if !coach.preferences.usePersonalData { consentCard }
                topicSection
                planEntry
                briefSection
                Button { showSources = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield")
                        Text("See the records behind your coach")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }.font(.footnote).foregroundStyle(StrandPalette.textSecondary)
                }.buttonStyle(.plain).padding(.bottom, 8)
            }
            .padding(.horizontal, 22).padding(.vertical, 22)
        }
        .refreshable { await coach.refresh() }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("coach.overview")
    }

    private var outlook: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("YOUR DAILY OUTLOOK", systemImage: "sun.horizon")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1)
                Spacer()
                Image(systemName: "sparkle").font(.title3)
            }.foregroundStyle(StrandPalette.accent)
            Text(coach.preferences.usePersonalData ? "Your day, in focus." : "Start with your goals.")
                .font(.system(size: 29, weight: .medium, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            Text(coach.dailyBrief.hasPrefix("Allow local") ? coach.snapshot.summary : coach.dailyBrief)
                .font(.system(size: 14)).lineSpacing(4)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(5)
            HStack(spacing: 6) {
                Circle().fill(coach.availability == .available ? StrandPalette.accent : StrandPalette.textTertiary)
                    .frame(width: 5, height: 5)
                Text(coach.isPreview ? "Sample records, no model inference" : coach.availability.title)
                    .font(.system(size: 10, weight: .medium))
                Spacer(minLength: 6)
                if let day = coach.snapshot.latestDay {
                    Text(day).font(.system(size: 10, design: .monospaced))
                }
            }.foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(LinearGradient(colors: [StrandPalette.accentMuted, StrandPalette.card], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(StrandPalette.accent.opacity(0.14), lineWidth: 1) }
        }
    }

    private var metricStrip: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(coach.snapshot.metrics.prefix(3))) { metric in
                VStack(alignment: .leading, spacing: 7) {
                    Text(metric.title.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.6).foregroundStyle(StrandPalette.textTertiary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(metric.value).font(.system(size: 27, weight: .medium, design: .rounded)).minimumScaleFactor(0.7)
                        Text(metric.unit).font(.caption2).foregroundStyle(StrandPalette.textTertiary)
                    }.lineLimit(1)
                    LocalCoachSparkline(samples: metric.samples)
                        .stroke(metricTint(metric.id), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(height: 25)
                        .accessibilityHidden(true)
                    Text(metric.detail).font(.system(size: 10)).foregroundStyle(StrandPalette.textTertiary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func metricTint(_ id: String) -> Color {
        if id.localizedCaseInsensitiveContains("sleep") { return StrandPalette.sleepAccent }
        if id.localizedCaseInsensitiveContains("strain") { return StrandPalette.strainAccent }
        return StrandPalette.accent
    }

    private var consentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Make it personal", systemImage: "lock.shield").font(.headline)
            Text("Allow Coach to read your selected NOOP records on this iPhone. Your local coach does not send them to a cloud model.")
                .font(.footnote).foregroundStyle(StrandPalette.textSecondary)
            Button("Use my local records") {
                coach.preferences.usePersonalData = true
            }.buttonStyle(LocalCoachPrimaryButtonStyle())
                .accessibilityIdentifier("coach.allowRecords")
        }.modifier(LocalCoachPanel())
    }

    private var topicSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            LocalCoachSectionHeading(title: "What’s on your mind?", eyebrow: "EXPLORE WITH COACH")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LocalCoachTopic.allCases) { topic in
                        Button { selectedTopic = topic } label: {
                            Label(topic.title, systemImage: topic.symbol)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 13).padding(.vertical, 10)
                                .foregroundStyle(selectedTopic == topic ? StrandPalette.onInk : StrandPalette.textSecondary)
                                .background(selectedTopic == topic ? StrandPalette.accent : StrandPalette.inset, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
            Button { submit(selectedTopic.prompt) } label: {
                HStack(alignment: .top, spacing: 16) {
                    Text(selectedTopic.prompt).font(.system(size: 14)).lineSpacing(3)
                        .foregroundStyle(StrandPalette.textSecondary).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").foregroundStyle(StrandPalette.accent)
                }.padding(16).background(StrandPalette.card, in: .rect(cornerRadius: 16))
            }.buttonStyle(.plain)
        }
    }

    private var planEntry: some View {
        Button { screen = .plan; if coach.plan == nil { showPlanBuilder = true } } label: {
            HStack(spacing: 15) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 24, weight: .light)).foregroundStyle(StrandPalette.accent)
                    .frame(width: 48, height: 58).background(StrandPalette.accentMuted, in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text(coach.plan?.title ?? "Turn intention into a plan").font(.system(size: 15, weight: .semibold))
                    Text(coach.plan == nil ? "Build, review and save your next workout." : "\(coach.plan?.days.count ?? 0) sessions · Ready for your review")
                        .font(.system(size: 12)).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(StrandPalette.textTertiary)
            }.modifier(LocalCoachPanel())
        }.buttonStyle(.plain)
    }

    private var briefSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LocalCoachSectionHeading(title: "A moment to check in", eyebrow: "YOUR RHYTHM")
            HStack(spacing: 10) {
                briefButton("Morning", symbol: "sun.max", kind: .morning)
                briefButton("Evening", symbol: "moon", kind: .evening)
                briefButton("This week", symbol: "calendar", kind: .weekly)
            }
        }
    }

    private func briefButton(_ title: String, symbol: String, kind: LocalCoachBriefKind) -> some View {
        Button {
            screen = .chat
            Task { await coach.generateBrief(kind: kind) }
        } label: {
            VStack(alignment: .leading, spacing: 15) {
                Image(systemName: symbol).font(.system(size: 20, weight: .light)).foregroundStyle(StrandPalette.accent)
                Text(title).font(.system(size: 12, weight: .medium))
            }.frame(maxWidth: .infinity, alignment: .leading).padding(15)
                .background(StrandPalette.card, in: .rect(cornerRadius: 16))
        }.buttonStyle(.plain)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if coach.isPreview { LocalCoachFixtureLabel() }
                    if coach.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 18) {
                            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(StrandPalette.accent)
                            Text("Let’s connect the dots.").font(.system(size: 28, weight: .medium, design: .rounded))
                            Text("Ask about your sleep, training, recovery or goals. Coach can look at the local records you allow and show its sources.")
                                .font(.body).foregroundStyle(StrandPalette.textSecondary)
                        }.padding(.vertical, 32)
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
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading " + coach.activeTools.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", "))
                                .font(.caption).foregroundStyle(StrandPalette.textSecondary)
                        }.accessibilityIdentifier("coach.toolActivity")
                    }
                    Color.clear.frame(height: 1).id("coach.bottom")
                }.padding(22)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: coach.messages.last?.text) { _, _ in proxy.scrollTo("coach.bottom", anchor: .bottom) }
            .onChange(of: coach.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("coach.bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("coach.bottom", anchor: .bottom) }
        }.accessibilityIdentifier("coach.conversation")
    }

    private var composerView: some View {
        VStack(spacing: 7) {
            if voice.isRecording || voice.isStarting {
                Label(voice.isStarting ? "Preparing on-device dictation" : "Listening on this iPhone", systemImage: "waveform")
                    .font(.caption).foregroundStyle(StrandPalette.accent)
            }
            if attachmentTask != nil {
                HStack { ProgressView().controlSize(.small); Text("Reading workout text on this iPhone").font(.caption) }
            }
            if visible && LocalCoachIntentBridge.hasPendingRequest {
                Button("Load next Siri question") { consumeSiriDraft() }
                    .font(.caption).disabled(!composer.isEmpty || coach.isResponding)
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
                    .font(.system(size: 15)).lineLimit(1...5)
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
                        .frame(width: 38, height: 38).background(StrandPalette.accent, in: Circle())
                }
                .disabled(!coach.isResponding && composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(coach.isResponding || !composer.isEmpty ? 1 : 0.45)
                .accessibilityLabel(coach.isResponding ? "Stop response" : "Send message")
                .accessibilityIdentifier("coach.send")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(StrandPalette.inset, in: .rect(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(StrandPalette.cardBorder, lineWidth: 1) }
            Text("ON THIS IPHONE · PRIVATE BY DESIGN")
                .font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.1)
                .foregroundStyle(StrandPalette.textTertiary)
        }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 8)
            .background(StrandPalette.appCanvas)
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
            Form {
                Section {
                    Text("Check exercise names and numbers before using this text. Photos are read locally and are not attached to the model request.")
                        .font(.footnote).foregroundStyle(.secondary)
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
        }.preferredColorScheme(.dark)
    }
}

private struct LocalCoachMessageView: View {
    let message: LocalCoachMessage
    let streaming: Bool
    let onSpeak: () -> Void
    @State private var showEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 7) {
                Image(systemName: message.role == .user ? "person.crop.circle" : "sparkle")
                    .foregroundStyle(message.role == .user ? StrandPalette.textTertiary : StrandPalette.accent)
                Text(message.role == .user ? "YOU" : "NOOP COACH")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.2)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                if streaming { ProgressView().controlSize(.mini) }
            }
            if message.text.isEmpty && streaming {
                Text("Looking into it…").foregroundStyle(StrandPalette.textTertiary).font(.body)
            } else {
                Markdown(message.text)
                    .markdownTheme(.strand)
                    .textSelection(.enabled)
            }
            if !message.toolNames.isEmpty {
                Text(message.toolNames.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(StrandPalette.accent)
            }
            if !message.evidence.isEmpty {
                Button { showEvidence = true } label: {
                    Label("\(message.evidence.count) source records", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(StrandPalette.textSecondary)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .background(StrandPalette.inset, in: Capsule())
                }.buttonStyle(.plain)
            }
            if message.isInterrupted {
                Label("Response stopped", systemImage: "pause.circle").font(.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            if message.role == .assistant && !streaming && !message.text.isEmpty {
                Button(action: onSpeak) { Label("Read aloud", systemImage: "speaker.wave.2").font(.caption2) }
                    .foregroundStyle(StrandPalette.textTertiary)
                ShareLink(item: message.text) {
                    Label("Share", systemImage: "square.and.arrow.up").font(.caption2)
                }.foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(message.role == .user ? 16 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? StrandPalette.card : .clear, in: .rect(cornerRadius: 18))
        .sheet(isPresented: $showEvidence) { LocalCoachSourcesView(evidence: message.evidence, title: "Sources for this answer") }
    }
}

struct LocalCoachPanel: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(StrandPalette.card, in: .rect(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(StrandPalette.hairline, lineWidth: 1) }
    }
}

struct LocalCoachSectionHeading: View {
    let title: String
    let eyebrow: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(eyebrow).font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.4).foregroundStyle(StrandPalette.textTertiary)
            Text(title).font(.system(size: 20, weight: .medium, design: .rounded))
        }
    }
}

struct LocalCoachPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold))
            .foregroundStyle(StrandPalette.onInk)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(StrandPalette.accent.opacity(configuration.isPressed ? 0.7 : 1), in: .rect(cornerRadius: 14))
    }
}

struct LocalCoachFixtureLabel: View {
    var body: some View {
        Label("Preview with synthetic data", systemImage: "testtube.2")
            .font(.caption2).foregroundStyle(StrandPalette.warning)
            .accessibilityIdentifier("coach.syntheticPreview")
    }
}

private struct LocalCoachSparkline: Shape {
    let samples: [Double]
    func path(in rect: CGRect) -> Path {
        let values = samples.filter(\.isFinite)
        guard values.count > 1, let low = values.min(), let high = values.max() else { return Path() }
        let range = max(high - low, 1)
        return Path { path in
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: rect.minX + rect.width * Double(index) / Double(values.count - 1),
                                    y: rect.maxY - rect.height * (value - low) / range)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
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
            if deviceCheck { LocalCoachDeviceCheckView() }
            else if diagnostics { LocalCoachDiagnosticsView() }
            else { LocalCoachView(screen: screen) }
        }
            .environmentObject(coach).preferredColorScheme(.dark)
    }
}
#endif
#endif
