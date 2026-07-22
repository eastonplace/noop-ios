import Foundation

extension LiveState {
    public func append(log line: String, domain: TestDomain? = nil) {
        let tagged = domain.map { "[\($0.id)] " + line } ?? line
        let redacted = Self.redactPii(tagged)
        log.append(redacted)
        if log.count > Self.maxLogLines {
            log.removeFirst(log.count - Self.maxLogLines)
        }
        logTailPersistence.append(redacted)

        if line.contains("session persisted"),
            let rows = ConnectionReadout.drainedRowsFromSummary(line)
        {
            TestCentre.noteDrainedRows(rows)
        }
    }

    public func taggedTail(domain: TestDomain) -> [String] {
        let prefix = "[\(domain.id)] "
        return log.filter { $0.hasPrefix(prefix) }
    }

    private static let tailKey = "strapLog.tail"
    static let tailLimit = 2_000

    nonisolated static func persistTail(_ lines: [String]) {
        let tail = lines.count > tailLimit ? Array(lines.suffix(tailLimit)) : lines
        UserDefaults.standard.set(tail, forKey: tailKey)
    }

    public func flushLogPersistence() async {
        await logTailPersistence.flush()
    }

    public func clearLog() async {
        log.removeAll(keepingCapacity: true)
        await logTailPersistence.clear()
    }

    nonisolated public static func persistedLogTail() -> [String] {
        (UserDefaults.standard.array(forKey: tailKey) as? [String]) ?? []
    }

    nonisolated public static func scheduledExportText(extraHeaderLines: [String] = []) -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var header = "NOOP strap log (scheduled export) — iOS\nApp: \(version)\niOS: "
            + ProcessInfo.processInfo.operatingSystemVersionString + "\n"
        if !extraHeaderLines.isEmpty { header += extraHeaderLines.joined(separator: "\n") + "\n" }
        header += String(repeating: "-", count: 40) + "\n"
        return header + persistedLogTail().joined(separator: "\n")
    }

    nonisolated static func redactPii(_ value: String) -> String {
        var output = value
        output = output.replacingOccurrences(
            of: "([0-9A-Fa-f]{2}):[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:([0-9A-Fa-f]{2})",
            with: "$1:••:••:••:••:$2",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: "WHOOP (\\d[0-9A-Za-z]{5,})",
            with: "WHOOP <serial>",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: "(?![0-9A-Fa-f]{8}-(?:0000-1000-8000-00805f9b34fb|8d6d-82b8-614a-1c8cb0f8dcc6))[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
            with: "<device>",
            options: [.regularExpression, .caseInsensitive]
        )
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
