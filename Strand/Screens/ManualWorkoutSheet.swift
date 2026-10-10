import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Manual workout sheet
//
// Add a workout you tracked elsewhere, or edit one you already logged. Five inputs — sport,
// start, duration, average HR, calories — validated by WorkoutSource.buildManualRow (the same
// honest-row rules the engine uses). On save the caller persists it under the strap source via
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

    @State private var sport: String
    @State private var start: Date
    @State private var durationMin: Int
    @State private var avgHrText: String
    @State private var kcalText: String
    /// The sports used lately (free-typed ones included), offered under the Sport field as one-tap chips.
    @State private var recentSports: [String] = RecentSportsPrefs.recent()

    /// Focus for the numeric (Avg HR / Calories) fields so the keyboard Done button can resign them —
    /// the decimal pad has no return key. iOS-only effect; the enum keeps both platforms compiling.
    private enum NumberField: Hashable { case avgHr, calories }
    @FocusState private var focusedField: NumberField?

    /// Whether the Sport text field is being edited — drives whether the catalogue suggestions show
    /// beneath it. The list also stays hidden once the typed text exactly matches a catalogue sport
    /// (a settled choice), so the form isn't permanently half-covered.
    @FocusState private var sportFocused: Bool

    init(editing: WorkoutRow? = nil,
         onSave: @escaping (_ row: WorkoutRow, _ replacing: WorkoutRow?) -> Void) {
        self.editing = editing
        self.onSave = onSave
        // Pre-fill from the edited row (display "detected" as "Activity" so a re-label starts clean).
        let e = editing
        // Seeds the LOCALE-STABLE editable form, not the localized display: the field's content is
        // persisted verbatim on save, and a translated word would split cross-source dedup per language.
        _sport = State(initialValue: e.map { WorkoutSource.editableSport($0.sport) } ?? "")
        _start = State(initialValue: e.map { Date(timeIntervalSince1970: TimeInterval($0.startTs)) } ?? Date())
        _durationMin = State(initialValue: e.map { max(1, Int((($0.durationS ?? Double($0.endTs - $0.startTs)) / 60).rounded())) } ?? 45)
        _avgHrText = State(initialValue: e?.avgHr.map(String.init) ?? "")
        _kcalText = State(initialValue: e?.energyKcal.map { String(Int($0.rounded())) } ?? "")
    }

    var body: some View {
        // The form scrolls, so at the sheet's medium height the header stays clear of the grabber and the footer stays
        // pinned instead of the whole stack overflowing both ways. The footer sits above the keyboard.
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
                            .accessibilityLabel("Duration in minutes")
                        }
                    }
                    HStack(spacing: 14) {
                        field(String(localized: "Avg HR")) {
                            numberInput(String(localized: "optional"), text: $avgHrText, unit: "bpm", field: .avgHr)
                                .accessibilityLabel("Average heart rate in beats per minute, optional")
                        }
                        field(String(localized: "Calories")) {
                            numberInput(String(localized: "optional"), text: $kcalText, unit: "kcal", field: .calories)
                                .accessibilityLabel("Calories in kilocalories, optional")
                        }
                    }
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
        // A short 5-field form → open at .medium with .large a drag away; the grabber also gives the
        // top dismiss affordance the sheet otherwise lacks (only a bottom Cancel).
        .noopSheetPresentation(largeFirst: typeSize.isAccessibilitySize)
        #endif
        .background(StrandPalette.surfaceOverlay)
        // Lets the user dismiss the decimal pad (which has no return key) and reach Cancel/Add. No-op on macOS.
        .keyboardDoneToolbar($focusedField)
    }

    // MARK: - Sport picker
    //
    // A searchable PICKER over the shared WorkoutCatalog (the same named-sport list the live tracker
    // uses, incl. Padel) with a free-text FALLBACK: the text field IS the value, so an unusual sport
    // NOOP doesn't enumerate still saves exactly as typed (#519). Typing filters the catalogue
    // beneath the field; tapping a match fills it; the list collapses on a settled / off-catalogue
    // entry so the short form isn't permanently covered. Mirrors Android WorkoutsScreen.SportPickerField.

    /// Suggestions for the current text — the whole catalogue while empty, else a case-insensitive
    /// name filter. Empty list ⇒ a free-typed sport with no match (keeps whatever was typed).
    private var sportSuggestions: [WorkoutCatalog.Sport] { WorkoutCatalog.matching(sport) }

    /// Show the list only while the field is focused, there are matches, and the text isn't already an
    /// exact catalogue name (a settled choice collapses it).
    private var showSportSuggestions: Bool {
        sportFocused && !sportSuggestions.isEmpty && WorkoutCatalog.sport(named: sport) == nil
    }

    private var sportPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("e.g. Running", text: $sport)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .focused($sportFocused)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(StrandPalette.surfaceInset, in: inputShape)
                .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
                .accessibilityLabel("Sport")
            if !showSportSuggestions && !recentSports.isEmpty {
                WorkoutRecentSportChips(sports: recentSports, selected: sport) { sport = $0 }
                    .padding(.top, 2)
            }
            if showSportSuggestions {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sportSuggestions) { sp in
                            Button {
                                sport = sp.name
                                sportFocused = false
                            } label: {
                                HStack(spacing: 6) {
                                    Text(sp.name)
                                        .font(StrandFont.body)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    if sp.isDistanceSport {
                                        Text("· GPS")
                                            .font(StrandFont.footnote)
                                            .foregroundStyle(StrandPalette.textTertiary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 12).padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Pick \(sp.name)")
                        }
                    }
                }
                .frame(maxHeight: 168)
                .background(StrandPalette.surfaceInset, in: inputShape)
                .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
            }
        }
    }

    // MARK: - Sections

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
                noteRow(validationNote, systemImage: "exclamationmark.circle.fill", tint: StrandPalette.statusWarning)
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
                    cancelButton
                }
            } else {
                HStack(spacing: NoopMetrics.space3) {
                    cancelButton
                    Spacer()
                    saveButton
                }
            }
        }
    }

    private var cancelButton: some View {
        Button("Cancel") { dismiss() }
            .buttonStyle(.plain)
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(minHeight: 44)
    }

    private var saveButton: some View {
        Button { save() } label: {
            Label { editing == nil ? Text("Add") : Text("Save") } icon: { Image(systemName: "checkmark") }
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
        }
        .buttonStyle(PrimaryPillButtonStyle())
        .disabled(builtRow == nil)
        .accessibilityLabel(editing == nil ? "Add workout" : "Save workout")
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numberInput(_ placeholder: String, text: Binding<String>, unit: String, field: NumberField) -> some View {
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

    private var validationNote: String? {
        guard builtRow == nil else { return nil }
        if sport.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Enter a sport.") }
        if start > Date() { return String(localized: "Start can't be in the future.") }
        if !avgHrText.trimmingCharacters(in: .whitespaces).isEmpty, avgHr == nil || !(25...250).contains(avgHr ?? -1) {
            return String(localized: "Average HR must be 25-250 bpm.")
        }
        if !kcalText.trimmingCharacters(in: .whitespaces).isEmpty, kcal == nil || (kcal ?? -1) < 0 || (kcal ?? 0) > 20_000 {
            return String(localized: "Calories must be 0-20,000.")
        }
        return String(localized: "Check the values and try again.")
    }

    private func save() {
        guard let row = builtRow else { return }
        RecentSportsPrefs.recordSelection(sport)
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
