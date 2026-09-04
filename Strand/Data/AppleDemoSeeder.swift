#if DEBUG
import Foundation
import StrandAnalytics
import WhoopStore
import WhoopProtocol

// MARK: - DEBUG-only demo seed (Apple parity with Android's DemoSeeder)
// Seeds a comprehensive, self-contained synthetic dataset so a DEBUG build can walk every screen —
// Today, Sleep, Trends, Workouts, Health, Stress, Insights, Explore — with no strap and no import.
// This is the Apple twin of `android/.../data/DemoSeeder.kt` (same RNG seed, same physiology, same
// 120-day window) and exists so we can render iOS + macOS for verification and marketing screenshots.
//
// Gating: the whole file is `#if DEBUG`, so it is stripped from every Release build (the shipped
// app). At runtime it only seeds when launched with `--demo-seed` AND the store has no daily rows,
// so it runs at most once and never clobbers real data. Everything here is SYNTHETIC and
// DETERMINISTIC (fixed seed) — nothing is real biometric data. Values are physiologically plausible
// and internally correlated (recovery ↔ HRV ↔ resting-HR ↔ sleep; strain ↔ workouts; a slow fitness
// drift) so the charts, trends and insights all read like a real account.
enum AppleDemoSeeder {

    /// Bump when the fixture shape changes. The simulator demo uses this in its
    /// database filename, so a newer fixture never gets trapped behind an older,
    /// partially-seeded database.
    static let fixtureVersion = 4
    static var databaseFilename: String { "whoop-demo-v\(fixtureVersion).sqlite" }

    private enum Scenario: String {
        case healthy, illness
    }

    static let whoop = "my-whoop"
    static let apple = "apple-health"
    static let comparisonOura = "oura-ring-4-demo"
    private static let DAYS = 120
    /// Effort rescale factor: the old 0–21 strain scale → the new 0–100 Effort scale.
    private static let STRAIN_SCALE = 100.0 / 21.0

    private static let SPORTS = [
        "Running", "Cycling", "Strength", "HIIT", "Swimming", "Yoga", "Walking", "Rowing",
    ]
    private static let DISTANCE_SPORTS: Set<String> = ["Running", "Cycling", "Walking", "Swimming", "Rowing"]

    /// True when the process was launched asking for the demo seed (Xcode scheme arg or `simctl
    /// launch … --demo-seed`).
    static var requested: Bool {
        #if targetEnvironment(simulator)
        isSeedRequested(arguments: CommandLine.arguments, isSimulator: true)
        #else
        // Even a DEBUG-signed build on a real phone must never enter demo mode.
        isSeedRequested(arguments: CommandLine.arguments, isSimulator: false)
        #endif
    }

    /// Narrow launch route for deterministic visual proof of the real Devices screen. It is accepted
    /// only together with the simulator-only demo seed, so neither ordinary Debug use nor a real phone
    /// can bypass the production navigation shell.
    static var devicesQARequested: Bool {
        #if targetEnvironment(simulator)
        isDevicesQARequested(arguments: CommandLine.arguments, isSimulator: true)
        #else
        false
        #endif
    }

    static func isSeedRequested(arguments: [String], isSimulator: Bool) -> Bool {
        isSimulator && arguments.contains("--demo-seed")
    }

    static func isDevicesQARequested(arguments: [String], isSimulator: Bool) -> Bool {
        isSeedRequested(arguments: arguments, isSimulator: isSimulator)
            && arguments.contains("--demo-devices-qa")
    }

    /// F7: evidence launches default to a healthy populated day. The prior illness
    /// fixture remains available explicitly via `--demo-scenario illness`.
    private static var scenario: Scenario {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--demo-scenario"), index + 1 < args.count else {
            return .healthy
        }
        return Scenario(rawValue: args[index + 1].lowercased()) ?? .healthy
    }

    /// Seed only if requested AND the store is empty. Safe to call on every launch.
    static func seedIfRequested(into store: WhoopStore) async {
        guard requested else { return }
        seedDemoPreferences()
        seedDemoDevicesIfNeeded(into: store)
        let auditFormatter = DateFormatter()
        auditFormatter.locale = Locale(identifier: "en_US_POSIX")
        auditFormatter.timeZone = .current
        auditFormatter.dateFormat = "yyyy-MM-dd"
        try? await seedCleanupAuditFixtures(into: store, calendar: .current, formatter: auditFormatter)
        let existing = (try? await store.dailyMetrics(deviceId: whoop, from: "0000-00-00", to: "9999-99-99")) ?? []
        guard existing.isEmpty else { return }
        do { try await seed(into: store) }
        catch { NSLog("AppleDemoSeeder: seed failed — \(error)") }
    }

    /// Audit-only preferences that unlock low-risk conditional surfaces. Pre-sleep HR is deliberately
    /// absent: consent is a production preference, and demo launches must not persist an opt-in that a
    /// later ordinary launch could apply to the normal database.
    static func seedDemoPreferences(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: HydrationStore.enabledKey)
        defaults.set(true, forKey: "behavior.illnessWatch")
        defaults.set(
            DashboardCardPrefs.encode(DashboardCard.defaultSelection + [.hydration]),
            forKey: DashboardCardPrefs.selectionKey)
    }

    /// Demo screenshots may render the pre-sleep card without mutating consent. Callers pass the stored
    /// production choice separately, so a demo-to-normal relaunch immediately falls back to that choice.
    static func effectivePreSleepFeedbackEnabled(userOptIn: Bool, demoRequested: Bool) -> Bool {
        userOptIn || demoRequested
    }

    /// DEBUG/demo-only device inventory. Polar keeps the existing generic-strap coverage. The Oura row
    /// is a second independently-keyed, comparison-capable source with real daily rows seeded below.
    /// Both remain `.paired`, so the canonical WHOOP stays active and no source transition can start.
    private static func seedDemoDevicesIfNeeded(into store: WhoopStore) {
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        guard let devices = try? registry.all() else { return }
        let ids = Set(devices.map(\.id))
        let now = Int(Date().timeIntervalSince1970)
        if !ids.contains("polar-h10-demo") {
            let polar = PairedDevice(
                id: "polar-h10-demo", brand: "Polar", model: "H10", nickname: nil,
                sourceKind: .liveBLE, capabilities: [.hr, .hrv], status: .paired,
                addedAt: now - 2 * 24 * 60 * 60, lastSeenAt: now - 3_600)
            try? registry.add(polar)
        }
        if !ids.contains(comparisonOura) {
            let oura = PairedDevice(
                id: comparisonOura, brand: "Oura", model: "Oura Ring 4", nickname: nil,
                sourceKind: .oura, capabilities: [.hr, .hrv, .spo2, .skinTemp, .sleep],
                status: .paired, addedAt: now - 24 * 60 * 60, lastSeenAt: now - 900)
            try? registry.add(oura)
        }
    }

    private static func seed(into store: WhoopStore) async throws {
        var rng = SplitMix64(seed: 0xC0FFEE)
        let cal = Calendar.current
        let zone = TimeZone.current
        let startDay = cal.date(byAdding: .day, value: -(DAYS - 1), to: cal.startOfDay(for: Date()))!

        try? await store.upsertDevice(id: whoop, mac: nil, name: "WHOOP (demo)")

        var daily: [DailyMetric] = []
        var sleeps: [CachedSleepSession] = []
        var series: [MetricPoint] = []
        var appleRows: [AppleDaily] = []
        var workouts: [WorkoutRow] = []
        var journal: [JournalEntry] = []

        var weight = 79.5
        var fitness = 0.0  // slow upward drift: HRV rises, resting-HR falls, VO2max climbs

        let isoFmt = DateFormatter()
        isoFmt.locale = Locale(identifier: "en_US_POSIX")
        isoFmt.timeZone = zone
        isoFmt.dateFormat = "yyyy-MM-dd"

        for i in 0..<DAYS {
            let date = cal.date(byAdding: .day, value: i, to: startDay)!
            let day = isoFmt.string(from: date)
            let weekday = cal.component(.weekday, from: date)  // 1=Sun … 7=Sat
            let weekend = (weekday == 1 || weekday == 7)
            fitness += 0.012
            // F5 evidence fixture: keep the deterministic account physiologically alive. The
            // slow wave prevents ruler-straight baselines; periodic fatigue days create the
            // recovery dips / RHR spikes a real 120-day history contains. DEBUG-only seed data.
            let autonomicWave = Foundation.sin(Double(i) / 3.7)
            let fatigueDay = i % 19 == 7

            // --- training load for the day ---
            let trains = weekend ? rng.nextDouble() < 0.40 : rng.nextDouble() < 0.62
            let nWorkouts = !trains ? 0 : (rng.nextDouble() < 0.22 ? 2 : 1)

            // --- sleep architecture ---
            let totalSleep = gauss(&rng, 430.0, 35.0).clamped(300.0, 540.0)
            let efficiency = gauss(&rng, 89.0, 4.0).clamped(72.0, 98.0)
            let deep = (totalSleep * gauss(&rng, 0.20, 0.03)).clamped(35.0, 130.0)
            let rem = (totalSleep * gauss(&rng, 0.23, 0.03)).clamped(45.0, 150.0)
            let light = (totalSleep - deep - rem).atLeast(60.0)
            let disturbances = Int(gauss(&rng, 6.0, 3.0).clamped(0.0, 18.0))

            // --- autonomic markers ---
            let hrv = (gauss(&rng, 78.0 + fitness * 1.5 + autonomicWave * 5.0, 12.0)
                + (weekend ? 6 : 0) - Double(nWorkouts) * 4 - (fatigueDay ? 16 : 0))
                .clamped(28.0, 150.0)
            let rhr = Int((gauss(&rng, 56.0 - fitness * 0.4 - autonomicWave * 1.8, 3.0)
                + Double(nWorkouts) * 1.2 + (fatigueDay ? 6 : 0)).clamped(42.0, 74.0))
            let spo2 = gauss(&rng, 96.5, 0.8).clamped(93.0, 100.0)
            let skinTempDev = (gauss(&rng, 0.0, 0.25) + (fatigueDay ? 0.45 : 0)).clamped(-1.2, 1.4)
            let resp = (gauss(&rng, 14.6, 0.9) + (fatigueDay ? 1.3 : 0)).clamped(11.0, 19.0)

            // --- recovery: a function of HRV, sleep quality and resting-HR ---
            let recovery = (
                40 + (hrv - 70) * 0.55 + (efficiency - 85) * 0.6 + (totalSleep - 420) * 0.03 -
                    (Double(rhr) - 55) * 1.4 - Double(disturbances) * 0.8
                    - (fatigueDay ? 8 : 0) + gauss(&rng, 0.0, 5.0)
            ).clamped(8.0, 99.0)

            // --- strain (Effort): workout-driven, rescaled 0–21 → 0–100 ---
            let strain = (
                (nWorkouts == 0 ? gauss(&rng, 7.5, 1.8)
                 : gauss(&rng, 13.5, 2.4) + Double(nWorkouts - 1) * 2.5) * STRAIN_SCALE
            ).clamped(3.0 * STRAIN_SCALE, 100.0)

            daily.append(DailyMetric(
                day: day, totalSleepMin: round1(totalSleep), efficiency: round1(efficiency),
                deepMin: round1(deep), remMin: round1(rem), lightMin: round1(light),
                disturbances: disturbances, restingHr: rhr, avgHrv: round1(hrv),
                recovery: round1(recovery), strain: round1(strain), exerciseCount: nWorkouts,
                spo2Pct: round1(spo2), skinTempDevC: round2(skinTempDev), respRateBpm: round1(resp)))

            // --- sleep session: previous night ~23:10 → wake, with a REAL stage timeline so the
            //     hypnogram renders the computed segment path (not just the proportional bar). ---
            let onsetBase = cal.date(byAdding: .day, value: -1, to: date)!
            let onsetDay = cal.startOfDay(for: onsetBase)
            let onset = Int(onsetDay.timeIntervalSince1970) + 23 * 3600 + 10 * 60 + rng.nextInt(-1800, 1800)
            let inBedSec = Int((totalSleep + totalSleep * (100 - efficiency) / 100) * 60)
            sleeps.append(CachedSleepSession(
                startTs: onset, endTs: onset + inBedSec,
                efficiency: round1(efficiency), restingHr: rhr, avgHrv: round1(hrv),
                stagesJSON: segmentsJSON(onset: onset, deep: deep, rem: rem, light: light,
                                         awakeMin: Double(disturbances) * 1.6)))

            // --- long-format extras (body composition) under my-whoop ---
            weight += gauss(&rng, -0.02, 0.18)
            series.append(MetricPoint(day: day, key: "weightKg", value: round2(weight)))
            series.append(MetricPoint(day: day, key: "bodyFatPct",
                value: round1((18.0 - fitness * 0.2 + gauss(&rng, 0.0, 0.4)).clamped(10.0, 24.0))))
            // Export-verbatim sleep figures (same metricSeries keys the importers write), so the demo
            // Sleep tiles exercise the prefer-imported path.
            let demoNeedMin = (totalSleep + gauss(&rng, 25.0, 20.0)).clamped(420.0, 560.0)
            series.append(MetricPoint(day: day, key: "sleep_performance",
                value: round1(min(totalSleep / demoNeedMin * 100.0, 100.0))))
            series.append(MetricPoint(day: day, key: "sleep_consistency",
                value: round1(gauss(&rng, 80.0, 8.0).clamped(40.0, 100.0))))
            series.append(MetricPoint(day: day, key: "sleep_need_min", value: round1(demoNeedMin)))
            series.append(MetricPoint(day: day, key: "sleep_debt_min",
                value: round1((demoNeedMin - totalSleep).atLeast(0.0))))

            // --- Apple Health daily aggregate ---
            let steps = Int(gauss(&rng, 8500.0, 2600.0).clamped(1200.0, 19000.0))
            appleRows.append(AppleDaily(
                day: day, steps: steps,
                activeKcal: round1((Double(steps) * 0.045 + Double(nWorkouts) * 220).clamped(120.0, 1400.0)),
                basalKcal: round1(gauss(&rng, 1650.0, 40.0)),
                vo2max: round1((46 + fitness * 0.3 + gauss(&rng, 0.0, 0.5)).clamped(38.0, 56.0)),
                avgHr: Int(gauss(&rng, 72.0, 5.0)), maxHr: Int(gauss(&rng, 150.0, 12.0)),
                walkingHr: Int(gauss(&rng, 108.0, 6.0)), weightKg: round2(weight)))

            // --- workouts on training days ---
            for k in 0..<nWorkouts {
                let sport = SPORTS[rng.nextInt(0, SPORTS.count)]
                let durSec = gauss(&rng, 48.0, 16.0).clamped(18.0, 110.0) * 60
                let hour = weekend ? 9 : 18
                let dayStart = cal.startOfDay(for: date)
                let start = Int(dayStart.timeIntervalSince1970) + hour * 3600 + rng.nextInt(0, 50) * 60 + k * 3600
                let avg = Int(gauss(&rng, 138.0, 12.0))
                // T84 screenshot contract: the latest seeded workout must carry the same
                // imported zone split as a real WHOOP workout so Strain detail and the
                // post-run summary can prove their engine-derived bpm boundaries. Older
                // rows keep the deterministic WHOOP/Apple mix.
                let src = i == DAYS - 1 ? whoop : (rng.nextDouble() < 0.7 ? whoop : apple)
                let zonesJSON: String? = src == whoop ? {
                    let z = [gauss(&rng, 15.0, 5.0), gauss(&rng, 30.0, 8.0), gauss(&rng, 28.0, 8.0),
                             gauss(&rng, 15.0, 6.0), gauss(&rng, 6.0, 3.0)].map { $0.clamped(0.0, 100.0) }
                    return "{\"zone1\":\(round1(z[0])),\"zone2\":\(round1(z[1])),\"zone3\":\(round1(z[2])),\"zone4\":\(round1(z[3])),\"zone5\":\(round1(z[4]))}"
                }() : nil
                workouts.append(WorkoutRow(
                    startTs: start, endTs: start + Int(durSec), sport: sport, source: src,
                    durationS: round1(durSec),
                    energyKcal: round1((durSec / 60) * gauss(&rng, 9.0, 2.0)),
                    avgHr: avg, maxHr: avg + Int(gauss(&rng, 22.0, 6.0)),
                    strain: round1((strain * gauss(&rng, 0.6, 0.1)).clamped(4.0 * STRAIN_SCALE, 100.0)),
                    distanceM: DISTANCE_SPORTS.contains(sport) ? round1(gauss(&rng, 6500.0, 2500.0).atLeast(500.0)) : nil,
                    zonesJSON: zonesJSON, notes: nil))
            }

            // --- journal answers for the recent 40 days (real catalog strings → Insights light up) ---
            if i >= DAYS - 40 {
                journal.append(JournalEntry(day: day, question: "Did you drink any alcohol?", answeredYes: rng.nextDouble() < 0.18, notes: nil))
                journal.append(JournalEntry(day: day, question: "Did you have caffeine late in the day?", answeredYes: rng.nextDouble() < 0.30, notes: nil))
                journal.append(JournalEntry(day: day, question: "Did you feel stressed?", answeredYes: rng.nextDouble() < 0.28, notes: nil))
            }
        }

        // The cleanup illness surface is opt-in now; healthy is the F7 screenshot default.
        if scenario == .illness {
            for index in daily.indices.suffix(2) {
                let row = daily[index]
                daily[index] = DailyMetric(
                    day: row.day, totalSleepMin: row.totalSleepMin, efficiency: row.efficiency,
                    deepMin: row.deepMin, remMin: row.remMin, lightMin: row.lightMin,
                    disturbances: row.disturbances, restingHr: 72, avgHrv: 34,
                    recovery: 24, strain: row.strain, exerciseCount: row.exerciseCount,
                    spo2Pct: row.spo2Pct, skinTempDevC: 0.9, respRateBpm: 18.8,
                    steps: row.steps, activeKcalEst: row.activeKcalEst)
            }
        }

        // --- weekly Fitness Age + VO2max estimate (the engine stamps these on each week's
        //     Saturday; mirror that here so the Fitness Age screen renders under --demo-seed).
        //     Trends from ~42 → ~36 (younger) as the demo "fitness" drift climbs; vo2max ~44 → ~50.
        var fitnessAge = 42.0
        var vo2 = 44.0
        var vitality = 55.0      // weekly Vitality (0–100) trending up as the demo habits improve
        var bodyAgeDemo = 40.0   // Body Age (years) trending down (younger)
        for i in 0..<DAYS {
            let date = cal.date(byAdding: .day, value: i, to: startDay)!
            guard cal.component(.weekday, from: date) == 7 else { continue }  // 7 = Saturday
            let day = isoFmt.string(from: date)
            series.append(MetricPoint(day: day, key: "fitness_age",
                value: round1((fitnessAge + gauss(&rng, 0.0, 0.3)).clamped(34.0, 44.0))))
            series.append(MetricPoint(day: day, key: "vo2max_est",
                value: round1((vo2 + gauss(&rng, 0.0, 0.4)).clamped(42.0, 52.0))))
            series.append(MetricPoint(day: day, key: "vitality",
                value: round1((vitality + gauss(&rng, 0.0, 1.0)).clamped(40.0, 80.0))))
            series.append(MetricPoint(day: day, key: "body_age",
                value: round1((bodyAgeDemo + gauss(&rng, 0.0, 0.3)).clamped(30.0, 45.0))))
            fitnessAge -= 0.75  // ~6 yr younger across the 8 seeded Saturdays
            vo2 += 0.75
            vitality += 2.0
            bodyAgeDemo -= 0.6
        }

        // Ryan reconciliation QA: bank continuous minute-level HR across the latest 15 nights and
        // every waking interval between them. The latest prior-main → current-main window therefore
        // has complete SQL buckets for the Sleep contrast card, while the earlier nights provide enough
        // genuine raw pre-sleep windows for the opt-in analysis baseline to rebuild deterministically.
        let physiologicalHR = physiologicalHeartRateFixture(sleeps: sleeps)
        if !physiologicalHR.isEmpty {
            _ = try await store.insert(Streams(hr: physiologicalHR), deviceId: whoop)
        }

        // Seed the same display-only pre-sleep history up front under the canonical computed namespace.
        // IntelligenceEngine later derives these points again from the raw fixture above, using the same
        // complete-set reconciliation as production. These rows never enter Recovery, Rest, or Effort.
        let preSleepPoints = preSleepMetricFixture(days: daily, sleeps: sleeps)
        if !preSleepPoints.isEmpty {
            _ = try await store.upsertMetricSeries(preSleepPoints, deviceId: "\(whoop)-noop")
        }

        // The comparison card reads exact physical device ids. Give the paired Oura its own bounded
        // daily history with small, plausible differences; no ownership or score is copied across ids.
        let comparisonDays = comparisonDailyFixture(days: daily)
        try? await store.upsertDevice(id: comparisonOura, mac: nil, name: "Oura Ring 4 (demo)")
        if !comparisonDays.isEmpty {
            _ = try await store.upsertDailyMetrics(comparisonDays, deviceId: comparisonOura)
        }

        // 004 T80: bank TODAY's intraday HR + R-R so the stress ribbon and Live-HR module
        // render populated states in simulator screenshots. DaytimeStress needs >= 300 HR
        // samples per hour to score an hour, so we seed one sample every 10 s from 06:00
        // to "now" with a gentle daily arc + noise, and R-R at ~0.5 Hz tracking the HR.
        // Sim-only by construction: the seeder itself only runs behind --demo-seed.
        do {
            let cal = Calendar.current
            let dayStart = Int(cal.startOfDay(for: Date()).timeIntervalSince1970)
            let wake = dayStart + 6 * 3600
            let now = Int(Date().timeIntervalSince1970)
            if now > wake {
                var hrs: [HRSample] = []
                var rrs: [RRInterval] = []
                var t = wake
                while t < now {
                    let hourOfDay = Double(t - dayStart) / 3600.0
                    // Resting ~58, morning walk bump ~9-10h, midday ~70, evening spike ~18h.
                    let arc = 62.0 + 14.0 * sin((hourOfDay - 7.0) / 17.0 * .pi)
                        + (hourOfDay > 9.0 && hourOfDay < 10.0 ? 26.0 : 0)
                        + (hourOfDay > 17.5 && hourOfDay < 18.5 ? 38.0 : 0)
                    let bpm = Int((arc + gauss(&rng, 0, 3.0)).clamped(48, 168).rounded())
                    hrs.append(HRSample(ts: t, bpm: bpm))
                    if t % 2 == 0 {
                        let rrMs = Int((60_000.0 / Double(bpm) + gauss(&rng, 0, 22.0))
                            .clamped(320, 1300).rounded())
                        rrs.append(RRInterval(ts: t, rrMs: rrMs))
                    }
                    t += 10
                }
                _ = try await store.insert(Streams(hr: hrs, rr: rrs), deviceId: whoop)
            }
        }
        _ = try await store.upsertDailyMetrics(daily, deviceId: whoop)
        _ = try await store.upsertSleepSessions(sleeps, deviceId: whoop)
        _ = try await store.upsertMetricSeries(series, deviceId: whoop)
        _ = try await store.upsertAppleDaily(appleRows, deviceId: apple)
        if !workouts.isEmpty { _ = try await store.upsertWorkouts(workouts, deviceId: whoop) }
        if !journal.isEmpty { _ = try await store.upsertJournal(journal, deviceId: whoop) }
        NSLog("AppleDemoSeeder: seeded \(daily.count) days, \(workouts.count) workouts.")
    }

    /// One sample per complete minute from 30 minutes before the oldest selected night through the
    /// latest selected wake. Values follow a stable lower-asleep / higher-awake pattern, with a gentle
    /// pre-sleep taper and a slightly elevated final pre-sleep window for visible baseline feedback.
    static func physiologicalHeartRateFixture(
        sleeps: [CachedSleepSession],
        maximumNights: Int = 15
    ) -> [HRSample] {
        guard maximumNights > 0 else { return [] }
        let valid = sleeps
            .filter { $0.effectiveStartTs < $0.endTs }
            .sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        let selected = Array(valid.suffix(maximumNights))
        guard let first = selected.first, let last = selected.last else { return [] }

        let rawStart = first.effectiveStartTs - PreSleepHeartRateFeedback.defaultPreSleepWindowSeconds
        let start = rawStart - positiveRemainder(rawStart, divisor: 60)
        let lastRemainder = positiveRemainder(last.endTs, divisor: 60)
        let end = lastRemainder == 0 ? last.endTs : last.endTs + (60 - lastRemainder)
        guard start < end else { return [] }

        var result: [HRSample] = []
        result.reserveCapacity((end - start) / 60)
        var sessionIndex = 0
        var timestamp = start
        while timestamp < end {
            while sessionIndex < selected.count && timestamp >= selected[sessionIndex].endTs {
                sessionIndex += 1
            }
            let current = sessionIndex < selected.count ? selected[sessionIndex] : nil
            let asleep = current.map {
                timestamp >= $0.effectiveStartTs && timestamp < $0.endTs
            } ?? false
            let minute = Double(timestamp / 60)
            let bpm: Double
            if asleep, let current {
                let duration = max(1, current.endTs - current.effectiveStartTs)
                let progress = Double(timestamp - current.effectiveStartTs) / Double(duration)
                bpm = 53.0 + 2.4 * sin(progress * 4.0 * .pi) + 1.1 * sin(minute * 0.37)
            } else if let upcoming = current,
                      timestamp < upcoming.effectiveStartTs,
                      upcoming.effectiveStartTs - timestamp
                        <= PreSleepHeartRateFeedback.defaultPreSleepWindowSeconds {
                let isLatest = sessionIndex == selected.count - 1
                let target = preSleepTarget(index: sessionIndex, isLatest: isLatest)
                bpm = target + 1.0 * sin(minute * 0.53)
            } else {
                let seconds = positiveRemainder(timestamp, divisor: 86_400)
                let hour = Double(seconds) / 3_600.0
                bpm = 70.0 + 7.0 * sin((hour - 8.0) / 24.0 * 2.0 * .pi)
                    + 1.6 * sin(minute * 0.41)
            }
            result.append(HRSample(ts: timestamp, bpm: Int(bpm.clamped(42, 180).rounded())))
            timestamp += 60
        }
        return result
    }

    /// Five display-only points per recent night. Keys come from the production analytics contract,
    /// so a rename cannot leave the demo silently writing an obsolete series.
    static func preSleepMetricFixture(
        days: [DailyMetric],
        sleeps: [CachedSleepSession],
        maximumNights: Int = 14
    ) -> [MetricPoint] {
        guard maximumNights > 0, days.count == sleeps.count else { return [] }
        let selected = Array(zip(days, sleeps).suffix(maximumNights))
        return selected.enumerated().flatMap { index, pair in
            let (day, sleep) = pair
            let mean = preSleepTarget(index: index + 1, isLatest: index == selected.count - 1)
            return [
                MetricPoint(day: day.day, key: PreSleepHeartRateFeedback.meanMetricKey, value: round1(mean)),
                MetricPoint(day: day.day, key: PreSleepHeartRateFeedback.validSamplesMetricKey, value: 30),
                MetricPoint(day: day.day, key: PreSleepHeartRateFeedback.totalSamplesMetricKey, value: 30),
                MetricPoint(day: day.day, key: PreSleepHeartRateFeedback.primarySleepStartMetricKey,
                            value: Double(sleep.effectiveStartTs)),
                MetricPoint(day: day.day, key: PreSleepHeartRateFeedback.primarySleepEndMetricKey,
                            value: Double(sleep.endTs)),
            ]
        }
    }

    /// Read-only peer rows for the last 14 days. Only signals the Oura fixture claims to capture are
    /// present; activity totals and NOOP scores remain nil rather than being invented for that source.
    static func comparisonDailyFixture(days: [DailyMetric], maximumDays: Int = 14) -> [DailyMetric] {
        guard maximumDays > 0 else { return [] }
        return Array(days.suffix(maximumDays)).enumerated().map { index, row in
            DailyMetric(
                day: row.day,
                totalSleepMin: row.totalSleepMin.map { max(0, $0 - Double(5 + index % 4)) },
                efficiency: row.efficiency.map { max(0, $0 - 0.7) },
                deepMin: row.deepMin.map { max(0, $0 - 3) },
                remMin: row.remMin.map { max(0, $0 + 2) },
                lightMin: row.lightMin.map { max(0, $0 - 4) },
                disturbances: row.disturbances.map { max(0, $0 + (index % 2)) },
                restingHr: row.restingHr.map { $0 + (index.isMultiple(of: 3) ? 2 : 1) },
                avgHrv: row.avgHrv.map { round1($0 * 0.97) },
                recovery: nil,
                strain: nil,
                exerciseCount: nil,
                spo2Pct: row.spo2Pct.map { round1(max(0, $0 - 0.3)) },
                skinTempDevC: row.skinTempDevC.map { round2($0 + 0.1) }
            )
        }
    }

    private static func preSleepTarget(index: Int, isLatest: Bool) -> Double {
        60.0 + 1.8 * sin(Double(index) * 0.71) + (isLatest ? 5.0 : 0.0)
    }

    private static func positiveRemainder(_ value: Int, divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }

    /// Real store rows for the surfaces that were blocked in the first cleanup sweep.
    private static func seedCleanupAuditFixtures(into store: WhoopStore,
                                                 calendar: Calendar,
                                                 formatter: DateFormatter) async throws {
        let now = Date()
        let today = formatter.string(from: now)
        let markerRows = [whoop, "\(whoop)-noop"].flatMap { deviceId in
            (0..<3).map { offset in
                let date = calendar.date(byAdding: .day, value: -offset * 14, to: now)!
                return LabMarkerRow(
                    id: "demo-ferritin-\(deviceId)-\(offset)", deviceId: deviceId, markerKey: "ferritin",
                    category: "bloodPanel", day: formatter.string(from: date),
                    takenAt: Int(date.timeIntervalSince1970), value: 72 - Double(offset * 6),
                    valueText: nil, unit: "ng/mL", source: "demo-audit-v3",
                    note: offset == 0 ? "Synthetic audit fixture" : nil,
                    referenceText: "30–300 ng/mL")
            }
        }
        _ = try await store.upsertLabMarkers(markerRows)

        let hydration = [
            MetricPoint(day: today, key: HydrationStore.key, value: 1_237),
            MetricPoint(day: formatter.string(from: calendar.date(byAdding: .day, value: -1, to: now)!),
                        key: HydrationStore.key, value: 1_850),
        ]
        _ = try await store.upsertMetricSeries(hydration, deviceId: HydrationStore.sourceId)
        let entries = [
            HydrationEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!, amountMl: 500,
                           loggedAt: calendar.date(bySettingHour: 8, minute: 15, second: 0, of: now)!),
            HydrationEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!, amountMl: 737,
                           loggedAt: calendar.date(bySettingHour: 12, minute: 30, second: 0, of: now)!),
        ]
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: HydrationStore.entriesKey(forDay: today))
        }
    }

    // MARK: - helpers

    private static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
    private static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    /// Box–Muller normal sample, matching DemoSeeder.gauss exactly.
    private static func gauss(_ rng: inout SplitMix64, _ mean: Double, _ sd: Double) -> Double {
        let u1 = rng.nextDouble().clamped(1e-9, 1.0)
        let u2 = rng.nextDouble()
        return mean + sd * (Foundation.sqrt(-2.0 * Foundation.log(u1)) * Foundation.cos(2.0 * Double.pi * u2))
    }

    /// A plausible light→deep→rem cycle as the COMPUTED segment array
    /// [{"start":epoch,"end":epoch,"stage":"light"|"deep"|"rem"|"wake"}] that SleepView.decodeSegments
    /// reads, laid end-to-end from `onset`.
    private static func segmentsJSON(onset: Int, deep: Double, rem: Double, light: Double, awakeMin: Double) -> String {
        var t = onset
        var parts: [String] = []
        func seg(_ stage: String, _ minutes: Double) {
            let secs = Int(minutes * 60)
            guard secs > 0 else { return }
            parts.append("{\"start\":\(t),\"end\":\(t + secs),\"stage\":\"\(stage)\"}")
            t += secs
        }
        seg("light", light * 0.35); seg("deep", deep * 0.6); seg("light", light * 0.30)
        seg("rem", rem * 0.6); seg("deep", deep * 0.4); seg("light", light * 0.35)
        seg("rem", rem * 0.4); seg("wake", awakeMin)
        return "[" + parts.joined(separator: ",") + "]"
    }
}

/// Deterministic SplitMix64 PRNG — gives a fixed, reproducible demo dataset across runs (the Apple
/// counterpart of Kotlin's `Random(0xC0FFEE)`). Not for any security use.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)  // 2^53
    }

    /// Uniform Int in [lower, upper).
    mutating func nextInt(_ lower: Int, _ upper: Int) -> Int {
        guard upper > lower else { return lower }
        let span = UInt64(upper - lower)
        return lower + Int(next() % span)
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
    func atLeast(_ lo: Double) -> Double { Swift.max(self, lo) }
}
#endif
