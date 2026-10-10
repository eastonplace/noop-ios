#!/usr/bin/env python3
"""Regression tests for the presented-screen header context rule in source_contract_audit."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import source_contract_audit as audit  # noqa: E402

HOST_WITH_CHILD_SHEET_RESET = """
struct WorkoutsLike: View {
    var body: some View {
        ScreenScaffold(title: "Workouts") { Text("x") }
            .sheet(item: $detail) { DetailLike().sheetScreenScaffoldEnvironment() }
    }
}
"""

HOST_WITH_ROOT_RESET = """
struct WorkoutsLike: View {
    var body: some View {
        ScreenScaffold(title: "Workouts") { Text("x") }
            .sheetScreenScaffoldEnvironment()
    }
}
"""

SITE = """
struct Presenter: View {
    var body: some View {
        Text("x").sheet(isPresented: $show) { WorkoutsLike() }
    }
}
"""

SITE_WITH_RESET = SITE.replace("WorkoutsLike()", "WorkoutsLike().sheetScreenScaffoldEnvironment()")


class PresentationFindingsTests(unittest.TestCase):
    def findings(self, host: str, site: str) -> list[str]:
        return audit.presentation_findings({"A.swift": host, "B.swift": site})

    def test_a_reset_only_on_a_child_sheet_does_not_clear_the_hosts_own_context(self):
        self.assertEqual(len(self.findings(HOST_WITH_CHILD_SHEET_RESET, SITE)), 1)

    def test_a_reset_on_the_hosts_own_root_clears_it(self):
        self.assertEqual(self.findings(HOST_WITH_ROOT_RESET, SITE), [])

    def test_a_reset_at_the_presentation_site_clears_it(self):
        self.assertEqual(self.findings(HOST_WITH_CHILD_SHEET_RESET, SITE_WITH_RESET), [])


if __name__ == "__main__":
    unittest.main()
