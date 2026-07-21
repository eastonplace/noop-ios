import SwiftUI

/// The shared raised-paper sheet body. The host owns the real `.sheet` presentation;
/// this component only supplies the approved grabber, header, content, and actions.
public struct PaperSheetCard<Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let primaryTitle: String
    private let close: () -> Void
    private let primaryAction: () -> Void
    private let content: Content

    public init(
        title: String,
        subtitle: String? = nil,
        primaryTitle: String,
        close: @escaping () -> Void,
        primaryAction: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.primaryTitle = primaryTitle
        self.close = close
        self.primaryAction = primaryAction
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            Capsule(style: .continuous)
                .fill(StrandPalette.hairlineStrong)
                .frame(width: 36, height: 5)
                .padding(.top, 9)
                .padding(.bottom, 11)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(StrandFont.cardTitle)
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(StrandPalette.surfaceInset))
                }
                .buttonStyle(SheetsAlertsPressStyle())
                .accessibilityLabel(Text("Close sheet", bundle: .module))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            content.padding(.horizontal, 16)

            Button(action: primaryAction) {
                Text(primaryTitle)
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.surfaceRaised)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(StrandPalette.textPrimary)
                    )
            }
            .buttonStyle(SheetsAlertsPressStyle())
            .padding(16)
        }
        .background(sheetShape)
    }

    private var sheetShape: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 22,
            bottomLeadingRadius: 14,
            bottomTrailingRadius: 14,
            topTrailingRadius: 22,
            style: .continuous
        )
        .fill(StrandPalette.surfaceRaised)
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 22,
                bottomLeadingRadius: 14,
                bottomTrailingRadius: 14,
                topTrailingRadius: 22,
                style: .continuous
            )
            .strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.16), StrandPalette.hairline],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        )
    }
}

/// Consequence-first confirmation gate. Business effects stay in the supplied closures.
public struct ConfirmGateCard: View {
    private let icon: String
    private let tint: Color
    private let title: String
    private let message: String
    private let confirmTitle: String
    private let cancel: () -> Void
    private let confirm: () -> Void

    public init(
        icon: String,
        tint: Color,
        title: String,
        message: String,
        confirmTitle: String,
        cancel: @escaping () -> Void,
        confirm: @escaping () -> Void
    ) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.cancel = cancel
        self.confirm = confirm
    }

    public var body: some View {
        VStack(spacing: 12) {
            gateIcon(icon, tint: tint)
            VStack(spacing: 4) {
                Text(title)
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(message)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                gateButton(String(localized: "Cancel", bundle: .module), foreground: StrandPalette.textPrimary,
                           background: StrandPalette.surfaceInset, action: cancel)
                gateButton(confirmTitle, foreground: StrandPalette.surfaceRaised,
                           background: StrandPalette.textPrimary, action: confirm)
            }
        }
        .gateCardSurface()
        .accessibilityElement(children: .contain)
    }
}

/// A destructive button that calls its action only after one uninterrupted hold.
public struct HoldToConfirmButton: View {
    private let title: String
    private let completedTitle: String
    private let holdSeconds: Double
    private let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: Double = 0
    @State private var contract = HoldToConfirmContract()
    @State private var confirmationTask: Task<Void, Never>?

    public init(
        title: String,
        completedTitle: String? = nil,
        holdSeconds: Double = 1.2,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.completedTitle = completedTitle ?? String(localized: "Removed", bundle: .module)
        self.holdSeconds = HoldToConfirmContract.normalized(seconds: holdSeconds)
        self.action = action
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(StrandPalette.metricRose.opacity(0.12))
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(StrandPalette.metricRose.opacity(contract.confirmed ? 1 : 0.82))
                    .frame(width: proxy.size.width * progress)
                HStack(spacing: 7) {
                    Image(systemName: contract.confirmed ? "checkmark" : "trash")
                        .font(.system(size: 12, weight: .bold))
                    Text(contract.confirmed ? completedTitle : title)
                        .font(StrandFont.caption.weight(.semibold))
                        .contentTransition(.opacity)
                }
                .foregroundStyle(progress > 0.45 || contract.confirmed ? StrandPalette.surfaceRaised : StrandPalette.metricRose)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .scaleEffect(contract.holding && !reduceMotion ? 0.985 : 1)
        .contentShape(Rectangle())
        .gesture(holdGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(contract.confirmed ? completedTitle : String(localized: "\(title). Hold to confirm", bundle: .module))
        .onDisappear { cancelHold(playWarning: false) }
    }

    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in startHold() }
            .onEnded { _ in
                if !contract.confirmed { cancelHold(playWarning: true) }
            }
    }

    private func startHold() {
        guard contract.begin() else { return }
        StrandHaptic.light.play()
        withAnimation(.linear(duration: holdSeconds)) { progress = 1 }
        confirmationTask?.cancel()
        confirmationTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
            } catch { return }
            guard !Task.isCancelled, contract.complete() else { return }
            StrandHaptic.commit.play()
            action()
        }
    }

    private func cancelHold(playWarning: Bool) {
        confirmationTask?.cancel()
        confirmationTask = nil
        if !contract.confirmed {
            withAnimation(reduceMotion ? nil : StrandMotion.value) { progress = 0 }
            if playWarning { StrandHaptic.warning.play() }
        }
        contract.cancel()
    }
}

/// Pure state seam for the uninterrupted-hold and exactly-once contracts.
struct HoldToConfirmContract: Equatable {
    static let defaultHoldSeconds = 1.2
    static let minimumHoldSeconds = 0.1

    private(set) var holding = false
    private(set) var confirmed = false

    static func normalized(seconds: Double) -> Double {
        max(minimumHoldSeconds, seconds)
    }

    mutating func begin() -> Bool {
        guard !holding, !confirmed else { return false }
        holding = true
        return true
    }

    mutating func cancel() {
        holding = false
    }

    mutating func complete() -> Bool {
        guard holding, !confirmed else { return false }
        confirmed = true
        holding = false
        return true
    }
}

/// Consequence-first destructive gate with the fixed 1.2-second hold contract.
public struct DestructiveGateCard: View {
    private let title: String
    private let message: String
    private let confirmTitle: String
    private let completedTitle: String
    private let cancelTitle: String
    private let cancel: () -> Void
    private let confirm: () -> Void

    public init(
        title: String,
        message: String,
        confirmTitle: String,
        completedTitle: String? = nil,
        cancelTitle: String? = nil,
        cancel: @escaping () -> Void,
        confirm: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.completedTitle = completedTitle ?? String(localized: "Removed", bundle: .module)
        self.cancelTitle = cancelTitle ?? String(localized: "Keep everything", bundle: .module)
        self.cancel = cancel
        self.confirm = confirm
    }

    public var body: some View {
        VStack(spacing: 12) {
            gateIcon("trash", tint: StrandPalette.metricRose)
            VStack(spacing: 4) {
                Text(title)
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(message)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HoldToConfirmButton(title: confirmTitle, completedTitle: completedTitle, action: confirm)
            gateButton(cancelTitle, foreground: StrandPalette.textPrimary,
                       background: StrandPalette.surfaceInset, action: cancel)
        }
        .gateCardSurface()
        .accessibilityElement(children: .contain)
    }
}

/// Compact positive landing for a completed operation. Hosting and dismissal stay owner-controlled.
public struct SuccessFlashCard: View {
    private let message: String
    private let detail: String

    public init(message: String, detail: String) {
        self.message = message
        self.detail = detail
    }

    public var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(StrandPalette.surfaceRaised)
                .frame(width: 30, height: 30)
                .background(Circle().fill(StrandPalette.chargeAccent))
            VStack(alignment: .leading, spacing: 1) {
                Text(message)
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(detail)
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(StrandPalette.surfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(StrandPalette.chargeAccent.opacity(0.35), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(message). \(detail)")
    }
}

private func gateIcon(_ systemName: String, tint: Color) -> some View {
    Image(systemName: systemName)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 44, height: 44)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .accessibilityHidden(true)
}

private func gateButton(
    _ title: String,
    foreground: Color,
    background: Color,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        Text(title)
            .font(StrandFont.caption.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(background))
    }
    .buttonStyle(SheetsAlertsPressStyle())
}

private extension View {
    func gateCardSurface() -> some View {
        padding(18)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(StrandPalette.surfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.16), StrandPalette.hairline],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    )
            )
    }
}

private struct SheetsAlertsPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
