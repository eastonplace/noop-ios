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

// MARK: - The manual log's sport
//
// The manual log picks a sport the way the start sheet does: a catalogue name, from the recent chips or from all the
// activities. The free-text path is "Other": choosing it opens a field for the activity's own name, which is what is
// saved. A stored sport the catalogue does not list (one typed before there was a picker, an unlabelled detected bout)
// is shown as "Other" carrying its name, so editing it changes nothing it did not have to.

enum ManualWorkoutSport {
    /// What the picker shows for a stored sport: the catalogue name chosen, and the name "Other" carries. nil, or a blank
    /// sport, is a fresh log with nothing chosen yet.
    static func choice(for stored: String?) -> (chosen: String, custom: String) {
        let trimmed = stored?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !trimmed.isEmpty else { return ("", "") }
        if let named = WorkoutCatalog.sport(named: trimmed) { return (named.name, "") }
        return (WorkoutCatalog.defaultSportName, trimmed)
    }

    /// The sport that is saved: the catalogue name, or, for "Other", the name typed under it ("Other" when none is).
    /// Empty while nothing is chosen.
    static func sport(chosen: String, custom: String) -> String {
        guard chosen == WorkoutCatalog.defaultSportName else { return chosen }
        let name = custom.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? chosen : name
    }

    /// The chips under the Sport field: the recent catalogue sports, with the current choice first when it is not one of
    /// them, so what is chosen is always visible there. At most `RecentSportsPrefs.maxCount`.
    static func chips(recents: [String], chosen: String) -> [String] {
        var names = StartWorkoutChoices.recentSports(from: recents).map(\.name)
        if let named = WorkoutCatalog.sport(named: chosen), !names.contains(named.name) {
            names.insert(named.name, at: 0)
            names = Array(names.prefix(RecentSportsPrefs.maxCount))
        }
        return names
    }

    /// Whether a saved sport belongs in the recents: only catalogue sports do, since both pickers offer only those, and a
    /// free-typed name would take a slot neither of them can show.
    static func recordedName(for sport: String) -> String? {
        WorkoutCatalog.sport(named: sport)?.name
    }
}
