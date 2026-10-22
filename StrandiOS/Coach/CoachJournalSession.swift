import Foundation

enum CoachComposerMode: Equatable {
    case coach, journal
}

/// Manual capture is a deliberate local action, not permission for Coach to inspect personal records.
struct CoachJournalAccessPolicy: Equatable {
    let coachEnabled: Bool
    let usesPersonalData: Bool
    let isPreview: Bool
    let hasRepository: Bool
    let sourceFenced: Bool

    var canUseManualJournal: Bool { hasRepository && !isPreview && !sourceFenced }
    var canReadAutomatically: Bool { canUseManualJournal && coachEnabled && usesPersonalData }
}

enum CoachComposerRouting {
    enum Destination: Equatable { case coach, journalReview, blocked }

    static func destination(mode: CoachComposerMode, access: CoachJournalAccessPolicy,
                            modelAvailable: Bool) -> Destination {
        switch mode {
        case .journal: return access.canUseManualJournal ? .journalReview : .blocked
        case .coach: return !access.isPreview && access.coachEnabled && modelAvailable ? .coach : .blocked
        }
    }
}

/// Keeps the explicit wake-day key and the legacy Today/Yesterday/Tomorrow controls in agreement.
/// Offsets are calendar days, never fixed 24-hour intervals, and computing an offset does not move a key.
enum CoachJournalDaySelection {
    static func key(dayOffset: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
        key(for: calendar.date(byAdding: .day, value: -dayOffset, to: now) ?? now, calendar: calendar)
    }

    static func date(for day: String, calendar: Calendar = .current) -> Date? {
        let components = day.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3, components[0].count == 4,
              components[1].count == 2, components[2].count == 2,
              let year = Int(components[0]), let month = Int(components[1]), let date = Int(components[2]),
              let value = calendar.date(from: DateComponents(year: year, month: month, day: date)),
              key(for: value, calendar: calendar) == day else { return nil }
        return value
    }

    static func offset(for day: String, now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let selected = date(for: day, calendar: calendar) else { return nil }
        return calendar.dateComponents([.day], from: selected, to: calendar.startOfDay(for: now)).day
    }

    private static func key(for date: Date, calendar: Calendar) -> String {
        String(format: "%04d-%02d-%02d", calendar.component(.year, from: date),
               calendar.component(.month, from: date), calendar.component(.day, from: date))
    }
}

/// Identity, not cancellation alone, fences every awaited read. Restoring consent or returning to the
/// same day cannot make an earlier request current again.
struct CoachJournalRequestGate {
    struct Request: Equatable {
        let id = UUID()
        let day: String
        let sourceContext: String
    }

    private var day = ""
    private var sourceContext = ""
    private var canRead = false
    private var request: Request?

    @discardableResult
    mutating func configure(day: String, sourceContext: String, canRead: Bool) -> Bool {
        guard self.day != day || self.sourceContext != sourceContext || self.canRead != canRead else { return false }
        self.day = day
        self.sourceContext = sourceContext
        self.canRead = canRead
        request = nil
        return true
    }

    mutating func begin() -> Request? {
        guard canRead else { return nil }
        let next = Request(day: day, sourceContext: sourceContext)
        request = next
        return next
    }

    mutating func cancel() { request = nil }

    func accepts(_ candidate: Request, day: String, sourceContext: String) -> Bool {
        canRead && request == candidate && candidate.day == day && candidate.sourceContext == sourceContext
            && self.day == day && self.sourceContext == sourceContext
    }
}

#if os(iOS)
import Combine
import StrandAnalytics

/// Owns only this feature's selected-day values. The transcript receives plain values, never the
/// repository's live heart-rate publications. A nil repository is the isolated preview path.
@MainActor
final class CoachJournalSession: ObservableObject {
    let repository: Repository?
    @Published private(set) var catalog: JournalCatalogStore?
    @Published private(set) var day: String
    @Published private(set) var snapshot: CoachJournalSnapshot?
    @Published var draftAnswers: [String: Bool] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var status: String?
    @Published private(set) var access: CoachJournalAccessPolicy

    private let manualReads: Bool
    private var active = false
    private var coachEnabled = false
    private var usesPersonalData = false
    private var isPreview = true
    private var gate = CoachJournalRequestGate()
    private var readTask: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []
    private var observedRevision: String?

    init(repository: Repository?, day: String = Repository.localDayKey(Date()), manualReads: Bool = false) {
        self.repository = repository
        self.catalog = nil
        self.day = day
        self.manualReads = manualReads
        self.access = .init(coachEnabled: false, usesPersonalData: false, isPreview: true,
                            hasRepository: repository != nil, sourceFenced: repository?.verifiedExternalSurfaceFenced ?? false)
        if let repository {
            // @Published announces in willSet. Inspect the completed state on the main queue, then
            // compare only source/record/journal tokens; sensor-only changes never start a read.
            repository.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }.store(in: &observers)
            NotificationCenter.default.publisher(for: .init("noop.notificationJournalDidChange"))
                .receive(on: DispatchQueue.main).sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.reloadCatalog() }
                }.store(in: &observers)
        }
    }

    isolated deinit { readTask?.cancel() }

    private var readAuthorized: Bool { manualReads ? access.canUseManualJournal : access.canReadAutomatically }
    var canRead: Bool { active && readAuthorized && repository?.verifiedExternalSurfaceFenced == false }

    var quickItems: [CoachJournalQuickItem] {
        guard let snapshot, let catalog, canRead else { return [] }
        return catalog.resolvedItems(imported: snapshot.importedQuestions)
            .filter { !$0.kind.isNumeric }
            .sorted { ($0.sortIndex, $0.display) < ($1.sortIndex, $1.display) }
            .prefix(4).map { .init(id: $0.canonical, title: $0.display) }
    }

    /// Preserve exact catalog keys and values. Display copy is evidence for the review, never parser input.
    var quickSuggestions: [JournalEntryParser.Suggestion] {
        let changes = CoachJournalDraftPolicy.changes(saved: snapshot?.answers ?? [:], draft: draftAnswers)
        return quickItems.compactMap { item in
            guard let value = changes[item.id] else { return nil }
            return .init(canonical: item.id, value: .boolean(value),
                         excerpt: item.title + ": " + (value ? "Yes" : "No"))
        }
    }

    func configure(coachEnabled: Bool, usesPersonalData: Bool, isPreview: Bool, active: Bool = true) {
        let resuming = active && !self.active
        self.coachEnabled = coachEnabled
        self.usesPersonalData = usesPersonalData
        self.isPreview = isPreview
        self.active = active
        if !active {
            readTask?.cancel()
            readTask = nil
            gate.cancel()
            isLoading = false
        }
        reconcile(forceReload: resuming)
    }

    func select(day: String) {
        guard CoachJournalDaySelection.date(for: day) != nil, day != self.day else { return }
        self.day = day
        reconcile()
    }

    func refresh() { reconcile(forceReload: true) }

    /// Only a deliberate Journal action may bypass Coach's record-consent gate. In particular,
    /// constructing a preview never opens (or migrates) the UserDefaults-backed catalog.
    func manualCatalog() -> JournalCatalogStore? {
        guard access.canUseManualJournal, repository?.verifiedExternalSurfaceFenced == false else { return nil }
        if catalog == nil { catalog = JournalCatalogStore() }
        return catalog
    }

    func didSave() {
        draftAnswers = [:]
        status = "Journal saved for \(day)."
        reconcile(forceReload: true)
    }

    func pause() {
        active = false
        readTask?.cancel()
        readTask = nil
        gate.cancel()
        isLoading = false
        reconcile()
    }

    func reloadCatalog() {
        guard catalog?.reloadFromDefaults() == true else { return }
        // An old quick choice must not be applied to an item that was hidden or changed to numeric.
        draftAnswers = [:]
        objectWillChange.send()
    }

    private func reconcile(forceReload: Bool = false) {
        let nextAccess = CoachJournalAccessPolicy(coachEnabled: coachEnabled, usesPersonalData: usesPersonalData,
                                                 isPreview: isPreview, hasRepository: repository != nil,
                                                 sourceFenced: repository?.verifiedExternalSurfaceFenced ?? false)
        if access != nextAccess { access = nextAccess }
        let context = repository?.journalEntrySourceContext ?? "unavailable"
        // Visibility stops work, but only a date/source/permission change erases a person's draft.
        let contextChanged = gate.configure(day: day, sourceContext: context, canRead: readAuthorized)
        if contextChanged {
            readTask?.cancel()
            readTask = nil
            snapshot = nil
            draftAnswers = [:]
            status = nil
            isLoading = false
        }
        guard let repository, canRead else { return }
        if catalog == nil { catalog = JournalCatalogStore() }
        let revision = context + "|\(repository.journalRevision)|" + LocalCoachEngine.recordsToken(of: repository)
        guard contextChanged || forceReload || observedRevision != revision else { return }
        observedRevision = revision
        readTask?.cancel()
        guard let request = gate.begin() else { return }
        isLoading = true
        readTask = Task { [weak self, weak repository] in
            guard let repository else { return }
            do {
                let loaded = try await repository.coachJournalSnapshot(day: request.day)
                guard let self, !Task.isCancelled else { return }
                // The first database open can establish its identity during the read. Reconcile it
                // exactly as any other replacement, then make a fresh request in the new context.
                guard repository.journalEntrySourceContext == request.sourceContext else {
                    self.reconcile()
                    return
                }
                guard self.canRead, self.gate.accepts(request, day: loaded.day, sourceContext: loaded.sourceContext) else { return }
                self.snapshot = loaded
                self.isLoading = false
                self.status = loaded.catalogWasTruncated
                    ? "Some imported journal labels were omitted from this bounded check-in. Your saved answers are unchanged."
                    : nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                guard repository.journalEntrySourceContext == request.sourceContext else {
                    self.reconcile()
                    return
                }
                guard self.canRead, self.gate.accepts(request, day: request.day, sourceContext: request.sourceContext) else { return }
                self.snapshot = nil
                self.isLoading = false
                self.status = (error as? LocalizedError)?.errorDescription ?? "Your journal could not be loaded. Try again."
            }
        }
    }
}
#endif
