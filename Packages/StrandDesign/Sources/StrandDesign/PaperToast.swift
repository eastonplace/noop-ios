import SwiftUI

#if canImport(Accessibility)
import Accessibility
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Low, non-stacking transient feedback promoted from the NOOP design lab.
public struct PaperToast: View {
    private let message: LocalizedStringKey
    private let systemImage: String
    private let tint: Color
    private let actionTitle: LocalizedStringKey?
    private let announcement: String?
    private let action: (() -> Void)?
    private let dismissesOnAction: Bool
    private let dismiss: (() -> Void)?
    private let dwellDuration: TimeInterval?

    @State private var remaining = 1.0

    public init(
        _ message: LocalizedStringKey,
        systemImage: String = "checkmark.circle.fill",
        tint: Color = StrandPalette.statusPositive,
        actionTitle: LocalizedStringKey? = nil,
        announcement: String? = nil,
        dismissesOnAction: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.init(
            message: message,
            systemImage: systemImage,
            tint: tint,
            actionTitle: actionTitle,
            announcement: announcement,
            dismissesOnAction: dismissesOnAction,
            action: action,
            dismiss: nil,
            dwellDuration: nil
        )
    }

    private init(
        message: LocalizedStringKey,
        systemImage: String,
        tint: Color,
        actionTitle: LocalizedStringKey?,
        announcement: String?,
        dismissesOnAction: Bool,
        action: (() -> Void)?,
        dismiss: (() -> Void)?,
        dwellDuration: TimeInterval?
    ) {
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.actionTitle = actionTitle
        self.announcement = announcement
        self.dismissesOnAction = dismissesOnAction
        self.action = action
        self.dismiss = dismiss
        self.dwellDuration = dwellDuration
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(tint.opacity(0.12)))
                    .accessibilityHidden(true)

                Text(message)
                    .font(StrandFont.caption.weight(.medium))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                if let actionTitle, let action {
                    Button {
                        action()
                        if dismissesOnAction { dismiss?() }
                    } label: {
                        Text(actionTitle)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(StrandPalette.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(minWidth: 44, minHeight: 44)
                            .background(Capsule(style: .continuous).fill(StrandPalette.accent.opacity(0.1)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)

            GeometryReader { proxy in
                Rectangle()
                    .fill(tint.opacity(0.5))
                    .frame(width: proxy.size.width * remaining, height: 2)
            }
            .frame(height: 2)
        }
        .background(StrandPalette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
        .accessibilityElement(children: action == nil ? .combine : .contain)
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear {
            announceMessage()
            startLifetimeDrain()
        }
    }

    fileprivate func dismissingAction(_ dismiss: @escaping () -> Void) -> PaperToast {
        PaperToast(
            message: message,
            systemImage: systemImage,
            tint: tint,
            actionTitle: actionTitle,
            announcement: announcement,
            dismissesOnAction: dismissesOnAction,
            action: action,
            dismiss: dismiss,
            dwellDuration: dwellDuration
        )
    }

    fileprivate func timed(dwellNanoseconds: UInt64?) -> PaperToast {
        PaperToast(
            message: message,
            systemImage: systemImage,
            tint: tint,
            actionTitle: actionTitle,
            announcement: announcement,
            dismissesOnAction: dismissesOnAction,
            action: action,
            dismiss: dismiss,
            dwellDuration: dwellNanoseconds.map { TimeInterval($0) / 1_000_000_000 }
        )
    }

    private func startLifetimeDrain() {
        remaining = 1
        guard let dwellDuration else { return }
        withAnimation(.linear(duration: dwellDuration)) { remaining = 0 }
    }

    private func announceMessage() {
        guard let announcement, !announcement.isEmpty else { return }

        #if os(iOS)
        if #available(iOS 17.0, *) {
            AccessibilityNotification.Announcement(announcement).post()
        } else {
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }
        #elseif os(macOS)
        if #available(macOS 14.0, *) {
            AccessibilityNotification.Announcement(announcement).post()
        }
        #elseif os(watchOS)
        AccessibilityNotification.Announcement(announcement).post()
        #endif
    }
}

struct PaperToastDwellState: Equatable {
    static let defaultDwellNanoseconds: UInt64 = 2_400_000_000

    private(set) var generation = 0
    private(set) var activeGeneration: Int?

    mutating func present() -> Int {
        generation += 1
        activeGeneration = generation
        return generation
    }

    mutating func cancel() {
        activeGeneration = nil
    }

    func shouldDismiss(generation: Int) -> Bool {
        activeGeneration == generation
    }
}

enum PaperToastDismissal: Equatable {
    case automatic
    case ownerControlled

    var dwellNanoseconds: UInt64? {
        switch self {
        case .automatic:
            return PaperToastDwellState.defaultDwellNanoseconds
        case .ownerControlled:
            return nil
        }
    }
}

private struct PaperToastPresenter: ViewModifier {
    @Binding var isPresented: Bool
    /// `nil` leaves dismissal entirely to the owner. This is intentionally additive:
    /// the standard toast still owns its 2.4-second timer, while legacy actions with an
    /// existing semantic timer (Sleep delete undo) can reuse the presentation without
    /// introducing a second, competing clock.
    let dwellNanoseconds: UInt64?
    let toast: () -> PaperToast

    @State private var dwell = PaperToastDwellState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if isPresented {
                    toast()
                        .dismissingAction(dismiss)
                        .timed(dwellNanoseconds: dwellNanoseconds)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .offset(y: 12).combined(with: .opacity)
                        )
                        .onAppear { _ = dwell.present() }
                        .task(id: dwell.generation) {
                            guard let dwellNanoseconds else { return }
                            let generation = dwell.generation
                            do {
                                try await Task.sleep(nanoseconds: dwellNanoseconds)
                            } catch {
                                return
                            }
                            guard !Task.isCancelled,
                                  isPresented,
                                  dwell.shouldDismiss(generation: generation)
                            else { return }
                            dismiss()
                        }
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.22) : StrandMotion.reveal,
                       value: isPresented)
            .onChangeCompat(of: isPresented) { presented in
                if !presented { dwell.cancel() }
            }
            .onDisappear { dwell.cancel() }
    }

    private func dismiss() {
        dwell.cancel()
        withAnimation(.easeOut(duration: 0.22)) {
            isPresented = false
        }
    }
}

public extension View {
    /// Presents one low toast and dismisses it after the design-system 2.4-second dwell.
    func paperToast(
        isPresented: Binding<Bool>,
        @ViewBuilder toast: @escaping () -> PaperToast
    ) -> some View {
        modifier(PaperToastPresenter(
            isPresented: isPresented,
            dwellNanoseconds: PaperToastDwellState.defaultDwellNanoseconds,
            toast: toast
        ))
    }

    /// Additive dwell override for existing actions whose semantic window is longer than
    /// the standard toast dwell (for example, the seven-second Sleep delete undo window).
    func paperToast(
        isPresented: Binding<Bool>,
        dwell: TimeInterval,
        @ViewBuilder toast: @escaping () -> PaperToast
    ) -> some View {
        let nanoseconds = UInt64(max(0, dwell) * 1_000_000_000)
        return modifier(PaperToastPresenter(
            isPresented: isPresented,
            dwellNanoseconds: nanoseconds,
            toast: toast
        ))
    }

    /// Additive owner-controlled presentation. Pass `false` when the owning feature
    /// already has the one authoritative dismissal timer; no auto-dismiss task is
    /// scheduled by `PaperToast` in that mode.
    func paperToast(
        isPresented: Binding<Bool>,
        autoDismiss: Bool,
        @ViewBuilder toast: @escaping () -> PaperToast
    ) -> some View {
        modifier(PaperToastPresenter(
            isPresented: isPresented,
            dwellNanoseconds: (autoDismiss
                ? PaperToastDismissal.automatic
                : PaperToastDismissal.ownerControlled).dwellNanoseconds,
            toast: toast
        ))
    }
}

#if DEBUG
private struct PaperToastPreview: View {
    @State private var visible = true

    var body: some View {
        VStack {
            Button("Show toast") { visible = true }
            Spacer()
        }
        .padding()
        .frame(width: 390, height: 300)
        .background(StrandPalette.canvas)
        .paperToast(isPresented: $visible) {
            PaperToast("Workout saved", actionTitle: "Undo") {}
        }
    }
}

#Preview("PaperToast") { PaperToastPreview() }
#endif
