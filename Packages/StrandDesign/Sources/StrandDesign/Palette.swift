import SwiftUI

// MARK: - Hex color helper

public extension Color {
    /// Parse an RGB or RGBA hex string into sRGB components.
    static func sRGBComponents(hex: String) -> (r: Double, g: Double, b: Double, a: Double) {
        let raw = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&int)
        switch raw.count {
        case 8:
            return (
                Double((int >> 24) & 0xFF) / 255.0,
                Double((int >> 16) & 0xFF) / 255.0,
                Double((int >> 8) & 0xFF) / 255.0,
                Double(int & 0xFF) / 255.0
            )
        default:
            return (
                Double((int >> 16) & 0xFF) / 255.0,
                Double((int >> 8) & 0xFF) / 255.0,
                Double(int & 0xFF) / 255.0,
                1.0
            )
        }
    }

    init(hex: String) {
        let c = Color.sRGBComponents(hex: hex)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    /// Compatibility initializer for the former two-theme palette.
    /// Noop now has one fixed dark appearance, so the dark value is always authoritative.
    init(light: String, dark: String) {
        _ = light
        self.init(hex: dark)
    }
}

// MARK: - Strand palette
//
// One WHOOP-aligned dark color system. Public names stay stable so all existing views inherit the
// migration without component rewrites. Metric colors retain their specific meaning. Generic chrome,
// links, selection, and primary actions use WHOOP teal.

public enum StrandPalette {

    #if os(iOS)
    public static let appCanvas = Color(hex: "#101518")
    #else
    public static let appCanvas = canvas
    #endif

    // MARK: Surfaces

    public static let canvas = Color(hex: "#101518")
    public static let card = Color(hex: "#182126")
    public static let cardBorder = Color(hex: "#2A383F")
    public static let inset = Color(hex: "#202C32")
    public static let surfaceBase = canvas
    public static let surfaceRaised = card
    public static let surfaceOverlay = card
    public static let surfaceInset = inset
    public static let hairline = Color(hex: "#FFFFFF14")
    public static let hairlineStrong = Color(hex: "#FFFFFF2E")

    // MARK: Text

    public static let textPrimary = Color(hex: "#FFFFFF")
    public static let textSecondary = Color(hex: "#C3CDD2")
    public static let textTertiary = Color(hex: "#8E9DA4")

    public static let onDarkPrimary = textPrimary
    public static let onDarkSecondary = textSecondary
    public static let onDarkTertiary = textTertiary

    public static let glowAmbient = Color(hex: "#063D2E")

    // MARK: Chrome and actions

    public static let ink = Color(hex: "#00F19F")
    public static let onInk = Color(hex: "#07120E")
    public static let link = Color(hex: "#00F19F")
    public static let accent = link
    public static let accentHover = Color(hex: "#66F8C7")
    public static let accentMuted = Color(hex: "#123D32")
    public static let focusRing = link
    public static let disabledOpacity: Double = 0.45

    // MARK: Pillars and semantic data

    public static let chargeAccent = Color(hex: "#16EC06")
    public static let chargeTint = Color(hex: "#163817")
    public static let effortAccent = strainAccent
    public static let effortTint = Color(hex: "#102F43")
    public static let restAccent = sleepAccent
    public static let restTint = Color(hex: "#26343D")
    public static let stressAccent = Color(hex: "#FF8A00")
    public static let stressTint = Color(hex: "#3A2A18")
    public static let liveRed = Color(hex: "#FF0026")
    public static let liveRedTint = Color(hex: "#3A1720")

    /// WHOOP score colors. Keep each color tied to its metric meaning.
    public static let recoveryHigh = Color(hex: "#16EC06")
    public static let recoveryMed = Color(hex: "#FFDE00")
    public static let recoveryLow = Color(hex: "#FF0026")
    public static let recoveryData = Color(hex: "#67AEE6")
    public static let strainAccent = Color(hex: "#0093E7")
    public static let sleepAccent = Color(hex: "#7BA1BB")
    public static let sleepNeedTeal = Color(hex: "#00F19F")

    public static let journalAccent = Color(hex: "#8E6FD6")

    public static let stressRestful = Color(hex: "#16EC06")
    public static let stressLow = Color(hex: "#7BA1BB")
    public static let stressMedium = Color(hex: "#FFDE00")
    public static let stressHigh = Color(hex: "#FF0026")

    public static let success = Color(hex: "#16EC06")
    public static let info = Color(hex: "#0093E7")
    public static let warning = Color(hex: "#FFDE00")
    public static let warningBg = Color(hex: "#3A3314")
    public static let destructive = Color(hex: "#FF0026")
    public static let error = destructive

    // MARK: Data style compatibility

    public static var chartStyle: ChartStyle = .titanium
    @inline(__always) static var isClassic: Bool { false }

    // The legacy ramps remain available for binary/source compatibility. The fixed app style does not
    // select them, and the fixed-dark color initializer resolves their dark values.
    static let cRecovery000 = Color(light: "#CB3A2F", dark: "#E5483B")
    static let cRecovery030 = Color(light: "#D87328", dark: "#EE8B3C")
    static let cRecovery055 = Color(light: "#CFA528", dark: "#F2C53D")
    static let cRecovery078 = Color(light: "#74A53A", dark: "#A6D04E")
    static let cRecovery100 = Color(light: "#2E9E4F", dark: "#46B45A")
    static let cRecoveryStops: [Gradient.Stop] = [
        .init(color: cRecovery000, location: 0.00),
        .init(color: cRecovery030, location: 0.30),
        .init(color: cRecovery055, location: 0.55),
        .init(color: cRecovery078, location: 0.78),
        .init(color: cRecovery100, location: 1.00),
    ]

    static let cStrain000 = Color(light: "#5E92D6", dark: "#7FB2E8")
    static let cStrain033 = Color(light: "#3A74C4", dark: "#4A90E2")
    static let cStrain066 = Color(light: "#284F9C", dark: "#2F6FCB")
    static let cStrain100 = Color(light: "#1C3E80", dark: "#1E4FA0")
    static let cStrainStops: [Gradient.Stop] = [
        .init(color: cStrain000, location: 0.00),
        .init(color: cStrain033, location: 0.33),
        .init(color: cStrain066, location: 0.66),
        .init(color: cStrain100, location: 1.00),
    ]

    static let cSleepAwake = Color(light: "#8C95A3", dark: "#C9CCD6")
    static let cSleepLight = Color(light: "#3A80D6", dark: "#6FA8E8")
    static let cSleepDeep = Color(light: "#203E73", dark: "#2A4C8F")
    static let cSleepREM = Color(light: "#6A4FC0", dark: "#8E6FD6")

    static let cZone1 = Color(light: "#828D9B", dark: "#9AA7B5")
    static let cZone2 = Color(light: "#2E9E4F", dark: "#46B45A")
    static let cZone3 = Color(light: "#CFA528", dark: "#F2C53D")
    static let cZone4 = Color(light: "#D87328", dark: "#EE8B3C")
    static let cZone5 = Color(light: "#CB3A2F", dark: "#E5483B")

    static let cStressStops: [Gradient.Stop] = [
        .init(color: Color(light: "#2E9E4F", dark: "#46B45A"), location: 0.0),
        .init(color: Color(light: "#CFA528", dark: "#F2C53D"), location: 0.5),
        .init(color: Color(light: "#CB3A2F", dark: "#E5483B"), location: 1.0),
    ]

    // MARK: Recovery

    public static let recovery000 = recoveryLow
    public static let recovery030 = recoveryLow
    public static let recovery055 = recoveryMed
    public static let recovery078 = recoveryHigh
    public static let recovery100 = recoveryHigh

    /// Hard band boundaries keep recovery colors meaningful instead of blending them into new states.
    public static var recoveryStops: [Gradient.Stop] {
        [
            .init(color: recoveryLow, location: 0.00),
            .init(color: recoveryLow, location: 0.329),
            .init(color: recoveryMed, location: 0.330),
            .init(color: recoveryMed, location: 0.659),
            .init(color: recoveryHigh, location: 0.660),
            .init(color: recoveryHigh, location: 1.00),
        ]
    }

    public static var recoveryGradient: Gradient { Gradient(stops: recoveryStops) }

    // MARK: Strain

    public static let strain000 = strainAccent
    public static let strain033 = strainAccent
    public static let strain066 = strainAccent
    public static let strain100 = strainAccent

    public static var strainStops: [Gradient.Stop] {
        [
            .init(color: strainAccent, location: 0.00),
            .init(color: strainAccent, location: 1.00),
        ]
    }

    public static var strainGradient: Gradient { Gradient(stops: strainStops) }

    // MARK: Sleep stages and heart-rate zones

    public static let stageAwake = Color(hex: "#E5484D")
    public static let stageREM = Color(hex: "#A8CBF7")
    public static let stageLight = Color(hex: "#5B9BF6")
    public static let stageDeep = Color(hex: "#1E3A8A")
    public static var sleepAwake: Color { stageAwake }
    public static var sleepREM: Color { stageREM }
    public static var sleepLight: Color { stageLight }
    public static var sleepDeep: Color { stageDeep }

    public static let zoneZ5 = Color(hex: "#FF6B2C")
    public static let zoneZ4 = Color(hex: "#FFA424")
    public static let zoneZ3 = Color(hex: "#33BE66")
    public static let zoneZ2 = Color(hex: "#64B5F6")
    public static let zoneZ1 = Color(hex: "#B7C9D3")
    public static var zone1: Color { zoneZ1 }
    public static var zone2: Color { zoneZ2 }
    public static var zone3: Color { zoneZ3 }
    public static var zone4: Color { zoneZ4 }
    public static var zone5: Color { zoneZ5 }
    public static var hrZones: [Color] { [zone1, zone1, zone2, zone3, zone4, zone5] }

    // MARK: Status and metrics

    public static var statusPositive: Color { success }
    public static var statusWarning: Color { warning }
    public static var statusCritical: Color { destructive }

    public static var metricCyan: Color { sleepNeedTeal }
    public static var metricPurple: Color { journalAccent }
    public static var metricAmber: Color { stressAccent }
    public static var metricRose: Color { liveRed }

    // MARK: Domain color worlds

    public static var chargeColor: Color { chargeAccent }
    public static var chargeDeep: Color { Color(hex: "#0BAF13") }
    public static var chargeBright: Color { recoveryHigh }
    public static var chargeGlow: Color { recoveryHigh }
    public static var chargeGradient: Gradient { Gradient(colors: [chargeDeep, chargeBright]) }

    public static var effortColor: Color { strainAccent }
    public static var effortDeep: Color { strainAccent }
    public static var effortBright: Color { strainAccent }
    public static var effortGlow: Color { strainAccent }
    public static var effortGradient: Gradient { Gradient(colors: [effortDeep, effortBright]) }

    public static var restColor: Color { sleepAccent }
    public static var restDeep: Color { Color(hex: "#4F7187") }
    public static var restBright: Color { sleepAccent }
    public static var restGlow: Color { sleepAccent }
    public static var restGradient: Gradient { Gradient(colors: [restDeep, restBright]) }

    public static var stressColor: Color { stressAccent }
    public static var stressDeep: Color { success }
    public static var stressBright: Color { destructive }
    public static var stressGlow: Color { stressAccent }
    public static var stressGradient: Gradient { Gradient(colors: [stressDeep, stressColor, stressBright]) }

    // MARK: Shared backgrounds and compatibility ramps

    public static let scenicCenter = Color(hex: "#283339")
    public static let scenicEdge = Color(hex: "#101518")
    public static let scenicStar = Color(hex: "#C8CFD8")

    public static let cardFillTop = Color(hex: "#283339")
    public static let cardFillBottom = Color(hex: "#101518")

    /// Legacy "gold" names now resolve to the unified teal action ramp.
    public static let gold = Color(hex: "#00F19F")
    public static let goldLight = Color(hex: "#66F8C7")
    public static let goldDeep = Color(hex: "#00A96F")
    public static let goldDeepText = Color(hex: "#07120E")
    public static let tipCore = Color(hex: "#FFFFFF")
    public static let signalYellow = Color(hex: "#FFDE00")
    public static let goldGradient = Gradient(colors: [goldLight, gold, goldDeep])

    public static let titaniumTop = Color(hex: "#B7C4CA")
    public static let titaniumMid = Color(hex: "#7E8F97")
    public static let titaniumLow = Color(hex: "#56666E")
    public static let titaniumDeep = Color(hex: "#344249")
    public static let titaniumGradient = Gradient(
        colors: [titaniumTop, titaniumMid, titaniumLow, titaniumDeep]
    )

    // MARK: Sampling helpers

    public static func recoveryColor(_ score: Double) -> Color {
        guard !isClassic else { return sample(stops: cRecoveryStops, at: score / 100.0) }
        switch score {
        case ..<33: return recoveryLow
        case ..<66: return recoveryMed
        default: return recoveryHigh
        }
    }

    public static func strainColor(_ strain: Double) -> Color {
        _ = strain
        return strainAccent
    }

    public static func effortTint(fraction: Double) -> Color {
        _ = fraction
        return strainAccent
    }

    public static func recoveryState(_ score: Double) -> String {
        switch score {
        case ..<25: return String(localized: "DEPLETED", bundle: .module)
        case ..<50: return String(localized: "LOW", bundle: .module)
        case ..<70: return String(localized: "MODERATE", bundle: .module)
        case ..<88: return String(localized: "PRIMED", bundle: .module)
        default: return String(localized: "PEAK", bundle: .module)
        }
    }

    public static func hrZoneColor(_ zone: Int) -> Color {
        let z = max(1, min(5, zone))
        return hrZones[z]
    }

    public static func sleepStageColor(_ stage: SleepStage) -> Color {
        switch stage {
        case .awake: return sleepAwake
        case .light: return sleepLight
        case .deep: return sleepDeep
        case .rem: return sleepREM
        }
    }

    public static func sample(stops: [Gradient.Stop], at position: Double) -> Color {
        guard let first = stops.first else { return .clear }
        guard stops.count > 1 else { return first.color }
        let t = min(max(position, 0.0), 1.0)

        var lower = stops[0]
        var upper = stops[stops.count - 1]
        for index in 0..<(stops.count - 1) {
            let a = stops[index]
            let b = stops[index + 1]
            if t >= a.location && t <= b.location {
                lower = a
                upper = b
                break
            }
        }

        let span = upper.location - lower.location
        let localT = span > 0 ? (t - lower.location) / span : 0
        return interpolate(lower.color, upper.color, localT)
    }

    static func interpolate(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ca = ColorComponentCache.components(of: a)
        let cb = ColorComponentCache.components(of: b)
        let value = min(max(t, 0.0), 1.0)
        return Color(
            .sRGB,
            red: ca.r + (cb.r - ca.r) * value,
            green: ca.g + (cb.g - ca.g) * value,
            blue: ca.b + (cb.b - ca.b) * value,
            opacity: ca.a + (cb.a - ca.a) * value
        )
    }
}

// MARK: - Resolved component cache

/// Gradient endpoints are static palette colors. Cache their resolved components once.
enum ColorComponentCache {
    private static var store: [Color: (r: Double, g: Double, b: Double, a: Double)] = [:]
    private static let lock = NSLock()

    static func components(of color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
        lock.lock()
        if let hit = store[color] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let resolved = color.rgbaComponents
        lock.lock()
        if store.count > 512 {
            store.removeAll(keepingCapacity: true)
        }
        store[color] = resolved
        lock.unlock()
        return resolved
    }
}

// MARK: - Sleep stage

public enum SleepStage: String, CaseIterable, Sendable {
    case awake
    case light
    case deep
    case rem

    public var label: String {
        switch self {
        case .awake: return String(localized: "Awake", bundle: .module)
        case .light: return String(localized: "Light", bundle: .module)
        case .deep: return String(localized: "Deep", bundle: .module)
        case .rem: return "REM"
        }
    }

    public var bandRank: Int {
        switch self {
        case .awake: return 0
        case .rem: return 1
        case .light: return 2
        case .deep: return 3
        }
    }
}

// MARK: - Color component extraction

extension Color {
    var rgbaComponents: (r: Double, g: Double, b: Double, a: Double) {
        #if canImport(AppKit)
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        ns.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #elseif canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #else
        return (0, 0, 0, 1)
        #endif
    }
}

#if DEBUG
#Preview("Palette") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            swatchRow("Surfaces", [
                ("base", StrandPalette.surfaceBase),
                ("raised", StrandPalette.surfaceRaised),
                ("overlay", StrandPalette.surfaceOverlay),
                ("inset", StrandPalette.surfaceInset),
                ("hairline", StrandPalette.hairline),
                ("strong", StrandPalette.hairlineStrong),
            ])
            swatchRow("Text", [
                ("primary", StrandPalette.textPrimary),
                ("secondary", StrandPalette.textSecondary),
                ("tertiary", StrandPalette.textTertiary),
            ])
            swatchRow("Actions", [
                ("teal", StrandPalette.accent),
                ("hover", StrandPalette.accentHover),
                ("muted", StrandPalette.accentMuted),
            ])
            swatchRow("Scores", [
                ("recovery", StrandPalette.recoveryHigh),
                ("strain", StrandPalette.strainAccent),
                ("sleep", StrandPalette.sleepAccent),
                ("need", StrandPalette.sleepNeedTeal),
            ])
            swatchRow("Recovery bands", [
                ("low", StrandPalette.recoveryLow),
                ("medium", StrandPalette.recoveryMed),
                ("high", StrandPalette.recoveryHigh),
            ])
        }
        .padding(24)
    }
    .frame(width: 520, height: 760)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

@ViewBuilder
private func swatchRow(_ title: String, _ items: [(String, Color)]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title.uppercased())
            .font(.caption)
            .foregroundStyle(StrandPalette.textTertiary)
        HStack(spacing: 10) {
            ForEach(items, id: \.0) { name, color in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color)
                        .frame(width: 64, height: 48)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(StrandPalette.hairline, lineWidth: 1)
                        )
                    Text(name)
                        .font(.system(size: 9))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }
}
#endif
