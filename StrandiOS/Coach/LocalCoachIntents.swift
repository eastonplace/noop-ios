#if os(iOS)
import Foundation
import AppIntents

enum LocalCoachIntentError: LocalizedError {
    case emptyQuestion, questionTooLong, invalidQuestion, queueFull, unavailable, storageUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyQuestion: "Enter a question for Coach."
        case .questionTooLong: "This question is too long. Shorten it or enter it directly in Coach."
        case .invalidQuestion: "This question contains unsupported control characters. Enter plain text."
        case .queueFull: "Coach has five pending requests. Open Coach to review them before adding another."
        case .unavailable: "Open NOOP and enable Coach with an available data source before trying again."
        case .storageUnavailable: "NOOP could not save or read the pending request. Open Coach and enter your question there."
        }
    }
}

/// App-private inbox, used only by foreground-opening intents in the main app target.
/// All read/modify/write operations run without suspension on MainActor. Do not move this store
/// into an intent extension or an App Group without adding interprocess coordination.
@MainActor
struct LocalCoachPendingRequestStore {
    struct Context: Codable, Equatable, Sendable {
        var sourceID: String
        var enabled: Bool
        var usePersonalData: Bool
        var memoryEnabled: Bool
        var isFenced: Bool
    }

    struct Request: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let question: String
        let date: Date
        let context: Context?
    }

    private struct State: Codable {
        var version = 1
        var context: Context?
        var requests: [Request] = []
    }

    static let maximumRequests = 5
    static let maximumQuestionBytes = 4_000
    static let maximumFileBytes = 64 * 1_024
    static let lifetime: TimeInterval = 10 * 60
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("pending-requests-v1.json") }

    static func appLocal() throws -> Self {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw LocalCoachIntentError.storageUnavailable
        }
        return Self(directory: root.appendingPathComponent("LocalCoachIntents", isDirectory: true))
    }

    func updateContext(_ context: Context) throws {
        guard !context.sourceID.isEmpty, context.sourceID.utf8.count <= 1_024 else {
            throw LocalCoachIntentError.unavailable
        }
        var state = try load()
        guard state.context != context else { return }
        // An unscoped first-launch question is still only editable input, never authorization.
        if state.context != nil || !context.enabled || context.isFenced {
            state.requests.removeAll()
        }
        state.context = context
        try save(state)
    }

    @discardableResult
    func enqueue(_ question: String, now: Date = Date()) throws -> Request {
        let text = try Self.validatedQuestion(question)
        var state = try load()
        guard state.context?.enabled != false, state.context?.isFenced != true else {
            throw LocalCoachIntentError.unavailable
        }
        prune(&state, now: now)
        guard state.requests.count < Self.maximumRequests else { throw LocalCoachIntentError.queueFull }
        let request = Request(id: UUID(), question: text, date: now, context: state.context)
        state.requests.append(request)
        try save(state)
        return request
    }

    func consume(now: Date = Date()) throws -> Request? {
        var state = try load()
        let before = state.requests
        prune(&state, now: now)
        guard !state.requests.isEmpty else {
            if state.requests != before { try save(state) }
            return nil
        }
        let request = state.requests.removeFirst()
        // Persist removal BEFORE returning. Repeated task/foreground/notification handlers cannot
        // consume it twice, even after relaunch. A crash after this write can lose the unsent draft;
        // the String-only host API cannot atomically acknowledge presentation across a process crash.
        try save(state)
        return request
    }

    func hasPending(now: Date = Date()) throws -> Bool {
        var state = try load()
        let before = state.requests
        prune(&state, now: now)
        if state.requests != before { try save(state) }
        return !state.requests.isEmpty
    }

    func clear() throws {
        var state = try load()
        state.requests.removeAll()
        try save(state)
    }

    static func validatedQuestion(_ question: String) throws -> String {
        guard question.utf8.count <= maximumQuestionBytes else { throw LocalCoachIntentError.questionTooLong }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalCoachIntentError.emptyQuestion }
        guard !text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" && $0 != "\r"
        }) else { throw LocalCoachIntentError.invalidQuestion }
        return text
    }

    private func prune(_ state: inout State, now: Date) {
        guard state.context?.enabled != false, state.context?.isFenced != true else {
            state.requests.removeAll()
            return
        }
        var ids = Set<UUID>()
        state.requests = Array(state.requests.filter { request in
            let age = now.timeIntervalSince(request.date)
            return age.isFinite && age >= -30 && age < Self.lifetime
                && (request.context == nil || request.context == state.context)
                && (try? Self.validatedQuestion(request.question)) != nil
                && ids.insert(request.id).inserted
        }.prefix(Self.maximumRequests))
    }

    private func load() throws -> State {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return State()
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumFileBytes else {
            throw LocalCoachIntentError.storageUnavailable
        }
        let bytes = try Data(contentsOf: fileURL)
        guard bytes.count <= Self.maximumFileBytes else { throw LocalCoachIntentError.storageUnavailable }
        let state = try JSONDecoder().decode(State.self, from: bytes)
        guard state.version == 1, state.requests.count <= Self.maximumRequests else {
            throw LocalCoachIntentError.storageUnavailable
        }
        return state
    }

    private func save(_ state: State) throws {
        let bytes = try JSONEncoder().encode(state)
        guard bytes.count <= Self.maximumFileBytes else { throw LocalCoachIntentError.storageUnavailable }
        var folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.complete])
        var flags = URLResourceValues()
        flags.isExcludedFromBackup = true
        try folder.setResourceValues(flags)
        try bytes.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}

/// Host: call updateContext at launch and on source/privacy changes before reading this bridge.
/// Route using hasPendingRequest; only one UI owner calls consume when its composer can accept a
/// draft. Never call send, generateBrief, savePlan, or read aloud in response to this notification.
@MainActor
enum LocalCoachIntentBridge {
    static let notification = Notification.Name("NOOP.LocalCoach.pendingRequest")
    static private(set) var errorText: String?
    private static var contextReady = false

    @discardableResult
    static func updateContext(sourceID: String, preferences: LocalCoachPreferences, isFenced: Bool = false) -> Bool {
        contextReady = false
        do {
            try LocalCoachPendingRequestStore.appLocal().updateContext(.init(
                sourceID: sourceID, enabled: preferences.enabled, usePersonalData: preferences.usePersonalData,
                memoryEnabled: preferences.memoryEnabled, isFenced: isFenced))
            contextReady = true
            errorText = nil
            return true
        } catch {
            errorText = LocalCoachIntentError.storageUnavailable.localizedDescription
            return false
        }
    }

    static var hasPendingRequest: Bool {
        guard contextReady else { return false }
        do { return try LocalCoachPendingRequestStore.appLocal().hasPending() }
        catch { errorText = LocalCoachIntentError.storageUnavailable.localizedDescription; return false }
    }

    static func consume() -> String? {
        guard contextReady else { return nil }
        do {
            let question = try LocalCoachPendingRequestStore.appLocal().consume()?.question
            errorText = nil
            return question
        } catch {
            errorText = LocalCoachIntentError.storageUnavailable.localizedDescription
            return nil
        }
    }

    static func enqueue(_ question: String) {
        do { try enqueueFromShortcut(question) }
        catch {
            errorText = error.localizedDescription
            NotificationCenter.default.post(name: notification, object: nil)
        }
    }

    static func clearPending() {
        do { try LocalCoachPendingRequestStore.appLocal().clear(); errorText = nil }
        catch { errorText = LocalCoachIntentError.storageUnavailable.localizedDescription }
    }

    static func enqueueFromShortcut(_ question: String) throws {
        do {
            try LocalCoachPendingRequestStore.appLocal().enqueue(question)
        } catch let error as LocalCoachIntentError {
            errorText = error.localizedDescription
            throw error
        } catch {
            errorText = LocalCoachIntentError.storageUnavailable.localizedDescription
            throw LocalCoachIntentError.storageUnavailable
        }
        errorText = nil
        // The notification contains no question, records, or source identifiers.
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

enum LocalCoachPlanAction: String, AppEnum {
    case build, review
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Plan action")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .build: "Build a training plan", .review: "Review my training plan"
    ]
}

enum LocalCoachShortcutPrompt {
    static func brief(_ kind: LocalCoachBriefKind) -> String {
        switch kind {
        case .morning: "Give me a morning outlook from my latest available records, including sleep, recovery, and options for today."
        case .evening: "Review my day from the available records and help me prepare for sleep tonight."
        case .weekly: "Review my past week of sleep, recovery, and training. Help me plan the next week."
        case .activity: "Review my latest recorded activity, its workload, and recovery considerations."
        }
    }
    static func plan(_ action: LocalCoachPlanAction) -> String {
        switch action {
        case .build: "Help me build a weekly training plan. Ask about my goals, available days, equipment, and time. I will review the plan before saving."
        case .review: "Help me review my training plan against my goals and recent available records. Suggest changes for me to review; do not save changes automatically."
        }
    }
}

struct AskLocalCoachIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Coach"
    static let description = IntentDescription("Open NOOP Coach with a question to review and send. Answers stay in the app.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Question", requestValueDialog: "What would you like to ask your NOOP coach?")
    var question: String
    static var parameterSummary: some ParameterSummary { Summary("Ask Coach \(\.$question)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await LocalCoachIntentBridge.enqueueFromShortcut(question)
        return .result(dialog: "Review your question in NOOP Coach, then tap Send.")
    }
}

struct LocalCoachMorningIntent: AppIntent {
    static let title: LocalizedStringResource = "Morning Outlook"
    static let description = IntentDescription("Open Coach to review a morning outlook request before sending it.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    func perform() async throws -> some IntentResult {
        try await LocalCoachIntentBridge.enqueueFromShortcut(LocalCoachShortcutPrompt.brief(.morning))
        return .result()
    }
}

struct LocalCoachEveningIntent: AppIntent {
    static let title: LocalizedStringResource = "Evening Review"
    static let description = IntentDescription("Open Coach to review an evening and sleep preparation request.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    func perform() async throws -> some IntentResult {
        try await LocalCoachIntentBridge.enqueueFromShortcut(LocalCoachShortcutPrompt.brief(.evening))
        return .result()
    }
}

struct LocalCoachWeeklyIntent: AppIntent {
    static let title: LocalizedStringResource = "Weekly Review"
    static let description = IntentDescription("Open Coach with an editable request to review the past week.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    func perform() async throws -> some IntentResult {
        try await LocalCoachIntentBridge.enqueueFromShortcut(LocalCoachShortcutPrompt.brief(.weekly))
        return .result()
    }
}

struct LocalCoachActivityIntent: AppIntent {
    static let title: LocalizedStringResource = "Activity Review"
    static let description = IntentDescription("Open Coach with an editable request to review your latest recorded activity.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    func perform() async throws -> some IntentResult {
        try await LocalCoachIntentBridge.enqueueFromShortcut(LocalCoachShortcutPrompt.brief(.activity))
        return .result()
    }
}

struct LocalCoachSleepIntent: AppIntent {
    static let title: LocalizedStringResource = "Sleep Review"
    static let description = IntentDescription("Open Coach to review a question about your recent sleep.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    func perform() async throws -> some IntentResult {
        try await LocalCoachIntentBridge.enqueueFromShortcut(LocalCoachTopic.sleep.prompt)
        return .result()
    }
}

struct LocalCoachPlanIntent: AppIntent {
    static let title: LocalizedStringResource = "Build or Review Training Plan"
    static let description = IntentDescription("Open Coach with a plan request. Review the request and any plan in NOOP before saving.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Plan action", default: .build) var action: LocalCoachPlanAction
    static var parameterSummary: some ParameterSummary { Summary("\(\.$action) in Coach") }
    func perform() async throws -> some IntentResult {
        try await LocalCoachIntentBridge.enqueueFromShortcut(LocalCoachShortcutPrompt.plan(action))
        return .result()
    }
}
#endif
