import SwiftUI
import Foundation
import StrandDesign
import StrandImport
import StrandAnalytics
import WhoopStore

// MARK: - Marker editor (manual entry — MVP)
//
// The "+ add a reading" sheet for the Lab Book (Health Records pillar, spec §"Add / edit
// a marker"). Pick a marker from MarkerCatalog (searchable) OR add a custom marker (free
// name + unit), then: value (numeric, the marker's canonical unit prefilled, a unit
// switcher where sensible e.g. mmol/L↔mg/dL with the conversion shown transparently),
// date/time taken, an optional note, and an OPTIONAL "reference range from my report"
// free-text — NEVER a NOOP-shipped range. Blood pressure is a PAIRED marker (systolic +
// diastolic entered together, stored as two keys) so it reads naturally.
//
// On save it hands the caller `[LabMarkerRow]` drafts (one row, or two for BP) under the
// strap device id with a `lab-book`-projecting write path; the caller persists + refreshes.
// SELF-CONTAINED: no AppModel/Settings edits; the sheet owns all its state.
//
// NON-CLINICAL: this only captures what the user types. The reference field is theirs,
// shown back verbatim — NOOP defines no ranges and asserts no normality.

struct MarkerEditorView: View {
    /// Persist the validated draft row(s). Async so the caller can write + refresh.
    let onSave: (_ drafts: [LabMarkerRow]) async -> Void

    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    // Marker selection.
    @State private var selection: MarkerDefinition?
    @State private var customName = ""
    @State private var customUnit = ""
    @State private var addingCustom = false
    @State private var search = ""

    // Reading inputs.
    @State private var valueText = ""
    @State private var diastolicText = ""   // only used for the paired BP marker
    @State private var unit = ""
    @State private var unitChoice = 0       // index into the active unit options (the switcher)
    @State private var takenAt = Date()
    @State private var note = ""
    @State private var referenceText = ""

    @State private var saving = false

    private enum Field: Hashable { case value, diastolic, note, reference, customName, customUnit }
    @FocusState private var focused: Field?

    private let accent = DomainTint.custom(StrandPalette.metricCyan)

    var body: some View {
        ScreenScaffold(title: "Add a reading",
                       subtitle: "Type in a number from your own report. It stays on \(Platform.deviceNounPhrase).") {
            VStack(alignment: .leading, spacing: 0) {
                markerSection
                if selection != nil || addingCustom {
                    FlatSectionSeparator()
                    readingSection
                }
                FlatSectionSeparator()
                disclaimerNote
                // At accessibility text sizes a pinned footer would take half the sheet, so it follows the form.
                if typeSize.isAccessibilitySize { footer.padding(.top, NoopMetrics.space5) }
            }
            // The form is as wide as the sheet, whatever one of its rows would like: a row that cannot shrink must not
            // widen the whole page and push every other row off the edge of the screen.
            #if os(iOS)
            .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in max(0, width - 32) }
            #endif
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !typeSize.isAccessibilitySize { footer.sheetFooterBar() }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        // A FIXED frame (not minWidth/minHeight): a macOS sheet hosting a ScrollView needs a definite
        // height, otherwise the scaffold's height stays ambiguous and every row collapses to the top,
        // rendering the title/fields/catalog on top of each other. Matches the other editor sheets.
        .frame(width: 520, height: 720)
        #endif
        .background(StrandPalette.surfaceBase)
        .keyboardDoneToolbar($focused)
        #if DEBUG
        .onAppear(perform: qaPreselectMarker)
        #endif
    }

    #if DEBUG
    /// Screenshot harness only: `--noop-qa-marker <key>` opens the editor with that catalog marker already chosen (and no
    /// keyboard up), so the reading form can be captured without UI automation; `--noop-qa-marker-custom` opens the custom
    /// marker form with a name, a unit and a value filled in.
    private func qaPreselectMarker() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--noop-qa-marker-custom"), selection == nil, !addingCustom {
            addingCustom = true
            customName = "Magnesium"
            customUnit = "mmol/L"
            valueText = "0.82"
            return
        }
        guard selection == nil, let index = arguments.firstIndex(of: "--noop-qa-marker"),
              arguments.indices.contains(index + 1),
              let def = MarkerCatalog.definition(for: arguments[index + 1]) else { return }
        selection = def
        unit = def.canonicalUnit
        unitChoice = 0
    }
    #endif

    // MARK: - Marker picker

    private var markerSection: some View {
        FlatSection("Marker", systemImage: "flask", tint: accent, contentSpacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                if addingCustom {
                    customMarkerFields
                } else if let selection {
                    chosenMarkerRow(selection)
                } else {
                    searchField
                    catalogList
                    ChipRow {
                        WidgetChipButton(
                            title: "Add a custom marker", systemImage: "plus",
                            accessibilityLabel: "Add a custom marker",
                            action: {
                                addingCustom = true
                                focused = .customName
                            })
                    }
                }
            }
        }
    }

    private var searchField: some View {
        PaperSearchField(
            "Search markers (e.g. LDL, ferritin)",
            text: $search,
            height: 44,
            cornerRadius: 10,
            inputConfiguration: .searchQuery
        )
        .accessibilityLabel("Search markers")
    }

    private var filteredCatalog: [MarkerDefinition] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return MarkerCatalog.builtIn }
        return MarkerCatalog.builtIn.filter {
            $0.displayName.lowercased().contains(q) || $0.key.contains(q)
        }
    }

    /// Every catalog marker as a flat row (the page scrolls, so all of them are reachable): its glyph, its name and
    /// category, and the unit it is stored in.
    private var catalogList: some View {
        let matches = filteredCatalog
        return VStack(spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element.key) { index, def in
                if index > 0 { ExploreRowSeparator() }
                Button {
                    choose(def)
                } label: {
                    ExploreFlatRow(
                        symbol: def.category.symbol, tint: accent,
                        title: Text(verbatim: def.displayName),
                        subtitle: Text(verbatim: def.category.displayName),
                        showsChevron: false,
                        spoken: "\(def.displayName), \(def.canonicalUnit)"
                    ) {
                        Text(verbatim: def.canonicalUnit)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(1)
                    }
                }
                .exploreRowPress()
            }
            if matches.isEmpty {
                Text("No match. Add it as a custom marker below.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.vertical, NoopMetrics.space2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chosenMarkerRow(_ def: MarkerDefinition) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            ExploreFlatRow(
                symbol: def.category.symbol, tint: accent,
                title: Text(verbatim: def.displayName),
                subtitle: Text(verbatim: def.category.displayName),
                showsChevron: false)
            ChipRow {
                WidgetChipButton(
                    title: "Change", systemImage: "arrow.left.arrow.right",
                    accessibilityLabel: "Change marker", action: reset)
            }
        }
    }

    private var customMarkerFields: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            field(String(localized: "Name")) {
                textBox("e.g. Magnesium", text: $customName, focus: .customName)
                    .accessibilityLabel("Custom marker name")
            }
            field(String(localized: "Unit")) {
                textBox("e.g. mmol/L", text: $customUnit, focus: .customUnit)
                    .accessibilityLabel("Custom marker unit")
            }
            ChipRow {
                WidgetChipButton(
                    title: "Back to the marker list", systemImage: "chevron.left",
                    accessibilityLabel: "Back to the marker list",
                    action: { addingCustom = false })
            }
        }
    }

    // MARK: - Reading inputs

    private var readingSection: some View {
        FlatSection("Reading", systemImage: "pencil", tint: accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                if isBloodPressure {
                    bloodPressureFields
                } else {
                    valueField
                }
                field(String(localized: "Date taken")) {
                    takenAtPicker
                }
                field(String(localized: "Note (optional)")) {
                    textBox("e.g. fasting, morning draw", text: $note, focus: .note)
                        .accessibilityLabel("Optional note")
                }
                field(String(localized: "Reference range from my report (optional)")) {
                    textBox("e.g. 2.0–5.0 (your report's own range)", text: $referenceText, focus: .reference)
                        .accessibilityLabel("Reference range from your own report, optional")
                }
                Text("NOOP never fills this in. It only shows back exactly what you type from your own report.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var valueField: some View {
        VStack(alignment: .leading, spacing: 6) {
            if typeSize.isAccessibilitySize {
                // At an accessibility size the unit switcher cannot sit beside its label: it stacks under it.
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel(String(localized: "Value"))
                    if unitOptions.count > 1 { unitSwitcher }
                }
            } else {
                HStack {
                    fieldLabel(String(localized: "Value"))
                    Spacer()
                    if unitOptions.count > 1 { unitSwitcher }
                }
            }
            numberInput(placeholder: "e.g. 3.1", text: $valueText, unit: activeUnit, field: .value)
                .background(StrandPalette.surfaceInset, in: inputShape)
            .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
            if unitOptions.count > 1 {
                Text("Stored as \(MarkerUnits.canonicalUnit(for: markerKey, fallback: unit)). \(conversionNote)")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The transparent unit switcher (e.g. mmol/L ↔ mg/dL).
    private var unitSwitcher: some View {
        SegmentedPillControl(Array(unitOptions.indices), selection: $unitChoice) { unitOptions[$0] }
            .accessibilityLabel("Unit")
    }

    /// The date and the time of the reading. Side by side they are wider than the sheet at the accessibility sizes, so
    /// there each gets its own line.
    @ViewBuilder
    private var takenAtPicker: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                DatePicker("", selection: $takenAt, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .accessibilityLabel("Date taken")
                DatePicker("", selection: $takenAt, in: ...Date(), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .accessibilityLabel("Time taken")
            }
        } else {
            DatePicker("", selection: $takenAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .accessibilityLabel("Date and time taken")
        }
    }

    private var bloodPressureFields: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            // Side by side, each box needs room for its number and unit; at accessibility sizes each is as wide as the sheet.
            let systolic = field(String(localized: "Systolic")) {
                numberBox(placeholder: String(localized: "e.g. 120"), text: $valueText, unit: "mmHg", field: .value)
                    .accessibilityLabel("Systolic blood pressure in mmHg")
            }
            let diastolic = field(String(localized: "Diastolic")) {
                numberBox(placeholder: String(localized: "e.g. 80"), text: $diastolicText, unit: "mmHg", field: .diastolic)
                    .accessibilityLabel("Diastolic blood pressure in mmHg")
            }
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) { systolic; diastolic }
            } else {
                HStack(spacing: NoopMetrics.space4) { systolic; diastolic }
            }
            Text("Entered together; stored as two markers so each lines up cleanly against your signals.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A number field with its unit. At the accessibility sizes the unit drops under the number: side by side the field
    /// and its unit are wider than the sheet, and the whole form would widen with them.
    private func numberInput(placeholder: LocalizedStringKey, text: Binding<String>, unit: String, field: Field) -> some View {
        let input = TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(StrandFont.bodyNumber)
            .foregroundStyle(StrandPalette.textPrimary)
            .numericKeyboard()
            .focused($focused, equals: field)
        let unitText = Text(verbatim: unit).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) { input; unitText }
            } else {
                HStack(spacing: 8) { input; unitText }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numberBox(placeholder: String, text: Binding<String>, unit: String, field: Field) -> some View {
        numberInput(placeholder: LocalizedStringKey(placeholder), text: text, unit: unit, field: field)
        .background(StrandPalette.surfaceInset, in: inputShape)
        .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }

    // MARK: - Disclaimer + footer

    private var disclaimerNote: some View {
        Text("Lab Book keeps your own numbers. It doesn't test, read, or judge them, and it's not medical advice. Everything stays on \(Platform.deviceNounPhrase).")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, NoopMetrics.space4)
    }

    private var footer: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // Stacked, the primary action first and as wide as the sheet, so neither label wraps.
                VStack(spacing: NoopMetrics.space2) {
                    saveButton.frame(maxWidth: .infinity)
                    cancelButton.frame(maxWidth: .infinity)
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
        Button { dismiss() } label: {
            Text("Cancel").frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
        }
        .buttonStyle(SecondaryPillButtonStyle())
    }

    private var saveButton: some View {
        Button { save() } label: {
            Text("Save").frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
        }
        .buttonStyle(PrimaryPillButtonStyle())
        .disabled(drafts.isEmpty || saving)
        .accessibilityLabel("Save reading")
    }

    // MARK: - Selection + units

    private func choose(_ def: MarkerDefinition) {
        selection = def
        unit = def.canonicalUnit
        unitChoice = 0
        focused = .value
    }

    private func reset() {
        selection = nil
        valueText = ""
        diastolicText = ""
        unitChoice = 0
        search = ""
    }

    /// The active marker key (catalog key, or a slug of the custom name).
    private var markerKey: String {
        if let selection { return selection.key }
        return MarkerUnits.slug(customName)
    }

    private var category: LabMarkerCategory {
        if let selection { return selection.category }
        return .other
    }

    private var isBloodPressure: Bool { markerKey == LabBookProjection.bpSystolicKey }

    /// The unit options for the active marker — a switcher list only for markers that have a
    /// well-known dual unit (lipids/glucose: mmol/L↔mg/dL). Everything else has one canonical unit.
    private var unitOptions: [String] {
        if addingCustom { return [customUnit.isEmpty ? "" : customUnit] }
        return MarkerUnits.options(for: markerKey, canonical: unit)
    }

    private var activeUnit: String {
        guard unitOptions.indices.contains(unitChoice) else { return unit }
        return unitOptions[unitChoice]
    }

    private var conversionNote: String {
        guard unitOptions.count > 1, activeUnit != MarkerUnits.canonicalUnit(for: markerKey, fallback: unit),
              let factor = MarkerUnits.factorToCanonical(markerKey: markerKey, from: activeUnit) else {
            return ""
        }
        return String(localized: "× \(MarkerUnits.factorLabel(factor)) on save.")
    }

    // MARK: - Build the draft rows

    /// The validated draft row(s): two for BP, one otherwise. Empty when inputs aren't usable yet.
    private var drafts: [LabMarkerRow] {
        // Custom marker needs a name + unit.
        if addingCustom {
            guard !customName.trimmingCharacters(in: .whitespaces).isEmpty,
                  !customUnit.trimmingCharacters(in: .whitespaces).isEmpty,
                  let v = MarkerUnits.parse(valueText) else { return [] }
            return [row(key: markerKey, category: .other, value: v, unit: customUnit)]
        }
        guard selection != nil else { return [] }
        if isBloodPressure {
            guard let sys = MarkerUnits.parse(valueText), let dia = MarkerUnits.parse(diastolicText) else { return [] }
            return [
                row(key: LabBookProjection.bpSystolicKey, category: .bloodPressure, value: sys, unit: "mmHg"),
                row(key: LabBookProjection.bpDiastolicKey, category: .bloodPressure, value: dia, unit: "mmHg"),
            ]
        }
        guard let raw = MarkerUnits.parse(valueText) else { return [] }
        // Convert the entered value to the canonical stored unit if a switcher is in use.
        let canonical = MarkerUnits.canonicalUnit(for: markerKey, fallback: unit)
        let stored = MarkerUnits.toCanonical(markerKey: markerKey, value: raw, from: activeUnit)
        return [row(key: markerKey, category: category, value: stored, unit: canonical)]
    }

    private func row(key: String, category: LabMarkerCategory, value: Double, unit: String) -> LabMarkerRow {
        let trimmedNote = note.trimmingCharacters(in: .whitespaces)
        let trimmedRef = referenceText.trimmingCharacters(in: .whitespaces)
        let epoch = Int(takenAt.timeIntervalSince1970)
        return LabMarkerRow(
            id: "\(key)-\(epoch)-\(UUID().uuidString.prefix(8))",
            deviceId: repo.deviceId,
            markerKey: key,
            category: category.rawValue,
            day: LabBookFormat.dayKey(takenAt),
            takenAt: epoch,
            value: value,
            valueText: nil,
            unit: unit,
            source: "manual",
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            referenceText: trimmedRef.isEmpty ? nil : trimmedRef
        )
    }

    private func save() {
        let rows = drafts
        guard !rows.isEmpty else { return }
        saving = true
        Task {
            await onSave(rows)
            dismiss()
        }
    }

    // MARK: - Small builders

    private var inputShape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    /// A one-line text input in the shared inset field look.
    private func textBox(_ placeholder: LocalizedStringKey, text: Binding<String>, focus: Field) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.textPrimary)
            .focused($focused, equals: focus)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(minHeight: 44)
            .background(StrandPalette.surfaceInset, in: inputShape)
            .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }

    /// A field's caption: capitals with tracking, scaled to fit a long word rather than broken inside it.
    private func fieldLabel(_ label: String) -> some View {
        Text(verbatim: label).strandOverlineFitted().lineLimit(3).fixedSize(horizontal: false, vertical: true)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Unit handling (transparent mmol/L ↔ mg/dL switcher for lipids/glucose)
//
// Only the markers with a well-known dual unit get a switcher; everything else keeps its
// single canonical unit. Conversions are exact and reversible. The stored value is always
// the canonical unit, so the daily projection + correlation stay consistent regardless of
// what the user typed in.

enum MarkerUnits {
    /// Markers whose mg/dL → mmol/L factor we know (molar-mass derived, standard clinical factors).
    /// Lipids share 38.67; glucose uses 18.0.
    private static let mgdlToMmol: [String: Double] = [
        "total_cholesterol": 1.0 / 38.67,
        "ldl":               1.0 / 38.67,
        "hdl":               1.0 / 38.67,
        "triglycerides":     1.0 / 88.57,   // triglyceride molar conversion
        "fasting_glucose":   1.0 / 18.0,
    ]

    /// The canonical (stored) unit for a marker — the catalog's, or a fallback.
    static func canonicalUnit(for key: String, fallback: String) -> String {
        MarkerCatalog.definition(for: key)?.canonicalUnit ?? fallback
    }

    /// The unit options shown in the switcher. Two entries (canonical + mg/dL) for the dual-unit
    /// markers; otherwise just the single canonical unit.
    static func options(for key: String, canonical: String) -> [String] {
        if mgdlToMmol[key] != nil { return [canonicalUnit(for: key, fallback: canonical), "mg/dL"] }
        return [canonical]
    }

    /// Multiplicative factor turning a value in `from` into the canonical unit, or nil if no conversion.
    static func factorToCanonical(markerKey: String, from unit: String) -> Double? {
        guard unit == "mg/dL", let f = mgdlToMmol[markerKey] else { return nil }
        return f
    }

    /// Convert a typed value (in `from`) to the canonical stored unit. Identity when no conversion applies.
    static func toCanonical(markerKey: String, value: Double, from unit: String) -> Double {
        guard let f = factorToCanonical(markerKey: markerKey, from: unit) else { return value }
        return value * f
    }

    /// A short label for the conversion factor (4 sig figs), e.g. "0.02586".
    static func factorLabel(_ f: Double) -> String { String(format: "%.5g", f) }

    /// A number typed into a reading field. The decimal mark is the keyboard's own ("3,1" on a German keyboard, "3.1" on an
    /// English one) and a full stop always works; the other mark is a grouping mark, which a reading never has, so it is
    /// not guessed at ("1,000" is not read as 1 on an English keyboard) and the field simply stays unsaved. nil for
    /// anything that is not one plain number.
    static func parse(_ text: String, locale: Locale = .autoupdatingCurrent) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let separator = locale.decimalSeparator ?? "."
        let marks = trimmed.filter { $0 == "." || $0 == "," }
        guard marks.count <= 1, marks.allSatisfy({ $0 == "." || String($0) == separator }) else { return nil }
        return Double(trimmed.replacingOccurrences(of: separator, with: "."))
    }

    /// A lower-cased, underscored slug for a custom marker name → its stable key.
    static func slug(_ name: String) -> String {
        let lowered = name.trimmingCharacters(in: .whitespaces).lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "_"
        }
        let collapsed = String(mapped).replacingOccurrences(of: "__", with: "_")
        return "custom_" + collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}

#if DEBUG
@MainActor
private func markerEditorPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Marker Editor") {
    MarkerEditorView { _ in }
        .environmentObject(markerEditorPreviewRepo())
        .frame(width: 520, height: 720)
        .preferredColorScheme(.dark)
}
#endif
