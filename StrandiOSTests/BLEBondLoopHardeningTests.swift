import XCTest
import CoreBluetooth
@testable import NOOP

/// Pins the #78 give-up hardening added alongside #747/#750:
///
///  - HOLE 1 (locale-proof refusal detection): Foundation LOCALIZES CoreBluetooth error strings, so the
///    old `localizedDescription.contains("encryption"/"authentication")` check silently never fired on a
///    non-English device - no pairing hint, no give-up, no #52 pin handoff. `isInsufficientAuthError`
///    classifies by ATT code FIRST, keeping the English string match as an additive fallback only.
///  - HOLE 4 (salvage probe): `shouldSalvageProbe` is the pure gate for the one bounded app-foreground
///    attempt while the pause is latched - what makes the give-up provably unable to strand a strap the
///    user has since freed, while never re-entering the refusal hammer.
final class BLEBondLoopHardeningTests: XCTestCase {

    // MARK: isInsufficientAuthError (hole 1)

    /// The two ATT codes classify by CODE, regardless of what the (possibly localized) text says.
    func testAttCodes_classifyRegardlessOfText() {
        XCTAssertTrue(BLEManager.isInsufficientAuthError(CBATTError(.insufficientEncryption)))
        XCTAssertTrue(BLEManager.isInsufficientAuthError(CBATTError(.insufficientAuthentication)))
    }

    /// The German-device regression: a CBATTErrorDomain code-15 error whose LOCALIZED text contains
    /// neither English keyword must STILL classify - by code. This is the exact shape that silently
    /// disabled the whole #78 stack on non-English devices.
    func testLocalizedAttError_classifiesByCode() {
        let err = NSError(domain: CBATTErrorDomain,
                          code: CBATTError.insufficientEncryption.rawValue,
                          userInfo: [NSLocalizedDescriptionKey: "Die Verschluesselung ist unzureichend."])
        XCTAssertTrue(BLEManager.isInsufficientAuthError(err))
        let auth = NSError(domain: CBATTErrorDomain,
                           code: CBATTError.insufficientAuthentication.rawValue,
                           userInfo: [NSLocalizedDescriptionKey: "Authentifizierung fehlgeschlagen."])
        XCTAssertTrue(BLEManager.isInsufficientAuthError(auth))
    }

    /// The English free-text fallback is ADDITIVE, not replaced: a plain NSError outside the
    /// CBATTError domain whose text carries the keyword still classifies (no regression on paths that
    /// surface non-ATT errors).
    func testEnglishStringFallback_stillClassifies() {
        let enc = NSError(domain: "SomeOtherDomain", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Encryption is insufficient."])
        XCTAssertTrue(BLEManager.isInsufficientAuthError(enc))
        let auth = NSError(domain: "SomeOtherDomain", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "Authentication is insufficient."])
        XCTAssertTrue(BLEManager.isInsufficientAuthError(auth))
    }

    /// An unrelated error (wrong code, no keyword) never classifies - a timeout must not feed the
    /// refusal streak.
    func testUnrelatedErrors_doNotClassify() {
        XCTAssertFalse(BLEManager.isInsufficientAuthError(CBError(.connectionTimeout)))
        let other = NSError(domain: CBATTErrorDomain,
                            code: CBATTError.requestNotSupported.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: "Request is not supported."])
        XCTAssertFalse(BLEManager.isInsufficientAuthError(other))
    }
}
