import unittest
from pathlib import Path
from workout_navigation_contract import errors

ROOT = Path(__file__).resolve().parents[2]


class WorkoutNavigationContractTests(unittest.TestCase):
    def setUp(self):
        self.root = (ROOT / "StrandiOS/App/RootTabView.swift").read_text()
        self.live = (ROOT / "Strand/Screens/LiveWorkoutView.swift").read_text()

    def test_integrated_route_has_one_owner(self):
        self.assertEqual(errors(self.root, self.live), [])

    def test_duplicate_stack_is_rejected(self):
        changed = self.root.replace("case .activeWorkout: LiveWorkoutView", "case .activeWorkout: quickScreen(LiveWorkoutView")
        self.assertTrue(errors(changed, self.live))

    def test_missing_direct_router_is_rejected(self):
        self.assertTrue(errors(self.root.replace("quickAction = .activeWorkout", "quickAction = .live"), self.live))

    def test_missing_native_owner_is_rejected(self):
        self.assertTrue(errors(self.root, self.live.replace("NavigationStack {", "Group {")))

    def test_missing_equatable_boundary_is_rejected(self):
        self.assertTrue(errors(self.root, self.live.replace(".equatable()", "")))


if __name__ == "__main__":
    unittest.main()
