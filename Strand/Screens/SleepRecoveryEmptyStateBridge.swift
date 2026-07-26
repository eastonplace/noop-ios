import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// Local routing seam for the app's shared empty-state component. The one Sleep
/// placeholder becomes actionable; every other call delegates to StrandDesign unchanged.
@ViewBuilder
func ComingSoon(what: String) -> some View {
    if MissedSleepRecoveryRouting.shouldReplaceEmptyState(what) {
        MissedSleepRecoveryBridge()
    } else {
        StrandDesign.ComingSoon(what: what)
    }
}

enum MissedSleepRecoveryRouting {
    static func shouldReplaceEmptyState(_ message: String) -> Bool {
        message.hasPrefix("No nights here yet.")
    }
}

private struct MissedSleepRecoveryBridge: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var intelligence: IntelligenceEngine

    @State private var isRetrying = false
    @State private var editorSeed: MissedSleepWindowSeed?
    @State private var notice: SleepRecoveryNotice?

    var body: some View {
        MissedSleepRecoveryCard(
            isRetrying: isRetrying,
            onRetry: { Task { await retryDetection() } },
            onSetWindow: { editorSeed = .lastNight() })
            .sheet(item: $editorSeed) { seed in
                MissedSleepWindowEditor(seed: seed) { startTs, endTs in
                    let result = await repo.recoverMissedSleep(
                        startTs: startTs,
                        endTs: endTs)
                    let confidence = result.confidence.map {
                        " Detection confidence: \(Int(($0 * 100).rounded()))%."
                    } ?? ""
                    notice = SleepRecoveryNotice(
                        title: result.title,
                        message: result.message + confidence)
                    return result.savedSession
                }
            }
            .alert(item: $notice) { value in
                Alert(
                    title: Text(value.title),
                    message: Text(value.message),
                    dismissButton: .default(Text("OK")))
            }
    }

    @MainActor
    private func retryDetection() async {
        guard !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }

        let seed = MissedSleepWindowSeed.lastNight()
        let requestedStart = Int(seed.start.timeIntervalSince1970)
        let requestedEnd = Int(seed.end.timeIntervalSince1970)
        await intelligence.analyzeRecent(maxDays: 3, force: true)
        _ = await repo.refresh(.recentDashboard(days: 120))

        let sessions = await repo.allSleepSessions()
        let recovered = sessions
            .filter { $0.effectiveStartTs < requestedEnd && requestedStart < $0.endTs }
            .max { lhs, rhs in
                (lhs.endTs - lhs.effectiveStartTs) < (rhs.endTs - rhs.effectiveStartTs)
            }
        await repo.recordSleepDetectionRetry(
            requestedStartTs: requestedStart,
            requestedEndTs: requestedEnd,
            recoveredSession: recovered)

        if recovered != nil {
            notice = SleepRecoveryNotice(
                title: "Sleep detected",
                message: "NOOP found the night on a fresh pass and regenerated the day from the recorded data.")
        } else {
            notice = SleepRecoveryNotice(
                title: "Still not enough confidence",
                message: "Automatic detection still could not defend a sleep session. Set the sleep window to narrow the search without inventing stages or vitals.")
        }
    }
}

private struct MissedSleepWindowEditor: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (_ startTs: Int, _ endTs: Int) async -> Bool
    @State private var start: Date
    @State private var end: Date
    @State private var isSaving = false
    @State private var validationMessage: String?

    init(
        seed: MissedSleepWindowSeed,
        onSave: @escaping (_ startTs: Int, _ endTs: Int) async -> Bool
    ) {
        self.onSave = onSave
        _start = State(initialValue: seed.start)
        _end = State(initialValue: seed.end)
    }

    private var duration: TimeInterval { end.timeIntervalSince(start) }
    private var durationText: String {
        let minutes = max(0, Int(duration / 60))
        return "\(minutes / 60) hr \(minutes % 60) min window"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("When were you in bed?")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("These times only bound the review. NOOP will inspect the physiological data inside the window and keep uncertain signals unknown.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 0) {
                        dateRow(
                            title: "In bed",
                            icon: "moon.fill",
                            selection: $start,
                            range: ...Date())
                        Divider().padding(.leading, 48)
                        dateRow(
                            title: "Woke up",
                            icon: "sun.max.fill",
                            selection: $end,
                            range: ...Date())
                    }
                    .padding(.horizontal, 16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    HStack(spacing: 10) {
                        Image(systemName: isValidWindow ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(isValidWindow ? .green : .orange)
                        Text(validationMessage ?? durationText)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)

                    VStack(alignment: .leading, spacing: 10) {
                        Label("What happens next", systemImage: "waveform.path.ecg.rectangle")
                            .font(.headline)
                        recoveryExplanation(
                            number: "1",
                            text: "Read HR, HRV, respiration, and motion only inside this window.")
                        recoveryExplanation(
                            number: "2",
                            text: "Rebuild sleep stages only when the sensor evidence supports them.")
                        recoveryExplanation(
                            number: "3",
                            text: "Regenerate Rest and Charge and preserve the correction through later syncs.")
                    }
                    .padding(16)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding(20)
            }
            .navigationTitle("Recover sleep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Review data").fontWeight(.semibold)
                        }
                    }
                    .disabled(isSaving || !isValidWindow)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onChange(of: start) { _, _ in validate() }
            .onChange(of: end) { _, _ in validate() }
        }
    }

    private var isValidWindow: Bool {
        duration >= Double(SleepWindowRecovery.minWindowSeconds)
            && duration <= Double(SleepWindowRecovery.maxWindowSeconds)
            && end <= Date()
    }

    @ViewBuilder
    private func dateRow(
        title: String,
        icon: String,
        selection: Binding<Date>,
        range: PartialRangeThrough<Date>
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.blue)
            Text(title)
                .font(.headline)
            Spacer()
            DatePicker(
                title,
                selection: selection,
                in: range,
                displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
        }
        .padding(.vertical, 14)
    }

    private func recoveryExplanation(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.blue, in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func validate() {
        if end <= start {
            validationMessage = "Wake time must be after bedtime."
        } else if duration < Double(SleepWindowRecovery.minWindowSeconds) {
            validationMessage = "Choose at least a 30-minute window."
        } else if duration > Double(SleepWindowRecovery.maxWindowSeconds) {
            validationMessage = "Choose a window no longer than 16 hours."
        } else if end > Date() {
            validationMessage = "Wake time cannot be in the future."
        } else {
            validationMessage = nil
        }
    }

    @MainActor
    private func save() async {
        validate()
        guard isValidWindow, !isSaving else { return }
        isSaving = true
        let saved = await onSave(
            Int(start.timeIntervalSince1970),
            Int(end.timeIntervalSince1970))
        isSaving = false
        if saved { dismiss() }
    }
}
