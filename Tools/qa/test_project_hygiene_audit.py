import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("project_hygiene_audit.py")
spec = importlib.util.spec_from_file_location("project_hygiene_audit", MODULE_PATH)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

PROJECT = """\
name: Fixture
settings:
  base:
    MARKETING_VERSION: "{version}"
packages:
  Core:
    path: {package_path}
targets:
  App:
    type: application
    sources:
      - path: App
      - path: {app_tool_path}
        type: folder
  AppTests:
    type: bundle.unit-test
    sources:
      - AppTests
    dependencies:
      - target: App
"""

CHANGELOG = """\
enum AppChangelog {{
    static let currentVersion = "2.0.0"
    static let releases: [Release] = [
        Release(version: "{newest}", title: "t", date: "d", items: []),
        Release(version: "1.0.0", title: "t", date: "d", items: []),
    ]
}}
"""


IGNORE_RULES = """\
**/linux-capture/captures/
**/linux-capture/**/*.json
**/linux-capture/**/*.db
**/linux-capture/**/*.db-wal
**/linux-capture/**/*.db-shm
**/linux-capture/.venv*/
"""


class ProjectHygieneAuditTests(unittest.TestCase):
    def make_repo(self, files: dict[str, str], version: str = "2.0.0", newest: str = "2.0.0",
                  package_path: str = "Packages/Core", app_tool_path: str = "Tools/Preview") -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        contents = {
            "project.yml": PROJECT.format(version=version, package_path=package_path,
                                          app_tool_path=app_tool_path),
            "Strand/System/AppChangelog.swift": CHANGELOG.format(newest=newest),
            "App/App.swift": "",
            "AppTests/AppTests.swift": "",
            "Packages/Core/Package.swift": "",
            "Packages/Core/Tests/CoreTests/CoreTests.swift": "",
            "Tools/Preview/Preview.swift": "",
            ".gitignore": IGNORE_RULES,
        }
        contents.update(files)
        for relative, text in contents.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "-c", "core.ignorecase=false", "add", "-A"], cwd=root, check=True)
        return root

    def test_clean_fixture_passes(self):
        errors, warnings = module.audit(self.make_repo({}))
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])

    def test_orphaned_test_folder_is_an_error(self):
        errors, _ = module.audit(self.make_repo({"LegacyTests/OldTests.swift": ""}))
        self.assertTrue(any("LegacyTests/" in line for line in errors), errors)

    def test_test_file_outside_test_targets_is_an_error(self):
        errors, _ = module.audit(self.make_repo({"App/Stray/StrayTests.swift": ""}))
        self.assertTrue(any("App/Stray/StrayTests.swift" in line for line in errors), errors)

    def test_allowlisted_strandtests_and_package_tests_are_allowed(self):
        errors, _ = module.audit(self.make_repo({"StrandTests/AnyTests.swift": ""}))
        self.assertEqual(errors, [])

    def test_version_drift_is_a_warning_not_an_error(self):
        errors, warnings = module.audit(self.make_repo({}, version="2.1.0", newest="2.0.0"))
        self.assertEqual(errors, [])
        self.assertEqual(len(warnings), 1)
        self.assertIn("2.1.0", warnings[0])

    def test_fork_release_is_newer_than_upstream_history(self):
        text = ('static let releases: [Release] = [\n'
                '  .fork("1.7.0", "Fork", "October", []),\n'
                '  Release(version: "7.9.0", title: "Upstream", date: "July", items: []),\n'
                ']')
        self.assertEqual(module.newest_changelog_version(text), "1.7.0")

    def test_source_path_case_mismatch_is_an_error(self):
        errors, _ = module.audit(self.make_repo({}, app_tool_path="tools/Preview"))
        self.assertTrue(any("tools/Preview" in line and "Tools/Preview" in line for line in errors), errors)

    def test_package_path_case_mismatch_is_an_error(self):
        errors, _ = module.audit(self.make_repo({}, package_path="packages/Core"))
        self.assertTrue(any("packages/Core" in line for line in errors), errors)

    def test_tracked_capture_database_is_an_error(self):
        root = self.make_repo({"Tools/linux-capture/README.md": ""})
        db = root / "Tools/linux-capture/captures/whoop.db"
        db.parent.mkdir(parents=True, exist_ok=True)
        db.write_text("serial", encoding="utf-8")
        subprocess.run(["git", "add", "-f", str(db)], cwd=root, check=True)
        errors, _ = module.audit(root)
        self.assertTrue(any("captures/whoop.db" in line for line in errors), errors)

    def test_capture_paths_must_be_ignored_under_both_spellings(self):
        root = self.make_repo({".gitignore": "Tools/linux-capture/captures/\n"})
        errors, _ = module.audit(root)
        self.assertTrue(any("tools/linux-capture/captures/whoop.db" in line for line in errors), errors)

    def test_nested_capture_outputs_must_be_ignored(self):
        one_level = IGNORE_RULES.replace("/**/*.", "/*.")
        root = self.make_repo({".gitignore": one_level})
        errors, _ = module.audit(root)
        self.assertTrue(any("tools/linux-capture/exports/all.json" in line for line in errors), errors)
        self.assertTrue(any("Tools/linux-capture/runs/whoop.db-wal" in line for line in errors), errors)
        self.assertFalse(any("linux-capture/whoop.db`" in line for line in errors), errors)

    def test_tracked_nested_export_is_an_error(self):
        root = self.make_repo({})
        export = root / "Tools/linux-capture/exports/all.json"
        export.parent.mkdir(parents=True, exist_ok=True)
        export.write_text("{}", encoding="utf-8")
        subprocess.run(["git", "add", "-f", str(export)], cwd=root, check=True)
        errors, _ = module.audit(root)
        self.assertTrue(any("exports/all.json" in line and "tracked" in line for line in errors), errors)

    def test_global_git_excludes_cannot_mask_a_missing_root_rule(self):
        root = self.make_repo({".gitignore": ""})
        home = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(home)], check=False))
        (home / "ignore").write_text("captures/\n*.json\n*.db\n*.db-wal\n*.db-shm\n.venv/\n", encoding="utf-8")
        (home / "config").write_text(f"[core]\n\texcludesFile = {home / 'ignore'}\n", encoding="utf-8")
        saved = {key: os.environ.get(key) for key in ("GIT_CONFIG_GLOBAL", "XDG_CONFIG_HOME")}
        os.environ["GIT_CONFIG_GLOBAL"] = str(home / "config")
        os.environ["XDG_CONFIG_HOME"] = str(home)
        try:
            errors, _ = module.audit(root)
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
        self.assertTrue(any("tools/linux-capture/whoop.db" in line for line in errors), errors)

    def test_reader_handles_inline_and_mapping_sources(self):
        targets = module.parse_targets(PROJECT.format(version="1", package_path="P", app_tool_path="T"))
        self.assertEqual(targets["App"]["sources"], ["App", "T"])
        self.assertEqual(targets["AppTests"], {"type": "bundle.unit-test", "sources": ["AppTests"]})


if __name__ == "__main__":
    unittest.main()
