#if os(iOS)
import SwiftUI
import StrandDesign

struct LocalCoachDiagnosticsView: View {
    @EnvironmentObject private var coach: LocalCoachEngine
    @State private var checks: [LocalCoachCheck] = []
    @State private var runningChecks = false
    @State private var probeTask: Task<Void, Never>?
    @State private var probeID: UUID?
    @State private var title = ""
    @State private var steps = ""
    @State private var expected = ""
    @State private var actual = ""
    @State private var report: String?

    var body: some View {
        Form {
            Section {
                if coach.isPreview { LocalCoachFixtureLabel() }
                Label("Coach lab", systemImage: "wrench.and.screwdriver")
                    .font(.system(size: 27, weight: .medium, design: .rounded))
                Text("Check the app, describe a bug and share a report you have reviewed.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                Button {
                    runningChecks = true
                    Task {
                        checks = await LocalCoachDiagnostics.runLocalChecks(preview: coach.isPreview)
                        runningChecks = false
                    }
                } label: {
                    HStack { Label("Run local checks", systemImage: "checkmark.circle"); Spacer(); if runningChecks { ProgressView() } }
                }.disabled(runningChecks || probeTask != nil)
                    .accessibilityIdentifier("coach.runChecks")
                Button(probeTask == nil ? "Test Apple Intelligence" : "Stop model test") {
                    if probeTask != nil { cancelProbe(); return }
                    let token = UUID()
                    probeID = token
                    probeTask = Task {
                        let check: LocalCoachCheck
                        do { check = try await LocalCoachDiagnostics.testModel() }
                        catch is CancellationError { return }
                        catch {
                            check = .init(id: "generation", title: "Local model generation", status: .failed,
                                          detail: "The synthetic model request returned an error. No personal records were supplied.")
                        }
                        guard probeID == token, !Task.isCancelled else { return }
                        checks.removeAll { $0.id == "generation" }
                        checks.append(check)
                        probeTask = nil
                        probeID = nil
                    }
                }.disabled(coach.isPreview || !coach.preferences.enabled || runningChecks || coach.isResponding)
                    .accessibilityIdentifier("coach.testModel")
                ForEach(checks) { check in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(check.title).font(.subheadline.weight(.medium))
                            Spacer()
                            Text(check.status.rawValue).font(.caption.weight(.semibold))
                                .foregroundStyle(check.status == .passed ? StrandPalette.accent : StrandPalette.warning)
                        }
                        Text(check.detail).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            } header: { Text("Test on this device") } footer: {
                Text("Local checks use a disposable test record. The model test uses a synthetic prompt. These checks do not verify the whole app or coaching advice.")
            }
            Section("Report a problem") {
                TextField("Short title", text: $title)
                TextField("Steps to reproduce", text: $steps, axis: .vertical).lineLimit(2...6)
                TextField("What should happen?", text: $expected, axis: .vertical).lineLimit(2...4)
                TextField("What happened instead?", text: $actual, axis: .vertical).lineLimit(2...6)
                Button("Preview report") {
                    report = LocalCoachDiagnostics.report(coach: coach, title: title, steps: steps,
                                                          expected: expected, actual: actual, checks: checks)
                }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("coach.previewReport")
            }
            Section {
                NavigationLink("Open full Test Centre") { TestCentreView() }
            } footer: {
                Text("The Test Centre has strap diagnostics and reviewed log exports. Reports here omit conversations and health data automatically.")
            }
            #if DEBUG
            Section("Interface checks with sample data") {
                ForEach(LocalCoachScreen.allCases) { screen in
                    NavigationLink(screen.title) { LocalCoachPreviewHost(screen: screen.rawValue) }
                }
            }
            #endif
        }
        .navigationTitle("Testing & reports").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            NavigationStack {
                ScrollView { Text(report ?? "").font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding() }
                    .navigationTitle("Review report").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Close") { report = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            ShareLink(item: report ?? "") { Label("Share report", systemImage: "square.and.arrow.up") }
                        }
                    }
            }.preferredColorScheme(.dark)
        }
        .onDisappear { cancelProbe() }
        .onChange(of: coach.preferences.enabled) { _, _ in cancelProbe() }
        .tint(StrandPalette.accent)
    }

    private func cancelProbe() {
        probeID = nil
        probeTask?.cancel()
        probeTask = nil
    }
}
#if DEBUG
/// Launch-only QA route for checking a signed phone build without touching personal records.
struct LocalCoachDeviceCheckView: View {
    @State private var checks: [LocalCoachCheck] = []
    @State private var complete = false
    @State private var receiptError: String?

    var body: some View {
        Form {
            Section {
                Text("Checks use synthetic data. No health records or conversations enter the model.")
                    .font(.subheadline)
                if !complete { ProgressView("Checking this device…") }
            }
            ForEach(checks) { check in
                Section(check.title) {
                    Text(check.status.rawValue).foregroundStyle(check.status == .passed ? StrandPalette.accent : StrandPalette.warning)
                    Text(check.detail).font(.footnote)
                }
            }
            if let receiptError { Text(receiptError).foregroundStyle(StrandPalette.warning) }
        }
        .navigationTitle("Device check")
        .task {
            checks = await LocalCoachDiagnostics.runLocalChecks(preview: false)
            do { checks.append(try await LocalCoachDiagnostics.testModel()) }
            catch is CancellationError { return }
            catch { checks.append(.init(id: "generation", title: "Local model generation", status: .failed,
                                        detail: "The synthetic model request returned an error. No personal records were supplied.")) }
            guard !Task.isCancelled else { return }
            complete = true
            do {
                let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
                let payload: [String: Any] = [
                    "checkedAt": ISO8601DateFormatter().string(from: Date()),
                    "checks": checks.map { ["id": $0.id, "title": $0.title, "status": $0.status.rawValue, "detail": $0.detail] }
                ]
                try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                    .write(to: cache.appendingPathComponent("noop-coach-device-check.json"), options: [.atomic, .completeFileProtection])
            } catch { receiptError = "The checks finished, but the local receipt could not be saved." }
        }
    }
}
#endif
#endif
