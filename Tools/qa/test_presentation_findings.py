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


SETTINGS_HOST = """
struct SettingsSheetHost: View {
    var body: some View {
        NavigationStack { SettingsView() }
            .environment(\\.screenScaffoldPresentation, .settingsDetail)
    }
}
"""

SETTINGS_HOST_WITHOUT_ENVIRONMENT = SETTINGS_HOST.replace(
    ".environment(\\.screenScaffoldPresentation, .settingsDetail)", "")

SETTINGS_SITE = """
struct Shell: View {
    var body: some View {
        Text("x").sheet(item: $settingsSheet) { request in SettingsSheetHost(request: request) }
    }
}
"""

BARE_SETTINGS_SITE = """
struct Shell: View {
    var body: some View {
        Text("x").sheet(isPresented: $show) { NavigationStack { SettingsView() } }
    }
}
"""


class PresentationFindingsTests(unittest.TestCase):
    def findings(self, host: str, site: str) -> list[str]:
        return audit.presentation_findings({"A.swift": host, "B.swift": site})

    def test_a_reset_only_on_a_child_sheet_does_not_clear_the_hosts_own_context(self):
        self.assertEqual(len(self.findings(HOST_WITH_CHILD_SHEET_RESET, SITE)), 1)

    def test_a_reset_on_the_hosts_own_root_clears_it(self):
        self.assertEqual(self.findings(HOST_WITH_ROOT_RESET, SITE), [])

    def test_a_reset_at_the_presentation_site_clears_it(self):
        self.assertEqual(self.findings(HOST_WITH_CHILD_SHEET_RESET, SITE_WITH_RESET), [])

    def test_a_sheet_presenting_the_settings_host_is_fine_while_the_host_sets_the_environment(self):
        self.assertEqual(audit.presentation_findings({"Host.swift": SETTINGS_HOST, "Shell.swift": SETTINGS_SITE}), [])

    def test_a_sheet_presenting_the_settings_host_is_flagged_when_the_host_stops_setting_it(self):
        findings = audit.presentation_findings(
            {"Host.swift": SETTINGS_HOST_WITHOUT_ENVIRONMENT, "Shell.swift": SETTINGS_SITE})
        self.assertEqual(len(findings), 1)

    def test_a_bare_settings_view_in_a_sheet_is_still_flagged(self):
        self.assertEqual(len(audit.presentation_findings({"Shell.swift": BARE_SETTINGS_SITE})), 1)


if __name__ == "__main__":
    unittest.main()
