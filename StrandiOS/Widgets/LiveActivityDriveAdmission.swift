#if os(iOS)
import Foundation

/// What one drive of the Live Activity may carry, decided before it is queued.
///
/// Recovery, the day's effort and the verified context and generation are health values. They reach the Lock Screen only
/// under the App Group's active verified-sink token for the same context. A drive without that token used to be dropped
/// whole, and every drive carries the verified surface (`StrandiOSApp.driveLiveActivity`), so an install without the token
/// never requested an activity at all, workout included. Such a drive is published instead on the tokenless lane with every
/// health field removed: an unverified or stale context still never shows Recovery, and the workout still starts. A workout's
/// effort comes from the workout state, not from here, so it still shows.
struct LiveActivityDriveAdmission: Equatable {
    /// How the App Group token relates to the drive. Logged; never the context itself.
    enum TokenState: String, Equatable {
        case match, mismatch, missing
    }

    /// Non-nil only when the token names this drive's context; the drive then goes on the verified lane.
    let token: VerifiedSinkToken?
    let recovery: Int?
    let effort: Double?
    let verifiedContextId: String?
    let verifiedProjectionGeneration: Int64?
    let tokenState: TokenState
    /// The drive carried health values and no token named its context, so they were removed.
    let strippedHealth: Bool

    static func decide(
        recovery: Int?,
        effort: Double?,
        verifiedContextId: String?,
        verifiedProjectionGeneration: Int64?,
        activeToken: VerifiedSinkToken?
    ) -> LiveActivityDriveAdmission {
        let matching: VerifiedSinkToken? = {
            guard let contextId = verifiedContextId,
                  verifiedProjectionGeneration != nil,
                  let activeToken,
                  activeToken.contextId == contextId else { return nil }
            return activeToken
        }()
        let tokenState: TokenState = matching != nil ? .match : (activeToken == nil ? .missing : .mismatch)
        let carriesHealth = recovery != nil
            || effort != nil
            || verifiedContextId != nil
            || verifiedProjectionGeneration != nil
        guard carriesHealth, matching == nil else {
            return LiveActivityDriveAdmission(
                token: matching, recovery: recovery, effort: effort, verifiedContextId: verifiedContextId,
                verifiedProjectionGeneration: verifiedProjectionGeneration, tokenState: tokenState, strippedHealth: false)
        }
        return LiveActivityDriveAdmission(
            token: nil, recovery: nil, effort: nil, verifiedContextId: nil, verifiedProjectionGeneration: nil,
            tokenState: tokenState, strippedHealth: true)
    }
}
#endif
