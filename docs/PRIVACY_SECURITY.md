# Privacy and Security

NOOP currently ships as an iPhone app and processes supported strap and health data locally. There are no Android, macOS app, or watchOS clients in this repository.

> NOOP is not a medical device. Biometric values and derived scores are sensitive estimates. Review [DISCLAIMER.md](../DISCLAIMER.md) and [ATTRIBUTION.md](../ATTRIBUTION.md).

## Data flow

- Bluetooth samples, imports, profiles, settings, and derived metrics are stored on the iPhone in app-controlled SQLite/files or system-protected preferences/keychain storage.
- Apple Health access is permission-scoped and runs through iPhone HealthKit. It does not require a NOOP watch app.
- Widgets and Live Activities receive bounded snapshots through the configured App Group.
- User-created backup files can contain plaintext health data. Anyone with access to an exported file may be able to read it; store and share backups accordingly.

## Network behavior

Core protocol, storage, import, and analytics paths are local. The optional AI Coach is the only user-facing feature designed to contact a configured model provider. It requires user configuration and an explicit request; the provider receives the content needed for that request under the provider's own privacy terms.

Swift Package Manager and Xcode may access dependency hosts while building. Build-time dependency downloads are not app runtime telemetry.

## Platform protections

iOS supplies app-container isolation and data-protection classes. HealthKit, Bluetooth, location, notifications, App Groups, and background execution remain subject to entitlements, provisioning, and user permission. These protections reduce casual cross-app access but do not replace device passcode security or encrypted handling of exported backups.

## Diagnostics

Connection and test diagnostics should remain bounded and avoid tokens, full biometric payloads, or personal identifiers. Never attach an unsanitized database, Apple Health export, WHOOP export, or Bluetooth capture to a public issue. Use the in-app report/export controls and inspect the artifact before sharing it.

## Backup and restore

Restore accepts user-selected data and must treat archives and databases as untrusted input. The implementation validates database identity/integrity and uses rollback safeguards. Archive handling should remain allowlisted and bounded by entry count, uncompressed size, duplicate-name, and compression-ratio checks.

## Reporting a security issue

Do not publish exploitable details or personal data in a normal issue. Follow the private reporting path documented by the repository owner, and include the affected version, iOS version, impact, and a minimal sanitized reproduction.
