import Foundation

// MARK: - The sport's name as it is drawn
//
// The live screen's title, the resume bar and the start page's title all call a sport by the same name: specific ("Outdoor run",
// "Treadmill run", "Strength training") and in the person's language. The STORED sport name is data: it is persisted verbatim, round-trips
// through CSV and Apple Health export and must read the same on Android, so it is never translated or changed. Only what is drawn is
// localized, here, from a closed table of the catalogue's sports (`WorkoutCatalog.all`) plus the two spellings strength sessions arrive
// under; a sport the table does not know (a free-typed one, a detected bout) is drawn as it is stored.

enum WorkoutSportTitle {
    /// The localized, sentence-case name for a stored sport name.
    static func name(for stored: String) -> String {
        guard let known = known(stored) else { return WorkoutSource.displaySport(stored) }
        return known
    }

    /// Whether the table has a name for this stored sport (every catalogue sport but the free-text "Other" does).
    static func isKnown(_ stored: String) -> Bool { known(stored) != nil }

    private static func known(_ stored: String) -> String? {
        switch stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "running": return String(localized: "Outdoor run")
        case "walking": return String(localized: "Outdoor walk")
        case "hiking": return String(localized: "Hike")
        case "cycling": return String(localized: "Outdoor ride")
        case "open-water swim": return String(localized: "Open-water swim")
        case "rowing": return String(localized: "Rowing")
        case "treadmill run": return String(localized: "Treadmill run")
        case "treadmill walk": return String(localized: "Treadmill walk")
        case "indoor cycle": return String(localized: "Indoor cycle")
        case "pool swim": return String(localized: "Pool swim")
        case "row machine": return String(localized: "Row machine")
        case "elliptical": return String(localized: "Elliptical")
        case "strength", "strength training", "traditional strength training": return String(localized: "Strength training")
        case "bodybuilding": return String(localized: "Bodybuilding")
        case "weightlifting": return String(localized: "Weightlifting")
        case "hiit": return String(localized: "HIIT")
        case "yoga": return String(localized: "Yoga")
        case "pilates": return String(localized: "Pilates")
        case "boxing": return String(localized: "Boxing")
        case "basketball": return String(localized: "Basketball")
        case "soccer": return String(localized: "Soccer")
        case "baseball": return String(localized: "Baseball")
        case "badminton": return String(localized: "Badminton")
        case "tennis": return String(localized: "Tennis")
        case "squash": return String(localized: "Squash")
        case "racquetball": return String(localized: "Racquetball")
        case "table tennis": return String(localized: "Table tennis")
        case "volleyball": return String(localized: "Volleyball")
        case "martial arts": return String(localized: "Martial arts")
        case "dancing": return String(localized: "Dancing")
        case "golf": return String(localized: "Golf")
        case "climbing": return String(localized: "Climbing")
        case "stretching": return String(localized: "Stretching")
        case "skiing": return String(localized: "Skiing")
        case "snowboarding": return String(localized: "Snowboarding")
        case "padel": return String(localized: "Padel")
        case "pickleball": return String(localized: "Pickleball")
        case "bowling": return String(localized: "Bowling")
        default: return nil
        }
    }
}
