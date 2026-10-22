import StrandAnalytics
import WhoopStore

struct WorkoutSuggestionContext: Equatable, Sendable {
    let sourceContext: String
    let sourceLineage: String
    let invalidationEpoch: UInt64
}

struct AutoWorkoutSuggestion: Equatable, Sendable {
    let window: DetectedWorkout
    let prediction: WorkoutTypeSuggestion.Prediction
    let sourceId: String
    let context: WorkoutSuggestionContext
    let databaseInstanceId: String
    let sourceOwner: HistoricalCursorScope

    func hasSameWindow(as other: AutoWorkoutSuggestion) -> Bool {
        sourceId == other.sourceId && sourceOwner == other.sourceOwner
            && context == other.context && databaseInstanceId == other.databaseInstanceId
            && window.startSec == other.window.startSec && window.endSec == other.window.endSec
    }
}

enum WorkoutSuggestionSaveResult: Equatable, Sendable {
    case saved
    case alreadySaved
    case stale
    case failed
}
