import SwiftUI
import UIKit

enum LiftReceiptPresentation: Equatable, Sendable {
  case freshlyCompleted
  case settled

  var animatesPrint: Bool {
    self == .freshlyCompleted
  }
}

enum LiftReceiptExportValidation: Equatable, Sendable {
  case readable
  case missingImage
  case tooSmall
  case emptyData
}

enum LiftReceiptExportValidator {
  nonisolated static func validate(
    pixelWidth: Int?,
    pixelHeight: Int?,
    byteCount: Int?
  ) -> LiftReceiptExportValidation {
    guard let pixelWidth, let pixelHeight, let byteCount else {
      return .missingImage
    }
    guard pixelWidth >= 600, pixelHeight >= 600 else {
      return .tooSmall
    }
    guard byteCount >= 1_024 else {
      return .emptyData
    }
    return .readable
  }
}

@MainActor
enum LiftReceiptExportRenderer {
  static func render(
    session: LiftSession,
    snapshot: LiftReceiptSnapshot,
    receiptNumber: String,
    paperStyle: ExportPaperStyle,
    displayScale: CGFloat,
    personalRecordsBySetID: [UUID: LiftPersonalRecord] = [:]
  ) -> UIImage? {
    let document = CompletedReceiptDocument(
      session: session,
      snapshot: snapshot,
      receiptNumber: receiptNumber,
      paperStyle: paperStyle,
      totalsRevealed: true,
      personalRecordsBySetID: personalRecordsBySetID
    )
    .frame(width: 390)
    .environment(\.colorScheme, .light)

    let renderer = ImageRenderer(content: document)
    renderer.proposedSize = ProposedViewSize(width: 390, height: nil)
    renderer.scale = max(displayScale, 2)
    renderer.isOpaque = true
    return renderer.uiImage
  }
}

struct CompletedReceiptView: View {
  @EnvironmentObject private var store: LiftStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.displayScale) private var displayScale

  let session: LiftSession
  let presentation: LiftReceiptPresentation
  let onClose: () -> Void
  let onViewReceipts: () -> Void

  @State private var revealProgress: CGFloat
  @State private var contentOpacity: Double
  @State private var totalsRevealed: Bool
  @State private var didBeginPresentation = false
  @State private var printTask: Task<Void, Never>?
  @State private var shareItem: LiftReceiptShareItem?
  @State private var exportErrorMessage: String?
  @State private var cachedPersonalRecordsBySetID: [UUID: LiftPersonalRecord]?

  init(
    session: LiftSession,
    presentation: LiftReceiptPresentation = .freshlyCompleted,
    onClose: @escaping () -> Void = {},
    onViewReceipts: @escaping () -> Void = {}
  ) {
    self.session = session
    self.presentation = presentation
    self.onClose = onClose
    self.onViewReceipts = onViewReceipts

    let startsSettled = presentation == .settled
    _revealProgress = State(initialValue: startsSettled ? 1 : 0)
    _contentOpacity = State(initialValue: startsSettled ? 1 : 0)
    _totalsRevealed = State(initialValue: startsSettled)
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      ScrollView {
        CompletedReceiptDocument(
          session: session,
          snapshot: snapshot,
          receiptNumber: receiptNumber,
          paperStyle: .white,
          totalsRevealed: totalsRevealed,
          personalRecordsBySetID: personalRecordsBySetID
        )
        .mask(alignment: .top) {
          Rectangle()
            .scaleEffect(y: revealMaskScale, anchor: .top)
        }
        .opacity(contentOpacity)
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 112)
      }
      .scrollIndicators(.hidden)

      CompletedReceiptActionBar(
        onClose: onClose,
        onViewReceipts: onViewReceipts,
        onShare: exportReceipt
      )
    }
    .liftScreenBackground()
    .onAppear {
      if cachedPersonalRecordsBySetID == nil {
        cachedPersonalRecordsBySetID = recomputedPersonalRecordsBySetID
      }
      beginPresentation()
    }
    .onDisappear {
      printTask?.cancel()
      printTask = nil
    }
    .sheet(item: $shareItem) { item in
      LiftReceiptActivityView(image: item.image)
    }
    .alert("Couldn’t Share Receipt", isPresented: exportErrorPresentation) {
      Button("Try Again", action: exportReceipt)
      Button("Cancel", role: .cancel) {
        exportErrorMessage = nil
      }
    } message: {
      Text(exportErrorMessage ?? "The receipt image was not readable. Your workout is still saved.")
    }
  }

  private var snapshot: LiftReceiptSnapshot {
    LiftReceiptSnapshot.make(
      session: session,
      exercisesByID: Dictionary(uniqueKeysWithValues: store.exercises.map { ($0.id, $0) }),
      targetSetsByExerciseID: [:]
    )
  }

  private var receiptNumber: String {
    LiftMedia.receiptNumber(for: session, in: store.sessions)
  }

  private var personalRecordsBySetID: [UUID: LiftPersonalRecord] {
    cachedPersonalRecordsBySetID ?? recomputedPersonalRecordsBySetID
  }

  private var recomputedPersonalRecordsBySetID: [UUID: LiftPersonalRecord] {
    guard LiftStore.prDetectionEnabled else { return [:] }
    return LiftProgressMath.historicalPersonalRecords(
      sessions: store.sessions
    ).recordsBySetID
  }

  private var revealMaskScale: CGFloat {
    guard presentation.animatesPrint, !reduceMotion else { return 1 }
    return revealProgress
  }

  private var exportErrorPresentation: Binding<Bool> {
    Binding(
      get: { exportErrorMessage != nil },
      set: { isPresented in
        if !isPresented {
          exportErrorMessage = nil
        }
      }
    )
  }

  private func beginPresentation() {
    guard !didBeginPresentation else { return }
    didBeginPresentation = true

    guard presentation.animatesPrint else {
      revealProgress = 1
      contentOpacity = 1
      totalsRevealed = true
      return
    }

    printTask?.cancel()
    if reduceMotion {
      revealProgress = 1
      withAnimation(LiftMotion.reducedCrossfade) {
        contentOpacity = 1
        totalsRevealed = true
      }
      return
    }

    contentOpacity = 1
    withAnimation(LiftMotion.receiptPrint) {
      revealProgress = 1
    }
    printTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(520))
      guard !Task.isCancelled else { return }
      withAnimation(LiftMotion.printLine) {
        totalsRevealed = true
      }
    }
  }

  private func exportReceipt() {
    exportErrorMessage = nil

    guard let image = LiftReceiptExportRenderer.render(
      session: session,
      snapshot: snapshot,
      receiptNumber: receiptNumber,
      paperStyle: store.settings.exportPaperStyle,
      displayScale: displayScale,
      personalRecordsBySetID: personalRecordsBySetID
    ) else {
      failExport(.missingImage)
      return
    }
    let pngData = image.pngData()
    let validation = LiftReceiptExportValidator.validate(
      pixelWidth: Int((image.size.width * image.scale).rounded()),
      pixelHeight: Int((image.size.height * image.scale).rounded()),
      byteCount: pngData?.count
    )
    guard validation == .readable else {
      failExport(validation)
      return
    }

    shareItem = LiftReceiptShareItem(image: image)
  }

  private func failExport(_ validation: LiftReceiptExportValidation) {
    switch validation {
    case .missingImage:
      exportErrorMessage = "Lift couldn’t render this receipt image. Your workout is still saved."
    case .tooSmall:
      exportErrorMessage = "The rendered receipt was too small to read. Try sharing it again."
    case .emptyData:
      exportErrorMessage = "The rendered receipt contained no readable image data. Try again."
    case .readable:
      exportErrorMessage = nil
    }
  }
}

private struct CompletedReceiptDocument: View {
  let session: LiftSession
  let snapshot: LiftReceiptSnapshot
  let receiptNumber: String
  let paperStyle: ExportPaperStyle
  let totalsRevealed: Bool
  let personalRecordsBySetID: [UUID: LiftPersonalRecord]

  var body: some View {
    VStack(spacing: 0) {
      ReceiptSheet {
        ReceiptHeader(
          title: "Lift Receipt",
          subtitle: liftReceiptDate(session.startedAt),
          trailing: receiptNumber
        )
        Text(session.title.uppercased())
          .font(.receipt(18, weight: .black))
          .foregroundStyle(LiftTheme.ink)
          .fixedSize(horizontal: false, vertical: true)
        ReceiptDashedRule()
        ReceiptColumns([
          ("#", .leading),
          ("Exercise", .leading),
          ("Sets", .trailing),
          ("Volume (lb)", .trailing),
        ])
        ReceiptDashedRule()
        CompletedReceiptRows(
          snapshot: snapshot,
          personalRecordsBySetID: personalRecordsBySetID
        )
        AnimatedReceiptTotals(snapshot: snapshot, isRevealed: totalsRevealed)
        ReceiptDashedRule()
        Text("THANK YOU FOR SHOWING UP.")
          .font(.receipt(11, weight: .black))
          .tracking(1.1)
          .foregroundStyle(LiftTheme.ink)
          .frame(maxWidth: .infinity, alignment: .center)
          .multilineTextAlignment(.center)
        BarcodeView(seed: session.id.uuidString)
        Text(receiptNumber)
          .font(.receipt(9, weight: .bold))
          .foregroundStyle(LiftTheme.inkSecondary)
          .frame(maxWidth: .infinity, alignment: .center)
      }
      .colorMultiply(paperColor)
      ReceiptEdge()
        .colorMultiply(paperColor)
    }
    .background(paperColor)
    .overlay {
      if paperStyle == .cream {
        ReceiptCreamTexture()
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Lift receipt \(receiptNumber)")
  }

  private var paperColor: Color {
    paperStyle == .cream ? LiftTheme.exportCream : LiftTheme.paper
  }
}

private struct CompletedReceiptRows: View {
  let snapshot: LiftReceiptSnapshot
  let personalRecordsBySetID: [UUID: LiftPersonalRecord]

  var body: some View {
    if snapshot.lines.isEmpty {
      Text("NO SETS WERE LOGGED ON THIS RECEIPT.")
        .font(.receipt(11, weight: .bold))
        .foregroundStyle(LiftTheme.inkSecondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 22)
    } else {
      ForEach(snapshot.lines) { line in
        let record = personalRecordsBySetID[line.id]
        ReceiptLine(
          index: line.ordinal,
          title: line.exerciseName,
          detail: line.detailLabel,
          value: record == nil ? line.volumeLabel : "\(line.volumeLabel) · PR"
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityLabel)
        if let record {
          LiftPRPayoffView(record: record)
            .padding(.leading, 33)
        }
      }
    }
  }
}

private struct AnimatedReceiptTotals: View {
  let snapshot: LiftReceiptSnapshot
  let isRevealed: Bool

  var body: some View {
    VStack(spacing: 7) {
      ReceiptRule()
      totalRow(title: "Sets", value: isRevealed ? "\(snapshot.workingSetCount)" : "0")
      totalRow(title: "Total volume", value: liftVolume(isRevealed ? snapshot.totalVolume : 0))
      totalRow(title: "Duration", value: liftClockDuration(isRevealed ? snapshot.duration : 0))
    }
    .animation(LiftMotion.printLine, value: isRevealed)
    .accessibilityElement(children: .combine)
  }

  private func totalRow(title: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title.uppercased())
        .font(.receipt(10, weight: .bold))
        .foregroundStyle(LiftTheme.inkSecondary)
      Spacer(minLength: 8)
      Text(value.uppercased())
        .font(.receipt(13, weight: .black))
        .monospacedDigit()
        .contentTransition(.numericText())
        .fixedSize(horizontal: true, vertical: false)
    }
  }
}

private struct CompletedReceiptActionBar: View {
  let onClose: () -> Void
  let onViewReceipts: () -> Void
  let onShare: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      ReceiptSecondaryButton(
        title: "Close",
        systemImage: "xmark",
        fillsWidth: true,
        action: onClose
      )
      ReceiptSecondaryButton(
        title: "Receipts",
        systemImage: "ticket",
        fillsWidth: true,
        action: onViewReceipts
      )
      ReceiptPrimaryButton(
        title: "Share",
        systemImage: "square.and.arrow.up",
        action: onShare
      )
    }
    .padding(.horizontal, 12)
    .padding(.top, 10)
    .padding(.bottom, 10)
    .background(.ultraThinMaterial)
  }
}

private struct ReceiptCreamTexture: View {
  var body: some View {
    Canvas { context, size in
      for offset in stride(from: CGFloat(7), through: size.height, by: 17) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: offset))
        path.addLine(to: CGPoint(x: size.width, y: offset + 1))
        context.stroke(path, with: .color(LiftTheme.ink.opacity(0.025)), lineWidth: 0.5)
      }
    }
  }
}

private struct LiftReceiptShareItem: Identifiable {
  let id = UUID()
  let image: UIImage
}

private struct LiftReceiptActivityView: UIViewControllerRepresentable {
  let image: UIImage

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [image], applicationActivities: nil)
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
