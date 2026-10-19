#if os(iOS)
import Foundation

enum LocalCoachTopic: String, Codable, CaseIterable, Identifiable, Sendable {
    case today, training, sleep, recovery, stress, nutrition, habits, goals
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .today: return "sun.horizon"
        case .training: return "figure.strengthtraining.traditional"
        case .sleep: return "moon.stars"
        case .recovery: return "heart.circle"
        case .stress: return "waveform.path"
        case .nutrition: return "leaf"
        case .habits: return "checkmark.circle"
        case .goals: return "scope"
        }
    }
    var prompt: String {
        switch self {
        case .today: return "Give me my daily outlook using my latest available records. Help me plan today."
        case .training: return "Review my recent training and help me decide what to do next."
        case .sleep: return "Compare my recent sleep with my usual pattern and help me plan tonight."
        case .recovery: return "Explain my recovery trend and the recorded factors behind it."
        case .stress: return "Help me understand the stress information available in my records."
        case .nutrition: return "Review my recorded nutrition and help me support my training."
        case .habits: return "Which logged habits are associated with my better days? Distinguish association from cause."
        case .goals: return "Help me build a weekly plan around my goals and available training time."
        }
    }
}

struct LocalCoachEvidence: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var detail: String
    var source: String
    var date: Date?
}

struct LocalCoachMetric: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var value: String
    var unit: String
    var detail: String
    var samples: [Double]
}

struct LocalCoachSnapshot: Codable, Equatable, Sendable {
    var generatedAt: Date
    var sourceID: String
    var latestDay: String?
    var summary: String
    var metrics: [LocalCoachMetric]
    var evidence: [LocalCoachEvidence]
    var context: String
    static var empty: Self {
        Self(generatedAt: Date(), sourceID: "", latestDay: nil,
             summary: "Connect your data when you are ready. You can still ask general training questions.",
             metrics: [], evidence: [], context: "No personal records supplied.")
    }
}

struct LocalCoachToolDescriptor: Identifiable, Sendable {
    var id: String
    var title: String
    var description: String
    var symbol: String
}

struct LocalCoachToolResult: Sendable {
    var text: String
    var evidence: [LocalCoachEvidence]
    /// Visual summaries built from the same records as `text`. Never sent to the model.
    var cards: [LocalCoachCard] = []
}

struct LocalCoachMessage: Codable, Equatable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
    var createdAt = Date()
    var evidence: [LocalCoachEvidence] = []
    var toolNames: [String] = []
    var isInterrupted = false
    /// Optional so conversations saved before cards existed (no `cards` key) still decode.
    var cards: [LocalCoachCard]? = nil

    enum CodingKeys: String, CodingKey {
        case id, role, text, createdAt, evidence, toolNames, isInterrupted, cards
    }
}

struct LocalCoachConversation: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var updatedAt = Date()
    var messages: [LocalCoachMessage] = []
    var pinned = false
}

struct LocalCoachMemory: Codable, Equatable, Identifiable, Sendable {
    enum Category: String, Codable, CaseIterable, Identifiable, Sendable {
        case goals, identity, lifestyle, preferences, events, healthHistory, mood
        var id: String { rawValue }
        var title: String { self == .healthHistory ? "Health history" : rawValue.capitalized }
    }
    var id = UUID()
    var category: Category
    var text: String
    var updatedAt = Date()
    var enabled = true
}

struct LocalCoachPlannedExercise: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var catalogID: String
    var name: String
    var equipment: String
    var sets: Int
    var reps: Int
    var restSeconds: Int
    var note: String = "Choose a load that keeps each repetition controlled."
}

struct LocalCoachPlanDay: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var dayOffset: Int
    var title: String
    var focus: String
    var minutes: Int
    var exercises: [LocalCoachPlannedExercise]
    var completed = false
}

struct LocalCoachPlan: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var summary: String
    var createdAt = Date()
    var sourceID: String
    var days: [LocalCoachPlanDay]
    var saved = false
    var sourceContext: String? = nil
}

struct LocalCoachPreferences: Codable, Equatable, Sendable {
    var enabled = true
    var usePersonalData = false
    var memoryEnabled = true
    var autoBrief = false
    var speakReplies = false
    var style = "Direct and supportive"
    var customInstructions = ""
}

enum LocalCoachAvailability: Equatable, Sendable {
    case checking, available, unsupported, notReady, disabled, unavailable(String)
    var title: String {
        switch self {
        case .checking: return "Checking Apple Intelligence"
        case .available: return "On-device intelligence"
        case .unsupported: return "Requires Apple Intelligence"
        case .notReady: return "Apple Intelligence is getting ready"
        case .disabled: return "Coach is paused"
        case .unavailable(let message): return message
        }
    }
}

enum LocalCoachBriefKind: String, Sendable, CaseIterable { case morning, evening, weekly, activity }
#endif
