import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// A saved session, with metric availability determined by its real record.
struct WorkoutDetailView: View {
    let row: WorkoutRow
    var onClose: (() -> Void)? = nil
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var profile = ProfileStore()
    @AppStorage(UnitPrefs.systemKey) private var unitRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.effortScaleKey) private var scaleRaw = EffortScale.whoop.rawValue
    @State private var resolved: WorkoutRow?
    @State private var chart: WorkoutChartProjection?
    @State private var zones: [Double]?
    @State private var importedZones = false
    @State private var route: [[RouteMath.LatLng]] = []
    @State private var loaded = false
    @State private var selectedZone: Int?
    @State private var tab: DetailTab = .overview

    enum DetailTab: String, CaseIterable, Identifiable {
        case overview = "Overview", heartRate = "Heart rate", route = "Route"
        var id: String { rawValue }
    }
    private var record: WorkoutRow { resolved ?? row }
    private var imperial: Bool { unitRaw == UnitSystem.imperial.rawValue }
    private var sport: String { WorkoutSource.displaySport(record.sport) }
    private var duration: Double? {
        WorkoutExperiencePolicy.positive(record.durationS)
            ?? WorkoutExperiencePolicy.positive(Double(record.endTs) - Double(record.startTs))
    }
    private var availableTabs: [DetailTab] {
        [.overview] + ((chart?.points.isEmpty == false) ? [.heartRate] : []) + (route.isEmpty ? [] : [.route])
    }
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 240 : 140), spacing: 12)]
    }

    var body: some View {
        ExperienceScroll {
            sessionHero
            if availableTabs.count > 1 {
                Picker("Session section", selection: $tab) {
                    ForEach(availableTabs) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            switch tab {
            case .overview:
                metrics
                if let chart, !chart.points.isEmpty {
                    WorkoutHeartChart(projection: chart, sourceLabel: "Strap heart rate · Time-bucket averages")
                } else if loaded {
                    ExperienceMessage(title: "Heart-rate trace unavailable",
                                      message: "The stored summary remains available. No trace was returned for this session.",
                                      symbol: "waveform.path.ecg")
                } else {
                    ProgressView("Loading session detail…").frame(maxWidth: .infinity).padding(20)
                }
                if let average = record.avgHr, let readings = chart?.readings, !readings.isEmpty,
                   abs(Double(average) - readings.reduce(0, { $0 + $1.bpm }) / Double(readings.count)) > 3 {
                    Text("The summary average and trace differ. The chart uses strap time-bucket averages; the summary keeps its saved value.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                zoneSection
                WorkoutHeartRateRecoveryCard(workout: record, maxHR: Double(profile.hrMax))
                if !route.isEmpty { routeSection }
                if let notes = record.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    PaperCard {
                        VStack(alignment: .leading, spacing: 10) {
                            ExperienceSectionHeading(title: "Session notes")
                            Text(notes).font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                                .textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            case .heartRate:
                if let chart { WorkoutHeartChart(projection: chart, sourceLabel: "Strap heart rate · Time-bucket averages") }
                zoneSection
            case .route:
                routeSection
            }
        }
        .navigationTitle(sport)
        .noopFocusedTask()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { close() } }
            ToolbarItem(placement: .confirmationAction) {
                ShareLink(item: shareText) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share workout summary")
                    .accessibilityHint("Shares text only. Route coordinates are excluded.")
            }
        }
        .task(id: "\(row.startTs)|\(row.sport)|\(repo.deviceId)") { await load() }
        .refreshable { await load() }
    }

    private var sessionHero: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: WorkoutExperiencePolicy.symbol(for: sport))
                        .font(StrandFont.title2).foregroundStyle(StrandPalette.strainAccent)
                        .frame(width: 48, height: 48)
                        .background(StrandPalette.strainAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sport).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                        Text(start.formatted(date: .abbreviated, time: .shortened))
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 24) { durationHero; Spacer(minLength: 0); strainHero }
                    VStack(alignment: .leading, spacing: 16) { durationHero; strainHero }
                }
                Divider().overlay(StrandPalette.hairline)
                Label(sourceName, systemImage: "checkmark.circle")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private var durationHero: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(duration.map(WorkoutExperiencePolicy.elapsed) ?? "—")
                .font(StrandFont.timer).monospacedDigit().foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text("Session duration").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var strainHero: some View {
        if let stored = StrainResolver.canonicalWorkout(record)?.storedValue, stored.isFinite {
            let value = UnitFormatter.effortValue(stored, scale: UnitPrefs.resolveEffortScale(scaleRaw))
            VStack(spacing: 8) {
                ScoreRing(value: value, range: 0...21, accent: StrandPalette.strainAccent,
                          size: 88, lineWidth: 7,
                          format: { _ in UnitFormatter.effortDisplay(stored, scale: UnitPrefs.resolveEffortScale(scaleRaw)) },
                          centerCaption: nil)
                Text("Session strain").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private var metrics: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            if let value = WorkoutExperiencePolicy.distance(record.distanceM, imperial: imperial) {
                ExperienceMetricTile(label: value.label, value: value.value, unit: value.unit, symbol: "location")
                if let rate = WorkoutExperiencePolicy.rate(sport: sport, meters: record.distanceM,
                                                           seconds: duration, imperial: imperial) {
                    ExperienceMetricTile(label: rate.label, value: rate.value, unit: rate.unit, symbol: "speedometer")
                }
            }
            if let hr = record.avgHr, (30...300).contains(hr) {
                ExperienceMetricTile(label: "Average heart rate", value: "\(hr)", unit: "bpm",
                                     tint: StrandPalette.liveRed, symbol: "heart")
            }
            if let hr = record.maxHr, (30...300).contains(hr) {
                ExperienceMetricTile(label: "Peak heart rate", value: "\(hr)", unit: "bpm",
                                     tint: StrandPalette.liveRed, symbol: "arrow.up.heart")
            }
            if let energy = WorkoutExperiencePolicy.positive(record.energyKcal) {
                ExperienceMetricTile(label: "Recorded energy", value: energy.formatted(.number.precision(.fractionLength(0))),
                                     unit: "kcal", symbol: "flame")
            }
        }
    }

    @ViewBuilder private var zoneSection: some View {
        if let zones = WorkoutExperiencePolicy.validZones(zones) {
            let total = zones.reduce(0, +)
            PaperCard {
                VStack(alignment: .leading, spacing: 16) {
                    ExperienceSectionHeading(title: "Time in heart-rate zones", detail: importedZones
                        ? "Recorded zone split · Imported with this session"
                        : "Estimated from strap readings · Age-based maximum heart rate")
                    ForEach(zones.indices, id: \.self) { index in
                        let fraction = zones[index] / total
                        Button { selectedZone = selectedZone == index ? nil : index } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Zone \(index + 1)").font(StrandFont.body)
                                    Spacer()
                                    Text(WorkoutExperiencePolicy.elapsed(zones[index] * 60)).monospacedDigit()
                                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                                        .monospacedDigit().foregroundStyle(StrandPalette.textSecondary)
                                }
                                ProgressView(value: fraction).tint(StrandPalette.hrZoneColor(index + 1))
                                if selectedZone == index {
                                    Text(importedZones
                                         ? "This duration comes from the session’s recorded zone percentages."
                                         : "Estimated time within this age-based heart-rate zone. Gaps may reduce measured coverage.")
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .foregroundStyle(StrandPalette.textPrimary)
                            .padding(.vertical, 8).frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Zone \(index + 1), \(WorkoutExperiencePolicy.elapsed(zones[index] * 60)), \(Int((fraction * 100).rounded())) percent")
                        .accessibilityHint("Shows how this duration was calculated")
                    }
                    Text("Percentages use recorded zone time. Time without a zone value is excluded.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    @ViewBuilder private var routeSection: some View {
        if !route.isEmpty {
            PaperCard {
                VStack(alignment: .leading, spacing: 12) {
                    ExperienceSectionHeading(title: "Recorded route", detail: "Pinch to zoom · Drag to explore")
                    WorkoutRouteMap(segments: route)
                        .frame(height: 280).clipShape(RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel("Recorded \(sport) route with start and finish markers")
                    Text("Separate route segments remain separate. Map tiles may require a network connection.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private var start: Date { Date(timeIntervalSince1970: Double(record.startTs)) }
    private var sourceName: String {
        switch WorkoutSource.classify(record.source) {
        case .whoop: "WHOOP import"
        case .apple: "Apple Health"
        case .manual: "Saved in NOOP"
        case .detected: "Detected session"
        case .lifting: "Imported strength session"
        case .activityFile: "Imported activity file"
        }
    }
    private var shareText: String {
        var lines = ["\(sport) · NOOP", start.formatted(date: .abbreviated, time: .shortened)]
        if let duration { lines.append("Duration: \(WorkoutExperiencePolicy.elapsed(duration))") }
        if let distance = WorkoutExperiencePolicy.distance(record.distanceM, imperial: imperial) {
            lines.append("Distance: \(distance.value) \(distance.unit)")
        }
        if let hr = record.avgHr, (30...300).contains(hr) { lines.append("Average heart rate: \(hr) bpm") }
        return lines.joined(separator: "\n")
    }
    private func close() { if let onClose { onClose() } else { dismiss() } }

    @MainActor private func load() async {
        let source = repo.deviceId
        guard row.startTs >= 0, row.endTs >= row.startTs,
              row.startTs < Int.max - 61, row.endTs < Int.max - 61 else {
            loaded = true
            return
        }
        let lower = max(0, row.startTs - 60)
        let upper = max(row.endTs, row.startTs + 1) + 60
        let rows = await repo.workoutRows(from: lower, to: upper)
        guard !Task.isCancelled, repo.deviceId == source else { return }
        let target = rows.first { $0.startTs == row.startTs && $0.sport == row.sport } ?? row
        resolved = target
        guard target.startTs >= 0, target.endTs > target.startTs else {
            loaded = true
            return
        }
        let buckets = await repo.workoutHrBuckets(from: target.startTs, to: target.endTs)
        let samples = buckets.map { WorkoutChartSample(time: Date(timeIntervalSince1970: Double($0.ts)), bpm: $0.bpm) }
        let start = Date(timeIntervalSince1970: Double(target.startTs))
        let end = Date(timeIntervalSince1970: Double(target.endTs))
        // The repository supplies time-bucket averages. Do not describe these as raw beat samples.
        let bucketSeconds = max(15, min(300, max(1, target.endTs - target.startTs) / 120))
        let spacing = Double(bucketSeconds) * 1.5
        let projection = await Task.detached(priority: .userInitiated) {
            WorkoutChartProjection(samples: samples, start: start, end: end, gapThreshold: spacing)
        }.value
        var minutes: [Double]?
        var fromImport = false
        if let percentages = WorkoutZones.percents(target.zonesJSON),
           let seconds = WorkoutExperiencePolicy.positive(target.durationS)
            ?? WorkoutExperiencePolicy.positive(Double(target.endTs) - Double(target.startTs)) {
            minutes = WorkoutExperiencePolicy.validZones(percentages.map { seconds / 60 * $0 / 100 })
            fromImport = minutes != nil
        }
        if minutes == nil {
            minutes = await repo.workoutZoneMinutes(from: target.startTs, to: target.endTs, age: profile.age)
        }
        guard !Task.isCancelled, repo.deviceId == source else { return }
        chart = projection
        zones = WorkoutExperiencePolicy.validZones(minutes)
        importedZones = fromImport
        route = RouteStore.load(startTs: target.startTs, sport: target.sport)?.decodedSegments.filter { $0.count >= 2 } ?? []
        loaded = true
        if !availableTabs.contains(tab) { tab = .overview }
    }
}
