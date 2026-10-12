import Foundation

/// The wearer's maximum heart rate, shared with the widget extension through the App Group's defaults.
///
/// The app writes it (override-aware, from `ProfileStore`) at launch and whenever the profile changes; the widgets and
/// the Live Activity read it to colour heart rate by the wearer's own zones instead of the fixed 60 / 110 split. The
/// extension never opens the profile or the database. A missing or implausible value reads as nil, and the caller falls
/// back to the fixed split, which is what the widgets did before personal zones.
public enum WidgetPersonalZones {
    public static let hrMaxKey = "noop.widget.hrMax"

    /// What `HRZoneStyle.Thresholds(hrMax:)` accepts; anything outside is not a maximum heart rate.
    public static let plausibleRange: ClosedRange<Double> = 100...260

    private static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: WidgetSnapshot.suiteName) }

    /// Store the maximum. Returns whether the stored value changed, so the caller reloads the widgets only when it did.
    @discardableResult
    public static func publish(hrMax: Int, to defaults: UserDefaults? = nil) -> Bool {
        guard plausibleRange.contains(Double(hrMax)), let defaults = defaults ?? sharedDefaults else { return false }
        let previous = defaults.object(forKey: hrMaxKey) as? Int
        guard previous != hrMax else { return false }
        defaults.set(hrMax, forKey: hrMaxKey)
        return true
    }

    /// The stored maximum, or nil when the app has not written one (or wrote something implausible).
    public static func hrMax(from defaults: UserDefaults? = nil) -> Double? {
        guard let defaults = defaults ?? sharedDefaults,
              let stored = defaults.object(forKey: hrMaxKey) as? Int else { return nil }
        let value = Double(stored)
        return plausibleRange.contains(value) ? value : nil
    }
}
