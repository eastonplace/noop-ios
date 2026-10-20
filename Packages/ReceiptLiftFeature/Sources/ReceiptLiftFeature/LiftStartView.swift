import StrandDesign
import SwiftUI

// MARK: - Strength home
//
// The page Lift opens on (phone 2 of the approved design): the routine that is up next with its exercises and one big
// Start, this calendar week at a glance, sets per muscle against the common 10-20 band, and the last few lifts with the
// Strain each one scored. History, Progress, Routines and the settings gear are one tap away in the header.

struct LiftStartView: View {
  @EnvironmentObject private var store: LiftStore
  @Environment(\.liftFormat) private var format
  @Environment(\.liftHostChrome) private var host
  @Environment(\.liftStrainProvider) private var strainProvider
  @Environment(\.dynamicTypeSize) private var typeSize

  let onOpenSettings: () -> Void
  let onResume: () -> Void
  let onStartOpen: () -> Void
  let onStartRoutine: (LiftRoutine) -> Void
  let onPreview: (LiftRoutine) -> Void
  let onOpen: (LiftRoute) -> Void

  @State private var week: LiftWeekSummary?
  @State private var muscles = LiftMuscleVolume(rows: [])
  @State private var lastLift: LiftSession?
  @State private var recent: [LiftSession] = []
  @State private var recentStrains: [String: Double] = [:]
  @ScaledMetric(relativeTo: .largeTitle) private var routineTitleSize: CGFloat = 34

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 0) {
        if let session = store.activeSession {
          LiftInProgressSection(session: session, onResume: onResume)
        } else {
          upNextSection
        }
        FlatSectionSeparator()
        thisWeekSection
        FlatSectionSeparator()
        musclesSection
        if !recent.isEmpty {
          FlatSectionSeparator()
          recentSection
        }
      }
      .padding(.horizontal, StrengthMetrics.gutter)
      .padding(.top, NoopMetrics.space2)
      .padding(.bottom, NoopMetrics.space6)
      .frame(maxWidth: LiftChromeMetrics.maxColumnWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .scrollIndicators(.hidden)
    .background(StrandPalette.appCanvas.ignoresSafeArea())
    .safeAreaInset(edge: .top, spacing: 0) { header }
    .toolbar(.hidden, for: .navigationBar)
    .background { EdgeSwipeBack(rootBackAction: host.onBack).frame(width: 0, height: 0) }
    .onAppear(perform: refreshSummaries)
    .onChange(of: store.sessions) { refreshSummaries() }
    .task(id: recentIDs) { await loadRecentStrains() }
  }

  // MARK: Header

  private var header: some View {
    VStack(spacing: 0) {
      // The sheet's grabber, drawn the way the approved design has it, only where Lift is the root of the host's sheet.
      if host.onClose != nil { StrengthGrabber() }
      headerRow
    }
    .padding(.horizontal, StrengthMetrics.gutter)
    .padding(.top, NoopMetrics.space3)
    .padding(.bottom, NoopMetrics.space1)
    .frame(maxWidth: LiftChromeMetrics.maxColumnWidth + StrengthMetrics.gutter * 2)
    .frame(maxWidth: .infinity)
    .background(StrandPalette.appCanvas)
  }

  private var headerRow: some View {
    StrengthHeader(title: "Strength", onBack: host.onBack) {
      HStack(spacing: 0) {
        StrengthIconButton(systemImage: "clock.arrow.circlepath", accessibilityLabel: "Lift history") { onOpen(.history) }
        Menu {
          Button { onOpen(.routines) } label: { Label("Routines and schedule", systemImage: "calendar") }
          Button { onOpen(.progress) } label: { Label("Progress", systemImage: "chart.xyaxis.line") }
            .accessibilityLabel("Lift progress")
          Button(action: onOpenSettings) { Label("Lift settings", systemImage: "gearshape") }
        } label: {
          StrengthIconGlyph(systemImage: "list.bullet")
        }
        .accessibilityLabel("Lift menu")
        if let onClose = host.onClose {
          StrengthIconButton(systemImage: "xmark", accessibilityLabel: "Close", action: onClose)
        }
      }
      .padding(.trailing, -StrengthMetrics.iconInset)
    }
  }

  // MARK: Up next

  private var nextRoutine: LiftRoutine? { store.nextSuggestedRoutine }

  @ViewBuilder private var upNextSection: some View {
    if let routine = nextRoutine {
      routineHero(routine)
    } else {
      noRoutineHero
    }
  }

  private func routineHero(_ routine: LiftRoutine) -> some View {
    let exercises = routine.exerciseIDs.compactMap { store.exercise(for: $0) }
    let thumbLimit = 5
    let extra = max(exercises.count - thumbLimit, 0)
    return VStack(alignment: .leading, spacing: 0) {
      Button { onPreview(routine) } label: {
        VStack(alignment: .leading, spacing: 0) {
          eyebrowRow(routine)
          Text(verbatim: routine.name)
            .font(StrandFont.sized(routineTitleSize, weight: .bold))
            .tracking(-0.8)
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, NoopMetrics.space2)
            .accessibilityAddTraits(.isHeader)
          Text(verbatim: routineMeta(routine, exercises: exercises))
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
          if !exercises.isEmpty {
            thumbs(exercises, limit: thumbLimit, extra: extra).padding(.top, NoopMetrics.space4)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityHint("Opens the routine before you start")

      Button { onStartRoutine(routine) } label: {
        Label { Text("Start \(routine.name)") } icon: { Image(systemName: "play.fill") }
      }
      .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
      .padding(.top, NoopMetrics.space4)
      .accessibilityHint("Starts this routine now")

      HStack(spacing: NoopMetrics.space3) {
        Button(action: onStartOpen) { Text("Empty workout").frame(maxWidth: .infinity, minHeight: 24) }
          .buttonStyle(SecondaryPillButtonStyle())
          .accessibilityHint("Starts a lift you build as you go")
        Button { onOpen(.routines) } label: { Text("Pick a routine").frame(maxWidth: .infinity, minHeight: 24) }
          .buttonStyle(SecondaryPillButtonStyle())
      }
      .padding(.top, NoopMetrics.space3)
    }
  }

  private var noRoutineHero: some View {
    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
      SectionEyebrow("Start", systemImage: "dumbbell.fill", tint: .muscular)
      if let lastLift { LiftLastLiftLine(session: lastLift) }
      LiftNote(text: "No routines yet. Create one, or open a workout and add exercises as you go.")
      Button(action: onStartOpen) { Label("Empty workout", systemImage: "play.fill") }
        .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
        .accessibilityHint("Starts a lift you build as you go")
      Button { onOpen(.newRoutine) } label: { Text("Create a routine").frame(maxWidth: .infinity, minHeight: 24) }
        .buttonStyle(SecondaryPillButtonStyle())
    }
  }

  private func eyebrowRow(_ routine: LiftRoutine) -> some View {
    let pill = lastDoneText(for: routine)
    return Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
          SectionEyebrow(title: upNextTitle(for: routine), systemImage: "calendar", tint: .muscular)
          if let pill { ValuePill(pill, tint: StrandPalette.textSecondary) }
        }
      } else {
        HStack(spacing: NoopMetrics.space2) {
          SectionEyebrow(title: upNextTitle(for: routine), systemImage: "calendar", tint: .muscular)
          if let pill { ValuePill(pill, tint: StrandPalette.textSecondary).layoutPriority(2) }
        }
      }
    }
  }

  private func thumbs(_ exercises: [LiftExercise], limit: Int, extra: Int) -> some View {
    // The tiles shrink together to fit the width (the design's flex row): at 58pt six of them are wider than the page
    // and would push the whole column past its gutters.
    StrengthTileRow(maxSide: typeSize.isAccessibilitySize ? 44 : 58, spacing: 8) {
      ForEach(Array(exercises.prefix(limit)), id: \.id) { exercise in
        StrengthExerciseTile(exercise: exercise, size: nil)
      }
      if extra > 0 {
        Text(verbatim: "+\(extra)")
          .font(StrandFont.subhead.weight(.semibold))
          .foregroundStyle(StrandPalette.textSecondary)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
          .accessibilityHidden(true)
      }
    }
  }

  private func upNextTitle(for routine: LiftRoutine) -> String {
    let scheduled = LiftStore.upcomingWorkouts(in: store.scheduledWorkouts, now: Date(), calendar: .current)
      .first { $0.routineID == routine.id }
    guard let scheduled else { return String(localized: "Up next") }
    return String(localized: "Up next · \(format.relativeDay(scheduled.plannedAt))")
  }

  private func routineMeta(_ routine: LiftRoutine, exercises: [LiftExercise]) -> String {
    let minutes = store.estimatedMinutes(for: routine)
    let plans = store.materializedPlans(for: routine)
    let muscles = LiftMuscleVolume.topMuscles(
      plans: plans.map { (exerciseID: $0.exerciseID, sets: LiftStore.setCount(from: $0.sets) ?? 3) },
      limit: 3, muscles: { id in store.exercise(for: id).map(Self.muscleTokens) ?? (nil, []) })
    return LiftFormat.facts([
      LiftFormat.exerciseCount(exercises.count),
      minutes > 0 ? String(localized: "about \(format.minutes(minutes))") : "",
      muscles.map { $0.title.lowercased() }.formatted(.list(type: .and, width: .narrow)),
    ]).replacingOccurrences(of: "\u{00A0}· ", with: " · ")
  }

  private func lastDoneText(for routine: LiftRoutine) -> String? {
    guard let days = LiftHomeLogic.daysSinceLastDone(routineID: routine.id, in: store.sessions, now: Date(), calendar: .current)
    else { return nil }
    switch days {
    case 0: return String(localized: "Last done today")
    case 1: return String(localized: "Last done yesterday")
    default: return String(localized: "Last done \(days) days ago")
    }
  }

  static func muscleTokens(_ exercise: LiftExercise) -> (primary: String?, secondary: [String]) {
    let metadata = LiftExerciseCatalog.metadata(for: exercise)
    return (metadata?.target ?? (exercise.muscleGroup.isEmpty ? nil : exercise.muscleGroup), metadata?.secondaryMuscles ?? [])
  }

  // MARK: This week

  private var thisWeekSection: some View {
    let summary = week
    let dateRange = summary.map { rangeText($0.interval) } ?? ""
    return VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
      SectionEyebrow("This week", systemImage: "chart.bar.xaxis", tint: .muscular, trailing: dateRange.isEmpty ? .none : .text(dateRange))
      if let summary {
        let volume = format.compactVolumeParts(pounds: summary.volume)
        StrengthStatStrip(items: [
          .init(
            id: "sessions", label: "Sessions", value: summary.workouts.formatted(),
            caption: summary.plannedThisWeek > 0 ? String(localized: "of \(summary.plannedThisWeek) planned") : nil),
          .init(
            id: "sets", label: "Working sets", value: summary.workingSets.formatted(),
            caption: LiftWeekDeltaText.make(summary.workingSetsDeltaVsLastWeek),
            spoken: "\(summary.workingSets), \(LiftWeekDeltaText.spoken(summary.workingSetsDeltaVsLastWeek))"),
          .init(
            id: "volume", label: "Volume", value: volume.number,
            caption: String(localized: "\(volume.unit) lifted"),
            spoken: format.spokenWeight(pounds: summary.volume)),
        ])
      }
    }
  }

  private func rangeText(_ interval: DateInterval) -> String {
    let end = interval.end.addingTimeInterval(-1)
    return interval.start.formatted(.dateTime.month(.abbreviated).day().locale(format.locale))
      + " – " + end.formatted(.dateTime.day().locale(format.locale))
  }

  // MARK: Sets per muscle

  private var musclesSection: some View {
    VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
      SectionEyebrow("Sets per muscle", systemImage: "figure.strengthtraining.traditional", tint: .muscular, trailing: .text(String(localized: "this week")))
      VStack(spacing: 0) {
        ForEach(muscles.rows) { row in LiftMuscleBarRow(row: row) }
      }
      Text("10–20 sets a week is a common growth range. It’s a guide, not a target.")
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: Recent

  private var recentSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        SectionEyebrow("Recent", systemImage: "clock.arrow.circlepath", tint: .muscular)
        Button { onOpen(.history) } label: {
          Text("See all").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("See all lifts")
      }
      ForEach(Array(recent.enumerated()), id: \.element.id) { index, session in
        if index > 0 { FlatRowSeparator() }
        LiftRecentRow(session: session, strain: recentStrains[session.id.uuidString])
      }
    }
  }

  // MARK: Data

  private var recentIDs: [String] { recent.map { $0.id.uuidString } }

  private func refreshSummaries() {
    let now = Date()
    week = LiftTodayMath.weekSummary(in: store.sessions, scheduled: store.scheduledWorkouts, asOf: now, calendar: .current)
    if let interval = week?.interval {
      muscles = LiftMuscleVolume.make(sessions: store.sessions, in: interval) { id in
        store.exercise(for: id).map(Self.muscleTokens) ?? (nil, [])
      }
    }
    lastLift = store.lastCompletedSession
    recent = LiftTodayMath.recentCompletedSessions(in: store.sessions, limit: 3)
  }

  /// Reads the stored Strain of the recent lifts, then again whenever the host says stored Strain changed: a lift's value
  /// is written after its session lands in `store.sessions`, so a single read at that moment would miss it.
  private func loadRecentStrains() async {
    let ids = recentIDs
    guard let strainProvider, !ids.isEmpty else { recentStrains = [:]; return }
    await LiftRecentStrain.observe(provider: strainProvider, sessionIDs: ids) { recentStrains = $0 }
  }
}

enum LiftRecentStrain {
  /// Hands `apply` the stored Strain of `sessionIDs` now and again after every update the provider announces, until the
  /// calling task is cancelled. The stream is opened before the first read so an update that lands during it is not lost.
  @MainActor
  static func observe(
    provider: any LiftStrainProviding, sessionIDs: [String], apply: ([String: Double]) -> Void
  ) async {
    let updates = provider.updates()
    apply(await provider.recentStrains(sessionIDs: sessionIDs))
    for await _ in updates {
      if Task.isCancelled { return }
      apply(await provider.recentStrains(sessionIDs: sessionIDs))
    }
  }
}

// MARK: - Pieces

/// One muscle's bar: its name, the filled share of a 0-24 track with the 10-20 band shaded, and the set count.
struct LiftMuscleBarRow: View {
  let row: LiftMuscleVolume.Row
  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .subheadline) private var nameWidth: CGFloat = 86

  var body: some View {
    let name = Text(verbatim: row.group.title).font(StrandFont.subhead.weight(.medium)).foregroundStyle(StrandPalette.textPrimary)
    let value = Text(verbatim: String(row.displaySets))
      .font(StrandFont.subhead.weight(.semibold)).monospacedDigit()
      .foregroundStyle(row.isInsideBand ? StrandPalette.textPrimary : StrandPalette.textSecondary)
    Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 4) {
          HStack { name; Spacer(minLength: 8); value }
          bar
        }
        .padding(.vertical, 6)
      } else {
        HStack(spacing: 10) {
          name.frame(width: nameWidth, alignment: .leading).lineLimit(1).minimumScaleFactor(0.7)
          bar
          value.frame(width: 28, alignment: .trailing)
        }
        .frame(minHeight: 30)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: spoken))
  }

  private var spoken: String {
    let sets = LiftFormat.setCount(row.displaySets)
    let band = row.isInsideBand ? String(localized: "inside the common range") : String(localized: "outside the common range")
    return "\(row.group.title), \(sets), \(band)"
  }

  private var bar: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let track = LiftMuscleVolume.trackMaximum
      let bandStart = width * CGFloat(LiftMuscleVolume.band.lowerBound / track)
      let bandWidth = width * CGFloat((LiftMuscleVolume.band.upperBound - LiftMuscleVolume.band.lowerBound) / track)
      ZStack(alignment: .leading) {
        Capsule(style: .continuous).fill(StrandPalette.surfaceInset).frame(height: 8)
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(StrandPalette.muscularAccent.opacity(0.10))
          .overlay(alignment: .leading) { Rectangle().fill(StrandPalette.muscularAccent.opacity(0.45)).frame(width: 1) }
          .overlay(alignment: .trailing) { Rectangle().fill(StrandPalette.muscularAccent.opacity(0.45)).frame(width: 1) }
          .frame(width: bandWidth, height: 16)
          .offset(x: bandStart)
        Capsule(style: .continuous)
          .fill(row.isInsideBand ? StrandPalette.muscularAccent : StrandPalette.muscularAccent.opacity(0.42))
          .frame(width: max(width * CGFloat(min(row.sets, track) / track), row.sets > 0 ? 6 : 0), height: 8)
      }
      .frame(height: proxy.size.height)
    }
    .frame(height: 16)
    .accessibilityHidden(true)
  }
}

/// One of the last lifts: its day, name, a line of facts and the Strain it scored (the stored value, "—" when missing).
struct LiftRecentRow: View {
  let session: LiftSession
  let strain: Double?
  @Environment(\.liftFormat) private var format
  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .title3) private var dayWidth: CGFloat = 44

  var body: some View {
    let seconds = (session.endedAt ?? session.startedAt).timeIntervalSince(session.startedAt)
    let volume = format.compactVolumeParts(pounds: session.totalVolume)
    let facts = LiftFormat.facts([
      format.shortDuration(seconds), LiftFormat.setCount(session.workingSets.count), "\(volume.number) \(volume.unit)",
    ])
    let strainText = strain.map { $0.formatted(.number.precision(.fractionLength(1)).locale(format.locale)) } ?? "—"
    Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 4) {
          dayStack
          Text(verbatim: session.title).font(StrandFont.body.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
          Text(verbatim: facts).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
          strainStack(strainText)
        }
      } else {
        HStack(spacing: 12) {
          dayStack.frame(width: dayWidth)
          VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: session.title).font(StrandFont.body.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
              .lineLimit(1).minimumScaleFactor(0.8)
            Text(verbatim: facts).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
              .lineLimit(1).minimumScaleFactor(0.8)
          }
          Spacer(minLength: 8)
          strainStack(strainText)
        }
      }
    }
    .padding(.vertical, 11)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      LiftFormat.spoken([
        format.weekdayDay(session.startedAt), session.title, format.spokenDuration(seconds),
        LiftFormat.setCount(session.workingSets.count), format.spokenWeight(pounds: session.totalVolume),
        strain.map { String(localized: "Strain \($0.formatted(.number.precision(.fractionLength(1)).locale(format.locale)))") }
          ?? String(localized: "Strain not scored"),
      ]))
  }

  private var dayStack: some View {
    VStack(spacing: 1) {
      Text(session.startedAt.formatted(.dateTime.weekday(.abbreviated).locale(format.locale)))
        .textCase(.uppercase)
        .font(StrandFont.micro.weight(.bold)).tracking(1)
        .foregroundStyle(StrandPalette.textTertiary)
      Text(session.startedAt.formatted(.dateTime.day().locale(format.locale)))
        .font(StrandFont.headline).monospacedDigit().foregroundStyle(StrandPalette.textPrimary)
    }
  }

  private func strainStack(_ text: String) -> some View {
    VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 0) {
      Text(verbatim: text).font(StrandFont.headline).monospacedDigit().foregroundStyle(StrandPalette.strainAccent)
      Text("Strain").font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
    }
  }
}

enum LiftHomeLogic {
  /// Whole days since the latest finished session of this routine, nil when it has never been done.
  nonisolated static func daysSinceLastDone(routineID: UUID, in sessions: [LiftSession], now: Date, calendar: Calendar) -> Int? {
    guard let latest = sessions
      .filter({ $0.endedAt != nil && $0.routineID == routineID })
      .map({ $0.endedAt ?? $0.startedAt })
      .max()
    else { return nil }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: latest), to: calendar.startOfDay(for: now)).day ?? 0
    return max(days, 0)
  }
}

// MARK: - Pieces

/// The three ways into Lift's other pages, as the Workouts hub offers them.
struct LiftChipLinks: View {
  let onOpen: (LiftRoute) -> Void

  var body: some View {
    ChipRow {
      WidgetChipButton(
        title: "History", systemImage: "list.bullet.rectangle", showsChevron: true,
        accessibilityLabel: "Lift history"
      ) { onOpen(.history) }
      WidgetChipButton(
        title: "Progress", systemImage: "chart.xyaxis.line", showsChevron: true,
        accessibilityLabel: "Lift progress"
      ) { onOpen(.progress) }
      WidgetChipButton(
        title: "Schedule", systemImage: "calendar", showsChevron: true,
        accessibilityLabel: "Routines and schedule"
      ) { onOpen(.routines) }
    }
  }
}

/// "Last lift" over its name and a line of facts, the shape the Workouts hub gives it.
struct LiftLastLiftLine: View {
  let session: LiftSession
  @Environment(\.liftFormat) private var format

  var body: some View {
    let seconds = (session.endedAt ?? session.startedAt).timeIntervalSince(session.startedAt)
    let sets = session.workingSets.count
    var facts = [format.day(session.startedAt)]
    var spoken = facts
    if sets > 0 {
      facts.append(LiftFormat.setCount(sets))
      spoken = facts
    }
    if seconds >= 60 {
      facts.append(format.shortDuration(seconds))
      spoken.append(format.spokenDuration(seconds))
    }
    return VStack(alignment: .leading, spacing: 2) {
      Text("Last lift").font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
      Text(verbatim: session.title)
        .font(StrandFont.body.weight(.semibold))
        .foregroundStyle(StrandPalette.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      Text(verbatim: LiftFormat.facts(facts))
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Last lift")
    .accessibilityValue(([session.title] + spoken).joined(separator: ", "))
  }
}

/// The lift in flight: how long it has run, how far through its sets, and the one button that returns to it.
struct LiftInProgressSection: View {
  let session: LiftSession
  let onResume: () -> Void
  @EnvironmentObject private var store: LiftStore
  @Environment(\.liftFormat) private var format
  @ScaledMetric(relativeTo: .title) private var heroSize: CGFloat = WidgetMetrics.heroValueSize

  var body: some View {
    LiftFlatSection("In progress", trailing: .pill("Live", tone: .positive)) {
      VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
        VStack(alignment: .leading, spacing: 2) {
          Text(timerInterval: session.startedAt...Date.distantFuture, countsDown: false)
            .font(StrandFont.number(heroSize, weight: .bold))
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
          Text(verbatim: session.title).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        FactStrip(facts: facts)
        Button(action: onResume) { Label("Resume lift", systemImage: "play.fill") }
          .buttonStyle(PrimaryPillButtonStyle())
      }
    }
  }

  private var facts: [FactStrip.Fact] {
    var facts: [FactStrip.Fact] = []
    if let progress = store.activeRoutineProgress() {
      facts.append(.init("Sets", value: progress.setLabel))
      facts.append(.init("Exercise", value: progress.moveLabel))
    } else {
      facts.append(.init("Sets", value: session.workingSets.count.formatted()))
    }
    facts.append(
      .init(
        "Volume", value: format.volume(pounds: session.totalVolume),
        spokenValue: format.spokenWeight(pounds: session.totalVolume)))
    return facts
  }
}
