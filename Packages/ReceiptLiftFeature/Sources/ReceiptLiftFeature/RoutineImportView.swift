import SwiftUI
import UniformTypeIdentifiers
import StrandDesign

struct RoutineImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LiftStore
    @State private var picking = false
    @State private var exportingTemplate = false
    @State private var loading = false
    @State private var saving = false
    @State private var fileName = ""
    @State private var preview: LiftRoutineImportPreview?
    @State private var allowsCustomExercises = false
    @State private var failure: String?
    @State private var readTask: Task<Void, Never>?
    @State private var readRequestID: UUID?

    var body: some View {
        LiftSheetPage(title: "Import routines", onClose: close, content: {
            if loading {
                LiftMessage(isLoading: true, title: "Reading your spreadsheet…")
            } else if let preview {
                review(preview)
            } else {
                introduction
            }
            if let failure {
                FlatSectionSeparator()
                LiftFlatSection("Couldn’t import", systemImage: "exclamationmark.circle") {
                    Text(failure)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("routine.import.error")
                }
            }
        }, footer: {
            if let preview {
                VStack(spacing: NoopMetrics.space2) {
                    if needsCustomExerciseConsent(preview) {
                        Text("Turn on “\(LiftFormat.addCustomExercises(preview.newExercises.count))” to continue")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("routine.import.consentHint")
                    }
                    Button { confirm(preview) } label: {
                        if saving { ProgressView().tint(StrandPalette.textPrimary).liftPillLabel() }
                        else if preview.routines.count == 1 { Text("Import routine").liftPillLabel() }
                        else { Text("Import \(preview.routines.count) routines").liftPillLabel() }
                    }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .disabled(saving || needsCustomExerciseConsent(preview))
                    .accessibilityLabel("Confirm routine import")
                    .accessibilityIdentifier("routine.import.confirm")
                }
            } else {
                Button { picking = true } label: { Text("Choose spreadsheet").liftPillLabel() }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .disabled(loading)
                    .accessibilityIdentifier("routine.import.chooseFile")
            }
        })
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(saving)
        .fileImporter(isPresented: $picking, allowedContentTypes: Self.acceptedTypes, allowsMultipleSelection: false, onCompletion: selectedFile)
        .fileExporter(isPresented: $exportingTemplate, document: RoutineCSVTemplate(), contentType: .commaSeparatedText, defaultFilename: "NOOP-routines") { result in
            if case .failure(let error) = result, !Self.isCancellation(error) { failure = error.localizedDescription }
        }
        .onDisappear { cancelReading() }
    }

    private static var acceptedTypes: [UTType] {
        [.commaSeparatedText, UTType(filenameExtension: "xlsx") ?? .spreadsheet]
    }

    private var introduction: some View {
        LiftFlatSection("Plan in a spreadsheet", systemImage: "tablecells") {
            Text("Import a CSV or Excel file with one exercise per row. You’ll review everything before it’s saved.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            LiftTextButton("Save CSV template", systemImage: "square.and.arrow.down") {
                exportingTemplate = true
            }
            DisclosureGroup("File format") {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    columnRow("exercise", "required")
                    columnRow("routine", "groups rows into routines")
                    columnRow("sets, reps", "a range like 8-12 works")
                    columnRow("rest_sec, rpe", "rest and effort")
                    columnRow("weight_kg or weight_lb", "planned load")
                    columnRow("notes", "anything else")
                    Text("Up to 8 MB. In Excel, save calculated cells as values first.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, NoopMetrics.space2)
            }
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .tint(StrandPalette.textTertiary)
            .accessibilityIdentifier("routine.import.fileFormat")
        }
    }

    /// A column name in a plain monospaced weight, with what it holds underneath in the quieter colour.
    private func columnRow(_ key: String, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: key)
                .font(StrandFont.caption.monospaced().weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(detail)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func review(_ preview: LiftRoutineImportPreview) -> some View {
        LiftFlatSection("Review import", systemImage: "doc.text.magnifyingglass") {
            Text(fileName).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(2)
            Text(LiftFormat.facts([LiftFormat.routineCount(preview.routines.count), LiftFormat.exerciseCount(preview.exerciseCount)]))
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Text("Added alongside your existing routines.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LiftTextButton("Choose another file", systemImage: "folder") { picking = true }
                .disabled(saving)
        }
        if !preview.newExercises.isEmpty {
            FlatSectionSeparator()
            LiftFlatSection("New custom exercises", systemImage: "plus.circle") {
                Text("Not in your exercise library yet. Check the spelling before adding them.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    ForEach(preview.newExercises) { exercise in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exercise.name).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            let labels = [exercise.muscleGroup, exercise.equipment].filter { !$0.isEmpty }
                            if !labels.isEmpty {
                                Text(labels.joined(separator: " · ")).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                    }
                }
                Toggle(LiftFormat.addCustomExercises(preview.newExercises.count), isOn: $allowsCustomExercises)
                    .font(StrandFont.subhead)
                    .tint(StrandPalette.ink)
                    .disabled(saving)
                    .accessibilityIdentifier("routine.import.allowCustomExercises")
            }
        }
        ForEach(preview.routines) { routine in
            FlatSectionSeparator()
            LiftFlatSection(LocalizedStringKey(userText: routine.name), systemImage: "list.bullet.rectangle") {
                Text(routine.trainingMode.title).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                if !routine.notes.isEmpty {
                    Text(routine.notes).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                LazyVStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    ForEach(routine.exercisePlans ?? []) { plan in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: Self.title(for: plan, in: preview))
                                .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                            if let matched = Self.matchedName(for: plan, in: preview) {
                                Text("Matched to \(matched)")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            let facts = [Self.setsFact(plan.sets), Self.repsFact(plan.reps), plan.rest, plan.targetEffort].filter { !$0.isEmpty }
                            if !facts.isEmpty {
                                Text(facts.joined(separator: " · ")).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            }
                            if !plan.notes.isEmpty {
                                Text(plan.notes).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }.accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    /// The spreadsheet's own name for the row, or the library name when the sheet and library agree.
    private static func title(for plan: LiftRoutineExercisePlan, in preview: LiftRoutineImportPreview) -> String {
        preview.importedNames[plan.id] ?? preview.exercise(plan.exerciseID)?.name.liftDisplayName ?? String(localized: "Exercise")
    }

    /// The library exercise a differently written sheet name was matched to, as Lift shows it elsewhere.
    private static func matchedName(for plan: LiftRoutineExercisePlan, in preview: LiftRoutineImportPreview) -> String? {
        guard preview.importedNames[plan.id] != nil else { return nil }
        return preview.exercise(plan.exerciseID)?.name.liftDisplayName
    }

    /// "1 set" and "3 sets"; a range or other text such as "3-4" reads as plural.
    private static func setsFact(_ sets: String) -> String {
        guard !sets.isEmpty else { return "" }
        return Int(sets).map(LiftFormat.setCount) ?? String(localized: "\(sets) sets")
    }

    /// "1 rep" and "8 reps"; a range such as "8-12" reads as plural.
    private static func repsFact(_ reps: String) -> String {
        guard !reps.isEmpty else { return "" }
        return Int(reps).map(LiftFormat.repCount) ?? String(localized: "\(reps) reps")
    }

    private func needsCustomExerciseConsent(_ preview: LiftRoutineImportPreview) -> Bool {
        !preview.newExercises.isEmpty && !allowsCustomExercises
    }

    private func selectedFile(_ result: Result<[URL], Error>) {
        guard !saving else { return }
        switch result {
        case .failure(let error): if !Self.isCancellation(error) { failure = error.localizedDescription }
        case .success(let urls):
            guard let url = urls.first, let parser = store.routineImportParser else { return }
            let requestID = UUID()
            readRequestID = requestID
            readTask?.cancel()
            preview = nil
            failure = nil
            allowsCustomExercises = false
            loading = true
            fileName = url.lastPathComponent
            readTask = Task {
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let data = try LiftRoutineImportFile.read(url)
                    try Task.checkCancellation()
                    let draft = try parser(data)
                    try Task.checkCancellation()
                    return draft
                }
                do {
                    let draft = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: { worker.cancel() }
                    guard !Task.isCancelled, readRequestID == requestID else { return }
                    preview = try store.prepareRoutineImport(draft)
                } catch is CancellationError { }
                catch {
                    guard !Task.isCancelled, readRequestID == requestID else { return }
                    failure = error.localizedDescription
                }
                guard !Task.isCancelled, readRequestID == requestID else { return }
                loading = false
                readTask = nil
            }
        }
    }

    private func confirm(_ preview: LiftRoutineImportPreview) {
        guard !saving else { return }
        saving = true
        failure = nil
        Task {
            do {
                try await store.importReviewedRoutines(preview, allowNewExercises: allowsCustomExercises)
                dismiss()
            } catch { failure = error.localizedDescription }
            saving = false
        }
    }

    private func close() {
        guard !saving else { return }
        cancelReading()
        dismiss()
    }

    private func cancelReading() {
        readRequestID = nil
        readTask?.cancel()
        readTask = nil
    }

    private static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
    }
}

private struct RoutineCSVTemplate: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    init() { }
    init(configuration: ReadConfiguration) throws { }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(Self.csv.utf8))
    }
    private static let csv = """
    routine,exercise,sets,reps,rest_sec,rpe,weight_kg,notes
    Upper Day,Machine Chest Press,3,8-12,90,8,,Control the lowering
    Upper Day,Pull-Up,3,6-10,120,8,,

    """
}
