import SwiftUI
import StrandDesign
import WhoopStore

struct JournalMoodCheckIn: View {
    let date: Date
    @EnvironmentObject private var repo: Repository
    @State private var mood: Int?
    @State private var saving = false
    @State private var failure: String?
    @State private var loadedDay: String?
    @State private var revision = 0
    private var day: String { JournalExperiencePolicy.dayKey(date) }
    var body: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 14) {
                ExperienceSectionHeading(title: "How did you feel?", detail: "Mood for \(date.formatted(date: .abbreviated, time: .omitted))")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 12) {
                    ForEach(1...5, id: \.self) { value in
                        Button { save(value) } label: {
                            VStack(spacing: 6) {
                                Text(MoodStore.face(for: value)).font(StrandFont.title2)
                                Text(MoodStore.label(for: value)).font(StrandFont.caption)
                            }
                            .foregroundStyle(StrandPalette.textPrimary).frame(maxWidth: .infinity, minHeight: 64)
                            .background(mood == value ? StrandPalette.inset : StrandPalette.card, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain).disabled(saving || loadedDay != day)
                        .accessibilityLabel(MoodStore.label(for: value))
                        .accessibilityAddTraits(mood == value ? .isSelected : [])
                    }
                }
                if saving { ProgressView("Saving mood…") }
                if let failure {
                    Text(failure).font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
                    Button("Retry mood") { revision += 1 }.frame(minHeight: 44)
                }
            }
        }
        .task(id: "\(day)|\(revision)") {
            let key = day
            do {
                let value = try await read(key)
                try Task.checkCancellation()
                guard day == key else { return }
                mood = value
                loadedDay = key
                failure = nil
            } catch is CancellationError { return }
            catch { if day == key { failure = error.localizedDescription } }
        }
    }
    private func read(_ day: String) async throws -> Int? {
        guard let store = await repo.storeHandle() else { throw JournalExperienceStore.Failure.unavailable }
        let values = try await store.metricSeries(deviceId: MoodStore.moodDeviceId, key: MoodStore.moodKey, from: day, to: day)
        guard let value = values.last?.value, value.isFinite, (1...5).contains(value) else { return nil }
        return Int(value.rounded())
    }
    private func save(_ value: Int) {
        guard !saving, loadedDay == day else { return }
        let key = day
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                guard let store = await repo.storeHandle() else { throw JournalExperienceStore.Failure.unavailable }
                _ = try await store.upsertMetricSeries([MetricPoint(day: key, key: MoodStore.moodKey, value: Double(value))],
                                                      deviceId: MoodStore.moodDeviceId)
                guard try await read(key) == value else { throw NativeJournalEditError.verificationFailed }
                if day == key { mood = value; failure = nil }
            } catch { if day == key { failure = error.localizedDescription } }
        }
    }
}
