import Combine
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// NOOP — Health Monitor.
///
/// A flat drill-in in the widget language: the overnight vital signs first (each row opens its own trend), the live
/// heart rate with the wearer's personal zones, the recovery contributors, the weekly Fitness Age and Vitality, the
/// skin-temperature suite, the records links and the strap's sync status. Sections are an eyebrow over free content with
/// one hairline between neighbours; there is no card around anything.
///
/// The sections live in their own files: `HealthVitals` (vital signs, contributors, the metric trend page),
/// `HealthLive` (the live trace), `HealthAge` (Fitness Age, Vitality) and `SkinTempCardsView` (the skin suite).
struct HealthView: View {
    @EnvironmentObject var repo: Repository
    // NOTE: HealthView itself deliberately does NOT observe `LiveState`/`AppModel` for live HR. A connected strap
    // publishes at ~1 Hz; observing here would re-evaluate this body (and re-diff the heavy vitals/skin-temp/age
    // sections) on every tick. The ONLY live-dependent decision the parent used to make — "empty state vs the live
    // stack while there's no history yet" — lives in the `HealthFirstRunContent` leaf, which owns `live`/`model`
    // itself. The common path (history present) branches purely on `repo.days`, so a live tick re-renders only the
    // `HeartRateSection` leaf.

    // Temperature display preference (D#103). Skin temp is stored in °C (absolute or a ±deviation); the toggle
    // re-labels it to °F. Display-only — banding still runs on the stored °C value.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""

    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric, override: temperatureRaw)
    }

    var body: some View {
        let readings = BodyVitalSigns.readings(sourceRows: repo.vitalMetricRows, temperatureUnit: temperatureUnit)
        ScreenScaffold(
            title: "Health Monitor",
            onRefresh: { _ = await repo.refresh(.currentDay) },
            headerContext: HealthFormat.headerContext(dayKey: BodyVitalSigns.latestDayKey(readings))
        ) {
            if repo.days.isEmpty {
                // First run / no history: whether to show the empty state or the full live stack depends on whether
                // a strap is streaming live HR — a `live`-dependent choice. It's isolated to this leaf (which owns
                // `live`/`model`) so a ~1 Hz HR tick re-renders only this branch, never the parent, and only while
                // there's no history (a transient first-run state).
                HealthFirstRunContent(readings: readings)
            } else {
                // History present: `live` is irrelevant to the layout choice, so the parent renders the full section
                // stack directly without observing the HR stream.
                HealthSectionsStack(readings: readings)
            }
        }
    }
}

// MARK: - Content stacks

/// The full Health section stack (vitals, live HR, contributors, age, skin temperature, records, sync). Each section is
/// its own leaf owning exactly what it needs, so only the `HeartRateSection` re-renders on a ~1 Hz HR tick — the static
/// sections depend on `repo`/`profile`/`model` snapshots only. Shared by the history-present path and the first-run live
/// path so the stack is defined once.
private struct HealthSectionsStack: View {
    let readings: [BodyVitalReading]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The overnight vital signs: each row is a tap target that opens that vital's trend page.
            HealthVitalsSection(readings: readings)
            DrillInSeparator()
            // The live HR section is its own view: it owns `live`/`profile`, so the ~1Hz HR stream re-renders only
            // this subtree — the static sections around it do not re-render on each HR tick.
            HeartRateSection()
            DrillInSeparator()
            // The CONTRIBUTORS to today's recovery (HRV / Resting HR / Sleep / Respiratory), each scored against the
            // on-device baseline. Depends only on `repo`.
            RecoveryContributorsSection()
            DrillInSeparator()
            // Fitness Age (weekly, computed by IntelligenceEngine and read back from the "fitness_age" metricSeries).
            // Its own view depending only on `repo`/`profile`, so the live HR stream never re-renders it.
            FitnessAgeSection()
            DrillInSeparator()
            // Vitality / Body Age (weekly, computed by IntelligenceEngine from the mortality-hazard model). Its own
            // view depending only on repo/profile.
            VitalitySection()
            DrillInSeparator()
            // v5 skin-temperature suite: the illness "heads-up", body clock, and (opt-in) cycle awareness, each driven
            // by a pure StrandAnalytics engine result the analytics pass computed and AppModel publishes. Its own
            // view depending on `model` + `repo`.
            SkinTempSection()
            DrillInSeparator()
            // v5 deep-links: the records logbook + the multi-device fused record, reachable from their honest Health
            // home as drill-in rows (not their own destinations).
            HealthHubLinksSection()
            DrillInSeparator()
            // Manual "Sync now" + honest sync status (#364). Its own view so the ~1Hz HR stream doesn't re-render
            // the rest; depends on `live` (connection/backfill state) + `model`.
            SyncStatusSection()
        }
    }
}

/// First-run content (no history yet). Owns `live`/`model` so the live-HR-gated choice between the empty state and the
/// full live stack ticks here, in isolation, instead of re-rendering HealthView.
private struct HealthFirstRunContent: View {
    let readings: [BodyVitalReading]

    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var model: AppModel

    /// HR to display: the spike-filtered median (model.bpm, #39) when available, else the reported value, else
    /// R-R-derived (the strap streams R-R even when its HR field reads 0).
    private var displayHR: Int? {
        if let hr = model.bpm, hr > 0 { return hr }
        if let hr = live.heartRate, hr > 0 { return hr }
        if let last = live.rr.last, last > 0 { return Int((60_000.0 / Double(last)).rounded()) }
        return nil
    }
    private var hasLiveHR: Bool { displayHR != nil }

    var body: some View {
        if !hasLiveHR {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
                    SectionEyebrow("Vital Signs", systemImage: "waveform.path.ecg", tint: .neutral)
                    HealthEmptyNote(
                        symbol: "waveform.path.ecg",
                        text: "No biometrics yet. Import your WHOOP export (and Apple Health if you have it) in Data Sources to fill this in.")
                }
                DrillInSeparator()
                // Even with no history yet, a freshly-connected strap can be told to sync now (#364) — so the control
                // is reachable before the screen has any data to show.
                SyncStatusSection()
            }
        } else {
            HealthSectionsStack(readings: readings)
        }
    }
}

// MARK: - Sync status + "Sync now" (#364)

/// Manual "Sync now" control + honest sync status, mirroring the Android Sync-now button. Its own view depending only on
/// `live` (connection + backfill state) and `model` (the BLE pass-through). Honesty rules (CLAUDE.md): the button is
/// disabled and the copy explains itself when no strap is connected; while a sync runs it shows the in-progress pill +
/// the live chunk count (never a fabricated percent — total pending is unknowable from the protocol); otherwise it shows
/// when history last synced.
/// How the Health Monitor's Sync status line is coloured. Pure, so the rule is pinned by tests.
enum SyncStatusTone: Equatable {
    /// A sync that just worked.
    case good
    /// Not connected, waiting or saved history that is still recent: no verdict, quiet ink.
    case quiet
    /// A failed sync, or saved history that has gone stale.
    case attention

    /// Saved history older than this reads as needing attention.
    static let staleAfter: TimeInterval = 2 * 86_400

    /// Failure, then staleness, then success: a sync that completed but left the newest saved history more than two
    /// days old is not a good one, so staleness is checked before success.
    static func of(_ status: HistoricalSyncStatus, newestHistoryAt: TimeInterval?, now: TimeInterval) -> SyncStatusTone {
        if status.isFailure { return .attention }
        if let newestHistoryAt, now - newestHistoryAt > staleAfter { return .attention }
        if status.isCurrentSuccess { return .good }
        return .quiet
    }

    /// The "Showing saved history through ..." detail line says what the status above it does not. A clean, current
    /// sync already says it all, but a completed sync over stale history needs it to say how old the data is.
    static func showsSavedHistoryLine(_ status: HistoricalSyncStatus, tone: SyncStatusTone) -> Bool {
        !status.isCurrentSuccess || tone == .attention
    }
}

private struct SyncStatusSection: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The strap link is usable for a manual offload kick (matches BLEManager.syncNow's own gate).
    private var canSync: Bool {
        live.connected && live.encryptedBond
            && live.historicalSyncSessionState != .waitingForSecureHandshake
            && !live.backfilling
    }

    private var syncStatus: HistoricalSyncStatus {
        HistoricalSyncStatusResolver.resolve(
            connected: live.connected,
            liveHeartRateAvailable: live.streamingLiveHR,
            sessionState: live.historicalSyncSessionState,
            lastSuccessfulBackfillAt: live.lastSyncedAt,
            historicalDataFrontierAt: live.historicalDataFrontierAt,
            lastSyncError: live.lastSyncError,
            historySyncExperimental: live.historySyncExperimental,
            chunks: live.syncChunksThisSession,
            now: Date().timeIntervalSince1970)
    }

    private var connectionWord: String {
        live.connected
            ? (live.bonded ? String(localized: "Connected") : String(localized: "Pairing…"))
            : String(localized: "Offline")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            SectionEyebrow("Sync", systemImage: "arrow.triangle.2.circlepath", tint: .neutral,
                           trailing: .text(connectionWord))
            statusRow
            // The manual offload kick reaches the BLE engine's gated entry point directly (same idiom as
            // SettingsView's `model.ble.enableWhoop5DeepData()`); BLEManager.syncNow() is the honest gate — a no-op
            // when no strap is connected or a sync is already running.
            HStack(spacing: 0) {
                Button {
                    model.ble.syncNow()
                } label: {
                    Label {
                        Text(verbatim: live.backfilling ? String(localized: "Syncing…") : String(localized: "Sync now"))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(SecondaryPillButtonStyle())
                .disabled(!canSync)
                .accessibilityLabel("Sync now")
                .accessibilityHint(canSync
                    ? "Pulls your strap's stored history immediately, without waiting for the next automatic sync."
                    : (live.backfilling ? "A sync is already in progress." : "Connect your strap first."))
                Spacer(minLength: 0)
            }
            Text(verbatim: helperText)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The status line above the button: an in-progress pill while syncing (with the live chunk count), else a
    /// last-synced read-out, else an honest "not connected".
    @ViewBuilder private var statusRow: some View {
        if live.historicalSyncSessionState == .syncing {
            // Reuse the shared in-progress affordance so this matches every other "syncing history" surface.
            SyncingHistoryNote(chunks: live.syncChunksThisSession)
        } else {
            let status = syncStatus
            VStack(alignment: .leading, spacing: 6) {
                statusLabel(Self.localized(status.primary), color: statusColor(status))
                // The resolver's primary line IS the saved-history sentence when there is nothing else to say
                // (`primary: saved ?? ...`), so the detail line only shows when it adds something.
                if SyncStatusTone.showsSavedHistoryLine(status, tone: tone(status)),
                   let saved = status.savedHistory, saved != status.primary {
                    Text(verbatim: saved)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A short status ("Not connected") is a pill; a long one ("Showing saved history through Jul 29, 2025 at 5:22 PM",
    /// "History sync waiting for secure link") is a caption in the same colour, which wraps like text instead of
    /// swelling into a multi-line blob. At accessibility sizes every status is a caption.
    @ViewBuilder private func statusLabel(_ text: String, color: Color) -> some View {
        if Self.showsAsPill(text, accessibilitySize: typeSize.isAccessibilitySize) {
            ValuePill(text, tint: color)
        } else {
            Text(verbatim: text)
                .font(StrandFont.subhead)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func showsAsPill(_ text: String, accessibilitySize: Bool) -> Bool {
        !accessibilitySize && text.count <= 24
    }

    /// Mint says good or live, so it is only for a sync that just worked. A strap that is offline or still waiting
    /// reads in quiet ink, and amber when the newest saved history is more than two days old or a sync failed.
    private func tone(_ status: HistoricalSyncStatus) -> SyncStatusTone {
        SyncStatusTone.of(
            status, newestHistoryAt: live.historicalDataFrontierAt ?? live.lastSyncedAt,
            now: Date().timeIntervalSince1970)
    }

    private func statusColor(_ status: HistoricalSyncStatus) -> Color {
        switch tone(status) {
        case .good: StrandTone.positive.color
        case .quiet: StrandPalette.textSecondary
        case .attention: StrandTone.warning.color
        }
    }

    /// The resolver's fixed English sentences, said in the person's language. The ones that carry a time or a count
    /// (and a strap's own error text) pass through as the resolver wrote them.
    static func localized(_ primary: String) -> String {
        switch primary {
        case "Not connected": String(localized: "Not connected")
        case "History sync experimental": String(localized: "History sync experimental")
        case "History sync waiting for secure link": String(localized: "History sync waiting for secure link")
        case "Live HR only · History sync waiting for secure link":
            String(localized: "Live HR only · History sync waiting for secure link")
        case "Secure link ready · Waiting for history sync": String(localized: "Secure link ready · Waiting for history sync")
        case "History sync completed with issues": String(localized: "History sync completed with issues")
        case "History sync failed": String(localized: "History sync failed")
        default: primary
        }
    }

    private var helperText: String {
        if live.backfilling {
            return String(localized: "Pulling your strap's stored history. This drains oldest-first; a deep backlog now continues automatically across passes instead of waiting between syncs.")
        }
        if !live.connected {
            return String(localized: "Connect your strap to sync its stored history. Until then, only imported data shows here.")
        }
        if live.historicalSyncSessionState == .waitingForSecureHandshake {
            return String(localized: "History sync is waiting for the secure link. Live heart rate can continue while pairing finishes.")
        }
        if live.historicalSyncSessionState == .failed {
            return String(localized: "Reconnect the strap to retry the secure handshake and history sync.")
        }
        return String(localized: "Syncs your strap's stored history right away, instead of waiting for the next automatic sync.")
    }
}

// MARK: - Skin-temperature suite (v5: illness heads-up · body clock · cycle awareness)

/// The v5 skin-temperature section: the confounder-suppressed illness "heads-up", the body-clock estimate, and the
/// OPT-IN cycle awareness block — each rendered from a pure StrandAnalytics engine result the analytics pass computed and
/// `AppModel` publishes. Honest throughout: the heads-up only shows when the engine returns a non-quiet level; cycle
/// awareness shows the opt-in block until the user turns it on (default OFF); the body clock shows nil-state copy until
/// it can read a rhythm.
private struct SkinTempSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var repo: Repository

    /// The cycle-awareness opt-in (default OFF). The same key AppModel reads, so a flip is consistent.
    @AppStorage(AppModel.cycleAwarenessKey) private var cycleEnabled = false

    /// Whether the cycle-awareness opt-in is offered for this profile (#801). Delegates to the shared
    /// ``ProfileStore/cycleAwarenessApplies`` gate so Health + Automations stay in lockstep: cycle phase is read from the
    /// menstrual skin-temperature shift, so the opt-in is NOT shown for male profiles.
    private var cycleOptInApplies: Bool { model.profile.cycleAwarenessApplies }

    private enum Block: Hashable {
        case headsUp, bodyClock, cycle, optIn, empty
    }

    /// The blocks to show, in order.
    private var blocks: [Block] {
        var blocks: [Block] = []
        // 1. Illness heads-up — only when the engine returned something worth surfacing.
        if let illness = model.illnessSignal, illness.level != .quiet { blocks.append(.headsUp) }
        // 2. Body clock — shows nil-state copy via the engine's own confidence handling.
        if model.circadianPhase != nil { blocks.append(.bodyClock) }
        // 3. Cycle awareness: opt-in, and gated on profile sex (#801). Cycle phase is derived from the menstrual
        // temperature shift, so the opt-in is only offered to profiles it can apply to (female / nonbinary); it is NOT
        // rendered for male profiles. If a profile that previously enabled it later switches to male, we still honour
        // the existing awareness block rather than silently hiding their data; only the OPT-IN invitation is gated.
        if cycleEnabled, model.cyclePhase != nil {
            blocks.append(.cycle)
        } else if !cycleEnabled && cycleOptInApplies {
            blocks.append(.optIn)
        }
        // Honest empty state when the suite has nothing to show yet. The opt-in block normally fills the section when
        // cycle is OFF, but it is gated off for male profiles (#801), so the section can also be blank when the opt-in
        // doesn't apply AND nothing else has data. Show the empty state in either case (cycle ON but thin, OR opt-in
        // hidden with no other signal).
        if (cycleEnabled || !cycleOptInApplies)
            && model.illnessSignal == nil && model.circadianPhase == nil && model.cyclePhase == nil {
            blocks.append(.empty)
        }
        return blocks
    }

    var body: some View {
        // The skin-temperature blocks sit under the nightly-sensor eyebrow; the body clock, which is read from light
        // and sleep timing, is its own section after them so no heading promises what its content is not.
        let blocks = self.blocks
        let skinBlocks = blocks.filter { $0 != .bodyClock }
        VStack(alignment: .leading, spacing: 0) {
            if !skinBlocks.isEmpty {
                VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
                    SectionEyebrow(
                        "Skin temperature", systemImage: ProductionTrendMetric.skinTemp.symbol,
                        tint: ProductionTrendMetric.skinTemp.domainTint(latest: nil),
                        trailing: .text(String(localized: "From your nightly sensor")))
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(skinBlocks.enumerated()), id: \.element) { index, block in
                            if index > 0 { FlatRowSeparator().padding(.vertical, NoopMetrics.space3) }
                            content(block)
                        }
                    }
                }
            }
            if blocks.contains(.bodyClock), let phase = model.circadianPhase {
                if !skinBlocks.isEmpty { DrillInSeparator() }
                BodyClockCard(estimate: phase)
            }
        }
    }

    @ViewBuilder
    private func content(_ block: Block) -> some View {
        switch block {
        case .headsUp:
            if let illness = model.illnessSignal {
                HeadsUpCard(result: illness, distance: model.illnessDistance)
            }
        case .bodyClock:
            EmptyView()   // its own section, drawn by `body`
        case .cycle:
            if let cycle = model.cyclePhase {
                CycleAwarenessCard(result: cycle, curve: model.cycleCurve,
                                   // Symmetric off (#801): turn it off in-place, here in Health, where it was turned
                                   // on, not only from Automations.
                                   onTurnOff: {
                                       cycleEnabled = false
                                       model.cycleAwarenessEnabled = false
                                       Task { await model.refreshV5Signals() }
                                   })
            }
        case .optIn:
            CycleAwarenessOptInCard(onEnable: {
                cycleEnabled = true
                model.cycleAwarenessEnabled = true
                Task { await model.refreshV5Signals() }
            })
        case .empty:
            HealthEmptyNote(symbol: "thermometer.medium",
                            text: "Wear the strap overnight and these read from your nightly skin temperature.")
        }
    }
}

// MARK: - Health hub deep-links (Lab Book · Your Data, Fused)

/// Two drill-in rows that give the records logbook (Lab Book) and the multi-device fused record their honest Health home
/// without making either its own top-level destination — they route via `NavRouter` (the macOS sidebar selects the item;
/// iOS presents the pillar sheet).
private struct HealthHubLinksSection: View {
    @EnvironmentObject var router: NavRouter

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                "Records & sources", systemImage: "books.vertical", tint: .neutral,
                trailing: .text(String(localized: "On \(Platform.deviceNounPhrase)")))
            VStack(spacing: 0) {
                linkRow(title: String(localized: "Lab Book"),
                        subtitle: String(localized: "Keep your bloods, BP and body numbers private, on \(Platform.deviceNounPhrase)."),
                        symbol: "books.vertical.fill") { router.openLabBook() }
                FlatRowSeparator()
                linkRow(title: String(localized: "Your Data, Fused"),
                        subtitle: String(localized: "The best-sourced number per metric across every band you use."),
                        symbol: "square.stack.3d.up.fill") { router.openFusedRecord() }
            }
        }
    }

    private func linkRow(title: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HealthLinkRowLabel(title: title, subtitle: subtitle, symbol: symbol)
        }
        // The same press response as every tappable row on the flat pages.
        .buttonStyle(FlatRowPressStyle())
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Health Monitor") {
    let repo = Repository(deviceId: "preview")
    repo.days = [
        DailyMetric(
            day: "2026-06-06",
            totalSleepMin: 462, efficiency: 92,
            deepMin: 96, remMin: 108, lightMin: 240, disturbances: 7,
            restingHr: 52, avgHrv: 74, recovery: 81, strain: 11.4,
            exerciseCount: 1,
            spo2Pct: 97, skinTempDevC: 34.2, respRateBpm: 14.6
        )
    ]
    repo.loaded = true

    let live = LiveState()
    live.connected = true
    live.bonded = true
    live.heartRate = 132
    live.rr = [455, 460, 448, 470, 452, 461, 449, 458, 463, 451]

    return HealthView()
        .environmentObject(repo)
        .environmentObject(live)
        .environmentObject(ProfileStore())
        .environmentObject(AppModel())
        .environmentObject(NavRouter())
        .frame(width: 900, height: 760)
        .preferredColorScheme(.dark)
}

/// Deterministic render target for `--demo-screen fitnessage` (pair with `--demo-seed` to populate the
/// weekly value). Shows the REAL `FitnessAgeSection` on the production scaffold, so a screenshot matches
/// what ships. Reads the same injected `repo`/`profile` environment objects as the live app.
struct FitnessAgeDemoScreen: View {
    var body: some View {
        ScreenScaffold(title: "Health Monitor", subtitle: "Fitness Age", onRefresh: {}) {
            FitnessAgeSection()
        }
    }
}

/// Deterministic render target for `--demo-screen vitality` (pair with `--demo-seed`).
struct VitalityDemoScreen: View {
    var body: some View {
        ScreenScaffold(title: "Health Monitor", subtitle: "Vitality", onRefresh: {}) {
            VitalitySection()
        }
    }
}
#endif
