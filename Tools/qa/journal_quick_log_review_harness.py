#!/usr/bin/env python3
"""Exercise production Journal rules/model/catalog on macOS without an app or saved user data."""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def source(path, revision):
    if revision:
        return subprocess.check_output(['git', 'show', f'{revision}:{path}'], cwd=ROOT, text=True)
    return (ROOT / path).read_text()


def declaration(text, prefix):
    start = text.index(prefix)
    opening = text.index('{', start)
    depth, cursor = 1, opening + 1
    while depth:
        depth += (text[cursor] == '{') - (text[cursor] == '}')
        cursor += 1
    return text[start:cursor]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--revision')
    args = parser.parse_args()
    read = lambda p: source(p, args.revision)
    rules = read('Strand/Screens/JournalQuickLog.swift').replace('import WhoopStore', '')
    catalog = read('Strand/Data/JournalCatalog.swift')
    helpers = read('Strand/Screens/JournalQuestions.swift').split('// MARK: - Editing rules')[0]
    helpers = helpers.replace('import StrandDesign', '').replace('import WhoopStore', '')
    model = declaration(read('Strand/Screens/JournalQuickLogSection.swift'), '@MainActor\nfinal class JournalQuickLogModel')
    # Old revisions cannot accept a source identity. Forward the new test fixture signature to their
    # unchanged day-only seed so the regression fails on stale answers, rather than an API compile error.
    if 'func seed(day: String, sourceContext: String' not in model:
        model += r"""
@MainActor extension JournalQuickLogModel {
    func seed(day: String, sourceContext: String, tiles: [JournalQuickLogTile],
              native: JournalQuickLog.DayValues, imported: JournalQuickLog.DayValues,
              earlier: JournalQuickLog.DayValues, epoch: Int) {
        seed(day: day, tiles: tiles, native: native, imported: imported, earlier: earlier, epoch: epoch)
    }
}
"""
    root_writer = declaration(read('Strand/Screens/CoachingRootView.swift'), 'private var writer: JournalQuickLogModel.Writer')
    load_key = declaration(read('Strand/Screens/CoachingRootView.swift'), 'private var loadKey: String')
    saves = '\n'.join(declaration(read('Strand/Data/Repository.swift'), prefix) for prefix in [
        'func saveJournalAnswer(', 'func saveJournalNumeric(', 'func clearJournalAnswer('])
    repository_source = read('Strand/Data/Repository.swift')
    if 'private func canCommitJournalWrite(' in repository_source:
        saves += '\n' + declaration(repository_source, 'private func canCommitJournalWrite(')
    merge = declaration(read('Strand/Data/Repository.swift'), 'nonisolated static func mergeJournal(')
    bounded = declaration(read('Strand/Data/Repository.swift'), 'func journalEntries(from: String, to: String)')
    active = declaration(read('Strand/Data/Repository+JournalDay.swift'), 'func activeCoachingQuestions(')
    day_values = declaration(read('Strand/Data/Repository+JournalDay.swift'), 'func journalDayValues(')
    swift = '''import Foundation
import SwiftUI
struct JournalEntry {
    var day: String; var question: String; var answeredYes: Bool
    var notes: String? = nil; var numericValue: Double? = nil
}
enum StrandPalette {
    static let sleepAccent = Color.blue, metricAmber = Color.orange, strainAccent = Color.red
    static let metricRose = Color.pink, metricCyan = Color.cyan
}
struct CoachingBehaviorMembership {
    var setId: String; var canonicalQuestion: String; var coachingGroup: String
    var sortIndex: Int; var isActive: Bool; var isQuickAdd: Bool
}
@MainActor final class FixtureStore {
    var memberships: [CoachingBehaviorMembership] = []
    var entries: [String: [JournalEntry]] = [:]
    var fails = false
    var mutations = 0
    func upsertJournal(_ rows: [JournalEntry], deviceId: String) async throws -> Int {
        mutations += 1; entries[deviceId, default: []] += rows; return rows.count
    }
    func deleteJournal(deviceId: String, day: String, question: String) async throws -> Int {
        mutations += 1; return 1
    }
    struct SetRow { var id = "daily-fundamentals" }
    enum Failure: Error { case unavailable }
    func ensureDefaultCoachingSet(name: String, memberships: [CoachingBehaviorMembership]) async throws -> SetRow {
        if fails { throw Failure.unavailable }; return SetRow()
    }
    func coachingMemberships(setId: String) async throws -> [CoachingBehaviorMembership] {
        if fails { throw Failure.unavailable }; return memberships
    }
    func journalEntries(deviceId: String, from: String, to: String) async throws -> [JournalEntry] {
        entries[deviceId, default: []].filter { $0.day >= from && $0.day <= to }
    }
}
@MainActor final class Repository {
    static let journalDeviceId = "noop-journal"
    var fixture: FixtureStore? = FixtureStore()
    var importedReadIds = ["whoop-active", "my-whoop"]
    var journalEntrySourceContext = "store-A"
    var verifiedExternalSurfaceFenced = false
    var journalRevision = 0
    var refreshSeq = 0
    var holdNextStore = false
    var releaseStore: CheckedContinuation<Void, Never>?
    func journalDidChange() { journalRevision += 1 }
    func storeHandle() async -> FixtureStore? { fixture }
    func ensureStore() async -> FixtureStore? {
        if holdNextStore {
            holdNextStore = false
            await withCheckedContinuation { releaseStore = $0 }
        }
        return fixture
    }
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    static func dayString(_ day: Date) -> String { dayFormatter.string(from: day) }
''' + merge + '\n' + active + '\n' + day_values + '\n' + bounded + '\n' + saves + '\n}\n' + catalog + rules + helpers + model + '\n@MainActor struct RootWriter { let repo: Repository;\n' + root_writer + '\nvar value: JournalQuickLogModel.Writer { writer }\n}\n@MainActor struct RootLoadIdentity { let repo: Repository; var dayKey = "2026-10-22"; var catalogRevision = 0;\n' + load_key + '\nvar value: String { loadKey }\n}\n' + r'''
@main struct Harness {
    @MainActor static func main() async {
        var failed = 0
        func check(_ value: Bool, _ name: String) {
            print("\(value ? "PASS" : "FAIL"): \(name)")
            if !value { failed += 1 }
        }
        let name = "noop.journal.review." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let catalog = JournalCatalogStore(defaults: defaults)
        let items = catalog.resolvedItems(imported: [])
        let tiles = JournalQuickLogTile.tiles(from: items, active: Set(items.map(\.canonical)))
        check(JournalQuickLogTile.tiles(from: items, active: []).isEmpty,
              "all-disabled membership shows no questions")
        let repo = Repository()
        let emptyActive = await repo.activeCoachingQuestions(for: items)
        check(emptyActive.isEmpty, "successful empty membership remains empty")
        repo.fixture?.fails = true
        let unavailable = await repo.activeCoachingQuestions(for: items)
        check(unavailable.count == 10, "failed membership read falls back to catalog keys")
        repo.fixture = nil
        let missingStore = await repo.activeCoachingQuestions(for: items)
        check(missingStore.count == 10, "unavailable store falls back to catalog keys")
        for reset in [false, true] {
            let model = JournalQuickLogModel()
            var saved: [(String, JournalQuickLog.Write)] = []
            var callbackCount = 0
            var release: CheckedContinuation<Void, Never>?
            model.writer = .init(save: { day, write in
                saved.append((day, write))
                if saved.count == 1 { await withCheckedContinuation { release = $0 } }
            }, clear: { _, _ in }, canWrite: { true }, didWrite: { callbackCount += 1 })
            model.seed(day: "2026-10-22", sourceContext: "store-A", tiles: tiles, native: .init(), imported: .init(), earlier: .init(), epoch: 0)
            model.markRest()
            for _ in 0..<1000 where release == nil { try? await Task.sleep(for: .milliseconds(1)) }
            check(release != nil, "bulk save reached suspended first write")
            if reset { model.reset() }
            model.seed(day: "2026-10-21", sourceContext: "store-A", tiles: tiles, native: .init(), imported: .init(), earlier: .init(), epoch: model.changeEpoch)
            // A different host Writer must not take over an already accepted run.
            var replacementWrites = 0
            model.writer = .init(save: { _, _ in replacementWrites += 1 }, clear: { _, _ in }, canWrite: { true }, didWrite: { callbackCount += 1 })
            release?.resume()
            for _ in 0..<1000 where saved.count < tiles.count { try? await Task.sleep(for: .milliseconds(1)) }
            check(saved.count == 10 && saved.allSatisfy { $0.0 == "2026-10-22" },
                  "accepted bulk answers finish on captured day after \(reset ? "reset" : "day seed")")
            check(replacementWrites == 0, "accepted run retains original writer")
            check(model.answeredCount == 0 && model.dayKey == "2026-10-21" && callbackCount == 0,
                  "old completion cannot publish into the new day")
        }
        let switchedRepo = Repository()
        let switchedModel = JournalQuickLogModel()
        switchedModel.writer = RootWriter(repo: switchedRepo).value
        switchedModel.seed(day: "2026-10-22", sourceContext: "store-A", tiles: tiles,
                           native: .init(), imported: .init(), earlier: .init(), epoch: 0)
        switchedRepo.holdNextStore = true
        let plainTile = tiles.first { $0.amount == nil }!
        switchedModel.tap(plainTile)
        for _ in 0..<1000 where switchedRepo.releaseStore == nil { try? await Task.sleep(for: .milliseconds(1)) }
        check(switchedRepo.releaseStore != nil && switchedModel.state(of: plainTile) == .yes,
              "old-source optimistic answer is visible while its store open is suspended")
        switchedRepo.journalEntrySourceContext = "store-B"
        switchedRepo.fixture = FixtureStore()
        switchedModel.writer = RootWriter(repo: switchedRepo).value
        switchedModel.seed(day: "2026-10-22", sourceContext: "store-B", tiles: tiles,
                           native: .init(), imported: .init(), earlier: .init(), epoch: switchedModel.changeEpoch)
        check(switchedModel.state(of: plainTile) == .unanswered,
              "same-day new-source seed clears old optimistic answer despite old in-flight write")
        switchedRepo.releaseStore?.resume()
        try? await Task.sleep(for: .milliseconds(20))
        check(switchedRepo.journalRevision == 0 && switchedModel.state(of: plainTile) == .unanswered,
              "blocked old-source completion emits no revision and leaves new source blank")
        switchedModel.tap(plainTile)
        for _ in 0..<1000 where switchedRepo.journalRevision < 1 { try? await Task.sleep(for: .milliseconds(1)) }
        check(switchedRepo.fixture?.entries[Repository.journalDeviceId]?.last?.answeredYes == true,
              "first new-source tap uses blank state and the replacement writer")
        let queuedRepo = Repository()
        let queuedModel = JournalQuickLogModel()
        queuedModel.writer = RootWriter(repo: queuedRepo).value
        queuedModel.seed(day: "2026-10-22", sourceContext: "store-A", tiles: tiles,
                         native: .init(), imported: .init(), earlier: .init(), epoch: 0)
        queuedRepo.holdNextStore = true
        queuedModel.tap(plainTile)
        for _ in 0..<1000 where queuedRepo.releaseStore == nil { try? await Task.sleep(for: .milliseconds(1)) }
        queuedRepo.journalEntrySourceContext = "store-B"
        queuedRepo.fixture = FixtureStore()
        queuedModel.seed(day: "2026-10-22", sourceContext: "store-B", tiles: tiles,
                         native: .init(), imported: .init(), earlier: .init(), epoch: queuedModel.changeEpoch)
        queuedModel.writer = RootWriter(repo: queuedRepo).value
        queuedModel.tap(plainTile)
        try? await Task.sleep(for: .milliseconds(20))
        check(queuedRepo.fixture?.mutations == 0,
              "source reset preserves accepted write tail before new-source operation")
        queuedRepo.releaseStore?.resume()
        for _ in 0..<1000 where queuedRepo.journalRevision < 1 { try? await Task.sleep(for: .milliseconds(1)) }
        check(queuedRepo.journalRevision == 1 && queuedRepo.fixture?.mutations == 1,
              "only the replacement-source operation persists after the old tail unblocks")
        let identity = RootLoadIdentity(repo: repo)
        let initialLoad = identity.value
        repo.journalRevision += 1
        check(identity.value != initialLoad, "durable Journal writes invalidate main-screen load identity")
        for numeric in [false, true] {
            let fencedRepo = Repository()
            let writer = RootWriter(repo: fencedRepo).value
            fencedRepo.holdNextStore = true
            let operation = Task { @MainActor in
                await writer.save("2026-10-22", numeric ? .amount(question: "Q", value: 2) : .answer(question: "Q", yes: true))
            }
            for _ in 0..<1000 where fencedRepo.releaseStore == nil { try? await Task.sleep(for: .milliseconds(1)) }
            check(fencedRepo.releaseStore != nil, "accepted write reached suspended store open")
            fencedRepo.journalEntrySourceContext = "store-B"
            fencedRepo.fixture = FixtureStore()
            fencedRepo.releaseStore?.resume()
            await operation.value
            check(fencedRepo.fixture?.mutations == 0, "source change during store open rejects \(numeric ? "numeric" : "boolean") write")
            check(!writer.canWrite(), "captured main writer stops new taps after source replacement")
        }
        let validRepo = Repository()
        let validWriter = RootWriter(repo: validRepo).value
        await validWriter.save("2026-10-22", .answer(question: "Q", yes: true))
        await validWriter.save("2026-10-22", .amount(question: "Q", value: 2))
        await validWriter.clear("2026-10-22", "Q")
        check(validRepo.fixture?.mutations == 3 && validRepo.journalRevision == 3,
              "same-source boolean, numeric, and clear writes still persist and publish revisions")
        validRepo.verifiedExternalSurfaceFenced = true
        await validWriter.save("2026-10-22", .answer(question: "Q", yes: false))
        check(validRepo.fixture?.mutations == 3 && !validWriter.canWrite(),
              "active replacement fence prevents captured main writer from saving")
        let clearRepo = Repository()
        let clearWriter = RootWriter(repo: clearRepo).value
        clearRepo.holdNextStore = true
        let clearing = Task { @MainActor in await clearWriter.clear("2026-10-22", "Q") }
        for _ in 0..<1000 where clearRepo.releaseStore == nil { try? await Task.sleep(for: .milliseconds(1)) }
        clearRepo.journalEntrySourceContext = "store-B"
        clearRepo.fixture = FixtureStore()
        clearRepo.releaseStore?.resume()
        await clearing.value
        check(clearRepo.fixture?.mutations == 0, "source change during store open rejects clear")
        for returnToOriginalDay in [false, true] {
            let model = JournalQuickLogModel()
            var saved: [(String, JournalQuickLog.Write)] = []
            var release: CheckedContinuation<Void, Never>?
            var suspendedFirst = false
            model.writer = .init(save: { day, write in
                if !suspendedFirst {
                    suspendedFirst = true
                    await withCheckedContinuation { release = $0 }
                }
                saved.append((day, write))
            }, clear: { _, _ in }, canWrite: { true }, didWrite: {})
            model.seed(day: "2026-10-22", sourceContext: "store-A", tiles: tiles, native: .init(), imported: .init(), earlier: .init(), epoch: 0)
            model.markRest()
            for _ in 0..<1000 where release == nil { try? await Task.sleep(for: .milliseconds(1)) }
            if returnToOriginalDay {
                model.reset()
                model.seed(day: "2026-10-21", sourceContext: "store-A", tiles: tiles, native: .init(), imported: .init(), earlier: .init(), epoch: model.changeEpoch)
                model.reset()
                model.seed(day: "2026-10-22", sourceContext: "store-A", tiles: tiles, native: .init(), imported: .init(), earlier: .init(), epoch: model.changeEpoch)
            }
            let changedTile = tiles.last!
            model.set(changedTile, yes: true)
            try? await Task.sleep(for: .milliseconds(20))
            check(saved.isEmpty, "newer tap waits for suspended bulk save \(returnToOriginalDay ? "after A-B-A" : "on same day")")
            release?.resume()
            for _ in 0..<1000 where saved.count < 11 { try? await Task.sleep(for: .milliseconds(1)) }
            check(saved.count == 11 && saved.last?.1 == .amount(question: changedTile.id, value: 1),
                  "latest tap wins over accepted older bulk answer \(returnToOriginalDay ? "after A-B-A" : "on same day")")
        }
        let high = JournalEntry(day: "2026-10-22", question: "Q", answeredYes: true, numericValue: 3)
        let low = JournalEntry(day: "2026-10-22", question: "Q", answeredYes: false, numericValue: 0)
        let merged = Repository.mergeJournal(imported: [high, low], native: [])
        check(merged.first?.numericValue == 3 && merged.first?.answeredYes == true,
              "first imported owner wins overlapping answers")
        repo.fixture = FixtureStore()
        repo.fixture?.entries = ["whoop-active": [high], "my-whoop": [low]]
        let visibleDay = await repo.journalDayValues(day: "2026-10-22")
        check(visibleDay.imported.numeric["Q"] == 3 && visibleDay.imported.answers["Q"] == true,
              "Journal day uses the same active-owner precedence as analytics")
        let before = JournalEntry(day: "2026-10-21", question: "before", answeredYes: true)
        let end = JournalEntry(day: "2026-10-23", question: "end", answeredYes: true)
        let after = JournalEntry(day: "2026-10-24", question: "after", answeredYes: true)
        repo.fixture?.entries["whoop-active"] = [before, high, end, after]
        let bounded = await repo.journalEntries(from: "2026-10-22", to: "2026-10-23")
        check(bounded.map(\.question) == ["Q", "end"], "bounded Journal reads include both ends and exclude adjacent days")
        let invalid = await repo.journalEntries(from: "2026-10-01", to: "2026-10-99")
        check(invalid.isEmpty, "invalid date range is rejected before reading Journal rows")
        let override = Repository.mergeJournal(imported: [high, low], native: [low])
        check(override.first?.numericValue == 0 && override.first?.answeredYes == false,
              "explicit local zero overrides imported amount")
        let editor = JournalCatalogStore(defaults: defaults)
        editor.rename("Did you read before bed?", to: "Bedtime reading")
        editor.setKind("Did you read before bed?", to: .numeric(unitLabel: "pages"))
        editor.addCustom("Stretching")
        catalog.reloadFromDefaults()
        let editedItems = catalog.resolvedItems(imported: [])
        let editedTiles = JournalQuickLogTile.tiles(from: editedItems, active: Set(editedItems.map(\.canonical)))
        let reading = editedTiles.first { $0.id == "Did you read before bed?" }
        check(reading?.name == "Bedtime reading" && reading?.amount?.unit.plural == "pages",
              "separate editor catalog reload updates tile label and answer type")
        check(editedTiles.contains { $0.id == "Stretching" }, "separate editor catalog reload adds custom question")
        editor.remove("Stretching")
        catalog.reloadFromDefaults()
        check(!catalog.resolvedItems(imported: []).contains { $0.canonical == "Stretching" },
              "separate editor catalog reload removes deleted custom question")
        exit(failed == 0 ? 0 : 1)
    }
}
'''
    with tempfile.TemporaryDirectory(prefix='noop-journal-review-') as scratch:
        path = Path(scratch)
        (path / 'main.swift').write_text(swift)
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(path / 'cache'),
                        '-swift-version', '6', str(path / 'main.swift'), '-o', str(path / 'harness')], check=True)
        return subprocess.run([str(path / 'harness')], check=False).returncode


if __name__ == '__main__':
    raise SystemExit(main())
