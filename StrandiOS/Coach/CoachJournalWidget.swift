import Foundation

struct CoachJournalQuickItem: Identifiable, Equatable {
    let id: String
    let title: String
}

/// Pure draft semantics shared by the widget and its focused regression tests.
enum CoachJournalDraftPolicy {
    /// Only explicit selections can be changes. Missing keys never mean an implicit clear or "No".
    static func changes(saved: [String: Bool], draft: [String: Bool]) -> [String: Bool] {
        draft.filter { saved[$0.key] != $0.value }
    }

    static func answer(for id: String, saved: [String: Bool], draft: [String: Bool]) -> Bool? {
        draft[id] ?? saved[id]
    }

    /// Reselecting the same value is idempotent; clearing saved answers belongs to the full Journal.
    static func select(_ value: Bool, for id: String, in draft: inout [String: Bool]) {
        draft[id] = value
    }

    /// A draft contains intent, not a saved snapshot. Clearing overrides lets later saved edits win.
    static func discard(_ draft: inout [String: Bool]) {
        draft = [:]
    }
}

#if os(iOS)
import SwiftUI
import StrandDesign

/// A value-fed check-in on the Coach canvas. Selection edits only the supplied draft; this view
/// never reads records, creates a proposal, or saves. Its owner supplies the day and confirmation flow.
///
/// Flat, like the other Coach sections: an eyebrow, a plain "Open" on the right, and the rows on the canvas.
struct CoachJournalWidget: View {
    let day: String
    let items: [CoachJournalQuickItem]
    let savedAnswers: [String: Bool]
    @Binding var draftAnswers: [String: Bool]
    let mood: Int?
    let notePreview: String?
    let isLoading: Bool
    let canRead: Bool
    var isPreview = false
    let status: String?
    let onOpen: () -> Void
    let onCompose: () -> Void
    let onReview: () -> Void
    let onInsights: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var changes: [String: Bool] {
        CoachJournalDraftPolicy.changes(saved: savedAnswers, draft: draftAnswers)
    }

    private var note: String? {
        guard let value = notePreview?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            header
            if !canRead {
                accessNotice
            } else if isLoading {
                HStack(spacing: NoopMetrics.space2) {
                    ProgressView().controlSize(.small)
                    Text("Loading your check-in…").font(StrandFont.caption)
                }
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("coach.journal.loading")
            } else {
                checkInContent
            }

            if isPreview {
                Text("Sample check-in · preview only")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityIdentifier("coach.journal.preview")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(StrandPalette.journalAccent)
        .disabled(isPreview)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach.journal.widget")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space2) {
            SectionEyebrow("Journal", systemImage: "book.closed", tint: .journal)
            Spacer(minLength: NoopMetrics.space2)
            Button(action: onOpen) {
                HStack(spacing: 3) {
                    Text("Open")
                    Image(systemName: "chevron.right").font(StrandFont.caption).accessibilityHidden(true)
                }
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open full Journal")
            .accessibilityIdentifier("coach.journal.open")
        }
    }

    /// Locked: one line and one plain action.
    private var accessNotice: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) { lockedLine; allowButton }
            } else {
                HStack(alignment: .center, spacing: NoopMetrics.space3) {
                    lockedLine
                    Spacer(minLength: NoopMetrics.space2)
                    allowButton
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach.journal.consent")
    }

    private var lockedLine: some View {
        Text("Let Coach read your records to see journal patterns.")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var allowButton: some View {
        CoachTextButton("Allow", action: onInsights)
            .accessibilityLabel("Allow Coach to read your records")
            .accessibilityIdentifier("coach.journal.access")
    }

    @ViewBuilder private var checkInContent: some View {
        // Which day this logs, in the Journal's own words: "Yesterday" unless another day was chosen in the full Journal.
        Text(verbatim: JournalBehaviorDay.words(forStorageKey: day).moodTitle)
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .accessibilityIdentifier("coach.journal.day")

        if items.isEmpty {
            Text("Choose what to track in the full Journal.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 0) {
                ForEach(items) { item in quickRow(item) }
            }
        }

        if mood.map({ (1...5).contains($0) }) == true || note != nil {
            savedSummary
        }

        if !changes.isEmpty {
            reviewActions
        }

        if let status, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(verbatim: status)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("coach.journal.status")
        }

        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 0) { secondaryActions }
        } else {
            HStack(spacing: NoopMetrics.space5) { secondaryActions; Spacer(minLength: 0) }
        }
    }

    @ViewBuilder private func quickRow(_ item: CoachJournalQuickItem) -> some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    quickLabel(item)
                    answerControls(item)
                }
            } else {
                HStack(spacing: NoopMetrics.space2) {
                    quickLabel(item)
                    Spacer(minLength: NoopMetrics.space1)
                    answerControls(item)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach.journal.item.\(item.id)")
    }

    private func quickLabel(_ item: CoachJournalQuickItem) -> some View {
        // The chosen Yes or No is already highlighted, and the unsaved count sits below the list. No subtitle.
        Text(verbatim: item.title)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answerControls(_ item: CoachJournalQuickItem) -> some View {
        HStack(spacing: NoopMetrics.space1) {
            answerButton(true, item: item)
            answerButton(false, item: item)
        }
    }

    /// Yes and No are plain words: the chosen one is accent and bold, the other quiet. No fill, border or capsule.
    private func answerButton(_ value: Bool, item: CoachJournalQuickItem) -> some View {
        let selected = CoachJournalDraftPolicy.answer(for: item.id, saved: savedAnswers, draft: draftAnswers) == value
        return Button {
            guard canRead, !isLoading, !isPreview else { return }
            CoachJournalDraftPolicy.select(value, for: item.id, in: &draftAnswers)
        } label: {
            Text(value ? "Yes" : "No")
                .font(StrandFont.subhead.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? StrandPalette.accent : StrandPalette.textSecondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title): \(value ? String(localized: "Yes") : String(localized: "No"))")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint("Changes this draft. Review the check-in before saving.")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("coach.journal.\(item.id).\(value ? "yes" : "no")")
    }

    @ViewBuilder private var savedSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let mood, (1...5).contains(mood) {
                Text("Mood · \(MoodStore.label(for: mood))")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityIdentifier("coach.journal.mood")
            }
            if let note {
                Text(verbatim: note)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("coach.journal.note")
            }
        }
    }

    /// Unsaved choices: a count, then Discard and Review as plain words.
    private var reviewActions: some View {
        HStack(spacing: NoopMetrics.space4) {
            Text("\(changes.count) not saved")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            CoachTextButton("Discard", tint: StrandPalette.textSecondary) {
                guard !isPreview else { return }
                CoachJournalDraftPolicy.discard(&draftAnswers)
            }
            .accessibilityIdentifier("coach.journal.discard")
            CoachTextButton("Review", action: onReview)
                .accessibilityIdentifier("coach.journal.review")
        }
    }

    @ViewBuilder private var secondaryActions: some View {
        actionButton("Write or dictate", symbol: "square.and.pencil", identifier: "coach.journal.compose",
                     action: onCompose)
        actionButton("Ask about patterns", symbol: "chart.xyaxis.line", identifier: "coach.journal.insights",
                     action: onInsights)
    }

    private func actionButton(_ title: LocalizedStringKey, symbol: String, identifier: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).accessibilityHidden(true)
                Text(title).fixedSize(horizontal: false, vertical: true)
            }
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
#endif
