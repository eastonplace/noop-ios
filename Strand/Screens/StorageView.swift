import SwiftUI
import StrandDesign
import WhoopStore

/// #590 — on-device storage diagnostics. iOS users saw "Documents & Data" balloon to ~19 GB after an
/// Apple Health import: the document picker's `asCopy:true` duplicate sat in `Documents/Inbox/` forever
/// and the WAL never truncated. AppModel now reclaims both automatically (Inbox cleanup on import +
/// launch, WAL truncate after each import); this screen makes the footprint VISIBLE and gives a manual
/// "Clean up now" escape hatch for anyone who already grew a backlog before the fix shipped.
///
/// Read-only otherwise: it shows the database size, the leftover Inbox size, and any stranded import
/// temp files. The button purges Inbox + temp and truncates the WAL — never touches live rows.
struct StorageView: View {
    @EnvironmentObject var model: AppModel

    @State private var report: AppModel.StorageReport?
    @State private var loading = true
    @State private var cleaning = false
    @State private var lastCleanedSummary: String?
    @State private var quarantinedJobs: [HistoricalQuarantinedJob] = []
    @State private var recoveryBusyReceiptId: String?
    @State private var pendingDiscard: HistoricalQuarantinedJob?
    @State private var recoveryMessage: String?

    var body: some View {
        ScreenScaffold(title: "Storage",
                       subtitle: "Where NOOP's on-device space is going, and a one-tap clean-up.") {
            SettingsScreenTemplate(sections: storageSections)
        }
        .task { await load() }
        .confirmationDialog(
            "Delete this quarantined archive?",
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete exact archive", role: .destructive) {
                guard let job = pendingDiscard else { return }
                pendingDiscard = nil
                Task { await discard(job) }
            }
            Button("Cancel", role: .cancel) { pendingDiscard = nil }
        } message: {
            Text("This permanently deletes the selected exact WHOOP history archive. Export it first if you may need it for decoder recovery. Your existing decoded health data and receipt remain.")
        }
    }

    private var storageSections: [SettingsSectionModel] {
        var rows: [SettingsRowModel] = []
        if loading && report == nil {
            rows.append(.custom(id: "measuring") {
                StatePill("Measuring…", tone: .accent, pulsing: true).padding(13)
            })
        } else if let report {
            rows.append(.custom(id: "breakdown") { breakdownCard(report).padding(13) })
            if report.historicalQuarantine.jobCount > 0 {
                rows.append(.custom(id: "historical-quarantine") {
                    historicalQuarantineCard(report.historicalQuarantine).padding(13)
                })
            }
            rows.append(.custom(id: "cleanup") { cleanUpCard(report).padding(13) })
        } else {
            rows.append(.custom(id: "unavailable") {
                DataPendingNote(title: "Storage unavailable",
                                message: "Couldn't read the local store right now. Try again in a moment.",
                                symbol: "internaldrive").padding(13)
            })
        }
        rows.append(.custom(id: "explanation") { explainerCard.padding(13) })
        return [.init(id: "storage", header: "On-device Storage", rows: rows)]
    }

    private func historicalQuarantineCard(_ summary: HistoricalQuarantineSummary) -> some View {
        PaperCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Label("WHOOP history recovery", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.statusWarning)
                Text("\(summary.jobCount) exact archive\(summary.jobCount == 1 ? "" : "s") could not be indexed. \(summary.jobCount == 1 ? "It remains protected and uses" : "They remain protected and use") \(Self.format(Int64(summary.protectedMappedByteCount))) of the mandatory mapped-data allowance.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let recoveryMessage {
                    Text(recoveryMessage)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }

                ForEach(quarantinedJobs) { job in
                    Divider().overlay(StrandPalette.hairline)
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        HStack {
                            Text(Self.recoveryErrorLabel(job.lastErrorCode))
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer(minLength: 8)
                            Text(Self.format(Int64(job.storedByteCount)))
                                .font(StrandFont.bodyNumber)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Text("Receipt \(job.receiptId.prefix(8)) · \(Self.format(Int64(job.archiveByteCount))) of exact frames retained")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)

                        HStack(spacing: NoopMetrics.space2) {
                            Button("Export") { Task { await export(job) } }
                                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                            Button("Retry") { Task { await retry(job) } }
                                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                            Button("Delete", role: .destructive) { pendingDiscard = job }
                                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                        }
                        .disabled(recoveryBusyReceiptId != nil)
                    }
                }
            }
        }
    }

    // MARK: - Cards

    private func breakdownCard(_ r: AppModel.StorageReport) -> some View {
        PaperCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("On-device footprint")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)

                row(icon: "cylinder.split.1x2",
                    label: "Health database",
                    bytes: r.db,
                    tint: StrandPalette.accent)
                Divider().overlay(StrandPalette.hairline)
                row(icon: "tray.full",
                    label: "Leftover import copies",
                    bytes: r.inbox,
                    tint: r.inbox > 0 ? StrandPalette.statusWarning : StrandPalette.textTertiary,
                    note: r.inbox > 0 ? "Reclaimable" : nil)
                Divider().overlay(StrandPalette.hairline)
                row(icon: "clock.arrow.circlepath",
                    label: "Import temp files",
                    bytes: r.importTemp,
                    tint: r.importTemp > 0 ? StrandPalette.statusWarning : StrandPalette.textTertiary,
                    note: r.importTemp > 0 ? "Reclaimable" : nil)
            }
        }
    }

    private func cleanUpCard(_ r: AppModel.StorageReport) -> some View {
        let reclaimable = r.inbox + r.importTemp
        return PaperCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("Clean up")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(reclaimable > 0
                     ? "There's about \(Self.format(reclaimable)) of leftover import scratch space to reclaim. This never removes your imported data."
                     : "Nothing to reclaim right now. NOOP already cleans up import scratch space automatically.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let lastCleanedSummary {
                    Text(lastCleanedSummary)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusPositive)
                }

                Button {
                    Task { await cleanUp() }
                } label: {
                    HStack(spacing: NoopMetrics.space2) {
                        if cleaning { ProgressView().controlSize(.small) }
                        Text(cleaning ? "Cleaning up…" : "Clean up now")
                    }
                }
                .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                .disabled(cleaning || reclaimable == 0)
                .accessibilityLabel("Clean up leftover import files")
            }
        }
    }

    private var explainerCard: some View {
        DataPendingNote(
            title: "Why does this grow?",
            message: "When you import an Apple Health or WHOOP export, iOS hands NOOP a private copy of the file. NOOP reads it, saves your data into the health database, then deletes the copy. Older builds didn't delete every copy. This screen reclaims any that were left behind.",
            symbol: "questionmark.circle")
    }

    // MARK: - Row

    private func row(icon: String, label: LocalizedStringKey, bytes: Int64?,
                     tint: Color, note: LocalizedStringKey? = nil) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: icon)
                .font(StrandFont.headline)
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let note {
                    Text(note)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer(minLength: 8)
            Text(bytes.map(Self.format) ?? "—")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    // MARK: - Data

    private func load() async {
        loading = true
        async let reportLoad = model.storageReport()
        async let jobsLoad = model.historicalQuarantinedJobs()
        let (r, jobs) = await (reportLoad, jobsLoad)
        report = r
        quarantinedJobs = jobs
        #if DEBUG
        if CommandLine.arguments.contains("--storage-recovery-qa") {
            let fixture = HistoricalQuarantinedJob(
                receiptId: "qa-receipt-7f31e9ab",
                rawBatchId: "qa-batch",
                deviceId: "qa-strap",
                lineage: "qa-lineage",
                cursorEpoch: 0,
                protectedMappedByteCount: 1_244,
                archiveByteCount: 42_680,
                storedByteCount: 12_840,
                lastErrorCode: "invalidArchive",
                updatedAt: Int(Date().timeIntervalSince1970)
            )
            quarantinedJobs = [fixture]
            report?.historicalQuarantine = HistoricalQuarantineSummary(
                jobCount: 1,
                protectedMappedByteCount: fixture.protectedMappedByteCount,
                archiveByteCount: fixture.archiveByteCount,
                storedByteCount: fixture.storedByteCount
            )
        }
        #endif
        loading = false
    }

    private func cleanUp() async {
        guard !cleaning else { return }
        cleaning = true
        let before = (report?.inbox ?? 0) + (report?.importTemp ?? 0)
        let r = await model.cleanUpStorage()
        let after = r.inbox + r.importTemp
        let freed = max(0, before - after)
        report = r
        lastCleanedSummary = freed > 0 ? String(localized: "Reclaimed \(Self.format(freed)).") : String(localized: "Already clean.")
        cleaning = false
    }

    private func export(_ job: HistoricalQuarantinedJob) async {
        guard recoveryBusyReceiptId == nil else { return }
        recoveryBusyReceiptId = job.receiptId
        defer { recoveryBusyReceiptId = nil }
        guard let archive = await model.historicalQuarantinedArchive(receiptId: job.receiptId),
              let metadata = try? JSONEncoder().encode(archive.job) else {
            recoveryMessage = String(localized: "The quarantined archive is no longer available.")
            return
        }
        let prefix = "noop-whoop-quarantine-\(job.receiptId.prefix(8))"
        let exported = FileExport.exportBundle(entries: [
            .init(name: "\(prefix).sqlite-zlib", data: archive.compressedArchive),
            .init(name: "\(prefix).json", data: metadata),
        ], suggestedName: "\(prefix).zip")
        recoveryMessage = exported == nil
            ? String(localized: "Archive export was cancelled or failed.")
            : String(localized: "Archive export opened.")
    }

    private func retry(_ job: HistoricalQuarantinedJob) async {
        guard recoveryBusyReceiptId == nil else { return }
        recoveryBusyReceiptId = job.receiptId
        let accepted = await model.retryHistoricalQuarantinedJob(receiptId: job.receiptId)
        recoveryMessage = accepted
            ? String(localized: "Retry scheduled with the current decoder.")
            : String(localized: "The job changed before it could be retried.")
        recoveryBusyReceiptId = nil
        await load()
    }

    private func discard(_ job: HistoricalQuarantinedJob) async {
        guard recoveryBusyReceiptId == nil else { return }
        recoveryBusyReceiptId = job.receiptId
        let discarded = await model.discardHistoricalQuarantinedArchive(receiptId: job.receiptId)
        recoveryMessage = discarded
            ? String(localized: "The selected exact archive was deleted. Its receipt remains.")
            : String(localized: "The archive changed before it could be deleted.")
        recoveryBusyReceiptId = nil
        await load()
    }

    /// Human byte size, decimal (matches iOS Settings' "Documents & Data" presentation).
    static func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: bytes)
    }

    private static func recoveryErrorLabel(_ code: String?) -> String {
        switch code {
        case "invalidArchive": "Archive integrity failed"
        case "invalidIndexes": "Archive index is malformed"
        case "missingRawBatch": "Archive is missing"
        case "invalidEnvelope": "Frame integrity failed"
        case "rawIntegrityFailure": "Archive byte integrity failed"
        case "unsupportedLayout": "Frame layout is unsupported"
        case .some: "Indexing failed"
        case .none: "Materialization failed"
        }
    }
}
