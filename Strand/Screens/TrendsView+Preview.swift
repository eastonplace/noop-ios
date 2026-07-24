import SwiftUI
import WhoopStore

#if DEBUG
@MainActor
private func previewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    let calendar = Calendar(identifier: .gregorian)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    let today = Date()
    var seeded: [DailyMetric] = []
    let span = 365 * 3

    for index in stride(from: span - 1, through: 0, by: -1) {
        guard let date = calendar.date(byAdding: .day, value: -index, to: today) else { continue }
        let phase = Double(span - 1 - index)
        let recovery = 55 + 28 * sin(phase / 11.0) + Double((Int(phase) * 31) % 17) - 8
        let hrv = 58 + 16 * sin(phase / 9.0) + Double((Int(phase) * 13) % 11) - 5
        let restingHR = 52 + 4 * sin(phase / 7.0) + Double((Int(phase) * 7) % 5) - 2
        let strain = 9 + 6 * sin(phase / 5.0 + 1.2) + Double((Int(phase) * 5) % 4) - 2
        let gap = Int(phase) % 23 == 0
        seeded.append(DailyMetric(
            day: formatter.string(from: date),
            totalSleepMin: 420,
            efficiency: 0.9,
            deepMin: 90,
            remMin: 110,
            lightMin: 200,
            disturbances: 6,
            restingHr: gap ? nil : Int(restingHR.rounded()),
            avgHrv: gap ? nil : max(15, hrv),
            recovery: gap ? nil : max(2, min(99, recovery)),
            strain: gap ? nil : max(0, min(21, strain)),
            exerciseCount: 1
        ))
    }

    repo.days = seeded
    repo.loaded = true
    return repo
}

#Preview("Trends") {
    TrendsView()
        .environmentObject(previewRepo())
        .environmentObject(LiveState())
        .frame(width: 960, height: 960)
        .preferredColorScheme(.dark)
}
#endif
