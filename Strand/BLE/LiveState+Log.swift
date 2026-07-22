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
        #if os(iOS)
        let osName = "iOS"
        #else
        let osName = "macOS"
        #endif
        var header = "NOOP strap log (scheduled export) — \(osName)\nApp: \(version)\n\(osName): "
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

    func exportableLogTextFlushing(extraHeaderLines: [String] = []) async -> String {
        await flushLogPersistence()
        return exportableLogText(extraHeaderLines: extraHeaderLines)
    }

    func exportableLogText(extraHeaderLines: [String] = []) -> String {
        // Existing synchronous callers still receive every in-memory line immediately. Start a background
        // force-flush so Copy/Save also commits the durable tail without blocking the UI.
        Task { await flushLogPersistence() }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        #if os(iOS)
        let osName = "iOS"
        #else
        let osName = "macOS"
        #endif
        var header = "NOOP strap log - \(osName)\nApp: \(version)\n\(osName): "
            + ProcessInfo.processInfo.operatingSystemVersionString + "\n"
        #if os(iOS)
        let diagnosticLines = IOSDiagnostics.capture().summaryLines()
        if !diagnosticLines.isEmpty { header += diagnosticLines.joined(separator: "\n") + "\n" }
        #endif
        if !extraHeaderLines.isEmpty { header += extraHeaderLines.joined(separator: "\n") + "\n" }
        header += String(repeating: "-", count: 40) + "\n"
        return header + log.joined(separator: "\n")
    }
}
