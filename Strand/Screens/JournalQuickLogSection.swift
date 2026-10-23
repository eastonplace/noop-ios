import SwiftUI
import StrandDesign

// MARK: - Model

/// The answers on the Journal page for one day, and every way a tap changes them. The page that hosts it (the
/// Journal screen, or the Journal opened from Coach) loads a day's answers and hands them in with `seed`; the model
/// shows each tap at once, writes it through the host's `Writer`, and ignores a reload that began before the last
/// tap so a slow read can never put an old answer back on screen.
@MainActor
final class JournalQuickLogModel: ObservableObject {
    /// How the host stores an answer. Each call is awaited, so the model knows when a tap has landed.
    struct Writer {
        var save: @MainActor (_ day: String, _ write: JournalQuickLog.Write) async -> Void
        var clear: @MainActor (_ day: String, _ question: String) async -> Void
        /// Asked at the moment of every tap: false stops it (no consent, a source swap in progress).
        var canWrite: @MainActor () -> Bool
        /// Called once a run of writes has landed, so the host can refresh what it shows around the grid.
        var didWrite: @MainActor () -> Void

        static let none = Writer(save: { _, _ in }, clear: { _, _ in }, canWrite: { false }, didWrite: {})
    }

    private enum Step {
        case save(JournalQuickLog.Write)
        case clear(String)
    }

    /// The day the values below belong to. nil while a day is loading: nothing can be tapped until it is set.
    @Published private(set) var dayKey: String?
    @Published private(set) var tiles: [JournalQuickLogTile] = []
    /// Taps made on this page (and anything stored natively). Imported answers sit beside them, never on top.
    @Published private(set) var native = JournalQuickLog.DayValues()
    @Published private(set) var imported = JournalQuickLog.DayValues()
    /// The earlier day's answers, for "Same as yesterday".
    @Published private(set) var earlier = JournalQuickLog.DayValues()
    /// Bumped for each tap that changes an answer, and for the tap that answers the last question. They drive the
    /// light and the success haptic.
    @Published private(set) var tapTick = 0
    @Published private(set) var completionTick = 0

    var writer: Writer = .none

    /// Counts every change made here. A host reads it before it reads the day, and hands it back with the result.
    private(set) var changeEpoch = 0
    private var generation = 0
    private var inFlight = 0
    /// Accepted actions keep their order across day changes. A newer tap must follow the whole older bulk action.
    private var writeTail: Task<Void, Never>?

    var effective: JournalQuickLog.DayValues { JournalQuickLog.merged(native: native, imported: imported) }
    var total: Int { tiles.count }
    var answeredCount: Int { JournalQuickLog.answeredCount(tiles.map(\.target), in: effective) }
    var isComplete: Bool { total > 0 && answeredCount == total }

    func state(of tile: JournalQuickLogTile) -> JournalQuickLog.TileState {
        JournalQuickLog.state(of: tile.id, hasAmount: tile.amount != nil, in: effective)
    }

    /// Whether the tile has an answer of its own that "Clear" would remove (an imported answer cannot be cleared here).
    func hasNativeAnswer(_ tile: JournalQuickLogTile) -> Bool { native.isAnswered(tile.id) }

    /// The page moves to another day: nothing shows, and nothing can be tapped, until that day's answers arrive.
    func reset() {
        generation += 1
        inFlight = 0
        dayKey = nil
        native = .init()
        imported = .init()
        earlier = .init()
    }

    /// Fresh values from a read that began when `changeEpoch` was `epoch`. For the day already on screen they are
    /// applied only if nothing was tapped since and no write is still on its way; the next read catches up.
    func seed(day: String, tiles: [JournalQuickLogTile], native: JournalQuickLog.DayValues,
              imported: JournalQuickLog.DayValues, earlier: JournalQuickLog.DayValues, epoch: Int) {
        if dayKey != day {
            generation += 1
            inFlight = 0
            dayKey = day
            self.tiles = tiles
            self.native = native
            self.imported = imported
            self.earlier = earlier
            return
        }
        if self.tiles != tiles { self.tiles = tiles }
        guard inFlight == 0, epoch == changeEpoch else { return }
        if self.native != native { self.native = native }
        if self.imported != imported { self.imported = imported }
        if self.earlier != earlier { self.earlier = earlier }
    }

    // MARK: Taps

    /// A tap on a tile: Yes, then No, then Yes again; or one more step for a counted tile.
    func tap(_ tile: JournalQuickLogTile) {
        guard canAct else { return }
        let current = state(of: tile)
        if let amount = tile.amount {
            var base: Double?
            if case .amount(let value) = current { base = value }
            commit([.save(.amount(question: tile.id, value: JournalQuickLog.stepUp(base, step: amount.step)))])
        } else {
            let answer: Bool? = {
                switch current {
                case .yes: return true
                case .no: return false
                case .amount(let value): return value > 0
                case .unanswered: return nil
                }
            }()
            commit([.save(.answer(question: tile.id, yes: JournalQuickLog.tapped(answer)))])
        }
    }

    /// The minus glyph on a counted tile: one step down, and 0 is an explicit No.
    func stepDown(_ tile: JournalQuickLogTile) {
        guard canAct, let amount = tile.amount, case .amount(let value) = state(of: tile),
              let next = JournalQuickLog.stepDown(value, step: amount.step) else { return }
        commit([.save(.amount(question: tile.id, value: next))])
    }

    /// The menu's "Yes" and "No".
    func set(_ tile: JournalQuickLogTile, yes: Bool) {
        guard canAct else { return }
        if let amount = tile.amount {
            commit([.save(yes ? .amount(question: tile.id, value: amount.step) : .amount(question: tile.id, value: 0))])
        } else {
            commit([.save(.answer(question: tile.id, yes: yes))])
        }
    }

    /// The menu's "None today" on a counted tile: an explicit 0.
    func setNone(_ tile: JournalQuickLogTile) {
        guard canAct else { return }
        commit([.save(.amount(question: tile.id, value: 0))])
    }

    /// The menu's "Clear": back to blank (or to the imported answer, if there is one).
    func clear(_ tile: JournalQuickLogTile) {
        guard canAct, hasNativeAnswer(tile) else { return }
        commit([.clear(tile.id)])
    }

    // MARK: Actions

    var markRestWrites: [JournalQuickLog.Write] { JournalQuickLog.markRest(tiles.map(\.target), in: effective) }

    var copyEarlierWrites: [JournalQuickLog.Write] {
        JournalQuickLog.copyFromEarlier(tiles.map(\.target), current: effective, earlier: earlier)
    }

    /// "Mark the rest No".
    func markRest() {
        guard canAct else { return }
        commit(markRestWrites.map(Step.save))
    }

    /// "Same as yesterday": fills only the blanks.
    func copyEarlier() {
        guard canAct else { return }
        commit(copyEarlierWrites.map(Step.save))
    }

    // MARK: Writing

    private var canAct: Bool { dayKey != nil && writer.canWrite() }

    private func commit(_ steps: [Step]) {
        guard let day = dayKey, !steps.isEmpty else { return }
        let wasComplete = isComplete
        for step in steps {
            switch step {
            case .save(let write): apply(write)
            case .clear(let question):
                native.answers[question] = nil
                native.numeric[question] = nil
            }
        }
        changeEpoch += 1
        if !wasComplete && isComplete { completionTick += 1 } else { tapTick += 1 }
        let run = generation
        let writer = writer
        let previous = writeTail
        inFlight += 1
        writeTail = Task { @MainActor in
            await previous?.value
            for step in steps {
                // Accepted answers belong to the captured day and writer even after the page moves.
                // Each host writer still enforces its consent and source checks before persistence.
                switch step {
                case .save(let write): await writer.save(day, write)
                case .clear(let question): await writer.clear(day, question)
                }
            }
            guard run == self.generation else { return }
            self.inFlight -= 1
            writer.didWrite()
        }
    }

    private func apply(_ write: JournalQuickLog.Write) {
        switch write {
        case .answer(let question, let yes):
            native.answers[question] = yes
            native.numeric[question] = nil
        case .amount(let question, let value):
            native.answers[question] = value > 0
            native.numeric[question] = value
        }
    }
}

// MARK: - Progress

/// "4 of 10" and its bar, under whatever the host puts first (the day).
struct JournalQuickLogProgress<Leading: View>: View {
    @ObservedObject var model: JournalQuickLogModel
    private let leading: Leading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title3) private var countSize: CGFloat = 20

    init(model: JournalQuickLogModel, @ViewBuilder leading: () -> Leading) {
        self.model = model
        self.leading = leading()
    }

    private var answered: Int { model.dayKey == nil ? 0 : model.answeredCount }
    private var fraction: Double { model.total == 0 ? 0 : Double(answered) / Double(model.total) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: NoopMetrics.space2) {
                leading
                Spacer(minLength: NoopMetrics.space2)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: "\(answered)")
                        .font(StrandFont.number(countSize, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                        .contentTransition(.numericText())
                    Text("of \(model.total)")
                        .font(StrandFont.subhead)
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(answered) of \(model.total) answered")
                .accessibilityIdentifier("journal.progress")
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(StrandPalette.hairline)
                    Rectangle()
                        .fill(StrandPalette.journalAccent)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : StrandMotion.gentle, value: answered)
    }
}

// MARK: - Section

/// "What happened": the day's questions as a grid of tiles with a hairline between the rows, the two actions under
/// it, and the line that says the day is done. Tapping saves. Used by the Journal page and by the Journal opened from Coach.
struct JournalQuickLogSection: View {
    @ObservedObject var model: JournalQuickLogModel
    /// The day this section is for. Until the model holds that day, the grid is blank and cannot be tapped.
    let dayKey: String
    let words: JournalBehaviorDay.Words
    /// Days in a row up to and including this one, for the done line. 0 leaves the line out: the Journal page
    /// leaves it out because the dots under the grid already say "N-day streak".
    var streak: Int = 0

    @Environment(\.dynamicTypeSize) private var typeSize

    private var ready: Bool { model.dayKey == dayKey }

    private var columnCount: Int {
        if typeSize >= .accessibility3 { return 1 }
        return typeSize.isAccessibilitySize ? 2 : 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow("What happened", tint: .journal, trailing: .text(hint))
                .padding(.bottom, NoopMetrics.space1)
            grid
            actions
            if ready && model.isComplete { doneLine }
        }
        .strandHaptic(.light, trigger: model.tapTick)
        .strandHaptic(.success, trigger: model.completionTick)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journal.quicklog")
    }

    private var hint: String {
        ready && model.answeredCount > 0 ? String(localized: "Tap again for No") : String(localized: "Tap what applies")
    }

    // MARK: Grid

    private var rows: [[JournalQuickLogTile]] {
        stride(from: 0, to: model.tiles.count, by: columnCount).map {
            Array(model.tiles[$0..<min($0 + columnCount, model.tiles.count)])
        }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                if rowIndex > 0 {
                    Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
                }
                HStack(spacing: NoopMetrics.space3) {
                    ForEach(row) { tile in
                        JournalQuickLogCell(
                            tile: tile,
                            state: ready ? model.state(of: tile) : .unanswered,
                            canClear: ready && model.hasNativeAnswer(tile),
                            isEnabled: ready,
                            model: model)
                    }
                    if row.count < columnCount {
                        ForEach(0..<(columnCount - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityHidden(true)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!ready)
    }

    // MARK: Actions

    private var canCopyEarlier: Bool { ready && !model.copyEarlierWrites.isEmpty }
    private var restCount: Int { ready ? model.markRestWrites.count : 0 }

    private var restTitle: String {
        model.answeredCount == 0 ? String(localized: "Mark the rest No")
                                 : String(localized: "Mark the other \(restCount) No")
    }

    @ViewBuilder private var actions: some View {
        if canCopyEarlier || restCount > 0 {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout(spacing: NoopMetrics.space5))
            layout {
                if canCopyEarlier {
                    textAction(words.repeatTitle, symbol: "arrow.counterclockwise", id: "journal.repeatYesterday") {
                        model.copyEarlier()
                    }
                }
                if restCount > 0 {
                    textAction(restTitle, symbol: nil, id: "journal.markRestNo") { model.markRest() }
                }
            }
            .padding(.top, NoopMetrics.space1)
        }
    }

    private func textAction(_ title: String, symbol: String?, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: NoopMetrics.space1) {
                if let symbol {
                    Image(systemName: symbol).font(StrandFont.caption.weight(.semibold)).accessibilityHidden(true)
                }
                Text(verbatim: title).fixedSize(horizontal: false, vertical: true)
            }
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(StrandPalette.journalAccent)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(FlatRowPressStyle())
        .accessibilityIdentifier(id)
    }

    // MARK: Done

    private var doneLine: some View {
        VStack(spacing: 0) {
            Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                Image(systemName: "checkmark")
                    .font(StrandFont.body.weight(.semibold))
                    .foregroundStyle(StrandPalette.journalAccent)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: words.doneTitle)
                        .font(StrandFont.body.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let streakLine = JournalQuickLog.streakText(streak) {
                        Text(verbatim: streakLine)
                            .font(StrandFont.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Text("Heads-Up and Coach can use all of it.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, NoopMetrics.space3)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("journal.done")
            Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
        }
        .padding(.top, NoopMetrics.space2)
        .transition(.opacity)
    }
}

// MARK: - Cell

/// One tile of the grid: the question's symbol, its name, and what was logged. The whole tile is one button.
/// A counted tile also shows a bare minus once there is something to take off.
private struct JournalQuickLogCell: View {
    let tile: JournalQuickLogTile
    let state: JournalQuickLog.TileState
    let canClear: Bool
    let isEnabled: Bool
    let model: JournalQuickLogModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = 84
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 18

    private var stateText: String { JournalQuickLog.stateText(state, unit: tile.amount?.unit) }

    private var glyphColor: Color {
        switch state {
        case .yes, .amount: return tile.tint
        case .unanswered, .no: return StrandPalette.textTertiary
        }
    }

    private var nameColor: Color { state.isAnswered ? StrandPalette.textPrimary : StrandPalette.textSecondary }

    private var stateColor: Color {
        switch state {
        case .yes, .amount: return tile.tint
        case .no, .unanswered: return StrandPalette.textTertiary
        }
    }

    private var showsMinus: Bool {
        if case .amount = state { return true }
        return false
    }

    var body: some View {
        Button { model.tap(tile) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Image(systemName: tile.icon)
                    .font(.system(size: glyphSize, weight: .medium))
                    .foregroundStyle(glyphColor)
                    .frame(height: 24, alignment: .leading)
                    .accessibilityHidden(true)
                Text(verbatim: tile.name)
                    .font(StrandFont.subhead)
                    .foregroundStyle(nameColor)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: stateText.isEmpty ? " " : stateText)
                    .font(StrandFont.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(stateColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : StrandMotion.interactive, value: state)
        }
        .buttonStyle(FlatRowPressStyle())
        .overlay(alignment: .topTrailing) {
            if showsMinus {
                Button { model.stepDown(tile) } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
                .transition(.opacity)
            }
        }
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityHint(Text(verbatim: accessibilityHint))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("journal.tile.\(tile.id)")
        .adjustable(tile.amount != nil && isEnabled) { direction in
            switch direction {
            case .increment: model.tap(tile)
            case .decrement: model.stepDown(tile)
            @unknown default: break
            }
        }
    }

    @ViewBuilder private var menu: some View {
        if tile.amount != nil {
            Button("None today") { model.setNone(tile) }
        } else {
            Button("Yes") { model.set(tile, yes: true) }
            Button("No") { model.set(tile, yes: false) }
        }
        if canClear { Button("Clear") { model.clear(tile) } }
    }

    private var accessibilityLabel: String {
        let answer: String
        switch state {
        case .unanswered: answer = String(localized: "not answered")
        case .yes: answer = String(localized: "yes")
        case .no: answer = String(localized: "no")
        case .amount: answer = stateText
        }
        return "\(tile.name), \(answer)"
    }

    private var accessibilityHint: String {
        if let amount = tile.amount {
            return String(localized: "Double-tap to add \(JournalQuickLog.amountText(amount.step, unit: amount.unit)). Swipe up or down to change it.")
        }
        return state == .yes ? String(localized: "Double-tap to switch to No") : String(localized: "Double-tap to log Yes")
    }
}

private extension View {
    /// VoiceOver's swipe-up / swipe-down adjustment, only on a tile that counts an amount.
    @ViewBuilder func adjustable(_ enabled: Bool, action: @escaping (AccessibilityAdjustmentDirection) -> Void) -> some View {
        if enabled { accessibilityAdjustableAction(action) } else { self }
    }
}
