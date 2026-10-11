import StrandDesign
import SwiftUI

// MARK: - Lift home
//
// The page Lift opens on: begin a workout (blank, or from a routine), pick up the one in flight, and see the week at a
// glance. History, Progress and Routines are one tap away as chips, the way the Workouts hub offers them.

struct LiftStartView: View {
  @EnvironmentObject private var store: LiftStore
  @Environment(\.liftFormat) private var format
  @Environment(\.liftHostChrome) private var host

  let onOpenSettings: () -> Void
  let onResume: () -> Void
  let onStartOpen: () -> Void
  let onPreview: (LiftRoutine) -> Void
  let onOpen: (LiftRoute) -> Void

  @State private var week = LiftSevenDaySummary.zero
  @State private var lastLift: LiftSession?

  var body: some View {
    LiftPage(
      title: "Lift",
      trailing: { HeaderChipButton("gearshape", accessibilityLabel: "Lift settings", action: onOpenSettings) }
    ) {
      if let session = store.activeSession {
        LiftInProgressSection(session: session, onResume: onResume)
      } else {
        startSection
      }
      FlatSectionSeparator()
      thisWeekSection
      if store.activeSession == nil {
        FlatSectionSeparator()
        routinesSection
      }
    }
    .onAppear(perform: refreshSummaries)
    .onChange(of: store.sessions) { refreshSummaries() }
  }

  // MARK: Start

  private var startSection: some View {
    LiftFlatSection("Start") {
      VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
        if let lastLift { LiftLastLiftLine(session: lastLift) }
        Button(action: onStartOpen) {
          Label("Open workout", systemImage: "plus")
        }
        .buttonStyle(PrimaryPillButtonStyle())
        .accessibilityHint("Starts a lift you build as you go")
        LiftChipLinks(onOpen: onOpen)
      }
    }
  }

  // MARK: This week

  private var thisWeekSection: some View {
    LiftFlatSection("This week", systemImage: "calendar") {
      if week.workoutCount > 0 {
        FactStrip(facts: [
          .init("Workouts", value: week.workoutCount.formatted()),
          .init("Sets", value: week.workingSetCount.formatted()),
          .init(
            "Volume", value: format.volume(pounds: week.volume),
            spokenValue: format.spokenWeight(pounds: week.volume)),
        ])
      } else {
        LiftNote(text: "No lifts in the last 7 days")
      }
    }
  }

  // MARK: Routines

  private var routinesSection: some View {
    LiftFlatSection("Routines", systemImage: "list.bullet.rectangle", contentSpacing: 0) {
      if store.routines.isEmpty {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
          LiftNote(text: "No routines yet. Create one, or open a workout and add exercises as you go.")
          Button { onOpen(.routines) } label: { Label("Create routine", systemImage: "plus") }
            .buttonStyle(PrimaryPillButtonStyle())
        }
        .padding(.top, NoopMetrics.space3)
      } else {
        let nextID = store.nextSuggestedRoutine?.id
        LiftRowList(items: store.routines, separatorInset: GlyphDisc.diameter(scaled: 38) + NoopMetrics.space3) { routine, _ in
          Button { onPreview(routine) } label: {
            LiftListRow(
              title: routine.name,
              details: [routineDetail(routine)],
              showsChevron: true,
              leading: { GlyphDisc("dumbbell.fill") },
              accessory: { if routine.id == nextID { StatePill("Next up", tone: .accent, showsDot: false).fixedSize() } }
            )
          }
          .buttonStyle(FlatRowPressStyle())
          .accessibilityElement(children: .combine)
          .accessibilityHint("Opens the routine before you start")
        }
      }
    }
  }

  private func routineDetail(_ routine: LiftRoutine) -> String {
    let minutes = store.estimatedMinutes(for: routine)
    let count = routine.exerciseIDs.count
    var facts = [String(localized: "\(count) exercises")]
    if minutes > 0 { facts.append(String(localized: "\(minutes) min")) }
    return facts.joined(separator: " · ")
  }

  private func refreshSummaries() {
    week = LiftTodayMath.sevenDaySummary(in: store.sessions, asOf: Date(), calendar: .current)
    lastLift = store.lastCompletedSession
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
        title: "Routines", systemImage: "calendar", showsChevron: true,
        accessibilityLabel: "Manage routines"
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
      facts.append(String(localized: "\(sets) sets"))
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
      Text(verbatim: facts.joined(separator: " · "))
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
