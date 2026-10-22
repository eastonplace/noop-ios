"""Exercise release checks with real local Git history, including incomplete checkouts."""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

AUDIT = Path(__file__).with_name("whats_new_release_audit.py")


class WhatsNewReleaseAuditTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "repo"
        self.root.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "fixture@example.test")
        self.git("config", "user.name", "Fixture")
        (self.root / "Tools/qa").mkdir(parents=True)
        shutil.copyfile(AUDIT, self.root / "Tools/qa/whats_new_release_audit.py")
        self.write_release("1.7.0", 238)
        self.base = self.commit("base")
        self.git("update-ref", "refs/remotes/origin/main", self.base)
        self.git("remote", "add", "origin", str(self.root))

    def git(self, *args, root=None):
        return subprocess.run(["git", *args], cwd=root or self.root, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write_release(self, version, build):
        (self.root / "project.yml").write_text(
            f'settings:\n  base:\n    MARKETING_VERSION: "{version}"\n    CURRENT_PROJECT_VERSION: "{build}"\n')
        path = self.root / "Strand/System/AppChangelog.swift"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('enum AppChangelog {\n'
                        f'  static let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "{version}"\n'
                        '  static let releases: [Release] = [\n'
                        f'    .fork("{version}", "Title", "October 2026", [Feature("star", .accent, "Title", "Detail")]),\n'
                        '  ]\n}\n')
        (self.root / "CHANGELOG.md").write_text(f'## {version}\n\nFixture changes.\n')

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def audit(self, *, base=None, head=None, root=None, pr=True):
        root = root or self.root
        env = {key: value for key, value in os.environ.items()
               if key not in ("GITHUB_BASE_REF", "GITHUB_BASE_SHA", "GITHUB_HEAD_SHA")}
        if pr:
            env.update(GITHUB_BASE_REF="main", GITHUB_BASE_SHA=base or self.base,
                       GITHUB_HEAD_SHA=head or self.git("rev-parse", "HEAD", root=root))
        return subprocess.run([sys.executable, str(root / "Tools/qa/whats_new_release_audit.py")],
                              cwd=root, env=env, capture_output=True, text=True)

    def test_valid_bump_passes(self):
        self.write_release("1.8.0", 239)
        self.commit("feature")
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_base_fails_closed(self):
        result = self.audit(base="f" * 40)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("compare", result.stdout)

    def test_unchanged_version_is_rejected(self):
        (self.root / "Strand/App.swift").write_text("// user-facing change\n")
        self.commit("feature without bump")
        self.assertNotEqual(self.audit().returncode, 0)

    def test_fork_renumbering_still_requires_higher_build(self):
        self.write_release("9.0.1", 237)
        base = self.commit("upstream numbering")
        self.write_release("1.7.0", 206)
        self.commit("renumbered fork")
        result = self.audit(base=base)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("CURRENT_PROJECT_VERSION", result.stdout)

    def test_fork_renumbering_with_higher_build_passes(self):
        self.write_release("9.0.1", 237)
        base = self.commit("upstream numbering")
        self.write_release("1.7.0", 238)
        self.commit("renumbered fork")
        result = self.audit(base=base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_shallow_checkout_without_base_fails_closed(self):
        self.write_release("1.8.0", 239)
        self.commit("feature")
        clone = Path(self.tmp.name) / "shallow"
        self.git("clone", "-q", "--depth=1", self.root.as_uri(), str(clone))
        self.assertNotEqual(self.audit(root=clone).returncode, 0)

    def test_divergent_branch_compares_its_merge_base(self):
        self.git("checkout", "-qb", "feature")
        self.write_release("1.8.0", 239)
        head = self.commit("feature")
        self.git("checkout", "-q", "main")
        (self.root / "README.md").write_text("Independent main update\n")
        base = self.commit("main docs")
        self.git("checkout", "-q", "feature")
        result = self.audit(base=base, head=head)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_main_or_manual_run_checks_local_release_without_pr_comparison(self):
        self.assertEqual(self.audit(pr=False).returncode, 0)


if __name__ == "__main__":
    unittest.main()
