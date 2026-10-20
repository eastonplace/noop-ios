import SwiftUI

/// Stable, app-local identities. These preferences affect the + menu only.
enum QuickActionVisibilityID: String, CaseIterable, Hashable {
    case journal, live, workout, strength, intervals, breathe

    var defaultsKey: String { "quickActions.visible.\(rawValue)" }
    static let recentActivityKey = "quickActions.visible.recentActivity"

    var title: String {
        switch self {
        case .journal: "Journal"
        case .live: "Live HR"
        case .workout: "Workout"
        case .strength: "Strength"
        case .intervals: "Intervals"
        case .breathe: "Breathe"
        }
    }

    var symbol: String {
        switch self {
        case .journal: "pencil.line"
        case .live: "heart.fill"
        case .workout: "figure.run"
        case .strength: "dumbbell.fill"
        case .intervals: "timer"
        case .breathe: "wind"
        }
    }
}

/// Value-only presentation policy. It cannot change an activity or its resume surfaces.
struct QuickActionVisibilityPolicy: Equatable {
    var hiddenActions: Set<QuickActionVisibilityID> = []
    var recentActivityEnabled = true

    init(hiddenActions: Set<QuickActionVisibilityID> = [], recentActivityEnabled: Bool = true) {
        self.hiddenActions = hiddenActions
        self.recentActivityEnabled = recentActivityEnabled
    }

    init(defaults: UserDefaults) {
        hiddenActions = Set(QuickActionVisibilityID.allCases.filter {
            defaults.object(forKey: $0.defaultsKey) != nil && !defaults.bool(forKey: $0.defaultsKey)
        })
        recentActivityEnabled = defaults.object(forKey: QuickActionVisibilityID.recentActivityKey) == nil
            || defaults.bool(forKey: QuickActionVisibilityID.recentActivityKey)
    }

    var visibleActions: [QuickActionVisibilityID] {
        QuickActionVisibilityID.allCases.filter { !hiddenActions.contains($0) }
    }

    /// Runtime workout, lift, sport and GPS gates are evaluated by WorkoutQuickStart before this permission.
    func recentSport(eligible sport: String?) -> String? {
        recentActivityEnabled ? sport : nil
    }

    func isEmpty(eligibleRecentSport: String?) -> Bool {
        visibleActions.isEmpty && recentSport(eligible: eligibleRecentSport) == nil
    }
}

/// Native switches stay reactive while Settings is open. The fan takes a new snapshot on each presentation.
struct QuickActionVisibilityPreferences: DynamicProperty {
    @AppStorage(QuickActionVisibilityID.journal.defaultsKey) private var journal = true
    @AppStorage(QuickActionVisibilityID.live.defaultsKey) private var live = true
    @AppStorage(QuickActionVisibilityID.workout.defaultsKey) private var workout = true
    @AppStorage(QuickActionVisibilityID.strength.defaultsKey) private var strength = true
    @AppStorage(QuickActionVisibilityID.intervals.defaultsKey) private var intervals = true
    @AppStorage(QuickActionVisibilityID.breathe.defaultsKey) private var breathe = true
    @AppStorage(QuickActionVisibilityID.recentActivityKey) var recentActivity = true

    func binding(for action: QuickActionVisibilityID) -> Binding<Bool> {
        switch action {
        case .journal: $journal
        case .live: $live
        case .workout: $workout
        case .strength: $strength
        case .intervals: $intervals
        case .breathe: $breathe
        }
    }

    var shownCount: Int {
        QuickActionVisibilityID.allCases.filter { binding(for: $0).wrappedValue }.count
    }
}
