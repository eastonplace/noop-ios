import Foundation

/// UIP-10: the WidgetKit kind strings, shared by the widget declarations and the app's per-lane reloads so
/// the two can't drift apart.
public enum WidgetKinds {
    /// `NOOPWidget`: Recovery, Strain, Sleep, HRV, live heart rate, stress and battery.
    public static let main = "NOOPWidget"
    /// The Lock Screen Strain circle.
    public static let strainAccessory = "NOOPStrainAccessoryWidget"
    /// Recorded daily stress. Reads only the verified core and its enrichment, never the live overlay.
    public static let stress = "NOOPStressWidget"

    public static let all = [main, strainAccessory, stress]
}
