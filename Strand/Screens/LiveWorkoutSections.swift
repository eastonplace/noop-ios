import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Live workout signals
//
// The leaf every live number reads its freshness through. It observes only what it draws (the workout's own published values
// or the recorder), so a heart-rate sample redraws the figures and never the whole screen.

// MARK: Signal notices

/// Reads the two live signals every two seconds and hands what it found to `content`. A signal going quiet publishes
/// nothing (no reading arrives), so it has to be asked on a clock. The pills, the tiles and the zone rail all read
/// through this, so none of them can show a number at full strength that another has already called stale.
struct LiveWorkoutSignalReader<Content: View>: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    /// The strap's link, read at each tick (never observed): with it the snapshot can tell a strap that went quiet from one
    /// that never connected. nil leaves `strapNeverConnected` false.
    var live: LiveState?
    /// A page that is not on screen has no clock: it draws what is true now, once, and is redrawn when something it shows
    /// changes. Only the page being looked at ticks.
    var isVisible = true
    @ViewBuilder let content: (LiveWorkoutSignals.Snapshot) -> Content

    var body: some View {
        if isVisible {
            TimelineView(.periodic(from: .now, by: 2)) { context in
                content(snapshot(at: context.date))
            }
        } else {
            content(snapshot(at: Date()))
        }
    }

    private func snapshot(at now: Date) -> LiveWorkoutSignals.Snapshot {
        let tracksRoute = recorder.isRecording && recorder.canRecordRoute
        return LiveWorkoutSignals.Snapshot(
            heartRateIsStale: LiveWorkoutSignals.heartRateIsStale(
                lastReadingAt: workout.lastReadingAt, workoutStart: workout.start,
                isPaused: workout.isPaused, isEnding: workout.isEnding, now: now),
            gps: tracksRoute ? recorder.signalState(now: now) : nil,
            strapNeverConnected: live.map { workout.lastReadingAt == nil && !$0.connected } ?? false,
            locationIsOff: recorder.isRecording && !recorder.canRecordRoute)
    }
}
