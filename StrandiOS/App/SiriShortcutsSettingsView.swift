#if os(iOS)
import SwiftUI
import AppIntents

/// Uses the same NativeSettingsList as the surrounding settings screens.
struct SiriShortcutsSettingsView: View {
    var body: some View {
        NativeSettingsList {
            Section {
                SiriTipView(intent: AskLocalCoachIntent(), isVisible: .constant(true))
                Text("Say ‘Ask NOOP coach’. Siri asks for your question. NOOP opens with an editable draft; tap Send when it is ready.")
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Ask your coach")
            } footer: {
                Text("Unlock your iPhone to use Coach actions. These actions do not return health records or coach answers to Siri.")
            }

            Section {
                phrase("Morning outlook", spoken: "My morning outlook in NOOP", symbol: "sun.horizon")
                phrase("Evening review", spoken: "Review my evening in NOOP", symbol: "moon.stars")
                phrase("Weekly review", spoken: "Review my week in NOOP", symbol: "calendar")
                phrase("Activity review", spoken: "Review my activity in NOOP", symbol: "figure.run")
                phrase("Sleep review", spoken: "Review my sleep in NOOP", symbol: "bed.double")
                phrase("Training plan", spoken: "Build a training plan in NOOP", symbol: "list.clipboard")
                Text("For an existing plan, say ‘Review my training plan in NOOP’. You can also choose Build or Review in the action's Shortcuts settings.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Outlooks and plans")
            } footer: {
                Text("Each action prepares a request for review in Coach. A plan is saved only after you review it and tap Save. Pending requests expire after 10 minutes; up to five can wait at once.")
            }

            Section {
                Label("Tap the microphone in Coach to dictate.", systemImage: "mic")
                Text("Microphone and speech permissions are requested only when you tap to start. Dictation requires on-device speech support for your language. If it is unavailable, type your question.")
                Label("Choose a workout photo to copy its text.", systemImage: "text.viewfinder")
                Text("NOOP reads text on this device. Review and correct the extracted text before sending. It does not interpret exercises, form, or objects from the image.")
            } header: {
                Text("Voice and workout photos")
            } footer: {
                Text("Read aloud plays a reply on your device when you request it. Voice input stops when you leave Coach or change its privacy settings. Siri itself uses Apple's Siri settings; it is separate from NOOP's on-device dictation.")
            }

            Section {
                SiriTipView(intent: SyncStrapIntent(), isVisible: .constant(true))
                SiriTipView(intent: BuzzStrapIntent(), isVisible: .constant(true))
                SiriTipView(intent: MarkMomentIntent(), isVisible: .constant(true))
            } header: {
                Text("Strap actions")
            } footer: {
                Text("Sync your strap, buzz it, or mark a moment from Siri, Spotlight, Shortcuts, Back Tap, or an automation.")
            }

            Section {
                ShortcutsLink()
            } header: {
                Text("Shortcuts app")
            } footer: {
                Text("Add Ask Coach to a shortcut and fill in Question, or leave it as Ask Each Time. Coach actions open NOOP for review even when run from an automation. Personal records require separate consent in Coach settings.")
            }
        }
        .navigationTitle("Siri & Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("coach.siriSettings")
    }

    private func phrase(_ title: String, spoken: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
            Text(spoken).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
