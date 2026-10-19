#if os(iOS)
import Foundation

/// Hosted CI simulators report the system model as available but ship no model assets, so generation fails with
/// `GenerationError` code -1 (UnifiedAssetFramework 5000, "no underlying assets"). Only that signature may skip a live-model test.
enum LocalCoachModelAssets {
    static let skipReason = "The on-device model reports available but has no downloaded assets in this test environment."

    static func areMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain.contains("GenerationError") && nsError.code == -1
    }

    /// The engine flattens a thrown error into `localizedDescription`, e.g. "(FoundationModels.LanguageModelSession.GenerationError error -1.)".
    static func areMissing(engineError text: String?) -> Bool {
        text?.contains("GenerationError error -1") == true
    }
}
#endif
