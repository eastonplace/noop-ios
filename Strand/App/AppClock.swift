import Foundation
import os
import StrandAnalytics

/// Cached display formatters. Every mutable cache value is protected by the same lock.
enum AppClock {
    private struct Cache {
        var system24: Bool?
        var key: String?
        var formatter: DateFormatter?
    }
    private static let cache = OSAllocatedUnfairLock(initialState: Cache())
    private final class LocaleObserver: @unchecked Sendable {
        // The immutable token is only retained; NotificationCenter manages callback delivery.
        let token: NSObjectProtocol
        init() {
            token = NotificationCenter.default.addObserver(
                forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: nil
            ) { _ in AppClock.invalidate() }
        }
        deinit { NotificationCenter.default.removeObserver(token) }
    }
    private static let observer = LocaleObserver()

    static var preference: ClockFormatPreference {
        ClockFormatPreference.from(stored: UserDefaults.standard.string(forKey: ClockFormatPreference.defaultsKey))
    }
    static var systemUses24Hour: Bool {
        _ = observer
        return cache.withLock { state in
            if let value = state.system24 { return value }
            let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .autoupdatingCurrent) ?? "H"
            let value = !pattern.contains("a")
            state.system24 = value
            return value
        }
    }
    static var uses24Hour: Bool {
        ClockFormat.uses24Hour(preference: preference, systemUses24Hour: systemUses24Hour)
    }
    static var formattingLocale: Locale {
        Locale(identifier: ClockFormat.hourCycleLocaleIdentifier(base: Locale.autoupdatingCurrent.identifier,
                                                                uses24Hour: uses24Hour))
    }
    static func invalidate() { cache.withLock { $0 = Cache() } }
    static func hourMinuteFormatter() -> DateFormatter {
        let template = ClockFormat.hourMinuteTemplate(uses24Hour: uses24Hour)
        let locale = Locale.autoupdatingCurrent
        let key = "\(locale.identifier)|\(template)"
        return cache.withLock { state in
            if state.key == key, let formatter = state.formatter { return formatter }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate(template)
            state.key = key
            state.formatter = formatter
            return formatter
        }
    }
    static func hourMinute(_ date: Date) -> String { hourMinuteFormatter().string(from: date) }
    static func hourMinute(unix ts: Int) -> String { hourMinute(Date(timeIntervalSince1970: Double(ts))) }
}
