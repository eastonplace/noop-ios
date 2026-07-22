import Foundation
import WhoopStore

/// iPhone-side HealthKit device registration. This is not a watchOS target; it lets the iOS app describe
/// recent Apple Health data honestly when the user has authorized HealthKit.
enum AppleWatchDevice {
    nonisolated static let deviceId = "apple-health"
    nonisolated static let recentWindowDays = 14
    nonisolated static let candidateCapabilities: Set<Metric> = [.hr, .hrv, .sleep, .steps, .spo2, .skinTemp]

    nonisolated static func capabilities(daily: [DailyMetric], apple: [AppleDaily]) -> Set<Metric> {
        var capabilities: Set<Metric> = []
        if daily.contains(where: { $0.restingHr != nil })
            || apple.contains(where: { $0.avgHr != nil || $0.maxHr != nil }) {
            capabilities.insert(.hr)
        }
        if daily.contains(where: { $0.avgHrv != nil }) { capabilities.insert(.hrv) }
        if daily.contains(where: { ($0.totalSleepMin ?? 0) > 0 }) { capabilities.insert(.sleep) }
        if daily.contains(where: { ($0.steps ?? 0) > 0 })
            || apple.contains(where: { ($0.steps ?? 0) > 0 }) {
            capabilities.insert(.steps)
        }
        if daily.contains(where: { $0.spo2Pct != nil }) { capabilities.insert(.spo2) }
        if daily.contains(where: { $0.skinTempDevC != nil }) { capabilities.insert(.skinTemp) }
        return capabilities.intersection(candidateCapabilities)
    }

    nonisolated static func device(
        daily: [DailyMetric],
        apple: [AppleDaily],
        authorized: Bool,
        existing: PairedDevice? = nil,
        now: Date = Date()
    ) -> PairedDevice? {
        guard authorized else { return nil }
        let capabilities = capabilities(daily: daily, apple: apple)
        guard !capabilities.isEmpty else { return nil }
        let timestamp = Int(now.timeIntervalSince1970)
        return PairedDevice(
            id: deviceId,
            brand: "Apple",
            model: "Apple Health",
            nickname: existing?.nickname,
            peripheralId: nil,
            sourceKind: .liveAppleWatch,
            capabilities: capabilities,
            status: .paired,
            addedAt: existing?.addedAt ?? timestamp,
            lastSeenAt: timestamp
        )
    }

    @MainActor
    static func registerIfAuthorized(
        registry: DeviceRegistry,
        store: WhoopStore,
        authorized: Bool,
        now: Date = Date()
    ) async {
        guard authorized else { return }
        let to = dayString(now)
        let fromDate = Calendar.current.date(byAdding: .day, value: -recentWindowDays, to: now) ?? now
        let from = dayString(fromDate)
        let daily = (try? await store.dailyMetrics(deviceId: deviceId, from: from, to: to)) ?? []
        let apple = (try? await store.appleDaily(deviceId: deviceId, from: from, to: to)) ?? []
        let existing = registry.devices.first(where: { $0.id == deviceId })
        guard let value = device(
            daily: daily,
            apple: apple,
            authorized: authorized,
            existing: existing,
            now: now
        ) else { return }
        registry.add(value)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    private static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }
}
