/// Local value state for the suggestion card. Request tokens make delayed reads and save results
/// harmless after a dismissal, source change, or a newer candidate. A failed save keeps the user's type.
struct AutoWorkoutCardState {
    private(set) var candidate: AutoWorkoutSuggestion?
    var selectedType = "Workout"
    private(set) var saving = false
    private(set) var saveResult: WorkoutSuggestionSaveResult?
    private var loadToken = 0
    private var saveToken = 0

    mutating func beginLoad() -> Int {
        loadToken &+= 1
        return loadToken
    }

    mutating func receive(_ next: AutoWorkoutSuggestion?, for request: Int) {
        guard request == loadToken else { return }
        // A transient read failure also returns no candidate. It must not dismiss an in-flight write
        // or erase its retry state. Source/toggle changes explicitly clear and invalidate this state.
        if next == nil, saving || saveResult == .failed { return }
        let sameWindow = next.map { new in candidate.map { $0.hasSameWindow(as: new) } ?? false } ?? false
        candidate = next
        if !sameWindow {
            selectedType = next?.prediction.sport ?? "Workout"
            saving = false
            saveResult = nil
            saveToken &+= 1
        }
    }

    mutating func beginSave() -> Int? {
        guard candidate != nil, !saving else { return nil }
        saving = true
        saveResult = nil
        saveToken &+= 1
        return saveToken
    }

    @discardableResult
    mutating func completeSave(_ result: WorkoutSuggestionSaveResult, for request: Int) -> Bool {
        guard request == saveToken, saving else { return false }
        saving = false
        if result == .failed {
            saveResult = result
        } else {
            clear()
        }
        return true
    }

    mutating func clear() {
        loadToken &+= 1
        saveToken &+= 1
        candidate = nil
        selectedType = "Workout"
        saving = false
        saveResult = nil
    }
}
