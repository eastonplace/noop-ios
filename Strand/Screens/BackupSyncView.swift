import SwiftUI
import StrandDesign

/// Backup & Sync (folder destination). The Apple mirror of the Android `BackupSyncScreen`: pick a
/// folder, turn on daily auto-backup (an on-launch catch-up), back up now, or restore from a snapshot
/// already in that folder. Snapshots are the existing `.noopbak` whole-DB format. Point the folder at
/// Google Drive / iCloud / Dropbox for off-device sync with no in-app cloud account.
struct BackupSyncView: View {
    @EnvironmentObject var model: AppModel

    @State private var auto = FolderBackup.autoEnabled
    @State private var folderLabel = FolderBackup.folderLabel()
    @State private var lastMs = FolderBackup.lastBackupMs
    @State private var busy = false

    // Successful operations are transient; failures remain visible with a truthful
    // retry route until the next attempt succeeds or replaces them.
    @State private var successToast: String?
    @State private var operationFailure: BackupOperationFailure?
    @State private var runningOperation: BackupOperationKind?

    // Restore-from-folder flow (must-fix #1 + #2): a sheet lists the folder's snapshots; choosing one
    // arms a destructive confirmation; only confirming runs the overwrite.
    @State private var showRestoreSheet = false
    @State private var snapshots: [FolderBackup.Snapshot] = []
    @State private var pendingRestore: FolderBackup.Snapshot?
    @State private var confirmRestore = false

    private var demoAuditMode: Bool {
        #if DEBUG
        AppleDemoSeeder.requested
        #else
        false
        #endif
    }

    init() {
        #if DEBUG
        if AppleDemoSeeder.requested {
            _folderLabel = State(initialValue: "Demo Backup Folder")
            _lastMs = State(initialValue: Int(Date().addingTimeInterval(-3_600).timeIntervalSince1970 * 1_000))
        }
        #endif
    }

    var body: some View {
        ScreenScaffold(
            title: "Backup & Sync",
            subtitle: "Keep your local data safe."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                SectionHeader("Backup location")
                folderCard
                SectionHeader("Auto backup")
                autoCard
                SectionHeader("Restore")
                restoreCard
                if let runningOperation {
                    PaperOperationFeedback(
                        title: runningOperation.runningTitle,
                        message: runningOperation.runningMessage,
                        phase: .running
                    )
                } else if let operationFailure {
                    PaperOperationFeedback(
                        title: operationFailure.title,
                        message: operationFailure.message,
                        phase: .failed,
                        actionTitle: operationFailure.actionTitle,
                        retry: { retry(operationFailure.retry) }
                    )
                }
                NoteCard("Backups are saved to your chosen local or cloud-synced folder. You're in control.",
                         style: .privacy)
            }
        }
        .paperToast(
            isPresented: Binding(
                get: { successToast != nil },
                set: { if !$0 { successToast = nil } }
            )
        ) {
            PaperToast(
                LocalizedStringKey(successToast!),
                announcement: successToast
            )
        }
        // Pick which snapshot to restore - the folder's own snapshots, newest first (must-fix #1).
        .sheet(isPresented: $showRestoreSheet) {
            RestorePickerSheet(snapshots: snapshots) { chosen in
                showRestoreSheet = false
                pendingRestore = chosen
                if chosen != nil { confirmRestore = true }
            }
        }
        // Explicit in-app destructive confirmation BEFORE any overwrite (must-fix #2).
        .alert("Restore this backup?", isPresented: $confirmRestore, presenting: pendingRestore) { snap in
            Button("Replace all data", role: .destructive) { runRestore(snap) }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: { snap in
            // A hand-named file with no resolved date (timeMs 0) confirms by NAME, not "1 Jan 1970".
            Text(snap.timeMs > 0
                ? "Replace all current data with the backup from \(absoluteTime(snap.timeMs))? This cannot be undone."
                : "Replace all current data with the backup \(snap.name)? This cannot be undone.")
        }
    }

    // MARK: - Cards

    private var folderCard: some View {
        PaperCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SettingsRow(icon: "folder.fill", title: "NOOP Backup",
                            subtitle: LocalizedStringKey(folderLabel ?? String(localized: "No folder chosen")),
                            showsChevron: false) {
                    Button(folderLabel == nil ? "Choose" : "Change") { chooseFolder() }
                        .buttonStyle(ChipButtonStyle())
                        .disabled(busy)
                }
                Text("Tip: choose a folder in iCloud Drive and your backups sync to all your Apple devices automatically, no account setup needed.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var autoCard: some View {
        PaperCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Daily auto-backup")
                            .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        Text("Backs up to your folder about once a day and keeps the latest \(FolderBackup.keepCount). On this platform it runs when you next open NOOP.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("Daily auto-backup", isOn: $auto)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.ink)
                        .disabled(folderLabel == nil)
                        .onChangeCompat(of: auto) { on in FolderBackup.autoEnabled = on }
                }
                Text(lastMs > 0 ? "Last backup: \(relativeTime(lastMs))" : "No backup yet.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                NoopButton(busy ? "Working…" : "Back up now",
                           systemImage: "icloud.and.arrow.up", kind: .primary, fullWidth: true) { backupNow() }
                    .disabled(folderLabel == nil || busy)
            }
        }
    }

    private var restoreCard: some View {
        PaperCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Restore")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text("Replace this device's data with one of the backups in your folder. This overwrites current data, so back up first if you're unsure.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                NoopButton("Restore from a backup…", systemImage: "arrow.uturn.backward", kind: .secondary) {
                    openRestorePicker()
                }
                .disabled(folderLabel == nil || busy)
            }
        }
    }

    // MARK: - Actions

    private func chooseFolder() {
        #if os(macOS)
        if FolderBackup.pickFolder() != nil { folderLabel = FolderBackup.folderLabel() }
        #else
        // #1000a: on iOS the folder picker has reportedly refused to enable its Select button, leaving
        // the user with only Cancel and NOOP silently doing nothing. We can't tell a deliberate Cancel
        // apart from that dead-button dead-end (both come back nil), so when no folder arrives we show
        // the screen's normal result alert with a concrete workaround instead of staying silent. Mildly
        // chatty on a genuine Cancel; honest and actionable when the picker is actually broken.
        Task {
            if await FolderBackup.pickFolder() != nil {
                folderLabel = FolderBackup.folderLabel()
                operationFailure = nil
            } else {
                operationFailure = BackupOperationFailure(
                    title: String(localized: "No folder selected"),
                    message: String(localized: "NOOP didn't get a folder back from the picker. If the Select button won't enable, try creating a fresh folder in Files (under On My iPhone or iCloud Drive) and choosing that instead."),
                    retry: .chooseFolder,
                    actionTitle: "Choose again"
                )
            }
        }
        #endif
    }

    private func backupNow() {
        if demoAuditMode {
            presentSuccess(
                title: String(localized: "Backed up"),
                message: String(localized: "Saved a synthetic audit backup. No file was written.")
            )
            return
        }
        runningOperation = .backup
        operationFailure = nil
        busy = true
        Task {
            let ok = await FolderBackup.backupNow(checkpoint: { await model.repo.checkpointForBackup() })
            await MainActor.run {
                lastMs = FolderBackup.lastBackupMs
                busy = false
                runningOperation = nil
                if ok {
                    presentSuccess(
                        title: String(localized: "Backed up"),
                        message: String(localized: "Saved a backup to your folder.")
                    )
                } else {
                    operationFailure = BackupOperationFailure(
                        title: String(localized: "Backup problem"),
                        message: String(localized: "Backup failed - re-pick the folder and try again."),
                        retry: .backup
                    )
                }
            }
        }
    }

    private func openRestorePicker() {
        snapshots = demoAuditMode
            ? [FolderBackup.Snapshot(name: "noop-audit-demo.noopbak",
                                     timeMs: Int(Date().addingTimeInterval(-3_600).timeIntervalSince1970 * 1_000))]
            : FolderBackup.listSnapshots()
        if snapshots.isEmpty {
            operationFailure = BackupOperationFailure(
                title: String(localized: "No backups found"),
                message: String(localized: "There are no NOOP backups in your folder yet. Use Back up now first."),
                retry: .backup,
                actionTitle: "Back up now"
            )
        } else {
            operationFailure = nil
            showRestoreSheet = true
        }
    }

    private func runRestore(_ snap: FolderBackup.Snapshot) {
        pendingRestore = nil
        runningOperation = .restore
        operationFailure = nil
        busy = true
        Task {
            let result = await FolderBackup.restore(
                snapshotNamed: snap.name,
                lifecycle: model.backupRestoreLifecycle)
            await MainActor.run {
                busy = false
                runningOperation = nil
                switch result {
                case .imported:
                    presentSuccess(
                        title: String(localized: "Restored"),
                        message: String(localized: "The restored database is open and ready to use.")
                    )
                case .failure(let m):
                    operationFailure = BackupOperationFailure(
                        title: String(localized: "Restore problem"),
                        message: m,
                        retry: .restore(snap)
                    )
                case .cancelled, .exported:
                    operationFailure = BackupOperationFailure(
                        title: String(localized: "Restore problem"),
                        message: String(localized: "Couldn't restore that backup."),
                        retry: .restore(snap)
                    )
                }
            }
        }
    }

    private func presentSuccess(title: String, message: String) {
        operationFailure = nil
        successToast = "\(title). \(message)"
    }

    private func retry(_ action: BackupRetry) {
        switch action {
        case .chooseFolder: chooseFolder()
        case .backup: backupNow()
        case .restore(let snapshot): runRestore(snapshot)
        }
    }

    // MARK: - Formatting

    private func relativeTime(_ ms: Int) -> String {
        let f = RelativeDateTimeFormatter()
        return f.localizedString(for: Date(timeIntervalSince1970: Double(ms) / 1000.0), relativeTo: Date())
    }

    private func absoluteTime(_ ms: Int) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    }
}

private enum BackupOperationKind {
    case backup
    case restore

    var runningTitle: String {
        switch self {
        case .backup: return String(localized: "Backing up")
        case .restore: return String(localized: "Restoring")
        }
    }

    var runningMessage: String {
        switch self {
        case .backup: return String(localized: "Saving a backup to your folder.")
        case .restore: return String(localized: "Replacing local data with the selected backup.")
        }
    }
}

private enum BackupRetry {
    case chooseFolder
    case backup
    case restore(FolderBackup.Snapshot)
}

private struct BackupOperationFailure {
    let title: String
    let message: String
    let retry: BackupRetry
    var actionTitle: LocalizedStringKey = "Retry"
}

/// The snapshot chooser shown before a restore (must-fix #1: pick from the folder, newest first).
/// Reports the chosen snapshot (or nil if dismissed) back to the host, which then arms the destructive
/// confirmation.
private struct RestorePickerSheet: View {
    let snapshots: [FolderBackup.Snapshot]
    let onChoose: (FolderBackup.Snapshot?) -> Void

    private var displayedSnapshots: [FolderBackup.Snapshot] {
        #if DEBUG
        if snapshots.isEmpty, AppleDemoSeeder.requested {
            return [FolderBackup.Snapshot(name: "noop-audit-demo.noopbak",
                                          timeMs: Int(Date().addingTimeInterval(-3_600).timeIntervalSince1970 * 1_000))]
        }
        #endif
        return snapshots
    }

    var body: some View {
        NavigationStack {
            List(displayedSnapshots) { snap in
                Button { onChoose(snap) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            // A hand-named file whose date lookup failed has timeMs 0; show its name as the
                            // primary line rather than "1 Jan 1970". The filename subtitle then only repeats
                            // when we DO have a real date to head the row.
                            Text(primaryLabel(snap))
                                .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                            if snap.timeMs > 0 {
                                Text(snap.name)
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .accessibilityLabel(accessibilityLabel(snap))
            }
            .navigationTitle("Choose a backup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onChoose(nil) }
                }
            }
        }
    }

    /// The row's headline: a friendly date when we resolved one, else the filename (never the epoch date).
    private func primaryLabel(_ snap: FolderBackup.Snapshot) -> String {
        snap.timeMs > 0 ? absoluteTime(snap.timeMs) : snap.name
    }

    /// VoiceOver label: reads the resolved date when we have one, else the filename (no epoch date).
    private func accessibilityLabel(_ snap: FolderBackup.Snapshot) -> String {
        snap.timeMs > 0 ? String(localized: "Restore backup from \(absoluteTime(snap.timeMs))")
                        : String(localized: "Restore backup \(snap.name)")
    }

    private func absoluteTime(_ ms: Int) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    }
}
