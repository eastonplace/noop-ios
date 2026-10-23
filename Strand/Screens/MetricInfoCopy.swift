import StrandDesign

// MARK: - ⓘ copy for the scores and vitals
//
// Same shape as `MetricInfo.swift`: what it means for you, what good looks like, how to read yours (high, low, normal and
// what to do), and a short "how it's worked out" last. Ranges are conservative, widely used adult figures; where a
// number is personal the copy says so. Health copy ends with "a guide, not medical advice".

private let guideNote = String(localized: "This is a guide, not medical advice. If something feels wrong, or a number stays off for a week or more, talk to a doctor.")

extension MetricInfo {

    // MARK: Today and vitals

    static var hrvSections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), paragraphs: [
                String(localized: "HRV is how much the time between your heartbeats varies. A bit of variation is a good sign: it means your body can shift gears easily and is recovered enough to handle stress."),
                String(localized: "NOOP shows it in milliseconds (ms), measured mostly while you sleep.")
            ]),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "There is no good number for everyone. HRV is very personal and depends on age, fitness, genes and the device, so comparing yours with a friend's tells you nothing. Healthy adults can sit anywhere from the 20s to well over 100 ms."),
                String(localized: "What matters is your own baseline: a steady range over weeks, with a higher reading usually meaning you are better recovered.")
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "Near your baseline: normal. Carry on."),
                String(localized: "Well below your baseline for a night or two: your body is under load. Common causes are hard training, poor sleep, alcohol, stress, a late meal or the start of an illness. Go easier, sleep more and see if it bounces back."),
                String(localized: "Low for a week or more: treat it as a signal to rest, cut back on alcohol and check in on stress or illness."),
                String(localized: "Above your baseline: usually good recovery. A single very high night is not a goal to chase."),
                guideNote
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "The overnight average of the variation between beats, compared with your own recent nights. It is the biggest single input to Recovery.")),
        ]
    }

    static var restingHRSections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "Resting heart rate is how fast your heart beats when you are calm and still. A lower number usually means a fitter, more relaxed heart.")),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "Most adults sit at roughly 50–80 beats per minute (bpm). Well-trained people are often lower, in the 40s or 50s."),
                String(localized: "It is personal, so your own steady range matters more than any chart.")
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "Near your usual: normal."),
                String(localized: "A few bpm above your usual for a day or two: often a hard workout, poor sleep, alcohol, stress, heat or dehydration. Rest and it should settle."),
                String(localized: "5+ bpm above your usual for several days: your body may be fighting something or is overtrained. Take it easy, and see a doctor if you feel unwell."),
                String(localized: "Slowly trending down over weeks: usually fitness improving. That is a good thing."),
                guideNote
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "Your heart rate while at rest, mostly from the night, shown against your own recent baseline. It feeds Recovery.")),
        ]
    }

    static var respiratorySections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "Respiratory rate is how many breaths you take per minute while you sleep.")),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "Most healthy adults breathe about 12–20 times a minute at rest. It is very steady from night to night, which is why small changes stand out."),
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "Within about 1 breath of your usual: normal."),
                String(localized: "A sustained rise of 1 or more above your norm, especially with a higher resting heart rate or lower HRV, can be an early sign of illness. Rest and keep an eye on it."),
                String(localized: "One-off bumps happen after alcohol, a hard workout, a stuffy room or altitude."),
                String(localized: "Consistently outside 12–20, or breathing trouble, is worth raising with a doctor."),
                guideNote
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "Estimated by the strap overnight, then compared with your own recent nights. It is a small input to Recovery.")),
        ]
    }

    static var readinessSections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "Readiness is a quick read on whether today suits a hard push, steady work, or an easier day, based on how you have been recovering and training.")),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "Primed or Balanced means your body is handling its load, so train as planned."),
                String(localized: "Strained or Run down means one or more signals are off your usual. It is not a failure, it is a prompt to ease off."),
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "The signals underneath (HRV, resting HR, breathing and recent load) each get a flag. Good and neutral are normal for you, watch is worth keeping an eye on, and red is clearly off."),
                String(localized: "Mostly green: go ahead. One amber: fine, but keep the session sensible."),
                String(localized: "Several amber or red: make today easy, sleep well and let the numbers recover. A hard day on a red morning is how overtraining starts."),
                String(localized: "The ratio badge compares your last week of training with your last four. 0.8–1.3 is a steady build, above about 1.5 is a spike that raises injury risk."),
                guideNote
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "Each signal is compared with your own trailing baseline. It needs some history first, and it never changes your Recovery score.")),
        ]
    }

    // MARK: Recovery, Strain, Trends

    static var recoverySections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "Recovery is how ready your body is to take on strain today, from 0 to 100%. It is measured each morning from your night.")),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "67% and up (green) means well recovered: you can push. 34–66% (yellow) is middling: train normally. Under 34% (red) is low: choose rest or something easy."),
                String(localized: "Your scores will bounce around. Look at your typical level over a few weeks rather than any one morning."),
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "Green: a good day for a hard session."),
                String(localized: "Yellow: a normal day. Listen to how you feel."),
                String(localized: "Red: your body is asking for a lighter day. The usual causes are poor or short sleep, alcohol, illness, stress or hard training the day before. Sleep earlier and keep effort low."),
                String(localized: "Recovery is a guide, not medical advice. It does not diagnose anything.")
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "Mostly your overnight HRV (about 55%), then resting heart rate (20%), sleep (15%), breathing (5%) and skin temperature (5%), each against your own baseline.")),
        ]
    }

    static var strainSections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "Strain is how much work your heart and body have done today, from light activity to an all-out day.")),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "It depends on your recovery, not a fixed target. On the 0–21 scale, under 10 is Light, 10 to under 14 is Moderate, 14 to under 18 is High, and 18 or more is All Out."),
                String(localized: "A good match is high strain on high Recovery days and lighter strain on low ones."),
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "Low on a green day: you have room to do more."),
                String(localized: "High on a red day: you are stacking load on a tired body. Ease off tomorrow."),
                String(localized: "Several all-out days in a row builds fatigue fast. Mix in easy days."),
                String(localized: "It builds through the day from heart-rate and movement load. Logged working sets can add muscular load, so lifting can count even when heart rate alone misses some of the work.")
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "Heart-rate intervals count more as heart-rate reserve rises, using your resting and maximum heart rates. Worn sleep adds background credit. Steps and active energy provide floors, and logged working sets add muscular load to the heart-rate component before it is compared with those floors. The result is shown on the 0–21 scale.")),
        ]
    }

    static var strainScoreSections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "These rows show the overlapping values used to choose your Strain score, plus any increase from logged lifting.")),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "There is no ideal split to aim for. Cardio often sets the score on a workout day. Steps or active energy can set a floor on a quieter one."),
                String(localized: "What matters is that the total suits your Recovery: more on green days, less on red ones.")
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "Cardio decides the score when its heart-rate and worn-sleep load, plus any logged lifting, is at least as high as the movement floors."),
                String(localized: "Steps or energy decides the score when that movement floor is higher than the cardiovascular and lifting result."),
                String(localized: "Do not add the rows together. The Lifting row shows only what your logged sets add. After lifting is applied to cardio, the highest of cardio, steps and active energy sets the score. If the rows do not match the score above, they can come from a different source or scoring moment."),
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "NOOP compares the heart-rate and worn-sleep component with the step and active-energy floors. Logged lifting adds to the cardiovascular load before that comparison. These are overlapping candidates, not shares of a total.")),
        ]
    }

    static var trendScoresSections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "Each row is your average over the range you picked, with a change against the period of the same length just before it. It shows whether you are drifting up, down or staying steady.")),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "Recovery, Sleep and HRV trending up or holding steady is good. A slow climb over weeks is the sign of a body adapting well."),
                String(localized: "Strain has no good direction. Higher is fine if your Recovery holds up, and a drop can simply mean a rest week."),
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "Small changes of a point or two are noise. Look for moves that last. \"Early read\" means there are too few days so far to trust the change."),
                String(localized: "Recovery and HRV falling while Strain rises: you may be doing too much. Add rest."),
                String(localized: "Recovery falling while Sleep falls: sleep is the first thing to fix."),
                String(localized: "Everything dipping at once for a few days is often illness, travel or stress."),
                String(localized: "HRV is personal. Compare it with your own past, not with other people."),
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "The average of the days with data in your range, against the average of the period of the same length just before it. Days without data are skipped.")),
        ]
    }

    static var weeklyReadoutSections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "A summary of one week: how recovered you were, how hard you worked and how well you slept, plus the biggest changes from the week before.")),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "A good week has steady or rising Recovery and Sleep, with Strain you chose to put in. A rest week with low Strain and rising Recovery is also good."),
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "Biggest changes lists what moved most against the previous week. Start with the one that surprises you."),
                String(localized: "Whether a rise is good depends on the metric: up is good for Recovery and Sleep, but Strain just shows how hard you worked."),
                String(localized: "Fewer than 7 days of data makes the comparison rough, and it says so."),
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "Averages of the days with data in the week against the days with data in the week before.")),
        ]
    }

    // MARK: Sleep

    static var sleepScoreSections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "Your Sleep score is a 0–100% summary of the night. NOOP's own scores consider how much you slept against your need, how efficiently you slept and how regular your sleep was. Imported scores keep the source's calculation.")),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "85% and up is excellent, 70–84% is good, and below about 50% means the night fell well short."),
                String(localized: "Most adults need about 7–9 hours. Your own need can be a bit more after hard days."),
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "High: you got the rest you needed. Keep your bed and wake times steady."),
                String(localized: "Low: you were short on time, woke a lot, or your times were irregular. Go to bed earlier, keep a regular schedule, and limit alcohol and late caffeine."),
                String(localized: "One bad night is not a problem. Look at the week."),
                guideNote
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "The method depends on the score's source. NOOP's legacy model weights hours against need at 50%, efficiency at 20%, deep and REM sleep at 20%, and consistency at 10%. The newer model weights hours against need at 70%, then efficiency, regular bed and wake times, and low overnight stress at 10% each, with a lower ceiling when optional signals are missing. Imported WHOOP scores use WHOOP's calculation.")),
        ]
    }

    static var sleepStagesSections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), paragraphs: [
                String(localized: "Sleep moves through stages in cycles of about 90 minutes. Each does a different job."),
                String(localized: "Deep: the body repairs itself, muscles recover and the immune system gets a boost."),
                String(localized: "REM: dreaming. This is when the brain files memories and processes emotions."),
                String(localized: "Light: the lighter in-between sleep. It is most of the night, and that is normal."),
                String(localized: "Awake: short wake-ups. A few are normal and often forgotten."),
            ]),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "For most adults, deep sleep is about 13–23% of the night and REM about 20–25%. Light sleep makes up much of the rest, and awake time should be small."),
                String(localized: "The typical mark on each row shows your own usual share, which is a better yardstick than the general range."),
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "Near your typical mark: a normal night for you."),
                String(localized: "Deep low: alcohol, a late meal, a hot room and stress can all cut deep sleep. Deep sleep also falls with age."),
                String(localized: "REM low: alcohol, short nights and cutting the end of the night short all squeeze REM."),
                String(localized: "Lots of awake time: noise, light, pain, stress, a late caffeine hit or an uncomfortable room."),
                String(localized: "Wearable stage estimates are not lab-grade. Use the trend rather than one night's split."),
                guideNote
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "Estimated from heart rate, heart rhythm and movement through the night, then smoothed on the chart for readability.")),
        ]
    }

    static var sleepNeedSections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "Sleep need is how much sleep your body is asking for tonight. Sleep balance is how you have done against that need over the last two weeks, and any debt you owe.")),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "Most adults need about 7–9 hours. Your number is built around your own baseline, then nudged by how hard you worked yesterday, any debt to repay and naps you took."),
                String(localized: "Good balance means you are meeting your need most nights, with little or no debt."),
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "Need higher than usual: you trained hard, or you are paying back missed sleep. Aim to be in bed earlier."),
                String(localized: "In debt: you have been short for several nights. You can claw it back with an earlier bedtime and a steady wake time over a few days. One long sleep-in does not fix it."),
                String(localized: "Surplus: you are ahead of your need, which is fine."),
                guideNote
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "A baseline need plus extra for yesterday's Strain and debt repayment, minus nap credit. Balance compares the last 14 nights of sleep with the need for each.")),
        ]
    }

    static var nightDetailSections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "These rows break last night into the parts behind your Sleep score. Each shows last night's figure and how it compares with your own typical.")),
            .init(heading: String(localized: "Efficiency"), paragraphs: [
                String(localized: "How much of your time in bed you were asleep. 85% or more is good. Low efficiency usually means lying awake or waking a lot."),
            ]),
            .init(heading: String(localized: "Hours vs needed"), paragraphs: [
                String(localized: "Your sleep as a share of your Sleep need. 100% means you got what you needed. Under about 85% on many nights builds debt."),
            ]),
            .init(heading: String(localized: "Restorative"), paragraphs: [
                String(localized: "The share of your sleep spent in deep plus REM. For most adults that is roughly 35–45%. It naturally falls with age and with alcohol."),
            ]),
            .init(heading: String(localized: "Consistency"), paragraphs: [
                String(localized: "How regular your sleep and wake times are from day to day. Higher is better. A steady schedule helps sleep quality more than most people expect."),
            ]),
            .init(heading: String(localized: "Respiratory rate"), paragraphs: [
                String(localized: "Breaths per minute while you sleep, usually about 12–20. It is steady for you, so a sustained rise of 1 or more can flag illness."),
            ]),
            .init(heading: String(localized: "Duration"), paragraphs: [
                String(localized: "How long you slept. Most adults need about 7–9 hours. Tap the row for the 30-night chart."),
            ]),
            .init(heading: String(localized: "Reading yours"), body:
                String(localized: "Compare each row with its typical. A few points either way is noise. Look for a row that stays off for several nights, and fix that first. This is a guide, not medical advice.")),
        ]
    }

    // MARK: Body, forecast, stress

    static var vitalitySections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "Vitality is a 0–100 read of how your everyday habits and body signals compare with people your age. Body Age is the age your body is acting like.")),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "A Vitality of 50 means you look like the average for your age. Higher is better, and a Body Age below your real age means your signals look younger than average."),
                String(localized: "It is a trend, not a verdict. A few years either way is well within the margin of error."),
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "Body Age older than your age: look at the factor listed as the biggest drag. Sleep, steps and resting heart rate are the easiest to move."),
                String(localized: "Younger: keep doing what works."),
                String(localized: "It changes slowly because it uses a week of data, so give changes a few weeks to show."),
                guideNote
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "From your last week of resting heart rate, HRV, sleep length and regularity, and steps, compared with typical values for your age.")),
        ]
    }

    static var recoveryForecastSections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "An estimate of the Recovery you will likely wake up with tomorrow, if you sleep about as much as usual tonight.")),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "Green (67%+) is a good outlook, yellow is middling, and red means tomorrow may start low."),
                String(localized: "The ± range is how unsure the estimate is. A wider range means less certainty, so treat it as a rough steer, not a promise."),
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "A low forecast: go to bed earlier, skip alcohol and keep the evening calm. These are the levers you control tonight."),
                String(localized: "A high forecast: keep your routine, you are on track."),
                String(localized: "Tomorrow's actual Recovery depends on how you sleep and what your body does overnight, so it can land outside the range."),
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "It starts from your recent Recovery average, adjusts for today's Strain against your norm and for the sleep you usually get, and pulls gently back toward your average.")),
        ]
    }

    static var stressSections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "Stress shows how much load your body is under, from 0 to 3. It reflects your body's physical response, not how stressed you feel.")),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "Under 1 is Low, 1–2 is Moderate and above 2 is High. Some stress is normal and healthy: exercise, work and a busy day all raise it."),
                String(localized: "What matters is recovery: stress should come down in the evening and overnight."),
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "Low: you are calm or recovered."),
                String(localized: "Moderate: a normal workday."),
                String(localized: "High, for a stretch: take a break, breathe slowly for a few minutes, go for a walk or wind down early. If it stays high with no clear cause, look at sleep, caffeine and workload."),
                String(localized: "A hard workout can raise it for a while. That is expected."),
                guideNote
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "The daily score uses a stored stress value when available, or resting heart rate and HRV against recent daily history. The hourly timeline normally compares today's waking heart-rate and beat-to-beat signals with calmer hours from the same day; it can work without earlier nights or usable beat-to-beat data. If Personal baseline is enabled and enough history is available, the hourly timeline instead uses a heart-rate baseline from the previous 30 complete days. Otherwise it keeps the same-day comparison. The selected baseline mode does not change the daily score.")),
        ]
    }

    // MARK: Training load page

    static var loadProjectionSections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "What your recent load would be tomorrow for three imagined days: rest, a moderate session or all out.")),
            .init(heading: String(localized: "What good looks like"), body:
                String(localized: "Recent load between 0.8× and 1.3× of your base is a steady build. A rest day lets form recover, a hard day pushes load up.")),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "If a hard day would push you above about 1.3×, you are already near a spike. Consider an easier day."),
                String(localized: "If an easy day drops you below 0.8×, that is fine for recovery, but fitness slips if it goes on for weeks."),
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "The same running averages as Training load, with a rest day, a moderate session or an all-out day added for tomorrow. It is not a recommendation.")),
        ]
    }

    static var loadHistorySections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "Your recent load and fitness base over time. The gap between them is your form.")),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "A base that rises slowly over weeks is the sign of steady progress. Recent load that hugs it, then dips for a rest week, is a healthy pattern."),
                String(localized: "Sharp peaks well above the base are where injuries and burnout come from."),
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "Recent above base: you are building, and tired. Plan an easier day soon."),
                String(localized: "Recent below base: you are fresher, or losing fitness if it lasts weeks."),
                String(localized: "Compare with your own history, not other people's load."),
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "Each day's Strain feeds a roughly 1-week and a roughly 6-week running average.")),
        ]
    }

    // MARK: Insights

    static var metricRelationshipsSections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "How closely two of your numbers move together across your own days. For example, whether higher HRV tends to come with higher Recovery.")),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "There is no good or bad value. The number runs from −1 to +1. Near 0 means no link, near +1 means they rise together and near −1 means one rises as the other falls."),
                String(localized: "Strength uses the size of r, ignoring its sign. Below 0.1 is no relationship, 0.1 to under 0.3 is weak, 0.3 to under 0.5 moderate, 0.5 to under 0.7 strong, and 0.7 or more very strong. The sign only tells you whether the numbers move together or in opposite directions."),
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "A link is not a cause. Two numbers can move together because a third thing drives both, or by chance, especially with a short history."),
                String(localized: "Use it as a hint about what to try, such as sleeping more to see if Recovery follows."),
                String(localized: "The more days behind it, the more it can be trusted."),
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "Pearson correlation (r) across the days where both metrics have data.")),
        ]
    }

    static var doseResponseSections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "How much each extra unit of something you log, such as a drink or a late coffee, tends to change your numbers the next day.")),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "A flat curve means little effect on you. A steep downward curve means each unit costs you noticeable Recovery."),
                String(localized: "It is about your body only. Compare it with its own range, not with other people."),
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "\"Prior-shrunk\" means that with only a few logged days, NOOP leans on typical effects and only moves toward your own result as your data grows. It stops a handful of days from fooling you."),
                String(localized: "Until the curve is yours, it is labelled as not yet personal. Keep logging to sharpen it."),
                String(localized: "Like any pattern, it shows an association, not proof of cause."),
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "A simple curve fitted to your logged doses and next-day results, blended with typical effects when your data is thin.")),
        ]
    }
}
