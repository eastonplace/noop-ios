#if os(iOS)
import Foundation
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

struct LocalCoachCheck: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable { case passed = "Passed", failed = "Failed", skipped = "Not tested" }
    var id: String
    var title: String
    var status: Status
    var detail: String
}

@MainActor
enum LocalCoachDiagnostics {
    nonisolated static func isReadyReply(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(CharacterSet(charactersIn: "`")))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() == "READY"
    }
    static var operationalSummary: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return """
        NOOP \(version), build \(build). \(ProcessInfo.processInfo.operatingSystemVersionString).
        Apple on-device model available: \(modelAvailable).
        Protected data available: \(UIApplication.shared.isProtectedDataAvailable).
        Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled).
        Open Coach settings > Testing & bug reports to run local checks or prepare a report.
        This status read does not run tests, read health values, inspect Bluetooth, or establish that a bug is fixed.
        """
    }
    /// This contains operational state only. Never add prompts, memory or biometric values.
    static func report(coach: LocalCoachEngine, title: String, steps: String,
                       expected: String, actual: String, checks: [LocalCoachCheck]) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let state: String
        switch coach.availability {
        case .available: state = "Available"
        case .checking: state = "Checking"
        case .unsupported: state = "Unsupported device or OS"
        case .notReady: state = "Model not ready"
        case .disabled: state = "Coach disabled"
        case .unavailable: state = "Model unavailable"
        }
        return """
        # NOOP Coach issue
        \(LocalCoachText.bounded(title, bytes: 300))

        ## Steps to reproduce
        \(LocalCoachText.bounded(steps, bytes: 4_000))

        ## Expected
        \(LocalCoachText.bounded(expected, bytes: 2_000))

        ## Observed
        \(LocalCoachText.bounded(actual, bytes: 4_000))

        ## Environment
        App: \(version) (\(build))
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Preview: \(coach.isPreview)
        On-device model: \(state)
        Context capacity: \(coach.contextCapacity.map(String.init) ?? "unknown") tokens
        Coach enabled: \(coach.preferences.enabled)
        Local-record permission: \(coach.preferences.usePersonalData)
        Memory permission: \(coach.preferences.memoryEnabled)
        Response active: \(coach.isResponding)
        Active tool count: \(coach.activeTools.count)
        Error visible: \(coach.errorText != nil)
        Protected storage available: \(UIApplication.shared.isProtectedDataAvailable)
        Low power mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)

        ## Checks from this visit
        \(checks.isEmpty ? "No checks run." : checks.map { "\($0.title): \($0.status.rawValue). \($0.detail)" }.joined(separator: "\n"))

        No conversation, memory, health values, account keys, source identifiers or raw logs are attached automatically.
        Review your own description for private information before sharing.
        """
    }

    static func runLocalChecks(preview: Bool) async -> [LocalCoachCheck] {
        var results: [LocalCoachCheck] = []
        let tools = LocalCoachDataService.tools
        let valid = !tools.isEmpty && Set(tools.map(\.id)).count == tools.count
            && tools.allSatisfy { !$0.id.isEmpty && !$0.description.isEmpty }
        results.append(.init(id: "tools", title: "Tool registration", status: valid ? .passed : .failed,
                             detail: "\(tools.count) named tools checked for empty or duplicate registrations. Tool execution is not tested here."))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noop-coach-check-" + UUID().uuidString)
        do {
            let store = LocalCoachPersistence(directory: directory)
            var sample = LocalCoachPersistence.State(sourceID: "synthetic-check")
            sample.conversations = [.init(title: "Synthetic check", messages: [.init(role: .user, text: "Test record")])]
            try store.save(sample)
            let loaded = try store.load(sourceID: sample.sourceID)
            guard loaded.conversations == sample.conversations else { throw CocoaError(.fileReadCorruptFile) }
            try FileManager.default.removeItem(at: directory)
            results.append(.init(id: "storage", title: "Local save and read", status: .passed,
                                 detail: "A synthetic record completed a write/read round trip in temporary storage. Your saved history was not changed."))
        } catch {
            // Never include filesystem paths or underlying error payloads in the shareable report.
            results.append(.init(id: "storage", title: "Local save and read", status: .failed,
                                 detail: "The temporary storage check failed. Check available storage and unlock the phone before retrying."))
        }
        let available = modelAvailable
        results.append(.init(id: "model", title: "Apple Intelligence readiness",
                             status: preview ? .skipped : available ? .passed : .failed,
                             detail: preview ? "Preview data cannot establish model readiness."
                                 : available ? "The system reports its local model is available. Generation requires the separate model test."
                                 : "The system model is unavailable. Check Apple Intelligence settings and model download status."))
        return results
    }

    static var modelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    /// An isolated synthetic prompt: no Repository, conversation or health data enters this session.
    static func testModel() async throws -> LocalCoachCheck {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.isAvailable else {
                return .init(id: "generation", title: "Local model generation", status: .skipped,
                             detail: "Apple Intelligence is not available on this device.")
            }
            let start = Date()
            let session = LanguageModelSession(model: model, instructions: "Follow the user's formatting request exactly.")
            var response = ""
            for try await update in session.streamResponse(to: "Reply with the single word READY.",
                    options: GenerationOptions(temperature: 0, maximumResponseTokens: 20)) {
                try Task.checkCancellation()
                response = update.content
            }
            try Task.checkCancellation()
            let passed = isReadyReply(response)
            let seconds = Date().timeIntervalSince(start).formatted(.number.precision(.fractionLength(1)))
            let observed = response.isEmpty ? "<empty>" : LocalCoachText.bounded(response, bytes: 240).replacingOccurrences(of: "\n", with: " ")
            return .init(id: "generation", title: "Local model generation", status: passed ? .passed : .failed,
                         detail: "Synthetic prompt completed in \(seconds) seconds. Reply: \(String(reflecting: observed)). Single-word check \(passed ? "passed" : "failed"). This does not test coaching quality or tool calls.")
        }
        #endif
        return .init(id: "generation", title: "Local model generation", status: .skipped,
                     detail: "This OS does not support Foundation Models.")
    }
}
#endif
