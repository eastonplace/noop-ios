#if os(iOS)
import Foundation
import Combine
import AVFoundation
import Speech
import UIKit

/// Permission frameworks may invoke their completion handlers on arbitrary queues. Keep the
/// continuation callback nonisolated so a permission reply cannot inherit MainActor isolation from
/// LocalCoachVoice and trip Swift's executor precondition before the suspended task resumes.
enum LocalCoachPermissionBridge {
    nonisolated static func request<Value: Sendable>(
        _ register: @Sendable (@escaping @Sendable (Value) -> Void) -> Void
    ) async -> Value {
        await withCheckedContinuation { continuation in
            register { value in
                continuation.resume(returning: value)
            }
        }
    }
}

/// Host: start only from a microphone tap. Call cancel() on disappear, source changes, and privacy
/// changes. stop() keeps the latest transcript for review; cancel() also erases it. speak(_:) needs
/// a user tap or an explicit read-aloud preference and must never run from an intent handler.
@MainActor
final class LocalCoachVoice: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published private(set) var errorText: String?
    @Published private(set) var isStarting = false
    @Published private(set) var isSpeaking = false

    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var bufferSink: LocalCoachSpeechBuffer?
    private var hasTap = false
    private var ownsAudioSession = false
    private var operationID: UUID?
    private var recordingLimit: Task<Void, Never>?
    private let synthesizer = AVSpeechSynthesizer()
    private var spokenUtterance: AVSpeechUtterance?
    private var observers: Set<AnyCancellable> = []
    private static let maximumTranscriptBytes = 4_000
    private static let maximumSpokenBytes = 16_000

    override init() {
        super.init()
        synthesizer.delegate = self
        // Playback manages its own session. Capture explicitly owns/deactivates its session.
        synthesizer.usesApplicationAudioSession = false
        observeLifecycle()
    }

    isolated deinit {
        recordingLimit?.cancel()
        bufferSink?.finish()
        engine?.stop()
        if hasTap { engine?.inputNode.removeTap(onBus: 0) }
        recognitionTask?.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func start() async {
        guard !isStarting, !isRecording, !Task.isCancelled else { return }
        stopSpeaking()
        transcript = ""
        errorText = nil
        isStarting = true
        let token = UUID()
        operationID = token
        await withTaskCancellationHandler {
            await beginRecording(token: token)
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.operationID == token else { return }
                self?.stop()
            }
        }
    }

    /// End capture and reject late recognition callbacks. Preserve editable text.
    func stop() {
        operationID = nil
        isStarting = false
        isRecording = false
        recordingLimit?.cancel()
        recordingLimit = nil
        bufferSink?.finish()
        bufferSink = nil
        engine?.stop()
        if hasTap { engine?.inputNode.removeTap(onBus: 0) }
        hasTap = false
        recognitionTask?.cancel()
        recognitionTask = nil
        recognizer = nil
        engine = nil
        if ownsAudioSession {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                ownsAudioSession = false
            } catch {
                errorText = "The audio session could not close cleanly. Close Coach before trying voice input again."
            }
        }
    }

    /// Use for privacy/source changes and when the host view disappears.
    func cancel() {
        stop()
        stopSpeaking()
        transcript = ""
    }

    func speak(_ text: String) {
        stop()
        stopSpeaking()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.utf8.count <= Self.maximumSpokenBytes else {
            errorText = "This reply is too long to read aloud. Select a shorter reply."
            return
        }
        guard UIApplication.shared.applicationState == .active else { return }
        // Only installed Apple voices are eligible. Never request Personal Voice permission or
        // select a third-party speech provider that may process text outside this app's policy.
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isPersonalVoice) && $0.identifier.hasPrefix("com.apple.")
        }
        let locale = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        guard let voice = voices.first(where: { $0.language == locale })
            ?? voices.first(where: { $0.language.split(separator: "-").first.map(String.init) == language }) else {
            errorText = "No installed system voice matches your language. Add a voice in iPhone Accessibility settings or read the reply on screen."
            return
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        spokenUtterance = utterance
        isSpeaking = true
        errorText = nil
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        spokenUtterance = nil
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func beginRecording(token: UUID) async {
        defer { if operationID == token { isStarting = false } }
        guard let candidate = SFSpeechRecognizer(locale: Locale.current), candidate.supportsOnDeviceRecognition else {
            fail("On-device dictation is unavailable for this language or device. Type your question instead.", token: token)
            return
        }
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil,
              Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            fail("This build is missing its voice permission descriptions. Type your question instead.", token: token)
            return
        }

        let speechStatus: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            speechStatus = await LocalCoachPermissionBridge.request { completion in
                SFSpeechRecognizer.requestAuthorization { status in
                    completion(status)
                }
            }
        } else {
            speechStatus = SFSpeechRecognizer.authorizationStatus()
        }
        guard isCurrent(token) else { finishCancelledStart(token); return }
        guard speechStatus == .authorized else {
            fail("Speech recognition is not allowed. Enable Speech Recognition for NOOP in iPhone Settings, or type your question.", token: token)
            return
        }
        let microphoneAllowed: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted: microphoneAllowed = true
        case .denied: microphoneAllowed = false
        case .undetermined:
            microphoneAllowed = await LocalCoachPermissionBridge.request { completion in
                AVAudioApplication.requestRecordPermission { granted in
                    completion(granted)
                }
            }
        @unknown default: microphoneAllowed = false
        }
        guard isCurrent(token) else { finishCancelledStart(token); return }
        guard microphoneAllowed else {
            fail("Microphone access is not allowed. Enable the microphone for NOOP in iPhone Settings, or type your question.", token: token)
            return
        }
        guard candidate.supportsOnDeviceRecognition, candidate.isAvailable else {
            fail("On-device dictation is not ready. Type your question or try again later.", token: token)
            return
        }
        guard UIApplication.shared.applicationState != .background else {
            finishCancelledStart(token)
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            ownsAudioSession = true
            try session.setActive(true)
            let audioEngine = AVAudioEngine()
            engine = audioEngine
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
                fail("No microphone audio is available. Check the audio route and try again.", token: token)
                return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            request.taskHint = .dictation
            let sink = LocalCoachSpeechBuffer(request: request)
            bufferSink = sink
            recognizer = candidate
            recognitionTask = candidate.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self, self.operationID == token else { return }
                    if let text {
                        self.transcript = Self.bounded(text, bytes: Self.maximumTranscriptBytes)
                        if text.utf8.count > Self.maximumTranscriptBytes {
                            self.stop()
                            self.errorText = "Dictation reached its text limit. Review the captured text before sending."
                            return
                        }
                    }
                    if final || failed {
                        self.stop()
                        if failed && !final {
                            self.errorText = "On-device dictation stopped. Review the captured text or try again."
                        }
                    }
                }
            }
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { @Sendable buffer, _ in
                sink.append(buffer)
            }
            hasTap = true
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            recordingLimit = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.operationID == token else { return }
                self.stop()
                self.errorText = "Dictation stopped after one minute. Review the text or tap the microphone to continue."
            }
        } catch {
            fail("The microphone could not start. Check that another app or call is not using it, then try again.", token: token)
        }
    }

    private func isCurrent(_ token: UUID) -> Bool { operationID == token && !Task.isCancelled }
    private func finishCancelledStart(_ token: UUID) { if operationID == token { stop() } }
    private func fail(_ message: String, token: UUID) {
        guard operationID == token else { return }
        stop()
        errorText = message
    }

    private func observeLifecycle() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.cancel() } }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Permission sheets also deactivate the app. Disappearance, background, or
                    // privacy changes still invalidate a pending user-initiated start.
                    if !self.isStarting { self.stop() }
                    self.stopSpeaking()
                }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    == AVAudioSession.InterruptionType.began.rawValue
                guard began else { return }
                Task { @MainActor [weak self] in self?.stop(); self?.stopSpeaking() }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] notification in
                let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                        || reason == AVAudioSession.RouteChangeReason.noSuitableRouteForCategory.rawValue else { return }
                Task { @MainActor [weak self] in self?.stop(); self?.stopSpeaking() }
            }.store(in: &observers)
    }

    private static func bounded(_ text: String, bytes: Int) -> String {
        var result = ""
        var count = 0
        for scalar in text.unicodeScalars {
            guard count + scalar.utf8.count <= bytes else { break }
            result.unicodeScalars.append(scalar)
            count += scalar.utf8.count
        }
        return result
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishedSpeaking(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishedSpeaking(id) }
    }

    private func finishedSpeaking(_ id: ObjectIdentifier) {
        guard let spokenUtterance, ObjectIdentifier(spokenUtterance) == id else { return }
        self.spokenUtterance = nil
        isSpeaking = false
    }
}

/// Only append/finish access Speech's Objective-C request after setup. A lock prevents a realtime
/// audio callback from appending after capture stops. The request is not exposed to other actors.
private final class LocalCoachSpeechBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    init(request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        request?.append(buffer)
    }
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        request?.endAudio()
        request = nil
    }
}
#endif
