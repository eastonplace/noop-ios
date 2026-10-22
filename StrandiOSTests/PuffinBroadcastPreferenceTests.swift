import Foundation
import XCTest
@testable import NOOP

@MainActor
final class PuffinBroadcastPreferenceTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults, String) -> Void) {
        let domain = "PuffinBroadcastPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        body(defaults, domain)
    }

    func testAbsentChoiceDoesNotRequestADeviceWrite() {
        withDefaults { defaults, domain in
            XCTAssertNil(PuffinExperiment.savedBroadcastHrChoice(in: defaults, domainName: domain))
        }
    }

    func testBothExplicitChoicesArePreservedForReconnect() {
        withDefaults { defaults, domain in
            for choice in [true, false] {
                defaults.set(choice, forKey: PuffinExperiment.broadcastHrKey)
                XCTAssertEqual(PuffinExperiment.savedBroadcastHrChoice(in: defaults, domainName: domain), choice)
            }
        }
    }

    func testRegistrationDefaultsDoNotBecomeADeviceWriteChoice() {
        withDefaults { defaults, domain in
            for fallback in [false, true] {
                defaults.register(defaults: [PuffinExperiment.broadcastHrKey: fallback])
                XCTAssertNil(PuffinExperiment.savedBroadcastHrChoice(in: defaults, domainName: domain))
            }
            defaults.set(false, forKey: PuffinExperiment.broadcastHrKey)
            XCTAssertEqual(PuffinExperiment.savedBroadcastHrChoice(in: defaults, domainName: domain), false)
        }
    }

    func testMalformedSavedChoiceIsIgnored() {
        withDefaults { defaults, domain in
            let malformedValues: [Any] = ["not-a-bool", 0, 1, 2, 1.0, [true]]
            for malformed in malformedValues {
                defaults.set(malformed, forKey: PuffinExperiment.broadcastHrKey)
                XCTAssertNil(PuffinExperiment.savedBroadcastHrChoice(in: defaults, domainName: domain),
                             "A non-Boolean saved value must not authorize a firmware write: \(malformed)")
            }
        }
    }
}
