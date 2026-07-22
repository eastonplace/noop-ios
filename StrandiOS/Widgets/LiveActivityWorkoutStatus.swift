#if os(iOS)
/// Cheap workout-presence seam used by the Live Activity controller.
///
/// `StrandiOSApp` already passes the expensive workout projection as an autoclosure. Reading only the
/// optional session's presence here lets the controller react to Start/Finish immediately without forcing
/// calories, zones, and trace reconstruction on every heart-rate callback. The optional explicit argument
/// on `LiveActivityController.update` remains available for tests and future call-site decoupling.
@MainActor
enum LiveActivityWorkoutStatus {
    static var isActive: Bool { AppModel.shared?.activeWorkout != nil }
}
#endif
