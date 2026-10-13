import Foundation

/// CORE-09: the version of the decoder's historical-record layouts, owned by the decoder.
///
/// Bump `version` whenever a change lets the decoder read records it rejected before: a new type-47
/// layout version, a corrected offset, a new fallback. The app replays its reject archive once per value,
/// which is the only way already-ACKed history that only the archive still holds gets recovered. The replay
/// used to be keyed on the app version, which replayed for nothing on every release and missed a decoder
/// change shipped without a version bump. `WhoopDecoderSchemaTests` pins the layout table to this value,
/// so changing the table without bumping it fails the test.
public enum WhoopDecoderSchema {
    public static let version = 1
}
