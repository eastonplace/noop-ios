#if DEBUG
import Foundation
import GRDB
import WhoopProtocol
import WhoopStore
import WorkoutRouteExport

// MARK: - DEBUG-only demo week for the Workouts screens
//
// `AppleDemoSeeder.seed` scatters random workouts over 120 days. Every one of them is written as source
// "my-whoop" or "apple-health", none carries a strain version, none has a GPS route, a lift log or a dense heart-rate
// trace, and the newest can start later today. That is enough for a list, but the Workouts screens make decisions from
// exactly those details: whose Strain a row shows (NOOP's own, WHOOP's imported value, or none), whether a route map
// or a heart-rate curve exists, whether a lift is the last thing done.
//
// This top-up owns the newest `ownedDays` days (today and the six before it) and fills them with one session of every
// kind the screens tell apart, plus one rest day:
//
//   today   Strength Training   NOOP-scored (Strain V2) · dense HR trace · a lift log ("Upper body A")
//   -1 day  Running             NOOP-scored · GPS route + distance · dense HR trace
//   -2 days (rest day: nothing at all)
//   -3 days Cycling             imported from WHOOP with WHOOP's own Strain · HR zone split · no HR trace
//   -4 days Yoga                logged by hand · no HR in the window, so not scored
//   -5 days HIIT                imported from WHOOP with WHOOP's own Strain
//   -6 days Walking             Apple Health · distance only
//
// plus two older lift sessions so the lift history is more than one entry. Everything is deterministic (fixed times of
// day, a seeded noise source) and idempotent: it replaces what it owns on every `--demo-seed` launch, and never writes
// outside the simulator demo database (`AppleDemoSeeder.requested` gates the caller).
//
// Elevation is deliberately absent: the app stores a route as an encoded polyline plus a distance and keeps no
// altitude anywhere, so there is nothing to seed.
enum AppleDemoWorkoutFixture {

    /// Days (today included) whose workouts, heart-rate samples and lift sessions this fixture replaces.
    static let ownedDays = 7

    /// A session the fixture writes: the workout row, the store it belongs under, and whatever hangs off it.
    struct Session: Sendable {
        let dayOffset: Int
        let deviceId: String
        let row: WorkoutRow
        let hr: [HRSample]
        let route: WorkoutRoute?
        let lift: LiftLog?
    }

    struct LiftLog: Sendable {
        let session: LiftSessionRow
        let sets: [LiftSetRow]
    }

    /// Replaces the owned week in `store`. Safe to call on every launch.
    static func seed(into store: WhoopStore, now: Date = Date(), calendar: Calendar = .current) async {
        let sessions = plan(now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let windowStart = Int((calendar.date(byAdding: .day, value: -(ownedDays - 1), to: today) ?? today).timeIntervalSince1970)
        let windowEnd = Int((calendar.date(byAdding: .day, value: 1, to: today) ?? today).timeIntervalSince1970)
        let owned = sessions.filter { $0.dayOffset < ownedDays }
        let hrWindows = owned.map { (start: $0.row.startTs, end: $0.row.endTs) }

        do {
            // 1. Clear the window: every workout under the three ids the demo reads from, the lift log of those days,
            //    and the minute-level resting HR the base seed laid across them (it would otherwise be drawn as
            //    spikes through a workout's curve, and would score a session that is meant to be unscored).
            let ids = [AppleDemoSeeder.whoop, AppleDemoSeeder.apple, "\(AppleDemoSeeder.whoop)-noop"]
            try await store.registryWriter.write { db in
                try db.execute(sql: """
                    DELETE FROM workout
                    WHERE deviceId IN (?, ?, ?) AND startTs >= ? AND startTs < ?
                    """, arguments: [ids[0], ids[1], ids[2], windowStart, windowEnd])
                // The fixture also writes two older lift sessions outside the owned week, whose ids carry the
                // `demo-lift-` prefix and move with the date. Clear every session that prefix names, wherever it
                // falls, with its sets and its workout row, so a launch on a later day never leaves the earlier
                // day's older sessions behind.
                try db.execute(sql: """
                    DELETE FROM workout
                    WHERE deviceId IN (?, ?, ?) AND startTs IN (
                        SELECT startTs FROM liftSession WHERE deviceId = ? AND id LIKE 'demo-lift-%')
                    """, arguments: [ids[0], ids[1], ids[2], AppleDemoSeeder.whoop])
                try db.execute(sql: """
                    DELETE FROM liftSet
                    WHERE sessionId IN (
                        SELECT id FROM liftSession
                        WHERE deviceId = ? AND (id LIKE 'demo-lift-%' OR (startTs >= ? AND startTs < ?)))
                    """, arguments: [AppleDemoSeeder.whoop, windowStart, windowEnd])
                try db.execute(sql: """
                    DELETE FROM liftSession
                    WHERE deviceId = ? AND (id LIKE 'demo-lift-%' OR (startTs >= ? AND startTs < ?))
                    """, arguments: [AppleDemoSeeder.whoop, windowStart, windowEnd])
                for window in hrWindows {
                    try db.execute(sql: """
                        DELETE FROM hrSample WHERE deviceId = ? AND ts >= ? AND ts <= ?
                        """, arguments: [AppleDemoSeeder.whoop, window.start, window.end])
                }
            }

            // 2. Write the sessions. A lift session is saved through the store's atomic lift API so the workout row,
            //    the session and its sets stay paired exactly as the app writes them.
            var hr: [HRSample] = []
            for session in sessions {
                hr += session.hr
                if let lift = session.lift {
                    try await store.saveLiftSession(session: lift.session, sets: lift.sets, workout: session.row)
                } else {
                    _ = try await store.upsertWorkouts([session.row], deviceId: session.deviceId)
                }
                if let route = session.route {
                    RouteStore.store(route, startTs: session.row.startTs, sport: session.row.sport)
                }
            }
            if !hr.isEmpty { _ = try await store.insert(Streams(hr: hr), deviceId: AppleDemoSeeder.whoop) }

            // 3. Strength Strain: score each lift from its sets and fold it into its workout and day exactly as the
            //    app does for a real save (one extra step on the heart-rate value, never a replacement).
            let nowTs = Int(now.timeIntervalSince1970)
            for session in sessions {
                if let lift = session.lift {
                    let row = StrengthStrainIntegration.computed(
                        sessionId: lift.session.id, startTs: session.row.startTs, sets: lift.sets, bodyweightKg: 75)
                    try await store.upsertLiftStrainComputed(deviceId: AppleDemoSeeder.whoop, rows: [row], now: nowTs)
                }
            }
            _ = try await store.applyLiftStrain(
                canonicalComputedDeviceId: "\(AppleDemoSeeder.whoop)-noop", now: nowTs,
                combine: StrengthStrainIntegration.combine)
            NSLog("AppleDemoWorkoutFixture: %d sessions, %d HR samples.", sessions.count, hr.count)
        } catch {
            NSLog("AppleDemoWorkoutFixture: failed — \(error)")
        }
    }

    // MARK: - Plan (pure)

    static func plan(now: Date, calendar: Calendar) -> [Session] {
        let today = calendar.startOfDay(for: now)
        let nowTs = Int(now.timeIntervalSince1970)
        func ts(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Int {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: today) ?? today
            let moment = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
            return Int(moment.timeIntervalSince1970)
        }
        var sessions: [Session] = []
        let whoop = AppleDemoSeeder.whoop

        // Today: a strength session, only once it is over (a row can never start in the future).
        let strengthStart = ts(0, 7, 10), strengthEnd = strengthStart + 52 * 60
        if strengthEnd <= nowTs - 120 {
            let trace = hrTrace(start: strengthStart, end: strengthEnd, seed: 0x5712E) { (t: Double, total: Double) -> Double in
                // A set every ~3.5 minutes: the rate climbs through the set and settles in the rest after it.
                let phase: Double = t.truncatingRemainder(dividingBy: 215) / 215
                let set: Double = pow(max(0, Foundation.sin(phase * Double.pi)), 1.5)
                let warmUp: Double = min(1, t / 420)
                let drift: Double = 1 + 0.1 * (t / total)
                return (96 + 40 * set * (0.55 + 0.45 * warmUp)) * drift
            }
            sessions.append(strengthSession(dayOffset: 0, start: strengthStart, end: strengthEnd, trace: trace,
                                            program: "Upper body A", strain: 47.6, kcal: 338,
                                            exercises: upperBodyA))
        }

        // Yesterday: a GPS run with its route, scored by NOOP from the trace.
        let runStart = ts(1, 17, 40), runEnd = runStart + 34 * 60
        let route = demoRoute(startTs: runStart, durationS: runEnd - runStart)
        let runTrace = hrTrace(start: runStart, end: runEnd, seed: 0x2E55) { (t: Double, total: Double) -> Double in
            let warm = 240.0, cool = 360.0
            if t < warm { return 110 + 44 * (t / warm) }
            if t > total - cool { return 160 - 42 * ((t - (total - cool)) / cool) }
            let steady: Double = 160 + 4 * Foundation.sin(t / 140) + 0.004 * (t - warm)
            let firstSurge: Double = 9 * bump(t, center: total * 0.38, width: 110)
            let secondSurge: Double = 11 * bump(t, center: total * 0.72, width: 90)
            return steady + firstSurge + secondSurge
        }
        sessions.append(Session(
            dayOffset: 1, deviceId: whoop,
            row: manualRow(start: runStart, end: runEnd, sport: "Running", trace: runTrace, strain: 61.9,
                           kcal: 402, distanceM: route.distanceM),
            hr: runTrace, route: route, lift: nil))

        // Three days ago: cycling imported from a WHOOP export, with WHOOP's own Strain (14.6 on its 0-21 scale).
        let rideStart = ts(3, 6, 45)
        sessions.append(Session(
            dayOffset: 3, deviceId: whoop,
            row: WorkoutRow(startTs: rideStart, endTs: rideStart + 67 * 60, sport: "Cycling", source: "whoop",
                            durationS: 67 * 60, energyKcal: 705, avgHr: 141, maxHr: 172,
                            strain: 14.6 * 100 / 21, distanceM: 28_400,
                            zonesJSON: zonesJSON(8, 31, 36, 20, 5), notes: nil),
            hr: [], route: nil, lift: nil))

        // Four days ago: yoga logged by hand. No HR in the window (cleared above), so it stays unscored.
        let yogaStart = ts(4, 19, 0)
        sessions.append(Session(
            dayOffset: 4, deviceId: whoop,
            row: WorkoutRow(startTs: yogaStart, endTs: yogaStart + 40 * 60, sport: "Yoga", source: "manual",
                            durationS: 40 * 60, energyKcal: 118, avgHr: nil, maxHr: nil, strain: nil,
                            distanceM: nil, zonesJSON: nil, notes: nil),
            hr: [], route: nil, lift: nil))

        // Five days ago: a WHOOP-imported interval session.
        let hiitStart = ts(5, 12, 15)
        sessions.append(Session(
            dayOffset: 5, deviceId: whoop,
            row: WorkoutRow(startTs: hiitStart, endTs: hiitStart + 30 * 60, sport: "HIIT", source: "whoop",
                            durationS: 30 * 60, energyKcal: 392, avgHr: 158, maxHr: 186,
                            strain: 16.9 * 100 / 21, distanceM: nil,
                            zonesJSON: zonesJSON(5, 14, 26, 38, 17), notes: nil),
            hr: [], route: nil, lift: nil))

        // Six days ago: an Apple Health walk.
        let walkStart = ts(6, 8, 20)
        sessions.append(Session(
            dayOffset: 6, deviceId: AppleDemoSeeder.apple,
            row: WorkoutRow(startTs: walkStart, endTs: walkStart + 38 * 60, sport: "Walking", source: "apple-health",
                            durationS: 38 * 60, energyKcal: 142, avgHr: nil, maxHr: nil, strain: nil,
                            distanceM: 3_150, zonesJSON: nil, notes: nil),
            hr: [], route: nil, lift: nil))

        // Older lift sessions, outside the owned week (they only add history).
        for (offset, program, exercises, strain, kcal) in [
            (8, "Lower body", lowerBody, 41.9, 312.0),
            (12, "Upper body B", upperBodyB, 44.3, 329.0),
        ] {
            let start = ts(offset, 18, 5)
            sessions.append(strengthSession(dayOffset: offset, start: start, end: start + 53 * 60, trace: [],
                                            program: program, strain: strain, kcal: kcal, exercises: exercises))
        }
        return sessions
    }

    // MARK: - Rows

    private static func manualRow(start: Int, end: Int, sport: String, trace: [HRSample], strain: Double,
                                  kcal: Double, distanceM: Double?) -> WorkoutRow {
        let bpm = trace.map(\.bpm)
        let average = bpm.isEmpty ? nil : Int((Double(bpm.reduce(0, +)) / Double(bpm.count)).rounded())
        return WorkoutRow(startTs: start, endTs: end, sport: sport, source: "manual",
                          durationS: Double(end - start), energyKcal: kcal, avgHr: average, maxHr: bpm.max(),
                          strain: strain, distanceM: distanceM, zonesJSON: nil, notes: nil, strainVersion: 2)
    }

    private static func strengthSession(dayOffset: Int, start: Int, end: Int, trace: [HRSample], program: String,
                                        strain: Double, kcal: Double, exercises: [LiftExercise]) -> Session {
        let id = "demo-lift-\(start)"
        let sets = liftSets(sessionId: id, start: start, end: end, exercises: exercises)
        let row = manualRow(start: start, end: end, sport: "Strength Training", trace: trace, strain: strain,
                            kcal: kcal, distanceM: nil)
        let session = LiftSessionRow(id: id, deviceId: AppleDemoSeeder.whoop, startTs: start, endTs: end,
                                     sport: "Strength Training", programId: nil, programName: program,
                                     sessionRpe: nil, note: nil)
        return Session(dayOffset: dayOffset, deviceId: AppleDemoSeeder.whoop, row: row, hr: trace, route: nil,
                       lift: LiftLog(session: session, sets: sets))
    }

    /// The importer's zone shape: percent of the session per zone.
    private static func zonesJSON(_ z1: Double, _ z2: Double, _ z3: Double, _ z4: Double, _ z5: Double) -> String {
        "{\"zone1\":\(z1),\"zone2\":\(z2),\"zone3\":\(z3),\"zone4\":\(z4),\"zone5\":\(z5)}"
    }

    // MARK: - Lift log

    struct LiftExercise: Sendable {
        let name: String
        let primary: LiftMuscle
        let secondary: [LiftMuscle]
        /// (kilograms, reps, isWarmup)
        let sets: [(Double, Int, Bool)]
    }

    private static let upperBodyA = [
        LiftExercise(name: "Bench press", primary: .chest, secondary: [.frontDelts, .triceps],
                     sets: [(40, 10, true), (70, 8, false), (72.5, 8, false), (72.5, 7, false), (70, 8, false)]),
        LiftExercise(name: "Barbell row", primary: .upperBack, secondary: [.lats, .biceps],
                     sets: [(60, 10, false), (60, 10, false), (62.5, 8, false)]),
        LiftExercise(name: "Overhead press", primary: .frontDelts, secondary: [.triceps, .sideDelts],
                     sets: [(40, 8, false), (40, 8, false), (42.5, 6, false)]),
        LiftExercise(name: "Lat pulldown", primary: .lats, secondary: [.biceps],
                     sets: [(55, 12, false), (55, 12, false), (57.5, 10, false)]),
    ]

    private static let lowerBody = [
        LiftExercise(name: "Back squat", primary: .quads, secondary: [.glutes, .hamstrings],
                     sets: [(60, 8, true), (100, 5, false), (100, 5, false), (105, 4, false), (100, 5, false)]),
        LiftExercise(name: "Romanian deadlift", primary: .hamstrings, secondary: [.glutes, .lowerBack],
                     sets: [(80, 8, false), (80, 8, false), (85, 6, false)]),
        LiftExercise(name: "Leg press", primary: .quads, secondary: [.glutes],
                     sets: [(160, 10, false), (160, 10, false), (170, 8, false)]),
    ]

    private static let upperBodyB = [
        LiftExercise(name: "Incline dumbbell press", primary: .chest, secondary: [.frontDelts, .triceps],
                     sets: [(28, 10, false), (28, 9, false), (30, 7, false)]),
        LiftExercise(name: "Seated cable row", primary: .upperBack, secondary: [.lats, .biceps],
                     sets: [(52.5, 12, false), (52.5, 12, false), (57.5, 9, false)]),
        LiftExercise(name: "Lateral raise", primary: .sideDelts, secondary: [],
                     sets: [(10, 15, false), (10, 14, false), (10, 12, false)]),
    ]

    private static func liftSets(sessionId: String, start: Int, end: Int, exercises: [LiftExercise]) -> [LiftSetRow] {
        let total = exercises.reduce(0) { $0 + $1.sets.count }
        let step = max(60, (end - start - 300) / max(total, 1))
        var rows: [LiftSetRow] = []
        var ordinal = 0
        for exercise in exercises {
            var workingIndex = 0
            for (kilograms, reps, isWarmup) in exercise.sets {
                if !isWarmup { workingIndex += 1 }
                let setStart = start + 180 + ordinal * step
                rows.append(LiftSetRow(
                    id: "\(sessionId)-\(ordinal)", deviceId: AppleDemoSeeder.whoop, sessionId: sessionId,
                    ord: ordinal, exercise: exercise.name, primaryMuscle: exercise.primary,
                    secondaryMuscles: exercise.secondary, setIndex: isWarmup ? 0 : workingIndex,
                    weightKg: kilograms, reps: reps, rpe: nil, isWarmup: isWarmup,
                    startTs: setStart, endTs: setStart + 45, restSec: step - 45, note: nil))
                ordinal += 1
            }
        }
        return rows
    }

    // MARK: - Heart-rate trace

    /// One sample every 2 s from `start` to `end`, following `level` (bpm at `t` seconds into a window of `total`)
    /// with a little smoothed noise so the curve breathes instead of drawing a ruler line.
    static func hrTrace(start: Int, end: Int, seed: UInt64,
                        level: (_ t: Double, _ total: Double) -> Double) -> [HRSample] {
        var rng = SplitMix64(seed: seed)
        var wobble = 0.0
        var samples: [HRSample] = []
        samples.reserveCapacity((end - start) / 2 + 1)
        var ts = start
        while ts <= end {
            let u1 = max(rng.nextDouble(), 1e-9), u2 = rng.nextDouble()
            let noise = (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * Double.pi * u2)
            wobble = wobble * 0.82 + noise * 1.4
            let bpm = (level(Double(ts - start), Double(end - start)) + wobble).rounded()
            samples.append(HRSample(ts: ts, bpm: Int(min(max(bpm, 60), 196))))
            ts += 2
        }
        return samples
    }

    private static func bump(_ t: Double, center: Double, width: Double) -> Double {
        let x = (t - center) / width
        return Foundation.exp(-x * x)
    }

    // MARK: - Route

    /// A loop through Central Park, wobbled so it reads as a path rather than an ellipse. It carries one timestamp per
    /// point across the session, as a recorded run does, so the workout's Share route control appears.
    static func demoRoute(startTs: Int, durationS: Int) -> WorkoutRoute {
        let points = (0...150).map { index -> RouteMath.LatLng in
            let angle = Double(index) / 150 * 2 * Double.pi
            let lat = 40.7790 + 0.0086 * Foundation.sin(angle) + 0.0009 * Foundation.sin(3 * angle + 1.1)
            let lon = -73.9650 + 0.0104 * Foundation.cos(angle) + 0.0007 * Foundation.cos(2 * angle + 0.4)
            return RouteMath.LatLng(lat, lon)
        }
        let stepMs = Int64(durationS) * 1_000 / Int64(points.count - 1)
        let timed = points.enumerated().map { index, point in
            RecordedRoutePoint(latitude: point.lat, longitude: point.lon,
                               timestampMs: Int64(startTs) * 1_000 + Int64(index) * stepMs, horizontalAccuracyM: 5)
        }
        return WorkoutRoute(segmentPolylines: [RouteMath.encode(points)],
                            distanceM: RouteMath.totalMeters(points).rounded(), pointSegments: [timed])
    }
}
#endif
