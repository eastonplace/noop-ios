// Verified external surfaces consume the single durable projection.

#if os(iOS)
import Foundation
import NoopPhase34Core
import StrandDesign
import WhoopStore

struct ExternalSurfaceProjection: Equatable {
    let contextId: String
    let deviceId: String
    let generation: Int64
    let logicalDayKey: String
    let recovery: Int?
    /// The verified projection's own Strain on the 0...21 display scale, for its logical day. Read through `effort(...)`.
    private let verifiedEffort: Double?
    let sleepScore: Int?

    static func recoveryValue(_ value: Double) -> Int? {
        guard value.isFinite, (0...100).contains(value),
              value.rounded() >= Double(Int.min), value.rounded() <= Double(Int.max)
        else { return nil }
        return Int(value.rounded())
    }

    static func effortValue(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return StrainScale.displayValue(fromStored: value)
    }

    init(_ projection: VerifiedHealthProjection) {
        contextId = projection.contextId
        deviceId = projection.deviceId
        generation = projection.generation
        logicalDayKey = projection.logicalDay.key
        recovery = projection.visibleMetric(.recovery).flatMap { Self.recoveryValue($0.value) }
        verifiedEffort = projection.visibleStrainValue.flatMap(Self.effortValue)
        sleepScore = projection.visibleMetric(.sleepScore).flatMap { Int(exactly: $0.value.rounded()) }
    }

    /// The display-scale Strain the Live Activity may show at `now`: the projection's own while its logical day is the one
    /// Today is on, and otherwise the one Today shows for the current logical day (`todayStrain`), or none.
    /// After the 04:00 rollover the newest projection can still be yesterday's, and its Strain is not today's;
    /// this is the rule the widget core and the live overlay follow. The surface is held between drives, so
    /// the day is decided at the drive, not when the surface was built.
    @MainActor
    func effort(
        now: Date = Date(),
        calendar: Calendar = .current,
        todayStrain: (String) -> ResolvedStrain?
    ) -> Double? {
        let currentKey = WidgetCoreDay.currentKey(now: now, calendar: calendar)
        if logicalDayKey == currentKey { return verifiedEffort }
        return (try? CivilDay(key: currentKey))
            .flatMap { WidgetSnapshot.liveStoredStrain(todayStrain(currentKey), day: $0) }
            .flatMap(Self.effortValue)
    }
}
#endif
