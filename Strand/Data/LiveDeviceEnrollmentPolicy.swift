import Foundation
import WhoopStore

/// Admission for a newly enrolled live device only. Existing registry rows, source selection,
/// restore, and import readers retain their current compatibility behavior.
enum LiveDeviceEnrollmentPolicy {
    static func permits(_ device: PairedDevice) -> Bool {
        device.sourceKind == .liveBLE && device.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
    }
}
