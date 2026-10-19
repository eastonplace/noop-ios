import StrandDesign
import SwiftUI

/// Where the summary was opened from: straight after finishing (closing returns to Lift) or from History (a pushed page).
enum LiftSummaryContext { case freshlyCompleted, history }

// MARK: - Post-session summary
//
// Phone 4 of the approved design: Strain with the heart-rate-only mark and the with-your-sets mark on one gauge, a
// plain-language lede, a strip of the session's numbers and what was lifted, best set first. Every number is the stored
// one: Strain comes from the provider, never from a formula in the view.

struct LiftSessionSummaryView: View {
  @EnvironmentObject private var store: LiftStore
  @Environment(\.liftFormat) private var format
  @Environment(\.liftStrainProvider) private var strainProvider
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize

  let session: LiftSession
  let context: LiftSummaryContext
  var onClose: () -> Void = {}
  var onViewReceipts: () -> Void = {}

  @State private var snapshot: LiftStrainSnapshot?
  @State private var strainState: LiftSummaryStrainState = .scoring
  @State private var appearedAt = Date()
  @State private var showsReceipt = false
  @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 64

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 0) {
        strainSection
        FlatSectionSeparator()
        statStrip
        FlatSectionSeparator()
        liftedSection
      }
      .padding(.horizontal, LiftChromeMetrics.gutter)
      .padding(.top, NoopMetrics.space3)
      .padding(.bottom, NoopMetrics.space6)
      .frame(maxWidth: LiftChromeMetrics.maxColumnWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .scrollIndicators(.hidden)
    .background(StrandPalette.appCanvas.ignoresSafeArea())
    .safeAreaInset(edge: .top, spacing: 0) { header }
    .toolbar(.hidden, for: .navigationBar)
    .background { EdgeSwipeBack(rootBackAction: context == .freshlyCompleted ? onClose : nil).frame(width: 0, height: 0) }
    .navigationDestination(isPresented: $showsReceipt) {
      CompletedReceiptView(
        session: session,
        presentation: context == .freshlyCompleted ? .freshlyCompleted : .settled,
        onClose: onClose,
        onViewReceipts: onViewReceipts
      )
      .environmentObject(store)
    }
    .task(id: session.id) { await observeStrain() }
  }

  // MARK: Header

  private var header: some View {
    StrengthHeader(title: LocalizedStringKey(userText: session.title), onBack: {
      if context == .freshlyCompleted { onClose() } else { dismiss() }
    }) {
      HStack(spacing: NoopMetrics.space1) {
        if !typeSize.isAccessibilitySize {
          Text(verbatim: dayAndDuration)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        HeaderChipButton("ticket", accessibilityLabel: "Receipt") { showsReceipt = true }
      }
    }
    .padding(.horizontal, LiftChromeMetrics.gutter)
    .padding(.top, NoopMetrics.space3)
    .padding(.bottom, NoopMetrics.space1)
    .frame(maxWidth: LiftChromeMetrics.maxColumnWidth + LiftChromeMetrics.gutter * 2)
    .frame(maxWidth: .infinity)
    .background(StrandPalette.appCanvas)
  }

  private var duration: TimeInterval { (session.endedAt ?? session.startedAt).timeIntervalSince(session.startedAt) }

  private var dayAndDuration: String {
    let day = session.startedAt.formatted(.dateTime.weekday(.abbreviated).locale(format.locale))
    return [day, duration >= 60 ? format.shortDuration(duration) : ""].filter { !$0.isEmpty }.joined(separator: " · ")
  }

  // MARK: Strain

  private var strainSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      SectionEyebrow("Strain", systemImage: "flame.fill", tint: .strain, trailing: bandPill)
      switch strainState {
      case .scored(let snapshot): scored(snapshot)
      case .scoring:
        HStack(spacing: NoopMetrics.space3) {
          ProgressView().tint(StrandPalette.textSecondary)
          Text("Scoring…").font(StrandFont.title2).foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(.top, NoopMetrics.space4)
        .accessibilityElement(children: .combine)
      case .waiting: placeholder("Strain will update when heart data syncs")
      case .notScoredYet: placeholder("Not scored yet · wear your strap during lifts")
      case .noSets(let heartRate):
        if let heartRate {
          bigValue(heartRate)
          Text("Log sets to count lifting")
            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary).padding(.top, NoopMetrics.space3)
        } else {
          placeholder("Log sets to count lifting")
        }
      case .unavailable: placeholder("Strain isn’t ready for this lift yet.")
      }
    }
  }

  private var bandPill: EyebrowTrailing {
    guard case .scored(let snapshot) = strainState, let combined = snapshot.combinedDisplay else { return .none }
    return .custom(AnyView(ValuePill(StrainScale.band(combined).title, tint: StrandPalette.strainAccent, dotTint: StrandPalette.strainAccent)))
  }

  private func placeholder(_ text: LocalizedStringKey) -> some View {
    Text(text)
      .font(StrandFont.title2)
      .foregroundStyle(StrandPalette.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, NoopMetrics.space4)
  }

  private func bigValue(_ value: Double) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(verbatim: value.formatted(.number.precision(.fractionLength(1)).locale(format.locale)))
        .font(StrandFont.sized(heroSize, weight: .bold))
        .tracking(-2)
        .monospacedDigit()
        .foregroundStyle(StrandPalette.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
      Text("of 21").font(StrandFont.body.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
    }
    .padding(.top, NoopMetrics.space3)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private func scored(_ snapshot: LiftStrainSnapshot) -> some View {
    if let combined = snapshot.combinedDisplay, let heartRate = snapshot.heartRateDisplay {
      let add = max(combined - heartRate, 0)
      bigValue(combined)
      LiftStrainGauge(heartRate: heartRate, combined: combined, locale: format.locale)
        .padding(.top, NoopMetrics.space3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Strain")
        .accessibilityValue(Text(verbatim: spokenStrain(combined: combined, heartRate: heartRate, add: add)))
      Text(markdown: LiftSessionSummaryLogic.lede(
        heartRate: heartRate, combined: combined, workingSets: snapshot.workingSets,
        rpeRange: LiftSessionSummaryLogic.rpeRange(LiftSessionSummaryLogic.ratedWorkingEfforts(session)),
        locale: format.locale), emphasis: StrandPalette.textPrimary)
        .font(StrandFont.body)
        .foregroundStyle(StrandPalette.textSecondary)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, NoopMetrics.space3)
      if snapshot.bodyweightIsDefault {
        Text(verbatim: LiftSessionSummaryLogic.defaultBodyweightNote())
          .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary).padding(.top, NoopMetrics.space2)
      }
    } else {
      placeholder("Strain isn’t ready for this lift yet.")
    }
  }

  private func spokenStrain(combined: Double, heartRate: Double, add: Double) -> String {
    func n(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1)).locale(format.locale)) }
    return String(localized: "Strain \(n(combined)) of 21; heart rate only \(n(heartRate)); your sets add \(n(add))")
  }

  // MARK: Strip

  private var statStrip: some View {
    let efforts = LiftSessionSummaryLogic.ratedWorkingEfforts(session)
    let working = session.workingSets.count
    let warmups = session.sets.count - working
    let volume = format.volumeParts(pounds: session.totalVolume)
    var items: [StrengthStatStrip.Item] = [
      .init(id: "sets", label: "Working sets", value: working.formatted(),
            caption: warmups > 0 ? String(localized: "+\(warmups) warm-ups") : nil,
            spoken: "\(LiftFormat.setCount(working))" + (warmups > 0 ? ", \(warmups) warm-ups" : "")),
      .init(id: "volume", label: "Volume", value: volume.number, caption: String(localized: "\(volume.unit) lifted"),
            spoken: format.spokenWeight(pounds: session.totalVolume)),
    ]
    if let average = LiftSessionSummaryLogic.averageEffort(efforts) {
      let text = average.formatted(.number.precision(.fractionLength(1)).locale(format.locale))
      items.append(.init(
        id: "effort", label: "Avg effort", value: String(localized: "RPE \(text)"),
        caption: LiftSessionSummaryLogic.effortWord(average)))
    }
    return StrengthStatStrip(items: items)
  }

  // MARK: What you lifted

  private var liftedSection: some View {
    let records = LiftStore.prDetectionEnabled
      ? Set(LiftProgressMath.historicalPersonalRecords(sessions: store.sessions).recordsBySetID.keys) : []
    let lifts = LiftSummaryLifts.make(
      session: session, exercises: Dictionary(uniqueKeysWithValues: store.exercises.map { ($0.id, $0) }),
      recordSetIDs: records)
    return VStack(alignment: .leading, spacing: 0) {
      SectionEyebrow("What you lifted", systemImage: "dumbbell.fill", tint: .muscular, trailing: .text(String(localized: "best set")))
        .padding(.bottom, NoopMetrics.space1)
      ForEach(Array(lifts.enumerated()), id: \.element.id) { index, lift in
        if index > 0 { FlatRowSeparator(leadingInset: 48 + 12) }
        LiftSummaryLiftRow(lift: lift)
      }
      if lifts.isEmpty { LiftNote(text: "No working sets were logged in this lift.") }
    }
  }

  // MARK: Strain resolution

  /// Resolves the state now, then again on every provider update and when the timeout passes, so a summary waiting on
  /// heart data swaps to the score the moment it exists and never spins past the timeout.
  private func observeStrain() async {
    appearedAt = Date()
    let timeout = LiftSummaryStrainState.timeout
    await resolve(timeout: timeout)
    guard let strainProvider else {
      try? await Task.sleep(for: .seconds(timeout))
      if !Task.isCancelled { await resolve(timeout: timeout) }
      return
    }
    let updates = strainProvider.updates()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { @MainActor in
        for await _ in updates {
          if Task.isCancelled { return }
          await resolve(timeout: timeout)
        }
      }
      group.addTask { @MainActor in
        try? await Task.sleep(for: .seconds(timeout))
        if !Task.isCancelled { await resolve(timeout: timeout) }
      }
      await group.waitForAll()
    }
  }

  private func resolve(timeout: TimeInterval) async {
    let latest = await strainProvider?.summary(sessionID: session.id.uuidString)
    snapshot = latest
    strainState = LiftSummaryStrainState.resolve(snapshot: latest, elapsed: Date().timeIntervalSince(appearedAt), timeout: timeout)
  }
}

extension Text {
  /// Text from a string whose `**bold**` runs are real emphasis, in `emphasis` colour; a string that fails to parse is
  /// shown as it is.
  init(markdown: String, emphasis: Color) {
    if var attributed = try? AttributedString(markdown: markdown) {
      for run in attributed.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
        attributed[run.range].foregroundColor = emphasis
      }
      self.init(attributed)
    } else {
      self.init(verbatim: markdown)
    }
  }
}

// MARK: - Gauge

/// The 0-21 track with the heart-rate-only share in blue, what the sets add in purple, and a mark and a label on each.
struct LiftStrainGauge: View {
  let heartRate: Double
  let combined: Double
  let locale: Locale

  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 11.5

  private var scale: Double { StrainScale.displayRange.upperBound }

  var body: some View {
    let hr = min(max(heartRate, 0), scale) / scale
    let total = min(max(combined, 0), scale) / scale
    VStack(alignment: .leading, spacing: 0) {
      if typeSize.isAccessibilitySize {
        track(hr: hr, total: total)
        scaleEnds.padding(.top, NoopMetrics.space2)
        legend.padding(.top, NoopMetrics.space3)
      } else {
        ZStack(alignment: .top) {
          track(hr: hr, total: total).padding(.top, 30)
          MarkerLabels(fractions: [hr, total]) {
            label("Heart rate only · \(number(heartRate))", foreground: StrandPalette.textSecondary, fill: StrandPalette.tagFill)
            label("With your sets · \(number(combined))", foreground: StrandPalette.onLightFill, fill: StrandPalette.solidFill)
          }
        }
        scaleEnds.padding(.top, 24)
      }
    }
  }

  private func number(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)).locale(locale))
  }

  private func track(hr: Double, total: Double) -> some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        Capsule(style: .continuous).fill(StrandPalette.surfaceInset).frame(height: 12)
        UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
          .fill(StrandPalette.strainAccent).frame(width: width * hr, height: 12)
        Rectangle().fill(StrandPalette.muscularAccent).frame(width: max(width * (total - hr), 0), height: 12)
          .offset(x: width * hr)
        Capsule(style: .continuous).fill(StrandPalette.textSecondary).frame(width: 3, height: 28).offset(x: width * hr - 1.5)
        Capsule(style: .continuous).fill(Color.white).frame(width: 3, height: 28).offset(x: width * total - 1.5)
      }
      .frame(height: 28)
    }
    .frame(height: 28)
  }

  private var scaleEnds: some View {
    HStack {
      Text(verbatim: "0")
      Spacer()
      Text(verbatim: "21")
    }
    .font(StrandFont.sized(labelSize, weight: .regular))
    .foregroundStyle(StrandPalette.textTertiary)
    .accessibilityHidden(true)
  }

  private func label(_ text: LocalizedStringKey, foreground: Color, fill: Color) -> some View {
    Text(text)
      .font(StrandFont.sized(labelSize, weight: .bold))
      .foregroundStyle(foreground)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(fill, in: Capsule(style: .continuous))
  }

  private var legend: some View {
    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
      legendRow(color: StrandPalette.strainAccent, text: "Heart rate only · \(number(heartRate))")
      legendRow(color: StrandPalette.muscularAccent, text: "With your sets · \(number(combined))")
    }
  }

  private func legendRow(color: Color, text: LocalizedStringKey) -> some View {
    HStack(spacing: 8) {
      RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color).frame(width: 10, height: 10)
      Text(text).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// Places each child centred over its fraction of the width, kept inside the row, the first above the track and the
/// second below its mark.
private struct MarkerLabels: Layout {
  let fractions: [Double]

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    CGSize(width: proposal.width ?? 0, height: 58)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for (index, subview) in subviews.enumerated() where index < fractions.count {
      let size = subview.sizeThatFits(.unspecified)
      let centre = bounds.minX + bounds.width * CGFloat(fractions[index])
      let x = min(max(centre - size.width / 2, bounds.minX), bounds.maxX - size.width)
      let y = index == 0 ? bounds.minY : bounds.minY + 50
      subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
    }
  }
}

// MARK: - Row

struct LiftSummaryLiftRow: View {
  let lift: LiftSummaryLift
  @Environment(\.liftFormat) private var format
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let figure = lift.showsReps ? "\(lift.best.reps)" : format.number(pounds: lift.best.estimatedOneRepMax)
    let caption = lift.showsReps ? String(localized: "reps") : String(localized: "e1RM \(format.unitSymbol)")
    let setLine = String(localized: "\(LiftFormat.setCount(lift.workingSets)) · \(format.number(pounds: lift.best.weight)) × \(lift.best.reps)")
    Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 6) {
          StrengthExerciseTile(exercise: lift.exercise, size: 48, cornerRadius: 12)
          titleLine
          Text(verbatim: setLine).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
          figureStack(figure, caption, alignment: .leading)
        }
      } else {
        HStack(spacing: 12) {
          StrengthExerciseTile(exercise: lift.exercise, size: 48, cornerRadius: 12)
          VStack(alignment: .leading, spacing: 2) {
            titleLine
            Text(verbatim: setLine).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
              .lineLimit(1).minimumScaleFactor(0.8)
          }
          Spacer(minLength: 8)
          figureStack(figure, caption, alignment: .trailing)
        }
      }
    }
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      LiftFormat.spoken([
        lift.name.liftDisplayName, LiftFormat.setCount(lift.workingSets),
        lift.isPersonalRecord ? String(localized: "personal record") : "",
        lift.showsReps ? LiftFormat.repCount(lift.best.reps) : String(localized: "estimated one-rep max \(format.spokenWeight(pounds: lift.best.estimatedOneRepMax))"),
      ]))
  }

  private var titleLine: some View {
    HStack(spacing: 6) {
      Text(verbatim: lift.name.liftDisplayName)
        .font(StrandFont.body.weight(.semibold))
        .foregroundStyle(StrandPalette.textPrimary)
        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
        .minimumScaleFactor(0.8)
      if lift.isPersonalRecord { LiftTag(text: "PR", systemImage: "star.fill", tint: StrandPalette.signalYellow) }
    }
  }

  private func figureStack(_ figure: String, _ caption: String, alignment: HorizontalAlignment) -> some View {
    VStack(alignment: alignment, spacing: 2) {
      Text(verbatim: figure).font(StrandFont.body.weight(.semibold)).monospacedDigit().foregroundStyle(StrandPalette.textPrimary)
      Text(verbatim: caption).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
    }
  }
}
