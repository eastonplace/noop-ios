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
                Button { confirm(preview) } label: {
                    if saving { ProgressView().tint(StrandPalette.textPrimary).liftPillLabel() }
                    else if preview.routines.count == 1 { Text("Import routine").liftPillLabel() }
                    else { Text("Import \(preview.routines.count) routines").liftPillLabel() }
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(saving || (!preview.newExercises.isEmpty && !allowsCustomExercises))
                .accessibilityLabel("Confirm routine import")
                .accessibilityIdentifier("routine.import.confirm")
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
            Text("Import a CSV or Excel (.xlsx) file with one exercise per row. Review the routines and their prescriptions before saving.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("An exercise column is required. Optional columns include routine, sets, reps, rest_sec, rpe, weight_kg or weight_lb, and notes. Rep ranges such as 8-12 are supported. Blank prescriptions stay empty.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Files can be up to 8 MB. In Excel, paste calculated cells as values before exporting. Use an explicit unit for planned loads; a plain weight column uses kilograms.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            ChipRow {
                WidgetChipButton(title: "Save CSV template", systemImage: "square.and.arrow.down", accessibilityLabel: "Save CSV template") {
                    exportingTemplate = true
                }
            }
        }
    }

    @ViewBuilder private func review(_ preview: LiftRoutineImportPreview) -> some View {
        LiftFlatSection("Review import", systemImage: "doc.text.magnifyingglass") {
            Text(fileName).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(2)
            Text("\(preview.routines.count) routines · \(preview.exerciseCount) exercises")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Text("The routines below will be added to your library. Your existing routines and scheduled workouts are kept.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ChipRow {
                WidgetChipButton(title: "Choose another file", systemImage: "folder", accessibilityLabel: "Choose another file") {
                    picking = true
                }.disabled(saving)
            }
        }
        if !preview.warnings.isEmpty {
            FlatSectionSeparator()
            LiftFlatSection("Import notes", systemImage: "info.circle") {
                ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if !preview.newExercises.isEmpty {
            FlatSectionSeparator()
            LiftFlatSection("New custom exercises", systemImage: "plus.circle") {
                Text("These names have no exact match in your exercise library. Check their spelling and labels before adding them.")
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
                Toggle("Add these \(preview.newExercises.count) custom exercises", isOn: $allowsCustomExercises)
                    .font(StrandFont.subhead)
                    .tint(StrandPalette.accent)
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
                            Text(preview.exercise(plan.exerciseID)?.name ?? "Exercise")
                                .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                            let facts = [plan.sets.isEmpty ? "" : "\(plan.sets) sets", plan.reps.isEmpty ? "" : "\(plan.reps) reps", plan.rest, plan.targetEffort].filter { !$0.isEmpty }
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
