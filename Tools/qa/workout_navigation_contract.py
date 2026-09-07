"""Structural guard for the active workout's single navigation owner."""
import re


def errors(root_source: str, live_source: str) -> list[str]:
    failures = []
    route = re.search(r"case\s+\.activeWorkout\s*:\s*LiveWorkoutView\(onClose:", root_source)
    if not route:
        failures.append("RootTabView must directly present the active LiveWorkoutView.")
    if "router.presentActiveWorkout = false" not in root_source or "quickAction = .activeWorkout" not in root_source:
        failures.append("The direct active-workout router must consume the legacy one-shot and open the sheet.")
    if re.search(r"quickScreen\(\s*LiveWorkoutView", root_source):
        failures.append("LiveWorkoutView owns navigation; quickScreen must not add a second stack.")
    root = live_source.split("private struct StableWorkoutSession", 1)[0]
    if root.count("NavigationStack {") != 1 or ".noopFocusedTask()" not in root:
        failures.append("LiveWorkoutView must own exactly one focused navigation stack.")
    if "StableWorkoutSession(model: model, workout: workout)" not in root or ".equatable()" not in root:
        failures.append("Active-workout navigation must retain the stable session rendering boundary.")
    return failures
