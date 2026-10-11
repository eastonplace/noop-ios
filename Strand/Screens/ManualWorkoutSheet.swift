import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Manual workout sheet
//
// Add a workout you tracked elsewhere, or edit one you already logged. Five inputs — sport,
// start, duration, average HR, calories — validated by WorkoutSource.buildManualRow (the same
// honest-row rules the engine uses). The sport is chosen from the catalogue like the start sheet's (recent chips, and
// every activity in a sheet of its own); "Other" opens a field for an activity the catalogue does not list. On save the caller persists it under the strap source via
// Repository.saveManualWorkout. Captured-but-unexposed fields (maxHr / strain / zones) on an edited
// row are carried over by WorkoutSource.preservingCaptured so editing a live-tracked session's
// sport/duration never silently wipes its real strain.
//
// `editing` is non-nil when editing an existing row (its values pre-fill the form and it is passed
// as `replacing:` so a changed natural key deletes the old row). nil = a fresh add.

struct ManualWorkoutSheet: View {
    /// The row being edited, or nil for a new manual workout.
    let editing: WorkoutRow?
    /// Called with the validated row (and the original, when editing) once the user taps Save.
    let onSave: (_ row: WorkoutRow, _ replacing: WorkoutRow?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The catalogue sport chosen; empty until one is. "Other" may carry a name of its own (`customSport`).
    @State private var chosenSport: String
    @State private var customSport: String
    @State private var start: Date
    @State private var durationMin: Int
    @State private var avgHrText: String
    @State private var kcalText: String
    /// The sports used lately, offered under the Sport field as one-tap chips.
    @State private var recentSports: [String] = RecentSportsPrefs.recent()
    @State private var showsAllActivities = false
    /// True once Add has been tapped on a form that could not be saved. Until then, what is missing is a hint, not a fault.
    @State private var attemptedAdd = false

    /// Focus for the text fields so the keyboard Done button can resign them — the decimal pad has no return key.
    /// iOS-only effect; the enum keeps both platforms compiling.
    private enum FormField: Hashable { case customSport, avgHr, calories }
    @FocusState private var focusedField: FormField?

    /// The sport as it is saved.
    private var sport: String { ManualWorkoutSport.sport(chosen: chosenSport, custom: customSport) }

    init(editing: WorkoutRow? = nil,
         onSave: @escaping (_ row: WorkoutRow, _ replacing: WorkoutRow?) -> Void) {
        self.editing = editing
        self.onSave = onSave
        // Pre-fill from the edited row (display "detected" as "Activity" so a re-label starts clean).
        let e = editing
        // Seeds the LOCALE-STABLE editable form, not the localized display: the field's content is
        // persisted verbatim on save, and a translated word would split cross-source dedup per language.
        let choice = ManualWorkoutSport.choice(for: e.map { WorkoutSource.editableSport($0.sport) })
        _chosenSport = State(initialValue: choice.chosen)
        _customSport = State(initialValue: choice.custom)
        _start = State(initialValue: e.map { Date(timeIntervalSince1970: TimeInterval($0.startTs)) } ?? Date())
        _durationMin = State(initialValue: e.map { max(1, Int((($0.durationS ?? Double($0.endTs - $0.startTs)) / 60).rounded())) } ?? 45)
        _avgHrText = State(initialValue: e?.avgHr.map(String.init) ?? "")
        _kcalText = State(initialValue: e?.energyKcal.map { String(Int($0.rounded())) } ?? "")
    }

    var body: some View {
        // The form scrolls and the footer stays pinned above the keyboard. The sheet opens at full height: at the medium
        // one the last fields sat clipped under the footer.
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.space5) {
                header
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    field(String(localized: "Sport")) {
                        sportPicker
                    }
                    field(String(localized: "Start")) {
                        DatePicker(selection: $start, in: ...Date(), displayedComponents: [.date, .hourAndMinute]) {
                            Text("Start date and time")
                        }
                        .labelsHidden()
                    }
                    field(String(localized: "Duration")) {
                        HStack(spacing: 12) {
                            Stepper(value: $durationMin, in: 1...(24 * 60), step: 5) {
                                Text(durationLabel)
                                    .font(StrandFont.number(16))
                                    .foregroundStyle(StrandPalette.effortBright)
                            }
                            // The label names what the stepper changes; the value is what it is now, spoken after each step.
                            .accessibilityLabel("Duration")
                            .accessibilityValue(WorkoutFormat.spokenDuration(Double(durationMin) * 60))
                        }
                    }
                    numberFields
                }
                if avgHrEditedNote { noteRow(String(localized: "Avg HR is shown as typed. The HR graph, zones and Strain stay from the recorded session.")) }
                // At accessibility text sizes a pinned footer would take half the sheet, so it follows the form.
                if typeSize.isAccessibilitySize { footerWithNote }
            }
            .padding(.horizontal, NoopMetrics.space6)
            .padding(.top, NoopMetrics.space6)
            .padding(.bottom, NoopMetrics.space4)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // What is wrong with the form stays beside the button it explains, however far the form is scrolled.
            if !typeSize.isAccessibilitySize {
                footerWithNote
                    .padding(.horizontal, NoopMetrics.space6)
                    .padding(.top, NoopMetrics.space2)
                    .padding(.bottom, NoopMetrics.space3)
                    .background(StrandPalette.surfaceOverlay)
            }
        }
        // A fixed 420pt is right for the free-floating macOS sheet, but on iPhone it's wider than
        // the screen, so the Avg HR/Calories row, the Start DatePicker and the footer ran off the
        // right edge (#185, same fix as WhatsNewView/ScoringGuideView). iOS fills the presented
        // sheet's width and sizes to content height instead.
        #if os(macOS)
        .frame(width: 420, height: 560)
        #else
        .frame(maxWidth: .infinity)
        // Full height always; the grabber also gives the top dismiss affordance the sheet otherwise lacks (only a
        // bottom Cancel).
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceOverlay)
        // Lets the user dismiss the decimal pad (which has no return key) and reach Cancel/Add. No-op on macOS.
        .keyboardDoneToolbar($focusedField)
    }

    // MARK: - Sport picker
    //
    // The sports used lately as chips (with the current choice among them), a row that opens every activity in a sheet of
    // its own, and, once "Other" is chosen, a field for the activity's own name. That field is the free-text path (#519):
    // an activity the catalogue does not list still saves exactly as typed.

    private var chipSports: [String] { ManualWorkoutSport.chips(recents: recentSports, chosen: chosenSport) }

    private var sportPicker: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if !chipSports.isEmpty {
                WorkoutRecentSportChips(sports: chipSports, selected: chosenSport) { chosenSport = $0 }
            }
            allActivitiesRow
            if chosenSport == WorkoutCatalog.defaultSportName { customSportField }
        }
        .sheet(isPresented: $showsAllActivities) {
            WorkoutActivityPickerSheet(
                selected: chosenSport,
                onSelect: { chosenSport = $0 },
                onCustom: { name in
                    chosenSport = WorkoutCatalog.defaultSportName
                    customSport = name
                })
        }
    }

    private var allActivitiesRow: some View {
        Button { showsAllActivities = true } label: {
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DomainTint.workout.accent)
                    .accessibilityHidden(true)
                Text("All activities")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: NoopMetrics.space2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(StrandPalette.surfaceInset, in: inputShape)
            .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var customSportField: some View {
        TextField("Name it (optional)", text: $customSport)
            .textFieldStyle(.plain)
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.textPrimary)
            .focused($focusedField, equals: .customSport)
            .submitLabel(.done)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(StrandPalette.surfaceInset, in: inputShape)
            .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .accessibilityLabel("Name of the activity, optional")
    }

    // MARK: - Sections

    /// Avg HR and Calories share a row; at accessibility sizes each is as wide as the sheet, so what is typed stays in view.
    @ViewBuilder private var numberFields: some View {
        let avgHrField = field(String(localized: "Avg HR")) {
            numberInput(String(localized: "optional"), text: $avgHrText, unit: "bpm", field: .avgHr)
                .accessibilityLabel("Average heart rate in beats per minute, optional")
        }
        let caloriesField = field(String(localized: "Calories")) {
            numberInput(String(localized: "optional"), text: $kcalText, unit: "kcal", field: .calories)
                .accessibilityLabel("Calories in kilocalories, optional")
        }
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) { avgHrField; caloriesField }
        } else {
            HStack(spacing: 14) { avgHrField; caloriesField }
        }
    }

    private var header: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    // The same glyph the rest of the workouts screens wear, so the sheet reads as part of them.
                    WorkoutSportGlyph(symbol: "figure.run")
                    headerTexts
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    WorkoutSportGlyph(symbol: "figure.run")
                    headerTexts
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var headerTexts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(editing == nil ? "Add Workout" : "Edit Workout")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(editing == nil
                 ? "Log a session you tracked elsewhere."
                 : "Adjust this session's details.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What is wrong with the form, beside the buttons it explains.
    private var footerWithNote: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if let validationNote {
                // Before anyone has tried to add, what is missing is a hint; a fault is for a form that was tried.
                noteRow(validationNote.text,
                        systemImage: validationNote.isHint ? "info.circle" : "exclamationmark.circle.fill",
                        tint: validationNote.isHint ? StrandPalette.textTertiary : StrandPalette.statusWarning)
            }
            footer
        }
    }

    private var footer: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // Stacked, the primary action first and as wide as the sheet, so neither label wraps.
                VStack(spacing: NoopMetrics.space2) {
                    saveButton.frame(maxWidth: .infinity)
                    WorkoutCancelButton(fillsWidth: true)
                }
            } else {
                HStack(spacing: NoopMetrics.space3) {
                    WorkoutCancelButton()
                    Spacer()
                    saveButton
                }
            }
        }
    }

    private var saveButton: some View {
        // Never disabled: a button that cannot be pressed cannot say what is missing. Pressed on an incomplete form it
        // turns the hint into the fault. Until the form can be saved it is drawn in the standard unavailable look.
        Button { attemptSave() } label: {
            Label { editing == nil ? Text("Add") : Text("Save") } icon: { Image(systemName: "checkmark") }
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
        }
        .buttonStyle(PrimaryPillButtonStyle(looksUnavailable: builtRow == nil))
        .accessibilityLabel(editing == nil ? "Add workout" : "Save workout")
        .accessibilityHint(Text(verbatim: builtRow == nil ? (validationNote?.text ?? "") : ""))
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numberInput(_ placeholder: String, text: Binding<String>, unit: String, field: FormField) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                // Numeric entry → decimal pad on iOS (digits + "."), not the QWERTY default; no-op on macOS.
                .numericKeyboard()
                .focused($focusedField, equals: field)
            Text(unit).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        // Fill the field column so the Avg HR / Calories boxes share an identical width — left to
        // their intrinsic size the two boxes rendered unequal (the "bpm"/"kcal" units differ in
        // length), so the side-by-side row read as lopsided (#234).
        .frame(maxWidth: .infinity)
        .background(StrandPalette.surfaceInset, in: inputShape)
        .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }

    private func noteRow(_ text: String, systemImage: String = "info.circle", tint: Color = StrandPalette.textTertiary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Validation / build

    private var inputShape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    private var durationLabel: String { WorkoutFormat.duration(Double(durationMin) * 60) }

    /// Parsed avg-HR — nil for blank, an out-of-band sentinel handled by buildManualRow otherwise.
    private var avgHr: Int? { Int(avgHrText.trimmingCharacters(in: .whitespaces)) }
    private var kcal: Double? { Double(kcalText.trimmingCharacters(in: .whitespaces)) }

    /// The validated row, or nil when the inputs can't make an honest one (drives the disabled Save +
    /// the inline note). Built through the same WorkoutSource.buildManualRow the engine trusts.
    private var builtRow: WorkoutRow? {
        // A typed-but-unparseable number is invalid (e.g. "abc" in Avg HR) — guard before building.
        if !avgHrText.trimmingCharacters(in: .whitespaces).isEmpty && avgHr == nil { return nil }
        if !kcalText.trimmingCharacters(in: .whitespaces).isEmpty && kcal == nil { return nil }
        guard let base = WorkoutSource.buildManualRow(start: start, durationMin: durationMin,
                                                      sport: sport, avgHr: avgHr, energyKcal: kcal)
        else { return nil }
        // Carry over captured-but-unexposed fields when editing an existing strap session.
        return WorkoutSource.preservingCaptured(base, from: editing)
    }

    /// #18: true when this edit changes the Avg HR on a row that carries CAPTURED strain/zones from a
    /// recorded session. preservingCaptured keeps the old strain/zonesJSON verbatim, so a typed Avg HR is
    /// saved while the HR graph, zones and Strain stay from the recording. That mismatch is silent, so we
    /// surface a one-line note. We do NOT re-score from a single number (that would fabricate a strain),
    /// this is purely an honest disclosure. nil for a fresh add, or when nothing captured would go stale.
    private var avgHrEditedNote: Bool {
        guard let editing, let built = builtRow else { return false }
        let captured = editing.strain != nil || editing.zonesJSON != nil
        return captured && built.avgHr != editing.avgHr
    }

    /// What stops the form being saved. `isHint` is true for the one thing a fresh form always lacks (a sport) until an
    /// Add has been tried; everything else follows something the person typed or picked, so it is a fault at once.
    private struct ValidationNote {
        let text: String
        var isHint = false
    }

    private var validationNote: ValidationNote? {
        guard builtRow == nil else { return nil }
        if chosenSport.isEmpty { return ValidationNote(text: String(localized: "Choose a sport."), isHint: !attemptedAdd) }
        if start > Date() { return ValidationNote(text: String(localized: "Start can't be in the future.")) }
        if !avgHrText.trimmingCharacters(in: .whitespaces).isEmpty, avgHr == nil || !(25...250).contains(avgHr ?? -1) {
            return ValidationNote(text: String(localized: "Average HR must be 25-250 bpm."))
        }
        if !kcalText.trimmingCharacters(in: .whitespaces).isEmpty, kcal == nil || (kcal ?? -1) < 0 || (kcal ?? 0) > 20_000 {
            return ValidationNote(text: String(localized: "Calories must be 0-20,000."))
        }
        return ValidationNote(text: String(localized: "Check the values and try again."))
    }

    /// Add on a form that cannot be saved shows what is missing; on one that can, it saves.
    private func attemptSave() {
        guard builtRow != nil else {
            attemptedAdd = true
            return
        }
        save()
    }

    private func save() {
        guard let row = builtRow else { return }
        if let recorded = ManualWorkoutSport.recordedName(for: sport) { RecentSportsPrefs.recordSelection(recorded) }
        onSave(row, editing)
        dismiss()
    }
}

#if DEBUG
#Preview("Add") {
    ManualWorkoutSheet { _, _ in }
        .preferredColorScheme(.dark)
}

#Preview("Edit") {
    ManualWorkoutSheet(editing: WorkoutRow(
        startTs: Int(Date().timeIntervalSince1970) - 3600, endTs: Int(Date().timeIntervalSince1970),
        sport: "Running", source: "manual", durationS: 3600, energyKcal: 540,
        avgHr: 148, maxHr: 172, strain: 12.4, distanceM: nil, zonesJSON: nil, notes: nil)) { _, _ in }
        .preferredColorScheme(.dark)
}
#endif
