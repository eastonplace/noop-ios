import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - ⓘ "what this means" for Load focus and Training load
//
// The same chip the Sleep page puts beside its stage header (`WidgetChipButton` with `info.circle`, opening a
// popover that is a sheet on iPhone). The copy leads with what the numbers mean for the person and what to do about
// them; how it is worked out comes last and short.

enum LoadInfoTopic {
    case loadFocus
    case trainingLoad
}

struct LoadInfoButton: View {
    let topic: LoadInfoTopic
    @State private var isShowing = false

    var body: some View {
        WidgetChipButton(systemImage: "info.circle",
                         accessibilityLabel: topic == .loadFocus ? "About Load focus" : "About Training load") {
            isShowing.toggle()
        }
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            LoadInfoSheet(topic: topic)
                .presentationDetents([.medium, .large])
        }
        .accessibilityIdentifier(topic == .loadFocus ? "loadFocus.info" : "trainingLoad.info")
    }
}

struct LoadInfoSheet: View {
    let topic: LoadInfoTopic

    private struct Block: Identifiable {
        let id = UUID()
        let heading: String
        let lines: [String]
    }

    private var title: String {
        topic == .loadFocus ? String(localized: "About Load focus") : String(localized: "About Training load")
    }

    private var blocks: [Block] {
        topic == .loadFocus ? loadFocusBlocks : trainingLoadBlocks
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text(verbatim: title)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(blocks) { block in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: block.heading)
                            .font(StrandFont.footnote.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(block.lines, id: \.self) { line in
                            Text(verbatim: line)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(NoopMetrics.cardInnerPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 380)
        .background(StrandPalette.surfaceOverlay)
    }

    // MARK: Load focus

    private var loadFocusBlocks: [Block] {
        let override = ProfileStore.storedHrMaxOverride()
        let maxHR = ProfileStore.hrMax(age: ProfileStore.storedAge(), override: override)
        let source = override > 0 ? String(localized: "your own setting") : String(localized: "estimated from your age")
        return [
            Block(heading: String(localized: "What it means"), lines: [
                String(localized: "How your workout effort splits between easy aerobic work, tempo and threshold work, and all-out work.")
            ]),
            Block(heading: String(localized: "What good looks like"), lines: [
                String(localized: "Most of your training easy, some of it tempo, and a little of it hard. Roughly 35–55% low aerobic, 25–45% high aerobic and 5–15% anaerobic."),
                String(localized: "Low aerobic is zones 1–2, steady easy effort. High aerobic is zones 3–4, tempo and threshold. Anaerobic is zone 5, intervals and sprints."),
                String(localized: "Most endurance fitness is built on easy volume, and a little hard work goes a long way.")
            ]),
            Block(heading: String(localized: "Reading yours"), lines: [
                String(localized: "In range: your mix looks like a typical endurance build. Keep going."),
                String(localized: "Low aerobic a bit low: add more easy volume, like an extra easy session or longer easy days."),
                String(localized: "High aerobic a bit high: you are living in the middle. Make easy days easier and keep hard days purposeful."),
                String(localized: "Anaerobic a bit high: too much hard work against your base raises fatigue and injury risk. Add easy sessions or swap one hard day for an easy one."),
                String(localized: "Anaerobic a bit low: fine if you are building a base. A short interval session now and then is enough."),
                String(localized: "It is a guide, not a prescription. Your sport and your goals can sensibly sit outside these ranges.")
            ]),
            Block(heading: String(localized: "How it's worked out"), lines: [
                String(localized: "From workout heart rate only, over the last 4 weeks. Minutes in harder zones count more, weighted like Strain. It needs \(LoadFocus.minimumWorkouts)+ workouts with heart rate. Zones use a max HR of \(maxHR) (\(source)).")
            ])
        ]
    }

    // MARK: Training load

    private var trainingLoadBlocks: [Block] {
        [
            Block(heading: String(localized: "What the numbers mean"), lines: [
                String(localized: "Recent load is how much you have been training over about the last week."),
                String(localized: "Fitness base is what your body is used to, over about six weeks."),
                String(localized: "Form is base minus recent. It says whether you are fresher or more tired than usual.")
            ]),
            Block(heading: String(localized: "What your load should be"), lines: [
                String(localized: "Compare recent load to your base. At 0.8–1.3× you are building steadily."),
                String(localized: "Above about 1.3× is a spike. Injury and fatigue risk rises, so ease up for a few days."),
                String(localized: "Below 0.8× you are easing off. That is fine for recovery or a taper, but fitness slowly drops if it lasts for weeks.")
            ]),
            Block(heading: String(localized: "Reading form"), lines: [
                String(localized: "Negative form means you are training above your base. That is normal in a build block, so watch your recovery."),
                String(localized: "Positive form means you are fresher.")
            ]),
            Block(heading: String(localized: "It is personal"), lines: [
                String(localized: "There is no right number. Compare with your own base, not with other people's load.")
            ]),
            Block(heading: String(localized: "How it's worked out"), lines: [
                String(localized: "Each day's Strain feeds two running averages, about 1 week and about 6 weeks. Recent days count more.")
            ])
        ]
    }
}
