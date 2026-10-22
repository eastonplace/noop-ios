#!/usr/bin/env python3
"""Small real-Git fixtures for the trusted change-plan policy. No Swift builds."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools/ci/classify_pr.py"
spec = importlib.util.spec_from_file_location("ci_classifier", SCRIPT)
ci = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = ci
spec.loader.exec_module(ci)


class GitFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        self.write("Tools/ci/classify_pr.py", SCRIPT.read_text())
        self.write("project.yml", "settings:\n  MARKETING_VERSION: 1.8.1\n  CURRENT_PROJECT_VERSION: 241\n  SWIFT_VERSION: 6.0\n")
        for name in ci.LEGACY_HOST_PACKAGES:
            deps = ["WhoopProtocol"] if name == "WhoopStore" else []
            if name == "StrandAnalytics":
                deps = ["WhoopStore"]
            self.package(name, deps)
        for name in ci.APP_BUILD_PACKAGES:
            self.package(name, host=False, tests=False)
        for target, folder in [("NOOPiOSTests", "StrandiOSTests"), ("NOOPCoachUITests", "StrandiOSUITests")]:
            selectors = ci.SAFETY_NATIVE if target == "NOOPiOSTests" else ci.HIGH_UI
            groups = {}
            for selector in selectors:
                _, cls, method = selector.split("/")
                groups.setdefault(cls, []).append(method)
            groups["ExtraCoverageTests"] = ["testRetainedFullCoverage"]
            for cls, methods in groups.items():
                self.write(f"{folder}/{cls}.swift", f"import XCTest\nfinal class {cls}: XCTestCase {{\n" + "\n".join(f" func {method}() {{}}" for method in methods) + "\n}\n")
        self.write("Strand/Screens/WorkoutSportTitle.swift", "import Foundation\nenum WorkoutSportTitle { static let title = \"Run\" }\n")
        self.write("Strand/Screens/TodayView.swift", "import SwiftUI\nstruct TodayView { let runtime = 1 }\n")
        self.write("README.md", "Fixture\n")
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True).strip()

    def write(self, path, text):
        dest = self.repo / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text)

    def package(self, name, deps=(), host=True, tests=True):
        platforms = ".macOS(.v13), .iOS(.v17)" if host else ".iOS(.v17)"
        dependencies = ",".join(f'.package(path: "../{dep}")' for dep in deps)
        test = f', .testTarget(name: "{name}Tests", dependencies: ["{name}"])' if tests else ""
        self.write(f"Packages/{name}/Package.swift", f'// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: "{name}", platforms: [{platforms}], dependencies: [{dependencies}], targets: [.target(name: "{name}"){test}])\n')
        self.write(f"Packages/{name}/Sources/{name}/Value.swift", "struct Value {}\n")

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "--allow-empty", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def plan(self, **kwargs):
        return ci.classify(self.repo, self.base, self.commit(), event="pull_request", **kwargs)

    def test_docs_skip_app_and_keep_eight_legacy_contexts(self):
        self.write("docs/guide.md", "Guide\n")
        plan = self.plan()
        self.assertEqual(plan["mode"], "docs")
        self.assertFalse(plan["run_app"])
        self.assertEqual(len(plan["host_matrix"]), 8)
        self.assertFalse(any(row["run"] for row in plan["host_matrix"]))
        ci.validate_plan(plan)

    def test_ui_is_one_today_plus_affected_and_fixed_method_safety(self):
        self.write("Strand/Screens/WorkoutSportTitle.swift", "enum WorkoutSportTitle { static let title = \"Ride\" }\n")
        plan = self.plan()
        self.assertEqual(plan["mode"], "ui")
        self.assertEqual(plan["native_level"], "smoke")
        self.assertTrue(set(ci.SAFETY_NATIVE) <= set(plan["native_tests"]))
        self.assertEqual(plan["ui_tests"], [ci.TODAY_UI])

    def test_mixed_unknown_runtime_and_workflow_are_high(self):
        for path in ["Strand/Screens/TodayView.swift", "Strand/BLE/Radio.swift", "StrandiOSShared/Data.swift", ".github/workflows/app-build.yml", "Tools/qa/policy.py", "new-unknown.txt"]:
            with self.subTest(path=path):
                self.write(path, "changed\n")
                plan = self.plan()
                self.assertEqual(plan["mode"], "high")
                self.assertEqual(plan["native_tests"], ["NOOPiOSTests"])
                self.assertTrue(set(ci.HIGH_UI) <= set(plan["ui_tests"]))

    def test_ui_file_cannot_gain_runtime_writes_silently(self):
        self.write("Strand/Screens/WorkoutSportTitle.swift", "import Foundation\nlet x = UserDefaults.standard\n")
        self.assertEqual(self.plan()["mode"], "high")

    def test_version_metadata_is_narrow(self):
        self.write("project.yml", "settings:\n  MARKETING_VERSION: 1.8.2\n  CURRENT_PROJECT_VERSION: 242\n  SWIFT_VERSION: 6.0\n")
        self.write("Strand/System/AppChangelog.swift", "enum AppChangelog {}\n")
        self.assertEqual(self.plan()["mode"], "ui")
        self.write("project.yml", "settings:\n  MARKETING_VERSION: 1.8.3\n  CURRENT_PROJECT_VERSION: 243\n  SWIFT_VERSION: 5.0\n")
        self.assertEqual(self.plan()["mode"], "high")

    def test_rename_uses_old_and_new_path_risk(self):
        self.write("docs/.keep", "")
        self.git("mv", "Strand/Screens/TodayView.swift", "docs/moved.md")
        self.assertEqual(self.plan()["mode"], "high")

    def test_reverse_dependencies_use_deleted_base_edges(self):
        self.package("WhoopStore", [])
        self.write("Packages/WhoopProtocol/Sources/WhoopProtocol/Value.swift", "struct Value { let changed = 1 }\n")
        plan = self.plan()
        self.assertTrue({"WhoopProtocol", "WhoopStore", "StrandAnalytics"} <= set(plan["host_packages"]))

    def test_deleted_package_preserves_consumers_and_legacy_skip(self):
        self.git("rm", "-qr", "Packages/WhoopProtocol")
        self.package("WhoopStore", [])
        plan = self.plan()
        self.assertIn("WhoopStore", plan["host_packages"])
        self.assertIn("StrandAnalytics", plan["host_packages"])
        self.assertFalse(next(row for row in plan["host_matrix"] if row["package"] == "WhoopProtocol")["run"])

    def test_new_host_package_and_all_eleven_lanes(self):
        self.package("NewHost", ["StrandDesign"])
        plan = self.plan()
        self.assertIn("NewHost", plan["host_packages"])
        self.assertEqual(len(plan["package_validation"]), 12)
        self.assertEqual({row["lane"] for row in plan["package_validation"]}, {"host_test", "app_build"})

    def test_unknown_testless_package_fails_instead_of_invalid_swift_test(self):
        self.package("UnknownIOS", host=False, tests=False)
        with self.assertRaises(ci.PlanError):
            self.plan()

    def test_known_ios_package_new_test_target_requires_reviewed_validation_lane(self):
        self.package("ReceiptLiftFeature", host=False, tests=True)
        with self.assertRaises(ci.PlanError):
            self.plan()

    def test_nested_package_manifest_cannot_escape_inventory(self):
        self.write("Packages/Nested/Inner/Package.swift", "import PackageDescription\n")
        with self.assertRaises(ci.PlanError):
            self.plan()

    def test_invalid_known_manifest_selects_all_host_packages(self):
        self.write("Packages/WhoopProtocol/Package.swift", "unparseable manifest")
        plan = self.plan()
        self.assertEqual(plan["mode"], "high")
        self.assertEqual(set(plan["host_packages"]), set(ci.LEGACY_HOST_PACKAGES))
        self.assertTrue(plan["inventory_errors"])

    def test_bad_sha_and_unrelated_git_history_fail(self):
        with self.assertRaises(ci.PlanError):
            ci.classify(self.repo, "not-a-sha", self.base, event="pull_request")
        self.git("checkout", "--orphan", "unrelated")
        self.git("rm", "-qrf", ".")
        self.write("README.md", "unrelated")
        head = self.commit()
        with self.assertRaises(ci.PlanError):
            ci.classify(self.repo, self.base, head, event="pull_request")

    def test_merge_base_ignores_new_base_only_changes(self):
        self.git("checkout", "-qb", "feature")
        self.write("docs/feature.md", "feature")
        head = self.commit()
        self.git("checkout", "-q", "main")
        self.write("Strand/BLE/BaseOnly.swift", "base only")
        base = self.commit()
        self.assertEqual(ci.classify(self.repo, base, head, event="pull_request")["mode"], "docs")

    def test_bootstrap_is_high_ten_ui_and_all_packages_full_is_complete(self):
        self.git("rm", "-q", "Tools/ci/classify_pr.py")
        self.base = self.commit()
        self.write("docs/guide.md", "docs")
        plan = self.plan()
        self.assertEqual(plan["mode"], "high")
        self.assertEqual(set(plan["ui_tests"]), set(ci.HIGH_UI))
        self.assertEqual(len(plan["host_packages"]), 8)
        full = self.plan(full=True)
        self.assertEqual(full["mode"], "full")
        self.assertGreater(len(full["ui_tests"]), 10)

    def test_hash_and_tested_sha_are_bound(self):
        self.write("docs/change.md", "change")
        head = self.commit()
        with self.assertRaises(ci.PlanError):
            ci.classify(self.repo, self.base, head, tested_sha=self.base)
        plan = ci.classify(self.repo, self.base, head, tested_sha=head)
        self.assertEqual(plan["tested_sha"], head)
        plan["mode"] = "docs" if plan["mode"] != "docs" else "ui"
        with self.assertRaises(ci.PlanError):
            ci.validate_plan(plan)

    def test_full_inventory_uses_tested_merge_with_new_base_test_and_package(self):
        self.git("checkout", "-qb", "feature")
        self.write("docs/feature.md", "feature")
        head = self.commit()
        self.git("checkout", "-q", "main")
        self.write("StrandiOSUITests/MergedTests.swift", "import XCTest\nfinal class MergedTests: XCTestCase { func testBaseCase() {} }\n")
        self.package("MergedHost")
        base = self.commit()
        self.git("merge", "--no-ff", "-qm", "merge", "feature")
        tested = self.git("rev-parse", "HEAD")
        plan = ci.classify(self.repo, base, head, tested_sha=tested, full=True)
        self.assertIn("NOOPCoachUITests/MergedTests/testBaseCase", plan["ui_tests"])
        self.assertIn("MergedHost", plan["host_packages"])

    def test_rename_package_selects_old_and_new_consumers(self):
        self.git("mv", "Packages/WhoopProtocol", "Packages/RenamedProtocol")
        self.package("RenamedProtocol")
        self.package("WhoopStore", ["RenamedProtocol"])
        plan = self.plan()
        self.assertTrue({"RenamedProtocol", "WhoopStore", "StrandAnalytics"} <= set(plan["host_packages"]))

    def test_unsupported_diff_and_dynamic_dependencies_fail_closed(self):
        for raw in (b"X\0path\0", b"R100\0only-old\0", b"M\0path", b"Q\0path\0"):
            with self.subTest(raw=raw), self.assertRaises(ci.PlanError):
                ci.parse_diff(raw)
        path = self.repo / "Packages/WhoopStore/Package.swift"
        path.write_text(path.read_text().replace('dependencies: [.package(path: "../WhoopProtocol")]', 'dependencies: dynamicDependencies'))
        plan = self.plan()
        self.assertTrue(plan["inventory_errors"])
        self.assertEqual(len(plan["host_packages"]), 8)

    def test_affected_native_tests_are_actual_method_selectors(self):
        self.write("StrandiOSTests/WorkoutSportTitleTests.swift", "import XCTest\nfinal class WorkoutSportTitleTests: XCTestCase { func testTitle() {} }\n")
        self.base = self.commit()
        self.write("Strand/Screens/WorkoutSportTitle.swift", "enum WorkoutSportTitle { static let title = \"Ride\" }\n")
        self.assertIn("NOOPiOSTests/WorkoutSportTitleTests/testTitle", self.plan()["native_tests"])

    def test_high_coach_change_retains_related_ui_beyond_baseline(self):
        self.write("StrandiOSUITests/LocalCoachShellTests.swift", "import XCTest\nfinal class LocalCoachShellTests: XCTestCase { func testComposer() {} }\n")
        self.base = self.commit()
        self.write("StrandiOS/Coach/LocalCoachEngine.swift", "struct LocalCoachEngine {}\n")
        plan = self.plan()
        self.assertEqual(plan["mode"], "high")
        self.assertIn("NOOPCoachUITests/LocalCoachShellTests/testComposer", plan["ui_tests"])

    def test_protected_loader_ignores_head_classifier_and_python_modules(self):
        self.write("Tools/ci/classify_pr.py", "raise SystemExit('PR classifier executed')\n")
        self.write("json.py", "raise RuntimeError('PR module imported')\n")
        head = self.commit()
        output = self.repo / "plan.json"
        result = subprocess.run([sys.executable, "-I", str(ROOT / "Tools/ci/load_plan.py"), "--repo", str(self.repo), "--base", self.base, "--head", head, "--tested-sha", head, "--event", "pull_request", "--output", str(output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(output.read_text())
        self.assertEqual(plan["policy_sha"], self.base)
        self.assertEqual(plan["mode"], "high")

    def test_bootstrap_loader_resolves_relative_repository_and_artifact_paths(self):
        self.git("rm", "-q", "Tools/ci/classify_pr.py")
        base = self.commit()
        self.write("Tools/ci/classify_pr.py", SCRIPT.read_text())
        head = self.commit()
        result = subprocess.run([sys.executable, "-I", str(ROOT / "Tools/ci/load_plan.py"), "--repo", ".", "--base", base, "--head", head, "--event", "pull_request", "--output", "artifacts/plan.json", "--github-output", "artifacts/outputs.txt"], cwd=self.repo, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads((self.repo / "artifacts/plan.json").read_text())
        self.assertEqual(plan["mode"], "high")
        self.assertEqual(len(plan["ui_tests"]), 10)
        self.assertIn("run_app=true", (self.repo / "artifacts/outputs.txt").read_text())


if __name__ == "__main__":
    unittest.main()
