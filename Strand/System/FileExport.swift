import Foundation
import ZIPFoundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#elseif canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

/// Cross-platform "save / share a file" helper.
///
/// - macOS uses `NSSavePanel` (sandbox-safe via the user-selected-file entitlement).
/// - iOS presents the system share sheet (`UIActivityViewController`) so the user can save the file
///   to Files, AirDrop it, or send it on — the idiomatic iOS way to get a file out of the sandbox.
enum FileExport {

    /// Compatibility for consumers that require owned bytes. The production share paths use the staged
    /// file directly; this reads only the scrubbed result, never a whole raw Data + String + Data trio.
    static func sanitizedCaptureData(at source: URL) throws -> Data {
        let staged = try stagedSanitizedCapture(at: source, suggestedName: source.lastPathComponent)
        defer { removeStaged(staged) }
        return try Data(contentsOf: staged)
    }

    enum CaptureError: LocalizedError {
        case recordTooLarge, changedWhileReading
        var errorDescription: String? {
            switch self {
            case .recordTooLarge: "A capture record exceeds the safe export limit. The original file was kept."
            case .changedWhileReading: "The capture changed while it was being exported. Try again."
            }
        }
    }

    /// Raw captures are JSON/JSONL: none of the scrub's patterns cross a newline. Retain a complete
    /// record across 64 KiB reads so MACs, UUIDs, WHOOP serials, hex runs and UTF-8 scalars cannot split.
    /// PuffinCapture.encodedJSON pretty-prints each field; the 16-bit frame length bounds a valid hex
    /// field near 128 KiB. A record over 1 MiB fails closed instead of retaining an unbounded token.
    /// The open descriptor plus initial length owns the snapshot; the recorder's atomic rewrites cannot
    /// replace it mid-export. There is no truncation and the original file is never modified.
    static func stagedSanitizedCapture(at source: URL, suggestedName: String) throws -> URL {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        try input.seek(toOffset: 0)
        let directory = try stagingDirectory()
        let destination = directory.appendingPathComponent(URL(fileURLWithPath: suggestedName).lastPathComponent)
        let partial = directory.appendingPathComponent(".partial")
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: partial.path)
        #endif
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }
        var pending = Data()
        var remaining = size
        let maximumRecordBytes = 1_024 * 1_024
        func writeRecords(_ records: Data) throws {
            guard let text = String(data: records, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSFilePathErrorKey: source.path])
            }
            try output.write(contentsOf: Data(LiveState.redactPii(text).utf8))
        }
        while remaining > 0 {
            // Foundation regex/string bridges are autoreleased. Drain them per bounded read, rather
            // than retaining temporary objects for the entire serial-actor job.
            try autoreleasepool {
                try Task.checkCancellation()
                let bytes = try input.read(upToCount: Int(min(65_536, remaining))) ?? Data()
                guard !bytes.isEmpty else { throw CaptureError.changedWhileReading }
                remaining -= UInt64(bytes.count)
                pending.append(bytes)
                var start = pending.startIndex
                while let newline = pending[start...].firstIndex(of: 0x0A) {
                    let end = pending.index(after: newline)
                    guard end - start <= maximumRecordBytes else { throw CaptureError.recordTooLarge }
                    start = end
                }
                if start != pending.startIndex {
                    // Scrub all complete records in this read together. The delimiter is retained, so
                    // batching changes neither regex boundaries nor the exact bytes written.
                    try writeRecords(pending.subdata(in: pending.startIndex..<start))
                    pending = Data(pending[start...])
                }
                guard pending.count <= maximumRecordBytes else { throw CaptureError.recordTooLarge }
            }
        }
        if !pending.isEmpty { try writeRecords(pending) }
        try Task.checkCancellation()
        try output.close()
        try FileManager.default.moveItem(at: partial, to: destination)
        succeeded = true
        return destination
    }

    private static func stagingDirectory() throws -> URL {
        var directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
    }

    private static func removeStaged(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        if directory.lastPathComponent.hasPrefix("noop-export-") {
            try? FileManager.default.removeItem(at: directory)
        } else { try? FileManager.default.removeItem(at: url) }
    }

    /// Stage beside the chosen destination, then rename on that same volume. No existing user file
    /// is removed until the complete copy is ready; a failed copy or rename leaves it intact.
    static func copyAtomically(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".noop-export-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: source, to: staged)
        let status = staged.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { errno = EINVAL; return Int32(-1) }
                return rename(sourcePath, destinationPath)
            }
        }
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSFilePathErrorKey: destination.path])
        }
    }

    private static let io = ExportIO()
    private actor ExportIO {
        func stage(_ source: URL, name: String) throws -> URL {
            try FileExport.stagedSanitizedCapture(at: source, suggestedName: name)
        }
        func tail(_ source: URL, maximumBytes: Int?) throws -> (data: Data, truncated: Bool)? {
            let staged: URL
            do { staged = try FileExport.stagedSanitizedCapture(at: source, suggestedName: source.lastPathComponent) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
            defer { FileExport.removeStaged(staged) }
            let handle = try FileHandle(forReadingFrom: staged)
            defer { try? handle.close() }
            let count = try handle.seekToEnd()
            let budget = UInt64(max(0, maximumBytes ?? Int.max))
            let kept = min(count, budget)
            try handle.seek(toOffset: count - kept)
            var data = Data()
            var remaining = kept
            while remaining > 0 {
                try Task.checkCancellation()
                let part = try handle.read(upToCount: Int(min(65_536, remaining))) ?? Data()
                guard !part.isEmpty else { throw CaptureError.changedWhileReading }
                data.append(part)
                remaining -= UInt64(part.count)
            }
            return (data, count > budget)
        }
        func redact(_ entries: [BundleEntry]) -> [BundleEntry] {
            entries.map { entry in
                guard let text = String(data: entry.data, encoding: .utf8) else { return entry }
                return BundleEntry(name: entry.name, data: Data(LiveState.redactPii(text).utf8))
            }
        }
        func zip(_ entries: [BundleEntry], baseName: String) -> URL? {
            FileExport.zipData(entries: entries, baseName: baseName)
        }
        func pair(_ source: URL, fileName: String, text: String, textName: String, baseName: String) -> URL? {
            let staged = try? FileExport.stagedSanitizedCapture(at: source, suggestedName: fileName)
            defer { if let staged { FileExport.removeStaged(staged) } }
            var entries = [ZipEntry(name: textName, contents: .bytes(Data(text.utf8)))]
            if let staged { entries.insert(ZipEntry(name: fileName, contents: .file(staged)), at: 0) }
            return FileExport.zip(entries: entries, baseName: baseName)
        }
        func copy(_ source: URL, to destination: URL) throws {
            try FileExport.copyAtomically(source, to: destination)
        }
    }

    /// Keep only the already-scrubbed tail required by the existing bundle budget. The stream is
    /// scrubbed before seeking, so a serial straddling the retained-tail boundary cannot leak.
    static func sanitizedCaptureTail(at source: URL, maximumBytes: Int?) async throws -> (data: Data, truncated: Bool)? {
        try await io.tail(source, maximumBytes: maximumBytes)
    }

    static func sanitizedEntries(_ entries: [BundleEntry]) async -> [BundleEntry] {
        await io.redact(entries)
    }

    @MainActor
    static func exportSanitizedCapture(at source: URL, suggestedName: String) async throws {
        let staged = try await io.stage(source, name: suggestedName)
        if Task.isCancelled { removeStaged(staged); throw CancellationError() }
        #if os(macOS)
        defer { removeStaged(staged) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try await io.copy(staged, to: destination)
        #else
        present(activityItems: [staged], cleanup: [staged])
        #endif
    }

    /// A short `yyMMdd-HHmm` wall-clock stamp for export filenames (#510 — maddognik's protocol RE),
    /// so a reporter who saves several strap logs / raw captures in a row gets sortable, non-colliding
    /// files (e.g. `noop-strap-log-260617-1042.txt`) instead of repeatedly overwriting one name.
    /// Locale-independent (POSIX) so the stamp is stable on every machine.
    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyMMdd-HHmm"
        return f.string(from: date)
    }

    /// Compose a timestamped suggested filename — `<prefix>-<yyMMdd-HHmm>.<ext>`
    /// (e.g. `timestampedName("noop-strap-log", ext: "txt")` → `noop-strap-log-260617-1042.txt`).
    static func timestampedName(_ prefix: String, ext: String) -> String {
        "\(prefix)-\(timestamp()).\(ext)"
    }

    /// Profile-tagged, self-describing bundle filename: `noop-<profile>-<platform>-v<version>-<yyMMdd-HHmm>.zip`
    /// (spec section 5.1). Self-describing at a glance so a maintainer knows the profile, platform and
    /// version before opening the zip. `timestampedName` keeps its old 2-arg form for the existing
    /// strap-log / raw-capture callers; this is the new bundle-name builder.
    static func bundleName(profile: String, platform: String, version: String, date: Date = Date()) -> String {
        "noop-\(profile)-\(platform)-v\(version)-\(timestamp(date)).zip"
    }

    /// Write `text` to a file and let the user choose where it goes.
    @MainActor
    static func exportText(_ text: String, suggestedName: String) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
        #else
        // Write to a temp file FIRST and only present the share sheet if the file actually exists.
        // The previous `try?` swallowed write failures, then handed an empty/missing path to the
        // share sheet — the user saw a broken export with no error. Clean up the temp file after the
        // share sheet closes so the temporaryDirectory doesn't accumulate dead exports across runs.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        present(activityItems: [url], cleanup: [url])
        #endif
    }

    /// Let the user save / share an existing file at `src`. On macOS this copies to a chosen
    /// destination; on iOS it offers the file through the share sheet. `src` is owned by the caller
    /// (e.g. a Puffin capture inside the app's container) and is NOT deleted by the share-sheet
    /// completion handler — only files we staged ourselves get cleaned up.
    @MainActor
    static func exportFile(at src: URL, suggestedName: String? = nil) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName ?? src.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
        } catch { /* best-effort */ }
        #else
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        present(activityItems: [src], cleanup: [])
        #endif
    }

    /// Export an existing file AND a block of text together as a matched pair (#510, raw capture plus the
    /// strap log that produced it). Now a 2-entry case of `exportBundle`: both ride in one `.zip` so a
    /// reporter saves them in a single gesture on every platform (the old macOS path opened two save
    /// panels back-to-back; the bundle is one panel). The caller's text is already redacted by its sink;
    /// the raw capture is redacted again at this egress boundary. If the source file is absent, falls back to a
    /// single-entry bundle (just the text) so the tap is never a dead end.
    @MainActor
    static func exportPair(file src: URL, fileSuggestedName: String,
                           text: String, textSuggestedName: String) async {
        let zipName = timestampedName("noop-export", ext: "zip")
        let base = String(zipName.dropLast(4))
        guard let staged = await io.pair(src, fileName: fileSuggestedName, text: text,
                                        textName: textSuggestedName, baseName: base) else { return }
        if Task.isCancelled { removeStaged(staged); return }
        await presentBundle(staged, suggestedName: zipName)
    }

    #if os(iOS)
    /// Present `UIActivityViewController` and, once it closes, best-effort remove the URLs in
    /// `cleanup` so staged exports don't accumulate in `temporaryDirectory` across runs.
    @MainActor
    private static func present(activityItems: [Any], cleanup: [URL], completion: (() -> Void)? = nil) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared
                .connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene.windows.first?.rootViewController else {
            for url in cleanup { removeStaged(url) }
            completion?()
            return
        }
        // Present from the TOP-MOST controller, not the root (#455). When the caller is itself inside a
        // SwiftUI sheet — e.g. the Trends report is shown via `.sheet` — root already has that sheet
        // presented, so `root.present(...)` is a no-op ("already presenting…") and the share sheet never
        // appears. Climb the presentedViewController chain so the share sheet stacks on top of whatever's
        // up. (The Share-strap-log path worked only because Settings isn't a sheet — root had nothing on it.)
        var presenter = root
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        if !cleanup.isEmpty || completion != nil {
            // Fires after the share sheet is dismissed (saved or cancelled). We clean up staged files and
            // then run `completion` (M1/#812: the Test Centre report opens its prefilled issue here, once
            // the share sheet is gone, so the in-app SafariVC presents with nothing else on screen).
            vc.completionWithItemsHandler = { _, _, _, _ in
                for url in cleanup { removeStaged(url) }
                completion?()
            }
        }
        // iPad: anchor the popover to the screen centre to avoid a crash.
        if let pop = vc.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        presenter.present(vc, animated: true)
    }
    #endif

    // MARK: - Bundle export (Test Centre, spec section 5.1)

    /// A file destined for the zip bundle: its in-zip name plus the bytes. Text entries (report.txt,
    /// meta.json) are produced by the assembler; existing on-disk files (raw-capture, screenshot) are
    /// read into Data by the assembler. EVERY entry must already be redacted by the caller (section 5.3).
    /// Equatable so the assembler cap can assert an undersized bundle is returned untouched (section 5.4).
    struct BundleEntry: Equatable, Sendable { let name: String; let data: Data }

    private struct ZipEntry {
        enum Contents { case bytes(Data), file(URL) }
        let name: String
        let contents: Contents
    }

    /// Zip `entries` into a single staged `.zip` under the temporary directory and return its URL, or nil
    /// if there are no entries. Pure file IO, no UI, so it is unit-testable. Uses ZIPFoundation's `Archive`
    /// which is available on macOS and iOS without shelling out. The caller presents the URL (NSSavePanel
    /// on macOS, share sheet on iOS) and cleans it up.
    static func zipData(entries: [BundleEntry], baseName: String) -> URL? {
        zip(entries: entries.map { ZipEntry(name: $0.name, contents: .bytes($0.data)) }, baseName: baseName)
    }

    private static func zip(entries: [ZipEntry], baseName: String) -> URL? {
        guard !entries.isEmpty, let directory = try? stagingDirectory() else { return nil }
        let name = URL(fileURLWithPath: baseName).lastPathComponent + ".zip"
        let url = directory.appendingPathComponent(name)
        do {
            let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
            for entry in entries {
                try Task.checkCancellation()
                switch entry.contents {
                case .bytes(let data):
                    try archive.addEntry(with: entry.name, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                        let start = Int(position)
                        return data.subdata(in: start..<min(start + size, data.count))
                    }
                case .file(let source):
                    let handle = try FileHandle(forReadingFrom: source)
                    defer { try? handle.close() }
                    let count = try handle.seekToEnd()
                    try archive.addEntry(with: entry.name, type: .file, uncompressedSize: Int64(count)) { position, size in
                        try handle.seek(toOffset: UInt64(position))
                        return try handle.read(upToCount: size) ?? Data()
                    }
                }
            }
            return url
        } catch { removeStaged(url); return nil }
    }

    /// Zip `entries` into one `.zip` and hand it to the user (NSSavePanel on macOS, share sheet on iOS).
    /// EVERY entry must already be redacted by the caller (section 5.3); the 20 MB cap (section 5.4) is the
    /// assembler's job before it calls here. Returns the staged / saved zip URL, nil on cancel or failure.
    @MainActor @discardableResult
    static func exportBundle(entries: [BundleEntry], suggestedName: String,
                             completion: (() -> Void)? = nil) async -> URL? {
        let base = suggestedName.hasSuffix(".zip") ? String(suggestedName.dropLast(4)) : suggestedName
        guard let staged = await io.zip(entries, baseName: base) else { completion?(); return nil }
        if Task.isCancelled { removeStaged(staged); return nil }
        return await presentBundle(staged, suggestedName: suggestedName, completion: completion)
    }

    @MainActor @discardableResult
    private static func presentBundle(_ staged: URL, suggestedName: String,
                                      completion: (() -> Void)? = nil) async -> URL? {
        #if os(macOS)
        defer { removeStaged(staged) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return nil }
        do { try await io.copy(staged, to: dest) }
        catch { return nil }
        return dest
        #else
        present(activityItems: [staged], cleanup: [staged], completion: completion)
        return staged
        #endif
    }
}
