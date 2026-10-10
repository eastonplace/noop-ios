import Foundation

// MARK: - Start-workout rules
//
// What the start sheet decides before anything is drawn: which sport it opens on, which recent sports it offers and
// how a run's setting (outdoor or treadmill) maps onto the sports the catalogue actually has. Pure values, tested
// without a view.

/// Where a run happens, mapped onto the two catalogue sports that spell it. The catalogue has no trail-running sport,
/// so there is no trail option here: hiking is a different activity and is never offered as a kind of run.
enum WorkoutRunType: CaseIterable, Hashable {
    case outdoor
    case treadmill

    /// The catalogue sport this way of running is stored as.
    var sportName: String {
        switch self {
        case .outdoor: return "Running"
        case .treadmill: return "Treadmill run"
        }
    }

    /// The run type a sport stands for, or nil when it is not one of the two (a free-typed sport, a hike).
    static func of(sport name: String) -> WorkoutRunType? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return allCases.first { $0.sportName.caseInsensitiveCompare(trimmed) == .orderedSame }
    }
}

/// Where a sport is done, when the catalogue says so.
enum WorkoutSetting: Equatable {
    case outdoor
    case indoor
}

enum StartWorkoutChoices {
    /// The sport a first-ever start opens on, when there is no recent choice to open on.
    static let fallbackSport = "Running"

    /// The machine counterparts of the outdoor sports: a treadmill, a bike on a trainer, a rowing machine.
    private static let indoorSportNames: Set<String> = [
        "Treadmill run", "Treadmill walk", "Indoor cycle", "Row machine", "Elliptical",
    ]

    /// Where a sport is done: outdoors for the sports that record a route, indoors for their machine counterparts, and
    /// nil for everything else (a court, a studio, a gym floor), which says nothing rather than guess.
    static func setting(for sport: WorkoutCatalog.Sport) -> WorkoutSetting? {
        if sport.isDistanceSport { return .outdoor }
        return indoorSportNames.contains(sport.name) ? .indoor : nil
    }

    /// The sports the sheet can show as recent: the persisted recents, most recent first, kept to the catalogue (a
    /// live start offers only named sports) and to `RecentSportsPrefs.maxCount`.
    static func recentSports(from recents: [String]) -> [WorkoutCatalog.Sport] {
        var seen = Set<String>()
        var sports: [WorkoutCatalog.Sport] = []
        for name in recents {
            guard let sport = WorkoutCatalog.sport(named: name), seen.insert(sport.name).inserted else { continue }
            sports.append(sport)
            if sports.count == RecentSportsPrefs.maxCount { break }
        }
        return sports
    }

    /// The sport the sheet opens on: the most recent one, else running.
    static func initialSport(recents: [String]) -> String {
        recentSports(from: recents).first?.name ?? fallbackSport
    }

    /// What the sheet calls an activity in its title and its button ("Run", "Ride"). Catalogue names are stored
    /// verbatim and shown as they are; these three read better as the thing you do.
    static func displayTitle(for sport: String) -> String {
        switch sport {
        case "Running": return String(localized: "Run")
        case "Hiking": return String(localized: "Hike")
        case "Cycling": return String(localized: "Ride")
        default: return sport
        }
    }
}
