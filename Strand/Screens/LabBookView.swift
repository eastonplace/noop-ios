import SwiftUI
import Foundation
import UniformTypeIdentifiers
import StrandDesign
import StrandImport
import StrandAnalytics
import WhoopStore

// MARK: - Lab Book (Health Records pillar — v5)
//
// "Your own logbook." NOOP gives you a private place to KEEP the numbers you already
// get from your doctor or pharmacy — bloods, blood pressure, body measurements — and
// SEE them next to your wearable signals, entirely on this device. NOOP never tests
// you, never reads a result for you, and never tells you what a number means medically.
// (Spec: docs/superpowers/specs/2026-06-19-v5-health-records-design.md.)
//
// This screen is SELF-CONTAINED: it takes the repo via the environment (the same one
// every other screen binds to) and reads/writes markers through `repo.storeHandle()` —
// the on-device WhoopStore, where the LabMarkerStore extension lives (v17 `labMarker`
// table). Raw readings are stored under the strap device id (`repo.deviceId`); every
// write also projects a daily series under the `lab-book` source so Compare/Explore/
// Coach see markers unchanged. The "Compare with a signal" surface (MarkerDetailView)
// reads its correlation word and colour from the same `CorrelationStrength` rule as
// Compare and the Metric Explorer.
//
// It is built from the flat widget parts the rest of the app uses (an eyebrow per section, glyph rows with a muted
// latest value, pill buttons) and renders the same whether it is pushed from Trends or opened as a sheet from
// Health's Records.
//
// NON-CLINICAL (load-bearing, spec §"Non-clinical / legal framing"): no word here
// asserts a clinical judgement — never "abnormal/high/low/normal" as NOOP's own
// statement; any reference range shown is EXACTLY what the user typed from their own
// report; correlation copy says "association, not a medical finding". The full
// disclaimer shows on the screen and (Wave 3) links to the consolidated About & Legal.

struct LabBookView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState

    /// All readings, grouped + ordered for display. Loaded off the store on appear/refresh.
    @State private var markers: [LabMarkerRow] = []
    @State private var loaded = false

    /// The marker whose detail sheet is open (nil = none).
    @State private var detailKey: String?
    /// Whether the add/edit editor sheet is open.
    @State private var showingEditor = false
    /// Whether the first-use disclaimer sheet is open.
    @State private var showingDisclaimer = false

    // Markers CSV import (LabMarkerCsvImport, Phase 2).
    @State private var showingCsvImporter = false   // macOS .fileImporter presentation
    @State private var csvImporting = false
    @State private var csvSummary: String?
    @State private var csvFailed = false

    private let accent = DomainTint.custom(StrandPalette.metricCyan)

    var body: some View {
        ScreenScaffold(
            title: "Lab Book",
            subtitle: "Private health notebook",
            onRefresh: { await load() },
            // PERF: the column ends in a row per marker; the LazyVStack path builds the off-screen rows on demand so a
            // logbook with many markers doesn't render every row up-front.
            lazy: true
        ) {
            VStack(alignment: .leading, spacing: 0) {
                markersSection
                FlatSectionSeparator()
                importSection
                if loaded, !markers.isEmpty {
                    FlatSectionSeparator()
                    recentSection
                }
                FlatSectionSeparator()
                disclaimerNote
            }
        }
        .task(id: repo.refreshSeq) {
            await load()
            #if DEBUG
            await applyQAFixture()
            #endif
        }
        // Nested sheets carry their own Cancel / Done or close button; the sheetScreenScaffoldEnvironment only keeps
        // the app chrome (and the presenting sheet's close button) from leaking into them.
        .sheet(isPresented: $showingEditor) {
            MarkerEditorView { drafts in
                await save(drafts)
            }
            .sheetScreenScaffoldEnvironment()
        }
        .sheet(item: detailBinding) { key in
            MarkerDetailView(markerKey: key.id,
                             readings: readings(for: key.id),
                             onDelete: { id in await delete(id) })
                .sheetScreenScaffoldEnvironment(onClose: { detailKey = nil })
        }
        .sheet(isPresented: $showingDisclaimer) {
            LabBookDisclaimerView(onClose: { showingDisclaimer = false })
                .sheetScreenScaffoldEnvironment(onClose: { showingDisclaimer = false })
        }
        // macOS picker for the markers CSV; iOS goes through DocumentPicker (see
        // presentCsvImporter) for the iCloud download-on-pick behaviour (#179).
        .fileImporter(isPresented: $showingCsvImporter,
                      allowedContentTypes: [.commaSeparatedText, .plainText],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { importMarkersCsv(url: url) }
            case .failure(let error):
                NSLog("Import: markers CSV picker failed - \(error.localizedDescription)")
            }
        }
    }

    #if DEBUG
    // Screenshot harness only. `--noop-qa-labbook-fixture` saves a small logbook (several readings of a few markers, a
    // blood-pressure pair and a custom marker) through the real save path, so the list, a marker's page and its signal
    // comparison have something to show. `--noop-qa-labbook-empty` draws the empty logbook whatever is stored.
    // `--noop-qa-marker-detail <key>` opens that marker's page, `--noop-qa-marker-signal <metric key>` picks the signal
    // its comparison uses, and `--noop-qa-labbook-disclaimer` opens the disclaimer.
    private func applyQAFixture() async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--noop-qa-labbook-fixture"), !markers.contains(where: { $0.id.hasPrefix("qa-") }) {
            await save(Self.qaFixtureRows(deviceId: repo.deviceId))
        }
        if arguments.contains("--noop-qa-labbook-empty") { markers = [] }
        if let index = arguments.firstIndex(of: "--noop-qa-marker-detail"), arguments.indices.contains(index + 1),
           detailKey == nil {
            detailKey = arguments[index + 1]
        }
        if arguments.contains("--noop-qa-labbook-disclaimer") { showingDisclaimer = true }
    }

    private static func qaFixtureRows(deviceId: String) -> [LabMarkerRow] {
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        func row(_ key: String, _ category: LabMarkerCategory, daysAgo: Int, _ value: Double, _ unit: String,
                 note: String? = nil, reference: String? = nil) -> LabMarkerRow {
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return LabMarkerRow(
                id: "qa-\(key)-\(daysAgo)", deviceId: deviceId, markerKey: key, category: category.rawValue,
                day: LabBookFormat.dayKey(date), takenAt: Int(date.timeIntervalSince1970), value: value, valueText: nil,
                unit: unit, source: "manual", note: note, referenceText: reference)
        }
        var rows: [LabMarkerRow] = []
        for (index, ago) in [3, 10, 17, 24, 31, 38].enumerated() {
            rows.append(row("ferritin", .bloodPanel, daysAgo: ago, 92 - Double(index) * 5 + Double(index % 2) * 4, "ng/mL",
                            note: ago == 3 ? "Morning draw, fasting" : nil, reference: "30\u{2013}300 ng/mL"))
        }
        for (index, ago) in [5, 40, 90].enumerated() {
            rows.append(row("ldl", .bloodPanel, daysAgo: ago, 3.1 + Double(index) * 0.3, "mmol/L"))
        }
        for ago in [2, 16, 30] {
            rows.append(row(LabBookProjection.bpSystolicKey, .bloodPressure, daysAgo: ago, 118 + Double(ago % 5), "mmHg"))
            rows.append(row(LabBookProjection.bpDiastolicKey, .bloodPressure, daysAgo: ago, 76 + Double(ago % 3), "mmHg"))
        }
        rows.append(row("custom_magnesium", .other, daysAgo: 12, 0.82, "mmol/L"))
        return rows
    }
    #endif

    // MARK: - Markers

    private var markersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !loaded {
                ExploreMessage(isLoading: true, title: Text("Reading your logbook…"))
            } else if markers.isEmpty {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    ExploreMessage(
                        symbol: "flask", title: Text("No markers yet"),
                        message: Text("Track what matters to you. Add a marker to get started."))
                    addButton("Add marker")
                }
            } else {
                FlatSection(
                    "Markers", systemImage: "flask", tint: accent,
                    trailing: .text(allMarkerKeys.count.formatted()),
                    contentSpacing: 0
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(allMarkerKeys.enumerated()), id: \.element) { index, key in
                            if index > 0 { ExploreRowSeparator() }
                            markerRow(key)
                        }
                        addButton("Add a reading").padding(.top, NoopMetrics.space3)
                    }
                }
            }
        }
    }

    private func addButton(_ title: LocalizedStringKey) -> some View {
        Button { showingEditor = true } label: {
            Label(title, systemImage: "plus")
        }
        .buttonStyle(PrimaryPillButtonStyle())
        .accessibilityLabel("Add a marker reading")
    }

    /// One marker: its glyph, its name, when it was last taken, and the latest value with the unit set apart and muted.
    private func markerRow(_ key: String) -> some View {
        let series = readings(for: key)
        let latest = series.last
        let parts = LabBookFormat.parts(latest, key: key)
        let name = displayName(for: key)
        return Button {
            detailKey = key
        } label: {
            ExploreFlatRow(
                symbol: LabMarkerCategory(rawValue: latest?.category ?? "")?.symbol ?? "flask",
                tint: accent,
                title: Text(verbatim: name),
                subtitle: Text(verbatim: lastTakenCaption(latest)),
                spoken: String(localized: "\(name), latest \(LabBookFormat.spoken(parts)), \(series.count) readings")
            ) {
                ExploreLatestValue(number: parts.number, unit: parts.unit)
            }
        }
        .exploreRowPress()
    }

    private var allMarkerKeys: [String] {
        Set(markers.map(\.markerKey)).sorted { displayName(for: $0) < displayName(for: $1) }
    }

    // MARK: - Import entry (the Phase-2 markers CSV importer, LabMarkerCsvImport)
    //
    // The cross-platform floor is manual entry (above). The bulk markers CSV import is the
    // Phase-2 engine (LabMarkerCsvImport, spec §"Phasing"): (date, marker, value, unit) rows
    // with tolerant headers, catalog + custom marker mapping, and skip-and-count on anything
    // unreadable. The picker follows the Data Sources idiom (DocumentPicker on iOS,
    // .fileImporter on macOS).

    private var importSection: some View {
        FlatSection("Import", systemImage: "square.and.arrow.down", tint: accent, contentSpacing: 0) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Button { presentCsvImporter() } label: {
                    ExploreFlatRow(
                        symbol: "tray.and.arrow.down", tint: accent,
                        title: Text("Import readings"),
                        subtitle: Text("Bring in readings from a markers CSV")
                    ) {
                        if csvImporting { ProgressView().controlSize(.small) }
                    }
                }
                .exploreRowPress()
                .disabled(csvImporting)
                .accessibilityHint("Choose a markers CSV file to import")
                if let summary = csvSummary {
                    Text(summary)
                        .font(StrandFont.subhead)
                        .foregroundStyle(csvFailed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func presentCsvImporter() {
        #if os(iOS)
        // iOS: UIDocumentPickerViewController with asCopy:true (DocumentPicker) so an
        // undownloaded iCloud file is fetched and handed over readable (#179).
        Task {
            guard let url = await DocumentPicker.importFile([.commaSeparatedText, .plainText]) else { return } // cancelled
            importMarkersCsv(url: url)
        }
        #else
        showingCsvImporter = true
        #endif
    }

    /// Parse a markers CSV (LabMarkerCsvImport) and upsert the readings into the Lab Book
    /// under this device id with the `lab-csv` provenance tag; the daily `lab-book`
    /// projection rides the store's upsert, then a refresh lets Compare/Explore/Coach see
    /// the new markers.
    private func importMarkersCsv(url: URL) {
        csvImporting = true
        csvSummary = nil
        csvFailed = false
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let result = LabMarkerCsvImport.parse(data: data)
                guard !result.fileTooLarge else {
                    csvSummary = String(localized: "That file is too large for a markers CSV import.")
                    csvFailed = true
                    csvImporting = false
                    return
                }
                guard result.importedReadings > 0 else {
                    csvSummary = String(localized: "No usable rows found. Check the file has date, marker and value columns.")
                    csvFailed = true
                    logImport("Lab Book CSV: no usable rows (\(result.skippedRows) skipped)")
                    csvImporting = false
                    return
                }
                guard let store = await repo.storeHandle() else {
                    csvSummary = String(localized: "Couldn't open the local store.")
                    csvFailed = true
                    csvImporting = false
                    return
                }
                let rows = result.rows.map { r -> LabMarkerRow in
                    // UTC noon of the row's literal day: deterministic, so re-importing
                    // the same file updates in place (natural key
                    // deviceId+markerKey+takenAt+source) instead of duplicating.
                    let epoch = LabBookFormat.noonEpoch(r.day)
                    return LabMarkerRow(
                        id: "\(r.markerKey)-\(epoch)-\(UUID().uuidString.prefix(8))",
                        deviceId: repo.deviceId,
                        markerKey: r.markerKey,
                        category: r.category.rawValue,
                        day: r.day,
                        takenAt: epoch,
                        value: r.value,
                        valueText: nil,
                        unit: r.unit,
                        source: LabMarkerCsvImport.sourceId,
                        note: nil,
                        referenceText: nil
                    )
                }
                try await store.upsertLabMarkers(rows)
                _ = await repo.refresh(.currentDay)   // re-resolves the lab-book projection into Compare/Explore/Coach
                await load()
                var msg = String(localized: "Imported \(result.importedReadings) readings (\(result.distinctMarkers) markers)")
                if let a = result.earliestDay, let b = result.latestDay, a != b { msg += " · \(a)-\(b)" }
                if result.skippedRows > 0 {
                    // Whole-phrase variants per count; the separator stays outside the localized key.
                    msg += " · " + (result.skippedRows == 1
                                    ? String(localized: "1 row skipped")
                                    : String(localized: "\(result.skippedRows) rows skipped"))
                }
                csvSummary = msg
                csvFailed = false
                logImport("Lab Book CSV: \(result.importedReadings) readings, \(result.distinctMarkers) markers, \(result.skippedRows) rejected")
            } catch {
                csvSummary = String(localized: "Import failed: \(error.localizedDescription)")
                csvFailed = true
                logImport("Lab Book CSV failed: \(error.localizedDescription)")
            }
            csvImporting = false
        }
    }

    /// One privacy-safe line into the SAME exported strap log the other importers use
    /// (issue #421 parity): COUNTS only, never a file name, a path, or any health value.
    /// Same shape as DataSourcesView.logImport.
    private func logImport(_ line: String) {
        live.append(log: "[\(AppModel.logTimeFormatter.string(from: Date()))] Import \(line)")
    }

    // MARK: - Recent readings

    private var recentSection: some View {
        FlatSection("Recent Readings", systemImage: "clock", tint: accent, contentSpacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                let recent = Array(markers.sorted { $0.takenAt > $1.takenAt }.prefix(3))
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { ExploreRowSeparator() }
                    let parts = LabBookFormat.parts(row, key: row.markerKey)
                    let name = displayName(for: row.markerKey)
                    let date = LabBookFormat.dayFromKey(row.day)
                    Button {
                        detailKey = row.markerKey
                    } label: {
                        ExploreFlatRow(
                            symbol: "clock", tint: accent,
                            title: Text(verbatim: name),
                            subtitle: Text(verbatim: date),
                            spoken: "\(name), \(date), \(LabBookFormat.spoken(parts))"
                        ) {
                            ExploreLatestValue(number: parts.number, unit: parts.unit)
                        }
                    }
                    .exploreRowPress()
                }
            }
        }
    }

    // MARK: - Disclaimer (always visible footnote + link)

    private var disclaimerNote: some View {
        Button { showingDisclaimer = true } label: {
            ExploreFlatRow(
                symbol: "info.circle", tint: .neutral,
                title: Text("Important"),
                subtitle: Text("NOOP is for personal tracking and insights only. It is not medical advice or a diagnostic tool."),
                spoken: String(localized: "Important. NOOP is for personal tracking and insights only. Read the full note.")
            )
        }
        .exploreRowPress()
    }

    // MARK: - Data helpers

    /// Marker definition lookup → display name (catalog, else the key humanised).
    private func displayName(for key: String) -> String { Self.displayName(for: key) }

    static func displayName(for key: String) -> String {
        MarkerCatalog.definition(for: key)?.displayName ?? humanise(key)
    }

    static func humanise(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Readings for one marker, oldest-first (the store already returns them sorted by takenAt).
    private func readings(for key: String) -> [LabMarkerRow] {
        markers.filter { $0.markerKey == key }
    }

    private func lastTakenCaption(_ row: LabMarkerRow?) -> String {
        guard let row else { return String(localized: "no readings yet") }
        return String(localized: "last taken \(LabBookFormat.dayFromKey(row.day))")
    }

    private var detailBinding: Binding<MarkerKeyID?> {
        Binding(
            get: { detailKey.map(MarkerKeyID.init) },
            set: { detailKey = $0?.id }
        )
    }

    // MARK: - Load / save / delete (through the shared on-device store)

    private func load() async {
        guard let store = await repo.storeHandle() else { return }
        let loadSeq = repo.refreshSeq
        let deviceID = repo.deviceId
        let categories = LabMarkerCategory.allCases.map(\.rawValue)
        let all = await withTaskGroup(of: [LabMarkerRow].self, returning: [LabMarkerRow].self) { group in
            for category in categories {
                group.addTask {
                    (try? await store.labMarkers(deviceId: deviceID, category: category)) ?? []
                }
            }
            var result: [LabMarkerRow] = []
            for await rows in group { result.append(contentsOf: rows) }
            return result
        }
        guard !Task.isCancelled, loadSeq == repo.refreshSeq else { return }
        markers = all.sorted { $0.takenAt < $1.takenAt }
        loaded = true
    }

    private func save(_ drafts: [LabMarkerRow]) async {
        guard !drafts.isEmpty, let store = await repo.storeHandle() else { return }
        _ = try? await store.upsertLabMarkers(drafts)
        _ = await repo.refresh(.currentDay)   // re-resolves the lab-book projection into Compare/Explore/Coach
        await load()
    }

    private func delete(_ id: String) async {
        guard let store = await repo.storeHandle() else { return }
        _ = try? await store.deleteLabMarker(id: id)
        _ = await repo.refresh(.currentDay)
        await load()
    }
}

// MARK: - Identifiable wrapper so a String marker key can drive `.sheet(item:)`

private struct MarkerKeyID: Identifiable { let id: String }

// MARK: - Category display names + glyphs

extension LabMarkerCategory {
    /// Human label for the Lab Book grouping header. Organisational only — never a clinical panel name.
    var displayName: String {
        switch self {
        case .bloodPanel:      return String(localized: "Blood panel")
        case .bloodPressure:   return String(localized: "Blood pressure")
        case .bodyMeasurement: return String(localized: "Body")
        case .imaging:         return String(localized: "Imaging")
        case .appointmentNote: return String(localized: "Notes")
        case .other:           return String(localized: "Custom")
        }
    }

    /// The symbol on a marker's row: what kind of number it is, never a verdict on it.
    var symbol: String {
        switch self {
        case .bloodPanel:      return "drop.fill"
        case .bloodPressure:   return "waveform.path.ecg"
        case .bodyMeasurement: return "figure.stand"
        case .imaging:         return "photo"
        case .appointmentNote: return "note.text"
        case .other:           return "testtube.2"
        }
    }
}

// MARK: - Shared formatting (decimals from the catalog; Gregorian day keys, the person's own date format)

enum LabBookFormat {
    /// Format a numeric value with the marker's catalog decimals (default 1 for custom markers).
    static func value(_ v: Double, key: String) -> String {
        let decimals = MarkerCatalog.definition(for: key)?.decimals ?? 1
        return decimals == 0 ? String(Int(v.rounded())) : String(format: "%.\(decimals)f", v)
    }

    /// A reading as a number and its unit, so a list can set the unit apart and mute it: "92.0" and "ng/mL". A text
    /// entry has no unit; a missing reading is the dash.
    static func parts(_ row: LabMarkerRow?, key: String) -> (number: String, unit: String) {
        guard let row else { return (WidgetMetrics.missingValue, "") }
        if let v = row.value { return (value(v, key: key), row.unit) }
        return (row.valueText ?? WidgetMetrics.missingValue, "")
    }

    /// What VoiceOver says for a reading: the number, then the unit when there is one.
    static func spoken(_ parts: (number: String, unit: String)) -> String {
        parts.unit.isEmpty ? parts.number : "\(parts.number) \(parts.unit)"
    }

    /// "12 Jun 2026" in the person's language and order, for the instant a reading was taken.
    static func day(_ epoch: Int, locale: Locale = .autoupdatingCurrent) -> String {
        Date(timeIntervalSince1970: TimeInterval(epoch)).formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
    }

    /// The same, for a stored `yyyy-MM-dd` day key. The key is read as a Gregorian day (whatever calendar the device
    /// shows) and drawn on that day in the person's time zone, so the date never shifts near midnight or when the
    /// device changes zone. Falls back to the raw key if it is not a real day.
    static func dayFromKey(_ day: String, locale: Locale = .autoupdatingCurrent) -> String {
        guard let date = ExploreDayKey.date(for: day) else { return day }
        return date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
    }

    /// The `yyyy-MM-dd` day key the projection uses (the Gregorian LOCAL day of the reading).
    static func dayKey(_ date: Date) -> String { ExploreDayKey.key(for: date) }

    /// Epoch seconds of UTC noon on a `yyyy-MM-dd` day, the deterministic, LOCATION-INDEPENDENT `takenAt` for
    /// CSV-imported readings, so re-importing the same file (even after travel to another zone) upserts in place instead
    /// of minting a duplicate (natural key deviceId+markerKey+takenAt+source). Plain day arithmetic, so no calendar,
    /// locale or time zone (and no skipped local midnight) can move it. 0 only for a genuinely unreadable day string.
    /// History dates render from the stored `day` string, not this takenAt.
    static func noonEpoch(_ day: String) -> Int {
        guard let number = ExploreDayKey.dayNumber(for: day) else { return 0 }
        return number * 86_400 + 12 * 3600
    }
}

// MARK: - Trailing window control (7 / 14 / 30 days)

enum LabWindow: String, CaseIterable, Identifiable {
    case week, fortnight, month
    var id: String { rawValue }
    var label: String {
        switch self {
        case .week:      return String(localized: "7d")
        case .fortnight: return String(localized: "14d")
        case .month:     return String(localized: "30d")
        }
    }
    var days: Int {
        switch self {
        case .week:      return 7
        case .fortnight: return 14
        case .month:     return 30
        }
    }
    var phrase: String {
        switch self {
        case .week:      return String(localized: "7 days")
        case .fortnight: return String(localized: "14 days")
        case .month:     return String(localized: "30 days")
        }
    }
}

// MARK: - Wearable signals offered for correlation + the shared insight language
//
// The pickable wearable metrics + the restrained correlation copy. The strength word, its colour and the signed number
// are `CorrelationStrength`'s, the one rule Compare and the Metric Explorer read too; only the markers' sentences live
// here, plus the mandatory markers clause.

enum LabBookSignals {
    /// The reading-count floor below which NO conclusion sentence renders (spec default 4).
    static let floor = 4

    /// The wearable metrics offered to pair a marker against. Strap-source keys read through the
    /// Explore freshest-wins path; weight resolves from Apple/Health-Connect/strap as available.
    static let options: [MetricDescriptor] = [
        descriptor("rhr"),
        descriptor("hrv"),
        descriptor("recovery"),
        descriptor("sleep_performance"),
        descriptor("sleep_total_min"),
        descriptor("strain"),
        descriptor("skin_temp"),
        descriptor("steps"),
        descriptor("weight"),
    ].compactMap { $0 }

    private static func descriptor(_ key: String) -> MetricDescriptor? {
        MetricCatalog.all.first { $0.key == key }
    }

    /// "When LDL is higher, HRV tends to be lower." — descriptive, no causal language. A relationship is worth a sentence
    /// from "moderate" up, by the shared rule (applied to r as printed). Whole-phrase variants per direction so
    /// translators never see a stitched verb fragment; the names are shown as they are.
    static func insightSentence(markerName: String, signalName: String, r: Double) -> String {
        guard CorrelationStrength(r: r).isNotable else {
            return String(localized: "Over your readings, \(markerName) and \(signalName) move largely independently. No clear relationship.")
        }
        return r < 0
            ? String(localized: "When \(markerName) is higher, \(signalName) tends to be lower.")
            : String(localized: "When \(markerName) is higher, \(signalName) tends to be higher.")
    }

    /// The mandatory markers clause under a relationship (spec §"On-device algorithm"): how many readings it rests on,
    /// the strength, and that it is association, not a finding.
    static func associationClause(n: Int, r: Double) -> String {
        let strength = CorrelationStrength(r: r)
        guard strength != .negligible else {
            return String(localized: "\(n) readings used · \(strength.word) association. This is your own data sitting side by side. It's not a medical finding, and it shows association, not cause.")
        }
        let direction = r >= 0 ? String(localized: "positive") : String(localized: "negative")
        return String(localized: "\(n) readings used · \(strength.word) \(direction) association. This is your own data sitting side by side. It's not a medical finding, and it shows association, not cause.")
    }
}

#if DEBUG
@MainActor
private func labBookPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Lab Book") {
    LabBookView()
        .environmentObject(labBookPreviewRepo())
        .environmentObject(LiveState())
        .frame(width: 920, height: 860)
        .preferredColorScheme(.dark)
}
#endif
