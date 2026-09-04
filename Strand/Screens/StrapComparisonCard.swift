import Foundation
import NoopPhase34Core
import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

struct StrapComparisonSnapshot: Equatable, Sendable {
    let firstDeviceId: String
    let firstName: String
    let secondDeviceId: String
    let secondName: String
    let day: String
    let rows: [StrapComparison.Row]
}

enum StrapComparisonEmptyReason: Equatable, Sendable {
    case needsSecondDevice
    case noSharedDay(firstName: String, secondName: String)
    case noComparableMetrics(day: String, firstName: String, secondName: String)
}

enum StrapComparisonLoadOutcome: Equatable, Sendable {
    case snapshot(StrapComparisonSnapshot)
    case empty(StrapComparisonEmptyReason)
}

/// A small, read-only seam between the Devices screen and the indexed daily-metric store read.
/// It deliberately keeps each `PairedDevice.id` intact: comparison never resolves, aliases, merges,
/// or writes either source.
enum StrapComparisonDataLoader {
    static let lookbackDays = 30

    struct DayWindow: Equatable, Sendable {
        let fromDay: String
        let toDay: String
    }

    typealias DailyMetricReader = @Sendable (
        _ deviceId: String,
        _ fromDay: String,
        _ toDay: String
    ) async throws -> [DailyMetric]

    static func comparableDevices(_ devices: [PairedDevice]) -> [PairedDevice] {
        devices
            .filter { device in
                device.status != .archived
                    && !device.isImportSource
                    && (isWhoop(device) || device.sourceKind == .oura)
            }
            .sorted { lhs, rhs in
                let lhsStatus = statusRank(lhs.status)
                let rhsStatus = statusRank(rhs.status)
                if lhsStatus != rhsStatus { return lhsStatus < rhsStatus }
                if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
                return lhs.id < rhs.id
            }
    }

    static func dayWindow(
        endingAt date: Date = Date(),
        calendar sourceCalendar: Calendar = .current
    ) -> DayWindow {
        let calendar = sourceCalendar
        let end = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .day, value: -(lookbackDays - 1), to: end) ?? end
        return DayWindow(fromDay: dayKey(start, calendar: calendar),
                         toDay: dayKey(end, calendar: calendar))
    }

    static func load(
        devices: [PairedDevice],
        fromDay: String,
        toDay: String,
        readDailyMetrics: DailyMetricReader
    ) async throws -> StrapComparisonLoadOutcome {
        let candidates = comparableDevices(devices)
        guard candidates.count >= 2 else { return .empty(.needsSecondDevice) }

        let first = candidates[0]
        let second = candidates[1]
        async let firstLoad = mergedDailyMetrics(
            deviceId: first.id,
            fromDay: fromDay,
            toDay: toDay,
            readDailyMetrics: readDailyMetrics
        )
        async let secondLoad = mergedDailyMetrics(
            deviceId: second.id,
            fromDay: fromDay,
            toDay: toDay,
            readDailyMetrics: readDailyMetrics
        )
        let (firstRows, secondRows) = try await (firstLoad, secondLoad)

        let firstByDay = rowsByDay(firstRows, fromDay: fromDay, toDay: toDay)
        let secondByDay = rowsByDay(secondRows, fromDay: fromDay, toDay: toDay)
        let sharedDays = Set(firstByDay.keys)
            .intersection(secondByDay.keys)
            .sorted(by: >)
        guard let newestSharedDay = sharedDays.first else {
            return .empty(.noSharedDay(firstName: first.displayName,
                                       secondName: second.displayName))
        }

        for sharedDay in sharedDays {
            guard let firstMetric = firstByDay[sharedDay],
                  let secondMetric = secondByDay[sharedDay]
            else { continue }

            let rows = StrapComparison.compare(metricValues(firstMetric), metricValues(secondMetric))
            guard !rows.isEmpty else { continue }

            return .snapshot(StrapComparisonSnapshot(
                firstDeviceId: first.id,
                firstName: first.displayName,
                secondDeviceId: second.id,
                secondName: second.displayName,
                day: sharedDay,
                rows: rows
            ))
        }

        return .empty(.noComparableMetrics(day: newestSharedDay,
                                           firstName: first.displayName,
                                           secondName: second.displayName))
    }

    /// One physical device owns a raw/imported namespace and a `-noop` computed sibling. Compare the
    /// physical source's complete daily record while keeping its raw id as the card identity. Imported
    /// fields win and locally analyzed fields fill only gaps, matching Repository's normal source merge.
    static func mergedDailyMetrics(
        deviceId: String,
        fromDay: String,
        toDay: String,
        readDailyMetrics: DailyMetricReader
    ) async throws -> [DailyMetric] {
        let computedId = ExactAnalysisNamespace.defaultComputedDeviceId(forRawDeviceId: deviceId)
        async let importedLoad = readDailyMetrics(deviceId, fromDay, toDay)
        async let computedLoad = readDailyMetrics(computedId, fromDay, toDay)
        let (imported, computed) = try await (importedLoad, computedLoad)
        return Repository.mergeDaily(imported: imported, computed: computed)
    }

    static func metricValues(
        _ metric: DailyMetric
    ) -> [MetricArbitrationPolicy.MetricKind: Double] {
        var values: [MetricArbitrationPolicy.MetricKind: Double] = [:]
        if let value = metric.restingHr { values[.restingHR] = Double(value) }
        if let value = metric.avgHrv { values[.hrv] = value }
        if let value = metric.spo2Pct { values[.spo2] = value }
        if let value = metric.skinTempDevC { values[.skinTemp] = value }
        if let value = metric.steps { values[.steps] = Double(value) }
        if let value = metric.totalSleepMin { values[.sleep] = value }
        if let value = metric.activeKcalEst { values[.calories] = value }
        return values
    }

    private static func isWhoop(_ device: PairedDevice) -> Bool {
        device.id == "my-whoop"
            || device.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
    }

    private static func statusRank(_ status: DeviceStatus) -> Int {
        switch status {
        case .active: 0
        case .paired: 1
        case .archived: 2
        }
    }

    private static func rowsByDay(
        _ rows: [DailyMetric],
        fromDay: String,
        toDay: String
    ) -> [String: DailyMetric] {
        Dictionary(
            rows
                .filter { $0.day >= fromDay && $0.day <= toDay }
                .map { ($0.day, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 0,
                      components.month ?? 0,
                      components.day ?? 0)
    }
}

/// Isolated observation leaf. Only this card subscribes to repository refreshes; the surrounding
/// device list remains driven solely by `DeviceRegistry`.
@MainActor
struct StrapComparisonCard: View {
    @ObservedObject private var repository: Repository
    let devices: [PairedDevice]

    @State private var state: LoadState = .loading
    @State private var retryToken = 0

    init(devices: [PairedDevice], repository: Repository) {
        self.devices = devices
        self.repository = repository
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                StrapComparisonMessageCard(
                    symbol: "rectangle.2.swap",
                    title: "Reading recent strap data",
                    message: "NOOP is looking for the latest day both straps recorded.",
                    showsProgress: true
                )

            case .empty(let reason):
                StrapComparisonMessageCard(
                    symbol: emptySymbol(reason),
                    title: emptyTitle(reason),
                    message: emptyMessage(reason)
                )

            case .snapshot(let snapshot):
                StrapComparisonResultCard(snapshot: snapshot)

            case .failed:
                StrapComparisonMessageCard(
                    symbol: "exclamationmark.arrow.triangle.2.circlepath",
                    title: "Comparison unavailable",
                    message: "NOOP could not read recent on-device data. Your scores and source ownership are unchanged.",
                    retry: { retryToken &+= 1 }
                )
            }
        }
        .task(id: loadKey) {
            await load()
        }
    }

    private var loadKey: String {
        let candidateKey = StrapComparisonDataLoader.comparableDevices(devices)
            .prefix(2)
            .map { "\($0.id)|\($0.displayName)|\($0.status.rawValue)|\($0.lastSeenAt)" }
            .joined(separator: ";")
        return "\(repository.refreshSeq)|\(retryToken)|\(candidateKey)"
    }

    private func load() async {
        state = .loading
        let candidates = StrapComparisonDataLoader.comparableDevices(devices)
        guard candidates.count >= 2 else {
            state = .empty(.needsSecondDevice)
            return
        }

        guard let store = await repository.storeHandle() else {
            state = .failed
            return
        }

        let window = StrapComparisonDataLoader.dayWindow()
        do {
            let outcome = try await StrapComparisonDataLoader.load(
                devices: devices,
                fromDay: window.fromDay,
                toDay: window.toDay,
                readDailyMetrics: { deviceId, fromDay, toDay in
                    try await store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay)
                }
            )
            guard !Task.isCancelled else { return }
            switch outcome {
            case .snapshot(let snapshot): state = .snapshot(snapshot)
            case .empty(let reason): state = .empty(reason)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed
        }
    }

    private func emptySymbol(_ reason: StrapComparisonEmptyReason) -> String {
        switch reason {
        case .needsSecondDevice: "rectangle.2.swap"
        case .noSharedDay: "calendar.badge.exclamationmark"
        case .noComparableMetrics: "waveform.path.ecg.rectangle"
        }
    }

    private func emptyTitle(_ reason: StrapComparisonEmptyReason) -> String {
        switch reason {
        case .needsSecondDevice: "Pair a second supported strap"
        case .noSharedDay: "No shared recent day"
        case .noComparableMetrics: "No comparable readings"
        }
    }

    private func emptyMessage(_ reason: StrapComparisonEmptyReason) -> String {
        switch reason {
        case .needsSecondDevice:
            return "Pair a second WHOOP or Oura device to compare daily readings. This view never changes your scores."
        case .noSharedDay(let firstName, let secondName):
            return "\(firstName) and \(secondName) do not both have daily data in the last \(StrapComparisonDataLoader.lookbackDays) days."
        case .noComparableMetrics(let day, let firstName, let secondName):
            return "\(firstName) and \(secondName) recorded \(day), but neither has a supported daily reading to compare."
        }
    }
}

private extension StrapComparisonCard {
    enum LoadState: Equatable {
        case loading
        case empty(StrapComparisonEmptyReason)
        case snapshot(StrapComparisonSnapshot)
        case failed
    }
}

private struct StrapComparisonMessageCard: View {
    let symbol: String
    let title: String
    let message: String
    var showsProgress = false
    var retry: (() -> Void)?

    var body: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(alignment: .center, spacing: NoopMetrics.space2) {
                    Text("STRAP COMPARISON").strandOverline()
                    Spacer(minLength: NoopMetrics.space2)
                    StatePill("READ ONLY", tone: .neutral, showsDot: false)
                }

                HStack(alignment: .top, spacing: NoopMetrics.space3) {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(width: 24)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text(title)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(message)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if showsProgress {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(StrandPalette.accent)
                        .accessibilityLabel("Loading strap comparison")
                }

                if let retry {
                    Button("Try again", action: retry)
                        .buttonStyle(.noopSecondary)
                }
            }
        }
    }
}

private struct StrapComparisonResultCard: View {
    let snapshot: StrapComparisonSnapshot

    var body: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: NoopMetrics.space2) {
                    Text("STRAP COMPARISON").strandOverline()
                    Spacer(minLength: NoopMetrics.space2)
                    StatePill("READ ONLY", tone: .neutral, showsDot: false)
                }

                Text("Latest shared daily data: \(snapshot.day)")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.top, NoopMetrics.space2)

                deviceHeadings
                    .padding(.top, NoopMetrics.space4)
                    .padding(.bottom, NoopMetrics.space2)

                Divider().overlay(StrandPalette.hairline)

                ForEach(Array(snapshot.rows.enumerated()), id: \.offset) { index, row in
                    metricRow(row)
                    if index < snapshot.rows.count - 1 {
                        Divider().overlay(StrandPalette.hairline)
                    }
                }

                Label {
                    Text("Values stay separate. This card does not change source ownership or any NOOP score.")
                } icon: {
                    Image(systemName: "lock.shield")
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, NoopMetrics.space3)
            }
        }
    }

    private var deviceHeadings: some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            deviceHeading("STRAP A", name: snapshot.firstName)
            deviceHeading("STRAP B", name: snapshot.secondName)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Strap A: \(snapshot.firstName). Strap B: \(snapshot.secondName).")
    }

    private func deviceHeading(_ label: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(label)
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(name)
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricRow(_ row: StrapComparison.Row) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .center, spacing: NoopMetrics.space2) {
                Text(StrapComparisonFormat.label(row.metric))
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: NoopMetrics.space2)
                agreementPill(row.agreement)
            }

            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
                metricValue(row.a, kind: row.metric)
                metricValue(row.b, kind: row.metric)
            }
        }
        .padding(.vertical, NoopMetrics.space3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel(row)))
    }

    private func metricValue(
        _ value: Double?,
        kind: MetricArbitrationPolicy.MetricKind
    ) -> some View {
        Text(StrapComparisonFormat.value(value, kind: kind))
            .font(StrandFont.bodyNumber)
            .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func agreementPill(_ agreement: AgreementState) -> some View {
        switch agreement {
        case .single:
            StatePill("ONE READING", tone: .neutral, showsDot: false)
        case .agree:
            StatePill("CLOSE MATCH", tone: .positive, showsDot: false)
        case .minorDelta:
            StatePill("SLIGHT DIFFERENCE", tone: .neutral, showsDot: false)
        case .conflict:
            StatePill("DIFFERENT", tone: .warning, showsDot: true)
        }
    }

    private func accessibilityLabel(_ row: StrapComparison.Row) -> String {
        let metric = StrapComparisonFormat.label(row.metric)
        let first = StrapComparisonFormat.value(row.a, kind: row.metric)
        let second = StrapComparisonFormat.value(row.b, kind: row.metric)
        return "\(metric). \(snapshot.firstName): \(first). \(snapshot.secondName): \(second). \(StrapComparisonFormat.agreement(row.agreement))."
    }
}

enum StrapComparisonFormat {
    static func label(_ kind: MetricArbitrationPolicy.MetricKind) -> String {
        switch kind {
        case .restingHR: "Resting HR"
        case .heartRate: "Heart rate"
        case .hrv: "HRV"
        case .spo2: "Blood oxygen"
        case .skinTemp: "Skin temp change"
        case .steps: "Steps"
        case .sleep: "Sleep"
        case .calories: "Active calories"
        case .other: "Reading"
        }
    }

    static func value(
        _ value: Double?,
        kind: MetricArbitrationPolicy.MetricKind
    ) -> String {
        guard let value, value.isFinite,
              value >= Double(Int.min), value <= Double(Int.max) else { return "No data" }
        switch kind {
        case .restingHR, .heartRate:
            return "\(Int(value.rounded()).formatted()) bpm"
        case .hrv:
            return "\(Int(value.rounded()).formatted()) ms"
        case .spo2:
            return "\(Int(value.rounded()).formatted())%"
        case .skinTemp:
            let prefix = value > 0 ? "+" : ""
            return "\(prefix)\(String(format: "%.1f", value))°C"
        case .steps:
            return Int(value.rounded()).formatted()
        case .sleep:
            return duration(minutes: value)
        case .calories:
            return "\(Int(value.rounded()).formatted()) kcal"
        case .other:
            return value == value.rounded()
                ? Int(value).formatted()
                : String(format: "%.1f", value)
        }
    }

    static func agreement(_ state: AgreementState) -> String {
        switch state {
        case .single: "One reading"
        case .agree: "Close match"
        case .minorDelta: "Slight difference"
        case .conflict: "Different readings"
        }
    }

    private static func duration(minutes: Double) -> String {
        let total = max(0, Int(minutes.rounded()))
        let hours = total / 60
        let minutes = total % 60
        if hours == 0 { return "\(minutes) min" }
        if minutes == 0 { return "\(hours) hr" }
        return "\(hours) hr \(minutes) min"
    }
}
