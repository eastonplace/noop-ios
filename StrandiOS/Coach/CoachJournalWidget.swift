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
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            header
            Text("The night and day leading into this morning.")
                .coachFont(12.5, .regular, relativeTo: .footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

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
        .padding(NoopMetrics.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: NoopMetrics.radius5, style: .continuous)
            .fill(StrandPalette.card))
        .overlay(RoundedRectangle(cornerRadius: NoopMetrics.radius5, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
        .tint(StrandPalette.journalAccent)
        .disabled(isPreview)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach.journal.widget")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            if typeSize.isAccessibilitySize {
                SectionEyebrow("Journal", systemImage: "book.closed", tint: .journal)
                openButton
            } else {
                HStack(alignment: .center, spacing: NoopMetrics.space2) {
                    SectionEyebrow("Journal", systemImage: "book.closed", tint: .journal)
                    openButton
                }
            }
            Text("Wake day: \(day)")
                .coachFont(13, .medium, relativeTo: .footnote, digits: true)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("coach.journal.day")
        }
    }

    private var openButton: some View {
        Button(action: onOpen) {
            HStack(spacing: 5) {
                Text("Full Journal").fixedSize(horizontal: false, vertical: true)
                Image(systemName: "arrow.up.right").accessibilityHidden(true)
            }
            .coachFont(12.5, .medium, relativeTo: .footnote)
            .foregroundStyle(StrandPalette.journalAccent)
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open full Journal")
        .accessibilityIdentifier("coach.journal.open")
    }

    private var accessNotice: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Your check-in stays hidden here until you allow Coach to read your records. You can still use the full Journal.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            actionButton("Use records for insights", symbol: "lock.shield", identifier: "coach.journal.access",
                         action: onInsights)
        }
        .accessibilityIdentifier("coach.journal.consent")
    }

    @ViewBuilder private var checkInContent: some View {
        if items.isEmpty {
            Text("Choose what to track in the full Journal.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: NoopMetrics.space2) {
                ForEach(items) { item in quickRow(item) }
            }
        }

        if mood.map({ (1...5).contains($0) }) == true || note != nil {
            Divider().overlay(StrandPalette.hairline)
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
            VStack(spacing: NoopMetrics.space2) { secondaryActions }
        } else {
            HStack(spacing: NoopMetrics.space2) { secondaryActions }
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
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: item.title)
                .coachFont(13.5, .medium, relativeTo: .subheadline)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(answerStatus(for: item.id))
                .coachFont(11.5, .regular, relativeTo: .caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answerControls(_ item: CoachJournalQuickItem) -> some View {
        HStack(spacing: NoopMetrics.space1) {
            answerButton(true, item: item)
            answerButton(false, item: item)
        }
    }

    private func answerButton(_ value: Bool, item: CoachJournalQuickItem) -> some View {
        let selected = CoachJournalDraftPolicy.answer(for: item.id, saved: savedAnswers, draft: draftAnswers) == value
        return Button {
            guard canRead, !isLoading, !isPreview else { return }
            CoachJournalDraftPolicy.select(value, for: item.id, in: &draftAnswers)
        } label: {
            Text(value ? "Yes" : "No")
                .coachFont(13, .semibold, relativeTo: .footnote)
                .foregroundStyle(selected ? StrandPalette.onInk : StrandPalette.textSecondary)
                .padding(.horizontal, NoopMetrics.space3)
                .frame(minWidth: 44, minHeight: 44)
                .background(Capsule().fill(selected ? StrandPalette.textPrimary : StrandPalette.inset))
                .overlay(Capsule().strokeBorder(selected ? StrandPalette.journalAccent : StrandPalette.hairlineStrong,
                                                lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title): \(value ? String(localized: "Yes") : String(localized: "No"))")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint("Changes this draft. Review the check-in before saving.")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("coach.journal.\(item.id).\(value ? "yes" : "no")")
    }

    private func answerStatus(for id: String) -> String {
        guard let value = CoachJournalDraftPolicy.answer(for: id, saved: savedAnswers, draft: draftAnswers) else {
            return String(localized: "Not logged")
        }
        if savedAnswers[id] == value {
            return value ? String(localized: "Logged yes") : String(localized: "Logged no")
        }
        return value ? String(localized: "Yes · not saved") : String(localized: "No · not saved")
    }

    @ViewBuilder private var savedSummary: some View {
        if let mood, (1...5).contains(mood) {
            Label("Mood: \(MoodStore.label(for: mood))", systemImage: "face.smiling")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityIdentifier("coach.journal.mood")
        }
        if let note {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text("Saved note").font(StrandFont.caption.weight(.medium))
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(verbatim: note)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("coach.journal.note")
        }
    }

    private var reviewActions: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text("Your changes are ready to review. Nothing has been saved yet.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onReview) {
                Label("Review check-in", systemImage: "checkmark.circle")
                    .coachFont(14, .semibold, relativeTo: .subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .accessibilityIdentifier("coach.journal.review")
            Button {
                guard !isPreview else { return }
                CoachJournalDraftPolicy.discard(&draftAnswers)
            } label: {
                Text("Discard changes")
                    .coachFont(12.5, .medium, relativeTo: .footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("coach.journal.discard")
        }
    }

    @ViewBuilder private var secondaryActions: some View {
        actionButton("Write or dictate", symbol: "square.and.pencil", identifier: "coach.journal.compose",
                     action: onCompose)
        actionButton("Ask about patterns", symbol: "sparkle", identifier: "coach.journal.insights",
                     action: onInsights)
    }

    private func actionButton(_ title: LocalizedStringKey, symbol: String, identifier: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(StrandPalette.journalAccent).accessibilityHidden(true)
                Text(title).fixedSize(horizontal: false, vertical: true)
            }
            .coachFont(12.5, .medium, relativeTo: .footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.horizontal, NoopMetrics.space2)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
                .strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
#endif
