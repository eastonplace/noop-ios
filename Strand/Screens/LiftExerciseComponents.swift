import SwiftUI
import Charts
import StrandDesign

/// Shared linked artwork. Missing custom-exercise art stays explicit instead of showing another move.
struct NoopLiftExerciseArtwork: View {
    let name: String
    var size: CGFloat = 64
    @State private var artwork: Image?
    private var url: URL? { NoopLiftCatalog.resolve(name: name)?.imageURL }
    var body: some View {
        Group {
            if let artwork { artwork.resizable().scaledToFit() }
            else { fallback }
        }
        .frame(width: size, height: size).background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
        .task(id: url) {
            artwork = nil
            guard let url else { return }
            let data = await LiftArtworkCache.shared.data(for: url)
            guard !Task.isCancelled else { return }
            guard let data else { return }
            #if os(iOS)
            if let decoded = UIImage(data: data) { artwork = Image(uiImage: decoded) }
            #else
            if let decoded = NSImage(data: data) { artwork = Image(nsImage: decoded) }
            #endif
        }
    }
    private var fallback: some View {
        Image(systemName: "dumbbell.fill").font(.system(size: size * 0.3)).foregroundStyle(Color.gray)
    }
}

struct LiftExerciseLink: View {
    let name: String
    let action: () -> Void
    var size: CGFloat = 72
    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                NoopLiftExerciseArtwork(name: name, size: size)
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    if let entry = NoopLiftCatalog.resolve(name: name) {
                        Text("\(entry.muscle.capitalized) · \(entry.equipment.capitalized)")
                            .font(.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Label("History & exercise details", systemImage: "chart.xyaxis.line")
                        .font(.caption.weight(.medium)).foregroundStyle(StrandPalette.accent)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(StrandPalette.textSecondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(name), history and exercise details")
    }
}


struct LiftProgressPoint: Identifiable {
    let id: String
    let date: Date
    let value: Double
}
struct LiftProgressChart: View {
    let points: [LiftProgressPoint]
    let unit: String
    let isVolume: Bool
    var body: some View {
        Group {
            if points.isEmpty {
                ContentUnavailableView("Your progress starts here", systemImage: "chart.xyaxis.line", description: Text("Saved working sets will appear here."))
            } else {
                VStack(spacing: 8) {
                Chart(points) { point in
                    if isVolume {
                        BarMark(x: .value("Date", point.date), y: .value(unit, point.value)).foregroundStyle(StrandPalette.accent)
                    } else {
                        LineMark(x: .value("Date", point.date), y: .value(unit, point.value)).foregroundStyle(StrandPalette.accent)
                        PointMark(x: .value("Date", point.date), y: .value(unit, point.value)).foregroundStyle(StrandPalette.accent)
                    }
                }.chartYAxisLabel(unit)
                    .chartXScale(range: .plotDimension(padding: 12))
                    .chartXAxis(.hidden)
                HStack {
                    if let first = points.first { Text(first.date, format: .dateTime.month(.abbreviated).day()) }
                    Spacer()
                    if let last = points.last { Text(last.date, format: .dateTime.month(.abbreviated).day()) }
                }.font(.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }.frame(height: 190)
    }
}

private actor LiftArtworkCache {
    static let shared = LiftArtworkCache()
    private let cache = NSCache<NSURL, NSData>()
    private var pending: [URL: Task<Data?, Never>] = [:]
    init() { cache.countLimit = 80; cache.totalCostLimit = 12 * 1024 * 1024 }
    func data(for url: URL) async -> Data? {
        if let cached = cache.object(forKey: url as NSURL) { return cached as Data }
        if let task = pending[url] { return await task.value }
        let task = Task.detached(priority: .utility) { try? Data(contentsOf: url) }
        pending[url] = task
        let value = await task.value
        pending[url] = nil
        if let value { cache.setObject(value as NSData, forKey: url as NSURL, cost: value.count) }
        return value
    }
}
