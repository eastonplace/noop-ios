import Foundation
import StrandAnalytics

/// BLE-10: lines appended since the last publish into `LiveState.log`.
struct PendingLogLines {
    var lines: [String] = []
    var publishScheduled = false
}

extension LiveState {
    /// BLE-10: queued lines reach the published `log` at most this often, so a burst of strap-log lines
    /// republishes the 5,000-line array once instead of once per line.
    nonisolated static let logPublishIntervalNanoseconds: UInt64 = 250_000_000
    /// Trim in chunks: only once the array passes the cap by this many lines.
    nonisolated static let logTrimSlack = 250

    public func append(log line: String, domain: TestDomain? = nil) {
        let tagged = domain.map { "[\($0.id)] " + line } ?? line
        let redacted = Self.redactPii(tagged)
        pendingLogLines.lines.append(redacted)
        logTailPersistence.append(redacted)
        schedulePendingLogPublish()

        if line.contains("session persisted"),
            let rows = ConnectionReadout.drainedRowsFromSummary(line)
        {
            TestCentre.noteDrainedRows(rows)
        }
    }

    public func taggedTail(domain: TestDomain) -> [String] {
        let prefix = "[\(domain.id)] "
        return log.filter { $0.hasPrefix(prefix) } + pendingLogLines.lines.filter { $0.hasPrefix(prefix) }
    }

    private func schedulePendingLogPublish() {
        guard !pendingLogLines.publishScheduled else { return }
        pendingLogLines.publishScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.logPublishIntervalNanoseconds)
            self?.publishPendingLog()
        }
    }

    /// Move the queued lines into the published `log` in one mutation (one publish), trimming in chunks.
    func publishPendingLog() {
        pendingLogLines.publishScheduled = false
        guard !pendingLogLines.lines.isEmpty else { return }
        var updated = log
        updated.append(contentsOf: pendingLogLines.lines)
        pendingLogLines.lines.removeAll(keepingCapacity: true)
        if updated.count > Self.maxLogLines + Self.logTrimSlack {
            updated.removeFirst(updated.count - Self.maxLogLines)
        }
        log = updated
    }

    nonisolated private static let tailKey = "strapLog.tail"
    nonisolated static let tailLimit = 2_000

    nonisolated static func persistTail(_ lines: [String]) {
        // BLE-10: lines are redacted once, when appended, and `persistedLogTail()` re-redacts older stored
        // data when it loads; redacting again here only doubled the regex work of every write.
        let tail = lines.count > tailLimit ? Array(lines.suffix(tailLimit)) : lines
        UserDefaults.standard.set(tail, forKey: tailKey)
    }

    public func flushLogPersistence() async {
        await logTailPersistence.flush()
    }

    public func clearLog() async {
        pendingLogLines.lines.removeAll(keepingCapacity: true)
        log.removeAll(keepingCapacity: true)
        await logTailPersistence.clear()
    }

    nonisolated public static func persistedLogTail() -> [String] {
        let stored = (UserDefaults.standard.array(forKey: tailKey) as? [String]) ?? []
        let redacted = stored.map(Self.redactPii)
        if redacted != stored {
            UserDefaults.standard.set(redacted, forKey: tailKey)
        }
        return redacted
    }

    nonisolated public static func scheduledExportText(extraHeaderLines: [String] = []) -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var header = "NOOP strap log (scheduled export) — iOS\nApp: \(version)\niOS: "
            + ProcessInfo.processInfo.operatingSystemVersionString + "\n"
        if !extraHeaderLines.isEmpty { header += extraHeaderLines.joined(separator: "\n") + "\n" }
        header += String(repeating: "-", count: 40) + "\n"
        return header + persistedLogTail().joined(separator: "\n")
    }

    /// Mask serial-shaped ASCII runs embedded inside a hexadecimal frame dump. Event 109 on WHOOP 5/MG
    /// can carry the strap serial this way, where the ordinary text rules below cannot see it. Preserve all
    /// other bytes so the diagnostic remains useful. Process an even prefix of odd-length runs and leave a
    /// trailing half-byte unchanged.
    nonisolated static func redactHexDump(_ hex: String) -> String {
        let characters = Array(hex)
        guard characters.count >= 16 else { return hex }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count / 2)
        var characterIndex = 0
        while characterIndex + 1 < characters.count {
            guard let byte = UInt8(String(characters[characterIndex...(characterIndex + 1)]), radix: 16) else {
                return hex
            }
            bytes.append(byte)
            characterIndex += 2
        }

        var output = characters
        var runStart = -1
        func closeRun(at end: Int) {
            defer { runStart = -1 }
            guard runStart >= 0, end - runStart >= 9 else { return }
            var containsLetter = false
            for index in runStart..<end {
                let byte = bytes[index]
                if (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) {
                    containsLetter = true
                    break
                }
            }
            guard containsLetter else { return }
            // Mask the complete serial-shaped run. Looking only at bytes after the first letter leaked
            // valid serials with a long numeric prefix and letters near the end (for example 123456789ABC).
            for maskedIndex in runStart..<end {
                output[maskedIndex * 2] = "•"
                output[maskedIndex * 2 + 1] = "•"
            }
        }

        for (index, byte) in bytes.enumerated() {
            let isAlphanumeric = (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
            if isAlphanumeric {
                if runStart < 0 { runStart = index }
            } else {
                closeRun(at: index)
            }
        }
        closeRun(at: bytes.count)
        return String(output)
    }

    nonisolated private static let hexRunRegex = try? NSRegularExpression(
        pattern: "[0-9a-fA-F]{16,}"
    )
    // BLE-10: compiled once instead of on every redacted line.
    nonisolated private static let macAddressRegex = try? NSRegularExpression(
        pattern: "([0-9A-Fa-f]{2}):[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:([0-9A-Fa-f]{2})"
    )
    nonisolated private static let strapSerialRegex = try? NSRegularExpression(
        pattern: "WHOOP (\\d[0-9A-Za-z]{5,})"
    )
    nonisolated private static let deviceUUIDRegex = try? NSRegularExpression(
        pattern: "(?![0-9A-Fa-f]{8}-(?:0000-1000-8000-00805f9b34fb|8d6d-82b8-614a-1c8cb0f8dcc6))[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
        options: [.caseInsensitive]
    )

    nonisolated private static func replacingMatches(of regex: NSRegularExpression?, in value: String,
                                                     with template: String) -> String {
        guard let regex else { return value }
        return regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value),
                                              withTemplate: template)
    }

    nonisolated static func redactPii(_ value: String) -> String {
        var output = value
        if let regex = Self.hexRunRegex {
            let source = output as NSString
            let matches = regex.matches(
                in: output,
                range: NSRange(location: 0, length: source.length)
            )
            if !matches.isEmpty {
                var rebuilt = ""
                var lastLocation = 0
                for match in matches {
                    rebuilt += source.substring(with: NSRange(
                        location: lastLocation,
                        length: match.range.location - lastLocation
                    ))
                    rebuilt += Self.redactHexDump(source.substring(with: match.range))
                    lastLocation = match.range.location + match.range.length
                }
                rebuilt += source.substring(from: lastLocation)
                output = rebuilt
            }
        }
        output = Self.replacingMatches(of: Self.macAddressRegex, in: output, with: "$1:••:••:••:••:$2")
        output = Self.replacingMatches(of: Self.strapSerialRegex, in: output, with: "WHOOP <serial>")
        output = Self.replacingMatches(of: Self.deviceUUIDRegex, in: output, with: "<device>")
        return output
    }

    /// Export path used by new async Copy/Save/Share surfaces. It waits for the serial durable-tail queue
    /// before returning the in-memory body, so the user action both includes and commits every accepted line.
    func exportableLogTextFlushing(extraHeaderLines: [String] = []) async -> String {
        await flushLogPersistence()
        return exportableLogText(extraHeaderLines: extraHeaderLines)
    }

    /// Synchronous compatibility body builder. It includes every in-memory line immediately and also starts
    /// a force-flush on the owned persistence queue, so existing copy/save callers do not block the UI or
    /// silently leave their newest messages waiting for the ordinary debounce.
    func exportableLogText(extraHeaderLines: [String] = []) -> String {
        publishPendingLog()   // BLE-10: include lines still waiting for the next batched publish
        Task { [weak self] in await self?.flushLogPersistence() }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var header = "NOOP strap log - iOS\nApp: \(version)\niOS: "
            + ProcessInfo.processInfo.operatingSystemVersionString + "\n"
        let diagnosticLines = IOSDiagnostics.capture().summaryLines()
        if !diagnosticLines.isEmpty { header += diagnosticLines.joined(separator: "\n") + "\n" }
        if !extraHeaderLines.isEmpty { header += extraHeaderLines.joined(separator: "\n") + "\n" }
        header += String(repeating: "-", count: 40) + "\n"
        return header + log.joined(separator: "\n")
    }
}
