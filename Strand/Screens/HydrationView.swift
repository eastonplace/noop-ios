import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Hydration detail (MVP, opt-in, local-only)
//
// A flat drill-in in the widget language: today's litres against the goal as a hero value over a flat bar, the quick
// log pills (Sip / Cup / Bottle / a custom size), today's logged drinks (tap to edit, trash to delete) and the last
// seven days as bars. The hydration tint is the Today card's teal everywhere.
// BYTE-PARITY twin of the Android `HydrationScreen`: the day total + history come from the local-only
// `HydrationStore` series (additive day total), and the goal is the pure `HydrationGoal` engine (profile
// sex + today's Strain bump). The per-drink rows are the editable detail behind the day total; the day total stays the
// source of truth the rest of the app reads. Volumes are shown in ml and litres: there is no volume unit setting.
struct HydrationView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    /// Today's running total (ml) + the 7-day history (oldest→newest), loaded off the gesture path and
    /// refreshed after each log. A reload key the taps bump so the `.task` re-reads the store.
    @State private var totalML: Double = 0
    @State private var history: [(day: String, value: Double)] = []
    @State private var reloadTick = 0
    /// #798 - today's individual logged drinks (for tap-to-edit and delete), and the entry being
    /// edited in the amount sheet (nil when the sheet is closed).
    @State private var entries: [HydrationEntry] = []
    @State private var editingEntry: HydrationEntry?
    /// #798 - the user's custom container size (ml), editable from the custom-size sheet. Persisted local-only.
    @AppStorage(HydrationStore.customSizeKey) private var customSizeML = HydrationGoal.cupML
    @State private var showCustomSizeSheet = false

    @Environment(\.dynamicTypeSize) private var typeSize

    private var goalML: Int { repo.hydrationGoalML(profileSex: profile.sex) }
    private var fraction: Double { HydrationGoal.fraction(totalML: totalML, goalML: goalML) }
    private var percent: Int { min(100, Int((fraction * 100).rounded(.towardZero))) }
    private var tint: Color { HealthTint.hydration.accent }

    var body: some View {
        ScreenScaffold(
            title: "Hydration",
            onRefresh: { await reload() },
            headerContext: DrillInFormat.headerDate(Date())
        ) {
            VStack(alignment: .leading, spacing: 0) {
                hero
                DrillInSeparator()
                logSection
                DrillInSeparator()
                todaySection
                DrillInSeparator()
                historySection
                DrillInSeparator()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your fluid intake today, on \(Platform.deviceNounPhrase) only.")
                    Text("A simple goal that adjusts to your effort. General wellness guidance, not medical advice.")
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: reloadTick) { await reload() }
        #if DEBUG
        .onAppear { debugScene() }
        #endif
        // #798 - edit a logged drink's amount.
        .sheet(item: $editingEntry) { entry in
            HydrationAmountSheet(title: "Edit drink", initialML: entry.amountMl) { newML in
                editingEntry = nil
                Task { await updateEntry(entry, to: newML) }
            } onCancel: { editingEntry = nil }
        }
        // #798 - set the custom container size.
        .sheet(isPresented: $showCustomSizeSheet) {
            HydrationAmountSheet(title: "Custom size", initialML: customSizeML) { newML in
                customSizeML = newML
                showCustomSizeSheet = false
            } onCancel: { showCustomSizeSheet = false }
        }
    }

    // MARK: - Hero (today's litres against the goal)

    private var hero: some View {
        let total = DrillInFormat.number(HydrationGoal.litres(fromML: totalML), fractionDigits: 1)
        let goal = DrillInFormat.number(HydrationGoal.litres(fromML: Double(goalML)), fractionDigits: 1)
        return VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            SectionEyebrow("Hydration", systemImage: "drop.fill", tint: HealthTint.hydration)
            HeroValue(value: total, unit: String(localized: "L"),
                      caption: String(localized: "of \(goal) L"), captionPlacement: .below)
            HealthStrengthBar(strength: totalML > 0 ? fraction * 100 : nil, tint: tint)
            Text("\(percent)% of today's goal")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hydration today")
        .accessibilityValue("\(total) of \(goal) litres")
    }

    // MARK: - Quick log (Sip / Cup / Bottle / a custom size)

    private var logSection: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            SectionEyebrow("Log a drink", systemImage: "plus.circle", tint: HealthTint.hydration)
            ChipRow {
                logButton(String(localized: "Sip"), systemImage: "drop", ml: HydrationGoal.sipML)
                logButton(String(localized: "Cup"), systemImage: "cup.and.saucer.fill", ml: HydrationGoal.cupML)
                logButton(String(localized: "Bottle"), systemImage: "drop.fill", ml: HydrationGoal.bottleML)
            }
            // #798 - a custom container the user sizes themselves. Tapping logs it; the pencil opens the
            // size editor so a one-off mug / flask / glass can be set once and reused.
            ChipRow {
                Button {
                    Task { await add(ml: customSizeML) }
                } label: {
                    Label {
                        Text(verbatim: String(localized: "Custom \(customSizeML) ml"))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "drop.circle")
                    }
                }
                .buttonStyle(SecondaryPillButtonStyle())
                .accessibilityLabel("Log custom \(customSizeML) millilitres")
                WidgetChipButton(systemImage: "pencil", accessibilityLabel: "Set custom container size") {
                    showCustomSizeSheet = true
                }
            }
            Text("Sip \(HydrationGoal.sipML) ml · Cup \(HydrationGoal.cupML) ml · Bottle \(HydrationGoal.bottleML) ml")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One quick-add pill. Logs the amount and refreshes.
    private func logButton(_ title: String, systemImage: String, ml: Int) -> some View {
        Button {
            Task { await add(ml: ml) }
        } label: {
            Label {
                Text(verbatim: title)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: systemImage)
            }
        }
        .buttonStyle(SecondaryPillButtonStyle())
        .accessibilityLabel(Text(verbatim: String(localized: "Log \(title)")))
    }

    // MARK: - Today's logged drinks (#798) - tap to edit, trash to delete

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow("Today's drinks", systemImage: "list.bullet", tint: HealthTint.hydration)
            if totalML <= 0 && entries.isEmpty {
                HealthEmptyNote(symbol: "drop", text: "No drinks logged yet. Tap Sip, Cup or Bottle to start.")
            } else {
                HealthValueRow(systemImage: "drop.fill", label: String(localized: "Logged today"),
                               value: Int(totalML).formatted(), unit: String(localized: "ml"), tint: HealthTint.hydration)
                if !entries.isEmpty {
                    // #842 — plain rows inside the page ScrollView (a nested scroll-disabled List with a hardcoded
                    // height clipped every row past the third). Tap a row to edit; the trailing trash deletes (a plain
                    // row can't host native swipe-to-delete).
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { FlatRowSeparator() }
                            entryRow(entry)
                        }
                    }
                    Text("Tap a drink to edit it, or use the trash to delete.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// One logged-drink row: the time it was logged + its amount (tap to edit) with a trailing trash.
    private func entryRow(_ entry: HydrationEntry) -> some View {
        let time = entry.loggedAt.formatted(date: .omitted, time: .shortened)
        return HStack(spacing: NoopMetrics.space2) {
            Button { editingEntry = entry } label: {
                Group {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 2) {
                            timeLabel(time)
                            amountLabel(entry.amountMl)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                            timeLabel(time)
                            Spacer(minLength: NoopMetrics.space2)
                            amountLabel(entry.amountMl)
                        }
                    }
                }
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(FlatRowPressStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Logged \(entry.amountMl) millilitres at \(time)")
            .accessibilityHint("Tap to edit the amount")
            Button(role: .destructive) {
                Task { await deleteEntry(entry) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete the \(entry.amountMl) millilitre drink logged at \(time)")
        }
    }

    private func timeLabel(_ time: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            HealthGlyph(systemImage: "drop.fill", color: tint)
            Text(verbatim: time)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    @ViewBuilder private func amountLabel(_ ml: Int) -> some View {
        let amount = HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(verbatim: ml.formatted())
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("ml").font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        }
        if typeSize.isAccessibilitySize { amount.healthIconIndent() } else { amount }
    }

    // MARK: - 7-day history (bars, today on the right)

    private var historySection: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            SectionEyebrow("Last 7 days", systemImage: "calendar", tint: HealthTint.hydration)
            historyBars
        }
    }

    @ViewBuilder private var historyBars: some View {
        if history.isEmpty {
            Text("No history yet.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        } else {
            // Scale the bars to the LARGER of the goal and the biggest day, so an over-goal day doesn't clip.
            let ceiling = max(Double(max(goalML, 1)), history.map(\.value).max() ?? 0, 1)
            let lastIndex = history.count - 1
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(history.enumerated()), id: \.element.day) { index, bar in
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(StrandPalette.surfaceInset)
                                .frame(height: 96)
                            let frac = min(1.0, max(0.0, bar.value / ceiling))
                            if frac > 0 {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(index == lastIndex ? tint : tint.opacity(0.45))
                                    .frame(height: max(3, 96 * CGFloat(frac)))
                            }
                        }
                        Text(verbatim: weekdayInitial(bar.day))
                            .font(StrandFont.micro)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(weekdayInitial(bar.day)): \(DrillInFormat.number(HydrationGoal.litres(fromML: bar.value), fractionDigits: 1)) litres")
                }
            }
        }
    }

    // MARK: - Data

    /// The one-letter weekday for a yyyy-MM-dd key in the person's language, or "·" when unparseable.
    private func weekdayInitial(_ dayKey: String) -> String {
        guard let date = BodyVitalSigns.localDate(fromDayKey: dayKey) else { return "·" }
        return date.formatted(.dateTime.weekday(.narrow))
    }

    /// Log `ml` (additive day total + a per-entry row, #798) and refresh.
    private func add(ml: Int) async {
        guard ml > 0 else { return }
        _ = await repo.logHydration(amountMl: ml)
        reloadTick &+= 1
    }

    /// #798 - delete a logged drink, re-deriving the day total, then refresh.
    private func deleteEntry(_ entry: HydrationEntry) async {
        _ = await repo.deleteHydrationEntry(id: entry.id)
        reloadTick &+= 1
    }

    /// #798 - set a logged drink's amount, re-deriving the day total, then refresh.
    private func updateEntry(_ entry: HydrationEntry, to ml: Int) async {
        _ = await repo.updateHydrationEntry(id: entry.id, amountMl: ml)
        reloadTick &+= 1
    }

    /// Load today's total + the 7-day history + today's per-entry list from the store.
    private func reload() async {
        totalML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
        history = await repo.hydrationHistory(days: 7)
        entries = repo.hydrationEntries()
    }

    #if DEBUG
    /// QA hook: `--noop-hydration-scene=edit` opens the first logged drink's amount sheet, `=custom` the custom-size
    /// sheet, straight from launch, so the sheets can be captured without a tap.
    private func debugScene() {
        guard let scene = CommandLine.arguments.first(where: { $0.hasPrefix("--noop-hydration-scene=") })?
            .dropFirst("--noop-hydration-scene=".count) else { return }
        switch scene {
        case "custom": showCustomSizeSheet = true
        case "edit":
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                editingEntry = repo.hydrationEntries().first
            }
        default: break
        }
    }
    #endif
}

// MARK: - Amount sheet (#798) - edit a drink / set the custom size

/// A small stepper sheet for an ml amount. Reused by the edit-entry and custom-size flows. Clamps to a sane range
/// so the value stays a real container size.
private struct HydrationAmountSheet: View {
    let title: LocalizedStringKey
    let initialML: Int
    let onSave: (Int) -> Void
    let onCancel: () -> Void

    @State private var ml: Int
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Bounds for a plausible single container (10 ml up to 3 L), stepping in 10 ml increments.
    private static let minML = 10
    private static let maxML = 3000
    private static let stepML = 10

    init(title: LocalizedStringKey, initialML: Int, onSave: @escaping (Int) -> Void,
         onCancel: @escaping () -> Void) {
        self.title = title
        self.initialML = initialML
        self.onSave = onSave
        self.onCancel = onCancel
        _ml = State(initialValue: Self.clamp(initialML))
    }

    static func clamp(_ value: Int) -> Int { min(maxML, max(minML, value)) }

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            NoopSheetTitleRow(title) {
                HeaderChipButton("xmark", accessibilityLabel: "Close") { onCancel() }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Amount")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                HeroValue(value: "\(ml)", unit: String(localized: "ml"))
            }
            .accessibilityElement(children: .combine)
            Stepper(value: $ml, in: Self.minML...Self.maxML, step: Self.stepML) {
                Text("Adjust amount")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .accessibilityLabel("Amount in millilitres")
            .accessibilityValue("\(ml) millilitres")
            Spacer(minLength: 0)
            ChipRow {
                Button { onCancel() } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryPillButtonStyle())
                Button { onSave(Self.clamp(ml)) } label: {
                    Text("Save").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryPillButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, NoopMetrics.space3)
        .padding(.bottom, NoopMetrics.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.appCanvas.ignoresSafeArea())
        // iOS-only sheet sizing - macOS sheets are free-floating windows and reject detents (see the
        // shared `noopSheetPresentation` note); the call site stays cross-platform via this guard. At an
        // accessibility size the sheet opens full height instead of clipping its content.
        #if os(iOS)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(320)])
        .presentationDragIndicator(.visible)
        #endif
    }
}
