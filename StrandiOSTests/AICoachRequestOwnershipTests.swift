import XCTest
import Foundation
@testable import NOOP

/// Requests use synthetic credentials, a suspended context reader, and an in-process URL protocol.
/// No Keychain item, network endpoint, or health database is accessed by these tests.
@MainActor
final class AICoachRequestOwnershipTests: XCTestCase {
    private var savedDefaults: [String: Any] = [:]
    private let defaultsKeys = ["ai.provider", "ai.model", "ai.dataConsent", "ai.customBaseURL",
                                "ai.customConnected", "ai.includeOnDeviceSignals", "ai.systemPrompt"]
    private var sessions: [URLSession] = []

    override func setUp() async throws {
        for key in defaultsKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() async throws {
        for session in sessions { session.invalidateAndCancel() }
        CoachRequestURLProtocol.handler = nil
        for key in defaultsKeys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func fixture() -> (AICoachEngine, Repository, CoachTestCredentials) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoachRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        sessions.append(session)
        let credentials = CoachTestCredentials()
        let repo = Repository(deviceId: "synthetic-coach-source")
        let engine = AICoachEngine(repo: repo, session: session, keyAccess: credentials.access)
        engine.provider = .custom
        engine.model = "synthetic-model"
        engine.customBaseURL = "https://original.invalid/v1"
        engine.customConnected = true
        engine.dataConsent = true
        engine.buildFullContextOverride = { "Synthetic personal metric: 73." }
        return (engine, repo, credentials)
    }

    func testRevokingConsentDuringContextReadPreventsNetworkRequest() async {
        let (engine, _, _) = fixture()
        let gate = CoachRequestGate()
        engine.buildFullContextOverride = { await gate.wait(); return "Private synthetic metric: 73." }
        var requests = 0
        CoachRequestURLProtocol.handler = { _ in requests += 1; return .reply("Unexpected reply") }

        let request = Task { await engine.send("How am I doing?") }
        await gate.waitUntilEntered()
        engine.dataConsent = false
        gate.release()
        await request.value

        XCTAssertEqual(requests, 0, "Revoked personal context must never reach the transport")
        XCTAssertFalse(engine.sending)
        XCTAssertFalse(engine.messages.contains { $0.role == .assistant })
    }

    func testProviderChangeDuringContextReadCannotSendOriginalKeyToNewProvider() async {
        let (engine, _, credentials) = fixture()
        engine.provider = .openAI
        credentials.owner = AIProvider.openAI.rawValue
        let gate = CoachRequestGate()
        engine.buildFullContextOverride = { await gate.wait(); return "Synthetic personal metric: 73." }
        var requests: [URLRequest] = []
        CoachRequestURLProtocol.handler = { requests.append($0); return .reply("Unexpected reply") }

        let request = Task { await engine.send("Summarize my day") }
        await gate.waitUntilEntered()
        engine.provider = .custom
        engine.customBaseURL = "https://replacement.invalid/v1"
        gate.release()
        await request.value

        XCTAssertTrue(requests.isEmpty, "The captured cloud credential must not be sent to Custom")
        XCTAssertFalse(engine.sending)
    }

    func testDisconnectDuringBriefContextReadPreventsNetworkRequest() async {
        let (engine, _, credentials) = fixture()
        let gate = CoachRequestGate()
        engine.buildFullContextOverride = { await gate.wait(); return "Synthetic personal metric: 73." }
        var requests = 0
        CoachRequestURLProtocol.handler = { _ in requests += 1; return .reply("Unexpected brief") }

        let request = Task { await engine.startBriefIfNeeded() }
        await gate.waitUntilEntered()
        engine.disconnect()
        gate.release()
        await request.value

        XCTAssertEqual(requests, 0)
        XCTAssertNil(credentials.key)
        XCTAssertTrue(engine.messages.isEmpty)
        XCTAssertFalse(engine.sending)
    }

    func testSourceInvalidationThatReopensDuringReadStillRejectsOldContext() async {
        let (engine, repo, _) = fixture()
        let gate = CoachRequestGate()
        engine.buildFullContextOverride = { await gate.wait(); return "Old source synthetic metric: 73." }
        var requests = 0
        CoachRequestURLProtocol.handler = { _ in requests += 1; return .reply("Unexpected reply") }

        let request = Task { await engine.send("Summarize my records") }
        await gate.waitUntilEntered()
        repo.verifiedExternalSurfaceFenced = true
        repo.verifiedExternalSurfaceFenced = false
        gate.release()
        await request.value

        XCTAssertEqual(requests, 0, "A completed source transition must not make an old read current again")
        XCTAssertFalse(engine.sending)
    }

    func testClearingKeyDuringContextReadDoesNotFallBackToKeylessRequest() async {
        let (engine, _, credentials) = fixture()
        let gate = CoachRequestGate()
        engine.buildFullContextOverride = { await gate.wait(); return "Synthetic personal metric: 73." }
        var requests = 0
        CoachRequestURLProtocol.handler = { _ in requests += 1; return .reply("Unexpected reply") }

        let request = Task { await engine.send("Review my records") }
        await gate.waitUntilEntered()
        engine.clearKey()
        gate.release()
        await request.value

        XCTAssertNil(credentials.key)
        XCTAssertEqual(requests, 0)
        XCTAssertFalse(engine.sending)
    }

    func testSignalOptOutDuringContextReadPreventsSendingEarlierContext() async {
        let (engine, _, _) = fixture()
        engine.includeOnDeviceSignals = true
        let gate = CoachRequestGate()
        engine.buildFullContextOverride = { await gate.wait(); return "Synthetic opted-in signal: 73." }
        var requests = 0
        CoachRequestURLProtocol.handler = { _ in requests += 1; return .reply("Unexpected reply") }

        let request = Task { await engine.send("Review my signals") }
        await gate.waitUntilEntered()
        engine.includeOnDeviceSignals = false
        gate.release()
        await request.value

        XCTAssertEqual(requests, 0)
        XCTAssertFalse(engine.sending)
    }

    func testModelChangeBackToOriginalStillCancelsOldRequest() async {
        let (engine, _, _) = fixture()
        let gate = CoachRequestGate()
        engine.buildFullContextOverride = { await gate.wait(); return "Synthetic personal metric: 73." }
        var requests = 0
        CoachRequestURLProtocol.handler = { _ in requests += 1; return .reply("Unexpected reply") }

        let request = Task { await engine.send("Review my records") }
        await gate.waitUntilEntered()
        engine.model = "replacement-model"
        engine.model = "synthetic-model"
        gate.release()
        await request.value

        XCTAssertEqual(requests, 0, "Returning to the original model must not revive cancelled work")
        XCTAssertFalse(engine.sending)
    }

    func testCallerCancellationDuringContextReadPreventsNetworkRequest() async {
        let (engine, _, _) = fixture()
        let gate = CoachRequestGate()
        engine.buildFullContextOverride = { await gate.wait(); return "Synthetic personal metric: 73." }
        var requests = 0
        CoachRequestURLProtocol.handler = { _ in requests += 1; return .reply("Unexpected reply") }

        let request = Task { await engine.send("Review my records") }
        await gate.waitUntilEntered()
        request.cancel()
        gate.release()
        await request.value

        XCTAssertEqual(requests, 0)
        XCTAssertFalse(engine.sending)
        XCTAssertNil(engine.errorText)
    }

    func testSameCustomProviderServerChangeDropsStaleModelList() async {
        let (engine, _, _) = fixture()
        let gate = CoachRequestGate()
        engine.fetchModelsOverride = { _, _ in await gate.wait(); return ["obsolete-server-model"] }
        let refresh = Task { await engine.refreshModels() }
        await gate.waitUntilEntered()
        engine.customBaseURL = "https://replacement.invalid/v1"
        gate.release()
        await refresh.value

        XCTAssertFalse(engine.availableModels.contains("obsolete-server-model"))
        XCTAssertNil(engine.errorText)
    }

    func testConcurrentSendDoesNotAppendOrSendASecondQuestion() async {
        let (engine, _, _) = fixture()
        let gate = CoachRequestGate()
        engine.buildFullContextOverride = { await gate.wait(); return "Synthetic personal metric: 73." }
        var requests = 0
        CoachRequestURLProtocol.handler = { _ in requests += 1; return .reply("First answer") }

        let first = Task { await engine.send("First question") }
        await gate.waitUntilEntered()
        let second = Task { await engine.send("Second question") }
        await Task.yield()
        gate.release()
        await first.value
        await second.value

        XCTAssertEqual(requests, 1)
        XCTAssertEqual(engine.messages.filter { $0.role == .user }.map(\.text), ["First question"])
    }

    func testRevocationKeepsVisibleTranscriptButExcludesPersonalRepliesFromNextPayload() async throws {
        let (engine, _, _) = fixture()
        var payloads: [String] = []
        CoachRequestURLProtocol.handler = { request in
            payloads.append(String(decoding: Self.body(of: request), as: UTF8.self))
            return .reply(payloads.count == 1 ? "Your private synthetic metric is 73." : "General explanation")
        }
        await engine.send("Review my records")
        engine.dataConsent = false
        await engine.send("What is recovery?")

        XCTAssertEqual(payloads.count, 2)
        let last = try XCTUnwrap(payloads.last)
        XCTAssertFalse(last.contains("private synthetic metric"))
        XCTAssertFalse(last.contains("Synthetic personal metric"))
        XCTAssertFalse(last.contains("Review my records"))
        XCTAssertTrue(last.contains("What is recovery?"))
        XCTAssertTrue(engine.messages.contains { $0.text == "Your private synthetic metric is 73." },
                      "Revocation changes outbound history, not the person's visible transcript")
    }

    func testLateOldRequestCannotPublishOrClearNewRequestBusyState() async {
        let (engine, _, _) = fixture()
        engine.dataConsent = false
        let oldGate = CoachRequestGate()
        let newGate = CoachRequestGate()
        CoachRequestURLProtocol.handler = { request in
            if request.url?.host == "original.invalid" {
                await oldGate.wait()
                return .reply("Obsolete answer")
            }
            await newGate.wait()
            return .reply("Current answer")
        }
        let oldRequest = Task { await engine.send("Old question") }
        await oldGate.waitUntilEntered()
        engine.disconnect()
        engine.customBaseURL = "https://replacement.invalid/v1"
        engine.customConnected = true
        let newRequest = Task { await engine.send("New question") }
        await newGate.waitUntilEntered()
        oldGate.release()
        await oldRequest.value

        XCTAssertTrue(engine.sending, "Only the current request owns the busy state")
        XCTAssertFalse(engine.messages.contains { $0.text == "Obsolete answer" })
        XCTAssertNil(engine.errorText, "Cancellation of the old request must not surface over the new request")
        newGate.release()
        await newRequest.value
        XCTAssertEqual(engine.messages.last?.text, "Current answer")
        XCTAssertFalse(engine.sending)
    }

    func testSourceInvalidationExcludesEarlierRepliesFromNextPayload() async throws {
        let (engine, repo, _) = fixture()
        var payloads: [String] = []
        CoachRequestURLProtocol.handler = { request in
            payloads.append(String(decoding: Self.body(of: request), as: UTF8.self))
            return .reply(payloads.count == 1 ? "Earlier source metric: 73." : "Current source answer")
        }
        await engine.send("Review earlier records")
        repo.verifiedExternalSurfaceFenced = true
        repo.verifiedExternalSurfaceFenced = false
        engine.buildFullContextOverride = { "Current source synthetic metric: 81." }
        await engine.send("Review current records")

        XCTAssertEqual(payloads.count, 2)
        let last = try XCTUnwrap(payloads.last)
        XCTAssertFalse(last.contains("Earlier source metric"))
        XCTAssertFalse(last.contains("Review earlier records"))
        XCTAssertTrue(last.contains("Current source synthetic metric: 81."))
        XCTAssertTrue(engine.messages.contains { $0.text == "Earlier source metric: 73." })
    }

    func testSourceRetirementDuringHTTPPreventsCompatibilityRetry() async {
        await assertSourceRetirementPreventsRetry(provider: .custom)
    }

    func testSourceRetirementDuringOpenAIHTTPPreventsCompatibilityRetry() async {
        await assertSourceRetirementPreventsRetry(provider: .openAI)
    }

    private func assertSourceRetirementPreventsRetry(provider: AIProvider) async {
        let (engine, repo, credentials) = fixture()
        engine.provider = provider
        credentials.owner = provider.rawValue
        var requests = 0
        CoachRequestURLProtocol.handler = { _ in
            requests += 1
            if requests == 1 {
                repo.verifiedExternalSurfaceFenced = true
                repo.verifiedExternalSurfaceFenced = false
                return .init(status: 400, data: Data(#"{"error":{"message":"unsupported max_tokens"}}"#.utf8))
            }
            return .reply("Obsolete source reply")
        }
        await engine.send("Review the source before retirement")
        XCTAssertEqual(requests, 1, "A retired source must not be transmitted again by a compatibility retry")
        XCTAssertFalse(engine.messages.contains { $0.role == .assistant })
        XCTAssertFalse(engine.sending)
    }

    func testCurrentCustomRequestStillRetriesCompatibleParameters() async {
        await assertCurrentRequestRetries(provider: .custom)
    }

    func testCurrentOpenAIRequestStillRetriesCompatibleParameters() async {
        await assertCurrentRequestRetries(provider: .openAI)
    }

    private func assertCurrentRequestRetries(provider: AIProvider) async {
        let (engine, _, credentials) = fixture()
        engine.provider = provider
        credentials.owner = provider.rawValue
        var requests: [URLRequest] = []
        CoachRequestURLProtocol.handler = { request in
            requests.append(request)
            if requests.count == 1 {
                return .init(status: 400, data: Data(#"{"error":{"message":"unsupported max_tokens"}}"#.utf8))
            }
            return .reply("Current source reply")
        }
        await engine.send("Review my day")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.url, requests.last?.url)
        let firstBody = requests.first.map { String(decoding: Self.body(of: $0), as: UTF8.self) } ?? ""
        let lastBody = requests.last.map { String(decoding: Self.body(of: $0), as: UTF8.self) } ?? ""
        XCTAssertTrue(firstBody.contains("\"max_tokens\""))
        XCTAssertTrue(lastBody.contains("\"max_completion_tokens\""))
        XCTAssertTrue(lastBody.contains("Synthetic personal metric: 73."))
        XCTAssertEqual(engine.messages.last?.text, "Current source reply")
        XCTAssertFalse(engine.sending)
        XCTAssertNil(engine.errorText)
    }

    func testCustomRetryRetainsOriginalEndpointWhenSettingsChange() async throws {
        _ = fixture()
        let client = CustomClient()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoachRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        sessions.append(session)
        var destinations: [String] = []
        CoachRequestURLProtocol.handler = { request in
            destinations.append(request.url?.absoluteString ?? "")
            if destinations.count == 1 {
                UserDefaults.standard.set("https://replacement.invalid/v1", forKey: AIProvider.customBaseURLKey)
                return .init(status: 400, data: Data(#"{"error":{"message":"unsupported max_tokens"}}"#.utf8))
            }
            return .reply("Retried answer")
        }

        let reply = try await client.send(key: "synthetic-original-key", model: "synthetic-model",
                                          systemPrompt: "Synthetic test instruction", messages: [], session: session)
        XCTAssertEqual(reply, "Retried answer")
        XCTAssertEqual(destinations, ["https://original.invalid/v1/chat/completions",
                                     "https://original.invalid/v1/chat/completions"])
    }

    func testCustomModelFetchRetainsEndpointCapturedAtCreation() async throws {
        _ = fixture()
        let client = CustomClient()
        UserDefaults.standard.set("https://replacement.invalid/v1", forKey: AIProvider.customBaseURLKey)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoachRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        sessions.append(session)
        var sent: URLRequest?
        CoachRequestURLProtocol.handler = { request in
            sent = request
            return .init(status: 200, data: Data(#"{"data":[{"id":"original-server-model"}]}"#.utf8))
        }

        let models = try await client.fetchModels(key: "synthetic-original-key", session: session)
        XCTAssertEqual(models, ["original-server-model"])
        XCTAssertEqual(sent?.url?.absoluteString, "https://original.invalid/v1/models")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-original-key")
    }

    func testUnchangedRequestUsesCapturedConfigurationAndPublishesReply() async throws {
        let (engine, _, _) = fixture()
        var request: URLRequest?
        CoachRequestURLProtocol.handler = { request = $0; return .reply("Expected answer") }
        await engine.send("Review my day")

        let sent = try XCTUnwrap(request)
        XCTAssertEqual(sent.url?.absoluteString, "https://original.invalid/v1/chat/completions")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-original-key")
        let payload = String(decoding: Self.body(of: sent), as: UTF8.self)
        XCTAssertTrue(payload.contains("Synthetic personal metric: 73."))
        XCTAssertTrue(payload.contains("Review my day"))
        XCTAssertTrue(payload.contains("synthetic-model"))
        XCTAssertEqual(engine.messages.last?.text, "Expected answer")
        XCTAssertFalse(engine.sending)
        XCTAssertNil(engine.errorText)
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}

@MainActor
private final class CoachTestCredentials {
    var key: String? = "synthetic-original-key"
    var owner: String? = AIProvider.custom.rawValue
    var access: AICoachKeyAccess {
        .init(read: { self.key }, owner: { self.owner }, save: { key, owner in
            self.key = key; self.owner = owner; return true
        }, clear: { self.key = nil; self.owner = nil })
    }
}

@MainActor
private final class CoachRequestGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
    func waitUntilEntered() async {
        for _ in 0..<2_000 {
            if !waiters.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("The controlled asynchronous operation did not start")
    }
    func release() {
        isOpen = true
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private final class CoachRequestURLProtocol: URLProtocol {
    struct Response: Sendable {
        let status: Int
        let data: Data
        static func reply(_ text: String) -> Self {
            let body: [String: Any] = ["choices": [["message": ["content": text], "finish_reason": "stop"]]]
            return Self(status: 200, data: try! JSONSerialization.data(withJSONObject: body))
        }
    }
    @MainActor static var handler: ((URLRequest) async -> Response)?
    private let deliveryState = DeliveryState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = request
        let delivery = Delivery(self, state: deliveryState)
        Task { @MainActor in
            guard let handler = Self.handler, let url = request.url else {
                delivery.fail()
                return
            }
            let result = await handler(request)
            delivery.complete(result, url: url)
        }
    }
    override func stopLoading() { deliveryState.stop() }

    /// A stopped URLProtocol must not call its client again. The lock serializes stop with delivery,
    /// including Foundation implementations that remove cancelled tasks from their registry immediately.
    private final class DeliveryState: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var stopped = false
        func stop() {
            lock.lock()
            defer { lock.unlock() }
            stopped = true
        }
    }

    /// This one task owns delivery; the lock also protects cancellation from URLSession's callback queue.
    /// The wrapper avoids asserting Sendable conformance for Foundation's URLProtocol itself.
    private final class Delivery: @unchecked Sendable {
        let owner: CoachRequestURLProtocol
        let state: DeliveryState
        init(_ owner: CoachRequestURLProtocol, state: DeliveryState) {
            self.owner = owner
            self.state = state
        }
        func fail() {
            state.lock.lock()
            defer { state.lock.unlock() }
            guard !state.stopped else { return }
            owner.client?.urlProtocol(owner, didFailWithError: URLError(.unsupportedURL))
        }
        func complete(_ result: Response, url: URL) {
            state.lock.lock()
            defer { state.lock.unlock() }
            guard !state.stopped else { return }
            let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            owner.client?.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)
            owner.client?.urlProtocol(owner, didLoad: result.data)
            owner.client?.urlProtocolDidFinishLoading(owner)
        }
    }
}
