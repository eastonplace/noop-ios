import Foundation
import UIKit

/// Actions triggered by the strap's physical gestures on iPhone.
///
/// `lockScreen` is retained only so an older persisted preference decodes safely. It is filtered out of
/// the iPhone picker because third-party iOS apps cannot lock the device.
enum DeviceActionKind: String, Codable, CaseIterable, Identifiable {
    case none
    case lockScreen
    case buzzBack
    case markMoment
    case sleepMark
    case hapticClock
    case runShortcut

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Nothing"
        case .lockScreen: return "Lock Screen (legacy)"
        case .buzzBack: return "Buzz back (confirm)"
        case .markMoment: return "Mark a moment"
        case .sleepMark: return "Log a sleep mark"
        case .hapticClock: return "Buzz the time"
        case .runShortcut: return "Run a Shortcut…"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "circle.slash"
        case .lockScreen: return "lock.fill"
        case .buzzBack: return "waveform.path"
        case .markMoment: return "mappin.and.ellipse"
        case .sleepMark: return "moon.zzz.fill"
        case .hapticClock: return "clock.fill"
        case .runShortcut: return "bolt.fill"
        }
    }
}

enum DeviceActions {
    /// iOS exposes no supported API for a third-party app to lock the phone.
    static func lockScreen() -> Bool { false }

    /// Run a user-owned Shortcut by name through Apple's public URL scheme.
    @MainActor
    static func runShortcut(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") else { return }
        UIApplication.shared.open(url)
    }
}

// Source-compatibility aliases while the remaining call sites migrate to the iPhone-native names.
typealias MacActionKind = DeviceActionKind
typealias MacActions = DeviceActions
