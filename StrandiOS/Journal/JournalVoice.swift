#if os(iOS)
import Foundation
import Combine
import AVFoundation
import Speech
import UIKit

enum JournalVoiceEvent: Sendable {
    case transcript(String, isFinal: Bool)
    case failed(String)
}

enum JournalVoiceFailure: Error, LocalizedError {
    case onDeviceUnavailable, permissionDescriptionsMissing, speechPermissionDenied, microphonePermissionDenied
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .onDeviceUnavailable: return "On-device dictation is unavailable for this language or device. You can type your entry."
        case .permissionDescriptionsMissing: return "Dictation is unavailable in this build. You can type your entry."
        case .speechPermissionDenied: return "Speech Recognition is not allowed. Enable it for NOOP in iPhone Settings, or type your entry."
        case .microphonePermissionDenied: return "Microphone access is not allowed. Enable it for NOOP in iPhone Settings, or type your entry."
        case .microphoneUnavailable: return "The microphone could not start. Check your audio route or type your entry."
        }
    }
}

/// The hardware boundary is injectable; journal lifecycle tests exercise the production state
/// machine without requesting permissions or recording a real microphone.
@MainActor
protocol JournalVoiceCapture: AnyObject {
    func start(receive: @escaping @MainActor @Sendable (JournalVoiceEvent) -> Void) async throws
    func finish()
    func cancel()
}

/// Input-only dictation, independent of Coach model availability and Coach consent. A tap starts
/// capture; finish drains accepted audio into a final transcript, while cancel invalidates all work.
@MainActor
final class JournalVoice: ObservableObject {
    enum Phase: Equatable { case idle, requestingPermission, recording, finishing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var errorText: String?

    private let capture: any JournalVoiceCapture
    private let finalizationTimeout: Duration
    private var operationID: UUID?
    private var recordingLimit: Task<Void, Never>?
    private var finalizationLimit: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []
    var isBusy: Bool { phase != .idle }

    init(capture: (any JournalVoiceCapture)? = nil, finalizationTimeout: Duration = .seconds(3)) {
        self.capture = capture ?? AppleJournalVoiceCapture()
        self.finalizationTimeout = finalizationTimeout
        observeLifecycle()
    }

    isolated deinit {
        recordingLimit?.cancel()
        finalizationLimit?.cancel()
        capture.cancel()
    }

    func start() async {
        guard phase == .idle, !Task.isCancelled else { return }
        let token = UUID()
        operationID = token
        transcript = ""
        errorText = nil
        phase = .requestingPermission
        await withTaskCancellationHandler {
            do {
                try await capture.start { [weak self] event in
                    guard let self, self.operationID == token else { return }
                    self.receive(event)
                }
                guard operationID == token, !Task.isCancelled else { return }
                phase = .recording
                recordingLimit = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard let self, self.operationID == token else { return }
                    self.finish()
                }
            } catch is CancellationError {
                if operationID == token { cancel() }
            } catch {
                guard operationID == token else { return }
                complete(message: error.localizedDescription)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.operationID == token else { return }
                self?.cancel()
            }
        }
    }

    /// Stop microphone capture while accepting the recognizer's final result for a bounded window.
    func finish() {
        guard phase == .recording, let token = operationID else { return }
        recordingLimit?.cancel()
        recordingLimit = nil
        phase = .finishing
        capture.finish()
        finalizationLimit = Task { @MainActor [weak self, finalizationTimeout] in
            do { try await Task.sleep(for: finalizationTimeout) } catch { return }
            guard let self, self.operationID == token else { return }
            self.complete(message: self.transcript.isEmpty
                ? "No transcript was returned. Try dictating again or type your entry."
                : "Dictation could not finish. The captured text is available below; check it before using it.")
        }
    }

    /// Use on dismissal, source/day/catalog changes, and explicit cancellation.
    func cancel() {
        complete(message: nil)
        transcript = ""
    }

    private func receive(_ event: JournalVoiceEvent) {
        switch event {
        case .transcript(let text, let final):
            transcript = Self.bounded(text, bytes: 4_000)
            if text.utf8.count > 4_000 {
                complete(message: "Dictation reached the entry limit. Check the captured text before using it.")
            } else if final {
                complete(message: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No speech was captured. Try again or type your entry." : nil)
            }
        case .failed(let message):
            complete(message: message)
        }
    }

    private func complete(message: String?) {
        operationID = nil
        recordingLimit?.cancel()
        finalizationLimit?.cancel()
        recordingLimit = nil
        finalizationLimit = nil
        capture.cancel()
        phase = .idle
        errorText = message
    }

    private func observeLifecycle() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.cancel() } }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    // Permission sheets deactivate the app too; their token remains valid until an
                    // actual dismissal/background/source change cancels the requested operation.
                    if self?.phase == .recording { self?.finish() }
                }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    == AVAudioSession.InterruptionType.began.rawValue
                guard began else { return }
                Task { @MainActor [weak self] in
                    guard self?.isBusy == true else { return }
                    self?.complete(message: "Dictation was interrupted. Check any captured text or try again.")
                }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] notification in
                let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                    || reason == AVAudioSession.RouteChangeReason.noSuitableRouteForCategory.rawValue else { return }
                Task { @MainActor [weak self] in
                    guard self?.isBusy == true else { return }
                    self?.complete(message: "The microphone route changed. Check any captured text or try again.")
                }
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
}

@MainActor
private final class AppleJournalVoiceCapture: JournalVoiceCapture {
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var buffer: JournalSpeechBuffer?
    private var hasTap = false
    private var ownsAudioSession = false
    private var operationID: UUID?

    func start(receive: @escaping @MainActor @Sendable (JournalVoiceEvent) -> Void) async throws {
        cancel()
        let token = UUID()
        operationID = token
        guard let candidate = SFSpeechRecognizer(locale: Locale.current),
              candidate.supportsOnDeviceRecognition else { throw JournalVoiceFailure.onDeviceUnavailable }
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil,
              Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            throw JournalVoiceFailure.permissionDescriptionsMissing
        }
        // This small nonisolated bridge is shared with Coach's speech input, not its model or policy.
        let speechStatus: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            speechStatus = await LocalCoachPermissionBridge.request { completion in
                SFSpeechRecognizer.requestAuthorization { completion($0) }
            }
        } else { speechStatus = SFSpeechRecognizer.authorizationStatus() }
        try check(token)
        guard speechStatus == .authorized else { throw JournalVoiceFailure.speechPermissionDenied }
        let microphoneAllowed: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted: microphoneAllowed = true
        case .denied: microphoneAllowed = false
        case .undetermined:
            microphoneAllowed = await LocalCoachPermissionBridge.request { completion in
                AVAudioApplication.requestRecordPermission { completion($0) }
            }
        @unknown default: microphoneAllowed = false
        }
        try check(token)
        guard microphoneAllowed else { throw JournalVoiceFailure.microphonePermissionDenied }
        guard candidate.supportsOnDeviceRecognition, candidate.isAvailable else {
            throw JournalVoiceFailure.onDeviceUnavailable
        }
        guard UIApplication.shared.applicationState != .background else { throw CancellationError() }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            ownsAudioSession = true
            try session.setActive(true)
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
                throw JournalVoiceFailure.microphoneUnavailable
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            request.taskHint = .dictation
            let buffer = JournalSpeechBuffer(request: request)
            self.buffer = buffer
            recognizer = candidate
            recognitionTask = candidate.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard self?.operationID == token else { return }
                    if let text { receive(.transcript(text, isFinal: final)) }
                    if failed && !final {
                        receive(.failed("On-device dictation stopped. Check any captured text or try again."))
                    }
                }
            }
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { @Sendable audio, _ in buffer.append(audio) }
            hasTap = true
            engine.prepare()
            try engine.start()
        } catch {
            cancel()
            throw JournalVoiceFailure.microphoneUnavailable
        }
    }

    func finish() {
        endCapture()
        recognitionTask?.finish()
    }

    func cancel() {
        operationID = nil
        endCapture()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognizer = nil
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard operationID == token else { throw CancellationError() }
    }

    private func endCapture() {
        engine?.stop()
        if hasTap { engine?.inputNode.removeTap(onBus: 0) }
        hasTap = false
        buffer?.finish()
        buffer = nil
        engine = nil
        if ownsAudioSession {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                ownsAudioSession = false
            } catch {
                // Retain ownership so a later cancel/deinit retries cleanup rather than forgetting
                // an active recording session after an audio-route interruption.
            }
        }
    }

    isolated deinit { cancel() }
}

/// AVAudioEngine's real-time callback and main-actor teardown may overlap. The request is never
/// exposed across actors; append and endAudio serialize through this narrow lock.
private final class JournalSpeechBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    init(request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }

    func append(_ audio: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        request?.append(audio)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        request?.endAudio()
        request = nil
    }
}
#endif
